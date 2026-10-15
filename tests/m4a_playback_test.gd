extends SceneTree
## Tests for playing M4A / AAC: SongFeatures.decode_pcm16 (the native
## extension) and SongAnalyzer.decode_os_stream / load_stream.
##
##   godot --headless --script tests/m4a_playback_test.gd
##
## Synthetic WAVs exercise decode_pcm16 anywhere the extension is built;
## the M4A cases use a real file from this machine's library and SKIP when
## it (or an OS AAC decoder) isn't there.

const M4A := "D:/Music/Imagine Dragons/Evolve/04 Believer.m4a"
## Its real length: the iTunSMPB tag's 9011622 samples at 44.1 kHz, i.e.
## without the encoder's 2112 priming / 538 padding samples.
const M4A_SECONDS := 9011622.0 / 44100.0

var _p := 0
var _f := 0
var _s := 0


func ok(cond: bool, label: String) -> void:
	if cond:
		_p += 1
		print("  ok   ", label)
	else:
		_f += 1
		print("  FAIL ", label)


func skip(label: String) -> void:
	_s += 1
	print("  skip ", label)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== M4A playback ==")
	if not ClassDB.class_exists("SongFeatures"):
		skip("native extension not built")
	else:
		_test_decode_pcm16()
		await _test_stream()
		_test_beat_alignment()
	print("== %d passed, %d failed, %d skipped ==" % [_p, _f, _s])
	quit(1 if _f > 0 else 0)


## `channels` channels of 16-bit PCM; channel c holds the constant value
## (c + 1) * 1000 so the decoded channel order can be checked.
func _wav(path: String, channels: int, seconds: float, rate := 22050) -> String:
	var frames := int(rate * seconds)
	var data := PackedByteArray()
	data.resize(frames * channels * 2)
	for i in range(frames):
		for c in range(channels):
			data.encode_s16((i * channels + c) * 2, (c + 1) * 1000)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(36 + data.size())
	f.store_buffer("WAVEfmt ".to_ascii_buffer())
	f.store_32(16)
	f.store_16(1)
	f.store_16(channels)
	f.store_32(rate)
	f.store_32(rate * channels * 2)
	f.store_16(channels * 2)
	f.store_16(16)
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(data.size())
	f.store_buffer(data)
	f.close()
	return ProjectSettings.globalize_path(path)


func _test_decode_pcm16() -> void:
	print("- decode_pcm16")
	var sf = ClassDB.instantiate("SongFeatures")
	var d: Dictionary = sf.decode_pcm16(_wav("user://_pcm_stereo.wav", 2, 3.0), 0.0)
	ok(d.ok and d.mix_rate == 22050 and d.stereo and absf(d.duration - 3.0) < 0.001, "stereo WAV: rate, stereo, duration")
	var data: PackedByteArray = d.get("data", PackedByteArray())
	ok(data.size() == 22050 * 3 * 2 * 2, "16-bit interleaved, %d bytes" % data.size())
	ok(abs(data.decode_s16(0) - 1000) <= 1 and abs(data.decode_s16(2) - 2000) <= 1, "left / right in order (%d, %d)" % [data.decode_s16(0), data.decode_s16(2)])

	d = sf.decode_pcm16(_wav("user://_pcm_mono.wav", 1, 2.0), 0.0)
	ok(d.ok and not d.stereo and d.data.size() == 22050 * 2 * 2, "mono stays mono")

	d = sf.decode_pcm16(_wav("user://_pcm_quad.wav", 4, 1.0), 0.0)
	ok(d.ok and d.stereo and d.data.size() == 22050 * 2 * 2, "4 channels -> stereo")
	ok(d.ok and abs(d.data.decode_s16(0) - 1000) <= 1 and abs(d.data.decode_s16(2) - 2000) <= 1, "...keeping front left / right")

	d = sf.decode_pcm16(_wav("user://_pcm_long.wav", 2, 12.0), 5.0)
	ok(not d.ok and d.error == "track is too long", "max_seconds cap (%s)" % d.get("error", ""))
	d = sf.decode_pcm16(ProjectSettings.globalize_path("user://_pcm_missing.mp3"), 0.0)
	ok(not d.ok, "missing file fails (%s)" % d.get("error", ""))


func _test_stream() -> void:
	print("- SongAnalyzer.load_stream / decode_os_stream")
	ok(SongAnalyzer.is_os_format("x.M4A") and SongAnalyzer.is_os_format("x.aac")
		and not SongAnalyzer.is_os_format("x.mp3"), "is_os_format")
	if not FileAccess.file_exists(M4A) or not SongAnalyzer.os_decoding_available():
		skip("real M4A / OS AAC decoder not available here")
		return
	var t := Time.get_ticks_msec()
	var r := SongAnalyzer.decode_os_stream(M4A)
	var s: AudioStreamWAV = r["stream"]
	print("    decoded in %d ms" % (Time.get_ticks_msec() - t))
	ok(s != null and r["error"] == "", "M4A -> AudioStreamWAV %s" % r["error"])
	if s == null:
		return
	ok(absf(s.get_length() - M4A_SECONDS) < 0.001, "length %.3f s, priming / padding trimmed" % s.get_length())
	ok(s.format == AudioStreamWAV.FORMAT_16_BITS and s.stereo and s.mix_rate == 44100, "16-bit stereo 44.1 kHz")
	ok(SongAnalyzer.load_stream(M4A) is AudioStreamWAV, "load_stream handles M4A too")

	# Actually play it.
	var player := AudioStreamPlayer.new()
	root.add_child(player)
	player.stream = s
	player.play(60.0)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1000:
		await process_frame
	var pos := player.get_playback_position()
	ok(player.playing and pos > 60.5 and pos < 62.0, "plays from 60 s (at %.2f s after 1 s)" % pos)
	player.seek(150.0)
	await process_frame
	ok(player.get_playback_position() >= 150.0, "seeks")
	player.stop()
	player.queue_free()


## The decoded audio lines up with VirtualDJ's beat grid: the sharpest
## loudness rise near each beat sits on it. Without the iTunSMPB trimming
## every onset landed ~48 ms (2112 samples) late.
func _test_beat_alignment() -> void:
	print("- M4A timing vs VirtualDJ's beat grid")
	var path := "D:/Music/Nicki Minaj/Pink Friday ... Roman Reloaded/10 Starships.m4a"
	var db := VirtualDjDatabase.new()
	db.load_all()
	var song := db.find_song(path)
	if song == null or not FileAccess.file_exists(path) or not SongAnalyzer.os_decoding_available():
		skip("Starships / OS AAC decoder not on this machine")
		return
	var d: Dictionary = ClassDB.instantiate("SongFeatures").waveform_file(path, 1000)   # 1 ms columns
	var pk: PackedFloat32Array = d.wave_peak
	var offs := []
	for b in song.beat_times(d.duration):
		var c := int(b * 1000.0)
		if c < 120 or c + 120 >= pk.size():
			continue
		var best := -1.0
		var at := 0
		for k in range(-100, 101):
			var rise := pk[c + k + 5] - pk[c + k - 5]
			if rise > best:
				best = rise
				at = k
		offs.append(at)
	offs.sort()
	var median: int = offs[offs.size() / 2]
	ok(absi(median) <= 10, "onsets on the beats: median %+d ms over %d beats" % [median, offs.size()])
	ok(absf(d.duration - song.length) < 0.02, "length matches VirtualDJ's (%.3f vs %.3f s)" % [d.duration, song.length])
