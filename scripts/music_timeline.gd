class_name MusicTimeline
extends VBoxContainer
## The Music Library's track timeline, shown when a track is
## double-clicked: the track's colour-coded waveform (the Auto Show
## panel's WaveHeatmap) sitting at the bottom of the view, zoomable with
## the mouse wheel, and under it a slimmer copy that always shows the
## whole track. A rectangle on that overview marks the part the big
## waveform shows: drag it to scroll, or click elsewhere on the overview
## to jump there.
##
## To the right of the waveform, Back to start and Play / Pause play the
## track; a red line marks the playback position (on both waveforms), and
## clicking the big waveform moves it. While playing, the view pages
## along when the playhead runs off its right edge. Space also plays /
## pauses. VirtualDJ's beat grid, when it knows the track, is drawn over
## the waveform: a line per beat, bolder at each bar (4 beats, counted
## from VirtualDJ's first beat).
##
## The waveform is decoded on a worker thread by the `native` extension
## (SongFeatures.waveform_file — MP3 / OGG / WAV, plus M4A / AAC through the
## OS's decoder), at WAVE_COLS_PER_SEC so zooming in shows real detail.
## An M4A is also decoded for playback on a second worker thread
## (SongAnalyzer.decode_os_stream); Play is enabled once it's ready.
## Above the waveforms there's only a status line with a progress bar,
## for loading and errors; it's empty once a track is shown.

## At the top, the master lighting timeline (TimelineTrack: position,
## strobe, cue and colour rows and a dimmer node line), which affects
## every fixture.
## Above the bar ruler, the song's structure (Intro / Verse / Chorus / ...,
## from SongAnalyzer, run in the background when a track opens; with
## VirtualDJ's beat grid swapped in and the section borders snapped to its
## bars when it knows the track). Beside it, two small buttons: lock /
## unlock editing the structure (drag a border, right-click a section),
## and generate an Auto Show light show from it (generate_show_requested).

## Ask the shell to build an Auto Show light show for `path` from
## `analysis` (its possibly-edited structure).
signal generate_show_requested(path: String, analysis: SongAnalysis)

## Waveform columns per second of audio: ~10 ms each.
const WAVE_COLS_PER_SEC := 100
## How much of the track the zoomable waveform shows at first, seconds.
const INITIAL_VIEW := 30.0
## Recently opened tracks' waveforms kept in memory.
const CACHE_SIZE := 6
const BEATS_PER_BAR := 4
const PLAYHEAD_COLOR := Color(1.0, 0.22, 0.22)
## The transport buttons: squares this size, stacked this far apart,
## pinned to the bottom of the waveform (two fit beside the default
## waveform + bar ruler).
const _BUTTON_WIDTH := 48.0
const _BUTTON_GAP := 6.0
## The zoomable waveform's height.
const WAVE_HEIGHT_DEFAULT := 90.0

var _status: Label
var _wave_note := ""            # status line: waveform loading / errors
var _play_note := ""            # status line: preparing / can't play the audio
var _progress: ProgressBar
var _spacer: Control
var _wave: WaveHeatmap
var _ruler: BarRuler
var _structure: StructureBar
var _master: TimelineTrack
var _master_plate: TimelineTrack.NamePlate
var _lock_btn: TransportButton
var _gen_btn: TransportButton
var _structure_locked := true
var _struct_cache: Dictionary = {}   # path -> SongAnalysis (with any edits)
var _button_col: Control
var _overview: WaveHeatmap
var _box: ViewBox
var _reset_btn: TransportButton
var _play_btn: TransportButton

var _path := ""
var _song: VirtualDjDatabase.Song = null
var _sf = null                  # SongFeatures doing the current waveform decode
var _thread: Thread
var _result: Dictionary = {}
var _cache: Dictionary = {}     # path -> SongAnalysis
var _cache_order: Array = []

# Playback.
var _player: AudioStreamPlayer
var _stream_path := ""          # the track _player.stream holds (kept for a reopen)
var _play_thread: Thread        # decoding an M4A for playback
var _play_sf = null
var _play_result: Dictionary = {}
var _pos := 0.0                 # playback position while stopped / paused
var _was_playing := false
var _scrubbing := false         # dragging the playhead with the mouse


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 6)

	var load_row := HBoxContainer.new()
	add_child(load_row)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	load_row.add_child(_status)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(220, 0)
	_progress.max_value = 1.0
	_progress.step = 0.001
	_progress.visible = false
	load_row.add_child(_progress)

	# Everything above stays at the top; the waveforms sit at the bottom.
	_spacer = Control.new()
	_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_spacer)

	# The zoomable waveform, with the transport buttons stacked to its right.
	var wave_row := HBoxContainer.new()
	wave_row.add_theme_constant_override("separation", 6)
	add_child(wave_row)
	var wave_col := VBoxContainer.new()
	wave_col.add_theme_constant_override("separation", 0)
	wave_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wave_row.add_child(wave_col)
	_wave = WaveHeatmap.new()
	_wave.custom_minimum_size = Vector2(0, WAVE_HEIGHT_DEFAULT)
	_wave.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_wave.zoomable = true
	_wave.cursor_color = PLAYHEAD_COLOR
	_wave.tooltip_text = "Click or drag: move the playhead · Mouse wheel: zoom · Shift+wheel: scroll"
	_wave.background_color = Color.BLACK
	_wave.view_changed.connect(_box_follow)
	_wave.seek_requested.connect(begin_scrub)
	_wave.seek_dragged.connect(scrub_to)
	_wave.seek_released.connect(end_scrub)
	# The master lighting timeline (all fixtures), at the top.
	_master = TimelineTrack.new()
	_master.target = TimelineTrack.Target.MASTER
	_master.title = "Master"
	_master.wave = _wave
	wave_col.add_child(_master)
	_master.item_rect_changed.connect(_place_buttons)
	# The song's structure, above the bar ruler and as tall.
	_structure = StructureBar.new()
	_structure.custom_minimum_size = Vector2(0, BarRuler.HEIGHT)
	_structure.show_cursor = false
	_structure.editable = false
	_structure.seek_requested.connect(seek)
	_structure.tooltip_text = "Song structure: unlock to drag a border or right-click a section"
	wave_col.add_child(_structure)
	# The lock / generate buttons stay level with it.
	_structure.item_rect_changed.connect(_place_buttons)
	# The bar-number strip along its top, carrying the playhead's marker.
	_ruler = BarRuler.new()
	_ruler.wave = _wave
	_ruler.tooltip_text = "Click or drag: move the playhead"
	_ruler.pressed.connect(begin_scrub)
	_ruler.dragged.connect(scrub_to)
	_ruler.released.connect(end_scrub)
	wave_col.add_child(_ruler)
	wave_col.add_child(_wave)

	# A plain holder, not a box: the buttons keep their square size, placed
	# by _place_buttons() (transport at the bottom, the small pair at the
	# top), without making the row taller.
	var buttons := Control.new()
	buttons.custom_minimum_size = Vector2(_BUTTON_WIDTH, 0)
	buttons.size_flags_vertical = Control.SIZE_FILL
	_button_col = buttons
	buttons.resized.connect(_place_buttons)
	wave_row.add_child(buttons)
	_reset_btn = TransportButton.new()
	_reset_btn.glyph = TransportButton.Glyph.TO_START
	_reset_btn.pressed.connect(rewind)
	_reset_btn.tooltip_text = "Back to the start"
	buttons.add_child(_reset_btn)
	_play_btn = TransportButton.new()
	_play_btn.glyph = TransportButton.Glyph.PLAY
	_play_btn.pressed.connect(toggle_play)
	_play_btn.tooltip_text = "Play / pause (Space)"
	buttons.add_child(_play_btn)
	# Beside the structure bar: lock / unlock editing it, and generate a
	# light show from it.
	_lock_btn = TransportButton.new()
	_lock_btn.glyph = TransportButton.Glyph.LOCKED
	_lock_btn.pressed.connect(toggle_structure_lock)
	buttons.add_child(_lock_btn)
	_gen_btn = TransportButton.new()
	_gen_btn.glyph = TransportButton.Glyph.GENERATE
	_gen_btn.tooltip_text = "Generate an Auto Show light show from this structure"
	_gen_btn.pressed.connect(generate_show)
	buttons.add_child(_gen_btn)
	for b in [_reset_btn, _play_btn, _lock_btn, _gen_btn]:
		b.focus_mode = Control.FOCUS_NONE
	# Beside the master timeline: its name, vertically, on a filled plate.
	_master_plate = TimelineTrack.NamePlate.new()
	_master_plate.track = _master
	buttons.add_child(_master_plate)
	_place_buttons()
	_update_structure_buttons()

	# The whole-track overview, lined up under the waveform.
	var over_row := HBoxContainer.new()
	over_row.add_theme_constant_override("separation", 6)
	add_child(over_row)
	_overview = WaveHeatmap.new()
	_overview.custom_minimum_size = Vector2(0, 44)
	_overview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_overview.cursor_color = PLAYHEAD_COLOR
	_overview.background_color = Color.BLACK
	over_row.add_child(_overview)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(_BUTTON_WIDTH, 0)
	over_row.add_child(pad)
	_box = ViewBox.new()
	_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	_box.tooltip_text = "Drag to scroll · click to jump"
	_box.view_moved.connect(func(start: float): _wave.set_view(start, _wave.visible_length()))
	_overview.add_child(_box)

	_player = AudioStreamPlayer.new()
	add_child(_player)

	visibility_changed.connect(func():
		if not is_visible_in_tree():
			pause())
	_update_transport()


func _exit_tree() -> void:
	_stop_loading()
	_stop_stream_load()


## Show `path`'s timeline. `song` is VirtualDJ's database entry for it,
## when it has one — that's where the beat grid comes from.
func open(path: String, song: VirtualDjDatabase.Song = null) -> void:
	_stop_loading()
	if path != _path:
		_stop_playback()
	_path = path
	_song = song
	_set_analysis(null)

	if _cache.has(path):
		_touch_cache(path)
		_set_analysis(_cache[path])
	elif not ClassDB.class_exists("SongFeatures"):
		_set_wave_note("Waveforms need the native extension — build it with addons/native/build.py (see addons/native/BUILD.md).")
	elif SongAnalyzer.is_os_format(path) and not SongAnalyzer.os_decoding_available():
		_set_wave_note("This system has no decoder for .%s files (needs Windows with Media Foundation, or macOS)." % path.get_extension().to_lower())
	elif not FileAccess.file_exists(path):
		_set_wave_note("File not found.")
	else:
		_set_wave_note("Reading waveform…")
		_progress.value = 0.0
		_progress.visible = true
		_result = {}
		_sf = ClassDB.instantiate("SongFeatures")
		_thread = Thread.new()
		_thread.start(_decode.bind(_sf, path))
	_load_playback(path)
	_load_structure(path)


## The track currently shown.
func current_path() -> String:
	return _path


func is_loading() -> bool:
	return _thread != null


## Whether the track's audio is still being prepared for playback.
func is_loading_playback() -> bool:
	return _play_thread != null


## The zoomable waveform (for tests / later features).
func wave() -> WaveHeatmap:
	return _wave


func overview() -> WaveHeatmap:
	return _overview


func ruler() -> BarRuler:
	return _ruler


func overview_box() -> ViewBox:
	return _box


func play_button() -> TransportButton:
	return _play_btn


func reset_button() -> TransportButton:
	return _reset_btn


# -------------------------------------------------------------- PLAYBACK --

## Whether the track can be played (its audio is loaded).
func can_play() -> bool:
	return _player.stream != null and _stream_path == _path


func is_playing() -> bool:
	return _player.playing


## The playback position, seconds.
func playback_position() -> float:
	if _player.playing:
		# Smooth between mixes, and line up with what's actually heard.
		var t := _player.get_playback_position() + AudioServer.get_time_since_last_mix() \
				- AudioServer.get_output_latency()
		return clampf(t, 0.0, _length())
	return _pos


func toggle_play() -> void:
	if _player.playing:
		pause()
	else:
		play()


func play() -> void:
	if not can_play() or _player.playing:
		return
	if _pos >= _length() - 0.05:
		_pos = 0.0
	_player.play(_pos)
	_was_playing = true
	_update_transport()


func pause() -> void:
	if not _player.playing:
		return
	# Freeze exactly where the playhead was last drawn (it's redrawn every
	# frame while playing) rather than re-reading the audio clock here,
	# between frames, which comes out a little later than what's on
	# screen and would nudge the line forward. Resuming plays from this
	# same spot.
	_pos = _wave.song_pos if _wave.show_cursor else playback_position()
	_player.stop()
	_was_playing = false
	_update_transport()


## Back to the start (still playing, if it was), and scroll there.
func rewind() -> void:
	seek(0.0)
	_wave.set_view(0.0, _wave.visible_length())


## Start moving the playhead with the mouse (ruler or waveform press).
## While the button's held the line follows the pointer; if the track is
## playing it keeps playing where it was, and jumps there on release —
## no stuttering scrub.
func begin_scrub(t: float) -> void:
	_scrubbing = true
	scrub_to(t)


func scrub_to(t: float) -> void:
	if not _scrubbing:
		return
	_pos = clampf(t, 0.0, _length())
	_update_cursor()


func end_scrub(t: float) -> void:
	if not _scrubbing:
		return
	_scrubbing = false
	seek(t)


func is_scrubbing() -> bool:
	return _scrubbing


## Move the playback position to `t` seconds.
func seek(t: float) -> void:
	_pos = clampf(t, 0.0, _length())
	if _player.playing:
		_player.seek(_pos)
	_update_cursor()


func _length() -> float:
	if _player.stream != null:
		return _player.stream.get_length()
	return _wave.duration() if _wave.analysis != null else 0.0


## Load `path`'s audio into the player: at once for MP3 / OGG / WAV, on a
## worker thread for M4A / AAC. Reopening the track keeps what's loaded.
func _load_playback(path: String) -> void:
	if _stream_path == path and _player.stream != null:
		_update_transport()
		return
	_stop_stream_load()
	_player.stream = null
	_stream_path = ""
	_pos = 0.0
	if not FileAccess.file_exists(path):
		_update_transport()
		return
	if SongAnalyzer.is_os_format(path):
		if SongAnalyzer.os_decoding_available():
			_play_result = {}
			_play_sf = ClassDB.instantiate("SongFeatures")
			_play_thread = Thread.new()
			_play_thread.start(func(): _play_result = SongAnalyzer.decode_os_stream(path, _play_sf))
	else:
		var s := SongAnalyzer.load_stream(path)
		if s != null:
			_player.stream = s
			_stream_path = path
	_update_transport()


func _stop_stream_load() -> void:
	if _play_thread == null:
		return
	if _play_sf != null:
		_play_sf.cancel()
	_play_thread.wait_to_finish()
	_play_thread = null
	_play_sf = null
	_play_result = {}


func _stop_playback() -> void:
	_player.stop()
	_was_playing = false
	_pos = 0.0


func _update_transport() -> void:
	_play_btn.glyph = TransportButton.Glyph.PAUSE if _player.playing else TransportButton.Glyph.PLAY
	_play_btn.disabled = not can_play()
	_reset_btn.disabled = not can_play()
	# On the status line, where they're seen without hovering.
	if _play_thread != null:
		_play_note = "Preparing the audio…"
	elif not can_play() and _path != "" and _wave.analysis != null:
		_play_note = "Can't play this track: %s." % String(_play_result.get("error", "unsupported audio")) \
				if not _play_result.is_empty() else "Can't play this track."
	else:
		_play_note = ""
	_show_status()
	_play_btn.queue_redraw()
	_update_cursor()


func _set_wave_note(text: String) -> void:
	_wave_note = text
	_show_status()


## The status line: the waveform's loading / error note and the
## playback one, whichever are set.
func _show_status() -> void:
	var parts := PackedStringArray()
	for n in [_wave_note, _play_note]:
		if n != "":
			parts.append(n)
	_status.text = "  ·  ".join(parts)


func _update_cursor() -> void:
	var on := can_play() and _wave.analysis != null
	var t := _pos if _scrubbing else playback_position()
	for w in [_wave, _overview]:
		w.show_cursor = on
		if not is_equal_approx(w.song_pos, t):
			w.song_pos = t
		w.queue_redraw()
	_ruler.queue_redraw()


func _unhandled_key_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		toggle_play()
		get_viewport().set_input_as_handled()


# ----------------------------------------------------------- PER FRAME --

func _process(_delta: float) -> void:
	if _thread != null:
		if _thread.is_alive():
			_progress.value = _sf.get_progress()
		else:
			_finish_wave_load()
	if _play_thread != null and not _play_thread.is_alive():
		_finish_stream_load()

	if _player.playing:
		# While the playhead's being dragged it follows the mouse, not the
		# audio (which jumps there on release).
		if not _scrubbing:
			var before := _wave.song_pos
			_update_cursor()
			_follow_playhead(before, _wave.song_pos)
	elif _was_playing:
		# Played to the end.
		_was_playing = false
		_pos = _length()
		_update_transport()


## Page the zoomable view along when the playhead runs off its right edge
## (only then — scrolling elsewhere while playing is left alone).
func _follow_playhead(before: float, now: float) -> void:
	var end := _wave.view_start + _wave.visible_length()
	if before <= end and now > end:
		_wave.set_view(now, _wave.visible_length())


func _finish_wave_load() -> void:
	_thread.wait_to_finish()
	_thread = null
	_sf = null
	_progress.visible = false
	if not bool(_result.get("ok", false)):
		_set_wave_note("Couldn't read the waveform: %s." % String(_result.get("error", "unknown error")))
		return
	var a := SongAnalysis.new()
	a.path = _path
	a.duration = float(_result["duration"])
	a.wave_lo = _result["wave_lo"]
	a.wave_mid = _result["wave_mid"]
	a.wave_hi = _result["wave_hi"]
	a.wave_peak = _result["wave_peak"]
	_result = {}
	_cache[_path] = a
	_touch_cache(_path)
	_set_analysis(a)


func _finish_stream_load() -> void:
	_play_thread.wait_to_finish()
	_play_thread = null
	_play_sf = null
	var s: AudioStream = _play_result.get("stream")
	if s != null:
		_player.stream = s
		_stream_path = _path
		_play_result = {}
	_update_transport()


# ---------------------------------------------------------------- VIEW --

## Stop and discard an in-flight waveform decode (leaving the view, or
## opening another track).
func _stop_loading() -> void:
	if _thread == null:
		return
	if _sf != null:
		_sf.cancel()
	_thread.wait_to_finish()
	_thread = null
	_sf = null
	_progress.visible = false


func _decode(sf, path: String) -> void:
	_result = sf.waveform_file(path, WAVE_COLS_PER_SEC)


func _touch_cache(path: String) -> void:
	_cache_order.erase(path)
	_cache_order.append(path)
	while _cache_order.size() > CACHE_SIZE:
		_cache.erase(_cache_order.pop_front())


func _set_analysis(a: SongAnalysis) -> void:
	_wave.set_analysis(a)
	_overview.set_analysis(a)
	_box.duration = a.duration if a != null else 0.0
	_set_wave_note("")
	if a == null:
		_wave.set_beat_grid(PackedFloat32Array())
		_box.set_view(0.0, 0.0)
		_update_cursor()
		return
	_apply_beat_grid(a.duration)
	_wave.set_view(0.0, minf(INITIAL_VIEW, a.duration))
	_box_follow(_wave.view_start, _wave.visible_length())
	_update_cursor()


## VirtualDJ's beat grid for the track (variable-tempo grids included),
## bars counted from its first beat.
func _apply_beat_grid(duration: float) -> void:
	if _song == null:
		_wave.set_beat_grid(PackedFloat32Array())
		return
	var beats := _song.beat_times(duration)
	# May be negative: VirtualDJ's first beat can sit just before 0 s.
	_wave.set_beat_grid(beats, BEATS_PER_BAR, _song.first_beat_index(beats))


# ------------------------------------------------------- SONG STRUCTURE --

## The structure bar (for tests / later features).
## The master lighting timeline (all fixtures).
func master_track() -> TimelineTrack:
	return _master


func master_plate() -> TimelineTrack.NamePlate:
	return _master_plate


func structure_bar() -> StructureBar:
	return _structure


func lock_button() -> TransportButton:
	return _lock_btn


func generate_button() -> TransportButton:
	return _gen_btn


## The current track's analysed structure, or null while it's analysing
## (or when it can't be).
func structure() -> SongAnalysis:
	return _structure.analysis


func is_structure_locked() -> bool:
	return _structure_locked


func toggle_structure_lock() -> void:
	set_structure_locked(not _structure_locked)


## Locked: the structure bar only seeks. Unlocked: drag a section border
## (snapped to a bar) or right-click a section to relabel / split / delete.
func set_structure_locked(locked: bool) -> void:
	_structure_locked = locked
	_structure.editable = not locked
	_update_structure_buttons()


## Ask for an Auto Show light show built from the current structure.
func generate_show() -> void:
	if _structure.analysis != null:
		generate_show_requested.emit(_path, _structure.analysis)


func _update_structure_buttons() -> void:
	var ready := _structure.analysis != null
	_lock_btn.glyph = TransportButton.Glyph.LOCKED if _structure_locked else TransportButton.Glyph.UNLOCKED
	if _structure_locked:
		_lock_btn.tooltip_text = "Song structure locked: click to edit it"
	else:
		_lock_btn.tooltip_text = "Song structure editable: click to lock it"
	_lock_btn.disabled = not ready
	_gen_btn.disabled = not ready


## Analyse `path`'s structure in the background (cached per track, edits
## included). Needs the native extension (seconds; no muted playback).
func _load_structure(path: String) -> void:
	if _struct_cache.has(path):
		_set_structure(_struct_cache[path])
		return
	_set_structure(null)
	if not SongAnalyzer.fast_available():
		_structure.placeholder = "song structure needs the native extension"
		return
	if SongAnalyzer.is_os_format(path) and not SongAnalyzer.os_decoding_available():
		_structure.placeholder = "can't decode this format here"
		return
	if not FileAccess.file_exists(path):
		_structure.placeholder = ""
		return
	_structure.placeholder = "analysing the song structure..."
	# One analyser per track: a result for a track that's since been left
	# is still cached, just not shown.
	var an := SongAnalyzer.new()
	add_child(an)
	var song := _song
	an.finished.connect(func(a: SongAnalysis):
		an.queue_free()
		_structure_ready(path, a, song))
	an.failed.connect(func(m: String):
		an.queue_free()
		if path == _path:
			_structure.placeholder = "couldn't analyse the structure: " + m.trim_suffix(".")
			_structure.queue_redraw())
	an.analyse(path)


func _structure_ready(path: String, a: SongAnalysis, song: VirtualDjDatabase.Song) -> void:
	if song != null:
		apply_vdj_grid(a, song)
	_struct_cache[path] = a
	if path == _path:
		_set_structure(a)


func _set_structure(a: SongAnalysis) -> void:
	_structure.set_analysis(a)
	_structure.set_view(_wave.view_start, _wave.visible_length() if _wave.analysis != null else 0.0)
	_update_structure_buttons()


## Use VirtualDJ's beat grid (what the decks play to) in place of the
## analyser's own: its beats, its bars (four beats from its first beat),
## its tempo; and move each section border to the nearest of its bars,
## so the structure lines up with the bar ruler.
static func apply_vdj_grid(a: SongAnalysis, song: VirtualDjDatabase.Song) -> void:
	var beats := song.beat_times(a.duration)
	if beats.size() < 2:
		return
	var phase := song.first_beat_index(beats)
	var bars := PackedFloat32Array()
	for i in range(beats.size()):
		if posmod(i - phase, BEATS_PER_BAR) == 0:
			bars.append(beats[i])
	a.beat_times = beats
	a.downbeats = bars
	if song.best_bpm() > 0.0:
		a.bpm = song.best_bpm()
	if bars.is_empty():
		return
	var secs: Array = a.sections
	for i in range(1, secs.size()):
		var t: float = secs[i]["start"]
		var j := clampi(bars.bsearch(t), 0, bars.size() - 1)
		if j > 0 and absf(bars[j - 1] - t) < absf(bars[j] - t):
			j -= 1
		secs[i]["start"] = bars[j]
		secs[i - 1]["end"] = bars[j]
	# Snapping can collapse a very short section to nothing: drop it.
	for i in range(secs.size() - 1, -1, -1):
		if float(secs[i]["end"]) - float(secs[i]["start"]) < 0.01 and secs.size() > 1:
			if i > 0:
				secs[i - 1]["end"] = secs[i]["end"]
			else:
				secs[i + 1]["start"] = secs[i]["start"]
			secs.remove_at(i)


## Square transport buttons stacked at the bottom of their column (the
## waveform's bottom edge): Play / Pause lowest, Back to start above it.
func _place_buttons() -> void:
	if _button_col == null or _play_btn == null or _reset_btn == null:
		return   # still being built
	var h := _button_col.size.y
	_play_btn.position = Vector2(0, h - _BUTTON_WIDTH)
	_reset_btn.position = Vector2(0, h - 2.0 * _BUTTON_WIDTH - _BUTTON_GAP)
	for b in [_reset_btn, _play_btn]:
		b.size = Vector2(_BUTTON_WIDTH, _BUTTON_WIDTH)
	# The small pair, level with the structure bar (below the master
	# timeline): squares as tall as it, side by side.
	if _lock_btn != null and _gen_btn != null and _structure != null:
		var sq := BarRuler.HEIGHT
		var x0 := (_BUTTON_WIDTH - 2.0 * sq - _BUTTON_GAP) * 0.5
		var y := _structure.position.y
		_lock_btn.position = Vector2(x0, y)
		_gen_btn.position = Vector2(x0 + sq + _BUTTON_GAP, y)
		for b in [_lock_btn, _gen_btn]:
			b.size = Vector2(sq, sq)
	# The master timeline's name plate fills the column beside it.
	if _master_plate != null and _master != null:
		_master_plate.position = Vector2(0, _master.position.y)
		_master_plate.size = Vector2(_BUTTON_WIDTH, _master.size.y)


## Keep the overview's rectangle on the zoomable waveform's window.
func _box_follow(start: float, length: float) -> void:
	_box.set_view(start, length)
	_ruler.queue_redraw()
	_structure.set_view(start, length)
	_master.queue_redraw()


## The strip along the top of the zoomable waveform: bar numbers (from 1,
## counted from VirtualDJ's first beat, like the waveform's bold bar
## lines) and the playhead's marker — an inverted triangle on top of its
## line. Press / drag / release with the left button to move the
## playhead. Draws from `wave`'s view, beat grid and playhead.
class BarRuler:
	extends Control

	signal pressed(seconds: float)
	signal dragged(seconds: float)
	signal released(seconds: float)

	const HEIGHT := 18.0
	## Closest two drawn bar numbers may be, pixels (wider gaps when
	## zoomed out: every 2nd, 4th, 8th... bar).
	const LABEL_GAP := 34.0
	const BG := Color(0.13, 0.13, 0.15)
	const TICK := Color(1, 1, 1, 0.35)
	const BEAT_TICK := Color(1, 1, 1, 0.22)
	const TEXT := Color(0.78, 0.78, 0.82)
	const FONT_SIZE := 11
	const MARKER_W := 12.0
	const MARKER_H := 9.0

	var wave: WaveHeatmap
	var _dragging := false

	func _ready() -> void:
		custom_minimum_size = Vector2(0, HEIGHT)
		mouse_filter = Control.MOUSE_FILTER_STOP

	## The ticks drawn for the current view: [[x, is_bar], ...] — the
	## waveform's own grid lines, so beats appear (and drop out) with it.
	func ticks() -> Array:
		if wave == null or wave.analysis == null:
			return []
		return wave.grid_lines(wave.view_start, wave.view_start + wave.visible_length())

	## The bar numbers drawn for the current view: [[x, number], ...].
	func bar_labels() -> Array:
		var out: Array = []
		if wave == null or wave.analysis == null:
			return out
		var beats := wave.grid_beats
		var per := wave.beats_per_bar
		if beats.size() < 2:
			return out
		var t0 := wave.view_start
		var t1 := t0 + wave.visible_length()
		var i0 := beats.bsearch(t0)
		var i1 := beats.bsearch(t1, false)
		if i1 <= i0:
			return out
		# Thin to every 2nd / 4th / ... bar so numbers don't collide.
		var j := clampi(i0, 0, beats.size() - 2)
		var bar_px := (beats[j + 1] - beats[j]) * per / wave.visible_length() * size.x
		var every := 1
		while bar_px * every < LABEL_GAP and every < 1 << 20:
			every *= 2
		# First bar start at or after i0.
		var i := i0 + posmod(wave.bar_phase - i0, per)
		while i < i1:
			var n := floori(float(i - wave.bar_phase) / per) + 1
			if n >= 1 and (n - 1) % every == 0:
				out.append([wave.time_to_x(beats[i]), n])
			i += per
		return out

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), BG)
		if wave == null or wave.analysis == null:
			return
		# Bar and beat ticks, exactly where the waveform draws its grid lines
		# (and thinned the same way: beats only once they're far enough
		# apart to read). Short for beats, longer for bars; numbered bars
		# get the longest, with their number beside it.
		for tick in ticks():
			var tx: float = tick[0]
			if tick[1]:
				draw_line(Vector2(tx, size.y * 0.6), Vector2(tx, size.y), TICK, 1.0)
			else:
				draw_line(Vector2(tx, size.y * 0.75), Vector2(tx, size.y), BEAT_TICK, 1.0)
		var font := get_theme_default_font()
		for lab in bar_labels():
			var x: float = lab[0]
			draw_line(Vector2(x, size.y * 0.45), Vector2(x, size.y), TICK, 1.0)
			draw_string(font, Vector2(x + 3.0, size.y - 5.0), str(lab[1]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, TEXT)
		if wave.show_cursor:
			var t := wave.song_pos
			if t >= wave.view_start and t <= wave.view_start + wave.visible_length():
				var px := wave.time_to_x(t)
				# The line runs on into the waveform's own playhead line.
				draw_line(Vector2(px, MARKER_H), Vector2(px, size.y), wave.cursor_color, 2.0)
				draw_colored_polygon(PackedVector2Array([
					Vector2(px - MARKER_W * 0.5, 0.0), Vector2(px + MARKER_W * 0.5, 0.0),
					Vector2(px, MARKER_H)]), wave.cursor_color)

	func _x_to_time(x: float) -> float:
		return clampf(wave.x_to_time(x), 0.0, wave.duration())

	func _gui_input(event: InputEvent) -> void:
		if wave == null or wave.analysis == null:
			return
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging = true
				pressed.emit(_x_to_time(event.position.x))
			elif _dragging:
				_dragging = false
				released.emit(_x_to_time(event.position.x))
			accept_event()
		elif event is InputEventMouseMotion and _dragging:
			dragged.emit(_x_to_time(event.position.x))
			accept_event()


## A transport button whose icon is drawn rather than taken from the font
## (the default font has no media symbols).
class TransportButton:
	extends Button

	enum Glyph { TO_START, PLAY, PAUSE, LOCKED, UNLOCKED, GENERATE }

	var glyph := Glyph.PLAY:
		set(v):
			glyph = v
			queue_redraw()

	func _draw() -> void:
		var c := get_theme_color("font_disabled_color" if disabled else "font_color")
		var s := minf(minf(size.x, size.y) * 0.36, 18.0)
		var o := size * 0.5
		match glyph:
			Glyph.PLAY:
				draw_colored_polygon(PackedVector2Array([
					o + Vector2(-s * 0.6, -s), o + Vector2(s, 0), o + Vector2(-s * 0.6, s)]), c)
			Glyph.PAUSE:
				draw_rect(Rect2(o + Vector2(-s * 0.75, -s), Vector2(s * 0.5, s * 2)), c)
				draw_rect(Rect2(o + Vector2(s * 0.25, -s), Vector2(s * 0.5, s * 2)), c)
			Glyph.TO_START:
				draw_rect(Rect2(o + Vector2(-s, -s), Vector2(s * 0.3, s * 2)), c)
				draw_colored_polygon(PackedVector2Array([
					o + Vector2(s * 0.8, -s), o + Vector2(-s * 0.55, 0), o + Vector2(s * 0.8, s)]), c)
			Glyph.LOCKED, Glyph.UNLOCKED:
				# A padlock: body below, shackle above. Unlocked, the shackle
				# is raised with its left leg out of the body.
				var w := s * 1.5
				var lw := maxf(s * 0.22, 1.5)
				var body_top := o.y - s * 0.1
				draw_rect(Rect2(Vector2(o.x - w * 0.5, body_top), Vector2(w, s * 1.1)), c)
				var unlocked := glyph == Glyph.UNLOCKED
				var r := w * 0.32
				var arc_y := o.y - s * 0.45 - (s * 0.4 if unlocked else 0.0)
				draw_arc(Vector2(o.x, arc_y), r, PI, TAU, 10, c, lw)
				draw_line(Vector2(o.x + r, arc_y), Vector2(o.x + r, body_top), c, lw)
				var left_end := arc_y + s * 0.2 if unlocked else body_top
				draw_line(Vector2(o.x - r, arc_y), Vector2(o.x - r, left_end), c, lw)
			Glyph.GENERATE:
				# A circular "rebuild" arrow.
				var rr := s * 0.85
				var wd := maxf(s * 0.22, 1.5)
				draw_arc(o, rr, -PI * 0.35, PI * 1.35, 16, c, wd)
				var tip := o + Vector2(cos(-PI * 0.35), sin(-PI * 0.35)) * rr
				draw_colored_polygon(PackedVector2Array([
					tip + Vector2(-s * 0.55, -s * 0.15), tip + Vector2(s * 0.25, -s * 0.5),
					tip + Vector2(s * 0.2, s * 0.35)]), c)


## The overview's "you are here" rectangle: the zoomable waveform's
## visible window, over the whole-track waveform. Drag it with the left
## button to scroll; press anywhere else to centre the window there (and
## keep dragging from there).
class ViewBox:
	extends Control

	signal view_moved(start: float)

	var duration := 0.0
	var start := 0.0
	var length := 0.0

	var _dragging := false
	var _grab := 0.0           # seconds from the box's start to the pointer

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func set_view(s: float, l: float) -> void:
		start = s
		length = l
		queue_redraw()

	func box_rect() -> Rect2:
		if duration <= 0.0:
			return Rect2()
		var x0 := start / duration * size.x
		var x1 := (start + length) / duration * size.x
		return Rect2(x0, 0.0, maxf(x1 - x0, 3.0), size.y)

	func _draw() -> void:
		if duration <= 0.0 or length <= 0.0:
			return
		var r := box_rect()
		# Dim what's outside the window so the window reads at a glance.
		draw_rect(Rect2(0, 0, r.position.x, size.y), Color(0, 0, 0, 0.35))
		draw_rect(Rect2(r.end.x, 0, size.x - r.end.x, size.y), Color(0, 0, 0, 0.35))
		draw_rect(r, Color(1, 1, 1, 0.10))
		draw_rect(r, Color(1, 1, 1, 0.85), false, 1.5)

	func _x_to_time(x: float) -> float:
		return x / maxf(size.x, 1.0) * duration

	func _gui_input(event: InputEvent) -> void:
		if duration <= 0.0:
			return
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				var t := _x_to_time(event.position.x)
				if box_rect().has_point(event.position):
					_grab = t - start
				else:
					# Jump: centre the window on the click.
					_grab = length * 0.5
					view_moved.emit(t - _grab)
				_dragging = true
			else:
				_dragging = false
			accept_event()
		elif event is InputEventMouseMotion and _dragging:
			view_moved.emit(_x_to_time(event.position.x) - _grab)
			accept_event()
