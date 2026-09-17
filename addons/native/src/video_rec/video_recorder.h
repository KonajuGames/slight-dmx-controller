#ifndef VIDEO_RECORDER_H
#define VIDEO_RECORDER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

namespace godot {

// Records an RGBA8 frame stream to an H.264 MP4 (minih264 + minimp4), with
// an optional MP3 audio track (shine) muxed alongside it. Frames/audio are
// pushed from the caller (render thread / audio poll); a single worker
// thread does all encoding *and* every mux write, since minimp4's MP4E_mux_t
// isn't safe to touch from two threads at once — video and audio each get
// their own queue, but both drain through the one worker/one muxer.
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
	std::deque<std::vector<uint8_t>> _queue;    // RGBA8 frames waiting to encode
	std::deque<std::vector<float>> _a_queue;    // interleaved audio waiting to encode
	static const int MAX_QUEUE = 16;
	static const int MAX_A_QUEUE = 256;         // audio chunks are small and frequent

	std::mutex _status_mtx;
	String _status = "idle";

	void _set_status(const String &s);
	void _worker();
	bool _encode_one(const uint8_t *rgba);
	bool _encode_audio(const std::vector<float> &interleaved);
	void _finalize();

protected:
	static void _bind_methods();

public:
	// path: an absolute .mp4 path. kbps: target video bitrate.
	bool start(const String &path, int width, int height, int fps, int kbps);
	void push_frame(const PackedByteArray &rgba8);   // width*height*4 bytes

	// Adds an MP3 audio track to the current recording. Call once, after a
	// successful start() and before any push_audio(). channels must be 1 or
	// 2. No-op (recording stays video-only) if the sample rate isn't one
	// shine supports (the common engine rates, 44100/48000, are).
	bool start_audio(int sample_rate, int channels);
	// Interleaved float samples in [-1, 1], `channels` (from start_audio())
	// per frame, at `sample_rate`. Any chunk size is fine -- internally
	// buffered up to whatever shine's encoder needs per pass. No-op if
	// start_audio() wasn't called or failed.
	void push_audio(const PackedFloat32Array &interleaved);

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
