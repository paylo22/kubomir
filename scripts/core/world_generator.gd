class_name WorldGenerator
extends RefCounted
## Генератор архипелага: острова разных типов посреди океана.
##
## Как он работает (по шагам — сервер запускает их по очереди):
##   prepare()     — расставляем острова на карте (быстро, в основном потоке);
##   heights_row() — для каждого столбца считаем высоту поверхности (ряды — параллельно);
##   fill_row()    — заполняем столбцы блоками: камень, земля, песок, вода, пещеры (параллельно);
##   finish()      — руда, деревья и точка появления (в одном фоновом потоке).
## Ряды мира не зависят друг от друга, поэтому их можно считать на всех ядрах сразу.
## Здесь нельзя трогать узлы сцены — только данные.

enum { ISLAND_BIG, ISLAND_MEDIUM, ISLAND_SANDY, ISLAND_ROCKY }
const KIND_NAMES := {
	ISLAND_BIG: "большой лесистый остров с горами",
	ISLAND_MEDIUM: "средний лесистый остров",
	ISLAND_SANDY: "песчаный островок",
	ISLAND_ROCKY: "скалистый остров",
}
const OCEAN := 255 ## «тип» столбца, где нет острова

## Шанс дерева на блоке травы для каждого типа острова.
const TREE_CHANCE := {ISLAND_BIG: 0.02, ISLAND_MEDIUM: 0.03, ISLAND_SANDY: 0.006, ISLAND_ROCKY: 0.004}

var world_seed := 12345
var size_chunks := 16
var height := 64
var sea_level := 22
var caves_enabled := true
var trees_multiplier := 1.0

## Что сейчас делаем и насколько готово (читает основной поток для экрана загрузки).
var stage_text := "Готовимся…"
var finish_progress := 0.0
## Острова: [{"cx", "cz": центр, "r": радиус, "kind": тип, "stretch": вытянутость, "cos"/"sin": поворот}, ...]
var islands: Array[Dictionary] = []

var _data: WorldData
var _size := 0
var _heights := PackedInt32Array()  # высота поверхности каждого столбца
var _kinds := PackedByteArray()     # тип острова каждого столбца (OCEAN — океан)
var _rows_done := PackedByteArray() # отметки готовых рядов: 1 — высоты, 2 — блоки
var _row_islands: Array = []        # для каждого ряда — острова, которые до него дотягиваются

var _coast_noise := FastNoiseLite.new()
var _bay_noise := FastNoiseLite.new()
var _hill_noise := FastNoiseLite.new()
var _ridge_noise := FastNoiseLite.new()
var _ocean_noise := FastNoiseLite.new()
var _cave_noise := FastNoiseLite.new()


# =============================================================================
#   Шаг 0: подготовка и расстановка островов
# =============================================================================

func prepare(data: WorldData) -> void:
	_data = data
	_size = size_chunks * WorldData.CHUNK_SIZE
	data.setup(_size, _size, height)
	data.world_seed = world_seed
	data.sea_level = sea_level

	_coast_noise.seed = world_seed
	_coast_noise.frequency = 0.035
	_coast_noise.fractal_octaves = 3
	_bay_noise.seed = world_seed + 6
	_bay_noise.frequency = 0.012 # крупные бухты и полуострова
	_hill_noise.seed = world_seed + 1
	_hill_noise.frequency = 0.03
	_hill_noise.fractal_octaves = 3
	_ridge_noise.seed = world_seed + 2
	_ridge_noise.frequency = 0.018
	_ridge_noise.fractal_octaves = 2
	_ocean_noise.seed = world_seed + 3
	_ocean_noise.frequency = 0.05
	_cave_noise.seed = world_seed + 4
	_cave_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_cave_noise.frequency = 0.045
	_cave_noise.fractal_type = FastNoiseLite.FRACTAL_NONE

	_place_islands()

	var columns := _size * _size
	_heights.resize(columns)
	_kinds.resize(columns)
	_rows_done.resize(_size)
	_rows_done.fill(0)
	# Для каждого ряда запоминаем, какие острова могут его касаться — так не придётся
	# для каждого блока проверять все острова мира.
	_row_islands.resize(_size)
	for z in _size:
		var list: Array[Dictionary] = []
		for isl in islands:
			if absf(z - float(isl["cz"])) <= _reach(isl) + 3.0:
				list.append(isl)
		_row_islands[z] = list


func _place_islands() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed + 11
	var s := float(_size)
	var k := pow(s / 256.0, 2.0) # во сколько раз мир больше «среднего»
	# [тип, сколько, мин. радиус, макс. радиус]
	var plan := [
		[ISLAND_BIG, maxi(1, roundi(1.0 * k)), clampf(s * 0.15, 22, 60), clampf(s * 0.2, 25, 70)],
		[ISLAND_MEDIUM, maxi(1, roundi(2.5 * k)), clampf(s * 0.07, 12, 30), clampf(s * 0.11, 14, 36)],
		[ISLAND_ROCKY, roundi(1.5 * k), 8.0, 16.0],
		[ISLAND_SANDY, roundi(4.0 * k) + 1, 6.0, 11.0],
	]
	islands.clear()
	for entry in plan:
		for n in int(entry[1]):
			for attempt in 300:
				var r := rng.randf_range(entry[2], entry[3])
				var lo := r + 14.0 # от края мира — океан, чтобы было куда плыть
				var hi := s - r - 14.0
				if hi <= lo:
					break
				var cx: float
				var cz: float
				if islands.is_empty(): # первый (большой) остров — ближе к центру, на нём появимся
					cx = clampf(s / 2.0 + rng.randf_range(-0.08, 0.08) * s, lo, hi)
					cz = clampf(s / 2.0 + rng.randf_range(-0.08, 0.08) * s, lo, hi)
				else:
					cx = rng.randf_range(lo, hi)
					cz = rng.randf_range(lo, hi)
				# Острова не круглые: вытянуты и повёрнуты по-разному
				var stretch := rng.randf_range(0.72, 1.38)
				var angle := rng.randf_range(0.0, PI)
				var candidate := {"cx": cx, "cz": cz, "r": r, "kind": int(entry[0]),
					"stretch": stretch, "cos": cos(angle), "sin": sin(angle)}
				var ok := true
				for other in islands:
					var dist := Vector2(cx, cz).distance_to(Vector2(other["cx"], other["cz"]))
					if dist < _reach(candidate) / 1.2 + _reach(other) / 1.2 + 10.0: # между островами — пролив
						ok = false
						break
				# и не вылезают за край мира
				if ok and (cx - _reach(candidate) < 6.0 or cz - _reach(candidate) < 6.0
						or cx + _reach(candidate) > s - 6.0 or cz + _reach(candidate) > s - 6.0):
					ok = false
				if ok:
					islands.append(candidate)
					break


# =============================================================================
#   Шаг 1: высоты (вызывается для каждого ряда z, в разных потоках)
# =============================================================================

## «Влияние» острова на точку: 1 в центре, 0 на краю, дальше — меньше нуля.
## Учитываем вытянутость и поворот острова (эллипс).
static func _influence(isl: Dictionary, x: float, z: float) -> float:
	var dx := x - float(isl["cx"])
	var dz := z - float(isl["cz"])
	var c: float = isl["cos"]
	var sn: float = isl["sin"]
	var st: float = isl["stretch"]
	var u := (dx * c + dz * sn) / st
	var v := (-dx * sn + dz * c) * st
	return 1.0 - sqrt(u * u + v * v) / float(isl["r"])


## Как далеко от центра остров может дотянуться (с учётом вытянутости и шума берега).
static func _reach(isl: Dictionary) -> float:
	var st: float = isl["stretch"]
	return float(isl["r"]) * maxf(st, 1.0 / st) * 1.5


func heights_row(z: int) -> void:
	var near: Array[Dictionary] = _row_islands[z]
	for x in _size:
		var best_f := -10.0
		var kind := OCEAN
		# «Влияние» острова: 1 в центре, 0 на краю радиуса, дальше — меньше нуля
		for isl in near:
			var f := _influence(isl, x, z)
			if f > best_f:
				best_f = f
				kind = int(isl["kind"])
		# Шум делает берег изрезанным: бухты, мысы, крошечные островки рядом
		var l := best_f + _coast_noise.get_noise_2d(x, z) * 0.26 + _bay_noise.get_noise_2d(x, z) * 0.22
		var col := x + z * _size
		if l <= 0.0:
			# Океан: у берега мелко, дальше глубже
			var floor_h := sea_level - 1 + l * 26.0 + _ocean_noise.get_noise_2d(x, z) * 2.0
			_heights[col] = clampi(int(floor_h), 4, sea_level - 1)
			_kinds[col] = OCEAN
			continue
		var t := smoothstep(0.0, 0.55, l) # 0 у берега → 1 в глубине острова
		var hills := _hill_noise.get_noise_2d(x, z)
		var h := float(sea_level) + 1.0
		match kind:
			ISLAND_BIG:
				h += t * 9.0 + hills * 5.0 * t
				var ridge := 1.0 - absf(_ridge_noise.get_noise_2d(x, z))
				h += pow(ridge, 3.0) * 30.0 * t * t # горы в середине острова
			ISLAND_MEDIUM:
				h += t * 7.0 + hills * 4.0 * t
			ISLAND_SANDY:
				h += t * 2.5 + hills * 1.0 * t
			ISLAND_ROCKY:
				var raw := t * 13.0 + hills * 4.0 * t
				h += floorf(raw / 3.0) * 3.0 + (2.0 if t > 0.15 else 0.0) # уступы-скалы
		_heights[col] = clampi(int(h), sea_level + 1, height - 8)
		_kinds[col] = kind
	_rows_done[z] = 1


# =============================================================================
#   Шаг 2: блоки (для каждого ряда z, в разных потоках)
# =============================================================================

func fill_row(z: int) -> void:
	var blocks := _data.blocks # ссылка на общий массив: ряды пишут в разные места
	var hm := _data.heightmap
	var ta := _data.top_any
	var h_world := height
	for x in _size:
		var col := x + z * _size
		var h := _heights[col]
		var kind := _kinds[col]
		var base := col * h_world
		var top_block := Blocks.GRASS
		var filler := Blocks.DIRT
		if kind == OCEAN:
			# Дно: у берега песок, глубже — гравий с песчаными пятнами
			if h >= sea_level - 6 or _ocean_noise.get_noise_2d(x * 3.0, z * 3.0) < -0.2:
				top_block = Blocks.SAND
			else:
				top_block = Blocks.GRAVEL
			filler = top_block
		elif h <= sea_level + 2 or kind == ISLAND_SANDY:
			top_block = Blocks.SAND # пляж
			filler = Blocks.SAND
		elif kind == ISLAND_ROCKY:
			if _hill_noise.get_noise_2d(x * 2.0, z * 2.0) > 0.35:
				top_block = Blocks.GRASS
				filler = Blocks.DIRT
			else:
				top_block = Blocks.STONE
				filler = Blocks.STONE
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
			blocks[base + y] = id
		if kind == OCEAN:
			for y in range(h + 1, sea_level + 1):
				blocks[base + y] = Blocks.WATER
			hm[col] = h          # верхний непрозрачный — дно
			ta[col] = sea_level  # верхний непустой — поверхность воды
		else:
			# Пещеры — только внутри суши и подальше от воды, чтобы море не «висело» стеной в пещере
			if caves_enabled and h >= sea_level + 6 and _min_height_around(x, z) >= sea_level + 3:
				for y in range(2, h - 3):
					if _cave_noise.get_noise_3d(x, y * 1.4, z) > 0.55:
						blocks[base + y] = Blocks.AIR
			hm[col] = h
			ta[col] = h
	_rows_done[z] = 2


func _min_height_around(x: int, z: int) -> int:
	var m := 9999
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var nx := clampi(x + dx, 0, _size - 1)
			var nz := clampi(z + dz, 0, _size - 1)
			m = mini(m, _heights[nx + nz * _size])
	return m


## Сколько рядов прошло шаг stage (1 или 2), от 0 до 1.
func rows_progress(stage: int) -> float:
	var done := 0
	for z in _size:
		if _rows_done[z] >= stage:
			done += 1
	return float(done) / maxi(1, _size)


# =============================================================================
#   Шаг 3: руда, деревья, точка появления (один фоновый поток)
# =============================================================================

func finish() -> void:
	stage_text = "Прячем руду…"
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed + 5
	var area := _size * _size
	_veins(rng, Blocks.COAL_ORE, int(area / 160.0), 4, 9, 2, sea_level + 8)
	_veins(rng, Blocks.IRON_ORE, int(area / 320.0), 3, 7, 2, sea_level - 2)
	finish_progress = 0.3

	stage_text = "Сажаем деревья…"
	for z in range(2, _size - 2):
		for x in range(2, _size - 2):
			var col := x + z * _size
			var kind := _kinds[col]
			if kind == OCEAN:
				continue
			var top := _data.heightmap[col]
			if _data.get_block(x, top, z) != Blocks.GRASS:
				continue
			if rng.randf() < float(TREE_CHANCE.get(kind, 0.0)) * trees_multiplier:
				_tree(x, top, z, rng)
				for dz in range(-2, 3):
					for dx in range(-2, 3):
						_data.update_column(x + dx, z + dz)
		finish_progress = 0.3 + 0.6 * z / _size

	stage_text = "Выбираем место высадки…"
	if not islands.is_empty():
		var first: Dictionary = islands[0]
		_data.spawn_point = _data.find_ground_near(int(first["cx"]), int(first["cz"]), int(first["r"]))
	finish_progress = 1.0
	stage_text = "Готово"


func _veins(rng: RandomNumberGenerator, ore: int, count: int,
		min_len: int, max_len: int, min_y: int, max_y: int) -> void:
	for v in count:
		var p := Vector3i(rng.randi_range(0, _size - 1), rng.randi_range(min_y, max_y), rng.randi_range(0, _size - 1))
		for i in rng.randi_range(min_len, max_len):
			if _data.get_block(p.x, p.y, p.z) == Blocks.STONE:
				_data.set_block_raw(p.x, p.y, p.z, ore)
			match rng.randi() % 6:
				0: p.x += 1
				1: p.x -= 1
				2: p.y += 1
				3: p.y -= 1
				4: p.z += 1
				5: p.z -= 1


func _tree(x: int, ground: int, z: int, rng: RandomNumberGenerator) -> void:
	var trunk := rng.randi_range(4, 6)
	if ground + trunk + 2 >= _data.height:
		return
	_data.set_block_raw(x, ground, z, Blocks.DIRT)
	for i in range(1, trunk + 1):
		_data.set_block_raw(x, ground + i, z, Blocks.WOOD)
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
				if _data.is_inside(px, py, pz) and _data.get_block(px, py, pz) == Blocks.AIR:
					_data.set_block_raw(px, py, pz, Blocks.LEAVES)
