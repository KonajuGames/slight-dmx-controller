class_name WaveHeatmap
extends Control
## The whole analysed song as a colour-coded waveform: bar height is the
## loudness envelope, hue is the spectral balance (bass amber, mid green,
## air blue). Section tints behind it and downbeat ticks line it up with
## the structure strip. Click anywhere to seek.

signal seek_requested(seconds: float)

var analysis: SongAnalysis
var song_pos := 0.0

const _LO := Color(1.00, 0.62, 0.20)     # bass
const _MID := Color(0.35, 0.80, 0.42)    # mid
const _HI := Color(0.40, 0.72, 1.00)     # air
const _IMG_H := 128

var _tex: ImageTexture
var _built_w := -1


func _ready() -> void:
	custom_minimum_size = Vector2(0, 92)
	mouse_filter = Control.MOUSE_FILTER_STOP


func set_analysis(a: SongAnalysis) -> void:
	analysis = a
	_tex = null
	_built_w = -1
	queue_redraw()


func _dur() -> float:
	return maxf(analysis.duration, 0.001) if analysis != null else 1.0


func _draw() -> void:
	var w := size.x
	var h := size.y

	if analysis == null or not analysis.has_wave():
		draw_rect(Rect2(0, 0, w, h), Color(0.10, 0.10, 0.13))
		draw_string(ThemeDB.fallback_font, Vector2(8, h * 0.5 + 4),
			"analyse a song to see its waveform",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.5, 0.5, 0.55))
		return

	var dur := _dur()

	for sec in analysis.sections:
		var x0: float = float(sec["start"]) / dur * w
		var x1: float = float(sec["end"]) / dur * w
		var tint: Color = StructureBar.LABEL_HUE.get(
			String(sec["label"]), Color(0.3, 0.3, 0.35))
		tint.a = 0.16
		draw_rect(Rect2(x0, 0, maxf(x1 - x0, 1.0), h), tint)

	if _tex == null or _built_w != int(w):
		_rebuild(maxi(int(w), 1))
	if _tex != null:
		draw_texture_rect(_tex, Rect2(0, 0, w, h), false)

	for db in analysis.downbeats:
		var x: float = float(db) / dur * w
		draw_line(Vector2(x, h - 4), Vector2(x, h), Color(1, 1, 1, 0.22), 1.0)

	var px: float = clampf(song_pos / dur, 0.0, 1.0) * w
	draw_line(Vector2(px, 0), Vector2(px, h), Color(1, 1, 1, 0.9), 2.0)


func _rebuild(w: int) -> void:
	_built_w = w
	_tex = null
	var lo := analysis.wave_lo
	var mid := analysis.wave_mid
	var hi := analysis.wave_hi
	var pk := analysis.wave_peak
	var n := pk.size()
	if n == 0:
		return

	var img := Image.create_empty(w, _IMG_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var mid_y := _IMG_H / 2
	for x in range(w):
		var s := clampi(int(float(x) / w * n), 0, n - 1)
		# sharpen the dominant band so bass / air read, not a mid wall
		var l := lo[s] * lo[s] * 1.3
		var m := mid[s] * mid[s]
		var a := hi[s] * hi[s] * 1.3
		var sum := l + m + a
		var col := Color(0.55, 0.55, 0.6)
		if sum > 0.0001:
			col = (_LO * l + _MID * m + _HI * a) / sum
		var amp := sqrt(clampf(pk[s], 0.0, 1.0))
		var half := int(amp * (mid_y - 1))
		for dy in range(half + 1):
			var fade := 1.0 - 0.4 * float(dy) / maxf(half, 1.0)
			var c := Color(col.r, col.g, col.b, fade)
			img.set_pixel(x, mid_y - dy, c)
			img.set_pixel(x, mini(_IMG_H - 1, mid_y + dy), c)
	_tex = ImageTexture.create_from_image(img)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT and analysis != null:
		seek_requested.emit(clampf(event.position.x / size.x, 0.0, 1.0) * _dur())
