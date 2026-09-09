# usb_dmx — USB DMX output GDExtension

Adds a `UsbDmxOutput` class so a universe can be sent to a USB DMX
interface instead of Art-Net. Two backends, both loaded at run time
(dynamically — neither is needed to *build*):

**FTDI D2XX** (`ftd2xx.dll` / `libftd2xx.so` / `.dylib`):
- **Enttec DMX USB Pro** (and Mk2, DMXKing ultraDMX, …) — framed
  `0x7E … 0xE7` message, the interface's MCU generates the DMX timing.
- **Enttec Open DMX USB** (bare FT232) — the extension generates the
  BREAK / MAB and streams raw 250 k 8N2. Works, but USB latency makes the
  timing jittery; fine for LED fixtures, less so for movers.

**libusb** (`libusb-1.0.dll` / `libusb-1.0.so.0` / `.dylib`):
- **anyma uDMX** — one vendor control transfer per frame. EP0 is slow, so
  a full universe refreshes at ~20-25 Hz.
- **Raw FTDI** — the FT232 vendor requests (baud / line / BREAK) + a bulk
  write, i.e. the Open DMX / Enttec Pro protocols without the D2XX driver.
  Single-port FT232R / FT232BM / FT-X only. **Only listed when D2XX is not
  available** — on Linux / macOS without `libftd2xx`, this is the FTDI
  path. Needs the device bound to a libusb-compatible driver (libusb
  kernel driver on Linux; WinUSB via Zadig on Windows).

Devices are enumerated from whichever backends are present and shown in
one list. The app runs fine without the extension built — the "USB DMX"
output option is disabled and `UsbDmx.available` is `false`.

## Requirements

- **git**, **Python 3**, **SCons** (`pip install scons`)
- A C++ toolchain:
  - Windows: Visual Studio 2022 with **"Desktop development with C++"**
    (the MSVC compiler + Windows SDK). Build from a *Developer* prompt, or
    let SCons find MSVC automatically.
  - Linux: gcc or clang, `libdl` (standard)
  - macOS: Xcode command-line tools
- On the machine that *runs* the app, at least one backend library:
  - FTDI **D2XX** (`ftd2xx.dll` / `libftd2xx.*`) — ships with the FTDI
    "CDM" / D2XX or Enttec driver; on Windows the VCP driver install puts
    it in `System32`. <https://ftdichip.com/drivers/d2xx-drivers/>
  - **libusb-1.0** — from the OS package manager, or bundled with the
    uDMX driver on Windows. Only needed for uDMX.
  Neither is needed to build.

## Build

```
python addons/usb_dmx/build.py
```

This clones `godot-cpp` (branch 4.5 by default) into `addons/usb_dmx/godot-cpp`
on first run, builds `template_debug` and `template_release` into
`addons/usb_dmx/bin/`, then copies `usb_dmx.gdextension.disabled` to
`usb_dmx.gdextension` to switch it on. Re-open the Godot project.

**The first build compiles all of godot-cpp — 15-20 minutes.** After that
it's cached; rebuilding just this extension takes seconds. `template_debug`
is what the editor and a debug export use; `template_release` is for
release exports.

Manual equivalent:

```
git clone --depth 1 --branch 4.5 https://github.com/godotengine/godot-cpp addons/usb_dmx/godot-cpp
cd addons/usb_dmx
python -m SCons platform=windows target=template_debug
python -m SCons platform=windows target=template_release
cp usb_dmx.gdextension.disabled usb_dmx.gdextension
```

The extension ships **disabled** (`usb_dmx.gdextension.disabled`) so an
unbuilt checkout doesn't spew "GDExtension dynamic library not found".
The app already treats it as optional — `UsbDmx.available` stays `false`
and the USB output choice is greyed out.

## Windows: which driver?

- **Enttec DMX USB Pro** and most "pro" boxes expose a VCP *and* work
  through D2XX with the stock FTDI driver — no Zadig needed.
- **Open DMX USB** also works through D2XX with the stock driver. Do **not**
  swap it to WinUSB with Zadig; that breaks D2XX.
- **uDMX** needs a WinUSB / libusb driver (its own installer, or Zadig).
  That's separate from the FTDI devices above.

## API (from GDScript)

```gdscript
var out := UsbDmxOutput.new()
if out.driver_available():
    for d in out.list_devices():   # {serial, description, backend, guessed_mode}
        print(d)
    out.open_serial(d.serial, UsbDmxOutput.MODE_AUTO)
    out.set_fps(40)
    out.set_frame(my_512_byte_PackedByteArray)   # call every tick
    ...
    out.close()
```

In this project the `UsbDmx` autoload wraps all of that; you just pick
**USB DMX** and a device in a universe's connection row.
