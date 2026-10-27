class_name PalettesPanel
extends VBoxContainer
## The console's Palettes tab: the show's colour, position and beam
## palettes (PaletteLibrary) as a grid of buttons per kind, like a desk's
## palette windows.
##
## Record (per kind) makes a palette from the live levels of the fixtures
## picked in Fixtures (all, or a group). Clicking a palette applies it to
## those fixtures (it sets their controls); recording a cue then links the
## cue to it. Right-click a palette to update it from the live levels
## (every cue using it changes), rename or delete it.

const _BTN := Vector2(112, 44)
const _DIM := Color(1, 1, 1, 0.55)

var library: PaletteLibrary
## Set by the shell: func() -> patched fixtures ({uid, u, start, profile,
## mode}); func() -> group names; func(name) -> the uids in that group;
## func(buffers) -> loads per-universe buffers into the fixture controls;
## func(id) -> how many cues use a palette; func(id) -> int, bakes a
## palette's values into the cues using it (before it's deleted).
var fixtures_provider := Callable()
var group_names_provider := Callable()
var group_members_provider := Callable()
var apply_cb := Callable()
var users_cb := Callable()
var bake_cb := Callable()

var _fixtures_option: OptionButton
var _grids: Array = []            # per kind: HFlowContainer
var _status: Label
var _menu: PopupMenu
var _menu_palette: PaletteLibrary.Palette

enum { M_UPDATE, M_RENAME, M_DELETE }


func _ready() -> void:
	add_theme_constant_override("separation", 8)

	var title := Label.new()
	title.text = "Palettes"
	add_child(title)

	var top := HFlowContainer.new()
	top.add_theme_constant_override("h_separation", 6)
	var fl := Label.new()
	fl.text = "Fixtures:"
	top.add_child(fl)
	_fixtures_option = OptionButton.new()
	_fixtures_option.tooltip_text = "Which fixtures Record captures and a palette is applied to"
	top.add_child(_fixtures_option)
	add_child(top)

	for kind in range(PaletteLibrary.KINDS.size()):
		add_child(HSeparator.new())
		var head := HFlowContainer.new()
		head.add_theme_constant_override("h_separation", 8)
		var kl := Label.new()
		kl.text = PaletteLibrary.KINDS[kind]
		kl.custom_minimum_size = Vector2(70, 0)
		head.add_child(kl)
		var rec := Button.new()
		rec.text = "Record %s" % PaletteLibrary.KINDS[kind]
		rec.tooltip_text = "A new %s palette from the fixtures' live %s channels (%s)" % [
			PaletteLibrary.KINDS[kind].to_lower(), PaletteLibrary.KINDS[kind].to_lower(),
			", ".join(PaletteLibrary.KIND_ROLES[kind]).to_lower().replace("_", " ")]
		rec.pressed.connect(record.bind(kind))
		head.add_child(rec)
		add_child(head)
		var grid := HFlowContainer.new()
		grid.add_theme_constant_override("h_separation", 6)
		grid.add_theme_constant_override("v_separation", 6)
		add_child(grid)
		_grids.append(grid)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	var hint := Label.new()
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = _DIM
	hint.text = "Set the fixtures the way you want, then Record. Click a palette to apply it; record a cue and the cue uses " \
		+ "the palette rather than the values, so updating the palette (right-click) changes every cue that uses it. " \
		+ "Cues using palettes are marked ◆ in the cue list."
	add_child(hint)

	_menu = PopupMenu.new()
	_menu.add_item("Update from Live", M_UPDATE)
	_menu.add_item("Rename…", M_RENAME)
	_menu.add_separator()
	_menu.add_item("Delete…", M_DELETE)
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)

	library.changed.connect(rebuild)
	refresh_fixture_options()
	rebuild()


## Refill Fixtures: all, then each group (keeping the pick).
func refresh_fixture_options() -> void:
	var keep := _fixtures_option.get_item_text(_fixtures_option.selected) if _fixtures_option.selected >= 0 else ""
	_fixtures_option.clear()
	_fixtures_option.add_item("All fixtures")
	var names: Array = group_names_provider.call() if group_names_provider.is_valid() else []
	for n in names:
		_fixtures_option.add_item(String(n))
	_fixtures_option.selected = 0
	for i in range(_fixtures_option.item_count):
		if _fixtures_option.get_item_text(i) == keep:
			_fixtures_option.selected = i


## The fixtures Fixtures picks.
func picked_fixtures() -> Array:
	var all: Array = fixtures_provider.call() if fixtures_provider.is_valid() else []
	if _fixtures_option.selected <= 0 or not group_members_provider.is_valid():
		return all
	var members: Array = group_members_provider.call(_fixtures_option.get_item_text(_fixtures_option.selected))
	return all.filter(func(fx): return members.has(String(fx["uid"])))


static func _bases() -> Array:
	var out: Array = []
	for i in range(ArtNet.universe_count()):
		out.append(ArtNet.get_universe(i).dmx_data)
	return out


## Record a new palette of `kind` from the picked fixtures' live levels.
func record(kind: int) -> PaletteLibrary.Palette:
	var n := library.of_kind(kind).size() + 1
	var p := library.record(kind, "%s %d" % [PaletteLibrary.KINDS[kind], n], picked_fixtures(), _bases())
	if p == null:
		_status.text = "None of those fixtures has %s channels." % PaletteLibrary.KINDS[kind].to_lower()
	else:
		_status.text = "Recorded %s for %d fixture%s." % [p.name, p.values.size(), "" if p.values.size() == 1 else "s"]
	return p


## Apply palette `p` to the picked fixtures it holds (their controls).
func apply(p: PaletteLibrary.Palette) -> void:
	var fixtures := picked_fixtures()
	if apply_cb.is_valid():
		apply_cb.call(library.applied(p, fixtures, _bases()))
	var n := fixtures.filter(func(fx): return p.values.has(String(fx["uid"]))).size()
	_status.text = "%s applied to %d fixture%s." % [p.name, n, "" if n == 1 else "s"] if n > 0 \
		else "%s holds none of those fixtures." % p.name


func update_from_live(p: PaletteLibrary.Palette) -> void:
	library.update(p, picked_fixtures(), _bases())
	var users: int = users_cb.call(p.id) if users_cb.is_valid() else 0
	_status.text = "Updated %s from the live levels — %d cue%s use%s it." % [
		p.name, users, "" if users == 1 else "s", "s" if users == 1 else ""]


## Delete palette `p`; the cues using it keep its values.
func delete(p: PaletteLibrary.Palette) -> void:
	var n: int = bake_cb.call(p.id) if bake_cb.is_valid() else 0
	library.remove(p)
	_status.text = "Deleted %s%s." % [p.name, (" — its values are now in the %d cue%s that used it" % [n, "" if n == 1 else "s"]) if n > 0 else ""]


func rebuild() -> void:
	if _grids.is_empty():
		return
	var fixtures: Array = fixtures_provider.call() if fixtures_provider.is_valid() else []
	for kind in range(_grids.size()):
		var grid: HFlowContainer = _grids[kind]
		for ch in grid.get_children():
			ch.queue_free()
		var list := library.of_kind(kind)
		if list.is_empty():
			var none := Label.new()
			none.text = "none yet"
			none.modulate = _DIM
			grid.add_child(none)
		for p in list:
			grid.add_child(_button(p, fixtures))


func _button(p: PaletteLibrary.Palette, fixtures: Array) -> Button:
	var b := Button.new()
	b.text = p.name
	b.custom_minimum_size = _BTN
	b.clip_text = true
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = "%s — click to apply, right-click to update, rename or delete. %d fixture%s." % [
		p.name, p.values.size(), "" if p.values.size() == 1 else "s"]
	var sw = library.swatch(p, fixtures)
	if sw != null:
		var c: Color = sw
		for state in ["normal", "hover", "pressed"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = c.darkened(0.15) if state == "normal" else c
			sb.set_corner_radius_all(3)
			sb.set_border_width_all(2 if state == "hover" else 0)
			sb.border_color = Color.WHITE
			b.add_theme_stylebox_override(state, sb)
		var dark := c.get_luminance() > 0.55
		for k in ["font_color", "font_hover_color", "font_pressed_color"]:
			b.add_theme_color_override(k, Color.BLACK if dark else Color.WHITE)
	b.pressed.connect(apply.bind(p))
	b.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
			_menu_palette = p
			_menu.position = Vector2i(get_screen_position() + get_local_mouse_position())
			_menu.popup())
	return b


func _on_menu(id: int) -> void:
	var p := _menu_palette
	if p == null:
		return
	match id:
		M_UPDATE:
			update_from_live(p)
		M_RENAME:
			_ask_name(p)
		M_DELETE:
			var users: int = users_cb.call(p.id) if users_cb.is_valid() else 0
			var dlg := ConfirmationDialog.new()
			dlg.title = "Delete Palette"
			dlg.dialog_text = "Delete %s?" % p.name + (
				"\n\n%d cue%s use%s it; they'll keep its values." % [users, "" if users == 1 else "s", "s" if users == 1 else ""]
				if users > 0 else "")
			dlg.ok_button_text = "Delete"
			add_child(dlg)
			dlg.confirmed.connect(func():
				dlg.queue_free()
				delete(p))
			dlg.canceled.connect(func(): dlg.queue_free())
			dlg.popup_centered()


func _ask_name(p: PaletteLibrary.Palette) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Rename Palette"
	var edit := LineEdit.new()
	edit.text = p.name
	edit.select_all_on_focus = true
	edit.custom_minimum_size = Vector2(240, 0)
	dlg.add_child(edit)
	dlg.register_text_enter(edit)
	add_child(dlg)
	dlg.confirmed.connect(func():
		if edit.text.strip_edges() != "":
			library.rename(p, edit.text.strip_edges())
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()
	edit.grab_focus()
