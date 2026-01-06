## ImpostorManager - High-performance distant impostor rendering
##
## Renders distant landmarks as octahedral impostors (pre-rendered billboards).
## Optimized for minimal frame impact with async loading and spatial culling.
##
## **DUAL IMPOSTOR SYSTEM** (Performance Optimization):
##
## This manager handles TWO types of impostors with different visibility strategies:
##
## 1. **STANDALONE IMPOSTORS** (Cell-Level Visibility):
##    - Non-significant objects (common trees, rocks, clutter)
##    - Visibility controlled by FAR tier cells from DistanceTierManager
##    - Entire cells of impostors show/hide together
##    - No crossfade (instant pop-in at FAR tier boundary)
##    - Performance: Very cheap - cell-level culling, no per-object tracking
##
## 2. **LOD-MANAGED IMPOSTORS** (Object-Level Visibility):
##    - Significant objects (landmarks, unique buildings, quest items)
##    - Visibility controlled by ObjectStreamer's per-object LOD system
##    - Smooth dithered crossfade from MID tier (LOD3) to FAR tier (Impostor)
##    - Tracked individually via lod_object_id
##    - Performance: More expensive but provides AAA quality for important objects
##
## Why two systems?
## - Not every object needs a full LOD chain (NEAR→MID LOD1/2/3→FAR impostor)
## - Common vegetation/clutter uses standalone (cheap)
## - Landmarks/unique objects use LOD-managed (high quality)
## - This hybrid approach balances performance and visual quality
##
## Key features:
## - ASYNC texture loading (no main thread blocking)
## - Spatial cell-based visibility culling (O(visible cells) not O(all impostors))
## - Dirty region tracking (only rebuild changed batches)
## - Texture array batching (single draw call for all impostors)
## - 16-frame octahedral atlas with depth for parallax
## - LOD crossfade coordination with ObjectStreamer (significant objects only)
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
const BackgroundJobSystemScript := preload("res://src/core/threading/background_job_system.gd")

## Reference to ImpostorCandidates for checking impostor eligibility
var impostor_candidates: ImpostorCandidates = null

## Reference to ObjectStreamer for LOD-Impostor crossfade coordination
var object_streamer: RefCounted = null

## **UNIFIED VISIBILITY**: Reference to DistanceTierManager for visibility authority
var _distance_tier_manager: RefCounted = null

## Track impostors managed by LOD system (currently in LOD3-Impostor transition)
## object_id -> impostor_id mapping
var _lod_managed_impostors: Dictionary = {}

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

## **UNIFIED VISIBILITY**: Cached visible cells computed by update_visibility()
## Only recalculated when camera crosses cell boundary (optimization)
var _cached_visible_cells: Dictionary = {}  # Vector2i -> true

## **CACHE**: Last camera cell for visibility caching
## Only recalculate visible cells when camera crosses cell boundary
var _last_camera_cell: Vector2i = Vector2i(-99999, -99999)

## **CACHE**: Cached impostor cell keys to avoid allocation during iteration
var _impostors_by_cell_keys_cache: Array = []
var _impostors_by_cell_keys_dirty: bool = true

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

## Background job system for texture loading
var _job_system: RefCounted = null  # BackgroundJobSystem
var _pending_job_ids: Dictionary = {}  # hash_key -> job_id

## Texture array rebuild batching - wait for loading to stabilize before rebuilding
var _last_texture_add_time: float = 0.0
const TEXTURE_ARRAY_REBUILD_DELAY: float = 0.1  # Wait 100ms after last texture before rebuilding (was 300ms)

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
## CHANGED: Defaults to FALSE - visibility will be set by WorldStreamingManager._apply_streaming_mode()
## This prevents impostors from appearing before proper mode synchronization
var _globally_visible: bool = false

## Track missing textures count (for summary logging, not spam)
var _missing_texture_count: int = 0

## Dirty tracking for efficient rebuilds
var _dirty_cells: Dictionary = {}  # Vector2i -> true (cells needing rebuild)
var _full_rebuild_needed: bool = false
var _rebuild_timer: float = 0.0
const REBUILD_DELAY: float = 0.1  # Batch rebuilds over 100ms (was 50ms)

## Throttle rebuilds to prevent per-frame stutter
var _last_rebuild_time: float = 0.0
const MIN_REBUILD_INTERVAL: float = 0.1  # Max 10 rebuilds per second (was 0.25 = 4 per second)

## Distance thresholds from DistanceUtils (single source of truth)
var _min_distance_sq: float = DU.MID_END * DU.MID_END  # 500m squared
var _max_distance_sq: float = DU.FAR_END * DU.FAR_END  # 5000m squared


## Pending impostor data (waiting for texture)
class PendingImpostor:
	var model_path: String
	var position: Vector3
	var rotation: Vector3
	var scale: Vector3
	var cell_grid: Vector2i
	var texture_size: Vector2
	var aabb_center_y: float = 0.0  # AABB center Y offset from metadata
	var lod_object_id: int = -1  # For LOD-managed impostors, the object ID in ObjectStreamer


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
	var aabb_center_y: float = 0.0  # AABB center Y offset from metadata (for correct billboard placement)
	var fade_amount: float = 1.0  # For LOD crossfade (0.0=invisible, 1.0=fully visible)
	var lod_object_id: int = -1   # Linked LOD object ID (-1 if not LOD-managed)


func _enter_tree() -> void:
	_scenario = get_viewport().get_world_3d().scenario
	_setup_master_multimesh()
	_setup_billboard_material()
	_start_background_loading()
	# Visibility controlled by _globally_visible flag (defaults to true)
	# Will be shown once impostors are loaded and multimesh is rebuilt
	if _master_instance:
		_master_instance.visible = _globally_visible


func _exit_tree() -> void:
	_stop_background_loading()
	clear()


## Start background loading system
func _start_background_loading() -> void:
	_start_job_system()


## Stop background loading system
func _stop_background_loading() -> void:
	_stop_job_system()


#region Job System (New)

## Start the background job system for texture loading
func _start_job_system() -> void:
	if _job_system != null:
		return

	_job_system = BackgroundJobSystemScript.new()
	# Use 2 worker threads for texture I/O (more than that doesn't help disk-bound work)
	var err: Error = _job_system.start(2)
	if err != OK:
		push_error("ImpostorManager: Failed to start job system - texture loading will not work")
		_job_system = null
		return

	if debug_enabled:
		print("ImpostorManager: Job system started with 2 workers")


## Stop the job system
func _stop_job_system() -> void:
	if _job_system == null:
		return

	_job_system.stop()
	_job_system = null
	_pending_job_ids.clear()


## Submit a texture load job to the job system
func _submit_texture_load_job(hash_key: String, texture_path: String) -> void:
	if _job_system == null:
		return

	# Create a job that loads the image from disk
	# IMPORTANT: This callable runs on a worker thread - must be thread-safe!
	var load_callable := func() -> Dictionary:
		var image := Image.new()
		var err := image.load(texture_path)
		if err == OK:
			return {"hash_key": hash_key, "image": image, "success": true}
		else:
			return {"hash_key": hash_key, "image": null, "success": false, "error": err}

	var job_id: int = _job_system.submit(load_callable, "texture", 0)
	if job_id >= 0:
		_pending_job_ids[hash_key] = job_id


## Poll job system for completed texture loads
func _poll_job_system_results() -> void:
	if _job_system == null:
		return

	# Process up to 10 results per frame
	var results: Array = _job_system.poll_results(10)

	for result in results:
		if result.status != BackgroundJobSystemScript.JobStatus.COMPLETED:
			# Job failed or was cancelled
			var hash_key_to_remove := ""
			for hk: String in _pending_job_ids:
				if _pending_job_ids[hk] == result.job_id:
					hash_key_to_remove = hk
					break
			if not hash_key_to_remove.is_empty():
				_pending_job_ids.erase(hash_key_to_remove)
				_pending_impostors.erase(hash_key_to_remove)
			continue

		# Extract result data
		var data: Dictionary = result.result
		if data == null or not data.get("success", false):
			continue

		var hash_key: String = data.get("hash_key", "")
		var image: Image = data.get("image")

		if hash_key.is_empty() or image == null:
			continue

		# Remove from pending tracking
		_pending_job_ids.erase(hash_key)

		# Process the loaded texture
		_on_texture_loaded(hash_key, image)

#endregion


func _process(delta: float) -> void:
	# Poll for textures loaded by job system (non-blocking)
	_poll_job_system_results()

	# Rebuild texture array if dirty AND enough time has passed since last texture add
	# This batches multiple texture additions into a single rebuild
	if _texture_array_dirty:
		var time_since_last_add := Time.get_ticks_msec() / 1000.0 - _last_texture_add_time
		# Check if there are still textures being loaded
		var still_loading := not _pending_texture_loads.is_empty() or not _pending_impostors.is_empty()

		# Check job system for pending work
		if _job_system != null:
			still_loading = still_loading or _job_system.get_queue_size() > 0 or _job_system.get_active_count() > 0 or _job_system.get_pending_result_count() > 0

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

			# Additional throttle: don't rebuild more than MIN_REBUILD_INTERVAL apart
			var current_time := Time.get_ticks_msec() / 1000.0
			var time_since_last_rebuild := current_time - _last_rebuild_time

			if _rebuild_timer >= rebuild_delay and time_since_last_rebuild >= MIN_REBUILD_INTERVAL:
				_rebuild_multimesh()
				_rebuild_timer = 0.0
				_last_rebuild_time = current_time




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
## Extended with LOD crossfade support using screen-door dithering
func _get_optimized_shader_code() -> String:
	return """
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2DArray texture_atlas : source_color;
uniform int atlas_columns = 4;
uniform int atlas_rows = 4;

varying vec3 view_direction;
varying flat float texture_layer;
varying flat float fade_amount;

// 4x4 Bayer dither matrix for screen-door fade (matches lod_crossfade.gdshader)
const float BAYER_MATRIX[16] = float[16](
	0.0 / 16.0,  8.0 / 16.0,  2.0 / 16.0, 10.0 / 16.0,
	12.0 / 16.0, 4.0 / 16.0, 14.0 / 16.0,  6.0 / 16.0,
	3.0 / 16.0, 11.0 / 16.0,  1.0 / 16.0,  9.0 / 16.0,
	15.0 / 16.0, 7.0 / 16.0, 13.0 / 16.0,  5.0 / 16.0
);

float get_bayer_threshold(ivec2 screen_pos) {
	int x = screen_pos.x % 4;
	int y = screen_pos.y % 4;
	return BAYER_MATRIX[y * 4 + x];
}

void vertex() {
	// Get texture layer and fade amount from instance custom data
	// x = texture layer, y = fade amount (0.0-1.0)
	texture_layer = INSTANCE_CUSTOM.x;
	fade_amount = INSTANCE_CUSTOM.y;

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

	// Screen-door dithering for LOD crossfade
	// When fade_amount = 1.0, all pixels pass (fully visible)
	// When fade_amount = 0.0, no pixels pass (invisible)
	ivec2 screen_pos = ivec2(FRAGCOORD.xy);
	float dither_threshold = get_bayer_threshold(screen_pos);
	if (dither_threshold >= fade_amount) {
		discard;
	}

	ALBEDO = tex.rgb;
}
"""


## Set the impostor candidates reference
func set_impostor_candidates(candidates: ImpostorCandidates) -> void:
	impostor_candidates = candidates


## Set the ObjectStreamer for LOD-Impostor crossfade coordination
func set_object_streamer(manager: RefCounted) -> void:
	object_streamer = manager

## Legacy alias for compatibility
func set_object_distance_manager(manager: RefCounted) -> void:
	set_object_streamer(manager)

## **UNIFIED VISIBILITY**: Set the DistanceTierManager for visibility authority
func set_distance_tier_manager(manager: RefCounted) -> void:
	_distance_tier_manager = manager


#region LOD Crossfade Coordination (LOD-Managed Impostors Only)

## **DUAL IMPOSTOR SYSTEM - LOD-MANAGED PATH**
##
## These functions manage the coordination between ObjectStreamer and ImpostorManager
## for SIGNIFICANT objects that have a full LOD chain (NEAR → MID LOD1/2/3 → FAR impostor).
##
## Flow for LOD-managed impostors:
## 1. ObjectStreamer detects object entering FAR tier
## 2. ObjectStreamer calls ImpostorManager.add_impostor() - creates impostor
## 3. ObjectStreamer calls register_lod_managed_impostor() - marks as LOD-controlled
## 4. During MID→FAR transition, ObjectStreamer calls set_lod_impostor_fade()
## 5. Impostor fades in (0.0 → 1.0) while LOD3 fades out (1.0 → 0.0) via dithering
## 6. When fully in FAR tier, fade_amount = 1.0 (fully visible)
## 7. update_visibility() SKIPS these impostors (ObjectStreamer owns visibility)
##
## STANDALONE impostors (non-significant objects) bypass this system entirely.

## Register an impostor as managed by the LOD system
## Called by ObjectStreamer when starting MID-FAR transition
func register_lod_managed_impostor(lod_object_id: int, impostor_id: int) -> void:
	if impostor_id not in _impostors:
		return
	_lod_managed_impostors[lod_object_id] = impostor_id
	var impostor: ImpostorInstance = _impostors[impostor_id]
	impostor.lod_object_id = lod_object_id


## Unregister an impostor from LOD management
## Called when transition completes or object is unregistered
func unregister_lod_managed_impostor(lod_object_id: int) -> void:
	if lod_object_id not in _lod_managed_impostors:
		return
	var impostor_id: int = _lod_managed_impostors[lod_object_id]
	if impostor_id in _impostors:
		var impostor: ImpostorInstance = _impostors[impostor_id]
		impostor.lod_object_id = -1
		impostor.fade_amount = 1.0  # Reset to fully visible
	_lod_managed_impostors.erase(lod_object_id)


## Get impostor ID for a LOD-managed object
## Returns -1 if not found
func get_lod_impostor_id(lod_object_id: int) -> int:
	return _lod_managed_impostors.get(lod_object_id, -1)


## Set the fade amount for a LOD-managed impostor
## amount: 0.0 = invisible, 1.0 = fully visible
## Returns true if successfully updated
func set_lod_impostor_fade(lod_object_id: int, amount: float) -> bool:
	if lod_object_id not in _lod_managed_impostors:
		return false
	var impostor_id: int = _lod_managed_impostors[lod_object_id]
	if impostor_id not in _impostors:
		return false
	var impostor: ImpostorInstance = _impostors[impostor_id]
	impostor.fade_amount = clampf(amount, 0.0, 1.0)
	# Mark cell dirty to update multimesh
	_dirty_cells[impostor.cell_grid] = true
	return true


## Check if an impostor is LOD-managed
func is_lod_managed(impostor_id: int) -> bool:
	if impostor_id not in _impostors:
		return false
	var impostor: ImpostorInstance = _impostors[impostor_id]
	return impostor.lod_object_id >= 0


## Cancel a pending impostor for a LOD object (when object leaves FAR tier before texture loaded)
func cancel_pending_for_lod_object(lod_object_id: int) -> void:
	# Search through all pending lists and remove entries with matching lod_object_id
	for hash_key: String in _pending_impostors:
		var pending_list: Array = _pending_impostors[hash_key]
		var i := pending_list.size() - 1
		while i >= 0:
			var pending: PendingImpostor = pending_list[i]
			if pending.lod_object_id == lod_object_id:
				pending_list.remove_at(i)
			i -= 1
		# Clean up empty lists
		if pending_list.is_empty():
			_pending_impostors.erase(hash_key)

#endregion


## Add an impostor for a model at a specific world position
## Returns impostor_id or -1 if texture not yet loaded (will be added when ready)
## For LOD-managed impostors, pass lod_object_id >= 0 to auto-register when texture loads
func add_impostor(
	model_path: String,
	world_position: Vector3,
	world_rotation: Vector3,
	world_scale: Vector3,
	cell_grid: Vector2i = Vector2i.ZERO,
	lod_object_id: int = -1
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

	# Get impostor metadata for size and AABB center
	var metadata: Dictionary = _get_or_load_impostor_metadata(model_path)
	var impostor_size: Vector2 = Vector2(10.0, 10.0)
	var aabb_center_y: float = 0.0  # Y offset of AABB center from model origin
	if not metadata.is_empty():
		var bounds: Dictionary = metadata.get("bounds", {})
		if not bounds.is_empty():
			impostor_size.x = bounds.get("width", 10.0)
			impostor_size.y = bounds.get("height", 10.0)
			# Get AABB center Y - this tells us where the visual center is relative to model origin
			var center_arr: Variant = bounds.get("center", [])
			if center_arr is Array and (center_arr as Array).size() >= 2:
				aabb_center_y = (center_arr as Array)[1] as float
		else:
			impostor_size.x = metadata.get("width", 10.0)
			impostor_size.y = metadata.get("height", 10.0)

	# Check if texture is already loaded
	if hash_key in _impostor_textures:
		var impostor_id := _create_impostor_instance(model_path, hash_key, world_position, world_rotation, world_scale, cell_grid, impostor_size, aabb_center_y)
		# Auto-register as LOD-managed if object ID was provided
		if impostor_id >= 0 and lod_object_id >= 0:
			register_lod_managed_impostor(lod_object_id, impostor_id)
		return impostor_id

	# Check if texture is already pending (in dict or thread queue)
	if hash_key in _pending_texture_loads or hash_key in _pending_impostors:
		# Queue this impostor to be created when texture loads
		_queue_pending_impostor(hash_key, model_path, world_position, world_rotation, world_scale, cell_grid, impostor_size, aabb_center_y, lod_object_id)
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
	_queue_pending_impostor(hash_key, model_path, world_position, world_rotation, world_scale, cell_grid, impostor_size, aabb_center_y, lod_object_id)

	# Queue texture for background thread loading (non-blocking)
	_queue_texture_for_background_load(hash_key, texture_path)

	return -1


## Queue an impostor to be created when its texture loads
func _queue_pending_impostor(hash_key: String, model_path: String, pos: Vector3, rot: Vector3, scl: Vector3, cell: Vector2i, size: Vector2, center_y: float, lod_object_id: int = -1) -> void:
	if hash_key not in _pending_impostors:
		_pending_impostors[hash_key] = []

	var pending := PendingImpostor.new()
	pending.model_path = model_path
	pending.position = pos
	pending.rotation = rot
	pending.scale = scl
	pending.cell_grid = cell
	pending.texture_size = size
	pending.aabb_center_y = center_y
	pending.lod_object_id = lod_object_id

	(_pending_impostors[hash_key] as Array).append(pending)


## Queue pending texture loads to the background system
## Called when add_impostor discovers a texture needs loading
func _queue_texture_for_background_load(hash_key: String, texture_path: String) -> void:
	if _job_system != null:
		_submit_texture_load_job(hash_key, texture_path)
		_pending_texture_loads.erase(hash_key)
	else:
		# Fallback to synchronous load if job system not available
		var image := Image.new()
		if image.load(texture_path) == OK:
			_on_texture_loaded(hash_key, image)
		else:
			push_warning("[ImpostorManager] Synchronous load failed for %s (job system unavailable)" % texture_path.get_file())
			_pending_impostors.erase(hash_key)
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
	var created_lod_managed: bool = false
	if hash_key in _pending_impostors:
		var pending_list: Array = _pending_impostors[hash_key]
		pending_count = pending_list.size()
		for pending: PendingImpostor in pending_list:
			var impostor_id := _create_impostor_instance(
				pending.model_path,
				hash_key,
				pending.position,
				pending.rotation,
				pending.scale,
				pending.cell_grid,
				pending.texture_size,
				pending.aabb_center_y
			)
			# Auto-register LOD-managed impostors when texture finishes loading
			if impostor_id >= 0 and pending.lod_object_id >= 0:
				register_lod_managed_impostor(pending.lod_object_id, impostor_id)
				# LOD-managed impostors should be fully visible immediately
				# ObjectStreamer may have already set fade to 1.0, but ensure it
				var impostor: ImpostorInstance = _impostors[impostor_id]
				impostor.fade_amount = 1.0
				created_lod_managed = true
		_pending_impostors.erase(hash_key)

	# If we created LOD-managed impostors, force a faster rebuild
	# since they need to be visible immediately
	if created_lod_managed:
		_full_rebuild_needed = true


## Add texture to the texture array
func _add_to_texture_array(hash_key: String, image: Image) -> int:
	if hash_key in _texture_index_map:
		return _texture_index_map[hash_key]

	# Check texture array limit with warnings
	_check_texture_array_limits()

	if _texture_array_size >= MAX_TEXTURE_ARRAY_LAYERS:
		# Array is full - find an existing texture to reuse (LRU would be better but this is simpler)
		# For now, just cycle through existing indices
		push_error("ImpostorManager: Texture array limit reached (%d/%d). New impostor will reuse existing texture (quality degradation)." % [_texture_array_size, MAX_TEXTURE_ARRAY_LAYERS])
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
	impostor_size: Vector2,
	aabb_center_y: float = 0.0
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
	impostor.texture_size = impostor_size
	impostor.aabb_center_y = aabb_center_y
	# Visibility determined by global visibility state
	# Using _globally_visible instead of _cached_visible_cells to avoid race condition
	# where new impostors are created before update_visibility() populates the cache
	impostor.visible = _globally_visible

	_impostors[_next_id] = impostor
	_next_id += 1

	# Track by cell for spatial culling
	if cell_grid not in _impostors_by_cell:
		_impostors_by_cell[cell_grid] = []
		_impostors_by_cell_keys_dirty = true  # New cell added - refresh cache
		_stats["cells_with_impostors"] = _impostors_by_cell.size()
		# NOTE: Do NOT add to _cached_visible_cells here!
		# Visibility is determined by DistanceTierManager.FAR tier only.
		# New cells start invisible and become visible when update_visibility() runs.
	(_impostors_by_cell[cell_grid] as Array).append(impostor.id)

	# Update stats
	_stats["total_impostors"] = _impostors.size()
	_stats["visible_impostors"] = _impostors.size()  # Will be updated by visibility check

	# Mark cell as dirty for rebuild
	_dirty_cells[cell_grid] = true

	# Note: Visibility will be updated by WorldStreamingManager calling update_visibility()

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


## **UNIFIED VISIBILITY**: Update impostor visibility from DistanceTierManager
## Replaces manual distance calculations with queries to the visibility authority
## No parameters needed - queries FAR tier cells from DistanceTierManager
##
## **DUAL IMPOSTOR SYSTEM**: This only updates STANDALONE impostors (cell-level visibility).
## LOD-managed impostors are controlled by ObjectStreamer and are explicitly skipped here
## to avoid conflicts with the per-object LOD crossfade system.
##
## **GPU-DRIVEN MODE**: When _gpu_driven_mode is true, visibility is controlled by
## GPUVisibilityRenderer instead of this CPU path. Call is_gpu_driven() to check.
func update_visibility() -> int:
	var changes: int = 0

	# **GPU-DRIVEN MODE**: Skip CPU visibility if GPU is handling it
	# GPUVisibilityRenderer applies visibility directly via apply_gpu_visibility()
	if _gpu_driven_mode:
		return 0

	# **SAFETY CHECK**: Early exit if no impostors to update
	if _impostors_by_cell.is_empty():
		return 0

	# **SELF-COMPUTED FAR VISIBILITY**: Compute visible cells directly
	# Instead of relying on DTM's FAR cell list (which only tracks significant objects),
	# we iterate our own _impostors_by_cell and check distance.
	# This is more efficient: O(impostor_cells) instead of O(far_radius²)
	# and ensures all impostor cells are considered, not just DTM-tracked ones.

	# Get camera position from tier manager
	var camera_pos := Vector3.ZERO
	if _distance_tier_manager:
		camera_pos = _distance_tier_manager._camera_position
	if camera_pos == Vector3.ZERO:
		# Fallback: No camera position, keep current visibility
		return 0

	# **OPTIMIZATION**: Only recalculate visible cells when camera crosses cell boundary
	# This reduces iteration from O(1023 cells) every frame to only when camera moves 117m+
	var current_cell := Vector2i(
		int(floor(camera_pos.x / DU.CELL_SIZE_METERS)),
		int(floor(-camera_pos.z / DU.CELL_SIZE_METERS))  # Z is flipped
	)

	# If camera is in same cell, skip expensive recalculation
	if current_cell == _last_camera_cell and not _cached_visible_cells.is_empty():
		# No changes needed - visibility is cached
		return 0

	_last_camera_cell = current_cell

	# Calculate FAR tier distance thresholds (squared for efficiency)
	var far_start_sq := DU.MID_END * DU.MID_END  # 500m²
	var far_end_sq := DU.FAR_END * DU.FAR_END    # 5000m²

	# Refresh cached keys only when dirty (impostor added/removed)
	if _impostors_by_cell_keys_dirty:
		_impostors_by_cell_keys_cache = _impostors_by_cell.keys()
		_impostors_by_cell_keys_dirty = false

	# Build visible cells by checking each impostor cell's distance
	var far_cells: Array[Vector2i] = []
	for cell_grid: Vector2i in _impostors_by_cell_keys_cache:
		# Calculate cell center position
		var cell_center := Vector3(
			cell_grid.x * DU.CELL_SIZE_METERS + DU.HALF_CELL_SIZE,
			camera_pos.y,  # Use camera Y to avoid height affecting distance
			-cell_grid.y * DU.CELL_SIZE_METERS - DU.HALF_CELL_SIZE  # Z is flipped
		)
		var dist_sq := camera_pos.distance_squared_to(cell_center)

		# Check if in FAR tier range
		if dist_sq >= far_start_sq and dist_sq < far_end_sq:
			far_cells.append(cell_grid)

	# Limit FAR cells to prevent overload (optional, matches DTM behavior)
	const MAX_FAR_CELLS := 250
	if far_cells.size() > MAX_FAR_CELLS:
		# Sort by distance and take closest
		far_cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			var ca := Vector3(a.x * DU.CELL_SIZE_METERS, 0, -a.y * DU.CELL_SIZE_METERS)
			var cb := Vector3(b.x * DU.CELL_SIZE_METERS, 0, -b.y * DU.CELL_SIZE_METERS)
			return camera_pos.distance_squared_to(ca) < camera_pos.distance_squared_to(cb)
		)
		far_cells.resize(MAX_FAR_CELLS)

	# Convert to visibility dictionary for efficient lookups
	var new_visible_cells: Dictionary = {}
	for cell_grid in far_cells:
		new_visible_cells[cell_grid] = true

	# Detect changes and update STANDALONE impostors only
	for cell_grid: Vector2i in _impostors_by_cell:
		var was_visible: bool = cell_grid in _cached_visible_cells
		var is_visible: bool = cell_grid in new_visible_cells

		if was_visible != is_visible:
			# Update all STANDALONE impostors in this cell
			var cell_impostors: Variant = _impostors_by_cell.get(cell_grid)
			if cell_impostors == null:
				continue

			for impostor_id: int in cell_impostors:
				var impostor: Variant = _impostors.get(impostor_id)
				if impostor == null:
					continue

				# **DUAL SYSTEM**: Skip LOD-managed impostors
				# ObjectStreamer controls visibility and crossfade for significant objects
				# via set_lod_impostor_fade() during MID→FAR tier transitions
				if impostor.lod_object_id >= 0:
					continue

				# STANDALONE impostor: Use cell-level visibility (instant pop-in)
				impostor.visible = is_visible
				changes += 1

			# Mark cell as dirty
			_dirty_cells[cell_grid] = true

	_cached_visible_cells = new_visible_cells

	# Update stats
	var visible_count: int = 0
	for cell_grid: Vector2i in _cached_visible_cells:
		var cell_arr: Variant = _impostors_by_cell.get(cell_grid)
		if cell_arr != null:
			visible_count += (cell_arr as Array).size()
	_stats["visible_impostors"] = visible_count

	return changes


## Throttle debug logging to reduce spam
var _last_debug_log_time: float = 0.0
const DEBUG_LOG_INTERVAL: float = 2.0  # Only log every 2 seconds

## Rebuild the master MultiMesh with current impostor data
func _rebuild_multimesh() -> void:
	# Collect visible impostors
	var visible_impostors: Array[ImpostorInstance] = []

	for cell_grid: Vector2i in _cached_visible_cells:
		var cell_impostors: Variant = _impostors_by_cell.get(cell_grid)
		if cell_impostors == null:
			continue

		for impostor_id: int in cell_impostors:
			var impostor: Variant = _impostors.get(impostor_id)
			if impostor != null and impostor.visible:
				# LOD-managed impostors: Include but use their LOD-controlled fade amount
				# Standalone impostors: Always fully visible (fade_amount = 1.0)
				visible_impostors.append(impostor)

	# Resize MultiMesh
	var count := visible_impostors.size()

	if debug_enabled:
		var current_time := Time.get_ticks_msec() / 1000.0
		if current_time - _last_debug_log_time >= DEBUG_LOG_INTERVAL:
			_last_debug_log_time = current_time
			print("ImpostorManager: _rebuild_multimesh - total=%d, visible_cells=%d, visible_impostors=%d, texture_layers=%d" % [
				_impostors.size(), _cached_visible_cells.size(), count, _texture_array_size])

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

		# Position the billboard correctly:
		# - The billboard quad is centered at origin (extends -0.5 to +0.5 in local space)
		# - After scaling, it extends from -size_y/2 to +size_y/2 in local Y
		# - The impostor texture was rendered with the model centered at its AABB center
		# - Object world position is typically at the model's origin (base/feet)
		# - AABB center Y tells us how high the visual center is above the origin
		#
		# So we need: billboard center Y = object position Y + AABB center Y
		# The AABB center Y is already the offset from origin to visual center
		var center_y_offset: float = impostor.aabb_center_y * scale_factor
		xform.origin = impostor.position + Vector3(0, center_y_offset, 0)

		_master_multimesh.set_instance_transform(i, xform)

		# Set custom data: x = texture layer index, y = fade amount (for LOD crossfade)
		_master_multimesh.set_instance_custom_data(i, Color(float(impostor.texture_index), impostor.fade_amount, 0, 1))

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
			_cached_visible_cells[cell_grid] = true
		else:
			_cached_visible_cells.erase(cell_grid)

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
		# Mark all cells as dirty and force immediate rebuild
		for cell_grid: Vector2i in _impostors_by_cell:
			_dirty_cells[cell_grid] = true
			_cached_visible_cells[cell_grid] = true
	else:
		_stats["visible_impostors"] = 0
		_cached_visible_cells.clear()

	_full_rebuild_needed = true

	# Force immediate rebuild when visibility is enabled
	# This ensures impostors appear right away instead of waiting for next frame
	if is_visible and not _impostors_by_cell.is_empty():
		_rebuild_multimesh()


## Clear all impostors
func clear() -> void:
	_impostors.clear()
	_impostors_by_cell.clear()
	_impostors_by_cell_keys_cache.clear()
	_impostors_by_cell_keys_dirty = true
	_last_camera_cell = Vector2i(-99999, -99999)
	_cached_visible_cells.clear()
	_dirty_cells.clear()
	_pending_impostors.clear()
	_pending_texture_loads.clear()
	_impostor_textures.clear()
	_impostor_metadata.clear()
	_texture_index_map.clear()
	_all_array_images.clear()
	_texture_array_size = 0
	_texture_array = null

	# Cancel pending jobs
	if _job_system != null:
		_job_system.cancel_by_tag("texture")
		_pending_job_ids.clear()

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
	var stats := _stats.duplicate()

	# Add job system stats
	if _job_system != null:
		var job_stats: Dictionary = _job_system.get_stats()
		stats["job_queue_size"] = job_stats.get("queue_size", 0)
		stats["job_active_count"] = job_stats.get("active_jobs", 0)
		stats["job_total_completed"] = job_stats.get("jobs_completed", 0)

	return stats


## Check if a cell has impostors
func has_impostors_for_cell(cell_grid: Vector2i) -> bool:
	return cell_grid in _impostors_by_cell and not (_impostors_by_cell[cell_grid] as Array).is_empty()


## Get count of impostors in a cell
func get_cell_impostor_count(cell_grid: Vector2i) -> int:
	if cell_grid not in _impostors_by_cell:
		return 0
	return (_impostors_by_cell[cell_grid] as Array).size()


## Track warning threshold to avoid spam
var _texture_limit_warning_shown: bool = false

## Check texture array limits and warn if approaching capacity
func _check_texture_array_limits() -> void:
	const WARNING_THRESHOLD := 450  # 90% of 512

	if _texture_array_size >= WARNING_THRESHOLD and not _texture_limit_warning_shown:
		push_warning("ImpostorManager: Approaching texture array limit (%d/%d = %d%%). Consider reducing impostor usage or increasing MAX_TEXTURE_ARRAY_LAYERS." % [
			_texture_array_size,
			MAX_TEXTURE_ARRAY_LAYERS,
			int((_texture_array_size * 100.0) / MAX_TEXTURE_ARRAY_LAYERS)
		])
		_texture_limit_warning_shown = true


#region GPU Visibility Support (Phase 2)

## Whether GPU-driven visibility is enabled for this manager
var _gpu_driven_mode: bool = false

## Mapping of impostor_id -> global_index in GPUVisibilityRenderer
var _gpu_index_mapping: Dictionary = {}

## Get the master MultiMesh for GPU registration
func get_master_multimesh() -> MultiMesh:
	return _master_multimesh


## Get the master MultiMesh RID for RenderingServer operations
func get_multimesh_rid() -> RID:
	if _master_multimesh:
		return _master_multimesh.get_rid()
	return RID()


## Get the MultiMesh buffer RID for GPU compute access
## NOTE: Requires Godot 4.4+ with multimesh_get_buffer_rd_rid
func get_buffer_rid() -> RID:
	if not _master_multimesh:
		return RID()

	var rs := RenderingServer
	if rs.has_method("multimesh_get_buffer_rd_rid"):
		var mm_rid := _master_multimesh.get_rid()
		return rs.call("multimesh_get_buffer_rd_rid", mm_rid)

	return RID()


## Enable or disable GPU-driven mode
## When enabled, visibility updates come from GPUVisibilityRenderer
func set_gpu_driven_mode(enabled: bool) -> void:
	_gpu_driven_mode = enabled


## Check if GPU-driven mode is active
func is_gpu_driven() -> bool:
	return _gpu_driven_mode


## Register an impostor with GPU visibility system
## Returns the global index assigned, or -1 if failed
func register_with_gpu_visibility(impostor_id: int, global_index: int) -> bool:
	if impostor_id not in _impostors:
		return false

	_gpu_index_mapping[impostor_id] = global_index
	return true


## Unregister an impostor from GPU visibility system
func unregister_from_gpu_visibility(impostor_id: int) -> void:
	_gpu_index_mapping.erase(impostor_id)


## Get all impostors with their positions for GPU registration
## Returns: Array of {impostor_id, position, cell_grid}
func get_all_impostors_for_gpu() -> Array[Dictionary]:
	var result: Array[Dictionary] = []

	for impostor_id: int in _impostors:
		var impostor: ImpostorInstance = _impostors[impostor_id]
		result.append({
			"impostor_id": impostor_id,
			"position": impostor.position,
			"cell_grid": impostor.cell_grid,
			"texture_index": impostor.texture_index,
		})

	return result


## Apply GPU visibility results to impostors
## visibility_data: PackedFloat32Array with [visibility, fade, tier, flags] per global index
## This is the main entry point for GPU-driven visibility updates
func apply_gpu_visibility(visibility_data: PackedFloat32Array) -> void:
	if not _gpu_driven_mode:
		return

	var visible_count := 0
	var changes_needed := false

	for impostor_id: int in _impostors:
		if impostor_id not in _gpu_index_mapping:
			continue

		var impostor: ImpostorInstance = _impostors[impostor_id]
		var global_idx: int = _gpu_index_mapping[impostor_id]

		# Skip LOD-managed impostors - ObjectStreamer controls their visibility
		if impostor.lod_object_id >= 0:
			if impostor.visible:
				visible_count += 1
			continue

		# Read visibility from GPU compute output
		var vis_base := global_idx * 4
		if vis_base + 3 >= visibility_data.size():
			continue

		var visibility: float = visibility_data[vis_base]
		var fade: float = visibility_data[vis_base + 1]
		var tier: int = int(visibility_data[vis_base + 2])

		# FAR tier = impostors visible
		var should_be_visible := (tier == 2)  # TIER_FAR = 2
		var final_fade := visibility * fade if should_be_visible else 0.0

		# Update impostor state
		var was_visible := impostor.visible
		impostor.visible = should_be_visible
		impostor.fade_amount = final_fade

		if should_be_visible:
			visible_count += 1

		if was_visible != should_be_visible:
			_dirty_cells[impostor.cell_grid] = true
			changes_needed = true

	_stats["visible_impostors"] = visible_count

	# Trigger rebuild if visibility changed
	if changes_needed:
		_full_rebuild_needed = true


## Batch apply GPU visibility with per-impostor data
## gpu_results: Dictionary[impostor_id] -> {visibility, fade, tier}
func apply_gpu_visibility_batch(gpu_results: Dictionary) -> void:
	if not _gpu_driven_mode:
		return

	var visible_count := 0
	var changes_needed := false

	for impostor_id: int in gpu_results:
		if impostor_id not in _impostors:
			continue

		var impostor: ImpostorInstance = _impostors[impostor_id]

		# Skip LOD-managed impostors
		if impostor.lod_object_id >= 0:
			if impostor.visible:
				visible_count += 1
			continue

		var result: Dictionary = gpu_results[impostor_id]
		var visibility: float = result.get("visibility", 0.0)
		var fade: float = result.get("fade", 1.0)
		var tier: int = result.get("tier", 3)  # Default to HIDDEN

		var should_be_visible := (tier == 2)  # TIER_FAR = 2
		var final_fade := visibility * fade if should_be_visible else 0.0

		var was_visible := impostor.visible
		impostor.visible = should_be_visible
		impostor.fade_amount = final_fade

		if should_be_visible:
			visible_count += 1

		if was_visible != should_be_visible:
			_dirty_cells[impostor.cell_grid] = true
			changes_needed = true

	_stats["visible_impostors"] = visible_count

	if changes_needed:
		_full_rebuild_needed = true


## Sync the MultiMesh buffer after GPU modifications
## Required due to Godot limitation: GPU writes don't render until set_buffer() is called
func sync_gpu_buffer() -> bool:
	if not _master_multimesh:
		return false

	var rs := RenderingServer
	var mm_rid := _master_multimesh.get_rid()

	# Read and re-set the buffer to force GPU sync
	var buffer := rs.multimesh_get_buffer(mm_rid)
	rs.multimesh_set_buffer(mm_rid, buffer)

	return true

#endregion
