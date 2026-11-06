class_name SettingsPanel
extends PanelContainer
## Панель настроек. Используется и в главном меню, и в меню паузы.
## Всё меняется сразу, а в файл записывается при нажатии «Назад».

signal closed

var _auto_jump: Button
var _show_fps: Button


func _ready() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	add_child(box)

	var title := UITheme.label("Настройки", 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	_add_slider(box, "Дальность прорисовки (чанков)", "view_distance", 3, 12, 1, "%d")
	_add_slider(box, "Чувствительность камеры (палец)", "touch_sensitivity", 0.2, 3.0, 0.1, "×%.1f")
	_add_slider(box, "Чувствительность мыши", "mouse_sensitivity", 0.2, 3.0, 0.1, "×%.1f")

	_auto_jump = UITheme.button("", _toggle.bind("auto_jump"), 520)
	_auto_jump.toggle_mode = true
	box.add_child(_auto_jump)
	_show_fps = UITheme.button("", _toggle.bind("show_fps"), 520)
	_show_fps.toggle_mode = true
	box.add_child(_show_fps)
	_refresh_toggles()

	var back := UITheme.button("Назад", _on_back, 520)
	box.add_child(back)


func _add_slider(box: VBoxContainer, title: String, key: String,
		min_value: float, max_value: float, step: float, fmt: String) -> void:
	var row := HBoxContainer.new()
	box.add_child(row)
	var name_label := UITheme.label(title, 22, UITheme.TEXT_DIM)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)
	var value_label := UITheme.label("", 22)
	row.add_child(value_label)

	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.custom_minimum_size = Vector2(520, 44)
	slider.value = float(Game.settings[key])
	var is_int := step >= 1.0
	var update_text := func(v: float) -> void:
		if is_int:
			value_label.text = fmt % int(v)
		else:
			value_label.text = fmt % v
	update_text.call(slider.value)
	slider.value_changed.connect(func(v: float) -> void:
		if is_int:
			Game.settings[key] = int(v)
		else:
			Game.settings[key] = v
		update_text.call(v))
	box.add_child(slider)


func _toggle(key: String) -> void:
	Game.settings[key] = not bool(Game.settings[key])
	_refresh_toggles()


func _refresh_toggles() -> void:
	_auto_jump.button_pressed = bool(Game.settings["auto_jump"])
	_auto_jump.text = "Автопрыжок: " + ("ВКЛ" if _auto_jump.button_pressed else "ВЫКЛ")
	_show_fps.button_pressed = bool(Game.settings["show_fps"])
	_show_fps.text = "Показывать FPS: " + ("ВКЛ" if _show_fps.button_pressed else "ВЫКЛ")


func _on_back() -> void:
	Game.save_settings()
	closed.emit()
