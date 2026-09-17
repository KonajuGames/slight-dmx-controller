# Vendored MP3 encoder (LGPL-2.0-only)

- **shine** — https://github.com/toots/shine (tag `3.1.1`), `src/lib/*`
  copied from this directory's `.c`/`.h` files. A small, fixed-point,
  real-time-capable MPEG-1 Layer III (MP3) encoder — used for `video_rec`'s
  optional audio track (see
  `../../src/video_rec/video_recorder.cpp`'s `start_audio()`/`push_audio()`).
  Public API: `layer3.h`. **One local patch**: `types.h` shims GCC's
  `__attribute__((unused))` (used on a couple of intentionally-unused
  variables in `l3subband.c`/`l3mdct.c`) to a no-op under MSVC, which has
  no such attribute and fails to parse it outright.

Unlike every other vendored library in this project (all public
domain/CC0/MIT), shine is **LGPL-2.0-only** — see `LICENSE.shine`. That's
compatible with statically linking it into `addons/native`'s GDExtension:
this repository already ships shine's full, unmodified source (satisfying
the "provide the source" term), and the whole GDExtension is built from
source by the end user via `addons/native/build.py` — there's no
pre-built-binary-only distribution to reconcile with the LGPL's
right-to-relink requirement.
