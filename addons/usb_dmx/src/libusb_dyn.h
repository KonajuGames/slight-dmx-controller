// Runtime loader for the subset of libusb-1.0 the uDMX backend needs.
// Like the D2XX loader: nothing here is needed to *build*, and the
// library is optional at run time. Opens libusb-1.0.dll / libusb-1.0.so.0
// / libusb-1.0.0.dylib with dlopen/LoadLibrary.
#ifndef USB_DMX_LIBUSB_DYN_H
#define USB_DMX_LIBUSB_DYN_H

#include <cstdint>

namespace usbdmx {

typedef struct libusb_context libusb_context;
typedef struct libusb_device libusb_device;
typedef struct libusb_device_handle libusb_device_handle;

// Matches libusb.h (standard USB device descriptor, 18 bytes, aligned).
struct libusb_device_descriptor {
	uint8_t bLength;
	uint8_t bDescriptorType;
	uint16_t bcdUSB;
	uint8_t bDeviceClass;
	uint8_t bDeviceSubClass;
	uint8_t bDeviceProtocol;
	uint8_t bMaxPacketSize0;
	uint16_t idVendor;
	uint16_t idProduct;
	uint16_t bcdDevice;
	uint8_t iManufacturer;
	uint8_t iProduct;
	uint8_t iSerialNumber;
	uint8_t bNumConfigurations;
};

struct Libusb {
	int (*init)(libusb_context **) = nullptr;
	void (*exit)(libusb_context *) = nullptr;
	intptr_t (*get_device_list)(libusb_context *, libusb_device ***) = nullptr; // ssize_t
	void (*free_device_list)(libusb_device **, int) = nullptr;
	int (*get_device_descriptor)(libusb_device *, libusb_device_descriptor *) = nullptr;
	uint8_t (*get_bus_number)(libusb_device *) = nullptr;
	uint8_t (*get_device_address)(libusb_device *) = nullptr;
	int (*open)(libusb_device *, libusb_device_handle **) = nullptr;
	void (*close)(libusb_device_handle *) = nullptr;
	int (*get_string_descriptor_ascii)(libusb_device_handle *, uint8_t, unsigned char *, int) = nullptr;
	int (*set_auto_detach_kernel_driver)(libusb_device_handle *, int) = nullptr;
	int (*set_configuration)(libusb_device_handle *, int) = nullptr;
	int (*claim_interface)(libusb_device_handle *, int) = nullptr;
	int (*release_interface)(libusb_device_handle *, int) = nullptr;
	int (*control_transfer)(libusb_device_handle *, uint8_t, uint8_t, uint16_t, uint16_t,
			unsigned char *, uint16_t, unsigned int) = nullptr;
	int (*bulk_transfer)(libusb_device_handle *, unsigned char, unsigned char *, int,
			int *, unsigned int) = nullptr;

	bool ok = false;
	libusb_context *ctx = nullptr;

	bool load();   // loads the library and calls libusb_init once
	void unload();
	~Libusb() { unload(); }

private:
	void *_lib = nullptr;
};

Libusb &libusb();

} // namespace usbdmx

#endif // USB_DMX_LIBUSB_DYN_H
