class_name CueListPanel
extends VBoxContainer
## The playback side of the console: an ordered list of cues you step
## through with GO, each crossfading every universe from the current
## output to the cue's stored look over its fade time.
##
## Recording captures the live DMX buffers (so dial a look with the
## fixture controls, then Record Cue). Cues are saved inside the show file.

signal cues_changed

var cues: Array[Cue] = []
var _current := -1   # cue currently live (-1 = none)
var _next := 0       # cue GO will fire

# UI
var cue_list: ItemList
var next_label: Label
var label_edit: LineEdit
var fade_up_spin: SpinBox
var fade_down_spin: SpinBox
var new_fade_spin: SpinBox
var status_label: Label
var _syncing := false  # guard while pushing cue -> edit fields


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	custom_minimum_size = Vector2(300, 0)

	var title := Label.new()
	title.text = "Cue List"
	add_child(title)

	# --- transport ---
	var transport := HBoxContainer.new()
	transport.add_theme_constant_override("separation", 6)
	var go_btn := Button.new()
	go_btn.text = "GO"
	go_btn.custom_minimum_size = Vector2(64, 36)
	go_btn.pressed.connect(go)
	transport.add_child(go_btn)
	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.pressed.connect(go_back)
	transport.add_child(back_btn)
	var halt_btn := Button.new()
	halt_btn.text = "Halt"
	halt_btn.pressed.connect(halt)
	transport.add_child(halt_btn)
	add_child(transport)

	cue_list = ItemList.new()
	cue_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cue_list.allow_reselect = true
	cue_list.item_selected.connect(_on_cue_selected)
	cue_list.item_activated.connect(func(idx: int): _fire(idx))
	add_child(cue_list)

	next_label = Label.new()
	add_child(next_label)

	add_child(HSeparator.new())

	# --- selected-cue editor ---
	var edit_grid := GridContainer.new()
	edit_grid.columns = 2
	edit_grid.add_theme_constant_override("h_separation", 8)
	edit_grid.add_theme_constant_override("v_separation", 4)

	edit_grid.add_child(_lbl("Label"))
	label_edit = LineEdit.new()
	label_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label_edit.text_changed.connect(_on_label_edited)
	edit_grid.add_child(label_edit)

	edit_grid.add_child(_lbl("Fade up (s)"))
	fade_up_spin = _fade_spin()
	fade_up_spin.value_changed.connect(func(v: float): _set_selected_fade(true, v))
	edit_grid.add_child(fade_up_spin)

	edit_grid.add_child(_lbl("Fade down (s)"))
	fade_down_spin = _fade_spin()
	fade_down_spin.value_changed.connect(func(v: float): _set_selected_fade(false, v))
	edit_grid.add_child(fade_down_spin)
	add_child(edit_grid)

	var edit_btns := HBoxContainer.new()
	edit_btns.add_theme_constant_override("separation", 6)
	var update_btn := Button.new()
	update_btn.text = "Update"
	update_btn.pressed.connect(update_cue)
	edit_btns.add_child(update_btn)
	var dup_btn := Button.new()
	dup_btn.text = "Duplicate"
	dup_btn.pressed.connect(duplicate_cue)
	edit_btns.add_child(dup_btn)
	var del_btn := Button.new()
	del_btn.text = "Delete"
	del_btn.pressed.connect(delete_cue)
	edit_btns.add_child(del_btn)
	add_child(edit_btns)

	add_child(HSeparator.new())

	# --- record ---
	var rec_row := HBoxContainer.new()
	rec_row.add_theme_constant_override("separation", 6)
	rec_row.add_child(_lbl("New cue fade (s)"))
	new_fade_spin = _fade_spin()
	new_fade_spin.value = 3.0
	rec_row.add_child(new_fade_spin)
	var rec_btn := Button.new()
	rec_btn.text = "Record Cue"
	rec_btn.pressed.connect(record_cue)
	rec_row.add_child(rec_btn)
	add_child(rec_row)

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status_label)

	ArtNet.fade_finished.connect(_on_fade_finished)
	_refresh_list()


# ---------------------------------------------------------------- HELPERS --

func _lbl(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _fade_spin() -> SpinBox:
	var s := SpinBox.new()
	s.min_value = 0.0
	s.max_value = 600.0
	s.step = 0.1
	s.value = 3.0
	s.custom_minimum_size = Vector2(70, 0)
	return s


func _selected_index() -> int:
	var sel := cue_list.get_selected_items()
	return sel[0] if sel.size() > 0 else -1


# ---------------------------------------------------------------- PLAYBACK --

func go() -> void:
	if cues.is_empty():
		return
	_fire(clampi(_next, 0, cues.size() - 1))


func go_back() -> void:
	if cues.is_empty():
		return
	var from_idx: int = _current if _current >= 0 else 0
	_fire(clampi(from_idx - 1, 0, cues.size() - 1))


func halt() -> void:
	ArtNet.stop_fade()
	status_label.text = "Halted."


func _fire(idx: int) -> void:
	if idx < 0 or idx >= cues.size():
		return
	var cue := cues[idx]
	var targets: Array = []
	for i in range(ArtNet.universe_count()):
		targets.append(cue.target_for(i))
	ArtNet.start_fade(targets, cue.fade_up, cue.fade_down)

	_current = idx
	_next = min(idx + 1, cues.size() - 1)
	_refresh_list()
	status_label.text = "GO — cue %d (%s), %.1fs / %.1fs" % [
		idx + 1, cue.label, cue.fade_up, cue.fade_down]


func _on_fade_finished() -> void:
	if _current >= 0 and _current < cues.size():
		status_label.text = "Cue %d complete." % (_current + 1)


# ----------------------------------------------------------------- EDITING --

func record_cue() -> void:
	var c := Cue.new("Cue %d" % (cues.size() + 1), new_fade_spin.value, new_fade_spin.value)
	c.capture()
	var at := _selected_index()
	var insert_at := cues.size() if at == -1 else at + 1
	cues.insert(insert_at, c)
	if _current >= insert_at:
		_current += 1
	_next = clampi(_next, 0, cues.size() - 1)
	_refresh_list()
	cue_list.select(insert_at)
	_on_cue_selected(insert_at)
	status_label.text = "Recorded cue %d." % (insert_at + 1)
	cues_changed.emit()


func update_cue() -> void:
	var at := _selected_index()
	if at == -1:
		return
	cues[at].capture()
	status_label.text = "Updated cue %d from live output." % (at + 1)
	cues_changed.emit()


func duplicate_cue() -> void:
	var at := _selected_index()
	if at == -1:
		return
	var c := Cue.from_dict(cues[at].to_dict())
	c.label += " copy"
	cues.insert(at + 1, c)
	if _current > at:
		_current += 1
	_refresh_list()
	cue_list.select(at + 1)
	_on_cue_selected(at + 1)
	cues_changed.emit()


func delete_cue() -> void:
	var at := _selected_index()
	if at == -1:
		return
	cues.remove_at(at)
	if _current == at:
		_current = -1
	elif _current > at:
		_current -= 1
	_next = clampi(_next, 0, max(cues.size() - 1, 0))
	_refresh_list()
	if not cues.is_empty():
		cue_list.select(min(at, cues.size() - 1))
		_on_cue_selected(min(at, cues.size() - 1))
	status_label.text = "Deleted a cue (%d left)." % cues.size()
	cues_changed.emit()


func _on_cue_selected(idx: int) -> void:
	if idx < 0 or idx >= cues.size():
		return
	_syncing = true
	label_edit.text = cues[idx].label
	fade_up_spin.value = cues[idx].fade_up
	fade_down_spin.value = cues[idx].fade_down
	_syncing = false


func _on_label_edited(text: String) -> void:
	if _syncing:
		return
	var i := _selected_index()
	if i == -1:
		return
	cues[i].label = text
	var keep := i
	_refresh_list()
	cue_list.select(keep)
	cues_changed.emit()


func _set_selected_fade(is_up: bool, v: float) -> void:
	if _syncing:
		return
	var i := _selected_index()
	if i == -1:
		return
	if is_up:
		cues[i].fade_up = v
	else:
		cues[i].fade_down = v
	var keep := i
	_refresh_list()
	cue_list.select(keep)
	cues_changed.emit()


func _refresh_list() -> void:
	var sel := _selected_index()
	cue_list.clear()
	for i in range(cues.size()):
		var c := cues[i]
		var marker := "> " if i == _current else "  "
		cue_list.add_item("%s%d  %s   %.1f/%.1fs" % [
			marker, i + 1, c.label, c.fade_up, c.fade_down])
	if sel >= 0 and sel < cue_list.item_count:
		cue_list.select(sel)
	if cues.is_empty():
		next_label.text = "No cues — dial a look, then Record Cue."
	else:
		next_label.text = "Next: cue %d" % (clampi(_next, 0, cues.size() - 1) + 1)


# ------------------------------------------------------- SERIALIZATION --

func to_dict() -> Dictionary:
	var arr: Array = []
	for c in cues:
		arr.append(c.to_dict())
	return {"cues": arr, "current": _current, "next": _next}


func from_dict(d: Dictionary) -> void:
	cues.clear()
	for e in d.get("cues", []):
		if e is Dictionary:
			cues.append(Cue.from_dict(e))
	_current = clampi(int(d.get("current", -1)), -1, cues.size() - 1)
	_next = clampi(int(d.get("next", 0)), 0, max(cues.size() - 1, 0))
	_refresh_list()
