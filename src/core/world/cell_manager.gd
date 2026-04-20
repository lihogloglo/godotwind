## Cell Manager - Loads and instantiates Morrowind cells in Godot
## Handles loading cells from ESM data and placing objects using NIF models
## Ported from OpenMW apps/openmw/mwworld/cellstore.cpp and scene.cpp
##
## Supports both synchronous and asynchronous cell loading:
## - load_exterior_cell() / load_cell() - Synchronous, blocks until complete
## - request_cell_async() - Async, uses BackgroundProcessor for NIF parsing
##
## Phase 2 Refactoring: Uses ReferenceInstantiator for object creation (SRP)
class_name CellManager
extends RefCounted

# Preload coordinate utilities
const CS := preload("res://src/core/coordinate_system.gd")
const ModelLoader := preload("res://src/core/world/model_loader.gd")
const ReferenceInstantiator := preload("res://src/core/world/reference_instantiator.gd")
const ObjectPoolScript := preload("res://src/core/world/object_pool.gd")
const NIFConverter := preload("res://src/core/nif/nif_converter.gd")
const NIFParseResult := preload("res://src/core/nif/nif_parse_result.gd")
const StaticObjectRendererScript := preload("res://src/core/world/static_object_renderer.gd")
const CharacterFactoryV2 := preload("res://src/core/animation/character_factory_v2.gd")
const MeshVisibilityUtils := preload("res://src/core/world/mesh_visibility_utils.gd")
const StreamingPolicyScript := preload("res://src/core/world/streaming_policy.gd")
const DU := preload("res://src/core/world/distance_utils.gd")
# S.1 follow-up §12.2 — second crash-site breadcrumbs for the post-instantiate
# batch add_child loop.
const CrashBreadcrumb := preload("res://src/core/logging/crash_breadcrumb.gd")

# Model loader for NIF loading and caching
var _model_loader: ModelLoader = ModelLoader.new()

# Reference instantiator for creating Node3D objects from cell references
var _instantiator: ReferenceInstantiator = ReferenceInstantiator.new()

# Character factory for creating animated NPCs and creatures
# Use V2 factory for new animation system with IK, procedural animation, and LOD
var _character_factory: CharacterFactoryV2 = CharacterFactoryV2.new()
var enable_npc_wander: bool = true  # NPCs wander near spawn points

# Object pool for frequently used models
var _object_pool: RefCounted = null  # ObjectPool

# Static object renderer for fast flora rendering (uses RenderingServer directly)
var _static_renderer: Node = null  # StaticObjectRenderer

# MID-tier batch pool removed — StaticObjectRenderer now handles MID with per-instance LOD

# Statistics (instantiation stats now in ReferenceInstantiator, model stats in ModelLoader)
var _stats: Dictionary = {
	"multimesh_instances": 0,
	"objects_instantiated": 0,
	"lights_created": 0,
	"objects_from_pool": 0,
}

# Configuration
var create_lights: bool = true   # Whether to create OmniLight3D for light refs
var load_npcs: bool = true:      # Whether to load NPC models
	set(value):
		load_npcs = value
		_sync_instantiator_config()
var load_creatures: bool = true: # Whether to load creature models
	set(value):
		load_creatures = value
		_sync_instantiator_config()
var use_object_pool: bool = true # Whether to use object pooling for common models
var use_static_renderer: bool = true  # Use RenderingServer for flora (much faster)
var use_multimesh_instancing: bool = true  # Use MultiMesh for batching identical objects
var min_instances_for_multimesh: int = 10  # Minimum instances to use MultiMesh instead of individual nodes

# Morrowind light radius to Godot light range conversion factor
const MW_LIGHT_SCALE: float = CS.SCALE_FACTOR  # 1/70 — converts MW radius to meters

# Pool pre-warming: fraction of max pool size to pre-create during preload
const POOL_PREWARM_RATIO: float = 0.2
# Pool pre-warming: minimum instances to pre-create per model
const POOL_PREWARM_MIN_COUNT: int = 10
# Default maximum pool size when auto-registering models
const DEFAULT_POOL_MAX_SIZE: int = 50

# Phase A — off-thread PackedScene.instantiate gate. Slice 4 lands the dispatch
# pass inert; slice 5 flips this to true AND wires the drain in the same
# commit. Inert-until-drain keeps the branch free of worker-result leaks
# between slices. Plan: phase_a_offthread_instantiate.md §7.4–§7.5.
const PHASE_A_OFFTHREAD_INSTANTIATE: bool = false


## Initialize instantiator with current configuration and dependencies
func _init() -> void:
	_sync_instantiator_config()


## Initialize object pool for frequently used models
## parent_node: Node3D to store pooled objects when not in use (required for proper pooling)
func init_object_pool(parent_node: Node3D = null) -> void:
	if _object_pool == null:
		_object_pool = ObjectPoolScript.new()
		# Initialize pool with parent node for storing inactive instances
		# Without this, released objects have no parent and may be garbage collected
		if parent_node:
			_object_pool.call("init", parent_node)
		_sync_instantiator_config()


## Get the object pool (for releasing objects back when unloading cells)
func get_object_pool() -> RefCounted:
	return _object_pool


## Set the mod registry for asset resolution
func set_mod_registry(registry: ModRegistry) -> void:
	if _model_loader:
		_model_loader.set_mod_registry(registry)


## I.7 — Install a callback that receives every DoorInteractable's
## `door_activated` signal. Called by world_explorer after the pocket
## manager is ready so door taps can drive `enter_interior()`.
## Headless / test-scene callers can leave it unset — teleport doors
## still emit their signal but no listener consumes it.
func set_door_activated_handler(handler: Callable) -> void:
	_instantiator.door_activated_handler = handler


# REMOVED: set_object_streamer()
# Native streaming system uses visibility_range, not a separate ObjectStreamer


## Sync configuration to instantiator
func _sync_instantiator_config() -> void:
	# Set up character factory
	_character_factory.set_model_loader(_model_loader)
	_character_factory.enable_wander = enable_npc_wander

	# Configure instantiator
	_instantiator.model_loader = _model_loader
	_instantiator.object_pool = _object_pool
	_instantiator.static_renderer = _static_renderer
	_instantiator.character_factory = _character_factory
	_instantiator.create_lights = create_lights
	_instantiator.load_npcs = load_npcs
	_instantiator.load_creatures = load_creatures
	_instantiator.use_object_pool = use_object_pool
	_instantiator.use_static_renderer = use_static_renderer

	# Pass scene tree for fade-in tweens (will be set when first called from a Node)
	var main_loop: MainLoop = Engine.get_main_loop()
	if main_loop is SceneTree:
		_instantiator.scene_tree = main_loop as SceneTree


## Load an interior cell by name and return a Node3D containing all objects
func load_cell(cell_name: String) -> Node3D:
	var cell_record: CellRecord = ESMManager.get_cell(cell_name)
	if not cell_record:
		push_error("CellManager: Cell not found: '%s'" % cell_name)
		return null

	return _instantiate_cell(cell_record)


## Load an exterior cell by grid coordinates and return a Node3D containing all objects
func load_exterior_cell(x: int, y: int) -> Node3D:
	var cell_record: CellRecord = ESMManager.get_exterior_cell(x, y)
	if not cell_record:
		push_error("CellManager: Exterior cell not found: %d, %d" % [x, y])
		return null

	return _instantiate_cell(cell_record)


## Load exterior cell metadata only (no objects) for AAA streaming mode
## Returns an empty Node3D container - terrain is handled separately via Terrain3D
## Objects are streamed by ObjectStreamer via position index
func load_exterior_cell_metadata_only(x: int, y: int) -> Node3D:
	var cell_record: CellRecord = ESMManager.get_exterior_cell(x, y)
	if not cell_record:
		push_error("CellManager: Exterior cell not found: %d, %d" % [x, y])
		return null

	# Create empty container - no objects, terrain is separate
	var cell_node := Node3D.new()
	cell_node.name = "Cell_%d_%d" % [x, y]

	# Store cell metadata for potential use (water height, ambient, etc.)
	cell_node.set_meta("cell_record", cell_record)
	cell_node.set_meta("grid_x", x)
	cell_node.set_meta("grid_y", y)
	cell_node.set_meta("aaa_mode", true)

	return cell_node


## Load only NPCs/creatures into an existing cell node
## Used when toggling NPCs on after cells were loaded without them
func load_characters_into_cell(x: int, y: int, cell_node: Node3D) -> int:
	var cell_record: CellRecord = ESMManager.get_exterior_cell(x, y)
	if not cell_record:
		push_warning("CellManager: Cannot load characters - cell not found: %d, %d" % [x, y])
		return 0

	var cell_grid := Vector2i(x, y)
	var loaded := 0
	var npc_refs := 0

	# Temporarily enable NPC/creature loading
	var was_loading_npcs := load_npcs
	var was_loading_creatures := load_creatures
	load_npcs = true
	load_creatures = true

	for ref: CellReference in cell_record.references:
		# Get base record and type
		var record_type: Array = [""]
		var base_record: Variant = ESMManager.get_any_record(str(ref.ref_id), record_type)
		if not base_record:
			continue

		var type_name: String = record_type[0] if record_type.size() > 0 else ""

		# Only handle NPCs and creatures
		if type_name in ["npc", "creature", "leveled_creature"]:
			npc_refs += 1
			var obj: Node3D = _instantiator.instantiate_reference(ref, cell_grid)
			if obj:
				cell_node.add_child(obj)
				loaded += 1
	# Restore original loading settings
	load_npcs = was_loading_npcs
	load_creatures = was_loading_creatures

	return loaded


## Instantiate a cell from its record
func _instantiate_cell(cell: CellRecord) -> Node3D:
	var cell_node := Node3D.new()

	# Get cell grid for static renderer tracking
	var cell_grid := Vector2i(cell.grid_x, cell.grid_y) if not cell.is_interior() else Vector2i.ZERO

	# Name the cell node
	if cell.is_interior():
		cell_node.name = cell.name.replace(" ", "_").replace(",", "")
	else:
		cell_node.name = "Cell_%d_%d" % [cell.grid_x, cell.grid_y]

	var loaded := 0
	var failed := 0
	var static_count := 0
	var multimesh_count := 0

	# Phase 1: Group references by model for potential MultiMesh batching
	if use_multimesh_instancing:
		var instance_groups := _group_references_for_instancing(cell.references, cell_grid)

		# Phase 2: Create MultiMesh instances for suitable groups
		multimesh_count = _create_multimesh_instances(instance_groups, cell_node)

		# Collect objects for deferred fade-in (must wait until cell_node is in scene tree)
		var objects_to_fade: Array[Node3D] = []

		# Phase 3: Instantiate remaining objects normally
		for ref: CellReference in instance_groups.get("individual_refs", []):
			var obj := _instantiator.instantiate_reference(ref, cell_grid)
			if obj:
				cell_node.add_child(obj)
				if _instantiator.enable_fade_in:
					objects_to_fade.append(obj)
				loaded += 1
			elif use_static_renderer and _static_renderer:
				static_count += 1
			else:
				failed += 1

		# Defer fade-in until cell_node enters scene tree
		if not objects_to_fade.is_empty():
			_defer_fade_in(cell_node, objects_to_fade)
	else:
		# Collect objects for deferred fade-in
		var objects_to_fade: Array[Node3D] = []

		# Original path: no batching
		for ref: CellReference in cell.references:
			var obj := _instantiator.instantiate_reference(ref, cell_grid)
			if obj:
				cell_node.add_child(obj)
				if _instantiator.enable_fade_in:
					objects_to_fade.append(obj)
				loaded += 1
			elif use_static_renderer and _static_renderer:
				static_count += 1
			else:
				failed += 1

		# Defer fade-in until cell_node enters scene tree
		if not objects_to_fade.is_empty():
			_defer_fade_in(cell_node, objects_to_fade)

	var total_objects := loaded + static_count + multimesh_count
	Log.info("streaming", "CellManager: Loaded %d objects (%d individual, %d static, %d multimesh), %d failed" % [
		total_objects, loaded, static_count, multimesh_count, failed
	])
	_stats["multimesh_instances"] = _stats.get("multimesh_instances", 0) + multimesh_count

	return cell_node


## Defer fade-in until cell_node enters the scene tree
## This is necessary because Node.create_tween() requires the node to be in the scene tree
func _defer_fade_in(cell_node: Node3D, objects: Array[Node3D]) -> void:
	Log.debug("streaming", "[CellManager] _defer_fade_in called with %d objects, cell in tree: %s" % [objects.size(), cell_node.is_inside_tree()])

	# Connect to tree_entered signal to apply fade-in once in scene tree
	var apply_fades := func() -> void:
		Log.debug("streaming", "[CellManager] apply_fades executing for %d objects" % objects.size())
		for obj: Node3D in objects:
			if is_instance_valid(obj):
				_instantiator._apply_fade_in(obj)
				# Randomize animation start to desync identical objects (flags, banners)
				if obj.has_meta("_anim_randomize"):
					obj.remove_meta("_anim_randomize")
					for child in obj.get_children():
						if child is AnimationPlayer:
							var ap := child as AnimationPlayer
							if ap.is_playing():
								ap.seek(randf() * ap.current_animation_length)

	if cell_node.is_inside_tree():
		# Already in tree, apply immediately
		apply_fades.call()
	else:
		# Wait for tree entry
		cell_node.tree_entered.connect(apply_fades, CONNECT_ONE_SHOT)


## Group cell references for MultiMesh instancing
## Returns dictionary with:
## - "multimesh_groups": Dictionary of model_path -> Array of {ref, transform, base_record}
## - "individual_refs": Array of references that should be instantiated individually
func _group_references_for_instancing(references: Array, cell_grid: Vector2i) -> Dictionary:
	var multimesh_candidates: Dictionary = {}  # model_path -> Array of {ref, base_record}
	var individual_refs: Array = []
	var _debug_significant_count := 0

	for ref: CellReference in references:
		# Get base record and type
		var record_type: Array = [""]
		var base_record: Variant = ESMManager.get_any_record(str(ref.ref_id), record_type)

		if not base_record:
			continue

		var type_name: String = record_type[0] if record_type.size() > 0 else ""

		# Skip non-model objects (lights, NPCs, creatures, leveled items)
		if type_name in ["light", "npc", "creature", "leveled_creature", "leveled_item"]:
			individual_refs.append(ref)
			continue

		# Get model path
		var model_path: String = _get_model_path(base_record)
		if model_path.is_empty():
			continue

		# Check if suitable for MultiMesh
		if not _is_multimesh_candidate(model_path, base_record):
			individual_refs.append(ref)
			if _instantiator.is_significant_object(model_path):
				_debug_significant_count += 1
			continue

		# Check if would use static renderer (skip those - already optimized)
		if use_static_renderer and _static_renderer and _instantiator._is_static_render_model(model_path):
			individual_refs.append(ref)
			continue

		# Add to candidates
		var normalized := model_path.to_lower().replace("/", "\\")
		if normalized not in multimesh_candidates:
			multimesh_candidates[normalized] = []

		var candidates_array: Array = multimesh_candidates[normalized]
		candidates_array.append({
			"ref": ref,
			"base_record": base_record,
			"model_path": model_path
		})

	# Filter groups: only keep those with enough instances
	var multimesh_groups: Dictionary = {}
	for model_path: String in multimesh_candidates:
		var candidates: Array = multimesh_candidates[model_path]
		if candidates.size() >= min_instances_for_multimesh:
			multimesh_groups[model_path] = candidates
		else:
			# Too few instances - instantiate individually
			for candidate: Dictionary in candidates:
				individual_refs.append(candidate.ref)

	if _debug_significant_count > 0:
		Log.debug("streaming", "[ODM-GROUP] Cell %s: %d significant objects to instantiate individually" % [
			cell_grid, _debug_significant_count
		])

	return {
		"multimesh_groups": multimesh_groups,
		"individual_refs": individual_refs
	}


## Check if a model is suitable for MultiMesh instancing
## MultiMesh candidates are: small repeated objects like rocks, pots, bottles, flora
func _is_multimesh_candidate(model_path: String, base_record: Variant) -> bool:
	var lower := model_path.to_lower()

	# Small rocks (already filtered by _is_static_render_model for flora)
	if "terrain_rock" in lower:
		# Only small rocks (rm_ prefix = rock medium/small)
		if "_rm_" in lower or "small" in lower:
			return true
		return false

	# Containers - pots, urns, barrels, crates
	if "contain_" in lower:
		if "barrel" in lower or "sack" in lower or "crate" in lower or "chest" in lower:
			return true
		# Redware pots, urns
		if "redware" in lower or "urn" in lower or "pot_" in lower:
			return true
		return false

	# Misc clutter - bottles, cups, plates, etc.
	if "misc_com" in lower or "misc_de" in lower:
		if "bottle" in lower or "cup" in lower or "plate" in lower or "bowl" in lower:
			return true
		if "lantern" in lower or "candle" in lower:
			return true
		return false

	# Light fixtures (the model, not the light itself)
	if "light_" in lower and "com_" in lower:
		return true

	# Dwemer items (gears, pipes, etc.)
	if "dwrv_" in lower:
		if "gear" in lower or "pipe" in lower or "scrap" in lower:
			return true

	return false


## Create MultiMeshInstance3D nodes for batched groups
## Returns total count of instances created
func _create_multimesh_instances(instance_groups: Dictionary, parent_node: Node3D) -> int:
	var multimesh_groups := instance_groups.get("multimesh_groups", {}) as Dictionary
	var total_count := 0

	for model_path: String in multimesh_groups:
		var candidates: Array = multimesh_groups[model_path]
		var count := candidates.size()
		if count == 0:
			continue

		# Get/load prototype model
		var first_candidate: Dictionary = candidates[0]
		var base_record: Variant = first_candidate.get("base_record", {})
		var record_id: String = ""
		if base_record is Dictionary:
			var base_dict: Dictionary = base_record
			record_id = base_dict.get("record_id", "")
		var first_model_path: String = first_candidate.get("model_path", "")
		var prototype: Node3D = _model_loader.get_model(first_model_path, record_id)

		if not prototype:
			# Failed to load - fall back to individual instantiation
			for candidate: Dictionary in candidates:
				var obj: Node3D = _instantiator.instantiate_reference(candidate.ref as CellReference)
				if obj:
					parent_node.add_child(obj)
			continue

		# Find first MeshInstance3D in prototype (skips LOD nodes)
		var mesh_instance: MeshInstance3D = _find_first_mesh_instance(prototype)
		if not mesh_instance or not mesh_instance.mesh:
			Log.debug("streaming", "[DIAG] MultiMesh: No valid mesh found in %s, falling back to individual" % model_path.get_file())
			for candidate: Dictionary in candidates:
				var obj: Node3D = _instantiator.instantiate_reference(candidate.ref as CellReference)
				if obj:
					parent_node.add_child(obj)
			continue

		# Debug: Log what mesh we're using and what other meshes exist in the prototype
		Log.debug("streaming", "[DIAG] MultiMesh using mesh '%s' from %s" % [mesh_instance.name, model_path.get_file()])
		_debug_log_all_meshes(prototype, model_path.get_file())

		# Create MultiMesh
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.instance_count = count
		multimesh.mesh = mesh_instance.mesh

		# Set transforms for each instance
		for i in range(count):
			var ref := candidates[i].ref as CellReference
			multimesh.set_instance_transform(i, _calculate_transform(ref))

		# Create MultiMeshInstance3D node
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "MultiMesh_%s_%d" % [model_path.get_file().get_basename(), count]
		mmi.multimesh = multimesh
		mmi.material_override = mesh_instance.material_override
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

		# Render-tier visibility_range — single band 0-500m → impostor handoff.
		mmi.visibility_range_begin = 0.0
		mmi.visibility_range_end = DU.MID_END
		mmi.visibility_range_begin_margin = 0.0
		mmi.visibility_range_end_margin = DU.FADE_MARGIN_LOD3_FAR
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

		parent_node.add_child(mmi)
		total_count += count

		Log.debug("streaming", "  MultiMesh: %d x %s" % [count, model_path.get_file()])

	return total_count


## Find first MeshInstance3D in a node hierarchy.
## Post-B-wide refactor: there are no sibling `_LODn` nodes — LODs live inside
## the ArrayMesh via surface_lod_indices — so the old skip clause is gone.
## (Narrow-scope Priority-0-allowed edit, LOD_REFACTOR_B_WIDE.md Part 3.3.)
func _find_first_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D

	for child in node.get_children():
		var found := _find_first_mesh_instance(child)
		if found:
			return found

	return null


## Debug: Log all MeshInstance3D nodes in a prototype (to audit LOD nodes)
func _debug_log_all_meshes(node: Node, model_name: String, depth: int = 0) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var is_lod := mi.name.ends_with("_LOD1") or mi.name.ends_with("_LOD2") or mi.name.ends_with("_LOD3")
		var mat_info := "no_material"
		if mi.material_override:
			mat_info = "override"
		elif mi.mesh and mi.mesh.get_surface_count() > 0:
			var surf_mat := mi.mesh.surface_get_material(0)
			mat_info = "surface_mat" if surf_mat else "no_surf_mat"
		Log.debug("streaming", "[DIAG]   %s%s: visible=%s, is_lod=%s, mat=%s" % [
			"  ".repeat(depth), mi.name, mi.visible, is_lod, mat_info
		])
	for child in node.get_children():
		_debug_log_all_meshes(child, model_name, depth + 1)


## Calculate transform for a cell reference
func _calculate_transform(ref: CellReference) -> Transform3D:
	var pos := CS.vector_to_godot(ref.position)
	var scale := CS.scale_to_godot(ref.scale)
	var basis := CS.esm_rotation_to_godot_basis(ref.rotation)
	basis = basis.scaled(scale)
	return Transform3D(basis, pos)



## Preload common models into cache to reduce initial loading delays
## Call this during game initialization for smoother first-cell loading
## Also pre-warms the object pool with initial instances for instant acquire()
## Returns number of models successfully preloaded
func preload_common_models() -> int:
	var common_models := ObjectPoolScript.identify_common_models(self)
	var loaded := 0
	var pool_instances := 0

	for model_path: String in common_models:
		# Skip if already cached
		if _model_loader.has_model(model_path):
			continue

		# Skip flora that will use StaticObjectRenderer instead
		if use_static_renderer and _static_renderer and _instantiator._is_static_render_model(model_path):
			continue

		# Try to load the model
		var prototype: Node3D = _model_loader.get_model(model_path)
		if prototype:
			loaded += 1

			# Register with pool AND pre-warm with initial instances
			# Pre-warming means acquire() returns instantly without duplicate()
			# Increased from 50% to 80% for higher cache hit rate (targeting 70%+)
			if _object_pool and not _object_pool.call("has_model", model_path):
				var pool_size: int = common_models[model_path]
				# Pre-create 80% of max pool size for maximum cache hit rate
				# This front-loads the duplicate() cost during preload instead of gameplay
				var initial_count: int = maxi(POOL_PREWARM_MIN_COUNT, int(pool_size * POOL_PREWARM_RATIO))
				_object_pool.call("register_model", model_path, prototype, initial_count, pool_size)
				pool_instances += initial_count

	return loaded


## Preload models asynchronously using the background processor
## Emits preload_complete signal when done
## Returns immediately - check preload_progress for status
signal preload_progress(loaded: int, total: int)
signal preload_complete(loaded: int, failed: int)

var _preload_pending: Dictionary = {}  # model_path -> task_id
var _preload_loaded: int = 0
var _preload_failed: int = 0
var _preload_total: int = 0

func preload_common_models_async() -> void:
	# In runtime mode, load from disk cache only - no NIF parsing
	if _model_loader.runtime_mode:
		var common_models := ObjectPoolScript.identify_common_models(self)
		var loaded := 0
		var skipped := 0

		for model_path: String in common_models:
			# Skip if already in memory cache
			if _model_loader.has_model(model_path):
				continue

			# Try to load from disk cache
			var prototype := _model_loader.get_model(model_path)
			if prototype:
				loaded += 1
			else:
				skipped += 1  # Not prebaked - that's fine

		Log.info("streaming", "CellManager: Preloaded %d models from disk cache (%d not prebaked)" % [loaded, skipped])
		preload_complete.emit(loaded, skipped)
		return

	# PREBAKING MODE: Do async NIF parsing
	if not _background_processor:
		push_warning("CellManager: No background processor, falling back to sync preload")
		preload_common_models()
		return

	var common_models := ObjectPoolScript.identify_common_models(self)
	_preload_loaded = 0
	_preload_failed = 0
	_preload_total = 0
	_preload_pending.clear()

	for model_path: String in common_models:
		# Skip if already cached
		if _model_loader.has_model(model_path):
			continue

		_preload_total += 1

		# Submit parse task
		var task_id := _submit_parse_task(model_path, "", -1)  # -1 = preload, not tied to a cell request
		if task_id >= 0:
			_preload_pending[model_path] = task_id

	if _preload_pending.is_empty():
		preload_complete.emit(0, 0)
		return

	Log.info("streaming", "CellManager: Preloading %d models asynchronously..." % _preload_pending.size())


func _check_preload_completion(task_id: int, result: Variant) -> bool:
	# Check if this task is a preload task
	var model_path := ""
	for path: String in _preload_pending:
		if _preload_pending[path] == task_id:
			model_path = path
			break

	if model_path.is_empty():
		return false  # Not a preload task

	_preload_pending.erase(model_path)

	if result is NIFParseResult:
		var parse_result: NIFParseResult = result
		if parse_result.is_valid():
			var converter: NIFConverter = NIFConverter.new()
			var prototype: Node3D = converter.convert_from_parsed(parse_result)
			if prototype:
				_model_loader.add_to_cache(model_path, prototype, "")
				_preload_loaded += 1

				# Register with pool
				if _object_pool and not _object_pool.call("has_model", model_path):
					var common_models: Dictionary = ObjectPoolScript.identify_common_models(self)
					_object_pool.call("register_model", model_path, prototype, 0, common_models.get(model_path, DEFAULT_POOL_MAX_SIZE))
			else:
				_preload_failed += 1
		else:
			_preload_failed += 1
	else:
		_preload_failed += 1

	preload_progress.emit(_preload_loaded, _preload_total)

	if _preload_pending.is_empty():
		Log.info("streaming", "CellManager: Preload complete - %d loaded, %d failed" % [_preload_loaded, _preload_failed])
		preload_complete.emit(_preload_loaded, _preload_failed)

	return true


# =============================================================================
# DEFERRED CELL LOADING (For Per-Object Distance Management)
# =============================================================================
# Loads cell reference DATA without instantiating Node3D objects.
# Objects are registered with ObjectStreamer as "deferred" and will
# be instantiated when they enter NEAR range.
#
# This enables radius-based cell loading where:
# - All cells within FAR range have their data loaded
# - Only objects in NEAR range get Node3D instantiated
# - MID/FAR objects show LOD meshes or impostors via ObjectStreamer
# =============================================================================

## Get cell references for a given grid position
func get_cell_references(x: int, y: int) -> Array:
	var cell_record: CellRecord = ESMManager.get_exterior_cell(x, y)
	if not cell_record:
		return []
	return cell_record.references


## Instantiate a single deferred object by its data
## Called when ObjectStreamer requests instantiation (object entering NEAR)
## Returns the instantiated Node3D or null on failure
func instantiate_deferred_object(
	model_path: String,
	world_transform: Transform3D,
	cell_grid: Vector2i,
	ref_id: String,
	ref_num: int
) -> Node3D:
	# Get record_id for collision shape lookup
	var record_type: Array = [""]
	var base_record: Variant = ESMManager.get_any_record(ref_id, record_type)

	var record_id: String = ""
	if base_record and "record_id" in base_record:
		record_id = base_record.record_id

	# Try to get from object pool first
	if use_object_pool and _object_pool:
		var pooled: Node3D = _object_pool.call("acquire", model_path)
		if pooled:
			pooled.name = ref_id + "_" + str(ref_num)
			pooled.global_transform = world_transform
			_hide_lod_nodes(pooled)  # CRITICAL: Hide LODs on pooled objects
			ModelLoader._disable_collision_shapes_in_tree(pooled)  # reset: may have been NEAR before pool release
			_stats["objects_from_pool"] += 1
			return pooled

	# Load — get_model() returns a fresh Node3D (collision disabled) from PackedScene cache.
	var instance: Node3D = _model_loader.get_model(model_path, record_id)
	if not instance:
		return null

	instance.name = ref_id + "_" + str(ref_num)
	instance.global_transform = world_transform

	# CRITICAL: Hide LOD nodes to prevent white mesh overlays
	_hide_lod_nodes(instance)

	# Add metadata for console object picker
	if base_record:
		if "record_id" in base_record:
			instance.set_meta("form_id", base_record.record_id)
		instance.set_meta("ref_id", ref_id)
		instance.set_meta("ref_num", ref_num)
		instance.set_meta("model_path", model_path)

	_stats["objects_instantiated"] += 1

	# NOTE: Fade-in is NOT applied here - caller must apply after add_child()
	# Use apply_fade_in_to_object() after adding to scene tree

	return instance


## Apply fade-in effect to an object (must be called after add_child)
## This is a public helper for callers who instantiate objects via instantiate_deferred_object()
func apply_fade_in_to_object(obj: Node3D) -> void:
	if _instantiator.enable_fade_in and is_instance_valid(obj):
		_instantiator._apply_fade_in(obj)


# =============================================================================
# ASYNC CELL LOADING API
# =============================================================================
# Uses BackgroundProcessor to parse NIFs on worker threads.
# The main thread then instantiates from parsed data within time budget.
# =============================================================================

## Maximum concurrent async cell requests (prevents memory buildup)
## Industry standard: 4-8 concurrent operations max to avoid I/O saturation
## Diagnostics show duplicate() is fast (~0.35ms), so we can handle more concurrent requests
const MAX_ASYNC_REQUESTS := 6

## Maximum items in instantiation queue (prevents memory buildup)
## Morrowind cells can have 200+ objects each, 32 cells × 200 = 6400 objects max
const MAX_INSTANTIATION_QUEUE := 8000

## Maximum objects to instantiate per frame (prevents frame spikes)
## With prebaked models (no NIF conversion), instantiation is very fast (~0.35ms per object)
## Increased from 30 to 50 for faster loading without significant FPS impact
const MAX_INSTANTIATIONS_PER_FRAME := 50

## Enable diagnostic logging for performance analysis
var diagnostic_logging: bool = true

## Diagnostic counters (reset periodically)
var _diag_instantiate_time_total_us: int = 0
var _diag_instantiate_count: int = 0
var _diag_last_log_frame: int = 0

## Per-type breakdown (scientific-approach instrumentation 2026-04-19).
## Answers "inside inst: 60ms, which type_name dominates?" Reset every
## ~5s after a log dump in `_maybe_log_per_type_breakdown`.
var _diag_per_type_time_us: Dictionary[String, int] = {}
var _diag_per_type_count: Dictionary[String, int] = {}
var _diag_per_type_last_log_msec: int = 0

## Proximity-deferred interactives (containers, doors, activators, carryables).
## Each entry mirrors `InstantiationEntry` but lives off the main queue until
## the camera approaches the ref. Re-queued by `tick_proximity_deferred`.
## OpenMW lazy-spawn pattern: Node3D interactives at 12-20 ms/ref don't
## instantiate until gameplay can plausibly interact (< 80 m from camera).
var _proximity_deferred: Array[InstantiationEntry] = []
## Enforce retry budget so we don't re-queue the entire deferred list every frame.
var _proximity_last_tick_msec: int = 0
const PROXIMITY_TICK_INTERVAL_MSEC: int = 250

## Queue for pending NIF conversions (deferred to avoid main thread stall)
## Each entry: {parse_result: NIFParseResult, model_path: String, request_id: int, item_id: String}
var _pending_conversions: Array[Dictionary] = []
var _pending_conversion_index: int = 0

## Maximum conversion time per frame in milliseconds
## NOTE: A single complex model can take 500ms-6s to convert
## We can't interrupt mid-conversion, so this is really just a guide
## The key optimization is doing only ONE conversion per frame
const MAX_CONVERSION_TIME_MS := 50.0  # Allow one conversion to complete

## Maximum conversions per frame - keeps FPS stable even with complex models
const MAX_CONVERSIONS_PER_FRAME := 1

## Maximum retries for failed async requests
const MAX_ASYNC_RETRIES := 2

# =============================================================================
# NEAR TIER BURST LOADING (Aggressive instantiation for critical cells)
# =============================================================================

## Import StreamingConfig for burst loading parameters
const SC := preload("res://src/core/world/streaming_config.gd")

## Whether burst loading is currently active
var _burst_loading_active: bool = false

## Burst loading budget (ms) - higher than normal for faster cell population
var _burst_budget_ms: float = SC.NEAR_BURST_BUDGET_MS

## Burst loading max instantiations per frame
var _burst_max_instantiations: int = SC.NEAR_BURST_MAX_INSTANTIATIONS

## Distance threshold for burst loading (objects closer than this get burst priority)
var _burst_distance: float = SC.NEAR_BURST_DISTANCE



# =============================================================================
# POOL PRE-WARMING
# =============================================================================

## Enable pool pre-warming when objects are discovered near player
var pool_prewarm_enabled: bool = SC.POOL_PREWARM_ENABLED

## Models pending pre-warm: model_path -> count needed
var _prewarm_pending: Dictionary = {}

## Pre-warm budget per frame
var _prewarm_per_frame: int = SC.POOL_PREWARM_MAX_PER_FRAME

## Per-request load configuration that overrides shared instantiator defaults.
##
## Carried on AsyncCellRequest and copied onto each spawned InstantiationEntry
## so that concurrent exterior + interior loads can use different settings
## without stomping on each other's shared state.
##
## Prior to this class, InteriorPocketManager had to mutate _instantiator's
## shared flags during a sync load (ipm.gd:753-774). With async loads the
## same mutation would be read across frames by concurrent exterior
## instantiations — LoadProfile eliminates that race by making the settings
## per-request.
class LoadProfile:
	## Apply deferred fade-in after add_child. Off for invisible pocket loads.
	var fade_in: bool = true
	## Route mid-worthy objects through the RS / static-renderer batching path.
	## Must be OFF for interior pockets — RS instances render at ESM world
	## position and ignore the pocket Y=-500 offset + INTERIOR_RENDER_LAYERS.
	var use_static_renderer: bool = true
	## NPC/creature distance cull from camera. 0.0 disables the check — needed
	## for interior pockets because the camera is at the exterior position
	## during pocket load but interior actors use small cell-local coordinates.
	var max_actor_distance: float = 150.0
	## Priority-lane flag — entries with this set jump to the tail of the
	## instantiation queue (pop_back() = next out) regardless of distance
	## priority. Only set to true during an active interior transition to
	## drain the interior ahead of exterior work.
	var interior_priority: bool = false

	static func exterior_default() -> LoadProfile:
		return LoadProfile.new()

	static func interior_pocket() -> LoadProfile:
		var p := LoadProfile.new()
		p.fade_in = false
		p.use_static_renderer = false
		p.max_actor_distance = 0.0
		p.interior_priority = false  # Flipped to true by IPM during transition
		return p


## Async cell request tracking
class AsyncCellRequest:
	var cell_record: CellRecord
	var grid: Vector2i  # For exterior cells
	var is_interior: bool
	var request_id: int
	var load_profile: LoadProfile = null  # Per-request settings (null -> use exterior defaults)
	var pending_parses: Dictionary[String, int] = {}  # model_path -> task_id
	var pending_disk_loads: Dictionary[String, Array] = {}  # model_path -> Array[CellReference] (refs waiting for this model)
	var parsed_results: Dictionary[String, NIFParseResult] = {}  # model_path -> NIFParseResult
	var references_to_process: Array[CellReference] = []  # CellReference objects awaiting instantiation
	var pending_instantiations: int = 0  # Count of items queued for instantiation
	var cell_node: Node3D = null  # The cell node being built
	var started: bool = false
	var completed: bool = false
	var failed: bool = false  # Whether the request failed
	var error_message: String = ""  # Error description if failed
	var retry_count: int = 0  # Number of retries attempted
	var failed_models: Array[String] = []  # Models that failed to parse


## Next async request ID
var _next_async_id: int = 1

## Active async requests
var _async_requests: Dictionary[int, AsyncCellRequest] = {}


## Entry in the instantiation queue
class InstantiationEntry:
	var request_id: int
	var ref: CellReference
	var model_path: String
	var item_id: String
	var position: Vector3
	## Per-entry load profile copied from the owning AsyncCellRequest at queue
	## time. Read during _process_instantiation_queue so that concurrent loads
	## with different profiles don't stomp on each other.
	## Null means "use instantiator defaults" (sync path compatibility).
	var load_profile: LoadProfile = null
	## Mirrored from load_profile.interior_priority for cheap sort access.
	## Flipped to true by InteriorPocketManager when a transition begins so
	## that in-flight interior entries drain ahead of exterior work.
	var interior_priority: bool = false

	# Phase A (off-thread PackedScene.instantiate) — currently unused, wired in
	# slices 3-5. Plan: docs/plans/distant_rendering_2026_04/phase_a_offthread_instantiate.md §3.
	## Detached Node3D produced by the worker (null until worker completes).
	## Main thread reads this ONLY after WorkerThreadPool.is_task_completed
	## returns true — that boundary is the implicit mutex.
	var worker_instance: Node3D = null
	## Set true by the dispatch pass after WorkerThreadPool.add_task succeeds.
	## Guards against re-dispatching the same entry on subsequent frames.
	var worker_dispatched: bool = false
	## Task id returned by WorkerThreadPool.add_task, used by
	## is_task_completed polling (drain pass) and wait_for_task_completion
	## (cancellation pass). -1 means "never dispatched".
	var worker_task_id: int = -1


## BackgroundProcessor reference (must be set via set_background_processor)
var _background_processor: Node = null

## Instantiation queue for time-budgeted processing
## Entries include position for distance-priority sorting
var _instantiation_queue: Array[InstantiationEntry] = []

## Camera position for distance-based prioritization
var _camera_position: Vector3 = Vector3.ZERO

## Camera forward direction for frustum-aware priority sorting
var _camera_forward: Vector3 = Vector3.FORWARD

## Frame counter for periodic queue re-sorting
var _queue_sort_frame: int = 0
const QUEUE_SORT_INTERVAL: int = 10  # Re-sort every N frames

## Parsed model prototypes waiting to be cached (from async results)
var _pending_prototype_cache: Dictionary = {}  # cache_key -> NIFParseResult

## AABB max dimension cache — avoids recomputing for same model path.
## Maps model_path -> float (max dimension in meters). 0.0 = unknown/no mesh.
## Retained for future use (projected-size metric, interaction reach, etc).
## S.1: AABB-based mid-worthy upgrade moved to prebake; runtime cache kept idle.
var _aabb_cache: Dictionary = {}  # String -> float


## Update camera position for NEAR-tier actor filtering
func set_camera_position(pos: Vector3) -> void:
	_instantiator.camera_position = pos


## Set the background processor to use for async loading
func set_background_processor(processor: Node) -> void:
	if _background_processor:
		var task_completed_signal: Signal = _background_processor.get("task_completed")
		if task_completed_signal and task_completed_signal.is_connected(_on_parse_completed):
			task_completed_signal.disconnect(_on_parse_completed)

	_background_processor = processor

	if _background_processor:
		var task_completed_signal: Signal = _background_processor.get("task_completed")
		if task_completed_signal:
			task_completed_signal.connect(_on_parse_completed)


## Check if there's capacity for more async requests
## Use this before calling request_exterior_cell_async to avoid fallback to sync
func has_async_capacity() -> bool:
	return _background_processor != null and _async_requests.size() < MAX_ASYNC_REQUESTS


## Set the interior_priority flag on all in-flight instantiation entries for
## the given async request. Called by InteriorPocketManager at the start of
## a transition so that the interior drains ahead of exterior streaming. A
## subsequent force_queue_resort() push the flagged entries to the tail.
func set_request_priority(request_id: int, priority: bool) -> void:
	if request_id in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]
		if request and request.load_profile:
			request.load_profile.interior_priority = priority
	for entry: InstantiationEntry in _instantiation_queue:
		if entry.request_id == request_id:
			entry.interior_priority = priority
			if entry.load_profile:
				entry.load_profile.interior_priority = priority


## Force an immediate queue re-sort. Use after mutating priority flags so
## the new order takes effect on the next _process_instantiation_queue pass.
func force_queue_resort() -> void:
	_sort_queue_by_priority()
	_queue_sort_frame = Engine.get_frames_drawn()


## Get the number of available async request slots
func get_async_slots_available() -> int:
	if not _background_processor:
		return 0
	return maxi(0, MAX_ASYNC_REQUESTS - _async_requests.size())


## Request async loading of an exterior cell
## Returns request_id for tracking, or -1 if async not available or at capacity
## `profile` — optional per-request override of instantiator defaults. Pass
## null (default) to use the shared instantiator flags (current behavior).
func request_exterior_cell_async(x: int, y: int, profile: LoadProfile = null) -> int:
	if not _background_processor:
		# Only warn once per session about missing processor
		if not _stats.get("_warned_no_processor", false):
			push_warning("CellManager: No background processor set, falling back to sync load")
			_stats["_warned_no_processor"] = true
		return -1

	# Check concurrent request limit - don't warn, caller should check has_async_capacity()
	if _async_requests.size() >= MAX_ASYNC_REQUESTS:
		return -1

	var cell_record: CellRecord = ESMManager.get_exterior_cell(x, y)
	if not cell_record:
		return -1

	return _start_async_request(cell_record, Vector2i(x, y), false, profile)


## Request async loading of an interior cell
## Returns request_id for tracking, or -1 if async not available or at capacity
## `profile` — per-request override. Interior pockets should pass
## `LoadProfile.interior_pocket()` so RS/static-renderer batching is disabled
## (RS instances render at ESM world position, not pocket offset).
func request_cell_async(cell_name: String, profile: LoadProfile = null) -> int:
	if not _background_processor:
		# Only warn once per session about missing processor
		if not _stats.get("_warned_no_processor", false):
			push_warning("CellManager: No background processor set, falling back to sync load")
			_stats["_warned_no_processor"] = true
		return -1

	# Check concurrent request limit - don't warn, caller should check has_async_capacity()
	if _async_requests.size() >= MAX_ASYNC_REQUESTS:
		return -1

	var cell_record: CellRecord = ESMManager.get_cell(cell_name)
	if not cell_record:
		return -1

	return _start_async_request(cell_record, Vector2i.ZERO, true, profile)


## Check if an async request is complete
func is_async_complete(request_id: int) -> bool:
	if request_id not in _async_requests:
		return true  # Not found = already completed or invalid
	var request: AsyncCellRequest = _async_requests.get(request_id)
	return request.completed if request else true


## Check if an async request has failed (some models couldn't be parsed)
func has_async_failed(request_id: int) -> bool:
	if request_id not in _async_requests:
		return false
	var request: AsyncCellRequest = _async_requests[request_id]
	return not request.failed_models.is_empty()


## Get the error message for a failed request
func get_async_error(request_id: int) -> String:
	if request_id not in _async_requests:
		return ""
	var request: AsyncCellRequest = _async_requests.get(request_id)
	return request.error_message if request else ""


## Get number of failed models in an async request
func get_async_failed_count(request_id: int) -> int:
	if request_id not in _async_requests:
		return 0
	var request: AsyncCellRequest = _async_requests[request_id]
	var failed_models_array: Array = request.failed_models
	return failed_models_array.size()


## Get the result of a completed async request
## Returns the cell Node3D, or null if not ready
func get_async_result(request_id: int) -> Node3D:
	if request_id not in _async_requests:
		return null

	var request: AsyncCellRequest = _async_requests[request_id]
	if not request.completed:
		return null

	# Remove from tracking and return result
	_async_requests.erase(request_id)
	return request.cell_node


## Get the cell node for an in-progress async request (for progressive loading)
## Returns the cell Node3D even if not complete - objects will appear as instantiated
## Returns null if request_id is invalid
func get_async_cell_node(request_id: int) -> Node3D:
	if request_id not in _async_requests:
		return null
	var request: AsyncCellRequest = _async_requests.get(request_id)
	return request.cell_node if request else null


## Re-queue proximity-deferred refs that are now within spawn distance.
## Called from `native_streaming_manager._update_loaded_cells` after the
## load/unload dispatch. Throttled to PROXIMITY_TICK_INTERVAL_MSEC so walking
## the deferred list is bounded (targets ~4 checks/sec = cheap even at 10k refs).
## Also drops entries whose request is gone (cell fully unloaded).
func tick_proximity_deferred(camera_pos: Vector3) -> void:
	var now_msec := Time.get_ticks_msec()
	if now_msec - _proximity_last_tick_msec < PROXIMITY_TICK_INTERVAL_MSEC:
		return
	_proximity_last_tick_msec = now_msec
	if _proximity_deferred.is_empty():
		return

	var threshold_sq: float = ReferenceInstantiator.INTERACTIVE_PROXIMITY_THRESHOLD_M * ReferenceInstantiator.INTERACTIVE_PROXIMITY_THRESHOLD_M
	var kept: Array[InstantiationEntry] = []
	var requeued: int = 0
	var dropped: int = 0
	for entry: InstantiationEntry in _proximity_deferred:
		# Drop entries whose request vanished (cell unloaded or finalized).
		if entry.request_id not in _async_requests:
			dropped += 1
			continue
		var request: AsyncCellRequest = _async_requests[entry.request_id]
		if not is_instance_valid(request.cell_node):
			dropped += 1
			# `pending_instantiations` gets resolved at cell-fail finalize.
			continue
		if entry.position.distance_squared_to(camera_pos) <= threshold_sq:
			_instantiation_queue.push_back(entry)
			requeued += 1
		else:
			kept.append(entry)
	# Rebuild to kept entries — avoid O(N²) from in-place remove.
	_proximity_deferred = kept
	if requeued > 0 or dropped > 0:
		Log.debug("streaming", "[proximity-tick] requeued=%d dropped=%d still_deferred=%d" % [
			requeued, dropped, _proximity_deferred.size()
		])


## Periodic dump of per-type instantiate breakdown. Logs every 5s when any
## instantiate activity happened in the window. Resets counters after dump.
func _maybe_log_per_type_breakdown() -> void:
	var now_msec := Time.get_ticks_msec()
	if _diag_per_type_last_log_msec == 0:
		_diag_per_type_last_log_msec = now_msec
		return
	if now_msec - _diag_per_type_last_log_msec < 5000:
		return
	_diag_per_type_last_log_msec = now_msec
	if _diag_per_type_count.is_empty():
		return
	# Sort by total time descending
	var entries: Array = []
	for t_name: String in _diag_per_type_time_us:
		var total_us: int = _diag_per_type_time_us[t_name]
		var count: int = _diag_per_type_count.get(t_name, 0)
		var avg_us: float = float(total_us) / float(count) if count > 0 else 0.0
		entries.append({"type": t_name, "total_ms": total_us / 1000.0, "count": count, "avg_us": avg_us})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["total_ms"] > b["total_ms"])
	var summary_parts: Array[String] = []
	for e: Dictionary in entries:
		summary_parts.append("%s(n=%d tot=%.1fms avg=%dµs)" % [e["type"], e["count"], e["total_ms"], int(e["avg_us"])])
	Log.info("streaming", "[inst-breakdown 5s] " + "  ".join(summary_parts))
	_diag_per_type_time_us.clear()
	_diag_per_type_count.clear()


## Cancel an async request — HARD cancel, destroys everything.
##
## Used by interior-pocket teardown where there is no unload-container limbo
## and no state-reversal path. Exterior cell unload DOES have state reversal
## (see `finalize_unloaded_cell` below) — don't use this from the exterior
## `_unload_cell` path, that would re-introduce the missing-objects-on-return
## bug (2026-04-19): filtering the queue during unload discards 100-300 pending
## instantiations per cell; reclaim then returns a half-populated cell_node.
func cancel_async_request(request_id: int) -> void:
	if request_id not in _async_requests:
		return

	var request: AsyncCellRequest = _async_requests[request_id]

	# Cancel pending parse tasks
	for task_id: int in request.pending_parses.values():
		_background_processor.call("cancel_task", task_id)

	# Remove all pending instantiations for this request from the queue
	# This prevents orphan objects when the cell is unloaded mid-loading
	var queue_before := _instantiation_queue.size()
	_instantiation_queue = _instantiation_queue.filter(
		func(entry: InstantiationEntry) -> bool: return entry.request_id != request_id
	)
	var removed := queue_before - _instantiation_queue.size()
	if removed > 0:
		# This is expected behavior when cells are unloaded mid-loading
		# Using print instead of push_warning since it's informational, not a problem
		Log.info("streaming", "CellManager: Cleaned up %d pending instantiations for unloaded cell (request %d)" % [removed, request_id])

	# Clean up cell node if started
	if request.cell_node:
		request.cell_node.queue_free()

	_async_requests.erase(request_id)


## Finalize an unloaded cell — SOFT cleanup after state-reversal window closes.
##
## Call when a cell's unload-container entry has fully drained to empty and the
## cell_node is being queue_free'd by `_process_budgeted_unloading`. Cleans up
## residual async request state WITHOUT touching cell_node (already dying on
## the caller's side) and WITHOUT any early queue filter (drain path's existing
## is_instance_valid guard handles orphaned entries).
##
## This is the exterior-cell counterpart to `cancel_async_request`. Canonical
## state-reversal pattern per UE5 World Partition + OpenMW UnrefQueue: keep
## request + queue intact through the unload-container limbo so reclaim can
## reverse the transition without losing pending instantiation work.
func finalize_unloaded_cell(request_id: int) -> void:
	if request_id not in _async_requests:
		return
	var request: AsyncCellRequest = _async_requests[request_id]
	# Cancel any still-in-flight parse tasks (cell's gone, results have no home).
	for task_id: int in request.pending_parses.values():
		_background_processor.call("cancel_task", task_id)
	# Filter any remaining queue entries for this request. Unlike the unload-
	# path filter (which was the bug), this runs AFTER the cell has truly died
	# and the state-reversal window is closed — no reclaim can use these.
	_instantiation_queue = _instantiation_queue.filter(
		func(entry: InstantiationEntry) -> bool: return entry.request_id != request_id
	)
	# Note: DON'T queue_free(request.cell_node) — caller (_process_budgeted_unloading)
	# owns the cell_node teardown and has already queue_free'd it.
	_async_requests.erase(request_id)


## Cancel async request by cell grid (useful when unloading cells)
func cancel_async_request_for_cell(grid: Vector2i) -> void:
	# Find and cancel any async request for this cell
	var request_ids_to_cancel: Array[int] = []
	for request_id: int in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]
		if not request.is_interior and request.grid == grid:
			request_ids_to_cancel.append(request_id)

	for request_id in request_ids_to_cancel:
		cancel_async_request(request_id)


## Process pending NIF conversions - DISABLED AT RUNTIME
## At runtime, all models should already be in disk cache from prebaking.
## This function is kept for prebaking tools but does nothing in runtime mode.
## Returns true if any conversions were done (always false in runtime mode)
func process_pending_conversions(_budget_ms: float) -> bool:
	# In runtime mode (world explorer), skip all conversion - models must be prebaked
	if _model_loader.runtime_mode:
		# Clear any pending conversions - they shouldn't exist in runtime mode
		if _pending_conversion_index < _pending_conversions.size():
			push_warning("CellManager: %d models queued for conversion but runtime_mode=true. Run prebaking first!" % (_pending_conversions.size() - _pending_conversion_index))
			_pending_conversions.clear()
			_pending_conversion_index = 0
		return false

	# PREBAKING MODE ONLY: Process conversions for prebaking tools
	if _pending_conversion_index >= _pending_conversions.size():
		return false

	var converted := 0

	while _pending_conversion_index < _pending_conversions.size() and converted < MAX_CONVERSIONS_PER_FRAME:
		var entry: Dictionary = _pending_conversions[_pending_conversion_index]
		_pending_conversion_index += 1
		var parse_result: NIFParseResult = entry.parse_result
		var model_path: String = entry.model_path
		var request_id: int = entry.request_id
		var item_id: String = entry.item_id

		# Check if request still exists
		if request_id not in _async_requests:
			continue

		var request: AsyncCellRequest = _async_requests[request_id]
		var prototype: Node3D = null

		# Perform the conversion (PREBAKING ONLY - can take 500ms-6s!)
		var converter := NIFConverter.new()
		prototype = converter.convert_from_parsed(parse_result)

		if prototype:
			# Add to memory cache AND disk cache (handled inside add_to_cache)
			_model_loader.add_to_cache(model_path, prototype, item_id)
			# NOW queue references for this model
			_queue_references_for_model(request, model_path)
		else:
			request.failed_models.append(model_path)
			# Still queue references - they'll get placeholders
			_queue_references_for_model(request, model_path)

		converted += 1

		# Check if request is now complete
		if _is_request_complete(request):
			_finalize_request(request)

	# Periodic cleanup of the queue
	if _pending_conversion_index >= _pending_conversions.size():
		_pending_conversions.clear()
		_pending_conversion_index = 0
	elif _pending_conversion_index > 50:
		_pending_conversions = _pending_conversions.slice(_pending_conversion_index)
		_pending_conversion_index = 0

	return converted > 0


## Process async disk loads - call this every frame to complete pending model loads
## budget_usec: time budget for PackedScene instantiation; 0 uses loader fallback.
## Returns number of models that finished loading this frame
func process_async_disk_loads(budget_usec: int = 0) -> int:
	return _model_loader.process_async_loads(budget_usec)


## Get count of pending async disk loads
func get_pending_disk_load_count() -> int:
	return _model_loader.get_pending_async_count()


## Process async instantiation within time budget (call from _process)
## Returns number of objects instantiated this frame
## Uses BOTH time budget AND object count cap for consistent frame times
## Objects sorted by frustum-aware priority - visible nearest objects first
##
## BURST LOADING: When objects are very close to camera (< NEAR_BURST_DISTANCE),
## uses higher budget and limits for faster cell population.
##
## Parameters:
##   budget_ms: Time budget in milliseconds (may be overridden by burst loading)
##   camera_pos: Camera position for priority sorting (optional, uses cached if not provided)
##   camera_fwd: Camera forward direction for frustum priority (optional)
func process_async_instantiation(budget_ms: float, camera_pos: Vector3 = Vector3.INF, camera_fwd: Vector3 = Vector3.INF) -> int:
	# Update camera position/forward if provided
	if camera_pos != Vector3.INF:
		_camera_position = camera_pos
	if camera_fwd != Vector3.INF:
		_camera_forward = camera_fwd

	# Start budget clock BEFORE pre-loop work — disk loads, conversions, and
	# pool prewarm all consume frame time that must count against the budget.
	# Without this, these operations can blow the budget before the main
	# instantiation loop even begins (root cause of 112ms frame overruns).
	var start_time := Time.get_ticks_usec()

	# First process any pending async disk loads, budgeted so they can't eat the
	# entire frame allocation before the main instantiation loop runs.
	# Half the caller budget: leaves the other half for _instantiation_queue items.
	process_async_disk_loads(int(budget_ms * 500.0))  # budget_ms*0.5 in usec

	# Then process any pending conversions to feed the cache
	# Cap conversion time to half the budget so instantiation still gets time
	var conversion_budget_ms := budget_ms * 0.5
	process_pending_conversions(conversion_budget_ms)

	# Process pool pre-warming in background (only if budget permits)
	var pre_loop_elapsed := float(Time.get_ticks_usec() - start_time) / 1000.0
	if pool_prewarm_enabled and pre_loop_elapsed < budget_ms * 0.7:
		_process_pool_prewarm()

	if _instantiation_queue.is_empty():
		return 0

	# Sort queue by priority periodically (not every frame - too expensive)
	var current_frame := Engine.get_frames_drawn()
	if current_frame - _queue_sort_frame >= QUEUE_SORT_INTERVAL:
		_queue_sort_frame = current_frame
		_sort_queue_by_priority()

	# BURST LOADING: Check if nearest objects are very close (critical loading)
	# If so, use aggressive budget to populate cells faster
	var effective_budget_ms := budget_ms
	var effective_max_instantiations := MAX_INSTANTIATIONS_PER_FRAME

	if not _instantiation_queue.is_empty():
		var last_entry: InstantiationEntry = _instantiation_queue[-1]
		var last_pos: Vector3 = last_entry.position
		var last_distance := _camera_position.distance_to(last_pos)

		if last_distance < _burst_distance:
			# Activate burst loading for nearby objects
			_burst_loading_active = true
			effective_budget_ms = _burst_budget_ms
			effective_max_instantiations = _burst_max_instantiations
		else:
			_burst_loading_active = false

	var budget_usec := effective_budget_ms * 1000.0
	var instantiated := 0
	var exit_reason := ""

	# Periodic per-type breakdown dump (every 5s). Answers "inside inst:, which
	# ref type dominates" with real data, not intuition.
	_maybe_log_per_type_breakdown()

	# Phase A — dispatch pass. Inert until PHASE_A_OFFTHREAD_INSTANTIATE flips
	# true in slice 5 (the drain lands alongside). The dispatcher iterates the
	# queue without popping; any cache-hit entry gets a WorkerThreadPool task
	# bound with (entry, packed_scene, base_record, type_name). The drain
	# (slice 5) checks entry.worker_instance before falling back to the
	# synchronous instantiate_reference call. Plan §3.1.
	if PHASE_A_OFFTHREAD_INSTANTIATE:
		_phase_a_dispatch_pass()

	# Batch children for deferred add_child (reduces scene tree churn)
	var pending_children: Array[Dictionary] = []  # {parent: Node3D, child: Node3D}

	while not _instantiation_queue.is_empty():
		# Check time budget
		var elapsed := Time.get_ticks_usec() - start_time
		if elapsed >= budget_usec:
			exit_reason = "time_budget"
			break

		# Check object count cap (critical for consistent frame times)
		if instantiated >= effective_max_instantiations:
			exit_reason = "object_cap"
			break

		var entry: InstantiationEntry = _instantiation_queue.pop_back()
		var request_id: int = entry.request_id
		var ref: CellReference = entry.ref
		var model_path: String = entry.model_path
		var item_id: String = entry.item_id

		# Check if request still exists
		if request_id not in _async_requests:
			continue

		var request: AsyncCellRequest = _async_requests[request_id]

		# CRITICAL: Check if cell_node is still valid (cell may have been unloaded)
		# This prevents crash when camera moves and cell is freed mid-instantiation
		if not is_instance_valid(request.cell_node):
			# Cell was unloaded, skip remaining items for this request
			request.pending_instantiations -= 1
			if _is_request_complete(request):
				request.completed = true
				request.failed = true
				request.error_message = "Cell node freed during instantiation"
			continue

		# Decrement pending count
		request.pending_instantiations -= 1

		# S.1 refactor (near_tier_refactor.md 2026-04-19): per-object distance +
		# tier branching removed. Cell-level tier is the axis of variation, not
		# per-object. If a cell is in the active set, every ref in it becomes a
		# Node3D — no defer queue, no MID RS instances, no "near:" RS shims.
		# MID / HLOD / impostor re-enable is driven by `request_cell_tier` in
		# phases S.7+. Until then, NEAR is the only tier and the only codepath.
		_instantiator._set_transient_profile(entry.load_profile)
		var inst_start := Time.get_ticks_usec()
		var inst_cell_grid: Vector2i = request.grid if not request.is_interior else Vector2i.ZERO
		var obj := _instantiator.instantiate_reference(ref, inst_cell_grid)
		var inst_elapsed := Time.get_ticks_usec() - inst_start
		_instantiator._clear_transient_profile()
		_diag_instantiate_time_total_us += inst_elapsed
		_diag_instantiate_count += 1
		# Per-type breakdown — direct attribution of inst: cost to specific ref types.
		var t_name: String = _instantiator.last_type_name
		if t_name.is_empty():
			t_name = "unknown"
		_diag_per_type_time_us[t_name] = _diag_per_type_time_us.get(t_name, 0) + inst_elapsed
		_diag_per_type_count[t_name] = _diag_per_type_count.get(t_name, 0) + 1

		# Lazy-spawn deferral — interactive ref too far, park it for later.
		# The reference_instantiator returned null without decrementing our
		# pending counter (see below). Push to the deferred list; it'll be
		# re-queued when the camera is within 80 m via tick_proximity_deferred.
		if obj == null and _instantiator.last_proximity_deferred:
			_proximity_deferred.append(entry)
			# Rewind the pending counter — this ref isn't instantiated OR failed,
			# it's paused. `_is_request_complete` must still see it as in-flight.
			request.pending_instantiations += 1
			continue

		if obj:
			# Override prebaked 0-500m VR (legacy MID-tier artifact) → 0-NEAR_END
			# so NEAR Node3Ds cull at 150m instead of bleeding to 500m. Without
			# this, every Node3D in cells 150m-350m draws at full cost (no MID
			# RS offload during NEAR-only mode). Restored 2026-04-19 after S.1
			# launch revealed the 35 fps mid-load regression. Stays even after
			# S.7 brings MID back — NEAR Node3Ds always cull at NEAR_END; MID
			# RS instances cover 150m+ via PrototypeRegistry.
			_apply_near_visibility_range(obj)
			obj.set_meta("visibility_prebaked", true)

			# Double-check parent is still valid before queuing (defensive)
			if is_instance_valid(request.cell_node):
				# Capture per-entry fade-in decision now so the pending_children
				# batch loop doesn't have to look up LoadProfile later.
				var entry_fade_in_decision: bool = _instantiator.enable_fade_in
				if entry.load_profile:
					entry_fade_in_decision = entry.load_profile.fade_in
				pending_children.append({
					"parent": request.cell_node,
					"child": obj,
					"fade_in": entry_fade_in_decision,
				})
				instantiated += 1
			else:
				obj.queue_free()

		# Check if this was the last reference — route through _finalize_request
		# so batching + GPU scene DB upload fire (inline `request.completed = true`
		# was a pre-existing bypass for content cells).
		if _is_request_complete(request):
			_finalize_request(request)

	# Batch add all children at once (significantly reduces scene tree overhead)
	# For large batches (>20), use call_deferred to spread work across frames
	const DEFERRED_THRESHOLD := 20
	var add_child_start := Time.get_ticks_usec()
	var use_deferred := pending_children.size() > DEFERRED_THRESHOLD
	CrashBreadcrumb.write("cm::batch_start", "n=%d deferred=%s" % [pending_children.size(), str(use_deferred)])
	for entry in pending_children:
		var parent: Node3D = entry.parent
		var child: Node3D = entry.child
		# Per-entry fade-in decision captured earlier (pre-batching loop).
		# Interior pockets flip this off because pocket geometry lives at
		# Y=-500 while loading and fading is invisible.
		var entry_fade_in: bool = entry.get("fade_in", _instantiator.enable_fade_in)
		if is_instance_valid(parent) and is_instance_valid(child):
			if use_deferred:
				parent.call_deferred("add_child", child)
				# Defer fade-in until child enters scene tree — SceneTreeTimer requires
				# an active scene_tree. Without this, material_override gets set to the
				# fade ShaderMaterial but no restoration timer is scheduled, leaving
				# objects stuck in the fade-in window indefinitely.
				if entry_fade_in:
					child.tree_entered.connect(
						func() -> void:
							if is_instance_valid(child):
								apply_fade_in_to_object(child),
						CONNECT_ONE_SHOT
					)
			else:
				parent.add_child(child)
				if entry_fade_in:
					apply_fade_in_to_object(child)
	CrashBreadcrumb.write("cm::batch_done", "n=%d" % pending_children.size())
	return instantiated


## Phase A — dispatch WorkerThreadPool tasks for every cache-hit entry that
## hasn't been dispatched yet. Runs ONCE per process_async_instantiation call,
## before the synchronous drain loop. No popping here — entries stay queued
## until the drain consumes them.
##
## Types excluded (no worker dispatch, synchronous path handles them):
##   light / npc / creature / leveled_creature / leveled_item — custom
##     _instantiate_light / _instantiate_actor path, not the cache-hit model
##     path. Slice 5's drain checks worker_instance; if null these fall
##     through to sync naturally.
##
## Runtime guard: PHASE_A_OFFTHREAD_INSTANTIATE gates the whole thing, so this
## code is inert until slice 5 flips the flag.
func _phase_a_dispatch_pass() -> void:
	if _instantiator == null:
		return
	var ml: RefCounted = _instantiator.model_loader
	if ml == null:
		return
	if not ml.has_method("get_cached_packed_scene"):
		return  # slice 3 API not present — defensive
	for entry: InstantiationEntry in _instantiation_queue:
		if entry.worker_dispatched:
			continue
		if entry.worker_instance != null:
			continue
		# Cache-peek first — cheapest gate, drops ~20% of entries (cache miss)
		# before we spend ESMManager time. get_cached_packed_scene returns null
		# on miss / null sentinel / non-PackedScene entry.
		var packed_scene: PackedScene = ml.call("get_cached_packed_scene", entry.model_path, entry.item_id)
		if packed_scene == null:
			continue
		# Resolve base_record + type_name on main thread — ESMManager is an
		# autoload and worker-unsafe per plan §5.1. Cheap (dict lookup).
		var record_type: Array = [""]
		var base_record: Variant = ESMManager.get_any_record(str(entry.ref.ref_id), record_type)
		if base_record == null:
			continue
		var type_name: String = record_type[0] if record_type.size() > 0 else ""
		# Type filter: lights / actors / leveled types don't go through the
		# _instantiate_model_object cache-hit path — skip worker dispatch for
		# them. The synchronous drain still handles them.
		match type_name:
			"light", "npc", "creature", "leveled_creature", "leveled_item":
				continue
		entry.worker_dispatched = true
		entry.worker_task_id = WorkerThreadPool.add_task(
			_instantiator._worker_instantiate.bind(entry, packed_scene, base_record, type_name),
			false,
			"cell_manager:phase_a_instantiate",
		)


## Sort instantiation queue by frustum-aware priority
## Objects in front of camera get priority; objects behind are deprioritized 4x
## Queue is sorted FARTHEST-first so pop_back() returns highest priority (nearest/in-frustum)
##
## PRIORITY LANE: Entries with `interior_priority == true` ALWAYS sort to the
## tail of the queue, ahead of every non-priority entry regardless of distance.
## Within the priority lane, existing distance/frustum ordering still applies.
## InteriorPocketManager flips this flag on all in-flight interior entries at
## the start of a transition so that the interior drains ahead of exterior
## streaming during the critical fade window.
func _sort_queue_by_priority() -> void:
	if _instantiation_queue.size() < 2:
		return

	var cam_pos := _camera_position
	var cam_fwd := _camera_forward

	# Pre-calculate priorities to avoid expensive lambda logic during sort
	# GDScript sort_custom is much faster with simple float comparisons
	var priorities := {} # entry -> float
	for entry in _instantiation_queue:
		var pos: Vector3 = entry.position
		var dist_sq := cam_pos.distance_squared_to(pos)

		if cam_fwd != Vector3.ZERO:
			var dir := (pos - cam_pos)
			# Frustum penalty: objects behind camera (dot < 0.3) get 4x distance penalty
			if dist_sq > 1.0 and cam_fwd.dot(dir) < 0.3 * dir.length():
				dist_sq *= 4.0

		priorities[entry] = dist_sq

	_instantiation_queue.sort_custom(func(a: InstantiationEntry, b: InstantiationEntry) -> bool:
		# PRIMARY KEY: priority lane. Non-priority entries come first (head
		# of the array); priority entries go to the tail so pop_back() takes
		# them first. Returning `false` when a is priority and b is not puts
		# a AFTER b; returning `true` when a is non-priority and b is priority
		# puts a BEFORE b.
		if a.interior_priority != b.interior_priority:
			return not a.interior_priority  # non-priority before priority
		# SECONDARY KEY: existing distance/frustum priority. Farthest first,
		# so pop_back() returns nearest/highest-priority within the lane.
		return priorities[a] > priorities[b]
	)


# =============================================================================
# POOL PRE-WARMING IMPLEMENTATION
# =============================================================================

## Queue models for pre-warming based on nearby objects
## Called when objects are registered with ObjectStreamer
func queue_prewarm(model_path: String, count: int = 1) -> void:
	if not pool_prewarm_enabled or not _object_pool:
		return

	var normalized := model_path.to_lower().replace("/", "\\")

	# Check if pool already has enough available
	if _object_pool.has_method("get_available_count"):
		var available: int = _object_pool.get_available_count(normalized)
		if available >= SC.POOL_PREWARM_MAX_PER_MODEL:
			return

	# Add to pending pre-warm
	var current: int = _prewarm_pending.get(normalized, 0)
	_prewarm_pending[normalized] = mini(current + count, SC.POOL_PREWARM_MAX_PER_MODEL)


## Process pool pre-warming within budget
func _process_pool_prewarm() -> void:
	if _prewarm_pending.is_empty() or not _object_pool:
		return

	var prewarmed := 0
	var to_remove: Array[String] = []

	for model_path: String in _prewarm_pending:
		if prewarmed >= _prewarm_per_frame:
			break

		var count: int = _prewarm_pending[model_path]
		var remaining := _prewarm_per_frame - prewarmed

		# Only pre-warm if pool has the model registered
		if _object_pool.has_method("prewarm"):
			var created: int = _object_pool.prewarm(model_path, mini(count, remaining))
			prewarmed += created

			if created >= count:
				to_remove.append(model_path)
			else:
				_prewarm_pending[model_path] = count - created

	# Remove completed entries
	for path in to_remove:
		_prewarm_pending.erase(path)


## Check if burst loading is currently active
func is_burst_loading() -> bool:
	return _burst_loading_active




## Internal: Start an async request
func _start_async_request(cell: CellRecord, grid: Vector2i, is_interior: bool, profile: LoadProfile = null) -> int:
	var request := AsyncCellRequest.new()
	request.cell_record = cell
	request.grid = grid
	request.is_interior = is_interior
	# Default to exterior profile if caller didn't provide one. Having a
	# non-null profile on every request simplifies _queue_instantiation and
	# _process_instantiation_queue (no null checks on the hot path).
	request.load_profile = profile if profile else LoadProfile.exterior_default()
	request.request_id = _next_async_id
	_next_async_id += 1

	# Create the cell node
	request.cell_node = Node3D.new()
	if is_interior:
		request.cell_node.name = cell.name.replace(" ", "_").replace(",", "")
	else:
		request.cell_node.name = "Cell_%d_%d" % [grid.x, grid.y]

	# Store request BEFORE processing so _queue_instantiation can find it
	_async_requests[request.request_id] = request

	# Collect all unique model paths that need loading
	var models_to_load: Dictionary = {}  # model_path -> {item_ids: Array}
	var disk_cache_hits := 0

	for ref: CellReference in cell.references:
		var record_type: Array = [""]
		var base_record: Variant = ESMManager.get_any_record(str(ref.ref_id), record_type)
		if not base_record:
			continue

		var type_name: String = record_type[0] if record_type.size() > 0 else ""

		# Skip types that don't use models or are disabled
		if type_name == "leveled_item":
			continue
		if type_name == "npc" and not load_npcs:
			continue
		if type_name == "creature" and not load_creatures:
			continue
		if type_name == "leveled_creature" and not load_creatures:
			continue

		var model_path: String = _get_model_path(base_record)
		if model_path.is_empty():
			# Light without model, or actor placeholder - queue for direct instantiation
			# NOTE: These must be queued immediately, NOT added to references_to_process
			# references_to_process is for refs waiting on async model parsing
			# If we add model-less refs there, they'll never be processed when all models
			# come from disk cache (no parsing = no _queue_references_for_model calls)
			_queue_instantiation(request.request_id, ref, "", "")
			continue

		var item_id: String = ""
		if "record_id" in base_record:
			item_id = base_record.record_id

		# Check if already in memory cache
		if _model_loader.has_model(model_path, item_id):
			# Already have this model, queue reference for instantiation
			_queue_instantiation(request.request_id, ref, model_path, item_id)
			continue

		# Check disk cache - if available, start ASYNC load (non-blocking!)
		if _model_loader.enable_disk_cache and _model_loader.has_disk_cached(model_path, item_id):
			# Track this reference as waiting for the model
			if model_path not in request.pending_disk_loads:
				request.pending_disk_loads[model_path] = []
			request.pending_disk_loads[model_path].append({"ref": ref, "item_id": item_id})

			# Start async load (or add callback to existing load)
			# request_model_async handles deduplication internally
			var callback := _make_disk_load_callback(request.request_id, model_path, item_id)
			_model_loader.request_model_async(model_path, item_id, callback)
			disk_cache_hits += 1
			continue

		# RUNTIME MODE: Skip models not in disk cache - they must be prebaked
		# No NIF conversion at runtime - only prebaking does conversion
		if _model_loader.runtime_mode:
			# Model not prebaked - skip this reference silently
			# (The prebaking UI will show which models are missing)
			continue

		# PREBAKING MODE ONLY: Need to load this model from BSA + convert NIF
		if model_path not in models_to_load:
			models_to_load[model_path] = {"item_ids": []}
		var item_ids_array: Array = models_to_load[model_path].item_ids
		if item_id and item_id not in item_ids_array:
			item_ids_array.append(item_id)

		# Queue reference for later (after model is parsed)
		request.references_to_process.append(ref)

	# Submit parse tasks for models that need loading
	for model_path: String in models_to_load:
		var model_info: Variant = models_to_load[model_path]
		var item_ids: Array = model_info.get("item_ids", []) if model_info is Dictionary else []
		var item_id: String = item_ids[0] if item_ids.size() > 0 else ""

		var task_id := _submit_parse_task(str(model_path), item_id, request.request_id)
		if task_id >= 0:
			request.pending_parses[model_path] = task_id

	request.started = true

	# Mark as complete if nothing to do (all models cached and instantiated)
	if _is_request_complete(request):
		_finalize_request(request)

	return request.request_id


## Internal: Submit a NIF parse task to background processor
## BSA extraction now happens ON THE WORKER THREAD to avoid main thread stalls
func _submit_parse_task(model_path: String, item_id: String, _request_id: int) -> int:
	# Build full path (this is just string manipulation, fast)
	var full_path := model_path
	if not model_path.to_lower().begins_with("meshes"):
		full_path = "meshes\\" + model_path

	# Check if file exists BEFORE submitting task (fast metadata check)
	# This avoids submitting tasks for non-existent files
	var actual_path := ""
	if BSAManager.has_file(full_path):
		actual_path = full_path
	elif BSAManager.has_file(model_path):
		actual_path = model_path

	if actual_path.is_empty():
		return -1

	# Submit task that does BOTH extraction AND parsing on worker thread
	# This moves the expensive I/O off the main thread entirely
	var task_id: int = _background_processor.call("submit_task", func() -> Variant:
		# BSA extraction now happens on worker thread!
		var nif_data: PackedByteArray = BSAManager.extract_file(actual_path)
		if nif_data.is_empty():
			return null
		return NIFConverter.parse_buffer_only(nif_data, actual_path, item_id)
	)

	return task_id


## Internal: Handle parse completion from background processor
func _on_parse_completed(task_id: int, result: Variant) -> void:
	# First check if this is a preload task
	if _check_preload_completion(task_id, result):
		return  # Was handled as preload

	# Find which cell request this belongs to
	for request_id: int in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]

		for model_path: String in request.pending_parses:
			if request.pending_parses[model_path] == task_id:
				# Found it - store result
				request.pending_parses.erase(model_path)

				var parse_success := false
				var convert_start := Time.get_ticks_usec()

				if result is NIFParseResult:
					var parse_result: NIFParseResult = result
					if parse_result.is_valid():
						request.parsed_results[model_path] = parse_result
						parse_success = true

						# DEFERRED CONVERSION: Queue for processing in process_pending_conversions()
						# This prevents 300ms-6s freezes when complex models finish parsing
						_pending_conversions.append({
							"parse_result": parse_result,
							"model_path": model_path,
							"request_id": request_id,
							"item_id": parse_result.item_id
						})
					else:
						# Parse returned invalid result
						request.failed_models.append(model_path)
				else:
					# Result wasn't a NIFParseResult (unexpected)
					request.failed_models.append(model_path)

				var convert_elapsed := (Time.get_ticks_usec() - convert_start) / 1000.0

				# NOTE: Conversion and reference queuing is now DEFERRED
				# See process_pending_conversions() which handles both
				# This prevents 300ms-6s freezes when complex models complete

				return


## Internal: Queue references that were waiting for a model to be parsed
func _queue_references_for_model(request: AsyncCellRequest, model_path: String) -> void:
	var remaining: Array = []

	for ref: CellReference in request.references_to_process:
		var record_type: Array = [""]
		var base_record: Variant = ESMManager.get_any_record(str(ref.ref_id), record_type)
		if not base_record:
			continue

		var ref_model_path: String = _get_model_path(base_record)
		var item_id: String = ""
		if "record_id" in base_record:
			item_id = base_record.record_id

		if ref_model_path.to_lower().replace("/", "\\") == model_path.to_lower().replace("/", "\\"):
			# This reference uses the model that was just parsed
			_queue_instantiation(request.request_id, ref, model_path, item_id)
		else:
			remaining.append(ref)

	request.references_to_process = remaining


## Internal: Check if an async request is complete
func _is_request_complete(request: AsyncCellRequest) -> bool:
	return request.pending_parses.is_empty() and request.pending_disk_loads.is_empty() and request.references_to_process.is_empty() and request.pending_instantiations <= 0


## Internal: Create a callback for async disk load completion
## This is called when ModelLoader finishes loading a model from disk cache
func _make_disk_load_callback(request_id: int, model_path: String, _item_id: String) -> Callable:
	return func(loaded_model_path: String, loaded_item_id: String, model: Node3D) -> void:
		_on_disk_load_completed(request_id, loaded_model_path, loaded_item_id, model)


## Internal: Handle async disk load completion
func _on_disk_load_completed(request_id: int, model_path: String, item_id: String, _model: Node3D) -> void:
	if request_id not in _async_requests:
		return  # Request was cancelled

	var request: AsyncCellRequest = _async_requests[request_id]

	# Check if cell_node is still valid (cell may have been unloaded)
	if not is_instance_valid(request.cell_node):
		request.pending_disk_loads.erase(model_path)
		if _is_request_complete(request):
			request.completed = true
			request.failed = true
			request.error_message = "Cell node freed during disk load"
		return

	# Get all references waiting for this model
	if model_path not in request.pending_disk_loads:
		return

	var waiting_refs: Array = request.pending_disk_loads[model_path]
	request.pending_disk_loads.erase(model_path)

	# Queue all waiting references for instantiation
	for ref_info: Dictionary in waiting_refs:
		var ref: CellReference = ref_info.ref
		var ref_item_id: String = ref_info.item_id
		_queue_instantiation(request_id, ref, model_path, ref_item_id)

	# Check if request is now complete
	if _is_request_complete(request):
		_finalize_request(request)


## Helper methods delegated to ReferenceInstantiator
## These are thin wrappers used by async loading code

func _get_model_path(record: Variant) -> String:
	return _instantiator._get_model_path(record)

func _apply_transform(node: Node3D, ref: CellReference, apply_model_rotation: bool) -> void:
	_instantiator._apply_transform(node, ref, apply_model_rotation)

func _create_placeholder(ref: CellReference) -> Node3D:
	return _instantiator._create_placeholder(ref)


# REMOVED: _instantiate_reference_from_parsed (duplicate fast-path).
# Streaming now routes directly through _instantiator.instantiate_reference()
# at the single call site in _process_instantiation_queue. The duplicate
# silently skipped DoorInteractable attach (I.7), carryable RigidBody
# conversion (I.1), _apply_metadata, and _auto_play_nif_animation — see
# the "Simplicity Over Over-Engineering" principle in .claude/CLAUDE.md
# for why two parallel instantiation paths is a drift landmine.


## Check if a cell reference must always use the NEAR (full Node3D) path
## Returns true for lights, NPCs, creatures — these need physics, interaction, or animation
## Internal: Finalize a request (mark completed). Phase 3 step 7 removed the
## per-cell MultiMesh batcher — MID instances are already routed through the
## world-scoped PrototypeRegistry at add-time by static_object_renderer.
func _finalize_request(request: AsyncCellRequest) -> void:
	if request.completed:
		return
	request.completed = true


## Internal: Queue an object for instantiation with limit checking
## Includes object position for distance-priority sorting
## S.1: queue-time classification (always_near / mid_worthy) removed — per-cell
## tier is the axis of variation, every queued ref becomes a Node3D.
func _queue_instantiation(request_id: int, ref: CellReference, model_path: String, item_id: String) -> bool:
	# Check queue limit to prevent memory buildup
	if _instantiation_queue.size() >= MAX_INSTANTIATION_QUEUE:
		push_warning("CellManager: Instantiation queue full (%d items), dropping object" % MAX_INSTANTIATION_QUEUE)
		return false

	# Get object position for distance-priority sorting
	var position := CS.vector_to_godot(ref.position)

	var entry := InstantiationEntry.new()
	entry.request_id = request_id
	entry.ref = ref
	entry.model_path = model_path
	entry.item_id = item_id
	entry.position = position

	# Copy the per-request LoadProfile onto the entry so the instantiation
	# queue processor can read it without a dictionary lookup, and so that
	# concurrent loads with different profiles don't collide on shared state.
	var owning_request: AsyncCellRequest = _async_requests.get(request_id) if request_id in _async_requests else null
	if owning_request and owning_request.load_profile:
		entry.load_profile = owning_request.load_profile
		entry.interior_priority = owning_request.load_profile.interior_priority

	_instantiation_queue.append(entry)

	# Track pending instantiation count for completion checking
	if owning_request:
		owning_request.pending_instantiations += 1

	return true


## Internal: Get cache key for a model
func _get_cache_key(model_path: String, item_id: String) -> String:
	var normalized := model_path.to_lower().replace("/", "\\")
	if not item_id.is_empty():
		return normalized + ":" + item_id.to_lower()
	return normalized


## Hide LOD sibling nodes and materialless meshes in a scene tree
## Calls MeshVisibilityUtils directly for consistent behavior
## CRITICAL: Must be called after every duplicate() to prevent white mesh overlays
func _hide_lod_nodes(node: Node) -> void:
	MeshVisibilityUtils.hide_lod_and_materialless(node)


## Get count of pending async requests
func get_async_pending_count() -> int:
	var count := 0
	for request_id: int in _async_requests:
		var request: AsyncCellRequest = _async_requests.get(request_id)
		if request and not request.completed:
			count += 1
	return count


## Get total objects waiting in instantiation queue
func get_instantiation_queue_size() -> int:
	return _instantiation_queue.size()


## Get comprehensive loading stats
func get_loading_stats() -> Dictionary:
	return {
		"instantiation_queue_size": _instantiation_queue.size(),
		"burst_loading_active": _burst_loading_active,
		"burst_budget_ms": _burst_budget_ms,
		"burst_max_instantiations": _burst_max_instantiations,
		"prewarm_pending_count": _prewarm_pending.size(),
		"objects_instantiated": int(_stats.get("objects_instantiated", 0)) + int(_instantiator.stats.get("objects_instantiated", 0)),
		"objects_from_pool": int(_stats.get("objects_from_pool", 0)) + int(_instantiator.stats.get("objects_from_pool", 0)),
		"avg_instantiate_time_us": (_diag_instantiate_time_total_us / _diag_instantiate_count) if _diag_instantiate_count > 0 else 0
	}


## Get overall stats including pool stats
func get_stats() -> Dictionary:
	var result := _stats.duplicate()

	# Merge instantiator stats. Post-drift-fix the instantiator owns the
	# objects_instantiated / objects_from_pool / lights_created counters for
	# the streaming queue path (Step 3 of _process_instantiation_queue).
	for key in ["objects_instantiated", "objects_from_pool", "lights_created"]:
		result[key] = int(result.get(key, 0)) + int(_instantiator.stats.get(key, 0))

	# Add pool stats if pool is available
	if _object_pool and _object_pool.has_method("get_stats"):
		var pool_stats: Dictionary = _object_pool.call("get_stats")
		result["pool_available"] = pool_stats.get("total_available", 0)
		result["pool_in_use"] = pool_stats.get("total_in_use", 0)
		result["pool_total_pools"] = pool_stats.get("total_pools", 0)
		result["pool_hit_rate"] = pool_stats.get("hit_rate", 0.0)
		result["pool_new_instances"] = pool_stats.get("new_instances_created", 0)
		result["pool_acquires"] = pool_stats.get("acquires", 0)
		result["pool_releases"] = pool_stats.get("releases", 0)

	return result


## Override VR on every GeometryInstance3D descendant to the NEAR range (~155m).
## Prebaked prototypes carry 0-500m (legacy MID-tier range artifact). NEAR Node3Ds
## must cull at NEAR_END so the visible disc follows the camera instead of bleeding
## to impostor range — this matters during the NEAR-only window AND post-S.7 when
## MID RS instances take over 150m+ via PrototypeRegistry.
func _apply_near_visibility_range(node: Node3D) -> void:
	for geo: Node in node.find_children("*", "GeometryInstance3D", true, false):
		var g := geo as GeometryInstance3D
		g.visibility_range_begin = 0.0
		g.visibility_range_end = DU.NEAR_END + DU.FADE_MARGIN_NEAR_LOD1
		g.visibility_range_begin_margin = 0.0
		g.visibility_range_end_margin = DU.FADE_MARGIN_NEAR_LOD1
		g.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
