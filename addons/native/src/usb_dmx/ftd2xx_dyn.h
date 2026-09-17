// Minimal, self-contained declarations for the subset of the FTDI D2XX
// API this extension uses, plus a runtime loader. Nothing here needs the
// FTDI SDK at build time — the shared library (ftd2xx.dll / libftd2xx.so
// / libftd2xx.dylib) is opened with dlopen/LoadLibrary at runtime and is
// optional: if it isn't installed, `Ftdi::load()` fails cleanly and the
// extension reports "driver not available".
#ifndef USB_DMX_FTD2XX_DYN_H
#define USB_DMX_FTD2XX_DYN_H

#include <cstdint>

namespace usbdmx {

// D2XX's ULONG/DWORD are 32-bit on every platform FTDI ships for (it is
// `unsigned long` on Windows, where that is 4 bytes). Pin to uint32_t so
// the struct layout and out-params are right on 64-bit Linux too.
typedef void *FT_HANDLE;
typedef uint32_t FT_STATUS; // FT_OK == 0
typedef uint32_t FT_ULONG;

// FT_GetDeviceInfoList node (matches ftd2xx.h layout)
struct FT_DEVICE_LIST_INFO_NODE {
	FT_ULONG Flags;
	FT_ULONG Type;
	FT_ULONG ID;
	FT_ULONG LocId;
	char SerialNumber[16];
	char Description[64];
	FT_HANDLE ftHandle;
};

// data characteristics
static const unsigned char FT_BITS_8 = 8;
static const unsigned char FT_STOP_BITS_2 = 2;
static const unsigned char FT_PARITY_NONE = 0;
// flow control
static const unsigned short FT_FLOW_NONE = 0x0000;
// purge
static const FT_ULONG FT_PURGE_RX = 1;
static const FT_ULONG FT_PURGE_TX = 2;
// open flags
static const FT_ULONG FT_OPEN_BY_SERIAL_NUMBER = 1;

// Function-pointer table. Names match the C API.
struct Ftdi {
	FT_STATUS (*CreateDeviceInfoList)(FT_ULONG *) = nullptr;
	FT_STATUS (*GetDeviceInfoList)(FT_DEVICE_LIST_INFO_NODE *, FT_ULONG *) = nullptr;
	FT_STATUS (*OpenEx)(void *, FT_ULONG, FT_HANDLE *) = nullptr;
	FT_STATUS (*Close)(FT_HANDLE) = nullptr;
	FT_STATUS (*ResetDevice)(FT_HANDLE) = nullptr;
	FT_STATUS (*Purge)(FT_HANDLE, FT_ULONG) = nullptr;
	FT_STATUS (*SetBaudRate)(FT_HANDLE, FT_ULONG) = nullptr;
	FT_STATUS (*SetDataCharacteristics)(FT_HANDLE, unsigned char, unsigned char, unsigned char) = nullptr;
	FT_STATUS (*SetFlowControl)(FT_HANDLE, unsigned short, unsigned char, unsigned char) = nullptr;
	FT_STATUS (*SetLatencyTimer)(FT_HANDLE, unsigned char) = nullptr;
	FT_STATUS (*SetUSBParameters)(FT_HANDLE, FT_ULONG, FT_ULONG) = nullptr;
	FT_STATUS (*SetRts)(FT_HANDLE) = nullptr;
	FT_STATUS (*ClrRts)(FT_HANDLE) = nullptr;
	FT_STATUS (*SetBreakOn)(FT_HANDLE) = nullptr;
	FT_STATUS (*SetBreakOff)(FT_HANDLE) = nullptr;
	FT_STATUS (*Write)(FT_HANDLE, void *, FT_ULONG, FT_ULONG *) = nullptr;

	bool ok = false;

	// Load the platform D2XX library. Safe to call repeatedly; returns
	// whether the table is usable.
	bool load();
	void unload();

	~Ftdi() { unload(); }

private:
	void *_lib = nullptr;
};

// Process-wide instance (loaded lazily by UsbDmxOutput).
Ftdi &ftdi();

} // namespace usbdmx

#endif // USB_DMX_FTD2XX_DYN_H
