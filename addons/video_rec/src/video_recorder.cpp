#include "video_recorder.h"

#include "minih264e.h" // declarations only — the implementation is in codec_impl.c
#include "minimp4.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>

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
};

// --------------------------------------------------------------- bind --

void VideoRecorder::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start", "path", "width", "height", "fps", "kbps"), &VideoRecorder::start);
	ClassDB::bind_method(D_METHOD("push_frame", "rgba8"), &VideoRecorder::push_frame);
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
		{
			std::unique_lock<std::mutex> lk(_q_mtx);
			_q_cv.wait(lk, [&] { return !_queue.empty() || _finishing.load(); });
			if (_queue.empty()) {
				if (_finishing.load()) {
					break;
				}
				continue;
			}
			frame = std::move(_queue.front());
			_queue.pop_front();
		}
		if (_encode_one(frame.data())) {
			_encoded++;
		} else {
			_set_status("encode error — recording stopped");
			_finishing = true; // bail; stop() will finish the file
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

void VideoRecorder::_finalize() {
	Enc *e = _enc;
	if (!e) {
		return;
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
