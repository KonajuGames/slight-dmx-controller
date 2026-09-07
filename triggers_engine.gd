extends Node
## Autoload singleton: "Triggers"
##
## Listens for MIDI (Godot's built-in `InputEventMIDI`) and OSC (a UDP
## listener on `osc_port`) and fires console actions through `fired`. The
## shell (dmx_controller.gd) connects that to the cue / chase / effect
## panels. The Triggers dialog edits `triggers` and drives Learn.

signal fired(action: int, target: String)     ## a binding matched
signal activity(text: String)                 ## last message seen (dialog display)
signal learned(descriptor: Dictionary)        ## a Learn capture completed
signal osc_state_changed(listening: bool, detail: String)

var triggers: Array[Trigger] = []

var midi_enabled := true
var osc_enabled := false
var osc_port := 9000

var _learning := false
var _udp := PacketPeerUDP.new()
var _midi_opened := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	_open_midi()


func _open_midi() -> void:
	if not _midi_opened:
		OS.open_midi_inputs()
		_midi_opened = true


func midi_devices() -> PackedStringArray:
	_open_midi()
	return OS.get_connected_midi_inputs()


# ------------------------------------------------------------------ LEARN --

## Arm Learn: the next MIDI / OSC message is reported via `learned` instead
## of being matched against bindings.
func start_learn() -> void:
	_learning = true

func cancel_learn() -> void:
	_learning = false


# -------------------------------------------------------------------- OSC --

func set_osc(enabled: bool, port: int) -> void:
	osc_enabled = enabled
	osc_port = clampi(port, 1, 65535)
	_udp.close()
	if not osc_enabled:
		osc_state_changed.emit(false, "off")
		return
	var err := _udp.bind(osc_port)
	if err == OK:
		osc_state_changed.emit(true, "listening on :%d" % osc_port)
	else:
		osc_enabled = false
		osc_state_changed.emit(false, "port :%d unavailable" % osc_port)


# ---------------------------------------------------------------- INTAKE --

func _input(event: InputEvent) -> void:
	if not (event is InputEventMIDI) or not midi_enabled:
		return
	var ev: InputEventMIDI = event
	# ignore the constant stream of clock / active-sensing / aftertouch
	if ev.message not in [MIDI_MESSAGE_NOTE_ON, MIDI_MESSAGE_NOTE_OFF,
			MIDI_MESSAGE_CONTROL_CHANGE, MIDI_MESSAGE_PROGRAM_CHANGE]:
		return

	if _learning:
		if ev.message == MIDI_MESSAGE_NOTE_OFF:
			return
		if ev.message == MIDI_MESSAGE_NOTE_ON and ev.velocity == 0:
			return
		_learning = false
		var kind := Trigger.MIDI_NOTE
		var number := ev.pitch
		if ev.message == MIDI_MESSAGE_CONTROL_CHANGE:
			kind = Trigger.MIDI_CC
			number = ev.controller_number
		elif ev.message == MIDI_MESSAGE_PROGRAM_CHANGE:
			kind = Trigger.MIDI_PROGRAM
		learned.emit({
			"source": Trigger.SRC_MIDI, "kind": kind,
			"channel": ev.channel, "number": number,
		})
		return

	_report_midi(ev)
	for t in triggers:
		if t.enabled and t.matches_midi(ev):
			fired.emit(t.action, t.target)


func _process(_delta: float) -> void:
	if not osc_enabled:
		return
	while _udp.get_available_packet_count() > 0:
		var pkt := _udp.get_packet()
		for msg in OscMessage.parse_packet(pkt):
			_dispatch_osc(msg)


func _dispatch_osc(msg: OscMessage) -> void:
	if _learning:
		_learning = false
		learned.emit({"source": Trigger.SRC_OSC, "address": msg.address})
		return
	var arg_txt := "" if msg.args.is_empty() else "  %s" % str(msg.args)
	activity.emit("OSC  %s%s" % [msg.address, arg_txt])
	for t in triggers:
		if t.enabled and t.matches_osc(msg):
			fired.emit(t.action, t.target)


func _report_midi(ev: InputEventMIDI) -> void:
	var ch := ev.channel + 1
	match ev.message:
		MIDI_MESSAGE_CONTROL_CHANGE:
			activity.emit("MIDI  CC %d = %d  ch %d" % [ev.controller_number, ev.controller_value, ch])
		MIDI_MESSAGE_PROGRAM_CHANGE:
			activity.emit("MIDI  PC %d  ch %d" % [ev.pitch, ch])
		MIDI_MESSAGE_NOTE_ON:
			activity.emit("MIDI  Note %d  vel %d  ch %d" % [ev.pitch, ev.velocity, ch])


# ------------------------------------------------------- SERIALIZATION --

func to_dict() -> Dictionary:
	var arr: Array = []
	for t in triggers:
		arr.append(t.to_dict())
	return {
		"triggers": arr,
		"midi_enabled": midi_enabled,
		"osc_enabled": osc_enabled,
		"osc_port": osc_port,
	}


func from_dict(d: Dictionary) -> void:
	triggers.clear()
	for e in d.get("triggers", []):
		if e is Dictionary:
			triggers.append(Trigger.from_dict(e))
	midi_enabled = bool(d.get("midi_enabled", true))
	set_osc(bool(d.get("osc_enabled", false)), int(d.get("osc_port", 9000)))
