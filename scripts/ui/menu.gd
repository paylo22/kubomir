extends Control
## Главное меню: продолжить, новый мир, загрузить мир, настройки, выход.
## Весь интерфейс собирается из кода — так его проще менять вместе.

var _atlas: ImageTexture
var _center: CenterContainer
var _main: VBoxContainer
var _new_panel: PanelContainer
var _load_panel: PanelContainer
var _settings: SettingsPanel
var _continue_btn: Button
var _list: VBoxContainer
var _name_edit: LineEdit
var _seed_edit: LineEdit
var _size_buttons: Array[Button] = []
var _size_index := 1
var _last_world_id := ""


func _ready() -> void:
	theme = UITheme.create()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_atlas = ImageTexture.create_from_image(BlockTextures.create_atlas_image())

	var bg := Control.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.draw.connect(_draw_background.bind(bg))
	bg.resized.connect(bg.queue_redraw)
	add_child(bg)

	_center = CenterContainer.new()
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_center)

	_build_main()
	_build_new_world()
	_build_load()
	_settings = SettingsPanel.new()
	_settings.closed.connect(_show.bind("main"))
	_center.add_child(_settings)
	_show("main")


# =============================================================================
#   Экраны меню
# =============================================================================

func _build_main() -> void:
	_main = VBoxContainer.new()
	_main.add_theme_constant_override("separation", 14)
	_center.add_child(_main)

	var title := UITheme.label("КУБОМИР", 84)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	title.add_theme_constant_override("shadow_offset_x", 4)
	title.add_theme_constant_override("shadow_offset_y", 4)
	_main.add_child(title)
	var version := UITheme.label("версия " + Game.VERSION, 20, Color(1, 1, 1, 0.8))
	version.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_main.add_child(version)
	_main.add_child(_spacer(16))

	_continue_btn = UITheme.button("Продолжить", _on_continue, 440)
	_main.add_child(_continue_btn)
	_main.add_child(UITheme.button("Новый мир", _show.bind("new"), 440))
	_main.add_child(UITheme.button("Мои миры", _show.bind("load"), 440))
	_main.add_child(UITheme.button("Настройки", _show.bind("settings"), 440))
	_main.add_child(UITheme.button("Выход", get_tree().quit, 440))


func _build_new_world() -> void:
	_new_panel = PanelContainer.new()
	_center.add_child(_new_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	_new_panel.add_child(box)

	var title := UITheme.label("Новый мир", 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	box.add_child(UITheme.label("Название", 22, UITheme.TEXT_DIM))
	_name_edit = LineEdit.new()
	_name_edit.custom_minimum_size = Vector2(560, 60)
	_name_edit.max_length = 40
	box.add_child(_name_edit)

	box.add_child(UITheme.label("Зерно мира (пусто — случайное)", 22, UITheme.TEXT_DIM))
	_seed_edit = LineEdit.new()
	_seed_edit.custom_minimum_size = Vector2(560, 60)
	_seed_edit.placeholder_text = "например, 12345 или слово"
	_seed_edit.max_length = 30
	box.add_child(_seed_edit)

	box.add_child(UITheme.label("Размер мира", 22, UITheme.TEXT_DIM))
	var sizes := HBoxContainer.new()
	sizes.add_theme_constant_override("separation", 10)
	box.add_child(sizes)
	var group := ButtonGroup.new()
	for i in Game.WORLD_SIZES.size():
		var info: Dictionary = Game.WORLD_SIZES[i]
		var blocks_side: int = info["chunks"] * WorldData.CHUNK_SIZE
		var b := UITheme.button("%s\n%d×%d" % [info["name"], blocks_side, blocks_side], _select_size.bind(i), 180)
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(180, 84)
		sizes.add_child(b)
		_size_buttons.append(b)
	_select_size(_size_index)

	box.add_child(_spacer(6))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)
	row.add_child(UITheme.button("Назад", _show.bind("main"), 270))
	var create := UITheme.button("Создать", _on_create, 270)
	create.add_theme_stylebox_override("normal", _accent_box())
	row.add_child(create)


func _build_load() -> void:
	_load_panel = PanelContainer.new()
	_center.add_child(_load_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	_load_panel.add_child(box)

	var title := UITheme.label("Мои миры", 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(820, 400)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 10)
	scroll.add_child(_list)

	box.add_child(UITheme.button("Назад", _show.bind("main"), 820))


func _show(screen: String) -> void:
	for child in _center.get_children():
		child.visible = false
	match screen:
		"main":
			_refresh_continue()
			_main.visible = true
		"new":
			_name_edit.text = "Мой мир %d" % (SaveFiles.list_worlds().size() + 1)
			_seed_edit.text = ""
			_new_panel.visible = true
		"load":
			_fill_world_list()
			_load_panel.visible = true
		"settings":
			_settings.visible = true


func _refresh_continue() -> void:
	var worlds := SaveFiles.list_worlds()
	if worlds.is_empty():
		_last_world_id = ""
		_continue_btn.text = "Продолжить"
		_continue_btn.disabled = true
	else:
		_last_world_id = worlds[0]["id"]
		_continue_btn.text = "Продолжить: " + str(worlds[0].get("name", "мир"))
		_continue_btn.disabled = false


func _fill_world_list() -> void:
	for child in _list.get_children():
		child.queue_free()
	var worlds := SaveFiles.list_worlds()
	if worlds.is_empty():
		var empty := UITheme.label("Пока нет ни одного мира.\nСоздай первый в «Новый мир»!", 24, UITheme.TEXT_DIM)
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_list.add_child(empty)
		return
	for meta in worlds:
		_list.add_child(_world_row(meta))


func _world_row(meta: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)
	info.add_child(UITheme.label(str(meta.get("name", meta["id"])), 26))
	var details := "%s · зерно %s · %s" % [
		_size_name(int(meta.get("size_chunks", 6))), str(meta.get("seed", "?")),
		_format_date(int(meta.get("last_played", 0)))]
	info.add_child(UITheme.label(details, 18, UITheme.TEXT_DIM))

	var id: String = meta["id"]
	var play := UITheme.button("Играть", Game.start_saved_world.bind(id), 160)
	play.add_theme_stylebox_override("normal", _accent_box())
	row.add_child(play)
	var del := UITheme.button("Удалить", Callable(), 160)
	del.pressed.connect(_on_delete.bind(id, del))
	row.add_child(del)
	return row


func _on_delete(id: String, button: Button) -> void:
	# Первое нажатие — переспрашиваем, второе — удаляем.
	if button.text != "Точно?":
		button.text = "Точно?"
		return
	SaveFiles.delete_world(id)
	_fill_world_list()


func _select_size(i: int) -> void:
	_size_index = i
	for j in _size_buttons.size():
		_size_buttons[j].button_pressed = (j == i)


func _on_create() -> void:
	var world_name := _name_edit.text.strip_edges()
	if world_name.is_empty():
		world_name = "Мой мир"
	var seed_value := Game.parse_seed(_seed_edit.text)
	Game.start_new_world(world_name, seed_value, Game.WORLD_SIZES[_size_index]["chunks"])


func _on_continue() -> void:
	if _last_world_id != "":
		Game.start_saved_world(_last_world_id)


func _notification(what: int) -> void:
	# Кнопка «Назад» на Android: из любого экрана меню — на главный.
	if what == NOTIFICATION_WM_GO_BACK_REQUEST and _main and not _main.visible:
		_show("main")


# =============================================================================
#   Мелочи
# =============================================================================

func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _accent_box() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = UITheme.ACCENT.darkened(0.1)
	s.set_corner_radius_all(10)
	s.content_margin_left = 22
	s.content_margin_right = 22
	s.content_margin_top = 14
	s.content_margin_bottom = 14
	return s


func _size_name(chunks: int) -> String:
	for info in Game.WORLD_SIZES:
		if info["chunks"] == chunks:
			return info["name"]
	return "%d×%d" % [chunks * 16, chunks * 16]


func _format_date(unix: int) -> String:
	if unix <= 0:
		return ""
	var bias_minutes: int = Time.get_time_zone_from_system().get("bias", 0)
	var d := Time.get_datetime_dict_from_unix_time(unix + bias_minutes * 60)
	return "%02d.%02d.%d %02d:%02d" % [d["day"], d["month"], d["year"], d["hour"], d["minute"]]


func _draw_background(bg: Control) -> void:
	var s := bg.size
	# Небо: сверху синее, к горизонту светлее
	var top := Color(0.30, 0.50, 0.86)
	var bottom := Color(0.72, 0.84, 0.96)
	bg.draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(s.x, 0), s, Vector2(0, s.y)]),
		PackedColorArray([top, top, bottom, bottom]))
	# Земля из блоков внизу экрана — холмики разной высоты
	var t := 64.0
	var cols := ceili(s.x / t) + 1
	for cx in cols:
		var hill := 2 + int(round(sin(cx * 0.45) * 1.2 + sin(cx * 0.17 + 1.0) * 1.0))
		for row in hill + 1:
			var y := s.y - (row + 1) * t
			var id := Blocks.DIRT
			if row == hill:
				id = Blocks.GRASS
			elif row == 0:
				id = Blocks.STONE
			var shade := 1.0 - 0.08 * (hill - row)
			bg.draw_texture_rect_region(_atlas, Rect2(cx * t, y, t, t), BlockTextures.get_icon_region(id),
				Color(shade, shade, shade))
