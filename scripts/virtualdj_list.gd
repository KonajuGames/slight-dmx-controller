class_name VirtualDjList
extends RefCounted
## One VirtualDJ "Virtual Folder" (a `.vdjfolder` file in a `MyLists`
## directory): a named, ordered list of tracks — VirtualDJ's playlists.
##
## `MyLists` sits next to each `database.xml` (see VirtualDjDatabase), so
## there's one in `<Documents>/VirtualDJ/` and one in `<drive>/VirtualDJ/`
## on each music drive. `load_all()` reads every list from all of them,
## in the order VirtualDJ shows them (its `order` files).
##
##   var db := VirtualDjDatabase.new()
##   db.load_all()
##   for list in VirtualDjList.load_all():
##       print(list.name, ": ", list.entries.size(), " tracks")
##       for song in list.resolve(db):    # database entry, or null
##           ...

const LISTS_DIR := "MyLists"
const EXT := "vdjfolder"
## Plain-text file VirtualDJ keeps in MyLists: one list name per line, in
## display order.
const ORDER_FILE := "order"


## One `<song>` in the list. These are VirtualDJ's cached copies of the
## track's details at the time it was added; the database (via
## resolve()) has the full, current entry.
class Entry:
	extends RefCounted
	var path: String = ""        # forward slashes
	var file_size: int = 0
	var length: float = 0.0      # seconds
	var bpm: float = 0.0         # beats per minute (0 = unknown)
	var key: String = ""         # VirtualDJ notation, e.g. "F#m"
	var artist: String = ""
	var title: String = ""
	var remix: String = ""
	var idx: int = 0             # position VirtualDJ stored

	func display_name() -> String:
		if artist != "" and title != "":
			return "%s - %s" % [artist, title]
		if title != "":
			return title
		return path.get_file().get_basename()


var name: String = ""            # the file name, without .vdjfolder
var path: String = ""            # the .vdjfolder file
## Subfolder path inside MyLists ("" at the top level), "/"-separated.
var group: String = ""
## <VirtualFolder> attributes as stored (seen: ordered, singleDrive,
## noDuplicates — "yes"/"no").
var options: Dictionary = {}
var entries: Array = []          # [Entry], in list order


## Total running time in seconds.
func total_length() -> float:
	var t := 0.0
	for e in entries:
		t += e.length
	return t


## The VirtualDjDatabase.Song for each entry, in list order — null where
## the database has no entry for that file.
func resolve(db: VirtualDjDatabase) -> Array:
	var out: Array = []
	for e in entries:
		out.append(db.find_song(e.path))
	return out


## Every MyLists directory on this machine (next to each VirtualDJ
## database), Documents first.
static func find_list_dirs() -> PackedStringArray:
	var out := PackedStringArray()
	for db_file in VirtualDjDatabase.find_database_files():
		var d := db_file.get_base_dir().path_join(LISTS_DIR)
		if DirAccess.dir_exists_absolute(d):
			out.append(d)
	return out


## Load every list from every MyLists directory, in VirtualDJ's display
## order: names listed in an `order` file first (the first `order` file
## to mention a name places it — the Documents one covers lists on every
## drive), then the rest by name. Lists that fail to load are skipped,
## with a message appended to `errors` if one is passed.
static func load_all(errors: Array = []) -> Array:
	var lists: Array = []
	var order := {}
	for d in find_list_dirs():
		for n in _read_order(d.path_join(ORDER_FILE)):
			if not order.has(n):
				order[n] = order.size()
		_load_dir(d, "", lists, errors)
	lists.sort_custom(func(a: VirtualDjList, b: VirtualDjList) -> bool:
		var ia: int = order.get(a.name, 1 << 30)
		var ib: int = order.get(b.name, 1 << 30)
		if ia != ib:
			return ia < ib
		if a.group != b.group:
			return a.group.naturalnocasecmp_to(b.group) < 0
		return a.name.naturalnocasecmp_to(b.name) < 0)
	return lists


## Read one `.vdjfolder` file. Returns null (and appends to `errors`) if
## it can't be read or isn't a Virtual Folder.
static func load_file(file_path: String, errors: Array = []) -> VirtualDjList:
	if not FileAccess.file_exists(file_path):
		errors.append("%s: not found" % file_path)
		return null
	var parser := XMLParser.new()
	var err := parser.open(file_path)
	if err != OK:
		errors.append("%s: can't open (%s)" % [file_path, error_string(err)])
		return null

	var list: VirtualDjList = null
	while true:
		err = parser.read()
		if err == ERR_FILE_EOF:
			break
		if err != OK:
			errors.append("%s: XML parse error near line %d" % [file_path, parser.get_current_line()])
			break
		if parser.get_node_type() != XMLParser.NODE_ELEMENT:
			continue
		match parser.get_node_name():
			"VirtualFolder":
				list = VirtualDjList.new()
				list.path = file_path
				list.name = file_path.get_file().get_basename()
				for i in range(parser.get_attribute_count()):
					list.options[parser.get_attribute_name(i)] = parser.get_attribute_value(i)
			"song":
				if list != null:
					list.entries.append(_read_entry(parser, list.entries.size()))

	if list == null:
		errors.append("%s: not a VirtualDJ Virtual Folder" % file_path)
		return null
	# Stable sort on idx (sort_custom isn't stable, so break ties on the
	# file position _read_entry defaulted idx from).
	var pos := {}
	for i in range(list.entries.size()):
		pos[list.entries[i]] = i
	list.entries.sort_custom(func(a: Entry, b: Entry) -> bool:
		return a.idx < b.idx if a.idx != b.idx else pos[a] < pos[b])
	return list


# ================================================================ helpers ==

static func _read_entry(parser: XMLParser, file_pos: int) -> Entry:
	var e := Entry.new()
	e.path = _attr(parser, "path").replace("\\", "/")
	e.file_size = _attr(parser, "size").to_int()
	e.length = _attr(parser, "songlength").to_float()
	e.bpm = _attr(parser, "bpm").to_float()
	e.key = _attr(parser, "key")
	e.artist = _attr(parser, "artist")
	e.title = _attr(parser, "title")
	e.remix = _attr(parser, "remix")
	var idx := _attr(parser, "idx")
	e.idx = idx.to_int() if idx.is_valid_int() else file_pos
	return e


static func _attr(parser: XMLParser, attr_name: String) -> String:
	return parser.get_named_attribute_value_safe(attr_name)


static func _read_order(order_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	if not FileAccess.file_exists(order_path):
		return out
	for line in FileAccess.get_file_as_string(order_path).split("\n"):
		var n := line.strip_edges()
		if n != "":
			out.append(n)
	return out


## Load every .vdjfolder under `dir`, recursing into subdirectories (a
## "<name>.subfolders" directory shows in VirtualDJ as folder <name>).
static func _load_dir(dir: String, group: String, lists: Array, errors: Array) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		errors.append("%s: can't open directory" % dir)
		return
	for f in da.get_files():
		if f.get_extension().to_lower() != EXT:
			continue
		var list := load_file(dir.path_join(f), errors)
		if list != null:
			list.group = group
			lists.append(list)
	for sub in da.get_directories():
		var label := sub.trim_suffix(".subfolders")
		_load_dir(dir.path_join(sub), label if group == "" else group + "/" + label, lists, errors)
