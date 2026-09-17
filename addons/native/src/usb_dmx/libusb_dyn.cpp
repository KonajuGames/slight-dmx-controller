#include "libusb_dyn.h"

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace usbdmx {

#if defined(_WIN32)
static void *open_lib(const char *n) { return (void *)LoadLibraryA(n); }
static void *sym(void *l, const char *n) { return (void *)GetProcAddress((HMODULE)l, n); }
static void close_lib(void *l) { FreeLibrary((HMODULE)l); }
static const char *kNames[] = {"libusb-1.0.dll", "libusb-1.0", nullptr};
#elif defined(__APPLE__)
static void *open_lib(const char *n) { return dlopen(n, RTLD_NOW | RTLD_LOCAL); }
static void *sym(void *l, const char *n) { return dlsym(l, n); }
static void close_lib(void *l) { dlclose(l); }
static const char *kNames[] = {"libusb-1.0.0.dylib", "libusb-1.0.dylib",
	"/usr/local/lib/libusb-1.0.0.dylib", "/opt/homebrew/lib/libusb-1.0.0.dylib", nullptr};
#else
static void *open_lib(const char *n) { return dlopen(n, RTLD_NOW | RTLD_LOCAL); }
static void *sym(void *l, const char *n) { return dlsym(l, n); }
static void close_lib(void *l) { dlclose(l); }
static const char *kNames[] = {"libusb-1.0.so.0", "libusb-1.0.so", nullptr};
#endif

bool Libusb::load() {
	if (ok) {
		return true;
	}
	for (int i = 0; kNames[i] && _lib == nullptr; i++) {
		_lib = open_lib(kNames[i]);
	}
	if (_lib == nullptr) {
		return false;
	}

#define BIND(field, cname)                                           \
	field = reinterpret_cast<decltype(field)>(sym(_lib, "libusb_" cname)); \
	if (field == nullptr) {                                          \
		unload();                                                    \
		return false;                                                \
	}
	BIND(init, "init")
	BIND(exit, "exit")
	BIND(get_device_list, "get_device_list")
	BIND(free_device_list, "free_device_list")
	BIND(get_device_descriptor, "get_device_descriptor")
	BIND(get_bus_number, "get_bus_number")
	BIND(get_device_address, "get_device_address")
	BIND(open, "open")
	BIND(close, "close")
	BIND(get_string_descriptor_ascii, "get_string_descriptor_ascii")
	BIND(claim_interface, "claim_interface")
	BIND(release_interface, "release_interface")
	BIND(control_transfer, "control_transfer")
	BIND(bulk_transfer, "bulk_transfer")
#undef BIND
	// optional — don't fail if missing
	set_auto_detach_kernel_driver =
		reinterpret_cast<decltype(set_auto_detach_kernel_driver)>(
			sym(_lib, "libusb_set_auto_detach_kernel_driver"));
	set_configuration =
		reinterpret_cast<decltype(set_configuration)>(sym(_lib, "libusb_set_configuration"));

	if (init(&ctx) != 0) {
		ctx = nullptr;
		unload();
		return false;
	}
	ok = true;
	return true;
}

void Libusb::unload() {
	if (ctx && exit) {
		exit(ctx);
		ctx = nullptr;
	}
	if (_lib) {
		close_lib(_lib);
		_lib = nullptr;
	}
	ok = false;
}

Libusb &libusb() {
	static Libusb instance;
	return instance;
}

} // namespace usbdmx
