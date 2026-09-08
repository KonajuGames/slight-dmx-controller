class_name XYPad
extends Control
## A pan / tilt trackpad. Drag the puck to set two values at once: pan on
## the horizontal axis, tilt on the vertical (up = higher value). Values
## are normalised 0..1; the caller maps them to the fixture's channels.
## `changed(x, y)` fires while dragging; `set_value_silent` moves the puck
## without signalling.

signal changed(x: float, y: float)

var value := Vector2(0.5, 0.5)          ## 0..1, y is bottom-up
var _drag := false

const _KNOB := 6.0


func _ready() -> void:
	custom_minimum_size = Vector2(116, 116)
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(false)


## Move the puck without emitting `changed` (for Home / Load to Patch).
func set_value_silent(v: Vector2) -> void:
	value = v.clamp(Vector2.ZERO, Vector2.ONE)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_drag = true
			set_process(true)
			_apply_pos(event.position)
		else:
			_drag = false
			set_process(false)


## While dragging, follow the mouse even when it leaves the control.
func _process(_delta: float) -> void:
	if not _drag:
		set_process(false)
		return
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_drag = false
		set_process(false)
		return
	_apply_pos(get_local_mouse_position())


func _apply_pos(p: Vector2) -> void:
	var nx := clampf(p.x / maxf(size.x, 1.0), 0.0, 1.0)
	var ny := clampf(1.0 - p.y / maxf(size.y, 1.0), 0.0, 1.0)
	value = Vector2(nx, ny)
	queue_redraw()
	changed.emit(nx, ny)


func _draw() -> void:
	var w := size.x
	var h := size.y

	draw_rect(Rect2(0, 0, w, h), Color(0.09, 0.10, 0.13))
	var grid := Color(1, 1, 1, 0.06)
	for i in range(1, 4):
		draw_line(Vector2(w * i / 4.0, 0), Vector2(w * i / 4.0, h), grid, 1.0)
		draw_line(Vector2(0, h * i / 4.0), Vector2(w, h * i / 4.0), grid, 1.0)
	draw_line(Vector2(w / 2.0, 0), Vector2(w / 2.0, h), Color(1, 1, 1, 0.13), 1.0)
	draw_line(Vector2(0, h / 2.0), Vector2(w, h / 2.0), Color(1, 1, 1, 0.13), 1.0)
	draw_rect(Rect2(0, 0, w, h), Color(1, 1, 1, 0.18), false, 1.0)

	var px := value.x * w
	var py := (1.0 - value.y) * h
	var accent := Color(0.28, 0.62, 1.0)
	draw_line(Vector2(px, 0), Vector2(px, h), Color(accent.r, accent.g, accent.b, 0.35), 1.0)
	draw_line(Vector2(0, py), Vector2(w, py), Color(accent.r, accent.g, accent.b, 0.35), 1.0)
	draw_circle(Vector2(px, py), _KNOB, accent)
	draw_arc(Vector2(px, py), _KNOB, 0.0, TAU, 20, Color.WHITE, 1.5)
