class_name StructureBar
extends Control
## The analysed song structure as a horizontal strip: one coloured block
## per section (Intro / Verse / Chorus / …), faint downbeat ticks, and a
## playhead. Click anywhere to seek.
##
## The structure is also editable in place, so the user can correct a
## boundary the analyser got slightly wrong:
## - Hover the border between two sections and drag with the left mouse
##   button to move it, snapped to the nearest bar (or beat, or not at all:
##   right-click > Snapping, which also covers Split Here). A border can't be
##   dragged past the start of its left segment or the end of its right
##   segment; dropped there, the segment it closed up is deleted.
## - Right-click a segment for a menu to change its type, split it at the
##   click point (snapped to the nearest bar), or delete it — an adjacent
##   segment expands to fill the gap.
## Edits mutate `analysis.sections` in place (shared with the timeline's
## Generate) and emit `structure_edited` so listeners can refresh.
##
## `editable` = false locks that editing (clicks just seek). It can also
## show only part of the song — `view_start` / `view_len` seconds, set by
## whoever owns the zoom (the DJ Edit Mode timeline follows its
## waveform); by default it shows the whole song.

signal seek_requested(seconds: float)
signal structure_edited()

var analysis: SongAnalysis
var song_pos := 0.0
var show_cursor := true
var cursor_color := Color(1, 1, 1, 0.9)
## Border dragging and the right-click menu; off = locked (clicks seek).
var editable := true:
	set(v):
		editable = v
		_drag_border = -1
		_hover_border = -1
		queue_redraw()
## Visible window, seconds; view_len <= 0 = the whole song.
var view_start := 0.0
var view_len := 0.0
## Shown in place of the sections when there are none (e.g. while
## analysing).
var placeholder := "analyse a song to see its structure"

## Section label -> base hue. Shared with WaveHeatmap.
const LABEL_HUE := {
	"Intro": Color(0.20, 0.35, 0.75), "Verse": Color(0.20, 0.55, 0.55),
	"Chorus": Color(0.85, 0.45, 0.15), "Bridge": Color(0.55, 0.25, 0.70),
	"Build": Color(0.55, 0.55, 0.58), "Drop": Color(0.80, 0.20, 0.20),
	"Outro": Color(0.22, 0.28, 0.55),
}
## Same keys as LABEL_HUE, in a fixed order for the right-click menu.
const LABELS := ["Intro", "Verse", "Chorus", "Bridge", "Build", "Drop", "Outro"]

const _BORDER_HIT_PX := 6.0
const _ID_SPLIT := 1000
const _ID_DELETE := 1001

## What a dragged border / a split snaps to (right-click > Snapping).
enum Snap { BAR, BEAT, NONE }
const SNAP_LABELS := ["Bar", "Beat", "No Snapping"]
var snap := Snap.BAR
var _snap_menu: PopupMenu

var _drag_border := -1          # index i => dragging the border between sections[i]/[i+1]
var _hover_border := -1
var _popup: PopupMenu
var _popup_section_idx := -1
var _popup_click_time := 0.0


func _ready() -> void:
	if custom_minimum_size.y <= 0.0:
		custom_minimum_size = Vector2(0, 46)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_popup = PopupMenu.new()
	add_child(_popup)
	_popup.id_pressed.connect(_on_popup_id)
	# Right-click > Snapping > Bar / Beat / No Snapping.
	_snap_menu = PopupMenu.new()
	for i in range(SNAP_LABELS.size()):
		_snap_menu.add_radio_check_item(SNAP_LABELS[i], i)
	_snap_menu.id_pressed.connect(func(id: int):
		snap = id as Snap)
	_popup.add_child(_snap_menu)


func set_analysis(a: SongAnalysis) -> void:
	analysis = a
	_drag_border = -1
	_hover_border = -1
	queue_redraw()


func _dur() -> float:
	return maxf(analysis.duration, 0.001) if analysis != null else 1.0


func set_view(start: float, length: float) -> void:
	view_start = start
	view_len = length
	queue_redraw()


func _vis_len() -> float:
	return view_len if view_len > 0.0 else _dur()


func _t2x(t: float) -> float:
	return (t - view_start) / _vis_len() * size.x


func _x2t(x: float) -> float:
	return clampf(view_start + x / maxf(size.x, 1.0) * _vis_len(), 0.0, _dur())


func _draw() -> void:
	var w := size.x
	var h := size.y
	var f := ThemeDB.fallback_font

	if analysis == null or analysis.sections.is_empty():
		draw_rect(Rect2(0, 0, w, h), Color(0.12, 0.12, 0.14))
		draw_string(f, Vector2(8, h * 0.5 + 4), placeholder,
			HORIZONTAL_ALIGNMENT_LEFT, -1, mini(12, int(h) - 6), Color(0.5, 0.5, 0.55))
		return

	for i in range(analysis.sections.size()):
		var sec: Dictionary = analysis.sections[i]
		var x0: float = _t2x(float(sec["start"]))
		var x1: float = _t2x(float(sec["end"]))
		if x1 < 0.0 or x0 > w:
			continue
		var base: Color = LABEL_HUE.get(String(sec["label"]), Color(0.3, 0.3, 0.35))
		var col := base.lerp(base.lightened(0.35), clampf(float(sec["energy"]), 0.0, 1.0))
		# Clipped to the bar: zoomed in, a section can run far past either
		# edge (and would paint over its neighbours).
		var lx := maxf(x0, 0.0)
		var rx := minf(x1, w)
		draw_rect(Rect2(lx, 0, maxf(rx - lx, 1.0), h), col)
		var border_col := Color(0, 0, 0, 0.35)
		var border_w := 1.0
		if i > 0 and (i - 1 == _drag_border or i - 1 == _hover_border):
			border_col = Color(1, 1, 1, 0.9)
			border_w = 2.0
		if x0 >= 0.0:
			draw_line(Vector2(x0, 0), Vector2(x0, h), border_col, border_w)
		if rx - lx > 34.0:
			draw_string(f, Vector2(lx + 4, h * 0.5 + 4), String(sec["label"]),
				HORIZONTAL_ALIGNMENT_LEFT, rx - lx - 6, 11, Color(1, 1, 1, 0.9))

	# Bar ticks along the bottom, unless they'd crowd together.
	var bar_px := 0.0
	if analysis.downbeats.size() > 1:
		bar_px = (analysis.downbeats[1] - analysis.downbeats[0]) / _vis_len() * w
	if bar_px >= 4.0:
		for db in analysis.downbeats:
			var x := _t2x(float(db))
			if x >= 0.0 and x <= w:
				draw_line(Vector2(x, h - 5), Vector2(x, h), Color(1, 1, 1, 0.25), 1.0)

	if show_cursor:
		var px := _t2x(song_pos)
		if px >= 0.0 and px <= w:
			draw_line(Vector2(px, 0), Vector2(px, h), cursor_color, 2.0)


func _get_cursor_shape(pos: Vector2 = Vector2()) -> Control.CursorShape:
	if analysis != null and editable and (_drag_border != -1 or _border_at(pos) != -1):
		return Control.CURSOR_HSIZE
	return Control.CURSOR_ARROW


func _gui_input(event: InputEvent) -> void:
	if analysis == null:
		return

	if event is InputEventMouseMotion:
		if not editable:
			return
		if _drag_border != -1:
			_update_drag(event.position.x)
		else:
			var b := _border_at(event.position)
			if b != _hover_border:
				_hover_border = b
				queue_redraw()
		return

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var b := _border_at(event.position) if editable else -1
			if b != -1:
				_drag_border = b
			else:
				seek_requested.emit(_x2t(event.position.x))
		elif event.button_index == MOUSE_BUTTON_RIGHT and editable:
			var idx := analysis.section_at(_x2t(event.position.x))
			if idx != -1:
				_open_context_menu(idx, event.position)
	elif event is InputEventMouseButton and not event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT and _drag_border != -1:
			_drop_empty(_drag_border)
			_drag_border = -1
			queue_redraw()
			structure_edited.emit()


# ------------------------------------------------------------- DRAG BORDER --

func _border_at(pos: Vector2) -> int:
	if analysis == null or size.x <= 0.0:
		return -1
	for i in range(analysis.sections.size() - 1):
		var x := _t2x(float(analysis.sections[i]["end"]))
		if absf(pos.x - x) <= _BORDER_HIT_PX:
			return i
	return -1


func _update_drag(mouse_x: float) -> void:
	var secs := analysis.sections
	var i := _drag_border
	if size.x <= 0.0:
		return
	var lo: float = float(secs[i]["start"])
	var hi: float = float(secs[i + 1]["end"])
	var raw_t: float = _x2t(mouse_x)
	var t: float = clampf(_snap_time(clampf(raw_t, lo, hi)), lo, hi)
	secs[i]["end"] = t
	secs[i + 1]["start"] = t
	queue_redraw()


## A border dropped (between sections `i` and `i + 1`): either side left
## with no length is deleted — its neighbour already covers its span.
func _drop_empty(i: int) -> void:
	var secs := analysis.sections
	for k in [i + 1, i]:
		if secs.size() > 1 and float(secs[k]["end"]) - float(secs[k]["start"]) < 0.02:
			secs.remove_at(k)
			return


## Where a dragged border or a split lands, per `snap`: the nearest bar
## line (`analysis.downbeats` — the default, since a section boundary
## almost always falls on a bar and that keeps a stray nudge from landing
## a beat off), the nearest beat (`analysis.beat_times`), or exactly where
## the pointer is. Falls back to unsnapped when the grid isn't available.
func _snap_time(t: float) -> float:
	if analysis == null:
		return t
	match snap:
		Snap.BAR:
			return _nearest(analysis.downbeats, t)
		Snap.BEAT:
			return _nearest(analysis.beat_times, t)
	return t


static func _nearest(grid: PackedFloat32Array, t: float) -> float:
	if grid.is_empty():
		return t
	var i := clampi(grid.bsearch(t), 0, grid.size() - 1)
	if i > 0 and absf(grid[i - 1] - t) < absf(grid[i] - t):
		i -= 1
	return grid[i]


# ---------------------------------------------------------- CONTEXT MENU --

func _open_context_menu(idx: int, at_pos: Vector2) -> void:
	var secs := analysis.sections
	_popup_section_idx = idx
	_popup_click_time = _x2t(at_pos.x)

	_popup.clear()
	var cur := String(secs[idx]["label"])
	for i in range(LABELS.size()):
		_popup.add_radio_check_item(LABELS[i], i)
		_popup.set_item_checked(i, LABELS[i] == cur)
	_popup.add_separator()
	_popup.add_item("Split Here", _ID_SPLIT)
	_popup.add_item("Delete Segment", _ID_DELETE)
	_popup.add_separator()
	for i in range(SNAP_LABELS.size()):
		_snap_menu.set_item_checked(i, i == snap)
	_popup.add_submenu_node_item("Snapping", _snap_menu)

	var screen_pos: Vector2 = get_screen_transform() * at_pos
	_popup.popup(Rect2i(Vector2i(screen_pos), Vector2i.ZERO))


func _on_popup_id(id: int) -> void:
	if analysis == null or _popup_section_idx < 0 or _popup_section_idx >= analysis.sections.size():
		return
	if id == _ID_SPLIT:
		_split_segment(_popup_section_idx, _popup_click_time)
	elif id == _ID_DELETE:
		_delete_segment(_popup_section_idx)
	elif id >= 0 and id < LABELS.size():
		analysis.sections[_popup_section_idx]["label"] = LABELS[id]
		queue_redraw()
		structure_edited.emit()


func _split_segment(idx: int, at_time: float) -> void:
	var secs := analysis.sections
	var seg: Dictionary = secs[idx]
	var t := _snap_time(clampf(at_time, float(seg["start"]), float(seg["end"])))
	if t - float(seg["start"]) < 0.02 or float(seg["end"]) - t < 0.02:
		return  # too close to an existing edge to make two real segments
	var new_seg: Dictionary = seg.duplicate(true)
	new_seg["start"] = t
	seg["end"] = t
	secs.insert(idx + 1, new_seg)
	queue_redraw()
	structure_edited.emit()


func _delete_segment(idx: int) -> void:
	var secs := analysis.sections
	if secs.size() <= 1:
		return  # always keep at least one section
	if idx > 0:
		secs[idx - 1]["end"] = secs[idx]["end"]
	else:
		secs[idx + 1]["start"] = secs[idx]["start"]
	secs.remove_at(idx)
	queue_redraw()
	structure_edited.emit()
