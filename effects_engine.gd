extends Node
## Autoload singleton: "Fx"
##
## Runs the chases and waveform effects and composites their combined
## output into a per-universe override layer. `ArtNet.send_all()` asks for
## that layer each frame and lays it on top of the base buffers (which the
## fixture controls and cue crossfades write), then applies the grand
## master.

var chases: Array[Chase] = []
var effects: Array[WaveEffect] = []


func _process(delta: float) -> void:
	for c in chases:
		if c.running:
			c.advance(delta)
	for e in effects:
		if e.running:
			e.advance(delta)


## One override map { channel -> value } per universe slot, HTP-merged
## across every running chase and effect. `n` is the current universe
## count. Untouched channels are simply absent (base passes through).
func compose(n: int) -> Array:
	var layers: Array = []
	for i in range(n):
		layers.append({})
	for c in chases:
		if c.running:
			c.write_into(layers)
	for e in effects:
		if e.running:
			e.write_into(layers)
	return layers


func any_running() -> bool:
	for c in chases:
		if c.running:
			return true
	for e in effects:
		if e.running:
			return true
	return false


func stop_all() -> void:
	for c in chases:
		c.running = false
	for e in effects:
		e.running = false
