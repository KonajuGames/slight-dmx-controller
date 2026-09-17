class_name SongAnalysis
extends RefCounted
## The result of analysing a music file: an estimated tempo, a beat grid,
## and a list of structural sections (Intro / Verse / Chorus / Bridge /
## Build / Drop / Outro) with a 0..1 energy figure. Produced by
## SongAnalyzer, consumed by ShowGenerator and AutoShow.

var path: String = ""
var duration: float = 0.0        # seconds
var bpm: float = 120.0
## Musical key, from SongDetect.detect_key(): root pitch class (0=C .. 11=B)
## and "major"/"minor". Auto Show derives its section palettes from this.
var key_root: int = 0
var key_mode: String = "major"
var beat_times: PackedFloat32Array = PackedFloat32Array()
var downbeats: PackedFloat32Array = PackedFloat32Array()   # every bar's beat 1
## [{ start: float, end: float, label: String, energy: float, cluster: int }]
var sections: Array = []

## Whole-song loudness/spectral envelope for the waveform view: one value
## per column (0..1), columns span the whole track. `peak` is the level,
## `lo`/`mid`/`hi` are the band balance at that column.
var wave_lo: PackedFloat32Array = PackedFloat32Array()
var wave_mid: PackedFloat32Array = PackedFloat32Array()
var wave_hi: PackedFloat32Array = PackedFloat32Array()
var wave_peak: PackedFloat32Array = PackedFloat32Array()


func has_wave() -> bool:
	return wave_peak.size() > 0


func section_at(t: float) -> int:
	for i in range(sections.size()):
		if t >= sections[i]["start"] and t < sections[i]["end"]:
			return i
	return sections.size() - 1 if not sections.is_empty() else -1


const _KEY_NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

func key_name() -> String:
	return "%s %s" % [_KEY_NAMES[clampi(key_root, 0, 11)], key_mode.capitalize()]


func summary() -> String:
	return "%.0f BPM · %s · %d beats · %d bars · %d sections" % [
		bpm, key_name(), beat_times.size(), downbeats.size(), sections.size()]


func to_dict() -> Dictionary:
	return {
		"path": path, "duration": duration, "bpm": bpm,
		"key_root": key_root, "key_mode": key_mode,
		"beat_times": Array(beat_times),
		"downbeats": Array(downbeats),
		"sections": sections.duplicate(true),
		"wave_cols": wave_peak.size(),
		"wave": Marshalls.raw_to_base64(_wave_bytes()) if wave_peak.size() > 0 else "",
	}


## The four wave arrays quantised to one byte each, laid out
## [lo…][mid…][hi…][peak…]. Empty when there's no wave.
func _wave_bytes() -> PackedByteArray:
	var n := wave_peak.size()
	var b := PackedByteArray()
	if n == 0:
		return b
	b.resize(n * 4)
	for i in range(n):
		b[i] = int(clampf(wave_lo[i], 0.0, 1.0) * 255.0)
		b[n + i] = int(clampf(wave_mid[i], 0.0, 1.0) * 255.0)
		b[n * 2 + i] = int(clampf(wave_hi[i], 0.0, 1.0) * 255.0)
		b[n * 3 + i] = int(clampf(wave_peak[i], 0.0, 1.0) * 255.0)
	return b


static func from_dict(d: Dictionary) -> SongAnalysis:
	var a := SongAnalysis.new()
	a.path = String(d.get("path", ""))
	a.duration = float(d.get("duration", 0.0))
	a.bpm = float(d.get("bpm", 120.0))
	a.key_root = clampi(int(d.get("key_root", 0)), 0, 11)
	a.key_mode = String(d.get("key_mode", "major"))
	a.beat_times = PackedFloat32Array()
	for t in d.get("beat_times", []):
		a.beat_times.append(float(t))
	a.downbeats = PackedFloat32Array()
	for t in d.get("downbeats", []):
		a.downbeats.append(float(t))
	a.sections = []
	for s in d.get("sections", []):
		if s is Dictionary:
			a.sections.append({
				"start": float(s.get("start", 0.0)),
				"end": float(s.get("end", 0.0)),
				"label": String(s.get("label", "Section")),
				"energy": clampf(float(s.get("energy", 0.5)), 0.0, 1.0),
				"cluster": int(s.get("cluster", 0)),
			})
	a._wave_from_bytes(
		Marshalls.base64_to_raw(String(d.get("wave", ""))), int(d.get("wave_cols", 0)))
	return a


func _wave_from_bytes(b: PackedByteArray, n: int) -> void:
	wave_lo = PackedFloat32Array()
	wave_mid = PackedFloat32Array()
	wave_hi = PackedFloat32Array()
	wave_peak = PackedFloat32Array()
	if n <= 0 or b.size() < n * 4:
		return
	wave_lo.resize(n)
	wave_mid.resize(n)
	wave_hi.resize(n)
	wave_peak.resize(n)
	for i in range(n):
		wave_lo[i] = b[i] / 255.0
		wave_mid[i] = b[n + i] / 255.0
		wave_hi[i] = b[n * 2 + i] / 255.0
		wave_peak[i] = b[n * 3 + i] / 255.0
