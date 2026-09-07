class_name ShowGenerator
extends RefCounted
## Turns a `SongAnalysis` + the live patch into a starter light show:
##   - one block cue per section, a section-appropriate look on every
##     patched fixture (palette + intensity by label; strobe on drops)
##   - an "Auto Beat" colour chase (beat-synced) for the big sections
##   - "Auto Move Slow / Fast" pan-tilt effects for moving heads
##   - a timeline (section start on the downbeat) that fires all of it
##
## Generated cues carry `Cue.auto = true` so a rebuild replaces only
## them; the timeline addresses sections by index, and the shell maps
## that to a cue number when it installs the show.

const PALETTES := {
	"Intro":  [Color(0.10, 0.20, 0.85), Color(0.05, 0.35, 0.70)],
	"Verse":  [Color(1.00, 0.62, 0.28), Color(0.95, 0.80, 0.55)],
	"Chorus": [Color(1.00, 0.10, 0.10), Color(0.15, 0.45, 1.00),
			   Color(1.00, 0.10, 0.55), Color(0.25, 1.00, 0.35)],
	"Bridge": [Color(0.70, 0.10, 1.00), Color(0.10, 0.90, 0.90)],
	"Build":  [Color(1.00, 1.00, 1.00), Color(0.85, 0.85, 1.00)],
	"Drop":   [Color(1.00, 1.00, 1.00), Color(1.00, 0.25, 0.10)],
	"Outro":  [Color(0.10, 0.15, 0.55)],
}
const INTENSITY := {
	"Intro": 0.35, "Verse": 0.62, "Chorus": 1.0, "Bridge": 0.5,
	"Build": 0.75, "Drop": 1.0, "Outro": 0.28,
}
const FADE := {
	"Intro": 3.0, "Verse": 2.0, "Chorus": 0.7, "Bridge": 2.5,
	"Build": 1.0, "Drop": 0.05, "Outro": 4.0,
}
const CHASE_NAME := "Auto Beat"
const MOVE_SLOW := "Auto Move Slow"
const MOVE_FAST := "Auto Move Fast"
const BIG := ["Chorus", "Drop"]
const MOVING := ["Chorus", "Drop", "Bridge", "Build"]


## -> { cues, chase, effects, timeline }
static func build(a: SongAnalysis, panels: Array) -> Dictionary:
	var fixtures := _collect(panels)
	var cues: Array = []
	var timeline: Array = []

	for i in range(a.sections.size()):
		var sec: Dictionary = a.sections[i]
		var label := String(sec["label"])
		var pal: Array = PALETTES.get(label, PALETTES["Verse"])
		var lvl: float = clampf(float(INTENSITY.get(label, 0.6))
			* lerpf(0.78, 1.12, float(sec["energy"])), 0.05, 1.0)
		var moving: bool = label in MOVING
		var strobe: bool = label == "Drop"

		var per_uni := _blank(panels.size())
		for fi in range(fixtures.size()):
			_paint(per_uni, fixtures[fi], pal[fi % pal.size()], lvl, moving, strobe, fi, fixtures.size())

		var cue := Cue.new("%d. %s" % [i + 1, label],
			float(FADE.get(label, 2.0)), float(FADE.get(label, 2.0)) + 0.5)
		cue.auto = true
		cue.set_levels(per_uni)
		cues.append(cue)

		var t := _section_start(a, sec)
		timeline.append({"t": t, "kind": "cue", "arg": i})
		timeline.append({"t": t, "kind": "chase", "arg": {"name": CHASE_NAME, "on": label in BIG}})
		timeline.append({"t": t, "kind": "effect",
			"arg": {"name": MOVE_FAST, "on": label in ["Chorus", "Drop"]}})
		timeline.append({"t": t, "kind": "effect",
			"arg": {"name": MOVE_SLOW, "on": label in ["Bridge", "Build", "Verse"]}})

	timeline.sort_custom(func(x, y): return float(x["t"]) < float(y["t"]))
	return {
		"cues": cues,
		"chase": _beat_chase(panels, fixtures),
		"effects": _move_effects(a.bpm),
		"timeline": timeline,
	}


# -------------------------------------------------------------------------

## The section's start, snapped to the nearest downbeat so cues land on
## the "1" of a bar.
static func _section_start(a: SongAnalysis, sec: Dictionary) -> float:
	var s := float(sec["start"])
	if s <= 0.05 or a.downbeats.is_empty():
		return s
	var best := s
	var bd := INF
	for d in a.downbeats:
		var dist: float = absf(d - s)
		if dist < bd:
			bd = dist
			best = d
	return best if bd < 1.2 else s


static func _collect(panels: Array) -> Array:
	var out: Array = []
	for u in range(panels.size()):
		for fx in panels[u].patched_fixtures:
			var prof: FixtureProfile = fx["profile"]
			out.append({
				"u": u, "start": int(fx["start"]),
				"chans": prof.channels_for_mode(int(fx.get("mode", 0))),
			})
	return out


static func _blank(n: int) -> Array:
	var a: Array = []
	for i in range(n):
		a.append({})
	return a


static func _paint(per_uni: Array, fx: Dictionary, col: Color, lvl: float,
		moving: bool, strobe: bool, idx: int, total: int) -> void:
	var chans: Array = fx["chans"]
	var start: int = fx["start"]
	var u: int = fx["u"]
	if u < 0 or u >= per_uni.size():
		return
	var d: Dictionary = per_uni[u]

	var has_dimmer := false
	for ch in chans:
		if String(ch["role"]) == "DIMMER":
			has_dimmer = true
	var rgb_scale := 1.0 if has_dimmer else lvl

	for li in range(chans.size()):
		var c := start + li
		match String(chans[li]["role"]):
			"DIMMER": d[c] = int(round(lvl * 255.0))
			"RED": d[c] = int(round(col.r * 255.0 * rgb_scale))
			"GREEN": d[c] = int(round(col.g * 255.0 * rgb_scale))
			"BLUE": d[c] = int(round(col.b * 255.0 * rgb_scale))
			"WHITE": d[c] = int(round(minf(col.r, minf(col.g, col.b)) * 200.0 * rgb_scale))
			"PAN":
				var spread := 0.0
				if moving and total > 1:
					spread = (float(idx) / float(total - 1) - 0.5) * 90.0
				d[c] = clampi(128 + int(spread / 270.0 * 255.0), 0, 255)
			"TILT": d[c] = 150 if moving else 128
			"STROBE": d[c] = 200 if strobe else 0


static func _beat_chase(panels: Array, fixtures: Array) -> Chase:
	var c := Chase.new()
	c.name = CHASE_NAME
	c.bpm = 120.0
	c.beat_sync = true
	var pal: Array = PALETTES["Chorus"]
	for step in range(pal.size()):
		var per_uni := _blank(panels.size())
		for fi in range(fixtures.size()):
			_paint(per_uni, fixtures[fi], pal[(fi + step) % pal.size()], 1.0, true, false, fi, fixtures.size())
		var look: Array = []
		for d in per_uni:
			var out := {}
			for k in d.keys():
				out[str(int(k))] = clampi(int(d[k]), 0, 255)
			look.append(out)
		c.steps.append(look)
	return c


## Pan/tilt circles for moving heads — targets are resolved by the shell
## from the live patch when the show is installed.
static func _move_effects(bpm: float) -> Array:
	var slow_pan := WaveEffect.new()
	slow_pan.name = MOVE_SLOW
	slow_pan.role = "PAN"
	slow_pan.waveform = WaveEffect.SINE
	slow_pan.bpm = maxf(bpm * 0.25, 8.0)
	slow_pan.size = 90.0
	slow_pan.center = 128.0
	slow_pan.fan_deg = 60.0

	var fast_pan := WaveEffect.new()
	fast_pan.name = MOVE_FAST
	fast_pan.role = "PAN"
	fast_pan.waveform = WaveEffect.SINE
	fast_pan.bpm = maxf(bpm * 0.5, 20.0)
	fast_pan.size = 200.0
	fast_pan.center = 128.0
	fast_pan.fan_deg = 120.0
	return [slow_pan, fast_pan]
