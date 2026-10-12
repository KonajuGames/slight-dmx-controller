extends SceneTree
## Tests for MusicBrowserPanel — the "Music Library" view — and switching
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
	print("== Music Library view ==")
	_test_folder_listing()
	_test_panel()
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
	ok(top[-1].get_text(0) == "VirtualDJ Virtual Folders", "Virtual Folders after the drives")
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


func _test_main_scene() -> void:
	print("- main scene view switch")
	var main: Control = load("res://main.tscn").instantiate()
	root.add_child(main)
	ok(main.view_option.item_count == 2 and main.view_option.selected == 0, "View selector, Console first")
	ok(main._console_view.visible and not main.music_panel.visible, "starts in the Console view")
	ok(not main.music_panel._loaded, "Music Library not loaded until shown")
	main.view_option.select(1)
	main.view_option.item_selected.emit(1)
	ok(not main._console_view.visible and main.music_panel.visible, "switches to the Music Library")
	ok(main.music_panel._loaded, "loads on first show")
	main.set_view(0)
	ok(main._console_view.visible and not main.music_panel.visible and main.view_option.selected == 0,
		"and back to the Console")
	main.queue_free()
