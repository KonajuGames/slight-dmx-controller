# Vendored encoder headers (public domain, CC0)

- **minih264e.h** — https://github.com/lieff/minih264 — single-header
  H.264 baseline encoder. Unmodified.
- **minimp4.h** — https://github.com/lieff/minimp4 — single-header MP4
  muxer. **One local patch**: `#define MINIMP4_TRANSCODE_SPS_ID 1` (near
  the top) wrapped in `#ifndef` so `SConstruct`'s `-D…=0` can disable the
  SPS/PPS-id transcoder — its private `bs_t` / `h264e_bs_*` collide with
  minih264 when both live in one translation unit, and we feed a single
  encoder that already emits correct ids.

`LICENSE.CC0` is the shared CC0 1.0 text (identical in both repos).
