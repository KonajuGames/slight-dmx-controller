extends SceneTree
## Tests for palettes (PaletteLibrary, the Palettes tab) and the cues that
## use them.
##
##   godot --headless --script tests/palettes_test.gd

var _p := 0
var _f := 0

const DIR := "user://_palettes_test"

# These reach the ArtNet autoload, which a --script run can't resolve at
# compile time — so they're loaded at run time.
var Lib: GDScript

var main: Control
var art: Node
var u0


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
	print("== Palettes ==")
	Lib = load("res://scripts/palette_library.gd")
	DirAccess.make_dir_recursive_absolute(DIR)
	main = load("res://main.tscn").instantiate()
	main.last_show_store = DIR + "/last.json"
	main.ui_state_store = DIR + "/ui.json"
	root.add_child(main)
	await process_frame
	art = root.get_node("ArtNet")
	u0 = art.get_universe(0)
	_setup()
	_test_record()
	_test_cue_links()
	_test_update_and_apply()
	_test_groups_and_kinds()
	_test_tracking_switch()
	_test_delete()
	_test_show_file()
	main.queue_free()
	await process_frame
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR.path_join(f))
	DirAccess.remove_absolute(DIR)
	print("== %d passed, %d failed ==" % [_p, _f])
	quit(1 if _f > 0 else 0)


## Spot at 1: dimmer, pan, tilt, red, green, blue, gobo (channels 0-6).
## Par at 21: red, green, blue (20-22).
func _setup() -> void:
	var spot := FixtureProfile.new("pspot", "Pal Spot", [
		{"name": "Dimmer", "role": "DIMMER"}, {"name": "Pan", "role": "PAN"},
		{"name": "Tilt", "role": "TILT"}, {"name": "Red", "role": "RED"},
		{"name": "Green", "role": "GREEN"}, {"name": "Blue", "role": "BLUE"},
		{"name": "Gobo", "role": "GOBO"},
	])
	var par := FixtureProfile.new("ppar", "Pal Par", [
		{"name": "Red", "role": "RED"}, {"name": "Green", "role": "GREEN"},
		{"name": "Blue", "role": "BLUE"},
	])
	main._panels[0].add_patched(spot, 0, 0, "Spot", Vector3.ZERO, Vector3.ZERO)
	main._panels[0].add_patched(par, 20, 0, "Par", Vector3.ZERO, Vector3.ZERO)
	main.groups.append({"name": "Pars", "members": [String(main._panels[0].patched_fixtures[1]["uid"])]})
	main.groups_panel.groups_changed.emit()


func _rgb(spot: Array, par: Array) -> void:
	for i in 3:
		u0.set_channel(3 + i, spot[i])
		u0.set_channel(20 + i, par[i])


func _test_record() -> void:
	print("- recording")
	u0.set_all(0)
	_rgb([255, 0, 0], [255, 0, 0])
	var p = main.palettes_panel.record(Lib.COLOUR)
	ok(p != null and p.name == "Colour 1" and p.values.size() == 2, "a colour palette for both fixtures")
	var spot_uid := String(main._panels[0].patched_fixtures[0]["uid"])
	ok(p.values[spot_uid].keys() == ["3", "4", "5"], "...just their colour channels, by offset (%s)" % str(p.values[spot_uid].keys()))
	main.palettes.rename(p, "Red")
	ok(main.palettes_panel.record(Lib.BEAM) != null, "a beam palette (the spot's gobo)")
	ok(main.palettes.of_kind(Lib.BEAM)[0].values.size() == 1, "...only the fixture with beam channels")
	var sw = main.palettes.swatch(p, main._perform_fixtures())
	ok(sw is Color and sw.is_equal_approx(Color.RED), "its swatch is red")
	ok(main.palettes_panel._grids[Lib.COLOUR].get_child_count() >= 1, "a button in the Colour grid")


func _test_cue_links() -> void:
	print("- cues link to palettes")
	var cp = main.cue_panel
	var red = main.palettes.of_kind(Lib.COLOUR)[0]
	u0.set_channel(0, 255)
	cp.record_cue()                     # tracking: dimmer up, both red
	var c = cp.cues[0]
	var spot_uid := String(main._panels[0].patched_fixtures[0]["uid"])
	var par_uid := String(main._panels[0].patched_fixtures[1]["uid"])
	ok(c.refs.get(spot_uid, {}).get("colour") == red.id and c.refs.get(par_uid, {}).get("colour") == red.id,
		"both fixtures' colour is the palette")
	ok(not c.levels[0].has("3") and not c.levels[0].has("20") and c.levels[0].get("0") == 255,
		"...not stored in the cue; the dimmer is")
	ok("◆ Red" in cp.cue_list.get_item_text(0), "the cue list says so: %s" % cp.cue_list.get_item_text(0))
	var look: Array = cp.standing_look(1)
	ok(look[0].get("3") == 255 and look[0].get("20") == 255 and look[0].get("4") == 0, "it plays back red")
	# Only what a tracking cue changes links: the par goes 254 — no palette.
	_rgb([255, 0, 0], [254, 0, 0])
	cp.record_cue()
	var c2 = cp.cues[1]
	ok(not c2.refs.has(par_uid) and c2.levels[0].get("20") == 254, "a colour that's not quite the palette's: raw values")
	ok(not c2.refs.has(spot_uid), "...and the unchanged spot isn't touched")
	_rgb([255, 0, 0], [255, 0, 0])
	main.cue_panel.tracking_enabled = false
	cp.record_cue()                     # a block, all red
	var c3 = cp.cues[2]
	ok(c3.refs.get(par_uid, {}).get("colour") == red.id and not c3.levels[0].has("20"), "a block cue links too")
	main.cue_panel.tracking_enabled = true


func _test_update_and_apply() -> void:
	print("- updating and applying")
	var cp = main.cue_panel
	var red = main.palettes.of_kind(Lib.COLOUR)[0]
	_rgb([0, 0, 200], [0, 0, 200])
	main.palettes_panel.update_from_live(red)
	ok("2 cues use it" in main.palettes_panel._status.text, "update: says how many cues use it (%s)" % main.palettes_panel._status.text)
	var look: Array = cp.standing_look(1)
	ok(look[0].get("3") == 0 and look[0].get("5") == 200 and look[0].get("22") == 200, "every cue using it follows: now blue")
	ok(cp.standing_look(2)[0].get("20") == 254, "...not the one with raw values")
	_rgb([0, 0, 0], [0, 0, 0])
	cp.go_to_number(3)
	art._process(5.0)
	ok(u0.get_channel(5) == 200 and u0.get_channel(22) == 200, "GO plays the palette as it is now")
	_rgb([0, 255, 0], [0, 255, 0])
	main.palettes_panel.apply(red)
	ok(u0.get_channel(4) == 0 and u0.get_channel(5) == 200 and u0.get_channel(22) == 200, "Apply sets the fixtures to it")
	ok(u0.get_channel(0) == 255, "...leaving their other channels")


func _test_groups_and_kinds() -> void:
	print("- groups and kinds")
	var panel = main.palettes_panel
	panel.refresh_fixture_options()
	ok(panel._fixtures_option.item_count == 2 and panel._fixtures_option.get_item_text(1) == "Pars", "Fixtures: all, then the groups")
	panel._fixtures_option.selected = 1
	_rgb([10, 10, 10], [0, 255, 255])
	var cyan = panel.record(Lib.COLOUR)
	ok(cyan.values.size() == 1, "recorded for the group only")
	_rgb([1, 2, 3], [9, 9, 9])
	panel.apply(cyan)
	ok(u0.get_channel(21) == 255 and u0.get_channel(3) == 1, "applied to the group only")
	ok(panel.record(Lib.POSITION) == null and "None of those" in panel._status.text, "pars have no position: nothing recorded")
	panel._fixtures_option.selected = 0
	u0.set_channel(1, 100)
	u0.set_channel(2, 50)
	var pos = panel.record(Lib.POSITION)
	ok(pos != null and pos.values.size() == 1, "a position palette: the spot")
	main.cue_panel.record_cue()
	var c = main.cue_panel.cues[3]
	var spot_uid := String(main._panels[0].patched_fixtures[0]["uid"])
	ok(c.refs.get(spot_uid, {}).get("position") == pos.id, "a cue links its position too")


func _test_tracking_switch() -> void:
	print("- tracking / block")
	var cp = main.cue_panel
	var before: Array = cp.standing_look(1)
	cp.cue_list.select(0)
	cp._on_cue_selected(0)
	cp._set_selected_tracking(false)
	var c = cp.cues[0]
	ok(not c.tracking and not c.refs.is_empty() and not c.levels[0].has("3") and not c.levels[0].has("20"),
		"made a block: still uses the palette, no values for it")
	ok(cp.standing_look(1) == before, "...and looks the same")
	cp._set_selected_tracking(true)
	ok(cp.standing_look(1) == before and not c.levels[0].has("20"), "and back")


func _test_delete() -> void:
	print("- deleting")
	var cp = main.cue_panel
	var red = main.palettes.of_kind(Lib.COLOUR)[0]
	var looks: Array = []
	for i in range(cp.cues.size()):
		looks.append(cp._targets_from_state(cp.standing_look(i + 1)))   # as DMX: a block's 0s may be implicit
	ok(cp.palette_users(red.id) == 2, "two cues use it")
	main.palettes_panel.delete(red)
	ok(main.palettes.find(red.id) == null, "gone")
	ok(cp.palette_users(red.id) == 0 and cp.cues[0].levels[0].get("22") == 200, "its values are in the cues now")
	var same := true
	for i in range(cp.cues.size()):
		same = same and cp._targets_from_state(cp.standing_look(i + 1)) == looks[i]
	ok(same, "every cue looks the same as before")
	ok("◆ Red" not in cp.cue_list.get_item_text(0), "the cue list no longer says so")


func _test_show_file() -> void:
	print("- the show file")
	var d: Dictionary = main.show_dict()
	var n: int = main.palettes.palettes.size()
	var look: Array = main.cue_panel.standing_look(4)
	main.apply_show_dict({"universes": [{}], "live": [{}]})
	ok(main.palettes.palettes.is_empty(), "a show without palettes: none")
	main.apply_show_dict(d)
	ok(main.palettes.palettes.size() == n and main.cue_panel.standing_look(4) == look,
		"loaded back: the palettes, and the cues still use them")
	var p = main.palettes_panel.record(Lib.BEAM)
	ok(p != null and main.palettes.find(p.id) == p and main.palettes.palettes.filter(func(x): return x.id == p.id).size() == 1,
		"a new palette never reuses an id (%s)" % p.id)
	# A fixture taken out of the patch: its references are skipped.
	var refs_before: int = main.cue_panel.cues[3].refs.size()
	main._panels[0].patched_fixtures.remove_at(0)
	var l2: Array = main.cue_panel.standing_look(4)
	ok(refs_before > 0 and not l2[0].has("1"), "an unpatched fixture's palette isn't played")
