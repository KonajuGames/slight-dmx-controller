class_name MusicTimeline
extends VBoxContainer
## DJ Edit Mode's track timeline, shown when a track is
## double-clicked: the track's colour-coded waveform (a WaveHeatmap)
## sitting at the bottom of the view, zoomable with
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
## Above the waveforms there's only a status line, for loading and
## errors; it's empty once a track is shown. While the track's being read,
## the whole-track waveform's background is the progress bar.

## Above it, in a vertically scrolling panel filling the space left, a
## timeline for every patched fixture (fixtures_provider), followed by one
## for each of its heads when it has more than one.
## Then the master lighting timeline (TimelineTrack: position, strobe,
## movement and colour rows and a dimmer node line), which affects every
## fixture.
## A song's timelines (every track's dimmer nodes, and the structure once
## edited) are kept in the show's timeline_store, keyed by fixture uid, and
## saved automatically when the song is left (another song opened, the
## timeline hidden, the app closed) — or by flush().
## A left-button drag on an empty part of the timelines selects an area
## (selection()): whole bars, beats, or exact times as the structure bar's
## snapping says, on every row the drag crosses — rows of several tracks
## included. A plain drag replaces the selection, Ctrl adds to it, and
## Shift extends the last area to take in the new one. A plain drag on a
## selected area's start / end resizes it (snapped; dimmer nodes on that
## edge go with it); inside it, moves the whole selection (snapped), its
## content landing — and overwriting — where it's dropped, on release.
## Delete clears the
## selected areas; Escape or Ctrl+D deselects; Ctrl+A selects everything,
## Ctrl+C copies, Ctrl+X cuts
## and Ctrl+V pastes (select_all(), copy_selection(), cut_selection(),
## paste()).
## Every timeline edit (dimmer nodes / line, Delete, cut, paste, the
## structure) can be undone with Ctrl+Z and redone with Ctrl+Y or
## Ctrl+Shift+Z (undo(), redo()) — per song, while the show's open.
## Above the bar ruler, the song's structure (Intro / Verse / Chorus / ...,
## from SongAnalyzer, run in the background when a track opens; with
## VirtualDJ's beat grid swapped in and the section borders snapped to its
## bars when it knows the track). Beside it, two small buttons: lock /
## unlock editing the structure (drag a border, right-click a section),
## and generate a light show into the timelines from it (generate_show(),
## TimelineGenerator).

## A song's timelines were saved to the store (flush()).
signal timelines_saved(path: String)
## The show's timelines folder changed (set_timeline_store()).
signal timeline_store_changed

## Waveform columns per second of audio: ~10 ms each.
const WAVE_COLS_PER_SEC := 100
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
## Returns the patched fixtures, in order, as
## [{key: String (stable for the session), name, profile: FixtureProfile,
## mode: int}]; refresh_fixtures() reads it.
var fixtures_provider := Callable()
var _fixture_scroll: ScrollContainer
var _fixture_list: VBoxContainer
var _fixture_empty: Label
var _fixture_tracks: Array[TimelineTrack] = []
## The show's named positions (set by the shell): the Position submenu's
## choices, and what the position rows draw in.
var positions: PositionLibrary:
	set(v):
		positions = v
		if _master != null:
			_master.positions = v
		for tr in _fixture_tracks:
			tr.positions = v
## The current show's timelines folder (set by the shell; null = none,
## timelines live only in memory).
var timeline_store: TimelineStore
var _songs := {}                # song path -> its timelines data (loaded / edited this session)
var _selection := TimelineSelection.new()
# An area selection being dragged: the row index (in _row_list()) and time
# where it started, the blocks to keep under it, and (Shift) the area it
# extends; empty = not selecting.
var _sel_drag := {}
## What Ctrl+C copied (kept across songs): {length, tracks: [{key, rows:
## {Row: [{t0, t1, nodes?}]}}]} — times relative to the copy's start.
var _clip := {}
## Undo / redo, per song path: {undo: [states], redo: [states], state:
## the current state} — a state being the song's timelines (tracks and any
## edited structure) as _snapshot() takes them.
const UNDO_LIMIT := 100
var _history := {}
var _batching := false          # several edits recorded as one undo step
var _dirty := false             # the open song's timelines changed since saved
var _wave: WaveHeatmap
var _ruler: BarRuler
var _structure: StructureBar
var _master: TimelineTrack
var _master_plate: TimelineTrack.NamePlate
var _lock_btn: TransportButton
var _gen_btn: TransportButton
var _structure_locked := true
var _struct_cache: Dictionary = {}   # path -> SongAnalysis (with any edits)
var _generated: Dictionary = {}      # path -> times Generate has run on it (the next variation)
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
# Middle-button drag panning: where it started (screen x) and the view's
# start then; _pan_x < 0 = not panning.
var _pan_x := -1.0
var _pan_from := 0.0


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

	# The fixtures' (and heads') timelines fill the space above the master
	# one, scrolling vertically. The scroll bar's space is always reserved,
	# taken out of the name plates' column, so the tracks stay exactly as
	# wide as the waveform below.
	_fixture_scroll = ScrollContainer.new()
	_fixture_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_fixture_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_fixture_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_RESERVE
	add_child(_fixture_scroll)
	_fixture_list = VBoxContainer.new()
	_fixture_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fixture_list.add_theme_constant_override("separation", 2)
	_fixture_scroll.add_child(_fixture_list)
	_fixture_empty = Label.new()
	_fixture_empty.text = "No fixtures patched."
	_fixture_empty.modulate = Color(1, 1, 1, 0.45)
	_fixture_list.add_child(_fixture_empty)

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
	_master.set_meta("key", "master")
	_master.dimmer_edited.connect(_mark_dirty)
	_master.selection = _selection
	_master.select_drag.connect(_on_select_drag)
	_master.playhead_drag.connect(_on_playhead_drag)
	_master.context_requested.connect(_on_context)
	_master.positions = positions
	wave_col.add_child(_master)
	_master.item_rect_changed.connect(_place_buttons)
	# The song's structure, above the bar ruler and as tall.
	_structure = StructureBar.new()
	_structure.custom_minimum_size = Vector2(0, BarRuler.HEIGHT)
	_structure.show_cursor = false
	_structure.editable = false
	_structure.seek_requested.connect(seek)
	_structure.tooltip_text = "Song structure: unlock to drag a border or right-click a section"
	_structure.structure_edited.connect(_on_structure_edited)
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
	_gen_btn.tooltip_text = "Generate a light show into the timelines from this song's structure, tempo and energy — press again for another variation (replaces them; Ctrl+Z undoes)"
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
			pause()
			flush()
			if is_panning():
				_pan_x = -1.0
				Input.set_default_cursor_shape(Input.CURSOR_ARROW))
	_update_transport()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		flush()                 # the app's closing: save the open song's timelines


func _exit_tree() -> void:
	flush()
	_stop_loading()
	_stop_stream_load()


## Show `path`'s timeline. `song` is VirtualDJ's database entry for it,
## when it has one — that's where the beat grid comes from.
func open(path: String, song: VirtualDjDatabase.Song = null) -> void:
	_stop_loading()
	if path != _path:
		_stop_playback()
		flush()                 # leaving the last song: save its timelines
		_selection.clear()
	_path = path
	_song = song
	_set_analysis(null)
	_show_song_data()

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
		# The whole-track waveform's background is the progress bar.
		_overview.progress = 0.0
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


## The playhead line dragged on a timeline: scrub, as on the ruler.
func _on_playhead_drag(_track: TimelineTrack, phase: int, t: float) -> void:
	match phase:
		TimelineTrack.SELECT_PRESS:
			begin_scrub(t)
		TimelineTrack.SELECT_MOVE:
			scrub_to(t)
		TimelineTrack.SELECT_RELEASE:
			end_scrub(t)


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
	for tr in [_master] + Array(_fixture_tracks):
		if tr != null:
			tr.update_playhead()


# ------------------------------------------------------ AREA SELECTION --

## The selected areas of the timelines.
func selection() -> TimelineSelection:
	return _selection


## Every timeline row, top to bottom on screen: the fixtures' tracks (in
## order, each's rows top down) then the master's, as [{track, row}].
func _row_list() -> Array:
	var out: Array = []
	for tr in Array(_fixture_tracks) + [_master]:
		var rs: Array = tr.rows.duplicate()
		rs.reverse()                    # rows are kept bottom to top
		for r in rs:
			out.append({"track": tr, "row": r})
	return out


## The index in `rows` of the row at global y (the nearest, if between or
## beyond them).
func _row_index_at(rows: Array, gy: float) -> int:
	var best := 0
	var best_d := INF
	for i in range(rows.size()):
		var tr: TimelineTrack = rows[i]["track"]
		var r := tr.row_rect(rows[i]["row"])
		var top := tr.get_global_transform() * r.position
		var d := 0.0 if gy >= top.y and gy < top.y + r.size.y else minf(absf(gy - top.y), absf(gy - top.y - r.size.y))
		if d < best_d:
			best = i
			best_d = d
	return best


## The song time at global x (the timelines share the waveform's view).
func _time_at(gx: float) -> float:
	var wr := _wave.get_global_rect()
	var t := _wave.view_start + (gx - wr.position.x) / maxf(wr.size.x, 1.0) * _wave.visible_length()
	return clampf(t, 0.0, _wave.duration())


## The boundaries a selection snaps to for the structure bar's snapping:
## bar or beat starts (from the waveform's beat grid, else the structure
## analysis), or none (NONE, or no grid).
func _snap_grid() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if _structure.snap == StructureBar.Snap.NONE:
		return out
	var beats := _wave.grid_beats
	if not beats.is_empty():
		if _structure.snap == StructureBar.Snap.BEAT:
			return beats
		for i in range(beats.size()):
			if posmod(i - _wave.bar_phase, _wave.beats_per_bar) == 0:
				out.append(beats[i])
		return out
	var a: SongAnalysis = _struct_cache.get(_path)
	if a != null:
		return a.beat_times if _structure.snap == StructureBar.Snap.BEAT else a.downbeats
	return out


## The span from `ta` to `tb` widened to whole grid cells (bars / beats):
## from the start of the cell holding the earlier to the end of the cell
## holding the later. As is with no grid.
func snap_span(ta: float, tb: float) -> Vector2:
	var lo := minf(ta, tb)
	var hi := maxf(ta, tb)
	var g := _snap_grid()
	if g.is_empty():
		return Vector2(lo, hi)
	var dur := _wave.duration()
	var i := g.bsearch(lo, false) - 1      # the last boundary <= lo
	var j := g.bsearch(hi, false)          # the first boundary > hi
	return Vector2(g[i] if i >= 0 else 0.0, g[j] if j < g.size() else dur)


## Select every row of every timeline (fixtures', heads' and the master's)
## over the whole song (Ctrl+A). Returns whether there was a song to
## select in.
func select_all() -> bool:
	if _wave.analysis == null:
		return false
	var rows := _row_list()
	if rows.is_empty():
		return false
	_selection.set_blocks([TimelineSelection.block(_row_ids(rows, 0, rows.size() - 1), 0.0, _wave.duration())])
	return true


func _on_select_drag(_track: TimelineTrack, phase: int, gpos: Vector2, ctrl: bool, shift: bool) -> void:
	if _wave.analysis == null:
		return
	var rows := _row_list()
	if rows.is_empty():
		return
	if phase == TimelineTrack.SELECT_PRESS and not ctrl and not shift:
		var edge := _edge_at(_track, gpos)
		if not edge.is_empty():
			_sel_drag = edge
			return
		var key := String(_track.get_meta("key"))
		var row := _track.row_at(_track.get_global_transform().affine_inverse() * gpos)
		if _selection.has(key, row, _time_at(gpos.x)):
			_sel_drag = {"mode": "move", "from": _time_at(gpos.x), "blocks": _selection.blocks.duplicate(true),
				"gpos": gpos, "track": _track, "clip": _copy_clip()}
			return
	if not _sel_drag.is_empty() and _sel_drag.get("mode") == "edge":
		_drag_edge(phase, gpos)
		return
	if not _sel_drag.is_empty() and _sel_drag.get("mode") == "move":
		_drag_move(phase, gpos)
		return
	if phase == TimelineTrack.SELECT_PRESS:
		var keep: Array = []
		var extend := {}
		if shift and not _selection.is_empty():
			keep = _selection.blocks.slice(0, _selection.blocks.size() - 1)
			extend = _selection.blocks[-1]
		elif ctrl:
			keep = _selection.blocks.duplicate()
		_sel_drag = {"row": _row_index_at(rows, gpos.y), "t": _time_at(gpos.x), "keep": keep, "extend": extend}
	if _sel_drag.is_empty():
		return
	var i0: int = _sel_drag["row"]
	var i1 := _row_index_at(rows, gpos.y)
	var span := snap_span(_sel_drag["t"], _time_at(gpos.x))
	var lo := mini(i0, i1)
	var hi := maxi(i0, i1)
	var extend: Dictionary = _sel_drag["extend"]
	if not extend.is_empty():
		# Shift: from the last area through the new one — every row and
		# all the time between them.
		span = Vector2(minf(span.x, extend["t0"]), maxf(span.y, extend["t1"]))
		for k in range(rows.size()):
			if _row_ids(rows, k, k)[0] in extend["rows"]:
				lo = mini(lo, k)
				hi = maxi(hi, k)
	var blocks: Array = (_sel_drag["keep"] as Array).duplicate()
	if span.y > span.x:
		blocks.append(TimelineSelection.block(_row_ids(rows, lo, hi), span.x, span.y))
	_selection.set_blocks(blocks)
	if phase == TimelineTrack.SELECT_RELEASE:
		_sel_drag = {}


## Clear what's in the selected areas (Delete), by kind of row: the
## dimmer is blacked out across each span (TimelineTrack.clear_dimmer);
## the other rows have nothing to clear yet. Each row's overlapping spans
## are merged first. The selection stays. Returns whether anything changed.
func delete_selection() -> bool:
	var changed := false
	for tr in [_master] + Array(_fixture_tracks):
		var key := String(tr.get_meta("key"))
		for row in tr.rows:
			for span in _merged(_selection.spans_for(key, row)):
				match row:
					TimelineTrack.Row.DIMMER:
						if tr.clear_dimmer(span.x, span.y):
							changed = true
					TimelineTrack.Row.COLOUR:
						if tr.replace_colour(span.x, span.y, []):
							changed = true
					TimelineTrack.Row.POSITION:
						if tr.replace_position(span.x, span.y, []):
							changed = true
					TimelineTrack.Row.MOVEMENT:
						if tr.replace_movement(span.x, span.y, []):
							changed = true
					TimelineTrack.Row.STROBE:
						if tr.replace_strobe(span.x, span.y, []):
							changed = true
					_:
						pass
	if changed:
		_mark_dirty()
	return changed


## Copy what's in the selected areas (Ctrl+C), row by row, with times
## relative to the start of the earliest area: the dimmer line in each
## span; the other rows just their spans for now. Returns whether there
## was anything to copy.
func copy_selection() -> bool:
	if _selection.is_empty():
		return false
	_clip = _copy_clip()
	return true


## The selected areas' content as a clip ({length, tracks}), times
## relative to the earliest area's start.
func _copy_clip() -> Dictionary:
	var start := INF
	var finish := -INF
	for b in _selection.blocks:
		start = minf(start, b["t0"])
		finish = maxf(finish, b["t1"])
	var tracks: Array = []
	for tr in Array(_fixture_tracks) + [_master]:      # top to bottom
		var key := String(tr.get_meta("key"))
		var rows := {}
		for row in tr.rows:
			var parts: Array = []
			for span in _merged(_selection.spans_for(key, row)):
				var part := {"t0": span.x - start, "t1": span.y - start}
				match row:
					TimelineTrack.Row.DIMMER:
						# Only where the line has values (a fixture / head may
						# have none there: nothing to copy).
						var d: Vector2 = tr.dimmer_defined_span(span.x, span.y)
						if d.x >= 0.0:
							part = {"t0": d.x - start, "t1": d.y - start, "nodes": tr.dimmer_segment(d.x, d.y)}
					TimelineTrack.Row.COLOUR:
						part["segments"] = tr.colour_segment(span.x, span.y)
					TimelineTrack.Row.STROBE:
						part["strobes"] = tr.strobe_segment(span.x, span.y)
					TimelineTrack.Row.POSITION:
						part["positions"] = tr.position_segment(span.x, span.y)
					TimelineTrack.Row.MOVEMENT:
						part["movements"] = tr.movement_segment(span.x, span.y)
					_:
						pass
				parts.append(part)
			if not parts.is_empty():
				rows[row] = parts
		if not rows.is_empty():
			tracks.append({"key": key, "rows": rows})
	return {"length": finish - start, "tracks": tracks}


## Cut the selected areas (Ctrl+X): copy them, then clear them as Delete
## does. Returns whether there was anything to cut.
func cut_selection() -> bool:
	if not copy_selection():
		return false
	delete_selection()
	return true


## What's been copied ({} = nothing).
func clipboard() -> Dictionary:
	return _clip


## Paste what was copied (Ctrl+V). Where: at the start of the current
## selection, into the tracks it touches (one copied track goes into each
## of them; several pair off in order, repeating); with nothing selected,
## at the playhead, back into the tracks it came from. Each copied row goes
## into the same kind of row; a dimmer span replaces the line there
## (TimelineTrack.replace_dimmer: the level outside kept). The pasted
## areas become the selection. Returns whether anything was pasted.
## `here_track` / `here_time` (the context menu's Paste Here): paste at
## that time into that track instead.
func paste(here_track: TimelineTrack = null, here_time := 0.0) -> bool:
	if _clip.is_empty() or _wave.analysis == null:
		return false
	var sources: Array = _clip["tracks"]
	if sources.is_empty():
		return false
	var pairs: Array = []           # [[target track, source track]]
	var at: float
	if here_track != null:
		at = here_time
		pairs.append([here_track, sources[0]])
	elif not _selection.is_empty():
		at = INF
		var keys := {}
		for b in _selection.blocks:
			at = minf(at, b["t0"])
			for id in b["rows"]:
				keys[id.get_slice("|", 0)] = true
		var targets: Array = []
		for tr in Array(_fixture_tracks) + [_master]:
			if keys.has(String(tr.get_meta("key"))):
				targets.append(tr)
		for i in range(targets.size()):
			pairs.append([targets[i], sources[i % sources.size()]])
	else:
		at = _wave.song_pos
		for src in sources:
			var tr := _track_for(String(src["key"]))
			if tr != null:
				pairs.append([tr, src])
	var done := _paste_into(pairs, at)
	if done["blocks"].is_empty():
		return false
	_selection.set_blocks(done["blocks"])
	if done["changed"]:
		_mark_dirty()
	return true


## Put each [target track, clip track] pair's content in at `at` seconds.
## Returns {blocks: the areas it went into (selection blocks), changed}.
func _paste_into(pairs: Array, at: float) -> Dictionary:
	var dur := _wave.duration()
	var blocks: Array = []
	var changed := false
	for pair in pairs:
		var tr: TimelineTrack = pair[0]
		var src: Dictionary = pair[1]
		var key := String(tr.get_meta("key"))
		for row in src["rows"]:
			if not tr.has_row(row):
				continue
			for part in src["rows"][row]:
				var t0: float = at + part["t0"]
				var t1: float = minf(at + part["t1"], dur)
				if t1 <= t0:
					continue
				if row == TimelineTrack.Row.DIMMER and part.has("nodes"):
					changed = tr.replace_dimmer(at + part["t0"], at + part["t1"], part["nodes"]) or changed
				elif row == TimelineTrack.Row.COLOUR and part.has("segments"):
					changed = tr.replace_colour(at + part["t0"], at + part["t1"], part["segments"]) or changed
				elif row == TimelineTrack.Row.STROBE and part.has("strobes"):
					changed = tr.replace_strobe(at + part["t0"], at + part["t1"], part["strobes"]) or changed
				elif row == TimelineTrack.Row.POSITION and part.has("positions"):
					changed = tr.replace_position(at + part["t0"], at + part["t1"], part["positions"]) or changed
				elif row == TimelineTrack.Row.MOVEMENT and part.has("movements"):
					changed = tr.replace_movement(at + part["t0"], at + part["t1"], part["movements"]) or changed
				blocks.append(TimelineSelection.block(PackedStringArray([TimelineSelection.row_id(key, row)]), t0, t1))
	return {"blocks": blocks, "changed": changed}


func _track_for(key: String) -> TimelineTrack:
	for tr in [_master] + Array(_fixture_tracks):
		if String(tr.get_meta("key")) == key:
			return tr
	return null


# ---------------------------------------------------------- CONTEXT MENU --

enum { M_DELETE, M_UNDO, M_REDO, M_CUT, M_COPY, M_PASTE, M_PASTE_HERE, M_SELECT_ALL, M_DESELECT }
enum Dim { BLACK, HALF, FULL, FADE_IN, FADE_OUT, PULSE_IN, PULSE_OUT, SMOOTH, BEAT_PULSES, BAR_PULSES }
const DIM_LABELS := {Dim.BLACK: "Black (0%)", Dim.HALF: "Half (50%)", Dim.FULL: "Full (100%)",
	Dim.FADE_IN: "Fade In", Dim.FADE_OUT: "Fade Out", Dim.PULSE_IN: "Pulse In", Dim.PULSE_OUT: "Pulse Out",
	Dim.SMOOTH: "Smooth (ramp across)", Dim.BEAT_PULSES: "Pulse on Every Beat", Dim.BAR_PULSES: "Pulse on Every Bar"}
enum Col { STATIC, GRADIENT, RAINBOW, CLEAR, PRESET = 100 }
## The Strobe submenu: a speed (TimelineTrack.Strobe), or off.
const STROBE_OFF := -1
const COLOUR_PRESETS := [["Red", Color(1, 0, 0)], ["Orange", Color(1, 0.5, 0)], ["Yellow", Color(1, 1, 0)],
	["Green", Color(0, 1, 0)], ["Cyan", Color(0, 1, 1)], ["Blue", Color(0, 0, 1)], ["Purple", Color(0.5, 0, 1)],
	["Magenta", Color(1, 0, 1)], ["White", Color(1, 1, 1)]]

var _menu: PopupMenu
var _dimmer_menu: PopupMenu
var _colour_menu: PopupMenu
var _strobe_menu: PopupMenu
var _position_menu: PopupMenu
var _movement_menu: PopupMenu
const MOVEMENT_CLEAR := 1000
## The Movement submenu's sizes (of the pan / tilt range) and cycles (in
## bars), and the item ids they're listed under — small and slow enough
## for real moving heads to keep up.
const MOVEMENT_SIZES := [["Small", 0.02], ["Medium", 0.04], ["Large", 0.08]]
const MOVEMENT_CYCLES := [["1 bar", 1.0], ["2 bars", 2.0], ["4 bars", 4.0]]
const MOVEMENT_SIZE_ID := 200
const MOVEMENT_CYCLE_ID := 300
## The size / cycle new movements get (indices into the lists above).
var movement_size := 1
var movement_cycle := 1
const POSITION_CLEAR := 1000
var _ctx := {}                  # the right-click: {track, row, time}


## A right-click on a timeline: the actions that fit where it was — on
## the selection: Delete, Undo / Redo, Cut / Copy / Paste and, for the
## kinds of row selected, a Dimmer, Colour, Strobe, Position and Movement submenu; elsewhere: Undo /
## Redo, Paste Here, Select All.
func _on_context(track: TimelineTrack, row: int, gpos: Vector2, time: float) -> void:
	if _wave.analysis == null:
		return
	_ctx = {"track": track, "row": row, "time": time}
	var on_sel := _selection.has(String(track.get_meta("key")), row, time)
	context_items(on_sel)       # fills _menu
	var local := track.get_global_transform().affine_inverse() * gpos
	_menu.popup(Rect2i(Vector2i(track.get_screen_transform() * local), Vector2i.ZERO))


## Fill the context menu for a right-click on (`on_selection`) or off the
## selection. Returns the menu (for tests).
func context_items(on_selection: bool) -> PopupMenu:
	_ensure_menus()
	_menu.clear()
	var ctrl := KEY_MASK_CTRL
	if on_selection:
		_menu.add_item("Delete", M_DELETE, KEY_DELETE)
	if can_undo():
		_menu.add_item("Undo", M_UNDO, ctrl | KEY_Z)
	if can_redo():
		_menu.add_item("Redo", M_REDO, ctrl | KEY_Y)
	if on_selection:
		_menu.add_separator()
		_menu.add_item("Cut", M_CUT, ctrl | KEY_X)
		_menu.add_item("Copy", M_COPY, ctrl | KEY_C)
	if not _clip.is_empty():
		if on_selection:
			_menu.add_item("Paste", M_PASTE, ctrl | KEY_V)
		else:
			_menu.add_item("Paste Here", M_PASTE_HERE)
	if on_selection:
		var kinds := selected_row_kinds()
		if kinds.has(TimelineTrack.Row.DIMMER) or kinds.has(TimelineTrack.Row.COLOUR) or kinds.has(TimelineTrack.Row.STROBE) \
				or kinds.has(TimelineTrack.Row.POSITION) or kinds.has(TimelineTrack.Row.MOVEMENT):
			_menu.add_separator()
		if kinds.has(TimelineTrack.Row.DIMMER):
			_fill_dimmer_menu()
			_menu.add_submenu_node_item("Dimmer", _dimmer_menu)
		if kinds.has(TimelineTrack.Row.COLOUR):
			_fill_colour_menu()
			_menu.add_submenu_node_item("Colour", _colour_menu)
		if kinds.has(TimelineTrack.Row.STROBE):
			_strobe_menu.clear()
			for sp in [TimelineTrack.Strobe.SLOW, TimelineTrack.Strobe.MEDIUM, TimelineTrack.Strobe.FAST]:
				_strobe_menu.add_item("Strobe " + TimelineTrack.STROBE_NAMES[sp], sp)
			_strobe_menu.add_separator()
			_strobe_menu.add_item("Strobe Off", 100)
			_menu.add_submenu_node_item("Strobe", _strobe_menu)
		if kinds.has(TimelineTrack.Row.POSITION):
			_fill_position_menu()
			_menu.add_submenu_node_item("Position", _position_menu)
		if kinds.has(TimelineTrack.Row.MOVEMENT):
			_fill_movement_menu()
			_menu.add_submenu_node_item("Movement", _movement_menu)
	_menu.add_separator()
	_menu.add_item("Select All", M_SELECT_ALL, ctrl | KEY_A)
	if not _selection.is_empty():
		_menu.add_item("Deselect", M_DESELECT, KEY_ESCAPE)
	return _menu


## The kinds of row (TimelineTrack.Row) in the selection.
func selected_row_kinds() -> Dictionary:
	var out := {}
	for b in _selection.blocks:
		for id in b["rows"]:
			out[int(id.get_slice("|", 1))] = true
	return out


func _ensure_menus() -> void:
	if _menu != null:
		return
	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)
	_dimmer_menu = PopupMenu.new()
	_dimmer_menu.id_pressed.connect(func(id: int): apply_dimmer(id))
	_menu.add_child(_dimmer_menu)
	_colour_menu = PopupMenu.new()
	_colour_menu.id_pressed.connect(_on_colour_menu)
	_menu.add_child(_colour_menu)
	_strobe_menu = PopupMenu.new()
	_strobe_menu.id_pressed.connect(func(id: int): apply_strobe(STROBE_OFF if id == 100 else id))
	_menu.add_child(_strobe_menu)
	_position_menu = PopupMenu.new()
	_position_menu.id_pressed.connect(func(id: int):
		if id == POSITION_CLEAR:
			apply_position("")
		elif positions != null and id < positions.positions.size():
			apply_position(String(positions.positions[id]["id"])))
	_menu.add_child(_position_menu)
	_movement_menu = PopupMenu.new()
	_movement_menu.id_pressed.connect(func(id: int):
		if id == MOVEMENT_CLEAR:
			apply_movement("")
		elif id >= MOVEMENT_CYCLE_ID:
			set_movement_cycle(id - MOVEMENT_CYCLE_ID)
		elif id >= MOVEMENT_SIZE_ID:
			set_movement_size(id - MOVEMENT_SIZE_ID)
		else:
			apply_movement(TimelineTrack.MOVEMENTS[id]))
	_menu.add_child(_movement_menu)


func _fill_dimmer_menu() -> void:
	_dimmer_menu.clear()
	for k in [Dim.BLACK, Dim.HALF, Dim.FULL]:
		_dimmer_menu.add_item(DIM_LABELS[k], k)
	_dimmer_menu.add_separator()
	for k in [Dim.FADE_IN, Dim.FADE_OUT, Dim.PULSE_IN, Dim.PULSE_OUT, Dim.SMOOTH]:
		_dimmer_menu.add_item(DIM_LABELS[k], k)
	_dimmer_menu.add_separator()
	for k in [Dim.BEAT_PULSES, Dim.BAR_PULSES]:
		_dimmer_menu.add_item(DIM_LABELS[k], k)
		_dimmer_menu.set_item_disabled(_dimmer_menu.get_item_index(k), _wave.grid_beats.is_empty())


func _fill_colour_menu() -> void:
	_colour_menu.clear()
	_colour_menu.add_item("Static Colour…", Col.STATIC)
	_colour_menu.add_item("Gradient…", Col.GRADIENT)
	_colour_menu.add_item("Rainbow", Col.RAINBOW)
	_colour_menu.add_separator()
	for i in range(COLOUR_PRESETS.size()):
		_colour_menu.add_icon_item(_swatch(COLOUR_PRESETS[i][1]), COLOUR_PRESETS[i][0], Col.PRESET + i)
	_colour_menu.add_separator()
	_colour_menu.add_item("Clear Colour", Col.CLEAR)


static func _swatch(c: Color) -> Texture2D:
	var img := Image.create_empty(12, 12, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)


func _on_menu(id: int) -> void:
	match id:
		M_DELETE:
			delete_selection()
		M_UNDO:
			undo()
		M_REDO:
			redo()
		M_CUT:
			cut_selection()
		M_COPY:
			copy_selection()
		M_PASTE:
			paste()
		M_PASTE_HERE:
			if not _ctx.is_empty():
				paste(_ctx["track"], _ctx["time"])
		M_SELECT_ALL:
			select_all()
		M_DESELECT:
			_selection.clear()


func _on_colour_menu(id: int) -> void:
	match id:
		Col.STATIC:
			_pick_colours(["Colour"], func(c: Array): apply_static_colour(c[0]))
		Col.GRADIENT:
			_pick_colours(["From", "To"], func(c: Array): apply_gradient(c[0], c[1]))
		Col.RAINBOW:
			apply_rainbow()
		Col.CLEAR:
			apply_colour_segments(func(_t0, _t1): return [])
		_:
			if id >= Col.PRESET and id - Col.PRESET < COLOUR_PRESETS.size():
				apply_static_colour(COLOUR_PRESETS[id - Col.PRESET][1])


## A small dialog with a colour picker per label; `done` gets the colours
## on OK.
func _pick_colours(labels: Array, done: Callable) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Colour" if labels.size() == 1 else "Gradient"
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var pickers: Array = []
	var defaults := [Color(1, 0, 0), Color(0, 0, 1)]
	for i in range(labels.size()):
		var col := VBoxContainer.new()
		var l := Label.new()
		l.text = labels[i]
		col.add_child(l)
		var p := ColorPicker.new()
		p.edit_alpha = false
		p.color = defaults[i % defaults.size()]
		col.add_child(p)
		row.add_child(col)
		pickers.append(p)
	dlg.add_child(row)
	add_child(dlg)
	dlg.confirmed.connect(func():
		done.call(pickers.map(func(p): return p.color))
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()


# ---------------------------------------------------- DIMMER / COLOUR ACTIONS --

## Give every selected dimmer span a shape (Dim): Black / Half / Full, a
## fade, a pulse, a smooth ramp or pulses on the beat grid
## (dimmer_shape()). Returns whether anything changed.
func apply_dimmer(kind: int) -> bool:
	var changed := false
	for tr in [_master] + Array(_fixture_tracks):
		var key := String(tr.get_meta("key"))
		if not tr.has_row(TimelineTrack.Row.DIMMER):
			continue
		for span in _merged(_selection.spans_for(key, TimelineTrack.Row.DIMMER)):
			var shape := dimmer_shape(kind, span.x, span.y, effective_dimmer(tr, span.x, false),
				effective_dimmer(tr, span.y, true), _beat_grid_for(kind))
			if not shape.is_empty() and tr.replace_dimmer(span.x, span.y, shape):
				changed = true
	if changed:
		_mark_dirty()
	return changed


## The dimmer level that applies on `tr` at `t` (just after it, with
## `after`): its own line where it has values, else what it inherits — a
## head its fixture's, a fixture the master's.
func effective_dimmer(tr: TimelineTrack, t: float, after: bool) -> float:
	if tr.dimmer_defined_at(t) or not tr.inherits():
		return tr._dimmer_after(t) if after else tr.dimmer_at(t)
	var key := String(tr.get_meta("key"))
	var parent: TimelineTrack = _track_for(key.get_slice("/", 0)) if "/" in key else _master
	if parent == null or parent == tr:
		return 1.0
	return effective_dimmer(parent, t, after)


func _beat_grid_for(kind: int) -> PackedFloat32Array:
	if kind == Dim.BEAT_PULSES:
		return _wave.grid_beats
	if kind == Dim.BAR_PULSES:
		var out := PackedFloat32Array()
		var beats := _wave.grid_beats
		for i in range(beats.size()):
			if posmod(i - _wave.bar_phase, _wave.beats_per_bar) == 0:
				out.append(beats[i])
		return out
	return PackedFloat32Array()


## The dimmer line for a shape across `t0`..`t1` (nodes relative to t0, as
## TimelineTrack.replace_dimmer() takes). `left` / `right`: the level just
## outside the span (the pulses start and end there, Smooth ramps between
## them); `grid`: the beat / bar times (the beat pulses: up to 100% on each
## and down to 0% by the next).
static func dimmer_shape(kind: int, t0: float, t1: float, left: float, right: float,
		grid := PackedFloat32Array()) -> PackedVector2Array:
	var n := t1 - t0
	match kind:
		Dim.BLACK:
			return PackedVector2Array([Vector2(0, 0), Vector2(n, 0)])
		Dim.HALF:
			return PackedVector2Array([Vector2(0, 0.5), Vector2(n, 0.5)])
		Dim.FULL:
			return PackedVector2Array([Vector2(0, 1), Vector2(n, 1)])
		Dim.FADE_IN:
			return PackedVector2Array([Vector2(0, 0), Vector2(n, 1)])
		Dim.FADE_OUT:
			return PackedVector2Array([Vector2(0, 1), Vector2(n, 0)])
		Dim.PULSE_IN:
			return PackedVector2Array([Vector2(0, left), Vector2(n * 0.5, 1), Vector2(n, right)])
		Dim.PULSE_OUT:
			return PackedVector2Array([Vector2(0, left), Vector2(n * 0.5, 0), Vector2(n, right)])
		Dim.SMOOTH:
			return PackedVector2Array([Vector2(0, left), Vector2(n, right)])
		Dim.BEAT_PULSES, Dim.BAR_PULSES:
			var hits: Array = []
			for b in grid:
				if b >= t0 and b < t1:
					hits.append(b)
			if hits.is_empty():
				return PackedVector2Array()
			var out := PackedVector2Array()
			if hits[0] > t0:
				out.append(Vector2(0, 0))
			for i in range(hits.size()):
				var at: float = hits[i] - t0
				var next: float = (hits[i + 1] if i + 1 < hits.size() else t1) - t0
				if not out.is_empty():
					out.append(Vector2(at, 0))
				out.append(Vector2(at, 1))
				out.append(Vector2(next, 0))
			return out
	return PackedVector2Array()


## Run `make(t0, t1) -> segments` (relative to t0) over every selected
## colour span, replacing what's there. Returns whether anything changed.
func apply_colour_segments(make: Callable) -> bool:
	var changed := false
	for tr in [_master] + Array(_fixture_tracks):
		var key := String(tr.get_meta("key"))
		if not tr.has_row(TimelineTrack.Row.COLOUR):
			continue
		for span in _merged(_selection.spans_for(key, TimelineTrack.Row.COLOUR)):
			if tr.replace_colour(span.x, span.y, make.call(span.x, span.y)):
				changed = true
	if changed:
		_mark_dirty()
	return changed


## The Position submenu: each named position with its icon, then Clear
## Position. (Item ids: the position's index; POSITION_CLEAR.)
func _fill_position_menu() -> void:
	_position_menu.clear()
	if positions != null:
		for i in range(positions.positions.size()):
			var pos: Dictionary = positions.positions[i]
			_position_menu.add_icon_item(PositionEditor.triangle_icon(pos["colour"]), String(pos["name"]), i)
	if _position_menu.item_count == 0:
		_position_menu.add_item("(no positions — add some under Positions)", -1)
		_position_menu.set_item_disabled(0, true)
	_position_menu.add_separator()
	_position_menu.add_item("Clear Position", POSITION_CLEAR)


## Put named position `id` across every selected position span ("" clears
## them). Returns whether anything changed.
func apply_position(id: String) -> bool:
	var changed := false
	for tr in [_master] + Array(_fixture_tracks):
		var key := String(tr.get_meta("key"))
		if not tr.has_row(TimelineTrack.Row.POSITION):
			continue
		for span in _merged(_selection.spans_for(key, TimelineTrack.Row.POSITION)):
			if tr.replace_position(span.x, span.y, [] if id == "" else [{"t0": 0.0, "t1": span.y - span.x, "pos": id}]):
				changed = true
	if changed:
		_mark_dirty()
	return changed


## The Movement submenu: None and the shapes, then Size and Cycle (radio
## items, checked at the selection's movement — or what new ones get),
## then Clear Movement.
func _fill_movement_menu() -> void:
	_sync_movement_options()
	_movement_menu.clear()
	for i in range(TimelineTrack.MOVEMENTS.size()):
		_movement_menu.add_item(TimelineTrack.MOVEMENT_NAMES[TimelineTrack.MOVEMENTS[i]], i)
		if i == 0:
			_movement_menu.add_separator()
	_movement_menu.add_separator("Size")
	for i in range(MOVEMENT_SIZES.size()):
		_movement_menu.add_radio_check_item(MOVEMENT_SIZES[i][0], MOVEMENT_SIZE_ID + i)
		_movement_menu.set_item_checked(_movement_menu.get_item_index(MOVEMENT_SIZE_ID + i), i == movement_size)
	_movement_menu.add_separator("Cycle")
	for i in range(MOVEMENT_CYCLES.size()):
		_movement_menu.add_radio_check_item(MOVEMENT_CYCLES[i][0], MOVEMENT_CYCLE_ID + i)
		_movement_menu.set_item_checked(_movement_menu.get_item_index(MOVEMENT_CYCLE_ID + i), i == movement_cycle)
	_movement_menu.add_separator()
	_movement_menu.add_item("Clear Movement", MOVEMENT_CLEAR)


## Take the size / cycle shown from the first movement in the selection,
## if there is one.
func _sync_movement_options() -> void:
	for tr in [_master] + Array(_fixture_tracks):
		var key := String(tr.get_meta("key"))
		for span in _merged(_selection.spans_for(key, TimelineTrack.Row.MOVEMENT)):
			var segs: Array = tr.movement_segment(span.x, span.y)
			for sg in segs:
				if String(sg["fx"]) == "none":
					continue
				movement_size = _nearest_index(MOVEMENT_SIZES, float(sg["size"]))
				movement_cycle = _nearest_index(MOVEMENT_CYCLES, float(sg["period"]) / bar_length_at(span.x + sg["t0"]))
				return


static func _nearest_index(options: Array, v: float) -> int:
	var best := 0
	for i in range(options.size()):
		if absf(options[i][1] - v) < absf(options[best][1] - v):
			best = i
	return best


## Put movement effect `fx` (TimelineTrack.MOVEMENTS; "" clears) across
## every selected movement span, at the chosen size (movement_size) and
## cycle (movement_cycle bars, from the beat grid where the span starts).
## Returns whether anything changed.
func apply_movement(fx: String) -> bool:
	var changed := false
	for tr in [_master] + Array(_fixture_tracks):
		var key := String(tr.get_meta("key"))
		if not tr.has_row(TimelineTrack.Row.MOVEMENT):
			continue
		for span in _merged(_selection.spans_for(key, TimelineTrack.Row.MOVEMENT)):
			var segs := [] if fx == "" else [{"t0": 0.0, "t1": span.y - span.x, "fx": fx,
				"period": bar_length_at(span.x) * MOVEMENT_CYCLES[movement_cycle][1],
				"size": MOVEMENT_SIZES[movement_size][1]}]
			if tr.replace_movement(span.x, span.y, segs):
				changed = true
	if changed:
		_mark_dirty()
	return changed


## Size `i` (MOVEMENT_SIZES) for new movements, and for the selected ones.
func set_movement_size(i: int) -> bool:
	movement_size = clampi(i, 0, MOVEMENT_SIZES.size() - 1)
	return _restyle_movements(func(sg: Dictionary, _at: float): sg["size"] = MOVEMENT_SIZES[movement_size][1])


## Cycle `i` (MOVEMENT_CYCLES) for new movements, and for the selected
## ones (in bars at each segment's start).
func set_movement_cycle(i: int) -> bool:
	movement_cycle = clampi(i, 0, MOVEMENT_CYCLES.size() - 1)
	return _restyle_movements(func(sg: Dictionary, at: float):
		sg["period"] = bar_length_at(at) * MOVEMENT_CYCLES[movement_cycle][1])


## Change the selected movement segments in place with `change(segment,
## its start in seconds)` — their effects and times kept.
func _restyle_movements(change: Callable) -> bool:
	var changed := false
	for tr in [_master] + Array(_fixture_tracks):
		var key := String(tr.get_meta("key"))
		if not tr.has_row(TimelineTrack.Row.MOVEMENT):
			continue
		for span in _merged(_selection.spans_for(key, TimelineTrack.Row.MOVEMENT)):
			var segs: Array = tr.movement_segment(span.x, span.y)
			if segs.is_empty():
				continue
			for sg in segs:
				if String(sg["fx"]) != "none":
					change.call(sg, span.x + float(sg["t0"]))
			# Keep the gaps between them: replace only where they are.
			for sg in segs:
				if tr.replace_movement(span.x + float(sg["t0"]), span.x + float(sg["t1"]), [_relative(sg)]):
					changed = true
	if changed:
		_mark_dirty()
	return changed


## A segment made relative to its own start (for replace_movement()).
static func _relative(sg: Dictionary) -> Dictionary:
	var out := sg.duplicate()
	out["t1"] = float(sg["t1"]) - float(sg["t0"])
	out["t0"] = 0.0
	return out


## How long a bar is at `t` seconds, from the beat grid (MOVEMENT_PERIOD
## without one).
func bar_length_at(t: float) -> float:
	var beats := _wave.grid_beats
	if beats.size() < 2:
		return TimelineTrack.MOVEMENT_PERIOD
	var i := clampi(beats.bsearch(t), 1, beats.size() - 1)
	return (beats[i] - beats[i - 1]) * maxi(_wave.beats_per_bar, 1)


## Turn the strobe on at `speed` (TimelineTrack.Strobe), or off
## (STROBE_OFF), across every selected strobe span. Returns whether
## anything changed.
func apply_strobe(speed: int) -> bool:
	var changed := false
	for tr in [_master] + Array(_fixture_tracks):
		var key := String(tr.get_meta("key"))
		if not tr.has_row(TimelineTrack.Row.STROBE):
			continue
		for span in _merged(_selection.spans_for(key, TimelineTrack.Row.STROBE)):
			if tr.replace_strobe(span.x, span.y, [] if speed == STROBE_OFF else [{"t0": 0.0, "t1": span.y - span.x, "speed": speed}]):
				changed = true
	if changed:
		_mark_dirty()
	return changed


## One colour across every selected colour span.
func apply_static_colour(c: Color) -> bool:
	return apply_colour_segments(func(t0, t1): return [{"t0": 0.0, "t1": t1 - t0, "c0": c, "c1": c}])


## A gradient from `a` to `b` across every selected colour span.
func apply_gradient(a: Color, b: Color) -> bool:
	return apply_colour_segments(func(t0, t1): return [{"t0": 0.0, "t1": t1 - t0, "c0": a, "c1": b}])


## The hue wheel once round across every selected colour span.
func apply_rainbow() -> bool:
	return apply_colour_segments(func(t0, t1): return rainbow_segments(t1 - t0))


## A rainbow over `length` seconds: red round the hue wheel back to red,
## in six segments.
static func rainbow_segments(length: float) -> Array:
	var out: Array = []
	for i in range(6):
		out.append({"t0": length * i / 6.0, "t1": length * (i + 1) / 6.0,
			"c0": Color.from_hsv(i / 6.0, 1, 1), "c1": Color.from_hsv(fmod((i + 1) / 6.0, 1.0), 1, 1)})
	return out


## Spans ([Vector2(t0, t1)]) sorted and with overlapping / touching ones
## joined.
static func _merged(spans: Array) -> Array:
	spans.sort_custom(func(a: Vector2, b: Vector2): return a.x < b.x)
	var out: Array = []
	for sp in spans:
		if not out.is_empty() and sp.x <= out[-1].y:
			out[-1] = Vector2(out[-1].x, maxf(out[-1].y, sp.y))
		else:
			out.append(sp)
	return out


## The nearest snapping boundary to `t` (bar / beat starts, by the
## structure bar's snapping), or `t` with no snapping.
func snap_nearest(t: float) -> float:
	var g := _snap_grid()
	return t if g.is_empty() else StructureBar._nearest(g, t)


## A press on a selected area's start / end on `track`'s row under
## `gpos`: what dragging it needs ({} if not on an edge) — the block,
## which end, each selected dimmer row's nodes on that edge and colour
## row's segment boundaries there (moved with it, kept between their
## neighbours).
func _edge_at(track: TimelineTrack, gpos: Vector2) -> Dictionary:
	var local := track.get_global_transform().affine_inverse() * gpos
	var row := track.row_at(local)
	if row < 0:
		return {}
	var id := TimelineSelection.row_id(String(track.get_meta("key")), row)
	for bi in range(_selection.blocks.size()):
		var b: Dictionary = _selection.blocks[bi]
		if not id in b["rows"]:
			continue
		for which in [0, 1]:
			var et: float = b["t0"] if which == 0 else b["t1"]
			if absf(local.x - track._t2x(et)) > TimelineTrack.EDGE_GRAB:
				continue
			var lo: float = 0.0 if which == 0 else b["t0"]
			var hi: float = b["t1"] if which == 0 else _wave.duration()
			var moving: Array = []       # [{track, nodes (original), idx: [node indices on the edge]}]
			var stretching: Array = []   # [{track, segs (original), ends: [[segment index, "t0" / "t1"]]}]
			for rid in b["rows"]:
				var kind := int(rid.get_slice("|", 1))
				var tr := _track_for(rid.get_slice("|", 0))
				if tr == null:
					continue
				if kind in [TimelineTrack.Row.COLOUR, TimelineTrack.Row.STROBE, TimelineTrack.Row.POSITION, TimelineTrack.Row.MOVEMENT]:
					# Colour / strobe / position segment boundaries on the edge move with
					# it; the segments' other ends (and their neighbours)
					# limit it.
					var prop: String = {TimelineTrack.Row.COLOUR: "colour_segments", TimelineTrack.Row.STROBE: "strobe_segments",
						TimelineTrack.Row.POSITION: "position_segments", TimelineTrack.Row.MOVEMENT: "movement_segments"}[kind]
					var segs_now: Array = tr.get(prop)
					var ends: Array = []
					for k in range(segs_now.size()):
						var sg: Dictionary = segs_now[k]
						if absf(sg["t0"] - et) < 0.001:
							ends.append([k, "t0"])
							hi = minf(hi, sg["t1"] - 0.001)
						elif absf(sg["t1"] - et) < 0.001:
							ends.append([k, "t1"])
							lo = maxf(lo, sg["t0"] + 0.001)
						elif sg["t1"] < et:
							lo = maxf(lo, sg["t1"])
						elif sg["t0"] > et:
							hi = minf(hi, sg["t0"])
					if not ends.is_empty():
						stretching.append({"track": tr, "prop": prop, "segs": segs_now, "ends": ends})
					continue
				if kind != TimelineTrack.Row.DIMMER:
					continue
				var idx: Array = []
				for k in range(tr.dimmer_nodes.size()):
					var x := tr.dimmer_nodes[k].x
					if absf(x - et) < 0.001:
						idx.append(k)
					elif x < et:
						lo = maxf(lo, x)
					else:
						hi = minf(hi, x)
				if not idx.is_empty():
					moving.append({"track": tr, "nodes": tr.dimmer_nodes, "idx": idx})
			return {"mode": "edge", "block": bi, "which": which, "lo": lo, "hi": hi, "moving": moving,
				"stretching": stretching}
	return {}


## Dragging a selected area's edge: it follows the pointer, snapped and
## kept inside its limits; the dimmer nodes and colour segment boundaries
## on it follow. One undo step when released, if any of those moved.
func _drag_edge(phase: int, gpos: Vector2) -> void:
	var d := _sel_drag
	var t := clampf(snap_nearest(_time_at(gpos.x)), d["lo"], d["hi"])
	var blocks: Array = _selection.blocks.duplicate(true)
	var b: Dictionary = blocks[d["block"]]
	if d["which"] == 0:
		t = minf(t, b["t1"] - 0.001)
		b["t0"] = t
	else:
		t = maxf(t, b["t0"] + 0.001)
		b["t1"] = t
	_selection.set_blocks(blocks)
	var moved := false
	for m in d["moving"]:
		var nodes: PackedVector2Array = (m["nodes"] as PackedVector2Array).duplicate()
		for k in m["idx"]:
			nodes[k].x = t
		m["track"].dimmer_nodes = nodes
		moved = moved or nodes != m["nodes"]
	for c in d["stretching"]:
		var segs: Array = (c["segs"] as Array).duplicate(true)
		for e in c["ends"]:
			segs[e[0]][e[1]] = t
		c["track"].set(c["prop"], segs)
		moved = moved or segs != c["segs"]
	if phase == TimelineTrack.SELECT_RELEASE:
		_sel_drag = {}
		if moved:
			_mark_dirty()


## Dragging the whole selection: the areas follow the pointer (their start
## snapped, kept within the song); on release the content is cut from
## where it was and pasted where it's dropped — overwriting what's there —
## as one undo step. Released without moving: a plain click there.
func _drag_move(phase: int, gpos: Vector2) -> void:
	var d := _sel_drag
	var orig: Array = d["blocks"]
	var start := INF
	var finish := -INF
	for b in orig:
		start = minf(start, b["t0"])
		finish = maxf(finish, b["t1"])
	var new_start := snap_nearest(start + _time_at(gpos.x) - d["from"])
	new_start = clampf(new_start, 0.0, maxf(_wave.duration() - (finish - start), 0.0))
	var delta := new_start - start
	if phase != TimelineTrack.SELECT_RELEASE:
		_selection.set_blocks(_shifted(orig, delta))
		_show_ghosts(d["clip"], start, new_start if not is_zero_approx(delta) else NAN)
		return
	_sel_drag = {}
	_show_ghosts({}, 0.0, NAN)
	if is_zero_approx(delta):
		# Just a click inside the selection: as a plain click anywhere — it
		# replaces the selection with what's under it (cleared first, so
		# the click isn't taken as inside it again).
		_selection.clear()
		_on_select_drag(d["track"], TimelineTrack.SELECT_PRESS, d["gpos"], false, false)
		_on_select_drag(d["track"], TimelineTrack.SELECT_RELEASE, d["gpos"], false, false)
		return
	move_selection(orig, delta)


## Show `clip` (its content from `from`) as a ghost on each track it has
## content for, landing at `at`; NAN or an empty clip clears them.
func _show_ghosts(clip: Dictionary, from: float, at: float) -> void:
	var by_key := {}
	if not clip.is_empty() and not is_nan(at):
		for src in clip["tracks"]:
			by_key[String(src["key"])] = src["rows"]
	for tr in [_master] + Array(_fixture_tracks):
		var rows = by_key.get(String(tr.get_meta("key")))
		var g: Dictionary = {} if rows == null else {"rows": rows, "at": at, "from": from}
		if g != tr.ghost:
			tr.ghost = g


## Move the content of the areas `blocks` by `delta` seconds into the
## same rows (cut, then pasted — overwriting — at the new place), and
## select the moved areas. One undo step. Returns whether anything changed.
func move_selection(blocks: Array, delta: float) -> bool:
	_selection.set_blocks(blocks)
	var clip := _copy_clip()
	var start := INF
	for b in blocks:
		start = minf(start, b["t0"])
	_batching = true
	var cleared := delete_selection()
	var pairs: Array = []
	for src in clip["tracks"]:
		var tr := _track_for(String(src["key"]))
		if tr != null:
			pairs.append([tr, src])
	var done := _paste_into(pairs, start + delta)
	_batching = false
	_selection.set_blocks(_shifted(blocks, delta))
	if cleared or done["changed"]:
		_mark_dirty()
		return true
	return false


## `blocks` moved by `delta` seconds.
static func _shifted(blocks: Array, delta: float) -> Array:
	var out: Array = []
	for b in blocks:
		out.append(TimelineSelection.block(b["rows"], b["t0"] + delta, b["t1"] + delta))
	return out


func _row_ids(rows: Array, lo: int, hi: int) -> PackedStringArray:
	var out := PackedStringArray()
	for k in range(lo, hi + 1):
		out.append(TimelineSelection.row_id(String(rows[k]["track"].get_meta("key")), rows[k]["row"]))
	return out


## Where a middle-button drag pans the view: the waveform's width, from
## the top of the fixtures' timelines down to the bottom of the waveform
## (the timelines, structure bar, bar ruler and waveform), in global
## coordinates.
func pan_area() -> Rect2:
	var w := _wave.get_global_rect()
	var top := _fixture_scroll.get_global_rect().position.y
	return Rect2(w.position.x, top, w.size.x, w.end.y - top)


func is_panning() -> bool:
	return _pan_x >= 0.0


## Press and drag the middle button over the timeline area: the view
## follows the pointer left / right (the time under it stays under it).
## Caught here, ahead of the controls under the pointer, so it works the
## same over all of them.
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or _wave.analysis == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed and pan_area().has_point(event.global_position):
			_pan_x = event.global_position.x
			_pan_from = _wave.view_start
			Input.set_default_cursor_shape(Input.CURSOR_DRAG)
			get_viewport().set_input_as_handled()
		elif not event.pressed and is_panning():
			_pan_x = -1.0
			Input.set_default_cursor_shape(Input.CURSOR_ARROW)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and is_panning():
		var per_px := _wave.visible_length() / maxf(_wave.size.x, 1.0)
		_wave.set_view(_pan_from - (event.global_position.x - _pan_x) * per_px, _wave.visible_length())
		get_viewport().set_input_as_handled()


func _unhandled_key_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		toggle_play()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not _selection.is_empty() 			and (event.keycode == KEY_ESCAPE or (event.keycode == KEY_D and event.is_command_or_control_pressed())):
		_selection.clear()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_DELETE and not _selection.is_empty():
		delete_selection()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and event.is_command_or_control_pressed() \
			and (event.keycode == KEY_Y or event.keycode == KEY_Z):
		if event.keycode == KEY_Y or event.shift_pressed:
			redo()
		else:
			undo()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.is_command_or_control_pressed() \
			and event.keycode in [KEY_A, KEY_C, KEY_X, KEY_V]:
		match event.keycode:
			KEY_A:
				select_all()
			KEY_C:
				copy_selection()
			KEY_X:
				cut_selection()
			KEY_V:
				paste()
		get_viewport().set_input_as_handled()


# ----------------------------------------------------------- PER FRAME --

func _process(_delta: float) -> void:
	if _thread != null:
		if _thread.is_alive():
			_overview.progress = _sf.get_progress()
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
	_overview.progress = -1.0
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
	_overview.progress = -1.0


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
	_wave.set_view(0.0, 0.0)            # a song opens fully zoomed out
	_box_follow(_wave.view_start, _wave.visible_length())
	_update_cursor()
	_default_master_line()


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


## The fixtures' and heads' timelines, in order (top to bottom).
func fixture_tracks() -> Array[TimelineTrack]:
	return _fixture_tracks


## What the timelines hold now, edits included, as DjPerformer.song_output()
## takes it: track key -> {dimmer, colour, strobe, position, movement}.
## Empty with no song open.
func live_tracks() -> Dictionary:
	var out := {}
	if _path == "":
		return out
	for tr in [_master] + Array(_fixture_tracks):
		out[String(tr.get_meta("key"))] = {"dimmer": tr.dimmer_nodes, "colour": tr.colour_segments,
			"strobe": tr.strobe_segments, "position": tr.position_segments, "movement": tr.movement_segments}
	return out


func fixture_scroll() -> ScrollContainer:
	return _fixture_scroll


## The timelines for one fixture, as [{key, title, target, rows}]: the
## fixture's own (rows for every channel it has), then — when it has more
## than one head (RGB group) — one per head, with rows for that head's
## channels, titled with the fixture's name and "Head N" on a second line.
static func fixture_track_specs(key: String, fixture_name: String, profile: FixtureProfile, mode: int) -> Array:
	var chans := profile.channels_for_mode(mode)
	var roles := []
	for ch in chans:
		roles.append(String(ch["role"]))
	var out := [{"key": key, "title": fixture_name, "target": TimelineTrack.Target.FIXTURE,
		"rows": TimelineTrack.rows_for_roles(roles)}]
	var heads := profile.head_groups(mode)
	if heads.size() > 1:
		for hi in range(heads.size()):
			var g: Dictionary = heads[hi]
			var hroles := []
			for k in [g["r"], g["g"], g["b"]] + Array(g["extra"]):
				if int(k) >= 0:
					hroles.append(String(chans[int(k)]["role"]))
			out.append({"key": "%s/h%d" % [key, hi], "title": "%s\nHead %d" % [fixture_name, hi + 1],
				"target": TimelineTrack.Target.HEAD, "rows": TimelineTrack.rows_for_roles(hroles)})
	return out


## Rebuild the fixtures' timelines from fixtures_provider (call when the
## patch changes). A track that's still there keeps its dimmer nodes.
func refresh_fixtures() -> void:
	_collect()
	_rebuild_fixture_tracks()


func _rebuild_fixture_tracks() -> void:
	if _fixture_list == null:
		return
	var saved: Dictionary = song_data().get("tracks", {})
	for c in _fixture_list.get_children():
		if c != _fixture_empty:
			_fixture_list.remove_child(c)
			c.queue_free()
	_fixture_tracks.clear()
	var fixtures: Array = fixtures_provider.call() if fixtures_provider.is_valid() else []
	var plate_w := _fixture_plate_width()
	for fx in fixtures:
		for spec in fixture_track_specs(String(fx["key"]), String(fx["name"]), fx["profile"], int(fx.get("mode", 0))):
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 6)
			var tr := TimelineTrack.new()
			tr.target = spec["target"]
			tr.title = spec["title"]
			tr.rows = spec["rows"]
			tr.wave = _wave
			tr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			tr.set_meta("key", spec["key"])
			tr.dimmer_nodes = _nodes_from(saved.get(spec["key"], {}).get("dimmer", []))
			tr.colour_segments = _segs_from(saved.get(spec["key"], {}).get("colour", []))
			tr.strobe_segments = _spans_from(saved.get(spec["key"], {}).get("strobe", []))
			tr.position_segments = _pos_from(saved.get(spec["key"], {}).get("position", []))
			tr.movement_segments = _moves_from(saved.get(spec["key"], {}).get("movement", []))
			tr.positions = positions
			tr.dimmer_edited.connect(_mark_dirty)
			tr.selection = _selection
			tr.select_drag.connect(_on_select_drag)
			tr.playhead_drag.connect(_on_playhead_drag)
			tr.context_requested.connect(_on_context)
			row.add_child(tr)
			var plate := TimelineTrack.NamePlate.new()
			plate.track = tr
			plate.custom_minimum_size = Vector2(plate_w, 0)
			row.add_child(plate)
			_fixture_list.add_child(row)
			_fixture_tracks.append(tr)
	_fixture_empty.visible = _fixture_tracks.is_empty()


# ----------------------------------------------------- SAVED TIMELINES --

## The open song's timelines: {tracks: {key: {dimmer: [[t, level], ...]}},
## structure?: {sections}} — from the store the first time, then kept.
func song_data() -> Dictionary:
	if _path == "":
		return {}
	if not _songs.has(_path):
		var d := timeline_store.load_song(_path) if timeline_store != null else {}
		if not d.get("tracks") is Dictionary:
			d["tracks"] = {}
		_songs[_path] = d
	return _songs[_path]


## Whether the open song's timelines have changed since they were saved.
func has_unsaved_timelines() -> bool:
	return _dirty


## Save the open song's timelines to the store, if they've changed.
## Returns "" or what went wrong.
func flush() -> String:
	if not _dirty or _path == "" or timeline_store == null:
		return ""
	_collect()
	var err := timeline_store.save_song(_path, song_data())
	if err == "":
		_dirty = false
		timelines_saved.emit(_path)
	else:
		push_warning("Couldn't save the timelines for %s: %s" % [_path.get_file(), err])
	return err


## Delete the song at `path`'s saved timelines from the store, and forget
## them (and their undo history) here. If it's the open song, its tracks
## go back to empty, unsaved edits and all. Returns whether there were any.
func remove_song_timelines(path: String) -> bool:
	var had := timeline_store != null and timeline_store.remove_song(path)
	_songs.erase(path)
	_history.erase(path)
	if path == _path:
		_dirty = false
		_show_song_data()
	return had


## Switch to another show's timelines folder. `reload`: forget what's in
## memory and show the open song's timelines from the new folder (loading
## another show — flush() the old one first); otherwise keep it, edits and
## all (Save Show As… onto a copy of the folder).
func set_timeline_store(store: TimelineStore, reload := true) -> void:
	timeline_store = store
	timeline_store_changed.emit()
	if reload:
		_songs.clear()
		_history.clear()
		_dirty = false
		_show_song_data()


## The tracks' current nodes into the open song's data.
func _collect() -> void:
	if _path == "" or _master == null:
		return
	var tracks: Dictionary = song_data()["tracks"]
	for tr in [_master] + Array(_fixture_tracks):
		var key := String(tr.get_meta("key"))
		var entry: Dictionary = tracks.get(key, {})
		if tr.dimmer_nodes.is_empty():
			entry.erase("dimmer")
		else:
			entry["dimmer"] = _nodes_to(tr.dimmer_nodes)
		if tr.colour_segments.is_empty():
			entry.erase("colour")
		else:
			entry["colour"] = _segs_to(tr.colour_segments)
		if tr.movement_segments.is_empty():
			entry.erase("movement")
		else:
			entry["movement"] = _moves_to(tr.movement_segments)
		if tr.position_segments.is_empty():
			entry.erase("position")
		else:
			entry["position"] = _pos_to(tr.position_segments)
		if tr.strobe_segments.is_empty():
			entry.erase("strobe")
		else:
			entry["strobe"] = _spans_to(tr.strobe_segments)
		if entry.is_empty():
			tracks.erase(key)
		else:
			tracks[key] = entry


## Show the open song's data on the tracks (and its structure, if it's
## been analysed already).
func _show_song_data() -> void:
	var tracks: Dictionary = song_data().get("tracks", {})
	if _master != null:
		_master.dimmer_nodes = _nodes_from(tracks.get("master", {}).get("dimmer", []))
		_master.colour_segments = _segs_from(tracks.get("master", {}).get("colour", []))
		_master.strobe_segments = _spans_from(tracks.get("master", {}).get("strobe", []))
		_master.position_segments = _pos_from(tracks.get("master", {}).get("position", []))
		_master.movement_segments = _moves_from(tracks.get("master", {}).get("movement", []))
	_rebuild_fixture_tracks()
	if _path != "" and _struct_cache.has(_path):
		_apply_saved_structure(_path, _struct_cache[_path])
		_set_structure(_struct_cache[_path])
	_default_master_line()
	if _path != "" and _hist()["state"] == null:
		_hist()["state"] = _snapshot()       # where undo stops


## A song whose master has no dimmer line yet gets one: a node at its
## start and one at its end, at 0 % (so nothing comes on until the line is
## raised or a fixture has values of its own). Not an edit (nothing to save, no
## undo step) — it's where the song starts.
func _default_master_line() -> void:
	if _path == "" or _master == null or _wave.analysis == null or not _master.dimmer_nodes.is_empty():
		return
	_master.dimmer_nodes = PackedVector2Array([Vector2(0.0, 0.0), Vector2(_wave.duration(), 0.0)])
	_collect()
	var h := _hist()
	if h["state"] != null:
		h["state"] = _snapshot()        # undo stops here, with the default line


## An edit's been made: the song's timelines are unsaved, and the state
## before it goes on the undo list.
func _mark_dirty() -> void:
	_dirty = true
	if not _batching:
		_record_edit()


func _on_structure_edited() -> void:
	var a: SongAnalysis = _struct_cache.get(_path)
	if a == null:
		return
	song_data()["structure"] = {"sections": a.sections.duplicate(true)}
	_mark_dirty()


# ------------------------------------------------------------ UNDO / REDO --

## The open song's timelines as they stand: {tracks, structure?}.
func _snapshot() -> Dictionary:
	_collect()
	var d := song_data()
	var snap := {"tracks": (d["tracks"] as Dictionary).duplicate(true)}
	if d.get("structure") is Dictionary:
		snap["structure"] = (d["structure"] as Dictionary).duplicate(true)
	return snap


func _hist() -> Dictionary:
	if not _history.has(_path):
		_history[_path] = {"undo": [], "redo": [], "state": null}
	return _history[_path]


func _record_edit() -> void:
	if _path == "":
		return
	var h := _hist()
	var now := _snapshot()
	if h["state"] != null and now != h["state"]:
		h["undo"].push_back(h["state"])
		if h["undo"].size() > UNDO_LIMIT:
			h["undo"].pop_front()
		h["redo"].clear()
	h["state"] = now


func can_undo() -> bool:
	return _path != "" and not _hist()["undo"].is_empty()


func can_redo() -> bool:
	return _path != "" and not _hist()["redo"].is_empty()


## Undo the open song's last timeline edit (Ctrl+Z). Returns whether there
## was one.
func undo() -> bool:
	if not can_undo():
		return false
	var h := _hist()
	h["redo"].push_back(h["state"])
	h["state"] = h["undo"].pop_back()
	_restore(h["state"])
	return true


## Redo the last undone edit (Ctrl+Y / Ctrl+Shift+Z). Returns whether there
## was one.
func redo() -> bool:
	if not can_redo():
		return false
	var h := _hist()
	h["undo"].push_back(h["state"])
	h["state"] = h["redo"].pop_back()
	_restore(h["state"])
	return true


## Put the song's timelines back to a _snapshot() (unsaved until the song's
## left, like an edit).
func _restore(snap: Dictionary) -> void:
	var d := song_data()
	d["tracks"] = (snap["tracks"] as Dictionary).duplicate(true)
	if snap.has("structure"):
		d["structure"] = (snap["structure"] as Dictionary).duplicate(true)
	else:
		d.erase("structure")
	# Onto the tracks as they are (not rebuilt: the panel keeps its scroll).
	var tracks: Dictionary = d["tracks"]
	for tr in [_master] + Array(_fixture_tracks):
		tr.dimmer_nodes = _nodes_from(tracks.get(String(tr.get_meta("key")), {}).get("dimmer", []))
		tr.colour_segments = _segs_from(tracks.get(String(tr.get_meta("key")), {}).get("colour", []))
		tr.strobe_segments = _spans_from(tracks.get(String(tr.get_meta("key")), {}).get("strobe", []))
		tr.position_segments = _pos_from(tracks.get(String(tr.get_meta("key")), {}).get("position", []))
		tr.movement_segments = _moves_from(tracks.get(String(tr.get_meta("key")), {}).get("movement", []))
	if _struct_cache.has(_path):
		_apply_saved_structure(_path, _struct_cache[_path])
		_set_structure(_struct_cache[_path])
	_dirty = true


## Put the song's saved (edited) sections on its analysis — or, with none
## saved, the analyser's own (kept aside the first time).
func _apply_saved_structure(path: String, a: SongAnalysis) -> void:
	if not a.has_meta("analysed_sections"):
		a.set_meta("analysed_sections", a.sections.duplicate(true))
	var d: Dictionary = _songs.get(path, {})
	var saved = d["structure"].get("sections") if d.get("structure") is Dictionary else null
	a.sections = (saved if saved is Array else a.get_meta("analysed_sections")).duplicate(true)


static func _nodes_from(arr) -> PackedVector2Array:
	var out := PackedVector2Array()
	if arr is Array:
		for p in arr:
			if p is Array and p.size() >= 2:
				out.append(Vector2(float(p[0]), float(p[1])))
	return out


## Colour segments to / from their saved form: [[t0, t1, "rrggbb",
## "rrggbb"], ...].
static func _segs_to(segs: Array) -> Array:
	var out := []
	for sg in segs:
		out.append([snappedf(sg["t0"], 0.001), snappedf(sg["t1"], 0.001),
			(sg["c0"] as Color).to_html(false), (sg["c1"] as Color).to_html(false)])
	return out


## Movement segments to / from their saved form: [[t0, t1, effect,
## period, size(, phase)], ...] — the phase only where it isn't 0.
static func _moves_to(spans: Array) -> Array:
	var out := []
	for sg in spans:
		var e := [snappedf(sg["t0"], 0.001), snappedf(sg["t1"], 0.001), String(sg.get("fx", "none")),
			snappedf(float(sg.get("period", TimelineTrack.MOVEMENT_PERIOD)), 0.0001),
			snappedf(float(sg.get("size", TimelineTrack.MOVEMENT_SIZE)), 0.0001)]
		if float(sg.get("phase", 0.0)) != 0.0:
			e.append(snappedf(float(sg["phase"]), 0.0001))
		out.append(e)
	return out


static func _moves_from(arr) -> Array:
	var out: Array = []
	if arr is Array:
		for e in arr:
			if e is Array and e.size() >= 3 and float(e[1]) > float(e[0]) and str(e[2]) in TimelineTrack.MOVEMENTS:
				out.append({"t0": float(e[0]), "t1": float(e[1]), "fx": str(e[2]),
					"period": float(e[3]) if e.size() > 3 else TimelineTrack.MOVEMENT_PERIOD,
					"size": float(e[4]) if e.size() > 4 else TimelineTrack.MOVEMENT_SIZE})
				if e.size() > 5:
					out[out.size() - 1]["phase"] = float(e[5])
	return out


## Position segments to / from their saved form: [[t0, t1, position id], ...].
static func _pos_to(spans: Array) -> Array:
	var out := []
	for sg in spans:
		out.append([snappedf(sg["t0"], 0.001), snappedf(sg["t1"], 0.001), String(sg.get("pos", ""))])
	return out


static func _pos_from(arr) -> Array:
	var out: Array = []
	if arr is Array:
		for e in arr:
			if e is Array and e.size() >= 3 and float(e[1]) > float(e[0]):
				out.append({"t0": float(e[0]), "t1": float(e[1]), "pos": str(e[2])})
	return out


## Strobe segments to / from their saved form: [[t0, t1, speed], ...]
## (speed: 0 slow, 1 medium, 2 fast; medium when it's missing).
static func _spans_to(spans: Array) -> Array:
	var out := []
	for sg in spans:
		out.append([snappedf(sg["t0"], 0.001), snappedf(sg["t1"], 0.001), int(sg.get("speed", TimelineTrack.Strobe.MEDIUM))])
	return out


static func _spans_from(arr) -> Array:
	var out: Array = []
	if arr is Array:
		for e in arr:
			if e is Array and e.size() >= 2 and float(e[1]) > float(e[0]):
				var speed := clampi(int(e[2]) if e.size() >= 3 else TimelineTrack.Strobe.MEDIUM,
					TimelineTrack.Strobe.SLOW, TimelineTrack.Strobe.FAST)
				out.append({"t0": float(e[0]), "t1": float(e[1]), "speed": speed})
	return out


static func _segs_from(arr) -> Array:
	var out: Array = []
	if arr is Array:
		for e in arr:
			if e is Array and e.size() >= 4:
				out.append({"t0": float(e[0]), "t1": float(e[1]),
					"c0": Color.from_string(str(e[2]), Color.WHITE), "c1": Color.from_string(str(e[3]), Color.WHITE)})
	return out


static func _nodes_to(nodes: PackedVector2Array) -> Array:
	var out := []
	for p in nodes:
		out.append([snappedf(p.x, 0.001), snappedf(p.y, 0.0001)])
	return out


## The name plates beside the fixtures' timelines: the button column's
## width less the scroll bar's (always reserved).
func _fixture_plate_width() -> float:
	var bar := _fixture_scroll.get_v_scroll_bar().get_combined_minimum_size().x
	return maxf(_BUTTON_WIDTH - bar, 8.0)


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


## Generate a light show into this song's timelines (the Generate button):
## from its structure (sections and their energy), its beat grid / tempo,
## the fixtures' rows and the named positions (TimelineGenerator). Each
## press makes another variation of the song's show. Replaces what the
## timelines had, as one undo step. Returns whether it ran.
func generate_show() -> bool:
	var a: SongAnalysis = _structure.analysis
	if a == null or _wave.analysis == null or _path == "":
		return false
	var beats := _wave.grid_beats
	if beats.is_empty():
		beats = a.beat_times
	if beats.is_empty():
		beats = TimelineGenerator._even_beats(a.bpm, _wave.duration())
	# Each fixture with its category and category group, as the patch has
	# them now (changing them doesn't rebuild the tracks).
	var parts := {}
	for fx in (fixtures_provider.call() if fixtures_provider.is_valid() else []):
		parts[String(fx["key"])] = fx
	var tracks: Array = []
	for tr in [_master] + Array(_fixture_tracks):
		var key := String(tr.get_meta("key"))
		var t := {"key": key, "target": tr.target, "rows": tr.rows}
		if parts.has(key):
			t["category"] = String(parts[key].get("category", ""))
			t["group"] = int(parts[key].get("category_group", 1))
			var wheel: Array = (parts[key]["profile"] as FixtureProfile).wheel_colours(int(parts[key].get("mode", 0)))
			if not wheel.is_empty():
				t["wheel"] = wheel
		tracks.append(t)
	var ids: Array = []
	if positions != null:
		# Movement needs a position to move around: with none named yet, a
		# "Centre" one (no points of its own: every fixture centred).
		if positions.positions.is_empty():
			positions.rename(String(positions.add()["id"]), "Centre")
		# Each with how widely it spreads the beams (narrow -> wide by energy).
		for pos in positions.positions:
			ids.append({"id": String(pos["id"]), "spread": _spread(pos["points"])})
	# Which beat starts a bar: the grid's, or the analysis's first downbeat.
	var bar_phase := 0
	if beats == _wave.grid_beats:
		bar_phase = _wave.bar_phase
	elif not a.downbeats.is_empty():
		bar_phase = clampi(beats.bsearch(a.downbeats[0] - 0.01), 0, beats.size() - 1)
	var variation: int = _generated.get(_path, 0)
	_generated[_path] = variation + 1
	var show := TimelineGenerator.generate(a.sections, beats, _wave.beats_per_bar, _wave.duration(),
		tracks, ids, _path.get_file(), variation, bar_phase,
		{"peak": a.wave_peak, "lo": a.wave_lo, "hi": a.wave_hi})
	for tr in [_master] + Array(_fixture_tracks):
		var c: Dictionary = show.get(String(tr.get_meta("key")), {})
		tr.dimmer_nodes = c.get("dimmer", PackedVector2Array())
		tr.colour_segments = c.get("colour", [])
		tr.strobe_segments = c.get("strobe", [])
		tr.position_segments = c.get("position", [])
		tr.movement_segments = c.get("movement", [])
	_mark_dirty()
	return true


## How far apart a position's points are: their mean distance from
## their middle (0 with fewer than two).
static func _spread(points: Dictionary) -> float:
	if points.size() < 2:
		return 0.0
	var mid := Vector2.ZERO
	for v in points.values():
		mid += v
	mid /= points.size()
	var d := 0.0
	for v in points.values():
		d += (v as Vector2).distance_to(mid)
	return d / points.size()


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
	_apply_saved_structure(path, a)
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
	for tr in _fixture_tracks:
		tr.queue_redraw()


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
