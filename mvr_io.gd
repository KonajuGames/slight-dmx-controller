class_name MvrIO
extends RefCounted
## My Virtual Rig (.mvr) import / export. An MVR is a ZIP holding
## `GeneralSceneDescription.xml` plus the `.gdtf` files it references.
##
## Import is best-effort: it reads each <Fixture>'s matrix, DMX address
## and GDTF, imports the GDTF as a FixtureProfile, and returns a plan the
## shell turns into patch entries. Trusses become viz geometry.
##
## Export writes a spec-shaped scene description + a generated GDTF per
## distinct profile. Coordinates: MVR is Z-up, millimetres; Godot is
## Y-up, metres — converted here.

const TMP := "user://_mvr_tmp"


# =============================================================== IMPORT ==

## -> { "fixtures": [ {profile, mode_name, universe, start, pos, rot, name} ],
##      "trusses": [ {pos, size} ], "warnings": [String] }  or  {"error": ..}
static func import_path(path: String) -> Dictionary:
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return {"error": "Can't open .mvr (not a ZIP?)."}
	var lut := {}
	for n in zip.get_files():
		lut[n.to_lower()] = n
	if not lut.has("generalscenedescription.xml"):
		zip.close()
		return {"error": "No GeneralSceneDescription.xml in the archive."}

	var xml := zip.read_file(lut["generalscenedescription.xml"])
	var root := FixtureImport._parse_xml(xml)
	var gsd = FixtureImport._kid(root, "GeneralSceneDescription")
	var scene = FixtureImport._kid(gsd, "Scene") if gsd else null
	if scene == null:
		zip.close()
		return {"error": "GeneralSceneDescription has no <Scene>."}

	var warnings: Array = []
	var fixtures: Array = []
	var trusses: Array = []
	var model_bytes := {}  # profile id -> {name: PackedByteArray}
	var gdtf_cache := {}   # spec filename -> {profile} or {error}

	DirAccess.make_dir_recursive_absolute(TMP)
	for fx in FixtureImport._find_all(scene, "Fixture"):
		var spec := String(_child_text(fx, "GDTFSpec")).strip_edges()
		var mode_name := String(_child_text(fx, "GDTFMode")).strip_edges()
		var fname := String(fx["attrs"].get("name", _child_text(fx, "Name")))
		var mat := _parse_matrix(_child_text(fx, "Matrix"))
		var addr := _fixture_address(fx)

		var prof: FixtureProfile = null
		if spec != "" and lut.has(("gdtf/" + spec).to_lower()) or lut.has(spec.to_lower()):
			var key := spec.to_lower()
			if lut.has(("gdtf/" + spec).to_lower()):
				key = ("gdtf/" + spec).to_lower()
			if not gdtf_cache.has(spec):
				var tmp_file := "%s/%s" % [TMP, spec]
				var w := FileAccess.open(tmp_file, FileAccess.WRITE)
				if w:
					w.store_buffer(zip.read_file(lut[key]))
					w.close()
				var r := FixtureImport.from_path(tmp_file)
				gdtf_cache[spec] = r
			var res: Dictionary = gdtf_cache[spec]
			if res.has("profile"):
				prof = res["profile"]
				if not res.get("model_bytes", {}).is_empty():
					model_bytes[prof.id] = res["model_bytes"]
				for wm in res.get("warnings", []):
					warnings.append("%s: %s" % [spec, wm])
			else:
				warnings.append("Couldn't read GDTF '%s' (%s)" % [spec, res.get("error", "?")])
		if prof == null:
			warnings.append("Fixture '%s' skipped — no usable GDTF." % fname)
			continue

		var mode_idx := 0
		for i in range(prof.mode_count()):
			if prof.mode_names()[i] == mode_name:
				mode_idx = i
		fixtures.append({
			"profile": prof, "mode": mode_idx, "name": fname,
			"universe": addr["universe"], "start": addr["channel"],
			"pos": mat["pos"], "rot": mat["rot"],
		})

	for tr in FixtureImport._find_all(scene, "Truss"):
		var m := _parse_matrix(_child_text(tr, "Matrix"))
		trusses.append({"pos": m["pos"], "size": 3.0})

	zip.close()
	return {"fixtures": fixtures, "trusses": trusses, "warnings": warnings, "model_bytes": model_bytes}


static func _child_text(node, name: String) -> String:
	var k = FixtureImport._kid(node, name)
	return String(k.get("text", "")) if k != null else ""


static func _fixture_address(fx) -> Dictionary:
	var addrs = FixtureImport._kid(fx, "Addresses")
	var raw := 1
	if addrs:
		var a = FixtureImport._kid(addrs, "Address")
		if a:
			raw = int(a.get("text", "1"))
	raw = maxi(raw, 1)
	return {"universe": (raw - 1) / 512, "channel": (raw - 1) % 512}


## MVR "{r0,r1,r2}{u..}{f..}{px,py,pz}" (mm, Z-up) -> Godot pos (m) + heading.
static func _parse_matrix(s: String) -> Dictionary:
	var nums: Array = []
	var cur := ""
	for ch in s:
		if ch in "-0123456789.eE+":
			cur += ch
		elif cur != "":
			nums.append(float(cur))
			cur = ""
	if cur != "":
		nums.append(float(cur))
	if nums.size() < 12:
		return {"pos": Vector3.ZERO, "rot": Vector3.ZERO}
	# columns: right(0..2) up(3..5) forward(6..8) pos(9..11)
	var pos_z_up := Vector3(nums[9], nums[10], nums[11]) / 1000.0
	var fwd := Vector3(nums[6], nums[7], nums[8])
	# Z-up -> Y-up
	var pos := Vector3(pos_z_up.x, pos_z_up.z, -pos_z_up.y)
	var heading := rad_to_deg(atan2(-fwd.x, fwd.y)) if fwd.length() > 0.01 else 0.0
	return {"pos": pos, "rot": Vector3(0, heading, 0)}


# =============================================================== EXPORT ==

static func export_path(path: String, panels: Array, viz: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(TMP + "/out")
	var zw := ZIPPacker.new()
	if zw.open(path) != OK:
		return "Export failed: can't write %s" % path

	# one GDTF per distinct profile
	var seen := {}
	var fixture_xml := ""
	var fid := 1
	for u in range(panels.size()):
		for f in panels[u].patched_fixtures:
			var prof: FixtureProfile = f["profile"]
			var spec := "%s.gdtf" % prof.id
			if not seen.has(prof.id):
				seen[prof.id] = true
				zw.start_file("gdtf/" + spec)
				zw.write_file(_gen_gdtf(prof))
				zw.close_file()
			var mode: int = int(f.get("mode", 0))
			var mode_name: String = prof.mode_names()[clampi(mode, 0, prof.mode_count() - 1)]
			var addr := u * 512 + int(f["start"]) + 1
			fixture_xml += _fixture_node(String(f["name"]), spec, mode_name, addr,
				f.get("pos", Vector3.ZERO), f.get("rot", Vector3.ZERO), fid)
			fid += 1

	var gsd := """<?xml version="1.0" encoding="UTF-8"?>
<GeneralSceneDescription verMajor="1" verMinor="6" provider="sLight">
 <Scene>
  <Layers>
   <Layer name="Rig" uuid="%s">
    <ChildList>
%s    </ChildList>
   </Layer>
  </Layers>
 </Scene>
</GeneralSceneDescription>
""" % [_uuid(), fixture_xml]
	zw.start_file("GeneralSceneDescription.xml")
	zw.write_file(gsd.to_utf8_buffer())
	zw.close_file()
	zw.close()
	return "Exported %d fixtures to %s" % [fid - 1, path.get_file()]


static func _fixture_node(name: String, spec: String, mode_name: String, addr: int, pos: Vector3, rot: Vector3, fid: int) -> String:
	# Godot Y-up (m) -> MVR Z-up (mm)
	var p := Vector3(pos.x, -pos.z, pos.y) * 1000.0
	var h := deg_to_rad(rot.y)
	var right := Vector3(cos(h), sin(h), 0)
	var fwd := Vector3(-sin(h), cos(h), 0)
	var mat := "{%s}{0,0,1}{%s}{%.3f,%.3f,%.3f}" % [
		_v(right), _v(fwd), p.x, p.y, p.z]
	return """     <Fixture name="%s" uuid="%s">
      <Matrix>%s</Matrix>
      <GDTFSpec>%s</GDTFSpec>
      <GDTFMode>%s</GDTFMode>
      <Addresses><Address break="1">%d</Address></Addresses>
      <FixtureID>%d</FixtureID>
      <CastShadow>false</CastShadow>
     </Fixture>
""" % [_esc(name), _uuid(), mat, _esc(spec), _esc(mode_name), addr, fid]


static func _v(v: Vector3) -> String:
	return "%.4f,%.4f,%.4f" % [v.x, v.y, v.z]


static func _esc(s: String) -> String:
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


static func _uuid() -> String:
	var h := ""
	for i in range(32):
		h += "%x" % (randi() % 16)
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]


const _ROLE_ATTR := {
	"DIMMER": "Dimmer", "RED": "ColorAdd_R", "GREEN": "ColorAdd_G", "BLUE": "ColorAdd_B",
	"WHITE": "ColorAdd_W", "AMBER": "ColorAdd_A", "UV": "ColorAdd_UV",
	"PAN": "Pan", "PAN_FINE": "Pan", "TILT": "Tilt", "TILT_FINE": "Tilt",
	"STROBE": "Shutter1", "ZOOM": "Zoom", "GOBO": "Gobo1", "GOBO_ROT": "Gobo1Pos",
	"COLOR_WHEEL": "Color1", "GENERIC": "NoFeature",
}


## A .gdtf is itself a ZIP holding description.xml — build one on disk and
## hand back its bytes.
static func _gen_gdtf(prof: FixtureProfile) -> PackedByteArray:
	DirAccess.make_dir_recursive_absolute(TMP)
	var tmp := "%s/_gen_%s.gdtf" % [TMP, prof.id]
	var zp := ZIPPacker.new()
	if zp.open(tmp) != OK:
		return PackedByteArray()
	zp.start_file("description.xml")
	zp.write_file(_gen_gdtf_xml(prof))
	zp.close_file()
	zp.close()
	return FileAccess.get_file_as_bytes(tmp)


static func _gen_gdtf_xml(prof: FixtureProfile) -> PackedByteArray:
	var used_attrs := {}
	var modes_xml := ""
	for mi in range(prof.mode_count()):
		var chans: Array = prof.channels_for_mode(mi)
		var ch_xml := ""
		for ci in range(chans.size()):
			var ch: Dictionary = chans[ci]
			if bool(ch.get("fine", false)):
				continue  # folded into the coarse channel's Offset
			var role := String(ch["role"])
			var attr: String = _ROLE_ATTR.get(role, "NoFeature")
			used_attrs[attr] = true
			var offset := "%d" % (ci + 1)
			if ci + 1 < chans.size() and bool(chans[ci + 1].get("fine", false)):
				offset = "%d,%d" % [ci + 1, ci + 2]
			var dflt := int(ch.get("default", 0))
			ch_xml += """      <DMXChannel DMXBreak="1" Offset="%s" Geometry="Body" Highlight="None">
       <LogicalChannel Attribute="%s">
        <ChannelFunction Attribute="%s" Name="%s 1" DMXFrom="0/1" Default="%d/1"/>
       </LogicalChannel>
      </DMXChannel>
""" % [offset, attr, attr, attr, dflt]
		modes_xml += """    <DMXMode Name="%s" Geometry="Body">
     <DMXChannels>
%s     </DMXChannels>
    </DMXMode>
""" % [_esc(String(prof.mode_names()[mi])), ch_xml]

	var attr_xml := ""
	for a in used_attrs:
		attr_xml += '   <Attribute Name="%s" Pretty="%s"/>\n' % [a, a]

	var xml := """<?xml version="1.0" encoding="UTF-8"?>
<GDTF DataVersion="1.1">
 <FixtureType Name="%s" ShortName="%s" LongName="%s" Manufacturer="sLight" FixtureTypeID="%s">
  <AttributeDefinitions>
   <ActivationGroups/>
   <FeatureGroups/>
   <Attributes>
%s   </Attributes>
  </AttributeDefinitions>
  <Wheels/>
  <PhysicalDescriptions/>
  <Models/>
  <Geometries>
   <Geometry Name="Body" Model="" Position="{1,0,0,0}{0,1,0,0}{0,0,1,0}{0,0,0,1}"/>
  </Geometries>
  <DMXModes>
%s  </DMXModes>
  <Revisions/>
 </FixtureType>
</GDTF>
""" % [_esc(prof.profile_name), _esc(prof.id.substr(0, 10)), _esc(prof.profile_name),
	_uuid(), attr_xml, modes_xml]
	return xml.to_utf8_buffer()
