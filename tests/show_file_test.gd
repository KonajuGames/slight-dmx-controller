extends SceneTree
## Tests for saving the show (fixture layout, visualizer placement, live
## levels, cues, effects, groups, ...) to a file and loading it back.
##
##   godot --headless --script tests/show_file_test.gd

var _p := 0
var _f := 0
var _s := 0

const PATH := "user://_show_file_test.slight"
## The tests' own "last show" memory, so the app's real one is untouched.
const STORE := "user://_show_file_test_last.json"


func ok(cond: bool, label: String) -> void:
	if cond:
		_p += 1
		print("  ok   ", label)
	else:
		_f += 1
		print("  FAIL ", label)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== Show files ==")
	await _test_round_trip()
	await _test_reopen_at_start()
	print("== %d passed, %d failed, %d skipped ==" % [_p, _f, _s])
	quit(1 if _f > 0 else 0)


func _rgb() -> FixtureProfile:
	return FixtureProfile.new("rgb", "RGB par", [
		{"name": "Red", "role": "RED"}, {"name": "Green", "role": "GREEN"},
		{"name": "Blue", "role": "BLUE"},
	])


func _bar() -> FixtureProfile:
	var chans := []
	for h in range(2):
		chans.append({"name": "Red", "role": "RED"})
		chans.append({"name": "Green", "role": "GREEN"})
		chans.append({"name": "Blue", "role": "BLUE"})
	return FixtureProfile.new("bar2", "2-head bar", chans)


func _test_round_trip() -> void:
	print("- save, change everything, load it back")
	var main: Control = load("res://main.tscn").instantiate()
	main.last_show_store = STORE
	root.add_child(main)
	await process_frame
	var fx: Node = root.get_node("Fx")
	var panel = main._panels[0]
	var u = panel.sender

	# A rig: two fixtures placed in the visualizer, with levels.
	panel.add_patched(_rgb(), 0, 0, "Par L", Vector3(-2, 4, -1), Vector3(90, 15, 0))
	panel.add_patched(_bar(), 10, 0, "Bar", Vector3(1.5, 3.5, -2), Vector3(80, 0, 30))
	await process_frame
	var par_id := int(panel.patched_fixtures[0]["id"])
	var bar_id := int(panel.patched_fixtures[1]["id"])
	panel.load_look(PackedByteArray([200, 40, 10]))
	u.set_virtual_dimmer_level(par_id, 0.4)
	panel.patched_fixtures[0]["_set_vdim"].call(0.4)
	# A cue, a group, an effect.
	main.cue_panel.record_cue()
	main.groups.append({"name": "Front", "members": [[0, par_id], [0, bar_id]]})
	var e = load("res://scripts/wave_effect.gd").new()
	e.name = "Test wave"
	e.group = "Front"
	fx.effects.append(e)

	var err: String = main.save_show_to(PATH)
	ok(err == "" and FileAccess.file_exists(PATH), "saved (%s)" % err)
	ok(main.show_path == PATH, "it becomes the current show file")
	ok(main.remembered_show() == PATH, "...and is remembered for the next start")
	var doc = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	ok(doc is Dictionary and doc.get("format") == "sLight show" and int(doc.get("version")) == 1, "tagged with format and version")
	var saved_fixtures: Array = doc["universes"][0]["fixtures"]
	ok(saved_fixtures.size() == 2 and saved_fixtures[0]["profile"]["profile_name"] == "RGB par",
		"each fixture with its whole profile (portable)")

	# Change everything.
	panel.apply_patch_dict({"fixtures": []})
	main.cue_panel.from_dict({})
	main.groups.clear()
	fx.effects.clear()
	main.show_path = "user://elsewhere.slight"
	ok(panel.patched_fixtures.is_empty(), "(cleared)")

	err = main.load_show_from(PATH)
	await process_frame
	ok(err == "", "loaded (%s)" % err)
	ok(main.show_path == PATH, "it becomes the current show file")
	var pf: Array = main._panels[0].patched_fixtures
	ok(pf.size() == 2 and pf[0]["name"] == "Par L" and pf[1]["name"] == "Bar" and int(pf[1]["start"]) == 10,
		"fixtures, names and addresses")
	ok(pf.size() == 2 and pf[0]["pos"].is_equal_approx(Vector3(-2, 4, -1)) and pf[0]["rot"].is_equal_approx(Vector3(90, 15, 0))
		and pf[1]["pos"].is_equal_approx(Vector3(1.5, 3.5, -2)) and pf[1]["rot"].is_equal_approx(Vector3(80, 0, 30)),
		"visualizer positions and rotations")
	u = main._panels[0].sender
	ok(u.get_channel(0) == 200 and u.get_channel(1) == 40 and u.get_channel(2) == 10, "live levels (the actual colour)")
	var new_par := int(pf[0]["id"]) if pf.size() > 0 else -1
	ok(is_equal_approx(u.virtual_dimmer_level(new_par), 0.4), "virtual dimmer level (%.2f)" % u.virtual_dimmer_level(new_par))
	ok(main.cue_panel.cues.size() == 1 and main.cue_panel.cues[0].levels.size() > 0 and int(main.cue_panel.cues[0].levels[0].get("0", main.cue_panel.cues[0].levels[0].get(0, -1))) == 200,
		"the cue, with its levels")
	ok(main.groups.size() == 1 and main.groups[0]["name"] == "Front" and main.groups[0]["members"].size() == 2,
		"the group and its members (remapped to the new fixture ids)")
	ok(fx.effects.size() == 1 and fx.effects[0].name == "Test wave" and fx.effects[0].group == "Front", "the effect")
	var tracks: Array = main.music_panel.timeline().fixture_tracks()
	ok(tracks.size() == 4, "the Music Library timeline follows: par, bar + 2 heads (%d)" % tracks.size())

	# Bad files leave the show alone.
	var bad := "user://_show_file_bad.json"
	var f := FileAccess.open(bad, FileAccess.WRITE)
	f.store_string("{\"hello\": 1}")
	f.close()
	err = main.load_show_from(bad)
	ok(err != "" and main._panels[0].patched_fixtures.size() == 2 and main.show_path == PATH, "not a show file: refused (%s)" % err)
	f = FileAccess.open(bad, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 99, "universes": []}))
	f.close()
	err = main.load_show_from(bad)
	ok(err != "" and main._panels[0].patched_fixtures.size() == 2, "from a newer version: refused (%s)" % err)
	ok(main.load_show_from("user://_no_such_show.slight") != "", "missing file: refused")
	ok(main.remembered_show() == PATH, "a refused file isn't remembered")
	# An older show (no live levels) still loads, at the patch's defaults.
	doc.erase("live")
	doc.erase("format")
	doc.erase("version")
	f = FileAccess.open(bad, FileAccess.WRITE)
	f.store_string(JSON.stringify(doc))
	f.close()
	err = main.load_show_from(bad)
	ok(err == "" and main._panels[0].patched_fixtures.size() == 2 and main._panels[0].sender.get_channel(0) == 0,
		"an older show file loads (no live levels)")

	ok(main.remembered_show() == bad, "the last loaded file is remembered")
	main.save_show_to(PATH)                 # leave PATH remembered for the next test
	DirAccess.remove_absolute(ProjectSettings.globalize_path(bad))
	fx.effects.clear()
	main.queue_free()
	await process_frame


func _test_reopen_at_start() -> void:
	print("- reopening the last show at the next start")
	var main: Control = load("res://main.tscn").instantiate()
	main.last_show_store = STORE
	root.add_child(main)
	await process_frame
	await process_frame
	ok(main._panels[0].patched_fixtures.is_empty(), "a scene a test adds itself doesn't reopen anything")
	main.restore_last_show()
	await process_frame
	ok(main.show_path == PATH and main._panels[0].patched_fixtures.size() == 2,
		"the remembered show is reopened (%d fixtures)" % main._panels[0].patched_fixtures.size())
	ok("Reopened the last show" in main.status_label.text, "status says so: %s" % main.status_label.text)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	main.restore_last_show()
	ok("Couldn't reopen" in main.status_label.text and main.remembered_show() == PATH,
		"gone since: says so (%s)" % main.status_label.text)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(STORE))
	main.restore_last_show()
	ok(main.remembered_show() == "", "nothing remembered: nothing to do")
	root.get_node("Fx").effects.clear()
	main.queue_free()
