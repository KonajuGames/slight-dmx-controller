class_name TimelineTrack
extends Control
## One lighting timeline in the Music Library's track timeline: the
## master (affects every fixture), one fixture, or one head of a fixture.
## It's a stack of rows, one per kind of thing its target supports, from
## the bottom up:
##   Position — 10 px, for moving heads (pan / tilt)
##   Strobe   — 10 px
##   Cues     — 10 px
##   Colour   — 10 px
##   Dimmer   — 80 px: a node line for the intensity, filled underneath
##              with white fading from transparent at the bottom of the
##              row to 50 % at its top
## The master has every row; a fixture or head only those its channels
## support (rows_for_roles()). Rows follow `wave`'s zoom, so they line up
## with the waveform and everything else in the timeline.
##
## Editing the dimmer line with the mouse:
##   drag a node            move it (in time between its neighbours, and
##                          level); with Shift held, only along the axis
##                          the pointer has moved furthest on
##   drag the line          move that stretch of it (the nodes either side)
##                          up or down
##   Ctrl + left-click line add a node there
##   Ctrl + right-click     remove the node under the pointer
## A left-button drag anywhere else selects an area (select_drag: the
## track's owner — MusicTimeline — keeps the TimelineSelection, which can
## span rows of several tracks; this track draws its rows' part of it).

## Emitted when the user changes the dimmer nodes (after each add / remove,
## and when a drag ends).
signal dimmer_edited
## A left-button drag on no node / line: `phase` SELECT_PRESS, _MOVE or
## _RELEASE, at `global_pos`, with the Ctrl / Shift keys as held at the
## press.
signal select_drag(track: TimelineTrack, phase: int, global_pos: Vector2, ctrl: bool, shift: bool)
enum { SELECT_PRESS, SELECT_MOVE, SELECT_RELEASE }

## The kinds of row (stacked bottom to top in this order: ROW_ORDER).
enum Row { POSITION, STROBE, CUES, COLOUR, DIMMER }
enum Target { MASTER, FIXTURE, HEAD }

## Bottom to top.
const ROW_ORDER := [Row.POSITION, Row.STROBE, Row.CUES, Row.COLOUR, Row.DIMMER]
const ROW_NAMES := {Row.POSITION: "Position", Row.STROBE: "Strobe", Row.CUES: "Cues",
	Row.COLOUR: "Colour", Row.DIMMER: "Dimmer"}
const ROW_HEIGHT := 10.0
const DIMMER_HEIGHT := 80.0

const _BG := [Color(0.10, 0.10, 0.12), Color(0.12, 0.12, 0.14)]
const _SEPARATOR := Color(0, 0, 0, 0.6)
const _LABEL := Color(1, 1, 1, 0.28)
const _LINE := Color(1, 1, 1, 0.9)
const _FILL_TOP_ALPHA := 0.5
const _NODE_RADIUS := 3.0
const _SELECT_FILL := Color(0.35, 0.6, 1.0, 0.28)
const _SELECT_EDGE := Color(0.55, 0.78, 1.0, 0.9)
const _NODE_HOVER_RADIUS := 4.5
## How close (px) the pointer must be to grab a node or hit the line.
const _GRAB := 6.0
## Keeps the dimmer line's 0 % and 100 % off the row's very edges.
const _DIMMER_PAD := 4.0

var target := Target.MASTER
var title := "Master"
## Present rows, in ROW_ORDER (bottom to top).
var rows: Array = ROW_ORDER.duplicate():
	set(v):
		rows = []
		for r in ROW_ORDER:
			if r in v:
				rows.append(r)
		_fit_height()
		queue_redraw()
## The dimmer's node line: (seconds, level 0..1), in time order. No nodes
## = a flat 100 %; before the first node / after the last it holds level.
var dimmer_nodes := PackedVector2Array():
	set(v):
		dimmer_nodes = v
		queue_redraw()
## Supplies the view (zoom / scroll) — the timeline's zoomable waveform.
var wave: WaveHeatmap
## Whether the mouse can edit the dimmer nodes.
var editable := true
## The selected areas this track draws its rows' part of (and its key in
## them: meta "key"). Null = none.
var selection: TimelineSelection:
	set(v):
		if selection != null and selection.changed.is_connected(queue_redraw):
			selection.changed.disconnect(queue_redraw)
		selection = v
		if selection != null:
			selection.changed.connect(queue_redraw)
		queue_redraw()
var _selecting := false

var _hover := -1      # node index under the pointer, or -1
var _drag := -1       # node index being dragged, or -1
## Node indices moved by a line drag (empty when not dragging the line).
var _drag_line := PackedInt32Array()
var _line_t := 0.0                         # where on the line it was grabbed
var _press := Vector2.ZERO                 # pointer position at the press
var _orig := PackedVector2Array()          # the nodes at the press


## The rows a fixture (or head) with these channel roles gets: Position for
## pan / tilt, Strobe for a strobe / shutter channel, Colour for any colour
## channel or wheel, Dimmer for a dimmer channel — or for colour / white
## channels without one, which the fixture's virtual dimmer scales; Cues
## always.
static func rows_for_roles(roles: Array) -> Array:
	var out := []
	if "PAN" in roles or "TILT" in roles:
		out.append(Row.POSITION)
	if "STROBE" in roles:
		out.append(Row.STROBE)
	out.append(Row.CUES)
	for r in ["RED", "GREEN", "BLUE", "WHITE", "AMBER", "UV", "COLOR_WHEEL"]:
		if r in roles:
			out.append(Row.COLOUR)
			break
	var dimmable := "DIMMER" in roles
	for r in FixtureProfile.VIRTUAL_DIMMER_ROLES:
		dimmable = dimmable or r in roles
	if dimmable:
		out.append(Row.DIMMER)
	return out


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	_fit_height()


func has_row(r: Row) -> bool:
	return r in rows


func row_height(r: Row) -> float:
	return DIMMER_HEIGHT if r == Row.DIMMER else ROW_HEIGHT


## A row's rectangle within the track (empty if the track hasn't got it).
func row_rect(r: Row) -> Rect2:
	if not has_row(r):
		return Rect2()
	var y := size.y
	for row in rows:                # bottom to top
		var h := row_height(row)
		y -= h
		if row == r:
			return Rect2(0.0, y, size.x, h)
	return Rect2()


func _fit_height() -> void:
	var h := 0.0
	for r in rows:
		h += row_height(r)
	custom_minimum_size = Vector2(custom_minimum_size.x, h)


## The dimmer level at `t` seconds (linear between nodes).
func dimmer_at(t: float) -> float:
	var n := dimmer_nodes.size()
	if n == 0:
		return 1.0
	if t <= dimmer_nodes[0].x:
		return dimmer_nodes[0].y
	for i in range(1, n):
		if t <= dimmer_nodes[i].x:
			var a := dimmer_nodes[i - 1]
			var b := dimmer_nodes[i]
			return lerpf(a.y, b.y, (t - a.x) / maxf(b.x - a.x, 1e-6))
	return dimmer_nodes[n - 1].y


## The index of the dimmer node within _GRAB px of `pos` (the nearest), or -1.
func node_at(pos: Vector2) -> int:
	var r := row_rect(Row.DIMMER)
	if r.size.y <= 0.0:
		return -1
	var best := -1
	var best_d := _GRAB
	for i in range(dimmer_nodes.size()):
		var p := dimmer_nodes[i]
		var d := pos.distance_to(Vector2(_t2x(p.x), _level_y(r, p.y)))
		if d <= best_d:
			best = i
			best_d = d
	return best


## Whether `pos` is on the dimmer line (within _GRAB px of it vertically,
## inside the dimmer row).
func on_line(pos: Vector2) -> bool:
	var r := row_rect(Row.DIMMER)
	if r.size.y <= 0.0 or not r.has_point(pos):
		return false
	return absf(pos.y - _level_y(r, dimmer_at(_x2t(pos.x)))) <= _GRAB


## Add a node on the line at x = `pos.x` (its level is the line's there),
## keeping time order. Returns its index.
func add_node_at(pos: Vector2) -> int:
	var t := _clamp_time(_x2t(pos.x))
	var level := dimmer_at(t)
	var i := 0
	while i < dimmer_nodes.size() and dimmer_nodes[i].x < t:
		i += 1
	var nodes := dimmer_nodes
	nodes.insert(i, Vector2(t, level))
	dimmer_nodes = nodes
	return i


func remove_node(i: int) -> void:
	if i < 0 or i >= dimmer_nodes.size():
		return
	var nodes := dimmer_nodes
	nodes.remove_at(i)
	dimmer_nodes = nodes


## Move node `i` to the track position `pos`: its time stays between its
## neighbours' (and within the song), its level within 0..1.
func move_node(i: int, pos: Vector2) -> void:
	if i < 0 or i >= dimmer_nodes.size():
		return
	var r := row_rect(Row.DIMMER)
	var t := _clamp_time(_x2t(pos.x))
	if i > 0:
		t = maxf(t, dimmer_nodes[i - 1].x)
	if i < dimmer_nodes.size() - 1:
		t = minf(t, dimmer_nodes[i + 1].x)
	var span := maxf(r.size.y - 2.0 * _DIMMER_PAD, 1.0)
	var level := clampf((r.end.y - _DIMMER_PAD - pos.y) / span, 0.0, 1.0)
	var nodes := dimmer_nodes
	nodes[i] = Vector2(t, level)
	dimmer_nodes = nodes


func _clamp_time(t: float) -> float:
	var end := wave.duration() if wave != null and wave.analysis != null else INF
	return clampf(t, 0.0, end)


## Move the stretch of line through time `t` by `dy` px (down is
## positive) from the levels in `from`: the nodes either side of it, or
## the end node it holds level from. All of them move by the same amount,
## limited so none leaves 0..1. With no nodes (a flat 100 %), one is made
## at 0 s to carry the level. Returns the indices moved.
func move_line(t: float, dy: float, from: PackedVector2Array) -> PackedInt32Array:
	var nodes := from.duplicate()
	if nodes.is_empty():
		if dy == 0.0:
			return PackedInt32Array([0])
		nodes.append(Vector2(0.0, 1.0))
	var n := nodes.size()
	var i := 0
	while i < n and nodes[i].x <= t:
		i += 1
	var idx := PackedInt32Array()
	if i == 0:
		idx.append(0)
	elif i == n:
		idx.append(n - 1)
	else:
		idx.append(i - 1)
		idx.append(i)
	var r := row_rect(Row.DIMMER)
	var d := -dy / maxf(r.size.y - 2.0 * _DIMMER_PAD, 1.0)
	var lo := 1.0
	var hi := 0.0
	for k in idx:
		lo = minf(lo, nodes[k].y)
		hi = maxf(hi, nodes[k].y)
	d = clampf(d, -lo, 1.0 - hi)
	for k in idx:
		nodes[k].y += d
	dimmer_nodes = nodes
	return idx


## The row at `pos` (track coordinates), or -1.
func row_at(pos: Vector2) -> int:
	for r in rows:
		if row_rect(r).has_point(pos):
			return r
	return -1


func _gui_input(event: InputEvent) -> void:
	# An area selection under way: follow it to the release.
	if _selecting:
		if event is InputEventMouseMotion:
			select_drag.emit(self, SELECT_MOVE, get_global_transform() * event.position, false, false)
			accept_event()
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_selecting = false
			select_drag.emit(self, SELECT_RELEASE, get_global_transform() * event.position, false, false)
			accept_event()
		return
	var dimmer_editing := editable and has_row(Row.DIMMER)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var at: Vector2 = event.position
		var special := dimmer_editing and (node_at(at) >= 0 or on_line(at))
		if not special and row_at(at) >= 0:
			# Empty timeline: start selecting an area.
			_selecting = true
			select_drag.emit(self, SELECT_PRESS, get_global_transform() * at, event.ctrl_pressed, event.shift_pressed)
			accept_event()
			return
	if not dimmer_editing:
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _drag >= 0:
			_drag_node(mm.position, mm.shift_pressed)
			accept_event()
			return
		if not _drag_line.is_empty():
			_drag_line = move_line(_line_t, mm.position.y - _press.y, _orig)
			accept_event()
			return
		_set_hover(node_at(mm.position), on_line(mm.position))
		return
	if not event is InputEventMouseButton:
		return
	var mb := event as InputEventMouseButton
	if mb.button_index == MOUSE_BUTTON_LEFT:
		if not mb.pressed:
			if _drag >= 0 or not _drag_line.is_empty():
				var moved := dimmer_nodes != _orig
				_drag = -1
				_drag_line = PackedInt32Array()
				if moved:
					dimmer_edited.emit()
				accept_event()
			return
		var i := node_at(mb.position)
		if i < 0 and mb.ctrl_pressed and on_line(mb.position):
			i = add_node_at(mb.position)
			dimmer_edited.emit()
		_press = mb.position
		_orig = dimmer_nodes.duplicate()
		if i >= 0:
			_drag = i
			_set_hover(i, false)
			accept_event()
		elif not mb.ctrl_pressed and on_line(mb.position):
			# Grabbed the line itself: drag that stretch of it up / down.
			_line_t = _x2t(mb.position.x)
			_drag_line = PackedInt32Array([-1])      # non-empty: dragging
			accept_event()
	elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and mb.ctrl_pressed:
		var i := node_at(mb.position)
		if i >= 0:
			_drag = -1
			_drag_line = PackedInt32Array()
			remove_node(i)
			_set_hover(node_at(mb.position), on_line(mb.position))
			dimmer_edited.emit()
			accept_event()


## Drag node `_drag` by the pointer's movement since the press (so it
## doesn't jump to the pointer); with `lock`, only along the axis the
## pointer has moved furthest on.
func _drag_node(pos: Vector2, lock: bool) -> void:
	var r := row_rect(Row.DIMMER)
	var o := _orig[_drag]
	var delta := pos - _press
	if lock:
		if absf(delta.x) >= absf(delta.y):
			delta.y = 0.0
		else:
			delta.x = 0.0
	move_node(_drag, Vector2(_t2x(o.x), _level_y(r, o.y)) + delta)
	if lock:
		# Hold the locked axis exactly (no pixel round trip).
		var nodes := dimmer_nodes
		if delta.y == 0.0:
			nodes[_drag].y = o.y
		if delta.x == 0.0:
			nodes[_drag].x = o.x
		dimmer_nodes = nodes


func _set_hover(i: int, line := false) -> void:
	var shape := Control.CURSOR_POINTING_HAND if i >= 0 \
		else (Control.CURSOR_VSIZE if line else Control.CURSOR_ARROW)
	mouse_default_cursor_shape = shape
	if i == _hover:
		return
	_hover = i
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _drag < 0 and _drag_line.is_empty():
		_set_hover(-1)


func _view() -> Vector2:
	if wave == null or wave.analysis == null:
		return Vector2(0.0, 1.0)
	return Vector2(wave.view_start, wave.visible_length())


func _t2x(t: float) -> float:
	var v := _view()
	return (t - v.x) / v.y * size.x


func _x2t(x: float) -> float:
	var v := _view()
	return v.x + x / maxf(size.x, 1.0) * v.y


## A dimmer level's y within the dimmer row's rectangle.
func _level_y(r: Rect2, level: float) -> float:
	return r.end.y - _DIMMER_PAD - clampf(level, 0.0, 1.0) * (r.size.y - 2.0 * _DIMMER_PAD)


## The dimmer line's points across the visible window: the window's edges
## plus every node in it, as (x, y) in the track.
func dimmer_polyline() -> PackedVector2Array:
	var out := PackedVector2Array()
	var r := row_rect(Row.DIMMER)
	if r.size.y <= 0.0:
		return out
	var v := _view()
	var t0 := v.x
	var t1 := v.x + v.y
	out.append(Vector2(0.0, _level_y(r, dimmer_at(t0))))
	for p in dimmer_nodes:
		if p.x > t0 and p.x < t1:
			out.append(Vector2(_t2x(p.x), _level_y(r, p.y)))
	out.append(Vector2(size.x, _level_y(r, dimmer_at(t1))))
	return out


func _draw() -> void:
	var font := get_theme_default_font()
	var i := 0
	for row in rows:
		var r := row_rect(row)
		draw_rect(r, _BG[i % 2])
		draw_line(Vector2(0, r.position.y), Vector2(size.x, r.position.y), _SEPARATOR, 1.0)
		i += 1
		if row == Row.DIMMER:
			_draw_dimmer(r)
		# The name, sized to fit the row (8 px in the 10 px rows), at the top
		# of the dimmer row.
		var fs := 10 if row == Row.DIMMER else 8
		var band := minf(r.size.y, 14.0)
		draw_string(font, Vector2(4.0, r.position.y + band * 0.5 + fs * 0.35),
			ROW_NAMES[row], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, _LABEL)
		_draw_selection(row, r)


## This row's selected spans: a translucent blue fill, edged at each end.
func _draw_selection(row: Row, r: Rect2) -> void:
	if selection == null or not has_meta("key"):
		return
	for span in selection.spans_for(String(get_meta("key")), row):
		if _t2x(span.y) < 0.0 or _t2x(span.x) > size.x:
			continue                    # out of view
		var x0 := clampf(_t2x(span.x), 0.0, size.x)
		var x1 := clampf(_t2x(span.y), 0.0, size.x)
		draw_rect(Rect2(x0, r.position.y, maxf(x1 - x0, 1.0), r.size.y), _SELECT_FILL)
		for t in [span.x, span.y]:
			var x := _t2x(t)
			if x >= 0.0 and x <= size.x:
				draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), _SELECT_EDGE, 1.0)


func _draw_dimmer(r: Rect2) -> void:
	var line := dimmer_polyline()
	if line.size() < 2:
		return
	# The fill: a quad under each segment, its alpha following height in
	# the row (0 at the bottom, 50 % at the top) — linear in y, so the
	# per-vertex colours interpolate it exactly.
	var bottom := r.end.y
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	for k in range(line.size() - 1):
		var a := line[k]
		var b := line[k + 1]
		var base := pts.size()
		for q in [a, b, Vector2(b.x, bottom), Vector2(a.x, bottom)]:
			pts.append(q)
			cols.append(Color(1, 1, 1, _FILL_TOP_ALPHA * clampf((bottom - q.y) / r.size.y, 0.0, 1.0)))
		for t in [0, 1, 2, 0, 2, 3]:
			idx.append(base + t)
	RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), idx, pts, cols)
	draw_polyline(line, _LINE, 1.5, true)
	# The nodes themselves (not the window-edge points).
	var v := _view()
	for i in range(dimmer_nodes.size()):
		var p := dimmer_nodes[i]
		if p.x >= v.x and p.x <= v.x + v.y:
			var hot := i == _hover or i == _drag
			draw_circle(Vector2(_t2x(p.x), _level_y(r, p.y)),
				_NODE_HOVER_RADIUS if hot else _NODE_RADIUS, _LINE)


## The plate beside a track (in the timeline's right-hand column): a
## filled rectangle as tall as the track, with its target's name written
## vertically, reading bottom to top.
class NamePlate:
	extends Control

	const FILL := Color(0.20, 0.20, 0.24)
	## A head's plate is a shade darker than its fixture's.
	const HEAD_FILL := Color(0.15, 0.15, 0.18)
	const BORDER := Color(0, 0, 0, 0.6)
	const TEXT := Color(0.85, 0.85, 0.9)
	const FONT_SIZE := 12
	## Shrinks to this to fit a long name before trimming it.
	const MIN_FONT_SIZE := 9

	var track: TimelineTrack:
		set(v):
			track = v
			queue_redraw()

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func title() -> String:
		return track.title if track != null else ""

	## The name's lines (a title can hold "\n" breaks).
	func lines() -> PackedStringArray:
		return title().split("\n", false)

	## The font size the name's drawn at: FONT_SIZE, or the largest down
	## to MIN_FONT_SIZE at which its longest line fits the plate's height.
	func font_size() -> int:
		var font := get_theme_default_font()
		var room := maxf(size.y - 8.0, 0.0)
		var fs := FONT_SIZE
		while fs > MIN_FONT_SIZE and _longest(font, fs) > room:
			fs -= 1
		return fs

	func _longest(font: Font, fs: int) -> float:
		var w := 0.0
		for line in lines():
			w = maxf(w, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
		return w

	func _draw() -> void:
		var head := track != null and track.target == TimelineTrack.Target.HEAD
		draw_rect(Rect2(Vector2.ZERO, size), HEAD_FILL if head else FILL)
		draw_rect(Rect2(Vector2.ZERO, size), BORDER, false, 1.0)
		var text := lines()
		if text.is_empty():
			return
		var font := get_theme_default_font()
		# Rotate a quarter turn anticlockwise about the plate's centre, then
		# centre the text on it (its length runs up the plate; each further
		# line sits to the right of the one before). A smaller font if that
		# makes it fit the plate's height, else trimmed.
		var room := maxf(size.y - 8.0, 0.0)
		var fs := font_size()
		var line_h := font.get_height(fs)
		var y := -line_h * text.size() * 0.5 + font.get_ascent(fs)
		draw_set_transform(size * 0.5, -PI * 0.5)
		for line in text:
			var w := minf(font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x, room)
			draw_string(font, Vector2(-w * 0.5, y), line, HORIZONTAL_ALIGNMENT_LEFT, room, fs, TEXT)
			y += line_h
		draw_set_transform(Vector2.ZERO)
