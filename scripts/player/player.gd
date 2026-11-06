extends CharacterBody3D
## Игрок: ходьба, прыжки, полёт, поворот камеры, удары по блокам и установка блоков.
##
## Важно: игрок сам мир НЕ меняет. Он отправляет команды серверу через session:
##   session.send_command({"type": "hit_block", ...})
## и сообщает, где находится: session.report_state({...}).
## Так игра уже устроена «как сетевая» — потом команды просто пойдут по сети.

@export_group("Движение")
@export var walk_speed := 4.5
@export var fly_speed := 10.0
@export var jump_velocity := 8.0
@export var gravity := 24.0
@export var swim_speed_factor := 0.55 ## во сколько раз медленнее двигаемся в воде
@export var swim_up_speed := 3.5      ## скорость всплытия, если держать «Прыжок»
@export var sink_speed := 1.2         ## скорость, с которой медленно тонем

@export_group("Камера")
@export var mouse_sensitivity := 0.0025 ## умножается на настройку из меню
@export var touch_sensitivity := 0.006  ## умножается на настройку из меню

@export_group("Блоки")
@export var reach := 6.0          ## как далеко достаёт рука (в блоках)
@export var place_repeat := 0.25  ## если держать «Ставить» — блоки ставятся с таким интервалом

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D

var session: Node   # GameSession (scripts/game_session.gd)
var world: WorldView
var hud: Node       # HUD (scripts/ui/hud.gd)

var flying := false
var in_water := false
var _active := false # включается, когда мир вокруг построен
var _target := {}    # блок, на который смотрим
var _highlight: MeshInstance3D
var _hit_timer := 0.0
var _place_timer := 0.0
# Были ли кнопки нажаты в прошлом кадре (так ловим момент нажатия сами, надёжно).
var _was_breaking := false
var _was_placing := false
var _was_fly := false


func _ready() -> void:
	_highlight = _make_highlight()
	add_child(_highlight)


## Появиться в мире. state — то, что прислал сервер (позиция, поворот, полёт, выбранный блок).
func spawn(state: Dictionary) -> void:
	global_position = state.get("pos", Vector3.ZERO)
	rotation.y = float(state.get("yaw", 0.0))
	head.rotation.x = float(state.get("pitch", 0.0))
	flying = bool(state.get("flying", false))
	hud.set_flying(flying)
	hud.hotbar.select(int(state.get("hotbar", 0)))
	velocity = Vector3.ZERO
	_active = true


func _unhandled_input(event: InputEvent) -> void:
	# На сенсорном экране Godot «изображает» мышь из касаний — такие события пропускаем,
	# касания обрабатывает TouchControls. Ниже — только настоящая мышь.
	if event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_look(event.relative * mouse_sensitivity * float(Game.settings["mouse_sensitivity"]))

	if event is InputEventMouseButton:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			# Первый клик по окну только «захватывает» мышь
			if event.pressed and _active:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				_set_action("break_block", event.pressed)
			MOUSE_BUTTON_RIGHT:
				_set_action("place_block", event.pressed)
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					hud.hotbar.select(hud.hotbar.selected - 1)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					hud.hotbar.select(hud.hotbar.selected + 1)

	# Выбор блока цифрами 1–9
	if event is InputEventKey and event.pressed and not event.echo:
		var k: int = event.physical_keycode
		if k >= KEY_1 and k <= KEY_9:
			hud.hotbar.select(k - KEY_1)


func _set_action(action: String, pressed: bool) -> void:
	if pressed:
		Input.action_press(action)
	else:
		Input.action_release(action)


## Отпустить кнопки мыши (при паузе), чтобы они не «залипли».
func release_inputs() -> void:
	Input.action_release("break_block")
	Input.action_release("place_block")


func _look(delta: Vector2) -> void:
	rotation.y -= delta.x                       # поворот тела влево-вправо
	head.rotation.x = clampf(head.rotation.x - delta.y, deg_to_rad(-89), deg_to_rad(89)) # голова вверх-вниз


func _physics_process(delta: float) -> void:
	if not _active:
		return

	# Поворот камеры пальцем
	if hud.touch_controls:
		var sens := touch_sensitivity * float(Game.settings["touch_sensitivity"])
		_look(hud.touch_controls.consume_look_delta() * sens)

	var fly_pressed := Input.is_action_pressed("toggle_fly")
	if fly_pressed and not _was_fly:
		flying = not flying
		velocity.y = 0.0
		hud.set_flying(flying)
	_was_fly = fly_pressed

	# Направление движения: клавиатура или джойстик (что сильнее отклонено)
	var move_input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if hud.touch_controls:
		var stick: Vector2 = hud.touch_controls.move_vector
		if stick.length() > move_input.length():
			move_input = stick
	var dir := transform.basis * Vector3(move_input.x, 0, move_input.y)

	in_water = _check_in_water()
	if flying:
		var vertical := 0.0
		if Input.is_action_pressed("jump"):
			vertical += 1.0
		if Input.is_action_pressed("fly_down"):
			vertical -= 1.0
		velocity = dir * fly_speed + Vector3(0, vertical * fly_speed * 0.8, 0)
	elif in_water:
		_swim(delta, dir)
	else:
		velocity.y = maxf(velocity.y - gravity * delta, -50.0)
		if is_on_floor():
			if Input.is_action_pressed("jump"):
				velocity.y = jump_velocity
			elif _auto_jump_enabled() and dir.length() > 0.1 and _step_ahead(dir):
				velocity.y = jump_velocity
		var target := dir * walk_speed
		var accel := 14.0 if is_on_floor() else 5.0
		velocity.x = lerpf(velocity.x, target.x, clampf(accel * delta, 0, 1))
		velocity.z = lerpf(velocity.z, target.z, clampf(accel * delta, 0, 1))

	move_and_slide()
	_keep_inside_world()
	session.report_state({
		"pos": global_position,
		"yaw": rotation.y,
		"pitch": head.rotation.x,
		"flying": flying,
		"hotbar": hud.hotbar.selected,
	})
	_update_target()
	_handle_blocks(delta)
	hud.update_info(self, world.loaded_count())


func _auto_jump_enabled() -> bool:
	return hud.touch_controls != null and bool(Game.settings["auto_jump"])


## Плавание: медленно тонем, «Прыжок» — вверх, «Вниз» — нырнуть.
func _swim(delta: float, dir: Vector3) -> void:
	if velocity.y < -4.0:
		velocity.y = lerpf(velocity.y, -4.0, 0.25) # вода тормозит падение — «плюх»
	var target_vy := -sink_speed
	if Input.is_action_pressed("jump"):
		target_vy = swim_up_speed
	elif Input.is_action_pressed("fly_down"):
		target_vy = -swim_up_speed
	velocity.y = move_toward(velocity.y, target_vy, 14.0 * delta)
	# Упёрлись в берег — выбираемся (сами, если включён автопрыжок)
	if is_on_wall() and dir.length() > 0.1 and (Input.is_action_pressed("jump") or _auto_jump_enabled()):
		velocity.y = maxf(velocity.y, 5.5)
	var target := dir * walk_speed * swim_speed_factor
	velocity.x = lerpf(velocity.x, target.x, clampf(6.0 * delta, 0, 1))
	velocity.z = lerpf(velocity.z, target.z, clampf(6.0 * delta, 0, 1))


## В воде ли мы: вода у ног или у пояса.
func _check_in_water() -> bool:
	var data := world.data
	var p := global_position
	var x := floori(p.x)
	var z := floori(p.z)
	return data.get_block(x, floori(p.y + 0.2), z) == Blocks.WATER \
		or data.get_block(x, floori(p.y + 1.0), z) == Blocks.WATER


## Голова под водой? (для синего тумана)
func is_head_underwater() -> bool:
	var c := camera.global_position
	return world.data.get_block(floori(c.x), floori(c.y), floori(c.z)) == Blocks.WATER


## Есть ли впереди ступенька высотой в один блок, на которую можно запрыгнуть?
func _step_ahead(dir: Vector3) -> bool:
	var data := world.data
	var ahead := global_position + dir.normalized() * 0.6
	var fx := floori(ahead.x)
	var fz := floori(ahead.z)
	var fy := floori(global_position.y + 0.1)
	return data.is_solid(fx, fy, fz) \
		and not data.is_solid(fx, fy + 1, fz) \
		and not data.is_solid(fx, fy + 2, fz) \
		and not data.is_solid(floori(global_position.x), fy + 2, floori(global_position.z))


func _keep_inside_world() -> void:
	var data := world.data
	var p := global_position
	p.x = clampf(p.x, 0.35, data.size_x - 0.35)
	p.z = clampf(p.z, 0.35, data.size_z - 0.35)
	if p.y < -20.0: # упал за край — возвращаем на точку появления
		p = data.get_spawn_position()
		velocity = Vector3.ZERO
	global_position = p


# =============================================================================
#   Удары по блокам и установка
# =============================================================================

func _update_target() -> void:
	var origin := camera.global_position
	var forward := -camera.global_transform.basis.z
	_target = world.data.raycast(origin, forward, reach)
	if _target.get("hit", false):
		var p: Vector3i = _target["pos"]
		_highlight.visible = true
		_highlight.global_position = Vector3(p)
	else:
		_highlight.visible = false


func _handle_blocks(delta: float) -> void:
	_hit_timer -= delta
	_place_timer -= delta

	# Держим «Ломать» — бьём по блоку 5 раз в секунду. Урон копится, пока блок не сломается.
	var breaking := Input.is_action_pressed("break_block")
	if breaking and _target.get("hit", false):
		if not _was_breaking or _hit_timer <= 0.0:
			_hit_timer = 1.0 / Damage.HITS_PER_SECOND
			session.send_command({
				"type": "hit_block",
				"pos": _target["pos"],
				"damage": Damage.HAND,
				"damage_type": Damage.MELEE,
			})
	_was_breaking = breaking

	var placing := Input.is_action_pressed("place_block")
	if placing and _target.get("hit", false):
		if not _was_placing or _place_timer <= 0.0:
			_place_timer = place_repeat
			var p: Vector3i = _target["pos"] + _target["normal"]
			session.send_command({
				"type": "place_block",
				"pos": p,
				"block": hud.hotbar.get_selected_block(),
			})
	_was_placing = placing


## Чёрная рамка вокруг блока, на который смотрим.
func _make_highlight() -> MeshInstance3D:
	var e := 0.005
	var a := Vector3(-e, -e, -e)
	var b := Vector3(1 + e, 1 + e, 1 + e)
	var c := [
		Vector3(a.x, a.y, a.z), Vector3(b.x, a.y, a.z), Vector3(b.x, a.y, b.z), Vector3(a.x, a.y, b.z),
		Vector3(a.x, b.y, a.z), Vector3(b.x, b.y, a.z), Vector3(b.x, b.y, b.z), Vector3(a.x, b.y, b.z),
	]
	var edges := [0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7]
	var verts := PackedVector3Array()
	for i in edges:
		verts.append(c[i])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.05, 0.05, 0.05)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.top_level = true # не крутится вместе с игроком
	mi.visible = false
	return mi
