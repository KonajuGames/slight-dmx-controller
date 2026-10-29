extends Node
## Autoload singleton: "Triggers"
##
## Listens for MIDI (Godot's built-in `InputEventMIDI`) and OSC (a UDP
## listener on `osc_port`) and fires console actions through `fired`. The
## shell (dmx_controller.gd) connects that to the cue / chase / effect
## panels. The Triggers dialog edits `triggers` and drives Learn.
##
## Also sends **feedback**: when a binding's target is active (its cue is
## live, its chase / effect is running) its pad is lit. Godot has no
## built-in MIDI output, so MIDI feedback prefers the native `midi_out`
## GDExtension (see `midi_out_bridge.gd`'s `MidiOut` autoload) when it's
## built and a port is selected; otherwise it falls back to UDP, sent to
## `tools/midi_bridge.py`. OSC feedback goes straight to the device either
## way.

signal fired(action: int, target: String)     ## a binding matched
## A flash binding's pad came back up (Trigger.FLASH_ACTIONS: note-off,
## CC below 64, OSC 0). A Program Change flash, which has none, fires with
## the target Trigger.FLASH_TOGGLE instead.
signal released(action: int, target: String)
signal activity(text: String)                 ## last message seen (dialog display)
signal learned(descriptor: Dictionary)        ## a Learn capture completed
signal osc_state_changed(listening: bool, detail: String)

var triggers: Array[Trigger] = []

var midi_enabled := true
var osc_enabled := false
var osc_port := 9000

# feedback
var feedback_enabled := false
var midi_out_host := "127.0.0.1"
var midi_out_port := 9010                      ## the midi_bridge.py UDP port (fallback)
var midi_out_port_name := ""                   ## native MidiOut port name (preferred)
var osc_out_host := "127.0.0.1"
var osc_out_port := 9001
## Set by the shell: func(action: int, target: String) -> bool.
var feedback_state_cb := Callable()

var _learning := false
var _udp := PacketPeerUDP.new()
var _midi_opened := false
var _fb_state := {}
var _fb_refresh := 0.0
var _fb_pulse := {}          ## binding id -> seconds left holding the "on" value
var _bend_down := {}         ## pitch-bend binding -> whether its bend is past BEND_PRESS


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	_open_midi()
	get_tree().root.window_input.connect(_on_window_input)
	Sound.beat.connect(func():
		if not Tempo.running:            # the tempo clock's beats win
			_on_ext_beat())
	Tempo.beat.connect(_on_ext_beat)


func _open_midi() -> void:
	if not _midi_opened:
		OS.open_midi_inputs()
		_midi_opened = true


func midi_devices() -> PackedStringArray:
	_open_midi()
	return OS.get_connected_midi_inputs()


## Close and reopen every MIDI input, so a device plugged in since they
## were opened is listened to too.
func reopen_midi() -> void:
	if _midi_opened:
		OS.close_midi_inputs()
		_midi_opened = false
	_open_midi()


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

## MIDI arrives as the root window's input, taken here before the window
## passes it on: Godot forwards it only to a focused dialog (an embedded
## window) then — a root-level _input() would miss every message while the
## Triggers dialog is open, Learn included.
func _on_window_input(event: InputEvent) -> void:
	if not (event is InputEventMIDI) or not midi_enabled:
		return
	var ev: InputEventMIDI = event
	# ignore the constant stream of clock / active-sensing / aftertouch
	if ev.message not in [MIDI_MESSAGE_NOTE_ON, MIDI_MESSAGE_NOTE_OFF,
			MIDI_MESSAGE_CONTROL_CHANGE, MIDI_MESSAGE_PROGRAM_CHANGE, MIDI_MESSAGE_PITCH_BEND]:
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
		elif ev.message == MIDI_MESSAGE_PITCH_BEND:
			kind = Trigger.MIDI_PITCH_BEND
			number = 0
		learned.emit({
			"source": Trigger.SRC_MIDI, "kind": kind,
			"channel": ev.channel, "number": number,
		})
		return

	_report_midi(ev)
	for t in triggers:
		if not (t.enabled and t.fires_action()):
			continue
		if t.midi_kind == Trigger.MIDI_PITCH_BEND and ev.message == MIDI_MESSAGE_PITCH_BEND \
				and t.source == Trigger.SRC_MIDI and (t.midi_channel < 0 or ev.channel == t.midi_channel):
			# A bend streams values as it moves: only crossing BEND_PRESS counts.
			var down := t.matches_midi(ev)
			if down == bool(_bend_down.get(t, false)):
				continue
			_bend_down[t] = down
		if t.matches_midi(ev):
			# A Program Change has no release: its flash toggles instead.
			var toggles := t.is_flash() and t.midi_kind == Trigger.MIDI_PROGRAM
			fired.emit(t.action, Trigger.FLASH_TOGGLE if toggles else t.target)
		elif t.is_flash() and t.matches_midi_release(ev):
			released.emit(t.action, t.target)


func _process(delta: float) -> void:
	_feedback_tick(delta)
	if not osc_enabled:
		return
	while _udp.get_available_packet_count() > 0:
		var pkt := _udp.get_packet()
		for msg in OscMessage.parse_packet(pkt):
			_dispatch_osc(msg)


# ------------------------------------------------------------- FEEDBACK --

func set_feedback(enabled: bool, midi_port: int, osc_host: String, osc_port_: int) -> void:
	# turn the LEDs off on the *current* ports before changing anything
	if feedback_enabled and not enabled:
		all_feedback_off()
	feedback_enabled = enabled
	midi_out_port = clampi(midi_port, 1, 65535)
	osc_out_host = osc_host if osc_host.strip_edges() != "" else "127.0.0.1"
	osc_out_port = clampi(osc_port_, 1, 65535)
	if enabled:
		refresh_feedback()


## Open a native MIDI output port for feedback (the `midi_out` extension's
## MidiOut autoload) — the first port whose name contains `name_substr`
## (case-insensitive; "" picks the first available port). No-op, `MidiOut`
## stays closed, if the extension isn't built: feedback then falls back to
## the UDP bridge. Call again with "" to release the port.
func set_midi_output_port(name_substr: String) -> void:
	midi_out_port_name = name_substr
	if not MidiOut.available:
		return
	if name_substr.strip_edges() == "":
		MidiOut.close()
	else:
		MidiOut.open_port(name_substr)


## Force every feedback binding to re-send its current state (call after a
## show load, or when a controller is plugged in).
func refresh_feedback() -> void:
	_fb_state.clear()
	_fb_refresh = 0.0


## A beat (the tempo clock's, or else the live audio's in Sound Reactive):
## flash every Beat-watch feedback pad.
func _on_ext_beat() -> void:
	if not feedback_enabled:
		return
	for t in triggers:
		if t.enabled and t.fb_enabled and t.fb_watch == Trigger.FB_BEAT:
			_send_feedback(t, t.fb_on)
			_fb_pulse[t.get_instance_id()] = 0.09


func _feedback_tick(delta: float) -> void:
	if not feedback_enabled:
		return

	# decay beat flashes back to the "off" value
	for key in _fb_pulse.keys():
		_fb_pulse[key] -= delta
		if _fb_pulse[key] <= 0.0:
			_fb_pulse.erase(key)
			var t := instance_from_id(key) as Trigger
			if t != null:
				_send_feedback(t, t.fb_off)

	if not feedback_state_cb.is_valid():
		return
	_fb_refresh -= delta
	if _fb_refresh <= 0.0:
		_fb_refresh = 2.0
		_fb_state.clear()          # periodic full resend — handles hot-plug
	for t in triggers:
		if not (t.enabled and t.fb_enabled and t.can_feedback()):
			continue
		if t.fb_watch == Trigger.FB_BEAT:
			continue               # pulse-driven, handled in _on_ext_beat
		var q: Array = t.feedback_query()
		if q[0] == "":
			continue
		var active: bool = bool(feedback_state_cb.call(q[0], q[1]))
		var key := t.get_instance_id()
		if _fb_state.get(key, null) != active:
			_fb_state[key] = active
			_send_feedback(t, t.fb_on if active else t.fb_off)


## Send every feedback binding's "off" value (on shutdown / feedback off).
func all_feedback_off() -> void:
	for t in triggers:
		if t.fb_enabled:
			_send_feedback(t, t.fb_off)
	_fb_state.clear()
	_fb_pulse.clear()


func _exit_tree() -> void:
	all_feedback_off()


func _send_feedback(t: Trigger, value: int) -> void:
	if t.source == Trigger.SRC_MIDI:
		var ch: int = maxi(t.midi_channel, 0)
		if t.midi_kind == Trigger.MIDI_PITCH_BEND:
			# 0..127 scaled to the 14-bit bend (a motor fader goes there)
			var bend := clampi(roundi(value / 127.0 * 16383.0), 0, 16383)
			if MidiOut.is_open():
				MidiOut.send(0xE0 | (ch & 0x0F), bend & 0x7F, bend >> 7)
			else:
				FeedbackOut.send_midi(midi_out_host, midi_out_port, 0xE0 | (ch & 0x0F), bend & 0x7F, bend >> 7)
		elif MidiOut.is_open():
			# native path (midi_out extension) -- no UDP hop, no bridge script
			if t.midi_kind == Trigger.MIDI_CC:
				MidiOut.cc(ch, t.midi_number, value)
			else:
				MidiOut.note(ch, t.midi_number, value)
		elif t.midi_kind == Trigger.MIDI_CC:
			FeedbackOut.cc(midi_out_host, midi_out_port, ch, t.midi_number, value)
		else:
			FeedbackOut.note(midi_out_host, midi_out_port, ch, t.midi_number, value)
	else:
		FeedbackOut.osc(osc_out_host, osc_out_port, t.osc_address, float(value) / 127.0)


func _dispatch_osc(msg: OscMessage) -> void:
	if _learning:
		_learning = false
		learned.emit({"source": Trigger.SRC_OSC, "address": msg.address})
		return
	var arg_txt := "" if msg.args.is_empty() else "  %s" % str(msg.args)
	activity.emit("OSC  %s%s" % [msg.address, arg_txt])
	for t in triggers:
		if t.enabled and t.fires_action() and t.matches_osc(msg):
			fired.emit(t.action, t.target)
		elif t.enabled and t.is_flash() and t.matches_osc_release(msg):
			released.emit(t.action, t.target)


func _report_midi(ev: InputEventMIDI) -> void:
	var ch := ev.channel + 1
	match ev.message:
		MIDI_MESSAGE_CONTROL_CHANGE:
			activity.emit("MIDI  CC %d = %d  ch %d" % [ev.controller_number, ev.controller_value, ch])
		MIDI_MESSAGE_PROGRAM_CHANGE:
			activity.emit("MIDI  PC %d  ch %d" % [ev.pitch, ch])
		MIDI_MESSAGE_PITCH_BEND:
			activity.emit("MIDI  Pitch Bend %d  ch %d" % [ev.pitch, ch])
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
		"feedback_enabled": feedback_enabled,
		"midi_out_port": midi_out_port,
		"midi_out_port_name": midi_out_port_name,
		"osc_out_host": osc_out_host,
		"osc_out_port": osc_out_port,
	}


func from_dict(d: Dictionary) -> void:
	triggers.clear()
	for e in d.get("triggers", []):
		if e is Dictionary:
			triggers.append(Trigger.from_dict(e))
	midi_enabled = bool(d.get("midi_enabled", true))
	set_osc(bool(d.get("osc_enabled", false)), int(d.get("osc_port", 9000)))
	set_feedback(
		bool(d.get("feedback_enabled", false)),
		int(d.get("midi_out_port", 9010)),
		String(d.get("osc_out_host", "127.0.0.1")),
		int(d.get("osc_out_port", 9001)))
	set_midi_output_port(String(d.get("midi_out_port_name", "")))
