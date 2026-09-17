#include "midi_output.h"
#include "RtMidi.h"

#include <godot_cpp/core/class_db.hpp>

#include <vector>

using namespace godot;

void MidiOutput::_bind_methods() {
	ClassDB::bind_method(D_METHOD("driver_available"), &MidiOutput::driver_available);
	ClassDB::bind_method(D_METHOD("list_ports"), &MidiOutput::list_ports);
	ClassDB::bind_method(D_METHOD("open_port", "index"), &MidiOutput::open_port);
	ClassDB::bind_method(D_METHOD("open_port_by_name", "name_substr"), &MidiOutput::open_port_by_name);
	ClassDB::bind_method(D_METHOD("close"), &MidiOutput::close);
	ClassDB::bind_method(D_METHOD("is_open"), &MidiOutput::is_open);
	ClassDB::bind_method(D_METHOD("send", "status", "d1", "d2"), &MidiOutput::send);
}

MidiOutput::MidiOutput() {
	try {
		_out = new RtMidiOut();
	} catch (RtMidiError &) {
		_out = nullptr;
	}
}

MidiOutput::~MidiOutput() {
	close();
	delete _out;
}

bool MidiOutput::driver_available() {
	return _out != nullptr;
}

PackedStringArray MidiOutput::list_ports() {
	PackedStringArray out;
	if (_out == nullptr) {
		return out;
	}
	try {
		unsigned int n = _out->getPortCount();
		for (unsigned int i = 0; i < n; i++) {
			out.push_back(String(_out->getPortName(i).c_str()));
		}
	} catch (RtMidiError &) {
	}
	return out;
}

bool MidiOutput::open_port(int index) {
	if (_out == nullptr || index < 0) {
		return false;
	}
	close();
	try {
		_out->openPort((unsigned int)index);
		_is_open = true;
	} catch (RtMidiError &) {
		_is_open = false;
	}
	return _is_open;
}

bool MidiOutput::open_port_by_name(const String &name_substr) {
	if (_out == nullptr) {
		return false;
	}
	String needle = name_substr.to_lower();
	try {
		unsigned int n = _out->getPortCount();
		for (unsigned int i = 0; i < n; i++) {
			String pname = String(_out->getPortName(i).c_str());
			if (needle.is_empty() || pname.to_lower().find(needle) != -1) {
				return open_port((int)i);
			}
		}
	} catch (RtMidiError &) {
	}
	return false;
}

void MidiOutput::close() {
	if (_out != nullptr && _is_open) {
		try {
			_out->closePort();
		} catch (RtMidiError &) {
		}
	}
	_is_open = false;
}

bool MidiOutput::is_open() const {
	return _is_open;
}

void MidiOutput::send(int status, int d1, int d2) {
	if (_out == nullptr || !_is_open) {
		return;
	}
	std::vector<unsigned char> msg;
	msg.push_back((unsigned char)(status & 0xFF));
	msg.push_back((unsigned char)(d1 & 0x7F));
	msg.push_back((unsigned char)(d2 & 0x7F));
	try {
		_out->sendMessage(&msg);
	} catch (RtMidiError &) {
	}
}
