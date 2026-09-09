class_name VisualizerPanel
extends Control
## 3D visualizer tab: a lit room with the patched fixtures, driven live by
## each universe's composited DMX output. Orbit the camera, click a
## fixture to select it, drag it on the floor or type its position, add
## trusses, and set the haze / room.

const ROOMS := {
	"Black Box": {"floor": Vector2(26, 20), "wall": Color(0.05, 0.05, 0.06), "haze": 0.015},
	"Club": {"floor": Vector2(16, 13), "wall": Color(0.04, 0.03, 0.06), "haze": 0.03},
	"Arena": {"floor": Vector2(44, 30), "wall": Color(0.06, 0.06, 0.07), "haze": 0.008},
}
const HAZE_MAX := 0.05

## "Dock to Main" button (shown only while floating) — the shell moves
## this panel between the right-hand tab and its own window. Popping *out*
## is done by dragging the tab.
signal popout_pressed

var panels: Array = []   # shared reference to the shell's _panels
## Shell handlers for the whole-rig formats (they touch the patch).
var mvr_import_cb := Callable()   # func(path: String) -> String  (status/error)
var mvr_export_cb := Callable()   # func(path: String) -> String

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
var _cam_views: Array = []   # [{name, target:[x,y,z], yaw, pitch, dist, fov, ortho}]
var _prop_root: Node3D

# recorder
var _rec: VideoRec = null
var _rec_accum := 0.0

# interaction
var _drag := ""            # "", "orbit", "pan", "move"
var _drag_from := Vector2.ZERO
var _drag_moved := false
var _move_node: Node3D = null
var _selected: Node3D = null

var _room := "Black Box"

# overlay UI
var _toolbar: PanelContainer
var _ui_toggle: Button
var _ui_visible := true
var _haze_slider: HSlider
var _worklight_check: CheckButton
var _shadow_check: CheckButton
var _room_option: OptionButton
var _view_option: OptionButton
var _fov_spin: SpinBox
var _ortho_check: CheckButton
var _rec_btn: Button
var _rec_label: Label
var _popout_btn: Button
var _prop_panel: PanelContainer
var _prop_title: Label
var _px: SpinBox
var _py: SpinBox
var _pz: SpinBox
var _phead: SpinBox
var _ptilt: SpinBox
var _plen: SpinBox
var _plen_lbl: Label
var _plen_row: Control
var _prot_row: Control
var _syncing := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_viewport()
	_build_world()
	_build_overlay()
	_seed_views()
	_refresh_view_option()
	_apply_room(_room)
	_apply_view(0)
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
	_env.ambient_light_color = Color(0.5, 0.5, 0.55)
	_env.ambient_light_energy = 0.045
	_env.tonemap_mode = Environment.TONE_MAPPER_ACES
	_env.tonemap_exposure = 1.0
	_env.glow_enabled = true
	_env.glow_intensity = 0.5
	_env.glow_bloom = 0.08
	_env.glow_hdr_threshold = 0.9
	_env.volumetric_fog_enabled = true
	_env.volumetric_fog_density = 0.02
	_env.volumetric_fog_albedo = Color(0.92, 0.92, 0.92)
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
	_prop_root = Node3D.new()
	_world.add_child(_prop_root)


# ------------------------------------------------------------- OVERLAY --

func _mklabel(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


func _flow(h := 8, v := 4) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", h)
	f.add_theme_constant_override("v_separation", v)
	return f


func _btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	return b


## Show the "Dock to Main" button only while the panel is in its own window.
func set_floating(floating: bool) -> void:
	if _popout_btn:
		_popout_btn.visible = floating


func _build_overlay() -> void:
	_toolbar = PanelContainer.new()
	_toolbar.position = Vector2(8, 8)
	_toolbar.custom_minimum_size = Vector2(560, 0)
	_toolbar.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_toolbar)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	_toolbar.add_child(col)

	# --- row 1: look --------------------------------------------------
	var r1 := _flow()
	col.add_child(r1)

	r1.add_child(_mklabel("Haze"))
	_haze_slider = HSlider.new()
	_haze_slider.min_value = 0.0
	_haze_slider.max_value = 1.0
	_haze_slider.step = 0.01
	_haze_slider.value = 0.35
	_haze_slider.custom_minimum_size = Vector2(110, 0)
	_haze_slider.value_changed.connect(func(v: float): _env.volumetric_fog_density = v * HAZE_MAX)
	r1.add_child(_haze_slider)

	_worklight_check = CheckButton.new()
	_worklight_check.text = "Work light"
	_worklight_check.button_pressed = true
	_worklight_check.toggled.connect(func(on: bool): _work_light.light_energy = 0.12 if on else 0.0)
	r1.add_child(_worklight_check)

	_shadow_check = CheckButton.new()
	_shadow_check.text = "Shadows"
	_shadow_check.toggled.connect(_set_shadows)
	r1.add_child(_shadow_check)

	r1.add_child(_mklabel("Room"))
	_room_option = OptionButton.new()
	for k in ROOMS:
		_room_option.add_item(k)
	_room_option.item_selected.connect(func(i: int): _apply_room(_room_option.get_item_text(i)))
	r1.add_child(_room_option)

	# --- row 2: camera ----------------------------------------------
	var r2 := _flow()
	col.add_child(r2)

	r2.add_child(_mklabel("View"))
	_view_option = OptionButton.new()
	_view_option.item_selected.connect(func(i: int): _apply_view(i))
	r2.add_child(_view_option)
	r2.add_child(_btn("Save as...", _save_view_as))
	r2.add_child(_btn("Update", _update_view))
	r2.add_child(_btn("Delete", _delete_view))

	r2.add_child(_mklabel("FOV"))
	_fov_spin = SpinBox.new()
	_fov_spin.min_value = 15
	_fov_spin.max_value = 100
	_fov_spin.value = 55
	_fov_spin.value_changed.connect(func(v: float): _cam.fov = v)
	r2.add_child(_fov_spin)

	_ortho_check = CheckButton.new()
	_ortho_check.text = "Ortho"
	_ortho_check.toggled.connect(func(on: bool):
		_cam.projection = Camera3D.PROJECTION_ORTHOGONAL if on else Camera3D.PROJECTION_PERSPECTIVE
		_update_camera())
	r2.add_child(_ortho_check)

	# --- row 3: scene + render ------------------------------------
	var r3 := _flow()
	col.add_child(r3)
	r3.add_child(_btn("Add Truss", _add_truss))
	r3.add_child(_btn("Load Model...", _load_model_dialog))
	r3.add_child(_btn("Auto-arrange", _auto_arrange))
	r3.add_child(_btn("Import MVR...", func(): _mvr_dialog(false)))
	r3.add_child(_btn("Export MVR...", func(): _mvr_dialog(true)))
	r3.add_child(_btn("Screenshot", _screenshot))
	_rec_btn = _btn("Record", _toggle_record)
	r3.add_child(_rec_btn)
	_rec_label = _mklabel("")
	r3.add_child(_rec_label)

	_popout_btn = _btn("Dock to Main", func(): popout_pressed.emit())
	_popout_btn.visible = false
	r3.add_child(_popout_btn)

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
	_plen_lbl = _mklabel("Length")
	_plen_row.add_child(_plen_lbl)
	_plen = SpinBox.new()
	_plen.min_value = 0.05
	_plen.max_value = 40.0
	_plen.step = 0.1
	_plen.value = 4.0
	_plen.value_changed.connect(func(_v): _write_selected_transform())
	_plen_row.add_child(_plen)
	_plen_row.add_child(_btn("Delete", _delete_selected))
	pv.add_child(_plen_row)

	_prop_panel.visible = false

	# always-visible toggle for the on-screen controls (top-right); added
	# last so it stays clickable over everything else.
	_ui_toggle = _btn("Hide UI", _toggle_ui)
	_ui_toggle.mouse_filter = Control.MOUSE_FILTER_STOP
	_ui_toggle.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_ui_toggle.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_ui_toggle.grow_vertical = Control.GROW_DIRECTION_END
	_ui_toggle.offset_left = -8
	_ui_toggle.offset_right = -8
	_ui_toggle.offset_top = 8
	_ui_toggle.offset_bottom = 8
	add_child(_ui_toggle)


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

func _seed_views() -> void:
	_cam_views = [
		{"name": "Orbit", "target": [0, 1.5, -3], "yaw": 0.4, "pitch": 0.35, "dist": 15.0, "fov": 55.0, "ortho": false},
		{"name": "Front", "target": [0, 2.0, -4], "yaw": 0.0, "pitch": 0.05, "dist": 15.0, "fov": 50.0, "ortho": false},
		{"name": "Audience", "target": [0, 2.5, -5], "yaw": 0.0, "pitch": 0.18, "dist": 24.0, "fov": 40.0, "ortho": false},
		{"name": "FOH high", "target": [0, 2.0, -5], "yaw": 0.15, "pitch": 0.55, "dist": 20.0, "fov": 45.0, "ortho": false},
		{"name": "Top", "target": [0, 1.0, -4], "yaw": 0.0, "pitch": 1.4, "dist": 24.0, "fov": 50.0, "ortho": true},
	]


func _refresh_view_option() -> void:
	var keep := _view_option.selected
	_view_option.clear()
	for v in _cam_views:
		_view_option.add_item(String(v["name"]))
	if keep >= 0 and keep < _view_option.item_count:
		_view_option.selected = keep


func _apply_view(i: int) -> void:
	if i < 0 or i >= _cam_views.size():
		return
	var v: Dictionary = _cam_views[i]
	var t: Array = v["target"]
	_cam_target = Vector3(t[0], t[1], t[2])
	_cam_yaw = float(v["yaw"])
	_cam_pitch = float(v["pitch"])
	_cam_dist = float(v["dist"])
	_cam.fov = float(v.get("fov", 55.0))
	_fov_spin.value = _cam.fov
	var ortho := bool(v.get("ortho", false))
	_ortho_check.button_pressed = ortho
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL if ortho else Camera3D.PROJECTION_PERSPECTIVE
	_update_camera()


func _current_view_dict(name: String) -> Dictionary:
	return {
		"name": name,
		"target": [_cam_target.x, _cam_target.y, _cam_target.z],
		"yaw": _cam_yaw, "pitch": _cam_pitch, "dist": _cam_dist,
		"fov": _cam.fov, "ortho": _cam.projection == Camera3D.PROJECTION_ORTHOGONAL,
	}


func _update_view() -> void:
	var i := _view_option.selected
	if i >= 0 and i < _cam_views.size():
		var n := String(_cam_views[i]["name"])
		_cam_views[i] = _current_view_dict(n)


func _save_view_as() -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Save camera view"
	var le := LineEdit.new()
	le.text = "View %d" % (_cam_views.size() + 1)
	le.custom_minimum_size = Vector2(200, 0)
	dlg.add_child(le)
	dlg.register_text_enter(le)
	add_child(dlg)
	dlg.confirmed.connect(func():
		var n := le.text.strip_edges()
		if n != "":
			_cam_views.append(_current_view_dict(n))
			_refresh_view_option()
			_view_option.selected = _cam_views.size() - 1
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()
	le.grab_focus()
	le.select_all()


func _delete_view() -> void:
	var i := _view_option.selected
	if i >= 0 and i < _cam_views.size() and _cam_views.size() > 1:
		_cam_views.remove_at(i)
		_refresh_view_option()
		_apply_view(_view_option.selected)


func _update_camera() -> void:
	_cam_pitch = clampf(_cam_pitch, -1.45, 1.45)
	_cam_dist = clampf(_cam_dist, 2.0, 120.0)
	var dir := Vector3(
		cos(_cam_pitch) * sin(_cam_yaw),
		sin(_cam_pitch),
		cos(_cam_pitch) * cos(_cam_yaw))
	_cam.position = _cam_target + dir * _cam_dist
	_cam.look_at(_cam_target, Vector3.UP if absf(_cam_pitch) < 1.4 else Vector3.FORWARD)
	if _cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		_cam.size = _cam_dist * 1.1


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
	var hit := _raycast(pos, 2 | 4 | 8)  # fixtures + trusses + props
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


func _toggle_ui() -> void:
	_ui_visible = not _ui_visible
	_ui_toggle.text = "Hide UI" if _ui_visible else "Show UI"
	_toolbar.visible = _ui_visible
	_refresh_props()


func _refresh_props() -> void:
	if _selected == null or not _ui_visible:
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
	elif _selected.has_meta("prop"):
		_prop_title.text = "Model: " + String(_selected.get_meta("model_name", "prop"))
		_plen_lbl.text = "Scale"
	else:
		_prop_title.text = "Truss"
		_plen_lbl.text = "Length"
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
	elif _selected.has_meta("prop"):
		_plen.value = _selected.scale.x
		_phead.value = _selected.rotation_degrees.y
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
	elif _selected.has_meta("prop"):
		_selected.scale = Vector3.ONE * maxf(_plen.value, 0.01)
		_selected.rotation_degrees.y = _phead.value
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


func spawn_truss_at(pos: Vector3, length := 3.0, rot_y := 0.0) -> void:
	_spawn_truss(pos, length, rot_y)


func _set_truss_selected(truss: Node3D, on: bool) -> void:
	var mi: MeshInstance3D = truss.get_node_or_null("mesh")
	if mi == null:
		return
	var m: StandardMaterial3D = mi.material_override
	m.emission_enabled = on
	m.emission = Color(0.2, 1.0, 1.0)
	m.emission_energy_multiplier = 0.4 if on else 0.0


func _delete_selected() -> void:
	if _selected and (_selected.has_meta("truss") or _selected.has_meta("prop")):
		var t := _selected
		_select(null)
		t.queue_free()


# ---------------------------------------------------------- glTF PROPS --

func _load_model_dialog() -> void:
	var fd := FileDialog.new()
	fd.title = "Load glTF model (set piece / stage element)"
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.add_filter("*.glb,*.gltf", "glTF model")
	fd.use_native_dialog = true
	add_child(fd)
	fd.file_selected.connect(func(path: String):
		var n := _spawn_prop(path, _cam_target, 1.0, 0.0)
		if n:
			_select(n)
		fd.queue_free())
	fd.canceled.connect(func(): fd.queue_free())
	fd.popup_centered_ratio(0.6)


func _spawn_prop(path: String, pos: Vector3, scl: float, rot_y: float) -> Node3D:
	var scene := FixtureView._load_glb(path)
	if scene == null:
		return null
	var prop := Node3D.new()
	prop.set_meta("prop", true)
	prop.set_meta("model_path", path)
	prop.set_meta("model_name", path.get_file())
	prop.position = pos
	prop.scale = Vector3.ONE * scl
	prop.rotation_degrees.y = rot_y
	prop.add_child(scene)

	var body := StaticBody3D.new()
	body.collision_layer = 8
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var aabb := _scene_aabb(scene)
	var shp := BoxShape3D.new()
	shp.size = aabb.size.clampf(0.2, 100.0)
	cs.shape = shp
	cs.position = aabb.get_center()
	body.add_child(cs)
	prop.add_child(body)

	_prop_root.add_child(prop)
	return prop


func _scene_aabb(n: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mi in n.find_children("*", "VisualInstance3D", true, false):
		var a: AABB = (mi as VisualInstance3D).get_aabb()
		a = (mi as Node3D).transform * a
		box = a if first else box.merge(a)
		first = false
	if first:
		box = AABB(Vector3(-0.5, 0, -0.5), Vector3.ONE)
	return box


# ------------------------------------------------------------ FIXTURES --

## Rebuild the 3D fixtures from the current patch (called on any patch
## change). Selection is dropped.
func rebuild() -> void:
	_select(null)
	for c in _fixture_root.get_children():
		c.queue_free()
	var want_shadows := _shadow_check.button_pressed if _shadow_check else false
	for u in range(panels.size()):
		for f in panels[u].patched_fixtures:
			var fv := FixtureView.new()
			fv.shadows = want_shadows
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


func _set_shadows(on: bool) -> void:
	for c in _fixture_root.get_children():
		if c is FixtureView:
			(c as FixtureView).shadows = on


# ------------------------------------------------- RENDER / RECORD / MVR --


func _screenshot() -> void:
	var img := _vp.get_texture().get_image()
	if img == null:
		return
	DirAccess.make_dir_recursive_absolute("user://render")
	var p := "user://render/shot_%s.png" % _stamp()
	img.save_png(p)
	_rec_label.text = "Saved " + p.get_file()
	OS.shell_open(ProjectSettings.globalize_path("user://render"))


func _toggle_record() -> void:
	if _rec != null:
		var s := _rec.stop()
		_rec = null
		_rec_btn.text = "Record"
		_rec_label.text = s
		OS.shell_open(ProjectSettings.globalize_path("user://render"))
		return
	var img := _vp.get_texture().get_image()
	if img == null:
		_rec_label.text = "no image to record"
		return
	_rec = VideoRec.new()
	var out := _rec.start("user://render", img.get_width(), img.get_height())
	if out == "":
		_rec = null
		_rec_label.text = "recorder failed to start"
		return
	_rec_accum = 0.0
	_rec_btn.text = "Stop"
	_rec_label.text = "REC → %s%s" % [out.get_file(), "" if _rec.is_mp4() else "  (PNG — build video_rec)"]


func _capture_frame() -> void:
	if _rec != null:
		_rec.push(_vp.get_texture().get_image())


func _stamp() -> String:
	return Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")


func _mvr_dialog(export_mode: bool) -> void:
	var fd := FileDialog.new()
	fd.title = "Export MVR (My Virtual Rig)" if export_mode else "Import MVR (My Virtual Rig)"
	fd.file_mode = FileDialog.FILE_MODE_SAVE_FILE if export_mode else FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.add_filter("*.mvr", "My Virtual Rig")
	if export_mode:
		fd.current_file = "rig.mvr"
	fd.use_native_dialog = true
	add_child(fd)
	fd.file_selected.connect(func(path: String):
		if export_mode and mvr_export_cb.is_valid():
			_rec_label.text = String(mvr_export_cb.call(path))
		elif not export_mode and mvr_import_cb.is_valid():
			_rec_label.text = String(mvr_import_cb.call(path))
		fd.queue_free())
	fd.canceled.connect(func(): fd.queue_free())
	fd.popup_centered_ratio(0.6)


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

func _process(delta: float) -> void:
	# While the tab is on screen, recompute output every frame so movement
	# and colour stay smooth; otherwise the 30 Hz refresh tick is enough.
	if is_visible_in_tree():
		ArtNet.tick(false)
	if _rec != null:
		_rec_accum += delta
		var step := 1.0 / VideoRec.FPS
		var grabbed := 0
		while _rec_accum >= step and grabbed < 3:   # cap catch-up so a hitch doesn't spiral
			_rec_accum -= step
			_capture_frame()
			grabbed += 1
		_rec_label.text = "REC  %d" % _rec.frame_count()


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
	var props: Array = []
	for p in _prop_root.get_children():
		props.append({
			"path": String(p.get_meta("model_path", "")),
			"pos": [p.position.x, p.position.y, p.position.z],
			"scale": p.scale.x, "rot_y": p.rotation_degrees.y,
		})
	return {
		"room": _room,
		"haze": _haze_slider.value,
		"work_light": _worklight_check.button_pressed,
		"shadows": _shadow_check.button_pressed,
		"cam": [_cam_target.x, _cam_target.y, _cam_target.z, _cam_yaw, _cam_pitch, _cam_dist],
		"views": _cam_views.duplicate(true),
		"trusses": trusses,
		"props": props,
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
	if d.has("shadows"):
		_shadow_check.button_pressed = bool(d["shadows"])
		_set_shadows(_shadow_check.button_pressed)

	var views = d.get("views", null)
	if views is Array and not views.is_empty():
		_cam_views = views.duplicate(true)
		_refresh_view_option()
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
	for p in _prop_root.get_children():
		p.queue_free()
	for pd in d.get("props", []):
		if pd is Dictionary and FileAccess.file_exists(String(pd.get("path", ""))):
			var pp: Array = pd.get("pos", [0, 0, 0])
			_spawn_prop(String(pd["path"]), Vector3(pp[0], pp[1], pp[2]),
				float(pd.get("scale", 1.0)), float(pd.get("rot_y", 0.0)))
