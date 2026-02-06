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

## Reference count for textures: hash_key -> count of impostors using it
var _texture_ref_counts: Dictionary = {}

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

## Track when impostors have been modified (need MultiMesh rebuild)
var _impostors_dirty: bool = false

## Rate-limiting for MultiMesh rebuilds to prevent frame stalls
## Rebuilding 70k+ instances every frame is catastrophic for performance
var _last_multimesh_rebuild_time: float = 0.0
var _last_impostor_add_time: float = 0.0  # When the last impostor was created (for debounce)
const MULTIMESH_REBUILD_INTERVAL: float = 0.5  # Minimum seconds between rebuilds
const MULTIMESH_REBUILD_DEBOUNCE: float = 0.2  # Wait this long after last impostor add before rebuilding

## Deferred impostor loading - process cells progressively to avoid freezing
var _pending_impostor_cells: Array[Vector2i] = []  # Cells waiting to be processed
var _impostor_cells_per_frame: int = 5  # Max cells to process per frame (tunable)
var _impostor_load_budget_ms: float = 4.0  # Time budget for impostor loading per frame

## Statistics
var _stats: Dictionary = {
	"total_impostors": 0,
	"texture_cache_size": 0,
	"texture_array_layers": 0,
	"pending_loads": 0,
	"skipped_no_texture": 0,  # Models that matched patterns but had no prebaked texture
	"skipped_not_candidate": 0,  # Models that didn't match impostor candidate patterns
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
	Log.info("impostors", "Initializing impostor renderer...")
	_setup_master_multimesh()
	_setup_billboard_material()
	_start_job_system()
	Log.info("impostors", "Initialization complete. Debug enabled: %s" % debug_enabled)


func _exit_tree() -> void:
	_stop_job_system()
	clear()


func _setup_master_multimesh() -> void:
	_master_multimesh = MultiMesh.new()
	_master_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_master_multimesh.use_custom_data = true

	# Create quad mesh for billboard
	# NOTE: We set the material on the mesh surface directly, not just material_override
	# This ensures the shader is definitely applied (material_override should work but didn't)
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	# Material will be set in _setup_billboard_material() after shader is created
	_master_multimesh.mesh = quad

	_master_instance = MultiMeshInstance3D.new()
	_master_instance.multimesh = _master_multimesh
	_master_instance.name = "ImpostorMasterBatch"

	# Configure native visibility_range for FAR tier
	# CRITICAL FIX: Use Godot's native visibility_range to hide impostors at close range
	# This is more reliable than shader-only discard because Godot culls BEFORE rendering
	# Begin at FAR_START (500m) minus margin for smooth transition
	_master_instance.visibility_range_begin = DU.FAR_START - DU.FADE_MARGIN  # 450m
	_master_instance.visibility_range_end = DU.FAR_END  # 5000m
	_master_instance.visibility_range_begin_margin = DU.FADE_MARGIN  # 50m hysteresis
	_master_instance.visibility_range_end_margin = DU.FADE_MARGIN
	_master_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

	add_child(_master_instance)


func _setup_billboard_material() -> void:
	var shader := Shader.new()
	shader.code = _get_octahedral_shader_code()

	# Check if shader compiled successfully
	# Note: Godot doesn't expose direct "is_valid" for shaders, but errors print to console
	Log.debug("impostors", "Shader code length: %d chars" % shader.code.length())

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
	_billboard_material.set_shader_parameter("debug_mode", false)  # Normal mode: impostors only visible 500m+

	# Set material on both the mesh surface AND as override (belt and suspenders)
	# This ensures the shader is applied even if material_override has issues
	var quad_mesh: QuadMesh = _master_multimesh.mesh as QuadMesh
	if quad_mesh:
		quad_mesh.surface_set_material(0, _billboard_material)
		Log.debug("impostors", "Set material on QuadMesh surface 0")

	_master_instance.material_override = _billboard_material
	Log.debug("impostors", "Set material_override on MultiMeshInstance3D")


## Toggle debug mode for impostor shader (shows bright magenta at any distance)
## CRITICAL: Also disables visibility_range_begin so impostors render at close range
func set_shader_debug_mode(enabled: bool) -> void:
	Log.debug("impostors", "set_shader_debug_mode called with: %s" % enabled)
	Log.debug("impostors", "_billboard_material is: %s" % (_billboard_material != null))
	Log.debug("impostors", "_master_instance is: %s" % (_master_instance != null))

	# Note: Currently using simplified debug shader that always shows magenta
	# The debug_mode uniform only exists in the full shader (commented out)
	if _billboard_material and _billboard_material.shader:
		# Check if shader has debug_mode uniform before setting
		var shader_code: String = _billboard_material.shader.code
		if "debug_mode" in shader_code:
			_billboard_material.set_shader_parameter("debug_mode", enabled)
			var actual_value = _billboard_material.get_shader_parameter("debug_mode")
			Log.debug("impostors", "debug_mode uniform set to: %s (verified: %s)" % [enabled, actual_value])
		else:
			Log.debug("impostors", "Using simplified shader (no debug_mode uniform) - always magenta")
	else:
		Log.error("impostors", "_billboard_material or shader is null!")

	# CRITICAL FIX: visibility_range culls the MultiMesh BEFORE shader runs
	# So we must also disable visibility_range_begin for debug mode to work at close range
	if _master_instance:
		if enabled:
			# Debug mode: show at any distance
			_master_instance.visibility_range_begin = 0.0
			_master_instance.visibility_range_begin_margin = 0.0
			Log.debug("impostors", "visibility_range_begin set to 0 (debug mode)")
		else:
			# Normal mode: restore FAR tier visibility (450m+)
			_master_instance.visibility_range_begin = DU.FAR_START - DU.FADE_MARGIN  # 450m
			_master_instance.visibility_range_begin_margin = DU.FADE_MARGIN  # 50m hysteresis
			Log.debug("impostors", "visibility_range_begin restored to 450m")

	Log.info("impostors", "Shader debug mode: %s" % ("ON - magenta squares at ANY distance" if enabled else "OFF - normal rendering (500m+)"))

#endregion


#region Octahedral Billboard Shader (Valuable Custom Code)

func _get_octahedral_shader_code() -> String:
	# Full octahedral impostor shader with texture sampling and debug mode
	# NOTE: Godot shaders do NOT support 'return' in fragment() - use if/else instead
	#
	# IMPORTANT: Per-impostor distance culling is done in the shader because:
	# - MultiMesh visibility_range is calculated from the MultiMeshInstance3D position (origin)
	# - NOT from each individual instance's position
	# - So we must discard fragments for impostors that are too close to the camera
	return """
shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled, unshaded;

uniform sampler2DArray texture_atlas : source_color, filter_linear_mipmap;
uniform int atlas_columns = 4;
uniform int atlas_rows = 4;
uniform float fade_distance = 500.0;
uniform float fade_margin = 50.0;
uniform bool debug_mode = false;

varying flat float texture_layer;
varying flat float rotation_offset;
varying float dist_to_camera;

void vertex() {
	// Get texture layer and rotation from instance custom data
	texture_layer = INSTANCE_CUSTOM.x;
	rotation_offset = INSTANCE_CUSTOM.y;

	// Calculate distance to camera for fading
	vec3 camera_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 impostor_center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	dist_to_camera = distance(camera_pos, impostor_center);

	// Y-axis billboard (face camera horizontally, keep vertical axis)
	vec3 to_camera = camera_pos - impostor_center;
	vec3 look_dir = normalize(vec3(to_camera.x, 0.0, to_camera.z));

	// Handle edge case when camera is directly above/below
	if (length(vec2(to_camera.x, to_camera.z)) < 0.001) {
		look_dir = vec3(0.0, 0.0, 1.0);
	}

	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), look_dir));
	vec3 up = vec3(0.0, 1.0, 0.0);

	// Build billboard matrix preserving scale
	float scale_x = length(MODEL_MATRIX[0].xyz);
	float scale_y = length(MODEL_MATRIX[1].xyz);

	mat4 billboard = mat4(
		vec4(right * scale_x, 0.0),
		vec4(up * scale_y, 0.0),
		vec4(look_dir, 0.0),
		MODEL_MATRIX[3]
	);

	MODELVIEW_MATRIX = VIEW_MATRIX * billboard;
}

void fragment() {
	// CRITICAL: Per-impostor distance culling
	// Discard impostors that are closer than FAR tier start (fade_distance)
	// This is necessary because MultiMesh visibility_range only checks distance
	// from the MultiMeshInstance3D node position (origin), not each instance
	if (!debug_mode && dist_to_camera < fade_distance - fade_margin) {
		discard;
	}

	// Calculate view angle for frame selection
	vec3 camera_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 impostor_center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 view_dir = normalize(camera_pos - impostor_center);

	float angle = atan(view_dir.x, view_dir.z) - rotation_offset;
	float normalized_angle = (angle + PI) / (2.0 * PI);
	int total_frames = atlas_columns * atlas_rows;
	int frame = int(normalized_angle * float(total_frames)) % total_frames;

	// Calculate UV within the atlas
	int col = frame % atlas_columns;
	int row = frame / atlas_columns;
	vec2 frame_size = vec2(1.0 / float(atlas_columns), 1.0 / float(atlas_rows));
	vec2 atlas_uv = vec2(float(col), float(row)) * frame_size + UV * frame_size;

	// Sample texture from array using the layer index
	vec4 tex = texture(texture_atlas, vec3(atlas_uv, texture_layer));

	// DEBUG MODE: Show bright magenta at any distance (for testing)
	// Normal mode: show actual texture
	if (debug_mode) {
		ALBEDO = vec3(1.0, 0.0, 1.0);
		ALPHA = 1.0;
	} else {
		// Alpha test - discard fully transparent pixels
		if (tex.a < 0.1) {
			discard;
		}
		ALBEDO = tex.rgb;
		ALPHA = tex.a;
	}
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

## Track when we last ran compaction (avoid running every frame)
var _last_compaction_time: float = 0.0
const COMPACTION_INTERVAL: float = 5.0  # Run compaction check every 5 seconds
const COMPACTION_THRESHOLD: float = 0.75  # Compact when 75% full

func _process(_delta: float) -> void:
	# Poll for completed texture loads
	_poll_job_results()

	# Process deferred impostor cell loading (progressive to avoid freezing)
	_process_pending_impostor_cells()

	# Periodic compaction to prevent texture array from filling up
	var current_time := Time.get_ticks_msec() / 1000.0
	if current_time - _last_compaction_time >= COMPACTION_INTERVAL:
		_last_compaction_time = current_time
		# Check if we're above the compaction threshold
		if _texture_array_size > MAX_TEXTURE_ARRAY_LAYERS * COMPACTION_THRESHOLD:
			var before := _texture_array_size
			_compact_texture_array()
			if _texture_array_size < before:
				if debug_enabled:
					_debug("Periodic compaction freed %d texture slots (%d -> %d)" % [
						before - _texture_array_size, before, _texture_array_size])

	# Rebuild texture array if needed (batched to avoid rebuilding every frame)
	if _texture_array_dirty:
		var time_since_add := current_time - _last_texture_add_time
		if time_since_add >= TEXTURE_ARRAY_REBUILD_DELAY:
			_rebuild_texture_array()
			# Schedule MultiMesh rebuild (rate-limited below)
			_impostors_dirty = true
			_texture_array_dirty = false

	# Rate-limited MultiMesh rebuild to prevent frame stalls
	# With 70k+ impostors, rebuilding every frame destroys FPS
	if _impostors_dirty:
		var time_since_last_rebuild := current_time - _last_multimesh_rebuild_time
		var time_since_last_add := current_time - _last_impostor_add_time

		# Only rebuild if:
		# 1. Enough time has passed since last rebuild (rate limit), AND
		# 2. Either we've waited long enough after last add (debounce), OR no pending cells
		var should_rebuild := time_since_last_rebuild >= MULTIMESH_REBUILD_INTERVAL
		var done_adding := time_since_last_add >= MULTIMESH_REBUILD_DEBOUNCE or _pending_impostor_cells.is_empty()

		if should_rebuild and done_adding:
			Log.info("impostors", "Rebuilding MultiMesh with %d impostors" % _impostors.size())
			_rebuild_multimesh()
			_last_multimesh_rebuild_time = current_time
			_impostors_dirty = false


## Process pending impostor cells progressively (time-budgeted)
func _process_pending_impostor_cells() -> void:
	if _pending_impostor_cells.is_empty():
		return

	var start_time := Time.get_ticks_msec()
	var cells_processed := 0

	while not _pending_impostor_cells.is_empty():
		# Check time budget
		var elapsed := Time.get_ticks_msec() - start_time
		if elapsed >= _impostor_load_budget_ms:
			break

		# Check per-frame cell limit
		if cells_processed >= _impostor_cells_per_frame:
			break

		var grid: Vector2i = _pending_impostor_cells.pop_front()
		_load_impostors_from_cell_record(grid)
		cells_processed += 1

	if cells_processed > 0 and debug_enabled:
		var elapsed := Time.get_ticks_msec() - start_time
		_debug("Processed %d impostor cells in %.1fms, %d remaining" % [
			cells_processed, elapsed, _pending_impostor_cells.size()])


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
	if debug_enabled:
		_debug("ImpostorCandidates initialized: %s" % (impostor_candidates != null))


## Add an impostor for a model at a specific world position
## Returns impostor_id or -1 if texture not yet loaded or doesn't exist
func add_impostor(
	model_path: String,
	cell_grid: Vector2i,
	world_position: Vector3,
	world_rotation: Vector3 = Vector3.ZERO,
	world_scale: Vector3 = Vector3.ONE
) -> int:
	# Check if this model should have an impostor
	if impostor_candidates and not impostor_candidates.should_have_impostor(model_path):
		_stats["skipped_not_candidate"] += 1
		return -1

	# CRITICAL FIX: Check if prebaked texture actually exists on disk
	# Many models match the impostor candidate patterns but don't have prebaked textures
	# Without this check, they would render as magenta fallback textures
	var texture_path := ImpostorCandidatesScript.get_impostor_texture_path(model_path)
	if not FileAccess.file_exists(texture_path):
		# No prebaked texture - skip this impostor silently
		# This is expected for many models that match patterns but weren't baked
		_stats["skipped_no_texture"] += 1
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

	# Create pending impostor data FIRST (before texture load which may be sync)
	var pending := PendingImpostor.new()
	pending.model_path = model_path
	pending.cell_grid = cell_grid
	pending.position = world_position
	pending.rotation = world_rotation
	pending.scale = world_scale
	pending.texture_size = impostor_size
	pending.aabb_center_y = aabb_center_y

	# Queue for async load (or sync if texture missing)
	var need_texture_load := false
	if hash_key not in _pending_impostors:
		_pending_impostors[hash_key] = []
		need_texture_load = true

	# Add to pending list BEFORE starting texture load
	(_pending_impostors[hash_key] as Array).append(pending)

	# Now start texture load if needed
	# Note: We already verified texture_path exists at the start of this function
	if need_texture_load:
		if debug_enabled:
			var normalized := ImpostorCandidatesScript.normalize_model_path(model_path)
			_debug("=== Impostor Texture Loading ===")
			_debug("  Model path (input): %s" % model_path)
			_debug("  Normalized path: %s" % normalized)
			_debug("  Hash key: %s" % hash_key)
			_debug("  Texture path: %s" % texture_path)

		# Try async loading first
		if _job_system != null:
			_submit_texture_load_job(hash_key, texture_path)
		else:
			# Fallback to synchronous loading if job system failed
			_load_texture_sync(hash_key, texture_path)

	return -1


## Remove an impostor by ID
func remove_impostor(impostor_id: int) -> void:
	if impostor_id in _impostors:
		var imp: ImpostorData = _impostors[impostor_id]
		# Decrement texture reference count
		var hash_key: String = imp.texture_hash
		if hash_key in _texture_ref_counts:
			_texture_ref_counts[hash_key] -= 1
			if _texture_ref_counts[hash_key] <= 0:
				_texture_ref_counts.erase(hash_key)
		_impostors.erase(impostor_id)
		_stats["total_impostors"] = _impostors.size()
		_impostors_dirty = true  # Mark for MultiMesh rebuild


## Clear all impostors
func clear() -> void:
	_impostors.clear()
	_texture_ref_counts.clear()
	_stats["total_impostors"] = 0
	_impostors_dirty = true  # Mark for MultiMesh rebuild

	if _master_multimesh:
		_master_multimesh.instance_count = 0


## Get statistics
func get_stats() -> Dictionary:
	var s := _stats.duplicate()
	# Add dynamic stats
	s["multimesh_instance_count"] = _master_multimesh.instance_count if _master_multimesh else 0
	s["loaded_impostor_cells"] = _loaded_impostor_cells.size()
	s["pending_texture_loads"] = _pending_job_ids.size()
	s["pending_impostors"] = _pending_impostors.size()
	s["process_enabled"] = is_processing()
	s["has_candidates"] = impostor_candidates != null
	return s


## Detailed diagnostic output - call this to debug rendering issues
func dump_diagnostic() -> String:
	var lines: Array[String] = []
	lines.append("=== NativeImpostorRenderer Diagnostic ===")

	# MultiMesh state
	lines.append("\n[MultiMesh State]")
	if _master_multimesh:
		lines.append("  instance_count: %d" % _master_multimesh.instance_count)
		lines.append("  visible_instance_count: %d" % _master_multimesh.visible_instance_count)
		lines.append("  mesh: %s" % (_master_multimesh.mesh != null))
		lines.append("  transform_format: %d" % _master_multimesh.transform_format)
		lines.append("  use_custom_data: %s" % _master_multimesh.use_custom_data)
	else:
		lines.append("  ERROR: _master_multimesh is null!")

	# MultiMeshInstance3D state
	lines.append("\n[MultiMeshInstance3D State]")
	if _master_instance:
		lines.append("  in_tree: %s" % _master_instance.is_inside_tree())
		lines.append("  visible: %s" % _master_instance.visible)
		lines.append("  global_position: %s" % _master_instance.global_position)
		lines.append("  visibility_range_begin: %.1f" % _master_instance.visibility_range_begin)
		lines.append("  visibility_range_end: %.1f" % _master_instance.visibility_range_end)
		lines.append("  material_override: %s" % (_master_instance.material_override != null))
		lines.append("  cast_shadow: %d" % _master_instance.cast_shadow)
		lines.append("  layers: %d" % _master_instance.layers)
	else:
		lines.append("  ERROR: _master_instance is null!")

	# Material/Shader state
	lines.append("\n[Material State]")
	if _billboard_material:
		lines.append("  shader: %s" % (_billboard_material.shader != null))
		if _billboard_material.shader:
			lines.append("  shader_code_length: %d chars" % _billboard_material.shader.code.length())
			# Show first 100 chars of shader code to verify it's our shader
			var code_preview: String = _billboard_material.shader.code.substr(0, 100).replace("\n", " ")
			lines.append("  shader_preview: '%s...'" % code_preview)
		lines.append("  debug_mode: %s" % _billboard_material.get_shader_parameter("debug_mode"))
		lines.append("  fade_distance: %s" % _billboard_material.get_shader_parameter("fade_distance"))
	else:
		lines.append("  ERROR: _billboard_material is null!")

	# Check mesh surface material
	lines.append("\n[Mesh Surface Material]")
	if _master_multimesh and _master_multimesh.mesh:
		var mesh: Mesh = _master_multimesh.mesh
		lines.append("  mesh_type: %s" % mesh.get_class())
		lines.append("  surface_count: %d" % mesh.get_surface_count())
		if mesh.get_surface_count() > 0:
			var surface_mat: Material = mesh.surface_get_material(0)
			lines.append("  surface_0_material: %s" % (surface_mat != null))
			if surface_mat:
				lines.append("  surface_0_material_class: %s" % surface_mat.get_class())
				if surface_mat is ShaderMaterial:
					var sm: ShaderMaterial = surface_mat as ShaderMaterial
					lines.append("  surface_0_has_shader: %s" % (sm.shader != null))
	else:
		lines.append("  ERROR: mesh is null!")

	# Texture array state
	lines.append("\n[Texture Array State]")
	lines.append("  _texture_array: %s" % (_texture_array != null))
	lines.append("  _texture_array_size: %d" % _texture_array_size)
	lines.append("  _all_array_images count: %d" % _all_array_images.size())
	lines.append("  _texture_index_map count: %d" % _texture_index_map.size())

	# Impostor data
	lines.append("\n[Impostor Data]")
	lines.append("  _impostors count: %d" % _impostors.size())

	# Sample first 3 impostor transforms
	if _impostors.size() > 0:
		lines.append("  First 3 impostors:")
		var count := 0
		for impostor_id: int in _impostors:
			if count >= 3:
				break
			var imp: ImpostorData = _impostors[impostor_id]
			lines.append("    [%d] pos=%s, scale=%s, tex_size=%s, tex_idx=%d" % [
				impostor_id, imp.position, imp.scale, imp.texture_size, imp.texture_index
			])
			count += 1

	var output := "\n".join(lines)
	Log.info("impostors", output)
	return output


## Update impostor area: load new cells, unload old ones
## Called by streaming manager
func update_impostor_area(center_cell: Vector2i, radius: int) -> void:
	if not impostor_candidates:
		push_warning("[NativeImpostorRenderer] update_impostor_area called but impostor_candidates is null!")
		return

	# 1. Calculate cells that SHOULD be loaded
	var desired_cells: Dictionary = {}
	# FIX: Convert cell radius to meters for comparison with cell_distance_squared
	# cell_distance_squared returns distance in METERS squared, so we need meters squared here
	var radius_meters := float(radius) * DU.CELL_SIZE_METERS
	var radius_sq := radius_meters * radius_meters

	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var grid := Vector2i(center_cell.x + dx, center_cell.y + dy)
			if DU.cell_distance_squared(center_cell, grid) <= radius_sq:
				desired_cells[grid] = true

	# Debug: Show how many cells are in range
	if debug_enabled:
		_debug("Impostor area: center=%s, radius=%d cells (%.0fm), desired_cells=%d" % [
			center_cell, radius, radius_meters, desired_cells.size()])

	# 2. Unload cells that are no longer in range
	var cells_to_unload: Array[Vector2i] = []
	for grid: Vector2i in _loaded_impostor_cells:
		if grid not in desired_cells:
			cells_to_unload.append(grid)
			
	if not cells_to_unload.is_empty():
		_unload_impostors_in_cells(cells_to_unload)
	
	# 3. Queue new cells for DEFERRED loading (prevents freezing)
	var cells_to_load: Array[Vector2i] = []
	for grid: Vector2i in desired_cells:
		if grid not in _loaded_impostor_cells and grid not in _pending_impostor_cells:
			cells_to_load.append(grid)
			_loaded_impostor_cells[grid] = true

	if not cells_to_load.is_empty():
		# Sort by distance from center (closest first)
		cells_to_load.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return DU.cell_distance_squared(center_cell, a) < DU.cell_distance_squared(center_cell, b)
		)

		# Queue for progressive loading instead of loading synchronously
		_pending_impostor_cells.append_array(cells_to_load)
		Log.info("impostors", "Queued %d impostor cells for deferred loading (total pending: %d)" % [
			cells_to_load.size(), _pending_impostor_cells.size()])


## Unload impostors belonging to specific cells
func _unload_impostors_in_cells(grids: Array[Vector2i]) -> void:
	var grid_set: Dictionary = {}
	for g in grids:
		grid_set[g] = true
		_loaded_impostor_cells.erase(g)

	# Remove active impostors and decrement texture reference counts
	var ids_to_remove: Array[int] = []
	for id: int in _impostors:
		var imp: ImpostorData = _impostors[id]
		if imp.cell_grid in grid_set:
			ids_to_remove.append(id)
			# Decrement texture reference count
			var hash_key: String = imp.texture_hash
			if hash_key in _texture_ref_counts:
				_texture_ref_counts[hash_key] -= 1
				if _texture_ref_counts[hash_key] <= 0:
					_texture_ref_counts.erase(hash_key)

	for id in ids_to_remove:
		_impostors.erase(id)

	if not ids_to_remove.is_empty():
		_impostors_dirty = true  # Mark for MultiMesh rebuild

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
		Log.error("impostors", "ESMManager not available!")
		return

	var cell_record = ESMManager.get_exterior_cell(grid.x, grid.y)
	if not cell_record:
		# Only log failures for cells within a reasonable range (not ocean/edge cells)
		if abs(grid.x) < 30 and abs(grid.y) < 30:
			_debug("No cell record for grid %s" % grid)
		return

	var ref_count := 0
	var impostor_count := 0
	var model_count := 0

	# Iterate over all references in the cell
	for ref in cell_record.references:
		ref_count += 1
		# Lookup the record to get the model path (CellReference doesn't have it directly)
		var record = ESMManager.get_any_record(str(ref.ref_id))
		if not record or not ("model" in record) or not record.model:
			continue

		var model_path: String = record.model
		if model_path.is_empty():
			continue

		model_count += 1

		# Check if it needs an impostor
		if impostor_candidates.should_have_impostor(model_path):
			impostor_count += 1
			# Convert coordinates using CS (CoordinateSystem)
			# CS assumes "ref" has position/rotation/scale.
			# Or we can use the raw values if we know them.
			# To be safe and consistent with ReferenceInstantiator:
			var pos := CS.vector_to_godot(ref.position)
			var scale_vec := CS.scale_to_godot(ref.scale)
			var basis := CS.esm_rotation_to_godot_basis(ref.rotation)
			var rot_euler := basis.get_euler() # We store Euler for simplicity

			add_impostor(model_path, grid, pos, rot_euler, scale_vec)

	if debug_enabled and (impostor_count > 0 or ref_count > 0):
		_debug("Cell %s: %d refs, %d models, %d impostor candidates" % [grid, ref_count, model_count, impostor_count])


func _debug(msg: String) -> void:
	if debug_enabled:
		Log.debug("impostors", msg)

#endregion


#region Internal Implementation

func _on_texture_loaded(hash_key: String, image: Image) -> void:
	# Check if there are any pending impostors waiting for this texture
	# If none (all cells were unloaded), skip adding to texture array
	if hash_key not in _pending_impostors or (_pending_impostors[hash_key] as Array).is_empty():
		if debug_enabled:
			_debug("Texture loaded but no pending impostors for hash %s, skipping" % hash_key)
		_pending_impostors.erase(hash_key)
		return

	# Create texture and cache
	var texture := ImageTexture.create_from_image(image)
	if not texture:
		push_error("[NativeImpostorRenderer] Failed to create ImageTexture for hash %s" % hash_key)
		_pending_impostors.erase(hash_key)
		return

	_impostor_textures[hash_key] = texture
	_stats["texture_cache_size"] = _impostor_textures.size()

	# Add to texture array - check for failure
	var texture_index := _add_to_texture_array(hash_key, image)
	if texture_index < 0:
		# Texture array full and compaction didn't help - skip these impostors
		if debug_enabled:
			_debug("Texture array full, skipping %d impostors for hash %s" % [
				(_pending_impostors[hash_key] as Array).size(), hash_key])
		_pending_impostors.erase(hash_key)
		# Also remove from texture cache since we won't use it
		_impostor_textures.erase(hash_key)
		_stats["texture_cache_size"] = _impostor_textures.size()
		return

	# Create all pending impostors waiting for this texture
	var pending_list: Array = _pending_impostors[hash_key]
	var created_count := pending_list.size()
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
	if debug_enabled:
		_debug("Texture loaded, created %d impostors for hash %s" % [created_count, hash_key])


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
	_impostors_dirty = true  # Mark for MultiMesh rebuild (rate-limited in _process)
	_last_impostor_add_time = Time.get_ticks_msec() / 1000.0  # For debounce

	# Increment texture reference count
	_texture_ref_counts[hash_key] = _texture_ref_counts.get(hash_key, 0) + 1

	impostor_created.emit(impostor.id, model_path)

	return impostor.id


func _add_to_texture_array(hash_key: String, image: Image) -> int:
	if hash_key in _texture_index_map:
		return _texture_index_map[hash_key]

	# If at capacity, try to compact by removing unused textures
	if _texture_array_size >= MAX_TEXTURE_ARRAY_LAYERS:
		_compact_texture_array()
		# Check again after compaction
		if _texture_array_size >= MAX_TEXTURE_ARRAY_LAYERS:
			# Log warning only once per overflow event (not every impostor)
			if not _stats.get("_logged_array_full", false):
				push_warning("[NativeImpostorRenderer] Texture array limit reached (%d layers). New impostors will be skipped until cells unload." % MAX_TEXTURE_ARRAY_LAYERS)
				_stats["_logged_array_full"] = true
			return -1  # Return -1 to indicate failure (not 0 which is a valid index)

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


## Compact the texture array by removing unreferenced textures
## This rebuilds the array with only textures that have active impostors using them
func _compact_texture_array() -> void:
	# Find which textures are still in use (have reference count > 0)
	var used_hashes: Array[String] = []
	for hash_key: String in _texture_index_map:
		if hash_key in _texture_ref_counts and _texture_ref_counts[hash_key] > 0:
			used_hashes.append(hash_key)

	var removed_count := _texture_index_map.size() - used_hashes.size()
	if removed_count == 0:
		return  # Nothing to compact

	if debug_enabled:
		_debug("Compacting texture array: removing %d unused textures" % removed_count)

	# Build new arrays with only used textures
	var new_images: Array[Image] = []
	var new_index_map: Dictionary = {}

	for i in used_hashes.size():
		var hash_key: String = used_hashes[i]
		var old_index: int = _texture_index_map[hash_key]
		new_images.append(_all_array_images[old_index])
		new_index_map[hash_key] = i

	# Update impostor texture indices to match new array positions
	for id: int in _impostors:
		var imp: ImpostorData = _impostors[id]
		if imp.texture_hash in new_index_map:
			imp.texture_index = new_index_map[imp.texture_hash]

	# Clear old cached textures that are no longer in the array
	for hash_key: String in _impostor_textures.keys():
		if hash_key not in new_index_map:
			_impostor_textures.erase(hash_key)

	# Replace arrays
	_all_array_images = new_images
	_texture_index_map = new_index_map
	_texture_array_size = new_images.size()
	_texture_array_dirty = true
	_impostors_dirty = true  # Need to rebuild MultiMesh with new indices

	_stats["texture_array_layers"] = _texture_array_size
	_stats["texture_cache_size"] = _impostor_textures.size()

	# Reset "array full" warning flag since we freed space
	if removed_count > 0:
		_stats["_logged_array_full"] = false


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
		push_error("[NativeImpostorRenderer] Failed to create texture array: %s" % error_string(err))
		_texture_array_dirty = false
		return

	Log.debug("impostors", "Rebuilt texture array with %d layers" % images.size())
	_billboard_material.set_shader_parameter("texture_atlas", _texture_array)
	Log.debug("impostors", "Set texture_atlas on material")
	_texture_array_dirty = false


func _rebuild_multimesh() -> void:
	var impostor_count := _impostors.size()

	if impostor_count == 0:
		_master_multimesh.instance_count = 0
		if debug_enabled:
			_debug("_rebuild_multimesh: No impostors to render")
		return

	_master_multimesh.instance_count = impostor_count

	var idx := 0
	for impostor_id: int in _impostors:
		var impostor: ImpostorData = _impostors[impostor_id]

		# Position billboard at model center (adjusted for AABB center)
		var billboard_pos := impostor.position
		billboard_pos.y += impostor.aabb_center_y * impostor.scale.y

		# Create transform with scale based on texture size
		var scale_x := impostor.texture_size.x * impostor.scale.x
		var scale_y := impostor.texture_size.y * impostor.scale.y

		var transform := Transform3D()
		transform = transform.scaled(Vector3(scale_x, scale_y, 1.0))
		transform.origin = billboard_pos

		_master_multimesh.set_instance_transform(idx, transform)

		# Custom data: x = texture layer, y = rotation.y (radians)
		_master_multimesh.set_instance_custom_data(idx, Color(float(impostor.texture_index), impostor.rotation.y, 0.0, 1.0))

		idx += 1

	# Only log rebuild at debug level (was spamming the console)
	if debug_enabled:
		_debug("MultiMesh rebuilt: %d instances, visible=%d" % [
			impostor_count, _master_multimesh.visible_instance_count
		])


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
