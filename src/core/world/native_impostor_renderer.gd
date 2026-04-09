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
## Lines of code: ~1,200 (vs ~1,529 in old ImpostorManager)
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

## Texture array for batched rendering (albedo)
var _texture_array: Texture2DArray = null
var _texture_index_map: Dictionary[String, int] = {}  # texture_hash -> array_index
var _texture_array_dirty: bool = false
var _all_array_images: Array[Image] = []
var _texture_array_size: int = 0
var _last_texture_add_time: float = 0.0

## Normal texture array (parallel to albedo array, same layer indices)
var _normal_texture_array: Texture2DArray = null
var _normal_index_map: Dictionary[String, int] = {}  # texture_hash -> normal array_index
var _all_normal_images: Array[Image] = []
var _normal_array_size: int = 0
var _normal_array_dirty: bool = false

## Reference count for textures: hash_key -> count of impostors using it
var _texture_ref_counts: Dictionary[String, int] = {}

## Reverse index: texture_hash -> Array[int] of impostor IDs using that hash
## Enables O(k) lookup instead of O(total_impostors) when a normal texture loads
var _hash_to_impostor_ids: Dictionary[String, Array] = {}  # Array[int]

## Loaded impostor textures: hash_key -> Texture2D
var _impostor_textures: Dictionary[String, Texture2D] = {}

## Loaded normal textures: hash_key -> Image (stored as Image, added to array)
var _impostor_normal_images: Dictionary[String, Image] = {}

## Background job system for async texture loading
var _job_system: RefCounted = null
var _pending_job_ids: Dictionary[String, int] = {} # hash_key -> job_id

## Pending impostors waiting for texture
var _pending_impostors: Dictionary[String, Array] = {}  # hash_key -> Array[PendingImpostor]

## Default fallback texture for missing impostors (created on demand)
var _fallback_texture: ImageTexture = null

## Active impostors: impostor_id -> ImpostorData
var _impostors: Dictionary[int, ImpostorData] = {}
var _next_id: int = 0

## Spatial index: cell_grid -> Array[int] of impostor IDs
## Enables O(cell_count) lookups instead of O(total_impostors) for unloading
var _cell_index: Dictionary[Vector2i, Array] = {}  # Array[int]

## Cached impostor metadata
var _impostor_metadata: Dictionary[String, Dictionary] = {}

## Cached file existence checks to avoid repeated disk I/O
var _file_exists_cache: Dictionary[String, bool] = {}

## Cached ref_id -> model_path mapping to avoid repeated ESMManager.get_any_record() calls
## Same ref_ids appear across thousands of cells — cache eliminates redundant C# bridge calls
var _ref_id_to_model: Dictionary[String, String] = {}  # ref_id -> model_path ("" = no model)


## Track loaded impostor cells to avoid duplicates
var _loaded_impostor_cells: Dictionary[Vector2i, bool] = {} # Vector2i -> true

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
var _pending_cell_index: int = 0  # Current front of the queue
var _impostor_load_budget_usec: float = 4000.0  # Time budget in microseconds (4ms)

## Intra-cell resume state — when a dense cell exceeds the budget mid-reference,
## we save progress and resume next frame instead of blowing through the budget
var _has_resume: bool = false
var _resume_cell_grid: Vector2i = Vector2i.ZERO
var _resume_ref_index: int = 0

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

## Benchmark timer for periodic stats logging
var _benchmark_timer: float = 0.0
const BENCHMARK_LOG_INTERVAL: float = 5.0

## Last known camera center cell (for screen-size estimation)
var _last_center_cell: Vector2i = Vector2i.ZERO
var _screen_size_histogram_logged: bool = false

## Previous center for differential impostor updates
var _prev_impostor_center: Vector2i = Vector2i(999999, 999999)

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
	var variant_flag: float = 0.0  # See ImpostorData.variant_flag


class ImpostorData:
	var id: int
	var cell_grid: Vector2i # Cell this belongs to
	var model_path: String
	var texture_hash: String
	var texture_index: int
	var normal_texture_index: int = -1  # -1 = no normals (legacy v3 bake)
	var position: Vector3
	var rotation: Vector3
	var scale: Vector3
	var texture_size: Vector2
	var aabb_center_y: float = 0.0
	## Bake variant flag, packed into INSTANCE_CUSTOM.w for the shader.
	## Lets the shader pick between Variant A (legacy 16-frame azimuthal) and
	## Variant B (octahedral nearest-neighbor) at sample time.
	##   0.0 = v4 azimuthal (legacy)
	##   1.0 = v5 hemi octahedral
	##   2.0 = v5 sphere octahedral
	var variant_flag: float = 0.0

#endregion


#region Initialization

func _ready() -> void:
	Log.info("impostors", "Initializing impostor renderer...")
	_setup_master_multimesh()
	_setup_billboard_material()
	_start_job_system()
	Log.info("impostors", "Initialization complete. Debug enabled: %s" % debug_enabled)


func _exit_tree() -> void:
	if Engine.has_meta("_quitting"):
		return
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
	_master_instance.visibility_range_begin = DU.FAR_START - DU.FADE_MARGIN_LOD3_FAR  # 480m
	_master_instance.visibility_range_end = DU.FAR_END  # 5000m
	_master_instance.visibility_range_begin_margin = DU.FADE_MARGIN_LOD3_FAR  # 20m hysteresis
	_master_instance.visibility_range_end_margin = DU.FADE_MARGIN_LOD3_FAR
	_master_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

	# Receive shadows YES, cast shadows NO (per audit fix #6 / reviewer addendum D).
	# Casting shadows from a flat camera-facing quad would produce rectangular
	# billboard shadows on the terrain at 500m+ — worse than the original "flat
	# lighting" problem. The shader render_mode no longer has `shadows_disabled`,
	# so receive is on; this property turns off cast.
	_master_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

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

	# Create initial empty texture arrays (albedo + normal)
	var default_img := Image.create(512, 512, false, Image.FORMAT_RGBA8)
	default_img.fill(Color(0, 0, 0, 0))
	var default_array := Texture2DArray.new()
	default_array.create_from_images([default_img])
	_billboard_material.set_shader_parameter("texture_atlas", default_array)

	# Normal atlas: default to up-facing normal (0.5, 1.0, 0.5), zero depth
	var default_normal_img := Image.create(512, 512, false, Image.FORMAT_RGBA8)
	default_normal_img.fill(Color(0.5, 1.0, 0.5, 0.0))
	var default_normal_array := Texture2DArray.new()
	default_normal_array.create_from_images([default_normal_img])
	_billboard_material.set_shader_parameter("normal_atlas", default_normal_array)

	_billboard_material.set_shader_parameter("fade_distance", DU.MID_END) # 500m
	_billboard_material.set_shader_parameter("fade_margin", DU.FADE_MARGIN_LOD3_FAR) # 20m
	_billboard_material.set_shader_parameter("debug_mode", false)

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
			_master_instance.visibility_range_begin = DU.FAR_START - DU.FADE_MARGIN_LOD3_FAR  # 480m
			_master_instance.visibility_range_begin_margin = DU.FADE_MARGIN_LOD3_FAR  # 20m hysteresis
			Log.debug("impostors", "visibility_range_begin restored to 450m")

	Log.info("impostors", "Shader debug mode: %s" % ("ON - magenta squares at ANY distance" if enabled else "OFF - normal rendering (500m+)"))

#endregion


#region Octahedral Billboard Shader (Lit with Normal Maps)

func _get_octahedral_shader_code() -> String:
	# Lit billboard impostor shader. Two variants live in the same shader,
	# selected per-instance via INSTANCE_CUSTOM.w (the variant flag):
	#   0.0 = Variant A — legacy v4 azimuthal 16-frame (4×4 atlas, Y-only)
	#   1.0 = Variant B — v5 hemi octahedral nearest-neighbor (8×8 atlas)
	#   2.0 = Variant B — v5 sphere octahedral nearest-neighbor (8×8 atlas)
	#
	# INSTANCE_CUSTOM layout:
	#   .x = albedo texture array layer index
	#   .y = rotation offset (instance yaw, radians)
	#   .z = normal texture array layer index (-1 = no normals)
	#   .w = variant flag (0/1/2 — see above)
	#
	# Variant B fixes the audit bugs that wrecked Variant A:
	# - True octahedral direction sampling (not Y-only) so above/below views
	#   render the correct silhouette.
	# - Yaw-rotated decoded normals: the baked normal is in bake-time local
	#   space (instance was at rotation 0). At runtime we rotate it FORWARD
	#   by the instance yaw to get the actual world-space normal. The view
	#   direction used for frame selection is correspondingly rotated
	#   BACKWARD by yaw to express it in local space.
	# - Shadow receive enabled (no `shadows_disabled` in render_mode).
	# - Renormalize after sample.
	#
	# Variant B intentionally does NOT do tri-sample blending or parallax —
	# both were dropped per the simplification pass. They can be added later
	# if the validation scene shows visible cell popping or missing depth.
	#
	# Per-impostor distance culling stays in fragment because MultiMesh
	# visibility_range checks node position not per-instance position.
	return """
shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled;

uniform sampler2DArray texture_atlas : source_color, filter_linear_mipmap;
uniform sampler2DArray normal_atlas : filter_linear_mipmap;
uniform int atlas_columns = 4;  // Variant A only — 4×4
uniform int atlas_rows = 4;     // Variant A only — 4×4
uniform float fade_distance = 500.0;
uniform float fade_margin = 50.0;
uniform bool debug_mode = false;
uniform float impostor_roughness : hint_range(0.0, 1.0) = 0.85;
uniform float impostor_specular : hint_range(0.0, 1.0) = 0.3;

// Variant B grid size — must match impostor_baker_v3.GRID_SIZE
const int V5_GRID_SIZE = 8;

varying flat float texture_layer;
varying flat float normal_layer;
varying flat float rotation_offset;
varying flat float variant_flag;
varying float dist_to_camera;

// === Octahedral encoding (must match GDScript baker) ===

vec2 oct_encode_sphere(vec3 n) {
	n = normalize(n);
	float sum = abs(n.x) + abs(n.y) + abs(n.z);
	vec2 p = n.xz / sum;
	if (n.y < 0.0) {
		vec2 old = p;
		p.x = (1.0 - abs(old.y)) * sign(old.x);
		p.y = (1.0 - abs(old.x)) * sign(old.y);
	}
	return p;
}

vec2 oct_encode_hemi(vec3 n) {
	n = normalize(n);
	// Project to octahedron, then rotate 45° to fill the unit square.
	float sum = abs(n.x) + abs(n.y) + abs(n.z);
	vec2 p = n.xz / sum;
	return vec2(p.x - p.y, p.x + p.y);
}

// === Yaw rotation around Y axis ===

vec3 rotate_y(vec3 v, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	return vec3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z);
}

void vertex() {
	texture_layer = INSTANCE_CUSTOM.x;
	rotation_offset = INSTANCE_CUSTOM.y;
	normal_layer = INSTANCE_CUSTOM.z;
	variant_flag = INSTANCE_CUSTOM.w;

	vec3 camera_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 impostor_center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	dist_to_camera = distance(camera_pos, impostor_center);

	// Y-axis billboard (face camera horizontally, keep vertical axis)
	vec3 to_camera = camera_pos - impostor_center;
	vec3 look_dir = normalize(vec3(to_camera.x, 0.0, to_camera.z));
	if (length(vec2(to_camera.x, to_camera.z)) < 0.001) {
		look_dir = vec3(0.0, 0.0, 1.0);
	}
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), look_dir));
	vec3 up = vec3(0.0, 1.0, 0.0);

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
	// Per-impostor distance culling (visibility_range hits node, not instance)
	if (!debug_mode && dist_to_camera < fade_distance - fade_margin) {
		discard;
	}

	vec3 camera_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 impostor_center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 view_dir_world = normalize(camera_pos - impostor_center);
	bool has_normals = normal_layer >= 0.0;

	vec2 atlas_uv;
	bool is_v5 = variant_flag > 0.5;

	if (is_v5) {
		// === Variant B — v5 octahedral nearest-neighbor ===
		// Express the world-space view direction in instance local space by
		// rotating BACKWARD by the instance yaw. This is the frame the baker
		// used (instance at rotation 0), so the octahedral lookup matches.
		vec3 view_dir_local = rotate_y(view_dir_world, -rotation_offset);

		vec2 oct_uv;
		if (variant_flag > 1.5) {
			oct_uv = oct_encode_sphere(view_dir_local);  // sphere
		} else {
			oct_uv = oct_encode_hemi(view_dir_local);    // hemi
		}

		// Map [-1, 1]² → cell coords [0, GRID_SIZE)
		vec2 cell_coord = (oct_uv * 0.5 + 0.5) * float(V5_GRID_SIZE);
		ivec2 cell = ivec2(floor(cell_coord));
		cell = clamp(cell, ivec2(0), ivec2(V5_GRID_SIZE - 1));

		float inv_grid = 1.0 / float(V5_GRID_SIZE);
		atlas_uv = (vec2(cell) + UV) * inv_grid;
	} else {
		// === Variant A — legacy v4 azimuthal 16-frame ===
		float angle = atan(view_dir_world.x, view_dir_world.z) - rotation_offset;
		float normalized_angle = (angle + PI) / (2.0 * PI);
		int total_frames = atlas_columns * atlas_rows;
		int frame = int(normalized_angle * float(total_frames)) % total_frames;

		int col = frame % atlas_columns;
		int row = frame / atlas_columns;
		vec2 frame_size_uv = vec2(1.0 / float(atlas_columns), 1.0 / float(atlas_rows));
		atlas_uv = vec2(float(col), float(row)) * frame_size_uv + UV * frame_size_uv;
	}

	// Sample albedo
	vec4 tex = texture(texture_atlas, vec3(atlas_uv, texture_layer));

	if (debug_mode) {
		ALBEDO = vec3(1.0, 0.0, 1.0);
		ALPHA = 1.0;
	} else {
		// Alpha test
		if (tex.a < 0.1) {
			discard;
		}

		ALBEDO = tex.rgb;
		ALPHA = tex.a;

		if (has_normals) {
			vec4 normal_data = texture(normal_atlas, vec3(atlas_uv, normal_layer));
			vec3 baked_normal = normalize(normal_data.rgb * 2.0 - 1.0);

			vec3 world_normal;
			if (is_v5) {
				// v5 baked normals are in instance local space (bake camera was
				// world-aligned with the model at rotation 0). Rotate FORWARD
				// by instance yaw to get the actual runtime world normal.
				world_normal = rotate_y(baked_normal, rotation_offset);
			} else {
				// v4 baked normals were stored as bake-time world-space; the
				// renderer's instances were always at rotation 0 in v4 (the
				// runtime never rotated them) so no yaw correction needed
				// here. Keeping the original behavior for v4 compat.
				world_normal = baked_normal;
			}

			NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
			ROUGHNESS = impostor_roughness;
			SPECULAR = impostor_specular;
		}
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


## Submit async job to load a normal texture.
## `is_res` selects between async PNG decode (Image.load) and Godot
## ResourceLoader (.res ImageTexture for v5 bakes). ResourceLoader IS
## thread-safe in Godot 4.6 for runtime resource files outside res://.
func _submit_normal_load_job(hash_key: String, normal_path: String, is_res: bool = false) -> void:
	if _job_system == null:
		return

	var normal_job_key := hash_key + "_normal"
	if normal_job_key in _pending_job_ids:
		return  # Already loading

	var load_callable := func() -> Dictionary:
		var image := _load_normal_image(normal_path, is_res)
		if image:
			return {"hash_key": hash_key, "image": image, "success": true, "is_normal": true}
		else:
			return {"hash_key": hash_key, "image": null, "success": false, "is_normal": true}

	var job_id: int = _job_system.submit(load_callable, "texture", 0)
	if job_id >= 0:
		_pending_job_ids[normal_job_key] = job_id


## Synchronous normal texture loading fallback.
func _load_normal_sync(hash_key: String, normal_path: String, is_res: bool = false) -> void:
	var image := _load_normal_image(normal_path, is_res)
	if image:
		_on_normal_loaded(hash_key, image)
	else:
		if debug_enabled:
			_debug("Failed to load normal texture: %s" % normal_path)


## Shared loader: PNG via Image.load, .res via ResourceLoader+get_image.
## Returns null on any failure.
func _load_normal_image(normal_path: String, is_res: bool) -> Image:
	if is_res:
		var res := ResourceLoader.load(normal_path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if not res or not (res is Texture2D):
			return null
		var tex: Texture2D = res as Texture2D
		var img := tex.get_image()
		return img if img else null
	else:
		var image := Image.new()
		var err := image.load(normal_path)
		return image if err == OK else null


## Called when a normal texture finishes loading
func _on_normal_loaded(hash_key: String, image: Image) -> void:
	# Resize to standard size
	var img_copy := image.duplicate() as Image
	if img_copy.get_size() != Vector2i(512, 512):
		img_copy.resize(512, 512, Image.INTERPOLATE_LANCZOS)

	_impostor_normal_images[hash_key] = img_copy

	# Add to normal texture array
	var normal_index := _add_to_normal_array(hash_key, img_copy)

	# Update existing impostors that use this hash — O(k) via reverse index
	if hash_key in _hash_to_impostor_ids:
		for id: int in _hash_to_impostor_ids[hash_key]:
			var imp: ImpostorData = _impostors.get(id)
			if imp:
				imp.normal_texture_index = normal_index
		_impostors_dirty = true

	if debug_enabled:
		_debug("Normal texture loaded for hash %s, index %d" % [hash_key, normal_index])


## Add image to normal texture array
func _add_to_normal_array(hash_key: String, image: Image) -> int:
	if hash_key in _normal_index_map:
		return _normal_index_map[hash_key]

	var index := _normal_array_size
	_normal_index_map[hash_key] = index
	_normal_array_size += 1
	_all_normal_images.append(image)
	_normal_array_dirty = true
	_last_texture_add_time = Time.get_ticks_msec() / 1000.0
	return index


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

func _process(delta: float) -> void:
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

	# Rebuild texture arrays if needed (batched to avoid rebuilding every frame)
	if _texture_array_dirty or _normal_array_dirty:
		var time_since_add := current_time - _last_texture_add_time
		if time_since_add >= TEXTURE_ARRAY_REBUILD_DELAY:
			_rebuild_texture_array()
			# Schedule MultiMesh rebuild (rate-limited below)
			_impostors_dirty = true

	# Rate-limited MultiMesh rebuild to prevent frame stalls
	# With 70k+ impostors, rebuilding every frame destroys FPS
	if _impostors_dirty:
		var time_since_last_rebuild := current_time - _last_multimesh_rebuild_time
		var time_since_last_add := current_time - _last_impostor_add_time

		# Only rebuild if:
		# 1. Enough time has passed since last rebuild (rate limit), AND
		# 2. Either we've waited long enough after last add (debounce), OR no pending cells, AND
		# 3. We have a meaningful number of impostors (skip tiny rebuilds during initial load)
		var should_rebuild := time_since_last_rebuild >= MULTIMESH_REBUILD_INTERVAL
		var done_adding := time_since_last_add >= MULTIMESH_REBUILD_DEBOUNCE or _pending_cell_index >= _pending_impostor_cells.size()
		var has_enough := _impostors.size() >= 500 or _pending_cell_index >= _pending_impostor_cells.size()

		if should_rebuild and done_adding and has_enough:
			_rebuild_multimesh()
			_last_multimesh_rebuild_time = current_time
			_impostors_dirty = false

	# Periodic benchmark stats
	_benchmark_timer += delta
	if _benchmark_timer >= BENCHMARK_LOG_INTERVAL:
		_benchmark_timer = 0.0
		var pending_count: int = maxi(0, _pending_impostor_cells.size() - _pending_cell_index)
		Log.info("impostors", "Benchmark: %d impostors, %d tex layers, %d pending cells, mm_instances=%d" % [
			_impostors.size(), _texture_array_size, pending_count,
			_master_multimesh.instance_count if _master_multimesh else 0])


## Process pending impostor cells progressively (time-budgeted with intra-cell resume)
func _process_pending_impostor_cells() -> void:
	if _pending_cell_index >= _pending_impostor_cells.size() and not _has_resume:
		return

	var start_usec := Time.get_ticks_usec()
	var deadline_usec := start_usec + int(_impostor_load_budget_usec)
	var cells_processed := 0

	# Resume a partially-processed cell from last frame
	if _has_resume:
		var resume_idx := _load_impostors_from_cell_record_budgeted(_resume_cell_grid, _resume_ref_index, deadline_usec)
		if resume_idx < 0:
			# Cell complete
			_has_resume = false
			_resume_ref_index = 0
			cells_processed += 1
		else:
			# Still not done — save resume state and bail
			_resume_ref_index = resume_idx
			var elapsed_usec := Time.get_ticks_usec() - start_usec
			Log.debug("impostors", "Resumed cell %s (ref %d), %.2f ms, %d remaining" % [
				_resume_cell_grid, resume_idx, elapsed_usec / 1000.0,
				_pending_impostor_cells.size() - _pending_cell_index])
			return

	while _pending_cell_index < _pending_impostor_cells.size():
		# Check time budget between cells
		if Time.get_ticks_usec() >= deadline_usec:
			break

		var grid: Vector2i = _pending_impostor_cells[_pending_cell_index]
		_pending_cell_index += 1

		var resume_idx := _load_impostors_from_cell_record_budgeted(grid, 0, deadline_usec)
		if resume_idx < 0:
			# Cell complete
			cells_processed += 1
		else:
			# Cell exceeded budget mid-reference — save resume state
			_has_resume = true
			_resume_cell_grid = grid
			_resume_ref_index = resume_idx
			break

	# Periodic cleanup of the queue
	if _pending_cell_index >= _pending_impostor_cells.size() and not _has_resume:
		_pending_impostor_cells.clear()
		_pending_cell_index = 0
		# Queue finished — log screen-size histogram once
		_log_screen_size_histogram()
	elif _pending_cell_index > 100 and not _has_resume:
		_pending_impostor_cells = _pending_impostor_cells.slice(_pending_cell_index)
		_pending_cell_index = 0

	if cells_processed > 0:
		var elapsed_usec := Time.get_ticks_usec() - start_usec
		Log.debug("impostors", "Processed %d cells in %.2f ms, %d remaining" % [
			cells_processed, elapsed_usec / 1000.0,
			_pending_impostor_cells.size() - _pending_cell_index])


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

		# Route to correct handler based on whether this is a normal texture
		if data.get("is_normal", false):
			_pending_job_ids.erase(hash_key + "_normal")
			_on_normal_loaded(hash_key, image)
		else:
			_pending_job_ids.erase(hash_key)
			_on_texture_loaded(hash_key, image)

#endregion


#region Public API

## Set the impostor candidates reference
func set_impostor_candidates(candidates: ImpostorCandidatesScript) -> void:
	impostor_candidates = candidates
	if debug_enabled:
		_debug("ImpostorCandidates initialized: %s" % (impostor_candidates != null))


## Set the impostor loading budget (microseconds per frame)
## During startup, use a higher budget (e.g., 15000) since the player isn't playing yet
func set_load_budget_usec(budget: float) -> void:
	_impostor_load_budget_usec = budget


## Get the number of pending impostor cells (not yet processed)
func get_pending_cell_count() -> int:
	var remaining := _pending_impostor_cells.size() - _pending_cell_index
	if _has_resume:
		remaining += 1  # Count the partially-processed cell
	return maxi(0, remaining)


## Get the initial total of impostor cells queued (set once at first full recalc)
## Used for progress calculation
var _initial_pending_count: int = 0

func get_initial_pending_count() -> int:
	return _initial_pending_count


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

	# Resolve which bake version to use. v5 (octahedral) takes priority over
	# v4 (azimuthal) when both are present, so re-baking a single asset
	# automatically opts it into Variant B at runtime.
	var v5_albedo_path := ImpostorCandidatesScript.get_impostor_texture_path_v5(model_path)
	var has_v5 := _cached_file_exists(v5_albedo_path)

	var texture_path: String
	var normal_path: String
	var normal_is_res: bool
	if has_v5:
		texture_path = v5_albedo_path
		normal_path = ImpostorCandidatesScript.get_impostor_normal_res_path_v5(model_path)
		normal_is_res = true
	else:
		texture_path = ImpostorCandidatesScript.get_impostor_texture_path(model_path)
		if not _cached_file_exists(texture_path):
			_stats["skipped_no_texture"] += 1
			return -1
		normal_path = ImpostorCandidatesScript.get_impostor_normal_path(model_path)
		normal_is_res = false

	var has_normal_texture := _cached_file_exists(normal_path)

	var hash_key: String = ImpostorCandidatesScript.get_hash_key(model_path)

	# Get impostor metadata for size + variant flag
	var metadata := _get_or_load_metadata(model_path)
	var impostor_size := Vector2(10.0, 10.0)
	var aabb_center_y: float = 0.0
	var variant_flag: float = 0.0  # 0 = v4 azimuthal (default)

	if not metadata.is_empty():
		var bounds: Dictionary = metadata.get("bounds", {})
		if not bounds.is_empty():
			impostor_size.x = bounds.get("width", 10.0)
			impostor_size.y = bounds.get("height", 10.0)
			var center_arr: Variant = bounds.get("center", [])
			if center_arr is Array and (center_arr as Array).size() >= 2:
				aabb_center_y = (center_arr as Array)[1] as float

		# v5 bake variant resolution
		var bake_version: int = int(metadata.get("version", metadata.get("bake_version", 4)))
		if bake_version >= 5:
			var projection: String = str(metadata.get("projection", "hemi"))
			variant_flag = 2.0 if projection == "sphere" else 1.0

	# If texture already loaded, create impostor immediately
	if hash_key in _impostor_textures:
		var existing_id := _create_impostor(model_path, cell_grid, hash_key, world_position, world_rotation, world_scale, impostor_size, aabb_center_y)
		if existing_id >= 0 and existing_id in _impostors:
			(_impostors[existing_id] as ImpostorData).variant_flag = variant_flag
			_impostors_dirty = true
		return existing_id

	# Create pending impostor data FIRST (before texture load which may be sync)
	var pending := PendingImpostor.new()
	pending.model_path = model_path
	pending.cell_grid = cell_grid
	pending.position = world_position
	pending.rotation = world_rotation
	pending.scale = world_scale
	pending.texture_size = impostor_size
	pending.aabb_center_y = aabb_center_y
	pending.variant_flag = variant_flag

	# Queue for async load (or sync if texture missing)
	var need_texture_load := false
	if hash_key not in _pending_impostors:
		_pending_impostors[hash_key] = []
		need_texture_load = true

	# Add to pending list BEFORE starting texture load
	(_pending_impostors[hash_key] as Array).append(pending)

	# Now start texture load if needed
	if need_texture_load:
		if debug_enabled:
			var normalized := ImpostorCandidatesScript.normalize_model_path(model_path)
			_debug("=== Impostor Texture Loading (v%s) ===" % ("5" if has_v5 else "4"))
			_debug("  Model path (input): %s" % model_path)
			_debug("  Normalized path: %s" % normalized)
			_debug("  Hash key: %s" % hash_key)
			_debug("  Texture path: %s" % texture_path)
			_debug("  Normal path: %s (exists: %s, .res: %s)" % [normal_path, has_normal_texture, normal_is_res])

		# Try async loading first
		if _job_system != null:
			_submit_texture_load_job(hash_key, texture_path)
			if has_normal_texture:
				_submit_normal_load_job(hash_key, normal_path, normal_is_res)
		else:
			# Fallback to synchronous loading if job system failed
			_load_texture_sync(hash_key, texture_path)
			if has_normal_texture:
				_load_normal_sync(hash_key, normal_path, normal_is_res)

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
		# Maintain reverse index
		if hash_key in _hash_to_impostor_ids:
			var hash_ids: Array = _hash_to_impostor_ids[hash_key]
			var hidx := hash_ids.find(impostor_id)
			if hidx >= 0:
				hash_ids[hidx] = hash_ids.back()
				hash_ids.pop_back()
			if hash_ids.is_empty():
				_hash_to_impostor_ids.erase(hash_key)
		_impostors.erase(impostor_id)
		_stats["total_impostors"] = _impostors.size()
		_impostors_dirty = true  # Mark for MultiMesh rebuild


## Clear all impostors
func clear() -> void:
	_impostors.clear()
	_cell_index.clear()
	_texture_ref_counts.clear()
	_hash_to_impostor_ids.clear()
	_file_exists_cache.clear()
	_impostor_normal_images.clear()
	_ref_id_to_model.clear()
	_has_resume = false
	_resume_cell_grid = Vector2i.ZERO
	_resume_ref_index = 0
	_initial_pending_count = 0
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
## Uses differential update when moving 1-2 cells (only processes the ring delta),
## falls back to full recalc on teleport or first call.
## Called by streaming manager
func update_impostor_area(center_cell: Vector2i, radius: int) -> void:
	_last_center_cell = center_cell
	if not impostor_candidates:
		push_warning("[NativeImpostorRenderer] update_impostor_area called but impostor_candidates is null!")
		return

	var radius_meters := float(radius) * DU.CELL_SIZE_METERS
	var radius_sq := radius_meters * radius_meters

	# Differential update: if we moved only 1-2 cells, compute only the delta ring
	var delta := Vector2i(absi(center_cell.x - _prev_impostor_center.x), absi(center_cell.y - _prev_impostor_center.y))
	var use_differential := _prev_impostor_center != Vector2i(999999, 999999) and delta.x <= 2 and delta.y <= 2

	if use_differential and center_cell != _prev_impostor_center:
		# Border-strip approach: only scan strips on the leading/trailing edges
		# For a move of (dx, dy), new cells appear on the leading edge and old cells
		# disappear from the trailing edge. Each strip is at most 2R+1 cells long.
		var cells_to_unload: Array[Vector2i] = []
		var cells_to_load: Array[Vector2i] = []
		var move := center_cell - _prev_impostor_center  # (dx, dy) signed

		# Scan border strips where cells may have entered or exited
		# For X movement: scan columns at the leading and trailing X edges
		if move.x != 0:
			for step in range(1, absi(move.x) + 1):
				# Leading edge (new cells): column at center + R in direction of motion
				var lead_x: int = center_cell.x + radius * signi(move.x) - (step - 1) * signi(move.x)
				# Trailing edge (removed cells): column at prev - R opposite to motion
				var trail_x: int = _prev_impostor_center.x - radius * signi(move.x) + (step - 1) * signi(move.x)
				for cy in range(-radius, radius + 1):
					var lead_grid := Vector2i(lead_x, center_cell.y + cy)
					if DU.cell_distance_squared(center_cell, lead_grid) <= radius_sq:
						if lead_grid not in _loaded_impostor_cells and lead_grid not in _pending_impostor_cells:
							cells_to_load.append(lead_grid)
							_loaded_impostor_cells[lead_grid] = true
					var trail_grid := Vector2i(trail_x, _prev_impostor_center.y + cy)
					if DU.cell_distance_squared(_prev_impostor_center, trail_grid) <= radius_sq:
						if trail_grid in _loaded_impostor_cells:
							cells_to_unload.append(trail_grid)

		# For Y movement: scan rows at the leading and trailing Y edges
		if move.y != 0:
			for step in range(1, absi(move.y) + 1):
				var lead_y: int = center_cell.y + radius * signi(move.y) - (step - 1) * signi(move.y)
				var trail_y: int = _prev_impostor_center.y - radius * signi(move.y) + (step - 1) * signi(move.y)
				for cx in range(-radius, radius + 1):
					var lead_grid := Vector2i(center_cell.x + cx, lead_y)
					if DU.cell_distance_squared(center_cell, lead_grid) <= radius_sq:
						if lead_grid not in _loaded_impostor_cells and lead_grid not in _pending_impostor_cells:
							cells_to_load.append(lead_grid)
							_loaded_impostor_cells[lead_grid] = true
					var trail_grid := Vector2i(_prev_impostor_center.x + cx, trail_y)
					if DU.cell_distance_squared(_prev_impostor_center, trail_grid) <= radius_sq:
						if trail_grid in _loaded_impostor_cells:
							cells_to_unload.append(trail_grid)

		if not cells_to_unload.is_empty():
			_unload_impostors_in_cells(cells_to_unload)

		if not cells_to_load.is_empty():
			cells_to_load.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
				return DU.cell_distance_squared(center_cell, a) < DU.cell_distance_squared(center_cell, b)
			)
			_pending_impostor_cells.append_array(cells_to_load)

		Log.debug("impostors", "Differential: +%d -%d impostor cells (move:%s, scanned:%d)" % [
			cells_to_load.size(), cells_to_unload.size(), move,
			(absi(move.x) + absi(move.y)) * (2 * radius + 1) * 2])

	else:
		# Full recalculation (first call, teleport, or large move)
		var desired_cells: Dictionary = {}
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var grid := Vector2i(center_cell.x + dx, center_cell.y + dy)
				if DU.cell_distance_squared(center_cell, grid) <= radius_sq:
					desired_cells[grid] = true

		if debug_enabled:
			_debug("Full impostor recalc: center=%s, radius=%d, desired=%d" % [
				center_cell, radius, desired_cells.size()])

		var cells_to_unload: Array[Vector2i] = []
		for grid: Vector2i in _loaded_impostor_cells:
			if grid not in desired_cells:
				cells_to_unload.append(grid)

		if not cells_to_unload.is_empty():
			_unload_impostors_in_cells(cells_to_unload)

		var cells_to_load: Array[Vector2i] = []
		for grid: Vector2i in desired_cells:
			if grid not in _loaded_impostor_cells and grid not in _pending_impostor_cells:
				cells_to_load.append(grid)
				_loaded_impostor_cells[grid] = true

		if not cells_to_load.is_empty():
			cells_to_load.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
				return DU.cell_distance_squared(center_cell, a) < DU.cell_distance_squared(center_cell, b)
			)
			_pending_impostor_cells.append_array(cells_to_load)
			# Track initial count for progress reporting (only on first full recalc)
			if _initial_pending_count == 0:
				_initial_pending_count = _pending_impostor_cells.size()
			Log.info("impostors", "Queued %d impostor cells for deferred loading (total pending: %d)" % [
				cells_to_load.size(), _pending_impostor_cells.size()])

	_prev_impostor_center = center_cell


## Unload impostors belonging to specific cells
func _unload_impostors_in_cells(grids: Array[Vector2i]) -> void:
	for g: Vector2i in grids:
		_loaded_impostor_cells.erase(g)

	# Use spatial index for O(cell_count) lookup instead of O(total_impostors)
	var ids_to_remove: Array[int] = []
	for grid: Vector2i in grids:
		if grid not in _cell_index:
			continue
		for id: int in _cell_index[grid]:
			var imp: ImpostorData = _impostors.get(id)
			if imp:
				ids_to_remove.append(id)
				# Decrement texture reference count
				var hash_key: String = imp.texture_hash
				if hash_key in _texture_ref_counts:
					_texture_ref_counts[hash_key] -= 1
					if _texture_ref_counts[hash_key] <= 0:
						_texture_ref_counts.erase(hash_key)
				# Maintain reverse index
				if hash_key in _hash_to_impostor_ids:
					var hash_ids: Array = _hash_to_impostor_ids[hash_key]
					var hidx := hash_ids.find(id)
					if hidx >= 0:
						hash_ids[hidx] = hash_ids.back()
						hash_ids.pop_back()
					if hash_ids.is_empty():
						_hash_to_impostor_ids.erase(hash_key)
		_cell_index.erase(grid)

	for id: int in ids_to_remove:
		_impostors.erase(id)

	if not ids_to_remove.is_empty():
		_impostors_dirty = true  # Mark for MultiMesh rebuild

	_stats["total_impostors"] = _impostors.size()
	
	# Remove pending impostors
	var grid_set: Dictionary = {}
	for g2: Vector2i in grids:
		grid_set[g2] = true
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
## Load impostors from a cell record with intra-cell budget checking.
## Returns -1 if the cell was fully processed, or the reference index to resume from
## if the budget was exceeded mid-cell.
func _load_impostors_from_cell_record_budgeted(grid: Vector2i, start_ref: int, deadline_usec: int) -> int:
	if not ESMManager:
		Log.error("impostors", "ESMManager not available!")
		return -1

	var cell_record = ESMManager.get_exterior_cell(grid.x, grid.y)
	if not cell_record:
		if abs(grid.x) < 30 and abs(grid.y) < 30:
			_debug("No cell record for grid %s" % grid)
		return -1

	var refs: Array = cell_record.references
	var ref_count := refs.size()
	var impostor_count := 0
	var model_count := 0

	# Process references starting from start_ref (supports resume)
	var i := start_ref
	while i < ref_count:
		# Budget check every 16 refs to avoid Time.get_ticks_usec() overhead per-ref
		if (i - start_ref) & 15 == 15 and Time.get_ticks_usec() >= deadline_usec:
			return i  # Budget exceeded — return resume index

		var ref = refs[i]
		i += 1

		# Fast path: use cached ref_id -> model_path mapping
		var ref_id_str: String = str(ref.ref_id)
		var model_path: String
		if ref_id_str in _ref_id_to_model:
			model_path = _ref_id_to_model[ref_id_str]
			if model_path.is_empty():
				continue  # Cached as "no model"
		else:
			# Cache miss — do the expensive ESM lookup once
			var record = ESMManager.get_any_record(ref_id_str)
			if not record or not ("model" in record) or not record.model:
				_ref_id_to_model[ref_id_str] = ""  # Cache negative result
				continue
			model_path = record.model
			if model_path.is_empty():
				_ref_id_to_model[ref_id_str] = ""
				continue
			_ref_id_to_model[ref_id_str] = model_path

		model_count += 1

		# Check if it needs an impostor
		if impostor_candidates.should_have_impostor(model_path):
			impostor_count += 1
			var pos := CS.vector_to_godot(ref.position)
			var scale_vec := CS.scale_to_godot(ref.scale)
			var basis := CS.esm_rotation_to_godot_basis(ref.rotation)
			var rot_euler := basis.get_euler()

			add_impostor(model_path, grid, pos, rot_euler, scale_vec)

	if debug_enabled and (impostor_count > 0 or ref_count > 0):
		_debug("Cell %s: %d refs (from %d), %d models, %d impostor candidates" % [grid, ref_count, start_ref, model_count, impostor_count])

	return -1  # Cell fully processed


## Log screen-size histogram of all loaded impostors (one-time diagnostic)
func _log_screen_size_histogram() -> void:
	if _screen_size_histogram_logged:
		return
	_screen_size_histogram_logged = true

	var camera_pos := DU.cell_to_world_center(_last_center_cell)
	# Assume 1080p, 75° vertical FOV
	var screen_height := 1080.0
	var fov_rad := deg_to_rad(75.0)
	var half_screen_factor := screen_height / (2.0 * tan(fov_rad / 2.0))

	var buckets: Array[int] = [0, 0, 0, 0, 0]  # <1px, 1-2px, 2-5px, 5-10px, 10+px
	var bucket_names: Array[String] = ["<1px", "1-2px", "2-5px", "5-10px", "10+px"]

	for impostor_id: int in _impostors:
		var imp: ImpostorData = _impostors[impostor_id]
		var dist := camera_pos.distance_to(imp.position)
		if dist < 1.0:
			dist = 1.0
		var obj_size := maxf(imp.texture_size.x * imp.scale.x, imp.texture_size.y * imp.scale.y)
		var screen_px := obj_size / dist * half_screen_factor

		if screen_px < 1.0:
			buckets[0] += 1
		elif screen_px < 2.0:
			buckets[1] += 1
		elif screen_px < 5.0:
			buckets[2] += 1
		elif screen_px < 10.0:
			buckets[3] += 1
		else:
			buckets[4] += 1

	Log.info("impostors", "Screen-size histogram (%d total impostors):" % _impostors.size())
	for i in range(buckets.size()):
		var pct: float = 100.0 * buckets[i] / maxf(1.0, float(_impostors.size()))
		Log.info("impostors", "  %s: %d (%.1f%%)" % [bucket_names[i], buckets[i], pct])


func _debug(msg: String) -> void:
	if debug_enabled:
		Log.debug("impostors", msg)


## Cached file existence check — avoids repeated disk I/O for the same paths
func _cached_file_exists(path: String) -> bool:
	if path in _file_exists_cache:
		return _file_exists_cache[path]
	var exists := FileAccess.file_exists(path)
	_file_exists_cache[path] = exists
	return exists

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
	# Check if normal texture was already loaded for this hash
	var normal_idx: int = _normal_index_map.get(hash_key, -1)

	var pending_list: Array = _pending_impostors[hash_key]
	var created_count := pending_list.size()
	for pending: PendingImpostor in pending_list:
		var imp_id := _create_impostor(
			pending.model_path,
			pending.cell_grid,
			hash_key,
			pending.position,
			pending.rotation,
			pending.scale,
			pending.texture_size,
			pending.aabb_center_y
		)
		if imp_id >= 0 and imp_id in _impostors:
			# Set normal index if available
			if normal_idx >= 0:
				_impostors[imp_id].normal_texture_index = normal_idx
			# Propagate the bake variant flag from pending → live impostor
			(_impostors[imp_id] as ImpostorData).variant_flag = pending.variant_flag
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

	# Maintain spatial index for O(cell_size) unloading
	if cell_grid not in _cell_index:
		_cell_index[cell_grid] = [] as Array[int]
	_cell_index[cell_grid].append(impostor.id)

	# Increment texture reference count
	_texture_ref_counts[hash_key] = _texture_ref_counts.get(hash_key, 0) + 1

	# Maintain reverse index: hash_key -> impostor IDs
	if hash_key not in _hash_to_impostor_ids:
		_hash_to_impostor_ids[hash_key] = [] as Array[int]
	_hash_to_impostor_ids[hash_key].append(impostor.id)

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

	# Also compact normal arrays in parallel
	var new_normal_images: Array[Image] = []
	var new_normal_index_map: Dictionary = {}

	for i in used_hashes.size():
		var hash_key: String = used_hashes[i]
		if hash_key in _normal_index_map:
			var old_normal_idx: int = _normal_index_map[hash_key]
			new_normal_images.append(_all_normal_images[old_normal_idx])
			new_normal_index_map[hash_key] = new_normal_images.size() - 1

	# Update impostor texture indices to match new array positions
	for id: int in _impostors:
		var imp: ImpostorData = _impostors[id]
		if imp.texture_hash in new_index_map:
			imp.texture_index = new_index_map[imp.texture_hash]
			imp.normal_texture_index = new_normal_index_map.get(imp.texture_hash, -1)

	# Clear old cached textures that are no longer in the array
	for hash_key: String in _impostor_textures.keys():
		if hash_key not in new_index_map:
			_impostor_textures.erase(hash_key)
			_impostor_normal_images.erase(hash_key)

	# Replace arrays
	_all_array_images = new_images
	_texture_index_map = new_index_map
	_texture_array_size = new_images.size()
	_all_normal_images = new_normal_images
	_normal_index_map = new_normal_index_map
	_normal_array_size = new_normal_images.size()
	_texture_array_dirty = true
	_normal_array_dirty = true
	_impostors_dirty = true  # Need to rebuild MultiMesh with new indices

	_stats["texture_array_layers"] = _texture_array_size
	_stats["texture_cache_size"] = _impostor_textures.size()

	# Reset "array full" warning flag since we freed space
	if removed_count > 0:
		_stats["_logged_array_full"] = false


func _rebuild_texture_array() -> void:
	if _all_array_images.is_empty():
		_texture_array_dirty = false
		_normal_array_dirty = false
		return

	# Rebuild albedo texture array
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
	_texture_array_dirty = false

	# Rebuild normal texture array (if any normals loaded)
	if not _all_normal_images.is_empty():
		var normal_images: Array[Image] = []
		for img: Image in _all_normal_images:
			if img.get_format() != Image.FORMAT_RGBA8:
				img.convert(Image.FORMAT_RGBA8)
			normal_images.append(img)

		_normal_texture_array = Texture2DArray.new()
		err = _normal_texture_array.create_from_images(normal_images)
		if err != OK:
			push_error("[NativeImpostorRenderer] Failed to create normal texture array: %s" % error_string(err))
		else:
			Log.debug("impostors", "Rebuilt normal texture array with %d layers" % normal_images.size())
			_billboard_material.set_shader_parameter("normal_atlas", _normal_texture_array)
	_normal_array_dirty = false


func _rebuild_multimesh() -> void:
	var start_usec := Time.get_ticks_usec()
	var impostor_count := _impostors.size()

	if impostor_count == 0:
		_master_multimesh.instance_count = 0
		if debug_enabled:
			_debug("_rebuild_multimesh: No impostors to render")
		return

	# Build a PackedFloat32Array and use set_buffer() for a single bulk upload
	# instead of N * 2 individual set_instance_transform/set_instance_custom_data calls.
	#
	# Buffer layout per instance (TRANSFORM_3D + custom_data, no colors):
	#   12 floats: Transform3D as 3 rows of [basis_col.x, basis_col.y, basis_col.z, origin_component]
	#     Row 0: [basis.x.x, basis.x.y, basis.x.z, origin.x]  (column 0 + origin.x)
	#     Row 1: [basis.y.x, basis.y.y, basis.y.z, origin.y]  (column 1 + origin.y)
	#     Row 2: [basis.z.x, basis.z.y, basis.z.z, origin.z]  (column 2 + origin.z)
	#   4 floats: custom_data [r, g, b, a]
	# Total: 16 floats per instance
	var stride := 16
	var buffer := PackedFloat32Array()
	buffer.resize(impostor_count * stride)

	var offset := 0
	for impostor_id: int in _impostors:
		var impostor: ImpostorData = _impostors[impostor_id]

		# Position billboard at model center (adjusted for AABB center)
		var billboard_pos := impostor.position
		billboard_pos.y += impostor.aabb_center_y * impostor.scale.y

		# Scale based on texture size
		var sx := impostor.texture_size.x * impostor.scale.x
		var sy := impostor.texture_size.y * impostor.scale.y

		# Transform: scaled identity basis (diagonal: sx, sy, 1.0) + origin
		# Column 0 + origin.x
		buffer[offset +  0] = sx
		buffer[offset +  1] = 0.0
		buffer[offset +  2] = 0.0
		buffer[offset +  3] = billboard_pos.x
		# Column 1 + origin.y
		buffer[offset +  4] = 0.0
		buffer[offset +  5] = sy
		buffer[offset +  6] = 0.0
		buffer[offset +  7] = billboard_pos.y
		# Column 2 + origin.z
		buffer[offset +  8] = 0.0
		buffer[offset +  9] = 0.0
		buffer[offset + 10] = 1.0
		buffer[offset + 11] = billboard_pos.z
		# Custom data: texture_index, rotation_y, normal_index, variant_flag
		# .w (variant_flag) selects shader path:
		#   0.0 = Variant A — legacy v4 azimuthal 16-frame
		#   1.0 = Variant B — v5 hemi octahedral
		#   2.0 = Variant B — v5 sphere octahedral
		buffer[offset + 12] = float(impostor.texture_index)
		buffer[offset + 13] = impostor.rotation.y
		buffer[offset + 14] = float(impostor.normal_texture_index)
		buffer[offset + 15] = impostor.variant_flag

		offset += stride

	_master_multimesh.instance_count = impostor_count
	_master_multimesh.set_buffer(buffer)

	var elapsed_usec := Time.get_ticks_usec() - start_usec
	Log.debug("impostors", "MultiMesh rebuild: %d instances, %.2f ms (set_buffer)" % [
		impostor_count, elapsed_usec / 1000.0])


func _get_or_load_metadata(model_path: String) -> Dictionary:
	var hash_key := ImpostorCandidatesScript.get_hash_key(model_path)

	if hash_key in _impostor_metadata:
		return _impostor_metadata[hash_key]

	# Prefer v5 metadata if present (octahedral bakes), otherwise fall back to
	# v4 (legacy azimuthal bakes). Same hash key for both — only the filename
	# suffix differs.
	var v5_path := ImpostorCandidatesScript.get_impostor_metadata_path_v5(model_path)
	var metadata_path := v5_path if FileAccess.file_exists(v5_path) else ImpostorCandidatesScript.get_impostor_metadata_path(model_path)
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
