class_name SongAnalysis
extends RefCounted
## The result of analysing a music file: an estimated tempo, a beat grid,
## and a list of structural sections (Intro / Verse / Chorus / Bridge /
## Build / Drop / Outro) with a 0..1 energy figure. Produced by
## SongAnalyzer, consumed by ShowGenerator and AutoShow.

var path: String = ""
var duration: float = 0.0        # seconds
var bpm: float = 120.0
var beat_times: PackedFloat32Array = PackedFloat32Array()
var downbeats: PackedFloat32Array = PackedFloat32Array()   # every bar's beat 1
## [{ start: float, end: float, label: String, energy: float, cluster: int }]
var sections: Array = []


func section_at(t: float) -> int:
	for i in range(sections.size()):
		if t >= sections[i]["start"] and t < sections[i]["end"]:
			return i
	return sections.size() - 1 if not sections.is_empty() else -1


func summary() -> String:
	return "%.0f BPM · %d beats · %d bars · %d sections" % [
		bpm, beat_times.size(), downbeats.size(), sections.size()]


func to_dict() -> Dictionary:
	return {
		"path": path, "duration": duration, "bpm": bpm,
		"beat_times": Array(beat_times),
		"downbeats": Array(downbeats),
		"sections": sections.duplicate(true),
	}


static func from_dict(d: Dictionary) -> SongAnalysis:
	var a := SongAnalysis.new()
	a.path = String(d.get("path", ""))
	a.duration = float(d.get("duration", 0.0))
	a.bpm = float(d.get("bpm", 120.0))
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
	return a
