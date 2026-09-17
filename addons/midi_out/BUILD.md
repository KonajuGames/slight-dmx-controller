# midi_out — native MIDI output GDExtension

Adds a `MidiOutput` class so MIDI **feedback** (lighting a controller's
pad LEDs) can go straight to a real MIDI port instead of over UDP to
`tools/midi_bridge.py`. Godot's built-in MIDI support
(`OS.open_midi_inputs()` / `InputEventMIDI`) is input-only — this fills
in the missing output half, via [RtMidi](https://github.com/thestk/rtmidi)
(vendored in `src/RtMidi.h` / `src/RtMidi.cpp`, MIT-style license — see
`src/RTMIDI_LICENSE.txt`).

Unlike `usb_dmx` (FTDI D2XX / libusb), there's **no separate runtime
driver to install**: RtMidi's backend for each platform is a native OS
API that ships with the OS itself —

- **Windows** — WinMM (`winmm.dll`, always present)
- **macOS** — CoreMIDI (framework, always present)
- **Linux** — ALSA (`libasound`, present on essentially every desktop
  install; install `libasound2`/`alsa-lib` if it's somehow missing)

So once this extension is *built*, it works on any machine that can run
the app at all — nothing extra to install on the machine that runs it,
unlike USB DMX.

## Requirements (to build)

- **git**, **Python 3**, **SCons** (`pip install scons`)
- A C++ toolchain:
  - Windows: Visual Studio 2022 with **"Desktop development with C++"**
  - Linux: gcc or clang, ALSA dev headers (`libasound2-dev` / `alsa-lib-devel`)
  - macOS: Xcode command-line tools

## Build

```
python addons/midi_out/build.py
```

Reuses `addons/usb_dmx/godot-cpp` if you've already built that extension
(a fast local copy instead of a full clone); otherwise clones godot-cpp
fresh (~15-20 minutes, one-time). Builds `template_debug` and
`template_release` into `addons/midi_out/bin/`, then activates
`midi_out.gdextension` (copied from `.disabled`). Re-open the Godot
project afterwards.

The extension ships **disabled** so an unbuilt checkout doesn't spew
"GDExtension dynamic library not found" — the app already treats it as
optional (`MidiOut.available` stays `false` and MIDI feedback falls back
to the `tools/midi_bridge.py` UDP path, same as before this extension
existed).

## API (from GDScript)

```gdscript
var out := MidiOutput.new()
if out.driver_available():
    for name in out.list_ports():
        print(name)
    out.open_port_by_name("Launchpad")   # first port whose name contains this (case-insensitive)
    out.send(0x90, 60, 127)              # note on, channel 1, note 60, velocity 127
    ...
    out.close()
```

In this project the `MidiOut` autoload (`midi_out_bridge.gd`) wraps all
of that; the Triggers dialog's Feedback row shows a MIDI output **port
picker** once this extension is built, instead of the UDP "MIDI ->
bridge" port field.
