class_name PaletteLibrary
extends RefCounted
## The show's palettes: named colours, positions and beam looks, each a
## set of channel values per fixture, that cues refer to instead of holding
## the values themselves — so changing a palette changes every cue that
## uses it.
##
## A palette's kind picks the channel roles it holds (KIND_ROLES; a fine
## channel goes with its coarse one). Its values are per fixture uid, by
## channel offset from the fixture's start: {uid: {"<offset>": value}} —
## so it follows the fixture when it's re-patched to another address.
##
## Cues link to palettes when they're recorded (CueListPanel): a fixture
## whose channels of a kind exactly match a palette's for it gets a
## reference to the palette (Cue.refs) instead of the values. Playback
## resolves the reference to the palette's values as they are now.

## A palette added, changed, renamed or removed.
signal changed

enum { COLOUR, POSITION, BEAM }
const KINDS := ["Colour", "Position", "Beam"]
## Saved by name.
const KIND_KEYS := ["colour", "position", "beam"]
const KIND_ROLES := [
	["RED", "GREEN", "BLUE", "WHITE", "AMBER", "UV", "COLOR_WHEEL"],
	["PAN", "PAN_FINE", "TILT", "TILT_FINE"],
	["ZOOM", "GOBO", "GOBO_ROT"],
]


class Palette:
	var id := ""
	var name := ""
	var kind: int = COLOUR
	var values := {}            # uid -> {"<offset>": value}

	func to_dict() -> Dictionary:
		return {"id": id, "name": name, "kind": KIND_KEYS[kind], "values": values.duplicate(true)}

	static func from_dict(d: Dictionary) -> Palette:
		var p := Palette.new()
		p.id = String(d.get("id", ""))
		p.name = String(d.get("name", "Palette"))
		p.kind = maxi(KIND_KEYS.find(String(d.get("kind", "colour"))), 0)
		var v = d.get("values", {})
		if v is Dictionary:
			for uid in v:
				var per := {}
				if v[uid] is Dictionary:
					for k in v[uid]:
						per[str(int(k))] = clampi(int(v[uid][k]), 0, 255)
				p.values[String(uid)] = per
		return p


var palettes: Array[Palette] = []
var _next_id := 1


## A fixture's channel offsets of `kind` (fine channels included).
static func offsets(fixture: Dictionary, kind: int) -> Array:
	var out: Array = []
	var profile: FixtureProfile = fixture["profile"]
	var chans := profile.channels_for_mode(int(fixture.get("mode", 0)))
	for k in range(chans.size()):
		if String(chans[k]["role"]) in KIND_ROLES[kind]:
			out.append(k)
	return out


func find(id: String) -> Palette:
	for p in palettes:
		if p.id == id:
			return p
	return null


func of_kind(kind: int) -> Array:
	return palettes.filter(func(p): return p.kind == kind)


## A new palette of `kind` called `name`, from `fixtures`' channels of that
## kind in `bases` (per universe, the live buffers). Fixtures without any
## such channels aren't in it. Null if none of them has any.
func record(kind: int, name_: String, fixtures: Array, bases: Array) -> Palette:
	var p := Palette.new()
	p.kind = kind
	p.name = name_
	_capture(p, fixtures, bases)
	if p.values.is_empty():
		return null
	p.id = "p%d" % _next_id
	_next_id += 1
	palettes.append(p)
	changed.emit()
	return p


## Re-record `p` from `bases`: every fixture it holds that's in
## `fixtures`, and any of `fixtures` it doesn't hold yet.
func update(p: Palette, fixtures: Array, bases: Array) -> void:
	_capture(p, fixtures, bases)
	changed.emit()


func _capture(p: Palette, fixtures: Array, bases: Array) -> void:
	for fx in fixtures:
		var offs := offsets(fx, p.kind)
		if offs.is_empty():
			continue
		var base: PackedByteArray = bases[int(fx["u"])] if int(fx["u"]) < bases.size() else PackedByteArray()
		var per := {}
		for o in offs:
			var c := int(fx["start"]) + int(o)
			per[str(o)] = int(base[c]) if c < base.size() else 0
		p.values[String(fx["uid"])] = per


func rename(p: Palette, name_: String) -> void:
	p.name = name_
	changed.emit()


func remove(p: Palette) -> void:
	palettes.erase(p)
	changed.emit()


## The palette of `kind` that `fixture`'s channels of that kind in `base`
## (its universe's buffer) match exactly ("" if none does).
func match_fixture(kind: int, fixture: Dictionary, base: PackedByteArray) -> String:
	var uid := String(fixture["uid"])
	var offs := offsets(fixture, kind)
	if offs.is_empty():
		return ""
	for p in palettes:
		if p.kind != kind or not p.values.has(uid):
			continue
		var per: Dictionary = p.values[uid]
		var same := per.size() == offs.size()
		for o in offs:
			if not same:
				break
			var c := int(fixture["start"]) + int(o)
			same = per.has(str(o)) and int(per[str(o)]) == (int(base[c]) if c < base.size() else 0)
		if same:
			return p.id
	return ""


## Palette `id`'s values for the fixture `fixture`, as {channel: value} in
## its universe ({} if the palette's gone or doesn't hold the fixture).
func channels_for(id: String, fixture: Dictionary) -> Dictionary:
	var p := find(id)
	var out := {}
	if p == null or not p.values.has(String(fixture["uid"])):
		return out
	var per: Dictionary = p.values[String(fixture["uid"])]
	for o in per:
		out[int(fixture["start"]) + int(o)] = int(per[o])
	return out


## `bases` (per universe) with palette `p` applied to `fixtures` — the
## ones it holds — for loading into the fixture controls.
func applied(p: Palette, fixtures: Array, bases: Array) -> Array:
	var out: Array = []
	for b in bases:
		out.append((b as PackedByteArray).duplicate())
	for fx in fixtures:
		var u := int(fx["u"])
		if u >= out.size():
			continue
		var chans := channels_for(p.id, fx)
		for c in chans:
			if c < out[u].size():
				out[u][c] = chans[c]
	return out


## A colour to show palette `p` as: a colour palette's first fixture's
## red / green / blue (brightened to full), or its colour wheel slot's; null
## for other kinds or when there's nothing to go on.
func swatch(p: Palette, fixtures: Array):
	if p.kind != COLOUR:
		return null
	for fx in fixtures:
		var uid := String(fx["uid"])
		if not p.values.has(uid):
			continue
		var per: Dictionary = p.values[uid]
		var profile: FixtureProfile = fx["profile"]
		var chans := profile.channels_for_mode(int(fx.get("mode", 0)))
		var rgb := Vector3(-1, -1, -1)
		var w := 0
		for o in per:
			var k := int(o)
			if k >= chans.size():
				continue
			match String(chans[k]["role"]):
				"RED": rgb.x = int(per[o])
				"GREEN": rgb.y = int(per[o])
				"BLUE": rgb.z = int(per[o])
				"WHITE": w = maxi(w, int(per[o]))
				"COLOR_WHEEL":
					if not bool(chans[k].get("fine", false)):
						var wc = DmxRender._slot_color(chans[k], int(per[o]))
						if wc != null:
							return wc
		if rgb.x >= 0 and rgb.y >= 0 and rgb.z >= 0:
			var c := Color(maxf(rgb.x, w) / 255.0, maxf(rgb.y, w) / 255.0, maxf(rgb.z, w) / 255.0)
			var top := maxf(c.r, maxf(c.g, c.b))
			return Color(c.r / top, c.g / top, c.b / top) if top > 0.0 else Color.BLACK
	return null


func to_dict() -> Dictionary:
	var arr: Array = []
	for p in palettes:
		arr.append(p.to_dict())
	return {"palettes": arr, "next_id": _next_id}


func from_dict(d: Dictionary) -> void:
	palettes.clear()
	for e in d.get("palettes", []):
		if e is Dictionary:
			var p := Palette.from_dict(e)
			if p.id != "":
				palettes.append(p)
	_next_id = int(d.get("next_id", 1))
	for p in palettes:                    # never reuse an id the show has
		if p.id.begins_with("p") and p.id.substr(1).is_valid_int():
			_next_id = maxi(_next_id, p.id.substr(1).to_int() + 1)
	changed.emit()
