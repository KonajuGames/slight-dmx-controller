class_name TabPadding
extends RefCounted
## The one inset every tab page gets, so controls never sit flush against a
## tab container's edge and every tab looks the same. Use it for every new
## tab:
##
##   pad_tabs(tc)   a TabContainer whose pages are all ordinary panels: its
##                  panel style gets PAD content margins all round (the
##                  console's playback tabs, the universe tabs, ...)
##   page(content)  one page of a TabContainer that can't be padded as a
##                  whole because another of its pages is full-bleed (the
##                  right-hand tabs, where the 3D Visualizer runs edge to
##                  edge): `content` wrapped in a MarginContainer of PAD
##
## tests/tab_padding_test.gd checks every tab in the app is one or the
## other (or listed as full-bleed there).

const PAD := 8


static func pad_tabs(tc: TabContainer) -> void:
	var base := tc.get_theme_stylebox("panel")
	var sb: StyleBox = base.duplicate() if base != null else StyleBoxEmpty.new()
	sb.content_margin_left = PAD
	sb.content_margin_right = PAD
	sb.content_margin_top = PAD
	sb.content_margin_bottom = PAD
	tc.add_theme_stylebox_override("panel", sb)


static func page(content: Control) -> MarginContainer:
	var m := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, PAD)
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.size_flags_vertical = Control.SIZE_EXPAND_FILL
	m.add_child(content)
	return m


## Whether `tc` was given pad_tabs().
static func is_padded(tc: TabContainer) -> bool:
	if not tc.has_theme_stylebox_override("panel"):
		return false
	var sb := tc.get_theme_stylebox("panel")
	return sb.content_margin_left == PAD and sb.content_margin_right == PAD \
		and sb.content_margin_top == PAD and sb.content_margin_bottom == PAD


## Whether `c` is a page() wrapper.
static func is_page(c: Control) -> bool:
	if not c is MarginContainer:
		return false
	for side in ["left", "right", "top", "bottom"]:
		if c.get_theme_constant("margin_" + side) != PAD:
			return false
	return true
