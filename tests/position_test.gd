extends SceneTree
## Tests for named positions: PositionLibrary, the PositionEditor and the
## Positions list in DJ Edit Mode, and saving them with the show.
##
##   godot --headless --script tests/position_test.gd

var _p := 0
var _f := 0
var _s := 0


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
	print("== Named positions ==")
	_test_library()
	_test_icon()
	await _test_editor()
	await _test_browser()
	await _test_show()
	print("== %d passed, %d failed, %d skipped ==" % [_p, _f, _s])
	quit(1 if _f > 0 else 0)


func _mover() -> FixtureProfile:
	return FixtureProfile.new("mv", "Mover", [{"name": "Pan", "role": "PAN"}, {"name": "Tilt", "role": "TILT"},
		{"name": "Dimmer", "role": "DIMMER"}])


func _par() -> FixtureProfile:
	return FixtureProfile.new("par", "Par", [{"name": "Red", "role": "RED"}, {"name": "Green", "role": "GREEN"},
		{"name": "Blue", "role": "BLUE"}])


func _test_library() -> void:
	print("- the library")
	var lib := PositionLibrary.new()
	var changes := [0]
	lib.changed.connect(func(): changes[0] += 1)
	var a := lib.add()
	var b := lib.add()
	var c := lib.add()
	ok(a["name"] == "Position 1" and b["name"] == "Position 2" and lib.positions.size() == 3, "new positions are numbered")
	ok(a["colour"] != b["colour"] and b["colour"] != c["colour"] and a["colour"] != c["colour"], "each gets its own colour")
	ok(absf(a["colour"].h - b["colour"].h) > 0.1 and absf(b["colour"].h - c["colour"].h) > 0.1, "...well apart on the hue wheel")
	ok(a["id"] != b["id"], "and its own id")
	lib.rename(a["id"], "  Drop  ")
	ok(lib.find(a["id"])["name"] == "Drop", "renamed (trimmed)")
	lib.rename(a["id"], "   ")
	ok(lib.find(a["id"])["name"] == "Drop", "a blank name is ignored")
	ok(lib.point(a["id"], "fx1") == PositionLibrary.DEFAULT_POINT, "a fixture without a point: centred")
	lib.set_point(a["id"], "fx1", Vector2(0.25, 1.4))
	ok(lib.point(a["id"], "fx1") == Vector2(0.25, 1.0), "a point set (kept inside 0..1)")
	ok(changes[0] >= 5, "changes are signalled")
	var lib2 := PositionLibrary.new()
	lib2.from_dict(JSON.parse_string(JSON.stringify(lib.to_dict())))
	ok(lib2.positions.size() == 3 and lib2.find(a["id"])["name"] == "Drop"
		and lib2.point(a["id"], "fx1").is_equal_approx(Vector2(0.25, 1.0))
		and (lib2.find(b["id"])["colour"] as Color).is_equal_approx(Color.from_string(b["colour"].to_html(false), Color.BLACK)),
		"saved and loaded: names, colours, points")
	var d := lib2.add()
	ok(d["name"] == "Position 4" and d["colour"] != c["colour"], "a loaded library carries on numbering")
	lib2.clear()
	ok(lib2.positions.is_empty(), "cleared")


func _test_icon() -> void:
	print("- the position icon")
	var img := PositionEditor.triangle_icon(Color(1, 0, 0)).get_image()
	var s := img.get_width()
	ok(img.get_pixel(int(s * 0.75), s / 2).a > 0.5, "solid near its right point")
	ok(img.get_pixel(int(s * 0.75), 1).a < 0.1 and img.get_pixel(int(s * 0.75), s - 2).a < 0.1, "but narrow there")
	ok(img.get_pixel(int(s * 0.2), 3).a > 0.5 and img.get_pixel(int(s * 0.2), s - 4).a > 0.5, "wide on the left: it points right")
	ok(img.get_pixel(int(s * 0.5), s / 2).is_equal_approx(Color(1, 0, 0, 1)), "in the position's colour")
	ok(PositionEditor.triangle_icon(Color(1, 0, 0)) == PositionEditor.triangle_icon(Color(1, 0, 0)), "made once per colour")


func _fixtures() -> Array:
	return [{"uid": "m1", "name": "Mover L", "profile": _mover(), "mode": 0},
		{"uid": "pp", "name": "Par", "profile": _par(), "mode": 0},
		{"uid": "m2", "name": "Mover R", "profile": _mover(), "mode": 0}]


func _press(pad: Control, local: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = pad.get_global_transform() * local
	ev.global_position = ev.position
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	root.push_input(ev)


func _move(pad: Control, local: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pad.get_global_transform() * local
	ev.global_position = ev.position
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(ev)


func _test_editor() -> void:
	print("- the position editor")
	var lib := PositionLibrary.new()
	var pos := lib.add()
	var id: String = pos["id"]
	lib.set_point(id, "m2", Vector2(0.8, 0.2))
	var ed := PositionEditor.new()
	ed.library = lib
	var fx := _fixtures()
	ed.fixtures_provider = func(): return fx
	root.add_child(ed)
	ed.position = Vector2.ZERO
	ed.size = Vector2(900, 600)
	await process_frame
	ed.open(id)
	await process_frame
	await process_frame
	var pad := ed.pad()
	var list: ItemList = ed._list
	ok(list.item_count == 2 and list.get_item_text(0) == "Mover L" and list.get_item_text(1) == "Mover R",
		"lists only the fixtures with pan and tilt")
	ok(ed.name_edit().text == "Position 1" and ed._icon.texture == PositionEditor.triangle_icon(pos["colour"]),
		"the position's name at the top of the side panel, after its triangle")
	ok(is_equal_approx(pad.size.x, pad.size.y) and pad.size.x > 400, "a large square pad (%.0f x %.0f)" % [pad.size.x, pad.size.y])
	ok(pad.get_global_rect().end.x <= list.get_global_rect().position.x, "the side panel on its right")
	# Nothing selected: nothing to drag.
	var centre := pad.to_px(Vector2(0.5, 0.5))
	_press(pad, centre, true)
	_move(pad, centre + Vector2(50, 0))
	_press(pad, centre + Vector2(50, 0), false)
	ok(lib.point(id, "m1") == Vector2(0.5, 0.5), "an unselected (dimmed) point doesn't move")
	ok(ed.selected_uids() == ["m1"], "clicking a dimmed point selects its fixture")
	# Selected: drag it.
	_press(pad, centre, true)
	_move(pad, centre + Vector2(pad.size.x * 0.1, -pad.size.y * 0.2))
	_press(pad, centre + Vector2(pad.size.x * 0.1, -pad.size.y * 0.2), false)
	ok(lib.point(id, "m1").is_equal_approx(Vector2(0.6, 0.7)) and lib.point(id, "m2") == Vector2(0.8, 0.2),
		"dragging the highlighted point moves it (pan right, tilt up) and only it (%s)" % str(lib.point(id, "m1")))
	# Both selected: they move together.
	ed.select_uids(["m1", "m2"])
	var from := pad.to_px(lib.point(id, "m2"))
	_press(pad, from, true)
	_move(pad, from + Vector2(-pad.size.x * 0.1, 0))
	_press(pad, from + Vector2(-pad.size.x * 0.1, 0), false)
	ok(lib.point(id, "m1").is_equal_approx(Vector2(0.5, 0.7)) and lib.point(id, "m2").is_equal_approx(Vector2(0.7, 0.2)),
		"with several selected, dragging one moves them all")
	# Renaming.
	ed.name_edit().text = "Crowd"
	ed.name_edit().text_submitted.emit("Crowd")
	ok(lib.find(id)["name"] == "Crowd", "the name can be edited")
	ed.queue_free()
	await process_frame


func _test_browser() -> void:
	print("- the Positions list in DJ Edit Mode")
	var lib := PositionLibrary.new()
	var panel := MusicBrowserPanel.new()
	panel.positions = lib
	root.add_child(panel)
	panel.position = Vector2.ZERO
	panel.size = Vector2(1200, 700)
	var fx := _fixtures()
	panel.position_editor().fixtures_provider = func(): return fx
	await process_frame
	var list := panel.positions_list()
	var tree: Tree = panel._tree
	ok(list.get_global_rect().position.y > tree.get_global_rect().position.y and is_equal_approx(list.get_global_rect().position.x, tree.get_global_rect().position.x),
		"a list below the folders")
	var heads := panel.find_children("*", "Label", true, false).filter(func(l): return l.text == "Positions")
	ok(heads.size() == 1 and heads[0].get_global_rect().position.y < list.get_global_rect().position.y, "under a \"Positions\" header")
	ok(list.item_count == 1 and list.get_item_text(0) == "+", "no positions: just \"+\"")
	list.select(0)
	list.item_selected.emit(0)
	ok(lib.positions.size() == 1 and list.item_count == 2 and list.get_item_text(0) == "Position 1" and list.get_item_text(1) == "+",
		"\"+\" adds a position (and stays last)")
	ok(list.get_item_icon(0) == PositionEditor.triangle_icon(lib.positions[0]["colour"]), "listed with its colour's triangle")
	ok(panel.is_position_shown() and panel.position_editor().position_id == lib.positions[0]["id"]
		and not panel._list_view.visible and list.is_selected(0), "and opens it in the editor")
	lib.rename(lib.positions[0]["id"], "Crowd")
	ok(list.get_item_text(0) == "Crowd" and list.is_selected(0), "renaming updates the list")
	list.select(1)
	list.item_selected.emit(1)
	panel.show_track_list()
	ok(not panel.is_position_shown() and panel._list_view.visible and list.get_selected_items().is_empty(),
		"picking a folder goes back to the track list")
	panel.open_position(lib.positions[0]["id"])
	lib.from_dict({})
	ok(not panel.is_position_shown() and list.item_count == 1, "its position gone (another show): back to the list")
	panel.queue_free()
	await process_frame


func _test_show() -> void:
	print("- saved with the show")
	var path := "user://_positions_test.slight"
	var main: Control = load("res://main.tscn").instantiate()
	main.last_show_store = "user://_positions_test_last.json"
	root.add_child(main)
	await process_frame
	main._panels[0].add_patched(_mover(), 0, 0, "Spot", Vector3.ZERO, Vector3.ZERO)
	var uid := String(main._panels[0].patched_fixtures[0]["uid"])
	var p: Dictionary = main.positions.add()
	main.positions.rename(p["id"], "Stage")
	main.positions.set_point(p["id"], uid, Vector2(0.3, 0.6))
	ok(main.music_panel.position_editor().moving_fixtures().size() == 1, "the editor lists the show's pan / tilt fixtures")
	main.save_show_to(path)
	main.positions.clear()
	main.load_show_from(path)
	ok(main.positions.positions.size() == 1 and main.positions.positions[0]["name"] == "Stage"
		and main.positions.point(p["id"], uid).is_equal_approx(Vector2(0.3, 0.6)), "positions load back with the show")
	main.new_show()
	ok(main.positions.positions.is_empty(), "a new show has none")
	main.queue_free()
	await process_frame
	for f in [path, "user://_positions_test_last.json"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	if DirAccess.dir_exists_absolute("user://_positions_test.timelines"):
		DirAccess.remove_absolute("user://_positions_test.timelines")
