class_name SongDetect
extends RefCounted
## Pure detection maths for SongAnalyzer — kept separate so it can be
## tested on synthetic feature arrays without any audio.
##
## Everything works in whatever time unit the caller passes (SongAnalyzer
## runs it in fast-playback "capture time" and scales the results back to
## song time). Feature frames are beat-synchronous by the time `segment`
## sees them.


# =============================================================== TEMPO ==

## Tempo (BPM) from autocorrelation of an onset envelope sampled at
## `env_hz`, weighted by a log-normal prior around `prior_bpm`, with
## octave correction and parabolic refinement.
##
## `prior_bpm` is the expected tempo — 120 for a real signal, or
## `120 * playback_speed` when the analyser fed a sped-up capture.
static func estimate_tempo(onset: PackedFloat32Array, env_hz: float, prior_bpm := 120.0) -> float:
	var lo_lag := maxi(1, int(60.0 / (prior_bpm * 3.2) * env_hz))
	var hi_lag := int(60.0 / (prior_bpm / 2.6) * env_hz)
	var raw := {}
	var best_lag := lo_lag
	var best := -1.0
	for lag in range(lo_lag, hi_lag + 1):
		var s := 0.0
		var i := 0
		while i + lag < onset.size():
			s += onset[i] * onset[i + lag]
			i += 1
		raw[lag] = s
		var bpm := 60.0 * env_hz / float(lag)
		var w: float = exp(-0.5 * pow(log(bpm / prior_bpm) / 0.55, 2.0))
		if s * w > best:
			best = s * w
			best_lag = lag

	# octave correction toward the prior
	var dbl := int(round(best_lag / 2.0))
	if raw.has(dbl) and float(raw[dbl]) > float(raw[best_lag]) * 0.55 \
			and 60.0 * env_hz / float(dbl) <= prior_bpm * 1.7:
		best_lag = dbl
	var hlf := best_lag * 2
	if raw.has(hlf) and float(raw[hlf]) > float(raw[best_lag]) * 0.75 \
			and 60.0 * env_hz / float(hlf) >= prior_bpm * 0.6:
		best_lag = hlf

	var lag := float(best_lag)
	if raw.has(best_lag - 1) and raw.has(best_lag + 1):
		var y0: float = raw[best_lag - 1]
		var y1: float = raw[best_lag]
		var y2: float = raw[best_lag + 1]
		var den := y0 - 2.0 * y1 + y2
		if absf(den) > 0.0001:
			lag += clampf(0.5 * (y0 - y2) / den, -1.0, 1.0)

	var out := 60.0 * env_hz / maxf(lag, 1.0)
	while out > prior_bpm * 2.0:
		out *= 0.5
	while out < prior_bpm * 0.5:
		out *= 2.0
	return snappedf(out, 0.05)


# =========================================================== DP BEATS ==

## Dynamic-programming beat tracking (Ellis 2007): pick beats that fall on
## onset peaks while staying close to the target period. Returns beat
## times in seconds. `onset` is sampled at `env_hz`. Runs a second pass
## with the period measured from the first, which corrects a rough tempo
## estimate.
static func dp_beats(onset: PackedFloat32Array, env_hz: float, bpm: float) -> PackedFloat32Array:
	var beats := _dp_pass(onset, env_hz, 60.0 / bpm * env_hz)
	if beats.size() > 16:
		var ivs: Array = []
		for i in range(1, beats.size()):
			ivs.append(beats[i] - beats[i - 1])
		ivs.sort()
		var med: float = ivs[ivs.size() / 2] * env_hz
		if med > 2.0 and absf(med / (60.0 / bpm * env_hz) - 1.0) > 0.03:
			beats = _dp_pass(onset, env_hz, med)
	return beats


static func _dp_pass(onset: PackedFloat32Array, env_hz: float, period: float) -> PackedFloat32Array:
	var n := onset.size()
	if n < period * 4.0 or period < 2.0:
		return PackedFloat32Array()

	# local-normalise the onset envelope
	var o := _local_norm(onset, int(period * 2.0))

	var cum := PackedFloat32Array()
	var back := PackedInt32Array()
	cum.resize(n)
	back.resize(n)
	var tight := 12.0
	var lo := int(period * 0.5)
	var hi := int(period * 2.0)
	for t in range(n):
		var best := -INF
		var bi := -1
		var a := maxi(0, t - hi)
		var z := t - lo
		for tau in range(a, z + 1):
			if tau < 0:
				continue
			var ratio := float(t - tau) / period
			var pen := log(ratio) if ratio > 0.0 else -10.0
			var score: float = cum[tau] - tight * pen * pen
			if score > best:
				best = score
				bi = tau
		cum[t] = o[t] + (best if bi >= 0 else 0.0)
		back[t] = bi

	# best endpoint within the final beat-and-a-bit
	var e := n - 1
	for t in range(maxi(0, n - int(period)), n):
		if cum[t] > cum[e]:
			e = t
	var rev: Array = []
	while e >= 0:
		rev.append(e)
		e = back[e]
	rev.reverse()

	var beats := PackedFloat32Array()
	for idx in rev:
		beats.append(float(idx) / env_hz)
	return beats


static func _local_norm(a: PackedFloat32Array, win: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(a.size())
	win = maxi(win, 4)
	for i in range(a.size()):
		var lo := maxi(0, i - win)
		var hi := mini(a.size(), i + win)
		var mx := 0.0001
		for j in range(lo, hi):
			mx = maxf(mx, a[j])
		out[i] = a[i] / mx
	return out


# ========================================================== DOWNBEATS ==

## Which of the 4 beat positions (0..3) is beat "1": the phase whose beats
## carry the most chroma change (chord changes land on downbeats).
static func downbeat_phase(beat_chroma: Array) -> int:
	if beat_chroma.size() < 8:
		return 0
	var score := [0.0, 0.0, 0.0, 0.0]
	for i in range(1, beat_chroma.size()):
		var d := _chroma_dist(beat_chroma[i], beat_chroma[i - 1])
		score[i % 4] += d
	var best := 0
	for p in range(1, 4):
		if score[p] > score[best]:
			best = p
	return best


static func _chroma_dist(a, b) -> float:
	var s := 0.0
	for i in range(min(a.size(), b.size())):
		s += absf(float(a[i]) - float(b[i]))
	return s


# ========================================================= STRUCTURE ==

## Full structural segmentation. `feats[i]` is a beat-synchronous feature
## vector (chroma 12 + timbre, already scaled); `energy[i]` is a 0..1
## loudness per beat; `beat_times` in seconds. Returns
## [{ start, end, label, energy, cluster }].
static func segment(feats: Array, energy: PackedFloat32Array,
		beat_times: PackedFloat32Array, db_phase: int, duration: float) -> Array:
	var nb := feats.size()
	if nb < 12:
		return [{"start": 0.0, "end": duration, "label": "Verse",
			"energy": 0.6, "cluster": 0}]

	var ssm := _ssm(feats)
	var nov := _novelty(ssm, mini(16, nb / 4))

	# candidate boundaries: novelty peaks, min ~4 bars apart, snapped to
	# the downbeat grid
	var min_gap_beats := 16
	var thr := _percentile(nov, 0.70)
	var bounds: Array = [0]
	var last := -min_gap_beats
	for i in range(4, nb - 4):
		if i - last < min_gap_beats:
			continue
		if nov[i] >= thr and nov[i] >= nov[i - 1] and nov[i] > nov[i + 1]:
			bounds.append(_snap_downbeat(i, db_phase))
			last = i
	if bounds[bounds.size() - 1] < nb - 8:
		bounds.append(nb)
	else:
		bounds[bounds.size() - 1] = nb

	# merge segments under ~6 bars
	var segs: Array = []
	for i in range(bounds.size() - 1):
		var s: int = bounds[i]
		var e: int = bounds[i + 1]
		if e - s < 16 and not segs.is_empty():
			segs[-1]["e"] = e
		else:
			segs.append({"s": s, "e": e})

	# per-segment mean feature + energy
	for seg in segs:
		seg["feat"] = _mean_vec(feats, seg["s"], seg["e"])
		seg["en"] = _mean_arr(energy, seg["s"], seg["e"])
		seg["rise"] = _mean_arr(energy, seg["e"] - 8, seg["e"]) \
			- _mean_arr(energy, seg["s"], seg["s"] + 8)

	# cluster by feature similarity (union-find over similar pairs)
	var parent: Array = []
	for i in range(segs.size()):
		parent.append(i)
	for i in range(segs.size()):
		for j in range(i + 1, segs.size()):
			if _cos(segs[i]["feat"], segs[j]["feat"]) > 0.86:
				_union(parent, i, j)
	var cluster_of: Array = []
	var cluster_ids := {}
	for i in range(segs.size()):
		var root := _find(parent, i)
		if not cluster_ids.has(root):
			cluster_ids[root] = cluster_ids.size()
		cluster_of.append(cluster_ids[root])

	# cluster stats
	var cl_count := {}
	var cl_energy := {}
	for i in range(segs.size()):
		var c: int = cluster_of[i]
		cl_count[c] = int(cl_count.get(c, 0)) + 1
		cl_energy[c] = float(cl_energy.get(c, 0.0)) + float(segs[i]["en"])
	for c in cl_energy:
		cl_energy[c] /= cl_count[c]

	# the recurring cluster with the most energy is the chorus; the next
	# recurring one is the verse
	var recurring: Array = []
	for c in cl_count:
		if int(cl_count[c]) >= 2:
			recurring.append(c)
	recurring.sort_custom(func(a, b): return float(cl_energy[a]) > float(cl_energy[b]))
	var chorus_cl: int = recurring[0] if recurring.size() > 0 else -1
	var verse_cl: int = recurring[1] if recurring.size() > 1 else -1

	var elo := INF
	var ehi := -INF
	for seg in segs:
		elo = minf(elo, seg["en"])
		ehi = maxf(ehi, seg["en"])
	var espan: float = maxf(ehi - elo, 0.0001)

	var out: Array = []
	for i in range(segs.size()):
		var seg: Dictionary = segs[i]
		var c: int = cluster_of[i]
		var en_n: float = clampf((seg["en"] - elo) / espan, 0.0, 1.0)
		var label := "Verse"
		if c == chorus_cl:
			label = "Chorus"
		elif c == verse_cl:
			label = "Verse"
		elif i == 0:
			label = "Intro" if en_n < 0.55 else "Verse"
		elif i == segs.size() - 1:
			label = "Outro" if en_n < 0.55 else "Chorus"
		elif en_n <= 0.32:
			label = "Bridge"
		elif en_n >= 0.7:
			label = "Chorus"
		out.append({
			"start": _btime(beat_times, seg["s"]),
			"end": _btime(beat_times, seg["e"]),
			"label": label, "energy": clampf(en_n, 0.06, 1.0), "cluster": c,
		})

	# build -> drop refinement
	for i in range(out.size() - 1):
		if float(segs[i]["rise"]) > 0.14 and out[i]["energy"] < 0.7 \
				and out[i + 1]["label"] == "Chorus" and out[i + 1]["energy"] >= 0.8:
			out[i]["label"] = "Build"
			out[i + 1]["label"] = "Drop"

	out[0]["start"] = 0.0
	out[out.size() - 1]["end"] = duration
	return out


# --- structure helpers -------------------------------------------------

static func _ssm(feats: Array) -> Array:
	var n := feats.size()
	var s: Array = []
	for i in range(n):
		var row := PackedFloat32Array()
		row.resize(n)
		s.append(row)
	for i in range(n):
		s[i][i] = 1.0
		for j in range(i + 1, n):
			var v := _cos(feats[i], feats[j])
			s[i][j] = v
			s[j][i] = v
	return s


## Foote checkerboard novelty along the SSM diagonal.
static func _novelty(ssm: Array, k: int) -> PackedFloat32Array:
	var n := ssm.size()
	var nov := PackedFloat32Array()
	nov.resize(n)
	k = maxi(k, 2)
	# gaussian-tapered checkerboard kernel
	var kern: Array = []
	for a in range(-k, k):
		var row := PackedFloat32Array()
		for b in range(-k, k):
			var g: float = exp(-(a * a + b * b) / float(k * k) * 2.0)
			var sign := 1.0 if (a * b) >= 0 else -1.0
			row.append(sign * g)
		kern.append(row)
	for i in range(n):
		if i - k < 0 or i + k >= n:
			continue
		var acc := 0.0
		for a in range(-k, k):
			for b in range(-k, k):
				acc += kern[a + k][b + k] * ssm[i + a][i + b]
		nov[i] = maxf(0.0, acc)
	return nov


static func _snap_downbeat(beat_index: int, phase: int) -> int:
	var off := ((beat_index - phase) % 4 + 4) % 4
	if off == 0:
		return beat_index
	return beat_index - off if off <= 2 else beat_index + (4 - off)


static func _btime(beat_times: PackedFloat32Array, idx: int) -> float:
	if beat_times.is_empty():
		return 0.0
	idx = clampi(idx, 0, beat_times.size() - 1)
	return beat_times[idx]


static func _mean_vec(vecs: Array, lo: int, hi: int) -> PackedFloat32Array:
	lo = maxi(lo, 0)
	hi = mini(hi, vecs.size())
	var dim: int = vecs[0].size() if not vecs.is_empty() else 0
	var out := PackedFloat32Array()
	out.resize(dim)
	if hi <= lo:
		return out
	for i in range(lo, hi):
		for d in range(dim):
			out[d] += vecs[i][d]
	for d in range(dim):
		out[d] /= float(hi - lo)
	return out


static func _mean_arr(a: PackedFloat32Array, lo: int, hi: int) -> float:
	lo = maxi(lo, 0)
	hi = mini(hi, a.size())
	if hi <= lo:
		return 0.0
	var s := 0.0
	for i in range(lo, hi):
		s += a[i]
	return s / float(hi - lo)


static func _cos(a, b) -> float:
	var dot := 0.0
	var na := 0.0
	var nb := 0.0
	for i in range(min(a.size(), b.size())):
		dot += a[i] * b[i]
		na += a[i] * a[i]
		nb += b[i] * b[i]
	if na < 1e-9 or nb < 1e-9:
		return 0.0
	return dot / sqrt(na * nb)


static func _percentile(a: PackedFloat32Array, p: float) -> float:
	var c := Array(a)
	c.sort()
	return c[clampi(int(p * c.size()), 0, c.size() - 1)] if not c.is_empty() else 0.0


static func _find(parent: Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i


static func _union(parent: Array, a: int, b: int) -> void:
	parent[_find(parent, a)] = _find(parent, b)
