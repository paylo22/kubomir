extends CanvasLayer
## Интерфейс поверх игры: прицел, панель блоков, строка с информацией,
## всплывающие сообщения, экран загрузки и сенсорное управление.

var touch_enabled := DisplayServer.is_touchscreen_available() or Game.force_touch_ui
var hotbar: Hotbar
var touch_controls: TouchControls # null, если сенсорного экрана нет

var _info: Label
var _block_name: Label
var _toast: Label
var _loading: ColorRect
var _loading_label: Label
var _loading_bar: ProgressBar
var _flying := false
var _name_timer := 0.0
var _toast_timer := 0.0


func setup(atlas: Texture2D) -> void:
	# --- Прицел в центре экрана ---
	var crosshair := Control.new()
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crosshair.draw.connect(func() -> void:
		crosshair.draw_line(Vector2(-12, 0), Vector2(12, 0), Color(1, 1, 1, 0.85), 2.0)
		crosshair.draw_line(Vector2(0, -12), Vector2(0, 12), Color(1, 1, 1, 0.85), 2.0))
	add_child(crosshair)

	# --- Сенсорное управление ---
	if touch_enabled:
		touch_controls = TouchControls.new()
		add_child(touch_controls)

	# --- Панель блоков: на планшете сверху (как в Survivalcraft), на ПК снизу ---
	hotbar = Hotbar.new()
	hotbar.atlas = atlas
	add_child(hotbar)
	var w := hotbar.size.x
	hotbar.anchor_left = 0.5
	hotbar.anchor_right = 0.5
	hotbar.offset_left = -w / 2
	hotbar.offset_right = w / 2
	if touch_enabled:
		hotbar.anchor_top = 0.0
		hotbar.anchor_bottom = 0.0
		hotbar.offset_top = 12
		hotbar.offset_bottom = 12 + Hotbar.SLOT
	else:
		hotbar.anchor_top = 1.0
		hotbar.anchor_bottom = 1.0
		hotbar.offset_top = -Hotbar.SLOT - 12
		hotbar.offset_bottom = -12
	hotbar.selection_changed.connect(_on_selection_changed)
	if touch_controls:
		touch_controls.hotbar = hotbar

	# --- Название выбранного блока (появляется ненадолго) ---
	_block_name = _make_label(22)
	_block_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_block_name.anchor_left = 0.0
	_block_name.anchor_right = 1.0
	if touch_enabled:
		_block_name.anchor_top = 0.0
		_block_name.anchor_bottom = 0.0
		_block_name.offset_top = 84
		_block_name.offset_bottom = 114
	else:
		_block_name.anchor_top = 1.0
		_block_name.anchor_bottom = 1.0
		_block_name.offset_top = -Hotbar.SLOT - 50
		_block_name.offset_bottom = -Hotbar.SLOT - 20
	_block_name.visible = false
	add_child(_block_name)

	# --- Всплывающее сообщение («Мир сохранён») ---
	_toast = _make_label(22)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.anchor_left = 0.0
	_toast.anchor_right = 1.0
	_toast.anchor_top = 0.62
	_toast.anchor_bottom = 0.62
	_toast.visible = false
	add_child(_toast)

	# --- Информация в левом верхнем углу ---
	_info = _make_label(16)
	_info.position = Vector2(12, 8)
	add_child(_info)

	# --- Экран загрузки ---
	_loading = ColorRect.new()
	_loading.color = Color(0.08, 0.1, 0.14)
	_loading.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_loading)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.offset_left = -240
	box.offset_right = 240
	box.offset_top = -70
	box.offset_bottom = 70
	box.add_theme_constant_override("separation", 10)
	_loading.add_child(box)
	var title := _make_label(44)
	title.text = "КУБОМИР"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	_loading_label = _make_label(22)
	_loading_label.text = "Готовимся…"
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_loading_label)
	_loading_bar = ProgressBar.new()
	_loading_bar.max_value = 1.0
	_loading_bar.show_percentage = false
	_loading_bar.custom_minimum_size = Vector2(480, 20)
	box.add_child(_loading_bar)


func _make_label(font_size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_x", 2)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func set_loading_progress(text: String, ratio: float) -> void:
	_loading_label.text = text
	_loading_bar.value = ratio


func hide_loading() -> void:
	_loading.visible = false


func set_flying(value: bool) -> void:
	_flying = value
	if touch_controls:
		touch_controls.set_flying(value)


## Короткое сообщение посреди экрана на пару секунд.
func show_toast(text: String, seconds := 2.0) -> void:
	_toast.text = text
	_toast.visible = true
	_toast_timer = seconds


func _on_selection_changed(_index: int) -> void:
	_block_name.text = Blocks.get_block_name(hotbar.get_selected_block())
	_block_name.visible = true
	_name_timer = 1.5


func _process(delta: float) -> void:
	if _name_timer > 0.0:
		_name_timer -= delta
		if _name_timer <= 0.0:
			_block_name.visible = false
	if _toast_timer > 0.0:
		_toast_timer -= delta
		if _toast_timer <= 0.0:
			_toast.visible = false


func update_info(player: Node3D) -> void:
	var text := ""
	if Game.settings["show_fps"]:
		var p := player.global_position
		text = "FPS: %d   X %d  Y %d  Z %d" % [Engine.get_frames_per_second(), floori(p.x), floori(p.y), floori(p.z)]
	if _flying:
		text += "   [Полёт]"
	if not touch_enabled:
		text += "\nЛКМ — ломать (держать), ПКМ — ставить, 1–8 / колёсико — блок, F — полёт, Shift — вниз, Esc — меню"
	_info.text = text
