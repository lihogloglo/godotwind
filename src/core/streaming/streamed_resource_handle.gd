class_name StreamedResourceHandle
extends RefCounted

var cache_key: String = ""
var packed_scene: PackedScene = null
var extracted_meshes: Array[Mesh] = []
var extracted_materials: Array[Material] = []
var owners: Dictionary = {}


func _init(p_cache_key: String = "", p_packed_scene: PackedScene = null) -> void:
	cache_key = p_cache_key
	set_packed_scene(p_packed_scene)


func set_packed_scene(scene: PackedScene) -> void:
	packed_scene = scene
	extracted_meshes.clear()
	extracted_materials.clear()
	if packed_scene != null:
		_collect_scene_state_resources(packed_scene)


func add_owner(owner: String) -> void:
	var key := owner if not owner.is_empty() else "external"
	owners[key] = int(owners.get(key, 0)) + 1


func remove_owner(owner: String) -> void:
	var key := owner if not owner.is_empty() else "external"
	if not owners.has(key):
		return
	var count := int(owners[key]) - 1
	if count > 0:
		owners[key] = count
	else:
		owners.erase(key)


func is_owned() -> bool:
	return not owners.is_empty()


func release() -> void:
	owners.clear()
	extracted_meshes.clear()
	extracted_materials.clear()
	packed_scene = null


func _collect_scene_state_resources(scene: PackedScene) -> void:
	var state := scene.get_state()
	if state == null:
		return
	var node_count := state.get_node_count()
	for node_index in node_count:
		var property_count := state.get_node_property_count(node_index)
		for property_index in property_count:
			var value: Variant = state.get_node_property_value(node_index, property_index)
			_collect_resource(value)


func _collect_resource(value: Variant) -> void:
	if value is Mesh:
		var mesh := value as Mesh
		if mesh not in extracted_meshes:
			extracted_meshes.append(mesh)
		_collect_mesh_materials(mesh)
	elif value is Material:
		var material := value as Material
		if material not in extracted_materials:
			extracted_materials.append(material)
	elif value is Array:
		for item: Variant in value:
			_collect_resource(item)
	elif value is Dictionary:
		for item: Variant in (value as Dictionary).values():
			_collect_resource(item)


func _collect_mesh_materials(mesh: Mesh) -> void:
	var surface_count := mesh.get_surface_count()
	for surface_index in surface_count:
		var material := mesh.surface_get_material(surface_index)
		if material != null and material not in extracted_materials:
			extracted_materials.append(material)
