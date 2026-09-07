class_name ShowGenerator
extends RefCounted
## Turns a `SongAnalysis` + the live patch into a starter light show.
##
## Fixtures are sorted by kind (moving head / wash / strobe / dimmer) and
## each section gets a **recipe** — a look for each kind plus which chase
## and movement effect to run. Every label has a small pool of recipes
## that cycle by occurrence, so consecutive verses / choruses / drops
## don't repeat. Drops get a short blackout a couple of beats before the
## hit.
##
## Output: { cues, chases, effects, timeline }. Generated cues carry
## `Cue.auto = true` (a rebuild replaces only those); the timeline
## addresses sections by index, the shell maps that to a cue number.

# ---- colours ----
const _WARM := Color(1.00, 0.55, 0.20)
const _AMBER := Color(1.00, 0.76, 0.42)
const _COOL := Color(0.14, 0.40, 1.00)
const _DEEP := Color(0.05, 0.10, 0.62)
const _CYAN := Color(0.10, 0.90, 0.90)
const _MAGENTA := Color(1.00, 0.10, 0.60)
const _PURPLE := Color(0.60, 0.10, 1.00)
const _RED := Color(1.00, 0.08, 0.08)
const _GREEN := Color(0.20, 1.00, 0.32)
const _LIME := Color(0.65, 1.00, 0.12)
const _WHITE := Color(1.00, 1.00, 1.00)

# ---- named chases / effects ----
const CH_COLOR := "Auto Colour Beat"
const CH_PULSE := "Auto Dimmer Pulse"
const CH_SWEEP := "Auto Position Sweep"
const ALL_CHASES := [CH_COLOR, CH_PULSE, CH_SWEEP]

## `mul` is a fraction of the song tempo. Pan / tilt effects are capped at
## 60 BPM by WaveEffect (motors can't chase faster), so these fractions
## keep the slow / fast pairs distinct below that for typical tempos.
const FX := {
	"Auto Pan Slow":   {"role": "PAN", "wave": 0, "mul": 0.18, "size": 100.0, "center": 128.0, "fan": 60.0, "phase": 0.0, "pickup": false},
	"Auto Pan Fast":   {"role": "PAN", "wave": 0, "mul": 0.38, "size": 210.0, "center": 128.0, "fan": 130.0, "phase": 0.0, "pickup": false},
	"Auto Tilt Slow":  {"role": "TILT", "wave": 0, "mul": 0.16, "size": 55.0, "center": 120.0, "fan": 40.0, "phase": 90.0, "pickup": false},
	"Auto Tilt Fast":  {"role": "TILT", "wave": 0, "mul": 0.40, "size": 80.0, "center": 120.0, "fan": 90.0, "phase": 90.0, "pickup": false},
	"Auto Tilt Wave":  {"role": "TILT", "wave": 1, "mul": 0.28, "size": 70.0, "center": 120.0, "fan": 200.0, "phase": 0.0, "pickup": false},
	"Auto Dim Breath": {"role": "DIMMER", "wave": 0, "mul": 0.125, "size": 80.0, "center": 150.0, "fan": 30.0, "phase": 0.0, "pickup": true},
}
const FX_SETS := {
	"circle_slow": ["Auto Pan Slow", "Auto Tilt Slow"],
	"circle_fast": ["Auto Pan Fast", "Auto Tilt Fast"],
	"tilt": ["Auto Tilt Wave"],
	"breath": ["Auto Dim Breath"],
	"none": [],
}

const FADE := {
	"Intro": 3.0, "Verse": 2.0, "Chorus": 0.7, "Bridge": 2.5,
	"Build": 1.0, "Drop": 0.05, "Outro": 4.0,
}

# ---- recipe pools: label -> [ {wash, mover, strobe, chase, fx}, ... ] ----
const RECIPES := {
	"Intro": [
		{"wash": {"mode": "unison", "cols": [_DEEP], "lvl": 0.42},
		 "mover": {"pos": "down", "mode": "unison", "cols": [_COOL], "lvl": 0.40},
		 "strobe": false, "chase": "", "fx": "breath"},
	],
	"Verse": [
		{"wash": {"mode": "split", "cols": [_WARM, _AMBER], "lvl": 0.60},
		 "mover": {"pos": "down", "mode": "unison", "cols": [_AMBER], "lvl": 0.55},
		 "strobe": false, "chase": "", "fx": "none"},
		{"wash": {"mode": "unison", "cols": [_AMBER], "lvl": 0.62},
		 "mover": {"pos": "updown", "mode": "split", "cols": [_WARM, _DEEP], "lvl": 0.55},
		 "strobe": false, "chase": CH_PULSE, "fx": "none"},
		{"wash": {"mode": "split", "cols": [_COOL, _CYAN], "lvl": 0.58},
		 "mover": {"pos": "down", "mode": "unison", "cols": [_CYAN], "lvl": 0.50},
		 "strobe": false, "chase": "", "fx": "tilt"},
	],
	"Chorus": [
		{"wash": {"mode": "split", "cols": [_RED, _COOL], "lvl": 1.0},
		 "mover": {"pos": "out", "mode": "split", "cols": [_RED, _COOL], "lvl": 1.0},
		 "strobe": false, "chase": CH_COLOR, "fx": "circle_fast"},
		{"wash": {"mode": "unison", "cols": [_MAGENTA], "lvl": 1.0},
		 "mover": {"pos": "cross", "mode": "split", "cols": [_MAGENTA, _CYAN], "lvl": 1.0},
		 "strobe": false, "chase": CH_SWEEP, "fx": "none"},
		{"wash": {"mode": "rainbow", "cols": [_RED, _GREEN, _COOL, _MAGENTA], "lvl": 1.0},
		 "mover": {"pos": "updown", "mode": "rainbow", "cols": [_LIME, _MAGENTA, _CYAN, _WARM], "lvl": 1.0},
		 "strobe": false, "chase": CH_COLOR, "fx": "tilt"},
	],
	"Bridge": [
		{"wash": {"mode": "unison", "cols": [_PURPLE], "lvl": 0.50},
		 "mover": {"pos": "out", "mode": "split", "cols": [_PURPLE, _CYAN], "lvl": 0.50},
		 "strobe": false, "chase": "", "fx": "circle_slow"},
		{"wash": {"mode": "split", "cols": [_DEEP, _PURPLE], "lvl": 0.45},
		 "mover": {"pos": "down", "mode": "unison", "cols": [_DEEP], "lvl": 0.40},
		 "strobe": false, "chase": "", "fx": "breath"},
	],
	"Build": [
		{"wash": {"mode": "unison", "cols": [_WHITE], "lvl": 0.80},
		 "mover": {"pos": "cross", "mode": "unison", "cols": [_WHITE], "lvl": 0.85},
		 "strobe": false, "chase": CH_PULSE, "fx": "none"},
	],
	"Drop": [
		{"wash": {"mode": "unison", "cols": [_WHITE], "lvl": 1.0},
		 "mover": {"pos": "audience", "mode": "unison", "cols": [_WHITE], "lvl": 1.0},
		 "strobe": true, "chase": CH_COLOR, "fx": "circle_fast"},
		{"wash": {"mode": "split", "cols": [_RED, _WHITE], "lvl": 1.0},
		 "mover": {"pos": "cross", "mode": "split", "cols": [_RED, _WHITE], "lvl": 1.0},
		 "strobe": true, "chase": CH_SWEEP, "fx": "tilt"},
	],
	"Outro": [
		{"wash": {"mode": "unison", "cols": [_DEEP], "lvl": 0.30},
		 "mover": {"pos": "down", "mode": "unison", "cols": [_DEEP], "lvl": 0.25},
		 "strobe": false, "chase": "", "fx": "breath"},
	],
}


## -> { cues, chases, effects, timeline }
static func build(a: SongAnalysis, panels: Array) -> Dictionary:
	var fixtures := _collect(panels)
	var cues: Array = []
	var timeline: Array = []
	var seen := {}                     # label -> how many times used

	var bar := 4.0 * 60.0 / maxf(a.bpm, 40.0)

	for i in range(a.sections.size()):
		var sec: Dictionary = a.sections[i]
		var label := String(sec["label"])
		var pool: Array = RECIPES.get(label, RECIPES["Verse"])
		var occ := int(seen.get(label, 0))
		seen[label] = occ + 1
		var recipe: Dictionary = pool[occ % pool.size()]

		var e := float(sec["energy"])
		var per_uni := _blank(panels.size())
		for fx in fixtures:
			_apply_recipe(per_uni, fx, recipe, e)

		var fade: float = float(FADE.get(label, 2.0))
		var cue := Cue.new("%d. %s%s" % [i + 1, label, ("" if occ == 0 else " %d" % (occ + 1))],
			fade, fade + 0.4)
		cue.auto = true
		cue.set_levels(per_uni)
		cues.append(cue)

		var t := _section_start(a, sec)
		if label == "Drop" and t > bar:
			timeline.append({"t": t - bar * 0.5, "kind": "blackout", "arg": 0})
		timeline.append({"t": t, "kind": "cue", "arg": i})
		for ch in ALL_CHASES:
			timeline.append({"t": t, "kind": "chase", "arg": {"name": ch, "on": ch == recipe["chase"]}})
		var on_fx: Array = FX_SETS.get(recipe["fx"], [])
		for fxn in FX.keys():
			timeline.append({"t": t, "kind": "effect", "arg": {"name": fxn, "on": fxn in on_fx}})

	# the shared blackout cue, appended last; resolve its timeline events
	var bo := Cue.new("◦ Blackout", 0.04, 0.04)
	bo.auto = true
	bo.set_levels(_blank(panels.size()))
	cues.append(bo)
	var bo_index := cues.size() - 1
	for ev in timeline:
		if ev["kind"] == "blackout":
			ev["kind"] = "cue"
			ev["arg"] = bo_index

	timeline.sort_custom(func(x, y): return float(x["t"]) < float(y["t"]))
	return {
		"cues": cues,
		"chases": _chases(panels, fixtures, a.bpm),
		"effects": _effects(a.bpm),
		"timeline": timeline,
	}


# ============================================================ FIXTURES ==

static func _collect(panels: Array) -> Array:
	var out: Array = []
	var counts := {}
	for u in range(panels.size()):
		for fx in panels[u].patched_fixtures:
			var prof: FixtureProfile = fx["profile"]
			var chans: Array = prof.channels_for_mode(int(fx.get("mode", 0)))
			var kind := _classify(chans)
			var e: Dictionary = {"u": u, "start": int(fx["start"]), "chans": chans, "kind": kind}
			e["gi"] = int(counts.get(kind, 0))
			counts[kind] = e["gi"] + 1
			out.append(e)
	for e in out:
		e["gn"] = int(counts[e["kind"]])
	return out


static func _classify(chans: Array) -> String:
	var r := {}
	for ch in chans:
		r[String(ch["role"])] = true
	if r.has("PAN") and r.has("TILT"):
		return "mover"
	if r.has("STROBE") and not (r.has("RED") or r.has("DIMMER")):
		return "strobe"
	if r.has("RED") or r.has("GREEN") or r.has("BLUE"):
		return "wash"
	if r.has("DIMMER"):
		return "dimmer"
	return "other"


# ============================================================== LOOKS ==

static func _apply_recipe(per_uni: Array, fx: Dictionary, recipe: Dictionary, energy: float) -> void:
	var em := lerpf(0.8, 1.12, energy)
	match String(fx["kind"]):
		"mover":
			var m: Dictionary = recipe["mover"]
			var pt := _position(String(m["pos"]), fx["gi"], fx["gn"])
			_paint(per_uni, fx, _pick(m, fx["gi"]), clampf(float(m["lvl"]) * em, 0.05, 1.0),
				pt.x, pt.y, false)
		"strobe":
			_paint(per_uni, fx, _WHITE, 1.0, -1, -1, bool(recipe.get("strobe", false)))
		_:
			var w: Dictionary = recipe["wash"]
			_paint(per_uni, fx, _pick(w, fx["gi"]), clampf(float(w["lvl"]) * em, 0.05, 1.0),
				-1, -1, false)


static func _pick(spec: Dictionary, gi: int) -> Color:
	var cols: Array = spec["cols"]
	match String(spec["mode"]):
		"unison": return cols[0]
		"split": return cols[gi % mini(2, cols.size())]
		"rainbow": return cols[gi % cols.size()]
	return cols[0]


## Pan / tilt DMX values (0-255) for a named position, fixture `gi` of `gn`.
static func _position(name: String, gi: int, gn: int) -> Vector2i:
	var frac := 0.0
	if gn > 1:
		frac = (float(gi) / float(gn - 1) - 0.5) * 2.0     # -1 .. 1
	match name:
		"out": return Vector2i(clampi(128 + int(frac * 95.0), 0, 255), 104)
		"cross": return Vector2i(58 if gi % 2 == 0 else 198, 120)
		"audience": return Vector2i(128, 214)
		"updown": return Vector2i(128, 92 if gi % 2 == 0 else 178)
		_: return Vector2i(128, 128)   # "down"


static func _paint(per_uni: Array, fx: Dictionary, col: Color, lvl: float,
		pan: int, tilt: int, strobe: bool) -> void:
	var u: int = fx["u"]
	if u < 0 or u >= per_uni.size():
		return
	var d: Dictionary = per_uni[u]
	var start: int = fx["start"]
	var chans: Array = fx["chans"]

	var has_dimmer := false
	for ch in chans:
		if String(ch["role"]) == "DIMMER":
			has_dimmer = true
	var rgb := 1.0 if has_dimmer else lvl

	for li in range(chans.size()):
		var c := start + li
		match String(chans[li]["role"]):
			"DIMMER": d[c] = int(round(lvl * 255.0))
			"RED": d[c] = int(round(col.r * 255.0 * rgb))
			"GREEN": d[c] = int(round(col.g * 255.0 * rgb))
			"BLUE": d[c] = int(round(col.b * 255.0 * rgb))
			"WHITE": d[c] = int(round(minf(col.r, minf(col.g, col.b)) * 200.0 * rgb))
			"PAN":
				if pan >= 0:
					d[c] = pan
			"TILT":
				if tilt >= 0:
					d[c] = tilt
			"STROBE": d[c] = 200 if strobe else 0


static func _blank(n: int) -> Array:
	var a: Array = []
	for i in range(n):
		a.append({})
	return a


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


# ============================================================= CHASES ==

static func _chases(panels: Array, fixtures: Array, bpm: float) -> Array:
	return [
		_colour_chase(panels, fixtures),
		_pulse_chase(panels, fixtures),
		_sweep_chase(panels, fixtures, bpm),
	]


static func _look_from(per_uni: Array) -> Array:
	var look: Array = []
	for d in per_uni:
		var out := {}
		for k in d.keys():
			out[str(int(k))] = clampi(int(d[k]), 0, 255)
		look.append(out)
	return look


## Bold colour rotating across every fixture, one step per beat.
static func _colour_chase(panels: Array, fixtures: Array) -> Chase:
	var c := Chase.new()
	c.name = CH_COLOR
	c.bpm = 120.0
	c.beat_sync = true
	var pal := [_RED, _COOL, _MAGENTA, _GREEN, _WARM, _CYAN]
	for step in range(pal.size()):
		var per_uni := _blank(panels.size())
		for fx in fixtures:
			var pt := _position("out", fx["gi"], fx["gn"]) if fx["kind"] == "mover" else Vector2i(-1, -1)
			_paint(per_uni, fx, pal[(fx["gi"] + step) % pal.size()], 1.0, pt.x, pt.y, false)
		c.steps.append(_look_from(per_uni))
	return c


## Dimmer runs along the fixtures — one bright, the rest dim.
static func _pulse_chase(panels: Array, fixtures: Array) -> Chase:
	var c := Chase.new()
	c.name = CH_PULSE
	c.bpm = 120.0
	c.beat_sync = true
	var steps: int = maxi(2, mini(8, fixtures.size()))
	for step in range(steps):
		var per_uni := _blank(panels.size())
		for fx in fixtures:
			var hot: bool = (fx["gi"] % steps) == step
			_paint(per_uni, fx, _WHITE, 1.0 if hot else 0.12, -1, -1, false)
		c.steps.append(_look_from(per_uni))
	return c


## Moving heads rotate through positions, smooth crossfade, every 2 beats.
static func _sweep_chase(panels: Array, fixtures: Array, bpm: float) -> Chase:
	var c := Chase.new()
	c.name = CH_SWEEP
	c.bpm = maxf(bpm * 0.5, 20.0)
	c.beat_sync = false
	c.crossfade = 0.75
	c.direction = Chase.DIR_BOUNCE
	var order := ["down", "out", "cross", "audience"]
	var cols := [_COOL, _MAGENTA, _WARM, _CYAN]
	for step in range(order.size()):
		var per_uni := _blank(panels.size())
		for fx in fixtures:
			if fx["kind"] == "mover":
				var pt := _position(order[step], fx["gi"], fx["gn"])
				_paint(per_uni, fx, cols[step % cols.size()], 1.0, pt.x, pt.y, false)
			else:
				_paint(per_uni, fx, cols[step % cols.size()], 0.85, -1, -1, false)
		c.steps.append(_look_from(per_uni))
	return c


# ============================================================ EFFECTS ==

static func _effects(bpm: float) -> Array:
	var out: Array = []
	for name in FX.keys():
		var d: Dictionary = FX[name]
		var e := WaveEffect.new()
		e.name = name
		e.role = String(d["role"])
		e.waveform = int(d["wave"])
		e.bpm = maxf(bpm * float(d["mul"]), 6.0)
		e.size = float(d["size"])
		e.center = float(d["center"])
		e.fan_deg = float(d["fan"])
		e.phase_deg = float(d["phase"])
		e.base_mode = WaveEffect.BASE_PICKUP if bool(d["pickup"]) else WaveEffect.BASE_ABSOLUTE
		out.append(e)
	return out
