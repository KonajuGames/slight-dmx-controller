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
## when false, reactors don't run and beat-synced chases fall back to BPM.

var chases: Array[Chase] = []
var effects: Array[WaveEffect] = []
var reactors: Array[SoundReactor] = []

## True while the console is in Sound Reactive run mode.
var sound_reactive := false


func _ready() -> void:
	Sound.beat.connect(_on_beat)


func _process(delta: float) -> void:
	for c in chases:
		if c.running and not (sound_reactive and c.beat_sync):
			c.advance(delta)
	for e in effects:
		if e.running:
			e.advance(delta)
	if sound_reactive:
		for r in reactors:
			if r.running:
				r.advance(delta, false)


## A beat: kick pulse-mode reactors and step every running beat-sync chase.
func _on_beat() -> void:
	if not sound_reactive:
		return
	for r in reactors:
		if r.running and r.mode == SoundReactor.MODE_PULSE:
			r.advance(0.0, true)
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
	for c in chases:
		if c.running:
			c.write_into(layers)
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
