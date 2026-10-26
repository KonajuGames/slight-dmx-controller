extends SceneTree
## Tests for the tempo clock (the `Tempo` autoload): tap tempo, MIDI
## clock, external (OS2L) beats, free-running between them, and what
## follows it — beat-sync chases and tempo-synced effects.
##
##   godot --headless --script tests/tempo_clock_test.gd
##
## A fresh clock is made for each test and driven with explicit times, so
## nothing waits on the real clock.

var _p := 0
var _f := 0


func ok(cond: bool, label: String) -> void:
	if cond:
		_p += 1
		print("  ok   ", label)
	else:
		_f += 1
		print("  FAIL ", label)


func _initialize() -> void:
	print("== Tempo clock ==")
	_test_tap()
	_test_free_running()
	_test_midi_clock()
	_test_external_beats()
	_test_effect_rate()
	print("== %d passed, %d failed ==" % [_p, _f])
	quit(1 if _f > 0 else 0)


func _clock() -> Node:
	return load("res://scripts/tempo_clock.gd").new()


func _beats(t: Node) -> Array:
	var n := [0]
	t.beat.connect(func(): n[0] += 1)
	return n


func _test_tap() -> void:
	print("- tap tempo")
	var t := _clock()
	var beats := _beats(t)
	ok(not t.running and t.describe() == "— BPM", "off to start with")
	t.tap(10.0)
	ok(t.running and t.source == t.Source.TAP and beats[0] == 1, "one tap starts it, on a beat")
	ok(is_equal_approx(t.bpm, 120.0), "...at the tempo it had (120)")
	t.tap(10.5)
	t.tap(11.0)
	t.tap(11.5)
	ok(absf(t.bpm - 120.0) < 0.01 and beats[0] == 4, "taps half a second apart: 120 BPM (%.2f)" % t.bpm)
	t.tap(11.9)
	ok(absf(t.bpm - 60.0 / (1.9 / 4.0)) < 0.01, "the average spacing of the taps (%.2f)" % t.bpm)
	t.tap(20.0)
	t.tap(20.4)
	ok(absf(t.bpm - 150.0) < 0.01, "a pause starts a new count: 150 BPM (%.2f)" % t.bpm)
	t.tap(30.0)
	t.tap(30.1)
	ok(t.bpm == t.MAX_BPM, "capped at %d" % t.MAX_BPM)
	ok("Tap" in t.describe(), "the read-out names the source: %s" % t.describe())
	t.stop()
	ok(not t.running and t.source == t.Source.NONE, "stop() turns it off")
	t.free()


func _test_free_running() -> void:
	print("- free-running between taps")
	var t := _clock()
	var beats := _beats(t)
	t.tap(0.0)
	t.tap(0.5)                      # 120 BPM, next beat at 1.0
	t.advance(0.9)
	ok(beats[0] == 2, "no beat before it's due")
	t.advance(1.0)
	ok(beats[0] == 3, "a beat when it's due")
	ok(absf(t.phase(1.25) - 0.5) < 0.001, "halfway to the next one: phase 0.5 (%.3f)" % t.phase(1.25))
	t.advance(1.6)
	ok(beats[0] == 4, "and the next")
	t.advance(5.2)
	ok(beats[0] == 5, "after a stall, one beat, not a burst")
	t.advance(5.4)
	ok(beats[0] == 5, "...back in step (next at 5.5)")
	t.advance(5.5)
	ok(beats[0] == 6, "...which it lands")
	t.free()


func _test_midi_clock() -> void:
	print("- MIDI clock")
	var t := _clock()
	var beats := _beats(t)
	var dt := 60.0 / 125.0 / 24.0     # 125 BPM, 24 pulses a beat
	for i in range(24):
		t.clock_pulse(100.0 + i * dt)
	ok(not t.running and beats[0] == 0, "a beat's worth of pulses before it has a tempo")
	for i in range(24, 97):
		t.clock_pulse(100.0 + i * dt)
	ok(t.running and t.source == t.Source.MIDI_CLOCK, "then it's the source")
	ok(absf(t.bpm - 125.0) < 0.05, "at its tempo, 125 (%.2f)" % t.bpm)
	ok(beats[0] == 4, "a beat every 24 pulses: 24, 48, 72, 96 (%d)" % beats[0])
	ok(not t.tap(100.0 + 97 * dt), "taps are ignored while it's live")
	var last := 100.0 + 96 * dt
	t.advance(last + 0.4)
	ok(t.source == t.Source.MIDI_CLOCK, "still live just after the last pulse")
	t.advance(last + 0.6)
	ok(t.running and t.source == t.Source.TAP, "gone quiet: runs on freely")
	ok(t.tap(last + 1.0), "...and taps work again")
	t.free()


func _test_external_beats() -> void:
	print("- OS2L beats")
	var t := _clock()
	var beats := _beats(t)
	t.external_beat(128.0, t.Source.OS2L, 50.0)
	ok(t.running and t.source == t.Source.OS2L and beats[0] == 1, "a VirtualDJ beat takes the clock")
	ok(is_equal_approx(t.bpm, 128.0), "...at its tempo")
	var p: float = 60.0 / 128.0
	t.advance(50.0 + p + 0.01)
	ok(beats[0] == 1, "a beat a little late isn't doubled by the free-running clock")
	t.external_beat(128.0, t.Source.OS2L, 50.0 + p + 0.02)
	ok(beats[0] == 2, "...it lands when it comes")
	t.advance(50.0 + p * 2.3)
	ok(beats[0] == 3, "one missed: filled in")
	t.advance(50.0 + p * 6.0)
	ok(t.source == t.Source.TAP, "stopped coming: runs on freely")
	t.free()


func _test_effect_rate() -> void:
	print("- tempo-synced effects")
	var WE = load("res://scripts/wave_effect.gd")
	var e = WE.new()
	e.bpm = 30.0
	ok(e.rate(128.0) == 30.0, "Own rate: its BPM")
	e.tempo_beats = 2.0
	ok(e.rate(0.0) == 30.0, "following, but no clock: its BPM")
	ok(is_equal_approx(e.rate(128.0), 64.0), "2 beats a cycle at 128: 64 cycles a minute")
	e.role = "PAN"
	e.tempo_beats = 1.0
	ok(e.rate(128.0) == WE.MOTOR_MAX_BPM, "pan is still capped")
	var d: Dictionary = e.to_dict()
	ok(WE.from_dict(d).tempo_beats == 1.0, "saved with the effect")
	ok(WE.from_dict({}).tempo_beats == 0.0, "older shows: Own rate")
