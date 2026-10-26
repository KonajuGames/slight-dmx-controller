class_name TimelineBatch
extends Node
## Regenerates the lighting timelines of a list of songs (the song list's
## Regenerate Lighting Timelines), a few at a time: each song's structure
## analysed on a worker thread of its own (a SongAnalyzer each; a song
## already analysed this session goes straight through), then a show
## generated into its saved timelines (MusicTimeline.generate_into()) — as
## Generate would, a new variation each time.
##
## progress(path, 0..1) as each song goes (0 while it waits its turn),
## done(path, error) when it's finished ("" — saved), all_done when the
## last has.

signal progress(path: String, fraction: float)
signal done(path: String, error: String)
signal all_done

## How much of a song's bar its analysis takes (the generating, the rest).
const ANALYSIS_SHARE := 0.9

var timeline: MusicTimeline
## path -> its VirtualDjDatabase.Song (its beat grid), or null.
var song_lookup := Callable()
## What's done with each song once its structure's known: (path, song) ->
## "" or what went wrong. Unset, a show is generated into its saved
## timelines (MusicTimeline.generate_into()).
var generator := Callable()
## Songs analysed at once: one per worker thread — a few, leaving cores
## for the app; one where only the playback analysis works (it plays the
## song through a shared, muted bus).
var workers := maxi(1, mini(4, OS.get_processor_count() / 2)) if SongAnalyzer.fast_available() else 1

var _queue: Array = []              # paths waiting their turn
var _running := {}                  # path -> its SongAnalyzer (null: generating)


## Queue `paths` (those not already queued or under way), and start.
func add(paths: Array) -> void:
	for path in paths:
		if not path in _queue and not _running.has(path):
			_queue.append(path)
			progress.emit(path, 0.0)
	_pump()


## Whether `path` is queued or under way.
func has(path: String) -> bool:
	return path in _queue or _running.has(path)


func is_busy() -> bool:
	return not _queue.is_empty() or not _running.is_empty()


## Stop: nothing more is generated (an analysis under way finishes, unused).
func cancel() -> void:
	_queue.clear()
	for path in _running:
		var an: SongAnalyzer = _running[path]
		if an != null:
			an.queue_free()
	_running.clear()


func _pump() -> void:
	while _running.size() < workers and not _queue.is_empty():
		_start(_queue.pop_front())


func _start(path: String) -> void:
	var song = song_lookup.call(path) if song_lookup.is_valid() else null
	_running[path] = null
	if timeline.cached_structure(path) != null:
		_generate.call_deferred(path, song)
		return
	var why := ""
	if not FileAccess.file_exists(path):
		why = "file not found"
	elif SongAnalyzer.is_os_format(path) and not SongAnalyzer.os_decoding_available():
		why = "can't decode .%s files here" % path.get_extension().to_lower()
	if why != "":
		_finish.call_deferred(path, why)
		return
	var an := SongAnalyzer.new()
	add_child(an)
	_running[path] = an
	an.progress.connect(func(f: float):
		if _running.get(path) == an:
			progress.emit(path, f * ANALYSIS_SHARE))
	an.finished.connect(func(a: SongAnalysis):
		an.queue_free()
		if _running.get(path) != an:
			return                          # cancelled
		timeline.add_structure(path, a, song)
		_running[path] = null
		_generate(path, song))
	an.failed.connect(func(m: String):
		an.queue_free()
		if _running.get(path) == an:
			_finish(path, m.trim_suffix(".")))
	an.analyse(path)


func _generate(path: String, song) -> void:
	if not _running.has(path):
		return                              # cancelled
	progress.emit(path, ANALYSIS_SHARE)
	_finish(path, generator.call(path, song) if generator.is_valid() else timeline.generate_into(path, song))


func _finish(path: String, error: String) -> void:
	if not _running.has(path):
		return
	_running.erase(path)
	if error == "":
		progress.emit(path, 1.0)
	done.emit(path, error)
	_pump()
	if not is_busy():
		all_done.emit()
