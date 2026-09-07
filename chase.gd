class_name Chase
extends RefCounted
## A chase: an ordered list of steps (captured looks, same shape as
## Cue.levels) cycled at a tempo. Unlike a cue, a chase runs continuously
## and its output is composited as an override *layer* on top of the base
## buffers (fixture controls + cue fades) rather than replacing them.

const DIR_FORWARD := 0
const DIR_BACKWARD := 1
const DIR_BOUNCE := 2

var name: String = "Chase"
var bpm: float = 120.0
## Fraction (0..1) of each step spent crossfading in from the previous
## step. 0 = hard snap.
var crossfade: float = 0.0
var direction: int = DIR_FORWARD
## When true, the chase advances one step per detected beat instead of by
## `bpm` — but only while the console is in Sound Reactive run mode.
var beat_sync: bool = false
var running: bool = false
## steps[i] is an Array (per universe) of { "<channel>": value }.
var steps: Array = []

var _pos := 0
var _from := 0
var _elapsed := 0.0
var _bounce := 1


func step_time() -> float:
	return 60.0 / maxf(bpm, 1.0)


func step_count() -> int:
	return steps.size()


## Append the current live output of every universe as a new step.
func capture_step() -> void:
	var look: Array = []
	for i in range(ArtNet.universe_count()):
		var u := ArtNet.get_universe(i)
		var d := {}
		for c in range(ArtNetUniverse.DMX_UNIVERSE_SIZE):
			var v := u.get_channel(c)
			if v != 0:
				d[str(c)] = v
		look.append(d)
	steps.append(look)


func reset() -> void:
	_pos = 0
	_from = 0
	_elapsed = 0.0
	_bounce = 1


func advance(delta: float) -> void:
	if steps.size() < 2:
		return
	_elapsed += delta
	var st := step_time()
	while _elapsed >= st:
		_elapsed -= st
		_from = _pos
		_advance_pos()


## Jump to the next step now (used by beat-sync). `_elapsed` is reset so a
## crossfade, if any, starts from this beat.
func beat_step() -> void:
	if steps.size() < 2:
		return
	_from = _pos
	_elapsed = 0.0
	_advance_pos()


func _advance_pos() -> void:
	match direction:
		DIR_BACKWARD:
			_pos = (_pos - 1 + steps.size()) % steps.size()
		DIR_BOUNCE:
			_pos += _bounce
			if _pos >= steps.size() - 1:
				_pos = steps.size() - 1
				_bounce = -1
			elif _pos <= 0:
				_pos = 0
				_bounce = 1
		_:
			_pos = (_pos + 1) % steps.size()


static func _level(look: Array, u: int, c: int) -> int:
	if u >= 0 and u < look.size():
		return int(look[u].get(str(c), 0))
	return 0


## HTP-merge this chase's current output into the per-universe layers.
func write_into(layers: Array) -> void:
	if steps.is_empty():
		return
	var cur: Array = steps[clampi(_pos, 0, steps.size() - 1)]
	var prev: Array = []
	var blend := 1.0
	if crossfade > 0.0 and steps.size() >= 2:
		var fade_dur := step_time() * crossfade
		if fade_dur > 0.0 and _elapsed < fade_dur:
			prev = steps[clampi(_from, 0, steps.size() - 1)]
			blend = _elapsed / fade_dur

	for u in range(layers.size()):
		var touched := {}
		if u < cur.size():
			for k in cur[u].keys():
				touched[k] = true
		if not prev.is_empty() and u < prev.size():
			for k in prev[u].keys():
				touched[k] = true
		for k in touched.keys():
			var c := int(k)
			var b := _level(cur, u, c)
			var a := _level(prev, u, c) if not prev.is_empty() else b
			var v := clampi(int(round(a + (b - a) * blend)), 0, 255)
			layers[u][c] = maxi(int(layers[u].get(c, 0)), v)


func to_dict() -> Dictionary:
	return {
		"name": name,
		"bpm": bpm,
		"crossfade": crossfade,
		"direction": direction,
		"beat_sync": beat_sync,
		"steps": steps.duplicate(true),
	}


static func from_dict(d: Dictionary) -> Chase:
	var c := Chase.new()
	c.name = String(d.get("name", "Chase"))
	c.bpm = float(d.get("bpm", 120.0))
	c.crossfade = clampf(float(d.get("crossfade", 0.0)), 0.0, 1.0)
	c.direction = clampi(int(d.get("direction", 0)), 0, 2)
	c.beat_sync = bool(d.get("beat_sync", false))
	c.steps = []
	for s in d.get("steps", []):
		var look: Array = []
		if s is Array:
			for entry in s:
				var ud := {}
				if entry is Dictionary:
					for k in entry.keys():
						ud[String(k)] = clampi(int(entry[k]), 0, 255)
				look.append(ud)
		c.steps.append(look)
	return c
