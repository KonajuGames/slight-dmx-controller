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
	ok(menu.item_count == 5 and menu.get_item_text(4).begins_with("Remove Lighting Timelines"),
		"a track's right-click menu")
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
