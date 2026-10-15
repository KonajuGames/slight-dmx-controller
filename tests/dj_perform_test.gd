extends SceneTree
## Tests for DJ Perform Mode: DjPerformer (VirtualDJ over OS2L playing the
## songs' lighting timelines into the DMX output) and its panel.
##
##   godot --headless --script tests/dj_perform_test.gd

var _p := 0
var _f := 0
var _s := 0

# DjPerformer reaches the ArtNet autoload, which a --script run can't
# resolve at compile time — so it's loaded at run time.
var P: GDScript
var PanelScript: GDScript

const DIR := "user://_dj_perform_test"


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
	print("== DJ Perform Mode ==")
	P = load("res://scripts/dj_performer.gd")
	PanelScript = load("res://scripts/dj_perform_panel.gd")
	_test_song_output()
	_test_mix()
	_test_report_time()
	await _test_performer()
	_clean()
	print("== %d passed, %d failed, %d skipped ==" % [_p, _f, _s])
	quit(1 if _f > 0 else 0)


func _clean() -> void:
	for d in [DIR + "/show.timelines", DIR]:
		if DirAccess.dir_exists_absolute(d):
			for f in DirAccess.get_files_at(d):
				DirAccess.remove_absolute(d.path_join(f))
			DirAccess.remove_absolute(d)


func _profile(id: String, roles: Array) -> FixtureProfile:
	var chans := []
	for r in roles:
		chans.append({"name": r, "role": r})
	return FixtureProfile.new(id, id, chans)


## A par with a dimmer at 1, an RGB par without at 11, a two-head bar
## without at 21, a mover with pan / tilt and a dimmer at 41.
func _fixtures() -> Array:
	return [
		{"uid": "a", "u": 0, "start": 0, "mode": 0, "profile": _profile("dpar", ["DIMMER", "RED", "GREEN", "BLUE"])},
		{"uid": "b", "u": 0, "start": 10, "mode": 0, "profile": _profile("rgb", ["RED", "GREEN", "BLUE"])},
		{"uid": "c", "u": 0, "start": 20, "mode": 0, "profile": _profile("bar", ["RED", "GREEN", "BLUE", "RED", "GREEN", "BLUE"])},
		{"uid": "d", "u": 0, "start": 40, "mode": 0, "profile": _profile("mover", ["PAN", "TILT", "DIMMER", "RED", "GREEN", "BLUE"])},
	]


func _bases() -> Array:
	var b := PackedByteArray()
	b.resize(512)
	for i in range(1, 4):
		b[i] = 200                    # par a: white
	b[10] = 200; b[11] = 100; b[12] = 50   # par b: orange
	for i in range(20, 26):
		b[i] = 100                    # bar c: grey
	return [b]


## A track with a dimmer line through these [t, level] points.
func _nodes(arr: Array) -> Dictionary:
	var out := PackedVector2Array()
	for p in arr:
		out.append(Vector2(p[0], p[1]))
	return {"dimmer": out}


## A track with one colour segment.
func _colour(t0: float, t1: float, c0: Color, c1: Color) -> Dictionary:
	return {"colour": [{"t0": t0, "t1": t1, "c0": c0, "c1": c1}]}


func _test_song_output() -> void:
	print("- a song's timelines into DMX values")
	var fx := _fixtures()
	var bases := _bases()
	var out: Array = P.song_output({}, 5.0, fx, bases, 1)
	ok(out.size() == 1 and out[0].is_empty(), "no timelines: drives nothing")
	# The master at 50 %.
	out = P.song_output({"master": _nodes([[0, 0.5]])}, 5.0, fx, bases, 1)
	var o: Dictionary = out[0]
	ok(o.get(0) == 128 and o.get(42) == 128, "master 50 %%: dimmer channels at half (%s / %s)" % [o.get(0), o.get(42)])
	ok(not o.has(1) and not o.has(43), "...colour left alone where there's a dimmer")
	ok(o.get(10) == 100 and o.get(11) == 50 and o.get(12) == 25, "no dimmer channel: the colour scaled (the virtual dimmer)")
	ok(o.get(20) == 50 and o.get(25) == 50, "a multi-head fixture without a dimmer: every head scaled")
	ok(not o.has(40) and not o.has(41), "pan / tilt untouched")
	# A fixture's own line times the master.
	out = P.song_output({"master": _nodes([[0, 0.5]]), "a": _nodes([[0, 0.2], [10, 1.0]])}, 5.0, fx, bases, 1)
	ok(out[0].get(0) == int(round(255 * 0.5 * 0.6)), "fixture x master (%s)" % out[0].get(0))
	# Only a head of the bar.
	out = P.song_output({"c/h1": _nodes([[0, 0.0]])}, 5.0, fx, bases, 1)
	o = out[0]
	ok(o.get(23) == 0 and o.get(25) == 0 and not o.has(20) and not o.has(10), "a head's line: only that head")
	# A head line on a fixture with a dimmer channel leaves the dimmer alone.
	var mover2 := {"uid": "e", "u": 0, "start": 60, "mode": 0,
		"profile": _profile("bar2", ["DIMMER", "RED", "GREEN", "BLUE", "RED", "GREEN", "BLUE"])}
	var b2: Array = _bases()
	for i in range(61, 67):
		b2[0][i] = 180
	out = P.song_output({"e/h0": _nodes([[0, 0.5]])}, 5.0, [mover2], b2, 1)
	ok(not out[0].has(60) and out[0].get(61) == 90 and not out[0].has(64), "head line with a dimmer channel: that head's colour, dimmer untouched")
	# Off the end of the universes / other universes.
	out = P.song_output({"master": _nodes([[0, 1.0]])}, 5.0, [{"uid": "z", "u": 3, "start": 0, "mode": 0, "profile": _profile("dpar", ["DIMMER"])}], bases, 1)
	ok(out[0].is_empty(), "a fixture on a universe that isn't there: skipped")
	# Colour.
	out = P.song_output({"master": _colour(0, 10, Color(1, 0, 0), Color(1, 0, 0))}, 5.0, fx, bases, 1)
	o = out[0]
	ok(o.get(1) == 255 and o.get(2) == 0 and o.get(3) == 0 and not o.has(0), "master colour: every head red, dimmer channel left alone")
	ok(o.get(10) == 255 and o.get(11) == 0 and o.get(20) == 255 and o.get(23) == 255 and o.get(43) == 255, "...on every fixture and head")
	ok(P.song_output({"master": _colour(0, 10, Color(1, 0, 0), Color(1, 0, 0))}, 12.0, fx, bases, 1)[0].is_empty(),
		"outside the colour segment: nothing set")
	out = P.song_output({"master": _colour(0, 10, Color(0, 0, 0), Color(0, 0, 1))}, 5.0, fx, bases, 1)
	ok(out[0].get(3) == 128, "a gradient: half way at the middle (%s)" % out[0].get(3))
	var t2 := {"master": _colour(0, 10, Color(1, 0, 0), Color(1, 0, 0)), "c": _colour(0, 10, Color(0, 1, 0), Color(0, 1, 0)),
		"c/h1": _colour(0, 10, Color(0, 0, 1), Color(0, 0, 1))}
	o = P.song_output(t2, 5.0, fx, bases, 1)[0]
	ok(o.get(10) == 255 and o.get(21) == 255 and o.get(20) == 0 and o.get(25) == 255 and o.get(24) == 0,
		"a head's colour beats its fixture's, which beats the master's")
	t2 = {"b": _colour(0, 10, Color(1, 1, 1), Color(1, 1, 1)), "master": _nodes([[0, 0.5]])}
	o = P.song_output(t2, 5.0, fx, bases, 1)[0]
	ok(o.get(10) == 128 and o.get(11) == 128, "no dimmer channel: the timeline's colour, dimmed (%s)" % o.get(10))
	ok(o.get(0) == 128 and o.get(1) == null, "with one: colour and dimmer separate (the par's colour untouched)")
	# Strobe.
	var strober := {"uid": "s", "u": 0, "start": 80, "mode": 0, "profile": FixtureProfile.new("st", "st", [
		{"name": "Shutter", "role": "STROBE", "ranges": [{"lo": 0, "hi": 9, "label": "Closed"}, {"lo": 10, "hi": 19, "label": "Open"},
			{"lo": 20, "hi": 240, "label": "Strobe slow-fast"}]}, {"name": "Dimmer", "role": "DIMMER"}])}
	var plain := {"uid": "q", "u": 0, "start": 90, "mode": 0, "profile": _profile("plainstrobe", ["STROBE", "DIMMER"])}
	var on := {"strobe": [{"t0": 0.0, "t1": 10.0, "speed": 2}]}
	o = P.song_output({"s": on, "q": on}, 5.0, [strober, plain], bases, 1)[0]
	ok(o.get(80) == 240 and o.get(90) == 240, "strobe fast: the fast end of its strobe range (or of 20-240) (%s / %s)" % [o.get(80), o.get(90)])
	var slow := {"strobe": [{"t0": 0.0, "t1": 10.0, "speed": 0}]}
	var medium := {"strobe": [{"t0": 0.0, "t1": 10.0, "speed": 1}]}
	ok(P.song_output({"s": slow}, 5.0, [strober], bases, 1)[0].get(80) == 64
		and P.song_output({"s": medium}, 5.0, [strober], bases, 1)[0].get(80) == 141, "slow / medium: a fifth / just over half way up the range")
	ok(P.song_output({"s": slow, "master": medium}, 5.0, [strober], bases, 1)[0].get(80) == 141, "its own and the master's: the faster")
	ok(P.mix([P.song_output({"s": slow}, 5.0, [strober], bases, 1), P.song_output({"s": on}, 5.0, [strober], bases, 1)], [{}], 1)[0][80] == 240,
		"two decks strobing: the faster wins (HTP)")
	ok(not o.has(81), "...and nothing else")
	ok(P.song_output({"s": on}, 12.0, [strober], bases, 1)[0].is_empty(), "outside a strobe segment: left alone")
	o = P.song_output({"master": on}, 5.0, [strober, plain] + fx, bases, 1)[0]
	ok(o.get(80) == 240 and o.get(90) == 240 and not o.has(0), "the master's strobe: every fixture with a strobe channel")
	# Positions: pan / tilt.
	var lib := PositionLibrary.new()
	var left := lib.add()
	var right := lib.add()
	var spot16 := {"uid": "h", "u": 0, "start": 100, "mode": 0, "profile": FixtureProfile.new("s16", "s16", [
		{"name": "Pan", "role": "PAN"}, {"name": "Pan fine", "role": "PAN_FINE", "fine": true},
		{"name": "Tilt", "role": "TILT"}, {"name": "Tilt fine", "role": "TILT_FINE", "fine": true}, {"name": "Dimmer", "role": "DIMMER"}])}
	lib.set_point(left["id"], "h", Vector2(0.25, 0.75))
	lib.set_point(left["id"], "d", Vector2(0.5, 1.0))
	lib.set_point(right["id"], "d", Vector2(1.0, 0.0))
	var at_left := {"position": [{"t0": 0.0, "t1": 10.0, "pos": left["id"]}]}
	o = P.song_output({"master": at_left}, 5.0, [spot16] + fx, bases, 1, lib)[0]
	var pan16: int = o.get(100) * 256 + o.get(101)
	var tilt16: int = o.get(102) * 256 + o.get(103)
	ok(pan16 == int(round(0.25 * 65535)) and tilt16 == int(round(0.75 * 65535)),
		"a 16-bit mover: pan / tilt across coarse and fine (%d / %d)" % [pan16, tilt16])
	ok(o.get(40) == 128 and o.get(41) == 255, "an 8-bit mover: its point for that position (%s / %s)" % [o.get(40), o.get(41)])
	ok(not o.has(104) and not o.has(42), "dimmers untouched")
	o = P.song_output({"master": at_left, "d": {"position": [{"t0": 0.0, "t1": 10.0, "pos": right["id"]}]}}, 5.0, fx, bases, 1, lib)[0]
	ok(o.get(40) == 255 and o.get(41) == 0, "a fixture's own position row beats the master's")
	ok(P.song_output({"master": at_left}, 12.0, fx, bases, 1, lib)[0].is_empty(), "outside a position segment: left alone")
	ok(P.song_output({"master": at_left}, 5.0, fx, bases, 1, null)[0].is_empty(), "no positions library: nothing")
	var gone := {"position": [{"t0": 0.0, "t1": 10.0, "pos": "deleted"}]}
	ok(P.song_output({"master": gone}, 5.0, fx, bases, 1, lib)[0].is_empty(), "a deleted position: nothing")
	var avg: Array = P.average_channels(fx, 1)
	var mixed: Array = P.mix([P.song_output({"master": at_left}, 5.0, fx, bases, 1, lib),
		P.song_output({"d": {"position": [{"t0": 0.0, "t1": 10.0, "pos": right["id"]}]}}, 5.0, fx, bases, 1, lib)], avg, 1)
	ok(mixed[0][40] == 192 and mixed[0][41] == 128, "two decks moving it: the average (%s / %s)" % [mixed[0][40], mixed[0][41]])


func _test_mix() -> void:
	print("- mixing decks")
	var fx := _fixtures()
	var avg: Array = P.average_channels(fx, 1)
	ok(avg[0].has(40) and avg[0].has(41) and avg[0].size() == 2, "pan / tilt channels are averaged; the rest HTP")
	var a := [{0: 100, 10: 50, 40: 0, 41: 100}]
	var b := [{0: 200, 10: 20, 40: 200}]
	var m: Array = P.mix([a, b], avg, 1)
	ok(m[0][0] == 200 and m[0][10] == 50, "HTP: the highest wins (dimmer, colour)")
	ok(m[0][40] == 100 and m[0][41] == 100, "movement: the average of the decks driving it")
	ok(P.mix([a], avg, 1)[0] == a[0], "one deck: as is")


func _test_report_time() -> void:
	print("- a deck's position")
	var d = P.Deck.new()
	d.playing = true
	P.report_time(d, 10.0, 1000)
	P.report_time(d, 10.2, 1200)
	ok(is_equal_approx(d.rate, 1.0) and d.time == 10.2, "reports a second apart: normal speed")
	P.report_time(d, 10.46, 1400)          # 1.3x
	ok(d.rate > 1.0 and d.rate < 1.3, "a pitched-up deck: the rate follows (%.3f)" % d.rate)
	d.playing = false
	d.time = 30.0
	ok(d.position() == 30.0, "paused: stays put")


func _song_file(path: String, seed_v: int) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var b := PackedByteArray()
	b.resize(90000)
	for i in range(0, b.size(), 17):
		b[i] = (i * seed_v) & 0xFF
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(b)
	f.close()


func _vdj(perf, trigger: String, value) -> void:
	perf.os2l.handle_message({"evt": "subscribed", "trigger": trigger, "value": value})


func _wait_loads(perf) -> bool:
	var t := Time.get_ticks_msec()
	while not perf.loads_done() and Time.get_ticks_msec() - t < 5000:
		await process_frame
	return perf.loads_done()


func _test_performer() -> void:
	print("- following VirtualDJ")
	_clean()
	var song1 := ProjectSettings.globalize_path(DIR + "/one.song")
	var song2 := ProjectSettings.globalize_path(DIR + "/two.song")
	var song3 := ProjectSettings.globalize_path(DIR + "/three.song")
	_song_file(song1, 3)
	_song_file(song2, 5)
	_song_file(song3, 7)
	var store := TimelineStore.new(DIR + "/show.timelines")
	store.save_song(song1, {"tracks": {"master": {"dimmer": [[0.0, 0.25], [20.0, 0.25]]}}})
	store.save_song(song2, {"tracks": {"a": {"dimmer": [[0.0, 0.8]]}}})
	var fx := _fixtures()
	var artnet: Node = root.get_node("ArtNet")
	var u0 = artnet.get_universe(0)
	var keep: PackedByteArray = u0.dmx_data.duplicate()
	u0.dmx_data = _bases()[0]

	var perf = P.new()
	perf.port = 19962
	perf.advertise = false
	perf.fixtures_provider = func(): return fx
	var current_store := [store]
	perf.store_provider = func(): return current_store[0]
	root.add_child(perf)
	ok(not perf.is_active() and not artnet.layer_providers.has(perf.layer), "not running until started")
	ok(perf.start() == OK and perf.is_listening(), "start(): listening (%s)" % perf.status())
	ok(artnet.layer_providers.has(perf.layer), "and playing into the DMX output")

	# Deck 1 loads song 1 (VirtualDJ reports Windows paths).
	_vdj(perf, "deck 1 get_filepath", song1.replace("/", "\\"))
	ok(perf.deck(1).path == song1 and perf.deck(1).load_state == P.Load.LOADING, "a new song on a deck: its timelines load in the background")
	ok(await _wait_loads(perf) and perf.deck(1).load_state == P.Load.LOADED and perf.deck(1).tracks.has("master"), "loaded")
	ok(perf.layer(1)[0].is_empty(), "not playing: nothing driven")
	_vdj(perf, "deck 1 level", 1.0)
	_vdj(perf, "deck 1 play", "on")
	_vdj(perf, "deck 1 get_time elapsed absolute", 5000.0)
	ok(perf.deck(1).live() and absf(perf.deck(1).position() - 5.0) < 0.2, "playing at 5 s")
	var l: Array = perf.layer(1)
	ok(l[0].get(0) == 64 and l[0].get(42) == 64, "the master's 25 %% on the dimmers (%s)" % l[0].get(0))
	artnet.tick(false)
	ok(u0.output[0] == 64, "in the DMX frame (%d)" % u0.output[0])
	_vdj(perf, "deck 1 level", 0.0)
	ok(perf.layer(1)[0].is_empty(), "volume fader down (cueing in the headphones): not driven")
	_vdj(perf, "deck 1 level", 0.9)
	# Deck 2: song 2 (par a at 80 %) — the two mix, HTP.
	_vdj(perf, "deck 2 get_filepath", song2)
	await _wait_loads(perf)
	_vdj(perf, "deck 2 play", "on")
	_vdj(perf, "deck 2 get_time elapsed absolute", 60000.0)
	l = perf.layer(1)
	ok(l[0].get(0) == 204 and l[0].get(42) == 64, "two decks playing: highest takes precedence (%s, %s)" % [l[0].get(0), l[0].get(42)])
	_vdj(perf, "deck 2 play", "off")
	ok(perf.layer(1)[0].get(0) == 64, "deck 2 paused: deck 1's again")
	# A song without timelines; a song changed while loading.
	_vdj(perf, "deck 2 get_filepath", song3)
	ok(await _wait_loads(perf) and perf.deck(2).load_state == P.Load.NO_TIMELINES, "a song with no timelines")
	_vdj(perf, "deck 2 get_filepath", song2)
	_vdj(perf, "deck 2 get_filepath", song3)
	await _wait_loads(perf)
	ok(perf.deck(2).path == song3 and perf.deck(2).load_state == P.Load.NO_TIMELINES, "changed while loading: the newer song wins")
	# No timelines folder (a new, unsaved show).
	current_store[0] = null
	perf.reload_all()
	ok(perf.deck(1).load_state == P.Load.NO_FOLDER and perf.layer(1)[0].is_empty(), "no timelines folder: nothing to play")
	current_store[0] = store
	perf.reload_all()
	await _wait_loads(perf)
	ok(perf.deck(1).load_state == P.Load.LOADED, "the show's folder back: reloaded")

	# The panel.
	var panel = PanelScript.new()
	panel.performer = perf
	root.add_child(panel)
	await process_frame
	panel.refresh()
	var rows: Array = panel._rows
	ok("listening on :19962" in panel._connection.text and "waiting for VirtualDJ" in panel._connection.text,
		"panel: the connection (%s)" % panel._connection.text)
	ok(rows[0]["song"].text == "one" and rows[0]["state"].text == "playing" and rows[0]["timelines"].text == "playing (1 track)"
		and rows[0]["position"].text.begins_with("0:0"), "panel: deck 1 (%s / %s / %s)" % [rows[0]["state"].text, rows[0]["timelines"].text, rows[0]["position"].text])
	ok(rows[1]["state"].text == "paused" and rows[1]["timelines"].text == "none for this song", "panel: deck 2")
	ok(rows[2]["state"].text == "empty" and rows[2]["song"].text == "", "panel: an empty deck")
	# Stop.
	perf.stop()
	ok(not perf.is_active() and not artnet.layer_providers.has(perf.layer) and perf.deck(1).path == "", "stop(): listener and playback stopped, decks forgotten")
	artnet.tick(false)
	ok(u0.output[0] == 0, "nothing in the DMX frame any more")
	panel.refresh()
	ok(panel._connection.text == "OS2L: off", "panel: off")
	panel.queue_free()
	perf.queue_free()
	u0.dmx_data = keep
	await process_frame
