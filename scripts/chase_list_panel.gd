class_name ChaseListPanel
extends VBoxContainer
## Chases tab: build a chase from captured steps, set its tempo / fade /
## direction, and run it. Output is an override layer on top of the base
## look, so a chase can run over a cue. Chases live in `Fx.chases`.

signal chases_changed

## Set by the shell: func(buffers: Array of PackedByteArray) — loads a
## step's per-universe look into the fixture controls for editing.
var to_patch_cb := Callable()

var chase_list: ItemList
var step_list: ItemList
var name_edit: LineEdit
var run_check: CheckButton
var bpm_spin: SpinBox
var xfade_spin: SpinBox
var dir_option: OptionButton
var beat_check: CheckBox
var status_label: Label
var _syncing := false


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	custom_minimum_size = Vector2(300, 0)

	var title := Label.new()
	title.text = "Chases"
	add_child(title)

	var top := _flow()
	var new_btn := Button.new()
	new_btn.text = "New Chase"
	new_btn.pressed.connect(_new_chase)
	top.add_child(new_btn)
	var del_btn := Button.new()
	del_btn.text = "Delete Chase"
	del_btn.pressed.connect(_delete_chase)
	top.add_child(del_btn)
	add_child(top)

	chase_list = ItemList.new()
	chase_list.custom_minimum_size = Vector2(0, 90)
	chase_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chase_list.item_selected.connect(_on_chase_selected)
	add_child(chase_list)

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

	grid.add_child(_lbl("Tempo (BPM)"))
	bpm_spin = _num(1, 600, 1, 120)
	bpm_spin.value_changed.connect(func(v: float): _set_field("bpm", v))
	grid.add_child(bpm_spin)

	grid.add_child(_lbl("Crossfade (%)"))
	xfade_spin = _num(0, 100, 1, 0)
	xfade_spin.value_changed.connect(func(v: float): _set_field("crossfade", v / 100.0))
	grid.add_child(xfade_spin)

	grid.add_child(_lbl("Direction"))
	dir_option = OptionButton.new()
	for n in ["Forward", "Backward", "Bounce"]:
		dir_option.add_item(n)
	dir_option.item_selected.connect(func(i: int): _set_field("direction", i))
	grid.add_child(dir_option)

	grid.add_child(_lbl("Beat sync"))
	beat_check = CheckBox.new()
	beat_check.text = "step on each beat (Sound Reactive mode)"
	beat_check.toggled.connect(func(on: bool): _set_field("beat_sync", on))
	grid.add_child(beat_check)
	add_child(grid)

	var step_btns := _flow()
	var rec_btn := Button.new()
	rec_btn.text = "Record Step"
	rec_btn.pressed.connect(_record_step)
	step_btns.add_child(rec_btn)
	var upd_step_btn := Button.new()
	upd_step_btn.text = "Update Step"
	upd_step_btn.tooltip_text = "Overwrite the selected step with the current live output."
	upd_step_btn.pressed.connect(_update_step)
	step_btns.add_child(upd_step_btn)
	var load_step_btn := Button.new()
	load_step_btn.text = "Load Step to Patch"
	load_step_btn.tooltip_text = "Set the fixture controls to the selected step so you can tweak it, then Update Step."
	load_step_btn.pressed.connect(_load_step_to_patch)
	step_btns.add_child(load_step_btn)
	var del_step_btn := Button.new()
	del_step_btn.text = "Delete Step"
	del_step_btn.pressed.connect(_delete_step)
	step_btns.add_child(del_step_btn)
	add_child(step_btns)

	step_list = ItemList.new()
	step_list.custom_minimum_size = Vector2(0, 90)
	add_child(step_list)

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status_label)

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
	var s := chase_list.get_selected_items()
	return s[0] if s.size() > 0 else -1


func _current() -> Chase:
	var i := _sel()
	if i >= 0 and i < Fx.chases.size():
		return Fx.chases[i]
	return null


# ----------------------------------------------------------------- ACTIONS --

func _new_chase() -> void:
	var c := Chase.new()
	c.name = "Chase %d" % (Fx.chases.size() + 1)
	Fx.chases.append(c)
	_refresh()
	chase_list.select(Fx.chases.size() - 1)
	_on_chase_selected(Fx.chases.size() - 1)
	chases_changed.emit()


func _delete_chase() -> void:
	var i := _sel()
	if i == -1:
		return
	Fx.chases.remove_at(i)
	_refresh()
	if not Fx.chases.is_empty():
		var pick: int = min(i, Fx.chases.size() - 1)
		chase_list.select(pick)
		_on_chase_selected(pick)
	chases_changed.emit()


func _record_step() -> void:
	var c := _current()
	if c == null:
		return
	c.capture_step()
	_refresh_steps()
	_refresh_list_row(_sel())
	status_label.text = "Recorded step %d of '%s'." % [c.step_count(), c.name]
	chases_changed.emit()


func _delete_step() -> void:
	var c := _current()
	if c == null:
		return
	var s := step_list.get_selected_items()
	if s.is_empty():
		return
	c.steps.remove_at(s[0])
	c.reset()
	_refresh_steps()
	_refresh_list_row(_sel())
	chases_changed.emit()


func _update_step() -> void:
	var c := _current()
	var s := step_list.get_selected_items()
	if c == null or s.is_empty():
		return
	c.update_step(s[0])
	_refresh_steps()
	step_list.select(s[0])
	status_label.text = "Updated step %d of '%s' from live output." % [s[0] + 1, c.name]
	chases_changed.emit()


## Push the selected step's look into the fixture controls so it can be
## tweaked and re-recorded with Update Step.
func _load_step_to_patch() -> void:
	var c := _current()
	var s := step_list.get_selected_items()
	if c == null or s.is_empty() or not to_patch_cb.is_valid():
		return
	to_patch_cb.call(c.step_buffers(s[0]))
	status_label.text = "Step %d loaded into the patch — tweak the fixtures, then Update Step." % (s[0] + 1)


func _on_run_toggled(on: bool) -> void:
	if _syncing:
		return
	var c := _current()
	if c == null:
		return
	if on:
		c.reset()
	c.running = on
	_refresh_list_row(_sel())
	status_label.text = ("Running '%s'." % c.name) if on else ("Stopped '%s'." % c.name)


## Toggle a chase's run state by name (MIDI / OSC trigger). Case-
## insensitive; falls back to a 1-based index if `key` is a number.
func toggle_by_name(key: String) -> void:
	var idx := _find_chase(key)
	if idx != -1:
		set_running_by_name(key, not Fx.chases[idx].running)


## Set a chase's run state explicitly (Auto Show timeline).
func set_running_by_name(key: String, on: bool) -> void:
	var idx := _find_chase(key)
	if idx == -1 or Fx.chases[idx].running == on:
		return
	var c: Chase = Fx.chases[idx]
	if on:
		c.reset()
	c.running = on
	_refresh_list_row(idx)
	if _sel() == idx:
		_syncing = true
		run_check.button_pressed = on
		_syncing = false
	status_label.text = ("Running '%s'." % c.name) if on else ("Stopped '%s'." % c.name)


func _find_chase(key: String) -> int:
	var low := key.strip_edges().to_lower()
	for i in range(Fx.chases.size()):
		if Fx.chases[i].name.to_lower() == low:
			return i
	if low.is_valid_int():
		var n := int(low) - 1
		if n >= 0 and n < Fx.chases.size():
			return n
	return -1


func _on_name_edited(t: String) -> void:
	if _syncing:
		return
	var c := _current()
	if c == null:
		return
	c.name = t
	_refresh_list_row(_sel())
	chases_changed.emit()


func _set_field(field: String, v) -> void:
	if _syncing:
		return
	var c := _current()
	if c == null:
		return
	c.set(field, v)
	_refresh_list_row(_sel())
	chases_changed.emit()


func _on_chase_selected(idx: int) -> void:
	if idx < 0 or idx >= Fx.chases.size():
		return
	var c := Fx.chases[idx]
	_syncing = true
	name_edit.text = c.name
	run_check.button_pressed = c.running
	bpm_spin.value = c.bpm
	xfade_spin.value = round(c.crossfade * 100.0)
	dir_option.selected = c.direction
	beat_check.button_pressed = c.beat_sync
	_syncing = false
	_refresh_steps()


# ---------------------------------------------------------------- REFRESH --

func _chase_row_text(c: Chase) -> String:
	var tempo := "beat" if c.beat_sync else "%.0f BPM" % c.bpm
	return "%s%s  %d steps  %s" % [
		"> " if c.running else "  ", c.name, c.step_count(), tempo]


func _refresh_list_row(i: int) -> void:
	if i >= 0 and i < chase_list.item_count and i < Fx.chases.size():
		chase_list.set_item_text(i, _chase_row_text(Fx.chases[i]))


func _refresh() -> void:
	var keep := _sel()
	chase_list.clear()
	for c in Fx.chases:
		chase_list.add_item(_chase_row_text(c))
	if keep >= 0 and keep < chase_list.item_count:
		chase_list.select(keep)
	_refresh_steps()


## Re-sync the list and editor after something outside this panel changed
## the chases (e.g. Blackout All stopping them).
func sync_ui() -> void:
	_refresh()
	var i := _sel()
	if i != -1:
		_on_chase_selected(i)


func _refresh_steps() -> void:
	step_list.clear()
	var c := _current()
	if c == null:
		return
	for i in range(c.steps.size()):
		var n := 0
		for uni in c.steps[i]:
			n += uni.size()
		step_list.add_item("Step %d  (%d ch)" % [i + 1, n])


# ------------------------------------------------------- SERIALIZATION --

func to_dict() -> Dictionary:
	var arr: Array = []
	for c in Fx.chases:
		arr.append(c.to_dict())
	return {"chases": arr}


func from_dict(d: Dictionary) -> void:
	Fx.chases.clear()
	for e in d.get("chases", []):
		if e is Dictionary:
			Fx.chases.append(Chase.from_dict(e))
	_refresh()
	if not Fx.chases.is_empty():
		chase_list.select(0)
		_on_chase_selected(0)
