// DirectSound PCM buffers mixed into native float stereo. All decoding remains on game workers.
#include "FNVNativeMedia.h"
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define MAX_VOICES 4096
#define MAX_XA2_VOICES 512
#define XA2_QUEUE_CAP 64
#define XA2_MAX_CH 8
typedef struct {uint8_t *data;uint32_t bytes,refs;unsigned channels,rate,bits,format,alignment;} PCM;
typedef struct {PCM *pcm;double frame;unsigned frequency;float left,right;int volume,pan,playing,loop;} Voice;
static Voice *voices[MAX_VOICES];
static pthread_mutex_t audio_lock=PTHREAD_MUTEX_INITIALIZER;
static float master_gain=1;
static float gain(int db){return db<=-10000?0:powf(10.0f,fminf(0,db)/2000.0f);}
static void gains(Voice *v){v->left=gain(v->volume)*gain(v->pan>0?-v->pan:0);v->right=gain(v->volume)*gain(v->pan<0?v->pan:0);}
static uint32_t add(Voice *v){for(uint32_t i=1;i<MAX_VOICES;i++)if(!voices[i]){voices[i]=v;return i;}return 0;}
static Voice *get(uint32_t id){return id<MAX_VOICES?voices[id]:NULL;}
uint32_t fnv_audio_voice_create(uint32_t bytes,unsigned channels,unsigned rate,unsigned bits,unsigned format){
    if(!bytes || bytes>64u*1024*1024 || channels<1 || channels>2 || rate<100 || rate>200000 ||
       !((format==1&&(bits==8||bits==16||bits==24||bits==32))||(format==3&&bits==32)))return 0;
    PCM *p=calloc(1,sizeof *p);Voice *v=calloc(1,sizeof *v);
    if(!p||!v){free(p);free(v);return 0;}
    p->data=calloc(1,bytes);if(!p->data){free(p);free(v);return 0;}
    p->bytes=bytes;p->refs=1;p->channels=channels;p->rate=rate;p->bits=bits;p->format=format;p->alignment=channels*(bits/8);
    if(format==1&&bits==8)memset(p->data,128,bytes);
    v->pcm=p;v->frequency=rate;gains(v);
    pthread_mutex_lock(&audio_lock);uint32_t id=add(v);pthread_mutex_unlock(&audio_lock);
    if(!id){free(p->data);free(p);free(v);}return id;
}
uint32_t fnv_audio_voice_duplicate(uint32_t id){
    uint32_t copy=0;pthread_mutex_lock(&audio_lock);Voice *old=get(id);
    if(old){Voice *v=malloc(sizeof *v);if(v){*v=*old;v->frame=0;v->playing=0;copy=add(v);if(copy)v->pcm->refs++;else free(v);}}
    pthread_mutex_unlock(&audio_lock);return copy;
}
int fnv_audio_voice_destroy(uint32_t id){
    int last=0;pthread_mutex_lock(&audio_lock);Voice *v=get(id);
    if(v){voices[id]=NULL;if(!--v->pcm->refs){free(v->pcm->data);free(v->pcm);last=1;}free(v);}
    pthread_mutex_unlock(&audio_lock);return last;
}
void fnv_audio_voice_write(uint32_t id,uint32_t offset,const void *data,uint32_t bytes){
    pthread_mutex_lock(&audio_lock);Voice *v=get(id);
    if(v&&offset<v->pcm->bytes){if(bytes>v->pcm->bytes-offset)bytes=v->pcm->bytes-offset;memcpy(v->pcm->data+offset,data,bytes);}
    pthread_mutex_unlock(&audio_lock);
}
void fnv_audio_voice_play(uint32_t id,int loop){pthread_mutex_lock(&audio_lock);Voice *v=get(id);if(v){v->playing=1;v->loop=!!loop;}pthread_mutex_unlock(&audio_lock);}
void fnv_audio_voice_stop(uint32_t id){pthread_mutex_lock(&audio_lock);Voice *v=get(id);if(v)v->playing=0;pthread_mutex_unlock(&audio_lock);}
void fnv_audio_voice_seek(uint32_t id,uint32_t offset){pthread_mutex_lock(&audio_lock);Voice *v=get(id);if(v)v->frame=(offset%v->pcm->bytes)/v->pcm->alignment;pthread_mutex_unlock(&audio_lock);}
uint32_t fnv_audio_voice_cursor(uint32_t id,int *playing,int *loop){
    uint32_t cursor=0;pthread_mutex_lock(&audio_lock);Voice *v=get(id);
    if(v){cursor=(uint32_t)v->frame*v->pcm->alignment;if(playing)*playing=v->playing;if(loop)*loop=v->loop;}
    else{if(playing)*playing=0;if(loop)*loop=0;}pthread_mutex_unlock(&audio_lock);return cursor;
}
void fnv_audio_voice_volume(uint32_t id,int db){pthread_mutex_lock(&audio_lock);Voice *v=get(id);if(v){v->volume=db;gains(v);}pthread_mutex_unlock(&audio_lock);}
void fnv_audio_voice_pan(uint32_t id,int db){pthread_mutex_lock(&audio_lock);Voice *v=get(id);if(v){v->pan=db;gains(v);}pthread_mutex_unlock(&audio_lock);}
void fnv_audio_voice_frequency(uint32_t id,unsigned hz){pthread_mutex_lock(&audio_lock);Voice *v=get(id);if(v)v->frequency=hz?hz:v->pcm->rate;pthread_mutex_unlock(&audio_lock);}
void fnv_audio_master_volume(int db){pthread_mutex_lock(&audio_lock);master_gain=gain(db);pthread_mutex_unlock(&audio_lock);}
static float sample(const PCM *p,uint32_t frame,unsigned channel){
    const uint8_t *s=p->data+(size_t)frame*p->alignment+(channel<p->channels?channel:0)*(p->bits/8);
    if(p->format==3){float f;memcpy(&f,s,4);return isfinite(f)?f:0;}
    if(p->bits==8)return ((int)*s-128)/128.0f;
    if(p->bits==16){int16_t v;memcpy(&v,s,2);return v/32768.0f;}
    if(p->bits==24){int32_t v=(int32_t)((uint32_t)s[0]<<8|(uint32_t)s[1]<<16|(uint32_t)s[2]<<24);return v/2147483648.0f;}
    int32_t v;memcpy(&v,s,4);return v/2147483648.0f;
}
typedef struct {
    float *pcm;
    unsigned frames, channels;
    unsigned play_begin, play_end;
    unsigned loop_begin, loop_end;
    unsigned loop_count, loops_done, exit_loop;
    uint32_t context;
    double pos;
} XA2Buffer;

typedef struct {
    int used, playing;
    unsigned channels, sample_rate;
    float volume, freq_ratio;
    float ch_vol[XA2_MAX_CH], mat_l[XA2_MAX_CH], mat_r[XA2_MAX_CH];
    uint64_t samples_played, last_step_ns;
    double samples_frac;
    unsigned head, count;
    XA2Buffer q[XA2_QUEUE_CAP];
} XA2Voice;

static XA2Voice xa2_voices[MAX_XA2_VOICES];
static float xa2_master_vol = 1.0f;
static uint64_t xa2_last_mix_ns = 0;

static uint64_t monotonic_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void xa2_set_default_matrix(XA2Voice *v, unsigned ch) {
    for (unsigned i = 0; i < XA2_MAX_CH; i++) {
        v->ch_vol[i] = 1.0f;
        v->mat_l[i] = 0.0f;
        v->mat_r[i] = 0.0f;
    }
    if (ch == 1) {
        v->mat_l[0] = 0.707107f;
        v->mat_r[0] = 0.707107f;
    } else if (ch == 2) {
        v->mat_l[0] = 1.0f;
        v->mat_r[1] = 1.0f;
    } else if (ch >= 6) {
        v->mat_l[0] = 1.0f;
        v->mat_r[1] = 1.0f;
        v->mat_l[2] = 0.707107f;
        v->mat_r[2] = 0.707107f;
        v->mat_l[3] = 0.5f;
        v->mat_r[3] = 0.5f;
        v->mat_l[4] = 0.707107f;
        v->mat_r[5] = 0.707107f;
    } else {
        for (unsigned i = 0; i < ch && i < XA2_MAX_CH; i++) {
            v->mat_l[i] = (i & 1) ? 0.0f : 0.707107f;
            v->mat_r[i] = (i & 1) ? 0.707107f : 0.0f;
        }
    }
}

static void xa2_clear_queue_locked(XA2Voice *v) {
    for (unsigned i = 0; i < v->count; i++) {
        XA2Buffer *b = &v->q[(v->head + i) % XA2_QUEUE_CAP];
        free(b->pcm);
        b->pcm = NULL;
    }
    v->head = 0;
    v->count = 0;
}

static void xa2_pop_head_locked(XA2Voice *v) {
    XA2Buffer *b = &v->q[v->head];
    free(b->pcm);
    b->pcm = NULL;
    v->head = (v->head + 1) % XA2_QUEUE_CAP;
    v->count--;
}

static int xa2_buf_can_loop(const XA2Buffer *b) {
    return b->loop_count > 0 && !b->exit_loop &&
           (b->loop_count == 255 || b->loops_done < b->loop_count) &&
           b->loop_end > b->loop_begin;
}

static int xa2_advance_head_locked(XA2Voice *v) {
    while (v->count > 0) {
        XA2Buffer *b = &v->q[v->head];
        if (!b->pcm || b->frames == 0 || b->play_begin >= b->play_end) {
            xa2_pop_head_locked(v);
            continue;
        }
        int loop = xa2_buf_can_loop(b);
        double end_pos = loop ? (double)b->loop_end : (double)b->play_end;
        if (b->pos >= end_pos) {
            if (loop) {
                double span = (double)(b->loop_end - b->loop_begin);
                b->pos = (double)b->loop_begin + fmod(b->pos - end_pos, span);
                b->loops_done++;
                continue;
            }
            if (b->pos >= (double)b->play_end) {
                xa2_pop_head_locked(v);
                continue;
            }
        }
        return 1;
    }
    return 0;
}

static void xa2_advance_voice_locked(XA2Voice *v, unsigned mix_frames, double mix_rate,
                                     float *left, float *right, uint64_t now_ns) {
    v->last_step_ns = now_ns;
    if (!v->used || !v->playing || v->count == 0 || mix_rate <= 0.0 || mix_frames == 0)
        return;

    double rate = (double)(v->sample_rate ? v->sample_rate : 48000);
    double ratio = (double)(v->freq_ratio > 0.0f ? v->freq_ratio : 1.0f);
    double step = (rate * ratio) / mix_rate;

    for (unsigned i = 0; i < mix_frames; i++) {
        if (!xa2_advance_head_locked(v))
            break;
        XA2Buffer *b = &v->q[v->head];
        if (left && right) {
            int loop = xa2_buf_can_loop(b);
            unsigned end_u = loop ? b->loop_end : b->play_end;
            if (end_u > b->frames)
                end_u = b->frames;
            unsigned a = (unsigned)b->pos;
            if (a >= b->frames)
                a = b->frames - 1;
            unsigned a1 = (a + 1 < end_u) ? (a + 1) : (loop ? b->loop_begin : a);
            if (a1 >= b->frames)
                a1 = a;
            float frac = (float)(b->pos - (double)a);
            if (frac < 0.0f) frac = 0.0f;
            if (frac > 1.0f) frac = 1.0f;
            unsigned ch = b->channels < XA2_MAX_CH ? b->channels : XA2_MAX_CH;
            float l = 0.0f, r = 0.0f;
            for (unsigned c = 0; c < ch; c++) {
                float s0 = b->pcm[(size_t)a * b->channels + c];
                float s1 = b->pcm[(size_t)a1 * b->channels + c];
                float s = s0 + (s1 - s0) * frac;
                float g = s * v->ch_vol[c] * v->volume * xa2_master_vol * master_gain;
                l += g * v->mat_l[c];
                r += g * v->mat_r[c];
            }
            left[i] += l;
            right[i] += r;
        }
        b->pos += step;
        v->samples_frac += step;
        if (v->samples_frac >= 1.0) {
            uint64_t whole = (uint64_t)v->samples_frac;
            v->samples_played += whole;
            v->samples_frac -= (double)whole;
        }
    }
    xa2_advance_head_locked(v);
}

int xa2_voice_alloc(unsigned channels, unsigned sample_rate) {
    if (channels < 1) channels = 1;
    if (channels > XA2_MAX_CH) channels = XA2_MAX_CH;
    if (sample_rate < 100 || sample_rate > 384000) sample_rate = 48000;
    pthread_mutex_lock(&audio_lock);
    int found = -1;
    for (int i = 0; i < MAX_XA2_VOICES; i++) {
        if (!xa2_voices[i].used) {
            XA2Voice *v = &xa2_voices[i];
            memset(v, 0, sizeof *v);
            v->used = 1;
            v->channels = channels;
            v->sample_rate = sample_rate;
            v->volume = 1.0f;
            v->freq_ratio = 1.0f;
            v->last_step_ns = monotonic_ns();
            xa2_set_default_matrix(v, channels);
            found = i;
            break;
        }
    }
    pthread_mutex_unlock(&audio_lock);
    return found;
}

void xa2_voice_free(int id) {
    if (id < 0 || id >= MAX_XA2_VOICES) return;
    pthread_mutex_lock(&audio_lock);
    XA2Voice *v = &xa2_voices[id];
    if (v->used) {
        xa2_clear_queue_locked(v);
        memset(v, 0, sizeof *v);
    }
    pthread_mutex_unlock(&audio_lock);
}

void xa2_voice_set_volume(int id, float vol) {
    if (id < 0 || id >= MAX_XA2_VOICES || !isfinite(vol)) return;
    pthread_mutex_lock(&audio_lock);
    if (xa2_voices[id].used) xa2_voices[id].volume = vol;
    pthread_mutex_unlock(&audio_lock);
}

void xa2_voice_set_master_volume(float vol) {
    if (!isfinite(vol)) return;
    pthread_mutex_lock(&audio_lock);
    xa2_master_vol = vol;
    pthread_mutex_unlock(&audio_lock);
}

void xa2_voice_set_channel_volumes(int id, unsigned channels, const float *vols) {
    if (id < 0 || id >= MAX_XA2_VOICES || !vols) return;
    pthread_mutex_lock(&audio_lock);
    XA2Voice *v = &xa2_voices[id];
    if (v->used) {
        unsigned n = channels < XA2_MAX_CH ? channels : XA2_MAX_CH;
        for (unsigned i = 0; i < n; i++)
            if (isfinite(vols[i])) v->ch_vol[i] = vols[i];
    }
    pthread_mutex_unlock(&audio_lock);
}

void xa2_voice_set_matrix(int id, unsigned src_ch, unsigned dst_ch, const float *matrix) {
    if (id < 0 || id >= MAX_XA2_VOICES || !matrix || src_ch == 0 || dst_ch == 0) return;
    pthread_mutex_lock(&audio_lock);
    XA2Voice *v = &xa2_voices[id];
    if (v->used) {
        unsigned s_max = src_ch < XA2_MAX_CH ? src_ch : XA2_MAX_CH;
        for (unsigned s = 0; s < s_max; s++) {
            float l = 0.0f, r = 0.0f;
            if (dst_ch == 1) {
                l = r = matrix[s];
            } else if (dst_ch == 2) {
                l = matrix[0 * src_ch + s];
                r = matrix[1 * src_ch + s];
            } else if (dst_ch == 4) {
                l = matrix[0 * src_ch + s] + 0.707107f * matrix[2 * src_ch + s];
                r = matrix[1 * src_ch + s] + 0.707107f * matrix[3 * src_ch + s];
            } else if (dst_ch >= 6) {
                l = matrix[0 * src_ch + s] + 0.707107f * matrix[2 * src_ch + s] +
                    0.5f * matrix[3 * src_ch + s] + 0.707107f * matrix[4 * src_ch + s];
                r = matrix[1 * src_ch + s] + 0.707107f * matrix[2 * src_ch + s] +
                    0.5f * matrix[3 * src_ch + s] + 0.707107f * matrix[5 * src_ch + s];
            } else {
                l = matrix[0 * src_ch + s];
                r = matrix[1 * src_ch + s];
            }
            v->mat_l[s] = isfinite(l) ? l : 0.0f;
            v->mat_r[s] = isfinite(r) ? r : 0.0f;
        }
    }
    pthread_mutex_unlock(&audio_lock);
}

void xa2_voice_set_freq_ratio(int id, float ratio) {
    if (id < 0 || id >= MAX_XA2_VOICES || !isfinite(ratio) || ratio <= 0.0f) return;
    pthread_mutex_lock(&audio_lock);
    if (xa2_voices[id].used) xa2_voices[id].freq_ratio = ratio;
    pthread_mutex_unlock(&audio_lock);
}

void xa2_voice_set_sample_rate(int id, unsigned sample_rate) {
    if (id < 0 || id >= MAX_XA2_VOICES || sample_rate < 100 || sample_rate > 384000) return;
    pthread_mutex_lock(&audio_lock);
    if (xa2_voices[id].used) xa2_voices[id].sample_rate = sample_rate;
    pthread_mutex_unlock(&audio_lock);
}

void xa2_voice_start(int id) {
    if (id < 0 || id >= MAX_XA2_VOICES) return;
    pthread_mutex_lock(&audio_lock);
    if (xa2_voices[id].used) {
        xa2_voices[id].playing = 1;
        xa2_voices[id].last_step_ns = monotonic_ns();
    }
    pthread_mutex_unlock(&audio_lock);
}

void xa2_voice_stop(int id) {
    if (id < 0 || id >= MAX_XA2_VOICES) return;
    pthread_mutex_lock(&audio_lock);
    if (xa2_voices[id].used) xa2_voices[id].playing = 0;
    pthread_mutex_unlock(&audio_lock);
}

void xa2_voice_flush(int id) {
    if (id < 0 || id >= MAX_XA2_VOICES) return;
    pthread_mutex_lock(&audio_lock);
    if (xa2_voices[id].used) xa2_clear_queue_locked(&xa2_voices[id]);
    pthread_mutex_unlock(&audio_lock);
}

void xa2_voice_exit_loop(int id) {
    if (id < 0 || id >= MAX_XA2_VOICES) return;
    pthread_mutex_lock(&audio_lock);
    XA2Voice *v = &xa2_voices[id];
    if (v->used && v->count > 0)
        v->q[v->head].exit_loop = 1;
    pthread_mutex_unlock(&audio_lock);
}

int xa2_voice_submit(int id, const float *pcm, unsigned frames, unsigned channels,
                     unsigned play_begin, unsigned play_length,
                     unsigned loop_begin, unsigned loop_length,
                     unsigned loop_count, uint32_t context) {
    if (id < 0 || id >= MAX_XA2_VOICES) return -1;
    if (channels < 1) channels = 1;
    if (channels > XA2_MAX_CH) channels = XA2_MAX_CH;

    float *copy = NULL;
    if (pcm && frames > 0) {
        size_t bytes = (size_t)frames * channels * sizeof(float);
        copy = (float *)malloc(bytes);
        if (!copy) return -1;
        memcpy(copy, pcm, bytes);
    }

    unsigned p_begin = play_begin < frames ? play_begin : frames;
    unsigned p_end = (play_length == 0 || p_begin + play_length > frames) ? frames : (p_begin + play_length);
    unsigned l_begin = loop_begin < frames ? loop_begin : 0;
    unsigned l_end = (loop_length == 0 || l_begin + loop_length > p_end) ? p_end : (l_begin + loop_length);

    pthread_mutex_lock(&audio_lock);
    XA2Voice *v = &xa2_voices[id];
    if (!v->used || v->count >= XA2_QUEUE_CAP) {
        pthread_mutex_unlock(&audio_lock);
        free(copy);
        return -1;
    }
    XA2Buffer *b = &v->q[(v->head + v->count) % XA2_QUEUE_CAP];
    memset(b, 0, sizeof *b);
    b->pcm = copy;
    b->frames = copy ? frames : 0;
    b->channels = channels;
    b->play_begin = p_begin;
    b->play_end = p_end;
    b->loop_begin = l_begin;
    b->loop_end = l_end;
    b->loop_count = loop_count;
    b->context = context;
    b->pos = (double)p_begin;
    v->count++;
    pthread_mutex_unlock(&audio_lock);
    return 0;
}

void xa2_voice_get_state(int id, uint32_t *out_context, uint32_t *out_queued, uint64_t *out_samples_played) {
    uint32_t ctx = 0, queued = 0;
    uint64_t played = 0;
    if (id >= 0 && id < MAX_XA2_VOICES) {
        uint64_t now = monotonic_ns();
        pthread_mutex_lock(&audio_lock);
        XA2Voice *v = &xa2_voices[id];
        if (v->used) {
            if (v->playing && v->count > 0 &&
                (xa2_last_mix_ns == 0 || now - xa2_last_mix_ns > 80000000ULL)) {
                uint64_t dt_ns = now > v->last_step_ns ? (now - v->last_step_ns) : 0;
                if (dt_ns > 50000000ULL) dt_ns = 50000000ULL;
                unsigned sim_frames = (unsigned)((dt_ns * 48000ULL) / 1000000000ULL);
                if (sim_frames > 0)
                    xa2_advance_voice_locked(v, sim_frames, 48000.0, NULL, NULL, now);
            }
            if (v->count > 0)
                ctx = v->q[v->head].context;
            queued = v->count;
            played = v->samples_played;
        }
        pthread_mutex_unlock(&audio_lock);
    }
    if (out_context) *out_context = ctx;
    if (out_queued) *out_queued = queued;
    if (out_samples_played) *out_samples_played = played;
}

void fnv_audio_mix(float *left,float *right,unsigned frames,double rate){
    memset(left,0,frames*sizeof *left);memset(right,0,frames*sizeof *right);
    if(rate<=0 || pthread_mutex_trylock(&audio_lock))return; // audio thread never waits for guest writes
    uint64_t now = monotonic_ns();
    xa2_last_mix_ns = now;
    for(unsigned id=1;id<MAX_VOICES;id++){
        Voice *v=voices[id];if(!v||!v->playing)continue;PCM *p=v->pcm;uint32_t total=p->bytes/p->alignment;
        if(!total){v->playing=0;continue;}double step=v->frequency/rate;
        for(unsigned i=0;i<frames;i++){
            if(v->frame>=total){if(v->loop)v->frame=fmod(v->frame,total);else{v->playing=0;v->frame=0;break;}}
            uint32_t a=(uint32_t)v->frame,b=a+1<total?a+1:v->loop?0:a;float fraction=(float)(v->frame-a);
            float l=sample(p,a,0),r=sample(p,a,p->channels==1?0:1);
            l+=(sample(p,b,0)-l)*fraction;r+=(sample(p,b,p->channels==1?0:1)-r)*fraction;
            left[i]+=l*v->left*master_gain;right[i]+=r*v->right*master_gain;v->frame+=step;
        }
        if(v->frame>=total){if(v->loop)v->frame=fmod(v->frame,total);else{v->playing=0;v->frame=0;}}
    }
    for (int id = 0; id < MAX_XA2_VOICES; id++) {
        if (xa2_voices[id].used && xa2_voices[id].playing)
            xa2_advance_voice_locked(&xa2_voices[id], frames, rate, left, right, now);
    }
    pthread_mutex_unlock(&audio_lock);
    for(unsigned i=0;i<frames;i++){left[i]=fmaxf(-1,fminf(1,left[i]));right[i]=fmaxf(-1,fminf(1,right[i]));}
}
