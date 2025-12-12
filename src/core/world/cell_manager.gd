## Cell Manager - Loads and instantiates Morrowind cells in Godot
## Handles loading cells from ESM data and placing objects using NIF models
## Ported from OpenMW apps/openmw/mwworld/cellstore.cpp and scene.cpp
class_name CellManager
extends RefCounted

# Preload coordinate utilities
const MWCoords := preload("res://src/core/morrowind_coords.gd")
const ObjectPoolScript := preload("res://src/core/world/object_pool.gd")

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
	extents = MWCoords.position_to_godot(extents).abs()
	center = MWCoords.position_to_godot(center)

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
	node.position = MWCoords.position_to_godot(ref.position)
	node.scale = MWCoords.scale_to_godot(ref.scale)

	# Rotation conversion via CoordinateSystem
	# NIF models are already converted to Y-up in nif_converter, so we only
	# need to apply the object's rotation from the cell reference
	#
	# Morrowind uses ZYX Euler order (yaw around Z, then pitch around Y, then roll around X)
	# After coordinate conversion (Z->Y, Y->-Z), this becomes YZX order in Godot
	var godot_euler := MWCoords.rotation_to_godot(ref.rotation)
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
