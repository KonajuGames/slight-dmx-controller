class_name Spectrogram
extends Control
## A scrolling FFT heat-map. Each frame it pulls one column of band
## magnitudes (0..1, low → high) from `source` and scrolls the rest left.
## Used for the live input in Sound Reactive and the playing song in Auto
## Show.

var source := Callable()          ## func() -> PackedFloat32Array
var beat_source := Callable()      ## optional func() -> float (0..1 flash)
var bands := 32
var history := 160

var _img: Image
var _tex: ImageTexture
var _write := 0
var _any := false

const _HEAT := [
	Color(0.02, 0.02, 0.07), Color(0.16, 0.05, 0.38), Color(0.45, 0.06, 0.52),
	Color(0.82, 0.16, 0.40), Color(0.98, 0.48, 0.15), Color(1.0, 0.86, 0.32),
	Color(1.0, 1.0, 0.96),
]


func _ready() -> void:
	custom_minimum_size = Vector2(0, 104)
	_img = Image.create_empty(history, bands, false, Image.FORMAT_RGB8)
	_img.fill(_HEAT[0])
	_tex = ImageTexture.create_from_image(_img)
	set_process(true)


func _process(_delta: float) -> void:
	if not is_visible_in_tree() or not source.is_valid():
		return
	var col: PackedFloat32Array = source.call()
	var lit := false
	for y in range(bands):
		var v: float = col[y] if y < col.size() else 0.0
		if v > 0.01:
			lit = true
		_img.set_pixel(_write, bands - 1 - y, _heat(v))
	_any = _any or lit
	_write = (_write + 1) % history
	_tex.update(_img)
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	if not _any:
		draw_rect(Rect2(0, 0, w, h), _HEAT[0])
		var f := ThemeDB.fallback_font
		draw_string(f, Vector2(8, h * 0.5 + 4), "no signal",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.5, 0.5, 0.55))
		return

	# newest column sits at the right edge; the ring seam is at `_write`
	var older := history - _write
	var split := w * older / float(history)
	if older > 0:
		draw_texture_rect_region(_tex, Rect2(0, 0, split, h),
			Rect2(_write, 0, older, bands))
	if _write > 0:
		draw_texture_rect_region(_tex, Rect2(split, 0, w - split, h),
			Rect2(0, 0, _write, bands))

	if beat_source.is_valid():
		var b: float = beat_source.call()
		if b > 0.02:
			draw_rect(Rect2(0, 0, w, h), Color(1, 1, 1, 0.3 * b), false, 2.0)


func _heat(v: float) -> Color:
	v = clampf(sqrt(clampf(v, 0.0, 1.0)), 0.0, 1.0)   # gamma for contrast
	var f := v * (_HEAT.size() - 1)
	var i := int(f)
	if i >= _HEAT.size() - 1:
		return _HEAT[_HEAT.size() - 1]
	return _HEAT[i].lerp(_HEAT[i + 1], f - i)
