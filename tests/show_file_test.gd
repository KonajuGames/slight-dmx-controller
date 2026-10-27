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
	await _test_timelines_with_show()
	await _test_groups_by_uid()
	await _test_new_show()
	await _test_default_names()
	await _test_model_colours()
	await _test_viz_ui_state()
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


## The "1"-"4" category group buttons in the fixture's row.
func _group_buttons(panel, index: int) -> Array:
	var out: Array = []
	for b in panel.fixtures_vbox.get_child(index).find_children("*", "Button", true, false):
		if b.button_group != null and b.text in ["1", "2", "3", "4"]:
			out.append(b)
	return out


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
	panel.load_look(PackedByteArray([200, 40, 10]))
	u.set_virtual_dimmer_level(par_id, 0.4)
	panel.patched_fixtures[0]["_set_vdim"].call(0.4)
	# A cue, a group, an effect.
	main.cue_panel.record_cue()
	var par_uid := String(panel.patched_fixtures[0]["uid"])
	var bar_uid := String(panel.patched_fixtures[1]["uid"])
	ok(panel.patched_fixtures[0]["category"] == "Primary Wash" and panel.patched_fixtures[1]["category"] == "Primary Multi-cell",
		"default categories: a par is a wash, a 2-head bar a multi-cell")
	var mover := FixtureProfile.new("mh", "Moving head", [
		{"name": "Pan", "role": "PAN"}, {"name": "Dimmer", "role": "DIMMER"},
	])
	ok(mover.default_show_category(0) == "Primary Mover", "...one with pan (or tilt) a mover")
	panel.patched_fixtures[0]["category"] = "Secondary Wash"
	ok(panel.patched_fixtures[0]["category_group"] == 1 and panel.patched_fixtures[1]["category_group"] == 1,
		"category group 1 by default")
	var bar_groups := _group_buttons(panel, 1)
	bar_groups[2].button_pressed = true
	ok(panel.patched_fixtures[1]["category_group"] == 3 and not bar_groups[0].button_pressed
		and _group_buttons(panel, 0)[0].button_pressed,
		"picking group 3 deselects 1, on that fixture only")
	var row: Control = panel.fixtures_vbox.get_child(1)
	var row_btns := {}
	for b in row.find_children("*", "Button", true, false):
		if b.icon != null and b.text == "":
			row_btns[b.tooltip_text] = b
	var title_rect: Rect2 = row.find_children("*", "Label", true, false)[0].get_global_rect()
	var cat_rect: Rect2 = row.find_children("*", "OptionButton", true, false)[0].get_global_rect()
	var right := row.get_global_rect().end.x
	ok(row_btns.has("Remove") and cat_rect.position.x > title_rect.end.x - 1.0
		and absf(cat_rect.end.x - right) < 12.0
		and absf(row_btns["Remove"].get_global_rect().end.x - right) < 12.0,
		"the category, groups and Flash/Home/Remove at the right of the fixture's name")
	ok(row_btns.size() == 5 and row_btns.has("Flash") and row_btns.has("Home") and row_btns.has("Expand")
		and row_btns.has("Leave out of show generation"),
		"Expand, Flash, Home, Remove and leave-out are icons (named in their tooltips)")
	var exclude_btn: Button = row_btns.get("Leave out of show generation")
	ok(exclude_btn != null and exclude_btn.toggle_mode and not exclude_btn.button_pressed
		and not panel.patched_fixtures[1].get("exclude_generate", false), "...a fixture is in show generation by default")
	if exclude_btn != null:
		exclude_btn.button_pressed = true
	ok(panel.patched_fixtures[1]["exclude_generate"] and not panel.patched_fixtures[0]["exclude_generate"]
		and exclude_btn.tooltip_text.begins_with("Left out"), "...toggled on: that fixture is left out")
	var tl_fx: Array = main._timeline_fixtures()
	ok(tl_fx.size() == 2 and tl_fx[1]["exclude_generate"] and not tl_fx[0]["exclude_generate"],
		"...and the timelines are told so")
	var ex_rect: Rect2 = exclude_btn.get_global_rect() if exclude_btn != null else Rect2()
	ok(is_equal_approx(ex_rect.get_center().y, cat_rect.get_center().y) and ex_rect.end.x <= cat_rect.position.x,
		"...its button just left of the category")
	var controls: Control = row.get_child(0).get_child(1)
	var collapsed := not controls.visible
	row_btns["Expand"].pressed.emit()
	ok(collapsed and controls.visible and row_btns["Expand"].tooltip_text == "Collapse",
		"a fixture starts collapsed to its header; Expand shows its controls")
	row_btns["Expand"].pressed.emit()
	var g4: Rect2 = bar_groups[3].get_global_rect()
	var fl: Rect2 = row_btns["Flash"].get_global_rect() if row_btns.has("Flash") else Rect2()
	ok(cat_rect.end.y <= g4.position.y and is_equal_approx(fl.position.y, g4.position.y)
		and fl.position.x - g4.end.x >= 8.0,
		"...on the groups' line beneath the category, after a gap (%.0f px)" % (fl.position.x - g4.end.x))
	main.groups.append({"name": "Front", "members": [par_uid, bar_uid]})
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
	ok(saved_fixtures.size() == 2 and saved_fixtures[0]["profile"]["model"] == "RGB par",
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
	ok(pf.size() == 2 and pf[0]["category"] == "Secondary Wash" and pf[1]["category"] == "Primary Multi-cell",
		"categories, as changed")
	ok(pf.size() == 2 and pf[0]["category_group"] == 1 and pf[1]["category_group"] == 3
		and _group_buttons(main._panels[0], 1)[2].button_pressed,
		"category groups, as changed (and shown)")
	ok(pf.size() == 2 and not pf[0]["exclude_generate"] and pf[1]["exclude_generate"],
		"left out of show generation, as changed")
	u = main._panels[0].sender
	ok(u.get_channel(0) == 200 and u.get_channel(1) == 40 and u.get_channel(2) == 10, "live levels (the actual colour)")
	var new_par := int(pf[0]["id"]) if pf.size() > 0 else -1
	ok(is_equal_approx(u.virtual_dimmer_level(new_par), 0.4), "virtual dimmer level (%.2f)" % u.virtual_dimmer_level(new_par))
	ok(main.cue_panel.cues.size() == 1 and main.cue_panel.cues[0].levels.size() > 0 and int(main.cue_panel.cues[0].levels[0].get("0", main.cue_panel.cues[0].levels[0].get(0, -1))) == 200,
		"the cue, with its levels")
	ok(main.groups.size() == 1 and main.groups[0]["name"] == "Front" and main.groups[0]["members"] == [par_uid, bar_uid],
		"the group and its members (by fixture uid)")
	ok(fx.effects.size() == 1 and fx.effects[0].name == "Test wave" and fx.effects[0].group == "Front", "the effect")
	var tracks: Array = main.music_panel.timeline().fixture_tracks()
	ok(tracks.size() == 4, "the DJ Edit Mode timeline follows: par, bar + 2 heads (%d)" % tracks.size())

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
	for sf in doc["universes"][0]["fixtures"]:
		sf.erase("category")
		sf.erase("category_group")
		sf.erase("exclude_generate")
	doc.erase("format")
	doc.erase("version")
	f = FileAccess.open(bad, FileAccess.WRITE)
	f.store_string(JSON.stringify(doc))
	f.close()
	err = main.load_show_from(bad)
	ok(err == "" and main._panels[0].patched_fixtures.size() == 2 and main._panels[0].sender.get_channel(0) == 0,
		"an older show file loads (no live levels)")
	ok(main._panels[0].patched_fixtures[0]["category"] == "Primary Wash"
		and main._panels[0].patched_fixtures[1]["category"] == "Primary Multi-cell",
		"...its fixtures in their default categories")
	ok(main._panels[0].patched_fixtures[1]["category_group"] == 1, "...and category group 1")
	ok(not main._panels[0].patched_fixtures[1]["exclude_generate"], "...in show generation")
	# One saved in the old Auto Show run mode (gone): opens in Cue Mode.
	doc["run_mode"] = 2
	doc["auto_show"] = {"song": "C:/old.mp3"}
	f = FileAccess.open(bad, FileAccess.WRITE)
	f.store_string(JSON.stringify(doc))
	f.close()
	err = main.load_show_from(bad)
	ok(err == "" and main.run_mode == 0 and main.run_mode_option.selected == 0,
		"a show saved in the old Auto Show run mode opens in Cue Mode")
	var titles: Array = []
	for tc in main.find_children("*", "TabContainer", true, false):
		if tc.get_tab_count() > 0 and tc.get_tab_title(0) == "Cues":
			for i in range(tc.get_tab_count()):
				titles.append(tc.get_tab_title(i))
	ok(titles == ["Cues", "Chases", "Effects", "Sound", "Groups", "Faders"], "no Auto Show tab (%s)" % str(titles))
	ok(main.run_mode_option.item_count == 2, "run modes: Cue Mode, Sound Reactive")
	# Triggers' feedback: saved by name now; the old numbers still read.
	var tr := Trigger.new()
	tr.fb_enabled = true
	tr.fb_watch = Trigger.FB_MODE_SOUND
	var td := tr.to_dict()
	ok(td.get("fb_watch_key") == "mode_sound" and Trigger.from_dict(td).fb_watch == Trigger.FB_MODE_SOUND,
		"a trigger's feedback saves and loads by name")
	var legacy := Trigger.from_dict({"fb_enabled": true, "fb_watch": 6})
	ok(legacy.fb_watch == Trigger.FB_MODE_SOUND and legacy.fb_enabled, "an old show's number: Sound Reactive (6) still means it")
	legacy = Trigger.from_dict({"fb_enabled": true, "fb_watch": 4})
	ok(legacy.fb_watch == Trigger.FB_ACTION and not legacy.fb_enabled, "an old Auto Show feedback (4): turned off")
	legacy = Trigger.from_dict({"fb_enabled": true, "fb_watch": 3})
	ok(legacy.fb_watch == Trigger.FB_FX_ANY and legacy.fb_enabled, "...the ones before it unchanged")

	ok(main.remembered_show() == bad, "the last loaded file is remembered")
	# Ctrl+S saves to the current show file, in either view.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(bad))
	main.set_view(1)
	var ks := InputEventKey.new()
	ks.keycode = KEY_S
	ks.ctrl_pressed = true
	ks.pressed = true
	root.push_input(ks)
	ok(FileAccess.file_exists(bad) and "Show saved" in main.status_label.text,
		"Ctrl+S saves the show (from DJ Edit Mode): %s" % main.status_label.text)
	var dialogs_before: int = main.find_children("*", "FileDialog", false, false).size()
	var saved_text: String = main.status_label.text
	ks = InputEventKey.new()
	ks.keycode = KEY_S
	ks.ctrl_pressed = true
	ks.shift_pressed = true
	ks.pressed = true
	root.push_input(ks)
	var dialogs: Array = main.find_children("*", "FileDialog", false, false)
	ok(dialogs.size() == dialogs_before + 1 and dialogs[-1].title == "Save Show As"
		and dialogs[-1].file_mode == FileDialog.FILE_MODE_SAVE_FILE and main.status_label.text == saved_text,
		"Shift+Ctrl+S opens Save Show As (not a plain save)")
	dialogs[-1].canceled.emit()
	await process_frame
	ks = InputEventKey.new()
	ks.keycode = KEY_O
	ks.ctrl_pressed = true
	ks.pressed = true
	root.push_input(ks)
	dialogs = main.find_children("*", "FileDialog", false, false)
	ok(dialogs.size() == dialogs_before + 1 and dialogs[-1].title == "Load Show"
		and dialogs[-1].file_mode == FileDialog.FILE_MODE_OPEN_FILE, "Ctrl+O opens Load Show")
	dialogs[-1].canceled.emit()
	main.set_view(0)
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


func _rm_dir(d: String) -> void:
	if DirAccess.dir_exists_absolute(d):
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d.path_join(f))
		DirAccess.remove_absolute(d)


func _test_timelines_with_show() -> void:
	print("- music timelines saved with the show")
	var a_show := "user://_tl_show_a.slight"
	var b_show := "user://_tl_show_b.slight"
	var song := "user://_tl_show_song.song"
	var sf := FileAccess.open(song, FileAccess.WRITE)
	var bytes := PackedByteArray()
	bytes.resize(100000)
	for i in range(0, bytes.size(), 13):
		bytes[i] = i & 0xFF
	sf.store_buffer(bytes)
	sf.close()
	var main: Control = load("res://main.tscn").instantiate()
	main.last_show_store = STORE
	root.add_child(main)
	await process_frame
	var panel = main._panels[0]
	panel.apply_patch_dict({"fixtures": []})
	panel.add_patched(_rgb(), 0, 0, "Par L", Vector3.ZERO, Vector3.ZERO)
	panel.add_patched(_bar(), 10, 0, "Bar", Vector3.ZERO, Vector3.ZERO)
	var uids := [String(panel.patched_fixtures[0]["uid"]), String(panel.patched_fixtures[1]["uid"])]
	ok(uids[0].length() == 16 and uids[0] != uids[1], "each patched fixture gets a permanent uid")
	var tl = main.music_panel.timeline()
	tl.open(song)
	await process_frame
	ok(tl.fixture_tracks().size() == 4 and tl.fixture_tracks()[0].get_meta("key") == uids[0]
		and tl.fixture_tracks()[2].get_meta("key") == uids[1] + "/h0", "the timeline's tracks are keyed by uid (heads: uid/h<n>)")
	tl.fixture_tracks()[2].dimmer_nodes = PackedVector2Array([Vector2(4, 0.5)])
	tl.fixture_tracks()[2].dimmer_edited.emit()

	ok(main.save_show_to(a_show) == "", "save the show")
	var doc = JSON.parse_string(FileAccess.get_file_as_string(a_show))
	ok(doc["timelines"] == "_tl_show_a.timelines", "it names its timelines folder")
	ok(doc["universes"][0]["fixtures"][1]["uid"] == uids[1], "and saves each fixture's uid")
	var a_store := TimelineStore.new("user://_tl_show_a.timelines")
	ok(a_store.load_song(song).get("tracks", {}).get(uids[1] + "/h0", {}).get("dimmer") == [[4.0, 0.5]],
		"Save Show saves the open song's unsaved timelines into the folder")

	# Save As: the folder's copied, and edits from then on go to the copy.
	ok(main.save_show_to(b_show) == "", "save as another show")
	ok(tl.timeline_store.dir == "user://_tl_show_b.timelines"
		and TimelineStore.new("user://_tl_show_b.timelines").load_song(song).get("tracks", {}).has(uids[1] + "/h0"),
		"its timelines folder is a copy")
	tl.master_track().dimmer_nodes = PackedVector2Array([Vector2(1, 1)])
	tl.master_track().dimmer_edited.emit()
	main.save_show_to(b_show)
	ok(TimelineStore.new("user://_tl_show_b.timelines").load_song(song)["tracks"].has("master")
		and not a_store.load_song(song)["tracks"].has("master"), "later edits go to the new show only")

	# Loading a show: same uids, its own timelines.
	ok(main.load_show_from(a_show) == "", "load the first show")
	await process_frame
	ok(String(main._panels[0].patched_fixtures[1]["uid"]) == uids[1], "fixtures keep their uids")
	ok(tl.timeline_store.dir == "user://_tl_show_a.timelines" and tl.master_track().dimmer_nodes.is_empty()
		and tl.fixture_tracks()[2].dimmer_nodes == PackedVector2Array([Vector2(4, 0.5)]),
		"the open song shows that show's timelines")
	# An older show without uids gets new ones.
	doc["universes"][0]["fixtures"][0].erase("uid")
	var f := FileAccess.open(a_show, FileAccess.WRITE)
	f.store_string(JSON.stringify(doc))
	f.close()
	main.load_show_from(a_show)
	ok(String(main._panels[0].patched_fixtures[0]["uid"]).length() == 16
		and String(main._panels[0].patched_fixtures[0]["uid"]) != uids[0], "an older show's fixtures get uids")

	main.queue_free()
	await process_frame
	for p in [a_show, b_show, song, STORE]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	_rm_dir("user://_tl_show_a.timelines")
	_rm_dir("user://_tl_show_b.timelines")
	root.get_node("Fx").effects.clear()


func _test_groups_by_uid() -> void:
	print("- fixture groups by fixture uid")
	var path := "user://_groups_test.slight"
	var main: Control = load("res://main.tscn").instantiate()
	main.last_show_store = STORE
	root.add_child(main)
	await process_frame
	var panel = main._panels[0]
	panel.apply_patch_dict({"fixtures": []})
	panel.add_patched(_rgb(), 0, 0, "A", Vector3.ZERO, Vector3.ZERO)
	panel.add_patched(_rgb(), 3, 0, "B", Vector3.ZERO, Vector3.ZERO)
	panel.add_patched(_rgb(), 6, 0, "C", Vector3.ZERO, Vector3.ZERO)
	var uid_a := String(panel.patched_fixtures[0]["uid"])
	var uid_c := String(panel.patched_fixtures[2]["uid"])
	main.groups.append({"name": "Ends", "members": [uid_a, uid_c]})
	main.groups_panel.sync_to_patch()
	var reds: Array = main._resolve_fx_targets("RED", -1, "Ends")
	ok(reds.size() == 2 and reds[0]["ch"] == 0 and reds[1]["ch"] == 6, "an effect on the group reaches its members' channels")
	var listed: Array = main._list_patched_fixtures()
	ok(listed.size() == 3 and listed[0]["uid"] == uid_a, "the groups checklist lists fixtures by uid")
	main.save_show_to(path)
	var doc = JSON.parse_string(FileAccess.get_file_as_string(path))
	ok(doc["groups"]["groups"][0]["members"] == [uid_a, uid_c], "saved as uids")

	# Reorder the patch in the file: the group still means A and C.
	var fx: Array = doc["universes"][0]["fixtures"]
	fx.reverse()
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(doc))
	f.close()
	main.load_show_from(path)
	await process_frame
	var names := []
	for m in main.groups[0]["members"]:
		for p in main._panels[0].patched_fixtures:
			if String(p["uid"]) == m:
				names.append(p["name"])
	ok(names == ["A", "C"], "a reordered patch keeps the same members (%s)" % str(names))
	reds = main._resolve_fx_targets("RED", -1, "Ends")
	ok(reds.size() == 2 and reds.map(func(r): return r["ch"]).has(0) and reds.map(func(r): return r["ch"]).has(6),
		"...and the same channels")

	# An older show: members as [universe, patch index].
	doc["groups"] = {"groups": [{"name": "Old", "members": [[0, 1], [0, 7]]}]}
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(doc))
	f.close()
	main.load_show_from(path)
	await process_frame
	ok(main.groups[0]["members"] == [String(main._panels[0].patched_fixtures[1]["uid"])],
		"an older show's [universe, index] members become uids (out-of-range ones dropped)")

	# Removing a universe takes its fixtures out of groups.
	main._on_add_universe()
	await process_frame
	main._panels[1].add_patched(_rgb(), 0, 0, "D", Vector3.ZERO, Vector3.ZERO)
	var uid_d := String(main._panels[1].patched_fixtures[0]["uid"])
	var keep := String(main.groups[0]["members"][0])
	main.groups[0]["members"].append(uid_d)
	main.universe_tabs.current_tab = 1
	main._on_remove_universe()
	await process_frame
	ok(main.groups[0]["members"] == [keep], "removing a universe drops its fixtures from groups")

	main.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(STORE))
	if DirAccess.dir_exists_absolute("user://_groups_test.timelines"):
		DirAccess.remove_absolute("user://_groups_test.timelines")


func _test_new_show() -> void:
	print("- New Show")
	var path := "user://_new_show_test.slight"
	var main: Control = load("res://main.tscn").instantiate()
	main.last_show_store = STORE
	root.add_child(main)
	await process_frame
	var fx: Node = root.get_node("Fx")
	var panel = main._panels[0]
	panel.ip_edit.text = "10.1.2.3"
	panel.add_patched(_rgb(), 0, 0, "Par", Vector3.ZERO, Vector3.ZERO)
	panel.load_look(PackedByteArray([200, 100, 50]))
	main._on_add_universe()
	main.cue_panel.record_cue()
	main.groups.append({"name": "G", "members": [String(panel.patched_fixtures[0]["uid"])]})
	var e = load("res://scripts/wave_effect.gd").new()
	fx.effects.append(e)
	main.save_show_to(path)
	ok(main.remembered_show() == path, "(a saved show)")

	# Ctrl+N asks first.
	var kn := InputEventKey.new()
	kn.keycode = KEY_N
	kn.ctrl_pressed = true
	kn.pressed = true
	root.push_input(kn)
	var dlgs: Array = main.find_children("*", "ConfirmationDialog", false, false)
	ok(dlgs.size() == 1 and dlgs[0].title == "New Show" and main._panels[0].patched_fixtures.size() == 1,
		"Ctrl+N asks before starting a new show")
	dlgs[0].canceled.emit()
	await process_frame
	ok(main._panels[0].patched_fixtures.size() == 1, "cancelled: the show's untouched")
	root.push_input(kn)
	dlgs = main.find_children("*", "ConfirmationDialog", false, false)
	dlgs[-1].confirmed.emit()
	await process_frame
	panel = main._panels[0]
	ok(main._panels.size() == 1 and panel.patched_fixtures.is_empty(), "confirmed: one universe, no fixtures")
	ok(panel.sender.get_channel(0) == 0 and panel.sender.get_channel(1) == 0, "everything dark")
	ok(main.cue_panel.cues.is_empty() and main.groups.is_empty() and fx.effects.is_empty(), "no cues, groups or effects")
	ok(panel.ip_edit.text == "10.1.2.3", "universe 1's output settings kept")
	ok(main.show_path == "" and "New show" in main.status_label.text, "untitled: %s" % main.status_label.text)
	ok(main.remembered_show() == path, "the last saved show is still the one reopened at start")
	ok(main.music_panel.timeline().timeline_store == null, "no music timelines")
	# Ctrl+Shift+N adds a universe (no confirmation), up to the limit.
	var ku := InputEventKey.new()
	ku.keycode = KEY_N
	ku.ctrl_pressed = true
	ku.shift_pressed = true
	ku.pressed = true
	var dlg_count: int = main.find_children("*", "ConfirmationDialog", false, false).size()
	root.push_input(ku)
	ok(main._panels.size() == 2 and _artnet_count() == 2 and "Added universe 2" in main.status_label.text
		and main.find_children("*", "ConfirmationDialog", false, false).size() == dlg_count,
		"Ctrl+Shift+N adds a universe: %s" % main.status_label.text)
	for i in range(10):
		root.push_input(ku)
	ok(main._panels.size() == 8 and "limit" in main.status_label.text, "...up to the limit: %s" % main.status_label.text)
	main.new_show()
	ok(main._panels.size() == 1, "(back to one)")
	# Ctrl+Shift+R removes the current universe, after asking.
	var kr := InputEventKey.new()
	kr.keycode = KEY_R
	kr.ctrl_pressed = true
	kr.shift_pressed = true
	kr.pressed = true
	dlg_count = main.find_children("*", "ConfirmationDialog", false, false).size()
	root.push_input(kr)
	ok(main.find_children("*", "ConfirmationDialog", false, false).size() == dlg_count
		and "only universe" in main.status_label.text, "with one universe: nothing to remove (%s)" % main.status_label.text)
	root.push_input(ku)
	root.push_input(ku)
	main._panels[1].add_patched(_rgb(), 0, 0, "Mid A", Vector3.ZERO, Vector3.ZERO)
	main._panels[1].add_patched(_rgb(), 3, 0, "Mid B", Vector3.ZERO, Vector3.ZERO)
	main._panels[2].add_patched(_rgb(), 0, 0, "Last", Vector3.ZERO, Vector3.ZERO)
	main.universe_tabs.current_tab = 1
	root.push_input(kr)
	var rd: Array = main.find_children("*", "ConfirmationDialog", false, false)
	ok(rd.size() == dlg_count + 1 and rd[-1].title == "Remove Universe"
		and rd[-1].dialog_text == "Remove universe 2 and its 2 fixtures (also taken out of any groups)?",
		"Ctrl+Shift+R asks about the current universe: %s" % rd[-1].dialog_text)
	rd[-1].canceled.emit()
	await process_frame
	ok(main._panels.size() == 3, "cancelled: nothing removed")
	root.push_input(kr)
	rd = main.find_children("*", "ConfirmationDialog", false, false)
	rd[-1].confirmed.emit()
	await process_frame
	ok(main._panels.size() == 2 and main._panels[1].patched_fixtures.size() == 1
		and main._panels[1].patched_fixtures[0]["name"] == "Last", "confirmed: universe 2 removed, the one after it moves up")
	# The Remove Universe button asks the same way.
	main.universe_tabs.current_tab = 1
	main.remove_uni_btn.pressed.emit()
	rd = main.find_children("*", "ConfirmationDialog", false, false)
	ok(rd.size() == dlg_count + 1 and rd[-1].dialog_text == "Remove universe 2 and its 1 fixture (also taken out of any groups)?"
		and main._panels.size() == 2, "the Remove Universe button asks first: %s" % rd[-1].dialog_text)
	rd[-1].confirmed.emit()
	await process_frame
	ok(main._panels.size() == 1, "...and removes it when confirmed")
	# Saving an untitled show asks where (it doesn't overwrite the default file).
	var before: int = main.find_children("*", "FileDialog", false, false).size()
	main._on_save_show()
	var fds: Array = main.find_children("*", "FileDialog", false, false)
	ok(fds.size() == before + 1 and fds[-1].title == "Save Show As", "Save Show on a new show asks where")
	fds[-1].canceled.emit()
	main.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(STORE))
	if DirAccess.dir_exists_absolute("user://_new_show_test.timelines"):
		DirAccess.remove_absolute("user://_new_show_test.timelines")
	fx.effects.clear()


func _test_default_names() -> void:
	print("- Unnamed fixtures")
	var main: Control = load("res://main.tscn").instantiate()
	main.last_show_store = STORE
	root.add_child(main)
	await process_frame
	var panel = main._panels[0]
	panel.add_patched(_rgb(), 0, 0, "", Vector3.ZERO, Vector3.ZERO)
	panel.add_patched(_rgb(), 3, 0, "Front", Vector3.ZERO, Vector3.ZERO)
	panel.add_patched(_rgb(), 6, 0, "  ", Vector3.ZERO, Vector3.ZERO)
	ok(panel.patched_fixtures.map(func(f): return f["name"]) == ["RGB par #1", "Front", "RGB par #2"],
		"no name: the model, numbered (%s)" % str(panel.patched_fixtures.map(func(f): return f["name"])))
	main._on_add_universe()
	main._panels[1].add_patched(_rgb(), 0, 0, "", Vector3.ZERO, Vector3.ZERO)
	ok(main._panels[1].patched_fixtures[0]["name"] == "RGB par #3", "numbered across universes")
	panel._on_remove_fixture(panel.patched_fixtures[0]["id"])
	panel.add_patched(_rgb(), 0, 0, "", Vector3.ZERO, Vector3.ZERO)
	ok(panel.patched_fixtures[-1]["name"] == "RGB par #4", "a removed one's number isn't reused while later ones remain")
	# The Add Fixture button, with its Name field empty.
	panel.profile_option.selected = 0
	panel.fixture_name_edit.text = ""
	panel._on_add_fixture_pressed()
	var model: String = panel.available_profiles[0].model
	ok(panel.patched_fixtures[-1]["name"] == model + " #1", "Add Fixture with no name: %s" % panel.patched_fixtures[-1]["name"])
	var title: Label = panel.fixtures_vbox.get_child(panel.fixtures_vbox.get_child_count() - 1) \
		.find_children("*", "Label", true, false)[0]
	ok(title.text.begins_with(model + " #1  (ch ") and title.text.count(model) == 1 and model in title.tooltip_text,
		"the list shows just its name (%s); the model's in the tooltip" % title.text)
	main.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(STORE))


## The fixture list's row backgrounds, in order.
func _row_colours(panel) -> Array:
	var out: Array = []
	for row in panel.fixtures_vbox.get_children():
		if not row.is_queued_for_deletion():
			out.append((row.get_theme_stylebox("panel") as StyleBoxFlat).bg_color)
	return out


func _test_model_colours() -> void:
	print("- Model colours")
	var main: Control = load("res://main.tscn").instantiate()
	main.last_show_store = STORE
	root.add_child(main)
	await process_frame
	var dim := FixtureProfile.new("dim", "Dimmer", [{"name": "Dimmer", "role": "DIMMER"}])
	var panel = main._panels[0]
	var C: Array = panel.MODEL_COLOURS
	panel.add_patched(_rgb(), 0, 0, "", Vector3.ZERO, Vector3.ZERO)
	panel.add_patched(_bar(), 3, 0, "", Vector3.ZERO, Vector3.ZERO)
	panel.add_patched(_rgb(), 9, 0, "", Vector3.ZERO, Vector3.ZERO)
	main._on_add_universe()
	main._panels[1].add_patched(dim, 0, 0, "", Vector3.ZERO, Vector3.ZERO)
	main._panels[1].add_patched(_bar(), 1, 0, "", Vector3.ZERO, Vector3.ZERO)
	await process_frame
	ok(_row_colours(panel) == [C[0], C[1], C[0]], "a model's rows share a colour, in the order the models appear")
	ok(_row_colours(main._panels[1]) == [C[2], C[1]], "...across universes")
	var fills: Array = []
	for p in main.music_panel.timeline()._fixture_list.get_children():
		if not p.is_queued_for_deletion() and p.get_child_count() == 2:
			fills.append(p.get_child(1).fill)
	# The bar's two heads are timelines of their own, in its colour too.
	ok(fills == [C[0], C[1], C[1], C[1], C[0], C[2], C[1], C[1], C[1]], "the timelines' plates: %s" % str(fills))
	var bodies: Array = []
	for fv in main.viz_panel._fixture_root.get_children():
		if "body_colour" in fv and not fv.is_queued_for_deletion():
			bodies.append(fv.body_colour)
	ok(bodies == [C[0], C[1], C[0], C[2], C[1]], "the 3D Visualiser's bodies")
	# Removing the first RGB par leaves the bar first: the colours follow.
	panel._on_remove_fixture(panel.patched_fixtures[0]["id"])
	await process_frame
	ok(_row_colours(panel) == [C[0], C[1]] and _row_colours(main._panels[1]) == [C[2], C[0]],
		"removing a fixture recolours every universe")
	main.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(STORE))


func _artnet_count() -> int:
	return root.get_node("ArtNet").universe_count()


func _test_viz_ui_state() -> void:
	print("- the 3D Visualiser's UI shown / hidden, kept between runs")
	const UI_STORE := "user://_show_file_test_ui_state.json"
	var main: Control = load("res://main.tscn").instantiate()
	main.last_show_store = STORE
	main.ui_state_store = UI_STORE
	root.add_child(main)
	await process_frame
	ok(main.viz_panel.is_ui_visible() and main.viz_panel._toolbar.visible, "shown to start with")
	main.viz_panel._toggle_ui()
	ok(not main.viz_panel.is_ui_visible() and not main.viz_panel._toolbar.visible, "Hide UI hides it")
	main._save_ui_state()
	main.queue_free()
	await process_frame
	main = load("res://main.tscn").instantiate()
	main.last_show_store = STORE
	main.ui_state_store = UI_STORE
	root.add_child(main)
	await process_frame
	main._restore_ui_state()
	ok(not main.viz_panel.is_ui_visible() and not main.viz_panel._toolbar.visible
		and main.viz_panel._ui_toggle.text == "Show UI", "...and it's still hidden next time")
	# A state saved before this was kept: shown.
	var f := FileAccess.open(UI_STORE, FileAccess.WRITE)
	f.store_string(JSON.stringify({"viz_window": {"floating": false}}))
	f.close()
	main._restore_ui_state()
	ok(main.viz_panel.is_ui_visible(), "an older saved state: shown")
	main.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(UI_STORE))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(STORE))
