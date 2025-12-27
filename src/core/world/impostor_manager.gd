## ImpostorManager - High-performance distant impostor rendering
##
## Renders distant landmarks as octahedral impostors (pre-rendered billboards).
## Optimized for minimal frame impact with async loading and spatial culling.
##
## Key features:
## - ASYNC texture loading (no main thread blocking)
## - Spatial cell-based visibility culling (O(visible cells) not O(all impostors))
## - Dirty region tracking (only rebuild changed batches)
## - Texture array batching (single draw call for all impostors)
## - 16-frame octahedral atlas with depth for parallax
##
## Impostor textures are expected in the cache directory:
##   {cache}/impostors/[model_hash]_impostor.png (albedo + depth in alpha)
##   {cache}/impostors/[model_hash]_impostor.json (metadata)
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

## Pending async texture loads: model_path_hash -> texture_path
var _pending_texture_loads: Dictionary = {}

## Impostors waiting for their texture to load: model_path_hash -> Array[PendingImpostor]
var _pending_impostors: Dictionary = {}

## Loaded impostor metadata: model_path_hash -> Dictionary
var _impostor_metadata: Dictionary = {}

## Master MultiMesh for ALL impostors (single draw call)
## Uses custom data to encode texture index for texture array lookup
var _master_multimesh: MultiMesh = null
var _master_instance: MultiMeshInstance3D = null

## Active impostors: impostor_id -> ImpostorInstance
var _impostors: Dictionary = {}

## Impostors by cell: Vector2i -> Array[int] (impostor_ids)
## Used for O(1) cell-based visibility culling
var _impostors_by_cell: Dictionary = {}

## Visible cells cache (updated when camera moves significantly)
var _visible_cells: Dictionary = {}  # Vector2i -> true
var _last_visibility_check_pos: Vector3 = Vector3.INF
var _visibility_check_threshold: float = 50.0  # Re-check every 50 meters

## Next impostor ID
var _next_id: int = 0

## Billboard material with texture array support
var _billboard_material: ShaderMaterial = null

## Texture array for batched rendering
var _texture_array: Texture2DArray = null
var _texture_index_map: Dictionary = {}  # texture_hash -> array_index
var _texture_array_dirty: bool = false
var _pending_array_textures: Array[Image] = []
var _texture_array_size: int = 0
const MAX_TEXTURE_ARRAY_LAYERS: int = 256

## Stats
var _stats: Dictionary = {
	"total_impostors": 0,
	"visible_impostors": 0,
	"texture_cache_size": 0,
	"cells_with_impostors": 0,
	"pending_loads": 0,
	"draw_calls": 1,  # Always 1 with texture array
	"texture_array_layers": 0,
}

## Debug logging enabled
var debug_enabled: bool = false

## Dirty tracking for efficient rebuilds
var _dirty_cells: Dictionary = {}  # Vector2i -> true (cells needing rebuild)
var _full_rebuild_needed: bool = false
var _rebuild_timer: float = 0.0
const REBUILD_DELAY: float = 0.05  # Batch rebuilds over 50ms

## Distance thresholds (cached from tier manager)
var _min_distance_sq: float = 250000.0  # 500m squared
var _max_distance_sq: float = 25000000.0  # 5000m squared


## Pending impostor data (waiting for texture)
class PendingImpostor:
	var model_path: String
	var position: Vector3
	var rotation: Vector3
	var scale: Vector3
	var cell_grid: Vector2i
	var texture_size: Vector2


## Impostor instance data
class ImpostorInstance:
	var id: int
	var model_path: String
	var texture_hash: String
	var texture_index: int  # Index in texture array
	var position: Vector3
	var rotation: Vector3
	var scale: Vector3
	var cell_grid: Vector2i
	var visible: bool = true
	var texture_size: Vector2


func _enter_tree() -> void:
	_scenario = get_viewport().get_world_3d().scenario
	_setup_master_multimesh()
	_setup_billboard_material()


func _exit_tree() -> void:
	clear()


func _process(delta: float) -> void:
	# Poll async texture loads
	_poll_pending_textures()

	# Rebuild texture array if needed
	if _texture_array_dirty:
		_rebuild_texture_array()

	# Deferred batch rebuild with timer (coalesce multiple changes)
	if not _dirty_cells.is_empty() or _full_rebuild_needed:
		_rebuild_timer += delta
		if _rebuild_timer >= REBUILD_DELAY:
			_rebuild_multimesh()
			_rebuild_timer = 0.0


## Set up the master MultiMesh for single draw call rendering
func _setup_master_multimesh() -> void:
	_master_multimesh = MultiMesh.new()
	_master_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_master_multimesh.use_custom_data = true  # For texture index

	# Create quad mesh for billboard
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)  # Size controlled by transform scale
	_master_multimesh.mesh = quad

	_master_instance = MultiMeshInstance3D.new()
	_master_instance.multimesh = _master_multimesh
	_master_instance.name = "ImpostorMasterBatch"
	add_child(_master_instance)


## Set up the billboard material with texture array support
func _setup_billboard_material() -> void:
	var shader := Shader.new()
	shader.code = _get_optimized_shader_code()

	_billboard_material = ShaderMaterial.new()
	_billboard_material.shader = shader
	_billboard_material.set_shader_parameter("atlas_columns", 4)
	_billboard_material.set_shader_parameter("atlas_rows", 4)
	_billboard_material.set_shader_parameter("use_parallax", true)
	_billboard_material.set_shader_parameter("parallax_depth", 0.15)

	_master_instance.material_override = _billboard_material


## Optimized shader with texture array, 16-frame atlas, and parallax
func _get_optimized_shader_code() -> String:
	return """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, shadows_disabled;

// Texture array containing all impostor atlases
uniform sampler2DArray texture_atlas : source_color, filter_linear_mipmap;
uniform float alpha_cutoff : hint_range(0.0, 1.0) = 0.5;

// Atlas configuration (4x4 = 16 frames for smooth rotation)
uniform int atlas_columns = 4;
uniform int atlas_rows = 4;

// Parallax settings
uniform bool use_parallax = true;
uniform float parallax_depth : hint_range(0.0, 0.5) = 0.15;

// Frame interpolation
uniform bool interpolate_frames = true;
uniform float interpolation_sharpness = 4.0;

varying vec3 view_direction;
varying flat float texture_layer;

void vertex() {
	// Get texture layer from instance custom data (x component)
	texture_layer = INSTANCE_CUSTOM.x;

	// Get view direction in world space
	vec3 camera_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 world_pos = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	view_direction = normalize(camera_pos - world_pos);

	// Billboard: rotate to face camera (Y-axis only for upright billboards)
	vec3 look_dir = normalize(vec3(view_direction.x, 0.0, view_direction.z));
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), look_dir));
	vec3 up = vec3(0.0, 1.0, 0.0);

	// Build billboard matrix
	mat4 billboard = mat4(
		vec4(right, 0.0),
		vec4(up, 0.0),
		vec4(look_dir, 0.0),
		MODEL_MATRIX[3]
	);

	// Apply scale from model matrix
	float scale_x = length(MODEL_MATRIX[0].xyz);
	float scale_y = length(MODEL_MATRIX[1].xyz);
	float scale_z = length(MODEL_MATRIX[2].xyz);

	billboard[0] *= scale_x;
	billboard[1] *= scale_y;
	billboard[2] *= scale_z;

	MODELVIEW_MATRIX = VIEW_MATRIX * billboard;
}

// Convert view direction to frame index (0-15 for 4x4 atlas)
int get_frame_index(vec3 view_dir) {
	float angle = atan(view_dir.x, view_dir.z);  // -PI to PI
	float normalized = (angle + PI) / (2.0 * PI);  // 0-1
	int frame = int(normalized * float(atlas_columns * atlas_rows)) % (atlas_columns * atlas_rows);
	return frame;
}

// Get UV offset for a frame index
vec2 get_frame_uv(int frame_index, vec2 uv) {
	float col = float(frame_index % atlas_columns);
	float row = float(frame_index / atlas_columns);
	vec2 frame_size = vec2(1.0 / float(atlas_columns), 1.0 / float(atlas_rows));
	return vec2(col, row) * frame_size + uv * frame_size;
}

// Sample with parallax offset
vec4 sample_with_parallax(vec3 view_dir, vec2 uv, int frame, float layer) {
	vec2 atlas_uv = get_frame_uv(frame, uv);

	if (!use_parallax) {
		return texture(texture_atlas, vec3(atlas_uv, layer));
	}

	// Simple parallax offset based on view angle
	vec2 parallax_offset = vec2(view_dir.x, -view_dir.y) * parallax_depth * (1.0 - uv.y);
	vec2 frame_size = vec2(1.0 / float(atlas_columns), 1.0 / float(atlas_rows));

	// Clamp offset to stay within frame bounds
	vec2 offset_uv = atlas_uv + parallax_offset * frame_size;
	vec2 frame_min = get_frame_uv(frame, vec2(0.0, 0.0));
	vec2 frame_max = get_frame_uv(frame, vec2(1.0, 1.0));
	offset_uv = clamp(offset_uv, frame_min, frame_max);

	return texture(texture_atlas, vec3(offset_uv, layer));
}

// Smoothly blend between two frames
vec4 sample_interpolated(vec3 view_dir, vec2 uv, float layer) {
	float angle = atan(view_dir.x, view_dir.z) + PI;  // 0 to 2*PI
	float total_frames = float(atlas_columns * atlas_rows);
	float frame_angle = angle / (2.0 * PI) * total_frames;  // 0 to 16

	int frame_a = int(floor(frame_angle)) % int(total_frames);
	int frame_b = (frame_a + 1) % int(total_frames);
	float blend = fract(frame_angle);

	// Sharpen the blend for less ghosting
	blend = smoothstep(0.5 - 0.5/interpolation_sharpness, 0.5 + 0.5/interpolation_sharpness, blend);

	vec4 color_a = sample_with_parallax(view_dir, uv, frame_a, layer);
	vec4 color_b = sample_with_parallax(view_dir, uv, frame_b, layer);

	return mix(color_a, color_b, blend);
}

void fragment() {
	vec4 tex;

	if (interpolate_frames) {
		tex = sample_interpolated(view_direction, UV, texture_layer);
	} else {
		int frame = get_frame_index(view_direction);
		tex = sample_with_parallax(view_direction, UV, frame, texture_layer);
	}

	// Alpha test
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
## Returns impostor_id or -1 if texture not yet loaded (will be added when ready)
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

	var hash_key: String = str(model_path.to_lower().hash())

	# Get impostor metadata for size
	var metadata: Dictionary = _get_or_load_impostor_metadata(model_path)
	var impostor_size: Vector2 = Vector2(10.0, 10.0)
	if not metadata.is_empty():
		var bounds: Dictionary = metadata.get("bounds", {})
		if not bounds.is_empty():
			impostor_size.x = bounds.get("width", 10.0)
			impostor_size.y = bounds.get("height", 10.0)
		else:
			impostor_size.x = metadata.get("width", 10.0)
			impostor_size.y = metadata.get("height", 10.0)

	# Check if texture is already loaded
	if hash_key in _impostor_textures:
		return _create_impostor_instance(model_path, hash_key, world_position, world_rotation, world_scale, cell_grid, impostor_size)

	# Check if texture is pending load
	if hash_key in _pending_texture_loads:
		# Queue this impostor to be created when texture loads
		_queue_pending_impostor(hash_key, model_path, world_position, world_rotation, world_scale, cell_grid, impostor_size)
		return -1

	# Start async texture load
	var texture_path: String = ImpostorCandidatesScript.get_impostor_texture_path(model_path)
	if not FileAccess.file_exists(texture_path):
		return -1

	# Use ResourceLoader for async loading
	var err := ResourceLoader.load_threaded_request(texture_path, "Image", false, ResourceLoader.CACHE_MODE_IGNORE)
	if err == OK:
		_pending_texture_loads[hash_key] = texture_path
		_stats["pending_loads"] = _pending_texture_loads.size()

		# Queue this impostor
		_queue_pending_impostor(hash_key, model_path, world_position, world_rotation, world_scale, cell_grid, impostor_size)

		if debug_enabled:
			print("ImpostorManager: Started async load for %s" % texture_path.get_file())

	return -1


## Queue an impostor to be created when its texture loads
func _queue_pending_impostor(hash_key: String, model_path: String, pos: Vector3, rot: Vector3, scl: Vector3, cell: Vector2i, size: Vector2) -> void:
	if hash_key not in _pending_impostors:
		_pending_impostors[hash_key] = []

	var pending := PendingImpostor.new()
	pending.model_path = model_path
	pending.position = pos
	pending.rotation = rot
	pending.scale = scl
	pending.cell_grid = cell
	pending.texture_size = size

	(_pending_impostors[hash_key] as Array).append(pending)


## Poll for completed async texture loads
func _poll_pending_textures() -> void:
	if _pending_texture_loads.is_empty():
		return

	var completed: Array[String] = []

	for hash_key: String in _pending_texture_loads:
		var texture_path: String = _pending_texture_loads[hash_key]
		var status := ResourceLoader.load_threaded_get_status(texture_path)

		if status == ResourceLoader.THREAD_LOAD_LOADED:
			var image: Image = ResourceLoader.load_threaded_get(texture_path) as Image
			if image:
				_on_texture_loaded(hash_key, image)
			completed.append(hash_key)
		elif status == ResourceLoader.THREAD_LOAD_FAILED:
			if debug_enabled:
				push_warning("ImpostorManager: Failed to load %s" % texture_path)
			completed.append(hash_key)
			# Clean up pending impostors for this texture
			_pending_impostors.erase(hash_key)

	for hash_key: String in completed:
		_pending_texture_loads.erase(hash_key)

	_stats["pending_loads"] = _pending_texture_loads.size()


## Called when a texture finishes loading
func _on_texture_loaded(hash_key: String, image: Image) -> void:
	# Create texture and cache it
	var texture := ImageTexture.create_from_image(image)
	if not texture:
		return

	_impostor_textures[hash_key] = texture
	_stats["texture_cache_size"] = _impostor_textures.size()

	# Add to texture array
	var texture_index := _add_to_texture_array(hash_key, image)

	# Create all pending impostors for this texture
	if hash_key in _pending_impostors:
		var pending_list: Array = _pending_impostors[hash_key]
		for pending: PendingImpostor in pending_list:
			_create_impostor_instance(
				pending.model_path,
				hash_key,
				pending.position,
				pending.rotation,
				pending.scale,
				pending.cell_grid,
				pending.texture_size
			)
		_pending_impostors.erase(hash_key)

	if debug_enabled:
		print("ImpostorManager: Texture loaded, index %d" % texture_index)


## Add texture to the texture array
func _add_to_texture_array(hash_key: String, image: Image) -> int:
	if hash_key in _texture_index_map:
		return _texture_index_map[hash_key]

	if _texture_array_size >= MAX_TEXTURE_ARRAY_LAYERS:
		push_warning("ImpostorManager: Texture array full (%d layers)" % MAX_TEXTURE_ARRAY_LAYERS)
		return 0

	var index := _texture_array_size
	_texture_index_map[hash_key] = index
	_texture_array_size += 1

	# Resize image to standard size if needed
	var target_size := Vector2i(512, 512)  # 4x4 atlas of 128x128 frames
	if image.get_size() != target_size:
		image.resize(target_size.x, target_size.y, Image.INTERPOLATE_LANCZOS)

	_pending_array_textures.append(image)
	_texture_array_dirty = true

	_stats["texture_array_layers"] = _texture_array_size

	return index


## Rebuild the texture array from pending images
func _rebuild_texture_array() -> void:
	if _pending_array_textures.is_empty() and _texture_array != null:
		_texture_array_dirty = false
		return

	# Collect all images
	var images: Array[Image] = []

	# Get existing images from current texture array
	if _texture_array != null:
		for i in range(_texture_array.get_layers()):
			var layer_image := _texture_array.get_layer_data(i)
			if layer_image:
				images.append(layer_image)

	# Add pending images
	images.append_array(_pending_array_textures)
	_pending_array_textures.clear()

	if images.is_empty():
		_texture_array_dirty = false
		return

	# Ensure all images have same format
	var target_format := Image.FORMAT_RGBA8
	for i in range(images.size()):
		if images[i].get_format() != target_format:
			images[i].convert(target_format)

	# Create new texture array
	var size: Vector2i = images[0].get_size()
	_texture_array = Texture2DArray.new()
	_texture_array.create_from_images(images)

	# Update material
	_billboard_material.set_shader_parameter("texture_atlas", _texture_array)

	_texture_array_dirty = false

	if debug_enabled:
		print("ImpostorManager: Rebuilt texture array with %d layers" % images.size())


## Create the actual impostor instance
func _create_impostor_instance(
	model_path: String,
	hash_key: String,
	world_position: Vector3,
	world_rotation: Vector3,
	world_scale: Vector3,
	cell_grid: Vector2i,
	impostor_size: Vector2
) -> int:
	# Get texture index
	var texture_index: int = _texture_index_map.get(hash_key, 0)

	# Create impostor instance
	var impostor := ImpostorInstance.new()
	impostor.id = _next_id
	impostor.model_path = model_path
	impostor.texture_hash = hash_key
	impostor.texture_index = texture_index
	impostor.position = world_position
	impostor.rotation = world_rotation
	impostor.scale = world_scale
	impostor.cell_grid = cell_grid
	impostor.visible = true
	impostor.texture_size = impostor_size

	_impostors[_next_id] = impostor
	_next_id += 1

	# Track by cell for spatial culling
	if cell_grid not in _impostors_by_cell:
		_impostors_by_cell[cell_grid] = []
		_stats["cells_with_impostors"] = _impostors_by_cell.size()
	(_impostors_by_cell[cell_grid] as Array).append(impostor.id)

	# Update stats
	_stats["total_impostors"] = _impostors.size()
	_stats["visible_impostors"] = _impostors.size()  # Will be updated by visibility check

	# Mark cell as dirty for rebuild
	_dirty_cells[cell_grid] = true

	return impostor.id


## Add impostors for all eligible objects in a cell
## Returns number of impostors added (may be 0 if textures are loading async)
func add_cell_impostors(cell_grid: Vector2i, references: Array) -> int:
	var count: int = 0

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

		# Check if should have impostor (fast path - check before doing anything else)
		if impostor_candidates and not impostor_candidates.should_have_impostor(model_path):
			continue

		# Calculate world position/rotation/scale
		var pos: Vector3 = CS.vector_to_godot(cell_ref.position)
		var rot_basis: Basis = CS.esm_rotation_to_godot_basis(cell_ref.rotation)
		var scl: Vector3 = CS.scale_to_godot(cell_ref.scale)

		# Add impostor (may return -1 if async loading)
		var id: int = add_impostor(model_path, pos, rot_basis.get_euler(), scl, cell_grid)
		if id >= 0:
			count += 1

	return count


## Remove an impostor by ID
func remove_impostor(impostor_id: int) -> void:
	if impostor_id not in _impostors:
		return

	var impostor: ImpostorInstance = _impostors[impostor_id]
	var cell_grid: Vector2i = impostor.cell_grid

	# Remove from cell tracking
	if cell_grid in _impostors_by_cell:
		var cell_arr: Array = _impostors_by_cell[cell_grid]
		cell_arr.erase(impostor_id)
		if cell_arr.is_empty():
			_impostors_by_cell.erase(cell_grid)

	_impostors.erase(impostor_id)

	# Update stats
	_stats["total_impostors"] = _impostors.size()
	_stats["cells_with_impostors"] = _impostors_by_cell.size()

	# Mark cell as dirty
	_dirty_cells[cell_grid] = true


## Remove all impostors for a cell
func remove_impostors_for_cell(cell_grid: Vector2i) -> void:
	if cell_grid not in _impostors_by_cell:
		return

	# Copy array since we're modifying it
	var impostor_ids: Array = (_impostors_by_cell[cell_grid] as Array).duplicate()
	for id: int in impostor_ids:
		if id in _impostors:
			_impostors.erase(id)

	_impostors_by_cell.erase(cell_grid)

	# Update stats
	_stats["total_impostors"] = _impostors.size()
	_stats["cells_with_impostors"] = _impostors_by_cell.size()

	# Mark for full rebuild since we removed a whole cell
	_full_rebuild_needed = true


## Update visibility for impostors based on camera distance
## Uses cell-based spatial culling for O(visible cells) complexity
func update_impostor_visibility(camera_pos: Vector3, min_distance: float, max_distance: float) -> int:
	# Cache squared distances
	_min_distance_sq = min_distance * min_distance
	_max_distance_sq = max_distance * max_distance

	# Check if we need to recalculate visible cells
	var dist_moved := camera_pos.distance_squared_to(_last_visibility_check_pos)
	if dist_moved < _visibility_check_threshold * _visibility_check_threshold:
		return 0  # Haven't moved enough, skip update

	_last_visibility_check_pos = camera_pos

	# Update visible cells based on distance
	var changes: int = 0
	var new_visible_cells: Dictionary = {}

	# Only check cells that have impostors
	for cell_grid: Vector2i in _impostors_by_cell:
		# Calculate cell center distance (approximate)
		# Cell size is ~117m in Morrowind
		var cell_center := Vector3(cell_grid.x * 117.0 + 58.5, camera_pos.y, -cell_grid.y * 117.0 - 58.5)
		var dist_sq := camera_pos.distance_squared_to(cell_center)

		var cell_visible := dist_sq >= _min_distance_sq and dist_sq <= _max_distance_sq

		if cell_visible:
			new_visible_cells[cell_grid] = true

		# Check if visibility changed for this cell
		var was_visible: bool = cell_grid in _visible_cells
		if cell_visible != was_visible:
			# Update all impostors in this cell
			var cell_impostors: Array = _impostors_by_cell[cell_grid]
			for impostor_id: int in cell_impostors:
				if impostor_id in _impostors:
					var impostor: ImpostorInstance = _impostors[impostor_id]
					impostor.visible = cell_visible
					changes += 1

			# Mark cell as dirty
			_dirty_cells[cell_grid] = true

	_visible_cells = new_visible_cells

	# Update stats
	var visible_count: int = 0
	for cell_grid: Vector2i in _visible_cells:
		if cell_grid in _impostors_by_cell:
			visible_count += (_impostors_by_cell[cell_grid] as Array).size()
	_stats["visible_impostors"] = visible_count

	return changes


## Rebuild the master MultiMesh with current impostor data
func _rebuild_multimesh() -> void:
	# Collect visible impostors
	var visible_impostors: Array[ImpostorInstance] = []

	for cell_grid: Vector2i in _visible_cells:
		if cell_grid not in _impostors_by_cell:
			continue

		var cell_impostors: Array = _impostors_by_cell[cell_grid]
		for impostor_id: int in cell_impostors:
			if impostor_id in _impostors:
				var impostor: ImpostorInstance = _impostors[impostor_id]
				if impostor.visible:
					visible_impostors.append(impostor)

	# Resize MultiMesh
	var count := visible_impostors.size()
	if count == 0:
		_master_multimesh.instance_count = 0
		_master_instance.visible = false
		_dirty_cells.clear()
		_full_rebuild_needed = false
		return

	_master_instance.visible = true
	_master_multimesh.instance_count = count

	# Set transforms and custom data
	for i in range(count):
		var impostor: ImpostorInstance = visible_impostors[i]

		# Build transform
		var xform := Transform3D.IDENTITY

		# Apply size and scale
		var scale_factor: float = impostor.scale.x
		var size_x: float = impostor.texture_size.x * scale_factor
		var size_y: float = impostor.texture_size.y * scale_factor
		xform = xform.scaled(Vector3(size_x, size_y, 1.0))

		# Position with Y offset for center pivot
		xform.origin = impostor.position + Vector3(0, size_y * 0.5, 0)

		_master_multimesh.set_instance_transform(i, xform)

		# Set custom data (texture layer index)
		_master_multimesh.set_instance_custom_data(i, Color(float(impostor.texture_index), 0, 0, 1))

	_dirty_cells.clear()
	_full_rebuild_needed = false

	if debug_enabled:
		print("ImpostorManager: Rebuilt MultiMesh with %d visible impostors" % count)


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

			var json := JSON.new()
			if json.parse(json_str) == OK:
				var data: Dictionary = json.data as Dictionary
				_impostor_metadata[hash_key] = data
				return data

	return {}


## Set visibility for all impostors at once
func set_all_visible(is_visible: bool) -> void:
	for cell_grid: Vector2i in _impostors_by_cell:
		if is_visible:
			_visible_cells[cell_grid] = true
		else:
			_visible_cells.erase(cell_grid)

		var cell_impostors: Array = _impostors_by_cell[cell_grid]
		for impostor_id: int in cell_impostors:
			if impostor_id in _impostors:
				(_impostors[impostor_id] as ImpostorInstance).visible = is_visible

	if is_visible:
		_stats["visible_impostors"] = _stats["total_impostors"]
	else:
		_stats["visible_impostors"] = 0

	_full_rebuild_needed = true


## Clear all impostors
func clear() -> void:
	_impostors.clear()
	_impostors_by_cell.clear()
	_visible_cells.clear()
	_dirty_cells.clear()
	_pending_impostors.clear()
	_pending_texture_loads.clear()
	_impostor_textures.clear()
	_impostor_metadata.clear()
	_texture_index_map.clear()
	_pending_array_textures.clear()
	_texture_array_size = 0
	_texture_array = null

	if _master_multimesh:
		_master_multimesh.instance_count = 0

	_stats["total_impostors"] = 0
	_stats["visible_impostors"] = 0
	_stats["texture_cache_size"] = 0
	_stats["cells_with_impostors"] = 0
	_stats["pending_loads"] = 0
	_stats["texture_array_layers"] = 0

	_full_rebuild_needed = false


## Get statistics
func get_stats() -> Dictionary:
	return _stats.duplicate()


## Check if a cell has impostors
func has_impostors_for_cell(cell_grid: Vector2i) -> bool:
	return cell_grid in _impostors_by_cell and not (_impostors_by_cell[cell_grid] as Array).is_empty()


## Get count of impostors in a cell
func get_cell_impostor_count(cell_grid: Vector2i) -> int:
	if cell_grid not in _impostors_by_cell:
		return 0
	return (_impostors_by_cell[cell_grid] as Array).size()
