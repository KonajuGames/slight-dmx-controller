class_name RecentDirs
extends RefCounted
## Each file dialog remembers its own last-used directory, by a short
## purpose key ("song", "fixture_import", ...), across app restarts — so
## the fixture-import folder, the music library, the glTF-props folder
## and the MVR-rig folder don't have to share one "last directory" the
## way a single global memory would force them to. Backed by a small
## user:// JSON file.

const _PATH := "user://recent_dirs.json"

static var _dirs := {}
static var _loaded := false


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(_PATH):
		return
	var f := FileAccess.open(_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		_dirs = parsed


static func _save() -> void:
	var f := FileAccess.open(_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_dirs))
		f.close()


## Point `fd` at the remembered directory for `key` (if it still exists),
## and start remembering whichever directory the user next successfully
## opens or saves through it. Call before the dialog is shown, and after
## `fd.access = FileDialog.ACCESS_FILESYSTEM` — FileDialog silently
## refuses an absolute `current_dir` while access is still the default
## res://-only mode.
static func track(fd: FileDialog, key: String) -> void:
	_load()
	var dir := String(_dirs.get(key, ""))
	if dir != "" and DirAccess.dir_exists_absolute(dir):
		fd.current_dir = dir

	var remember := func(path: String) -> void:
		var d := path.get_base_dir()
		if String(_dirs.get(key, "")) != d:
			_dirs[key] = d
			_save()
	fd.file_selected.connect(remember)
	fd.files_selected.connect(func(paths: PackedStringArray) -> void:
		if not paths.is_empty():
			remember.call(paths[0]))
