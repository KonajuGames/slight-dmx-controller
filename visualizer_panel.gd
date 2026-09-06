class_name VisualizerPanel
extends Control
## 3D visualizer tab: a lit room with the patched fixtures, driven live by
## each universe's composited DMX output. Orbit the camera, click a
## fixture to select it, drag it on the floor or type its position, add
## trusses, and set the haze / room.

const ROOMS := {
	"Black Box": {"floor": Vector2(26, 20), "wall": Color(0.05, 0.05, 0.06), "haze": 0.022},
	"Club": {"floor": Vector2(16, 13), "wall": Color(0.04, 0.03, 0.06), "haze": 0.05},
	"Arena": {"floor": Vector2(44, 30), "wall": Color(0.06, 0.06, 0.07), "haze": 0.013},
}
const HAZE_MAX := 0.09

var panels: Array = []   # shared reference to the shell's _panels

var _svc: SubViewportContainer
var _vp: SubViewport
var _world: Node3D
var _cam: Camera3D
var _env: Environment
var _work_light: DirectionalLight3D
var _floor: MeshInstance3D
var _wall: MeshInstance3D
var _fixture_root: Node3D
var _truss_root: Node3D

# camera orbit
var _cam_target := Vector3(0, 1.5, -3)
var _cam_yaw := 0.4
var _cam_pitch := 0.35
var _cam_dist := 15.0

# interaction
var _drag := ""            # "", "orbit", "pan", "move"
var _drag_from := Vector2.ZERO
var _drag_moved := false
var _move_node: Node3D = null
var _selected: Node3D = null

var _room := "Black Box"

# overlay UI
var _haze_slider: HSlider
var _worklight_check: CheckButton
var _room_option: OptionButton
var _prop_panel: PanelContainer
var _prop_title: Label
var _px: SpinBox
var _py: SpinBox
var _pz: SpinBox
var _phead: SpinBox
var _ptilt: SpinBox
var _plen: SpinBox
var _plen_row: Control
var _prot_row: Control
var _syncing := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_viewport()
	_build_world()
	_build_overlay()
	_apply_room(_room)
	_update_camera()
	set_process(true)


# ------------------------------------------------------------ VIEWPORT --

func _build_viewport() -> void:
	_svc = SubViewportContainer.new()
	_svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	_svc.stretch = true
	_svc.mouse_filter = Control.MOUSE_FILTER_IGNORE  # events fall through to _gui_input
	add_child(_svc)

	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_2X
	_vp.handle_input_locally = false
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_svc.add_child(_vp)


func _build_world() -> void:
	_world = Node3D.new()
	_vp.add_child(_world)

	_cam = Camera3D.new()
	_cam.fov = 55.0
	_cam.near = 0.05
	_cam.far = 250.0
	_world.add_child(_cam)
	_cam.current = true

	var we := WorldEnvironment.new()
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.02, 0.02, 0.03)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.55, 0.55, 0.65)
	_env.ambient_light_energy = 0.07
	_env.tonemap_mode = Environment.TONE_MAPPER_AGX
	_env.tonemap_exposure = 1.1
	_env.glow_enabled = true
	_env.glow_intensity = 0.7
	_env.glow_bloom = 0.2
	_env.glow_hdr_threshold = 0.7
	_env.volumetric_fog_enabled = true
	_env.volumetric_fog_density = 0.03
	_env.volumetric_fog_length = 55.0
	_env.volumetric_fog_gi_inject = 0.0
	_env.volumetric_fog_ambient_inject = 0.0
	we.environment = _env
	_world.add_child(we)

	_work_light = DirectionalLight3D.new()
	_work_light.rotation_degrees = Vector3(-55, -30, 0)
	_work_light.light_energy = 0.12
	_work_light.light_color = Color(0.9, 0.92, 1.0)
	_work_light.shadow_enabled = false
	_world.add_child(_work_light)

	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.08, 0.08, 0.09)
	fm.roughness = 0.95
	_floor = MeshInstance3D.new()
	_floor.mesh = PlaneMesh.new()
	_floor.material_override = fm
	_world.add_child(_floor)
	var fb := StaticBody3D.new()
	fb.collision_layer = 1
	fb.collision_mask = 0
	var fcs := CollisionShape3D.new()
	fcs.shape = WorldBoundaryShape3D.new()  # infinite ground plane at y=0
	fb.add_child(fcs)
	_floor.add_child(fb)

	var wm := StandardMaterial3D.new()
	wm.albedo_color = Color(0.05, 0.05, 0.06)
	wm.roughness = 1.0
	_wall = MeshInstance3D.new()
	_wall.mesh = PlaneMesh.new()
	_wall.material_override = wm
	_wall.rotation_degrees = Vector3(90, 0, 0)
	_world.add_child(_wall)

	_fixture_root = Node3D.new()
	_world.add_child(_fixture_root)
	_truss_root = Node3D.new()
	_world.add_child(_truss_root)


# ------------------------------------------------------------- OVERLAY --

func _mklabel(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


func _build_overlay() -> void:
	var bar := PanelContainer.new()
	bar.position = Vector2(8, 8)
	bar.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	bar.add_child(row)

	row.add_child(_mklabel("Haze"))
	_haze_slider = HSlider.new()
	_haze_slider.min_value = 0.0
	_haze_slider.max_value = 1.0
	_haze_slider.step = 0.01
	_haze_slider.value = 0.35
	_haze_slider.custom_minimum_size = Vector2(120, 0)
	_haze_slider.value_changed.connect(func(v: float): _env.volumetric_fog_density = v * HAZE_MAX)
	row.add_child(_haze_slider)

	_worklight_check = CheckButton.new()
	_worklight_check.text = "Work light"
	_worklight_check.button_pressed = true
	_worklight_check.toggled.connect(func(on: bool): _work_light.light_energy = 0.12 if on else 0.0)
	row.add_child(_worklight_check)

	row.add_child(_mklabel("Room"))
	_room_option = OptionButton.new()
	for k in ROOMS:
		_room_option.add_item(k)
	_room_option.item_selected.connect(func(i: int): _apply_room(_room_option.get_item_text(i)))
	row.add_child(_room_option)

	var truss_btn := Button.new()
	truss_btn.text = "Add Truss"
	truss_btn.pressed.connect(_add_truss)
	row.add_child(truss_btn)

	var arrange_btn := Button.new()
	arrange_btn.text = "Auto-arrange"
	arrange_btn.pressed.connect(_auto_arrange)
	row.add_child(arrange_btn)

	var reset_btn := Button.new()
	reset_btn.text = "Reset view"
	reset_btn.pressed.connect(func():
		_cam_target = Vector3(0, 1.5, -3)
		_cam_yaw = 0.4
		_cam_pitch = 0.35
		_cam_dist = 15.0
		_update_camera())
	row.add_child(reset_btn)

	# --- selected-item properties ---
	_prop_panel = PanelContainer.new()
	_prop_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_prop_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_prop_panel.position = Vector2(8, 8)
	_prop_panel.offset_bottom = -8
	_prop_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(_prop_panel)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 4)
	_prop_panel.add_child(pv)

	_prop_title = _mklabel("")
	pv.add_child(_prop_title)

	var grid := GridContainer.new()
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", 6)
	pv.add_child(grid)
	grid.add_child(_mklabel("X"))
	_px = _pos_spin()
	grid.add_child(_px)
	grid.add_child(_mklabel("Y"))
	_py = _pos_spin()
	grid.add_child(_py)
	grid.add_child(_mklabel("Z"))
	_pz = _pos_spin()
	grid.add_child(_pz)
	for s in [_px, _py, _pz]:
		s.value_changed.connect(func(_v): _write_selected_transform())

	_prot_row = HBoxContainer.new()
	_prot_row.add_child(_mklabel("Heading"))
	_phead = _ang_spin()
	_prot_row.add_child(_phead)
	_prot_row.add_child(_mklabel("Tilt down"))
	_ptilt = _ang_spin()
	_prot_row.add_child(_ptilt)
	for s in [_phead, _ptilt]:
		s.value_changed.connect(func(_v): _write_selected_transform())
	pv.add_child(_prot_row)

	_plen_row = HBoxContainer.new()
	_plen_row.add_child(_mklabel("Length"))
	_plen = SpinBox.new()
	_plen.min_value = 0.5
	_plen.max_value = 20.0
	_plen.step = 0.5
	_plen.value = 4.0
	_plen.value_changed.connect(func(_v): _write_selected_transform())
	_plen_row.add_child(_plen)
	var del_btn := Button.new()
	del_btn.text = "Delete truss"
	del_btn.pressed.connect(_delete_selected_truss)
	_plen_row.add_child(del_btn)
	pv.add_child(_plen_row)

	_prop_panel.visible = false


func _pos_spin() -> SpinBox:
	var s := SpinBox.new()
	s.min_value = -40
	s.max_value = 40
	s.step = 0.1
	s.custom_minimum_size = Vector2(64, 0)
	return s


func _ang_spin() -> SpinBox:
	var s := SpinBox.new()
	s.min_value = -180
	s.max_value = 180
	s.step = 1
	s.custom_minimum_size = Vector2(64, 0)
	return s


# -------------------------------------------------------------- CAMERA --

func _update_camera() -> void:
	_cam_pitch = clampf(_cam_pitch, -1.45, 1.45)
	_cam_dist = clampf(_cam_dist, 2.0, 90.0)
	var dir := Vector3(
		cos(_cam_pitch) * sin(_cam_yaw),
		sin(_cam_pitch),
		cos(_cam_pitch) * cos(_cam_yaw))
	_cam.position = _cam_target + dir * _cam_dist
	_cam.look_at(_cam_target, Vector3.UP)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_cam_dist *= 0.9
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_cam_dist *= 1.1
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_begin_drag(mb.position, mb.shift_pressed)
			else:
				_end_drag()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_drag = "pan" if mb.pressed else ""
			_drag_from = mb.position
	elif event is InputEventMouseMotion and _drag != "":
		_drag_motion(event as InputEventMouseMotion)


func _begin_drag(pos: Vector2, shift: bool) -> void:
	_drag_from = pos
	_drag_moved = false
	if shift:
		_drag = "pan"
		return
	var hit := _raycast(pos, 2 | 4)  # fixtures + trusses
	if hit.is_empty():
		_drag = "orbit"
	else:
		var node: Node3D = hit["collider"].get_parent()
		_select(node)
		_move_node = node
		_drag = "move"


func _drag_motion(mm: InputEventMouseMotion) -> void:
	if mm.position.distance_to(_drag_from) > 3.0:
		_drag_moved = true
	match _drag:
		"orbit":
			_cam_yaw -= mm.relative.x * 0.01
			_cam_pitch += mm.relative.y * 0.01
			_update_camera()
		"pan":
			var right := _cam.global_transform.basis.x
			var up := _cam.global_transform.basis.y
			_cam_target -= (right * mm.relative.x - up * mm.relative.y) * _cam_dist * 0.0016
			_update_camera()
		"move":
			if _move_node:
				var plane := Plane(Vector3.UP, _move_node.position.y)
				var from := _cam.project_ray_origin(mm.position)
				var dir := _cam.project_ray_normal(mm.position)
				var p = plane.intersects_ray(from, dir)
				if p != null:
					_move_node.position = Vector3(p.x, _move_node.position.y, p.z)
					_sync_props_from_selected()
					_write_selected_transform()


func _end_drag() -> void:
	if _drag == "orbit" and not _drag_moved:
		_select(null)  # click on empty space clears selection
	_drag = ""
	_move_node = null


func _raycast(pos: Vector2, mask: int) -> Dictionary:
	var space := _world.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		_cam.project_ray_origin(pos),
		_cam.project_ray_origin(pos) + _cam.project_ray_normal(pos) * 300.0)
	q.collision_mask = mask
	return space.intersect_ray(q)


# ------------------------------------------------------------ SELECTION --

func _select(node: Node3D) -> void:
	if _selected == node:
		return
	if _selected and _selected is FixtureView:
		(_selected as FixtureView).selected = false
	if _selected and _selected.has_meta("truss"):
		_set_truss_selected(_selected, false)
	_selected = node
	if _selected and _selected is FixtureView:
		(_selected as FixtureView).selected = true
	if _selected and _selected.has_meta("truss"):
		_set_truss_selected(_selected, true)
	_refresh_props()


func _refresh_props() -> void:
	if _selected == null:
		_prop_panel.visible = false
		return
	_prop_panel.visible = true
	var is_fx := _selected is FixtureView
	_prot_row.visible = is_fx
	_plen_row.visible = not is_fx
	if is_fx:
		var fv := _selected as FixtureView
		_prop_title.text = "%s   (U%d ch %d-%d)" % [
			fv.display_name, fv.universe + 1, fv.start + 1,
			fv.start + fv.profile.channel_count(fv.mode)]
	else:
		_prop_title.text = "Truss"
	_sync_props_from_selected()


func _sync_props_from_selected() -> void:
	if _selected == null:
		return
	_syncing = true
	_px.value = _selected.position.x
	_py.value = _selected.position.y
	_pz.value = _selected.position.z
	if _selected is FixtureView:
		var e := _patch_entry(_selected as FixtureView)
		var r: Vector3 = e.get("rot", Vector3.ZERO) if e else Vector3.ZERO
		_phead.value = r.y
		_ptilt.value = r.x
	else:
		_plen.value = _selected.get_meta("len", 4.0)
		_phead.value = _selected.rotation_degrees.y
	_syncing = false


func _write_selected_transform() -> void:
	if _syncing or _selected == null:
		return
	_selected.position = Vector3(_px.value, _py.value, _pz.value)
	if _selected is FixtureView:
		var fv := _selected as FixtureView
		var rot := Vector3(_ptilt.value, _phead.value, 0)
		fv.apply_transform(_selected.position, rot)
		var e := _patch_entry(fv)
		if e:
			e["pos"] = _selected.position
			e["rot"] = rot
	elif _selected.has_meta("truss"):
		_selected.set_meta("len", _plen.value)
		_selected.rotation_degrees.y = _phead.value
		_reshape_truss(_selected, _plen.value)


func _patch_entry(fv: FixtureView) -> Dictionary:
	if fv.universe < 0 or fv.universe >= panels.size():
		return {}
	for f in panels[fv.universe].patched_fixtures:
		if int(f["id"]) == fv.fixture_id:
			return f
	return {}


# --------------------------------------------------------------- TRUSS --

func _make_truss_mesh() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.1, 0.1, 0.11)
	m.metallic = 0.7
	m.roughness = 0.4
	mi.material_override = m
	return mi


func _reshape_truss(truss: Node3D, length: float) -> void:
	var mi: MeshInstance3D = truss.get_node("mesh")
	(mi.mesh as BoxMesh).size = Vector3(length, 0.16, 0.16)
	var cs: CollisionShape3D = truss.get_node("body/shape")
	(cs.shape as BoxShape3D).size = Vector3(length, 0.16, 0.16)


func _spawn_truss(pos: Vector3, length: float, rot_y: float) -> Node3D:
	var truss := Node3D.new()
	truss.set_meta("truss", true)
	truss.set_meta("len", length)
	truss.position = pos
	truss.rotation_degrees.y = rot_y
	var mi := _make_truss_mesh()
	mi.name = "mesh"
	truss.add_child(mi)
	var body := StaticBody3D.new()
	body.name = "body"
	body.collision_layer = 4
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.name = "shape"
	cs.shape = BoxShape3D.new()
	body.add_child(cs)
	truss.add_child(body)
	_truss_root.add_child(truss)
	_reshape_truss(truss, length)
	return truss


func _add_truss() -> void:
	var t := _spawn_truss(_cam_target + Vector3(0, 4.0, 0), 4.0, 0.0)
	_select(t)


func _set_truss_selected(truss: Node3D, on: bool) -> void:
	var mi: MeshInstance3D = truss.get_node("mesh")
	var m: StandardMaterial3D = mi.material_override
	m.emission_enabled = on
	m.emission = Color(0.2, 1.0, 1.0)
	m.emission_energy_multiplier = 0.4 if on else 0.0


func _delete_selected_truss() -> void:
	if _selected and _selected.has_meta("truss"):
		var t := _selected
		_select(null)
		t.queue_free()


# ------------------------------------------------------------ FIXTURES --

## Rebuild the 3D fixtures from the current patch (called on any patch
## change). Selection is dropped.
func rebuild() -> void:
	_select(null)
	for c in _fixture_root.get_children():
		c.queue_free()
	for u in range(panels.size()):
		for f in panels[u].patched_fixtures:
			var fv := FixtureView.new()
			_fixture_root.add_child(fv)
			fv.setup(u, int(f["start"]), int(f.get("mode", 0)),
				f["profile"], int(f["id"]), String(f["name"]))
			fv.apply_transform(
				f.get("pos", UniversePanel.auto_place(0)),
				f.get("rot", Vector3(28, 0, 0)))


func _auto_arrange() -> void:
	for u in range(panels.size()):
		var i := 0
		for f in panels[u].patched_fixtures:
			f["pos"] = UniversePanel.auto_place(i) + Vector3(0, 0, u * -2.0)
			f["rot"] = Vector3(28, 0, 0)
			i += 1
	rebuild()


# ---------------------------------------------------------------- ROOM --

func _apply_room(name: String) -> void:
	if not ROOMS.has(name):
		return
	_room = name
	var r: Dictionary = ROOMS[name]
	var fs: Vector2 = r["floor"]
	(_floor.mesh as PlaneMesh).size = fs
	(_floor.material_override as StandardMaterial3D).albedo_color = Color(0.08, 0.08, 0.09)
	(_wall.mesh as PlaneMesh).size = Vector2(fs.x, 8.0)
	_wall.position = Vector3(0, 4.0, -fs.y * 0.5)
	(_wall.material_override as StandardMaterial3D).albedo_color = r["wall"]
	_haze_slider.value = float(r["haze"]) / HAZE_MAX
	_env.volumetric_fog_density = float(r["haze"])
	for i in range(_room_option.item_count):
		if _room_option.get_item_text(i) == name:
			_room_option.selected = i


# ------------------------------------------------------------- PROCESS --

func _process(_delta: float) -> void:
	# While the tab is on screen, recompute output every frame so movement
	# and colour stay smooth; otherwise the 30 Hz refresh tick is enough.
	if is_visible_in_tree():
		ArtNet.tick(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and _fixture_root:
		# Don't run every FixtureView's _process while the tab is hidden.
		_fixture_root.process_mode = (
			Node.PROCESS_MODE_INHERIT if is_visible_in_tree()
			else Node.PROCESS_MODE_DISABLED)


# ------------------------------------------------------- SERIALIZATION --

func to_dict() -> Dictionary:
	var trusses: Array = []
	for t in _truss_root.get_children():
		trusses.append([t.position.x, t.position.y, t.position.z,
			t.get_meta("len", 4.0), t.rotation_degrees.y])
	return {
		"room": _room,
		"haze": _haze_slider.value,
		"work_light": _worklight_check.button_pressed,
		"cam": [_cam_target.x, _cam_target.y, _cam_target.z, _cam_yaw, _cam_pitch, _cam_dist],
		"trusses": trusses,
	}


func from_dict(d: Dictionary) -> void:
	if not (d is Dictionary):
		return
	_apply_room(String(d.get("room", _room)))
	if d.has("haze"):
		_haze_slider.value = float(d["haze"])
		_env.volumetric_fog_density = float(d["haze"]) * HAZE_MAX
	if d.has("work_light"):
		_worklight_check.button_pressed = bool(d["work_light"])
		_work_light.light_energy = 0.12 if _worklight_check.button_pressed else 0.0
	var cam = d.get("cam", null)
	if cam is Array and cam.size() == 6:
		_cam_target = Vector3(cam[0], cam[1], cam[2])
		_cam_yaw = cam[3]
		_cam_pitch = cam[4]
		_cam_dist = cam[5]
		_update_camera()
	for t in _truss_root.get_children():
		t.queue_free()
	for tr in d.get("trusses", []):
		if tr is Array and tr.size() >= 5:
			_spawn_truss(Vector3(tr[0], tr[1], tr[2]), float(tr[3]), float(tr[4]))
