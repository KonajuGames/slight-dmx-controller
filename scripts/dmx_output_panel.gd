class_name DmxOutputPanel
extends MarginContainer
## "DMX Output" tab: a live grid of every universe's current output.
## Each cell shows the channel number (top, small) and its byte value
## (bottom, large); the cell's background brightness tracks the value
## so blackout vs. live channels are visible at a glance.
##
## Read-only. Shows `ArtNetUniverse.output` -- the same post-effect,
## post-grand-master buffer the 3D visualizer and wire transmit use --
## kept current by the shell's existing 30 Hz `ArtNet.tick()` refresh.

const COLUMNS := 16

class ChannelCell:
	var style: StyleBoxFlat
	var num_label: Label
	var value_label: Label
	var last_value := -1

var _uni_tabs: TabContainer
var _cells: Array = []  # Array[Array[ChannelCell]], one inner array per universe tab
var _built_universe_count := -1


func _ready() -> void:
	for side in ["left", "right", "top", "bottom"]:
		add_theme_constant_override("margin_" + side, 8)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	add_child(vb)

	var title := Label.new()
	title.text = "DMX Output"
	title.add_theme_font_size_override("font_size", 16)
	vb.add_child(title)

	_uni_tabs = TabContainer.new()
	_uni_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_uni_tabs)

	_rebuild_tabs()


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	if ArtNet.universe_count() != _built_universe_count:
		_rebuild_tabs()
	for u in range(_cells.size()):
		_refresh_universe(u)


func _rebuild_tabs() -> void:
	for c in _uni_tabs.get_children():
		c.queue_free()
	_cells.clear()
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
		var t := v / 255.0
		cell.style.bg_color = Color(t, t, t)
		var text_color := Color.WHITE if t < 0.5 else Color.BLACK
		cell.num_label.add_theme_color_override("font_color", text_color)
		cell.value_label.add_theme_color_override("font_color", text_color)
		cell.value_label.text = str(v)
