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

# Model loader for NIF loading and caching
var _model_loader: ModelLoader = ModelLoader.new()

# Reference instantiator for creating Node3D objects from cell references
var _instantiator: ReferenceInstantiator = ReferenceInstantiator.new()

# Character factory for creating animated NPCs and creatures
# Use V2 factory for new animation system with IK, procedural animation, and LOD
var _character_factory: CharacterFactoryV2 = CharacterFactoryV2.new()

# Object pool for frequently used models
var _object_pool: RefCounted = null  # ObjectPool

# Static object renderer for fast flora rendering (uses RenderingServer directly)
var _static_renderer: Node = null  # StaticObjectRenderer

# ObjectStreamer for distance-based visibility and LOD management
var _object_distance_manager: Node3D = null  # ObjectStreamer

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
# MW units are roughly 1/128th of a meter, so radius 256 ~= 2 meters
const MW_LIGHT_SCALE: float = 1.0 / 70.0  # Tuned for visual appearance


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


## Set the ObjectStreamer for distance-based visibility and LOD
func set_object_streamer(streamer: Node3D) -> void:
	_object_distance_manager = streamer
	_sync_instantiator_config()


## Sync configuration to instantiator
func _sync_instantiator_config() -> void:
	# Set up character factory
	_character_factory.set_model_loader(_model_loader)

	# Configure instantiator
	_instantiator.model_loader = _model_loader
	_instantiator.object_pool = _object_pool
	_instantiator.static_renderer = _static_renderer
	_instantiator.character_factory = _character_factory
	_instantiator.object_distance_manager = _object_distance_manager
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

		# Phase 3: Instantiate remaining objects normally
		for ref: CellReference in instance_groups.get("individual_refs", []):
			var obj := _instantiator.instantiate_reference(ref, cell_grid)
			if obj:
				cell_node.add_child(obj)
				loaded += 1
			elif use_static_renderer and _static_renderer:
				static_count += 1
			else:
				failed += 1
	else:
		# Original path: no batching
		for ref: CellReference in cell.references:
			var obj := _instantiator.instantiate_reference(ref, cell_grid)
			if obj:
				cell_node.add_child(obj)
				loaded += 1
			elif use_static_renderer and _static_renderer:
				static_count += 1
			else:
				failed += 1

	var total_objects := loaded + static_count + multimesh_count
	print("CellManager: Loaded %d objects (%d individual, %d static, %d multimesh), %d failed" % [
		total_objects, loaded, static_count, multimesh_count, failed
	])
	_stats["multimesh_instances"] = _stats.get("multimesh_instances", 0) + multimesh_count

	return cell_node


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
			# Debug: Check if this is a significant object
			if _instantiator.is_significant_object(model_path):
				_debug_significant_count += 1
				if _debug_significant_count <= 5:
					print("[ODM-GROUP] Significant object for individual: %s in cell %s" % [
						model_path.get_file(), cell_grid
					])
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
		print("[ODM-GROUP] Cell %s: %d significant objects to instantiate individually" % [
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

		# Find first MeshInstance3D in prototype
		var mesh_instance: MeshInstance3D = _find_first_mesh_instance(prototype)
		if not mesh_instance or not mesh_instance.mesh:
			for candidate: Dictionary in candidates:
				var obj: Node3D = _instantiator.instantiate_reference(candidate.ref as CellReference)
				if obj:
					parent_node.add_child(obj)
			continue

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

		parent_node.add_child(mmi)
		total_count += count

		print("  MultiMesh: %d × %s" % [count, model_path.get_file()])

	return total_count


## Find first MeshInstance3D in a node hierarchy
func _find_first_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D

	for child in node.get_children():
		var found := _find_first_mesh_instance(child)
		if found:
			return found

	return null


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
				var initial_count: int = maxi(10, int(pool_size * 0.8))
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

		print("CellManager: Preloaded %d models from disk cache (%d not prebaked)" % [loaded, skipped])
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

	print("CellManager: Preloading %d models asynchronously..." % _preload_pending.size())


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
					_object_pool.call("register_model", model_path, prototype, 0, common_models.get(model_path, 50))
			else:
				_preload_failed += 1
		else:
			_preload_failed += 1
	else:
		_preload_failed += 1

	preload_progress.emit(_preload_loaded, _preload_total)

	if _preload_pending.is_empty():
		print("CellManager: Preload complete - %d loaded, %d failed" % [_preload_loaded, _preload_failed])
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

## Load cell reference data and register all objects as deferred with ObjectStreamer
## Does NOT instantiate Node3D objects - that happens when objects enter NEAR range
## Returns number of objects registered, or -1 on failure
func load_cell_deferred(x: int, y: int) -> int:
	var cell_record: CellRecord = ESMManager.get_exterior_cell(x, y)
	if not cell_record:
		return -1

	if not _object_distance_manager:
		push_warning("CellManager: Cannot load deferred - no ObjectStreamer set")
		return -1

	if not _object_distance_manager.has_method("register_deferred_object"):
		push_warning("CellManager: ObjectStreamer does not support deferred registration")
		return -1

	var cell_grid := Vector2i(x, y)
	var registered := 0

	for ref: CellReference in cell_record.references:
		# Get base record and type
		var record_type: Array = [""]
		var base_record: Variant = ESMManager.get_any_record(str(ref.ref_id), record_type)
		if not base_record:
			continue

		var type_name: String = record_type[0] if record_type.size() > 0 else ""

		# Skip types that don't work with deferred loading
		if type_name == "light":
			continue  # Lights need special handling
		if type_name == "leveled_item":
			continue  # Leveled items need resolution
		if type_name == "npc" and not load_npcs:
			continue
		if type_name == "creature" and not load_creatures:
			continue
		if type_name == "leveled_creature" and not load_creatures:
			continue

		# Get model path
		var model_path: String = _get_model_path(base_record)
		if model_path.is_empty():
			continue

		# Skip models that would use static renderer (already optimized differently)
		if use_static_renderer and _static_renderer and _instantiator._is_static_render_model(model_path):
			continue

		# Calculate world position and rotation
		var world_position: Vector3 = CS.vector_to_godot(ref.position)
		var rotation: Vector3 = ref.rotation  # Store raw ESM rotation for later conversion
		var scale_factor: Vector3 = CS.scale_to_godot(ref.scale)

		# Register with ODM as deferred
		var object_id: int = _object_distance_manager.register_deferred_object(
			model_path,
			world_position,
			rotation,
			scale_factor,
			cell_grid,
			str(ref.ref_id),
			ref.ref_num
		)

		if object_id >= 0:
			registered += 1

	return registered


## Get cell references for deferred loading (without instantiation)
## Used by WorldStreamingManager to get reference data for deferred registration
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
			_stats["objects_from_pool"] += 1
			return pooled

	# Load or get cached model
	var model_prototype: Node3D = _model_loader.get_model(model_path, record_id)
	if not model_prototype:
		return null

	# Create instance
	var instance: Node3D = model_prototype.duplicate()
	instance.name = ref_id + "_" + str(ref_num)
	instance.global_transform = world_transform

	# Add metadata for console object picker
	if base_record:
		if "record_id" in base_record:
			instance.set_meta("form_id", base_record.record_id)
		instance.set_meta("ref_id", ref_id)
		instance.set_meta("ref_num", ref_num)
		instance.set_meta("model_path", model_path)

	_stats["objects_instantiated"] += 1

	# Apply fade-in effect if enabled
	if _instantiator.enable_fade_in:
		_instantiator._apply_fade_in(instance)

	return instance


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
var _diag_duplicate_time_total_us: int = 0
var _diag_duplicate_count: int = 0
var _diag_last_log_frame: int = 0

## Queue for pending NIF conversions (deferred to avoid main thread stall)
## Each entry: {parse_result: NIFParseResult, model_path: String, request_id: int, item_id: String}
var _pending_conversions: Array[Dictionary] = []

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
# PARALLEL DUPLICATE (WorkerThreadPool)
# =============================================================================

## Enable parallel duplicate() for faster instantiation
var parallel_duplicate_enabled: bool = SC.PARALLEL_DUPLICATE_ENABLED

## Results from parallel duplicate tasks (thread-safe queue)
## Each entry: {instance: Node3D, request_id: int, transform_data: Dictionary, model_path: String, name: String, cell_node: Node3D}
## Note: We store transform_data instead of ref to avoid RefCounted lifetime issues across threads
var _parallel_duplicate_results: Array = []
var _parallel_duplicate_mutex: Mutex = Mutex.new()

## Active parallel duplicate task count
var _parallel_duplicate_active: int = 0

## Pending parallel duplicate requests (waiting for task slot)
## Each entry: {prototype: Node3D, request_id: int, ref: CellReference, model_path: String, item_id: String}
var _parallel_duplicate_pending: Array = []

## Statistics for parallel duplicate diagnostics
var _parallel_duplicate_stats: Dictionary = {
	"dispatched": 0,
	"completed": 0,
	"failed_cell_freed": 0,
	"failed_instance_invalid": 0,
	"failed_duplicate_error": 0,
	"total_dispatch_time_usec": 0,
	"total_process_time_usec": 0,
}

# =============================================================================
# POOL PRE-WARMING
# =============================================================================

## Enable pool pre-warming when objects are discovered near player
var pool_prewarm_enabled: bool = SC.POOL_PREWARM_ENABLED

## Models pending pre-warm: model_path -> count needed
var _prewarm_pending: Dictionary = {}

## Pre-warm budget per frame
var _prewarm_per_frame: int = SC.POOL_PREWARM_MAX_PER_FRAME

## Async cell request tracking
class AsyncCellRequest:
	var cell_record: CellRecord
	var grid: Vector2i  # For exterior cells
	var is_interior: bool
	var request_id: int
	var pending_parses: Dictionary = {}  # model_path -> task_id
	var pending_disk_loads: Dictionary = {}  # model_path -> Array[CellReference] (refs waiting for this model)
	var parsed_results: Dictionary = {}  # model_path -> NIFParseResult
	var references_to_process: Array = []  # CellReference objects awaiting instantiation
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
var _async_requests: Dictionary = {}  # request_id -> AsyncCellRequest

## BackgroundProcessor reference (must be set via set_background_processor)
var _background_processor: Node = null

## Instantiation queue for time-budgeted processing
## Entries include position for distance-priority sorting
var _instantiation_queue: Array = []  # Array of {request_id, ref, model_path, position}

## Camera position for distance-based prioritization
var _camera_position: Vector3 = Vector3.ZERO

## Frame counter for periodic queue re-sorting
var _queue_sort_frame: int = 0
const QUEUE_SORT_INTERVAL: int = 10  # Re-sort every N frames

## Parsed model prototypes waiting to be cached (from async results)
var _pending_prototype_cache: Dictionary = {}  # cache_key -> NIFParseResult


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


## Request async loading of an exterior cell
## Returns request_id for tracking, or -1 if async not available or at capacity
func request_exterior_cell_async(x: int, y: int) -> int:
	if not _background_processor:
		push_warning("CellManager: No background processor set, falling back to sync load")
		return -1

	# Check concurrent request limit
	if _async_requests.size() >= MAX_ASYNC_REQUESTS:
		push_warning("CellManager: Async request limit reached (%d), rejecting cell (%d, %d)" % [MAX_ASYNC_REQUESTS, x, y])
		return -1

	var cell_record: CellRecord = ESMManager.get_exterior_cell(x, y)
	if not cell_record:
		return -1

	return _start_async_request(cell_record, Vector2i(x, y), false)


## Request async loading of an interior cell
## Returns request_id for tracking, or -1 if async not available or at capacity
func request_cell_async(cell_name: String) -> int:
	if not _background_processor:
		push_warning("CellManager: No background processor set, falling back to sync load")
		return -1

	# Check concurrent request limit
	if _async_requests.size() >= MAX_ASYNC_REQUESTS:
		push_warning("CellManager: Async request limit reached (%d), rejecting cell '%s'" % [MAX_ASYNC_REQUESTS, cell_name])
		return -1

	var cell_record: CellRecord = ESMManager.get_cell(cell_name)
	if not cell_record:
		return -1

	return _start_async_request(cell_record, Vector2i.ZERO, true)


## Check if an async request is complete
func is_async_complete(request_id: int) -> bool:
	if request_id not in _async_requests:
		return true  # Not found = already completed or invalid
	return _async_requests[request_id].completed


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
	return _async_requests[request_id].error_message


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
	return _async_requests[request_id].cell_node


## Cancel an async request
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
		func(entry: Dictionary) -> bool: return entry.request_id != request_id
	)
	var removed := queue_before - _instantiation_queue.size()
	if removed > 0:
		# This is expected behavior when cells are unloaded mid-loading
		# Using print instead of push_warning since it's informational, not a problem
		print("CellManager: Cleaned up %d pending instantiations for unloaded cell (request %d)" % [removed, request_id])

	# Clean up cell node if started
	if request.cell_node:
		request.cell_node.queue_free()

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
		if not _pending_conversions.is_empty():
			push_warning("CellManager: %d models queued for conversion but runtime_mode=true. Run prebaking first!" % _pending_conversions.size())
			_pending_conversions.clear()
		return false

	# PREBAKING MODE ONLY: Process conversions for prebaking tools
	if _pending_conversions.is_empty():
		return false

	var converted := 0

	while not _pending_conversions.is_empty() and converted < MAX_CONVERSIONS_PER_FRAME:
		var entry: Dictionary = _pending_conversions.pop_front()
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
			request.completed = true

	return converted > 0


## Process async disk loads - call this every frame to complete pending model loads
## Returns number of models that finished loading this frame
func process_async_disk_loads() -> int:
	return _model_loader.process_async_loads()


## Get count of pending async disk loads
func get_pending_disk_load_count() -> int:
	return _model_loader.get_pending_async_count()


## Process async instantiation within time budget (call from _process)
## Returns number of objects instantiated this frame
## Uses BOTH time budget AND object count cap for consistent frame times
## Objects are sorted by distance to camera - nearest objects instantiate first
##
## BURST LOADING: When objects are very close to camera (< NEAR_BURST_DISTANCE),
## uses higher budget and limits for faster cell population.
##
## PARALLEL DUPLICATE: When enabled and queue is large enough, uses WorkerThreadPool
## to duplicate prototypes on worker threads, reducing main thread stalls.
##
## Parameters:
##   budget_ms: Time budget in milliseconds (may be overridden by burst loading)
##   camera_pos: Camera position for distance-priority sorting (optional, uses cached if not provided)
func process_async_instantiation(budget_ms: float, camera_pos: Vector3 = Vector3.INF) -> int:
	# Update camera position if provided
	if camera_pos != Vector3.INF:
		_camera_position = camera_pos

	# First process any pending async disk loads (non-blocking check)
	process_async_disk_loads()

	# Then process any pending conversions to feed the cache
	process_pending_conversions(MAX_CONVERSION_TIME_MS)

	# Process completed parallel duplicate results first (these are ready to add)
	var parallel_added := _process_parallel_duplicate_results()

	# Process pool pre-warming in background
	if pool_prewarm_enabled:
		_process_pool_prewarm()

	if _instantiation_queue.is_empty():
		return parallel_added

	# Sort queue by distance periodically (not every frame - too expensive)
	var current_frame := Engine.get_frames_drawn()
	if current_frame - _queue_sort_frame >= QUEUE_SORT_INTERVAL:
		_queue_sort_frame = current_frame
		_sort_queue_by_distance()

	# BURST LOADING: Check if nearest objects are very close (critical loading)
	# If so, use aggressive budget to populate cells faster
	var effective_budget_ms := budget_ms
	var effective_max_instantiations := MAX_INSTANTIATIONS_PER_FRAME

	if not _instantiation_queue.is_empty():
		var first_entry: Dictionary = _instantiation_queue[0]
		var first_pos: Vector3 = first_entry.get("position", Vector3.ZERO)
		var first_distance := _camera_position.distance_to(first_pos)

		if first_distance < _burst_distance:
			# Activate burst loading for nearby objects
			_burst_loading_active = true
			effective_budget_ms = _burst_budget_ms
			effective_max_instantiations = _burst_max_instantiations
		else:
			_burst_loading_active = false

	var start_time := Time.get_ticks_usec()
	var budget_usec := effective_budget_ms * 1000.0
	var instantiated := parallel_added
	var exit_reason := ""

	# PARALLEL DUPLICATE: If queue is large and parallel enabled, dispatch to workers
	if parallel_duplicate_enabled and _instantiation_queue.size() >= SC.PARALLEL_DUPLICATE_MIN_BATCH:
		var dispatched := _dispatch_parallel_duplicates(effective_max_instantiations - instantiated)
		if dispatched > 0:
			# Some work dispatched to workers, continue with remaining budget
			pass

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

		var entry: Dictionary = _instantiation_queue.pop_front()
		var request_id: int = entry.request_id
		var ref: CellReference = entry.ref
		var model_path: String = entry.model_path
		var item_id: String = entry.get("item_id", "")

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

		# Instantiate this reference (this contains the expensive duplicate() call)
		var inst_start := Time.get_ticks_usec()
		var obj := _instantiate_reference_from_parsed(ref, model_path, item_id, request)
		var inst_elapsed := Time.get_ticks_usec() - inst_start

		# Track duplicate time for diagnostics
		_diag_duplicate_time_total_us += inst_elapsed
		_diag_duplicate_count += 1

		if obj:
			# Double-check parent is still valid before queuing (defensive)
			if is_instance_valid(request.cell_node):
				pending_children.append({"parent": request.cell_node, "child": obj})
				instantiated += 1
			else:
				# Parent was freed, clean up the orphan object
				obj.queue_free()

		# Check if this was the last reference
		if _is_request_complete(request):
			request.completed = true

	# Batch add all children at once (significantly reduces scene tree overhead)
	# Using call_deferred spreads the work across frames for very large batches
	var add_child_start := Time.get_ticks_usec()
	for entry in pending_children:
		var parent: Node3D = entry.parent
		var child: Node3D = entry.child
		if is_instance_valid(parent) and is_instance_valid(child):
			parent.add_child(child)
	return instantiated


## Sort instantiation queue by distance to camera (nearest first)
## Uses squared distance for performance (avoids sqrt)
func _sort_queue_by_distance() -> void:
	if _instantiation_queue.size() < 2:
		return

	var cam_pos := _camera_position
	_instantiation_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pos_a: Vector3 = a.get("position", Vector3.ZERO)
		var pos_b: Vector3 = b.get("position", Vector3.ZERO)
		var dist_sq_a := cam_pos.distance_squared_to(pos_a)
		var dist_sq_b := cam_pos.distance_squared_to(pos_b)
		return dist_sq_a < dist_sq_b  # Nearest first
	)


# =============================================================================
# PARALLEL DUPLICATE IMPLEMENTATION
# =============================================================================

## Dispatch duplicate tasks to WorkerThreadPool
## Returns number of tasks dispatched
func _dispatch_parallel_duplicates(max_count: int) -> int:
	if _parallel_duplicate_active >= SC.PARALLEL_DUPLICATE_MAX_TASKS:
		return 0  # Already at capacity

	var dispatched := 0
	var available_slots := SC.PARALLEL_DUPLICATE_MAX_TASKS - _parallel_duplicate_active

	while dispatched < mini(max_count, available_slots) and not _instantiation_queue.is_empty():
		var entry: Dictionary = _instantiation_queue.pop_front()
		var request_id: int = entry.request_id
		var ref: CellReference = entry.ref
		var model_path: String = entry.model_path
		var item_id: String = entry.get("item_id", "")

		# Check if request still exists
		if request_id not in _async_requests:
			continue

		var request: AsyncCellRequest = _async_requests[request_id]

		# Check if cell_node is still valid
		if not is_instance_valid(request.cell_node):
			request.pending_instantiations -= 1
			if _is_request_complete(request):
				request.completed = true
				request.failed = true
				request.error_message = "Cell node freed during parallel dispatch"
			continue

		# Get the model prototype (must be done on main thread)
		var cache_key := _get_cache_key(model_path, item_id)
		var model_prototype: Node3D = null

		# Try object pool first
		if use_object_pool and _object_pool and not model_path.is_empty():
			var pooled: Node3D = _object_pool.call("acquire", model_path)
			if pooled:
				# Got from pool - no need to duplicate, add directly
				var pool_name := str(ref.ref_id) + "_" + str(ref.ref_num)
				pooled.name = pool_name
				_apply_transform(pooled, ref, true)
				_stats["objects_from_pool"] = _stats.get("objects_from_pool", 0) + 1

				# Add to results directly (already done on main thread)
				# Mark as from_pool so we don't increment "completed" counter for worker tasks
				# Use cell_node_id for consistency with worker thread path
				var pool_cell_id: int = request.cell_node.get_instance_id() if request.cell_node else 0
				_parallel_duplicate_mutex.lock()
				_parallel_duplicate_results.append({
					"instance": pooled,
					"request_id": request_id,
					"transform_data": {},  # Already applied above, empty to skip re-apply
					"model_path": model_path,
					"cell_node_id": pool_cell_id,
					"name": pool_name,
					"from_pool": true
				})
				_parallel_duplicate_mutex.unlock()
				dispatched += 1
				continue

		# Get from cache
		model_prototype = _model_loader.get_cached(model_path, item_id)
		if not model_prototype:
			# Model not in cache - fall back to sync path
			model_prototype = _model_loader.get_model(model_path, item_id)
			if not model_prototype:
				request.pending_instantiations -= 1
				continue

		# Auto-register with object pool if available (on-demand pooling)
		# This enables pooling even without explicit preload_common_models() call
		if use_object_pool and _object_pool and not model_path.is_empty():
			if not _object_pool.call("has_model", model_path):
				# Register with default pool size - pool will grow as needed
				_object_pool.call("register_model", model_path, model_prototype, 0, 50)

		# Dispatch duplicate() to worker thread
		_parallel_duplicate_active += 1
		var dispatch_start := Time.get_ticks_usec()

		# Capture variables for closure - extract transform data BEFORE dispatching
		# This avoids RefCounted lifetime issues with CellReference across threads
		# IMPORTANT: Capture cell_node_id instead of cell_node to avoid crash if cell is freed
		# before the worker thread completes. We look up the node by ID on the main thread.
		var cell_node: Node3D = request.cell_node
		var cell_node_id: int = cell_node.get_instance_id() if cell_node else 0
		var instance_name := str(ref.ref_id) + "_" + str(ref.ref_num)
		var transform_data := {
			"position": ref.position,
			"rotation": ref.rotation,
			"scale": ref.scale,
		}

		# Capture model_prototype instance ID instead of the node itself
		# This prevents crashes if the model cache is cleared during the async operation
		var prototype_id: int = model_prototype.get_instance_id() if model_prototype else 0

		WorkerThreadPool.add_task(func():
			# This runs on worker thread - duplicate the prototype
			# Resource paths are cleared in ModelLoader._load_from_disk_cache() so duplicates
			# don't conflict on the same paths
			var task_start := Time.get_ticks_usec()
			var instance: Node3D = null
			var success := true

			# Look up prototype by ID - safe if node was freed
			var prototype: Node3D = instance_from_id(prototype_id) as Node3D if prototype_id != 0 else null
			if prototype:
				instance = prototype.duplicate()
				if instance:
					instance.name = instance_name
				else:
					success = false
			else:
				success = false

			# Store result for main thread to process
			# NOTE: We store cell_node_id instead of cell_node to avoid lambda capture crash
			_parallel_duplicate_mutex.lock()
			if success and instance:
				_parallel_duplicate_results.append({
					"instance": instance,
					"request_id": request_id,
					"transform_data": transform_data,
					"model_path": model_path,
					"cell_node_id": cell_node_id,
					"name": instance_name
				})
			else:
				_parallel_duplicate_stats["failed_duplicate_error"] += 1
			_parallel_duplicate_active -= 1
			_parallel_duplicate_stats["total_dispatch_time_usec"] += Time.get_ticks_usec() - task_start
			_parallel_duplicate_mutex.unlock()
		)

		_parallel_duplicate_stats["dispatched"] += 1

		dispatched += 1

	return dispatched


## Process completed parallel duplicate results
## Returns number of objects added to scene
func _process_parallel_duplicate_results() -> int:
	var process_start := Time.get_ticks_usec()

	_parallel_duplicate_mutex.lock()
	var results := _parallel_duplicate_results.duplicate()
	_parallel_duplicate_results.clear()
	_parallel_duplicate_mutex.unlock()

	if results.is_empty():
		return 0

	var added := 0
	for result: Dictionary in results:
		var instance: Node3D = result.get("instance")
		var request_id: int = result.get("request_id", -1)
		var transform_data: Dictionary = result.get("transform_data", {})
		var cell_node_id: int = result.get("cell_node_id", 0)

		# Validate instance is still valid (could have been freed if duplicate failed)
		if not is_instance_valid(instance):
			_parallel_duplicate_stats["failed_instance_invalid"] += 1
			continue

		# Look up cell_node from instance ID (avoids lambda capture crash)
		var cell_node: Node3D = null
		if cell_node_id != 0:
			cell_node = instance_from_id(cell_node_id) as Node3D

		# Validate cell_node is still valid
		if not is_instance_valid(cell_node):
			instance.queue_free()
			_parallel_duplicate_stats["failed_cell_freed"] += 1
			continue

		# Validate request still exists
		if request_id in _async_requests:
			var request: AsyncCellRequest = _async_requests[request_id]
			request.pending_instantiations -= 1

			if _is_request_complete(request):
				request.completed = true

		# Apply transform from stored data (instead of ref)
		# This matches _apply_transform but uses stored Dictionary instead of CellReference
		if not transform_data.is_empty():
			instance.position = CS.vector_to_godot(transform_data.get("position", Vector3.ZERO))
			instance.scale = CS.scale_to_godot(transform_data.get("scale", 1.0))
			instance.basis = CS.esm_rotation_to_godot_basis(transform_data.get("rotation", Vector3.ZERO))

		# Set pool metadata so object can be returned to pool when cell is unloaded
		var model_path: String = result.get("model_path", "")
		if use_object_pool and _object_pool and not model_path.is_empty():
			var normalized := model_path.to_lower().replace("/", "\\")
			instance.set_meta("pool_model_path", normalized)

		# Add to scene
		cell_node.add_child(instance)
		added += 1

		_stats["objects_instantiated"] += 1
		_diag_duplicate_count += 1

		# Only count as "completed" if this was an actual worker thread duplicate, not from pool
		if not result.get("from_pool", false):
			_parallel_duplicate_stats["completed"] += 1

	_parallel_duplicate_stats["total_process_time_usec"] += Time.get_ticks_usec() - process_start
	return added


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


## Get parallel duplicate stats
func get_parallel_duplicate_stats() -> Dictionary:
	var stats := {
		"active_tasks": _parallel_duplicate_active,
		"pending_results": _parallel_duplicate_results.size(),
		"enabled": parallel_duplicate_enabled,
		# Detailed stats
		"dispatched": _parallel_duplicate_stats.get("dispatched", 0),
		"completed": _parallel_duplicate_stats.get("completed", 0),
		"failed_cell_freed": _parallel_duplicate_stats.get("failed_cell_freed", 0),
		"failed_instance_invalid": _parallel_duplicate_stats.get("failed_instance_invalid", 0),
		"failed_duplicate_error": _parallel_duplicate_stats.get("failed_duplicate_error", 0),
	}

	# Calculate averages
	var dispatched: int = _parallel_duplicate_stats.get("dispatched", 0)
	if dispatched > 0:
		stats["avg_dispatch_time_us"] = _parallel_duplicate_stats.get("total_dispatch_time_usec", 0) / dispatched
	else:
		stats["avg_dispatch_time_us"] = 0

	var completed: int = _parallel_duplicate_stats.get("completed", 0)
	if completed > 0:
		stats["avg_process_time_us"] = _parallel_duplicate_stats.get("total_process_time_usec", 0) / completed
	else:
		stats["avg_process_time_us"] = 0

	# Success rate
	var failed_cell: int = stats["failed_cell_freed"]
	var failed_instance: int = stats["failed_instance_invalid"]
	var failed_dup: int = stats["failed_duplicate_error"]
	var total_finished: int = completed + failed_cell + failed_instance + failed_dup
	if total_finished > 0:
		stats["success_rate"] = float(completed) / float(total_finished)
	else:
		stats["success_rate"] = 1.0

	return stats


## Internal: Start an async request
func _start_async_request(cell: CellRecord, grid: Vector2i, is_interior: bool) -> int:
	var request := AsyncCellRequest.new()
	request.cell_record = cell
	request.grid = grid
	request.is_interior = is_interior
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
		var item_ids: Array = model_info.item_ids if model_info is Dictionary else []
		var item_id: String = item_ids[0] if item_ids.size() > 0 else ""

		var task_id := _submit_parse_task(str(model_path), item_id, request.request_id)
		if task_id >= 0:
			request.pending_parses[model_path] = task_id

	request.started = true

	# Mark as complete if nothing to do (all models cached and instantiated)
	if _is_request_complete(request):
		request.completed = true

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
		request.completed = true


## Helper methods delegated to ReferenceInstantiator
## These are thin wrappers used by async loading code

func _get_model_path(record: Variant) -> String:
	return _instantiator._get_model_path(record)

func _apply_transform(node: Node3D, ref: CellReference, apply_model_rotation: bool) -> void:
	_instantiator._apply_transform(node, ref, apply_model_rotation)

func _create_placeholder(ref: CellReference) -> Node3D:
	return _instantiator._create_placeholder(ref)


## Internal: Instantiate a reference from parsed data
func _instantiate_reference_from_parsed(ref: CellReference, model_path: String, item_id: String, request: AsyncCellRequest) -> Node3D:
	# Handle model-less references (lights without models, etc.)
	# These were queued with empty model_path and should use the instantiator directly
	if model_path.is_empty():
		var cell_grid := request.grid if not request.is_interior else Vector2i.ZERO
		return _instantiator.instantiate_reference(ref, cell_grid)

	# Get the cached model prototype
	var cache_key := _get_cache_key(model_path, item_id)

	# Try object pool first
	if use_object_pool and _object_pool and not model_path.is_empty():
		var pooled: Node3D = _object_pool.call("acquire", model_path)
		if pooled:
			pooled.name = str(ref.ref_id) + "_" + str(ref.ref_num)
			_apply_transform(pooled, ref, true)
			_stats["objects_from_pool"] = _stats.get("objects_from_pool", 0) + 1
			return pooled

	# Get from cache (async system should have already cached this)
	var model_prototype: Node3D = _model_loader.get_cached(model_path, item_id)
	if not model_prototype:
		# Model not in cache - use full instantiator path which can load from disk
		var cell_grid := request.grid if not request.is_interior else Vector2i.ZERO
		return _instantiator.instantiate_reference(ref, cell_grid)

	# Create instance
	var instance: Node3D = model_prototype.duplicate()
	instance.name = str(ref.ref_id) + "_" + str(ref.ref_num)

	# Check if this is a light record - needs OmniLight3D in addition to model
	var record_type: Array = [""]
	var base_record: Variant = ESMManager.get_any_record(str(ref.ref_id), record_type)
	if base_record and record_type[0] == "light":
		var light_record: LightRecord = base_record as LightRecord
		if light_record:
			# Wrap model in container and add light
			var container := Node3D.new()
			container.name = instance.name
			instance.name = "Model"
			container.add_child(instance)

			# Create the actual light source (same logic as _instantiate_light)
			if create_lights and light_record.radius > 0 and not light_record.is_off_by_default():
				var omni := OmniLight3D.new()
				omni.name = "Light"
				omni.omni_range = light_record.radius * MW_LIGHT_SCALE
				omni.light_color = light_record.color
				if light_record.is_negative():
					omni.light_negative = true
				omni.light_energy = 1.0 if light_record.is_fire() else 0.8
				omni.shadow_enabled = light_record.is_dynamic()
				omni.omni_attenuation = 1.0
				container.add_child(omni)
				_stats["lights_created"] += 1

			_apply_transform(container, ref, false)
			_stats["objects_instantiated"] += 1
			return container

	# Apply transform for non-light objects
	_apply_transform(instance, ref, true)

	_stats["objects_instantiated"] += 1
	return instance


## Internal: Queue an object for instantiation with limit checking
## Includes object position for distance-priority sorting
func _queue_instantiation(request_id: int, ref: CellReference, model_path: String, item_id: String) -> bool:
	# Check queue limit to prevent memory buildup
	if _instantiation_queue.size() >= MAX_INSTANTIATION_QUEUE:
		push_warning("CellManager: Instantiation queue full (%d items), dropping object" % MAX_INSTANTIATION_QUEUE)
		return false

	# Get object position for distance-priority sorting
	var position := CS.vector_to_godot(ref.position)

	_instantiation_queue.append({
		"request_id": request_id,
		"ref": ref,
		"model_path": model_path,
		"item_id": item_id,
		"position": position
	})

	# Track pending instantiation count for completion checking
	if request_id in _async_requests:
		_async_requests[request_id].pending_instantiations += 1

	return true


## Internal: Get cache key for a model
func _get_cache_key(model_path: String, item_id: String) -> String:
	var normalized := model_path.to_lower().replace("/", "\\")
	if not item_id.is_empty():
		return normalized + ":" + item_id.to_lower()
	return normalized


## Get count of pending async requests
func get_async_pending_count() -> int:
	var count := 0
	for request_id: int in _async_requests:
		if not _async_requests[request_id].completed:
			count += 1
	return count


## Get total objects waiting in instantiation queue
func get_instantiation_queue_size() -> int:
	return _instantiation_queue.size()


## Get comprehensive loading stats including burst loading and parallel duplicate
func get_loading_stats() -> Dictionary:
	var parallel_stats := get_parallel_duplicate_stats()
	return {
		"instantiation_queue_size": _instantiation_queue.size(),
		"burst_loading_active": _burst_loading_active,
		"burst_budget_ms": _burst_budget_ms,
		"burst_max_instantiations": _burst_max_instantiations,
		"parallel_duplicate_enabled": parallel_duplicate_enabled,
		"parallel_duplicate_active": parallel_stats.active_tasks,
		"parallel_duplicate_pending": parallel_stats.pending_results,
		"prewarm_pending_count": _prewarm_pending.size(),
		"objects_instantiated": _stats.get("objects_instantiated", 0),
		"objects_from_pool": _stats.get("objects_from_pool", 0),
		"avg_duplicate_time_us": (_diag_duplicate_time_total_us / _diag_duplicate_count) if _diag_duplicate_count > 0 else 0
	}


## Get overall stats including pool stats
func get_stats() -> Dictionary:
	var result := _stats.duplicate()

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


## Clean up significant objects in a cell when it's unloaded
## Called by WorldStreamingManager when unloading cells
## Returns number of objects unregistered
func cleanup_cell_significant_objects(cell_grid: Vector2i) -> int:
	if not _object_distance_manager:
		return 0

	if not _object_distance_manager.has_method("unregister_cell"):
		return 0

	return _object_distance_manager.unregister_cell(cell_grid)
