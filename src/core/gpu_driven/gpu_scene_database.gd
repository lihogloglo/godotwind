## GPUSceneDatabase - SSBO-backed storage for MID/FAR objects
##
## This class manages the GPU-resident state for the world's objects,
## providing the foundation for GPU-driven culling and hybrid rendering.
##
## Struct Layout (96 bytes, std430):
## struct ObjectData {
##     vec4 position_radius;     // xyz: world pos, w: bounding radius
##     vec4 aabb_extent_meshID;  // xyz: half-extents, w: mesh_id (as float)
##     vec4 transform_col0;      // 3x4 affine transform (col 0)
##     vec4 transform_col1;      // 3x4 affine transform (col 1)
##     vec4 transform_col2;      // 3x4 affine transform (col 2)
##     uint lod_mask;
##     uint pad0, pad1, pad2;    // Align to 16 bytes
## };
class_name GPUSceneDatabase
extends RefCounted

const MAX_OBJECTS = 100_000
const STRIDE = 96

## GPU resources
var _rd: RenderingDevice = null
var _object_buffer: RID = RID()

## Slot management
var _free_slots: Array[int] = []
var _next_slot: int = 0
var _total_objects: int = 0

## Mapping: cell_grid -> Array of assigned slots
var _cell_slots: Dictionary[Vector2i, Array] = {} # Array[int]

## Whether resources are initialized
var _initialized: bool = false


func _init() -> void:
	_rd = RenderingServer.get_rendering_device()
	if not _rd:
		push_error("[GPURenderer] No RenderingDevice available")
		return

	_initialize_buffer()
	_initialized = true


func _initialize_buffer() -> void:
	var buffer_size = MAX_OBJECTS * STRIDE
	_object_buffer = _rd.storage_buffer_create(buffer_size)
	
	# Pre-fill free slots (optional, or just use _next_slot)
	for i in range(MAX_OBJECTS):
		_free_slots.append(MAX_OBJECTS - 1 - i)
	_next_slot = 0


## Add objects from a cell to the GPU database
## grid: The cell grid coordinates
## objects: Array of Dictionaries containing object data (transform, aabb, etc.)
func add_cell_objects(grid: Vector2i, objects: Array) -> Array[int]:
	if not _initialized:
		return []

	var slots: Array[int] = []
	var buffer_data = PackedByteArray()
	buffer_data.resize(objects.size() * STRIDE)

	for i in range(objects.size()):
		var slot = _allocate_slot()
		if slot == -1:
			push_error("[GPURenderer] Out of GPU scene slots!")
			break
		
		slots.append(slot)
		var obj = objects[i]
		_pack_object_data(buffer_data, i * STRIDE, obj)

	# Update the cell mapping
	_cell_slots[grid] = slots
	_total_objects += slots.size()

	# Upload in batches (not optimal but simple for Phase 2)
	# TODO: Use a dedicated staging buffer and async copy
	for i in range(slots.size()):
		var offset = slots[i] * STRIDE
		var data_slice = buffer_data.slice(i * STRIDE, (i + 1) * STRIDE)
		_rd.buffer_update(_object_buffer, offset, STRIDE, data_slice)

	return slots


## Remove all objects for a cell
func remove_cell_objects(grid: Vector2i) -> void:
	if grid not in _cell_slots:
		return

	var slots: Array[int] = _cell_slots[grid]
	for slot in slots:
		_deactivate_slot(slot)
		_free_slots.append(slot)

	_total_objects -= slots.size()
	_cell_slots.erase(grid)


func _allocate_slot() -> int:
	if _free_slots.is_empty():
		return -1
	return _free_slots.pop_back()


func _deactivate_slot(slot: int) -> void:
	# Set radius = -1 to mark as inactive for the cull shader
	var data = PackedByteArray()
	data.resize(STRIDE)
	data.encode_float(12, -1.0) # position_radius.w
	_rd.buffer_update(_object_buffer, slot * STRIDE, 16, data.slice(0, 16))


func _pack_object_data(buffer: PackedByteArray, offset: int, obj: Dictionary) -> void:
	var xform: Transform3D = obj.get("transform", Transform3D.IDENTITY)
	var aabb: AABB = obj.get("aabb", AABB())
	var mesh_id: float = obj.get("mesh_id", 0.0)
	var lod_mask: int = obj.get("lod_mask", 0)

	# vec4 position_radius (offset 0)
	buffer.encode_float(offset + 0, xform.origin.x)
	buffer.encode_float(offset + 4, xform.origin.y)
	buffer.encode_float(offset + 8, xform.origin.z)
	buffer.encode_float(offset + 12, aabb.get_longest_axis_size() * 0.5)

	# vec4 aabb_extent_meshID (offset 16)
	var extent = aabb.size * 0.5
	buffer.encode_float(offset + 16, extent.x)
	buffer.encode_float(offset + 20, extent.y)
	buffer.encode_float(offset + 24, extent.z)
	buffer.encode_float(offset + 28, mesh_id)

	# 3x4 transform columns (offset 32, 48, 64)
	# col 0
	buffer.encode_float(offset + 32, xform.basis.x.x)
	buffer.encode_float(offset + 36, xform.basis.y.x)
	buffer.encode_float(offset + 40, xform.basis.z.x)
	buffer.encode_float(offset + 44, xform.origin.x)
	# col 1
	buffer.encode_float(offset + 48, xform.basis.x.y)
	buffer.encode_float(offset + 52, xform.basis.y.y)
	buffer.encode_float(offset + 56, xform.basis.z.y)
	buffer.encode_float(offset + 60, xform.origin.y)
	# col 2
	buffer.encode_float(offset + 64, xform.basis.x.z)
	buffer.encode_float(offset + 68, xform.basis.y.z)
	buffer.encode_float(offset + 72, xform.basis.z.z)
	buffer.encode_float(offset + 76, xform.origin.z)

	# uint lod_mask (offset 80)
	buffer.encode_u32(offset + 80, lod_mask)
	
	# padding (offset 84, 88, 92)
	buffer.encode_u32(offset + 84, 0)
	buffer.encode_u32(offset + 88, 0)
	buffer.encode_u32(offset + 92, 0)


## Get the storage buffer RID
func get_buffer_rid() -> RID:
	return _object_buffer


## Get statistics
func get_stats() -> Dictionary:
	return {
		"total_objects": _total_objects,
		"free_slots": _free_slots.size(),
		"memory_mb": (MAX_OBJECTS * STRIDE) / (1024.0 * 1024.0)
	}


func cleanup() -> void:
	if _object_buffer.is_valid():
		_rd.free_rid(_object_buffer)
		_object_buffer = RID()
