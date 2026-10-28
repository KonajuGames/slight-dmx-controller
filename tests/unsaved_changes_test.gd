extends SceneTree
## Tests for the show's unsaved-changes tracking: the title bar's "*" and
## the Save / Don't Save / Cancel prompt before New, Load and quitting.
##
##   godot --headless --script tests/unsaved_changes_test.gd
##
## Everything goes to scratch files under user://_unsaved_test.

var _p := 0
var _f := 0

const DIR := "user://_unsaved_test"


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
	print("== Unsaved changes ==")
	DirAccess.make_dir_recursive_absolute(DIR)
	await _test()
	_clean()
	print("== %d passed, %d failed ==" % [_p, _f])
	quit(1 if _f > 0 else 0)


func _clean() -> void:
	for d in [DIR + "/show.timelines", DIR]:
		if DirAccess.dir_exists_absolute(d):
			for f in DirAccess.get_files_at(d):
				DirAccess.remove_absolute(d.path_join(f))
			DirAccess.remove_absolute(d)


func _main() -> Control:
	var main: Control = load("res://main.tscn").instantiate()
	main.last_show_store = DIR + "/last.json"
	main.ui_state_store = DIR + "/ui.json"
	main.autosave.file = DIR + "/autosave.slight"
	main.autosave.session_file = DIR + "/session.json"
	return main


## The open "Unsaved Changes" dialog under `main`, or null.
func _prompt(main: Control) -> ConfirmationDialog:
	for c in main.get_children():
		if c is ConfirmationDialog and c.title == "Unsaved Changes" and not c.is_queued_for_deletion():
			return c
	return null


func _test() -> void:
	var main := _main()
	root.add_child(main)
	await process_frame
	ok(not main.has_unsaved_changes(), "a fresh show has nothing unsaved")
	main._update_title()
	ok(main.get_window().title == "Untitled — sLight", "title: %s" % main.get_window().title)

	var path := DIR + "/show.slight"
	main.save_show_to(path)
	ok(main.get_window().title == "show — sLight", "saved: named, no * (%s)" % main.get_window().title)

	# Playing the show isn't an edit.
	main._panels[0].sender.set_channel(0, 200)
	main.viz_panel._cam_yaw += 0.5
	ok(not main.has_unsaved_changes(), "live levels and the camera moving: still saved")

	# The connection type is.
	main._panels[0].output_option.selected = OUT_SACN()
	main._panels[0].apply_connection()
	ok(main.has_unsaved_changes(), "the output switched to sACN: unsaved")
	main._update_title()
	ok(main.get_window().title == "*show — sLight", "...and the title says so (%s)" % main.get_window().title)

	# New Show with unsaved changes asks first; Cancel leaves it alone.
	main.cue_panel.record_cue()
	var cues: int = main.cue_panel.cues.size()
	var ran := [0]
	main.confirm_unsaved("testing", func(): ran[0] += 1)
	var dlg := _prompt(main)
	ok(dlg != null and ran[0] == 0, "unsaved: asks before going on")
	ok(dlg != null and "show" in dlg.dialog_text, "...naming the show: %s" % (dlg.dialog_text if dlg else ""))
	dlg.canceled.emit()
	ok(ran[0] == 0 and main.has_unsaved_changes(), "Cancel: doesn't go on")

	# Don't Save goes on without saving.
	main.confirm_unsaved("testing", func(): ran[0] += 1)
	_prompt(main).custom_action.emit(&"discard")
	ok(ran[0] == 1 and main.has_unsaved_changes(), "Don't Save: goes on, still unsaved")

	# Save saves to the show file, then goes on.
	main.confirm_unsaved("testing", func(): ran[0] += 1)
	_prompt(main).confirmed.emit()
	ok(ran[0] == 2 and not main.has_unsaved_changes(), "Save: saved, then goes on")
	var other := _main()
	root.add_child(other)
	await process_frame
	other.load_show_from(path)
	ok(other.cue_panel.cues.size() == cues and other._panels[0].sender.output_mode == OUT_SACN(),
		"...the file has the cue and the sACN output")
	ok(not other.has_unsaved_changes(), "a show just loaded has nothing unsaved")
	other.queue_free()

	# Nothing unsaved: no prompt at all.
	main.confirm_unsaved("testing", func(): ran[0] += 1)
	ok(ran[0] == 3 and _prompt(main) == null, "nothing unsaved: goes straight on")

	main.new_show()
	ok(not main.has_unsaved_changes() and main.show_name() == "Untitled", "a new show: Untitled, nothing unsaved")
	main.queue_free()
	await process_frame


## ArtNetUniverse.OUT_SACN, loaded at run time (it needs the ArtNet autoload).
func OUT_SACN() -> int:
	return load("res://scripts/artnet_universe.gd").OUT_SACN
