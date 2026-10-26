extends Node
## Autoload singleton: "Tempo"
##
## The console's tempo clock: a steady beat that beat-sync chases step on
## and tempo-synced effects run at, in any run mode. Off (running ==
## false) until something sets the tempo:
##
##   tap()               — Tap Tempo: the top bar's Tap button, the T key
##                         or a MIDI / OSC binding. Each tap lands a beat;
##                         two or more within TAP_RESET seconds of each
##                         other set the tempo from their average spacing.
##   MIDI clock          — any MIDI input's timing clock (24 pulses a
##                         quarter note), read here from Godot's
##                         InputEventMIDI. Start re-zeroes the beat count.
##   external_beat()     — a beat reported by another program: DJ Perform
##                         Mode passes on VirtualDJ's OS2L beats.
##
## MIDI clock and OS2L beats are external sources: while one keeps
## arriving it owns the clock (and taps are ignored). When it stops, the
## clock runs on freely at the last tempo, as if tapped, until stop().
##
## Between beats the clock free-runs from the last one, so a source that
## drops a beat or two is bridged.

signal beat          ## a beat of the running clock
signal changed       ## running, bpm or source changed

enum Source { NONE, TAP, MIDI_CLOCK, OS2L }
const SOURCE_NAMES := ["Off", "Tap", "MIDI clock", "VirtualDJ"]

const MIN_BPM := 30.0
const MAX_BPM := 300.0
## Taps further apart than this start a new count.
const TAP_RESET := 2.0
## The tempo is the average of up to this many taps' spacing.
const TAP_HISTORY := 8
const CLOCK_PPQN := 24
## MIDI clock pulses averaged for the tempo (four beats).
const CLOCK_WINDOW := 96
## An external source is lost after this long without a pulse / beat.
const CLOCK_TIMEOUT := 0.5
const EXTERNAL_TIMEOUT_BEATS := 2.5

var running := false
var bpm := 120.0
var source: int = Source.NONE
## 1.0 on a beat, decaying to 0 (for meters / indicators).
var beat_pulse := 0.0
## Listen for MIDI clock on the MIDI inputs.
var midi_clock_enabled := true

var _next_beat := 0.0        # seconds (clock time) of the next free-running beat
var _taps: Array[float] = []
var _clock_times: Array[float] = []
var _clock_count := 0        # pulses since Start / the first pulse
var _last_external := -INF   # clock time of the external source's last pulse / beat
var _external: int = Source.NONE


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


## Seconds on the clock the tempo runs by (overridable by tests through
## each call's `now`).
static func now_s() -> float:
	return Time.get_ticks_usec() / 1000000.0


func period() -> float:
	return 60.0 / bpm


## How far into the current beat the clock is, 0..1 (0 when stopped).
func phase(now: float = -1.0) -> float:
	if not running:
		return 0.0
	if now < 0.0:
		now = now_s()
	return clampf(1.0 - (_next_beat - now) / period(), 0.0, 1.0)


## Whether a MIDI clock or OS2L source is driving the clock now.
func external_live(now: float = -1.0) -> bool:
	if _external == Source.NONE:
		return false
	if now < 0.0:
		now = now_s()
	var timeout := CLOCK_TIMEOUT if _external == Source.MIDI_CLOCK else period() * EXTERNAL_TIMEOUT_BEATS
	return now - _last_external <= timeout


## A tap: lands a beat now and, with the taps before it, sets the tempo.
## Ignored (returns false) while an external source owns the clock.
func tap(now: float = -1.0) -> bool:
	if now < 0.0:
		now = now_s()
	if external_live(now):
		return false
	if not _taps.is_empty() and now - _taps[_taps.size() - 1] > TAP_RESET:
		_taps.clear()
	_taps.append(now)
	while _taps.size() > TAP_HISTORY:
		_taps.remove_at(0)
	if _taps.size() >= 2:
		var spacing := (_taps[_taps.size() - 1] - _taps[0]) / (_taps.size() - 1)
		bpm = clampf(60.0 / spacing, MIN_BPM, MAX_BPM)
	_external = Source.NONE
	source = Source.TAP
	running = true
	_land_beat(now)
	changed.emit()
	return true


## Stop the clock (chases go back to their own rate).
func stop() -> void:
	if not running and source == Source.NONE:
		return
	running = false
	source = Source.NONE
	_external = Source.NONE
	_taps.clear()
	_clock_times.clear()
	changed.emit()


## A beat from another program (OS2L: VirtualDJ's beat, with its tempo).
func external_beat(new_bpm: float, from: int = Source.OS2L, now: float = -1.0) -> void:
	if now < 0.0:
		now = now_s()
	if new_bpm > 0.0:
		bpm = clampf(new_bpm, MIN_BPM, MAX_BPM)
	_take(from, now)
	_land_beat(now)


## One MIDI timing-clock pulse (0xF8).
func clock_pulse(now: float = -1.0) -> void:
	if now < 0.0:
		now = now_s()
	if not _clock_times.is_empty() and now - _clock_times[_clock_times.size() - 1] > CLOCK_TIMEOUT:
		_clock_times.clear()        # the clock was stopped: start counting again
		_clock_count = 0
	_clock_times.append(now)
	while _clock_times.size() > CLOCK_WINDOW + 1:
		_clock_times.remove_at(0)
	if _clock_times.size() >= CLOCK_PPQN + 1:
		var span := _clock_times[_clock_times.size() - 1] - _clock_times[0]
		if span > 0.0:
			bpm = clampf(60.0 / (span / (_clock_times.size() - 1) * CLOCK_PPQN), MIN_BPM, MAX_BPM)
	var on_beat := _clock_count % CLOCK_PPQN == 0
	_clock_count += 1
	if _clock_times.size() < CLOCK_PPQN + 1:
		return                      # no tempo yet
	_take(Source.MIDI_CLOCK, now)
	if on_beat:
		_land_beat(now)


## MIDI Start (0xFA): the next pulse is beat 1.
func clock_start() -> void:
	_clock_count = 0


func _take(from: int, now: float) -> void:
	_last_external = now
	if _external != from or source != from or not running:
		_external = from
		source = from
		running = true
		changed.emit()


func _land_beat(now: float) -> void:
	_next_beat = now + period()
	beat_pulse = 1.0
	beat.emit()


func _process(delta: float) -> void:
	beat_pulse = maxf(0.0, beat_pulse - delta * 4.0)
	advance(now_s())


## Run the clock up to `now`: a free-running beat when one's due (late by a
## quarter beat while an external source is live, so it only fills in a
## missed one), and an external source given up when it's gone quiet.
func advance(now: float) -> void:
	if not running:
		return
	var live := external_live(now)
	if _external != Source.NONE and not live:
		_external = Source.NONE
		source = Source.TAP         # runs on at the last tempo
		changed.emit()
	var due := _next_beat + (period() * 0.25 if live else 0.0)
	if now >= due:
		# Several beats late (the app stalled): just the one, back in step.
		while _next_beat + period() <= now:
			_next_beat += period()
		_next_beat += period()
		beat_pulse = 1.0
		beat.emit()


func _input(event: InputEvent) -> void:
	if not midi_clock_enabled or not (event is InputEventMIDI):
		return
	match (event as InputEventMIDI).message:
		MIDI_MESSAGE_TIMING_CLOCK:
			clock_pulse()
		MIDI_MESSAGE_START:
			clock_start()


## The top bar's read-out: "128.0 BPM · Tap", or "— BPM" when off.
func describe() -> String:
	if not running:
		return "— BPM"
	return "%.1f BPM · %s" % [bpm, SOURCE_NAMES[source]]
