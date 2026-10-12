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
## The waveform is decoded on a worker thread by the `native` extension
## (SongFeatures.waveform_file — MP3 / OGG / WAV, plus M4A / AAC through the
## OS's decoder), at WAVE_COLS_PER_SEC so zooming in shows real detail.
## Above the waveforms there's only a status line with a progress bar,
## for loading and errors; it's empty once a track is shown.

## Waveform columns per second of audio: ~10 ms each.
const WAVE_COLS_PER_SEC := 100
## How much of the track the zoomable waveform shows at first, seconds.
const INITIAL_VIEW := 30.0
## Recently opened tracks' waveforms kept in memory.
const CACHE_SIZE := 6

var _status: Label
var _progress: ProgressBar
var _wave: WaveHeatmap
var _overview: WaveHeatmap
var _box: ViewBox

var _path := ""
var _sf = null                  # SongFeatures doing the current decode
var _thread: Thread
var _result: Dictionary = {}
var _cache: Dictionary = {}     # path -> SongAnalysis
var _cache_order: Array = []


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
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(spacer)

	_wave = WaveHeatmap.new()
	_wave.custom_minimum_size = Vector2(0, 180)
	_wave.zoomable = true
	_wave.show_cursor = false
	_wave.tooltip_text = "Mouse wheel: zoom · Shift+wheel: scroll"
	_wave.view_changed.connect(_box_follow)
	add_child(_wave)

	_overview = WaveHeatmap.new()
	_overview.custom_minimum_size = Vector2(0, 44)
	_overview.show_cursor = false
	add_child(_overview)
	_box = ViewBox.new()
	_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	_box.tooltip_text = "Drag to scroll · click to jump"
	_box.view_moved.connect(func(start: float): _wave.set_view(start, _wave.visible_length()))
	_overview.add_child(_box)


func _exit_tree() -> void:
	_stop_loading()


## Show `path`'s timeline.
func open(path: String) -> void:
	_stop_loading()
	_path = path
	_set_analysis(null)

	if _cache.has(path):
		_touch_cache(path)
		_set_analysis(_cache[path])
		return
	if not ClassDB.class_exists("SongFeatures"):
		_status.text = "Waveforms need the native extension — build it with addons/native/build.py (see addons/native/BUILD.md)."
		return
	var ext := path.get_extension().to_lower()
	if ext in ["m4a", "aac", "mp4"] and not SongAnalyzer.os_decoding_available():
		_status.text = "This system has no decoder for .%s files (needs Windows with Media Foundation, or macOS)." % ext
		return
	if not FileAccess.file_exists(path):
		_status.text = "File not found."
		return

	_status.text = "Reading waveform…"
	_progress.value = 0.0
	_progress.visible = true
	_result = {}
	_sf = ClassDB.instantiate("SongFeatures")
	_thread = Thread.new()
	_thread.start(_decode.bind(_sf, path))
	set_process(true)


## The track currently shown.
func current_path() -> String:
	return _path


func is_loading() -> bool:
	return _thread != null


## The zoomable waveform (for tests / later features).
func wave() -> WaveHeatmap:
	return _wave


func overview_box() -> ViewBox:
	return _box


## Stop and discard an in-flight decode (leaving the view, or opening
## another track).
func _stop_loading() -> void:
	if _thread == null:
		return
	if _sf != null:
		_sf.cancel()
	_thread.wait_to_finish()
	_thread = null
	_sf = null
	_progress.visible = false
	set_process(false)


func _decode(sf, path: String) -> void:
	_result = sf.waveform_file(path, WAVE_COLS_PER_SEC)


func _process(_delta: float) -> void:
	if _thread == null:
		set_process(false)
		return
	if _thread.is_alive():
		_progress.value = _sf.get_progress()
		return
	_thread.wait_to_finish()
	_thread = null
	_sf = null
	_progress.visible = false
	set_process(false)
	if not bool(_result.get("ok", false)):
		_status.text = "Couldn't read the waveform: %s." % String(_result.get("error", "unknown error"))
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


func _touch_cache(path: String) -> void:
	_cache_order.erase(path)
	_cache_order.append(path)
	while _cache_order.size() > CACHE_SIZE:
		_cache.erase(_cache_order.pop_front())


func _set_analysis(a: SongAnalysis) -> void:
	_wave.set_analysis(a)
	_overview.set_analysis(a)
	_box.duration = a.duration if a != null else 0.0
	_status.text = ""
	if a == null:
		_box.set_view(0.0, 0.0)
		return
	_wave.set_view(0.0, minf(INITIAL_VIEW, a.duration))
	_box_follow(_wave.view_start, _wave.visible_length())


## Keep the overview's rectangle on the zoomable waveform's window.
func _box_follow(start: float, length: float) -> void:
	_box.set_view(start, length)


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
