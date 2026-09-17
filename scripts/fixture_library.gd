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
##
## A second live source, GDTF-Share (gdtf-share.com), works the same way
## but needs a (free) account — `gdtf_login()` exchanges a username/password
## for a session cookie. Unlike everything else here, **neither the
## password nor the cookie is ever written to disk**: both live only in
## this autoload's memory for the running session (`_gdtf_cookie`,
## `_gdtf_user`) and are gone the moment the app closes, so logging in is
## a once-per-launch step. Only the *downloaded fixtures* get the usual
## on-disk cache under `user://fixture_online/` (prefixed `gdtf-`) — that's
## public fixture data, not a credential.

const INDEX_PATH := "res://fixtures/index.json"
const SHARD_DIR := "res://fixtures/lib"

## OFL on GitHub. The tree call lists every fixture path in one request;
## raw.githubusercontent serves the individual files (no API rate limit).
const OFL_TREE_URL := "https://api.github.com/repos/OpenLightingProject/open-fixture-library/git/trees/master?recursive=1"
const OFL_RAW := "https://raw.githubusercontent.com/OpenLightingProject/open-fixture-library/master/fixtures/"
const ONLINE_CACHE := "user://fixture_online"
const _UA := "sLight-fixture-library"

## GDTF-Share's public API (login required). See
## https://github.com/mvrdevelopment/tools/blob/main/GDTF_Share_API —
## login.php sets a session cookie (~2h) that getList.php/downloadFile.php
## expect back as a `Cookie:` header (HTTPRequest doesn't manage cookies
## itself, unlike a browser, so this class extracts and resends it by hand).
const GDTF_LOGIN_URL := "https://gdtf-share.com/apis/public/login.php"
const GDTF_LIST_URL := "https://gdtf-share.com/apis/public/getList.php"
const GDTF_DOWNLOAD_URL := "https://gdtf-share.com/apis/public/downloadFile.php"
const GDTF_TMP := "user://fixture_online/_gdtf_download.tmp"

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

## GDTF-Share — session-only, never persisted (see class doc comment).
var _gdtf_cookie := ""              ## "" until gdtf_login() succeeds
var _gdtf_user := ""                ## for display only ("logged in as ...")
var _gdtf_online: Array = []        ## same row shape as _online; ids "gdtf-..."
var _gdtf_online_by_id: Dictionary = {}
var _gdtf_online_makers: PackedStringArray = []
var _gdtf_loaded := false
var _gdtf_error := ""


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
	if _by_id.has(id):
		return _by_id[id]
	if _online_by_id.has(id):
		return _online_by_id[id]
	return _gdtf_online_by_id.get(id, {})


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
	if id.begins_with("gdtf-"):
		return await _download_gdtf(id)
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


## Files sitting in the on-disk online cache (OFL fixtures only — GDTF's
## share the same directory but are counted by cached_gdtf_count()).
func cached_online_count() -> int:
	var d := DirAccess.open(ONLINE_CACHE)
	if d == null:
		return 0
	var n := 0
	for f in d.get_files():
		if f.ends_with(".json") and not f.begins_with("gdtf-"):
			n += 1
	return n


func clear_online_cache() -> void:
	var d := DirAccess.open(ONLINE_CACHE)
	if d == null:
		return
	for f in d.get_files():
		if not f.begins_with("gdtf-"):
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


# ==================================================== GDTF-SHARE ==

func gdtf_logged_in() -> bool:
	return _gdtf_cookie != ""


## For display only ("logged in as ..."); "" when not logged in.
func gdtf_username() -> String:
	return _gdtf_user


func gdtf_error() -> String:
	return _gdtf_error


func gdtf_ready() -> bool:
	return _gdtf_loaded


func gdtf_online_count() -> int:
	return _gdtf_online.size()


func gdtf_online_manufacturers() -> PackedStringArray:
	return _gdtf_online_makers


## Exchanges a GDTF-Share username/password for a session cookie. Neither
## is written to disk: `password` is used only for this one request and
## then discarded; `user`/the cookie are kept in memory for the rest of
## the running session (gone on the next launch — log in again then).
## Coroutine — `await` it. Returns true on success; otherwise see
## gdtf_error().
func gdtf_login(user: String, password: String) -> bool:
	_gdtf_error = ""
	var body := JSON.stringify({"user": user, "password": password})
	var r := await _http_raw(HTTPClient.METHOD_POST, GDTF_LOGIN_URL,
		["Content-Type: application/json", "User-Agent: " + _UA], body)
	var cookie := _extract_cookie(r["headers"])
	var parsed = JSON.parse_string((r["body"] as PackedByteArray).get_string_from_utf8())
	if not r["ok"] or cookie == "" or not (parsed is Dictionary) or not bool(parsed.get("result", false)):
		_gdtf_error = String(parsed["error"]) if (parsed is Dictionary and parsed.has("error")) \
			else "login failed (%s)" % _last_http
		return false
	_gdtf_cookie = cookie
	_gdtf_user = user
	return true


## Drops the session cookie and username, and the fetched catalogue — as if
## never logged in this session. Downloaded/cached fixtures are untouched.
func gdtf_logout() -> void:
	_gdtf_cookie = ""
	_gdtf_user = ""
	_gdtf_online.clear()
	_gdtf_online_by_id.clear()
	_gdtf_online_makers = PackedStringArray()
	_gdtf_loaded = false


## Pull the current revision list from GDTF-Share (one request). Requires
## gdtf_login() first. Coroutine — `await` it. Returns true on success;
## otherwise see gdtf_error().
func refresh_gdtf() -> bool:
	_gdtf_error = ""
	if _gdtf_cookie == "":
		_gdtf_error = "not logged in"
		return false
	var r := await _http_raw(HTTPClient.METHOD_GET, GDTF_LIST_URL,
		["Cookie: " + _gdtf_cookie, "User-Agent: " + _UA], "")
	if not r["ok"]:
		if int(r["code"]) == 401:
			_gdtf_cookie = ""   # session expired — caller needs to log in again
		_gdtf_error = "couldn't reach GDTF-Share (%s)" % _last_http
		return false
	var parsed = JSON.parse_string((r["body"] as PackedByteArray).get_string_from_utf8())
	var rows = parsed.get("list", parsed.get("fixtures", null)) if parsed is Dictionary else null
	if not (rows is Array):
		_gdtf_error = "unexpected response from GDTF-Share"
		return false

	_gdtf_online.clear()
	_gdtf_online_by_id.clear()
	var makers := {}
	for row in rows:
		if not (row is Dictionary):
			continue
		# str(), not String(): JSON numbers parse as float (GDTF-Share's
		# "rid" included, confirmed against a real response), and the
		# String(x) constructor call has no float overload at all -- it
		# throws "Invalid call 'String' constructor" at runtime. str()
		# stringifies any Variant. "rid" additionally needs int() first:
		# str(150162.0) is the ugly/wrong "150162.0", and downloadFile.php
		# expects a plain integer in its "rid" query parameter.
		var maker := str(row.get("manufacturer", "?"))
		var model := str(row.get("fixture", "?"))
		var rid_raw = row.get("rid", null)
		if rid_raw == null:
			continue
		var rid := str(int(rid_raw))
		var id := "gdtf-" + _san(maker + "-" + model + "-" + rid)
		var modes: Array = []
		for m in row.get("modes", []):
			if m is Dictionary:
				modes.append({"name": str(m.get("name", "")), "ch": _safe_int(m.get("dmxfootprint", 0))})
		var e := {
			"id": id, "maker": maker, "model": model,
			"name": "%s %s" % [maker, model],
			"cat": "", "ofl_cat": [], "modes": modes, "pt": false, "approx": 0,
			"authors": [str(row.get("creator", row.get("uploader", "")))],
			"shard": "", "online": true, "gdtf": true,
			"bundled": _by_id.has(id), "rid": rid,
			"revision": str(row.get("revision", "")),
			"version": str(row.get("version", "")),
			"_hay": ("%s %s" % [maker, model]).to_lower(),
		}
		_gdtf_online.append(e)
		_gdtf_online_by_id[id] = e
		makers[maker] = true

	_gdtf_online.sort_custom(func(a, b):
		if a["maker"] != b["maker"]:
			return a["maker"].naturalnocasecmp_to(b["maker"]) < 0
		return a["model"].naturalnocasecmp_to(b["model"]) < 0)
	_gdtf_online_makers = PackedStringArray(makers.keys())
	_gdtf_online_makers.sort()
	_gdtf_loaded = true
	return true


func gdtf_online_entry(id: String) -> Dictionary:
	return _gdtf_online_by_id.get(id, {})


## GDTF-Share rows matching a text query (+ optional manufacturer).
func search_gdtf(text := "", maker := "") -> Array:
	var terms := text.strip_edges().to_lower().split(" ", false)
	var out: Array = []
	for e in _gdtf_online:
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


## Files sitting in the on-disk online cache from GDTF-Share downloads.
func cached_gdtf_count() -> int:
	var d := DirAccess.open(ONLINE_CACHE)
	if d == null:
		return 0
	var n := 0
	for f in d.get_files():
		if f.begins_with("gdtf-") and f.ends_with(".json"):
			n += 1
	return n


func clear_gdtf_cache() -> void:
	var d := DirAccess.open(ONLINE_CACHE)
	if d == null:
		return
	for f in d.get_files():
		if f.begins_with("gdtf-") and f.ends_with(".json"):
			d.remove(f)
	for id in _gdtf_online_by_id.keys():
		_profile_cache.erase(id)


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


## Downloads a GDTF-Share revision (a ".gdtf" zip, streamed whole) and
## converts it with the same code the manual **Import…** path uses for a
## local .gdtf file. The zip only ever touches disk as a scratch temp file
## (ZIPReader needs a real path) — deleted right after parsing; only the
## converted profile is cached, same as _download_online().
func _download_gdtf(id: String) -> FixtureProfile:
	var e = _gdtf_online_by_id.get(id, null)
	if e == null:
		_gdtf_error = "unknown fixture id"
		return null
	if _gdtf_cookie == "":
		_gdtf_error = "not logged in"
		return null
	var url := "%s?rid=%s" % [GDTF_DOWNLOAD_URL, String(e["rid"]).uri_encode()]
	var r := await _http_raw(HTTPClient.METHOD_GET, url,
		["Cookie: " + _gdtf_cookie, "User-Agent: " + _UA], "")
	if not r["ok"]:
		if int(r["code"]) == 401:
			_gdtf_cookie = ""
		_gdtf_error = "download failed (%s)" % _last_http
		return null

	DirAccess.make_dir_recursive_absolute(ONLINE_CACHE)
	var tmp_path := ProjectSettings.globalize_path(GDTF_TMP)
	var tf := FileAccess.open(GDTF_TMP, FileAccess.WRITE)
	if tf == null:
		_gdtf_error = "couldn't write a temp file for the download"
		return null
	tf.store_buffer(r["body"])
	tf.close()

	var res: Dictionary = FixtureImport.from_path(tmp_path)
	DirAccess.remove_absolute(tmp_path)
	if res.has("error"):
		_gdtf_error = res["error"]
		return null
	var prof: FixtureProfile = res["profile"]
	prof.id = id
	prof.profile_name = "%s %s" % [e["maker"], e["model"]]
	e["name"] = prof.profile_name
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


## One-shot HTTP request returning the raw response — used for GDTF-Share,
## which needs the response headers (to pick up the session cookie) and
## sometimes a binary body (the downloaded .gdtf), neither of which
## _http_json() exposes. `body` is the request body (a JSON string for the
## login POST, "" for a GET). Sets `_last_http`.
func _http_raw(method: int, url: String, headers: PackedStringArray, body: String) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 20.0
	add_child(req)
	var err := req.request(url, headers, method, body)
	if err != OK:
		req.queue_free()
		_last_http = "request error %d" % err
		return {"ok": false, "code": 0, "headers": PackedStringArray(), "body": PackedByteArray()}
	var r = await req.request_completed
	req.queue_free()
	if int(r[0]) != HTTPRequest.RESULT_SUCCESS:
		_last_http = "connection failed (%d)" % int(r[0])
		return {"ok": false, "code": 0, "headers": PackedStringArray(), "body": PackedByteArray()}
	var code := int(r[1])
	_last_http = "HTTP %d" % code
	return {"ok": code >= 200 and code < 300, "code": code, "headers": r[2], "body": r[3]}


## Joins every "Set-Cookie:" response header into one "name=value; ..."
## string suitable for a subsequent request's "Cookie:" header. HTTPRequest
## doesn't track cookies itself (unlike a browser), so GDTF-Share's session
## auth has to be carried by hand between requests.
func _extract_cookie(headers: PackedStringArray) -> String:
	var parts: PackedStringArray = []
	for h in headers:
		if h.to_lower().begins_with("set-cookie:"):
			var v := h.substr(h.find(":") + 1).strip_edges()
			var semi := v.find(";")
			parts.append(v.substr(0, semi) if semi >= 0 else v)
	return "; ".join(parts)


## int(), but null-safe: Dictionary.get()'s default only applies when the
## key is *absent* — a key present with a JSON `null` (GDTF-Share has a few,
## e.g. "description") still reaches here as the literal null, and
## int(null) throws "Invalid call. Nonexistent 'int' constructor" just like
## String(float) does for a value type it has no constructor overload for.
func _safe_int(v, default := 0) -> int:
	return default if v == null else int(v)


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
