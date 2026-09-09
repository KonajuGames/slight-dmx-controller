/* Ogg Vorbis decode via stb_vorbis (public domain). Own translation unit. */
#if defined(_MSC_VER)
#define _CRT_SECURE_NO_WARNINGS 1
#endif

#include "decode.h"

#include <stdlib.h>

#define STB_VORBIS_NO_STDIO
#define STB_VORBIS_NO_PUSHDATA_API
#include "stb_vorbis.c"

int sd_decode_ogg(const uint8_t *data, size_t n, sd_audio *out) {
	int channels = 0, rate = 0;
	short *pcm16 = NULL;
	int frames = stb_vorbis_decode_memory((const unsigned char *)data, (int)n,
			&channels, &rate, &pcm16);
	if (frames < 0 || !pcm16 || channels < 1 || rate < 1) {
		free(pcm16);
		return -1;
	}
	size_t total = (size_t)frames * (size_t)channels;
	float *f = (float *)malloc(total * sizeof(float));
	if (!f) {
		free(pcm16);
		return -2;
	}
	for (size_t i = 0; i < total; i++) {
		f[i] = (float)pcm16[i] * (1.0f / 32768.0f);
	}
	free(pcm16);
	out->pcm = f;
	out->channels = channels;
	out->rate = rate;
	out->frames = frames;
	return 0;
}
