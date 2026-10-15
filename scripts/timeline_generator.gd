class_name TimelineGenerator
extends RefCounted
## Builds a light show into a song's timelines from its structure, tempo
## and energy — what DJ Edit Mode's Generate button does.
##
## In: the song's sections ({start, end, label, energy}), its beat grid (or
## BPM), its length, and the timelines to fill (master, fixtures, heads:
## their keys and rows), plus the show's named positions. Out: per track
## key, the rows' content in the timelines' in-memory forms:
##   {dimmer: PackedVector2Array, colour: [segments], strobe: [spans],
##    position: [spans], movement: [spans]}
##
## The rules, section by section (energy rescaled across the song, so its
## quietest part is 0 and its loudest 1):
##   master dimmer  the section at 25-100 % by energy, a beat's fade
##                  between sections; faded in at the start, out at the end
##   fixture dimmer high energy: a pulse on every beat, chasing across the
##                  fixtures; upper-middle: a pulse on every bar; otherwise
##                  nothing (they follow the master)
##   colour         a palette per kind of section (every chorus alike): the
##                  master its main colour, every other fixture its accent;
##                  a multi-head fixture's heads blend main -> accent; the
##                  loudest sections sweep main -> accent across them
##   strobe         a build into a big rise in energy: the section's last
##                  two bars, medium then fast (on the master)
##   position       the named positions in turn, a section each (master)
##   movement       by energy: a small slow tilt sweep, a circle, a large
##                  fast figure 8 (master; one cycle per ½ / 1 / 2 bars)

## Energy (rescaled) above which a section is "high" (beat pulses, gradient,
## big movement) and "upper-middle" (bar pulses).
const HIGH := 0.75
const MID := 0.5
## A rise in energy into the next section that earns a strobe build.
const BUILD_RISE := 0.35

## Palettes by section label: [main, accent] hues (0..1) — the generator
## rotates them by a per-song offset so every song looks a little
## different, but every chorus within a song alike.
const PALETTES := {
	"intro": [0.60, 0.72], "verse": [0.55, 0.85], "pre-chorus": [0.80, 0.95],
	"chorus": [0.00, 0.10], "drop": [0.95, 0.12], "bridge": [0.45, 0.65],
	"breakdown": [0.68, 0.75], "outro": [0.62, 0.70],
}


## Build the show. `tracks`: [{key, target: TimelineTrack.Target, rows:
## [Row]}] in order (fixtures then their heads, the master too);
## `beats`: the beat times; `per_bar`: beats a bar; `positions`: the named
## positions' ids. Returns key -> content (only the rows each track has).
static func generate(sections: Array, beats: PackedFloat32Array, per_bar: int, duration: float,
		tracks: Array, positions: Array = [], seed_text := "") -> Dictionary:
	var secs := _normalised(sections, duration)
	if beats.is_empty():
		beats = _even_beats(120.0, duration)
	per_bar = maxi(per_bar, 1)
	var beat_len := _median_gap(beats)
	var bar_len := beat_len * per_bar
	var hue_shift := float(hash(seed_text) % 1000) / 1000.0 * 0.25
	var out := {}
	var fixtures: Array = []          # fixture tracks (not heads), in order
	var heads_of := {}                # fixture key -> its head tracks
	for t in tracks:
		out[String(t["key"])] = {"dimmer": PackedVector2Array(), "colour": [], "strobe": [], "position": [], "movement": []}
		if t["target"] == TimelineTrack.Target.FIXTURE:
			fixtures.append(t)
		elif t["target"] == TimelineTrack.Target.HEAD:
			var parent := String(t["key"]).get_slice("/", 0)
			if not heads_of.has(parent):
				heads_of[parent] = []
			heads_of[parent].append(t)

	# --- the master ---------------------------------------------------
	var master := {}
	for t in tracks:
		if t["target"] == TimelineTrack.Target.MASTER:
			master = t
	if not master.is_empty():
		var m: Dictionary = out[String(master["key"])]
		if TimelineTrack.Row.DIMMER in master["rows"]:
			m["dimmer"] = _master_dimmer(secs, beat_len, duration)
		if TimelineTrack.Row.COLOUR in master["rows"]:
			for s in secs:
				var pal := _palette(String(s["label"]), hue_shift)
				var c1: Color = pal[1] if s["e"] >= HIGH else pal[0]
				m["colour"].append({"t0": s["start"], "t1": s["end"], "c0": pal[0], "c1": c1})
		if TimelineTrack.Row.STROBE in master["rows"]:
			m["strobe"] = _strobe_builds(secs, bar_len)
		if TimelineTrack.Row.POSITION in master["rows"] and not positions.is_empty():
			for i in range(secs.size()):
				m["position"].append({"t0": secs[i]["start"], "t1": secs[i]["end"], "pos": String(positions[i % positions.size()])})
		if TimelineTrack.Row.MOVEMENT in master["rows"]:
			for s in secs:
				m["movement"].append(_movement_for(s, bar_len))

	# --- fixtures and their heads ---------------------------------------
	for fi in range(fixtures.size()):
		var f: Dictionary = fixtures[fi]
		var fo: Dictionary = out[String(f["key"])]
		var heads: Array = heads_of.get(String(f["key"]), [])
		if TimelineTrack.Row.DIMMER in f["rows"]:
			var master_line: PackedVector2Array = out[String(master["key"])]["dimmer"] if not master.is_empty() else PackedVector2Array()
			fo["dimmer"] = _fixture_pulses(secs, beats, per_bar, fi, fixtures.size(), master_line)
		for s in secs:
			var pal := _palette(String(s["label"]), hue_shift)
			if heads.size() > 1:
				# The heads blend from the main colour to the accent.
				for hi in range(heads.size()):
					var h: Dictionary = heads[hi]
					if TimelineTrack.Row.COLOUR in h["rows"]:
						var c := (pal[0] as Color).lerp(pal[1], float(hi) / float(heads.size() - 1))
						out[String(h["key"])]["colour"].append({"t0": s["start"], "t1": s["end"], "c0": c, "c1": c})
			elif TimelineTrack.Row.COLOUR in f["rows"] and fi % 2 == 1:
				# Every other fixture takes the accent (the rest the master's main).
				var c0: Color = pal[1]
				var c1: Color = pal[0] if s["e"] >= HIGH else pal[1]
				fo["colour"].append({"t0": s["start"], "t1": s["end"], "c0": c0, "c1": c1})
	return out


## The sections, sorted and filling the song, with their energy rescaled
## to 0..1 across it ("e"). No sections: the whole song as one.
static func _normalised(sections: Array, duration: float) -> Array:
	var secs: Array = []
	for s in sections:
		if float(s.get("end", 0.0)) > float(s.get("start", 0.0)):
			secs.append({"start": float(s["start"]), "end": minf(float(s["end"]), duration),
				"label": String(s.get("label", "verse")).to_lower(), "energy": float(s.get("energy", 0.5))})
	secs.sort_custom(func(a, b): return a["start"] < b["start"])
	if secs.is_empty():
		secs.append({"start": 0.0, "end": duration, "label": "verse", "energy": 0.6})
	var lo := INF
	var hi := -INF
	for s in secs:
		lo = minf(lo, s["energy"])
		hi = maxf(hi, s["energy"])
	for s in secs:
		s["e"] = 0.6 if hi - lo < 0.001 else (s["energy"] - lo) / (hi - lo)
	return secs


static func _even_beats(bpm: float, duration: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var step := 60.0 / maxf(bpm, 1.0)
	var t := 0.0
	while t < duration:
		out.append(t)
		t += step
	return out


static func _median_gap(beats: PackedFloat32Array) -> float:
	if beats.size() < 2:
		return 0.5
	var gaps: Array = []
	for i in range(1, beats.size()):
		gaps.append(beats[i] - beats[i - 1])
	gaps.sort()
	return maxf(float(gaps[gaps.size() / 2]), 0.05)


## [main, accent] colours for a section label, hues shifted per song.
static func _palette(label: String, shift: float) -> Array:
	var key := label
	if not PALETTES.has(key):
		key = "chorus" if "chorus" in label else ("verse" if "verse" in label else "bridge")
	var hues: Array = PALETTES[key]
	return [Color.from_hsv(fmod(hues[0] + shift, 1.0), 0.9, 1.0), Color.from_hsv(fmod(hues[1] + shift, 1.0), 0.85, 1.0)]


## The master's line: each section at 25-100 % by its energy, a beat's
## fade between sections; up from 0 over the first bar-ish, down to 0
## over the last.
static func _master_dimmer(secs: Array, beat_len: float, duration: float) -> PackedVector2Array:
	var out := PackedVector2Array([Vector2(0.0, 0.0)])
	var fade := minf(beat_len, 1.0)
	for i in range(secs.size()):
		var s: Dictionary = secs[i]
		var level := 0.25 + 0.75 * float(s["e"])
		var a: float = s["start"] + (fade if i == 0 else fade * 0.5)
		var b: float = s["end"] - (fade if i == secs.size() - 1 else fade * 0.5)
		if b <= a:
			a = (s["start"] + s["end"]) * 0.5
			b = a
		out.append(Vector2(a, level))
		if b > a:
			out.append(Vector2(b, level))
	out.append(Vector2(duration, 0.0))
	return out


## A fixture's dimmer: in high-energy sections a pulse on every beat (each
## fixture taking every Nth beat — a chase), upper-middle a pulse every
## bar; elsewhere nothing, so it follows the master. Each pulsing stretch
## steps up to 100 % on its beat and fades to 0 by the next. (A line has no
## holes, so between pulsing sections it copies the master's line — the
## same as following it.)
static func _fixture_pulses(secs: Array, beats: PackedFloat32Array, per_bar: int, index: int, count: int,
		master_line: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var first := -1
	var last := -1
	for i in range(secs.size()):
		if float(secs[i]["e"]) >= MID:
			if first < 0:
				first = i
			last = i
	for i in range(maxi(first, 0), last + 1):
		var s: Dictionary = secs[i]
		var e: float = s["e"]
		if e < MID:
			# Between pulsing sections: the master's line.
			_append(out, Vector2(s["start"], TimelineTrack.level_at(master_line, s["start"])))
			for p in master_line:
				if p.x > s["start"] and p.x < s["end"]:
					_append(out, p)
			_append(out, Vector2(s["end"], TimelineTrack.level_at(master_line, s["end"])))
			continue
		var hits: Array = []
		for bi in range(beats.size()):
			var b := beats[bi]
			if b < s["start"] or b >= s["end"]:
				continue
			if e >= HIGH:
				if count <= 2 or posmod(bi - index, mini(count, per_bar)) == 0:
					hits.append(b)
			elif bi % per_bar == 0:
				hits.append(b)
		if hits.is_empty():
			continue
		# One stretch for the section: from its start to its end.
		var shape := MusicTimeline.dimmer_shape(MusicTimeline.Dim.BEAT_PULSES, s["start"], s["end"], 0.0, 0.0,
			PackedFloat32Array(hits))
		for p in shape:
			_append(out, Vector2(p.x + s["start"], p.y))
	return out


## Add a node to a line, keeping it in time order.
static func _append(line: PackedVector2Array, p: Vector2) -> void:
	if line.is_empty() or p.x >= line[line.size() - 1].x:
		line.append(p)


## Strobe builds: the last two bars before a section that rises sharply in
## energy (medium, then fast in the final bar).
static func _strobe_builds(secs: Array, bar_len: float) -> Array:
	var out: Array = []
	for i in range(secs.size() - 1):
		var s: Dictionary = secs[i]
		var nxt: Dictionary = secs[i + 1]
		if float(nxt["e"]) - float(s["e"]) < BUILD_RISE or float(nxt["e"]) < HIGH:
			continue
		var end: float = s["end"]
		var a := maxf(end - 2.0 * bar_len, s["start"])
		var mid := maxf(end - bar_len, a)
		if mid > a:
			out.append({"t0": a, "t1": mid, "speed": TimelineTrack.Strobe.MEDIUM})
		if end > mid:
			out.append({"t0": mid, "t1": end, "speed": TimelineTrack.Strobe.FAST})
	return out


## The master's movement for a section, by its energy.
static func _movement_for(s: Dictionary, bar_len: float) -> Dictionary:
	var e: float = s["e"]
	var fx := "tilt_sweep"
	var size := 0.04
	var bars := 2.0
	if e >= HIGH:
		fx = "figure8"
		size = 0.16
		bars = 0.5
	elif e >= 0.35:
		fx = "circle"
		size = 0.08
		bars = 1.0
	return {"t0": s["start"], "t1": s["end"], "fx": fx, "period": bar_len * bars, "size": size}
