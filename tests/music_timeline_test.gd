extends SceneTree
## Tests for DJ Edit Mode's track timeline: WaveHeatmap's zoomable
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
	_test_grid_lines()
	await _test_ruler()
	_test_apply_vdj_grid()
	_test_structure_snapping()
	await _test_structure()
	await _test_layout()
	await _test_timeline()
	await _test_playback()
	await _test_beat_grid_real()
	await _test_browser_switch()
	await _test_middle_pan()
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
	ok(w.visible_length() == 100.0, "not zoomable: wheel ignored")
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
	ok(tl.overview().progress >= 0.0, "the whole-track waveform's background shows the progress")
	ok(tl.find_children("*", "ProgressBar", true, false).is_empty(), "no separate progress bar")
	ok(await _wait_loaded(tl), "loads")
	ok(tl.overview().progress < 0.0, "progress cleared once loaded")
	var w := tl.wave()
	ok(w.analysis != null and is_equal_approx(w.analysis.duration, 40.0), "duration %.2f s" % (w.analysis.duration if w.analysis else -1.0))
	ok(w.analysis != null and w.analysis.wave_peak.size() == 4000, "100 columns per second (%d)" % (w.analysis.wave_peak.size() if w.analysis else -1))
	if w.analysis != null:
		var pk := w.analysis.wave_peak
		ok(pk[2000] > 0.9 and pk[500] < 0.15 and pk[3500] < 0.15, "loud burst lands at 15-25 s (%.2f / %.2f / %.2f)" % [pk[500], pk[2000], pk[3500]])
	ok(is_equal_approx(w.view_start, 0.0) and is_equal_approx(w.visible_length(), 40.0), "opens fully zoomed out (the whole 40 s)")
	var box := tl.overview_box()
	ok(is_equal_approx(box.start, 0.0) and is_equal_approx(box.length, 40.0) and is_equal_approx(box.duration, 40.0),
		"overview rectangle follows (the whole track)")
	w.set_view(5.0, 10.0)
	ok(is_equal_approx(box.start, 5.0) and is_equal_approx(box.length, 10.0), "zooming moves the rectangle")
	box.view_moved.emit(20.0)
	ok(is_equal_approx(w.view_start, 20.0) and is_equal_approx(w.visible_length(), 10.0), "dragging the rectangle scrolls the waveform")
	# Nothing above the waveforms but the (now empty) status line: no
	# title, track info, back button or time range — the only buttons are
	# the two transport buttons.
	var buttons := tl.find_children("*", "Button", true, false)
	# (Bar the fixture panel's "No fixtures patched.")
	var fx_panel := tl.fixture_scroll()
	var shown := tl.find_children("*", "Label", true, false).filter(
		func(l): return l.visible and l.text != "" and not fx_panel.is_ancestor_of(l))
	ok(buttons.size() == 4 and tl.play_button() in buttons and tl.reset_button() in buttons
		and tl.lock_button() in buttons and tl.generate_button() in buttons and shown.is_empty(),
		"no header or time label; only the transport and structure buttons (%d buttons, labels %s)" % [
		buttons.size(), str(shown.map(func(l): return l.text))])

	w.set_view(12.0, 6.0)                       # zoomed in, then the song opened again
	tl.open(wav)
	ok(not tl.is_loading() and tl.wave().analysis != null, "reopening comes from the cache")
	ok(tl.wave().view_start == 0.0 and is_equal_approx(tl.wave().visible_length(), 40.0), "...fully zoomed out again")

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
		ok(a != null and absf(a.duration - 9011622.0 / 44100.0) < 0.001, "M4A duration: encoder priming / padding trimmed (%.3f s)" % (a.duration if a else -1.0))

	# Leaving mid-decode cancels it.
	var mix := "D:/Music/Compilations/Skitzmix 90's Anthems/01 Skitzmix 90's Anthems (Continuous Mix 1).m4a"
	if FileAccess.file_exists(mix) and SongAnalyzer.os_decoding_available():
		tl.open(mix)
		await process_frame
		var t1 := Time.get_ticks_msec()
		tl.open(wav)   # cached -> cancels the mix decode and returns
		ok(Time.get_ticks_msec() - t1 < 2000 and not tl.is_loading(), "switching track cancels a long decode (%d ms)" % (Time.get_ticks_msec() - t1))
		ok(tl.overview().progress < 0.0, "...and clears its progress")
	else:
		skip("long mix not on this machine")
	tl.queue_free()


func _test_grid_lines() -> void:
	print("- beat grid lines")
	var w := WaveHeatmap.new()
	root.add_child(w)
	w.size = Vector2(1000, 180)
	w.set_analysis(_analysis(100.0, 10000))
	var beats := PackedFloat32Array()
	for i in range(200):
		beats.append(0.25 + i * 0.5)              # 120 BPM from 0.25 s
	w.set_beat_grid(beats, 4, 2)                  # bars start at beats 2, 6, 10, ...
	w.set_view(0.0, 10.0)                         # 100 px per second: beats 50 px apart
	var lines := w.grid_lines(0.0, 10.0)
	ok(lines.size() == 20, "every beat drawn when far apart (%d)" % lines.size())
	var bars := lines.filter(func(l): return l[1]).map(func(l): return roundi(l[0]))
	ok(bars == [125, 325, 525, 725, 925], "bars every 4 beats from the phase beat %s" % str(bars))
	w.set_view(0.0, 100.0)                        # 10 px per s: beats 5 px apart -> still drawn
	ok(w.grid_lines(0.0, 100.0).size() == 200, "beats kept down to 5 px apart")
	w.set_view(0.0, 0.0)
	w.size = Vector2(500, 180)                    # 5 px per s: beats 2.5 px, bars 10 px
	var far := w.grid_lines(0.0, 100.0)
	ok(far.size() == 50 and far.all(func(l): return l[1]), "zoomed out: bars only (%d)" % far.size())
	w.size = Vector2(100, 180)                    # bars 2 px apart
	ok(w.grid_lines(0.0, 100.0).is_empty(), "zoomed right out: no grid")
	w.set_beat_grid(PackedFloat32Array())
	ok(w.grid_lines(0.0, 100.0).is_empty(), "cleared")
	w.queue_free()


func _ruler_event(r: Control, x: float, pressed = null) -> void:
	var e: InputEvent
	if pressed == null:
		e = InputEventMouseMotion.new()
		e.button_mask = MOUSE_BUTTON_MASK_LEFT
	else:
		e = InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
	e.position = Vector2(x, 9)
	r._gui_input(e)


func _test_ruler() -> void:
	print("- bar ruler")
	var tl := MusicTimeline.new()
	root.add_child(tl)
	tl.size = Vector2(1100, 600)
	var song := VirtualDjDatabase.Song.new()
	song.scan_bpm = 120.0           # 0.5 s beats, 2 s bars
	song.phase = 0.25               # bar 1 starts at 0.25 s
	song.length = 40.0
	var wav := _synth_wav("user://_ruler.wav")
	# The WAV plays without the native extension; give it a synthetic
	# waveform when the extension isn't there to decode one.
	tl.open(wav, song)
	await _wait_loaded(tl)
	if tl.wave().analysis == null:
		tl._set_analysis(_analysis(40.0, 4000))
	await process_frame
	var r := tl.ruler()
	var w := tl.wave()
	var rr := r.get_global_rect()
	var wr := w.get_global_rect()
	ok(is_equal_approx(rr.end.y, wr.position.y) and is_equal_approx(rr.position.x, wr.position.x)
		and is_equal_approx(rr.size.x, wr.size.x), "a strip right on top of the waveform, as wide")
	ok(rr.size.y >= 14.0 and rr.size.y <= 24.0, "small (%.0f px tall)" % rr.size.y)

	w.set_view(0.0, 10.0)
	var labels := r.bar_labels()
	var nums := labels.map(func(l): return l[1])
	ok(nums == [1, 2, 3, 4, 5], "bars numbered from 1 %s" % str(nums))
	ok(labels.all(func(l): return absf(l[0] - w.time_to_x(0.25 + (l[1] - 1) * 2.0)) < 0.5), "each at its bar's start")
	var ticks := r.ticks()
	ok(ticks.size() == 20 and ticks.filter(func(t): return t[1]).size() == 5, "a tick per beat, bars marked (%d ticks)" % ticks.size())
	ok(ticks == w.grid_lines(0.0, 10.0), "ticks are exactly the waveform's grid lines")
	w.set_view(20.0, 10.0)
	ok(r.bar_labels().map(func(l): return l[1]) == [11, 12, 13, 14, 15], "numbering carries on through the track")
	w.set_view(0.0, 0.0)            # whole 40 s: beats ~13 px apart, still marked
	ok(r.ticks().any(func(t): return not t[1]), "beats still marked while they're readable")
	# Zoomed right out (a 400 s view): 2 s bars ~5 px apart, so only every
	# Nth bar is numbered — N a power of two, numbers >= LABEL_GAP apart.
	w.min_view = 2.0
	tl._set_analysis(_analysis(400.0, 40000))
	w.set_view(0.0, 0.0)
	var far := r.bar_labels()
	var step: int = far[1][1] - far[0][1] if far.size() > 1 else 0
	var pow2 := step > 1 and (step & (step - 1)) == 0
	var spaced := true
	for i in range(1, far.size()):
		spaced = spaced and far[i][1] - far[i - 1][1] == step and far[i][0] - far[i - 1][0] >= MusicTimeline.BarRuler.LABEL_GAP - 0.5
	ok(far[0][1] == 1 and pow2 and spaced, "zoomed out: every %dth bar numbered, %d labels" % [step, far.size()])
	var far_ticks := r.ticks()
	ok(not far_ticks.is_empty() and far_ticks.all(func(t): return t[1]), "...beats too close to read: bar ticks only")
	tl._set_analysis(_analysis(40.0, 4000))

	# Bars before VirtualDJ's first beat aren't numbered.
	song.phase = 4.25               # first beat later: beats from 0.25 s, bar 1 at 4.25 s
	tl._song = song
	tl._apply_beat_grid(40.0)
	w.set_view(0.0, 10.0)
	nums = r.bar_labels().map(func(l): return l[1])
	ok(nums == [1, 2, 3], "nothing before the first beat %s" % str(nums))

	# Click sets the playhead; drag moves it; the audio follows on release.
	w.set_view(0.0, 10.0)
	_ruler_event(r, w.time_to_x(3.0), true)
	_ruler_event(r, w.time_to_x(3.0), false)
	ok(absf(tl.playback_position() - 3.0) < 0.01 and absf(w.song_pos - 3.0) < 0.01, "click on the ruler sets the playhead (%.2f)" % tl.playback_position())
	var mt := tl.master_track()
	ok(mt._playhead != null and absf(mt.playhead_x() - mt._t2x(3.0)) < 0.5 and mt.playhead_x() > 0.0,
		"the playhead runs down the timelines too (x %.1f)" % mt.playhead_x())
	tl.fixtures_provider = func(): return [{"key": "par", "name": "Par", "mode": 0,
		"profile": FixtureProfile.new("p", "P", [{"name": "Dimmer", "role": "DIMMER"}])}]
	tl.refresh_fixtures()
	await process_frame
	var ft: Array = tl.fixture_tracks()
	ok(ft.size() == 1 and absf(ft[0].playhead_x() - ft[0]._t2x(3.0)) < 0.5, "...on the fixtures' timelines as well")
	tl.fixtures_provider = Callable()
	tl.refresh_fixtures()
	# Dragging the line on a timeline scrubs, as on the ruler.
	var cy := mt.row_rect(TimelineTrack.Row.COLOUR).get_center().y
	var on_line := Vector2(mt.playhead_x() + 2.0, cy)
	var mv := InputEventMouseMotion.new()
	mv.position = on_line
	mt._gui_input(mv)
	ok(mt.mouse_default_cursor_shape == Control.CURSOR_HSIZE, "over the playhead line: left-right arrows")
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = on_line
	mt._gui_input(press)
	mv = InputEventMouseMotion.new()
	mv.position = Vector2(mt._t2x(5.0), cy)
	mt._gui_input(mv)
	ok(tl.is_scrubbing() and absf(w.song_pos - 5.0) < 0.01 and absf(mt.playhead_x() - mt._t2x(5.0)) < 0.5,
		"dragging it on a timeline moves the playhead (%.2f)" % w.song_pos)
	var rel := InputEventMouseButton.new()
	rel.button_index = MOUSE_BUTTON_LEFT
	rel.pressed = false
	rel.position = mv.position
	mt._gui_input(rel)
	ok(not tl.is_scrubbing() and absf(tl.playback_position() - 5.0) < 0.01 and tl.selection().is_empty(),
		"released: the playhead's there, and nothing was selected")
	press.position = Vector2(mt._t2x(5.0) + 20.0, cy)
	mt._gui_input(press)
	ok(mt._selecting and not tl.is_scrubbing(), "a press beside the line still selects")
	rel.position = Vector2(mt._t2x(7.0), cy)
	mt._gui_input(rel)
	tl.selection().clear()
	tl.seek(3.0)
	w.set_view(20.0, 10.0)
	ok(mt.playhead_x() < 0.0, "not drawn when it's out of view")
	w.set_view(0.0, 10.0)
	tl.play()
	await _wait(300)
	var playing_at := tl.playback_position()
	_ruler_event(r, w.time_to_x(5.0), true)
	_ruler_event(r, w.time_to_x(6.5))
	_ruler_event(r, w.time_to_x(7.0))
	await process_frame
	ok(tl.is_scrubbing() and absf(w.song_pos - 7.0) < 0.01, "dragging moves the playhead line (%.2f)" % w.song_pos)
	ok(tl.is_playing() and absf(tl._player.get_playback_position() - playing_at) < 0.3,
		"...while the audio plays on where it was")
	_ruler_event(r, w.time_to_x(7.0), false)
	ok(not tl.is_scrubbing() and absf(tl.playback_position() - 7.0) < 0.1, "release: playback jumps there (%.2f)" % tl.playback_position())
	await _wait(300)
	ok(tl.playback_position() > 7.1, "and carries on playing from there (%.2f)" % tl.playback_position())
	tl.pause()

	# The same on the waveform itself.
	w.seek_requested.emit(2.0)
	w.seek_dragged.emit(4.5)
	ok(absf(w.song_pos - 4.5) < 0.01, "dragging on the waveform moves it too")
	w.seek_released.emit(4.5)
	ok(absf(tl.playback_position() - 4.5) < 0.01, "...and sets it on release")
	tl.queue_free()


func _test_apply_vdj_grid() -> void:
	print("- VirtualDJ grid on an analysed structure")
	var a := SongAnalysis.new()
	a.duration = 40.0
	a.bpm = 117.0
	a.sections = [
		{"start": 0.0, "end": 8.3, "label": "Intro", "energy": 0.2, "cluster": 0},
		{"start": 8.3, "end": 8.6, "label": "Build", "energy": 0.5, "cluster": 1},
		{"start": 8.6, "end": 24.9, "label": "Chorus", "energy": 0.9, "cluster": 2},
		{"start": 24.9, "end": 40.0, "label": "Outro", "energy": 0.3, "cluster": 3},
	]
	var song := VirtualDjDatabase.Song.new()
	song.scan_bpm = 120.0           # 0.5 s beats, 2 s bars from 0.25 s
	song.phase = 0.25
	song.length = 40.0
	MusicTimeline.apply_vdj_grid(a, song)
	ok(a.bpm == 120.0, "tempo from VirtualDJ (%.1f)" % a.bpm)
	ok(a.beat_times.size() == 80 and is_equal_approx(a.beat_times[0], 0.25), "VirtualDJ's beats")
	ok(a.downbeats.size() == 20 and is_equal_approx(a.downbeats[1], 2.25), "bars every 4 beats from its first beat")
	var starts: Array = a.sections.map(func(sec): return snappedf(sec["start"], 0.01))
	ok(starts == [0.0, 8.25, 24.25], "borders snapped to its bars; a section squeezed to nothing dropped %s" % str(starts))
	var contiguous := true
	for i in range(1, a.sections.size()):
		contiguous = contiguous and a.sections[i]["start"] == a.sections[i - 1]["end"]
	ok(contiguous and a.sections[-1]["end"] == 40.0, "still contiguous to the end")


func _drag_border(sb: StructureBar, from_t: float, to_t: float) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(sb._t2x(from_t), 9)
	sb._gui_input(press)
	var move := InputEventMouseMotion.new()
	move.position = Vector2(sb._t2x(to_t), 9)
	sb._gui_input(move)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = move.position
	sb._gui_input(up)


func _test_structure_snapping() -> void:
	print("- structure snapping (right-click > Snapping)")
	var sb := StructureBar.new()
	root.add_child(sb)
	sb.size = Vector2(1000, 18)
	var a := SongAnalysis.new()
	a.duration = 20.0
	for i in range(40):
		a.beat_times.append(0.25 + i * 0.5)          # beats every 0.5 s
		if i % 4 == 0:
			a.downbeats.append(0.25 + i * 0.5)       # bars every 2 s
	a.sections = [
		{"start": 0.0, "end": 8.25, "label": "Verse", "energy": 0.4, "cluster": 0},
		{"start": 8.25, "end": 20.0, "label": "Chorus", "energy": 0.9, "cluster": 1},
	]
	sb.set_analysis(a)
	ok(sb.snap == StructureBar.Snap.BAR, "snaps to bars by default")

	_drag_border(sb, 8.25, 9.1)
	ok(is_equal_approx(a.sections[0]["end"], 8.25), "bar: 9.1 s -> nearest bar 8.25 (%.2f)" % a.sections[0]["end"])
	sb.snap = StructureBar.Snap.BEAT
	_drag_border(sb, 8.25, 9.1)
	ok(is_equal_approx(a.sections[0]["end"], 9.25), "beat: 9.1 s -> nearest beat 9.25 (%.2f)" % a.sections[0]["end"])
	sb.snap = StructureBar.Snap.NONE
	_drag_border(sb, 9.25, 9.1)
	ok(absf(a.sections[0]["end"] - 9.1) < 0.03, "no snapping: stays at 9.1 (%.3f)" % a.sections[0]["end"])
	ok(a.sections[1]["start"] == a.sections[0]["end"], "neighbour follows")

	# Split Here obeys it too.
	sb.snap = StructureBar.Snap.BEAT
	sb._split_segment(1, 13.4)
	ok(a.sections.size() == 3 and is_equal_approx(a.sections[1]["end"], 13.25), "split snaps to the beat (%.2f)" % a.sections[1]["end"])

	# A border dragged right up to the far one: the segment it closed up
	# goes, either side.
	sb.snap = StructureBar.Snap.NONE
	a.sections[1]["label"] = "Build"
	_drag_border(sb, 9.1, 15.0)
	ok(a.sections.size() == 2 and a.sections.map(func(s): return s["label"]) == ["Verse", "Chorus"]
		and is_equal_approx(a.sections[0]["end"], 13.25) and a.sections[1]["start"] == a.sections[0]["end"],
		"dragged to nothing on its right: that segment deleted")
	_drag_border(sb, 13.25, 4.0)
	ok(a.sections.size() == 2 and is_equal_approx(a.sections[1]["start"], 4.0), "a drag that leaves both: both kept")
	_drag_border(sb, 4.0, -1.0)
	ok(a.sections.size() == 1 and a.sections[0]["label"] == "Chorus" and a.sections[0]["start"] == 0.0 and a.sections[0]["end"] == 20.0,
		"dragged to nothing on its left: that one deleted")
	sb.snap = StructureBar.Snap.BEAT

	# The menu: a Snapping submenu with the three choices, current one ticked.
	sb._open_context_menu(0, Vector2(100, 9))
	var p: PopupMenu = sb._popup
	var sub_idx := -1
	for i in range(p.item_count):
		if p.get_item_text(i) == "Snapping":
			sub_idx = i
	ok(sub_idx != -1 and p.get_item_submenu_node(sub_idx) == sb._snap_menu, "right-click menu has a Snapping submenu")
	var m: PopupMenu = sb._snap_menu
	var texts := []
	for i in range(m.item_count):
		texts.append(m.get_item_text(i))
	ok(texts == ["Bar", "Beat", "No Snapping"], "with Bar / Beat / No Snapping %s" % str(texts))
	ok(m.is_item_checked(1) and not m.is_item_checked(0) and not m.is_item_checked(2), "the current one (Beat) ticked")
	p.hide()
	m.id_pressed.emit(2)
	ok(sb.snap == StructureBar.Snap.NONE, "choosing one switches to it")
	m.id_pressed.emit(0)
	ok(sb.snap == StructureBar.Snap.BAR, "...and back to Bar")
	sb.queue_free()


func _test_structure() -> void:
	print("- song structure bar")
	if not ClassDB.class_exists("SongFeatures"):
		skip("song structure (native extension not built)")
		return
	var tl := MusicTimeline.new()
	root.add_child(tl)
	tl.size = Vector2(1100, 600)
	var song := VirtualDjDatabase.Song.new()
	song.scan_bpm = 120.0
	song.phase = 0.25
	song.length = 40.0
	var wav := _synth_wav("user://_structure.wav")
	tl.open(wav, song)
	var lock := tl.lock_button()
	var gen := tl.generate_button()
	ok(tl.structure() == null and lock.disabled and gen.disabled, "while analysing: no structure, buttons disabled")
	ok("analysing" in tl.structure_bar().placeholder, "...and it says so")
	var t := Time.get_ticks_msec()
	while tl.structure() == null and Time.get_ticks_msec() - t < 20000:
		await process_frame
	await process_frame
	var a := tl.structure()
	ok(a != null and not a.sections.is_empty(), "analysed: %d sections" % (a.sections.size() if a else 0))
	if a == null:
		tl.queue_free()
		return
	ok(not lock.disabled and not gen.disabled, "buttons enabled")
	ok(a.bpm == 120.0 and a.downbeats.size() > 0 and is_equal_approx(a.downbeats[1], 2.25), "VirtualDJ's grid swapped in")
	var on_bars := a.sections.slice(1).all(func(sec): return a.downbeats.has(sec["start"]))
	ok(on_bars, "section borders on VirtualDJ's bars")

	# Layout: above the ruler, as tall; the small squares beside it.
	var sb := tl.structure_bar()
	var sr := sb.get_global_rect()
	var rr := tl.ruler().get_global_rect()
	ok(is_equal_approx(sr.end.y, rr.position.y) and is_equal_approx(sr.size.y, rr.size.y)
		and is_equal_approx(sr.position.x, rr.position.x) and is_equal_approx(sr.size.x, rr.size.x),
		"structure bar right above the ruler, same height and width")
	var lr := lock.get_global_rect()
	var gr := gen.get_global_rect()
	ok(lr.size == Vector2(sr.size.y, sr.size.y) and gr.size == lr.size, "two squares as tall as the bar (%s)" % lr.size)
	ok(is_equal_approx(lr.position.y, sr.position.y) and is_equal_approx(gr.position.y, sr.position.y)
		and lr.position.x >= sr.end.x and gr.position.x > lr.end.x, "side by side to its right, level with it")
	ok(gr.end.x <= tl.play_button().get_global_rect().end.x + 0.5, "...within the transport column")

	# Zoom follows the waveform.
	tl.wave().set_view(10.0, 8.0)
	ok(sb.view_start == 10.0 and sb.view_len == 8.0, "follows the waveform's zoom")

	# Lock.
	ok(tl.is_structure_locked() and not sb.editable and lock.glyph == MusicTimeline.TransportButton.Glyph.LOCKED,
		"starts locked")
	lock.pressed.emit()
	ok(not tl.is_structure_locked() and sb.editable and lock.glyph == MusicTimeline.TransportButton.Glyph.UNLOCKED,
		"lock button unlocks editing")
	lock.pressed.emit()
	ok(tl.is_structure_locked() and not sb.editable, "...and locks it again")

	# Locked: clicking the bar seeks; it can't drag a border.
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.position = Vector2(sb._t2x(13.0), 9)
	sb._gui_input(e)
	ok(absf(tl.playback_position() - 13.0) < 0.05, "clicking it sets the playhead (%.2f)" % tl.playback_position())
	ok(sb._drag_border == -1, "locked: no border dragging")

	# Unlocked: drag a border on the zoomed bar; it snaps to a bar.
	lock.pressed.emit()
	var b_end: float = a.sections[0]["end"]
	tl.wave().set_view(maxf(b_end - 6.0, 0.0), 12.0)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(sb._t2x(b_end), 9)
	sb._gui_input(press)
	var move := InputEventMouseMotion.new()
	move.position = Vector2(sb._t2x(b_end + 2.1), 9)
	sb._gui_input(move)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = move.position
	sb._gui_input(up)
	var new_end: float = a.sections[0]["end"]
	ok(absf(new_end - (b_end + 2.0)) < 0.01 and a.downbeats.has(new_end) and a.sections[1]["start"] == new_end,
		"unlocked: dragging a border on the zoomed bar moves it a bar along (%.2f -> %.2f)" % [b_end, new_end])
	lock.pressed.emit()

	# Generate: a show into the timelines (TimelineGenerator's own tests
	# cover what goes in).
	tl.master_track().dimmer_nodes = PackedVector2Array()
	gen.pressed.emit()
	ok(tl.master_track().dimmer_nodes.size() > 2 and not tl.master_track().colour_segments.is_empty(),
		"generate fills the timelines from this structure")
	ok(tl.master_track().movement_segments.is_empty(), "no position library: no movement")
	var first_show := str(tl.master_track().colour_segments)
	gen.pressed.emit()
	ok(str(tl.master_track().colour_segments) != first_show, "pressing it again: another variation")
	ok(tl.has_unsaved_timelines() and tl.can_undo(), "as an edit that can be undone")
	var lib := PositionLibrary.new()
	tl.positions = lib
	gen.pressed.emit()
	ok(lib.positions.size() == 1 and lib.positions[0]["name"] == "Centre" and lib.positions[0]["points"].is_empty(),
		"no named positions: a \"Centre\" one is made (every fixture centred)")
	var mpos: Array = tl.master_track().position_segments
	ok(not mpos.is_empty() and mpos.all(func(p): return p["pos"] == lib.positions[0]["id"])
		and not tl.master_track().movement_segments.is_empty(), "...and the show moves around it")
	lib.add()
	gen.pressed.emit()
	ok(lib.positions.size() == 2, "with positions already: none added")
	tl.positions = null
	# A fixture left out of generation has its timelines cleared (its
	# heads' too).
	var rgb := FixtureProfile.new("bar", "Bar", [{"name": "R", "role": "RED"}, {"name": "G", "role": "GREEN"},
		{"name": "B", "role": "BLUE"}, {"name": "R", "role": "RED"}, {"name": "G", "role": "GREEN"}, {"name": "B", "role": "BLUE"}])
	tl.fixtures_provider = func(): return [
		{"key": "in", "name": "In", "mode": 0, "profile": rgb},
		{"key": "out", "name": "Out", "mode": 0, "profile": rgb, "exclude_generate": true}]
	tl.refresh_fixtures()
	var marker := PackedVector2Array([Vector2(1.0, 0.123), Vector2(2.0, 0.123)])
	var red := [{"t0": 0.0, "t1": 5.0, "c0": Color.RED, "c1": Color.RED}]
	for tr in tl.fixture_tracks():
		tr.dimmer_nodes = marker
		tr.colour_segments = red.duplicate(true)
	tl._mark_dirty()                                  # as an edit by hand records it
	gen.pressed.emit()
	var kept := {}
	var cleared := {}
	for tr in tl.fixture_tracks():
		kept[String(tr.get_meta("key"))] = tr.dimmer_nodes == marker
		cleared[String(tr.get_meta("key"))] = tr.dimmer_nodes.is_empty() and tr.colour_segments.is_empty() \
			and tr.strobe_segments.is_empty() and tr.position_segments.is_empty() and tr.movement_segments.is_empty()
	ok(kept.size() == 6 and cleared["out"] and cleared["out/h0"] and cleared["out/h1"],
		"a fixture left out of generation has its old timelines cleared, its heads' too")
	ok(not kept["in"] and not kept["in/h0"] and not kept["in/h1"], "...the others are generated")
	tl.undo()
	var back := tl.fixture_tracks().all(func(tr): return tr.dimmer_nodes == marker and tr.colour_segments.size() == 1)
	ok(back, "...and one undo brings them all back")
	tl.fixtures_provider = Callable()
	tl.refresh_fixtures()

	# Cached per track, edits included.
	a.sections[0]["label"] = "Bridge"
	tl.structure_bar().structure_edited.emit()      # as the bar does for any edit
	tl.open(wav, song)
	ok(tl.structure() == a and a.sections[0]["label"] == "Bridge", "reopening keeps the (edited) structure")

	# Another song: the structure's locked again (the same one: left as it is).
	lock.pressed.emit()
	tl.open(wav, song)
	ok(not tl.is_structure_locked(), "reopening the same song leaves it unlocked")
	tl.open("user://_another_song.wav")
	ok(tl.is_structure_locked() and not sb.editable and lock.glyph == MusicTimeline.TransportButton.Glyph.LOCKED,
		"opening another song locks it again")
	tl.queue_free()


func _test_layout() -> void:
	print("- waveform layout")
	var tl := MusicTimeline.new()
	root.add_child(tl)
	tl.position = Vector2.ZERO
	tl.size = Vector2(1100, 600)
	await process_frame
	await process_frame
	var w := tl.wave()
	var wr := w.get_global_rect()
	ok(is_equal_approx(wr.size.y, 90.0), "waveform 90 px tall")
	ok(is_equal_approx(wr.end.y, tl.overview().get_global_rect().position.y - 6.0), "sitting on the overview at the bottom")
	# No resize strip any more: nothing with a vertical-resize cursor.
	var resizers := tl.find_children("*", "Control", true, false).filter(
		func(c): return c.mouse_default_cursor_shape == Control.CURSOR_VSIZE)
	ok(resizers.is_empty(), "no resize strip above it")
	ok(is_equal_approx(tl.structure_bar().get_global_rect().position.y + 36.0, wr.position.y),
		"structure bar and ruler directly above it")
	ok(tl.play_button().size == Vector2(48, 48) and tl.reset_button().size == Vector2(48, 48)
		and is_equal_approx(tl.play_button().get_global_rect().end.y, wr.end.y),
		"transport buttons 48 px squares at its bottom")
	tl.queue_free()


func _key_space() -> InputEventKey:
	var k := InputEventKey.new()
	k.keycode = KEY_SPACE
	k.pressed = true
	return k


func _wait(ms: int) -> void:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < ms:
		await process_frame


func _test_playback() -> void:
	print("- playback")
	if not ClassDB.class_exists("SongFeatures"):
		skip("playback (native extension not built)")
		return
	var tl := MusicTimeline.new()
	root.add_child(tl)
	tl.size = Vector2(1100, 600)
	var wav := _synth_wav("user://_timeline_play.wav")
	var song := VirtualDjDatabase.Song.new()
	song.scan_bpm = 120.0
	song.phase = 0.25
	song.length = 40.0
	tl.open(wav, song)
	await _wait_loaded(tl)
	await process_frame
	var w := tl.wave()
	var play := tl.play_button()
	var reset := tl.reset_button()

	# Layout: the buttons stacked to the right of the waveform.
	var wr := w.get_global_rect()
	var pr := play.get_global_rect()
	var rr := reset.get_global_rect()
	ok(rr.position.x >= wr.end.x and pr.position.x >= wr.end.x, "buttons to the right of the waveform")
	ok(rr.end.y <= pr.position.y + 0.5 and is_equal_approx(rr.position.x, pr.position.x), "reset above play, stacked")
	ok(pr.size == Vector2(48, 48) and rr.size == Vector2(48, 48), "both square (%s, %s)" % [pr.size, rr.size])
	ok(is_equal_approx(pr.end.y, wr.end.y) and is_equal_approx(pr.position.y - rr.end.y, 6.0),
		"aligned to the waveform's bottom, Play / Pause lowest, 6 px apart")
	ok(rr.position.y >= tl.ruler().get_global_rect().position.y - 0.5, "...fitting beside the default waveform + bar ruler")
	ok(is_equal_approx(tl.overview().get_global_rect().size.x, wr.size.x), "overview lined up under the waveform")

	# Subwindows (tooltips, dialogs) must stay embedded: as native windows
	# each tooltip stalled the app ~140 ms on opening — during playback the
	# playhead visibly jumped (and DMX output hiccuped).
	ok(ProjectSettings.get_setting("display/window/subwindows/embed_subwindows") == true,
		"project embeds subwindows (native tooltips stall the app)")
	ok(tl.can_play() and not play.disabled and not reset.disabled, "a WAV is playable at once")
	ok(play.glyph == MusicTimeline.TransportButton.Glyph.PLAY, "shows Play")
	ok(w.show_cursor and w.cursor_color == MusicTimeline.PLAYHEAD_COLOR and tl.overview().show_cursor,
		"red playhead on both waveforms")
	ok(w.song_pos == 0.0, "playhead at the start")

	# Beat grid from the VirtualDJ entry: 120 BPM from 0.25 s.
	ok(w.grid_beats.size() == 80 and is_equal_approx(w.grid_beats[0], 0.25) and w.bar_phase == 0,
		"beat grid from VirtualDJ (%d beats)" % w.grid_beats.size())

	play.pressed.emit()
	ok(tl.is_playing() and play.glyph == MusicTimeline.TransportButton.Glyph.PAUSE, "Play -> playing, shows Pause")
	await _wait(600)
	var p1 := tl.playback_position()
	ok(p1 > 0.3 and p1 < 1.0 and absf(w.song_pos - p1) < 0.1,
		"position advances, playhead follows (%.2f s)" % p1)
	# Pause between frames: the line must stay exactly where the last frame
	# drew it (a fresh read of the audio clock would land later).
	OS.delay_msec(12)
	var drawn := w.song_pos
	play.pressed.emit()
	ok(w.song_pos == drawn and tl.overview().song_pos == drawn,
		"pausing leaves the playhead exactly where it was drawn (%.4f -> %.4f)" % [drawn, w.song_pos])
	var held := tl.playback_position()
	await _wait(300)
	ok(not tl.is_playing() and is_equal_approx(tl.playback_position(), held) and play.glyph == MusicTimeline.TransportButton.Glyph.PLAY,
		"Pause holds the position (%.2f s)" % held)
	play.pressed.emit()
	await _wait(200)
	ok(tl.playback_position() > held, "Play resumes from there")

	w.set_view(10.0, 10.0)
	reset.pressed.emit()
	ok(tl.playback_position() < 0.2 and tl.is_playing() and w.view_start == 0.0, "Back to start: position 0, still playing, view scrolled back")

	w.seek_requested.emit(12.0)
	w.seek_released.emit(12.0)
	ok(absf(tl.playback_position() - 12.0) < 0.2, "clicking the waveform moves the playhead")

	# Paging: playhead running off the right edge scrolls the view.
	w.set_view(5.0, 8.0)
	tl.seek(12.8)
	await _wait(500)
	ok(w.view_start > 12.5 and w.view_start < 13.5, "view pages along with the playhead (now %.2f s)" % w.view_start)

	tl.pause()
	root.push_input(_key_space())   # not handled by anything else here
	await process_frame
	ok(tl.is_playing(), "Space plays")
	tl._unhandled_key_input(_key_space())
	ok(not tl.is_playing(), "Space pauses")

	# Playing to the end.
	tl.seek(39.6)
	tl.play()
	await _wait(1200)
	ok(not tl.is_playing() and play.glyph == MusicTimeline.TransportButton.Glyph.PLAY, "stops at the end")
	ok(tl.playback_position() == 0.0 and w.song_pos == 0.0 and w.view_start == 0.0,
		"...the playhead back at the start, in view (%.2f)" % tl.playback_position())
	tl.play()
	ok(tl.is_playing() and tl.playback_position() < 0.5, "Play after the end starts over")
	tl.pause()

	# Hiding the timeline pauses it.
	tl.play()
	tl.visible = false
	ok(not tl.is_playing(), "hiding the view pauses")
	tl.visible = true

	# A track VirtualDJ doesn't know has no grid; a missing file can't play.
	tl.open(wav, null)
	ok(w.grid_beats.is_empty(), "no VirtualDJ entry -> no grid")
	tl.open(ProjectSettings.globalize_path("user://_no_such_track.mp3"))
	ok(not tl.can_play() and play.disabled and reset.disabled and not w.show_cursor, "missing file: transport disabled")
	tl.queue_free()


func _test_beat_grid_real() -> void:
	print("- real tracks")
	var db := VirtualDjDatabase.new()
	db.load_all()
	var believer := "D:/Music/Imagine Dragons/Evolve/04 Believer.m4a"
	var song := db.find_song(believer)
	if song == null or not SongAnalyzer.os_decoding_available():
		skip("Believer / OS AAC decoder not on this machine")
		return
	var tl := MusicTimeline.new()
	root.add_child(tl)
	tl.size = Vector2(1100, 600)
	tl.open(believer, song)
	ok(tl.is_loading_playback() and tl.play_button().disabled, "M4A: Play disabled while the audio is prepared")
	ok("Preparing the audio" in tl._status.text, "...and the status line says so (%s)" % tl._status.text)
	var t := Time.get_ticks_msec()
	while (tl.is_loading() or tl.is_loading_playback()) and Time.get_ticks_msec() - t < 30000:
		await process_frame
	await process_frame
	ok(tl.can_play() and not tl.play_button().disabled, "...then enabled")
	ok(tl._status.text == "", "status line clear once it's ready")
	var w := tl.wave()
	var g := w.grid_beats
	ok(g.size() > 400 and absf(g[0] - song.first_beat()) < 0.001, "VirtualDJ grid: %d beats from %.3f s" % [g.size(), g[0] if g.size() else -1.0])
	ok(absf((g[1] - g[0]) - 60.0 / song.best_bpm()) < 0.001, "at the deck's %.2f BPM" % song.best_bpm())
	tl.play()
	await _wait(500)
	ok(tl.is_playing() and tl.playback_position() > 0.2, "M4A plays in the timeline (%.2f s)" % tl.playback_position())
	tl.pause()

	var blah := db.find_song("D:/Music/Compilations/Blah Blah Blah (Remixes)/08 Blah Blah Blah.m4a")
	if blah == null or not blah.has_beat_grid():
		skip("variable-tempo track not on this machine")
	else:
		tl.open(blah.path, blah)
		t = Time.get_ticks_msec()
		while tl.is_loading() and Time.get_ticks_msec() - t < 30000:
			await process_frame
		var bg := tl.wave().grid_beats
		ok(bg.size() == blah.beat_times(tl.wave().duration()).size() and absf(bg[0] - 0.030459) < 0.001,
			"variable-tempo grid: %d beats from VirtualDJ's first beat" % bg.size())

	# Wake Me Up: VirtualDJ's first beat is at -0.043 s, so the first beat
	# drawn (0.441 s) is the bar's second, and bars fall on -0.043 + 4n beats.
	var wake := db.find_song("D:/Music/Avicii/True/01 Wake Me Up.m4a")
	if wake == null:
		skip("Wake Me Up not on this machine")
	else:
		tl.open(wake.path, wake)
		t = Time.get_ticks_msec()
		while tl.is_loading() and Time.get_ticks_msec() - t < 30000:
			await process_frame
		var ww := tl.wave()
		ok(ww.bar_phase == -1, "first beat before 0 s: bars counted from it (phase %d)" % ww.bar_phase)
		ww.set_view(0.0, 4.0)
		var bars := ww.grid_lines(0.0, 4.0).filter(func(l): return l[1]).map(func(l): return snappedf(ww.x_to_time(l[0]), 0.001))
		var spb := 60.0 / wake.best_bpm()
		ok(bars.size() == 2 and absf(bars[0] - (wake.first_beat() + 4 * spb)) < 0.002
			and absf(bars[1] - (wake.first_beat() + 8 * spb)) < 0.002,
			"bar lines at %s (first beat %.3f + 4 / 8 beats)" % [str(bars), wake.first_beat()])
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


func _mouse(tl: MusicTimeline, pos: Vector2, button: MouseButton, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_index = button
	ev.pressed = pressed
	tl.get_viewport().push_input(ev)


func _drag_to(tl: MusicTimeline, pos: Vector2, mask: int) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_mask = mask
	tl.get_viewport().push_input(ev)


func _test_middle_pan() -> void:
	print("- middle-button drag pans the view")
	var tl := MusicTimeline.new()
	root.add_child(tl)
	tl.position = Vector2.ZERO
	tl.size = Vector2(1100, 700)
	tl._set_analysis(_analysis(100.0, 10000))
	await process_frame
	await process_frame
	var w := tl.wave()
	w.set_view(40.0, 20.0)
	var per_px := 20.0 / w.size.x
	var area := tl.pan_area()
	var wr := w.get_global_rect()
	ok(area.position.x == wr.position.x and area.size.x == wr.size.x and is_equal_approx(area.end.y, wr.end.y)
		and area.position.y <= tl.master_track().get_global_rect().position.y
		and area.position.y <= tl.fixture_scroll().get_global_rect().position.y + 0.5,
		"the area: the waveform's width, from the fixtures' timelines down to the waveform")
	var mid := MOUSE_BUTTON_MASK_MIDDLE
	# On the waveform: drag left 200 px -> later in the song.
	var p := Vector2(wr.position.x + 400.0, wr.get_center().y)
	_mouse(tl, p, MOUSE_BUTTON_MIDDLE, true)
	ok(tl.is_panning(), "pressing the middle button starts panning")
	_drag_to(tl, p + Vector2(-200, 5), mid)
	ok(is_equal_approx(w.view_start, 40.0 + 200.0 * per_px) and is_equal_approx(w.visible_length(), 20.0),
		"dragging left moves the view later, zoom unchanged (%.2f)" % w.view_start)
	_drag_to(tl, p + Vector2(300, 0), mid)
	ok(is_equal_approx(w.view_start, 40.0 - 300.0 * per_px), "dragging right moves it earlier (%.2f)" % w.view_start)
	ok(w.song_pos == 0.0, "the playhead doesn't move")
	_mouse(tl, p + Vector2(300, 0), MOUSE_BUTTON_MIDDLE, false)
	ok(not tl.is_panning(), "releasing stops")
	var after := w.view_start
	_drag_to(tl, p + Vector2(-500, 0), 0)
	ok(w.view_start == after, "no panning after release")
	# On the master timeline: the same, and the tracks follow.
	var mr := tl.master_track().get_global_rect()
	var q := Vector2(mr.position.x + 600.0, mr.get_center().y)
	_mouse(tl, q, MOUSE_BUTTON_MIDDLE, true)
	_drag_to(tl, q + Vector2(-100, 0), mid)
	_mouse(tl, q + Vector2(-100, 0), MOUSE_BUTTON_MIDDLE, false)
	ok(is_equal_approx(w.view_start, after + 100.0 * per_px), "works over the timelines too (%.2f)" % w.view_start)
	ok(tl.structure_bar().view_start == w.view_start, "the structure bar follows")
	# Clamped at the ends.
	_mouse(tl, q, MOUSE_BUTTON_MIDDLE, true)
	_drag_to(tl, q + Vector2(5000, 0), mid)
	ok(w.view_start == 0.0, "stops at the start")
	_drag_to(tl, q + Vector2(-50000, 0), mid)
	ok(is_equal_approx(w.view_start, 80.0), "stops at the end")
	_mouse(tl, q, MOUSE_BUTTON_MIDDLE, false)
	# Outside the area (the name plates' column, the overview): nothing.
	var pr := tl.play_button().get_global_rect()
	_mouse(tl, pr.get_center(), MOUSE_BUTTON_MIDDLE, true)
	ok(not tl.is_panning(), "not from the buttons column")
	_mouse(tl, pr.get_center(), MOUSE_BUTTON_MIDDLE, false)
	var orr := tl.overview().get_global_rect()
	_mouse(tl, orr.get_center(), MOUSE_BUTTON_MIDDLE, true)
	ok(not tl.is_panning(), "not from the whole-track overview")
	_mouse(tl, orr.get_center(), MOUSE_BUTTON_MIDDLE, false)
	# Left button still scrubs, not pans.
	_mouse(tl, p, MOUSE_BUTTON_LEFT, true)
	ok(not tl.is_panning(), "the left button doesn't pan")
	_mouse(tl, p, MOUSE_BUTTON_LEFT, false)
	tl.queue_free()
	await process_frame
