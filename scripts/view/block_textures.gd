class_name BlockTextures
extends RefCounted
## Рисует текстуры блоков (пиксель-арт 16×16) прямо из кода —
## поэтому картинки в проект добавлять не нужно.
## Все текстуры лежат в одном «атласе»: длинной картинке из квадратиков.
## Какой квадратик на какой грани — написано в Blocks.TILES.

const TILE_SIZE := 16
const CRACK_STAGES := 5


## Создаёт картинку атласа шириной T_COUNT*16 и высотой 16 пикселей.
static func create_atlas_image() -> Image:
	var img := Image.create_empty(Blocks.T_COUNT * TILE_SIZE, TILE_SIZE, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 777 # одинаковое число => текстуры каждый раз одинаковые

	_noise(img, Blocks.T_GRASS_TOP, Color(0.36, 0.62, 0.22), 0.07, rng)
	_noise(img, Blocks.T_DIRT, Color(0.53, 0.37, 0.23), 0.06, rng)
	_speckles(img, Blocks.T_DIRT, Color(0.40, 0.27, 0.16), 18, rng)
	_grass_side(img, rng)
	_noise(img, Blocks.T_STONE, Color(0.52, 0.52, 0.53), 0.05, rng)
	_speckles(img, Blocks.T_STONE, Color(0.42, 0.42, 0.43), 25, rng)
	_noise(img, Blocks.T_SAND, Color(0.87, 0.81, 0.57), 0.04, rng)
	_log_side(img, rng)
	_log_top(img, rng)
	_leaves(img, rng)
	_planks(img, rng)
	_cobble(img, rng)
	_ore(img, Blocks.T_COAL, Color(0.12, 0.12, 0.12), rng)
	_ore(img, Blocks.T_IRON, Color(0.85, 0.65, 0.50), rng)
	_bedrock(img, rng)
	_water(img, rng)
	_noise(img, Blocks.T_GRAVEL, Color(0.50, 0.47, 0.45), 0.04, rng)
	_pebbles(img, Blocks.T_GRAVEL, rng)
	return img


## Иконка блока для панели быстрого доступа (берём боковую текстуру).
static func get_icon_region(id: int) -> Rect2:
	var tile := Blocks.get_tile(id, 1)
	return Rect2(tile * TILE_SIZE, 0, TILE_SIZE, TILE_SIZE)


## Средний цвет боковой текстуры блока — для осколков при разрушении.
static func average_color(atlas: Image, id: int) -> Color:
	var tile := Blocks.get_tile(id, 1)
	var sum := Color(0, 0, 0, 0)
	var count := 0
	for y in TILE_SIZE:
		for x in TILE_SIZE:
			var c := atlas.get_pixel(tile * TILE_SIZE + x, y)
			if c.a > 0.5:
				sum += c
				count += 1
	if count == 0:
		return Color.WHITE
	return Color(sum.r / count, sum.g / count, sum.b / count, 1.0)


## Текстуры трещин: 5 стадий, от лёгких царапин до почти развалившегося блока.
## Трещины «растут» из нескольких точек: каждая следующая стадия продолжает
## те же линии и добавляет ответвления — поэтому разрушение выглядит постепенным.
static func create_crack_textures() -> Array[ImageTexture]:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
		Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1)]
	# Заранее прокладываем пути трещин (список пикселей), стадия берёт их начало.
	var paths: Array = []
	for crack in 7:
		var path: Array[Vector2i] = []
		var p := Vector2i(rng.randi_range(6, 9), rng.randi_range(6, 9)) # из середины блока
		var main_dir := (crack * 3) % 8 # трещины расходятся в разные стороны
		var d := main_dir
		for step in 26:
			if p.x < 0 or p.x >= TILE_SIZE or p.y < 0 or p.y >= TILE_SIZE:
				break # дошли до края блока
			path.append(p)
			if rng.randf() < 0.4: # трещина виляет, но держит общее направление
				d = (main_dir + [-1, 1][rng.randi() % 2] + 8) % 8
			else:
				d = main_dir
			p += dirs[d]
		paths.append(path)
	var result: Array[ImageTexture] = []
	for stage in CRACK_STAGES:
		var img := Image.create_empty(TILE_SIZE, TILE_SIZE, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))
		var cracks := 2 + stage          # сколько трещин видно
		var length := 4 + stage * 5      # и какой они длины
		for c in cracks:
			var path: Array = paths[c]
			for i in mini(length, path.size()):
				var px: Vector2i = path[i]
				img.set_pixel(px.x, px.y, Color(0.06, 0.05, 0.04, 0.8))
		# На последних стадиях блок ещё и темнеет — видно, что он вот-вот развалится
		if stage >= 3:
			for y in TILE_SIZE:
				for x in TILE_SIZE:
					if img.get_pixel(x, y).a == 0.0 and rng.randf() < 0.08 * (stage - 2):
						img.set_pixel(x, y, Color(0, 0, 0, 0.25))
		result.append(ImageTexture.create_from_image(img))
	return result


# --- Вспомогательные функции рисования ---------------------------------------

static func _px(img: Image, tile: int, x: int, y: int, c: Color) -> void:
	img.set_pixel(tile * TILE_SIZE + x, y, c)


static func _shade(c: Color, k: float) -> Color:
	return Color(clampf(c.r + k, 0, 1), clampf(c.g + k, 0, 1), clampf(c.b + k, 0, 1), c.a)


static func _noise(img: Image, tile: int, base: Color, amount: float, rng: RandomNumberGenerator) -> void:
	for y in TILE_SIZE:
		for x in TILE_SIZE:
			_px(img, tile, x, y, _shade(base, rng.randf_range(-amount, amount)))


static func _speckles(img: Image, tile: int, c: Color, count: int, rng: RandomNumberGenerator) -> void:
	for i in count:
		_px(img, tile, rng.randi() % TILE_SIZE, rng.randi() % TILE_SIZE, _shade(c, rng.randf_range(-0.03, 0.03)))


static func _grass_side(img: Image, rng: RandomNumberGenerator) -> void:
	_noise(img, Blocks.T_GRASS_SIDE, Color(0.53, 0.37, 0.23), 0.06, rng)
	_speckles(img, Blocks.T_GRASS_SIDE, Color(0.40, 0.27, 0.16), 14, rng)
	for x in TILE_SIZE:
		var depth := rng.randi_range(3, 5) # травинки свисают на разную глубину
		for y in depth:
			_px(img, Blocks.T_GRASS_SIDE, x, y, _shade(Color(0.36, 0.62, 0.22), rng.randf_range(-0.07, 0.05)))


static func _log_side(img: Image, rng: RandomNumberGenerator) -> void:
	for x in TILE_SIZE:
		var stripe := rng.randf_range(-0.05, 0.05)
		if x % 4 == 0:
			stripe -= 0.08
		for y in TILE_SIZE:
			_px(img, Blocks.T_LOG_SIDE, x, y, _shade(Color(0.42, 0.30, 0.17), stripe + rng.randf_range(-0.03, 0.03)))


static func _log_top(img: Image, rng: RandomNumberGenerator) -> void:
	var center := Vector2(7.5, 7.5)
	for y in TILE_SIZE:
		for x in TILE_SIZE:
			var d := Vector2(x, y).distance_to(center)
			var c: Color
			if d > 6.8:
				c = Color(0.42, 0.30, 0.17) # кора по краю
			elif int(d) % 2 == 0:
				c = Color(0.72, 0.56, 0.34) # годовые кольца
			else:
				c = Color(0.64, 0.48, 0.28)
			_px(img, Blocks.T_LOG_TOP, x, y, _shade(c, rng.randf_range(-0.03, 0.03)))


static func _leaves(img: Image, rng: RandomNumberGenerator) -> void:
	for y in TILE_SIZE:
		for x in TILE_SIZE:
			var c := _shade(Color(0.22, 0.50, 0.16), rng.randf_range(-0.09, 0.07))
			if rng.randf() < 0.18:
				c.a = 0.0 # дырочка — сквозь неё видно
			_px(img, Blocks.T_LEAVES, x, y, c)


static func _planks(img: Image, rng: RandomNumberGenerator) -> void:
	for y in TILE_SIZE:
		var board := floori(y / 4.0)
		var seam := (board * 7 + 3) % TILE_SIZE # где у доски стык
		for x in TILE_SIZE:
			var k := rng.randf_range(-0.03, 0.03) + (board % 2) * 0.03
			if y % 4 == 3 or x == seam:
				k -= 0.15
			_px(img, Blocks.T_PLANKS, x, y, _shade(Color(0.72, 0.55, 0.32), k))


static func _cobble(img: Image, rng: RandomNumberGenerator) -> void:
	# Камни: несколько случайных центров, каждый пиксель берёт цвет ближайшего.
	var points: Array[Vector2] = []
	var tones: Array[float] = []
	for i in 9:
		points.append(Vector2(rng.randf_range(0, 16), rng.randf_range(0, 16)))
		tones.append(rng.randf_range(-0.08, 0.08))
	for y in TILE_SIZE:
		for x in TILE_SIZE:
			var p := Vector2(x + 0.5, y + 0.5)
			var best := 999.0
			var second := 999.0
			var best_i := 0
			for i in points.size():
				var d := p.distance_to(points[i])
				if d < best:
					second = best
					best = d
					best_i = i
				elif d < second:
					second = d
			var c := _shade(Color(0.55, 0.55, 0.55), tones[best_i] + rng.randf_range(-0.03, 0.03))
			if second - best < 1.1:
				c = Color(0.30, 0.30, 0.31) # шов между камнями
			_px(img, Blocks.T_COBBLE, x, y, c)


static func _ore(img: Image, tile: int, ore_color: Color, rng: RandomNumberGenerator) -> void:
	_noise(img, tile, Color(0.52, 0.52, 0.53), 0.05, rng)
	for cluster in 5:
		var cx := rng.randi_range(2, 13)
		var cy := rng.randi_range(2, 13)
		for i in 4:
			var x := clampi(cx + rng.randi_range(-1, 1), 0, 15)
			var y := clampi(cy + rng.randi_range(-1, 1), 0, 15)
			_px(img, tile, x, y, _shade(ore_color, rng.randf_range(-0.05, 0.05)))


static func _bedrock(img: Image, rng: RandomNumberGenerator) -> void:
	for y in TILE_SIZE:
		for x in TILE_SIZE:
			var v := rng.randf_range(0.12, 0.42)
			_px(img, Blocks.T_BEDROCK, x, y, Color(v, v, v))


static func _water(img: Image, rng: RandomNumberGenerator) -> void:
	for y in TILE_SIZE:
		for x in TILE_SIZE:
			var wave := sin((x + y * 0.5) * 0.9) * 0.03
			_px(img, Blocks.T_WATER, x, y, _shade(Color(0.22, 0.45, 0.78), wave + rng.randf_range(-0.025, 0.025)))
	# светлые блики на поверхности
	for i in 10:
		var x := rng.randi_range(0, 13)
		var y := rng.randi_range(0, 15)
		for k in rng.randi_range(2, 3):
			_px(img, Blocks.T_WATER, x + k, y, Color(0.45, 0.66, 0.92))


static func _pebbles(img: Image, tile: int, rng: RandomNumberGenerator) -> void:
	for i in 26:
		var cx := rng.randi_range(0, 14)
		var cy := rng.randi_range(0, 14)
		var tone := rng.randf_range(-0.16, 0.12)
		var c := _shade(Color(0.52, 0.49, 0.47), tone)
		_px(img, tile, cx, cy, c)
		_px(img, tile, cx + 1, cy, c)
		_px(img, tile, cx, cy + 1, _shade(c, -0.06))
		_px(img, tile, cx + 1, cy + 1, _shade(c, -0.1))
