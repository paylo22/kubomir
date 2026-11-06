class_name SaveFiles
extends RefCounted
## Работа с файлами сохранений.
## Каждый мир — отдельная папка: user://worlds/<id>/
##   meta.cfg  — название, зерно, даты (читается быстро — для списка миров в меню)
##   world.dat — сами блоки, урон, игроки (сжатые)
##   world.bak — предыдущее сохранение (на случай, если запись оборвётся)
## «user://» — личная папка игры на устройстве. На Android её не видно в «Файлах»,
## зато её никто случайно не удалит.

const WORLDS_DIR := "user://worlds"


static func world_dir(id: String) -> String:
	return WORLDS_DIR.path_join(id)


static func new_world_id() -> String:
	return "world_%d_%03d" % [int(Time.get_unix_time_from_system()), randi() % 1000]


static func exists(id: String) -> bool:
	return FileAccess.file_exists(world_dir(id).path_join("meta.cfg"))


## Список всех миров, самые свежие — первыми.
static func list_worlds() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not DirAccess.dir_exists_absolute(WORLDS_DIR):
		return result
	for id in DirAccess.get_directories_at(WORLDS_DIR):
		var meta := read_meta(id)
		if not meta.is_empty():
			result.append(meta)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("last_played", 0)) > int(b.get("last_played", 0)))
	return result


static func read_meta(id: String) -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(world_dir(id).path_join("meta.cfg")) != OK:
		return {}
	var meta := {"id": id}
	for key in cfg.get_section_keys("world"):
		meta[key] = cfg.get_value("world", key)
	return meta


static func write_meta(id: String, meta: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(world_dir(id))
	var cfg := ConfigFile.new()
	for key in meta:
		if key != "id":
			cfg.set_value("world", key, meta[key])
	cfg.save(world_dir(id).path_join("meta.cfg"))


## Записать мир. Сначала пишем во временный файл, потом подменяем —
## так даже если игра закроется посреди записи, старое сохранение останется целым.
static func write_world(id: String, payload: Dictionary) -> String:
	var dir := world_dir(id)
	DirAccess.make_dir_recursive_absolute(dir)
	var tmp := dir.path_join("world.tmp")
	var main := dir.path_join("world.dat")
	var bak := dir.path_join("world.bak")
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return "не удалось открыть файл для записи (%s)" % error_string(FileAccess.get_open_error())
	f.store_var(payload)
	f.close()
	if FileAccess.file_exists(main):
		if FileAccess.file_exists(bak):
			DirAccess.remove_absolute(bak)
		DirAccess.rename_absolute(main, bak)
	var err := DirAccess.rename_absolute(tmp, main)
	if err != OK:
		return "не удалось сохранить файл (%s)" % error_string(err)
	return ""


## Прочитать мир. Если основной файл испорчен — пробуем резервную копию.
static func read_world(id: String) -> Dictionary:
	var dir := world_dir(id)
	for name in ["world.dat", "world.bak"]:
		var path := dir.path_join(name)
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var value = f.get_var()
		f.close()
		if value is Dictionary and value.has("world"):
			return value
	return {}


static func delete_world(id: String) -> void:
	var dir := world_dir(id)
	if not DirAccess.dir_exists_absolute(dir):
		return
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
