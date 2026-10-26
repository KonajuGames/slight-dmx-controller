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

var _connection: Label
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
		+ "decks playing together are mixed — colour, dimmer and strobe highest-takes-precedence, pan / tilt averaged. " 		+ "A song without timelines gets temporary ones: on the beat at once, then a show generated from the song once it's analysed " 		+ "(saved with the show, marked orange in DJ Edit Mode's song list until you edit them)."
	add_child(hint)
	refresh()


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
		if d == null or d.path == "":
			row["state"].text = "empty"
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
