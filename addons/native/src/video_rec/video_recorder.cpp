#include "video_recorder.h"

#include "minih264e.h" // declarations only — the implementation is in codec_impl.c
#include "minimp4.h"
// shine's header has no extern "C" guard of its own (unlike the two
// above), so its C-linkage declarations need one here or the C++ compiler
// mangles the calls while the .c files it's declaring export plain C symbols.
extern "C" {
#include "layer3.h" // shine MP3 encoder's public API
}

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

using namespace godot;

#if defined(_WIN32)
#define REC_FSEEK(f, off) _fseeki64((f), (off), SEEK_SET)
#else
#define REC_FSEEK(f, off) fseeko((f), (off), SEEK_SET)
#endif

// ------------------------------------------------------------ helpers --
namespace {

int mp4_write_cb(int64_t offset, const void *buffer, size_t size, void *token) {
	FILE *f = static_cast<FILE *>(token);
	if (REC_FSEEK(f, offset) != 0) {
		return 1;
	}
	return fwrite(buffer, 1, size, f) != size ? 1 : 0;
}

inline uint8_t clamp8(int v, int lo, int hi) {
	return static_cast<uint8_t>(v < lo ? lo : (v > hi ? hi : v));
}

// RGBA8 -> I420, BT.709 limited range.
void rgba_to_i420(const uint8_t *rgba, int w, int h, uint8_t *out) {
	uint8_t *Y = out;
	uint8_t *U = out + w * h;
	uint8_t *V = U + (w / 2) * (h / 2);

	for (int y = 0; y < h; y++) {
		const uint8_t *row = rgba + static_cast<size_t>(y) * w * 4;
		uint8_t *yr = Y + static_cast<size_t>(y) * w;
		for (int x = 0; x < w; x++) {
			int r = row[x * 4], g = row[x * 4 + 1], b = row[x * 4 + 2];
			yr[x] = clamp8((1826 * r + 6142 * g + 620 * b + 5000) / 10000 + 16, 16, 235);
		}
	}
	for (int y = 0; y < h; y += 2) {
		const uint8_t *r0 = rgba + static_cast<size_t>(y) * w * 4;
		const uint8_t *r1 = rgba + static_cast<size_t>((y + 1 < h) ? y + 1 : y) * w * 4;
		uint8_t *ur = U + static_cast<size_t>(y / 2) * (w / 2);
		uint8_t *vr = V + static_cast<size_t>(y / 2) * (w / 2);
		for (int x = 0; x < w; x += 2) {
			int x1 = (x + 1 < w) ? x + 1 : x;
			int r = (r0[x * 4] + r0[x1 * 4] + r1[x * 4] + r1[x1 * 4] + 2) >> 2;
			int g = (r0[x * 4 + 1] + r0[x1 * 4 + 1] + r1[x * 4 + 1] + r1[x1 * 4 + 1] + 2) >> 2;
			int b = (r0[x * 4 + 2] + r0[x1 * 4 + 2] + r1[x * 4 + 2] + r1[x1 * 4 + 2] + 2) >> 2;
			int u = (-1006 * r - 3386 * g + 4392 * b + 5000) / 10000 + 128;
			int v = (4392 * r - 3989 * g - 403 * b + 5000) / 10000 + 128;
			ur[x / 2] = clamp8(u, 16, 240);
			vr[x / 2] = clamp8(v, 16, 240);
		}
	}
}

} // namespace

struct VideoRecorder::Enc {
	FILE *file = nullptr;
	H264E_persist_t *enc = nullptr;
	H264E_scratch_t *scratch = nullptr;
	MP4E_mux_t *mux = nullptr;
	mp4_h26x_writer_t mp4wr {};
	// double-buffered I420 — const_input_flag=1 keeps the previous frame
	// referenced for inter prediction, so the two buffers alternate.
	std::vector<uint8_t> yuv[2];
	int cur = 0;

	// audio (optional -- only set once start_audio() succeeds)
	shine_t mp3 = nullptr;
	int audio_track = -1;
	int a_rate = 0, a_channels = 0;
	int a_samples_per_pass = 0;        // shine_samples_per_pass(mp3), per channel
	std::vector<int16_t> a_pcm;        // interleaved int16, accumulated until a_samples_per_pass is ready
};

// --------------------------------------------------------------- bind --

void VideoRecorder::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start", "path", "width", "height", "fps", "kbps"), &VideoRecorder::start);
	ClassDB::bind_method(D_METHOD("push_frame", "rgba8"), &VideoRecorder::push_frame);
	ClassDB::bind_method(D_METHOD("start_audio", "sample_rate", "channels"), &VideoRecorder::start_audio);
	ClassDB::bind_method(D_METHOD("push_audio", "interleaved"), &VideoRecorder::push_audio);
	ClassDB::bind_method(D_METHOD("stop"), &VideoRecorder::stop);
	ClassDB::bind_method(D_METHOD("is_recording"), &VideoRecorder::is_recording);
	ClassDB::bind_method(D_METHOD("get_frame_count"), &VideoRecorder::get_frame_count);
	ClassDB::bind_method(D_METHOD("get_dropped"), &VideoRecorder::get_dropped);
	ClassDB::bind_method(D_METHOD("get_status"), &VideoRecorder::get_status);
}

VideoRecorder::VideoRecorder() {}
VideoRecorder::~VideoRecorder() {
	stop();
}

void VideoRecorder::_set_status(const String &s) {
	std::lock_guard<std::mutex> lk(_status_mtx);
	_status = s;
}

String VideoRecorder::get_status() {
	std::lock_guard<std::mutex> lk(_status_mtx);
	return _status;
}

bool VideoRecorder::is_recording() const { return _running.load(); }
int VideoRecorder::get_frame_count() const { return _encoded.load(); }
int VideoRecorder::get_dropped() const { return _dropped.load(); }

// --------------------------------------------------------------- start --

bool VideoRecorder::start(const String &path, int width, int height, int fps, int kbps) {
	stop();

	// Round to a multiple of 16: keeps the I420 chroma stride 8-aligned,
	// which minih264's SSE2 path requires, and avoids padded strides.
	width &= ~15;
	height &= ~15;
	if (width < 16 || height < 16 || width > 8192 || height > 8192) {
		_set_status("unsupported size");
		return false;
	}
	_w = width;
	_h = height;
	_fps = fps < 1 ? 1 : (fps > 120 ? 120 : fps);
	_kbps = kbps < 200 ? 200 : (kbps > 200000 ? 200000 : kbps);

	Enc *e = new Enc();
	e->file = fopen(path.utf8().get_data(), "wb");
	if (!e->file) {
		delete e;
		_set_status("can't create " + path);
		return false;
	}

	H264E_create_param_t cp;
	memset(&cp, 0, sizeof(cp));
	cp.width = _w;
	cp.height = _h;
	cp.gop = _fps * 2;
	cp.num_layers = 1;
	cp.const_input_flag = 1;
	cp.vbv_size_bytes = _kbps * 1000 / 8 * 2;
	cp.max_threads = 0;

	int sizeof_persist = 0, sizeof_scratch = 0;
	if (H264E_sizeof(&cp, &sizeof_persist, &sizeof_scratch) != H264E_STATUS_SUCCESS) {
		fclose(e->file);
		delete e;
		_set_status("encoder rejected the parameters");
		return false;
	}
	e->enc = static_cast<H264E_persist_t *>(std::malloc(sizeof_persist));
	e->scratch = static_cast<H264E_scratch_t *>(std::malloc(sizeof_scratch));
	if (!e->enc || !e->scratch || H264E_init(e->enc, &cp) != H264E_STATUS_SUCCESS) {
		std::free(e->enc);
		std::free(e->scratch);
		fclose(e->file);
		delete e;
		_set_status("encoder init failed");
		return false;
	}

	e->mux = MP4E_open(0, 0, e->file, &mp4_write_cb);
	if (!e->mux || mp4_h26x_write_init(&e->mp4wr, e->mux, _w, _h, 0) != MP4E_STATUS_OK) {
		if (e->mux) {
			MP4E_close(e->mux);
		}
		std::free(e->enc);
		std::free(e->scratch);
		fclose(e->file);
		delete e;
		_set_status("mp4 muxer init failed");
		return false;
	}

	int isz = _w * _h + 2 * (_w / 2) * (_h / 2);
	e->yuv[0].resize(isz);
	e->yuv[1].resize(isz);

	_enc = e;
	_pushed = 0;
	_encoded = 0;
	_dropped = 0;
	_finishing = false;
	_running = true;
	{
		std::lock_guard<std::mutex> lk(_q_mtx);
		_queue.clear();
		_a_queue.clear();
	}
	_thread = std::thread(&VideoRecorder::_worker, this);
	_set_status("recording");
	return true;
}

// --------------------------------------------------------------- frame --

void VideoRecorder::push_frame(const PackedByteArray &rgba8) {
	if (!_running.load() || _finishing.load()) {
		return;
	}
	int need = _w * _h * 4;
	if (rgba8.size() != need) {
		_dropped++;
		return;
	}
	{
		std::lock_guard<std::mutex> lk(_q_mtx);
		if (static_cast<int>(_queue.size()) >= MAX_QUEUE) {
			_dropped++;
			return;
		}
		const uint8_t *p = rgba8.ptr();
		_queue.emplace_back(p, p + need);
	}
	_pushed++;
	_q_cv.notify_one();
}

// --------------------------------------------------------------- audio --

bool VideoRecorder::start_audio(int sample_rate, int channels) {
	if (!_running.load() || _enc == nullptr || _enc->mux == nullptr) {
		return false;
	}
	Enc *e = _enc;
	if (e->mp3 != nullptr) {
		return true; // already started
	}
	channels = (channels == 1) ? 1 : 2;

	shine_config_t cfg;
	memset(&cfg, 0, sizeof(cfg));
	shine_set_config_mpeg_defaults(&cfg.mpeg);
	cfg.wave.samplerate = sample_rate;
	cfg.wave.channels = static_cast<enum channels>(channels);
	cfg.mpeg.mode = (channels == 1) ? MONO : JOINT_STEREO;
	cfg.mpeg.bitr = 192; // good-quality default for a screen-recording soundtrack
	if (shine_find_samplerate_index(sample_rate) < 0 || shine_check_config(sample_rate, cfg.mpeg.bitr) < 0) {
		return false; // e.g. an unusual mix rate shine's Layer III tables don't cover
	}

	shine_t mp3 = shine_initialise(&cfg);
	if (mp3 == nullptr) {
		return false;
	}

	MP4E_track_t tr;
	memset(&tr, 0, sizeof(tr));
	tr.track_media_kind = e_audio;
	// 0x6B == MPEG-1 Part 3 (Layer I/II/III) audio -- the standard MP4RA
	// object type for an MP3 track; unlike AAC it carries no ASC/DSI, each
	// frame is self-describing.
	tr.object_type_indication = 0x6B;
	tr.time_scale = sample_rate;
	tr.default_duration = 0;
	tr.u.a.channelcount = channels;
	int track_id = MP4E_add_track(e->mux, &tr);
	if (track_id < 0) {
		shine_close(mp3);
		return false;
	}
	// Empty on purpose: MP3 has no AAC-style AudioSpecificConfig to carry
	// (each frame's own header is self-describing) -- this call exists only
	// to make minimp4 actually write the esds box's DecoderConfigDescriptor
	// (which is where the real object_type_indication byte lands; see the
	// "LOCAL PATCH" in minimp4.h), since it otherwise skips that whole
	// write path for a track with no DSI at all.
	uint8_t empty_dsi = 0;
	MP4E_set_dsi(e->mux, track_id, &empty_dsi, 0);

	e->mp3 = mp3;
	e->audio_track = track_id;
	e->a_rate = sample_rate;
	e->a_channels = channels;
	e->a_samples_per_pass = shine_samples_per_pass(mp3);
	e->a_pcm.clear();
	return true;
}

void VideoRecorder::push_audio(const PackedFloat32Array &interleaved) {
	if (!_running.load() || _finishing.load() || _enc == nullptr || _enc->mp3 == nullptr) {
		return;
	}
	if (interleaved.size() == 0) {
		return;
	}
	std::vector<float> v(interleaved.ptr(), interleaved.ptr() + interleaved.size());
	{
		std::lock_guard<std::mutex> lk(_q_mtx);
		if (static_cast<int>(_a_queue.size()) >= MAX_A_QUEUE) {
			return; // drop silently -- a gap in the soundtrack beats blocking the caller
		}
		_a_queue.emplace_back(std::move(v));
	}
	_q_cv.notify_one();
}

void VideoRecorder::stop() {
	if (_thread.joinable()) {
		_finishing = true;
		_q_cv.notify_all();
		_thread.join();
	}
	if (_enc) {
		delete _enc;
		_enc = nullptr;
	}
	_running = false;
}

// -------------------------------------------------------------- worker --

void VideoRecorder::_worker() {
	for (;;) {
		std::vector<uint8_t> frame;
		std::vector<float> audio;
		bool have_frame = false, have_audio = false;
		{
			std::unique_lock<std::mutex> lk(_q_mtx);
			_q_cv.wait(lk, [&] { return !_queue.empty() || !_a_queue.empty() || _finishing.load(); });
			if (!_queue.empty()) {
				frame = std::move(_queue.front());
				_queue.pop_front();
				have_frame = true;
			} else if (!_a_queue.empty()) {
				audio = std::move(_a_queue.front());
				_a_queue.pop_front();
				have_audio = true;
			} else if (_finishing.load()) {
				break;
			}
		}
		// Both writes land on the same muxer, but only ever from this one
		// worker thread -- MP4E_mux_t isn't safe to touch concurrently.
		if (have_frame) {
			if (_encode_one(frame.data())) {
				_encoded++;
			} else {
				_set_status("encode error — recording stopped");
				_finishing = true; // bail; stop() will finish the file
			}
		}
		if (have_audio && !_encode_audio(audio)) {
			_set_status("audio encode error — recording stopped");
			_finishing = true;
		}
	}
	_finalize();
}

bool VideoRecorder::_encode_one(const uint8_t *rgba) {
	Enc *e = _enc;
	uint8_t *dst = e->yuv[e->cur].data();
	rgba_to_i420(rgba, _w, _h, dst);

	H264E_io_yuv_t io;
	io.yuv[0] = dst;
	io.yuv[1] = dst + _w * _h;
	io.yuv[2] = dst + _w * _h + (_w / 2) * (_h / 2);
	io.stride[0] = _w;
	io.stride[1] = _w / 2;
	io.stride[2] = _w / 2;

	H264E_run_param_t rp;
	memset(&rp, 0, sizeof(rp));
	rp.frame_type = 0;
	rp.encode_speed = 8; // fast — this is real-time capture
	rp.desired_frame_bytes = _kbps * 1000 / 8 / _fps;
	rp.qp_min = 12;
	rp.qp_max = 50;

	unsigned char *coded = nullptr;
	int coded_size = 0;
	if (H264E_encode(e->enc, e->scratch, &rp, &io, &coded, &coded_size) != H264E_STATUS_SUCCESS) {
		return false;
	}
	e->cur ^= 1; // the buffer just encoded stays referenced; next frame uses the other

	if (coded_size > 0 &&
			mp4_h26x_write_nal(&e->mp4wr, coded, coded_size, 90000 / _fps) != MP4E_STATUS_OK) {
		return false;
	}
	return true;
}

// Worker-thread only (see _worker()). Buffers `interleaved` (float, one
// call's worth of new samples) onto whatever's left over from the previous
// call, then shine-encodes and muxes every complete pass it can make.
bool VideoRecorder::_encode_audio(const std::vector<float> &interleaved) {
	Enc *e = _enc;
	if (e == nullptr || e->mp3 == nullptr) {
		return true; // audio track not started -- silently ignore, video keeps going
	}
	size_t base = e->a_pcm.size();
	e->a_pcm.resize(base + interleaved.size());
	for (size_t i = 0; i < interleaved.size(); i++) {
		float f = interleaved[i] * 32767.0f;
		f = f < -32768.0f ? -32768.0f : (f > 32767.0f ? 32767.0f : f);
		e->a_pcm[base + i] = static_cast<int16_t>(lroundf(f));
	}

	int need = e->a_samples_per_pass * e->a_channels; // interleaved samples per encoder pass
	size_t consumed = 0;
	while (static_cast<int>(e->a_pcm.size() - consumed) >= need) {
		int written = 0;
		unsigned char *mp3 = shine_encode_buffer_interleaved(e->mp3, e->a_pcm.data() + consumed, &written);
		consumed += need;
		if (mp3 != nullptr && written > 0) {
			if (MP4E_put_sample(e->mux, e->audio_track, mp3, written, e->a_samples_per_pass,
						MP4E_SAMPLE_RANDOM_ACCESS) != MP4E_STATUS_OK) {
				return false;
			}
		}
	}
	if (consumed > 0) {
		e->a_pcm.erase(e->a_pcm.begin(), e->a_pcm.begin() + consumed);
	}
	return true;
}

void VideoRecorder::_finalize() {
	Enc *e = _enc;
	if (!e) {
		return;
	}
	if (e->mp3) {
		int written = 0;
		unsigned char *tail = shine_flush(e->mp3, &written);
		if (tail != nullptr && written > 0 && e->mux != nullptr) {
			MP4E_put_sample(e->mux, e->audio_track, tail, written, e->a_samples_per_pass, MP4E_SAMPLE_RANDOM_ACCESS);
		}
		shine_close(e->mp3);
		e->mp3 = nullptr;
	}
	if (e->mux) {
		mp4_h26x_write_close(&e->mp4wr);
		MP4E_close(e->mux);
		e->mux = nullptr;
	}
	if (e->file) {
		fclose(e->file);
		e->file = nullptr;
	}
	if (e->enc) {
		std::free(e->enc);
		e->enc = nullptr;
	}
	if (e->scratch) {
		std::free(e->scratch);
		e->scratch = nullptr;
	}
	_running = false;
	String msg = String("saved — ") + itos(_encoded.load()) + " frames";
	if (_dropped.load() > 0) {
		msg += ", " + itos(_dropped.load()) + " dropped";
	}
	_set_status(msg);
}
