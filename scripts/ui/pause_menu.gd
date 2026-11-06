extends CanvasLayer
## Меню паузы: продолжить, настройки, сохранить, выйти в главное меню.
## Открывается кнопкой «Меню» на экране, клавишей Esc или кнопкой «Назад» на Android.
## Этот узел работает даже на паузе (process_mode = ALWAYS), остальная игра — замирает.

signal opened
signal resumed
signal save_requested
signal quit_requested
signal map_requested

## Можно ли открыть паузу (во время загрузки мира — нельзя).
var enabled := false
var _root: Control
var _main: VBoxContainer
var _settings: SettingsPanel
var _status: Label
var _map_panel: PanelContainer
var _map_view: MapView


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 10
	_root = Control.new()
	_root.theme = UITheme.create()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)
	_main = VBoxContainer.new()
	_main.add_theme_constant_override("separation", 14)
	panel.add_child(_main)
	var title := UITheme.label("Пауза", 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_main.add_child(title)
	_main.add_child(UITheme.button("Продолжить", close, 420))
	_main.add_child(UITheme.button("Карта", func() -> void: map_requested.emit(), 420))
	_main.add_child(UITheme.button("Настройки", _open_settings, 420))
	_main.add_child(UITheme.button("Сохранить", func() -> void: save_requested.emit(), 420))
	_main.add_child(UITheme.button("Сохранить и выйти в меню", func() -> void: quit_requested.emit(), 420))
	_status = UITheme.label("", 20, UITheme.TEXT_DIM)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_main.add_child(_status)

	_settings = SettingsPanel.new()
	_settings.visible = false
	_settings.closed.connect(_close_settings)
	center.add_child(_settings)

	# Окно карты
	_map_panel = PanelContainer.new()
	_map_panel.visible = false
	center.add_child(_map_panel)
	var map_box := VBoxContainer.new()
	map_box.add_theme_constant_override("separation", 10)
	_map_panel.add_child(map_box)
	var map_title := UITheme.label("Карта", 30)
	map_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	map_box.add_child(map_title)
	_map_view = MapView.new()
	map_box.add_child(_map_view)
	map_box.add_child(UITheme.button("Назад", _close_map, 500))
	visible = false


func is_open() -> bool:
	return visible


func open() -> void:
	if visible:
		return
	visible = true
	_main.get_parent().visible = true
	_settings.visible = false
	_map_panel.visible = false
	_status.text = ""
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	opened.emit()


func close() -> void:
	if not visible:
		return
	if _settings.visible:
		Game.save_settings()
	visible = false
	get_tree().paused = false
	resumed.emit()


func show_status(text: String) -> void:
	_status.text = text


## Показать карту. uv — где игрок (0..1 по ширине и высоте мира), yaw — куда смотрит.
func show_map(texture: Texture2D, uv: Vector2, yaw: float) -> void:
	_map_view.texture = texture
	_map_view.show_player(uv, yaw)
	_main.get_parent().visible = false
	_settings.visible = false
	_map_panel.visible = true


func _close_map() -> void:
	_map_panel.visible = false
	_main.get_parent().visible = true


func _open_settings() -> void:
	_main.get_parent().visible = false
	_settings.visible = true


func _close_settings() -> void:
	_settings.visible = false
	_main.get_parent().visible = true


func _toggle() -> void:
	if not enabled:
		return
	if not visible:
		open()
	elif _settings.visible:
		Game.save_settings()
		_close_settings()
	elif _map_panel.visible:
		_close_map()
	else:
		close()


var _was_pressed := false

func _process(_delta: float) -> void:
	var pressed := Input.is_action_pressed("pause")
	if pressed and not _was_pressed:
		_toggle()
	_was_pressed = pressed


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_toggle()
