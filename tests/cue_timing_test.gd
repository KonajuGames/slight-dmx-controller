extends SceneTree
## Tests for cue timing: a cue's Delay before its fade, Follow into the
## next cue, and the fade progress bar.
##
##   godot --headless --script tests/cue_timing_test.gd
##
## The crossfade engine and the cue list's timers are stepped by hand
## (step()), so nothing waits on the real clock.

var _p := 0
var _f := 0

var art: Node
var panel
var CueScript: GDScript


func ok(cond: bool, label: String) -> void:
	if cond:
		_p += 1
		print("  ok   ", label)
	else:
		_f += 1
		print("  FAIL ", label)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== Cue timing ==")
	art = root.get_node("ArtNet")
	CueScript = load("res://scripts/cue.gd")
	panel = load("res://scripts/cue_list_panel.gd").new()
	root.add_child(panel)
	_test_saved()
	_test_plain()
	_test_delay()
	_test_follow()
	_test_takeover()
	panel.queue_free()
	print("== %d passed, %d failed ==" % [_p, _f])
	quit(1 if _f > 0 else 0)


## Run the fade engine and the cue timers on by `secs`, in 50 ms steps.
func step(secs: float) -> void:
	var n := int(round(secs / 0.05))
	for i in range(n):
		art._process(0.05)
		panel.advance(0.05)


func _cue(level: int, fade: float, delay := 0.0, follow := false, wait := 0.0):
	var c = CueScript.new("L%d" % level, fade, fade)
	c.set_levels([{0: level}])
	c.delay = delay
	c.follow = follow
	c.follow_wait = wait
	return c


func _level() -> int:
	return art.get_universe(0).get_channel(0)


func _reset(list: Array) -> void:
	panel.halt()
	art.get_universe(0).set_all(0)
	panel.cues.clear()
	for c in list:
		panel.cues.append(c)
	panel._current = -1
	panel._next = 0


func _test_saved() -> void:
	print("- saved with the cue")
	var c = _cue(10, 1.0, 1.5, true, 2.5)
	var back = CueScript.from_dict(c.to_dict())
	ok(back.delay == 1.5 and back.follow and back.follow_wait == 2.5, "delay, follow and its wait round-trip")
	var old = CueScript.from_dict({"label": "x", "levels": []})
	ok(old.delay == 0.0 and not old.follow, "older cues: no delay, no follow")
	ok(CueScript.from_dict({"delay": -3}).delay == 0.0, "a negative delay reads as none")


func _test_plain() -> void:
	print("- a plain cue, and the progress bar")
	_reset([_cue(200, 2.0)])
	panel.go()
	ok(panel.progress_bar.value < 0.01 and "Cue 1" in panel.progress_label.text, "GO: the bar starts (%s)" % panel.progress_label.text)
	step(1.0)
	ok(absf(panel.progress_bar.value - 0.5) < 0.05 and absi(_level() - 100) <= 3,
		"half way through the fade: the bar's half way (%.2f), so's the level (%d)" % [panel.progress_bar.value, _level()])
	ok("50%" in panel.progress_label.text and "1.0s" in panel.progress_label.text, "...and says so: %s" % panel.progress_label.text)
	step(1.1)
	ok(_level() == 200 and panel.progress_bar.value == 1.0 and panel.progress_label.text == "", "done: full, the bar full")
	ok(not panel.is_waiting(), "no follow: nothing waiting")
	# Only rising channels: the fade's as long as its up time.
	_reset([_cue(100, 1.0)])
	panel.cues[0].fade_down = 9.0
	panel.go()
	step(0.5)
	ok(absf(art.fade_progress() - 0.5) < 0.06, "only rising: the progress is over the up time (%.2f)" % art.fade_progress())


func _test_delay() -> void:
	print("- delay")
	_reset([_cue(200, 1.0, 2.0)])
	panel.go()
	ok(panel.current_number() == 1 and panel.is_waiting(), "GO: the cue is live, waiting out its delay")
	step(1.0)
	ok(_level() == 0 and "Delay 1.0s" in panel.progress_label.text, "nothing moves during the delay (%s)" % panel.progress_label.text)
	ok(absf(panel.progress_bar.value - 0.5) < 0.05, "...the bar counts it down")
	step(1.5)
	ok(_level() > 0 and _level() < 200 and "Cue 1" in panel.progress_label.text, "then the fade starts (%d)" % _level())
	step(1.0)
	ok(_level() == 200, "and finishes")
	ok("d2.0" in panel.cue_list.get_item_text(0), "the list shows the delay: %s" % panel.cue_list.get_item_text(0))


func _test_follow() -> void:
	print("- follow")
	_reset([_cue(100, 1.0, 0.0, true, 1.0), _cue(200, 0.0, 0.0, true), _cue(50, 1.0), _cue(0, 0.0)])
	panel.go()
	step(1.1)
	ok(_level() == 100 and panel.current_number() == 1 and panel.is_waiting(), "cue 1 faded in: its follow waits")
	ok("Follow in" in panel.progress_label.text, "...shown on the bar: %s" % panel.progress_label.text)
	step(0.5)
	ok(panel.current_number() == 1, "...for its wait")
	step(0.6)
	ok(panel.current_number() >= 2, "then GOes cue 2 by itself")
	step(0.1)
	ok(panel.current_number() == 3, "cue 2 (no fade, no wait) follows straight on into cue 3")
	step(1.1)
	ok(_level() == 50 and panel.current_number() == 3 and not panel.is_waiting(), "cue 3 has no follow: the sequence stops there")
	ok("→ 1.0s" in panel.cue_list.get_item_text(0) and "→" not in panel.cue_list.get_item_text(2),
		"the list marks the follows: %s" % panel.cue_list.get_item_text(0))
	# The last cue's follow has nowhere to go.
	_reset([_cue(100, 0.0, 0.0, true)])
	panel.go()
	step(0.2)
	ok(not panel.is_waiting() and panel.current_number() == 1, "a follow on the last cue: nothing")


func _test_takeover() -> void:
	print("- GO, Halt and loading take over")
	_reset([_cue(100, 0.5, 0.0, true, 5.0), _cue(200, 0.0), _cue(30, 0.0)])
	panel.go()
	step(0.6)
	ok(panel.is_waiting(), "a follow waiting")
	panel.go()
	ok(panel.current_number() == 2 and not panel.is_waiting(), "GO takes over from it")
	step(6.0)
	ok(panel.current_number() == 2, "...and it doesn't fire later")
	_reset([_cue(100, 0.5, 0.0, true, 1.0), _cue(200, 0.0)])
	panel.go()
	step(0.6)
	panel.halt()
	step(2.0)
	ok(panel.current_number() == 1 and not panel.is_waiting(), "Halt stops a follow")
	_reset([_cue(100, 1.0, 3.0), _cue(200, 0.0)])
	panel.go()
	step(1.0)
	panel.halt()
	step(3.0)
	ok(_level() == 0, "...and a delay")
	_reset([_cue(100, 1.0, 3.0)])
	panel.go()
	panel.from_dict({"cues": [_cue(5, 0.0).to_dict()]})
	step(4.0)
	ok(_level() == 0 and not panel.is_waiting(), "loading another cue list drops what was waiting")
	# A delayed cue lets the last cue's fade run on.
	_reset([_cue(200, 2.0), _cue(10, 0.0, 5.0)])
	panel.go()
	step(1.0)
	panel.go()
	step(1.05)
	ok(_level() == 200 and panel.current_number() == 2, "a delayed cue: the last fade runs on through its delay (%d)" % _level())
	ok("Delay" in panel.progress_label.text, "...the bar shows the delay")
