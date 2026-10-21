extends SceneTree
## Tests for TimelineTrack — a lighting timeline (master / fixture / head)
## in DJ Edit Mode's track timeline — and the master track's place
## above the song structure.
##
##   godot --headless --script tests/timeline_track_test.gd

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
	print("== Timeline tracks ==")
	_test_rows()
	_test_rows_for_roles()
	_test_dimmer()
	_test_editing()
	_test_line_drag()
	await _test_in_timeline()
	_test_fixture_specs()
	await _test_fixture_tracks()
	await _test_area_selection()
	_test_clear_dimmer()
	await _test_delete_selection()
	await _test_generate_into_selection()
	await _test_reanalyse_and_generate()
	_test_dimmer_segments()
	await _test_copy_paste()
	await _test_undo_redo()
	_test_dimmer_shapes()
	await _test_context_menu()
	await _test_drag_selection()
	_test_strobe_model()
	await _test_strobe_editing()
	await _test_position_row()
	await _test_movement_row()
	await _test_dimmer_inheritance()
	print("== %d passed, %d failed, %d skipped ==" % [_p, _f, _s])
	quit(1 if _f > 0 else 0)


func _test_rows() -> void:
	print("- master rows")
	var tr := TimelineTrack.new()
	root.add_child(tr)
	ok(tr.target == TimelineTrack.Target.MASTER and tr.rows.size() == 5, "the master has every row")
	ok(tr.custom_minimum_size.y == 80.0 + 4 * 10.0, "120 px: four 10 px rows + the 80 px dimmer (%.0f)" % tr.custom_minimum_size.y)
	tr.size = Vector2(800, tr.custom_minimum_size.y)
	var R := TimelineTrack.Row
	var want := {R.DIMMER: Rect2(0, 0, 800, 80), R.COLOUR: Rect2(0, 80, 800, 10), R.MOVEMENT: Rect2(0, 90, 800, 10),
		R.STROBE: Rect2(0, 100, 800, 10), R.POSITION: Rect2(0, 110, 800, 10)}
	var all_ok := true
	for r in want:
		all_ok = all_ok and tr.row_rect(r) == want[r]
	ok(all_ok, "bottom up: Position, Strobe, Cues, Colour, then the Dimmer on top")
	tr.queue_free()


func _test_rows_for_roles() -> void:
	print("- rows from a fixture's channels")
	var R := TimelineTrack.Row
	ok(TimelineTrack.rows_for_roles(["PAN", "PAN_FINE", "TILT", "DIMMER", "STROBE", "COLOR_WHEEL", "GOBO"])
		== [R.POSITION, R.STROBE, R.MOVEMENT, R.COLOUR, R.DIMMER], "moving head: every row")
	ok(TimelineTrack.rows_for_roles(["DIMMER", "RED", "GREEN", "BLUE"]) == [R.COLOUR, R.DIMMER],
		"RGB par: colour, dimmer (no movement: it can't move)")
	ok(TimelineTrack.rows_for_roles(["RED", "GREEN", "BLUE", "WHITE"]) == [R.COLOUR, R.DIMMER],
		"RGBW without a dimmer channel: still a dimmer row (the virtual dimmer)")
	ok(TimelineTrack.rows_for_roles(["COLOR_WHEEL", "GOBO"]) == [R.COLOUR], "colour wheel only: no dimmer row")
	ok(TimelineTrack.rows_for_roles(["DIMMER"]) == [R.DIMMER], "plain dimmer: just the dimmer")
	ok(TimelineTrack.rows_for_roles(["PAN"]) == [R.POSITION, R.MOVEMENT], "pan only: position and movement")
	var tr := TimelineTrack.new()
	tr.target = TimelineTrack.Target.FIXTURE
	root.add_child(tr)
	tr.rows = [R.DIMMER, R.MOVEMENT]      # any order in, stacking order kept
	ok(tr.rows == [R.MOVEMENT, R.DIMMER] and tr.custom_minimum_size.y == 90.0, "fewer rows -> shorter track (%.0f)" % tr.custom_minimum_size.y)
	ok(not tr.has_row(R.POSITION) and tr.row_rect(R.POSITION) == Rect2(), "absent rows have no rectangle")
	tr.queue_free()


func _test_dimmer() -> void:
	print("- dimmer node line")
	var tr := TimelineTrack.new()
	root.add_child(tr)
	tr.size = Vector2(1000, tr.custom_minimum_size.y)
	ok(tr.dimmer_at(5.0) == 1.0, "no nodes: a flat 100 %")
	var line := tr.dimmer_polyline()
	var r := tr.row_rect(TimelineTrack.Row.DIMMER)
	ok(line.size() == 2 and line[0].y == line[1].y and line[0].y == r.position.y + 4.0,
		"drawn across the top of the row (inset 4 px)")
	tr.dimmer_nodes = PackedVector2Array([Vector2(0.2, 0.0), Vector2(0.6, 1.0)])
	ok(tr.dimmer_at(0.0) == 0.0 and tr.dimmer_at(0.9) == 1.0, "holds the first / last level outside the nodes")
	ok(is_equal_approx(tr.dimmer_at(0.4), 0.5), "linear between nodes")
	line = tr.dimmer_polyline()        # no waveform: the view is 0..1 s
	ok(line.size() == 4 and is_equal_approx(line[1].x, 200.0) and is_equal_approx(line[2].x, 600.0),
		"line through the window's edges and each node in view")
	ok(is_equal_approx(line[1].y, r.end.y - 4.0) and is_equal_approx(line[2].y, r.position.y + 4.0),
		"0 % at the bottom, 100 % at the top")
	tr.queue_free()


func _click(tr: TimelineTrack, pos: Vector2, button: MouseButton, pressed: bool, ctrl := false) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = pos
	ev.button_index = button
	ev.pressed = pressed
	ev.ctrl_pressed = ctrl
	tr._gui_input(ev)


func _motion(tr: TimelineTrack, pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	tr._gui_input(ev)


func _test_editing() -> void:
	print("- editing dimmer nodes with the mouse")
	var tr := TimelineTrack.new()
	root.add_child(tr)
	tr.size = Vector2(1000, tr.custom_minimum_size.y)   # no waveform: 0..1 s across 1000 px
	var edits := [0]
	tr.dimmer_edited.connect(func(): edits[0] += 1)
	var r := tr.row_rect(TimelineTrack.Row.DIMMER)
	var top := r.position.y + 4.0                       # the flat 100 % line
	# Ctrl + left-click on the line adds a node there.
	_click(tr, Vector2(300, top + 2.0), MOUSE_BUTTON_LEFT, true, true)
	_click(tr, Vector2(300, top + 2.0), MOUSE_BUTTON_LEFT, false, true)
	ok(tr.dimmer_nodes.size() == 1 and is_equal_approx(tr.dimmer_nodes[0].x, 0.3)
		and tr.dimmer_nodes[0].y == 1.0, "ctrl+click on the line adds a node on it")
	ok(edits[0] == 1, "reported once (a release without a move isn't an edit)")
	_click(tr, Vector2(600, r.end.y - 10.0), MOUSE_BUTTON_LEFT, true, true)
	ok(tr.dimmer_nodes.size() == 1, "ctrl+click off the line adds nothing")
	_click(tr, Vector2(600, top), MOUSE_BUTTON_LEFT, true, false)
	_click(tr, Vector2(600, top), MOUSE_BUTTON_LEFT, false, false)
	ok(tr.dimmer_nodes.size() == 1 and edits[0] == 1, "a plain click on the line adds nothing")
	_click(tr, Vector2(700, top), MOUSE_BUTTON_LEFT, true, true)
	_click(tr, Vector2(700, top), MOUSE_BUTTON_LEFT, false, true)
	ok(tr.dimmer_nodes.size() == 2 and is_equal_approx(tr.dimmer_nodes[1].x, 0.7), "a second node, in time order")
	# Drag the first node: down to half and right — but not past its neighbour.
	var mid := (r.position.y + r.end.y) * 0.5
	_click(tr, Vector2(300, top), MOUSE_BUTTON_LEFT, true)
	_motion(tr, Vector2(450, mid))
	ok(is_equal_approx(tr.dimmer_nodes[0].x, 0.45) and is_equal_approx(tr.dimmer_nodes[0].y, 0.5),
		"dragging moves the node in time and level")
	_motion(tr, Vector2(900, r.end.y + 50.0))
	ok(is_equal_approx(tr.dimmer_nodes[0].x, 0.7) and tr.dimmer_nodes[0].y == 0.0,
		"kept before its neighbour, and within 0 %")
	_motion(tr, Vector2(-100, r.position.y - 50.0))
	ok(tr.dimmer_nodes[0].x == 0.0 and tr.dimmer_nodes[0].y == 1.0, "not before 0 s, nor above 100 %")
	var n: int = edits[0]
	_click(tr, Vector2(0, top), MOUSE_BUTTON_LEFT, false)
	ok(edits[0] == n + 1, "the end of a drag is reported")
	_motion(tr, Vector2(500, mid))
	ok(tr.dimmer_nodes[0].x == 0.0, "no drag after release")
	# Ctrl + right-click on a node removes it.
	_click(tr, Vector2(500, top), MOUSE_BUTTON_RIGHT, true, true)
	ok(tr.dimmer_nodes.size() == 2, "ctrl+right-click away from a node removes nothing")
	_click(tr, Vector2(700, top), MOUSE_BUTTON_RIGHT, true, false)
	ok(tr.dimmer_nodes.size() == 2, "a plain right-click removes nothing")
	_click(tr, Vector2(702, top + 2.0), MOUSE_BUTTON_RIGHT, true, true)
	ok(tr.dimmer_nodes.size() == 1 and tr.dimmer_nodes[0].x == 0.0, "ctrl+right-click on a node removes it")
	tr.editable = false
	_click(tr, Vector2(0, top), MOUSE_BUTTON_RIGHT, true, true)
	ok(tr.dimmer_nodes.size() == 1, "not editable: ignored")
	tr.queue_free()


func _test_line_drag() -> void:
	print("- dragging the dimmer line, and Shift-locked node drags")
	var tr := TimelineTrack.new()
	root.add_child(tr)
	tr.size = Vector2(1000, tr.custom_minimum_size.y)   # 0..1 s across 1000 px
	var edits := [0]
	tr.dimmer_edited.connect(func(): edits[0] += 1)
	var r := tr.row_rect(TimelineTrack.Row.DIMMER)
	var span := r.size.y - 8.0                          # 0 % .. 100 % in px
	var top := r.position.y + 4.0
	# No nodes: dragging the flat line makes one node at 0 s carrying the level.
	_click(tr, Vector2(500, top), MOUSE_BUTTON_LEFT, true)
	_motion(tr, Vector2(520, top))
	ok(tr.dimmer_nodes.is_empty(), "a sideways move on the flat line changes nothing")
	_motion(tr, Vector2(520, top + span * 0.25))
	ok(tr.dimmer_nodes.size() == 1 and tr.dimmer_nodes[0].x == 0.0
		and is_equal_approx(tr.dimmer_nodes[0].y, 0.75), "the flat line moves down (one node at 0 s)")
	_click(tr, Vector2(520, top + span * 0.25), MOUSE_BUTTON_LEFT, false)
	ok(edits[0] == 1, "reported on release")
	# Between two nodes: both move by the same amount.
	tr.dimmer_nodes = PackedVector2Array([Vector2(0.2, 0.25), Vector2(0.6, 0.75), Vector2(0.8, 0.5)])
	var y := r.end.y - 4.0 - tr.dimmer_at(0.4) * span
	_click(tr, Vector2(400, y), MOUSE_BUTTON_LEFT, true)
	_motion(tr, Vector2(430, y - span * 0.1))
	ok(is_equal_approx(tr.dimmer_nodes[0].y, 0.35) and is_equal_approx(tr.dimmer_nodes[1].y, 0.85)
		and tr.dimmer_nodes[2].y == 0.5, "the nodes either side move up together, the rest stay")
	ok(is_equal_approx(tr.dimmer_nodes[0].x, 0.2) and is_equal_approx(tr.dimmer_nodes[1].x, 0.6),
		"only up and down, not in time")
	_motion(tr, Vector2(430, y - span))
	ok(is_equal_approx(tr.dimmer_nodes[0].y, 0.5) and tr.dimmer_nodes[1].y == 1.0,
		"stops when one reaches 100 % (keeping the slope)")
	_click(tr, Vector2(430, y - span), MOUSE_BUTTON_LEFT, false)
	# Past the last node: the line holds its level, so it moves that node.
	y = r.end.y - 4.0 - 0.5 * span
	_click(tr, Vector2(950, y), MOUSE_BUTTON_LEFT, true)
	_motion(tr, Vector2(950, y + span * 0.5))
	ok(tr.dimmer_nodes[2].y == 0.0 and tr.dimmer_nodes[1].y == 1.0, "after the last node: moves the last node")
	_click(tr, Vector2(950, y + span * 0.5), MOUSE_BUTTON_LEFT, false)
	# Shift locks a node drag to the axis moved furthest on.
	tr.dimmer_nodes = PackedVector2Array([Vector2(0.2, 0.5), Vector2(0.8, 0.5)])
	var n0 := Vector2(200, r.end.y - 4.0 - 0.5 * span)
	var x0 := tr.dimmer_nodes[0].x                  # 0.2 as stored (32-bit)
	_click(tr, n0, MOUSE_BUTTON_LEFT, true)
	var ev := InputEventMouseMotion.new()
	ev.position = n0 + Vector2(100, 15)
	ev.shift_pressed = true
	tr._gui_input(ev)
	ok(is_equal_approx(tr.dimmer_nodes[0].x, 0.3) and tr.dimmer_nodes[0].y == 0.5,
		"shift, mostly sideways: only in time")
	ev.position = n0 + Vector2(10, 30)
	tr._gui_input(ev)
	ok(tr.dimmer_nodes[0].x == x0 and is_equal_approx(tr.dimmer_nodes[0].y, 0.5 - 30.0 / span),
		"shift, mostly up / down: only in level")
	_motion(tr, n0 + Vector2(10, 30))
	ok(is_equal_approx(tr.dimmer_nodes[0].x, 0.21), "without shift: both")
	_click(tr, n0, MOUSE_BUTTON_LEFT, false)
	tr.queue_free()


func _par() -> FixtureProfile:
	return FixtureProfile.new("par", "RGB par", [
		{"name": "Dimmer", "role": "DIMMER"}, {"name": "Red", "role": "RED"},
		{"name": "Green", "role": "GREEN"}, {"name": "Blue", "role": "BLUE"},
	])


func _bar() -> FixtureProfile:
	var chans := [{"name": "Strobe", "role": "STROBE"}]
	for h in range(3):
		chans.append({"name": "Red %d" % (h + 1), "role": "RED"})
		chans.append({"name": "Green %d" % (h + 1), "role": "GREEN"})
		chans.append({"name": "Blue %d" % (h + 1), "role": "BLUE"})
	chans.append({"name": "White 3", "role": "WHITE"})
	return FixtureProfile.new("bar", "3-head LED bar", chans)


func _test_fixture_specs() -> void:
	print("- timelines for a fixture and its heads")
	var R := TimelineTrack.Row
	var T := TimelineTrack.Target
	var par := MusicTimeline.fixture_track_specs("0/1", "Par", _par(), 0)
	ok(par.size() == 1 and par[0]["title"] == "Par" and par[0]["target"] == T.FIXTURE
		and par[0]["rows"] == [R.COLOUR, R.DIMMER], "a single-head fixture: one timeline")
	var bar := MusicTimeline.fixture_track_specs("0/2", "Bar", _bar(), 0)
	ok(bar.size() == 4, "a three-head fixture: its own timeline plus one per head (%d)" % bar.size())
	ok(bar[0]["target"] == T.FIXTURE and bar[0]["rows"] == [R.STROBE, R.COLOUR, R.DIMMER],
		"the fixture's covers all its channels")
	ok(bar[1]["target"] == T.HEAD and bar[1]["title"] == "Bar\nHead 1" and bar[3]["title"] == "Bar\nHead 3",
		"heads titled in order, \"Head N\" on a second line")
	ok(bar[1]["rows"] == [R.COLOUR, R.DIMMER], "a head's rows are its own channels' (no strobe)")
	ok(bar[1]["key"] != bar[2]["key"] and bar[0]["key"] == "0/2", "each with its own key")


func _test_fixture_tracks() -> void:
	print("- the fixtures' timelines in the track timeline")
	var fixtures := [{"key": "0/1", "name": "Par", "profile": _par(), "mode": 0}]
	var tl := MusicTimeline.new()
	tl.fixtures_provider = func(): return fixtures
	root.add_child(tl)
	tl.position = Vector2.ZERO
	tl.size = Vector2(1100, 700)
	await process_frame
	ok(tl.fixture_tracks().is_empty(), "nothing until refreshed / a track opens")
	tl.open("user://_no_such_song.wav")             # dimmer nodes belong to the open song
	tl.refresh_fixtures()
	await process_frame
	await process_frame
	ok(tl.fixture_tracks().size() == 1 and tl.fixture_tracks()[0].title == "Par", "one per fixture")
	var sc := tl.fixture_scroll().get_global_rect()
	var mr := tl.master_track().get_global_rect()
	ok(sc.end.y <= mr.position.y + 0.5 and sc.position.y < 60.0, "the scroll panel fills the space above the master")
	var fr := tl.fixture_tracks()[0].get_global_rect()
	ok(is_equal_approx(fr.position.x, mr.position.x) and is_equal_approx(fr.size.x, mr.size.x),
		"exactly as wide as the master (and waveform) (%.0f vs %.0f)" % [fr.size.x, mr.size.x])
	ok(fr.position.y >= sc.position.y - 0.5, "at the top of the panel")
	var plate := tl.fixture_tracks()[0].get_parent().get_child(1) as Control
	var vbar := tl.fixture_scroll().get_v_scroll_bar().get_global_rect()
	ok(plate is TimelineTrack.NamePlate and is_equal_approx(plate.get_global_rect().size.y, fr.size.y)
		and plate.get_global_rect().end.x <= vbar.position.x + 0.5, "a name plate beside it, clear of the scroll bar")
	ok(tl.fixture_tracks()[0].wave == tl.wave(), "follows the waveform's zoom")
	# Edits survive a refresh; a three-head bar adds four timelines and scrolls.
	tl.fixture_tracks()[0].dimmer_nodes = PackedVector2Array([Vector2(1, 0.5)])
	for i in range(3):
		fixtures.append({"key": "0/%d" % (i + 2), "name": "LED Bar %d" % (i + 1), "profile": _bar(), "mode": 0})
	tl.refresh_fixtures()
	await process_frame
	await process_frame
	ok(tl.fixture_tracks().size() == 13, "1 par + 3 bars × (1 + 3 heads) = 13 (%d)" % tl.fixture_tracks().size())
	ok(tl.fixture_tracks()[0].dimmer_nodes == PackedVector2Array([Vector2(1, 0.5)]), "a kept fixture keeps its dimmer nodes")
	ok(tl.fixture_tracks()[2].target == TimelineTrack.Target.HEAD, "heads follow their fixture")
	var hp := tl.fixture_tracks()[2].get_parent().get_child(1) as TimelineTrack.NamePlate
	ok(hp.lines() == PackedStringArray(["LED Bar 1", "Head 1"]), "a head's plate: two lines")
	ok(hp.font_size() == TimelineTrack.NamePlate.FONT_SIZE, "each short enough for the full size")
	ok((tl.master_plate() as TimelineTrack.NamePlate).font_size() == TimelineTrack.NamePlate.FONT_SIZE,
		"a short name keeps the full size")
	var bar := tl.fixture_scroll().get_v_scroll_bar()
	ok(bar.max_value > bar.page, "more than fits: it scrolls")
	ok(is_equal_approx(tl.fixture_scroll().get_global_rect().end.y, sc.end.y), "without pushing the master down")
	fixtures.clear()
	tl.refresh_fixtures()
	ok(tl.fixture_tracks().is_empty(), "no fixtures: none")
	tl.queue_free()


func _test_in_timeline() -> void:
	print("- the master track in the timeline")
	var tl := MusicTimeline.new()
	root.add_child(tl)
	tl.position = Vector2.ZERO
	tl.size = Vector2(1100, 700)
	await process_frame
	await process_frame
	var m := tl.master_track()
	var mr := m.get_global_rect()
	var sr := tl.structure_bar().get_global_rect()
	var wr := tl.wave().get_global_rect()
	ok(m.target == TimelineTrack.Target.MASTER and m.rows.size() == 5, "a master track with every row")
	ok(is_equal_approx(mr.end.y, sr.position.y), "right above the song structure")
	ok(is_equal_approx(mr.position.x, wr.position.x) and is_equal_approx(mr.size.x, wr.size.x), "as wide as the waveform")
	ok(is_equal_approx(mr.size.y, 120.0), "120 px tall")
	var lb := tl.lock_button().get_global_rect()
	ok(is_equal_approx(lb.position.y, sr.position.y), "lock / generate buttons still level with the structure bar")
	ok(m.wave == tl.wave(), "follows the waveform's zoom")
	var plate := tl.master_plate()
	var pr := plate.get_global_rect()
	ok(is_equal_approx(pr.position.y, mr.position.y) and is_equal_approx(pr.size.y, mr.size.y),
		"name plate beside it, as tall as it")
	ok(pr.position.x >= mr.end.x and is_equal_approx(pr.end.x, tl.play_button().get_global_rect().end.x),
		"filling the column to its right")
	ok(plate.title() == "Master", "showing the target's name")
	# Mouse input through the viewport reaches the master's dimmer line.
	var y := mr.position.y + m.row_rect(TimelineTrack.Row.DIMMER).position.y + 4.0
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.position = Vector2(mr.position.x + 200.0, y)
		ev.global_position = ev.position
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.ctrl_pressed = true
		root.push_input(ev)
	ok(m.dimmer_nodes.size() == 1, "ctrl+click in the timeline adds a master dimmer node")
	tl.queue_free()


# The global position of time `t` on `row` of track `tr` (in a timeline).
func _at(tl: MusicTimeline, tr: TimelineTrack, row: int, t: float, dy := 0.0) -> Vector2:
	var wr := tl.wave().get_global_rect()
	var x := wr.position.x + (t - tl.wave().view_start) / tl.wave().visible_length() * wr.size.x
	var r := tr.row_rect(row)
	return Vector2(x, (tr.get_global_transform() * r.get_center()).y + dy)


func _press(tl: MusicTimeline, pos: Vector2, pressed: bool, ctrl := false, shift := false) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.ctrl_pressed = ctrl
	ev.shift_pressed = shift
	tl.get_viewport().push_input(ev)


func _move(tl: MusicTimeline, pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	tl.get_viewport().push_input(ev)


func _sel_drag(tl: MusicTimeline, a: Vector2, b: Vector2, ctrl := false, shift := false) -> void:
	_press(tl, a, true, ctrl, shift)
	_move(tl, (a + b) * 0.5)
	_move(tl, b)
	_press(tl, b, false, ctrl, shift)


func _test_area_selection() -> void:
	print("- selecting areas of the timelines")
	var R := TimelineTrack.Row
	var fixtures := [{"key": "par", "name": "Par", "profile": _par(), "mode": 0}]
	var tl := MusicTimeline.new()
	tl.fixtures_provider = func(): return fixtures
	root.add_child(tl)
	tl.position = Vector2.ZERO
	tl.size = Vector2(1100, 700)
	var a := SongAnalysis.new()
	a.duration = 60.0
	for arr in [a.wave_lo, a.wave_mid, a.wave_hi, a.wave_peak]:
		arr.resize(6000)
	tl._set_analysis(a)
	var beats := PackedFloat32Array()
	for i in range(120):
		beats.append(i * 0.5)                  # 120 BPM: bars of 2 s from 0
	tl.wave().set_beat_grid(beats, 4, 0)
	tl.refresh_fixtures()
	await process_frame
	await process_frame
	tl.wave().set_view(0.0, 20.0)
	var m := tl.master_track()
	var par := tl.fixture_tracks()[0]
	var sel := tl.selection()
	var sb := tl.structure_bar()

	# Bar snapping (the default): whole bars on the row.
	_sel_drag(tl, _at(tl, m, R.DIMMER, 3.1), _at(tl, m, R.DIMMER, 6.9))
	ok(sel.blocks.size() == 1 and sel.blocks[0]["rows"] == PackedStringArray(["master|%d" % R.DIMMER])
		and is_equal_approx(sel.blocks[0]["t0"], 2.0) and is_equal_approx(sel.blocks[0]["t1"], 8.0),
		"a drag on a row selects the whole bars it touches (2–8 s)")
	ok(m.dimmer_nodes.is_empty(), "...without touching the dimmer line")
	ok(sel.has("master", R.DIMMER, 5.0) and not sel.has("master", R.COLOUR, 5.0), "only that row")
	# Another plain drag replaces it.
	_sel_drag(tl, _at(tl, m, R.MOVEMENT, 10.5), _at(tl, m, R.MOVEMENT, 11.0))
	ok(sel.blocks.size() == 1 and is_equal_approx(sel.blocks[0]["t0"], 10.0) and is_equal_approx(sel.blocks[0]["t1"], 12.0)
		and sel.blocks[0]["rows"] == PackedStringArray(["master|%d" % R.MOVEMENT]), "a new plain drag replaces the selection")
	# Ctrl adds.
	_sel_drag(tl, _at(tl, m, R.STROBE, 14.2), _at(tl, m, R.STROBE, 14.4), true)
	ok(sel.blocks.size() == 2 and sel.has("master", R.MOVEMENT, 11.0) and sel.has("master", R.STROBE, 15.0),
		"Ctrl adds to it")
	# Shift: from the last area (strobe, 14–16 s) through the new one.
	_sel_drag(tl, _at(tl, m, R.DIMMER, 18.5), _at(tl, m, R.DIMMER, 18.6), false, true)
	var last: Dictionary = sel.blocks[-1]
	ok(sel.blocks.size() == 2 and is_equal_approx(last["t0"], 14.0) and is_equal_approx(last["t1"], 20.0),
		"Shift extends the last area through the new one in time (14–20 s)")
	ok(last["rows"] == PackedStringArray(["master|%d" % R.DIMMER, "master|%d" % R.COLOUR, "master|%d" % R.MOVEMENT, "master|%d" % R.STROBE]),
		"...and takes in the rows between (%s)" % str(last["rows"]))
	ok(sel.has("master", R.MOVEMENT, 11.0), "earlier Ctrl-added areas stay")
	# Across tracks: the fixture's dimmer down to the master's position row.
	_sel_drag(tl, _at(tl, par, R.DIMMER, 4.0), _at(tl, m, R.POSITION, 5.0))
	var rows: PackedStringArray = sel.blocks[0]["rows"]
	ok(sel.blocks.size() == 1 and rows.size() == 2 + 5 and rows[0] == "par|%d" % R.DIMMER
		and rows[1] == "par|%d" % R.COLOUR and rows[2] == "master|%d" % R.DIMMER and rows[6] == "master|%d" % R.POSITION,
		"dragging across tracks covers every row between, top to bottom (%d rows)" % rows.size())
	ok(par.selection == sel and m.selection == sel, "both tracks draw the same selection")
	# Beat and no snapping.
	sb.snap = StructureBar.Snap.BEAT
	_sel_drag(tl, _at(tl, m, R.MOVEMENT, 3.1), _at(tl, m, R.MOVEMENT, 3.3))
	ok(is_equal_approx(sel.blocks[0]["t0"], 3.0) and is_equal_approx(sel.blocks[0]["t1"], 3.5), "beat snapping: whole beats")
	sb.snap = StructureBar.Snap.NONE
	sel.clear()                                  # (a drag inside a selection would move it)
	_sel_drag(tl, _at(tl, m, R.MOVEMENT, 3.1), _at(tl, m, R.MOVEMENT, 7.3))
	ok(absf(sel.blocks[0]["t0"] - 3.1) < 0.05 and absf(sel.blocks[0]["t1"] - 7.3) < 0.05,
		"no snapping: exactly where dragged (%.2f–%.2f)" % [sel.blocks[0]["t0"], sel.blocks[0]["t1"]])
	# A plain click (no drag) clears it — with snapping, it selects that cell.
	_press(tl, _at(tl, m, R.MOVEMENT, 9.0), true)
	_press(tl, _at(tl, m, R.MOVEMENT, 9.0), false)
	ok(sel.is_empty(), "no snapping: a click clears the selection")
	sb.snap = StructureBar.Snap.BAR
	_press(tl, _at(tl, m, R.MOVEMENT, 9.0), true)
	_press(tl, _at(tl, m, R.MOVEMENT, 9.0), false)
	ok(sel.blocks.size() == 1 and is_equal_approx(sel.blocks[0]["t0"], 8.0) and is_equal_approx(sel.blocks[0]["t1"], 10.0),
		"bar snapping: a click selects the bar under it")
	# A node or the line isn't empty timeline: no selecting there.
	m.dimmer_nodes = PackedVector2Array([Vector2(5.0, 0.5)])
	var node_pos := m.get_global_transform() * Vector2(m._t2x(5.0), m._level_y(m.row_rect(R.DIMMER), 0.5))
	_sel_drag(tl, node_pos, node_pos + Vector2(80, 0))
	ok(sel.blocks.size() == 1 and is_equal_approx(sel.blocks[0]["t0"], 8.0) and m.dimmer_nodes[0].x > 5.0,
		"dragging a node moves the node, not the selection")
	# Opening another song clears it.
	tl.open("user://_another_song.wav")
	ok(sel.is_empty(), "another song: selection cleared")
	tl.queue_free()
	await process_frame


func _test_clear_dimmer() -> void:
	print("- clearing a span of the dimmer")
	var tr := TimelineTrack.new()             # no waveform: no song end
	tr.dimmer_nodes = PackedVector2Array([Vector2(0, 0.2), Vector2(4, 1.0), Vector2(6, 0.6), Vector2(10, 0.2)])
	ok(tr.clear_dimmer(2.0, 8.0), "reports a change")
	var n := tr.dimmer_nodes
	ok(n == PackedVector2Array([Vector2(0, 0.2), Vector2(2, 0.6), Vector2(2, 0), Vector2(8, 0), Vector2(8, 0.4), Vector2(10, 0.2)]),
		"nodes inside go; steps down to 0 and back up at the edges (%s)" % str(n))
	ok(is_equal_approx(tr.dimmer_at(1.0), 0.4) and is_equal_approx(tr.dimmer_at(9.0), 0.3),
		"the level outside the span is unchanged")
	ok(tr.dimmer_at(3.0) == 0.0 and tr.dimmer_at(7.9) == 0.0, "0 inside")
	ok(not tr.clear_dimmer(2.0, 8.0) and tr.dimmer_nodes == n, "clearing it again changes nothing")
	# No nodes (a flat 100 %).
	tr.dimmer_nodes = PackedVector2Array()
	tr.clear_dimmer(3.0, 5.0)
	ok(tr.dimmer_nodes == PackedVector2Array([Vector2(3, 1), Vector2(3, 0), Vector2(5, 0), Vector2(5, 1)])
		and tr.dimmer_at(1.0) == 1.0 and tr.dimmer_at(9.0) == 1.0, "a flat line: a gap at 0, full either side")
	# From the song's start; and where it's already dark outside.
	tr.dimmer_nodes = PackedVector2Array([Vector2(0, 0.0), Vector2(10, 1.0)])
	tr.clear_dimmer(0.0, 5.0)
	ok(tr.dimmer_nodes == PackedVector2Array([Vector2(0, 0), Vector2(5, 0), Vector2(5, 0.5), Vector2(10, 1)]),
		"from the start: no node before it (%s)" % str(tr.dimmer_nodes))
	tr.dimmer_nodes = PackedVector2Array([Vector2(2, 0.0), Vector2(4, 0.0)])
	tr.clear_dimmer(2.5, 3.5)
	ok(tr.dimmer_nodes == PackedVector2Array([Vector2(2, 0), Vector2(2.5, 0), Vector2(3.5, 0), Vector2(4, 0)]),
		"already dark outside: no extra edge nodes")
	ok(not tr.clear_dimmer(5.0, 5.0), "an empty span: nothing")
	tr.free()


func _test_delete_selection() -> void:
	print("- Delete clears the selected areas")
	var R := TimelineTrack.Row
	var fixtures := [{"key": "par", "name": "Par", "profile": _par(), "mode": 0}]
	var tl := MusicTimeline.new()
	tl.fixtures_provider = func(): return fixtures
	root.add_child(tl)
	tl.position = Vector2.ZERO
	tl.size = Vector2(1100, 700)
	var a := SongAnalysis.new()
	a.duration = 60.0
	for arr in [a.wave_lo, a.wave_mid, a.wave_hi, a.wave_peak]:
		arr.resize(6000)
	tl._set_analysis(a)
	tl.open("user://_delete_song.wav")         # so edits count (no file: not saved)
	tl._set_analysis(a)
	tl.refresh_fixtures()
	await process_frame
	await process_frame
	var m := tl.master_track()
	var par := tl.fixture_tracks()[0]
	m.dimmer_nodes = PackedVector2Array([Vector2(1, 0.5), Vector2(5, 1.0), Vector2(30, 0.5)])
	par.dimmer_nodes = PackedVector2Array([Vector2(3, 0.8)])
	var sel := tl.selection()
	sel.set_blocks([
		TimelineSelection.block(PackedStringArray(["master|%d" % R.DIMMER, "master|%d" % R.MOVEMENT]), 4.0, 8.0),
		TimelineSelection.block(PackedStringArray(["master|%d" % R.DIMMER]), 6.0, 12.0),     # overlaps: merged
		TimelineSelection.block(PackedStringArray(["par|%d" % R.DIMMER]), 10.0, 20.0)])
	var ev := InputEventKey.new()
	ev.keycode = KEY_DELETE
	ev.pressed = true
	root.push_input(ev)
	await process_frame
	var mn := m.dimmer_nodes
	ok(mn.size() == 6 and mn[0] == Vector2(1, 0.5) and mn[2] == Vector2(4, 0) and mn[3] == Vector2(12, 0)
		and mn[5] == Vector2(30, 0.5), "the master's dimmer: one dark span over the merged 4–12 s (%s)" % str(mn))
	ok(is_equal_approx(m.dimmer_at(4.0), 0.875) and is_equal_approx(m.dimmer_at(20.0), 0.7)
		and is_equal_approx(m._dimmer_after(12.0), 0.86), "levels either side kept")
	ok(par.dimmer_nodes.size() == 4 and par.dimmer_at(15.0) == 0.0 and is_equal_approx(par.dimmer_at(5.0), 0.8)
		and not par.dimmer_defined_at(25.0), "the fixture's dimmer too (and no edge node past its line's end)")
	ok(tl.has_unsaved_timelines(), "marked as changed (saved on leaving the song)")
	ok(sel.blocks.size() == 3, "the selection stays")
	sel.clear()
	ev = InputEventKey.new()
	ev.keycode = KEY_DELETE
	ev.pressed = true
	root.push_input(ev)
	ok(m.dimmer_nodes == mn, "nothing selected: Delete does nothing")
	tl.queue_free()
	await process_frame


func _test_generate_into_selection() -> void:
	print("- Generate with areas selected fills only those")
	var R := TimelineTrack.Row
	var fixtures := [{"key": "par", "name": "Par", "profile": _par(), "mode": 0}]
	var tl := MusicTimeline.new()
	tl.fixtures_provider = func(): return fixtures
	root.add_child(tl)
	tl.size = Vector2(1100, 700)
	var a := SongAnalysis.new()
	a.duration = 60.0
	for arr in [a.wave_lo, a.wave_mid, a.wave_hi, a.wave_peak]:
		arr.resize(6000)
	tl._set_analysis(a)
	tl.open("user://_gen_sel_song.wav")
	tl._set_analysis(a)
	tl.refresh_fixtures()
	await process_frame
	var m := tl.master_track()
	var par := tl.fixture_tracks()[0]
	m.dimmer_nodes = PackedVector2Array([Vector2(0, 0.5), Vector2(60, 0.5)])
	m.colour_segments = [{"t0": 0.0, "t1": 60.0, "c0": Color.RED, "c1": Color.RED}]
	par.dimmer_nodes = PackedVector2Array([Vector2(0, 0.3), Vector2(60, 0.3)])
	var show := {
		"master": {"dimmer": PackedVector2Array([Vector2(0, 1.0), Vector2(60, 1.0)]),
			"colour": [{"t0": 0.0, "t1": 60.0, "c0": Color.BLUE, "c1": Color.BLUE}]},
		"par": {"dimmer": PackedVector2Array([Vector2(0, 0.9), Vector2(60, 0.9)])}}
	tl.selection().set_blocks([
		TimelineSelection.block(PackedStringArray(["master|%d" % R.DIMMER, "master|%d" % R.COLOUR]), 10.0, 20.0)])
	ok(tl._splice_show(show), "reports a change")
	ok(m.dimmer_at(15.0) == 1.0 and m.dimmer_at(5.0) == 0.5 and m._dimmer_after(20.0) == 0.5,
		"the master's dimmer: generated inside the area, kept outside")
	ok(m.segment_colour_at(m.colour_segments, 15.0) == Color.BLUE and m.segment_colour_at(m.colour_segments, 5.0) == Color.RED
		and m.segment_colour_at(m.colour_segments, 30.0) == Color.RED, "its colour too")
	ok(is_equal_approx(par.dimmer_at(15.0), 0.3), "a track with nothing selected is left alone (%s)" % str(par.dimmer_nodes))
	tl.selection().set_blocks([TimelineSelection.block(PackedStringArray(["par|%d" % R.DIMMER]), 30.0, 40.0)])
	ok(not tl._splice_show(show, {"par": true}), "a left-out fixture's selected rows are left alone")
	tl.queue_free()
	await process_frame


func _structure_analysis(label: String) -> SongAnalysis:
	var a := SongAnalysis.new()
	a.duration = 40.0
	a.bpm = 120.0
	for arr in [a.wave_lo, a.wave_mid, a.wave_hi, a.wave_peak]:
		arr.resize(4000)
	a.sections = [{"start": 0.0, "end": 20.0, "label": label, "energy": 0.3, "cluster": 0},
		{"start": 20.0, "end": 40.0, "label": "Chorus", "energy": 0.9, "cluster": 1}]
	return a


func _test_reanalyse_and_generate() -> void:
	print("- Shift+Generate re-analyses the structure, then generates")
	var path := "user://_reanalyse_song.wav"
	var tl := MusicTimeline.new()
	root.add_child(tl)
	tl.size = Vector2(1100, 700)
	var old := _structure_analysis("Intro")
	tl._set_analysis(old)
	tl.open(path)
	tl._set_analysis(old)
	tl._structure_ready(path, old, null)
	await process_frame
	old.sections[0]["label"] = "Verse"                # an edit to the structure
	tl._on_structure_edited()
	var before := tl.master_track().dimmer_nodes
	ok(not tl.reanalyse_and_generate(), "no such file: nothing to re-analyse")
	tl._regenerate[path] = true                        # as reanalyse_and_generate() leaves it
	tl._structure_ready(path, _structure_analysis("Intro"), null)
	ok(not tl.song_data().has("structure"), "the structure's edits are dropped")
	ok(tl.structure().sections[0]["label"] == "Intro", "the fresh analysis is shown")
	ok(tl.master_track().dimmer_nodes != before, "and a show's generated from it")
	ok(not tl._regenerate.has(path), "only once")
	ok(tl.undo() and tl.song_data().get("structure", {}).get("sections", [{}])[0].get("label") == "Verse"
		and tl.master_track().dimmer_nodes == before, "one undo brings back the edited structure and the old show")
	tl.queue_free()
	await process_frame


func _test_dimmer_segments() -> void:
	print("- copying / replacing a stretch of the dimmer line")
	var tr := TimelineTrack.new()
	tr.dimmer_nodes = PackedVector2Array([Vector2(0, 0.2), Vector2(4, 1.0), Vector2(6, 0.6), Vector2(10, 0.2)])
	var seg := tr.dimmer_segment(2.0, 8.0)
	ok(seg == PackedVector2Array([Vector2(0, 0.6), Vector2(2, 1.0), Vector2(4, 0.6), Vector2(6, 0.4)]),
		"a segment: the edge levels and the nodes inside, relative to its start (%s)" % str(seg))
	tr.dimmer_nodes = PackedVector2Array([Vector2(0, 0.5), Vector2(20, 0.5)])
	ok(tr.replace_dimmer(10.0, 16.0, seg), "pasting it reports a change")
	for t in [10.5, 12.0, 13.0, 15.9]:
		ok(is_equal_approx(tr.dimmer_at(t), [0.6, 1.0, 0.8, 0.41][[10.5, 12.0, 13.0, 15.9].find(t)] if t != 10.5 else 0.7),
			"pasted shape at %.1f s (%.3f)" % [t, tr.dimmer_at(t)])
	ok(tr.dimmer_at(9.0) == 0.5 and tr._dimmer_after(16.0) == 0.5 and tr.dimmer_at(18.0) == 0.5, "the line outside unchanged")
	ok(not tr.replace_dimmer(10.0, 16.0, seg), "pasting the same again changes nothing")
	# Cut off at the song's end.
	var tl := MusicTimeline.new()
	root.add_child(tl)
	var a := SongAnalysis.new()
	a.duration = 12.0
	for arr in [a.wave_lo, a.wave_mid, a.wave_hi, a.wave_peak]:
		arr.resize(1200)
	tl._set_analysis(a)
	var m := tl.master_track()
	m.dimmer_nodes = PackedVector2Array()
	m.replace_dimmer(10.0, 16.0, seg)
	ok(m.dimmer_nodes[-1].x == 12.0 and is_equal_approx(m.dimmer_nodes[-1].y, 1.0) and m.dimmer_nodes.size() == 3,
		"past the song's end: cut there (%s)" % str(m.dimmer_nodes))
	tl.queue_free()
	tr.free()


func _key(keycode: Key, ctrl := true) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.ctrl_pressed = ctrl
	ev.pressed = true
	root.push_input(ev)


func _test_copy_paste() -> void:
	print("- Ctrl+C / Ctrl+V")
	var R := TimelineTrack.Row
	var fixtures := [{"key": "p1", "name": "Par 1", "profile": _par(), "mode": 0},
		{"key": "p2", "name": "Par 2", "profile": _par(), "mode": 0}]
	var tl := MusicTimeline.new()
	tl.fixtures_provider = func(): return fixtures
	root.add_child(tl)
	tl.position = Vector2.ZERO
	tl.size = Vector2(1100, 700)
	tl.open("user://_paste_song.wav")
	var a := SongAnalysis.new()
	a.duration = 60.0
	for arr in [a.wave_lo, a.wave_mid, a.wave_hi, a.wave_peak]:
		arr.resize(6000)
	tl._set_analysis(a)
	await process_frame
	await process_frame
	var m := tl.master_track()
	var p1 := tl.fixture_tracks()[0]
	var p2 := tl.fixture_tracks()[1]
	var sel := tl.selection()
	m.dimmer_nodes = PackedVector2Array([Vector2(4, 0.0), Vector2(6, 1.0), Vector2(8, 0.0)])
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["master|%d" % R.DIMMER, "master|%d" % R.MOVEMENT]), 4.0, 8.0)])
	_key(KEY_C)
	var clip := tl.clipboard()
	ok(clip.get("length") == 4.0 and clip["tracks"].size() == 1 and clip["tracks"][0]["key"] == "master"
		and clip["tracks"][0]["rows"].has(R.DIMMER) and clip["tracks"][0]["rows"].has(R.MOVEMENT), "Ctrl+C copies the selected rows")
	ok(sel.blocks.size() == 1, "copying leaves the selection")
	# Paste at a selected spot on the same track.
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["master|%d" % R.DIMMER]), 20.0, 22.0)])
	_key(KEY_V)
	ok(is_equal_approx(m.dimmer_at(22.0), 1.0) and m.dimmer_at(20.0) == 0.0 and is_equal_approx(m.dimmer_at(23.0), 0.5),
		"Ctrl+V pastes at the selection's start (20–24 s)")
	ok(m.dimmer_at(5.0) == 0.5 and m.dimmer_at(14.0) == 0.0 and m.dimmer_at(30.0) == 0.0, "the rest of the line unchanged")
	ok(sel.blocks.size() == 2 and is_equal_approx(sel.blocks[0]["t0"], 20.0) and is_equal_approx(sel.blocks[0]["t1"], 24.0),
		"the pasted area becomes the selection (dimmer and cues rows)")
	ok(tl.has_unsaved_timelines(), "marked as changed")
	# One copied track into several selected ones.
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["p1|%d" % R.COLOUR, "p1|%d" % R.MOVEMENT, "p2|%d" % R.DIMMER]), 30.0, 31.0)])
	_key(KEY_V)
	ok(is_equal_approx(p1.dimmer_at(32.0), 1.0) and is_equal_approx(p2.dimmer_at(32.0), 1.0)
		and p1._dimmer_after(30.0) == 0.0 and not p1.dimmer_defined_at(29.0) and p1.dimmer_nodes.size() == 3,
		"one copied track pastes into every selected track (an empty fixture row: just the pasted stretch)")
	ok(sel.blocks.size() == 2, "each gets its dimmer row selected (pars have no movement row)")
	# Nothing selected: at the playhead, back into the source track.
	sel.clear()
	tl.wave().song_pos = 40.0
	_key(KEY_V)
	ok(is_equal_approx(m.dimmer_at(42.0), 1.0) and m.dimmer_at(40.0) == 0.0, "nothing selected: at the playhead, into the source track")
	# Two copied tracks pair off with the selected tracks.
	p1.dimmer_nodes = PackedVector2Array([Vector2(0, 0.3), Vector2(60, 0.3)])
	p2.dimmer_nodes = PackedVector2Array([Vector2(0, 0.7), Vector2(60, 0.7)])
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["p1|%d" % R.DIMMER, "p1|%d" % R.MOVEMENT, "p2|%d" % R.DIMMER]), 0.0, 2.0)])
	_key(KEY_C)
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["master|%d" % R.DIMMER]), 50.0, 51.0),
		TimelineSelection.block(PackedStringArray(["p1|%d" % R.DIMMER]), 50.0, 51.0)])
	_key(KEY_V)
	ok(is_equal_approx(p1.dimmer_at(51.0), 0.3) and is_equal_approx(m.dimmer_at(51.0), 0.7),
		"several copied tracks pair off in order (Par 1 -> Par 1, Par 2 -> master)")
	# Ctrl+X: copied, then cleared like Delete; pastes back the same shape.
	m.dimmer_nodes = PackedVector2Array([Vector2(0, 0.5), Vector2(55, 1.0)])
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["master|%d" % R.DIMMER]), 10.0, 20.0)])
	var at15 := m.dimmer_at(15.0)
	_key(KEY_X)
	ok(tl.clipboard()["length"] == 10.0 and tl.clipboard()["tracks"][0]["key"] == "master", "Ctrl+X copies the selection")
	ok(m._dimmer_after(10.0) == 0.0 and m.dimmer_at(19.0) == 0.0 and is_equal_approx(m.dimmer_at(25.0), 0.5 + 0.5 * 25.0 / 55.0),
		"...and clears it, the line outside kept")
	ok(sel.blocks.size() == 1, "the selection stays")
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["master|%d" % R.DIMMER]), 30.0, 31.0)])
	_key(KEY_V)
	ok(is_equal_approx(m.dimmer_at(35.0), at15), "what was cut pastes elsewhere")
	sel.clear()
	ok(not tl.cut_selection(), "nothing selected: nothing to cut")
	# The copy survives opening another song.
	tl.open("user://_paste_song_2.wav")
	tl._set_analysis(a)
	ok(not tl.clipboard().is_empty(), "the copy is kept when another song opens")
	sel.clear()
	_key(KEY_V, false)
	ok(sel.is_empty(), "plain V doesn't paste")
	tl._dirty = false
	tl.queue_free()
	await process_frame


func _key_shift(keycode: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.ctrl_pressed = true
	ev.shift_pressed = true
	ev.pressed = true
	root.push_input(ev)


func _test_undo_redo() -> void:
	print("- Ctrl+Z / Ctrl+Y")
	var R := TimelineTrack.Row
	var fixtures := [{"key": "p1", "name": "Par 1", "profile": _par(), "mode": 0}]
	var tl := MusicTimeline.new()
	tl.fixtures_provider = func(): return fixtures
	root.add_child(tl)
	tl.position = Vector2.ZERO
	tl.size = Vector2(1100, 700)
	var a := SongAnalysis.new()
	a.duration = 60.0
	for arr in [a.wave_lo, a.wave_mid, a.wave_hi, a.wave_peak]:
		arr.resize(6000)
	tl.open("user://_undo_song.wav")
	tl._set_analysis(a)
	await process_frame
	var m := tl.master_track()
	var p1 := tl.fixture_tracks()[0]
	ok(not tl.can_undo() and not tl.can_redo(), "a freshly opened song: nothing to undo")
	ok(m.dimmer_nodes == PackedVector2Array([Vector2(0, 0), Vector2(60, 0)]),
		"the master's dimmer starts with a node at the start and the end, at 0 %")
	ok(not tl.has_unsaved_timelines(), "...which isn't an edit")
	# Edit 1: a node added on the master (as the mouse does: change, then report).
	m.dimmer_nodes = PackedVector2Array([Vector2(10, 0.5)])
	m.dimmer_edited.emit()
	# Edit 2: the fixture's line.
	p1.dimmer_nodes = PackedVector2Array([Vector2(5, 0.2), Vector2(15, 0.8)])
	p1.dimmer_edited.emit()
	# Edit 3: Delete over the master's 8–12 s.
	tl.selection().set_blocks([TimelineSelection.block(PackedStringArray(["master|%d" % R.DIMMER]), 8.0, 12.0)])
	tl.delete_selection()
	var after_delete := m.dimmer_nodes
	ok(tl.can_undo() and not tl.can_redo(), "edits can be undone")
	_key(KEY_Z)
	ok(m.dimmer_nodes == PackedVector2Array([Vector2(10, 0.5)]), "Ctrl+Z undoes the Delete")
	_key(KEY_Z)
	ok(p1.dimmer_nodes.is_empty() and m.dimmer_nodes.size() == 1, "again: the fixture's edit")
	_key(KEY_Z)
	ok(m.dimmer_nodes == PackedVector2Array([Vector2(0, 0), Vector2(60, 0)]) and not tl.can_undo(),
		"again: back to how the song opened (the master's default start / end nodes)")
	ok(not tl.undo(), "nothing more to undo")
	_key(KEY_Y)
	ok(m.dimmer_nodes == PackedVector2Array([Vector2(10, 0.5)]) and p1.dimmer_nodes.is_empty(), "Ctrl+Y redoes")
	_key_shift(KEY_Z)
	ok(p1.dimmer_nodes == PackedVector2Array([Vector2(5, 0.2), Vector2(15, 0.8)]), "so does Ctrl+Shift+Z")
	_key(KEY_Y)
	ok(m.dimmer_nodes == after_delete and not tl.can_redo(), "all the way back")
	ok(tl.has_unsaved_timelines(), "undo / redo leave the song to be saved")
	# A new edit after an undo drops the redo.
	tl.undo()
	ok(tl.can_redo(), "(undone once)")
	m.dimmer_nodes = PackedVector2Array([Vector2(30, 1.0)])
	m.dimmer_edited.emit()
	ok(not tl.can_redo(), "a new edit clears what could be redone")
	tl.undo()
	ok(m.dimmer_nodes == PackedVector2Array([Vector2(10, 0.5)]), "and undoes back to before it")
	# Paste is undoable too.
	tl.selection().set_blocks([TimelineSelection.block(PackedStringArray(["master|%d" % R.DIMMER]), 0.0, 20.0)])
	tl.copy_selection()
	tl.selection().set_blocks([TimelineSelection.block(PackedStringArray(["p1|%d" % R.DIMMER]), 30.0, 31.0)])
	var p1_before := p1.dimmer_nodes
	tl.paste()
	ok(p1.dimmer_nodes != p1_before, "(pasted)")
	tl.undo()
	ok(p1.dimmer_nodes == p1_before, "a paste undoes")
	# The structure.
	var sa := SongAnalysis.new()
	sa.duration = 60.0
	sa.sections = [{"start": 0.0, "end": 30.0, "label": "Verse", "energy": 0.4, "cluster": 0}, {"start": 30.0, "end": 60.0, "label": "Chorus", "energy": 0.9, "cluster": 1}]
	tl._struct_cache[tl.current_path()] = sa
	tl._apply_saved_structure(tl.current_path(), sa)
	sa.sections[0]["label"] = "Intro"
	tl.structure_bar().structure_edited.emit()
	ok(tl.can_undo(), "a structure edit can be undone")
	tl.undo()
	ok(sa.sections[0]["label"] == "Verse", "undo puts the structure back")
	tl.redo()
	ok(sa.sections[0]["label"] == "Intro", "redo re-applies it")
	# Ctrl+A: everything.
	tl.selection().clear()
	_key(KEY_A)
	var all: Array = tl.selection().blocks
	ok(all.size() == 1 and all[0]["t0"] == 0.0 and all[0]["t1"] == 60.0
		and (all[0]["rows"] as PackedStringArray).size() == tl.fixture_tracks()[0].rows.size() + m.rows.size(),
		"Ctrl+A selects every row of every timeline over the whole song")
	ok(tl.selection().has("p1", R.DIMMER, 30.0) and tl.selection().has("master", R.POSITION, 59.0), "fixtures and master alike")
	tl.selection().set_blocks([TimelineSelection.block(PackedStringArray(["master|%d" % R.MOVEMENT]), 1.0, 2.0)])
	_key(KEY_A)
	ok(tl.selection().blocks.size() == 1 and tl.selection().blocks[0]["t1"] == 60.0, "replacing any selection")
	_key(KEY_A, false)
	ok(tl.selection().blocks[0]["t1"] == 60.0, "(plain A: nothing)")
	_key(KEY_D, false)
	ok(not tl.selection().is_empty(), "(plain D: nothing)")
	_key(KEY_D)
	ok(tl.selection().is_empty(), "Ctrl+D clears the selection")
	_key(KEY_A)
	_key(KEY_ESCAPE, false)
	ok(tl.selection().is_empty(), "so does Escape")
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	root.push_input(esc)
	ok(not root.is_input_handled(), "Escape with nothing selected is left for others")
	# Per song: another song has its own history; coming back keeps this one's.
	tl.open("user://_undo_song_2.wav")
	ok(not tl.can_undo(), "another song: its own (empty) history")
	tl.open("user://_undo_song.wav")
	ok(tl.can_undo(), "back again: this song's history is still there")
	# Another show's folder: history gone.
	tl.set_timeline_store(TimelineStore.new("user://_undo_other.timelines"))
	ok(not tl.can_undo(), "another show: history cleared")
	tl._dirty = false
	tl.queue_free()
	await process_frame


func _test_dimmer_shapes() -> void:
	print("- the Dimmer submenu's shapes")
	var D := MusicTimeline.Dim
	var shape := func(k): return MusicTimeline.dimmer_shape(k, 10.0, 14.0, 0.3, 0.6)
	ok(shape.call(D.BLACK) == PackedVector2Array([Vector2(0, 0), Vector2(4, 0)]), "Black: 0%")
	ok(shape.call(D.FULL) == PackedVector2Array([Vector2(0, 1), Vector2(4, 1)]), "Full: 100%")
	ok(shape.call(D.HALF) == PackedVector2Array([Vector2(0, 0.5), Vector2(4, 0.5)]), "Half: 50%")
	ok(shape.call(D.FADE_IN) == PackedVector2Array([Vector2(0, 0), Vector2(4, 1)]), "Fade In: 0% up to 100%")
	ok(shape.call(D.FADE_OUT) == PackedVector2Array([Vector2(0, 1), Vector2(4, 0)]), "Fade Out: 100% down to 0%")
	ok(shape.call(D.PULSE_IN) == PackedVector2Array([Vector2(0, 0.3), Vector2(2, 1), Vector2(4, 0.6)]),
		"Pulse In: from the level on the left up to 100% and down to the level on the right")
	ok(shape.call(D.PULSE_OUT) == PackedVector2Array([Vector2(0, 0.3), Vector2(2, 0), Vector2(4, 0.6)]), "Pulse Out: down to 0% in the middle")
	ok(shape.call(D.SMOOTH) == PackedVector2Array([Vector2(0, 0.3), Vector2(4, 0.6)]), "Smooth: a straight ramp between the two")
	var beats := PackedFloat32Array([9.0, 10.5, 11.0, 13.0, 15.0])
	var pulses: PackedVector2Array = MusicTimeline.dimmer_shape(D.BEAT_PULSES, 10.0, 14.0, 0.3, 0.6, beats)
	ok(pulses == PackedVector2Array([Vector2(0, 0), Vector2(0.5, 0), Vector2(0.5, 1), Vector2(1, 0), Vector2(1, 0), Vector2(1, 1),
		Vector2(3, 0), Vector2(3, 0), Vector2(3, 1), Vector2(4, 0)]), "beat pulses: up at each beat, down to 0%% by the next (%s)" % str(pulses))
	ok(MusicTimeline.dimmer_shape(D.BEAT_PULSES, 20.0, 21.0, 0, 0, beats).is_empty(), "no beats in the span: no shape")


func _menu_ids(menu: PopupMenu) -> Array:
	var out := []
	for i in range(menu.item_count):
		if not menu.is_item_separator(i):
			out.append(menu.get_item_text(i))
	return out


func _test_context_menu() -> void:
	print("- the right-click menu")
	var R := TimelineTrack.Row
	var fixtures := [{"key": "p1", "name": "Par 1", "profile": _par(), "mode": 0}]
	var tl := MusicTimeline.new()
	tl.fixtures_provider = func(): return fixtures
	root.add_child(tl)
	tl.position = Vector2.ZERO
	tl.size = Vector2(1100, 700)
	tl.open("user://_menu_song.wav")
	var a := SongAnalysis.new()
	a.duration = 60.0
	for arr in [a.wave_lo, a.wave_mid, a.wave_hi, a.wave_peak]:
		arr.resize(6000)
	tl._set_analysis(a)
	await process_frame
	await process_frame
	var m := tl.master_track()
	var p1 := tl.fixture_tracks()[0]
	var sel := tl.selection()
	# Off the selection, nothing to undo or paste: just Select All.
	ok(_menu_ids(tl.context_items(false)) == ["Select All"], "off any selection, a fresh song: Select All")
	# On a selection of dimmer rows.
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["master|%d" % R.DIMMER, "p1|%d" % R.DIMMER]), 10.0, 14.0)])
	ok(_menu_ids(tl.context_items(true)) == ["Delete", "Cut", "Copy", "Dimmer", "Select All", "Deselect"],
		"on a dimmer selection: Delete, Cut, Copy, Dimmer, Select All, Deselect (%s)" % str(_menu_ids(tl.context_items(true))))
	var dm: PopupMenu = tl._dimmer_menu
	ok(_menu_ids(dm) == ["Black (0%)", "Half (50%)", "Full (100%)", "Fade In", "Fade Out", "Pulse In", "Pulse Out",
		"Smooth (ramp across)", "Pulse on Every Beat", "Pulse on Every Bar"], "the Dimmer submenu")
	ok(dm.is_item_disabled(dm.get_item_index(MusicTimeline.Dim.BEAT_PULSES)), "beat pulses greyed out without a beat grid")
	# A real right-click on it opens the menu.
	var wr := tl.wave().get_global_rect()
	var at := Vector2(wr.position.x + 12.0 / 60.0 * wr.size.x, (m.get_global_transform() * m.row_rect(R.DIMMER).get_center()).y)
	var ev := InputEventMouseButton.new()
	ev.position = at
	ev.global_position = at
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = true
	root.push_input(ev)
	ok(tl._menu.visible and tl._ctx["track"] == m and tl._ctx["row"] == R.DIMMER and absf(tl._ctx["time"] - 12.0) < 0.2,
		"right-clicking the selection opens the menu there")
	tl._menu.hide()
	# Pulse In from the menu.
	m.dimmer_nodes = PackedVector2Array([Vector2(0, 0.4), Vector2(60, 0.4)])
	m.dimmer_edited.emit()
	dm.id_pressed.emit(MusicTimeline.Dim.PULSE_IN)
	ok(is_equal_approx(m.dimmer_at(12.0), 1.0) and is_equal_approx(m.dimmer_at(10.0), 0.4) and is_equal_approx(m._dimmer_after(14.0), 0.4),
		"Dimmer > Pulse In: up to 100% mid-span, the edges at the level outside")
	ok(is_equal_approx(p1.dimmer_at(12.0), 1.0) and is_equal_approx(p1.dimmer_at(10.0), 0.4) and not p1.dimmer_defined_at(9.0),
		"...on every selected dimmer row (an empty fixture row: from / to the level it inherits — the master's)")
	ok(_menu_ids(tl.context_items(true)).has("Undo"), "now Undo is offered")
	tl._menu.id_pressed.emit(MusicTimeline.M_UNDO)
	ok(is_equal_approx(m.dimmer_at(12.0), 0.4) and _menu_ids(tl.context_items(true)).has("Redo"), "Undo from the menu; then Redo is offered")
	tl._menu.id_pressed.emit(MusicTimeline.M_REDO)
	ok(is_equal_approx(m.dimmer_at(12.0), 1.0), "Redo from the menu")
	# Colour rows.
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["p1|%d" % R.COLOUR, "master|%d" % R.COLOUR]), 20.0, 30.0)])
	var items := _menu_ids(tl.context_items(true))
	ok(items.has("Colour") and not items.has("Dimmer"), "a colour selection: a Colour submenu (no Dimmer)")
	var cm := _menu_ids(tl._colour_menu)
	ok(cm[1] == "Gradient…" and cm[2] == "Rainbow" and cm.has("Red") and cm[-1] == "Clear Colour",
		"the Colour submenu: static, gradient, rainbow, presets, clear (%s)" % str(cm))
	tl._colour_menu.id_pressed.emit(MusicTimeline.Col.PRESET + 5)      # Blue
	ok(p1.colour_at(25.0) == Color(0, 0, 1) and m.colour_at(25.0) == Color(0, 0, 1) and p1.colour_at(31.0) == null,
		"Colour > Blue: a static colour over the span")
	ok(tl.apply_gradient(Color(1, 0, 0), Color(0, 1, 0)) and (p1.colour_at(25.0) as Color).is_equal_approx(Color(0.5, 0.5, 0)),
		"a gradient across the span")
	ok(tl.apply_rainbow() and p1.colour_segments.size() == 6 and (p1.colour_at(20.0) as Color).is_equal_approx(Color(1, 0, 0)),
		"a rainbow: six segments round the hue wheel")
	# Delete, copy / paste and the saved form.
	tl.apply_static_colour(Color(1, 0.5, 0))
	tl.copy_selection()
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["p1|%d" % R.COLOUR]), 40.0, 41.0)])
	tl.paste()
	ok(p1.colour_at(45.0) == Color(1, 0.5, 0) and m.colour_at(45.0) == null, "colour copies and pastes")
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["p1|%d" % R.COLOUR]), 22.0, 24.0)])
	tl._menu.id_pressed.emit(MusicTimeline.M_DELETE)
	ok(p1.colour_at(23.0) == null and p1.colour_at(21.0) == Color(1, 0.5, 0) and p1.colour_at(25.0) == Color(1, 0.5, 0),
		"Delete cuts a gap in a colour segment")
	tl._collect()
	var saved: Array = tl.song_data()["tracks"]["p1"]["colour"]
	ok(saved.size() == 3 and saved[0][2] == "ff8000", "saved as [t0, t1, colour, colour] (%s)" % str(saved[0]))
	ok(_near(MusicTimeline._segs_from(saved)[0]["c0"], Color(1, 0.5, 0)), "and read back (8-bit)")
	tl.undo()
	ok(_near(p1.colour_at(23.0), Color(1, 0.5, 0)), "undo brings colour back too")
	# Off the selection with something copied: Paste Here, into the track clicked.
	sel.clear()
	items = _menu_ids(tl.context_items(false))
	ok(items.has("Paste Here") and items.has("Undo") and not items.has("Delete") and not items.has("Copy"),
		"off the selection: Undo / Paste Here, no Delete / Copy (%s)" % str(items))
	tl._ctx = {"track": p1, "row": R.COLOUR, "time": 50.0}
	tl._menu.id_pressed.emit(MusicTimeline.M_PASTE_HERE)
	ok(p1.colour_at(55.0) == Color(1, 0.5, 0), "Paste Here: at the clicked time, into the clicked track")
	# Ctrl+right-click on a dimmer node still removes it (no menu).
	tl._menu.hide()
	m.dimmer_nodes = PackedVector2Array([Vector2(12, 0.5)])
	var node_at := m.get_global_transform() * Vector2(m._t2x(12.0), m._level_y(m.row_rect(R.DIMMER), 0.5))
	ev = InputEventMouseButton.new()
	ev.position = node_at
	ev.global_position = node_at
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.ctrl_pressed = true
	ev.pressed = true
	root.push_input(ev)
	ok(m.dimmer_nodes.is_empty() and not tl._menu.visible, "Ctrl+right-click on a node still removes it, no menu")
	tl._dirty = false
	tl.queue_free()
	await process_frame


## Colours equal to 8-bit precision (as they're saved).
func _near(a, b: Color) -> bool:
	return a is Color and absf(a.r - b.r) < 0.003 and absf(a.g - b.g) < 0.003 and absf(a.b - b.b) < 0.003


func _test_drag_selection() -> void:
	print("- dragging a selection's edges, and the selection")
	var R := TimelineTrack.Row
	var fixtures := [{"key": "p1", "name": "Par 1", "profile": _par(), "mode": 0}]
	var tl := MusicTimeline.new()
	tl.fixtures_provider = func(): return fixtures
	root.add_child(tl)
	tl.position = Vector2.ZERO
	tl.size = Vector2(1100, 700)
	tl.open("user://_move_song.wav")
	var a := SongAnalysis.new()
	a.duration = 60.0
	for arr in [a.wave_lo, a.wave_mid, a.wave_hi, a.wave_peak]:
		arr.resize(6000)
	tl._set_analysis(a)
	var beats := PackedFloat32Array()
	for i in range(120):
		beats.append(i * 0.5)                  # bars of 2 s from 0
	tl.wave().set_beat_grid(beats, 4, 0)
	await process_frame
	await process_frame
	tl.wave().set_view(0.0, 20.0)
	var m := tl.master_track()
	var p1 := tl.fixture_tracks()[0]
	var sel := tl.selection()
	var sb := tl.structure_bar()
	sb.snap = StructureBar.Snap.BAR
	# A dark span 4–8 s on the master's dimmer (steps at both edges), selected.
	m.dimmer_nodes = PackedVector2Array([Vector2(0, 0.5), Vector2(4, 0.5), Vector2(4, 0), Vector2(8, 0), Vector2(8, 0.5), Vector2(12, 0.5)])
	m.dimmer_edited.emit()
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["master|%d" % R.DIMMER, "master|%d" % R.MOVEMENT]), 4.0, 8.0)])
	await process_frame
	# Hovering: the cursor says what a drag would do.
	var mid_y := (m.get_global_transform() * m.row_rect(R.MOVEMENT).get_center()).y
	var local_end := Vector2(m._t2x(8.0), m.row_rect(R.MOVEMENT).get_center().y)
	m._set_hover(-1, false, local_end)
	ok(m.mouse_default_cursor_shape == Control.CURSOR_HSIZE, "over a selection's edge: left-right arrows")
	m._set_hover(-1, false, Vector2(m._t2x(6.0), local_end.y))
	ok(m.mouse_default_cursor_shape == Control.CURSOR_MOVE, "inside it: a move cursor")
	# Drag the end from 8 s to about 9.7 s: snaps to the bar at 10 s; the
	# nodes on that edge go with it.
	_sel_drag(tl, _at(tl, m, R.MOVEMENT, 8.0), _at(tl, m, R.MOVEMENT, 9.7))
	ok(sel.blocks.size() == 1 and sel.blocks[0]["t0"] == 4.0 and is_equal_approx(sel.blocks[0]["t1"], 10.0),
		"dragging the end moves it, snapped to the bar (4–%.1f s)" % sel.blocks[0]["t1"])
	ok(m.dimmer_nodes == PackedVector2Array([Vector2(0, 0.5), Vector2(4, 0.5), Vector2(4, 0), Vector2(10, 0), Vector2(10, 0.5), Vector2(12, 0.5)]),
		"the dimmer nodes on that edge moved with it (%s)" % str(m.dimmer_nodes))
	tl.undo()
	ok(m.dimmer_nodes[3].x == 8.0, "one undo step")
	tl.redo()
	# The start can't pass the next node out (none here) nor the end; past
	# a neighbouring node it stops there.
	_sel_drag(tl, _at(tl, m, R.MOVEMENT, 10.0), _at(tl, m, R.MOVEMENT, 18.0))
	ok(is_equal_approx(sel.blocks[0]["t1"], 12.0) and m.dimmer_nodes[3].x == 12.0,
		"an edge with nodes stops at the next node along (%.1f)" % sel.blocks[0]["t1"])
	tl.undo()
	_sel_drag(tl, _at(tl, m, R.MOVEMENT, 4.0), _at(tl, m, R.MOVEMENT, 15.0))
	ok(sel.blocks[0]["t0"] < sel.blocks[0]["t1"] and sel.blocks[0]["t0"] <= 10.0, "the start can't pass the end")
	tl.undo()
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["master|%d" % R.DIMMER, "master|%d" % R.MOVEMENT]), 4.0, 10.0)])
	await process_frame
	# Move the selection: grab it at 6 s, drop it at about 13 s — the start
	# moves 7 s, snapped to the bar: 4 -> 10 s (rounded from 11).
	var before := m.dimmer_nodes
	_press(tl, _at(tl, m, R.MOVEMENT, 6.0), true)
	_move(tl, _at(tl, m, R.MOVEMENT, 9.0))
	_move(tl, _at(tl, m, R.MOVEMENT, 13.0))
	ok(is_equal_approx(sel.blocks[0]["t0"], 12.0) and m.dimmer_nodes == before,
		"while dragging: the selection moves (snapped), the content not yet (%.1f)" % sel.blocks[0]["t0"])
	ok(m.ghost.get("at") == 12.0 and m.ghost.get("from") == 4.0 and m.ghost["rows"].has(R.DIMMER)
		and m.ghost["rows"][R.DIMMER][0]["nodes"] is PackedVector2Array and p1.ghost.is_empty(),
		"...with a ghost of its content where it would land (only on the tracks it covers)")
	_press(tl, _at(tl, m, R.MOVEMENT, 13.0), false)
	ok(is_equal_approx(sel.blocks[0]["t0"], 12.0) and is_equal_approx(sel.blocks[0]["t1"], 18.0), "on release: moved to 12–18 s")
	ok(m.ghost.is_empty(), "the ghost goes on release")
	ok(m._dimmer_after(12.0) == 0.0 and m.dimmer_at(17.9) == 0.0 and is_equal_approx(m._dimmer_after(18.0), 0.5),
		"the dark span went with it, overwriting what was there")
	ok(m._dimmer_after(4.0) == 0.0 and m.dimmer_at(9.0) == 0.0 and m.dimmer_at(3.0) == 0.5, "where it was is cleared (as Delete does)")
	ok(tl.clipboard().is_empty(), "the clipboard's untouched")
	tl.undo()
	ok(m.dimmer_nodes == before, "one undo step puts it all back")
	# A click inside the selection without dragging: a plain click there.
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["master|%d" % R.MOVEMENT]), 4.0, 10.0)])
	_press(tl, _at(tl, m, R.MOVEMENT, 6.5), true)
	_move(tl, _at(tl, m, R.MOVEMENT, 6.6))
	ok(m.ghost.is_empty(), "no ghost until the selection has actually moved")
	_press(tl, _at(tl, m, R.MOVEMENT, 6.5), false)
	ok(sel.blocks.size() == 1 and is_equal_approx(sel.blocks[0]["t0"], 6.0) and is_equal_approx(sel.blocks[0]["t1"], 8.0),
		"a click inside the selection selects the bar under it")
	# Ctrl / Shift inside the selection still build it.
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["master|%d" % R.MOVEMENT]), 4.0, 10.0)])
	_sel_drag(tl, _at(tl, m, R.MOVEMENT, 6.5), _at(tl, m, R.MOVEMENT, 7.0), true)
	ok(sel.blocks.size() == 2, "Ctrl+drag inside: adds an area, doesn't move")
	# A colour segment moves too.
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["p1|%d" % R.COLOUR]), 2.0, 4.0)])
	tl.apply_static_colour(Color(1, 0, 0))
	tl.move_selection(sel.blocks.duplicate(true), 4.0)
	ok(p1.colour_at(3.0) == null and p1.colour_at(7.0) == Color(1, 0, 0), "colour moves with the selection")
	# Colour segment boundaries on a dragged edge move with it.
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["p1|%d" % R.COLOUR]), 6.0, 8.0)])
	p1.colour_segments = [{"t0": 2.0, "t1": 6.0, "c0": Color(0, 1, 0), "c1": Color(0, 1, 0)},
		{"t0": 6.0, "t1": 8.0, "c0": Color(1, 0, 0), "c1": Color(1, 0, 0)},
		{"t0": 12.0, "t1": 14.0, "c0": Color(0, 0, 1), "c1": Color(0, 0, 1)}]
	p1.dimmer_edited.emit()                         # (a recorded edit, for undo)
	await process_frame
	_sel_drag(tl, _at(tl, p1, R.COLOUR, 8.0), _at(tl, p1, R.COLOUR, 9.8))
	ok(is_equal_approx(sel.blocks[0]["t1"], 10.0) and is_equal_approx(p1.colour_segments[1]["t1"], 10.0)
		and p1.colour_segments[1]["c1"] == Color(1, 0, 0), "a segment ending on the dragged edge stretches with it (to %.1f)" % p1.colour_segments[1]["t1"])
	_sel_drag(tl, _at(tl, p1, R.COLOUR, 6.0), _at(tl, p1, R.COLOUR, 3.9))
	ok(is_equal_approx(sel.blocks[0]["t0"], 4.0) and is_equal_approx(p1.colour_segments[0]["t1"], 4.0)
		and is_equal_approx(p1.colour_segments[1]["t0"], 4.0), "both segments meeting on the edge move with it (to %.1f)" % sel.blocks[0]["t0"])
	_sel_drag(tl, _at(tl, p1, R.COLOUR, 10.0), _at(tl, p1, R.COLOUR, 16.0))
	ok(is_equal_approx(p1.colour_segments[1]["t1"], 12.0) and p1.colour_segments[2]["t0"] == 12.0,
		"stopped by the next segment along (%.1f)" % p1.colour_segments[1]["t1"])
	tl.undo()
	ok(is_equal_approx(p1.colour_segments[1]["t1"], 10.0), "undoable")
	tl._dirty = false
	tl.queue_free()
	await process_frame


func _test_strobe_model() -> void:
	print("- strobe segments")
	var tr := TimelineTrack.new()
	ok(not tr.strobe_at(1.0), "off by default")
	ok(tr.replace_strobe(2.0, 4.0, [{"t0": 0.0, "t1": 2.0}]) and tr.strobe_at(3.0) and not tr.strobe_at(5.0), "turned on across a span")
	ok(not tr.replace_strobe(2.0, 4.0, [{"t0": 0.0, "t1": 2.0}]), "again: no change")
	tr.replace_strobe(4.0, 6.0, [{"t0": 0.0, "t1": 2.0}])
	ok(tr.strobe_segments == [{"t0": 2.0, "t1": 6.0, "speed": 1}], "touching segments join (%s)" % str(tr.strobe_segments))
	tr.replace_strobe(3.0, 4.0, [])
	ok(tr.strobe_segments == [{"t0": 2.0, "t1": 3.0, "speed": 1}, {"t0": 4.0, "t1": 6.0, "speed": 1}], "off in the middle: a gap")
	var S := TimelineTrack.Strobe
	tr.replace_strobe(6.0, 8.0, [{"t0": 0.0, "t1": 2.0, "speed": S.FAST}])
	ok(tr.strobe_segments.size() == 3 and tr.strobe_speed_at(7.0) == S.FAST and tr.strobe_speed_at(5.0) == S.MEDIUM,
		"a different speed next to it: kept separate")
	ok(tr.strobe_speed_at(3.5) == -1, "off: -1")
	var r := Rect2(0, 0, 100, 10)
	ok(TimelineTrack.strobe_line_y(r, S.SLOW) > TimelineTrack.strobe_line_y(r, S.MEDIUM)
		and TimelineTrack.strobe_line_y(r, S.MEDIUM) > TimelineTrack.strobe_line_y(r, S.FAST),
		"the dashed line: low for slow, middle for medium, high for fast")
	ok(tr.strobe_segment(2.5, 5.0) == [{"t0": 0.0, "t1": 0.5, "speed": 1}, {"t0": 1.5, "t1": 2.5, "speed": 1}], "a stretch copied, relative to its start (with its speed)")
	tr.free()


func _test_strobe_editing() -> void:
	print("- the strobe row in the timeline")
	var R := TimelineTrack.Row
	var mover := FixtureProfile.new("mv", "Mover", [{"name": "Pan", "role": "PAN"}, {"name": "Tilt", "role": "TILT"},
		{"name": "Shutter", "role": "STROBE"}, {"name": "Dimmer", "role": "DIMMER"}])
	var fixtures := [{"key": "mv", "name": "Mover", "profile": mover, "mode": 0}]
	var tl := MusicTimeline.new()
	tl.fixtures_provider = func(): return fixtures
	root.add_child(tl)
	tl.position = Vector2.ZERO
	tl.size = Vector2(1100, 700)
	tl.open("user://_strobe_song.wav")
	var a := SongAnalysis.new()
	a.duration = 60.0
	for arr in [a.wave_lo, a.wave_mid, a.wave_hi, a.wave_peak]:
		arr.resize(6000)
	tl._set_analysis(a)
	var beats := PackedFloat32Array()
	for i in range(120):
		beats.append(i * 0.5)
	tl.wave().set_beat_grid(beats, 4, 0)
	await process_frame
	await process_frame
	tl.wave().set_view(0.0, 20.0)
	var mv := tl.fixture_tracks()[0]
	var m := tl.master_track()
	var sel := tl.selection()
	ok(mv.has_row(R.STROBE), "a fixture with a strobe channel has a strobe row")
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["mv|%d" % R.STROBE, "master|%d" % R.STROBE]), 4.0, 8.0)])
	var items := _menu_ids(tl.context_items(true))
	ok(items.has("Strobe") and not items.has("Colour") and not items.has("Dimmer"), "a strobe selection: a Strobe submenu (%s)" % str(items))
	ok(_menu_ids(tl._strobe_menu) == ["Strobe Slow", "Strobe Medium", "Strobe Fast", "Strobe Off"], "Strobe Slow / Medium / Fast / Off")
	tl._strobe_menu.id_pressed.emit(TimelineTrack.Strobe.FAST)
	ok(mv.strobe_speed_at(6.0) == TimelineTrack.Strobe.FAST and m.strobe_at(6.0) and not mv.strobe_at(9.0),
		"Strobe Fast: on, fast, across the selected rows")
	tl._strobe_menu.id_pressed.emit(TimelineTrack.Strobe.MEDIUM)
	ok(mv.strobe_speed_at(6.0) == TimelineTrack.Strobe.MEDIUM and mv.strobe_segments.size() == 1, "Strobe Medium: the speed changed")
	tl.undo()
	ok(mv.strobe_speed_at(6.0) == TimelineTrack.Strobe.FAST, "undo: back to fast")
	tl.undo()
	ok(not mv.strobe_at(6.0), "again: off")
	tl.redo()
	tl.redo()
	# Saved, and read back.
	tl._collect()
	ok(tl.song_data()["tracks"]["mv"]["strobe"] == [[4.0, 8.0, 1]], "saved as [[t0, t1, speed]]")
	ok(MusicTimeline._spans_from([[4.0, 8.0, 2]]) == [{"t0": 4.0, "t1": 8.0, "speed": 2}], "and read back")
	ok(MusicTimeline._spans_from([[4.0, 8.0]]) == [{"t0": 4.0, "t1": 8.0, "speed": 1}], "saved without a speed: medium")
	# Copy / paste, Delete.
	tl.copy_selection()
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["mv|%d" % R.STROBE]), 20.0, 21.0)])
	tl.paste()
	ok(mv.strobe_at(22.0) and not m.strobe_at(22.0), "copies and pastes")
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["mv|%d" % R.STROBE]), 5.0, 6.0)])
	tl.delete_selection()
	ok(mv.strobe_at(4.5) and not mv.strobe_at(5.5) and mv.strobe_at(7.0), "Delete turns it off there")
	tl._strobe_menu.id_pressed.emit(TimelineTrack.Strobe.MEDIUM)
	ok(mv.strobe_segments[0] == {"t0": 4.0, "t1": 8.0, "speed": 1}, "on again: rejoined")
	# Edge drag: the boundary on the edge goes with it.
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["mv|%d" % R.STROBE]), 4.0, 8.0)])
	await process_frame
	_sel_drag(tl, _at(tl, mv, R.STROBE, 8.0), _at(tl, mv, R.STROBE, 9.8))
	ok(is_equal_approx(mv.strobe_segments[0]["t1"], 10.0), "dragging the edge moves the strobe's end (%.1f)" % mv.strobe_segments[0]["t1"])
	# Move the selection: the strobe goes with it.
	tl.move_selection(sel.blocks.duplicate(true), 10.0)
	ok(not mv.strobe_at(6.0) and mv.strobe_at(16.0) and mv.strobe_at(19.9), "moving the selection moves the strobe")
	ok(_menu_ids(tl.context_items(true)).has("Strobe"), "(still selected)")
	tl._strobe_menu.id_pressed.emit(100)            # Strobe Off
	ok(not mv.strobe_at(16.0), "Strobe Off")
	tl._dirty = false
	tl.queue_free()
	await process_frame


func _test_position_row() -> void:
	print("- the position row")
	var R := TimelineTrack.Row
	var lib := PositionLibrary.new()
	var crowd := lib.add()
	lib.rename(crowd["id"], "Crowd")
	var stage := lib.add()
	lib.rename(stage["id"], "Stage")
	var mover := FixtureProfile.new("mv", "Mover", [{"name": "Pan", "role": "PAN"}, {"name": "Tilt", "role": "TILT"},
		{"name": "Dimmer", "role": "DIMMER"}])
	var fixtures := [{"key": "mv", "name": "Mover", "profile": mover, "mode": 0}]
	var tl := MusicTimeline.new()
	tl.fixtures_provider = func(): return fixtures
	tl.positions = lib
	root.add_child(tl)
	tl.position = Vector2.ZERO
	tl.size = Vector2(1100, 700)
	tl.open("user://_position_song.wav")
	var a := SongAnalysis.new()
	a.duration = 60.0
	for arr in [a.wave_lo, a.wave_mid, a.wave_hi, a.wave_peak]:
		arr.resize(6000)
	tl._set_analysis(a)
	var beats := PackedFloat32Array()
	for i in range(120):
		beats.append(i * 0.5)
	tl.wave().set_beat_grid(beats, 4, 0)
	await process_frame
	await process_frame
	tl.wave().set_view(0.0, 20.0)
	var mv := tl.fixture_tracks()[0]
	var m := tl.master_track()
	var sel := tl.selection()
	ok(mv.has_row(R.POSITION) and mv.positions == lib and m.positions == lib, "a mover has a position row; the tracks know the positions")
	# The model.
	ok(mv.replace_position(2.0, 4.0, [{"t0": 0.0, "t1": 2.0, "pos": crowd["id"]}]) and mv.position_at(3.0) == crowd["id"]
		and mv.position_at(5.0) == "", "a position across a span")
	mv.replace_position(4.0, 6.0, [{"t0": 0.0, "t1": 2.0, "pos": crowd["id"]}])
	ok(mv.position_segments == [{"t0": 2.0, "t1": 6.0, "pos": crowd["id"]}], "the same position touching: joined")
	mv.replace_position(6.0, 8.0, [{"t0": 0.0, "t1": 2.0, "pos": stage["id"]}])
	ok(mv.position_segments.size() == 2 and mv.position_at(7.0) == stage["id"], "a different one: kept apart")
	ok(mv.position_segment(5.0, 7.0) == [{"t0": 0.0, "t1": 1.0, "pos": crowd["id"]}, {"t0": 1.0, "t1": 2.0, "pos": stage["id"]}],
		"a stretch copied, with its positions")
	mv.position_segments = []
	# The Position submenu.
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["mv|%d" % R.POSITION, "master|%d" % R.POSITION]), 4.0, 8.0)])
	var items := _menu_ids(tl.context_items(true))
	ok(items.has("Position") and not items.has("Strobe"), "a position selection: a Position submenu (%s)" % str(items))
	var pm: PopupMenu = tl._position_menu
	ok(_menu_ids(pm) == ["Crowd", "Stage", "Clear Position"], "each named position, then Clear Position (%s)" % str(_menu_ids(pm)))
	ok(pm.get_item_icon(0) == PositionEditor.triangle_icon(crowd["colour"]) and pm.get_item_icon(1) == PositionEditor.triangle_icon(stage["colour"]),
		"with its coloured icon")
	pm.id_pressed.emit(1)
	ok(mv.position_at(6.0) == stage["id"] and m.position_at(6.0) == stage["id"] and mv.position_at(9.0) == "", "picking one puts it across the selected rows")
	tl.undo()
	ok(mv.position_at(6.0) == "", "undoable")
	tl.redo()
	tl._collect()
	ok(tl.song_data()["tracks"]["mv"]["position"] == [[4.0, 8.0, stage["id"]]], "saved as [[t0, t1, position id]]")
	ok(MusicTimeline._pos_from([[4.0, 8.0, stage["id"]]]) == [{"t0": 4.0, "t1": 8.0, "pos": stage["id"]}], "and read back")
	# Copy / paste, move, edge drag, clear.
	tl.copy_selection()
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["mv|%d" % R.POSITION]), 20.0, 21.0)])
	tl.paste()
	ok(mv.position_at(22.0) == stage["id"] and m.position_at(22.0) == "", "copies and pastes")
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["mv|%d" % R.POSITION]), 4.0, 8.0)])
	await process_frame
	_sel_drag(tl, _at(tl, mv, R.POSITION, 8.0), _at(tl, mv, R.POSITION, 9.8))
	ok(is_equal_approx(mv.position_segments[0]["t1"], 10.0), "dragging an edge moves the segment's end")
	tl.move_selection(sel.blocks.duplicate(true), 2.0)
	ok(mv.position_at(5.0) == "" and mv.position_at(11.0) == stage["id"], "moving the selection moves it")
	tl._position_menu.id_pressed.emit(MusicTimeline.POSITION_CLEAR)
	ok(mv.position_at(11.0) == "", "Clear Position")
	# A deleted position: still there, drawn grey.
	tl.apply_position(crowd["id"])
	lib.remove(crowd["id"])
	ok(mv.position_at(8.0) == crowd["id"], "a deleted position's segments stay (drawn grey)")
	# No positions at all.
	lib.clear()
	_menu_ids(tl.context_items(true))
	ok(tl._position_menu.is_item_disabled(0), "no positions: a hint, greyed out")
	tl._dirty = false
	tl.queue_free()
	await process_frame


func _test_movement_row() -> void:
	print("- the movement row")
	var R := TimelineTrack.Row
	# The shapes.
	var circle := {"fx": "circle", "period": 2.0, "size": 0.1}
	ok(TimelineTrack.movement_offset(circle, 0.0).is_equal_approx(Vector2(0.1, 0.0))
		and TimelineTrack.movement_offset(circle, 0.5).is_equal_approx(Vector2(0.0, 0.1))
		and TimelineTrack.movement_offset(circle, 1.0).is_equal_approx(Vector2(-0.1, 0.0))
		and TimelineTrack.movement_offset(circle, 2.0).is_equal_approx(Vector2(0.1, 0.0)), "circle: round once a period, at its size")
	var eight := {"fx": "figure8", "period": 2.0, "size": 0.1}
	ok(TimelineTrack.movement_offset(eight, 0.0).is_equal_approx(Vector2.ZERO)
		and TimelineTrack.movement_offset(eight, 0.5).is_equal_approx(Vector2(0.1, 0.0))
		and TimelineTrack.movement_offset(eight, 0.25).y > 0.0 and TimelineTrack.movement_offset(eight, 0.75).y < 0.0,
		"figure 8: across and back, up then down on each side")
	ok(TimelineTrack.movement_offset({"fx": "pan_sweep", "period": 2.0, "size": 0.1}, 0.5).is_equal_approx(Vector2(0.1, 0.0))
		and TimelineTrack.movement_offset({"fx": "tilt_sweep", "period": 2.0, "size": 0.1}, 0.5).is_equal_approx(Vector2(0.0, 0.1)),
		"pan sweep / tilt sweep: one axis")
	ok(TimelineTrack.movement_offset({"fx": "none"}, 0.7) == Vector2.ZERO, "none: still")
	# In the timeline.
	var mover := FixtureProfile.new("mv", "Mover", [{"name": "Pan", "role": "PAN"}, {"name": "Tilt", "role": "TILT"}])
	var fixtures := [{"key": "mv", "name": "Mover", "profile": mover, "mode": 0}]
	var tl := MusicTimeline.new()
	tl.fixtures_provider = func(): return fixtures
	root.add_child(tl)
	tl.position = Vector2.ZERO
	tl.size = Vector2(1100, 700)
	tl.open("user://_movement_song.wav")
	var a := SongAnalysis.new()
	a.duration = 60.0
	for arr in [a.wave_lo, a.wave_mid, a.wave_hi, a.wave_peak]:
		arr.resize(6000)
	tl._set_analysis(a)
	var beats := PackedFloat32Array()
	for i in range(140):
		beats.append(i * 0.45)                # 133 BPM: a bar is 1.8 s
	tl.wave().set_beat_grid(beats, 4, 0)
	await process_frame
	await process_frame
	tl.wave().set_view(0.0, 20.0)
	var mv := tl.fixture_tracks()[0]
	var m := tl.master_track()
	var sel := tl.selection()
	ok(mv.has_row(R.MOVEMENT) and TimelineTrack.ROW_NAMES[R.MOVEMENT] == "Movement", "a mover has a Movement row (the old Cues row)")
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["mv|%d" % R.MOVEMENT, "master|%d" % R.MOVEMENT]), 4.0, 8.0)])
	var items := _menu_ids(tl.context_items(true))
	ok(items.has("Movement"), "a movement selection: a Movement submenu")
	ok(_menu_ids(tl._movement_menu) == ["None", "Circle", "Figure 8", "Pan Sweep", "Tilt Sweep",
		"Small", "Medium", "Large", "1 bar", "2 bars", "4 bars", "Clear Movement"],
		"None, the shapes, Size, Cycle, Clear Movement (%s)" % str(_menu_ids(tl._movement_menu)))
	var mm: PopupMenu = tl._movement_menu
	ok(mm.is_item_radio_checkable(mm.get_item_index(MusicTimeline.MOVEMENT_SIZE_ID))
		and mm.is_item_checked(mm.get_item_index(MusicTimeline.MOVEMENT_SIZE_ID + 1))
		and mm.is_item_checked(mm.get_item_index(MusicTimeline.MOVEMENT_CYCLE_ID + 1)), "size / cycle as radio items: Medium, 2 bars to start")
	tl._movement_menu.id_pressed.emit(1)          # Circle
	var sg := mv.movement_at(6.0)
	ok(sg.get("fx") == "circle" and m.movement_at(6.0).get("fx") == "circle" and mv.movement_at(9.0).is_empty(),
		"Circle across the selected rows")
	ok(is_equal_approx(sg["period"], 3.6) and is_equal_approx(sg["size"], TimelineTrack.MOVEMENT_SIZE),
		"one cycle every two bars (%.2f s), the default size" % sg["period"])
	tl._collect()
	ok(tl.song_data()["tracks"]["mv"]["movement"] == [[4.0, 8.0, "circle", 3.6, TimelineTrack.MOVEMENT_SIZE]], "saved")
	ok(MusicTimeline._moves_from([[4.0, 8.0, "figure8", 1.8, 0.1]]) == [{"t0": 4.0, "t1": 8.0, "fx": "figure8", "period": 1.8, "size": 0.1}],
		"and read back")
	ok(MusicTimeline._moves_from([[4.0, 8.0, "wobble"]]).is_empty(), "an unknown effect is dropped")
	tl._movement_menu.id_pressed.emit(0)          # None
	ok(mv.movement_at(6.0).get("fx") == "none", "None: a segment that holds it still")
	tl.undo()
	ok(mv.movement_at(6.0).get("fx") == "circle", "undoable")
	tl.copy_selection()
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["mv|%d" % R.MOVEMENT]), 20.0, 21.0)])
	tl.paste()
	ok(mv.movement_at(22.0).get("fx") == "circle" and is_equal_approx(mv.movement_at(22.0)["period"], 3.6), "copies and pastes (with its period)")
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["mv|%d" % R.MOVEMENT]), 4.0, 8.0)])
	tl.move_selection(sel.blocks.duplicate(true), 2.0)
	ok(mv.movement_at(5.0).is_empty() and mv.movement_at(9.0).get("fx") == "circle", "moves with the selection")
	tl._movement_menu.id_pressed.emit(MusicTimeline.MOVEMENT_CLEAR)
	ok(mv.movement_at(9.0).is_empty(), "Clear Movement")
	# Size and cycle.
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["mv|%d" % R.MOVEMENT]), 2.0, 6.0)])
	tl._movement_menu.id_pressed.emit(MusicTimeline.MOVEMENT_SIZE_ID + 2)      # Large
	tl._movement_menu.id_pressed.emit(MusicTimeline.MOVEMENT_CYCLE_ID + 0)     # 1 bar
	tl._movement_menu.id_pressed.emit(2)                                        # Figure 8
	var big := mv.movement_at(4.0)
	ok(big.get("fx") == "figure8" and is_equal_approx(big["size"], 0.08) and is_equal_approx(big["period"], 1.8),
		"chosen size / cycle go with a new effect (Large, 1 bar = %.2f s)" % big["period"])
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["mv|%d" % R.MOVEMENT]), 10.0, 12.0)])
	tl._movement_menu.id_pressed.emit(1)
	ok(is_equal_approx(mv.movement_at(11.0)["size"], 0.08), "...and stay chosen for the next")
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["mv|%d" % R.MOVEMENT]), 0.0, 14.0)])
	_menu_ids(tl.context_items(true))
	ok(mm.is_item_checked(mm.get_item_index(MusicTimeline.MOVEMENT_SIZE_ID + 2))
		and mm.is_item_checked(mm.get_item_index(MusicTimeline.MOVEMENT_CYCLE_ID + 0)), "the menu shows the selection's size / cycle")
	tl._movement_menu.id_pressed.emit(MusicTimeline.MOVEMENT_SIZE_ID + 0)      # Small
	tl._movement_menu.id_pressed.emit(MusicTimeline.MOVEMENT_CYCLE_ID + 2)     # 4 bars
	ok(is_equal_approx(mv.movement_at(4.0)["size"], 0.02) and is_equal_approx(mv.movement_at(4.0)["period"], 7.2)
		and mv.movement_at(4.0)["fx"] == "figure8" and is_equal_approx(mv.movement_at(11.0)["size"], 0.02)
		and mv.movement_at(11.0)["fx"] == "circle", "changing size / cycle changes the selected movements, effects kept")
	ok(mv.movement_at(8.0).is_empty() and is_equal_approx(mv.movement_at(22.0)["size"], 0.04),
		"...and leaves the gaps, and movements outside the selection, alone")
	tl.undo()
	ok(is_equal_approx(mv.movement_at(4.0)["period"], 1.8), "undoable")
	tl._dirty = false
	tl.queue_free()
	await process_frame


func _test_dimmer_inheritance() -> void:
	print("- fixture / head dimmer rows inherit")
	var R := TimelineTrack.Row
	var fixtures := [{"key": "bar", "name": "Bar", "profile": _bar(), "mode": 0}]
	var tl := MusicTimeline.new()
	tl.fixtures_provider = func(): return fixtures
	root.add_child(tl)
	tl.position = Vector2.ZERO
	tl.size = Vector2(1100, 700)
	tl.open("user://_inherit_song.wav")
	var a := SongAnalysis.new()
	a.duration = 60.0
	for arr in [a.wave_lo, a.wave_mid, a.wave_hi, a.wave_peak]:
		arr.resize(6000)
	tl._set_analysis(a)
	await process_frame
	await process_frame
	tl.wave().set_view(0.0, 20.0)
	var m := tl.master_track()
	var bar := tl.fixture_tracks()[0]
	var head := tl.fixture_tracks()[1]
	var sel := tl.selection()
	ok(m.dimmer_polyline().size() == 2, "the master: a flat 100 % line by default")
	ok(bar.inherits() and head.inherits() and not m.inherits(), "fixtures and heads inherit; the master doesn't")
	ok(bar.dimmer_polyline().is_empty() and head.dimmer_polyline().is_empty() and not bar.dimmer_defined_at(5.0),
		"a fixture's / head's dimmer row: no values, nothing drawn, by default")
	ok(not bar.on_line(Vector2(300, bar.row_rect(R.DIMMER).position.y + 4)), "no line to grab or Ctrl+click")
	# Values via the Dimmer submenu: only over the selected stretch.
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["bar|%d" % R.DIMMER]), 4.0, 8.0)])
	tl.apply_dimmer(MusicTimeline.Dim.HALF)
	ok(bar.dimmer_nodes == PackedVector2Array([Vector2(4, 0.5), Vector2(8, 0.5)]), "Half: values over the stretch only (%s)" % str(bar.dimmer_nodes))
	ok(bar.dimmer_defined_at(6.0) and not bar.dimmer_defined_at(3.0) and not bar.dimmer_defined_at(9.0), "defined first node to last")
	var line := bar.dimmer_polyline()
	ok(line.size() == 2 and is_equal_approx(line[0].x, bar._t2x(4.0)) and is_equal_approx(line[1].x, bar._t2x(8.0)),
		"drawn only across that stretch")
	# Effective levels: head -> fixture -> master.
	m.dimmer_nodes = PackedVector2Array([Vector2(0, 0.25)])
	ok(is_equal_approx(tl.effective_dimmer(head, 6.0, false), 0.5) and is_equal_approx(tl.effective_dimmer(head, 2.0, false), 0.25)
		and is_equal_approx(tl.effective_dimmer(bar, 10.0, false), 0.25), "a head inherits its fixture's, which inherits the master's")
	# A pulse on the empty head starts / ends at what it inherits.
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["bar/h0|%d" % R.DIMMER]), 6.0, 10.0)])
	tl.apply_dimmer(MusicTimeline.Dim.PULSE_IN)
	ok(head.dimmer_nodes == PackedVector2Array([Vector2(6, 0.5), Vector2(8, 1.0), Vector2(10, 0.25)]),
		"Pulse In on an empty head: from the fixture's 50 %% to the master's 25 %% (%s)" % str(head.dimmer_nodes))
	# Copying an empty row copies nothing; a partly-defined one, its stretch.
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["bar|%d" % R.DIMMER]), 0.0, 20.0)])
	tl.copy_selection()
	var part: Dictionary = tl.clipboard()["tracks"][0]["rows"][R.DIMMER][0]
	ok(is_equal_approx(part["t0"], 4.0) and is_equal_approx(part["t1"], 8.0), "copying a fixture row: just where it has values")
	head.dimmer_nodes = PackedVector2Array()
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["bar/h0|%d" % R.DIMMER]), 0.0, 20.0)])
	tl.copy_selection()
	ok(not tl.clipboard()["tracks"][0]["rows"][R.DIMMER][0].has("nodes"), "copying an empty row: nothing to paste")
	tl._dirty = false
	tl.queue_free()
	await process_frame
