## NativeImpostorRenderer - Simplified Impostor Rendering with Native Visibility
##
## This is a simplified version of ImpostorManager that:
## - KEEPS the octahedral impostor shader (Godot doesn't have this natively)
## - KEEPS the texture array batching (single draw call for all impostors)
## - REMOVES manual visibility calculations (uses visibility_range instead)
## - REMOVES LOD crossfade coordination (native fade handles this)
##
## PHILOSOPHY:
## The impostor shader is valuable custom code. The visibility logic is not.
## Let Godot handle visibility via visibility_range, we just render the impostors.
##
## Lines of code: ~400 (vs ~1,529 in old ImpostorManager)
class_name NativeImpostorRenderer
extends Node3D

const DU := preload("res://src/core/world/distance_utils.gd")
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")
const BackgroundJobSystemScript := preload("res://src/core/threading/background_job_system.gd")
# We assume global CS class is available or we use duplicated logic?
# Best to rely on the fact that CellManager usually handles this.
# Note: Since we are reading raw ESM data here, we might need CoordinateSystem.
# We'll trust the user to have CS singleton or class.
const CS := preload("res://src/core/coordinate_system.gd")

#region Configuration

## Maximum texture array layers (most GPUs support 512+)
const MAX_TEXTURE_ARRAY_LAYERS: int = 512

## Texture array rebuild delay (batch multiple additions)
const TEXTURE_ARRAY_REBUILD_DELAY: float = 0.1

#endregion


#region Signals

## Emitted when an impostor is created
signal impostor_created(impostor_id: int, model_path: String)

## Emitted when statistics update
signal stats_updated(stats: Dictionary)

#endregion


#region Internal State

## Impostor candidates (knows which models have impostors)
var impostor_candidates: ImpostorCandidatesScript = null

## Master MultiMesh for single draw call rendering
var _master_multimesh: MultiMesh = null
var _master_instance: MultiMeshInstance3D = null

## Billboard shader material with texture array
var _billboard_material: ShaderMaterial = null

## Texture array for batched rendering
var _texture_array: Texture2DArray = null
var _texture_index_map: Dictionary = {}  # texture_hash -> array_index
var _texture_array_dirty: bool = false
var _all_array_images: Array[Image] = []
var _texture_array_size: int = 0
var _last_texture_add_time: float = 0.0

## Loaded impostor textures: hash_key -> Texture2D
var _impostor_textures: Dictionary = {}

## Background job system for async texture loading
var _job_system: RefCounted = null
var _pending_job_ids: Dictionary = {}

## Pending impostors waiting for texture
var _pending_impostors: Dictionary = {}  # hash_key -> Array[PendingImpostor]

## Default fallback texture for missing impostors (created on demand)
var _fallback_texture: ImageTexture = null

## Active impostors: impostor_id -> ImpostorData
var _impostors: Dictionary = {}
var _next_id: int = 0

## Cached impostor metadata
var _impostor_metadata: Dictionary = {}

## Track loaded impostor cells to avoid duplicates
var _loaded_impostor_cells: Dictionary = {} # Vector2i -> true

## Statistics
var _stats: Dictionary = {
	"total_impostors": 0,
	"texture_cache_size": 0,
	"texture_array_layers": 0,
	"pending_loads": 0,
}

## Debug logging
var debug_enabled: bool = false

#endregion


#region Data Classes

class PendingImpostor:
	var model_path: String
	var cell_grid: Vector2i  # Cell this belongs to
	var position: Vector3
	var rotation: Vector3
	var scale: Vector3
	var texture_size: Vector2
	var aabb_center_y: float = 0.0


class ImpostorData:
	var id: int
	var cell_grid: Vector2i # Cell this belongs to
	var model_path: String
	var texture_hash: String
	var texture_index: int
	var position: Vector3
	var rotation: Vector3
	var scale: Vector3
	var texture_size: Vector2
	var aabb_center_y: float = 0.0

#endregion


#region Initialization

func _ready() -> void:
	_setup_master_multimesh()
	_setup_billboard_material()
	_start_job_system()


func _exit_tree() -> void:
	_stop_job_system()
	clear()


func _setup_master_multimesh() -> void:
	_master_multimesh = MultiMesh.new()
	_master_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_master_multimesh.use_custom_data = true
	
	# Create quad mesh for billboard
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	_master_multimesh.mesh = quad
	
	_master_instance = MultiMeshInstance3D.new()
	_master_instance.multimesh = _master_multimesh
	_master_instance.name = "ImpostorMasterBatch"
	
	# Configure native visibility_range for FAR tier
	# Impostors are visible from 0 to 5000m (Shader handles the start/fade-in)
	# We set begin to 0 so the batch is always rendered, allowing the shader to handle per-instance fading
	_master_instance.visibility_range_begin = 0.0
	_master_instance.visibility_range_end = DU.FAR_END   # 5000m
	_master_instance.visibility_range_end_margin = DU.FADE_MARGIN
	_master_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	
	add_child(_master_instance)


func _setup_billboard_material() -> void:
	var shader := Shader.new()
	shader.code = _get_octahedral_shader_code()
	
	_billboard_material = ShaderMaterial.new()
	_billboard_material.shader = shader
	_billboard_material.set_shader_parameter("atlas_columns", 4)
	_billboard_material.set_shader_parameter("atlas_rows", 4)
	
	# Create initial empty texture array
	var default_img := Image.create(512, 512, false, Image.FORMAT_RGBA8)
	default_img.fill(Color(0, 0, 0, 0))
	var default_array := Texture2DArray.new()
	default_array.create_from_images([default_img])
	_billboard_material.set_shader_parameter("texture_atlas", default_array)
	_billboard_material.set_shader_parameter("fade_distance", DU.MID_END) # 500m
	_billboard_material.set_shader_parameter("fade_margin", DU.FADE_MARGIN) # 50m
	
	_master_instance.material_override = _billboard_material

#endregion


#region Octahedral Billboard Shader (Valuable Custom Code)

func _get_octahedral_shader_code() -> String:
	return """
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2DArray texture_atlas : source_color;
uniform int atlas_columns = 4;
uniform int atlas_rows = 4;
uniform float fade_distance = 500.0;
uniform float fade_margin = 50.0;

varying vec3 view_direction;
varying flat float texture_layer;
varying flat float rotation_offset;
varying float dist_to_camera;

void vertex() {
	// Get texture layer from instance custom data
	texture_layer = INSTANCE_CUSTOM.x;
	rotation_offset = INSTANCE_CUSTOM.y;
	
	// Calculate view direction for frame selection
	vec3 camera_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 world_pos = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	view_direction = normalize(camera_pos - world_pos);
	dist_to_camera = distance(camera_pos, world_pos);
	
	// Y-axis billboard (face camera horizontally)
	vec3 look_dir = normalize(vec3(view_direction.x, 0.0, view_direction.z));
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), look_dir));
	vec3 up = vec3(0.0, 1.0, 0.0);
	
	mat4 billboard = mat4(
		vec4(right, 0.0),
		vec4(up, 0.0),
		vec4(look_dir, 0.0),
		MODEL_MATRIX[3]
	);
	
	// Preserve scale from model matrix
	float scale_x = length(MODEL_MATRIX[0].xyz);
	float scale_y = length(MODEL_MATRIX[1].xyz);
	float scale_z = length(MODEL_MATRIX[2].xyz);
	
	billboard[0] *= scale_x;
	billboard[1] *= scale_y;
	billboard[2] *= scale_z;
	
	MODELVIEW_MATRIX = VIEW_MATRIX * billboard;
}

void fragment() {
	// Select frame based on view angle (16 frames in 4x4 grid)
	float angle = atan(view_direction.x, view_direction.z);
	
	// Apply object rotation
	angle -= rotation_offset;
	
	float normalized = (angle + PI) / (2.0 * PI);
	int total_frames = atlas_columns * atlas_rows;
	int frame = int(normalized * float(total_frames)) % total_frames;
	
	// Calculate UV within the atlas
	float col = float(frame % atlas_columns);
	float row = float(frame / atlas_columns);
	vec2 frame_size = vec2(1.0 / float(atlas_columns), 1.0 / float(atlas_rows));
	vec2 atlas_uv = vec2(col, row) * frame_size + UV * frame_size;
	
	// Sample from texture array
	vec4 tex = texture(texture_atlas, vec3(atlas_uv, texture_layer));
	
	// Alpha test
	if (tex.a < 0.1) {
		discard;
	}

	// Distance fade-in (impostors appear when real objects disappear)
	// Real objects fade OUT from (fade_distance - fade_margin) to fade_distance
	// Impostors fade IN from (fade_distance - fade_margin) to fade_distance
	float fade = smoothstep(fade_distance - fade_margin, fade_distance, dist_to_camera);
	tex.a *= fade;
	
	ALBEDO = tex.rgb;
	ALPHA = tex.a;
}
"""

#endregion


#region Job System for Async Texture Loading

func _start_job_system() -> void:
	if _job_system != null:
		return

	_job_system = BackgroundJobSystemScript.new()
	var err: Error = _job_system.start(2)  # 2 worker threads
	if err != OK:
		push_error("[NativeImpostorRenderer] Failed to start job system: %s" % error_string(err))
		push_error("[NativeImpostorRenderer] Falling back to synchronous texture loading")
		_job_system = null


func _stop_job_system() -> void:
	if _job_system == null:
		return
	
	_job_system.stop()
	_job_system = null
	_pending_job_ids.clear()


func _submit_texture_load_job(hash_key: String, texture_path: String) -> void:
	if _job_system == null:
		return

	var load_callable := func() -> Dictionary:
		var image := Image.new()
		var err := image.load(texture_path)
		if err == OK:
			return {"hash_key": hash_key, "image": image, "success": true}
		else:
			return {"hash_key": hash_key, "image": null, "success": false}

	var job_id: int = _job_system.submit(load_callable, "texture", 0)
	if job_id >= 0:
		_pending_job_ids[hash_key] = job_id
		if debug_enabled:
			_debug("Submitted async texture load job %d for hash %s" % [job_id, hash_key])


## Synchronous texture loading fallback
func _load_texture_sync(hash_key: String, texture_path: String) -> void:
	var image := Image.new()
	var err := image.load(texture_path)
	if err == OK:
		if debug_enabled:
			_debug("Loaded texture synchronously: %s" % texture_path)
		_on_texture_loaded(hash_key, image)
	else:
		push_warning("[NativeImpostorRenderer] Failed to load texture: %s (%s)" % [texture_path, error_string(err)])
		# Use fallback
		_on_texture_loaded(hash_key, _get_fallback_image())


## Get or create fallback texture image (magenta/pink for visibility)
func _get_fallback_image() -> Image:
	if _fallback_texture == null:
		var img := Image.create(512, 512, false, Image.FORMAT_RGBA8)
		img.fill(Color(1.0, 0.0, 1.0, 1.0))  # Magenta
		_fallback_texture = ImageTexture.create_from_image(img)
		if debug_enabled:
			_debug("Created fallback impostor texture (magenta)")
	return _fallback_texture.get_image()

#endregion


#region Main Update

func _process(delta: float) -> void:
	# Poll for completed texture loads
	_poll_job_results()
	
	# Rebuild texture array if needed
	if _texture_array_dirty:
		var time_since_add := Time.get_ticks_msec() / 1000.0 - _last_texture_add_time
		if time_since_add >= TEXTURE_ARRAY_REBUILD_DELAY:
			_rebuild_texture_array()
			_rebuild_multimesh()


func _poll_job_results() -> void:
	if _job_system == null:
		return
	
	var results: Array = _job_system.poll_results(10)
	
	for result in results:
		if result.status != BackgroundJobSystemScript.JobStatus.COMPLETED:
			continue
		
		var data: Dictionary = result.result
		if data == null or not data.get("success", false):
			continue
		
		var hash_key: String = data.get("hash_key", "")
		var image: Image = data.get("image")
		
		if hash_key.is_empty() or image == null:
			continue
		
		_pending_job_ids.erase(hash_key)
		_on_texture_loaded(hash_key, image)

#endregion


#region Public API

## Set the impostor candidates reference
func set_impostor_candidates(candidates: ImpostorCandidatesScript) -> void:
	impostor_candidates = candidates


## Add an impostor for a model at a specific world position
## Returns impostor_id or -1 if texture not yet loaded
func add_impostor(
	model_path: String,
	cell_grid: Vector2i,
	world_position: Vector3,
	world_rotation: Vector3 = Vector3.ZERO,
	world_scale: Vector3 = Vector3.ONE
) -> int:
	# Check if this model should have an impostor
	if impostor_candidates and not impostor_candidates.should_have_impostor(model_path):
		return -1
	
	var hash_key: String = ImpostorCandidatesScript.get_hash_key(model_path)
	
	# Get impostor metadata for size
	var metadata := _get_or_load_metadata(model_path)
	var impostor_size := Vector2(10.0, 10.0)
	var aabb_center_y: float = 0.0
	
	if not metadata.is_empty():
		var bounds: Dictionary = metadata.get("bounds", {})
		if not bounds.is_empty():
			impostor_size.x = bounds.get("width", 10.0)
			impostor_size.y = bounds.get("height", 10.0)
			var center_arr: Variant = bounds.get("center", [])
			if center_arr is Array and (center_arr as Array).size() >= 2:
				aabb_center_y = (center_arr as Array)[1] as float
	
	# If texture already loaded, create impostor immediately
	if hash_key in _impostor_textures:
		return _create_impostor(model_path, cell_grid, hash_key, world_position, world_rotation, world_scale, impostor_size, aabb_center_y)
	
	# Queue for async load
	if hash_key not in _pending_impostors:
		_pending_impostors[hash_key] = []

		# Start texture load
		var texture_path := ImpostorCandidatesScript.get_impostor_texture_path(model_path)
		if debug_enabled:
			_debug("Checking impostor texture: %s" % texture_path)
			_debug("File exists: %s" % FileAccess.file_exists(texture_path))

		if FileAccess.file_exists(texture_path):
			# Try async loading first
			if _job_system != null:
				_submit_texture_load_job(hash_key, texture_path)
			else:
				# Fallback to synchronous loading if job system failed
				_load_texture_sync(hash_key, texture_path)
		else:
			if debug_enabled:
				_debug("Impostor texture not found, using fallback for: %s" % model_path)
			# Use fallback texture immediately
			_on_texture_loaded(hash_key, _get_fallback_image())
	
	# Queue the impostor
	var pending := PendingImpostor.new()
	pending.model_path = model_path
	pending.cell_grid = cell_grid
	pending.position = world_position
	pending.rotation = world_rotation
	pending.scale = world_scale
	pending.texture_size = impostor_size
	pending.aabb_center_y = aabb_center_y
	(_pending_impostors[hash_key] as Array).append(pending)
	
	return -1


## Remove an impostor by ID
func remove_impostor(impostor_id: int) -> void:
	if impostor_id in _impostors:
		_impostors.erase(impostor_id)
		_stats["total_impostors"] = _impostors.size()


## Clear all impostors
func clear() -> void:
	_impostors.clear()
	_stats["total_impostors"] = 0
	
	if _master_multimesh:
		_master_multimesh.instance_count = 0


## Get statistics
func get_stats() -> Dictionary:
	return _stats.duplicate()


## Update impostor area: load new cells, unload old ones
## Called by streaming manager
func update_impostor_area(center_cell: Vector2i, radius: int) -> void:
	if not impostor_candidates:
		return
		
	# 1. Calculate cells that SHOULD be loaded
	var desired_cells: Dictionary = {}
	var radius_sq := float(radius * radius)
	
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var grid := Vector2i(center_cell.x + dx, center_cell.y + dy)
			if DU.cell_distance_squared(center_cell, grid) <= radius_sq:
				desired_cells[grid] = true
	
	# 2. Unload cells that are no longer in range
	var cells_to_unload: Array[Vector2i] = []
	for grid: Vector2i in _loaded_impostor_cells:
		if grid not in desired_cells:
			cells_to_unload.append(grid)
			
	if not cells_to_unload.is_empty():
		_unload_impostors_in_cells(cells_to_unload)
	
	# 3. Load new cells
	var cells_to_load: Array[Vector2i] = []
	for grid: Vector2i in desired_cells:
		if grid not in _loaded_impostor_cells:
			cells_to_load.append(grid)
			_loaded_impostor_cells[grid] = true
			
	if not cells_to_load.is_empty():
		_debug("Loading impostors for %d new cells" % cells_to_load.size())
		for grid in cells_to_load:
			_load_impostors_from_cell_record(grid)


## Unload impostors belonging to specific cells
func _unload_impostors_in_cells(grids: Array[Vector2i]) -> void:
	var grid_set: Dictionary = {}
	for g in grids:
		grid_set[g] = true
		_loaded_impostor_cells.erase(g)
		
	# Remove active impostors
	var ids_to_remove: Array[int] = []
	for id: int in _impostors:
		var imp: ImpostorData = _impostors[id]
		if imp.cell_grid in grid_set:
			ids_to_remove.append(id)
			
	for id in ids_to_remove:
		_impostors.erase(id)
		
	_stats["total_impostors"] = _impostors.size()
	
	# Remove pending impostors
	for hash_key: String in _pending_impostors:
		var list: Array = _pending_impostors[hash_key]
		var i := list.size() - 1
		while i >= 0:
			var pending: PendingImpostor = list[i]
			if pending.cell_grid in grid_set:
				list.remove_at(i)
			i -= 1
			
	_debug("Unloaded %d cells, removed %d impostors" % [grids.size(), ids_to_remove.size()])


## Internal helper to load impostors from ESM record
func _load_impostors_from_cell_record(grid: Vector2i) -> void:
	if not ESMManager:
		return
		
	var cell_record = ESMManager.get_exterior_cell(grid.x, grid.y)
	if not cell_record:
		return
		
	# Iterate over all references in the cell
	for ref in cell_record.references:
		# Lookup the record to get the model path (CellReference doesn't have it directly)
		var record = ESMManager.get_any_record(str(ref.ref_id))
		if not record or not ("model" in record) or not record.model:
			continue
			
		var model_path: String = record.model
		if model_path.is_empty():
			continue
			
		# Check if it needs an impostor
		if impostor_candidates.should_have_impostor(model_path):
			# Convert coordinates using CS (CoordinateSystem)
			# CS assumes "ref" has position/rotation/scale.
			# Or we can use the raw values if we know them.
			# To be safe and consistent with ReferenceInstantiator:
			var pos := CS.vector_to_godot(ref.position)
			var scale_vec := CS.scale_to_godot(ref.scale)
			var basis := CS.esm_rotation_to_godot_basis(ref.rotation)
			var rot_euler := basis.get_euler() # We store Euler for simplicity
			
			add_impostor(model_path, grid, pos, rot_euler, scale_vec)


func _debug(msg: String) -> void:
	if debug_enabled:
		print("[NativeImpostorRenderer] %s" % msg)

#endregion


#region Internal Implementation

func _on_texture_loaded(hash_key: String, image: Image) -> void:
	# Create texture and cache
	var texture := ImageTexture.create_from_image(image)
	if not texture:
		return
	
	_impostor_textures[hash_key] = texture
	_stats["texture_cache_size"] = _impostor_textures.size()
	
	# Add to texture array
	_add_to_texture_array(hash_key, image)
	
	# Create all pending impostors
	if hash_key in _pending_impostors:
		var pending_list: Array = _pending_impostors[hash_key]
		for pending: PendingImpostor in pending_list:
			_create_impostor(
				pending.model_path,
				pending.cell_grid,
				hash_key,
				pending.position,
				pending.rotation,
				pending.scale,
				pending.texture_size,
				pending.aabb_center_y
			)
		_pending_impostors.erase(hash_key)


func _create_impostor(
	model_path: String,
	cell_grid: Vector2i,
	hash_key: String,
	position: Vector3,
	rotation: Vector3,
	scale: Vector3,
	texture_size: Vector2,
	aabb_center_y: float
) -> int:
	var texture_index: int = _texture_index_map.get(hash_key, 0)
	
	var impostor := ImpostorData.new()
	impostor.id = _next_id
	impostor.cell_grid = cell_grid
	impostor.model_path = model_path
	impostor.texture_hash = hash_key
	impostor.texture_index = texture_index
	impostor.position = position
	impostor.rotation = rotation
	impostor.scale = scale
	impostor.texture_size = texture_size
	impostor.aabb_center_y = aabb_center_y
	
	_next_id += 1
	_impostors[impostor.id] = impostor
	_stats["total_impostors"] = _impostors.size()
	
	impostor_created.emit(impostor.id, model_path)
	
	return impostor.id


func _add_to_texture_array(hash_key: String, image: Image) -> int:
	if hash_key in _texture_index_map:
		return _texture_index_map[hash_key]
	
	if _texture_array_size >= MAX_TEXTURE_ARRAY_LAYERS:
		push_error("[NativeImpostorRenderer] Texture array limit reached")
		return 0
	
	var index := _texture_array_size
	_texture_index_map[hash_key] = index
	_texture_array_size += 1
	
	# Resize image to standard size
	var img_copy := image.duplicate() as Image
	if img_copy.get_size() != Vector2i(512, 512):
		img_copy.resize(512, 512, Image.INTERPOLATE_LANCZOS)
	
	_all_array_images.append(img_copy)
	_texture_array_dirty = true
	_last_texture_add_time = Time.get_ticks_msec() / 1000.0
	
	_stats["texture_array_layers"] = _texture_array_size
	
	return index


func _rebuild_texture_array() -> void:
	if _all_array_images.is_empty():
		_texture_array_dirty = false
		return
	
	var images: Array[Image] = []
	for img: Image in _all_array_images:
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		images.append(img)
	
	_texture_array = Texture2DArray.new()
	var err := _texture_array.create_from_images(images)
	if err != OK:
		push_error("[NativeImpostorRenderer] Failed to create texture array")
		_texture_array_dirty = false
		return
	
	_billboard_material.set_shader_parameter("texture_atlas", _texture_array)
	_texture_array_dirty = false


func _rebuild_multimesh() -> void:
	var impostor_count := _impostors.size()
	
	if impostor_count == 0:
		_master_multimesh.instance_count = 0
		return
	
	_master_multimesh.instance_count = impostor_count
	
	var idx := 0
	for impostor_id: int in _impostors:
		var impostor: ImpostorData = _impostors[impostor_id]
		
		# Wait, if we are loading from ESM raw data, we need to convert coords!
		# Using CS.convert_transform(pos, rot, scale)
		var transform := Transform3D()
		# If this came from add_impostor with raw data...
		# Note: add_impostor receives "world_position", "world_rotation". 
		# If _load_impostors_from_cell_record calls it with raw MW data, we have a problem.
		# Let's fix _load_impostors_from_cell_record to convert first.
		
		var billboard_pos := impostor.position
		billboard_pos.y += impostor.aabb_center_y * impostor.scale.y
		
		# Create transform with scale based on texture size
		var scale_x := impostor.texture_size.x * impostor.scale.x
		var scale_y := impostor.texture_size.y * impostor.scale.y

		transform = transform.scaled(Vector3(scale_x, scale_y, 1.0))
		transform.origin = billboard_pos

		_master_multimesh.set_instance_transform(idx, transform)
		
		# Custom data: x = texture layer, y = rotation.y (radians)
		_master_multimesh.set_instance_custom_data(idx, Color(float(impostor.texture_index), impostor.rotation.y, 0.0, 1.0))
		
		idx += 1


func _get_or_load_metadata(model_path: String) -> Dictionary:
	var hash_key := ImpostorCandidatesScript.get_hash_key(model_path)
	
	if hash_key in _impostor_metadata:
		return _impostor_metadata[hash_key]
	
	var metadata_path := ImpostorCandidatesScript.get_impostor_metadata_path(model_path)
	if not FileAccess.file_exists(metadata_path):
		return {}
	
	var file := FileAccess.open(metadata_path, FileAccess.READ)
	if not file:
		return {}
	
	var json_str := file.get_as_text()
	file.close()
	
	var json := JSON.new()
	if json.parse(json_str) != OK:
		return {}
	
	var metadata: Dictionary = json.data
	_impostor_metadata[hash_key] = metadata
	
	return metadata

#endregion
