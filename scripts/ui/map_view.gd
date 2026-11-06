class_name MapView
extends Control
## Окно карты: рисует картинку мира и стрелку — где ты и куда смотришь.

var texture: Texture2D
var marker_uv := Vector2(0.5, 0.5) ## положение игрока на карте (0..1)
var yaw := 0.0                     ## поворот игрока


func _ready() -> void:
	custom_minimum_size = Vector2(500, 500)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func show_player(uv: Vector2, player_yaw: float) -> void:
	marker_uv = uv
	yaw = player_yaw
	queue_redraw()


func _draw() -> void:
	var side := minf(size.x, size.y)
	var rect := Rect2((size - Vector2(side, side)) / 2.0, Vector2(side, side))
	draw_rect(rect.grow(4), Color(0, 0, 0, 0.6))
	if texture:
		draw_texture_rect(texture, rect, false)
	# Стрелка игрока: острый конец смотрит туда же, куда камера (север — вверх)
	var c := rect.position + marker_uv * rect.size
	var dir := Vector2(-sin(yaw), -cos(yaw))
	var perp := Vector2(-dir.y, dir.x)
	var pts := PackedVector2Array([c + dir * 16, c + perp * 9 - dir * 9, c - perp * 9 - dir * 9])
	draw_colored_polygon(pts, Color(1, 0.25, 0.2))
	pts.append(pts[0])
	draw_polyline(pts, Color.WHITE, 2.0)
	draw_string(ThemeDB.fallback_font, rect.position + Vector2(rect.size.x / 2 - 6, 26), "С",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(1, 1, 1, 0.85))
