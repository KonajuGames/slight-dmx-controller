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

/* Streaming decode: `sink` is called with successive chunks of interleaved
   float PCM, so a long track never has to sit in memory whole.
   `total_frames` is the expected per-channel length (0 = unknown) for
   progress. The sink returns nonzero to stop early, in which case the
   decode returns SD_STOPPED. Otherwise 0 on success, negative on failure. */
#define SD_STOPPED 1
#define SD_NO_OS_DECODER (-100)
typedef int (*sd_sink)(void *ctx, const float *pcm, int64_t frames, int channels, int rate,
		int64_t total_frames);

int sd_stream_mp3(const uint8_t *data, size_t n, sd_sink sink, void *ctx);
int sd_stream_ogg(const uint8_t *data, size_t n, sd_sink sink, void *ctx);
int sd_stream_wav(const uint8_t *data, size_t n, sd_sink sink, void *ctx);

/* The OS's own decoder, for formats with no bundled one -- AAC in .m4a /
   .aac / .mp4 in particular: Windows Media Foundation (loaded at run time,
   so Windows "N" editions without it just report SD_NO_OS_DECODER) or
   macOS ExtAudioFile. Elsewhere always SD_NO_OS_DECODER. `path_utf8` is a
   file path; '/' separators are fine. */
int sd_stream_os(const char *path_utf8, sd_sink sink, void *ctx);
int sd_os_decoder_available(void);

#ifdef __cplusplus
}
#endif

#endif /* SONG_DSP_DECODE_H */
