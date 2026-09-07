extends Node
## Autoload singleton: "AutoShow"
##
## The Auto Show run mode: plays a music file and fires the generated cue
## list / beat-chase from a timeline locked to the playback position.
## Analysis runs in a child `SongAnalyzer`.

signal state_changed
signal analysis_progress(fraction: float)
signal analysis_done
signal analysis_failed(reason: String)
signal cue_fired(number: int)              ## shell -> cue_panel.go_to_number
signal chase_set(chase_name: String, on: bool)
signal effect_set(effect_name: String, on: bool)
signal beat                                ## shell -> Fx._on_beat

var active := false                        ## true while run mode == Auto Show
var playing := false
var song_path := ""
var analysis: SongAnalysis
## [{ t: float, kind: "cue"|"chase"|"effect", arg }], sorted by t.
## "cue" arg is a 0-based section index; `cue_base` maps it to a number.
var timeline: Array = []
var cue_base := 1                          ## 1-based number of section 0's cue

var _player: AudioStreamPlayer
var _analyzer: SongAnalyzer
var _resume := 0.0
var _next_ev := 0
var _next_beat := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = AudioStreamPlayer.new()
	_player.bus = "Master"
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


func set_show(events: Array, first_cue_number := 1) -> void:
	timeline = events
	cue_base = maxi(first_cue_number, 1)
	timeline.sort_custom(func(x, y): return float(x["t"]) < float(y["t"]))
	_rewind(position())


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


## Fold every timeline event up to `t` and emit the resulting state: the
## last cue, and the final on/off for each chase and effect. Used after a
## seek so a jump lands on the right look *and* layers, not just the cue.
func _resync(t: float) -> void:
	var last_cue := -1
	var chase_state := {}
	var effect_state := {}
	for ev in timeline:
		if float(ev["t"]) > t:
			break
		match String(ev["kind"]):
			"cue": last_cue = int(ev["arg"])
			"chase": chase_state[String(ev["arg"]["name"])] = bool(ev["arg"]["on"])
			"effect": effect_state[String(ev["arg"]["name"])] = bool(ev["arg"]["on"])
	if last_cue >= 0:
		cue_fired.emit(cue_base + last_cue)
	for n in chase_state:
		chase_set.emit(n, chase_state[n])
	for n in effect_state:
		effect_set.emit(n, effect_state[n])


# ------------------------------------------------------------- PLAYBACK --

func _process(_delta: float) -> void:
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
			"cue":
				cue_fired.emit(cue_base + int(ev["arg"]))
			"chase":
				chase_set.emit(String(ev["arg"]["name"]), bool(ev["arg"]["on"]))
			"effect":
				effect_set.emit(String(ev["arg"]["name"]), bool(ev["arg"]["on"]))
		_next_ev += 1


# ------------------------------------------------------- SERIALIZATION --

func to_dict() -> Dictionary:
	return {
		"song_path": song_path,
		"analysis": analysis.to_dict() if analysis != null else {},
		"timeline": timeline.duplicate(true),
		"cue_base": cue_base,
	}


func from_dict(d: Dictionary) -> void:
	stop()
	song_path = String(d.get("song_path", ""))
	timeline = d.get("timeline", []).duplicate(true) if d.get("timeline", null) is Array else []
	cue_base = maxi(int(d.get("cue_base", 1)), 1)
	analysis = null
	var ad = d.get("analysis", {})
	if ad is Dictionary and not ad.is_empty():
		analysis = SongAnalysis.from_dict(ad)
	if song_path != "" and FileAccess.file_exists(song_path):
		var s := SongAnalyzer.load_stream(song_path)
		if s != null:
			_player.stream = s
	state_changed.emit()
