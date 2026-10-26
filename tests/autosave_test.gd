extends SceneTree
## Tests for autosave and crash recovery (Autosave, and the shell's use of
## it).
##
##   godot --headless --script tests/autosave_test.gd
##
## Everything goes to scratch files under user://_autosave_test, never the
## app's own autosave or session files.

var _p := 0
var _f := 0

const DIR := "user://_autosave_test"


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
	print("== Autosave ==")
	DirAccess.make_dir_recursive_absolute(DIR)
	_test_autosave()
	await _test_shell()
	_clean()
	print("== %d passed, %d failed ==" % [_p, _f])
	quit(1 if _f > 0 else 0)


func _clean() -> void:
	for d in [DIR + "/show.timelines", DIR]:
		if DirAccess.dir_exists_absolute(d):
			for f in DirAccess.get_files_at(d):
				DirAccess.remove_absolute(d.path_join(f))
			DirAccess.remove_absolute(d)


func _new_autosave():
	var a = load("res://scripts/autosave.gd").new()
	a.file = DIR + "/autosave.slight"
	a.session_file = DIR + "/session.json"
	return a


func _test_autosave() -> void:
	print("- snapshots and sessions")
	var a = _new_autosave()
	ok(a.begin().is_empty(), "a first run: nothing to recover")
	var show := {"format": "sLight show", "cues": {"cues": [1, 2]}}
	a.mark_saved(show)
	ok(not a.tick(show, "D:/x.slight") and not FileAccess.file_exists(a.file), "unchanged since it was saved: no snapshot")
	show["cues"] = {"cues": [1, 2, 3]}
	ok(a.tick(show, "D:/x.slight") and FileAccess.file_exists(a.file), "changed: a snapshot")
	ok(not a.tick(show, "D:/x.slight"), "...and not again until it changes again")
	show["cues"] = {"cues": [4]}
	ok(a.tick(show, "D:/x.slight"), "changed again: written over the last one")
	ok(not FileAccess.file_exists(a.file + ".tmp"), "...no temporary file left behind")
	var snap: Dictionary = a.read()
	ok(snap.get("show_path") == "D:/x.slight" and snap["show"]["cues"]["cues"] == [4.0], "it holds the show and its file")
	ok(absi(int(snap["saved_at"]) - int(Time.get_unix_time_from_system())) < 5, "...and when")
	ok(":" in a.when(snap) and a.when(snap).length() == 5, "taken today: just the time (%s)" % a.when(snap))
	ok(a.when({"saved_at": 0}).begins_with("1970-01-0"), "another day: the date too (%s)" % a.when({"saved_at": 0}))
	# The app's killed here: the next start finds the session still marked.
	var b = _new_autosave()
	var found: Dictionary = b.begin()
	ok(found.get("show", {}).get("cues", {}).get("cues") == [4.0], "after a crash: the snapshot is handed back")
	b.end()
	ok(not FileAccess.file_exists(b.file), "a clean quit removes it")
	var c = _new_autosave()
	ok(c.begin().is_empty(), "after a clean quit: nothing to recover")
	# Crashed with no snapshot (nothing changed): nothing either.
	var d = _new_autosave()
	ok(d.begin().is_empty(), "crashed, but nothing was autosaved: nothing")
	var f := FileAccess.open(d.file, FileAccess.WRITE)
	f.store_string("{ not json")
	f.close()
	ok(d.read().is_empty(), "an unreadable snapshot is ignored")
	d.end()


func _main() -> Control:
	var main: Control = load("res://main.tscn").instantiate()
	main.last_show_store = DIR + "/last.json"
	main.ui_state_store = DIR + "/ui.json"
	main.autosave.file = DIR + "/autosave.slight"
	main.autosave.session_file = DIR + "/session.json"
	return main


func _test_shell() -> void:
	print("- in the app")
	var main := _main()
	root.add_child(main)
	await process_frame
	ok(main.autosave.begin().is_empty(), "started cleanly")
	var path := DIR + "/show.slight"
	ok(main.save_show_to(path) == "", "a show saved")
	ok(not main.autosave_now(), "unchanged since: no autosave")
	main.cue_panel.record_cue()
	ok(main.autosave_now(), "a cue recorded: autosaved")
	ok(main.autosave.read()["show_path"] == ProjectSettings.globalize_path(path) or main.autosave.read()["show_path"] == path,
		"...for its show file")
	var cues: int = main.cue_panel.cues.size()
	# Killed without quitting: a new run starts.
	main.queue_free()
	await process_frame
	main = _main()
	root.add_child(main)
	await process_frame
	main.load_show_from(path)
	ok(main.cue_panel.cues.size() == cues - 1, "the show file is as it was saved")
	var snap: Dictionary = main.recovery_offer()
	ok(not snap.is_empty(), "the autosave is offered")
	ok(main.restore_autosave(snap) == "", "and restored")
	ok(main.cue_panel.cues.size() == cues and main.show_path == path, "...with the cue, for the same show file")
	ok("autosaved" in main.status_label.text, "the status says so: %s" % main.status_label.text)
	ok(main.autosave.changed_since(main.show_dict()), "...and that it's not saved yet")
	main.save_show_to(path)
	main.autosave.end()
	# Crashed again, but the snapshot is what's in the show file anyway.
	main.autosave.begin()
	main.cue_panel.record_cue()
	main.autosave_now()
	main.save_show_to(path)
	ok(main.autosave.begin().size() > 0 and main.recovery_offer().is_empty(),
		"a snapshot that matches the show as it is: not offered")
	main.queue_free()
	await process_frame
