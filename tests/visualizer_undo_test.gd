extends SceneTree
## Tests for undoing moves in the 3D Visualizer — dragging a fixture,
## typing its position / rotation, Auto-arrange, trusses.
##
##   godot --headless --script tests/visualizer_undo_test.gd

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


## A stand-in for a UniversePanel: just its patch.
class FakePanel:
	var patched_fixtures: Array = []


func _run() -> void:
	print("== Visualizer undo ==")
	var profile := FixtureProfile.new("par", "Par", [{"name": "Dimmer", "role": "DIMMER"}])
	var panel := FakePanel.new()
	panel.patched_fixtures = [
		{"id": 1, "uid": "fa", "name": "A", "profile": profile, "start": 0, "mode": 0,
			"pos": Vector3(1, 4, -2), "rot": Vector3(90, 0, 0)},
		{"id": 2, "uid": "fb", "name": "B", "profile": profile, "start": 1, "mode": 0,
			"pos": Vector3(-1, 4, -2), "rot": Vector3(90, 0, 0)},
	]
	# Loaded at run time: it needs the ArtNet autoload, which a test script
	# can't name when it compiles.
	var viz = load("res://scripts/visualizer_panel.gd").new()
	viz.panels = [panel]
	root.add_child(viz)
	viz.size = Vector2(900, 600)
	await process_frame
	viz.rebuild()
	await process_frame
	var a: Dictionary = panel.patched_fixtures[0]
	var view_of := func(id: int) -> Node3D:
		for c in viz._fixture_root.get_children():
			if c.has_method("apply_transform") and c.fixture_id == id and not c.is_queued_for_deletion():
				return c
		return null
	ok(not viz.can_undo() and viz._undo_btn.disabled and viz._redo_btn.disabled, "nothing to undo at first")

	# Typing a position.
	viz._select(view_of.call(1))
	viz._px.value = 3.0
	ok(a["pos"].is_equal_approx(Vector3(3, 4, -2)) and viz.can_undo() and not viz._undo_btn.disabled,
		"typing X moves the fixture, an undoable step")
	viz._ptilt.value = 45.0
	ok(a["rot"].is_equal_approx(Vector3(45, 0, 0)), "typing its tilt turns it")
	viz.undo()
	ok(a["rot"].is_equal_approx(Vector3(90, 0, 0)) and a["pos"].is_equal_approx(Vector3(3, 4, -2))
		and is_equal_approx(viz._ptilt.value, 90.0), "undo: the tilt back (the field too), the move kept")
	viz.undo()
	var fv: Node3D = view_of.call(1)
	ok(a["pos"].is_equal_approx(Vector3(1, 4, -2)) and fv.position.is_equal_approx(Vector3(1, 4, -2))
		and is_equal_approx(viz._px.value, 1.0), "undo again: back where it was, in the patch, the view and the field")
	ok(not viz.can_undo() and viz.can_redo() and not viz._redo_btn.disabled, "...nothing more to undo, redo available")
	viz.redo()
	ok(a["pos"].is_equal_approx(Vector3(3, 4, -2)), "redo: moved again")
	viz.redo()
	ok(a["rot"].is_equal_approx(Vector3(45, 0, 0)) and not viz.can_redo(), "...and turned again")

	# Dragging: the whole drag one step.
	viz.undo()
	viz.undo()
	fv = view_of.call(1)
	viz._start_move(fv)
	var c: Vector2 = viz.get_global_rect().get_center()
	for k in range(5):
		var mm := InputEventMouseMotion.new()
		mm.position = c + Vector2(40 * (k + 1), 10 * k)
		mm.relative = Vector2(40, 10)
		viz._drag_motion(mm)
	viz._end_drag()
	var dragged: Vector3 = a["pos"]
	ok(not dragged.is_equal_approx(Vector3(1, 4, -2)) and is_equal_approx(dragged.y, 4.0),
		"dragging moves it on its own height (%s)" % dragged)
	ok(not viz.can_redo(), "a new move clears redo")
	viz.undo()
	ok(a["pos"].is_equal_approx(Vector3(1, 4, -2)), "one undo takes back the whole drag")
	viz.redo()
	ok(a["pos"].is_equal_approx(dragged), "...redo puts it back where it was dropped")
	var steps: int = viz._undo.size()
	viz._start_move(view_of.call(1))
	viz._end_drag()
	ok(viz._undo.size() == steps, "a click that doesn't move it: no step")

	# Auto-arrange: every fixture, one step — through the rebuild.
	var b: Dictionary = panel.patched_fixtures[1]
	var before_b: Vector3 = b["pos"]
	viz._auto_arrange()
	await process_frame
	ok(not a["pos"].is_equal_approx(dragged) or not b["pos"].is_equal_approx(before_b), "auto-arrange moves them")
	viz.undo()
	ok(a["pos"].is_equal_approx(dragged) and b["pos"].is_equal_approx(before_b)
		and view_of.call(1).position.is_equal_approx(dragged), "one undo puts them all back (on the rebuilt views)")

	# Trusses.
	viz._add_truss()
	var truss: Node3D = viz._selected
	var tpos: Vector3 = truss.position
	viz._plen.value = 6.0
	var tlen: float = viz._plen.value         # (the box snaps to its steps)
	viz._pz.value = tpos.z - 2.0
	viz.undo()
	ok(is_equal_approx(truss.position.z, tpos.z) and is_equal_approx(float(truss.get_meta("len")), tlen),
		"a truss's move undone, its length kept")
	viz.undo()
	ok(is_equal_approx(float(truss.get_meta("len")), 4.0), "...then its length")
	viz._delete_selected()
	await process_frame
	ok(viz.redo() and not is_instance_valid(truss), "redo on a deleted truss: skipped, no error")

	# A fixture unpatched since: skipped.
	viz._select(view_of.call(2))
	viz._px.value = 7.0
	panel.patched_fixtures.remove_at(1)
	viz.rebuild()
	await process_frame
	ok(viz.undo() and a["pos"].is_equal_approx(dragged), "undoing a move of an unpatched fixture: skipped, no error")

	# Ctrl+Z / Ctrl+Y: over the visualizer.
	viz._select(view_of.call(1))
	viz._px.value = 5.0
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_Z
	key.ctrl_pressed = true
	Input.warp_mouse(c)
	var attn: bool = viz._has_attention()
	if attn:
		viz._shortcut_input(key)
		ok(is_equal_approx(a["pos"].x, dragged.x), "Ctrl+Z over the visualizer undoes")
		key.keycode = KEY_Y
		viz._shortcut_input(key)
		ok(is_equal_approx(a["pos"].x, 5.0), "Ctrl+Y redoes")
	else:
		print("  skip Ctrl+Z / Ctrl+Y (no pointer headless)")

	# Typing then Enter lets go of the field, so Ctrl+Z is the move's.
	var le: LineEdit = viz._px.get_line_edit()
	le.grab_focus()
	le.text_submitted.emit("2")
	ok(not le.has_focus(), "Enter in a field lets go of the keyboard")

	# Another show: nothing to undo.
	viz.from_dict({})
	ok(not viz.can_undo() and not viz.can_redo(), "loading a show clears the history")

	viz.queue_free()
	print("== %d passed, %d failed ==" % [_p, _f])
	quit(1 if _f > 0 else 0)
