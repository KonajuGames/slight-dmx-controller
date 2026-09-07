extends Node
## Autoload singleton: "Sound"
##
## Captures an audio input (microphone / line-in) and exposes smoothed
## frequency-band energies plus beat detection, for the "Sound Reactive"
## run mode. SoundReactor and beat-synced chases read these each frame;
## the SoundPanel shows the live meters and owns the settings.
##
## Idle (active == false) it does nothing and every value decays to 0, so
## it is always safe to read.

signal beat                       ## emitted on the frame a beat is detected
signal devices_changed

const BUS_NAME := "SoundReactive"

## Frequency splits (Hz) for the three bands.
const BASS_HZ := Vector2(20.0, 250.0)
const MID_HZ := Vector2(250.0, 2000.0)
const TREBLE_HZ := Vector2(2000.0, 16000.0)

## Magnitudes below MIN_DB read as 0, at 0 dB they read as 1.
const MIN_DB := -60.0

var active := false: set = _set_active
var input_device := ""            ## "" = system default
var gain := 1.0                   ## 0.25 .. 4 — trim on the raw signal
var beat_sensitivity := 1.4       ## instantaneous bass / rolling average to fire
var response := 0.5               ## 0 = smooth/laggy, 1 = snappy

# live, 0..1, read every frame -----------------------------------------
var level := 0.0
var bass := 0.0
var mid := 0.0
var treble := 0.0
var beat_pulse := 0.0             ## 1.0 on a beat, decays back to 0

var _player: AudioStreamPlayer
var _analyzer: AudioEffectSpectrumAnalyzerInstance
var _bass_hist := PackedFloat32Array()
var _hist_len := 50
var _hist_i := 0
var _beat_cooldown := 0.0
var _bus_idx := -1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	_bass_hist.resize(_hist_len)


func input_devices() -> PackedStringArray:
	return AudioServer.get_input_device_list()


func _set_active(v: bool) -> void:
	if v == active:
		return
	active = v
	if active:
		_start()
	else:
		_stop()


func _start() -> void:
	if AudioServer.input_device != input_device and input_device != "":
		AudioServer.input_device = input_device

	if _bus_idx < 0:
		_bus_idx = AudioServer.bus_count
		AudioServer.add_bus(_bus_idx)
		AudioServer.set_bus_name(_bus_idx, BUS_NAME)
		AudioServer.set_bus_mute(_bus_idx, true)   # never monitor the mic
		var an := AudioEffectSpectrumAnalyzer.new()
		an.buffer_length = 0.15
		an.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_2048
		AudioServer.add_bus_effect(_bus_idx, an)

	_analyzer = AudioServer.get_bus_effect_instance(_bus_idx, 0)

	if _player == null:
		_player = AudioStreamPlayer.new()
		_player.stream = AudioStreamMicrophone.new()
		_player.bus = BUS_NAME
		add_child(_player)
	_player.play()


func _stop() -> void:
	if _player:
		_player.stop()
	level = 0.0
	bass = 0.0
	mid = 0.0
	treble = 0.0
	beat_pulse = 0.0
	for i in range(_hist_len):
		_bass_hist[i] = 0.0


func set_device(name: String) -> void:
	input_device = name
	if name != "":
		AudioServer.input_device = name
	if active:
		_stop()
		_start()


func _process(delta: float) -> void:
	beat_pulse = maxf(0.0, beat_pulse - delta * 3.5)
	_beat_cooldown = maxf(0.0, _beat_cooldown - delta)

	if not active or _analyzer == null:
		var d := clampf(delta * 6.0, 0.0, 1.0)
		level = lerpf(level, 0.0, d)
		bass = lerpf(bass, 0.0, d)
		mid = lerpf(mid, 0.0, d)
		treble = lerpf(treble, 0.0, d)
		return

	var b := _band(BASS_HZ)
	var m := _band(MID_HZ)
	var t := _band(TREBLE_HZ)
	var l: float = clampf(maxf(b, maxf(m, t)) * 0.6 + (b + m + t) / 3.0 * 0.7, 0.0, 1.0)

	# asymmetric smoothing: rise fast, fall slow (looks like light chasing sound)
	var up := clampf(lerpf(0.35, 0.95, response) * delta * 60.0, 0.0, 1.0)
	var down := clampf(lerpf(0.04, 0.30, response) * delta * 60.0, 0.0, 1.0)
	bass = _slew(bass, b, up, down)
	mid = _slew(mid, m, up, down)
	treble = _slew(treble, t, up, down)
	level = _slew(level, l, up, down)

	_detect_beat(b, delta)


func _slew(cur: float, target: float, up: float, down: float) -> float:
	return lerpf(cur, target, up if target > cur else down)


## Linear magnitude for a Hz range, mapped MIN_DB..0 dB -> 0..1, times gain.
func _band(hz: Vector2) -> float:
	if _analyzer == null:
		return 0.0
	var mag := _analyzer.get_magnitude_for_frequency_range(
		hz.x, hz.y, AudioEffectSpectrumAnalyzerInstance.MAGNITUDE_MAX)
	var lin: float = (mag.x + mag.y) * 0.5
	if lin <= 0.00001:
		return 0.0
	var db: float = linear_to_db(lin) + 6.0   # +6: line level rarely hits 0 dBFS
	return clampf((db - MIN_DB) / -MIN_DB, 0.0, 1.0) * gain


## `n` log-spaced band energies (0..1) from ~40 Hz to ~16 kHz, for the
## spectrogram. Empty / zeros when not active.
func spectrum(n := 40) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	if not active or _analyzer == null:
		return out
	var lo := 40.0
	var hi := 16000.0
	var ratio: float = pow(hi / lo, 1.0 / n)
	var f := lo
	for i in range(n):
		var f2 := f * ratio
		out[i] = _band(Vector2(f, f2))
		f = f2
	return out


func _detect_beat(inst_bass: float, _delta: float) -> void:
	var sum := 0.0
	for v in _bass_hist:
		sum += v
	var avg := sum / _hist_len

	_bass_hist[_hist_i] = inst_bass
	_hist_i = (_hist_i + 1) % _hist_len

	if _beat_cooldown <= 0.0 and inst_bass > 0.12 \
			and inst_bass > avg * beat_sensitivity and inst_bass > avg + 0.04:
		beat_pulse = 1.0
		_beat_cooldown = 0.11        # ~9 beats/sec ceiling
		beat.emit()
