class_name Blocks
extends RefCounted
## Справочник всех типов блоков: номер, название, прочность, текстуры граней,
## прозрачность и как блок сопротивляется разным типам урона.
## Здесь только описание блоков — рисование текстур лежит в view/block_textures.gd.

# --- Номера блоков (ID). 0 = пустота (воздух). -------------------------------
# ВАЖНО: номера уже записаны в сохранениях. Новые блоки добавляй только в конец
# (перед COUNT), иначе в старых мирах блоки перепутаются.
enum {
	AIR,
	GRASS,
	DIRT,
	STONE,
	SAND,
	WOOD,
	LEAVES,
	PLANKS,
	COBBLESTONE,
	COAL_ORE,
	IRON_ORE,
	BEDROCK,
	WATER,
	GRAVEL,
	COUNT, # не блок, просто количество типов
}

# --- Номера клеток в атласе текстур (одна длинная картинка из квадратиков 16×16)
enum {
	T_GRASS_TOP,
	T_GRASS_SIDE,
	T_DIRT,
	T_STONE,
	T_SAND,
	T_LOG_SIDE,
	T_LOG_TOP,
	T_LEAVES,
	T_PLANKS,
	T_COBBLE,
	T_COAL,
	T_IRON,
	T_BEDROCK,
	T_WATER,
	T_GRAVEL,
	T_COUNT,
}

const NAMES := {
	AIR: "Воздух",
	GRASS: "Трава",
	DIRT: "Земля",
	STONE: "Камень",
	SAND: "Песок",
	WOOD: "Бревно",
	LEAVES: "Листва",
	PLANKS: "Доски",
	COBBLESTONE: "Булыжник",
	COAL_ORE: "Угольная руда",
	IRON_ORE: "Железная руда",
	BEDROCK: "Коренная порода",
	WATER: "Вода",
	GRAVEL: "Гравий",
}

## Прочность блока: сколько урона он выдерживает. -1 = неразрушимый.
## Удар рукой наносит Damage.HAND (3) урона, 5 ударов в секунду.
const HP := {
	AIR: 0,
	GRASS: 6,
	DIRT: 5,
	STONE: 30,
	SAND: 4,
	WOOD: 20,
	LEAVES: 1,
	PLANKS: 16,
	COBBLESTONE: 32,
	COAL_ORE: 36,
	IRON_ORE: 42,
	BEDROCK: -1,
	WATER: -1,
	GRAVEL: 6,
}

## Множитель входящего урона по типам (1.0 = обычный урон, 0.5 = вдвое меньше).
## Если блока или типа нет в таблице — множитель 1.0.
const DAMAGE_MULTIPLIER := {
	LEAVES: {Damage.BULLET: 2.0, Damage.EXPLOSION: 3.0},
	WOOD: {Damage.EXPLOSION: 1.5},
	PLANKS: {Damage.EXPLOSION: 1.5},
	GRASS: {Damage.BULLET: 0.6, Damage.EXPLOSION: 1.2},
	DIRT: {Damage.BULLET: 0.6, Damage.EXPLOSION: 1.2},
	SAND: {Damage.BULLET: 0.6, Damage.EXPLOSION: 1.2},
	GRAVEL: {Damage.BULLET: 0.6, Damage.EXPLOSION: 1.2},
	STONE: {Damage.BULLET: 0.4, Damage.EXPLOSION: 0.8},
	COBBLESTONE: {Damage.BULLET: 0.5, Damage.EXPLOSION: 0.8},
}

# Текстуры граней: [верх, бок, низ]
const TILES := {
	GRASS: [T_GRASS_TOP, T_GRASS_SIDE, T_DIRT],
	DIRT: [T_DIRT, T_DIRT, T_DIRT],
	STONE: [T_STONE, T_STONE, T_STONE],
	SAND: [T_SAND, T_SAND, T_SAND],
	WOOD: [T_LOG_TOP, T_LOG_SIDE, T_LOG_TOP],
	LEAVES: [T_LEAVES, T_LEAVES, T_LEAVES],
	PLANKS: [T_PLANKS, T_PLANKS, T_PLANKS],
	COBBLESTONE: [T_COBBLE, T_COBBLE, T_COBBLE],
	COAL_ORE: [T_COAL, T_COAL, T_COAL],
	IRON_ORE: [T_IRON, T_IRON, T_IRON],
	BEDROCK: [T_BEDROCK, T_BEDROCK, T_BEDROCK],
	WATER: [T_WATER, T_WATER, T_WATER],
	GRAVEL: [T_GRAVEL, T_GRAVEL, T_GRAVEL],
}

# Сквозь эти блоки видно соседей (у листвы есть дырочки, вода прозрачная).
const TRANSPARENT := [AIR, LEAVES, WATER]
# Сквозь эти блоки можно проходить (по ним нельзя ходить, их нельзя «выделить» прицелом).
const PASSABLE := [AIR, WATER]

# Быстрые таблицы-«шпаргалки» для построения сетки (заполняются один раз при запуске):
## 1, если блок прозрачный, иначе 0. Индекс — номер блока.
static var TRANSPARENT_LUT := _build_transparent_lut()
## Номер текстуры: [номер_блока * 3 + грань], грань: 0 = верх, 1 = бок, 2 = низ.
static var TILE_LUT := _build_tile_lut()
## 1, если блок твёрдый (на нём можно стоять, его можно ударить), иначе 0.
static var SOLID_LUT := _build_solid_lut()


static func get_block_name(id: int) -> String:
	return NAMES.get(id, "?")


static func get_hp(id: int) -> float:
	return float(HP.get(id, 10))


static func is_breakable(id: int) -> bool:
	return id != AIR and get_hp(id) >= 0.0


## Можно ли ставить этот блок руками.
static func is_placeable(id: int) -> bool:
	return id > AIR and id < COUNT and id != BEDROCK and id != WATER


static func is_solid(id: int) -> bool:
	return SOLID_LUT[id] == 1


static func damage_multiplier(id: int, damage_type: int) -> float:
	var table: Dictionary = DAMAGE_MULTIPLIER.get(id, {})
	return float(table.get(damage_type, 1.0))


## Номер текстуры для грани. face: 0 = верх, 1 = бок, 2 = низ.
static func get_tile(id: int, face: int) -> int:
	var tiles: Array = TILES.get(id, [T_STONE, T_STONE, T_STONE])
	return tiles[face]


static func is_transparent(id: int) -> bool:
	return id in TRANSPARENT


static func _build_transparent_lut() -> PackedByteArray:
	var lut := PackedByteArray()
	lut.resize(256) # с запасом: в байте может оказаться любое число
	lut.fill(0)
	for id in TRANSPARENT:
		lut[id] = 1
	return lut


static func _build_solid_lut() -> PackedByteArray:
	var lut := PackedByteArray()
	lut.resize(256)
	lut.fill(1)
	for id in PASSABLE:
		lut[id] = 0
	return lut


static func _build_tile_lut() -> PackedInt32Array:
	var lut := PackedInt32Array()
	lut.resize(256 * 3) # для неизвестных номеров (например, из битого файла) — текстура камня
	for id in 256:
		for face in 3:
			lut[id * 3 + face] = get_tile(id, face)
	return lut
