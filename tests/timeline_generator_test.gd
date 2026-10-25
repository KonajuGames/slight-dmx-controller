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
	_test_phrases()
	_test_patterns()
	_test_variety()
	_test_escalation()
	_test_envelope()
	_test_contrast()
	_test_positions()
	_test_categories()
	_test_head_movers()
	_test_wheel()
	_test_valid()
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


func _beats(n := 240) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	for i in range(n):
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
		{"key": "spot2", "target": T.FIXTURE, "rows": [R.POSITION, R.MOVEMENT, R.DIMMER]},
	]


func _show(variation := 0, seed := "song.mp3") -> Dictionary:
	return TimelineGenerator.generate(_sections(), _beats(), 4, 120.0, _tracks(), ["posA", "posB"], seed, variation)


func _test_show() -> void:
	print("- a show from the structure")
	var show := _show()
	ok(show.size() == 9, "content for every timeline")
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
	# Colour: the master's main colour per section kind (both choruses alike).
	var cs: Array = m["colour"]
	var c1 = _colour_at(cs, 45.0)
	ok(c1 != null and c1 == _colour_at(cs, 85.0) and c1 != _colour_at(cs, 20.0),
		"a palette per kind of section: both choruses start in the same colour, the verse another")
	# Strobe builds: into each chorus, none into the outro.
	var st: Array = m["strobe"]
	ok(TimelineTrack.speed_at(st, 37.0) == TimelineTrack.Strobe.MEDIUM and TimelineTrack.speed_at(st, 38.5) == TimelineTrack.Strobe.FAST
		and TimelineTrack.speed_at(st, 77.0) == TimelineTrack.Strobe.MEDIUM and TimelineTrack.speed_at(st, 78.5) == TimelineTrack.Strobe.FAST,
		"a strobe build in the two bars before each chorus: medium, then fast")
	ok(TimelineTrack.speed_at(st, 30.0) < 0 and TimelineTrack.speed_at(st, 106.0) < 0, "no strobe in the verse or outro")
	# Positions and movement.
	var pos: Array = m["position"]
	ok(not pos.is_empty() and pos.all(func(p): return p["pos"] in ["posA", "posB"]) and is_equal_approx(pos[0]["t0"], 0.0)
		and is_equal_approx(pos[pos.size() - 1]["t1"], 120.0), "named positions across the song")
	var mv: Array = m["movement"]
	var covered := not mv.is_empty()
	for g in mv:
		covered = covered and pos.any(func(p): return p["t0"] <= g["t0"] + 0.001 and p["t1"] >= g["t1"] - 0.001)
	ok(covered, "every movement over a position")
	var quiet := TimelineTrack.movement_segment_at(mv, 8.0)
	var loud := TimelineTrack.movement_segment_at(mv, 50.0)
	ok(quiet["fx"] in ["tilt_sweep", "pan_sweep"] and is_equal_approx(quiet["period"], 16.0) and loud["size"] > quiet["size"]
		and loud["period"] < quiet["period"], "quiet: a small slow sweep; loud: bigger and faster")
	# Fixture dimmers.
	var p1: PackedVector2Array = show["par1"]["dimmer"]
	var p2: PackedVector2Array = show["par2"]["dimmer"]
	var brighter := -1.0
	for span in [Vector2(0, 40), Vector2(64, 80), Vector2(104, 120)]:
		var t: float = span.x
		while t < span.y:
			if TimelineTrack.line_defined_at(p1, t) and TimelineTrack.level_at(p1, t) > TimelineTrack.level_at(md, t) + 0.02:
				brighter = t
			t += 0.1
	ok(brighter < 0.0, "fixtures in the quieter sections: never brighter than the master (%.1f s)" % brighter)
	ok(_peak(p1, 40.0, 64.0) > 0.99 and _differs(p1, p2, 40.0, 64.0), "in a chorus: full-level hits, the fixtures not all alike")
	ok(_is_sorted(p1) and _is_sorted(p2), "the lines in time order")
	# Repeatable; a different song, different colours.
	ok(str(_show()) == str(show), "the same song and variation: the same show")
	ok(_colour_at(_show(0, "another.mp3")["master"]["colour"], 45.0) != c1, "another song: other colours")


func _test_phrases() -> void:
	print("- phrases")
	var secs := TimelineGenerator._normalised([{"start": 0.0, "end": 64.0, "label": "Verse", "energy": 0.5}], 64.0)
	var bars := PackedFloat32Array()
	for i in range(32):
		bars.append(i * 2.0)
	var ph := TimelineGenerator._phrases(secs, bars, 2.0)
	ok(ph.size() == 4 and is_equal_approx(ph[1]["t0"], 16.0) and is_equal_approx(ph[3]["t1"], 64.0),
		"a 32-bar section: four 8-bar phrases")
	ok((ph[0]["bars"] as PackedFloat32Array).size() == 8 and is_equal_approx(ph[0]["fill"], 14.0), "...each knowing its bars and its last bar (a fill's place)")
	secs = TimelineGenerator._normalised([{"start": 0.0, "end": 22.0, "label": "Verse", "energy": 0.5}], 22.0)
	ph = TimelineGenerator._phrases(secs, bars, 2.0)
	ok(ph.size() == 1, "an 11-bar section: one phrase (a 3-bar leftover joins it)")
	# Bar lines from the bar phase: beat 1 of each bar.
	var bs := TimelineGenerator._bar_starts(_beats(80), 4, 1)
	ok(is_equal_approx(bs[0], 0.5) and is_equal_approx(bs[1], 2.5), "bars start on the bar phase's beat (0.5 s, 2.5 s — not 0 s)")
	ph = TimelineGenerator._phrases(TimelineGenerator._normalised([{"start": 0.5, "end": 40.5, "label": "Verse", "energy": 0.5}], 40.5), bs, 2.0)
	ok(ph.size() == 3 and is_equal_approx(ph[1]["t0"], 16.5) and is_equal_approx(ph[2]["t0"], 32.5), "...and the phrases cut on them (20 bars: 8 + 8 + 4)")


func _test_patterns() -> void:
	print("- patterns")
	var seq: Array = []
	for j in range(6):
		for i in range(6):
			if TimelineGenerator._step_on("chase", j, i, 6):
				seq.append(i)
	ok(seq == [0, 1, 2, 3, 4, 5], "a chase travels across all the fixtures (six, not four)")
	seq = []
	for j in range(5):
		for i in range(3):
			if TimelineGenerator._step_on("ping_pong", j, i, 3):
				seq.append(i)
	ok(seq == [0, 1, 2, 1, 0], "ping-pong: there and back")
	var lit0: Array = []
	var lit1: Array = []
	for i in range(4):
		if TimelineGenerator._step_on("centre_out", 0, i, 4):
			lit0.append(i)
		if TimelineGenerator._step_on("centre_out", 1, i, 4):
			lit1.append(i)
	ok(lit0 == [1, 2] and lit1 == [0, 3], "centre out: the middle pair, then the outer pair")
	# Bar hits on the real bar lines.
	var ctx := {"beats": _beats(40), "beat_len": 0.5, "bar_len": 2.0, "per_bar": 4, "bar_phase": 1,
		"master": PackedVector2Array([Vector2(0, 1), Vector2(20, 1)])}
	var line := TimelineGenerator._pattern("bar_hits", 0.0, 8.0, 0, 2, {"tier": 3, "sparkle": []}, ctx)
	ok(_step_up_at(line, 0.5) and _step_up_at(line, 2.5) and not _step_up_at(line, 2.0), "bar hits land on beat 1 (bar phase 1: 0.5 s, 2.5 s)")
	line = TimelineGenerator._pattern("follow", 2.0, 6.0, 0, 2, {"tier": 0, "sparkle": []}, ctx)
	ok(line.size() == 2 and is_equal_approx(line[0].y, 1.0), "follow: the master's line")
	line = TimelineGenerator._pattern("breathe", 0.0, 8.0, 0, 2, {"tier": 1, "sparkle": []}, ctx)
	ok(_peak(line, 0.0, 8.0) <= 1.0 and _low(line, 0.0, 8.0) > 0.2 and _peak(line, 0.0, 8.0) - _low(line, 0.0, 8.0) > 0.5,
		"breathe: a slow swell that never goes dark")
	var a := TimelineGenerator._pattern("solo", 0.0, 8.0, 0, 2, {"tier": 1, "sparkle": []}, ctx)
	var b := TimelineGenerator._pattern("solo", 0.0, 8.0, 1, 2, {"tier": 1, "sparkle": []}, ctx)
	ok(TimelineTrack.level_at(a, 0.5) > TimelineTrack.level_at(b, 0.5) and TimelineTrack.level_at(b, 2.5) > TimelineTrack.level_at(a, 2.5),
		"solo: one fixture at a time, a bar each")
	# A movement's phase: where in its cycle it starts.
	var sg := {"t0": 0.0, "t1": 8.0, "fx": "circle", "period": 2.0, "size": 0.1}
	var half := sg.duplicate()
	half["phase"] = 0.5
	ok(TimelineTrack.movement_offset(half, 0.0).is_equal_approx(TimelineTrack.movement_offset(sg, 1.0)), "a movement's phase starts it that far into its cycle")
	var back := MusicTimeline._moves_from(MusicTimeline._moves_to([half, sg]))
	ok(is_equal_approx(back[0]["phase"], 0.5) and not back[1].has("phase"), "...saved and loaded (only where it isn't 0)")


func _test_variety() -> void:
	print("- variety")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var pk := TimelineGenerator._Picker.new(rng)
	var picks: Array = []
	for i in range(200):
		picks.append(pk.pick(TimelineGenerator.DIM_PATTERNS[3]))
	var repeat := false
	for i in range(2, picks.size()):
		repeat = repeat or picks[i] == picks[i - 1] or picks[i] == picks[i - 2]
	var seen := {}
	for p in picks:
		seen[p] = true
	ok(not repeat and seen.size() == TimelineGenerator.DIM_PATTERNS[3].size(), "picks never repeat the last two, and use every pattern")
	# A long loud section keeps changing.
	var long := [{"start": 0.0, "end": 16.0, "label": "Intro", "energy": 0.1}, {"start": 16.0, "end": 144.0, "label": "Drop", "energy": 1.0}]
	var secs := TimelineGenerator._normalised(long, 144.0)
	TimelineGenerator._mark_repeats(secs)
	var bars := PackedFloat32Array()
	for i in range(72):
		bars.append(i * 2.0)
	var ph := TimelineGenerator._phrases(secs, bars, 2.0)
	var plan := TimelineGenerator._plan(secs, ph, rng, 4, 0.5)
	var dims := {}
	var colours := {}
	var moves := {}
	for p in range(1, plan.size()):
		dims[plan[p]["dim"]] = true
		colours[plan[p]["colour"]] = true
		moves[plan[p]["move"]] = true
	ok(ph.size() == 9 and dims.size() >= 4 and colours.size() >= 3 and moves.size() >= 2,
		"a 64-bar drop: 8 phrases with %d dimmer patterns, %d colour modes, %d movements" % [dims.size(), colours.size(), moves.size()])
	# Variations.
	var v0 := _show(0)
	var v1 := _show(1)
	ok(str(v0["par1"]["dimmer"]) != str(v1["par1"]["dimmer"]), "another variation: another show")
	ok(str(_show(1)) == str(v1), "...the same each time")


func _test_escalation() -> void:
	print("- repeats build")
	var secs := TimelineGenerator._normalised(_sections(), 120.0)
	TimelineGenerator._mark_repeats(secs)
	ok(secs[2]["rep"] == 0 and is_equal_approx(secs[2]["lift"], 0.0) and secs[4]["rep"] == 1 and is_equal_approx(secs[4]["lift"], 1.0),
		"the second chorus: lifted")
	ok(secs[4]["finale"] and not secs[2]["finale"] and secs.filter(func(s): return s["finale"]).size() == 1,
		"the last chorus is the finale (only it)")
	var single := TimelineGenerator._normalised([{"start": 0.0, "end": 10.0, "label": "Verse", "energy": 0.2}, {"start": 10.0, "end": 20.0, "label": "Drop", "energy": 0.9}], 20.0)
	TimelineGenerator._mark_repeats(single)
	ok(single[1]["finale"], "no returning loud kind: the loudest section is the finale")
	var show := _show()
	var m: Dictionary = show["master"]
	var mv1 := TimelineTrack.movement_segment_at(m["movement"], 45.0)
	var mv2 := TimelineTrack.movement_segment_at(m["movement"], 85.0)
	ok(mv2["size"] > mv1["size"] and mv2["fx"] in ["figure8", "circle", "pan_sweep"], "the finale moves bigger (%.3f > %.3f)" % [mv2["size"], mv1["size"]])
	var s1 := TimelineTrack.movement_segment_at(show["spot"]["movement"], 85.0)
	var s2 := TimelineTrack.movement_segment_at(show["spot2"]["movement"], 85.0)
	ok(not s1.is_empty() and not s2.is_empty() and s1["fx"] == mv2["fx"] and s1.get("phase", 0.0) != s2.get("phase", 0.0),
		"...its movers fanned out across one shape")
	ok(TimelineTrack.speed_at(m["strobe"], 95.5) == TimelineTrack.Strobe.FAST and TimelineTrack.speed_at(m["strobe"], 103.5) == TimelineTrack.Strobe.FAST
		and TimelineTrack.speed_at(m["strobe"], 90.0) < 0, "...strobe hits ending each of its phrases")
	# The build into the finale stops a beat early on a blackout.
	var md: PackedVector2Array = m["dimmer"]
	ok(TimelineTrack.speed_at(m["strobe"], 79.7) < 0 and TimelineTrack.level_at(md, 79.75) < 0.001 and TimelineTrack.level_at(md, 80.01) > 0.9,
		"a beat's blackout before the finale, then straight up")
	var p1: PackedVector2Array = show["par1"]["dimmer"]
	ok(not TimelineTrack.line_defined_at(p1, 79.75) or TimelineTrack.level_at(p1, 79.75) < 0.001, "...the fixtures dark too")


## Over many variations: every row well-formed.
func _test_valid() -> void:
	print("- well-formed over 30 variations")
	var bad := ""
	for v in range(30):
		var show := _show(v, "valid.mp3") if v % 2 == 0 else TimelineGenerator.generate(_sections(), _beats(), 4, 120.0,
			_tracks(), _spread_positions(), "valid.mp3", v, 0, _env())
		for k in show:
			var c: Dictionary = show[k]
			var line: PackedVector2Array = c["dimmer"]
			if not _is_sorted(line):
				bad = "%s dimmer (variation %d)" % [k, v]
			for p in line:
				if p.y < -0.001 or p.y > 1.001:
					bad = "%s dimmer level %f" % [k, p.y]
			for row in ["colour", "strobe", "position", "movement"]:
				var segs: Array = c[row]
				for i in range(segs.size()):
					if segs[i]["t1"] <= segs[i]["t0"] or (i > 0 and segs[i]["t0"] < segs[i - 1]["t1"] - 0.0001):
						bad = "%s %s (variation %d)" % [k, row, v]
	ok(bad == "", "lines in time order, levels 0..1, segments ordered and not overlapping %s" % bad)


## An envelope over the 120 s song: loudness by section energy, with the
## first chorus dropping out from 48 s to 52 s and the second verse bar
## (18-20 s) quieter; bass strong on every other beat; bright 84-92 s.
func _env() -> Dictionary:
	var peak := PackedFloat32Array()
	var lo := PackedFloat32Array()
	var hi := PackedFloat32Array()
	for c in range(1200):
		var t := c * 0.1
		var e := 0.5
		for sec in _sections():
			if t >= sec["start"] and t < sec["end"]:
				e = sec["energy"]
		if t >= 48.0 and t < 52.0:
			e = 0.1
		if t >= 18.0 and t < 20.0:
			e *= 0.6
		peak.append(e)
		lo.append(0.8 if fmod(t, 1.0) < 0.5 else 0.2)
		hi.append(0.9 if t >= 84.0 and t < 92.0 else 0.3)
	return {"peak": peak, "lo": lo, "hi": hi}


func _spread_positions() -> Array:
	return [{"id": "wide", "spread": 0.4}, {"id": "narrow", "spread": 0.0}, {"id": "mid", "spread": 0.2}, {"id": "wider", "spread": 0.3}]


func _test_envelope() -> void:
	print("- the envelope")
	var show := TimelineGenerator.generate(_sections(), _beats(), 4, 120.0, _tracks(), ["posA", "posB"], "song.mp3", 0, 0, _env())
	var m: Dictionary = show["master"]
	var md: PackedVector2Array = m["dimmer"]
	ok(TimelineTrack.level_at(md, 18.5) < TimelineTrack.level_at(md, 22.5) - 0.02, "the master rides the loudness: lower in a quieter bar (%.2f < %.2f)"
		% [TimelineTrack.level_at(md, 18.5), TimelineTrack.level_at(md, 22.5)])
	var none := _show()
	ok(TimelineTrack.level_at(none["master"]["dimmer"], 18.5) == TimelineTrack.level_at(none["master"]["dimmer"], 22.5), "...without one, flat across the section")
	# A dip inside the chorus: its own phrase, the return too.
	var secs := TimelineGenerator._normalised(_sections(), 120.0)
	var en := TimelineGenerator._envelope(_env(), 120.0)
	var bars := TimelineGenerator._bar_starts(_beats(), 4, 0)
	var evs := TimelineGenerator._events(secs, bars, 2.0, en)
	ok(evs.has(2) and evs[2].any(func(e): return e["kind"] == "dip" and is_equal_approx(e["t"], 48.0))
		and evs[2].any(func(e): return e["kind"] == "drop" and is_equal_approx(e["t"], 52.0)), "the chorus drops out at 48 s and comes back at 52 s")
	var ph := TimelineGenerator._phrases(secs, bars, 2.0, evs)
	var dip: Array = ph.filter(func(p): return is_equal_approx(p["t0"], 48.0))
	var back: Array = ph.filter(func(p): return is_equal_approx(p["t0"], 52.0))
	ok(dip.size() == 1 and dip[0]["dip"] and back.size() == 1 and back[0]["drop"], "...each starting a phrase (the dip marked, the return too)")
	ok(TimelineTrack.speed_at(m["strobe"], 52.2) == TimelineTrack.Strobe.FAST and TimelineTrack.speed_at(m["strobe"], 53.0) < 0,
		"a strobe hit on the beat it comes back")
	ok(TimelineTrack.level_at(md, 50.0) < TimelineTrack.level_at(md, 44.0), "the master dips with it")
	# The outro (104-120 s) tailing off: the master follows it down.
	var fading := _env()
	for c in range(1040, 1200):
		fading["peak"][c] = 0.2 * (1.0 - (c - 1040) / 160.0)
	var fd: PackedVector2Array = TimelineGenerator.generate(_sections(), _beats(), 4, 120.0, _tracks(), ["posA", "posB"],
		"song.mp3", 0, 0, fading)["master"]["dimmer"]
	var o0 := TimelineTrack.level_at(fd, 105.0)
	var o1 := TimelineTrack.level_at(fd, 112.0)
	var o2 := TimelineTrack.level_at(fd, 117.0)
	ok(o1 < o0 * 0.7 and o2 < o0 * 0.35, "the master tails off with the outro (%.2f, %.2f, %.2f)" % [o0, o1, o2])
	# Bass accents: hits follow the bass.
	var ctx := {"beats": _beats(40), "beat_len": 0.5, "bar_len": 2.0, "per_bar": 4, "bar_phase": 0,
		"master": PackedVector2Array([Vector2(0, 1), Vector2(20, 1)]), "env": en}
	var line := TimelineGenerator._pattern("every_beat", 0.0, 4.0, 0, 2, {"tier": 3, "sparkle": []}, ctx)
	ok(_level_after(line, 1.0) > 0.99 and absf(_level_after(line, 1.5) - (0.55 + 0.45 * 0.25)) < 0.02,
		"every beat: strong bass at full, weak at %.2f" % _level_after(line, 1.5))
	# Sparkle: thicker where it's brighter.
	var order: Array = []
	for j in range(40):
		order.append([0, 1, 2, 3, 4, 5, 6, 7, 8])
	var bright := 0
	var dull := 0
	for i in range(9):
		var sp := TimelineGenerator._pattern("sparkle", 84.0, 86.0, i, 9, {"tier": 3, "sparkle": order}, _ctx_at(84.0, en))
		var sq := TimelineGenerator._pattern("sparkle", 60.0, 62.0, i, 9, {"tier": 3, "sparkle": order}, _ctx_at(60.0, en))
		bright += 1 if _level_after(sp, 84.0) > 0.01 else 0
		dull += 1 if _level_after(sq, 60.0) > 0.01 else 0
	ok(bright > dull and dull >= 1, "sparkle: %d fixtures lit where it's bright, %d where it isn't" % [bright, dull])
	var pool := TimelineGenerator._weighted(TimelineGenerator.DIM_PATTERNS[2], {"lo": 1.5, "hi": 0.8}, 2)
	var w := {}
	for o in pool:
		w[o[0]] = o[1]
	ok(w["bar_hits"] == 4.0 and w["half_time"] == 4.0 and w["wave"] == 2.0 and w.has("every_beat"), "a bass-heavy phrase favours the beat patterns")


func _ctx_at(t: float, en: Dictionary) -> Dictionary:
	var b := PackedFloat32Array()
	for i in range(8):
		b.append(t + i * 0.5)
	return {"beats": b, "beat_len": 0.5, "bar_len": 2.0, "per_bar": 4, "bar_phase": 0,
		"master": PackedVector2Array([Vector2(0, 1), Vector2(120, 1)]), "env": en}


func _test_contrast() -> void:
	print("- contrast")
	var secs := TimelineGenerator._normalised(_sections(), 120.0)
	ok(secs[3]["breakdown"] and not secs[1]["breakdown"] and not secs[5]["breakdown"], "the quiet bridge between the choruses: a breakdown")
	var show := _show()
	var m: Dictionary = show["master"]
	var md: PackedVector2Array = m["dimmer"]
	var e: float = secs[3]["e"]
	ok(is_equal_approx(TimelineTrack.level_at(md, 72.0), 0.6 * (0.25 + 0.75 * e)), "...darker")
	var c: Color = _colour_at(m["colour"], 70.0)
	ok(absf(fposmod(c.h - TimelineGenerator.COOL_HUE + 0.5, 1.0) - 0.5) < 0.16, "...cooler (hue %.2f)" % c.h)
	var bars := TimelineGenerator._bar_starts(_beats(), 4, 0)
	TimelineGenerator._mark_repeats(secs)
	var ph := TimelineGenerator._phrases(secs, bars, 2.0)
	var rng := RandomNumberGenerator.new()
	var plan := TimelineGenerator._plan(secs, ph, rng, 5, 0.5)
	var calm := true
	for p in range(ph.size()):
		if ph[p]["s"] == 3:
			calm = calm and plan[p]["dim"] in ["solo_dark", "duo", "breathe_slow"] and plan[p]["fill"] == "" and plan[p]["fan"] == ""
	ok(calm, "...one or two fixtures at a time or slow swells, no fills, no fanning")
	var dctx := {"beats": _beats(20), "beat_len": 0.5, "bar_len": 2.0, "per_bar": 4, "bar_phase": 0,
		"master": PackedVector2Array([Vector2(0, 1), Vector2(10, 1)])}
	var a := TimelineGenerator._pattern("duo", 0.0, 8.0, 0, 4, {"tier": 0, "sparkle": []}, dctx)
	var b := TimelineGenerator._pattern("duo", 0.0, 8.0, 1, 4, {"tier": 0, "sparkle": []}, dctx)
	ok(TimelineTrack.level_at(a, 1.0) > 0.99 and TimelineTrack.level_at(b, 1.0) < 0.01 and TimelineTrack.level_at(b, 5.0) > 0.99,
		"duo: a pair lit, two bars each, the rest dark")
	# The riser into the first chorus (the verse's last four bars).
	ok(TimelineTrack.level_at(md, 38.5) > TimelineTrack.level_at(md, 33.0) + 0.3 and TimelineTrack.level_at(md, 33.0) < 0.7,
		"a riser: the master climbs to full into the build (%.2f -> %.2f)" % [TimelineTrack.level_at(md, 33.0), TimelineTrack.level_at(md, 38.5)])
	var early := 0
	var late := 0
	for k in ["par1", "par2", "bar", "spot", "spot2"]:
		early += _step_ups(show[k]["dimmer"], 32.0, 34.0)
		late += _step_ups(show[k]["dimmer"], 38.0, 39.5)
	ok(late >= 2 * early and early >= 3, "...the chase speeding up (%d hits in its first bar, %d in its last)" % [early, late])
	var c0: Color = TimelineTrack.segment_colour_at(m["colour"], 32.1)
	var c1: Color = TimelineTrack.segment_colour_at(m["colour"], 39.4)
	ok(c1.s < c0.s - 0.3, "...the colour fading towards white (saturation %.2f -> %.2f)" % [c0.s, c1.s])


func _test_positions() -> void:
	print("- positions by energy")
	ok(TimelineGenerator._ranked(_spread_positions()) == ["narrow", "mid", "wider", "wide"], "ranked narrow -> wide by spread")
	ok(TimelineGenerator._ranked(["b", "a"]) == ["b", "a"], "...ids alone keep their order")
	var ranks := TimelineGenerator._energy_ranks(TimelineGenerator._normalised(_sections(), 120.0))
	ok(ranks == [0.0, 2.0 / 4, 3.0 / 4, 1.0 / 4, 1.0, 0.0], "sections ranked by energy, evenly spaced: %s" % [ranks])
	# Over many songs, every position gets a fair share of the time.
	var time := {}
	for v in range(30):
		var sh := TimelineGenerator.generate(_sections(), _beats(), 4, 120.0, _tracks(), ["A", "B", "C", "D", "E"], "fair%d.mp3" % v, v)
		for sp in sh["master"]["position"]:
			time[sp["pos"]] = time.get(sp["pos"], 0.0) + float(sp["t1"]) - float(sp["t0"])
	var share: Array = time.values().map(func(x): return x / (30 * 120.0))
	ok(time.size() == 5 and share.min() > 0.12 and share.max() < 0.28, "every position used about as much: %s" % [time])
	ok(is_equal_approx(MusicTimeline._spread({"a": Vector2(0.4, 0.5), "b": Vector2(0.6, 0.5)}), 0.1) and MusicTimeline._spread({"a": Vector2(0.4, 0.5)}) == 0.0,
		"a position's spread: its points' mean distance from their middle")
	var show := TimelineGenerator.generate(_sections(), _beats(), 4, 120.0, _tracks(), _spread_positions(), "song.mp3")
	var pos: Array = show["master"]["position"]
	ok(TimelineTrack.position_id_at(pos, 70.0) == "narrow", "the breakdown: the narrowest")
	ok(TimelineTrack.position_id_at(pos, 85.0) in ["wider", "wide"] and TimelineTrack.position_id_at(pos, 100.0) in ["wider", "wide"],
		"the finale: the widest")
	ok(TimelineTrack.position_id_at(pos, 41.0) != TimelineTrack.position_id_at(pos, 57.0), "a loud section: a new one each phrase")
	var changes := 0
	for sg in pos:
		if sg["t0"] > 16.0 and sg["t0"] < 40.0:
			changes += 1
	ok(changes == 0 and TimelineTrack.position_id_at(pos, 5.0) in ["narrow", "mid"], "a quieter one: one per section (the intro narrow)")


func _level_after(line: PackedVector2Array, t: float) -> float:
	return TimelineTrack.level_at(line, t + 0.0001)


func _step_ups(line: PackedVector2Array, a: float, b: float) -> int:
	var n := 0
	for i in range(1, line.size()):
		if line[i].x >= a and line[i].x < b and is_equal_approx(line[i].x, line[i - 1].x) and line[i].y > line[i - 1].y + 0.05:
			n += 1
	return n


func _test_edges() -> void:
	print("- edge cases")
	var show := TimelineGenerator.generate([], PackedFloat32Array(), 4, 60.0,
		[{"key": "master", "target": T.MASTER, "rows": [R.DIMMER, R.POSITION, R.MOVEMENT]}])
	var md: PackedVector2Array = show["master"]["dimmer"]
	ok(md.size() >= 3 and md[md.size() - 1] == Vector2(60, 0), "no structure: the whole song as one section")
	ok(show["master"]["position"].is_empty(), "no named positions: no position segments")
	ok(show["master"]["movement"].is_empty(), "...and no movement (it needs a position to move around)")
	show = TimelineGenerator.generate([], PackedFloat32Array(), 4, 60.0,
		[{"key": "master", "target": T.MASTER, "rows": [R.DIMMER, R.MOVEMENT]}], ["posA"])
	ok(show["master"]["movement"].is_empty(), "no position row: no movement either")
	ok(show["master"]["colour"].is_empty(), "a row the track hasn't got: left empty")
	var flat := [{"start": 0.0, "end": 30.0, "label": "Verse", "energy": 0.5}, {"start": 30.0, "end": 60.0, "label": "Chorus", "energy": 0.5}]
	show = TimelineGenerator.generate(flat, PackedFloat32Array(), 4, 60.0, [{"key": "master", "target": T.MASTER, "rows": [R.DIMMER]}])
	ok(is_equal_approx(TimelineTrack.level_at(show["master"]["dimmer"], 15.0), TimelineTrack.level_at(show["master"]["dimmer"], 45.0)),
		"sections of equal energy: equal levels")
	show = TimelineGenerator.generate(_sections(), _beats(), 4, 120.0, [{"key": "solo", "target": T.FIXTURE, "rows": [R.DIMMER, R.COLOUR]}])
	ok(show.size() == 1 and _is_sorted(show["solo"]["dimmer"]), "no master timeline, one fixture: still a show")


## A rig with every category: washes in two groups (and one secondary),
## movers (one secondary), two four-head bars.
func _cat_tracks() -> Array:
	var out: Array = [
		{"key": "master", "target": T.MASTER, "rows": TimelineTrack.ROW_ORDER.duplicate()},
		{"key": "w1", "target": T.FIXTURE, "rows": [R.COLOUR, R.DIMMER], "category": "Primary Wash", "group": 1},
		{"key": "w2", "target": T.FIXTURE, "rows": [R.COLOUR, R.DIMMER], "category": "Primary Wash", "group": 2},
		{"key": "w3", "target": T.FIXTURE, "rows": [R.COLOUR, R.DIMMER], "category": "Primary Wash", "group": 2},
		{"key": "ws", "target": T.FIXTURE, "rows": [R.COLOUR, R.DIMMER], "category": "Secondary Wash", "group": 1},
		{"key": "m1", "target": T.FIXTURE, "rows": [R.POSITION, R.MOVEMENT, R.DIMMER], "category": "Primary Mover", "group": 1},
		{"key": "m2", "target": T.FIXTURE, "rows": [R.POSITION, R.MOVEMENT, R.DIMMER], "category": "Primary Mover", "group": 1},
		{"key": "ms", "target": T.FIXTURE, "rows": [R.POSITION, R.MOVEMENT, R.DIMMER], "category": "Secondary Mover", "group": 1},
	]
	for b in ["b1", "b2"]:
		out.append({"key": b, "target": T.FIXTURE, "rows": [R.COLOUR, R.DIMMER], "category": "Primary Multi-cell", "group": 1})
		for h in range(4):
			out.append({"key": "%s/h%d" % [b, h], "target": T.HEAD, "rows": [R.COLOUR, R.DIMMER]})
	return out


func _cat_show(variation: int) -> Dictionary:
	return TimelineGenerator.generate(_sections(), _beats(), 4, 120.0, _cat_tracks(), ["posA", "posB"], "cats.mp3", variation)


func _test_categories() -> void:
	print("- fixture categories and groups")
	var plain: Array = _tracks()
	ok(TimelineGenerator._role_of(plain[1], []) == ["wash", 1] and TimelineGenerator._role_of(plain[7], []) == ["mover", 1]
		and TimelineGenerator._role_of(plain[3], [plain[4], plain[5], plain[6]]) == ["multi", 1],
		"without categories: a par's a wash, a spot a mover, a bar of heads a multi-cell")
	ok(TimelineGenerator._role_of({"rows": [R.COLOUR], "category": "Secondary Mover"}, []) == ["mover", 2],
		"a category overrides the rows")
	var sctx := _ctx_at(0.0, {})
	var lit := func(i: int, t: float) -> bool:
		return TimelineTrack.level_at(TimelineGenerator._pattern("stack", 0.0, 2.0, i, 4, {"tier": 3, "sparkle": []}, sctx), t) > 0.5
	ok(lit.call(0, 0.1) and not lit.call(1, 0.1) and lit.call(0, 1.6) and lit.call(3, 1.6) and not lit.call(3, 1.1),
		"stack: one more head lit each beat, the first held throughout")

	var shows: Array = []
	for v in range(10):
		shows.append(_cat_show(v))
	var s0: Dictionary = shows[0]
	ok(s0.has("w1") and s0.has("b1/h3") and s0.has("ms"), "every track filled")

	# Multi-cells: their heads carry the patterns, the fixture follows.
	var heads_differ := false
	var bars_empty := true
	for sh in shows:
		heads_differ = heads_differ or _differs(sh["b1/h0"]["dimmer"], sh["b1/h3"]["dimmer"], 40.0, 64.0)
		bars_empty = bars_empty and sh["b1"]["dimmer"].is_empty()
	ok(heads_differ, "a multi-cell's heads play patterns across them")
	ok(bars_empty, "...not on the fixture's own dimmer")
	var head_colours := false
	for sh in shows:
		var c0 = _colour_at(sh["b1/h0"]["colour"], 44.0)
		var c3 = _colour_at(sh["b1/h3"]["colour"], 44.0)
		head_colours = head_colours or (c0 != null and c3 != null and c0 != c3)
	ok(head_colours, "...and colours across them")

	# Secondary: in support, below the primaries — then together in the finale.
	var supported := false
	for sh in shows:
		if _peak(sh["ws"]["dimmer"], 40.0, 56.0) <= TimelineGenerator.SUPPORT_LEVEL + 0.01 and _peak(sh["w1"]["dimmer"], 40.0, 56.0) >= 0.95:
			supported = true
	ok(supported, "a secondary wash supports the primaries, under them")
	var calm_ok := true
	for sh in shows:
		var m := _peak(sh["master"]["dimmer"], 16.0, 30.0)
		calm_ok = calm_ok and _peak(sh["ws"]["dimmer"], 16.0, 30.0) <= TimelineGenerator.SUPPORT_LEVEL * m + 0.02
	ok(calm_ok, "...never over its share of the master outside a riser or the finale")
	var together := true
	for sh in shows:
		together = together and _peak(sh["ws"]["dimmer"], 80.0, 104.0) >= 0.95
	ok(together, "...and at full with them in the finale")
	var accent := true
	for sh in shows:
		var c = _colour_at(sh["ws"]["colour"], 20.0)
		accent = accent and c != null and c != _colour_at(sh["master"]["colour"], 20.0)
	ok(accent, "a secondary wash in the palette's other colour")

	# Movers: secondary ones answer the primaries' movement.
	var answered := false
	for sh in shows:
		for mv in sh["ms"]["movement"]:
			var main = null
			for m in sh["master"]["movement"]:
				if float(m["t0"]) <= float(mv["t0"]) + 0.001 and float(m["t1"]) > float(mv["t0"]):
					main = m
			if main != null and (is_equal_approx(float(mv.get("phase", 0.0)), 0.5) or String(mv["fx"]) == "none"
					or float(mv["period"]) > float(main["period"]) + 0.001):
				answered = true
	ok(answered, "a secondary mover mirrors, follows slower or holds against the primaries")

	# Category groups: a group's fixtures step together.
	var grouped := false
	for sh in shows:
		for a in [40.0, 56.0, 80.0, 96.0]:
			if not _differs(sh["w2"]["dimmer"], sh["w3"]["dimmer"], a, a + 8.0) \
					and _differs(sh["w1"]["dimmer"], sh["w2"]["dimmer"], a, a + 8.0):
				grouped = true
	ok(grouped, "fixtures in one category group step together, another group apart")

	# All valid.
	var sorted := true
	for sh in shows:
		for k in sh:
			sorted = sorted and _is_sorted(sh[k]["dimmer"])
	ok(sorted, "every line in time order")
	var same := _cat_show(3)
	ok(str(same) == str(shows[3]), "the same variation, the same show")


## A rig with two three-head movers, a plain mover and two washes.
func _head_mover_tracks() -> Array:
	var out: Array = [
		{"key": "master", "target": T.MASTER, "rows": TimelineTrack.ROW_ORDER.duplicate()},
		{"key": "w1", "target": T.FIXTURE, "rows": [R.COLOUR, R.DIMMER]},
		{"key": "w2", "target": T.FIXTURE, "rows": [R.COLOUR, R.DIMMER]},
		{"key": "spot", "target": T.FIXTURE, "rows": [R.POSITION, R.MOVEMENT, R.DIMMER]},
	]
	for m in ["mh1", "mh2"]:
		out.append({"key": m, "target": T.FIXTURE, "rows": [R.POSITION, R.MOVEMENT, R.COLOUR, R.DIMMER]})
		for h in range(3):
			out.append({"key": "%s/h%d" % [m, h], "target": T.HEAD, "rows": [R.COLOUR, R.DIMMER]})
	return out


func _test_head_movers() -> void:
	print("- movers with several heads")
	var tracks := _head_mover_tracks()
	ok(TimelineGenerator._role_of(tracks[4], [tracks[5], tracks[6], tracks[7]]) == ["mover", 1],
		"a moving fixture with several heads is a mover")
	var shows: Array = []
	for v in range(10):
		shows.append(TimelineGenerator.generate(_sections(), _beats(), 4, 120.0, tracks, ["posA", "posB"], "heads.mp3", v))
	var moved := false
	var fixture_lines := false
	var cells := false
	var as_one := false
	var head_colours := false
	var sorted := true
	for sh in shows:
		moved = moved or not sh["mh1"]["movement"].is_empty()
		fixture_lines = fixture_lines or not sh["mh1"]["dimmer"].is_empty()
		for a in range(0, 112, 8):
			var h0: PackedVector2Array = sh["mh1/h0"]["dimmer"]
			var h2: PackedVector2Array = sh["mh1/h2"]["dimmer"]
			if _differs(h0, h2, a, a + 8.0):
				cells = true
			elif h0.size() >= 2 and h0[0].x <= a and h0[h0.size() - 1].x >= a + 8.0 \
					and not _differs(h0, sh["mh1"]["dimmer"], a, a + 8.0) and _differs(sh["mh1"]["dimmer"], sh["master"]["dimmer"], a, a + 8.0):
				as_one = true
			var c0 = _colour_at(sh["mh1/h0"]["colour"], a + 1.0)
			var c2 = _colour_at(sh["mh1/h2"]["colour"], a + 1.0)
			head_colours = head_colours or (c0 != null and c2 != null and c0 != c2)
		for k in sh:
			sorted = sorted and _is_sorted(sh[k]["dimmer"])
	ok(moved, "a multi-head mover still moves (fanned with the movers)")
	ok(fixture_lines, "...and plays the movers' patterns on its own dimmer")
	ok(cells, "its heads sometimes play patterns across them, as cells")
	ok(as_one, "...and around those, the mover's pattern together")
	ok(head_colours, "...and colours across them")
	ok(sorted, "every line in time order")
	var again := TimelineGenerator.generate(_sections(), _beats(), 4, 120.0, tracks, ["posA", "posB"], "heads.mp3", 4)
	ok(str(again) == str(shows[4]), "the same variation, the same show")


func _test_wheel() -> void:
	print("- colour wheel fixtures")
	var wheel := [Color.WHITE, Color(1, 0, 0), Color(0, 1, 0), Color(0, 0, 1), Color(1, 1, 0)]
	var tracks := [
		{"key": "master", "target": T.MASTER, "rows": TimelineTrack.ROW_ORDER.duplicate()},
		{"key": "par", "target": T.FIXTURE, "rows": [R.COLOUR, R.DIMMER]},
		{"key": "spot", "target": T.FIXTURE, "rows": [R.POSITION, R.MOVEMENT, R.COLOUR, R.DIMMER], "wheel": wheel},
	]
	var only := true
	var solid := true
	var changes := true
	for v in range(6):
		var show := TimelineGenerator.generate(_sections(), _beats(), 4, 120.0, tracks, ["posA"], "wheel.mp3", v)
		var segs: Array = show["spot"]["colour"]
		var seen := {}
		for sg in segs:
			only = only and sg["c0"] in wheel and sg["c1"] in wheel
			solid = solid and sg["c0"] == sg["c1"]
			seen[sg["c0"]] = true
		changes = changes and seen.size() >= 2 and float(segs[0]["t0"]) <= 0.01 and float(segs[segs.size() - 1]["t1"]) >= 119.9
	ok(only, "a wheel fixture's colour row only has its wheel's colours")
	ok(solid, "...each held (a wheel turns, it can't fade)")
	ok(changes, "...covering the song and changing through it")


func _colour_at(segs: Array, t: float):
	for sg in segs:
		if t >= sg["t0"] and t < sg["t1"]:
			return sg["c0"]
	return null


func _peak(line: PackedVector2Array, a: float, b: float) -> float:
	var m := 0.0
	for p in line:
		if p.x >= a and p.x <= b:
			m = maxf(m, p.y)
	return m


func _low(line: PackedVector2Array, a: float, b: float) -> float:
	var m := 1.0
	for p in line:
		if p.x >= a and p.x <= b:
			m = minf(m, p.y)
	return m


func _differs(x: PackedVector2Array, y: PackedVector2Array, a: float, b: float) -> bool:
	var t := a
	while t < b:
		if absf(TimelineTrack.level_at(x, t) - TimelineTrack.level_at(y, t)) > 0.2:
			return true
		t += 0.125
	return false


func _is_sorted(line: PackedVector2Array) -> bool:
	for i in range(1, line.size()):
		if line[i].x < line[i - 1].x - 0.0001:
			return false
	return true


func _step_up_at(line: PackedVector2Array, t: float) -> bool:
	for i in range(line.size() - 1):
		if is_equal_approx(line[i].x, t) and is_equal_approx(line[i + 1].x, t) and line[i + 1].y > line[i].y:
			return true
		if is_equal_approx(line[i].x, t) and i == 0 and line[i].y >= 0.99:
			return true
	return false
