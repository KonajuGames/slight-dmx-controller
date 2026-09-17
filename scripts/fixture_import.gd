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
	if "gobopos" in s or "gobo1pos" in s or ("gobo" in s and ("rot" in s or "index" in s or "spin" in s)):
		return "GOBO_ROT"
	if "gobo" in s:
		return "GOBO"
	if "zoom" in s:
		return "ZOOM"
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

	# GeometryReference nodes turn one "module" of channels into many
	# cells / heads — expand them so the flat channel list has every head.
	var refs := _gdtf_refs(ft)

	var modes: Array = []
	for mn in mode_nodes:
		modes.append(_gdtf_mode(mn, wheels, warnings, refs))

	var id := _safe_id_hint(fixture_name)
	var phys := _gdtf_physical(ft, modes)
	var geo := _gdtf_geometry(ft, media_reader, warnings)
	var heads := _gdtf_head_offsets(ft, mode_nodes, geo["geometry"], refs)
	if not heads.is_empty():
		phys["heads"] = heads

	var profile := FixtureProfile.new(id, fixture_name, [], modes, phys)
	profile.geometry = geo["geometry"]
	return {"profile": profile, "warnings": warnings, "model_bytes": geo["model_bytes"]}


# ------------------------------------------------------------ GDTF HEADS --

## GDTF stores a 4x4 as column-major "{c0}{c1}{c2}{c3}" in a right-handed
## Z-up frame. Godot is right-handed Y-up; the change of basis C maps a
## GDTF vector (x,y,z) -> (x, z, -y). This returns C * M * C_inverse for
## the rotation and C * translation for the origin, i.e. the same rigid
## transform expressed in Godot's axes.
static func _gdtf_transform(m: Array) -> Transform3D:
	if not (m is Array) or m.size() != 16:
		return Transform3D.IDENTITY
	var cx := Vector3(m[0], m[1], m[2])     # GDTF local X axis
	var cy := Vector3(m[4], m[5], m[6])     # GDTF local Y axis
	var cz := Vector3(m[8], m[9], m[10])    # GDTF local Z axis
	var conv := func(v: Vector3) -> Vector3: return Vector3(v.x, v.z, -v.y)
	# Godot basis columns: X <- C.cx, Y <- C.cz, Z <- -C.cy  (= C M C^-1)
	var b := Basis(conv.call(cx), conv.call(cz), -conv.call(cy))
	if not b.determinant() > 0.0001:
		b = Basis.IDENTITY
	else:
		b = b.orthonormalized()
	return Transform3D(b, conv.call(Vector3(m[12], m[13], m[14])))


## Cumulative Godot-space Transform3D of every named geometry in the tree.
static func _geo_xform_map(node, parent := Transform3D.IDENTITY, out := {}) -> Dictionary:
	if node == null:
		return out
	var world: Transform3D = parent * _gdtf_transform(node.get("mat", []))
	if String(node.get("name", "")) != "":
		out[String(node["name"])] = world
	for c in node.get("children", []):
		_geo_xform_map(c, world, out)
	return out


static func _gdtf_refs(ft) -> Array:
	var out: Array = []
	for gr in _find_all(ft, "GeometryReference"):
		var brk = _kid(gr, "Break")
		out.append({
			"name": String(gr["attrs"].get("Name", "")),
			"geometry": String(gr["attrs"].get("Geometry", "")),
			"dmx_offset": int(brk["attrs"].get("DMXOffset", "0")) if brk else 0,
			"xform": _gdtf_transform(_gdtf_matrix(String(gr["attrs"].get("Position", "")))),
		})
	return out


## Euler angles (degrees, Godot XYZ) of `b` relative to `ref` — the extra
## rotation that turns head 0's orientation into this head's.
static func _rel_euler(b: Basis, ref: Basis) -> Array:
	var e := (ref.inverse() * b).orthonormalized().get_euler()
	return [rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z)]


## Per-head placement relative to the fixture origin:
## [ [x, y, z, rot_x, rot_y, rot_z], ... ] — metres and degrees, rotation
## relative to the first head. Built from the geometries the RGB channels
## drive, using whichever mode names the most of them.
static func _gdtf_head_offsets(ft, mode_nodes: Array, geometry: Dictionary, refs: Array) -> Array:
	if geometry.is_empty() or not geometry.has("tree"):
		return _ref_head_offsets(refs)
	var xmap := _geo_xform_map(geometry["tree"])
	var root_name := String(geometry["tree"].get("name", ""))
	var origin: Transform3D = xmap.get(root_name, Transform3D.IDENTITY)

	var best: Array = []
	for mn in mode_nodes:
		var geos: Array = []
		for dc in _kids(_kid(mn, "DMXChannels"), "DMXChannel"):
			for lc in _kids(dc, "LogicalChannel"):
				if String(lc["attrs"].get("Attribute", "")) in ["ColorAdd_R", "ColorRGB_Red"]:
					var g := String(dc["attrs"].get("Geometry", ""))
					if g != "" and not (g in geos):
						geos.append(g)
		if geos.size() > best.size():
			best = geos

	if best.size() < 2:
		return _ref_head_offsets(refs)

	var inv := origin.affine_inverse()
	var head0: Transform3D = inv * xmap.get(best[0], origin)
	var out: Array = []
	for g in best:
		var t: Transform3D = inv * xmap.get(g, origin)
		var rot := _rel_euler(t.basis, head0.basis)
		out.append([t.origin.x, t.origin.y, t.origin.z, rot[0], rot[1], rot[2]])
	return out


## Per-head placement from the <GeometryReference> matrices (a pixel bar /
## spider defined by references rather than distinct RGB geometries).
static func _ref_head_offsets(refs: Array) -> Array:
	if refs.size() < 2:
		return []
	var xf: Array = []
	for r in refs:
		xf.append(r.get("xform", Transform3D.IDENTITY))
	# re-centre translation on the group midpoint; keep rotations relative
	# to the first reference
	var mid := Vector3.ZERO
	for t in xf:
		mid += (t as Transform3D).origin
	mid /= xf.size()
	var ref_basis: Basis = (xf[0] as Transform3D).basis
	var out: Array = []
	for t in xf:
		var tt: Transform3D = t
		var p := tt.origin - mid
		var rot := _rel_euler(tt.basis, ref_basis)
		out.append([p.x, p.y, p.z, rot[0], rot[1], rot[2]])
	return out


# --------------------------------------------------------- GDTF GEOMETRY --

## Parse <Geometries> into a node tree plus the glTF model files, and note
## which geometry the Pan / Tilt channels drive.
static func _gdtf_geometry(ft, media_reader: Callable, warnings: Array) -> Dictionary:
	var empty := {"geometry": {}, "model_bytes": {}}
	var geos = _kid(ft, "Geometries")
	if geos == null:
		return empty

	var roots: Array = []
	for c in geos.get("children", []):
		if c["name"] in ["Geometry", "Axis"]:
			roots.append(_geo_node(c))
	if roots.is_empty():
		return empty

	var pan_geo := ""
	var tilt_geo := ""
	for dc in _find_all(ft, "DMXChannel"):
		var g := String(dc["attrs"].get("Geometry", ""))
		if g == "":
			continue
		for lc in _kids(dc, "LogicalChannel"):
			match String(lc["attrs"].get("Attribute", "")):
				"Pan": pan_geo = g
				"Tilt": tilt_geo = g

	var model_bytes := {}
	var models_el = _kid(ft, "Models")
	if models_el != null and media_reader.is_valid():
		for m in _kids(models_el, "Model"):
			var mname := String(m["attrs"].get("Name", ""))
			var mfile := String(m["attrs"].get("File", mname))
			for cand in [
				"models/gltf/%s.glb" % mfile, "models/gltf/%s.gltf" % mfile,
				"models/%s.glb" % mfile, "%s.glb" % mfile,
			]:
				var b: PackedByteArray = media_reader.call(cand)
				if not b.is_empty():
					model_bytes[mname] = b
					break

	return {
		"geometry": {
			"tree": roots[0],
			"pan_geo": pan_geo,
			"tilt_geo": tilt_geo,
			"models": {},       # filled in by the shell after saving files
			"models_dir": "",
		},
		"model_bytes": model_bytes,
	}


static func _geo_node(el) -> Dictionary:
	var kind := "geometry"
	if el["name"] == "Axis":
		kind = "axis"
	elif el["name"] in ["Beam", "FilterBeam"]:
		kind = "beam"
	var node := {
		"name": String(el["attrs"].get("Name", "")),
		"kind": kind,
		"mat": _gdtf_matrix(String(el["attrs"].get("Position", ""))),
		"model": String(el["attrs"].get("Model", "")),
		"beam_deg": clampf(float(el["attrs"].get("BeamAngle", "0")), 0.0, 120.0) if kind == "beam" else 0.0,
		"children": [],
	}
	for c in el.get("children", []):
		if c["name"] in ["Geometry", "Axis", "Beam", "FilterBeam", "Support", "Structure"]:
			node["children"].append(_geo_node(c))
	return node


## GDTF "{a,b,c,d}{...}{...}{...}" -> 16 floats (column-major).
static func _gdtf_matrix(s: String) -> Array:
	var out: Array = []
	var num := ""
	for ch in s:
		if ch in "-0123456789.eE+":
			num += ch
		elif num != "":
			out.append(float(num))
			num = ""
	if num != "":
		out.append(float(num))
	if out.size() != 16:
		return [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0]
	return out


static func _gdtf_physical(ft, modes: Array) -> Dictionary:
	var phys := {
		"category": _guess_category(modes),
		"beam_deg": 14.0, "pan_range": 540.0, "tilt_range": 270.0,
	}
	var beam = _find_first(ft, "Beam")
	if beam and beam["attrs"].has("BeamAngle"):
		phys["beam_deg"] = clampf(float(beam["attrs"]["BeamAngle"]), 1.0, 120.0)

	var pan_found := false
	var tilt_found := false
	for cf in _find_all(ft, "ChannelFunction"):
		if not (cf["attrs"].has("PhysicalFrom") and cf["attrs"].has("PhysicalTo")):
			continue
		var span := absf(float(cf["attrs"]["PhysicalTo"]) - float(cf["attrs"]["PhysicalFrom"]))
		match String(cf["attrs"].get("Attribute", "")):
			"Pan":
				phys["pan_range"] = span if not pan_found else maxf(phys["pan_range"], span)
				pan_found = true
			"Tilt":
				phys["tilt_range"] = span if not tilt_found else maxf(phys["tilt_range"], span)
				tilt_found = true
	return phys


static func _guess_category(modes: Array) -> String:
	var roles := {}
	for m in modes:
		for ch in m.get("channels", []):
			roles[String(ch["role"])] = true
	if roles.has("PAN") and roles.has("TILT"):
		return "moving_head"
	if roles.has("STROBE") and not roles.has("RED") and not roles.has("DIMMER"):
		return "blinder"
	if roles.has("RED") and roles.has("GREEN") and roles.has("BLUE"):
		return "par"
	if roles.has("DIMMER"):
		return "par"
	return "generic"


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


## The channel's home DMX value, or -1 if the GDTF states none (the caller
## then falls back to a role-appropriate default).
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
	if chosen == null or not chosen["attrs"].has("Default"):
		return -1
	return _dmx_int(String(chosen["attrs"]["Default"]))


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


static func _gdtf_mode(mn, wheels: Dictionary, warnings: Array, refs: Array = []) -> Dictionary:
	var mode_name := String(mn["attrs"].get("Name", "Mode"))
	var dmx_channels := _kids(_kid(mn, "DMXChannels"), "DMXChannel")

	# Geometries instanced by a <GeometryReference> hold "module" channels
	# (one pixel / head) that get replicated at each reference's DMX offset.
	var module_names := {}
	for r in refs:
		var gm := String(r.get("geometry", ""))
		if gm != "":
			module_names[gm] = true

	var slots := {}          # 1-based offset -> channel dict
	var module_slots := {}   # subset of slots that live in a referenced module
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

		var is_module: bool = module_names.has(String(dc["attrs"].get("Geometry", "")))

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
		var dval := _gdtf_default(dc, funcs)          # -1 when the GDTF gives none
		var has_default := dval >= 0
		var is16 := dval > 255 or offs.size() >= 2
		var coarse_default := (dval >> 8) if dval > 255 else maxi(dval, 0)
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

		# Leave "default" unset when the GDTF states none, so the profile
		# can fall back per role (pan / tilt park in the middle).
		var coarse_slot := {
			"name": cname, "role": role, "fine": false, "ranges": ranges,
		}
		if has_default:
			coarse_slot["default"] = clampi(coarse_default, 0, 255)
		slots[offs[0]] = coarse_slot
		if is_module:
			module_slots[offs[0]] = slots[offs[0]]
		footprint = maxi(footprint, offs[0])
		for k in range(1, offs.size()):
			var fine_slot := {
				"name": "%s fine" % cname, "role": _fine_role(role),
				"fine": true, "ranges": [],
			}
			if has_default:
				fine_slot["default"] = clampi(fine_default if k == 1 else 0, 0, 255)
			slots[offs[k]] = fine_slot
			if is_module:
				module_slots[offs[k]] = slots[offs[k]]
			footprint = maxi(footprint, offs[k])

	# replicate the module channels at every GeometryReference's DMX offset
	if module_slots.size() > 0 and refs.size() >= 2:
		var base_off := 1 << 30
		for r in refs:
			base_off = mini(base_off, int(r.get("dmx_offset", 0)))
		for r in refs:
			var shift := int(r.get("dmx_offset", 0)) - base_off
			if shift <= 0:
				continue
			for boff in module_slots:
				var tgt: int = int(boff) + shift
				if tgt >= 1 and tgt <= _MAX_FOOTPRINT and not slots.has(tgt):
					slots[tgt] = (module_slots[boff] as Dictionary).duplicate(true)
					footprint = maxi(footprint, tgt)

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
			"Zoom": return "ZOOM"
			"ColorIntensity":
				return _role_for(String(cap.get("color", cname)))
			"WheelSlotRotation", "WheelRotation":
				var wr := String(cap.get("wheel", cname))
				if wheels.has(wr) and _ofl_wheel_kind(wheels[wr].get("slots", [])) == "GOBO":
					return "GOBO_ROT"
			"WheelSlot", "WheelShake":
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

	var ch := {
		"name": cname, "role": role, "fine": false, "ranges": ranges,
	}
	# No explicit default -> let the profile decide per role (pan / tilt
	# park in the middle rather than at 0).
	if cdef.has("defaultValue"):
		ch["default"] = _ofl_num(cdef["defaultValue"])
	return ch


## Ordered pixels of an OFL `matrix` object: [{key, pos:Vector3}] with pos in
## grid units (X right, Y up, Z toward viewer), centred on the fixture origin.
static func _ofl_matrix_pixels(matrix: Dictionary) -> Array:
	var raw: Array = []   # {key, x, y, z} in 1-based grid indices
	if matrix.get("pixelKeys", null) is Array:
		var layers: Array = matrix["pixelKeys"]
		for z in range(layers.size()):
			var rows = layers[z]
			if not (rows is Array):
				continue
			for y in range(rows.size()):
				var cols = rows[y]
				if not (cols is Array):
					continue
				for x in range(cols.size()):
					var k = cols[x]
					if k != null:
						raw.append({"key": String(k), "x": x + 1, "y": rows.size() - y, "z": z + 1})
	elif matrix.get("pixelCount", null) is Array and matrix["pixelCount"].size() == 3:
		var pc: Array = matrix["pixelCount"]
		for z in range(int(pc[2])):
			for y in range(int(pc[1])):
				for x in range(int(pc[0])):
					raw.append({
						"key": "(%d, %d, %d)" % [x + 1, y + 1, z + 1],
						"x": x + 1, "y": y + 1, "z": z + 1,
					})
	if raw.is_empty():
		return []

	var cx := 0.0
	var cy := 0.0
	var cz := 0.0
	for r in raw:
		cx += r["x"]; cy += r["y"]; cz += r["z"]
	cx /= raw.size(); cy /= raw.size(); cz /= raw.size()
	var out: Array = []
	for r in raw:
		out.append({
			"key": r["key"],
			"pos": Vector3(r["x"] - cx, r["y"] - cy, r["z"] - cz),
		})
	return out


## Resolve a mode's `{insert:"matrixChannels", ...}` entry to a flat list of
## channel dicts, and record the per-head offset for each emitted pixel.
static func _ofl_expand_matrix(
		entry: Dictionary, pixels: Array, templates: Dictionary,
		wheels: Dictionary, head_pos: Array, warnings: Array) -> Array:
	var order := String(entry.get("channelOrder", "perPixel"))
	var tmpl_names: Array = entry.get("templateChannels", [])

	# which pixels, in which order
	var keys: Array = []
	var rf = entry.get("repeatFor", "eachPixelXYZ")
	if rf is Array:
		for k in rf:
			keys.append(String(k))
	else:
		for p in pixels:
			keys.append(String(p["key"]))

	var pos_of := {}
	for p in pixels:
		pos_of[String(p["key"])] = p["pos"]

	var out: Array = []
	var emit := func(pkey: String, tname: String) -> void:
		var cname := tname.replace("$pixelKey", pkey)
		var tdef = templates.get(tname, templates.get(cname, null))
		if tdef is Dictionary:
			out.append(_ofl_channel(cname, tdef, wheels, warnings))
		else:
			out.append({"name": cname, "role": "GENERIC", "default": 0, "fine": false, "ranges": []})

	if order == "perChannel":
		warnings.append("Matrix channelOrder 'perChannel' — per-head colour pickers may not align")
		for tname in tmpl_names:
			for pkey in keys:
				emit.call(pkey, String(tname))
	else:
		for pkey in keys:
			for tname in tmpl_names:
				emit.call(pkey, String(tname))
			var pv = pos_of.get(pkey, Vector3.ZERO)
			head_pos.append([pv.x, pv.y, pv.z])
	return out


static func from_ofl(d: Dictionary) -> Dictionary:
	var warnings: Array = []
	var fixture_name := String(d.get("name", "Imported Fixture"))
	var available: Dictionary = d.get("availableChannels", {})
	var wheels: Dictionary = d.get("wheels", {})
	var templates: Dictionary = d.get("templateChannels", {})
	var pixels := _ofl_matrix_pixels(d.get("matrix", {}))
	var head_pos: Array = []

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
			elif entry is Dictionary and String(entry.get("insert", "")) == "matrixChannels":
				var hp: Array = []
				mch.append_array(_ofl_expand_matrix(entry, pixels, templates, wheels, hp, warnings))
				if head_pos.is_empty():
					head_pos = hp
			else:
				mch.append({"name": "Matrix", "role": "GENERIC", "default": 0, "fine": false, "ranges": []})
				warnings.append("Matrix / template channels are imported as GENERIC")
		modes.append({"name": String(m.get("name", "Mode")), "channels": mch})

	if modes.is_empty():
		return {"error": "The OFL fixture has no modes."}

	var phys := _ofl_physical(d, modes)
	if head_pos.size() >= 2:
		# grid indices -> metres. Prefer the fixture's real width if given.
		var pitch := 0.15
		var dims = d.get("physical", {}).get("dimensions", null)
		if dims is Array and dims.size() >= 1 and pixels.size() >= 2:
			var span := 0.0
			for p in pixels:
				span = maxf(span, absf(p["pos"].x))
			if span > 0.0:
				pitch = (float(dims[0]) / 1000.0) / (span * 2.0 + 1.0)
		for h in head_pos:
			h[0] *= pitch; h[1] *= pitch; h[2] *= pitch
		phys["heads"] = head_pos

	var profile := FixtureProfile.new(
		_safe_id_hint(fixture_name), fixture_name, [], modes, phys)
	return {"profile": profile, "warnings": warnings}


static func _ofl_physical(d: Dictionary, modes: Array) -> Dictionary:
	var phys := {
		"category": "", "beam_deg": 14.0, "pan_range": 540.0, "tilt_range": 270.0,
	}
	var op: Dictionary = d.get("physical", {})
	var dm = op.get("lens", {}).get("degreesMinMax", null)
	if dm is Array and dm.size() == 2:
		phys["beam_deg"] = clampf(float(dm[0]), 1.0, 120.0)
	var focus: Dictionary = op.get("focus", {})
	var pm = focus.get("panMax", null)
	if pm is float or pm is int:
		phys["pan_range"] = clampf(float(pm), 0.0, 1080.0)
	var tm = focus.get("tiltMax", null)
	if tm is float or tm is int:
		phys["tilt_range"] = clampf(float(tm), 0.0, 540.0)

	for c in d.get("categories", []):
		var s := String(c).to_lower()
		if "moving head" in s or "scanner" in s:
			phys["category"] = "moving_head"
		elif "blinder" in s or "strobe" in s:
			phys["category"] = "blinder"
		elif "pixel bar" in s or "matrix" in s:
			phys["category"] = "strip"
	if phys["category"] == "":
		phys["category"] = _guess_category(modes)
	return phys


# ============================================== tiny XML tree helper ==
# { "name": String, "attrs": Dictionary, "children": Array } nodes.

static func _parse_xml(bytes: PackedByteArray) -> Dictionary:
	var parser := XMLParser.new()
	if parser.open_buffer(bytes) != OK:
		return {"name": "", "attrs": {}, "children": [], "text": ""}
	var root := {"name": "", "attrs": {}, "children": [], "text": ""}
	var stack: Array = [root]
	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var node := {"name": parser.get_node_name(), "attrs": {}, "children": [], "text": ""}
				for i in range(parser.get_attribute_count()):
					node["attrs"][parser.get_attribute_name(i)] = parser.get_attribute_value(i)
				stack[stack.size() - 1]["children"].append(node)
				if not parser.is_empty():
					stack.append(node)
			XMLParser.NODE_ELEMENT_END:
				if stack.size() > 1:
					stack.pop_back()
			XMLParser.NODE_TEXT:
				var t := parser.get_node_data().strip_edges()
				if t != "":
					stack[stack.size() - 1]["text"] += t
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


static func _find_all(node, name: String, out: Array = []) -> Array:
	if node == null:
		return out
	for c in node.get("children", []):
		if c["name"] == name:
			out.append(c)
		_find_all(c, name, out)
	return out


static func _find_first(node, name: String):
	var all := _find_all(node, name)
	return all[0] if not all.is_empty() else null
