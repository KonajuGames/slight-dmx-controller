extends SceneTree
## Tests for the virtual dimmer: a fixture with colour channels but no
## DIMMER channel gets one, applied to the universe's output frame without
## changing the colour channels' stored values.
##
##   godot --headless --script tests/virtual_dimmer_test.gd

var _p := 0
var _f := 0
var _s := 0

# The universe and its panel reach autoloads (ArtNet, UsbDmx), which a
# --script run can't resolve at compile time — so they're loaded at run time.


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
	print("== Virtual dimmer ==")
	_test_profile()
	_test_universe()
	await _test_panel()
	print("== %d passed, %d failed, %d skipped ==" % [_p, _f, _s])
	quit(1 if _f > 0 else 0)


func _rgbw() -> FixtureProfile:
	return FixtureProfile.new("rgbw", "RGBW par", [
		{"name": "Red", "role": "RED"}, {"name": "Green", "role": "GREEN"},
		{"name": "Blue", "role": "BLUE"}, {"name": "White", "role": "WHITE"},
		{"name": "Strobe", "role": "STROBE"},
	])


func _dimmed_rgb() -> FixtureProfile:
	return FixtureProfile.new("drgb", "Dimmer RGB par", [
		{"name": "Dimmer", "role": "DIMMER"}, {"name": "Red", "role": "RED"},
		{"name": "Green", "role": "GREEN"}, {"name": "Blue", "role": "BLUE"},
	])


func _test_profile() -> void:
	print("- which channels a virtual dimmer scales")
	ok(_rgbw().virtual_dimmer_channels(0) == PackedInt32Array([0, 1, 2, 3]),
		"no dimmer channel: the colour / white channels (not the strobe)")
	ok(_dimmed_rgb().virtual_dimmer_channels(0).is_empty(), "a real dimmer channel: none")
	var pan_only := FixtureProfile.new("pt", "Pan/tilt", [{"name": "Pan", "role": "PAN"}, {"name": "Tilt", "role": "TILT"}])
	ok(pan_only.virtual_dimmer_channels(0).is_empty(), "no colour channels: none")


func _test_universe() -> void:
	print("- applied when the frame is built")
	var u = load("res://scripts/artnet_universe.gd").new()
	for i in range(5):
		u.set_channel(10 + i, 200)
	u.set_virtual_dimmer(1, PackedInt32Array([10, 11, 12, 13]))
	ok(u.has_virtual_dimmer(1) and u.virtual_dimmer_level(1) == 1.0, "starts open")
	u.compute_output()
	ok(u.output[10] == 200 and u.output[13] == 200, "open: output = the colour")
	u.set_virtual_dimmer_level(1, 0.5)
	u.compute_output()
	ok(u.output[10] == 100 and u.output[13] == 100, "50 %: colour channels halved in the output")
	ok(u.output[14] == 200, "channels outside it untouched")
	ok(u.dmx_data[10] == 200 and u.get_channel(13) == 200, "stored colour values unchanged")
	u.compute_output(0.5)
	ok(u.output[10] == 50 and u.output[14] == 100, "the grand master still applies on top")
	u.compute_output(1.0, {11: 80})
	ok(u.output[11] == 40, "scales effect / chase overrides too")
	u.set_virtual_dimmer(1, PackedInt32Array([10, 11, 12, 13]))
	ok(u.virtual_dimmer_level(1) == 0.5, "re-registering keeps the level")
	u.remove_virtual_dimmer(1)
	u.compute_output()
	ok(u.output[10] == 200 and u.virtual_dimmer_level(1) == 1.0, "removed: full output")


func _test_panel() -> void:
	print("- the fixture panel's virtual dimmer")
	var u = load("res://scripts/artnet_universe.gd").new()
	var panel = load("res://scripts/universe_panel.gd").new()
	panel.sender = u
	panel.available_profiles = [_rgbw(), _dimmed_rgb()]
	root.add_child(panel)
	await process_frame
	panel.add_patched(_rgbw(), 0, 0, "Par A", Vector3.ZERO, Vector3.ZERO)
	panel.add_patched(_dimmed_rgb(), 10, 0, "Par B", Vector3.ZERO, Vector3.ZERO)
	var id_a := int(panel.patched_fixtures[0]["id"])
	var id_b := int(panel.patched_fixtures[1]["id"])
	ok(u.has_virtual_dimmer(id_a) and not u.has_virtual_dimmer(id_b),
		"only the fixture without a dimmer channel gets one")
	ok(u.virtual_dimmers[id_a]["channels"] == PackedInt32Array([0, 1, 2, 3]), "on its universe channels")
	await process_frame                # let the rebuilt rows replace the old
	var slider := _find_vdim_slider(panel)
	ok(slider != null, "a virtual dimmer slider in its controls")
	if slider == null:
		panel.queue_free()
		return
	u.set_channel(0, 255)
	u.set_channel(3, 128)
	slider.value = 51                  # 20 %
	u.compute_output()
	ok(is_equal_approx(u.virtual_dimmer_level(id_a), 0.2), "the slider sets the level")
	ok(u.dmx_data[0] == 255 and u.dmx_data[3] == 128, "colour channels keep the actual colour")
	ok(u.output[0] == 51 and u.output[3] == 26, "the frame carries the dimmed colour")
	panel.load_look(PackedByteArray([10, 20, 30, 40]))
	ok(u.virtual_dimmer_level(id_a) == 1.0 and u.dmx_data[0] == 10, "loading a look opens it, colour as stored")
	panel._on_remove_fixture(id_a)
	ok(not u.has_virtual_dimmer(id_a), "removing the fixture drops it")
	panel.apply_patch_dict({"fixtures": [{"name": "Par C", "start": 20, "profile": _rgbw().to_dict()}]})
	ok(u.virtual_dimmers.size() == 1 and not u.has_virtual_dimmer(id_b)
		and u.virtual_dimmers.values()[0]["channels"] == PackedInt32Array([20, 21, 22, 23]),
		"a reloaded patch replaces them")
	panel.queue_free()


func _find_vdim_slider(n: Node) -> VSlider:
	for c in n.get_children():
		if c is VBoxContainer and c.get_child_count() > 1 and c.get_child(0) is Label \
				and (c.get_child(0) as Label).text == "Dimmer\n(virtual)":
			return c.get_child(1) as VSlider
		var found := _find_vdim_slider(c)
		if found != null:
			return found
	return null
