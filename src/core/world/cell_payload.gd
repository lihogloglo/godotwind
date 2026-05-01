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
var static_prepare_entries_by_key: Dictionary = {}
var static_prepare_enqueued: Dictionary[String, bool] = {}
var static_buckets_by_key: Dictionary[String, RefCounted] = {}
var pending_model_loads_by_key: Dictionary = {}
var completed_model_loads: Array[Dictionary] = []
var completed_model_load_keys: Dictionary[String, bool] = {}
## Per-cell static collision publish state. CellManager still drives the
## pipeline, but the worker payload, task id, and finalized PhysicsServer body
## are owned by the same payload record as the visual publish queues.
var collision_built: bool = false
var collision_dispatched: bool = false
var collision_payload: Variant = null
var collision_task_id: int = -1
var collision_body: Variant = null
var publish_driver: Callable = Callable()
var stats: Dictionary = {
	"static_refs": 0,
	"interactive_refs": 0,
	"light_refs": 0,
	"model_keys": 0,
	"pinned_resources": 0,
	"static_prepare_queue": 0,
	"static_buckets": 0,
	"pending_model_loads": 0,
	"completed_model_loads": 0,
}


func _init(p_grid: Vector2i = Vector2i.ZERO) -> void:
	grid = p_grid


func configure_publish_driver(driver: Callable) -> void:
	publish_driver = driver


func publish_step(budget_usec: int) -> int:
	if budget_usec <= 0 or state == State.UNLOADING:
		return 0
	if not publish_driver.is_valid():
		return 0
	return maxi(0, int(publish_driver.call(self, budget_usec)))


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


func enqueue_static_prepare(
	request_id: int,
	type_name: String,
	model_path: String,
	item_id: String,
	key: String,
	expected_count: int,
) -> bool:
	if key.is_empty() or bool(static_prepare_enqueued.get(key, false)):
		return false
	static_prepare_entries_by_key[key] = {
		"request_id": request_id,
		"type_name": type_name,
		"model_path": model_path,
		"item_id": item_id,
		"key": key,
		"expected_count": expected_count,
	}
	static_prepare_enqueued[key] = true
	_update_static_prepare_stats()
	return true


func get_static_prepare_queue_size() -> int:
	return static_prepare_entries_by_key.size()


func pop_static_prepare_entry(key: String) -> Dictionary:
	if key.is_empty() or not static_prepare_entries_by_key.has(key):
		return {}
	var entry: Dictionary = static_prepare_entries_by_key[key]
	static_prepare_entries_by_key.erase(key)
	static_prepare_enqueued.erase(key)
	_update_static_prepare_stats()
	return entry


func requeue_static_prepare_entry(entry: Dictionary) -> void:
	var key := str(entry.get("key", ""))
	if key.is_empty() or bool(static_prepare_enqueued.get(key, false)):
		return
	static_prepare_entries_by_key[key] = entry
	static_prepare_enqueued[key] = true
	_update_static_prepare_stats()


func discard_static_prepare_queue() -> void:
	static_prepare_entries_by_key.clear()
	static_prepare_enqueued.clear()
	_update_static_prepare_stats()


func has_static_bucket(key: String) -> bool:
	return not key.is_empty() and static_buckets_by_key.has(key)


func add_static_bucket(key: String, bucket: RefCounted) -> void:
	if key.is_empty() or bucket == null:
		return
	# Phase 2A records the bucket while the async request is active. After the
	# cell completes, live cleanup is owned by StaticObjectRenderer's cell index.
	static_buckets_by_key[key] = bucket
	stats["static_buckets"] = static_buckets_by_key.size()


func get_model_handle(model_path: String, item_id: String) -> RefCounted:
	var key := make_model_key(model_path, item_id)
	return resource_handles_by_key.get(key) as RefCounted


func enqueue_pending_model_load(key: String, ref_info: Dictionary) -> void:
	if key.is_empty():
		return
	if not pending_model_loads_by_key.has(key):
		pending_model_loads_by_key[key] = []
	var refs: Array = pending_model_loads_by_key[key]
	refs.append(ref_info)
	_update_model_callback_stats()


func discard_pending_model_load(key: String) -> void:
	if key.is_empty():
		return
	pending_model_loads_by_key.erase(key)
	completed_model_load_keys.erase(key)
	var kept: Array[Dictionary] = []
	for completion: Dictionary in completed_model_loads:
		if str(completion.get("key", "")) != key:
			kept.append(completion)
	completed_model_loads = kept
	_update_model_callback_stats()


func mark_model_load_completed(key: String, request_id: int, model_path: String, item_id: String) -> void:
	if key.is_empty() or bool(completed_model_load_keys.get(key, false)):
		return
	completed_model_loads.append({
		"key": key,
		"request_id": request_id,
		"model_path": model_path,
		"item_id": item_id,
	})
	completed_model_load_keys[key] = true
	_update_model_callback_stats()


func pop_model_load_completion() -> Dictionary:
	while not completed_model_loads.is_empty():
		var completion: Dictionary = completed_model_loads.pop_front()
		var key := str(completion.get("key", ""))
		completed_model_load_keys.erase(key)
		if key.is_empty() or not pending_model_loads_by_key.has(key):
			continue
		var waiting_refs: Array = pending_model_loads_by_key[key]
		pending_model_loads_by_key.erase(key)
		completion["waiting_refs"] = waiting_refs
		_update_model_callback_stats()
		return completion
	_update_model_callback_stats()
	return {}


func get_pending_model_load_count() -> int:
	return pending_model_loads_by_key.size()


func get_completed_model_load_count() -> int:
	return completed_model_loads.size()


func discard_model_load_callbacks() -> void:
	pending_model_loads_by_key.clear()
	completed_model_loads.clear()
	completed_model_load_keys.clear()
	_update_model_callback_stats()


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


func _update_static_prepare_stats() -> void:
	stats["static_prepare_queue"] = get_static_prepare_queue_size()


func _update_model_callback_stats() -> void:
	stats["pending_model_loads"] = get_pending_model_load_count()
	stats["completed_model_loads"] = get_completed_model_load_count()


func _make_world_transform(ref: CellReference) -> Transform3D:
	var pos := CS.vector_to_godot(ref.position)
	var scale := CS.scale_to_godot(ref.scale)
	var basis := CS.esm_rotation_to_godot_basis(ref.rotation)
	basis = basis.scaled(scale)
	return Transform3D(basis, pos)
