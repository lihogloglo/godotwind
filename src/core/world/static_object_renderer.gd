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
## The instance carries a single hard-cull `visibility_range` at MID_END for the
## MID->HLOD tier handoff; sub-LOD selection is fully engine-driven.
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
const SC := preload("res://src/core/world/streaming_config.gd")
const PrototypeRegistryScript := preload("res://src/core/world/prototype_registry.gd")
const PrototypeBatchScript := preload("res://src/core/world/prototype_batch.gd")
const CellStaticBucketScript := preload("res://src/core/world/cell_static_bucket.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const EXTERIOR_RENDER_LAYER_MASK := 1

## Parked legacy PrototypeRegistry path. It is world-scoped, which is the wrong
## shape for a large open world because one MultiMesh is spatially indexed as
## one object. Keep USE_PROTOTYPE_REGISTRY false unless this is rewritten into
## spatially local buckets per the streaming/rendering bible.
var _prototype_registry: RefCounted = null

## Registered mesh types: type_name -> MeshType
var _mesh_types: Dictionary[String, MeshType] = {}

## Phase E — guards _mesh_types against concurrent read (worker via
## precompute_instance) + write (main via register_from_prototype / clear).
## Godot Dictionary is NOT thread-safe for concurrent mutation — docs list it
## as "thread-safe in read-only mode" only. Without this lock, a rehash
## triggered by insertion on main could corrupt a worker read of an unrelated
## existing key. Builder review 2026-04-21 flagged this as BLOCKER 2.
##
## Hold-time discipline: minimum critical section — build new MeshType
## structs locally on main, grab the lock only for the dict insert. Worker
## readers grab the lock, copy out the MeshType reference, release before
## touching its fields (which are never re-mutated after insertion).
var _mesh_types_mutex: Mutex = Mutex.new()

## All instances: instance_id -> InstanceData
var _instances: Dictionary[int, InstanceData] = {}

## Spatial index: cell_grid Vector2i -> Array[int] of instance IDs
## Enables O(cell_count) lookups instead of O(total_instances) for promotion/removal
var _cell_index: Dictionary[Vector2i, Array] = {} # Array[int]

## Phase 2B near-streaming path: renderer-indexed per-cell/payload buckets.
## CellStaticBucket owns its RS instances, local MultiMeshes, and the strong
## Mesh/Material/handle refs behind those RIDs. `_mesh_types` is only the
## prototype lookup source used at bucket creation time.
var _cell_buckets: Dictionary[Vector2i, Array] = {} # Array[CellStaticBucket]
var _cell_bucket_hide_progress: Dictionary[Vector2i, int] = {}
var _cell_bucket_key_index: Dictionary[String, RefCounted] = {}
var _cell_bucket_pending_cleanup: Dictionary[String, bool] = {}
var _cell_bucket_build_tasks: Dictionary[String, RefCounted] = {}
var _hlod_covered_bucket_counts: Dictionary[String, int] = {}
var _hlod_bucket_visibility_end: float = DU.HLOD_START
var _descriptor_build_tasks: Dictionary[String, DescriptorBuildTask] = {}

## Render-only proxy handoff: source_key -> direct instance ID. This is for
## stateful refs that need a cheap visual at distance and a full gameplay actor
## near the player. Bucketed MultiMeshes are intentionally not used here because
## they cannot punch out one source ref when that actor promotes or dirties.
var _visual_proxy_by_source: Dictionary[String, int] = {}
var _visual_proxy_dirty_reason: Dictionary[String, String] = {}
var _visual_proxy_suppressed: Dictionary[String, bool] = {}

## Phase 3 registry fade duration (seconds). Matches Phase 2's NEAR fade
## default — see lod_crossfade.gdshader. The shader reads this per-slot via
## INSTANCE_CUSTOM.y so it could be tuned per-instance in the future; today
## every slot uses this single value.
const REGISTRY_FADE_DURATION_S: float = 0.3
const DESCRIPTOR_BUILD_BUDGET_USEC: int = 1000
## Safety gate for the parked world-scoped PrototypeRegistry/MultiMesh path.
## The active static path is the per-cell CellStaticBucket path above. Re-enable
## only after replacing the registry with spatially local buckets and re-running
## the bible's MID/HLOD/FAR verification gates.
const USE_PROTOTYPE_REGISTRY: bool = false


## Next instance ID
var _next_id: int = 0

## World scenario RID (set when entering tree)
var _scenario: RID = RID()

## Maximum visibility range for individual MID instances.
## Default: MID_END (300m). HLOD owns the next fixed tier, 300-1000m.
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
	"cell_buckets": 0,
	"bucket_instances": 0,
	"bucket_draw_groups": 0,
	"bucket_rs_instances": 0,
	"hlod_bucket_overrides": 0,
	"hlod_bucket_override_refs": 0,
	"visual_proxy_instances": 0,
	"visual_proxy_dirty": 0,
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
	var surface_materials: Array[Material] = []  ## Per-surface mats (strong refs)
	var local_transform: Transform3D  ## Child's transform relative to prototype root
	var has_lod_chain: bool = false


## Mesh type registration data
class MeshType:
	var name: String
	var mesh_rid: RID          ## Owned/generated or legacy cached RID; descriptor paths derive from mesh_resource
	var material_rid: RID      ## Owned/generated or legacy cached RID; descriptor paths derive from material_resource
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


## Validated static prototype data extracted before publishing to _mesh_types.
## The descriptor owns Resource refs only. RIDs are derived later at the actual
## RS instance publish point so static prepare cannot create server state.
class StaticPrototypeDescriptor:
	var sub_meshes: Array[SubMeshEntry] = []
	var aabb: AABB
	var has_lod_chain: bool = false


class DescriptorBuildTask:
	var type_name: String = ""
	var packed_scene: PackedScene = null
	var state: SceneState = null
	var node_index: int = 0
	var xforms: Dictionary[String, Transform3D] = {".": Transform3D.IDENTITY}
	var descriptor: StaticPrototypeDescriptor = null
	var failed: bool = false
	var done: bool = false


## Phase E — precomputed instance data produced off-thread.
##
## The worker fills every field of this struct using thread-safe reads only
## (`_mesh_types[type_name]` + pure math via `CS.*` static functions). The
## main-thread drain then publishes the struct via `add_instance_precomputed`
## which does the MultiMesh buffer writes + dict bookkeeping that can't run
## off-thread (per research doc §2.1 — MultiMesh.set_instance_transform is
## main-thread-only).
##
## Lifetime contract: allocated on worker, written by worker (every field
## set), read by main thread ONLY after WorkerThreadPool.is_task_completed
## returns true. Same implicit-mutex pattern as Phase A's `worker_instance`.
##
## Plan: docs/plans/distant_rendering_2026_04/phase_e_static_bulk_upload.md §3.1
class PrecomputedInstance:
	var type_name: String                             ## Lowercased normalized model path
	var world_transform: Transform3D                  ## Full world-space xform (world)
	var sub_mesh_combined_xforms: Array[Transform3D] = []  ## world * sub.local_transform, per sub-mesh
	var custom_data: Color                            ## (spawn_time, fade_duration, 0, 0) for the shader
	var aabb: AABB                                    ## Union AABB (copied from MeshType)
	var cell_grid: Vector2i
	var model_path: String
	var item_id: String
	var ref_id: StringName
	var ref_num: int


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
	## Parked PrototypeRegistry routing. When >= 0, this instance's slots live
	## inside the legacy world-scoped registry. The active cell-bucket path does
	## not allocate InstanceData for every static draw; these fields remain for
	## legacy add_instance/debug-tool compatibility.
	var registry_id: int = -1
	## Metadata for MID→NEAR promotion (Phase 5b)
	var model_path: String     ## Original model path for prototype lookup
	var item_id: String        ## Item variant ID
	var ref_id: StringName     ## ESM reference ID (e.g., "barrel_01")
	var ref_num: int           ## ESM unique reference number
	var source_key: String = "" ## Stable placed-reference key for proxy handoff.
	var visual_proxy: bool = false


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
	# Fast-path check under lock — prevents duplicate-register if two callers
	# race (rare, but cheap to close).
	_mesh_types_mutex.lock()
	var already := type_name in _mesh_types
	_mesh_types_mutex.unlock()
	if already:
		return

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

	# Publish atomically. Re-check inside the lock in case another main-thread
	# caller (tests, debug paths) registered while we were building.
	_mesh_types_mutex.lock()
	if type_name not in _mesh_types:
		_mesh_types[type_name] = mesh_type
		_stats["mesh_types"] += 1
	_mesh_types_mutex.unlock()


## Register a mesh type from a Node3D prototype.
##
## Post-B-wide: walks ALL visible MeshInstance3D children in the prototype tree
## and stores each as a SubMeshEntry. Multi-mesh buildings (3-8 children) get
## one RS instance per child at add_instance time, all tracked under one ID.
## Single-mesh prototypes (flora, small clutter) work exactly as before.
func register_from_prototype(type_name: String, prototype: Node3D) -> void:
	# Fast-path check under lock — prevents worker tearing on a rehash mid-
	# register. Releasing the lock before the expensive build is safe because
	# we re-check under lock before final insert.
	_mesh_types_mutex.lock()
	var already := type_name in _mesh_types
	_mesh_types_mutex.unlock()
	if already:
		return

	var all_mis := _find_all_mesh_instances(prototype)
	if all_mis.is_empty():
		push_warning("StaticObjectRenderer: No mesh found in prototype for '%s'" % type_name)
		return

	var descriptor := StaticPrototypeDescriptor.new()

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
			descriptor.has_lod_chain = true

		# Material resolution: override > surface override > mesh surface
		if mi.material_override:
			entry.material_resource = mi.material_override
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
				entry.surface_materials.clear()

		# Expand union AABB
		var child_aabb := mi.mesh.get_aabb()
		var transformed_aabb := entry.local_transform * child_aabb
		if descriptor.sub_meshes.is_empty():
			descriptor.aabb = transformed_aabb
		else:
			descriptor.aabb = descriptor.aabb.merge(transformed_aabb)

		descriptor.sub_meshes.append(entry)

	if descriptor.sub_meshes.is_empty():
		# All mesh instances were filtered out (no mesh on any MI). Defensive
		# — _find_all_mesh_instances already pre-filters, but be safe.
		return

	_publish_static_descriptor(type_name, descriptor)


## Compatibility alias — post-B-wide there's no difference between the two
## registration paths. Kept so existing callers (cell_manager.gd, test scenes)
## continue to work without edits until they're cleaned up in Phase F.
## Register a mesh type directly from PackedScene metadata without instantiating
## a Node3D tree. This is the preferred streaming prepare path: SceneState gives
## us MeshInstance3D meshes, transforms, visibility, and material overrides
## without paying PackedScene.instantiate().
func register_from_packed_scene(type_name: String, packed_scene: PackedScene) -> bool:
	_mesh_types_mutex.lock()
	var already := type_name in _mesh_types
	_mesh_types_mutex.unlock()
	if already:
		return true
	if packed_scene == null:
		return false

	var descriptor := _build_descriptor_from_packed_scene(packed_scene)
	if descriptor == null or descriptor.sub_meshes.is_empty():
		return false

	_publish_static_descriptor(type_name, descriptor)
	return true


func request_register_from_packed_scene(type_name: String, packed_scene: PackedScene) -> String:
	_mesh_types_mutex.lock()
	var already := type_name in _mesh_types
	_mesh_types_mutex.unlock()
	if already:
		return "ready"
	if type_name.is_empty() or packed_scene == null:
		return "failed"

	if type_name in _descriptor_build_tasks:
		var existing: DescriptorBuildTask = _descriptor_build_tasks[type_name]
		_process_descriptor_build_slice(existing)
		if not existing.done:
			return "pending"
		_descriptor_build_tasks.erase(type_name)
		if existing.failed or existing.descriptor == null or existing.descriptor.sub_meshes.is_empty():
			return "failed"
		_publish_static_descriptor(type_name, existing.descriptor)
		return "ready"

	var task := DescriptorBuildTask.new()
	task.type_name = type_name
	task.packed_scene = packed_scene
	task.state = packed_scene.get_state()
	task.descriptor = StaticPrototypeDescriptor.new()
	if task.state == null:
		task.failed = true
		task.done = true
		return "failed"
	_process_descriptor_build_slice(task)
	if task.done:
		if task.failed or task.descriptor == null or task.descriptor.sub_meshes.is_empty():
			return "failed"
		_publish_static_descriptor(type_name, task.descriptor)
		return "ready"
	_descriptor_build_tasks[type_name] = task
	return "pending"


func _process_descriptor_build_slice(task: DescriptorBuildTask) -> void:
	if task == null or task.done:
		return
	if task.state == null or task.descriptor == null:
		task.failed = true
		task.done = true
		return

	var start_usec := Time.get_ticks_usec()
	var node_count := task.state.get_node_count()
	while task.node_index < node_count:
		_append_descriptor_node(task, task.node_index)
		task.node_index += 1
		if Time.get_ticks_usec() - start_usec >= DESCRIPTOR_BUILD_BUDGET_USEC:
			return

	task.failed = task.descriptor.sub_meshes.is_empty()
	task.done = true


func _append_descriptor_node(task: DescriptorBuildTask, node_index: int) -> void:
	var state := task.state
	var descriptor := task.descriptor
	var path := str(state.get_node_path(node_index, false))
	var parent_path := str(state.get_node_path(node_index, true))
	var local_xform := Transform3D.IDENTITY
	var visible := true
	var mesh: Mesh = null
	var material_override: Material = null
	var surface_overrides: Dictionary[int, Material] = {}

	for property_index in range(state.get_node_property_count(node_index)):
		var prop_name := str(state.get_node_property_name(node_index, property_index))
		var prop_value: Variant = state.get_node_property_value(node_index, property_index)
		match prop_name:
			"transform":
				if prop_value is Transform3D:
					local_xform = prop_value
			"visible":
				visible = bool(prop_value)
			"mesh":
				mesh = prop_value as Mesh
			"material_override":
				material_override = prop_value as Material
			_:
				if prop_name.begins_with("surface_material_override/"):
					var idx_text := prop_name.get_slice("/", 1)
					if idx_text.is_valid_int():
						var mat := prop_value as Material
						if mat != null:
							surface_overrides[int(idx_text)] = mat

	var parent_xform: Transform3D = task.xforms.get(parent_path, Transform3D.IDENTITY)
	var rel_xform: Transform3D = parent_xform * local_xform
	task.xforms[path] = rel_xform

	if state.get_node_type(node_index) != &"MeshInstance3D" or mesh == null or not visible:
		return

	var entry := SubMeshEntry.new()
	entry.mesh_resource = mesh
	entry.local_transform = rel_xform
	entry.has_lod_chain = mesh.has_meta("has_lod_chain") if mesh is ArrayMesh else false
	if entry.has_lod_chain:
		descriptor.has_lod_chain = true

	if material_override != null:
		entry.material_resource = material_override
	elif not surface_overrides.is_empty():
		var surface_count := mesh.get_surface_count()
		if surface_count == 1 and surface_overrides.has(0):
			entry.material_resource = surface_overrides[0]
		else:
			entry.surface_materials.resize(surface_count)
			for surface_key: Variant in surface_overrides.keys():
				var surface_index := int(surface_key)
				if surface_index >= 0 and surface_index < surface_count:
					entry.surface_materials[surface_index] = surface_overrides[surface_index]

	var transformed_aabb := entry.local_transform * mesh.get_aabb()
	if descriptor.sub_meshes.is_empty():
		descriptor.aabb = transformed_aabb
	else:
		descriptor.aabb = descriptor.aabb.merge(transformed_aabb)
	descriptor.sub_meshes.append(entry)


func _build_descriptor_from_packed_scene(packed_scene: PackedScene) -> StaticPrototypeDescriptor:
	if packed_scene == null:
		return null
	var state: SceneState = packed_scene.get_state()
	if state == null:
		return null

	var xforms: Dictionary[String, Transform3D] = {".": Transform3D.IDENTITY}
	var descriptor := StaticPrototypeDescriptor.new()

	for i in range(state.get_node_count()):
		var path := str(state.get_node_path(i, false))
		var parent_path := str(state.get_node_path(i, true))
		var local_xform := Transform3D.IDENTITY
		var visible := true
		var mesh: Mesh = null
		var material_override: Material = null
		var surface_overrides: Dictionary[int, Material] = {}

		for p in range(state.get_node_property_count(i)):
			var prop_name := str(state.get_node_property_name(i, p))
			var prop_value: Variant = state.get_node_property_value(i, p)
			match prop_name:
				"transform":
					if prop_value is Transform3D:
						local_xform = prop_value
				"visible":
					visible = bool(prop_value)
				"mesh":
					mesh = prop_value as Mesh
				"material_override":
					material_override = prop_value as Material
				_:
					if prop_name.begins_with("surface_material_override/"):
						var idx_text := prop_name.get_slice("/", 1)
						if idx_text.is_valid_int():
							var mat := prop_value as Material
							if mat != null:
								surface_overrides[int(idx_text)] = mat

		var parent_xform: Transform3D = xforms.get(parent_path, Transform3D.IDENTITY)
		var rel_xform: Transform3D = parent_xform * local_xform
		xforms[path] = rel_xform

		if state.get_node_type(i) != &"MeshInstance3D" or mesh == null or not visible:
			continue

		var entry := SubMeshEntry.new()
		entry.mesh_resource = mesh
		entry.local_transform = rel_xform
		entry.has_lod_chain = mesh.has_meta("has_lod_chain") if mesh is ArrayMesh else false
		if entry.has_lod_chain:
			descriptor.has_lod_chain = true

		if material_override != null:
			entry.material_resource = material_override
		elif not surface_overrides.is_empty():
			var surface_count := mesh.get_surface_count()
			if surface_count == 1 and surface_overrides.has(0):
				entry.material_resource = surface_overrides[0]
			else:
				entry.surface_materials.resize(surface_count)
				for surface_key: Variant in surface_overrides.keys():
					var surface_index := int(surface_key)
					if surface_index >= 0 and surface_index < surface_count:
						entry.surface_materials[surface_index] = surface_overrides[surface_index]

		var transformed_aabb := entry.local_transform * mesh.get_aabb()
		if descriptor.sub_meshes.is_empty():
			descriptor.aabb = transformed_aabb
		else:
			descriptor.aabb = descriptor.aabb.merge(transformed_aabb)
		descriptor.sub_meshes.append(entry)

	if descriptor.sub_meshes.is_empty():
		return null
	return descriptor


func _publish_static_descriptor(type_name: String, descriptor: StaticPrototypeDescriptor) -> void:
	if descriptor == null or descriptor.sub_meshes.is_empty():
		return

	_materialize_surface_material_meshes(descriptor)
	var first := descriptor.sub_meshes[0]
	var mesh_type := MeshType.new()
	mesh_type.name = type_name
	if first.mesh_resource:
		mesh_type.mesh_rid = RID()
		mesh_type.mesh_resource = first.mesh_resource
		mesh_type.owns_mesh = false
	else:
		mesh_type.mesh_rid = RenderingServer.mesh_create()
		mesh_type.owns_mesh = true
	if first.material_resource:
		mesh_type.material_rid = RID()
		mesh_type.material_resource = first.material_resource
		mesh_type.owns_material = false
	else:
		mesh_type.material_rid = RID()
		mesh_type.owns_material = false
	mesh_type.aabb = descriptor.aabb
	mesh_type.has_lod_chain = descriptor.has_lod_chain
	mesh_type.sub_meshes = descriptor.sub_meshes
	if not first.surface_materials.is_empty():
		mesh_type.surface_materials = first.surface_materials

	_mesh_types_mutex.lock()
	if type_name not in _mesh_types:
		_mesh_types[type_name] = mesh_type
		_stats["mesh_types"] += 1
	_mesh_types_mutex.unlock()


func _materialize_surface_material_meshes(descriptor: StaticPrototypeDescriptor) -> void:
	for sub_mesh_value: Variant in descriptor.sub_meshes:
		var entry: SubMeshEntry = sub_mesh_value as SubMeshEntry
		if entry == null or entry.mesh_resource == null or entry.surface_materials.is_empty():
			continue
		var source_mesh := entry.mesh_resource
		if not source_mesh is ArrayMesh:
			continue
		var material_count := mini(entry.surface_materials.size(), source_mesh.get_surface_count())
		var has_surface_material := false
		for surface_index in range(material_count):
			if entry.surface_materials[surface_index] != null:
				has_surface_material = true
				break
		if not has_surface_material:
			entry.surface_materials.clear()
			continue
		var mesh_copy := _copy_array_mesh_with_surface_materials(source_mesh as ArrayMesh, entry.surface_materials, entry.has_lod_chain)
		if mesh_copy == null:
			continue
		entry.mesh_resource = mesh_copy
		entry.surface_materials.clear()


func _copy_array_mesh_with_surface_materials(source_mesh: ArrayMesh, surface_materials: Array[Material], generate_lod_chain: bool) -> ArrayMesh:
	var importer := ImporterMesh.new()
	for surface_index in range(source_mesh.get_surface_count()):
		var arrays := source_mesh.surface_get_arrays(surface_index)
		if arrays.is_empty():
			continue
		var material: Material = null
		if surface_index < surface_materials.size() and surface_materials[surface_index] != null:
			material = surface_materials[surface_index]
		else:
			material = source_mesh.surface_get_material(surface_index)
		importer.add_surface(
			source_mesh.surface_get_primitive_type(surface_index),
			arrays,
			source_mesh.surface_get_blend_shape_arrays(surface_index),
			{},
			material
		)
	if generate_lod_chain:
		importer.generate_lods(60.0, 25.0, [])
	var mesh_copy: ArrayMesh = importer.get_mesh()
	if mesh_copy != null and mesh_copy.get_surface_count() > 0:
		for meta_key: StringName in source_mesh.get_meta_list():
			mesh_copy.set_meta(meta_key, source_mesh.get_meta(meta_key))
		if generate_lod_chain:
			mesh_copy.set_meta("has_lod_chain", true)
		return mesh_copy
	return null


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

## Per-frame cull tick. Returns the visible slot total, or -1 when the
## registry skipped the tick (camera didn't move + nothing dirty), or 0
## when the registry hasn't been instantiated yet.
##
## Driver: native_streaming_manager._process. Passes current camera position
## and the active max-visible-distance squared (visibility_range_end²).
func tick_prototype_cull(cam_pos: Vector3, max_dist_sq: float, batch_budget: int = 0) -> int:
	if not USE_PROTOTYPE_REGISTRY:
		return 0
	if _prototype_registry == null:
		return 0
	# When invisible: only run if dirty (flushes hide_instance zero-scale transforms to GPU).
	# Skip movement-driven re-culls entirely — no per-frame cost while MID is off.
	if not _globally_visible and not _prototype_registry.is_cull_dirty():
		return 0
	return _prototype_registry.tick_cull_if_needed(cam_pos, max_dist_sq, batch_budget)


## Pause registry MultiMesh uploads for a few frames around unload membership
## churn. This keeps set_buffer away from the same frame as hide/release work.
func defer_prototype_uploads(frames: int) -> void:
	if _prototype_registry == null:
		return
	if _prototype_registry.has_method("defer_uploads"):
		_prototype_registry.call("defer_uploads", frames)


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


## Phase E — worker-safe precompute for the STAT off-thread path.
##
## Runs on WorkerThreadPool (called by cell_manager's dispatch pass). Reads
## `_mesh_types[type_name]` which is set-once by `register_from_prototype` on
## the main thread; the dispatcher gate (§3.3) ensures this entry is fully
## published before the worker runs. No writes to any shared state.
##
## Returns null if:
##   - type_name is not registered (caller must fall back to sync path to
##     trigger cold register_from_prototype — this helper never does the cold
##     register since that walks a scene tree, main-thread only)
##   - `_scenario.is_valid()` is false (pre-enter-tree — should never happen
##     since dispatcher gates also check registration state)
##
## Non-null return means the caller can route to `add_instance_precomputed`.
##
## Thread-safety:
##   - `_mesh_types` read: dict access, Godot Dictionary reads on a dict
##     whose layout is stable are safe (no concurrent writer, see §8 of the
##     plan). Gate in dispatcher blocks cold register race.
##   - `CS.vector_to_godot/scale_to_godot/esm_rotation_to_godot_basis`: all
##     static functions on CoordinateSystem, pure math (line 88/141/216 of
##     coordinate_system.gd). No shared state.
##   - `Transform3D` / `Basis` / `Vector3` constructors: thread-safe math.
##   - `Time.get_ticks_msec()`: thread-safe.
##
## Plan: phase_e_static_bulk_upload.md §3.2, §5 ops audit
# PHASE_E:WORKER_SAFE
func precompute_instance(
	type_name: String,
	ref: CellReference,
	cell_grid: Vector2i,
) -> PrecomputedInstance:
	# Short critical section: grab the MeshType reference under lock, release
	# immediately. MeshType fields (sub_meshes, aabb, etc.) are frozen after
	# register_from_prototype's atomic publish, so reading them outside the
	# lock is safe. _scenario is set-once in _enter_tree + never reassigned —
	# no lock needed.
	_mesh_types_mutex.lock()
	if type_name not in _mesh_types:
		_mesh_types_mutex.unlock()
		return null
	var mesh_type: MeshType = _mesh_types[type_name]
	_mesh_types_mutex.unlock()
	if not _scenario.is_valid():
		return null

	# Transform math (mirrors _instantiate_static_object lines 640-644).
	var pos := CS.vector_to_godot(ref.position)
	var scale := CS.scale_to_godot(ref.scale)
	var basis := CS.esm_rotation_to_godot_basis(ref.rotation)
	basis = basis.scaled(scale)
	var world_transform := Transform3D(basis, pos)

	# Sub-mesh world xforms — pre-multiply world * local. Saves the main-thread
	# portion of the hot loop in PrototypeRegistry.add_instance. Reg add expects
	# to compute `p_world_transform * local_xform` per sub-mesh; if we hand it
	# the combined xform directly (§3.5 `add_instance_precomputed`), it skips
	# that per-sub multiply. Cost moved off-thread: 3-5 Transform3D mults × N
	# sub-meshes per ref.
	var combined: Array[Transform3D] = []
	combined.resize(mesh_type.sub_meshes.size())
	for i in range(mesh_type.sub_meshes.size()):
		var entry: SubMeshEntry = mesh_type.sub_meshes[i]
		combined[i] = world_transform * entry.local_transform

	# Shader custom data — spawn time + fade duration for lod_crossfade_multimesh.
	var spawn_time: float = float(Time.get_ticks_msec()) / 1000.0
	var custom_data := Color(spawn_time, REGISTRY_FADE_DURATION_S, 0.0, 0.0)

	var precomp := PrecomputedInstance.new()
	precomp.type_name = type_name
	precomp.world_transform = world_transform
	precomp.sub_mesh_combined_xforms = combined
	precomp.custom_data = custom_data
	precomp.aabb = mesh_type.aabb
	precomp.cell_grid = cell_grid
	precomp.model_path = ""  # Caller fills in via ref.model_path if needed
	precomp.item_id = ""
	precomp.ref_id = StringName(str(ref.ref_id))
	precomp.ref_num = ref.ref_num
	return precomp


## Add an instance of a registered mesh type.
##
## Post-B-wide: single RS instance per object with a single hard-cull
## visibility_range at MID_END (MID->HLOD tier handoff). Sub-LOD selection
## is driven by the embedded `surface_lod_indices` chain + Godot's C++ screen-
## space LOD selector, not by manual distance bands.
##
## Returns instance ID for later manipulation, or -1 on failure.
# PHASE_E:MAIN_ONLY
func add_instance(type_name: String, transform: Transform3D, cell_grid: Vector2i = Vector2i.ZERO,
		model_path: String = "", item_id: String = "", ref_id: StringName = &"", ref_num: int = 0,
		source_key: String = "", visual_proxy: bool = false) -> int:
	# NOTE: no early-return on `_globally_visible`. Post-statics_no_node3d T.1
	# the renderer is the universal static-render path (NEAR + flora + rocks +
	# arch + clutter). Dropping spawns when invisible = losing statics that a
	# subsequent `set_all_visible(true)` can never recover. Hide-on-add is
	# handled below at the registry (line ~399) + legacy (line ~495) branches.

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
	data.source_key = source_key
	data.visual_proxy = visual_proxy

	# Phase 3 registry path. Always taken for prototypes registered via
	# register_from_prototype (which populates sub_meshes). The legacy
	# register_mesh_type direct path (no sub_meshes) falls through to the
	# RS-instance branch below — that's kept for debug tools / tests that
	# instantiate a Mesh resource directly without a Node3D prototype.
	if USE_PROTOTYPE_REGISTRY and not mesh_type.sub_meshes.is_empty():
		var registry := _ensure_registry()
		if registry != null:
			var subs: Array = _build_registry_sub_meshes(mesh_type)
			## spawn_time + fade_duration drive the shader crossfade (see
			## lod_crossfade_multimesh.gdshader). fade_duration is seconds,
			## not metres — DU.FADE_MARGIN_LOD3_FAR was the wrong constant.
			var spawn_time: float = float(Time.get_ticks_msec()) / 1000.0
			registry.add_instance(id, subs, transform, spawn_time, REGISTRY_FADE_DURATION_S)
			# Registry path mirror of the legacy-path `_globally_visible` check
			# (line 476). Without this, instances added via the registry after
			# `set_all_visible(false)` come back as visible MultiMesh slots —
			# the "groups of meshes appear when moving after toggle none" bug.
			if not _globally_visible:
				registry.hide_instance(id)
				data.visible = false
			data.registry_id = id
			_instances[id] = data
			mesh_type.instance_count += 1
			_stats["total_instances"] += 1
			if _globally_visible:
				_stats["visible_instances"] += 1
			if cell_grid not in _cell_index:
				_cell_index[cell_grid] = [] as Array[int]
			_cell_index[cell_grid].append(id)
			if visual_proxy and not source_key.is_empty():
				_visual_proxy_by_source[source_key] = id
				_stats["visual_proxy_instances"] = int(_stats.get("visual_proxy_instances", 0)) + 1
			return id

	# Legacy fallback: per-sub-mesh RS instance path for register_mesh_type
	# callers (no prototype sub_meshes). Rare in production, used mainly by
	# tests and low-level debug tools.
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
		var legacy_material_rid: RID = mesh_type.material_resource.get_rid() if mesh_type.material_resource \
			else mesh_type.material_rid
		var rid := _create_rs_instance(legacy_mesh_rid, legacy_material_rid,
			mesh_type.surface_materials, transform, mesh_type.aabb)
		if rid.is_valid():
			data.sub_rids.append(rid)
		data.instance_rid = rid
	else:
		for entry: SubMeshEntry in sub_entries:
			if entry.mesh_resource == null:
				continue
			var child_xform := transform * entry.local_transform
			var material_rid: RID = entry.material_resource.get_rid() if entry.material_resource else RID()
			var rid := _create_rs_instance(entry.mesh_resource.get_rid(), material_rid,
				entry.surface_materials, child_xform, entry.mesh_resource.get_aabb())
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
	if visual_proxy and not source_key.is_empty():
		_visual_proxy_by_source[source_key] = id
		_stats["visual_proxy_instances"] = int(_stats.get("visual_proxy_instances", 0)) + 1

	return id


## Add or return a direct render-only proxy for a stateful placed source ref.
## Uses per-instance RS state, not CellStaticBucket, so gameplay promotion can
## hide exactly one source ref without disturbing other refs sharing a model.
func add_visual_proxy(source_key: String, type_name: String, transform: Transform3D, cell_grid: Vector2i = Vector2i.ZERO,
		model_path: String = "", item_id: String = "", ref_id: StringName = &"", ref_num: int = 0) -> int:
	if source_key.is_empty() or source_key in _visual_proxy_dirty_reason:
		return -1
	var existing_id := int(_visual_proxy_by_source.get(source_key, -1))
	if existing_id in _instances:
		if not bool(_visual_proxy_suppressed.get(source_key, false)):
			set_instance_visible(existing_id, true)
		return existing_id

	var id := add_instance(type_name, transform, cell_grid, model_path, item_id, ref_id, ref_num, source_key, true)
	if id < 0:
		return -1
	if bool(_visual_proxy_suppressed.get(source_key, false)):
		set_instance_visible(id, false)
	return id


func suppress_proxy(source_key: String) -> void:
	if source_key.is_empty():
		return
	_visual_proxy_suppressed[source_key] = true
	var id := int(_visual_proxy_by_source.get(source_key, -1))
	if id in _instances:
		set_instance_visible(id, false)


func restore_proxy_if_clean(source_key: String) -> void:
	if source_key.is_empty():
		return
	_visual_proxy_suppressed.erase(source_key)
	if source_key in _visual_proxy_dirty_reason:
		return
	var id := int(_visual_proxy_by_source.get(source_key, -1))
	if id in _instances:
		set_instance_visible(id, true)


func mark_proxy_dirty(source_key: String, reason: String = "") -> void:
	if source_key.is_empty():
		return
	var was_clean := source_key not in _visual_proxy_dirty_reason
	_visual_proxy_dirty_reason[source_key] = reason
	if was_clean:
		_stats["visual_proxy_dirty"] = int(_stats.get("visual_proxy_dirty", 0)) + 1
	suppress_proxy(source_key)


func is_proxy_dirty(source_key: String) -> bool:
	return source_key in _visual_proxy_dirty_reason


## Phase E — main-thread consumer of a worker-prepared PrecomputedInstance.
##
## Mirrors the registry-path branch of `add_instance` (§3.5 of plan) but
## skips all the work that `precompute_instance` already did on the worker:
##   - transform math (pos, scale, basis, compose) — worker
##   - sub-mesh `world * local` composition — worker
##   - custom_data Color construction — worker
##
## Main-thread-bound work that remains:
##   - `_next_id` increment (shared counter)
##   - InstanceData struct population
##   - `PrototypeRegistry.add_instance_precombined` (MultiMesh slot acquire +
##     slot transform/custom_data writes — main-thread per research doc §2.1)
##   - `_instances` / `_cell_index` / `_stats` dict updates
##
## `precomp.model_path` + `precomp.item_id` carry the ref metadata for
## promotion/unload bookkeeping. Callers who have ref-level info they want
## stored beyond what precompute captured can set those fields on the struct
## before calling this.
##
## Returns the newly-allocated instance_id, or -1 if the type isn't registered
## or the scenario is invalid. The precompute helper already guards both but
## the race is closed here too — register can ONLY be completed on main
## thread, so the time between precompute and add is a window where a
## `clear(clear_mesh_types=true)` from somewhere else could drop the type.
##
## Plan: phase_e_static_bulk_upload.md §3.2, §5.1
## Phase 2B bucket publication. `_mesh_types` supplies immutable prototype
## descriptors; the returned CellStaticBucket owns the live resources/RIDs.
func create_cell_bucket(type_name: String, payload_key: String, transforms: Array, cell_grid: Vector2i, resource_handle: RefCounted = null) -> RefCounted:
	if payload_key.is_empty():
		return null
	var bucket_key := _make_cell_bucket_key(cell_grid, payload_key)
	if _cell_bucket_key_index.has(bucket_key) or _cell_bucket_build_tasks.has(bucket_key) or bool(_cell_bucket_pending_cleanup.get(bucket_key, false)):
		return null
	if type_name not in _mesh_types:
		return null
	if transforms.is_empty() or not _scenario.is_valid():
		return null

	var mesh_type: MeshType = _mesh_types[type_name]
	if mesh_type.sub_meshes.is_empty():
		return null

	var bucket: RefCounted = CellStaticBucketScript.new()
	var ok := bool(bucket.call(
		"configure",
		type_name,
		payload_key,
		cell_grid,
		mesh_type.sub_meshes,
		transforms,
		_scenario,
		_get_bucket_visibility_range_end(bucket_key, transforms.size()),
		_globally_visible,
		resource_handle
	))
	if not ok:
		if bucket.has_method("cleanup"):
			bucket.call("cleanup")
		return null

	_finalize_cell_bucket(bucket, type_name, payload_key, cell_grid)
	return bucket


func create_cell_bucket_budgeted(
	type_name: String,
	payload_key: String,
	transforms: Array,
	cell_grid: Vector2i,
	resource_handle: RefCounted,
	deadline_usec: int,
) -> Dictionary:
	if payload_key.is_empty():
		return {"status": "failed", "bucket": null}
	var bucket_key := _make_cell_bucket_key(cell_grid, payload_key)
	if _cell_bucket_key_index.has(bucket_key):
		return {"status": "ready", "bucket": _cell_bucket_key_index[bucket_key]}
	if bool(_cell_bucket_pending_cleanup.get(bucket_key, false)):
		return {"status": "failed", "bucket": null}
	if type_name not in _mesh_types:
		return {"status": "failed", "bucket": null}
	if transforms.is_empty() or not _scenario.is_valid():
		return {"status": "failed", "bucket": null}

	var mesh_type: MeshType = _mesh_types[type_name]
	if mesh_type.sub_meshes.is_empty():
		return {"status": "failed", "bucket": null}

	var bucket: RefCounted = _cell_bucket_build_tasks.get(bucket_key) as RefCounted
	if bucket == null:
		bucket = CellStaticBucketScript.new()
		var started := bool(bucket.call(
			"begin_configure",
			type_name,
			payload_key,
			cell_grid,
			mesh_type.sub_meshes,
			transforms,
			_scenario,
			_get_bucket_visibility_range_end(bucket_key, transforms.size()),
			_globally_visible,
			resource_handle
		))
		if not started:
			if bucket.has_method("cleanup"):
				bucket.call("cleanup")
			return {"status": "failed", "bucket": null}
		_cell_bucket_build_tasks[bucket_key] = bucket

	var status := str(bucket.call("configure_step", deadline_usec))
	if status == "pending":
		return {"status": "pending", "bucket": bucket}

	_cell_bucket_build_tasks.erase(bucket_key)
	if status != "ready":
		if bucket.has_method("cleanup"):
			bucket.call("cleanup")
		return {"status": "failed", "bucket": null}

	_finalize_cell_bucket(bucket, type_name, payload_key, cell_grid)
	return {"status": "ready", "bucket": bucket}


func _finalize_cell_bucket(bucket: RefCounted, type_name: String, _payload_key: String, cell_grid: Vector2i) -> void:
	if cell_grid not in _cell_buckets:
		_cell_buckets[cell_grid] = []
	_cell_buckets[cell_grid].append(bucket)
	var bucket_key := str(bucket.get("bucket_key"))
	_cell_bucket_key_index[bucket_key] = bucket
	_stats["cell_buckets"] = int(_stats.get("cell_buckets", 0)) + 1
	var bucket_count := int(bucket.get("instance_count"))
	_stats["bucket_instances"] = int(_stats.get("bucket_instances", 0)) + bucket_count
	var draw_group_count := int(bucket.call("get_draw_group_count")) if bucket.has_method("get_draw_group_count") else 0
	_stats["bucket_draw_groups"] = int(_stats.get("bucket_draw_groups", 0)) + draw_group_count
	_stats["bucket_rs_instances"] = int(_stats.get("bucket_rs_instances", 0)) + draw_group_count
	_stats["total_instances"] = int(_stats.get("total_instances", 0)) + bucket_count
	if _globally_visible:
		_stats["visible_instances"] = int(_stats.get("visible_instances", 0)) + bucket_count
	if type_name in _mesh_types:
		var mesh_type: MeshType = _mesh_types[type_name]
		mesh_type.instance_count += bucket_count


func set_visibility_range_end(p_visibility_range_end: float) -> void:
	visibility_range_end = p_visibility_range_end
	for buckets: Array in _cell_buckets.values():
		for bucket_value: Variant in buckets:
			var bucket: RefCounted = bucket_value as RefCounted
			if bucket != null and not bool(bucket.get("frozen")) and bucket.has_method("set_visibility_range_end"):
				var bucket_key := str(bucket.get("bucket_key"))
				var bucket_count := int(bucket.get("instance_count"))
				bucket.call("set_visibility_range_end", _get_bucket_visibility_range_end(bucket_key, bucket_count))


## Apply exact HLOD coverage to active MID buckets. Fully covered buckets cap at
## the HLOD handoff; partial/uncovered buckets keep the normal MID end.
func set_hlod_covered_bucket_counts(bucket_counts: Dictionary, covered_range_end: float = DU.HLOD_START) -> void:
	_hlod_covered_bucket_counts.clear()
	for key_value: Variant in bucket_counts.keys():
		var bucket_key := str(key_value)
		var count := int(bucket_counts[key_value])
		if count > 0:
			_hlod_covered_bucket_counts[bucket_key] = count
	_hlod_bucket_visibility_end = maxf(0.0, covered_range_end)
	_apply_bucket_visibility_ranges()


func _apply_bucket_visibility_ranges() -> void:
	for buckets: Array in _cell_buckets.values():
		for bucket_value: Variant in buckets:
			var bucket: RefCounted = bucket_value as RefCounted
			if bucket == null or bool(bucket.get("frozen")) or not bucket.has_method("set_visibility_range_end"):
				continue
			var bucket_key := str(bucket.get("bucket_key"))
			var bucket_count := int(bucket.get("instance_count"))
			var target_end := _get_bucket_visibility_range_end(bucket_key, bucket_count)
			bucket.call("set_visibility_range_end", target_end)
	_refresh_hlod_bucket_override_stats()


func _refresh_hlod_bucket_override_stats() -> void:
	var override_count := 0
	var override_refs := 0
	for buckets: Array in _cell_buckets.values():
		for bucket_value: Variant in buckets:
			var bucket: RefCounted = bucket_value as RefCounted
			if bucket == null or bool(bucket.get("frozen")):
				continue
			var bucket_key := str(bucket.get("bucket_key"))
			var bucket_count := int(bucket.get("instance_count"))
			if bucket_count > 0 and int(_hlod_covered_bucket_counts.get(bucket_key, 0)) >= bucket_count:
				override_count += 1
				override_refs += bucket_count
	_stats["hlod_bucket_overrides"] = override_count
	_stats["hlod_bucket_override_refs"] = override_refs


func _get_bucket_visibility_range_end(bucket_key: String, bucket_count: int) -> float:
	if bucket_count > 0 and int(_hlod_covered_bucket_counts.get(bucket_key, 0)) >= bucket_count:
		return minf(visibility_range_end, _hlod_bucket_visibility_end)
	return visibility_range_end


func _make_cell_bucket_key(cell_grid: Vector2i, payload_key: String) -> String:
	return "%d,%d:%s" % [cell_grid.x, cell_grid.y, payload_key]


# PHASE_E:MAIN_ONLY
func add_instance_precomputed(precomp: PrecomputedInstance) -> int:
	if precomp == null:
		return -1
	var type_name := precomp.type_name
	if type_name not in _mesh_types:
		return -1
	if not _scenario.is_valid():
		return -1

	var mesh_type: MeshType = _mesh_types[type_name]
	var id := _next_id
	_next_id += 1

	var data := InstanceData.new()
	data.id = id
	data.type_name = type_name
	data.transform = precomp.world_transform
	data.visible = true
	data.cell_grid = precomp.cell_grid
	data.model_path = precomp.model_path
	data.item_id = precomp.item_id
	data.ref_id = precomp.ref_id
	data.ref_num = precomp.ref_num

	# Registry path — always used for prototypes registered via
	# register_from_prototype. `sub_meshes` empty ⇒ mismatched registration
	# state (rare) ⇒ bail; legacy path wouldn't use precomputed data anyway.
	if USE_PROTOTYPE_REGISTRY and mesh_type.sub_meshes.is_empty():
		return -1

	# Build the registry input, feeding pre-combined world transforms (worker
	# already computed `world * local`). `local_transform` is still stored so
	# future set_instance_transform re-compositions work.
	if USE_PROTOTYPE_REGISTRY:
		var registry := _ensure_registry()
		if registry == null:
			return -1
		var subs: Array = []
		subs.resize(mesh_type.sub_meshes.size())
		for i in range(mesh_type.sub_meshes.size()):
			var entry: SubMeshEntry = mesh_type.sub_meshes[i]
			var world_xf: Transform3D = precomp.sub_mesh_combined_xforms[i] \
				if i < precomp.sub_mesh_combined_xforms.size() else precomp.world_transform
			subs[i] = {
				"mesh": entry.mesh_resource,
				"material": entry.material_resource,
				"world_transform": world_xf,
				"local_transform": entry.local_transform,
			}

		registry.add_instance_precombined(
			id, subs,
			precomp.custom_data.r,  # spawn_time packed into custom_data.r
			precomp.custom_data.g,  # fade_duration packed into custom_data.g
		)

		if not _globally_visible:
			registry.hide_instance(id)
			data.visible = false
		data.registry_id = id
	else:
		var sub_entries := mesh_type.sub_meshes
		if sub_entries.is_empty():
			var legacy_mesh_rid: RID = mesh_type.mesh_resource.get_rid() if mesh_type.mesh_resource \
				else mesh_type.mesh_rid
			var legacy_material_rid: RID = mesh_type.material_resource.get_rid() if mesh_type.material_resource \
				else mesh_type.material_rid
			var rid := _create_rs_instance(legacy_mesh_rid, legacy_material_rid,
				mesh_type.surface_materials, precomp.world_transform, mesh_type.aabb)
			if rid.is_valid():
				data.sub_rids.append(rid)
			data.instance_rid = rid
		else:
			for i in range(sub_entries.size()):
				var entry: SubMeshEntry = sub_entries[i]
				if entry.mesh_resource == null:
					continue
				var child_xform: Transform3D = precomp.sub_mesh_combined_xforms[i] \
					if i < precomp.sub_mesh_combined_xforms.size() \
					else precomp.world_transform * entry.local_transform
				var material_rid: RID = entry.material_resource.get_rid() if entry.material_resource else RID()
				var rid := _create_rs_instance(entry.mesh_resource.get_rid(), material_rid,
					entry.surface_materials, child_xform, entry.mesh_resource.get_aabb())
				if rid.is_valid():
					data.sub_rids.append(rid)
			if not data.sub_rids.is_empty():
				data.instance_rid = data.sub_rids[0]
		if not _globally_visible:
			for rid: RID in data.sub_rids:
				if rid.is_valid():
					RenderingServer.instance_set_visible(rid, false)
			data.visible = false
	_instances[id] = data
	mesh_type.instance_count += 1
	_stats["total_instances"] += 1
	if _globally_visible:
		_stats["visible_instances"] += 1
	if precomp.cell_grid not in _cell_index:
		_cell_index[precomp.cell_grid] = [] as Array[int]
	_cell_index[precomp.cell_grid].append(id)

	return id


## Create a single RS instance with visibility_range + LOD bias + material.
## Returns RID() on invalid mesh_rid — caller must guard against non-valid return.
##
## `aabb` is retained for legacy callers that still pass it for diagnostics.
## MID ownership itself must not screen-size-cull visible geometry before the
## tier handoff; embedded mesh LOD handles detail reduction.
func _create_rs_instance(mesh_rid: RID, material_rid: RID,
		surface_materials: Array[Material], xform: Transform3D,
		_aabb: AABB = AABB()) -> RID:
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
	rs.instance_set_layer_mask(instance_rid, EXTERIOR_RENDER_LAYER_MASK)
	rs.instance_set_transform(instance_rid, xform)

	# Apply material: prefer whole-mesh override, fall back to per-surface
	if material_rid.is_valid():
		rs.instance_geometry_set_material_override(instance_rid, material_rid)
	elif not surface_materials.is_empty():
		for si in range(surface_materials.size()):
			var mat: Material = surface_materials[si]
			if mat:
				rs.instance_set_surface_override_material(instance_rid, si, mat.get_rid())

	# MID is the safety fallback through its configured range. Small static
	# detail culling needs a coverage-aware replacement tier before it can ship.
	rs.instance_geometry_set_visibility_range(
		instance_rid,
		0.0, visibility_range_end,
		0.0, DU.FADE_MARGIN_LOD3_FAR,
		SC.MID_VISIBILITY_FADE_MODE
	)

	# Default LOD bias — tunable per type later via streaming_config.
	rs.instance_geometry_set_lod_bias(instance_rid, SC.DEFAULT_LOD_BIAS)
	rs.instance_geometry_set_cast_shadows_setting(
		instance_rid,
		_shadow_setting_for_aabb(_aabb)
	)

	if not _globally_visible:
		rs.instance_set_visible(instance_rid, false)

	return instance_rid


static func _shadow_setting_for_aabb(aabb: AABB) -> int:
	var max_dim := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	if max_dim < SC.MID_SHADOW_MIN_MESH_SIZE_M:
		return RenderingServer.SHADOW_CASTING_SETTING_OFF
	return RenderingServer.SHADOW_CASTING_SETTING_ON


## Remove an instance — frees per-instance RS RIDs for unbatched, or zero-scales
## the MultiMesh slot for batched (slot stays allocated to avoid reshuffling).
func remove_instance(id: int) -> void:
	if id not in _instances:
		return

	var data: InstanceData = _instances[id]
	if data.visual_proxy and not data.source_key.is_empty():
		_visual_proxy_by_source.erase(data.source_key)
		_visual_proxy_suppressed.erase(data.source_key)
		_stats["visual_proxy_instances"] = maxi(0, int(_stats.get("visual_proxy_instances", 0)) - 1)

	if data.registry_id >= 0 and _prototype_registry != null:
		# Registry owns the slots — release them back to the freelist. MultiMesh
		# + RS instance stay live (shared across all instances of the prototype).
		_prototype_registry.remove_instance(data.registry_id)
	else:
		# Legacy register_mesh_type path — free the per-sub-mesh RS RIDs.
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


## Remove all instances belonging to a cell. Uses spatial index for
## O(cell_size) instead of O(total_instances).
func remove_cell_instances(cell_grid: Vector2i) -> int:
	var removed := 0

	if cell_grid in _cell_index:
		var to_remove: Array = _cell_index[cell_grid].duplicate()
		for id: int in to_remove:
			remove_instance(id)
		removed += to_remove.size()

	var detached_buckets := _detach_cell_buckets(cell_grid)
	removed += _cleanup_detached_buckets(detached_buckets)

	return removed


func _detach_cell_buckets(cell_grid: Vector2i) -> Array:
	_cancel_bucket_builds_for_cell(cell_grid)
	if cell_grid not in _cell_buckets:
		_cell_bucket_hide_progress.erase(cell_grid)
		return []
	var buckets: Array = _cell_buckets[cell_grid]
	_cell_buckets.erase(cell_grid)
	_cell_bucket_hide_progress.erase(cell_grid)
	for bucket_value: Variant in buckets:
		var bucket: RefCounted = bucket_value as RefCounted
		if bucket == null:
			continue
		if bucket.has_method("freeze"):
			bucket.call("freeze")
		var bucket_key := str(bucket.get("bucket_key"))
		if not bucket_key.is_empty():
			_cell_bucket_key_index.erase(bucket_key)
			_cell_bucket_pending_cleanup[bucket_key] = true
	return buckets


func cancel_cell_bucket_build(bucket_key: String) -> void:
	if not _cell_bucket_build_tasks.has(bucket_key):
		return
	var bucket: RefCounted = _cell_bucket_build_tasks[bucket_key]
	_cell_bucket_build_tasks.erase(bucket_key)
	if bucket != null and bucket.has_method("cleanup"):
		bucket.call("cleanup")


func _cancel_bucket_builds_for_cell(cell_grid: Vector2i) -> void:
	var prefix := "%d,%d:" % [cell_grid.x, cell_grid.y]
	for key_value: Variant in _cell_bucket_build_tasks.keys():
		var bucket_key := str(key_value)
		if bucket_key.begins_with(prefix):
			cancel_cell_bucket_build(bucket_key)


func _cleanup_detached_buckets(buckets: Array) -> int:
	var removed := 0
	for bucket_value: Variant in buckets:
		var bucket: RefCounted = bucket_value as RefCounted
		if bucket == null:
			continue
		var count := int(bucket.get("instance_count"))
		var was_visible := bool(bucket.get("visible"))
		var bucket_type := str(bucket.get("type_name"))
		var bucket_key := str(bucket.get("bucket_key"))
		var draw_group_count := int(bucket.call("get_draw_group_count")) if bucket.has_method("get_draw_group_count") else 0
		if bucket.has_method("cleanup"):
			count = int(bucket.call("cleanup"))
		removed += count
		_stats["cell_buckets"] = maxi(0, int(_stats.get("cell_buckets", 0)) - 1)
		_stats["bucket_instances"] = maxi(0, int(_stats.get("bucket_instances", 0)) - count)
		_stats["bucket_draw_groups"] = maxi(0, int(_stats.get("bucket_draw_groups", 0)) - draw_group_count)
		_stats["bucket_rs_instances"] = maxi(0, int(_stats.get("bucket_rs_instances", 0)) - draw_group_count)
		_stats["total_instances"] = maxi(0, int(_stats.get("total_instances", 0)) - count)
		if was_visible:
			_stats["visible_instances"] = maxi(0, int(_stats.get("visible_instances", 0)) - count)
		if bucket_type in _mesh_types:
			var mesh_type: MeshType = _mesh_types[bucket_type]
			mesh_type.instance_count = maxi(0, mesh_type.instance_count - count)
		if not bucket_key.is_empty():
			_cell_bucket_pending_cleanup.erase(bucket_key)
	return removed


## Hide all instances belonging to a cell (fast — no GPU resource cleanup)
## Used for immediate visual removal before deferred free_rid() cleanup.
func hide_cell_instances(cell_grid: Vector2i) -> int:
	var count := 0
	if cell_grid in _cell_index:
		for id: int in _cell_index[cell_grid]:
			if id not in _instances:
				continue
			var data: InstanceData = _instances[id]
			if data.registry_id >= 0 and _prototype_registry != null:
				_prototype_registry.hide_instance(data.registry_id)
			else:
				for rid: RID in data.sub_rids:
					if rid.is_valid():
						RenderingServer.instance_set_visible(rid, false)
			data.visible = false
			count += 1

	if cell_grid in _cell_buckets:
		for bucket_value: Variant in _cell_buckets[cell_grid]:
			var bucket: RefCounted = bucket_value as RefCounted
			if bucket == null or bool(bucket.get("frozen")) or not bool(bucket.get("visible")):
				continue
			var bucket_count := int(bucket.get("instance_count"))
			if bucket.has_method("set_visible"):
				bucket.call("set_visible", false)
			_stats["visible_instances"] = maxi(0, int(_stats.get("visible_instances", 0)) - bucket_count)
			count += bucket_count

	return count


## Budgeted hide: hides up to `max_count` RS instances for a cell.
## Returns: [hidden_count, is_complete] — hidden_count is how many were hidden this call,
## is_complete is true when all instances in the cell have been hidden.
## Call repeatedly across frames until is_complete is true.
var _cell_hide_progress: Dictionary[Vector2i, int] = {}  # cell_grid -> index into _cell_index[grid]

func hide_cell_instances_budgeted(cell_grid: Vector2i, max_count: int) -> Array:
	if cell_grid not in _cell_index and cell_grid not in _cell_buckets:
		_cell_hide_progress.erase(cell_grid)
		_cell_bucket_hide_progress.erase(cell_grid)
		return [0, true]

	var cell_ids: Array = _cell_index.get(cell_grid, [])
	var start_idx: int = _cell_hide_progress.get(cell_grid, 0)
	var hidden := 0

	var i := start_idx
	while i < cell_ids.size() and hidden < max_count:
		var id: int = cell_ids[i]
		if id in _instances:
			var data: InstanceData = _instances[id]
			if data.visible:
				if data.registry_id >= 0 and _prototype_registry != null:
					_prototype_registry.hide_instance(data.registry_id)
				else:
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

	if is_complete and cell_grid in _cell_buckets:
		var buckets: Array = _cell_buckets[cell_grid]
		var bucket_start_idx: int = _cell_bucket_hide_progress.get(cell_grid, 0)
		var bi := bucket_start_idx
		while bi < buckets.size() and hidden < max_count:
			var bucket: RefCounted = buckets[bi] as RefCounted
			if bucket != null and not bool(bucket.get("frozen")) and bool(bucket.get("visible")):
				var count := int(bucket.get("instance_count"))
				if bucket.has_method("set_visible"):
					bucket.call("set_visible", false)
				_stats["visible_instances"] = maxi(0, int(_stats.get("visible_instances", 0)) - count)
				hidden += count
			bi += 1
		is_complete = bi >= buckets.size()
		if is_complete:
			_cell_bucket_hide_progress.erase(cell_grid)
		else:
			_cell_bucket_hide_progress[cell_grid] = bi

	return [hidden, is_complete]


## NOTE: the old scene-node per-cell MultiMesh batch path
## (batch_cell_into_multimesh, _cell_batches, CellBatch) was removed. It was not
## replaced by the parked world-scoped PrototypeRegistry for production use.
## The active NEAR/MID static path is CellStaticBucket: per cell/payload,
## server-direct, resource-owning, and cleanup-detached before RID free.

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
	else:
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

	if data.registry_id >= 0 and _prototype_registry != null:
		if is_promoted:
			_prototype_registry.hide_instance(data.registry_id)
		else:
			_prototype_registry.show_instance(data.registry_id, data.transform)
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
	var visible_direct_instances := 0
	for id: int in _instances:
		var data: InstanceData = _instances[id]
		var instance_visible := visible
		if data.visual_proxy and not data.source_key.is_empty():
			instance_visible = visible \
				and data.source_key not in _visual_proxy_dirty_reason \
				and not bool(_visual_proxy_suppressed.get(data.source_key, false))
		if data.registry_id >= 0 and _prototype_registry != null:
			if instance_visible:
				_prototype_registry.show_instance(data.registry_id, data.transform)
			else:
				_prototype_registry.hide_instance(data.registry_id)
		else:
			for rid: RID in data.sub_rids:
				if rid.is_valid():
					RenderingServer.instance_set_visible(rid, instance_visible)
		data.visible = instance_visible
		if instance_visible:
			visible_direct_instances += 1
	for buckets: Array in _cell_buckets.values():
		for bucket_value: Variant in buckets:
			var bucket: RefCounted = bucket_value as RefCounted
			if bucket != null and not bool(bucket.get("frozen")) and bucket.has_method("set_visible"):
				bucket.call("set_visible", visible)
	var bucket_instances := int(_stats.get("bucket_instances", 0))
	_stats["visible_instances"] = visible_direct_instances + (bucket_instances if visible else 0)


func clear(clear_mesh_types: bool = true) -> void:
	var rs := RenderingServer

	# Tear down the registry first — it owns its own RS instances + MultiMeshes.
	if _prototype_registry != null:
		_prototype_registry.cleanup()
		_prototype_registry = null

	for bucket_key: String in _cell_bucket_build_tasks.keys():
		cancel_cell_bucket_build(bucket_key)
	_cell_bucket_build_tasks.clear()

	for id: int in _instances:
		var data: InstanceData = _instances[id]
		for rid: RID in data.sub_rids:
			if rid.is_valid():
				rs.free_rid(rid)
	_instances.clear()
	_cell_index.clear()
	_visual_proxy_by_source.clear()
	_visual_proxy_dirty_reason.clear()
	_visual_proxy_suppressed.clear()
	var detached_bucket_lists: Array = []
	for cell_grid: Vector2i in _cell_buckets.keys():
		detached_bucket_lists.append(_detach_cell_buckets(cell_grid))
	_cell_bucket_hide_progress.clear()
	_cell_hide_progress.clear()
	_cell_bucket_key_index.clear()
	for buckets: Array in detached_bucket_lists:
		_cleanup_detached_buckets(buckets)
	_cell_bucket_pending_cleanup.clear()
	_hlod_covered_bucket_counts.clear()
	_drain_descriptor_build_tasks()

	if clear_mesh_types:
		# Lock for the iteration + clear — any in-flight worker read of
		# _mesh_types must complete or block here before we clear prototype
		# descriptors and legacy direct-instance owned RIDs. Cell buckets have
		# already detached and freed their own RIDs/resource refs above.
		# Clear is the teardown path (scene exit / test cleanup); worker
		# cancellation SHOULD have already run upstream via
		# _phase_a_cancel_workers_for_request, but this lock is the final
		# correctness barrier.
		_mesh_types_mutex.lock()
		for type_name: String in _mesh_types:
			var mesh_type: MeshType = _mesh_types[type_name]
			if mesh_type.owns_mesh and mesh_type.mesh_rid.is_valid():
				rs.free_rid(mesh_type.mesh_rid)
			if mesh_type.owns_material and mesh_type.material_rid.is_valid():
				rs.free_rid(mesh_type.material_rid)
		_mesh_types.clear()
		_stats["mesh_types"] = 0
		_mesh_types_mutex.unlock()

	_stats["total_instances"] = 0
	_stats["visible_instances"] = 0
	_stats["cell_buckets"] = 0
	_stats["bucket_instances"] = 0
	_stats["bucket_draw_groups"] = 0
	_stats["bucket_rs_instances"] = 0
	_stats["hlod_bucket_overrides"] = 0
	_stats["hlod_bucket_override_refs"] = 0
	_stats["visual_proxy_instances"] = 0
	_stats["visual_proxy_dirty"] = 0


func _drain_descriptor_build_tasks() -> void:
	_descriptor_build_tasks.clear()

#endregion


#region Queries

## Get statistics, including active CellStaticBucket counters and parked
## PrototypeRegistry counters.
##
## Extra fields:
##   `cell_buckets`        — active spatially local static buckets
##   `bucket_draw_groups`  — draw groups inside active buckets
##   `bucket_rs_instances` — RS instances owned by active buckets
##   `registry_batches`    — legacy PrototypeRegistry MultiMeshes, normally 0
##   `registry_slots`      — legacy registry live slots, normally 0
##
## Legacy mm_batches/mm_slots/mm_cells fields are retained and set to 0 for
## any callers that still probe them (heartbeat log, benchmark readers) —
## they'll be cleaned up in a follow-up pass.
func get_stats() -> Dictionary:
	_refresh_hlod_bucket_override_stats()
	var result: Dictionary = _stats.duplicate()
	result["mm_batches"] = 0
	result["mm_slots"] = 0
	result["mm_cells"] = 0

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
	# Mutex-wrapped: worker-thread callers (prototype pre-registration in Phase F,
	# precompute_instance in Phase E) need to read _mesh_types concurrently with
	# main-thread registration writes. ~100ns uncontended.
	_mesh_types_mutex.lock()
	var result := type_name in _mesh_types
	_mesh_types_mutex.unlock()
	return result

## Whether mid_objects is toggled on. Used by callers to skip work that would be discarded.
func is_globally_visible() -> bool:
	return _globally_visible


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
