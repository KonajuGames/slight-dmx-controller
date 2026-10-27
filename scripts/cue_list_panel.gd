class_name CueListPanel
extends VBoxContainer
## The playback side of the console: an ordered list of cues you step
## through with GO, each crossfading every universe from the current
## output to the cue's stored look over its fade time.
##
## Recording captures the live DMX buffers (so dial a look with the
## fixture controls, then Record Cue). Cues are saved inside the show file.
##
## Cues track. With **Tracking** on, a recorded cue stores only the
## channels it *changes* from the look the earlier cues leave standing;
## everything else tracks through, and editing an upstream cue ripples
## down the list. A **block** cue (Tracking unticked for that cue) stores
## a full look and stops the ripple. Playback folds cues[0..n] together —
## blocks wipe first, tracking cues merge on top — so the fade target is
## always the complete standing look for that point in the list.
##
## A cue's **Delay** holds its fade back that long after GO; with
## **Follow** ticked, once its fade finishes (and its wait after that) the
## next cue GOes by itself, so a run of cues can play as a sequence. GO,
## Back or a Go-to while one's waiting takes over from it; Halt stops the
## fade and anything waiting. The bar under the transport shows the
## delay counting down, the fade's progress, then the follow's wait.

signal cues_changed

var cues: Array[Cue] = []
var _current := -1   # cue currently live (-1 = none)
var _next := 0       # cue GO will fire
var _delay_left := -1.0    # seconds until the live cue's fade starts (-1: not waiting)
var _follow_left := -1.0   # seconds until the follow GOes the next cue (-1: none)
var _fading := -1          # the cue whose fade is running (-1: none)
var tracking_enabled := true   # what Record Cue makes: tracking vs block

## Set by the shell: func(buffers: Array of PackedByteArray) — loads a
## cue's per-universe look into the fixture controls for editing.
var to_patch_cb := Callable()

# UI
var cue_list: ItemList
var next_label: Label
var label_edit: LineEdit
var fade_up_spin: SpinBox
var fade_down_spin: SpinBox
var new_fade_spin: SpinBox
var delay_spin: SpinBox
var follow_check: CheckBox
var follow_spin: SpinBox
var progress_bar: ProgressBar
var progress_label: Label
var track_check: CheckBox        # per-selected-cue: tracking vs block
var tracking_check: CheckBox     # global: mode for new recordings
var status_label: Label
var _syncing := false  # guard while pushing cue -> edit fields


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	custom_minimum_size = Vector2(300, 0)

	var title := Label.new()
	title.text = "Cue List"
	add_child(title)

	# --- transport ---
	var transport := _flow()
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

	# --- what's running: delay, fade, follow ---
	var prog_row := HBoxContainer.new()
	prog_row.add_theme_constant_override("separation", 8)
	progress_bar = ProgressBar.new()
	progress_bar.max_value = 1.0
	progress_bar.step = 0.0
	progress_bar.show_percentage = false
	progress_bar.custom_minimum_size = Vector2(120, 12)
	progress_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	progress_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	prog_row.add_child(progress_bar)
	progress_label = Label.new()
	progress_label.custom_minimum_size = Vector2(130, 0)
	prog_row.add_child(progress_label)
	add_child(prog_row)

	cue_list = ItemList.new()
	cue_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cue_list.custom_minimum_size = Vector2(0, 120)
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

	edit_grid.add_child(_lbl("Delay (s)"))
	delay_spin = _fade_spin()
	delay_spin.value = 0.0
	delay_spin.tooltip_text = "How long after GO this cue's fade starts."
	delay_spin.value_changed.connect(func(v: float): _set_selected_field("delay", v))
	edit_grid.add_child(delay_spin)

	edit_grid.add_child(_lbl("Follow"))
	var follow_row := _flow()
	follow_check = CheckBox.new()
	follow_check.text = "then GO next after"
	follow_check.tooltip_text = "When this cue's fade finishes, wait this long, then GO the next cue automatically."
	follow_check.toggled.connect(func(on: bool):
		follow_spin.editable = on
		_set_selected_field("follow", on))
	follow_row.add_child(follow_check)
	follow_spin = _fade_spin()
	follow_spin.value = 0.0
	follow_spin.suffix = "s"
	follow_spin.editable = false
	follow_spin.value_changed.connect(func(v: float): _set_selected_field("follow_wait", v))
	follow_row.add_child(follow_spin)
	edit_grid.add_child(follow_row)

	edit_grid.add_child(_lbl("Tracking"))
	track_check = CheckBox.new()
	track_check.text = "tracks from previous cue"
	track_check.tooltip_text = "On: this cue only stores what it changes.\nOff (block): it stores a full look and stops upstream edits tracking through."
	track_check.toggled.connect(_set_selected_tracking)
	edit_grid.add_child(track_check)
	add_child(edit_grid)

	var edit_btns := _flow()
	var to_patch_btn := Button.new()
	to_patch_btn.text = "Load to Patch"
	to_patch_btn.tooltip_text = "Set the fixture controls to this cue's look so you can tweak it, then Update."
	to_patch_btn.pressed.connect(load_selected_to_patch)
	edit_btns.add_child(to_patch_btn)
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
	var rec_row := _flow()
	rec_row.add_child(_lbl("New cue fade (s)"))
	new_fade_spin = _fade_spin()
	new_fade_spin.value = 3.0
	rec_row.add_child(new_fade_spin)
	var rec_btn := Button.new()
	rec_btn.text = "Record Cue"
	rec_btn.pressed.connect(record_cue)
	rec_row.add_child(rec_btn)
	tracking_check = CheckBox.new()
	tracking_check.text = "Tracking"
	tracking_check.button_pressed = tracking_enabled
	tracking_check.tooltip_text = "New cues store only what they change from the previous cues."
	tracking_check.toggled.connect(func(on: bool): tracking_enabled = on)
	rec_row.add_child(tracking_check)
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


## A horizontal row that wraps to the next line instead of overflowing.
func _flow(h: int = 6, v: int = 4) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", h)
	f.add_theme_constant_override("v_separation", v)
	return f


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


# --------------------------------------------------------------- TRACKING --

## Fold cues[0..last] into the standing look: one Dictionary per universe
## ({ "<channel>": int }, values may be 0). A block cue wipes the rig
## before applying its stored channels; a tracking cue merges its moves
## over whatever the earlier cues left.
func _fold(last: int) -> Array:
	var ucount := ArtNet.universe_count()
	var out: Array = []
	for _i in range(ucount):
		out.append({})
	for i in range(mini(last + 1, cues.size())):
		var c := cues[i]
		if not c.tracking:
			out = []
			for _j in range(ucount):
				out.append({})
		for u in range(ucount):
			if u >= c.levels.size():
				continue
			var d: Dictionary = c.levels[u]
			for k in d.keys():
				out[u][String(k)] = clampi(int(d[k]), 0, 255)
	return out


## The complete look cue `number` (1-based) leaves standing, as GO would
## (per universe {"<channel>": value}); [] if there's no such cue. For
## cue faders.
func standing_look(number: int) -> Array:
	if number < 1 or number > cues.size():
		return []
	return _fold(number - 1)


## Turn a folded state (Array of Dictionary) into fade targets (Array of
## 512-byte PackedByteArray), one per universe.
func _targets_from_state(state: Array) -> Array:
	var targets: Array = []
	for u in range(ArtNet.universe_count()):
		var buf := PackedByteArray()
		buf.resize(ArtNet.DMX_UNIVERSE_SIZE)
		var d: Dictionary = state[u] if u < state.size() else {}
		for k in d.keys():
			var c := int(k)
			if c >= 0 and c < buf.size():
				buf[c] = clampi(int(d[k]), 0, 255)
		targets.append(buf)
	return targets


# ---------------------------------------------------------------- PLAYBACK --

## 1-based number of the cue currently live (0 = none). For MIDI feedback.
func current_number() -> int:
	return _current + 1 if _current >= 0 else 0


func go() -> void:
	if cues.is_empty():
		return
	_fire(clampi(_next, 0, cues.size() - 1))


func go_back() -> void:
	if cues.is_empty():
		return
	var from_idx: int = _current if _current >= 0 else 0
	_fire(clampi(from_idx - 1, 0, cues.size() - 1))


## Jump straight to a 1-based cue number (used by MIDI / OSC triggers).
func go_to_number(n: int) -> void:
	if cues.is_empty():
		return
	_fire(clampi(n - 1, 0, cues.size() - 1))


## Stop the fade and anything waiting (a cue's delay, a follow).
func halt() -> void:
	ArtNet.stop_fade()
	_cancel_timers()
	status_label.text = "Halted."


func _cancel_timers() -> void:
	_delay_left = -1.0
	_follow_left = -1.0
	_fading = -1
	_update_progress()


func _fire(idx: int) -> void:
	if idx < 0 or idx >= cues.size():
		return
	var cue := cues[idx]
	_follow_left = -1.0              # this GO takes over from anything waiting
	_delay_left = -1.0
	_current = idx
	_next = min(idx + 1, cues.size() - 1)
	_refresh_list()
	var times := "%.1fs / %.1fs" % [cue.fade_up, cue.fade_down]
	if cue.delay > 0.0:
		times = "delay %.1fs, " % cue.delay + times
	status_label.text = "GO — cue %d (%s) [%s], %s" % [
		idx + 1, cue.label, ("track" if cue.tracking else "block"), times]
	if cue.delay > 0.0:
		_fading = -1                 # the last cue's fade runs on, but its end follows nothing
		_delay_left = cue.delay
	else:
		_start_fade(idx)
	_update_progress()


func _start_fade(idx: int) -> void:
	var cue := cues[idx]
	_fading = idx
	ArtNet.start_fade(_targets_from_state(_fold(idx)), cue.fade_up, cue.fade_down)


func _on_fade_finished() -> void:
	if _fading < 0 or _fading != _current or _current >= cues.size():
		return
	_fading = -1
	var cue := cues[_current]
	if cue.follow and _current < cues.size() - 1:
		_follow_left = cue.follow_wait      # GOes on the next advance(), even at 0
		status_label.text = "Cue %d complete — following on to cue %d." % [_current + 1, _current + 2]
	else:
		status_label.text = "Cue %d complete." % (_current + 1)


func _process(delta: float) -> void:
	advance(delta)


## Run the cue list's timers on by `delta` seconds: a delay ending starts
## its cue's fade, a follow's wait ending GOes the next cue.
func advance(delta: float) -> void:
	if _delay_left >= 0.0:
		_delay_left -= delta
		if _delay_left <= 0.0:
			_delay_left = -1.0
			if _current >= 0 and _current < cues.size():
				_start_fade(_current)
	elif _follow_left >= 0.0:
		_follow_left -= delta
		if _follow_left <= 0.0:
			_follow_left = -1.0
			if _current >= 0 and _current < cues.size() - 1:
				_fire(_current + 1)
	_update_progress()


## Whether a cue is waiting out its delay, or a follow its wait.
func is_waiting() -> bool:
	return _delay_left >= 0.0 or _follow_left >= 0.0


## The bar under the transport: the delay counting down, the fade's
## progress, the follow's wait.
func _update_progress() -> void:
	if progress_bar == null:
		return
	var text := ""
	var value := 0.0
	if _delay_left >= 0.0 and _current >= 0 and _current < cues.size():
		var d := cues[_current].delay
		value = 1.0 - _delay_left / d if d > 0.0 else 1.0
		text = "Delay %.1fs" % maxf(_delay_left, 0.0)
	elif _fading >= 0 and ArtNet.is_fading():
		value = ArtNet.fade_progress()
		text = "Cue %d  %d%%  %.1fs" % [_fading + 1, roundi(value * 100.0), ArtNet.fade_remaining()]
	elif _follow_left >= 0.0 and _current >= 0 and _current < cues.size():
		var w := cues[_current].follow_wait
		value = 1.0 - _follow_left / w if w > 0.0 else 1.0
		text = "Follow in %.1fs" % maxf(_follow_left, 0.0)
	elif _current >= 0:
		value = 1.0
	progress_bar.value = value
	progress_label.text = text


# ----------------------------------------------------------------- EDITING --

func record_cue() -> void:
	var at := _selected_index()
	var insert_at := cues.size() if at == -1 else at + 1
	var c := Cue.new("Cue %d" % (cues.size() + 1), new_fade_spin.value, new_fade_spin.value)
	c.tracking = tracking_enabled
	if c.tracking:
		c.capture_tracked(_fold(insert_at - 1))
	else:
		c.capture()
	cues.insert(insert_at, c)
	if _current >= insert_at:
		_current += 1
	_next = clampi(_next, 0, cues.size() - 1)
	_refresh_list()
	cue_list.select(insert_at)
	_on_cue_selected(insert_at)
	status_label.text = "Recorded cue %d (%s) — %d moves." % [
		insert_at + 1, ("tracking" if c.tracking else "block"), c.move_count()]
	cues_changed.emit()


## Push the selected cue's standing look into the fixture controls so it
## can be tweaked and re-recorded with Update.
func load_selected_to_patch() -> void:
	var at := _selected_index()
	if at == -1 or not to_patch_cb.is_valid():
		return
	to_patch_cb.call(_targets_from_state(_fold(at)))
	status_label.text = "Cue %d loaded into the patch — tweak the fixtures, then Update." % (at + 1)


func update_cue() -> void:
	var at := _selected_index()
	if at == -1:
		return
	if cues[at].tracking:
		cues[at].capture_tracked(_fold(at - 1))
	else:
		cues[at].capture()
	var keep := at
	_refresh_list()
	cue_list.select(keep)
	status_label.text = "Updated cue %d from live output (%s) — %d moves." % [
		at + 1, ("tracking" if cues[at].tracking else "block"), cues[at].move_count()]
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
		_cancel_timers()
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
	delay_spin.value = cues[idx].delay
	follow_check.button_pressed = cues[idx].follow
	follow_spin.value = cues[idx].follow_wait
	follow_spin.editable = cues[idx].follow
	track_check.button_pressed = cues[idx].tracking
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


## Flip the selected cue between tracking and block, rewriting its stored
## levels so the look it produces on stage doesn't change — only how it
## reacts to edits of the cues before it.
func _set_selected_tracking(on: bool) -> void:
	if _syncing:
		return
	var i := _selected_index()
	if i == -1 or cues[i].tracking == on:
		return
	var through := _fold(i)       # complete standing look at this cue
	var before := _fold(i - 1)    # look the earlier cues leave standing
	cues[i].tracking = on
	var new_levels: Array = []
	for u in range(ArtNet.universe_count()):
		var t: Dictionary = through[u] if u < through.size() else {}
		var b: Dictionary = before[u] if u < before.size() else {}
		var d := {}
		if on:
			for k in t.keys():
				if int(t[k]) != int(b.get(k, 0)):
					d[String(k)] = int(t[k])
			for k in b.keys():
				if not t.has(k) and int(b[k]) != 0:
					d[String(k)] = 0            # earlier cue's value, moved to 0
		else:
			for k in t.keys():
				if int(t[k]) != 0:
					d[String(k)] = int(t[k])
		new_levels.append(d)
	cues[i].levels = new_levels
	var keep := i
	_refresh_list()
	cue_list.select(keep)
	status_label.text = "Cue %d is now a %s cue." % [i + 1, ("tracking" if on else "block")]
	cues_changed.emit()


## Set one of the selected cue's timing fields ("delay", "follow",
## "follow_wait").
func _set_selected_field(field: String, v) -> void:
	if _syncing:
		return
	var i := _selected_index()
	if i == -1:
		return
	cues[i].set(field, v)
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
		var flag := "T" if c.tracking else "B"
		var timing := ""
		if c.delay > 0.0:
			timing += "  d%.1f" % c.delay
		if c.follow:
			timing += "  → %.1fs" % c.follow_wait
		cue_list.add_item("%s%d [%s] %s   %.1f/%.1fs%s" % [
			marker, i + 1, flag, c.label, c.fade_up, c.fade_down, timing])
	if sel >= 0 and sel < cue_list.item_count:
		cue_list.select(sel)
	if cues.is_empty():
		next_label.text = "No cues — dial a look, then Record Cue."
	else:
		var mode := "tracking" if tracking_enabled else "block"
		next_label.text = "Next: cue %d   (recording: %s)" % [
			clampi(_next, 0, cues.size() - 1) + 1, mode]


# ------------------------------------------------------- SERIALIZATION --

func to_dict() -> Dictionary:
	var arr: Array = []
	for c in cues:
		arr.append(c.to_dict())
	return {
		"cues": arr, "current": _current, "next": _next,
		"tracking": tracking_enabled,
	}


func from_dict(d: Dictionary) -> void:
	cues.clear()
	for e in d.get("cues", []):
		if e is Dictionary:
			cues.append(Cue.from_dict(e))
	_current = clampi(int(d.get("current", -1)), -1, cues.size() - 1)
	_next = clampi(int(d.get("next", 0)), 0, max(cues.size() - 1, 0))
	_cancel_timers()
	tracking_enabled = bool(d.get("tracking", true))
	if tracking_check:
		tracking_check.button_pressed = tracking_enabled
	_refresh_list()
