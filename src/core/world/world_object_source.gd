class_name WorldObjectSource
extends RefCounted

const WorldObjectRecordScript := preload("res://src/core/world/world_object_record.gd")
const WorldCellManifestScript := preload("res://src/core/world/world_cell_manifest.gd")


func get_space_manifest(space_handle: RefCounted) -> Variant:
	if space_handle == null:
		return null
	if space_handle.has_method("is_interior") and bool(space_handle.call("is_interior")):
		return get_interior_cell_manifest(str(space_handle.get("key")))
	if space_handle.has_method("is_exterior") and bool(space_handle.call("is_exterior")):
		var key := str(space_handle.get("key"))
		var parts := key.split(",")
		if parts.size() == 2:
			return get_cell_manifest(Vector2i(int(parts[0]), int(parts[1])))
	return null


func get_cell_manifest(cell_grid: Vector2i) -> Variant:
	return null


func get_interior_cell_manifest(cell_name: String) -> Variant:
	return null


func get_objects_in_cell(cell_grid: Vector2i, capability_mask: int = 0) -> Array[WorldObjectRecord]:
	var out: Array[WorldObjectRecord] = []
	var manifest: Variant = get_cell_manifest(cell_grid)
	if manifest == null:
		return out
	for record: RefCounted in manifest.objects:
		var world_record := record as WorldObjectRecord
		if world_record == null:
			continue
		if capability_mask == 0 or (world_record.capability_flags & capability_mask) != 0:
			out.append(world_record)
	return out


func get_objects_in_cells(cells: Array[Vector2i], capability_mask: int = 0) -> Array[WorldObjectRecord]:
	var out: Array[WorldObjectRecord] = []
	for cell_grid: Vector2i in cells:
		out.append_array(get_objects_in_cell(cell_grid, capability_mask))
	return out


func get_object_record(_object_id: StringName) -> Variant:
	return null


func get_spawn_adapter_payload(_adapter_payload_id: StringName) -> Dictionary:
	return {}
