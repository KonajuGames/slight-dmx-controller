#include "usb_dmx_output.h"
#include "ftd2xx_dyn.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <chrono>
#include <cstring>
#include <vector>

#if defined(_WIN32)
#include <windows.h>
#include <timeapi.h> // timeBeginPeriod / timeEndPeriod
#endif

using namespace godot;
using namespace std::chrono;

// ---- 1 ms timer resolution on Windows so the pacing sleep isn't ~15 ms --
namespace {
struct TimerRes {
	TimerRes() {
#if defined(_WIN32)
		timeBeginPeriod(1);
#endif
	}
	~TimerRes() {
#if defined(_WIN32)
		timeEndPeriod(1);
#endif
	}
} g_timer_res;

void sleep_until(steady_clock::time_point t) {
	auto now = steady_clock::now();
	if (t > now) {
		std::this_thread::sleep_for(t - now);
	}
}
} // namespace

// ---------------------------------------------------------------- bind --

void UsbDmxOutput::_bind_methods() {
	ClassDB::bind_method(D_METHOD("driver_available"), &UsbDmxOutput::driver_available);
	ClassDB::bind_method(D_METHOD("list_devices"), &UsbDmxOutput::list_devices);
	ClassDB::bind_method(D_METHOD("open", "device_index", "mode"), &UsbDmxOutput::open);
	ClassDB::bind_method(D_METHOD("open_serial", "serial", "mode"), &UsbDmxOutput::open_serial);
	ClassDB::bind_method(D_METHOD("close"), &UsbDmxOutput::close);
	ClassDB::bind_method(D_METHOD("is_open"), &UsbDmxOutput::is_open);
	ClassDB::bind_method(D_METHOD("set_frame", "data"), &UsbDmxOutput::set_frame);
	ClassDB::bind_method(D_METHOD("blackout"), &UsbDmxOutput::blackout);
	ClassDB::bind_method(D_METHOD("set_fps", "fps"), &UsbDmxOutput::set_fps);
	ClassDB::bind_method(D_METHOD("get_fps"), &UsbDmxOutput::get_fps);
	ClassDB::bind_method(D_METHOD("get_status"), &UsbDmxOutput::get_status);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "fps"), "set_fps", "get_fps");

	BIND_ENUM_CONSTANT(MODE_AUTO);
	BIND_ENUM_CONSTANT(MODE_OPEN_DMX);
	BIND_ENUM_CONSTANT(MODE_ENTTEC_PRO);
}

// --------------------------------------------------------------- setup --

UsbDmxOutput::UsbDmxOutput() {}

UsbDmxOutput::~UsbDmxOutput() {
	close();
}

void UsbDmxOutput::_set_status(const String &s) {
	std::lock_guard<std::mutex> lk(_status_mtx);
	_status = s;
}

String UsbDmxOutput::get_status() {
	std::lock_guard<std::mutex> lk(_status_mtx);
	return _status;
}

bool UsbDmxOutput::driver_available() {
	return usbdmx::ftdi().load();
}

TypedArray<Dictionary> UsbDmxOutput::list_devices() {
	TypedArray<Dictionary> out;
	usbdmx::Ftdi &f = usbdmx::ftdi();
	if (!f.load()) {
		return out;
	}
	usbdmx::FT_ULONG n = 0;
	if (f.CreateDeviceInfoList(&n) != 0 || n == 0) {
		return out;
	}
	std::vector<usbdmx::FT_DEVICE_LIST_INFO_NODE> nodes(n);
	if (f.GetDeviceInfoList(nodes.data(), &n) != 0) {
		return out;
	}
	for (usbdmx::FT_ULONG i = 0; i < n; i++) {
		String desc = String::utf8(nodes[i].Description);
		String serial = String::utf8(nodes[i].SerialNumber);
		if (serial.is_empty()) {
			continue; // already open elsewhere, or not addressable by serial
		}
		int guess = MODE_OPEN_DMX;
		String du = desc.to_upper();
		if (du.contains("PRO") || du.contains("DMXKING") || du.contains("ULTRADMX")) {
			guess = MODE_ENTTEC_PRO;
		}
		Dictionary d;
		d["index"] = (int)i;
		d["description"] = desc;
		d["serial"] = serial;
		d["guessed_mode"] = guess;
		out.push_back(d);
	}
	return out;
}

// ---------------------------------------------------------------- open --

bool UsbDmxOutput::open(int device_index, int mode) {
	TypedArray<Dictionary> devs = list_devices();
	for (int i = 0; i < devs.size(); i++) {
		Dictionary d = devs[i];
		if ((int)d["index"] == device_index) {
			String serial_str = d["serial"];
			return open_serial(serial_str, mode);
		}
	}
	_set_status("device not found");
	return false;
}

bool UsbDmxOutput::open_serial(const String &serial, int mode) {
	close();

	usbdmx::Ftdi &f = usbdmx::ftdi();
	if (!f.load()) {
		_set_status("FTDI driver not installed");
		return false;
	}

	CharString cs = serial.utf8();
	usbdmx::FT_HANDLE h = nullptr;
	// OpenEx takes a non-const pointer even for BY_SERIAL_NUMBER.
	if (f.OpenEx((void *)cs.get_data(), usbdmx::FT_OPEN_BY_SERIAL_NUMBER, &h) != 0 || h == nullptr) {
		_set_status("could not open " + serial);
		return false;
	}

	int m = mode;
	if (m == MODE_AUTO) {
		m = MODE_OPEN_DMX;
		TypedArray<Dictionary> devs = list_devices();
		for (int i = 0; i < devs.size(); i++) {
			Dictionary d = devs[i];
			String s = d["serial"];
			if (s == serial) {
				m = (int)d["guessed_mode"];
				break;
			}
		}
	}
	_mode.store(m);

	f.ResetDevice(h);
	f.SetUSBParameters(h, 4096, 4096);
	f.SetLatencyTimer(h, 1);
	f.SetFlowControl(h, usbdmx::FT_FLOW_NONE, 0, 0);
	if (m == MODE_OPEN_DMX) {
		f.SetBaudRate(h, 250000);
		f.SetDataCharacteristics(h, usbdmx::FT_BITS_8, usbdmx::FT_STOP_BITS_2, usbdmx::FT_PARITY_NONE);
		f.ClrRts(h);
		f.SetBreakOff(h);
	}
	f.Purge(h, usbdmx::FT_PURGE_RX | usbdmx::FT_PURGE_TX);

	_handle = h;
	_link_ok.store(true);
	_set_status(String(m == MODE_ENTTEC_PRO ? "open (Enttec Pro)" : "open (Open DMX)") + " — " + serial);

	_running.store(true);
	_thread = std::thread(&UsbDmxOutput::_worker, this);
	return true;
}

void UsbDmxOutput::close() {
	_running.store(false);
	if (_thread.joinable()) {
		_thread.join();
	}
	if (_handle) {
		usbdmx::ftdi().Close(_handle);
		_handle = nullptr;
	}
	_link_ok.store(false);
	_set_status("closed");
}

bool UsbDmxOutput::is_open() const {
	return _running.load() && _link_ok.load();
}

// --------------------------------------------------------------- frame --

void UsbDmxOutput::set_frame(const PackedByteArray &data) {
	std::lock_guard<std::mutex> lk(_buf_mtx);
	int n = data.size();
	if (n > 512) {
		n = 512;
	}
	for (int i = 0; i < n; i++) {
		_buf[i] = data[i];
	}
	for (int i = n; i < 512; i++) {
		_buf[i] = 0;
	}
}

void UsbDmxOutput::blackout() {
	std::lock_guard<std::mutex> lk(_buf_mtx);
	std::memset(_buf, 0, sizeof(_buf));
}

void UsbDmxOutput::set_fps(int fps) {
	_fps.store(fps < 1 ? 1 : (fps > 44 ? 44 : fps));
}

int UsbDmxOutput::get_fps() const {
	return _fps.load();
}

// -------------------------------------------------------------- worker --

void UsbDmxOutput::_worker() {
	auto next = steady_clock::now();
	while (_running.load()) {
		uint8_t frame[513];
		frame[0] = 0; // DMX start code
		{
			std::lock_guard<std::mutex> lk(_buf_mtx);
			std::memcpy(frame + 1, _buf, 512);
		}

		bool ok = (_mode.load() == MODE_ENTTEC_PRO)
				? _write_enttec_pro(frame)
				: _write_open_dmx(frame);
		if (!ok) {
			_link_ok.store(false);
			_set_status("write failed — device disconnected?");
			// keep the thread alive but idle; close() joins it
			std::this_thread::sleep_for(milliseconds(250));
			continue;
		}

		next += microseconds(1000000 / _fps.load());
		auto now = steady_clock::now();
		if (next < now) {
			next = now; // fell behind, don't spiral
		}
		sleep_until(next);
	}
}

bool UsbDmxOutput::_write_open_dmx(const uint8_t *frame513) {
	usbdmx::Ftdi &f = usbdmx::ftdi();
	// BREAK (>= 88 us; USB latency makes ours ~1 ms, which is legal) + MAB
	if (f.SetBreakOn(_handle) != 0) {
		return false;
	}
	std::this_thread::sleep_for(microseconds(120));
	if (f.SetBreakOff(_handle) != 0) {
		return false;
	}
	std::this_thread::sleep_for(microseconds(12));
	usbdmx::FT_ULONG wrote = 0;
	return f.Write(_handle, (void *)frame513, 513, &wrote) == 0 && wrote == 513;
}

bool UsbDmxOutput::_write_enttec_pro(const uint8_t *frame513) {
	// Enttec USB Pro "Send DMX Packet" (label 6): 0x7E 06 <len_lo> <len_hi>
	// <513 payload bytes> 0xE7. The Pro's MCU generates the DMX timing.
	static const int PAYLOAD = 513;
	static const int MSG_LEN = 4 + PAYLOAD + 1;
	uint8_t msg[MSG_LEN];
	msg[0] = 0x7E;
	msg[1] = 6;
	msg[2] = PAYLOAD & 0xFF;
	msg[3] = (PAYLOAD >> 8) & 0xFF;
	std::memcpy(msg + 4, frame513, PAYLOAD);
	msg[4 + PAYLOAD] = 0xE7;
	usbdmx::FT_ULONG wrote = 0;
	return usbdmx::ftdi().Write(_handle, msg, MSG_LEN, &wrote) == 0 && (int)wrote == MSG_LEN;
}
