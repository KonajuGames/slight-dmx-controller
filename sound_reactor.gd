class_name SoundReactor
extends RefCounted
## Maps one audio band (or the beat) onto a channel role, spread across
## the patched fixtures that carry it — the Sound Reactive counterpart of
## WaveEffect. Output is an HTP override layer, composited by `Fx` while
## the console is in Sound Reactive run mode.
##
## Targets are resolved from the live patch the same way effects are and
## baked in with set_targets().

const BAND_LEVEL := 0
const BAND_BASS := 1
const BAND_MID := 2
const BAND_TREBLE := 3
const BANDS := ["Level", "Bass", "Mid", "Treble"]

const MODE_FOLLOW := 0   ## output tracks the band value continuously
const MODE_PULSE := 1    ## each beat snaps output to `high`, then it releases
const MODES := ["Follow", "Pulse"]

var name: String = "Reactor"
var band: int = BAND_BASS
var role: String = "DIMMER"
var universe: int = -1       # -1 = every universe (ignored when `group` is set)
var group: String = ""
var mode: int = MODE_FOLLOW
var low: float = 0.0         # DMX value when the band reads 0
var high: float = 255.0      # DMX value when the band reads 1
var attack: float = 0.7      # 0..1 slew toward a rising value
var release: float = 0.12    # 0..1 slew toward a falling value
var fan: float = 0.0         # 0..1 — spreads the response across the target list
var running: bool = false

var _val := 0.0              # smoothed 0..1 drive
var _targets: Array = []     # [{ "u": int, "ch": int }]


func set_targets(t: Array) -> void:
	_targets = t


func target_count() -> int:
	return _targets.size()


func _raw() -> float:
	match band:
		BAND_BASS: return Sound.bass
		BAND_MID: return Sound.mid
		BAND_TREBLE: return Sound.treble
		_: return Sound.level


## Advance the smoothed drive. `beat` is true on a beat frame.
func advance(delta: float, beat: bool) -> void:
	var target := _raw()
	if mode == MODE_PULSE:
		if beat:
			_val = 1.0
		_val = maxf(0.0, _val - delta * lerpf(0.6, 4.0, release))
		return
	var k := clampf((attack if target > _val else release) * delta * 60.0, 0.0, 1.0)
	_val = lerpf(_val, target, k)


func write_into(layers: Array) -> void:
	if _targets.is_empty():
		return
	for i in range(_targets.size()):
		var t: Dictionary = _targets[i]
		var u := int(t["u"])
		var c := int(t["ch"])
		if u < 0 or u >= layers.size():
			continue
		var drive := _val
		if fan > 0.0 and _targets.size() > 1:
			# ripple the drive along the list so it doesn't move as one block
			var ph: float = float(i) / float(_targets.size() - 1)
			drive = clampf(_val - fan * ph * (1.0 - _val), 0.0, 1.0)
		var v := clampi(int(round(lerpf(low, high, drive))), 0, 255)
		layers[u][c] = maxi(int(layers[u].get(c, 0)), v)


func to_dict() -> Dictionary:
	return {
		"name": name, "band": band, "role": role,
		"universe": universe, "group": group, "mode": mode,
		"low": low, "high": high, "attack": attack, "release": release,
		"fan": fan,
	}


static func from_dict(d: Dictionary) -> SoundReactor:
	var r := SoundReactor.new()
	r.name = String(d.get("name", "Reactor"))
	r.band = clampi(int(d.get("band", BAND_BASS)), 0, BANDS.size() - 1)
	r.role = String(d.get("role", "DIMMER"))
	r.universe = int(d.get("universe", -1))
	r.group = String(d.get("group", ""))
	r.mode = clampi(int(d.get("mode", 0)), 0, MODES.size() - 1)
	r.low = clampf(float(d.get("low", 0.0)), 0.0, 255.0)
	r.high = clampf(float(d.get("high", 255.0)), 0.0, 255.0)
	r.attack = clampf(float(d.get("attack", 0.7)), 0.0, 1.0)
	r.release = clampf(float(d.get("release", 0.12)), 0.0, 1.0)
	r.fan = clampf(float(d.get("fan", 0.0)), 0.0, 1.0)
	return r
