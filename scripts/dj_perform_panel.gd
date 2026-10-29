class_name DjPerformPanel
extends VBoxContainer
## DJ Perform Mode's view: the OS2L connection with VirtualDJ and, per
## deck, the song on it, whether it's playing, where it is and whether its
## lighting timelines are loaded (and so playing into the lights). The
## work is the DjPerformer's; this just shows it, refreshed a few times a
## second.

const _REFRESH := 0.1
const _DIM := Color(1, 1, 1, 0.5)
const _LIVE := Color(0.55, 0.85, 0.55)

var performer: DjPerformer
## The live flashes (set by the shell before this is added to the tree).
var flash: LiveFlash

var _connection: Label
var _flash_btns: Array[Button] = []
var _latch: CheckButton
var _colour: ColorPickerButton
var _rows: Array = []        # per deck: {state, song, position, timelines} Labels
var _since := 0.0


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 10)

	var title := Label.new()
	title.text = "DJ Perform Mode"
	title.add_theme_font_size_override("font_size", 20)
	add_child(title)

	_connection = Label.new()
	_connection.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_connection)

	if flash != null:
		add_child(_build_flash_bar())

	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 8)
	add_child(grid)
	for h in ["Deck", "State", "Song", "Position", "Timelines"]:
		var l := Label.new()
		l.text = h
		l.modulate = _DIM
		grid.add_child(l)
	for i in range(DjPerformer.DECKS):
		var num := Label.new()
		num.text = str(i + 1)
		grid.add_child(num)
		var row := {}
		for k in ["state", "song", "position", "timelines"]:
			var l := Label.new()
			if k == "song":
				l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
				l.custom_minimum_size = Vector2(240, 0)
			grid.add_child(l)
			row[k] = l
		_rows.append(row)

	var hint := Label.new()
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = _DIM
	hint.text = "VirtualDJ finds sLight over the network (OS2L, advertised as \"sLight\"), or point its os2lDirectIp option at this machine. " \
		+ "A deck's lighting timelines (from DJ Edit Mode, saved with the show) play into the lights while it's playing with its volume up; " \
		+ "decks playing together are mixed — colour, dimmer and strobe highest-takes-precedence, pan / tilt averaged. " 		+ "A song without timelines gets temporary ones: on the beat at once, then a show generated from the song once it's analysed " 		+ "(saved with the show, marked orange in DJ Edit Mode's song list until you edit them). " \
		+ "The Live buttons (or B / S / W / C held down, or MIDI / OSC pads) flash over everything playing while held; with Latch on they stay on until pressed again."
	add_child(hint)
	refresh()


## The live flashes: a big button each (held, or toggled with Latch), the
## Colour flash's colour and the Latch switch.
func _build_flash_bar() -> Control:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 8)
	row.add_theme_constant_override("v_separation", 6)
	var lbl := Label.new()
	lbl.text = "Live:"
	row.add_child(lbl)
	for kind in range(LiveFlash.NAMES.size()):
		var b := Button.new()
		b.text = "%s (%s)" % [LiveFlash.NAMES[kind], OS.get_keycode_string(LiveFlash.KEYS[kind])]
		b.custom_minimum_size = Vector2(120, 44)
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = "Hold for %s over everything playing (or press %s). With Latch on, click to turn it on and again to turn it off." % [
			LiveFlash.NAMES[kind].to_lower(), OS.get_keycode_string(LiveFlash.KEYS[kind])]
		b.button_down.connect(func(): flash.press(kind))
		b.button_up.connect(func(): flash.release(kind))
		row.add_child(b)
		_flash_btns.append(b)
	_colour = ColorPickerButton.new()
	_colour.color = flash.colour
	_colour.edit_alpha = false
	_colour.custom_minimum_size = Vector2(44, 44)
	_colour.focus_mode = Control.FOCUS_NONE
	_colour.tooltip_text = "The Colour flash's colour"
	_colour.color_changed.connect(func(c: Color): flash.colour = c)
	row.add_child(_colour)
	_latch = CheckButton.new()
	_latch.text = "Latch"
	_latch.focus_mode = Control.FOCUS_NONE
	_latch.tooltip_text = "Flashes stay on when clicked, until clicked again. Turning Latch off lets go of them all."
	_latch.button_pressed = flash.latch
	_latch.toggled.connect(func(on: bool):
		flash.latch = on
		if not on:
			flash.clear())
	row.add_child(_latch)
	flash.changed.connect(sync_flash)
	sync_flash()
	return row


## Light the buttons of the flashes that are on; match the colour and
## Latch to the flashes' settings (after a show load).
func sync_flash() -> void:
	if flash == null or _latch == null:
		return
	for kind in range(_flash_btns.size()):
		var b := _flash_btns[kind]
		if flash.is_on(kind):
			var sb := StyleBoxFlat.new()
			sb.bg_color = _FLASH_ON[kind] if kind != LiveFlash.COLOUR else flash.colour
			sb.set_corner_radius_all(3)
			for state in ["normal", "hover", "pressed", "hover_pressed"]:
				b.add_theme_stylebox_override(state, sb)
			var dark := sb.bg_color.get_luminance() > 0.6
			for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
				b.add_theme_color_override(c, Color.BLACK if dark else Color.WHITE)
		else:
			for state in ["normal", "hover", "pressed", "hover_pressed"]:
				b.remove_theme_stylebox_override(state)
			for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
				b.remove_theme_color_override(c)
	_colour.color = flash.colour
	_latch.set_pressed_no_signal(flash.latch)


## A lit flash button's colour (Colour's is its own).
const _FLASH_ON := [Color(0.85, 0.3, 0.2), Color(0.8, 0.85, 1.0), Color(0.95, 0.95, 0.95), Color.RED]


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_since += delta
	if _since >= _REFRESH:
		_since = 0.0
		refresh()


## Show the performer's current state.
func refresh() -> void:
	if _connection == null:
		return
	if performer == null or not performer.is_active():
		_connection.text = "OS2L: off"
	else:
		var parts := PackedStringArray(["OS2L: " + performer.status()])
		var adv := performer.advertising_status()
		if adv != "":
			parts.append(adv)
		var n := performer.client_count()
		parts.append("VirtualDJ connected" if n == 1 else ("%d clients connected" % n if n > 1 else "waiting for VirtualDJ"))
		_connection.text = "  ·  ".join(parts)
	for i in range(_rows.size()):
		var row: Dictionary = _rows[i]
		var d: DjPerformer.Deck = performer.deck(i + 1) if performer != null else null
		if d == null or d.hidden or d.path == "":
			row["state"].text = "not in the skin" if d != null and d.hidden else "empty"
			row["song"].text = ""
			row["position"].text = ""
			row["timelines"].text = ""
			row["state"].modulate = _DIM
			continue
		var silent: bool = d.level != null and float(d.level) <= DjPerformer.SILENT_LEVEL
		row["state"].text = ("playing" + (" (muted)" if silent else "")) if d.playing else "paused"
		row["state"].modulate = _LIVE if d.live() else Color.WHITE
		row["song"].text = d.path.get_file().get_basename()
		row["song"].tooltip_text = d.path
		row["position"].text = _fmt(d.position())
		row["timelines"].text = timelines_text(d)
		row["timelines"].modulate = _LIVE if d.live() else Color.WHITE


## What the Timelines column says for a deck.
static func timelines_text(d: DjPerformer.Deck) -> String:
	match d.load_state:
		DjPerformer.Load.LOADING:
			return "generating…" if d.temporary else "loading…"
		DjPerformer.Load.LOADED:
			var n := d.tracks.size()
			var text := ("playing" if d.live() else "ready") + " (%d track%s" % [n, "" if n == 1 else "s"]
			if d.analysing:
				return text + ", temporary: on the beat only while the song's analysed — %d%%)" % roundi(d.progress * 100.0)
			text += ", temporary)" if d.temporary else ")"
			return text + (" — " + d.note if d.note != "" else "")
		DjPerformer.Load.NO_TIMELINES:
			return "none for this song" + (" (couldn't generate: %s)" % d.note if d.note != "" else "")
		DjPerformer.Load.NO_FOLDER:
			return "show not saved (no timelines folder)"
	return ""


static func _fmt(t: float) -> String:
	var s := int(maxf(t, 0.0))
	return "%d:%02d" % [s / 60, s % 60]
