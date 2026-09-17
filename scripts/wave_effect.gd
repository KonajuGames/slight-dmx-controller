class_name WaveEffect
extends RefCounted
## A parametric waveform on one channel role, spread across the patched
## fixtures that carry that role. Classic uses: a dimmer pulse, a pan/tilt
## circle (pan sine + tilt sine at 90° phase), a colour swell.
##
## Channel targets are resolved from the live patch (role -> channels) and
## baked in with set_targets(); rebuild them if the patch changes.

const SINE := 0
const TRIANGLE := 1
const SAW := 2
const SQUARE := 3
const RANDOM := 4

const WAVEFORMS := ["Sine", "Triangle", "Sawtooth", "Square", "Random"]

const BASE_ABSOLUTE := 0  # swing around `center`
const BASE_PICKUP := 1    # swing around the channel's live base value
const BASE_MODES := ["Absolute", "Pickup"]

## Roles driven by a physical motor — pan, tilt, zoom heads can't chase a
## fast waveform, so their rate is capped.
const MOTOR_ROLES := ["PAN", "PAN_FINE", "TILT", "TILT_FINE", "ZOOM"]
const MOTOR_MAX_BPM := 60.0

var name: String = "Effect"
var role: String = "DIMMER": set = _set_role
var universe: int = -1        # -1 = every universe (ignored when `group` is set)
var group: String = ""       # fixture-group name, "" = universe filter
var waveform: int = SINE
var base_mode: int = BASE_ABSOLUTE
var bpm: float = 60.0: set = _set_bpm
var size: float = 128.0       # peak-to-peak swing
var center: float = 128.0     # midpoint level (Absolute mode)
var fan_deg: float = 0.0      # phase spread across the target list
var phase_deg: float = 0.0    # global phase offset
var running: bool = false

var _phase := 0.0             # elapsed cycles
var _targets: Array = []      # [{ "u": int, "ch": int }]
var _rng := RandomNumberGenerator.new()
var _rand_vals: Array = []
var _rand_step := -1


## The rate a pan/tilt/zoom effect can actually be run at.
func max_bpm() -> float:
	return MOTOR_MAX_BPM if role in MOTOR_ROLES else 1200.0


func _set_role(v: String) -> void:
	role = v
	_set_bpm(bpm)   # re-clamp for the new role


func _set_bpm(v: float) -> void:
	bpm = clampf(v, 0.0, max_bpm())


func set_targets(t: Array) -> void:
	_targets = t
	_rand_vals.resize(t.size())
	_rand_step = -1


func target_count() -> int:
	return _targets.size()


func advance(delta: float) -> void:
	_phase += delta * (bpm / 60.0)


func _wave(x: float) -> float:
	var f := x - floorf(x)  # 0..1
	match waveform:
		TRIANGLE:
			return 1.0 - 4.0 * absf(f - 0.5)
		SAW:
			return 2.0 * f - 1.0
		SQUARE:
			return 1.0 if f < 0.5 else -1.0
		_:
			return sin(x * TAU)


## HTP-merge this effect's output into `layers`. In Pickup mode the swing
## is centred on the matching channel's value in `bases` (the base
## buffers — fixture controls + cue fades) instead of on `center`.
func write_into(layers: Array, bases: Array = []) -> void:
	if _targets.is_empty():
		return

	if waveform == RANDOM:
		var step := int(floorf(_phase))
		if step != _rand_step:
			_rand_step = step
			for i in range(_targets.size()):
				_rand_vals[i] = _rng.randf() * 2.0 - 1.0

	for k in range(_targets.size()):
		var t: Dictionary = _targets[k]
		var u := int(t["u"])
		var c := int(t["ch"])
		if u < 0 or u >= layers.size():
			continue
		var w: float
		if waveform == RANDOM:
			w = float(_rand_vals[k]) if k < _rand_vals.size() else 0.0
		else:
			var x := _phase + phase_deg / 360.0 + (fan_deg / 360.0) * k
			w = _wave(x)

		var mid := center
		if base_mode == BASE_PICKUP and u < bases.size():
			var buf: PackedByteArray = bases[u]
			mid = float(buf[c]) if c >= 0 and c < buf.size() else 0.0

		var v := clampi(int(round(mid + (size * 0.5) * w)), 0, 255)
		layers[u][c] = maxi(int(layers[u].get(c, 0)), v)


func to_dict() -> Dictionary:
	return {
		"name": name, "role": role, "universe": universe, "group": group,
		"waveform": waveform, "base_mode": base_mode,
		"bpm": bpm, "size": size, "center": center,
		"fan_deg": fan_deg, "phase_deg": phase_deg,
	}


static func from_dict(d: Dictionary) -> WaveEffect:
	var e := WaveEffect.new()
	e.name = String(d.get("name", "Effect"))
	e.role = String(d.get("role", "DIMMER"))
	e.universe = int(d.get("universe", -1))
	e.group = String(d.get("group", ""))
	e.waveform = clampi(int(d.get("waveform", 0)), 0, WAVEFORMS.size() - 1)
	e.base_mode = clampi(int(d.get("base_mode", 0)), 0, BASE_MODES.size() - 1)
	e.bpm = float(d.get("bpm", 60.0))
	e.size = clampf(float(d.get("size", 128.0)), 0.0, 255.0)
	e.center = clampf(float(d.get("center", 128.0)), 0.0, 255.0)
	e.fan_deg = float(d.get("fan_deg", 0.0))
	e.phase_deg = float(d.get("phase_deg", 0.0))
	return e
