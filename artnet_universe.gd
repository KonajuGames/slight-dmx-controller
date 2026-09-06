class_name ArtNetUniverse
extends RefCounted
## One Art-Net universe: a 512-channel DMX buffer plus its own UDP socket
## and target. Builds and sends ArtDMX packets — any Art-Net-to-DMX
## gateway/node, or software like QLC+, can receive them.
##
## The `ArtNet` autoload owns one of these per universe slot; see
## artnet_sender.gd.

const ARTNET_PORT_DEFAULT := 6454
const DMX_UNIVERSE_SIZE := 512

var udp := PacketPeerUDP.new()
var target_ip := "127.0.0.1"
var target_port := ARTNET_PORT_DEFAULT
## The Art-Net universe number written into the packet (0..32767). The
## slot's position in the GUI is separate from this — several slots can
## even target the same number on different IPs.
var artnet_universe := 0
var connected := false

var _sequence := 0
var dmx_data := PackedByteArray()


func _init() -> void:
	dmx_data.resize(DMX_UNIVERSE_SIZE)
	dmx_data.fill(0)


## Point this universe's sender at a new IP/port. Safe to call repeatedly.
func set_target(ip: String, port: int = ARTNET_PORT_DEFAULT) -> void:
	target_ip = ip
	target_port = port
	udp.close()
	var err := udp.connect_to_host(target_ip, target_port)
	connected = (err == OK)


## Set a single DMX channel. channel is 0-indexed (0..511), value is 0..255.
func set_channel(channel: int, value: int) -> void:
	if channel < 0 or channel >= DMX_UNIVERSE_SIZE:
		return
	dmx_data[channel] = clampi(value, 0, 255)


func get_channel(channel: int) -> int:
	if channel < 0 or channel >= DMX_UNIVERSE_SIZE:
		return 0
	return dmx_data[channel]


func set_all(value: int) -> void:
	dmx_data.fill(clampi(value, 0, 255))


## Send the buffer as one ArtDMX packet. `overrides` ({channel: value})
## replace those channels first (the effects/chase layer); then the whole
## frame is scaled by `scale` (0..1, the grand master). Both act on a
## copy, so the stored per-channel values are never lost. Call
## ~30-40x/second — most Art-Net receivers expect a steady refresh stream,
## like real DMX512.
func send(scale: float = 1.0, overrides: Dictionary = {}) -> void:
	if not connected:
		return

	var data := dmx_data
	if scale < 1.0 or not overrides.is_empty():
		data = dmx_data.duplicate()
		for key in overrides:
			var c := int(key)
			if c >= 0 and c < data.size():
				data[c] = clampi(int(overrides[key]), 0, 255)
		if scale < 1.0:
			for i in range(data.size()):
				data[i] = int(data[i] * scale)

	var packet := PackedByteArray()

	# "Art-Net" + null terminator (8 bytes, protocol ID)
	packet.append_array("Art-Net".to_ascii_buffer())
	packet.append(0)

	# OpCode = OpDmx (0x5000), sent low byte first
	packet.append(0x00)
	packet.append(0x50)

	# Protocol version 14, high byte first
	packet.append(0)
	packet.append(14)

	# Sequence number (1-255, 0 disables sequencing). Wrap, skipping 0.
	_sequence = (_sequence % 255) + 1
	packet.append(_sequence)

	# Physical port (informational only)
	packet.append(0)

	# Universe, 15-bit, low byte first
	packet.append(artnet_universe & 0xFF)
	packet.append((artnet_universe >> 8) & 0xFF)

	# Data length, high byte first, must be even
	var length := data.size()
	if length % 2 != 0:
		length -= 1
	packet.append((length >> 8) & 0xFF)
	packet.append(length & 0xFF)

	packet.append_array(data.slice(0, length))

	udp.put_packet(packet)


func close() -> void:
	udp.close()
