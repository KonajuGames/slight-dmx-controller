class_name TimelineTrack
extends Control
## One lighting timeline in DJ Edit Mode's track timeline: the
## master (affects every fixture), one fixture, or one head of a fixture.
## It's a stack of rows, one per kind of thing its target supports, from
## the bottom up:
##   Position — 10 px, for moving heads (pan / tilt): a named position
##   Strobe   — 10 px
##   Movement — 10 px, for moving heads: a movement effect (circle, figure
##              8, ...) around the pan / tilt the Position row gives
##   Colour   — 10 px
##   Dimmer   — 80 px: a node line for the intensity, filled underneath
##              with white fading from transparent at the bottom of the
##              row to 50 % at its top. The master's runs the whole song
##              (a flat 100 % with no nodes); a fixture's or head's starts
##              empty and covers only from its first node to its last —
##              where it has one it overrides the fixture's / master's,
##              elsewhere it inherits (inherits())
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
## The colour row holds colour segments (colour_segments): a span with a
## colour at each end — the same for a static colour, two for a gradient;
## outside its segments the row sets nothing. The strobe row holds strobe
## segments (strobe_segments): spans where the strobe's on, at a speed
## (Strobe: slow / medium / fast) — drawn as a line up at each end and a
## dashed line between, low / middle / high in the row by speed; off
## elsewhere.
## Right-click asks the owner
## for a context menu (context_requested).
## A plain left-button drag on a selected area's start / end resizes it,
## and inside it moves it (the owner does both, through select_drag); a
## dimmer node still wins over the edge, the edge over the dimmer line.
## A plain left-button press on the playhead line (within PLAYHEAD_GRAB
## px) drags it (playhead_drag: the owner scrubs) — over everything but a
## dimmer node.
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
## The playhead line dragged: `phase` SELECT_PRESS, _MOVE or _RELEASE, to
## `time` seconds.
signal playhead_drag(track: TimelineTrack, phase: int, time: float)
## A right-click on `row` (not a Ctrl+right-click on a dimmer node, which
## removes it), at `global_pos` / `time` seconds.
signal context_requested(track: TimelineTrack, row: int, global_pos: Vector2, time: float)
## The user toggled mute or solo on the track's name plate.
signal mix_toggled(track: TimelineTrack)
## `mute`, `solo` or `silenced` changed (by the user or not).
signal mix_changed
## The user collapsed the track (a click on its name plate) or expanded it
## (a click on the collapsed bar).
signal collapse_toggled(track: TimelineTrack)

## The kinds of row (stacked bottom to top in this order: ROW_ORDER).
enum Row { POSITION, STROBE, MOVEMENT, COLOUR, DIMMER }
enum Target { MASTER, FIXTURE, HEAD }

## Bottom to top.
const ROW_ORDER := [Row.POSITION, Row.STROBE, Row.MOVEMENT, Row.COLOUR, Row.DIMMER]
const ROW_NAMES := {Row.POSITION: "Position", Row.STROBE: "Strobe", Row.MOVEMENT: "Movement",
	Row.COLOUR: "Colour", Row.DIMMER: "Dimmer"}
const ROW_HEIGHT := 10.0
## A collapsed track's height.
const COLLAPSED_HEIGHT := 20.0
## The width of a collapsed bar's M / S buttons.
const COLLAPSED_BUTTON_WIDTH := 22.0
const DIMMER_HEIGHT := 80.0

const _BG := [Color(0.10, 0.10, 0.12), Color(0.12, 0.12, 0.14)]
const _SEPARATOR := Color(0, 0, 0, 0.6)
const _LABEL := Color(1, 1, 1, 0.28)
const _LINE := Color(1, 1, 1, 0.9)
const _FILL_TOP_ALPHA := 0.5
const _NODE_RADIUS := 3.0
const _GHOST_LINE := Color(1, 1, 1, 0.55)
const _GHOST_FILL_ALPHA := 0.18
const _GHOST_COLOUR_ALPHA := 0.6
const _GHOST_DIM := Color(0, 0, 0, 0.35)
const _STROBE := Color(1, 1, 1, 0.9)
## How close (px) the pointer must be to a selected area's start / end to
## grab it.
const EDGE_GRAB := 5.0
## How near the playhead line (px) a press picks it up.
const PLAYHEAD_GRAB := 4.0
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
## The colour row's segments, in time order and not overlapping:
## [{t0, t1, c0: Color, c1: Color}] — c0 at t0 fading to c1 at t1.
var colour_segments: Array = []:
	set(v):
		colour_segments = v
		queue_redraw()
## Strobe speeds; a segment without one (saved before speeds) is MEDIUM.
enum Strobe { SLOW, MEDIUM, FAST }
const STROBE_NAMES := {Strobe.SLOW: "Slow", Strobe.MEDIUM: "Medium", Strobe.FAST: "Fast"}
## The strobe row's segments (strobe on), in time order, not overlapping:
## [{t0, t1, speed: Strobe}].
var strobe_segments: Array = []:
	set(v):
		strobe_segments = v
		queue_redraw()
## The position row's segments, in time order, not overlapping:
## [{t0, t1, pos: a named position's id}].
var position_segments: Array = []:
	set(v):
		position_segments = v
		queue_redraw()
## The movement row's segments, in time order, not overlapping:
## [{t0, t1, fx: Movement name ("none", "circle", ...), period: seconds
## per cycle, size: 0..1 of the pan / tilt range, phase?: 0..1 of a cycle
## it starts into (fixtures fanned out across one movement)}].
var movement_segments: Array = []:
	set(v):
		movement_segments = v
		queue_redraw()
## The show's named positions (their colours, for drawing the position
## row). Null = none.
var positions: PositionLibrary:
	set(v):
		if positions != null and positions.changed.is_connected(queue_redraw):
			positions.changed.disconnect(queue_redraw)
		positions = v
		if positions != null:
			positions.changed.connect(queue_redraw)
		queue_redraw()
## While the selection's being moved: its content, drawn translucent where
## it would land — {rows: {Row: [parts — {t0, t1, nodes? / segments?},
## relative to the clip's start]}, at: where the clip would start, from:
## where it starts now (that spot is dimmed)}. {} = none.
var ghost := {}:
	set(v):
		ghost = v
		queue_redraw()
## Supplies the view (zoom / scroll) — the timeline's zoomable waveform.
var wave: WaveHeatmap
## Whether the mouse can edit the dimmer nodes.
var editable := true
## The selected areas this track draws its rows' part of (and its key in
## them: meta "key"). Null = none.
var selection: TimelineSelection:
	set(v):
		if selection != null and selection.changed.is_connected(update_selection):
			selection.changed.disconnect(update_selection)
		selection = v
		if selection != null:
			selection.changed.connect(update_selection)
		update_selection()
## Muted: left out of playback (the plate's M button); a muted master
## silences every fixture, a muted fixture its heads. Saved with the
## timelines.
var mute := false:
	set(v):
		if v != mute:
			mute = v
			queue_redraw()                  # a collapsed bar's M
			mix_changed.emit()
## Soloed (the plate's S button; not on the master): while any track is,
## only the soloed ones play (a soloed fixture's heads too, and a soloed
## head's fixture and the master, which it inherits from). Saved.
var solo := false:
	set(v):
		if v != solo:
			solo = v
			queue_redraw()
			mix_changed.emit()
## Whether it's left out of playback now, by its own mute / solo or
## another's (plays()): drawn faded.
var silenced := false:
	set(v):
		if v != silenced:
			silenced = v
			queue_redraw()
			mix_changed.emit()
## Collapsed: no rows, just a bar styled as its name plate — the name at
## the left, M / S at the right. Still plays. Saved with the timelines.
var collapsed := false:
	set(v):
		if v != collapsed:
			collapsed = v
			_fit_height()
			queue_redraw()
## The collapsed bar's colour (its name plate's fill).
var plate_fill := NamePlate.FILL:
	set(v):
		plate_fill = v
		queue_redraw()
var _selecting := false
var _dragging_playhead := false

var _hover := -1      # node index under the pointer, or -1
var _drag := -1       # node index being dragged, or -1
## Node indices moved by a line drag (empty when not dragging the line).
var _drag_line := PackedInt32Array()
var _line_t := 0.0                         # where on the line it was grabbed
var _press := Vector2.ZERO                 # pointer position at the press
var _orig := PackedVector2Array()          # the nodes at the press


## The rows a fixture (or head) with these channel roles gets: Position
## and Movement for pan / tilt, Strobe for a strobe / shutter channel,
## Colour for any colour channel or wheel, Dimmer for a dimmer channel — or
## for colour / white channels without one, which the fixture's virtual
## dimmer scales.
static func rows_for_roles(roles: Array) -> Array:
	var out := []
	var moves := "PAN" in roles or "TILT" in roles
	if moves:
		out.append(Row.POSITION)
	if "STROBE" in roles:
		out.append(Row.STROBE)
	if moves:
		out.append(Row.MOVEMENT)
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
	set_notify_transform(true)          # scrolled into view: catch up (_stale)
	_selection_layer = SelectionLayer.new()
	_selection_layer.track = self
	_selection_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_selection_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_selection_layer)
	_playhead = Playhead.new()
	_playhead.track = self
	_playhead.set_anchors_preset(Control.PRESET_FULL_RECT)
	_playhead.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_playhead)


var _playhead: Playhead
var _selection_layer: SelectionLayer
# The nearest ancestor clipping the track (the fixtures' scroll panel), or
# null. While the track's scrolled out of it nothing's drawn: _stale is
# set instead, and it's redrawn when it comes back into view.
var _clip: Control
var _stale := false


## Redraw just the playhead line (it moves every frame while playing; the
## rows themselves needn't be redrawn for it).
func update_playhead() -> void:
	_redraw_layer(_playhead)


## Redraw just the selected areas (the rows beneath stay as they are).
func update_selection() -> void:
	_redraw_layer(_selection_layer)


func _redraw_layer(layer: Control) -> void:
	if not is_on_screen():
		_stale = true
	elif layer != null:
		layer.queue_redraw()


## Whether any of the track shows (isn't scrolled out of its panel).
func is_on_screen() -> bool:
	if _clip == null:
		return true
	return get_global_rect().intersects(_clip.get_global_rect())


## `r` (a rectangle in the track) in global coordinates, cut to the panel
## the track scrolls in: empty where it's scrolled out of view.
func visible_global_rect(r: Rect2) -> Rect2:
	var g := get_global_transform() * r
	return g if _clip == null else g.intersection(_clip.get_global_rect())


## Draw what was skipped while out of view, if it's back in view.
func _catch_up() -> void:
	if _stale and is_on_screen():
		queue_redraw()


## Where the playhead line is drawn across the rows, x in the track; -1
## when there's none (no song playable, or out of view).
func playhead_x() -> float:
	if wave == null or wave.analysis == null or not wave.show_cursor:
		return -1.0
	var x := _t2x(wave.song_pos)
	return x if x >= 0.0 and x <= size.x else -1.0


func has_row(r: Row) -> bool:
	return r in rows


func row_height(r: Row) -> float:
	return DIMMER_HEIGHT if r == Row.DIMMER else ROW_HEIGHT


## A row's rectangle within the track (empty if the track hasn't got it).
func row_rect(r: Row) -> Rect2:
	if collapsed or not has_row(r):
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
	if collapsed:
		h = COLLAPSED_HEIGHT
	custom_minimum_size = Vector2(custom_minimum_size.x, h)


## The dimmer level at `t` seconds (linear between nodes).
func dimmer_at(t: float) -> float:
	return level_at(dimmer_nodes, t)


## Whether this track's dimmer line inherits where it has no values (a
## fixture's or head's — the master's runs the whole song).
func inherits() -> bool:
	return target != Target.MASTER


## Whether the dimmer line has a value at `t`: anywhere on the master; on
## a fixture / head, from its first node to its last.
func dimmer_defined_at(t: float) -> bool:
	return not inherits() or line_defined_at(dimmer_nodes, t)


static func line_defined_at(nodes: PackedVector2Array, t: float) -> bool:
	return nodes.size() > 0 and t >= nodes[0].x and t <= nodes[nodes.size() - 1].x


## The part of `t0`..`t1` the dimmer line has values over (all of it on
## the master), or Vector2(-1, -1) where it has none.
func dimmer_defined_span(t0: float, t1: float) -> Vector2:
	if not inherits():
		return Vector2(t0, t1)
	if dimmer_nodes.is_empty():
		return Vector2(-1, -1)
	var a := maxf(t0, dimmer_nodes[0].x)
	var b := minf(t1, dimmer_nodes[dimmer_nodes.size() - 1].x)
	return Vector2(a, b) if b > a else Vector2(-1, -1)


## A node line's level at `t` seconds: linear between nodes, holding the
## first / last level outside them, 1.0 with no nodes. Where two nodes
## share a time (a step), the earlier's level.
static func level_at(nodes: PackedVector2Array, t: float) -> float:
	var n := nodes.size()
	if n == 0:
		return 1.0
	if t <= nodes[0].x:
		return nodes[0].y
	for i in range(1, n):
		if t <= nodes[i].x:
			var a := nodes[i - 1]
			var b := nodes[i]
			return lerpf(a.y, b.y, (t - a.x) / maxf(b.x - a.x, 1e-6))
	return nodes[n - 1].y


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
	if not dimmer_defined_at(_x2t(pos.x)):
		return false                    # no line there (a fixture / head inheriting)
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


## The dimmer level just after `t` — where two nodes share a time (a
## step), the later one's; dimmer_at() gives the earlier's.
func _dimmer_after(t: float) -> float:
	var n := dimmer_nodes.size()
	if n == 0:
		return 1.0
	for i in range(n):
		if dimmer_nodes[i].x > t:
			if i == 0:
				return dimmer_nodes[0].y
			var a := dimmer_nodes[i - 1]
			var b := dimmer_nodes[i]
			return lerpf(a.y, b.y, (t - a.x) / maxf(b.x - a.x, 1e-6))
	return dimmer_nodes[n - 1].y


## Black out the dimmer from `t0` to `t1` seconds: the nodes in that span
## go, the level there is 0, and a node at each edge keeps the level just
## outside it as it was (a step down at t0, back up at t1). No edge node
## where the span reaches the song's start / end, or where the level
## outside is already 0. Returns whether anything changed.
func clear_dimmer(t0: float, t1: float) -> bool:
	return replace_dimmer(t0, t1, PackedVector2Array([Vector2(0, 0), Vector2(t1 - t0, 0)]))


## The dimmer line from `t0` to `t1` (for copying), as nodes relative to
## t0: the level just after t0, every node strictly inside, and the level
## just before t1 — so it pastes back exactly.
func dimmer_segment(t0: float, t1: float) -> PackedVector2Array:
	var out := PackedVector2Array([Vector2(0.0, _dimmer_after(t0))])
	for p in dimmer_nodes:
		if p.x > t0 and p.x < t1:
			out.append(Vector2(p.x - t0, p.y))
	out.append(Vector2(t1 - t0, dimmer_at(t1)))
	return out


## Replace the dimmer line from `t0` to `t1` with `segment` (nodes
## relative to t0, from 0 to t1 - t0 — as dimmer_segment() gives): the
## nodes in that span go, the segment's go in, and a node at each edge
## keeps the level just outside as it was (a step there, if it differs
## from the segment's own edge level). Cut off at the song's end. Returns
## whether anything changed.
func replace_dimmer(t0: float, t1: float, segment: PackedVector2Array) -> bool:
	var end := wave.duration() if wave != null and wave.analysis != null else INF
	var shift := t0
	t0 = maxf(t0, 0.0)
	t1 = minf(t1, end)
	if t1 <= t0 or segment.is_empty():
		return false
	# The segment on the timeline, cut to t0..t1 (interpolated at a cut).
	var seg := PackedVector2Array()
	for k in range(segment.size()):
		var p := Vector2(segment[k].x + shift, segment[k].y)
		if p.x < t0:
			if k + 1 < segment.size():          # crossing into the window
				var q := Vector2(segment[k + 1].x + shift, segment[k + 1].y)
				if q.x > t0:
					seg.append(Vector2(t0, lerpf(p.y, q.y, (t0 - p.x) / (q.x - p.x))))
			continue
		if p.x > t1:
			if k > 0:                           # crossing out of it
				var o := Vector2(segment[k - 1].x + shift, segment[k - 1].y)
				if o.x < t1:
					seg.append(Vector2(t1, lerpf(o.y, p.y, (t1 - o.x) / (p.x - o.x))))
			break
		seg.append(p)
	if seg.is_empty():
		return false
	var before := dimmer_at(t0)         # just before t0 (the left of any step there)
	var after := _dimmer_after(t1)      # just after t1 (the right of any step)
	var nodes := PackedVector2Array()
	var i := 0
	while i < dimmer_nodes.size() and dimmer_nodes[i].x < t0:
		nodes.append(dimmer_nodes[i])
		i += 1
	# Edge nodes keep the line outside as it was — only where it has values
	# there (a fixture's / head's line doesn't spread past its ends).
	var n := dimmer_nodes.size()
	var line_before := not inherits() or (n > 0 and t0 > dimmer_nodes[0].x)
	var line_after := not inherits() or (n > 0 and t1 < dimmer_nodes[n - 1].x)
	if t0 > 0.0 and line_before and not is_equal_approx(before, seg[0].y):
		nodes.append(Vector2(t0, before))
	nodes.append_array(seg)
	if t1 < end and line_after and not is_equal_approx(after, seg[-1].y):
		nodes.append(Vector2(t1, after))
	while i < dimmer_nodes.size() and dimmer_nodes[i].x <= t1:
		i += 1                          # inside the span: replaced
	while i < dimmer_nodes.size():
		nodes.append(dimmer_nodes[i])
		i += 1
	if nodes == dimmer_nodes:
		return false
	dimmer_nodes = nodes
	return true


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


# ---------------------------------------------------------------- COLOUR --

## The colour at `t` seconds (a segment's, interpolated), or null where
## no segment is.
func colour_at(t: float):
	return segment_colour_at(colour_segments, t)


static func segment_colour_at(segs: Array, t: float):
	for sg in segs:
		if t >= sg["t0"] and t <= sg["t1"]:
			var span: float = sg["t1"] - sg["t0"]
			return (sg["c0"] as Color).lerp(sg["c1"], 0.0 if span <= 0.0 else (t - sg["t0"]) / span)
	return null


## The colour segments from `t0` to `t1` (for copying), cut to that span
## and made relative to t0.
func colour_segment(t0: float, t1: float) -> Array:
	var out: Array = []
	for sg in colour_segments:
		if sg["t1"] <= t0 or sg["t0"] >= t1:
			continue
		var a := maxf(sg["t0"], t0)
		var b := minf(sg["t1"], t1)
		out.append({"t0": a - t0, "t1": b - t0,
			"c0": segment_colour_at([sg], a), "c1": segment_colour_at([sg], b)})
	return out


## Replace the colour row from `t0` to `t1` with `segments` (relative to
## t0, as colour_segment() gives; [] clears it): segments overlapping the
## span are cut back to its edges (keeping their colours there). Cut off
## at the song's end. Returns whether anything changed.
func replace_colour(t0: float, t1: float, segments: Array) -> bool:
	var end := wave.duration() if wave != null and wave.analysis != null else INF
	var shift := t0
	t0 = maxf(t0, 0.0)
	t1 = minf(t1, end)
	if t1 <= t0:
		return false
	var out: Array = []
	for sg in colour_segments:
		if sg["t1"] <= t0 or sg["t0"] >= t1:
			out.append(sg)
			continue
		if sg["t0"] < t0:
			out.append({"t0": sg["t0"], "t1": t0, "c0": sg["c0"], "c1": segment_colour_at([sg], t0)})
		if sg["t1"] > t1:
			out.append({"t0": t1, "t1": sg["t1"], "c0": segment_colour_at([sg], t1), "c1": sg["c1"]})
	for sg in segments:
		var a: float = sg["t0"] + shift
		var b: float = sg["t1"] + shift
		if b <= t0 or a >= t1:
			continue
		var whole := {"t0": a, "t1": b, "c0": sg["c0"], "c1": sg["c1"]}
		var ca := maxf(a, t0)
		var cb := minf(b, t1)
		if cb > ca:
			out.append({"t0": ca, "t1": cb, "c0": segment_colour_at([whole], ca), "c1": segment_colour_at([whole], cb)})
	out.sort_custom(func(x, y): return x["t0"] < y["t0"])
	if _same_segments(out, colour_segments):
		return false
	colour_segments = out
	return true


static func _same_segments(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if not (is_equal_approx(a[i]["t0"], b[i]["t0"]) and is_equal_approx(a[i]["t1"], b[i]["t1"])
				and (a[i]["c0"] as Color).is_equal_approx(b[i]["c0"]) and (a[i]["c1"] as Color).is_equal_approx(b[i]["c1"])):
			return false
	return true


# ---------------------------------------------------------------- STROBE --

## Whether the strobe's on at `t` seconds.
func strobe_at(t: float) -> bool:
	return span_at(strobe_segments, t)


## The strobe's speed at `t` seconds (Strobe), or -1 where it's off.
func strobe_speed_at(t: float) -> int:
	return speed_at(strobe_segments, t)


static func speed_at(spans: Array, t: float) -> int:
	for sg in spans:
		if t >= sg["t0"] and t <= sg["t1"]:
			return int(sg.get("speed", Strobe.MEDIUM))
	return -1


static func span_at(spans: Array, t: float) -> bool:
	for sg in spans:
		if t >= sg["t0"] and t <= sg["t1"]:
			return true
	return false


## The strobe segments from `t0` to `t1` (for copying), cut to that span
## and made relative to t0.
func strobe_segment(t0: float, t1: float) -> Array:
	return tagged_segment(strobe_segments, t0, t1, "speed", Strobe.MEDIUM)


## Replace the strobe row from `t0` to `t1` with `segments` (relative to
## t0; [] turns it off there): segments overlapping the span are cut back
## to its edges; touching segments of the same speed are joined. Cut off
## at the song's end. Returns whether anything changed.
func replace_strobe(t0: float, t1: float, segments: Array) -> bool:
	var out := _replace_tagged(strobe_segments, t0, t1, segments, "speed", Strobe.MEDIUM)
	if out == strobe_segments:
		return false
	strobe_segments = out
	return true


# -------------------------------------------------------------- POSITION --

## The named position's id at `t` seconds, or "" where none is.
func position_at(t: float) -> String:
	return position_id_at(position_segments, t)


static func position_id_at(spans: Array, t: float) -> String:
	for sg in spans:
		if t >= sg["t0"] and t <= sg["t1"]:
			return String(sg.get("pos", ""))
	return ""


## The position segments from `t0` to `t1` (for copying), cut and relative
## to t0.
func position_segment(t0: float, t1: float) -> Array:
	return tagged_segment(position_segments, t0, t1, "pos", "")


## Replace the position row from `t0` to `t1` with `segments` (relative to
## t0, each {t0, t1, pos: a named position's id}; [] clears it there).
## Touching segments of the same position join. Returns whether anything
## changed.
func replace_position(t0: float, t1: float, segments: Array) -> bool:
	var out := _replace_tagged(position_segments, t0, t1, segments, "pos", "")
	if out == position_segments:
		return false
	position_segments = out
	return true


# -------------------------------------------------------------- MOVEMENT --

## The movement effects: none (hold still — beating a master movement),
## and the shapes the pan / tilt trace around their position.
const MOVEMENTS := ["none", "circle", "figure8", "pan_sweep", "tilt_sweep"]
const MOVEMENT_NAMES := {"none": "None", "circle": "Circle", "figure8": "Figure 8",
	"pan_sweep": "Pan Sweep", "tilt_sweep": "Tilt Sweep"}
## A new movement's size (of the pan / tilt range) and, without a beat
## grid, its cycle length.
const MOVEMENT_SIZE := 0.04
const MOVEMENT_PERIOD := 4.0
## The largest movement size (MusicTimeline's Large), what the row draws
## its shapes at full size for.
const MOVEMENT_SIZE_MAX := 0.08


## The movement segment at `t` seconds ({} where there's none).
func movement_at(t: float) -> Dictionary:
	return movement_segment_at(movement_segments, t)


static func movement_segment_at(spans: Array, t: float) -> Dictionary:
	for sg in spans:
		if t >= sg["t0"] and t <= sg["t1"]:
			return sg
	return {}


## Where a movement puts the pan / tilt, relative to its centre, `dt`
## seconds into its segment: the shape's point at that phase of its cycle
## (plus the segment's own phase), times its size (pan right, tilt up).
## None: no offset.
static func movement_offset(sg: Dictionary, dt: float) -> Vector2:
	var period := maxf(float(sg.get("period", MOVEMENT_PERIOD)), 0.05)
	var a := TAU * fposmod(dt / period + float(sg.get("phase", 0.0)), 1.0)
	var size := float(sg.get("size", MOVEMENT_SIZE))
	match String(sg.get("fx", "none")):
		"circle":
			return Vector2(cos(a), sin(a)) * size
		"figure8":
			return Vector2(sin(a), sin(2.0 * a) * 0.5) * size
		"pan_sweep":
			return Vector2(sin(a), 0.0) * size
		"tilt_sweep":
			return Vector2(0.0, sin(a)) * size
	return Vector2.ZERO


func movement_segment(t0: float, t1: float) -> Array:
	return tagged_segment(movement_segments, t0, t1, "fx", "none")


## Replace the movement row from `t0` to `t1` with `segments` (relative to
## t0; [] clears it). Touching segments with the same effect join.
func replace_movement(t0: float, t1: float, segments: Array) -> bool:
	var out := _replace_tagged(movement_segments, t0, t1, segments, "fx", "none")
	if out == movement_segments:
		return false
	movement_segments = out
	return true


# ---------------------------------------------------------- TAGGED SPANS --
# Strobe and position segments are spans with one tag each ({t0, t1,
# <tag>}): a speed, a position's id.

## The segments of `spans` from `t0` to `t1`, cut to that span and made
## relative to t0, keeping their `tag` (`default` where it's missing) and
## any other fields.
static func tagged_segment(spans: Array, t0: float, t1: float, tag: String, default) -> Array:
	var out: Array = []
	for sg in spans:
		if sg["t1"] <= t0 or sg["t0"] >= t1:
			continue
		out.append(_with_span(sg, maxf(sg["t0"], t0) - t0, minf(sg["t1"], t1) - t0, tag, default))
	return out


## A copy of span `sg` (every field) over `a`..`b`, its `tag` filled in.
static func _with_span(sg: Dictionary, a: float, b: float, tag: String, default) -> Dictionary:
	var out := sg.duplicate()
	out["t0"] = a
	out["t1"] = b
	if not out.has(tag):
		out[tag] = default
	return out


## Whether two spans are the same apart from their times (so may join).
static func _same_but_times(x: Dictionary, y: Dictionary) -> bool:
	if x.size() != y.size():
		return false
	for k in x:
		if k != "t0" and k != "t1" and (not y.has(k) or x[k] != y[k]):
			return false
	return true


## `spans` with `t0`..`t1` replaced by `segments` (relative to t0): the
## spans overlapping it cut back to its edges, the new ones put in (cut
## to the span and the song's end), and touching spans with the same tag
## joined.
func _replace_tagged(spans: Array, t0: float, t1: float, segments: Array, tag: String, default) -> Array:
	var end := wave.duration() if wave != null and wave.analysis != null else INF
	var shift := t0
	t0 = maxf(t0, 0.0)
	t1 = minf(t1, end)
	if t1 <= t0:
		return spans
	var out: Array = []
	for sg in spans:
		if sg["t1"] <= t0 or sg["t0"] >= t1:
			out.append(sg.duplicate())
			continue
		if sg["t0"] < t0:
			out.append(_with_span(sg, sg["t0"], t0, tag, default))
		if sg["t1"] > t1:
			out.append(_with_span(sg, t1, sg["t1"], tag, default))
	for sg in segments:
		var a := maxf(sg["t0"] + shift, t0)
		var b := minf(sg["t1"] + shift, t1)
		if b > a:
			out.append(_with_span(sg, a, b, tag, default))
	out.sort_custom(func(x, y): return x["t0"] < y["t0"])
	var joined: Array = []
	for sg in out:
		if not sg.has(tag):
			sg[tag] = default
		if not joined.is_empty() and sg["t0"] <= joined[-1]["t1"] + 0.0005 and _same_but_times(sg, joined[-1]):
			joined[-1]["t1"] = maxf(joined[-1]["t1"], sg["t1"])
		else:
			joined.append(sg)
	return joined


func _gui_input(event: InputEvent) -> void:
	if collapsed:
		# A press on M / S toggles it; anywhere else expands the track.
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var b := collapsed_button_at(event.position)
			if b >= 0:
				toggle_mix(b)
			else:
				collapsed = false
				collapse_toggled.emit(self)
			accept_event()
		return
	# The playhead being dragged: follow it to the release.
	if _dragging_playhead:
		if event is InputEventMouseMotion:
			playhead_drag.emit(self, SELECT_MOVE, _x2t(event.position.x))
			accept_event()
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_dragging_playhead = false
			playhead_drag.emit(self, SELECT_RELEASE, _x2t(event.position.x))
			accept_event()
		return
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
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed \
			and not (event.ctrl_pressed and dimmer_editing and node_at(event.position) >= 0):
		var row := row_at(event.position)
		if row >= 0:
			context_requested.emit(self, row, get_global_transform() * event.position, _x2t(event.position.x))
			accept_event()
			return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var at: Vector2 = event.position
		var plain: bool = not event.ctrl_pressed and not event.shift_pressed
		if plain and on_playhead(at) and not (dimmer_editing and node_at(at) >= 0):
			_dragging_playhead = true
			playhead_drag.emit(self, SELECT_PRESS, _x2t(at.x))
			accept_event()
			return
		var edge := plain and on_selection_edge(at)
		var special := dimmer_editing and (node_at(at) >= 0 or (on_line(at) and not edge))
		if not special and row_at(at) >= 0:
			# Empty timeline: start selecting an area.
			_selecting = true
			select_drag.emit(self, SELECT_PRESS, get_global_transform() * at, event.ctrl_pressed, event.shift_pressed)
			accept_event()
			return
	if not dimmer_editing:
		if event is InputEventMouseMotion:
			_set_hover(-1, false, event.position)
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
		_set_hover(node_at(mm.position), on_line(mm.position), mm.position)
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


## Whether `pos` is on the playhead line, on a row.
func on_playhead(pos: Vector2) -> bool:
	var x := playhead_x()
	return x >= 0.0 and absf(pos.x - x) <= PLAYHEAD_GRAB and row_at(pos) >= 0


## Whether `pos` is on the start / end of a selected area on its row.
func on_selection_edge(pos: Vector2) -> bool:
	var row := row_at(pos)
	if row < 0 or selection == null or not has_meta("key"):
		return false
	for span in selection.spans_for(String(get_meta("key")), row):
		if absf(pos.x - _t2x(span.x)) <= EDGE_GRAB or absf(pos.x - _t2x(span.y)) <= EDGE_GRAB:
			return true
	return false


## Whether `pos` is inside a selected area on its row.
func in_selection(pos: Vector2) -> bool:
	var row := row_at(pos)
	return row >= 0 and selection != null and has_meta("key") \
		and selection.has(String(get_meta("key")), row, _x2t(pos.x))


## The pointer's cursor: a hand over a node, left-right arrows on the
## playhead or a selection's edge, up-down on the dimmer line, a move
## cursor inside a selection. `pos` (track coordinates) for the playhead
## and selection ones.
func _set_hover(i: int, line := false, pos := Vector2(-1, -1)) -> void:
	var shape := Control.CURSOR_ARROW
	if i >= 0:
		shape = Control.CURSOR_POINTING_HAND
	elif pos.x >= 0.0 and (on_playhead(pos) or on_selection_edge(pos)):
		shape = Control.CURSOR_HSIZE
	elif line:
		shape = Control.CURSOR_VSIZE
	elif pos.x >= 0.0 and in_selection(pos):
		shape = Control.CURSOR_MOVE
	mouse_default_cursor_shape = shape
	if i == _hover:
		return
	_hover = i
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _drag < 0 and _drag_line.is_empty():
		_set_hover(-1)
	elif what == NOTIFICATION_TRANSFORM_CHANGED:
		_catch_up()
	elif what == NOTIFICATION_ENTER_TREE:
		_clip = null
		var p := get_parent()
		while p != null and not (p is Control and p.clip_contents):
			p = p.get_parent()
		if p != null:
			_clip = p
			_clip.resized.connect(_catch_up)
	elif what == NOTIFICATION_EXIT_TREE:
		if _clip != null and _clip.resized.is_connected(_catch_up):
			_clip.resized.disconnect(_catch_up)
		_clip = null


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
	# Only where the line has values: on a fixture / head, its first node
	# to its last.
	var span := dimmer_defined_span(v.x, v.x + v.y)
	if span.x < 0.0:
		return out
	var t0 := span.x
	var t1 := span.y
	out.append(Vector2(_t2x(t0) if inherits() else 0.0, _level_y(r, _dimmer_after(t0) if inherits() else dimmer_at(t0))))
	for p in dimmer_nodes:
		if p.x > t0 and p.x < t1:
			out.append(Vector2(_t2x(p.x), _level_y(r, p.y)))
	out.append(Vector2(_t2x(t1) if inherits() else size.x, _level_y(r, dimmer_at(t1))))
	return out


func _draw() -> void:
	if not is_on_screen():
		_stale = true
		return
	_stale = false
	update_playhead()               # the view may have moved under it
	update_selection()
	if collapsed:
		_draw_collapsed()
		return
	var font := get_theme_default_font()
	var i := 0
	for row in rows:
		var r := row_rect(row)
		draw_rect(r, _BG[i % 2])
		draw_line(Vector2(0, r.position.y), Vector2(size.x, r.position.y), _SEPARATOR, 1.0)
		i += 1
	_draw_grid()
	for row in rows:
		var r := row_rect(row)
		if row == Row.DIMMER:
			_draw_dimmer(r)
		elif row == Row.COLOUR:
			_draw_colour(r)
		elif row == Row.STROBE:
			_draw_strobe(r, strobe_segments, 0.0, _STROBE)
		elif row == Row.POSITION:
			_draw_position(r, position_segments, 0.0, 1.0)
		elif row == Row.MOVEMENT:
			_draw_movement(r, movement_segments, 0.0, 1.0)
		# The name, sized to fit the row (8 px in the 10 px rows), at the top
		# of the dimmer row.
		var fs := 10 if row == Row.DIMMER else 8
		var band := minf(r.size.y, 14.0)
		draw_string(font, Vector2(4.0, r.position.y + band * 0.5 + fs * 0.35),
			ROW_NAMES[row], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, _LABEL)
		if not ghost.is_empty():
			_draw_ghost(row, r)
	if silenced:
		draw_rect(Rect2(Vector2.ZERO, size), _SILENCED)


## Collapsed: the bar, as its name plate — the name (and head) at the left,
## faded if it's left out of playback, and M / S at the right.
func _draw_collapsed() -> void:
	var box := Rect2(Vector2.ZERO, size)
	draw_rect(box, plate_fill.darkened(NamePlate.HEAD_DARKEN) if target == Target.HEAD else plate_fill)
	draw_rect(box, NamePlate.BORDER, false, 1.0)
	var font := get_theme_default_font()
	for b in NamePlate.buttons_for(self):
		NamePlate.draw_button(self, font, collapsed_button_rect(b), b, mute if b == NamePlate.MUTE else solo)
	var fs := NamePlate.FONT_SIZE
	var room := maxf(collapsed_button_rect(NamePlate.MUTE).position.x - 12.0, 0.0)
	draw_string(font, Vector2(6.0, size.y * 0.5 + fs * 0.35), collapsed_name(), HORIZONTAL_ALIGNMENT_LEFT, room, fs,
		NamePlate.TEXT if not silenced else Color(NamePlate.TEXT, 0.4))


## The name on the collapsed bar: the plate's lines on one ("Bar 1 · Head 2").
func collapsed_name() -> String:
	return " · ".join(title.split("\n", false))


## An M / S button's rectangle on the collapsed bar: side by side at its
## right end (empty when not collapsed, or without it).
func collapsed_button_rect(which: int) -> Rect2:
	var bs := NamePlate.buttons_for(self)
	var i := bs.find(which)
	if not collapsed or i < 0:
		return Rect2()
	var g := NamePlate.BUTTON_GAP
	var h := minf(NamePlate.BUTTON_HEIGHT, size.y - 2.0 * g)
	var x := size.x - (bs.size() - i) * (COLLAPSED_BUTTON_WIDTH + g)
	return Rect2(x, (size.y - h) * 0.5, COLLAPSED_BUTTON_WIDTH, h)


## The collapsed bar's button at `pos`, or -1.
func collapsed_button_at(pos: Vector2) -> int:
	for b in NamePlate.buttons_for(self):
		if collapsed_button_rect(b).has_point(pos):
			return b
	return -1


## Toggle mute (NamePlate.MUTE) or solo (NamePlate.SOLO), as the user.
func toggle_mix(which: int) -> void:
	if which == NamePlate.MUTE:
		mute = not mute
	else:
		solo = not solo
	mix_toggled.emit(self)


func _get_tooltip(at: Vector2) -> String:
	if not collapsed:
		return tooltip_text
	var b := collapsed_button_at(at)
	return NamePlate.button_tip(self, b) if b >= 0 else "Click to expand"


## The moving selection's ghost on this row: the spot it's leaving
## dimmed, and its content drawn faintly where it would land.
func _draw_ghost(row: Row, r: Rect2) -> void:
	var parts: Array = ghost.get("rows", {}).get(row, [])
	if parts.is_empty():
		return
	var at: float = ghost["at"]
	var from: float = ghost["from"]
	for part in parts:
		var x0 := clampf(_t2x(from + part["t0"]), 0.0, size.x)
		var x1 := clampf(_t2x(from + part["t1"]), 0.0, size.x)
		if x1 > x0:
			draw_rect(Rect2(x0, r.position.y, x1 - x0, r.size.y), _GHOST_DIM)
	for part in parts:
		var start: float = at + part["t0"]
		if part.has("nodes"):
			var line := PackedVector2Array()
			for p in part["nodes"]:
				line.append(Vector2(_t2x(start + p.x), _level_y(r, p.y)))
			if line.size() >= 2:
				var fill := PackedVector2Array(line)
				fill.append(Vector2(line[-1].x, r.end.y))
				fill.append(Vector2(line[0].x, r.end.y))
				draw_colored_polygon(fill, Color(1, 1, 1, _GHOST_FILL_ALPHA))
				for k in range(line.size() - 1):
					draw_dashed_line(line[k], line[k + 1], _GHOST_LINE, 1.5, 4.0)
		if part.has("strobes"):
			_draw_strobe(r, part["strobes"], start, _GHOST_LINE)
		if part.has("positions"):
			_draw_position(r, part["positions"], start, 0.6)
		if part.has("movements"):
			_draw_movement(r, part["movements"], start, 0.6)
		if part.has("segments"):
			for sg in part["segments"]:
				var a := _t2x(start + sg["t0"])
				var b := maxf(_t2x(start + sg["t1"]), a + 1.0)
				var pts := PackedVector2Array([Vector2(a, r.position.y + 1), Vector2(b, r.position.y + 1), Vector2(b, r.end.y), Vector2(a, r.end.y)])
				var c0: Color = sg["c0"]
				var c1: Color = sg["c1"]
				c0.a = _GHOST_COLOUR_ALPHA
				c1.a = _GHOST_COLOUR_ALPHA
				draw_polygon(pts, PackedColorArray([c0, c1, c1, c0]))
		var gx0 := _t2x(start)
		var gx1 := _t2x(at + part["t1"])
		draw_rect(Rect2(gx0, r.position.y, maxf(gx1 - gx0, 1.0), r.size.y), _GHOST_LINE, false, 1.0)


## Over a track left out of playback (muted, or not soloed).
const _SILENCED := Color(0.05, 0.05, 0.07, 0.55)


## The waveform's beat grid behind the rows: the same beat and bar lines
## (thinned out the same way when zoomed out), but quieter than on the
## waveform — thin, and fainter — so they don't compete with the content.
const _GRID_BAR := Color(1, 1, 1, 0.22)
const _GRID_BEAT := Color(1, 1, 1, 0.07)


func _draw_grid() -> void:
	if wave == null or wave.analysis == null:
		return
	var v := _view()
	for line in wave.grid_lines(v.x, v.x + v.y):
		var x: float = line[0]
		draw_line(Vector2(x, 0), Vector2(x, size.y), _GRID_BAR if line[1] else _GRID_BEAT, 1.0)


## This row's selected spans, on `on` (the selection layer): a
## translucent blue fill, edged at each end.
func _draw_selection(on: CanvasItem, row: Row, r: Rect2) -> void:
	if selection == null or not has_meta("key"):
		return
	for span in selection.spans_for(String(get_meta("key")), row):
		if _t2x(span.y) < 0.0 or _t2x(span.x) > size.x:
			continue                    # out of view
		var x0 := clampf(_t2x(span.x), 0.0, size.x)
		var x1 := clampf(_t2x(span.y), 0.0, size.x)
		on.draw_rect(Rect2(x0, r.position.y, maxf(x1 - x0, 1.0), r.size.y), _SELECT_FILL)
		for t in [span.x, span.y]:
			var x := _t2x(t)
			if x >= 0.0 and x <= size.x:
				on.draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), _SELECT_EDGE, 1.0)


## The colour segments in view: a band each, shaded from its start colour
## to its end colour.
func _draw_colour(r: Rect2) -> void:
	var v := _view()
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	for sg in colour_segments:
		if sg["t1"] < v.x or sg["t0"] > v.x + v.y:
			continue
		var a := maxf(sg["t0"], v.x)
		var b := minf(sg["t1"], v.x + v.y)
		var ca: Color = segment_colour_at([sg], a)
		var cb: Color = segment_colour_at([sg], b)
		var x0 := _t2x(a)
		var x1 := maxf(_t2x(b), x0 + 1.0)
		var base := pts.size()
		for q in [Vector2(x0, r.position.y + 1), Vector2(x1, r.position.y + 1), Vector2(x1, r.end.y), Vector2(x0, r.end.y)]:
			pts.append(q)
		for c in [ca, cb, cb, ca]:
			cols.append(c)
		for t in [0, 1, 2, 0, 2, 3]:
			idx.append(base + t)
	if not pts.is_empty():
		RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), idx, pts, cols)


## Strobe segments (offset by `shift` seconds): a line up the row at each
## end, a dashed line between them — at the bottom of the row for slow,
## the middle for medium, the top for fast.
func _draw_strobe(r: Rect2, segs: Array, shift: float, col: Color) -> void:
	var v := _view()
	for sg in segs:
		var mid := strobe_line_y(r, int(sg.get("speed", Strobe.MEDIUM)))
		var a: float = sg["t0"] + shift
		var b: float = sg["t1"] + shift
		if b < v.x or a > v.x + v.y:
			continue
		var x0 := _t2x(a)
		var x1 := _t2x(b)
		for x in [x0, x1]:
			if x >= 0.0 and x <= size.x:
				draw_line(Vector2(x, r.position.y + 1), Vector2(x, r.end.y), col, 1.5)
		var d0 := clampf(x0, 0.0, size.x)
		var d1 := clampf(x1, 0.0, size.x)
		if d1 > d0:
			draw_dashed_line(Vector2(d0, mid), Vector2(d1, mid), col, 1.0, 3.0)


## Position segments (offset by `shift` seconds, at `alpha`): the
## position's triangle in its colour at the start, and a line in that
## colour across the span; grey where the position's been deleted.
func _draw_position(r: Rect2, segs: Array, shift: float, alpha: float) -> void:
	var v := _view()
	var mid := r.position.y + r.size.y * 0.5
	var h := r.size.y - 2.0
	for sg in segs:
		var a: float = sg["t0"] + shift
		var b: float = sg["t1"] + shift
		if b < v.x or a > v.x + v.y:
			continue
		var pos := positions.find(String(sg.get("pos", ""))) if positions != null else {}
		var col: Color = pos["colour"] if not pos.is_empty() else Color(0.55, 0.55, 0.6)
		col.a *= alpha
		var x0 := _t2x(a)
		var x1 := _t2x(b)
		var d0 := clampf(x0 + h * 0.7, 0.0, size.x)
		var d1 := clampf(x1, 0.0, size.x)
		if d1 > d0:
			draw_line(Vector2(d0, mid), Vector2(d1, mid), Color(col.r, col.g, col.b, col.a * 0.7), 2.0)
		if x1 >= 0.0 and x1 <= size.x:
			draw_line(Vector2(x1, r.position.y + 2), Vector2(x1, r.end.y - 1), Color(col.r, col.g, col.b, col.a * 0.7), 1.0)
		if x0 + h >= 0.0 and x0 <= size.x:
			draw_colored_polygon(PackedVector2Array([Vector2(x0, r.position.y + 1), Vector2(x0 + h * 0.85, mid),
				Vector2(x0, r.end.y - 1)]), col)


## Movement segments (offset by `shift` seconds, at `alpha`): the effect's
## shape, small, at the start (a dot for none), and a line across the span
## — dashed for none.
func _draw_movement(r: Rect2, segs: Array, shift: float, alpha: float) -> void:
	var v := _view()
	var mid := r.position.y + r.size.y * 0.5
	var rad := (r.size.y - 2.0) * 0.5
	var col := Color(0.75, 0.85, 1.0, 0.9 * alpha)
	for sg in segs:
		var a: float = sg["t0"] + shift
		var b: float = sg["t1"] + shift
		if b < v.x or a > v.x + v.y:
			continue
		var fx := String(sg.get("fx", "none"))
		var x0 := _t2x(a)
		var x1 := _t2x(b)
		var c := Vector2(x0 + rad + 1.0, mid)
		var d0 := clampf(x0 + 2.0 * rad + 3.0, 0.0, size.x)
		var d1 := clampf(x1, 0.0, size.x)
		if d1 > d0:
			if fx == "none":
				draw_dashed_line(Vector2(d0, mid), Vector2(d1, mid), Color(col.r, col.g, col.b, col.a * 0.6), 1.0, 3.0)
			else:
				draw_line(Vector2(d0, mid), Vector2(d1, mid), Color(col.r, col.g, col.b, col.a * 0.6), 1.0)
		if x1 >= 0.0 and x1 <= size.x:
			draw_line(Vector2(x1, r.position.y + 2), Vector2(x1, r.end.y - 1), Color(col.r, col.g, col.b, col.a * 0.6), 1.0)
		if c.x + rad < 0.0 or c.x - rad > size.x:
			continue
		if fx == "none":
			draw_circle(c, 1.5, col)
			continue
		# The shape itself, traced once round — bigger for a bigger movement.
		var scale := rad * (0.55 + 0.45 * clampf(float(sg.get("size", MOVEMENT_SIZE)) / MOVEMENT_SIZE_MAX, 0.0, 1.0))
		var pts := PackedVector2Array()
		for i in range(25):
			var o := movement_offset({"fx": fx, "period": 1.0, "size": 1.0}, i / 24.0)
			pts.append(c + Vector2(o.x, -o.y) * scale)
		draw_polyline(pts, col, 1.2, true)


## What mute / solo leave playing, worked out once from `tracks` (keys
## "master", a fixture uid, "<uid>/h<n>", each with "mute" / "solo"):
## {solo: whether any track's soloed, solo_fixtures: {uid: true} for each
## fixture soloed or with a soloed head}. For plays().
static func mix_state(tracks: Dictionary) -> Dictionary:
	var any := false
	var fixtures := {}
	for key in tracks:
		if key == "master" or not tracks[key] is Dictionary or not bool(tracks[key].get("solo", false)):
			continue
		any = true
		fixtures[_fixture_of(String(key))] = true
	return {"solo": any, "solo_fixtures": fixtures}


## Whether the track `key` plays, by mute / solo (`mix`: mix_state()):
##   master: unless muted (muted, nothing plays)
##   a fixture: unless it or the master's muted; while any track's soloed,
##     only if it or one of its heads is (it's what they inherit from)
##   a head: unless it, its fixture or the master's muted; while any
##     track's soloed, only if it or its fixture is
static func plays(tracks: Dictionary, mix: Dictionary, key: String) -> bool:
	if _muted(tracks, "master"):
		return false
	if key == "master":
		return true
	var fixture := _fixture_of(key)
	if _muted(tracks, fixture) or (mix["solo"] and not mix["solo_fixtures"].has(fixture)):
		return false
	if key == fixture:
		return true
	return not _muted(tracks, key) and (not mix["solo"] or _soloed(tracks, fixture) or _soloed(tracks, key))


static func _muted(tracks: Dictionary, key: String) -> bool:
	return tracks.get(key) is Dictionary and bool(tracks[key].get("mute", false))


static func _soloed(tracks: Dictionary, key: String) -> bool:
	return tracks.get(key) is Dictionary and bool(tracks[key].get("solo", false))


## The fixture a track key belongs to: a head's ("<uid>/h<n>") its uid,
## otherwise the key itself.
static func _fixture_of(key: String) -> String:
	var i := key.rfind("/h")
	return key.substr(0, i) if i > 0 and key.substr(i + 2).is_valid_int() else key


## The height of a strobe segment's dashed line in the row `r`, by speed.
static func strobe_line_y(r: Rect2, speed: int) -> float:
	match speed:
		Strobe.SLOW:
			return r.end.y - 1.5
		Strobe.FAST:
			return r.position.y + 2.0
	return r.position.y + r.size.y * 0.5


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
	const HEAD_DARKEN := 0.25
	const BORDER := Color(0, 0, 0, 0.6)
	const TEXT := Color(0.85, 0.85, 0.9)
	const FONT_SIZE := 12
	## Shrinks to this to fit a long name before trimming it.
	const MIN_FONT_SIZE := 9

	## The mute / solo buttons along its top.
	enum { MUTE, SOLO }
	const BUTTON_HEIGHT := 14.0
	const BUTTON_GAP := 2.0
	const BUTTON_OFF := Color(0, 0, 0, 0.35)
	const MUTE_ON := Color(0.95, 0.45, 0.2)
	const SOLO_ON := Color(0.95, 0.85, 0.25)
	const BUTTON_TEXT_ON := Color(0.08, 0.08, 0.1)

	var track: TimelineTrack:
		set(v):
			if track != null and track.mix_changed.is_connected(queue_redraw):
				track.mix_changed.disconnect(queue_redraw)
			track = v
			if track != null:
				track.mix_changed.connect(queue_redraw)
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if collapsible() else Control.CURSOR_ARROW
			queue_redraw()
	## The plate's colour: a fixture's model colour (UniversePanel.MODEL_COLOURS).
	var fill := FILL:
		set(v):
			fill = v
			queue_redraw()

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS     # the wheel still scrolls the panel

	## The buttons it has: M, and S (not on the master's).
	func buttons() -> Array:
		return buttons_for(track)

	## The buttons `tr`'s plate (or collapsed bar) has.
	static func buttons_for(tr: TimelineTrack) -> Array:
		if tr == null:
			return []
		return [MUTE] if tr.target == TimelineTrack.Target.MASTER else [MUTE, SOLO]

	## Whether a click on it collapses its track (a fixture's or a head's;
	## not the master's).
	func collapsible() -> bool:
		return track != null and track.target != TimelineTrack.Target.MASTER

	## An M / S button: lit when on, its letter in the middle.
	static func draw_button(on_item: CanvasItem, font: Font, r: Rect2, which: int, on: bool) -> void:
		on_item.draw_rect(r, (MUTE_ON if which == MUTE else SOLO_ON) if on else BUTTON_OFF)
		on_item.draw_rect(r, BORDER, false, 1.0)
		var bfs := clampi(int(r.size.y) - 4, 6, 10)
		var letter := "M" if which == MUTE else "S"
		var lw := font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, bfs).x
		on_item.draw_string(font, Vector2(r.get_center().x - lw * 0.5, r.get_center().y + bfs * 0.35), letter,
			HORIZONTAL_ALIGNMENT_LEFT, -1, bfs, BUTTON_TEXT_ON if on else TEXT)

	## An M / S button's tooltip on `tr`'s plate or bar.
	static func button_tip(tr: TimelineTrack, which: int) -> String:
		if which == MUTE:
			return "Mute: leave out of playback" + (" (every fixture)" if tr.target == TimelineTrack.Target.MASTER
				else " (its heads too)" if tr.target == TimelineTrack.Target.FIXTURE else "")
		return "Solo: play only this" + (" fixture (its unmuted heads too)" if tr.target == TimelineTrack.Target.FIXTURE
			else " head")

	## A button's rectangle: side by side across the top, as tall as the
	## plate allows (a lone 10 px row's plate has them small).
	func button_rect(which: int) -> Rect2:
		var bs := buttons()
		var i := bs.find(which)
		if i < 0:
			return Rect2()
		var h := minf(BUTTON_HEIGHT, maxf(size.y - 2.0 * BUTTON_GAP, 4.0))
		var w := (size.x - BUTTON_GAP * (bs.size() + 1)) / bs.size()
		return Rect2(BUTTON_GAP + i * (w + BUTTON_GAP), BUTTON_GAP, w, h)

	## The button at `pos`, or -1.
	func button_at(pos: Vector2) -> int:
		for b in buttons():
			if button_rect(b).has_point(pos):
				return b
		return -1

	## The space below the buttons, where the name goes.
	func name_rect() -> Rect2:
		var top := button_rect(MUTE).end.y if track != null else 0.0
		return Rect2(0.0, top, size.x, maxf(size.y - top, 0.0))

	## A press on M / S toggles it; anywhere else on a fixture's or head's
	## plate collapses its track.
	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var b := button_at(event.position)
			if b >= 0:
				track.toggle_mix(b)
				accept_event()
			elif collapsible():
				track.collapsed = true
				track.collapse_toggled.emit(track)
				accept_event()

	func _get_tooltip(at: Vector2) -> String:
		var b := button_at(at)
		if b >= 0:
			return button_tip(track, b)
		return "Click to collapse" if collapsible() else ""

	func title() -> String:
		return track.title if track != null else ""

	## The name's lines (a title can hold "\n" breaks).
	func lines() -> PackedStringArray:
		return title().split("\n", false)

	## The font size the name's drawn at: FONT_SIZE, or the largest down
	## to MIN_FONT_SIZE at which its longest line fits the plate's height.
	func font_size() -> int:
		var font := get_theme_default_font()
		var room := maxf(name_rect().size.y - 8.0, 0.0)
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
		draw_rect(Rect2(Vector2.ZERO, size), fill.darkened(HEAD_DARKEN) if head else fill)
		draw_rect(Rect2(Vector2.ZERO, size), BORDER, false, 1.0)
		var font := get_theme_default_font()
		for b in buttons():
			draw_button(self, font, button_rect(b), b, track.mute if b == MUTE else track.solo)
		var text := lines()
		if text.is_empty():
			return
		var nr := name_rect()
		# Rotate a quarter turn anticlockwise about the centre of the space
		# below the buttons, then
		# centre the text on it (its length runs up the plate; each further
		# line sits to the right of the one before). A smaller font if that
		# makes it fit the plate's height, else trimmed.
		var room := maxf(nr.size.y - 8.0, 0.0)
		var fs := font_size()
		var line_h := font.get_height(fs)
		var y := -line_h * text.size() * 0.5 + font.get_ascent(fs)
		var colour := TEXT if not track.silenced else Color(TEXT, 0.4)
		draw_set_transform(nr.get_center(), -PI * 0.5)
		for line in text:
			var w := minf(font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x, room)
			draw_string(font, Vector2(-w * 0.5, y), line, HORIZONTAL_ALIGNMENT_LEFT, room, fs, colour)
			y += line_h
		draw_set_transform(Vector2.ZERO)


## The selected areas over a track's rows: their own layer, so changing
## the selection (every pointer move while dragging one out) doesn't
## redraw the rows beneath.
class SelectionLayer:
	extends Control

	var track: TimelineTrack

	func _draw() -> void:
		if track.collapsed:
			return
		for row in track.rows:
			track._draw_selection(self, row, track.row_rect(row))


## The playhead line over a track's rows (as on the waveform): its own
## layer, so moving it doesn't redraw the rows beneath.
class Playhead:
	extends Control

	var track: TimelineTrack

	func _draw() -> void:
		if track.collapsed:
			return
		var x := track.playhead_x()
		if x >= 0.0:
			draw_line(Vector2(x, 0), Vector2(x, size.y), track.wave.cursor_color, 2.0)
