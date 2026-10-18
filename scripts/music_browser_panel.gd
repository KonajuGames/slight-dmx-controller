class_name MusicBrowserPanel
extends HSplitContainer
## DJ Edit Mode: a narrow tree on the left — this machine's
## drives and folders, then VirtualDJ's Virtual Folders — and, filling the
## rest, the music in whatever's selected there.
##
## Folders load as they're expanded (a drive can hold far too many to
## walk up front). Track details come from VirtualDJ's database where it
## knows the file (artist / title / BPM / key / length, the same values
## its decks use), falling back to the file name. The database and lists
## load the first time the view is shown, not at app start.
##
## The left column has a "Folders" header over the folders, and below them
## a "Positions" header (with a "+" to add one) over the show's named
## positions (a PositionLibrary), each with its colour's triangle. Picking
## a position replaces the right side with its PositionEditor.
##
## A track with saved lighting timelines in the current show gets a small
## node-line icon (timeline_icon()) before its title. Most are told from
## the show's timelines index alone; a song that might have been moved
## there (same size as an indexed one) is fingerprinted in the background,
## a few per frame.
##
## Right-clicking a track opens its menu: open its timeline, show it in
## the file manager, copy its path, or remove its lighting timelines.

## Audio files listed in a folder (lower-case extensions).
const AUDIO_EXTS := ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "wma", "aif", "aiff"]

enum Col { NUM, TITLE, ARTIST, BPM, KEY, LENGTH, ALBUM, GENRE, FILE }
const COL_TITLES := ["#", "Title", "Artist", "BPM", "Key", "Length", "Album", "Genre", "File"]
## Sort key per column (a field of the row dictionaries built below).
const COL_KEYS := ["num", "title", "artist", "bpm", "key", "length", "album", "genre", "file"]

const _PLACEHOLDER := "_placeholder"
const _MISSING_COLOR := Color(1.0, 0.5, 0.5)
const HAS_TIMELINES_TIP := "Has lighting timelines in this show"
## The timeline icon's colour: a muted blue, readable on the list.
const ICON_COLOR := Color(0.45, 0.72, 0.95)
## Time per frame spent fingerprinting songs for their icons, ms.
const _CHECK_BUDGET_MS := 6

static var _icon: Texture2D
static var _blank: Texture2D

var _tree: Tree                 # left: drives / folders / Virtual Folders
var _list: Tree                 # right: the tracks
var _heading: Label
var _list_view: Control         # the heading + track list
var _timeline: MusicTimeline    # replaces _list_view while a track is open
var _editor: PositionEditor     # replaces it while a position is open
var _positions: PositionList    # the named positions
var _add_position: Button       # the "+" on the Positions header
var _position_menu: PopupMenu   # a position's right-click menu
var _menu_position := ""        # ...and the position it's for
enum { PM_RENAME, PM_DUPLICATE, PM_DELETE }
var _track_menu: PopupMenu      # a track's right-click menu
var _menu_track := ""           # ...and the track (path) it's for
enum { TM_OPEN, TM_SHOW_IN_FOLDER, TM_COPY_PATH, TM_REMOVE_TIMELINES }
## The show's named positions (set by the shell).
var positions: PositionLibrary:
	set(v):
		if positions != null and positions.changed.is_connected(refresh_positions):
			positions.changed.disconnect(refresh_positions)
		positions = v
		if positions != null:
			positions.changed.connect(refresh_positions)
		if _editor != null:
			_editor.library = v
		refresh_positions()
var _db: VirtualDjDatabase = null
var _lists: Array = []          # [VirtualDjList]
var _loaded := false

var _rows: Array = []           # [{num, title, artist, bpm, key, length, album, genre, file, path, missing}]
var _items := {}                # path -> its TreeItem in the list
var _has_timelines := {}        # path -> whether it has saved timelines (known so far)
var _to_check: Array = []       # paths still to fingerprint for their icon
var _sort_col := Col.NUM
var _sort_asc := true


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	split_offset = 260

	# The left column: the folders tree, then the named positions.
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(220, 0)
	left.add_theme_constant_override("separation", 4)
	left.add_child(_section_header("Folders"))
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.size_flags_stretch_ratio = 3.0
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_SINGLE
	_tree.item_collapsed.connect(_on_item_collapsed)
	_tree.item_selected.connect(_on_folder_selected)
	# Clicking the folder that's already selected doesn't re-select it, but
	# should still leave a track's timeline for the list.
	_tree.item_mouse_selected.connect(func(_pos: Vector2, _button: int): _on_folder_clicked())
	left.add_child(_tree)
	var head := _section_header("Positions")
	_add_position = Button.new()
	_add_position.text = "+"
	_add_position.flat = true
	_add_position.focus_mode = Control.FOCUS_NONE
	_add_position.tooltip_text = "Add a new position"
	_add_position.custom_minimum_size = Vector2(26, 0)
	_add_position.pressed.connect(add_position)
	head.add_child(_add_position)
	left.add_child(head)
	_positions = PositionList.new()
	_positions.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_positions.size_flags_stretch_ratio = 1.0
	_positions.custom_minimum_size = Vector2(0, 110)
	_positions.position_picked.connect(open_position)
	_positions.delete_requested.connect(confirm_delete_position)
	_positions.context_requested.connect(_on_position_context)
	left.add_child(_positions)
	_position_menu = PopupMenu.new()
	_position_menu.add_item("Rename", PM_RENAME)
	_position_menu.add_item("Duplicate", PM_DUPLICATE)
	_position_menu.add_separator()
	_position_menu.add_item("Delete…", PM_DELETE)
	_position_menu.id_pressed.connect(position_menu_action)
	add_child(_position_menu)
	add_child(left)

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
	_editor = PositionEditor.new()
	_editor.visible = false
	_editor.library = positions
	right_holder.add_child(_editor)
	refresh_positions()
	_timeline.timelines_saved.connect(func(path: String):
		_has_timelines[path] = true
		_show_mark(path))
	_timeline.timeline_store_changed.connect(refresh_timeline_marks)
	set_process(false)

	_heading = Label.new()
	_heading.text = "Select a folder or a VirtualDJ list."
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
	_list.allow_rmb_select = true
	_list.item_mouse_selected.connect(_on_track_clicked)
	right.add_child(_list)
	_track_menu = PopupMenu.new()
	_track_menu.add_item("Open Timeline", TM_OPEN)
	_track_menu.add_item("Show in File Explorer", TM_SHOW_IN_FOLDER)
	_track_menu.add_item("Copy Path", TM_COPY_PATH)
	_track_menu.add_separator()
	_track_menu.add_item("Remove Lighting Timelines…", TM_REMOVE_TIMELINES)
	_track_menu.id_pressed.connect(track_menu_action)
	add_child(_track_menu)

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
	vdj.set_text(0, "VirtualDJ Lists")
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
	var r := _row_for(it.get_metadata(0))
	if not r.is_empty():
		open_track(r)


## A right-click on a track: its menu, with what doesn't apply greyed out.
func _on_track_clicked(pos: Vector2, button: int) -> void:
	var it := _list.get_selected()
	if button != MOUSE_BUTTON_RIGHT or it == null:
		return
	_menu_track = it.get_metadata(0)
	var row := _row_for(_menu_track)
	var missing: bool = row.get("missing", true)
	_track_menu.set_item_disabled(_track_menu.get_item_index(TM_OPEN), missing)
	_track_menu.set_item_disabled(_track_menu.get_item_index(TM_SHOW_IN_FOLDER), missing)
	_track_menu.set_item_disabled(_track_menu.get_item_index(TM_REMOVE_TIMELINES),
		not has_timelines_mark(_menu_track))
	_track_menu.popup(Rect2i(Vector2i(_list.get_screen_position() + pos), Vector2i.ZERO))


func track_menu() -> PopupMenu:
	return _track_menu


## A track's right-click menu item, for the track it was opened on (or
## `path`). Remove Lighting Timelines asks first.
func track_menu_action(action: int, path := "") -> void:
	if path == "":
		path = _menu_track
	var row := _row_for(path)
	if row.is_empty():
		return
	match action:
		TM_OPEN:
			open_track(row)
		TM_SHOW_IN_FOLDER:
			OS.shell_show_in_file_manager(path)
		TM_COPY_PATH:
			DisplayServer.clipboard_set(path)
		TM_REMOVE_TIMELINES:
			confirm_remove_timelines(path)


## Ask, then delete a track's lighting timelines from the current show.
## Returns the dialog (for tests).
func confirm_remove_timelines(path: String) -> ConfirmationDialog:
	var row := _row_for(path)
	if row.is_empty():
		return null
	var dlg := ConfirmationDialog.new()
	dlg.title = "Remove Lighting Timelines"
	dlg.dialog_text = "Remove the lighting timelines for \"%s\" from this show?
This can't be undone." % row["title"]
	dlg.ok_button_text = "Remove"
	add_child(dlg)
	dlg.confirmed.connect(func():
		dlg.queue_free()
		remove_timelines(path))
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()
	return dlg


## Delete a track's lighting timelines from the current show and unmark it.
func remove_timelines(path: String) -> void:
	_timeline.remove_song_timelines(path)
	_to_check.erase(path)
	_has_timelines[path] = false
	_show_mark(path)


## The listed row for the track at `path` ({} if it isn't listed).
func _row_for(path: String) -> Dictionary:
	for r in _rows:
		if r["path"] == path:
			return r
	return {}


## Replace the track list with `row`'s timeline.
func open_track(row: Dictionary) -> void:
	_list_view.visible = false
	_editor.visible = false
	_timeline.visible = true
	_timeline.open(row["path"], _db.find_song(row["path"]) if _db != null else null)


## Back from a track's timeline (or a position) to the track list.
func show_track_list() -> void:
	_timeline.visible = false
	_editor.visible = false
	_positions.select("")
	_list_view.visible = true


## Whether a track's timeline is showing (rather than the track list).
func is_timeline_shown() -> bool:
	return _timeline.visible


func timeline() -> MusicTimeline:
	return _timeline


# ------------------------------------------------------------- POSITIONS --

## A header over a section of the left column: its title, and room on the
## right for buttons.
func _section_header(title: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = title
	l.add_theme_font_size_override("font_size", 15)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	return row


## The "+" on the Positions header.
func add_position_button() -> Button:
	return _add_position


func position_editor() -> PositionEditor:
	return _editor


func positions_list() -> PositionList:
	return _positions


## List the named positions (each after its colour's triangle), then
## "Add new position".
func refresh_positions() -> void:
	if _positions == null:
		return
	_positions.refresh(positions, _editor.position_id if _editor.visible else "")
	if _editor.visible and positions != null and positions.find(_editor.position_id).is_empty():
		show_track_list()                   # its position's gone (deleted, another show loaded)


## The Positions header's "+": add one, select it and open it in the editor.
func add_position() -> void:
	if positions != null:
		open_position(positions.add()["id"])


## A right-click on a position: Rename / Duplicate / Delete….
func _on_position_context(id: String, screen_pos: Vector2) -> void:
	_menu_position = id
	_position_menu.popup(Rect2i(Vector2i(screen_pos), Vector2i.ZERO))


func position_menu() -> PopupMenu:
	return _position_menu


## A position's right-click menu item, for the position it was opened on
## (or `id`): Rename opens it with its name selected to type over;
## Duplicate adds a copy and opens that; Delete asks first.
func position_menu_action(action: int, id := "") -> void:
	if id == "":
		id = _menu_position
	if positions == null or positions.find(id).is_empty():
		return
	match action:
		PM_RENAME:
			open_position(id)
			var field := _editor.name_edit()
			field.grab_focus()
			field.select_all()
		PM_DUPLICATE:
			open_position(positions.duplicate_position(id)["id"])
		PM_DELETE:
			confirm_delete_position(id)


## A position's ✕: ask, then delete it. Returns the dialog (for tests).
func confirm_delete_position(id: String) -> ConfirmationDialog:
	var pos := positions.find(id) if positions != null else {}
	if pos.is_empty():
		return null
	var dlg := ConfirmationDialog.new()
	dlg.title = "Delete Position"
	dlg.dialog_text = "Delete the position \"%s\"?" % pos["name"]
	dlg.ok_button_text = "Delete"
	add_child(dlg)
	dlg.confirmed.connect(func():
		dlg.queue_free()
		positions.remove(id))
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()
	return dlg


## Show position `id` in the editor, in place of the track list / timeline.
func open_position(id: String) -> void:
	_list_view.visible = false
	_timeline.visible = false
	_editor.visible = true
	_editor.open(id)
	_positions.select(id)


func is_position_shown() -> bool:
	return _editor.visible


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
	_set_heading("%s  (VirtualDJ list)" % list.name, _rows)
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
	_items.clear()
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
		_items[r["path"]] = it
	_update_column_titles()
	refresh_timeline_marks()


# ------------------------------------------------------- TIMELINE ICONS --

## Work out (again) which listed tracks have saved timelines in the
## current show, and mark them.
func refresh_timeline_marks() -> void:
	_has_timelines.clear()
	_to_check.clear()
	var store := _timeline.timeline_store
	for r in _rows:
		var path: String = r["path"]
		var has := TimelineStore.Has.NO
		if store != null and not r["missing"]:
			has = store.has_song_quick(path)
		if has == TimelineStore.Has.MAYBE:
			_to_check.append(path)
		else:
			_has_timelines[path] = has == TimelineStore.Has.YES
		_show_mark(path)
	set_process(not _to_check.is_empty())


## Whether the listed track at `path` is marked as having timelines (false
## while still being checked).
func has_timelines_mark(path: String) -> bool:
	return bool(_has_timelines.get(path, false))


## Whether every listed track's mark is settled (none still to check).
func timeline_marks_done() -> bool:
	return _to_check.is_empty()


func _process(_delta: float) -> void:
	var store := _timeline.timeline_store
	var t0 := Time.get_ticks_msec()
	while not _to_check.is_empty() and Time.get_ticks_msec() - t0 < _CHECK_BUDGET_MS:
		var path: String = _to_check.pop_front()
		_has_timelines[path] = store != null and store.has_song(path)
		_show_mark(path)
	if _to_check.is_empty():
		set_process(false)


func _show_mark(path: String) -> void:
	var it: TreeItem = _items.get(path)
	if it == null or not is_instance_valid(it):
		return
	var has := has_timelines_mark(path)
	# A blank of the same size keeps every title lined up.
	it.set_icon(Col.TITLE, timeline_icon() if has else _blank_icon())
	# (A missing file keeps its "File not found" tooltip: it's never marked.)
	if has:
		it.set_tooltip_text(Col.TITLE, HAS_TIMELINES_TIP)
	elif it.get_tooltip_text(Col.TITLE) == HAS_TIMELINES_TIP:
		it.set_tooltip_text(Col.TITLE, "")


## The "has lighting timelines" icon: a little dimmer node line — three
## segments with a dot at each node — like the timeline's dimmer row.
static func timeline_icon() -> Texture2D:
	if _icon == null:
		_icon = _draw_node_line(ICON_COLOR)
	return _icon


static func _blank_icon() -> Texture2D:
	if _blank == null:
		_blank = _draw_node_line(Color(0, 0, 0, 0))
	return _blank


## The line's 16 x 12 px, drawn by coverage (4 x 4 samples a pixel) so
## it's smooth, followed by ICON_GAP px of clear space before the title.
const ICON_GAP := 4
static func _draw_node_line(col: Color) -> Texture2D:
	const W := 16
	const H := 12
	var pts := [Vector2(1.6, 9.6), Vector2(5.6, 3.4), Vector2(10.2, 7.2), Vector2(14.4, 2.2)]
	var img := Image.create_empty(W + ICON_GAP, H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	if col.a > 0.0:
		for y in range(H):
			for x in range(W):
				var hit := 0
				for sy in range(4):
					for sx in range(4):
						var q := Vector2(x + (sx + 0.5) / 4.0, y + (sy + 0.5) / 4.0)
						if _on_node_line(q, pts):
							hit += 1
				if hit > 0:
					img.set_pixel(x, y, Color(col.r, col.g, col.b, col.a * hit / 16.0))
	return ImageTexture.create_from_image(img)


static func _on_node_line(q: Vector2, pts: Array) -> bool:
	for p in pts:
		if q.distance_to(p) <= 1.75:          # the nodes
			return true
	for i in range(pts.size() - 1):           # the line, 1.2 px wide
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var t := clampf((q - a).dot(b - a) / (b - a).length_squared(), 0.0, 1.0)
		if q.distance_to(a.lerp(b, t)) <= 0.6:
			return true
	return false


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
