class_name MorrowindObjectSpawnAdapter
extends "res://src/core/world/world_object_spawn_adapter.gd"

const CS := preload("res://src/core/coordinate_system.gd")
const CarryableRegistryScript := preload("res://src/core/interaction/carryable_registry.gd")
const RecordScript := preload("res://src/core/world/world_object_record.gd")

const CARRYABLE_BODY_FACTORY_PATH := "res://src/core/interaction/carryable_body_factory.gd"
const PICKUP_INTERACTABLE_PATH := "res://src/core/interaction/morrowind/pickup_interactable.gd"
const DOOR_INTERACTABLE_PATH := "res://src/core/interaction/morrowind/door_interactable.gd"
const CONTAINER_INTERACTABLE_PATH := "res://src/core/interaction/morrowind/container_interactable.gd"
const ACTIVATOR_INTERACTABLE_PATH := "res://src/core/interaction/morrowind/activator_interactable.gd"
const NPC_INTERACTABLE_PATH := "res://src/core/dialogue/morrowind/npc_interactable.gd"
const MorrowindTransitionProviderScript := preload("res://src/core/world/morrowind/morrowind_transition_provider.gd")
const LIGHT_PROXIMITY_THRESHOLD_M: float = 60.0
const LIGHT_ALWAYS_SPAWN_RADIUS_MW: float = 700.0
const MW_LIGHT_FLAG_FLICKER: int = 0x0008
const MW_LIGHT_FLAG_FIRE: int = 0x0010
const MW_LIGHT_FLAG_FLICKER_SLOW: int = 0x0040
const MW_LIGHT_FLAG_PULSE: int = 0x0080
const MW_LIGHT_FLAG_PULSE_SLOW: int = 0x0100
const MW_LIGHT_SCALE: float = 70.0 / 64.0
const INTERACTIVE_PROXIMITY_RADIUS_M: float = 25.0
const ACTOR_PROXIMITY_RADIUS_M: float = 150.0

var _source_reference_payload_cache: Dictionary[StringName, Dictionary] = {}

func instantiate_world_object(
	record: RefCounted,
	instantiator: RefCounted,
	cell_grid: Vector2i = Vector2i.ZERO,
	cache_item_id: String = "",
) -> Node3D:
	if record == null or instantiator == null:
		_mark_skipped(instantiator, "unknown")
		return null

	var payload := _get_payload(record)
	var type_name := _payload_type_name(record, payload)
	_set_spawn_diagnostics(instantiator, type_name, "")

	match int(record.get("spawn_route")):
		RecordScript.SpawnRoute.STATIC_BATCH:
			return _spawn_static_batch(record, instantiator, cell_grid)
		RecordScript.SpawnRoute.NODE:
			return _spawn_node(record, payload, instantiator, cell_grid, cache_item_id)
		RecordScript.SpawnRoute.LIGHT:
			return _spawn_light(record, payload, instantiator)
		RecordScript.SpawnRoute.ACTOR:
			return _spawn_actor(record, payload, instantiator)
		RecordScript.SpawnRoute.SKIP:
			_mark_skipped(instantiator, type_name)
			return null
		_:
			_mark_skipped(instantiator, type_name)
			return null


func resolve_source_reference_base_record(
	source_ref: Variant,
	record_type_out: Array = [],
	cached: bool = false,
) -> Variant:
	var ref_id := _source_ref_id(source_ref)
	if ref_id.is_empty():
		return null
	if object_source == null:
		_log_error("streaming", "Morrowind object adapter has no source for ref '%s'" % ref_id)
		return null
	var method_name := "get_source_base_record_cached" if cached else "get_source_base_record"
	if not object_source.has_method(method_name):
		_log_error("streaming", "Morrowind object source cannot resolve ref '%s'" % ref_id)
		return null
	return object_source.call(method_name, ref_id, record_type_out)


func make_world_object_record_from_source_reference(
	source_ref: Variant,
	base_record: Variant,
	type_name: String,
	model_path: String,
	item_id: String,
	cache_item_id: String,
	static_route: bool,
	cell_grid: Vector2i,
) -> RefCounted:
	if source_ref == null:
		return null
	var ref_id := _source_ref_id(source_ref)
	if ref_id.is_empty():
		return null
	var record: RefCounted = RecordScript.new()
	record.object_id = RecordScript.make_object_id(cell_grid, ref_id, _source_ref_num(source_ref))
	record.record_id = StringName(item_id if not item_id.is_empty() else _record_id_for(base_record, ref_id))
	record.source_ref_id = StringName(ref_id)
	record.source_key = "%s:%s" % [type_name, str(record.object_id)]
	record.cell_grid = cell_grid
	record.transform = _source_ref_transform(source_ref)
	record.model_path = model_path
	record.model_item_id = item_id
	record.cache_item_id = cache_item_id
	record.source_type = StringName(type_name)
	record.category = _category_for_type_name(type_name)
	record.spawn_route = _spawn_route_for_source_reference(type_name, base_record, static_route, model_path)
	record.static_batch_allowed = static_route
	record.capability_flags = _capabilities_for_source_reference(type_name, base_record, model_path, static_route)
	record.proximity_radius_m = _proximity_radius_for_source_reference(type_name, base_record)
	record.adapter_payload_id = record.object_id
	record.scale_scalar = _source_ref_scale(source_ref)
	_cache_source_reference_payload(record.adapter_payload_id, source_ref, base_record, type_name, cell_grid)
	if type_name == "light" and base_record != null:
		if "color" in base_record:
			record.light_color = base_record.color
		if "radius" in base_record:
			record.light_radius = float(base_record.radius) * MW_LIGHT_SCALE
		if "flags" in base_record:
			var light_flags := int(base_record.flags)
			record.light_animation = source_light_animation_for_record(base_record)
			record.light_is_fire = (light_flags & MW_LIGHT_FLAG_FIRE) != 0
	return record


func is_source_record_carryable(type_name: String, base_record: Variant) -> bool:
	return CarryableRegistryScript.is_carryable(type_name, base_record)


func postprocess_source_model_object(
	instance: Node3D,
	ref: Variant,
	base_record: Variant,
	type_name: String,
	cell_grid: Vector2i,
	record_id: String,
	instantiator: RefCounted,
	source_key: String = "",
) -> void:
	if instance == null:
		return
	if is_source_record_carryable(type_name, base_record):
		_attach_carryable(instance, base_record, type_name, record_id, instantiator)
	if type_name == "door" and ref != null and bool(ref.get("is_teleport")):
		_attach_door(instance, ref, cell_grid, base_record, record_id, instantiator)
	elif type_name == "container":
		_attach_container(instance, ref, base_record, record_id, instantiator, source_key)
	elif type_name == "activator":
		_attach_activator(instance, base_record, record_id, instantiator)


func postprocess_source_actor(
	character: Node3D,
	_ref: Variant,
	actor_record: Variant,
	actor_type: String,
	instantiator: RefCounted,
) -> Node3D:
	return _wrap_npc_actor(character, actor_record, actor_type, instantiator)


func _source_resolve_leveled_creature(
	leveled: Variant,
	_instantiator: RefCounted,
	player_level: int = 10,
) -> Variant:
	return _resolve_leveled_creature(leveled, player_level)


func source_light_animation_for_record(light_record: Variant) -> int:
	if light_record == null or not ("flags" in light_record):
		return RecordScript.LightAnimation.NONE
	var flags := int(light_record.flags)
	if (flags & MW_LIGHT_FLAG_FLICKER) != 0:
		return RecordScript.LightAnimation.FLICKER
	if (flags & MW_LIGHT_FLAG_FLICKER_SLOW) != 0:
		return RecordScript.LightAnimation.FLICKER_SLOW
	if (flags & MW_LIGHT_FLAG_PULSE) != 0:
		return RecordScript.LightAnimation.PULSE
	if (flags & MW_LIGHT_FLAG_PULSE_SLOW) != 0:
		return RecordScript.LightAnimation.PULSE_SLOW
	return RecordScript.LightAnimation.NONE


func _spawn_static_batch(record: RefCounted, instantiator: RefCounted, cell_grid: Vector2i) -> Node3D:
	if not instantiator.has_method("instantiate_static_world_object_record"):
		_mark_skipped(instantiator, _record_type_name(record))
		return null
	return instantiator.call("instantiate_static_world_object_record", record, cell_grid) as Node3D


func _spawn_node(
	record: RefCounted,
	payload: Dictionary,
	instantiator: RefCounted,
	cell_grid: Vector2i,
	cache_item_id: String,
) -> Node3D:
	var type_name := _payload_type_name(record, payload)
	if _is_record_proximity_deferred(record, instantiator):
		if instantiator.has_method("ensure_source_visual_proxy_for_record"):
			instantiator.call(
				"ensure_source_visual_proxy_for_record",
				record,
				type_name,
				cache_item_id,
			)
		_mark_deferred(instantiator, type_name)
		return null

	if not instantiator.has_method("instantiate_node_world_object_record"):
		_mark_skipped(instantiator, type_name)
		return null
	var node := instantiator.call("instantiate_node_world_object_record", record, cell_grid, cache_item_id) as Node3D
	if node == null:
		return null
	var ref: Variant = payload.get("ref", null)
	var base_record: Variant = payload.get("base_record", null)
	var record_id := str(record.get("record_id"))
	if ref != null and instantiator.has_method("apply_source_metadata"):
		instantiator.call("apply_source_metadata", node, ref, base_record, str(record.get("model_path")), type_name)
	if instantiator.has_method("apply_source_visual_proxy_runtime_for_record"):
		instantiator.call("apply_source_visual_proxy_runtime_for_record", node, record, type_name)
	postprocess_source_model_object(node, ref, base_record, type_name, cell_grid, record_id, instantiator, str(record.get("source_key")))
	return node


func _spawn_light(record: RefCounted, payload: Dictionary, instantiator: RefCounted) -> Node3D:
	var ref: Variant = payload.get("ref", null)
	var light_record: Variant = payload.get("base_record", null)
	if ref == null or light_record == null:
		_mark_skipped(instantiator, _record_type_name(record))
		return null
	if instantiator.has_method("should_source_load_lights") and not bool(instantiator.call("should_source_load_lights")):
		return null
	if is_source_record_carryable("light", light_record):
		return _spawn_node(record, payload, instantiator, _record_cell_grid(record), str(record.get("cache_item_id")))
	if _is_light_proximity_deferred(record, light_record, instantiator):
		_mark_deferred(instantiator, "light")
		return null
	if not instantiator.has_method("instantiate_source_light_record"):
		_mark_skipped(instantiator, "light")
		return null
	return instantiator.call("instantiate_source_light_record", record, light_record) as Node3D


func _spawn_actor(record: RefCounted, payload: Dictionary, instantiator: RefCounted) -> Node3D:
	var type_name := _payload_type_name(record, payload)
	if type_name == "npc" and instantiator.has_method("should_source_load_npcs") and not bool(instantiator.call("should_source_load_npcs")):
		return null
	if type_name != "npc" and instantiator.has_method("should_source_load_creatures") and not bool(instantiator.call("should_source_load_creatures")):
		return null
	if _is_record_proximity_deferred(record, instantiator):
		_mark_deferred(instantiator, type_name)
		return null

	var ref: Variant = payload.get("ref", null)
	var actor_record: Variant = payload.get("base_record", null)
	var actor_type := type_name
	if type_name == "leveled_creature":
		actor_record = _resolve_leveled_creature(actor_record)
		actor_type = "creature"
	if ref == null or actor_record == null:
		_mark_skipped(instantiator, type_name)
		return null
	if not instantiator.has_method("instantiate_source_actor_record"):
		_mark_skipped(instantiator, type_name)
		return null
	return instantiator.call("instantiate_source_actor_record", record, actor_record, actor_type) as Node3D


func _get_payload(record: RefCounted) -> Dictionary:
	var payload_id: StringName = record.get("adapter_payload_id")
	if payload_id == &"":
		payload_id = record.get("object_id")
	if _source_reference_payload_cache.has(payload_id):
		return _source_reference_payload_cache[payload_id]
	if object_source == null or not object_source.has_method("get_spawn_adapter_payload"):
		return {}
	return object_source.call("get_spawn_adapter_payload", payload_id)


func _payload_type_name(record: RefCounted, payload: Dictionary) -> String:
	var type_name := str(payload.get("type_name", ""))
	if not type_name.is_empty():
		return type_name
	return _record_type_name(record)


func _record_type_name(record: RefCounted) -> String:
	var source_type := str(record.get("source_type"))
	if not source_type.is_empty():
		return source_type
	return "object"


func _record_cell_grid(record: RefCounted) -> Vector2i:
	var value: Variant = record.get("cell_grid")
	if value is Vector2i:
		return value as Vector2i
	return Vector2i.ZERO


func _source_ref_id(source_ref: Variant) -> String:
	if source_ref == null:
		return ""
	var ref_value: Variant = source_ref.get("ref_id")
	return str(ref_value)


func _source_ref_num(source_ref: Variant) -> int:
	if source_ref == null:
		return 0
	return int(source_ref.get("ref_num"))


func _source_ref_scale(source_ref: Variant) -> float:
	if source_ref == null:
		return 1.0
	var value: Variant = source_ref.get("scale")
	return float(value) if value != null else 1.0


func _source_ref_transform(source_ref: Variant) -> Transform3D:
	if source_ref == null:
		return Transform3D.IDENTITY
	var position_value: Variant = source_ref.get("position")
	var rotation_value: Variant = source_ref.get("rotation")
	var position := Vector3.ZERO
	if position_value is Vector3:
		position = position_value as Vector3
	var rotation := Vector3.ZERO
	if rotation_value is Vector3:
		rotation = rotation_value as Vector3
	var scale := _source_ref_scale(source_ref)
	return Transform3D(
		CS.esm_rotation_to_godot_basis(rotation).scaled(CS.scale_to_godot(scale)),
		CS.vector_to_godot(position)
	)


func _record_position(record: RefCounted) -> Vector3:
	var value: Variant = record.get("transform")
	if value is Transform3D:
		return (value as Transform3D).origin
	return Vector3.ZERO


func _cache_source_reference_payload(
	payload_id: StringName,
	source_ref: Variant,
	base_record: Variant,
	type_name: String,
	cell_grid: Vector2i,
) -> void:
	if payload_id == &"":
		return
	_source_reference_payload_cache[payload_id] = {
		"ref": source_ref,
		"base_record": base_record,
		"type_name": type_name,
		"cell_grid": cell_grid,
	}


func _category_for_type_name(type_name: String) -> int:
	match type_name:
		"static":
			return RecordScript.Category.STATIC
		"door":
			return RecordScript.Category.DOOR
		"container":
			return RecordScript.Category.CONTAINER
		"activator":
			return RecordScript.Category.ACTIVATOR
		"light":
			return RecordScript.Category.LIGHT
		"npc":
			return RecordScript.Category.NPC
		"creature", "leveled_creature":
			return RecordScript.Category.CREATURE
		_:
			return RecordScript.Category.OTHER


func _spawn_route_for_source_reference(type_name: String, base_record: Variant, static_route: bool, model_path: String) -> int:
	if type_name == "leveled_item":
		return RecordScript.SpawnRoute.SKIP
	if is_source_record_carryable(type_name, base_record):
		return RecordScript.SpawnRoute.NODE
	if static_route:
		return RecordScript.SpawnRoute.STATIC_BATCH
	match type_name:
		"light":
			return RecordScript.SpawnRoute.LIGHT
		"npc", "creature", "leveled_creature":
			return RecordScript.SpawnRoute.ACTOR
		_:
			return RecordScript.SpawnRoute.NODE if not model_path.is_empty() or type_name in ["door", "container", "activator"] else RecordScript.SpawnRoute.NODE


func _capabilities_for_source_reference(type_name: String, base_record: Variant, model_path: String, static_route: bool) -> int:
	var flags := 0
	if is_source_record_carryable(type_name, base_record):
		flags |= RecordScript.CAP_GAMEPLAY | RecordScript.CAP_STATIC_VISUAL | RecordScript.CAP_COLLISION
		if not model_path.is_empty():
			flags |= RecordScript.CAP_IMPOSTOR
		return flags
	if static_route:
		flags |= RecordScript.CAP_STATIC_VISUAL | RecordScript.CAP_COLLISION
		return flags
	match type_name:
		"light":
			flags |= RecordScript.CAP_GAMEPLAY
			if base_record != null and "radius" in base_record and float(base_record.radius) >= LIGHT_ALWAYS_SPAWN_RADIUS_MW:
				flags |= RecordScript.CAP_DISTANT_LIGHT
		"npc", "creature", "leveled_creature":
			flags |= RecordScript.CAP_GAMEPLAY
		"door", "container", "activator":
			flags |= RecordScript.CAP_GAMEPLAY
			if not model_path.is_empty():
				flags |= RecordScript.CAP_STATIC_VISUAL
		_:
			if not model_path.is_empty():
				flags |= RecordScript.CAP_STATIC_VISUAL
	if not model_path.is_empty():
		flags |= RecordScript.CAP_IMPOSTOR
	return flags


func _proximity_radius_for_source_reference(type_name: String, base_record: Variant) -> float:
	if is_source_record_carryable(type_name, base_record):
		return INTERACTIVE_PROXIMITY_RADIUS_M
	match type_name:
		"light":
			return LIGHT_PROXIMITY_THRESHOLD_M
		"npc", "creature", "leveled_creature":
			return ACTOR_PROXIMITY_RADIUS_M
		"door", "container", "activator":
			return INTERACTIVE_PROXIMITY_RADIUS_M
		_:
			return 0.0


func _record_id_for(base_record: Variant, fallback: String) -> String:
	if base_record != null and "record_id" in base_record:
		var id := str(base_record.record_id)
		if not id.is_empty():
			return id
	return fallback


func _set_spawn_diagnostics(
	instantiator: RefCounted,
	type_name: String,
	route: String,
	proximity_deferred: bool = false
) -> void:
	if instantiator != null and instantiator.has_method("set_source_spawn_diagnostics"):
		instantiator.call("set_source_spawn_diagnostics", type_name, route, proximity_deferred)


func _get_instantiator_camera_position(instantiator: RefCounted) -> Vector3:
	if instantiator != null and instantiator.has_method("get_source_spawn_camera_position"):
		var value: Variant = instantiator.call("get_source_spawn_camera_position")
		if value is Vector3:
			return value as Vector3
	return Vector3.ZERO


func _is_record_proximity_deferred(record: RefCounted, instantiator: RefCounted) -> bool:
	if instantiator.has_method("is_source_static_renderer_effective") and not bool(instantiator.call("is_source_static_renderer_effective")):
		return false
	var radius := float(record.get("proximity_radius_m"))
	if radius <= 0.0:
		return false
	var camera_pos: Vector3 = _get_instantiator_camera_position(instantiator)
	return _record_position(record).distance_squared_to(camera_pos) > radius * radius


func _is_light_proximity_deferred(record: RefCounted, light_record: Variant, instantiator: RefCounted) -> bool:
	if instantiator.has_method("is_source_static_renderer_effective") and not bool(instantiator.call("is_source_static_renderer_effective")):
		return false
	if light_record != null and "radius" in light_record:
		if float(light_record.radius) >= LIGHT_ALWAYS_SPAWN_RADIUS_MW:
			return false
	var camera_pos: Vector3 = _get_instantiator_camera_position(instantiator)
	return _record_position(record).distance_squared_to(camera_pos) > LIGHT_PROXIMITY_THRESHOLD_M * LIGHT_PROXIMITY_THRESHOLD_M


func _attach_carryable(
	instance: Node3D,
	base_record: Variant,
	type_name: String,
	record_id: String,
	instantiator: RefCounted,
) -> void:
	if bool(StreamingConfig.DEBUG_DISABLE_JOLT_ATTACH):
		return
	if type_name == "light" and instantiator.has_method("attach_source_carryable_light_source"):
		instantiator.call("attach_source_carryable_light_source", instance, base_record)
	var mass_kg: float = CarryableRegistryScript.get_mass(type_name, base_record)
	var display_name := _get_display_name(base_record, record_id)
	var factory_script := load(CARRYABLE_BODY_FACTORY_PATH) as Script
	var pickup_script := load(PICKUP_INTERACTABLE_PATH) as Script
	if factory_script == null or pickup_script == null:
		_log_warn("interaction", "Carryable %s (%s) adapter scripts unavailable; staying static" % [record_id, type_name])
		return
	var rb: Variant = factory_script.call(
		"convert_static_to_rigid",
		instance,
		mass_kg,
		StringName(record_id),
		display_name,
		pickup_script,
	)
	if rb == null:
		_log_info("interaction", "Carryable %s (%s) has no collision/mesh; staying static" % [record_id, type_name])


func _attach_door(
	door_instance: Node3D,
	ref: Variant,
	cell_grid: Vector2i,
	base_record: Variant,
	record_id: String,
	instantiator: RefCounted,
) -> void:
	var display_name := _get_display_name(base_record, record_id)
	var destination_name := str(ref.get("teleport_cell"))
	var instance_key := ""
	if ref is Object and (ref as Object).has_meta("transition_portal_key"):
		instance_key = str((ref as Object).get_meta("transition_portal_key"))
	if instance_key.is_empty():
		instance_key = str(MorrowindTransitionProviderScript.make_exterior_portal_key(
			cell_grid,
			StringName(str(ref.get("ref_id"))),
			int(ref.get("ref_num"))
		))
	var door_script := load(DOOR_INTERACTABLE_PATH) as Script
	if door_script == null:
		_log_warn("interaction", "Door %s adapter script unavailable" % record_id)
		return
	door_instance.set_script(door_script)
	if door_instance.get_script() == null:
		_log_warn("interaction", "Door %s set_script failed; adapter cast null" % record_id)
		return
	door_instance.set("record_id", record_id)
	door_instance.set("door_instance_key", instance_key)
	door_instance.set("display_name", display_name)
	door_instance.set("destination_name", destination_name)
	door_instance.set("has_destination", not destination_name.is_empty())
	door_instance.set("door_record", base_record)
	_generate_interaction_area_for(door_instance, base_record, instantiator)
	var handler: Callable = instantiator.call("get_source_door_activated_handler") if instantiator.has_method("get_source_door_activated_handler") else Callable()
	if handler.is_valid() and not door_instance.is_connected(&"door_activated", handler):
		door_instance.connect("door_activated", handler)


func _attach_container(
	container_instance: Node3D,
	ref: Variant,
	base_record: Variant,
	record_id: String,
	instantiator: RefCounted,
	source_key: String = "",
) -> void:
	var container_script := load(CONTAINER_INTERACTABLE_PATH) as Script
	if container_script == null:
		_log_warn("interaction", "Container %s adapter script unavailable" % record_id)
		return
	container_instance.set_script(container_script)
	if container_instance.get_script() == null:
		_log_warn("interaction", "Container %s set_script failed; adapter cast null" % record_id)
		return
	container_instance.set("record_id", record_id)
	container_instance.set("display_name", _get_display_name(base_record, record_id))
	container_instance.set("container_record", base_record)
	if ref != null:
		container_instance.set("locked", bool(ref.get("is_locked")))
		container_instance.set("lock_level", int(ref.get("lock_level")))
	_generate_interaction_area_for(container_instance, base_record, instantiator)
	if ref != null and instantiator.has_method("uses_source_visual_proxy") and bool(instantiator.call("uses_source_visual_proxy", "container")):
		container_instance.connect("container_opened", _mark_visual_proxy_dirty.bind(instantiator, source_key, "container_opened"))


func _attach_activator(
	activator_instance: Node3D,
	base_record: Variant,
	record_id: String,
	instantiator: RefCounted,
) -> void:
	var activator_script := load(ACTIVATOR_INTERACTABLE_PATH) as Script
	if activator_script == null:
		_log_warn("interaction", "Activator %s adapter script unavailable" % record_id)
		return
	activator_instance.set_script(activator_script)
	if activator_instance.get_script() == null:
		_log_warn("interaction", "Activator %s set_script failed; adapter cast null" % record_id)
		return
	activator_instance.set("record_id", record_id)
	activator_instance.set("display_name", _get_display_name(base_record, record_id))
	activator_instance.set("activator_record", base_record)
	if base_record != null and "script_id" in base_record:
		activator_instance.set("script_id", String(base_record.script_id))
	_generate_interaction_area_for(activator_instance, base_record, instantiator)


func _wrap_npc_actor(character: Node3D, actor_record: Variant, actor_type: String, instantiator: RefCounted) -> Node3D:
	if character == null or actor_type != "npc" or not (actor_record is NPCRecord):
		return character
	var npc_script := load(NPC_INTERACTABLE_PATH) as Script
	if npc_script == null:
		_log_warn("interaction", "NPC %s adapter script unavailable" % str(actor_record.record_id))
		return character
	var wrapper := Node3D.new()
	wrapper.set_script(npc_script)
	wrapper.name = character.name + "_npc"
	wrapper.set("speaker_id", actor_record.record_id.to_lower())
	wrapper.transform = character.transform
	character.transform = Transform3D.IDENTITY
	wrapper.add_child(character)
	if instantiator.has_method("add_source_interactable_layer_recursive"):
		instantiator.call("add_source_interactable_layer_recursive", wrapper)
	return wrapper


func _generate_interaction_area_for(root: Node3D, base_record: Variant, instantiator: RefCounted) -> void:
	var model_path := _get_model_path(base_record)
	if instantiator.has_method("generate_source_interaction_area"):
		instantiator.call("generate_source_interaction_area", root, model_path)


func _mark_visual_proxy_dirty(_record_id: String, _container_record: Variant, _player: Node3D, instantiator: RefCounted, source_key: String, reason: String) -> void:
	if not instantiator.has_method("mark_source_visual_proxy_dirty"):
		return
	instantiator.call("mark_source_visual_proxy_dirty", source_key, reason)


func _resolve_leveled_creature(leveled: Variant, player_level: int = 10) -> Variant:
	if leveled == null or not ("creatures" in leveled) or leveled.creatures.is_empty():
		return null
	if "chance_none" in leveled and int(leveled.chance_none) > 0 and randi() % 100 < int(leveled.chance_none):
		return null
	var valid: Array = []
	for entry in leveled.creatures:
		if entry.level <= player_level:
			valid.append(entry)
	if valid.is_empty():
		var lowest: Variant = leveled.creatures[0]
		for entry in leveled.creatures:
			if entry.level < lowest.level:
				lowest = entry
		valid.append(lowest)
	var chosen: Variant = valid[randi() % valid.size()]
	var creature_id := str(chosen.creature_id)
	if object_source != null and object_source.has_method("get_source_creature"):
		var creature: Variant = object_source.call("get_source_creature", creature_id)
		if creature != null:
			return creature
	if object_source != null and object_source.has_method("get_source_leveled_creature"):
		var nested: Variant = object_source.call("get_source_leveled_creature", creature_id)
		if nested != null:
			return _resolve_leveled_creature(nested, player_level)
	_log_warn("streaming", "Could not resolve creature '%s' from leveled list" % creature_id)
	return null


func _log_info(category: String, message: String) -> void:
	var logger := _get_logger()
	if logger != null and logger.has_method("info"):
		logger.call("info", category, message)


func _log_warn(category: String, message: String) -> void:
	var logger := _get_logger()
	if logger != null and logger.has_method("warn"):
		logger.call("warn", category, message)
	else:
		push_warning("[%s] %s" % [category, message])


func _log_error(category: String, message: String) -> void:
	var logger := _get_logger()
	if logger != null and logger.has_method("error"):
		logger.call("error", category, message)
	else:
		push_error("[%s] %s" % [category, message])


func _get_logger() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("/root/Log")


func _get_display_name(base_record: Variant, record_id: String) -> String:
	if base_record != null and "name" in base_record and not String(base_record.name).is_empty():
		return String(base_record.name)
	return record_id


func _get_model_path(base_record: Variant) -> String:
	if base_record == null:
		return ""
	if "model" in base_record and base_record.model is String:
		return base_record.model
	return ""


func _mark_deferred(instantiator: RefCounted, type_name: String) -> void:
	_set_spawn_diagnostics(instantiator, type_name, "deferred", true)


func _mark_skipped(instantiator: RefCounted, type_name: String) -> void:
	_set_spawn_diagnostics(instantiator, type_name, "skip")
