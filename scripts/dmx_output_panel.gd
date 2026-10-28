class_name DmxOutputPanel
extends MarginContainer
## "DMX Output" tab: a live grid of every universe's current output.
## Each cell shows the channel number (top, small) and its byte value
## (bottom, large); the cell's background brightness tracks the value
## so blackout vs. live channels are visible at a glance. A channel a
## fixture occupies is tinted with its model's colour (the same one as in
## the fixture list and the 3D Visualizer), so each fixture's footprint
## stands out.
##
## Read-only. Shows `ArtNetUniverse.output` -- the same post-effect,
## post-grand-master buffer the 3D visualizer and wire transmit use --
## kept current by the shell's existing 30 Hz `ArtNet.tick()` refresh.

const COLUMNS := 16
## How much of a fixture's model colour shows through a channel's grey.
const TINT := 0.5

class ChannelCell:
	var style: StyleBoxFlat
	var num_label: Label
	var value_label: Label
	var last_value := -1
	var tint = null  # Color of the fixture occupying this channel, or null

## The UniversePanels, one per universe (shared with the shell), whose
## patched fixtures tint the grid. Set before the panel enters the tree.
var panels: Array = []

var _uni_tabs: TabContainer
var _cells: Array = []  # Array[Array[ChannelCell]], one inner array per universe tab
var _built_universe_count := -1
var _patch_signature := []


func _ready() -> void:
	# Inset from the tab's edge by the shell (TabPadding.page()).
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	add_child(vb)

	var title := Label.new()
	title.text = "DMX Output"
	title.add_theme_font_size_override("font_size", 16)
	vb.add_child(title)

	_uni_tabs = TabContainer.new()
	_uni_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	TabPadding.pad_tabs(_uni_tabs)
	vb.add_child(_uni_tabs)

	_rebuild_tabs()


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	if ArtNet.universe_count() != _built_universe_count:
		_rebuild_tabs()
	_refresh_tints()
	for u in range(_cells.size()):
		_refresh_universe(u)


func _rebuild_tabs() -> void:
	for c in _uni_tabs.get_children():
		c.queue_free()
	_cells.clear()
	_patch_signature = []
	_built_universe_count = ArtNet.universe_count()
	for u in range(_built_universe_count):
		var grid := GridContainer.new()
		grid.columns = COLUMNS
		grid.add_theme_constant_override("h_separation", 4)
		grid.add_theme_constant_override("v_separation", 4)
		var cells: Array[ChannelCell] = []
		for ch in range(ArtNetUniverse.DMX_UNIVERSE_SIZE):
			cells.append(_make_cell(grid, ch))
		_cells.append(cells)
		var sc := ScrollContainer.new()
		sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sc.add_child(grid)
		_uni_tabs.add_child(sc)
		_uni_tabs.set_tab_title(u, "Universe %d" % (u + 1))


func _make_cell(grid: GridContainer, channel: int) -> ChannelCell:
	var cell := ChannelCell.new()

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(46, 42)
	cell.style = StyleBoxFlat.new()
	cell.style.bg_color = Color(0, 0, 0)
	cell.style.set_corner_radius_all(3)
	cell.style.content_margin_left = 2
	cell.style.content_margin_right = 2
	cell.style.content_margin_top = 2
	cell.style.content_margin_bottom = 2
	panel.add_theme_stylebox_override("panel", cell.style)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 0)
	panel.add_child(vb)

	cell.num_label = Label.new()
	cell.num_label.text = str(channel + 1)
	cell.num_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cell.num_label.add_theme_font_size_override("font_size", 9)
	vb.add_child(cell.num_label)

	cell.value_label = Label.new()
	cell.value_label.text = "0"
	cell.value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cell.value_label.add_theme_font_size_override("font_size", 18)
	vb.add_child(cell.value_label)

	grid.add_child(panel)
	return cell


## Re-tint the cells when the patch has changed: what each fixture is, where
## it starts and its mode, in every universe.
func _refresh_tints() -> void:
	var sig := []
	for p in panels:
		var fxs := []
		for fx in p.patched_fixtures:
			fxs.append([(fx["profile"] as FixtureProfile).full_name(), int(fx["start"]), int(fx.get("mode", 0))])
		sig.append(fxs)
	if sig == _patch_signature:
		return
	_patch_signature = sig
	var colours := tint_map(panels, _cells.size())
	for u in range(_cells.size()):
		var cells: Array = _cells[u]
		for ch in range(cells.size()):
			var cell: ChannelCell = cells[ch]
			cell.tint = colours[u].get(ch)
			cell.last_value = -1  # repaint


## Each universe's channel -> the model colour of the fixture occupying it
## (UniversePanel.model_colours()), one Dictionary per universe up to `n`.
## A later fixture wins a channel two overlap on.
static func tint_map(p_panels: Array, n: int) -> Array:
	var colours := UniversePanel.model_colours(p_panels)
	var out: Array = []
	for u in range(n):
		var m := {}
		if u < p_panels.size():
			for fx in p_panels[u].patched_fixtures:
				var profile: FixtureProfile = fx["profile"]
				var c: Color = colours[profile.full_name()]
				var start: int = fx["start"]
				for k in range(profile.channel_count(int(fx.get("mode", 0)))):
					m[start + k] = c
		out.append(m)
	return out


## A cell's background: grey by its value, with a fixture's colour mixed in.
static func cell_colour(v: int, tint) -> Color:
	var t := v / 255.0
	var grey := Color(t, t, t)
	if tint == null:
		return grey
	# Keep a hint of the colour at full too, rather than washing out to white.
	return grey.lerp((tint as Color).lerp(Color.WHITE, t * 0.8), TINT)


func _refresh_universe(u: int) -> void:
	var uni := ArtNet.get_universe(u)
	if uni == null:
		return
	var out := uni.output
	var cells: Array = _cells[u]
	for ch in range(cells.size()):
		var v: int = out[ch] if ch < out.size() else 0
		var cell: ChannelCell = cells[ch]
		if v == cell.last_value:
			continue
		cell.last_value = v
		var bg := cell_colour(v, cell.tint)
		cell.style.bg_color = bg
		var text_color := Color.WHITE if bg.get_luminance() < 0.5 else Color.BLACK
		cell.num_label.add_theme_color_override("font_color", text_color)
		cell.value_label.add_theme_color_override("font_color", text_color)
		cell.value_label.text = str(v)
