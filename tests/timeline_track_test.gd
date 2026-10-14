extends SceneTree
## Tests for TimelineTrack — a lighting timeline (master / fixture / head)
## in the Music Library's track timeline — and the master track's place
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
