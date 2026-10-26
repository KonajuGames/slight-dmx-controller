class_name LiveFlash
extends RefCounted
## The live override layer: flash buttons that sit on top of everything
## else in the DMX frame — the console, song timelines (DJ Perform Mode,
## DJ Edit Mode playback), chases and effects — while they're held (or,
## latched, until pressed again). For reacting to a drop the timeline
## didn't see coming.
##
##   BLACKOUT  every fixture's intensity to 0 (dimmer and colour / white
##             channels; pan, tilt and the rest are left alone, so movers
##             don't swing)
##   STROBE    full intensity, strobing: a STROBE channel set to strobe
##             fast, or on a fixture without one its intensity flashed in
##             software (SOFT_STROBE_HZ)
##   WHITE     full white: dimmer, red, green, blue and white full, amber
##             and UV off; a colour wheel to its whitest slot
##   COLOUR    full in `colour`: dimmer full, red / green / blue from it,
##             white / amber / UV off; a colour wheel to its nearest slot
##
## STROBE combines with WHITE or COLOUR (a white or coloured strobe); on
## its own it strobes the colours already playing. WHITE beats COLOUR,
## and BLACKOUT beats everything. A STROBE channel is opened (its "open"
## value) under WHITE / COLOUR without STROBE, so the flash doesn't
## inherit a timeline's strobing.
##
## layer() is an ArtNet top layer: applied after the fixtures' virtual
## dimmers, so a fixture dimmed that way still flashes, and before the
## grand master.

enum { BLACKOUT, STROBE, WHITE, COLOUR }
const NAMES := ["Blackout", "Strobe", "White", "Colour"]
## The key that works each one in DJ Perform Mode.
const KEYS := [KEY_B, KEY_S, KEY_W, KEY_C]

const SOFT_STROBE_HZ := 10.0
## The part of each software-strobe cycle that's lit.
const SOFT_STROBE_DUTY := 0.34

const _INTENSITY_ROLES := ["RED", "GREEN", "BLUE", "WHITE", "AMBER", "UV"]

## Something was pressed or released (buttons and feedback pads follow).
signal changed

## The COLOUR flash's colour.
var colour := Color(1, 0, 0)
## Buttons and keys toggle the flashes instead of holding them.
var latch := false
## Set by the shell: func() -> Array of patched fixtures, as DjPerformer's
## fixtures_provider gives them ({u, start, profile, mode, ...}).
var fixtures_provider := Callable()

var _on := {}                # kind -> true while it's on


func is_on(kind: int) -> bool:
	return _on.has(kind)


func any_on() -> bool:
	return not _on.is_empty()


## A button / key / pad went down: the flash goes on (latched: toggles).
func press(kind: int) -> void:
	if latch:
		toggle(kind)
	else:
		set_on(kind, true)


## ...and came back up: off again (latched: nothing).
func release(kind: int) -> void:
	if not latch:
		set_on(kind, false)


func toggle(kind: int) -> void:
	set_on(kind, not is_on(kind))


func set_on(kind: int, on: bool) -> void:
	if kind < 0 or kind >= NAMES.size() or on == is_on(kind):
		return
	if on:
		_on[kind] = true
	else:
		_on.erase(kind)
	changed.emit()


func clear() -> void:
	if _on.is_empty():
		return
	_on.clear()
	changed.emit()


## The top layer for ArtNet.tick(): n {channel: value} dictionaries.
func layer(n: int) -> Array:
	var empty: Array = []
	if _on.is_empty() or not fixtures_provider.is_valid():
		for i in range(n):
			empty.append({})
		return empty
	return output(fixtures_provider.call(), n, _on.keys(), colour, Time.get_ticks_msec() / 1000.0)


## The flashes in `kinds` over `fixtures`, as n {channel: value}
## dictionaries, at `t` seconds (for the software strobe's phase).
static func output(fixtures: Array, n: int, kinds: Array, flash_colour: Color, t: float) -> Array:
	var out: Array = []
	for i in range(n):
		out.append({})
	if kinds.is_empty():
		return out
	var blackout := kinds.has(BLACKOUT)
	var strobe := kinds.has(STROBE)
	var tint = Color.WHITE if kinds.has(WHITE) else (flash_colour if kinds.has(COLOUR) else null)
	var soft_lit := fmod(t * SOFT_STROBE_HZ, 1.0) < SOFT_STROBE_DUTY
	for fx in fixtures:
		var u: int = fx["u"]
		if u < 0 or u >= n:
			continue
		var profile: FixtureProfile = fx["profile"]
		var mode: int = fx.get("mode", 0)
		var start: int = fx["start"]
		var chans := profile.channels_for_mode(mode)
		var o: Dictionary = out[u]
		var has_rgb := not profile.head_groups(mode).is_empty()
		var has_strobe := false
		for k in range(chans.size()):
			if String(chans[k]["role"]) == "STROBE":
				has_strobe = true
		# Lit this frame: always, but in the software strobe's off part.
		var lit := not blackout and (not strobe or has_strobe or soft_lit)
		for k in range(chans.size()):
			var ch: Dictionary = chans[k]
			var role := String(ch["role"])
			var fine := bool(ch.get("fine", false))
			match role:
				"DIMMER":
					o[start + k] = 255 if lit else 0
				"STROBE":
					if blackout or fine:
						continue
					if strobe:
						o[start + k] = DjPerformer.strobe_value(ch, TimelineTrack.Strobe.FAST)
					elif tint != null:
						o[start + k] = open_value(ch)
				"COLOR_WHEEL":
					if tint != null and lit and not has_rgb and not fine:
						var v := FixtureProfile.nearest_wheel_value(ch, tint)
						if v >= 0:
							o[start + k] = v
				_:
					if role not in _INTENSITY_ROLES:
						continue
					if not lit:
						o[start + k] = 0
					elif tint != null:
						o[start + k] = _tint_value(role, tint, kinds.has(WHITE))
					# STROBE alone: the colours playing, unchanged.
	return out


## A colour / white channel's level for a WHITE or COLOUR flash.
static func _tint_value(role: String, tint: Color, white: bool) -> int:
	match role:
		"RED": return int(round(tint.r * 255.0))
		"GREEN": return int(round(tint.g * 255.0))
		"BLUE": return int(round(tint.b * 255.0))
		"WHITE": return 255 if white else 0
	return 0                        # amber, UV


## The value that holds a STROBE channel open (lit, not strobing): the
## start of a range labelled open, else of one that's neither strobing
## nor closed, else 0.
static func open_value(ch: Dictionary) -> int:
	var ranges: Array = ch.get("ranges", [])
	for r in ranges:
		if "open" in String(r.get("label", "")).to_lower():
			return int(r["lo"])
	for r in ranges:
		var lbl := String(r.get("label", "")).to_lower()
		if not ("strob" in lbl or "puls" in lbl or "closed" in lbl or "black" in lbl or "random" in lbl):
			return int(r["lo"])
	return 0


func to_dict() -> Dictionary:
	return {"colour": colour.to_html(false), "latch": latch}


func from_dict(d: Dictionary) -> void:
	colour = Color.from_string(String(d.get("colour", "ff0000")), Color(1, 0, 0))
	latch = bool(d.get("latch", false))
	clear()
