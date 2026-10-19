extends SceneTree
## Tests for fixture profiles' manufacturer and model: saved and loaded,
## older profiles' single name, the bundled library, GDTF import and the
## MVR export's GDTF.
##
##   godot --headless --script tests/fixture_profile_test.gd

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
	print("== Fixture profiles ==")
	_test_names()
	_test_library()
	_test_gdtf()
	print("== %d passed, %d failed ==" % [_p, _f])
	quit(1 if _f > 0 else 0)


func _par() -> FixtureProfile:
	return FixtureProfile.new("acme-par", "Par 7", [
		{"name": "Red", "role": "RED"}, {"name": "Green", "role": "GREEN"},
		{"name": "Blue", "role": "BLUE"},
	], [], {}, "Acme")


func _test_names() -> void:
	print("- manufacturer and model")
	var p := _par()
	ok(p.manufacturer == "Acme" and p.model == "Par 7" and p.full_name() == "Acme Par 7", "a profile has both")
	ok(FixtureProfile.new("x", "Solo").full_name() == "Solo", "...the model alone without a manufacturer")
	var d := p.to_dict()
	ok(d.get("manufacturer") == "Acme" and d.get("model") == "Par 7" and not d.has("profile_name"), "saved as manufacturer and model")
	var back := FixtureProfile.from_dict(d)
	ok(back.manufacturer == "Acme" and back.model == "Par 7", "...and loaded back")
	var old := FixtureProfile.from_dict({"id": "old", "profile_name": "My Wash", "modes": []})
	ok(old.model == "My Wash" and old.manufacturer == "", "an older profile's name becomes its model")
	var builtins := FixtureProfile.built_in_profiles()
	ok(builtins.all(func(b): return b.manufacturer == "Generic" and b.model != ""), "built-ins: Generic, with their models")


func _test_library() -> void:
	print("- the bundled library")
	var lib: Node = root.get_node("Library")
	var e: Dictionary = lib.entry("cameo-auro-beam-150")
	var p: FixtureProfile = lib.resolve("cameo-auro-beam-150")
	ok(p != null and p.manufacturer == "Cameo" and p.model == "Auro Beam 150", "a bundled fixture has its manufacturer and model")
	ok(e.get("maker") == p.manufacturer and e.get("model") == p.model, "...matching its catalogue entry")
	var legacy := FixtureProfile.from_dict({"id": "x", "profile_name": "Cameo Auro Beam 150", "modes": []})
	lib._names_from(legacy, e)
	ok(legacy.manufacturer == "Cameo" and legacy.model == "Auro Beam 150", "an older cached download takes them from its entry")


func _test_gdtf() -> void:
	print("- GDTF")
	var xml: PackedByteArray = MvrIO._gen_gdtf_xml(_par())
	var res := FixtureImport.from_gdtf_xml(xml)
	ok(not res.has("error"), "the MVR export's GDTF reads back (%s)" % res.get("error", ""))
	var p: FixtureProfile = res.get("profile")
	ok(p != null and p.manufacturer == "Acme" and p.model == "Par 7", "...with its manufacturer and model")
	var anon := FixtureProfile.new("anon", "Thing", [{"name": "Dimmer", "role": "DIMMER"}])
	var p2: FixtureProfile = FixtureImport.from_gdtf_xml(MvrIO._gen_gdtf_xml(anon)).get("profile")
	ok(p2 != null and p2.model == "Thing", "a profile without a manufacturer exports with its model")
