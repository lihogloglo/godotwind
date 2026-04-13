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

## Maximum visibility range for individual MID instances.
## Default: MID_END (500m). When HLOD cells are available, set to HLOD_START (300m)
## so the HLOD cell mesh takes over at distance.
var visibility_range_end: float = DU.MID_END

## Stats
var _stats: Dictionary = {
	"mesh_types": 0,
	"total_instances": 0,
	"visible_instances": 0,
}


#region Data Classes

## Per-child-mesh entry inside a multi-mesh prototype
class SubMeshEntry:
	var mesh_resource: Mesh        ## Strong ref — prevents GC
	var mesh_rid: RID
	var material_resource: Material  ## Strong ref (whole-mesh override, may be null)
	var material_rid: RID
	var surface_materials: Array[Material] = []  ## Per-surface mats (strong refs)
	var local_transform: Transform3D  ## Child's transform relative to prototype root
	var has_lod_chain: bool = false


## Mesh type registration data
class MeshType:
	var name: String
	var mesh_rid: RID          ## Primary mesh RID (first child, for backwards compat)
	var material_rid: RID      ## Primary material RID (optional, whole-mesh override)
	var mesh_resource: Mesh    ## Strong reference — prevents GC when prototype is LRU-evicted
	var material_resource: Material  ## Strong reference — same reason
	var owns_mesh: bool        ## Whether we created the mesh RID
	var owns_material: bool    ## Whether we created the material RID
	var aabb: AABB             ## Bounding box for culling (union of all sub-meshes)
	var instance_count: int = 0
	## Per-surface materials (strong refs) for meshes without whole-mesh material_override
	var surface_materials: Array[Material] = []
	## Whether the embedded ArrayMesh carries a prebaked LOD chain (has_lod_chain meta).
	## Used by debug tooling + diagnostic reporting.
	var has_lod_chain: bool = false
	## All child meshes in the prototype. Single-mesh prototypes have one entry.
	## Multi-mesh buildings (Vivec cantons, Hlaalu, etc.) have 3-8 entries.
	var sub_meshes: Array[SubMeshEntry] = []


## Instance data
class InstanceData:
	var id: int
	var type_name: String
	var instance_rid: RID      ## Primary RS instance (first sub-mesh, for backwards compat)
	var sub_rids: Array[RID] = []  ## ALL RS instances (includes primary). Multi-mesh buildings have N.
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
## Post-B-wide: walks ALL visible MeshInstance3D children in the prototype tree
## and stores each as a SubMeshEntry. Multi-mesh buildings (3-8 children) get
## one RS instance per child at add_instance time, all tracked under one ID.
## Single-mesh prototypes (flora, small clutter) work exactly as before.
func register_from_prototype(type_name: String, prototype: Node3D) -> void:
	if type_name in _mesh_types:
		return

	var all_mis := _find_all_mesh_instances(prototype)
	if all_mis.is_empty():
		push_warning("StaticObjectRenderer: No mesh found in prototype for '%s'" % type_name)
		return

	# Build sub-mesh entries for every child MeshInstance3D
	var sub_entries: Array[SubMeshEntry] = []
	var union_aabb := AABB()
	var any_has_lod := false

	for mi: MeshInstance3D in all_mis:
		var entry := SubMeshEntry.new()
		entry.mesh_resource = mi.mesh
		entry.mesh_rid = mi.mesh.get_rid()
		# Local transform relative to prototype root
		if mi.get_parent() == prototype or mi == prototype:
			entry.local_transform = mi.transform
		else:
			# Deep child — accumulate transforms up to root
			entry.local_transform = _get_relative_transform(mi, prototype)
		entry.has_lod_chain = mi.mesh.has_meta("has_lod_chain") if mi.mesh is ArrayMesh else false
		if entry.has_lod_chain:
			any_has_lod = true

		# Material resolution: override > surface override > mesh surface
		if mi.material_override:
			entry.material_resource = mi.material_override
			entry.material_rid = mi.material_override.get_rid()
		else:
			var surface_count: int = mi.mesh.get_surface_count()
			for si in range(surface_count):
				var mat: Material = mi.get_surface_override_material(si)
				if not mat:
					mat = mi.mesh.surface_get_material(si)
				entry.surface_materials.append(mat)
			# Single-surface shortcut
			if surface_count == 1 and not entry.surface_materials.is_empty() and entry.surface_materials[0]:
				entry.material_resource = entry.surface_materials[0]
				entry.material_rid = entry.surface_materials[0].get_rid()
				entry.surface_materials.clear()

		# Expand union AABB
		var child_aabb := mi.mesh.get_aabb()
		var transformed_aabb := entry.local_transform * child_aabb
		if sub_entries.is_empty():
			union_aabb = transformed_aabb
		else:
			union_aabb = union_aabb.merge(transformed_aabb)

		sub_entries.append(entry)

	# Register using first child as primary (backwards compat for get_mesh_type_stats etc.)
	var first := sub_entries[0]
	register_mesh_type(type_name, first.mesh_resource,
		first.material_resource if first.material_resource else null)

	if type_name in _mesh_types:
		var mt: MeshType = _mesh_types[type_name]
		mt.sub_meshes = sub_entries
		mt.aabb = union_aabb
		mt.has_lod_chain = any_has_lod
		if not first.surface_materials.is_empty():
			mt.surface_materials = first.surface_materials


## Compatibility alias — post-B-wide there's no difference between the two
## registration paths. Kept so existing callers (cell_manager.gd, test scenes)
## continue to work without edits until they're cleaned up in Phase F.
func register_lod_from_prototype(type_name: String, prototype: Node3D) -> bool:
	register_from_prototype(type_name, prototype)
	return type_name in _mesh_types and _mesh_types[type_name].has_lod_chain


## Find ALL visible MeshInstance3D nodes in prototype tree (depth-first).
func _find_all_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh and mi.visible:
			result.append(mi)
	for child in node.get_children():
		result.append_array(_find_all_mesh_instances(child))
	return result


## Get a node's transform relative to a given ancestor.
func _get_relative_transform(node: Node3D, ancestor: Node3D) -> Transform3D:
	var xform := Transform3D.IDENTITY
	var current := node
	while current != null and current != ancestor:
		xform = current.transform * xform
		current = current.get_parent() as Node3D
	return xform

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

	# Create one RS instance per sub-mesh in the prototype.
	# Multi-mesh buildings (cantons, huts) get N RS instances; single-mesh
	# flora/clutter get 1. All tracked under the same instance ID.
	var sub_entries := mesh_type.sub_meshes
	if sub_entries.is_empty():
		# Fallback: legacy registration path (register_mesh_type called directly)
		var rid := _create_rs_instance(mesh_type.mesh_rid, mesh_type.material_rid,
			mesh_type.surface_materials, transform)
		data.instance_rid = rid
		data.sub_rids.append(rid)
	else:
		for entry: SubMeshEntry in sub_entries:
			var child_xform := transform * entry.local_transform
			var rid := _create_rs_instance(entry.mesh_rid, entry.material_rid,
				entry.surface_materials, child_xform)
			data.sub_rids.append(rid)
		# Primary RID = first (backwards compat)
		data.instance_rid = data.sub_rids[0]

	_instances[id] = data
	mesh_type.instance_count += 1
	_stats["total_instances"] += 1
	_stats["visible_instances"] += 1

	# Maintain spatial index
	if cell_grid not in _cell_index:
		_cell_index[cell_grid] = [] as Array[int]
	_cell_index[cell_grid].append(id)

	return id


## Create a single RS instance with visibility_range + LOD bias + material.
func _create_rs_instance(mesh_rid: RID, material_rid: RID,
		surface_materials: Array[Material], xform: Transform3D) -> RID:
	var rs := RenderingServer
	var instance_rid := rs.instance_create()
	rs.instance_set_base(instance_rid, mesh_rid)
	rs.instance_set_scenario(instance_rid, _scenario)
	rs.instance_set_transform(instance_rid, xform)

	# Apply material: prefer whole-mesh override, fall back to per-surface
	if material_rid.is_valid():
		rs.instance_geometry_set_material_override(instance_rid, material_rid)
	elif not surface_materials.is_empty():
		for si in range(surface_materials.size()):
			var mat: Material = surface_materials[si]
			if mat:
				rs.instance_set_surface_override_material(instance_rid, si, mat.get_rid())

	# Visibility range: 0 to visibility_range_end (default 500m, 300m with HLOD).
	# The embedded LOD chain handles sub-band selection within this range.
	rs.instance_geometry_set_visibility_range(
		instance_rid,
		0.0, visibility_range_end,
		0.0, DU.FADE_MARGIN_LOD3_FAR,           # 20m dither fade at far end
		RenderingServer.VISIBILITY_RANGE_FADE_SELF
	)

	# Default LOD bias — tunable per type later via streaming_config.
	rs.instance_geometry_set_lod_bias(instance_rid, 1.0)

	return instance_rid


## Remove an instance (frees all sub-mesh RS instances)
func remove_instance(id: int) -> void:
	if id not in _instances:
		return

	var data: InstanceData = _instances[id]

	for rid: RID in data.sub_rids:
		if rid.is_valid():
			RenderingServer.free_rid(rid)

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
		for rid: RID in data.sub_rids:
			if rid.is_valid():
				RenderingServer.instance_set_visible(rid, false)
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
			if data.visible:
				for rid: RID in data.sub_rids:
					if rid.is_valid():
						RenderingServer.instance_set_visible(rid, false)
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

## Set instance visibility (all sub-mesh RS instances)
func set_instance_visible(id: int, visible: bool) -> void:
	if id not in _instances:
		return

	var data: InstanceData = _instances[id]
	if data.visible == visible:
		return

	data.visible = visible

	for rid: RID in data.sub_rids:
		if rid.is_valid():
			RenderingServer.instance_set_visible(rid, visible)

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

	for rid: RID in data.sub_rids:
		if rid.is_valid():
			RenderingServer.instance_set_visible(rid, not is_promoted)


## Set instance transform (updates all sub-mesh RS instances with their local offsets)
func set_instance_transform(id: int, transform: Transform3D) -> void:
	if id not in _instances:
		return

	var data: InstanceData = _instances[id]
	data.transform = transform

	if data.type_name in _mesh_types:
		var mt: MeshType = _mesh_types[data.type_name]
		for i in range(mini(data.sub_rids.size(), mt.sub_meshes.size())):
			var rid: RID = data.sub_rids[i]
			if rid.is_valid():
				RenderingServer.instance_set_transform(rid, transform * mt.sub_meshes[i].local_transform)
	else:
		# Fallback: no sub_meshes info, just set primary
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
		for rid: RID in data.sub_rids:
			if rid.is_valid():
				rs.free_rid(rid)
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


## Get sub-mesh entries for a registered type (used by RuntimeHLODMerger).
## Returns empty array if type not registered.
func get_sub_meshes(type_name: String) -> Array[SubMeshEntry]:
	if type_name not in _mesh_types:
		return []
	return _mesh_types[type_name].sub_meshes

#endregion
