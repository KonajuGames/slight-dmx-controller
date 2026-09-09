#include "usb_dmx_output.h"
#include "ftd2xx_dyn.h"
#include "libusb_dyn.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <chrono>
#include <cstring>
#include <vector>

#if defined(_WIN32)
#include <windows.h>
#include <timeapi.h> // timeBeginPeriod / timeEndPeriod
#endif

using namespace godot;
using namespace std::chrono;

// anyma uDMX — shared "Free VID/PID" (16C0:05DC); confirm by product string.
static const uint16_t UDMX_VID = 0x16C0;
static const uint16_t UDMX_PID = 0x05DC;
static const uint8_t UDMX_CMD_SET_CHANNEL_RANGE = 2;

// Raw FTDI over libusb (no D2XX driver). Single-port FT232R / FT232BM /
// FT-X only — multi-port and FT232H go through D2XX.
static const uint16_t FTDI_VID = 0x0403;
static const uint8_t SIO_RESET = 0x00;
static const uint8_t SIO_SET_FLOW_CTRL = 0x02;
static const uint8_t SIO_SET_BAUDRATE = 0x03;
static const uint8_t SIO_SET_DATA = 0x04;
static const uint8_t SIO_SET_LATENCY = 0x09;
static const uint16_t FTDI_8N2 = 0x1008;       // 8 data bits, no parity, 2 stop
static const uint16_t FTDI_8N2_BREAK = 0x5008; // + break bit
static const uint16_t FTDI_BAUD_250K = 12;     // 3 MHz base / 12 = 250000
static const uint8_t FTDI_EP_OUT = 0x02;       // FT232 single-port bulk OUT

static bool ftdi_dmx_pid(uint16_t pid) {
	return pid == 0x6001 /* FT232AM/BM/R */ || pid == 0x6015 /* FT-X */;
}

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

String bus_addr_id(const char *prefix, usbdmx::Libusb &u, usbdmx::libusb_device *dev) {
	return String(prefix) + itos(u.get_bus_number(dev)) + ":" + itos(u.get_device_address(dev));
}

// Open the uDMX (udmx==true) or FTDI (false) device whose serial / bus:addr
// id matches `serial`. Caller closes the returned handle.
usbdmx::libusb_device_handle *find_libusb(bool udmx, const String &serial) {
	usbdmx::Libusb &u = usbdmx::libusb();
	usbdmx::libusb_device **list = nullptr;
	intptr_t n = u.get_device_list(u.ctx, &list);
	usbdmx::libusb_device_handle *found = nullptr;
	for (intptr_t i = 0; i < n && found == nullptr; i++) {
		usbdmx::libusb_device_descriptor desc;
		if (u.get_device_descriptor(list[i], &desc) != 0) {
			continue;
		}
		bool match = udmx ? (desc.idVendor == UDMX_VID && desc.idProduct == UDMX_PID)
						  : (desc.idVendor == FTDI_VID && ftdi_dmx_pid(desc.idProduct));
		if (!match) {
			continue;
		}
		usbdmx::libusb_device_handle *th = nullptr;
		if (u.open(list[i], &th) != 0 || th == nullptr) {
			continue;
		}
		unsigned char ser[256] = {0};
		if (desc.iSerialNumber) {
			u.get_string_descriptor_ascii(th, desc.iSerialNumber, ser, sizeof(ser));
		}
		String cand = String::utf8((const char *)ser);
		if (cand.is_empty()) {
			cand = bus_addr_id(udmx ? "udmx:" : "ftdi:", u, list[i]);
		}
		if (cand == serial) {
			found = th;
		} else {
			u.close(th);
		}
	}
	if (list) {
		u.free_device_list(list, 1);
	}
	return found;
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
	BIND_ENUM_CONSTANT(MODE_UDMX);
	BIND_ENUM_CONSTANT(BACKEND_FTDI);
	BIND_ENUM_CONSTANT(BACKEND_LIBUSB);
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
	return usbdmx::ftdi().load() || usbdmx::libusb().load();
}

void UsbDmxOutput::_start_worker() {
	_running.store(true);
	_thread = std::thread(&UsbDmxOutput::_worker, this);
}

// --------------------------------------------------------- enumeration --

TypedArray<Dictionary> UsbDmxOutput::list_devices() {
	TypedArray<Dictionary> out;

	// --- FTDI (D2XX): Open DMX, Enttec Pro, DMXKing ---
	usbdmx::Ftdi &f = usbdmx::ftdi();
	if (f.load()) {
		usbdmx::FT_ULONG n = 0;
		if (f.CreateDeviceInfoList(&n) == 0 && n > 0) {
			std::vector<usbdmx::FT_DEVICE_LIST_INFO_NODE> nodes(n);
			if (f.GetDeviceInfoList(nodes.data(), &n) == 0) {
				for (usbdmx::FT_ULONG i = 0; i < n; i++) {
					String desc = String::utf8(nodes[i].Description);
					String serial = String::utf8(nodes[i].SerialNumber);
					if (serial.is_empty()) {
						continue;
					}
					int guess = MODE_OPEN_DMX;
					String du = desc.to_upper();
					if (du.contains("PRO") || du.contains("DMXKING") || du.contains("ULTRADMX")) {
						guess = MODE_ENTTEC_PRO;
					}
					Dictionary d;
					d["serial"] = serial;
					d["description"] = desc;
					d["backend"] = (int)BACKEND_FTDI;
					d["guessed_mode"] = guess;
					out.push_back(d);
				}
			}
		}
	}

	// --- libusb: anyma uDMX, plus raw FTDI when D2XX isn't available ---
	usbdmx::Libusb &u = usbdmx::libusb();
	bool have_d2xx = f.ok;
	if (u.load()) {
		usbdmx::libusb_device **list = nullptr;
		intptr_t n = u.get_device_list(u.ctx, &list);
		for (intptr_t i = 0; i < n; i++) {
			usbdmx::libusb_device_descriptor desc;
			if (u.get_device_descriptor(list[i], &desc) != 0) {
				continue;
			}
			bool is_udmx = desc.idVendor == UDMX_VID && desc.idProduct == UDMX_PID;
			bool is_ftdi = !have_d2xx && desc.idVendor == FTDI_VID && ftdi_dmx_pid(desc.idProduct);
			if (!is_udmx && !is_ftdi) {
				continue;
			}

			unsigned char prod[256] = {0};
			unsigned char ser[256] = {0};
			bool opened = false;
			usbdmx::libusb_device_handle *h = nullptr;
			if (u.open(list[i], &h) == 0 && h) {
				opened = true;
				if (desc.iProduct) {
					u.get_string_descriptor_ascii(h, desc.iProduct, prod, sizeof(prod));
				}
				if (desc.iSerialNumber) {
					u.get_string_descriptor_ascii(h, desc.iSerialNumber, ser, sizeof(ser));
				}
				u.close(h);
			}
			String product = String::utf8((const char *)prod);
			String serial = String::utf8((const char *)ser);

			Dictionary d;
			d["backend"] = (int)BACKEND_LIBUSB;
			if (is_udmx) {
				if (opened && !product.to_upper().contains("UDMX")) {
					continue; // a different 16C0:05DC device
				}
				d["guessed_mode"] = (int)MODE_UDMX;
				d["serial"] = serial.is_empty() ? bus_addr_id("udmx:", u, list[i]) : serial;
				d["description"] = opened ? (product.is_empty() ? String("uDMX") : product)
										  : String("uDMX? (needs a libusb / WinUSB driver)");
			} else { // raw FTDI over libusb
				String du = product.to_upper();
				d["guessed_mode"] = (du.contains("PRO") ? (int)MODE_ENTTEC_PRO : (int)MODE_OPEN_DMX);
				d["serial"] = serial.is_empty() ? bus_addr_id("ftdi:", u, list[i]) : serial;
				d["description"] = (opened && !product.is_empty() ? product : String("FTDI")) + " (libusb)";
			}
			out.push_back(d);
		}
		if (list) {
			u.free_device_list(list, 1);
		}
	}

	return out;
}

// ---------------------------------------------------------------- open --

bool UsbDmxOutput::open(int device_index, int mode) {
	TypedArray<Dictionary> devs = list_devices();
	if (device_index >= 0 && device_index < devs.size()) {
		String serial_str = Dictionary(devs[device_index])["serial"];
		return open_serial(serial_str, mode);
	}
	_set_status("device not found");
	return false;
}

bool UsbDmxOutput::open_serial(const String &serial, int mode) {
	close();

	int be = BACKEND_FTDI;
	int guess = MODE_OPEN_DMX;
	TypedArray<Dictionary> devs = list_devices();
	for (int i = 0; i < devs.size(); i++) {
		Dictionary d = devs[i];
		if (String(d["serial"]) == serial) {
			be = (int)d["backend"];
			guess = (int)d["guessed_mode"];
			break;
		}
	}
	int m = (mode == MODE_AUTO) ? guess : mode;
	if (be == BACKEND_LIBUSB) {
		if (m == MODE_UDMX) {
			return _open_udmx(serial);
		}
		return _open_libftdi(serial, m); // raw FTDI over libusb
	}
	return _open_ftdi(serial, m); // FTDI D2XX
}

bool UsbDmxOutput::_open_ftdi(const String &serial, int mode) {
	usbdmx::Ftdi &f = usbdmx::ftdi();
	if (!f.load()) {
		_set_status("FTDI D2XX driver not installed");
		return false;
	}

	CharString cs = serial.utf8();
	usbdmx::FT_HANDLE h = nullptr;
	if (f.OpenEx((void *)cs.get_data(), usbdmx::FT_OPEN_BY_SERIAL_NUMBER, &h) != 0 || h == nullptr) {
		_set_status("could not open " + serial);
		return false;
	}

	int m = (mode == MODE_UDMX || mode == MODE_AUTO) ? MODE_OPEN_DMX : mode;
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
	_backend = BACKEND_FTDI;
	_link_ok.store(true);
	_set_status(String(m == MODE_ENTTEC_PRO ? "open (Enttec Pro)" : "open (Open DMX)") + " — " + serial);
	_start_worker();
	return true;
}

bool UsbDmxOutput::_open_udmx(const String &serial) {
	usbdmx::Libusb &u = usbdmx::libusb();
	if (!u.load()) {
		_set_status("libusb not installed");
		return false;
	}
	usbdmx::libusb_device_handle *h = find_libusb(true, serial);
	if (h == nullptr) {
		_set_status("could not open " + serial);
		return false;
	}
	if (u.set_auto_detach_kernel_driver) {
		u.set_auto_detach_kernel_driver(h, 1);
	}
	u.claim_interface(h, 0); // best effort — uDMX only has EP0

	_handle = h;
	_backend = BACKEND_LIBUSB;
	_mode.store(MODE_UDMX);
	_link_ok.store(true);
	_set_status("open (uDMX) — " + serial);
	_start_worker();
	return true;
}

bool UsbDmxOutput::_open_libftdi(const String &serial, int mode) {
	usbdmx::Libusb &u = usbdmx::libusb();
	if (!u.load()) {
		_set_status("libusb not installed");
		return false;
	}
	usbdmx::libusb_device_handle *h = find_libusb(false, serial);
	if (h == nullptr) {
		_set_status("could not open " + serial);
		return false;
	}
	if (u.set_auto_detach_kernel_driver) {
		u.set_auto_detach_kernel_driver(h, 1);
	}
	if (u.set_configuration) {
		u.set_configuration(h, 1); // best effort
	}
	if (u.claim_interface(h, 0) != 0) {
		u.close(h);
		_set_status("could not claim " + serial + " (libusb / WinUSB driver bound?)");
		return false;
	}

	int m = (mode == MODE_ENTTEC_PRO) ? MODE_ENTTEC_PRO : MODE_OPEN_DMX;
	// FT232 vendor setup (reset, no flow control, latency). Open DMX also
	// needs 250k 8N2; an Enttec Pro's PIC does its own timing so skip that.
	u.control_transfer(h, 0x40, SIO_RESET, 0, 0, nullptr, 0, 100);
	u.control_transfer(h, 0x40, SIO_SET_FLOW_CTRL, 0, 0, nullptr, 0, 100);
	if (m == MODE_OPEN_DMX) {
		u.control_transfer(h, 0x40, SIO_SET_BAUDRATE, FTDI_BAUD_250K, 0, nullptr, 0, 100);
		u.control_transfer(h, 0x40, SIO_SET_DATA, FTDI_8N2, 0, nullptr, 0, 100);
	}
	u.control_transfer(h, 0x40, SIO_SET_LATENCY, 1, 0, nullptr, 0, 100);
	u.control_transfer(h, 0x40, SIO_RESET, 1, 0, nullptr, 0, 100); // purge RX
	u.control_transfer(h, 0x40, SIO_RESET, 2, 0, nullptr, 0, 100); // purge TX

	_handle = h;
	_backend = BACKEND_LIBUSB;
	_mode.store(m);
	_link_ok.store(true);
	_set_status(String(m == MODE_ENTTEC_PRO ? "open (Enttec Pro, libusb)" : "open (Open DMX, libusb)") + " — " + serial);
	_start_worker();
	return true;
}

void UsbDmxOutput::close() {
	_running.store(false);
	if (_thread.joinable()) {
		_thread.join();
	}
	if (_handle) {
		if (_backend == BACKEND_LIBUSB) {
			usbdmx::Libusb &u = usbdmx::libusb();
			if (u.ok) {
				u.release_interface((usbdmx::libusb_device_handle *)_handle, 0);
				u.close((usbdmx::libusb_device_handle *)_handle);
			}
		} else {
			usbdmx::ftdi().Close(_handle);
		}
		_handle = nullptr;
	}
	_backend = BACKEND_FTDI;
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

		int m = _mode.load();
		bool ok;
		if (m == MODE_UDMX) {
			ok = _write_udmx(frame);
		} else if (_backend == BACKEND_LIBUSB) {
			ok = _write_libftdi(frame, m == MODE_ENTTEC_PRO); // raw FTDI over libusb
		} else if (m == MODE_ENTTEC_PRO) {
			ok = _write_enttec_pro(frame);
		} else {
			ok = _write_open_dmx(frame);
		}
		if (!ok) {
			_link_ok.store(false);
			_set_status("write failed — device disconnected?");
			std::this_thread::sleep_for(milliseconds(250));
			continue;
		}

		next += microseconds(1000000 / _fps.load());
		auto now = steady_clock::now();
		if (next < now) {
			next = now; // fell behind (uDMX EP0 is slow) — don't spiral
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

bool UsbDmxOutput::_write_udmx(const uint8_t *frame513) {
	// uDMX SetChannelRange: bmRequestType = vendor|host-to-device|device,
	// wValue = channel count, wIndex = first channel, data = the values
	// (no start code). One control transfer per frame — EP0 is slow, so
	// the effective refresh rate is ~20-25 Hz for a full universe.
	const uint16_t count = 512;
	int r = usbdmx::libusb().control_transfer(
			(usbdmx::libusb_device_handle *)_handle,
			0x40, UDMX_CMD_SET_CHANNEL_RANGE, count, 0,
			(unsigned char *)(frame513 + 1), count, 250);
	return r >= 0;
}

// Raw FTDI over libusb: the same wire format as the D2XX paths, but the
// BREAK is a SIO_SET_DATA control transfer and the frame goes out on the
// bulk endpoint.
bool UsbDmxOutput::_write_libftdi(const uint8_t *frame513, bool enttec_pro) {
	usbdmx::Libusb &u = usbdmx::libusb();
	usbdmx::libusb_device_handle *h = (usbdmx::libusb_device_handle *)_handle;
	int tr = 0;

	if (enttec_pro) {
		static const int PAYLOAD = 513;
		static const int MSG_LEN = 4 + PAYLOAD + 1;
		uint8_t msg[MSG_LEN];
		msg[0] = 0x7E;
		msg[1] = 6;
		msg[2] = PAYLOAD & 0xFF;
		msg[3] = (PAYLOAD >> 8) & 0xFF;
		std::memcpy(msg + 4, frame513, PAYLOAD);
		msg[4 + PAYLOAD] = 0xE7;
		return u.bulk_transfer(h, FTDI_EP_OUT, msg, MSG_LEN, &tr, 250) == 0 && tr == MSG_LEN;
	}

	// Open DMX: BREAK, MAB, then the 513-byte frame.
	if (u.control_transfer(h, 0x40, SIO_SET_DATA, FTDI_8N2_BREAK, 0, nullptr, 0, 100) < 0) {
		return false;
	}
	std::this_thread::sleep_for(microseconds(120));
	if (u.control_transfer(h, 0x40, SIO_SET_DATA, FTDI_8N2, 0, nullptr, 0, 100) < 0) {
		return false;
	}
	std::this_thread::sleep_for(microseconds(12));
	return u.bulk_transfer(h, FTDI_EP_OUT, (unsigned char *)frame513, 513, &tr, 250) == 0 && tr == 513;
}
