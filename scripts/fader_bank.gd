class_name FaderBank
extends Node
## Playback faders (the console's Faders tab): each puts a cue, a chase, a
## fixture group or an effect on a fader, 0..1, which a MIDI controller's
## fader or knob (a CC or a pitch bend, learned) can move.
##
##   CUE    a submaster: the cue's standing look (as GO would leave it)
##          brought up by the fader. Its intensity channels (a fixture's
##          DIMMER, or its colour / white channels when it has none) are
##          scaled by the fader and merged highest-takes-precedence with
##          the stage; its other channels (colour on a dimmed fixture,
##          pan, tilt, gobos, ...) go to the look's values while the
##          fader's up at all. A layer_providers layer, so chases and
##          effects still go over it.
##   CHASE  the fader runs the chase while it's up, its intensity
##          channels scaled by the fader (Chase.level); down to 0, the
##          chase stops and is the Chases tab's again.
##   GROUP  a group master: the group's fixtures' intensity channels are
##          scaled by the fader, whatever's driving them (an ArtNet scale
##          layer: after everything but the live flashes, before the grand
##          master). Up full, it does nothing.
##   EFFECT the fader runs the effect while it's up at its strength
##          (WaveEffect.level: a dimmer / colour effect's output scaled,
##          a movement's swing); down to 0, it stops and is the Effects
##          tab's again.
##
## Targets are by cue number (1-based) or chase / group / effect name.

## A fader moved (by MIDI, or from code) — the panel follows.
signal levels_changed
## Faders were added, removed, re-targeted or loaded.
signal faders_changed
## A MIDI Learn finished (the fader's index).
signal learned(index: int)
## A fader started or stopped a chase (the Chases tab follows).
signal chases_changed
## A fader started or stopped an effect (the Effects tab follows).
signal effects_changed

enum { KIND_CUE, KIND_CHASE, KIND_GROUP, KIND_EFFECT }
const KINDS := ["Cue", "Chase", "Group", "Effect"]
const MAX_FADERS := 24

const _INTENSITY_ROLES := ["RED", "GREEN", "BLUE", "WHITE", "AMBER", "UV"]


class Fader:
	var name := "Fader"
	var kind: int = KIND_CUE
	var target := ""            # cue number, or chase / group name
	var level := 0.0            # 0..1
	var midi_channel := -1      # -1: any
	var midi_cc := -1           # -1: not mapped
	var midi_bend := false      # mapped to its channel's pitch bend instead

	func to_dict() -> Dictionary:
		return {"name": name, "kind": KINDS[kind].to_lower(), "target": target,
			"level": level, "midi_channel": midi_channel, "midi_cc": midi_cc, "midi_bend": midi_bend}

	func is_mapped() -> bool:
		return midi_cc >= 0 or midi_bend

	func forget_midi() -> void:
		midi_cc = -1
		midi_bend = false
		midi_channel = -1

	static func from_dict(d: Dictionary) -> Fader:
		var f := Fader.new()
		f.name = String(d.get("name", "Fader"))
		var k := KINDS.map(func(s): return s.to_lower()).find(String(d.get("kind", "cue")))
		f.kind = maxi(k, 0)
		f.target = String(d.get("target", ""))
		f.level = clampf(float(d.get("level", 0.0)), 0.0, 1.0)
		f.midi_channel = clampi(int(d.get("midi_channel", -1)), -1, 15)
		f.midi_cc = clampi(int(d.get("midi_cc", -1)), -1, 127)
		f.midi_bend = bool(d.get("midi_bend", false))
		return f

	## "CC 7 · ch 1", "Bend · ch 2", or "" when it isn't mapped.
	func midi_text() -> String:
		if midi_bend:
			return "Bend · ch %s" % ("any" if midi_channel < 0 else str(midi_channel + 1))
		if midi_cc < 0:
			return ""
		return "CC %d · ch %s" % [midi_cc, "any" if midi_channel < 0 else str(midi_channel + 1)]


var faders: Array[Fader] = []

## Set by the shell: func() -> patched fixtures ({uid, u, start, profile,
## mode}); func() -> the show's groups ([{name, members: [uid]}]); and
## func(cue_number: int) -> the cue's standing look (per universe
## {"<channel>": value}), or [] if there's no such cue.
var fixtures_provider := Callable()
var groups_provider := Callable()
var cue_look_provider := Callable()
## Set by the shell: func(name: String, on: bool) — start (resolving its
## targets from the patch) or stop an effect. Unset: `running` is set
## directly.
var effect_runner := Callable()

var _learning := -1          # the fader whose MIDI Learn is armed
var _chase_held := {}        # chase instance id -> true: started by a fader
var _effect_held := {}       # effect instance id -> true: run by a fader


func _ready() -> void:
	ArtNet.layer_providers.append(layer)
	ArtNet.scale_providers.append(scale_layer)
	Fx.intensity_provider = intensity_channels
	get_tree().root.window_input.connect(_on_window_input)


func _exit_tree() -> void:
	ArtNet.layer_providers.erase(layer)
	ArtNet.scale_providers.erase(scale_layer)
	if Fx.intensity_provider == Callable(intensity_channels):
		Fx.intensity_provider = Callable()


func add_fader() -> Fader:
	if faders.size() >= MAX_FADERS:
		return null
	var f := Fader.new()
	f.name = "Fader %d" % (faders.size() + 1)
	faders.append(f)
	faders_changed.emit()
	return f


func remove_fader(i: int) -> void:
	if i < 0 or i >= faders.size():
		return
	set_level(i, 0.0)                     # lets go of its chase
	faders.remove_at(i)
	if _learning == i:
		_learning = -1
	faders_changed.emit()


## Re-point a fader (its chase, if it held one, is let go first).
func set_target(i: int, kind: int, target: String) -> void:
	if i < 0 or i >= faders.size():
		return
	var lvl := faders[i].level
	set_level(i, 0.0)
	faders[i].kind = clampi(kind, 0, KINDS.size() - 1)
	faders[i].target = target
	set_level(i, lvl)
	faders_changed.emit()


func set_level(i: int, v: float) -> void:
	if i < 0 or i >= faders.size():
		return
	var f := faders[i]
	f.level = clampf(v, 0.0, 1.0)
	if f.kind == KIND_CHASE:
		_drive_chase(f)
	elif f.kind == KIND_EFFECT:
		_drive_effect(f)
	levels_changed.emit()


func _drive_chase(f: Fader) -> void:
	var c := _chase(f.target)
	if c == null:
		return
	var key := c.get_instance_id()
	if f.level > 0.0:
		if not c.running:
			c.reset()
			c.running = true
			chases_changed.emit()
		_chase_held[key] = true
		c.level = f.level
	elif _chase_held.has(key):
		_chase_held.erase(key)
		c.running = false
		c.level = 1.0
		chases_changed.emit()


func _drive_effect(f: Fader) -> void:
	var e := _effect(f.target)
	if e == null:
		return
	var key := e.get_instance_id()
	if f.level > 0.0:
		if not e.running:
			if effect_runner.is_valid():
				effect_runner.call(e.name, true)
			else:
				e.running = true
			if not e.running:
				return                        # nothing patched for it to run on
			effects_changed.emit()
		_effect_held[key] = true
		e.level = f.level
	elif _effect_held.has(key):
		_effect_held.erase(key)
		if effect_runner.is_valid():
			effect_runner.call(e.name, false)
		else:
			e.running = false
		e.level = 1.0
		effects_changed.emit()


func _effect(name_: String) -> WaveEffect:
	var low := name_.strip_edges().to_lower()
	for e in Fx.effects:
		if e.name.to_lower() == low:
			return e
	return null


func _chase(name_: String) -> Chase:
	var low := name_.strip_edges().to_lower()
	for c in Fx.chases:
		if c.name.to_lower() == low:
			return c
	return null


## Blackout: every cue, chase and effect fader to 0 (group masters only ever
## take light away, so they're left).
func pull_down_playback() -> void:
	for i in range(faders.size()):
		if faders[i].kind != KIND_GROUP:
			set_level(i, 0.0)


## Faders down, chases let go (before loading another show).
func clear() -> void:
	for i in range(faders.size()):
		set_level(i, 0.0)
	faders.clear()
	_learning = -1
	_chase_held.clear()
	_effect_held.clear()
	faders_changed.emit()


# ------------------------------------------------------------------ MIDI --

## Arm MIDI Learn for fader `i`: the next CC or pitch bend that arrives
## maps it (-1 cancels).
func learn(i: int) -> void:
	_learning = i if i >= 0 and i < faders.size() else -1


func is_learning(i: int) -> bool:
	return _learning == i


## The root window's input, before it's forwarded (MIDI goes only to a
## focused dialog after that; see Triggers._on_window_input()).
func _on_window_input(event: InputEvent) -> void:
	if event is InputEventMIDI:
		handle_midi(event)


## A MIDI message: completes a Learn, or moves the faders mapped to it — a
## CC's 0..127, or a pitch bend's 0..16383 (0 = out, 16383 = full).
## Returns whether it was used.
func handle_midi(ev: InputEventMIDI) -> bool:
	var bend := ev.message == MIDI_MESSAGE_PITCH_BEND
	if not bend and ev.message != MIDI_MESSAGE_CONTROL_CHANGE:
		return false
	var value := ev.pitch / 16383.0 if bend else ev.controller_value / 127.0
	if _learning >= 0:
		var f := faders[_learning]
		f.midi_bend = bend
		f.midi_cc = -1 if bend else ev.controller_number
		f.midi_channel = ev.channel
		var i := _learning
		_learning = -1
		set_level(i, value)
		learned.emit(i)
		faders_changed.emit()
		return true
	var used := false
	for i in range(faders.size()):
		var f := faders[i]
		var hit := f.midi_bend if bend else (not f.midi_bend and f.midi_cc == ev.controller_number)
		if hit and (f.midi_channel < 0 or f.midi_channel == ev.channel):
			set_level(i, value)
			used = true
	return used


# --------------------------------------------------------------- OUTPUT --

## Per universe {channel: true}: every patched fixture's intensity
## channels — its DIMMER (not a fine channel), or with no DIMMER its
## colour / white channels.
func intensity_channels(n: int) -> Array:
	var fixtures: Array = fixtures_provider.call() if fixtures_provider.is_valid() else []
	return intensity_map(fixtures, n)


static func intensity_map(fixtures: Array, n: int, only: Dictionary = {}) -> Array:
	var out: Array = []
	for i in range(n):
		out.append({})
	for fx in fixtures:
		var u: int = fx["u"]
		if u < 0 or u >= n or (not only.is_empty() and not only.has(String(fx["uid"]))):
			continue
		var profile: FixtureProfile = fx["profile"]
		var chans := profile.channels_for_mode(int(fx.get("mode", 0)))
		var start: int = fx["start"]
		var dims: Array = []
		var colours: Array = []
		for k in range(chans.size()):
			if bool(chans[k].get("fine", false)):
				continue
			var role := String(chans[k]["role"])
			if role == "DIMMER":
				dims.append(k)
			elif role in _INTENSITY_ROLES:
				colours.append(k)
		for k in (dims if not dims.is_empty() else colours):
			out[u][start + int(k)] = true
	return out


## The cue faders' layer (ArtNet.layer_providers): n {channel: value}.
func layer(n: int) -> Array:
	var out: Array = []
	for i in range(n):
		out.append({})
	var looks: Array = []                 # [look, level]
	for f in faders:
		if f.kind != KIND_CUE or f.level <= 0.0 or not f.target.is_valid_int():
			continue
		var look: Array = cue_look_provider.call(int(f.target)) if cue_look_provider.is_valid() else []
		if not look.is_empty():
			looks.append([look, f.level])
	if looks.is_empty():
		return out
	var bases: Array = []
	for i in range(n):
		var u := ArtNet.get_universe(i)
		bases.append(u.dmx_data if u != null else PackedByteArray())
	return cue_output(looks, intensity_channels(n), bases, n)


## Cue submasters: `looks` is [[look, level], ...]. Intensity channels
## (`intensity`, per universe) scaled by their fader, highest wins over
## each other and the stage (`bases`); every other channel a look holds
## goes to its value (the highest fader's, where looks share one).
static func cue_output(looks: Array, intensity: Array, bases: Array, n: int) -> Array:
	var out: Array = []
	for i in range(n):
		out.append({})
	var others_level: Array = []          # per universe: channel -> the level that set it
	for i in range(n):
		others_level.append({})
	for entry in looks:
		var look: Array = entry[0]
		var lvl: float = entry[1]
		for u in range(mini(n, look.size())):
			var d: Dictionary = look[u] if look[u] is Dictionary else {}
			var inten: Dictionary = intensity[u] if u < intensity.size() else {}
			var base: PackedByteArray = bases[u] if u < bases.size() else PackedByteArray()
			for k in d:
				var c := int(k)
				var v := clampi(int(d[k]), 0, 255)
				if inten.has(c):
					var scaled := int(round(v * lvl))
					var b := int(base[c]) if c < base.size() else 0
					out[u][c] = maxi(maxi(int(out[u].get(c, 0)), scaled), b)
				elif lvl > float(others_level[u].get(c, -1.0)):
					out[u][c] = v
					others_level[u][c] = lvl
	return out


## The group masters' scale layer (ArtNet.scale_providers): n
## {channel: factor}, the lowest group fader over each of a group's
## fixtures' intensity channels.
func scale_layer(n: int) -> Array:
	var out: Array = []
	for i in range(n):
		out.append({})
	var groups: Array = groups_provider.call() if groups_provider.is_valid() else []
	var fixtures: Array = []
	for f in faders:
		if f.kind != KIND_GROUP or f.level >= 1.0:
			continue
		var members := {}
		for g in groups:
			if String(g["name"]).to_lower() == f.target.strip_edges().to_lower():
				for m in g["members"]:
					members[String(m)] = true
		if members.is_empty():
			continue
		if fixtures.is_empty() and fixtures_provider.is_valid():
			fixtures = fixtures_provider.call()
		var chans := intensity_map(fixtures, n, members)
		for u in range(n):
			for c in chans[u]:
				out[u][c] = minf(float(out[u].get(c, 1.0)), f.level)
	return out


# ------------------------------------------------------------ SHOW FILE --

func to_dict() -> Dictionary:
	var arr: Array = []
	for f in faders:
		arr.append(f.to_dict())
	return {"faders": arr}


func from_dict(d: Dictionary) -> void:
	clear()
	for e in d.get("faders", []):
		if e is Dictionary and faders.size() < MAX_FADERS:
			faders.append(Fader.from_dict(e))
	for i in range(faders.size()):
		set_level(i, faders[i].level)     # a chase fader that's up runs its chase
	faders_changed.emit()
