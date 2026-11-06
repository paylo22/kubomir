class_name WorldServer
extends Node
## «Сервер мира» — единственный, кто имеет право менять мир.
##
## Игроки (даже в одиночной игре) ничего не меняют сами — они отправляют команды:
##   {"type": "hit_block",   "pos": Vector3i, "damage": 3.0, "damage_type": Damage.MELEE}
##   {"type": "place_block", "pos": Vector3i, "block": Blocks.STONE}
## Сервер проверяет команду (дотягивается ли игрок, не жульничает ли),
## меняет мир и сообщает всем результат через сигналы block_changed / block_damaged.
##
## Сейчас команды приходят прямо из игры на этом же устройстве.
## Когда добавим сетевую игру, они начнут приходить по сети — а этот код не изменится.

signal world_loaded
signal load_failed(message: String)
signal saved(auto: bool)
signal block_changed(pos: Vector3i, new_id: int, old_id: int)
signal block_damaged(pos: Vector3i, damage: float)

const GAME_VERSION := "0.3"

@export_group("Генерация нового мира")
@export var world_height := 64
@export var sea_level := 22         ## до этой высоты — вода
@export var caves_enabled := true
@export var trees_multiplier := 1.0 ## 2.0 — вдвое больше деревьев, 0 — без деревьев

@export_group("Правила")
@export var autosave_interval := 60.0 ## секунд между автосохранениями
@export var max_reach := 7.5          ## дальше этого игрок не может ломать/ставить

var data: WorldData
var world_id := ""
var world_name := ""
var is_loaded := false
## Что сейчас происходит и насколько готово (для экрана загрузки).
var status_text := ""
var progress := 0.0

var _meta := {}
var _players := {}       # номер игрока -> его состояние (позиция, поворот, ...)
var _saved_players := {} # состояния из файла (для тех, кто ещё не зашёл)
var _task_id := -1
var _group_id := -1
var _gen_stage := 0 # 0 — не генерируем, 1 — высоты, 2 — блоки, 3 — руда и деревья
var _generator: WorldGenerator
var _load_result := {}
var _autosave_timer := 0.0


# =============================================================================
#   Создание и загрузка мира
# =============================================================================

## Создать новый мир. Генерация идёт в фоновом потоке, по окончании — сигнал world_loaded.
func create_world(id: String, title: String, seed_value: int, size_chunks: int) -> void:
	world_id = id
	world_name = title
	var now := int(Time.get_unix_time_from_system())
	_meta = {"name": title, "seed": seed_value, "size_chunks": size_chunks,
		"created": now, "last_played": now, "game_version": GAME_VERSION}
	data = WorldData.new()
	_generator = WorldGenerator.new()
	_generator.world_seed = seed_value
	_generator.size_chunks = size_chunks
	_generator.height = world_height
	_generator.sea_level = sea_level
	_generator.caves_enabled = caves_enabled
	_generator.trees_multiplier = trees_multiplier
	_generator.prepare(data)
	_meta["islands"] = _generator.islands.size()
	# Шаг 1: высоты — все ряды мира параллельно, на всех ядрах
	status_text = "Поднимаем острова из океана…"
	_gen_stage = 1
	_group_id = WorkerThreadPool.add_group_task(_generator.heights_row, data.size_z, -1, false, "Высоты")


## Загрузить сохранённый мир (чтение и распаковка — тоже в фоне).
func load_world(id: String) -> void:
	world_id = id
	_meta = SaveFiles.read_meta(id)
	world_name = str(_meta.get("name", id))
	data = WorldData.new()
	status_text = "Загружаем мир…"
	_load_result = {}
	_task_id = WorkerThreadPool.add_task(_load_in_thread.bind(id, data, _load_result), false, "Загрузка мира")


func _load_in_thread(id: String, target: WorldData, result: Dictionary) -> void:
	var payload := SaveFiles.read_world(id)
	if payload.is_empty():
		result["error"] = "файл мира не найден или повреждён"
		return
	var err := target.from_dict(payload["world"])
	if err != "":
		result["error"] = err
		return
	result["players"] = payload.get("players", {})


func _process(delta: float) -> void:
	if _gen_stage > 0:
		_process_generation()
		return
	if _task_id >= 0:
		if WorkerThreadPool.is_task_completed(_task_id):
			WorkerThreadPool.wait_for_task_completion(_task_id)
			_task_id = -1
			_finish_loading()
		return

	if is_loaded and autosave_interval > 0.0:
		_autosave_timer += delta
		if _autosave_timer >= autosave_interval:
			save_world(true)


## Генерация идёт шагами; каждый шаг — фоновое задание. Здесь следим и запускаем следующий.
func _process_generation() -> void:
	match _gen_stage:
		1:
			progress = 0.3 * _generator.rows_progress(1)
			if WorkerThreadPool.is_group_task_completed(_group_id):
				WorkerThreadPool.wait_for_group_task_completion(_group_id)
				status_text = "Насыпаем землю, камень и песок…"
				_gen_stage = 2
				_group_id = WorkerThreadPool.add_group_task(_generator.fill_row, data.size_z, -1, false, "Блоки")
		2:
			progress = 0.3 + 0.5 * _generator.rows_progress(2)
			if WorkerThreadPool.is_group_task_completed(_group_id):
				WorkerThreadPool.wait_for_group_task_completion(_group_id)
				_group_id = -1
				_gen_stage = 3
				_task_id = WorkerThreadPool.add_task(_generator.finish, false, "Руда и деревья")
		3:
			progress = 0.8 + 0.2 * _generator.finish_progress
			status_text = _generator.stage_text
			if WorkerThreadPool.is_task_completed(_task_id):
				WorkerThreadPool.wait_for_task_completion(_task_id)
				_task_id = -1
				_gen_stage = 0
				_finish_loading()


## Дождаться фоновых заданий (например, если игрок вышел из мира во время загрузки).
func _exit_tree() -> void:
	if _group_id >= 0:
		WorkerThreadPool.wait_for_group_task_completion(_group_id)
		_group_id = -1
	if _task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1


func _finish_loading() -> void:
	if _generator:
		_generator = null
		is_loaded = true
		progress = 1.0
		save_world(true) # сразу записываем новый мир, чтобы он появился в списке
	else:
		if _load_result.has("error"):
			load_failed.emit(str(_load_result["error"]))
			return
		_saved_players = _load_result.get("players", {})
		is_loaded = true
		progress = 1.0
	world_loaded.emit()


func save_world(auto := false) -> bool:
	if not is_loaded:
		return false
	_autosave_timer = 0.0
	# Запоминаем, где стояли игроки, которые сейчас в игре
	for id in _players:
		_saved_players[id] = _players[id].duplicate()
	var payload := {
		"game_version": GAME_VERSION,
		"world": data.to_dict(),
		"players": _saved_players,
	}
	var err := SaveFiles.write_world(world_id, payload)
	if err != "":
		push_error("Сохранение не удалось: " + err)
		return false
	_meta["last_played"] = int(Time.get_unix_time_from_system())
	_meta["name"] = world_name
	_meta["game_version"] = GAME_VERSION
	SaveFiles.write_meta(world_id, _meta)
	saved.emit(auto)
	return true


# =============================================================================
#   Игроки
# =============================================================================

## Игрок заходит в мир. Возвращает его состояние: где появиться и куда смотреть.
func join_player(player_id: int) -> Dictionary:
	var state: Dictionary
	if _saved_players.has(player_id):
		state = _saved_players[player_id].duplicate()
	else:
		state = {"pos": data.get_spawn_position(), "yaw": 0.0, "pitch": 0.0, "flying": false, "hotbar": 0}
	_players[player_id] = state
	return state


func leave_player(player_id: int) -> void:
	if _players.has(player_id):
		_saved_players[player_id] = _players[player_id]
		_players.erase(player_id)


## Игрок сообщает, где он сейчас (каждый кадр). По сети это будет частое короткое сообщение.
func report_player_state(player_id: int, state: Dictionary) -> void:
	if not _players.has(player_id):
		return
	var st: Dictionary = _players[player_id]
	for key in state:
		st[key] = state[key]


# =============================================================================
#   Команды
# =============================================================================

func submit(player_id: int, cmd: Dictionary) -> void:
	if not is_loaded or not _players.has(player_id):
		return
	match cmd.get("type", ""):
		"hit_block":
			_cmd_hit_block(player_id, cmd)
		"place_block":
			_cmd_place_block(player_id, cmd)
		_:
			push_warning("Неизвестная команда: %s" % cmd)


func _cmd_hit_block(player_id: int, cmd: Dictionary) -> void:
	var pos = cmd.get("pos")
	if not (pos is Vector3i) or not _can_reach(player_id, pos):
		return
	var id := data.get_block(pos.x, pos.y, pos.z)
	if not Blocks.is_breakable(id):
		return
	var damage_type := int(cmd.get("damage_type", Damage.MELEE))
	var dmg := clampf(float(cmd.get("damage", 0.0)), 0.0, Damage.MAX_PER_HIT)
	dmg *= Blocks.damage_multiplier(id, damage_type)
	var total := data.get_damage(pos) + dmg
	if total >= Blocks.get_hp(id):
		# Блок разрушен. Если рядом вода — она заливает освободившееся место.
		var new_id := Blocks.WATER if _touches_water(pos) else Blocks.AIR
		data.set_block(pos.x, pos.y, pos.z, new_id)
		block_changed.emit(pos, new_id, id)
	else:
		data.set_damage(pos, total) # трещины — блок помнит урон
		block_damaged.emit(pos, total)


func _cmd_place_block(player_id: int, cmd: Dictionary) -> void:
	var pos = cmd.get("pos")
	var block := int(cmd.get("block", Blocks.AIR))
	if not (pos is Vector3i) or not Blocks.is_placeable(block):
		return
	if not data.is_inside(pos.x, pos.y, pos.z):
		return
	var current := data.get_block(pos.x, pos.y, pos.z)
	if current != Blocks.AIR and current != Blocks.WATER: # ставить можно в воздух и в воду
		return
	if not _can_reach(player_id, pos):
		return
	# Нельзя поставить блок туда, где стоит любой игрок
	var box := AABB(Vector3(pos), Vector3.ONE)
	for id in _players:
		if _player_box(_players[id]).intersects(box):
			return
	var old := data.set_block(pos.x, pos.y, pos.z, block)
	block_changed.emit(pos, block, old)


## Есть ли вода сбоку или сверху от блока.
func _touches_water(pos: Vector3i) -> bool:
	for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1), Vector3i(0, 1, 0)]:
		var p: Vector3i = pos + d
		if data.get_block(p.x, p.y, p.z) == Blocks.WATER:
			return true
	return false


func _can_reach(player_id: int, pos: Vector3i) -> bool:
	var st: Dictionary = _players[player_id]
	var eye: Vector3 = st.get("pos", Vector3.ZERO) + Vector3(0, 1.6, 0)
	return eye.distance_to(Vector3(pos) + Vector3(0.5, 0.5, 0.5)) <= max_reach


static func _player_box(state: Dictionary) -> AABB:
	var p: Vector3 = state.get("pos", Vector3.ZERO)
	return AABB(p + Vector3(-0.29, 0.02, -0.29), Vector3(0.58, 1.7, 0.58))
