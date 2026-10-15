extends SceneTree
## Tests for TimelineGenerator — the Generate button's show, built into
## the timelines from a song's structure, tempo and energy.
##
##   godot --headless --script tests/timeline_generator_test.gd

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
	print("== Timeline generator ==")
	_test_show()
	_test_edges()
	print("== %d passed, %d failed, %d skipped ==" % [_p, _f, _s])
	quit(1 if _f > 0 else 0)


const R := TimelineTrack.Row
const T := TimelineTrack.Target


## A song: 120 BPM (bars of 2 s), six sections.
func _sections() -> Array:
	return [
		{"start": 0.0, "end": 16.0, "label": "Intro", "energy": 0.2},
		{"start": 16.0, "end": 40.0, "label": "Verse", "energy": 0.4},
		{"start": 40.0, "end": 64.0, "label": "Chorus", "energy": 0.9},
		{"start": 64.0, "end": 80.0, "label": "Bridge", "energy": 0.3},
		{"start": 80.0, "end": 104.0, "label": "Chorus", "energy": 0.95},
		{"start": 104.0, "end": 120.0, "label": "Outro", "energy": 0.2},
	]


func _beats() -> PackedFloat32Array:
	var b := PackedFloat32Array()
	for i in range(240):
		b.append(i * 0.5)
	return b


func _tracks() -> Array:
	return [
		{"key": "master", "target": T.MASTER, "rows": TimelineTrack.ROW_ORDER.duplicate()},
		{"key": "par1", "target": T.FIXTURE, "rows": [R.COLOUR, R.DIMMER]},
		{"key": "par2", "target": T.FIXTURE, "rows": [R.COLOUR, R.DIMMER]},
		{"key": "bar", "target": T.FIXTURE, "rows": [R.STROBE, R.COLOUR, R.DIMMER]},
		{"key": "bar/h0", "target": T.HEAD, "rows": [R.COLOUR, R.DIMMER]},
		{"key": "bar/h1", "target": T.HEAD, "rows": [R.COLOUR, R.DIMMER]},
		{"key": "bar/h2", "target": T.HEAD, "rows": [R.COLOUR, R.DIMMER]},
		{"key": "spot", "target": T.FIXTURE, "rows": [R.POSITION, R.MOVEMENT, R.DIMMER]},
	]


func _test_show() -> void:
	print("- a show from the structure")
	var show := TimelineGenerator.generate(_sections(), _beats(), 4, 120.0, _tracks(), ["posA", "posB"], "song.mp3")
	ok(show.size() == 8, "content for every timeline")
	var m: Dictionary = show["master"]
	# Master dimmer.
	var md: PackedVector2Array = m["dimmer"]
	ok(md[0] == Vector2(0, 0) and md[md.size() - 1] == Vector2(120, 0), "the master fades in from 0 and out to 0")
	var verse := TimelineTrack.level_at(md, 28.0)
	var chorus := TimelineTrack.level_at(md, 52.0)
	var intro := TimelineTrack.level_at(md, 8.0)
	ok(chorus > verse and verse > intro and is_equal_approx(chorus, 0.25 + 0.75 * (0.9 - 0.2) / 0.75),
		"its level follows the energy (intro %.2f < verse %.2f < chorus %.2f)" % [intro, verse, chorus])
	ok(is_equal_approx(TimelineTrack.level_at(md, 101.0), 1.0), "the loudest section: 100 %")
	# Colour.
	var cs: Array = m["colour"]
	ok(cs.size() == 6 and cs[2]["c0"] == cs[4]["c0"] and cs[1]["c0"] != cs[2]["c0"],
		"a colour per section, the same kind of section alike (both choruses)")
	ok(cs[2]["c0"] != cs[2]["c1"] and cs[1]["c0"] == cs[1]["c1"], "the loudest sections sweep main -> accent; the others hold")
	# Strobe builds: into each chorus, none into the outro.
	var st: Array = m["strobe"]
	ok(st.size() == 4 and is_equal_approx(st[0]["t0"], 36.0) and st[0]["speed"] == TimelineTrack.Strobe.MEDIUM
		and is_equal_approx(st[1]["t0"], 38.0) and is_equal_approx(st[1]["t1"], 40.0) and st[1]["speed"] == TimelineTrack.Strobe.FAST,
		"a strobe build in the two bars before each chorus: medium, then fast (%s)" % str(st))
	ok(not TimelineTrack.span_at(st, 103.0), "none into a quieter section")
	# Positions and movement.
	var pos: Array = m["position"]
	ok(pos.size() == 6 and pos[0]["pos"] == "posA" and pos[1]["pos"] == "posB" and pos[2]["pos"] == "posA",
		"the named positions in turn, a section each")
	var mv: Array = m["movement"]
	ok(mv[2]["fx"] == "figure8" and is_equal_approx(mv[2]["size"], 0.16) and is_equal_approx(mv[2]["period"], 1.0),
		"the loudest: a large figure 8, ½ bar a cycle")
	ok(mv[0]["fx"] == "tilt_sweep" and is_equal_approx(mv[0]["period"], 4.0) and mv[1]["fx"] == "tilt_sweep",
		"the quiet: a small slow tilt sweep, 2 bars a cycle")
	# Fixture dimmers: a beat chase in the choruses.
	var p1: PackedVector2Array = show["par1"]["dimmer"]
	var p2: PackedVector2Array = show["par2"]["dimmer"]
	ok(TimelineTrack.line_defined_at(p1, 41.0) and not TimelineTrack.line_defined_at(p1, 20.0),
		"fixtures: nothing in the quiet sections before (they follow the master)")
	ok(_step_up_at(p1, 40.0) and not _step_up_at(p1, 40.5) and _step_up_at(p1, 42.0),
		"in a chorus: a pulse on every 4th beat for the first fixture (40 s, 42 s)")
	ok(_step_up_at(p2, 40.5) and not _step_up_at(p2, 40.0), "...the next one beat later: a chase")
	ok(is_equal_approx(TimelineTrack.level_at(p1, 72.0), TimelineTrack.level_at(md, 72.0)),
		"between the choruses the fixture's line copies the master's (no dark gap)")
	# Colours: every other fixture the accent; a bar's heads blend.
	ok(show["par1"]["colour"].is_empty() and show["par2"]["colour"].size() == 6, "the first fixture takes the master's colour, the second the accent")
	var h0: Array = show["bar/h0"]["colour"]
	var h2: Array = show["bar/h2"]["colour"]
	ok(h0.size() == 6 and h0[1]["c0"] == cs[1]["c0"] and h2[1]["c0"] != h0[1]["c0"] and show["bar"]["colour"].is_empty(),
		"a multi-head fixture's heads blend main -> accent")
	ok(show["spot"]["position"].is_empty() and show["spot"]["movement"].is_empty(), "positions and movement on the master (fixtures follow it)")
	# Repeatable; a different song, different colours.
	var again := TimelineGenerator.generate(_sections(), _beats(), 4, 120.0, _tracks(), ["posA", "posB"], "song.mp3")
	ok(again["master"]["colour"][2]["c0"] == cs[2]["c0"], "the same song: the same show")
	var other := TimelineGenerator.generate(_sections(), _beats(), 4, 120.0, _tracks(), ["posA", "posB"], "another.mp3")
	ok(other["master"]["colour"][2]["c0"] != cs[2]["c0"], "another song: its colours shifted")


func _step_up_at(line: PackedVector2Array, t: float) -> bool:
	for i in range(line.size() - 1):
		if is_equal_approx(line[i].x, t) and is_equal_approx(line[i + 1].x, t) and line[i + 1].y > line[i].y:
			return true
		if is_equal_approx(line[i].x, t) and i == 0 and line[i].y >= 0.99:
			return true
	return false


func _test_edges() -> void:
	print("- edge cases")
	var show := TimelineGenerator.generate([], PackedFloat32Array(), 4, 60.0,
		[{"key": "master", "target": T.MASTER, "rows": [R.DIMMER, R.POSITION, R.MOVEMENT]}])
	var md: PackedVector2Array = show["master"]["dimmer"]
	ok(md.size() >= 3 and md[md.size() - 1] == Vector2(60, 0), "no structure: the whole song as one section")
	ok(show["master"]["position"].is_empty(), "no named positions: no position segments")
	ok(show["master"]["colour"].is_empty(), "a row the track hasn't got: left empty")
	var flat := [{"start": 0.0, "end": 30.0, "label": "Verse", "energy": 0.5}, {"start": 30.0, "end": 60.0, "label": "Chorus", "energy": 0.5}]
	show = TimelineGenerator.generate(flat, PackedFloat32Array(), 4, 60.0, [{"key": "master", "target": T.MASTER, "rows": [R.DIMMER]}])
	ok(is_equal_approx(TimelineTrack.level_at(show["master"]["dimmer"], 15.0), TimelineTrack.level_at(show["master"]["dimmer"], 45.0)),
		"sections of equal energy: equal levels")
