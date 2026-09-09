/* Minimal C decode API for the song_dsp GDExtension.
   Each sd_decode_* fills `out` with malloc'd interleaved float PCM at the
   file's native rate; the caller must sd_audio_free() it. Returns 0 on
   success, negative on failure. */
#ifndef SONG_DSP_DECODE_H
#define SONG_DSP_DECODE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
	float *pcm;      /* interleaved, channels * frames floats */
	int64_t frames;  /* per-channel sample count */
	int channels;
	int rate;        /* Hz */
} sd_audio;

int sd_decode_mp3(const uint8_t *data, size_t n, sd_audio *out);
int sd_decode_ogg(const uint8_t *data, size_t n, sd_audio *out);
int sd_decode_wav(const uint8_t *data, size_t n, sd_audio *out);
void sd_audio_free(sd_audio *a);

#ifdef __cplusplus
}
#endif

#endif /* SONG_DSP_DECODE_H */
