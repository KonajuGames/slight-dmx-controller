/* MP3 decode via minimp3 (CC0). Its own translation unit so minimp3's
   macros never meet stb_vorbis's. */
#if defined(_MSC_VER)
#define _CRT_SECURE_NO_WARNINGS 1
#endif

#include "decode.h"

#include <stdlib.h>
#include <string.h>

#define MINIMP3_IMPLEMENTATION
#define MINIMP3_FLOAT_OUTPUT
#define MINIMP3_NO_STDIO
#include "minimp3.h"
#include "minimp3_ex.h"

int sd_decode_mp3(const uint8_t *data, size_t n, sd_audio *out) {
	mp3dec_t dec;
	mp3dec_file_info_t info;
	memset(&info, 0, sizeof(info));
	if (mp3dec_load_buf(&dec, data, n, &info, NULL, NULL) != 0) {
		free(info.buffer);
		return -1;
	}
	if (!info.buffer || info.channels < 1 || info.hz < 1 || info.samples < info.channels) {
		free(info.buffer);
		return -2;
	}
	out->pcm = info.buffer; /* float, interleaved — owned by the caller now */
	out->channels = info.channels;
	out->rate = info.hz;
	out->frames = (int64_t)(info.samples / (size_t)info.channels);
	return 0;
}

int sd_stream_mp3(const uint8_t *data, size_t n, sd_sink sink, void *ctx) {
	mp3dec_ex_t dec;
	if (mp3dec_ex_open_buf(&dec, data, n, 0) != 0) {
		return -1;
	}
	int ch = dec.info.channels, rate = dec.info.hz;
	if (ch < 1 || rate < 1) {
		mp3dec_ex_close(&dec);
		return -2;
	}
	int64_t total = dec.samples > 0 ? (int64_t)(dec.samples / (uint64_t)ch) : 0;
	enum { CHUNK = 8192 };
	float *buf = (float *)malloc(sizeof(float) * CHUNK * ch);
	if (!buf) {
		mp3dec_ex_close(&dec);
		return -3;
	}
	int rc = 0;
	for (;;) {
		size_t got = mp3dec_ex_read(&dec, buf, (size_t)CHUNK * ch);
		if (got < (size_t)ch) {
			break;
		}
		if (sink(ctx, buf, (int64_t)(got / (size_t)ch), ch, rate, total) != 0) {
			rc = SD_STOPPED;
			break;
		}
	}
	free(buf);
	mp3dec_ex_close(&dec);
	return rc;
}
