extends SceneTree
## Tests for MusicBrowserPanel — DJ Edit Mode — and switching
## to it in the main shell.
##
##   godot --headless --script tests/music_browser_test.gd
##
## A synthetic folder under user:// is the portable part; the drives and
## VirtualDJ Virtual Folders actually on this machine are a sanity pass,
## SKIPPED where VirtualDJ isn't installed.

var _p := 0
var _f := 0
var _s := 0


func ok(cond: bool, label: String) -> void:
	if cond:
		_p += 1
		print("  ok   ", label)
	else:
		_f += 1
		print("  FAIL ", label)


func skip(label: String) -> void:
	_s += 1
	print("  skip ", label)


func _initialize() -> void:
	# Nodes added during _initialize don't get _ready() until the first
	# frame, so run the cases from there.
	_run.call_deferred()


func _run() -> void:
	print("== DJ Edit Mode (music library) ==")
	_test_folder_listing()
	_test_panel()
	await _test_timeline_icons()
	await _test_regenerate()
	_test_main_scene()
	print("== %d passed, %d failed, %d skipped ==" % [_p, _f, _s])
	quit(1 if _f > 0 else 0)


func _touch(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("x")
	f.close()


func _fixture_dir() -> String:
	var root := ProjectSettings.globalize_path("user://_music_browser")
	for f in ["Track 10.mp3", "Track 2.M4A", "song.flac", "notes.txt", "cover.jpg",
			"Album B/x.mp3", "album a/y.wav", "Album B/deeper/z.ogg"]:
		_touch(root.path_join(f))
	return root


func _test_folder_listing() -> void:
	print("- folder listing")
	var root := _fixture_dir()
	var files := MusicBrowserPanel.list_audio_files(root)
	ok(Array(files) == ["song.flac", "Track 2.M4A", "Track 10.mp3"],
		"audio only, any case, natural order %s" % str(files))
	var dirs := MusicBrowserPanel.list_subfolders(root)
	ok(Array(dirs) == ["album a", "Album B"], "subfolders, natural order %s" % str(dirs))
	ok(MusicBrowserPanel.list_audio_files(root.path_join("nope")).is_empty(), "missing folder -> nothing")


func _test_panel() -> void:
	print("- panel")
	var panel := MusicBrowserPanel.new()
	panel.visible = false
	root.add_child(panel)
	panel.ensure_loaded()
	var tree: Tree = panel._tree
	var top := tree.get_root().get_children()
	var drives := DirAccess.get_drive_count()
	ok(top.size() == drives + 1, "one item per drive + Virtual Folders (%d)" % top.size())
	ok(top[-1].get_text(0) == "VirtualDJ Lists", "VirtualDJ Lists (its Virtual Folders) after the drives")
	ok(top[0].collapsed and top[0].get_child_count() == 1, "drives start collapsed with a placeholder")

	# Lazy expansion, on a synthetic folder item.
	var fixture := _fixture_dir()
	var item := tree.create_item(tree.get_root())
	item.set_metadata(0, {"kind": "dir", "path": fixture})
	panel._add_placeholder(item)
	item.collapsed = true
	item.collapsed = false     # emits item_collapsed -> fills it
	var kids := item.get_children().map(func(c): return c.get_text(0))
	ok(kids == ["album a", "Album B"], "expanding loads subfolders, placeholder gone %s" % str(kids))
	var b := item.get_child(1)
	ok(b.get_child_count() == 1 and b.collapsed, "subfolders are lazily expandable too")
	b.collapsed = false
	ok(b.get_child_count() == 1 and b.get_child(0).get_text(0) == "deeper", "second level")
	var a := item.get_child(0)
	a.collapsed = false
	ok(a.get_child_count() == 0, "a folder without subfolders ends up empty")

	# Selecting a folder lists its music.
	tree.set_selected(item, 0)
	var rows := panel.rows()
	ok(rows.size() == 3, "selecting a folder lists its 3 audio files (%d)" % rows.size())
	ok(rows.map(func(r): return r["title"]) == ["song", "Track 2", "Track 10"], "titles from file names")
	ok(not rows[0]["missing"], "files exist")
	ok(panel._list.get_root().get_child_count() == 3, "list shows 3 rows")
	ok(panel._heading.text.begins_with(fixture) and "3 tracks" in panel._heading.text,
		"heading: %s" % panel._heading.text)

	panel.sort_by(MusicBrowserPanel.Col.TITLE, false)
	ok(panel.rows().map(func(r): return r["title"]) == ["Track 10", "Track 2", "song"], "sort by title, descending")
	ok(panel._list.get_column_title(MusicBrowserPanel.Col.TITLE).ends_with("▼"), "sort indicator")
	panel.sort_by(MusicBrowserPanel.Col.NUM, true)
	ok(panel.rows().map(func(r): return r["num"]) == [1, 2, 3], "back to folder order")

	# VirtualDJ Virtual Folders on this machine.
	var vdj: TreeItem = top[-1]
	var lists: Array = vdj.get_children().filter(func(c): return c.get_metadata(0) is Dictionary)
	if lists.is_empty():
		skip("no VirtualDJ Virtual Folders on this machine")
	else:
		var first: TreeItem = lists[0]
		var list: VirtualDjList = first.get_metadata(0)["list"]
		tree.set_selected(first, 0)
		rows = panel.rows()
		ok(rows.size() == list.entries.size(), "%s: all %d tracks listed" % [list.name, rows.size()])
		ok(rows.all(func(r): return r["title"] != ""), "every track has a title")
		var known := rows.filter(func(r): return r["bpm"] > 0.0).size()
		print("    %s: %d tracks, %d with a BPM, heading '%s'" % [list.name, rows.size(), known, panel._heading.text])
		ok(known > 0, "BPMs filled in from VirtualDJ")
		var r0: Dictionary = rows[0]
		var song := panel._db.find_song(r0["path"])
		ok(song == null or r0["bpm"] == song.best_bpm(), "BPM is the database's best_bpm()")
	panel.queue_free()


## A fake song: `n` bytes, varied by `seed_v`.
func _song_file(path: String, seed_v: int, n: int) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var b := PackedByteArray()
	b.resize(n)
	for i in range(0, n, 31):
		b[i] = (i * seed_v) & 0xFF
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(b)
	f.close()


func _test_timeline_icons() -> void:
	print("- the timelines icon in the track list")
	var dir := ProjectSettings.globalize_path("user://_music_icons")
	var songs := dir.path_join("songs")
	_song_file(songs.path_join("a.mp3"), 3, 120000)     # saved here
	_song_file(songs.path_join("b.mp3"), 5, 130000)     # saved elsewhere, since moved here
	_song_file(songs.path_join("c.mp3"), 7, 140000)     # none
	_song_file(songs.path_join("d.mp3"), 9, 130000)     # none, but b's size
	_song_file(dir.path_join("old/b.mp3"), 5, 130000)
	var store := TimelineStore.new(dir.path_join("show.timelines"))
	store.save_song(songs.path_join("a.mp3"), {"tracks": {"master": {"dimmer": [[1.0, 0.5]]}}})
	store.save_song(dir.path_join("old/b.mp3"), {"tracks": {"master": {"dimmer": [[2.0, 0.5]]}}})
	DirAccess.remove_absolute(dir.path_join("old/b.mp3"))

	var panel := MusicBrowserPanel.new()
	root.add_child(panel)
	await process_frame
	panel.timeline().set_timeline_store(TimelineStore.new(dir.path_join("show.timelines")))
	panel.show_folder(songs)
	var st: TimelineStore = panel.timeline().timeline_store
	ok(panel.has_timelines_mark(songs.path_join("a.mp3")), "a song saved at this path: marked straight away (from the index)")
	ok(not panel.has_timelines_mark(songs.path_join("c.mp3")) and not st._fingerprints.has(songs.path_join("c.mp3")),
		"a song no indexed song's size: unmarked without reading it")
	ok(not panel.timeline_marks_done(), "same-size songs are checked in the background")
	var t := Time.get_ticks_msec()
	while not panel.timeline_marks_done() and Time.get_ticks_msec() - t < 5000:
		await process_frame
	ok(panel.has_timelines_mark(songs.path_join("b.mp3")), "a moved song: found by fingerprint and marked")
	ok(not panel.has_timelines_mark(songs.path_join("d.mp3")), "same size, different song: unmarked")
	var items: Dictionary = panel._items
	var ia: TreeItem = items[songs.path_join("a.mp3")]
	var ic: TreeItem = items[songs.path_join("c.mp3")]
	ok(ia.get_icon(MusicBrowserPanel.Col.TITLE) == MusicBrowserPanel.timeline_icon()
		and ia.get_tooltip_text(MusicBrowserPanel.Col.TITLE) == MusicBrowserPanel.HAS_TIMELINES_TIP,
		"marked: the node-line icon before the title, with a tooltip")
	var blank := ic.get_icon(MusicBrowserPanel.Col.TITLE)
	ok(blank != null and blank != MusicBrowserPanel.timeline_icon() and blank.get_size() == MusicBrowserPanel.timeline_icon().get_size(),
		"unmarked: a blank the same size, so titles line up")
	var img := MusicBrowserPanel.timeline_icon().get_image()
	var lit := 0
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			if img.get_pixel(x, y).a > 0.5:
				lit += 1
	ok(img.get_size() == Vector2i(16 + MusicBrowserPanel.ICON_GAP, 12) and lit > 20 and lit < 120,
		"the icon: 16 x 12 plus a gap before the title, a thin line with dots (%d px)" % lit)
	# Saving a song's timelines marks it.
	panel.timeline().timelines_saved.emit(songs.path_join("c.mp3"))
	ok(panel.has_timelines_mark(songs.path_join("c.mp3"))
		and ic.get_icon(MusicBrowserPanel.Col.TITLE) == MusicBrowserPanel.timeline_icon(), "saving a song's timelines marks it")
	# The track menu: Remove Lighting Timelines asks, then deletes and unmarks.
	var menu := panel.track_menu()
	ok(menu.item_count == 6 and menu.get_item_text(4).begins_with("Regenerate Lighting Timelines")
		and menu.get_item_text(5).begins_with("Remove Lighting Timelines"), "a track's right-click menu")
	var dlg := panel.confirm_remove_timelines(songs.path_join("a.mp3"))
	ok(dlg != null and "a" in dlg.dialog_text, "removing asks first")
	ok(panel.has_timelines_mark(songs.path_join("a.mp3")), "...and nothing's removed until confirmed")
	dlg.confirmed.emit()
	ok(not panel.has_timelines_mark(songs.path_join("a.mp3"))
		and ia.get_icon(MusicBrowserPanel.Col.TITLE) != MusicBrowserPanel.timeline_icon(), "confirmed: unmarked")
	var fresh := TimelineStore.new(dir.path_join("show.timelines"))
	ok(not fresh.has_song(songs.path_join("a.mp3")) and fresh.has_song(songs.path_join("b.mp3")),
		"...its timelines gone from the show, others kept")
	panel.track_menu_action(MusicBrowserPanel.TM_COPY_PATH, songs.path_join("b.mp3"))
	ok(DisplayServer.clipboard_get() == songs.path_join("b.mp3") or DisplayServer.get_name() == "headless",
		"Copy Path")
	# Another show's folder (here, an empty one): marks cleared.
	panel.timeline().set_timeline_store(TimelineStore.new(dir.path_join("other.timelines")))
	ok(not panel.has_timelines_mark(songs.path_join("a.mp3")) and panel.timeline_marks_done(), "another show: its own marks (none)")
	panel.queue_free()
	await process_frame
	for d in [dir.path_join("show.timelines"), songs, dir.path_join("old"), dir]:
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d.path_join(f))
		DirAccess.remove_absolute(d)


## A ready-made structure for a 60 s song at 120 BPM (so no decoding).
func _analysis() -> SongAnalysis:
	var a := SongAnalysis.new()
	a.duration = 60.0
	a.bpm = 120.0
	for i in range(120):
		a.beat_times.append(i * 0.5)
		if i % 4 == 0:
			a.downbeats.append(i * 0.5)
	a.sections = [{"start": 0.0, "end": 16.0, "label": "Intro", "energy": 0.2},
		{"start": 16.0, "end": 44.0, "label": "Chorus", "energy": 0.9},
		{"start": 44.0, "end": 60.0, "label": "Outro", "energy": 0.3}]
	return a


## A 20 s mono WAV of clicks at `bpm` (louder every fourth), to analyse.
func _beat_wav(path: String, bpm: float) -> void:
	var rate := 22050
	var data := PackedByteArray()
	data.resize(rate * 20 * 2)
	var beat := 60.0 / bpm
	for i in range(int(20.0 / beat)):
		var amp := 24000.0 if i % 4 == 0 else 12000.0
		var s0 := int(i * beat * rate)
		for j in range(mini(1500, rate * 20 - s0)):
			var v := int(amp * sin(j * 0.25) * exp(-j / 300.0))
			data.encode_s16((s0 + j) * 2, v)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(36 + data.size())
	f.store_buffer("WAVEfmt ".to_ascii_buffer())
	f.store_32(16)
	f.store_16(1)
	f.store_16(1)
	f.store_32(rate)
	f.store_32(rate * 2)
	f.store_16(2)
	f.store_16(16)
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(data.size())
	f.store_buffer(data)
	f.close()


func _right_click(panel: MusicBrowserPanel, path: String) -> void:
	var r: Rect2 = panel._list.get_item_area_rect(panel._items[path])
	panel._on_track_clicked(r.get_center(), MOUSE_BUTTON_RIGHT)


func _wait_batch(panel: MusicBrowserPanel) -> void:
	var t := Time.get_ticks_msec()
	while panel.batch().is_busy() and Time.get_ticks_msec() - t < 20000:
		await process_frame


func _test_regenerate() -> void:
	print("- regenerating songs' timelines from the list")
	var dir := ProjectSettings.globalize_path("user://_music_regen")
	var songs := dir.path_join("songs")
	var p := []
	for k in range(4):
		_song_file(songs.path_join("s%d.mp3" % k), k + 1, 100000 + k * 1000)
		p.append(songs.path_join("s%d.mp3" % k))
	var panel := MusicBrowserPanel.new()
	root.add_child(panel)
	await process_frame
	var tl := panel.timeline()
	panel.show_folder(songs)
	# No show saved yet: nowhere to keep them.
	panel.select_paths([p[0]])
	_right_click(panel, p[0])
	var menu := panel.track_menu()
	var regen := menu.get_item_index(MusicBrowserPanel.TM_REGENERATE)
	ok(menu.is_item_disabled(regen) and panel.regenerate([p[0]]) == 0, "no show saved yet: Regenerate is greyed out")
	menu.hide()
	tl.set_timeline_store(TimelineStore.new(dir.path_join("show.timelines")))
	for k in range(3):
		tl.add_structure(p[k], _analysis())          # analysed already (this session)
	# Several selected, whole rows.
	panel.select_paths([p[0], p[1], p[2]])
	ok(panel.selected_paths() == [p[0], p[1], p[2]], "several tracks selected")
	var it1: TreeItem = panel._items[p[1]]
	ok(it1.is_selected(0) and it1.is_selected(MusicBrowserPanel.Col.FILE), "...whole rows")
	_right_click(panel, p[1])
	ok(panel.selected_paths().size() == 3 and menu.get_item_text(regen) == "Regenerate Lighting Timelines (3 songs)"
		and not menu.is_item_disabled(regen), "right-click one of them: the menu's for all three (%s)" % menu.get_item_text(regen))
	menu.hide()
	# Run: a couple at a time.
	panel.batch().workers = 2
	var most := [0]
	var saw := {}
	panel.batch().progress.connect(func(path: String, f: float):
		most[0] = maxi(most[0], panel.batch()._running.size())
		saw[path] = maxf(saw.get(path, -1.0), f))
	panel.track_menu_action(MusicBrowserPanel.TM_REGENERATE)
	ok(panel.batch().is_busy() and panel._progress.size() == 3, "Regenerate: all three under way or queued, each with a bar")
	await _wait_batch(panel)
	var store := TimelineStore.new(dir.path_join("show.timelines"))
	var all_saved := true
	for k in range(3):
		var d := store.load_song(p[k])
		all_saved = all_saved and not d.get("tracks", {}).get("master", {}).get("dimmer", []).is_empty() \
			and panel.has_timelines_mark(p[k])
	ok(all_saved, "each song's show generated, saved and marked")
	ok(not store.has_song(p[3]), "...an unselected one left alone")
	ok(most[0] <= 2 and saw.size() == 3 and saw.values().all(func(f): return f == 1.0), "at most two at a time, each bar run to full")
	ok(panel._progress.is_empty(), "the bars go when they're done")
	# The undo history: opening a regenerated song, it's an undo step.
	tl.open(p[0])
	ok(tl.can_undo() and not tl.master_track().dimmer_nodes.is_empty(), "opened later: its new show, and undo")
	tl.undo()
	ok(tl.master_track().dimmer_nodes.is_empty(), "...undo takes it back to what it was (nothing)")
	tl.redo()
	# The open song: its tracks change in place, saved.
	var edited := PackedVector2Array([Vector2(0, 0.33), Vector2(60, 0.33)])
	tl.master_track().dimmer_nodes = edited
	tl._mark_dirty()
	var steps: int = tl._hist()["undo"].size()
	panel.regenerate([p[0]])
	await _wait_batch(panel)
	ok(tl.master_track().dimmer_nodes != edited and not tl.has_unsaved_timelines() and tl._hist()["undo"].size() == steps + 1,
		"the open song: its tracks replaced in place, saved, one undo step")
	tl.undo()
	ok(tl.master_track().dimmer_nodes == edited, "...undo brings back the edit")
	# Not analysed yet, and it can't be (not really audio): it says why.
	var err := [""]
	panel.batch().done.connect(func(path: String, e: String):
		if path == p[3]:
			err[0] = e)
	panel.regenerate([p[3]])
	await _wait_batch(panel)
	var it3: TreeItem = panel._items[p[3]]
	ok(err[0] != "" and it3.get_tooltip_text(MusicBrowserPanel.Col.TITLE).begins_with("Couldn't regenerate")
		and not panel.has_timelines_mark(p[3]), "a song that can't be analysed: not marked, its tooltip says why (%s)" % err[0])
	# Real songs, analysed side by side on their own threads.
	if SongAnalyzer.fast_available():
		var wavs := [songs.path_join("beat a.wav"), songs.path_join("beat b.wav")]
		_beat_wav(wavs[0], 120.0)
		_beat_wav(wavs[1], 100.0)
		panel.show_folder(songs)
		panel.batch().workers = 2
		most[0] = 0
		var errs := []
		panel.batch().done.connect(func(path: String, e: String):
			if path in wavs and e != "":
				errs.append(e))
		panel.regenerate(wavs)
		await _wait_batch(panel)
		store = TimelineStore.new(dir.path_join("show.timelines"))
		ok(errs.is_empty() and wavs.all(func(w): return store.has_song(w) and tl.cached_structure(w) != null),
			"songs not analysed yet: analysed (two at once: %d), then generated and saved %s" % [most[0], str(errs)])
	else:
		skip("analysing songs needs the native extension")
	# Another show: anything queued is dropped.
	panel.batch().workers = 1
	panel.regenerate([p[1], p[2]])
	tl.set_timeline_store(TimelineStore.new(dir.path_join("other.timelines")))
	ok(not panel.batch().is_busy() and panel._progress.is_empty(), "another show: the queue's dropped")
	panel.queue_free()
	await process_frame
	for d in [dir.path_join("show.timelines"), dir.path_join("other.timelines"), songs, dir]:
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d.path_join(f))
		DirAccess.remove_absolute(d)


func _test_main_scene() -> void:
	print("- main scene view switch")
	var main: Control = load("res://main.tscn").instantiate()
	root.add_child(main)
	ok(main.view_option.item_count == 3 and main.view_option.selected == 0
		and main.view_option.get_item_text(1) == "DJ Edit Mode" and main.view_option.get_item_text(2) == "DJ Perform Mode",
		"View selector: Console, DJ Edit Mode, DJ Perform Mode")
	ok(main._console_view.visible and not main.music_panel.visible and not main.perform_panel.visible, "starts in the Console view")
	ok(not main.music_panel._loaded, "DJ Edit Mode not loaded until shown")
	main.view_option.select(1)
	main.view_option.item_selected.emit(1)
	ok(not main._console_view.visible and main.music_panel.visible, "switches to DJ Edit Mode")
	ok(main.music_panel._loaded, "loads on first show")
	ok(not main.performer.is_active(), "no OS2L listener outside DJ Perform Mode")
	main.performer.advertise = false
	main.performer.port = 19961
	main.set_view(2)
	ok(main.perform_panel.visible and not main.music_panel.visible and not main._console_view.visible,
		"switches to DJ Perform Mode")
	ok(main.performer.is_listening() and main.performer.os2l.get_port() == 19961, "which starts the OS2L listener")
	main.set_view(1)
	ok(not main.performer.is_active() and not main.performer.is_listening(), "leaving it stops the listener")
	main.set_view(0)
	ok(main._console_view.visible and not main.music_panel.visible and main.view_option.selected == 0,
		"and back to the Console")
	main.queue_free()
