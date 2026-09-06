class_name FixtureView
extends Node3D
## One patched fixture in the 3D visualizer. Builds a schematic body by
## category, and every frame reads its slice of the universe's composited
## `output` buffer (via DmxRender) to drive a SpotLight3D — colour,
## intensity, pan/tilt, zoom, strobe, gobo projection — plus a faint beam
## cone that reads even when the haze is low.

var universe := 0
var start := 0          # 0-based
var mode := 0
var fixture_id := 0
var display_name := ""
var profile: FixtureProfile

var selected := false: set = _set_selected

var _category := "par"
var _base_energy := 12.0
var _beam_len := 13.0

var _yoke: Node3D
var _head: Node3D
var _light: SpotLight3D
var _beam: MeshInstance3D
var _emissive: MeshInstance3D
var _ring: MeshInstance3D

var _cur_pan := 0.0
var _cur_tilt := 0.0
var _strobe_phase := 0.0
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
	_build()
	set_process(true)


# ------------------------------------------------------------ CATEGORY --

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


# --------------------------------------------------------------- BUILD --

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


func _build() -> void:
	var metal := _metal()

	match _category:
		"moving_head", "scanner":
			add_child(_cyl(0.13, 0.15, 0.10, metal))  # base
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
			var headbox := _box(Vector3(0.24, 0.20, 0.24), metal)
			_head.add_child(headbox)
			_attach_light(_head, Vector3(0, 0, -0.13))
			_attach_beam(_head, Vector3(0, 0, -0.13))
		"blinder", "strobe":
			var panel := _box(Vector3(0.55, 0.38, 0.12), metal)
			add_child(panel)
			_attach_emissive(Vector3(0.5, 0.32, 0.02), Vector3(0, 0, -0.07))
			_attach_light(self, Vector3(0, 0, -0.1))
			_light.spot_angle = 65.0
		"strip", "bar", "pixel_bar":
			var bar := _box(Vector3(1.0, 0.09, 0.09), metal)
			add_child(bar)
			_attach_emissive(Vector3(0.96, 0.05, 0.02), Vector3(0, 0, -0.06))
			_attach_light(self, Vector3(0, 0, -0.08))
			_light.spot_angle = 55.0
		_:  # par / wash / beam / generic — a can pointing down its -Z
			var can := _cyl(0.11, 0.11, 0.24, metal)
			can.rotation_degrees.x = 90.0    # cylinder axis -> Z
			can.position.z = -0.02
			add_child(can)
			_attach_light(self, Vector3(0, 0, -0.13))
			_attach_beam(self, Vector3(0, 0, -0.13))
			if _category == "wash":
				_light.spot_angle = 32.0

	# selection ring at the base
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

	# picker (collision layer 2)
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0
	body.set_meta("fixture_view", get_instance_id())
	var cs := CollisionShape3D.new()
	var shp := BoxShape3D.new()
	shp.size = Vector3(0.5, 0.5, 0.5)
	cs.shape = shp
	cs.position.y = 0.15
	body.add_child(cs)
	add_child(body)


func _attach_light(parent: Node3D, at: Vector3) -> void:
	_light = SpotLight3D.new()
	_light.position = at
	_light.spot_range = 26.0
	_light.spot_angle = clampf(float(profile.physical.get("beam_deg", 14.0)) * 0.5, 2.0, 60.0)
	_light.spot_angle_attenuation = 0.6
	_light.spot_attenuation = 1.2
	_light.light_energy = 0.0
	_light.shadow_enabled = false
	_light.light_volumetric_fog_energy = 3.0
	_light.distance_fade_enabled = true
	_light.distance_fade_begin = 24.0
	_light.distance_fade_length = 10.0
	parent.add_child(_light)


func _attach_beam(parent: Node3D, at: Vector3) -> void:
	if _category in ["blinder", "strobe", "strip", "bar", "pixel_bar", "wash"]:
		return
	_beam = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0      # wide end
	cyl.bottom_radius = 0.02  # at the lens
	cyl.height = 1.0
	cyl.radial_segments = 22
	cyl.cap_top = false
	cyl.cap_bottom = false
	_beam.mesh = cyl
	_beam.rotation_degrees = Vector3(-90, 0, 0)  # +Y (wide) -> -Z (out the front)
	_beam.position = at + Vector3(0, 0, -0.5)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.albedo_texture = _get_beam_gradient()
	mat.albedo_color = Color(1, 1, 1, 0.0)
	_beam.material_override = mat
	_beam.visible = false
	parent.add_child(_beam)


func _attach_emissive(size: Vector3, at: Vector3) -> void:
	_emissive = _box(size, StandardMaterial3D.new())
	_emissive.position = at
	var m: StandardMaterial3D = _emissive.material_override
	m.albedo_color = Color(0.02, 0.02, 0.02)
	m.emission_enabled = true
	m.emission = Color.WHITE
	m.emission_energy_multiplier = 0.0
	add_child(_emissive)


static func _get_beam_gradient() -> Texture2D:
	if _beam_gradient == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 1.0])
		g.colors = PackedColorArray([Color(1, 1, 1, 0.5), Color(1, 1, 1, 0.0)])
		var gt := GradientTexture2D.new()
		gt.gradient = g
		gt.width = 4
		gt.height = 64
		gt.fill_from = Vector2(0, 1)  # wide end (v=1 after our -90 rot maps to lens? keep simple)
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

	# Moving heads have a hard range — plain lerp toward the target angle,
	# never the wrap-around short path.
	var k := clampf(delta * 8.0, 0.0, 1.0)
	if _yoke:
		_cur_pan = lerpf(_cur_pan, deg_to_rad(float(st["pan"])), k)
		_yoke.rotation.y = _cur_pan
	if _head:
		_cur_tilt = lerpf(_cur_tilt, deg_to_rad(float(st["tilt"])), k)
		_head.rotation.x = _cur_tilt

	var mult := 1.0
	if st["strobe_hz"] > 0.01:
		_strobe_phase += delta * float(st["strobe_hz"])
		mult = 1.0 if fmod(_strobe_phase, 1.0) < 0.5 else 0.0
	else:
		_strobe_phase = 0.0
	var dim: float = float(st["dimmer"]) * mult
	var color: Color = st["color"]
	var half_angle: float = clampf(float(st["zoom"]) * 0.5, 2.0, 65.0)

	if _light:
		_light.light_color = color
		_light.light_energy = _base_energy * dim
		_light.spot_angle = half_angle
		_light.visible = dim > 0.002
		_apply_gobo(String(st["gobo"]))
	if _beam:
		if dim > 0.004:
			var wide := tan(deg_to_rad(half_angle)) * _beam_len
			_beam.scale = Vector3(wide, _beam_len, wide)
			_beam.position.z = -_beam_len * 0.5
			var mat: StandardMaterial3D = _beam.material_override
			mat.albedo_color = Color(color.r, color.g, color.b, clampf(0.16 * dim, 0.0, 0.30))
			_beam.visible = true
		else:
			_beam.visible = false
	if _emissive:
		var em: StandardMaterial3D = _emissive.material_override
		em.emission = color
		em.emission_energy_multiplier = dim * 7.0


func _apply_gobo(b64: String) -> void:
	if b64 == _cur_gobo:
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


func apply_transform(pos: Vector3, rot_deg: Vector3) -> void:
	position = pos
	# rot.x tilts the nose down; rot.y is heading
	rotation_degrees = Vector3(-rot_deg.x, rot_deg.y, rot_deg.z)
