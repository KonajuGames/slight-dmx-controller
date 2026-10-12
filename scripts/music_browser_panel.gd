class_name MusicBrowserPanel
extends HSplitContainer
## The "Music Library" view: a narrow tree on the left — this machine's
## drives and folders, then VirtualDJ's Virtual Folders — and, filling the
## rest, the music in whatever's selected there.
##
## Folders load as they're expanded (a drive can hold far too many to
## walk up front). Track details come from VirtualDJ's database where it
## knows the file (artist / title / BPM / key / length, the same values
## its decks use), falling back to the file name. The database and lists
## load the first time the view is shown, not at app start.

## Audio files listed in a folder (lower-case extensions).
const AUDIO_EXTS := ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "wma", "aif", "aiff"]

enum Col { NUM, TITLE, ARTIST, BPM, KEY, LENGTH, ALBUM, GENRE, FILE }
const COL_TITLES := ["#", "Title", "Artist", "BPM", "Key", "Length", "Album", "Genre", "File"]
## Sort key per column (a field of the row dictionaries built below).
const COL_KEYS := ["num", "title", "artist", "bpm", "key", "length", "album", "genre", "file"]

const _PLACEHOLDER := "_placeholder"
const _MISSING_COLOR := Color(1.0, 0.5, 0.5)

var _tree: Tree                 # left: drives / folders / Virtual Folders
var _list: Tree                 # right: the tracks
var _heading: Label
var _list_view: Control         # the heading + track list
var _timeline: MusicTimeline    # replaces _list_view while a track is open
var _db: VirtualDjDatabase = null
var _lists: Array = []          # [VirtualDjList]
var _loaded := false

var _rows: Array = []           # [{num, title, artist, bpm, key, length, album, genre, file, path, missing}]
var _sort_col := Col.NUM
var _sort_asc := true


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	split_offset = 260

	_tree = Tree.new()
	_tree.custom_minimum_size = Vector2(220, 0)
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_SINGLE
	_tree.item_collapsed.connect(_on_item_collapsed)
	_tree.item_selected.connect(_on_folder_selected)
	# Clicking the folder that's already selected doesn't re-select it, but
	# should still leave a track's timeline for the list.
	_tree.item_mouse_selected.connect(func(_pos: Vector2, _button: int): _on_folder_clicked())
	add_child(_tree)

	# The right side shows either the track list or a track's timeline.
	var right_holder := VBoxContainer.new()
	right_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(right_holder)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)
	right_holder.add_child(right)
	_list_view = right

	_timeline = MusicTimeline.new()
	_timeline.visible = false
	right_holder.add_child(_timeline)

	_heading = Label.new()
	_heading.text = "Select a folder or a VirtualDJ Virtual Folder."
	_heading.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	right.add_child(_heading)

	_list = Tree.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.hide_root = true
	_list.columns = COL_TITLES.size()
	_list.column_titles_visible = true
	_list.select_mode = Tree.SELECT_ROW
	# Pad cells so a right-aligned column doesn't run into the next one's text.
	_list.add_theme_constant_override("inner_item_margin_left", 6)
	_list.add_theme_constant_override("inner_item_margin_right", 6)
	for c in range(COL_TITLES.size()):
		_list.set_column_title(c, COL_TITLES[c])
		_list.set_column_clip_content(c, true)
	for c in [Col.NUM, Col.BPM, Col.KEY, Col.LENGTH]:
		_list.set_column_expand(c, false)
		# Wide enough for 4-digit row numbers / "150.0" / "C#m" / "12:34"
		# inside the cell padding below.
		_list.set_column_custom_minimum_width(c, 64)
		_list.set_column_title_alignment(c, HORIZONTAL_ALIGNMENT_RIGHT)
	_list.set_column_expand_ratio(Col.TITLE, 3)
	_list.set_column_expand_ratio(Col.ARTIST, 2)
	_list.set_column_expand_ratio(Col.ALBUM, 2)
	_list.set_column_expand_ratio(Col.GENRE, 1)
	_list.set_column_expand_ratio(Col.FILE, 3)
	_list.column_title_clicked.connect(_on_column_title_clicked)
	# Double-click (or Enter) a track: its timeline replaces the list.
	_list.item_activated.connect(_on_track_activated)
	right.add_child(_list)

	visibility_changed.connect(func():
		if is_visible_in_tree():
			ensure_loaded())


## Build the tree (and load VirtualDJ's database and lists) if that hasn't
## happened yet. Called when the view is first shown.
func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_db = VirtualDjDatabase.new()
	_db.load_all()
	_lists = VirtualDjList.load_all()
	_build_tree()


# ------------------------------------------------------------------ TREE --

func _build_tree() -> void:
	_tree.clear()
	var root := _tree.create_item()

	for i in range(DirAccess.get_drive_count()):
		var drive := DirAccess.get_drive_name(i)
		if drive == "":
			continue
		var path := drive if drive.ends_with("/") else drive + "/"
		var item := _tree.create_item(root)
		item.set_text(0, drive)
		item.set_tooltip_text(0, path)
		item.set_metadata(0, {"kind": "dir", "path": path})
		_add_placeholder(item)
		item.collapsed = true

	var vdj := _tree.create_item(root)
	vdj.set_text(0, "VirtualDJ Virtual Folders")
	vdj.set_selectable(0, false)
	vdj.set_custom_color(0, get_theme_color("font_disabled_color", "Tree"))
	if _lists.is_empty():
		var none := _tree.create_item(vdj)
		none.set_text(0, "(none found)")
		none.set_selectable(0, false)
	var groups := {"": vdj}     # "Gigs/2026" -> its TreeItem
	for list in _lists:
		var item := _tree.create_item(_group_item(groups, list.group))
		item.set_text(0, list.name)
		item.set_tooltip_text(0, list.path)
		item.set_metadata(0, {"kind": "list", "list": list})


## The tree item for a Virtual Folder group path, created on first use.
func _group_item(groups: Dictionary, group: String) -> TreeItem:
	if groups.has(group):
		return groups[group]
	var slash := group.rfind("/")
	var parent := _group_item(groups, group.substr(0, slash) if slash >= 0 else "")
	var item := _tree.create_item(parent)
	item.set_text(0, group.substr(slash + 1))
	item.set_selectable(0, false)
	groups[group] = item
	return item


## A dummy child so a folder shows an expand arrow before its contents
## are read (replaced when it's first expanded).
func _add_placeholder(item: TreeItem) -> void:
	var p := _tree.create_item(item)
	p.set_text(0, "…")
	p.set_selectable(0, false)
	p.set_metadata(0, {"kind": _PLACEHOLDER})


func _on_item_collapsed(item: TreeItem) -> void:
	if item.collapsed:
		return
	var first := item.get_first_child()
	if first == null or not (first.get_metadata(0) is Dictionary) \
			or first.get_metadata(0).get("kind") != _PLACEHOLDER:
		return
	first.free()
	expand_folder(item)


## Fill a folder item with its subfolders (each lazily expandable).
func expand_folder(item: TreeItem) -> void:
	var path: String = item.get_metadata(0)["path"]
	for name in list_subfolders(path):
		var child := _tree.create_item(item)
		child.set_text(0, name)
		child.set_tooltip_text(0, path.path_join(name))
		child.set_metadata(0, {"kind": "dir", "path": path.path_join(name)})
		_add_placeholder(child)
		child.collapsed = true


## A folder's visible subfolders, in natural order. Hidden and system
## folders (Recycle Bin, System Volume Information, ...) are skipped.
static func list_subfolders(path: String) -> PackedStringArray:
	var da := DirAccess.open(path)
	if da == null:
		return PackedStringArray()
	da.include_hidden = false
	var names := da.get_directories()
	var sorted := Array(names)
	sorted.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
	return PackedStringArray(sorted)


## A folder's audio files (names only), in natural order.
static func list_audio_files(path: String) -> PackedStringArray:
	var da := DirAccess.open(path)
	if da == null:
		return PackedStringArray()
	da.include_hidden = false
	var out := []
	for f in da.get_files():
		if f.get_extension().to_lower() in AUDIO_EXTS:
			out.append(f)
	out.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
	return PackedStringArray(out)


func _on_folder_selected() -> void:
	var item := _tree.get_selected()
	if item == null or not (item.get_metadata(0) is Dictionary):
		return
	var meta: Dictionary = item.get_metadata(0)
	match meta.get("kind"):
		"dir":
			show_folder(meta["path"])
		"list":
			show_list(meta["list"])


func _on_folder_clicked() -> void:
	var item := _tree.get_selected()
	if item != null and item.get_metadata(0) is Dictionary \
			and item.get_metadata(0).get("kind") in ["dir", "list"]:
		show_track_list()


func _on_track_activated() -> void:
	var it := _list.get_selected()
	if it == null:
		return
	for r in _rows:
		if r["path"] == it.get_metadata(0):
			open_track(r)
			return


## Replace the track list with `row`'s timeline.
func open_track(row: Dictionary) -> void:
	_list_view.visible = false
	_timeline.visible = true
	_timeline.open(row["path"], _db.find_song(row["path"]) if _db != null else null)


## Back from a track's timeline to the track list.
func show_track_list() -> void:
	_timeline.visible = false
	_list_view.visible = true


## Whether a track's timeline is showing (rather than the track list).
func is_timeline_shown() -> bool:
	return _timeline.visible


func timeline() -> MusicTimeline:
	return _timeline


# ------------------------------------------------------------------ LIST --

## List the music in a folder on disk (not its subfolders).
func show_folder(path: String) -> void:
	ensure_loaded()
	show_track_list()
	_rows.clear()
	var files := list_audio_files(path)
	for i in range(files.size()):
		var full := path.path_join(files[i])
		_rows.append(_row(i + 1, full, _db.find_song(full), null, files[i]))
	_set_heading(path, _rows)
	_sort_col = Col.NUM
	_sort_asc = true
	_fill_list()


## List a VirtualDJ Virtual Folder's tracks, in its order.
func show_list(list: VirtualDjList) -> void:
	ensure_loaded()
	show_track_list()
	_rows.clear()
	for i in range(list.entries.size()):
		var e: VirtualDjList.Entry = list.entries[i]
		_rows.append(_row(i + 1, e.path, _db.find_song(e.path), e, e.path))
	_set_heading("%s  (VirtualDJ Virtual Folder)" % list.name, _rows)
	_sort_col = Col.NUM
	_sort_asc = true
	_fill_list()


## The rows currently listed, in display order.
func rows() -> Array:
	return _rows


## One list row. Prefers VirtualDJ's database entry (the values its decks
## use), then the Virtual Folder's cached copy, then the file name.
func _row(num: int, path: String, song: VirtualDjDatabase.Song, entry: VirtualDjList.Entry,
		file_label: String) -> Dictionary:
	var r := {"num": num, "path": path, "file": file_label,
		"title": "", "artist": "", "bpm": 0.0, "key": "", "length": 0.0, "album": "", "genre": "",
		"missing": not FileAccess.file_exists(path)}
	if song != null:
		r["title"] = song.title
		r["artist"] = song.artist
		r["bpm"] = song.best_bpm()
		r["key"] = song.best_key()
		r["length"] = song.length
		r["album"] = song.album
		r["genre"] = song.genre
	elif entry != null:
		r["title"] = entry.title
		r["artist"] = entry.artist
		r["bpm"] = entry.bpm
		r["key"] = entry.key
		r["length"] = entry.length
	if r["title"] == "":
		r["title"] = path.get_file().get_basename()
	return r


func _set_heading(what: String, rows_: Array) -> void:
	var total := 0.0
	var missing := 0
	for r in rows_:
		total += r["length"]
		if r["missing"]:
			missing += 1
	var text := "%s — %d track%s" % [what, rows_.size(), "" if rows_.size() == 1 else "s"]
	if total > 0.0:
		text += " · " + _fmt_duration(total)
	if missing > 0:
		text += " · %d missing" % missing
	_heading.text = text
	_heading.tooltip_text = text


func _fill_list() -> void:
	_list.clear()
	var root := _list.create_item()
	for r in _rows:
		var it := _list.create_item(root)
		it.set_text(Col.NUM, str(r["num"]))
		it.set_text(Col.TITLE, r["title"])
		it.set_text(Col.ARTIST, r["artist"])
		it.set_text(Col.BPM, "%.1f" % r["bpm"] if r["bpm"] > 0.0 else "")
		it.set_text(Col.KEY, r["key"])
		it.set_text(Col.LENGTH, _fmt_time(r["length"]) if r["length"] > 0.0 else "")
		it.set_text(Col.ALBUM, r["album"])
		it.set_text(Col.GENRE, r["genre"])
		it.set_text(Col.FILE, r["file"])
		for c in [Col.NUM, Col.BPM, Col.KEY, Col.LENGTH]:
			it.set_text_alignment(c, HORIZONTAL_ALIGNMENT_RIGHT)
		it.set_tooltip_text(Col.FILE, r["path"])
		it.set_metadata(0, r["path"])
		if r["missing"]:
			for c in range(COL_TITLES.size()):
				it.set_custom_color(c, _MISSING_COLOR)
			it.set_tooltip_text(Col.TITLE, "File not found: " + r["path"])
	_update_column_titles()


func _on_column_title_clicked(column: int, mouse_button: int) -> void:
	if mouse_button != MOUSE_BUTTON_LEFT:
		return
	sort_by(column, not _sort_asc if column == _sort_col else true)


## Sort the listed tracks by a column (Col.*). Ties keep list order.
func sort_by(column: int, ascending: bool) -> void:
	_sort_col = column
	_sort_asc = ascending
	var key: String = COL_KEYS[column]
	_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var va = a[key]
		var vb = b[key]
		if va is String:
			var c := (va as String).naturalnocasecmp_to(vb)
			if c != 0:
				return c < 0 if ascending else c > 0
		elif va != vb:
			return va < vb if ascending else va > vb
		return a["num"] < b["num"])
	_fill_list()


func _update_column_titles() -> void:
	for c in range(COL_TITLES.size()):
		var t: String = COL_TITLES[c]
		if c == _sort_col:
			t += " ▲" if _sort_asc else " ▼"
		_list.set_column_title(c, t)


static func _fmt_time(seconds: float) -> String:
	var s := roundi(seconds)
	return "%d:%02d" % [floori(s / 60.0), s % 60]


static func _fmt_duration(seconds: float) -> String:
	var m := roundi(seconds / 60.0)
	return "%dh %02dm" % [floori(m / 60.0), m % 60] if m >= 60 else "%d min" % m
