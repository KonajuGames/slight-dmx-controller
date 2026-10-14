extends SceneTree
## Tests for TimelineStore (a show's folder of per-song lighting timelines)
## and the DJ Edit Mode timeline saving into it when a song is left.
##
##   godot --headless --script tests/timeline_store_test.gd

var _p := 0
var _f := 0
var _s := 0

const DIR := "user://_tl_store_test"


func ok(cond: bool, label: String) -> void:
	if cond:
		_p += 1
		print("  ok   ", label)
	else:
		_f += 1
		print("  FAIL ", label)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== Timeline store ==")
	_clean()
	DirAccess.make_dir_recursive_absolute(DIR)
	_test_store()
	await _test_autosave()
	_clean()
	print("== %d passed, %d failed, %d skipped ==" % [_p, _f, _s])
	quit(1 if _f > 0 else 0)


func _clean() -> void:
	for d in [DIR, DIR + "/songs", DIR + "/a.timelines", DIR + "/b.timelines", DIR]:
		if DirAccess.dir_exists_absolute(d):
			for f in DirAccess.get_files_at(d):
				DirAccess.remove_absolute(d.path_join(f))
	for d in [DIR + "/songs", DIR + "/a.timelines", DIR + "/b.timelines", DIR]:
		DirAccess.remove_absolute(d)


## A fake song file: `n` bytes from a seed.
func _song(name: String, seed_v: int, n := 200000) -> String:
	DirAccess.make_dir_recursive_absolute(DIR + "/songs")
	var path := DIR + "/songs/" + name
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var b := PackedByteArray()
	b.resize(n)
	for i in range(0, n, 97):
		b[i] = rng.randi() & 0xFF
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(b)
	f.close()
	return path


func _test_store() -> void:
	print("- the store")
	ok(TimelineStore.folder_for_show("D:/Shows/Club.slight") == "D:/Shows/Club.timelines", "the folder sits beside the show, named after it")
	var a := _song("a.wav", 1)
	var b := _song("b.wav", 2)
	var fa := TimelineStore.fingerprint_of(a)
	ok(fa.length() == 16 and fa == TimelineStore.fingerprint_of(a), "a stable 16-digit fingerprint")
	ok(fa != TimelineStore.fingerprint_of(b), "different songs differ")
	ok(TimelineStore.fingerprint_of(DIR + "/nope.wav") == "", "unreadable: none")
	var st := TimelineStore.new(DIR + "/a.timelines")
	ok(st.load_song(a).is_empty(), "nothing saved yet")
	var data := {"tracks": {"master": {"dimmer": [[1.0, 0.5], [2.0, 1.0]]}, "abc123/h0": {"dimmer": [[0.0, 0.0]]}},
		"structure": {"sections": [{"start": 0.0, "end": 10.0, "label": "Intro"}]}}
	ok(st.save_song(a, data) == "", "saved")
	ok(FileAccess.file_exists(DIR + "/a.timelines/%s.json" % fa), "as <fingerprint>.json")
	var back := TimelineStore.new(DIR + "/a.timelines").load_song(a)
	ok(back.get("format") == "sLight timelines" and int(back.get("version")) == 1
		and back["track"]["path"] == a and back["track"]["fingerprint"] == fa, "tagged with format, version and the song")
	ok(back["tracks"] == data["tracks"] and back["structure"] == data["structure"], "tracks and structure round-trip")
	ok(st.index().has(fa) and st.index()[fa]["title"] == "a", "listed in the index")
	# A moved / renamed song keeps its timelines.
	DirAccess.rename_absolute(a, DIR + "/songs/moved.wav")
	ok(TimelineStore.new(DIR + "/a.timelines").load_song(DIR + "/songs/moved.wav")["tracks"] == data["tracks"],
		"found again after being moved (by fingerprint)")
	DirAccess.rename_absolute(DIR + "/songs/moved.wav", a)
	# A copy for Save As.
	var copy := st.copy_to(DIR + "/b.timelines")
	ok(copy.dir == DIR + "/b.timelines" and copy.load_song(a)["tracks"] == data["tracks"], "copied to another folder")
	# From a newer sLight: ignored.
	var f := FileAccess.open(DIR + "/a.timelines/%s.json" % fa, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 99, "tracks": {"master": {}}}))
	f.close()
	ok(TimelineStore.new(DIR + "/a.timelines").load_song(a).is_empty(), "a newer version's file is ignored")
	ok(TimelineStore.new("").save_song(a, data) != "", "no folder: can't save")


func _par() -> FixtureProfile:
	return FixtureProfile.new("par", "RGB par", [
		{"name": "Red", "role": "RED"}, {"name": "Green", "role": "GREEN"}, {"name": "Blue", "role": "BLUE"},
	])


func _test_autosave() -> void:
	print("- the timeline saves a song's timelines when it's left")
	var song1 := _song("one.song", 11)
	var song2 := _song("two.song", 12)
	var fixtures := [{"key": "uid-par", "name": "Par", "profile": _par(), "mode": 0}]
	var tl := MusicTimeline.new()
	tl.fixtures_provider = func(): return fixtures
	root.add_child(tl)
	var store := TimelineStore.new(DIR + "/a.timelines")
	tl.set_timeline_store(store)
	tl.open(song1)
	await process_frame
	var par: TimelineTrack = tl.fixture_tracks()[0]
	ok(par.get_meta("key") == "uid-par", "fixture tracks keyed by the fixture's uid")
	# Edit like the mouse does: change the nodes, then report the edit.
	tl.master_track().dimmer_nodes = PackedVector2Array([Vector2(1, 0.25)])
	tl.master_track().dimmer_edited.emit()
	par.dimmer_nodes = PackedVector2Array([Vector2(2, 0.5), Vector2(3, 1)])
	par.dimmer_edited.emit()
	ok(tl.has_unsaved_timelines() and store.load_song(song1).is_empty(), "edited: unsaved until the song's left")
	tl.open(song2)
	ok(not tl.has_unsaved_timelines(), "opening another song saves them")
	var saved := store.load_song(song1)
	ok(saved.get("tracks", {}).get("master", {}).get("dimmer") == [[1.0, 0.25]]
		and saved["tracks"]["uid-par"]["dimmer"] == [[2.0, 0.5], [3.0, 1.0]], "master and fixture nodes saved")
	ok(tl.master_track().dimmer_nodes.is_empty() and tl.fixture_tracks()[0].dimmer_nodes.is_empty(), "the new song starts empty")
	tl.open(song1)
	ok(tl.master_track().dimmer_nodes == PackedVector2Array([Vector2(1, 0.25)])
		and tl.fixture_tracks()[0].dimmer_nodes == PackedVector2Array([Vector2(2, 0.5), Vector2(3, 1)]),
		"going back shows them again")
	# A fresh timeline (next run) reads them from the folder.
	var tl2 := MusicTimeline.new()
	tl2.fixtures_provider = func(): return fixtures
	root.add_child(tl2)
	tl2.set_timeline_store(TimelineStore.new(DIR + "/a.timelines"))
	tl2.open(song1)
	ok(tl2.fixture_tracks()[0].dimmer_nodes.size() == 2 and tl2.master_track().dimmer_nodes.size() == 1,
		"read back from the folder by a new session")
	# Hiding the timeline (switching view / back to the list) saves.
	tl2.master_track().dimmer_nodes = PackedVector2Array([Vector2(5, 0.0)])
	tl2.master_track().dimmer_edited.emit()
	tl2.visible = false
	ok(not tl2.has_unsaved_timelines()
		and TimelineStore.new(DIR + "/a.timelines").load_song(song1)["tracks"]["master"]["dimmer"] == [[5.0, 0.0]],
		"hiding the timeline saves")
	# A removed fixture's timeline is kept, and comes back with it.
	tl2.visible = true
	fixtures.clear()
	tl2.refresh_fixtures()
	tl2.master_track().dimmer_edited.emit()
	tl2.flush()
	ok(TimelineStore.new(DIR + "/a.timelines").load_song(song1)["tracks"].has("uid-par"), "a removed fixture's timeline is kept")
	fixtures.append({"key": "uid-par", "name": "Par", "profile": _par(), "mode": 0})
	tl2.refresh_fixtures()
	ok(tl2.fixture_tracks()[0].dimmer_nodes.size() == 2, "...and back when it's re-patched")
	# Switching store (another show) reloads; leaving the tree saves.
	tl2.set_timeline_store(TimelineStore.new(DIR + "/b.timelines"))
	ok(tl2.master_track().dimmer_nodes.is_empty(), "another show's folder: its own (here, none)")
	tl2.master_track().dimmer_nodes = PackedVector2Array([Vector2(7, 0.7)])
	tl2.master_track().dimmer_edited.emit()
	tl2.queue_free()
	await process_frame
	ok(TimelineStore.new(DIR + "/b.timelines").load_song(song1).get("tracks", {}).has("master"), "closing saves")
	tl.queue_free()
	await process_frame
