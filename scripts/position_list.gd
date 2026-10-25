class_name PositionList
extends ScrollContainer
## DJ Edit Mode's list of named positions (below the folders): a row per
## position — its colour's triangle and name; hovering shows an ✕ at the
## row's right to delete it, right-click for a menu. (Adding is the "+" on
## the Positions header, the owner's.) The owner does the work:
## position_picked / delete_requested / context_requested.
##
## It's styled as a standard list (ItemList, from the theme): the list's
## panel behind it, and each row its items' look — no fill until hovered,
## the hover / selected / hovered-selected boxes, their font colours, size
## and padding.

signal position_picked(id: String)
signal delete_requested(id: String)
## A right-click on a position's row, at `screen_pos`.
signal context_requested(id: String, screen_pos: Vector2)

var _box: VBoxContainer
var _group := ButtonGroup.new()
var _rows := {}                 # id -> its row Button
var _shown := ""                # what the rows show (ids, names, colours)
var _styling := false           # applying the theme (which itself signals a theme change)


func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_box = VBoxContainer.new()
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box.add_theme_constant_override("separation", 0)
	add_child(_box)
	_apply_theme()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _box != null and not _styling:
		_apply_theme()


## Take the look of a standard list (ItemList) from the theme.
func _apply_theme() -> void:
	_styling = true
	add_theme_stylebox_override("panel", get_theme_stylebox("panel", "ItemList"))
	for id in _rows:
		_style_row(_rows[id])
	_styling = false


## A row styled as a list item: its states' boxes and font colours, the
## list's font size, padding and icon gap. Every state has the same
## padding, so nothing shifts as it's hovered / selected.
func _style_row(r: Button) -> void:
	style_as_item(r, self, 22.0)                    # room for the ✕


## Style button `r` as a list item, from `from`'s theme (`right`: extra
## padding on its right). Shared with the other lists like this one.
static func style_as_item(r: Button, from: Control, right := 0.0) -> void:
	var hs := from.get_theme_constant("h_separation", "ItemList")
	var vs := from.get_theme_constant("v_separation", "ItemList")
	var pad := func(sb: StyleBox) -> StyleBox:
		var out: StyleBox = sb.duplicate() if sb != null else StyleBoxEmpty.new()
		out.content_margin_left = hs
		out.content_margin_right = hs + right
		out.content_margin_top = vs * 0.5
		out.content_margin_bottom = vs * 0.5
		return out
	var none: StyleBox = pad.call(StyleBoxEmpty.new())
	r.add_theme_stylebox_override("normal", none)
	r.add_theme_stylebox_override("disabled", none)
	r.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	r.add_theme_stylebox_override("hover", pad.call(from.get_theme_stylebox("hovered", "ItemList")))
	r.add_theme_stylebox_override("pressed", pad.call(from.get_theme_stylebox("selected", "ItemList")))
	r.add_theme_stylebox_override("hover_pressed", pad.call(from.get_theme_stylebox("hovered_selected", "ItemList")))
	var normal := from.get_theme_color("font_color", "ItemList")
	r.add_theme_color_override("font_color", normal)
	r.add_theme_color_override("font_focus_color", normal)
	r.add_theme_color_override("font_hover_color", from.get_theme_color("font_hovered_color", "ItemList"))
	r.add_theme_color_override("font_pressed_color", from.get_theme_color("font_selected_color", "ItemList"))
	r.add_theme_color_override("font_hover_pressed_color", from.get_theme_color("font_hovered_selected_color", "ItemList"))
	r.add_theme_font_size_override("font_size", from.get_theme_font_size("font_size", "ItemList"))
	r.add_theme_font_override("font", from.get_theme_font("font", "ItemList"))
	r.add_theme_constant_override("h_separation", from.get_theme_constant("icon_margin", "ItemList"))


## Show `library`'s positions, `selected_id` selected ("" for none).
func refresh(library: PositionLibrary, selected_id := "") -> void:
	if _box == null:
		return
	var sig := ""
	if library != null:
		for pos in library.positions:
			sig += "%s|%s|%s;" % [pos["id"], pos["name"], (pos["colour"] as Color).to_html()]
	if sig == _shown:
		select(selected_id)             # only a point moved: nothing to rebuild
		return
	_shown = sig
	for id in _rows:
		_rows[id].queue_free()
	_rows.clear()
	if library != null:
		var i := 0
		for pos in library.positions:
			var row := _make_row(pos)
			_box.add_child(row)
			_box.move_child(row, i)
			_rows[String(pos["id"])] = row
			i += 1
	select(selected_id)


## Show `id` selected (none for "").
func select(id: String) -> void:
	for rid in _rows:
		_rows[rid].set_pressed_no_signal(rid == id)


## The ids listed, in order.
func ids() -> Array:
	var out: Array = []
	for c in _box.get_children():
		if c.has_meta("id") and not c.is_queued_for_deletion():
			out.append(String(c.get_meta("id")))
	return out


func row(id: String) -> Button:
	return _rows.get(id)


## The row's ✕ (shown while the mouse is over the row).
func delete_button(id: String) -> Button:
	var r: Button = _rows.get(id)
	return r.get_node("Delete") if r != null else null


func selected_id() -> String:
	for id in _rows:
		if _rows[id].button_pressed:
			return id
	return ""


func _make_row(pos: Dictionary) -> Button:
	var id := String(pos["id"])
	var r := Button.new()
	r.set_meta("id", id)
	r.toggle_mode = true
	r.button_group = _group
	r.alignment = HORIZONTAL_ALIGNMENT_LEFT
	r.text = String(pos["name"])
	r.icon = PositionEditor.triangle_icon(pos["colour"])
	r.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.focus_mode = Control.FOCUS_NONE
	r.tooltip_text = String(pos["name"])
	r.pressed.connect(func(): position_picked.emit(id))
	r.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_RIGHT and ev.pressed:
			context_requested.emit(id, r.get_screen_transform() * ev.position)
			r.accept_event())
	var x := Button.new()
	x.name = "Delete"
	x.text = "✕"
	x.flat = true
	x.focus_mode = Control.FOCUS_NONE
	x.tooltip_text = "Delete this position"
	x.visible = false
	x.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	x.offset_left = -24
	x.pressed.connect(func(): delete_requested.emit(id))
	r.add_child(x)
	_style_row(r)
	# Hovering the row or its ✕ shows the ✕. Moving onto the ✕ counts as
	# leaving the row (then entering the ✕), so whether to show it is
	# settled once both have been heard: deferred.
	var over := {"row": false, "x": false}
	var settle := func():
		if is_instance_valid(x):
			x.visible = over["row"] or over["x"]
	r.mouse_entered.connect(func():
		over["row"] = true
		settle.call_deferred())
	r.mouse_exited.connect(func():
		over["row"] = false
		settle.call_deferred())
	x.mouse_entered.connect(func():
		over["x"] = true
		settle.call_deferred())
	x.mouse_exited.connect(func():
		over["x"] = false
		settle.call_deferred())
	return r
