## ImpostorManager - Manages far-distance impostor rendering (2km-5km)
##
## Renders distant landmarks as octahedral impostors (pre-rendered billboards).
## Uses MultiMesh batching for efficient rendering - groups instances by texture.
##
## Key features:
## - Loads pre-baked impostor textures for landmarks
## - Uses MultiMesh to batch impostors sharing the same texture (1 draw call per texture)
## - Billboard rotation handled in shader (GPU-based)
## - Handles impostor→mesh transition when player approaches
##
## Impostor textures are expected in the cache directory:
##   {cache}/impostors/[model_hash]_impostor.png
##   {cache}/impostors/[model_hash]_impostor.json (metadata)
## Default cache location: Documents/Godotwind/cache/
##
## Usage:
##   var manager := ImpostorManager.new()
##   add_child(manager)
##   manager.add_impostor(model_path, position, rotation, scale)
##   manager.remove_impostors_for_cell(cell_grid)
class_name ImpostorManager
extends Node3D

# Preload dependencies
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")
const CS := preload("res://src/core/coordinate_system.gd")

## Reference to ImpostorCandidates for checking impostor eligibility
var impostor_candidates: ImpostorCandidates = null

## World scenario RID
var _scenario: RID = RID()

## Loaded impostor textures: model_path_hash -> Texture2D
var _impostor_textures: Dictionary = {}

## Loaded impostor metadata: model_path_hash -> Dictionary
var _impostor_metadata: Dictionary = {}

## MultiMesh batches: texture_hash -> MultiMeshBatch
## Each unique texture gets its own MultiMesh for efficient batching
var _multimesh_batches: Dictionary = {}

## Active impostors: impostor_id -> ImpostorInstance
var _impostors: Dictionary[int, ImpostorInstance] = {}

## Impostors by cell: Vector2i -> Array[int] (impostor_ids)
var _impostors_by_cell: Dictionary[Vector2i, Array] = {}

## Next impostor ID
var _next_id: int = 0

## Default billboard material (octahedral shader placeholder)
var _billboard_material: ShaderMaterial = null

## Stats
var _stats: Dictionary[String, int] = {
	"total_impostors": 0,
	"visible_impostors": 0,
	"texture_cache_size": 0,
	"cells_with_impostors": 0,
	"multimesh_batches": 0,
	"draw_calls": 0,
}

## Debug logging enabled
var debug_enabled: bool = false

## Dirty flag for batch rebuild
var _batches_dirty: bool = false


## MultiMesh batch data for a single texture
class MultiMeshBatch:
	var texture_hash: String
	var texture: Texture2D
	var impostor_size: Vector2
	var multimesh: MultiMesh
	var instance: MultiMeshInstance3D
	var impostor_ids: Array[int] = []  # Track which impostors are in this batch
	var visible: bool = true


## Impostor instance data
class ImpostorInstance:
	var id: int
	var model_path: String
	var texture_hash: String  # For batch lookup
	var position: Vector3
	var rotation: Vector3
	var scale: Vector3
	var cell_grid: Vector2i
	var visible: bool = true
	var texture_size: Vector2  # Size of impostor in world units


func _enter_tree() -> void:
	_scenario = get_viewport().get_world_3d().scenario
	_setup_billboard_material()


func _exit_tree() -> void:
	clear()


func _process(_delta: float) -> void:
	# Rebuild dirty batches (deferred to avoid per-add overhead)
	if _batches_dirty:
		_rebuild_multimesh_batches()
		_batches_dirty = false


## Set up the billboard material with octahedral impostor shader
func _setup_billboard_material() -> void:
	# Try to load the prebaked octahedral shader
	var shader_path: String = "res://src/tools/prebaking/shaders/octahedral_impostor.gdshader"
	var shader: Shader = null

	if ResourceLoader.exists(shader_path):
		shader = load(shader_path) as Shader

	if not shader:
		# Fallback to inline shader if file not found
		shader = Shader.new()
		shader.code = _get_fallback_shader_code()

	_billboard_material = ShaderMaterial.new()
	_billboard_material.shader = shader
	_billboard_material.set_shader_parameter("atlas_columns", 4)
	_billboard_material.set_shader_parameter("atlas_rows", 2)
	_billboard_material.set_shader_parameter("interpolate_frames", true)


## Fallback shader code if external file not found
func _get_fallback_shader_code() -> String:
	return """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, shadows_disabled;

uniform sampler2D albedo_atlas : source_color, filter_linear_mipmap;
uniform float alpha_cutoff : hint_range(0.0, 1.0) = 0.5;
uniform int atlas_columns = 4;
uniform int atlas_rows = 2;

varying vec3 view_direction;

void vertex() {
	vec3 camera_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 world_pos = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	view_direction = normalize(camera_pos - world_pos);

	vec3 look_dir = normalize(vec3(view_direction.x, 0.0, view_direction.z));
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), look_dir));
	vec3 up = vec3(0.0, 1.0, 0.0);

	mat4 billboard = mat4(
		vec4(right, 0.0),
		vec4(up, 0.0),
		vec4(look_dir, 0.0),
		MODEL_MATRIX[3]
	);

	float scale_x = length(MODEL_MATRIX[0].xyz);
	float scale_y = length(MODEL_MATRIX[1].xyz);
	float scale_z = length(MODEL_MATRIX[2].xyz);

	billboard[0] *= scale_x;
	billboard[1] *= scale_y;
	billboard[2] *= scale_z;

	MODELVIEW_MATRIX = VIEW_MATRIX * billboard;
}

int get_frame_index(vec3 view_dir) {
	float angle = atan(view_dir.x, view_dir.z);
	float normalized = (angle + PI) / (2.0 * PI);
	return int(normalized * 8.0) % 8;
}

vec2 get_frame_uv(int frame_index, vec2 uv) {
	float col = float(frame_index % atlas_columns);
	float row = float(frame_index / atlas_columns);
	vec2 frame_size = vec2(1.0 / float(atlas_columns), 1.0 / float(atlas_rows));
	return vec2(col, row) * frame_size + uv * frame_size;
}

void fragment() {
	int frame = get_frame_index(view_direction);
	vec2 atlas_uv = get_frame_uv(frame, UV);
	vec4 tex = texture(albedo_atlas, atlas_uv);

	if (tex.a < alpha_cutoff) {
		discard;
	}
	ALBEDO = tex.rgb;
}
"""


## Set the impostor candidates reference
func set_impostor_candidates(candidates: ImpostorCandidates) -> void:
	impostor_candidates = candidates


## Add an impostor for a model at a specific world position
## Returns impostor_id or -1 if failed
## Uses deferred MultiMesh batching for efficient rendering
func add_impostor(
	model_path: String,
	world_position: Vector3,
	world_rotation: Vector3,
	world_scale: Vector3,
	cell_grid: Vector2i = Vector2i.ZERO
) -> int:
	if not _scenario.is_valid():
		push_warning("ImpostorManager: Not in scene tree")
		return -1

	# Check if this model should have an impostor
	if impostor_candidates and not impostor_candidates.should_have_impostor(model_path):
		return -1

	# Load impostor texture if not cached
	var texture: Texture2D = _get_or_load_impostor_texture(model_path)
	if not texture:
		# No pre-baked impostor available - skip
		return -1

	# Get texture hash for batch grouping
	var texture_hash: String = str(model_path.to_lower().hash())

	# Get impostor metadata
	var metadata: Dictionary = _get_or_load_impostor_metadata(model_path)
	var impostor_size: Vector2 = Vector2(10.0, 10.0)  # Default size
	if not metadata.is_empty():
		# Try new format first (bounds.width/height), then old format
		var bounds: Dictionary = metadata.get("bounds", {})
		if not bounds.is_empty():
			impostor_size.x = bounds.get("width", 10.0)
			impostor_size.y = bounds.get("height", 10.0)
		else:
			impostor_size.x = metadata.get("width", 10.0)
			impostor_size.y = metadata.get("height", 10.0)

	# Create impostor instance (no RenderingServer instance - batched via MultiMesh)
	var impostor: ImpostorInstance = ImpostorInstance.new()
	impostor.id = _next_id
	impostor.model_path = model_path
	impostor.texture_hash = texture_hash
	impostor.position = world_position
	impostor.rotation = world_rotation
	impostor.scale = world_scale
	impostor.cell_grid = cell_grid
	impostor.visible = true
	impostor.texture_size = impostor_size

	_impostors[_next_id] = impostor
	_next_id += 1

	# Track by cell
	if cell_grid not in _impostors_by_cell:
		var new_arr: Array[int] = []
		_impostors_by_cell[cell_grid] = new_arr
		_stats["cells_with_impostors"] += 1
	(_impostors_by_cell[cell_grid] as Array[int]).append(impostor.id)

	# Ensure batch exists for this texture
	if texture_hash not in _multimesh_batches:
		_create_batch_for_texture(texture_hash, texture, impostor_size)

	# Add to batch tracking
	var batch: MultiMeshBatch = _multimesh_batches[texture_hash]
	batch.impostor_ids.append(impostor.id)

	# Update stats
	_stats["total_impostors"] += 1
	_stats["visible_impostors"] += 1

	# Mark batches as dirty for rebuild
	_batches_dirty = true

	return impostor.id


## Create a new MultiMesh batch for a texture
func _create_batch_for_texture(texture_hash: String, texture: Texture2D, impostor_size: Vector2) -> void:
	var batch: MultiMeshBatch = MultiMeshBatch.new()
	batch.texture_hash = texture_hash
	batch.texture = texture
	batch.impostor_size = impostor_size

	# Create MultiMesh (will be populated in _rebuild_multimesh_batches)
	batch.multimesh = MultiMesh.new()
	batch.multimesh.transform_format = MultiMesh.TRANSFORM_3D

	# Create quad mesh for billboard
	var quad: QuadMesh = QuadMesh.new()
	quad.size = impostor_size
	batch.multimesh.mesh = quad

	# Create instance node
	batch.instance = MultiMeshInstance3D.new()
	batch.instance.multimesh = batch.multimesh
	batch.instance.name = "ImpostorBatch_%s" % texture_hash

	# Apply material with texture
	var mat: ShaderMaterial = _billboard_material.duplicate() as ShaderMaterial
	mat.set_shader_parameter("albedo_atlas", texture)
	batch.instance.material_override = mat

	add_child(batch.instance)
	_multimesh_batches[texture_hash] = batch
	_stats["multimesh_batches"] += 1


## Rebuild all MultiMesh batches from current impostor data
func _rebuild_multimesh_batches() -> void:
	# Group impostors by texture hash
	var impostors_by_hash: Dictionary[String, Array] = {}
	for id: int in _impostors:
		var impostor: ImpostorInstance = _impostors[id]
		if not impostor.visible:
			continue
		var hash_key: String = impostor.texture_hash
		if hash_key not in impostors_by_hash:
			impostors_by_hash[hash_key] = []
		(impostors_by_hash[hash_key] as Array).append(impostor)

	# Update each batch
	var draw_calls: int = 0
	for hash_key: Variant in _multimesh_batches:
		var batch: MultiMeshBatch = _multimesh_batches[hash_key]
		var batch_impostors: Array = impostors_by_hash.get(hash_key, [])

		if batch_impostors.is_empty():
			batch.multimesh.instance_count = 0
			batch.instance.visible = false
			continue

		batch.instance.visible = batch.visible
		batch.multimesh.instance_count = batch_impostors.size()

		# Set transforms for each instance
		for i in range(batch_impostors.size()):
			var impostor: ImpostorInstance = batch_impostors[i]
			var xform: Transform3D = Transform3D.IDENTITY

			# Apply scale (uniform for billboards)
			var scale_factor: float = impostor.scale.x
			xform = xform.scaled(Vector3(scale_factor, scale_factor, scale_factor))

			# Position with Y offset for center pivot
			xform.origin = impostor.position + Vector3(0, impostor.texture_size.y * 0.5 * scale_factor, 0)

			batch.multimesh.set_instance_transform(i, xform)

		draw_calls += 1

	_stats["draw_calls"] = draw_calls


## Add impostors for all eligible objects in a cell
## Returns number of impostors added
func add_cell_impostors(cell_grid: Vector2i, references: Array) -> int:
	var count: int = 0
	var candidates_checked: int = 0
	var textures_found: int = 0

	for ref: Variant in references:
		if not ref is CellReference:
			continue
		var cell_ref: CellReference = ref as CellReference

		# Get base record
		var record_type: Array[String] = [""]
		var base_record: RefCounted = ESMManager.get_any_record(str(cell_ref.ref_id), record_type)
		if not base_record:
			continue

		# Get model path
		var model_path: String = ""
		var model_val: Variant = base_record.get("model")
		if model_val:
			model_path = model_val as String
		else:
			var model_path_val: Variant = base_record.get("model_path")
			if model_path_val:
				model_path = model_path_val as String

		if model_path.is_empty():
			continue

		# Check if should have impostor
		if impostor_candidates and not impostor_candidates.should_have_impostor(model_path):
			continue

		candidates_checked += 1

		# DEBUG: Check if texture exists
		var texture_path: String = ImpostorCandidatesScript.get_impostor_texture_path(model_path)
		if FileAccess.file_exists(texture_path):
			textures_found += 1

		# Calculate world position/rotation/scale using proper ESM rotation conversion
		var pos: Vector3 = CS.vector_to_godot(cell_ref.position)
		var rot_basis: Basis = CS.esm_rotation_to_godot_basis(cell_ref.rotation)
		var scl: Vector3 = CS.scale_to_godot(cell_ref.scale)

		# Add impostor (pass Euler angles extracted from corrected basis)
		var id: int = add_impostor(model_path, pos, rot_basis.get_euler(), scl, cell_grid)
		if id >= 0:
			count += 1

	# DEBUG: Log impostor loading stats for this cell (guarded)
	if debug_enabled and candidates_checked > 0:
		print("ImpostorManager: Cell %s - checked %d candidates, %d textures found, %d impostors created" % [
			cell_grid, candidates_checked, textures_found, count
		])
		# DEBUG: Show first few expected texture paths if none found
		if textures_found == 0 and candidates_checked > 0:
			var sample_count: int = 0
			for ref2: Variant in references:
				if sample_count >= 3:
					break
				if not ref2 is CellReference:
					continue
				var cell_ref2: CellReference = ref2 as CellReference
				var record_type2: Array[String] = [""]
				var base_record2: RefCounted = ESMManager.get_any_record(str(cell_ref2.ref_id), record_type2)
				if not base_record2:
					continue
				var model_path2: String = ""
				var model_val2: Variant = base_record2.get("model")
				if model_val2:
					model_path2 = model_val2 as String
				else:
					var model_path_val2: Variant = base_record2.get("model_path")
					if model_path_val2:
						model_path2 = model_path_val2 as String
				if model_path2.is_empty():
					continue
				if impostor_candidates and not impostor_candidates.should_have_impostor(model_path2):
					continue
				var expected_path: String = ImpostorCandidatesScript.get_impostor_texture_path(model_path2)
				var hash_val: int = model_path2.to_lower().hash()
				print("  Expected texture: %s" % expected_path)
				print("    Model path: %s (hash: %x)" % [model_path2, hash_val])
				sample_count += 1

	return count


## Remove an impostor by ID
func remove_impostor(impostor_id: int) -> void:
	if impostor_id not in _impostors:
		return

	var impostor: ImpostorInstance = _impostors[impostor_id]

	# Remove from batch tracking
	if impostor.texture_hash in _multimesh_batches:
		var batch: MultiMeshBatch = _multimesh_batches[impostor.texture_hash]
		batch.impostor_ids.erase(impostor_id)

	# Update stats
	_stats["total_impostors"] -= 1
	if impostor.visible:
		_stats["visible_impostors"] -= 1

	# Remove from cell tracking
	if impostor.cell_grid in _impostors_by_cell:
		var cell_arr: Array[int] = _impostors_by_cell[impostor.cell_grid] as Array[int]
		cell_arr.erase(impostor_id)
		if cell_arr.is_empty():
			_impostors_by_cell.erase(impostor.cell_grid)
			_stats["cells_with_impostors"] -= 1

	_impostors.erase(impostor_id)

	# Mark for rebuild
	_batches_dirty = true


## Remove all impostors for a cell
func remove_impostors_for_cell(cell_grid: Vector2i) -> void:
	if cell_grid not in _impostors_by_cell:
		return

	# Copy array since we're modifying it
	var impostor_ids: Array[int] = (_impostors_by_cell[cell_grid] as Array[int]).duplicate()
	for id: int in impostor_ids:
		remove_impostor(id)


## Set impostor visibility
func set_impostor_visible(impostor_id: int, is_visible: bool) -> void:
	if impostor_id not in _impostors:
		return

	var impostor: ImpostorInstance = _impostors[impostor_id]
	if impostor.visible == is_visible:
		return

	impostor.visible = is_visible

	if is_visible:
		_stats["visible_impostors"] += 1
	else:
		_stats["visible_impostors"] -= 1

	# Mark for rebuild (visibility changes require MultiMesh update)
	_batches_dirty = true


## Update visibility for all impostors based on camera distance
## min_distance: Start showing impostors (end of MID tier)
## max_distance: Stop showing impostors (start of HORIZON tier)
func update_impostor_visibility(camera_pos: Vector3, min_distance: float, max_distance: float) -> int:
	var changes: int = 0
	var min_dist_sq: float = min_distance * min_distance
	var max_dist_sq: float = max_distance * max_distance

	for id: int in _impostors:
		var impostor: ImpostorInstance = _impostors[id]
		var dist_sq: float = camera_pos.distance_squared_to(impostor.position)

		var should_be_visible: bool = dist_sq >= min_dist_sq and dist_sq <= max_dist_sq

		if impostor.visible != should_be_visible:
			impostor.visible = should_be_visible
			if should_be_visible:
				_stats["visible_impostors"] += 1
			else:
				_stats["visible_impostors"] -= 1
			changes += 1

	# Mark for rebuild if any changes
	if changes > 0:
		_batches_dirty = true

	return changes


## Get or load impostor texture for a model
func _get_or_load_impostor_texture(model_path: String) -> Texture2D:
	var hash_key: String = str(model_path.to_lower().hash())

	# Check cache
	if hash_key in _impostor_textures:
		return _impostor_textures[hash_key]

	# Try to load from disk (external file path, not res://)
	var texture_path: String = ImpostorCandidatesScript.get_impostor_texture_path(model_path)
	if FileAccess.file_exists(texture_path):
		var image: Image = Image.load_from_file(texture_path)
		if image:
			var texture: ImageTexture = ImageTexture.create_from_image(image)
			if texture:
				_impostor_textures[hash_key] = texture
				_stats["texture_cache_size"] += 1
				if debug_enabled:
					print("ImpostorManager: Loaded texture for %s -> %s" % [model_path.get_file(), texture_path.get_file()])
				return texture
			else:
				if debug_enabled:
					push_warning("ImpostorManager: Failed to create ImageTexture from %s" % texture_path)
		else:
			if debug_enabled:
				push_warning("ImpostorManager: Failed to load image from %s" % texture_path)
	else:
		# DEBUG: Print expected path when texture not found (guarded and throttled)
		if debug_enabled and _stats.get("texture_cache_size", 0) == 0 and _stats.get("_debug_missing_logged", 0) < 5:
			print("ImpostorManager: Texture not found: %s" % texture_path)
			print("  Model path: %s" % model_path)
			_stats["_debug_missing_logged"] = _stats.get("_debug_missing_logged", 0) + 1

	# No pre-baked impostor available
	return null


## Get or load impostor metadata for a model
func _get_or_load_impostor_metadata(model_path: String) -> Dictionary:
	var hash_key: String = str(model_path.to_lower().hash())

	# Check cache
	if hash_key in _impostor_metadata:
		return _impostor_metadata[hash_key]

	# Try to load from disk
	var metadata_path: String = ImpostorCandidatesScript.get_impostor_metadata_path(model_path)
	if FileAccess.file_exists(metadata_path):
		var file: FileAccess = FileAccess.open(metadata_path, FileAccess.READ)
		if file:
			var json_str: String = file.get_as_text()
			file.close()

			var json: JSON = JSON.new()
			if json.parse(json_str) == OK:
				var data: Dictionary = json.data
				_impostor_metadata[hash_key] = data
				return data

	# Return empty - will use defaults
	return {}


## Set visibility for all impostors at once
func set_all_visible(is_visible: bool) -> void:
	# Update individual impostor visibility flags
	for id: int in _impostors:
		var impostor: ImpostorInstance = _impostors[id]
		impostor.visible = is_visible

	# Update all batch visibilities
	for hash_key: Variant in _multimesh_batches:
		var batch: MultiMeshBatch = _multimesh_batches[hash_key]
		batch.visible = is_visible
		batch.instance.visible = is_visible

	if is_visible:
		_stats["visible_impostors"] = _stats["total_impostors"]
	else:
		_stats["visible_impostors"] = 0

	# Need to rebuild to reflect visibility in MultiMesh instances
	_batches_dirty = true


## Clear all impostors
func clear() -> void:
	# Clear impostor tracking
	_impostors.clear()
	_impostors_by_cell.clear()

	# Clear MultiMesh batches
	for hash_key: Variant in _multimesh_batches:
		var batch: MultiMeshBatch = _multimesh_batches[hash_key]
		if batch.instance and is_instance_valid(batch.instance):
			batch.instance.queue_free()
	_multimesh_batches.clear()

	# Clear texture caches
	_impostor_textures.clear()
	_impostor_metadata.clear()

	# Reset stats
	_stats["total_impostors"] = 0
	_stats["visible_impostors"] = 0
	_stats["texture_cache_size"] = 0
	_stats["cells_with_impostors"] = 0
	_stats["multimesh_batches"] = 0
	_stats["draw_calls"] = 0

	_batches_dirty = false


## Get statistics
func get_stats() -> Dictionary[String, int]:
	return _stats.duplicate()


## Check if a cell has impostors
func has_impostors_for_cell(cell_grid: Vector2i) -> bool:
	if cell_grid not in _impostors_by_cell:
		return false
	var arr: Array[int] = _impostors_by_cell[cell_grid] as Array[int]
	return not arr.is_empty()


## Get count of impostors in a cell
func get_cell_impostor_count(cell_grid: Vector2i) -> int:
	if cell_grid not in _impostors_by_cell:
		return 0
	var arr: Array[int] = _impostors_by_cell[cell_grid] as Array[int]
	return arr.size()
