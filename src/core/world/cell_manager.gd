## Cell Manager - Loads and instantiates Morrowind cells in Godot
## Handles loading cells from ESM data and placing objects using NIF models
## Ported from OpenMW apps/openmw/mwworld/cellstore.cpp and scene.cpp
class_name CellManager
extends RefCounted

# Preload coordinate utilities
const MWCoords := preload("res://src/core/morrowind_coords.gd")

# Cache for loaded models to avoid re-parsing NIFs
var _model_cache: Dictionary = {}  # model_path (lowercase) -> Node3D prototype

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
			# Leveled creatures need to be resolved at runtime
			# For now, skip them
			return null
		"leveled_item":
			# Leveled items need to be resolved at runtime
			return null
		_:
			# Standard model-based object
			return _instantiate_model_object(ref, base_record)


## Instantiate a standard object with a NIF model
func _instantiate_model_object(ref: CellReference, base_record) -> Node3D:
	# Get model path
	var model_path: String = _get_model_path(base_record)
	if model_path.is_empty():
		return null

	# Load or get cached model
	var model_prototype := _get_model(model_path)
	if not model_prototype:
		# Create a placeholder for missing models
		return _create_placeholder(ref)

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

	# Apply transform
	_apply_transform(instance, ref, true)

	return instance


## Create a placeholder for actors without models (NPCs using body parts)
func _create_actor_placeholder(ref: CellReference, actor_record, actor_type: String) -> Node3D:
	var placeholder := MeshInstance3D.new()
	placeholder.name = str(ref.ref_id) + "_" + str(ref.ref_num)

	# Capsule mesh for humanoid shape
	var capsule := CapsuleMesh.new()
	capsule.radius = 25.0  # Roughly human-sized in MW units
	capsule.height = 128.0
	placeholder.mesh = capsule

	# Color based on type
	var mat := StandardMaterial3D.new()
	if actor_type == "npc":
		mat.albedo_color = Color(0.2, 0.6, 1.0, 0.7)  # Blue for NPCs
	else:
		mat.albedo_color = Color(1.0, 0.4, 0.2, 0.7)  # Orange for creatures
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	placeholder.material_override = mat

	# Apply transform (no model rotation needed for placeholder)
	_apply_transform(placeholder, ref, false)

	return placeholder


## Apply position, rotation, and scale to a node
## If apply_model_rotation is true, applies the Z-up to Y-up conversion
func _apply_transform(node: Node3D, ref: CellReference, apply_model_rotation: bool) -> void:
	# Position conversion: MW(x,y,z) -> Godot(x, z, -y)
	node.position = MWCoords.position_to_godot(ref.position)
	node.scale = MWCoords.scale_to_godot(ref.scale)

	if apply_model_rotation:
		# Build the complete rotation:
		# 1. Base rotation: -90 around X to convert Z-up model to Y-up world
		# 2. Object rotation: converted from MW to Godot coordinates
		var base_rotation := Basis(Vector3(1, 0, 0), -PI / 2.0)

		# Convert MW rotation to Godot axes
		# MW: X=pitch, Y=roll, Z=yaw (around vertical)
		var object_rotation := Basis.from_euler(Vector3(
			ref.rotation.x,   # Pitch
			ref.rotation.z,   # MW Z-yaw -> Godot Y-yaw
			-ref.rotation.y   # MW Y-roll -> Godot -Z-roll
		), EULER_ORDER_YXZ)

		# Combine: apply base rotation first, then object rotation
		node.basis = object_rotation * base_rotation
	else:
		# Just rotation conversion, no model orientation fix needed
		var object_rotation := Basis.from_euler(Vector3(
			ref.rotation.x,
			ref.rotation.z,
			-ref.rotation.y
		), EULER_ORDER_YXZ)
		node.basis = object_rotation


## Get the model path from a base record
func _get_model_path(record) -> String:
	if "model" in record and record.model:
		return record.model
	return ""


## Get or load a model prototype
func _get_model(model_path: String) -> Node3D:
	var normalized := model_path.to_lower().replace("/", "\\")

	if normalized in _model_cache:
		_stats["models_from_cache"] += 1
		return _model_cache[normalized]

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
		if not normalized in _model_cache:
			push_warning("CellManager: Model not found in BSA: '%s' (tried meshes\\ prefix too)" % model_path)
		_model_cache[normalized] = null
		return null

	# Convert NIF to Godot scene
	var converter := NIFConverter.new()
	var node := converter.convert_buffer(nif_data)

	if not node:
		push_warning("CellManager: Failed to convert NIF: '%s'" % model_path)
		_model_cache[normalized] = null
		return null

	_model_cache[normalized] = node
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
	}


## Get loading statistics
func get_stats() -> Dictionary:
	var stats := _stats.duplicate()
	stats["cached_models"] = _model_cache.size()
	return stats
