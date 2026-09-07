class_name AutoShowPanel
extends VBoxContainer
## Auto Show tab: load a music file, analyse its structure, generate a
## starter cue list from the patched fixtures, and run it locked to
## playback. Only drives output while the run mode is "Auto Show".

## Set by the shell: func(result: Dictionary) — installs the generated show.
var apply_show_cb := Callable()
## Set by the shell: func() -> Array of UniversePanel.
var panels_provider := Callable()

var _song_lbl: Label
var _analyse_btn: Button
var _speed_option: OptionButton
var _progress: ProgressBar
var _summary: Label
var _section_list: ItemList
var _build_btn: Button
var _play_btn: Button
var _pause_btn: Button
var _stop_btn: Button
var _seek: HSlider
var _pos_lbl: Label
var _status: Label
var _seeking := false


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	custom_minimum_size = Vector2(300, 0)
	set_process(true)

	var title := Label.new()
	title.text = "Auto Show"
	add_child(title)

	var hint := Label.new()
	hint.text = "Set the run mode to \"Auto Show\" (top bar) to run the generated show."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	add_child(hint)

	var load_row := _flow()
	var load_btn := Button.new()
	load_btn.text = "Load Song…"
	load_btn.pressed.connect(_pick_song)
	load_row.add_child(load_btn)
	_song_lbl = Label.new()
	_song_lbl.text = "(no song)"
	load_row.add_child(_song_lbl)
	add_child(load_row)

	var an_row := _flow()
	_analyse_btn = Button.new()
	_analyse_btn.text = "Analyse"
	_analyse_btn.disabled = true
	_analyse_btn.pressed.connect(func(): AutoShow.analyse(_speed_value()))
	an_row.add_child(_analyse_btn)
	an_row.add_child(_lbl("speed"))
	_speed_option = OptionButton.new()
	for s in ["1× (slow, exact)", "2×", "4× (fast)"]:
		_speed_option.add_item(s)
	_speed_option.selected = 2
	an_row.add_child(_speed_option)
	add_child(an_row)

	_progress = ProgressBar.new()
	_progress.min_value = 0.0
	_progress.max_value = 1.0
	_progress.show_percentage = false
	_progress.custom_minimum_size = Vector2(0, 8)
	_progress.visible = false
	add_child(_progress)

	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_summary)

	_section_list = ItemList.new()
	_section_list.custom_minimum_size = Vector2(0, 120)
	_section_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_section_list.item_activated.connect(_seek_to_section)
	add_child(_section_list)

	_build_btn = Button.new()
	_build_btn.text = "Build Light Show"
	_build_btn.disabled = true
	_build_btn.pressed.connect(_build)
	add_child(_build_btn)

	add_child(HSeparator.new())

	var t_row := _flow()
	_play_btn = _tbtn("▶ Play", func(): AutoShow.play())
	_pause_btn = _tbtn("⏸ Pause", func(): AutoShow.pause())
	_stop_btn = _tbtn("⏹ Stop", func(): AutoShow.stop())
	t_row.add_child(_play_btn)
	t_row.add_child(_pause_btn)
	t_row.add_child(_stop_btn)
	add_child(t_row)

	_seek = HSlider.new()
	_seek.min_value = 0.0
	_seek.max_value = 1.0
	_seek.step = 0.001
	_seek.custom_minimum_size = Vector2(0, 16)
	_seek.drag_started.connect(func(): _seeking = true)
	_seek.drag_ended.connect(func(_c: bool):
		_seeking = false
		AutoShow.seek(_seek.value * maxf(AutoShow.song_length(), 0.001)))
	add_child(_seek)

	_pos_lbl = Label.new()
	_pos_lbl.text = "0:00 / 0:00"
	add_child(_pos_lbl)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	AutoShow.state_changed.connect(_refresh)
	AutoShow.analysis_progress.connect(func(f: float):
		_progress.visible = true
		_progress.value = f)
	AutoShow.analysis_done.connect(_on_analysed)
	AutoShow.analysis_failed.connect(func(m: String):
		_progress.visible = false
		_status.text = "Analysis failed: " + m)
	_refresh()


## Re-sync after a show file load restored AutoShow's state.
func reload() -> void:
	_section_list.clear()
	_summary.text = ""
	_refresh()


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	var len := AutoShow.song_length()
	var pos := AutoShow.position()
	_pos_lbl.text = "%s / %s" % [_mmss(pos), _mmss(len)]
	if not _seeking and len > 0.0:
		_seek.set_value_no_signal(pos / len)


# ---------------------------------------------------------------- ACTIONS --

func _pick_song() -> void:
	var fd := FileDialog.new()
	fd.title = "Load a music file"
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.add_filter("*.mp3", "MP3 audio")
	fd.add_filter("*.ogg,*.oga", "Ogg Vorbis audio")
	fd.add_filter("*.wav", "WAV audio")
	fd.use_native_dialog = true
	add_child(fd)
	fd.file_selected.connect(func(path: String):
		if AutoShow.load_song(path):
			_status.text = "Loaded %s — press Analyse." % path.get_file()
		fd.queue_free())
	fd.canceled.connect(func(): fd.queue_free())
	fd.popup_centered_ratio(0.6)


func _on_analysed() -> void:
	_progress.visible = false
	var a := AutoShow.analysis
	_summary.text = a.summary()
	_section_list.clear()
	for s in a.sections:
		_section_list.add_item("%s   %s   (%s)" % [
			_mmss(s["start"]), s["label"], _mmss(s["end"] - s["start"])])
	_build_btn.disabled = false
	_status.text = "Analysed. Review the sections, then Build Light Show."
	_refresh()


func _seek_to_section(idx: int) -> void:
	var a := AutoShow.analysis
	if a != null and idx >= 0 and idx < a.sections.size():
		AutoShow.seek(float(a.sections[idx]["start"]))


func _build() -> void:
	var a := AutoShow.analysis
	if a == null or not apply_show_cb.is_valid():
		return
	var panels: Array = panels_provider.call() if panels_provider.is_valid() else []
	apply_show_cb.call(ShowGenerator.build(a, panels))
	_status.text = "Built %d section cues (added after your own). Switch to Auto Show mode and Play." % a.sections.size()


# ---------------------------------------------------------------- HELPERS --

func _speed_value() -> float:
	return [1.0, 2.0, 4.0][_speed_option.selected]


func _refresh() -> void:
	var loaded := AutoShow.song_path != ""
	_song_lbl.text = AutoShow.song_name() if loaded else "(no song)"
	_analyse_btn.disabled = not loaded
	_build_btn.disabled = AutoShow.analysis == null
	_play_btn.disabled = _player_missing()
	_pause_btn.disabled = _player_missing()
	_stop_btn.disabled = _player_missing()
	if AutoShow.analysis != null and _section_list.item_count == 0:
		_on_analysed_quiet()


func _on_analysed_quiet() -> void:
	var a := AutoShow.analysis
	_summary.text = a.summary()
	_section_list.clear()
	for s in a.sections:
		_section_list.add_item("%s   %s   (%s)" % [
			_mmss(s["start"]), s["label"], _mmss(s["end"] - s["start"])])


func _player_missing() -> bool:
	return AutoShow.song_length() <= 0.0


func _mmss(t: float) -> String:
	t = maxf(t, 0.0)
	return "%d:%02d" % [int(t) / 60, int(t) % 60]


func _lbl(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


func _flow(h: int = 6, v: int = 4) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", h)
	f.add_theme_constant_override("v_separation", v)
	return f


func _tbtn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	return b
