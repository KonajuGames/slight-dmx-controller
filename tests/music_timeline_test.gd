extends SceneTree
## Tests for the Music Library's track timeline: WaveHeatmap's zoomable
## view, the overview's view rectangle, MusicTimeline loading a track
## through the native extension, and the track list <-> timeline switch.
##
##   godot --headless --script tests/music_timeline_test.gd
##
## Decoding needs the `native` extension; those cases SKIP without it.
## A synthetic WAV is the portable track; real M4A files from this
## machine's library are a bonus check of the OS (AAC) decoder.

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


func skip(label: String) -> void:
	_s += 1
	print("  skip ", label)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== Music timeline ==")
	_test_wave_view()
	_test_view_box()
	await _test_timeline()
	await _test_browser_switch()
	print("== %d passed, %d failed, %d skipped ==" % [_p, _f, _s])
	quit(1 if _f > 0 else 0)


func _analysis(duration: float, cols: int) -> SongAnalysis:
	var a := SongAnalysis.new()
	a.duration = duration
	for arr in [a.wave_lo, a.wave_mid, a.wave_hi, a.wave_peak]:
		arr.resize(cols)
	for i in range(cols):
		a.wave_peak[i] = 0.5 + 0.5 * sin(i * 0.05)
		a.wave_lo[i] = 0.6
		a.wave_mid[i] = 0.3
		a.wave_hi[i] = 0.1
	return a


func _wheel(w: WaveHeatmap, button: int, x: float, shift := false) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = true
	e.position = Vector2(x, 10)
	e.shift_pressed = shift
	w._gui_input(e)


func _test_wave_view() -> void:
	print("- zoomable waveform")
	var w := WaveHeatmap.new()
	w.zoomable = true
	root.add_child(w)
	w.size = Vector2(1000, 180)
	w.set_analysis(_analysis(100.0, 10000))
	ok(w.visible_length() == 100.0 and w.view_start == 0.0, "starts showing the whole track")
	ok(w._levels.size() > 5 and w._levels[-1]["peak"].size() <= 64, "resolution pyramid (%d levels)" % w._levels.size())

	var changes := []
	w.view_changed.connect(func(s, l): changes.append([s, l]))
	w.set_view(10.0, 20.0)
	ok(w.view_start == 10.0 and w.visible_length() == 20.0 and changes.size() == 1, "set_view + view_changed")
	ok(is_equal_approx(w.time_to_x(20.0), 500.0) and is_equal_approx(w.x_to_time(250.0), 15.0), "time <-> x")

	var t_under := w.x_to_time(250.0)
	_wheel(w, MOUSE_BUTTON_WHEEL_UP, 250.0)
	ok(is_equal_approx(w.visible_length(), 16.0), "wheel up zooms in by 1.25 (%.2f s)" % w.visible_length())
	ok(is_equal_approx(w.x_to_time(250.0), t_under), "the time under the pointer stays put")
	_wheel(w, MOUSE_BUTTON_WHEEL_DOWN, 250.0)
	ok(is_equal_approx(w.visible_length(), 20.0), "wheel down zooms back out")
	for i in range(40):
		_wheel(w, MOUSE_BUTTON_WHEEL_UP, 500.0)
	ok(is_equal_approx(w.visible_length(), w.min_view), "zoom in stops at min_view (%.2f s)" % w.visible_length())
	for i in range(40):
		_wheel(w, MOUSE_BUTTON_WHEEL_DOWN, 500.0)
	ok(w.view_len == 0.0 and w.visible_length() == 100.0 and w.view_start == 0.0, "zoom out stops at the whole track")

	w.set_view(50.0, 20.0)
	_wheel(w, MOUSE_BUTTON_WHEEL_DOWN, 500.0, true)
	ok(is_equal_approx(w.view_start, 52.0) and is_equal_approx(w.visible_length(), 20.0), "Shift+wheel scrolls")
	w.set_view(95.0, 20.0)
	ok(w.view_start == 80.0, "view clamped to the end of the track")
	w.set_view(-5.0, 20.0)
	ok(w.view_start == 0.0, "...and the start")

	w.zoomable = false
	w.set_view(0.0, 0.0)
	_wheel(w, MOUSE_BUTTON_WHEEL_UP, 500.0)
	ok(w.visible_length() == 100.0, "not zoomable: wheel ignored (the Auto Show panel)")
	w.queue_free()


func _press(box: Control, x: float, pressed := true) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = Vector2(x, 10)
	box._gui_input(e)


func _move(box: Control, x: float) -> void:
	var e := InputEventMouseMotion.new()
	e.position = Vector2(x, 10)
	e.button_mask = MOUSE_BUTTON_MASK_LEFT
	box._gui_input(e)


func _test_view_box() -> void:
	print("- overview rectangle")
	var box := MusicTimeline.ViewBox.new()
	root.add_child(box)
	box.size = Vector2(1000, 44)
	box.duration = 100.0
	box.set_view(10.0, 20.0)
	ok(box.box_rect() == Rect2(100, 0, 200, 44), "rectangle = the visible window %s" % str(box.box_rect()))
	var moved := []
	box.view_moved.connect(func(s): moved.append(s))
	_press(box, 150.0)        # inside: grab 5 s into the window
	_move(box, 450.0)         # pointer at 45 s -> window starts at 40
	_press(box, 450.0, false)
	ok(moved.size() == 1 and is_equal_approx(moved[0], 40.0), "dragging moves the window %s" % str(moved))
	_move(box, 600.0)
	ok(moved.size() == 1, "released: motion no longer drags")
	moved.clear()
	_press(box, 800.0)        # outside: centre the window on 80 s
	ok(moved.size() == 1 and is_equal_approx(moved[0], 70.0), "clicking elsewhere jumps there %s" % str(moved))
	_move(box, 700.0)
	ok(moved.size() == 2 and is_equal_approx(moved[1], 60.0), "...and keeps dragging from there")
	_press(box, 700.0, false)
	box.queue_free()


## A WAV with a loud 10 s burst in the middle of 40 s of quiet.
func _synth_wav(path: String) -> String:
	var rate := 22050
	var n := rate * 40
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in range(n):
		var t := float(i) / rate
		var amp := 0.8 if (t >= 15.0 and t < 25.0) else 0.05
		data.encode_s16(i * 2, int(sin(t * TAU * 220.0) * amp * 32767.0))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(36 + data.size())
	f.store_buffer("WAVEfmt ".to_ascii_buffer())
	f.store_32(16)
	f.store_16(1)
	f.store_16(1)
	f.store_32(rate)
	f.store_32(rate * 2)
	f.store_16(2)
	f.store_16(16)
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(data.size())
	f.store_buffer(data)
	f.close()
	return ProjectSettings.globalize_path(path)


func _wait_loaded(tl: MusicTimeline, timeout_ms := 60000) -> bool:
	var t := Time.get_ticks_msec()
	while tl.is_loading() and Time.get_ticks_msec() - t < timeout_ms:
		await process_frame
	await process_frame
	return not tl.is_loading()


func _test_timeline() -> void:
	print("- timeline")
	var tl := MusicTimeline.new()
	root.add_child(tl)
	tl.size = Vector2(1100, 600)
	if not ClassDB.class_exists("SongFeatures"):
		tl.open("C:/nope.mp3")
		ok("native extension" in tl._status.text, "without the extension: says why (%s)" % tl._status.text)
		skip("decoding (native extension not built)")
		tl.queue_free()
		return

	var wav := _synth_wav("user://_timeline_test.wav")
	tl.open(wav)
	ok(tl.is_loading(), "decodes on a worker thread")
	ok(await _wait_loaded(tl), "loads")
	var w := tl.wave()
	ok(w.analysis != null and is_equal_approx(w.analysis.duration, 40.0), "duration %.2f s" % (w.analysis.duration if w.analysis else -1.0))
	ok(w.analysis != null and w.analysis.wave_peak.size() == 4000, "100 columns per second (%d)" % (w.analysis.wave_peak.size() if w.analysis else -1))
	if w.analysis != null:
		var pk := w.analysis.wave_peak
		ok(pk[2000] > 0.9 and pk[500] < 0.15 and pk[3500] < 0.15, "loud burst lands at 15-25 s (%.2f / %.2f / %.2f)" % [pk[500], pk[2000], pk[3500]])
	ok(is_equal_approx(w.view_start, 0.0) and is_equal_approx(w.visible_length(), 30.0), "opens showing the first 30 s")
	var box := tl.overview_box()
	ok(is_equal_approx(box.start, 0.0) and is_equal_approx(box.length, 30.0) and is_equal_approx(box.duration, 40.0),
		"overview rectangle follows")
	w.set_view(5.0, 10.0)
	ok(is_equal_approx(box.start, 5.0) and is_equal_approx(box.length, 10.0), "zooming moves the rectangle")
	box.view_moved.emit(20.0)
	ok(is_equal_approx(w.view_start, 20.0) and is_equal_approx(w.visible_length(), 10.0), "dragging the rectangle scrolls the waveform")
	# Nothing above the waveforms but the (now empty) status line: no
	# title, track info, back button or time range.
	var buttons := tl.find_children("*", "Button", true, false)
	var shown := tl.find_children("*", "Label", true, false).filter(func(l): return l.visible and l.text != "")
	ok(buttons.is_empty() and shown.is_empty(), "no header, buttons or time label (%d buttons, labels %s)" % [
		buttons.size(), str(shown.map(func(l): return l.text))])

	tl.open(wav)
	ok(not tl.is_loading() and tl.wave().analysis != null, "reopening comes from the cache")

	tl.open(ProjectSettings.globalize_path("user://_no_such_track.mp3"))
	ok(not tl.is_loading() and tl._status.text == "File not found.", "missing file")

	var believer := "D:/Music/Imagine Dragons/Evolve/04 Believer.m4a"
	if not FileAccess.file_exists(believer):
		skip("real M4A (Believer) not on this machine")
	elif not SongAnalyzer.os_decoding_available():
		skip("no OS AAC decoder here")
	else:
		var t0 := Time.get_ticks_msec()
		tl.open(believer)
		ok(await _wait_loaded(tl), "M4A loads through the OS decoder")
		var a := tl.wave().analysis
		print("    Believer: %.2f s, %d columns, %d ms" % [a.duration if a else -1.0, a.wave_peak.size() if a else -1, Time.get_ticks_msec() - t0])
		ok(a != null and absf(a.duration - 204.41) < 0.1, "M4A duration matches VirtualDJ's 204.41 s")

	# Leaving mid-decode cancels it.
	var mix := "D:/Music/Compilations/Skitzmix 90's Anthems/01 Skitzmix 90's Anthems (Continuous Mix 1).m4a"
	if FileAccess.file_exists(mix) and SongAnalyzer.os_decoding_available():
		tl.open(mix)
		await process_frame
		var t1 := Time.get_ticks_msec()
		tl.open(wav)   # cached -> cancels the mix decode and returns
		ok(Time.get_ticks_msec() - t1 < 2000 and not tl.is_loading(), "switching track cancels a long decode (%d ms)" % (Time.get_ticks_msec() - t1))
	else:
		skip("long mix not on this machine")
	tl.queue_free()


func _test_browser_switch() -> void:
	print("- track list <-> timeline")
	var panel := MusicBrowserPanel.new()
	root.add_child(panel)
	panel.ensure_loaded()
	var dir := ProjectSettings.globalize_path("user://_timeline_dir")
	DirAccess.make_dir_recursive_absolute(dir)
	_synth_wav("user://_timeline_dir/a.wav")
	panel.show_folder(dir)
	ok(not panel.is_timeline_shown(), "folder shows the track list")
	var first: TreeItem = panel._list.get_root().get_first_child()
	panel._list.set_selected(first, 0)
	panel._list.item_activated.emit()
	ok(panel.is_timeline_shown() and not panel._list_view.visible, "double-click opens the timeline in place of the list")
	ok(panel.timeline().current_path() == dir.path_join("a.wav"), "for that track")
	await _wait_loaded(panel.timeline())

	# Selecting a folder in the tree goes back to the list.
	var tree: Tree = panel._tree
	var item := tree.create_item(tree.get_root())
	item.set_metadata(0, {"kind": "dir", "path": dir})
	tree.set_selected(item, 0)
	ok(not panel.is_timeline_shown() and panel._list_view.visible, "selecting a folder shows the list again")

	panel.open_track(panel.rows()[0])
	ok(panel.is_timeline_shown(), "reopened")
	tree.item_mouse_selected.emit(Vector2.ZERO, MOUSE_BUTTON_LEFT)   # click the already-selected folder
	ok(not panel.is_timeline_shown(), "clicking the already-selected folder also goes back")
	panel.queue_free()
