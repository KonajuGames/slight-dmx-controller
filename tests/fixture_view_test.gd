extends SceneTree
## Tests for FixtureView's schematic bodies — which fixtures hang in a
## yoke that follows pan / tilt.
##
##   godot --headless --script tests/fixture_view_test.gd

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


## A profile with `roles` and physical category `category` ("" = auto).
func _profile(id: String, roles: Array, category: String) -> FixtureProfile:
	var chans: Array = []
	for r in roles:
		chans.append({"name": r, "role": r})
	var p := FixtureProfile.new(id, id, chans)
	p.physical["category"] = category
	return p


## A FixtureView (loaded at run time: it needs the ArtNet autoload) for
## `profile`, patched at channel 1 of universe 1.
func _view(profile: FixtureProfile) -> Node3D:
	var fv: Node3D = load("res://scripts/fixture_view.gd").new()
	root.add_child(fv)
	fv.setup(0, 0, 0, profile, 1, profile.id)
	return fv


func _run() -> void:
	print("== Fixture view ==")
	var moving := ["PAN", "TILT", "DIMMER", "RED", "GREEN", "BLUE"]
	var cases := [
		["auto", _profile("auto", moving, ""), true],
		["moving head", _profile("mh", moving, "moving_head"), true],
		["beam", _profile("beam", moving, "beam"), true],
		["wash", _profile("mwash", moving, "wash"), true],
		["beam without pan / tilt", _profile("fbeam", ["DIMMER"], "beam"), false],
		["par", _profile("par", ["DIMMER", "RED", "GREEN", "BLUE"], "par"), false],
	]
	for c in cases:
		var fv := _view(c[1])
		var yoked: bool = fv._yoke != null and fv._head != null
		ok(yoked == c[2], "%s: %s" % [c[0], "in a yoke" if c[2] else "fixed"])
		fv.queue_free()

	# A beam follows its pan / tilt.
	var fv := _view(_profile("beam", moving, "beam"))
	var uni = root.get_node("ArtNet").get_universe(0)    # (named at run time, as above)
	uni.output.resize(512)
	uni.output.fill(0)
	uni.output[0] = 128
	uni.output[1] = 128
	for _i in range(10):
		fv._process(1.0)
	var pan0: float = fv._cur_pan
	var tilt0: float = fv._cur_tilt
	uni.output[0] = 255
	uni.output[1] = 255
	for _i in range(10):
		fv._process(1.0)
	ok(fv._cur_pan > pan0 + 1.0 and fv._cur_tilt > tilt0 + 0.5,
		"a beam turns with its pan / tilt (pan %.2f -> %.2f rad, tilt %.2f -> %.2f)" % [pan0, fv._cur_pan, tilt0, fv._cur_tilt])
	var wide: SpotLight3D = _view(_profile("mwash", moving, "wash"))._heads[0]["light"]
	ok(wide.spot_angle >= 15.0 and (fv._heads[0]["light"] as SpotLight3D).spot_angle < 15.0,
		"...a moving wash still wide (%.0f°), a beam narrow (%.0f°)" % [wide.spot_angle, (fv._heads[0]["light"] as SpotLight3D).spot_angle])

	# The profile's pan / tilt range and beam angle set the travel and spread.
	var lim := _profile("lim", moving, "moving_head")
	lim.physical["pan_range"] = 180.0
	lim.physical["tilt_range"] = 90.0
	lim.physical["beam_deg"] = 40.0
	var lv := _view(lim)
	for _i in range(20):
		lv._process(1.0)
	ok(is_equal_approx(snappedf(rad_to_deg(lv._cur_pan), 0.1), 90.0)
		and is_equal_approx(snappedf(rad_to_deg(lv._cur_tilt), 0.1), 45.0),
		"full pan / tilt reach half the profile's range (%.1f°, %.1f°)" % [rad_to_deg(lv._cur_pan), rad_to_deg(lv._cur_tilt)])
	ok(is_equal_approx((lv._heads[0]["light"] as SpotLight3D).spot_angle, 20.0),
		"the beam spreads to the profile's angle (half %.1f°)" % (lv._heads[0]["light"] as SpotLight3D).spot_angle)

	print("== %d passed, %d failed ==" % [_p, _f])
	quit(1 if _f > 0 else 0)
