extends Node3D
## Сцена игры. Связывает вместе:
##   WorldServer — правила и данные мира (позже будет работать на сервере),
##   WorldView   — картинка мира (только чанки вокруг игрока),
##   Player      — наш игрок, HUD — интерфейс, PauseMenu — пауза и карта.
##
## Путь команды «сломать блок»:
##   Player → session.send_command() → WorldServer.submit() → проверка → изменение мира
##   → сигнал block_changed → WorldView перестраивает чанк и рисует осколки.

const LOCAL_PLAYER_ID := 1 ## наш номер игрока (по сети у каждого будет свой)

@onready var server: WorldServer = $WorldServer
@onready var world_view: WorldView = $WorldView
@onready var player: CharacterBody3D = $Player
@onready var hud: CanvasLayer = $HUD
@onready var pause_menu: CanvasLayer = $PauseMenu
@onready var environment: Environment = $WorldEnvironment.environment

var _player_state := {}
var _spawned := false
var _view_distance := -1
var _underwater := false
# Карта мира: строится в фоне после загрузки
var _map := WorldMap.new()
var _map_texture: ImageTexture
var _map_task := -1
var _map_dirty := false
var _map_pending: Array[Vector2i] = [] # столбцы, изменившиеся, пока карта строилась


func _ready() -> void:
	hud.setup(world_view.atlas)
	player.session = self
	player.world = world_view
	player.hud = hud

	server.block_changed.connect(world_view.on_block_changed)
	server.block_changed.connect(_on_block_changed_for_map)
	server.block_damaged.connect(world_view.on_block_damaged)
	server.world_loaded.connect(_on_world_loaded)
	server.load_failed.connect(_on_load_failed)
	server.saved.connect(_on_saved)

	pause_menu.opened.connect(_on_pause_opened)
	pause_menu.save_requested.connect(_on_save_requested)
	pause_menu.quit_requested.connect(_on_quit_requested)
	pause_menu.map_requested.connect(_on_map_requested)

	var launch: Dictionary = Game.launch
	match launch.get("mode", ""):
		"new":
			server.create_world(SaveFiles.new_world_id(), launch["name"], launch["seed"], launch["size"])
		"load":
			server.load_world(launch["id"])
		_:
			# Сцену запустили прямо из редактора (F6) — берём тестовый мир.
			if SaveFiles.exists("test"):
				server.load_world("test")
			else:
				server.create_world("test", "Тестовый мир", 12345, 8)


func _process(_delta: float) -> void:
	_poll_map_task()
	if not _spawned:
		if not server.is_loaded:
			hud.set_loading_progress(server.status_text, server.progress * 0.7)
		else:
			hud.set_loading_progress("Строим мир вокруг тебя…", 0.7 + world_view.initial_progress * 0.3)
		return
	var vd := int(Game.settings["view_distance"])
	if vd != _view_distance:
		_apply_view_distance(vd)
	world_view.set_focus(player.global_position)
	var under: bool = player.is_head_underwater()
	if under != _underwater:
		_underwater = under
		_apply_fog()
		hud.set_underwater(under)


func _on_world_loaded() -> void:
	_player_state = server.join_player(LOCAL_PLAYER_ID)
	_apply_view_distance(int(Game.settings["view_distance"]))
	world_view.spawn_area_ready.connect(_on_spawn_area_ready, CONNECT_ONE_SHOT)
	world_view.attach(server.data, _player_state["pos"])
	_map_task = WorkerThreadPool.add_task(_map.build.bind(server.data), false, "Карта мира")


func _on_spawn_area_ready() -> void:
	player.spawn(_player_state)
	hud.hide_loading()
	pause_menu.enabled = true
	_spawned = true


func _on_load_failed(message: String) -> void:
	hud.set_loading_progress("Не удалось загрузить мир: " + message, 0.0)
	await get_tree().create_timer(3.0).timeout
	Game.go_to_menu()


# =============================================================================
#   «Сеть» игрока. Сейчас — прямой вызов сервера на этом же устройстве.
# =============================================================================

func send_command(cmd: Dictionary) -> void:
	server.submit(LOCAL_PLAYER_ID, cmd)


func report_state(state: Dictionary) -> void:
	server.report_player_state(LOCAL_PLAYER_ID, state)


# =============================================================================
#   Дальность прорисовки, туман, вода
# =============================================================================

func _apply_view_distance(vd: int) -> void:
	_view_distance = vd
	world_view.view_distance = vd
	player.camera.far = vd * WorldData.CHUNK_SIZE + 32.0
	_apply_fog()


## Туман прячет край прорисовки: дальние чанки плавно растворяются в небе.
## Под водой — густой синий туман.
func _apply_fog() -> void:
	if _underwater:
		environment.fog_mode = Environment.FOG_MODE_EXPONENTIAL
		environment.fog_light_color = Color(0.06, 0.22, 0.42)
		environment.fog_density = 0.09
		environment.fog_sky_affect = 1.0
	else:
		var far := float(_view_distance * WorldData.CHUNK_SIZE)
		environment.fog_mode = Environment.FOG_MODE_DEPTH
		environment.fog_light_color = Color(0.72, 0.82, 0.95)
		environment.fog_density = 1.0
		environment.fog_depth_begin = far * 0.55
		environment.fog_depth_end = far
		environment.fog_depth_curve = 1.0
		environment.fog_sky_affect = 0.0 # небо остаётся голубым, туман — только на земле


# =============================================================================
#   Карта
# =============================================================================

func _poll_map_task() -> void:
	if _map_task >= 0 and WorkerThreadPool.is_task_completed(_map_task):
		WorkerThreadPool.wait_for_task_completion(_map_task)
		_map_task = -1
		for c in _map_pending:
			_map.update_column(c.x, c.y)
		_map_pending.clear()
		_map_texture = ImageTexture.create_from_image(_map.image)


func _on_block_changed_for_map(pos: Vector3i, _new_id: int, _old_id: int) -> void:
	if _map_task >= 0:
		_map_pending.append(Vector2i(pos.x, pos.z))
	else:
		_map.update_column(pos.x, pos.z)
		_map_dirty = true


func _on_map_requested() -> void:
	if _map_texture == null:
		pause_menu.show_status("Карта ещё рисуется…")
		return
	if _map_dirty:
		_map_texture.update(_map.image)
		_map_dirty = false
	var data := server.data
	var uv := Vector2(player.global_position.x / data.size_x, player.global_position.z / data.size_z)
	pause_menu.show_map(_map_texture, uv, player.rotation.y)


# =============================================================================
#   Пауза и сохранение
# =============================================================================

func _on_saved(auto: bool) -> void:
	if auto and _spawned:
		hud.show_toast("Автосохранение", 1.2)


func _on_save_requested() -> void:
	if server.save_world():
		pause_menu.show_status("Мир сохранён")
	else:
		pause_menu.show_status("Не удалось сохранить!")


func _on_quit_requested() -> void:
	server.save_world()
	world_view.finish_all_jobs()
	Game.go_to_menu()


## Открыли паузу — отпускаем все «нажатые» кнопки, чтобы они не залипли.
func _on_pause_opened() -> void:
	player.release_inputs()
	if hud.touch_controls:
		hud.touch_controls.release_all()


func _exit_tree() -> void:
	if _map_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_map_task)
		_map_task = -1


func _notification(what: int) -> void:
	# Игру сворачивают (Android) или закрывают окно (ПК) — сохраняемся.
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		if server and server.is_loaded:
			server.save_world()
