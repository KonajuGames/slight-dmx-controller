class_name FadersPanel
extends VBoxContainer
## The console's Faders tab: the playback faders (FaderBank), one strip
## each — its name, the fader and its level, what it's on (a cue, a chase
## or a group, and which) and its MIDI mapping (Learn) — wrapping across
## the tab.

const _STRIP_W := 86
const _DIM := Color(1, 1, 1, 0.55)

var bank: FaderBank
## Set by the shell: func() -> number of cues; func() -> group names.
var cue_count_provider := Callable()
var group_names_provider := Callable()

var _strips: HFlowContainer
var _add_btn: Button
var _hint: Label
## Per strip: {slider, level, name, kind, target, learn}.
var _rows: Array = []
var _syncing := false


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	custom_minimum_size = Vector2(300, 0)

	var title := Label.new()
	title.text = "Playback Faders"
	add_child(title)

	var top := HFlowContainer.new()
	top.add_theme_constant_override("h_separation", 6)
	_add_btn = Button.new()
	_add_btn.text = "Add Fader"
	_add_btn.pressed.connect(func():
		# A new fader starts on cue 1, if there is one.
		if bank.add_fader() != null and not _targets(FaderBank.KIND_CUE).is_empty():
			bank.set_target(bank.faders.size() - 1, FaderBank.KIND_CUE, "1"))
	top.add_child(_add_btn)
	add_child(top)

	_strips = HFlowContainer.new()
	_strips.add_theme_constant_override("h_separation", 6)
	_strips.add_theme_constant_override("v_separation", 10)
	add_child(_strips)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.modulate = _DIM
	_hint.text = "A Cue fader brings that cue's look up as a submaster (its intensity scaled by the fader, highest wins). " \
		+ "A Chase fader runs the chase while it's up, at the fader's intensity. " \
		+ "A Group fader is a group master: it scales the group's intensity down from full. " \
		+ "Learn, then move a fader or knob on a MIDI controller, to control it from there."
	add_child(_hint)

	bank.faders_changed.connect(rebuild)
	bank.levels_changed.connect(sync_levels)
	bank.learned.connect(func(_i): sync_learn())
	rebuild()


func _chase_names() -> Array:
	var out: Array = []
	for c in Fx.chases:
		out.append(c.name)
	return out


## What a fader of `kind` can be put on: [label, target] pairs.
func _targets(kind: int) -> Array:
	var out: Array = []
	match kind:
		FaderBank.KIND_CUE:
			var n: int = cue_count_provider.call() if cue_count_provider.is_valid() else 0
			for i in range(n):
				out.append(["Cue %d" % (i + 1), str(i + 1)])
		FaderBank.KIND_CHASE:
			for name_ in _chase_names():
				out.append([name_, name_])
		FaderBank.KIND_GROUP:
			var names: Array = group_names_provider.call() if group_names_provider.is_valid() else []
			for name_ in names:
				out.append([String(name_), String(name_)])
	return out


## Build a strip per fader.
func rebuild() -> void:
	if _strips == null:
		return
	for ch in _strips.get_children():
		ch.queue_free()
	_rows.clear()
	for i in range(bank.faders.size()):
		_strips.add_child(_build_strip(i))
	_add_btn.disabled = bank.faders.size() >= FaderBank.MAX_FADERS
	sync_levels()
	sync_learn()


## The cue / chase / group lists changed: refill the target pickers.
func refresh_targets() -> void:
	_syncing = true
	for i in range(_rows.size()):
		_fill_targets(i)
	_syncing = false


func _build_strip(i: int) -> Control:
	var f: FaderBank.Fader = bank.faders[i]
	var panel := PanelContainer.new()
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.custom_minimum_size = Vector2(_STRIP_W, 0)
	panel.add_child(col)

	var head := HBoxContainer.new()
	var name_edit := LineEdit.new()
	name_edit.text = f.name
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.custom_minimum_size = Vector2(40, 0)
	name_edit.text_changed.connect(func(t: String): f.name = t)
	head.add_child(name_edit)
	var del := Button.new()
	del.text = "✕"
	del.flat = true
	del.tooltip_text = "Remove this fader"
	del.pressed.connect(func(): bank.remove_fader(i))
	head.add_child(del)
	col.add_child(head)

	var slider := VSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.001
	slider.custom_minimum_size = Vector2(0, 150)
	slider.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	slider.value_changed.connect(func(v: float):
		if not _syncing:
			bank.set_level(i, v))
	col.add_child(slider)

	var level := Label.new()
	level.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(level)

	var kind := OptionButton.new()
	for k in FaderBank.KINDS:
		kind.add_item(k)
	kind.selected = f.kind
	kind.fit_to_longest_item = false
	kind.item_selected.connect(func(k: int):
		var t: Array = _targets(k)
		bank.set_target(i, k, String(t[0][1]) if not t.is_empty() else ""))
	col.add_child(kind)

	var target := OptionButton.new()
	target.fit_to_longest_item = false
	target.clip_text = true
	target.custom_minimum_size = Vector2(_STRIP_W, 0)
	target.item_selected.connect(func(idx: int):
		if _syncing:
			return
		var meta = target.get_item_metadata(idx)
		if meta != null:
			bank.set_target(i, f.kind, String(meta)))
	col.add_child(target)

	var learn := Button.new()
	learn.clip_text = true
	learn.custom_minimum_size = Vector2(_STRIP_W, 0)
	learn.tooltip_text = "MIDI Learn: click, then move a fader or knob on your controller. Right-click to forget the mapping."
	learn.pressed.connect(func():
		bank.learn(-1 if bank.is_learning(i) else i)
		sync_learn())
	learn.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
			f.midi_cc = -1
			f.midi_channel = -1
			sync_learn())
	col.add_child(learn)

	_rows.append({"slider": slider, "level": level, "name": name_edit, "kind": kind,
		"target": target, "learn": learn})
	_fill_targets(i)
	return panel


func _fill_targets(i: int) -> void:
	var f: FaderBank.Fader = bank.faders[i]
	var target: OptionButton = _rows[i]["target"]
	target.clear()
	var found := -1
	for pair in _targets(f.kind):
		target.add_item(String(pair[0]))
		target.set_item_metadata(target.item_count - 1, pair[1])
		if String(pair[1]).to_lower() == f.target.to_lower():
			found = target.item_count - 1
	if found < 0 and f.target != "":
		# Gone from the show (or not made yet): kept, marked missing.
		target.add_item("%s (missing)" % f.target)
		target.set_item_metadata(target.item_count - 1, f.target)
		found = target.item_count - 1
	if found < 0:
		# Nothing picked yet (or nothing to pick).
		target.add_item("(pick…)" if target.item_count > 0 else "(none to pick)")
		target.set_item_disabled(target.item_count - 1, true)
		found = target.item_count - 1
	target.selected = found


## Follow the faders' levels (moved by MIDI, or loaded).
func sync_levels() -> void:
	_syncing = true
	for i in range(mini(_rows.size(), bank.faders.size())):
		var f: FaderBank.Fader = bank.faders[i]
		_rows[i]["slider"].set_value_no_signal(f.level)
		_rows[i]["level"].text = "%d%%" % roundi(f.level * 100.0)
	_syncing = false


func sync_learn() -> void:
	for i in range(mini(_rows.size(), bank.faders.size())):
		var f: FaderBank.Fader = bank.faders[i]
		var b: Button = _rows[i]["learn"]
		if bank.is_learning(i):
			b.text = "Move it…"
		elif f.midi_cc >= 0:
			b.text = f.midi_text()
		else:
			b.text = "Learn"
