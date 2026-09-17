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

## Where this universe's frames go. ArtNet.tick() reads `output_mode`.
enum { OUT_ARTNET, OUT_SACN, OUT_USB }

var udp := PacketPeerUDP.new()
var target_ip := "127.0.0.1"
var target_port := ARTNET_PORT_DEFAULT
## The universe number written into the packet (Art-Net 0..32767,
## sACN 1..63999). The slot's position in the GUI is separate from this —
## several slots can even target the same number on different IPs.
var artnet_universe := 0
var connected := false

var output_mode: int = OUT_ARTNET

## OUT_USB: the FTDI interface serial (via the UsbDmx bridge) and its
## UsbDmx.MODE_* interface type.
var usb_serial := ""
var usb_mode := 0

## OUT_SACN: E1.31 priority (0..200, default 100) and an optional unicast
## target — blank means multicast to the universe's 239.255.x.x group.
var sacn_priority := 100
var sacn_unicast_ip := ""

var _sequence := 0
var _sacn_sequence := 0
var dmx_data := PackedByteArray()
## The last frame actually put on the wire: dmx_data with the effect/chase
## overrides and grand master already applied. The 3D visualizer reads
## this so it shows exactly what a receiver would.
var output := PackedByteArray()


func _init() -> void:
	dmx_data.resize(DMX_UNIVERSE_SIZE)
	dmx_data.fill(0)
	output.resize(DMX_UNIVERSE_SIZE)
	output.fill(0)


## Point this universe's Art-Net sender at a new IP/port. Safe to call
## repeatedly. Re-opens the socket for the current `output_mode`.
func set_target(ip: String, port: int = ARTNET_PORT_DEFAULT) -> void:
	target_ip = ip
	target_port = port
	_open_socket()


## Switch this universe's output (OUT_ARTNET / OUT_SACN / OUT_USB) and
## re-open the socket to match. sACN needs the universe number and
## `sacn_unicast_ip` set first.
func set_output_mode(mode: int) -> void:
	output_mode = mode
	_open_socket()


func _open_socket() -> void:
	udp.close()
	if output_mode == OUT_USB:
		connected = false                       # the UsbDmx bridge owns the device
		return
	var ip := target_ip
	var port := target_port
	if output_mode == OUT_SACN:
		ip = sacn_unicast_ip if sacn_unicast_ip != "" else Sacn.multicast_ip(maxi(artnet_universe, 1))
		port = Sacn.PORT
	connected = udp.connect_to_host(ip, port) == OK


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


## Fold the effect/chase `overrides` ({channel: value}) and the grand
## master `scale` (0..1) into `output`, without touching the stored
## per-channel values. Always safe to call; does not send anything.
func compute_output(scale: float = 1.0, overrides: Dictionary = {}) -> void:
	var data := dmx_data.duplicate()
	for key in overrides:
		var c := int(key)
		if c >= 0 and c < data.size():
			data[c] = clampi(int(overrides[key]), 0, 255)
	if scale < 1.0:
		for i in range(data.size()):
			data[i] = int(data[i] * scale)
	output = data


## Put the current `output` on the wire as one ArtDMX packet. Call
## ~30-40x/second — most Art-Net receivers expect a steady refresh stream,
## like real DMX512.
func transmit() -> void:
	if not connected:
		return
	var data := output

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


## Put the current `output` on the wire as one E1.31 Data packet. Call
## ~30-40x/second, like `transmit()`.
func transmit_sacn() -> void:
	if not connected:
		return
	_sacn_sequence = (_sacn_sequence + 1) & 0xFF
	udp.put_packet(Sacn.data_packet(
		maxi(artnet_universe, 1), output, ArtNet.sacn_cid, "sLight",
		sacn_priority, _sacn_sequence))


## Convenience: compute + transmit in one call.
func send(scale: float = 1.0, overrides: Dictionary = {}) -> void:
	compute_output(scale, overrides)
	transmit()


func close() -> void:
	udp.close()
