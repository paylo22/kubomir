class_name WorldMap
extends RefCounted
## Карта мира сверху: каждый пиксель — один столбец блоков.
## Цвет — от верхнего блока (трава, песок, камень…), вода — синяя, глубже — темнее.
## Рельеф подсвечен, как на настоящей карте: склоны с одной стороны светлее, с другой темнее.
## Строится в фоне при загрузке мира, потом обновляется по одному пикселю, когда меняются блоки.

const COLORS := {
	Blocks.GRASS: Color(0.36, 0.60, 0.24),
	Blocks.DIRT: Color(0.50, 0.36, 0.23),
	Blocks.STONE: Color(0.55, 0.55, 0.56),
	Blocks.SAND: Color(0.88, 0.82, 0.58),
	Blocks.WOOD: Color(0.42, 0.30, 0.17),
	Blocks.LEAVES: Color(0.18, 0.42, 0.14),
	Blocks.PLANKS: Color(0.72, 0.55, 0.32),
	Blocks.COBBLESTONE: Color(0.48, 0.48, 0.48),
	Blocks.COAL_ORE: Color(0.30, 0.30, 0.30),
	Blocks.IRON_ORE: Color(0.66, 0.56, 0.50),
	Blocks.BEDROCK: Color(0.20, 0.20, 0.20),
	Blocks.GRAVEL: Color(0.50, 0.47, 0.45),
}
const SHALLOW := Color(0.30, 0.62, 0.82)
const DEEP := Color(0.06, 0.18, 0.42)

var image: Image
var _data: WorldData


## Построить карту целиком (можно в фоновом потоке).
func build(data: WorldData) -> void:
	_data = data
	var img := Image.create_empty(data.size_x, data.size_z, false, Image.FORMAT_RGB8)
	for z in data.size_z:
		for x in data.size_x:
			img.set_pixel(x, z, column_color(x, z))
	image = img


## Перерисовать один столбец (после того как в нём сломали или поставили блок).
func update_column(x: int, z: int) -> void:
	if image == null or x < 0 or z < 0 or x >= _data.size_x or z >= _data.size_z:
		return
	image.set_pixel(x, z, column_color(x, z))


func column_color(x: int, z: int) -> Color:
	var sx := _data.size_x
	var col := x + z * sx
	var top := _data.top_any[col]
	if top < 0:
		return Color(0.05, 0.05, 0.06)
	var id := _data.get_block(x, top, z)
	if id == Blocks.WATER:
		var depth := top - _data.heightmap[col]
		return SHALLOW.lerp(DEEP, clampf(depth / 14.0, 0.0, 1.0))
	var c: Color = COLORS.get(id, Color(0.5, 0.5, 0.5))
	# Подсветка рельефа: сравниваем высоту с соседом на северо-западе
	var neighbor := _data.top_any[maxi(x - 1, 0) + maxi(z - 1, 0) * sx]
	var shade := 1.0 + clampf((top - neighbor) * 0.09, -0.25, 0.25)
	# Чем выше над морем — тем светлее
	shade *= 0.86 + clampf((top - _data.sea_level) / 40.0, 0.0, 0.3)
	return Color(clampf(c.r * shade, 0, 1), clampf(c.g * shade, 0, 1), clampf(c.b * shade, 0, 1))
