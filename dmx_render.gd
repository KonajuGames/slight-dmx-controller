class_name DmxRender
extends RefCounted
## Turns a fixture's live DMX (its slice of a universe's composited
## `output` buffer) into a visual state the 3D view applies:
##   { color, dimmer, pan, tilt, strobe_hz, gobo, zoom, blackout }
##
## Pure and stateless — call it every frame per fixture.

static func _read(buf: PackedByteArray, i: int) -> int:
	return int(buf[i]) if i >= 0 and i < buf.size() else 0


## The range slot `raw` falls into for a channel, or {} if none / no ranges.
static func _slot_at(ch: Dictionary, raw: int) -> Dictionary:
	for r in ch.get("ranges", []):
		if raw >= int(r["lo"]) and raw <= int(r["hi"]):
			return r
	return {}


static func _slot_color(ch: Dictionary, raw: int):
	var slot := _slot_at(ch, raw)
	if slot.is_empty():
		return null
	var hex := String(slot.get("color", ""))
	if hex != "":
		return Color.from_string(hex, Color.WHITE)
	var lbl := String(slot.get("label", "")).to_lower()
	if "open" in lbl or "white" in lbl or "none" in lbl:
		return null  # open slot: keep whatever colour the LEDs make
	for w in lbl.replace("/", " ").replace("-", " ").split(" ", false):
		var c := Color.from_string(w, Color.TRANSPARENT)
		if c != Color.TRANSPARENT:
			return c
	return null


static func _strobe_hz(ch: Dictionary, raw: int) -> float:
	var ranges: Array = ch.get("ranges", [])
	if not ranges.is_empty():
		var slot := _slot_at(ch, raw)
		if slot.is_empty():
			return 0.0
		var lbl := String(slot.get("label", "")).to_lower()
		if "strob" in lbl or "pulse" in lbl or "-fast" in lbl or "slow" in lbl:
			var lo := int(slot["lo"])
			var hi := maxi(int(slot["hi"]), lo + 1)
			return lerpf(1.0, 25.0, float(raw - lo) / float(hi - lo))
		return 0.0
	# no chart: guess a strobe band in the middle of the channel
	if raw >= 20 and raw <= 240:
		return lerpf(1.0, 22.0, float(raw - 20) / 220.0)
	return 0.0


static func _shutter_closed(ch: Dictionary, raw: int) -> bool:
	var slot := _slot_at(ch, raw)
	if slot.is_empty():
		return false
	var lbl := String(slot.get("label", "")).to_lower()
	return "closed" in lbl or "black" in lbl


## `out_buf` is the universe's composited output; `start` is 0-based.
static func evaluate(profile: FixtureProfile, mode: int, out_buf: PackedByteArray, start: int) -> Dictionary:
	var chans: Array = profile.channels_for_mode(mode)
	var phys: Dictionary = profile.physical
	var beam_deg := float(phys.get("beam_deg", 14.0))

	var st := {
		"color": Color.WHITE, "dimmer": 0.0,
		"pan": 0.0, "tilt": 0.0,
		"strobe_hz": 0.0, "gobo": "", "gobo_rot": 0.0,
		"zoom": beam_deg, "blackout": false,
	}

	var col := Color(0, 0, 0)     # accumulated additive colour drive
	var has_rgb := false
	var wheel_hue = null
	var dim := -1.0

	for ci in range(chans.size()):
		var ch: Dictionary = chans[ci]
		var role := String(ch["role"])
		var raw := _read(out_buf, start + ci)
		var has_fine: bool = ci + 1 < chans.size() and bool(chans[ci + 1].get("fine", false))

		match role:
			"DIMMER":
				dim = raw / 255.0
			"RED":
				col.r += raw / 255.0
				has_rgb = true
			"GREEN":
				col.g += raw / 255.0
				has_rgb = true
			"BLUE":
				col.b += raw / 255.0
				has_rgb = true
			"WHITE":
				var v := raw / 255.0
				col += Color(v, v * 0.95, v * 0.85)
				has_rgb = true
			"AMBER":
				var va := raw / 255.0
				col += Color(va, va * 0.55, 0.0)
				has_rgb = true
			"UV":
				var vu := raw / 255.0
				col += Color(vu * 0.45, 0.0, vu)
				has_rgb = true
			"PAN":
				var pv := raw * 256 + _read(out_buf, start + ci + 1) if has_fine else raw
				var span := 65535.0 if has_fine else 255.0
				st["pan"] = (pv / span - 0.5) * float(phys.get("pan_range", 540.0))
			"TILT":
				var tv := raw * 256 + _read(out_buf, start + ci + 1) if has_fine else raw
				var tspan := 65535.0 if has_fine else 255.0
				st["tilt"] = (tv / tspan - 0.5) * float(phys.get("tilt_range", 270.0))
			"ZOOM":
				st["zoom"] = lerpf(maxf(beam_deg * 0.6, 3.0), minf(beam_deg * 3.0, 70.0), raw / 255.0)
			"STROBE":
				st["strobe_hz"] = _strobe_hz(ch, raw)
				if _shutter_closed(ch, raw):
					st["blackout"] = true
			"GOBO":
				var slot := _slot_at(ch, raw)
				st["gobo"] = String(slot.get("image", "")) if not slot.is_empty() else ""
			"GOBO_ROT":
				if absi(raw - 128) > 10:
					st["gobo_rot"] = (float(raw) - 128.0) / 127.0 * 240.0  # deg/s, signed
			"COLOR_WHEEL":
				var wc = _slot_color(ch, raw)
				if wc != null:
					wheel_hue = wc

	# --- resolve colour + level ------------------------------------
	var level := 1.0
	var hue := Color.WHITE
	if has_rgb:
		level = clampf(maxf(maxf(col.r, col.g), col.b), 0.0, 1.0)
		hue = Color(col.r / level, col.g / level, col.b / level) if level > 0.001 else Color.BLACK
	elif wheel_hue != null:
		hue = wheel_hue as Color
	if wheel_hue != null and has_rgb:
		hue = hue * (wheel_hue as Color)

	st["color"] = hue
	var master := dim if dim >= 0.0 else 1.0
	st["dimmer"] = 0.0 if st["blackout"] else clampf(level * master, 0.0, 1.0)
	return st
