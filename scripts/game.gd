extends Node
## Глобальный узел «Game» (автозагрузка — он живёт всё время, пока запущена игра,
## даже когда меняются сцены). Здесь: настройки игрока и переходы меню ⇄ мир.
## Обращаться к нему можно из любого скрипта по имени: Game.settings, Game.go_to_menu() …

const SETTINGS_PATH := "user://settings.cfg"
const MENU_SCENE := "res://scenes/menu.tscn"
const GAME_SCENE := "res://scenes/game.tscn"
const VERSION := "0.3"

## Размеры архипелага для меню «Новый мир»: название -> сколько чанков (16 блоков) по стороне.
const WORLD_SIZES := [
	{"name": "Маленький", "chunks": 8},
	{"name": "Средний", "chunks": 16},
	{"name": "Большой", "chunks": 24},
]

var settings := {
	"view_distance": 6,
	"touch_sensitivity": 1.0,
	"mouse_sensitivity": 1.0,
	"auto_jump": true,
	"show_fps": true,
}

## Показать сенсорные кнопки даже без сенсорного экрана (для проверки на ПК).
var force_touch_ui := false

## Что запускать, когда откроется сцена мира:
## {"mode": "new", "name": ..., "seed": ..., "size": ...} или {"mode": "load", "id": ...}
var launch := {}


func _ready() -> void:
	load_settings()


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	for key in settings:
		settings[key] = cfg.get_value("settings", key, settings[key])


func save_settings() -> void:
	var cfg := ConfigFile.new()
	for key in settings:
		cfg.set_value("settings", key, settings[key])
	cfg.save(SETTINGS_PATH)


func start_new_world(world_name: String, seed_value: int, size_chunks: int) -> void:
	launch = {"mode": "new", "name": world_name, "seed": seed_value, "size": size_chunks}
	get_tree().change_scene_to_file(GAME_SCENE)


func start_saved_world(id: String) -> void:
	launch = {"mode": "load", "id": id}
	get_tree().change_scene_to_file(GAME_SCENE)


func go_to_menu() -> void:
	launch = {}
	get_tree().paused = false
	get_tree().change_scene_to_file(MENU_SCENE)


## Превратить текст из поля «зерно» в число. Пусто — случайное, слово — его «хэш».
func parse_seed(text: String) -> int:
	text = text.strip_edges()
	if text.is_empty():
		return randi() % 1000000
	if text.is_valid_int():
		return text.to_int()
	return absi(text.hash()) % 1000000000
