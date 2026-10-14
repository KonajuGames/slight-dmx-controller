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
## effects, over Auto Show.

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
	var tracks := {}                # track key -> PackedVector2Array dimmer nodes
	var load_id := 0

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

var os2l: Os2lServer
var decks: Array = []
var _status := "off"


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
	for d in decks:
		var n: int = d.num
		var fresh := Deck.new()
		fresh.num = n
		fresh.load_id = d.load_id + 1          # drop any load still under way
		decks[n - 1] = fresh
	state_changed.emit()


func _exit_tree() -> void:
	stop()


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
	var store: TimelineStore = store_provider.call() if store_provider.is_valid() else null
	if d.path == "":
		d.load_state = Load.NONE
	elif store == null:
		d.load_state = Load.NO_FOLDER
	else:
		d.load_state = Load.LOADING
		var dir := store.dir
		var path := d.path
		var id: int = d.load_id
		var num: int = d.num
		# A fresh store per read: nothing shared with the main thread.
		WorkerThreadPool.add_task(func():
			var data := TimelineStore.new(dir).load_song(path)
			_loaded.call_deferred(num, id, data))
	state_changed.emit()


func _loaded(num: int, id: int, data: Dictionary) -> void:
	var d: Deck = decks[num - 1]
	if id != d.load_id:
		return                              # superseded
	var tracks := {}
	var saved = data.get("tracks", {})
	if saved is Dictionary:
		for key in saved:
			var nodes := MusicTimeline._nodes_from(saved[key].get("dimmer", []) if saved[key] is Dictionary else [])
			if not nodes.is_empty():
				tracks[String(key)] = nodes
	d.tracks = tracks
	d.load_state = Load.LOADED if not tracks.is_empty() else Load.NO_TIMELINES
	state_changed.emit()


## Whether every deck's timelines have finished loading.
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
			outputs.append(song_output(d.tracks, d.position(), fixtures, bases, n))
	if outputs.is_empty():
		var empty: Array = []
		for i in range(n):
			empty.append({})
		return empty
	return mix(outputs, average_channels(fixtures, n), n)


## One song's lighting at `t` seconds, as n {channel: value}
## dictionaries (only the channels it drives). From its timelines
## (`tracks`: key -> dimmer nodes): the master's dimmer scales every
## fixture; a fixture's own dimmer scales it; a head's, that head.
##   - a fixture with a DIMMER channel: that channel = full x master x
##     fixture level (when either has nodes); a head's level scales its
##     colour channels from the operator's (`bases`) values
##   - one without: its colour channels (its virtual dimmer's) = the
##     operator's values x master x fixture x head level
## A fixture none of whose tracks (nor the master) have nodes isn't
## driven.
static func song_output(tracks: Dictionary, t: float, fixtures: Array, bases: Array, n: int) -> Array:
	var out: Array = []
	for i in range(n):
		out.append({})
	var master: PackedVector2Array = tracks.get("master", PackedVector2Array())
	var lm := TimelineTrack.level_at(master, t)
	for fx in fixtures:
		var u: int = fx["u"]
		if u < 0 or u >= n:
			continue
		var uid := String(fx["uid"])
		var profile: FixtureProfile = fx["profile"]
		var mode: int = fx.get("mode", 0)
		var start: int = fx["start"]
		var own: PackedVector2Array = tracks.get(uid, PackedVector2Array())
		var groups := profile.head_groups(mode)
		var head_level := {}               # channel index -> its head's level
		var any_head := false
		for h in range(groups.size()):
			var hn: PackedVector2Array = tracks.get("%s/h%d" % [uid, h], PackedVector2Array())
			if hn.is_empty():
				continue
			any_head = true
			var lh := TimelineTrack.level_at(hn, t)
			var g: Dictionary = groups[h]
			for k in [g["r"], g["g"], g["b"]] + Array(g["extra"]):
				if int(k) >= 0:
					head_level[int(k)] = lh
		var fixture_driven := not master.is_empty() or not own.is_empty()
		if not fixture_driven and not any_head:
			continue
		var lf := lm * TimelineTrack.level_at(own, t)
		var base: PackedByteArray = bases[u] if u < bases.size() else PackedByteArray()
		var chans := profile.channels_for_mode(mode)
		var dim := -1
		for k in range(chans.size()):
			if String(chans[k]["role"]) == "DIMMER":
				dim = k
				break
		if dim >= 0:
			if fixture_driven:
				out[u][start + dim] = int(round(255.0 * clampf(lf, 0.0, 1.0)))
			for k in head_level:
				out[u][start + k] = _scaled(base, start + k, head_level[k])
		else:
			for k in profile.virtual_dimmer_channels(mode):
				if not fixture_driven and not head_level.has(k):
					continue                # only a head line: just that head
				var l: float = (lf if fixture_driven else 1.0) * float(head_level.get(k, 1.0))
				out[u][start + k] = _scaled(base, start + k, l)
	return out


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
