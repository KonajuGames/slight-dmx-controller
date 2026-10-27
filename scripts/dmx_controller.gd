extends Control
## Main DMX control shell. Attached to the root Control node in main.tscn.
## Builds its whole UI in code so the scene file stays trivial.
##
## Layout: a top bar (view selector, grand master, Sending, add/remove
## universe, whole-show + preset save/load) above either the console —
## playback tabs beside a TabContainer with one UniversePanel per Art-Net
## universe — or DJ Edit Mode (MusicBrowserPanel) / DJ Perform Mode (DjPerformPanel). Each panel owns its own ArtNetUniverse sender and
## fixture patch; this shell owns the shared fixture-profile list and the
## refresh loop.

const REFRESH_HZ := 30.0
const PRESET_PATH := "user://dmx_preset.json"
const SHOW_PATH := "user://dmx_show.json"
const PROFILES_DIR := "user://fixture_profiles"
const MODELS_DIR := "user://fixture_models"

var available_profiles: Array[FixtureProfile] = []
var _builtin_ids := {}  # profile ids that come from code (can't be file-deleted)

## Fixture groups: [{ "name": String, "members": Array of fixture uids }].
var groups: Array = []

var _panels: Array[UniversePanel] = []
var _refresh_timer: Timer

# UI refs
var universe_tabs: TabContainer
var cue_panel: CueListPanel
var chase_panel: ChaseListPanel
var fx_panel: EffectsPanel
var sound_panel: SoundPanel
var groups_panel: GroupsPanel
## The playback faders (cue submasters, chase faders, group masters) and
## their tab.
var faders := FaderBank.new()
var faders_panel: FadersPanel
var viz_panel: VisualizerPanel
var dmx_output_panel: DmxOutputPanel
## DJ Edit Mode (the music library and its songs' lighting timelines),
## swapped in for the console area
## (`_console_view`) by the top bar's View selector.
var music_panel: MusicBrowserPanel
var _console_view: Control
var view_option: OptionButton
const VIEWS := ["Console", "DJ Edit Mode", "DJ Perform Mode"]
## DJ Perform Mode: VirtualDJ over OS2L playing the songs' timelines
## (running only while that view is showing), and its panel.
var performer: DjPerformer
## The show's named positions for moving fixtures (edited in DJ Edit Mode).
var positions := PositionLibrary.new()
var perform_panel: DjPerformPanel
## The live flashes (Blackout / Strobe / White / Colour), over everything
## in the DMX frame; their buttons are in DJ Perform Mode.
var flash := LiveFlash.new()
## The right-hand tabs (Patch + 3D Visualizer) and, while the visualizer
## is popped out, its own window.
var _right_tabs: TabContainer
var _viz_window: Window
const _VIZ_TAB := 1
var master_slider: HSlider
var sending_toggle: CheckButton
var run_mode_option: OptionButton
var tempo_label: Label
var tempo_stop_btn: Button
var _triggers_dialog: TriggersDialog

## Console run mode: 0 = Cue Mode (default), 1 = Sound Reactive. (Shows
## saved with the old 2 = Auto Show open in Cue Mode.)
const RUN_MODES := ["Cue Mode", "Sound Reactive"]
var run_mode := 0
var add_uni_btn: Button
var remove_uni_btn: Button
var status_label: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	# Resizable window with a floor small enough to be useful on a laptop;
	# every row below wraps rather than clipping past the right edge.
	var win := get_window()
	if win:
		win.min_size = Vector2i(720, 480)
		win.theme = _app_theme()

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)

	var main_vbox := VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 10)
	margin.add_child(main_vbox)

	main_vbox.add_child(_build_top_bar())
	main_vbox.add_child(HSeparator.new())

	# Playback (cues / chases / effects) on the left, universe tabs right.
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 340
	main_vbox.add_child(split)
	_console_view = split

	# The alternate view: drives / folders / VirtualDJ Virtual Folders and
	# their music. Hidden until picked in the top bar's View selector.
	music_panel = MusicBrowserPanel.new()
	music_panel.visible = false
	main_vbox.add_child(music_panel)
	music_panel.timeline().fixtures_provider = _timeline_fixtures
	music_panel.timeline().set_timeline_store(TimelineStore.new(TimelineStore.folder_for_show(show_path)))
	music_panel.positions = positions
	music_panel.timeline().positions = positions
	music_panel.position_editor().fixtures_provider = _position_fixtures
	music_panel.position_editor().highlight_changed.connect(highlight_fixtures)
	# Points moved (dragged on the pad): the lit fixtures follow.
	positions.changed.connect(func(): highlight_fixtures(music_panel.position_editor().highlighted_uids()))

	# DJ Perform Mode: started / stopped with its view.
	performer = DjPerformer.new()
	performer.fixtures_provider = _perform_fixtures
	performer.store_provider = func(): return music_panel.timeline().timeline_store
	performer.positions = positions
	# A song without timelines: temporary ones, generated as DJ Edit Mode does.
	performer.timeline = music_panel.timeline()
	performer.song_lookup = music_panel.find_song
	add_child(performer)
	music_panel.timeline().timeline_store_changed.connect(func():
		if performer.is_active():
			performer.reload_all())
	# DJ Edit Mode: the open song's timelines go live while it plays.
	ArtNet.layer_providers.append(_edit_playback_layer)
	# The live flashes: on top of everything.
	flash.fixtures_provider = _perform_fixtures
	ArtNet.top_providers.append(flash.layer)
	perform_panel = DjPerformPanel.new()
	perform_panel.performer = performer
	perform_panel.flash = flash
	perform_panel.visible = false
	main_vbox.add_child(perform_panel)

	var playback_tabs := TabContainer.new()
	playback_tabs.custom_minimum_size = Vector2(336, 0)
	split.add_child(playback_tabs)

	cue_panel = CueListPanel.new()
	cue_panel.to_patch_cb = _load_look_to_patch
	playback_tabs.add_child(_scrollable(cue_panel))
	chase_panel = ChaseListPanel.new()
	chase_panel.to_patch_cb = _load_look_to_patch
	playback_tabs.add_child(_scrollable(chase_panel))

	groups_panel = GroupsPanel.new()
	groups_panel.groups = groups
	groups_panel.fixtures_provider = _list_patched_fixtures

	fx_panel = EffectsPanel.new()
	fx_panel.resolve_targets_cb = _resolve_fx_targets
	fx_panel.group_names_provider = _group_names
	playback_tabs.add_child(_scrollable(fx_panel))

	sound_panel = SoundPanel.new()
	sound_panel.resolve_targets_cb = _resolve_fx_targets
	sound_panel.group_names_provider = _group_names
	playback_tabs.add_child(_scrollable(sound_panel))

	playback_tabs.add_child(_scrollable(groups_panel))

	faders.fixtures_provider = _perform_fixtures
	faders.groups_provider = func(): return groups
	faders.cue_look_provider = cue_panel.standing_look
	add_child(faders)
	faders_panel = FadersPanel.new()
	faders_panel.bank = faders
	faders_panel.cue_count_provider = func(): return cue_panel.cues.size()
	faders_panel.group_names_provider = _group_names

	playback_tabs.set_tab_title(0, "Cues")
	playback_tabs.set_tab_title(1, "Chases")
	playback_tabs.set_tab_title(2, "Effects")
	playback_tabs.set_tab_title(3, "Sound")
	playback_tabs.set_tab_title(4, "Groups")

	groups_panel.groups_changed.connect(fx_panel.refresh_group_options)
	groups_panel.groups_changed.connect(sound_panel.refresh_group_options)
	groups_panel.groups_changed.connect(faders_panel.refresh_targets)
	cue_panel.cues_changed.connect(faders_panel.refresh_targets)
	chase_panel.chases_changed.connect(faders_panel.refresh_targets)
	faders.chases_changed.connect(chase_panel.sync_ui)
	playback_tabs.tab_changed.connect(func(i: int):
		if i == 4:
			groups_panel.sync_to_patch()
		elif i == 2:
			fx_panel.refresh_group_options()
		elif i == 3:
			sound_panel.refresh_group_options())

	# Right side: "Patch" (the universe tabs), the "3D Visualizer", "DMX
	# Output" and the playback "Faders" (here for the room to spread out).
	_right_tabs = TabContainer.new()
	_right_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(_right_tabs)

	universe_tabs = TabContainer.new()
	_right_tabs.add_child(universe_tabs)

	viz_panel = VisualizerPanel.new()
	viz_panel.panels = _panels
	viz_panel.mvr_import_cb = _do_mvr_import
	viz_panel.mvr_export_cb = _do_mvr_export
	viz_panel.popout_pressed.connect(_dock_viz)
	_right_tabs.add_child(viz_panel)

	dmx_output_panel = DmxOutputPanel.new()
	_right_tabs.add_child(dmx_output_panel)

	var faders_scroll := _scrollable(faders_panel)
	_right_tabs.add_child(faders_scroll)

	_right_tabs.set_tab_title(0, "Patch")
	_right_tabs.set_tab_title(_VIZ_TAB, "3D Visualizer")
	_right_tabs.set_tab_title(2, "DMX Output")
	_right_tabs.set_tab_title(3, "Faders")
	# By its control, not its index: that shifts while the visualizer's
	# popped out.
	_right_tabs.tab_changed.connect(func(_i: int):
		if _right_tabs.get_current_tab_control() == faders_scroll:
			faders_panel.refresh_targets())
	_right_tabs.get_tab_bar().gui_input.connect(_on_right_tabbar_input)
	set_process(false)

	_load_available_profiles()

	# ArtNet always starts with one universe slot; give it a tab.
	_add_universe_tab(ArtNet.get_universe(0))
	_update_universe_buttons()
	fx_panel.refresh_universe_options()
	sound_panel.refresh_universe_options()
	viz_panel.rebuild()

	# Keep tab content off the container edges (the 3D visualizer tab is
	# meant to be full-bleed, so right_tabs is left alone).
	_pad_tab_content(playback_tabs)
	_pad_tab_content(universe_tabs)

	# MIDI / OSC GO triggers.
	_triggers_dialog = TriggersDialog.new()
	_triggers_dialog.chase_names_provider = _chase_names
	_triggers_dialog.effect_names_provider = _effect_names
	_triggers_dialog.visible = false
	add_child(_triggers_dialog)
	Triggers.fired.connect(_on_trigger_fired)
	Triggers.released.connect(_on_trigger_released)
	Triggers.feedback_state_cb = _feedback_state

	_refresh_timer = Timer.new()
	add_child(_refresh_timer)
	_refresh_timer.wait_time = 1.0 / REFRESH_HZ
	_refresh_timer.timeout.connect(_on_refresh_timeout)
	_refresh_timer.start()

	# Reopen the show that was current last time — only when running as
	# the app (a test that adds this scene itself loads nothing).
	(func():
		if get_tree().current_scene == self:
			restore_last_show()
			_restore_ui_state()
			_start_autosave()
	).call_deferred()


# ---------------------------------------------------------------- UI BUILD --

## Selected and hovered buttons in cornflower blue. Godot's default theme
## draws a pressed (toggled-on) button darker than a normal one and hover
## only faintly lighter, so a selected category group or the button under
## the mouse is hard to make out. Only these states are overridden; the
## rest falls back to the default theme. Set on the main window, so its
## dialogs and the popped-out visualizer pick it up too.
const ACCENT := Color(0.392, 0.584, 0.929)   # cornflower blue, #6495ED

static func _app_theme() -> Theme:
	var base := ThemeDB.get_default_theme()
	var t := Theme.new()
	var restyle := func(type: String, state: String, bg: Color, border: Color) -> void:
		var sb := base.get_stylebox(state, type).duplicate()
		if sb is StyleBoxFlat:
			sb.bg_color = bg
			sb.border_color = border
			sb.set_border_width_all(1 if border.a > 0.0 else 0)
		t.set_stylebox(state, type, sb)
	for type in ["Button", "OptionButton", "MenuButton"]:
		restyle.call(type, "hover", Color(ACCENT, 0.22), ACCENT)
		restyle.call(type, "pressed", ACCENT.darkened(0.3), Color(0, 0, 0, 0))
		restyle.call(type, "hover_pressed", ACCENT.darkened(0.1), Color(0, 0, 0, 0))
		t.set_color("font_pressed_color", type, Color.WHITE)
		t.set_color("font_hover_pressed_color", type, Color.WHITE)
		t.set_color("icon_pressed_color", type, Color.WHITE)
		t.set_color("icon_hover_pressed_color", type, Color.WHITE)
	return t


## Inset every tab's content by a few pixels so controls don't sit flush
## against the container edge. Keeps the theme's panel look, just adds
## content margins.
func _pad_tab_content(tc: TabContainer, pad := 8.0) -> void:
	var base := tc.get_theme_stylebox("panel")
	var sb: StyleBox = base.duplicate() if base != null else StyleBoxEmpty.new()
	sb.content_margin_left = pad
	sb.content_margin_right = pad
	sb.content_margin_top = pad
	sb.content_margin_bottom = pad
	tc.add_theme_stylebox_override("panel", sb)


## ------------------------------------------------- VISUALIZER POP-OUT --
## The 3D Visualizer can live in its own OS window (drag it to a second
## monitor for front-of-house). It's the same VisualizerPanel node,
## reparented between `_right_tabs` and a `Window`.
##
## Tear-off: drag the "3D Visualizer" tab off the tab bar. Re-dock: drag
## the window's title back over the tab bar (it lights up), close the
## window, or press "Dock to Main" in it.

var _viz_tab_grab := false
var _viz_last_pos := Vector2i.ZERO
var _viz_move_frames := 0
var _viz_still_frames := 0


func _on_right_tabbar_input(event: InputEvent) -> void:
	if _viz_window != null:
		return
	var tb := _right_tabs.get_tab_bar()
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_viz_tab_grab = tb.get_tab_idx_at_point(event.position) == _VIZ_TAB
		elif _viz_tab_grab:
			_viz_tab_grab = false
			# released clearly away from the tab bar -> tear it off (a small
			# margin so a nudge or a mis-click doesn't detach it)
			if not Rect2(Vector2.ZERO, tb.size).grow(28.0).has_point(event.position):
				_pop_out_viz()
	elif event is InputEventMouseButton and not event.pressed:
		_viz_tab_grab = false


func _pop_out_viz(rect := Rect2i()) -> void:
	if _viz_window != null:
		return
	var w := Window.new()
	# A real OS window, so it can go on another screen. Everything else
	# (dialogs, tooltips, menus) is embedded in the main window
	# (display/window/subwindows/embed_subwindows): a native tooltip window
	# stalls the whole app ~140 ms each time it opens — a playhead jump in
	# DJ Edit Mode, a hiccup in DMX output. (Only settable while the
	# window is hidden, so it's shown once it's in the tree.)
	w.visible = false
	w.force_native = true
	w.title = "sLight — 3D Visualizer"
	w.min_size = Vector2i(480, 320)
	var scr := DisplayServer.screen_get_usable_rect(get_window().current_screen)
	if rect.size.x > 200 and rect.size.y > 200:
		w.size = rect.size
		w.position = rect.position
		# reopened where it was saved: keep it on that screen (a second
		# monitor for front-of-house), if that screen's still connected
		for s in DisplayServer.get_screen_count():
			var sr := DisplayServer.screen_get_usable_rect(s)
			if sr.has_point(rect.get_center()):
				scr = sr
				break
	else:
		w.size = Vector2i(1000, 620)
		# drop it under the pointer, title bar clear of the screen edge
		w.position = Vector2i(DisplayServer.mouse_get_position()) - Vector2i(180, 6)
	w.position = Vector2i(
		clampi(w.position.x, scr.position.x + 8, scr.position.x + scr.size.x - 120),
		clampi(w.position.y, scr.position.y + 36, scr.position.y + scr.size.y - 80))
	w.close_requested.connect(_dock_viz)
	add_child(w)
	w.show()

	_right_tabs.remove_child(viz_panel)
	w.add_child(viz_panel)
	viz_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	# The tab container hides tabs that aren't current: popped out at
	# startup (Patch showing), the panel would arrive hidden and not draw.
	viz_panel.visible = true
	_viz_window = w
	_viz_last_pos = w.position
	_viz_move_frames = 0
	_viz_still_frames = 0
	viz_panel.set_floating(true)
	set_process(true)
	# "Patch" is the only tab left; it doubles as the re-dock drop zone.
	status_label.text = "3D Visualizer popped out — drag its title onto the tab bar to dock, or close it."
	_save_ui_state()


func _dock_viz() -> void:
	if _viz_window == null:
		return
	var w := _viz_window
	_viz_window = null                       # guard against close_requested re-entry
	set_process(false)
	_right_tabs.get_tab_bar().self_modulate = Color.WHITE
	if viz_panel.get_parent() == w:
		w.remove_child(viz_panel)
		_right_tabs.add_child(viz_panel)
		_right_tabs.move_child(viz_panel, _VIZ_TAB)
		_right_tabs.set_tab_title(_VIZ_TAB, "3D Visualizer")
		_right_tabs.current_tab = _VIZ_TAB
	viz_panel.set_floating(false)
	w.queue_free()
	_save_ui_state()


## While the visualizer floats, watch its window: when the user drags its
## title over the tab bar and lets go, dock it back.
func _process(_delta: float) -> void:
	if _viz_window == null:
		return
	var pos := _viz_window.position
	var over := _viz_title_over_tab_bar()
	if pos != _viz_last_pos:
		_viz_last_pos = pos
		_viz_move_frames += 1
		_viz_still_frames = 0
	elif _viz_move_frames >= 3:
		_viz_still_frames += 1
		if _viz_still_frames >= 18:
			_viz_move_frames = 0
			if over:
				_dock_viz()
				return
	_right_tabs.get_tab_bar().self_modulate = (
		Color(0.55, 0.8, 1.0) if (over and _viz_move_frames >= 3) else Color.WHITE)


func _viz_title_over_tab_bar() -> bool:
	var tb := _right_tabs.get_tab_bar()
	var zone := Rect2i(
		get_window().position + Vector2i(tb.global_position),
		Vector2i(int(_right_tabs.size.x), maxi(int(tb.size.y), 28) + 16))
	# the window's own top strip (client-area top ≈ just under the OS title)
	return zone.intersects(Rect2i(_viz_window.position, Vector2i(_viz_window.size.x, 6)))


func _viz_window_dict() -> Dictionary:
	if _viz_window == null:
		return {"floating": false, "ui": viz_panel.is_ui_visible()}
	return {
		"floating": true,
		"rect": [_viz_window.position.x, _viz_window.position.y,
			_viz_window.size.x, _viz_window.size.y],
		"ui": viz_panel.is_ui_visible(),
	}


func _apply_viz_window(d: Dictionary) -> void:
	viz_panel.set_ui_visible(bool(d.get("ui", true)))
	var want_float := bool(d.get("floating", false))
	var rect := Rect2i()
	var ra = d.get("rect", null)
	if ra is Array and ra.size() == 4:
		rect = Rect2i(int(ra[0]), int(ra[1]), int(ra[2]), int(ra[3]))
	if want_float and _viz_window == null:
		_pop_out_viz(rect)
	elif want_float and _viz_window != null and rect.size.x > 200:
		_viz_window.position = rect.position
		_viz_window.size = rect.size
	elif not want_float and _viz_window != null:
		_dock_viz()


## Where the visualizer window's state (docked, or floating and where;
## its UI shown or hidden) is
## kept between runs. It's this machine's screen layout, not the show's,
## so it isn't in the show file.
var ui_state_store := "user://ui_state.json"


func _save_ui_state() -> void:
	var f := FileAccess.open(ui_state_store, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"viz_window": _viz_window_dict()}))
		f.close()


func _restore_ui_state() -> void:
	if not FileAccess.file_exists(ui_state_store):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(ui_state_store))
	if parsed is Dictionary and parsed.get("viz_window") is Dictionary:
		_apply_viz_window(parsed["viz_window"])


func _notification(what: int) -> void:
	# quitting: keep where the floating visualizer was last moved / sized to
	if what == NOTIFICATION_WM_CLOSE_REQUEST and get_tree().current_scene == self:
		_save_ui_state()
		if music_panel:
			music_panel.timeline().flush()    # the open song's edits
		autosave.end()                        # a clean quit: nothing to recover


## Wrap a playback panel so it gets a vertical scrollbar when the window
## is too short to show all of its controls. Horizontal scrolling is off —
## the panels already wrap their rows to the available width. Tab titles
## are set explicitly by the caller.
func _scrollable(panel: Control) -> ScrollContainer:
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_FILL
	sc.add_child(panel)
	return sc


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _build_top_bar() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)

	# Wraps its buttons to the next line when the window is too narrow.
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 8)
	row.add_theme_constant_override("v_separation", 4)

	row.add_child(_label("View:"))
	view_option = OptionButton.new()
	for v in VIEWS:
		view_option.add_item(v)
	view_option.item_selected.connect(set_view)
	row.add_child(view_option)
	row.add_child(VSeparator.new())

	row.add_child(_label("Grand Master:"))
	master_slider = HSlider.new()
	master_slider.min_value = 0
	master_slider.max_value = 255
	master_slider.step = 1
	master_slider.value = 255
	master_slider.custom_minimum_size = Vector2(200, 0)
	master_slider.value_changed.connect(func(v: float): ArtNet.master = v / 255.0)
	row.add_child(master_slider)

	row.add_child(_label("Run Mode:"))
	run_mode_option = OptionButton.new()
	for m in RUN_MODES:
		run_mode_option.add_item(m)
	run_mode_option.selected = run_mode
	run_mode_option.item_selected.connect(_on_run_mode_changed)
	row.add_child(run_mode_option)

	# The tempo clock: tapped here, or taken from MIDI clock / VirtualDJ.
	var tap_btn := Button.new()
	tap_btn.text = "Tap"
	tap_btn.tooltip_text = "Tap Tempo (T): tap on the beat to set the tempo clock that beat-sync chases and tempo-synced effects follow. MIDI clock or VirtualDJ's beats take it over while they arrive."
	tap_btn.focus_mode = Control.FOCUS_NONE     # Space stays the cue GO
	tap_btn.button_down.connect(func(): Tempo.tap())     # on the press, not the release
	row.add_child(tap_btn)
	tempo_label = _label(Tempo.describe())
	tempo_label.custom_minimum_size = Vector2(150, 0)
	tempo_label.tooltip_text = "The tempo clock: its BPM and what's setting it."
	row.add_child(tempo_label)
	tempo_stop_btn = Button.new()
	tempo_stop_btn.text = "✕"
	tempo_stop_btn.flat = true
	tempo_stop_btn.tooltip_text = "Stop the tempo clock (chases go back to their own BPM)"
	tempo_stop_btn.pressed.connect(Tempo.stop)
	tempo_stop_btn.visible = Tempo.running
	row.add_child(tempo_stop_btn)
	Tempo.changed.connect(_on_tempo_changed)
	Tempo.beat.connect(_on_tempo_beat)

	sending_toggle = CheckButton.new()
	sending_toggle.text = "Sending"
	sending_toggle.button_pressed = true
	row.add_child(sending_toggle)

	var blackout := Button.new()
	blackout.text = "Blackout All"
	blackout.pressed.connect(_on_blackout_all)
	row.add_child(blackout)

	add_uni_btn = Button.new()
	add_uni_btn.text = "Add Universe"
	add_uni_btn.tooltip_text = "Add another universe (Ctrl+Shift+N)"
	add_uni_btn.pressed.connect(_on_add_universe)
	row.add_child(add_uni_btn)

	remove_uni_btn = Button.new()
	remove_uni_btn.text = "Remove Universe"
	remove_uni_btn.tooltip_text = "Remove the selected universe, after asking (Ctrl+Shift+R)"
	remove_uni_btn.pressed.connect(_confirm_remove_universe)
	row.add_child(remove_uni_btn)

	var new_show := Button.new()
	new_show.text = "New Show"
	new_show.tooltip_text = "Start a new, empty show (Ctrl+N)"
	new_show.pressed.connect(_on_new_show)
	row.add_child(new_show)

	var save_show := Button.new()
	save_show.text = "Save Show"
	save_show.tooltip_text = "Save the show to its current file (Ctrl+S)"
	save_show.pressed.connect(_on_save_show)
	row.add_child(save_show)

	var save_show_as := Button.new()
	save_show_as.text = "Save Show As…"
	save_show_as.tooltip_text = "Save the show to a new file (Shift+Ctrl+S)"
	save_show_as.pressed.connect(_on_save_show_as)
	row.add_child(save_show_as)

	var load_show := Button.new()
	load_show.text = "Load Show…"
	load_show.tooltip_text = "Open a show file (Ctrl+O)"
	load_show.pressed.connect(_on_load_show)
	row.add_child(load_show)

	var save_preset := Button.new()
	save_preset.text = "Save Preset"
	save_preset.pressed.connect(_on_save_preset)
	row.add_child(save_preset)

	var load_preset := Button.new()
	load_preset.text = "Load Preset"
	load_preset.pressed.connect(_on_load_preset)
	row.add_child(load_preset)

	var triggers_btn := Button.new()
	triggers_btn.text = "Triggers…"
	triggers_btn.pressed.connect(func(): _triggers_dialog.popup_centered())
	row.add_child(triggers_btn)

	col.add_child(row)

	status_label = _label("")
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(status_label)

	return col


## Switch the main area: 0 = the console (playback tabs + patch /
## visualizer / DMX output), 1 = DJ Edit Mode (the music library and song
## timelines), 2 = DJ Perform Mode (VirtualDJ over OS2L playing the
## timelines: its listener and timeline playback run only while it's
## showing). The top bar stays, and the console keeps running underneath.
func set_view(idx: int) -> void:
	idx = clampi(idx, 0, VIEWS.size() - 1)
	_console_view.visible = idx == 0
	music_panel.visible = idx == 1           # leaving it saves the open song's timelines
	perform_panel.visible = idx == 2
	if idx == 2 and not performer.is_active():
		music_panel.vdj_database()          # now, not mid-set when a song needs its grid
		var err := performer.start()
		status_label.text = "DJ Perform Mode: " + ("listening for VirtualDJ (OS2L)." if err == OK else performer.status())
	elif idx != 2 and performer.is_active():
		performer.stop()
		status_label.text = "DJ Perform Mode stopped."
	if view_option.selected != idx:
		view_option.selected = idx


## The view showing (index into VIEWS).
func current_view() -> int:
	return view_option.selected


# ------------------------------------------------------------- UNIVERSES --

func _add_universe_tab(sender: ArtNetUniverse) -> UniversePanel:
	var panel := UniversePanel.new()
	panel.sender = sender
	panel.available_profiles = available_profiles
	panel.profile_action_cb = _on_profile_action
	panel.patch_names_cb = func():
		var names: Array = []
		for p in _panels:
			for f in p.patched_fixtures:
				names.append(String(f["name"]))
		return names
	panel.panels_cb = func(): return _panels
	panel.patch_changed.connect(_on_patch_changed)
	universe_tabs.add_child(panel)
	_panels.append(panel)
	_refresh_tab_titles()
	return panel


func _on_add_universe() -> void:
	var u := ArtNet.add_universe()
	if u == null:
		status_label.text = "Universe limit reached (%d)." % ArtNet.MAX_UNIVERSES
		return
	_add_universe_tab(u)
	universe_tabs.current_tab = _panels.size() - 1
	_update_universe_buttons()
	fx_panel.refresh_universe_options()
	sound_panel.refresh_universe_options()
	status_label.text = "Added universe %d." % _panels.size()


## Remove Universe (button or Ctrl+Shift+R): ask, then remove the current
## universe (the selected universe tab), saying how many fixtures go with
## it.
func _confirm_remove_universe() -> void:
	if _panels.size() <= 1:
		status_label.text = "Can't remove the only universe."
		return
	var idx: int = universe_tabs.current_tab
	if idx < 0 or idx >= _panels.size():
		idx = _panels.size() - 1
	var n: int = _panels[idx].patched_fixtures.size()
	var dlg := ConfirmationDialog.new()
	dlg.title = "Remove Universe"
	dlg.dialog_text = "Remove universe %d%s?" % [idx + 1,
		"" if n == 0 else " and its %d fixture%s (also taken out of any groups)" % [n, "" if n == 1 else "s"]]
	dlg.ok_button_text = "Remove"
	add_child(dlg)
	dlg.confirmed.connect(func():
		dlg.queue_free()
		_on_remove_universe())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()


func _on_remove_universe() -> void:
	if _panels.size() <= 1:
		return
	var idx: int = universe_tabs.current_tab
	if idx < 0 or idx >= _panels.size():
		idx = _panels.size() - 1

	ArtNet.remove_universe(idx)
	var panel := _panels[idx]
	# Its fixtures leave their groups.
	var gone := {}
	for fx in panel.patched_fixtures:
		gone[String(fx["uid"])] = true
	for g in groups:
		g["members"] = (g["members"] as Array).filter(func(m): return not gone.has(String(m)))
	universe_tabs.remove_child(panel)
	panel.queue_free()
	_panels.remove_at(idx)
	groups_panel.sync_to_patch()

	_refresh_tab_titles()
	_update_universe_buttons()
	fx_panel.refresh_universe_options()
	sound_panel.refresh_universe_options()
	status_label.text = "Removed a universe (%d left)." % _panels.size()


func _sync_tabs_to_universes() -> void:
	while _panels.size() < ArtNet.universe_count():
		_add_universe_tab(ArtNet.get_universe(_panels.size()))
	while _panels.size() > ArtNet.universe_count():
		var panel := _panels[_panels.size() - 1]
		universe_tabs.remove_child(panel)
		panel.queue_free()
		_panels.pop_back()
	_refresh_tab_titles()
	_update_universe_buttons()
	fx_panel.refresh_universe_options()
	sound_panel.refresh_universe_options()
	if viz_panel:
		viz_panel.rebuild()


## Resolve an effect's channel targets from the live patch: every patched
## fixture that has a channel with `role` contributes that channel. When
## `group` names a fixture group, only its members count; otherwise
## `universe` filters (-1 = all universes).
func _resolve_fx_targets(role: String, universe: int, group: String = "") -> Array:
	var member_set := {}
	var use_group := false
	if group != "":
		for g in groups:
			if String(g["name"]) == group:
				use_group = true
				for m in g["members"]:
					member_set[String(m)] = true

	var out: Array = []
	for ui in range(_panels.size()):
		if not use_group and universe != -1 and universe != ui:
			continue
		for fixture in _panels[ui].patched_fixtures:
			if use_group and not member_set.has(String(fixture["uid"])):
				continue
			var profile: FixtureProfile = fixture["profile"]
			var chans: Array = profile.channels_for_mode(int(fixture.get("mode", 0)))
			var start: int = fixture["start"]
			for li in range(chans.size()):
				# A fine channel (a 16-bit pair's low byte) isn't a target
				# of its own, even carrying its coarse channel's role.
				if String(chans[li]["role"]) == role and not bool(chans[li].get("fine", false)):
					out.append({"u": ui, "ch": start + li})
	return out


func _group_names() -> Array:
	var out: Array = []
	for g in groups:
		out.append(String(g["name"]))
	return out


## Every patched fixture as { uid, label } for the groups checklist.
func _list_patched_fixtures() -> Array:
	var out: Array = []
	for ui in range(_panels.size()):
		for fx in _panels[ui].patched_fixtures:
			var prof: FixtureProfile = fx["profile"]
			var start: int = fx["start"]
			var count := prof.channel_count(int(fx.get("mode", 0)))
			out.append({
				"uid": String(fx["uid"]),
				"label": "U%d · %s (ch %d-%d)" % [ui + 1, fx["name"], start + 1, start + count],
			})
	return out


func _on_patch_changed() -> void:
	for p in _panels:
		p.recolour()                          # a model's colour can move with the patch
	if groups_panel:
		groups_panel.sync_to_patch()
	if viz_panel:
		viz_panel.rebuild()
	if music_panel:
		music_panel.timeline().refresh_fixtures()
		music_panel.position_editor().refresh_fixtures()


## Light these fixtures (by uid) full white and point them at the
## position being edited — the position editor's selection — and put
## every other fixture that was lit back as it was.
func highlight_fixtures(uids: Array) -> void:
	var editor := music_panel.position_editor()
	for p in _panels:
		for fx in p.patched_fixtures:
			var uid := String(fx["uid"])
			var id := int(fx["id"])
			p.set_highlight(id, uid in uids)
			if uid in uids and editor.position_id != "":
				p.aim(id, positions.point(editor.position_id, uid))


## Every patched fixture for the position editor (it lists those with pan
## and tilt).
func _position_fixtures() -> Array:
	var out: Array = []
	for ui in range(_panels.size()):
		for fx in _panels[ui].patched_fixtures:
			out.append({"uid": String(fx["uid"]), "name": "U%d · %s" % [ui + 1, fx["name"]],
				"profile": fx["profile"], "mode": int(fx.get("mode", 0))})
	return out


## Every patched fixture for DJ Perform Mode's timeline playback (but the
## ones highlighted, with `unlit_only`).
func _perform_fixtures(unlit_only := false) -> Array:
	var out: Array = []
	for ui in range(_panels.size()):
		for fx in _panels[ui].patched_fixtures:
			if unlit_only and _panels[ui].is_highlighted(int(fx["id"])):
				continue
			out.append({"uid": String(fx["uid"]), "u": ui, "start": int(fx["start"]),
				"profile": fx["profile"], "mode": int(fx.get("mode", 0)),
				"exclude_generate": bool(fx.get("exclude_generate", false))})
	return out


## The DMX layer for ArtNet.tick() from the song open in DJ Edit Mode: its
## timelines (edits included, as they stand) at the playhead, the way DJ
## Perform Mode would play them — while it plays, and while it's paused
## with its timeline showing (holding the look at the playhead, following
## it as it's moved). Nothing in the other views (the Positions Editor
## included) unless it's playing, and nothing while DJ Perform Mode is on
## — the live decks own the rig then. Never the fixtures highlighted (the
## Positions Editor's): they keep their white and aim.
func _edit_playback_layer(n: int) -> Array:
	var tl := music_panel.timeline()
	var shown := music_panel.visible and music_panel.is_timeline_shown()
	if not tl.can_play() or not (tl.is_playing() or shown) or performer.is_active():
		var empty: Array = []
		for i in range(n):
			empty.append({})
		return empty
	var bases: Array = []
	for i in range(n):
		var u := ArtNet.get_universe(i)
		bases.append(u.dmx_data if u != null else PackedByteArray())
	return DjPerformer.song_output(tl.live_tracks(), tl.playback_position(), _perform_fixtures(true), bases, n, positions)


## Every patched fixture, universe by universe, for the DJ Edit Mode
## timeline's per-fixture tracks — keyed by its uid, which the show's saved
## timelines use — with its category (FixtureProfile.SHOW_CATEGORIES),
## category group (1-4) and whether it's left out, for show generation.
func _timeline_fixtures() -> Array:
	var out: Array = []
	var colours := UniversePanel.model_colours(_panels)
	for ui in range(_panels.size()):
		for fx in _panels[ui].patched_fixtures:
			out.append({"key": String(fx["uid"]), "name": String(fx["name"]),
				"profile": fx["profile"], "mode": int(fx.get("mode", 0)),
				"category": String(fx.get("category", "")),
				"category_group": int(fx.get("category_group", 1)),
				"exclude_generate": bool(fx.get("exclude_generate", false)),
				"colour": colours[(fx["profile"] as FixtureProfile).full_name()]})
	return out


## Groups saved with their members' fixture uids (saved with the patch).
func _groups_to_dict() -> Dictionary:
	var arr: Array = []
	for g in groups:
		arr.append({"name": String(g["name"]), "members": (g["members"] as Array).duplicate()})
	return {"groups": arr}


func _groups_from_dict(d) -> void:
	groups.clear()
	if not (d is Dictionary):
		return
	for g in d.get("groups", []):
		if not (g is Dictionary):
			continue
		var mem: Array = []
		for m in g.get("members", []):
			if m is String:
				mem.append(m)
			elif m is Array and m.size() >= 2:
				# Older shows: [universe, patch index] — that fixture's uid
				# (the patch is loaded first).
				var u := int(m[0])
				var idx := int(m[1])
				if u >= 0 and u < _panels.size() and idx >= 0 and idx < _panels[u].patched_fixtures.size():
					mem.append(String(_panels[u].patched_fixtures[idx]["uid"]))
		groups.append({"name": String(g.get("name", "Group")), "members": mem})


func _refresh_tab_titles() -> void:
	for i in range(universe_tabs.get_tab_count()):
		universe_tabs.set_tab_title(i, "Universe %d" % (i + 1))


func _update_universe_buttons() -> void:
	add_uni_btn.disabled = ArtNet.universe_count() >= ArtNet.MAX_UNIVERSES
	remove_uni_btn.disabled = ArtNet.universe_count() <= 1


func _on_blackout_all() -> void:
	cue_panel.halt()                      # its fade, and any delay / follow waiting
	faders.pull_down_playback()           # cue and chase faders to 0
	Fx.stop_all()
	chase_panel.sync_ui()
	fx_panel.sync_ui()
	sound_panel.sync_ui()
	for i in range(ArtNet.universe_count()):
		ArtNet.get_universe(i).set_all(0)
	status_label.text = "Blackout — all universes, chases, effects and reactors stopped."


## Cue Mode: cues own playback. Sound Reactive: the audio input drives
## reactors + beat-synced chases on top of the standing base look.
func _on_run_mode_changed(idx: int) -> void:
	_set_run_mode(idx)
	match run_mode:
		1: status_label.text = "Sound Reactive — monitoring the audio input. Arm reactors in the Sound tab."
		_: status_label.text = "Cue Mode — cue list drives playback."


func _set_run_mode(idx: int) -> void:
	run_mode = idx if idx >= 0 and idx < RUN_MODES.size() else 0
	if run_mode_option.selected != run_mode:
		run_mode_option.selected = run_mode
	Fx.sound_reactive = run_mode == 1
	Sound.active = run_mode == 1


func _on_tempo_changed() -> void:
	tempo_label.text = Tempo.describe()
	tempo_stop_btn.visible = Tempo.running


## Each beat of the tempo clock: the read-out flashes, and its BPM (which
## MIDI clock and VirtualDJ keep refining) is brought up to date.
func _on_tempo_beat() -> void:
	tempo_label.text = Tempo.describe()
	tempo_label.modulate = ACCENT.lightened(0.4)
	create_tween().tween_property(tempo_label, "modulate", Color.WHITE, 0.25)


# ------------------------------------------------------ MIDI / OSC TRIGGERS --

func _chase_names() -> Array:
	var out: Array = []
	for c in Fx.chases:
		out.append(c.name)
	return out


func _effect_names() -> Array:
	var out: Array = []
	for e in Fx.effects:
		out.append(e.name)
	return out


## "Load to Patch" — write a cue's or chase step's per-universe look into
## the fixture controls so it can be edited and re-recorded.
func _load_look_to_patch(buffers: Array) -> void:
	ArtNet.stop_fade()
	for i in range(min(buffers.size(), _panels.size())):
		_panels[i].load_look(buffers[i])


## A MIDI / OSC binding matched — run its console action.
func _on_trigger_fired(action: int, target: String) -> void:
	match action:
		Trigger.ACT_CUE_GO: cue_panel.go()
		Trigger.ACT_CUE_BACK: cue_panel.go_back()
		Trigger.ACT_CUE_HALT: cue_panel.halt()
		Trigger.ACT_CUE_GOTO: cue_panel.go_to_number(int(target) if target.is_valid_int() else 1)
		Trigger.ACT_CHASE_TOGGLE: chase_panel.toggle_by_name(target)
		Trigger.ACT_EFFECT_TOGGLE: fx_panel.toggle_by_name(target)
		Trigger.ACT_BLACKOUT: _on_blackout_all()
		Trigger.ACT_TAP_TEMPO: Tempo.tap()
		_ when Trigger.FLASH_ACTIONS.has(action):
			var kind := Trigger.FLASH_ACTIONS.find(action)
			if target == Trigger.FLASH_TOGGLE:
				flash.toggle(kind)
			else:
				flash.press(kind)


## A flash binding's pad came back up.
func _on_trigger_released(action: int, _target: String) -> void:
	var kind := Trigger.FLASH_ACTIONS.find(action)
	if kind >= 0:
		flash.release(kind)


## Whether a feedback binding's watched state is currently active — its
## pad LED follows this.
func _feedback_state(kind: String, target: String) -> bool:
	var low := target.strip_edges().to_lower()
	match kind:
		"cue":
			return target.is_valid_int() and cue_panel.current_number() == int(target)
		"chase":
			for c in Fx.chases:
				if c.name.to_lower() == low:
					return c.running
		"effect":
			for e in Fx.effects:
				if e.name.to_lower() == low:
					return e.running
		"run_mode":
			return target.is_valid_int() and run_mode == int(target)
		"sending":
			return sending_toggle.button_pressed
		"fx_any":
			return Fx.any_running()
		"flash":
			return target.is_valid_int() and flash.is_on(int(target))
	return false


func _on_refresh_timeout() -> void:
	# Always recompute each universe's output (the 3D view reads it);
	# only put it on the wire while "Sending" is checked.
	ArtNet.tick(sending_toggle.button_pressed)


## Space fires the next cue, like a real console — but only when no text
## field or button ate the keypress first, and only in the Console view.
func _unhandled_key_input(event: InputEvent) -> void:
	# DJ Perform Mode: B / S / W / C hold the live flashes (Latch: toggle).
	# (A release counts in any view, so one held across a view change lets go.)
	if event is InputEventKey and (perform_panel.visible or not event.pressed) and not event.echo \
			and LiveFlash.KEYS.has(event.keycode) and not event.is_command_or_control_pressed() \
			and not event.shift_pressed and not event.alt_pressed:
		var kind := LiveFlash.KEYS.find(event.keycode)
		if event.pressed:
			flash.press(kind)
		else:
			flash.release(kind)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE and run_mode == 0 and _console_view.visible:
			cue_panel.go()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_T and not event.is_command_or_control_pressed() \
				and not event.shift_pressed and not event.alt_pressed:
			# T: Tap Tempo, from any view.
			Tempo.tap()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_S and event.is_command_or_control_pressed():
			# Ctrl+S: Save Show; Shift+Ctrl+S: Save Show As… — from either view.
			if event.shift_pressed:
				_on_save_show_as()
			else:
				_on_save_show()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_N and event.is_command_or_control_pressed():
			# Ctrl+N: New Show; Ctrl+Shift+N: Add Universe — from either view.
			if event.shift_pressed:
				_on_add_universe()
			else:
				_on_new_show()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_R and event.is_command_or_control_pressed() and event.shift_pressed:
			# Ctrl+Shift+R: remove the current universe, after asking.
			_confirm_remove_universe()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_O and event.is_command_or_control_pressed() and not event.shift_pressed:
			# Ctrl+O: Load Show…, from either view.
			_on_load_show()
			get_viewport().set_input_as_handled()


# -------------------------------------------------------------- PROFILES --

func _load_available_profiles() -> void:
	available_profiles.clear()
	_builtin_ids.clear()

	# Built-ins first, in their declared order; a custom file with the same
	# id replaces the built-in in place (that's how an edited built-in
	# "sticks"), and custom-only profiles are appended after.
	var by_id := {}
	var order: Array = []
	for p in FixtureProfile.built_in_profiles():
		_builtin_ids[p.id] = true
		by_id[p.id] = p
		order.append(p.id)

	if not DirAccess.dir_exists_absolute(PROFILES_DIR):
		DirAccess.make_dir_recursive_absolute(PROFILES_DIR)

	var dir := DirAccess.open(PROFILES_DIR)
	if dir:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			if fname.ends_with(".json"):
				var f := FileAccess.open(PROFILES_DIR + "/" + fname, FileAccess.READ)
				if f:
					var parsed = JSON.parse_string(f.get_as_text())
					f.close()
					if parsed is Dictionary:
						var cp := FixtureProfile.from_dict(parsed)
						if not by_id.has(cp.id):
							order.append(cp.id)
						by_id[cp.id] = cp
			fname = dir.get_next()
		dir.list_dir_end()

	for id in order:
		available_profiles.append(by_id[id])


func _profile_file_path(p: FixtureProfile) -> String:
	return PROFILES_DIR + "/%s.json" % p.id


func _profile_index_by_id(id: String) -> int:
	for i in range(available_profiles.size()):
		if available_profiles[i].id == id:
			return i
	return -1


func _profile_has_file(p: FixtureProfile) -> bool:
	return FileAccess.file_exists(_profile_file_path(p))


## Filesystem-safe id from a profile name (lowercase, [a-z0-9_] only).
func _safe_profile_id(pname: String) -> String:
	var s := ""
	for ch in pname.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_":
			s += ch
		elif ch == " " or ch == "-":
			s += "_"
	while s.begins_with("_"):
		s = s.substr(1)
	while s.ends_with("_"):
		s = s.substr(0, s.length() - 1)
	return s if s != "" else "profile"


func _unique_profile_id(base: String) -> String:
	var id := base
	var n := 2
	while _id_in_use(id):
		id = "%s_%d" % [base, n]
		n += 1
	return id


func _id_in_use(id: String) -> bool:
	if FileAccess.file_exists(PROFILES_DIR + "/%s.json" % id):
		return true
	for p in available_profiles:
		if p.id == id:
			return true
	return false


func _on_profile_action(action: String, profile) -> void:
	match action:
		"new":
			_open_profile_dialog(null)
		"import":
			_import_profile()
		"library":
			_open_library_dialog()
		"edit":
			_open_profile_dialog(profile)
		"delete":
			_delete_profile(profile)


## Pick a .gdtf or Open Fixture Library .json and add it as a custom
## profile (opened in the editor afterwards for review).
func _import_profile() -> void:
	var fd := FileDialog.new()
	fd.title = "Import Fixture Definition (GDTF / Open Fixture Library)"
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.add_filter("*.gdtf", "GDTF fixture")
	fd.add_filter("*.json", "Open Fixture Library JSON")
	fd.use_native_dialog = true
	RecentDirs.track(fd, "fixture_import")
	add_child(fd)
	fd.file_selected.connect(func(path: String):
		_do_import(path)
		fd.queue_free()
	)
	fd.canceled.connect(func(): fd.queue_free())
	fd.popup_centered_ratio(0.6)


func _do_import(path: String) -> void:
	var res := FixtureImport.from_path(path)
	if res.has("error"):
		status_label.text = "Import failed: %s" % res["error"]
		return

	var profile: FixtureProfile = res["profile"]
	var base_id := _safe_profile_id(profile.id if profile.id.strip_edges() != "" else profile.full_name())
	profile.id = base_id if not _id_in_use(base_id) else _unique_profile_id(base_id)

	# save any GDTF glTF model files alongside, referenced from the geometry
	var mbytes: Dictionary = res.get("model_bytes", {})
	if not mbytes.is_empty() and profile.geometry.has("tree"):
		var mdir := MODELS_DIR + "/" + profile.id
		DirAccess.make_dir_recursive_absolute(mdir)
		var mmap := {}
		for name in mbytes:
			var fn := _safe_profile_id(name) + ".glb"
			var mf := FileAccess.open(mdir + "/" + fn, FileAccess.WRITE)
			if mf:
				mf.store_buffer(mbytes[name])
				mf.close()
				mmap[name] = fn
		profile.geometry["models"] = mmap
		profile.geometry["models_dir"] = profile.id

	var f := FileAccess.open(PROFILES_DIR + "/%s.json" % profile.id, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(profile.to_dict()))
		f.close()
	available_profiles.append(profile)
	_refresh_all_profile_options(true)

	var warns: Array = res.get("warnings", [])
	var msg := "Imported '%s' — %d mode(s), %d ch." % [
		profile.model, profile.mode_count(), profile.channel_count(0)]
	if not warns.is_empty():
		msg += "  %d approximation(s); check it in Edit..." % warns.size()
		push_warning("Fixture import notes:\n- " + "\n- ".join(warns))
	status_label.text = msg


## Fill `preview` with a fixture's title, credits, and a per-mode channel
## list. `e` is the catalogue entry (bundled or online).
func _lib_render_preview(preview: VBoxContainer, e: Dictionary, p: FixtureProfile) -> void:
	for c in preview.get_children():
		c.queue_free()

	var title := _label(p.model)
	title.add_theme_font_size_override("font_size", 16)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview.add_child(title)

	var sub := " · ".join(([p.manufacturer] if p.manufacturer != "" else []) + (e.get("ofl_cat", []) as Array))
	var authors := ", ".join((e.get("authors", []) as Array))
	if authors != "":
		sub += "   ·   " + authors if sub != "" else authors
	if sub != "":
		var subl := _label(sub)
		subl.modulate = Color(1, 1, 1, 0.6)
		subl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		preview.add_child(subl)

	if e.get("online", false):
		var gdtf: bool = e.get("gdtf", false)
		var o := _label(("bundled + fetched from %s" % ("GDTF-Share" if gdtf else "OFL")) if e.get("bundled", false) \
			else ("fetched from GDTF-Share" if gdtf else "fetched from Open Fixture Library"))
		o.modulate = Color(0.55, 0.8, 1.0)
		preview.add_child(o)

	var heads: Array = p.physical.get("heads", [])
	if heads.size() >= 2:
		preview.add_child(_label("%d heads" % heads.size()))
	if int(e.get("approx", 0)) > 0:
		var ap := _label("%d channel(s) approximated on import" % int(e["approx"]))
		ap.modulate = Color(1, 0.8, 0.4)
		preview.add_child(ap)

	var mode_row := HBoxContainer.new()
	mode_row.add_child(_label("Mode:"))
	var mode_sel := OptionButton.new()
	mode_sel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for n in p.mode_names():
		mode_sel.add_item(n)
	mode_row.add_child(mode_sel)
	preview.add_child(mode_row)

	var ch_box := VBoxContainer.new()
	ch_box.add_theme_constant_override("separation", 1)
	preview.add_child(ch_box)

	var fill_channels := func(mi: int) -> void:
		for c in ch_box.get_children():
			c.queue_free()
		var chans: Array = p.channels_for_mode(mi)
		for ci in range(chans.size()):
			var ch: Dictionary = chans[ci]
			var line := _label("%2d   %s" % [ci + 1, String(ch.get("name", "Ch"))])
			var role := String(ch.get("role", "GENERIC"))
			if role != "GENERIC":
				line.text += "   · %s" % role.to_lower()
			line.modulate = Color(1, 1, 1, 0.55 if ch.get("fine", false) else 0.9)
			ch_box.add_child(line)
	mode_sel.item_selected.connect(fill_channels)
	fill_channels.call(0)


## Drop a library profile into `available_profiles` for the session and
## select it on the active universe (reusing it if already there). It
## rides in the show file via the patch — no user:// copy.
func _lib_commit_profile(p: FixtureProfile) -> void:
	if p == null:
		return
	var idx := _profile_index_by_id(p.id)
	if idx < 0:
		available_profiles.append(p)
		idx = available_profiles.size() - 1
	for panel in _panels:
		panel.populate_profile_option()
	var active := _panels[clampi(universe_tabs.current_tab, 0, _panels.size() - 1)]
	active.profile_option.selected = idx
	active.populate_mode_option()
	status_label.text = "Added '%s' from the library — set a start channel and Add Fixture." % p.model


## Browse the fixture library. "Bundled library" searches res://fixtures
## (fast, fully filterable); "OFL online" pulls the current Open Fixture
## Library list from GitHub and downloads a fixture on demand (cached under
## user://fixture_online). "Add to Patch" resolves the FixtureProfile,
## drops it into `available_profiles` for the session, and selects it — it
## rides in the show file via the patch, no user:// copy.
func _open_library_dialog() -> void:
	if not Library.available():
		status_label.text = "No bundled fixture library found."
		return

	var win := Window.new()
	win.title = "Fixture Library"
	win.size = Vector2i(920, 620)
	win.min_size = Vector2i(660, 440)
	add_child(win)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	win.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	# --- filter bar ---------------------------------------------------
	var filters := HFlowContainer.new()
	filters.add_theme_constant_override("h_separation", 8)
	filters.add_theme_constant_override("v_separation", 4)
	root.add_child(filters)

	var source_opt := OptionButton.new()
	source_opt.add_item("Bundled library")
	source_opt.add_item("OFL online")
	source_opt.add_item("GDTF-Share")
	filters.add_child(source_opt)

	var search := LineEdit.new()
	search.placeholder_text = "Search manufacturer / model…"
	search.custom_minimum_size = Vector2(220, 0)
	search.clear_button_enabled = true
	filters.add_child(search)

	var maker_opt := OptionButton.new()
	filters.add_child(maker_opt)

	var cat_opt := OptionButton.new()
	cat_opt.add_item("All types")
	var cat_labels := {
		"moving_head": "Moving head", "wash": "Wash", "par": "Par / colour",
		"beam": "Beam", "strip": "Strip / bar", "blinder": "Blinder / effect",
		"generic": "Other",
	}
	var cat_keys: Array = []
	for c in Library.categories():
		cat_keys.append(c)
		cat_opt.add_item(cat_labels.get(c, String(c).capitalize()))
	filters.add_child(cat_opt)

	var pt_check := CheckBox.new()
	pt_check.text = "Pan/Tilt only"
	filters.add_child(pt_check)

	filters.add_child(_label("Max ch:"))
	var maxch_spin := SpinBox.new()
	maxch_spin.min_value = 0
	maxch_spin.max_value = 96
	maxch_spin.value = 0
	maxch_spin.tooltip_text = "0 = any width"
	filters.add_child(maxch_spin)

	# --- results | preview -----------------------------------------
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 430
	root.add_child(split)

	var results := ItemList.new()
	results.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	results.custom_minimum_size = Vector2(360, 0)
	results.allow_reselect = true
	split.add_child(results)

	var preview_scroll := ScrollContainer.new()
	preview_scroll.custom_minimum_size = Vector2(320, 0)
	preview_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(preview_scroll)

	var preview := VBoxContainer.new()
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview.add_theme_constant_override("separation", 6)
	preview_scroll.add_child(preview)

	# --- footer ----------------------------------------------------
	var footer := HBoxContainer.new()
	root.add_child(footer)
	var count_lbl := _label("")
	count_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	count_lbl.modulate = Color(1, 1, 1, 0.6)
	footer.add_child(count_lbl)
	var clearcache_btn := Button.new()
	clearcache_btn.text = "Clear cache"
	clearcache_btn.visible = false
	footer.add_child(clearcache_btn)
	var add_btn := Button.new()
	add_btn.text = "Add to Patch"
	add_btn.disabled = true
	footer.add_child(add_btn)
	var close_btn := Button.new()
	close_btn.text = "Close"
	footer.add_child(close_btn)

	var src := _label(Library.source_note())
	src.modulate = Color(1, 1, 1, 0.45)
	root.add_child(src)

	# --- state + behaviour ---------------------------------------
	# gdtf_login_prompt lives inside `state` (not a plain local) because
	# set_source below needs to call it before it's assigned further down —
	# a plain local Callable var is captured *by value* (empty) at the
	# point set_source's closure is created, same as GDScript's int-closure
	# gotcha; a Dictionary's contents are mutable-by-reference instead, so
	# reassigning state["gdtf_login_prompt"] later is visible to set_source.
	var state := {
		"sel_id": "", "profile": null, "gen": 0, "online": false, "gdtf": false,
		"gdtf_login_prompt": Callable(),
	}

	var fill_makers := func(online: bool, gdtf: bool) -> void:
		maker_opt.clear()
		maker_opt.add_item("All manufacturers")
		var list: PackedStringArray
		if gdtf:
			list = Library.gdtf_online_manufacturers()
		elif online:
			list = Library.online_manufacturers()
		else:
			list = Library.manufacturers()
		for m in list:
			maker_opt.add_item(m)

	var select := func(id: String) -> void:
		state["gen"] = int(state["gen"]) + 1
		var g: int = state["gen"]
		state["sel_id"] = id
		state["profile"] = null
		add_btn.disabled = true
		for c in preview.get_children():
			c.queue_free()
		if id == "":
			return
		var p: FixtureProfile = Library.resolve(id)
		if p == null:
			preview.add_child(_label("Downloading…"))
			p = await Library.get_profile(id)
			if g != int(state["gen"]):
				return
			for c in preview.get_children():
				c.queue_free()
		if p == null:
			var why := Library.gdtf_error() if id.begins_with("gdtf-") else Library.online_error()
			var err := _label("Couldn't load this fixture.\n%s" % why)
			err.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			preview.add_child(err)
			return
		state["profile"] = p
		add_btn.disabled = false
		_lib_render_preview(preview, Library.entry(id), p)

	var refresh := func() -> void:
		var mk := "" if maker_opt.selected <= 0 else maker_opt.get_item_text(maker_opt.selected)
		var rows: Array
		if state["gdtf"]:
			rows = Library.search_gdtf(search.text, mk)
		elif state["online"]:
			rows = Library.search_online(search.text, mk)
		else:
			var ct := "" if cat_opt.selected <= 0 else String(cat_keys[cat_opt.selected - 1])
			rows = Library.search(search.text, mk, ct, int(maxch_spin.value), pt_check.button_pressed)
		results.clear()
		var reselect := -1
		for i in range(rows.size()):
			var e: Dictionary = rows[i]
			var text: String
			if state["gdtf"]:
				text = "%s   ·   v%s" % [String(e["name"]), String(e.get("version", "?"))]
				if e.get("bundled", false):
					text += "   ·   bundled"
			elif state["online"]:
				text = String(e["name"])
				if e.get("bundled", false):
					text += "   ·   bundled"
			else:
				var seen_ch := {}
				var widths: Array = []
				for m in e.get("modes", []):
					var ch := int(m.get("ch", 0))
					if not seen_ch.has(ch):
						seen_ch[ch] = true
						widths.append(str(ch))
				text = "%s   ·   %s ch   ·   %s" % [
					e["name"], "/".join(widths), cat_labels.get(e.get("cat", ""), "")]
			results.add_item(text)
			results.set_item_metadata(i, e["id"])
			if e["id"] == state["sel_id"]:
				reselect = i
		if state["gdtf"]:
			count_lbl.text = "%d of %d GDTF-Share fixtures · %d cached · logged in as %s" % [
				rows.size(), Library.gdtf_online_count(), Library.cached_gdtf_count(), Library.gdtf_username()]
		elif state["online"]:
			count_lbl.text = "%d of %d OFL fixtures · %d cached" % [
				rows.size(), Library.online_count(), Library.cached_online_count()]
		else:
			count_lbl.text = "%d of %d fixtures" % [rows.size(), Library.count()]
		if reselect >= 0:
			results.select(reselect)
		else:
			select.call("")

	var set_source := func(idx: int) -> void:
		var online: bool = idx != 0
		var gdtf: bool = idx == 2
		state["online"] = online
		state["gdtf"] = gdtf
		state["sel_id"] = ""
		search.text = ""
		cat_opt.disabled = online
		pt_check.disabled = online
		maxch_spin.editable = not online
		clearcache_btn.visible = online
		fill_makers.call(online, gdtf)
		if gdtf and not Library.gdtf_logged_in():
			results.clear()
			results.add_item("Log in to GDTF-Share to browse…")
			results.set_item_disabled(0, true)
			count_lbl.text = ""
			(state["gdtf_login_prompt"] as Callable).call()
			return
		if gdtf and not Library.gdtf_ready():
			results.clear()
			results.add_item("Fetching the GDTF-Share catalogue…")
			results.set_item_disabled(0, true)
			count_lbl.text = "contacting GDTF-Share…"
			source_opt.disabled = true
			var got_gdtf: bool = await Library.refresh_gdtf()
			source_opt.disabled = false
			if not got_gdtf:
				results.clear()
				results.add_item("Couldn't reach GDTF-Share: %s" % Library.gdtf_error())
				results.set_item_disabled(0, true)
				count_lbl.text = ""
				return
		elif online and not gdtf and not Library.online_ready():
			results.clear()
			results.add_item("Fetching the OFL catalogue from GitHub…")
			results.set_item_disabled(0, true)
			count_lbl.text = "contacting GitHub…"
			source_opt.disabled = true
			var got: bool = await Library.refresh_online()
			source_opt.disabled = false
			if not got:
				results.clear()
				results.add_item("Couldn't reach OFL: %s" % Library.online_error())
				results.set_item_disabled(0, true)
				count_lbl.text = ""
				return
		refresh.call()

	## A small popup asking for GDTF-Share credentials. Used only for the
	## login.php request (see fixture_library.gd's gdtf_login()) — never
	## written to disk, gone on Cancel/close, gone for good when the app
	## quits (the session cookie it produces isn't persisted either).
	state["gdtf_login_prompt"] = func() -> void:
		var lwin := Window.new()
		lwin.title = "Log in to GDTF-Share"
		# Auto-size to content instead of a guessed fixed height (which cut
		# the buttons off — theme/DPI-dependent control heights made a
		# hand-picked size unreliable). The hint label below gets an
		# explicit width cap so it wraps to a known number of lines instead
		# of reporting its whole one-line sentence as the "minimum" width.
		lwin.wrap_controls = true
		win.add_child(lwin)

		var lmargin := MarginContainer.new()
		lmargin.set_anchors_preset(Control.PRESET_FULL_RECT)
		for side in ["left", "right", "top", "bottom"]:
			lmargin.add_theme_constant_override("margin_" + side, 12)
		lwin.add_child(lmargin)

		var lvbox := VBoxContainer.new()
		lvbox.add_theme_constant_override("separation", 8)
		lmargin.add_child(lvbox)

		var hint := _label("Your gdtf-share.com account. Used only for this session — never saved to disk; log in again next launch.")
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.custom_minimum_size = Vector2(320, 0)
		hint.modulate = Color(1, 1, 1, 0.7)
		lvbox.add_child(hint)

		var user_edit := LineEdit.new()
		user_edit.placeholder_text = "Username"
		user_edit.custom_minimum_size = Vector2(320, 0)
		lvbox.add_child(user_edit)
		var pass_edit := LineEdit.new()
		pass_edit.placeholder_text = "Password"
		pass_edit.secret = true
		lvbox.add_child(pass_edit)
		var err_lbl := _label("")
		err_lbl.modulate = Color(1, 0.55, 0.55)
		err_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lvbox.add_child(err_lbl)

		var lbtns := HBoxContainer.new()
		lvbox.add_child(lbtns)
		var login_btn := Button.new()
		login_btn.text = "Log In"
		lbtns.add_child(login_btn)
		var cancel_btn := Button.new()
		cancel_btn.text = "Cancel"
		lbtns.add_child(cancel_btn)

		var back_to_bundled := func() -> void:
			lwin.queue_free()
			source_opt.select(0)
			set_source.call(0)

		var do_login := func() -> void:
			login_btn.disabled = true
			err_lbl.text = "Logging in…"
			var ok: bool = await Library.gdtf_login(user_edit.text, pass_edit.text)
			pass_edit.text = ""
			if not ok:
				err_lbl.text = Library.gdtf_error()
				login_btn.disabled = false
				return
			lwin.queue_free()
			set_source.call(2)

		login_btn.pressed.connect(do_login)
		pass_edit.text_submitted.connect(func(_t): do_login.call())
		cancel_btn.pressed.connect(back_to_bundled)
		lwin.close_requested.connect(back_to_bundled)
		lwin.popup_centered()
		user_edit.grab_focus()

	source_opt.item_selected.connect(set_source)
	search.text_changed.connect(func(_t): refresh.call())
	maker_opt.item_selected.connect(func(_i): refresh.call())
	cat_opt.item_selected.connect(func(_i): refresh.call())
	pt_check.toggled.connect(func(_p): refresh.call())
	maxch_spin.value_changed.connect(func(_v): refresh.call())
	results.item_selected.connect(func(i: int): select.call(String(results.get_item_metadata(i))))
	results.item_activated.connect(func(_i: int): add_btn.pressed.emit())
	clearcache_btn.pressed.connect(func():
		if state["gdtf"]:
			Library.clear_gdtf_cache()
		else:
			Library.clear_online_cache()
		refresh.call())

	add_btn.pressed.connect(func():
		_lib_commit_profile(state["profile"])
		if state["profile"] != null:
			win.queue_free()
	)
	close_btn.pressed.connect(func(): win.queue_free())
	win.close_requested.connect(func(): win.queue_free())

	fill_makers.call(false, false)
	refresh.call()
	search.grab_focus()
	win.popup_centered()


# ---------------------------------------------------------------- MVR --

func _save_imported_profile(prof: FixtureProfile, mbytes: Dictionary) -> FixtureProfile:
	if _id_in_use(prof.id):
		prof.id = _unique_profile_id(_safe_profile_id(prof.id))
	if not mbytes.is_empty() and prof.geometry.has("tree"):
		var mdir := MODELS_DIR + "/" + prof.id
		DirAccess.make_dir_recursive_absolute(mdir)
		var mmap := {}
		for name in mbytes:
			var fn := _safe_profile_id(name) + ".glb"
			var mf := FileAccess.open(mdir + "/" + fn, FileAccess.WRITE)
			if mf:
				mf.store_buffer(mbytes[name]); mf.close()
				mmap[name] = fn
		prof.geometry["models"] = mmap
		prof.geometry["models_dir"] = prof.id
	var f := FileAccess.open(PROFILES_DIR + "/%s.json" % prof.id, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(prof.to_dict())); f.close()
	available_profiles.append(prof)
	return prof


func _do_mvr_import(path: String) -> String:
	var res := MvrIO.import_path(path)
	if res.has("error"):
		return "MVR import failed: " + res["error"]
	var fx: Array = res["fixtures"]
	if fx.is_empty():
		return "MVR had no usable fixtures."

	var max_u := 0
	for e in fx:
		max_u = maxi(max_u, int(e["universe"]))
	ArtNet.stop_fade()
	ArtNet.set_universe_count(clampi(max_u + 1, 1, ArtNet.MAX_UNIVERSES))
	_sync_tabs_to_universes()

	# register each distinct GDTF profile once
	var by_iid := {}
	for e in fx:
		by_iid[e["profile"].get_instance_id()] = e["profile"]
	for prof in by_iid.values():
		if _profile_index_by_id(prof.id) == -1:
			_save_imported_profile(prof, res.get("model_bytes", {}).get(prof.id, {}))

	var count := 0
	for e in fx:
		var u := int(e["universe"])
		if u < 0 or u >= _panels.size():
			continue
		_panels[u].add_patched(e["profile"], int(e["start"]), int(e["mode"]),
			String(e["name"]), e["pos"], e["rot"], false)
		count += 1
	_refresh_all_profile_options(false)
	for tr in res.get("trusses", []):
		viz_panel.spawn_truss_at(tr["pos"], float(tr.get("size", 3.0)))
	_on_patch_changed()

	var w: Array = res.get("warnings", [])
	if not w.is_empty():
		push_warning("MVR import notes:\n- " + "\n- ".join(w))
	return "Imported %d fixtures, %d trusses from %s%s" % [
		count, res.get("trusses", []).size(), path.get_file(),
		"  (%d notes — see log)" % w.size() if not w.is_empty() else ""]


func _do_mvr_export(path: String) -> String:
	return MvrIO.export_path(path, _panels, viz_panel.to_dict())


## Confirm, then delete a custom profile's file (reverting to the built-in
## of the same id if one exists). A pure built-in can't be deleted.
func _delete_profile(p: FixtureProfile) -> void:
	if p == null:
		return
	if _builtin_ids.has(p.id) and not _profile_has_file(p):
		status_label.text = "'%s' is a built-in profile and can't be deleted." % p.model
		return

	var reverts := _builtin_ids.has(p.id)
	var dlg := ConfirmationDialog.new()
	dlg.title = "Delete Profile"
	if reverts:
		dlg.dialog_text = "Reset \"%s\" to its built-in default?\n\nYour edited copy (%s.json) will be removed." % [p.model, p.id]
		dlg.ok_button_text = "Reset"
	else:
		dlg.dialog_text = "Delete the profile \"%s\"?\n\n%s.json will be removed. This can't be undone." % [p.model, p.id]
		dlg.ok_button_text = "Delete"
	add_child(dlg)
	dlg.confirmed.connect(func():
		_do_delete_profile(p)
		dlg.queue_free()
	)
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()


func _do_delete_profile(p: FixtureProfile) -> void:
	var path := _profile_file_path(p)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

	var idx := _profile_index_by_id(p.id)
	if _builtin_ids.has(p.id):
		# restore the code default in the same slot
		var restored: FixtureProfile = null
		for b in FixtureProfile.built_in_profiles():
			if b.id == p.id:
				restored = b
				break
		if idx != -1 and restored:
			available_profiles[idx] = restored
		status_label.text = "Reset '%s' to its built-in default." % p.model
	else:
		if idx != -1:
			available_profiles.remove_at(idx)
		status_label.text = "Deleted profile '%s'." % p.model

	_refresh_all_profile_options(false)


func _refresh_all_profile_options(select_new: bool) -> void:
	for p in _panels:
		p.populate_profile_option()
	if select_new and not _panels.is_empty():
		var idx: int = clampi(universe_tabs.current_tab, 0, _panels.size() - 1)
		var active := _panels[idx]
		active.profile_option.selected = available_profiles.size() - 1
		active.populate_mode_option()


# ------------------------------------------------------------ SHOW FILES --

## A show file is everything about the rig and how it's played: every
## universe's connection settings and fixture patch (each fixture's
## profile, address, mode, and position / rotation in the visualizer),
## the fixtures' live levels and virtual dimmers, the cue list, chases,
## effects, fixture groups, named positions, sound reactions, triggers, run mode
## and the visualizer's stage. JSON; saved to any file (SHOW_EXT), or the
## default user:// one. The music tracks' lighting timelines go in a
## folder beside it (TimelineStore: "<show>.timelines/"), named in the
## show's "timelines".
const SHOW_EXT := "slight"
const SHOW_FORMAT := "sLight show"
const SHOW_VERSION := 1

## The show file Save Show writes to (the last one saved / loaded); ""
## for a new show not saved yet (Save Show asks where, like Save As).
var show_path := SHOW_PATH
## Where the current show file's path is remembered between runs, so it's
## reopened at the next start (restore_last_show()).
var last_show_store := "user://last_show.json"
## Autosave and crash recovery (its files can be pointed elsewhere before
## this is added to the tree, as tests do).
var autosave := Autosave.new()
var _autosave_timer: Timer


## The show file remembered from last time ("" if none).
func remembered_show() -> String:
	if not FileAccess.file_exists(last_show_store):
		return ""
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(last_show_store))
	return String(parsed.get("path", "")) if parsed is Dictionary else ""


func _remember_show(path: String) -> void:
	var f := FileAccess.open(last_show_store, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"path": path}))
		f.close()


## At startup: reopen the remembered show file, if there is one. If it's
## gone or won't load, the app starts empty and says why.
func restore_last_show() -> void:
	var path := remembered_show()
	if path == "":
		return
	var err := load_show_from(path)
	if err != "":
		status_label.text = "Couldn't reopen the last show: " + err
		return
	status_label.text = "Reopened the last show, %s." % path.get_file()


func show_dict() -> Dictionary:
	var data := {
		"format": SHOW_FORMAT,
		"version": SHOW_VERSION,
		"universes": [],
		"live": [],
		"run_mode": run_mode,
		"cues": cue_panel.to_dict(),
		"chases": chase_panel.to_dict(),
		"effects": fx_panel.to_dict(),
		"sound": sound_panel.to_dict(),
		"triggers": Triggers.to_dict(),
		"groups": _groups_to_dict(),
		"positions": positions.to_dict(),
		"live_flash": flash.to_dict(),
		"faders": faders.to_dict(),
		"viz": viz_panel.to_dict(),
		"sacn_cid": Marshalls.raw_to_base64(ArtNet.sacn_cid),
	}
	var store := music_panel.timeline().timeline_store if music_panel else null
	if store != null:
		data["timelines"] = store.dir.get_file()
	for p in _panels:
		data["universes"].append(p.patch_dict())
		data["live"].append(p.live_dict())
	return data


## Write the show to `path`. Returns "" or what went wrong. The music
## timelines follow: to a new file, the timelines folder is copied beside
## it; either way the open song's unsaved timelines are saved too.
func save_show_to(path: String) -> String:
	if music_panel:
		var tl := music_panel.timeline()
		var dir := TimelineStore.folder_for_show(path)
		if tl.timeline_store == null:
			tl.set_timeline_store(TimelineStore.new(dir), false)
		elif tl.timeline_store.dir != dir:
			tl.set_timeline_store(tl.timeline_store.copy_to(dir), false)
		tl.flush()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Couldn't write %s (%s)." % [path.get_file(), error_string(FileAccess.get_open_error())]
	var data := show_dict()
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	show_path = path
	_remember_show(path)
	autosave.mark_saved(data)
	return ""


## Read the show at `path` and replace the current one with it. Returns
## "" or what went wrong (the current show is left alone then).
func load_show_from(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "No show file at %s." % path
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "Couldn't read %s (%s)." % [path.get_file(), error_string(FileAccess.get_open_error())]
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary and parsed.has("universes")) and not parsed is Array:
		return "%s isn't a show file." % path.get_file()
	if parsed is Dictionary and int(parsed.get("version", 1)) > SHOW_VERSION:
		return "%s was saved by a newer sLight." % path.get_file()
	if music_panel:
		music_panel.timeline().flush()        # the outgoing show's open song
	apply_show_dict(parsed)
	_open_timelines_for(path, parsed)
	show_path = path
	_remember_show(path)
	autosave.mark_saved(show_dict())
	return ""


## Point DJ Edit Mode at the timelines folder of the show file `path`
## (the one its `parsed` contents name, else the default beside it); none
## for "" (a show never saved).
func _open_timelines_for(path: String, parsed) -> void:
	if not music_panel:
		return
	if path == "":
		music_panel.timeline().set_timeline_store(null)
		return
	var folder := TimelineStore.folder_for_show(path)
	var named = parsed.get("timelines") if parsed is Dictionary else null
	if named is String and named != "":
		folder = path.get_base_dir().path_join(named)
	music_panel.timeline().set_timeline_store(TimelineStore.new(folder))


## Replace the current show with a parsed show file (a Dictionary, or a
## legacy single-universe patch: a bare fixtures array).
func apply_show_dict(parsed) -> void:
	var uni_list: Array = parsed["universes"] if parsed is Dictionary else [{"fixtures": parsed}]

	ArtNet.stop_fade()
	Fx.stop_all()

	if parsed is Dictionary and parsed.has("sacn_cid"):
		var cid := Marshalls.base64_to_raw(String(parsed["sacn_cid"]))
		if cid.size() == 16:
			ArtNet.sacn_cid = cid

	var n: int = clampi(uni_list.size(), 1, ArtNet.MAX_UNIVERSES)
	ArtNet.set_universe_count(n)
	_sync_tabs_to_universes()
	for i in range(n):
		_panels[i].apply_patch_dict(uni_list[i] if i < uni_list.size() else {})

	var doc: Dictionary = parsed if parsed is Dictionary else {}
	# The fixtures' live levels (older files have none: the patch's
	# defaults stand).
	var live: Array = doc.get("live", [])
	for i in range(mini(live.size(), n)):
		if live[i] is Dictionary:
			_panels[i].apply_live_dict(live[i])
	cue_panel.from_dict(doc.get("cues", {}))
	chase_panel.from_dict(doc.get("chases", {}))
	_groups_from_dict(doc.get("groups", {}))   # fills the shared `groups`
	groups_panel.sync_to_patch()
	var pos_doc = doc.get("positions", {})
	positions.from_dict(pos_doc if pos_doc is Dictionary else {})
	fx_panel.from_dict(doc.get("effects", {}))
	fx_panel.refresh_group_options()
	sound_panel.from_dict(doc.get("sound", {}))
	sound_panel.refresh_group_options()
	Triggers.from_dict(doc.get("triggers", {}))
	var fader_doc = doc.get("faders", {})
	faders.from_dict(fader_doc if fader_doc is Dictionary else {})   # after the cues, chases and groups
	var flash_doc = doc.get("live_flash", {})
	flash.from_dict(flash_doc if flash_doc is Dictionary else {})
	perform_panel.sync_flash()
	_set_run_mode(int(doc.get("run_mode", 0)))
	_on_patch_changed()                       # groups, visualizer, DJ Edit Mode timelines
	viz_panel.from_dict(doc.get("viz", {}))


# --------------------------------------------------------------- AUTOSAVE --

## At startup (as the app): offer the autosaved show if the last run
## didn't close properly, then autosave every Autosave.INTERVAL seconds.
func _start_autosave() -> void:
	var snap := autosave.begin()
	if not snap.is_empty() and _worth_recovering(snap):
		_offer_recovery(snap)
	_autosave_timer = Timer.new()
	_autosave_timer.wait_time = Autosave.INTERVAL
	_autosave_timer.timeout.connect(autosave_now)
	add_child(_autosave_timer)
	_autosave_timer.start()


## Autosave now: the open song's timeline edits to its show's timelines
## (as leaving DJ Edit Mode would), and a snapshot of the show if it's
## changed since it was last saved. Returns whether a snapshot was taken.
func autosave_now() -> bool:
	if music_panel:
		music_panel.timeline().flush()
	return autosave.tick(show_dict(), show_path)


## The snapshot a run that didn't close properly left ({} if it was clean,
## left none, or the snapshot is just the show as it now stands) — what
## the startup offers to restore.
func recovery_offer() -> Dictionary:
	var snap := autosave.read()
	return snap if not snap.is_empty() and _worth_recovering(snap) else {}


## Whether a snapshot holds anything the show as it now stands doesn't.
## Both are compared as they'd read back from JSON (numbers as floats).
func _worth_recovering(snap: Dictionary) -> bool:
	var now = JSON.parse_string(JSON.stringify(show_dict()))
	return JSON.stringify(snap["show"]) != JSON.stringify(now)


func _offer_recovery(snap: Dictionary) -> void:
	var path := String(snap.get("show_path", ""))
	var dlg := ConfirmationDialog.new()
	dlg.title = "Restore Autosaved Show"
	dlg.dialog_text = "sLight didn't close properly last time.\n\nRestore %s as it was autosaved at %s? Its changes since it was last saved would otherwise be lost." % [
		path.get_file() if path != "" else "the unsaved show", Autosave.when(snap)]
	dlg.ok_button_text = "Restore"
	dlg.cancel_button_text = "Discard"
	add_child(dlg)
	dlg.confirmed.connect(func():
		dlg.queue_free()
		restore_autosave(snap))
	dlg.canceled.connect(func():
		dlg.queue_free()
		autosave.discard()
		status_label.text = "Autosaved show discarded.")
	dlg.popup_centered()


## Replace the current show with an autosave snapshot, for the show file it
## belongs to (Save Show saves it there). Left unsaved. Returns "" or what
## went wrong.
func restore_autosave(snap: Dictionary) -> String:
	var doc = snap.get("show")
	if not (doc is Dictionary and doc.has("universes")):
		return "The autosave isn't a show."
	var path := String(snap.get("show_path", ""))
	if music_panel:
		music_panel.timeline().flush()        # the outgoing show's open song
	apply_show_dict(doc)
	_open_timelines_for(path, doc)
	show_path = path
	if path != "":
		_remember_show(path)
	status_label.text = "Restored %s as it was autosaved at %s — not saved yet." % [
		path.get_file() if path != "" else "the unsaved show", Autosave.when(snap)]
	return ""


## New Show (Ctrl+N): after a confirmation, start an empty show.
func _on_new_show() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "New Show"
	dlg.dialog_text = "Start a new, empty show?\n\nAnything in the current show that hasn't been saved will be lost (the open song's timelines are saved)."
	dlg.ok_button_text = "New Show"
	add_child(dlg)
	dlg.confirmed.connect(func():
		dlg.queue_free()
		new_show())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()


## Replace the current show with an empty one: no fixtures (one
## universe, keeping universe 1's output settings — those are this
## machine's), everything dark, no cues, chases, effects, groups, sound
## reactions or triggers, the visualizer's stage reset, and no
## music timelines. It's untitled until saved (show_path ""); the last
## show stays the one reopened at start until then.
func new_show() -> void:
	if music_panel:
		music_panel.timeline().flush()        # the outgoing show's open song
	var conn: Dictionary = _panels[0].patch_dict()
	conn["fixtures"] = []
	apply_show_dict({"universes": [conn], "live": [{}]})
	if music_panel:
		music_panel.timeline().set_timeline_store(null)
	show_path = ""
	autosave.mark_saved(show_dict())          # nothing in it worth an autosave yet
	status_label.text = "New show (not saved yet)."


## Save Show: to the current show file.
func _on_save_show() -> void:
	if show_path == "":
		_on_save_show_as()              # a new show: ask where
		return
	var err := save_show_to(show_path)
	if err != "":
		status_label.text = "Show save failed: " + err
		return
	status_label.text = "Show saved to %s (%d universes, %d cues, %d chases, %d effects)." % [
		show_path.get_file(), _panels.size(), cue_panel.cues.size(), Fx.chases.size(), Fx.effects.size()]


## Save Show As…: pick the file, then save to it (it becomes the current one).
func _on_save_show_as() -> void:
	_show_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, "Save Show As", func(path: String):
		if path.get_extension() == "":
			path += "." + SHOW_EXT
		show_path = path
		_on_save_show()
	)


## Load Show…: pick a show file and load it.
func _on_load_show() -> void:
	_show_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, "Load Show", func(path: String):
		var err := load_show_from(path)
		if err != "":
			status_label.text = "Show load failed: " + err
			return
		status_label.text = "Show loaded from %s (%d universes, %d cues, %d chases, %d effects, %d groups)." % [
			path.get_file(), _panels.size(), cue_panel.cues.size(), Fx.chases.size(), Fx.effects.size(), groups.size()]
	)


func _show_file_dialog(mode: FileDialog.FileMode, title: String, on_pick: Callable) -> void:
	var fd := FileDialog.new()
	fd.mode_overrides_title = false     # keep "Save Show As" / "Load Show"
	fd.file_mode = mode
	fd.title = title
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.add_filter("*." + SHOW_EXT, "sLight show")
	fd.add_filter("*.json", "Show (JSON)")
	fd.use_native_dialog = true
	RecentDirs.track(fd, "show")
	if show_path != SHOW_PATH and show_path != "":
		fd.current_file = show_path.get_file()
	add_child(fd)
	fd.file_selected.connect(func(path: String):
		fd.queue_free()
		on_pick.call(path)
	)
	fd.canceled.connect(func(): fd.queue_free())
	fd.popup_centered_ratio(0.6)


# ---------------------------------------------------------------- PRESETS --

## A preset is every universe's live DMX buffer (non-zero channels only),
## independent of which fixtures are patched.
func _on_save_preset() -> void:
	var data := {"universes": []}
	for p in _panels:
		data["universes"].append(p.buffer_dict())

	var f := FileAccess.open(PRESET_PATH, FileAccess.WRITE)
	if f == null:
		status_label.text = "Preset save failed."
		return
	f.store_string(JSON.stringify(data))
	f.close()
	status_label.text = "Preset saved (%d universes)." % _panels.size()


func _on_load_preset() -> void:
	if not FileAccess.file_exists(PRESET_PATH):
		status_label.text = "No preset found."
		return

	var f := FileAccess.open(PRESET_PATH, FileAccess.READ)
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()

	var uni_list: Array
	if parsed is Dictionary and parsed.has("universes"):
		uni_list = parsed["universes"]
	elif parsed is Dictionary:
		# Legacy flat {channel: value} preset -> universe 0.
		uni_list = [{"channels": parsed}]
	else:
		status_label.text = "Preset file corrupt."
		return

	ArtNet.stop_fade()
	Fx.stop_all()
	chase_panel.sync_ui()
	fx_panel.sync_ui()
	# Grow (never shrink) so a preset wider than the current show still loads.
	var n: int = clampi(uni_list.size(), 1, ArtNet.MAX_UNIVERSES)
	ArtNet.set_universe_count(maxi(ArtNet.universe_count(), n))
	_sync_tabs_to_universes()
	for i in range(min(uni_list.size(), _panels.size())):
		_panels[i].apply_buffer_dict(uni_list[i])
	status_label.text = "Preset loaded (fixture controls won't move, but the output updates)."


# ----------------------------------------------------- NEW PROFILE DIALOG --

## The profile editor's Category choices: [physical.category, label].
## "" lets the visualizer guess from the channel roles.
const PROFILE_CATEGORIES := [
	["", "Auto (from channels)"], ["moving_head", "Moving head"], ["wash", "Wash"],
	["par", "Par"], ["beam", "Beam"], ["strip", "Strip / bar"], ["blinder", "Blinder / strobe"],
	["generic", "Generic"],
]


## physical.heads as the editor's text: one "x, y, z, rx, ry, rz" line per
## head (rotation left off when it's all zero).
func _format_heads(heads: Array) -> String:
	var lines: PackedStringArray = []
	for h in heads:
		var vals: Array = h.slice(0, 3) if h.size() < 6 or (h[3] == 0.0 and h[4] == 0.0 and h[5] == 0.0) else h
		lines.append(", ".join(vals.map(func(v): return String.num(float(v), 3))))
	return "\n".join(lines)


## Inverse of _format_heads: an Array of heads, or a String saying which
## line is wrong.
func _parse_heads_text(text: String):
	var heads: Array = []
	var n := 0
	for line in text.split("\n"):
		n += 1
		if line.strip_edges() == "":
			continue
		var parts := line.replace(";", ",").split(",", false)
		var vals: Array = []
		for p in parts:
			if not p.strip_edges().is_valid_float():
				return "Head line %d: \"%s\" isn't a number." % [n, p.strip_edges()]
			vals.append(p.strip_edges().to_float())
		if vals.size() != 3 and vals.size() != 6:
			return "Head line %d needs x, y, z (and optionally rot x, y, z) — it has %d value(s)." % [n, vals.size()]
		heads.append(vals)
	return heads


## Turn a "0-9:Open, 10-19:Red:#f00" text field into a ranges array.
## Each entry is "lo-hi", optionally ":label", optionally ":colour"
## (HTML hex or a named colour, drawn as a swatch in the dropdown).
func _parse_ranges_text(text: String) -> Array:
	var out: Array = []
	for part in text.split(",", false):
		var p: String = part.strip_edges()
		if p == "":
			continue
		var bits := p.split(":")
		var span: String = bits[0].strip_edges()
		var label := bits[1].strip_edges() if bits.size() > 1 else ""
		var color := bits[2].strip_edges() if bits.size() > 2 else ""
		var dash := span.find("-")
		if dash == -1:
			continue
		out.append({
			"lo": int(span.substr(0, dash).strip_edges()),
			"hi": int(span.substr(dash + 1).strip_edges()),
			"label": label,
			"color": color,
		})
	return out


## Inverse of _parse_ranges_text, for re-showing a channel's ranges.
func _format_ranges(arr: Array) -> String:
	var parts: Array = []
	for r in arr:
		var s := "%d-%d" % [int(r["lo"]), int(r["hi"])]
		var lbl := String(r.get("label", ""))
		var col := String(r.get("color", ""))
		if lbl != "" or col != "":
			s += ":" + lbl
		if col != "":
			s += ":" + col
		parts.append(s)
	var joined := ""
	for i in range(parts.size()):
		joined += parts[i]
		if i < parts.size() - 1:
			joined += ", "
	return joined


## Copy `image` (and any missing `color`) from `originals` onto same-label
## slots in `edited` — the ranges text field can't carry base64 gobo art,
## so this keeps it across an edit as long as the slot name is unchanged.
func _carry_slot_images(edited: Array, originals: Array) -> void:
	if originals.is_empty():
		return
	for slot in edited:
		if String(slot.get("image", "")) != "":
			continue
		var want := String(slot.get("label", "")).strip_edges().to_lower()
		for orig in originals:
			if String(orig.get("image", "")) == "":
				continue
			if String(orig.get("label", "")).strip_edges().to_lower() == want:
				slot["image"] = orig["image"]
				if String(slot.get("color", "")) == "":
					slot["color"] = orig.get("color", "")
				break


## Popup for creating or editing a fixture profile: a name, one or more
## DMX modes, and per mode a list of channels — each with a label, role,
## default / min / max, a 16-bit "fine" flag, and optional named value
## ranges. Saves to user://fixture_profiles/<id>.json.
##
## Pass `existing` to edit it in place (its id and file stay put; editing
## a built-in writes an editable copy under the same id that shadows the
## built-in). Pass null to create a new profile.
func _open_profile_dialog(existing: FixtureProfile = null) -> void:
	var editing := existing != null

	var win := Window.new()
	win.title = "Edit Fixture Profile" if editing else "New Fixture Profile"
	# Wide enough for a whole channel row (name, role, d/min/max, 16-bit,
	# ranges, X) — kept inside the main window (subwindows are embedded).
	var usable := get_tree().root.size
	win.size = Vector2i(mini(1060, usable.x - 40), mini(640, usable.y - 60))
	win.min_size = Vector2i(480, 360)
	add_child(win)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	win.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var name_row := HFlowContainer.new()
	name_row.add_child(_label("Manufacturer:"))
	var maker_edit := LineEdit.new()
	maker_edit.text = existing.manufacturer if editing else ""
	maker_edit.placeholder_text = "Generic"
	maker_edit.custom_minimum_size = Vector2(160, 0)
	name_row.add_child(maker_edit)
	name_row.add_child(_label("Model:"))
	var name_edit := LineEdit.new()
	name_edit.text = existing.model if editing else "Custom Fixture"
	name_edit.custom_minimum_size = Vector2(220, 0)
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(name_edit)
	vbox.add_child(name_row)

	if editing and _builtin_ids.has(existing.id) and not _profile_has_file(existing):
		var note := _label("Editing a built-in — Save keeps this as your own copy.")
		note.modulate = Color(1, 1, 1, 0.6)
		vbox.add_child(note)

	# --- physical -------------------------------------------------------
	# The visualizer's and DMX render's hints (FixtureProfile.physical).
	var phys: Dictionary = existing.physical if editing else FixtureProfile.PHYSICAL_DEFAULT
	var phys_row := HFlowContainer.new()
	phys_row.add_theme_constant_override("h_separation", 6)
	phys_row.add_theme_constant_override("v_separation", 4)
	phys_row.add_child(_label("Category:"))
	var cat_opt := OptionButton.new()
	for c in PROFILE_CATEGORIES:
		cat_opt.add_item(c[1])
		if c[0] == String(phys.get("category", "")):
			cat_opt.selected = cat_opt.item_count - 1
	phys_row.add_child(cat_opt)
	var make_phys_spin := func(label: String, v: float, lo: float, hi: float, step: float, tip: String) -> SpinBox:
		phys_row.add_child(_label(label))
		var s := SpinBox.new()
		s.min_value = lo
		s.max_value = hi
		s.step = step
		s.value = v
		s.suffix = "°"
		s.tooltip_text = tip
		phys_row.add_child(s)
		return s
	var beam_spin: SpinBox = make_phys_spin.call("Beam:", float(phys.get("beam_deg", 14.0)), 1.0, 120.0, 0.5,
		"Beam angle")
	var pan_spin: SpinBox = make_phys_spin.call("Pan range:", float(phys.get("pan_range", 540.0)), 0.0, 1080.0, 1.0,
		"Pan travel across the whole DMX range")
	var tilt_spin: SpinBox = make_phys_spin.call("Tilt range:", float(phys.get("tilt_range", 270.0)), 0.0, 540.0, 1.0,
		"Tilt travel across the whole DMX range")
	vbox.add_child(phys_row)
	if editing and not existing.geometry.is_empty():
		var geo_note := _label("The imported 3D model sets the beam angle in the visualizer.")
		geo_note.modulate = Color(1, 1, 1, 0.6)
		vbox.add_child(geo_note)

	# Multi-head fixtures (LED bars, spiders): one line per RGB head.
	var heads_edit := TextEdit.new()
	heads_edit.placeholder_text = "Head positions, one line per RGB head: x, y, z metres [, rot x, y, z degrees]  —  blank = single head / evenly spread"
	heads_edit.custom_minimum_size = Vector2(0, 64)
	heads_edit.text = _format_heads(phys.get("heads", []))
	vbox.add_child(heads_edit)

	# --- mode bar -------------------------------------------------------
	# Channel edits live in modes_data[cur.i]; the on-screen rows
	# are flushed back into it whenever the mode changes or on Save.
	var modes_data: Array = []
	if editing:
		for m in existing.modes:
			modes_data.append({
				"name": String(m.get("name", "Mode")),
				"channels": (m.get("channels", []) as Array).duplicate(true),
			})
	if modes_data.is_empty():
		modes_data = [{"name": "Default", "channels": []}]
	# Held in a Dictionary, not a bare int: GDScript lambdas capture locals
	# by value, so the several closures below must share one container to
	# all see the current mode index.
	var cur := {"i": 0}

	var mode_row := HFlowContainer.new()
	mode_row.add_theme_constant_override("h_separation", 6)
	mode_row.add_theme_constant_override("v_separation", 4)
	mode_row.add_child(_label("Mode:"))
	var mode_sel := OptionButton.new()
	mode_sel.custom_minimum_size = Vector2(120, 0)
	mode_row.add_child(mode_sel)
	var mode_name_edit := LineEdit.new()
	mode_name_edit.custom_minimum_size = Vector2(140, 0)
	mode_name_edit.text = String(modes_data[0]["name"])
	mode_row.add_child(mode_name_edit)
	var add_mode_btn := Button.new()
	add_mode_btn.text = "Add Mode"
	mode_row.add_child(add_mode_btn)
	var dup_mode_btn := Button.new()
	dup_mode_btn.text = "Duplicate Mode"
	mode_row.add_child(dup_mode_btn)
	var del_mode_btn := Button.new()
	del_mode_btn.text = "Delete Mode"
	mode_row.add_child(del_mode_btn)
	vbox.add_child(mode_row)

	var hint := _label("Ranges: \"0-9:Open, 10-19:Red:#f00\"  (label + optional colour; blank = plain slider)")
	hint.modulate = Color(1, 1, 1, 0.6)
	vbox.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var channels_box := VBoxContainer.new()
	channels_box.add_theme_constant_override("separation", 4)
	channels_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(channels_box)

	var channel_rows: Array = []

	var make_spin := func(v: int) -> SpinBox:
		var s := SpinBox.new()
		s.min_value = 0
		s.max_value = 255
		s.value = v
		s.custom_minimum_size = Vector2(56, 0)
		return s

	var add_channel_row: Callable
	var read_rows_into: Callable
	var build_rows_from: Callable
	var refresh_mode_sel: Callable
	var switch_mode: Callable
	# add_channel_row itself, for the rows' Duplicate buttons (a lambda
	# can't see its own variable — captured empty — so it's passed here).
	var row_fns := {}

	# A channel row's fields as the profile's channel dictionary.
	var row_to_dict := func(entry: Dictionary) -> Dictionary:
		var role_idx: int = entry["role_option"].selected
		var new_ranges := _parse_ranges_text(entry["ranges_edit"].text)
		_carry_slot_images(new_ranges, entry.get("orig_ranges", []))
		return {
			"name": entry["name_edit"].text,
			"role": FixtureProfile.ROLES[role_idx] if role_idx >= 0 else "GENERIC",
			"default": int(entry["def_spin"].value),
			"min": int(entry["min_spin"].value),
			"max": int(entry["max_spin"].value),
			"fine": entry["fine_check"].button_pressed,
			"ranges": new_ranges,
		}

	add_channel_row = func(data: Dictionary = {}):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)

		var handle := Label.new()
		handle.text = "≡"
		handle.tooltip_text = "Drag to reorder"
		handle.mouse_filter = Control.MOUSE_FILTER_STOP
		handle.mouse_default_cursor_shape = Control.CURSOR_VSIZE
		row.add_child(handle)

		var ch_name := LineEdit.new()
		ch_name.placeholder_text = "Channel name"
		ch_name.text = String(data.get("name", "Ch %d" % (channel_rows.size() + 1)))
		ch_name.custom_minimum_size = Vector2(110, 0)
		row.add_child(ch_name)

		var role_opt := OptionButton.new()
		for r in FixtureProfile.ROLES:
			role_opt.add_item(r)
		var role_idx := FixtureProfile.ROLES.find(String(data.get("role", "GENERIC")))
		role_opt.selected = role_idx if role_idx != -1 else FixtureProfile.ROLES.size() - 1
		row.add_child(role_opt)

		row.add_child(_label("d"))
		var def_spin: SpinBox = make_spin.call(int(data.get("default", 0)))
		row.add_child(def_spin)
		row.add_child(_label("min"))
		var min_spin: SpinBox = make_spin.call(int(data.get("min", 0)))
		row.add_child(min_spin)
		row.add_child(_label("max"))
		var max_spin: SpinBox = make_spin.call(int(data.get("max", 255)))
		row.add_child(max_spin)

		var fine_check := CheckBox.new()
		fine_check.text = "16-bit"
		fine_check.button_pressed = bool(data.get("fine", false))
		row.add_child(fine_check)

		var ranges_edit := LineEdit.new()
		ranges_edit.placeholder_text = "ranges"
		ranges_edit.custom_minimum_size = Vector2(150, 0)
		ranges_edit.text = _format_ranges(data.get("ranges", []))
		row.add_child(ranges_edit)

		var remove_row_btn := Button.new()
		remove_row_btn.icon = UniversePanel.header_icon("trash")
		remove_row_btn.tooltip_text = "Remove channel"
		row.add_child(remove_row_btn)

		var dup_row_btn := Button.new()
		dup_row_btn.icon = UniversePanel.header_icon("duplicate")
		dup_row_btn.tooltip_text = "Duplicate channel (added at the end)"
		row.add_child(dup_row_btn)

		channels_box.add_child(row)
		var entry := {
			"name_edit": ch_name, "role_option": role_opt,
			"def_spin": def_spin, "min_spin": min_spin, "max_spin": max_spin,
			"fine_check": fine_check, "ranges_edit": ranges_edit, "row": row,
			# the ranges field is text-only; keep the originals so slot
			# images (imported gobo art) survive an edit, matched by label.
			"orig_ranges": (data.get("ranges", []) as Array).duplicate(true),
		}
		channel_rows.append(entry)
		remove_row_btn.pressed.connect(func():
			channel_rows.erase(entry)
			row.queue_free()
		)
		dup_row_btn.pressed.connect(func():
			row_fns.add.call(row_to_dict.call(entry))
			# bring the copy into view once the list has laid it out
			var copy: Control = channel_rows[-1]["row"]
			(func(): scroll.ensure_control_visible(copy)).call_deferred()
		)
		# Dragging the handle moves the row live: the handle keeps the mouse
		# while pressed, and the row jumps to the slot under the cursor.
		var dragging := {"on": false}
		handle.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
				dragging.on = ev.pressed
				row.modulate = Color(0.75, 0.9, 1.3) if ev.pressed else Color.WHITE
				if not ev.pressed:
					channel_rows.sort_custom(func(a, b): return a["row"].get_index() < b["row"].get_index())
			elif ev is InputEventMouseMotion and dragging.on:
				var y := channels_box.get_global_mouse_position().y
				var kids := channels_box.get_children().filter(func(c): return not c.is_queued_for_deletion())
				var target: Node = kids[-1]
				for k in kids:
					if y < k.global_position.y + k.size.y * 0.5:
						target = k
						break
				if target != row:
					channels_box.move_child(row, target.get_index())
				# near the list's top / bottom edge, scroll it along
				var view := scroll.get_global_rect()
				if y < view.position.y + 24:
					scroll.scroll_vertical -= 12
				elif y > view.end.y - 24:
					scroll.scroll_vertical += 12
		)

	row_fns["add"] = add_channel_row

	read_rows_into = func(mode_idx: int):
		var chans: Array = []
		for entry in channel_rows:
			chans.append(row_to_dict.call(entry))
		modes_data[mode_idx]["channels"] = chans

	build_rows_from = func(mode_idx: int):
		for c in channels_box.get_children():
			c.queue_free()
		channel_rows.clear()
		var chans: Array = modes_data[mode_idx]["channels"]
		if chans.is_empty():
			add_channel_row.call()
		else:
			for c in chans:
				add_channel_row.call(c)

	refresh_mode_sel = func():
		mode_sel.clear()
		for m in modes_data:
			mode_sel.add_item(String(m["name"]))
		mode_sel.selected = cur.i
		del_mode_btn.disabled = modes_data.size() <= 1

	switch_mode = func(new_idx: int):
		read_rows_into.call(cur.i)
		cur.i = new_idx
		mode_name_edit.text = String(modes_data[cur.i]["name"])
		build_rows_from.call(cur.i)
		refresh_mode_sel.call()

	mode_sel.item_selected.connect(func(idx: int): switch_mode.call(idx))
	mode_name_edit.text_changed.connect(func(t: String):
		modes_data[cur.i]["name"] = t if t.strip_edges() != "" else "Mode"
		mode_sel.set_item_text(cur.i, modes_data[cur.i]["name"])
	)
	add_mode_btn.pressed.connect(func():
		read_rows_into.call(cur.i)
		modes_data.append({"name": "Mode %d" % (modes_data.size() + 1), "channels": []})
		switch_mode.call(modes_data.size() - 1)
	)
	# Copy the current mode (with its on-screen edits) in right after it.
	dup_mode_btn.pressed.connect(func():
		read_rows_into.call(cur.i)
		var src: Dictionary = modes_data[cur.i]
		modes_data.insert(cur.i + 1, {
			"name": "%s (copy)" % src["name"],
			"channels": (src["channels"] as Array).duplicate(true),
		})
		switch_mode.call(cur.i + 1)
	)
	del_mode_btn.pressed.connect(func():
		if modes_data.size() <= 1:
			return
		modes_data.remove_at(cur.i)
		cur.i = clampi(cur.i, 0, modes_data.size() - 1)
		mode_name_edit.text = String(modes_data[cur.i]["name"])
		build_rows_from.call(cur.i)
		refresh_mode_sel.call()
	)

	var add_channel_btn := Button.new()
	add_channel_btn.text = "Add Channel"
	add_channel_btn.pressed.connect(func(): add_channel_row.call())
	vbox.add_child(add_channel_btn)

	# Populate the first mode's channel rows (one blank row if it's empty).
	build_rows_from.call(cur.i)
	refresh_mode_sel.call()

	var bottom_row := HFlowContainer.new()
	var save_btn := Button.new()
	save_btn.text = "Save Changes" if editing else "Save Profile"
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	bottom_row.add_child(save_btn)
	bottom_row.add_child(cancel_btn)
	vbox.add_child(bottom_row)

	cancel_btn.pressed.connect(func(): win.queue_free())
	win.close_requested.connect(func(): win.queue_free())

	save_btn.pressed.connect(func():
		read_rows_into.call(cur.i)

		var p_modes: Array = []
		for m in modes_data:
			if (m["channels"] as Array).is_empty():
				status_label.text = "Mode '%s' has no channels." % m["name"]
				return
			p_modes.append({"name": m["name"], "channels": m["channels"]})

		var pname: String = name_edit.text.strip_edges()
		if pname == "":
			pname = "Custom Fixture"
		var pmaker: String = maker_edit.text.strip_edges()

		# Editing keeps the profile's id stable (so its file / built-in
		# shadow stays put); a new profile gets a unique id from its name.
		var safe_id: String = existing.id if editing \
			else _unique_profile_id(_safe_profile_id(("%s %s" % [pmaker, pname]).strip_edges()))

		var heads = _parse_heads_text(heads_edit.text)
		if heads is String:
			status_label.text = heads
			return
		var p_phys := {
			"category": PROFILE_CATEGORIES[maxi(cat_opt.selected, 0)][0],
			"beam_deg": beam_spin.value,
			"pan_range": pan_spin.value,
			"tilt_range": tilt_spin.value,
			"heads": heads,
		}
		var profile := FixtureProfile.new(safe_id, pname, [], p_modes, p_phys, pmaker)
		if editing:
			profile.geometry = existing.geometry.duplicate(true)   # an imported GDTF's 3D model

		var f := FileAccess.open(PROFILES_DIR + "/%s.json" % safe_id, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(profile.to_dict()))
			f.close()

		if editing:
			var idx := _profile_index_by_id(existing.id)
			if idx != -1:
				available_profiles[idx] = profile
			else:
				available_profiles.append(profile)
			_refresh_all_profile_options(false)
			status_label.text = "Updated profile '%s' — re-patch fixtures to use the changes." % pname
		else:
			available_profiles.append(profile)
			_refresh_all_profile_options(true)
			status_label.text = "Saved profile '%s' (%d mode(s))." % [pname, p_modes.size()]
		win.queue_free()
	)

	win.popup_centered()
