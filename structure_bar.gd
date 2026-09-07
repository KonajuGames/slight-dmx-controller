class_name StructureBar
extends Control
## The analysed song structure as a horizontal strip: one coloured block
## per section (Intro / Verse / Chorus / …), faint downbeat ticks, and a
## playhead. Click anywhere to seek.

signal seek_requested(seconds: float)

var analysis: SongAnalysis
var song_pos := 0.0

const _LABEL_HUE := {
	"Intro": Color(0.20, 0.35, 0.75), "Verse": Color(0.20, 0.55, 0.55),
	"Chorus": Color(0.85, 0.45, 0.15), "Bridge": Color(0.55, 0.25, 0.70),
	"Build": Color(0.55, 0.55, 0.58), "Drop": Color(0.80, 0.20, 0.20),
	"Outro": Color(0.22, 0.28, 0.55),
}


func _ready() -> void:
	custom_minimum_size = Vector2(0, 46)
	mouse_filter = Control.MOUSE_FILTER_STOP


func set_analysis(a: SongAnalysis) -> void:
	analysis = a
	queue_redraw()


func _dur() -> float:
	return maxf(analysis.duration, 0.001) if analysis != null else 1.0


func _draw() -> void:
	var w := size.x
	var h := size.y
	var f := ThemeDB.fallback_font

	if analysis == null or analysis.sections.is_empty():
		draw_rect(Rect2(0, 0, w, h), Color(0.12, 0.12, 0.14))
		draw_string(f, Vector2(8, h * 0.5 + 4), "analyse a song to see its structure",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.5, 0.5, 0.55))
		return

	var dur := _dur()
	for sec in analysis.sections:
		var x0: float = float(sec["start"]) / dur * w
		var x1: float = float(sec["end"]) / dur * w
		var base: Color = _LABEL_HUE.get(String(sec["label"]), Color(0.3, 0.3, 0.35))
		var col := base.lerp(base.lightened(0.35), clampf(float(sec["energy"]), 0.0, 1.0))
		draw_rect(Rect2(x0, 0, maxf(x1 - x0, 1.0), h), col)
		draw_line(Vector2(x0, 0), Vector2(x0, h), Color(0, 0, 0, 0.35), 1.0)
		if x1 - x0 > 34.0:
			draw_string(f, Vector2(x0 + 4, h * 0.5 + 4), String(sec["label"]),
				HORIZONTAL_ALIGNMENT_LEFT, x1 - x0 - 6, 11, Color(1, 1, 1, 0.9))

	for db in analysis.downbeats:
		var x: float = float(db) / dur * w
		draw_line(Vector2(x, h - 5), Vector2(x, h), Color(1, 1, 1, 0.25), 1.0)

	var px: float = clampf(song_pos / dur, 0.0, 1.0) * w
	draw_line(Vector2(px, 0), Vector2(px, h), Color(1, 1, 1, 0.9), 2.0)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT and analysis != null:
		seek_requested.emit(clampf(event.position.x / size.x, 0.0, 1.0) * _dur())
