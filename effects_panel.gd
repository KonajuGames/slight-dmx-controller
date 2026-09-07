class_name EffectsPanel
extends VBoxContainer
## Effects tab: parametric waveforms (sine / triangle / saw / square /
## random) on one channel role, fanned across the patched fixtures that
## carry it. Output is an override layer on top of the base look. Effects
## live in `Fx.effects`.

signal effects_changed

## Set by the shell: func(role, universe, group) -> Array of {u, ch}.
var resolve_targets_cb := Callable()
## Set by the shell: func() -> Array[String] of fixture-group names.
var group_names_provider := Callable()

const ROLE_CHOICES := [
	"DIMMER", "RED", "GREEN", "BLUE", "WHITE", "AMBER", "UV", "PAN", "TILT",
]

var fx_list: ItemList
var name_edit: LineEdit
var run_check: CheckButton
var role_option: OptionButton
var universe_option: OptionButton
var group_option: OptionButton
var base_option: OptionButton
var wave_option: OptionButton
var bpm_spin: SpinBox
var size_spin: SpinBox
var center_spin: SpinBox
var fan_spin: SpinBox
var phase_spin: SpinBox
var targets_label: Label
var status_label: Label
var _syncing := false


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	custom_minimum_size = Vector2(300, 0)

	var title := Label.new()
	title.text = "Effects"
	add_child(title)

	var top := _flow()
	var new_btn := Button.new()
	new_btn.text = "New Effect"
	new_btn.pressed.connect(_new_effect)
	top.add_child(new_btn)
	var del_btn := Button.new()
	del_btn.text = "Delete Effect"
	del_btn.pressed.connect(_delete_effect)
	top.add_child(del_btn)
	add_child(top)

	fx_list = ItemList.new()
	fx_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fx_list.custom_minimum_size = Vector2(0, 90)
	fx_list.item_selected.connect(_on_effect_selected)
	add_child(fx_list)

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

	grid.add_child(_lbl("Waveform"))
	wave_option = OptionButton.new()
	for w in WaveEffect.WAVEFORMS:
		wave_option.add_item(w)
	wave_option.item_selected.connect(func(i: int): _set_field("waveform", i))
	grid.add_child(wave_option)

	grid.add_child(_lbl("Base"))
	base_option = OptionButton.new()
	for b in WaveEffect.BASE_MODES:
		base_option.add_item(b)
	base_option.item_selected.connect(func(i: int): _set_field("base_mode", i))
	grid.add_child(base_option)

	grid.add_child(_lbl("Rate (BPM)"))
	bpm_spin = _num(1, 1200, 1, 60)
	bpm_spin.value_changed.connect(func(v: float): _set_field("bpm", v))
	grid.add_child(bpm_spin)

	grid.add_child(_lbl("Size"))
	size_spin = _num(0, 255, 1, 128)
	size_spin.value_changed.connect(func(v: float): _set_field("size", v))
	grid.add_child(size_spin)

	grid.add_child(_lbl("Center"))
	center_spin = _num(0, 255, 1, 128)
	center_spin.value_changed.connect(func(v: float): _set_field("center", v))
	grid.add_child(center_spin)

	grid.add_child(_lbl("Fan (deg)"))
	fan_spin = _num(-360, 360, 5, 0)
	fan_spin.value_changed.connect(func(v: float): _set_field("fan_deg", v))
	grid.add_child(fan_spin)

	grid.add_child(_lbl("Phase (deg)"))
	phase_spin = _num(-360, 360, 15, 0)
	phase_spin.value_changed.connect(func(v: float): _set_field("phase_deg", v))
	grid.add_child(phase_spin)
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

	refresh_universe_options()
	refresh_group_options()
	_refresh()


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
	s.custom_minimum_size = Vector2(72, 0)
	return s


func _sel() -> int:
	var s := fx_list.get_selected_items()
	return s[0] if s.size() > 0 else -1


func _current() -> WaveEffect:
	var i := _sel()
	if i >= 0 and i < Fx.effects.size():
		return Fx.effects[i]
	return null


## Rebuilt by the shell whenever a universe is added or removed.
func refresh_universe_options() -> void:
	var keep: int = universe_option.selected
	universe_option.clear()
	universe_option.add_item("All universes")
	for i in range(ArtNet.universe_count()):
		universe_option.add_item("Universe %d" % (i + 1))
	if keep >= 0 and keep < universe_option.item_count:
		universe_option.selected = keep


## Rebuilt by the shell whenever the fixture groups change.
func refresh_group_options() -> void:
	group_option.clear()
	group_option.add_item("(use universe)")
	if group_names_provider.is_valid():
		for n in group_names_provider.call():
			group_option.add_item(String(n))
	var e := _current()
	if e != null:
		_select_group(e.group)
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

func _new_effect() -> void:
	var e := WaveEffect.new()
	e.name = "Effect %d" % (Fx.effects.size() + 1)
	Fx.effects.append(e)
	_refresh()
	fx_list.select(Fx.effects.size() - 1)
	_on_effect_selected(Fx.effects.size() - 1)
	effects_changed.emit()


func _delete_effect() -> void:
	var i := _sel()
	if i == -1:
		return
	Fx.effects.remove_at(i)
	_refresh()
	if not Fx.effects.is_empty():
		var pick: int = min(i, Fx.effects.size() - 1)
		fx_list.select(pick)
		_on_effect_selected(pick)
	effects_changed.emit()


func _rebuild_targets() -> void:
	var e := _current()
	if e == null or not resolve_targets_cb.is_valid():
		return
	e.set_targets(resolve_targets_cb.call(e.role, e.universe, e.group))
	targets_label.text = "%d target channel(s)." % e.target_count()


func _on_run_toggled(on: bool) -> void:
	if _syncing:
		return
	var e := _current()
	if e == null:
		return
	if on:
		_rebuild_targets()
		if e.target_count() == 0:
			var where := "group '%s'" % e.group if e.group != "" else "that universe"
			status_label.text = "No %s channels patched in %s." % [e.role, where]
			_syncing = true
			run_check.button_pressed = false
			_syncing = false
			return
	e.running = on
	_refresh_list_row(_sel())
	status_label.text = ("Running '%s'." % e.name) if on else ("Stopped '%s'." % e.name)


## Toggle an effect's run state by name (MIDI / OSC trigger). Case-
## insensitive; a numeric key is treated as a 1-based index.
func toggle_by_name(key: String) -> void:
	var idx := _find_effect(key)
	if idx == -1:
		return
	var e: WaveEffect = Fx.effects[idx]
	var on := not e.running
	if on and resolve_targets_cb.is_valid():
		e.set_targets(resolve_targets_cb.call(e.role, e.universe, e.group))
		if e.target_count() == 0:
			status_label.text = "Trigger: no %s channels patched for '%s'." % [e.role, e.name]
			return
	e.running = on
	_refresh_list_row(idx)
	if _sel() == idx:
		_syncing = true
		run_check.button_pressed = on
		_syncing = false
	status_label.text = ("Running '%s'." % e.name) if on else ("Stopped '%s'." % e.name)


func _find_effect(key: String) -> int:
	var low := key.strip_edges().to_lower()
	for i in range(Fx.effects.size()):
		if Fx.effects[i].name.to_lower() == low:
			return i
	if low.is_valid_int():
		var n := int(low) - 1
		if n >= 0 and n < Fx.effects.size():
			return n
	return -1


func _on_name_edited(t: String) -> void:
	if _syncing:
		return
	var e := _current()
	if e == null:
		return
	e.name = t
	_refresh_list_row(_sel())
	effects_changed.emit()


func _set_field(field: String, v) -> void:
	if _syncing:
		return
	var e := _current()
	if e == null:
		return
	e.set(field, v)
	if field == "role" or field == "universe" or field == "group":
		_rebuild_targets()
	if field == "group":
		_update_group_state()
	_refresh_list_row(_sel())
	effects_changed.emit()


func _on_effect_selected(idx: int) -> void:
	if idx < 0 or idx >= Fx.effects.size():
		return
	var e := Fx.effects[idx]
	_syncing = true
	name_edit.text = e.name
	run_check.button_pressed = e.running
	role_option.selected = maxi(ROLE_CHOICES.find(e.role), 0)
	universe_option.selected = clampi(e.universe + 1, 0, universe_option.item_count - 1)
	_select_group(e.group)
	base_option.selected = e.base_mode
	wave_option.selected = e.waveform
	bpm_spin.value = e.bpm
	size_spin.value = e.size
	center_spin.value = e.center
	fan_spin.value = e.fan_deg
	phase_spin.value = e.phase_deg
	_syncing = false
	_update_group_state()
	targets_label.text = "%d target channel(s)." % e.target_count()


# ---------------------------------------------------------------- REFRESH --

func _row_text(e: WaveEffect) -> String:
	var scope := e.group if e.group != "" else ("all" if e.universe < 0 else "U%d" % (e.universe + 1))
	var pk := "  pickup" if e.base_mode == WaveEffect.BASE_PICKUP else ""
	return "%s%s  %s %s  %.0f BPM  (%s)%s" % [
		"> " if e.running else "  ", e.name,
		WaveEffect.WAVEFORMS[e.waveform], e.role, e.bpm, scope, pk]


func _refresh_list_row(i: int) -> void:
	if i >= 0 and i < fx_list.item_count and i < Fx.effects.size():
		fx_list.set_item_text(i, _row_text(Fx.effects[i]))


func _refresh() -> void:
	var keep := _sel()
	fx_list.clear()
	for e in Fx.effects:
		fx_list.add_item(_row_text(e))
	if keep >= 0 and keep < fx_list.item_count:
		fx_list.select(keep)


## Re-sync the list and editor after an external change (e.g. Blackout
## All stopping every effect).
func sync_ui() -> void:
	_refresh()
	var i := _sel()
	if i != -1:
		_on_effect_selected(i)


# ------------------------------------------------------- SERIALIZATION --

func to_dict() -> Dictionary:
	var arr: Array = []
	for e in Fx.effects:
		arr.append(e.to_dict())
	return {"effects": arr}


func from_dict(d: Dictionary) -> void:
	Fx.effects.clear()
	for entry in d.get("effects", []):
		if entry is Dictionary:
			Fx.effects.append(WaveEffect.from_dict(entry))
	_refresh()
	if not Fx.effects.is_empty():
		fx_list.select(0)
		_on_effect_selected(0)
