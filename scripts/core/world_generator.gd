class_name WorldGenerator
extends RefCounted
## Генератор мира: рельеф, горы, пещеры, руда, деревья.
## Работает в отдельном потоке (WorkerThreadPool), чтобы игра не зависала,
## пока создаётся мир. Поэтому здесь нельзя трогать узлы сцены — только данные.

var world_seed := 12345
var size_chunks := 6
var height := 64
var base_height := 24    ## средняя высота земли
var sand_level := 20     ## ниже этой высоты вместо травы песок
var caves_enabled := true
var trees_chance := 0.012

## Прогресс 0..1 — его читает основной поток, чтобы показать полоску загрузки.
var progress := 0.0
var stage_text := "Готовимся…"


func generate(data: WorldData) -> void:
	var size := size_chunks * WorldData.CHUNK_SIZE
	data.setup(size, size, height)
	data.world_seed = world_seed

	var height_noise := FastNoiseLite.new()
	height_noise.seed = world_seed
	height_noise.frequency = 0.008
	height_noise.fractal_octaves = 4

	var mountain_noise := FastNoiseLite.new()
	mountain_noise.seed = world_seed + 1
	mountain_noise.frequency = 0.005

	var cave_noise := FastNoiseLite.new()
	cave_noise.seed = world_seed + 2
	cave_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	cave_noise.frequency = 0.045
	cave_noise.fractal_type = FastNoiseLite.FRACTAL_NONE

	# --- Шаг 1: рельеф ---
	stage_text = "Создаём рельеф…"
	var blocks := data.blocks # это ссылка на тот же массив, а не копия
	for z in size:
		for x in size:
			_generate_column(blocks, data, x, z, height_noise, mountain_noise, cave_noise)
		progress = 0.8 * (z + 1) / size

	# --- Шаг 2: руда ---
	stage_text = "Прячем руду…"
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed + 3
	var area := size * size
	_veins(data, rng, Blocks.COAL_ORE, int(area / 110.0), 4, 9, 2, base_height)
	_veins(data, rng, Blocks.IRON_ORE, int(area / 220.0), 3, 7, 2, base_height - 8)
	data.recompute_all_columns()
	progress = 0.9

	# --- Шаг 3: деревья ---
	stage_text = "Сажаем деревья…"
	for z in range(2, size - 2):
		for x in range(2, size - 2):
			var top := data.get_column_top(x, z)
			if top <= 0 or data.get_block(x, top, z) != Blocks.GRASS:
				continue
			if rng.randf() < trees_chance:
				_tree(data, x, top, z, rng)
	data.recompute_all_columns()
	progress = 1.0
	stage_text = "Готово"


func _terrain_height(x: int, z: int, height_noise: FastNoiseLite, mountain_noise: FastNoiseLite) -> int:
	var h := base_height + height_noise.get_noise_2d(x, z) * 10.0
	var m := mountain_noise.get_noise_2d(x, z)
	if m > 0.1:
		h += (m - 0.1) * 45.0 # горы
	return clampi(int(h), 3, height - 12)


func _generate_column(blocks: PackedByteArray, data: WorldData, x: int, z: int,
		height_noise: FastNoiseLite, mountain_noise: FastNoiseLite, cave_noise: FastNoiseLite) -> void:
	var h := _terrain_height(x, z, height_noise, mountain_noise)
	var base := data.index_of(x, 0, z)
	var top_block := Blocks.GRASS
	var filler := Blocks.DIRT
	if h <= sand_level:
		top_block = Blocks.SAND
		filler = Blocks.SAND
	for y in h + 1:
		var id: int
		if y == 0:
			id = Blocks.BEDROCK
		elif y < h - 3:
			id = Blocks.STONE
		elif y < h:
			id = filler
		else:
			id = top_block
		# Пещеры: там, где шум больше порога, вырезаем пустоту.
		if caves_enabled and y > 1:
			var threshold := 0.55 if y < h - 4 else 0.72 # у поверхности пещер меньше
			if cave_noise.get_noise_3d(x, y * 1.4, z) > threshold:
				id = Blocks.AIR
		blocks[base + y] = id


func _veins(data: WorldData, rng: RandomNumberGenerator, ore: int, count: int,
		min_len: int, max_len: int, min_y: int, max_y: int) -> void:
	for v in count:
		var p := Vector3i(rng.randi_range(0, data.size_x - 1), rng.randi_range(min_y, max_y), rng.randi_range(0, data.size_z - 1))
		for i in rng.randi_range(min_len, max_len):
			if data.get_block(p.x, p.y, p.z) == Blocks.STONE:
				data.set_block_raw(p.x, p.y, p.z, ore)
			match rng.randi() % 6:
				0: p.x += 1
				1: p.x -= 1
				2: p.y += 1
				3: p.y -= 1
				4: p.z += 1
				5: p.z -= 1


func _tree(data: WorldData, x: int, ground: int, z: int, rng: RandomNumberGenerator) -> void:
	var trunk := rng.randi_range(4, 6)
	if ground + trunk + 2 >= data.height:
		return
	data.set_block_raw(x, ground, z, Blocks.DIRT)
	for i in range(1, trunk + 1):
		data.set_block_raw(x, ground + i, z, Blocks.WOOD)
	var top := ground + trunk
	for dy in range(-2, 2):
		var r := 2 if dy < 0 else 1
		for dx in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if absi(dx) == r and absi(dz) == r and (dy >= 0 or rng.randf() < 0.5):
					continue # срезаем углы кроны
				var px := x + dx
				var py := top + dy
				var pz := z + dz
				if data.is_inside(px, py, pz) and data.get_block(px, py, pz) == Blocks.AIR:
					data.set_block_raw(px, py, pz, Blocks.LEAVES)
