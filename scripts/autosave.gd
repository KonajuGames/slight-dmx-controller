class_name Autosave
extends RefCounted
## Autosave and crash recovery for the show.
##
## While the app runs, the shell calls tick() every INTERVAL seconds: when
## the show (show_dict()) differs from the last one saved, loaded or
## autosaved, a snapshot of it goes to `file` — with the show file it
## belongs to and when — never touching the show file itself.
##
## `session_file` says whether the app is running: begin() marks it at
## startup and end() clears it (and the snapshot) on a clean quit. So at
## the next start, begin() finding it still marked means the app didn't
## close properly — a crash, a power cut, a kill — and it hands back the
## snapshot, if there is one, for the shell to offer to restore.

const INTERVAL := 60.0

## The snapshot: {"format", "saved_at" (unix seconds), "show_path", "show"}.
var file := "user://autosave.slight"
## {"running": true} from begin() until end().
var session_file := "user://session.json"

var _last := ""              # the JSON of the show as last saved / loaded / autosaved


## At startup: the snapshot left by a run that didn't end cleanly ({}
## if the last one did, or left none); then this run is marked running.
func begin() -> Dictionary:
	var crashed := false
	if FileAccess.file_exists(session_file):
		var s = JSON.parse_string(FileAccess.get_file_as_string(session_file))
		crashed = s is Dictionary and bool(s.get("running", false))
	var snap := read() if crashed else {}
	_write(session_file, {"running": true})
	return snap


## A clean quit: nothing to recover next time.
func end() -> void:
	_write(session_file, {"running": false})
	discard()


## The snapshot in `file` ({} if there's none, or it's unreadable).
func read() -> Dictionary:
	if not FileAccess.file_exists(file):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(file))
	if not (parsed is Dictionary and parsed.get("show") is Dictionary):
		return {}
	return parsed


func discard() -> void:
	if FileAccess.file_exists(file):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(file))


## The show as it stands is saved (or was just loaded): not worth an
## autosave until it changes.
func mark_saved(show: Dictionary) -> void:
	_last = JSON.stringify(show)


## Whether `show` is different from the one last saved / loaded /
## autosaved.
func changed_since(show: Dictionary) -> bool:
	return JSON.stringify(show) != _last


## Autosave `show` (belonging to the show file `show_path`, "" if it's
## never been saved) if it's changed. Returns whether it wrote one.
func tick(show: Dictionary, show_path: String) -> bool:
	var text := JSON.stringify(show)
	if text == _last:
		return false
	if not _write(file, {"format": "sLight autosave", "saved_at": int(Time.get_unix_time_from_system()),
			"show_path": show_path, "show": show}):
		return false
	_last = text
	return true


## When a snapshot was taken, as local "HH:MM" (today) or "YYYY-MM-DD HH:MM".
static func when(snap: Dictionary) -> String:
	var t := int(snap.get("saved_at", 0))
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var d := Time.get_datetime_dict_from_unix_time(t + bias)
	var today := Time.get_datetime_dict_from_unix_time(int(Time.get_unix_time_from_system()) + bias)
	var hm := "%02d:%02d" % [d["hour"], d["minute"]]
	if d["year"] == today["year"] and d["month"] == today["month"] and d["day"] == today["day"]:
		return hm
	return "%04d-%02d-%02d %s" % [d["year"], d["month"], d["day"], hm]


static func _write(path: String, data: Dictionary) -> bool:
	# Written beside the target and then moved over it, so a crash mid-write
	# never leaves half a file where the last good one was.
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data))
	f.close()
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(path)) == OK
