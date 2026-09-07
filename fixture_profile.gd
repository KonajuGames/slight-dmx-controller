class_name FixtureProfile
extends RefCounted
## Describes one fixture "type": one or more DMX *modes*, each an ordered
## list of channels tagged with a role (DIMMER, RED, GREEN, BLUE, PAN,
## TILT, ...). Beyond the role, a channel can carry:
##   - "default": home value the fixture snaps to when patched / "Home"d
##   - "min" / "max": clamp limits for that channel's control
##   - "fine": true  -> this channel is the 16-bit LSB partner of the
##             channel immediately before it (PAN + Pan Fine, etc.)
##   - "ranges": [{"lo", "hi", "label"}, ...] -> named value slots
##             (gobo / colour-wheel positions) shown as a dropdown
##
## The GUI reads all of this to draw purpose-built controls once the
## fixture is patched at a start channel (a colour picker for an RGB
## trio, one high-res slider for a 16-bit pair, a slot dropdown for a
## gobo wheel, a plain slider for everything else).
##
## Profiles are plain data (id, name, modes) so they serialize to JSON
## directly for saving custom profiles and patch lists to disk.

const ROLES: Array[String] = [
	"DIMMER", "RED", "GREEN", "BLUE", "WHITE", "AMBER", "UV",
	"PAN", "PAN_FINE", "TILT", "TILT_FINE",
	"STROBE", "ZOOM", "GOBO", "GOBO_ROT", "COLOR_WHEEL", "GENERIC",
]

## Physical hints for the 3D visualizer. `category` is one of
## moving_head / wash / par / beam / strip / blinder / generic ("" = let
## the visualizer guess from the roles).
const PHYSICAL_DEFAULT := {
	"category": "",
	"beam_deg": 14.0,
	"pan_range": 540.0,
	"tilt_range": 270.0,
	## Per-head placement for multi-head fixtures — an LED bar's cells, a
	## spider's beams. Each entry is [x, y, z] (metres) or
	## [x, y, z, rot_x, rot_y, rot_z] (metres + degrees, Godot XYZ euler,
	## rotation relative to the first head). Empty = single head. Index
	## matches the order of RGB triplets in the channel list.
	"heads": [],
}

## Intensity roles that make up a "head" (an RGB triplet plus its extras).
const HEAD_ROLES := ["RED", "GREEN", "BLUE", "WHITE", "AMBER", "UV"]

var id: String
var profile_name: String
## Array of {"name": String, "channels": Array}. Always has at least one
## entry once the profile carries any channels; a single-mode fixture
## just has one.
var modes: Array = []
var physical: Dictionary = PHYSICAL_DEFAULT.duplicate()
## Optional GDTF geometry: { "tree": <node>, "pan_geo": String,
## "tilt_geo": String, "models_dir": String }. A node is
## { "name", "kind" (geometry|axis|beam), "mat" (16 floats),
##   "model" (String), "beam_deg" (float), "children": [node...] }.
## Empty when the profile wasn't imported from a geometry-rich GDTF.
var geometry: Dictionary = {}


func _init(p_id: String = "", p_name: String = "", p_channels: Array = [], p_modes: Array = [], p_physical: Dictionary = {}) -> void:
	id = p_id
	profile_name = p_name
	modes = []
	physical = _normalize_physical(p_physical)
	if not p_modes.is_empty():
		for m in p_modes:
			modes.append(_normalize_mode(m))
	elif not p_channels.is_empty():
		modes.append({"name": "Default", "channels": _normalize_channels(p_channels)})


static func _normalize_physical(p: Dictionary) -> Dictionary:
	var heads: Array = []
	for e in p.get("heads", []):
		if e is Array and e.size() == 3:
			heads.append([float(e[0]), float(e[1]), float(e[2]), 0.0, 0.0, 0.0])
		elif e is Array and e.size() >= 6:
			heads.append([float(e[0]), float(e[1]), float(e[2]),
				float(e[3]), float(e[4]), float(e[5])])
	return {
		"category": String(p.get("category", "")),
		"beam_deg": clampf(float(p.get("beam_deg", 14.0)), 1.0, 120.0),
		"pan_range": clampf(float(p.get("pan_range", 540.0)), 0.0, 1080.0),
		"tilt_range": clampf(float(p.get("tilt_range", 270.0)), 0.0, 540.0),
		"heads": heads,
	}


## Group the mode's channels into heads:
##   [{ r, g, b, extra:[idx], offset:Vector3, rotation:Vector3 }].
## One head per RGB triplet, in channel order; WHITE/AMBER/UV between/after a
## triplet fold into it. Empty if the fixture has no RGB. `offset` (metres)
## and `rotation` (radians, relative to head 0) come from `physical.heads`,
## or a horizontal spread with no rotation when that's absent.
func head_groups(mode_index: int) -> Array:
	var chans := channels_for_mode(mode_index)
	var heads: Array = []
	var cur = null
	for i in range(chans.size()):
		match String(chans[i]["role"]):
			"RED":
				if cur != null and cur["g"] != -1 and cur["b"] != -1:
					heads.append(cur)
					cur = null
				if cur == null:
					cur = {"r": i, "g": -1, "b": -1, "extra": []}
				else:
					cur["r"] = i
			"GREEN":
				if cur == null:
					cur = {"r": -1, "g": i, "b": -1, "extra": []}
				elif cur["g"] == -1:
					cur["g"] = i
			"BLUE":
				if cur == null:
					cur = {"r": -1, "g": -1, "b": i, "extra": []}
				elif cur["b"] == -1:
					cur["b"] = i
			"WHITE", "AMBER", "UV":
				if cur != null:
					cur["extra"].append(i)
	if cur != null:
		heads.append(cur)

	var full: Array = []
	for h in heads:
		if h["r"] != -1 and h["g"] != -1 and h["b"] != -1:
			full.append(h)

	var offs: Array = physical.get("heads", [])
	var n := full.size()
	for k in range(n):
		full[k]["rotation"] = Vector3.ZERO
		if k < offs.size():
			var h: Array = offs[k]
			full[k]["offset"] = Vector3(h[0], h[1], h[2])
			if h.size() >= 6:
				full[k]["rotation"] = Vector3(
					deg_to_rad(h[3]), deg_to_rad(h[4]), deg_to_rad(h[5]))
		elif n > 1:
			# no spacing in the definition — space the heads 0.15 m apart
			full[k]["offset"] = Vector3((k - (n - 1) * 0.5) * 0.15, 0, 0)
		else:
			full[k]["offset"] = Vector3.ZERO
	return full


# ------------------------------------------------------------ NORMALIZE --
# Every channel dict is forced into the same complete shape so the rest
# of the code never has to test for missing keys.

static func _normalize_channel(c: Dictionary) -> Dictionary:
	var lo := clampi(int(c.get("min", 0)), 0, 255)
	var hi := clampi(int(c.get("max", 255)), 0, 255)
	if lo > hi:
		var tmp := lo
		lo = hi
		hi = tmp

	var ch := {
		"name": String(c.get("name", "Ch")),
		"role": String(c.get("role", "GENERIC")),
		"min": lo,
		"max": hi,
		"default": clampi(int(c.get("default", 0)), lo, hi),
		"fine": bool(c.get("fine", false)),
		"ranges": [],
	}

	for r in c.get("ranges", []):
		var rlo := clampi(int(r.get("lo", 0)), 0, 255)
		var rhi := clampi(int(r.get("hi", 0)), 0, 255)
		if rlo > rhi:
			var tmp2 := rlo
			rlo = rhi
			rhi = tmp2
		var label := String(r.get("label", ""))
		if label == "":
			label = "%d-%d" % [rlo, rhi]
		# Optional swatch colour (HTML hex or named; the GUI also derives
		# one from the label for colour-wheel slots when blank) and an
		# optional base64 PNG (imported gobo artwork).
		ch["ranges"].append({
			"lo": rlo, "hi": rhi, "label": label,
			"color": String(r.get("color", "")),
			"image": String(r.get("image", "")),
		})

	return ch


static func _normalize_channels(arr: Array) -> Array:
	var out: Array = []
	for c in arr:
		out.append(_normalize_channel(c))
	return out


static func _normalize_mode(m: Dictionary) -> Dictionary:
	return {
		"name": String(m.get("name", "Mode")),
		"channels": _normalize_channels(m.get("channels", [])),
	}


# --------------------------------------------------------------- ACCESS --

func mode_count() -> int:
	return modes.size()


func mode_names() -> Array:
	var out: Array = []
	for m in modes:
		out.append(m["name"])
	return out


func channels_for_mode(mode_index: int) -> Array:
	if modes.is_empty():
		return []
	return modes[clampi(mode_index, 0, modes.size() - 1)]["channels"]


## Channel count of the given mode (mode 0 by default).
func channel_count(mode_index: int = 0) -> int:
	return channels_for_mode(mode_index).size()


# -------------------------------------------------------- SERIALIZATION --

func to_dict() -> Dictionary:
	var mode_dicts: Array = []
	for m in modes:
		mode_dicts.append({
			"name": m["name"],
			"channels": m["channels"].duplicate(true),
		})
	return {
		"id": id,
		"profile_name": profile_name,
		"physical": physical.duplicate(true),
		"geometry": geometry.duplicate(true),
		"modes": mode_dicts,
	}


static func from_dict(d: Dictionary) -> FixtureProfile:
	var p := FixtureProfile.new()
	p.id = String(d.get("id", ""))
	p.profile_name = String(d.get("profile_name", "Custom"))
	p.physical = _normalize_physical(d.get("physical", {}))
	var g = d.get("geometry", {})
	p.geometry = g.duplicate(true) if g is Dictionary else {}
	p.modes = []

	var raw_modes = d.get("modes", null)
	if raw_modes is Array and not (raw_modes as Array).is_empty():
		for m in raw_modes:
			p.modes.append(_normalize_mode(m))
	else:
		# Legacy format: a bare "channels" list becomes one "Default" mode.
		p.modes.append({
			"name": "Default",
			"channels": _normalize_channels(d.get("channels", [])),
		})
	return p


# ------------------------------------------------------- BUILT-IN SLOTS --
# Illustrative value ranges reused by the built-in multi-mode fixture.
# Real fixtures differ — always check the DMX chart.

static func _strobe_ranges() -> Array:
	return [
		{"lo": 0, "hi": 7, "label": "Shutter closed"},
		{"lo": 8, "hi": 15, "label": "Shutter open"},
		{"lo": 16, "hi": 131, "label": "Strobe slow-fast"},
		{"lo": 132, "hi": 255, "label": "Shutter open"},
	]


static func _color_wheel_ranges() -> Array:
	return [
		{"lo": 0, "hi": 9, "label": "Open / white", "color": "#ffffff"},
		{"lo": 10, "hi": 19, "label": "Red", "color": "#e01f1f"},
		{"lo": 20, "hi": 29, "label": "Orange", "color": "#f07a10"},
		{"lo": 30, "hi": 39, "label": "Yellow", "color": "#f2d011"},
		{"lo": 40, "hi": 49, "label": "Green", "color": "#1fae3d"},
		{"lo": 50, "hi": 59, "label": "Blue", "color": "#1f52e0"},
		{"lo": 60, "hi": 69, "label": "Magenta", "color": "#d016b0"},
	]


static func _gobo_ranges() -> Array:
	return [
		{"lo": 0, "hi": 7, "label": "Open"},
		{"lo": 8, "hi": 15, "label": "Gobo 1"},
		{"lo": 16, "hi": 23, "label": "Gobo 2"},
		{"lo": 24, "hi": 31, "label": "Gobo 3"},
		{"lo": 32, "hi": 39, "label": "Gobo 4"},
		{"lo": 40, "hi": 47, "label": "Gobo 5"},
	]


## A handful of common fixture shapes to start from. Real-world fixtures
## vary in channel order — always check the fixture's own DMX chart before
## trusting one of these for a physical light.
static func built_in_profiles() -> Array[FixtureProfile]:
	var list: Array[FixtureProfile] = []

	list.append(FixtureProfile.new("dimmer1", "Dimmer (1ch)", [
		{"name": "Dimmer", "role": "DIMMER"},
	]))

	list.append(FixtureProfile.new("rgb3", "RGB (3ch)", [
		{"name": "Red", "role": "RED"},
		{"name": "Green", "role": "GREEN"},
		{"name": "Blue", "role": "BLUE"},
	]))

	list.append(FixtureProfile.new("rgbw4", "RGBW (4ch)", [
		{"name": "Red", "role": "RED"},
		{"name": "Green", "role": "GREEN"},
		{"name": "Blue", "role": "BLUE"},
		{"name": "White", "role": "WHITE"},
	]))

	list.append(FixtureProfile.new("rgbaw5", "RGBAW (5ch)", [
		{"name": "Red", "role": "RED"},
		{"name": "Green", "role": "GREEN"},
		{"name": "Blue", "role": "BLUE"},
		{"name": "Amber", "role": "AMBER"},
		{"name": "White", "role": "WHITE"},
	]))

	list.append(FixtureProfile.new("mh_rgbw_pt7", "Moving Head RGBW Pan/Tilt (7ch)", [
		{"name": "Pan", "role": "PAN"},
		{"name": "Tilt", "role": "TILT"},
		{"name": "Dimmer", "role": "DIMMER"},
		{"name": "Red", "role": "RED"},
		{"name": "Green", "role": "GREEN"},
		{"name": "Blue", "role": "BLUE"},
		{"name": "White", "role": "WHITE"},
	]))

	# Multi-mode example: same fixture, an 8-channel and a 16-bit
	# 14-channel personality. Shows off fine channels, value slots,
	# and per-channel defaults all at once.
	list.append(FixtureProfile.new("mh_spot", "Moving Head Spot (multi-mode)", [], [
		{
			"name": "8 ch",
			"channels": [
				{"name": "Pan", "role": "PAN", "default": 128},
				{"name": "Tilt", "role": "TILT", "default": 128},
				{"name": "Dimmer", "role": "DIMMER"},
				{"name": "Shutter", "role": "STROBE", "ranges": _strobe_ranges(), "default": 12},
				{"name": "Colour Wheel", "role": "COLOR_WHEEL", "ranges": _color_wheel_ranges()},
				{"name": "Gobo Wheel", "role": "GOBO", "ranges": _gobo_ranges()},
				{"name": "Gobo Rotation", "role": "GENERIC"},
				{"name": "Pan/Tilt Speed", "role": "GENERIC"},
			],
		},
		{
			"name": "14 ch (16-bit)",
			"channels": [
				{"name": "Pan", "role": "PAN", "default": 128},
				{"name": "Pan Fine", "role": "PAN_FINE", "fine": true},
				{"name": "Tilt", "role": "TILT", "default": 128},
				{"name": "Tilt Fine", "role": "TILT_FINE", "fine": true},
				{"name": "Pan/Tilt Speed", "role": "GENERIC"},
				{"name": "Dimmer", "role": "DIMMER"},
				{"name": "Dimmer Fine", "role": "GENERIC", "fine": true},
				{"name": "Shutter", "role": "STROBE", "ranges": _strobe_ranges(), "default": 12},
				{"name": "Colour Wheel", "role": "COLOR_WHEEL", "ranges": _color_wheel_ranges()},
				{"name": "Gobo Wheel", "role": "GOBO", "ranges": _gobo_ranges()},
				{"name": "Gobo Rotation", "role": "GENERIC"},
				{"name": "Prism", "role": "GENERIC"},
				{"name": "Focus", "role": "GENERIC", "default": 128},
				{"name": "Function", "role": "GENERIC"},
			],
		},
	]))

	return list
