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
const DU := preload("res://src/core/world/distance_utils.gd")

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
var _last_visibility_check_pos: Vector3 = Vector3.INF  # INF ensures first check always runs
var _visibility_check_threshold: float = 25.0  # Re-check every 25 meters (more responsive)

## Next impostor ID
var _next_id: int = 0

## Billboard material with texture array support
var _billboard_material: ShaderMaterial = null

## Texture array for batched rendering
var _texture_array: Texture2DArray = null
var _texture_index_map: Dictionary = {}  # texture_hash -> array_index
var _texture_array_dirty: bool = false
var _all_array_images: Array[Image] = []  # Keep all images in memory for rebuilds
var _texture_array_size: int = 0
const MAX_TEXTURE_ARRAY_LAYERS: int = 512  # Increased from 256 - most GPUs support this

## Background texture loading thread
var _texture_load_thread: Thread = null
var _texture_load_mutex: Mutex = null
var _texture_load_queue: Array = []  # Array of {hash_key: String, path: String}
var _loaded_images_queue: Array = []  # Thread-safe results: {hash_key: String, image: Image}
var _thread_should_exit: bool = false

## Texture array rebuild batching - wait for loading to stabilize before rebuilding
var _last_texture_add_time: float = 0.0
const TEXTURE_ARRAY_REBUILD_DELAY: float = 0.3  # Wait 300ms after last texture before rebuilding

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

## Global visibility flag - controlled by Models toggle in world_explorer
## When false, impostors are hidden regardless of individual visibility
var _globally_visible: bool = false

## Track first texture load for one-time diagnostic
var _first_texture_logged: bool = false

## Track first add_cell call for one-time diagnostic
var _first_cell_logged: bool = false

## Track missing textures count (for summary logging, not spam)
var _missing_texture_count: int = 0

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
	_start_texture_load_thread()
	# Start hidden - visibility controlled by Models toggle in world_explorer
	if _master_instance:
		_master_instance.visible = false


func _exit_tree() -> void:
	_stop_texture_load_thread()
	clear()


## Start the background texture loading thread
func _start_texture_load_thread() -> void:
	if _texture_load_thread != null:
		return
	_texture_load_mutex = Mutex.new()
	_thread_should_exit = false
	_texture_load_thread = Thread.new()
	_texture_load_thread.start(_texture_load_worker)


## Stop the background texture loading thread
func _stop_texture_load_thread() -> void:
	if _texture_load_thread == null:
		return
	_thread_should_exit = true
	_texture_load_thread.wait_to_finish()
	_texture_load_thread = null
	_texture_load_mutex = null


## Background thread worker - loads images from disk without blocking main thread
var _thread_work_count: int = 0

func _texture_load_worker() -> void:
	# NOTE: Don't access Node properties (self) from thread - causes error
	# Just do the work silently
	while not _thread_should_exit:
		# Check if there's work to do
		_texture_load_mutex.lock()
		var has_work := not _texture_load_queue.is_empty()
		var work_item: Dictionary = {}
		if has_work:
			work_item = _texture_load_queue.pop_front()
		_texture_load_mutex.unlock()

		if not has_work:
			# Sleep briefly to avoid busy-waiting
			OS.delay_msec(5)
			continue

		_thread_work_count += 1

		# Load the image (this is the slow I/O operation we're offloading)
		var image := Image.new()
		var path_str: String = work_item.path
		if path_str.is_empty():
			continue

		var err := image.load(path_str)

		if err == OK:
			# Queue the result for main thread processing
			_texture_load_mutex.lock()
			_loaded_images_queue.append({
				"hash_key": work_item.hash_key,
				"image": image
			})
			_texture_load_mutex.unlock()


var _process_log_counter: int = 0
var _textures_loaded_this_frame: int = 0
const TEXTURES_PER_FRAME: int = 10  # Process up to 10 loaded textures per frame from thread

var _first_process_logged: bool = false

func _process(delta: float) -> void:
	# Poll for textures loaded by background thread (non-blocking)
	_poll_loaded_images_from_thread()

	# Rebuild texture array if dirty AND enough time has passed since last texture add
	# This batches multiple texture additions into a single rebuild
	if _texture_array_dirty:
		var time_since_last_add := Time.get_ticks_msec() / 1000.0 - _last_texture_add_time
		# Check if there are still textures being loaded (in pending dict OR thread queue)
		var still_loading := not _pending_texture_loads.is_empty() or not _pending_impostors.is_empty()
		if _texture_load_mutex:
			_texture_load_mutex.lock()
			still_loading = still_loading or not _texture_load_queue.is_empty() or not _loaded_images_queue.is_empty()
			_texture_load_mutex.unlock()
		if time_since_last_add >= TEXTURE_ARRAY_REBUILD_DELAY or not still_loading:
			_rebuild_texture_array()

	# Deferred batch rebuild with timer (coalesce multiple changes)
	# Rebuild progressively during loading to show impostors as they become available
	# IMPORTANT: Only rebuild multimesh if texture array is up to date, otherwise
	# impostors would reference non-existent texture layers and render as garbage/white
	if not _dirty_cells.is_empty() or _full_rebuild_needed:
		if _texture_array_dirty:
			# Texture array needs rebuild first - skip multimesh rebuild this frame
			pass
		else:
			_rebuild_timer += delta
			# Use shorter delay during active loading for progressive display
			var rebuild_delay := REBUILD_DELAY if _pending_texture_loads.is_empty() else 0.2
			if _rebuild_timer >= rebuild_delay:
				_rebuild_multimesh()
				_rebuild_timer = 0.0


## Poll for images loaded by the background thread and process them
var _poll_call_count: int = 0

func _poll_loaded_images_from_thread() -> void:
	if _texture_load_mutex == null:
		return

	_textures_loaded_this_frame = 0

	while _textures_loaded_this_frame < TEXTURES_PER_FRAME:
		# Get one loaded image from the thread's result queue
		_texture_load_mutex.lock()
		var has_result := not _loaded_images_queue.is_empty()
		var result: Dictionary = {}
		if has_result:
			result = _loaded_images_queue.pop_front()
		_texture_load_mutex.unlock()

		if not has_result:
			break

		# Process the loaded image on main thread
		_on_texture_loaded(result.hash_key, result.image)
		_textures_loaded_this_frame += 1


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
	# Use 4x4 to match prebaked impostor textures (16 frames)
	_billboard_material.set_shader_parameter("atlas_columns", 4)
	_billboard_material.set_shader_parameter("atlas_rows", 4)

	# Create initial empty texture array (will be replaced when textures load)
	var default_img := Image.create(512, 512, false, Image.FORMAT_RGBA8)
	default_img.fill(Color(0, 0, 0, 0))
	var default_array := Texture2DArray.new()
	default_array.create_from_images([default_img])
	_billboard_material.set_shader_parameter("texture_atlas", default_array)

	_master_instance.material_override = _billboard_material


## Simplified working shader - proven to work in test_impostor_minimal.gd
func _get_optimized_shader_code() -> String:
	return """
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2DArray texture_atlas : source_color;
uniform int atlas_columns = 4;
uniform int atlas_rows = 4;

varying vec3 view_direction;
varying flat float texture_layer;

void vertex() {
	// Get texture layer from instance custom data
	texture_layer = INSTANCE_CUSTOM.x;

	// Calculate view direction
	vec3 camera_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 world_pos = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	view_direction = normalize(camera_pos - world_pos);

	// Y-axis billboard
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

void fragment() {
	// Get frame based on view angle
	float angle = atan(view_direction.x, view_direction.z);
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

	if (tex.a < 0.1) {
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

	# CRITICAL: Use the centralized hash key function to ensure consistency
	# with the impostor baker's path normalization (forward/back slashes, meshes\ prefix)
	var hash_key: String = ImpostorCandidatesScript.get_hash_key(model_path)

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

	# Check if texture is already pending (in dict or thread queue)
	if hash_key in _pending_texture_loads or hash_key in _pending_impostors:
		# Queue this impostor to be created when texture loads
		_queue_pending_impostor(hash_key, model_path, world_position, world_rotation, world_scale, cell_grid, impostor_size)
		return -1

	# Start async texture load
	var texture_path: String = ImpostorCandidatesScript.get_impostor_texture_path(model_path)
	if not FileAccess.file_exists(texture_path):
		# Track missing textures for summary (don't spam per-model)
		_missing_texture_count += 1
		return -1

	# Mark as pending before queueing to avoid duplicate loads
	_pending_texture_loads[hash_key] = texture_path
	_stats["pending_loads"] = _pending_texture_loads.size()

	# Queue this impostor to be created when texture loads
	_queue_pending_impostor(hash_key, model_path, world_position, world_rotation, world_scale, cell_grid, impostor_size)

	# Queue texture for background thread loading (non-blocking)
	_queue_texture_for_background_load(hash_key, texture_path)

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


## Queue pending texture loads to the background thread
## Called when add_impostor discovers a texture needs loading
func _queue_texture_for_background_load(hash_key: String, texture_path: String) -> void:
	if _texture_load_mutex == null:
		# Fallback to synchronous load if thread not available
		var image := Image.new()
		if image.load(texture_path) == OK:
			_on_texture_loaded(hash_key, image)
		else:
			print("[ImpostorManager] Fallback load failed for %s" % texture_path.get_file())
			_pending_impostors.erase(hash_key)
		_pending_texture_loads.erase(hash_key)
		return

	# Queue for background thread
	_texture_load_mutex.lock()
	_texture_load_queue.append({
		"hash_key": hash_key,
		"path": texture_path
	})
	_texture_load_mutex.unlock()

	# Remove from pending dict since it's now in the thread queue
	_pending_texture_loads.erase(hash_key)


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
	var pending_count: int = 0
	if hash_key in _pending_impostors:
		var pending_list: Array = _pending_impostors[hash_key]
		pending_count = pending_list.size()
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


## Add texture to the texture array
func _add_to_texture_array(hash_key: String, image: Image) -> int:
	if hash_key in _texture_index_map:
		return _texture_index_map[hash_key]

	if _texture_array_size >= MAX_TEXTURE_ARRAY_LAYERS:
		# Array is full - find an existing texture to reuse (LRU would be better but this is simpler)
		# For now, just cycle through existing indices
		var fallback_index := hash_key.hash() % MAX_TEXTURE_ARRAY_LAYERS
		_texture_index_map[hash_key] = fallback_index
		return fallback_index

	var index := _texture_array_size
	_texture_index_map[hash_key] = index
	_texture_array_size += 1

	# Resize image to standard size if needed (4x4 atlas of 128x128 frames = 512x512)
	var target_size := Vector2i(512, 512)
	var img_copy := image.duplicate() as Image
	if img_copy.get_size() != target_size:
		img_copy.resize(target_size.x, target_size.y, Image.INTERPOLATE_LANCZOS)

	# Store image for future rebuilds
	_all_array_images.append(img_copy)
	_texture_array_dirty = true

	# Track when we last added a texture (for batched rebuilds)
	_last_texture_add_time = Time.get_ticks_msec() / 1000.0

	_stats["texture_array_layers"] = _texture_array_size

	return index


## Track first texture array rebuild for one-time diagnostic
var _first_array_rebuild_logged: bool = false

## Rebuild the texture array from stored images
func _rebuild_texture_array() -> void:
	if _all_array_images.is_empty():
		_texture_array_dirty = false
		return

	# Use all stored images directly (no need to extract from texture array)
	var images: Array[Image] = []
	for img: Image in _all_array_images:
		# Make sure format is correct
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		images.append(img)

	if images.is_empty():
		_texture_array_dirty = false
		return

	# Create new texture array
	_texture_array = Texture2DArray.new()
	var err := _texture_array.create_from_images(images)
	if err != OK:
		push_error("ImpostorManager: Failed to create texture array from %d images (error %d)" % [images.size(), err])
		_texture_array_dirty = false
		return

	# Update material
	if _billboard_material == null:
		push_error("[ImpostorManager] _billboard_material is NULL during texture array rebuild!")
		_texture_array_dirty = false
		return

	_billboard_material.set_shader_parameter("texture_atlas", _texture_array)

	# Verify material is still on the instance
	if _master_instance and _master_instance.material_override != _billboard_material:
		_master_instance.material_override = _billboard_material

	_texture_array_dirty = false


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
		# New cells default to visible (will be culled by update_impostor_visibility if out of range)
		_visible_cells[cell_grid] = true
	(_impostors_by_cell[cell_grid] as Array).append(impostor.id)

	# Update stats
	_stats["total_impostors"] = _impostors.size()
	_stats["visible_impostors"] = _impostors.size()  # Will be updated by visibility check

	# Mark cell as dirty for rebuild
	_dirty_cells[cell_grid] = true

	# Force visibility update on first impostor to ensure proper distance culling
	if _impostors.size() == 1:
		_last_visibility_check_pos = Vector3.INF

	return impostor.id


## Add impostors for all eligible objects in a cell
## Returns number of impostors added (may be 0 if textures are loading async)
func add_cell_impostors(cell_grid: Vector2i, references: Array) -> int:
	var count: int = 0
	var checked_count: int = 0
	var eligible_count: int = 0
	var missing_texture_count: int = 0

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

		checked_count += 1

		# Check if should have impostor (fast path - check before doing anything else)
		if impostor_candidates and not impostor_candidates.should_have_impostor(model_path):
			continue

		eligible_count += 1

		# Calculate world position/rotation/scale
		var pos: Vector3 = CS.vector_to_godot(cell_ref.position)
		var rot_basis: Basis = CS.esm_rotation_to_godot_basis(cell_ref.rotation)
		var scl: Vector3 = CS.scale_to_godot(cell_ref.scale)

		# Add impostor (may return -1 if async loading)
		var id: int = add_impostor(model_path, pos, rot_basis.get_euler(), scl, cell_grid)
		if id >= 0:
			count += 1
		elif id == -1:
			# Track if this was a missing texture (async loading returns -1 too)
			var hash_key: String = ImpostorCandidatesScript.get_hash_key(model_path)
			if hash_key not in _pending_texture_loads and hash_key not in _impostor_textures:
				missing_texture_count += 1

	return count


## Remove an impostor by ID
func remove_impostor(impostor_id: int) -> void:
	var impostor: Variant = _impostors.get(impostor_id)
	if impostor == null:
		return

	var cell_grid: Vector2i = impostor.cell_grid

	# Remove from cell tracking
	var cell_arr: Variant = _impostors_by_cell.get(cell_grid)
	if cell_arr != null:
		(cell_arr as Array).erase(impostor_id)
		if (cell_arr as Array).is_empty():
			_impostors_by_cell.erase(cell_grid)

	_impostors.erase(impostor_id)

	# Update stats
	_stats["total_impostors"] = _impostors.size()
	_stats["cells_with_impostors"] = _impostors_by_cell.size()

	# Mark cell as dirty
	_dirty_cells[cell_grid] = true


## Remove all impostors for a cell
func remove_impostors_for_cell(cell_grid: Vector2i) -> void:
	var cell_arr: Variant = _impostors_by_cell.get(cell_grid)
	if cell_arr == null:
		return

	# Erase all impostors in this cell
	for id: int in cell_arr:
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
	# Note: _last_visibility_check_pos starts as INF, so first call always passes
	var dist_moved := camera_pos.distance_squared_to(_last_visibility_check_pos)
	var threshold_sq := _visibility_check_threshold * _visibility_check_threshold

	# Also force update if we have impostors but no visible cells (initial state)
	var needs_initial_update := not _impostors_by_cell.is_empty() and _visible_cells.is_empty()

	if dist_moved < threshold_sq and not needs_initial_update:
		return 0  # Haven't moved enough, skip update

	_last_visibility_check_pos = camera_pos

	# Update visible cells based on distance
	var changes: int = 0
	var new_visible_cells: Dictionary = {}

	# Only check cells that have impostors
	for cell_grid: Vector2i in _impostors_by_cell:
		# Calculate cell center distance using centralized utility
		var cell_center := DU.cell_to_world_center(cell_grid, camera_pos.y)
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
				var impostor: Variant = _impostors.get(impostor_id)
				if impostor != null:
					impostor.visible = cell_visible
					changes += 1

			# Mark cell as dirty
			_dirty_cells[cell_grid] = true

	_visible_cells = new_visible_cells

	# Update stats
	var visible_count: int = 0
	for cell_grid: Vector2i in _visible_cells:
		var cell_arr: Variant = _impostors_by_cell.get(cell_grid)
		if cell_arr != null:
			visible_count += (cell_arr as Array).size()
	_stats["visible_impostors"] = visible_count

	return changes


## Track first multimesh rebuild for one-time diagnostic
var _first_multimesh_rebuild_logged: bool = false

## Rebuild the master MultiMesh with current impostor data
func _rebuild_multimesh() -> void:
	# Collect visible impostors
	var visible_impostors: Array[ImpostorInstance] = []

	for cell_grid: Vector2i in _visible_cells:
		var cell_impostors: Variant = _impostors_by_cell.get(cell_grid)
		if cell_impostors == null:
			continue

		for impostor_id: int in cell_impostors:
			var impostor: Variant = _impostors.get(impostor_id)
			if impostor != null and impostor.visible:
				visible_impostors.append(impostor)

	# Resize MultiMesh
	var count := visible_impostors.size()

	if debug_enabled:
		print("ImpostorManager: _rebuild_multimesh - total=%d, visible_cells=%d, visible_impostors=%d, texture_layers=%d" % [
			_impostors.size(), _visible_cells.size(), count, _texture_array_size])

	if count == 0:
		_master_multimesh.instance_count = 0
		_master_instance.visible = false
		_dirty_cells.clear()
		_full_rebuild_needed = false
		return

	# Only show if globally visible (controlled by Models toggle)
	_master_instance.visible = _globally_visible
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


## Get or load impostor metadata for a model
func _get_or_load_impostor_metadata(model_path: String) -> Dictionary:
	var hash_key: String = ImpostorCandidatesScript.get_hash_key(model_path)

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
	# Update global visibility flag
	_globally_visible = is_visible

	for cell_grid: Vector2i in _impostors_by_cell:
		if is_visible:
			_visible_cells[cell_grid] = true
		else:
			_visible_cells.erase(cell_grid)

		var cell_impostors: Array = _impostors_by_cell[cell_grid]
		for impostor_id: int in cell_impostors:
			var impostor: Variant = _impostors.get(impostor_id)
			if impostor != null:
				(impostor as ImpostorInstance).visible = is_visible

	# Also set master instance visibility directly
	if _master_instance:
		_master_instance.visible = is_visible

	if is_visible:
		_stats["visible_impostors"] = _stats["total_impostors"]
		# Force visibility re-check on next update to apply distance culling
		_last_visibility_check_pos = Vector3.INF
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
	_all_array_images.clear()
	_texture_array_size = 0
	_texture_array = null

	# Clear thread queues if thread is running
	if _texture_load_mutex:
		_texture_load_mutex.lock()
		_texture_load_queue.clear()
		_loaded_images_queue.clear()
		_texture_load_mutex.unlock()

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


## Helper to get human-readable image format name
func _format_name(format: int) -> String:
	match format:
		Image.FORMAT_L8: return "L8"
		Image.FORMAT_LA8: return "LA8"
		Image.FORMAT_R8: return "R8"
		Image.FORMAT_RG8: return "RG8"
		Image.FORMAT_RGB8: return "RGB8"
		Image.FORMAT_RGBA8: return "RGBA8"
		Image.FORMAT_RGBA4444: return "RGBA4444"
		Image.FORMAT_RGB565: return "RGB565"
		Image.FORMAT_RF: return "RF"
		Image.FORMAT_RGF: return "RGF"
		Image.FORMAT_RGBF: return "RGBF"
		Image.FORMAT_RGBAF: return "RGBAF"
		Image.FORMAT_DXT1: return "DXT1"
		Image.FORMAT_DXT3: return "DXT3"
		Image.FORMAT_DXT5: return "DXT5"
		_: return "FORMAT_%d" % format
