extends Node
## Autoload singleton: "ArtNet"
##
## Manages one `ArtNetUniverse` per universe slot and a global grand
## master. The GUI (dmx_controller.gd) drives the per-universe senders
## directly; the refresh timer just calls `send_all()`.
##
## Usage:
##   var u := ArtNet.get_universe(0)
##   u.set_target("192.168.1.50", 6454)
##   u.artnet_universe = 0
##   u.set_channel(0, 255)
##   ArtNet.master = 0.5          # grand master, 0..1
##   ArtNet.send_all()

const MAX_UNIVERSES := 8
const DMX_UNIVERSE_SIZE := ArtNetUniverse.DMX_UNIVERSE_SIZE
const ARTNET_PORT_DEFAULT := ArtNetUniverse.ARTNET_PORT_DEFAULT

## 0..1 scale applied to every universe's output on send.
var master := 1.0

## Source CID for every sACN universe (16 bytes). Persisted in the show
## file so receivers see one stable E1.31 source.
var sacn_cid := Sacn.random_cid()

var universes: Array[ArtNetUniverse] = []

## Emitted when a running crossfade reaches all its targets.
signal fade_finished

var _fade_active := false
var _fade_elapsed := 0.0
var _fade_up := 0.0
var _fade_down := 0.0
var _fade_from: Array = []  # PackedByteArray per universe
var _fade_to: Array = []    # PackedByteArray per universe


func _init() -> void:
	add_universe()  # always at least one slot


func universe_count() -> int:
	return universes.size()


func get_universe(idx: int) -> ArtNetUniverse:
	if idx < 0 or idx >= universes.size():
		return null
	return universes[idx]


## Append a new universe slot, numbered to the first free Art-Net number.
## Returns null if already at MAX_UNIVERSES.
func add_universe() -> ArtNetUniverse:
	if universes.size() >= MAX_UNIVERSES:
		return null
	var used := {}
	for existing in universes:
		used[existing.artnet_universe] = true
	var n := 0
	while used.has(n):
		n += 1
	var u := ArtNetUniverse.new()
	u.artnet_universe = n
	universes.append(u)
	return u


## Remove the slot at idx. Refuses to drop the last remaining universe.
func remove_universe(idx: int) -> void:
	if idx < 0 or idx >= universes.size() or universes.size() <= 1:
		return
	if universes[idx].output_mode == ArtNetUniverse.OUT_USB:
		UsbDmx.unroute(universes[idx].usb_serial)
	universes[idx].close()
	universes.remove_at(idx)


## Trim or grow the slot list to exactly `n` universes (clamped to
## [1, MAX_UNIVERSES]). Used when loading a show file.
func set_universe_count(n: int) -> void:
	n = clampi(n, 1, MAX_UNIVERSES)
	while universes.size() < n:
		add_universe()
	while universes.size() > n:
		var last := universes[universes.size() - 1]
		if last.output_mode == ArtNetUniverse.OUT_USB:
			UsbDmx.unroute(last.usb_serial)
		last.close()
		universes.remove_at(universes.size() - 1)


## Recompute every universe's `output` (base + effect/chase layer + grand
## master). When `transmit` is true, also put it on the wire. Call this
## every refresh tick — computing always keeps the 3D visualizer live
## even while "Sending" is off.
func tick(transmit: bool = true) -> void:
	var bases: Array = []
	for u in universes:
		bases.append(u.dmx_data)
	var layers: Array = Fx.compose(universes.size(), bases)
	for i in range(universes.size()):
		var ov: Dictionary = layers[i] if i < layers.size() else {}
		var u := universes[i]
		u.compute_output(master, ov)
		if transmit:
			match u.output_mode:
				ArtNetUniverse.OUT_USB:
					UsbDmx.send(u.usb_serial, u.output)
				ArtNetUniverse.OUT_SACN:
					u.transmit_sacn()
				_:
					u.transmit()


func send_all() -> void:
	tick(true)


# ------------------------------------------------------------ CROSSFADE --

func is_fading() -> bool:
	return _fade_active


## Crossfade every universe's buffer toward `targets` (targets[i] is a
## 512-byte PackedByteArray for universe slot i; slots past the list are
## left untouched). Channels rising use `fade_up` seconds, channels
## falling use `fade_down`. A running fade is replaced.
func start_fade(targets: Array, fade_up: float, fade_down: float) -> void:
	_fade_from = []
	for u in universes:
		_fade_from.append(u.dmx_data.duplicate())
	_fade_to = targets
	_fade_up = maxf(fade_up, 0.0)
	_fade_down = maxf(fade_down, 0.0)
	_fade_elapsed = 0.0
	_fade_active = true
	# Land instantly for a 0-second fade.
	if _fade_up == 0.0 and _fade_down == 0.0:
		_step()


func stop_fade() -> void:
	_fade_active = false


func _process(delta: float) -> void:
	if not _fade_active:
		return
	_fade_elapsed += delta
	_step()


func _step() -> void:
	var still_going := false
	for i in range(universes.size()):
		if i >= _fade_to.size():
			break
		var from: PackedByteArray = _fade_from[i] if i < _fade_from.size() else PackedByteArray()
		var to: PackedByteArray = _fade_to[i]
		var buf := PackedByteArray()
		buf.resize(DMX_UNIVERSE_SIZE)
		for c in range(DMX_UNIVERSE_SIZE):
			var a := int(from[c]) if c < from.size() else 0
			var b := int(to[c]) if c < to.size() else 0
			if a == b:
				buf[c] = a
				continue
			var dur := _fade_up if b > a else _fade_down
			var t := 1.0 if dur <= 0.0 else clampf(_fade_elapsed / dur, 0.0, 1.0)
			if t < 1.0:
				still_going = true
			buf[c] = int(round(a + (b - a) * t))
		universes[i].dmx_data = buf
	if not still_going:
		_fade_active = false
		fade_finished.emit()


func _exit_tree() -> void:
	for u in universes:
		u.close()
