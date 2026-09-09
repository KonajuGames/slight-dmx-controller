extends Control
## Main DMX control shell. Attached to the root Control node in main.tscn.
## Builds its whole UI in code so the scene file stays trivial.
##
## Layout: a top bar (grand master, Sending, add/remove universe, whole-
## show + preset save/load) above a TabContainer with one UniversePanel
## per Art-Net universe. Each panel owns its own ArtNetUniverse sender and
## fixture patch; this shell owns the shared fixture-profile list and the
## refresh loop.

const REFRESH_HZ := 30.0
const PRESET_PATH := "user://dmx_preset.json"
const SHOW_PATH := "user://dmx_show.json"
const PROFILES_DIR := "user://fixture_profiles"
const MODELS_DIR := "user://fixture_models"

var available_profiles: Array[FixtureProfile] = []
var _builtin_ids := {}  # profile ids that come from code (can't be file-deleted)

## Fixture groups: [{ "name": String, "members": Array of [u, fixture_id] }].
var groups: Array = []

var _panels: Array[UniversePanel] = []
var _refresh_timer: Timer

# UI refs
var universe_tabs: TabContainer
var cue_panel: CueListPanel
var chase_panel: ChaseListPanel
var fx_panel: EffectsPanel
var sound_panel: SoundPanel
var auto_show_panel: AutoShowPanel
var groups_panel: GroupsPanel
var viz_panel: VisualizerPanel
## The right-hand tabs (Patch + 3D Visualizer) and, while the visualizer
## is popped out, its own window.
var _right_tabs: TabContainer
var _viz_window: Window
const _VIZ_TAB := 1
var master_slider: HSlider
var sending_toggle: CheckButton
var run_mode_option: OptionButton
var _triggers_dialog: TriggersDialog

## Console run mode: 0 = Cue Mode (default), 1 = Sound Reactive,
## 2 = Auto Show (music-file timeline).
const RUN_MODES := ["Cue Mode", "Sound Reactive", "Auto Show"]
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

	auto_show_panel = AutoShowPanel.new()
	auto_show_panel.apply_show_cb = _apply_auto_show
	auto_show_panel.panels_provider = func(): return _panels
	playback_tabs.add_child(_scrollable(auto_show_panel))

	playback_tabs.add_child(_scrollable(groups_panel))
	playback_tabs.set_tab_title(0, "Cues")
	playback_tabs.set_tab_title(1, "Chases")
	playback_tabs.set_tab_title(2, "Effects")
	playback_tabs.set_tab_title(3, "Sound")
	playback_tabs.set_tab_title(4, "Auto Show")
	playback_tabs.set_tab_title(5, "Groups")

	groups_panel.groups_changed.connect(fx_panel.refresh_group_options)
	groups_panel.groups_changed.connect(sound_panel.refresh_group_options)
	playback_tabs.tab_changed.connect(func(i: int):
		if i == 5:
			groups_panel.sync_to_patch()
		elif i == 2:
			fx_panel.refresh_group_options()
		elif i == 3:
			sound_panel.refresh_group_options())

	AutoShow.cue_fired.connect(func(n: int): cue_panel.go_to_number(n))
	AutoShow.chase_set.connect(func(nm: String, on: bool): chase_panel.set_running_by_name(nm, on))
	AutoShow.effect_set.connect(func(nm: String, on: bool): fx_panel.set_running_by_name(nm, on))
	AutoShow.beat.connect(Fx._on_beat)

	# Right side: "Patch" (the universe tabs) and the "3D Visualizer".
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
	_right_tabs.set_tab_title(0, "Patch")
	_right_tabs.set_tab_title(_VIZ_TAB, "3D Visualizer")
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
	Triggers.feedback_state_cb = _feedback_state

	_refresh_timer = Timer.new()
	add_child(_refresh_timer)
	_refresh_timer.wait_time = 1.0 / REFRESH_HZ
	_refresh_timer.timeout.connect(_on_refresh_timeout)
	_refresh_timer.start()


# ---------------------------------------------------------------- UI BUILD --

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
	w.title = "sLight — 3D Visualizer"
	w.min_size = Vector2i(480, 320)
	var scr := DisplayServer.screen_get_usable_rect(get_window().current_screen)
	if rect.size.x > 200 and rect.size.y > 200:
		w.size = rect.size
		w.position = rect.position
	else:
		w.size = Vector2i(1000, 620)
		# drop it under the pointer, title bar clear of the screen edge
		w.position = Vector2i(DisplayServer.mouse_get_position()) - Vector2i(180, 6)
	w.position = Vector2i(
		clampi(w.position.x, scr.position.x + 8, scr.position.x + scr.size.x - 120),
		clampi(w.position.y, scr.position.y + 36, scr.position.y + scr.size.y - 80))
	w.close_requested.connect(_dock_viz)
	add_child(w)

	_right_tabs.remove_child(viz_panel)
	w.add_child(viz_panel)
	viz_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_viz_window = w
	_viz_last_pos = w.position
	_viz_move_frames = 0
	_viz_still_frames = 0
	viz_panel.set_floating(true)
	set_process(true)
	# "Patch" is the only tab left; it doubles as the re-dock drop zone.
	status_label.text = "3D Visualizer popped out — drag its title onto the tab bar to dock, or close it."


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
		return {"floating": false}
	return {
		"floating": true,
		"rect": [_viz_window.position.x, _viz_window.position.y,
			_viz_window.size.x, _viz_window.size.y],
	}


func _apply_viz_window(d: Dictionary) -> void:
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
	add_uni_btn.pressed.connect(_on_add_universe)
	row.add_child(add_uni_btn)

	remove_uni_btn = Button.new()
	remove_uni_btn.text = "Remove Universe"
	remove_uni_btn.pressed.connect(_on_remove_universe)
	row.add_child(remove_uni_btn)

	var save_show := Button.new()
	save_show.text = "Save Show"
	save_show.pressed.connect(_on_save_show)
	row.add_child(save_show)

	var load_show := Button.new()
	load_show.text = "Load Show"
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


# ------------------------------------------------------------- UNIVERSES --

func _add_universe_tab(sender: ArtNetUniverse) -> UniversePanel:
	var panel := UniversePanel.new()
	panel.sender = sender
	panel.available_profiles = available_profiles
	panel.profile_action_cb = _on_profile_action
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


func _on_remove_universe() -> void:
	if _panels.size() <= 1:
		return
	var idx: int = universe_tabs.current_tab
	if idx < 0 or idx >= _panels.size():
		idx = _panels.size() - 1

	ArtNet.remove_universe(idx)
	var panel := _panels[idx]
	universe_tabs.remove_child(panel)
	panel.queue_free()
	_panels.remove_at(idx)

	# fix up group members: drop the removed universe, shift higher ones down
	for g in groups:
		var mm: Array = []
		for m in g["members"]:
			var mu := int(m[0])
			if mu == idx:
				continue
			mm.append([mu - 1 if mu > idx else mu, int(m[1])])
		g["members"] = mm
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
					member_set["%d/%d" % [int(m[0]), int(m[1])]] = true

	var out: Array = []
	for ui in range(_panels.size()):
		if not use_group and universe != -1 and universe != ui:
			continue
		for fixture in _panels[ui].patched_fixtures:
			if use_group and not member_set.has("%d/%d" % [ui, int(fixture["id"])]):
				continue
			var profile: FixtureProfile = fixture["profile"]
			var chans: Array = profile.channels_for_mode(int(fixture.get("mode", 0)))
			var start: int = fixture["start"]
			for li in range(chans.size()):
				if String(chans[li]["role"]) == role:
					out.append({"u": ui, "ch": start + li})
	return out


func _group_names() -> Array:
	var out: Array = []
	for g in groups:
		out.append(String(g["name"]))
	return out


## Every patched fixture as { u, id, label } for the groups checklist.
func _list_patched_fixtures() -> Array:
	var out: Array = []
	for ui in range(_panels.size()):
		for fx in _panels[ui].patched_fixtures:
			var prof: FixtureProfile = fx["profile"]
			var start: int = fx["start"]
			var count := prof.channel_count(int(fx.get("mode", 0)))
			out.append({
				"u": ui, "id": int(fx["id"]),
				"label": "U%d · %s (ch %d-%d)" % [ui + 1, fx["name"], start + 1, start + count],
			})
	return out


func _fixture_index(u: int, id: int) -> int:
	if u < 0 or u >= _panels.size():
		return -1
	var pf: Array = _panels[u].patched_fixtures
	for i in range(pf.size()):
		if int(pf[i]["id"]) == id:
			return i
	return -1


func _on_patch_changed() -> void:
	if groups_panel:
		groups_panel.sync_to_patch()
	if viz_panel:
		viz_panel.rebuild()


## Groups saved with members as [universe, patch-index] so they survive a
## save/load even though fixture ids are session-local.
func _groups_to_dict() -> Dictionary:
	var arr: Array = []
	for g in groups:
		var mem: Array = []
		for m in g["members"]:
			var idx := _fixture_index(int(m[0]), int(m[1]))
			if idx != -1:
				mem.append([int(m[0]), idx])
		arr.append({"name": String(g["name"]), "members": mem})
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
			if not (m is Array) or m.size() < 2:
				continue
			var u := int(m[0])
			var idx := int(m[1])
			if u >= 0 and u < _panels.size() and idx >= 0 and idx < _panels[u].patched_fixtures.size():
				mem.append([u, int(_panels[u].patched_fixtures[idx]["id"])])
		groups.append({"name": String(g.get("name", "Group")), "members": mem})


func _refresh_tab_titles() -> void:
	for i in range(universe_tabs.get_tab_count()):
		universe_tabs.set_tab_title(i, "Universe %d" % (i + 1))


func _update_universe_buttons() -> void:
	add_uni_btn.disabled = ArtNet.universe_count() >= ArtNet.MAX_UNIVERSES
	remove_uni_btn.disabled = ArtNet.universe_count() <= 1


func _on_blackout_all() -> void:
	ArtNet.stop_fade()
	Fx.stop_all()
	AutoShow.pause()
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
		2: status_label.text = "Auto Show — load a song in the Auto Show tab, then Play."
		_: status_label.text = "Cue Mode — cue list drives playback."


func _set_run_mode(idx: int) -> void:
	run_mode = clampi(idx, 0, RUN_MODES.size() - 1)
	if run_mode_option.selected != run_mode:
		run_mode_option.selected = run_mode
	Fx.sound_reactive = run_mode == 1
	Sound.active = run_mode == 1
	Fx.auto_show = run_mode == 2
	AutoShow.active = run_mode == 2
	if run_mode != 2:
		AutoShow.pause()


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


## The Auto Show generator produced cues, chases, movement effects and a
## timeline — install them non-destructively (hand-programmed cues, chases
## and effects are left alone; only same-named auto ones are replaced).
func _apply_auto_show(res: Dictionary) -> void:
	var new_cues: Array = res["cues"]
	var first := cue_panel.replace_auto_cues(new_cues)

	for chase in res["chases"]:
		for i in range(Fx.chases.size() - 1, -1, -1):
			if Fx.chases[i].name == chase.name:
				Fx.chases.remove_at(i)
		Fx.chases.append(chase)
	chase_panel.sync_ui()

	for eff in res["effects"]:
		for i in range(Fx.effects.size() - 1, -1, -1):
			if Fx.effects[i].name == eff.name:
				Fx.effects.remove_at(i)
		eff.set_targets(_resolve_fx_targets(eff.role, eff.universe, eff.group))
		Fx.effects.append(eff)
	fx_panel.sync_ui()

	AutoShow.set_show(res["timeline"], first)
	status_label.text = "Auto Show built: %d section cues, %d chases, %d effects." % [
		res["cues"].size(), res["chases"].size(), res["effects"].size()]


## "Load to Patch" — write a cue's or chase step's per-universe look into
## the fixture controls so it can be edited and re-recorded.
func _load_look_to_patch(buffers: Array) -> void:
	ArtNet.stop_fade()
	AutoShow.pause()
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
		"autoshow":
			return AutoShow.playing
	return false


func _on_refresh_timeout() -> void:
	# Always recompute each universe's output (the 3D view reads it);
	# only put it on the wire while "Sending" is checked.
	ArtNet.tick(sending_toggle.button_pressed)


## Space fires the next cue, like a real console — but only when no text
## field or button ate the keypress first.
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE and run_mode == 0:
			cue_panel.go()
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
	var base_id := _safe_profile_id(profile.id if profile.id.strip_edges() != "" else profile.profile_name)
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
		profile.profile_name, profile.mode_count(), profile.channel_count(0)]
	if not warns.is_empty():
		msg += "  %d approximation(s); check it in Edit..." % warns.size()
		push_warning("Fixture import notes:\n- " + "\n- ".join(warns))
	status_label.text = msg


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
		status_label.text = "'%s' is a built-in profile and can't be deleted." % p.profile_name
		return

	var reverts := _builtin_ids.has(p.id)
	var dlg := ConfirmationDialog.new()
	dlg.title = "Delete Profile"
	if reverts:
		dlg.dialog_text = "Reset \"%s\" to its built-in default?\n\nYour edited copy (%s.json) will be removed." % [p.profile_name, p.id]
		dlg.ok_button_text = "Reset"
	else:
		dlg.dialog_text = "Delete the profile \"%s\"?\n\n%s.json will be removed. This can't be undone." % [p.profile_name, p.id]
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
		status_label.text = "Reset '%s' to its built-in default." % p.profile_name
	else:
		if idx != -1:
			available_profiles.remove_at(idx)
		status_label.text = "Deleted profile '%s'." % p.profile_name

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

## A show file is every universe's connection settings + fixture patch,
## plus the cue list, chases, effects and fixture groups.
func _on_save_show() -> void:
	var data := {
		"universes": [],
		"run_mode": run_mode,
		"cues": cue_panel.to_dict(),
		"chases": chase_panel.to_dict(),
		"effects": fx_panel.to_dict(),
		"sound": sound_panel.to_dict(),
		"triggers": Triggers.to_dict(),
		"auto_show": AutoShow.to_dict(),
		"groups": _groups_to_dict(),
		"viz": viz_panel.to_dict(),
		"viz_window": _viz_window_dict(),
		"sacn_cid": Marshalls.raw_to_base64(ArtNet.sacn_cid),
	}
	for p in _panels:
		data["universes"].append(p.patch_dict())

	var f := FileAccess.open(SHOW_PATH, FileAccess.WRITE)
	if f == null:
		status_label.text = "Show save failed."
		return
	f.store_string(JSON.stringify(data))
	f.close()
	status_label.text = "Show saved (%d universes, %d cues, %d chases, %d effects)." % [
		_panels.size(), cue_panel.cues.size(), Fx.chases.size(), Fx.effects.size()]


func _on_load_show() -> void:
	if not FileAccess.file_exists(SHOW_PATH):
		status_label.text = "No show file found."
		return

	var f := FileAccess.open(SHOW_PATH, FileAccess.READ)
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()

	var uni_list: Array
	if parsed is Dictionary and parsed.has("universes"):
		uni_list = parsed["universes"]
	elif parsed is Array:
		# Legacy single-universe patch: a bare fixtures array.
		uni_list = [{"fixtures": parsed}]
	else:
		status_label.text = "Show file corrupt."
		return

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
		_panels[i].apply_patch_dict(uni_list[i])

	var doc: Dictionary = parsed if parsed is Dictionary else {}
	cue_panel.from_dict(doc.get("cues", {}))
	chase_panel.from_dict(doc.get("chases", {}))
	_groups_from_dict(doc.get("groups", {}))   # fills the shared `groups`
	groups_panel.sync_to_patch()
	fx_panel.from_dict(doc.get("effects", {}))
	fx_panel.refresh_group_options()
	sound_panel.from_dict(doc.get("sound", {}))
	sound_panel.refresh_group_options()
	Triggers.from_dict(doc.get("triggers", {}))
	AutoShow.from_dict(doc.get("auto_show", {}))
	auto_show_panel.reload()
	_set_run_mode(int(doc.get("run_mode", 0)))
	viz_panel.rebuild()
	viz_panel.from_dict(doc.get("viz", {}))
	_apply_viz_window(doc.get("viz_window", {}))
	status_label.text = "Show loaded (%d universes, %d cues, %d chases, %d effects, %d groups)." % [
		n, cue_panel.cues.size(), Fx.chases.size(), Fx.effects.size(), groups.size()]


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
	win.size = Vector2i(760, 540)
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
	name_row.add_child(_label("Profile name:"))
	var name_edit := LineEdit.new()
	name_edit.text = existing.profile_name if editing else "Custom Fixture"
	name_edit.custom_minimum_size = Vector2(220, 0)
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(name_edit)
	vbox.add_child(name_row)

	if editing and _builtin_ids.has(existing.id) and not _profile_has_file(existing):
		var note := _label("Editing a built-in — Save keeps this as your own copy.")
		note.modulate = Color(1, 1, 1, 0.6)
		vbox.add_child(note)

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

	add_channel_row = func(data: Dictionary = {}):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)

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
		remove_row_btn.text = "X"
		row.add_child(remove_row_btn)

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

	read_rows_into = func(mode_idx: int):
		var chans: Array = []
		for entry in channel_rows:
			var role_idx: int = entry["role_option"].selected
			var new_ranges := _parse_ranges_text(entry["ranges_edit"].text)
			_carry_slot_images(new_ranges, entry.get("orig_ranges", []))
			chans.append({
				"name": entry["name_edit"].text,
				"role": FixtureProfile.ROLES[role_idx] if role_idx >= 0 else "GENERIC",
				"default": int(entry["def_spin"].value),
				"min": int(entry["min_spin"].value),
				"max": int(entry["max_spin"].value),
				"fine": entry["fine_check"].button_pressed,
				"ranges": new_ranges,
			})
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

		# Editing keeps the profile's id stable (so its file / built-in
		# shadow stays put); a new profile gets a unique id from its name.
		var safe_id: String = existing.id if editing else _unique_profile_id(_safe_profile_id(pname))

		var profile := FixtureProfile.new(safe_id, pname, [], p_modes)

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
