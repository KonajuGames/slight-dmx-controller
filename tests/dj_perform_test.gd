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
	_test_wheel()
	_test_mute_solo()
	_test_mix()
	_test_report_time()
	await _test_performer()
	await _test_temporary()
	await _test_edit_playback()
	_clean()
	print("== %d passed, %d failed, %d skipped ==" % [_p, _f, _s])
	quit(1 if _f > 0 else 0)


func _clean() -> void:
	for d in [DIR + "/show.timelines", DIR + "/temp/show.timelines", DIR + "/temp", DIR]:
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


## A colour wheel spot (no RGB): a dimmer at 1, its wheel at 2 — open,
## red, green, blue.
## `track` with `flags` ({mute: true} / {solo: true}) added.
func _with(track: Dictionary, flags: Dictionary) -> Dictionary:
	var out := track.duplicate()
	out.merge(flags, true)
	return out


func _test_mute_solo() -> void:
	print("- mute / solo")
	var fx := _fixtures()
	var bases := _bases()
	var half := _nodes([[0, 0.5]])
	var o: Dictionary = P.song_output({"master": _with(half, {"mute": true})}, 5.0, fx, bases, 1)[0]
	ok(o.is_empty(), "the master muted: nothing driven")
	o = P.song_output({"master": half, "a": {"mute": true}}, 5.0, fx, bases, 1)[0]
	ok(not o.has(0) and o.get(42) == 128 and o.get(20) == 50, "a fixture muted: not driven, the master's still on the rest")
	o = P.song_output({"master": half, "c": {"mute": true}}, 5.0, fx, bases, 1)[0]
	ok(not o.has(20) and not o.has(23), "a muted fixture's heads are muted too")
	o = P.song_output({"master": half, "c/h0": {"mute": true}}, 5.0, fx, bases, 1)[0]
	ok(not o.has(20) and o.get(23) == 50 and o.get(0) == 128, "a head muted: just that head")
	o = P.song_output({"master": half, "b": {"solo": true}}, 5.0, fx, bases, 1)[0]
	ok(o.get(10) == 100 and not o.has(0) and not o.has(20) and not o.has(42), "a fixture soloed: only it plays (with the master's line)")
	o = P.song_output({"master": half, "c": {"solo": true}, "c/h1": {"mute": true}}, 5.0, fx, bases, 1)[0]
	ok(o.get(20) == 50 and not o.has(23) and not o.has(0), "...its heads too, unless muted")
	o = P.song_output({"master": half, "c/h1": {"solo": true}}, 5.0, fx, bases, 1)[0]
	ok(o.get(23) == 50 and not o.has(20) and not o.has(0) and not o.has(10), "a head soloed: only it, of its fixture and the rest")
	o = P.song_output({"master": half, "a": {"solo": true}, "c/h0": {"solo": true}}, 5.0, fx, bases, 1)[0]
	ok(o.get(0) == 128 and o.get(20) == 50 and not o.has(23) and not o.has(42), "two soloed: both play")
	o = P.song_output({"master": half, "a": {"solo": true, "mute": true}}, 5.0, fx, bases, 1)[0]
	ok(o.is_empty(), "soloed but muted: muted (and the rest still left out)")
	# The rules on their own.
	var tracks := {"master": {}, "f": {"solo": true}, "g/h2": {"solo": true}, "g/h3": {}}
	var mix := TimelineTrack.mix_state(tracks)
	ok(TimelineTrack.plays(tracks, mix, "master") and TimelineTrack.plays(tracks, mix, "f/h0")
		and TimelineTrack.plays(tracks, mix, "g") and TimelineTrack.plays(tracks, mix, "g/h2")
		and not TimelineTrack.plays(tracks, mix, "g/h3") and not TimelineTrack.plays(tracks, mix, "x"),
		"plays(): the master and a soloed head's fixture play on; its other heads and other fixtures don't")


func _test_wheel() -> void:
	print("- a colour wheel fixture")
	var spot := FixtureProfile.new("spot", "Wheel Spot", [
		{"name": "Dimmer", "role": "DIMMER"},
		{"name": "Colour", "role": "COLOR_WHEEL", "ranges": [
			{"lo": 0, "hi": 9, "label": "Open"},
			{"lo": 10, "hi": 19, "label": "Red", "color": "#ff0000"},
			{"lo": 20, "hi": 29, "label": "Green", "color": "#00ff00"},
			{"lo": 30, "hi": 39, "label": "Blue", "color": "#0000ff"},
		]},
	])
	var fx := [{"uid": "s", "u": 0, "start": 0, "mode": 0, "profile": spot}]
	var bases := [PackedByteArray()]
	var tracks := {"master": _colour(0, 10, Color(0.1, 0.2, 1.0), Color(0.1, 0.2, 1.0))}
	ok(int(P.song_output(tracks, 5.0, fx, bases, 1)[0].get(1, -1)) == 34, "the wheel turns to the master's colour's nearest slot (blue)")
	tracks["s"] = _colour(0, 10, Color(0.1, 1.0, 0.1), Color(0.1, 1.0, 0.1))
	ok(int(P.song_output(tracks, 5.0, fx, bases, 1)[0].get(1, -1)) == 24, "...or its own colour's (green)")
	ok(not P.song_output({}, 5.0, fx, bases, 1)[0].has(1), "...and is left alone without a colour")


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
	ok(out[0].get(0) == int(round(255 * 0.6)) and out[0].get(42) == 128,
		"a fixture's line overrides the master's (others keep the master's) (%s)" % out[0].get(0))
	out = P.song_output({"master": _nodes([[0, 0.5]]), "a": _nodes([[2, 0.2], [4, 0.2]])}, 5.0, fx, bases, 1)
	ok(out[0].get(0) == 128, "outside its first-to-last node: the master's again")
	out = P.song_output({"a": _nodes([[3, 0.9]])}, 5.0, fx, bases, 1)
	ok(out[0].is_empty(), "a single node: no stretch, nothing driven")
	# Only a head of the bar.
	out = P.song_output({"c/h1": _nodes([[0, 0.0], [10, 0.0]])}, 5.0, fx, bases, 1)
	o = out[0]
	ok(o.get(23) == 0 and o.get(25) == 0 and not o.has(20) and not o.has(10), "a head's line: only that head")
	# A head line on a fixture with a dimmer channel leaves the dimmer alone.
	var mover2 := {"uid": "e", "u": 0, "start": 60, "mode": 0,
		"profile": _profile("bar2", ["DIMMER", "RED", "GREEN", "BLUE", "RED", "GREEN", "BLUE"])}
	var b2: Array = _bases()
	for i in range(61, 67):
		b2[0][i] = 180
	b2[0][60] = 204                               # its console dimmer: 80 %
	out = P.song_output({"e/h0": _nodes([[0, 0.5], [10, 0.5]])}, 5.0, [mover2], b2, 1)
	ok(out[0].get(60) == 204 and out[0].get(61) == 113 and out[0].get(64) == 180,
		"a head's line with a shared dimmer: the dimmer at the brightest head (the other's 80 %%), that head's colour scaled to 50 %% (%s / %s / %s)" % [out[0].get(60), out[0].get(61), out[0].get(64)])
	out = P.song_output({"master": _nodes([[0, 0.2]]), "e": _nodes([[0, 0.4], [10, 0.4]]), "e/h1": _nodes([[0, 1.0], [10, 1.0]])}, 5.0, [mover2], b2, 1)
	ok(out[0].get(60) == 255 and out[0].get(61) == 72 and out[0].get(64) == 180,
		"a head overrides its fixture, which overrides the master (head 2 full, head 1 at the fixture's 40 %%)")
	out = P.song_output({"master": _nodes([[0, 0.5]]), "c/h0": _nodes([[0, 1.0], [10, 1.0]])}, 5.0, fx, bases, 1)
	ok(out[0].get(20) == 100 and out[0].get(23) == 50, "no dimmer channel: a head's line over the master's, the other head the master's")
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
	# Left out of show generation: the master doesn't drive it, its own rows do.
	var everything: Dictionary = _nodes([[0, 0.5]])
	everything.merge(_colour(0, 10, Color(1, 0, 0), Color(1, 0, 0)))
	everything["position"] = at_left["position"]
	everything["strobe"] = on["strobe"]
	everything["movement"] = [{"t0": 0.0, "t1": 10.0, "fx": "circle", "period": 2.0, "size": 0.1}]
	var left_out: Array = []
	for f in fx + [plain]:
		var g: Dictionary = f.duplicate()
		g["exclude_generate"] = String(f["uid"]) in ["d", "q"]
		left_out.append(g)
	o = P.song_output({"master": everything}, 5.0, left_out, bases, 1, lib)[0]
	ok(o.get(0) == 128 and o.get(10) == 128 and o.get(90) == null and not o.has(91),
		"a fixture left out of generation ignores the master (the others still follow it) (%s / %s / %s)" % [o.get(0), o.get(10), o.get(90)])
	ok(not o.has(40) and not o.has(41) and not o.has(42) and not o.has(43),
		"...its pan / tilt, dimmer and colour all left alone")
	o = P.song_output({"master": everything, "d": _nodes([[0, 0.4], [10, 0.4]])}, 5.0, left_out, bases, 1, lib)[0]
	ok(o.get(42) == 102 and not o.has(40) and not o.has(43), "...but its own rows still drive it (%s)" % o.get(42))
	var avg: Array = P.average_channels(fx, 1)
	var mixed: Array = P.mix([P.song_output({"master": at_left}, 5.0, fx, bases, 1, lib),
		P.song_output({"d": {"position": [{"t0": 0.0, "t1": 10.0, "pos": right["id"]}]}}, 5.0, fx, bases, 1, lib)], avg, 1)
	ok(mixed[0][40] == 192 and mixed[0][41] == 128, "two decks moving it: the average (%s / %s)" % [mixed[0][40], mixed[0][41]])
	# Movement: around the position, or the console's pan / tilt.
	var circle := {"movement": [{"t0": 0.0, "t1": 10.0, "fx": "circle", "period": 2.0, "size": 0.1}]}
	var both := {"position": at_left["position"], "movement": circle["movement"]}
	o = P.song_output({"master": both}, 4.0, fx, bases, 1, lib)[0]      # 4 s in: two cycles, at angle 0
	ok(o.get(40) == int(round(0.6 * 255)) and o.get(41) == 255, "a circle around the position (start of a cycle: +size pan) (%s / %s)" % [o.get(40), o.get(41)])
	o = P.song_output({"master": both}, 4.5, fx, bases, 1, lib)[0]      # a quarter round: +size tilt
	ok(o.get(40) == 128 and o.get(41) == 255, "...a quarter round: up (tilt clamped at the top)")
	o = P.song_output({"master": both}, 5.0, fx, bases, 1, lib)[0]      # half round
	ok(o.get(40) == int(round(0.4 * 255)), "...half round: the other side (%s)" % o.get(40))
	var console: Array = _bases()
	console[0][40] = 64
	console[0][41] = 128
	o = P.song_output({"master": circle}, 4.0, fx, console, 1, lib)[0]
	ok(o.get(40) == int(round((64.0 / 255.0 + 0.1) * 255)) and o.get(41) == 128, "no position: around the console's pan / tilt (%s / %s)" % [o.get(40), o.get(41)])
	var still := {"movement": [{"t0": 0.0, "t1": 10.0, "fx": "none"}]}
	o = P.song_output({"master": both, "d": still}, 4.5, fx, bases, 1, lib)[0]
	ok(o.get(40) == 128 and o.get(41) == 255, "a fixture's None beats the master's circle: at the position, still")
	ok(P.song_output({"master": still}, 4.5, fx, bases, 1, lib)[0].is_empty(), "None alone, no position: nothing driven")
	o = P.song_output({"master": circle}, 4.5, [spot16], bases, 1, lib)[0]
	ok(o.get(100) * 256 + o.get(101) == 0 and o.get(102) * 256 + o.get(103) == int(round(0.1 * 65535)),
		"16-bit: around the console's (here 0 / 0, clamped)")


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
	store.save_song(song2, {"tracks": {"a": {"dimmer": [[0.0, 0.8], [100.0, 0.8]]}}})
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
	# Mute / solo come with a song's timelines — a track with just those too.
	perf._loaded(2, perf.deck(2).load_id, {"tracks": {"master": {"dimmer": [[0, 0.5]]}, "a": {"mute": true},
		"c/h1": {"solo": true}}})
	var mixed: Dictionary = perf.deck(2).tracks
	ok(mixed.get("a", {}).get("mute") == true and mixed.get("c/h1", {}).get("solo") == true
		and mixed["master"].get("mute") == false, "a deck's timelines keep their mute / solo")
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
	# Decks 3 and 4 behind a 2-deck skin still report what was left on them.
	ok(perf.deck(3).hidden and perf.deck(4).hidden and not perf.deck(2).hidden, "decks 3 and 4 hidden until the skin shows them")
	_vdj(perf, "deck 3 get_filepath", song1)
	_vdj(perf, "deck 3 play", "on")
	ok(perf.deck(3).path == "" and not perf.deck(3).playing, "a hidden deck's song isn't followed")
	_vdj(perf, "get_decks", 4)
	ok(not perf.deck(3).hidden and perf.deck(3).path == song1 and perf.deck(3).playing, "a 4-deck skin: deck 3 picks up what VirtualDJ reported")
	await _wait_loads(perf)
	_vdj(perf, "get_decks", "2")
	ok(perf.deck(3).hidden and perf.deck(3).path == "" and not perf.deck(3).live(), "back to 2 decks: deck 3 forgotten")

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
	ok(rows[2]["state"].text == "not in the skin" and rows[2]["song"].text == "", "panel: a deck the skin doesn't show")
	perf.set_skin_decks(4)
	panel.refresh()
	ok(rows[3]["state"].text == "empty" and rows[3]["song"].text == "", "panel: an empty deck")
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


## A ready-made structure for a 60 s song at 120 BPM (so no decoding).
func _analysis() -> SongAnalysis:
	var a := SongAnalysis.new()
	a.duration = 60.0
	a.bpm = 120.0
	for i in range(120):
		a.beat_times.append(i * 0.5)
		if i % 4 == 0:
			a.downbeats.append(i * 0.5)
	a.sections = [{"start": 0.0, "end": 16.0, "label": "Intro", "energy": 0.2},
		{"start": 16.0, "end": 44.0, "label": "Chorus", "energy": 0.9},
		{"start": 44.0, "end": 60.0, "label": "Outro", "energy": 0.3}]
	return a


## Until every deck's temporary timelines are as made as they'll get.
func _wait_generated(perf) -> bool:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < 30000:
		if perf.loads_done() and not perf.is_generating():
			return true
		await process_frame
	return false


func _test_temporary() -> void:
	print("- temporary timelines for songs without any")
	_clean()
	var dir := ProjectSettings.globalize_path(DIR + "/temp")
	var cached := dir.path_join("cached.mp3")        # analysed already this session
	var junk := dir.path_join("junk.mp3")            # can't be analysed
	var own := dir.path_join("own.mp3")              # has timelines of its own
	var unsaved := dir.path_join("unsaved.mp3")
	_song_file(cached, 3)
	_song_file(junk, 5)
	_song_file(own, 7)
	_song_file(unsaved, 11)
	var store := TimelineStore.new(dir.path_join("show.timelines"))
	store.save_song(own, {"tracks": {"master": {"dimmer": [[0.0, 0.5], [60.0, 0.5]]}}})
	var fx := _fixtures()
	var browser := MusicBrowserPanel.new()
	root.add_child(browser)
	await process_frame
	var tl := browser.timeline()
	tl.positions = PositionLibrary.new()
	tl.fixtures_provider = func():
		return fx.map(func(f): return {"key": f["uid"], "name": f["uid"], "profile": f["profile"], "mode": 0})
	tl.refresh_fixtures()
	tl.set_timeline_store(store)
	tl.add_structure(cached, _analysis())
	tl.add_structure(unsaved, _analysis())

	var perf = P.new()
	perf.port = 19963
	perf.advertise = false
	perf.fixtures_provider = func(): return fx
	perf.store_provider = func(): return tl.timeline_store
	perf.timeline = tl
	root.add_child(perf)
	perf.start()
	_vdj(perf, "get_decks", 4)

	# Analysed already: its show at once, saved flagged temporary.
	_vdj(perf, "deck 1 get_filepath", cached)
	ok(await _wait_generated(perf), "a song without timelines: generated")
	var d1 = perf.deck(1)
	ok(d1.load_state == P.Load.LOADED and d1.temporary and not d1.analysing and d1.tracks.has("master") and d1.tracks.size() > 1,
		"analysed this session: its generated show on the deck (%d tracks)" % d1.tracks.size())
	ok(store.load_song(cached).get("temporary") == true and store.is_temporary(cached)
		and TimelineStore.new(store.dir).is_temporary(cached), "saved with the show, flagged temporary (in the index too)")
	ok(PanelScript.timelines_text(d1).ends_with(", temporary)"), "panel: temporary (%s)" % PanelScript.timelines_text(d1))
	_vdj(perf, "deck 1 level", 1.0)
	_vdj(perf, "deck 1 play", "on")
	_vdj(perf, "deck 1 get_time elapsed absolute", 30000.0)
	ok(not perf.layer(1)[0].is_empty(), "and it plays into the lights")

	# Not analysed, and it can't be: a stand-in on the beat, kept.
	perf.os2l.handle_message({"evt": "subscribed", "trigger": "deck 2 get_bpm", "value": 128.0})
	_vdj(perf, "deck 2 get_filepath", junk)
	var d2 = perf.deck(2)
	await _wait_generated(perf)
	ok(d2.load_state == P.Load.LOADED and d2.temporary and not d2.tracks.is_empty() and d2.tracks.size() > 1,
		"a stand-in on the beat (made on a worker thread), while it's analysed")
	var was_analysing: bool = d2.analysing
	d2.analysing = true
	ok("on the beat only" in PanelScript.timelines_text(d2), "panel: says so (%s)" % PanelScript.timelines_text(d2))
	d2.analysing = was_analysing
	ok(not d2.analysing and d2.note != "" and not d2.tracks.is_empty() and not store.has_song(junk),
		"it can't be analysed: the stand-in stays, not saved (%s)" % d2.note)

	# A song with its own timelines: those, not temporary.
	_vdj(perf, "deck 1 get_filepath", own)
	await _wait_generated(perf)
	ok(d1.load_state == P.Load.LOADED and not d1.temporary and d1.tracks.size() == 1, "a song with its own timelines: those")
	tl.add_structure(own, _analysis())
	ok(tl.put_generated(own, tl.generate_for(own), true) != "" and not store.is_temporary(own),
		"temporary timelines never replace a song's own")
	# The temporary ones again, from the show.
	_vdj(perf, "deck 1 get_filepath", cached)
	await _wait_generated(perf)
	ok(d1.load_state == P.Load.LOADED and d1.temporary and not d1.analysing, "loaded again: its temporary timelines, from the show")

	# The song list: an orange icon; edited in DJ Edit Mode, they're the user's.
	browser.show_folder(dir)
	var it: TreeItem = browser._items[cached]
	ok(browser.is_temporary_mark(cached) and it.get_icon(MusicBrowserPanel.Col.TITLE) == MusicBrowserPanel.temporary_icon()
		and it.get_tooltip_text(MusicBrowserPanel.Col.TITLE) == MusicBrowserPanel.TEMPORARY_TIP, "song list: temporary ones in orange")
	ok(browser._items[own].get_icon(MusicBrowserPanel.Col.TITLE) == MusicBrowserPanel.timeline_icon(), "...the user's own in blue")
	tl.open(cached)
	tl.master_track().dimmer_nodes = PackedVector2Array([Vector2(0, 0.4), Vector2(60, 0.4)])
	tl._mark_dirty()
	ok(tl.flush() == "" and not store.is_temporary(cached) and not store.load_song(cached).has("temporary")
		and it.get_icon(MusicBrowserPanel.Col.TITLE) == MusicBrowserPanel.timeline_icon(), "edited and saved: the user's own (blue)")

	# No timelines folder: generated all the same, just not saved.
	tl.set_timeline_store(null)
	_vdj(perf, "deck 3 get_filepath", unsaved)
	await _wait_generated(perf)
	var d3 = perf.deck(3)
	ok(d3.load_state == P.Load.LOADED and d3.temporary and d3.tracks.size() > 1 and "not saved" in d3.note
		and not store.has_song(unsaved), "show not saved: generated and played, not saved (%s)" % d3.note)

	# A song really analysed (needs the native extension: no playback).
	if SongAnalyzer.fast_available():
		tl.set_timeline_store(store)
		var wav := _silent_wav(DIR + "/temp/real.wav")
		var d4 = perf.deck(4)
		_vdj(perf, "deck 4 get_filepath", wav)
		ok(await _wait_generated(perf) and not d4.analysing and d4.tracks.size() > 1 and d4.note == "" and store.is_temporary(wav)
			and tl.cached_structure(wav) != null, "analysed: its show generated, saved temporary (%s)" % d4.note)
	else:
		_s += 1
		print("  skip analysing a song needs the native extension")
	perf.stop()
	perf.queue_free()
	browser.queue_free()
	await process_frame


## A silent 6 s WAV.
func _silent_wav(path: String) -> String:
	var rate := 22050
	var data := PackedByteArray()
	data.resize(rate * 6 * 2)
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


func _test_edit_playback() -> void:
	print("- DJ Edit Mode playback goes live")
	DirAccess.make_dir_recursive_absolute(DIR)
	var main: Control = load("res://main.tscn").instantiate()
	main.last_show_store = DIR + "/last.json"
	root.add_child(main)
	await process_frame
	# A mover at channel 1: pan, tilt, dimmer.
	main._panels[0].add_patched(_profile("mover", ["PAN", "TILT", "DIMMER"]), 0, 0, "Spot", Vector3.ZERO, Vector3.ZERO)
	var tl = main.music_panel.timeline()
	tl.refresh_fixtures()
	tl.open(_silent_wav(DIR + "/edit.wav"))
	var t := Time.get_ticks_msec()
	while tl.is_loading() and Time.get_ticks_msec() - t < 20000:
		await process_frame
	ok(tl.can_play(), "a song open in DJ Edit Mode")
	tl.master_track().dimmer_nodes = PackedVector2Array([Vector2(0, 0.6), Vector2(6, 0.6)])
	ok(main._edit_playback_layer(1)[0].is_empty(), "not playing, in the console view: nothing goes out")
	tl.play()
	await create_timer(0.2).timeout
	var l: Dictionary = main._edit_playback_layer(1)[0]
	ok(tl.is_playing() and l.get(2) == int(round(0.6 * 255)), "playing: the timelines at the playhead (dimmer %s)" % str(l.get(2)))
	tl.master_track().dimmer_nodes = PackedVector2Array([Vector2(0, 0.2), Vector2(6, 0.2)])
	l = main._edit_playback_layer(1)[0]
	ok(l.get(2) == int(round(0.2 * 255)), "edits show straight away (dimmer %s)" % str(l.get(2)))
	ok(root.get_node("ArtNet").layer_providers.has(main._edit_playback_layer), "a layer of the DMX output")
	tl.pause()
	ok(main._edit_playback_layer(1)[0].is_empty(), "paused in another view: nothing goes out (the console has the rig)")
	main.music_panel.visible = true
	tl.visible = true                       # its timeline showing (as open_track() does)
	tl.master_track().dimmer_nodes = PackedVector2Array([Vector2(0, 0.2), Vector2(3, 0.2), Vector2(3, 0.9), Vector2(6, 0.9)])
	tl.seek(1.0)
	l = main._edit_playback_layer(1)[0]
	ok(l.get(2) == int(round(0.2 * 255)), "paused in DJ Edit Mode: the look at the playhead held (dimmer %s)" % str(l.get(2)))
	tl.seek(4.0)
	l = main._edit_playback_layer(1)[0]
	ok(absi(int(l.get(2, -9)) - 230) <= 1, "...following the playhead as it's moved (dimmer %s)" % str(l.get(2)))
	# The Positions Editor open in its place: the console (and its
	# highlights) have the rig.
	var pid := String(main.positions.add()["id"])
	main.music_panel.open_position(pid)
	ok(main._edit_playback_layer(1)[0].is_empty(), "paused, the Positions Editor showing: nothing goes out")
	# Playing on behind it: a highlighted fixture is left out of it.
	tl.play()
	await create_timer(0.1).timeout
	var spot := int(main._panels[0].patched_fixtures[0]["id"])
	main._panels[0].set_highlight(spot, true)
	ok(tl.is_playing() and main._edit_playback_layer(1)[0].is_empty(), "playing: a highlighted fixture keeps its highlight")
	main._panels[0].set_highlight(spot, false)
	ok(not main._edit_playback_layer(1)[0].is_empty(), "...and follows the timelines again once it's not")
	tl.pause()
	main.music_panel.visible = false
	ok(main._edit_playback_layer(1)[0].is_empty(), "back to the console: nothing goes out")
	main.queue_free()
	await process_frame
