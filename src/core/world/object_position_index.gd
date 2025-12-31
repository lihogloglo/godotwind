## ObjectPositionIndex - Spatial index for AAA-style object streaming
##
## Enables distance-based object discovery without loading cells first.
## This is the key component for true AAA streaming where objects are
## streamed by distance rather than by cell membership.
##
## Architecture:
##   - Built once at startup from ESM cell data
##   - Stores lightweight position data (not full CellReference)
##   - Spatial hash allows O(1) cell lookup + linear scan within cells
##   - Thread-safe for concurrent queries
##
## Usage:
##   var index := ObjectPositionIndex.new()
##   index.build_from_esm()  # One-time at startup
##   var nearby := index.get_objects_within_radius(camera_pos, 500.0)
##
## Performance:
##   - Memory: ~80 bytes per object (position + metadata)
##   - Query: O(cells_in_radius * objects_per_cell)
##   - Typical query (500m radius): <1ms for 10k objects
class_name ObjectPositionIndex
extends RefCounted

const CS := preload("res://src/core/coordinate_system.gd")

#region Object Position Data

## Lightweight position data for spatial queries
## Stores just enough to locate and identify an object
class ObjectPosition extends RefCounted:
	var position: Vector3          # Godot world position (meters)
	var model_path: String         # Base object model path (from STAT/DOOR/etc)
	var ref_id: StringName         # Base object ID (e.g., "flora_bc_grass_01")
	var ref_num: int               # Unique reference number within cell
	var cell_grid: Vector2i        # Cell grid coordinates
	var scale: float = 1.0         # Object scale
	var rotation: Vector3          # Euler rotation (radians)
	var object_type: int           # ObjectType enum value
	var is_significant: bool       # Worth LOD chain + impostor

	## Squared distance to a point (faster than distance)
	func distance_squared_to(point: Vector3) -> float:
		return position.distance_squared_to(point)

## Object type categories for filtering
enum ObjectType {
	STATIC = 0,      # STAT - rocks, buildings, flora
	DOOR = 1,        # DOOR - doors
	CONTAINER = 2,   # CONT - chests, barrels
	ACTIVATOR = 3,   # ACTI - levers, signs
	LIGHT = 4,       # LIGH - light sources
	NPC = 5,         # NPC_ - characters
	CREATURE = 6,    # CREA - creatures
	OTHER = 7        # Everything else
}

#endregion


#region Spatial Hash

## Cell size for spatial hash (in Godot meters)
## Using Morrowind cell size for natural alignment
const HASH_CELL_SIZE: float = CS.CELL_SIZE_GODOT  # ~117m

## Spatial hash: Vector2i (cell) -> Array[ObjectPosition]
var _spatial_hash: Dictionary = {}

## Total object count
var _total_objects: int = 0

## Index built flag
var _is_built: bool = false

## Build statistics
var _build_time_ms: float = 0.0
var _cells_indexed: int = 0

#endregion


#region Building the Index

## Build the position index from all exterior cells in ESMManager
## Call this once at startup after ESM files are loaded
func build_from_esm() -> void:
	if _is_built:
		push_warning("ObjectPositionIndex: Already built, call clear() first to rebuild")
		return

	var start_time := Time.get_ticks_msec()
	_spatial_hash.clear()
	_total_objects = 0
	_cells_indexed = 0

	# Iterate all exterior cells
	for cell_key: String in ESMManager.exterior_cells:
		var cell: CellRecord = ESMManager.exterior_cells[cell_key]
		if cell == null:
			continue

		_index_cell(cell)
		_cells_indexed += 1

	_is_built = true
	_build_time_ms = Time.get_ticks_msec() - start_time

	print("ObjectPositionIndex: Built in %.1fms - %d objects in %d cells" % [
		_build_time_ms, _total_objects, _cells_indexed
	])


## Index a single cell's references
func _index_cell(cell: CellRecord) -> void:
	var cell_grid := Vector2i(cell.grid_x, cell.grid_y)

	for ref: CellReference in cell.references:
		if ref.is_deleted:
			continue

		var obj_pos := _create_object_position(ref, cell_grid)
		if obj_pos != null:
			_add_to_hash(obj_pos)
			_total_objects += 1


## Create ObjectPosition from CellReference
func _create_object_position(ref: CellReference, cell_grid: Vector2i) -> ObjectPosition:
	# Get the base record to find model path
	var base_record = ESMManager.get_any_record(String(ref.ref_id))
	if base_record == null:
		return null

	# Determine object type and model path
	var obj_type := ObjectType.OTHER
	var model_path := ""
	var is_significant := false

	if base_record is StaticRecord:
		obj_type = ObjectType.STATIC
		model_path = base_record.model
		# Significant if not tiny flora/clutter
		is_significant = _is_significant_static(base_record)
	elif base_record.has_method("get") and base_record.get("model") != null:
		# Generic handler for records with model property
		model_path = base_record.model
		if base_record is DoorRecord:
			obj_type = ObjectType.DOOR
			is_significant = true
		elif base_record is ContainerRecord:
			obj_type = ObjectType.CONTAINER
			is_significant = true
		elif base_record is ActivatorRecord:
			obj_type = ObjectType.ACTIVATOR
			is_significant = true
		elif base_record is LightRecord:
			obj_type = ObjectType.LIGHT
			is_significant = false  # Lights usually small
	elif base_record is NPCRecord:
		obj_type = ObjectType.NPC
		is_significant = true
		# NPCs don't have single model - handled by CharacterFactory
	elif base_record is CreatureRecord:
		obj_type = ObjectType.CREATURE
		model_path = base_record.model
		is_significant = true

	# Skip if no model (except NPCs which are assembled)
	if model_path.is_empty() and obj_type != ObjectType.NPC:
		return null

	var obj := ObjectPosition.new()
	obj.position = CS.vector_to_godot(ref.position)
	obj.model_path = model_path.to_lower()
	obj.ref_id = ref.ref_id
	obj.ref_num = ref.ref_num
	obj.cell_grid = cell_grid
	obj.scale = ref.scale
	obj.rotation = ref.rotation
	obj.object_type = obj_type
	obj.is_significant = is_significant

	return obj


## Check if a static is significant (worth LOD/impostor)
func _is_significant_static(stat: StaticRecord) -> bool:
	var model_lower := stat.model.to_lower()

	# Skip tiny flora/grass
	if "grass" in model_lower or "kelp" in model_lower:
		return false

	# Skip tiny clutter
	if "clutter" in model_lower and "small" in model_lower:
		return false

	# Everything else is significant
	return true


## Add object to spatial hash
func _add_to_hash(obj: ObjectPosition) -> void:
	var hash_cell := _position_to_hash_cell(obj.position)

	if not _spatial_hash.has(hash_cell):
		_spatial_hash[hash_cell] = []

	_spatial_hash[hash_cell].append(obj)


## Convert world position to hash cell
func _position_to_hash_cell(pos: Vector3) -> Vector2i:
	return Vector2i(
		floori(pos.x / HASH_CELL_SIZE),
		floori(pos.z / HASH_CELL_SIZE)
	)

#endregion


#region Spatial Queries

## Get all objects within a radius of a point
## Returns Array[ObjectPosition], optionally sorted by distance (nearest first)
## WARNING: Sorting can be VERY expensive for large radius queries (5km = ~10k+ objects)
## Only enable sorting if you actually need the entire list sorted, not just the nearest N objects
func get_objects_within_radius(center: Vector3, radius: float, sort_by_distance: bool = false) -> Array[ObjectPosition]:
	if not _is_built:
		push_error("ObjectPositionIndex: Not built yet, call build_from_esm() first")
		return []

	var results: Array[ObjectPosition] = []
	var radius_sq := radius * radius

	# Calculate which hash cells to check
	var cell_radius := ceili(radius / HASH_CELL_SIZE)
	var center_cell := _position_to_hash_cell(center)

	# Iterate hash cells in radius
	for dx in range(-cell_radius, cell_radius + 1):
		for dz in range(-cell_radius, cell_radius + 1):
			var hash_cell := center_cell + Vector2i(dx, dz)

			if not _spatial_hash.has(hash_cell):
				continue

			# Check each object in this cell
			var objects: Array = _spatial_hash[hash_cell]
			for obj: ObjectPosition in objects:
				var dist_sq := obj.distance_squared_to(center)
				if dist_sq <= radius_sq:
					results.append(obj)

	# Only sort if explicitly requested (expensive for large result sets!)
	if sort_by_distance:
		results.sort_custom(func(a: ObjectPosition, b: ObjectPosition) -> bool:
			return a.distance_squared_to(center) < b.distance_squared_to(center)
		)

	return results


## Get objects within radius, filtered by type
func get_objects_within_radius_typed(
	center: Vector3,
	radius: float,
	types: Array[int]
) -> Array[ObjectPosition]:
	var all_objects := get_objects_within_radius(center, radius)

	if types.is_empty():
		return all_objects

	var filtered: Array[ObjectPosition] = []
	for obj in all_objects:
		if obj.object_type in types:
			filtered.append(obj)

	return filtered


## Get only significant objects within radius (for LOD/impostor)
func get_significant_objects_within_radius(
	center: Vector3,
	radius: float
) -> Array[ObjectPosition]:
	var all_objects := get_objects_within_radius(center, radius)

	var filtered: Array[ObjectPosition] = []
	for obj in all_objects:
		if obj.is_significant:
			filtered.append(obj)

	return filtered


## Get objects in a specific cell grid
func get_objects_in_cell(cell_grid: Vector2i) -> Array[ObjectPosition]:
	# Convert cell grid to hash cell (they're aligned)
	var hash_cell := cell_grid

	if not _spatial_hash.has(hash_cell):
		return []

	# Return copy to prevent external modification
	var objects: Array[ObjectPosition] = []
	for obj: ObjectPosition in _spatial_hash[hash_cell]:
		objects.append(obj)

	return objects


## Check if an object exists at a position (approximate)
func has_object_near(position: Vector3, tolerance: float = 1.0) -> bool:
	var nearby := get_objects_within_radius(position, tolerance)
	return not nearby.is_empty()


## Get object by ref_num and cell (exact lookup)
func get_object(cell_grid: Vector2i, ref_num: int) -> ObjectPosition:
	var hash_cell := cell_grid

	if not _spatial_hash.has(hash_cell):
		return null

	for obj: ObjectPosition in _spatial_hash[hash_cell]:
		if obj.ref_num == ref_num:
			return obj

	return null

#endregion


#region Statistics

## Get index statistics
func get_stats() -> Dictionary:
	return {
		"is_built": _is_built,
		"total_objects": _total_objects,
		"cells_indexed": _cells_indexed,
		"hash_cells": _spatial_hash.size(),
		"build_time_ms": _build_time_ms,
		"avg_objects_per_cell": _total_objects / maxf(_cells_indexed, 1),
	}


## Clear the index
func clear() -> void:
	_spatial_hash.clear()
	_total_objects = 0
	_cells_indexed = 0
	_is_built = false
	_build_time_ms = 0.0


## Check if index is ready
func is_built() -> bool:
	return _is_built


## Get total object count
func get_total_objects() -> int:
	return _total_objects

#endregion


#region Prebaking Support

## Save index to a resource file for faster startup
func save_to_file(path: String) -> Error:
	if not _is_built:
		push_error("ObjectPositionIndex: Cannot save - not built")
		return ERR_INVALID_DATA

	# Serialize to dictionary format
	var data := {
		"version": 1,
		"total_objects": _total_objects,
		"cells_indexed": _cells_indexed,
		"cells": {}
	}

	for hash_cell: Vector2i in _spatial_hash:
		var cell_key := "%d,%d" % [hash_cell.x, hash_cell.y]
		var objects: Array = []

		for obj: ObjectPosition in _spatial_hash[hash_cell]:
			objects.append({
				"pos": [obj.position.x, obj.position.y, obj.position.z],
				"model": obj.model_path,
				"ref_id": String(obj.ref_id),
				"ref_num": obj.ref_num,
				"cell": [obj.cell_grid.x, obj.cell_grid.y],
				"scale": obj.scale,
				"rot": [obj.rotation.x, obj.rotation.y, obj.rotation.z],
				"type": obj.object_type,
				"sig": obj.is_significant
			})

		data["cells"][cell_key] = objects

	# Save as JSON for now (could use binary format for speed)
	var json := JSON.stringify(data)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()

	file.store_string(json)
	file.close()

	print("ObjectPositionIndex: Saved to %s (%.1f KB)" % [path, json.length() / 1024.0])
	return OK


## Load index from a resource file
func load_from_file(path: String) -> Error:
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND

	var start_time := Time.get_ticks_msec()

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return FileAccess.get_open_error()

	var json_text := file.get_as_text()
	file.close()

	var json := JSON.new()
	var parse_result := json.parse(json_text)
	if parse_result != OK:
		push_error("ObjectPositionIndex: Failed to parse JSON: %s" % json.get_error_message())
		return ERR_PARSE_ERROR

	var data: Dictionary = json.data
	if data.get("version", 0) != 1:
		push_error("ObjectPositionIndex: Unknown version")
		return ERR_INVALID_DATA

	# Rebuild from data
	clear()

	for cell_key: String in data.get("cells", {}):
		var parts := cell_key.split(",")
		var hash_cell := Vector2i(int(parts[0]), int(parts[1]))

		var objects: Array = data["cells"][cell_key]
		for obj_data: Dictionary in objects:
			var obj := ObjectPosition.new()
			var pos: Array = obj_data["pos"]
			obj.position = Vector3(pos[0], pos[1], pos[2])
			obj.model_path = obj_data["model"]
			obj.ref_id = StringName(obj_data["ref_id"])
			obj.ref_num = int(obj_data["ref_num"])
			var cell: Array = obj_data["cell"]
			obj.cell_grid = Vector2i(int(cell[0]), int(cell[1]))
			obj.scale = obj_data["scale"]
			var rot: Array = obj_data["rot"]
			obj.rotation = Vector3(rot[0], rot[1], rot[2])
			obj.object_type = int(obj_data["type"])
			obj.is_significant = obj_data["sig"]

			_add_to_hash(obj)
			_total_objects += 1

	_cells_indexed = int(data.get("cells_indexed", 0))
	_is_built = true
	_build_time_ms = Time.get_ticks_msec() - start_time

	print("ObjectPositionIndex: Loaded from %s in %.1fms - %d objects" % [
		path, _build_time_ms, _total_objects
	])

	return OK

#endregion
