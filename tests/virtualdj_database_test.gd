extends SceneTree
## Tests for VirtualDjDatabase — the VirtualDJ database.xml loader.
##
##   godot --headless --script tests/virtualdj_database_test.gd
##
## The synthetic databases are the portable part: written to user://,
## covering tags, the seconds-per-beat BPM encoding, omitted Pos="0" POIs,
## entities, comments and duplicate-entry merging. The databases actually
## on this machine are then loaded as a bonus sanity pass — SKIPPED (not
## failed) when VirtualDJ isn't installed.

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
	print("== VirtualDJ database loader ==")
	_test_synthetic()
	_test_merge()
	_test_bad_files()
	_test_parse_key()
	_test_beat_grid()
	_test_real_databases()
	print("== %d passed, %d failed, %d skipped ==" % [_p, _f, _s])
	quit(1 if _f > 0 else 0)


const _DB_A := """<?xml version="1.0" encoding="UTF-8"?>
<VirtualDJ_Database Version="8.5">
 <Song FilePath="D:\\Music\\Band\\Album\\01 Track.m4a" FileSize="6495416">
  <Tags Author="Band &amp; Friends" Title="Track" Genre="Pop" Album="Album" TrackNumber="1/14" Year="2019" Bpm="0.434783" Key="C#m" Flag="1" />
  <Infos SongLength="181.043107" LastModified="1697984254" FirstSeen="1697983832" Bitrate="261" Cover="2" />
  <Scan Version="801" Bpm="0.434785" Phase="0.905646" AltBpm="0.652177" Volume="1.276375" Key="C#m" Flag="32768" />
  <Poi Pos="0.905646" Type="beatgrid" />
  <Poi Type="automix" Point="realStart" />
  <Poi Pos="178.811066" Type="automix" Point="realEnd" />
  <Poi Name="Break 2" Pos="169.827846" Type="remix" />
  <Poi Name="Break 1" Pos="53.261497" Type="remix" />
  <Poi Pos="47.160" Num="2" Type="cue" />
  <Poi Pos="12.5" Num="1" Name="Intro" Type="cue" />
  <Comment>Great opener</Comment>
 </Song>
 <Song FilePath="D:\\thriller.mp4" FileSize="7369550" Flag="64">
  <Tags Title="Thriller" Flag="1" />
 </Song>
 <Song FilePath="D:\\Music\\untagged.mp3" FileSize="1" />
</VirtualDJ_Database>
"""

## A second database (as if from Documents, on C:) listing one of the
## same D: songs with different data, and one of its own.
const _DB_B := """<?xml version="1.0" encoding="UTF-8"?>
<VirtualDJ_Database Version="8.5">
 <Song FilePath="d:/music/band/album/01 track.m4a" FileSize="6495416">
  <Tags Title="Stale copy" Bpm="0.5" />
 </Song>
 <Song FilePath="C:\\Users\\me\\Sampler\\Siren.vdjsample" FileSize="331329">
  <Tags Bpm="0.542857" Flag="1" />
 </Song>
</VirtualDJ_Database>
"""


func _write(path: String, text: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	return ProjectSettings.globalize_path(path)


func _test_synthetic() -> void:
	print("- synthetic database")
	var db := VirtualDjDatabase.new()
	var err := db.load_file(_write("user://_vdj_a.xml", _DB_A))
	ok(err == OK, "loads (%s)" % error_string(err))
	ok(db.song_count() == 3, "3 songs (%d)" % db.song_count())
	ok(db.errors.is_empty(), "no errors %s" % str(db.errors))

	var s := db.find_song("D:/Music/Band/Album/01 Track.m4a")
	ok(s != null, "found by forward-slash path")
	if s == null:
		return
	ok(db.find_song("D:\\Music\\Band\\Album\\01 Track.m4a") == s, "found by backslash path")
	if OS.get_name() == "Windows":
		ok(db.find_song("d:/music/band/album/01 track.m4a") == s, "found case-insensitively")
	ok(s.artist == "Band & Friends", "entities decoded (%s)" % s.artist)
	ok(s.title == "Track" and s.genre == "Pop" and s.year == "2019", "tags")
	ok(s.track_number == "1/14", "track number kept as text")
	ok(absf(s.bpm - 138.0) < 0.01, "tag BPM 0.434783 s/beat -> 138 (%.3f)" % s.bpm)
	ok(absf(s.scan_bpm - 138.0) < 0.01, "scan BPM (%.3f)" % s.scan_bpm)
	ok(absf(s.scan_alt_bpm - 92.0) < 0.01, "alt BPM (%.3f)" % s.scan_alt_bpm)
	ok(s.key == "C#m" and s.scan_key == "C#m", "key")
	ok(absf(s.length - 181.043107) < 1e-4, "length")
	ok(s.bitrate == 261 and s.first_seen == 1697983832, "infos")
	ok(s.scanned and absf(s.volume - 1.276375) < 1e-5, "scan volume")
	ok(absf(s.first_beat() - 0.905646) < 1e-5, "first beat from beatgrid")
	ok(s.automix.get("realStart", -1.0) == 0.0, "omitted Pos reads as 0")
	ok(absf(float(s.automix.get("realEnd", 0.0)) - 178.811066) < 1e-4, "automix point")
	ok(s.remix_points.size() == 2 and s.remix_points[0]["name"] == "Break 1",
		"remix points sorted by position")
	ok(s.cues.size() == 2 and s.cues[0]["num"] == 1 and s.cues[0]["name"] == "Intro",
		"cues sorted by number, with name")
	ok(s.comment == "Great opener", "comment text (%s)" % s.comment)
	ok(not s.is_video(), "audio isn't flagged video")

	var v := db.find_song("D:/thriller.mp4")
	ok(v != null and v.is_video(), "video flag")
	ok(v != null and v.bpm == 0.0 and not v.scanned, "no BPM / not scanned when absent")

	var u := db.find_song("D:/Music/untagged.mp3")
	ok(u != null and u.display_name() == "untagged", "self-closing <Song/>, name from file")


func _test_merge() -> void:
	print("- merging two databases")
	var db := VirtualDjDatabase.new()
	# The C: (Documents-style) database loads first, as in load_all().
	var b := _write("user://_vdj_b.xml", _DB_B)
	var a := _write("user://_vdj_a.xml", _DB_A)
	db.load_file(b)
	db.load_file(a)
	ok(db.sources.size() == 2, "both sources recorded")
	var on_c := b.length() > 1 and b[1] == ":" and b[0].to_lower() == "c"
	var on_d := a.length() > 1 and a[1] == ":" and a[0].to_lower() == "d"
	var s := db.find_song("D:/Music/Band/Album/01 Track.m4a")
	if OS.get_name() != "Windows":
		skip("drive-preference merge (Windows paths)")
	elif on_c and not on_d:
		# user:// is on C:, so neither file is "on D:" — first one wins.
		ok(s != null and s.title == "Stale copy", "without a same-drive DB, first loaded wins")
	else:
		skip("drive-preference merge (user:// not on C:)")
	ok(db.song_count() == 4, "4 distinct songs after merge (%d)" % db.song_count())

	# The real rule: a database on the song's own drive beats one elsewhere.
	var d2 := VirtualDjDatabase.new()
	var other := VirtualDjDatabase.Song.new()
	other.path = "D:/x.mp3"
	other.source = "C:/Users/me/Documents/VirtualDJ/database.xml"
	other.title = "from C"
	var local := VirtualDjDatabase.Song.new()
	local.path = "D:/x.mp3"
	local.source = "D:/VirtualDJ/database.xml"
	local.title = "from D"
	d2._add_song(other)
	d2._add_song(local)
	ok(d2.find_song("D:/x.mp3").title == "from D", "same-drive database wins")
	var other2 := VirtualDjDatabase.Song.new()
	other2.path = "D:/x.mp3"
	other2.source = "E:/VirtualDJ/database.xml"
	other2.title = "from E"
	d2._add_song(other2)
	ok(d2.find_song("D:/x.mp3").title == "from D", "...and isn't displaced by another drive")


func _test_bad_files() -> void:
	print("- bad input")
	var db := VirtualDjDatabase.new()
	ok(db.load_file("user://_vdj_missing.xml") != OK, "missing file fails")
	ok(db.load_file(_write("user://_vdj_other.xml", "<?xml version=\"1.0\"?><Other/>")) != OK,
		"non-VirtualDJ XML rejected")
	ok(db.errors.size() == 2, "errors recorded (%d)" % db.errors.size())


func _test_parse_key() -> void:
	print("- key parsing")
	var cases := {
		"C": [0, "major"], "C#m": [1, "minor"], "Ebm": [3, "minor"],
		"G#": [8, "major"], "Bb": [10, "major"], "Cb": [11, "major"],
		"Am": [9, "minor"],
	}
	for k in cases:
		var r := VirtualDjDatabase.parse_key(k)
		ok(r.get("root", -1) == cases[k][0] and r.get("mode", "") == cases[k][1],
			"%s -> %s" % [k, str(r)])
	ok(VirtualDjDatabase.parse_key("").is_empty(), "empty -> {}")
	ok(VirtualDjDatabase.parse_key("8A").is_empty(), "Camelot -> {}")


func _test_beat_grid() -> void:
	print("- BeatGrid parsing")
	var g := VirtualDjDatabase.parse_beat_grid(
		"1[10:4,0.5][12:2][13:1,0.25][13.25:0,0.6,0.61]")
	ok(g.get("mode", -1) == 1, "prefix -> mode")
	var segs: Array = g.get("segments", [])
	ok(segs.size() == 4, "4 segments (%d)" % segs.size())
	if segs.size() == 4:
		ok(segs[0]["start"] == 10.0 and segs[0]["beats"] == 4 and segs[0]["spb"] == 0.5, "first segment")
		ok(segs[1]["spb"] == 0.5, "missing spb carries over")
		ok(segs[2]["spb"] == 0.25, "explicit spb changes tempo")
		ok(segs[3]["beats"] == 0 and segs[3]["spb"] == 0.6, "last segment, third value ignored")
	for bad in ["", "1", "[1:2,0.5]", "x[1:2,0.5]", "1[1:2]", "1[1:2,0.5", "1[a:2,0.5]", "1[1:2,0]"]:
		ok(VirtualDjDatabase.parse_beat_grid(bad).is_empty(), "rejects %s" % bad)

	var s := VirtualDjDatabase.Song.new()
	s.length = 15.0
	s.grid_segments = segs
	var beats := s.beat_times()
	# 10,10.5,11,11.5 | 12,12.5 | 13 | 13.25,13.85,14.45 (then 15.05 > 15)
	var want := [10.0, 10.5, 11.0, 11.5, 12.0, 12.5, 13.0, 13.25, 13.85, 14.45]
	var same := beats.size() == want.size()
	for i in range(mini(beats.size(), want.size())):
		same = same and absf(beats[i] - want[i]) < 1e-4
	ok(same, "grid expands to beat times %s" % str(beats))
	ok(s.beat_times(12.0).size() == 5, "until= truncates")

	var c := VirtualDjDatabase.Song.new()
	c.length = 3.0
	c.scan_bpm = 120.0
	c.phase = 1.25
	ok(Array(c.beat_times()) == [0.25, 0.75, 1.25, 1.75, 2.25, 2.75],
		"no grid: constant tempo locked to phase %s" % str(c.beat_times()))
	ok(VirtualDjDatabase.Song.new().beat_times().is_empty(), "no tempo -> no beats")

	# Read through the loader, from a <Scan> element.
	var db := VirtualDjDatabase.new()
	db.load_file(_write("user://_vdj_grid.xml", """<?xml version="1.0" encoding="UTF-8"?>
<VirtualDJ_Database Version="8.5">
 <Song FilePath="D:\\mix.m4a"><Infos SongLength="15" />
  <Scan Version="801" Bpm="0.5" Phase="10" Rigid="0.51" BeatGrid="1[10:4,0.5][12:2][13:1,0.25][13.25:0,0.6,0.61]" />
 </Song>
</VirtualDJ_Database>"""))
	var m := db.find_song("D:/mix.m4a")
	ok(m != null and m.has_beat_grid() and m.grid_mode == 1 and m.grid_segments.size() == 4,
		"loader reads BeatGrid")
	ok(m != null and absf(m.rigid - 0.51) < 1e-6, "loader reads Rigid")
	ok(m != null and m.beat_times().size() == 10, "loaded grid expands")


func _test_real_databases() -> void:
	print("- databases on this machine")
	var files := VirtualDjDatabase.find_database_files()
	if files.is_empty():
		skip("no VirtualDJ database found")
		return
	for f in files:
		print("    found ", f)
	var db := VirtualDjDatabase.new()
	var t0 := Time.get_ticks_msec()
	var n := db.load_all()
	print("    %d songs from %d database(s) in %d ms" % [n, db.sources.size(), Time.get_ticks_msec() - t0])
	ok(db.sources.size() == files.size(), "every database loaded %s" % str(db.errors))
	ok(n > 0, "songs loaded")
	var with_bpm := 0
	var bad_bpm := 0
	for s in db.songs.values():
		if s.best_bpm() > 0.0:
			with_bpm += 1
			if s.best_bpm() < 20.0 or s.best_bpm() > 400.0:
				bad_bpm += 1
	print("    %d have a BPM, %d outside 20..400" % [with_bpm, bad_bpm])
	ok(with_bpm > 0, "some songs have a BPM")

	# Every real BeatGrid should expand to strictly increasing beats with
	# plausible spacing (20..400 BPM).
	var grids := 0
	var grid_bad := 0
	for s in db.songs.values():
		if not s.has_beat_grid():
			continue
		grids += 1
		var b: PackedFloat32Array = s.beat_times()
		var lo := INF
		var hi := 0.0
		for i in range(1, b.size()):
			var d := b[i] - b[i - 1]
			lo = minf(lo, d)
			hi = maxf(hi, d)
		var good := b.size() > 1 and lo > 0.15 and hi < 3.0
		if not good:
			grid_bad += 1
		print("    grid %-5d %4d segs %6d beats  gap %.3f..%.3f s  %s" % [
			s.grid_mode, s.grid_segments.size(), b.size(), lo, hi, s.display_name()])
	if grids == 0:
		skip("no BeatGrid in the local databases")
	else:
		ok(grid_bad == 0, "%d real BeatGrids expand cleanly (%d bad)" % [grids, grid_bad])
