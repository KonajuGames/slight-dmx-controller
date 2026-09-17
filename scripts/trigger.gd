class_name Trigger
extends RefCounted
## One binding: an incoming MIDI message or OSC address fires one console
## action (a cue GO / Back / Halt / Go-To, or a chase / effect run toggle).
## Held in `Triggers.triggers`, configured in the Triggers dialog, saved
## in the show file.

enum { SRC_MIDI, SRC_OSC }
const SOURCES := ["MIDI", "OSC"]

enum { MIDI_NOTE, MIDI_CC, MIDI_PROGRAM }
const MIDI_KINDS := ["Note", "Control Change", "Program Change"]

enum {
	ACT_CUE_GO, ACT_CUE_BACK, ACT_CUE_HALT, ACT_CUE_GOTO,
	ACT_CHASE_TOGGLE, ACT_EFFECT_TOGGLE, ACT_BLACKOUT, ACT_NONE,
}
const ACTIONS := [
	"Cue — GO", "Cue — Back", "Cue — Halt", "Cue — Go to #",
	"Chase — toggle", "Effect — toggle", "Blackout all",
	"(nothing — feedback only)",
]
## Which actions read `target` (a cue number, or a chase / effect name).
const ACTION_NEEDS_TARGET := {
	ACT_CUE_GOTO: true, ACT_CHASE_TOGGLE: true, ACT_EFFECT_TOGGLE: true,
}

## What a feedback LED follows. FB_ACTION mirrors this binding's own
## action; the rest are standalone console-state indicators.
enum {
	FB_ACTION, FB_BEAT, FB_SENDING, FB_FX_ANY, FB_AUTOSHOW,
	FB_MODE_CUE, FB_MODE_SOUND, FB_MODE_AUTOSHOW,
}
const FB_WATCHES := [
	"this binding's action", "Beat pulse", "Sending is on",
	"Any chase / effect running", "Auto Show is playing",
	"Run mode: Cue", "Run mode: Sound Reactive", "Run mode: Auto Show",
]

var name: String = "Trigger"
var enabled: bool = true
var source: int = SRC_MIDI

# MIDI match
var midi_kind: int = MIDI_NOTE
var midi_channel: int = -1     # -1 = any channel
var midi_number: int = 60      # note pitch / CC number / program number

# OSC match
var osc_address: String = "/go"

# action
var action: int = ACT_CUE_GO
var target: String = ""        # cue number as text, or chase / effect name

# feedback: light this binding's pad from some console state
var fb_enabled: bool = false
var fb_watch: int = FB_ACTION
var fb_on: int = 127           # note velocity / CC value while active
var fb_off: int = 0            # ...and while inactive


func needs_target() -> bool:
	return ACTION_NEEDS_TARGET.has(action)


func fires_action() -> bool:
	return action != ACT_NONE


## Feedback needs a steady state to follow: a standalone watch, or an
## action that has one.
func can_feedback() -> bool:
	if fb_watch != FB_ACTION:
		return true
	return action in [ACT_CUE_GOTO, ACT_CHASE_TOGGLE, ACT_EFFECT_TOGGLE]


## The (kind, target) the feedback engine queries the shell with. A pulse
## watch (Beat) returns "beat".
func feedback_query() -> Array:
	match fb_watch:
		FB_BEAT: return ["beat", ""]
		FB_SENDING: return ["sending", ""]
		FB_FX_ANY: return ["fx_any", ""]
		FB_AUTOSHOW: return ["autoshow", ""]
		FB_MODE_CUE: return ["run_mode", "0"]
		FB_MODE_SOUND: return ["run_mode", "1"]
		FB_MODE_AUTOSHOW: return ["run_mode", "2"]
	# FB_ACTION
	match action:
		ACT_CUE_GOTO: return ["cue", target]
		ACT_CHASE_TOGGLE: return ["chase", target]
		ACT_EFFECT_TOGGLE: return ["effect", target]
	return ["", ""]


## Human-readable summary of what this binding listens for.
func source_summary() -> String:
	if source == SRC_OSC:
		return "OSC  %s" % osc_address
	var ch := "any" if midi_channel < 0 else str(midi_channel + 1)
	match midi_kind:
		MIDI_CC: return "MIDI  CC %d  ch %s" % [midi_number, ch]
		MIDI_PROGRAM: return "MIDI  PC %d  ch %s" % [midi_number, ch]
		_: return "MIDI  Note %d  ch %s" % [midi_number, ch]


## Does this incoming MIDI event fire the trigger? Notes fire on note-on
## with velocity; CC / PC fire on a "pressed" value (>= 64 / any).
func matches_midi(ev: InputEventMIDI) -> bool:
	if source != SRC_MIDI:
		return false
	if midi_channel >= 0 and ev.channel != midi_channel:
		return false
	match midi_kind:
		MIDI_NOTE:
			return ev.message == MIDI_MESSAGE_NOTE_ON and ev.pitch == midi_number and ev.velocity > 0
		MIDI_CC:
			return ev.message == MIDI_MESSAGE_CONTROL_CHANGE \
				and ev.controller_number == midi_number and ev.controller_value >= 64
		MIDI_PROGRAM:
			return ev.message == MIDI_MESSAGE_PROGRAM_CHANGE and ev.pitch == midi_number
	return false


## Does this incoming OSC message fire the trigger? A message with no args,
## or whose first numeric arg is non-zero, counts as a press.
func matches_osc(msg: OscMessage) -> bool:
	if source != SRC_OSC or msg.address != osc_address:
		return false
	if msg.args.is_empty():
		return true
	var a = msg.args[0]
	if a is bool:
		return a
	if a is float or a is int:
		return absf(float(a)) > 0.0001
	return true


## Fill this trigger's match fields from a captured event descriptor
## (produced by Triggers during Learn).
func learn_from(d: Dictionary) -> void:
	source = int(d.get("source", SRC_MIDI))
	if source == SRC_OSC:
		osc_address = String(d.get("address", osc_address))
	else:
		midi_kind = int(d.get("kind", midi_kind))
		midi_channel = int(d.get("channel", midi_channel))
		midi_number = int(d.get("number", midi_number))


func to_dict() -> Dictionary:
	return {
		"name": name, "enabled": enabled, "source": source,
		"midi_kind": midi_kind, "midi_channel": midi_channel, "midi_number": midi_number,
		"osc_address": osc_address, "action": action, "target": target,
		"fb_enabled": fb_enabled, "fb_watch": fb_watch,
		"fb_on": fb_on, "fb_off": fb_off,
	}


static func from_dict(d: Dictionary) -> Trigger:
	var t := Trigger.new()
	t.name = String(d.get("name", "Trigger"))
	t.enabled = bool(d.get("enabled", true))
	t.source = clampi(int(d.get("source", SRC_MIDI)), 0, SOURCES.size() - 1)
	t.midi_kind = clampi(int(d.get("midi_kind", MIDI_NOTE)), 0, MIDI_KINDS.size() - 1)
	t.midi_channel = clampi(int(d.get("midi_channel", -1)), -1, 15)
	t.midi_number = clampi(int(d.get("midi_number", 60)), 0, 127)
	t.osc_address = String(d.get("osc_address", "/go"))
	t.action = clampi(int(d.get("action", ACT_CUE_GO)), 0, ACTIONS.size() - 1)
	t.target = String(d.get("target", ""))
	t.fb_enabled = bool(d.get("fb_enabled", false))
	t.fb_watch = clampi(int(d.get("fb_watch", FB_ACTION)), 0, FB_WATCHES.size() - 1)
	t.fb_on = clampi(int(d.get("fb_on", 127)), 0, 127)
	t.fb_off = clampi(int(d.get("fb_off", 0)), 0, 127)
	return t
