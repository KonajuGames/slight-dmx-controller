extends Node
## Autoload singleton: "Library"
##
## The bundled fixture library — ~640 real fixtures converted from the Open
## Fixture Library project (see `res://fixtures/ATTRIBUTION.md`, regenerated
## by `tools/build_fixture_library.gd`).
##
## `res://fixtures/index.json` is a small always-resident catalogue (id,
## manufacturer, model, category, per-mode channel counts). The full
## `FixtureProfile` for a fixture lives in a per-manufacturer shard
## (`res://fixtures/lib/<manufacturer>.json`) that is loaded and cached the
## first time something from that manufacturer is resolved — the 640
## profiles never all instantiate.

const INDEX_PATH := "res://fixtures/index.json"
const SHARD_DIR := "res://fixtures/lib"

var _entries: Array = []            ## catalogue rows, each with a cached "_hay"
var _by_id: Dictionary = {}         ## id -> entry
var _makers: PackedStringArray = [] ## sorted, unique
var _cats: PackedStringArray = []   ## sorted, unique (app categories)
var _meta: Dictionary = {}          ## { generated, count, ofl_commit, ... }

var _shard_cache: Dictionary = {}   ## manufacturer key -> { id: profile_dict }
var _profile_cache: Dictionary = {} ## id -> FixtureProfile


func _ready() -> void:
	_load_index()


func available() -> bool:
	return not _entries.is_empty()


func count() -> int:
	return _entries.size()


func manufacturers() -> PackedStringArray:
	return _makers


## App-level categories present in the library (moving_head / par / ...).
func categories() -> PackedStringArray:
	return _cats


## Human note for the browser footer, e.g. "638 fixtures · OFL 6c52a67 · 2026-09-11".
func source_note() -> String:
	if not available():
		return "no bundled library found"
	var parts: Array = ["%d fixtures" % _entries.size()]
	if _meta.has("ofl_commit"):
		parts.append("OFL %s" % String(_meta["ofl_commit"]).substr(0, 7))
	if _meta.has("generated"):
		parts.append(String(_meta["generated"]).substr(0, 10))
	return " · ".join(parts)


## Catalogue rows matching every given filter, in catalogue order
## (manufacturer then model). Entries are the raw index dicts — read-only.
##   text        space-separated terms, all must match maker/model/ofl category
##   maker       exact manufacturer name, or "" for any
##   category    exact app category, or "" for any
##   max_ch      keep fixtures with at least one mode this wide or narrower (0 = any)
##   needs_pt    keep only fixtures that have Pan and Tilt somewhere
func search(text := "", maker := "", category := "", max_ch := 0, needs_pt := false) -> Array:
	var terms := text.strip_edges().to_lower().split(" ", false)
	var out: Array = []
	for e in _entries:
		if maker != "" and e["maker"] != maker:
			continue
		if category != "" and e["cat"] != category:
			continue
		if needs_pt and not e["pt"]:
			continue
		if max_ch > 0 and _narrowest_mode(e) > max_ch:
			continue
		if terms.size() > 0:
			var hay: String = e["_hay"]
			var miss := false
			for t in terms:
				if not hay.contains(t):
					miss = true
					break
			if miss:
				continue
		out.append(e)
	return out


func entry(id: String) -> Dictionary:
	return _by_id.get(id, {})


## The full FixtureProfile for a catalogue id (lazy-loads + caches the
## manufacturer shard). Returns null if the id isn't in the library or the
## shard is missing.
func resolve(id: String) -> FixtureProfile:
	if _profile_cache.has(id):
		return _profile_cache[id]
	var e = _by_id.get(id, null)
	if e == null:
		return null
	var shard := _load_shard(String(e["shard"]))
	if not shard.has(id):
		return null
	var p := FixtureProfile.from_dict(shard[id])
	_profile_cache[id] = p
	return p


# --------------------------------------------------------------- internal --

func _load_index() -> void:
	_entries.clear()
	_by_id.clear()
	if not FileAccess.file_exists(INDEX_PATH):
		return
	var f := FileAccess.open(INDEX_PATH, FileAccess.READ)
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary) or not parsed.has("fixtures"):
		push_warning("Library: %s is malformed" % INDEX_PATH)
		return

	_meta = {}
	for k in ["generated", "count", "ofl_commit", "source"]:
		if parsed.has(k):
			_meta[k] = parsed[k]

	var makers := {}
	var cats := {}
	for e in parsed["fixtures"]:
		if not (e is Dictionary) or not e.has("id"):
			continue
		var ofl_cat: Array = e.get("ofl_cat", [])
		e["_hay"] = (String(e.get("maker", "")) + " " + String(e.get("model", "")) + " "
			+ " ".join(ofl_cat)).to_lower()
		_entries.append(e)
		_by_id[String(e["id"])] = e
		makers[String(e.get("maker", "?"))] = true
		cats[String(e.get("cat", "generic"))] = true

	_makers = PackedStringArray(makers.keys())
	_makers.sort()
	_cats = PackedStringArray(cats.keys())
	_cats.sort()


func _load_shard(mkey: String) -> Dictionary:
	if _shard_cache.has(mkey):
		return _shard_cache[mkey]
	var path := "%s/%s.json" % [SHARD_DIR, mkey]
	var shard := {}
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		var parsed = JSON.parse_string(f.get_as_text())
		f.close()
		if parsed is Dictionary:
			shard = parsed
	else:
		push_warning("Library: missing shard %s" % path)
	_shard_cache[mkey] = shard
	return shard


func _narrowest_mode(e: Dictionary) -> int:
	var best := 1 << 20
	for m in e.get("modes", []):
		best = mini(best, int(m.get("ch", 0)))
	return best if best < (1 << 20) else 0
