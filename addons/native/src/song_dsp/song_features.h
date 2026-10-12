#ifndef SONG_FEATURES_H
#define SONG_FEATURES_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <atomic>

namespace godot {

// Decodes a music file (MP3 / OGG / WAV with bundled decoders; M4A / AAC /
// MP4 with the OS's own -- see dec_os.cpp) straight to PCM and runs the
// heavy front-end of the song analysis in C++: STFT chroma/timbre frames,
// a time-domain onset envelope, and the whole-song waveform envelope.
// SongAnalyzer (GDScript) takes it from there (tempo, beats, structure).
//
// This replaces playing the file 4x through a muted capture bus — a
// ~4-minute track goes from a ~60 s wall-clock capture to a sub-second
// decode + analysis.
class SongFeatures : public RefCounted {
	GDCLASS(SongFeatures, RefCounted)

	std::atomic<float> _progress{0.0f};
	std::atomic<bool> _cancel{false};

protected:
	static void _bind_methods();

public:
	// Returns a Dictionary:
	//   ok        : bool
	//   error     : String            (when !ok)
	//   rate      : float              working sample rate (~11025)
	//   duration  : float              song length, seconds
	//   nframes   : int
	//   chroma    : PackedFloat32Array nframes*12, row-major
	//   rms, centroid, flux : PackedFloat32Array  (nframes)
	//   onset     : PackedFloat32Array
	//   onset_hz  : float
	//   wave_lo/wave_mid/wave_hi/wave_peak : PackedFloat32Array (wave_cols)
	// Safe to call from a worker thread.
	Dictionary analyze_file(const String &path, int n_fft, int hop, int wave_cols);

	// The whole-track waveform at high resolution, for a zoomable view:
	// `cols_per_sec` columns per second of audio (capped at 1000), built
	// in one streaming pass so even an hours-long mix never sits decoded
	// in memory. No length limit. Returns a Dictionary:
	//   ok, error, duration (s), cols_per_sec,
	//   wave_lo / wave_mid / wave_hi : PackedFloat32Array  band energy
	//     (bass < 250 Hz, mid, air > 2.5 kHz), normalised together to 0..1
	//   wave_peak : PackedFloat32Array  loudness (RMS), normalised to 0..1
	// Safe to call from a worker thread; cancel() stops it early.
	Dictionary waveform_file(const String &path, int cols_per_sec);

	// Decode a whole file to 16-bit PCM for playback -- what Godot needs to
	// play formats it has no decoder for (an AudioStreamWAV), M4A / AAC in
	// particular. More than two channels keep the front left / right.
	// Stops (ok = false, "track is too long") past `max_seconds`, while
	// decoding, since the PCM is held whole (~10 MB per minute at 44.1 kHz
	// stereo). Returns a Dictionary:
	//   ok, error, mix_rate (Hz), stereo (bool), duration (s),
	//   data : PackedByteArray  interleaved little-endian int16
	// Safe to call from a worker thread; cancel() stops it.
	Dictionary decode_pcm16(const String &path, double max_seconds);

	// Stop an in-flight waveform_file() / decode_pcm16() -- or analyze_file() while it's
	// decoding an OS-decoded format -- from another thread; it returns
	// ok = false, error "cancelled".
	void cancel();

	// Whether files only the OS can decode (.m4a / .aac / .mp4) are
	// supported here: Windows with Media Foundation, or macOS.
	static bool os_decoder_available();

	// 0..1 progress of an in-flight analyze_file() / waveform_file(), for a
	// progress bar.
	float get_progress() const;

	SongFeatures();
	~SongFeatures();
};

} // namespace godot

#endif // SONG_FEATURES_H
