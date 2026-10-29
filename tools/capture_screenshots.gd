extends SceneTree
## Retakes the user guide's and the README's screenshots from the running
## app: a demo rig is patched, each scene set up, and the window saved as
## a PNG named as docs/img's (and docs/screenshot.png's). Run it windowed
## (not --headless: nothing renders headless):
##
##   godot --script tools/capture_screenshots.gd -- <out dir> [name ...]
##
## <out dir> defaults to user://_screenshots; names pick which to take
## (all of them when there are none). Nothing of the user's is touched:
## the show, its timelines, the autosave and the UI state all go to
## scratch files under user://_capture. DJ Edit Mode's screenshots
## (11-13, 15) need a real song and are taken by hand.

const SIZE := Vector2i(1600, 900)
const SCRATCH := "user://_capture"
const SHOTS := ["01-patch-tab", "02-fixture-library", "03-cues-tab", "04-chases-tab",
	"05-effects-tab", "06-sound-tab", "08-groups-tab", "09-visualizer", "10-triggers-dialog",
	"14-dj-perform", "screenshot"]

var out_dir := "user://_screenshots"
var main: Control
var _uids: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		out_dir = args[0]
	var only: Array = args.slice(1)
	_run.call_deferred(only if not only.is_empty() else SHOTS)


func _run(names: Array) -> void:
	DirAccess.make_dir_recursive_absolute(SCRATCH)
	DirAccess.make_dir_recursive_absolute(out_dir)
	root.size = SIZE
	DisplayServer.window_set_size(SIZE)
	main = load("res://main.tscn").instantiate()
	main.last_show_store = SCRATCH + "/last.json"
	main.ui_state_store = SCRATCH + "/ui.json"
	main.autosave.file = SCRATCH + "/autosave.slight"
	main.autosave.session_file = SCRATCH + "/session.json"
	root.add_child(main)
	await _frames(5)
	main.new_show()
	_patch_rig()
	_program()
	main.status_label.text = ""
	await _frames(5)
	for n in names:
		if has_method("_" + n.replace("-", "_")):
			await call("_" + n.replace("-", "_"))
		else:
			print("no such screenshot: ", n)
	quit()


# ----------------------------------------------------------------- SETUP --

## Two moving heads, two washes and a spot.
func _patch_rig() -> void:
	var panel = main._panels[0]
	var lib := {}
	for p in main.available_profiles:
		lib[p.id] = p
	var rig := [["mh_rgbw_pt7", 0, "Mover L"], ["mh_rgbw_pt7", 10, "Mover R"], ["rgbw4", 20, "Wash L"],
		["rgbw4", 30, "Wash R"], ["mh_spot", 40, "Spot"]]
	var xs := [-1.5, 1.5, -4.0, 4.0, 0.0]
	for i in range(rig.size()):
		panel.add_patched(lib[rig[i][0]], rig[i][1], 0, rig[i][2], Vector3(xs[i], 4.0, -3.0), Vector3(90, 0, 0))
	for f in panel.patched_fixtures:
		_uids.append(String(f["uid"]))
	_look(_warm())


## A look: channel -> value, as the patch's controls are set.
func _look(levels: Dictionary) -> void:
	var buf := PackedByteArray()
	buf.resize(512)
	for ch in levels:
		buf[ch] = levels[ch]
	main._panels[0].load_look(buf)


## Movers amber and blue aimed in, washes warm, the spot open.
func _warm() -> Dictionary:
	return {0: 100, 1: 150, 2: 255, 3: 255, 4: 130, 5: 0, 6: 30,
		10: 156, 11: 150, 12: 255, 13: 30, 14: 90, 15: 255, 16: 30,
		20: 255, 21: 110, 22: 20, 23: 60, 30: 255, 31: 110, 32: 20, 33: 60,
		40: 128, 41: 110, 42: 255, 43: 12, 44: 0}


func _cool() -> Dictionary:
	return {0: 80, 1: 120, 2: 255, 3: 0, 4: 120, 5: 255, 6: 0,
		10: 176, 11: 120, 12: 255, 13: 0, 14: 200, 15: 255, 16: 0,
		20: 0, 21: 60, 22: 255, 23: 0, 30: 0, 31: 60, 32: 255, 33: 0,
		40: 128, 41: 90, 42: 200, 43: 12, 44: 40}


## Cues, a chase, an effect, a group and a couple of triggers.
func _program() -> void:
	var CueScript: GDScript = load("res://scripts/cue.gd")
	var cp = main.cue_panel
	for c in [["Warm Wash", 3.0, 2.0, _warm()], ["Cool Chase Standby", 2.0, 2.0, _cool()], ["Blackout", 1.5, 1.5, {}]]:
		var cue = CueScript.new(c[0], c[1], c[2])
		cue.set_levels([c[3]])
		cp.cues.append(cue)
	cp._refresh_list()
	cp.cues_changed.emit()

	var ChaseScript: GDScript = load("res://scripts/chase.gd")
	var chase = ChaseScript.new()
	chase.name = "Colour Wipe"
	chase.bpm = 120.0
	chase.crossfade = 0.3
	for col in [[255, 0, 0], [0, 255, 0], [0, 0, 255]]:
		var step := {}
		for base in [20, 30]:
			for k in range(3):
				step[str(base + k)] = col[k]
		chase.steps.append([step])
	root.get_node("Fx").chases.append(chase)
	main.chase_panel.chases_changed.emit()

	var WaveScript: GDScript = load("res://scripts/wave_effect.gd")
	var fx = WaveScript.new()
	fx.name = "Pan Sweep"
	fx.role = "PAN"
	fx.group = "Movers"
	fx.bpm = 20.0
	fx.size = 120.0
	fx.center = 128.0
	fx.fan_deg = 90.0
	root.get_node("Fx").effects.append(fx)
	main.fx_panel.effects_changed.emit()

	main.groups.append({"name": "Movers", "members": [_uids[0], _uids[1]]})
	main.groups_panel.groups_changed.emit()

	var t1 := Trigger.new()
	t1.name = "Pad 1 — GO"
	t1.midi_kind = Trigger.MIDI_NOTE
	t1.midi_number = 36
	t1.action = Trigger.ACT_CUE_GO
	var t2 := Trigger.new()
	t2.name = "Fader 8 — Strobe"
	t2.midi_kind = Trigger.MIDI_PITCH_BEND
	t2.midi_channel = 7
	t2.action = Trigger.ACT_FLASH_STROBE
	root.get_node("Triggers").triggers.append(t1)
	root.get_node("Triggers").triggers.append(t2)


func _playback_tab(i: int) -> void:
	main._console_view.get_child(0).current_tab = i


func _right_tab(i: int) -> void:
	main._right_tabs.current_tab = i


func _expand(indexes: Array) -> void:
	var panel = main._panels[0]
	for i in range(panel.patched_fixtures.size()):
		panel.patched_fixtures[i]["_expanded"] = i in indexes
	var live: Dictionary = panel.live_dict()
	panel._refresh_fixtures_vbox()
	panel.apply_live_dict(live)


## The 3D Visualizer with a little more haze, so the beams show.
func _viz_look() -> void:
	main.viz_panel._haze_slider.value = 0.5


func _clear_focus() -> void:
	root.warp_mouse(Vector2(SIZE.x - 2, SIZE.y - 2))
	var f := root.gui_get_focus_owner()
	if f:
		f.release_focus()


# ----------------------------------------------------------------- SHOTS --

func _01_patch_tab() -> void:
	main.set_view(0)
	_playback_tab(0)
	_right_tab(0)
	_look(_warm())
	_expand([0, 1])
	main.status_label.text = ""
	_clear_focus()
	await _shot("01-patch-tab")


func _02_fixture_library() -> void:
	main._open_library_dialog()
	var win: Window = main.get_child(main.get_child_count() - 1)
	await _frames(5)
	for e in win.find_children("*", "LineEdit", true, false):
		if e.placeholder_text.begins_with("Search"):
			e.text = "moving head"
			e.text_changed.emit(e.text)
	await _frames(10)
	for l in win.find_children("*", "ItemList", true, false):
		if l.item_count > 2:
			l.select(2)
			l.item_selected.emit(2)
			break
	win.popup_centered()
	await _shot("02-fixture-library")
	win.queue_free()


func _03_cues_tab() -> void:
	main.set_view(0)
	_playback_tab(0)
	_right_tab(0)
	_expand([])
	main.cue_panel.cue_list.select(0)
	main.cue_panel.cue_list.item_selected.emit(0)
	_clear_focus()
	await _shot("03-cues-tab")


func _04_chases_tab() -> void:
	_playback_tab(1)
	var cp = main.chase_panel
	cp.sync_ui()
	cp.chase_list.select(0)
	cp.chase_list.item_selected.emit(0)
	cp.set_running_by_name("Colour Wipe", true)
	cp.sync_ui()
	cp.chase_list.select(0)
	cp.chase_list.item_selected.emit(0)
	_right_tab(1)
	_viz_look()
	await _frames(30)
	_clear_focus()
	await _shot("04-chases-tab")
	cp.set_running_by_name("Colour Wipe", false)


func _05_effects_tab() -> void:
	_playback_tab(2)
	_right_tab(1)
	_viz_look()
	var fp = main.fx_panel
	fp.set_running_by_name("Pan Sweep", true)
	fp.sync_ui()
	fp.fx_list.select(0)
	fp.fx_list.item_selected.emit(0)
	await _frames(40)
	_clear_focus()
	await _shot("05-effects-tab")
	fp.set_running_by_name("Pan Sweep", false)
	fp.sync_ui()


func _06_sound_tab() -> void:
	_playback_tab(3)
	_right_tab(0)
	var fx_node := root.get_node("Fx")
	fx_node.reactors.assign(load("res://scripts/sound_reactor.gd").defaults())
	var sp = main.sound_panel
	sp.sync_ui()
	sp.rx_list.select(0)
	sp.rx_list.item_selected.emit(0)
	_clear_focus()
	await _shot("06-sound-tab")


func _08_groups_tab() -> void:
	_playback_tab(4)
	_right_tab(3)
	var gp = main.groups_panel
	gp._refresh_list()
	gp.group_list.select(0)
	gp.group_list.item_selected.emit(0)
	var fb = main.faders
	var Bank: GDScript = load("res://scripts/fader_bank.gd")
	fb.add_fader()
	fb.set_target(0, Bank.KIND_CUE, "1")
	fb.set_level(0, 0.8)
	fb.add_fader()
	fb.set_target(1, Bank.KIND_GROUP, "Movers")
	fb.set_level(1, 1.0)
	fb.add_fader()
	fb.set_target(2, Bank.KIND_EFFECT, "Pan Sweep")
	fb.set_level(2, 0.0)
	fb.faders[0].name = "Warm"
	fb.faders[1].name = "Movers"
	fb.faders[2].name = "Sweep"
	fb.faders[0].midi_cc = 7
	fb.faders[0].midi_channel = 0
	fb.faders[2].midi_bend = true
	fb.faders[2].midi_channel = 1
	main.faders_panel.rebuild()
	_clear_focus()
	await _shot("08-groups-tab")


func _09_visualizer() -> void:
	main.set_view(0)
	_playback_tab(0)
	_right_tab(1)
	_viz_look()
	_look(_warm())
	await _frames(20)
	_clear_focus()
	await _shot("09-visualizer")


func _10_triggers_dialog() -> void:
	main.set_view(0)
	_playback_tab(4)
	_right_tab(1)
	var d = main._triggers_dialog
	d.popup_centered()
	await _frames(5)
	d._refresh_list()
	d._list.select(0)
	d._list.item_selected.emit(0)
	await _shot("10-triggers-dialog")
	d.hide()


func _14_dj_perform() -> void:
	# A show with timelines for one song, VirtualDJ simulated over OS2L.
	var dir := ProjectSettings.globalize_path(SCRATCH)
	var songs := [dir.path_join("01 Wake Me Up.mp3"), dir.path_join("02 You Make Me.mp3")]
	for i in range(songs.size()):
		var f := FileAccess.open(songs[i], FileAccess.WRITE)
		f.store_string("not really audio %d" % i)
		f.close()
	var store := TimelineStore.new(SCRATCH + "/show.timelines")
	var tracks := {"master": {"dimmer": [[0.0, 0.2], [60.0, 0.9], [120.0, 0.4], [240.0, 1.0]],
		"colour": [[0.0, 240.0, "ff8800", "0044ff"]]}}
	for u in _uids:
		tracks[u] = {"dimmer": [[0.0, 0.5], [240.0, 1.0]]}
	store.save_song(songs[0], {"tracks": tracks})
	main.music_panel.timeline().set_timeline_store(store)
	var perf = main.performer
	perf.timeline = null                      # deck 2's song: no temporary show for the shot
	main.set_view(2)
	await _frames(5)
	# A client on the OS2L port, as VirtualDJ would be.
	var client := StreamPeerTCP.new()
	client.connect_to_host("127.0.0.1", perf.os2l.get_port())
	var wait := Time.get_ticks_msec()
	while perf.client_count() == 0 and Time.get_ticks_msec() - wait < 3000:
		client.poll()
		await process_frame
	var vdj := func(trigger: String, value):
		perf.os2l.handle_message({"evt": "subscribed", "trigger": trigger, "value": value})
	vdj.call("get_decks", 2)
	vdj.call("deck 1 get_filepath", songs[0].replace("/", "\\"))
	vdj.call("deck 1 level", 1.0)
	vdj.call("deck 1 play", "on")
	vdj.call("deck 1 get_time elapsed absolute", 95000.0)
	vdj.call("deck 2 get_filepath", songs[1].replace("/", "\\"))
	vdj.call("deck 2 level", 0.0)
	vdj.call("deck 2 play", "off")
	vdj.call("deck 2 get_time elapsed absolute", 31000.0)
	var t := Time.get_ticks_msec()
	while not perf.loads_done() and Time.get_ticks_msec() - t < 5000:
		await process_frame
	await _frames(20)
	main.status_label.text = ""
	_clear_focus()
	await _shot("14-dj-perform", 405)
	client.disconnect_from_host()
	main.set_view(0)


func _screenshot() -> void:
	main.set_view(0)
	_playback_tab(0)
	_right_tab(1)
	_viz_look()
	main.viz_panel.set_ui_visible(false)
	_look(_warm())
	main.cue_panel.cue_list.deselect_all()
	main.status_label.text = ""
	root.size = Vector2i(1400, 800)
	DisplayServer.window_set_size(root.size)
	await _frames(20)
	_clear_focus()
	await _shot("screenshot")
	main.viz_panel.set_ui_visible(true)
	root.size = SIZE
	DisplayServer.window_set_size(SIZE)


# ------------------------------------------------------------------ SAVE --

func _frames(n: int) -> void:
	for i in range(n):
		await process_frame


## Save the window (its top `height` pixels and left `width`, when set)
## as <name>.png in the output folder.
func _shot(name: String, height: int = 0, width: int = 0) -> void:
	await _frames(5)
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	if height > 0 or width > 0:
		img = img.get_region(Rect2i(0, 0, width if width > 0 else img.get_width(), height if height > 0 else img.get_height()))
	var path := out_dir.path_join(name + ".png")
	var err := img.save_png(path)
	print("%s %s (%dx%d)" % ["saved" if err == OK else "FAILED", path, img.get_width(), img.get_height()])
