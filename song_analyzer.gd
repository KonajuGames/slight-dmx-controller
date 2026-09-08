class_name SongAnalyzer
extends Node
## Analyses a music file into a `SongAnalysis` (tempo, beat grid, downbeat
## phase, structural sections).
##
## It plays the file fast and muted through an `AudioEffectCapture` bus,
## keeps the raw PCM, then runs the detection offline:
##   - a short-time Fourier transform for a beat-synchronous chroma +
##     timbre feature stream
##   - a time-domain onset envelope, a tempo estimate, and a
##     dynamic-programming beat tracker (SongDetect.dp_beats)
##   - a downbeat phase from where the chord changes fall
##   - a self-similarity / novelty segmentation with repetition-based
##     verse / chorus labelling (SongDetect.segment)
##
## Fast playback pitches the audio up by whole octaves (2× / 4×), which
## leaves the chroma unchanged; times are scaled back to song time.

signal progress(fraction: float)
signal finished(analysis: SongAnalysis)
signal failed(reason: String)

const BUS := "SongAnalysis"
const N_FFT := 2048
const HOP := 1024
const ONSET_DECIM := 128          # onset-envelope hop, in capture samples
const WAVE_COLS := 1024           # columns in the whole-song waveform view

var _player: AudioStreamPlayer
var _cap: AudioEffectCapture
var _bus_idx := -1
var _running := false
var _path := ""
var _dur := 0.0                   # song seconds
var _speed := 4.0
var _rate := 44100.0
var _pcm := PackedFloat32Array()  # mono, capture-rate, pitch-shifted


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


static func load_stream(path: String) -> AudioStream:
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	match path.get_extension().to_lower():
		"mp3":
			var s := AudioStreamMP3.new()
			s.data = bytes
			return s if s.get_length() > 0.0 else null
		"ogg", "oga":
			return AudioStreamOggVorbis.load_from_buffer(bytes)
		"wav":
			if ClassDB.class_has_method("AudioStreamWAV", "load_from_buffer", true):
				return AudioStreamWAV.load_from_buffer(bytes)
			return null
	return null


func analyse(path: String, speed := 4.0) -> void:
	if _running:
		return
	var stream := load_stream(path)
	if stream == null:
		failed.emit("Unsupported or unreadable audio (try MP3 or OGG).")
		return
	_dur = stream.get_length()
	if _dur <= 5.0:
		failed.emit("Track is too short, or its length is unknown.")
		return

	_path = path
	# 1× / 2× / 4× only — whole-octave shifts keep chroma intact
	_speed = 4.0 if speed >= 3.0 else (2.0 if speed >= 1.5 else 1.0)
	_setup_bus()
	_rate = AudioServer.get_mix_rate()
	_player.stream = stream
	_player.pitch_scale = _speed
	_pcm = PackedFloat32Array()
	_pcm.resize(int(_rate * _dur / _speed) + int(_rate))
	_pcm.resize(0)
	_running = true
	_player.play()


func _setup_bus() -> void:
	if _bus_idx < 0:
		_bus_idx = AudioServer.bus_count
		AudioServer.add_bus(_bus_idx)
		AudioServer.set_bus_name(_bus_idx, BUS)
		AudioServer.set_bus_mute(_bus_idx, true)
		_cap = AudioEffectCapture.new()
		_cap.buffer_length = 2.0
		AudioServer.add_bus_effect(_bus_idx, _cap)
	_cap.clear_buffer()
	if _player == null:
		_player = AudioStreamPlayer.new()
		_player.bus = BUS
		add_child(_player)


func _process(_delta: float) -> void:
	if not _running:
		return
	var avail := _cap.get_frames_available()
	if avail > 0:
		var buf := _cap.get_buffer(avail)
		for v in buf:
			_pcm.append((v.x + v.y) * 0.5)
	var pos := _player.get_playback_position()
	progress.emit(clampf(pos / _dur, 0.0, 1.0))
	if not _player.playing or pos >= _dur - 0.05:
		_finish()


func _finish() -> void:
	_running = false
	_player.stop()
	# drain whatever is still buffered
	var left := _cap.get_frames_available()
	if left > 0:
		for v in _cap.get_buffer(left):
			_pcm.append((v.x + v.y) * 0.5)
	if _pcm.size() < int(_rate * 3.0):
		failed.emit("Captured too little audio — is another app using the output device?")
		return
	finished.emit(_detect())


# ============================================================ FEATURES ==

func _detect() -> SongAnalysis:
	var a := SongAnalysis.new()
	a.path = _path
	a.duration = _dur

	var frames := _stft()                          # { chroma, rms, centroid, flux, blo, bmid, bhi }
	_build_wave(a, frames)
	var onset := _onset_env()
	var onset_hz := _rate / float(ONSET_DECIM)

	var bpm_cap := SongDetect.estimate_tempo(onset, onset_hz, 120.0 * _speed)
	var beats_cap := SongDetect.dp_beats(onset, onset_hz, bpm_cap)
	if beats_cap.size() < 8:
		# fall back to a rigid grid
		beats_cap = PackedFloat32Array()
		var p := 60.0 / bpm_cap
		var t := 0.0
		while t < _pcm.size() / _rate:
			beats_cap.append(t)
			t += p

	# beat-synchronous features
	var frame_hz := _rate / float(HOP)
	var bchroma: Array = []
	var benergy := PackedFloat32Array()
	var btimbre: Array = []
	for i in range(beats_cap.size()):
		var t0: float = beats_cap[i]
		var t1: float = beats_cap[i + 1] if i + 1 < beats_cap.size() else t0 + 60.0 / bpm_cap
		var f0 := int(t0 * frame_hz)
		var f1 := maxi(f0 + 1, int(t1 * frame_hz))
		bchroma.append(_avg_rows(frames["chroma"], f0, f1))
		benergy.append(_avg(frames["rms"], f0, f1))
		btimbre.append([
			_avg(frames["centroid"], f0, f1),
			_avg(frames["flux"], f0, f1),
		])

	_normalise(benergy)
	var cen := PackedFloat32Array()
	var flx := PackedFloat32Array()
	for v in btimbre:
		cen.append(v[0])
		flx.append(v[1])
	_normalise(cen)
	_normalise(flx)

	var db_phase := SongDetect.downbeat_phase(bchroma)

	# combined feature vector per beat: chroma (weighted for structure) +
	# timbre + energy
	var feats: Array = []
	for i in range(beats_cap.size()):
		var v := PackedFloat32Array()
		var c: PackedFloat32Array = bchroma[i]
		for x in c:
			v.append(x * 1.6)
		v.append(cen[i] * 0.5)
		v.append(flx[i] * 0.5)
		v.append(benergy[i] * 0.8)
		feats.append(v)

	var cap_dur := _pcm.size() / _rate
	var segs := SongDetect.segment(feats, benergy, beats_cap, db_phase, cap_dur)

	# scale capture time -> song time
	a.beat_times = PackedFloat32Array()
	for t in beats_cap:
		a.beat_times.append(t * _speed)
	a.downbeats = PackedFloat32Array()
	for i in range(beats_cap.size()):
		if i % 4 == db_phase:
			a.downbeats.append(beats_cap[i] * _speed)
	a.sections = []
	for s in segs:
		a.sections.append({
			"start": clampf(float(s["start"]) * _speed, 0.0, _dur),
			"end": clampf(float(s["end"]) * _speed, 0.0, _dur),
			"label": s["label"], "energy": s["energy"], "cluster": s["cluster"],
		})
	if not a.sections.is_empty():
		a.sections[0]["start"] = 0.0
		a.sections[-1]["end"] = _dur

	# tempo from the median song-time beat interval
	var iv: Array = []
	for i in range(1, a.beat_times.size()):
		iv.append(a.beat_times[i] - a.beat_times[i - 1])
	iv.sort()
	if not iv.is_empty():
		a.bpm = snappedf(60.0 / maxf(iv[iv.size() / 2], 0.01), 0.1)
	else:
		a.bpm = bpm_cap / _speed
	return a


## STFT over the captured PCM: per-frame chroma (12), RMS, spectral
## centroid and spectral flux. Bin→pitch-class is computed in *song*
## frequency (capture freq / speed), but since 2×/4× are whole octaves
## the class is the same either way.
func _stft() -> Dictionary:
	var nframes: int = maxi(1, (_pcm.size() - N_FFT) / HOP)
	var half := N_FFT / 2 + 1

	var bin_pc := PackedInt32Array()
	var bin_band := PackedInt32Array()             # 0 = bass, 1 = mid, 2 = air
	bin_pc.resize(half)
	bin_band.resize(half)
	for k in range(half):
		var f_song := (k * _rate / N_FFT) / _speed
		if f_song < 55.0 or f_song > 2000.0:
			bin_pc[k] = -1
		else:
			var midi := 69.0 + 12.0 * log(f_song / 440.0) / log(2.0)
			bin_pc[k] = ((int(round(midi)) % 12) + 12) % 12
		bin_band[k] = 0 if f_song < 250.0 else (1 if f_song < 2500.0 else 2)

	var chroma: Array = []
	var rms := PackedFloat32Array()
	var centroid := PackedFloat32Array()
	var flux := PackedFloat32Array()
	var blo := PackedFloat32Array()
	var bmid := PackedFloat32Array()
	var bhi := PackedFloat32Array()
	var prev := PackedFloat32Array()
	for fr in range(nframes):
		var spec := FFT.magnitude(_pcm, fr * HOP, N_FFT)
		var c := PackedFloat32Array()
		c.resize(12)
		var e := 0.0
		var cnum := 0.0
		var cden := 0.0
		var fx := 0.0
		var eb := [0.0, 0.0, 0.0]
		for k in range(spec.size()):
			var m := spec[k]
			e += m * m
			cnum += k * m
			cden += m
			eb[bin_band[k]] += m * m
			var pc := bin_pc[k]
			if pc >= 0:
				c[pc] += m
			if prev.size() == spec.size():
				fx += maxf(0.0, m - prev[k])
		var cs := 0.0
		for x in c:
			cs += x
		if cs > 0.0001:
			for i in range(12):
				c[i] /= cs
		chroma.append(c)
		rms.append(sqrt(e / spec.size()))
		centroid.append(cnum / cden if cden > 0.0 else 0.0)
		flux.append(fx)
		blo.append(sqrt(eb[0]))
		bmid.append(sqrt(eb[1]))
		bhi.append(sqrt(eb[2]))
		prev = spec
	return {
		"chroma": chroma, "rms": rms, "centroid": centroid, "flux": flux,
		"blo": blo, "bmid": bmid, "bhi": bhi,
	}


## Whole-song waveform envelope for the Auto Show wave view: WAVE_COLS
## columns spanning the track, each with a loudness peak and a bass / mid /
## air balance. Fed straight from the STFT frames (capture time maps
## linearly to song time).
func _build_wave(a: SongAnalysis, frames: Dictionary) -> void:
	var rms: PackedFloat32Array = frames["rms"]
	var blo: PackedFloat32Array = frames["blo"]
	var bmid: PackedFloat32Array = frames["bmid"]
	var bhi: PackedFloat32Array = frames["bhi"]
	var nf := rms.size()
	a.wave_lo = PackedFloat32Array()
	a.wave_mid = PackedFloat32Array()
	a.wave_hi = PackedFloat32Array()
	a.wave_peak = PackedFloat32Array()
	if nf == 0:
		return
	a.wave_lo.resize(WAVE_COLS)
	a.wave_mid.resize(WAVE_COLS)
	a.wave_hi.resize(WAVE_COLS)
	a.wave_peak.resize(WAVE_COLS)
	var pk_max := 1e-9
	var bnd_max := 1e-9
	for c in range(WAVE_COLS):
		var f0 := c * nf / WAVE_COLS
		var f1 := maxi(f0 + 1, (c + 1) * nf / WAVE_COLS)
		var sl := 0.0
		var sm := 0.0
		var sh := 0.0
		var pk := 0.0
		for i in range(f0, mini(f1, nf)):
			sl += blo[i]
			sm += bmid[i]
			sh += bhi[i]
			pk = maxf(pk, rms[i])
		var n := float(maxi(1, mini(f1, nf) - f0))
		sl /= n
		sm /= n
		sh /= n
		a.wave_lo[c] = sl
		a.wave_mid[c] = sm
		a.wave_hi[c] = sh
		a.wave_peak[c] = pk
		pk_max = maxf(pk_max, pk)
		bnd_max = maxf(bnd_max, maxf(sl, maxf(sm, sh)))
	for c in range(WAVE_COLS):
		a.wave_lo[c] /= bnd_max
		a.wave_mid[c] /= bnd_max
		a.wave_hi[c] /= bnd_max
		a.wave_peak[c] /= pk_max


## Time-domain onset envelope for beat tracking: the positive change in
## low-band energy (the kick / bass drives the beat) plus a light dash of
## broadband transient energy, sampled every ONSET_DECIM capture samples.
func _onset_env() -> PackedFloat32Array:
	var out_n := _pcm.size() / ONSET_DECIM
	var lo := PackedFloat32Array()
	var hi := PackedFloat32Array()
	lo.resize(out_n)
	hi.resize(out_n)

	var lp := 0.0                 # 1-pole low-pass state (~1 kHz capture)
	var hp_prev := 0.0
	var x_prev := 0.0
	var acc_lo := 0.0
	var acc_hi := 0.0
	var cnt := 0
	var oi := 0
	for i in range(_pcm.size()):
		var x := _pcm[i]
		lp += 0.15 * (x - lp)
		var h := 0.85 * (hp_prev + x - x_prev)
		hp_prev = h
		x_prev = x
		acc_lo += lp * lp
		acc_hi += h * h
		cnt += 1
		if cnt >= ONSET_DECIM:
			if oi < out_n:
				lo[oi] = sqrt(acc_lo / cnt)
				hi[oi] = sqrt(acc_hi / cnt)
			oi += 1
			acc_lo = 0.0
			acc_hi = 0.0
			cnt = 0

	_normalise(lo)
	_normalise(hi)
	var env := PackedFloat32Array()
	env.resize(out_n)
	for i in range(1, out_n):
		env[i] = maxf(0.0, lo[i] - lo[i - 1]) + 0.35 * maxf(0.0, hi[i] - hi[i - 1])

	# 3-tap smoothing
	var sm := PackedFloat32Array()
	sm.resize(out_n)
	for i in range(out_n):
		var s := 0.0
		var w := 0
		for j in range(maxi(0, i - 1), mini(out_n, i + 2)):
			s += env[j]
			w += 1
		sm[i] = s / w
	return sm


# --- helpers -----------------------------------------------------------

func _avg(a: PackedFloat32Array, lo: int, hi: int) -> float:
	lo = maxi(lo, 0)
	hi = mini(hi, a.size())
	if hi <= lo:
		return 0.0
	var s := 0.0
	for i in range(lo, hi):
		s += a[i]
	return s / float(hi - lo)


func _avg_rows(rows: Array, lo: int, hi: int) -> PackedFloat32Array:
	lo = maxi(lo, 0)
	hi = mini(hi, rows.size())
	var out := PackedFloat32Array()
	out.resize(12)
	if hi <= lo:
		out[0] = 1.0
		return out
	for i in range(lo, hi):
		for d in range(12):
			out[d] += rows[i][d]
	var n := float(hi - lo)
	for d in range(12):
		out[d] /= n
	return out


func _normalise(a: PackedFloat32Array) -> void:
	var lo := INF
	var hi := -INF
	for v in a:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var span := hi - lo
	if span < 1e-6:
		return
	for i in range(a.size()):
		a[i] = (a[i] - lo) / span
