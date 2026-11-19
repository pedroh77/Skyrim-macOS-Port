#pragma once
#include <stdint.h>
#include <stddef.h>
// Native playback only: no guest code is called from the audio render callback.
int fnv_audio_start(void);
void fnv_media_active(int active);
uint32_t fnv_audio_voice_create(uint32_t bytes,unsigned channels,unsigned rate,unsigned bits,unsigned format);
uint32_t fnv_audio_voice_duplicate(uint32_t voice);
int fnv_audio_voice_destroy(uint32_t voice); // true when the final shared buffer owner is released
void fnv_audio_voice_write(uint32_t voice,uint32_t offset,const void *data,uint32_t bytes);
void fnv_audio_voice_play(uint32_t voice,int loop);
void fnv_audio_voice_stop(uint32_t voice);
void fnv_audio_voice_seek(uint32_t voice,uint32_t byte_offset);
uint32_t fnv_audio_voice_cursor(uint32_t voice,int *playing,int *loop);
void fnv_audio_voice_volume(uint32_t voice,int hundredth_db);
void fnv_audio_voice_pan(uint32_t voice,int hundredth_db);
void fnv_audio_voice_frequency(uint32_t voice,unsigned hz);
void fnv_audio_master_volume(int hundredth_db);
void fnv_audio_mix(float *left,float *right,unsigned frames,double output_rate);
int xa2_voice_alloc(unsigned channels, unsigned sample_rate);
void xa2_voice_free(int v);
void xa2_voice_set_volume(int v, float vol);
void xa2_voice_set_master_volume(float vol);
void xa2_voice_set_channel_volumes(int v, unsigned channels, const float *vols);
void xa2_voice_set_matrix(int v, unsigned src_ch, unsigned dst_ch, const float *matrix);
void xa2_voice_set_freq_ratio(int v, float ratio);
void xa2_voice_set_sample_rate(int v, unsigned sample_rate);
void xa2_voice_start(int v);
void xa2_voice_stop(int v);
void xa2_voice_flush(int v);
void xa2_voice_exit_loop(int v);
int xa2_voice_submit(int v, const float *pcm, unsigned frames, unsigned channels,
                     unsigned play_begin, unsigned play_length,
                     unsigned loop_begin, unsigned loop_length,
                     unsigned loop_count, uint32_t context);
void xa2_voice_get_state(int v, uint32_t *out_context, uint32_t *out_queued, uint64_t *out_samples_played);
// Preconverted, owner-local movie cache decoded by AVFoundation. The original Bink file is preserved.
uintptr_t fnv_video_open(const char *path);
double fnv_video_time(uintptr_t movie);
int fnv_video_decode(uintptr_t movie,unsigned frame);
int fnv_video_copy(uintptr_t movie,void *destination,int pitch,unsigned destination_height,
                   unsigned dx,unsigned dy,unsigned sx,unsigned sy,unsigned width,unsigned height,unsigned format);
void fnv_video_pause(uintptr_t movie,int paused);
void fnv_video_close(uintptr_t movie);
