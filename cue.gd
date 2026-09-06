class_name Cue
extends RefCounted
## One cue: a stored "look" — every universe's DMX levels at capture time
## (non-zero channels only) plus split fade-in / fade-out times. Cues are
## non-tracking: a cue is a full state, so channels it doesn't store fade
## to 0 when the cue runs.
##
## `levels[i]` is a Dictionary { "<channel>": value } for universe slot i.

var label: String = ""
var fade_up: float = 3.0
var fade_down: float = 3.0
var levels: Array = []


func _init(p_label: String = "", p_fade_up: float = 3.0, p_fade_down: float = 3.0) -> void:
	label = p_label
	fade_up = p_fade_up
	fade_down = p_fade_down
	levels = []


## Snapshot every current universe's buffer into this cue.
func capture() -> void:
	levels = []
	for i in range(ArtNet.universe_count()):
		var u := ArtNet.get_universe(i)
		var d := {}
		for c in range(ArtNetUniverse.DMX_UNIVERSE_SIZE):
			var v := u.get_channel(c)
			if v != 0:
				d[str(c)] = v
		levels.append(d)


## Full 512-byte fade target for one universe (0 where the cue is silent).
func target_for(universe_index: int) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(ArtNetUniverse.DMX_UNIVERSE_SIZE)
	if universe_index >= 0 and universe_index < levels.size():
		var d: Dictionary = levels[universe_index]
		for key in d.keys():
			var c := int(key)
			if c >= 0 and c < buf.size():
				buf[c] = clampi(int(d[key]), 0, 255)
	return buf


func universe_count() -> int:
	return levels.size()


func to_dict() -> Dictionary:
	return {
		"label": label,
		"fade_up": fade_up,
		"fade_down": fade_down,
		"levels": levels.duplicate(true),
	}


static func from_dict(d: Dictionary) -> Cue:
	var c := Cue.new(
		String(d.get("label", "")),
		float(d.get("fade_up", 3.0)),
		float(d.get("fade_down", 3.0)))
	c.levels = []
	for entry in d.get("levels", []):
		var ud := {}
		if entry is Dictionary:
			for k in entry.keys():
				ud[String(k)] = clampi(int(entry[k]), 0, 255)
		c.levels.append(ud)
	return c
