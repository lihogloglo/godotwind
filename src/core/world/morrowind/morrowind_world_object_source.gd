class_name MorrowindWorldObjectSource
extends "res://src/core/world/world_object_source.gd"

const CS := preload("res://src/core/coordinate_system.gd")
const RecordScript := preload("res://src/core/world/world_object_record.gd")
const ManifestScript := preload("res://src/core/world/world_cell_manifest.gd")

const MW_LIGHT_SCALE: float = 70.0 / 64.0

var _manifest_cache: Dictionary[Vector2i, RefCounted] = {}
var _object_cache: Dictionary[StringName, RefCounted] = {}
var _esm_manager: Variant = null


func clear_cache() -> void:
	_manifest_cache.clear()
	_object_cache.clear()


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
	manifest.legacy_cell_record = cell_record
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


func resolve_gameplay_payload(object_id: StringName) -> Dictionary:
	var record: Variant = _get_record_by_id(object_id)
	if record == null:
		return {}
	return {
		"ref": record.legacy_ref,
		"base_record": record.legacy_base_record,
		"type_name": record.legacy_type_name,
		"cell_grid": record.cell_grid,
	}


func get_legacy_exterior_cell(cell_grid: Vector2i) -> Variant:
	var manifest: Variant = get_cell_manifest(cell_grid)
	return manifest.legacy_cell_record if manifest != null else null


func get_legacy_cell(cell_name: String) -> Variant:
	var esm: Variant = _get_esm_manager()
	return esm.get_cell(cell_name) if esm != null else null


func get_legacy_base_record(ref_id: String, record_type_out: Array = []) -> Variant:
	var esm: Variant = _get_esm_manager()
	return esm.get_any_record(ref_id, record_type_out) if esm != null else null


func get_legacy_base_record_cached(ref_id: String, record_type_out: Array = []) -> Variant:
	var esm: Variant = _get_esm_manager()
	if esm == null:
		return null
	if esm.has_method("get_any_record_cached"):
		return esm.get_any_record_cached(ref_id, record_type_out)
	return esm.get_any_record(ref_id, record_type_out)


func get_legacy_creature(creature_id: String) -> Variant:
	var esm: Variant = _get_esm_manager()
	return esm.get_creature(creature_id) if esm != null else null


func get_legacy_leveled_creature(creature_id: String) -> Variant:
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
	record.source_ref_id = StringName(str(ref.ref_id))
	record.source_key = "%s:%s" % [type_name, str(record.object_id)]
	record.cell_grid = cell_grid
	record.model_path = model_path
	record.category = category
	record.capability_flags = flags
	record.scale_scalar = float(ref.scale)
	record.transform = Transform3D(CS.esm_rotation_to_godot_basis(ref.rotation).scaled(CS.scale_to_godot(ref.scale)), CS.vector_to_godot(ref.position))
	record.legacy_ref = ref
	record.legacy_base_record = base_record
	record.legacy_type_name = type_name

	if type_name == "light":
		record.light_color = base_record.color
		record.light_radius = float(base_record.radius) * MW_LIGHT_SCALE
		record.light_flags = int(base_record.flags)

	return record


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
