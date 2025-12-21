## ReferenceInstantiator - Converts ESM cell references into Node3D objects
##
## Handles instantiation of different reference types:
## - Static objects (furniture, architecture, clutter)
## - Lights (model + OmniLight3D)
## - Actors (NPCs and creatures)
## - Flora/rocks via StaticObjectRenderer for performance
##
## Part of Phase 2 refactoring: Separating instantiation logic from cell management
## Extracted from CellManager to enforce Single Responsibility Principle
class_name ReferenceInstantiator
extends RefCounted

# Dependencies
const CS := preload("res://src/core/coordinate_system.gd")
const NIFConverter := preload("res://src/core/nif/nif_converter.gd")
const CharacterFactory := preload("res://src/core/character/character_factory.gd")

# Injected dependencies (set by CellManager)
var model_loader: RefCounted  # ModelLoader
var object_pool: RefCounted  # ObjectPool (optional)
var static_renderer: Node  # StaticObjectRenderer (optional)
var character_factory: CharacterFactory  # CharacterFactory for NPCs/creatures

# Configuration
var create_lights: bool = true
var load_npcs: bool = true
var load_creatures: bool = true
var use_object_pool: bool = true
var use_static_renderer: bool = true

# Statistics
var stats: Dictionary = {
	"objects_instantiated": 0,
	"objects_failed": 0,
	"objects_from_pool": 0,
	"lights_created": 0,
	"npcs_loaded": 0,
	"creatures_loaded": 0,
	"static_renderer_instances": 0,
}

# Morrowind light radius to Godot light range conversion factor
const MW_LIGHT_SCALE: float = 1.0 / 70.0


## Instantiate a cell reference into a Node3D
## Returns null if the reference cannot be instantiated or uses StaticObjectRenderer
func instantiate_reference(ref: CellReference, cell_grid: Vector2i = Vector2i.ZERO) -> Node3D:
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
			return _instantiate_model_object(ref, base_record, cell_grid)


## Instantiate a standard object with a NIF model
## For flora/rocks, uses StaticObjectRenderer for ~10x faster instantiation
func _instantiate_model_object(ref: CellReference, base_record, cell_grid: Vector2i = Vector2i.ZERO) -> Node3D:
	# Get model path and record ID
	var model_path: String = _get_model_path(base_record)
	if model_path.is_empty():
		return null

	# Get record_id for collision shape library lookup
	var record_id: String = ""
	if "record_id" in base_record:
		record_id = base_record.record_id

	# Check if this model should use static rendering (flora, small rocks)
	# Static rendering is ~10x faster but has no physics/interaction
	if use_static_renderer and static_renderer and _is_static_render_model(model_path):
		return _instantiate_static_object(ref, model_path, cell_grid)

	# Try to get from object pool first (if enabled)
	if use_object_pool and object_pool:
		var pooled: Node3D = object_pool.acquire(model_path)
		if pooled:
			pooled.name = str(ref.ref_id) + "_" + str(ref.ref_num)
			_apply_transform(pooled, ref, true)
			stats["objects_from_pool"] += 1
			return pooled

	# Load or get cached model (with item_id for collision shape lookup)
	var model_prototype: Node3D = model_loader.get_model(model_path, record_id)
	if not model_prototype:
		# Create a placeholder for missing models
		return _create_placeholder(ref)

	# Note: Object pool registration is handled by CellManager during cell loading
	# to avoid tight coupling with ObjectPool implementation details

	# Create instance
	var instance: Node3D = model_prototype.duplicate()
	instance.name = str(ref.ref_id) + "_" + str(ref.ref_num)

	# Apply transform
	_apply_transform(instance, ref, true)

	# Add metadata for console object picker
	_apply_metadata(instance, ref, base_record, model_path)

	stats["objects_instantiated"] += 1
	return instance


## Instantiate a flora/rock using StaticObjectRenderer (RenderingServer direct)
## Returns null (no Node3D created) - the instance exists only in RenderingServer
## This is ~10x faster than Node3D.duplicate()
func _instantiate_static_object(ref: CellReference, model_path: String, cell_grid: Vector2i) -> Node3D:
	var normalized := model_path.to_lower().replace("/", "\\")

	# Ensure model is loaded and registered with static renderer
	if not static_renderer.has_type(normalized):
		# Load prototype to get mesh
		var prototype: Node3D = model_loader.get_model(model_path)
		if prototype:
			static_renderer.register_from_prototype(normalized, prototype)
		else:
			return null

	# Calculate transform
	# Morrowind uses intrinsic XYZ Euler order -> XZY in Godot after coordinate conversion
	var pos := CS.vector_to_godot(ref.position)
	var scale := CS.scale_to_godot(ref.scale)
	var euler := CS.euler_to_godot(ref.rotation)
	var basis := Basis.from_euler(euler, EULER_ORDER_XZY)
	basis = basis.scaled(scale)
	var transform := Transform3D(basis, pos)

	# Add instance to static renderer
	var instance_id: int = static_renderer.add_instance(normalized, transform, cell_grid)
	if instance_id >= 0:
		stats["static_renderer_instances"] += 1

	# Return null - no Node3D created, exists only in RenderingServer
	# The cell_grid parameter lets us clean up when the cell unloads
	return null


## Instantiate a light object (model + OmniLight3D)
func _instantiate_light(ref: CellReference, light_record: LightRecord) -> Node3D:
	# Create container node
	var light_node := Node3D.new()
	light_node.name = str(ref.ref_id) + "_" + str(ref.ref_num)

	# Load the model if it has one
	if not light_record.model.is_empty():
		var model_prototype: Node3D = model_loader.get_model(light_record.model)
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
		stats["lights_created"] += 1

	# Apply transform to the container
	_apply_transform(light_node, ref, false)

	# Add metadata for console object picker
	light_node.set_meta("form_id", light_record.record_id if "record_id" in light_record else str(ref.ref_id))
	light_node.set_meta("record_type", "LIGH")
	light_node.set_meta("model_path", light_record.model if not light_record.model.is_empty() else "")
	light_node.set_meta("ref_id", str(ref.ref_id))
	light_node.set_meta("ref_num", ref.ref_num)
	light_node.set_meta("instance_id", ref.ref_num)

	return light_node


## Instantiate an NPC or Creature
## Uses CharacterFactory to create fully animated and functional characters
func _instantiate_actor(ref: CellReference, actor_record, actor_type: String) -> Node3D:
	# Use CharacterFactory if available (new system)
	if character_factory:
		var character: CharacterBody3D = null

		if actor_record is CreatureRecord:
			character = character_factory.create_creature(actor_record, ref.ref_num)
			stats["creatures_loaded"] += 1
		elif actor_record is NPCRecord:
			character = character_factory.create_npc(actor_record, ref.ref_num)
			stats["npcs_loaded"] += 1

		if character:
			# Apply transform to the CharacterBody3D
			_apply_transform(character, ref, true)

			# Add additional metadata for console object picker
			character.set_meta("form_id", actor_record.record_id if "record_id" in actor_record else str(ref.ref_id))
			character.set_meta("ref_id", str(ref.ref_id))
			character.set_meta("instance_id", ref.ref_num)
			character.set_meta("actor_type", actor_type)

			return character

	# Fallback to old system if CharacterFactory not available
	return _instantiate_actor_legacy(ref, actor_record, actor_type)


## Legacy actor instantiation (old system - basic model loading)
func _instantiate_actor_legacy(ref: CellReference, actor_record, actor_type: String) -> Node3D:
	var model_path: String = ""

	if actor_record is CreatureRecord:
		model_path = actor_record.model
		stats["creatures_loaded"] += 1
	elif actor_record is NPCRecord:
		# NPCs are complex - they use body parts assembled together
		# For now, use the base model if available, otherwise skip
		model_path = actor_record.model
		stats["npcs_loaded"] += 1

	if model_path.is_empty():
		# NPC without direct model - would need body part assembly
		# Create a simple placeholder for now
		return _create_actor_placeholder(ref, actor_record, actor_type)

	var model_prototype: Node3D = model_loader.get_model(model_path)
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

	# Add metadata for console object picker
	var record_type := "NPC_" if actor_type == "npc" else "CREA"
	instance.set_meta("form_id", actor_record.record_id if "record_id" in actor_record else str(ref.ref_id))
	instance.set_meta("record_type", record_type)
	instance.set_meta("model_path", model_path)
	instance.set_meta("ref_id", str(ref.ref_id))
	instance.set_meta("ref_num", ref.ref_num)
	instance.set_meta("instance_id", ref.ref_num)
	instance.set_meta("actor_type", actor_type)

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
		# Box for squat creatures (rats, mudcrabs, etc.)
		var box := BoxShape3D.new()
		box.size = Vector3(width, height, width)
		coll_shape.shape = box

	# Position collision shape at center
	coll_shape.position = center

	# Add to actor model
	# Find or create physics body
	var body: StaticBody3D = null
	for child in instance.get_children():
		if child is StaticBody3D:
			body = child
			break

	if not body:
		body = StaticBody3D.new()
		body.name = "ActorBody"
		body.collision_layer = 2  # Actor layer
		body.collision_mask = 1   # World collision
		instance.add_child(body)

	body.add_child(coll_shape)


## Create a placeholder for actors without models
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

	push_warning("ReferenceInstantiator: Could not resolve creature '%s' from leveled list '%s'" % [
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
	# Morrowind uses intrinsic XYZ Euler order (pitch around X, then roll around Y, then yaw around Z)
	# See: https://github.com/OpenMW/openmw - apps/openmw/mwworld/worldimp.cpp
	# After coordinate conversion (MW Z->Godot Y, MW Y->Godot -Z), XYZ becomes XZY in Godot
	var godot_euler := CS.euler_to_godot(ref.rotation)
	node.basis = Basis.from_euler(godot_euler, EULER_ORDER_XZY)


## Apply metadata to an object for console object picker identification
func _apply_metadata(node: Node3D, ref: CellReference, base_record, model_path: String) -> void:
	# Form ID / record ID
	if "record_id" in base_record:
		node.set_meta("form_id", base_record.record_id)

	# Model path
	if not model_path.is_empty():
		node.set_meta("model_path", model_path)

	# Reference info
	node.set_meta("ref_id", str(ref.ref_id))
	node.set_meta("ref_num", ref.ref_num)

	# Record type - determine from base_record class
	var record_type := "UNKNOWN"

	# Use class type checks to determine type
	if base_record is StaticRecord:
		record_type = "STAT"
	elif base_record is ActivatorRecord:
		record_type = "ACTI"
	elif base_record is ContainerRecord:
		record_type = "CONT"
	elif base_record is DoorRecord:
		record_type = "DOOR"
	elif base_record is LightRecord:
		record_type = "LIGH"
	elif base_record is NPCRecord:
		record_type = "NPC_"
	elif base_record is CreatureRecord:
		record_type = "CREA"
	elif base_record is MiscRecord:
		record_type = "MISC"
	elif base_record is WeaponRecord:
		record_type = "WEAP"
	elif base_record is ArmorRecord:
		record_type = "ARMO"
	elif base_record is ClothingRecord:
		record_type = "CLOT"
	elif base_record is BookRecord:
		record_type = "BOOK"
	elif base_record is IngredientRecord:
		record_type = "INGR"
	elif base_record is ApparatusRecord:
		record_type = "APPA"
	elif base_record is PotionRecord:
		record_type = "ALCH"

	node.set_meta("record_type", record_type)

	# Instance ID (unique per cell)
	node.set_meta("instance_id", ref.ref_num)


## Get the model path from a base record
func _get_model_path(record) -> String:
	if "model" in record and record.model:
		return record.model
	return ""


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
	mat.albedo_color = Color(1.0, 0.0, 1.0)  # Magenta
	placeholder.material_override = mat

	# Apply transform
	_apply_transform(placeholder, ref, false)

	stats["objects_failed"] += 1
	return placeholder


## Check if a model should use StaticObjectRenderer (fast flora/rock rendering)
func _is_static_render_model(model_path: String) -> bool:
	var lower := model_path.to_lower()

	# Flora - grass, kelp, flowers, ferns (visual only, no interaction)
	if "flora_" in lower:
		# Exclude trees (need collision) and harvestable plants
		if "tree" in lower:
			return false
		if "comberry" in lower or "marshmerrow" in lower or "wickwheat" in lower:
			return false  # Harvestable
		return true

	# Small rocks (purely decorative)
	if "rock_" in lower and "_small" in lower:
		return true

	return false


## Reset statistics
func reset_stats() -> void:
	stats = {
		"objects_instantiated": 0,
		"objects_failed": 0,
		"objects_from_pool": 0,
		"lights_created": 0,
		"npcs_loaded": 0,
		"creatures_loaded": 0,
		"static_renderer_instances": 0,
	}


## Get current statistics
func get_stats() -> Dictionary:
	return stats.duplicate()
