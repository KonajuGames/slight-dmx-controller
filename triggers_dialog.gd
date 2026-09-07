class_name TriggersDialog
extends Window
## Configures the MIDI / OSC "GO" triggers in `Triggers.triggers`. Opened
## from the top bar; the shell wires `Triggers.fired` to the panels.
##
## Each binding maps one incoming message (a MIDI note / CC / program
## change, or an OSC address) to one action. **Learn** captures the match
## fields from the next message received.

## Set by the shell — func() -> Array[String].
var chase_names_provider := Callable()
var effect_names_provider := Callable()

var _list: ItemList
var _name_edit: LineEdit
var _enabled_check: CheckBox
var _source_option: OptionButton
var _midi_box: VBoxContainer
var _osc_box: VBoxContainer
var _midi_kind: OptionButton
var _midi_channel: OptionButton
var _midi_number: SpinBox
var _osc_addr: LineEdit
var _learn_btn: Button
var _action_option: OptionButton
var _target_hint: Label
var _target_edit: LineEdit
var _target_pick: OptionButton
var _fb_row_lbl: Label
var _fb_box: HBoxContainer
var _fb_check: CheckBox
var _fb_on: SpinBox
var _fb_off: SpinBox

var _midi_devices_label: Label
var _midi_on: CheckBox
var _osc_on: CheckBox
var _osc_port: SpinBox
var _osc_status: Label
var _fb_enable: CheckBox
var _fb_midi_port: SpinBox
var _fb_osc_host: LineEdit
var _fb_osc_port: SpinBox
var _activity: Label
var _editor_col: VBoxContainer

var _syncing := false


func _ready() -> void:
	title = "MIDI / OSC Triggers & Feedback"
	size = Vector2i(740, 640)
	min_size = Vector2i(560, 480)
	close_requested.connect(hide)
	visibility_changed.connect(func(): if visible: _on_shown())

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for s in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + s, 12)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	root.add_child(_build_io_section())
	root.add_child(HSeparator.new())

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	body.add_child(_build_list_column())
	body.add_child(_build_editor_column())

	_activity = Label.new()
	_activity.text = "Waiting for MIDI / OSC…"
	_activity.add_theme_color_override("font_color", Color(0.65, 0.8, 0.65))
	root.add_child(_activity)

	Triggers.activity.connect(func(t: String): _activity.text = t)
	Triggers.learned.connect(_on_learned)
	Triggers.osc_state_changed.connect(func(_on, detail): _osc_status.text = "OSC: " + detail)

	_refresh_list()
	_sync_editor()


# ------------------------------------------------------------ IO SECTION --

func _build_io_section() -> Control:
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 6)

	_midi_on = CheckBox.new()
	_midi_on.text = "MIDI input"
	_midi_on.button_pressed = Triggers.midi_enabled
	_midi_on.toggled.connect(func(on: bool): Triggers.midi_enabled = on)
	grid.add_child(_midi_on)
	_midi_devices_label = Label.new()
	_midi_devices_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_midi_devices_label)
	var rescan := Button.new()
	rescan.text = "Rescan"
	rescan.pressed.connect(_refresh_midi_devices)
	grid.add_child(rescan)

	_osc_on = CheckBox.new()
	_osc_on.text = "OSC input"
	_osc_on.button_pressed = Triggers.osc_enabled
	_osc_on.toggled.connect(func(_on: bool): _apply_osc())
	grid.add_child(_osc_on)
	var port_row := HBoxContainer.new()
	port_row.add_child(_lbl("UDP port"))
	_osc_port = SpinBox.new()
	_osc_port.min_value = 1
	_osc_port.max_value = 65535
	_osc_port.value = Triggers.osc_port
	_osc_port.custom_minimum_size = Vector2(90, 0)
	port_row.add_child(_osc_port)
	grid.add_child(port_row)
	var apply := Button.new()
	apply.text = "Apply"
	apply.pressed.connect(_apply_osc)
	grid.add_child(apply)

	grid.add_child(Control.new())
	_osc_status = Label.new()
	_osc_status.text = "OSC: off"
	grid.add_child(_osc_status)
	grid.add_child(Control.new())

	# --- feedback (out) ---
	_fb_enable = CheckBox.new()
	_fb_enable.text = "Feedback (LEDs)"
	_fb_enable.button_pressed = Triggers.feedback_enabled
	_fb_enable.toggled.connect(func(_on: bool): _apply_feedback())
	grid.add_child(_fb_enable)
	var mrow := HBoxContainer.new()
	mrow.add_child(_lbl("MIDI → bridge :"))
	_fb_midi_port = SpinBox.new()
	_fb_midi_port.min_value = 1
	_fb_midi_port.max_value = 65535
	_fb_midi_port.value = Triggers.midi_out_port
	_fb_midi_port.custom_minimum_size = Vector2(90, 0)
	mrow.add_child(_fb_midi_port)
	grid.add_child(mrow)
	var apply2 := Button.new()
	apply2.text = "Apply"
	apply2.pressed.connect(_apply_feedback)
	grid.add_child(apply2)

	grid.add_child(Control.new())
	var orow := HBoxContainer.new()
	orow.add_child(_lbl("OSC →"))
	_fb_osc_host = LineEdit.new()
	_fb_osc_host.text = Triggers.osc_out_host
	_fb_osc_host.custom_minimum_size = Vector2(110, 0)
	orow.add_child(_fb_osc_host)
	orow.add_child(_lbl(":"))
	_fb_osc_port = SpinBox.new()
	_fb_osc_port.min_value = 1
	_fb_osc_port.max_value = 65535
	_fb_osc_port.value = Triggers.osc_out_port
	_fb_osc_port.custom_minimum_size = Vector2(90, 0)
	orow.add_child(_fb_osc_port)
	grid.add_child(orow)
	grid.add_child(Control.new())

	_refresh_midi_devices()
	return grid


func _apply_feedback() -> void:
	Triggers.set_feedback(_fb_enable.button_pressed, int(_fb_midi_port.value),
		_fb_osc_host.text, int(_fb_osc_port.value))
	_fb_enable.set_pressed_no_signal(Triggers.feedback_enabled)


func _apply_osc() -> void:
	Triggers.set_osc(_osc_on.button_pressed, int(_osc_port.value))
	_osc_on.set_pressed_no_signal(Triggers.osc_enabled)


func _refresh_midi_devices() -> void:
	var d := Triggers.midi_devices()
	_midi_devices_label.text = ("Devices: " + ", ".join(d)) if d.size() > 0 else "No MIDI devices found"


# --------------------------------------------------------- LIST COLUMN --

func _build_list_column() -> Control:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(230, 0)
	col.add_theme_constant_override("separation", 6)

	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(func(_i: int): _sync_editor())
	col.add_child(_list)

	var btns := HBoxContainer.new()
	var add := Button.new()
	add.text = "Add"
	add.pressed.connect(_add_trigger)
	btns.add_child(add)
	var dup := Button.new()
	dup.text = "Duplicate"
	dup.pressed.connect(_dup_trigger)
	btns.add_child(dup)
	var del := Button.new()
	del.text = "Delete"
	del.pressed.connect(_del_trigger)
	btns.add_child(del)
	col.add_child(btns)
	return col


# ------------------------------------------------------- EDITOR COLUMN --

func _build_editor_column() -> Control:
	var col := VBoxContainer.new()
	_editor_col = col
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 5)
	col.add_child(grid)

	grid.add_child(_lbl("Name"))
	_name_edit = LineEdit.new()
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_changed.connect(func(t: String): _edit("name", t))
	grid.add_child(_name_edit)

	grid.add_child(_lbl("Enabled"))
	_enabled_check = CheckBox.new()
	_enabled_check.toggled.connect(func(on: bool): _edit("enabled", on))
	grid.add_child(_enabled_check)

	grid.add_child(_lbl("Source"))
	_source_option = OptionButton.new()
	for s in Trigger.SOURCES:
		_source_option.add_item(s)
	_source_option.item_selected.connect(func(i: int): _edit("source", i); _sync_editor())
	grid.add_child(_source_option)
	col.add_child(HSeparator.new())

	# MIDI fields ---------------------------------------------------
	_midi_box = VBoxContainer.new()
	col.add_child(_midi_box)
	var mg := GridContainer.new()
	mg.columns = 2
	mg.add_theme_constant_override("h_separation", 8)
	mg.add_theme_constant_override("v_separation", 5)
	_midi_box.add_child(mg)

	mg.add_child(_lbl("Message"))
	_midi_kind = OptionButton.new()
	for k in Trigger.MIDI_KINDS:
		_midi_kind.add_item(k)
	_midi_kind.item_selected.connect(func(i: int): _edit("midi_kind", i); _sync_editor())
	mg.add_child(_midi_kind)

	mg.add_child(_lbl("Channel"))
	_midi_channel = OptionButton.new()
	_midi_channel.add_item("Any")
	for c in range(16):
		_midi_channel.add_item("Ch %d" % (c + 1))
	_midi_channel.item_selected.connect(func(i: int): _edit("midi_channel", i - 1))
	mg.add_child(_midi_channel)

	mg.add_child(_lbl("Note / CC #"))
	_midi_number = SpinBox.new()
	_midi_number.min_value = 0
	_midi_number.max_value = 127
	_midi_number.value_changed.connect(func(v: float): _edit("midi_number", int(v)))
	mg.add_child(_midi_number)

	# OSC fields ---------------------------------------------------
	_osc_box = VBoxContainer.new()
	col.add_child(_osc_box)
	var og := GridContainer.new()
	og.columns = 2
	og.add_theme_constant_override("h_separation", 8)
	og.add_theme_constant_override("v_separation", 5)
	_osc_box.add_child(og)
	og.add_child(_lbl("Address"))
	_osc_addr = LineEdit.new()
	_osc_addr.placeholder_text = "/cue/go"
	_osc_addr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_osc_addr.text_changed.connect(func(t: String): _edit("osc_address", t))
	og.add_child(_osc_addr)

	_learn_btn = Button.new()
	_learn_btn.text = "Learn — hit a key / send a message"
	_learn_btn.toggle_mode = true
	_learn_btn.toggled.connect(_on_learn_toggled)
	col.add_child(_learn_btn)

	col.add_child(HSeparator.new())

	var ag := GridContainer.new()
	ag.columns = 2
	ag.add_theme_constant_override("h_separation", 8)
	ag.add_theme_constant_override("v_separation", 5)
	col.add_child(ag)

	ag.add_child(_lbl("Action"))
	_action_option = OptionButton.new()
	for a in Trigger.ACTIONS:
		_action_option.add_item(a)
	_action_option.item_selected.connect(func(i: int): _edit("action", i); _sync_editor())
	ag.add_child(_action_option)

	_target_hint = _lbl("Target")
	ag.add_child(_target_hint)
	var trow := HBoxContainer.new()
	_target_edit = LineEdit.new()
	_target_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_target_edit.text_changed.connect(func(t: String): _edit("target", t))
	trow.add_child(_target_edit)
	_target_pick = OptionButton.new()
	_target_pick.item_selected.connect(func(i: int):
		if i > 0:
			_target_edit.text = _target_pick.get_item_text(i)
			_edit("target", _target_edit.text))
	trow.add_child(_target_pick)
	ag.add_child(trow)

	_fb_row_lbl = _lbl("Feedback")
	ag.add_child(_fb_row_lbl)
	_fb_box = HBoxContainer.new()
	_fb_check = CheckBox.new()
	_fb_check.text = "light the pad when active"
	_fb_check.toggled.connect(func(on: bool): _edit("fb_enabled", on))
	_fb_box.add_child(_fb_check)
	_fb_box.add_child(_lbl("  on"))
	_fb_on = _spin(0, 127, 127)
	_fb_on.value_changed.connect(func(v: float): _edit("fb_on", int(v)))
	_fb_box.add_child(_fb_on)
	_fb_box.add_child(_lbl("off"))
	_fb_off = _spin(0, 127, 0)
	_fb_off.value_changed.connect(func(v: float): _edit("fb_off", int(v)))
	_fb_box.add_child(_fb_off)
	ag.add_child(_fb_box)

	return col


func _spin(lo: int, hi: int, val: int) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.value = val
	s.custom_minimum_size = Vector2(56, 0)
	return s


# --------------------------------------------------------------- ACTIONS --

func _cur() -> Trigger:
	var s := _list.get_selected_items()
	if s.size() > 0 and s[0] < Triggers.triggers.size():
		return Triggers.triggers[s[0]]
	return null


func _edit(field: String, v) -> void:
	if _syncing:
		return
	var t := _cur()
	if t == null:
		return
	t.set(field, v)
	_refresh_row(_list.get_selected_items()[0])


func _add_trigger() -> void:
	var t := Trigger.new()
	t.name = "Trigger %d" % (Triggers.triggers.size() + 1)
	Triggers.triggers.append(t)
	_refresh_list()
	_list.select(Triggers.triggers.size() - 1)
	_sync_editor()


func _dup_trigger() -> void:
	var t := _cur()
	if t == null:
		return
	var c := Trigger.from_dict(t.to_dict())
	c.name += " copy"
	Triggers.triggers.append(c)
	_refresh_list()
	_list.select(Triggers.triggers.size() - 1)
	_sync_editor()


func _del_trigger() -> void:
	var s := _list.get_selected_items()
	if s.is_empty():
		return
	Triggers.triggers.remove_at(s[0])
	_refresh_list()
	if not Triggers.triggers.is_empty():
		_list.select(mini(s[0], Triggers.triggers.size() - 1))
	_sync_editor()


func _on_learn_toggled(on: bool) -> void:
	if on and _cur() != null:
		Triggers.start_learn()
		_activity.text = "Learning — send the MIDI / OSC message now…"
	else:
		Triggers.cancel_learn()


func _on_learned(descriptor: Dictionary) -> void:
	var t := _cur()
	_learn_btn.set_pressed_no_signal(false)
	if t == null:
		return
	t.learn_from(descriptor)
	_refresh_row(_list.get_selected_items()[0])
	_sync_editor()
	_activity.text = "Learned: " + t.source_summary()


func _on_shown() -> void:
	_refresh_midi_devices()
	_refresh_list()
	_sync_editor()
	_fb_enable.set_pressed_no_signal(Triggers.feedback_enabled)
	_fb_midi_port.set_value_no_signal(Triggers.midi_out_port)
	_fb_osc_host.text = Triggers.osc_out_host
	_fb_osc_port.set_value_no_signal(Triggers.osc_out_port)
	_osc_on.set_pressed_no_signal(Triggers.osc_enabled)
	_osc_port.set_value_no_signal(Triggers.osc_port)
	_midi_on.set_pressed_no_signal(Triggers.midi_enabled)


# --------------------------------------------------------------- REFRESH --

func _row_text(t: Trigger) -> String:
	var mark := "  " if t.enabled else "× "
	var tgt := ("  → %s" % t.target) if t.needs_target() and t.target != "" else ""
	return "%s%s   [%s]   %s%s" % [
		mark, t.name, t.source_summary(), Trigger.ACTIONS[t.action], tgt]


func _refresh_row(i: int) -> void:
	if i >= 0 and i < _list.item_count and i < Triggers.triggers.size():
		_list.set_item_text(i, _row_text(Triggers.triggers[i]))


func _refresh_list() -> void:
	var keep := _list.get_selected_items()
	_list.clear()
	for t in Triggers.triggers:
		_list.add_item(_row_text(t))
	if keep.size() > 0 and keep[0] < _list.item_count:
		_list.select(keep[0])


func _sync_editor() -> void:
	var t := _cur()
	_editor_col.modulate = Color.WHITE if t != null else Color(1, 1, 1, 0.35)
	if t == null:
		_midi_box.visible = false
		_osc_box.visible = false
		return

	_syncing = true
	_name_edit.text = t.name
	_enabled_check.button_pressed = t.enabled
	_source_option.selected = t.source
	_midi_box.visible = t.source == Trigger.SRC_MIDI
	_osc_box.visible = t.source == Trigger.SRC_OSC
	_midi_kind.selected = t.midi_kind
	_midi_channel.selected = t.midi_channel + 1
	_midi_number.value = t.midi_number
	_osc_addr.text = t.osc_address
	_action_option.selected = t.action

	var needs := t.needs_target()
	_target_hint.visible = needs
	_target_edit.get_parent().visible = needs
	if needs:
		_target_edit.text = t.target
		var names: Array = []
		var pick_label := "pick…"
		if t.action == Trigger.ACT_CHASE_TOGGLE and chase_names_provider.is_valid():
			names = chase_names_provider.call()
			_target_hint.text = "Chase name"
			_target_edit.placeholder_text = "chase name or number"
		elif t.action == Trigger.ACT_EFFECT_TOGGLE and effect_names_provider.is_valid():
			names = effect_names_provider.call()
			_target_hint.text = "Effect name"
			_target_edit.placeholder_text = "effect name or number"
		else:
			_target_hint.text = "Cue number"
			_target_edit.placeholder_text = "e.g. 5"
		_target_pick.visible = not names.is_empty()
		_target_pick.clear()
		_target_pick.add_item(pick_label)
		for n in names:
			_target_pick.add_item(String(n))

	var fb := t.can_feedback()
	_fb_row_lbl.visible = fb
	_fb_box.visible = fb
	if fb:
		_fb_check.button_pressed = t.fb_enabled
		_fb_on.value = t.fb_on
		_fb_off.value = t.fb_off
	_syncing = false


func _lbl(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l
