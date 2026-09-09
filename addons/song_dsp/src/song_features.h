#ifndef SONG_FEATURES_H
#define SONG_FEATURES_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <atomic>

namespace godot {

// Decodes a music file (MP3 / OGG / WAV) straight to PCM and runs the
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

	// 0..1 progress of an in-flight analyze_file(), for a progress bar.
	float get_progress() const;

	SongFeatures();
	~SongFeatures();
};

} // namespace godot

#endif // SONG_FEATURES_H
