## Cell Manager - Loads and instantiates Morrowind cells in Godot
## Handles loading cells from ESM data and placing objects using NIF models
## Ported from OpenMW apps/openmw/mwworld/cellstore.cpp and scene.cpp
##
## Supports both synchronous and asynchronous cell loading:
## - load_exterior_cell() / load_cell() - Synchronous, blocks until complete
## - request_cell_async() - Async, uses BackgroundProcessor for NIF parsing
class_name CellManager
extends RefCounted

# Preload coordinate utilities
const CS := preload("res://src/core/coordinate_system.gd")
const ObjectPoolScript := preload("res://src/core/world/object_pool.gd")
const NIFConverter := preload("res://src/core/nif/nif_converter.gd")
const NIFParseResult := preload("res://src/core/nif/nif_parse_result.gd")

# Cache for loaded models to avoid re-parsing NIFs
var _model_cache: Dictionary = {}  # model_path (lowercase) -> Node3D prototype

# Object pool for frequently used models
var _object_pool: RefCounted = null  # ObjectPool

# Statistics
var _stats: Dictionary = {
	"models_loaded": 0,
	"models_from_cache": 0,
	"objects_instantiated": 0,
	"objects_failed": 0,
	"lights_created": 0,
	"npcs_loaded": 0,
	"creatures_loaded": 0,
}

# Configuration
var create_lights: bool = true   # Whether to create OmniLight3D for light refs
var load_npcs: bool = true       # Whether to load NPC models
var load_creatures: bool = true  # Whether to load creature models
var use_object_pool: bool = true # Whether to use object pooling for common models

# Morrowind light radius to Godot light range conversion factor
# MW units are roughly 1/128th of a meter, so radius 256 ~= 2 meters
const MW_LIGHT_SCALE: float = 1.0 / 70.0  # Tuned for visual appearance


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

	# Name the cell node
	if cell.is_interior():
		cell_node.name = cell.name.replace(" ", "_").replace(",", "")
	else:
		cell_node.name = "Cell_%d_%d" % [cell.grid_x, cell.grid_y]

	print("CellManager: Loading cell '%s' with %d references..." % [cell.get_description(), cell.references.size()])

	var loaded := 0
	var failed := 0

	for ref in cell.references:
		var obj := _instantiate_reference(ref)
		if obj:
			cell_node.add_child(obj)
			loaded += 1
		else:
			failed += 1

	print("CellManager: Loaded %d objects, %d failed" % [loaded, failed])
	_stats["objects_instantiated"] += loaded
	_stats["objects_failed"] += failed

	return cell_node


## Instantiate a single cell reference as a Node3D
func _instantiate_reference(ref: CellReference) -> Node3D:
	# Use generic lookup to find the base record and its type
	var record_type: Array = [""]
	var base_record = ESMManager.get_any_record(str(ref.ref_id), record_type)

	if not base_record:
		# Not an error - some refs are for types we don't handle yet
		return null

	var type_name: String = record_type[0] if record_type.size() > 0 else ""

	# Handle different record types
	match type_name:
		"light":
			return _instantiate_light(ref, base_record as LightRecord)
		"npc":
			if not load_npcs:
				return null
			return _instantiate_actor(ref, base_record as NPCRecord, "npc")
		"creature":
			if not load_creatures:
				return null
			return _instantiate_actor(ref, base_record as CreatureRecord, "creature")
		"leveled_creature":
			if not load_creatures:
				return null
			# Resolve leveled creature to an actual creature
			var resolved := _resolve_leveled_creature(base_record as LeveledCreatureRecord)
			if resolved:
				return _instantiate_actor(ref, resolved, "creature")
			return null
		"leveled_item":
			# Leveled items need to be resolved at runtime
			# Could spawn random items here if needed
			return null
		_:
			# Standard model-based object
			return _instantiate_model_object(ref, base_record)


## Instantiate a standard object with a NIF model
func _instantiate_model_object(ref: CellReference, base_record) -> Node3D:
	# Get model path and record ID
	var model_path: String = _get_model_path(base_record)
	if model_path.is_empty():
		return null

	# Get record_id for collision shape library lookup
	var record_id: String = ""
	if "record_id" in base_record:
		record_id = base_record.record_id

	# Try to get from object pool first (if enabled)
	if use_object_pool and _object_pool:
		var pooled: Node3D = _object_pool.acquire(model_path)
		if pooled:
			pooled.name = str(ref.ref_id) + "_" + str(ref.ref_num)
			_apply_transform(pooled, ref, true)
			_stats["objects_from_pool"] = _stats.get("objects_from_pool", 0) + 1
			return pooled

	# Load or get cached model (with item_id for collision shape lookup)
	var model_prototype := _get_model(model_path, record_id)
	if not model_prototype:
		# Create a placeholder for missing models
		return _create_placeholder(ref)

	# Register with pool if pooling enabled and this is a common model
	if use_object_pool and _object_pool and not _object_pool.has_model(model_path):
		var common_models := ObjectPoolScript.identify_common_models(self)
		if model_path.to_lower().replace("/", "\\") in common_models:
			_object_pool.register_model(model_path, model_prototype, 0, common_models[model_path.to_lower().replace("/", "\\")])

	# Create instance
	var instance: Node3D = model_prototype.duplicate()
	instance.name = str(ref.ref_id) + "_" + str(ref.ref_num)

	# Apply transform
	_apply_transform(instance, ref, true)

	return instance


## Instantiate a light object (model + OmniLight3D)
func _instantiate_light(ref: CellReference, light_record: LightRecord) -> Node3D:
	# Create container node
	var light_node := Node3D.new()
	light_node.name = str(ref.ref_id) + "_" + str(ref.ref_num)

	# Load the model if it has one
	if not light_record.model.is_empty():
		var model_prototype := _get_model(light_record.model)
		if model_prototype:
			var model_instance: Node3D = model_prototype.duplicate()
			model_instance.name = "Model"
			light_node.add_child(model_instance)

	# Create the actual light source
	if create_lights and light_record.radius > 0 and not light_record.is_off_by_default():
		var omni := OmniLight3D.new()
		omni.name = "Light"

		# Convert MW radius to Godot range
		# MW radius is in game units, Godot uses meters
		omni.omni_range = light_record.radius * MW_LIGHT_SCALE

		# Set light color
		omni.light_color = light_record.color

		# Negative lights subtract light (Morrowind feature)
		if light_record.is_negative():
			omni.light_negative = true

		# Set energy based on whether it's a fire/torch light
		# Fire lights tend to be brighter
		omni.light_energy = 1.0 if light_record.is_fire() else 0.8

		# Enable shadows for dynamic lights only (performance)
		omni.shadow_enabled = light_record.is_dynamic()

		# Set attenuation for softer falloff
		omni.omni_attenuation = 1.0

		light_node.add_child(omni)
		_stats["lights_created"] += 1

	# Apply transform to the container
	_apply_transform(light_node, ref, false)

	return light_node


## Instantiate an NPC or Creature
## Note: Full body assembly from body parts is complex - for now just load the base model
func _instantiate_actor(ref: CellReference, actor_record, actor_type: String) -> Node3D:
	var model_path: String = ""

	if actor_record is CreatureRecord:
		model_path = actor_record.model
		_stats["creatures_loaded"] += 1
	elif actor_record is NPCRecord:
		# NPCs are complex - they use body parts assembled together
		# For now, use the base model if available, otherwise skip
		model_path = actor_record.model
		_stats["npcs_loaded"] += 1

	if model_path.is_empty():
		# NPC without direct model - would need body part assembly
		# Create a simple placeholder for now
		return _create_actor_placeholder(ref, actor_record, actor_type)

	var model_prototype := _get_model(model_path)
	if not model_prototype:
		return _create_actor_placeholder(ref, actor_record, actor_type)

	var instance: Node3D = model_prototype.duplicate()
	instance.name = str(ref.ref_id) + "_" + str(ref.ref_num)

	# Check if model has actor collision metadata (from NIF "Bounding Box" node)
	# If so, ensure it has a capsule collision shape for proper physics
	if instance.has_meta("actor_collision_extents"):
		_ensure_actor_collision(instance, actor_type)

	# Apply transform
	_apply_transform(instance, ref, true)

	return instance


## Ensure actor has proper capsule collision for CharacterBody3D compatibility
func _ensure_actor_collision(instance: Node3D, actor_type: String) -> void:
	# Get collision data from metadata (set by NIFConverter)
	var extents: Vector3 = instance.get_meta("actor_collision_extents", Vector3(0.3, 0.9, 0.3))
	var center: Vector3 = instance.get_meta("actor_collision_center", Vector3.ZERO)

	# Convert extents to Godot coordinates (Y-up) and meters
	extents = CS.vector_to_godot(extents).abs()
	center = CS.vector_to_godot(center)

	# Calculate dimensions
	var width := maxf(extents.x, extents.z) * 2.0
	var height := extents.y * 2.0

	# Create collision shape - capsule for humanoids, box for squat creatures
	var coll_shape := CollisionShape3D.new()
	coll_shape.name = "ActorCollision"

	if height > width * 1.2:
		# Capsule for humanoid shapes
		var capsule := CapsuleShape3D.new()
		capsule.radius = width / 2.0
		capsule.height = height
		coll_shape.shape = capsule
	else:
		# Box for squat creatures (crabs, rats, etc.)
		var box := BoxShape3D.new()
		box.size = Vector3(width, height, width)
		coll_shape.shape = box

	# Position at center
	coll_shape.position = center

	# Find or create StaticBody3D for the collision
	# (In the future this could be CharacterBody3D for NPCs that move)
	var body: StaticBody3D = null
	for child in instance.get_children():
		if child is StaticBody3D:
			body = child
			break

	if body == null:
		body = StaticBody3D.new()
		body.name = "ActorBody"
		instance.add_child(body)

	body.add_child(coll_shape)

	# Set collision layer/mask for actors (layer 2 = actors)
	body.collision_layer = 2
	body.collision_mask = 1  # Collide with world

	# Store actor type for later reference
	instance.set_meta("actor_type", actor_type)


## Create a placeholder for actors without models (NPCs using body parts)
func _create_actor_placeholder(ref: CellReference, _actor_record, actor_type: String) -> Node3D:
	var container := Node3D.new()
	container.name = str(ref.ref_id) + "_" + str(ref.ref_num)

	# Visual placeholder mesh
	var placeholder := MeshInstance3D.new()
	placeholder.name = "Visual"

	# Capsule mesh for humanoid shape (in meters)
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.35  # ~35cm radius
	capsule.height = 1.8   # ~1.8m tall
	placeholder.mesh = capsule

	# Color based on type
	var mat := StandardMaterial3D.new()
	if actor_type == "npc":
		mat.albedo_color = Color(0.2, 0.6, 1.0, 0.7)  # Blue for NPCs
	else:
		mat.albedo_color = Color(1.0, 0.4, 0.2, 0.7)  # Orange for creatures
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	placeholder.material_override = mat

	# Offset visual so bottom is at origin (feet at ground level)
	placeholder.position.y = capsule.height / 2.0

	container.add_child(placeholder)

	# Add collision body with capsule shape
	var body := StaticBody3D.new()
	body.name = "ActorBody"
	body.collision_layer = 2  # Actor layer
	body.collision_mask = 1   # World collision

	var coll_shape := CollisionShape3D.new()
	coll_shape.name = "ActorCollision"
	var coll_capsule := CapsuleShape3D.new()
	coll_capsule.radius = 0.35
	coll_capsule.height = 1.8
	coll_shape.shape = coll_capsule
	coll_shape.position.y = capsule.height / 2.0  # Match visual

	body.add_child(coll_shape)
	container.add_child(body)

	# Store metadata
	container.set_meta("actor_type", actor_type)
	container.set_meta("is_placeholder", true)

	# Apply transform (no model rotation needed for placeholder)
	_apply_transform(container, ref, false)

	return container


## Resolve a leveled creature list to an actual creature record
## Uses a simplified algorithm: pick a random creature from valid level range
## player_level defaults to 10 for now (could be passed in later)
func _resolve_leveled_creature(leveled: LeveledCreatureRecord, player_level: int = 10) -> CreatureRecord:
	if leveled.creatures.is_empty():
		return null

	# Check chance_none - random chance to spawn nothing
	if leveled.chance_none > 0 and randi() % 100 < leveled.chance_none:
		return null

	# Filter creatures by level (creatures spawn if player_level >= creature_level)
	var valid_creatures: Array[Dictionary] = []
	for entry in leveled.creatures:
		if entry.level <= player_level:
			valid_creatures.append(entry)

	if valid_creatures.is_empty():
		# No valid creatures for this level, pick lowest level one
		var lowest_entry: Dictionary = leveled.creatures[0]
		for entry in leveled.creatures:
			if entry.level < lowest_entry.level:
				lowest_entry = entry
		valid_creatures.append(lowest_entry)

	# Pick random creature from valid list
	var chosen: Dictionary = valid_creatures[randi() % valid_creatures.size()]
	var creature_id: String = chosen.creature_id

	# Look up the actual creature record
	var creature: CreatureRecord = ESMManager.get_creature(creature_id)
	if creature:
		return creature

	# Might be a nested leveled list - try to resolve recursively
	var nested_leveled: LeveledCreatureRecord = ESMManager.get_leveled_creature(creature_id)
	if nested_leveled:
		return _resolve_leveled_creature(nested_leveled, player_level)

	push_warning("CellManager: Could not resolve creature '%s' from leveled list '%s'" % [
		creature_id, leveled.record_id
	])
	return null


## Apply position, rotation, and scale to a node
## Uses unified CoordinateSystem for all conversions
func _apply_transform(node: Node3D, ref: CellReference, _apply_model_rotation: bool) -> void:
	# Position conversion via CoordinateSystem (outputs in meters)
	node.position = CS.vector_to_godot(ref.position)
	node.scale = CS.scale_to_godot(ref.scale)

	# Rotation conversion via CoordinateSystem
	# NIF models are already converted to Y-up in nif_converter, so we only
	# need to apply the object's rotation from the cell reference
	#
	# Morrowind uses ZYX Euler order (yaw around Z, then pitch around Y, then roll around X)
	# After coordinate conversion (Z->Y, Y->-Z), this becomes YZX order in Godot
	var godot_euler := CS.euler_to_godot(ref.rotation)
	node.basis = Basis.from_euler(godot_euler, EULER_ORDER_YZX)


## Get the model path from a base record
func _get_model_path(record) -> String:
	if "model" in record and record.model:
		return record.model
	return ""


## Get or load a model prototype
## item_id: Optional ESM record ID for collision shape library lookup
func _get_model(model_path: String, item_id: String = "") -> Node3D:
	var normalized := model_path.to_lower().replace("/", "\\")

	# Cache key includes item_id since same model may need different collision for different items
	var cache_key := normalized
	if not item_id.is_empty():
		cache_key = normalized + ":" + item_id.to_lower()

	if cache_key in _model_cache:
		_stats["models_from_cache"] += 1
		return _model_cache[cache_key]

	# Build the full path - ESM stores paths relative to meshes/
	var full_path := model_path
	if not model_path.to_lower().begins_with("meshes"):
		full_path = "meshes\\" + model_path

	# Try to load from BSA - check first to avoid error spam
	var nif_data := PackedByteArray()
	if BSAManager.has_file(full_path):
		nif_data = BSAManager.extract_file(full_path)
	elif BSAManager.has_file(model_path):
		nif_data = BSAManager.extract_file(model_path)

	if nif_data.is_empty():
		# Only warn once per model, don't spam
		if not cache_key in _model_cache:
			push_warning("CellManager: Model not found in BSA: '%s' (tried meshes\\ prefix too)" % model_path)
		_model_cache[cache_key] = null
		return null

	# Convert NIF to Godot scene with item_id for collision shape lookup
	var converter := NIFConverter.new()
	if not item_id.is_empty():
		converter.collision_item_id = item_id
	var node := converter.convert_buffer(nif_data, full_path)

	if not node:
		# Only warn once per failed model
		if not cache_key in _model_cache:
			push_warning("CellManager: Failed to convert NIF: '%s'" % full_path)
		_model_cache[cache_key] = null
		return null

	_model_cache[cache_key] = node
	_stats["models_loaded"] += 1
	return node


## Create a placeholder for missing models
func _create_placeholder(ref: CellReference) -> Node3D:
	var placeholder := MeshInstance3D.new()
	placeholder.name = str(ref.ref_id) + "_placeholder"

	# Simple box mesh (in Godot Y-up coordinates)
	var box := BoxMesh.new()
	box.size = Vector3(50, 50, 50)  # Roughly human-sized in Morrowind units
	placeholder.mesh = box

	# Magenta material to stand out
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.0, 1.0, 0.5)  # Semi-transparent magenta
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	placeholder.material_override = mat

	_apply_transform(placeholder, ref, false)

	return placeholder


## Clear the model cache
func clear_cache() -> void:
	for key in _model_cache:
		var node = _model_cache[key]
		if node and is_instance_valid(node):
			node.queue_free()
	_model_cache.clear()
	_stats = {
		"models_loaded": 0,
		"models_from_cache": 0,
		"objects_instantiated": 0,
		"objects_failed": 0,
		"lights_created": 0,
		"npcs_loaded": 0,
		"creatures_loaded": 0,
		"objects_from_pool": 0,
	}


## Get loading statistics
func get_stats() -> Dictionary:
	var stats := _stats.duplicate()
	stats["cached_models"] = _model_cache.size()

	# Add pool stats if available
	if _object_pool and _object_pool.has_method("get_stats"):
		var pool_stats: Dictionary = _object_pool.get_stats()
		stats["pool_available"] = pool_stats.get("total_available", 0)
		stats["pool_in_use"] = pool_stats.get("total_in_use", 0)
		stats["pool_hit_rate"] = pool_stats.get("hit_rate", 0.0)

	return stats


## Set the object pool to use for common models
func set_object_pool(pool: RefCounted) -> void:
	_object_pool = pool


## Get the object pool
func get_object_pool() -> RefCounted:
	return _object_pool


## Initialize a new object pool with default common models
func init_object_pool(pool_parent: Node3D = null) -> RefCounted:
	_object_pool = ObjectPoolScript.new()
	if pool_parent:
		_object_pool.init(pool_parent)
	return _object_pool


# =============================================================================
# ASYNC CELL LOADING API
# =============================================================================
# Uses BackgroundProcessor to parse NIFs on worker threads.
# The main thread then instantiates from parsed data within time budget.
# =============================================================================

## Maximum concurrent async cell requests (prevents memory buildup)
const MAX_ASYNC_REQUESTS := 8

## Maximum items in instantiation queue (prevents memory buildup)
const MAX_INSTANTIATION_QUEUE := 1000

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


## Process async instantiation within time budget (call from _process)
## Returns number of objects instantiated this frame
func process_async_instantiation(budget_ms: float) -> int:
	if _instantiation_queue.is_empty():
		return 0

	var start_time := Time.get_ticks_usec()
	var budget_usec := budget_ms * 1000.0
	var instantiated := 0

	while not _instantiation_queue.is_empty():
		var elapsed := Time.get_ticks_usec() - start_time
		if elapsed >= budget_usec:
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

		# Instantiate this reference
		var obj := _instantiate_reference_from_parsed(ref, model_path, item_id, request)
		if obj:
			request.cell_node.add_child(obj)
			instantiated += 1

		# Check if this was the last reference
		if _is_request_complete(request):
			request.completed = true

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

	# Collect all unique model paths that need loading
	var models_to_load: Dictionary = {}  # model_path -> {item_ids: Array}

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
			request.references_to_process.append(ref)
			continue

		var item_id: String = ""
		if "record_id" in base_record:
			item_id = base_record.record_id

		var cache_key := _get_cache_key(model_path, item_id)

		# Check if already cached
		if cache_key in _model_cache:
			# Already have this model, queue reference for instantiation
			_queue_instantiation(request.request_id, ref, model_path, item_id)
			continue

		# Need to load this model
		if model_path not in models_to_load:
			models_to_load[model_path] = {"item_ids": []}
		if item_id and item_id not in models_to_load[model_path].item_ids:
			models_to_load[model_path].item_ids.append(item_id)

		# Queue reference for later (after model is parsed)
		request.references_to_process.append(ref)

	# Submit parse tasks for models that need loading
	for model_path in models_to_load:
		var item_ids: Array = models_to_load[model_path].item_ids
		var item_id: String = item_ids[0] if item_ids.size() > 0 else ""

		var task_id := _submit_parse_task(model_path, item_id, request.request_id)
		if task_id >= 0:
			request.pending_parses[model_path] = task_id

	request.started = true
	_async_requests[request.request_id] = request

	# If no pending parses, mark as complete immediately
	if request.pending_parses.is_empty() and request.references_to_process.is_empty():
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
	# Find which request this belongs to
	for request_id in _async_requests:
		var request: AsyncCellRequest = _async_requests[request_id]

		for model_path in request.pending_parses:
			if request.pending_parses[model_path] == task_id:
				# Found it - store result
				request.pending_parses.erase(model_path)

				var parse_success := false
				if result is NIFParseResult:
					var parse_result: NIFParseResult = result
					if parse_result.is_valid():
						request.parsed_results[model_path] = parse_result
						parse_success = true

						# Convert to prototype and cache (main thread)
						var converter := NIFConverter.new()
						var prototype := converter.convert_from_parsed(parse_result)
						if prototype:
							var cache_key := _get_cache_key(model_path, parse_result.item_id)
							_model_cache[cache_key] = prototype
							_stats["models_loaded"] += 1
						else:
							# Conversion failed
							parse_success = false
							request.failed_models.append(model_path)
					else:
						# Parse returned invalid result
						request.failed_models.append(model_path)
				else:
					# Result wasn't a NIFParseResult (unexpected)
					request.failed_models.append(model_path)

				# Queue all references waiting for this model (even if failed, they'll get placeholders)
				_queue_references_for_model(request, model_path)

				# Check if request is now complete
				if _is_request_complete(request):
					request.completed = true
					# Mark as failed if any models failed to parse
					if not request.failed_models.is_empty():
						request.error_message = "Failed to parse %d models" % request.failed_models.size()

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
	return request.pending_parses.is_empty() and request.references_to_process.is_empty()


## Internal: Instantiate a reference from parsed data
func _instantiate_reference_from_parsed(ref: CellReference, model_path: String, item_id: String, request: AsyncCellRequest) -> Node3D:
	# Get the cached model prototype
	var cache_key := _get_cache_key(model_path, item_id)

	# Try object pool first
	if use_object_pool and _object_pool:
		var pooled: Node3D = _object_pool.acquire(model_path)
		if pooled:
			pooled.name = str(ref.ref_id) + "_" + str(ref.ref_num)
			_apply_transform(pooled, ref, true)
			_stats["objects_from_pool"] = _stats.get("objects_from_pool", 0) + 1
			return pooled

	# Get from cache
	if cache_key not in _model_cache or _model_cache[cache_key] == null:
		return _create_placeholder(ref)

	var model_prototype: Node3D = _model_cache[cache_key]

	# Create instance
	var instance: Node3D = model_prototype.duplicate()
	instance.name = str(ref.ref_id) + "_" + str(ref.ref_num)

	# Apply transform
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
