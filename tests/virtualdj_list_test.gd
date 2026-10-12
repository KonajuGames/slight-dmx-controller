extends SceneTree
## Tests for VirtualDjList — the VirtualDJ Virtual Folder (.vdjfolder)
## loader.
##
##   godot --headless --script tests/virtualdj_list_test.gd
##
## Synthetic lists written to user:// are the portable part; the lists
## actually on this machine are then loaded as a sanity pass — SKIPPED
## (not failed) when VirtualDJ isn't installed.

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
	print("== VirtualDJ list loader ==")
	_test_synthetic()
	_test_directory()
	_test_bad_files()
	_test_real_lists()
	print("== %d passed, %d failed, %d skipped ==" % [_p, _f, _s])
	quit(1 if _f > 0 else 0)


const _LIST := """<?xml version="1.0" encoding="UTF-8"?>
<VirtualFolder ordered="yes" singleDrive="yes">
	<song path="D:\\Music\\Smart E’s\\01. Sesame&apos;s Treet.mp3" size="4392884" songlength="213.8" bpm="72.447" key="C" artist="Smart E&apos;s" title="Sesame&apos;s Treet (edit)" remix="edit" idx="2" />
	<song path="D:\\Music\\Happy.m4a" size="8306944" songlength="233.3" bpm="79.998" key="Fm" artist="Pharrell Williams" title="Happy (from &quot;Despicable Me 2&quot;)" idx="0" />
	<song path="D:\\Music\\Majestic &amp; Boney M_\\01 Rasputin.m4a" size="7084518" songlength="186.2" bpm="127.999" key="B" title="Rasputin" idx="1" />
	<song path="D:\\Music\\no-idx.mp3" songlength="10" />
</VirtualFolder>
"""


func _write(path: String, text: String) -> String:
	var abs_path := ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	return abs_path


func _test_synthetic() -> void:
	print("- synthetic list")
	var errors: Array = []
	var list := VirtualDjList.load_file(_write("user://_vdjl/Disco 26.vdjfolder", _LIST), errors)
	ok(list != null, "loads %s" % str(errors))
	if list == null:
		return
	ok(list.name == "Disco 26", "name from file name (%s)" % list.name)
	ok(list.options.get("ordered") == "yes" and list.options.get("singleDrive") == "yes", "folder options")
	ok(list.entries.size() == 4, "4 entries (%d)" % list.entries.size())
	var titles := list.entries.map(func(e): return e.title)
	ok(titles == ["Happy (from \"Despicable Me 2\")", "Rasputin", "Sesame's Treet (edit)", ""],
		"sorted by idx, missing idx keeps file position  %s" % str(titles))
	var e: VirtualDjList.Entry = list.entries[2]
	ok(e.artist == "Smart E's", "&apos; decoded (%s)" % e.artist)
	ok(e.path == "D:/Music/Smart E’s/01. Sesame's Treet.mp3", "path: slashes, UTF-8, entities (%s)" % e.path)
	ok(absf(e.bpm - 72.447) < 1e-4 and e.key == "C" and e.remix == "edit", "bpm (real BPM) / key / remix")
	ok(absf(e.length - 213.8) < 1e-4 and e.file_size == 4392884, "length / size")
	ok(list.entries[1].path == "D:/Music/Majestic & Boney M_/01 Rasputin.m4a", "&amp; in path")
	ok(list.entries[1].display_name() == "Rasputin", "display name without artist")
	ok(list.entries[3].display_name() == "no-idx", "display name from file")
	ok(absf(list.total_length() - (213.8 + 233.3 + 186.2 + 10.0)) < 1e-3, "total length")

	# Resolving against a database.
	var db := VirtualDjDatabase.new()
	db.load_file(_write("user://_vdjl_db.xml", """<?xml version="1.0" encoding="UTF-8"?>
<VirtualDJ_Database Version="8.5">
 <Song FilePath="D:\\Music\\Happy.m4a"><Tags Title="Happy" Bpm="0.75" /></Song>
</VirtualDJ_Database>"""))
	var songs := list.resolve(db)
	ok(songs.size() == 4 and songs[0] != null and songs[0].title == "Happy", "resolve finds database entry")
	ok(songs[1] == null, "resolve gives null for a song not in the database")


func _test_directory() -> void:
	print("- MyLists directory")
	var root := "user://_vdjl_dir"
	_write(root + "/A list.vdjfolder", _LIST)
	_write(root + "/B list.vdjfolder", _LIST)
	_write(root + "/notes.txt", "not a list")
	_write(root + "/Gigs.subfolders/2026.vdjfolder", _LIST)
	_write(root + "/order", "B list\r\n\r\nA list\r\n")
	var lists: Array = []
	var errors: Array = []
	VirtualDjList._load_dir(ProjectSettings.globalize_path(root), "", lists, errors)
	ok(errors.is_empty(), "no errors %s" % str(errors))
	ok(lists.size() == 3, "3 lists, non-.vdjfolder ignored (%d)" % lists.size())
	var sub: Array = lists.filter(func(l): return l.name == "2026")
	ok(sub.size() == 1 and sub[0].group == "Gigs", "subfolder group, .subfolders stripped")
	var order := VirtualDjList._read_order(ProjectSettings.globalize_path(root + "/order"))
	ok(Array(order) == ["B list", "A list"], "order file: CRLF, blank lines %s" % str(order))


func _test_bad_files() -> void:
	print("- bad input")
	var errors: Array = []
	ok(VirtualDjList.load_file("user://_vdjl_missing.vdjfolder", errors) == null, "missing file -> null")
	ok(VirtualDjList.load_file(_write("user://_vdjl_other.vdjfolder",
		"<?xml version=\"1.0\"?><Other/>"), errors) == null, "non-Virtual-Folder XML -> null")
	ok(errors.size() == 2, "errors recorded (%d)" % errors.size())
	var empty := VirtualDjList.load_file(_write("user://_vdjl_empty.vdjfolder",
		"<?xml version=\"1.0\"?><VirtualFolder />"), errors)
	ok(empty != null and empty.entries.is_empty(), "empty list loads")


func _test_real_lists() -> void:
	print("- lists on this machine")
	var dirs := VirtualDjList.find_list_dirs()
	if dirs.is_empty():
		skip("no VirtualDJ MyLists directory found")
		return
	for d in dirs:
		print("    found ", d)
	var errors: Array = []
	var lists := VirtualDjList.load_all(errors)
	ok(errors.is_empty(), "every list loaded %s" % str(errors))
	ok(not lists.is_empty(), "lists loaded")
	var db := VirtualDjDatabase.new()
	db.load_all()
	var total := 0
	var missing := 0
	var bad_bpm := 0
	for list: VirtualDjList in lists:
		var songs := list.resolve(db)
		var m := songs.count(null)
		total += songs.size()
		missing += m
		for e in list.entries:
			if e.bpm != 0.0 and (e.bpm < 20.0 or e.bpm > 400.0):
				bad_bpm += 1
		print("    %-24s %-8s %3d tracks  %5.1f min  %d not in database" % [
			list.name, list.group, list.entries.size(), list.total_length() / 60.0, m])
	ok(total > 0, "lists have tracks")
	ok(bad_bpm == 0, "list BPMs are real BPM values (%d outside 20..400)" % bad_bpm)
	print("    %d of %d entries resolve to a database song" % [total - missing, total])
