extends Node
## Autoload singleton: "Fx"
##
## Runs the chases, waveform effects and sound reactors and composites
## their combined output into a per-universe override layer. `ArtNet.tick()`
## asks for that layer each frame and lays it on top of the base buffers
## (which the fixture controls and cue crossfades write), then applies the
## grand master.
##
## `sound_reactive` (set by the run-mode selector) gates the sound layer:
## when false, reactors don't run.
##
## Beat-sync chases step on the tempo clock's beats (`Tempo`: tapped, MIDI
## clock or VirtualDJ) whenever it's running, in any run mode; with it off,
## on the beats detected in the audio in Sound Reactive; otherwise they
## fall back to their own BPM. Tempo-synced effects (WaveEffect.tempo_beats)
## run at the clock's tempo while it's running.

var chases: Array[Chase] = []
var effects: Array[WaveEffect] = []
var reactors: Array[SoundReactor] = []

## True while the console is in Sound Reactive run mode.
var sound_reactive := false

## func(n: int) -> per universe {channel: true}: the patched fixtures'
## intensity channels, which a chase's `level` (set by a playback fader)
## scales. Set by the faders (FaderBank).
var intensity_provider := Callable()


func _beat_driven() -> bool:
	return Tempo.running or sound_reactive


func _ready() -> void:
	Sound.beat.connect(_on_sound_beat)
	Tempo.beat.connect(_on_tempo_beat)
	reactors = SoundReactor.defaults()


func _process(delta: float) -> void:
	for c in chases:
		if c.running and not (_beat_driven() and c.beat_sync):
			c.advance(delta)
	var tempo := Tempo.bpm if Tempo.running else 0.0
	for e in effects:
		if e.running:
			e.advance(delta, tempo)
	if sound_reactive:
		for r in reactors:
			if r.running:
				r.advance(delta, false)


## A beat detected in the live audio (Sound Reactive): kick pulse
## reactors, and step beat-sync chases unless the tempo clock is doing it.
func _on_sound_beat() -> void:
	if sound_reactive:
		for r in reactors:
			if r.running and r.mode == SoundReactor.MODE_PULSE:
				r.advance(0.0, true)
	if sound_reactive and not Tempo.running:
		_step_beat_chases()


## A beat of the tempo clock: step beat-sync chases and pull tempo-synced
## effects into phase with it.
func _on_tempo_beat() -> void:
	_step_beat_chases()
	for e in effects:
		if e.running:
			e.on_beat()


func _step_beat_chases() -> void:
	for c in chases:
		if c.running and c.beat_sync:
			c.beat_step()


## One override map { channel -> value } per universe slot, HTP-merged
## across every running chase, effect and (in Sound Reactive mode) reactor.
## `n` is the current universe count; `bases` (per-universe DMX buffers)
## feeds Pickup-mode effects. Untouched channels are simply absent.
func compose(n: int, bases: Array = []) -> Array:
	var layers: Array = []
	for i in range(n):
		layers.append({})
	var intensity: Array = []
	for c in chases:
		if c.running and c.level < 1.0 and intensity.is_empty() and intensity_provider.is_valid():
			intensity = intensity_provider.call(n)
	for c in chases:
		if c.running:
			c.write_into(layers, intensity)
	for e in effects:
		if e.running:
			e.write_into(layers, bases)
	if sound_reactive:
		for r in reactors:
			if r.running:
				r.write_into(layers)
	return layers


func any_running() -> bool:
	for c in chases:
		if c.running:
			return true
	for e in effects:
		if e.running:
			return true
	for r in reactors:
		if r.running:
			return true
	return false


func stop_all() -> void:
	for c in chases:
		c.running = false
	for e in effects:
		e.running = false
	for r in reactors:
		r.running = false
