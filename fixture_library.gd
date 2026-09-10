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
##
## `refresh_online()` additionally pulls the *current* OFL fixture list
## straight from GitHub (one request); `get_profile()` then downloads and
## converts an online-only fixture on demand, caching the result under
## `user://fixture_online/` so it works offline afterwards.

const INDEX_PATH := "res://fixtures/index.json"
const SHARD_DIR := "res://fixtures/lib"

## OFL on GitHub. The tree call lists every fixture path in one request;
## raw.githubusercontent serves the individual files (no API rate limit).
const OFL_TREE_URL := "https://api.github.com/repos/OpenLightingProject/open-fixture-library/git/trees/master?recursive=1"
const OFL_RAW := "https://raw.githubusercontent.com/OpenLightingProject/open-fixture-library/master/fixtures/"
const ONLINE_CACHE := "user://fixture_online"
const _UA := "sLight-fixture-library"

var _entries: Array = []            ## catalogue rows, each with a cached "_hay"
var _by_id: Dictionary = {}         ## id -> entry
var _makers: PackedStringArray = [] ## sorted, unique
var _cats: PackedStringArray = []   ## sorted, unique (app categories)
var _meta: Dictionary = {}          ## { generated, count, ofl_commit, ... }

var _shard_cache: Dictionary = {}   ## manufacturer key -> { id: profile_dict }
var _profile_cache: Dictionary = {} ## id -> FixtureProfile

var _online: Array = []             ## same row shape as _entries; modes/cat empty
var _online_by_id: Dictionary = {}
var _online_makers: PackedStringArray = []
var _online_loaded := false
var _online_error := ""
var _last_http := ""


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
	return _by_id.get(id, _online_by_id.get(id, {}))


## The full FixtureProfile for a catalogue id, synchronously: a bundled
## fixture (lazy-loads its manufacturer shard) or an online one already
## downloaded this or a past session (from user://fixture_online/). Returns
## null for an online fixture not yet fetched — use `get_profile()` for that.
func resolve(id: String) -> FixtureProfile:
	if _profile_cache.has(id):
		return _profile_cache[id]
	var e = _by_id.get(id, null)
	if e != null:
		var shard := _load_shard(String(e["shard"]))
		if not shard.has(id):
			return null
		var p := FixtureProfile.from_dict(shard[id])
		_profile_cache[id] = p
		return p
	var cpath := "%s/%s.json" % [ONLINE_CACHE, id]
	if FileAccess.file_exists(cpath):
		var cf := FileAccess.open(cpath, FileAccess.READ)
		var cd = JSON.parse_string(cf.get_as_text())
		cf.close()
		if cd is Dictionary:
			var cp := FixtureProfile.from_dict(cd)
			_profile_cache[id] = cp
			return cp
	return null


## Like resolve(), but for an online-only fixture it downloads and converts
## it on demand (and caches it). Coroutine — `await` it.
func get_profile(id: String) -> FixtureProfile:
	var p := resolve(id)
	if p != null:
		return p
	return await _download_online(id)


# ==================================================== ONLINE (OFL / GitHub) ==

func online_ready() -> bool:
	return _online_loaded


func online_error() -> String:
	return _online_error


func online_count() -> int:
	return _online.size()


func online_manufacturers() -> PackedStringArray:
	return _online_makers


## Files sitting in the on-disk online cache.
func cached_online_count() -> int:
	var d := DirAccess.open(ONLINE_CACHE)
	if d == null:
		return 0
	var n := 0
	for f in d.get_files():
		if f.ends_with(".json"):
			n += 1
	return n


func clear_online_cache() -> void:
	var d := DirAccess.open(ONLINE_CACHE)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	for id in _online_by_id.keys():
		_profile_cache.erase(id)


## Pull the current OFL fixture list from GitHub (one tree request plus
## manufacturers.json for the display names). Coroutine — `await` it.
## Returns true on success; otherwise see `online_error()`.
func refresh_online() -> bool:
	_online_error = ""
	var tree = await _http_json(OFL_TREE_URL, ["User-Agent: " + _UA])
	if not (tree is Dictionary) or not (tree.get("tree", null) is Array):
		_online_error = "couldn't reach GitHub (%s)" % _last_http
		return false
	var names := await _online_maker_names()

	_online.clear()
	_online_by_id.clear()
	var makers := {}
	for node in tree["tree"]:
		var path := String((node as Dictionary).get("path", ""))
		if not path.begins_with("fixtures/") or not path.ends_with(".json"):
			continue
		if path == "fixtures/manufacturers.json":
			continue
		var rel := path.substr(9)                # "<manufacturer>/<key>.json"
		var slash := rel.find("/")
		if slash < 1:
			continue
		var mkey := rel.substr(0, slash)
		var stem := rel.substr(slash + 1).get_basename()
		var id := _san(mkey + "-" + stem)
		var maker := String(names.get(mkey, mkey.capitalize()))
		var model := stem.replace("-", " ").capitalize()
		var e := {
			"id": id, "maker": maker, "model": model,
			"name": "%s %s" % [maker, model],
			"cat": "", "ofl_cat": [], "modes": [], "pt": false, "approx": 0,
			"authors": [], "shard": "", "online": true,
			"bundled": _by_id.has(id), "path": rel,
			"_hay": ("%s %s" % [maker, model]).to_lower(),
		}
		_online.append(e)
		_online_by_id[id] = e
		makers[maker] = true

	_online.sort_custom(func(a, b):
		if a["maker"] != b["maker"]:
			return a["maker"].naturalnocasecmp_to(b["maker"]) < 0
		return a["model"].naturalnocasecmp_to(b["model"]) < 0)
	_online_makers = PackedStringArray(makers.keys())
	_online_makers.sort()
	_online_loaded = true
	return true


func online_entry(id: String) -> Dictionary:
	return _online_by_id.get(id, {})


## Online rows matching a text query (+ optional manufacturer). No category
## / channel-count filtering — that data isn't known until a fixture is
## downloaded.
func search_online(text := "", maker := "") -> Array:
	var terms := text.strip_edges().to_lower().split(" ", false)
	var out: Array = []
	for e in _online:
		if maker != "" and e["maker"] != maker:
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


# --------------------------------------------------------------- internal --

func _download_online(id: String) -> FixtureProfile:
	var e = _online_by_id.get(id, null)
	if e == null:
		_online_error = "unknown fixture id"
		return null
	var parsed = await _http_json(OFL_RAW + String(e["path"]), [])
	# OFL keeps redirect stubs for renamed fixtures — follow one hop.
	if parsed is Dictionary and parsed.has("redirectTo"):
		parsed = await _http_json(OFL_RAW + String(parsed["redirectTo"]) + ".json", [])
	if not (parsed is Dictionary):
		_online_error = "download failed (%s)" % _last_http
		return null
	var res: Dictionary = FixtureImport.from_ofl(parsed)
	if res.has("error"):
		_online_error = res["error"]
		return null
	var prof: FixtureProfile = res["profile"]
	prof.id = id
	prof.profile_name = "%s %s" % [e["maker"], String(parsed.get("name", e["model"]))]
	e["model"] = String(parsed.get("name", e["model"]))
	e["name"] = prof.profile_name
	DirAccess.make_dir_recursive_absolute(ONLINE_CACHE)
	var cf := FileAccess.open("%s/%s.json" % [ONLINE_CACHE, id], FileAccess.WRITE)
	if cf:
		cf.store_string(JSON.stringify(prof.to_dict()))
		cf.close()
	_profile_cache[id] = prof
	return prof


func _online_maker_names() -> Dictionary:
	var d = await _http_json(OFL_RAW + "manufacturers.json", [])
	var out := {}
	if d is Dictionary:
		for k in d:
			if d[k] is Dictionary and d[k].has("name"):
				var nm := String(d[k]["name"])
				if nm.to_lower() == String(k).to_lower():
					nm = String(k).capitalize()
				out[k] = nm
	return out


## One-shot HTTP GET returning parsed JSON, or null (with `_last_http` set).
func _http_json(url: String, headers: Array):
	var req := HTTPRequest.new()
	req.timeout = 20.0
	add_child(req)
	var err := req.request(url, PackedStringArray(headers))
	if err != OK:
		req.queue_free()
		_last_http = "request error %d" % err
		return null
	var r = await req.request_completed
	req.queue_free()
	if int(r[0]) != HTTPRequest.RESULT_SUCCESS:
		_last_http = "connection failed (%d)" % int(r[0])
		return null
	var code := int(r[1])
	if code < 200 or code >= 300:
		_last_http = "HTTP %d" % code
		return null
	return JSON.parse_string((r[3] as PackedByteArray).get_string_from_utf8())


## id-safe key, identical to tools/build_fixture_library.gd so an online id
## matches its bundled counterpart.
func _san(s: String) -> String:
	var o := ""
	for ch in s.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "-":
			o += ch
		else:
			o += "-"
	while o.contains("--"):
		o = o.replace("--", "-")
	return o.strip_edges().trim_prefix("-").trim_suffix("-")


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
