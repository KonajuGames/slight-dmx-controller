class_name VideoRec
extends RefCounted
## Records a frame stream to an `.mp4` (H.264) via the optional `video_rec`
## GDExtension (minih264 + minimp4). Build it with
## `addons/video_rec/build.py`. Without it, this falls back to a numbered
## PNG sequence + an `assemble.txt` holding the ffmpeg line — the old
## behaviour.

const FPS := 30

var _rec = null              # VideoRecorder (extension present)
var _png_dir := ""
var _png_frame := 0
var _w := 0
var _h := 0
var _out := ""


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
