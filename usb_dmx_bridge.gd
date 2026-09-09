extends Node
## Autoload singleton: "UsbDmx"
##
## Optional USB-DMX universe output through the `usb_dmx` GDExtension
## (FTDI D2XX backend — Enttec DMX USB Pro, Open DMX USB, DMXKing, …).
## Build it with `addons/usb_dmx/build.py`. Until then, and on any machine
## without the FTDI runtime, `available` is false and every call here is a
## harmless no-op, so the rest of the app doesn't care.

const MODE_AUTO := 0
const MODE_OPEN_DMX := 1
const MODE_ENTTEC_PRO := 2
const MODE_NAMES := ["Auto", "Open DMX", "Enttec Pro"]

## True once the extension is loaded and the FTDI D2XX library is present.
var available := false

var _probe = null              # a UsbDmxOutput, for enumeration / driver check
var _outputs := {}             # ftdi serial -> UsbDmxOutput


func _ready() -> void:
	if ClassDB.class_exists("UsbDmxOutput"):
		_probe = ClassDB.instantiate("UsbDmxOutput")
		available = _probe != null and _probe.driver_available()

	if available:
		print("UsbDmx: FTDI D2XX ready")
	elif _probe != null:
		print("UsbDmx: extension loaded, but no FTDI D2XX runtime — see addons/usb_dmx/BUILD.md")
	else:
		print("UsbDmx: extension not built — see addons/usb_dmx/BUILD.md")


## [{ serial, description, guessed_mode }] for every connected interface.
func list_devices() -> Array:
	if not available:
		return []
	var out: Array = []
	for d in _probe.list_devices():
		out.append({
			"serial": String(d.get("serial", "")),
			"description": String(d.get("description", "")),
			"guessed_mode": int(d.get("guessed_mode", MODE_OPEN_DMX)),
		})
	return out


## Open (or re-open) `serial` in `mode` (MODE_*). Returns whether it is
## now streaming.
func route(serial: String, mode: int) -> bool:
	if not available or serial == "":
		return false
	var o = _outputs.get(serial, null)
	if o == null:
		o = ClassDB.instantiate("UsbDmxOutput")
		if o == null:
			return false
		_outputs[serial] = o
	o.close()
	if not o.open_serial(serial, mode):
		_outputs.erase(serial)
		return false
	return true


func unroute(serial: String) -> void:
	var o = _outputs.get(serial, null)
	if o != null:
		o.close()
		_outputs.erase(serial)


func is_sending(serial: String) -> bool:
	var o = _outputs.get(serial, null)
	return o != null and o.is_open()


func status(serial: String) -> String:
	if not available:
		return "USB DMX extension not built"
	var o = _outputs.get(serial, null)
	return String(o.get_status()) if o != null else "not open"


## Hand one universe's 512-byte frame to its interface. Call every tick.
func send(serial: String, dmx512: PackedByteArray) -> void:
	var o = _outputs.get(serial, null)
	if o != null:
		o.set_frame(dmx512)


func _exit_tree() -> void:
	for s in _outputs:
		_outputs[s].close()
	_outputs.clear()
