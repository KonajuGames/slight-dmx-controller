class_name FixtureView
extends Node3D
## One patched fixture in the 3D visualizer. Builds either the GDTF
## geometry (glTF models + pan/tilt axes) when the profile has it, or a
## schematic body by category. Every frame it reads its slice of the
## universe's composited `output` (via DmxRender) and drives one light +
## beam cone *per head* — so a multi-head bar / spider is many sources —
## plus shared pan/tilt/zoom/strobe/gobo.

var universe := 0
var start := 0          # 0-based
var mode := 0
var fixture_id := 0
var display_name := ""
var profile: FixtureProfile

var selected := false: set = _set_selected
var shadows := false: set = _set_shadows

var _category := "par"
var _base_energy := 12.0
var _beam_len := 13.0

var _yoke: Node3D            # pan axis
var _head: Node3D            # tilt axis
var _head_base := 0.0        # tilt-axis home rotation (rad, X)
var _ring: MeshInstance3D
var _geo_nodes := {}
var _geo_beam_node: Node3D
var _geo_beam_deg := 0.0

## Per head: { node, light, beam (or null), emissive (or null) }
var _heads: Array = []
var _light: SpotLight3D      # alias for _heads[0].light (compat / gobo target)

var _cur_pan := 0.0
var _cur_tilt := 0.0
var _strobe_phase := 0.0
var _gobo_roll := 0.0
var _cur_gobo := "unset"
var _gobo_cache := {}

static var _beam_gradient: Texture2D


func setup(p_universe: int, p_start: int, p_mode: int, p_profile: FixtureProfile, p_id: int, p_name: String) -> void:
	universe = p_universe
	start = p_start
	mode = p_mode
	profile = p_profile
	fixture_id = p_id
	display_name = p_name
	_category = _resolve_category()
	if not _build_from_geometry():
		_build_schematic()
	if not _heads.is_empty():
		_light = _heads[0]["light"]
	_add_selection_and_picker()
	set_process(true)


func _resolve_category() -> String:
	var c := String(profile.physical.get("category", ""))
	if c != "":
		return c
	var roles := {}
	for ch in profile.channels_for_mode(mode):
		roles[String(ch["role"])] = true
	if roles.has("PAN") and roles.has("TILT"):
		return "moving_head"
	if roles.has("STROBE") and not roles.has("RED"):
		return "blinder"
	if roles.has("RED") or roles.has("DIMMER"):
		return "wash" if float(profile.physical.get("beam_deg", 14.0)) > 28.0 else "par"
	return "generic"


func _head_offsets() -> Array:
	var groups := profile.head_groups(mode)
	if groups.is_empty():
		return [Vector3.ZERO]
	var out: Array = []
	for g in groups:
		out.append(g["offset"])
	return out


# ------------------------------------------------------- GDTF GEOMETRY --

func _build_from_geometry() -> bool:
	var geo: Dictionary = profile.geometry
	if geo.is_empty() or not geo.has("tree"):
		return false
	var mm: Dictionary = geo.get("models", {})
	if mm.is_empty():
		return false

	var mdir := "user://fixture_models/%s" % String(geo.get("models_dir", ""))
	_spawn_geo(geo["tree"], self, mdir, mm)

	if _geo_beam_node == null:
		for c in get_children():
			c.queue_free()
		_geo_nodes.clear()
		return false

	_yoke = _geo_nodes.get(String(geo.get("pan_geo", "")))
	_head = _geo_nodes.get(String(geo.get("tilt_geo", "")))
	if _head:
		_head_base = deg_to_rad(-90.0)  # tilt home: beam straight down
		_head.rotation.x = _head_base
	if _geo_beam_deg > 0.0:
		profile.physical["beam_deg"] = _geo_beam_deg

	_build_heads(_geo_beam_node, Vector3.ZERO, true, false)
	return true


func _spawn_geo(node: Dictionary, parent: Node3D, mdir: String, mmap: Dictionary) -> void:
	var n := Node3D.new()
	n.name = String(node.get("name", "geo")) if node.get("name", "") != "" else "geo"
	var m: Array = node.get("mat", [])
	if m.size() == 16:
		n.position = Vector3(float(m[12]), float(m[14]), -float(m[13]))  # Z-up -> Y-up
	parent.add_child(n)
	if node.get("name", "") != "":
		_geo_nodes[String(node["name"])] = n

	var mkey := String(node.get("model", ""))
	if mkey != "" and mmap.has(mkey):
		var scene := _load_glb("%s/%s" % [mdir, mmap[mkey]])
		if scene:
			n.add_child(scene)

	if String(node.get("kind", "")) == "beam":
		_geo_beam_node = n
		_geo_beam_deg = float(node.get("beam_deg", 0.0))

	for c in node.get("children", []):
		_spawn_geo(c, n, mdir, mmap)


static func _load_glb(path: String) -> Node3D:
	if not FileAccess.file_exists(path):
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		return null
	var scene = doc.generate_scene(state)
	return scene if scene is Node3D else null


# ------------------------------------------------------- SCHEMATIC BODY --

func _metal(shade := 0.14) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(shade, shade, shade)
	m.metallic = 0.55
	m.roughness = 0.5
	return m


func _box(size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	return mi


func _cyl(rt: float, rb: float, h: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = rt
	c.bottom_radius = rb
	c.height = h
	c.radial_segments = 20
	mi.mesh = c
	mi.material_override = mat
	return mi


func _build_schematic() -> void:
	var metal := _metal()

	match _category:
		"moving_head", "scanner":
			add_child(_cyl(0.13, 0.15, 0.10, metal))
			_yoke = Node3D.new()
			_yoke.position.y = 0.16
			add_child(_yoke)
			var armL := _box(Vector3(0.04, 0.26, 0.14), metal)
			armL.position = Vector3(-0.16, 0.13, 0)
			_yoke.add_child(armL)
			var armR := _box(Vector3(0.04, 0.26, 0.14), metal)
			armR.position = Vector3(0.16, 0.13, 0)
			_yoke.add_child(armR)
			_head = Node3D.new()
			_head.position.y = 0.22
			_yoke.add_child(_head)
			_head.add_child(_box(Vector3(0.24, 0.20, 0.24), metal))
			_build_heads(_head, Vector3(0, 0, -0.13), true, false)
		"blinder", "strobe":
			add_child(_box(Vector3(0.55, 0.38, 0.12), metal))
			_build_heads(self, Vector3(0, 0, -0.07), false, true, 65.0)
		"strip", "bar", "pixel_bar":
			var span := 0.0
			for o in _head_offsets():
				span = maxf(span, absf(o.x) * 2.0)
			var w := maxf(1.0, span + 0.2)
			add_child(_box(Vector3(w, 0.09, 0.09), metal))
			_build_heads(self, Vector3(0, 0, -0.06), false, true, 55.0)
		_:
			var can := _cyl(0.11, 0.11, 0.24, metal)
			can.rotation_degrees.x = 90.0
			can.position.z = -0.02
			add_child(can)
			_build_heads(self, Vector3(0, 0, -0.13), _category != "wash", false,
				32.0 if _category == "wash" else 0.0)


## Build one light (+ optional beam cone / emissive glow) per head, each
## parented at its offset under `carrier`.
func _build_heads(carrier: Node3D, base_at: Vector3, want_cone: bool, want_emissive: bool, angle_override := 0.0) -> void:
	var offsets := _head_offsets()
	for i in range(offsets.size()):
		var node := Node3D.new()
		node.position = base_at + offsets[i]
		carrier.add_child(node)
		var hd := {"node": node, "light": null, "beam": null, "emissive": null}

		var lt := SpotLight3D.new()
		lt.spot_range = 28.0
		lt.spot_angle = angle_override * 0.5 if angle_override > 0.0 \
			else clampf(float(profile.physical.get("beam_deg", 14.0)) * 0.5, 2.0, 60.0)
		lt.spot_angle_attenuation = 0.6
		lt.spot_attenuation = 1.2
		lt.light_energy = 0.0
		lt.shadow_enabled = shadows
		lt.light_volumetric_fog_energy = 3.0
		lt.distance_fade_enabled = true
		lt.distance_fade_begin = 24.0
		lt.distance_fade_length = 10.0
		node.add_child(lt)
		hd["light"] = lt

		if want_cone:
			hd["beam"] = _mk_beam()
			node.add_child(hd["beam"])
		if want_emissive:
			var sz := Vector3(0.22, 0.14, 0.02) if offsets.size() > 1 else Vector3(0.5, 0.32, 0.02)
			hd["emissive"] = _mk_emissive(sz)
			node.add_child(hd["emissive"])

		_heads.append(hd)


func _mk_beam() -> MeshInstance3D:
	var bm := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 0.02
	cyl.height = 1.0
	cyl.radial_segments = 22
	cyl.cap_top = false
	cyl.cap_bottom = false
	bm.mesh = cyl
	bm.rotation_degrees = Vector3(-90, 0, 0)
	bm.position = Vector3(0, 0, -0.5)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.albedo_texture = _get_beam_gradient()
	mat.texture_repeat = false   # clamp — no bright seam at the far end
	mat.albedo_color = Color(1, 1, 1, 0.0)
	bm.material_override = mat
	bm.visible = false
	return bm


func _mk_emissive(size: Vector3) -> MeshInstance3D:
	var mi := _box(size, StandardMaterial3D.new())
	var m: StandardMaterial3D = mi.material_override
	m.albedo_color = Color(0.02, 0.02, 0.02)
	m.emission_enabled = true
	m.emission = Color.WHITE
	m.emission_energy_multiplier = 0.0
	return mi


func _add_selection_and_picker() -> void:
	_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.26
	torus.outer_radius = 0.32
	_ring.mesh = torus
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.albedo_color = Color(0.2, 1.0, 1.0)
	rm.emission_enabled = true
	rm.emission = Color(0.2, 1.0, 1.0)
	_ring.material_override = rm
	_ring.position.y = -0.02
	_ring.visible = false
	add_child(_ring)

	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var shp := BoxShape3D.new()
	shp.size = Vector3(0.5, 0.5, 0.5)
	cs.shape = shp
	cs.position.y = 0.15
	body.add_child(cs)
	add_child(body)


static func _get_beam_gradient() -> Texture2D:
	if _beam_gradient == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 1.0])
		g.colors = PackedColorArray([Color(1, 1, 1, 0.5), Color(1, 1, 1, 0.0)])
		var gt := GradientTexture2D.new()
		gt.gradient = g
		gt.width = 4
		gt.height = 64
		gt.fill_from = Vector2(0, 1)
		gt.fill_to = Vector2(0, 0)
		_beam_gradient = gt
	return _beam_gradient


# ------------------------------------------------------------- RUNTIME --

func _process(delta: float) -> void:
	if profile == null:
		return
	var uni := ArtNet.get_universe(universe)
	if uni == null:
		return
	var st := DmxRender.evaluate(profile, mode, uni.output, start)

	var k := clampf(delta * 8.0, 0.0, 1.0)
	if _yoke:
		_cur_pan = lerpf(_cur_pan, deg_to_rad(float(st["pan"])), k)
		_yoke.rotation.y = _cur_pan
	if _head:
		_cur_tilt = lerpf(_cur_tilt, deg_to_rad(float(st["tilt"])), k)
		_head.rotation.x = _head_base + _cur_tilt

	var mult := 1.0
	if st["strobe_hz"] > 0.01:
		_strobe_phase += delta * float(st["strobe_hz"])
		mult = 1.0 if fmod(_strobe_phase, 1.0) < 0.5 else 0.0
	else:
		_strobe_phase = 0.0

	var half_angle: float = clampf(float(st["zoom"]) * 0.5, 2.0, 65.0)
	var hstates: Array = st["heads"]

	for i in range(_heads.size()):
		var hd: Dictionary = _heads[i]
		var hs: Dictionary = hstates[i] if i < hstates.size() else hstates[hstates.size() - 1]
		var dim: float = float(hs["level"]) * mult
		var color: Color = hs["color"]
		var lt: SpotLight3D = hd["light"]
		if lt:
			lt.light_color = color
			lt.light_energy = _base_energy * dim
			lt.spot_angle = half_angle
			lt.visible = dim > 0.002
		var bm: MeshInstance3D = hd["beam"]
		if bm:
			if dim > 0.004:
				var wide := tan(deg_to_rad(half_angle)) * _beam_len
				bm.scale = Vector3(wide, _beam_len, wide)
				bm.position.z = -_beam_len * 0.5
				var mat: StandardMaterial3D = bm.material_override
				mat.albedo_color = Color(color.r, color.g, color.b, clampf(0.16 * dim, 0.0, 0.30))
				bm.visible = true
			else:
				bm.visible = false
		var em: MeshInstance3D = hd["emissive"]
		if em:
			var m: StandardMaterial3D = em.material_override
			m.emission = color
			m.emission_energy_multiplier = dim * 7.0

	# gobo + spin on head 0 only
	if _light:
		_apply_gobo(String(st["gobo"]))
		if float(st["gobo_rot"]) != 0.0 and _light.light_projector != null:
			_gobo_roll += deg_to_rad(float(st["gobo_rot"])) * delta
			_light.rotation.z = _gobo_roll


func _apply_gobo(b64: String) -> void:
	if b64 == _cur_gobo or _light == null:
		return
	_cur_gobo = b64
	if b64 == "":
		_light.light_projector = null
		return
	if not _gobo_cache.has(b64):
		var bytes := Marshalls.base64_to_raw(b64)
		var img := Image.new()
		if bytes.is_empty() or img.load_png_from_buffer(bytes) != OK:
			_gobo_cache[b64] = null
		else:
			_gobo_cache[b64] = ImageTexture.create_from_image(img)
	_light.light_projector = _gobo_cache[b64]


# ------------------------------------------------------------- EDITING --

func _set_selected(v: bool) -> void:
	selected = v
	if _ring:
		_ring.visible = v


func _set_shadows(v: bool) -> void:
	shadows = v
	for hd in _heads:
		if hd["light"]:
			hd["light"].shadow_enabled = v


func apply_transform(pos: Vector3, rot_deg: Vector3) -> void:
	position = pos
	rotation_degrees = Vector3(-rot_deg.x, rot_deg.y, rot_deg.z)
