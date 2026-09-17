# native — bundled optional-features GDExtension

One GDExtension bundling every optional native feature the app can use, so
an exported build only ships a single shared library instead of one per
feature:

- **USB DMX output** (`UsbDmxOutput`) — send a universe to a USB DMX
  interface instead of Art-Net. Two backends, both loaded at run time
  (dynamically — neither is needed to *build*):
  - **FTDI D2XX** (`ftd2xx.dll` / `libftd2xx.so` / `.dylib`) — Enttec DMX
    USB Pro / Mk2 / DMXKing ultraDMX (framed, MCU-timed) and Enttec Open
    DMX USB (bare FT232, extension-generated timing).
  - **libusb** (`libusb-1.0.dll` / `libusb-1.0.so.0` / `.dylib`) — anyma
    uDMX (one control transfer per frame, ~20-25 Hz), and raw FTDI as a
    fallback when D2XX isn't present (needs a libusb-compatible driver:
    kernel driver on Linux, WinUSB via Zadig on Windows).
  - Devices from whichever backends are present are enumerated in one
    list. `UsbDmx.available` is `false` and the USB DMX output option is
    greyed out until both this extension is built *and* one of the above
    is installed on the machine that *runs* the app.

- **In-app H.264/MP4 recording** (`VideoRecorder`) — the visualizer's
  **Record** button encodes an RGBA8 frame stream straight to `.mp4`, no
  FFmpeg. Encoder: **minih264** (software H.264 baseline) + **minimp4**
  (muxer), single-header, public domain (CC0), vendored under
  `third_party/video_rec/`. Without this component built, Record falls
  back to a PNG sequence + an `assemble.txt` ffmpeg one-liner.

- **Fast song analysis** (`SongFeatures`) — decodes a music file (MP3 /
  OGG / WAV) straight to PCM and runs the STFT chroma/timbre frames, onset
  envelope, and whole-song waveform in C++ on a worker thread (a few
  seconds total). `SongAnalyzer` (GDScript) uses it when present; without
  it, analysis falls back to playing the track 4× through a muted
  `AudioEffectCapture` bus and running the STFT in GDScript (~60s+).
  Decoders: **minimp3** (MP3) and **stb_vorbis** (Ogg), single-file public
  domain, vendored under `third_party/song_dsp/`; WAV is parsed directly.

- **Native MIDI output** (`MidiOutput`) — MIDI **feedback** (lighting a
  controller's pad LEDs) goes straight to a real MIDI port instead of over
  UDP to `tools/midi_bridge.py`. Godot's built-in MIDI support
  (`OS.open_midi_inputs()` / `InputEventMIDI`) is input-only; this fills in
  the missing output half via [RtMidi](https://github.com/thestk/rtmidi)
  (vendored in `src/midi_out/RtMidi.h` / `.cpp`, MIT-style license — see
  `src/midi_out/RTMIDI_LICENSE.txt`). Unlike USB DMX, there's **no
  separate runtime driver to install** — RtMidi's backend on each platform
  is a native OS API that ships with the OS itself (WinMM on Windows,
  CoreMIDI on macOS, ALSA on Linux) — so once built, it just works
  everywhere. Without it, MIDI feedback falls back to the
  `tools/midi_bridge.py` UDP path.

The app runs fine with none of this built — every feature above checks
`ClassDB.class_exists(...)` and no-ops cleanly (see `usb_dmx_bridge.gd`,
`video_rec.gd`, `song_analyzer.gd`, `midi_out_bridge.gd`).

## Requirements

- **git**, **Python 3**, **SCons** (`pip install scons`)
- A C++ toolchain:
  - Windows: Visual Studio 2022 with **"Desktop development with C++"**
    (the MSVC compiler + Windows SDK). Build from a *Developer* prompt, or
    let SCons find MSVC automatically.
  - Linux: gcc or clang, ALSA dev headers (`libasound2-dev` /
    `alsa-lib-devel`), pthreads (standard)
  - macOS: Xcode command-line tools
- Nothing extra at run time for video/audio/MIDI — those are compiled in.
  USB DMX output additionally needs FTDI D2XX or libusb-1.0 present on the
  machine that *runs* the app (see above); that's the only run-time
  dependency of anything in this extension.

## Build

```
python addons/native/build.py
```

This clones `godot-cpp` (branch 4.5 by default) into `addons/native/godot-cpp`
on first run, builds `template_debug` and `template_release` into
`addons/native/bin/`, then copies `native.gdextension.disabled` to
`native.gdextension` to switch it on. Re-open the Godot project.

**The first build compiles all of godot-cpp — 15-20 minutes.** After that
it's cached; rebuilding just this extension takes seconds. `template_debug`
is what the editor and a debug export use; `template_release` is for
release exports.

Manual equivalent:

```
git clone --depth 1 --branch 4.5 https://github.com/godotengine/godot-cpp addons/native/godot-cpp
cd addons/native
python -m SCons platform=windows target=template_debug
python -m SCons platform=windows target=template_release
cp native.gdextension.disabled native.gdextension
```

The extension ships **disabled** (`native.gdextension.disabled`) so an
unbuilt checkout doesn't spew "GDExtension dynamic library not found".
Every feature it provides is independently optional at run time too — see
above.

## Windows: which USB DMX driver?

- **Enttec DMX USB Pro** and most "pro" boxes expose a VCP *and* work
  through D2XX with the stock FTDI driver — no Zadig needed.
- **Open DMX USB** also works through D2XX with the stock driver. Do **not**
  swap it to WinUSB with Zadig; that breaks D2XX.
- **uDMX** needs a WinUSB / libusb driver (its own installer, or Zadig).
  That's separate from the FTDI devices above.

## API (from GDScript)

```gdscript
# USB DMX
var out := UsbDmxOutput.new()
if out.driver_available():
    for d in out.list_devices():   # {serial, description, backend, guessed_mode}
        print(d)
    out.open_serial(d.serial, UsbDmxOutput.MODE_AUTO)
    out.set_fps(40)
    out.set_frame(my_512_byte_PackedByteArray)   # call every tick
    out.close()

# Video recording
var rec := VideoRecorder.new()
rec.start("C:/clips/show.mp4", 1920, 1080, 30, 12000)   # w, h, fps, kbps
rec.push_frame(img.get_data())   # each frame, from an RGBA8 image
rec.stop()                       # finalises the moov atom; check rec.get_status()

# Song analysis
var sf := SongFeatures.new()
var d: Dictionary = sf.analyze_file("C:/music/track.mp3", 2048, 1024, 1024)
if d.ok:
    d.rate; d.duration; d.nframes
    d.chroma            # PackedFloat32Array, nframes*12 row-major
    d.rms; d.centroid; d.flux; d.onset; d.onset_hz
    d.wave_lo; d.wave_mid; d.wave_hi; d.wave_peak

# MIDI output
var midi := MidiOutput.new()
if midi.driver_available():
    for name in midi.list_ports():
        print(name)
    midi.open_port_by_name("Launchpad")   # first port whose name contains this
    midi.send(0x90, 60, 127)              # note on, channel 1, note 60, velocity 127
    midi.close()
```

In this project, the `UsbDmx`, `VideoRec`/`video_rec.gd`, `SongAnalyzer`,
and `MidiOut` wrappers handle all of the above — you just use the app
normally; each falls back gracefully when this extension isn't built.
