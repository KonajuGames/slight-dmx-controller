# video_rec — in-app H.264 / MP4 recorder GDExtension

Adds a `VideoRecorder` class that encodes an RGBA8 frame stream straight
to an `.mp4` (H.264 baseline) — no FFmpeg, no external tools. The
visualizer's **Record** button uses it; without the extension built,
Record falls back to writing a PNG sequence + an `assemble.txt`.

Encoder: **minih264** (software H.264 baseline) + **minimp4** (MP4
muxer). Both are single-header, public domain (CC0), vendored in
`third_party/` — no download step for them.

## Requirements

- **git**, **Python 3**, **SCons** (`pip install scons`)
- A C++ toolchain — Windows: Visual Studio with "Desktop development with
  C++"; Linux: gcc/clang + pthreads; macOS: Xcode CLT.
- Nothing at run time — the encoder is compiled in.

## Build

```
python addons/video_rec/build.py
```

Clones its own `godot-cpp` into `addons/video_rec/godot-cpp` (copied from
`addons/usb_dmx/godot-cpp` if that exists, so no re-download — but still
a full ~15-20 min first compile; SCons's signature DB is per-build so a
shared checkout gets rebuilt anyway). Then activates
`video_rec.gdextension`. Manual:

```
git clone --depth 1 --branch 4.5 https://github.com/godotengine/godot-cpp addons/video_rec/godot-cpp
cd addons/video_rec
python -m SCons godot_cpp=godot-cpp platform=windows target=template_debug
python -m SCons godot_cpp=godot-cpp platform=windows target=template_release
cp video_rec.gdextension.disabled video_rec.gdextension
```

Ships **disabled** so an unbuilt checkout doesn't error.

## API

```gdscript
var rec := VideoRecorder.new()
rec.start("C:/clips/show.mp4", 1920, 1080, 30, 12000)   # w, h, fps, kbps
# each frame, from an RGBA8 image:
rec.push_frame(img.get_data())
...
rec.stop()          # finalises the moov atom; check rec.get_status()
```

- Width / height are rounded down to even. Software encoder — `encode_speed`
  is fixed fast; ~1080p30 keeps up on a modern CPU, higher may drop frames
  (`get_dropped()`).
- Video only — no audio track yet.
