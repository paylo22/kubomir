class_name WorldData
extends RefCounted
## Все блоки мира и их состояние (урон). Только данные — никакой картинки.
## Один и тот же класс будет работать и на сервере, и у игроков по сети.
##
## Как хранятся блоки: один большой массив байтов, каждый байт — номер блока.
## Блоки одного столбца (x, z) лежат подряд снизу вверх —
## так чанку удобно копировать целые столбцы за одну операцию.

const CHUNK_SIZE := 16
const SAVE_VERSION := 3

var size_x := 0
var size_z := 0
var height := 0
var world_seed := 0
## Уровень моря: до этой высоты (включительно) в океане стоит вода.
var sea_level := 0
## Где появляются новые игроки (выбирает генератор). Vector3.ZERO — «не задано».
var spawn_point := Vector3.ZERO
var blocks := PackedByteArray()
## Для каждого столбца — высота самого верхнего непрозрачного блока (-1, если нет).
## По ней понимаем, видно ли небо: всё, что ниже, — в тени.
var heightmap := PackedInt32Array()
## Для каждого столбца — высота самого верхнего НЕ пустого блока (включая листву).
var top_any := PackedInt32Array()
## Повреждённые блоки: Vector3i -> сколько урона уже получил.
var damage := {}


func setup(sx: int, sz: int, h: int) -> void:
	size_x = sx
	size_z = sz
	height = h
	blocks = PackedByteArray()
	blocks.resize(sx * sz * h) # всё заполнено нулями = воздух
	heightmap = PackedInt32Array()
	heightmap.resize(sx * sz)
	heightmap.fill(-1)
	top_any = PackedInt32Array()
	top_any.resize(sx * sz)
	top_any.fill(-1)
	damage = {}


func chunk_count_x() -> int:
	return ceili(float(size_x) / CHUNK_SIZE)


func chunk_count_z() -> int:
	return ceili(float(size_z) / CHUNK_SIZE)


# =============================================================================
#   Доступ к блокам
# =============================================================================

func is_inside(x: int, y: int, z: int) -> bool:
	return x >= 0 and x < size_x and z >= 0 and z < size_z and y >= 0 and y < height


func index_of(x: int, y: int, z: int) -> int:
	return y + (x + z * size_x) * height


func get_block(x: int, y: int, z: int) -> int:
	if not is_inside(x, y, z):
		return Blocks.AIR
	return blocks[index_of(x, y, z)]


## Твёрдый = на нём можно стоять (всё, кроме воздуха и воды).
func is_solid(x: int, y: int, z: int) -> bool:
	return Blocks.SOLID_LUT[get_block(x, y, z)] == 1


## Поставить блок. Возвращает, какой блок был раньше.
## Внимание: менять мир в игре должен только WorldServer!
func set_block(x: int, y: int, z: int, id: int) -> int:
	if not is_inside(x, y, z):
		return Blocks.AIR
	var i := index_of(x, y, z)
	var old := blocks[i]
	blocks[i] = id
	damage.erase(Vector3i(x, y, z)) # новый блок — целый
	update_column(x, z)
	return old


## Быстрая запись без пересчёта высот (только для генератора).
func set_block_raw(x: int, y: int, z: int, id: int) -> void:
	blocks[index_of(x, y, z)] = id


func get_damage(pos: Vector3i) -> float:
	return damage.get(pos, 0.0)


func set_damage(pos: Vector3i, value: float) -> void:
	if value <= 0.0:
		damage.erase(pos)
	else:
		damage[pos] = value


func get_column_top(x: int, z: int) -> int:
	if x < 0 or x >= size_x or z < 0 or z >= size_z:
		return -1
	return heightmap[x + z * size_x]


## Пересчитать высоты одного столбца (после изменения блока в нём).
func update_column(x: int, z: int) -> void:
	var base := (x + z * size_x) * height
	var lut := Blocks.TRANSPARENT_LUT
	var top := -1
	var top_nonempty := -1
	for y in range(height - 1, -1, -1):
		var id := blocks[base + y]
		if id != Blocks.AIR and top_nonempty < 0:
			top_nonempty = y
		if lut[id] == 0:
			top = y
			break
	heightmap[x + z * size_x] = top
	top_any[x + z * size_x] = top_nonempty


func recompute_all_columns() -> void:
	for z in size_z:
		for x in size_x:
			update_column(x, z)


## Точка появления игрока. Если генератор выбрал место — оно, иначе ищем землю у центра.
func get_spawn_position() -> Vector3:
	if spawn_point != Vector3.ZERO:
		return spawn_point
	return find_ground_near(int(size_x / 2.0), int(size_z / 2.0), 24)


## Ближайшее к (cx, cz) место на земле: трава, песок или земля, не на дереве и не в воде.
func find_ground_near(cx: int, cz: int, max_radius: int) -> Vector3:
	for r in max_radius: # обходим квадраты всё большего размера вокруг центра
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) != r:
					continue
				var x := cx + dx
				var z := cz + dz
				if x < 0 or x >= size_x or z < 0 or z >= size_z:
					continue
				var top := top_any[x + z * size_x]
				if top < 0 or top >= height - 3:
					continue
				var id := get_block(x, top, z)
				if id == Blocks.GRASS or id == Blocks.SAND or id == Blocks.DIRT:
					return Vector3(x + 0.5, top + 1.05, z + 0.5)
	# не нашли — просто над самым верхним блоком в центре
	var t := height - 1
	while t > 0 and get_block(cx, t, cz) == Blocks.AIR:
		t -= 1
	return Vector3(cx + 0.5, t + 1.05, cz + 0.5)


# =============================================================================
#   Луч «куда смотрит игрок» (перебор клеток вдоль луча, алгоритм DDA)
# =============================================================================

## Возвращает словарь: hit (попали ли), pos (блок), normal (с какой стороны попали).
func raycast(origin: Vector3, direction: Vector3, max_distance: float) -> Dictionary:
	var dir := direction.normalized()
	var cell := Vector3i(floori(origin.x), floori(origin.y), floori(origin.z))
	var step := Vector3i(int(signf(dir.x)), int(signf(dir.y)), int(signf(dir.z)))
	var t_delta := Vector3(
		absf(1.0 / dir.x) if dir.x != 0.0 else INF,
		absf(1.0 / dir.y) if dir.y != 0.0 else INF,
		absf(1.0 / dir.z) if dir.z != 0.0 else INF)
	var t_max := Vector3(
		_first_t(origin.x, cell.x, dir.x),
		_first_t(origin.y, cell.y, dir.y),
		_first_t(origin.z, cell.z, dir.z))
	var normal := Vector3i.ZERO
	var t := 0.0
	while t <= max_distance:
		if Blocks.SOLID_LUT[get_block(cell.x, cell.y, cell.z)] == 1: # воздух и воду пролетаем насквозь
			return {"hit": true, "pos": cell, "normal": normal}
		if t_max.x < t_max.y and t_max.x < t_max.z:
			cell.x += step.x
			t = t_max.x
			t_max.x += t_delta.x
			normal = Vector3i(-step.x, 0, 0)
		elif t_max.y < t_max.z:
			cell.y += step.y
			t = t_max.y
			t_max.y += t_delta.y
			normal = Vector3i(0, -step.y, 0)
		else:
			cell.z += step.z
			t = t_max.z
			t_max.z += t_delta.z
			normal = Vector3i(0, 0, -step.z)
	return {"hit": false}


func _first_t(o: float, c: int, d: float) -> float:
	if d > 0.0:
		return (c + 1 - o) / d
	elif d < 0.0:
		return (o - c) / -d
	return INF


# =============================================================================
#   Сохранение
# =============================================================================

## Упаковать мир в словарь для записи в файл. Блоки сжимаются (zstd) —
## мир 96×96×64 занимает ~600 КБ в памяти, а в файле — несколько десятков КБ.
func to_dict() -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"size_x": size_x,
		"size_z": size_z,
		"height": height,
		"seed": world_seed,
		"sea_level": sea_level,
		"spawn_point": spawn_point,
		"blocks_len": blocks.size(),
		"blocks": blocks.compress(FileAccess.COMPRESSION_ZSTD),
		# Высоты тоже сохраняем — пересчитывать их для большого мира долго.
		"heightmap": heightmap.to_byte_array().compress(FileAccess.COMPRESSION_ZSTD),
		"top_any": top_any.to_byte_array().compress(FileAccess.COMPRESSION_ZSTD),
		"damage": damage,
	}


## Распаковать мир из словаря. Возвращает пустую строку или текст ошибки.
func from_dict(d: Dictionary) -> String:
	for key in ["version", "size_x", "size_z", "height", "blocks_len", "blocks"]:
		if not d.has(key):
			return "в файле нет поля «%s»" % key
	if int(d["version"]) > SAVE_VERSION:
		return "мир сохранён более новой версией игры"
	setup(int(d["size_x"]), int(d["size_z"]), int(d["height"]))
	world_seed = int(d.get("seed", 0))
	sea_level = int(d.get("sea_level", 0))
	var sp = d.get("spawn_point", Vector3.ZERO)
	spawn_point = sp if sp is Vector3 else Vector3.ZERO
	var packed: PackedByteArray = d["blocks"]
	var raw := packed.decompress(int(d["blocks_len"]), FileAccess.COMPRESSION_ZSTD)
	if raw.size() != size_x * size_z * height:
		return "размер блоков не совпадает (файл повреждён?)"
	blocks = raw
	var dmg = d.get("damage", {})
	if dmg is Dictionary:
		for pos in dmg:
			if pos is Vector3i:
				damage[pos] = float(dmg[pos])
	# Высоты: берём из файла (быстро), а в старых сохранениях — пересчитываем.
	var columns := size_x * size_z
	var hm := _unpack_ints(d.get("heightmap"), columns)
	var ta := _unpack_ints(d.get("top_any"), columns)
	if hm.size() == columns and ta.size() == columns:
		heightmap = hm
		top_any = ta
	else:
		recompute_all_columns()
	return ""


static func _unpack_ints(value, count: int) -> PackedInt32Array:
	if not (value is PackedByteArray):
		return PackedInt32Array()
	var raw: PackedByteArray = value.decompress(count * 4, FileAccess.COMPRESSION_ZSTD)
	return raw.to_int32_array()
