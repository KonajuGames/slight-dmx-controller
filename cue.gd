class_name Cue
extends RefCounted
## One cue: a stored "look" — every universe's DMX levels at capture time
## plus split fade-in / fade-out times.
##
## `levels[i]` is a Dictionary { "<channel>": value } for universe slot i.
##
## A cue is either a **block** (`tracking == false`) or a **tracking** cue
## (`tracking == true`):
##   - a block stores a full look (non-zero channels); running it wipes the
##     rig first, so channels it doesn't store go to 0.
##   - a tracking cue stores only the channels that *change* from the state
##     the previous cues leave behind (including moves to 0). Everything
##     else "tracks" through unchanged. Editing an upstream cue therefore
##     ripples down the list until the next block.
## The cue list folds the two together for playback (see CueListPanel).

var label: String = ""
var fade_up: float = 3.0
var fade_down: float = 3.0
var levels: Array = []
var tracking: bool = false


func _init(p_label: String = "", p_fade_up: float = 3.0, p_fade_down: float = 3.0) -> void:
	label = p_label
	fade_up = p_fade_up
	fade_down = p_fade_down
	levels = []


## Snapshot every current universe's buffer into this cue as a full look
## (non-zero channels only). Used for block cues.
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


## Snapshot only the channels whose live value differs from `prev_state`
## (`prev_state[i]` is a Dictionary { "<channel>": value } — the look the
## earlier cues leave standing). A channel driven to 0 over a non-zero
## previous value is stored as an explicit 0 move. Used for tracking cues.
func capture_tracked(prev_state: Array) -> void:
	levels = []
	for i in range(ArtNet.universe_count()):
		var u := ArtNet.get_universe(i)
		var prev: Dictionary = prev_state[i] if i < prev_state.size() else {}
		var d := {}
		for c in range(ArtNetUniverse.DMX_UNIVERSE_SIZE):
			var v := u.get_channel(c)
			var pv := int(prev.get(str(c), 0))
			if v != pv:
				d[str(c)] = v
		levels.append(d)


## Number of channels this cue stores (its "moves"), across all universes.
func move_count() -> int:
	var n := 0
	for d in levels:
		if d is Dictionary:
			n += d.size()
	return n


func universe_count() -> int:
	return levels.size()


func to_dict() -> Dictionary:
	return {
		"label": label,
		"fade_up": fade_up,
		"fade_down": fade_down,
		"tracking": tracking,
		"levels": levels.duplicate(true),
	}


static func from_dict(d: Dictionary) -> Cue:
	var c := Cue.new(
		String(d.get("label", "")),
		float(d.get("fade_up", 3.0)),
		float(d.get("fade_down", 3.0)))
	# Older show files predate tracking — load their cues as blocks so they
	# play back exactly as they did before.
	c.tracking = bool(d.get("tracking", false))
	c.levels = []
	for entry in d.get("levels", []):
		var ud := {}
		if entry is Dictionary:
			for k in entry.keys():
				ud[String(k)] = clampi(int(entry[k]), 0, 255)
		c.levels.append(ud)
	return c
