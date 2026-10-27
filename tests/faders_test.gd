extends SceneTree
## Tests for the playback faders (FaderBank and the Faders tab): cue
## submasters, chase faders, group masters, MIDI Learn and the show file.
##
##   godot --headless --script tests/faders_test.gd

var _p := 0
var _f := 0

const DIR := "user://_faders_test"

# These reach the ArtNet / Fx autoloads, which a --script run can't
# resolve at compile time — so they're loaded at run time.
var Bank: GDScript
var CueScript: GDScript
var ChaseScript: GDScript


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
	print("== Playback faders ==")
	Bank = load("res://scripts/fader_bank.gd")
	CueScript = load("res://scripts/cue.gd")
	ChaseScript = load("res://scripts/chase.gd")
	_test_intensity_map()
	_test_cue_output()
	await _test_app()
	print("== %d passed, %d failed ==" % [_p, _f])
	quit(1 if _f > 0 else 0)


## Dimmer, pan, red, green, blue.
func _spot() -> FixtureProfile:
	return FixtureProfile.new("fspot", "Fader Spot", [
		{"name": "Dimmer", "role": "DIMMER"}, {"name": "Pan", "role": "PAN"},
		{"name": "Red", "role": "RED"}, {"name": "Green", "role": "GREEN"},
		{"name": "Blue", "role": "BLUE"},
	])


## Red, green, blue (no dimmer).
func _rgb() -> FixtureProfile:
	return FixtureProfile.new("frgb", "Fader RGB", [
		{"name": "Red", "role": "RED"}, {"name": "Green", "role": "GREEN"},
		{"name": "Blue", "role": "BLUE"},
	])


func _test_intensity_map() -> void:
	print("- intensity channels")
	var fx := [{"uid": "a", "u": 0, "start": 0, "mode": 0, "profile": _spot()},
		{"uid": "b", "u": 0, "start": 10, "mode": 0, "profile": _rgb()},
		{"uid": "c", "u": 1, "start": 0, "mode": 0, "profile": _rgb()}]
	var m: Array = Bank.intensity_map(fx, 2)
	ok(m[0].has(0) and not m[0].has(1) and not m[0].has(2), "a fixture with a dimmer: just its dimmer")
	ok(m[0].has(10) and m[0].has(11) and m[0].has(12), "one without: its colours")
	ok(m[1].has(0), "per universe")
	var only: Array = Bank.intensity_map(fx, 2, {"b": true})
	ok(not only[0].has(0) and only[0].has(10) and only[1].is_empty(), "just the fixtures asked for")


func _test_cue_output() -> void:
	print("- cue submasters")
	var inten := [{0: true, 10: true}]
	var look := [{"0": 200, "1": 90, "10": 100}]
	var base := PackedByteArray()
	base.resize(512)
	var o: Dictionary = Bank.cue_output([[look, 0.5]], inten, [base], 1)[0]
	ok(o[0] == 100 and o[10] == 50, "intensity scaled by the fader (%d, %d)" % [o[0], o[10]])
	ok(o[1] == 90, "anything else at the look's value")
	base[0] = 150
	o = Bank.cue_output([[look, 0.5]], inten, [base], 1)[0]
	ok(o[0] == 150, "the stage higher: it wins (HTP)")
	var other := [{"0": 255, "1": 10}]
	o = Bank.cue_output([[look, 0.5], [other, 0.2]], inten, [PackedByteArray()], 1)[0]
	ok(o[0] == 100, "two submasters: the higher intensity")
	ok(o[1] == 90, "...the higher fader's other channels")


func _main() -> Control:
	var main: Control = load("res://main.tscn").instantiate()
	main.last_show_store = DIR + "/last.json"
	main.ui_state_store = DIR + "/ui.json"
	return main


func _test_app() -> void:
	print("- in the app")
	DirAccess.make_dir_recursive_absolute(DIR)
	var main := _main()
	root.add_child(main)
	await process_frame
	var art := root.get_node("ArtNet")
	var fx_node := root.get_node("Fx")
	var u = art.get_universe(0)
	main._panels[0].add_patched(_spot(), 0, 0, "Spot", Vector3.ZERO, Vector3.ZERO)
	main._panels[0].add_patched(_rgb(), 10, 0, "Par", Vector3.ZERO, Vector3.ZERO)
	var spot_uid := String(main._panels[0].patched_fixtures[0]["uid"])
	var par_uid := String(main._panels[0].patched_fixtures[1]["uid"])
	u.set_all(0)
	var bank = main.faders

	# A cue submaster.
	var cue = CueScript.new("Look", 0.0, 0.0)
	cue.set_levels([{0: 200, 1: 77, 10: 120}])
	main.cue_panel.cues.append(cue)
	main.cue_panel.cues_changed.emit()
	bank.add_fader()
	bank.set_target(0, Bank.KIND_CUE, "1")
	art.tick(false)
	ok(u.output[0] == 0 and u.output[1] == 0, "a cue fader at 0: nothing")
	bank.set_level(0, 0.5)
	art.tick(false)
	ok(u.output[0] == 100 and u.output[10] == 60, "half way: the cue's intensity at half (%d, %d)" % [u.output[0], u.output[10]])
	ok(u.output[1] == 77, "...its pan at the cue's")
	bank.set_level(0, 0.0)

	# A chase fader.
	var chase = ChaseScript.new()
	chase.name = "Pulse"
	chase.steps = [[{"0": 255, "1": 30}], [{"0": 255, "1": 30}]]
	fx_node.chases.append(chase)
	main.chase_panel.chases_changed.emit()
	bank.add_fader()
	bank.set_target(1, Bank.KIND_CHASE, "pulse")
	ok(not chase.running, "a chase fader at 0: the chase isn't running")
	bank.set_level(1, 0.4)
	art.tick(false)
	ok(chase.running and u.output[0] == 102, "up to 40%%: it runs, its intensity at 40%% (%d)" % u.output[0])
	ok(u.output[1] == 30, "...its other channels as they are")
	bank.set_level(1, 0.0)
	ok(not chase.running and chase.level == 1.0, "down to 0: stopped, and the Chases tab's again")
	chase.running = true                    # run from the Chases tab
	bank.set_level(1, 0.0)
	ok(chase.running, "...a chase run from the Chases tab isn't stopped by a fader that's down")
	chase.running = false

	# A group master.
	main.groups.append({"name": "Pars", "members": [par_uid]})
	bank.add_fader()
	bank.set_target(2, Bank.KIND_GROUP, "Pars")
	u.set_channel(10, 200)
	u.set_channel(0, 200)
	bank.set_level(2, 1.0)
	art.tick(false)
	ok(u.output[10] == 200, "a group master full: nothing taken away")
	bank.set_level(2, 0.25)
	art.tick(false)
	ok(u.output[10] == 50 and u.output[0] == 200, "at 25%%: the group's intensity at a quarter, others untouched (%d)" % u.output[10])
	main.flash.press(main.flash.WHITE)
	art.tick(false)
	ok(u.output[10] == 255, "a live flash still goes over it")
	main.flash.clear()

	# MIDI.
	bank.learn(0)
	var ev := InputEventMIDI.new()
	ev.message = MIDI_MESSAGE_CONTROL_CHANGE
	ev.channel = 2
	ev.controller_number = 7
	ev.controller_value = 127
	ok(bank.handle_midi(ev) and bank.faders[0].midi_cc == 7 and bank.faders[0].midi_channel == 2,
		"Learn: the next CC maps the fader")
	ok(bank.faders[0].level == 1.0 and not bank.is_learning(0), "...moves it, and Learn ends")
	ev.controller_value = 64
	bank.handle_midi(ev)
	ok(absf(bank.faders[0].level - 64.0 / 127.0) < 0.001, "the CC moves it")
	ev.channel = 3
	ev.controller_value = 0
	ok(not bank.handle_midi(ev) and bank.faders[0].level > 0.4, "...not the same CC on another channel")

	# The panel.
	var panel = main.faders_panel
	ok(panel._rows.size() == 3, "a strip per fader")
	ok(absf(panel._rows[0]["slider"].value - 64.0 / 127.0) < 0.001 and panel._rows[0]["level"].text == "50%",
		"its fader follows MIDI (%s)" % panel._rows[0]["level"].text)
	ok(panel._rows[0]["learn"].text == "CC 7 · ch 3", "its Learn button shows the mapping: %s" % panel._rows[0]["learn"].text)
	ok(panel._rows[1]["target"].get_item_text(panel._rows[1]["target"].selected) == "Pulse", "its target picked")
	panel._rows[0]["slider"].value = 0.75
	ok(bank.faders[0].level == 0.75, "moving it moves the fader")

	# Blackout All.
	bank.set_level(1, 0.5)
	main._on_blackout_all()
	ok(bank.faders[0].level == 0.0 and bank.faders[1].level == 0.0 and not chase.running,
		"Blackout All pulls the cue and chase faders down")
	ok(bank.faders[2].level == 0.25, "...not the group master")

	# The show file.
	bank.set_level(1, 0.6)
	var d: Dictionary = main.show_dict()
	ok(d["faders"]["faders"].size() == 3 and d["faders"]["faders"][1]["kind"] == "chase", "saved with the show")
	bank.set_level(1, 0.0)
	main.apply_show_dict(d)
	var c2 = fx_node.chases[0]
	ok(main.faders.faders.size() == 3 and main.faders.faders[0].midi_cc == 7, "loaded back, MIDI mapping and all")
	ok(c2.running and absf(c2.level - 0.6) < 0.001, "a chase fader that was up runs its chase again")
	main.apply_show_dict({"universes": [{}], "live": [{}]})
	ok(main.faders.faders.is_empty() and not c2.running, "a show without faders: none, and the chase let go")
	ok(panel._rows.is_empty(), "...no strips")

	main.queue_free()
	await process_frame
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR.path_join(f))
	DirAccess.remove_absolute(DIR)
