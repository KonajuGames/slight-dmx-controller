extends SceneTree
## Tests for DmxRender — a fixture's live DMX turned into what the 3D
## visualizer shows.
##
##   godot --headless --script tests/dmx_render_test.gd

var _p := 0
var _f := 0


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
	print("== DMX render ==")
	_test_fine()
	await _test_effect_targets()
	print("== %d passed, %d failed ==" % [_p, _f])
	quit(1 if _f > 0 else 0)


## The visualizer's dimmer for a 16-bit level `v` on `prof`'s first two
## channels (coarse, then fine).
func _dimmer(prof: FixtureProfile, v: int) -> float:
	return float(DmxRender.evaluate(prof, 0, PackedByteArray([v >> 8, v & 0xFF, 0, 0]), 0)["dimmer"])


func _test_fine() -> void:
	print("- 16-bit channels")
	# The fine channel carrying its coarse channel's role, as some
	# profiles have it.
	var same_role := FixtureProfile.new("d16", "Dimmer 16", [
		{"name": "Dimmer", "role": "DIMMER"},
		{"name": "Dimmer Fine", "role": "DIMMER", "fine": true},
	])
	var generic_fine := FixtureProfile.new("d16g", "Dimmer 16 G", [
		{"name": "Dimmer", "role": "DIMMER"},
		{"name": "Dimmer Fine", "role": "GENERIC", "fine": true},
	])
	for prof in [same_role, generic_fine]:
		var steady := true
		var last := -1.0
		for v in range(0, 65536, 97):
			var d := _dimmer(prof, v)
			steady = steady and d >= last - 0.0001
			last = d
		ok(steady, "%s: the dimmer only rises as the 16-bit level does (no snapping back)" % prof.model)
		ok(is_equal_approx(_dimmer(prof, 0x8000), 0x8000 / 65535.0) and is_equal_approx(_dimmer(prof, 65535), 1.0),
			"%s: coarse is the high byte (half at 0x8000, full at 0xFFFF)" % prof.model)
	var pan := FixtureProfile.new("p16", "Pan 16", [
		{"name": "Pan", "role": "PAN"},
		{"name": "Pan Fine", "role": "PAN", "fine": true},
	], [], {"pan_range": 540.0})
	var st := DmxRender.evaluate(pan, 0, PackedByteArray([0xC0, 0x00]), 0)
	var expect := (0xC000 / 65535.0 - 0.5) * 540.0
	ok(absf(float(st["pan"]) - expect) < 0.01, "a fine channel with PAN's role doesn't take over the pan (%.2f)" % float(st["pan"]))


func _test_effect_targets() -> void:
	print("- effects' targets")
	var main: Control = load("res://main.tscn").instantiate()
	main.last_show_store = "user://_dmx_render_test_last.json"
	root.add_child(main)
	await process_frame
	var panel = main._panels[0]
	panel.apply_patch_dict({"fixtures": []})
	panel.add_patched(FixtureProfile.new("d16", "Dimmer 16", [
		{"name": "Dimmer", "role": "DIMMER"},
		{"name": "Dimmer Fine", "role": "DIMMER", "fine": true},
	]), 10, 0, "Dim", Vector3.ZERO, Vector3(90, 0, 0))
	var targets: Array = main._resolve_fx_targets("DIMMER", -1)
	ok(targets.size() == 1 and int(targets[0]["ch"]) == 10, "an effect on DIMMER drives the coarse channel, not the fine one")
	panel.apply_patch_dict({"fixtures": []})
	main.queue_free()
