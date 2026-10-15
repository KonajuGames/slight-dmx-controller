class_name PositionLibrary
extends RefCounted
## A show's named positions for moving fixtures: each a name, a colour of
## its own (shown as its icon), and a pan / tilt per fixture — keyed by
## the fixture's uid, normalised 0..1 over the axis' whole range (as the
## XY pads use), tilt bottom-up. Saved with the show (to_dict / from_dict).
##
##   positions: [{id, name, colour: Color, points: {uid: Vector2(pan, tilt)}}]

## Something about the positions changed (added, renamed, a point moved).
signal changed

## Where a fixture with no point of its own in a position is shown: centred.
const DEFAULT_POINT := Vector2(0.5, 0.5)
## Hues step round by the golden ratio, so each new position's colour is
## well away from the ones before it.
const _GOLDEN := 0.6180339887

var positions: Array = []
var _next := 0                  # the next new position's number / hue index


## Add a new position ("Position N", the next unused colour). Returns it.
func add() -> Dictionary:
	_next += 1
	var p := {"id": "p%d_%08x" % [_next, randi()], "name": "Position %d" % _next,
		"colour": colour_for(_next - 1), "points": {}}
	positions.append(p)
	changed.emit()
	return p


## The `n`th position's colour: a fully saturated, bright hue stepping
## round the wheel by the golden ratio — no two the same.
static func colour_for(n: int) -> Color:
	return Color.from_hsv(fmod(0.08 + n * _GOLDEN, 1.0), 0.75, 1.0)


func find(id: String) -> Dictionary:
	for p in positions:
		if p["id"] == id:
			return p
	return {}


## A copy of position `id` — its points, "<name> copy", the next colour —
## added after it. Returns the copy ({} if there's no such position).
func duplicate_position(id: String) -> Dictionary:
	var src := find(id)
	if src.is_empty():
		return {}
	_next += 1
	var p := {"id": "p%d_%08x" % [_next, randi()], "name": "%s copy" % src["name"],
		"colour": colour_for(_next - 1), "points": (src["points"] as Dictionary).duplicate()}
	positions.insert(positions.find(src) + 1, p)
	changed.emit()
	return p


## Delete position `id`.
func remove(id: String) -> void:
	for i in range(positions.size()):
		if positions[i]["id"] == id:
			positions.remove_at(i)
			changed.emit()
			return


func rename(id: String, new_name: String) -> void:
	var p := find(id)
	new_name = new_name.strip_edges()
	if p.is_empty() or new_name == "" or new_name == p["name"]:
		return
	p["name"] = new_name
	changed.emit()


## A fixture's pan / tilt in a position (DEFAULT_POINT if it has none).
func point(id: String, uid: String) -> Vector2:
	var p := find(id)
	return p.get("points", {}).get(uid, DEFAULT_POINT) if not p.is_empty() else DEFAULT_POINT


func set_point(id: String, uid: String, v: Vector2) -> void:
	var p := find(id)
	if p.is_empty():
		return
	p["points"][uid] = v.clamp(Vector2.ZERO, Vector2.ONE)
	changed.emit()


func clear() -> void:
	positions.clear()
	_next = 0
	changed.emit()


# ------------------------------------------------------- SERIALIZATION --

func to_dict() -> Dictionary:
	var out: Array = []
	for p in positions:
		var pts := {}
		for uid in p["points"]:
			var v: Vector2 = p["points"][uid]
			pts[uid] = [snappedf(v.x, 0.0001), snappedf(v.y, 0.0001)]
		out.append({"id": p["id"], "name": p["name"], "colour": (p["colour"] as Color).to_html(false), "points": pts})
	return {"positions": out, "next": _next}


func from_dict(d: Dictionary) -> void:
	positions.clear()
	for e in d.get("positions", []):
		if not e is Dictionary:
			continue
		var pts := {}
		var src = e.get("points", {})
		if src is Dictionary:
			for uid in src:
				var a = src[uid]
				if a is Array and a.size() >= 2:
					pts[String(uid)] = Vector2(float(a[0]), float(a[1])).clamp(Vector2.ZERO, Vector2.ONE)
		positions.append({"id": String(e.get("id", "p%08x" % randi())), "name": String(e.get("name", "Position")),
			"colour": Color.from_string(String(e.get("colour", "")), colour_for(positions.size())), "points": pts})
	_next = maxi(int(d.get("next", 0)), positions.size())
	changed.emit()
