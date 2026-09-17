#ifndef MIDI_OUTPUT_H
#define MIDI_OUTPUT_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

class RtMidiOut; // fwd decl -- keeps RtMidi.h (and its <vector>/<string>
                  // surface) out of this public header

namespace godot {

// One open native MIDI output port, via RtMidi (WinMM / CoreMIDI / ALSA,
// whichever backend this build links). Unlike UsbDmxOutput, which
// dynamically loads a vendor DLL at run time, this needs no separate
// runtime driver -- those APIs ship with the OS -- so `driver_available()`
// is really just "did the extension load".
class MidiOutput : public RefCounted {
	GDCLASS(MidiOutput, RefCounted)

private:
	RtMidiOut *_out = nullptr;
	bool _is_open = false;

protected:
	static void _bind_methods();

public:
	bool driver_available();

	// Every visible MIDI output port name, in RtMidi's enumeration order
	// (same order open_port()'s index refers to).
	PackedStringArray list_ports();

	bool open_port(int index);
	// Case-insensitive substring match against list_ports(); opens the
	// first hit. "" matches the first available port.
	bool open_port_by_name(const String &name_substr);
	void close();
	bool is_open() const;

	// One raw MIDI message (status byte + up to two 7-bit data bytes) --
	// same shape as FeedbackOut.send_midi()'s UDP fallback.
	void send(int status, int d1, int d2);

	MidiOutput();
	~MidiOutput();
};

} // namespace godot

#endif // MIDI_OUTPUT_H
