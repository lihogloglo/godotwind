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
const CharacterFactory := preload("res://src/core/character/character_factory.gd")

# Model loader for NIF loading and caching
var _model_loader: ModelLoader = ModelLoader.new()

# Reference instantiator for creating Node3D objects from cell references
var _instantiator: ReferenceInstantiator = ReferenceInstantiator.new()

# Character factory for creating animated NPCs and creatures
var _character_factory: CharacterFactory = CharacterFactory.new()

# Object pool for frequently used models
var _object_pool: RefCounted = null  # ObjectPool

# Static object renderer for fast flora rendering (uses RenderingServer directly)
var _static_renderer: Node = null  # StaticObjectRenderer

# Statistics (instantiation stats now in ReferenceInstantiator, model stats in ModelLoader)
var _stats: Dictionary = {
	"multimesh_instances": 0,
	"objects_instantiated": 0,
	"lights_created": 0,
	"objects_from_pool": 0,
}

# Configuration
var create_lights: bool = true   # Whether to create OmniLight3D for light refs
var load_npcs: bool = true       # Whether to load NPC models
var load_creatures: bool = true  # Whether to load creature models
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
func init_object_pool() -> void:
	if _object_pool == null:
		_object_pool = ObjectPoolScript.new()
		_sync_instantiator_config()


## Get the object pool (for releasing objects back when unloading cells)
func get_object_pool() -> RefCounted:
	return _object_pool


## Sync configuration to instantiator
func _sync_instantiator_config() -> void:
	# Set up character factory
	_character_factory.set_model_loader(_model_loader)

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

	print("CellManager: Loading cell '%s' with %d references..." % [cell.get_description(), cell.references.size()])

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
		for ref in instance_groups.get("individual_refs", []):
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
		for ref in cell.references:
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

	for ref in references:
		# Get base record and type
		var record_type: Array = [""]
		var base_record = ESMManager.get_any_record(str(ref.ref_id), record_type)

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
			continue

		# Check if would use static renderer (skip those - already optimized)
		if use_static_renderer and _static_renderer and _instantiator._is_static_render_model(model_path):
			individual_refs.append(ref)
			continue

		# Add to candidates
		var normalized := model_path.to_lower().replace("/", "\\")
		if normalized not in multimesh_candidates:
			multimesh_candidates[normalized] = []

		multimesh_candidates[normalized].append({
			"ref": ref,
			"base_record": base_record,
			"model_path": model_path
		})

	# Filter groups: only keep those with enough instances
	var multimesh_groups: Dictionary = {}
	for model_path in multimesh_candidates:
		var candidates: Array = multimesh_candidates[model_path]
		if candidates.size() >= min_instances_for_multimesh:
			multimesh_groups[model_path] = candidates
		else:
			# Too few instances - instantiate individually
			for candidate in candidates:
				individual_refs.append(candidate.ref)

	return {
		"multimesh_groups": multimesh_groups,
		"individual_refs": individual_refs
	}


## Check if a model is suitable for MultiMesh instancing
## MultiMesh candidates are: small repeated objects like rocks, pots, bottles, flora
func _is_multimesh_candidate(model_path: String, base_record) -> bool:
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
	var multimesh_groups: Dictionary = instance_groups.get("multimesh_groups", {})
	var total_count := 0

	for model_path in multimesh_groups:
		var candidates: Array = multimesh_groups[model_path]
		var count := candidates.size()

		if count == 0:
			continue

		# Get/load prototype model
		var first_candidate: Dictionary = candidates[0]
		var record_id: String = first_candidate.base_record.get("record_id", "")
		var prototype: Node3D = _model_loader.get_model(first_candidate.model_path, record_id)

		if not prototype:
			# Failed to load - fall back to individual instantiation
			for candidate in candidates:
				var obj := _instantiator.instantiate_reference(candidate.ref)
				if obj:
					parent_node.add_child(obj)
			continue

		# Find first MeshInstance3D in prototype
		var mesh_instance := _find_first_mesh_instance(prototype)
		if not mesh_instance or not mesh_instance.mesh:
			# No mesh found - fall back
			for candidate in candidates:
				var obj := _instantiator.instantiate_reference(candidate.ref)
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
			var candidate: Dictionary = candidates[i]
			var ref: CellReference = candidate.ref
			var transform := _calculate_transform(ref)
			multimesh.set_instance_transform(i, transform)

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
	var euler := CS.euler_to_godot(ref.rotation)
	var basis := Basis.from_euler(euler, EULER_ORDER_XZY)
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

	print("CellManager: Preloading %d common models..." % common_models.size())

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
			# Industry standard: Pre-create 33% to reduce duplicate() calls during gameplay
			if _object_pool and not _object_pool.has_model(model_path):
				var pool_size: int = common_models[model_path]
				# Pre-create 33% of max pool size (better coverage for initial cells)
				var initial_count: int = maxi(8, pool_size / 3)
				_object_pool.register_model(model_path, prototype, initial_count, pool_size)
				pool_instances += initial_count

	print("CellManager: Preloaded %d models, pre-warmed pool with %d instances" % [loaded, pool_instances])
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
	for path in _preload_pending:
		if _preload_pending[path] == task_id:
			model_path = path
			break

	if model_path.is_empty():
		return false  # Not a preload task

	_preload_pending.erase(model_path)

	if result is NIFParseResult:
		var parse_result: NIFParseResult = result
		if parse_result.is_valid():
			# Convert to prototype and cache
			var converter := NIFConverter.new()
			var prototype: Node3D = converter.convert_from_parsed(parse_result)
			if prototype:
				_model_loader.add_to_cache(model_path, prototype, "")
				_preload_loaded += 1

				# Register with pool
				if _object_pool and not _object_pool.has_model(model_path):
					var common_models := ObjectPoolScript.identify_common_models(self)
					var pool_size: int = common_models.get(model_path, 50)
					_object_pool.register_model(model_path, prototype, 0, pool_size)
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
## Diagnostics show avg instantiation is ~0.35ms, so 30 objects = ~10.5ms
## This leaves headroom within a 16.6ms frame (60 FPS)
const MAX_INSTANTIATIONS_PER_FRAME := 30

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

## Async cell request tracking
class AsyncCellRequest:
	var cell_record: CellRecord
	var grid: Vector2i  # For exterior cells
	var is_interior: bool
	var request_id: int
	var pending_parses: Dictionary = {}  # model_path -> task_id
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
var _instantiation_queue: Array = []  # Array of {request_id, ref, model_path}

## Parsed model prototypes waiting to be cached (from async results)
var _pending_prototype_cache: Dictionary = {}  # cache_key -> NIFParseResult


## Set the background processor to use for async loading
func set_background_processor(processor: Node) -> void:
	if _background_processor and _background_processor.task_completed.is_connected(_on_parse_completed):
		_background_processor.task_completed.disconnect(_on_parse_completed)

	_background_processor = processor

	if _background_processor:
		_background_processor.task_completed.connect(_on_parse_completed)


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
	return _async_requests[request_id].failed_models.size()


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
	for task_id in request.pending_parses.values():
		_background_processor.cancel_task(task_id)

	# Clean up cell node if started
	if request.cell_node:
		request.cell_node.queue_free()

	_async_requests.erase(request_id)


## Process pending NIF conversions - ONE per frame to maintain responsiveness
## Returns true if any conversions were done
## Call this BEFORE process_async_instantiation to feed the cache
## NOTE: Complex models can take 500ms-6s each, so we limit to MAX_CONVERSIONS_PER_FRAME
## With disk caching, second runs are nearly instant (1-5ms per model)
func process_pending_conversions(_budget_ms: float) -> bool:
	if _pending_conversions.is_empty():
		return false

	var converted := 0
	var from_disk := 0

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
		var convert_start := Time.get_ticks_usec()
		var prototype: Node3D = null
		var was_disk_hit := false

		# First check disk cache (fast path - 1-5ms vs 300-6000ms)
		if _model_loader.enable_disk_cache and _model_loader.has_disk_cached(model_path, item_id):
			prototype = _model_loader.get_model(model_path, item_id)
			was_disk_hit = true
			from_disk += 1
		else:
			# Perform the conversion (this is the slow part - can take 500ms-6s!)
			var converter := NIFConverter.new()
			prototype = converter.convert_from_parsed(parse_result)

		var convert_elapsed := (Time.get_ticks_usec() - convert_start) / 1000.0

		if prototype:
			if not was_disk_hit:
				# Add to memory cache AND disk cache (handled inside add_to_cache)
				_model_loader.add_to_cache(model_path, prototype, item_id)
			# NOW queue references for this model
			_queue_references_for_model(request, model_path)

			if diagnostic_logging:
				var source := "disk" if was_disk_hit else "NIF"
				print("[DIAG] Loaded (%s): %s (%.1fms, pending=%d, queue=%d)" % [
					source, model_path.get_file(), convert_elapsed, _pending_conversions.size(), _instantiation_queue.size()
				])
		else:
			request.failed_models.append(model_path)
			# Still queue references - they'll get placeholders
			_queue_references_for_model(request, model_path)

		converted += 1

		# Check if request is now complete
		if _is_request_complete(request):
			request.completed = true

	return converted > 0


## Process async instantiation within time budget (call from _process)
## Returns number of objects instantiated this frame
## Uses BOTH time budget AND object count cap for consistent frame times
func process_async_instantiation(budget_ms: float) -> int:
	# First process any pending conversions to feed the cache
	process_pending_conversions(MAX_CONVERSION_TIME_MS)

	if _instantiation_queue.is_empty():
		return 0

	var start_time := Time.get_ticks_usec()
	var budget_usec := budget_ms * 1000.0
	var instantiated := 0
	var exit_reason := ""

	# Batch children for deferred add_child (reduces scene tree churn)
	var pending_children: Array[Dictionary] = []  # {parent: Node3D, child: Node3D}

	while not _instantiation_queue.is_empty():
		# Check time budget
		var elapsed := Time.get_ticks_usec() - start_time
		if elapsed >= budget_usec:
			exit_reason = "time_budget"
			break

		# Check object count cap (critical for consistent frame times)
		if instantiated >= MAX_INSTANTIATIONS_PER_FRAME:
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
			# Queue for batch add_child instead of immediate
			pending_children.append({"parent": request.cell_node, "child": obj})
			instantiated += 1

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
	var add_child_elapsed := Time.get_ticks_usec() - add_child_start

	# Diagnostic logging every 60 frames (~1 second at 60 FPS)
	var current_frame := Engine.get_frames_drawn()
	if diagnostic_logging and (current_frame - _diag_last_log_frame) >= 60:
		var avg_inst_us := _diag_duplicate_time_total_us / maxi(_diag_duplicate_count, 1)
		print("[DIAG] CellManager: queue=%d, instantiated=%d, exit=%s, avg_inst=%.2fms, add_child=%.2fms, async_reqs=%d" % [
			_instantiation_queue.size(),
			instantiated,
			exit_reason if exit_reason else "empty_queue",
			avg_inst_us / 1000.0,
			add_child_elapsed / 1000.0,
			_async_requests.size()
		])
		# Reset counters
		_diag_duplicate_time_total_us = 0
		_diag_duplicate_count = 0
		_diag_last_log_frame = current_frame

	return instantiated


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

	for ref in cell.references:
		var record_type: Array = [""]
		var base_record = ESMManager.get_any_record(str(ref.ref_id), record_type)
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

		# Check disk cache - if available, load synchronously (fast! 1-5ms)
		if _model_loader.enable_disk_cache and _model_loader.has_disk_cached(model_path, item_id):
			var prototype := _model_loader.get_model(model_path, item_id)
			if prototype:
				disk_cache_hits += 1
				_queue_instantiation(request.request_id, ref, model_path, item_id)
				continue

		# Need to load this model from BSA + convert NIF
		if model_path not in models_to_load:
			models_to_load[model_path] = {"item_ids": []}
		if item_id and item_id not in models_to_load[model_path].item_ids:
			models_to_load[model_path].item_ids.append(item_id)

		# Queue reference for later (after model is parsed)
		request.references_to_process.append(ref)

	if disk_cache_hits > 0 and diagnostic_logging:
		print("[DIAG] Cell %s: %d models loaded from disk cache (instant)" % [request.cell_node.name, disk_cache_hits])

	# Submit parse tasks for models that need loading
	for model_path in models_to_load:
		var item_ids: Array = models_to_load[model_path].item_ids
		var item_id: String = item_ids[0] if item_ids.size() > 0 else ""

		var task_id := _submit_parse_task(model_path, item_id, request.request_id)
		if task_id >= 0:
			request.pending_parses[model_path] = task_id

	request.started = true

	# Mark as complete if nothing to do (all models cached and instantiated)
	if _is_request_complete(request):
		request.completed = true

	return request.request_id


## Internal: Submit a NIF parse task to background processor
func _submit_parse_task(model_path: String, item_id: String, request_id: int) -> int:
	# Build full path
	var full_path := model_path
	if not model_path.to_lower().begins_with("meshes"):
		full_path = "meshes\\" + model_path

	# Extract from BSA (this is I/O but relatively fast)
	var nif_data := PackedByteArray()
	if BSAManager.has_file(full_path):
		nif_data = BSAManager.extract_file(full_path)
	elif BSAManager.has_file(model_path):
		nif_data = BSAManager.extract_file(model_path)
		full_path = model_path

	if nif_data.is_empty():
		return -1

	# Submit parse task
	var task_id: int = _background_processor.submit_task(func():
		return NIFConverter.parse_buffer_only(nif_data, full_path, item_id)
	)

	return task_id


## Internal: Handle parse completion from background processor
func _on_parse_completed(task_id: int, result: Variant) -> void:
	# First check if this is a preload task
	if _check_preload_completion(task_id, result):
		return  # Was handled as preload

	# Find which cell request this belongs to
	for request_id in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]

		for model_path in request.pending_parses:
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

	for ref in request.references_to_process:
		var record_type: Array = [""]
		var base_record = ESMManager.get_any_record(str(ref.ref_id), record_type)
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
	return request.pending_parses.is_empty() and request.references_to_process.is_empty() and request.pending_instantiations <= 0


## Helper methods delegated to ReferenceInstantiator
## These are thin wrappers used by async loading code

func _get_model_path(record) -> String:
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
		var pooled: Node3D = _object_pool.acquire(model_path)
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
	var base_record = ESMManager.get_any_record(str(ref.ref_id), record_type)
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
func _queue_instantiation(request_id: int, ref: CellReference, model_path: String, item_id: String) -> bool:
	# Check queue limit to prevent memory buildup
	if _instantiation_queue.size() >= MAX_INSTANTIATION_QUEUE:
		push_warning("CellManager: Instantiation queue full (%d items), dropping object" % MAX_INSTANTIATION_QUEUE)
		return false

	_instantiation_queue.append({
		"request_id": request_id,
		"ref": ref,
		"model_path": model_path,
		"item_id": item_id
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
	for request_id in _async_requests:
		if not _async_requests[request_id].completed:
			count += 1
	return count


## Get total objects waiting in instantiation queue
func get_instantiation_queue_size() -> int:
	return _instantiation_queue.size()
