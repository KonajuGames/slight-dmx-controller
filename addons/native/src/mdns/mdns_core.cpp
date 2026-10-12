#include "mdns_core.h"

#include <atomic>
#include <cstdio>
#include <mutex>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <arpa/inet.h>
#include <dlfcn.h>
#include <sys/select.h>
#endif

namespace mdns {

class Backend {
public:
	virtual ~Backend() {}
	virtual bool available() const = 0;
	virtual const char *name() const = 0;
	virtual bool start(const std::string &instance, const std::string &type, uint16_t port,
			const Advertiser::Txt &txt) = 0;
	virtual void stop() = 0;
	virtual void poll() {}

	Advertiser::State state() const {
		std::lock_guard<std::mutex> lock(_m);
		return _state;
	}
	std::string registered_name() const {
		std::lock_guard<std::mutex> lock(_m);
		return _registered_name;
	}
	std::string error() const {
		std::lock_guard<std::mutex> lock(_m);
		return _error;
	}

protected:
	// Called from the responder's callback, which on Windows runs on a
	// thread-pool thread -- hence the lock.
	void set_state(Advertiser::State s, const std::string &name = std::string(),
			const std::string &err = std::string()) {
		std::lock_guard<std::mutex> lock(_m);
		_state = s;
		if (!name.empty() || s == Advertiser::IDLE) {
			_registered_name = name;
		}
		_error = err;
	}

private:
	mutable std::mutex _m;
	Advertiser::State _state = Advertiser::IDLE;
	std::string _registered_name;
	std::string _error;
};

static std::string code_error(const char *what, long code) {
	char buf[96];
	std::snprintf(buf, sizeof(buf), "%s failed (error %ld)", what, code);
	return buf;
}

#if defined(_WIN32)

// ----------------------------------------------------------------------------
// Windows: dnsapi.dll's DNS-SD functions (Windows 10 1809+). Declared here
// rather than taken from <windns.h> so the build doesn't depend on the SDK
// version or NTDDI_VERSION; layouts match windns.h.

namespace {

typedef void *PInstance; // DNS_SERVICE_INSTANCE*; its first field is the LPWSTR instance name
typedef VOID(WINAPI *RegisterComplete)(DWORD status, PVOID context, PInstance instance);

struct RegisterRequest { // DNS_SERVICE_REGISTER_REQUEST
	ULONG Version;
	ULONG InterfaceIndex;
	PInstance pServiceInstance;
	RegisterComplete pRegisterCompletionCallback;
	PVOID pQueryContext;
	HANDLE hCredentials;
	BOOL unicastEnabled;
};

typedef PInstance(WINAPI *ConstructInstanceFn)(PCWSTR name, PCWSTR host, DWORD *ip4, void *ip6,
		WORD port, WORD priority, WORD weight, DWORD count, PCWSTR *keys, PCWSTR *values);
typedef VOID(WINAPI *FreeInstanceFn)(PInstance);
typedef DWORD(WINAPI *RegisterFn)(RegisterRequest *, void *cancel);

const ULONG kRequestVersion1 = 1;      // DNS_QUERY_REQUEST_VERSION1
const DWORD kRequestPending = 9506;    // DNS_REQUEST_PENDING
const DWORD kWaitMs = 3000;            // longest we block in stop() for the responder

std::wstring widen(const std::string &s) {
	if (s.empty()) {
		return std::wstring();
	}
	int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
	std::wstring w(n, L'\0');
	MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], n);
	return w;
}

std::string narrow(const wchar_t *w) {
	if (w == nullptr || *w == 0) {
		return std::string();
	}
	int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
	std::string s(n > 0 ? n - 1 : 0, '\0');
	if (n > 1) {
		WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, nullptr, nullptr);
	}
	return s;
}

} // namespace

class WindowsBackend : public Backend {
public:
	WindowsBackend() {
		_lib = LoadLibraryW(L"dnsapi.dll");
		if (_lib == nullptr) {
			return;
		}
		_construct = (ConstructInstanceFn)GetProcAddress(_lib, "DnsServiceConstructInstance");
		_free = (FreeInstanceFn)GetProcAddress(_lib, "DnsServiceFreeInstance");
		_register = (RegisterFn)GetProcAddress(_lib, "DnsServiceRegister");
		_deregister = (RegisterFn)GetProcAddress(_lib, "DnsServiceDeRegister");
	}

	~WindowsBackend() override {
		stop();
		// dnsapi.dll stays loaded: a registration abandoned after a timeout
		// in stop() may still call back into it.
	}

	bool available() const override {
		return _construct && _free && _register && _deregister;
	}

	const char *name() const override { return available() ? "windows-dnsapi" : ""; }

	bool start(const std::string &instance, const std::string &type, uint16_t port,
			const Advertiser::Txt &txt) override {
		stop();
		if (!available()) {
			set_state(Advertiser::FAILED, "", "DNS-SD API not available (needs Windows 10 1809+)");
			return false;
		}
		wchar_t host[256];
		DWORD host_len = 256;
		if (!GetComputerNameExW(ComputerNameDnsHostname, host, &host_len)) {
			set_state(Advertiser::FAILED, "", code_error("GetComputerNameEx", (long)GetLastError()));
			return false;
		}
		_suffix = "." + type + ".local";
		std::wstring full = widen(instance + _suffix);
		std::wstring host_local = std::wstring(host) + L".local";

		std::vector<std::wstring> keys, values;
		for (const auto &kv : txt) {
			keys.push_back(widen(kv.first));
			values.push_back(widen(kv.second));
		}
		std::vector<PCWSTR> kp, vp;
		for (size_t i = 0; i < keys.size(); i++) {
			kp.push_back(keys[i].c_str());
			vp.push_back(values[i].c_str());
		}

		Reg *reg = new Reg();
		reg->owner = this;
		reg->free_fn = _free;
		reg->registered = CreateEventW(nullptr, TRUE, FALSE, nullptr);
		reg->deregistered = CreateEventW(nullptr, TRUE, FALSE, nullptr);
		// No addresses given: the responder answers with this host's own.
		reg->instance = _construct(full.c_str(), host_local.c_str(), nullptr, nullptr, port, 0, 0,
				(DWORD)kp.size(), kp.empty() ? nullptr : kp.data(), vp.empty() ? nullptr : vp.data());
		if (reg->instance == nullptr) {
			set_state(Advertiser::FAILED, "", "DnsServiceConstructInstance failed");
			destroy(reg);
			return false;
		}
		reg->req.Version = kRequestVersion1;
		reg->req.InterfaceIndex = 0; // all interfaces
		reg->req.pServiceInstance = reg->instance;
		reg->req.pRegisterCompletionCallback = &WindowsBackend::on_complete;
		reg->req.pQueryContext = reg;

		set_state(Advertiser::REGISTERING, instance);
		_reg = reg; // before registering: the callback may run immediately
		DWORD r = _register(&reg->req, nullptr);
		if (r != kRequestPending) {
			_reg = nullptr;
			set_state(Advertiser::FAILED, "", code_error("DnsServiceRegister", (long)r));
			destroy(reg);
			return false;
		}
		return true;
	}

	void stop() override {
		Reg *reg = _reg.exchange(nullptr);
		if (reg == nullptr) {
			return;
		}
		// The register callback has to have happened before deregistering
		// (and before `reg` can be reused for the deregister callback).
		if (WaitForSingleObject(reg->registered, kWaitMs) != WAIT_OBJECT_0) {
			abandon(reg);
			return;
		}
		bool was_registered;
		{
			std::lock_guard<std::mutex> lock(reg->m);
			was_registered = reg->status == ERROR_SUCCESS;
			reg->deregistering = true;
		}
		if (was_registered) {
			// Deregister what was actually registered: after a name conflict
			// that's the renamed instance ("sLight(1)"), and deregistering
			// the requested name instead would withdraw whoever owns *that*
			// and orphan ours.
			if (reg->registered_instance != nullptr) {
				reg->req.pServiceInstance = reg->registered_instance;
			}
			DWORD r = _deregister(&reg->req, nullptr);
			if (r == kRequestPending && WaitForSingleObject(reg->deregistered, kWaitMs) != WAIT_OBJECT_0) {
				abandon(reg);
				return;
			}
		}
		destroy(reg);
		set_state(Advertiser::IDLE);
	}

private:
	struct Reg {
		RegisterRequest req = {};
		PInstance instance = nullptr;            // what we asked for
		PInstance registered_instance = nullptr; // what the responder registered (from the callback)
		WindowsBackend *owner = nullptr; // not touched once `abandoned`
		FreeInstanceFn free_fn = nullptr;
		std::mutex m;
		bool deregistering = false;
		bool abandoned = false;
		DWORD status = 0;
		HANDLE registered = nullptr;   // set once the register callback ran
		HANDLE deregistered = nullptr; // set once the deregister callback ran
	};

	static VOID WINAPI on_complete(DWORD status, PVOID context, PInstance result) {
		Reg *reg = (Reg *)context;
		std::string result_name;
		if (result != nullptr) {
			result_name = narrow(*(wchar_t **)result);
		}
		bool deregistering, abandoned;
		bool keep = false;
		{
			std::lock_guard<std::mutex> lock(reg->m);
			deregistering = reg->deregistering;
			abandoned = reg->abandoned;
			if (!deregistering) {
				reg->status = status;
				// Keep the registered instance for DnsServiceDeRegister.
				if (status == ERROR_SUCCESS && !abandoned && result != nullptr &&
						result != reg->instance && reg->registered_instance == nullptr) {
					reg->registered_instance = result;
					keep = true;
				}
			}
		}
		if (!keep && result != nullptr && result != reg->instance && result != reg->registered_instance) {
			reg->free_fn(result);
		}
		if (abandoned) {
			return; // its owner may be gone; `reg` itself is deliberately leaked
		}
		if (deregistering) {
			SetEvent(reg->deregistered);
			return;
		}
		WindowsBackend *self = reg->owner;
		if (self->_reg.load() == reg) {
			if (status == ERROR_SUCCESS) {
				// "sLight._os2l._tcp.local" -> "sLight"
				const std::string &sfx = self->_suffix;
				if (result_name.size() > sfx.size() &&
						result_name.compare(result_name.size() - sfx.size(), sfx.size(), sfx) == 0) {
					result_name.resize(result_name.size() - sfx.size());
				}
				self->set_state(Advertiser::REGISTERED, result_name);
			} else {
				self->set_state(Advertiser::FAILED, "", code_error("DnsServiceRegister", (long)status));
			}
		}
		SetEvent(reg->registered);
	}

	// The responder didn't answer in time: leave `reg` for its late
	// callback (which then only frees its own result) rather than free it
	// under a pending call.
	void abandon(Reg *reg) {
		{
			std::lock_guard<std::mutex> lock(reg->m);
			reg->abandoned = true;
		}
		set_state(Advertiser::IDLE);
	}

	void destroy(Reg *reg) {
		if (reg->instance != nullptr) {
			_free(reg->instance);
		}
		if (reg->registered_instance != nullptr) {
			_free(reg->registered_instance);
		}
		if (reg->registered) {
			CloseHandle(reg->registered);
		}
		if (reg->deregistered) {
			CloseHandle(reg->deregistered);
		}
		delete reg;
	}

	HMODULE _lib = nullptr;
	ConstructInstanceFn _construct = nullptr;
	FreeInstanceFn _free = nullptr;
	RegisterFn _register = nullptr;
	RegisterFn _deregister = nullptr;
	std::atomic<Reg *> _reg{nullptr};
	std::string _suffix;
};

typedef WindowsBackend PlatformBackend;

#else

// ----------------------------------------------------------------------------
// macOS / Linux: Apple's dns_sd API (libSystem on macOS; Avahi's
// compatibility library on Linux), loaded at run time.

namespace {

typedef struct _DNSServiceRef_t *DNSServiceRef;
typedef void (*RegisterReply)(DNSServiceRef ref, uint32_t flags, int32_t err, const char *name,
		const char *regtype, const char *domain, void *context);
typedef int32_t (*RegisterFn)(DNSServiceRef *ref, uint32_t flags, uint32_t interface_index,
		const char *name, const char *regtype, const char *domain, const char *host,
		uint16_t port_be, uint16_t txt_len, const void *txt, RegisterReply cb, void *context);
typedef int (*SockFdFn)(DNSServiceRef ref);
typedef int32_t (*ProcessResultFn)(DNSServiceRef ref);
typedef void (*DeallocateFn)(DNSServiceRef ref);

#if defined(__APPLE__)
const char *kLibs[] = {"/usr/lib/libSystem.B.dylib", nullptr};
#else
const char *kLibs[] = {"libdns_sd.so.1", "libdns_sd.so", nullptr};
#endif

} // namespace

class DnsSdBackend : public Backend {
public:
	DnsSdBackend() {
		for (int i = 0; kLibs[i] != nullptr && _lib == nullptr; i++) {
			_lib = dlopen(kLibs[i], RTLD_NOW | RTLD_LOCAL);
		}
		if (_lib == nullptr) {
			return;
		}
		_register = (RegisterFn)dlsym(_lib, "DNSServiceRegister");
		_sockfd = (SockFdFn)dlsym(_lib, "DNSServiceRefSockFD");
		_process = (ProcessResultFn)dlsym(_lib, "DNSServiceProcessResult");
		_dealloc = (DeallocateFn)dlsym(_lib, "DNSServiceRefDeallocate");
	}

	~DnsSdBackend() override {
		stop();
		if (_lib != nullptr) {
			dlclose(_lib);
		}
	}

	bool available() const override { return _register && _sockfd && _process && _dealloc; }

	const char *name() const override { return available() ? "dns_sd" : ""; }

	bool start(const std::string &instance, const std::string &type, uint16_t port,
			const Advertiser::Txt &txt) override {
		stop();
		if (!available()) {
#if defined(__APPLE__)
			set_state(Advertiser::FAILED, "", "dns_sd API not available");
#else
			set_state(Advertiser::FAILED, "", "libdns_sd not found (install Avahi's dns_sd compatibility library)");
#endif
			return false;
		}
		// TXT record: length-prefixed "key=value" strings.
		std::string rec;
		for (const auto &kv : txt) {
			std::string s = kv.second.empty() ? kv.first : kv.first + "=" + kv.second;
			if (s.size() > 255) {
				s.resize(255);
			}
			rec.push_back((char)s.size());
			rec += s;
		}
		set_state(Advertiser::REGISTERING, instance);
		int32_t err = _register(&_ref, 0, 0, instance.c_str(), type.c_str(), nullptr, nullptr,
				htons(port), (uint16_t)rec.size(), rec.empty() ? nullptr : rec.data(),
				&DnsSdBackend::on_reply, this);
		if (err != 0) {
			_ref = nullptr;
			set_state(Advertiser::FAILED, "", code_error("DNSServiceRegister", err));
			return false;
		}
		return true;
	}

	void stop() override {
		if (_ref != nullptr) {
			_dealloc(_ref); // withdraws the registration
			_ref = nullptr;
		}
		set_state(Advertiser::IDLE);
	}

	void poll() override {
		if (_ref == nullptr) {
			return;
		}
		int fd = _sockfd(_ref);
		if (fd < 0) {
			return;
		}
		fd_set set;
		FD_ZERO(&set);
		FD_SET(fd, &set);
		timeval tv = {0, 0};
		if (select(fd + 1, &set, nullptr, nullptr, &tv) > 0) {
			int32_t err = _process(_ref);
			if (err != 0) {
				set_state(Advertiser::FAILED, "", code_error("DNSServiceProcessResult", err));
				_dealloc(_ref);
				_ref = nullptr;
			}
		}
	}

private:
	static void on_reply(DNSServiceRef, uint32_t, int32_t err, const char *name, const char *,
			const char *, void *context) {
		DnsSdBackend *self = (DnsSdBackend *)context;
		if (err == 0) {
			self->set_state(Advertiser::REGISTERED, name ? name : "");
		} else {
			self->set_state(Advertiser::FAILED, "", code_error("DNSServiceRegister", err));
		}
	}

	void *_lib = nullptr;
	RegisterFn _register = nullptr;
	SockFdFn _sockfd = nullptr;
	ProcessResultFn _process = nullptr;
	DeallocateFn _dealloc = nullptr;
	DNSServiceRef _ref = nullptr;
};

typedef DnsSdBackend PlatformBackend;

#endif

// ----------------------------------------------------------------------------

Advertiser::Advertiser() : _backend(new PlatformBackend()) {}
Advertiser::~Advertiser() {}

bool Advertiser::available() const { return _backend->available(); }
const char *Advertiser::backend_name() const { return _backend->name(); }

bool Advertiser::start(const std::string &instance, const std::string &type, uint16_t port,
		const Txt &txt) {
	return _backend->start(instance, type, port, txt);
}

void Advertiser::stop() { _backend->stop(); }
void Advertiser::poll() { _backend->poll(); }
Advertiser::State Advertiser::state() const { return _backend->state(); }
std::string Advertiser::registered_name() const { return _backend->registered_name(); }
std::string Advertiser::error() const { return _backend->error(); }

} // namespace mdns
