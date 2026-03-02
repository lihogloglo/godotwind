## MidTierBatchPool - MultiMesh batching for MID-tier objects (150-500m)
##
## Groups objects by (mesh_type, lod_level) into MultiMesh draw calls.
## Reduces MID-tier draw calls from ~200-500 individual RS instances
## to ~30-80 batched MultiMesh draw calls.
##
## Each batch is a MultiMeshInstance3D with visibility_range matching its LOD band:
##   LOD1 batch: 150-250m
##   LOD2 batch: 250-375m
##   LOD3 batch: 375-500m
##
## Adapted from NativeImpostorRenderer's batching pattern.
##
## Usage:
##   var pool := MidTierBatchPool.new()
##   add_child(pool)
##   pool.register_mesh("flora_kelp", {1: mesh_lod1, 2: mesh_lod2, 3: mesh_lod3})
##   pool.add_object("flora_kelp", obj_id, transform, cell_grid)
##   pool.rebuild_dirty_batches(2.0)  # Call each frame with budget
class_name MidTierBatchPool
extends Node3D

const DU := preload("res://src/core/world/distance_utils.gd")

## Minimum capacity for new batches (grows in powers of 2)
const MIN_BATCH_CAPACITY: int = 32
## Debounce delay before rebuilding dirty batches (seconds)
const REBUILD_DEBOUNCE: float = 0.1

## Zero-scale transform to hide MultiMesh instances.
## Transform3D() is IDENTITY (scale 1,1,1 at origin) — would render visibly!
## This uses a zero basis so the GPU early-outs on degenerate triangles.
var _hidden_xform := Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), Vector3.ZERO)

#region Data Classes

## Registered mesh data for one LOD level of one mesh type
class LodMeshData:
	var mesh: Mesh
	var material: Material
	var mesh_ref: Mesh        ## Strong ref to prevent GC
	var material_ref: Material ## Strong ref to prevent GC

## Registered mesh type with up to 3 LOD levels
class MeshTypeData:
	var type_name: String
	var lod_meshes: Dictionary = {}  ## {lod_level: int -> LodMeshData}
	var aabb: AABB

## A single MultiMesh batch for one (mesh_type, lod_level) combination
class BatchData:
	var batch_key: String
	var type_name: String
	var lod_level: int
	var multimesh: MultiMesh
	var instance_node: MultiMeshInstance3D
	var capacity: int = MIN_BATCH_CAPACITY
	## object_id -> slot index in MultiMesh
	var slot_map: Dictionary[int, int] = {}
	## Reusable slots from removed objects
	var free_slots: Array[int] = []
	var next_slot: int = 0
	## Highest occupied slot index (avoids O(n) scan during rebuild)
	var max_used_slot: int = -1
	var dirty: bool = false
	var last_change_time: float = 0.0

## Per-object metadata (for promotion and cell cleanup)
class ObjectEntry:
	var object_id: int
	var type_name: String
	var transform: Transform3D
	var cell_grid: Vector2i
	var visible: bool = true
	## Metadata for MID→NEAR promotion
	var model_path: String
	var item_id: String
	var ref_id: StringName
	var ref_num: int

#endregion

#region State

## Registered mesh types: type_name -> MeshTypeData
var _mesh_types: Dictionary[String, MeshTypeData] = {}

## All batches: batch_key -> BatchData (batch_key = "type_name_lodN")
var _batches: Dictionary[String, BatchData] = {}

## All objects: object_id -> ObjectEntry
var _objects: Dictionary[int, ObjectEntry] = {}

## Spatial index: cell_grid -> Array[int] of object_ids
var _cell_index: Dictionary[Vector2i, Array] = {}

## Next object ID
var _next_id: int = 0

## Stats
var _stats: Dictionary = {
	"mesh_types": 0,
	"batches": 0,
	"total_objects": 0,
	"visible_objects": 0,
	"rebuilds": 0,
}

#endregion


#region Mesh Registration

## Register a mesh type with LOD meshes extracted from a prototype Node3D.
## Finds LOD0 (main mesh) and _LOD1/_LOD2/_LOD3 sibling meshes.
## Returns true if at least one LOD mesh was found.
func register_from_prototype(type_name: String, prototype: Node3D) -> bool:
	if type_name in _mesh_types:
		return true

	var data := MeshTypeData.new()
	data.type_name = type_name

	# Walk the prototype tree and extract LOD meshes
	_extract_lod_meshes(prototype, data)

	# Fill missing LOD bands with best available fallback
	# Ensures objects are visible across all MID bands (150-500m)
	if not data.lod_meshes.is_empty():
		for level: int in [2, 3]:
			if level not in data.lod_meshes:
				for fallback: int in range(level - 1, 0, -1):
					if fallback in data.lod_meshes:
						data.lod_meshes[level] = data.lod_meshes[fallback]
						break

	if data.lod_meshes.is_empty():
		return false

	# Use the highest-detail available LOD for the AABB
	for level: int in [1, 2, 3]:
		if level in data.lod_meshes:
			var lod_data: LodMeshData = data.lod_meshes[level]
			if lod_data.mesh:
				data.aabb = lod_data.mesh.get_aabb()
				break

	_mesh_types[type_name] = data
	_stats["mesh_types"] = _mesh_types.size()

	# Create batches for each LOD level
	for lod_level: int in data.lod_meshes:
		_create_batch(type_name, lod_level, data)

	return true


## Extract LOD meshes from a prototype node tree
func _extract_lod_meshes(node: Node, data: MeshTypeData) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if not mi.mesh:
			return

		var node_name: String = node.name
		var lod_level := _get_lod_level_from_name(node_name)

		var lod_data := LodMeshData.new()
		lod_data.mesh = mi.mesh
		lod_data.mesh_ref = mi.mesh  # Strong ref
		# Only propagate explicit material_override (intentional full-mesh override).
		# Do NOT grab surface[0] material — multi-surface meshes have per-surface
		# materials baked in that MultiMesh inherits automatically.
		if mi.material_override:
			lod_data.material = mi.material_override
			lod_data.material_ref = mi.material_override

		# LOD0 (no suffix) maps to LOD1 for MID tier (closest MID band)
		if lod_level == 0:
			# Only use LOD0 as fallback if no dedicated LOD1 exists
			if 1 not in data.lod_meshes:
				data.lod_meshes[1] = lod_data
		else:
			data.lod_meshes[lod_level] = lod_data
		return  # Don't recurse into MeshInstance3D children

	for child in node.get_children():
		_extract_lod_meshes(child, data)


## Get LOD level from node name (0 = LOD0/base, 1-3 = LOD levels)
func _get_lod_level_from_name(node_name: String) -> int:
	var lower := node_name.to_lower()
	if lower.ends_with("_lod3"):
		return 3
	elif lower.ends_with("_lod2"):
		return 2
	elif lower.ends_with("_lod1"):
		return 1
	return 0  # Base mesh (LOD0)

#endregion


#region Batch Management

## Create a batch for a specific (type_name, lod_level) combination
func _create_batch(type_name: String, lod_level: int, mesh_data: MeshTypeData) -> BatchData:
	var batch_key := _make_batch_key(type_name, lod_level)
	if batch_key in _batches:
		return _batches[batch_key]

	var lod_data: LodMeshData = mesh_data.lod_meshes[lod_level]

	var batch := BatchData.new()
	batch.batch_key = batch_key
	batch.type_name = type_name
	batch.lod_level = lod_level

	# Create MultiMesh with pre-allocated capacity (avoids per-add reallocation)
	batch.multimesh = MultiMesh.new()
	batch.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	batch.multimesh.mesh = lod_data.mesh
	batch.multimesh.instance_count = MIN_BATCH_CAPACITY
	batch.multimesh.visible_instance_count = 0  # Nothing visible yet

	# Initialize all slots to hidden transform
	for i in MIN_BATCH_CAPACITY:
		batch.multimesh.set_instance_transform(i, _hidden_xform)

	# Create MultiMeshInstance3D with visibility_range for this LOD band
	batch.instance_node = MultiMeshInstance3D.new()
	batch.instance_node.name = batch_key
	batch.instance_node.multimesh = batch.multimesh

	# Apply material override if available
	if lod_data.material:
		batch.instance_node.material_override = lod_data.material

	# Set visibility_range for this LOD band
	_configure_lod_visibility(batch.instance_node, lod_level)

	# Disable shadow casting for MID-tier objects (150-500m)
	# Shadows from distant flora/rocks are invisible but cost GPU shadow atlas passes
	batch.instance_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	add_child(batch.instance_node)

	_batches[batch_key] = batch
	_stats["batches"] = _batches.size()
	return batch


## Configure visibility_range on a MultiMeshInstance3D for a LOD band
func _configure_lod_visibility(node: MultiMeshInstance3D, lod_level: int) -> void:
	match lod_level:
		1:
			node.visibility_range_begin = DU.NEAR_END       # 150
			node.visibility_range_end = DU.LOD1_END          # 250
			node.visibility_range_begin_margin = DU.FADE_MARGIN_NEAR_LOD1  # 5
			node.visibility_range_end_margin = DU.FADE_MARGIN_LOD1_LOD2    # 10
		2:
			node.visibility_range_begin = DU.LOD1_END        # 250
			node.visibility_range_end = DU.LOD2_END          # 375
			node.visibility_range_begin_margin = DU.FADE_MARGIN_LOD1_LOD2  # 10
			node.visibility_range_end_margin = DU.FADE_MARGIN_LOD2_LOD3    # 15
		3:
			node.visibility_range_begin = DU.LOD2_END        # 375
			node.visibility_range_end = DU.LOD3_END          # 500
			node.visibility_range_begin_margin = DU.FADE_MARGIN_LOD2_LOD3  # 15
			node.visibility_range_end_margin = DU.FADE_MARGIN_LOD3_FAR     # 20
	node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES


func _make_batch_key(type_name: String, lod_level: int) -> String:
	return "%s_lod%d" % [type_name, lod_level]

#endregion


#region Object Add/Remove

## Add an object to the batch pool. Creates entries for all available LOD levels.
## Returns an object_id for later removal/visibility control, or -1 on failure.
func add_object(type_name: String, transform: Transform3D, cell_grid: Vector2i,
		model_path: String = "", item_id: String = "",
		ref_id: StringName = &"", ref_num: int = 0) -> int:
	if type_name not in _mesh_types:
		return -1

	var mesh_data: MeshTypeData = _mesh_types[type_name]
	var object_id := _next_id
	_next_id += 1

	# Add to each LOD batch that has a mesh registered
	for lod_level: int in mesh_data.lod_meshes:
		var batch_key := _make_batch_key(type_name, lod_level)
		var batch: BatchData = _batches.get(batch_key)
		if not batch:
			continue

		var slot := _allocate_slot(batch)
		batch.multimesh.set_instance_transform(slot, transform)
		batch.slot_map[object_id] = slot
		if slot > batch.max_used_slot:
			batch.max_used_slot = slot
		# Ensure object is visible THIS frame (don't wait for rebuild debounce)
		if batch.multimesh.visible_instance_count <= slot:
			batch.multimesh.visible_instance_count = slot + 1
		batch.dirty = true
		batch.last_change_time = Time.get_ticks_msec() / 1000.0

	# Store object entry
	var entry := ObjectEntry.new()
	entry.object_id = object_id
	entry.type_name = type_name
	entry.transform = transform
	entry.cell_grid = cell_grid
	entry.model_path = model_path
	entry.item_id = item_id
	entry.ref_id = ref_id
	entry.ref_num = ref_num
	_objects[object_id] = entry

	# Spatial index
	if cell_grid not in _cell_index:
		_cell_index[cell_grid] = [] as Array[int]
	_cell_index[cell_grid].append(object_id)

	_stats["total_objects"] = _objects.size()
	_stats["visible_objects"] += 1
	return object_id


## Remove an object from all its batches.
## skip_spatial_index: true when called from remove_cell() (bulk cleanup handles it)
func _remove_object_internal(object_id: int, skip_spatial_index: bool) -> void:
	if object_id not in _objects:
		return

	var entry: ObjectEntry = _objects[object_id]
	var mesh_data: MeshTypeData = _mesh_types.get(entry.type_name)

	# Remove from each LOD batch
	if mesh_data:
		for lod_level: int in mesh_data.lod_meshes:
			var batch_key := _make_batch_key(mesh_data.type_name, lod_level)
			var batch: BatchData = _batches.get(batch_key)
			if batch and object_id in batch.slot_map:
				var slot: int = batch.slot_map[object_id]
				batch.multimesh.set_instance_transform(slot, _hidden_xform)
				batch.free_slots.append(slot)
				batch.slot_map.erase(object_id)
				batch.dirty = true
				batch.last_change_time = Time.get_ticks_msec() / 1000.0
				# Recalculate max_used_slot only if we removed the max
				if slot == batch.max_used_slot:
					batch.max_used_slot = _find_max_slot(batch)

	# Remove from spatial index (skip in bulk remove — caller handles it)
	if not skip_spatial_index and entry.cell_grid in _cell_index:
		var arr: Array = _cell_index[entry.cell_grid]
		var idx := arr.find(object_id)
		if idx >= 0:
			arr.remove_at(idx)
		if arr.is_empty():
			_cell_index.erase(entry.cell_grid)

	if entry.visible:
		_stats["visible_objects"] -= 1
	_objects.erase(object_id)
	_stats["total_objects"] = _objects.size()


## Remove an object from all its batches (public API)
func remove_object(object_id: int) -> void:
	_remove_object_internal(object_id, false)


## Remove all objects belonging to a cell (bulk unload).
## Skips per-object spatial index cleanup (O(1) instead of O(n²)).
func remove_cell(cell_grid: Vector2i) -> int:
	if cell_grid not in _cell_index:
		return 0

	var ids: Array = _cell_index[cell_grid].duplicate()
	# Erase the spatial index entry FIRST — avoid O(n²) per-object arr.find()
	_cell_index.erase(cell_grid)

	for obj_id: int in ids:
		_remove_object_internal(obj_id, true)
	return ids.size()


## Set visibility for an individual object (for MID→NEAR promotion)
## When hidden, the object's MultiMesh slot gets a zero-scale transform
func set_object_visible(object_id: int, visible: bool) -> void:
	if object_id not in _objects:
		return

	var entry: ObjectEntry = _objects[object_id]
	if entry.visible == visible:
		return

	entry.visible = visible
	var mesh_data: MeshTypeData = _mesh_types.get(entry.type_name)
	if not mesh_data:
		return

	for lod_level: int in mesh_data.lod_meshes:
		var batch_key := _make_batch_key(mesh_data.type_name, lod_level)
		var batch: BatchData = _batches.get(batch_key)
		if batch and object_id in batch.slot_map:
			var slot: int = batch.slot_map[object_id]
			if visible:
				batch.multimesh.set_instance_transform(slot, entry.transform)
			else:
				batch.multimesh.set_instance_transform(slot, _hidden_xform)
			batch.dirty = true

	if visible:
		_stats["visible_objects"] += 1
	else:
		_stats["visible_objects"] -= 1

#endregion


#region Slot Management

## Allocate a slot in a batch, growing capacity if needed
func _allocate_slot(batch: BatchData) -> int:
	# Reuse freed slot if available
	if not batch.free_slots.is_empty():
		return batch.free_slots.pop_back()

	# Need a new slot — grow if at capacity
	if batch.next_slot >= batch.capacity:
		_grow_batch(batch)

	var slot := batch.next_slot
	batch.next_slot += 1
	return slot


## Grow a batch's capacity (powers of 2).
## Pre-allocates the GPU buffer to avoid per-add reallocation.
func _grow_batch(batch: BatchData) -> void:
	var new_capacity := batch.capacity * 2
	batch.capacity = new_capacity
	# Resize GPU buffer once at the new capacity
	batch.multimesh.instance_count = new_capacity
	# Initialize new slots to hidden transform
	for i in range(batch.next_slot, new_capacity):
		batch.multimesh.set_instance_transform(i, _hidden_xform)


## Find the highest occupied slot in a batch (used when max slot is freed)
func _find_max_slot(batch: BatchData) -> int:
	var max_slot := -1
	for slot: int in batch.slot_map.values():
		if slot > max_slot:
			max_slot = slot
	return max_slot

#endregion


#region Rebuild

## Rebuild dirty batches within a time budget.
## Call this once per frame from the streaming manager.
func rebuild_dirty_batches(budget_ms: float) -> void:
	var start_usec := Time.get_ticks_usec()
	var now := Time.get_ticks_msec() / 1000.0
	var rebuilt := 0

	for batch_key: String in _batches:
		var batch: BatchData = _batches[batch_key]
		if not batch.dirty:
			continue

		# Debounce: wait for changes to settle
		if now - batch.last_change_time < REBUILD_DEBOUNCE:
			continue

		# Use tracked max_used_slot (O(1) instead of O(n) scan)
		if batch.max_used_slot >= 0:
			batch.multimesh.visible_instance_count = batch.max_used_slot + 1
		else:
			batch.multimesh.visible_instance_count = 0

		batch.dirty = false
		rebuilt += 1
		_stats["rebuilds"] += 1

		# Check budget
		var elapsed_ms := (Time.get_ticks_usec() - start_usec) / 1000.0
		if elapsed_ms >= budget_ms:
			break

#endregion


#region Queries

## Get object entry for promotion metadata
func get_object_entry(object_id: int) -> ObjectEntry:
	return _objects.get(object_id)


## Get objects in cells near camera within promotion distance
func get_promotable_objects(camera_pos: Vector3, max_distance_sq: float,
		cell_grids: Array[Vector2i]) -> Array[int]:
	var result: Array[int] = []
	for grid: Vector2i in cell_grids:
		if grid not in _cell_index:
			continue
		for obj_id: int in _cell_index[grid]:
			var entry: ObjectEntry = _objects.get(obj_id)
			if not entry or not entry.visible or entry.model_path.is_empty():
				continue
			var dist_sq := camera_pos.distance_squared_to(entry.transform.origin)
			if dist_sq < max_distance_sq:
				result.append(obj_id)
	return result


## Get statistics
func get_stats() -> Dictionary:
	var s := _stats.duplicate()
	s["batch_details"] = {}
	for batch_key: String in _batches:
		var batch: BatchData = _batches[batch_key]
		s["batch_details"][batch_key] = {
			"objects": batch.slot_map.size(),
			"capacity": batch.capacity,
			"free_slots": batch.free_slots.size(),
			"instance_count": batch.multimesh.instance_count,
			"visible_count": batch.multimesh.visible_instance_count,
		}
	return s


## Check if a mesh type is registered
func has_type(type_name: String) -> bool:
	return type_name in _mesh_types

#endregion


#region Cleanup

func _exit_tree() -> void:
	clear()


## Clear all objects and batches
func clear() -> void:
	_objects.clear()
	_cell_index.clear()

	for batch_key: String in _batches:
		var batch: BatchData = _batches[batch_key]
		if batch.instance_node and is_instance_valid(batch.instance_node):
			batch.instance_node.queue_free()
	_batches.clear()

	_stats["total_objects"] = 0
	_stats["visible_objects"] = 0
	_stats["batches"] = 0

#endregion
