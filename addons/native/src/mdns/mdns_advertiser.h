#ifndef MDNS_ADVERTISER_H
#define MDNS_ADVERTISER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <memory>

namespace mdns {
class Advertiser;
} // namespace mdns

namespace godot {

// Advertises one DNS-SD service (e.g. "_os2l._tcp", so VirtualDJ can find
// the OS2L server) through the OS's own mDNS responder -- see
// mdns_core.h for the per-platform backends. Like UsbDmxOutput's drivers,
// the backend is loaded at run time: backend_available() is false where
// it's missing (Windows before 10 1809; Linux without Avahi's libdns_sd).
class MdnsAdvertiser : public RefCounted {
	GDCLASS(MdnsAdvertiser, RefCounted)

public:
	enum State {
		STATE_IDLE = 0,
		STATE_REGISTERING = 1,
		STATE_REGISTERED = 2,
		STATE_FAILED = 3,
	};

private:
	std::unique_ptr<mdns::Advertiser> _adv;

protected:
	static void _bind_methods();

public:
	bool backend_available() const;
	// "windows-dnsapi", "dns_sd", or "" when unavailable.
	String get_backend() const;

	// Advertise `instance` as `type` ("_os2l._tcp") on `port`, with optional
	// TXT entries (String keys; values stringified). Returns false if the
	// request couldn't be made (see get_error()); otherwise poll() until
	// get_state() is STATE_REGISTERED or STATE_FAILED.
	bool start(const String &instance, const String &type, int port, const Dictionary &txt);
	void stop();
	void poll();

	State get_state() const;
	// May differ from the requested name after a conflict ("sLight(1)").
	String get_registered_name() const;
	String get_error() const;

	MdnsAdvertiser();
	~MdnsAdvertiser();
};

} // namespace godot

VARIANT_ENUM_CAST(godot::MdnsAdvertiser::State);

#endif // MDNS_ADVERTISER_H
