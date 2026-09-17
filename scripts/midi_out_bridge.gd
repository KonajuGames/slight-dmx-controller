extends Node
## Autoload singleton: "MidiOut"
##
## Optional native MIDI output through the `native` GDExtension (RtMidi —
## WinMM / CoreMIDI / ALSA). Build it with `addons/native/build.py`.
## Unlike UsbDmx, there's no separate runtime driver to install: the native
## OS MIDI API ships with the OS, so once the extension is built this just
## works. Until then, `available` is false and every call here is a
## harmless no-op — `triggers_engine.gd` falls back to the
## `tools/midi_bridge.py` UDP path, same as before this extension existed.

## True once the extension is loaded (its backend is always the OS's own
## MIDI API, so there's no separate "driver present" check like UsbDmx).
var available := false

var _out = null              # a MidiOutput
var _port_name := ""         # the name (substring) we're currently open on


func _ready() -> void:
	if ClassDB.class_exists("MidiOutput"):
		_out = ClassDB.instantiate("MidiOutput")
		available = _out != null and _out.driver_available()

	if available:
		print("MidiOut: ready")
	elif _out != null:
		print("MidiOut: extension loaded, but no MIDI backend available on this system")
	else:
		print("MidiOut: extension not built — see addons/native/BUILD.md")


## Every visible MIDI output port name.
func list_ports() -> PackedStringArray:
	if not available:
		return PackedStringArray()
	return _out.list_ports()


## Open the first output port whose name contains `name_substr`
## (case-insensitive; "" opens the first available port). Returns whether
## a port is now open.
func open_port(name_substr: String) -> bool:
	if not available:
		return false
	_port_name = name_substr
	return _out.open_port_by_name(name_substr)


func close() -> void:
	if _out != null:
		_out.close()
	_port_name = ""


func is_open() -> bool:
	return available and _out.is_open()


func current_port_name() -> String:
	return _port_name


## One raw MIDI message (status + up to two 7-bit data bytes).
func send(status: int, d1: int, d2: int) -> void:
	if available and _out.is_open():
		_out.send(status, d1, d2)


func note(channel: int, pitch: int, velocity: int) -> void:
	send(0x90 | (channel & 0x0F), pitch, velocity)


func cc(channel: int, number: int, value: int) -> void:
	send(0xB0 | (channel & 0x0F), number, value)


func _exit_tree() -> void:
	close()
