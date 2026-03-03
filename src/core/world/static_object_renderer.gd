## StaticObjectRenderer - RenderingServer-based renderer for static world objects
##
## Uses RenderingServer directly instead of Node3D for maximum performance.
## Best for objects that are purely visual with no interaction:
## - Flora (grass, flowers, kelp)
## - Small rocks and debris
## - Distant buildings (MID LOD)
## - Ground clutter
##
## Benefits over Node3D:
## - No scene tree overhead (~40 bytes per Node vs ~16 bytes per RID)
## - Faster instantiation (no node creation, parenting, notifications)
## - Per-instance visibility_range via RS (correct per-object LOD)
## - Godot auto-batches identical mesh+material RS instances
##
## Limitations:
## - No physics - use for visual-only objects
## - No signals or scripting on instances
##
## LOD Support:
## When registered via register_lod_from_prototype(), each object gets up to 4 RS
## instances (LOD0/LOD1/LOD2/LOD3) with per-instance visibility_range set via
## RenderingServer.instance_geometry_set_visibility_range(). Godot handles
## distance-based LOD switching entirely in C++ — zero GDScript overhead.
##
## Usage:
##   var renderer := StaticObjectRenderer.new()
##   add_child(renderer)  # Needs to be in tree for scenario
##   renderer.register_lod_from_prototype("flora_kelp", kelp_prototype)
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
	"lod_instances": 0,
}


#region Data Classes

## Per-LOD mesh entry (mesh + material for one LOD level)
class LodMeshEntry:
	var mesh: Mesh              ## Strong ref to prevent GC
	var mesh_rid: RID
	var material: Material      ## Strong ref to prevent GC (nullable, whole-mesh override)
	var material_rid: RID
	## Per-surface materials: surface_index -> Material (strong ref)
	## Used when there's no material_override but surface materials exist on the mesh
	## or as MeshInstance3D surface overrides. Applied via RS per-surface override.
	var surface_materials: Array[Material] = []

## Mesh type registration data
class MeshType:
	var name: String
	var mesh_rid: RID          ## Primary mesh RID (LOD0/fallback)
	var material_rid: RID      ## Primary material RID (optional, whole-mesh override)
	var mesh_resource: Mesh    ## Strong reference — prevents GC when prototype is LRU-evicted
	var material_resource: Material  ## Strong reference — same reason
	var owns_mesh: bool        ## Whether we created the mesh RID
	var owns_material: bool    ## Whether we created the material RID
	var aabb: AABB             ## Bounding box for culling
	var instance_count: int = 0
	## Per-surface materials (strong refs) for single-mesh path
	## Used when there's no material_override but per-surface materials exist
	var surface_materials: Array[Material] = []
	## LOD meshes for MID tier (lod_level -> LodMeshEntry)
	## If populated, add_instance() creates per-LOD RS instances with visibility_range
	var lod_meshes: Dictionary = {}  ## {int -> LodMeshEntry}


## Instance data
class InstanceData:
	var id: int
	var type_name: String
	var instance_rid: RID      ## Primary RenderingServer instance (LOD0 or single-mesh fallback)
	var transform: Transform3D
	var visible: bool = true
	var promoted: bool = false  ## True when a NEAR Node3D exists for this instance
	var cell_grid: Vector2i    ## Which cell this belongs to
	var gpu_slot: int = -1     ## Slot index in GPUSceneDatabase (-1 if not tracked)
	## LOD instance RIDs — one per LOD level (LOD1/LOD2/LOD3)
	## Each has its own mesh, visibility_range, and transform
	## Empty for non-LOD types (single instance_rid used instead)
	var lod_rids: Array[RID] = []
	## Metadata for MID→NEAR promotion (Phase 5b)
	var model_path: String     ## Original model path for prototype lookup
	var item_id: String        ## Item variant ID
	var ref_id: StringName     ## ESM reference ID (e.g., "barrel_01")
	var ref_num: int           ## ESM unique reference number

#endregion


func _enter_tree() -> void:
	_scenario = get_viewport().get_world_3d().scenario


func _exit_tree() -> void:
	# Clean up all RenderingServer resources
	clear()


#region Mesh Registration

## Register a mesh type that can be instanced (single mesh, no LOD)
## mesh: Can be ArrayMesh, or null to create from arrays
## material: Optional material to apply
func register_mesh_type(type_name: String, mesh: Mesh, material: Material = null) -> void:
	if type_name in _mesh_types:
		return  # Already registered

	var mesh_type := MeshType.new()
	mesh_type.name = type_name

	# Get or create mesh RID
	# CRITICAL: Store strong references to Mesh/Material resources to keep them alive.
	# Without these, LRU cache eviction of prototypes can free the underlying resources,
	# invalidating the RIDs and causing RS instances to disappear.
	if mesh:
		mesh_type.mesh_rid = mesh.get_rid()
		mesh_type.mesh_resource = mesh
		mesh_type.owns_mesh = false
		mesh_type.aabb = mesh.get_aabb()
	else:
		mesh_type.mesh_rid = RenderingServer.mesh_create()
		mesh_type.owns_mesh = true
		mesh_type.aabb = AABB()

	# Get or create material RID
	if material:
		mesh_type.material_rid = material.get_rid()
		mesh_type.material_resource = material
		mesh_type.owns_material = false
	else:
		mesh_type.material_rid = RID()
		mesh_type.owns_material = false

	_mesh_types[type_name] = mesh_type
	_stats["mesh_types"] += 1


## Register a mesh type from a Node3D prototype (extracts first non-LOD mesh)
## For MID-tier with LOD support, use register_lod_from_prototype() instead.
func register_from_prototype(type_name: String, prototype: Node3D) -> void:
	if type_name in _mesh_types:
		return

	# Find first MeshInstance3D in prototype
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
		# Collect per-surface materials
		var surface_count: int = mesh_instance.mesh.get_surface_count()
		for si in range(surface_count):
			var mat: Material = mesh_instance.get_surface_override_material(si)
			if not mat:
				mat = mesh_instance.mesh.surface_get_material(si)
			surface_mats.append(mat)
		# For single-surface, use as primary material
		if surface_count == 1 and not surface_mats.is_empty() and surface_mats[0]:
			material = surface_mats[0]
			surface_mats.clear()  # Will use primary material_rid instead

	register_mesh_type(type_name, mesh_instance.mesh, material)

	# Store per-surface materials if no whole-mesh override was found
	if not surface_mats.is_empty() and type_name in _mesh_types:
		_mesh_types[type_name].surface_materials = surface_mats


## Register a mesh type with LOD meshes extracted from a prototype Node3D.
## Finds LOD0 (main mesh) and _LOD1/_LOD2/_LOD3 sibling meshes.
## Creates per-instance visibility_range on each LOD level for correct per-object LOD.
## Returns true if at least one LOD mesh was found.
func register_lod_from_prototype(type_name: String, prototype: Node3D) -> bool:
	if type_name in _mesh_types:
		return not _mesh_types[type_name].lod_meshes.is_empty()

	var mesh_type := MeshType.new()
	mesh_type.name = type_name

	# Walk the prototype tree and extract LOD meshes
	_extract_lod_meshes(prototype, mesh_type)

	# Fill missing LOD bands with best available fallback
	# Ensures objects are visible across ALL bands (0-500m)
	if not mesh_type.lod_meshes.is_empty():
		# Ensure LOD0 (NEAR, 0-150m) always exists — use best available mesh
		if 0 not in mesh_type.lod_meshes:
			for fallback: int in [1, 2, 3]:
				if fallback in mesh_type.lod_meshes:
					mesh_type.lod_meshes[0] = mesh_type.lod_meshes[fallback]
					break

		# Fill MID bands (LOD1-3) with best available fallback
		for level: int in [1, 2, 3]:
			if level not in mesh_type.lod_meshes:
				# Try lower levels first, then LOD0
				for fallback: int in range(level - 1, -1, -1):
					if fallback in mesh_type.lod_meshes:
						mesh_type.lod_meshes[level] = mesh_type.lod_meshes[fallback]
						break

	if mesh_type.lod_meshes.is_empty():
		# No LOD meshes found — fall back to single-mesh registration
		register_from_prototype(type_name, prototype)
		return type_name in _mesh_types

	# Use the highest-detail available LOD for the AABB and primary mesh
	for level: int in [0, 1, 2, 3]:
		if level in mesh_type.lod_meshes:
			var entry: LodMeshEntry = mesh_type.lod_meshes[level]
			mesh_type.mesh_rid = entry.mesh_rid
			mesh_type.mesh_resource = entry.mesh
			mesh_type.material_rid = entry.material_rid if entry.material_rid.is_valid() else RID()
			mesh_type.material_resource = entry.material
			mesh_type.aabb = entry.mesh.get_aabb() if entry.mesh else AABB()
			mesh_type.owns_mesh = false
			mesh_type.owns_material = false
			break

	_mesh_types[type_name] = mesh_type
	_stats["mesh_types"] = _mesh_types.size()
	return true


## Extract LOD meshes from a prototype node tree
func _extract_lod_meshes(node: Node, mesh_type: MeshType) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if not mi.mesh:
			return
		# Skip hidden meshes — these were filtered by MeshVisibilityUtils
		# (materialless/white-only nodes). Processing them can overwrite
		# a valid textured LOD0 entry with an untextured one.
		if not mi.visible:
			return

		var node_name: String = node.name
		var lod_level := _get_lod_level_from_name(node_name)

		var entry := LodMeshEntry.new()
		entry.mesh = mi.mesh
		entry.mesh_rid = mi.mesh.get_rid()

		# Material resolution priority:
		# 1. material_override (whole-mesh override, set by NIF converter)
		# 2. MeshInstance3D surface override materials (per-surface on the node)
		# 3. Mesh resource surface materials (baked into the mesh)
		# The RS instance needs explicit material assignment for #1 and #2 since
		# it only sees the mesh RID (not the MeshInstance3D node).
		# For #3, the RS instance inherits mesh surface materials automatically.
		if mi.material_override:
			entry.material = mi.material_override
			entry.material_rid = mi.material_override.get_rid()
		else:
			entry.material_rid = RID()
			# Collect per-surface materials for RS per-surface override
			var surface_count: int = mi.mesh.get_surface_count()
			var has_surface_mats := false
			for si in range(surface_count):
				# Check MeshInstance3D surface override first, then mesh surface material
				var mat: Material = mi.get_surface_override_material(si)
				if not mat:
					mat = mi.mesh.surface_get_material(si)
				if mat:
					has_surface_mats = true
				entry.surface_materials.append(mat)
			# If single-surface with a material, also set as primary for fallback
			if has_surface_mats and surface_count == 1 and entry.surface_materials[0]:
				entry.material = entry.surface_materials[0]
				entry.material_rid = entry.surface_materials[0].get_rid()

		# LOD0 (no suffix): store as LOD0 for NEAR range (0-150m) AND
		# as LOD1 fallback for MID tier (if no dedicated LOD1 exists)
		if lod_level == 0:
			mesh_type.lod_meshes[0] = entry
			if 1 not in mesh_type.lod_meshes:
				mesh_type.lod_meshes[1] = entry
		else:
			mesh_type.lod_meshes[lod_level] = entry
		return  # Don't recurse into MeshInstance3D children

	for child in node.get_children():
		_extract_lod_meshes(child, mesh_type)


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


## Find first MeshInstance3D in prototype, skipping LOD nodes
func _find_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		var node_name: String = node.name
		var is_lod := node_name.ends_with("_LOD1") or node_name.ends_with("_LOD2") or node_name.ends_with("_LOD3")
		if is_lod:
			Log.debug("streaming", "[StaticRenderer] Skipping LOD node: %s" % node_name)
		else:
			return node
	for child in node.get_children():
		var result := _find_mesh_instance(child)
		if result:
			return result
	return null

#endregion


#region Instance Add/Remove

## Add an instance of a registered mesh type.
## If the type has LOD meshes, creates per-LOD RS instances with visibility_range.
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

	if not mesh_type.lod_meshes.is_empty():
		# LOD path: create one RS instance per LOD level with per-instance visibility_range
		# Godot handles distance-based LOD switching entirely in C++
		for lod_level: int in mesh_type.lod_meshes:
			var lod_entry: LodMeshEntry = mesh_type.lod_meshes[lod_level]
			var lod_rid := rs.instance_create()
			rs.instance_set_base(lod_rid, lod_entry.mesh_rid)
			rs.instance_set_scenario(lod_rid, _scenario)
			rs.instance_set_transform(lod_rid, transform)

			# Apply material: prefer whole-mesh override, fall back to per-surface
			if lod_entry.material_rid.is_valid():
				rs.instance_geometry_set_material_override(lod_rid, lod_entry.material_rid)
			elif not lod_entry.surface_materials.is_empty():
				# Per-surface materials: apply each one via RS surface override
				for si in range(lod_entry.surface_materials.size()):
					var mat: Material = lod_entry.surface_materials[si]
					if mat:
						rs.instance_set_surface_override_material(lod_rid, si, mat.get_rid())

			# LOD0 (NEAR, 0-150m) keeps shadow casting for nearby visual quality.
			# LOD1-3 (MID, 150-500m) disable shadows to save GPU budget.
			if lod_level > 0:
				rs.instance_geometry_set_cast_shadows_setting(
					lod_rid, RenderingServer.SHADOW_CASTING_SETTING_OFF
				)

			# Set per-instance visibility_range for this LOD band
			var vis := _get_lod_visibility_range(lod_level)
			rs.instance_geometry_set_visibility_range(
				lod_rid,
				vis.begin, vis.end,
				vis.begin_margin, vis.end_margin,
				RenderingServer.VISIBILITY_RANGE_FADE_SELF
			)

			data.lod_rids.append(lod_rid)

		# Use first LOD RID as primary for backwards compatibility
		data.instance_rid = data.lod_rids[0] if not data.lod_rids.is_empty() else RID()
		_stats["lod_instances"] += data.lod_rids.size()
	else:
		# Single-mesh path: one RS instance with NEAR visibility_range (0-150m)
		# Small objects without LODs are only visible up close
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

		# Set NEAR visibility range so single-mesh objects aren't rendered at all distances
		var vis := _get_lod_visibility_range(0)
		rs.instance_geometry_set_visibility_range(
			instance_rid,
			vis.begin, vis.end,
			vis.begin_margin, vis.end_margin,
			RenderingServer.VISIBILITY_RANGE_FADE_SELF
		)

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


## Get visibility_range parameters for a LOD level
## Returns {begin, end, begin_margin, end_margin}
## Level 0 = NEAR range (0-150m), ensures objects are visible at all distances
## Level 1-3 = MID sub-bands
static func _get_lod_visibility_range(lod_level: int) -> Dictionary:
	match lod_level:
		0:
			return {
				"begin": 0.0,                             # Visible from camera
				"end": DU.NEAR_END,                       # 150
				"begin_margin": 0.0,
				"end_margin": DU.FADE_MARGIN_NEAR_LOD1,   # 5
			}
		1:
			return {
				"begin": DU.NEAR_END,                     # 150
				"end": DU.LOD1_END,                       # 250
				"begin_margin": DU.FADE_MARGIN_NEAR_LOD1, # 5
				"end_margin": DU.FADE_MARGIN_LOD1_LOD2,   # 10
			}
		2:
			return {
				"begin": DU.LOD1_END,                     # 250
				"end": DU.LOD2_END,                       # 375
				"begin_margin": DU.FADE_MARGIN_LOD1_LOD2, # 10
				"end_margin": DU.FADE_MARGIN_LOD2_LOD3,   # 15
			}
		3:
			return {
				"begin": DU.LOD2_END,                     # 375
				"end": DU.LOD3_END,                       # 500
				"begin_margin": DU.FADE_MARGIN_LOD2_LOD3, # 15
				"end_margin": DU.FADE_MARGIN_LOD3_FAR,    # 20
			}
		_:
			return {
				"begin": 0.0,
				"end": DU.NEAR_END,
				"begin_margin": 0.0,
				"end_margin": DU.FADE_MARGIN_NEAR_LOD1,
			}


## Remove an instance and all its LOD RIDs
func remove_instance(id: int) -> void:
	if id not in _instances:
		return

	var data: InstanceData = _instances[id]

	# Free LOD RS instances
	for lod_rid: RID in data.lod_rids:
		if lod_rid.is_valid():
			RenderingServer.free_rid(lod_rid)
	_stats["lod_instances"] -= data.lod_rids.size()

	# Free primary instance (only if not already freed as part of lod_rids)
	if data.lod_rids.is_empty() and data.instance_rid.is_valid():
		RenderingServer.free_rid(data.instance_rid)

	# Update stats
	if data.type_name in _mesh_types:
		var mesh_type: MeshType = _mesh_types[data.type_name]
		mesh_type.instance_count -= 1

	if data.visible:
		_stats["visible_instances"] -= 1
	_stats["total_instances"] -= 1

	# Maintain spatial index
	if data.cell_grid in _cell_index:
		var cell_ids: Array = _cell_index[data.cell_grid]
		var idx := cell_ids.find(id)
		if idx >= 0:
			cell_ids.remove_at(idx)
		if cell_ids.is_empty():
			_cell_index.erase(data.cell_grid)

	_instances.erase(id)


## Remove all instances belonging to a cell
## Uses spatial index for O(cell_size) instead of O(total_instances)
func remove_cell_instances(cell_grid: Vector2i) -> int:
	if cell_grid not in _cell_index:
		return 0

	# Copy the IDs since remove_instance modifies _cell_index
	var to_remove: Array = _cell_index[cell_grid].duplicate()

	for id: int in to_remove:
		remove_instance(id)

	return to_remove.size()

#endregion


#region Visibility & Transform

## Set instance visibility (hides/shows all LOD instances)
func set_instance_visible(id: int, visible: bool) -> void:
	if id not in _instances:
		return

	var data: InstanceData = _instances[id]
	if data.visible == visible:
		return

	data.visible = visible

	# Hide/show all LOD instances
	if not data.lod_rids.is_empty():
		for lod_rid: RID in data.lod_rids:
			RenderingServer.instance_set_visible(lod_rid, visible)
	else:
		RenderingServer.instance_set_visible(data.instance_rid, visible)

	if visible:
		_stats["visible_instances"] += 1
	else:
		_stats["visible_instances"] -= 1


## Mark an instance as promoted (NEAR Node3D exists) and hide overlapping RS LODs.
## On promotion: hides LOD0 RS instance (0-150m, duplicated by NEAR Node3D).
## LOD1-3 RS instances stay visible as a safety net for 150-500m coverage.
## If the NEAR Node3D has its own LOD children, the visual overlap is harmless
## (same mesh, same transform, just slight overdraw). If not, LOD1-3 prevent gaps.
## On demotion (is_promoted=false), LOD0 RS instance is shown again.
func set_instance_promoted(id: int, is_promoted: bool) -> void:
	if id not in _instances:
		return
	var data: InstanceData = _instances[id]
	if data.promoted == is_promoted:
		return
	data.promoted = is_promoted

	if not data.lod_rids.is_empty():
		# Only hide LOD0 (index 0) — NEAR Node3D always covers 0-150m.
		# Keep LOD1-3 visible so 150-500m is always covered even if the
		# NEAR Node3D doesn't have LOD children.
		RenderingServer.instance_set_visible(data.lod_rids[0], not is_promoted)
	elif data.instance_rid.is_valid():
		# Single-mesh path: hide the whole instance (NEAR Node3D replaces it)
		RenderingServer.instance_set_visible(data.instance_rid, not is_promoted)


## Set instance transform (updates all LOD instances)
func set_instance_transform(id: int, transform: Transform3D) -> void:
	if id not in _instances:
		return

	var data: InstanceData = _instances[id]
	data.transform = transform

	# Update all LOD instances
	if not data.lod_rids.is_empty():
		for lod_rid: RID in data.lod_rids:
			RenderingServer.instance_set_transform(lod_rid, transform)
	else:
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

	# Free all instances (including LOD RIDs)
	for id: int in _instances:
		var data: InstanceData = _instances[id]
		for lod_rid: RID in data.lod_rids:
			if lod_rid.is_valid():
				rs.free_rid(lod_rid)
		if data.lod_rids.is_empty() and data.instance_rid.is_valid():
			rs.free_rid(data.instance_rid)
	_instances.clear()
	_cell_index.clear()

	# Free mesh types if requested
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
	_stats["lod_instances"] = 0

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
		"has_lod": not mesh_type.lod_meshes.is_empty(),
		"lod_levels": mesh_type.lod_meshes.keys(),
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
				continue  # Already has a NEAR Node3D
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


## Check if a type has LOD meshes
func has_lod(type_name: String) -> bool:
	if type_name not in _mesh_types:
		return false
	return not _mesh_types[type_name].lod_meshes.is_empty()

#endregion
