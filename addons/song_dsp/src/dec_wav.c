/* WAV decode — plain RIFF parsing, no library. Handles PCM (8/16/24/32-bit
   integer) and IEEE float, mono or multi-channel, incl. WAVE_FORMAT_EXTENSIBLE. */
#include "decode.h"

#include <stdlib.h>
#include <string.h>

static uint32_t rd_u32(const uint8_t *p) {
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint16_t rd_u16(const uint8_t *p) {
	return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

void sd_audio_free(sd_audio *a) {
	if (a && a->pcm) {
		free(a->pcm);
		a->pcm = NULL;
	}
}

int sd_decode_wav(const uint8_t *d, size_t n, sd_audio *out) {
	if (n < 44 || memcmp(d, "RIFF", 4) != 0 || memcmp(d + 8, "WAVE", 4) != 0) {
		return -1;
	}
	uint16_t fmt = 0, ch = 0, bits = 0;
	uint32_t rate = 0;
	const uint8_t *data = NULL;
	size_t data_len = 0;

	size_t pos = 12;
	while (pos + 8 <= n) {
		const uint8_t *id = d + pos;
		uint32_t sz = rd_u32(d + pos + 4);
		const uint8_t *body = d + pos + 8;
		if (sz > n - pos - 8) {
			sz = (uint32_t)(n - pos - 8);
		}
		if (memcmp(id, "fmt ", 4) == 0 && sz >= 16) {
			fmt = rd_u16(body);
			ch = rd_u16(body + 2);
			rate = rd_u32(body + 4);
			bits = rd_u16(body + 14);
			if (fmt == 0xFFFE && sz >= 26) {
				fmt = rd_u16(body + 24); /* extensible: first 2 bytes of the subformat GUID */
			}
		} else if (memcmp(id, "data", 4) == 0) {
			data = body;
			data_len = sz;
		}
		pos += 8 + sz + (sz & 1u); /* chunks are word-aligned */
	}

	if (!data || ch == 0 || rate == 0 || bits == 0) {
		return -2;
	}
	if (fmt != 1 && fmt != 3) {
		return -3; /* not PCM or IEEE float */
	}
	int bytes = bits / 8;
	if (bytes < 1) {
		return -3;
	}
	int64_t frames = (int64_t)(data_len / ((size_t)bytes * ch));
	if (frames < 1) {
		return -4;
	}
	size_t total = (size_t)frames * ch;
	float *f = (float *)malloc(total * sizeof(float));
	if (!f) {
		return -5;
	}
	for (size_t i = 0; i < total; i++) {
		const uint8_t *s = data + i * (size_t)bytes;
		float v = 0.0f;
		if (fmt == 3) {
			if (bits == 64) {
				double dv;
				memcpy(&dv, s, 8);
				v = (float)dv;
			} else {
				memcpy(&v, s, 4);
			}
		} else if (bits == 8) {
			v = ((int)s[0] - 128) * (1.0f / 128.0f);
		} else if (bits == 16) {
			v = (int16_t)rd_u16(s) * (1.0f / 32768.0f);
		} else if (bits == 24) {
			uint32_t u = ((uint32_t)s[0] << 8) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 24);
			v = (float)((int32_t)u >> 8) * (1.0f / 8388608.0f);
		} else if (bits == 32) {
			v = (float)(int32_t)rd_u32(s) * (1.0f / 2147483648.0f);
		} else {
			free(f);
			return -3;
		}
		f[i] = v;
	}
	out->pcm = f;
	out->channels = ch;
	out->rate = (int)rate;
	out->frames = frames;
	return 0;
}
