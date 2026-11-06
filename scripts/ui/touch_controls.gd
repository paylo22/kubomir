class_name TouchControls
extends Control
## Сенсорное управление для планшета/телефона:
##  • левая часть экрана — джойстик (появляется там, где коснулся пальцем);
##  • правая часть — поворот камеры свайпом;
##  • круглые кнопки справа — прыжок, ломать, ставить, полёт, вниз, меню.
## Поддерживается несколько пальцев одновременно (идти и прыгать, идти и смотреть).
## Кнопки «нажимают» действия из Карты ввода (Input Map), поэтому игроку всё равно,
## нажата клавиша или кнопка на экране.

const JOY_RADIUS := 90.0
const KNOB_RADIUS := 38.0

var move_vector := Vector2.ZERO # куда тянут джойстик, длина от 0 до 1
var hotbar: Hotbar
var flying := false

var _look_delta := Vector2.ZERO
var _touches := {} # номер пальца -> что он делает
var _joy_center := Vector2.ZERO
var _joy_knob := Vector2.ZERO
var _joy_active := false
var _pressed := {} # action -> true

# Кнопки: действие, подпись, позиция от правого нижнего угла, радиус
var _buttons := [
	{"action": "jump", "label": "Прыжок", "from_br": Vector2(110, 120), "r": 64.0},
	{"action": "break_block", "label": "Ломать", "from_br": Vector2(270, 200), "r": 56.0},
	{"action": "place_block", "label": "Ставить", "from_br": Vector2(110, 290), "r": 56.0},
	{"action": "fly_down", "label": "Вниз", "from_br": Vector2(260, 70), "r": 48.0, "only_flying": true},
	{"action": "toggle_fly", "label": "Полёт", "from_tr": Vector2(80, 160), "r": 44.0},
	{"action": "pause", "label": "Меню", "from_tr": Vector2(64, 52), "r": 38.0},
]


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Сколько провели пальцем для поворота камеры с прошлого кадра (и обнулить).
func consume_look_delta() -> Vector2:
	var d := _look_delta
	_look_delta = Vector2.ZERO
	return d


## Отпустить все пальцы (например, при открытии паузы — иначе кнопка «залипнет»).
func release_all() -> void:
	for action in _pressed:
		Input.action_release(action)
	_pressed.clear()
	_touches.clear()
	_joy_active = false
	move_vector = Vector2.ZERO
	_look_delta = Vector2.ZERO
	queue_redraw()


func set_flying(value: bool) -> void:
	flying = value
	queue_redraw()


func _button_center(b: Dictionary) -> Vector2:
	var s := get_viewport_rect().size
	if b.has("from_tr"):
		return Vector2(s.x - b["from_tr"].x, b["from_tr"].y)
	return s - b["from_br"]


func _button_at(pos: Vector2) -> Dictionary:
	for b in _buttons:
		if b.get("only_flying", false) and not flying:
			continue
		if pos.distance_to(_button_center(b)) <= b["r"] * 1.15:
			return b
	return {}


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_on_touch_down(event.index, event.position)
		else:
			_on_touch_up(event.index)
	elif event is InputEventScreenDrag:
		_on_drag(event.index, event.position, event.relative)


func _on_touch_down(index: int, pos: Vector2) -> void:
	# 1) Панель блоков
	if hotbar:
		var slot := hotbar.get_slot_at(pos)
		if slot >= 0:
			hotbar.select(slot)
			_touches[index] = {"role": "none"}
			return
	# 2) Кнопки
	var b := _button_at(pos)
	if not b.is_empty():
		var action: String = b["action"]
		Input.action_press(action)
		_pressed[action] = true
		_touches[index] = {"role": "button", "action": action}
		queue_redraw()
		return
	# 3) Левая часть — джойстик, правая — камера
	var s := get_viewport_rect().size
	if pos.x < s.x * 0.4 and not _joy_active:
		_joy_active = true
		_joy_center = pos
		_joy_knob = pos
		move_vector = Vector2.ZERO
		_touches[index] = {"role": "joystick"}
	else:
		_touches[index] = {"role": "look"}
	queue_redraw()


func _on_drag(index: int, pos: Vector2, relative: Vector2) -> void:
	if not _touches.has(index):
		return
	match _touches[index]["role"]:
		"joystick":
			var offset := (pos - _joy_center).limit_length(JOY_RADIUS)
			_joy_knob = _joy_center + offset
			move_vector = offset / JOY_RADIUS
			queue_redraw()
		"look":
			_look_delta += relative


func _on_touch_up(index: int) -> void:
	if not _touches.has(index):
		return
	var t: Dictionary = _touches[index]
	match t["role"]:
		"joystick":
			_joy_active = false
			move_vector = Vector2.ZERO
		"button":
			Input.action_release(t["action"])
			_pressed.erase(t["action"])
	_touches.erase(index)
	queue_redraw()


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var s := get_viewport_rect().size

	# Джойстик (если не трогают — рисуем бледную подсказку внизу слева)
	var center := _joy_center if _joy_active else Vector2(170, s.y - 170)
	var knob := _joy_knob if _joy_active else center
	var alpha := 0.35 if _joy_active else 0.15
	draw_circle(center, JOY_RADIUS, Color(1, 1, 1, alpha * 0.6))
	draw_arc(center, JOY_RADIUS, 0, TAU, 48, Color(1, 1, 1, alpha + 0.2), 3.0)
	draw_circle(knob, KNOB_RADIUS, Color(1, 1, 1, alpha + 0.25))

	# Кнопки
	for b in _buttons:
		if b.get("only_flying", false) and not flying:
			continue
		var c := _button_center(b)
		var r: float = b["r"]
		var is_down: bool = _pressed.has(b["action"])
		if b["action"] == "toggle_fly" and flying:
			is_down = true # подсвечиваем, пока летим
		draw_circle(c, r, Color(1, 1, 1, 0.45 if is_down else 0.2))
		draw_arc(c, r, 0, TAU, 40, Color(1, 1, 1, 0.6), 3.0)
		var fs := 20
		draw_string(font, Vector2(c.x - r, c.y + fs * 0.35), b["label"], HORIZONTAL_ALIGNMENT_CENTER, r * 2, fs, Color(1, 1, 1, 0.9))
