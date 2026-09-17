class_name VideoRec
extends RefCounted
## Records a frame stream to an `.mp4` (H.264, + an MP3 audio track) via the
## optional `native` GDExtension (minih264 + minimp4 + shine). Build it with
## `addons/native/build.py`. Without it, this falls back to a numbered
## PNG sequence + an `assemble.txt` holding the ffmpeg line — the old
## behaviour (silent; there's no equivalent audio fallback).
##
## The audio track is whatever's actually audible: an `AudioEffectCapture`
## on the Master bus (mixed there since Godot has no "sum everything"
## bus tap otherwise) picks up AutoShow's music, and `Sound`'s own capture
## (see sound_engine.gd) picks up the mic/line-in — deliberately muted out
## of Master so it doesn't feed back through speakers, so it needs its own
## tap. `pull_audio()` mixes the two and feeds the recorder every frame;
## call it continuously (not throttled to FPS like push()) or the capture
## buffers fill and start dropping the oldest audio.

const FPS := 30

var _rec = null              # VideoRecorder (extension present)
var _png_dir := ""
var _png_frame := 0
var _w := 0
var _h := 0
var _out := ""

var _master_cap: AudioEffectCapture = null
var _master_fx_idx := -1


static func available() -> bool:
	return ClassDB.class_exists("VideoRecorder")


## Start recording into `out_dir`. Returns the output path (an .mp4 file,
## or a folder for the PNG fallback), or "" on failure.
func start(out_dir: String, w: int, h: int, kbps := 12000) -> String:
	# multiple of 16 for the mp4 encoder (the H.264 chroma stride must stay
	# 8-aligned); the PNG fallback is happy with anything even.
	var step := 16 if available() else 2
	_w = w - (w % step)
	_h = h - (h % step)
	if _w < 16 or _h < 16:
		return ""
	DirAccess.make_dir_recursive_absolute(out_dir)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")

	if available():
		_rec = ClassDB.instantiate("VideoRecorder")
		_out = out_dir.path_join("rec_%s.mp4" % stamp)
		if _rec != null and _rec.start(ProjectSettings.globalize_path(_out), _w, _h, FPS, kbps):
			_start_audio()
			return _out
		_rec = null

	_png_dir = out_dir.path_join("rec_%s" % stamp)
	DirAccess.make_dir_recursive_absolute(_png_dir)
	var h2 := FileAccess.open(_png_dir.path_join("assemble.txt"), FileAccess.WRITE)
	if h2:
		h2.store_string("ffmpeg -framerate %d -i frame_%%05d.png -c:v libx264 -pix_fmt yuv420p out.mp4\n" % FPS)
		h2.close()
	_png_frame = 0
	_out = _png_dir
	return _out


func push(img: Image) -> void:
	if img == null or not is_recording():
		return
	if img.get_width() != _w or img.get_height() != _h:
		img.resize(_w, _h)
	if _rec != null:
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		_rec.push_frame(img.get_data())
	else:
		img.save_png(_png_dir.path_join("frame_%05d.png" % _png_frame))
		_png_frame += 1


## Finalise and return a short status line.
func stop() -> String:
	if _rec != null:
		_rec.stop()
		var s := String(_rec.get_status())
		_rec = null
		_stop_audio()
		return s
	var n := _png_frame
	_png_dir = ""
	return "%d PNG frames — run assemble.txt" % n


func is_recording() -> bool:
	return _rec != null or _png_dir != ""


func frame_count() -> int:
	return int(_rec.get_frame_count()) if _rec != null else _png_frame


func is_mp4() -> bool:
	return _rec != null


func _start_audio() -> void:
	var cap := AudioEffectCapture.new()
	cap.buffer_length = 0.5
	AudioServer.add_bus_effect(0, cap)   # bus 0 = Master
	_master_fx_idx = AudioServer.get_bus_effect_count(0) - 1
	# get_bus_effect(), not get_bus_effect_instance(): AudioEffectCapture is
	# unlike most effects -- get_buffer()/get_frames_available() live on the
	# effect resource itself, not the separate AudioEffectCaptureInstance
	# get_bus_effect_instance() returns (which doesn't have them at all).
	_master_cap = AudioServer.get_bus_effect(0, _master_fx_idx)
	_rec.start_audio(AudioServer.get_mix_rate(), 2)


func _stop_audio() -> void:
	if _master_fx_idx >= 0:
		AudioServer.remove_bus_effect(0, _master_fx_idx)
		_master_fx_idx = -1
	_master_cap = null


## Mixes the Master-bus tap (AutoShow playback) with Sound's mic/line-in
## tap and feeds the result to the encoder. Call every frame while
## recording (not just on the FPS-throttled cadence push() uses) so
## neither AudioEffectCapture's buffer fills up and starts dropping audio.
func pull_audio() -> void:
	if _rec == null or _master_cap == null:
		return
	var mic_n := Sound.capture_frames_available()
	var master_n := _master_cap.get_frames_available()
	var n: int = mini(master_n, mic_n) if mic_n > 0 else master_n
	if n <= 0:
		return
	var master_buf := _master_cap.get_buffer(n)
	var mixed := PackedFloat32Array()
	mixed.resize(n * 2)
	if mic_n > 0:
		var mic_buf := Sound.pull_capture(n)
		for i in range(n):
			mixed[i * 2] = clampf(master_buf[i].x + mic_buf[i].x, -1.0, 1.0)
			mixed[i * 2 + 1] = clampf(master_buf[i].y + mic_buf[i].y, -1.0, 1.0)
	else:
		for i in range(n):
			mixed[i * 2] = master_buf[i].x
			mixed[i * 2 + 1] = master_buf[i].y
	_rec.push_audio(mixed)
