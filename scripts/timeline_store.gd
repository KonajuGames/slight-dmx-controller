class_name TimelineStore
extends RefCounted
## Where a show keeps its music tracks' lighting timelines: a folder next
## to the show file ("MyShow.slight" -> "MyShow.timelines/") holding one
## JSON file per song, named by the song's fingerprint, plus an index:
##
##   MyShow.timelines/
##       index.json        { fingerprint: {path, title}, ... }
##       <fingerprint>.json
##
## A song's file:
##   { format, version, track: {path, fingerprint},
##     structure: {sections: [...]}            (only once edited)
##     tracks: { "master": {dimmer: [[t, level], ...]},
##               "<fixture uid>": {...}, "<fixture uid>/h<n>": {...} } }
##
## Songs are found by fingerprint (size + a hash of the file's start and
## end), so a song that's been moved or renamed keeps its timelines.

const FORMAT := "sLight timelines"
const VERSION := 1
const _SAMPLE := 65536

## The folder (any path FileAccess takes: absolute or user://).
var dir := ""

var _fingerprints := {}       # song path -> fingerprint (this session)


func _init(p_dir := "") -> void:
	dir = p_dir


## The timelines folder for a show file: beside it, named after it.
static func folder_for_show(show_path: String) -> String:
	return show_path.get_basename() + ".timelines"


## A song file's identity, independent of where it is: its size and a
## SHA-256 of its first and last 64 KB (the first 16 hex digits). "" if
## it can't be read.
static func fingerprint_of(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var n := f.get_length()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(var_to_bytes(n))
	ctx.update(f.get_buffer(mini(n, _SAMPLE)))
	if n > _SAMPLE:
		f.seek(maxi(n - _SAMPLE, _SAMPLE))
		ctx.update(f.get_buffer(_SAMPLE))
	f.close()
	return ctx.finish().hex_encode().substr(0, 16)


func fingerprint(path: String) -> String:
	if not _fingerprints.has(path):
		_fingerprints[path] = fingerprint_of(path)
	return _fingerprints[path]


func _song_file(fp: String) -> String:
	return dir.path_join(fp + ".json")


func _index_file() -> String:
	return dir.path_join("index.json")


static func _read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


static func _write_json(path: String, data) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return true


## The saved data for the song at `path` ({} if there's none, or it's
## from a newer sLight).
func load_song(path: String) -> Dictionary:
	if dir == "":
		return {}
	var fp := fingerprint(path)
	if fp == "":
		return {}
	var d = _read_json(_song_file(fp))
	if not d is Dictionary or int(d.get("version", 1)) > VERSION:
		return {}
	return d


## Save `data` ({structure?, tracks}) as the song at `path`'s timelines.
## Returns "" or what went wrong.
func save_song(path: String, data: Dictionary) -> String:
	if dir == "":
		return "no timelines folder"
	var fp := fingerprint(path)
	if fp == "":
		return "can't read %s" % path.get_file()
	DirAccess.make_dir_recursive_absolute(dir)
	var out := data.duplicate(true)
	out["format"] = FORMAT
	out["version"] = VERSION
	out["track"] = {"path": path, "fingerprint": fp}
	if not _write_json(_song_file(fp), out):
		return "can't write to %s" % dir
	var index = _read_json(_index_file())
	if not index is Dictionary:
		index = {}
	index[fp] = {"path": path, "title": path.get_file().get_basename()}
	_write_json(_index_file(), index)
	return ""


## The songs this folder has timelines for: {fingerprint: {path, title}}.
func index() -> Dictionary:
	var d = _read_json(_index_file())
	return d if d is Dictionary else {}


## Copy every file in this folder to `to_dir` (Save Show As…). Returns
## the store for the copy.
func copy_to(to_dir: String) -> TimelineStore:
	var copy := TimelineStore.new(to_dir)
	copy._fingerprints = _fingerprints.duplicate()
	if dir == "" or to_dir == dir or not DirAccess.dir_exists_absolute(dir):
		return copy
	DirAccess.make_dir_recursive_absolute(to_dir)
	for name in DirAccess.get_files_at(dir):
		if name.ends_with(".json"):
			DirAccess.copy_absolute(dir.path_join(name), to_dir.path_join(name))
	return copy
