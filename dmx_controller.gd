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

var available_profiles: Array[FixtureProfile] = []

var _panels: Array[UniversePanel] = []
var _refresh_timer: Timer

# UI refs
var universe_tabs: TabContainer
var cue_panel: CueListPanel
var master_slider: HSlider
var sending_toggle: CheckButton
var add_uni_btn: Button
var remove_uni_btn: Button
var status_label: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

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

	# Cue list on the left, universe tabs on the right.
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 320
	main_vbox.add_child(split)

	cue_panel = CueListPanel.new()
	split.add_child(cue_panel)

	universe_tabs = TabContainer.new()
	universe_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(universe_tabs)

	_load_available_profiles()

	# ArtNet always starts with one universe slot; give it a tab.
	_add_universe_tab(ArtNet.get_universe(0))
	_update_universe_buttons()

	_refresh_timer = Timer.new()
	add_child(_refresh_timer)
	_refresh_timer.wait_time = 1.0 / REFRESH_HZ
	_refresh_timer.timeout.connect(_on_refresh_timeout)
	_refresh_timer.start()


# ---------------------------------------------------------------- UI BUILD --

func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _build_top_bar() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	row.add_child(_label("Grand Master:"))
	master_slider = HSlider.new()
	master_slider.min_value = 0
	master_slider.max_value = 255
	master_slider.step = 1
	master_slider.value = 255
	master_slider.custom_minimum_size = Vector2(200, 0)
	master_slider.value_changed.connect(func(v: float): ArtNet.master = v / 255.0)
	row.add_child(master_slider)

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

	status_label = _label("")
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(status_label)

	return row


# ------------------------------------------------------------- UNIVERSES --

func _add_universe_tab(sender: ArtNetUniverse) -> UniversePanel:
	var panel := UniversePanel.new()
	panel.sender = sender
	panel.available_profiles = available_profiles
	panel.open_new_profile_cb = _open_new_profile_dialog
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

	_refresh_tab_titles()
	_update_universe_buttons()
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


func _refresh_tab_titles() -> void:
	for i in range(universe_tabs.get_tab_count()):
		universe_tabs.set_tab_title(i, "Universe %d" % (i + 1))


func _update_universe_buttons() -> void:
	add_uni_btn.disabled = ArtNet.universe_count() >= ArtNet.MAX_UNIVERSES
	remove_uni_btn.disabled = ArtNet.universe_count() <= 1


func _on_blackout_all() -> void:
	ArtNet.stop_fade()
	for i in range(ArtNet.universe_count()):
		ArtNet.get_universe(i).set_all(0)
	status_label.text = "Blackout — all universes."


func _on_refresh_timeout() -> void:
	if sending_toggle.button_pressed:
		ArtNet.send_all()


## Space fires the next cue, like a real console — but only when no text
## field or button ate the keypress first.
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			cue_panel.go()
			get_viewport().set_input_as_handled()


# -------------------------------------------------------------- PROFILES --

func _load_available_profiles() -> void:
	available_profiles.clear()
	available_profiles.append_array(FixtureProfile.built_in_profiles())

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
						available_profiles.append(FixtureProfile.from_dict(parsed))
			fname = dir.get_next()
		dir.list_dir_end()


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
## plus the cue list.
func _on_save_show() -> void:
	var data := {"universes": [], "cues": cue_panel.to_dict()}
	for p in _panels:
		data["universes"].append(p.patch_dict())

	var f := FileAccess.open(SHOW_PATH, FileAccess.WRITE)
	if f == null:
		status_label.text = "Show save failed."
		return
	f.store_string(JSON.stringify(data))
	f.close()
	status_label.text = "Show saved (%d universes, %d cues)." % [
		_panels.size(), cue_panel.cues.size()]


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
	var n: int = clampi(uni_list.size(), 1, ArtNet.MAX_UNIVERSES)
	ArtNet.set_universe_count(n)
	_sync_tabs_to_universes()
	for i in range(n):
		_panels[i].apply_patch_dict(uni_list[i])

	if parsed is Dictionary and parsed.has("cues"):
		cue_panel.from_dict(parsed["cues"])
	else:
		cue_panel.from_dict({})
	status_label.text = "Show loaded (%d universes, %d cues)." % [n, cue_panel.cues.size()]


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
	# Grow (never shrink) so a preset wider than the current show still loads.
	var n: int = clampi(uni_list.size(), 1, ArtNet.MAX_UNIVERSES)
	ArtNet.set_universe_count(maxi(ArtNet.universe_count(), n))
	_sync_tabs_to_universes()
	for i in range(min(uni_list.size(), _panels.size())):
		_panels[i].apply_buffer_dict(uni_list[i])
	status_label.text = "Preset loaded (fixture controls won't move, but the output updates)."


# ----------------------------------------------------- NEW PROFILE DIALOG --

## Turn a "0-9:Open, 10-19:Red" text field into a ranges array.
func _parse_ranges_text(text: String) -> Array:
	var out: Array = []
	for part in text.split(",", false):
		var p: String = part.strip_edges()
		if p == "":
			continue
		var span := p
		var label := ""
		var colon := p.find(":")
		if colon != -1:
			span = p.substr(0, colon).strip_edges()
			label = p.substr(colon + 1).strip_edges()
		var dash := span.find("-")
		if dash == -1:
			continue
		out.append({
			"lo": int(span.substr(0, dash).strip_edges()),
			"hi": int(span.substr(dash + 1).strip_edges()),
			"label": label,
		})
	return out


## Inverse of _parse_ranges_text, for re-showing a channel's ranges.
func _format_ranges(arr: Array) -> String:
	var parts: Array = []
	for r in arr:
		var lbl := String(r.get("label", ""))
		if lbl == "":
			parts.append("%d-%d" % [int(r["lo"]), int(r["hi"])])
		else:
			parts.append("%d-%d:%s" % [int(r["lo"]), int(r["hi"]), lbl])
	var s := ""
	for i in range(parts.size()):
		s += parts[i]
		if i < parts.size() - 1:
			s += ", "
	return s


## Popup for defining a custom fixture profile: a name, one or more DMX
## modes, and per mode a list of channels — each with a label, role,
## default / min / max, a 16-bit "fine" flag, and optional named value
## ranges. Saves to user://fixture_profiles/<id>.json and adds it to every
## universe's profile picker.
func _open_new_profile_dialog() -> void:
	var win := Window.new()
	win.title = "New Fixture Profile"
	win.size = Vector2i(760, 540)
	add_child(win)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	win.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var name_row := HBoxContainer.new()
	name_row.add_child(_label("Profile name:"))
	var name_edit := LineEdit.new()
	name_edit.text = "Custom Fixture"
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(name_edit)
	vbox.add_child(name_row)

	# --- mode bar -------------------------------------------------------
	# Channel edits live in modes_data[cur.i]; the on-screen rows
	# are flushed back into it whenever the mode changes or on Save.
	var modes_data: Array = [{"name": "Default", "channels": []}]
	# Held in a Dictionary, not a bare int: GDScript lambdas capture locals
	# by value, so the several closures below must share one container to
	# all see the current mode index.
	var cur := {"i": 0}

	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 6)
	mode_row.add_child(_label("Mode:"))
	var mode_sel := OptionButton.new()
	mode_sel.custom_minimum_size = Vector2(120, 0)
	mode_row.add_child(mode_sel)
	var mode_name_edit := LineEdit.new()
	mode_name_edit.custom_minimum_size = Vector2(140, 0)
	mode_name_edit.text = "Default"
	mode_row.add_child(mode_name_edit)
	var add_mode_btn := Button.new()
	add_mode_btn.text = "Add Mode"
	mode_row.add_child(add_mode_btn)
	var del_mode_btn := Button.new()
	del_mode_btn.text = "Delete Mode"
	mode_row.add_child(del_mode_btn)
	vbox.add_child(mode_row)

	var hint := _label("Ranges: \"0-9:Open, 10-19:Red\" (leave blank for a plain slider)")
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
			chans.append({
				"name": entry["name_edit"].text,
				"role": FixtureProfile.ROLES[role_idx] if role_idx >= 0 else "GENERIC",
				"default": int(entry["def_spin"].value),
				"min": int(entry["min_spin"].value),
				"max": int(entry["max_spin"].value),
				"fine": entry["fine_check"].button_pressed,
				"ranges": _parse_ranges_text(entry["ranges_edit"].text),
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

	# Start with one channel row so the dialog isn't empty.
	add_channel_row.call()
	refresh_mode_sel.call()

	var bottom_row := HBoxContainer.new()
	var save_btn := Button.new()
	save_btn.text = "Save Profile"
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
		var safe_id: String = pname.to_lower().replace(" ", "_")

		var profile := FixtureProfile.new(safe_id, pname, [], p_modes)

		var fpath := PROFILES_DIR + "/%s.json" % safe_id
		var f := FileAccess.open(fpath, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(profile.to_dict()))
			f.close()

		available_profiles.append(profile)
		_refresh_all_profile_options(true)
		status_label.text = "Saved profile '%s' (%d mode(s))." % [pname, p_modes.size()]
		win.queue_free()
	)

	win.popup_centered()
