## Cell Manager - Loads and instantiates Morrowind cells in Godot
## Handles loading cells from ESM data and placing objects using NIF models
class_name CellManager
extends RefCounted

# Cache for loaded models to avoid re-parsing NIFs
var _model_cache: Dictionary = {}  # model_path (lowercase) -> Node3D prototype

# Statistics
var _stats: Dictionary = {
	"models_loaded": 0,
	"models_from_cache": 0,
	"objects_instantiated": 0,
	"objects_failed": 0,
}


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
	# Look up the base record by ID
	var base_record = _get_base_record(ref.ref_id)
	if not base_record:
		# Not an error - some refs are for types we don't render (scripts, etc)
		return null

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

	# Apply transform - convert Morrowind coordinates to Godot
	# Morrowind: Z-up, Y-north, X-east
	# Godot: Y-up, Z-south, X-east
	instance.position = _mw_to_godot_position(ref.position)
	instance.rotation = _mw_to_godot_rotation(ref.rotation)
	instance.scale = Vector3.ONE * ref.scale

	return instance


## Get the base record for a reference ID
## Returns the ESM record or null if not found/not renderable
func _get_base_record(ref_id: StringName):
	var id := str(ref_id)

	# Try each record type that has a model
	var record = ESMManager.get_static(id)
	if record: return record

	record = ESMManager.get_door(id)
	if record: return record

	record = ESMManager.get_container(id)
	if record: return record

	record = ESMManager.get_light(id)
	if record: return record

	record = ESMManager.get_activator(id)
	if record: return record

	record = ESMManager.get_misc_item(id)
	if record: return record

	record = ESMManager.get_weapon(id)
	if record: return record

	record = ESMManager.get_armor(id)
	if record: return record

	record = ESMManager.get_clothing(id)
	if record: return record

	record = ESMManager.get_book(id)
	if record: return record

	record = ESMManager.get_potion(id)
	if record: return record

	record = ESMManager.get_ingredient(id)
	if record: return record

	record = ESMManager.get_apparatus(id)
	if record: return record

	record = ESMManager.get_lockpick(id)
	if record: return record

	record = ESMManager.get_probe(id)
	if record: return record

	record = ESMManager.get_repair_item(id)
	if record: return record

	# NPCs and creatures would need special handling for body parts
	# For now, skip them
	# record = ESMManager.get_npc(id)
	# record = ESMManager.get_creature(id)

	return null


## Get the model path from a base record
func _get_model_path(record) -> String:
	if record.has_method("get") and record.get("model"):
		return record.model
	if "model" in record:
		return record.model
	return ""


## Get or load a model prototype
func _get_model(model_path: String) -> Node3D:
	var normalized := model_path.to_lower().replace("/", "\\")

	if normalized in _model_cache:
		_stats["models_from_cache"] += 1
		return _model_cache[normalized]

	# Try to load from BSA
	var nif_data := BSAManager.extract_file(model_path)
	if nif_data.is_empty():
		# Try with meshes\ prefix if not already there
		if not model_path.to_lower().begins_with("meshes"):
			nif_data = BSAManager.extract_file("meshes\\" + model_path)

		if nif_data.is_empty():
			push_warning("CellManager: Model not found in BSA: '%s'" % model_path)
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

	# Simple box mesh
	var box := BoxMesh.new()
	box.size = Vector3(50, 50, 50)  # Roughly human-sized in Morrowind units
	placeholder.mesh = box

	# Magenta material to stand out
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.0, 1.0, 0.5)  # Semi-transparent magenta
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	placeholder.material_override = mat

	placeholder.position = _mw_to_godot_position(ref.position)
	placeholder.rotation = _mw_to_godot_rotation(ref.rotation)
	placeholder.scale = Vector3.ONE * ref.scale

	return placeholder


## Convert Morrowind position to Godot position
## Morrowind: X-east, Y-north, Z-up
## Godot: X-east, Y-up, Z-south (which is -north)
func _mw_to_godot_position(mw_pos: Vector3) -> Vector3:
	return Vector3(mw_pos.x, mw_pos.z, -mw_pos.y)


## Convert Morrowind rotation (Euler radians) to Godot rotation
## The rotation axes follow the same swap as position
func _mw_to_godot_rotation(mw_rot: Vector3) -> Vector3:
	return Vector3(mw_rot.x, mw_rot.z, -mw_rot.y)


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
	}


## Get loading statistics
func get_stats() -> Dictionary:
	var stats := _stats.duplicate()
	stats["cached_models"] = _model_cache.size()
	return stats
