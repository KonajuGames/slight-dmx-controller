#include "mdns_advertiser.h"
#include "mdns_core.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>

using namespace godot;

void MdnsAdvertiser::_bind_methods() {
	ClassDB::bind_method(D_METHOD("backend_available"), &MdnsAdvertiser::backend_available);
	ClassDB::bind_method(D_METHOD("get_backend"), &MdnsAdvertiser::get_backend);
	ClassDB::bind_method(D_METHOD("start", "instance", "type", "port", "txt"), &MdnsAdvertiser::start,
			DEFVAL(Dictionary()));
	ClassDB::bind_method(D_METHOD("stop"), &MdnsAdvertiser::stop);
	ClassDB::bind_method(D_METHOD("poll"), &MdnsAdvertiser::poll);
	ClassDB::bind_method(D_METHOD("get_state"), &MdnsAdvertiser::get_state);
	ClassDB::bind_method(D_METHOD("get_registered_name"), &MdnsAdvertiser::get_registered_name);
	ClassDB::bind_method(D_METHOD("get_error"), &MdnsAdvertiser::get_error);

	BIND_ENUM_CONSTANT(STATE_IDLE);
	BIND_ENUM_CONSTANT(STATE_REGISTERING);
	BIND_ENUM_CONSTANT(STATE_REGISTERED);
	BIND_ENUM_CONSTANT(STATE_FAILED);
}

static std::string to_std(const String &s) {
	CharString utf8 = s.utf8();
	return std::string(utf8.get_data(), utf8.length());
}

static String from_std(const std::string &s) {
	return String::utf8(s.c_str(), (int64_t)s.size());
}

MdnsAdvertiser::MdnsAdvertiser() :
		_adv(new mdns::Advertiser()) {}

MdnsAdvertiser::~MdnsAdvertiser() {
	_adv->stop();
}

bool MdnsAdvertiser::backend_available() const {
	return _adv->available();
}

String MdnsAdvertiser::get_backend() const {
	return String(_adv->backend_name());
}

bool MdnsAdvertiser::start(const String &instance, const String &type, int port, const Dictionary &txt) {
	if (port < 1 || port > 65535) {
		return false;
	}
	mdns::Advertiser::Txt entries;
	Array keys = txt.keys();
	for (int64_t i = 0; i < keys.size(); i++) {
		entries.emplace_back(to_std(String(keys[i])), to_std(String(txt[keys[i]])));
	}
	return _adv->start(to_std(instance), to_std(type), (uint16_t)port, entries);
}

void MdnsAdvertiser::stop() {
	_adv->stop();
}

void MdnsAdvertiser::poll() {
	_adv->poll();
}

MdnsAdvertiser::State MdnsAdvertiser::get_state() const {
	return (State)_adv->state();
}

String MdnsAdvertiser::get_registered_name() const {
	return from_std(_adv->registered_name());
}

String MdnsAdvertiser::get_error() const {
	return from_std(_adv->error());
}
