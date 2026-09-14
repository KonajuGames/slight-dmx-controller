class_name StructureBar
extends Control
## The analysed song structure as a horizontal strip: one coloured block
## per section (Intro / Verse / Chorus / …), faint downbeat ticks, and a
## playhead. Click anywhere to seek.
##
## The structure is also editable in place, so the user can correct a
## boundary the analyser got slightly wrong:
## - Hover the border between two sections and drag with the left mouse
##   button to move it, snapped to the nearest bar. A border can't be
##   dragged past the start of its left segment or the end of its right
##   segment.
## - Right-click a segment for a menu to change its type, split it at the
##   click point (snapped to the nearest bar), or delete it — an adjacent
##   segment expands to fill the gap.
## Edits mutate `analysis.sections` in place (shared with AutoShow/
## ShowGenerator) and emit `structure_edited` so listeners can refresh.

signal seek_requested(seconds: float)
signal structure_edited()

var analysis: SongAnalysis
var song_pos := 0.0

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

var _drag_border := -1          # index i => dragging the border between sections[i]/[i+1]
var _hover_border := -1
var _popup: PopupMenu
var _popup_section_idx := -1
var _popup_click_time := 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(0, 46)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_popup = PopupMenu.new()
	add_child(_popup)
	_popup.id_pressed.connect(_on_popup_id)


func set_analysis(a: SongAnalysis) -> void:
	analysis = a
	_drag_border = -1
	_hover_border = -1
	queue_redraw()


func _dur() -> float:
	return maxf(analysis.duration, 0.001) if analysis != null else 1.0


func _draw() -> void:
	var w := size.x
	var h := size.y
	var f := ThemeDB.fallback_font

	if analysis == null or analysis.sections.is_empty():
		draw_rect(Rect2(0, 0, w, h), Color(0.12, 0.12, 0.14))
		draw_string(f, Vector2(8, h * 0.5 + 4), "analyse a song to see its structure",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.5, 0.5, 0.55))
		return

	var dur := _dur()
	for i in range(analysis.sections.size()):
		var sec: Dictionary = analysis.sections[i]
		var x0: float = float(sec["start"]) / dur * w
		var x1: float = float(sec["end"]) / dur * w
		var base: Color = LABEL_HUE.get(String(sec["label"]), Color(0.3, 0.3, 0.35))
		var col := base.lerp(base.lightened(0.35), clampf(float(sec["energy"]), 0.0, 1.0))
		draw_rect(Rect2(x0, 0, maxf(x1 - x0, 1.0), h), col)
		var border_col := Color(0, 0, 0, 0.35)
		var border_w := 1.0
		if i > 0 and (i - 1 == _drag_border or i - 1 == _hover_border):
			border_col = Color(1, 1, 1, 0.9)
			border_w = 2.0
		draw_line(Vector2(x0, 0), Vector2(x0, h), border_col, border_w)
		if x1 - x0 > 34.0:
			draw_string(f, Vector2(x0 + 4, h * 0.5 + 4), String(sec["label"]),
				HORIZONTAL_ALIGNMENT_LEFT, x1 - x0 - 6, 11, Color(1, 1, 1, 0.9))

	for db in analysis.downbeats:
		var x: float = float(db) / dur * w
		draw_line(Vector2(x, h - 5), Vector2(x, h), Color(1, 1, 1, 0.25), 1.0)

	var px: float = clampf(song_pos / dur, 0.0, 1.0) * w
	draw_line(Vector2(px, 0), Vector2(px, h), Color(1, 1, 1, 0.9), 2.0)


func _get_cursor_shape(pos: Vector2 = Vector2()) -> Control.CursorShape:
	if analysis != null and (_drag_border != -1 or _border_at(pos) != -1):
		return Control.CURSOR_HSIZE
	return Control.CURSOR_ARROW


func _gui_input(event: InputEvent) -> void:
	if analysis == null:
		return

	if event is InputEventMouseMotion:
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
			var b := _border_at(event.position)
			if b != -1:
				_drag_border = b
			else:
				seek_requested.emit(clampf(event.position.x / size.x, 0.0, 1.0) * _dur())
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			var idx := analysis.section_at(clampf(event.position.x / size.x, 0.0, 1.0) * _dur())
			if idx != -1:
				_open_context_menu(idx, event.position)
	elif event is InputEventMouseButton and not event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT and _drag_border != -1:
			_drag_border = -1
			queue_redraw()
			structure_edited.emit()


# ------------------------------------------------------------- DRAG BORDER --

func _border_at(pos: Vector2) -> int:
	if analysis == null or size.x <= 0.0:
		return -1
	var dur := _dur()
	var w := size.x
	for i in range(analysis.sections.size() - 1):
		var x: float = float(analysis.sections[i]["end"]) / dur * w
		if absf(pos.x - x) <= _BORDER_HIT_PX:
			return i
	return -1


func _update_drag(mouse_x: float) -> void:
	var secs := analysis.sections
	var i := _drag_border
	var dur := _dur()
	var w := size.x
	if w <= 0.0:
		return
	var lo: float = float(secs[i]["start"])
	var hi: float = float(secs[i + 1]["end"])
	var raw_t: float = clampf(mouse_x / w, 0.0, 1.0) * dur
	var t: float = clampf(_snap_to_bar(clampf(raw_t, lo, hi)), lo, hi)
	secs[i]["end"] = t
	secs[i + 1]["start"] = t
	queue_redraw()


## Nearest bar line (`analysis.downbeats`), not the finer beat grid — a
## section boundary almost always falls on a bar, and snapping to bars
## keeps a stray beat-level nudge from landing one beat off. Falls back to
## unsnapped when downbeats aren't available (e.g. a very short song).
func _snap_to_bar(t: float) -> float:
	if analysis == null or analysis.downbeats.is_empty():
		return t
	var best: float = analysis.downbeats[0]
	var best_d := absf(t - best)
	for bt in analysis.downbeats:
		var d := absf(t - bt)
		if d < best_d:
			best_d = d
			best = bt
	return best


# ---------------------------------------------------------- CONTEXT MENU --

func _open_context_menu(idx: int, at_pos: Vector2) -> void:
	var secs := analysis.sections
	_popup_section_idx = idx
	_popup_click_time = clampf(at_pos.x / size.x, 0.0, 1.0) * _dur()

	_popup.clear()
	var cur := String(secs[idx]["label"])
	for i in range(LABELS.size()):
		_popup.add_radio_check_item(LABELS[i], i)
		_popup.set_item_checked(i, LABELS[i] == cur)
	_popup.add_separator()
	_popup.add_item("Split Here", _ID_SPLIT)
	_popup.add_item("Delete Segment", _ID_DELETE)

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
	var t := _snap_to_bar(clampf(at_time, float(seg["start"]), float(seg["end"])))
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
