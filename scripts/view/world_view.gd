class_name WorldView
extends Node3D
## Картинка мира: чанки, трещины на повреждённых блоках, осколки при разрушении.
## Сам мир (блоки) хранится в WorldData, а этот узел только показывает его.
## Когда сервер что-то меняет, он присылает событие — и мы перерисовываем нужное.

signal spawn_area_ready ## построены чанки вокруг точки появления — можно пускать игрока

@export var use_threads := true      ## строить сетку чанков в фоновых потоках
@export var max_parallel_jobs := 0   ## сколько чанков строить одновременно (0 = по числу ядер)
@export var snapshot_budget_ms := 4.0 ## сколько мс за кадр можно тратить на снимки чанков
@export var apply_budget_ms := 6.0    ## сколько мс за кадр можно тратить на выдачу готовых чанков

var data: WorldData
var atlas: ImageTexture
var atlas_image: Image
var opaque_material: StandardMaterial3D
var cutout_material: StandardMaterial3D # для листвы (с дырочками)
var chunks := {} # Vector2i -> Chunk
## Насколько построен мир при загрузке (0..1).
var initial_progress := 0.0

var _queue: Array[Vector2i] = [] # чанки, которые ждут перестройки
var _queued := {}
var _running := {}  # чанк -> задание, которое сейчас считается
var _dirty := {}    # чанки, изменившиеся, пока их уже считали
var _initial_pending := {}
var _initial_total := 0
var _spawn_waiting := {}
var _spawn_emitted := false

var _cracks := {} # Vector3i -> MeshInstance3D
var _crack_mesh: ArrayMesh
var _crack_materials: Array[StandardMaterial3D] = []
var _block_colors := PackedColorArray()
var _particle_mesh: BoxMesh
var _particle_scale_curve: Curve


func _ready() -> void:
	atlas_image = BlockTextures.create_atlas_image()
	atlas = ImageTexture.create_from_image(atlas_image)
	opaque_material = _make_material(false)
	cutout_material = _make_material(true)
	_setup_cracks()
	_setup_particles()


func _make_material(cutout: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = atlas
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST # чёткие пиксели
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED    # освещение «запечено» в цвет вершин
	m.vertex_color_use_as_albedo = true
	if cutout:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		m.alpha_scissor_threshold = 0.5
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## Начать показывать мир. focus — откуда строить в первую очередь (где появится игрок).
func attach(world_data: WorldData, focus: Vector3) -> void:
	data = world_data
	var focus_chunk := Vector2i(floori(focus.x / WorldData.CHUNK_SIZE), floori(focus.z / WorldData.CHUNK_SIZE))
	var order: Array[Vector2i] = []
	for cz in data.chunk_count_z():
		for cx in data.chunk_count_x():
			var cp := Vector2i(cx, cz)
			var chunk := Chunk.new(cp)
			chunks[cp] = chunk
			add_child(chunk)
			order.append(cp)
			_initial_pending[cp] = true
			if absi(cx - focus_chunk.x) <= 1 and absi(cz - focus_chunk.y) <= 1:
				_spawn_waiting[cp] = true
	order.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.distance_squared_to(focus_chunk) < b.distance_squared_to(focus_chunk))
	for cp in order:
		_enqueue(cp, false)
	_initial_total = order.size()
	# Трещины на блоках, повреждённых до сохранения
	for pos in data.damage:
		_update_crack(pos)


# =============================================================================
#   События от сервера
# =============================================================================

func on_block_changed(pos: Vector3i, new_id: int, old_id: int) -> void:
	# В одиночной игре сервер уже поменял блок в этих же данных.
	# По сети у игрока будет своя копия мира — тогда эта строчка её обновит.
	if data.get_block(pos.x, pos.y, pos.z) != new_id:
		data.set_block(pos.x, pos.y, pos.z, new_id)
	_remove_crack(pos)
	# Перестраиваем чанк блока и соседние (если блок у границы — у них меняются грани и тени).
	var own := _chunk_of(pos.x, pos.z)
	request_rebuild(own, true)
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var cp := _chunk_of(pos.x + dx, pos.z + dz)
			if cp != own:
				request_rebuild(cp, true)
	if new_id == Blocks.AIR and old_id != Blocks.AIR:
		_spawn_break_particles(pos, old_id)


func on_block_damaged(pos: Vector3i, damage: float) -> void:
	data.set_damage(pos, damage)
	_update_crack(pos)


func _chunk_of(x: int, z: int) -> Vector2i:
	return Vector2i(floori(float(x) / WorldData.CHUNK_SIZE), floori(float(z) / WorldData.CHUNK_SIZE))


# =============================================================================
#   Очередь перестройки чанков
# =============================================================================

func request_rebuild(cp: Vector2i, urgent: bool) -> void:
	if not chunks.has(cp):
		return
	if _running.has(cp):
		_dirty[cp] = true # досчитаем текущее и сразу пересчитаем ещё раз
		return
	if _queued.has(cp):
		if urgent:
			_queue.erase(cp)
			_queue.push_front(cp)
		return
	_enqueue(cp, urgent)


func _enqueue(cp: Vector2i, urgent: bool) -> void:
	_queued[cp] = true
	if urgent:
		_queue.push_front(cp)
	else:
		_queue.push_back(cp)


func _process(_delta: float) -> void:
	if data == null:
		return
	_collect_finished()
	_start_jobs()


func _start_jobs() -> void:
	var limit := max_parallel_jobs if max_parallel_jobs > 0 else maxi(1, OS.get_processor_count() - 1)
	var t0 := Time.get_ticks_usec()
	while not _queue.is_empty() and _running.size() < limit:
		var cp: Vector2i = _queue.pop_front()
		_queued.erase(cp)
		var job := ChunkMeshJob.snapshot(data, cp)
		if use_threads:
			job.task_id = WorkerThreadPool.add_task(job.run, false, "Сетка чанка")
			_running[cp] = job
		else:
			job.run()
			_apply(job)
		if (Time.get_ticks_usec() - t0) / 1000.0 > snapshot_budget_ms:
			break


func _collect_finished() -> void:
	# Выдача готового чанка (сетка + коллизия) занимает несколько мс в основном потоке.
	# Если готово сразу много — раздаём по нескольку за кадр, чтобы не было рывка.
	var t0 := Time.get_ticks_usec()
	for cp in _running.keys():
		var job: ChunkMeshJob = _running[cp]
		if not WorkerThreadPool.is_task_completed(job.task_id):
			continue
		WorkerThreadPool.wait_for_task_completion(job.task_id)
		_running.erase(cp)
		_apply(job)
		if _dirty.has(cp):
			_dirty.erase(cp)
			_enqueue(cp, true)
		if (Time.get_ticks_usec() - t0) / 1000.0 > apply_budget_ms:
			break


func _apply(job: ChunkMeshJob) -> void:
	var cp := job.chunk_pos
	chunks[cp].apply(job, opaque_material, cutout_material)
	if _initial_pending.has(cp):
		_initial_pending.erase(cp)
		initial_progress = 1.0 - float(_initial_pending.size()) / maxi(1, _initial_total)
	if _spawn_waiting.has(cp):
		_spawn_waiting.erase(cp)
		if _spawn_waiting.is_empty() and not _spawn_emitted:
			_spawn_emitted = true
			spawn_area_ready.emit()


## Дождаться всех фоновых заданий (например, перед выходом из мира).
func finish_all_jobs() -> void:
	for cp in _running:
		WorkerThreadPool.wait_for_task_completion(_running[cp].task_id)
	_running.clear()


func _exit_tree() -> void:
	finish_all_jobs()


# =============================================================================
#   Трещины
# =============================================================================

func _setup_cracks() -> void:
	for tex in BlockTextures.create_crack_textures():
		var m := StandardMaterial3D.new()
		m.albedo_texture = tex
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_crack_materials.append(m)
	# Кубик чуть больше блока, на всех гранях — текстура трещин целиком.
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var uv_corners: Array[Vector2] = [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	for fi in 6:
		var start := verts.size()
		for c in 4:
			var corner: Vector3i = ChunkMeshJob.CORNERS[fi][c]
			verts.append(Vector3(corner) * 1.006 - Vector3.ONE * 0.003)
			uvs.append(uv_corners[c])
		indices.append_array([start, start + 1, start + 2, start, start + 2, start + 3])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = indices
	_crack_mesh = ArrayMesh.new()
	_crack_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)


func _update_crack(pos: Vector3i) -> void:
	var id := data.get_block(pos.x, pos.y, pos.z)
	var hp := Blocks.get_hp(id)
	var dmg := data.get_damage(pos)
	if id == Blocks.AIR or hp <= 0.0 or dmg <= 0.0:
		_remove_crack(pos)
		return
	var stage := clampi(int(dmg / hp * BlockTextures.CRACK_STAGES), 0, BlockTextures.CRACK_STAGES - 1)
	var mi: MeshInstance3D = _cracks.get(pos)
	if mi == null:
		mi = MeshInstance3D.new()
		mi.mesh = _crack_mesh
		mi.position = Vector3(pos)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_cracks[pos] = mi
	mi.material_override = _crack_materials[stage]


func _remove_crack(pos: Vector3i) -> void:
	var mi: MeshInstance3D = _cracks.get(pos)
	if mi:
		mi.queue_free()
		_cracks.erase(pos)


# =============================================================================
#   Осколки при разрушении блока
# =============================================================================

func _setup_particles() -> void:
	_block_colors.resize(Blocks.COUNT)
	for id in Blocks.COUNT:
		_block_colors[id] = BlockTextures.average_color(atlas_image, id)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	_particle_mesh = BoxMesh.new()
	_particle_mesh.size = Vector3(0.13, 0.13, 0.13)
	_particle_mesh.material = mat
	_particle_scale_curve = Curve.new()
	_particle_scale_curve.add_point(Vector2(0, 1))
	_particle_scale_curve.add_point(Vector2(1, 0.2))


func _spawn_break_particles(pos: Vector3i, block_id: int) -> void:
	var p := CPUParticles3D.new()
	p.mesh = _particle_mesh
	p.amount = 16
	p.lifetime = 0.55
	p.one_shot = true
	p.explosiveness = 0.95
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(0.35, 0.35, 0.35)
	p.direction = Vector3.UP
	p.spread = 75.0
	p.initial_velocity_min = 1.5
	p.initial_velocity_max = 3.5
	p.gravity = Vector3(0, -14, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.3
	p.scale_amount_curve = _particle_scale_curve
	var c := _block_colors[block_id] if block_id < _block_colors.size() else Color.WHITE
	# Осколки в тени — темнее (как и сам блок).
	if pos.y < data.get_column_top(pos.x, pos.z):
		c = c.darkened(0.5)
	p.color = c
	p.position = Vector3(pos) + Vector3(0.5, 0.5, 0.5)
	add_child(p)
	p.emitting = true
	get_tree().create_timer(1.5).timeout.connect(p.queue_free)
