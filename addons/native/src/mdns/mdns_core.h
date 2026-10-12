#ifndef MDNS_CORE_H
#define MDNS_CORE_H

// DNS-SD service advertising (mDNS, "Bonjour") through the OS's own
// responder -- no mDNS packets of our own, so no fighting the system
// responder for UDP 5353:
//   - Windows: DnsServiceRegister / DnsServiceDeRegister (dnsapi.dll,
//     Windows 10 1809+), registered with the built-in Dnscache responder.
//   - macOS: DNSServiceRegister (dns_sd, part of libSystem).
//   - Linux: the same dns_sd API from Avahi's compatibility library
//     (libdns_sd.so.1, package avahi-compat-libdns_sd / libavahi-compat-libdnssd1).
// Every backend is loaded at run time, so the extension still loads where
// one is missing; available() just reports false.
//
// Plain C++ (no godot-cpp) so it can be built and tested on its own;
// mdns_advertiser.cpp is the Godot glue.

#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace mdns {

class Backend;

class Advertiser {
public:
	enum State {
		IDLE = 0,        // nothing registered
		REGISTERING = 1, // request sent, waiting for the responder
		REGISTERED = 2,  // advertised (registered_name() is the final name)
		FAILED = 3,      // see error()
	};

	using Txt = std::vector<std::pair<std::string, std::string>>;

	Advertiser();
	~Advertiser();
	Advertiser(const Advertiser &) = delete;
	Advertiser &operator=(const Advertiser &) = delete;

	// Whether this platform's DNS-SD API could be loaded.
	bool available() const;
	// "windows-dnsapi", "dns_sd", or "" when unavailable.
	const char *backend_name() const;

	// Advertise `instance` (e.g. "sLight") as `type` (e.g. "_os2l._tcp") on
	// `port`, with optional TXT key/value pairs. Replaces any current
	// registration. Returns false (and sets error()) if it couldn't even be
	// requested; otherwise the state moves to REGISTERED or FAILED once the
	// responder answers -- call poll() regularly.
	bool start(const std::string &instance, const std::string &type, uint16_t port,
			const Txt &txt = Txt());
	// Withdraw the advertisement (sends goodbye packets).
	void stop();
	// Deliver pending responder replies (dns_sd); harmless no-op elsewhere.
	void poll();

	State state() const;
	// The advertised instance name -- may differ from the requested one if
	// the responder renamed it to resolve a conflict ("sLight (2)").
	std::string registered_name() const;
	std::string error() const;

private:
	std::unique_ptr<Backend> _backend;
};

} // namespace mdns

#endif // MDNS_CORE_H
