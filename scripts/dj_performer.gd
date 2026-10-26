class_name DjPerformer
extends Node
## DJ Perform Mode's engine: listens for VirtualDJ over OS2L and plays the
## lighting timelines of the songs on its decks into the DMX output.
##
## For each deck it follows what VirtualDJ reports (Os2lServer's
## subscriptions): the song loaded (get_filepath), whether it's playing,
## its volume fader (level) and where it is (get_time — milliseconds,
## every ~100 ms; between reports the position runs on at the rate the
## reports have been advancing). A new song's timelines are read from the
## show's TimelineStore on a worker thread, so a deck change never stalls
## the app.
##
## Every refresh, each deck that's playing with its fader up and has
## timelines contributes song_output() at its position; the decks are
## merged by mix(): HTP (highest takes precedence) for colour, dimmer,
## strobe and everything else, an average for movement (pan / tilt). That
## goes into the DMX frame as an ArtNet layer (layer()) — under chases and
## effects.
##
## A song without timelines gets temporary ones (with `timeline`, DJ Edit
## Mode's MusicTimeline): straight away a stand-in on its beat grid
## (MusicTimeline.placeholder_for() — VirtualDJ's grid, or the tempo and
## first beat it reports), while its structure's analysed in the
## background (a TimelineBatch); then a show generated from it as Generate
## would, saved with the show flagged temporary (put_generated()) — or
## only kept here, with no timelines folder. A song analysed this session
## goes straight to its show.

## Something the panel shows changed (connection, a deck's song, state or
## timelines).
signal state_changed

## Decks followed (VirtualDJ has up to four).
const DECKS := 4
## Channel roles merged by averaging across decks; every other role is
## HTP.
const AVERAGE_ROLES := ["PAN", "PAN_FINE", "TILT", "TILT_FINE"]
## A deck whose volume fader is at or below this doesn't drive the lights
## (it's being cued in the headphones).
const SILENT_LEVEL := 0.02

enum Load { NONE, LOADING, LOADED, NO_TIMELINES, NO_FOLDER }

class Deck:
	var num := 0
	var path := ""                  # the song (forward slashes); "" = empty
	var playing := false
	var level = null                # volume fader 0..1, null = not reported
	var time := 0.0                 # seconds into the song at `ticks`
	var ticks := 0                  # Time.get_ticks_msec() of that report
	var rate := 1.0                 # song seconds per real second, from the reports
	var load_state := Load.NONE
	var tracks := {}                # track key -> {dimmer: PackedVector2Array, colour: [segments], strobe: [spans], position: [spans]}
	var load_id := 0
	var temporary := false          # the tracks are generated ones (not the user's)
	var analysing := false          # ...a stand-in, while the song's analysed
	var progress := 0.0             # ...how far that's got, 0..1
	var note := ""                  # why they're only a stand-in, or not saved

	## Seconds into the song now.
	func position() -> float:
		if not playing:
			return time
		return time + (Time.get_ticks_msec() - ticks) / 1000.0 * rate

	## Whether this deck drives the lights now.
	func live() -> bool:
		return playing and load_state == Load.LOADED and (level == null or float(level) > SILENT_LEVEL)


## The OS2L port to listen on.
var port := Os2lServer.DEFAULT_PORT
## Advertise over mDNS so VirtualDJ finds the server by itself.
var advertise := true
## Returns the patched fixtures: [{uid, u, start, profile, mode}].
var fixtures_provider := Callable()
## Returns the show's TimelineStore (or null: no timelines folder).
var store_provider := Callable()
## The show's named positions (what the position rows refer to).
var positions: PositionLibrary
## DJ Edit Mode's timeline, which generates temporary timelines for a
## song without any (null: none are).
var timeline: MusicTimeline
## path -> its VirtualDjDatabase.Song (its beat grid), or null.
var song_lookup := Callable()

var os2l: Os2lServer
var decks: Array = []
var _status := "off"
var _batch: TimelineBatch           # songs being analysed for their temporary timelines
var _pending := 0                   # shows being generated on worker threads
## The background timeline loads' (and generating's) WorkerThreadPool task ids. Each must be
## waited on (wait_for_task_completion), finished or not: the pool keeps an
## unwaited task — and its lambda — until engine shutdown, where freeing
## the lambda after GDScript has gone crashes the app on quit.
var _tasks: Array[int] = []


func _init() -> void:
	for i in range(DECKS):
		var d := Deck.new()
		d.num = i + 1
		decks.append(d)


func is_active() -> bool:
	return os2l != null


func is_listening() -> bool:
	return os2l != null and os2l.is_listening()


## The OS2L server's state, for the panel ("listening on :9960", "off",
## an error...).
func status() -> String:
	return _status


func client_count() -> int:
	return os2l.client_count() if os2l != null else 0


func advertising_status() -> String:
	return os2l.advertising_status() if os2l != null else ""


func deck(num: int) -> Deck:
	return decks[num - 1]


## Start listening for VirtualDJ and playing timelines. Returns the
## listen result (the timelines play regardless, once a client connects).
func start() -> Error:
	stop()
	os2l = Os2lServer.new()
	os2l.deck_count = DECKS
	os2l.subscriptions = Os2lServer.default_subscriptions(DECKS)
	os2l.advertise = advertise
	os2l.state_changed.connect(func(_on: bool, detail: String):
		_status = detail
		state_changed.emit())
	os2l.client_connected.connect(func(_p): state_changed.emit())
	os2l.client_disconnected.connect(func(_p): state_changed.emit())
	os2l.advertising_changed.connect(func(_a, _d): state_changed.emit())
	os2l.value_changed.connect(_on_value)
	add_child(os2l)
	var err := os2l.start(port)
	if not ArtNet.layer_providers.has(layer):
		ArtNet.layer_providers.append(layer)
	state_changed.emit()
	return err


## Stop listening and stop playing timelines (the decks are forgotten).
func stop() -> void:
	ArtNet.layer_providers.erase(layer)
	if os2l != null:
		os2l.stop()
		os2l.queue_free()
		os2l = null
	_status = "off"
	if _batch != null:
		_batch.cancel()
	for d in decks:
		var n: int = d.num
		var fresh := Deck.new()
		fresh.num = n
		fresh.load_id = d.load_id + 1          # drop any load still under way
		decks[n - 1] = fresh
	state_changed.emit()


func _exit_tree() -> void:
	stop()
	for id in _tasks:
		WorkerThreadPool.wait_for_task_completion(id)
	_tasks.clear()


## Release the loads that have finished (see _tasks).
func _reap_tasks() -> void:
	for id in _tasks.duplicate():
		if WorkerThreadPool.is_task_completed(id):
			WorkerThreadPool.wait_for_task_completion(id)
			_tasks.erase(id)


## Read every loaded deck's timelines again (the show changed).
func reload_all() -> void:
	for d in decks:
		if d.path != "":
			_load(d)


# --------------------------------------------------------------- DECKS --

func _on_value(trigger: String, value: Variant) -> void:
	# "deck N <query>"
	if not trigger.begins_with("deck "):
		return
	var num := trigger.get_slice(" ", 1).to_int()
	if num < 1 or num > DECKS:
		return
	var query := trigger.substr(("deck %d " % num).length())
	var d: Deck = decks[num - 1]
	match query:
		"get_filepath":
			var p := str(value).replace("\\", "/")
			if p != d.path:
				d.path = p
				d.time = 0.0
				d.ticks = Time.get_ticks_msec()
				d.rate = 1.0
				_load(d)
		"play":
			var on := Os2lServer._truthy(value)
			if on != d.playing:
				d.time = d.position()       # freeze / resume from where it is
				d.ticks = Time.get_ticks_msec()
				d.playing = on
				state_changed.emit()
		"level":
			d.level = float(value)
		"get_time elapsed absolute":
			report_time(d, float(value) / 1000.0, Time.get_ticks_msec())


## A position report for deck `d`: `t` seconds into the song at `now`
## msec ticks. While playing, the rate is learned from how far successive
## reports advance (a pitched-up deck runs fast), and the position snaps
## to the report.
static func report_time(d: Deck, t: float, now: int) -> void:
	if d.playing and now > d.ticks:
		var dt := (now - d.ticks) / 1000.0
		var observed := (t - d.time) / dt
		if dt > 0.02 and observed > 0.25 and observed < 4.0:
			d.rate = lerpf(d.rate, observed, 0.3)
	d.time = t
	d.ticks = now


func _load(d: Deck) -> void:
	d.load_id += 1
	d.tracks = {}
	d.temporary = false
	d.analysing = false
	d.note = ""
	var store: TimelineStore = store_provider.call() if store_provider.is_valid() else null
	if d.path == "":
		d.load_state = Load.NONE
	elif store == null and timeline != null:
		d.load_state = Load.LOADING         # nothing to read: temporary ones, made next frame
		d.temporary = true
		_generate.call_deferred(d.num, d.load_id)
	elif store == null:
		d.load_state = Load.NO_FOLDER
	else:
		d.load_state = Load.LOADING
		var dir := store.dir
		var path := d.path
		var id: int = d.load_id
		var num: int = d.num
		# A fresh store per read: nothing shared with the main thread.
		_tasks.append(WorkerThreadPool.add_task(func():
			var data := TimelineStore.new(dir).load_song(path)
			_loaded.call_deferred(num, id, data)))
	state_changed.emit()


func _loaded(num: int, id: int, data: Dictionary) -> void:
	_reap_tasks()
	var d: Deck = decks[num - 1]
	if id != d.load_id:
		return                              # superseded
	var tracks := {}
	var saved = data.get("tracks", {})
	if saved is Dictionary:
		for key in saved:
			if not saved[key] is Dictionary:
				continue
			var nodes := MusicTimeline._nodes_from(saved[key].get("dimmer", []))
			var segs := MusicTimeline._segs_from(saved[key].get("colour", []))
			var strobes := MusicTimeline._spans_from(saved[key].get("strobe", []))
			var places := MusicTimeline._pos_from(saved[key].get("position", []))
			var moves := MusicTimeline._moves_from(saved[key].get("movement", []))
			var muted := bool(saved[key].get("mute", false))
			var soloed := bool(saved[key].get("solo", false))
			if not nodes.is_empty() or not segs.is_empty() or not strobes.is_empty() or not places.is_empty() \
					or not moves.is_empty() or muted or soloed:
				tracks[String(key)] = {"dimmer": nodes, "colour": segs, "strobe": strobes, "position": places,
					"movement": moves, "mute": muted, "solo": soloed}
	d.tracks = tracks
	d.temporary = bool(data.get("temporary", false)) and not tracks.is_empty()
	d.load_state = Load.LOADED if not tracks.is_empty() else Load.NO_TIMELINES
	if tracks.is_empty() and timeline != null:
		_generate(num, id)
		return
	state_changed.emit()


# ------------------------------------------------- TEMPORARY TIMELINES --

## Give deck `num`'s song (still load `id`) temporary timelines: a
## stand-in at once and its structure analysed for the real thing — or,
## analysed already this session, the real thing (_generated()).
func _generate(num: int, id: int) -> void:
	var d: Deck = decks[num - 1]
	if id != d.load_id or d.path == "":
		return                              # superseded
	var song = song_lookup.call(d.path) if song_lookup.is_valid() else null
	d.temporary = true
	d.load_state = Load.LOADING
	if timeline.cached_structure(d.path) == null:
		var bpm := float(os2l.deck_value(num, "get_bpm", 0.0)) if os2l != null else 0.0
		var first := float(os2l.deck_value(num, "get_firstbeat", 0.0)) / 1000.0 if os2l != null else 0.0
		d.analysing = true
		d.progress = 0.0
		_run_job(timeline.placeholder_job(d.path, song, bpm, first), func(gen: Dictionary):
			if id == d.load_id and d.tracks.is_empty():    # not superseded, nor the real thing there first
				d.tracks = tracks_from_show(gen["show"])
				d.load_state = Load.LOADED
				state_changed.emit())
	if _batch == null:
		_batch = TimelineBatch.new()
		_batch.timeline = timeline
		_batch.song_lookup = song_lookup
		_batch.generator = _generated
		_batch.progress.connect(func(path: String, f: float):
			for other in decks:
				if other.path == path and other.analysing:
					other.progress = f)
		_batch.done.connect(_analysis_done)
		add_child(_batch)
	_batch.add([d.path])
	state_changed.emit()


## Song `path`'s structure is known: a show generated from it for the
## decks waiting on it (if any still are), saved as its temporary
## timelines where the show has a folder — generated on a worker thread.
## Returns "" or what went wrong.
func _generated(path: String, song) -> String:
	if _waiting(path).is_empty():
		return ""
	var job := timeline.generate_job(path, song)
	if job.is_empty():
		return "its structure hasn't been analysed"
	_run_job(job, func(gen: Dictionary):
		var waiting := _waiting(path)
		if waiting.is_empty():
			return                          # every deck's moved on
		var tracks := tracks_from_show(gen["show"])
		var store: TimelineStore = store_provider.call() if store_provider.is_valid() else null
		var note := "not saved: the show hasn't been saved"
		if store != null and store == timeline.timeline_store:
			var err := timeline.put_generated(path, gen, true)
			note = "" if err == "" else "not saved: " + err
		for d in waiting:
			d.tracks = tracks
			d.analysing = false
			d.load_state = Load.LOADED
			d.note = note
		state_changed.emit())
	return ""


## The decks with song `path` still waiting for its generated show.
func _waiting(path: String) -> Array:
	return decks.filter(func(d): return d.path == path and d.temporary and (d.analysing or d.load_state == Load.LOADING))


## Run `job` (MusicTimeline.generate_job() / placeholder_job()) on a
## worker thread, then done(its show) back on the main thread.
func _run_job(job: Dictionary, done: Callable) -> void:
	_pending += 1
	_tasks.append(WorkerThreadPool.add_task(func():
		var gen := MusicTimeline.run_job(job)
		_job_done.call_deferred(done, gen)))


func _job_done(done: Callable, gen: Dictionary) -> void:
	_reap_tasks()
	_pending -= 1
	done.call(gen)


## Whether temporary timelines are still being made (analysed or
## generated).
func is_generating() -> bool:
	return _pending > 0 or (_batch != null and _batch.is_busy()) or (timeline != null and timeline.is_saving())


## The analysis (or generating) of song `path` finished — with `error`, the
## decks waiting on it keep their stand-in.
func _analysis_done(path: String, error: String) -> void:
	if error == "":
		return
	for d in decks:
		if d.path == path and d.temporary and (d.analysing or d.load_state == Load.LOADING):
			if d.load_state == Load.LOADING and not d.analysing:
				d.load_state = Load.NO_TIMELINES    # (a stand-in still on its way: LOADED when it's here)
			d.analysing = false
			d.note = error
	state_changed.emit()


## A generated show (key -> content, TimelineGenerator's form) as a deck's
## tracks: only the tracks with something on them.
static func tracks_from_show(show: Dictionary) -> Dictionary:
	var tracks := {}
	for key in show:
		var c: Dictionary = show[key]
		var entry := {"dimmer": c.get("dimmer", PackedVector2Array()), "colour": c.get("colour", []),
			"strobe": c.get("strobe", []), "position": c.get("position", []), "movement": c.get("movement", []),
			"mute": false, "solo": false}
		if not entry["dimmer"].is_empty() or not entry["colour"].is_empty() or not entry["strobe"].is_empty() 				or not entry["position"].is_empty() or not entry["movement"].is_empty():
			tracks[String(key)] = entry
	return tracks


## Whether every deck's timelines have finished loading (temporary ones
## are made, the stand-ins at least).
func loads_done() -> bool:
	for d in decks:
		if d.load_state == Load.LOADING:
			return false
	return true


# -------------------------------------------------------------- OUTPUT --

## The DMX layer for ArtNet.tick(): the live decks' timelines mixed.
func layer(n: int) -> Array:
	var fixtures: Array = fixtures_provider.call() if fixtures_provider.is_valid() else []
	var bases: Array = []
	for i in range(n):
		var u := ArtNet.get_universe(i)
		bases.append(u.dmx_data if u != null else PackedByteArray())
	var outputs: Array = []
	for d in decks:
		if d.live():
			outputs.append(song_output(d.tracks, d.position(), fixtures, bases, n, positions))
	if outputs.is_empty():
		var empty: Array = []
		for i in range(n):
			empty.append({})
		return empty
	return mix(outputs, average_channels(fixtures, n), n)


## One song's lighting at `t` seconds, as n {channel: value}
## dictionaries (only the channels it drives). From its timelines
## (`tracks`: key -> {dimmer: nodes, colour: segments}, keys "master",
## a fixture uid, "<uid>/h<n>"):
##   dimmer: a head's line where it has values (its first node to its
##     last), else its fixture's, else the master's — overriding, not
##     multiplying
##   colour: a head's colour row, else its fixture's, else the master's,
##     sets that head's red / green / blue (where a segment covers `t`)
##   position: the fixture's position row, else the master's, names a
##     position (`positions`); its PAN / TILT go to that position's point
##     for the fixture (16-bit with fine channels)
##   movement: the fixture's movement row, else the master's, moves its
##     pan / tilt around that position (or, with none, the console's
##     pan / tilt) — a circle, figure 8, ... (TimelineTrack.movement_offset);
##     "none" holds it still
##   strobe: where the fixture's strobe row or the master's is on, its
##     STROBE channel(s) go to a strobing value (from the channel's
##     ranges); off, they're left as the console has them
##   colour wheel: on a fixture without RGB, its colour (its own or the
##     master's) turns its COLOR_WHEEL channel(s) to the nearest colour
##     slot
## On a fixture with a DIMMER channel that channel is set to the level (to
## the brightest head's where heads have lines of their own, each head's
## colour scaled down to its own level); on one without, the colour
## channels — the timeline's colour, or the console's (`bases`) — are
## scaled by the level (its virtual dimmer). Only what the timelines cover
## is driven. A fixture left out of show generation (its
## "exclude_generate") ignores the master: only its own timelines (and its
## heads') drive it. A fixture or head left out by mute / solo
## (TimelineTrack.plays()) isn't driven at all; the master muted, nothing
## is.
static func song_output(tracks: Dictionary, t: float, fixtures: Array, bases: Array, n: int,
		positions: PositionLibrary = null) -> Array:
	var out: Array = []
	for i in range(n):
		out.append({})
	var mix := TimelineTrack.mix_state(tracks)
	if not TimelineTrack.plays(tracks, mix, "master"):
		return out
	var master: Dictionary = tracks.get("master", {})
	var all_line: PackedVector2Array = master.get("dimmer", PackedVector2Array())
	var all_lm := TimelineTrack.level_at(all_line, t)
	var all_colour = TimelineTrack.segment_colour_at(master.get("colour", []), t)
	var all_strobe := TimelineTrack.speed_at(master.get("strobe", []), t)
	var all_place := TimelineTrack.position_id_at(master.get("position", []), t)
	var all_move := TimelineTrack.movement_segment_at(master.get("movement", []), t)
	for fx in fixtures:
		var u: int = fx["u"]
		if u < 0 or u >= n:
			continue
		# The master's, unless it's left out of the show: then none.
		var own_only := bool(fx.get("exclude_generate", false))
		var master_line: PackedVector2Array = PackedVector2Array() if own_only else all_line
		var lm := 1.0 if own_only else all_lm
		var master_colour = null if own_only else all_colour
		var master_strobe := -1 if own_only else all_strobe
		var master_place := "" if own_only else all_place
		var master_move: Dictionary = {} if own_only else all_move
		var uid := String(fx["uid"])
		if not TimelineTrack.plays(tracks, mix, uid):
			continue
		var profile: FixtureProfile = fx["profile"]
		var mode: int = fx.get("mode", 0)
		var start: int = fx["start"]
		var own: Dictionary = tracks.get(uid, {})
		var own_line: PackedVector2Array = own.get("dimmer", PackedVector2Array())
		var own_colour = TimelineTrack.segment_colour_at(own.get("colour", []), t)
		var fixture_colour = own_colour if own_colour != null else master_colour
		# Its own line where that has values, else the master's.
		var own_defined := TimelineTrack.line_defined_at(own_line, t)
		var fixture_dimmed := own_defined or not master_line.is_empty()
		var lf := TimelineTrack.level_at(own_line, t) if own_defined else lm
		var base: PackedByteArray = bases[u] if u < bases.size() else PackedByteArray()
		var chans := profile.channels_for_mode(mode)
		var dim := -1
		for k in range(chans.size()):
			if String(chans[k]["role"]) == "DIMMER":
				dim = k
				break
		# What a head without a line of its own gets: the fixture's level —
		# or, with no lines at all, the console's dimmer.
		var inherited := lf if fixture_dimmed else (_byte(base, start + dim) / 255.0 if dim >= 0 else 1.0)
		var place := TimelineTrack.position_id_at(own.get("position", []), t)
		if place == "":
			place = master_place
		var placed := place != "" and positions != null and not positions.find(place).is_empty()
		var move := TimelineTrack.movement_segment_at(own.get("movement", []), t)
		if move.is_empty():
			move = master_move
		var moving := not move.is_empty() and String(move.get("fx", "none")) != "none"
		if placed or moving:
			# Where it points: the named position, else the console's pan /
			# tilt; then the movement around it.
			var pt: Vector2 = positions.point(place, uid) if placed \
				else Vector2(_read_axis(base, chans, start, "PAN"), _read_axis(base, chans, start, "TILT"))
			if moving:
				pt += TimelineTrack.movement_offset(move, t - float(move["t0"]))
			_write_axis(out[u], chans, start, "PAN", pt.x)
			_write_axis(out[u], chans, start, "TILT", pt.y)
		var strobe := maxi(master_strobe, TimelineTrack.speed_at(own.get("strobe", []), t))
		if strobe >= 0:                     # the faster of the master's and its own
			for k in range(chans.size()):
				if String(chans[k]["role"]) == "STROBE":
					out[u][start + k] = strobe_value(chans[k], strobe)
		var groups := profile.head_groups(mode)
		if groups.is_empty() and fixture_colour != null:
			# No RGB: the colour wheel's nearest slot.
			for k in range(chans.size()):
				if String(chans[k]["role"]) == "COLOR_WHEEL" and not bool(chans[k].get("fine", false)):
					var v := FixtureProfile.nearest_wheel_value(chans[k], fixture_colour)
					if v >= 0:
						out[u][start + k] = v
		# Per head: its level (its own line where that has values, else
		# inherited) and colour.
		var heads: Array = []
		var any_head := false
		for h in range(groups.size()):
			var head_key := "%s/h%d" % [uid, h]
			var head: Dictionary = tracks.get(head_key, {})
			var head_line: PackedVector2Array = head.get("dimmer", PackedVector2Array())
			var own_head := TimelineTrack.line_defined_at(head_line, t)
			var on := groups.size() < 2 or TimelineTrack.plays(tracks, mix, head_key)
			any_head = any_head or (own_head and on)
			var head_colour = TimelineTrack.segment_colour_at(head.get("colour", []), t)
			heads.append({"own": own_head, "level": TimelineTrack.level_at(head_line, t) if own_head else inherited,
				"colour": head_colour if head_colour != null else fixture_colour, "on": on})
		# A DIMMER channel serves every head: the brightest head's level,
		# each head's colour then scaled down to its own.
		var dim_level := inherited
		if dim >= 0 and any_head:
			dim_level = 0.0
			for hd in heads:
				if hd["on"]:
					dim_level = maxf(dim_level, hd["level"])
		if dim >= 0 and (fixture_dimmed or any_head):
			out[u][start + dim] = int(round(255.0 * clampf(dim_level, 0.0, 1.0)))
		var in_head := {}
		for h in range(groups.size()):
			var g: Dictionary = groups[h]
			var hd: Dictionary = heads[h]
			if not hd["on"]:
				# Left out by mute / solo: its channels are the console's.
				for k in [g["r"], g["g"], g["b"]] + Array(g["extra"]):
					in_head[int(k)] = true
				continue
			var colour = hd["colour"]
			var level: float
			var dimmed: bool
			if dim >= 0:
				# Heads with lines of their own: scaled to theirs under the
				# shared dimmer; otherwise the dimmer channel does it all.
				level = (float(hd["level"]) / dim_level if dim_level > 0.0 else 0.0) if any_head else 1.0
				dimmed = any_head
			else:
				level = hd["level"]
				dimmed = hd["own"] or fixture_dimmed
			var rgb := {int(g["r"]): 0, int(g["g"]): 1, int(g["b"]): 2}
			for k in [g["r"], g["g"], g["b"]] + Array(g["extra"]):
				k = int(k)
				if k < 0:
					continue
				in_head[k] = true
				var coloured: bool = colour != null and rgb.has(k)
				if not coloured and not dimmed:
					continue
				var v: float = (colour as Color)[rgb[k]] * 255.0 if coloured else float(_byte(base, start + k))
				out[u][start + k] = int(round(v * clampf(level, 0.0, 1.0)))
		# Colour channels outside any head (a lone white, say): the
		# fixture's dimming, as its virtual dimmer.
		if dim < 0 and fixture_dimmed:
			for k in profile.virtual_dimmer_channels(mode):
				if not in_head.has(k):
					out[u][start + k] = _scaled(base, start + k, lf)
	return out


## Set a PAN / TILT axis to `norm` (0..1 over its range): 16-bit across
## it and its fine partner (the next channel, flagged fine or <ROLE>_FINE)
## as 0..65535, else the channel's min..max — as the fixture panel's XY pad
## does.
static func _write_axis(out: Dictionary, chans: Array, start: int, role: String, norm: float) -> void:
	for k in range(chans.size()):
		if String(chans[k]["role"]) != role:
			continue
		norm = clampf(norm, 0.0, 1.0)
		var fine: bool = k + 1 < chans.size() and (bool(chans[k + 1].get("fine", false))
			or String(chans[k + 1]["role"]) == role + "_FINE")
		if fine:
			var v := int(round(norm * 65535.0))
			out[start + k] = (v >> 8) & 0xFF
			out[start + k + 1] = v & 0xFF
		else:
			out[start + k] = int(round(lerpf(int(chans[k].get("min", 0)), int(chans[k].get("max", 255)), norm)))
		return


## A PAN / TILT axis's value in `base` (the console's), 0..1 over its
## range — _write_axis() backwards. 0.5 if the fixture has no such axis.
static func _read_axis(base: PackedByteArray, chans: Array, start: int, role: String) -> float:
	for k in range(chans.size()):
		if String(chans[k]["role"]) != role:
			continue
		var fine: bool = k + 1 < chans.size() and (bool(chans[k + 1].get("fine", false))
			or String(chans[k + 1]["role"]) == role + "_FINE")
		if fine:
			return (_byte(base, start + k) * 256 + _byte(base, start + k + 1)) / 65535.0
		var lo := int(chans[k].get("min", 0))
		var hi := int(chans[k].get("max", 255))
		return clampf(float(_byte(base, start + k) - lo) / maxf(hi - lo, 1.0), 0.0, 1.0)
	return 0.5


## How far through a strobe range each speed goes (slow / medium / fast).
const STROBE_SPEED_FRACTION := [0.2, 0.55, 1.0]

## The value that makes a STROBE channel strobe at `speed`
## (TimelineTrack.Strobe): that far through a range labelled strobe /
## pulse (slow to fast), or through 20-240 — strobing on a plain 0-255
## channel, as the visualizer reads one — without such a range.
static func strobe_value(ch: Dictionary, speed: int = TimelineTrack.Strobe.FAST) -> int:
	var lo := 20
	var hi := 240
	for r in ch.get("ranges", []):
		var lbl := String(r.get("label", "")).to_lower()
		if "strob" in lbl or "puls" in lbl:
			lo = int(r["lo"])
			hi = int(r["hi"])
			break
	var f: float = STROBE_SPEED_FRACTION[clampi(speed, 0, 2)]
	return int(round(lerpf(lo, hi, f)))


static func _byte(base: PackedByteArray, ch: int) -> int:
	return int(base[ch]) if ch >= 0 and ch < base.size() else 0


static func _scaled(base: PackedByteArray, ch: int, level: float) -> int:
	var v := int(base[ch]) if ch >= 0 and ch < base.size() else 0
	return int(round(v * clampf(level, 0.0, 1.0)))


## The channels merged by averaging (movement), per universe: n
## {channel: true} from the fixtures' PAN / TILT (and fine) channels.
static func average_channels(fixtures: Array, n: int) -> Array:
	var out: Array = []
	for i in range(n):
		out.append({})
	for fx in fixtures:
		var u: int = fx["u"]
		if u < 0 or u >= n:
			continue
		var profile: FixtureProfile = fx["profile"]
		var chans := profile.channels_for_mode(int(fx.get("mode", 0)))
		for k in range(chans.size()):
			if String(chans[k]["role"]) in AVERAGE_ROLES:
				out[u][int(fx["start"]) + k] = true
	return out


## Merge several songs' outputs (each n {channel: value}): a channel in
## `average` (per universe) takes the mean of the songs driving it; every
## other channel the highest.
static func mix(outputs: Array, average: Array, n: int) -> Array:
	var out: Array = []
	for i in range(n):
		var merged := {}
		var counts := {}
		var avg: Dictionary = average[i] if i < average.size() else {}
		for o in outputs:
			var od: Dictionary = o[i] if i < o.size() else {}
			for ch in od:
				var v: int = od[ch]
				if avg.has(ch):
					merged[ch] = int(merged.get(ch, 0)) + v
					counts[ch] = int(counts.get(ch, 0)) + 1
				else:
					merged[ch] = maxi(int(merged.get(ch, 0)), v)
		for ch in counts:
			merged[ch] = int(round(float(merged[ch]) / counts[ch]))
		out.append(merged)
	return out
