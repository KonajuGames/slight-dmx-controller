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
	for p in dimmer_nodes:
		if p.x >= v.x and p.x <= v.x + v.y:
			draw_circle(Vector2(_t2x(p.x), _level_y(r, p.y)), _NODE_RADIUS, _LINE)


## The plate beside a track (in the timeline's right-hand column): a
## filled rectangle as tall as the track, with its target's name written
## vertically, reading bottom to top.
class NamePlate:
	extends Control

	const FILL := Color(0.20, 0.20, 0.24)
	const BORDER := Color(0, 0, 0, 0.6)
	const TEXT := Color(0.85, 0.85, 0.9)
	const FONT_SIZE := 12

	var track: TimelineTrack:
		set(v):
			track = v
			queue_redraw()

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func title() -> String:
		return track.title if track != null else ""

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), FILL)
		draw_rect(Rect2(Vector2.ZERO, size), BORDER, false, 1.0)
		var text := title()
		if text == "":
			return
		var font := get_theme_default_font()
		var sw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE)
		# Rotate a quarter turn anticlockwise about the plate's centre, then
		# centre the text on it (its length runs up the plate). Trimmed to
		# the plate's height if it's longer.
		draw_set_transform(size * 0.5, -PI * 0.5)
		var room := maxf(size.y - 8.0, 0.0)
		var w := minf(sw.x, room)
		var ascent := font.get_ascent(FONT_SIZE)
		var descent := font.get_descent(FONT_SIZE)
		draw_string(font, Vector2(-w * 0.5, (ascent - descent) * 0.5), text,
			HORIZONTAL_ALIGNMENT_LEFT, room, FONT_SIZE, TEXT)
		draw_set_transform(Vector2.ZERO)
