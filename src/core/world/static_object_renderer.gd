## StaticObjectRenderer - RenderingServer-based renderer for static world objects
##
## Uses RenderingServer directly instead of Node3D for maximum performance.
## Best for objects that are purely visual with no interaction.
##
## LOD Support (post-B-wide refactor):
## Each object is **one** RS instance. LODs live inside the ArrayMesh via
## `surface_lod_indices`, stamped at prebake time by `nif_converter`. Godot's
## C++ LOD selector picks the right level per frame from screen-space coverage
## + `lod_bias` — no sibling LOD nodes, no manual distance cascade, no
## per-LOD RS instances.
##
## The instance carries a single hard-cull `visibility_range` at 500m for the
## render→impostor tier handoff; sub-LOD selection is fully engine-driven.
##
## Usage:
##   var renderer := StaticObjectRenderer.new()
##   add_child(renderer)  # Needs to be in tree for scenario
##   renderer.register_from_prototype("flora_kelp", kelp_prototype)
##   var id := renderer.add_instance("flora_kelp", transform, cell_grid)
##   renderer.set_instance_visible(id, false)  # Hide for promotion
##   renderer.remove_instance(id)  # When cell unloads
class_name StaticObjectRenderer
extends Node3D

const DU := preload("res://src/core/world/distance_utils.gd")

## Registered mesh types: type_name -> MeshType
var _mesh_types: Dictionary[String, MeshType] = {}

## All instances: instance_id -> InstanceData
var _instances: Dictionary[int, InstanceData] = {}

## Spatial index: cell_grid Vector2i -> Array[int] of instance IDs
## Enables O(cell_count) lookups instead of O(total_instances) for promotion/removal
var _cell_index: Dictionary[Vector2i, Array] = {} # Array[int]

## Next instance ID
var _next_id: int = 0

## World scenario RID (set when entering tree)
var _scenario: RID = RID()

## Stats
var _stats: Dictionary = {
	"mesh_types": 0,
	"total_instances": 0,
	"visible_instances": 0,
}


#region Data Classes

## Mesh type registration data
class MeshType:
	var name: String
	var mesh_rid: RID          ## Primary mesh RID (carries embedded LOD chain)
	var material_rid: RID      ## Primary material RID (optional, whole-mesh override)
	var mesh_resource: Mesh    ## Strong reference — prevents GC when prototype is LRU-evicted
	var material_resource: Material  ## Strong reference — same reason
	var owns_mesh: bool        ## Whether we created the mesh RID
	var owns_material: bool    ## Whether we created the material RID
	var aabb: AABB             ## Bounding box for culling
	var instance_count: int = 0
	## Per-surface materials (strong refs) for meshes without whole-mesh material_override
	var surface_materials: Array[Material] = []
	## Whether the embedded ArrayMesh carries a prebaked LOD chain (has_lod_chain meta).
	## Used by debug tooling + diagnostic reporting.
	var has_lod_chain: bool = false


## Instance data
class InstanceData:
	var id: int
	var type_name: String
	var instance_rid: RID      ## Single RenderingServer instance (holds embedded LOD chain)
	var transform: Transform3D
	var visible: bool = true
	var promoted: bool = false  ## True when a NEAR Node3D exists for this instance
	var cell_grid: Vector2i    ## Which cell this belongs to
	var gpu_slot: int = -1     ## Slot index in GPUSceneDatabase (-1 if not tracked)
	## Metadata for MID→NEAR promotion (Phase 5b)
	var model_path: String     ## Original model path for prototype lookup
	var item_id: String        ## Item variant ID
	var ref_id: StringName     ## ESM reference ID (e.g., "barrel_01")
	var ref_num: int           ## ESM unique reference number

#endregion


func _enter_tree() -> void:
	_scenario = get_viewport().get_world_3d().scenario


func _exit_tree() -> void:
	# If quitting, fast_cleanup already freed RS RIDs — skip redundant work
	if Engine.has_meta("_quitting"):
		return
	clear()


#region Mesh Registration

## Register a mesh type that can be instanced
## mesh: Can be ArrayMesh, or null to create from arrays
## material: Optional material to apply
func register_mesh_type(type_name: String, mesh: Mesh, material: Material = null) -> void:
	if type_name in _mesh_types:
		return  # Already registered

	var mesh_type := MeshType.new()
	mesh_type.name = type_name

	# CRITICAL: Store strong references to Mesh/Material resources to keep them alive.
	# Without these, LRU cache eviction of prototypes can free the underlying resources,
	# invalidating the RIDs and causing RS instances to disappear.
	if mesh:
		mesh_type.mesh_rid = mesh.get_rid()
		mesh_type.mesh_resource = mesh
		mesh_type.owns_mesh = false
		mesh_type.aabb = mesh.get_aabb()
		mesh_type.has_lod_chain = mesh.has_meta("has_lod_chain")
	else:
		mesh_type.mesh_rid = RenderingServer.mesh_create()
		mesh_type.owns_mesh = true
		mesh_type.aabb = AABB()

	if material:
		mesh_type.material_rid = material.get_rid()
		mesh_type.material_resource = material
		mesh_type.owns_material = false
	else:
		mesh_type.material_rid = RID()
		mesh_type.owns_material = false

	_mesh_types[type_name] = mesh_type
	_stats["mesh_types"] += 1


## Register a mesh type from a Node3D prototype.
##
## Post-B-wide refactor: walks the prototype tree for a single MeshInstance3D
## carrying an ArrayMesh with an embedded LOD chain (or a plain mesh if the
## asset is too small for LOD generation). The embedded chain is driven by
## Godot's C++ LOD selector automatically once the RS instance exists.
func register_from_prototype(type_name: String, prototype: Node3D) -> void:
	if type_name in _mesh_types:
		return

	var mesh_instance := _find_mesh_instance(prototype)
	if not mesh_instance or not mesh_instance.mesh:
		push_warning("StaticObjectRenderer: No mesh found in prototype for '%s'" % type_name)
		return

	# Material resolution priority:
	# 1. material_override (whole-mesh, set by NIF converter)
	# 2. MeshInstance3D surface override materials
	# 3. Mesh resource surface materials
	var material: Material = null
	var surface_mats: Array[Material] = []

	if mesh_instance.material_override:
		material = mesh_instance.material_override
	else:
		var surface_count: int = mesh_instance.mesh.get_surface_count()
		for si in range(surface_count):
			var mat: Material = mesh_instance.get_surface_override_material(si)
			if not mat:
				mat = mesh_instance.mesh.surface_get_material(si)
			surface_mats.append(mat)
		# For single-surface, use as primary material
		if surface_count == 1 and not surface_mats.is_empty() and surface_mats[0]:
			material = surface_mats[0]
			surface_mats.clear()

	register_mesh_type(type_name, mesh_instance.mesh, material)

	if not surface_mats.is_empty() and type_name in _mesh_types:
		_mesh_types[type_name].surface_materials = surface_mats


## Compatibility alias — post-B-wide there's no difference between the two
## registration paths. Kept so existing callers (cell_manager.gd, test scenes)
## continue to work without edits until they're cleaned up in Phase F.
func register_lod_from_prototype(type_name: String, prototype: Node3D) -> bool:
	register_from_prototype(type_name, prototype)
	return type_name in _mesh_types and _mesh_types[type_name].has_lod_chain


## Find first MeshInstance3D in prototype.
## Post-B-wide: there are no sibling `_LODn` nodes, so the old skip clause is
## dead. Picks the first visible MeshInstance3D with a mesh.
func _find_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh and mi.visible:
			return mi
	for child in node.get_children():
		var result := _find_mesh_instance(child)
		if result:
			return result
	return null

#endregion


#region Instance Add/Remove

## Add an instance of a registered mesh type.
##
## Post-B-wide: single RS instance per object with a single hard-cull
## visibility_range at 500m (render→impostor tier handoff). Sub-LOD selection
## is driven by the embedded `surface_lod_indices` chain + Godot's C++ screen-
## space LOD selector, not by manual distance bands.
##
## Returns instance ID for later manipulation, or -1 on failure.
func add_instance(type_name: String, transform: Transform3D, cell_grid: Vector2i = Vector2i.ZERO,
		model_path: String = "", item_id: String = "", ref_id: StringName = &"", ref_num: int = 0) -> int:
	if type_name not in _mesh_types:
		return -1

	if not _scenario.is_valid():
		push_warning("StaticObjectRenderer: Not in scene tree, cannot create instances")
		return -1

	var mesh_type: MeshType = _mesh_types[type_name]
	var rs := RenderingServer
	var id := _next_id
	_next_id += 1

	var data := InstanceData.new()
	data.id = id
	data.type_name = type_name
	data.transform = transform
	data.visible = true
	data.cell_grid = cell_grid
	data.model_path = model_path
	data.item_id = item_id
	data.ref_id = ref_id
	data.ref_num = ref_num

	var instance_rid := rs.instance_create()
	rs.instance_set_base(instance_rid, mesh_type.mesh_rid)
	rs.instance_set_scenario(instance_rid, _scenario)
	rs.instance_set_transform(instance_rid, transform)

	# Apply material: prefer whole-mesh override, fall back to per-surface
	if mesh_type.material_rid.is_valid():
		rs.instance_geometry_set_material_override(instance_rid, mesh_type.material_rid)
	elif not mesh_type.surface_materials.is_empty():
		for si in range(mesh_type.surface_materials.size()):
			var mat: Material = mesh_type.surface_materials[si]
			if mat:
				rs.instance_set_surface_override_material(instance_rid, si, mat.get_rid())

	# Single render-tier→impostor-handoff visibility_range.
	# 0-500m covers NEAR + MID. The embedded LOD chain handles sub-band selection.
	# The FAR tier (500-5000m) is the impostor renderer's job; this band's end
	# margin provides the dither crossfade into it.
	rs.instance_geometry_set_visibility_range(
		instance_rid,
		0.0, DU.MID_END,                        # 0-500m
		0.0, DU.FADE_MARGIN_LOD3_FAR,           # 20m dither fade into impostor
		RenderingServer.VISIBILITY_RANGE_FADE_SELF
	)

	# Default LOD bias — tunable per type later via streaming_config.
	rs.instance_geometry_set_lod_bias(instance_rid, 1.0)

	data.instance_rid = instance_rid
	_instances[id] = data
	mesh_type.instance_count += 1
	_stats["total_instances"] += 1
	_stats["visible_instances"] += 1

	# Maintain spatial index
	if cell_grid not in _cell_index:
		_cell_index[cell_grid] = [] as Array[int]
	_cell_index[cell_grid].append(id)

	return id


## Remove an instance
func remove_instance(id: int) -> void:
	if id not in _instances:
		return

	var data: InstanceData = _instances[id]

	if data.instance_rid.is_valid():
		RenderingServer.free_rid(data.instance_rid)

	if data.type_name in _mesh_types:
		var mesh_type: MeshType = _mesh_types[data.type_name]
		mesh_type.instance_count -= 1

	if data.visible:
		_stats["visible_instances"] -= 1
	_stats["total_instances"] -= 1

	# Maintain spatial index (swap-and-pop for O(1) removal)
	if data.cell_grid in _cell_index:
		var cell_ids: Array = _cell_index[data.cell_grid]
		var idx := cell_ids.find(id)
		if idx >= 0:
			cell_ids[idx] = cell_ids.back()
			cell_ids.pop_back()
		if cell_ids.is_empty():
			_cell_index.erase(data.cell_grid)

	_instances.erase(id)


## Remove all instances belonging to a cell
## Uses spatial index for O(cell_size) instead of O(total_instances)
func remove_cell_instances(cell_grid: Vector2i) -> int:
	if cell_grid not in _cell_index:
		return 0

	var to_remove: Array = _cell_index[cell_grid].duplicate()
	for id: int in to_remove:
		remove_instance(id)

	return to_remove.size()


## Hide all instances belonging to a cell (fast — no GPU resource cleanup)
## Used for immediate visual removal before deferred free_rid() cleanup
func hide_cell_instances(cell_grid: Vector2i) -> int:
	if cell_grid not in _cell_index:
		return 0

	var count := 0
	for id: int in _cell_index[cell_grid]:
		if id not in _instances:
			continue
		var data: InstanceData = _instances[id]
		if data.instance_rid.is_valid():
			RenderingServer.instance_set_visible(data.instance_rid, false)
		data.visible = false
		count += 1

	return count


## Budgeted hide: hides up to `max_count` RS instances for a cell.
## Returns: [hidden_count, is_complete] — hidden_count is how many were hidden this call,
## is_complete is true when all instances in the cell have been hidden.
## Call repeatedly across frames until is_complete is true.
var _cell_hide_progress: Dictionary[Vector2i, int] = {}  # cell_grid -> index into _cell_index[grid]

func hide_cell_instances_budgeted(cell_grid: Vector2i, max_count: int) -> Array:
	if cell_grid not in _cell_index:
		_cell_hide_progress.erase(cell_grid)
		return [0, true]

	var cell_ids: Array = _cell_index[cell_grid]
	var start_idx: int = _cell_hide_progress.get(cell_grid, 0)
	var hidden := 0

	var i := start_idx
	while i < cell_ids.size() and hidden < max_count:
		var id: int = cell_ids[i]
		if id in _instances:
			var data: InstanceData = _instances[id]
			if data.visible and data.instance_rid.is_valid():
				RenderingServer.instance_set_visible(data.instance_rid, false)
				data.visible = false
				hidden += 1
		i += 1

	var is_complete: bool = i >= cell_ids.size()
	if is_complete:
		_cell_hide_progress.erase(cell_grid)
	else:
		_cell_hide_progress[cell_grid] = i
	return [hidden, is_complete]

#endregion


#region Visibility & Transform

## Set instance visibility
func set_instance_visible(id: int, visible: bool) -> void:
	if id not in _instances:
		return

	var data: InstanceData = _instances[id]
	if data.visible == visible:
		return

	data.visible = visible

	if data.instance_rid.is_valid():
		RenderingServer.instance_set_visible(data.instance_rid, visible)

	if visible:
		_stats["visible_instances"] += 1
	else:
		_stats["visible_instances"] -= 1


## Mark an instance as promoted (NEAR Node3D exists) and hide the RS instance.
##
## Post-B-wide: a promoted object is replaced by a full scene-tree Node3D for
## 0-150m (with physics), so we hide the single RS instance completely.
## Demotion shows it again. The `near_has_lods` parameter is preserved for
## signature compatibility with `native_streaming_manager.gd` but no longer
## affects behavior — there are no LOD1-3 RIDs to selectively hide.
func set_instance_promoted(id: int, is_promoted: bool, _near_has_lods: bool = true) -> void:
	if id not in _instances:
		return
	var data: InstanceData = _instances[id]
	if data.promoted == is_promoted:
		return
	data.promoted = is_promoted

	if data.instance_rid.is_valid():
		RenderingServer.instance_set_visible(data.instance_rid, not is_promoted)


## Set instance transform
func set_instance_transform(id: int, transform: Transform3D) -> void:
	if id not in _instances:
		return

	var data: InstanceData = _instances[id]
	data.transform = transform

	if data.instance_rid.is_valid():
		RenderingServer.instance_set_transform(data.instance_rid, transform)


## Get instance transform
func get_instance_transform(id: int) -> Transform3D:
	if id not in _instances:
		return Transform3D.IDENTITY
	return _instances[id].transform

#endregion


#region Batch Operations

## Batch add instances (more efficient than individual adds)
## transforms: Array of Transform3D
## Returns array of instance IDs
func add_instances_batch(type_name: String, transforms: Array, cell_grid: Vector2i = Vector2i.ZERO) -> Array[int]:
	var ids: Array[int] = []

	if type_name not in _mesh_types:
		return ids

	if not _scenario.is_valid():
		return ids

	for transform_var: Variant in transforms:
		if not transform_var is Transform3D:
			continue
		var xform: Transform3D = transform_var as Transform3D
		var id := add_instance(type_name, xform, cell_grid)
		if id >= 0:
			ids.append(id)

	return ids

#endregion


#region Cleanup

## Clear all instances and optionally mesh types
func clear(clear_mesh_types: bool = true) -> void:
	var rs := RenderingServer

	for id: int in _instances:
		var data: InstanceData = _instances[id]
		if data.instance_rid.is_valid():
			rs.free_rid(data.instance_rid)
	_instances.clear()
	_cell_index.clear()

	if clear_mesh_types:
		for type_name: String in _mesh_types:
			var mesh_type: MeshType = _mesh_types[type_name]
			if mesh_type.owns_mesh and mesh_type.mesh_rid.is_valid():
				rs.free_rid(mesh_type.mesh_rid)
			if mesh_type.owns_material and mesh_type.material_rid.is_valid():
				rs.free_rid(mesh_type.material_rid)
		_mesh_types.clear()
		_stats["mesh_types"] = 0

	_stats["total_instances"] = 0
	_stats["visible_instances"] = 0

#endregion


#region Queries

## Get statistics
func get_stats() -> Dictionary:
	return _stats.duplicate()


## Get mesh type info
func get_mesh_type_stats(type_name: String) -> Dictionary:
	if type_name not in _mesh_types:
		return {}

	var mesh_type: MeshType = _mesh_types[type_name]
	return {
		"name": mesh_type.name,
		"instance_count": mesh_type.instance_count,
		"aabb": mesh_type.aabb,
		"has_lod_chain": mesh_type.has_lod_chain,
	}


## Get all registered mesh type names
func get_registered_types() -> Array[String]:
	var types: Array[String] = []
	for type_name: String in _mesh_types:
		types.append(type_name)
	return types


## Get instances in cells near the camera that are within promotion distance
## Returns array of instance IDs whose origin is within max_distance of camera_pos
## Skips already-promoted instances (those with a NEAR Node3D counterpart)
## Uses spatial index for O(nearby_instances) instead of O(total_instances)
func get_promotable_instances(camera_pos: Vector3, max_distance_sq: float, cell_grids: Array[Vector2i]) -> Array[int]:
	var result: Array[int] = []
	for grid: Vector2i in cell_grids:
		if grid not in _cell_index:
			continue
		for id: int in _cell_index[grid]:
			var data: InstanceData = _instances.get(id)
			if not data:
				continue
			if data.promoted:
				continue
			if data.model_path.is_empty():
				continue
			var dist_sq := camera_pos.distance_squared_to(data.transform.origin)
			if dist_sq < max_distance_sq:
				result.append(id)
	return result


## Get instance data for promotion (returns null if not found)
func get_instance_data(id: int) -> InstanceData:
	return _instances.get(id) as InstanceData


## Check if a type is registered
func has_type(type_name: String) -> bool:
	return type_name in _mesh_types


## Check if a type has a prebaked LOD chain
func has_lod(type_name: String) -> bool:
	if type_name not in _mesh_types:
		return false
	return _mesh_types[type_name].has_lod_chain

#endregion
