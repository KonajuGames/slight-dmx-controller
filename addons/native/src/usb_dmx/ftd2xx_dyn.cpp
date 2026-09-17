#include "ftd2xx_dyn.h"

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace usbdmx {

#if defined(_WIN32)
static void *open_lib(const char *name) { return (void *)LoadLibraryA(name); }
static void *sym(void *lib, const char *name) { return (void *)GetProcAddress((HMODULE)lib, name); }
static void close_lib(void *lib) { FreeLibrary((HMODULE)lib); }
static const char *kNames[] = {"ftd2xx.dll", "ftd2xx64.dll", nullptr};
#elif defined(__APPLE__)
static void *open_lib(const char *name) { return dlopen(name, RTLD_NOW | RTLD_LOCAL); }
static void *sym(void *lib, const char *name) { return dlsym(lib, name); }
static void close_lib(void *lib) { dlclose(lib); }
static const char *kNames[] = {"libftd2xx.dylib", "@rpath/libftd2xx.dylib",
	"/usr/local/lib/libftd2xx.dylib", nullptr};
#else
static void *open_lib(const char *name) { return dlopen(name, RTLD_NOW | RTLD_LOCAL); }
static void *sym(void *lib, const char *name) { return dlsym(lib, name); }
static void close_lib(void *lib) { dlclose(lib); }
static const char *kNames[] = {"libftd2xx.so", "libftd2xx.so.1",
	"/usr/local/lib/libftd2xx.so", nullptr};
#endif

bool Ftdi::load() {
	if (ok) {
		return true;
	}
	for (int i = 0; kNames[i] != nullptr && _lib == nullptr; i++) {
		_lib = open_lib(kNames[i]);
	}
	if (_lib == nullptr) {
		return false;
	}

#define BIND(field, cname)                                            \
	field = reinterpret_cast<decltype(field)>(sym(_lib, "FT_" cname)); \
	if (field == nullptr) {                                           \
		unload();                                                     \
		return false;                                                 \
	}

	BIND(CreateDeviceInfoList, "CreateDeviceInfoList")
	BIND(GetDeviceInfoList, "GetDeviceInfoList")
	BIND(OpenEx, "OpenEx")
	BIND(Close, "Close")
	BIND(ResetDevice, "ResetDevice")
	BIND(Purge, "Purge")
	BIND(SetBaudRate, "SetBaudRate")
	BIND(SetDataCharacteristics, "SetDataCharacteristics")
	BIND(SetFlowControl, "SetFlowControl")
	BIND(SetLatencyTimer, "SetLatencyTimer")
	BIND(SetUSBParameters, "SetUSBParameters")
	BIND(SetRts, "SetRts")
	BIND(ClrRts, "ClrRts")
	BIND(SetBreakOn, "SetBreakOn")
	BIND(SetBreakOff, "SetBreakOff")
	BIND(Write, "Write")
#undef BIND

	ok = true;
	return true;
}

void Ftdi::unload() {
	if (_lib) {
		close_lib(_lib);
		_lib = nullptr;
	}
	ok = false;
}

Ftdi &ftdi() {
	static Ftdi instance;
	return instance;
}

} // namespace usbdmx
