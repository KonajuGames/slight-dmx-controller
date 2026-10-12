class_name VirtualDjDatabase
extends RefCounted
## Reads VirtualDJ's song databases (`database.xml`) — the per-track tags,
## VirtualDJ's own BPM/key/phase analysis, hot cues, automix points and
## named remix sections — so a track VirtualDJ has already analysed can
## be lit without re-analysing it here.
##
## VirtualDJ keeps one database in `<Documents>/VirtualDJ/` plus one in
## `<drive root>/VirtualDJ/` on every drive that holds music (each drive's
## database lists the songs on that drive). `load_all()` finds and merges
## them all, keyed by the song's file path.
##
##   var db := VirtualDjDatabase.new()
##   db.load_all()
##   var song := db.find_song("D:/Music/Artist/Album/01 Track.m4a")
##   if song: print(song.bpm, " ", song.key)

const DB_DIR := "VirtualDJ"
const DB_FILE := "database.xml"

## `<Song Flag>` bit VirtualDJ sets on video files.
const SONG_FLAG_VIDEO := 64


## One `<Song>` entry. Times (`length`, `phase`, every POI `pos`) are in
## seconds from the start of the file.
class Song:
	extends RefCounted
	var path: String = ""            # forward slashes (Godot-friendly)
	var source: String = ""          # the database.xml this came from
	var file_size: int = 0
	var flags: int = 0
	# <Tags>
	var artist: String = ""
	var title: String = ""
	var genre: String = ""
	var album: String = ""
	var composer: String = ""
	var remix: String = ""
	var label: String = ""
	var track_number: String = ""    # as stored, e.g. "1/14"
	var year: String = ""
	var key: String = ""             # VirtualDJ notation, e.g. "C#m", "Eb"
	var bpm: float = 0.0             # beats per minute (0 = unknown)
	var rating: int = 0
	var comment: String = ""
	# <Infos>
	var length: float = 0.0
	var bitrate: int = 0
	var play_count: int = 0
	var first_seen: int = 0          # Unix time
	var last_modified: int = 0       # Unix time
	var last_play: int = 0           # Unix time
	# <Scan> — VirtualDJ's own analysis (tag values above may be user edits)
	var scanned: bool = false
	var scan_bpm: float = 0.0        # beats per minute
	var scan_alt_bpm: float = 0.0    # the half/double-time alternative
	var phase: float = 0.0           # seconds; position of a beat
	var volume: float = 1.0          # VirtualDJ's auto-gain factor
	var scan_key: String = ""
	## Variable-tempo grid from <Scan BeatGrid>, when VirtualDJ stored one
	## (long mixes, tracks with tempo drift). See parse_beat_grid().
	var grid_mode: int = -1          # the BeatGrid prefix (seen: 1, 9644); -1 = none
	var grid_segments: Array = []    # [{ start: float, beats: int, spb: float }]
	var rigid: float = 0.0           # <Scan Rigid>, seconds per beat; meaning unconfirmed
	# <Poi>
	var beatgrid: Array = []         # [float] — beat anchor positions
	var cues: Array = []             # [{ num: int, pos: float, name: String }]
	var automix: Dictionary = {}     # point name ("realStart", "fadeEnd", ...) -> pos
	var remix_points: Array = []     # [{ name: String, pos: float }], e.g. "Break 1"

	func is_video() -> bool:
		return flags & SONG_FLAG_VIDEO != 0

	## Best-known tempo: the tag (which the user may have corrected),
	## falling back to the scan.
	func best_bpm() -> float:
		return bpm if bpm > 0.0 else scan_bpm

	## Best-known key, in VirtualDJ notation.
	func best_key() -> String:
		return key if key != "" else scan_key

	## First beat position: the first beatgrid anchor, else the scan phase.
	func first_beat() -> float:
		return float(beatgrid[0]) if not beatgrid.is_empty() else phase

	func has_beat_grid() -> bool:
		return not grid_segments.is_empty()

	## Every beat time in seconds, ascending. Uses the variable-tempo grid
	## when there is one, otherwise a constant grid at best_bpm() locked to
	## first_beat() (extended back towards 0 as well as forward). Beats run
	## to `until` seconds, defaulting to the song length. Empty when the
	## tempo is unknown.
	func beat_times(until: float = -1.0) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		var end_t := until if until >= 0.0 else length
		if has_beat_grid():
			var last := grid_segments.size() - 1
			for i in range(grid_segments.size()):
				var seg: Dictionary = grid_segments[i]
				var start: float = seg["start"]
				var spb: float = seg["spb"]
				var n: int = seg["beats"]
				# The last segment (count 0) runs on to the end of the song.
				if i == last and n == 0 and spb > 0.0:
					n = maxi(int(floor((end_t - start) / spb)) + 1, 1)
				for b in range(n):
					var t := start + b * spb
					if end_t > 0.0 and t > end_t:
						break
					out.append(t)
			return out
		var bpm_v := best_bpm()
		if bpm_v <= 0.0 or end_t <= 0.0:
			return out
		var step := 60.0 / bpm_v
		var t := fposmod(first_beat(), step)
		while t <= end_t:
			out.append(t)
			t += step
		return out

	func display_name() -> String:
		if artist != "" and title != "":
			return "%s - %s" % [artist, title]
		if title != "":
			return title
		return path.get_file().get_basename()


## Every loaded song, by `_path_key(path)`.
var songs: Dictionary = {}
## The database files that loaded, in load order.
var sources: PackedStringArray = PackedStringArray()
## Human-readable problems from the last load (unreadable files etc.).
var errors: PackedStringArray = PackedStringArray()


## Every VirtualDJ database on this machine: the Documents one first, then
## one per drive root. Only files that exist are returned.
static func find_database_files() -> PackedStringArray:
	var out := PackedStringArray()
	var candidates := PackedStringArray()
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs != "":
		candidates.append(docs.path_join(DB_DIR).path_join(DB_FILE))
	for i in range(DirAccess.get_drive_count()):
		var root := DirAccess.get_drive_name(i)
		if root == "":
			continue
		# Windows reports "C:", other platforms a mount point.
		if not root.ends_with("/") and not root.ends_with("\\"):
			root += "/"
		candidates.append(root + DB_DIR + "/" + DB_FILE)
	var seen := {}
	for c in candidates:
		var p := c.replace("\\", "/").simplify_path()
		var k := _path_key(p)
		if seen.has(k) or not FileAccess.file_exists(p):
			continue
		seen[k] = true
		out.append(p)
	return out


## Find and load every database on this machine. Returns the number of
## songs loaded (after merging).
func load_all() -> int:
	songs.clear()
	sources.clear()
	errors.clear()
	for p in find_database_files():
		load_file(p)
	return songs.size()


## Load one `database.xml`, merging into `songs`. When two databases list
## the same file, the one on the song's own drive wins (that's the one
## VirtualDJ writes to); otherwise the first one loaded is kept.
func load_file(db_path: String) -> Error:
	if not FileAccess.file_exists(db_path):
		errors.append("%s: not found" % db_path)
		return ERR_FILE_NOT_FOUND
	var parser := XMLParser.new()
	var err := parser.open(db_path)
	if err != OK:
		errors.append("%s: can't open (%s)" % [db_path, error_string(err)])
		return err

	var saw_root := false
	var song: Song = null
	var in_comment := false
	while true:
		err = parser.read()
		if err == ERR_FILE_EOF:
			break
		if err != OK:
			errors.append("%s: XML parse error near line %d" % [db_path, parser.get_current_line()])
			break
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var tag := parser.get_node_name()
				if tag == "VirtualDJ_Database":
					saw_root = true
				elif tag == "Song":
					song = _read_song(parser, db_path)
					if parser.is_empty():
						_add_song(song)
						song = null
				elif song != null:
					match tag:
						"Tags": _read_tags(parser, song)
						"Infos": _read_infos(parser, song)
						"Scan": _read_scan(parser, song)
						"Poi": _read_poi(parser, song)
						"Comment": in_comment = not parser.is_empty()
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				if in_comment and song != null:
					song.comment += parser.get_node_data()
			XMLParser.NODE_ELEMENT_END:
				match parser.get_node_name():
					"Comment":
						in_comment = false
						if song != null:
							song.comment = song.comment.strip_edges()
					"Song":
						if song != null:
							_add_song(song)
						song = null

	if not saw_root:
		errors.append("%s: not a VirtualDJ database" % db_path)
		return ERR_FILE_UNRECOGNIZED
	sources.append(db_path)
	return OK


## The entry for a music file, or null. Path separators and (on Windows)
## letter case don't matter.
func find_song(file_path: String) -> Song:
	return songs.get(_path_key(file_path))


func song_count() -> int:
	return songs.size()


# ================================================================ parsing ==

static func _read_song(parser: XMLParser, db_path: String) -> Song:
	var s := Song.new()
	s.source = db_path
	s.path = _attr(parser, "FilePath").replace("\\", "/")
	s.file_size = _attr(parser, "FileSize").to_int()
	s.flags = _attr(parser, "Flag").to_int()
	return s


static func _read_tags(parser: XMLParser, s: Song) -> void:
	s.artist = _attr(parser, "Author")
	s.title = _attr(parser, "Title")
	s.genre = _attr(parser, "Genre")
	s.album = _attr(parser, "Album")
	s.composer = _attr(parser, "Composer")
	s.remix = _attr(parser, "Remix")
	s.label = _attr(parser, "Label")
	s.track_number = _attr(parser, "TrackNumber")
	s.year = _attr(parser, "Year")
	s.key = _attr(parser, "Key")
	s.bpm = _bpm(_attr(parser, "Bpm"))
	s.rating = _attr(parser, "Stars").to_int()


static func _read_infos(parser: XMLParser, s: Song) -> void:
	s.length = _attr(parser, "SongLength").to_float()
	s.bitrate = _attr(parser, "Bitrate").to_int()
	s.play_count = _attr(parser, "PlayCount").to_int()
	s.first_seen = _attr(parser, "FirstSeen").to_int()
	s.last_modified = _attr(parser, "LastModified").to_int()
	s.last_play = _attr(parser, "LastPlay").to_int()


static func _read_scan(parser: XMLParser, s: Song) -> void:
	s.scanned = true
	s.scan_bpm = _bpm(_attr(parser, "Bpm"))
	s.scan_alt_bpm = _bpm(_attr(parser, "AltBpm"))
	s.phase = _attr(parser, "Phase").to_float()
	var vol := _attr(parser, "Volume")
	if vol != "":
		s.volume = vol.to_float()
	s.scan_key = _attr(parser, "Key")
	s.rigid = _attr(parser, "Rigid").to_float()
	var grid := parse_beat_grid(_attr(parser, "BeatGrid"))
	if not grid.is_empty():
		s.grid_mode = grid["mode"]
		s.grid_segments = grid["segments"]


static func _read_poi(parser: XMLParser, s: Song) -> void:
	# VirtualDJ omits Pos when it's 0.
	var pos := _attr(parser, "Pos").to_float()
	match _attr(parser, "Type"):
		"beatgrid":
			s.beatgrid.append(pos)
		"cue":
			s.cues.append({"num": _attr(parser, "Num").to_int(), "pos": pos,
				"name": _attr(parser, "Name")})
		"automix":
			var point := _attr(parser, "Point")
			if point != "":
				s.automix[point] = pos
		"remix":
			s.remix_points.append({"name": _attr(parser, "Name"), "pos": pos})


func _add_song(s: Song) -> void:
	if s.path == "":
		return
	var k := _path_key(s.path)
	var existing: Song = songs.get(k)
	if existing == null or (_on_same_drive(s.source, s.path)
			and not _on_same_drive(existing.source, existing.path)):
		s.cues.sort_custom(func(a, b): return a["num"] < b["num"])
		s.remix_points.sort_custom(func(a, b): return a["pos"] < b["pos"])
		songs[k] = s


# ================================================================ helpers ==

static func _attr(parser: XMLParser, name: String) -> String:
	return parser.get_named_attribute_value_safe(name)


## VirtualDJ stores tempo as seconds per beat (0.5 = 120 BPM).
static func _bpm(seconds_per_beat: String) -> float:
	var spb := seconds_per_beat.to_float()
	return 60.0 / spb if spb > 0.0 else 0.0


## Lookup key for a file path: forward slashes, and case-folded on Windows
## where the filesystem is case-insensitive.
static func _path_key(p: String) -> String:
	var k := p.replace("\\", "/")
	return k.to_lower() if OS.get_name() == "Windows" else k


## True when a database lives on the same Windows drive as a song file.
static func _on_same_drive(db_path: String, song_path: String) -> bool:
	if db_path.length() < 2 or song_path.length() < 2:
		return false
	if db_path[1] != ":" or song_path[1] != ":":
		return false
	return db_path[0].to_lower() == song_path[0].to_lower()


# ======================================================= beat-grid parsing ==

## Parse a `<Scan BeatGrid>` value — VirtualDJ's (undocumented) variable-
## tempo grid — into { mode: int, segments: [{ start, beats, spb }] }.
## Returns {} for an empty or malformed value.
##
##   1[8.8033:125,0.58252][81.622:138,0.58236][204.61:261]...[2052:0,0.517256,0.51726]
##
## A number prefix (seen: 1, 9644 — meaning unknown), then one bracketed
## segment per run of evenly spaced beats: [start:count,secondsPerBeat].
## `start` is the run's first beat in seconds (rounded to ~5 significant
## digits); a missing secondsPerBeat repeats the previous segment's. Runs
## follow on from each other (start ≈ previous start + count × spb). The
## last segment has count 0 — it continues to the end of the song — and
## sometimes a third value close to its spb, which is ignored here.
static func parse_beat_grid(text: String) -> Dictionary:
	var open := text.find("[")
	if open <= 0 or not text.ends_with("]"):
		return {}
	var prefix := text.substr(0, open)
	if not prefix.is_valid_int():
		return {}
	var segments: Array = []
	var spb := 0.0
	for chunk in text.substr(open + 1, text.length() - open - 2).split("]["):
		var colon := chunk.find(":")
		if colon <= 0:
			return {}
		var start_s := chunk.substr(0, colon)
		var fields := chunk.substr(colon + 1).split(",")
		if not start_s.is_valid_float() or not fields[0].is_valid_int():
			return {}
		if fields.size() > 1:
			if not fields[1].is_valid_float():
				return {}
			spb = fields[1].to_float()
		var beats := fields[0].to_int()
		if spb <= 0.0 or beats < 0:
			return {}
		segments.append({"start": start_s.to_float(), "beats": beats, "spb": spb})
	return {"mode": prefix.to_int(), "segments": segments}


# ============================================================ key parsing ==

const _PITCH := {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


## VirtualDJ key notation ("C#m", "Ebm", "G#", "F") → { root: 0..11,
## mode: "major"/"minor" }, matching SongAnalysis.key_root / key_mode.
## Empty dictionary when it can't be parsed (e.g. Camelot "8A" notation).
static func parse_key(vdj_key: String) -> Dictionary:
	var k := vdj_key.strip_edges()
	if k == "" or not _PITCH.has(k[0].to_upper()):
		return {}
	var root: int = _PITCH[k[0].to_upper()]
	var i := 1
	if i < k.length() and (k[i] == "#" or k[i] == "♯"):
		root += 1
		i += 1
	elif i < k.length() and (k[i] == "b" or k[i] == "♭"):
		root -= 1
		i += 1
	var rest := k.substr(i).strip_edges().to_lower()
	var mode := "minor" if rest.begins_with("m") and not rest.begins_with("maj") else "major"
	return {"root": posmod(root, 12), "mode": mode}
