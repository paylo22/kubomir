extends Node3D
## Сцена игры. Связывает вместе:
##   WorldServer — правила и данные мира (позже будет работать на сервере),
##   WorldView   — картинка мира,
##   Player      — наш игрок, HUD — интерфейс, PauseMenu — пауза.
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

var _player_state := {}
var _spawned := false


func _ready() -> void:
	hud.setup(world_view.atlas)
	player.session = self
	player.world = world_view
	player.hud = hud

	server.block_changed.connect(world_view.on_block_changed)
	server.block_damaged.connect(world_view.on_block_damaged)
	server.world_loaded.connect(_on_world_loaded)
	server.load_failed.connect(_on_load_failed)
	server.saved.connect(_on_saved)

	pause_menu.opened.connect(_on_pause_opened)
	pause_menu.save_requested.connect(_on_save_requested)
	pause_menu.quit_requested.connect(_on_quit_requested)

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
				server.create_world("test", "Тестовый мир", 12345, 6)


func _process(_delta: float) -> void:
	if _spawned:
		return
	if not server.is_loaded:
		hud.set_loading_progress(server.status_text, server.progress * 0.5)
	else:
		hud.set_loading_progress("Строим мир…", 0.5 + world_view.initial_progress * 0.5)


func _on_world_loaded() -> void:
	_player_state = server.join_player(LOCAL_PLAYER_ID)
	world_view.spawn_area_ready.connect(_on_spawn_area_ready, CONNECT_ONE_SHOT)
	world_view.attach(server.data, _player_state["pos"])


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


func _notification(what: int) -> void:
	# Игру сворачивают (Android) или закрывают окно (ПК) — сохраняемся.
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		if server and server.is_loaded:
			server.save_world()
