# usb_dmx — USB DMX output GDExtension

Adds a `UsbDmxOutput` class backed by the FTDI **D2XX** driver, so a
universe can be sent to a USB DMX interface instead of Art-Net:

- **Enttec DMX USB Pro** (and Mk2, DMXKing ultraDMX, …) — framed
  `0x7E … 0xE7` message, the interface's MCU generates the DMX timing.
- **Enttec Open DMX USB** (bare FT232) — the extension generates the
  BREAK / MAB and streams raw 250 k 8N2. Works, but USB latency makes the
  timing jittery; fine for LED fixtures, less so for movers.

The app runs fine without this built — the "USB DMX" output option is
just disabled and `UsbDmx.available` is `false`.

## Requirements

- **git**, **Python 3**, **SCons** (`pip install scons`)
- A C++ toolchain:
  - Windows: Visual Studio 2022 with **"Desktop development with C++"**
    (the MSVC compiler + Windows SDK). Build from a *Developer* prompt, or
    let SCons find MSVC automatically.
  - Linux: gcc or clang, `libdl` (standard)
  - macOS: Xcode command-line tools
- The FTDI **D2XX runtime** on the machine that *runs* the app
  (`ftd2xx.dll` / `libftd2xx.so` / `libftd2xx.dylib`). It ships with the
  FTDI "CDM" / D2XX driver package and is loaded at runtime — it is **not**
  needed to build. Get it from <https://ftdichip.com/drivers/d2xx-drivers/>.
  On Windows the Enttec/FTDI VCP driver install already places it in
  `System32`.

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

## API (from GDScript)

```gdscript
var out := UsbDmxOutput.new()
if out.driver_available():
    for d in out.list_devices():        # {index, description, serial, guessed_mode}
        print(d)
    out.open_serial(d.serial, UsbDmxOutput.MODE_AUTO)
    out.set_fps(40)
    out.set_frame(my_512_byte_PackedByteArray)   # call every tick
    ...
    out.close()
```

In this project the `UsbDmx` autoload wraps all of that; you just pick
**USB DMX** and a device in a universe's connection row.
