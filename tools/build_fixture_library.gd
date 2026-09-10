extends SceneTree
## Build the bundled fixture library from an Open Fixture Library checkout.
##
##   godot --headless --script tools/build_fixture_library.gd -- <ofl_repo> [out_dir]
##
## <ofl_repo>  a clone of github.com/OpenLightingProject/open-fixture-library
##             (only its `fixtures/` tree is needed).
## out_dir     defaults to res://fixtures
##
## Every fixture is run through the *runtime* importer (FixtureImport.from_ofl)
## so there is exactly one OFL parser to keep working. Output:
##   <out>/index.json          small always-resident catalogue
##   <out>/lib/<manufacturer>.json   { id: FixtureProfile.to_dict() } shards
##   <out>/ATTRIBUTION.md, <out>/OFL-LICENSE.txt

const APP_CATS := ["moving_head", "wash", "par", "beam", "strip", "blinder", "generic"]

## Modes wider than this are dropped (huge per-pixel matrix personalities are
## unusable in the patch UI and bloat the bundle). A fixture with no mode at
## or under the cap is skipped entirely.
var _max_ch := 96


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("usage: --script tools/build_fixture_library.gd -- <ofl_repo> [out_dir] [--max-ch N]")
		quit(1)
		return
	var pos: Array = []
	var i := 0
	while i < args.size():
		if args[i] == "--max-ch" and i + 1 < args.size():
			_max_ch = maxi(1, int(args[i + 1]))
			i += 2
		else:
			pos.append(args[i])
			i += 1
	var ofl: String = pos[0].trim_suffix("/")
	var out: String = (pos[1] if pos.size() > 1 else "res://fixtures").trim_suffix("/")
	var rc := _build(ofl, out)
	quit(rc)


func _build(ofl: String, out: String) -> int:
	var fx_root := ofl + "/fixtures"
	var makers_raw = _read_json(fx_root + "/manufacturers.json")
	if not (makers_raw is Dictionary):
		printerr("can't read %s/manufacturers.json — is that an OFL checkout?" % fx_root)
		return 1
	var maker_name := {}
	for k in makers_raw:
		if makers_raw[k] is Dictionary and makers_raw[k].has("name"):
			var nm := String(makers_raw[k]["name"])
			if nm.to_lower() == String(k).to_lower():
				nm = String(k).capitalize()   # upstream left a slug as the name
			maker_name[k] = nm

	var top := DirAccess.open(fx_root)
	if top == null:
		printerr("can't open ", fx_root)
		return 1

	DirAccess.make_dir_recursive_absolute(out + "/lib")

	var index: Array = []
	var built := 0
	var skipped := 0
	var redirects := 0
	var approx := 0

	for mkey in top.get_directories():
		var mdir := fx_root + "/" + mkey
		var d := DirAccess.open(mdir)
		if d == null:
			continue
		var shard := {}
		for fname in d.get_files():
			if not fname.ends_with(".json"):
				continue
			var stem := fname.get_basename()
			var raw = _read_json(mdir + "/" + fname)
			if not (raw is Dictionary):
				skipped += 1
				continue
			if raw.has("redirectTo"):
				redirects += 1
				continue

			var res: Dictionary = FixtureImport.from_ofl(raw)
			if res.has("error"):
				printerr("  skip %s/%s — %s" % [mkey, stem, res["error"]])
				skipped += 1
				continue

			var profile: FixtureProfile = res["profile"]
			var maker := String(maker_name.get(mkey, mkey.capitalize()))
			var model := String(raw.get("name", profile.profile_name))
			var fid := _san(mkey + "-" + stem)
			profile.id = fid
			profile.profile_name = "%s %s" % [maker, model]

			var pd := profile.to_dict()
			pd["modes"] = (pd["modes"] as Array).filter(
				func(m): return (m["channels"] as Array).size() <= _max_ch)
			if (pd["modes"] as Array).is_empty():
				skipped += 1
				continue
			shard[fid] = pd

			var warns: Array = res.get("warnings", [])
			if not warns.is_empty():
				approx += 1
			var mode_sum: Array = []
			for m in pd["modes"]:
				mode_sum.append({"name": String(m["name"]), "ch": (m["channels"] as Array).size()})
			index.append({
				"id": fid,
				"maker": maker,
				"model": model,
				"name": profile.profile_name,
				"cat": _app_cat(profile),
				"ofl_cat": raw.get("categories", []),
				"modes": mode_sum,
				"pt": _has_pan_tilt(profile),
				"shard": mkey,
				"authors": raw.get("meta", {}).get("authors", []),
				"approx": warns.size(),
			})
			built += 1

		if not shard.is_empty():
			_write(out + "/lib/%s.json" % mkey, JSON.stringify(shard))

	index.sort_custom(func(a, b):
		if a["maker"] != b["maker"]:
			return a["maker"].naturalnocasecmp_to(b["maker"]) < 0
		return a["model"].naturalnocasecmp_to(b["model"]) < 0)

	_write(out + "/index.json", JSON.stringify({
		"generated": Time.get_datetime_string_from_system(true),
		"source": "Open Fixture Library",
		"ofl_commit": _git_head(ofl),
		"count": index.size(),
		"fixtures": index,
	}, "\t"))

	_write_attribution(out, ofl, index.size())
	var lic := _read_text(ofl + "/LICENSE")
	if lic != "":
		_write(out + "/OFL-LICENSE.txt", lic)

	print("\nbuilt %d fixtures across %d manufacturers (mode cap %d ch)" % [
		built, _distinct_makers(index), _max_ch])
	print("  %d redirects, %d skipped (unparseable or every mode over the cap), %d with approximations" % [
		redirects, skipped, approx])
	print("  -> %s/index.json + %s/lib/*.json" % [out, out])
	return 0


# --------------------------------------------------------------- helpers --

## id-safe: lowercase, keep [a-z0-9-], collapse the rest to "-".
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


func _app_cat(p: FixtureProfile) -> String:
	var c := String(p.physical.get("category", ""))
	return c if c in APP_CATS else "generic"


func _has_pan_tilt(p: FixtureProfile) -> bool:
	var seen := {}
	for ch in p.channels_for_mode(0):
		seen[String(ch["role"])] = true
	for i in range(p.mode_count()):
		for ch in p.channels_for_mode(i):
			seen[String(ch["role"])] = true
	return seen.has("PAN") and seen.has("TILT")


func _distinct_makers(index: Array) -> int:
	var s := {}
	for e in index:
		s[e["maker"]] = true
	return s.size()


func _read_json(path: String):
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed


func _read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("can't write ", path)
		return
	f.store_string(text)
	f.close()


func _git_head(repo: String) -> String:
	var head := _read_text(repo + "/.git/HEAD").strip_edges()
	if head.begins_with("ref: "):
		var ref := head.substr(5)
		return _read_text(repo + "/.git/" + ref).strip_edges().substr(0, 12)
	return head.substr(0, 12)


func _write_attribution(out: String, ofl: String, n: int) -> void:
	_write(out + "/ATTRIBUTION.md", "".join([
		"# Bundled fixture library\n\n",
		"%d fixture definitions generated from the " % n,
		"[Open Fixture Library](https://open-fixture-library.org) project ",
		"(commit `%s`).\n\n" % _git_head(ofl),
		"Each definition was converted to this app's `FixtureProfile` format by ",
		"`tools/build_fixture_library.gd` (which calls the same `FixtureImport.from_ofl` ",
		"used for manual imports). Regenerate with:\n\n",
		"```\ngit clone --depth 1 https://github.com/OpenLightingProject/open-fixture-library\n",
		"godot --headless --script tools/build_fixture_library.gd -- open-fixture-library\n```\n\n",
		"## Licence\n\n",
		"OFL fixture data is published under the MIT licence for the schema/tooling and, ",
		"per fixture, CC0-1.0 or CC-BY-SA-4.0 for the data. The upstream `LICENSE` is kept ",
		"here as `OFL-LICENSE.txt`. Fixture authors are credited in `index.json` ",
		"(`authors` per entry).\n",
	]))
