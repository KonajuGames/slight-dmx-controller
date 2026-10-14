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
	_test_dimmer_segments()
	await _test_copy_paste()
	await _test_undo_redo()
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
	var want := {R.DIMMER: Rect2(0, 0, 800, 80), R.COLOUR: Rect2(0, 80, 800, 10), R.CUES: Rect2(0, 90, 800, 10),
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
		== [R.POSITION, R.STROBE, R.CUES, R.COLOUR, R.DIMMER], "moving head: every row")
	ok(TimelineTrack.rows_for_roles(["DIMMER", "RED", "GREEN", "BLUE"]) == [R.CUES, R.COLOUR, R.DIMMER],
		"RGB par: cues, colour, dimmer")
	ok(TimelineTrack.rows_for_roles(["RED", "GREEN", "BLUE", "WHITE"]) == [R.CUES, R.COLOUR, R.DIMMER],
		"RGBW without a dimmer channel: still a dimmer row (the virtual dimmer)")
	ok(TimelineTrack.rows_for_roles(["COLOR_WHEEL", "GOBO"]) == [R.CUES, R.COLOUR], "colour wheel only: no dimmer row")
	ok(TimelineTrack.rows_for_roles(["DIMMER"]) == [R.CUES, R.DIMMER], "plain dimmer: cues, dimmer")
	var tr := TimelineTrack.new()
	tr.target = TimelineTrack.Target.FIXTURE
	root.add_child(tr)
	tr.rows = [R.DIMMER, R.CUES]      # any order in, stacking order kept
	ok(tr.rows == [R.CUES, R.DIMMER] and tr.custom_minimum_size.y == 90.0, "fewer rows -> shorter track (%.0f)" % tr.custom_minimum_size.y)
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
		and par[0]["rows"] == [R.CUES, R.COLOUR, R.DIMMER], "a single-head fixture: one timeline")
	var bar := MusicTimeline.fixture_track_specs("0/2", "Bar", _bar(), 0)
	ok(bar.size() == 4, "a three-head fixture: its own timeline plus one per head (%d)" % bar.size())
	ok(bar[0]["target"] == T.FIXTURE and bar[0]["rows"] == [R.STROBE, R.CUES, R.COLOUR, R.DIMMER],
		"the fixture's covers all its channels")
	ok(bar[1]["target"] == T.HEAD and bar[1]["title"] == "Bar\nHead 1" and bar[3]["title"] == "Bar\nHead 3",
		"heads titled in order, \"Head N\" on a second line")
	ok(bar[1]["rows"] == [R.CUES, R.COLOUR, R.DIMMER], "a head's rows are its own channels' (no strobe)")
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
	_sel_drag(tl, _at(tl, m, R.CUES, 10.5), _at(tl, m, R.CUES, 11.0))
	ok(sel.blocks.size() == 1 and is_equal_approx(sel.blocks[0]["t0"], 10.0) and is_equal_approx(sel.blocks[0]["t1"], 12.0)
		and sel.blocks[0]["rows"] == PackedStringArray(["master|%d" % R.CUES]), "a new plain drag replaces the selection")
	# Ctrl adds.
	_sel_drag(tl, _at(tl, m, R.STROBE, 14.2), _at(tl, m, R.STROBE, 14.4), true)
	ok(sel.blocks.size() == 2 and sel.has("master", R.CUES, 11.0) and sel.has("master", R.STROBE, 15.0),
		"Ctrl adds to it")
	# Shift: from the last area (strobe, 14–16 s) through the new one.
	_sel_drag(tl, _at(tl, m, R.DIMMER, 18.5), _at(tl, m, R.DIMMER, 18.6), false, true)
	var last: Dictionary = sel.blocks[-1]
	ok(sel.blocks.size() == 2 and is_equal_approx(last["t0"], 14.0) and is_equal_approx(last["t1"], 20.0),
		"Shift extends the last area through the new one in time (14–20 s)")
	ok(last["rows"] == PackedStringArray(["master|%d" % R.DIMMER, "master|%d" % R.COLOUR, "master|%d" % R.CUES, "master|%d" % R.STROBE]),
		"...and takes in the rows between (%s)" % str(last["rows"]))
	ok(sel.has("master", R.CUES, 11.0), "earlier Ctrl-added areas stay")
	# Across tracks: the fixture's dimmer down to the master's position row.
	_sel_drag(tl, _at(tl, par, R.DIMMER, 4.0), _at(tl, m, R.POSITION, 5.0))
	var rows: PackedStringArray = sel.blocks[0]["rows"]
	ok(sel.blocks.size() == 1 and rows.size() == 3 + 5 and rows[0] == "par|%d" % R.DIMMER
		and rows[2] == "par|%d" % R.CUES and rows[3] == "master|%d" % R.DIMMER and rows[7] == "master|%d" % R.POSITION,
		"dragging across tracks covers every row between, top to bottom (%d rows)" % rows.size())
	ok(par.selection == sel and m.selection == sel, "both tracks draw the same selection")
	# Beat and no snapping.
	sb.snap = StructureBar.Snap.BEAT
	_sel_drag(tl, _at(tl, m, R.CUES, 3.1), _at(tl, m, R.CUES, 3.3))
	ok(is_equal_approx(sel.blocks[0]["t0"], 3.0) and is_equal_approx(sel.blocks[0]["t1"], 3.5), "beat snapping: whole beats")
	sb.snap = StructureBar.Snap.NONE
	_sel_drag(tl, _at(tl, m, R.CUES, 3.1), _at(tl, m, R.CUES, 7.3))
	ok(absf(sel.blocks[0]["t0"] - 3.1) < 0.05 and absf(sel.blocks[0]["t1"] - 7.3) < 0.05,
		"no snapping: exactly where dragged (%.2f–%.2f)" % [sel.blocks[0]["t0"], sel.blocks[0]["t1"]])
	# A plain click (no drag) clears it — with snapping, it selects that cell.
	_press(tl, _at(tl, m, R.CUES, 9.0), true)
	_press(tl, _at(tl, m, R.CUES, 9.0), false)
	ok(sel.is_empty(), "no snapping: a click clears the selection")
	sb.snap = StructureBar.Snap.BAR
	_press(tl, _at(tl, m, R.CUES, 9.0), true)
	_press(tl, _at(tl, m, R.CUES, 9.0), false)
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
		TimelineSelection.block(PackedStringArray(["master|%d" % R.DIMMER, "master|%d" % R.CUES]), 4.0, 8.0),
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
	ok(par.dimmer_nodes.size() == 5 and par.dimmer_at(15.0) == 0.0 and is_equal_approx(par.dimmer_at(5.0), 0.8)
		and is_equal_approx(par.dimmer_at(25.0), 0.8), "the fixture's dimmer too")
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
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["master|%d" % R.DIMMER, "master|%d" % R.CUES]), 4.0, 8.0)])
	_key(KEY_C)
	var clip := tl.clipboard()
	ok(clip.get("length") == 4.0 and clip["tracks"].size() == 1 and clip["tracks"][0]["key"] == "master"
		and clip["tracks"][0]["rows"].has(R.DIMMER) and clip["tracks"][0]["rows"].has(R.CUES), "Ctrl+C copies the selected rows")
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
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["p1|%d" % R.COLOUR, "p1|%d" % R.CUES, "p2|%d" % R.DIMMER]), 30.0, 31.0)])
	_key(KEY_V)
	ok(is_equal_approx(p1.dimmer_at(32.0), 1.0) and is_equal_approx(p2.dimmer_at(32.0), 1.0)
		and p1._dimmer_after(30.0) == 0.0 and p1.dimmer_at(29.0) == 1.0, "one copied track pastes into every selected track")
	ok(sel.blocks.size() == 4, "each gets its dimmer and cues rows selected")
	# Nothing selected: at the playhead, back into the source track.
	sel.clear()
	tl.wave().song_pos = 40.0
	_key(KEY_V)
	ok(is_equal_approx(m.dimmer_at(42.0), 1.0) and m.dimmer_at(40.0) == 0.0, "nothing selected: at the playhead, into the source track")
	# Two copied tracks pair off with the selected tracks.
	p1.dimmer_nodes = PackedVector2Array([Vector2(0, 0.3)])
	p2.dimmer_nodes = PackedVector2Array([Vector2(0, 0.7)])
	sel.set_blocks([TimelineSelection.block(PackedStringArray(["p1|%d" % R.DIMMER, "p1|%d" % R.CUES, "p2|%d" % R.DIMMER]), 0.0, 2.0)])
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
	ok(m.dimmer_nodes.is_empty() and not tl.can_undo(), "again: back to how the song opened")
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
	tl.selection().set_blocks([TimelineSelection.block(PackedStringArray(["master|%d" % R.CUES]), 1.0, 2.0)])
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
