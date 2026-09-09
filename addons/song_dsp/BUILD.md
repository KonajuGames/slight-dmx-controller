# song_dsp — audio-decode + analysis front-end GDExtension

Adds a `SongFeatures` class that decodes a music file (MP3 / OGG / WAV)
straight to PCM and runs the heavy part of the song analysis in C++ — the
STFT chroma/timbre frames, the onset envelope, and the whole-song
waveform. `SongAnalyzer` (GDScript) uses it when present; without the
extension it falls back to the original path: play the track 4× through a
muted `AudioEffectCapture` bus, then do the STFT in GDScript.

Why: the capture path is bounded by real-time playback — a 4-minute track
takes ~60 s of wall-clock before any maths runs, and the GDScript STFT
then freezes the UI for another 5–15 s. Decoding directly makes analysis
purely compute-bound: a few seconds total, on a worker thread.

Decoders: **minimp3** (MP3) and **stb_vorbis** (Ogg) — single-file, public
domain, vendored in `third_party/`. WAV is parsed directly. No download
step, nothing at run time.

## Requirements

- **git**, **Python 3**, **SCons** (`pip install scons`)
- A C++ toolchain — Windows: Visual Studio with "Desktop development with
  C++"; Linux: gcc/clang + pthreads; macOS: Xcode CLT.

## Build

```
python addons/song_dsp/build.py
```

Clones its own `godot-cpp` into `addons/song_dsp/godot-cpp` (copied from a
sibling addon's checkout if one exists, so no re-download — but still a
full ~15–20 min first compile; SCons's signature DB is per-build so a
shared checkout gets rebuilt anyway). Then activates
`song_dsp.gdextension`. Manual:

```
git clone --depth 1 --branch 4.5 https://github.com/godotengine/godot-cpp addons/song_dsp/godot-cpp
cd addons/song_dsp
python -m SCons godot_cpp=godot-cpp platform=windows target=template_debug
python -m SCons godot_cpp=godot-cpp platform=windows target=template_release
cp song_dsp.gdextension.disabled song_dsp.gdextension
```

Ships **disabled** so an unbuilt checkout doesn't error.

## API

```gdscript
var sf := SongFeatures.new()
# n_fft, hop and wave_cols must match SongAnalyzer's constants.
var d: Dictionary = sf.analyze_file("C:/music/track.mp3", 2048, 1024, 1024)
if d.ok:
    d.rate        # working sample rate, ~11025
    d.duration    # seconds
    d.nframes
    d.chroma      # PackedFloat32Array, nframes*12 row-major
    d.rms; d.centroid; d.flux           # PackedFloat32Array (nframes)
    d.onset; d.onset_hz
    d.wave_lo; d.wave_mid; d.wave_hi; d.wave_peak   # (wave_cols)
```

`analyze_file()` is blocking (~1–3 s) but thread-safe — call it from a
`Thread` and poll `sf.get_progress()` (0..1) for a progress bar.

The working rate is fixed near 11025 Hz (44100 / 4) to match the constants
the GDScript detection maths were tuned against; the file is anti-alias
decimated to it after decode.
