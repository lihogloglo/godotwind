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
const PrototypeRegistryScript := preload("res://src/core/world/prototype_registry.gd")

## Phase 3 step 2 coexistence flag. When ON, add_instance routes through the
## world-scoped PrototypeRegistry (one MultiMesh per (mesh, material) hash
## across all loaded cells) instead of creating per-object RS instances.
## OFF (default) keeps the legacy per-object / per-cell-batch path.
##
## Toggle via the `proto_registry on|off` console command. Flag flips apply
## to NEWLY LOADED cells only — the caller is expected to reload cells or
## restart the scene for a clean A/B.
var use_prototype_registry: bool = false

## Lazily created registry — one per StaticObjectRenderer, shared across all
## cells loaded while the flag is ON. Null until first registry-routed add.
var _prototype_registry: RefCounted = null

## Registered mesh types: type_name -> MeshType
var _mesh_types: Dictionary[String, MeshType] = {}

## All instances: instance_id -> InstanceData
var _instances: Dictionary[int, InstanceData] = {}

## Spatial index: cell_grid Vector2i -> Array[int] of instance IDs
## Enables O(cell_count) lookups instead of O(total_instances) for promotion/removal
var _cell_index: Dictionary[Vector2i, Array] = {} # Array[int]

## Per-cell MultiMesh batches. Populated by batch_cell_into_multimesh(), freed
## by remove_cell_instances() / clear(). Each entry is an Array[CellBatch] —
## one entry per mesh type that was batched in that cell.
##
## NOTE 2026-04-17: shipped once, measured a regression (~15-20 FPS at steady
## state vs unbatched) because the per-cell centroid RS instance extends the
## effective visibility_range past what per-individual 500m culling would drop,
## and the 1000+ extra batch RS instances aren't offset by saved individual
## draws beyond 500m. Kept in the tree for iteration against a 150 FPS target —
## run with this path on if you want to tune MM_BATCH_MIN_COUNT, slot visibility,
## or switch to swap-pop compaction. `cell_manager.gd` calls
## `batch_cell_into_multimesh(grid)` at the end of `_finalize_request`.
var _cell_batches: Dictionary[Vector2i, Array] = {}  # Array[CellBatch]

## Minimum number of same-type instances in a cell before MultiMesh batching
## kicks in. Below this threshold the instances stay as individual RS instances —
## the per-batch overhead (MultiMesh allocation + one extra RS instance) outweighs
## the draw-call saving for tiny groups.
const MM_BATCH_MIN_COUNT: int = 4

## Next instance ID
var _next_id: int = 0

## World scenario RID (set when entering tree)
var _scenario: RID = RID()

## Maximum visibility range for individual MID instances.
## Default: MID_END (500m). When HLOD cells are available, set to HLOD_START (300m)
## so the HLOD cell mesh takes over at distance.
var visibility_range_end: float = DU.MID_END

## Global visibility override for benchmark A/B testing. When false, all RS
## instances are hidden and newly-created instances start hidden. Toggled by
## SubsystemToggles "mid_objects" flag via set_all_visible().
var _globally_visible: bool = true

## Stats
var _stats: Dictionary = {
	"mesh_types": 0,
	"total_instances": 0,
	"visible_instances": 0,
}


#region Data Classes

## Per-child-mesh entry inside a multi-mesh prototype.
##
## `mesh_rid` is intentionally NOT cached here (F3a, 2026-04-15). Derive it at
## use-time from `mesh_resource.get_rid()` — the strong ref guarantees the RID
## is valid as long as the entry exists. Caching the RID at registration was
## the root of the B1 RID-lifecycle hazard (static_object_renderer.gd:339
## `Initializing already initialized RID` / `Parameter mem is null` cluster).
class SubMeshEntry:
	var mesh_resource: Mesh        ## Strong ref — prevents GC; derive .get_rid() at use-time
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
	## MultiMesh batching (populated by batch_cell_into_multimesh). When batched,
	## sub_rids is cleared (the per-instance RS RIDs were freed and replaced by a
	## shared MultiMesh slot). visibility / promotion / removal route through
	## mm_slot + batch. -1 = not batched.
	var mm_slot: int = -1
	var batch: CellBatch = null
	## Phase 3 registry routing. When >= 0, this instance's slots live inside
	## the world-scoped PrototypeRegistry. sub_rids is empty; visibility /
	## promotion / removal route through the registry instead of RS RIDs.
	## Mutually exclusive with mm_slot / batch (registry path skips per-cell
	## batching entirely).
	var registry_id: int = -1
	## Metadata for MID→NEAR promotion (Phase 5b)
	var model_path: String     ## Original model path for prototype lookup
	var item_id: String        ## Item variant ID
	var ref_id: StringName     ## ESM reference ID (e.g., "barrel_01")
	var ref_num: int           ## ESM unique reference number


## Per-cell MultiMesh batch.
##
## Collapses N individual RS instances of the same mesh type within a cell into
## one draw call while preserving per-cell visibility_range + LOD behaviour.
## Canonical pattern (Unity StaticBatchingUtility / Unreal HISM): one MultiMesh
## per (cell, type), RS instance positioned at cell centroid so Godot's screen-
## space LOD selector evaluates against the cell's distance, and visibility_range
## fades the batch out at the same distance as individual instances would.
##
## Slot indexing: instance_data.mm_slot maps 1:1 to the slot the instance's
## transform was written into at batch creation. Promotion/visibility toggles
## that slot's transform to a zero-scale degenerate placeholder rather than
## compacting the MultiMesh (compaction would reshuffle every InstanceData's
## mm_slot — not worth the bookkeeping for a ~free GPU cost).
class CellBatch:
	var type_name: String
	var cell_grid: Vector2i
	var rs_instance: RID              ## Single RS instance with MultiMesh base
	var multimesh: MultiMesh          ## Strong ref — holds slot transforms + mesh ref
	var multimesh_rid: RID            ## Derived at use-time from multimesh.get_rid()
	var centroid: Vector3             ## RS instance origin (slots stored relative to this)
	var instance_ids: Array[int] = [] ## Instance IDs in this batch (parallel to slot index)
	var slot_count: int = 0

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
		if mi.mesh == null:
			continue  # Defensive: _find_all_mesh_instances filters but guard against future edits
		var entry := SubMeshEntry.new()
		entry.mesh_resource = mi.mesh
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

## Per-frame cull tick. No-op unless use_prototype_registry is ON and the
## registry has been instantiated. Returns the visible slot total (or -1
## when the registry decided the tick was unnecessary — e.g. static scene
## with no camera movement).
##
## Driver: native_streaming_manager._process. Passes current camera position
## and the active max-visible-distance squared (visibility_range_end²).
func tick_prototype_cull(cam_pos: Vector3, max_dist_sq: float) -> int:
	if not use_prototype_registry or _prototype_registry == null:
		return -1
	return _prototype_registry.tick_cull_if_needed(cam_pos, max_dist_sq)


## Lazily instantiate the PrototypeRegistry on first registry-routed add.
## Returns null if the scenario isn't set yet.
func _ensure_registry() -> RefCounted:
	if _prototype_registry != null:
		return _prototype_registry
	if not _scenario.is_valid():
		return null
	_prototype_registry = PrototypeRegistryScript.new(_scenario)
	return _prototype_registry


## Convert MeshType.sub_meshes into the dict-shape the registry expects.
## Mirrors prototype_registry.gd add_instance() input schema.
func _build_registry_sub_meshes(mesh_type: MeshType) -> Array:
	var out: Array = []
	out.resize(mesh_type.sub_meshes.size())
	for i in range(mesh_type.sub_meshes.size()):
		var entry: SubMeshEntry = mesh_type.sub_meshes[i]
		out[i] = {
			"mesh": entry.mesh_resource,
			"material": entry.material_resource,
			"local_transform": entry.local_transform,
		}
	return out


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

	# Phase 3 registry path — feature-flagged, coexists with legacy.
	# Branches early: skips per-sub-mesh RS.instance_create entirely and lets
	# the registry's world-scoped MultiMesh absorb this instance's slots.
	# Requires sub_meshes populated (register_from_prototype path); legacy
	# register_mesh_type callers fall through to the RS path below.
	if use_prototype_registry and not mesh_type.sub_meshes.is_empty():
		var registry := _ensure_registry()
		if registry != null:
			var subs: Array = _build_registry_sub_meshes(mesh_type)
			registry.add_instance(id, subs, transform, 0.0, DU.FADE_MARGIN_LOD3_FAR)
			data.registry_id = id
			_instances[id] = data
			mesh_type.instance_count += 1
			_stats["total_instances"] += 1
			_stats["visible_instances"] += 1
			if cell_grid not in _cell_index:
				_cell_index[cell_grid] = [] as Array[int]
			_cell_index[cell_grid].append(id)
			return id

	# Create one RS instance per sub-mesh in the prototype.
	# Multi-mesh buildings (cantons, huts) get N RS instances; single-mesh
	# flora/clutter get 1. All tracked under the same instance ID.
	# F3a (2026-04-15): derive mesh_rid at use-time from the strongly-held
	# mesh_resource. Caching the RID at registration was the root of the B1
	# `Initializing already initialized RID` / `mem is null` cluster.
	var sub_entries := mesh_type.sub_meshes
	if sub_entries.is_empty():
		# Fallback: legacy registration path (register_mesh_type called directly).
		# If we have the mesh resource, re-derive; else trust the owned/cached RID.
		var legacy_mesh_rid: RID = mesh_type.mesh_resource.get_rid() if mesh_type.mesh_resource \
			else mesh_type.mesh_rid
		var rid := _create_rs_instance(legacy_mesh_rid, mesh_type.material_rid,
			mesh_type.surface_materials, transform)
		if rid.is_valid():
			data.sub_rids.append(rid)
		data.instance_rid = rid
	else:
		for entry: SubMeshEntry in sub_entries:
			if entry.mesh_resource == null:
				continue
			var child_xform := transform * entry.local_transform
			var rid := _create_rs_instance(entry.mesh_resource.get_rid(), entry.material_rid,
				entry.surface_materials, child_xform)
			if rid.is_valid():
				data.sub_rids.append(rid)
		if not data.sub_rids.is_empty():
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
## Returns RID() on invalid mesh_rid — caller must guard against non-valid return.
func _create_rs_instance(mesh_rid: RID, material_rid: RID,
		surface_materials: Array[Material], xform: Transform3D) -> RID:
	# F3a (2026-04-15): defensive guard. An invalid mesh_rid reaching
	# instance_set_base was the B1 crash vector (`Initializing already initialized
	# RID` + `Parameter mem is null` cluster). Log once, skip cleanly.
	if not mesh_rid.is_valid():
		push_warning("StaticObjectRenderer: _create_rs_instance received invalid mesh_rid — skipping")
		return RID()
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

	if not _globally_visible:
		rs.instance_set_visible(instance_rid, false)

	return instance_rid


## Remove an instance — frees per-instance RS RIDs for unbatched, or zero-scales
## the MultiMesh slot for batched (slot stays allocated to avoid reshuffling).
func remove_instance(id: int) -> void:
	if id not in _instances:
		return

	var data: InstanceData = _instances[id]

	if data.registry_id >= 0 and _prototype_registry != null:
		# Registry owns the slots — release them back to the freelist. MultiMesh
		# + RS instance stay live (shared across all instances of the prototype).
		_prototype_registry.remove_instance(data.registry_id)
	elif data.mm_slot >= 0 and data.batch != null:
		# Vacate the MM slot. The slot index stays burned — compacting would
		# require rewriting every sibling InstanceData.mm_slot, which costs
		# more than the GPU price of a few degenerate triangles per cell.
		_hide_batch_slot(data.batch, data.mm_slot, data.transform.origin)
	else:
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
## Uses spatial index for O(cell_size) instead of O(total_instances).
## Also frees any per-cell MultiMesh batches (RS instance + MM resource).
func remove_cell_instances(cell_grid: Vector2i) -> int:
	if cell_grid not in _cell_index and cell_grid not in _cell_batches:
		return 0

	var removed := 0
	if cell_grid in _cell_index:
		var to_remove: Array = _cell_index[cell_grid].duplicate()
		for id: int in to_remove:
			remove_instance(id)
		removed = to_remove.size()

	# Batches freed AFTER per-instance removal (remove_instance zeroes the slots
	# but the RS instance + MM resource live on until here).
	_free_cell_batches(cell_grid)
	return removed


## Hide all instances belonging to a cell (fast — no GPU resource cleanup)
## Used for immediate visual removal before deferred free_rid() cleanup.
## Batched cells are hidden by toggling the cell's MM RS instances; individual
## instances are hidden per-RID.
func hide_cell_instances(cell_grid: Vector2i) -> int:
	var count := 0

	# Batched: one visibility toggle per batch covers all its slots.
	if cell_grid in _cell_batches:
		for batch: CellBatch in _cell_batches[cell_grid]:
			if batch.rs_instance.is_valid():
				RenderingServer.instance_set_visible(batch.rs_instance, false)

	if cell_grid in _cell_index:
		for id: int in _cell_index[cell_grid]:
			if id not in _instances:
				continue
			var data: InstanceData = _instances[id]
			if data.registry_id >= 0 and _prototype_registry != null:
				_prototype_registry.hide_instance(data.registry_id)
			elif data.mm_slot < 0:
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
	# On the first pass, toggle the cell's batch RS instances off cheaply — one
	# call per batch hides all its slots. The per-instance loop below still runs
	# for data.visible bookkeeping but skips RS work for batched instances.
	if start_idx == 0 and cell_grid in _cell_batches:
		for batch: CellBatch in _cell_batches[cell_grid]:
			if batch.rs_instance.is_valid():
				RenderingServer.instance_set_visible(batch.rs_instance, false)

	while i < cell_ids.size() and hidden < max_count:
		var id: int = cell_ids[i]
		if id in _instances:
			var data: InstanceData = _instances[id]
			if data.visible:
				if data.registry_id >= 0 and _prototype_registry != null:
					_prototype_registry.hide_instance(data.registry_id)
				elif data.mm_slot < 0:
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


## Collapse same-type instances in a cell into MultiMesh batches.
##
## Called once per cell after all of its instances have been created (hooked
## from `cell_manager._finalize_request`). For each mesh type in the cell whose
## prototype is single-sub-mesh AND has at least `MM_BATCH_MIN_COUNT` instances,
## creates a MultiMesh with one slot per instance and a single RS instance
## positioned at the centroid. The per-instance RS instances are freed and
## replaced by slot indexing; promotion / visibility / removal are routed to
## the batch slot by the other methods on this class.
##
## Types NOT batched (left as individuals):
##   - Multi-sub-mesh prototypes (buildings, cantons) — per-instance frustum
##     culling beats batching for high-vertex-count objects
##   - Types below the count threshold — batch overhead exceeds saving
##
## Returns the number of batches created (0 when nothing qualifies).
func batch_cell_into_multimesh(cell_grid: Vector2i) -> int:
	if cell_grid not in _cell_index:
		return 0
	if not _scenario.is_valid():
		return 0
	# Already batched — bail (batch_cell_into_multimesh is idempotent per cell).
	if cell_grid in _cell_batches:
		return 0

	# Snapshot the cell's instance IDs — downstream work touches _instances /
	# _mesh_types via MultiMesh allocation, so avoid any chance of concurrent
	# mutation invalidating the iterator.
	var cell_ids_snapshot: Array = (_cell_index[cell_grid] as Array).duplicate()

	var by_type: Dictionary[String, Array] = {}
	for id: int in cell_ids_snapshot:
		var data: InstanceData = _instances.get(id)
		if data == null:
			continue
		if data.mm_slot >= 0:
			continue  # Already batched (defensive)
		if data.promoted or not data.visible:
			continue  # Don't batch hidden/promoted instances
		var mt: MeshType = _mesh_types.get(data.type_name)
		if mt == null:
			continue
		if mt.sub_meshes.size() != 1:
			continue  # Multi-sub-mesh — keep individual
		if mt.sub_meshes[0].mesh_resource == null:
			continue
		# Instance must have at least one live RS RID to be a batch candidate —
		# if it's already been torn down we cannot reliably free it.
		if data.sub_rids.is_empty():
			continue
		if data.type_name not in by_type:
			by_type[data.type_name] = ([] as Array[int])
		(by_type[data.type_name] as Array).append(id)

	var batches_created := 0
	for type_name: String in by_type:
		var ids: Array = by_type[type_name]
		if ids.size() < MM_BATCH_MIN_COUNT:
			continue
		var batch := _create_cell_batch(cell_grid, type_name, ids)
		if batch != null:
			if cell_grid not in _cell_batches:
				_cell_batches[cell_grid] = ([] as Array[CellBatch])
			(_cell_batches[cell_grid] as Array).append(batch)
			batches_created += 1
	return batches_created


## Build a single CellBatch for `type_name` in `cell_grid`. Consumes the
## per-instance RS RIDs (frees them) and writes slot transforms into a fresh
## MultiMesh. Caller handles registering the batch in `_cell_batches`.
func _create_cell_batch(cell_grid: Vector2i, type_name: String, ids: Array) -> CellBatch:
	var mt: MeshType = _mesh_types.get(type_name)
	if mt == null or mt.sub_meshes.is_empty():
		return null
	var sub: SubMeshEntry = mt.sub_meshes[0]
	if sub.mesh_resource == null:
		return null
	var mesh_rid := sub.mesh_resource.get_rid()
	if not mesh_rid.is_valid():
		return null

	# Filter to instances that are still live (snapshot may pre-date a removal).
	var live_ids: Array[int] = []
	for id: int in ids:
		if _instances.has(id):
			live_ids.append(id)
	if live_ids.size() < MM_BATCH_MIN_COUNT:
		return null

	# Centroid anchor — RS instance origin. MM slot transforms are stored
	# relative so visibility_range / LOD evaluate at the cluster's position,
	# not at world origin.
	var centroid := Vector3.ZERO
	for id: int in live_ids:
		centroid += (_instances[id] as InstanceData).transform.origin
	centroid /= float(live_ids.size())

	var inv_anchor := Transform3D(Basis.IDENTITY, -centroid)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = sub.mesh_resource
	mm.instance_count = live_ids.size()

	for i in range(live_ids.size()):
		var data: InstanceData = _instances[live_ids[i]]
		var world_xform := data.transform * sub.local_transform
		# Slot stored relative to centroid: final world = centroid * (inv_anchor * world)
		#                                              = centroid * (centroid.inverse() * world) = world.
		mm.set_instance_transform(i, inv_anchor * world_xform)

	var rs := RenderingServer
	var rid := rs.instance_create()
	rs.instance_set_base(rid, mm.get_rid())
	rs.instance_set_scenario(rid, _scenario)
	rs.instance_set_transform(rid, Transform3D(Basis.IDENTITY, centroid))

	# Material routing: MultiMesh renders with the mesh's baked-in surface
	# materials automatically. Only apply a whole-mesh override when the
	# prototype had one — per-surface override isn't supported on MULTIMESH-
	# backed instances (instance->materials is unallocated for MM).
	if sub.material_rid.is_valid():
		rs.instance_geometry_set_material_override(rid, sub.material_rid)

	# visibility_range is evaluated against the RS instance origin (= centroid),
	# so the batch fades out at the same distance a per-cell single instance
	# would. FADE_SELF + 20m margin matches the individual path's dither.
	rs.instance_geometry_set_visibility_range(
		rid,
		0.0, visibility_range_end,
		0.0, DU.FADE_MARGIN_LOD3_FAR,
		RenderingServer.VISIBILITY_RANGE_FADE_SELF
	)
	rs.instance_geometry_set_lod_bias(rid, 1.0)

	if not _globally_visible:
		rs.instance_set_visible(rid, false)

	var batch := CellBatch.new()
	batch.type_name = type_name
	batch.cell_grid = cell_grid
	batch.rs_instance = rid
	batch.multimesh = mm
	batch.multimesh_rid = mm.get_rid()
	batch.centroid = centroid
	batch.slot_count = live_ids.size()
	batch.instance_ids = []
	batch.instance_ids.resize(live_ids.size())

	# Retire the per-instance RS RIDs, keeping InstanceData alive so promotion /
	# visibility / removal can still address the object via its batch slot.
	for i in range(live_ids.size()):
		var data: InstanceData = _instances[live_ids[i]]
		for r: RID in data.sub_rids:
			if r.is_valid():
				rs.free_rid(r)
		data.sub_rids.clear()
		data.instance_rid = RID()
		data.mm_slot = i
		data.batch = batch
		batch.instance_ids[i] = live_ids[i]

	return batch


## Hide a batch slot by collapsing its transform to a zero-scale placeholder
## (degenerate triangles, ~free on GPU). Used by visibility / promotion.
func _hide_batch_slot(batch: CellBatch, slot: int, origin: Vector3) -> void:
	if batch.multimesh == null or slot < 0 or slot >= batch.slot_count:
		return
	var hidden := Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), origin - batch.centroid)
	batch.multimesh.set_instance_transform(slot, hidden)


## Restore a batch slot to its live world transform. Used on demotion / unhide.
func _show_batch_slot(batch: CellBatch, slot: int, world_xform: Transform3D) -> void:
	if batch.multimesh == null or slot < 0 or slot >= batch.slot_count:
		return
	var inv_anchor := Transform3D(Basis.IDENTITY, -batch.centroid)
	batch.multimesh.set_instance_transform(slot, inv_anchor * world_xform)


## Free every batch belonging to a cell (frees RS instances, drops MultiMesh refs).
## Called by remove_cell_instances + clear.
func _free_cell_batches(cell_grid: Vector2i) -> void:
	if cell_grid not in _cell_batches:
		return
	var rs := RenderingServer
	for batch: CellBatch in _cell_batches[cell_grid]:
		if batch.rs_instance.is_valid():
			rs.free_rid(batch.rs_instance)
			batch.rs_instance = RID()
		batch.multimesh = null
		batch.multimesh_rid = RID()
	_cell_batches.erase(cell_grid)

#endregion


#region Visibility & Transform

## Set instance visibility — routes through MultiMesh slot when batched,
## per-RS-instance otherwise.
func set_instance_visible(id: int, visible: bool) -> void:
	if id not in _instances:
		return

	var data: InstanceData = _instances[id]
	if data.visible == visible:
		return

	data.visible = visible

	if data.registry_id >= 0 and _prototype_registry != null:
		if visible:
			_prototype_registry.show_instance(data.registry_id, data.transform)
		else:
			_prototype_registry.hide_instance(data.registry_id)
	elif data.mm_slot >= 0 and data.batch != null:
		if visible:
			_show_batch_slot(data.batch, data.mm_slot, data.transform * _sub_local(data))
		else:
			_hide_batch_slot(data.batch, data.mm_slot, data.transform.origin)
	else:
		for rid: RID in data.sub_rids:
			if rid.is_valid():
				RenderingServer.instance_set_visible(rid, visible)

	if visible:
		_stats["visible_instances"] += 1
	else:
		_stats["visible_instances"] -= 1


## Helper — return the single sub_mesh local transform for a batched instance's
## type (batched types are guaranteed single-sub-mesh by batch_cell_into_multimesh).
func _sub_local(data: InstanceData) -> Transform3D:
	var mt: MeshType = _mesh_types.get(data.type_name)
	if mt and not mt.sub_meshes.is_empty():
		return mt.sub_meshes[0].local_transform
	return Transform3D.IDENTITY


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

	if data.registry_id >= 0 and _prototype_registry != null:
		if is_promoted:
			_prototype_registry.hide_instance(data.registry_id)
		else:
			_prototype_registry.show_instance(data.registry_id, data.transform)
	elif data.mm_slot >= 0 and data.batch != null:
		if is_promoted:
			# NEAR Node3D takes over; collapse MultiMesh slot to degenerate triangles.
			_hide_batch_slot(data.batch, data.mm_slot, data.transform.origin)
		else:
			_show_batch_slot(data.batch, data.mm_slot, data.transform * _sub_local(data))
	else:
		for rid: RID in data.sub_rids:
			if rid.is_valid():
				RenderingServer.instance_set_visible(rid, not is_promoted)


## Set instance transform (updates all sub-mesh RS instances or MultiMesh slot)
func set_instance_transform(id: int, transform: Transform3D) -> void:
	if id not in _instances:
		return

	var data: InstanceData = _instances[id]
	data.transform = transform

	if data.registry_id >= 0 and _prototype_registry != null:
		# Skip writing live transform to the registry while the instance is
		# hidden/promoted — the registry hide path zero-scaled the slots;
		# restoring them here would resurrect a promoted object.
		if data.visible and not data.promoted:
			_prototype_registry.set_instance_transform(data.registry_id, transform)
		return

	if data.mm_slot >= 0 and data.batch != null:
		# Only write the live transform if the slot isn't currently hidden —
		# otherwise we'd resurrect a promoted/hidden slot.
		if data.visible and not data.promoted:
			_show_batch_slot(data.batch, data.mm_slot, transform * _sub_local(data))
		return

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
## Toggle visibility of ALL RS instances (for benchmark A/B testing).
## Operates directly on RS instances since they are not in the Node3D tree.
func set_all_visible(visible: bool) -> void:
	_globally_visible = visible
	# Per-cell batch RS instances — one toggle covers all slots.
	for cell_grid: Vector2i in _cell_batches:
		for batch: CellBatch in _cell_batches[cell_grid]:
			if batch.rs_instance.is_valid():
				RenderingServer.instance_set_visible(batch.rs_instance, visible)
	for id: int in _instances:
		var data: InstanceData = _instances[id]
		if data.registry_id >= 0 and _prototype_registry != null:
			if visible:
				_prototype_registry.show_instance(data.registry_id, data.transform)
			else:
				_prototype_registry.hide_instance(data.registry_id)
		elif data.mm_slot < 0:
			for rid: RID in data.sub_rids:
				if rid.is_valid():
					RenderingServer.instance_set_visible(rid, visible)
		data.visible = visible
	_stats["visible_instances"] = _instances.size() if visible else 0


func clear(clear_mesh_types: bool = true) -> void:
	var rs := RenderingServer

	# Free per-cell batch RS instances (MultiMesh resources drop with the batch).
	for cell_grid: Vector2i in _cell_batches:
		for batch: CellBatch in _cell_batches[cell_grid]:
			if batch.rs_instance.is_valid():
				rs.free_rid(batch.rs_instance)
				batch.rs_instance = RID()
			batch.multimesh = null
			batch.multimesh_rid = RID()
	_cell_batches.clear()

	# Tear down the registry first — it owns its own RS instances + MultiMeshes.
	if _prototype_registry != null:
		_prototype_registry.cleanup()
		_prototype_registry = null

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

## Get statistics, including MultiMesh batch breakdown.
##
## Extra fields:
##   `mm_batches`   — number of active CellBatch instances (= one RS draw each)
##   `mm_slots`     — total MultiMesh slots across all batches
##   `mm_cells`     — cells that have at least one batch
func get_stats() -> Dictionary:
	var result: Dictionary = _stats.duplicate()
	var mm_batches := 0
	var mm_slots := 0
	for cell_grid: Vector2i in _cell_batches:
		for batch: CellBatch in _cell_batches[cell_grid]:
			mm_batches += 1
			mm_slots += batch.slot_count
	result["mm_batches"] = mm_batches
	result["mm_slots"] = mm_slots
	result["mm_cells"] = _cell_batches.size()

	# Registry (Phase 3) stats — zero when flag OFF.
	result["registry_enabled"] = use_prototype_registry
	if _prototype_registry != null:
		result["registry_batches"] = _prototype_registry.get_batch_count()
		result["registry_slots"] = _prototype_registry.get_total_live_slots()
	else:
		result["registry_batches"] = 0
		result["registry_slots"] = 0
	return result


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


## Get the union AABB for a registered mesh type.
## Used by the object-paging projected-size filter (plan §2.2) — the bounding
## radius drives the `radius² × scale² < dist² × minSize²` rejection test.
## Returns AABB() if the type is not registered (caller skips the ref safely).
func get_mesh_aabb(type_name: String) -> AABB:
	if type_name not in _mesh_types:
		return AABB()
	return _mesh_types[type_name].aabb


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


## Get sub-mesh entries for a registered type (used by ObjectPaging).
## Returns empty array if type not registered.
func get_sub_meshes(type_name: String) -> Array[SubMeshEntry]:
	if type_name not in _mesh_types:
		return []
	return _mesh_types[type_name].sub_meshes

#endregion
