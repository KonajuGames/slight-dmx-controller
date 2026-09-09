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

// One open FTDI DMX interface. Holds a 512-byte frame buffer that a
// background thread streams to the hardware at a fixed refresh rate.
// `set_frame()` is the only thing the game calls per tick.
class UsbDmxOutput : public RefCounted {
	GDCLASS(UsbDmxOutput, RefCounted)

public:
	enum Mode {
		MODE_AUTO = 0,      // guess from the device description
		MODE_OPEN_DMX = 1,  // bare FTDI: generate BREAK + MAB, raw 250k 8N2
		MODE_ENTTEC_PRO = 2 // framed 0x7E .. 0xE7 message, MCU does the timing
	};

private:
	void *_handle = nullptr;
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
	bool _write_open_dmx(const uint8_t *frame513);
	bool _write_enttec_pro(const uint8_t *frame513);

protected:
	static void _bind_methods();

public:
	// True when the D2XX library could be loaded on this machine.
	bool driver_available();

	// [{ index:int, description:String, serial:String, guessed_mode:int }]
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

#endif // USB_DMX_OUTPUT_H
