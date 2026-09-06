class_name FixtureImport
extends RefCounted
## Imports external fixture definitions into `FixtureProfile`:
##   - GDTF  — a ".gdtf" ZIP holding "description.xml" (DIN SPEC 15800 /
##     GDTF-Share downloads).
##   - Open Fixture Library — a single-fixture ".json" (the "Download as
##     JSON" button on open-fixture-library.org, or a raw file from the
##     project's GitHub).
##
## Best-effort: channels that don't map cleanly become GENERIC and a
## `warnings` list explains what was approximated.
##
## Every entry point returns either
##   { "profile": FixtureProfile, "warnings": Array[String] }
## or
##   { "error": String }.

const _MAX_FOOTPRINT := 512


static func from_path(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"error": "File not found."}
	var low := path.to_lower()
	if low.ends_with(".gdtf"):
		return _from_gdtf_path(path)
	if low.ends_with(".json"):
		var f := FileAccess.open(path, FileAccess.READ)
		var parsed = JSON.parse_string(f.get_as_text())
		f.close()
		if not (parsed is Dictionary):
			return {"error": "Not a JSON object."}
		if parsed.has("availableChannels"):
			return from_ofl(parsed)
		if parsed.has("modes") or parsed.has("channels"):
			return {"profile": FixtureProfile.from_dict(parsed), "warnings": []}
		return {"error": "Unrecognised JSON (expected an Open Fixture Library fixture)."}
	return {"error": "Unsupported file type — need .gdtf or .json."}


# ============================================================ SHARED ==

static func _role_for(raw: String) -> String:
	var s := raw.to_lower()
	if "dimmer" in s or "intensity" in s or s == "master" or "master dim" in s:
		return "DIMMER"
	if "coloradd_r" in s or "colorrgb_red" in s or s == "red" or s == "r":
		return "RED"
	if "coloradd_g" in s or "colorrgb_green" in s or s == "green" or s == "g":
		return "GREEN"
	if "coloradd_b" in s or "colorrgb_blue" in s or s == "blue" or s == "b":
		return "BLUE"
	if "coloradd_w" in s or s == "white" or s == "w" or "warm white" in s or "cool white" in s:
		return "WHITE"
	if "coloradd_a" in s or s == "amber" or s == "a":
		return "AMBER"
	if "coloradd_uv" in s or s == "uv" or "ultraviolet" in s:
		return "UV"
	if "pan" in s and "span" not in s:
		return "PAN"
	if "tilt" in s:
		return "TILT"
	if "gobo" in s:
		return "GOBO"
	if "color" in s and ("wheel" in s or "macro" in s or "1" in s):
		return "COLOR_WHEEL"
	if "cto" in s or "ctb" in s or "ctc" in s or "colortemp" in s:
		return "COLOR_WHEEL"
	if "strob" in s or "shutter" in s:
		return "STROBE"
	return "GENERIC"


static func _fine_role(coarse_role: String) -> String:
	match coarse_role:
		"PAN": return "PAN_FINE"
		"TILT": return "TILT_FINE"
		_: return "GENERIC"


static func _safe_id_hint(s: String) -> String:
	var out := ""
	for ch in s.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
		elif ch == " " or ch == "-" or ch == "_" or ch == "/":
			out += "_"
	while out.begins_with("_"):
		out = out.substr(1)
	while out.ends_with("_"):
		out = out.substr(0, out.length() - 1)
	return out if out != "" else "imported"


static func _srgb_gamma(c: float) -> float:
	c = clampf(c, 0.0, 1.0)
	if c <= 0.0031308:
		return 12.92 * c
	return 1.055 * pow(c, 1.0 / 2.4) - 0.055


## CIE "x,y,Y" (GDTF ColorCIE) -> "#rrggbb", or "" if unusable.
static func _cie_to_hex(cie: String) -> String:
	var parts := cie.strip_edges().split(",")
	if parts.size() < 3:
		return ""
	var x := float(parts[0])
	var y := float(parts[1])
	var big_y := float(parts[2]) / 100.0
	if y <= 0.0001:
		return ""
	big_y = clampf(big_y, 0.05, 1.0)  # keep swatches visible
	var xf := (x / y) * big_y
	var zf := ((1.0 - x - y) / y) * big_y
	var r := 3.2406 * xf - 1.5372 * big_y - 0.4986 * zf
	var g := -0.9689 * xf + 1.8758 * big_y + 0.0415 * zf
	var b := 0.0557 * xf - 0.2040 * big_y + 1.0570 * zf
	var col := Color(_srgb_gamma(r), _srgb_gamma(g), _srgb_gamma(b))
	return "#" + col.to_html(false)


# ============================================================== GDTF ==

static func _from_gdtf_path(path: String) -> Dictionary:
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return {"error": "Can't open .gdtf (not a ZIP archive?)."}
	if not zip.file_exists("description.xml"):
		zip.close()
		return {"error": "No description.xml inside the .gdtf archive."}
	var xml := zip.read_file("description.xml")

	# Case-insensitive reader for embedded media (gobo images live in
	# "wheels/<MediaFileName>.png" per the GDTF spec).
	var lut := {}
	for n in zip.get_files():
		lut[n.to_lower()] = n
	var reader := func(want: String) -> PackedByteArray:
		var key: String = want.to_lower()
		if lut.has(key):
			return zip.read_file(lut[key])
		return PackedByteArray()

	var result := from_gdtf_xml(xml, reader)
	zip.close()
	return result


static func from_gdtf_xml(xml: PackedByteArray, media_reader := Callable()) -> Dictionary:
	var root := _parse_xml(xml)
	var ft = _kid(_kid(root, "GDTF"), "FixtureType")
	if ft == null:
		return {"error": "description.xml has no <FixtureType>."}

	var warnings: Array = []
	var maker := String(ft["attrs"].get("Manufacturer", ""))
	var model := String(ft["attrs"].get("LongName", ft["attrs"].get("Name", "GDTF Fixture")))
	var fixture_name := (maker + " " + model).strip_edges() if maker != "" else model

	var wheels := _gdtf_wheels(ft, media_reader, warnings)

	var modes_node = _kid(ft, "DMXModes")
	var mode_nodes := _kids(modes_node, "DMXMode")
	if mode_nodes.is_empty():
		return {"error": "No <DMXMode> found."}

	var modes: Array = []
	for mn in mode_nodes:
		modes.append(_gdtf_mode(mn, wheels, warnings))

	var id := _safe_id_hint(fixture_name)
	var profile := FixtureProfile.new(id, fixture_name, [], modes)
	return {"profile": profile, "warnings": warnings}


static func _gdtf_wheels(ft, media_reader: Callable, warnings: Array) -> Dictionary:
	var out := {}
	var wheels_node = _kid(ft, "Wheels")
	if wheels_node == null:
		return out
	for w in _kids(wheels_node, "Wheel"):
		var slots: Array = []
		for s in _kids(w, "Slot"):
			var media := String(s["attrs"].get("MediaFileName", "")).strip_edges()
			var image := ""
			if media != "" and media_reader.is_valid():
				image = _load_media_b64(media, media_reader)
				if image == "":
					warnings.append("Gobo image '%s' not found or unreadable" % media)
			slots.append({
				"name": String(s["attrs"].get("Name", "")),
				"color": _cie_to_hex(String(s["attrs"].get("Color", ""))),
				"image": image,
			})
		out[String(w["attrs"].get("Name", ""))] = slots
	return out


## Load "wheels/<media>.png" from the archive, downscale to 64 px, and
## return it base64-encoded (so it travels inside the profile JSON).
static func _load_media_b64(media: String, reader: Callable) -> String:
	for cand in ["wheels/%s.png" % media, "%s.png" % media, "wheels/%s" % media]:
		var bytes: PackedByteArray = reader.call(cand)
		if bytes.is_empty():
			continue
		var img := Image.new()
		if img.load_png_from_buffer(bytes) != OK:
			continue
		var big := maxi(img.get_width(), img.get_height())
		if big > 64:
			var sc := 64.0 / float(big)
			img.resize(maxi(1, int(img.get_width() * sc)), maxi(1, int(img.get_height() * sc)),
				Image.INTERPOLATE_BILINEAR)
		return Marshalls.raw_to_base64(img.save_png_to_buffer())
	return ""


static func _dmx_int(v: String) -> int:
	# GDTF DMXValue is "value/bytes" (e.g. "10/1", "32768/2"). Take value.
	return int(v.split("/")[0])


static func _gdtf_default(dc, funcs: Array) -> int:
	var chosen = null
	var initial := String(dc["attrs"].get("InitialFunction", ""))
	if initial != "":
		var want := initial.get_slice(".", initial.get_slice_count(".") - 1)
		for cf in funcs:
			if String(cf["attrs"].get("Name", "")) == want:
				chosen = cf
				break
	if chosen == null and not funcs.is_empty():
		chosen = funcs[0]
	if chosen == null:
		return 0
	var d := String(chosen["attrs"].get("Default", "0/1"))
	return _dmx_int(d)


## Pick the wheel slot a ChannelFunction refers to: explicit
## WheelSlotIndex, else a name match, else positional.
static func _match_wheel_slot(slots: Array, cf, label: String, fi: int) -> Dictionary:
	var wsi := int(cf["attrs"].get("WheelSlotIndex", "0"))
	if wsi >= 1 and wsi <= slots.size():
		return slots[wsi - 1]
	var low := label.to_lower()
	for s in slots:
		if String(s.get("name", "")).to_lower() == low:
			return s
	if fi >= 0 and fi < slots.size():
		return slots[fi]
	return {}


static func _gdtf_mode(mn, wheels: Dictionary, warnings: Array) -> Dictionary:
	var mode_name := String(mn["attrs"].get("Name", "Mode"))
	var dmx_channels := _kids(_kid(mn, "DMXChannels"), "DMXChannel")

	var slots := {}   # 1-based offset -> channel dict
	var footprint := 0

	for dc in dmx_channels:
		var offset_str := String(dc["attrs"].get("Offset", "")).strip_edges()
		if offset_str == "" or offset_str.to_lower() == "none":
			continue  # virtual channel — no DMX footprint
		var offs: Array = []
		for tok in offset_str.split(","):
			var n := int(tok.strip_edges())
			if n >= 1 and n <= _MAX_FOOTPRINT:
				offs.append(n)
		if offs.is_empty():
			continue

		var funcs: Array = []
		var attr := ""
		for lc in _kids(dc, "LogicalChannel"):
			if attr == "":
				attr = String(lc["attrs"].get("Attribute", ""))
			for cf in _kids(lc, "ChannelFunction"):
				funcs.append(cf)
		if attr == "" and not funcs.is_empty():
			attr = String(funcs[0]["attrs"].get("Attribute", ""))

		var role := _role_for(attr)
		var cname := attr if attr != "" else "Ch %d" % offs[0]
		var dval := _gdtf_default(dc, funcs)
		var is16 := dval > 255 or offs.size() >= 2
		var coarse_default := (dval >> 8) if dval > 255 else dval
		var fine_default := (dval & 0xFF) if dval > 255 else 0

		var ranges: Array = []
		if funcs.size() > 1 or role == "COLOR_WHEEL" or role == "GOBO":
			var lc_wheel := ""
			for lc in _kids(dc, "LogicalChannel"):
				if lc["attrs"].has("Wheel"):
					lc_wheel = String(lc["attrs"]["Wheel"])
			for fi in range(funcs.size()):
				var cf = funcs[fi]
				var lo := _dmx_int(String(cf["attrs"].get("DMXFrom", "0/1")))
				var hi := 255
				if fi + 1 < funcs.size():
					hi = maxi(lo, _dmx_int(String(funcs[fi + 1]["attrs"].get("DMXFrom", "255/1"))) - 1)
				var label := String(cf["attrs"].get("Name", "%d-%d" % [lo, hi]))
				var color := ""
				var image := ""
				var wname := String(cf["attrs"].get("Wheel", lc_wheel))
				if wname != "" and wheels.has(wname):
					var ws: Array = wheels[wname]
					var slot: Dictionary = _match_wheel_slot(ws, cf, label, fi)
					color = String(slot.get("color", ""))
					image = String(slot.get("image", ""))
				ranges.append({
					"lo": lo, "hi": hi, "label": label,
					"color": color, "image": image,
				})

		slots[offs[0]] = {
			"name": cname, "role": role,
			"default": clampi(coarse_default, 0, 255), "fine": false, "ranges": ranges,
		}
		footprint = maxi(footprint, offs[0])
		for k in range(1, offs.size()):
			slots[offs[k]] = {
				"name": "%s fine" % cname, "role": _fine_role(role),
				"default": clampi(fine_default if k == 1 else 0, 0, 255),
				"fine": true, "ranges": [],
			}
			footprint = maxi(footprint, offs[k])

	var channels: Array = []
	for off in range(1, footprint + 1):
		if slots.has(off):
			channels.append(slots[off])
		else:
			channels.append({"name": "Ch %d" % off, "role": "GENERIC", "default": 0, "fine": false, "ranges": []})
			warnings.append("%s: DMX channel %d not defined, left as GENERIC" % [mode_name, off])
	return {"name": mode_name, "channels": channels}


# =============================================== Open Fixture Library ==

static func _ofl_num(v) -> int:
	if v is String:
		var s: String = v
		if s.ends_with("%"):
			return clampi(int(round(float(s.substr(0, s.length() - 1)) * 2.55)), 0, 255)
		return clampi(int(s), 0, 255)
	return clampi(int(v), 0, 255)


static func _ofl_wheel_kind(slots: Array) -> String:
	for sl in slots:
		var t := String(sl.get("type", "")).to_lower()
		if t.begins_with("gobo"):
			return "GOBO"
		if t == "color":
			return "COLOR_WHEEL"
	return ""


static func _ofl_role(cname: String, cdef: Dictionary, wheels: Dictionary) -> String:
	var caps: Array = cdef.get("capabilities", [])
	if caps.is_empty() and cdef.has("capability"):
		caps = [cdef["capability"]]

	for cap in caps:
		var t := String(cap.get("type", ""))
		match t:
			"Intensity": return "DIMMER"
			"Pan", "PanContinuous": return "PAN"
			"Tilt", "TiltContinuous": return "TILT"
			"ShutterStrobe": return "STROBE"
			"ColorIntensity":
				return _role_for(String(cap.get("color", cname)))
			"WheelSlot", "WheelShake", "WheelSlotRotation", "WheelRotation":
				var wn := String(cap.get("wheel", cname))
				if wheels.has(wn):
					var k := _ofl_wheel_kind(wheels[wn].get("slots", []))
					if k != "":
						return k
	if wheels.has(cname):
		var k2 := _ofl_wheel_kind(wheels[cname].get("slots", []))
		if k2 != "":
			return k2
	return _role_for(cname)


static func _ofl_cap_label(cap: Dictionary, wheel_slots: Array) -> String:
	if cap.has("comment"):
		return String(cap["comment"])
	var t := String(cap.get("type", ""))
	if cap.has("slotNumber"):
		var n := int(cap["slotNumber"])
		if n >= 1 and n <= wheel_slots.size():
			var nm := String(wheel_slots[n - 1].get("name", ""))
			if nm != "":
				return nm
		return "Slot %d" % n
	if cap.has("effectName"):
		return String(cap["effectName"])
	if cap.has("color"):
		return String(cap["color"])
	if t == "NoFunction":
		return "—"
	return t if t != "" else "Range"


static func _ofl_cap_color(cap: Dictionary, wheel_slots: Array) -> String:
	if cap.has("colors") and cap["colors"] is Array and not cap["colors"].is_empty():
		return String(cap["colors"][0])
	if cap.has("color"):
		var c := Color.from_string(String(cap["color"]), Color.TRANSPARENT)
		if c != Color.TRANSPARENT:
			return String(cap["color"])
	if cap.has("slotNumber"):
		var n := int(cap["slotNumber"])
		if n >= 1 and n <= wheel_slots.size():
			var sc = wheel_slots[n - 1].get("colors", [])
			if sc is Array and not sc.is_empty():
				return String(sc[0])
	return ""


static func _ofl_channel(cname: String, cdef: Dictionary, wheels: Dictionary, warnings: Array) -> Dictionary:
	var caps: Array = cdef.get("capabilities", [])
	if caps.is_empty() and cdef.has("capability"):
		caps = [cdef["capability"]]

	var role := _ofl_role(cname, cdef, wheels)

	# find the wheel this channel drives, for slot names / colours
	var wheel_slots: Array = []
	if wheels.has(cname):
		wheel_slots = wheels[cname].get("slots", [])
	else:
		for cap in caps:
			if cap.has("wheel") and wheels.has(String(cap["wheel"])):
				wheel_slots = wheels[String(cap["wheel"])].get("slots", [])
				break

	var ranges: Array = []
	if caps.size() > 1:
		for cap in caps:
			var dr = cap.get("dmxRange", null)
			if not (dr is Array) or dr.size() != 2:
				continue
			ranges.append({
				"lo": int(dr[0]), "hi": int(dr[1]),
				"label": _ofl_cap_label(cap, wheel_slots),
				"color": _ofl_cap_color(cap, wheel_slots),
			})

	return {
		"name": cname, "role": role,
		"default": _ofl_num(cdef.get("defaultValue", 0)),
		"fine": false, "ranges": ranges,
	}


static func from_ofl(d: Dictionary) -> Dictionary:
	var warnings: Array = []
	var fixture_name := String(d.get("name", "Imported Fixture"))
	var available: Dictionary = d.get("availableChannels", {})
	var wheels: Dictionary = d.get("wheels", {})

	# fine-channel alias -> its coarse channel name
	var fine_of := {}
	for cn in available.keys():
		for fa in available[cn].get("fineChannelAliases", []):
			fine_of[String(fa)] = cn

	var modes: Array = []
	for m in d.get("modes", []):
		var mch: Array = []
		for entry in m.get("channels", []):
			if entry == null:
				mch.append({"name": "Unused", "role": "GENERIC", "default": 0, "fine": false, "ranges": []})
			elif entry is String:
				if fine_of.has(entry):
					var coarse: String = fine_of[entry]
					var cr := _ofl_role(coarse, available.get(coarse, {}), wheels)
					mch.append({"name": entry, "role": _fine_role(cr), "default": 0, "fine": true, "ranges": []})
				elif available.has(entry):
					mch.append(_ofl_channel(entry, available[entry], wheels, warnings))
				else:
					mch.append({"name": String(entry), "role": "GENERIC", "default": 0, "fine": false, "ranges": []})
					warnings.append("Channel '%s' is not in availableChannels" % entry)
			else:
				mch.append({"name": "Matrix", "role": "GENERIC", "default": 0, "fine": false, "ranges": []})
				warnings.append("Matrix / template channels are imported as GENERIC")
		modes.append({"name": String(m.get("name", "Mode")), "channels": mch})

	if modes.is_empty():
		return {"error": "The OFL fixture has no modes."}

	var profile := FixtureProfile.new(_safe_id_hint(fixture_name), fixture_name, [], modes)
	return {"profile": profile, "warnings": warnings}


# ============================================== tiny XML tree helper ==
# { "name": String, "attrs": Dictionary, "children": Array } nodes.

static func _parse_xml(bytes: PackedByteArray) -> Dictionary:
	var parser := XMLParser.new()
	if parser.open_buffer(bytes) != OK:
		return {"name": "", "attrs": {}, "children": []}
	var root := {"name": "", "attrs": {}, "children": []}
	var stack: Array = [root]
	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var node := {"name": parser.get_node_name(), "attrs": {}, "children": []}
				for i in range(parser.get_attribute_count()):
					node["attrs"][parser.get_attribute_name(i)] = parser.get_attribute_value(i)
				stack[stack.size() - 1]["children"].append(node)
				if not parser.is_empty():
					stack.append(node)
			XMLParser.NODE_ELEMENT_END:
				if stack.size() > 1:
					stack.pop_back()
	return root


static func _kids(node, name: String) -> Array:
	var out: Array = []
	if node == null:
		return out
	for c in node.get("children", []):
		if c["name"] == name:
			out.append(c)
	return out


static func _kid(node, name: String):
	var k := _kids(node, name)
	return k[0] if not k.is_empty() else null
