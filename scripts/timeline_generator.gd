class_name TimelineGenerator
extends RefCounted
## Builds a light show into a song's timelines from its structure, tempo
## and energy — what DJ Edit Mode's Generate button does.
##
## In: the song's sections ({start, end, label, energy}), its beat grid (or
## BPM) and which beat starts a bar, its length, and the timelines to fill
## (master, fixtures, heads: their keys and rows), plus the show's named
## positions. Out: per track key, the rows' content in the timelines'
## in-memory forms:
##   {dimmer: PackedVector2Array, colour: [segments], strobe: [spans],
##    position: [spans], movement: [spans]}
##
## Each section (energy rescaled across the song, so its quietest part is 0
## and its loudest 1) is cut into phrases of PHRASE_BARS bars on the bar
## lines, and every phrase picks its own look from the patterns that suit
## its energy — never one of the last two picked for that row — so a long
## section keeps changing. The picks come from a random generator seeded
## by the song and a variation number: the same song and variation always
## give the same show; another variation, another show.
##   master dimmer  the section at 25-100 % by energy, a beat's fade
##                  between sections; faded in at the start, out at the end
##   fixture dimmer per phrase a pattern (DIM_PATTERNS): quiet — follow the
##                  master, breathe, one fixture at a time; louder — bar
##                  hits, half time, odd / even, a wave across the rig;
##                  loudest — chases (either way, ping-pong, centre out),
##                  every beat, offbeats, sparkle. Many phrases end on a
##                  fill in their last bar (a fast chase, an eighth-note roll)
##   colour         a palette per kind of section (main, accent, third;
##                  every chorus in the same colours), laid across the rig
##                  per phrase (COLOUR_MODES): all alike, split, thirds,
##                  a gradient, sweeps, colours chasing bar by bar
##   strobe         a build into a big rise in energy: the section's last
##                  two bars, medium then fast (on the master) — sometimes
##                  ending a beat early on a blackout before the drop
##   position       the named positions in turn, a section each (master)
##   movement       per phrase a shape for the energy (MOVES), its size and
##                  speed growing with it; louder phrases sometimes fan the
##                  moving fixtures out across the shape (their own rows,
##                  phase-offset) — only over a position
## A kind of section that comes back builds each time: later choruses draw
## on busier patterns and colours, more fills, bigger movement. The last
## time the loudest kind comes round (or, without one, the loudest section)
## is the finale: everything — busiest patterns, a fill every phrase,
## rainbow colours, fanned movement, strobe hits ending each phrase.

## Energy (rescaled) above which a section is "high", "mid" and "low" (and
## below "calm"): the tier its patterns are picked from.
const HIGH := 0.75
const MID := 0.5
const LOW := 0.3
## A rise in energy into the next section that earns a strobe build.
const BUILD_RISE := 0.35
## Bars in a phrase: how often a section's look changes.
const PHRASE_BARS := 8

## Palettes by section label: [main, accent] hues (0..1) — the generator
## rotates them by a per-song offset so every song looks different, but
## every chorus within a song alike.
const PALETTES := {
	"intro": [0.60, 0.72], "verse": [0.55, 0.85], "pre-chorus": [0.80, 0.95],
	"chorus": [0.00, 0.10], "drop": [0.95, 0.12], "bridge": [0.45, 0.65],
	"breakdown": [0.68, 0.75], "outro": [0.62, 0.70],
}

## The fixtures' dimmer patterns by tier (calm, low, mid, high): [name,
## weight] — see _pattern().
const DIM_PATTERNS := [
	[["follow", 3], ["breathe", 2], ["solo", 1]],
	[["breathe", 2], ["solo", 2], ["bar_hits", 2], ["wave", 1]],
	[["bar_hits", 2], ["half_time", 2], ["odd_even", 2], ["wave", 2], ["ping_pong", 1]],
	[["chase", 3], ["chase_back", 2], ["ping_pong", 2], ["centre_out", 2], ["every_beat", 2],
		["offbeat", 1], ["odd_even", 1], ["sparkle", 1]],
]
## How the palette's colours are laid across the fixtures, by tier — see
## _unit_colour(). The finale adds "rainbow".
const COLOUR_MODES := [
	[["all", 3], ["gradient", 1]],
	[["all", 2], ["split", 2], ["gradient", 1], ["sweep", 1]],
	[["split", 2], ["thirds", 2], ["gradient", 2], ["sweep", 1]],
	[["split", 2], ["thirds", 2], ["sweep", 2], ["bar_chase", 2], ["gradient", 1]],
]
## Movement shapes by tier, and each tier's [size, bars a cycle].
const MOVES := [
	[["tilt_sweep", 2], ["pan_sweep", 2]],
	[["tilt_sweep", 1], ["pan_sweep", 2], ["circle", 2]],
	[["circle", 2], ["pan_sweep", 2], ["figure8", 1]],
	[["figure8", 3], ["circle", 2], ["pan_sweep", 1]],
]
const MOVE_SCALE := [[0.04, 4.0], [0.06, 2.0], [0.09, 1.0], [0.14, 0.5]]


## Weighted random picks that avoid repeating the last two (or, from a
## short list, the last one).
class _Picker:
	var rng: RandomNumberGenerator
	var recent: Array = []

	func _init(r: RandomNumberGenerator) -> void:
		rng = r

	func pick(options: Array) -> String:
		var avoid := recent.slice(maxi(recent.size() - mini(2, options.size() - 1), 0)) if options.size() > 1 else []
		var pool := options.filter(func(o): return not (o[0] in avoid))
		var total := 0.0
		for o in pool:
			total += float(o[1])
		var x := rng.randf() * total
		var chosen := String(pool[pool.size() - 1][0])
		for o in pool:
			x -= float(o[1])
			if x <= 0.0:
				chosen = String(o[0])
				break
		recent.append(chosen)
		if recent.size() > 2:
			recent.pop_front()
		return chosen


## Build the show. `tracks`: [{key, target: TimelineTrack.Target, rows:
## [Row]}] in order (fixtures then their heads, the master too);
## `beats`: the beat times; `per_bar`: beats a bar; `positions`: the named
## positions' ids; `seed_text` / `variation`: what seeds the picks;
## `bar_phase`: the index of a beat that starts a bar. Returns key ->
## content (only the rows each track has).
static func generate(sections: Array, beats: PackedFloat32Array, per_bar: int, duration: float,
		tracks: Array, positions: Array = [], seed_text := "", variation := 0, bar_phase := 0) -> Dictionary:
	var secs := _normalised(sections, duration)
	if beats.is_empty():
		beats = _even_beats(120.0, duration)
	per_bar = maxi(per_bar, 1)
	var beat_len := _median_gap(beats)
	var bar_len := beat_len * per_bar
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s|%d" % [seed_text, variation])
	var look := {"hue": rng.randf(), "sat": rng.randf_range(0.75, 0.95), "third": rng.randf_range(0.3, 0.5)}
	_mark_repeats(secs)
	var phrases := _phrases(secs, _bar_starts(beats, per_bar, bar_phase), bar_len)

	var out := {}
	var master := {}
	var fixtures: Array = []          # fixture tracks (not heads), in order
	var heads_of := {}                # fixture key -> its head tracks
	for t in tracks:
		out[String(t["key"])] = {"dimmer": PackedVector2Array(), "colour": [], "strobe": [], "position": [], "movement": []}
		if t["target"] == TimelineTrack.Target.MASTER:
			master = t
		elif t["target"] == TimelineTrack.Target.FIXTURE:
			fixtures.append(t)
		elif t["target"] == TimelineTrack.Target.HEAD:
			var parent := String(t["key"]).get_slice("/", 0)
			if not heads_of.has(parent):
				heads_of[parent] = []
			heads_of[parent].append(t)
	var dimmed: Array = fixtures.filter(func(f): return TimelineTrack.Row.DIMMER in f["rows"])
	var movers: Array = fixtures.filter(func(f): return TimelineTrack.Row.MOVEMENT in f["rows"])
	var plan := _plan(secs, phrases, rng, dimmed.size(), beat_len)

	# --- the master ---------------------------------------------------
	var mo: Dictionary = out[String(master["key"])] if not master.is_empty() else {}
	var master_line := _master_dimmer(secs, beat_len, duration)
	var builds := _strobe_builds(secs, bar_len, beat_len, rng)
	var blackouts: Array = builds["blackouts"]
	for w in blackouts:
		master_line = _cut_black(master_line, w.x, w.y, _section_level(secs, w.y))
	if not master.is_empty():
		if TimelineTrack.Row.DIMMER in master["rows"]:
			mo["dimmer"] = master_line
		if TimelineTrack.Row.STROBE in master["rows"]:
			mo["strobe"] = _with_finale_hits(builds["spans"], secs, phrases, bar_len)
		if TimelineTrack.Row.POSITION in master["rows"] and not positions.is_empty():
			for i in range(secs.size()):
				mo["position"].append({"t0": secs[i]["start"], "t1": secs[i]["end"], "pos": String(positions[i % positions.size()])})

	# --- dimmers --------------------------------------------------------
	var ctx := {"beats": beats, "beat_len": beat_len, "bar_len": bar_len, "per_bar": per_bar,
		"bar_phase": bar_phase, "master": master_line}
	var first := -1
	var last := -1
	for p in range(phrases.size()):
		if plan[p]["dim"] != "follow" or plan[p]["fill"] != "":
			if first < 0:
				first = p
			last = p
	for i in range(dimmed.size()):
		if first < 0:
			break
		var line := PackedVector2Array()
		for p in range(first, last + 1):
			for pt in _phrase_dimmer(plan[p], phrases[p], i, dimmed.size(), ctx):
				_append(line, pt)
		for w in blackouts:
			line = _cut_black(line, w.x, w.y, -1.0)
		out[String(dimmed[i]["key"])]["dimmer"] = line

	# --- colour ---------------------------------------------------------
	# The units colours are laid across: each fixture with a colour row, or
	# a multi-head fixture (its heads blending to the next unit's colour).
	var units: Array = []
	for f in fixtures:
		var heads: Array = heads_of.get(String(f["key"]), []).filter(func(h): return TimelineTrack.Row.COLOUR in h["rows"])
		if heads.size() > 1:
			units.append({"heads": heads})
		elif TimelineTrack.Row.COLOUR in f["rows"]:
			units.append({"fixture": f})
	for p in range(phrases.size()):
		var ph: Dictionary = phrases[p]
		var s: Dictionary = secs[ph["s"]]
		var pal := _palette(String(s["label"]), look)
		var mode: String = plan[p]["colour"]
		if not master.is_empty() and TimelineTrack.Row.COLOUR in master["rows"]:
			mo["colour"].append({"t0": ph["t0"], "t1": ph["t1"], "c0": pal[0], "c1": pal[1] if mode == "sweep" else pal[0]})
		if mode == "all":
			continue
		var spans: Array = []
		if mode == "bar_chase" or mode == "rainbow":
			var bars: PackedFloat32Array = ph["bars"]
			for m in range(bars.size()):
				spans.append(Vector2(bars[m], bars[m + 1] if m + 1 < bars.size() else ph["t1"]))
		else:
			spans.append(Vector2(ph["t0"], ph["t1"]))
		for u in range(units.size()):
			for m in range(spans.size()):
				var cs := _unit_colour(mode, u, units.size(), m, pal, look)
				if units[u].has("fixture"):
					out[String(units[u]["fixture"]["key"])]["colour"].append({"t0": spans[m].x, "t1": spans[m].y, "c0": cs[0], "c1": cs[1]})
					continue
				var nxt := _unit_colour(mode, u + 1, units.size(), m, pal, look)
				var heads: Array = units[u]["heads"]
				for hi in range(heads.size()):
					var w := float(hi) / float(heads.size() - 1)
					out[String(heads[hi]["key"])]["colour"].append({"t0": spans[m].x, "t1": spans[m].y,
						"c0": (cs[0] as Color).lerp(nxt[0], w), "c1": (cs[1] as Color).lerp(nxt[1], w)})
	for k in out:
		out[k]["colour"] = _merged(out[k]["colour"], ["c0", "c1"], true)

	# --- movement -------------------------------------------------------
	# It moves around a position: only with one.
	if not master.is_empty() and TimelineTrack.Row.MOVEMENT in master["rows"] and not mo["position"].is_empty():
		for p in range(phrases.size()):
			var ph: Dictionary = phrases[p]
			var s: Dictionary = secs[ph["s"]]
			var tm: int = 3 if s["finale"] else s["tier"]
			var scale: Array = MOVE_SCALE[tm]
			var size: float = scale[0] * (1.0 + 0.4 * float(s["lift"])) * (1.25 if s["finale"] else 1.0)
			var mv := {"t0": ph["t0"], "t1": ph["t1"], "fx": plan[p]["move"], "period": bar_len * float(scale[1]), "size": size}
			mo["movement"].append(mv)
			var fan: String = plan[p]["fan"]
			if fan == "" or movers.size() < 2:
				continue
			for j in range(movers.size()):
				var own := mv.duplicate()
				own["phase"] = float(j) / movers.size() if fan == "spread" else 0.5 * (j % 2)
				out[String(movers[j]["key"])]["movement"].append(own)
		for k in out:
			out[k]["movement"] = _merged(out[k]["movement"], ["fx", "period", "size", "phase"], false)
	return out


## The sections, sorted and filling the song, with their energy rescaled
## to 0..1 across it ("e") and its tier (0 calm .. 3 high). No sections:
## the whole song as one.
static func _normalised(sections: Array, duration: float) -> Array:
	var secs: Array = []
	for s in sections:
		if float(s.get("end", 0.0)) > float(s.get("start", 0.0)):
			secs.append({"start": float(s["start"]), "end": minf(float(s["end"]), duration),
				"label": String(s.get("label", "verse")).to_lower(), "energy": float(s.get("energy", 0.5))})
	secs.sort_custom(func(a, b): return a["start"] < b["start"])
	if secs.is_empty():
		secs.append({"start": 0.0, "end": duration, "label": "verse", "energy": 0.6})
	var lo := INF
	var hi := -INF
	for s in secs:
		lo = minf(lo, s["energy"])
		hi = maxf(hi, s["energy"])
	for s in secs:
		var e: float = 0.6 if hi - lo < 0.001 else (s["energy"] - lo) / (hi - lo)
		s["e"] = e
		s["tier"] = 3 if e >= HIGH else (2 if e >= MID else (1 if e >= LOW else 0))
	return secs


## Each section's place among its kind (by label): "rep" (0 the first
## time), "lift" (0 the first time .. 1 the last, for a kind that comes
## back) and "finale" (the last time the loudest returning kind comes
## round — or, with none loud, the last of the loudest sections).
static func _mark_repeats(secs: Array) -> void:
	var count := {}
	var energy := {}
	for s in secs:
		var k: String = s["label"]
		s["rep"] = int(count.get(k, 0))
		count[k] = int(count.get(k, 0)) + 1
		energy[k] = float(energy.get(k, 0.0)) + float(s["e"])
	var best := ""
	var best_e := HIGH
	for k in count:
		var mean := float(energy[k]) / int(count[k])
		if int(count[k]) > 1 and mean >= best_e:
			best = k
			best_e = mean
	var fin := -1
	for i in range(secs.size()):
		var s: Dictionary = secs[i]
		var n := int(count[s["label"]])
		s["lift"] = float(s["rep"]) / (n - 1) if n > 1 else 0.0
		s["finale"] = false
		if (best != "" and s["label"] == best) or (best == "" and float(s["e"]) >= 0.99):
			fin = i
	if fin >= 0:
		secs[fin]["finale"] = true


## The beats that start a bar: every `per_bar`th, from beat `bar_phase`.
static func _bar_starts(beats: PackedFloat32Array, per_bar: int, bar_phase: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for i in range(beats.size()):
		if posmod(i - bar_phase, per_bar) == 0:
			out.append(beats[i])
	return out


## The song's phrases: each section cut every PHRASE_BARS bars on its bar
## lines (a leftover under half a phrase joins the one before). [{t0, t1,
## s: the section's index, bars: the bar starts from t0, fill: where its
## last bar starts (a fill's place), or -1 for a phrase under two bars}].
static func _phrases(secs: Array, bar_starts: PackedFloat32Array, bar_len: float) -> Array:
	var out: Array = []
	for si in range(secs.size()):
		var s: Dictionary = secs[si]
		var a: float = s["start"]
		var b: float = s["end"]
		var inside: Array = []
		for t in bar_starts:
			if t > a + 0.01 and t < b - 0.01:
				inside.append(t)
		var cuts: Array = [a]
		var k := PHRASE_BARS - 1
		while k < inside.size():
			if b - float(inside[k]) >= 0.5 * PHRASE_BARS * bar_len:
				cuts.append(inside[k])
			k += PHRASE_BARS
		cuts.append(b)
		for c in range(cuts.size() - 1):
			var t0: float = cuts[c]
			var t1: float = cuts[c + 1]
			var bars := PackedFloat32Array([t0])
			for t in inside:
				if t > t0 + 0.01 and t < t1 - 0.01:
					bars.append(t)
			var fill: float = bars[bars.size() - 1] if bars.size() >= 2 and t1 - bars[bars.size() - 1] >= 0.75 * bar_len else -1.0
			out.append({"t0": t0, "t1": t1, "s": si, "bars": bars, "fill": fill})
	return out


## Each phrase's picks: {dim: pattern, fill: "" or a fill pattern, colour:
## mode, move: shape, fan: "" / "spread" / "alternate", tier: the dimmer
## pattern's tier, sparkle: per step the fixtures (of `n`) lit}.
static func _plan(secs: Array, phrases: Array, rng: RandomNumberGenerator, n: int, beat_len: float) -> Array:
	var dim_pick := _Picker.new(rng)
	var col_pick := _Picker.new(rng)
	var move_pick := _Picker.new(rng)
	var out: Array = []
	for ph in phrases:
		var s: Dictionary = secs[ph["s"]]
		var tier: int = s["tier"]
		var lift: float = s["lift"]
		var fin: bool = s["finale"]
		# A returning kind of section often borrows from the tier above.
		var td := tier
		if fin:
			td = 3
		elif lift >= 0.5 and tier >= 1 and tier < 3 and rng.randf() < 0.5:
			td += 1
		var dim := dim_pick.pick(DIM_PATTERNS[td])
		var fill := ""
		if td >= 2 and float(ph["fill"]) >= 0.0 and (fin or rng.randf() < 0.35 + 0.4 * lift):
			fill = "fill_chase" if td == 3 else "fill_roll"
		var tc := 3 if fin else mini(tier + (1 if lift >= 0.5 else 0), 3)
		var modes: Array = COLOUR_MODES[tc] + ([["rainbow", 3]] if fin else [])
		var colour := col_pick.pick(modes)
		var tm := 3 if fin else tier
		var move := move_pick.pick(MOVES[tm])
		var fan := ""
		if tm >= 2 and (fin or rng.randf() < 0.3 + 0.5 * lift):
			fan = "spread" if rng.randf() < 0.5 else "alternate"
		var sparkle: Array = []
		if dim == "sparkle" and n > 0:
			for _j in range(int(ceil((ph["t1"] - ph["t0"]) / beat_len)) + 2):
				var lit: Array = []
				for _k in range(maxi(1, n / 3)):
					lit.append(rng.randi_range(0, n - 1))
				sparkle.append(lit)
		out.append({"dim": dim, "fill": fill, "colour": colour, "move": move, "fan": fan, "tier": td, "sparkle": sparkle})
	return out


static func _even_beats(bpm: float, duration: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var step := 60.0 / maxf(bpm, 1.0)
	var t := 0.0
	while t < duration:
		out.append(t)
		t += step
	return out


static func _median_gap(beats: PackedFloat32Array) -> float:
	if beats.size() < 2:
		return 0.5
	var gaps: Array = []
	for i in range(1, beats.size()):
		gaps.append(beats[i] - beats[i - 1])
	gaps.sort()
	return maxf(float(gaps[gaps.size() / 2]), 0.05)


## [main, accent, third] colours for a section label, hues shifted per song
## (`look`: hue, sat, third — how far round from the main the third sits).
static func _palette(label: String, look: Dictionary) -> Array:
	var key := label
	if not PALETTES.has(key):
		key = "chorus" if "chorus" in label else ("verse" if "verse" in label else "bridge")
	var hues: Array = PALETTES[key]
	var shift: float = look["hue"]
	var sat: float = look["sat"]
	var main := fmod(hues[0] + shift, 1.0)
	return [Color.from_hsv(main, sat, 1.0), Color.from_hsv(fmod(hues[1] + shift, 1.0), sat * 0.95, 1.0),
		Color.from_hsv(fmod(main + float(look["third"]), 1.0), sat, 1.0)]


## Colour unit `u` of `count`'s [c0, c1] in bar `m` of a phrase, for a
## colour mode: split (main / accent alternating), thirds (the three in
## turn), gradient (main -> accent across the rig), sweep (each fading
## main -> accent or back), bar_chase (the three stepping on each bar),
## rainbow (hues round the wheel, turning each bar).
static func _unit_colour(mode: String, u: int, count: int, m: int, pal: Array, look: Dictionary) -> Array:
	var c: Color = pal[0]
	match mode:
		"split":
			c = pal[u % 2]
		"thirds":
			c = pal[u % 3]
		"gradient":
			c = (pal[0] as Color).lerp(pal[1], clampf(float(u) / maxf(count - 1, 1), 0.0, 1.0))
		"sweep":
			return [pal[0], pal[1]] if u % 2 == 0 else [pal[1], pal[0]]
		"bar_chase":
			c = pal[(u + m) % 3]
		"rainbow":
			c = Color.from_hsv(fposmod((pal[0] as Color).h + float(u) / maxf(count, 1) + m * 0.125, 1.0), look["sat"], 1.0)
	return [c, c]


## The master's line: each section at 25-100 % by its energy, a beat's
## fade between sections; up from 0 over the first bar-ish, down to 0
## over the last.
static func _master_dimmer(secs: Array, beat_len: float, duration: float) -> PackedVector2Array:
	var out := PackedVector2Array([Vector2(0.0, 0.0)])
	var fade := minf(beat_len, 1.0)
	for i in range(secs.size()):
		var s: Dictionary = secs[i]
		var level := 0.25 + 0.75 * float(s["e"])
		var a: float = s["start"] + (fade if i == 0 else fade * 0.5)
		var b: float = s["end"] - (fade if i == secs.size() - 1 else fade * 0.5)
		if b <= a:
			a = (s["start"] + s["end"]) * 0.5
			b = a
		out.append(Vector2(a, level))
		if b > a:
			out.append(Vector2(b, level))
	out.append(Vector2(duration, 0.0))
	return out


## The master's level for the section starting at `t`.
static func _section_level(secs: Array, t: float) -> float:
	for s in secs:
		if absf(float(s["start"]) - t) < 0.001:
			return 0.25 + 0.75 * float(s["e"])
	return -1.0


## `line` with 0 from `a` to `b` (stepping down at a, back up at b to
## `after` — or, < 0, where the line was). An empty line (following the
## master) or one that doesn't reach the window is left alone.
static func _cut_black(line: PackedVector2Array, a: float, b: float, after: float) -> PackedVector2Array:
	if line.is_empty() or line[0].x > a or line[line.size() - 1].x < b:
		return line
	var up := after if after >= 0.0 else TimelineTrack.level_at(line, b + 0.0001)
	var out := PackedVector2Array()
	for p in line:
		if p.x < a:
			out.append(p)
	out.append(Vector2(a, TimelineTrack.level_at(line, a)))
	out.append(Vector2(a, 0.0))
	out.append(Vector2(b, 0.0))
	out.append(Vector2(b, up))
	for p in line:
		if p.x > b:
			out.append(p)
	return out


## Add a node to a line, keeping it in time order.
static func _append(line: PackedVector2Array, p: Vector2) -> void:
	if line.is_empty() or p.x >= line[line.size() - 1].x:
		line.append(p)


## A phrase's dimmer for fixture `i` of `n`: its pattern, then its fill
## over the last bar.
static func _phrase_dimmer(pick: Dictionary, ph: Dictionary, i: int, n: int, ctx: Dictionary) -> PackedVector2Array:
	var t1: float = ph["t1"]
	var fill_at: float = ph["fill"] if pick["fill"] != "" else -1.0
	var out := _pattern(pick["dim"], ph["t0"], fill_at if fill_at > 0.0 else t1, i, n, pick, ctx)
	if fill_at > 0.0:
		for p in _pattern(pick["fill"], fill_at, t1, i, n, pick, ctx):
			_append(out, p)
	return out


## Dimmer pattern `name` from `a` to `b` for fixture `i` of `n`, peaking at
## 100 % in the loudest tier (else scaled by the master's level, so it's
## never brighter than the master and fades in and out with it):
##   follow      the master's line (as if there were none)
##   breathe     a slow swell over two bars, rippling across the rig
##   solo        one fixture at a time, a bar each, the rest low
##   wave        a swell travelling across the rig, a bar a cycle
##   bar_hits / half_time / every_beat / offbeat   everyone, on beat 1 /
##               beats 1 and 3 / every beat / between the beats
##   odd_even    odd and even fixtures on alternate beats
##   chase / chase_back / ping_pong / centre_out   one fixture a step
##               (a beat, an eighth with more fixtures than beats in a bar)
##               left to right, back, to and fro, from the centre out
##   sparkle     a random third of the fixtures each beat
##   fill_chase  a fill: an eighth-note chase
##   fill_roll   a fill: everyone on eighths, rising
static func _pattern(name: String, a: float, b: float, i: int, n: int, pick: Dictionary, ctx: Dictionary) -> PackedVector2Array:
	var master: PackedVector2Array = ctx["master"]
	if b <= a:
		return PackedVector2Array()
	if name == "follow":
		var out := PackedVector2Array([Vector2(a, TimelineTrack.level_at(master, a))])
		for p in master:
			if p.x > a and p.x < b:
				out.append(p)
		out.append(Vector2(b, TimelineTrack.level_at(master, b)))
		return out
	var line := _shape(name, a, b, i, n, pick, ctx)
	if int(pick["tier"]) < 3:
		for k in range(line.size()):
			line[k].y *= TimelineTrack.level_at(master, line[k].x)
	return line


## A pattern's shape (see _pattern()), peaking at 100 %.
static func _shape(name: String, a: float, b: float, i: int, n: int, pick: Dictionary, ctx: Dictionary) -> PackedVector2Array:
	var beat: float = ctx["beat_len"]
	var bar: float = ctx["bar_len"]
	var per_bar: int = ctx["per_bar"]
	var peak := 1.0
	match name:
		"breathe":
			return _smooth(a, b, beat * 0.5, func(t): return peak * (0.25 + 0.75 * (0.5 - 0.5 * cos(TAU * ((t - a) / (2.0 * bar) - 0.5 * i / maxf(n, 1))))))
		"wave":
			return _smooth(a, b, beat * 0.25, func(t): return peak * (0.5 + 0.5 * sin(TAU * ((t - a) / bar - float(i) / maxf(n, 1)))))
		"solo":
			var out := PackedVector2Array()
			var t := a
			var m := 0
			while t < b - 0.001:
				var e := minf(t + bar, b)
				var lvl := peak if m % maxi(n, 1) == i else peak * 0.12
				_append(out, Vector2(t, lvl))
				_append(out, Vector2(maxf(e - beat, t), lvl))
				t = e
				m += 1
			_append(out, Vector2(b, out[out.size() - 1].y))
			return out
	# The rest are pulses on beats / steps.
	var beats: PackedFloat32Array = ctx["beats"]
	var bar_phase: int = ctx["bar_phase"]
	var hits: Array = []        # [time, level]
	var decay := beat
	var bi := beats.bsearch(a - 0.001)
	var j := 0
	var sub := 2 if name == "fill_chase" or name == "fill_roll" or (n > per_bar and name in ["chase", "chase_back", "ping_pong", "centre_out"]) else 1
	while bi < beats.size() and beats[bi] < b - 0.001:
		var bt := beats[bi]
		var k := posmod(bi - bar_phase, per_bar)
		for q in range(sub):
			var t := bt + q * beat / sub
			if t >= b - 0.001:
				break
			var on := false
			var lvl := peak
			match name:
				"every_beat":
					on = true
					decay = beat * 0.8
				"bar_hits":
					on = k == 0
					decay = bar * 0.9
				"half_time":
					on = k % 2 == 0
					decay = beat * 1.6
				"offbeat":
					t = bt + beat * 0.5
					on = t < b - 0.001
					decay = beat * 0.45
				"odd_even":
					on = j % 2 == i % 2
				"chase", "chase_back", "ping_pong", "centre_out", "fill_chase":
					on = _step_on(name, j, i, n)
					decay = beat * 1.5 / sub
				"sparkle":
					var lit: Array = pick["sparkle"][j] if j < pick["sparkle"].size() else []
					on = i in lit
					decay = beat * 0.6
				"fill_roll":
					on = true
					lvl = peak * lerpf(0.5, 1.0, (t - a) / (b - a))
					decay = beat * 0.4
			if on:
				hits.append([t, lvl])
			j += 1
		bi += 1
	return _pulse_line(hits, a, b, decay)


## Whether a stepping pattern lights fixture `i` (of `n`) on step `j`.
static func _step_on(name: String, j: int, i: int, n: int) -> bool:
	if n <= 1:
		return true
	match name:
		"chase_back":
			return n - 1 - j % n == i
		"ping_pong":
			var pos := j % (2 * n - 2)
			return (pos if pos < n else 2 * n - 2 - pos) == i
		"centre_out":
			# The fixtures as far from the centre light together, inner first.
			var rings := int(floor((n - 1) / 2.0)) + 1
			return j % rings == int(floor(absf(i - (n - 1) / 2.0)))
	return j % n == i


## A line sampled from `level(t)` every `step` seconds from `a` to `b`.
static func _smooth(a: float, b: float, step: float, level: Callable) -> PackedVector2Array:
	var out := PackedVector2Array()
	var t := a
	while t < b:
		out.append(Vector2(t, clampf(level.call(t), 0.0, 1.0)))
		t += maxf(step, 0.01)
	out.append(Vector2(b, clampf(level.call(b), 0.0, 1.0)))
	return out


## Pulses from `a` to `b`: at each hit ([time, level]) a step up to its
## level fading to 0 over `decay` (or until the next hit).
static func _pulse_line(hits: Array, a: float, b: float, decay: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for k in range(hits.size()):
		var at: float = hits[k][0]
		var lvl: float = hits[k][1]
		var nxt: float = hits[k + 1][0] if k + 1 < hits.size() else b
		if out.is_empty() and at > a:
			out.append(Vector2(a, 0.0))
		if out.is_empty() or out[out.size() - 1].x < at:
			_append(out, Vector2(at, 0.0))
		_append(out, Vector2(at, lvl))
		var gone := at + decay
		if gone < nxt:
			_append(out, Vector2(gone, 0.0))
			_append(out, Vector2(nxt, 0.0))
		else:
			_append(out, Vector2(nxt, lvl * (1.0 - (nxt - at) / decay)))
	if out.is_empty():
		out.append(Vector2(a, 0.0))
	if out[out.size() - 1].x < b:
		out.append(Vector2(b, 0.0))
	return out


## Strobe builds: the last two bars before a section that rises sharply in
## energy (medium, then fast in the final bar) — half the time (always
## into the finale) stopping a beat short for a blackout. {spans, blackouts:
## [Vector2(from, to)]}.
static func _strobe_builds(secs: Array, bar_len: float, beat_len: float, rng: RandomNumberGenerator) -> Dictionary:
	var spans: Array = []
	var blackouts: Array = []
	for i in range(secs.size() - 1):
		var s: Dictionary = secs[i]
		var nxt: Dictionary = secs[i + 1]
		if float(nxt["e"]) - float(s["e"]) < BUILD_RISE or float(nxt["e"]) < HIGH:
			continue
		var end: float = s["end"]
		var gap := beat_len if (nxt["finale"] or rng.randf() < 0.5) and end - s["start"] > 3.0 * bar_len else 0.0
		var a := maxf(end - 2.0 * bar_len, s["start"])
		var mid := maxf(end - bar_len, a)
		if mid > a:
			spans.append({"t0": a, "t1": mid, "speed": TimelineTrack.Strobe.MEDIUM})
		if end - gap > mid:
			spans.append({"t0": mid, "t1": end - gap, "speed": TimelineTrack.Strobe.FAST})
		if gap > 0.0:
			blackouts.append(Vector2(end - gap, end))
	return {"spans": spans, "blackouts": blackouts}


## The strobe spans plus, in the finale, a fast hit over each phrase's last
## half bar (where no build's already running), in time order.
static func _with_finale_hits(spans: Array, secs: Array, phrases: Array, bar_len: float) -> Array:
	var out := spans.duplicate()
	for ph in phrases:
		if not secs[ph["s"]]["finale"]:
			continue
		var t1: float = ph["t1"]
		var t0 := maxf(t1 - bar_len * 0.5, ph["t0"])
		if not spans.any(func(sp): return sp["t0"] < t1 and sp["t1"] > t0):
			out.append({"t0": t0, "t1": t1, "speed": TimelineTrack.Strobe.FAST})
	out.sort_custom(func(x, y): return x["t0"] < y["t0"])
	return out


## Segments with touching neighbours that carry the same `fields` joined
## (`still`: only segments that hold one value, c0 == c1).
static func _merged(segs: Array, fields: Array, still: bool) -> Array:
	var out: Array = []
	for sg in segs:
		if not out.is_empty():
			var prev: Dictionary = out[out.size() - 1]
			var same: bool = absf(float(prev["t1"]) - float(sg["t0"])) < 0.0001
			for f in fields:
				same = same and prev.get(f) == sg.get(f)
			if still:
				same = same and prev["c0"] == prev["c1"]
			if same:
				prev["t1"] = sg["t1"]
				continue
		out.append(sg.duplicate())
	return out
