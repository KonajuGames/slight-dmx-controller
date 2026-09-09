class_name UniversePanel
extends VBoxContainer
## One universe's control surface — a tab in the main window. Owns an
## ArtNetUniverse sender plus its own fixture patch. The shell
## (dmx_controller.gd) holds the shared profile list, the grand master,
## the Sending toggle, and whole-show save/load.
##
## Before adding this to the tree, the shell sets `sender`,
## `available_profiles` and `profile_action_cb`; `_ready` then builds
## the UI.

const CHANNEL_MAX := 512

## Channel roles the per-fixture virtual dimmer scales.
const INTENSITY_ROLES := ["RED", "GREEN", "BLUE", "WHITE", "AMBER", "UV"]

## Emitted when a fixture is added or removed by the user (so the shell
## can refresh fixture-group membership).
signal patch_changed

var sender: ArtNetUniverse
var available_profiles: Array = []       # shared reference, owned by the shell
## Shell handler: func(action: String, profile) where action is
## "new" (profile null), "edit", or "delete".
var profile_action_cb := Callable()

var patched_fixtures: Array = []
var _next_fixture_id := 0

# UI refs
var ip_edit: LineEdit
var port_spin: SpinBox
var artnet_uni_spin: SpinBox
var output_option: OptionButton
var sacn_row: HFlowContainer
var sacn_priority_spin: SpinBox
var sacn_ip_edit: LineEdit
var usb_row: HFlowContainer
var usb_device_option: OptionButton
var usb_mode_option: OptionButton
var _usb_devices: Array = []
var status_label: Label
var rgb_start_spin: SpinBox
var rgb_picker: ColorPickerButton
var profile_option: OptionButton
var mode_option: OptionButton
var fixture_name_edit: LineEdit
var fixture_start_spin: SpinBox
var fixtures_vbox: VBoxContainer


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	add_child(_build_connection_row())
	add_child(_build_rgb_row())
	add_child(_build_action_row())
	add_child(HSeparator.new())
	add_child(_build_fixture_patch_section())

	populate_profile_option()
	apply_connection()


# ---------------------------------------------------------------- HELPERS --

func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _centered_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


## A horizontal row that wraps its children to the next line instead of
## overflowing the right edge when the window is narrow.
func _flow(h: int = 8, v: int = 4) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", h)
	f.add_theme_constant_override("v_separation", v)
	return f


func set_status(text: String) -> void:
	if status_label:
		status_label.text = text


# ---------------------------------------------------- SLOT ICONS --
# Small textures drawn for colour-wheel / gobo dropdown items.

const _ICON_SIZE := 22


## The dropdown icon for one range slot, or null for a plain text item.
func _slot_icon(role: String, r: Dictionary, index: int) -> Texture2D:
	var explicit := String(r.get("color", ""))

	# A real imported picture (e.g. a GDTF gobo) beats anything drawn.
	var img_b64 := String(r.get("image", ""))
	if img_b64 != "":
		var tex := _decode_slot_image(img_b64)
		if tex:
			return tex

	if role == "GOBO":
		var lbl := String(r["label"]).to_lower()
		var is_open := "open" in lbl or "none" in lbl or "no gobo" in lbl
		return _gobo_texture(index, is_open)
	if role == "COLOR_WHEEL" or explicit != "":
		return _swatch_texture(_slot_color(String(r["label"]), explicit))
	return null


## Decode a base64 PNG into an icon-sized, circular-masked texture.
func _decode_slot_image(b64: String) -> Texture2D:
	var bytes := Marshalls.base64_to_raw(b64)
	if bytes.is_empty():
		return null
	var src := Image.new()
	if src.load_png_from_buffer(bytes) != OK:
		return null

	var s := _ICON_SIZE
	var fitted := src
	var big := maxi(src.get_width(), src.get_height())
	if big != s:
		var sc := float(s) / float(maxi(big, 1))
		fitted = src.duplicate()
		fitted.resize(maxi(1, int(src.get_width() * sc)), maxi(1, int(src.get_height() * sc)),
			Image.INTERPOLATE_BILINEAR)
	if fitted.get_format() != Image.FORMAT_RGBA8:
		fitted.convert(Image.FORMAT_RGBA8)

	var out := Image.create_empty(s, s, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))
	var ox := (s - fitted.get_width()) / 2
	var oy := (s - fitted.get_height()) / 2
	var c := (s - 1) / 2.0
	var rad := c - 0.5
	for y in range(fitted.get_height()):
		for x in range(fitted.get_width()):
			var px := ox + x
			var py := oy + y
			if px < 0 or py < 0 or px >= s or py >= s:
				continue
			var col := fitted.get_pixel(x, y)
			var d := Vector2(px - c, py - c).length()
			if d > rad:
				col.a = 0.0
			elif d > rad - 1.2:
				col.a *= rad - d
			out.set_pixel(px, py, col)
	return ImageTexture.create_from_image(out)


## Resolve a swatch colour: an explicit HTML/named colour if given, else
## guessed from the label's words (so "Deep Red", "Open / white" work).
func _slot_color(label: String, explicit: String) -> Color:
	if explicit != "":
		return Color.from_string(explicit, Color(0.8, 0.8, 0.8))
	var low := label.to_lower()
	if "open" in low or "white" in low or "none" in low:
		return Color(1, 1, 1)
	if "uv" in low or "congo" in low:
		return Color(0.35, 0.12, 0.72)
	for w in low.replace("/", " ").replace("-", " ").split(" ", false):
		var c := Color.from_string(w, Color.TRANSPARENT)
		if c != Color.TRANSPARENT:
			return c
	return Color(0.8, 0.8, 0.8)


func _swatch_texture(col: Color) -> Texture2D:
	var s := _ICON_SIZE
	var img := Image.create_empty(s, s, false, Image.FORMAT_RGBA8)
	var border := Color(0.15, 0.15, 0.15)
	for y in range(s):
		for x in range(s):
			var edge := x == 0 or y == 0 or x == s - 1 or y == s - 1
			img.set_pixel(x, y, border if edge else col)
	return ImageTexture.create_from_image(img)


## A schematic gobo pattern, chosen by the slot's position in the list.
func _gobo_texture(index: int, is_open: bool) -> Texture2D:
	var s := _ICON_SIZE
	var img := Image.create_empty(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := (s - 1) / 2.0
	var rad := c - 1.0
	var lit := Color(0.95, 0.95, 0.95)
	var pat := 0 if is_open else 1 + (index % 6)
	var rng := RandomNumberGenerator.new()
	rng.seed = index * 1013904223 + 1

	for y in range(s):
		for x in range(s):
			var dx := x - c
			var dy := y - c
			var dist := sqrt(dx * dx + dy * dy)
			if dist > rad:
				continue
			var on := dist >= rad - 1.6  # circle outline, always
			if not on:
				var ang := atan2(dy, dx)
				match pat:
					1:  # dots
						on = int(roundi(dx / 4.0)) % 2 == 0 and int(roundi(dy / 4.0)) % 2 == 0
					2:  # spokes
						on = fmod(absf(ang), PI / 3.0) < 0.30
					3:  # bars
						on = int(floori(dy / 2.6)) % 2 == 0
					4:  # concentric rings
						on = int(roundi(dist / 3.0)) % 2 == 0
					5:  # cross
						on = absf(dx) < 1.6 or absf(dy) < 1.6
					6:  # breakup
						on = rng.randf() < 0.30
			if on:
				img.set_pixel(x, y, lit)
	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------- UI BUILD --

func _build_connection_row() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)

	var row := _flow()

	row.add_child(_label("IP:"))
	ip_edit = LineEdit.new()
	ip_edit.text = sender.target_ip
	ip_edit.custom_minimum_size = Vector2(120, 0)
	row.add_child(ip_edit)

	row.add_child(_label("Port:"))
	port_spin = SpinBox.new()
	port_spin.min_value = 1
	port_spin.max_value = 65535
	port_spin.value = sender.target_port
	row.add_child(port_spin)

	row.add_child(_label("Art-Net universe:"))
	artnet_uni_spin = SpinBox.new()
	artnet_uni_spin.min_value = 0
	artnet_uni_spin.max_value = 32767
	artnet_uni_spin.value = sender.artnet_universe
	row.add_child(artnet_uni_spin)

	row.add_child(_label("Output:"))
	output_option = OptionButton.new()
	output_option.add_item("Art-Net")   # OUT_ARTNET
	output_option.add_item("sACN")      # OUT_SACN
	output_option.add_item("USB DMX")   # OUT_USB
	output_option.set_item_disabled(2, not UsbDmx.available)
	if not UsbDmx.available:
		output_option.set_item_tooltip(2, "Build addons/usb_dmx — see BUILD.md")
	output_option.item_selected.connect(func(_i): _sync_output_ui())
	row.add_child(output_option)

	var apply_btn := Button.new()
	apply_btn.text = "Apply Connection"
	apply_btn.pressed.connect(apply_connection)
	row.add_child(apply_btn)

	status_label = _label("")
	row.add_child(status_label)

	col.add_child(row)

	# Extra row for "sACN": priority + optional unicast target.
	sacn_row = _flow()
	sacn_row.add_child(_label("Priority:"))
	sacn_priority_spin = SpinBox.new()
	sacn_priority_spin.min_value = 0
	sacn_priority_spin.max_value = 200
	sacn_priority_spin.value = sender.sacn_priority
	sacn_row.add_child(sacn_priority_spin)
	sacn_row.add_child(_label("Unicast IP (blank = multicast):"))
	sacn_ip_edit = LineEdit.new()
	sacn_ip_edit.placeholder_text = "239.255.x.x"
	sacn_ip_edit.custom_minimum_size = Vector2(130, 0)
	sacn_ip_edit.text = sender.sacn_unicast_ip
	sacn_row.add_child(sacn_ip_edit)
	col.add_child(sacn_row)

	# Extra row for "USB DMX": device + interface type.
	usb_row = _flow()
	usb_row.add_child(_label("Device:"))
	usb_device_option = OptionButton.new()
	usb_device_option.custom_minimum_size = Vector2(240, 0)
	usb_row.add_child(usb_device_option)
	usb_row.add_child(_label("Interface:"))
	usb_mode_option = OptionButton.new()
	for n in UsbDmx.MODE_NAMES:
		usb_mode_option.add_item(n)
	usb_row.add_child(usb_mode_option)
	var rescan := Button.new()
	rescan.text = "Rescan"
	rescan.pressed.connect(_rescan_usb)
	usb_row.add_child(rescan)
	col.add_child(usb_row)

	_rescan_usb()
	_sync_output_ui()
	return col


func _sync_output_ui() -> void:
	sacn_row.visible = output_option.selected == ArtNetUniverse.OUT_SACN
	usb_row.visible = output_option.selected == ArtNetUniverse.OUT_USB


func _rescan_usb() -> void:
	_usb_devices = UsbDmx.list_devices()
	var keep: int = usb_device_option.selected
	usb_device_option.clear()
	if _usb_devices.is_empty():
		usb_device_option.add_item("(no USB DMX interfaces found)" if UsbDmx.available
			else "(USB DMX extension not built)")
		usb_device_option.disabled = true
		return
	usb_device_option.disabled = false
	for d in _usb_devices:
		usb_device_option.add_item("%s  (%s)" % [d["description"], d["serial"]])
	if keep >= 0 and keep < _usb_devices.size():
		usb_device_option.selected = keep


func _build_rgb_row() -> Control:
	var row := _flow()
	row.add_child(_label("Quick RGB channels — start channel:"))
	rgb_start_spin = SpinBox.new()
	rgb_start_spin.min_value = 1
	rgb_start_spin.max_value = CHANNEL_MAX - 2
	rgb_start_spin.value = 1
	row.add_child(rgb_start_spin)

	rgb_picker = ColorPickerButton.new()
	rgb_picker.color = Color.WHITE
	rgb_picker.custom_minimum_size = Vector2(60, 24)
	rgb_picker.color_changed.connect(_on_rgb_color_changed)
	row.add_child(rgb_picker)

	return row


func _build_action_row() -> Control:
	var row := _flow()

	var blackout := Button.new()
	blackout.text = "Blackout Universe"
	blackout.pressed.connect(blackout_universe)
	row.add_child(blackout)

	var full := Button.new()
	full.text = "Universe Full"
	full.pressed.connect(full_universe)
	row.add_child(full)

	return row


func _build_fixture_patch_section() -> Control:
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL

	outer.add_child(_label("Fixture Patch"))

	var add_row := _flow()

	add_row.add_child(_label("Profile:"))
	profile_option = OptionButton.new()
	profile_option.custom_minimum_size = Vector2(180, 0)
	profile_option.item_selected.connect(func(_i: int): populate_mode_option())
	add_row.add_child(profile_option)

	add_row.add_child(_label("Mode:"))
	mode_option = OptionButton.new()
	mode_option.custom_minimum_size = Vector2(120, 0)
	add_row.add_child(mode_option)

	add_row.add_child(_label("Name:"))
	fixture_name_edit = LineEdit.new()
	fixture_name_edit.placeholder_text = "(optional)"
	fixture_name_edit.custom_minimum_size = Vector2(100, 0)
	add_row.add_child(fixture_name_edit)

	add_row.add_child(_label("Start ch:"))
	fixture_start_spin = SpinBox.new()
	fixture_start_spin.min_value = 1
	fixture_start_spin.max_value = CHANNEL_MAX
	fixture_start_spin.value = 1
	add_row.add_child(fixture_start_spin)

	var add_btn := Button.new()
	add_btn.text = "Add Fixture"
	add_btn.pressed.connect(_on_add_fixture_pressed)
	add_row.add_child(add_btn)

	var new_profile_btn := Button.new()
	new_profile_btn.text = "New..."
	new_profile_btn.pressed.connect(func(): _profile_action("new"))
	add_row.add_child(new_profile_btn)

	var import_profile_btn := Button.new()
	import_profile_btn.text = "Import..."
	import_profile_btn.pressed.connect(func(): _profile_action("import"))
	add_row.add_child(import_profile_btn)

	var edit_profile_btn := Button.new()
	edit_profile_btn.text = "Edit..."
	edit_profile_btn.pressed.connect(func(): _profile_action("edit"))
	add_row.add_child(edit_profile_btn)

	var del_profile_btn := Button.new()
	del_profile_btn.text = "Delete..."
	del_profile_btn.pressed.connect(func(): _profile_action("delete"))
	add_row.add_child(del_profile_btn)

	outer.add_child(add_row)

	var fixtures_scroll := ScrollContainer.new()
	fixtures_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Only scroll vertically; fixture control rows wrap to fit the width.
	fixtures_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(fixtures_scroll)

	fixtures_vbox = VBoxContainer.new()
	fixtures_vbox.add_theme_constant_override("separation", 6)
	fixtures_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fixtures_scroll.add_child(fixtures_vbox)

	return outer


# -------------------------------------------------------------- PROFILES --

func _selected_profile() -> FixtureProfile:
	var i: int = profile_option.selected
	if i >= 0 and i < available_profiles.size():
		return available_profiles[i]
	return null


func _profile_action(action: String) -> void:
	if not profile_action_cb.is_valid():
		return
	if action == "new" or action == "import":
		profile_action_cb.call(action, null)
	else:
		var p := _selected_profile()
		if p:
			profile_action_cb.call(action, p)


func populate_profile_option() -> void:
	var keep: int = profile_option.selected
	profile_option.clear()
	for p in available_profiles:
		profile_option.add_item(p.profile_name)
	if keep >= 0 and keep < profile_option.item_count:
		profile_option.selected = keep
	populate_mode_option()


## Fill the Mode dropdown from whichever profile is currently selected.
func populate_mode_option() -> void:
	mode_option.clear()
	var idx: int = profile_option.selected
	if idx < 0 or idx >= available_profiles.size():
		mode_option.disabled = true
		return
	for n in available_profiles[idx].mode_names():
		mode_option.add_item(n)
	if mode_option.item_count == 0:
		mode_option.add_item("Default")
	mode_option.selected = 0
	mode_option.disabled = mode_option.item_count <= 1


# ------------------------------------------------------- FIXTURE PATCHING --

func _on_add_fixture_pressed() -> void:
	if available_profiles.is_empty():
		return
	var idx: int = profile_option.selected
	if idx < 0 or idx >= available_profiles.size():
		return

	var profile: FixtureProfile = available_profiles[idx]
	var mode: int = clampi(mode_option.selected, 0, max(profile.mode_count() - 1, 0))
	var start := int(fixture_start_spin.value) - 1
	var fixture_label := fixture_name_edit.text
	if fixture_label.strip_edges() == "":
		fixture_label = profile.profile_name

	var fixture := {
		"id": _next_fixture_id,
		"name": fixture_label,
		"profile": profile,
		"start": start,
		"mode": mode,
		# 3D visualizer placement (world metres / degrees).
		"pos": auto_place(patched_fixtures.size()),
		"rot": Vector3(28, 0, 0),
	}
	_next_fixture_id += 1
	patched_fixtures.append(fixture)
	fixtures_vbox.add_child(_build_fixture_row(fixture))
	fixture_name_edit.text = ""

	# Advance the start-channel field past this fixture's channels so the
	# next Add Fixture click patches right after it, with no overlap.
	var next_start := start + profile.channel_count(mode) + 1
	fixture_start_spin.value = min(next_start, fixture_start_spin.max_value)
	patch_changed.emit()


## Patch a fixture programmatically (MVR import, scripting). `emit`
## defers the patch_changed signal so a bulk add fires it once.
func add_patched(profile: FixtureProfile, p_start: int, p_mode: int, p_name: String, pos: Vector3, rot: Vector3, emit := true) -> void:
	patched_fixtures.append({
		"id": _next_fixture_id,
		"name": p_name if p_name != "" else profile.profile_name,
		"profile": profile,
		"start": p_start,
		"mode": clampi(p_mode, 0, max(profile.mode_count() - 1, 0)),
		"pos": pos,
		"rot": rot,
	})
	_next_fixture_id += 1
	_refresh_fixtures_vbox()
	if emit:
		patch_changed.emit()


func _on_remove_fixture(fixture_id: int) -> void:
	for i in range(patched_fixtures.size()):
		if patched_fixtures[i]["id"] == fixture_id:
			patched_fixtures.remove_at(i)
			break
	_refresh_fixtures_vbox()
	patch_changed.emit()


func _refresh_fixtures_vbox() -> void:
	for c in fixtures_vbox.get_children():
		c.queue_free()
	for fixture in patched_fixtures:
		fixtures_vbox.add_child(_build_fixture_row(fixture))


## Builds one fixture's control panel for its selected mode:
##   - a virtual dimmer, if the fixture has colour/white channels but no
##     DIMMER channel of its own
##   - a complete Red/Green/Blue trio  -> one colour picker
##   - a channel followed by a "fine" channel  -> one 16-bit slider
##   - a channel with named value ranges  -> a slot dropdown + trim slider
##   - anything else  -> a plain slider clamped to the channel's min/max
## "Home" snaps every control back to its channel default (and the virtual
## dimmer back to full).
func _build_fixture_row(fixture: Dictionary) -> Control:
	var profile: FixtureProfile = fixture["profile"]
	var start: int = fixture["start"]
	var mode: int = int(fixture.get("mode", 0))
	var chans: Array = profile.channels_for_mode(mode)

	var panel := PanelContainer.new()
	var vbox := VBoxContainer.new()
	panel.add_child(vbox)

	# Callables that push each control back to its default value. Wired to
	# the Home button and also fired once on build so a freshly patched
	# fixture starts at its defaults (in the UI and on the wire).
	var reset_callables: Array = []
	# Callables func(buf: PackedByteArray) that pull each control's widget
	# to the value(s) in `buf` — used by "Load to Patch" so a cue can be
	# edited with the fixture controls.
	var apply_callables: Array = []

	var header := _flow()
	var title := Label.new()
	var mode_suffix := ""
	if profile.mode_count() > 1:
		mode_suffix = "  [%s]" % profile.mode_names()[clampi(mode, 0, profile.mode_count() - 1)]
	title.text = "%s — %s%s (ch %d-%d)" % [
		fixture["name"], profile.profile_name, mode_suffix,
		start + 1, start + chans.size()
	]
	header.add_child(title)

	# Flash: full white for as long as the button is held, then put the
	# affected channels back exactly as they were.
	var flash_targets := _flash_targets(chans)
	var flash_saved := {}
	var flash_btn := Button.new()
	flash_btn.text = "Flash"
	flash_btn.disabled = flash_targets.is_empty()
	flash_btn.button_down.connect(func():
		if not flash_saved.is_empty():
			return
		for ix in flash_targets:
			flash_saved[ix] = sender.get_channel(start + ix)
			sender.set_channel(start + ix, flash_targets[ix])
	)
	flash_btn.button_up.connect(func():
		for ix in flash_saved:
			sender.set_channel(start + ix, flash_saved[ix])
		flash_saved.clear()
	)
	header.add_child(flash_btn)

	var home_btn := Button.new()
	home_btn.text = "Home"
	home_btn.pressed.connect(func():
		for c in reset_callables:
			c.call()
	)
	header.add_child(home_btn)

	var remove_btn := Button.new()
	remove_btn.text = "Remove"
	var fixture_id: int = fixture["id"]
	remove_btn.pressed.connect(func(): _on_remove_fixture(fixture_id))
	header.add_child(remove_btn)
	vbox.add_child(header)

	var controls_row := _flow(12, 8)
	vbox.add_child(controls_row)

	# Decide whether this fixture needs a virtual dimmer: it must have at
	# least one colour/white channel and no DIMMER channel of its own.
	var has_dimmer := false
	var intensity_idx: Array = []
	for k in range(chans.size()):
		var role_k := String(chans[k]["role"])
		if role_k == "DIMMER":
			has_dimmer = true
		elif role_k in INTENSITY_ROLES:
			intensity_idx.append(k)
	var use_vdim: bool = (not has_dimmer) and not intensity_idx.is_empty()

	# vdim["frac"] is the 0..1 master; full_levels[i] is the raw 0..255
	# value the user dialed for intensity channel i. Every intensity write
	# goes through push_intensity so the master always applies.
	var vdim := {"frac": 1.0}
	var full_levels := {}
	for k in intensity_idx:
		full_levels[k] = 0

	var push_intensity := func(local_k: int):
		var lvl: int = int(full_levels.get(local_k, 0))
		lvl = int(round(lvl * float(vdim["frac"])))
		sender.set_channel(start + local_k, clampi(lvl, 0, 255))

	if use_vdim:
		var d_box := VBoxContainer.new()
		d_box.alignment = BoxContainer.ALIGNMENT_CENTER
		d_box.add_child(_centered_label("Dimmer\n(virtual)"))
		var d_slider := VSlider.new()
		d_slider.min_value = 0
		d_slider.max_value = 255
		d_slider.step = 1
		d_slider.value = 255
		d_slider.custom_minimum_size = Vector2(28, 90)
		d_box.add_child(d_slider)
		var d_val := _centered_label("255")
		d_box.add_child(d_val)
		d_slider.value_changed.connect(func(v: float):
			vdim["frac"] = float(v) / 255.0
			d_val.text = str(int(v))
			for li in full_levels:
				push_intensity.call(li)
		)
		controls_row.add_child(d_box)
		# The virtual dimmer homes to full, so a homed fixture behaves like
		# one whose real dimmer is open.
		reset_callables.append(func():
			d_slider.value = 255
			vdim["frac"] = 1.0
			d_val.text = "255"
			for li in full_levels:
				push_intensity.call(li)
		)
		# A loaded look bakes intensity into the raw colour values, so open
		# the virtual dimmer fully before the colour / intensity appliers run.
		apply_callables.append(func(_buf: PackedByteArray):
			d_slider.set_value_no_signal(255)
			vdim["frac"] = 1.0
			d_val.text = "255"
		)

	# One colour picker per head (RGB triplet). Multi-head fixtures — LED
	# bars, spiders — get "Colour 1", "Colour 2", …
	var heads := profile.head_groups(mode)
	var handled := {}
	for hi in range(heads.size()):
		var g: Dictionary = heads[hi]
		var r_idx: int = g["r"]
		var g_idx: int = g["g"]
		var b_idx: int = g["b"]
		var color_box := VBoxContainer.new()
		color_box.add_child(_centered_label("Colour %d" % (hi + 1) if heads.size() > 1 else "Colour"))
		var picker := ColorPickerButton.new()
		picker.color = Color.BLACK
		picker.custom_minimum_size = Vector2(60, 24)
		picker.color_changed.connect(func(c: Color):
			full_levels[r_idx] = int(round(c.r * 255))
			full_levels[g_idx] = int(round(c.g * 255))
			full_levels[b_idx] = int(round(c.b * 255))
			push_intensity.call(r_idx)
			push_intensity.call(g_idx)
			push_intensity.call(b_idx)
		)
		color_box.add_child(picker)
		controls_row.add_child(color_box)
		handled[r_idx] = true
		handled[g_idx] = true
		handled[b_idx] = true
		reset_callables.append(func():
			picker.color = Color.BLACK
			full_levels[r_idx] = 0
			full_levels[g_idx] = 0
			full_levels[b_idx] = 0
			push_intensity.call(r_idx)
			push_intensity.call(g_idx)
			push_intensity.call(b_idx)
		)
		apply_callables.append(func(buf: PackedByteArray):
			var rv := _bufv(buf, start + r_idx)
			var gv := _bufv(buf, start + g_idx)
			var bv := _bufv(buf, start + b_idx)
			picker.color = Color(rv / 255.0, gv / 255.0, bv / 255.0)
			full_levels[r_idx] = rv
			full_levels[g_idx] = gv
			full_levels[b_idx] = bv
			push_intensity.call(r_idx)
			push_intensity.call(g_idx)
			push_intensity.call(b_idx)
		)

	# A fixture with both a Pan and a Tilt channel gets a single 2D pad
	# instead of two sliders — drag the puck to aim the head.
	var pan_i := -1
	var tilt_i := -1
	for k in range(chans.size()):
		if handled.has(k):
			continue
		match String(chans[k]["role"]):
			"PAN":
				if pan_i == -1:
					pan_i = k
			"TILT":
				if tilt_i == -1:
					tilt_i = k
	if pan_i != -1 and tilt_i != -1:
		var pan_spec := _axis_spec(chans, pan_i)
		var tilt_spec := _axis_spec(chans, tilt_i)
		controls_row.add_child(_build_xy_pad(
			start, pan_spec, tilt_spec, reset_callables, apply_callables))
		handled[pan_i] = true
		handled[tilt_i] = true
		if pan_spec["fine"] != -1:
			handled[pan_spec["fine"]] = true
		if tilt_spec["fine"] != -1:
			handled[tilt_spec["fine"]] = true

	var ci := 0
	while ci < chans.size():
		if handled.has(ci):
			ci += 1
			continue
		var ch: Dictionary = chans[ci]
		var next_is_fine: bool = (ci + 1 < chans.size()) \
			and bool(chans[ci + 1].get("fine", false)) \
			and not bool(ch.get("fine", false))

		if next_is_fine:
			controls_row.add_child(_build_16bit_control(
				start, ci, ci + 1, ch, chans[ci + 1], reset_callables, apply_callables))
			handled[ci + 1] = true
			ci += 2
			continue

		if not (ch["ranges"] as Array).is_empty():
			controls_row.add_child(_build_range_control(start, ci, ch, reset_callables, apply_callables))
			ci += 1
			continue

		# Route lone intensity channels (White, Amber, UV) through the
		# virtual dimmer too, not just the RGB trio.
		if String(ch["role"]) in INTENSITY_ROLES:
			var li := ci
			var wcb := func(v: int):
				full_levels[li] = v
				push_intensity.call(li)
			controls_row.add_child(_build_slider_control(start, ci, ch, reset_callables, apply_callables, wcb))
			ci += 1
			continue

		controls_row.add_child(_build_slider_control(start, ci, ch, reset_callables, apply_callables))
		ci += 1

	# Snap everything to defaults now that all controls exist.
	for c in reset_callables:
		c.call()

	fixture["_apply"] = func(buf: PackedByteArray):
		for a in apply_callables:
			a.call(buf)

	return panel


func _bufv(buf: PackedByteArray, i: int) -> int:
	return int(buf[i]) if i >= 0 and i < buf.size() else 0


## Local channel index -> value for a "full white" flash: dimmer + every
## R/G/B/W channel to full (so each head goes white), amber / UV to zero
## when there's a white to keep pure, and a colour wheel to its open slot.
func _flash_targets(chans: Array) -> Dictionary:
	var out := {}
	var has_white := false
	for ch in chans:
		if String(ch["role"]) == "WHITE":
			has_white = true
	for k in range(chans.size()):
		var ch: Dictionary = chans[k]
		match String(ch["role"]):
			"DIMMER", "RED", "GREEN", "BLUE", "WHITE":
				out[k] = int(ch["max"])
			"AMBER", "UV":
				if has_white:
					out[k] = int(ch["min"])
			"COLOR_WHEEL":
				var wv := _white_slot(ch)
				if wv >= 0:
					out[k] = wv
	return out


## The DMX value that sits in a colour wheel's "open" / "white" slot, or
## -1 if the channel has no such slot.
func _white_slot(ch: Dictionary) -> int:
	for r in ch.get("ranges", []):
		var label := String(r["label"]).to_lower()
		if "white" in label or "open" in label:
			return int((int(r["lo"]) + int(r["hi"])) / 2.0)
	return -1


## Describe one pan/tilt axis: its coarse channel, its fine partner (-1 if
## 8-bit), the value range and the home value. 16-bit axes run 0..65535.
func _axis_spec(chans: Array, idx: int) -> Dictionary:
	var ch: Dictionary = chans[idx]
	if idx + 1 < chans.size() and bool(chans[idx + 1].get("fine", false)):
		return {
			"coarse": idx, "fine": idx + 1, "lo": 0, "hi": 65535,
			"default": (int(ch["default"]) << 8) | int(chans[idx + 1]["default"]),
		}
	return {
		"coarse": idx, "fine": -1,
		"lo": int(ch["min"]), "hi": int(ch["max"]), "default": int(ch["default"]),
	}


func _axis_from_buf(buf: PackedByteArray, start: int, spec: Dictionary) -> int:
	if spec["fine"] != -1:
		return (_bufv(buf, start + spec["coarse"]) << 8) | _bufv(buf, start + spec["fine"])
	return _bufv(buf, start + spec["coarse"])


## Pan/Tilt as one 2D pad: X = pan, Y = tilt (up = higher value). Writes
## both axes (splitting 16-bit ones across their two channels) whenever the
## puck moves, and follows Home / Load to Patch.
func _build_xy_pad(start: int, pan: Dictionary, tilt: Dictionary, reset_callables: Array, apply_callables: Array) -> Control:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(_centered_label("Pan / Tilt"))

	var pad := XYPad.new()
	box.add_child(pad)

	var val_lbl := _centered_label("")
	box.add_child(val_lbl)

	var write_axis := func(spec: Dictionary, norm: float) -> int:
		var span: int = spec["hi"] - spec["lo"]
		var v: int = clampi(spec["lo"] + int(round(norm * span)), spec["lo"], spec["hi"])
		if spec["fine"] != -1:
			sender.set_channel(start + spec["coarse"], (v >> 8) & 0xFF)
			sender.set_channel(start + spec["fine"], v & 0xFF)
		else:
			sender.set_channel(start + spec["coarse"], v)
		return v

	var norm_of := func(spec: Dictionary, v: int) -> float:
		return clampf(float(v - spec["lo"]) / maxi(1, spec["hi"] - spec["lo"]), 0.0, 1.0)

	var push := func(nx: float, ny: float):
		var pv: int = write_axis.call(pan, nx)
		var tv: int = write_axis.call(tilt, ny)
		val_lbl.text = "P%d  T%d" % [pv, tv]

	pad.changed.connect(func(nx: float, ny: float): push.call(nx, ny))

	reset_callables.append(func():
		var nx: float = norm_of.call(pan, pan["default"])
		var ny: float = norm_of.call(tilt, tilt["default"])
		pad.set_value_silent(Vector2(nx, ny))
		push.call(nx, ny)
	)
	apply_callables.append(func(buf: PackedByteArray):
		var nx: float = norm_of.call(pan, _axis_from_buf(buf, start, pan))
		var ny: float = norm_of.call(tilt, _axis_from_buf(buf, start, tilt))
		pad.set_value_silent(Vector2(nx, ny))
		push.call(nx, ny)
	)
	return box


## Plain 8-bit channel: a vertical slider clamped to [min, max]. When
## write_cb is given it receives the value instead of a direct DMX write
## (used to route intensity channels through the virtual dimmer).
func _build_slider_control(start: int, local_i: int, ch: Dictionary, reset_callables: Array, apply_callables: Array, write_cb := Callable()) -> Control:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(_centered_label(ch["name"]))

	var slider := VSlider.new()
	slider.min_value = int(ch["min"])
	slider.max_value = int(ch["max"])
	slider.step = 1
	slider.value = int(ch["min"])
	slider.custom_minimum_size = Vector2(28, 90)
	box.add_child(slider)

	var val_lbl := _centered_label(str(int(ch["min"])))
	box.add_child(val_lbl)

	var do_write := func(v: int):
		if write_cb.is_valid():
			write_cb.call(v)
		else:
			sender.set_channel(start + local_i, v)

	slider.value_changed.connect(func(v: float):
		do_write.call(int(v))
		val_lbl.text = str(int(v))
	)

	reset_callables.append(func():
		var d := int(ch["default"])
		slider.value = d
		do_write.call(d)
		val_lbl.text = str(d)
	)
	apply_callables.append(func(buf: PackedByteArray):
		var v := clampi(_bufv(buf, start + local_i), int(ch["min"]), int(ch["max"]))
		slider.set_value_no_signal(v)
		do_write.call(v)
		val_lbl.text = str(v)
	)
	return box


## 16-bit pair (coarse channel + its "fine" LSB partner): one slider over
## the full 0..65535 range, split into two DMX channels on the way out.
func _build_16bit_control(start: int, coarse_i: int, fine_i: int, coarse_ch: Dictionary, fine_ch: Dictionary, reset_callables: Array, apply_callables: Array) -> Control:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(_centered_label("%s (16-bit)" % coarse_ch["name"]))

	var default16 := (int(coarse_ch["default"]) << 8) | int(fine_ch["default"])

	var slider := VSlider.new()
	slider.min_value = 0
	slider.max_value = 65535
	slider.step = 1
	slider.value = 0
	slider.custom_minimum_size = Vector2(28, 120)
	box.add_child(slider)

	var val_lbl := _centered_label("0")
	box.add_child(val_lbl)

	var apply := func(v16: int):
		var vv := clampi(v16, 0, 65535)
		sender.set_channel(start + coarse_i, (vv >> 8) & 0xFF)
		sender.set_channel(start + fine_i, vv & 0xFF)
		val_lbl.text = str(vv)

	slider.value_changed.connect(func(v: float): apply.call(int(v)))

	reset_callables.append(func():
		slider.value = default16
		apply.call(default16)
	)
	apply_callables.append(func(buf: PackedByteArray):
		var v16 := (_bufv(buf, start + coarse_i) << 8) | _bufv(buf, start + fine_i)
		slider.set_value_no_signal(v16)
		apply.call(v16)
	)
	return box


## Channel with named value ranges (gobo / colour wheel): a dropdown that
## jumps to the middle of a slot, plus a slider for fine positioning. The
## two stay in sync — moving the slider re-selects whichever slot it lands
## in.
func _build_range_control(start: int, local_i: int, ch: Dictionary, reset_callables: Array, apply_callables: Array) -> Control:
	var ranges: Array = ch["ranges"]
	var ch_min := int(ch["min"])
	var ch_max := int(ch["max"])

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(160, 0)
	box.add_child(_centered_label(ch["name"]))

	var role := String(ch["role"])
	var opt := OptionButton.new()
	for ri in range(ranges.size()):
		var r: Dictionary = ranges[ri]
		var text := "%s (%d-%d)" % [r["label"], int(r["lo"]), int(r["hi"])]
		var icon := _slot_icon(role, r, ri)
		if icon:
			opt.add_icon_item(icon, text)
		else:
			opt.add_item(text)
	box.add_child(opt)

	var slider := HSlider.new()
	slider.min_value = ch_min
	slider.max_value = ch_max
	slider.step = 1
	slider.value = ch_min
	box.add_child(slider)

	var val_lbl := _centered_label(str(ch_min))
	box.add_child(val_lbl)

	var slot_for := func(v: int) -> int:
		for ri in range(ranges.size()):
			if v >= int(ranges[ri]["lo"]) and v <= int(ranges[ri]["hi"]):
				return ri
		return -1

	slider.value_changed.connect(func(v: float):
		var vv := clampi(int(v), ch_min, ch_max)
		sender.set_channel(start + local_i, vv)
		val_lbl.text = str(vv)
		var ri: int = slot_for.call(vv)
		if ri != -1 and opt.selected != ri:
			opt.select(ri)
	)

	opt.item_selected.connect(func(ri: int):
		var r: Dictionary = ranges[ri]
		var mid := int(floor((int(r["lo"]) + int(r["hi"])) / 2.0))
		mid = clampi(mid, ch_min, ch_max)
		slider.value = mid
		sender.set_channel(start + local_i, mid)
		val_lbl.text = str(mid)
	)

	reset_callables.append(func():
		var d := int(ch["default"])
		slider.value = d
		sender.set_channel(start + local_i, d)
		val_lbl.text = str(d)
		var ri: int = slot_for.call(d)
		opt.select(ri)
	)
	apply_callables.append(func(buf: PackedByteArray):
		var v := clampi(_bufv(buf, start + local_i), ch_min, ch_max)
		slider.set_value_no_signal(v)
		sender.set_channel(start + local_i, v)
		val_lbl.text = str(v)
		var ri: int = slot_for.call(v)
		if ri != -1:
			opt.select(ri)
	)
	return box


# -------------------------------------------------------------- ACTIONS --

func apply_connection() -> void:
	sender.artnet_universe = int(artnet_uni_spin.value)
	sender.target_ip = ip_edit.text
	sender.target_port = int(port_spin.value)
	sender.sacn_priority = int(sacn_priority_spin.value)
	sender.sacn_unicast_ip = sacn_ip_edit.text.strip_edges()

	var sel: int = output_option.selected
	var was_usb: bool = sender.output_mode == ArtNetUniverse.OUT_USB

	var new_serial := ""
	if sel == ArtNetUniverse.OUT_USB and UsbDmx.available \
			and usb_device_option.selected >= 0 \
			and usb_device_option.selected < _usb_devices.size():
		new_serial = String(_usb_devices[usb_device_option.selected]["serial"])
	if was_usb and sender.usb_serial != new_serial:
		UsbDmx.unroute(sender.usb_serial)

	match sel:
		ArtNetUniverse.OUT_USB:
			var mode: int = usb_mode_option.selected
			if new_serial != "" and UsbDmx.route(new_serial, mode):
				sender.usb_serial = new_serial
				sender.usb_mode = mode
				sender.set_output_mode(ArtNetUniverse.OUT_USB)
				set_status("USB DMX → %s  [%s]" % [new_serial, UsbDmx.status(new_serial)])
			else:
				sender.usb_serial = ""
				sender.set_output_mode(ArtNetUniverse.OUT_ARTNET)
				output_option.selected = ArtNetUniverse.OUT_ARTNET
				set_status("USB DMX: %s — sending Art-Net" % (
					UsbDmx.status(new_serial) if new_serial != "" else "no interface selected"))
		ArtNetUniverse.OUT_SACN:
			sender.usb_serial = ""
			sender.set_output_mode(ArtNetUniverse.OUT_SACN)
			var uni: int = maxi(sender.artnet_universe, 1)
			var tgt := sender.sacn_unicast_ip if sender.sacn_unicast_ip != "" \
				else Sacn.multicast_ip(uni)
			set_status("sACN → %s  U%d  pri %d" % [tgt, uni, sender.sacn_priority])
		_:
			sender.usb_serial = ""
			sender.set_output_mode(ArtNetUniverse.OUT_ARTNET)
			set_status("→ %s:%d  Art-Net U%d" % [
				ip_edit.text, int(port_spin.value), int(artnet_uni_spin.value)])

	_sync_output_ui()


func _on_rgb_color_changed(color: Color) -> void:
	var start := int(rgb_start_spin.value) - 1
	sender.set_channel(start, int(round(color.r * 255)))
	sender.set_channel(start + 1, int(round(color.g * 255)))
	sender.set_channel(start + 2, int(round(color.b * 255)))


func blackout_universe() -> void:
	sender.set_all(0)


func full_universe() -> void:
	sender.set_all(255)


# ------------------------------------------------------- SERIALIZATION --

## Default 3D placement for the Nth fixture in this universe: a hanging
## grid facing the stage.
static func auto_place(n: int) -> Vector3:
	var col := n % 6
	var row := n / 6
	return Vector3((col - 2.5) * 1.7, 4.6, -1.5 - row * 1.7)


static func _v3_to_arr(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


static func _arr_to_v3(a, fallback: Vector3) -> Vector3:
	if a is Array and a.size() == 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return fallback


## Connection settings + patched fixtures for this universe (part of a
## whole-show file). Does not include the live DMX buffer — that's a
## preset, saved separately.
func patch_dict() -> Dictionary:
	var fixtures: Array = []
	for fixture in patched_fixtures:
		var profile: FixtureProfile = fixture["profile"]
		fixtures.append({
			"name": fixture["name"],
			"start": fixture["start"],
			"mode": int(fixture.get("mode", 0)),
			"profile": profile.to_dict(),
			"pos": _v3_to_arr(fixture.get("pos", Vector3.ZERO)),
			"rot": _v3_to_arr(fixture.get("rot", Vector3.ZERO)),
		})
	return {
		"ip": ip_edit.text,
		"port": int(port_spin.value),
		"artnet_universe": int(artnet_uni_spin.value),
		"output": ["artnet", "sacn", "usb"][sender.output_mode],
		"usb_serial": sender.usb_serial,
		"usb_mode": sender.usb_mode,
		"sacn_priority": sender.sacn_priority,
		"sacn_ip": sender.sacn_unicast_ip,
		"fixtures": fixtures,
	}


func apply_patch_dict(d: Dictionary) -> void:
	if d.has("ip"):
		ip_edit.text = String(d["ip"])
	if d.has("port"):
		port_spin.value = int(d["port"])
	if d.has("artnet_universe"):
		artnet_uni_spin.value = int(d["artnet_universe"])

	sacn_priority_spin.value = clampi(int(d.get("sacn_priority", 100)), 0, 200)
	sacn_ip_edit.text = String(d.get("sacn_ip", ""))
	usb_mode_option.selected = clampi(
		int(d.get("usb_mode", 0)), 0, maxi(usb_mode_option.item_count - 1, 0))

	var want := String(d.get("output", "artnet"))
	var want_serial := String(d.get("usb_serial", ""))
	if want == "usb" and UsbDmx.available:
		output_option.selected = ArtNetUniverse.OUT_USB
		if want_serial != "":
			_rescan_usb()
			for di in range(_usb_devices.size()):
				if String(_usb_devices[di]["serial"]) == want_serial:
					usb_device_option.selected = di
					break
	elif want == "sacn":
		output_option.selected = ArtNetUniverse.OUT_SACN
	else:
		output_option.selected = ArtNetUniverse.OUT_ARTNET
	apply_connection()

	patched_fixtures.clear()
	var i := 0
	for entry in d.get("fixtures", []):
		var profile := FixtureProfile.from_dict(entry.get("profile", {}))
		patched_fixtures.append({
			"id": _next_fixture_id,
			"name": entry.get("name", profile.profile_name),
			"profile": profile,
			"start": int(entry.get("start", 0)),
			"mode": clampi(int(entry.get("mode", 0)), 0, max(profile.mode_count() - 1, 0)),
			"pos": _arr_to_v3(entry.get("pos", null), auto_place(i)),
			"rot": _arr_to_v3(entry.get("rot", null), Vector3(28, 0, 0)),
		})
		_next_fixture_id += 1
		i += 1
	_refresh_fixtures_vbox()


## Non-zero channels of this universe's live buffer (part of a preset).
func buffer_dict() -> Dictionary:
	var channels := {}
	for i in range(ArtNetUniverse.DMX_UNIVERSE_SIZE):
		var v := sender.get_channel(i)
		if v != 0:
			channels[str(i)] = v
	return {"channels": channels}


func apply_buffer_dict(d: Dictionary) -> void:
	sender.set_all(0)
	var channels: Dictionary = d.get("channels", {})
	for key in channels.keys():
		sender.set_channel(int(key), int(channels[key]))


## Load a full 512-byte look (a cue's stored levels for this universe)
## into the live buffer *and* the fixture controls, so the look can be
## edited with the sliders / pickers and re-recorded.
func load_look(buf: PackedByteArray) -> void:
	var n := ArtNetUniverse.DMX_UNIVERSE_SIZE
	if buf.size() >= n:
		sender.dmx_data = buf.slice(0, n)
	else:
		sender.set_all(0)
		for i in range(buf.size()):
			sender.set_channel(i, buf[i])
	for fixture in patched_fixtures:
		var a = fixture.get("_apply", null)
		if a is Callable and (a as Callable).is_valid():
			a.call(buf)
