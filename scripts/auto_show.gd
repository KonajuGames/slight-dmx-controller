extends Node
## Autoload singleton: "AutoShow"
##
## The Auto Show run mode: plays a music file and, locked to the playback
## position, drives a *layer* — a crossfading per-section look plus the
## generated beat chases / movement effects — that `ArtNet.tick()`
## composites **over** the operator's own cue playback. It never touches
## the cue list. Analysis runs in a child `SongAnalyzer`.

signal state_changed
signal analysis_progress(fraction: float)
signal analysis_done
signal analysis_failed(reason: String)
signal section_changed(index: int)        ## -1 = none / blacked out
signal chase_set(chase_name: String, on: bool)
signal effect_set(effect_name: String, on: bool)
signal beat                                ## shell -> Fx._on_beat

var active := false                        ## true while run mode == Auto Show
var playing := false
var song_path := ""
var analysis: SongAnalysis
## [{ t, kind: "section"|"blackout"|"chase"|"effect", arg, ... }], by t.
var timeline: Array = []
## looks[i] = per-universe { str(channel): value } for section i.
var looks: Array = []

var _player: AudioStreamPlayer
var _analyzer: SongAnalyzer
var _resume := 0.0
var _next_ev := 0
var _next_beat := 0

var _sec_cur := -1                         ## section the layer is fading toward
var _sec_prev := -1                        ## section it's fading from (-1 = black)
var _xf := 1.0                             ## crossfade 0..1 (prev -> cur)
var _xf_dur := 1.0
var _blackout := false                     ## pre-drop dip of the auto layer
var _fx_names: Array = []                  ## every chase / effect the timeline touches


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	_player = AudioStreamPlayer.new()
	add_child(_player)
	_analyzer = SongAnalyzer.new()
	add_child(_analyzer)
	_analyzer.progress.connect(func(f: float): analysis_progress.emit(f))
	_analyzer.failed.connect(func(m: String): analysis_failed.emit(m))
	_analyzer.finished.connect(func(a: SongAnalysis):
		analysis = a
		analysis_done.emit())


# ------------------------------------------------------------------ SONG --

func load_song(path: String) -> bool:
	stop()
	var s := SongAnalyzer.load_stream(path)
	if s == null:
		analysis_failed.emit("Can't load audio (try MP3 or OGG).")
		return false
	song_path = path
	analysis = null
	timeline.clear()
	_player.stream = s
	state_changed.emit()
	return true


func song_name() -> String:
	return song_path.get_file() if song_path != "" else ""


func song_length() -> float:
	return _player.stream.get_length() if _player.stream else 0.0


func analyse(speed := 4.0) -> void:
	if song_path != "":
		_analyzer.analyse(song_path, speed)


const _KIND_ORDER := {"blackout": 0, "section": 1, "chase": 2, "effect": 3}


func set_show(section_looks: Array, events: Array) -> void:
	looks = section_looks
	timeline = events
	timeline.sort_custom(func(x, y):
		var tx := float(x["t"])
		var ty := float(y["t"])
		if not is_equal_approx(tx, ty):
			return tx < ty
		return _KIND_ORDER.get(String(x["kind"]), 9) < _KIND_ORDER.get(String(y["kind"]), 9))
	_fx_names = []
	for ev in timeline:
		if String(ev["kind"]) in ["chase", "effect"]:
			var nm := String(ev["arg"]["name"])
			if nm not in _fx_names:
				_fx_names.append(nm)
	_rewind(position())
	_resync(position())


## The auto layer for `n` universes: the current section's look crossfaded
## from the previous one, as one { channel -> value } map per universe.
## Empty while stopped or during the pre-drop blackout.
func layer(n: int) -> Array:
	var out: Array = []
	for i in range(n):
		out.append({})
	if _blackout or looks.is_empty() or (not playing and _resume <= 0.01):
		return out
	var prev: Array = looks[_sec_prev] if _sec_prev >= 0 and _sec_prev < looks.size() else []
	var cur: Array = looks[_sec_cur] if _sec_cur >= 0 and _sec_cur < looks.size() else []
	var t := clampf(_xf, 0.0, 1.0)
	for i in range(n):
		var pd: Dictionary = prev[i] if i < prev.size() else {}
		var cd: Dictionary = cur[i] if i < cur.size() else {}
		var keys := {}
		for k in pd:
			keys[k] = true
		for k in cd:
			keys[k] = true
		for k in keys:
			var a := int(pd.get(k, 0))
			var b := int(cd.get(k, 0))
			out[i][int(k)] = int(round(lerpf(a, b, t)))
	return out


# ------------------------------------------------------------- TRANSPORT --

func play() -> void:
	if _player.stream == null:
		return
	if _player.playing:
		_player.stream_paused = false
	else:
		_player.play(_resume)
	playing = true
	_rewind(position())
	state_changed.emit()


func pause() -> void:
	if _player.playing:
		_resume = _player.get_playback_position()
		_player.stream_paused = true
	playing = false
	state_changed.emit()


func stop() -> void:
	_player.stop()
	_player.stream_paused = false
	playing = false
	_resume = 0.0
	_next_ev = 0
	_next_beat = 0
	_sec_cur = -1
	_sec_prev = -1
	_blackout = false
	for n in _fx_names:                        # drop the auto layer entirely
		chase_set.emit(n, false)
		effect_set.emit(n, false)
	section_changed.emit(-1)
	state_changed.emit()


func seek(t: float) -> void:
	t = clampf(t, 0.0, maxf(song_length() - 0.1, 0.0))
	_resume = t
	if _player.playing:
		_player.seek(t)
	_rewind(t)
	_resync(t)      # fire the cue + chase / effect state for where we landed
	state_changed.emit()


func position() -> float:
	if _player.stream == null:
		return 0.0
	if _player.playing:
		return _player.get_playback_position()
	return _resume


func _rewind(t: float) -> void:
	_next_ev = 0
	while _next_ev < timeline.size() and float(timeline[_next_ev]["t"]) < t:
		_next_ev += 1
	_next_beat = 0
	if analysis != null:
		while _next_beat < analysis.beat_times.size() and analysis.beat_times[_next_beat] < t:
			_next_beat += 1


## Fold every timeline event up to `t` and snap the layer + chase / effect
## state to it. Used after a seek (and after set_show) so a jump lands on
## the right section and layers without a stale crossfade.
func _resync(t: float) -> void:
	var sec := -1
	var black := false
	var chase_state := {}
	var effect_state := {}
	for ev in timeline:
		if float(ev["t"]) > t:
			break
		match String(ev["kind"]):
			"section":
				sec = int(ev["arg"])
				black = false
			"blackout":
				black = true
			"chase": chase_state[String(ev["arg"]["name"])] = bool(ev["arg"]["on"])
			"effect": effect_state[String(ev["arg"]["name"])] = bool(ev["arg"]["on"])
	_sec_prev = -1
	_sec_cur = sec
	_xf = 1.0
	_blackout = black
	section_changed.emit(-1 if black else sec)
	for n in chase_state:
		chase_set.emit(n, chase_state[n] and not black)
	for n in effect_state:
		effect_set.emit(n, effect_state[n] and not black)


# ------------------------------------------------------------- PLAYBACK --

func _process(delta: float) -> void:
	_xf = minf(_xf + delta / maxf(_xf_dur, 0.02), 1.0)
	if not active or not playing:
		return
	if not _player.playing:      # reached the end
		stop()
		return
	_advance_to(_player.get_playback_position())


## Fire every beat and timeline event up to `pos` (monotonic — call with
## non-decreasing positions; `seek()` resets the pointers first).
func _advance_to(pos: float) -> void:
	if analysis != null:
		while _next_beat < analysis.beat_times.size() and analysis.beat_times[_next_beat] <= pos:
			beat.emit()
			_next_beat += 1
	while _next_ev < timeline.size() and float(timeline[_next_ev]["t"]) <= pos:
		var ev: Dictionary = timeline[_next_ev]
		match String(ev["kind"]):
			"section":
				_sec_prev = _sec_cur
				_sec_cur = int(ev["arg"])
				_xf = 0.0
				_xf_dur = maxf(float(ev.get("fade", 1.0)), 0.02)
				_blackout = false
				section_changed.emit(_sec_cur)
			"blackout":
				_blackout = true
				section_changed.emit(-1)
				for n in _fx_names:                     # cut the auto layer dead
					chase_set.emit(n, false)
					effect_set.emit(n, false)
			"chase":
				chase_set.emit(String(ev["arg"]["name"]), bool(ev["arg"]["on"]) and not _blackout)
			"effect":
				effect_set.emit(String(ev["arg"]["name"]), bool(ev["arg"]["on"]) and not _blackout)
		_next_ev += 1


# ------------------------------------------------------- SERIALIZATION --

func to_dict() -> Dictionary:
	return {
		"song_path": song_path,
		"analysis": analysis.to_dict() if analysis != null else {},
		"timeline": timeline.duplicate(true),
		"looks": looks.duplicate(true),
	}


func from_dict(d: Dictionary) -> void:
	stop()
	song_path = String(d.get("song_path", ""))
	var evs = d.get("timeline", null)
	var lk = d.get("looks", null)
	analysis = null
	var ad = d.get("analysis", {})
	if ad is Dictionary and not ad.is_empty():
		analysis = SongAnalysis.from_dict(ad)
	if song_path != "" and FileAccess.file_exists(song_path):
		var s := SongAnalyzer.load_stream(song_path)
		if s != null:
			_player.stream = s
	if evs is Array and lk is Array:
		set_show(lk.duplicate(true), evs.duplicate(true))
	else:
		looks = []
		timeline = []
	state_changed.emit()
