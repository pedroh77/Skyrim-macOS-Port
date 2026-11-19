// XAudio2 2.6 + X3DAudio 1.7 + xWMA shims backed by FNVAudioMixer and FFmpeg.
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "com.h"
#include "FNVNativeMedia.h"

#ifdef SKYRIM_HAVE_FFMPEG
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#endif

static inline uint16_t xa2_r16(uint32_t a) {
    uint16_t v;
    memcpy(&v, MEM + a, 2);
    return v;
}
static inline void xa2_w16(uint32_t a, uint16_t v) {
    memcpy(MEM + a, &v, 2);
}
static inline float xa2_rf(uint32_t a) {
    float v;
    memcpy(&v, MEM + a, 4);
    return v;
}
static inline void xa2_wf(uint32_t a, float v) {
    memcpy(MEM + a, &v, 4);
}
static inline void xa2_w64(uint32_t a, uint64_t v) {
    memcpy(MEM + a, &v, 8);
}
static inline float xa2_argf(CPU *c, int idx) {
    uint32_t bits = ARG(c, idx);
    float f;
    memcpy(&f, &bits, 4);
    return f;
}

// Guest object private payloads stored in COM_DATA(o):
// Engine: none (vt_xaudio2)
// Mastering/Submix: [0]=kind(0=master,1=submix), [4]=channels, [8]=sample_rate
// Source: [0]=kind(2=source), [4]=mixer_id (0..511)
#define VO_KIND 0
#define VO_CH   4
#define VO_RATE 8
#define VO_ID   4

#define MAX_SOURCE_VOICES 512

typedef struct {
    int in_use;
    uint16_t fmt_tag;
    uint16_t channels;
    uint32_t sample_rate;
    uint32_t avg_bps;
    uint16_t block_align;
    uint16_t bits;
    uint16_t cb_size;
    uint8_t extra[64];
    float volume;
    float freq_ratio;
    float max_freq_ratio;
#ifdef SKYRIM_HAVE_FFMPEG
    AVCodecContext *codec_ctx;
    SwrContext *swr_ctx;
    int swr_rate;
    int swr_fmt;
    int swr_ch;
#endif
} XA2SourceMeta;

static XA2SourceMeta source_meta[MAX_SOURCE_VOICES];
static pthread_mutex_t xa2_meta_lock = PTHREAD_MUTEX_INITIALIZER;

static uint32_t vt_xaudio2, vt_master, vt_submix, vt_source, vt_reverb;
static pthread_once_t vt_once = PTHREAD_ONCE_INIT;

static int xa2_log_budget = 24;
static uint32_t xa2_submit_total = 0;
static uint32_t xa2_xwma_submits = 0;

#ifdef SKYRIM_HAVE_FFMPEG
static void xa2_close_ffmpeg(XA2SourceMeta *m) {
    if (m->swr_ctx) {
        swr_free(&m->swr_ctx);
        m->swr_ctx = NULL;
    }
    if (m->codec_ctx) {
        avcodec_free_context(&m->codec_ctx);
        m->codec_ctx = NULL;
    }
    m->swr_rate = 0;
    m->swr_fmt = 0;
    m->swr_ch = 0;
}

static int xa2_ensure_ffmpeg(XA2SourceMeta *m) {
    if (m->codec_ctx) return 0;
    enum AVCodecID cid = AV_CODEC_ID_NONE;
    if (m->fmt_tag == 0x0161) cid = AV_CODEC_ID_WMAV2;
    else if (m->fmt_tag == 0x0162) cid = AV_CODEC_ID_WMAPRO;
    else if (m->fmt_tag == 0x0002) cid = AV_CODEC_ID_ADPCM_MS;
    else if (m->fmt_tag == 0x0011) cid = AV_CODEC_ID_ADPCM_IMA_WAV;
    if (cid == AV_CODEC_ID_NONE) return -1;

    const AVCodec *codec = avcodec_find_decoder(cid);
    if (!codec) return -1;
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) return -1;

    av_channel_layout_default(&ctx->ch_layout, m->channels ? m->channels : 2);
    ctx->sample_rate = (int)(m->sample_rate ? m->sample_rate : 44100);
    ctx->bit_rate = (int64_t)m->avg_bps * 8;
    ctx->block_align = (int)m->block_align;
    ctx->bits_per_coded_sample = (int)m->bits;

    if (cid == AV_CODEC_ID_WMAV2) {
        int sz = m->cb_size >= 6 ? (m->cb_size > 64 ? 64 : m->cb_size) : 6;
        ctx->extradata = (uint8_t *)av_mallocz((size_t)sz + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!ctx->extradata) { avcodec_free_context(&ctx); return -1; }
        ctx->extradata_size = sz;
        if (m->cb_size >= 6) {
            memcpy(ctx->extradata, m->extra, (size_t)sz);
        } else {
            ctx->extradata[4] = 0x1f; // default xWMA WMAv2 flags matching FFmpeg xwma demuxer
        }
    } else if (cid == AV_CODEC_ID_WMAPRO) {
        int sz = m->cb_size >= 18 ? (m->cb_size > 64 ? 64 : m->cb_size) : 18;
        ctx->extradata = (uint8_t *)av_mallocz((size_t)sz + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!ctx->extradata) { avcodec_free_context(&ctx); return -1; }
        ctx->extradata_size = sz;
        if (m->cb_size >= 18)
            memcpy(ctx->extradata, m->extra, (size_t)sz);
    } else if (m->cb_size > 0) {
        int sz = m->cb_size > 64 ? 64 : m->cb_size;
        ctx->extradata = (uint8_t *)av_mallocz((size_t)sz + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!ctx->extradata) { avcodec_free_context(&ctx); return -1; }
        ctx->extradata_size = sz;
        memcpy(ctx->extradata, m->extra, (size_t)sz);
    }

    if (avcodec_open2(ctx, codec, NULL) < 0) {
        avcodec_free_context(&ctx);
        return -1;
    }
    m->codec_ctx = ctx;
    return 0;
}

static int xa2_decode_ffmpeg_buffer(XA2SourceMeta *m, const uint8_t *data, uint32_t bytes,
                                    uint32_t flags, float **out_pcm, unsigned *out_frames) {
    *out_pcm = NULL;
    *out_frames = 0;
    if (xa2_ensure_ffmpeg(m) < 0) return -1;

    AVPacket *pkt = av_packet_alloc();
    AVFrame *frm = av_frame_alloc();
    if (!pkt || !frm) {
        av_packet_free(&pkt);
        av_frame_free(&frm);
        return -1;
    }

    unsigned target_ch = m->channels ? m->channels : 2;
    size_t cap_frames = 4096;
    size_t used_frames = 0;
    float *pcm = (float *)malloc(cap_frames * target_ch * sizeof(float));
    if (!pcm) {
        av_packet_free(&pkt);
        av_frame_free(&frm);
        return -1;
    }

    uint32_t pkt_step = m->block_align ? m->block_align : bytes;
    for (uint32_t off = 0; off < bytes || (off == 0 && bytes == 0); ) {
        int send_rc;
        if (bytes > 0) {
            uint32_t sz = (bytes - off < pkt_step) ? (bytes - off) : pkt_step;
            pkt->data = (uint8_t *)(uintptr_t)(data + off);
            pkt->size = (int)sz;
            send_rc = avcodec_send_packet(m->codec_ctx, pkt);
            off += sz;
        } else {
            send_rc = 0;
        }
        (void)send_rc;

        for (int pass = 0; pass < 2; pass++) {
            if (pass == 1) {
                if (!(flags & 0x40) || off < bytes) break;
                avcodec_send_packet(m->codec_ctx, NULL);
            }
            while (avcodec_receive_frame(m->codec_ctx, frm) == 0) {
                if (!m->swr_ctx || m->swr_rate != frm->sample_rate ||
                    m->swr_fmt != frm->format || m->swr_ch != frm->ch_layout.nb_channels) {
                    if (m->swr_ctx) swr_free(&m->swr_ctx);
                    AVChannelLayout out_layout = {0};
                    av_channel_layout_default(&out_layout, (int)target_ch);
                    if (swr_alloc_set_opts2(&m->swr_ctx,
                                            &out_layout, AV_SAMPLE_FMT_FLT, frm->sample_rate,
                                            &frm->ch_layout, (enum AVSampleFormat)frm->format,
                                            frm->sample_rate, 0, NULL) < 0 ||
                        swr_init(m->swr_ctx) < 0) {
                        if (m->swr_ctx) swr_free(&m->swr_ctx);
                        free(pcm);
                        av_packet_free(&pkt);
                        av_frame_free(&frm);
                        return -1;
                    }
                    m->swr_rate = frm->sample_rate;
                    m->swr_fmt = frm->format;
                    m->swr_ch = frm->ch_layout.nb_channels;
                }
                size_t need = used_frames + (size_t)frm->nb_samples + 256;
                if (need > cap_frames) {
                    while (cap_frames < need) cap_frames *= 2;
                    float *tmp = (float *)realloc(pcm, cap_frames * target_ch * sizeof(float));
                    if (!tmp) {
                        free(pcm);
                        av_packet_free(&pkt);
                        av_frame_free(&frm);
                        return -1;
                    }
                    pcm = tmp;
                }
                uint8_t *dst_ptr = (uint8_t *)(pcm + used_frames * target_ch);
                int got = swr_convert(m->swr_ctx, &dst_ptr, frm->nb_samples + 64,
                                      (const uint8_t *const *)frm->extended_data, frm->nb_samples);
                if (got > 0) used_frames += (size_t)got;
                av_frame_unref(frm);
            }
            if (bytes == 0) break;
        }
        if (bytes == 0) break;
    }

    if (flags & 0x40)
        avcodec_flush_buffers(m->codec_ctx);

    av_packet_free(&pkt);
    av_frame_free(&frm);
    *out_pcm = pcm;
    *out_frames = (unsigned)used_frames;
    return 0;
}
#endif

static int xa2_decode_pcm(const XA2SourceMeta *m, const uint8_t *src, uint32_t bytes,
                          float **out_pcm, unsigned *out_frames) {
    unsigned ch = m->channels ? m->channels : 1;
    unsigned bytes_per_sample = (m->bits ? m->bits : 16) / 8;
    if (!bytes_per_sample || !ch) return -1;
    unsigned frame_bytes = bytes_per_sample * ch;
    unsigned frames = bytes / frame_bytes;
    *out_frames = frames;
    if (frames == 0) {
        *out_pcm = NULL;
        return 0;
    }
    float *pcm = (float *)malloc((size_t)frames * ch * sizeof(float));
    if (!pcm) return -1;

    size_t n_samples = (size_t)frames * ch;
    if (m->fmt_tag == 3 && m->bits == 32) {
        memcpy(pcm, src, n_samples * 4);
        for (size_t i = 0; i < n_samples; i++)
            if (!isfinite(pcm[i])) pcm[i] = 0.0f;
    } else if (m->bits == 8) {
        for (size_t i = 0; i < n_samples; i++)
            pcm[i] = ((int)src[i] - 128) / 128.0f;
    } else if (m->bits == 16) {
        for (size_t i = 0; i < n_samples; i++) {
            int16_t v;
            memcpy(&v, src + i * 2, 2);
            pcm[i] = v / 32768.0f;
        }
    } else if (m->bits == 24) {
        for (size_t i = 0; i < n_samples; i++) {
            const uint8_t *p = src + i * 3;
            int32_t v = (int32_t)((uint32_t)p[0] << 8 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 24);
            pcm[i] = v / 2147483648.0f;
        }
    } else if (m->bits == 32) {
        for (size_t i = 0; i < n_samples; i++) {
            int32_t v;
            memcpy(&v, src + i * 4, 4);
            pcm[i] = v / 2147483648.0f;
        }
    } else {
        free(pcm);
        return -1;
    }
    *out_pcm = pcm;
    return 0;
}

// --- Reverb / Generic IUnknown dummy COM object ---
static void XA2Rev_QueryInterface(CPU *c) {
    uint32_t out = ARG(c, 2);
    if (!out) { RET(c, 0x80004003u, 3); return; }
    uint32_t self = COM_THIS(c);
    P32(self + 4, G32(self + 4) + 1);
    P32(out, self);
    RET(c, 0, 3);
}

// --- IXAudio2 Engine Methods (16 slots) ---
static void XA2_QueryInterface(CPU *c) {
    uint32_t iid = ARG(c, 1), out = ARG(c, 2);
    if (!out) { RET(c, 0x80004003u, 3); return; }
    static const uint8_t iid_iunknown[16] = {0,0,0,0,0,0,0,0,0xc0,0,0,0,0,0,0,0x46};
    static const uint8_t iid_ixaudio2[16] = {0x58,0x1f,0xcf,0x8b,0xe7,0x9f,0x83,0x45,0x8a,0xc6,0xe2,0xad,0xc4,0x65,0xc8,0xbb};
    if (iid && (!memcmp(MEM + iid, iid_iunknown, 16) || !memcmp(MEM + iid, iid_ixaudio2, 16))) {
        uint32_t self = COM_THIS(c);
        P32(self + 4, G32(self + 4) + 1);
        P32(out, self);
        RET(c, 0, 3);
        return;
    }
    P32(out, 0);
    RET(c, 0x80004002u, 3);
}

static void XA2_GetDeviceCount(CPU *c) {
    uint32_t pCount = ARG(c, 1);
    if (pCount) P32(pCount, 1);
    RET(c, 0, 2);
}

static void XA2_GetDeviceDetails(CPU *c) {
    uint32_t idx = ARG(c, 1), pDetails = ARG(c, 2);
    if (!pDetails) { RET(c, 0x80070057u, 3); return; }
    if (idx != 0) { RET(c, 0x88960001u /* XAUDIO2_E_INVALID_CALL */, 3); return; }

    memset(MEM + pDetails, 0, 0x42c);
    static const char dev_name[] = "Default Audio Device";
    for (size_t i = 0; dev_name[i]; i++) {
        xa2_w16(pDetails + 0x000 + (uint32_t)i * 2, (uint16_t)dev_name[i]);
        xa2_w16(pDetails + 0x200 + (uint32_t)i * 2, (uint16_t)dev_name[i]);
    }
    P32(pDetails + 0x400, 0xf); // GlobalDefaultDevice (includes DefaultGameDevice bit 0x8)

    // OutputFormat: 40-byte WAVEFORMATEXTENSIBLE
    uint32_t fmt = pDetails + 0x404;
    xa2_w16(fmt + 0x00, 0xFFFE); // WAVE_FORMAT_EXTENSIBLE
    xa2_w16(fmt + 0x02, 2);      // nChannels
    P32(fmt + 0x04, 48000);      // nSamplesPerSec
    P32(fmt + 0x08, 384000);     // nAvgBytesPerSec
    xa2_w16(fmt + 0x0c, 8);      // nBlockAlign
    xa2_w16(fmt + 0x0e, 32);     // wBitsPerSample
    xa2_w16(fmt + 0x10, 22);     // cbSize
    xa2_w16(fmt + 0x12, 32);     // wValidBitsPerSample
    P32(fmt + 0x14, 3);          // dwChannelMask = SPEAKER_STEREO
    static const uint8_t sub_ieee_float[16] = {
        0x03,0x00,0x00,0x00, 0x00,0x00, 0x10,0x00,
        0x80,0x00, 0x00,0xaa,0x00,0x38,0x9b,0x71
    };
    memcpy(MEM + fmt + 0x18, sub_ieee_float, 16);
    RET(c, 0, 3);
}

static void XA2_Initialize(CPU *c) { RET(c, 0, 3); }
static void XA2_RegisterForCallbacks(CPU *c) {
    if (xa2_log_budget > 0) {
        xa2_log_budget--;
        fprintf(stderr, "[xaudio2] RegisterForCallbacks cb=%#x\n", ARG(c, 1));
    }
    RET(c, 0, 2);
}
static void XA2_UnregisterForCallbacks(CPU *c) { RET(c, 0, 2); }
static void XA2_StartEngine(CPU *c) { RET(c, 0, 1); }
static void XA2_StopEngine(CPU *c) { RET(c, 0, 1); }
static void XA2_CommitChanges(CPU *c) { RET(c, 0, 2); }
static void XA2_GetPerformanceData(CPU *c) {
    uint32_t p = ARG(c, 1);
    if (p) memset(MEM + p, 0, 64);
    RET(c, 0, 2);
}
static void XA2_SetDebugConfiguration(CPU *c) { RET(c, 0, 3); }

static void XA2_CreateMasteringVoice(CPU *c) {
    uint32_t ppVoice = ARG(c, 1);
    uint32_t ch = ARG(c, 2);
    uint32_t rate = ARG(c, 3);
    if (!ppVoice) { RET(c, 0x80070057u, 7); return; }

    fnv_audio_start();
    if (!ch) ch = 2;
    if (!rate) rate = 48000;

    uint32_t v = com_new(vt_master, 12);
    uint32_t d = COM_DATA(v);
    P32(d + VO_KIND, 0);
    P32(d + VO_CH, ch);
    P32(d + VO_RATE, rate);
    P32(ppVoice, v);

    if (xa2_log_budget > 0) {
        xa2_log_budget--;
        fprintf(stderr, "[xaudio2] CreateMasteringVoice ch=%u rate=%u -> %#x\n", ch, rate, v);
    }
    RET(c, 0, 7);
}

static void XA2_CreateSubmixVoice(CPU *c) {
    uint32_t ppVoice = ARG(c, 1);
    uint32_t ch = ARG(c, 2);
    uint32_t rate = ARG(c, 3);
    if (!ppVoice) { RET(c, 0x80070057u, 8); return; }

    if (!ch) ch = 2;
    if (!rate) rate = 48000;
    uint32_t v = com_new(vt_submix, 12);
    uint32_t d = COM_DATA(v);
    P32(d + VO_KIND, 1);
    P32(d + VO_CH, ch);
    P32(d + VO_RATE, rate);
    P32(ppVoice, v);

    if (xa2_log_budget > 0) {
        xa2_log_budget--;
        fprintf(stderr, "[xaudio2] CreateSubmixVoice ch=%u rate=%u -> %#x\n", ch, rate, v);
    }
    RET(c, 0, 8);
}

static void XA2_CreateSourceVoice(CPU *c) {
    uint32_t ppVoice = ARG(c, 1);
    uint32_t pFmt = ARG(c, 2);
    float max_ratio = xa2_argf(c, 4);
    uint32_t pCallback = ARG(c, 5);
    if (!ppVoice || !pFmt) { RET(c, 0x80070057u, 8); return; }

    uint16_t raw_tag = xa2_r16(pFmt + 0x00);
    uint16_t ch = xa2_r16(pFmt + 0x02);
    uint32_t rate = G32(pFmt + 0x04);
    uint32_t avg_bps = G32(pFmt + 0x08);
    uint16_t align = xa2_r16(pFmt + 0x0c);
    uint16_t bits = xa2_r16(pFmt + 0x0e);
    uint16_t cb_size = xa2_r16(pFmt + 0x10);
    uint16_t fmt_tag = raw_tag;
    if (raw_tag == 0xFFFE && cb_size >= 22) {
        uint32_t sub = G32(pFmt + 0x18);
        if (sub == 1 || sub == 3 || sub == 0x0161 || sub == 0x0162)
            fmt_tag = (uint16_t)sub;
    }

    int vid = xa2_voice_alloc(ch ? ch : 1, rate ? rate : 44100);
    if (vid < 0) { RET(c, 0x8007000eu, 8); return; }

    pthread_mutex_lock(&xa2_meta_lock);
    XA2SourceMeta *m = &source_meta[vid];
    memset(m, 0, sizeof *m);
    m->in_use = 1;
    m->fmt_tag = fmt_tag;
    m->channels = ch ? ch : 1;
    m->sample_rate = rate ? rate : 44100;
    m->avg_bps = avg_bps;
    m->block_align = align;
    m->bits = bits;
    m->cb_size = cb_size;
    if (cb_size > 0) {
        uint16_t ncopy = cb_size > sizeof m->extra ? (uint16_t)sizeof m->extra : cb_size;
        memcpy(m->extra, MEM + pFmt + 0x12, ncopy);
    }
    m->volume = 1.0f;
    m->freq_ratio = 1.0f;
    m->max_freq_ratio = max_ratio > 0.0f ? max_ratio : 2.0f;
    pthread_mutex_unlock(&xa2_meta_lock);

    uint32_t v = com_new(vt_source, 8);
    uint32_t d = COM_DATA(v);
    P32(d + VO_KIND, 2);
    P32(d + VO_ID, (uint32_t)vid);
    P32(ppVoice, v);

    if (xa2_log_budget > 0) {
        xa2_log_budget--;
        fprintf(stderr, "[xaudio2] CreateSourceVoice vid=%d fmt=%#x ch=%u rate=%u align=%u bits=%u cb=%u pCb=%#x\n",
                vid, fmt_tag, m->channels, m->sample_rate, align, bits, cb_size, pCallback);
    }
    RET(c, 0, 8);
}

// --- IXAudio2Voice / IXAudio2SourceVoice Methods (29 slots, NO IUnknown) ---
static void V_GetVoiceDetails(CPU *c) {
    uint32_t d = COM_DATA(COM_THIS(c));
    uint32_t p = ARG(c, 1);
    if (p) {
        uint32_t kind = G32(d + VO_KIND);
        uint32_t ch = 2, rate = 48000;
        if (kind == 2) {
            int vid = (int)G32(d + VO_ID);
            pthread_mutex_lock(&xa2_meta_lock);
            if (vid >= 0 && vid < MAX_SOURCE_VOICES && source_meta[vid].in_use) {
                ch = source_meta[vid].channels;
                rate = source_meta[vid].sample_rate;
            }
            pthread_mutex_unlock(&xa2_meta_lock);
        } else {
            ch = G32(d + VO_CH);
            rate = G32(d + VO_RATE);
        }
        P32(p + 0, 0);    // CreationFlags
        P32(p + 4, ch);   // InputChannels
        P32(p + 8, rate); // InputSampleRate
    }
    RET(c, 0, 2);
}

static void V_SetOutputVoices(CPU *c) { RET(c, 0, 2); }
static void V_SetEffectChain(CPU *c) { RET(c, 0, 2); }
static void V_EnableEffect(CPU *c) { RET(c, 0, 3); }
static void V_DisableEffect(CPU *c) { RET(c, 0, 3); }
static void V_GetEffectState(CPU *c) {
    uint32_t p = ARG(c, 2);
    if (p) P32(p, 0);
    RET(c, 0, 3);
}
static void V_SetEffectParameters(CPU *c) { RET(c, 0, 5); }
static void V_GetEffectParameters(CPU *c) { RET(c, 0, 4); }
static void V_SetFilterParameters(CPU *c) { RET(c, 0, 3); }
static void V_GetFilterParameters(CPU *c) {
    uint32_t p = ARG(c, 1);
    if (p) { P32(p, 0); xa2_wf(p + 4, 1.0f); xa2_wf(p + 8, 1.0f); }
    RET(c, 0, 2);
}
static void V_SetOutputFilterParameters(CPU *c) { RET(c, 0, 4); }
static void V_GetOutputFilterParameters(CPU *c) { RET(c, 0, 3); }

static void V_SetVolume(CPU *c) {
    uint32_t d = COM_DATA(COM_THIS(c));
    uint32_t kind = G32(d + VO_KIND);
    float vol = xa2_argf(c, 1);
    if (kind == 0) {
        xa2_voice_set_master_volume(vol);
    } else if (kind == 2) {
        int vid = (int)G32(d + VO_ID);
        xa2_voice_set_volume(vid, vol);
        pthread_mutex_lock(&xa2_meta_lock);
        if (vid >= 0 && vid < MAX_SOURCE_VOICES && source_meta[vid].in_use)
            source_meta[vid].volume = vol;
        pthread_mutex_unlock(&xa2_meta_lock);
    }
    RET(c, 0, 3);
}

static void V_GetVolume(CPU *c) {
    uint32_t d = COM_DATA(COM_THIS(c));
    uint32_t p = ARG(c, 1);
    float vol = 1.0f;
    if (G32(d + VO_KIND) == 2) {
        int vid = (int)G32(d + VO_ID);
        pthread_mutex_lock(&xa2_meta_lock);
        if (vid >= 0 && vid < MAX_SOURCE_VOICES && source_meta[vid].in_use)
            vol = source_meta[vid].volume;
        pthread_mutex_unlock(&xa2_meta_lock);
    }
    if (p) xa2_wf(p, vol);
    RET(c, 0, 2);
}

static void V_SetChannelVolumes(CPU *c) {
    uint32_t d = COM_DATA(COM_THIS(c));
    uint32_t ch = ARG(c, 1), pVols = ARG(c, 2);
    if (G32(d + VO_KIND) == 2 && pVols && ch > 0 && ch <= 8) {
        float vols[8];
        for (uint32_t i = 0; i < ch; i++) vols[i] = xa2_rf(pVols + i * 4);
        xa2_voice_set_channel_volumes((int)G32(d + VO_ID), ch, vols);
    }
    RET(c, 0, 4);
}

static void V_GetChannelVolumes(CPU *c) {
    uint32_t ch = ARG(c, 1), pVols = ARG(c, 2);
    if (pVols) for (uint32_t i = 0; i < ch && i < 8; i++) xa2_wf(pVols + i * 4, 1.0f);
    RET(c, 0, 3);
}

static void V_SetOutputMatrix(CPU *c) {
    uint32_t d = COM_DATA(COM_THIS(c));
    uint32_t pDest = ARG(c, 1);
    uint32_t srcCh = ARG(c, 2), dstCh = ARG(c, 3), pMat = ARG(c, 4);
    if (pDest != 0 && G32(COM_DATA(pDest) + VO_KIND) == 1) { RET(c, 0, 6); return; }
    if (G32(d + VO_KIND) == 2 && pMat && srcCh > 0 && dstCh > 0 && srcCh * dstCh <= 64) {
        float mat[64];
        for (uint32_t i = 0; i < srcCh * dstCh; i++) mat[i] = xa2_rf(pMat + i * 4);
        xa2_voice_set_matrix((int)G32(d + VO_ID), srcCh, dstCh, mat);
    }
    RET(c, 0, 6);
}

static void V_GetOutputMatrix(CPU *c) {
    uint32_t srcCh = ARG(c, 2), dstCh = ARG(c, 3), pMat = ARG(c, 4);
    if (pMat && srcCh * dstCh <= 64)
        for (uint32_t i = 0; i < srcCh * dstCh; i++) xa2_wf(pMat + i * 4, (i / srcCh == i % srcCh) ? 1.0f : 0.0f);
    RET(c, 0, 5);
}

static void V_DestroyVoice(CPU *c) {
    uint32_t d = COM_DATA(COM_THIS(c));
    if (G32(d + VO_KIND) == 2) {
        int vid = (int)G32(d + VO_ID);
        xa2_voice_free(vid);
        pthread_mutex_lock(&xa2_meta_lock);
        if (vid >= 0 && vid < MAX_SOURCE_VOICES && source_meta[vid].in_use) {
#ifdef SKYRIM_HAVE_FFMPEG
            xa2_close_ffmpeg(&source_meta[vid]);
#endif
            memset(&source_meta[vid], 0, sizeof source_meta[vid]);
        }
        pthread_mutex_unlock(&xa2_meta_lock);
    }
    RET(c, 0, 1);
}

static void SV_Start(CPU *c) {
    uint32_t d = COM_DATA(COM_THIS(c));
    if (G32(d + VO_KIND) == 2) xa2_voice_start((int)G32(d + VO_ID));
    RET(c, 0, 3);
}

static void SV_Stop(CPU *c) {
    uint32_t d = COM_DATA(COM_THIS(c));
    if (G32(d + VO_KIND) == 2) xa2_voice_stop((int)G32(d + VO_ID));
    RET(c, 0, 3);
}

static void SV_SubmitSourceBuffer(CPU *c) {
    uint32_t d = COM_DATA(COM_THIS(c));
    uint32_t pBuf = ARG(c, 1);
    if (G32(d + VO_KIND) != 2 || !pBuf) { RET(c, 0x80070057u, 3); return; }

    int vid = (int)G32(d + VO_ID);
    if (vid < 0 || vid >= MAX_SOURCE_VOICES) { RET(c, 0x80070057u, 3); return; }

    uint32_t flags = G32(pBuf + 0x00);
    uint32_t audio_bytes = G32(pBuf + 0x04);
    uint32_t pData = G32(pBuf + 0x08);
    uint32_t play_begin = G32(pBuf + 0x0c);
    uint32_t play_len = G32(pBuf + 0x10);
    uint32_t loop_begin = G32(pBuf + 0x14);
    uint32_t loop_len = G32(pBuf + 0x18);
    uint32_t loop_cnt = G32(pBuf + 0x1c);
    uint32_t context = G32(pBuf + 0x20);

    float *pcm = NULL;
    unsigned frames = 0;
    unsigned ch = 1;
    int rc = 0;

    pthread_mutex_lock(&xa2_meta_lock);
    XA2SourceMeta *m = &source_meta[vid];
    if (!m->in_use) {
        pthread_mutex_unlock(&xa2_meta_lock);
        RET(c, 0x80070057u, 3);
        return;
    }
    ch = m->channels ? m->channels : 1;
    uint16_t fmt = m->fmt_tag;
    int is_compressed = (fmt == 0x0161 || fmt == 0x0162 || fmt == 0x0002 || fmt == 0x0011);

    if (is_compressed) {
#ifdef SKYRIM_HAVE_FFMPEG
        rc = xa2_decode_ffmpeg_buffer(m, pData ? (MEM + pData) : NULL, audio_bytes, flags, &pcm, &frames);
#else
        rc = -1;
#endif
    } else if (audio_bytes > 0 && pData) {
        rc = xa2_decode_pcm(m, MEM + pData, audio_bytes, &pcm, &frames);
    }
    pthread_mutex_unlock(&xa2_meta_lock);

    if (rc == 0) {
        xa2_submit_total++;
        if (is_compressed) xa2_xwma_submits++;
        if (xa2_log_budget > 0 || (xa2_submit_total <= 50 && (xa2_submit_total % 25) == 0)) {
            if (xa2_log_budget > 0) xa2_log_budget--;
            fprintf(stderr, "[xaudio2] SubmitSourceBuffer #%u vid=%d fmt=%#x bytes=%u -> frames=%u loop=%u (xwma=%u)\n",
                    xa2_submit_total, vid, fmt, audio_bytes, frames, loop_cnt, xa2_xwma_submits);
        }
        xa2_voice_submit(vid, pcm, frames, ch, play_begin, play_len,
                         loop_begin, loop_len, loop_cnt, context);
    } else if (xa2_log_budget > 0) {
        xa2_log_budget--;
        fprintf(stderr, "[xaudio2] SubmitSourceBuffer decode failed vid=%d fmt=%#x bytes=%u\n",
                vid, fmt, audio_bytes);
    }
    free(pcm);
    RET(c, 0, 3);
}

static void SV_FlushSourceBuffers(CPU *c) {
    uint32_t d = COM_DATA(COM_THIS(c));
    if (G32(d + VO_KIND) == 2) {
        int vid = (int)G32(d + VO_ID);
        xa2_voice_flush(vid);
#ifdef SKYRIM_HAVE_FFMPEG
        pthread_mutex_lock(&xa2_meta_lock);
        if (vid >= 0 && vid < MAX_SOURCE_VOICES && source_meta[vid].codec_ctx)
            avcodec_flush_buffers(source_meta[vid].codec_ctx);
        pthread_mutex_unlock(&xa2_meta_lock);
#endif
    }
    RET(c, 0, 1);
}

static void SV_Discontinuity(CPU *c) { RET(c, 0, 1); }

static void SV_ExitLoop(CPU *c) {
    uint32_t d = COM_DATA(COM_THIS(c));
    if (G32(d + VO_KIND) == 2) xa2_voice_exit_loop((int)G32(d + VO_ID));
    RET(c, 0, 2);
}

static void SV_GetState(CPU *c) {
    uint32_t d = COM_DATA(COM_THIS(c));
    uint32_t pState = ARG(c, 1);
    if (pState && G32(d + VO_KIND) == 2) {
        uint32_t ctx = 0, queued = 0;
        uint64_t played = 0;
        xa2_voice_get_state((int)G32(d + VO_ID), &ctx, &queued, &played);
        P32(pState + 0x00, ctx);
        P32(pState + 0x04, queued);
        xa2_w64(pState + 0x08, played);
    } else if (pState) {
        memset(MEM + pState, 0, 16);
    }
    RET(c, 0, 2);
}

static void SV_SetFrequencyRatio(CPU *c) {
    uint32_t d = COM_DATA(COM_THIS(c));
    float ratio = xa2_argf(c, 1);
    if (G32(d + VO_KIND) == 2) {
        int vid = (int)G32(d + VO_ID);
        xa2_voice_set_freq_ratio(vid, ratio);
        pthread_mutex_lock(&xa2_meta_lock);
        if (vid >= 0 && vid < MAX_SOURCE_VOICES && source_meta[vid].in_use)
            source_meta[vid].freq_ratio = ratio;
        pthread_mutex_unlock(&xa2_meta_lock);
    }
    RET(c, 0, 3);
}

static void SV_GetFrequencyRatio(CPU *c) {
    uint32_t d = COM_DATA(COM_THIS(c));
    uint32_t p = ARG(c, 1);
    float ratio = 1.0f;
    if (G32(d + VO_KIND) == 2) {
        int vid = (int)G32(d + VO_ID);
        pthread_mutex_lock(&xa2_meta_lock);
        if (vid >= 0 && vid < MAX_SOURCE_VOICES && source_meta[vid].in_use)
            ratio = source_meta[vid].freq_ratio;
        pthread_mutex_unlock(&xa2_meta_lock);
    }
    if (p) xa2_wf(p, ratio);
    RET(c, 0, 2);
}

static void SV_SetSourceSampleRate(CPU *c) {
    uint32_t d = COM_DATA(COM_THIS(c));
    uint32_t rate = ARG(c, 1);
    if (G32(d + VO_KIND) == 2 && rate >= 100 && rate <= 384000) {
        int vid = (int)G32(d + VO_ID);
        xa2_voice_set_sample_rate(vid, rate);
        pthread_mutex_lock(&xa2_meta_lock);
        if (vid >= 0 && vid < MAX_SOURCE_VOICES && source_meta[vid].in_use)
            source_meta[vid].sample_rate = rate;
        pthread_mutex_unlock(&xa2_meta_lock);
    }
    RET(c, 0, 2);
}

static void init_vtables(void) {
    static const ComMethod rev_m[] = {
        { "QueryInterface", XA2Rev_QueryInterface },
        { "AddRef",         com_AddRef },
        { "Release",        com_Release },
    };
    vt_reverb = com_vtable("XAudio2Reverb", rev_m, 3);

    static const ComMethod xa2_m[] = {
        { "QueryInterface",         XA2_QueryInterface },
        { "AddRef",                 com_AddRef },
        { "Release",                com_Release },
        { "GetDeviceCount",         XA2_GetDeviceCount },
        { "GetDeviceDetails",       XA2_GetDeviceDetails },
        { "Initialize",             XA2_Initialize },
        { "RegisterForCallbacks",   XA2_RegisterForCallbacks },
        { "UnregisterForCallbacks", XA2_UnregisterForCallbacks },
        { "CreateSourceVoice",      XA2_CreateSourceVoice },
        { "CreateSubmixVoice",      XA2_CreateSubmixVoice },
        { "CreateMasteringVoice",   XA2_CreateMasteringVoice },
        { "StartEngine",            XA2_StartEngine },
        { "StopEngine",             XA2_StopEngine },
        { "CommitChanges",          XA2_CommitChanges },
        { "GetPerformanceData",     XA2_GetPerformanceData },
        { "SetDebugConfiguration",  XA2_SetDebugConfiguration },
    };
    vt_xaudio2 = com_vtable("IXAudio2", xa2_m, 16);

    static const ComMethod voice_m[] = {
        { "GetVoiceDetails",           V_GetVoiceDetails },
        { "SetOutputVoices",           V_SetOutputVoices },
        { "SetEffectChain",            V_SetEffectChain },
        { "EnableEffect",              V_EnableEffect },
        { "DisableEffect",             V_DisableEffect },
        { "GetEffectState",            V_GetEffectState },
        { "SetEffectParameters",       V_SetEffectParameters },
        { "GetEffectParameters",       V_GetEffectParameters },
        { "SetFilterParameters",       V_SetFilterParameters },
        { "GetFilterParameters",       V_GetFilterParameters },
        { "SetOutputFilterParameters", V_SetOutputFilterParameters },
        { "GetOutputFilterParameters", V_GetOutputFilterParameters },
        { "SetVolume",                 V_SetVolume },
        { "GetVolume",                 V_GetVolume },
        { "SetChannelVolumes",         V_SetChannelVolumes },
        { "GetChannelVolumes",         V_GetChannelVolumes },
        { "SetOutputMatrix",           V_SetOutputMatrix },
        { "GetOutputMatrix",           V_GetOutputMatrix },
        { "DestroyVoice",              V_DestroyVoice },
        { "Start",                     SV_Start },
        { "Stop",                      SV_Stop },
        { "SubmitSourceBuffer",        SV_SubmitSourceBuffer },
        { "FlushSourceBuffers",        SV_FlushSourceBuffers },
        { "Discontinuity",             SV_Discontinuity },
        { "ExitLoop",                  SV_ExitLoop },
        { "GetState",                  SV_GetState },
        { "SetFrequencyRatio",         SV_SetFrequencyRatio },
        { "GetFrequencyRatio",         SV_GetFrequencyRatio },
        { "SetSourceSampleRate",       SV_SetSourceSampleRate },
    };
    vt_master = com_vtable("IXAudio2MasteringVoice", voice_m, 19);
    vt_submix = com_vtable("IXAudio2SubmixVoice", voice_m, 19);
    vt_source = com_vtable("IXAudio2SourceVoice", voice_m, 29);
}

uint32_t xaudio2_create(uint32_t iid) {
    pthread_once(&vt_once, init_vtables);
    static const uint8_t iid_iunknown[16] = {0,0,0,0,0,0,0,0,0xc0,0,0,0,0,0,0,0x46};
    static const uint8_t iid_ixaudio2[16] = {0x58,0x1f,0xcf,0x8b,0xe7,0x9f,0x83,0x45,0x8a,0xc6,0xe2,0xad,0xc4,0x65,0xc8,0xbb};
    if (!iid || (memcmp(MEM + iid, iid_iunknown, 16) && memcmp(MEM + iid, iid_ixaudio2, 16)))
        return 0;
    uint32_t obj = com_new(vt_xaudio2, 0);
    if (xa2_log_budget > 0) {
        xa2_log_budget--;
        fprintf(stderr, "[xaudio2] CoCreateInstance(IXAudio2) -> %#x\n", obj);
    }
    return obj;
}

uint32_t xaudio2_create_reverb(uint32_t iid) {
    (void)iid;
    pthread_once(&vt_once, init_vtables);
    return com_new(vt_reverb, 0);
}

// --- X3DAudio 1.7 (__cdecl, caller cleans stack -> RET(c, ..., 0)) ---
SHIM(X3DAudioInitialize) {
    uint32_t mask = ARG(c, 0);
    float sos = xa2_argf(c, 1);
    uint32_t inst = ARG(c, 2);
    if (inst) {
        memset(MEM + inst, 0, 20);
        P32(inst + 0x00, mask);
        P32(inst + 0x04, (uint32_t)__builtin_popcount(mask));
        xa2_wf(inst + 0x08, isfinite(sos) && sos > 0.0f ? sos : 343.5f);
    }
    if (xa2_log_budget > 0) {
        xa2_log_budget--;
        fprintf(stderr, "[x3daudio] Initialize mask=%#x sos=%.2f inst=%#x\n", mask, sos, inst);
    }
    RET(c, 0, 0);
}

typedef struct { float x, y, z; } XA2Vec3;

static XA2Vec3 xa2_vread(uint32_t addr) {
    return (XA2Vec3){ xa2_rf(addr), xa2_rf(addr + 4), xa2_rf(addr + 8) };
}
static float xa2_vdot(XA2Vec3 a, XA2Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static XA2Vec3 xa2_vcross(XA2Vec3 a, XA2Vec3 b) {
    return (XA2Vec3){ a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x };
}
static XA2Vec3 xa2_vnorm(XA2Vec3 a, XA2Vec3 fallback) {
    float l = sqrtf(xa2_vdot(a, a));
    if (l > 1e-6f && isfinite(l)) return (XA2Vec3){ a.x / l, a.y / l, a.z / l };
    return fallback;
}

static float eval_distance_curve(uint32_t pCurve, float norm_d, float raw_d, float scaler) {
    if (!pCurve) {
        if (raw_d <= scaler || scaler <= 0.0f) return 1.0f;
        return scaler / raw_d;
    }
    uint32_t pts = G32(pCurve + 0x00);
    uint32_t cnt = G32(pCurve + 0x04);
    if (!pts || cnt == 0) return 1.0f;
    float d = norm_d < 0.0f ? 0.0f : (norm_d > 1.0f ? 1.0f : norm_d);
    if (d <= xa2_rf(pts)) return xa2_rf(pts + 4);
    for (uint32_t i = 1; i < cnt; i++) {
        float d0 = xa2_rf(pts + (i - 1) * 8);
        float d1 = xa2_rf(pts + i * 8);
        if (d <= d1) {
            float v0 = xa2_rf(pts + (i - 1) * 8 + 4);
            float v1 = xa2_rf(pts + i * 8 + 4);
            float span = d1 - d0;
            float t = span > 1e-6f ? (d - d0) / span : 0.0f;
            return v0 + (v1 - v0) * t;
        }
    }
    return xa2_rf(pts + (cnt - 1) * 8 + 4);
}

SHIM(X3DAudioCalculate) {
    uint32_t inst = ARG(c, 0);
    uint32_t pListener = ARG(c, 1);
    uint32_t pEmitter = ARG(c, 2);
    uint32_t flags = ARG(c, 3);
    uint32_t pDSP = ARG(c, 4);
    if (!pListener || !pEmitter || !pDSP) { RET(c, 0, 0); return; }

    XA2Vec3 front = xa2_vnorm(xa2_vread(pListener + 0x00), (XA2Vec3){0, 0, 1});
    XA2Vec3 top   = xa2_vnorm(xa2_vread(pListener + 0x0c), (XA2Vec3){0, 1, 0});
    XA2Vec3 right = xa2_vnorm(xa2_vcross(top, front),     (XA2Vec3){1, 0, 0});
    XA2Vec3 lpos  = xa2_vread(pListener + 0x18);
    XA2Vec3 lvel  = xa2_vread(pListener + 0x24);

    XA2Vec3 epos  = xa2_vread(pEmitter + 0x1c);
    XA2Vec3 evel  = xa2_vread(pEmitter + 0x28);
    float inner_r = xa2_rf(pEmitter + 0x34);
    uint32_t pVolCurve = G32(pEmitter + 0x48);
    float scaler = xa2_rf(pEmitter + 0x5c);
    float doppler_scaler = xa2_rf(pEmitter + 0x60);
    if (!isfinite(scaler) || scaler <= 0.0f) scaler = 1.0f;

    XA2Vec3 delta = { epos.x - lpos.x, epos.y - lpos.y, epos.z - lpos.z };
    float dist = sqrtf(xa2_vdot(delta, delta));
    if (!isfinite(dist)) dist = 0.0f;

    float rx = 0.0f, fx = 1.0f;
    if (dist > 1e-5f) {
        rx = xa2_vdot(delta, right) / dist;
        fx = xa2_vdot(delta, front) / dist;
        if (rx < -1.0f) rx = -1.0f; else if (rx > 1.0f) rx = 1.0f;
        if (fx < -1.0f) fx = -1.0f; else if (fx > 1.0f) fx = 1.0f;
    }
    float angle = acosf(fx);
    float vol = eval_distance_curve(pVolCurve, dist / scaler, dist, scaler);
    if (!isfinite(vol) || vol < 0.0f) vol = 0.0f;

    // Equal-power panning blended toward center inside InnerRadius
    float pan01 = 0.5f * (rx + 1.0f);
    if (inner_r > 1e-4f && dist < inner_r) {
        float t = dist / inner_r;
        pan01 = 0.5f + (pan01 - 0.5f) * t;
    } else if (dist <= 1e-5f) {
        pan01 = 0.5f;
    }
    float theta = pan01 * 1.57079633f;
    float lg = vol * cosf(theta);
    float rg = vol * sinf(theta);

    uint32_t pMat = G32(pDSP + 0x00);
    uint32_t srcCh = G32(pDSP + 0x08);
    uint32_t dstCh = G32(pDSP + 0x0c);
    if ((flags & 0x01) && pMat && srcCh > 0 && dstCh > 0 && srcCh * dstCh <= 64) {
        for (uint32_t i = 0; i < srcCh * dstCh; i++) xa2_wf(pMat + i * 4, 0.0f);
        for (uint32_t s = 0; s < srcCh; s++) {
            float w = 1.0f / (float)srcCh;
            if (dstCh == 1) {
                xa2_wf(pMat + s * 4, vol * w);
            } else {
                // Destination index 0 = Front Left, 1 = Front Right
                xa2_wf(pMat + (0 * srcCh + s) * 4, lg * w);
                xa2_wf(pMat + (1 * srcCh + s) * 4, rg * w);
                if (dstCh >= 6) {
                    float front_w = fx > 0.0f ? fx : 0.0f;
                    float rear_w = fx < 0.0f ? -fx : 0.0f;
                    xa2_wf(pMat + (0 * srcCh + s) * 4, lg * (0.65f + 0.35f * front_w) * w);
                    xa2_wf(pMat + (1 * srcCh + s) * 4, rg * (0.65f + 0.35f * front_w) * w);
                    xa2_wf(pMat + (2 * srcCh + s) * 4, vol * 0.5f * front_w * w);
                    xa2_wf(pMat + (4 * srcCh + s) * 4, lg * rear_w * w);
                    xa2_wf(pMat + (5 * srcCh + s) * 4, rg * rear_w * w);
                }
            }
        }
    }

    if (flags & 0x04) xa2_wf(pDSP + 0x10, 1.0f); // LPFDirectCoefficient
    if (flags & 0x08) xa2_wf(pDSP + 0x14, 1.0f); // LPFReverbCoefficient
    if (flags & 0x10) xa2_wf(pDSP + 0x18, 0.0f); // ReverbLevel
    xa2_wf(pDSP + 0x20, angle);
    xa2_wf(pDSP + 0x24, dist);

    if (flags & 0x20) {
        float sos = inst ? xa2_rf(inst + 0x08) : 343.5f;
        if (!isfinite(sos) || sos <= 0.0f) sos = 343.5f;
        float ev = 0.0f, lv = 0.0f, doppler = 1.0f;
        if (dist > 1e-5f) {
            XA2Vec3 dir = { delta.x / dist, delta.y / dist, delta.z / dist };
            ev = xa2_vdot(evel, dir) * doppler_scaler;
            lv = xa2_vdot(lvel, dir) * doppler_scaler;
            float denom = sos - ev;
            if (fabsf(denom) > 1e-3f) doppler = (sos - lv) / denom;
            if (!isfinite(doppler) || doppler < 0.5f) doppler = 0.5f;
            if (doppler > 2.0f) doppler = 2.0f;
        }
        xa2_wf(pDSP + 0x1c, doppler);
        xa2_wf(pDSP + 0x28, ev);
        xa2_wf(pDSP + 0x2c, lv);
    }
    RET(c, 0, 0);
}

SHIM_TABLE(xaudio_shims,
    E(X3DAudioInitialize) E(X3DAudioCalculate))
