class_name MorrowindWorldObjectSource
extends "res://src/core/world/world_object_source.gd"

const CS := preload("res://src/core/coordinate_system.gd")
const CarryableRegistryScript := preload("res://src/core/interaction/carryable_registry.gd")
const RecordScript := preload("res://src/core/world/world_object_record.gd")
const ManifestScript := preload("res://src/core/world/world_cell_manifest.gd")

const MW_LIGHT_SCALE: float = 70.0 / 64.0
const LIGHT_PROXIMITY_RADIUS_M: float = 60.0
const INTERACTIVE_PROXIMITY_RADIUS_M: float = 25.0
const ACTOR_PROXIMITY_RADIUS_M: float = 150.0
const MW_LIGHT_FLAG_FLICKER: int = 0x0008
const MW_LIGHT_FLAG_FIRE: int = 0x0010
const MW_LIGHT_FLAG_FLICKER_SLOW: int = 0x0040
const MW_LIGHT_FLAG_PULSE: int = 0x0080
const MW_LIGHT_FLAG_PULSE_SLOW: int = 0x0100

var _manifest_cache: Dictionary[Vector2i, RefCounted] = {}
var _object_cache: Dictionary[StringName, RefCounted] = {}
var _spawn_payload_cache: Dictionary[StringName, Dictionary] = {}
var _source_cell_cache: Dictionary[Vector2i, Variant] = {}
var _esm_manager: Variant = null


func clear_cache() -> void:
	_manifest_cache.clear()
	_object_cache.clear()
	_spawn_payload_cache.clear()
	_source_cell_cache.clear()


func get_cell_manifest(cell_grid: Vector2i) -> Variant:
	if _manifest_cache.has(cell_grid):
		return _manifest_cache[cell_grid]

	var esm: Variant = _get_esm_manager()
	if esm == null:
		return null
	var cell_record: Variant = esm.get_exterior_cell(cell_grid.x, cell_grid.y)
	if cell_record == null:
		return null

	var manifest: RefCounted = ManifestScript.new(cell_grid)
	_source_cell_cache[cell_grid] = cell_record
	for ref in cell_record.references:
		if ref.is_deleted:
			continue
		var record_type: Array = [""]
		var base_record: Variant = esm.get_any_record(str(ref.ref_id), record_type)
		if base_record == null:
			continue
		var record: Variant = _make_record(cell_grid, ref, base_record, str(record_type[0]))
		if record != null:
			manifest.add_object(record)
			_object_cache[record.object_id] = record

	_manifest_cache[cell_grid] = manifest
	return manifest


func get_object_record(object_id: StringName) -> Variant:
	return _get_record_by_id(object_id)


func get_spawn_adapter_payload(adapter_payload_id: StringName) -> Dictionary:
	return _spawn_payload_cache.get(adapter_payload_id, {})


func get_source_exterior_cell(cell_grid: Vector2i) -> Variant:
	if _source_cell_cache.has(cell_grid):
		return _source_cell_cache[cell_grid]
	get_cell_manifest(cell_grid)
	return _source_cell_cache.get(cell_grid, null)


func get_source_cell(cell_name: String) -> Variant:
	var esm: Variant = _get_esm_manager()
	return esm.get_cell(cell_name) if esm != null else null


func get_source_base_record(ref_id: String, record_type_out: Array = []) -> Variant:
	var esm: Variant = _get_esm_manager()
	return esm.get_any_record(ref_id, record_type_out) if esm != null else null


func get_source_base_record_cached(ref_id: String, record_type_out: Array = []) -> Variant:
	var esm: Variant = _get_esm_manager()
	if esm == null:
		return null
	if esm.has_method("get_any_record_cached"):
		return esm.get_any_record_cached(ref_id, record_type_out)
	return esm.get_any_record(ref_id, record_type_out)


func get_source_creature(creature_id: String) -> Variant:
	var esm: Variant = _get_esm_manager()
	return esm.get_creature(creature_id) if esm != null else null


func get_source_leveled_creature(creature_id: String) -> Variant:
	var esm: Variant = _get_esm_manager()
	return esm.get_leveled_creature(creature_id) if esm != null else null


func get_cell_size_meters() -> float:
	return CS.CELL_SIZE_GODOT


func _get_esm_manager() -> Variant:
	if _esm_manager != null:
		return _esm_manager
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	_esm_manager = tree.root.get_node_or_null("/root/ESMManager")
	if _esm_manager == null:
		push_error("MorrowindWorldObjectSource requires ESMManager autoload")
	return _esm_manager


func _get_record_by_id(object_id: StringName) -> Variant:
	if _object_cache.has(object_id):
		return _object_cache[object_id]
	return null


func _make_record(cell_grid: Vector2i, ref: Variant, base_record: Variant, type_name: String) -> Variant:
	var model_path := _get_model_path(base_record)
	var category := _category_for_type(type_name)
	var flags := _capabilities_for(type_name, base_record, model_path)
	var record: RefCounted = RecordScript.new()
	record.object_id = RecordScript.make_object_id(cell_grid, str(ref.ref_id), int(ref.ref_num))
	record.record_id = StringName(_record_id_for(base_record, str(ref.ref_id)))
	record.source_ref_id = StringName(str(ref.ref_id))
	record.source_key = "%s:%s" % [type_name, str(record.object_id)]
	record.cell_grid = cell_grid
	record.model_path = model_path
	record.model_item_id = str(record.record_id)
	record.category = category
	record.capability_flags = flags
	record.source_type = StringName(type_name)
	record.static_batch_allowed = _is_static_batch_allowed(type_name, base_record, model_path)
	record.spawn_route = _spawn_route_for(type_name, base_record, record.static_batch_allowed, model_path)
	record.cache_item_id = _cache_item_id_for(type_name, base_record, record.model_item_id, record.static_batch_allowed)
	record.proximity_radius_m = _proximity_radius_for(type_name, base_record)
	record.adapter_payload_id = record.object_id
	record.scale_scalar = float(ref.scale)
	record.transform = Transform3D(CS.esm_rotation_to_godot_basis(ref.rotation).scaled(CS.scale_to_godot(ref.scale)), CS.vector_to_godot(ref.position))
	_spawn_payload_cache[record.object_id] = {
		"ref": ref,
		"base_record": base_record,
		"type_name": type_name,
		"cell_grid": cell_grid,
	}

	if type_name == "light":
		record.light_color = base_record.color
		record.light_radius = float(base_record.radius) * MW_LIGHT_SCALE
		var light_flags := int(base_record.flags)
		record.light_animation = _light_animation_for_flags(light_flags)
		record.light_is_fire = (light_flags & MW_LIGHT_FLAG_FIRE) != 0

	return record


func _light_animation_for_flags(flags: int) -> int:
	if (flags & MW_LIGHT_FLAG_FLICKER) != 0:
		return RecordScript.LightAnimation.FLICKER
	if (flags & MW_LIGHT_FLAG_FLICKER_SLOW) != 0:
		return RecordScript.LightAnimation.FLICKER_SLOW
	if (flags & MW_LIGHT_FLAG_PULSE) != 0:
		return RecordScript.LightAnimation.PULSE
	if (flags & MW_LIGHT_FLAG_PULSE_SLOW) != 0:
		return RecordScript.LightAnimation.PULSE_SLOW
	return RecordScript.LightAnimation.NONE


func _record_id_for(base_record: Variant, fallback: String) -> String:
	if base_record != null and "record_id" in base_record:
		var id := str(base_record.record_id)
		if not id.is_empty():
			return id
	return fallback


func _spawn_route_for(type_name: String, base_record: Variant, static_batch_allowed: bool, model_path: String) -> int:
	if type_name == "leveled_item":
		return RecordScript.SpawnRoute.SKIP
	if CarryableRegistryScript.is_carryable(type_name, base_record):
		return RecordScript.SpawnRoute.NODE
	if static_batch_allowed:
		return RecordScript.SpawnRoute.STATIC_BATCH
	match type_name:
		"light":
			return RecordScript.SpawnRoute.LIGHT
		"npc", "creature", "leveled_creature":
			return RecordScript.SpawnRoute.ACTOR
		_:
			return RecordScript.SpawnRoute.NODE if not model_path.is_empty() else RecordScript.SpawnRoute.NODE


func _cache_item_id_for(type_name: String, base_record: Variant, model_item_id: String, static_batch_allowed: bool) -> String:
	if static_batch_allowed:
		return ""
	if CarryableRegistryScript.is_carryable(type_name, base_record):
		return model_item_id
	match type_name:
		"light", "npc", "creature", "leveled_creature":
			return ""
		_:
			return model_item_id


func _is_static_batch_allowed(type_name: String, base_record: Variant, model_path: String) -> bool:
	return type_name == "static" \
		and not model_path.is_empty() \
		and not CarryableRegistryScript.is_carryable(type_name, base_record)


func _proximity_radius_for(type_name: String, base_record: Variant) -> float:
	if CarryableRegistryScript.is_carryable(type_name, base_record):
		return INTERACTIVE_PROXIMITY_RADIUS_M
	match type_name:
		"light":
			return LIGHT_PROXIMITY_RADIUS_M
		"npc", "creature", "leveled_creature":
			return ACTOR_PROXIMITY_RADIUS_M
		"door", "container", "activator":
			return INTERACTIVE_PROXIMITY_RADIUS_M
		_:
			return 0.0


func _capabilities_for(type_name: String, base_record: Variant, model_path: String) -> int:
	var flags := 0
	match type_name:
		"static":
			if not model_path.is_empty():
				flags |= RecordScript.CAP_STATIC_VISUAL | RecordScript.CAP_COLLISION
				if _is_hlod_geometry_candidate(type_name, base_record, model_path):
					flags |= RecordScript.CAP_HLOD
		"door", "container", "activator":
			if not model_path.is_empty():
				flags |= RecordScript.CAP_GAMEPLAY | RecordScript.CAP_STATIC_VISUAL
				if _is_hlod_geometry_candidate(type_name, base_record, model_path):
					flags |= RecordScript.CAP_HLOD
		"light":
			flags |= RecordScript.CAP_GAMEPLAY
			if _is_distant_light_candidate(base_record):
				flags |= RecordScript.CAP_DISTANT_LIGHT
		"npc", "creature":
			flags |= RecordScript.CAP_GAMEPLAY
		_:
			if not model_path.is_empty():
				flags |= RecordScript.CAP_STATIC_VISUAL
	if not model_path.is_empty():
		flags |= RecordScript.CAP_IMPOSTOR
	return flags


static func _is_hlod_geometry_candidate(type_name: String, base_record: Variant, model_path: String) -> bool:
	var lower := model_path.to_lower().replace("/", "\\")
	if lower.is_empty():
		return false
	match type_name:
		"door":
			return true
		"activator":
			if _has_static_state_script(base_record):
				return false
			return _is_large_static_hlod_model(lower)
		"static":
			return _is_large_static_hlod_model(lower)
		_:
			return false


static func _has_static_state_script(base_record: Variant) -> bool:
	if base_record == null:
		return false
	if "script" in base_record and base_record.script is String:
		return not str(base_record.script).is_empty()
	return false


static func _is_large_static_hlod_model(lower_model_path: String) -> bool:
	if _is_specialized_distant_representation(lower_model_path):
		return false
	if "terrain_" in lower_model_path:
		return "_small" not in lower_model_path and "rock_sm" not in lower_model_path
	if "ex_" in lower_model_path or "dwrv_" in lower_model_path or "dae_" in lower_model_path:
		return true
	if "bridge" in lower_model_path or "dock" in lower_model_path or "platform" in lower_model_path:
		return true
	if "ship" in lower_model_path or "boat" in lower_model_path:
		return true
	if "stronghold" in lower_model_path or "velothi" in lower_model_path:
		return true
	return false


static func _is_specialized_distant_representation(lower_model_path: String) -> bool:
	return "flora_" in lower_model_path \
		or "grass" in lower_model_path \
		or "furn_" in lower_model_path \
		or "contain_" in lower_model_path \
		or "barrel" in lower_model_path \
		or "crate" in lower_model_path \
		or "light_" in lower_model_path \
		or "marker" in lower_model_path


func _is_distant_light_candidate(light_record: Variant) -> bool:
	return light_record != null \
		and light_record.has_method("is_off_by_default") \
		and not light_record.is_off_by_default() \
		and float(light_record.radius) > 0.0 \
		and light_record.has_method("is_negative") \
		and not light_record.is_negative()


func _category_for_type(type_name: String) -> int:
	match type_name:
		"static": return RecordScript.Category.STATIC
		"door": return RecordScript.Category.DOOR
		"container": return RecordScript.Category.CONTAINER
		"activator": return RecordScript.Category.ACTIVATOR
		"light": return RecordScript.Category.LIGHT
		"npc": return RecordScript.Category.NPC
		"creature": return RecordScript.Category.CREATURE
		_: return RecordScript.Category.OTHER


static func _get_model_path(record: Variant) -> String:
	if record == null:
		return ""
	if "model" in record and record.model is String:
		return record.model
	if "mesh" in record and record.mesh is String:
		return record.mesh
	return ""
