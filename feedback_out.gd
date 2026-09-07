class_name FeedbackOut
extends RefCounted
## Outbound control-surface messages for MIDI / OSC feedback.
##
## Godot has no MIDI output, so MIDI feedback is sent as 3-byte packets
## over UDP to a small bridge script (tools/midi_bridge.py) that forwards
## them to a real MIDI port. OSC feedback is sent straight to the device.

static var _udp := PacketPeerUDP.new()


static func _send(host: String, port: int, data: PackedByteArray) -> void:
	if host.strip_edges() == "" or port <= 0 or port > 65535:
		return
	if _udp.set_dest_address(host, port) == OK:
		_udp.put_packet(data)


## One raw MIDI message (status + up to two data bytes).
static func send_midi(host: String, port: int, status: int, d1: int, d2: int) -> void:
	_send(host, port, PackedByteArray([status & 0xFF, d1 & 0x7F, d2 & 0x7F]))


static func note(host: String, port: int, channel: int, pitch: int, velocity: int) -> void:
	send_midi(host, port, 0x90 | (channel & 0x0F), pitch, velocity)


static func cc(host: String, port: int, channel: int, number: int, value: int) -> void:
	send_midi(host, port, 0xB0 | (channel & 0x0F), number, value)


## One OSC message; `value` is sent as a single float argument.
static func osc(host: String, port: int, address: String, value: float) -> void:
	if address.strip_edges() == "":
		return
	_send(host, port, OscMessage.encode(address, [value]))
