class_name CellPayload
extends RefCounted

const CS := preload("res://src/core/coordinate_system.gd")
const StreamedResourceHandleScript := preload("res://src/core/streaming/streamed_resource_handle.gd")

enum State {
	QUEUED_DATA,
	PREPARING_PAYLOAD,
	PAYLOAD_READY,
	VISUAL_PUBLISHING,
	VISUAL_READY,
	PHYSICS_PUBLISHING,
	ACTIVE,
	UNLOADING,
}

var grid: Vector2i = Vector2i.ZERO
var state: int = State.QUEUED_DATA

var static_refs_by_model: Dictionary = {}
var static_instance_transforms: Dictionary = {}
var static_expected_counts: Dictionary = {}
var interactive_refs: Array = []
var light_refs: Array = []
var model_keys: Dictionary = {}
var resource_refs: Array[Resource] = []
var resource_refs_by_key: Dictionary = {}
var resource_handles_by_key: Dictionary = {}
var stats: Dictionary = {
	"static_refs": 0,
	"interactive_refs": 0,
	"light_refs": 0,
	"model_keys": 0,
	"pinned_resources": 0,
}


func _init(p_grid: Vector2i = Vector2i.ZERO) -> void:
	grid = p_grid


static func make_model_key(model_path: String, item_id: String = "") -> String:
	var normalized := model_path.to_lower().replace("/", "\\")
	if not item_id.is_empty():
		return normalized + ":" + item_id.to_lower()
	return normalized


func add_model_key(model_path: String, item_id: String, type_name: String, route: String) -> String:
	if model_path.is_empty():
		return ""
	var key := make_model_key(model_path, item_id)
	if not model_keys.has(key):
		model_keys[key] = {
			"model_path": model_path,
			"item_id": item_id,
			"type_name": type_name,
			"route": route,
			"count": 0,
		}
		stats["model_keys"] = int(stats.get("model_keys", 0)) + 1
	model_keys[key]["count"] = int(model_keys[key].get("count", 0)) + 1
	return key


func add_static_ref(model_path: String, item_id: String, ref: CellReference) -> void:
	var key := add_model_key(model_path, item_id, "static", "static")
	if key.is_empty():
		return
	if not static_refs_by_model.has(key):
		static_refs_by_model[key] = []
		static_instance_transforms[key] = []
		static_expected_counts[key] = 0
	static_refs_by_model[key].append(ref)
	static_instance_transforms[key].append(_make_world_transform(ref))
	static_expected_counts[key] = int(static_expected_counts[key]) + 1
	stats["static_refs"] = int(stats.get("static_refs", 0)) + 1


func add_light_ref(model_path: String, item_id: String, ref: CellReference) -> void:
	light_refs.append(ref)
	if not model_path.is_empty():
		add_model_key(model_path, item_id, "light", "light")
	stats["light_refs"] = int(stats.get("light_refs", 0)) + 1


func add_interactive_ref(type_name: String, model_path: String, item_id: String, ref: CellReference) -> void:
	interactive_refs.append(ref)
	if not model_path.is_empty():
		add_model_key(model_path, item_id, type_name, "interactive")
	stats["interactive_refs"] = int(stats.get("interactive_refs", 0)) + 1


func pin_model_resource(model_path: String, item_id: String, packed_scene: PackedScene) -> void:
	if packed_scene == null:
		return
	var key := make_model_key(model_path, item_id)
	var handle := StreamedResourceHandleScript.new(key, packed_scene)
	pin_model_handle(model_path, item_id, handle)


func pin_model_handle(model_path: String, item_id: String, handle: RefCounted) -> void:
	if handle == null or handle.packed_scene == null:
		return
	var key := make_model_key(model_path, item_id)
	var owner := _owner_key()
	if resource_handles_by_key.has(key):
		return
	handle.add_owner(owner)
	resource_handles_by_key[key] = handle
	resource_refs_by_key[key] = handle.packed_scene
	resource_refs.append(handle.packed_scene)
	stats["pinned_resources"] = resource_handles_by_key.size()


func restore_model_resource(model_loader: Object, model_path: String, item_id: String) -> bool:
	if model_loader == null or model_path.is_empty():
		return false
	var key := make_model_key(model_path, item_id)
	var handle: RefCounted = resource_handles_by_key.get(key) as RefCounted
	var packed_scene: PackedScene = handle.packed_scene if handle != null else resource_refs_by_key.get(key) as PackedScene
	if packed_scene == null:
		return false
	if model_loader.has_method("get_cached_packed_scene"):
		var cached: PackedScene = model_loader.call("get_cached_packed_scene", model_path, item_id)
		if cached != null:
			return true
	if model_loader.has_method("put_cached_packed_scene"):
		return bool(model_loader.call("put_cached_packed_scene", model_path, item_id, packed_scene))
	return false


func release_resource_handles() -> void:
	var owner := _owner_key()
	for handle_value: Variant in resource_handles_by_key.values():
		var handle: RefCounted = handle_value as RefCounted
		if handle != null:
			handle.remove_owner(owner)
	resource_handles_by_key.clear()
	resource_refs_by_key.clear()
	resource_refs.clear()
	stats["pinned_resources"] = 0


func bind_resource_handles_to_node(node: Node) -> void:
	if node == null or resource_handles_by_key.is_empty():
		return
	var handles: Array[RefCounted] = []
	for handle_value: Variant in resource_handles_by_key.values():
		var handle: RefCounted = handle_value as RefCounted
		if handle != null and handle not in handles:
			handles.append(handle)
	node.set_meta("_streamed_resource_handles", handles)


func _owner_key() -> String:
	return "cell:%s,%s" % [grid.x, grid.y]


func _make_world_transform(ref: CellReference) -> Transform3D:
	var pos := CS.vector_to_godot(ref.position)
	var scale := CS.scale_to_godot(ref.scale)
	var basis := CS.esm_rotation_to_godot_basis(ref.rotation)
	basis = basis.scaled(scale)
	return Transform3D(basis, pos)
