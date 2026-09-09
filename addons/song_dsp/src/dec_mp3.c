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
