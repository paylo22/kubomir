class_name Hotbar
extends Control
## Панель быстрого доступа: 9 ячеек с блоками, одна выбрана.
## Рисуется вручную в _draw() — так проще, чем собирать из кучи узлов.

signal selection_changed(index: int)

const SLOT := 64.0 # размер ячейки
const GAP := 6.0

var items: Array[int] = [
	Blocks.GRASS, Blocks.DIRT, Blocks.STONE, Blocks.COBBLESTONE,
	Blocks.PLANKS, Blocks.WOOD, Blocks.LEAVES, Blocks.SAND, Blocks.GRAVEL,
]
var selected := 0
var atlas: Texture2D


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(items.size() * (SLOT + GAP) - GAP, SLOT)
	size = custom_minimum_size


func select(index: int) -> void:
	selected = posmod(index, items.size()) # по кругу: после последней — первая
	queue_redraw()
	selection_changed.emit(selected)


func get_selected_block() -> int:
	return items[selected]


## Номер ячейки под точкой экрана (для пальца), или -1.
func get_slot_at(screen_pos: Vector2) -> int:
	if not visible:
		return -1
	var local := screen_pos - global_position
	if local.y < 0 or local.y > SLOT:
		return -1
	var i := floori(local.x / (SLOT + GAP))
	if i < 0 or i >= items.size():
		return -1
	return i


func _draw() -> void:
	for i in items.size():
		var r := Rect2(i * (SLOT + GAP), 0, SLOT, SLOT)
		draw_rect(r, Color(0, 0, 0, 0.45))
		if atlas:
			draw_texture_rect_region(atlas, r.grow(-10), BlockTextures.get_icon_region(items[i]))
		if i == selected:
			draw_rect(r, Color(1, 1, 1, 0.95), false, 4.0)
		else:
			draw_rect(r, Color(1, 1, 1, 0.25), false, 2.0)
