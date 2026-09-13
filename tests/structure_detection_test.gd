extends SceneTree
## Regression test for SongDetect.segment() — the structural section
## labeler behind the Auto Show tab. Guards against "almost every section
## reads as Chorus" (fixed in commit 5f99997, 2026-09-14):
##   1. clustering used to merge a quiet verse with its own chorus because
##      they share a chord progression (chroma dominates the similarity)
##   2. even gated by loudness, a long track could still chain segments
##      transitively into one supercluster spanning the whole song
##   3. a fixed energy tolerance meant nothing on a loudness-compressed
##      track whose whole body sits in a narrow dynamic range
##
##   godot --headless --script tests/structure_detection_test.gd
##
## The three synthetic cases are the actual repro cases used to find and
## fix the bug, and are the portable regression: no external files, no
## real (copyrighted) audio, deterministic. A handful of real files from
## this machine's music library are checked too, as a bonus cross-genre
## sanity pass — those SKIP (not fail) when the file isn't present, since
## the library obviously isn't portable to another machine or CI.

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
	print("== structure detection regression ==")
	if not SongAnalyzer.fast_available():
		printerr("song_dsp extension not built — see addons/song_dsp/BUILD.md")
		quit(1)
		return

	_test_same_chord_alternation()
	_test_jitter_tolerant_repeats()
	_test_realistic_layout()
	_test_real_files()

	print("== %d passed, %d failed, %d skipped ==" % [_p, _f, _s])
	quit(1 if _f > 0 else 0)


# ================================================================ CASES ==

## The bug's exact trigger: sections alternate quiet/loud on the *same*
## chord throughout, so chroma similarity alone can't tell verse from
## chorus — only loudness can. Before the fix every section here read
## "Chorus".
func _test_same_chord_alternation() -> void:
	print("- same chord, alternating quiet/loud")
	var a := _analyse(_synth_wav("user://_sdt_1.wav", 22050, [
		[0.0, 24.0, 0.4, 0], [24.0, 40.0, 1.0, 0], [40.0, 56.0, 0.4, 0],
		[56.0, 72.0, 1.0, 0], [72.0, 80.0, 0.3, 0],
	]))
	_print_sections(a)
	ok(a.sections.size() >= 3, "found more than one section (%d)" % a.sections.size())
	var counts := _label_counts(a)
	var chorus_n: int = int(counts.get("Chorus", 0)) + int(counts.get("Drop", 0))
	ok(chorus_n < a.sections.size(),
		"not every section is Chorus  (%d/%d)" % [chorus_n, a.sections.size()])
	ok(chorus_n > 0, "still recognises at least one Chorus")
	var quiet_hi := 0.0
	var loud_lo := 1.0
	for s in a.sections:
		var mid: float = (float(s["start"]) + float(s["end"])) * 0.5
		if (mid > 24.0 and mid < 40.0) or (mid > 56.0 and mid < 72.0):
			loud_lo = minf(loud_lo, float(s["energy"]))
		else:
			quiet_hi = maxf(quiet_hi, float(s["energy"]))
	ok(loud_lo > quiet_hi, "loud sections score higher energy than quiet ones")


## Real repeats never have identical loudness — a small jitter between
## "the same" section, twice each at quiet and loud, must still cluster
## together rather than fragment into a distinct label per repeat.
func _test_jitter_tolerant_repeats() -> void:
	print("- noisy repeats (small energy jitter)")
	var a := _analyse(_synth_wav("user://_sdt_2.wav", 22050, [
		[0.0, 16.0, 0.42, 0], [16.0, 32.0, 0.95, 0], [32.0, 48.0, 0.48, 0],
		[48.0, 64.0, 1.0, 0], [64.0, 80.0, 0.40, 0],
	]))
	_print_sections(a)
	ok(a.sections.size() >= 4, "found the expected section count (%d)" % a.sections.size())
	var distinct := {}
	for s in a.sections:
		distinct[String(s["label"])] = true
	ok(distinct.size() <= 3,
		"didn't fragment into a distinct label per section  (%d distinct of %d sections)"
			% [distinct.size(), a.sections.size()])
	ok(distinct.size() >= 2, "still distinguishes quiet from loud (%d distinct)" % distinct.size())


## A fuller layout: intro, two verses, three choruses, one bridge on a
## different chord (so it's genuinely distinct, not just quieter), outro.
## Checks the whole pipeline agrees with a normal pop structure.
func _test_realistic_layout() -> void:
	print("- realistic layout (intro/verse/chorus/bridge/outro)")
	var a := _analyse(_synth_wav("user://_sdt_3.wav", 22050, [
		[0.0, 8.0, 0.35, 0], [8.0, 24.0, 0.55, 0], [24.0, 40.0, 0.95, 0],
		[40.0, 56.0, 0.5, 0], [56.0, 72.0, 1.0, 0], [72.0, 88.0, 0.6, 1],
		[88.0, 104.0, 0.92, 0], [104.0, 112.0, 0.3, 0],
	]))
	_print_sections(a)
	var counts := _label_counts(a)
	var chorus_n: int = int(counts.get("Chorus", 0)) + int(counts.get("Drop", 0))
	ok(a.sections.size() >= 5, "found multiple sections (%d)" % a.sections.size())
	ok(chorus_n <= a.sections.size() / 2, "chorus isn't the majority label  (%d/%d)" % [chorus_n, a.sections.size()])
	ok(chorus_n >= 2, "still finds the recurring choruses  (%d)" % chorus_n)


## Bonus cross-genre sanity pass on real tracks from this machine's music
## library (see structure-detection-fixes memory for the full readout of
## each). Not portable, so these SKIP rather than fail when absent. The
## assertion is deliberately loose — real songs can legitimately be
## mostly one label (an almost entirely non-repeating song is mostly
## Verse) — it only catches the original bug's signature: the *whole*
## track collapsing into one or two labels.
func _test_real_files() -> void:
	print("- real files (informational; skip if not on this machine)")
	var files := [
		"F:/Music/_CDs/2 Unlimited/No Limit/01. 2 Unlimited - No Limit (Rap Version).mp3",
		"F:/Music/_CDs/Butthole Surfers/Pepper/01-Pepper.mp3",
		"F:/Music/_CDs/Bionic/Stay/01. Bionic - Stay (radio edit).mp3",
		"F:/Music/_CDs/Del the Funky Homosapien/Mistadobalina/01. Del the Funky Homosapien - Mistadobalina (radio edit).mp3",
		"F:/Music/_CDs/The Veronicas/Untouched/01. The Veronicas - Untouched.mp3",
	]
	for path in files:
		if not FileAccess.file_exists(path):
			skip("not present: %s" % path)
			continue
		var sf = ClassDB.instantiate("SongFeatures")
		var d: Dictionary = sf.analyze_file(path, 2048, 1024, 1024)
		if not bool(d.get("ok", false)):
			ok(false, "%s — analyze_file failed: %s" % [path.get_file(), d.get("error", "?")])
			continue
		var an := SongAnalyzer.new()
		an._path = path
		var a: SongAnalysis = an._detect_from_frames(d)
		an.free()
		_print_sections(a)
		var counts := _label_counts(a)
		var distinct := counts.size()
		var dominant := 0
		for k in counts:
			dominant = maxi(dominant, int(counts[k]))
		var frac: float = float(dominant) / maxf(1.0, float(a.sections.size()))
		print("  %s -> %s" % [path.get_file(), counts])
		if a.sections.size() >= 4:
			ok(distinct >= 2, "%s: more than one label used (%d)" % [path.get_file(), distinct])
			ok(frac < 0.9, "%s: no single label dominates the whole track  (%.0f%%)" % [path.get_file(), frac * 100.0])


# ============================================================= helpers ==

func _analyse(path: String) -> SongAnalysis:
	var sf = ClassDB.instantiate("SongFeatures")
	var d: Dictionary = sf.analyze_file(path, 2048, 1024, 1024)
	var an := SongAnalyzer.new()
	an._path = path
	var a: SongAnalysis = an._detect_from_frames(d)
	an.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return a


func _print_sections(a: SongAnalysis) -> void:
	for s in a.sections:
		print("    %6.1f - %6.1f  %-8s energy=%.2f" % [s["start"], s["end"], s["label"], s["energy"]])


func _label_counts(a: SongAnalysis) -> Dictionary:
	var counts := {}
	for s in a.sections:
		var l := String(s["label"])
		counts[l] = int(counts.get(l, 0)) + 1
	return counts


## A click track (kick on the beat, hat on the off-beat) plus a triad,
## with per-section amplitude and an optional alternate chord — enough to
## drive tempo/beat tracking and give the clustering something to chew on.
## `layout` is [{t0, t1, amp, chord(0 or 1)}, ...] covering the whole span.
func _synth_wav(path: String, sr: int, layout: Array) -> String:
	var total: float = layout[-1][1]
	var n := int(sr * total)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var beat := sr * 0.5   # 120 BPM
	var chord_a := [261.63, 329.63, 392.0]    # C major
	var chord_b := [349.23, 440.0, 523.25]    # F major
	for i in range(n):
		var t := float(i) / sr
		var amp := 0.4
		var chord := 0
		for seg in layout:
			if t >= seg[0] and t < seg[1]:
				amp = seg[2]
				chord = seg[3]
				break
		var s := 0.0
		var ph := fmod(float(i), beat)
		if ph < sr * 0.10:
			s += 0.7 * amp * exp(-ph / (sr * 0.03)) * sin(TAU * 60.0 * (ph / sr))
		var ph2 := fmod(float(i) + beat * 0.5, beat)
		if ph2 < sr * 0.03:
			s += 0.15 * amp * exp(-ph2 / (sr * 0.008)) * (randf() * 2.0 - 1.0)
		var freqs: Array = chord_b if chord == 1 else chord_a
		var chord_sum := 0.0
		for f in freqs:
			chord_sum += sin(TAU * float(f) * t)
		s += 0.22 * amp * (chord_sum / freqs.size())
		buf[i] = clampf(s, -1.0, 1.0)

	var f := FileAccess.open(path, FileAccess.WRITE)
	var datasize := n * 2
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(36 + datasize)
	f.store_buffer("WAVE".to_ascii_buffer())
	f.store_buffer("fmt ".to_ascii_buffer())
	f.store_32(16)
	f.store_16(1)
	f.store_16(1)
	f.store_32(sr)
	f.store_32(sr * 2)
	f.store_16(2)
	f.store_16(16)
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(datasize)
	for v in buf:
		f.store_16(int(clampf(v, -1.0, 1.0) * 32767.0) & 0xFFFF)
	f.close()
	return path
