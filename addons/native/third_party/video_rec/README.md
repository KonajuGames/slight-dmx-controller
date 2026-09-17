# Vendored encoder headers (public domain, CC0)

- **minih264e.h** — https://github.com/lieff/minih264 — single-header
  H.264 baseline encoder. Unmodified.
- **minimp4.h** — https://github.com/lieff/minimp4 — single-header MP4
  muxer. **Two local patches**:
  1. `#define MINIMP4_TRANSCODE_SPS_ID 1` (near the top) wrapped in
     `#ifndef` so `SConstruct`'s `-D…=0` can disable the SPS/PPS-id
     transcoder — its private `bs_t` / `h264e_bs_*` collide with minih264
     when both live in one translation unit, and we feed a single encoder
     that already emits correct ids.
  2. The esds writer (used when `MP4E_set_dsi()` was called on an audio
     track) hardcoded `MP4_OBJECT_TYPE_AUDIO_ISO_IEC_14496_3` (AAC) as the
     DecoderConfigDescriptor's objectTypeIndication, regardless of the
     track's own `object_type_indication` — harmless for this library's
     original AAC-only use, but wrong for `video_rec`'s MP3 (shine) audio
     track: every player correctly refused to decode MP3 bytes tagged as
     AAC. Now writes `tr->info.object_type_indication` instead. See
     `video_recorder.cpp`'s `start_audio()` for the MP3 side of this (it
     calls `MP4E_set_dsi()` with an empty payload — just to make this
     write path run at all — since MP3 has no AAC-style
     decoder-specific-info to carry).

`LICENSE.CC0` is the shared CC0 1.0 text (identical in both repos).
