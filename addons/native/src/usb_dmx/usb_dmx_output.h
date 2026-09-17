#ifndef USB_DMX_OUTPUT_H
#define USB_DMX_OUTPUT_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <atomic>
#include <cstdint>
#include <mutex>
#include <thread>

namespace godot {

// One open USB DMX interface. Holds a 512-byte frame buffer that a
// background thread streams to the hardware at a fixed refresh rate.
// `set_frame()` is the only thing the game calls per tick.
//
// Backends: FTDI D2XX, or libusb — which handles both anyma uDMX and
// raw FTDI (FT232 vendor requests + bulk writes) for platforms with no
// D2XX driver. So (backend, mode) can be:
//   FTDI   + OPEN_DMX / ENTTEC_PRO   (D2XX)
//   LIBUSB + UDMX                    (uDMX control transfers)
//   LIBUSB + OPEN_DMX / ENTTEC_PRO   (raw FTDI over libusb)
class UsbDmxOutput : public RefCounted {
	GDCLASS(UsbDmxOutput, RefCounted)

public:
	enum Mode {
		MODE_AUTO = 0,       // guess from the device
		MODE_OPEN_DMX = 1,   // bare FTDI: generate BREAK + MAB, raw 250k 8N2
		MODE_ENTTEC_PRO = 2, // framed 0x7E .. 0xE7 message, MCU does the timing
		MODE_UDMX = 3,       // anyma uDMX: one vendor control transfer per frame
	};
	enum Backend { BACKEND_FTDI = 0, BACKEND_LIBUSB = 1 };

private:
	void *_handle = nullptr;     // FT_HANDLE (FTDI) or libusb_device_handle*
	int _backend = BACKEND_FTDI;
	std::atomic<int> _mode{MODE_OPEN_DMX};
	std::atomic<int> _fps{40};
	std::atomic<bool> _running{false};
	std::atomic<bool> _link_ok{false};
	std::thread _thread;

	std::mutex _buf_mtx;
	uint8_t _buf[512] = {0};

	std::mutex _status_mtx;
	String _status = "closed";

	void _set_status(const String &s);
	void _worker();
	void _start_worker();
	bool _write_open_dmx(const uint8_t *frame513);
	bool _write_enttec_pro(const uint8_t *frame513);
	bool _write_udmx(const uint8_t *frame513);
	bool _write_libftdi(const uint8_t *frame513, bool enttec_pro);
	bool _open_ftdi(const String &serial, int mode);
	bool _open_udmx(const String &serial);
	bool _open_libftdi(const String &serial, int mode);

protected:
	static void _bind_methods();

public:
	// True when *either* backend library (D2XX or libusb) is available.
	bool driver_available();

	// [{ serial:String, description:String, backend:int, guessed_mode:int }]
	TypedArray<Dictionary> list_devices();

	bool open(int device_index, int mode);
	bool open_serial(const String &serial, int mode);
	void close();
	bool is_open() const;

	void set_frame(const PackedByteArray &data);
	void blackout();

	void set_fps(int fps);
	int get_fps() const;
	String get_status();

	UsbDmxOutput();
	~UsbDmxOutput();
};

} // namespace godot

VARIANT_ENUM_CAST(godot::UsbDmxOutput::Mode);
VARIANT_ENUM_CAST(godot::UsbDmxOutput::Backend);

#endif // USB_DMX_OUTPUT_H
