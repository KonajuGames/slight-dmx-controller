class_name WaveHeatmap
extends Control
## The whole analysed song as a colour-coded waveform: bar height is the
## loudness envelope, hue is the spectral balance (bass amber, mid green,
## air blue). Section tints behind it and downbeat ticks line it up with
## the structure strip. Click anywhere to seek.
##
## It can also show just part of the song — `view_start` / `view_len`
## seconds — and, with `zoomable` set, the mouse wheel zooms in and out
## around the pointer (horizontal wheel / Shift+wheel pans). Detail comes
## from however many columns the analysis carries; a pyramid of
## progressively merged columns keeps redraws to about one column per
## pixel even for an hours-long track.

signal seek_requested(seconds: float)
## The visible window changed (zoom, pan or set_view()).
signal view_changed(start: float, length: float)

var analysis: SongAnalysis
var song_pos := 0.0
## Draw the `song_pos` playhead.
var show_cursor := true
var cursor_color := Color(1, 1, 1, 0.9)
## Fill behind the wave; transparent (the panel shows through) by default.
var background_color := Color(0, 0, 0, 0):
	set(v):
		background_color = v
		queue_redraw()

## An optional beat grid drawn over the wave (set_beat_grid()): a thin
## line per beat and a bolder one at the start of each bar, thinned out
## when zoomed too far out to tell them apart.
var grid_beats := PackedFloat32Array()
var beats_per_bar := 4
## Index into grid_beats of a bar's first beat (bars count from there).
var bar_phase := 0
const _BEAT_LINE := Color(1, 1, 1, 0.16)
const _BAR_LINE := Color(1, 1, 1, 0.5)
## Closest lines are drawn, in pixels.
const _GRID_MIN_PX := 5.0
## Mouse wheel zooms (and pans) the view.
var zoomable := false
## Narrowest view the wheel can zoom in to, seconds.
var min_view := 2.0
## Wheel zoom factor per notch.
const ZOOM_STEP := 1.25

## The visible window, seconds. view_len <= 0 means the whole song.
var view_start := 0.0
var view_len := 0.0

const _LO := Color(1.00, 0.62, 0.20)     # bass
const _MID := Color(0.35, 0.80, 0.42)    # mid
const _HI := Color(0.40, 0.72, 1.00)     # air
## One bar's six vertices (top, centre and bottom, left and right) as
## four triangles.
const _BAR_TRIS := [0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 5, 4]

## [{ lo, mid, hi, peak }] — level 0 is the analysis' own columns, each
## level above merges pairs (bands averaged, peak maxed).
var _levels: Array = []


func _ready() -> void:
	if custom_minimum_size.y <= 0.0:
		custom_minimum_size = Vector2(0, 92)
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(queue_redraw)


func set_analysis(a: SongAnalysis) -> void:
	analysis = a
	_levels.clear()
	if a != null and a.has_wave():
		_build_levels()
	view_start = 0.0
	view_len = 0.0
	queue_redraw()


func duration() -> float:
	return maxf(analysis.duration, 0.001) if analysis != null else 1.0


## The visible window's length in seconds (the whole song when unzoomed).
func visible_length() -> float:
	return view_len if view_len > 0.0 else duration()


## Draw a beat grid: `beats` in seconds, ascending; beat `phase` (and every
## `per_bar`th one either side of it) starts a bar. Empty clears it.
func set_beat_grid(beats: PackedFloat32Array, per_bar := 4, phase := 0) -> void:
	grid_beats = beats
	beats_per_bar = maxi(per_bar, 1)
	bar_phase = phase
	queue_redraw()


## Show `length` seconds from `start` (clamped to the song). length <= 0
## shows the whole song.
func set_view(start: float, length: float) -> void:
	var dur := duration()
	var ln := dur if length <= 0.0 or length >= dur else maxf(length, minf(min_view, dur))
	var st := clampf(start, 0.0, maxf(dur - ln, 0.0))
	var new_len := 0.0 if is_equal_approx(ln, dur) else ln
	if is_equal_approx(st, view_start) and is_equal_approx(new_len, view_len):
		return
	view_start = st
	view_len = new_len
	queue_redraw()
	view_changed.emit(view_start, visible_length())


## Zoom by `factor` (<1 zooms in) keeping the time under `at_x` pixels put.
func zoom_at(factor: float, at_x: float) -> void:
	var w := maxf(size.x, 1.0)
	var frac := clampf(at_x / w, 0.0, 1.0)
	var t := view_start + frac * visible_length()
	var ln := clampf(visible_length() * factor, minf(min_view, duration()), duration())
	set_view(t - frac * ln, ln)


func time_to_x(t: float) -> float:
	return (t - view_start) / visible_length() * size.x


func x_to_time(x: float) -> float:
	return view_start + x / maxf(size.x, 1.0) * visible_length()


func _build_levels() -> void:
	var lo := analysis.wave_lo
	var mid := analysis.wave_mid
	var hi := analysis.wave_hi
	var pk := analysis.wave_peak
	_levels.append({"lo": lo, "mid": mid, "hi": hi, "peak": pk})
	while pk.size() > 64:
		var n := ceili(pk.size() / 2.0)
		var nlo := PackedFloat32Array()
		var nmid := PackedFloat32Array()
		var nhi := PackedFloat32Array()
		var npk := PackedFloat32Array()
		nlo.resize(n)
		nmid.resize(n)
		nhi.resize(n)
		npk.resize(n)
		var last := pk.size() - 1
		for i in range(n):
			var a := i * 2
			var b := mini(a + 1, last)
			nlo[i] = (lo[a] + lo[b]) * 0.5
			nmid[i] = (mid[a] + mid[b]) * 0.5
			nhi[i] = (hi[a] + hi[b]) * 0.5
			npk[i] = maxf(pk[a], pk[b])
		lo = nlo
		mid = nmid
		hi = nhi
		pk = npk
		_levels.append({"lo": lo, "mid": mid, "hi": hi, "peak": pk})


func _draw() -> void:
	var w := size.x
	var h := size.y

	if analysis == null or not analysis.has_wave():
		draw_rect(Rect2(0, 0, w, h), background_color if background_color.a > 0.0 else Color(0.10, 0.10, 0.13))
		draw_string(ThemeDB.fallback_font, Vector2(8, h * 0.5 + 4),
			"analyse a song to see its waveform",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.5, 0.5, 0.55))
		return

	if background_color.a > 0.0:
		draw_rect(Rect2(0, 0, w, h), background_color)

	var t0 := view_start
	var t1 := view_start + visible_length()

	for sec in analysis.sections:
		var s0: float = float(sec["start"])
		var s1: float = float(sec["end"])
		if s1 < t0 or s0 > t1:
			continue
		var x0 := time_to_x(s0)
		var x1 := time_to_x(s1)
		var tint: Color = StructureBar.LABEL_HUE.get(
			String(sec["label"]), Color(0.3, 0.3, 0.35))
		tint.a = 0.16
		draw_rect(Rect2(x0, 0, maxf(x1 - x0, 1.0), h), tint)

	_draw_wave(w, h, t0, t1)
	_draw_grid(h, t0, t1)

	for db in analysis.downbeats:
		if db < t0 or db > t1:
			continue
		var x := time_to_x(db)
		draw_line(Vector2(x, h - 4), Vector2(x, h), Color(1, 1, 1, 0.22), 1.0)

	if show_cursor and song_pos >= t0 and song_pos <= t1:
		var px := time_to_x(song_pos)
		draw_line(Vector2(px, 0), Vector2(px, h), cursor_color, 2.0)


func _draw_grid(h: float, t0: float, t1: float) -> void:
	for line in grid_lines(t0, t1):
		var x: float = line[0]
		if line[1]:
			draw_line(Vector2(x, 0), Vector2(x, h), _BAR_LINE, 2.0)
		else:
			draw_line(Vector2(x, 0), Vector2(x, h), _BEAT_LINE, 1.0)


## The beat grid lines between t0 and t1 as [[x, is_bar], ...]. Beats are
## left out once they'd be closer than _GRID_MIN_PX, then bars too.
func grid_lines(t0: float, t1: float) -> Array:
	var out: Array = []
	var n := grid_beats.size()
	if n == 0:
		return out
	var i0 := grid_beats.bsearch(t0)
	var i1 := grid_beats.bsearch(t1, false)
	if i1 <= i0:
		return out
	# Spacing from the local tempo, not the window average.
	var gap := 0.0
	if n > 1:
		var j := clampi(i0, 0, n - 2)
		gap = (grid_beats[j + 1] - grid_beats[j]) / visible_length() * size.x
	var beats := gap >= _GRID_MIN_PX
	if gap * beats_per_bar < _GRID_MIN_PX:
		return out
	for i in range(i0, i1):
		var is_bar := posmod(i - bar_phase, beats_per_bar) == 0
		if is_bar or beats:
			out.append([time_to_x(grid_beats[i]), is_bar])
	return out


## Bars for the visible window, as one triangle batch: each column is a
## vertical bar mirrored about the centre line, fading from opaque at the
## centre to 60% at its tips.
func _draw_wave(w: float, h: float, t0: float, t1: float) -> void:
	if _levels.is_empty() or w < 1.0:
		return
	var dur := duration()
	var n0: int = _levels[0]["peak"].size()
	# Pick the level with roughly one to two columns per pixel.
	var cols_visible := (t1 - t0) / dur * n0
	var lvl := clampi(int(floor(log(maxf(cols_visible / w, 1.0)) / log(2.0))), 0, _levels.size() - 1)
	var L: Dictionary = _levels[lvl]
	var lo: PackedFloat32Array = L["lo"]
	var mid: PackedFloat32Array = L["mid"]
	var hi: PackedFloat32Array = L["hi"]
	var pk: PackedFloat32Array = L["peak"]
	var n := pk.size()
	var col_dur := dur / n
	var c0 := clampi(int(floor(t0 / col_dur)), 0, n - 1)
	var c1 := clampi(int(ceil(t1 / col_dur)), c0 + 1, n)

	var mid_y := h * 0.5
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var count := c1 - c0
	pts.resize(count * 6)
	cols.resize(count * 6)
	idx.resize(count * 12)
	var v := 0
	var k := 0
	for c in range(c0, c1):
		var x0 := time_to_x(c * col_dur)
		var x1 := maxf(time_to_x((c + 1) * col_dur), x0 + 1.0)
		# sharpen the dominant band so bass / air read, not a mid wall
		var l := lo[c] * lo[c] * 1.3
		var m := mid[c] * mid[c]
		var a := hi[c] * hi[c] * 1.3
		var sum := l + m + a
		var col := Color(0.55, 0.55, 0.6)
		if sum > 0.0001:
			col = (_LO * l + _MID * m + _HI * a) / sum
		var half := sqrt(clampf(pk[c], 0.0, 1.0)) * (mid_y - 1.0)
		var tip := Color(col.r, col.g, col.b, 0.6)
		var core := Color(col.r, col.g, col.b, 1.0)
		pts[v] = Vector2(x0, mid_y - half)
		pts[v + 1] = Vector2(x1, mid_y - half)
		pts[v + 2] = Vector2(x0, mid_y)
		pts[v + 3] = Vector2(x1, mid_y)
		pts[v + 4] = Vector2(x0, mid_y + half)
		pts[v + 5] = Vector2(x1, mid_y + half)
		cols[v] = tip
		cols[v + 1] = tip
		cols[v + 2] = core
		cols[v + 3] = core
		cols[v + 4] = tip
		cols[v + 5] = tip
		for t in _BAR_TRIS:
			idx[k] = v + t
			k += 1
		v += 6
	RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), idx, pts, cols)


func _gui_input(event: InputEvent) -> void:
	if analysis == null:
		return
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				seek_requested.emit(clampf(x_to_time(mb.position.x), 0.0, duration()))
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if not zoomable:
					return
				if mb.shift_pressed:
					_pan(-1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0)
				else:
					zoom_at(1.0 / ZOOM_STEP if mb.button_index == MOUSE_BUTTON_WHEEL_UP else ZOOM_STEP,
						mb.position.x)
				accept_event()
			MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT:
				if not zoomable:
					return
				_pan(-1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_LEFT else 1.0)
				accept_event()


## Scroll the view by a tenth of its width.
func _pan(direction: float) -> void:
	set_view(view_start + direction * visible_length() * 0.1, view_len)
