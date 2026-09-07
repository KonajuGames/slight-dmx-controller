class_name SoundPanel
extends VBoxContainer
## Sound tab: pick an audio input, watch the live band meters, and build
## "reactors" that map a band (or the beat) onto a channel role across the
## patched fixtures. Reactors live in `Fx.reactors` and only drive output
## while the console's run mode is "Sound Reactive" (set in the top bar).

signal reactors_changed

## Set by the shell: func(role, universe, group) -> Array of {u, ch}.
var resolve_targets_cb := Callable()
## Set by the shell: func() -> Array[String] of fixture-group names.
var group_names_provider := Callable()

const ROLE_CHOICES := [
	"DIMMER", "RED", "GREEN", "BLUE", "WHITE", "AMBER", "UV", "STROBE", "ZOOM",
]

var device_option: OptionButton
var gain_slider: HSlider
var sens_slider: HSlider
var resp_slider: HSlider
var _meter: SoundMeter

var rx_list: ItemList
var name_edit: LineEdit
var run_check: CheckButton
var band_option: OptionButton
var role_option: OptionButton
var universe_option: OptionButton
var group_option: OptionButton
var mode_option: OptionButton
var low_spin: SpinBox
var high_spin: SpinBox
var attack_spin: SpinBox
var release_spin: SpinBox
var fan_spin: SpinBox
var targets_label: Label
var status_label: Label
var _syncing := false


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	custom_minimum_size = Vector2(300, 0)
	set_process(true)

	var title := Label.new()
	title.text = "Sound Reactive"
	add_child(title)

	var hint := Label.new()
	hint.text = "Set the run mode to \"Sound Reactive\" (top bar) to drive output from these."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	add_child(hint)

	# --- input + meters ---------------------------------------------
	var dev_row := _flow()
	dev_row.add_child(_lbl("Input"))
	device_option = OptionButton.new()
	device_option.item_selected.connect(_on_device_picked)
	dev_row.add_child(device_option)
	var refresh := Button.new()
	refresh.text = "Rescan"
	refresh.pressed.connect(_refresh_devices)
	dev_row.add_child(refresh)
	add_child(dev_row)

	_meter = SoundMeter.new()
	_meter.custom_minimum_size = Vector2(0, 54)
	add_child(_meter)

	var grid0 := GridContainer.new()
	grid0.columns = 2
	grid0.add_theme_constant_override("h_separation", 8)
	grid0.add_theme_constant_override("v_separation", 4)
	grid0.add_child(_lbl("Gain"))
	gain_slider = _slider(0.25, 4.0, 0.05, Sound.gain)
	gain_slider.value_changed.connect(func(v: float): Sound.gain = v)
	grid0.add_child(gain_slider)
	grid0.add_child(_lbl("Beat sensitivity"))
	sens_slider = _slider(1.05, 2.5, 0.05, Sound.beat_sensitivity)
	sens_slider.value_changed.connect(func(v: float): Sound.beat_sensitivity = v)
	grid0.add_child(sens_slider)
	grid0.add_child(_lbl("Response"))
	resp_slider = _slider(0.0, 1.0, 0.05, Sound.response)
	resp_slider.value_changed.connect(func(v: float): Sound.response = v)
	grid0.add_child(resp_slider)
	add_child(grid0)

	add_child(HSeparator.new())

	# --- reactor list ---------------------------------------------
	var top := _flow()
	var new_btn := Button.new()
	new_btn.text = "New Reactor"
	new_btn.pressed.connect(_new_reactor)
	top.add_child(new_btn)
	var del_btn := Button.new()
	del_btn.text = "Delete Reactor"
	del_btn.pressed.connect(_delete_reactor)
	top.add_child(del_btn)
	add_child(top)

	rx_list = ItemList.new()
	rx_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rx_list.custom_minimum_size = Vector2(0, 84)
	rx_list.item_selected.connect(_on_reactor_selected)
	add_child(rx_list)

	add_child(HSeparator.new())

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)

	grid.add_child(_lbl("Name"))
	name_edit = LineEdit.new()
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.text_changed.connect(_on_name_edited)
	grid.add_child(name_edit)

	grid.add_child(_lbl("Run"))
	run_check = CheckButton.new()
	run_check.toggled.connect(_on_run_toggled)
	grid.add_child(run_check)

	grid.add_child(_lbl("Band"))
	band_option = OptionButton.new()
	for b in SoundReactor.BANDS:
		band_option.add_item(b)
	band_option.item_selected.connect(func(i: int): _set_field("band", i))
	grid.add_child(band_option)

	grid.add_child(_lbl("Mode"))
	mode_option = OptionButton.new()
	for m in SoundReactor.MODES:
		mode_option.add_item(m)
	mode_option.item_selected.connect(func(i: int): _set_field("mode", i))
	grid.add_child(mode_option)

	grid.add_child(_lbl("Role"))
	role_option = OptionButton.new()
	for r in ROLE_CHOICES:
		role_option.add_item(r)
	role_option.item_selected.connect(func(i: int): _set_field("role", ROLE_CHOICES[i]))
	grid.add_child(role_option)

	grid.add_child(_lbl("Universe"))
	universe_option = OptionButton.new()
	universe_option.item_selected.connect(func(i: int): _set_field("universe", i - 1))
	grid.add_child(universe_option)

	grid.add_child(_lbl("Group"))
	group_option = OptionButton.new()
	group_option.item_selected.connect(func(i: int):
		_set_field("group", "" if i == 0 else group_option.get_item_text(i)))
	grid.add_child(group_option)

	grid.add_child(_lbl("Low / High"))
	var lh := HBoxContainer.new()
	low_spin = _num(0, 255, 1, 0)
	low_spin.value_changed.connect(func(v: float): _set_field("low", v))
	lh.add_child(low_spin)
	high_spin = _num(0, 255, 1, 255)
	high_spin.value_changed.connect(func(v: float): _set_field("high", v))
	lh.add_child(high_spin)
	grid.add_child(lh)

	grid.add_child(_lbl("Attack / Release"))
	var ar := HBoxContainer.new()
	attack_spin = _num(0.0, 1.0, 0.02, 0.7)
	attack_spin.value_changed.connect(func(v: float): _set_field("attack", v))
	ar.add_child(attack_spin)
	release_spin = _num(0.0, 1.0, 0.02, 0.12)
	release_spin.value_changed.connect(func(v: float): _set_field("release", v))
	ar.add_child(release_spin)
	grid.add_child(ar)

	grid.add_child(_lbl("Fan"))
	fan_spin = _num(0.0, 1.0, 0.05, 0.0)
	fan_spin.value_changed.connect(func(v: float): _set_field("fan", v))
	grid.add_child(fan_spin)
	add_child(grid)

	var rebuild := Button.new()
	rebuild.text = "Rebuild targets from patch"
	rebuild.pressed.connect(_rebuild_targets)
	add_child(rebuild)

	targets_label = _lbl("")
	add_child(targets_label)

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status_label)

	_refresh_devices()
	refresh_universe_options()
	refresh_group_options()
	_refresh()


func _process(_delta: float) -> void:
	if _meter and is_visible_in_tree():
		_meter.pull()


# ---------------------------------------------------------------- HELPERS --

func _lbl(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


func _flow(h: int = 6, v: int = 4) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", h)
	f.add_theme_constant_override("v_separation", v)
	return f


func _num(lo: float, hi: float, step: float, val: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = val
	s.custom_minimum_size = Vector2(64, 0)
	return s


func _slider(lo: float, hi: float, step: float, val: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = val
	s.custom_minimum_size = Vector2(150, 0)
	return s


func _sel() -> int:
	var s := rx_list.get_selected_items()
	return s[0] if s.size() > 0 else -1


func _current() -> SoundReactor:
	var i := _sel()
	if i >= 0 and i < Fx.reactors.size():
		return Fx.reactors[i]
	return null


# ---------------------------------------------------------------- DEVICES --

func _refresh_devices() -> void:
	device_option.clear()
	device_option.add_item("Default")
	var want := Sound.input_device
	var pick := 0
	for name in Sound.input_devices():
		if String(name) == "Default":
			continue
		device_option.add_item(String(name))
		if String(name) == want:
			pick = device_option.item_count - 1
	device_option.selected = pick


func _on_device_picked(i: int) -> void:
	Sound.set_device("" if i == 0 else device_option.get_item_text(i))
	status_label.text = "Input: %s" % device_option.get_item_text(i)


# --------------------------------------------------------- TARGET OPTIONS --

func refresh_universe_options() -> void:
	var keep: int = universe_option.selected
	universe_option.clear()
	universe_option.add_item("All universes")
	for i in range(ArtNet.universe_count()):
		universe_option.add_item("Universe %d" % (i + 1))
	if keep >= 0 and keep < universe_option.item_count:
		universe_option.selected = keep


func refresh_group_options() -> void:
	group_option.clear()
	group_option.add_item("(use universe)")
	if group_names_provider.is_valid():
		for n in group_names_provider.call():
			group_option.add_item(String(n))
	var r := _current()
	if r != null:
		_select_group(r.group)
	_update_group_state()


func _select_group(gname: String) -> void:
	group_option.selected = 0
	if gname == "":
		return
	for i in range(1, group_option.item_count):
		if group_option.get_item_text(i) == gname:
			group_option.selected = i
			return


func _update_group_state() -> void:
	universe_option.disabled = group_option.selected > 0


# ----------------------------------------------------------------- ACTIONS --

func _new_reactor() -> void:
	var r := SoundReactor.new()
	r.name = "Reactor %d" % (Fx.reactors.size() + 1)
	Fx.reactors.append(r)
	_refresh()
	rx_list.select(Fx.reactors.size() - 1)
	_on_reactor_selected(Fx.reactors.size() - 1)
	reactors_changed.emit()


func _delete_reactor() -> void:
	var i := _sel()
	if i == -1:
		return
	Fx.reactors.remove_at(i)
	_refresh()
	if not Fx.reactors.is_empty():
		var pick: int = min(i, Fx.reactors.size() - 1)
		rx_list.select(pick)
		_on_reactor_selected(pick)
	reactors_changed.emit()


func _rebuild_targets() -> void:
	var r := _current()
	if r == null or not resolve_targets_cb.is_valid():
		return
	r.set_targets(resolve_targets_cb.call(r.role, r.universe, r.group))
	targets_label.text = "%d target channel(s)." % r.target_count()


func _on_run_toggled(on: bool) -> void:
	if _syncing:
		return
	var r := _current()
	if r == null:
		return
	if on:
		_rebuild_targets()
		if r.target_count() == 0:
			var where := "group '%s'" % r.group if r.group != "" else "that universe"
			status_label.text = "No %s channels patched in %s." % [r.role, where]
			_syncing = true
			run_check.button_pressed = false
			_syncing = false
			return
	r.running = on
	_refresh_list_row(_sel())
	if on and not Fx.sound_reactive:
		status_label.text = "Armed '%s' — switch the run mode to Sound Reactive to hear it." % r.name
	else:
		status_label.text = ("Running '%s'." % r.name) if on else ("Stopped '%s'." % r.name)


func _on_name_edited(t: String) -> void:
	if _syncing:
		return
	var r := _current()
	if r == null:
		return
	r.name = t
	_refresh_list_row(_sel())
	reactors_changed.emit()


func _set_field(field: String, v) -> void:
	if _syncing:
		return
	var r := _current()
	if r == null:
		return
	r.set(field, v)
	if field == "role" or field == "universe" or field == "group":
		_rebuild_targets()
	if field == "group":
		_update_group_state()
	_refresh_list_row(_sel())
	reactors_changed.emit()


func _on_reactor_selected(idx: int) -> void:
	if idx < 0 or idx >= Fx.reactors.size():
		return
	var r := Fx.reactors[idx]
	_syncing = true
	name_edit.text = r.name
	run_check.button_pressed = r.running
	band_option.selected = r.band
	mode_option.selected = r.mode
	role_option.selected = maxi(ROLE_CHOICES.find(r.role), 0)
	universe_option.selected = clampi(r.universe + 1, 0, universe_option.item_count - 1)
	_select_group(r.group)
	low_spin.value = r.low
	high_spin.value = r.high
	attack_spin.value = r.attack
	release_spin.value = r.release
	fan_spin.value = r.fan
	_syncing = false
	_update_group_state()
	targets_label.text = "%d target channel(s)." % r.target_count()


# ---------------------------------------------------------------- REFRESH --

func _row_text(r: SoundReactor) -> String:
	var scope := r.group if r.group != "" else ("all" if r.universe < 0 else "U%d" % (r.universe + 1))
	return "%s%s  %s %s  %s  (%s)" % [
		"> " if r.running else "  ", r.name,
		SoundReactor.BANDS[r.band], r.role, SoundReactor.MODES[r.mode], scope]


func _refresh_list_row(i: int) -> void:
	if i >= 0 and i < rx_list.item_count and i < Fx.reactors.size():
		rx_list.set_item_text(i, _row_text(Fx.reactors[i]))


func _refresh() -> void:
	var keep := _sel()
	rx_list.clear()
	for r in Fx.reactors:
		rx_list.add_item(_row_text(r))
	if keep >= 0 and keep < rx_list.item_count:
		rx_list.select(keep)


func sync_ui() -> void:
	_refresh()
	var i := _sel()
	if i != -1:
		_on_reactor_selected(i)


# ------------------------------------------------------- SERIALIZATION --

func to_dict() -> Dictionary:
	var arr: Array = []
	for r in Fx.reactors:
		arr.append(r.to_dict())
	return {
		"reactors": arr,
		"device": Sound.input_device,
		"gain": Sound.gain,
		"beat_sensitivity": Sound.beat_sensitivity,
		"response": Sound.response,
	}


func from_dict(d: Dictionary) -> void:
	Fx.reactors.clear()
	for entry in d.get("reactors", []):
		if entry is Dictionary:
			Fx.reactors.append(SoundReactor.from_dict(entry))
	Sound.input_device = String(d.get("device", ""))
	Sound.gain = clampf(float(d.get("gain", 1.0)), 0.25, 4.0)
	Sound.beat_sensitivity = clampf(float(d.get("beat_sensitivity", 1.4)), 1.05, 2.5)
	Sound.response = clampf(float(d.get("response", 0.5)), 0.0, 1.0)
	_syncing = true
	gain_slider.value = Sound.gain
	sens_slider.value = Sound.beat_sensitivity
	resp_slider.value = Sound.response
	_syncing = false
	_refresh_devices()
	_refresh()
	if not Fx.reactors.is_empty():
		rx_list.select(0)
		_on_reactor_selected(0)


# =====================================================================
# Live band meter — four bars + a beat flash, repainted every frame.
# =====================================================================
class SoundMeter extends Control:
	var _b := 0.0
	var _m := 0.0
	var _t := 0.0
	var _l := 0.0
	var _beat := 0.0

	func pull() -> void:
		_b = Sound.bass
		_m = Sound.mid
		_t = Sound.treble
		_l = Sound.level
		_beat = Sound.beat_pulse
		queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(0, 0, w, h), Color(0.09, 0.09, 0.11))
		var bars := [
			["BASS", _b, Color(0.95, 0.35, 0.30)],
			["MID", _m, Color(0.40, 0.85, 0.45)],
			["TREB", _t, Color(0.40, 0.65, 0.95)],
			["LEVEL", _l, Color(0.90, 0.85, 0.35)],
		]
		var gap := 6.0
		var bw: float = (w - gap * (bars.size() + 1)) / bars.size()
		var x := gap
		for entry in bars:
			var val: float = clampf(entry[1], 0.0, 1.0)
			var bh := (h - 16.0) * val
			draw_rect(Rect2(x, h - 12.0 - bh, bw, bh), entry[2])
			draw_rect(Rect2(x, 4.0, bw, h - 16.0), Color(1, 1, 1, 0.05))
			var f := ThemeDB.fallback_font
			draw_string(f, Vector2(x, h - 2.0), entry[0],
				HORIZONTAL_ALIGNMENT_LEFT, bw, 9, Color(0.65, 0.65, 0.7))
			x += bw + gap
		if _beat > 0.01:
			draw_rect(Rect2(0, 0, w, h), Color(1, 1, 1, 0.28 * _beat), false, 3.0)
