#ifndef VIDEO_RECORDER_H
#define VIDEO_RECORDER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

namespace godot {

// Records an RGBA8 frame stream to an H.264 MP4 (minih264 + minimp4).
// Frames are pushed from the render thread; a worker converts to I420,
// encodes and muxes so the caller never blocks on the codec.
class VideoRecorder : public RefCounted {
	GDCLASS(VideoRecorder, RefCounted)

	struct Enc;                       // pImpl: the codec / muxer objects

	Enc *_enc = nullptr;
	int _w = 0, _h = 0, _fps = 30, _kbps = 8000;
	std::atomic<bool> _running{false};
	std::atomic<bool> _finishing{false};
	std::atomic<int> _pushed{0};
	std::atomic<int> _encoded{0};
	std::atomic<int> _dropped{0};

	std::thread _thread;
	std::mutex _q_mtx;
	std::condition_variable _q_cv;
	std::deque<std::vector<uint8_t>> _queue;   // RGBA8 frames waiting to encode
	static const int MAX_QUEUE = 16;

	std::mutex _status_mtx;
	String _status = "idle";

	void _set_status(const String &s);
	void _worker();
	bool _encode_one(const uint8_t *rgba);
	void _finalize();

protected:
	static void _bind_methods();

public:
	// path: an absolute .mp4 path. kbps: target video bitrate.
	bool start(const String &path, int width, int height, int fps, int kbps);
	void push_frame(const PackedByteArray &rgba8);   // width*height*4 bytes
	void stop();

	bool is_recording() const;
	int get_frame_count() const;
	int get_dropped() const;
	String get_status();

	VideoRecorder();
	~VideoRecorder();
};

} // namespace godot

#endif // VIDEO_RECORDER_H
