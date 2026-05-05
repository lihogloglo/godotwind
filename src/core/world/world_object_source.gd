class_name WorldObjectSource
extends RefCounted

const WorldObjectRecordScript := preload("res://src/core/world/world_object_record.gd")
const WorldCellManifestScript := preload("res://src/core/world/world_cell_manifest.gd")


func get_cell_manifest(cell_grid: Vector2i) -> Variant:
	return null


func get_objects_in_cell(cell_grid: Vector2i, capability_mask: int = 0) -> Array:
	var manifest: Variant = get_cell_manifest(cell_grid)
	if manifest == null:
		return []
	if capability_mask == 0:
		return manifest.objects.duplicate()
	var out: Array = []
	for record: RefCounted in manifest.objects:
		if (record.capability_flags & capability_mask) != 0:
			out.append(record)
	return out


func get_objects_in_cells(cells: Array[Vector2i], capability_mask: int = 0) -> Array:
	var out: Array = []
	for cell_grid: Vector2i in cells:
		out.append_array(get_objects_in_cell(cell_grid, capability_mask))
	return out


func get_cell_size_meters() -> float:
	return 117.0


func resolve_gameplay_payload(_object_id: StringName) -> Dictionary:
	return {}


func get_legacy_exterior_cell(_cell_grid: Vector2i) -> Variant:
	return null


func get_legacy_cell(_cell_name: String) -> Variant:
	return null


func get_legacy_base_record(_ref_id: String, _record_type_out: Array = []) -> Variant:
	return null


func get_legacy_base_record_cached(ref_id: String, record_type_out: Array = []) -> Variant:
	return get_legacy_base_record(ref_id, record_type_out)


func get_legacy_creature(_creature_id: String) -> Variant:
	return null


func get_legacy_leveled_creature(_creature_id: String) -> Variant:
	return null
