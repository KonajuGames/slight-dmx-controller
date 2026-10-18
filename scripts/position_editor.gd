class_name PositionEditor
extends HBoxContainer
## DJ Edit Mode's editor for one named position (PositionLibrary): a
## large, square pan / tilt pad filling the space, and on the right the
## position's name (editable, after its colour's triangle) over a list of
## every fixture with pan and tilt channels. Select fixtures in the list
## (Ctrl / Shift for several): their points are highlighted on the pad,
## in the position's colour, and dragging one moves them all; the other
## fixtures' points stay visible, dimmed. Clicking a dimmed point selects
## that fixture. The selected fixtures are lit full white and pointed at
## the position while they're selected and the editor's showing
## (highlight_changed: the owner does it, and puts the others back).
##
## Ctrl+C copies the selected fixtures' points (in list order); Ctrl+V
## pastes them onto the selected fixtures — in this position or another:
## the selected fixtures, in list order, take the copied points in turn,
## starting again from the first when there are more of them than points
## (so one copied point goes to every selected fixture). Not while the
## name field's being edited (it copies / pastes text).

## The fixtures to light up to find them: the selected ones while the
## editor's showing, else none.
signal highlight_changed(uids: Array)

const SIDE_WIDTH := 260.0

var library: PositionLibrary:
	set(v):
		if library != null and library.changed.is_connected(_on_library_changed):
			library.changed.disconnect(_on_library_changed)
		library = v
		if library != null:
			library.changed.connect(_on_library_changed)
## Returns the patched fixtures: [{uid, name, profile, mode}]; only those
## with both PAN and TILT channels are listed.
var fixtures_provider := Callable()

var position_id := ""
var _pad: PositionPad
var _name: LineEdit
var _icon: TextureRect
var _list: ItemList
var _none: Label
## The copied points, in list order (shared by every editor, so they
## paste into any position).
static var _clip: Array = []


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 12)

	var square := AspectRatioContainer.new()
	square.ratio = 1.0
	square.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	square.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(square)
	_pad = PositionPad.new()
	_pad.editor = self
	square.add_child(_pad)

	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(SIDE_WIDTH, 0)
	side.add_theme_constant_override("separation", 6)
	add_child(side)
	var head := HBoxContainer.new()
	side.add_child(head)
	_icon = TextureRect.new()
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_icon.custom_minimum_size = Vector2(16, 0)
	head.add_child(_icon)
	_name = LineEdit.new()
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name.placeholder_text = "Position name"
	_name.text_submitted.connect(func(_t: String): _commit_name())
	_name.focus_exited.connect(_commit_name)
	head.add_child(_name)
	var l := Label.new()
	l.text = "Fixtures with pan / tilt"
	l.modulate = Color(1, 1, 1, 0.6)
	side.add_child(l)
	_list = ItemList.new()
	_list.select_mode = ItemList.SELECT_MULTI
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.multi_selected.connect(func(_i: int, _sel: bool): _selection_changed())
	_list.item_selected.connect(func(_i: int): _selection_changed())
	visibility_changed.connect(_selection_changed)
	side.add_child(_list)
	_none = Label.new()
	_none.text = "No patched fixture has pan and tilt channels."
	_none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_none.modulate = Color(1, 1, 1, 0.5)
	side.add_child(_none)


## Show position `id` for editing.
func open(id: String) -> void:
	position_id = id
	refresh_fixtures()
	_show_header()
	_pad.queue_redraw()


## The pan / tilt fixtures, listed again (keeping the selection).
func refresh_fixtures() -> void:
	if _list == null:
		return
	var keep := selected_uids()
	_list.clear()
	for fx in moving_fixtures():
		var i := _list.add_item(String(fx["name"]))
		_list.set_item_metadata(i, String(fx["uid"]))
		if String(fx["uid"]) in keep:
			_list.select(i, false)
	_none.visible = _list.item_count == 0
	_selection_changed()


## The patched fixtures with both pan and tilt: [{uid, name}].
func moving_fixtures() -> Array:
	var out: Array = []
	var all: Array = fixtures_provider.call() if fixtures_provider.is_valid() else []
	for fx in all:
		var roles := {}
		for ch in (fx["profile"] as FixtureProfile).channels_for_mode(int(fx.get("mode", 0))):
			roles[String(ch["role"])] = true
		if roles.has("PAN") and roles.has("TILT"):
			out.append({"uid": String(fx["uid"]), "name": String(fx["name"])})
	return out


## The selected fixtures' uids.
func selected_uids() -> Array:
	var out: Array = []
	if _list != null:
		for i in _list.get_selected_items():
			out.append(String(_list.get_item_metadata(i)))
	return out


## Select just these fixtures in the list.
func select_uids(uids: Array) -> void:
	_list.deselect_all()
	for i in range(_list.item_count):
		if String(_list.get_item_metadata(i)) in uids:
			_list.select(i, false)
	_selection_changed()


## The position's name field and pad (for the browser / tests).
func name_edit() -> LineEdit:
	return _name


func pad() -> PositionPad:
	return _pad


## The fixtures lit up now (the selected ones while the editor's showing).
func highlighted_uids() -> Array:
	return selected_uids() if is_visible_in_tree() else []


## Copy the selected fixtures' points. Returns whether there were any.
func copy_points() -> bool:
	if library == null or position_id == "" or library.find(position_id).is_empty():
		return false
	var pts: Array = []
	for uid in selected_uids():
		pts.append(library.point(position_id, uid))
	if pts.is_empty():
		return false
	_clip = pts
	return true


## Paste the copied points onto the selected fixtures (see the top).
## Returns whether anything was pasted.
func paste_points() -> bool:
	if library == null or position_id == "" or library.find(position_id).is_empty() or _clip.is_empty():
		return false
	var targets := selected_uids()
	for i in range(targets.size()):
		library.set_point(position_id, targets[i], _clip[i % _clip.size()])
	return not targets.is_empty()


## Whether there are copied points to paste.
static func has_copied_points() -> bool:
	return not _clip.is_empty()


func _unhandled_key_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or _name.has_focus():
		return
	if event is InputEventKey and event.pressed and not event.echo and event.is_command_or_control_pressed() 			and not event.shift_pressed and not event.alt_pressed and event.keycode in [KEY_C, KEY_V]:
		if event.keycode == KEY_C:
			copy_points()
		else:
			paste_points()
		get_viewport().set_input_as_handled()


func _selection_changed() -> void:
	if _pad != null:
		_pad.queue_redraw()
	highlight_changed.emit(highlighted_uids())


func _exit_tree() -> void:
	highlight_changed.emit([])


func _show_header() -> void:
	var p := library.find(position_id) if library != null else {}
	if p.is_empty():
		_name.text = ""
		_icon.texture = null
		return
	if not _name.has_focus():
		_name.text = p["name"]
	_icon.texture = triangle_icon(p["colour"])


func _commit_name() -> void:
	if library != null and position_id != "":
		library.rename(position_id, _name.text)
		_name.text = library.find(position_id).get("name", _name.text)


func _on_library_changed() -> void:
	if position_id != "" and _name != null:
		_show_header()
		_pad.queue_redraw()


static var _icons := {}         # "colour/size" -> its triangle


## A small right-facing triangle in `colour`: a position's icon (made once
## per colour).
static func triangle_icon(colour: Color, size_px := 14) -> Texture2D:
	var key := "%s/%d" % [colour.to_html(), size_px]
	if not _icons.has(key):
		_icons[key] = _make_triangle(colour, size_px)
	return _icons[key]


static func _make_triangle(colour: Color, size_px: int) -> Texture2D:
	var img := Image.create_empty(size_px, size_px, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var a := Vector2(size_px * 0.85, size_px * 0.5)        # the point, on the right
	var b := Vector2(size_px * 0.15, size_px * 0.12)
	var c := Vector2(size_px * 0.15, size_px * 0.88)
	for y in range(size_px):
		for x in range(size_px):
			var hit := 0
			for sy in range(4):
				for sx in range(4):
					if Geometry2D.point_is_inside_triangle(Vector2(x + (sx + 0.5) / 4.0, y + (sy + 0.5) / 4.0), a, b, c):
						hit += 1
			if hit > 0:
				img.set_pixel(x, y, Color(colour.r, colour.g, colour.b, hit / 16.0))
	return ImageTexture.create_from_image(img)


## The pad: every pan / tilt fixture's point in the position — the
## selected ones highlighted in the position's colour (with their names)
## and draggable together, the rest dimmed.
class PositionPad:
	extends Control

	const GRAB := 12.0
	const DOT := 7.0

	var editor: PositionEditor
	var _drag := false
	var _press := Vector2.ZERO
	var _orig := {}             # uid -> its point at the press

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		custom_minimum_size = Vector2(200, 200)

	## A point (0..1, tilt bottom-up) to pad coordinates, and back.
	func to_px(v: Vector2) -> Vector2:
		return Vector2(v.x * size.x, (1.0 - v.y) * size.y)

	func to_value(p: Vector2) -> Vector2:
		return Vector2(p.x / maxf(size.x, 1.0), 1.0 - p.y / maxf(size.y, 1.0))

	## The fixture whose point is nearest `p` within GRAB px — only the
	## selected ones (`selected`), or only the others.
	func point_at(p: Vector2, selected: bool) -> String:
		var lib := editor.library
		var sel := editor.selected_uids()
		var best := ""
		var best_d := GRAB
		for fx in editor.moving_fixtures():
			var uid := String(fx["uid"])
			if (uid in sel) != selected:
				continue
			var d := p.distance_to(to_px(lib.point(editor.position_id, uid)))
			if d <= best_d:
				best = uid
				best_d = d
		return best

	func _gui_input(event: InputEvent) -> void:
		if editor == null or editor.library == null or editor.position_id == "":
			return
		var lib := editor.library
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if point_at(event.position, true) != "":
					_drag = true
					_press = event.position
					_orig = {}
					for uid in editor.selected_uids():
						_orig[uid] = lib.point(editor.position_id, uid)
				else:
					var other := point_at(event.position, false)
					if other != "":
						editor.select_uids([other])
			else:
				_drag = false
			accept_event()
		elif event is InputEventMouseMotion and _drag:
			var delta := to_value(event.position) - to_value(_press)
			for uid in _orig:
				lib.set_point(editor.position_id, uid, _orig[uid] + delta)
			accept_event()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(0, 0, w, h), Color(0.09, 0.10, 0.13))
		var grid := Color(1, 1, 1, 0.06)
		for i in range(1, 8):
			draw_line(Vector2(w * i / 8.0, 0), Vector2(w * i / 8.0, h), grid, 1.0)
			draw_line(Vector2(0, h * i / 8.0), Vector2(w, h * i / 8.0), grid, 1.0)
		draw_line(Vector2(w / 2.0, 0), Vector2(w / 2.0, h), Color(1, 1, 1, 0.13), 1.0)
		draw_line(Vector2(0, h / 2.0), Vector2(w, h / 2.0), Color(1, 1, 1, 0.13), 1.0)
		draw_rect(Rect2(0, 0, w, h), Color(1, 1, 1, 0.18), false, 1.0)
		var font := get_theme_default_font()
		draw_string(font, Vector2(6, h - 6), "Pan →", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.35))
		draw_string(font, Vector2(6, 14), "Tilt ↑", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.35))
		if editor == null or editor.library == null or editor.position_id == "":
			return
		var lib := editor.library
		var pos := lib.find(editor.position_id)
		if pos.is_empty():
			return
		var accent: Color = pos["colour"]
		var sel := editor.selected_uids()
		var fixtures := editor.moving_fixtures()
		# The others first, dimmed; the selected on top.
		for pass_selected in [false, true]:
			for fx in fixtures:
				var uid := String(fx["uid"])
				if (uid in sel) != pass_selected:
					continue
				var p := to_px(lib.point(editor.position_id, uid))
				if pass_selected:
					draw_line(Vector2(p.x, 0), Vector2(p.x, h), Color(accent.r, accent.g, accent.b, 0.3), 1.0)
					draw_line(Vector2(0, p.y), Vector2(w, p.y), Color(accent.r, accent.g, accent.b, 0.3), 1.0)
					draw_circle(p, DOT, accent)
					draw_arc(p, DOT, 0.0, TAU, 20, Color.WHITE, 1.5)
					draw_string(font, p + Vector2(DOT + 4, 4), String(fx["name"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
				else:
					draw_circle(p, DOT * 0.7, Color(0.6, 0.6, 0.65, 0.35))
					draw_string(font, p + Vector2(DOT, 4), String(fx["name"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.25))
