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

## Waveform columns per second of audio: ~10 ms each.
const WAVE_COLS_PER_SEC := 100
## How much of the track the zoomable waveform shows at first, seconds.
const INITIAL_VIEW := 30.0
## Recently opened tracks' waveforms kept in memory.
const CACHE_SIZE := 6
const BEATS_PER_BAR := 4
const PLAYHEAD_COLOR := Color(1.0, 0.22, 0.22)
const _BUTTON_WIDTH := 56.0
## The zoomable waveform's height: what it starts at, and the smallest the
## grip bar above it can drag it to. The largest is whatever room is free.
const WAVE_HEIGHT_DEFAULT := 90.0
const WAVE_HEIGHT_MIN := 40.0

var _status: Label
var _wave_note := ""            # status line: waveform loading / errors
var _play_note := ""            # status line: preparing / can't play the audio
var _progress: ProgressBar
var _spacer: Control
var _grip: SizeGrip
var _drag_start_height := 0.0
var _drag_max_height := 0.0
var _wave: WaveHeatmap
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

	# Drag up / down to make the waveform taller / shorter.
	_grip = SizeGrip.new()
	_grip.drag_started.connect(func():
		_drag_start_height = wave_height()
		_drag_max_height = maxf(wave_height() + _spacer.size.y, WAVE_HEIGHT_MIN))
	_grip.dragged.connect(func(dy: float): set_wave_height(_drag_start_height - dy))
	_grip.tooltip_text = "Drag to resize the waveform"
	add_child(_grip)

	# The zoomable waveform, with the transport buttons stacked to its right.
	var wave_row := HBoxContainer.new()
	wave_row.add_theme_constant_override("separation", 6)
	add_child(wave_row)
	_wave = WaveHeatmap.new()
	_wave.custom_minimum_size = Vector2(0, WAVE_HEIGHT_DEFAULT)
	_wave.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_wave.zoomable = true
	_wave.cursor_color = PLAYHEAD_COLOR
	_wave.tooltip_text = "Click: move the playhead · Mouse wheel: zoom · Shift+wheel: scroll"
	_wave.background_color = Color.BLACK
	_wave.view_changed.connect(_box_follow)
	_wave.seek_requested.connect(seek)
	wave_row.add_child(_wave)

	var buttons := VBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
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
	for b in [_reset_btn, _play_btn]:
		b.custom_minimum_size = Vector2(_BUTTON_WIDTH, 0)
		b.size_flags_vertical = Control.SIZE_EXPAND_FILL
		b.focus_mode = Control.FOCUS_NONE

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


func overview_box() -> ViewBox:
	return _box


func grip() -> SizeGrip:
	return _grip


## The zoomable waveform's height, pixels.
func wave_height() -> float:
	return _wave.custom_minimum_size.y


## Resize the zoomable waveform (the grip bar does this): at least
## WAVE_HEIGHT_MIN, at most what the free space above it allows.
func set_wave_height(h: float) -> void:
	_wave.custom_minimum_size.y = clampf(h, WAVE_HEIGHT_MIN, _max_wave_height())


## The tallest the waveform can be: its height plus the free space above
## it (measured at the start of a drag, since the layout lags the pointer).
func _max_wave_height() -> float:
	if _grip.is_dragging():
		return _drag_max_height
	return maxf(wave_height() + _spacer.size.y, WAVE_HEIGHT_MIN)


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
	var t := playback_position()
	for w in [_wave, _overview]:
		w.show_cursor = on
		if not is_equal_approx(w.song_pos, t):
			w.song_pos = t
		w.queue_redraw()


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


## Keep the overview's rectangle on the zoomable waveform's window.
func _box_follow(start: float, length: float) -> void:
	_box.set_view(start, length)


## The (invisible) strip above the waveform: drag it up or down to resize
## the waveform.
## Reports how far the pointer has moved vertically since the press, so
## the size tracks the pointer even after hitting a limit.
class SizeGrip:
	extends Control

	signal drag_started
	signal dragged(dy: float)

	const HEIGHT := 10.0
	var _dragging := false
	var _press_y := 0.0

	func _ready() -> void:
		# Nothing drawn: the resize cursor on hover is the only cue.
		custom_minimum_size = Vector2(0, HEIGHT)
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_VSIZE

	func is_dragging() -> bool:
		return _dragging

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
			if _dragging:
				_press_y = event.global_position.y
				drag_started.emit()
			accept_event()
		elif event is InputEventMouseMotion and _dragging:
			dragged.emit(event.global_position.y - _press_y)
			accept_event()


## A transport button whose icon is drawn rather than taken from the font
## (the default font has no media symbols).
class TransportButton:
	extends Button

	enum Glyph { TO_START, PLAY, PAUSE }

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
