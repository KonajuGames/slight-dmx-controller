extends SceneTree
## Tests for the live flashes (LiveFlash: Blackout / Strobe / White /
## Colour over everything in the DMX frame), their MIDI / OSC bindings
## and their keys and buttons in DJ Perform Mode.
##
##   godot --headless --script tests/live_flash_test.gd

var _p := 0
var _f := 0

# LiveFlash reaches DjPerformer, which reaches the ArtNet autoload — a
# --script run can't resolve that at compile time, so it's loaded at run
# time.
var F: GDScript

const DIR := "user://_live_flash_test"


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
	print("== Live flashes ==")
	F = load("res://scripts/live_flash.gd")
	_test_output()
	_test_strobe()
	_test_wheel()
	_test_press_latch()
	_test_top_layer()
	_test_trigger_release()
	await _test_shell()
	print("== %d passed, %d failed ==" % [_p, _f])
	quit(1 if _f > 0 else 0)


## A par: dimmer, red, green, blue, white, amber, pan.
func _par() -> Dictionary:
	var p := FixtureProfile.new("flashpar", "Flash Par", [
		{"name": "Dimmer", "role": "DIMMER"}, {"name": "Red", "role": "RED"},
		{"name": "Green", "role": "GREEN"}, {"name": "Blue", "role": "BLUE"},
		{"name": "White", "role": "WHITE"}, {"name": "Amber", "role": "AMBER"},
		{"name": "Pan", "role": "PAN"},
	])
	return {"uid": "p", "u": 0, "start": 10, "mode": 0, "profile": p}


## An RGB bar head without a dimmer or strobe channel.
func _rgb() -> Dictionary:
	var p := FixtureProfile.new("flashrgb", "Flash RGB", [
		{"name": "Red", "role": "RED"}, {"name": "Green", "role": "GREEN"},
		{"name": "Blue", "role": "BLUE"},
	])
	return {"uid": "r", "u": 0, "start": 30, "mode": 0, "profile": p}


func _strober() -> Dictionary:
	var p := FixtureProfile.new("flashstrobe", "Flash Strobe", [
		{"name": "Shutter", "role": "STROBE", "ranges": [{"lo": 0, "hi": 9, "label": "Closed"},
			{"lo": 10, "hi": 19, "label": "Open"}, {"lo": 20, "hi": 240, "label": "Strobe slow-fast"}]},
		{"name": "Dimmer", "role": "DIMMER"}, {"name": "Red", "role": "RED"},
		{"name": "Green", "role": "GREEN"}, {"name": "Blue", "role": "BLUE"},
	])
	return {"uid": "s", "u": 0, "start": 50, "mode": 0, "profile": p}


func _test_output() -> void:
	print("- blackout, white and colour")
	var fx := [_par(), _rgb()]
	ok(F.output(fx, 1, [], Color.RED, 0.0)[0].is_empty(), "nothing on: nothing driven")
	var o: Dictionary = F.output(fx, 1, [F.BLACKOUT], Color.RED, 0.0)[0]
	ok(o.get(10) == 0 and o.get(11) == 0 and o.get(14) == 0 and o.get(15) == 0, "blackout: dimmer and colours to 0")
	ok(not o.has(16), "...pan left alone, so movers don't swing")
	ok(o.get(30) == 0 and o.get(32) == 0, "...and a fixture without a dimmer, its colours")
	o = F.output(fx, 1, [F.WHITE], Color.RED, 0.0)[0]
	ok(o.get(10) == 255 and o.get(11) == 255 and o.get(13) == 255 and o.get(14) == 255, "white: dimmer, RGB and white full")
	ok(o.get(15) == 0, "...amber off")
	ok(o.get(30) == 255 and o.get(31) == 255 and o.get(32) == 255, "...an RGB-only head full white")
	var c := Color(1.0, 0.5, 0.0)
	o = F.output(fx, 1, [F.COLOUR], c, 0.0)[0]
	ok(o.get(10) == 255 and o.get(11) == 255 and o.get(12) == 128 and o.get(13) == 0, "colour: dimmer full, RGB from the colour")
	ok(o.get(14) == 0 and o.get(15) == 0, "...white and amber off")
	o = F.output(fx, 1, [F.COLOUR, F.WHITE], c, 0.0)[0]
	ok(o.get(12) == 255, "white beats colour")
	o = F.output(fx, 1, [F.WHITE, F.BLACKOUT], c, 0.0)[0]
	ok(o.get(10) == 0 and o.get(11) == 0, "blackout beats everything")
	var other := _par()
	other["u"] = 1
	var two: Array = F.output([other], 2, [F.WHITE], c, 0.0)
	ok(two[0].is_empty() and two[1].get(10) == 255, "each fixture in its own universe")


func _test_strobe() -> void:
	print("- strobe")
	var fx := [_strober(), _rgb()]
	var o: Dictionary = F.output(fx, 1, [F.STROBE], Color.RED, 0.0)[0]
	ok(o.get(50) == 240 and o.get(51) == 255, "a strobe channel strobes fast, dimmer full")
	ok(not o.has(52), "...in the colours already playing")
	ok(not o.has(30), "a head without a strobe channel: lit part of the software strobe, as it was")
	o = F.output(fx, 1, [F.STROBE], Color.RED, 0.05)[0]
	ok(o.get(30) == 0 and o.get(32) == 0, "...dark the rest of it")
	ok(o.get(50) == 240 and o.get(51) == 255, "...the strobe channel's fixture stays lit (its shutter strobes)")
	o = F.output(fx, 1, [F.STROBE, F.WHITE], Color.RED, 0.0)[0]
	ok(o.get(50) == 240 and o.get(52) == 255 and o.get(30) == 255, "strobe + white: a white strobe")
	o = F.output(fx, 1, [F.WHITE], Color.RED, 0.0)[0]
	ok(o.get(50) == 10, "white alone opens the shutter (its Open value)")
	var plain := FixtureProfile.new("plain", "Plain", [{"name": "Strobe", "role": "STROBE"}])
	ok(F.open_value(plain.channels_for_mode(0)[0]) == 0, "...a strobe channel without ranges: 0")


func _test_wheel() -> void:
	print("- a colour wheel fixture")
	var spot := FixtureProfile.new("flashspot", "Flash Spot", [
		{"name": "Dimmer", "role": "DIMMER"},
		{"name": "Colour", "role": "COLOR_WHEEL", "ranges": [
			{"lo": 0, "hi": 9, "label": "Open", "color": "#ffffff"},
			{"lo": 10, "hi": 19, "label": "Red", "color": "#ff0000"},
			{"lo": 20, "hi": 29, "label": "Blue", "color": "#0000ff"},
		]},
	])
	var fx := [{"uid": "w", "u": 0, "start": 0, "mode": 0, "profile": spot}]
	ok(int(F.output(fx, 1, [F.COLOUR], Color.RED, 0.0)[0].get(1, -1)) == 14, "colour: the nearest slot (red)")
	ok(int(F.output(fx, 1, [F.WHITE], Color.RED, 0.0)[0].get(1, -1)) == 4, "white: the white slot")
	ok(not F.output(fx, 1, [F.BLACKOUT], Color.RED, 0.0)[0].has(1), "blackout leaves the wheel")


func _test_press_latch() -> void:
	print("- held and latched")
	var fl = F.new()
	var changes := [0]
	fl.changed.connect(func(): changes[0] += 1)
	fl.press(F.STROBE)
	ok(fl.is_on(F.STROBE) and fl.any_on(), "pressed: on")
	fl.release(F.STROBE)
	ok(not fl.any_on() and changes[0] == 2, "released: off")
	fl.latch = true
	fl.press(F.WHITE)
	fl.release(F.WHITE)
	ok(fl.is_on(F.WHITE), "latched: still on when let go")
	fl.press(F.WHITE)
	ok(not fl.is_on(F.WHITE), "...off at the next press")
	fl.toggle(F.COLOUR)
	fl.clear()
	ok(not fl.any_on(), "clear() lets go of everything")
	ok(fl.layer(2).size() == 2 and fl.layer(2)[0].is_empty(), "no fixtures provider: an empty layer")
	fl.colour = Color(0, 1, 0)
	var d: Dictionary = fl.to_dict()
	var back = F.new()
	back.from_dict(d)
	ok(back.colour.is_equal_approx(Color(0, 1, 0)) and back.latch, "colour and Latch saved")
	back.from_dict({})
	ok(back.colour == Color(1, 0, 0) and not back.latch, "older shows: red, held")


func _test_top_layer() -> void:
	print("- over the virtual dimmers")
	var u = load("res://scripts/artnet_universe.gd").new()
	u.set_channel(30, 200)
	u.set_virtual_dimmer(7, PackedInt32Array([30, 31, 32]))
	u.set_virtual_dimmer_level(7, 0.0)
	u.compute_output(1.0, {31: 100})
	ok(u.output[30] == 0 and u.output[31] == 0, "a fixture dimmed to 0 by its virtual dimmer: dark")
	u.compute_output(1.0, {31: 100}, {30: 255, 31: 255})
	ok(u.output[30] == 255 and u.output[31] == 255, "the top layer still lights it")
	u.compute_output(0.5, {}, {30: 255})
	ok(u.output[30] == 127, "...under the grand master")


func _test_trigger_release() -> void:
	print("- MIDI / OSC flash bindings")
	var t := Trigger.new()
	t.action = Trigger.ACT_FLASH_STROBE
	ok(t.is_flash() and t.flash_kind() == F.STROBE, "a flash action works its flash")
	ok(t.can_feedback() and t.feedback_query() == ["flash", str(F.STROBE)], "...and its pad can follow it")
	ok(Trigger.ACTIONS.size() == Trigger.ACT_FLASH_COLOUR + 1, "every action named")
	t.midi_number = 40
	var ev := InputEventMIDI.new()
	ev.message = MIDI_MESSAGE_NOTE_ON
	ev.pitch = 40
	ev.velocity = 100
	ok(t.matches_midi(ev) and not t.matches_midi_release(ev), "note-on: pressed")
	ev.velocity = 0
	ok(t.matches_midi_release(ev), "note-on at velocity 0: released")
	ev.message = MIDI_MESSAGE_NOTE_OFF
	ok(t.matches_midi_release(ev), "note-off: released")
	ev.pitch = 41
	ok(not t.matches_midi_release(ev), "...not another note's")
	t.midi_kind = Trigger.MIDI_CC
	ev.message = MIDI_MESSAGE_CONTROL_CHANGE
	ev.controller_number = 40
	ev.controller_value = 10
	ok(t.matches_midi_release(ev) and not t.matches_midi(ev), "CC below 64: released")
	t.source = Trigger.SRC_OSC
	t.osc_address = "/flash/strobe"
	var msg := OscMessage.new()
	msg.address = "/flash/strobe"
	msg.args = [0.0]
	ok(t.matches_osc_release(msg) and not t.matches_osc(msg), "OSC 0: released")
	msg.args = [1.0]
	ok(t.matches_osc(msg) and not t.matches_osc_release(msg), "OSC 1: pressed")
	msg.args = []
	ok(not t.matches_osc_release(msg), "OSC without arguments: a press only")


func _key(code: Key, down: bool) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = down
	return ev


func _test_shell() -> void:
	print("- in the app")
	DirAccess.make_dir_recursive_absolute(DIR)
	var main: Control = load("res://main.tscn").instantiate()
	main.last_show_store = DIR + "/last.json"
	main.ui_state_store = DIR + "/ui.json"
	root.add_child(main)
	await process_frame
	var art := root.get_node("ArtNet")
	var p: Dictionary = _par()
	main._panels[0].add_patched(p["profile"], 10, 0, "Par", Vector3.ZERO, Vector3.ZERO)
	art.get_universe(0).set_channel(10, 100)
	art.tick(false)
	ok(art.get_universe(0).output[10] == 100, "the console's level goes out")
	main._unhandled_key_input(_key(KEY_B, true))
	ok(not main.flash.any_on(), "B does nothing in the console view")
	main.perform_panel.visible = true
	main._unhandled_key_input(_key(KEY_B, true))
	art.tick(false)
	ok(main.flash.is_on(F.BLACKOUT) and art.get_universe(0).output[10] == 0, "held B in DJ Perform Mode: blackout")
	ok(main._feedback_state("flash", str(F.BLACKOUT)), "...its feedback pads light")
	var btn: Button = main.perform_panel._flash_btns[F.BLACKOUT]
	ok(btn.has_theme_stylebox_override("normal"), "...and its button")
	main._unhandled_key_input(_key(KEY_B, false))
	art.tick(false)
	ok(not main.flash.any_on() and art.get_universe(0).output[10] == 100, "let go: the console's level again")
	ok(not btn.has_theme_stylebox_override("normal"), "...its button unlit")
	main._on_trigger_fired(Trigger.ACT_FLASH_WHITE, "")
	art.tick(false)
	ok(art.get_universe(0).output[14] == 255, "a pad held: white")
	main._on_trigger_released(Trigger.ACT_FLASH_WHITE, "")
	ok(not main.flash.any_on(), "...released")
	main._on_trigger_fired(Trigger.ACT_FLASH_COLOUR, Trigger.FLASH_TOGGLE)
	main._on_trigger_fired(Trigger.ACT_FLASH_STROBE, "")
	main._on_trigger_released(Trigger.ACT_FLASH_STROBE, "")
	ok(main.flash.is_on(F.COLOUR) and not main.flash.is_on(F.STROBE), "a Program Change flash toggles on")
	main._on_trigger_fired(Trigger.ACT_FLASH_COLOUR, Trigger.FLASH_TOGGLE)
	ok(not main.flash.any_on(), "...and off")
	main.perform_panel._latch.button_pressed = true
	main.flash.colour = Color(0, 0, 1)
	var d: Dictionary = main.show_dict()
	ok(d["live_flash"]["latch"] == true and d["live_flash"]["colour"] == "0000ff", "colour and Latch saved with the show")
	main.flash.press(F.WHITE)
	main.apply_show_dict({"universes": [{}], "live": [{}]})
	ok(not main.flash.any_on() and not main.flash.latch and not main.perform_panel._latch.button_pressed,
		"another show: all let go, its settings (none: held, red)")
	main.queue_free()
	await process_frame
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR.path_join(f))
	DirAccess.remove_absolute(DIR)
