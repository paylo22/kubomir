class_name ChunkMeshJob
extends RefCounted
## «Задание» на постройку сетки одного чанка.
##
## Как это работает, чтобы игра не подтормаживала:
## 1. В основном потоке делаем быстрый «снимок» блоков чанка (+1 блок рамки вокруг).
## 2. В фоновом потоке по снимку считаем все вершины, текстуры и тени (это долго).
## 3. Снова в основном потоке отдаём готовые массивы видеокарте и физике (это быстро).
## Пока фоновый поток считает, игра спокойно рисует кадры.
##
## Главная хитрость сетки: рисуем только грани, которые граничат с воздухом
## (или прозрачным блоком). Грани между двумя камнями никто не видит.

const SIZE := WorldData.CHUNK_SIZE
const PW := SIZE + 2 # ширина снимка вместе с рамкой

# Шесть направлений граней: +X, -X, +Y (верх), -Y (низ), +Z, -Z
const NORMALS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
# Четыре угла каждой грани (по часовой стрелке, если смотреть снаружи —
# так Godot понимает, где у грани «лицо»).
const CORNERS := [
	[Vector3i(1, 1, 1), Vector3i(1, 1, 0), Vector3i(1, 0, 0), Vector3i(1, 0, 1)], # +X
	[Vector3i(0, 1, 0), Vector3i(0, 1, 1), Vector3i(0, 0, 1), Vector3i(0, 0, 0)], # -X
	[Vector3i(0, 1, 0), Vector3i(1, 1, 0), Vector3i(1, 1, 1), Vector3i(0, 1, 1)], # +Y
	[Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(1, 0, 0), Vector3i(0, 0, 0)], # -Y
	[Vector3i(0, 1, 1), Vector3i(1, 1, 1), Vector3i(1, 0, 1), Vector3i(0, 0, 1)], # +Z
	[Vector3i(1, 1, 0), Vector3i(0, 1, 0), Vector3i(0, 0, 0), Vector3i(1, 0, 0)], # -Z
]
# Какую текстуру брать: 0 = верхнюю, 1 = боковую, 2 = нижнюю
const FACE_KIND: Array[int] = [1, 1, 0, 2, 1, 1]
# Яркость граней — бока чуть темнее, низ ещё темнее. Так блоки выглядят объёмно.
const FACE_SHADE: Array[float] = [0.80, 0.80, 1.0, 0.55, 0.90, 0.90]
# Затенение в углах (ambient occlusion): много соседей у угла → темнее
const AO_CURVE: Array[float] = [0.55, 0.70, 0.85, 1.0]
const SHADOW_LIGHT := 0.45 # яркость там, куда не достаёт небо (пещеры, под навесом)

# Для каждого угла каждой грани — три соседа, которые затеняют этот угол.
static var AO_OFFSETS := _build_ao_offsets()

# --- Входные данные (снимок) ---
var chunk_pos: Vector2i
var height := 0
var ids := PackedByteArray()  # блоки снимка: столбцами снизу вверх, с рамкой
var sky := PackedInt32Array() # верхний непрозрачный блок каждого столбца
var tops := PackedInt32Array() # верхний непустой блок каждого столбца
var task_id := -1

# --- Результат ---
var opaque_arrays := []   # массивы для непрозрачных блоков (пусто, если граней нет)
var cutout_arrays := []   # для листвы
var collision_faces := PackedVector3Array() # треугольники для физики

# Рабочие переменные
var _ph := 0 # высота столбца в снимке (высота мира + 2)
var _ao_delta := PackedInt32Array()


## Снимок блоков чанка. Вызывать в основном потоке (быстро: ~1–3 мс).
static func snapshot(data: WorldData, cp: Vector2i) -> ChunkMeshJob:
	var job := ChunkMeshJob.new()
	job.chunk_pos = cp
	job.height = data.height
	var h := data.height
	var ph := h + 2
	var empty_column := PackedByteArray()
	empty_column.resize(ph)
	var below := PackedByteArray([Blocks.STONE]) # под миром «камень» — низ мира не рисуем
	var above := PackedByteArray([Blocks.AIR])
	var snap_ids := PackedByteArray()
	var snap_sky := PackedInt32Array()
	var snap_tops := PackedInt32Array()
	snap_sky.resize(PW * PW)
	snap_tops.resize(PW * PW)
	var blocks := data.blocks
	var x0 := cp.x * SIZE - 1
	var z0 := cp.y * SIZE - 1
	for pz in PW:
		for px in PW:
			var wx := x0 + px
			var wz := z0 + pz
			var ci := px + pz * PW
			if wx >= 0 and wx < data.size_x and wz >= 0 and wz < data.size_z:
				var col := wx + wz * data.size_x
				var start := col * h
				snap_ids.append_array(below)
				snap_ids.append_array(blocks.slice(start, start + h))
				snap_ids.append_array(above)
				snap_sky[ci] = data.heightmap[col]
				snap_tops[ci] = data.top_any[col]
			else:
				snap_ids.append_array(empty_column) # за краем мира — воздух
				snap_sky[ci] = -1
				snap_tops[ci] = -1
	job.ids = snap_ids
	job.sky = snap_sky
	job.tops = snap_tops
	return job


## Посчитать сетку. Можно вызывать в фоновом потоке: здесь нет узлов сцены.
func run() -> void:
	_ph = height + 2
	var zs := PW * _ph # шаг по Z в снимке
	_ao_delta.resize(6 * 4 * 3)
	for fi in 6:
		for c in 4:
			for k in 3:
				var o: Vector3i = AO_OFFSETS[fi][c][k]
				_ao_delta[fi * 12 + c * 3 + k] = o.y + o.x * _ph + o.z * zs

	var tlut := Blocks.TRANSPARENT_LUT
	var opaque := MeshData.new()
	var cutout := MeshData.new()
	for pz in range(1, PW - 1):
		for px in range(1, PW - 1):
			var ci := px + pz * PW
			var col := ci * _ph + 1 # +1: пропускаем «камень» под миром
			for y in tops[ci] + 1:
				var i := col + y
				var id := ids[i]
				if id == Blocks.AIR:
					continue
				var md := cutout if tlut[id] == 1 else opaque
				# Грань рисуем, только если сосед с той стороны прозрачный
				if tlut[ids[i + _ph]] == 1: _add_face(md, i, ci, px - 1, y, pz - 1, 0, id)
				if tlut[ids[i - _ph]] == 1: _add_face(md, i, ci, px - 1, y, pz - 1, 1, id)
				if tlut[ids[i + 1]] == 1: _add_face(md, i, ci, px - 1, y, pz - 1, 2, id)
				if tlut[ids[i - 1]] == 1: _add_face(md, i, ci, px - 1, y, pz - 1, 3, id)
				if tlut[ids[i + zs]] == 1: _add_face(md, i, ci, px - 1, y, pz - 1, 4, id)
				if tlut[ids[i - zs]] == 1: _add_face(md, i, ci, px - 1, y, pz - 1, 5, id)

	if not opaque.is_empty():
		opaque_arrays = opaque.to_arrays()
		opaque.append_triangles(collision_faces)
	if not cutout.is_empty():
		cutout_arrays = cutout.to_arrays()
		cutout.append_triangles(collision_faces)
	ids = PackedByteArray() # снимок больше не нужен — освобождаем память


func _add_face(md: MeshData, i: int, ci: int, lx: int, y: int, lz: int, fi: int, id: int) -> void:
	var n := NORMALS[fi]
	var corners: Array = CORNERS[fi]
	var tlut := Blocks.TRANSPARENT_LUT

	# Координаты текстуры в атласе
	var tile := Blocks.TILE_LUT[id * 3 + FACE_KIND[fi]]
	var tile_w := 1.0 / Blocks.T_COUNT
	var eps := 0.0005 # крошечный отступ, чтобы не залезать на соседнюю текстуру
	var u0 := tile * tile_w + eps
	var u1 := (tile + 1) * tile_w - eps

	# Видно ли небо из клетки перед гранью? Если нет — грань в тени.
	var light := FACE_SHADE[fi]
	if y + n.y <= sky[ci + n.x + n.z * PW]:
		light *= SHADOW_LIGHT

	# Затенение каждого из 4 углов
	var d := fi * 12
	var l0 := light * _corner_ao(i, d, tlut)
	var l1 := light * _corner_ao(i, d + 3, tlut)
	var l2 := light * _corner_ao(i, d + 6, tlut)
	var l3 := light * _corner_ao(i, d + 9, tlut)

	var start := md.verts.size()
	var normal := Vector3(n)
	var p := Vector3(lx, y, lz)
	md.verts.append(p + Vector3(corners[0]))
	md.verts.append(p + Vector3(corners[1]))
	md.verts.append(p + Vector3(corners[2]))
	md.verts.append(p + Vector3(corners[3]))
	md.normals.append(normal)
	md.normals.append(normal)
	md.normals.append(normal)
	md.normals.append(normal)
	md.uvs.append(Vector2(u0, eps))
	md.uvs.append(Vector2(u1, eps))
	md.uvs.append(Vector2(u1, 1.0 - eps))
	md.uvs.append(Vector2(u0, 1.0 - eps))
	md.colors.append(Color(l0, l0, l0))
	md.colors.append(Color(l1, l1, l1))
	md.colors.append(Color(l2, l2, l2))
	md.colors.append(Color(l3, l3, l3))

	# Два треугольника. Диагональ выбираем так, чтобы тени в углах были ровными.
	if l0 + l2 < l1 + l3:
		md.indices.append(start + 1)
		md.indices.append(start + 2)
		md.indices.append(start + 3)
		md.indices.append(start + 1)
		md.indices.append(start + 3)
		md.indices.append(start)
	else:
		md.indices.append(start)
		md.indices.append(start + 1)
		md.indices.append(start + 2)
		md.indices.append(start)
		md.indices.append(start + 2)
		md.indices.append(start + 3)


## Насколько светлый угол: смотрим на 3 соседних блока возле угла.
func _corner_ao(i: int, d: int, tlut: PackedByteArray) -> float:
	var s1 := tlut[ids[i + _ao_delta[d]]] == 0
	var s2 := tlut[ids[i + _ao_delta[d + 1]]] == 0
	if s1 and s2:
		return AO_CURVE[0]
	var cr := tlut[ids[i + _ao_delta[d + 2]]] == 0
	return AO_CURVE[3 - int(s1) - int(s2) - int(cr)]


static func _build_ao_offsets() -> Array:
	var result := []
	for fi in 6:
		var n: Vector3i = NORMALS[fi]
		var face := []
		for c in 4:
			var corner: Vector3i = CORNERS[fi][c]
			var dirs: Array[Vector3i] = []
			for axis in 3:
				if n[axis] != 0:
					continue
				var dv := Vector3i.ZERO
				dv[axis] = corner[axis] * 2 - 1
				dirs.append(dv)
			face.append([n + dirs[0], n + dirs[1], n + dirs[0] + dirs[1]])
		result.append(face)
	return result


## Временное хранилище вершин, пока собираем сетку.
class MeshData:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	func is_empty() -> bool:
		return verts.is_empty()

	func to_arrays() -> Array:
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_NORMAL] = normals
		arr[Mesh.ARRAY_TEX_UV] = uvs
		arr[Mesh.ARRAY_COLOR] = colors
		arr[Mesh.ARRAY_INDEX] = indices
		return arr

	## Добавить все треугольники (для коллизии) в общий список.
	func append_triangles(out: PackedVector3Array) -> void:
		for idx in indices:
			out.append(verts[idx])
