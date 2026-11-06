class_name Chunk
extends StaticBody3D
## Чанк — кусок мира 16×16 блоков на всю высоту: его 3D-сетка и коллизия.
## Сетку считает ChunkMeshJob (в фоне), а чанк только показывает готовый результат.

var chunk_pos: Vector2i
var _mesh_instance := MeshInstance3D.new()
var _collision := CollisionShape3D.new()


func _init(cp: Vector2i) -> void:
	chunk_pos = cp
	name = "Chunk_%d_%d" % [cp.x, cp.y]
	position = Vector3(cp.x * WorldData.CHUNK_SIZE, 0, cp.y * WorldData.CHUNK_SIZE)
	add_child(_mesh_instance)
	add_child(_collision)


## Показать результат задания (вызывается в основном потоке).
func apply(job: ChunkMeshJob, opaque_material: Material, cutout_material: Material) -> void:
	var mesh := ArrayMesh.new()
	if not job.opaque_arrays.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, job.opaque_arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, opaque_material)
	if not job.cutout_arrays.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, job.cutout_arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, cutout_material)
	_mesh_instance.mesh = mesh
	if job.collision_faces.is_empty():
		_collision.shape = null
	else:
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(job.collision_faces)
		_collision.shape = shape
