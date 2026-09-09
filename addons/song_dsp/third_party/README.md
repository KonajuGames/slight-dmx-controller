# Vendored audio decoders (public domain)

Used only by the `song_dsp` GDExtension to decode a music file straight to
PCM so `SongAnalyzer` can analyse it without the 4× muted-playback capture.

- **minimp3.h** / **minimp3_ex.h** — https://github.com/lieff/minimp3 —
  single-header MP3 decoder. CC0. Unmodified. Built with
  `MINIMP3_FLOAT_OUTPUT` and `MINIMP3_NO_STDIO` (buffer decode only, no
  file I/O). `LICENSE.minimp3` is the CC0 text.
- **stb_vorbis.c** — https://github.com/nothings/stb — Ogg Vorbis decoder.
  Public domain / MIT. Unmodified. Built with `STB_VORBIS_NO_STDIO` +
  `STB_VORBIS_NO_PUSHDATA_API`. `LICENSE.stb` is the dual-license text
  from the file's own trailer.

Each decoder is compiled in its own C translation unit (`dec_mp3.c`,
`dec_ogg.c`) so their macros never meet. WAV is parsed directly in
`dec_wav.c` — no library needed.
