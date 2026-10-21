class_name TimelineSelection
extends RefCounted
## The selected areas of a track's lighting timelines: a list of blocks,
## each a time span across a set of rows. A row is named by its track's
## key ("master", a fixture uid, "<uid>/h<n>") and its TimelineTrack.Row,
## as row_id() — so a block can cover rows of several tracks, and still
## means the same rows after the patch is refreshed.
##
##   blocks: [{rows: PackedStringArray of row ids, t0: float, t1: float}]

signal changed

var blocks: Array = []:
	set(v):
		blocks = v
		_by_row = {}
# Each row id's spans, [Vector2(t0, t1), ...], built from `blocks` when
# first asked for after they change (spans_for is called per row, per
# track, on every redraw and pointer move).
var _by_row := {}


static func row_id(track_key: String, row: int) -> String:
	return "%s|%d" % [track_key, row]


static func block(rows: PackedStringArray, t0: float, t1: float) -> Dictionary:
	return {"rows": rows, "t0": minf(t0, t1), "t1": maxf(t0, t1)}


func is_empty() -> bool:
	return blocks.is_empty()


func clear() -> void:
	if blocks.is_empty():
		return
	blocks.clear()
	_by_row = {}
	changed.emit()


func set_blocks(b: Array) -> void:
	blocks = b
	changed.emit()


## The selected time spans on one row, as [Vector2(t0, t1), ...].
func spans_for(track_key: String, row: int) -> Array:
	if _by_row.is_empty() and not blocks.is_empty():
		for b in blocks:
			for id in b["rows"]:
				if not _by_row.has(id):
					_by_row[id] = []
				_by_row[id].append(Vector2(b["t0"], b["t1"]))
	return (_by_row.get(row_id(track_key, row), []) as Array).duplicate()


## Whether time `t` on a row is selected.
func has(track_key: String, row: int, t: float) -> bool:
	for s in spans_for(track_key, row):
		if t >= s.x and t <= s.y:
			return true
	return false
