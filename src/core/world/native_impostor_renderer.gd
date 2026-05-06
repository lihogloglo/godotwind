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
const WorldObjectRecordScript := preload("res://src/core/world/world_object_record.gd")
# We assume global CS class is available or we use duplicated logic?
# Best to rely on the fact that CellManager usually handles this.
# Note: Since we are reading raw ESM data here, we might need CoordinateSystem.
# We'll trust the user to have CS singleton or class.
const CS := preload("res://src/core/coordinate_system.gd")

#region Configuration

const DEFAULT_ATLAS_SIZE: int = 512
const SUPPORTED_ATLAS_SIZES: Array[int] = [512, 1024]
const MAX_TEXTURE_ARRAY_LAYERS: int = 256
const TEXTURE_ARRAY_SLAB_LAYERS: int = 4
const HERO_ATLAS_CAPTURE_SIZE_M: float = 48.0

## Texture array rebuild delay (batch multiple additions)
const TEXTURE_ARRAY_REBUILD_DELAY: float = 0.1

## Main-thread texture result handling budget. A single completed texture can
## create hundreds of impostors, so poll one result at a time and stop before
## texture finalization monopolizes a frame.
const JOB_RESULT_POLL_MAX_PER_FRAME: int = 4
const JOB_RESULT_POLL_BUDGET_USEC: int = 1500
const TEXTURE_LOAD_MAX_ACTIVE_TASKS: int = 2

## Full-ring uploads are expensive while the startup ring is still ingesting.
## Let the first visible batch appear quickly, then throttle progressive global
## commits until the queue drains.
const STARTUP_TEXTURE_REBUILD_INTERVAL: float = 0.25
const READY_IMPOSTOR_CREATE_MAX_PER_FRAME: int = 64
const READY_IMPOSTOR_CREATE_BUDGET_USEC: int = 1000
const IMPOSTOR_PAGE_SIZE_CELLS: int = 4
const IMPOSTOR_PAGE_REBUILD_MAX_PER_FRAME: int = 6
const IMPOSTOR_PAGE_REBUILD_BUDGET_USEC: int = 1000
const IMPOSTOR_PAGE_AABB_MARGIN: float = 64.0

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

## Shared billboard mesh/material. Instances are split into spatial pages so
## Godot can frustum/distance-cull bounded MultiMesh batches.
var _quad_mesh: QuadMesh = null
var _page_container: Node3D = null
var _impostor_pages: Dictionary[String, ImpostorPage] = {}
var _dirty_page_keys: Array[String] = []
var _dirty_page_set: Dictionary[String, bool] = {}
var _visibility_begin_distance: float = DU.FAR_START
var _visibility_end_distance: float = DU.FAR_END
var _visibility_fade_margin: float = DU.FADE_MARGIN_RENDER_FAR

## Billboard shader material with texture array
var _billboard_shader: Shader = null
var _billboard_material: ShaderMaterial = null
var _billboard_materials: Dictionary[String, ShaderMaterial] = {}

## Texture arrays for batched rendering, split by v6 atlas size.
var _texture_buckets: Dictionary[String, TextureBucket] = {}
var _hash_to_atlas_size: Dictionary[String, int] = {}
var _hash_to_bucket_key: Dictionary[String, String] = {}
var _last_texture_add_time: float = 0.0

## Phase 6 (2026-04-17) — async texture-array rebuild.
##
## The CPU-side work of converting + deep-copying the full 256-layer image
## set runs on a worker thread. Main thread finalises with the synchronous
## `Texture2DArray.new() + create_from_images()` call (RenderingServer
## texture allocation is main-thread only in Godot 4.6, verified against
## docs — offloading this last step would require a `RenderingDevice`
## rewrite).
##
## Double-buffer: the previous `_texture_array` is held in `_old_texture_array`
## for one frame after the swap to avoid a GPU-side use-after-free on
## drivers that batch texture binds across command buffers.
var _rebuild_task_id: int = -1                       ## -1 = idle
var _rebuild_bucket_key: String = ""
var _rebuild_pending_albedo: Array[Image] = []       ## worker output
var _rebuild_pending_normals: Array[Image] = []      ## worker output
var _texture_array_committed_this_frame: bool = false
var _next_rebuild_bucket_index: int = 0

## Reference count for textures: hash_key -> count of impostors using it
var _texture_ref_counts: Dictionary[String, int] = {}

## Reverse index: texture_hash -> Array[int] of impostor IDs using that hash
## Enables O(k) lookup instead of O(total_impostors) when a normal texture loads
var _hash_to_impostor_ids: Dictionary[String, Array] = {}  # Array[int]

## Loaded impostor albedo marker. The renderable GPU copy lives only in the
## Texture2DArray; do not create per-texture ImageTexture resources here.
var _impostor_textures: Dictionary[String, bool] = {}

## Loaded normal textures: hash_key -> Image (stored as Image, added to array)
var _impostor_normal_images: Dictionary[String, Image] = {}

## WorkerThreadPool-backed async texture loading
var _texture_jobs_active: bool = false
var _pending_job_ids: Dictionary[String, int] = {} # hash_key -> job_id
var _queued_texture_jobs: Array[Dictionary] = []
var _queued_texture_job_keys: Dictionary[String, bool] = {}
var _pending_job_results: Dictionary[String, Dictionary] = {}
var _pending_job_results_mutex: Mutex = Mutex.new()

## Pending impostors waiting for texture
var _pending_impostors: Dictionary[String, Array] = {}  # hash_key -> Array[PendingImpostor]
var _ready_texture_hashes: Array[String] = []
var _ready_texture_hash_set: Dictionary[String, bool] = {}

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
var _last_texture_array_rebuild_time: float = 0.0

## Deferred impostor loading - process cells progressively to avoid freezing
var _pending_impostor_cells: Array[Vector2i] = []  # Cells waiting to be processed
var _pending_impostor_cell_set: Dictionary[Vector2i, bool] = {}
var _pending_cell_index: int = 0  # Current front of the queue
var _impostor_load_budget_usec: float = 4000.0  # Time budget in microseconds (4ms)

## Intra-cell resume state — when a dense cell exceeds the budget mid-reference,
## we save progress and resume next frame instead of blowing through the budget
var _has_resume: bool = false
var _resume_cell_grid: Vector2i = Vector2i.ZERO
var _resume_ref_index: int = 0

## Resumable full-area recalc. Initial/teleport FAR rings can cover thousands
## of cells, so the scan itself is publication work and must yield to the
## shared conductor instead of building the whole queue in one frame.
var _area_update_active: bool = false
var _area_update_center: Vector2i = Vector2i.ZERO
var _area_update_radius: int = 0
var _area_update_radius_sq: float = 0.0
var _area_update_dx: int = 0
var _area_update_dy: int = 0
var _area_update_phase: int = 0
var _area_update_desired_cells: Dictionary = {}
var _area_update_loaded_keys: Array[Vector2i] = []
var _area_update_loaded_index: int = 0
var _area_update_desired_keys: Array = []
var _area_update_desired_index: int = 0
var _area_update_new_cells: int = 0

## Statistics
var _stats: Dictionary = {
	"total_impostors": 0,
	"texture_cache_size": 0,
	"texture_array_layers": 0,
	"pending_loads": 0,
	"skipped_no_texture": 0,  # Models that matched patterns but had no prebaked texture
	"skipped_not_candidate": 0,  # Models that didn't match impostor candidate patterns
	"far_cell_scan_us": 0,
	"far_cells_processed_last_frame": 0,
	"far_job_poll_us": 0,
	"far_job_results_handled": 0,
	"far_ready_create_us": 0,
	"far_ready_created": 0,
	"far_texture_upload_us": 0,
	"far_normal_upload_us": 0,
	"far_texture_upload_us_512": 0,
	"far_normal_upload_us_512": 0,
	"far_texture_upload_us_1024": 0,
	"far_normal_upload_us_1024": 0,
	"far_multimesh_pack_us": 0,
	"far_multimesh_upload_us": 0,
	"far_uploaded_instances": 0,
	"far_page_count": 0,
	"far_dirty_page_count": 0,
	"far_pages_rebuilt": 0,
	"far_visible_page_count": 0,
	"far_rebuild_deferred_pending": 0,
	"job_results_processed_last_frame": 0,
	"job_result_poll_last_ms": 0.0,
	"job_result_poll_max_ms": 0.0,
	"texture_array_rebuild_count": 0,
	"texture_array_upload_last_ms": 0.0,
	"texture_array_upload_max_ms": 0.0,
	"multimesh_rebuild_count": 0,
	"multimesh_rebuild_last_ms": 0.0,
	"multimesh_rebuild_max_ms": 0.0,
}

## Debug logging
var debug_enabled: bool = false

## SubsystemToggles "impostors" flag state. When false, `_process` skips the
## streaming work (pending-cell loader, texture-array rebuild, MultiMesh
## rebuild) so the impostor tier measures as fully-off, not just hidden.
## Mirrors the dual-purpose gate pattern used by ObjectPaging + StaticObjectRenderer.
var _streaming_enabled: bool = true

## Benchmark timer for periodic stats logging
var _benchmark_timer: float = 0.0
const BENCHMARK_LOG_INTERVAL: float = 5.0

## Last known camera center cell (for screen-size estimation)
var _last_center_cell: Vector2i = Vector2i.ZERO
var _screen_size_histogram_logged: bool = false

## Previous center for differential impostor updates
var _prev_impostor_center: Vector2i = Vector2i(999999, 999999)
var _prev_impostor_radius: int = -1
var _hlod_covered_object_ids: Dictionary = {}
var _world_object_source: RefCounted = null
var _fast_cleanup_done: bool = false

#endregion


#region Data Classes

class PendingImpostor:
	var model_path: String
	var cell_grid: Vector2i  # Cell this belongs to
	var atlas_size: int = 512
	var ref_id: String = ""
	var ref_num: int = 0
	var source_object_id: StringName = &""
	var position: Vector3
	var rotation: Vector3
	var scale: Vector3
	var texture_size: Vector2
	var aabb_center: Vector3 = Vector3.ZERO
	var variant_flag: float = 0.0  # See ImpostorData.variant_flag


class ImpostorData:
	var id: int
	var cell_grid: Vector2i # Cell this belongs to
	var page_key: String
	var bucket_key: String
	var atlas_size: int = 512
	var slab_index: int = 0
	var ref_id: String = ""
	var ref_num: int = 0
	var source_object_id: StringName = &""
	var model_path: String
	var texture_hash: String
	var texture_index: int
	var normal_texture_index: int = -1
	var position: Vector3
	var rotation: Vector3
	var scale: Vector3
	var texture_size: Vector2
	var aabb_center: Vector3 = Vector3.ZERO
	## Bake variant flag, packed into INSTANCE_CUSTOM.w for the shader.
	## Lets the shader pick the v6 octahedral projection at sample time.
	##   1.0 = v6 hemi octahedral
	##   2.0 = v6 sphere octahedral
	var variant_flag: float = 0.0


class ImpostorPage:
	var key: String
	var spatial_key: Vector2i
	var bucket_key: String
	var atlas_size: int = 512
	var slab_index: int = 0
	var center: Vector3
	var multimesh: MultiMesh
	var instance: MultiMeshInstance3D
	var impostor_ids: Array[int] = []
	var visibility_begin_distance: float = 0.0


class TextureBucket:
	var key: String
	var atlas_size: int = 512
	var slab_index: int = 0
	var material: ShaderMaterial = null
	var texture_array: Texture2DArray = null
	var normal_texture_array: Texture2DArray = null
	var old_texture_array: Texture2DArray = null
	var old_normal_texture_array: Texture2DArray = null
	var texture_index_map: Dictionary[String, int] = {}
	var normal_index_map: Dictionary[String, int] = {}
	var all_array_images: Array[Image] = []
	var all_normal_images: Array[Image] = []
	var texture_array_dirty: bool = false
	var normal_array_dirty: bool = false
	var committed_texture_array_layers: int = 0
	var committed_normal_array_layers: int = 0

#endregion


## SubsystemToggles handler: release FAR resources when the tier is off.
func set_enabled(enabled: bool) -> void:
	if enabled:
		_ensure_runtime_resources()
		_streaming_enabled = true
		visible = true
		set_process(false)
		_prev_impostor_center = Vector2i(999999, 999999)
		_prev_impostor_radius = -1
	else:
		release_runtime_resources()


func is_enabled() -> bool:
	return _streaming_enabled


func set_force_visible_for_test(enabled: bool) -> void:
	if enabled:
		_visibility_begin_distance = 0.0
		_visibility_fade_margin = 0.0
		_apply_visibility_ranges_to_pages()
		_apply_material_visibility_params(0.0, 0.0)
	else:
		set_visibility_range(DU.FAR_START, DU.FAR_END, DU.FADE_MARGIN_RENDER_FAR)


#region Initialization

func _ready() -> void:
	Log.info("impostors", "Initializing impostor renderer...")
	_setup_paged_multimeshes()
	_setup_billboard_material()
	_start_texture_jobs()
	Log.info("impostors", "Initialization complete. Debug enabled: %s" % debug_enabled)


func _exit_tree() -> void:
	if _fast_cleanup_done:
		return
	if Engine.has_meta("_quitting"):
		fast_cleanup()
		return
	fast_cleanup()


## Shutdown hook used by NativeStreamingManager.fast_cleanup().
## Stops thread owners before the scene tree starts freeing resources.
func fast_cleanup() -> void:
	if _fast_cleanup_done:
		return
	_fast_cleanup_done = true
	set_process(false)
	_streaming_enabled = false
	_stop_texture_jobs()
	# Phase 6: drain any in-flight rebuild worker task so its closure and
	# Image refs release before we go. Cheap — the task is CPU-only.
	if _rebuild_task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_rebuild_task_id)
		_rebuild_task_id = -1
		_rebuild_bucket_key = ""
		_rebuild_pending_albedo = []
		_rebuild_pending_normals = []
	Log.info("shutdown", "NativeImpostorRenderer fast_cleanup: workers stopped")
	_pending_impostor_cells.clear()
	_pending_impostor_cell_set.clear()
	_pending_cell_index = 0
	_pending_impostors.clear()
	_ready_texture_hashes.clear()
	_ready_texture_hash_set.clear()
	_pending_job_ids.clear()
	_has_resume = false
	_impostors_dirty = false
	Log.info("shutdown", "NativeImpostorRenderer fast_cleanup: queues cleared")
	# Terminal quit path: stop producers and leave existing visual resources to
	# the scene-tree/engine teardown. Manually freeing MultiMeshInstance3D,
	# ShaderMaterial, and Texture2DArray resources during an automated quit can
	# race the render frame that is still draining.


## Runtime off switch used by SubsystemToggles. Unlike `fast_cleanup()`, this
## keeps the renderer node reusable so toggling FAR back on can rebuild cleanly.
func release_runtime_resources() -> void:
	set_process(false)
	_streaming_enabled = false
	visible = false
	_stop_texture_jobs()
	if _rebuild_task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_rebuild_task_id)
		_rebuild_task_id = -1
		_rebuild_bucket_key = ""
		_rebuild_pending_albedo = []
		_rebuild_pending_normals = []
	clear()
	_texture_buckets.clear()
	_billboard_materials.clear()
	_billboard_material = null
	_get_or_create_bucket(DEFAULT_ATLAS_SIZE, 0)


func _detach_render_resources() -> void:
	_clear_pages(true)
	if _page_container:
		var parent := _page_container.get_parent()
		if parent:
			parent.remove_child(_page_container)
		_page_container.free()
		_page_container = null
	if _quad_mesh and _quad_mesh.get_surface_count() > 0:
		_quad_mesh.surface_set_material(0, null)
	_quad_mesh = null
	if _billboard_material:
		_billboard_material.shader = null
	_billboard_material = null
	_billboard_materials.clear()
	_texture_buckets.clear()


func _ensure_runtime_resources() -> void:
	if _page_container == null:
		_setup_paged_multimeshes()
	if _billboard_shader == null or _quad_mesh == null:
		_setup_billboard_material()
	else:
		_get_or_create_bucket(DEFAULT_ATLAS_SIZE, 0)
		if _quad_mesh:
			_quad_mesh.surface_set_material(0, _billboard_material)
	_start_texture_jobs()


func _setup_paged_multimeshes() -> void:
	_quad_mesh = QuadMesh.new()
	_quad_mesh.size = Vector2(1.0, 1.0)

	_page_container = Node3D.new()
	_page_container.name = "ImpostorPages"
	add_child(_page_container)


func _normalize_atlas_size(atlas_size: int) -> int:
	if atlas_size >= 1024:
		return 1024
	return DEFAULT_ATLAS_SIZE


func _is_supported_atlas_size(atlas_size: int) -> bool:
	return atlas_size in SUPPORTED_ATLAS_SIZES


func _resolve_runtime_atlas_size(metadata: Dictionary) -> int:
	var bounds: Dictionary = metadata.get("bounds", {})
	var capture_size := float(bounds.get("capture_size", 0.0))
	if capture_size <= 0.0:
		capture_size = maxf(
			maxf(float(bounds.get("width", 0.0)), float(bounds.get("height", 0.0))),
			float(bounds.get("depth", 0.0))
		)
	if capture_size >= HERO_ATLAS_CAPTURE_SIZE_M:
		return 1024
	return DEFAULT_ATLAS_SIZE


func _setup_billboard_material() -> void:
	var shader := Shader.new()
	shader.code = _get_octahedral_shader_code()
	_billboard_shader = shader

	# Check if shader compiled successfully
	# Note: Godot doesn't expose direct "is_valid" for shaders, but errors print to console
	Log.debug("impostors", "Shader code length: %d chars" % shader.code.length())

	_get_or_create_bucket(DEFAULT_ATLAS_SIZE, 0)

	if _quad_mesh:
		_quad_mesh.surface_set_material(0, _billboard_material)
		Log.debug("impostors", "Set material on shared impostor quad")


func _bucket_key(atlas_size: int, slab_index: int) -> String:
	atlas_size = _normalize_atlas_size(atlas_size)
	return "%d:%d" % [atlas_size, maxi(0, slab_index)]


func _get_bucket_for_hash(hash_key: String) -> TextureBucket:
	var bucket_key: String = _hash_to_bucket_key.get(hash_key, "")
	if bucket_key.is_empty() or bucket_key not in _texture_buckets:
		return null
	return _texture_buckets[bucket_key]


func _get_or_create_bucket(atlas_size: int, slab_index: int = 0) -> TextureBucket:
	atlas_size = _normalize_atlas_size(atlas_size)
	slab_index = maxi(0, slab_index)
	var key := _bucket_key(atlas_size, slab_index)
	if key in _texture_buckets:
		return _texture_buckets[key]

	var bucket := TextureBucket.new()
	bucket.key = key
	bucket.atlas_size = atlas_size
	bucket.slab_index = slab_index
	bucket.material = ShaderMaterial.new()
	bucket.material.shader = _billboard_shader
	bucket.material.set_shader_parameter("fade_distance", _visibility_begin_distance)
	bucket.material.set_shader_parameter("fade_margin", _visibility_fade_margin)
	bucket.material.set_shader_parameter("debug_mode", false)
	_assign_default_texture_arrays(bucket)

	_texture_buckets[key] = bucket
	_billboard_materials[key] = bucket.material
	if key == _bucket_key(DEFAULT_ATLAS_SIZE, 0) or _billboard_material == null:
		_billboard_material = bucket.material
	return bucket


func _get_write_bucket(atlas_size: int) -> TextureBucket:
	atlas_size = _normalize_atlas_size(atlas_size)
	var slab_index := 0
	while slab_index * TEXTURE_ARRAY_SLAB_LAYERS < MAX_TEXTURE_ARRAY_LAYERS:
		var key := _bucket_key(atlas_size, slab_index)
		if key in _texture_buckets:
			var bucket: TextureBucket = _texture_buckets[key]
			if maxi(bucket.all_array_images.size(), bucket.all_normal_images.size()) < TEXTURE_ARRAY_SLAB_LAYERS:
				return bucket
		else:
			return _get_or_create_bucket(atlas_size, slab_index)
		slab_index += 1
	return null


func _get_or_assign_bucket_for_hash(hash_key: String, atlas_size: int) -> TextureBucket:
	var bucket := _get_bucket_for_hash(hash_key)
	if bucket != null:
		return bucket
	bucket = _get_write_bucket(atlas_size)
	if bucket != null:
		_hash_to_bucket_key[hash_key] = bucket.key
	return bucket


func _assign_default_texture_arrays(bucket: TextureBucket) -> void:
	if bucket == null or bucket.material == null:
		return

	var default_img := Image.create(bucket.atlas_size, bucket.atlas_size, false, Image.FORMAT_RGBA8)
	default_img.fill(Color(0, 0, 0, 0))
	var default_array := Texture2DArray.new()
	default_array.create_from_images([default_img])
	bucket.texture_array = default_array
	bucket.material.set_shader_parameter("texture_atlas", bucket.texture_array)

	# Normal atlas: default to up-facing normal (0.5, 1.0, 0.5), zero depth
	var default_normal_img := Image.create(bucket.atlas_size, bucket.atlas_size, false, Image.FORMAT_RGBA8)
	default_normal_img.fill(Color(0.5, 1.0, 0.5, 0.0))
	var default_normal_array := Texture2DArray.new()
	default_normal_array.create_from_images([default_normal_img])
	bucket.normal_texture_array = default_normal_array
	bucket.material.set_shader_parameter("normal_atlas", bucket.normal_texture_array)
	bucket.committed_texture_array_layers = 0
	bucket.committed_normal_array_layers = 0


## Toggle debug mode for impostor shader (shows bright magenta at any distance)
## CRITICAL: Also disables visibility_range_begin so impostors render at close range
func set_shader_debug_mode(enabled: bool) -> void:
	Log.debug("impostors", "set_shader_debug_mode called with: %s" % enabled)
	Log.debug("impostors", "_billboard_material is: %s" % (_billboard_material != null))
	Log.debug("impostors", "page count is: %d" % _impostor_pages.size())

	if _billboard_material and _billboard_material.shader:
		var shader_code: String = _billboard_material.shader.code
		if "debug_mode" in shader_code:
			for material: ShaderMaterial in _billboard_materials.values():
				material.set_shader_parameter("debug_mode", enabled)
	else:
		Log.error("impostors", "_billboard_material or shader is null!")

	if enabled:
		for page: ImpostorPage in _impostor_pages.values():
			page.instance.visibility_range_begin = 0.0
			page.instance.visibility_range_begin_margin = 0.0
	else:
		_apply_visibility_ranges_to_pages()

	Log.info("impostors", "Shader debug mode: %s" % ("ON - magenta squares at ANY distance" if enabled else "OFF - normal rendering (FAR tier)"))


func set_normal_debug_for_test(enabled: bool) -> void:
	for material: ShaderMaterial in _billboard_materials.values():
		material.set_shader_parameter("debug_normals", enabled)


## Adjust impostor visibility_range_begin to match the active tier layout.
## FAR starts at FAR_START. Page-level HLOD coverage is retained as diagnostic
## metadata, but the production tier handoff is the fixed 1000m boundary.
func set_visibility_range_begin(begin_distance: float, fade_margin: float = DU.FADE_MARGIN_RENDER_FAR) -> void:
	_visibility_begin_distance = begin_distance
	_visibility_fade_margin = fade_margin
	_apply_visibility_ranges_to_pages()
	Log.info("impostors", "visibility_range_begin set to %.0fm (fade margin %.0fm)" % [
		begin_distance - fade_margin, fade_margin])


func set_visibility_range(begin_distance: float, end_distance: float, fade_margin: float = DU.FADE_MARGIN_RENDER_FAR) -> void:
	_visibility_begin_distance = begin_distance
	_visibility_end_distance = clampf(end_distance, begin_distance, DU.FAR_END)
	_visibility_fade_margin = fade_margin
	_apply_visibility_ranges_to_pages()
	Log.info("impostors", "visibility_range fixed %.0f-%.0fm (fade margin %.0fm)" % [
		begin_distance, _visibility_end_distance, fade_margin])


func set_hlod_covered_ref_nums(covered_ref_nums: Dictionary) -> void:
	set_hlod_covered_object_ids(covered_ref_nums)


func set_hlod_covered_object_ids(covered_object_ids: Dictionary) -> void:
	_hlod_covered_object_ids = covered_object_ids.duplicate()
	_apply_visibility_ranges_to_pages()


func set_world_object_source(source: RefCounted) -> void:
	_world_object_source = source

#endregion


#region Octahedral Billboard Shader (Lit with Normal Maps)

func _get_octahedral_shader_code() -> String:
	# Lit billboard impostor shader. v6-only projection, per-instance via
	# INSTANCE_CUSTOM.w:
	#   1.0 = v6 hemi octahedral tri-sample (8x8)
	#   2.0 = v6 sphere octahedral tri-sample (8x8)
	#
	# INSTANCE_CUSTOM: .x=albedo layer, .y=yaw rad, .z=normal layer, .w=variant
	#
	# v6 addresses IMPOSTOR_REBUILD.md audit:
	# §2.1 true octahedral sampling, §2.3 tri-sample + renormalize,
	# §2.4 yaw-rotated normals, §2.6 shadow receive.
	# §2.5 parallax deferred. §2.7 NORMAL_MATRIX is read-only in 4.6 (moot
	# since fragment overrides NORMAL from atlas).
	#
	# v6 uses Brucks tri-sample blending (barycentric weights across
	# the 3 nearest octahedral grid cells) for smooth angular transitions
	# with no visible frame popping. Parallax deferred — add if validation
	# shows missing depth cues.
	#
	# Per-impostor distance culling stays in fragment because MultiMesh
	# visibility_range checks node position not per-instance position.
	return """
shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled, alpha_to_coverage;

uniform sampler2DArray texture_atlas : source_color, filter_linear_mipmap;
uniform sampler2DArray normal_atlas : filter_linear_mipmap;
uniform float fade_distance = 500.0;
uniform float fade_margin = 50.0;
uniform bool debug_mode = false;
uniform bool debug_normals = false;
uniform float impostor_roughness : hint_range(0.0, 1.0) = 0.85;
uniform float impostor_specular : hint_range(0.0, 1.0) = 0.3;

// v6 grid size — must match impostor_baker_v3.GRID_SIZE
const int V6_GRID_SIZE = 8;

varying flat float texture_layer;
varying flat float normal_layer;
varying flat float rotation_offset;
varying flat float variant_flag;
varying flat vec3 view_dir_world_flat;
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

vec2 atlas_frame_uv(vec2 local_uv, ivec2 cell, ivec2 grid) {
	vec2 atlas_px = vec2(textureSize(texture_atlas, 0).xy);
	vec2 frame_px = atlas_px / vec2(grid);
	vec2 inset_uv = (local_uv * max(frame_px - vec2(2.0), vec2(1.0)) + vec2(1.0)) / atlas_px;
	return vec2(cell) / vec2(grid) + inset_uv;
}

void vertex() {
	texture_layer = INSTANCE_CUSTOM.x;
	rotation_offset = INSTANCE_CUSTOM.y;
	normal_layer = INSTANCE_CUSTOM.z;
	variant_flag = INSTANCE_CUSTOM.w;

	vec3 camera_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 impostor_center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	dist_to_camera = distance(camera_pos, impostor_center);
	view_dir_world_flat = normalize(camera_pos - impostor_center);

	// Camera-plane billboard. V6 atlas selection accounts for the actual
	// view direction; the card itself must face the camera for elevated views.
	// Use the camera right vector directly so the atlas frame is not mirrored
	// on the camera-facing card.
	vec3 right = normalize(INV_VIEW_MATRIX[0].xyz);
	vec3 up = normalize(INV_VIEW_MATRIX[1].xyz);
	vec3 look_dir = normalize(INV_VIEW_MATRIX[2].xyz);

	float scale_x = length(MODEL_MATRIX[0].xyz);
	float scale_y = length(MODEL_MATRIX[1].xyz);

	mat4 billboard = mat4(
		vec4(right * scale_x, 0.0),
		vec4(up * scale_y, 0.0),
		vec4(look_dir, 0.0),
		MODEL_MATRIX[3]
	);

	MODELVIEW_MATRIX = VIEW_MATRIX * billboard;
	// Audit S2.7: NORMAL_MATRIX is read-only in Godot 4.6. Not a problem —
	// the fragment shader overrides NORMAL directly from the baked normal
	// atlas, so the stale NORMAL_MATRIX is never consumed.
}

void fragment() {
	// Per-impostor distance culling (visibility_range hits node, not instance)
	if (!debug_mode && dist_to_camera < fade_distance - fade_margin) {
		discard;
	}

	vec3 view_dir_world = normalize(view_dir_world_flat);
	bool has_normals = normal_layer >= 0.0;

	vec4 tex;
	vec4 normal_data;

	// Reference: Ryan Brucks, "Octahedral Impostors Part 2: Triangle
	// Blending" (shaderbits.com). Three nearest grid cells blended by
	// barycentric weights = smooth angular transitions, no frame popping.
	vec3 view_dir_local = rotate_y(view_dir_world, -rotation_offset);

	vec2 oct_uv;
	if (variant_flag > 1.5) {
		oct_uv = oct_encode_sphere(view_dir_local);
	} else {
		oct_uv = oct_encode_hemi(view_dir_local);
	}

	// Continuous grid coordinate. Baker directions are generated at frame
	// centers ((cell + 0.5) / N), so subtract 0.5 before the triangle
	// lookup. Without this, exact baked views blend neighboring frames and
	// thin silhouettes can disappear or double.
	vec2 grid_coord = (oct_uv * 0.5 + 0.5) * float(V6_GRID_SIZE) - vec2(0.5);
	vec2 base = floor(grid_coord);
	vec2 f = grid_coord - base;

	// The unit cell splits into two triangles along the diagonal.
	// Determine which triangle contains the sample point.
	ivec2 cell_a, cell_b, cell_c;
	vec3 bary;

	if (f.x + f.y > 1.0) {
		// Lower-right triangle: vertices (1,0), (0,1), (1,1)
		cell_a = ivec2(base) + ivec2(1, 0);
		cell_b = ivec2(base) + ivec2(0, 1);
		cell_c = ivec2(base) + ivec2(1, 1);
		vec2 g = 1.0 - f;
		bary = vec3(g.y, g.x, 1.0 - g.x - g.y);
	} else {
		// Upper-left triangle: vertices (0,0), (1,0), (0,1)
		cell_a = ivec2(base);
		cell_b = ivec2(base) + ivec2(1, 0);
		cell_c = ivec2(base) + ivec2(0, 1);
		bary = vec3(1.0 - f.x - f.y, f.x, f.y);
	}

	// Clamp to grid bounds
	ivec2 grid_max = ivec2(V6_GRID_SIZE - 1);
	cell_a = clamp(cell_a, ivec2(0), grid_max);
	cell_b = clamp(cell_b, ivec2(0), grid_max);
	cell_c = clamp(cell_c, ivec2(0), grid_max);

	// Sample all three cells and blend by barycentric weights
	vec2 uv_a = atlas_frame_uv(UV, cell_a, ivec2(V6_GRID_SIZE, V6_GRID_SIZE));
	vec2 uv_b = atlas_frame_uv(UV, cell_b, ivec2(V6_GRID_SIZE, V6_GRID_SIZE));
	vec2 uv_c = atlas_frame_uv(UV, cell_c, ivec2(V6_GRID_SIZE, V6_GRID_SIZE));

	vec4 tex_a = texture(texture_atlas, vec3(uv_a, texture_layer));
	vec4 tex_b = texture(texture_atlas, vec3(uv_b, texture_layer));
	vec4 tex_c = texture(texture_atlas, vec3(uv_c, texture_layer));
	tex = tex_a * bary.x + tex_b * bary.y + tex_c * bary.z;

	if (has_normals) {
		vec4 nd_a = texture(normal_atlas, vec3(uv_a, normal_layer));
		vec4 nd_b = texture(normal_atlas, vec3(uv_b, normal_layer));
		vec4 nd_c = texture(normal_atlas, vec3(uv_c, normal_layer));
		normal_data = nd_a * bary.x + nd_b * bary.y + nd_c * bary.z;
	}

	if (debug_mode) {
		ALBEDO = vec3(1.0, 0.0, 1.0);
		ALPHA = 1.0;
	} else {
		if (tex.a < 0.1) {
			discard;
		}

		ALBEDO = tex.rgb;
		ALPHA = tex.a;
		ALPHA_SCISSOR_THRESHOLD = 0.08;
		ALPHA_ANTIALIASING_EDGE = 0.02;
		ALPHA_TEXTURE_COORDINATE = UV * vec2(textureSize(texture_atlas, 0).xy);

		if (has_normals) {
			// Decode and renormalize (critical after tri-sample blending —
			// linear interpolation of encoded normals shortens the vector)
			vec3 baked_normal = normalize(normal_data.rgb * 2.0 - 1.0);

			vec3 world_normal = rotate_y(baked_normal, rotation_offset);

			NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
			ROUGHNESS = impostor_roughness;
			SPECULAR = impostor_specular;

			if (debug_normals) {
				// Visualize world-space normals as RGB: R=+X, G=+Y, B=+Z
				ALBEDO = world_normal * 0.5 + 0.5;
				EMISSION = ALBEDO * 0.5;
			}
		}
	}
}
"""

#endregion


#region Job System for Async Texture Loading

func _start_texture_jobs() -> void:
	if _texture_jobs_active:
		return

	_texture_jobs_active = true
	Log.info("impostors", "NativeImpostorRenderer texture IO using WorkerThreadPool")


func _stop_texture_jobs() -> void:
	if not _texture_jobs_active and _pending_job_ids.is_empty():
		return

	for task_id: int in _pending_job_ids.values():
		if task_id >= 0:
			WorkerThreadPool.wait_for_task_completion(task_id)
	_pending_job_results_mutex.lock()
	_pending_job_results.clear()
	_pending_job_results_mutex.unlock()
	_queued_texture_jobs.clear()
	_queued_texture_job_keys.clear()
	_pending_job_ids.clear()
	_texture_jobs_active = false


func _dispatch_texture_jobs() -> void:
	if not _texture_jobs_active:
		return

	while _pending_job_ids.size() < TEXTURE_LOAD_MAX_ACTIVE_TASKS and not _queued_texture_jobs.is_empty():
		var job: Dictionary = _queued_texture_jobs.back()
		_queued_texture_jobs.pop_back()
		var job_key := String(job.get("job_key", ""))
		_queued_texture_job_keys.erase(job_key)
		if job_key.is_empty() or job_key in _pending_job_ids:
			continue
		var hash_key := String(job.get("hash_key", ""))
		var texture_path := String(job.get("path", ""))
		var is_normal := bool(job.get("is_normal", false))
		var is_res := bool(job.get("is_res", false))
		var atlas_size := int(job.get("atlas_size", DEFAULT_ATLAS_SIZE))
		var task_id := WorkerThreadPool.add_task(func() -> void:
			var image: Image = null
			if is_normal:
				image = _load_normal_image(texture_path, is_res)
			else:
				image = Image.new()
				var err := image.load(texture_path)
				if err != OK:
					image = null
			if image != null and image.get_size() != Vector2i(atlas_size, atlas_size):
				image.resize(atlas_size, atlas_size, Image.INTERPOLATE_LANCZOS)
			var result := {
				"hash_key": hash_key,
				"image": image,
				"success": image != null,
				"is_normal": is_normal,
			}
			_pending_job_results_mutex.lock()
			_pending_job_results[job_key] = result
			_pending_job_results_mutex.unlock()
		)
		if task_id >= 0:
			_pending_job_ids[job_key] = task_id
			if debug_enabled:
				_debug("Submitted async texture load task %d for key %s" % [task_id, job_key])


func _is_texture_job_queued(job_key: String) -> bool:
	return _queued_texture_job_keys.has(job_key)


func _submit_texture_load_job(hash_key: String, texture_path: String) -> void:
	if not _texture_jobs_active:
		return

	var job_key := hash_key
	if job_key in _pending_job_ids or _is_texture_job_queued(job_key):
		return
	_queued_texture_jobs.append({
		"job_key": job_key,
		"hash_key": hash_key,
		"path": texture_path,
		"is_normal": false,
		"is_res": false,
		"atlas_size": _hash_to_atlas_size.get(hash_key, DEFAULT_ATLAS_SIZE),
	})
	_queued_texture_job_keys[job_key] = true
	_dispatch_texture_jobs()


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
		_drop_pending_impostor_hash(hash_key)


## Submit async job to load a normal texture.
## `is_res` selects between async PNG decode (Image.load) and Godot
## ResourceLoader (.res ImageTexture for v6 bakes). ResourceLoader IS
## thread-safe in Godot 4.6 for runtime resource files outside res://.
func _submit_normal_load_job(hash_key: String, normal_path: String, is_res: bool = false) -> void:
	if not _texture_jobs_active:
		return

	var normal_job_key := hash_key + "_normal"
	if normal_job_key in _pending_job_ids or _is_texture_job_queued(normal_job_key):
		return  # Already loading

	_queued_texture_jobs.append({
		"job_key": normal_job_key,
		"hash_key": hash_key,
		"path": normal_path,
		"is_normal": true,
		"is_res": is_res,
		"atlas_size": _hash_to_atlas_size.get(hash_key, DEFAULT_ATLAS_SIZE),
	})
	_queued_texture_job_keys[normal_job_key] = true
	_dispatch_texture_jobs()


## Synchronous normal texture loading fallback.
func _load_normal_sync(hash_key: String, normal_path: String, is_res: bool = false) -> void:
	var image := _load_normal_image(normal_path, is_res)
	if image:
		_on_normal_loaded(hash_key, image)
	else:
		if debug_enabled:
			_debug("Failed to load normal texture: %s" % normal_path)
		_drop_pending_impostor_hash(hash_key)


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
	var atlas_size: int = _hash_to_atlas_size.get(hash_key, DEFAULT_ATLAS_SIZE)
	var bucket := _get_or_assign_bucket_for_hash(hash_key, atlas_size)
	if bucket == null:
		_drop_pending_impostor_hash(hash_key)
		return
	# Resize to standard size (256×256 matches albedo array resolution)
	var img_copy := image
	if img_copy.get_size() != Vector2i(bucket.atlas_size, bucket.atlas_size):
		img_copy = image.duplicate() as Image
		img_copy.resize(bucket.atlas_size, bucket.atlas_size, Image.INTERPOLATE_LANCZOS)

	_impostor_normal_images[hash_key] = img_copy

	# Add to normal texture array
	var normal_index := _add_to_normal_array(hash_key, img_copy, bucket)

	# Update existing impostors that use this hash via reverse index
	if hash_key in _hash_to_impostor_ids:
		var dirty_pages: Dictionary[String, bool] = {}
		for id: int in _hash_to_impostor_ids[hash_key]:
			var imp: ImpostorData = _impostors.get(id)
			if imp:
				imp.normal_texture_index = normal_index
				dirty_pages[imp.page_key] = true
		for page_key: String in dirty_pages.keys():
			_mark_page_dirty(page_key)
	if debug_enabled:
		_debug("Normal texture loaded for hash %s, index %d" % [hash_key, normal_index])

	if hash_key in _impostor_textures:
		_queue_ready_texture_hash(hash_key)


## Add image to normal texture array
func _add_to_normal_array(hash_key: String, image: Image, bucket: TextureBucket) -> int:
	if bucket == null:
		return -1
	if hash_key in bucket.normal_index_map:
		return bucket.normal_index_map[hash_key]

	var index := bucket.all_normal_images.size()
	bucket.normal_index_map[hash_key] = index
	bucket.all_normal_images.append(image)
	bucket.normal_array_dirty = true
	_last_texture_add_time = Time.get_ticks_msec() / 1000.0
	return index


#endregion


#region Main Update

## Track when we last ran compaction (avoid running every frame)
var _last_compaction_time: float = 0.0
const COMPACTION_INTERVAL: float = 5.0  # Run compaction check every 5 seconds
const COMPACTION_THRESHOLD: float = 0.75  # Compact when 75% full

func _process(delta: float) -> void:
	process_publication_slice(delta)


func process_publication_slice(delta: float, deadline_usec: int = 0) -> void:
	# Dual-purpose SubsystemToggles gate: when `impostors` is toggled off,
	# stop the whole per-frame streaming pipeline. Existing MultiMesh already
	# hidden by `.visible = false`. This early-return kills ingress work.
	if not _streaming_enabled:
		return
	if deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec:
		return

	_texture_array_committed_this_frame = false

	# Poll for completed texture loads
	_poll_job_results(deadline_usec)
	if deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec:
		return
	_process_ready_impostor_creates(deadline_usec)
	if deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec:
		return

	# Phase 6 (2026-04-17): poll async texture-array rebuild. No-op when no
	# task is in flight. When the worker completes, finalises the rebuild
	# on this frame (main-thread create_from_images + shader param swap).
	_poll_rebuild_task(deadline_usec)
	if deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec:
		return

	_process_pending_area_update(deadline_usec)
	if deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec:
		return

	# Process deferred impostor cell loading (progressive to avoid freezing)
	_process_pending_impostor_cells(deadline_usec)
	if deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec:
		return

	# Periodic compaction to prevent texture array from filling up
	var current_time := Time.get_ticks_msec() / 1000.0
	if current_time - _last_compaction_time >= COMPACTION_INTERVAL:
		_last_compaction_time = current_time
		# Check if we're above the compaction threshold
		var total_before := _get_total_texture_layers()
		if total_before > MAX_TEXTURE_ARRAY_LAYERS * COMPACTION_THRESHOLD:
			_compact_texture_array()
			var total_after := _get_total_texture_layers()
			if total_after < total_before:
				if debug_enabled:
					_debug("Periodic compaction freed %d texture slots (%d -> %d)" % [
						total_before - total_after, total_before, total_after])

	# Rebuild texture arrays if needed (batched to avoid rebuilding every frame)
	if _any_bucket_dirty():
		var time_since_add := current_time - _last_texture_add_time
		var time_since_rebuild := current_time - _last_texture_array_rebuild_time
		var pending_cells_done := _pending_cell_index >= _pending_impostor_cells.size() and not _has_resume
		var should_rebuild := false
		if pending_cells_done:
			should_rebuild = time_since_add >= TEXTURE_ARRAY_REBUILD_DELAY and time_since_rebuild >= TEXTURE_ARRAY_REBUILD_DELAY
		else:
			should_rebuild = time_since_rebuild >= STARTUP_TEXTURE_REBUILD_INTERVAL
		if should_rebuild:
			if deadline_usec <= 0 or Time.get_ticks_usec() < deadline_usec:
				_rebuild_texture_array()
			_last_texture_array_rebuild_time = current_time

	var texture_publish_ready := _any_bucket_ready()
	if texture_publish_ready:
		if _texture_array_committed_this_frame:
			_stats["far_rebuild_deferred_pending"] = int(_stats.get("far_rebuild_deferred_pending", 0)) + 1
		else:
			_process_dirty_page_rebuilds(deadline_usec)
	elif _impostors_dirty:
		_stats["far_rebuild_deferred_pending"] = int(_stats.get("far_rebuild_deferred_pending", 0)) + 1

	# Periodic benchmark stats
	_benchmark_timer += delta
	if _benchmark_timer >= BENCHMARK_LOG_INTERVAL:
		_benchmark_timer = 0.0
		var pending_count: int = maxi(0, _pending_impostor_cells.size() - _pending_cell_index)
		Log.info("impostors", "Benchmark: %d impostors, %d tex layers, %d pending cells, mm_instances=%d" % [
			_impostors.size(), _get_total_texture_layers(), pending_count,
			_get_uploaded_instance_count()])


## Process pending impostor cells progressively (time-budgeted with intra-cell resume)
func _process_pending_impostor_cells(deadline_usec: int = 0) -> void:
	if _pending_cell_index >= _pending_impostor_cells.size() and not _has_resume:
		return

	var start_usec := Time.get_ticks_usec()
	if deadline_usec <= 0:
		deadline_usec = start_usec + int(_impostor_load_budget_usec)
	else:
		deadline_usec = mini(deadline_usec, start_usec + int(_impostor_load_budget_usec))
	if Time.get_ticks_usec() >= deadline_usec:
		return
	var cells_processed := 0

	if _has_resume and not _loaded_impostor_cells.has(_resume_cell_grid):
		_has_resume = false
		_resume_ref_index = 0
		_resume_cell_grid = Vector2i.ZERO

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
			_record_cell_scan_stats(elapsed_usec, cells_processed)
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
		_pending_impostor_cell_set.erase(grid)
		if not _loaded_impostor_cells.has(grid):
			continue

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
		_pending_impostor_cell_set.clear()
		_pending_cell_index = 0
		# Queue finished — log screen-size histogram once
		_log_screen_size_histogram()
	elif _pending_cell_index > 100 and not _has_resume:
		_pending_impostor_cells = _pending_impostor_cells.slice(_pending_cell_index)
		_pending_cell_index = 0

	var elapsed_usec := Time.get_ticks_usec() - start_usec
	_record_cell_scan_stats(elapsed_usec, cells_processed)

	if cells_processed > 0:
		Log.debug("impostors", "Processed %d cells in %.2f ms, %d remaining" % [
			cells_processed, elapsed_usec / 1000.0,
			_pending_impostor_cells.size() - _pending_cell_index])


func _poll_job_results(deadline_usec: int = 0) -> void:
	if not _texture_jobs_active:
		return

	var start_usec := Time.get_ticks_usec()
	var processed := 0
	while processed < JOB_RESULT_POLL_MAX_PER_FRAME:
		var now_usec := Time.get_ticks_usec()
		if deadline_usec > 0 and now_usec >= deadline_usec:
			break
		if now_usec - start_usec >= JOB_RESULT_POLL_BUDGET_USEC:
			break

		var completed_key := ""
		var completed_task_id := -1
		for job_key: String in _pending_job_ids.keys():
			var task_id := int(_pending_job_ids[job_key])
			if WorkerThreadPool.is_task_completed(task_id):
				completed_key = job_key
				completed_task_id = task_id
				break
		if completed_key.is_empty():
			break

		WorkerThreadPool.wait_for_task_completion(completed_task_id)
		_pending_job_ids.erase(completed_key)

		_pending_job_results_mutex.lock()
		var data: Dictionary = _pending_job_results.get(completed_key, {})
		_pending_job_results.erase(completed_key)
		_pending_job_results_mutex.unlock()
		if data.is_empty():
			processed += 1
			continue

		var hash_key: String = data.get("hash_key", "")
		var image: Image = data.get("image")
		var is_normal := bool(data.get("is_normal", false))

		if not hash_key.is_empty():
			var job_key := hash_key + "_normal" if is_normal else hash_key
			_pending_job_ids.erase(job_key)

		if not data.get("success", false):
			if not hash_key.is_empty():
				_drop_pending_impostor_hash(hash_key)
			processed += 1
			continue

		if hash_key.is_empty() or image == null:
			processed += 1
			continue

		# Route to correct handler based on whether this is a normal texture
		if is_normal:
			_on_normal_loaded(hash_key, image)
		else:
			_on_texture_loaded(hash_key, image)

		processed += 1

	if deadline_usec <= 0 or Time.get_ticks_usec() < deadline_usec:
		_dispatch_texture_jobs()

	var elapsed_usec := Time.get_ticks_usec() - start_usec
	var elapsed_ms := float(elapsed_usec) / 1000.0
	_stats["far_job_poll_us"] = elapsed_usec
	_stats["far_job_results_handled"] = processed
	_stats["job_results_processed_last_frame"] = processed
	_stats["job_result_poll_last_ms"] = elapsed_ms
	_stats["job_result_poll_max_ms"] = maxf(float(_stats.get("job_result_poll_max_ms", 0.0)), elapsed_ms)


func _queue_impostor_cells(cells: Array[Vector2i]) -> void:
	for cell: Vector2i in cells:
		if _pending_impostor_cell_set.has(cell):
			continue
		_pending_impostor_cells.append(cell)
		_pending_impostor_cell_set[cell] = true


func _queue_ready_texture_hash(hash_key: String) -> void:
	if _ready_texture_hash_set.has(hash_key):
		return
	_ready_texture_hashes.append(hash_key)
	_ready_texture_hash_set[hash_key] = true


func _drop_pending_impostor_hash(hash_key: String) -> void:
	var bucket_key: String = _hash_to_bucket_key.get(hash_key, "")
	_pending_impostors.erase(hash_key)
	_ready_texture_hashes.erase(hash_key)
	_ready_texture_hash_set.erase(hash_key)
	_impostor_textures.erase(hash_key)
	_impostor_normal_images.erase(hash_key)
	_hash_to_atlas_size.erase(hash_key)
	_hash_to_bucket_key.erase(hash_key)
	if not bucket_key.is_empty():
		_compact_texture_array(bucket_key)


func _get_total_texture_layers() -> int:
	var total := 0
	for bucket: TextureBucket in _texture_buckets.values():
		total += bucket.all_array_images.size()
	return total


func _any_bucket_dirty() -> bool:
	for bucket: TextureBucket in _texture_buckets.values():
		if bucket.texture_array_dirty or bucket.normal_array_dirty:
			return true
	return false


func _any_bucket_ready() -> bool:
	for bucket: TextureBucket in _texture_buckets.values():
		if bucket.committed_texture_array_layers > 0:
			return true
	return false


func _get_dirty_rebuild_bucket() -> TextureBucket:
	var dirty_buckets: Array[TextureBucket] = []
	var pending_cells_done := _pending_cell_index >= _pending_impostor_cells.size() and not _has_resume
	for bucket: TextureBucket in _texture_buckets.values():
		if bucket.texture_array_dirty or (pending_cells_done and bucket.normal_array_dirty):
			dirty_buckets.append(bucket)
	if dirty_buckets.is_empty():
		return null
	_next_rebuild_bucket_index = _next_rebuild_bucket_index % dirty_buckets.size()
	var selected := dirty_buckets[_next_rebuild_bucket_index]
	_next_rebuild_bucket_index = (_next_rebuild_bucket_index + 1) % dirty_buckets.size()
	return selected


func _process_ready_impostor_creates(deadline_usec: int = 0) -> void:
	if _ready_texture_hashes.is_empty():
		_stats["far_ready_create_us"] = 0
		_stats["far_ready_created"] = 0
		return

	var start_usec := Time.get_ticks_usec()
	var created := 0
	while not _ready_texture_hashes.is_empty() and created < READY_IMPOSTOR_CREATE_MAX_PER_FRAME:
		var now_usec := Time.get_ticks_usec()
		if deadline_usec > 0 and now_usec >= deadline_usec:
			break
		if created > 0 and (created & 15) == 0 and now_usec - start_usec >= READY_IMPOSTOR_CREATE_BUDGET_USEC:
			break

		var hash_key := _ready_texture_hashes[0]
		if hash_key not in _pending_impostors or (_pending_impostors[hash_key] as Array).is_empty():
			_ready_texture_hashes.remove_at(0)
			_ready_texture_hash_set.erase(hash_key)
			_pending_impostors.erase(hash_key)
			continue

		var pending_list: Array = _pending_impostors[hash_key]
		var pending: PendingImpostor = pending_list.pop_back()
		var bucket := _get_bucket_for_hash(hash_key)
		if bucket == null:
			_drop_pending_impostor_hash(hash_key)
			continue
		var imp_id := _create_impostor(
			pending.model_path,
			pending.cell_grid,
			pending.ref_id,
			pending.ref_num,
			pending.source_object_id,
			hash_key,
			bucket,
			pending.position,
			pending.rotation,
			pending.scale,
			pending.texture_size,
			pending.aabb_center
		)
		if imp_id >= 0 and imp_id in _impostors:
			var normal_idx: int = bucket.normal_index_map.get(hash_key, -1)
			if normal_idx >= 0:
				_impostors[imp_id].normal_texture_index = normal_idx
			(_impostors[imp_id] as ImpostorData).variant_flag = pending.variant_flag
		created += 1

		if pending_list.is_empty():
			_pending_impostors.erase(hash_key)
			_ready_texture_hashes.remove_at(0)
			_ready_texture_hash_set.erase(hash_key)

	var elapsed_usec := Time.get_ticks_usec() - start_usec
	_stats["far_ready_create_us"] = elapsed_usec
	_stats["far_ready_created"] = created


func _spatial_page_key_for_cell(cell_grid: Vector2i) -> Vector2i:
	return Vector2i(
		floori(float(cell_grid.x) / float(IMPOSTOR_PAGE_SIZE_CELLS)),
		floori(float(cell_grid.y) / float(IMPOSTOR_PAGE_SIZE_CELLS))
	)


func _page_key_for_cell(cell_grid: Vector2i, bucket: TextureBucket) -> String:
	var spatial_key := _spatial_page_key_for_cell(cell_grid)
	return "%d,%d,%s" % [spatial_key.x, spatial_key.y, bucket.key]


func _page_center_for_key(spatial_key: Vector2i) -> Vector3:
	var origin_x := spatial_key.x * IMPOSTOR_PAGE_SIZE_CELLS
	var origin_y := spatial_key.y * IMPOSTOR_PAGE_SIZE_CELLS
	var center_x := (float(origin_x) + float(IMPOSTOR_PAGE_SIZE_CELLS) * 0.5) * DU.CELL_SIZE_METERS
	var center_z := -(float(origin_y) + float(IMPOSTOR_PAGE_SIZE_CELLS) * 0.5) * DU.CELL_SIZE_METERS
	return Vector3(center_x, 0.0, center_z)


func _get_or_create_page(page_key: String, spatial_key: Vector2i, bucket: TextureBucket) -> ImpostorPage:
	if page_key in _impostor_pages:
		return _impostor_pages[page_key]
	if bucket == null:
		return null

	if _page_container == null:
		_page_container = Node3D.new()
		_page_container.name = "ImpostorPages"
		add_child(_page_container)

	var page := ImpostorPage.new()
	page.key = page_key
	page.spatial_key = spatial_key
	page.bucket_key = bucket.key
	page.atlas_size = bucket.atlas_size
	page.slab_index = bucket.slab_index
	page.center = _page_center_for_key(spatial_key)
	page.multimesh = MultiMesh.new()
	page.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	page.multimesh.use_custom_data = true
	page.multimesh.mesh = _quad_mesh

	page.instance = MultiMeshInstance3D.new()
	page.instance.name = "ImpostorPage_%d_%d_%d_%d" % [spatial_key.x, spatial_key.y, page.atlas_size, page.slab_index]
	page.instance.position = page.center
	page.instance.multimesh = page.multimesh
	page.instance.material_override = bucket.material
	page.instance.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	page.instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	page.visibility_begin_distance = _page_visibility_begin_distance(page)
	_configure_page_visibility(page.instance, page.visibility_begin_distance)
	_page_container.add_child(page.instance)

	_impostor_pages[page_key] = page
	_stats["far_page_count"] = _impostor_pages.size()
	return page


func _configure_page_visibility(instance: MultiMeshInstance3D, begin_distance: float = -1.0) -> void:
	if begin_distance < 0.0:
		begin_distance = _visibility_begin_distance
	instance.visibility_range_begin = begin_distance - _visibility_fade_margin
	instance.visibility_range_begin_margin = _visibility_fade_margin
	instance.visibility_range_end = _visibility_end_distance
	instance.visibility_range_end_margin = DU.FADE_MARGIN_RENDER_FAR
	instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF


func _apply_visibility_ranges_to_pages() -> void:
	for page: ImpostorPage in _impostor_pages.values():
		page.visibility_begin_distance = _page_visibility_begin_distance(page)
		_configure_page_visibility(page.instance, page.visibility_begin_distance)
	_apply_material_visibility_params(_visibility_begin_distance, _visibility_fade_margin)


func _apply_material_visibility_params(begin_distance: float, fade_margin: float) -> void:
	for material: ShaderMaterial in _billboard_materials.values():
		material.set_shader_parameter("fade_distance", begin_distance)
		material.set_shader_parameter("fade_margin", fade_margin)


func _page_visibility_begin_distance(page: ImpostorPage) -> float:
	if page == null or page.impostor_ids.is_empty() or _hlod_covered_object_ids.is_empty():
		return _visibility_begin_distance
	for id: int in page.impostor_ids:
		var imp: ImpostorData = _impostors.get(id)
		var object_id := imp.source_object_id if imp != null else &""
		if imp == null or object_id == &"" or not _hlod_covered_object_ids.has(object_id):
			return _visibility_begin_distance
	return DU.HLOD_END


func _mark_page_dirty(page_key: String) -> void:
	if _dirty_page_set.has(page_key):
		return
	_dirty_page_keys.append(page_key)
	_dirty_page_set[page_key] = true
	_impostors_dirty = true


func _mark_all_pages_dirty() -> void:
	for page_key: String in _impostor_pages.keys():
		_mark_page_dirty(page_key)


func _free_page(page_key: String) -> void:
	if page_key not in _impostor_pages:
		return
	var page: ImpostorPage = _impostor_pages[page_key]
	if page.instance:
		var parent := page.instance.get_parent()
		page.instance.visible = false
		page.instance.material_override = null
		page.instance.multimesh = null
		if parent:
			parent.remove_child(page.instance)
		page.instance.free()
	if page.multimesh:
		page.multimesh.instance_count = 0
		page.multimesh.mesh = null
	_impostor_pages.erase(page_key)
	_dirty_page_keys.erase(page_key)
	_dirty_page_set.erase(page_key)
	_stats["far_page_count"] = _impostor_pages.size()


func _clear_pages(free_nodes: bool = true) -> void:
	var keys: Array = _impostor_pages.keys()
	for page_key: String in keys:
		if free_nodes:
			_free_page(page_key)
		else:
			var page: ImpostorPage = _impostor_pages[page_key]
			if page.multimesh:
				page.multimesh.instance_count = 0
			page.impostor_ids.clear()
	if free_nodes:
		_impostor_pages.clear()
	_dirty_page_keys.clear()
	_dirty_page_set.clear()
	_stats["far_page_count"] = _impostor_pages.size()


func _get_uploaded_instance_count() -> int:
	var count := 0
	for page: ImpostorPage in _impostor_pages.values():
		if page.multimesh:
			count += page.multimesh.instance_count
	return count


func _get_visible_page_count() -> int:
	var count := 0
	for page: ImpostorPage in _impostor_pages.values():
		if page.instance and page.instance.visible:
			count += 1
	return count


func _process_dirty_page_rebuilds(deadline_usec: int = 0) -> void:
	if _dirty_page_keys.is_empty():
		_stats["far_pages_rebuilt"] = 0
		_stats["far_multimesh_pack_us"] = 0
		_stats["far_multimesh_upload_us"] = 0
		_impostors_dirty = false
		return

	var start_usec := Time.get_ticks_usec()
	var rebuilt := 0
	var processed := 0
	var pack_usec := 0
	var upload_usec := 0
	var uploaded_instances := 0

	while not _dirty_page_keys.is_empty() and processed < IMPOSTOR_PAGE_REBUILD_MAX_PER_FRAME:
		var now_usec := Time.get_ticks_usec()
		if deadline_usec > 0 and now_usec >= deadline_usec:
			break
		if processed > 0 and now_usec - start_usec >= IMPOSTOR_PAGE_REBUILD_BUDGET_USEC:
			break
		var page_key: String = _dirty_page_keys.pop_back()
		_dirty_page_set.erase(page_key)
		processed += 1
		var result: Dictionary = _rebuild_page(page_key)
		rebuilt += int(result.get("rebuilt", 0))
		pack_usec += int(result.get("pack_usec", 0))
		upload_usec += int(result.get("upload_usec", 0))
		uploaded_instances += int(result.get("instances", 0))

	_stats["far_pages_rebuilt"] = rebuilt
	_stats["far_multimesh_pack_us"] = pack_usec
	_stats["far_multimesh_upload_us"] = upload_usec
	_stats["far_uploaded_instances"] = uploaded_instances
	_stats["multimesh_rebuild_count"] = int(_stats.get("multimesh_rebuild_count", 0)) + rebuilt
	_stats["multimesh_rebuild_last_ms"] = float(Time.get_ticks_usec() - start_usec) / 1000.0
	_stats["multimesh_rebuild_max_ms"] = maxf(float(_stats.get("multimesh_rebuild_max_ms", 0.0)), float(Time.get_ticks_usec() - start_usec) / 1000.0)
	_impostors_dirty = not _dirty_page_keys.is_empty()

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
	world_scale: Vector3 = Vector3.ONE,
	ref_id: String = "",
	ref_num: int = 0,
	source_object_id: StringName = &""
) -> int:
	# Check if this model should have an impostor
	if impostor_candidates and not impostor_candidates.should_have_impostor(model_path):
		_stats["skipped_not_candidate"] += 1
		return -1

	# Resolve which bake version to use. Runtime is intentionally strict:
	# v6 octahedral bakes are the only accepted impostors. Older bakes are
	# visually stale enough that drawing nothing is safer
	# than drawing the wrong surrogate.
	var v6_albedo_path := ImpostorCandidatesScript.get_impostor_texture_path_v6(model_path)
	var normal_path := ImpostorCandidatesScript.get_impostor_normal_res_path_v6(model_path)
	if not _cached_file_exists(v6_albedo_path) or not _cached_file_exists(normal_path):
		_stats["skipped_no_texture"] += 1
		return -1

	var hash_key: String = ImpostorCandidatesScript.get_hash_key(model_path)

	# Get v6 metadata for size + variant flag. Missing metadata previously
	# defaulted to a 10x10 billboard, which is exactly the kind of scale bug we
	# should fail closed on.
	var metadata := _get_or_load_metadata(model_path)
	if metadata.is_empty():
		_stats["skipped_no_texture"] += 1
		return -1

	var impostor_size := Vector2(10.0, 10.0)
	var aabb_center := Vector3.ZERO
	var variant_flag: float = 1.0  # 1 = v6 hemi octahedral

	var bounds: Dictionary = metadata.get("bounds", {})
	if bounds.is_empty():
		_stats["skipped_no_texture"] += 1
		return -1

	var capture_size := float(bounds.get("capture_size", 0.0))
	if capture_size > 0.0:
		impostor_size = Vector2(capture_size, capture_size)
	else:
		impostor_size.x = bounds.get("width", 0.0)
		impostor_size.y = bounds.get("height", 0.0)
	if impostor_size.x <= 0.0 or impostor_size.y <= 0.0:
		_stats["skipped_no_texture"] += 1
		return -1

	var center_arr: Variant = bounds.get("center", [])
	if center_arr is Array and (center_arr as Array).size() >= 3:
		var center_values := center_arr as Array
		aabb_center = Vector3(
			float(center_values[0]),
			float(center_values[1]),
			float(center_values[2])
		)

	var bake_version: int = int(metadata.get("version", metadata.get("bake_version", 0)))
	if bake_version < 6:
		_stats["skipped_no_texture"] += 1
		return -1

	var projection: String = str(metadata.get("projection", "hemi"))
	variant_flag = 2.0 if projection == "sphere" else 1.0
	var atlas_size := _resolve_runtime_atlas_size(metadata)
	if not _is_supported_atlas_size(atlas_size):
		_stats["skipped_no_texture"] += 1
		return -1
	_hash_to_atlas_size[hash_key] = atlas_size

	# Create pending impostor data FIRST (before texture load which may be
	# sync). Publication is always frame-budgeted, even when the texture is
	# already cached, so popular texture hashes cannot create thousands of
	# impostors in one scan or job-poll frame.
	var pending := PendingImpostor.new()
	pending.model_path = model_path
	pending.cell_grid = cell_grid
	pending.atlas_size = atlas_size
	pending.ref_id = ref_id
	pending.ref_num = ref_num
	pending.source_object_id = source_object_id
	pending.position = world_position
	pending.rotation = world_rotation
	pending.scale = world_scale
	pending.texture_size = impostor_size
	pending.aabb_center = aabb_center
	pending.variant_flag = variant_flag

	if hash_key in _impostor_textures:
		if hash_key not in _pending_impostors:
			_pending_impostors[hash_key] = []
		(_pending_impostors[hash_key] as Array).append(pending)
		var cached_bucket := _get_or_assign_bucket_for_hash(hash_key, atlas_size)
		if cached_bucket != null and hash_key in cached_bucket.normal_index_map:
			_queue_ready_texture_hash(hash_key)
		return -1

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
			_debug("=== Impostor Texture Loading (v6 strict) ===")
			_debug("  Model path (input): %s" % model_path)
			_debug("  Normalized path: %s" % normalized)
			_debug("  Hash key: %s" % hash_key)
			_debug("  Texture path: %s" % v6_albedo_path)
			_debug("  Normal path: %s" % normal_path)

		# Try async loading first
		if _texture_jobs_active:
			_submit_texture_load_job(hash_key, v6_albedo_path)
			_submit_normal_load_job(hash_key, normal_path, true)
		else:
			# Fallback to synchronous loading if job system failed
			_load_texture_sync(hash_key, v6_albedo_path)
			_load_normal_sync(hash_key, normal_path, true)

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
		_mark_page_dirty(imp.page_key)


## Clear all impostors. Runtime toggles reseed the default bucket so the node can
## be reused; shutdown must not allocate fresh render resources after teardown.
func clear(reseed_default_bucket: bool = true) -> void:
	var restart_texture_jobs := _texture_jobs_active and not _fast_cleanup_done
	_stop_texture_jobs()
	_impostors.clear()
	_cell_index.clear()
	_texture_ref_counts.clear()
	_hash_to_impostor_ids.clear()
	_loaded_impostor_cells.clear()
	_file_exists_cache.clear()
	_impostor_textures.clear()
	_impostor_normal_images.clear()
	_hash_to_atlas_size.clear()
	_hash_to_bucket_key.clear()
	_texture_buckets.clear()
	_billboard_materials.clear()
	if reseed_default_bucket and _billboard_shader != null:
		_get_or_create_bucket(DEFAULT_ATLAS_SIZE, 0)
	_ref_id_to_model.clear()
	_pending_impostor_cells.clear()
	_pending_impostor_cell_set.clear()
	_pending_cell_index = 0
	_pending_impostors.clear()
	_hlod_covered_object_ids.clear()
	_ready_texture_hashes.clear()
	_ready_texture_hash_set.clear()
	_pending_job_ids.clear()
	_pending_job_results_mutex.lock()
	_pending_job_results.clear()
	_pending_job_results_mutex.unlock()
	_has_resume = false
	_resume_cell_grid = Vector2i.ZERO
	_resume_ref_index = 0
	_last_center_cell = Vector2i.ZERO
	_prev_impostor_center = Vector2i(999999, 999999)
	_prev_impostor_radius = -1
	_initial_pending_count = 0
	_stats["total_impostors"] = 0
	_impostors_dirty = false
	_clear_pages(true)
	_reset_runtime_stats()
	if restart_texture_jobs:
		_start_texture_jobs()


func _reset_runtime_stats() -> void:
	for key: String in [
		"texture_cache_size",
		"texture_array_layers",
		"pending_loads",
		"far_cell_scan_us",
		"far_cells_processed_last_frame",
		"far_job_poll_us",
		"far_job_results_handled",
		"far_ready_create_us",
		"far_ready_created",
		"far_texture_upload_us",
		"far_normal_upload_us",
		"far_texture_upload_us_512",
		"far_normal_upload_us_512",
		"far_texture_upload_us_1024",
		"far_normal_upload_us_1024",
		"far_multimesh_pack_us",
		"far_multimesh_upload_us",
		"far_uploaded_instances",
		"far_page_count",
		"far_dirty_page_count",
		"far_pages_rebuilt",
		"far_visible_page_count",
		"far_rebuild_deferred_pending",
		"job_results_processed_last_frame",
		"job_result_poll_last_ms",
		"job_result_poll_max_ms",
		"texture_array_rebuild_count",
		"texture_array_upload_last_ms",
		"texture_array_upload_max_ms",
		"multimesh_rebuild_count",
		"multimesh_rebuild_last_ms",
		"multimesh_rebuild_max_ms",
	]:
		_stats[key] = 0


## Get statistics
func get_stats() -> Dictionary:
	var s := _stats.duplicate()
	# Add dynamic stats
	s["multimesh_instance_count"] = _get_uploaded_instance_count()
	s["far_uploaded_instances"] = _get_uploaded_instance_count()
	s["far_page_count"] = _impostor_pages.size()
	s["far_dirty_page_count"] = _dirty_page_keys.size()
	s["far_visible_page_count"] = _get_visible_page_count()
	s["loaded_impostor_cells"] = _loaded_impostor_cells.size()
	s["pending_texture_loads"] = _pending_job_ids.size() + _queued_texture_jobs.size()
	s["active_texture_load_tasks"] = _pending_job_ids.size()
	s["queued_texture_load_tasks"] = _queued_texture_jobs.size()
	s["pending_impostors"] = _pending_impostors.size()
	s["pending_loads"] = get_pending_cell_count()
	s["far_texture_rebuild_in_flight"] = _rebuild_task_id != -1
	s["texture_array_layers"] = _get_total_texture_layers()
	s["far_texture_array_dirty"] = _any_bucket_dirty()
	for atlas_size: int in SUPPORTED_ATLAS_SIZES:
		var texture_layers := 0
		var committed_texture_layers := 0
		var normal_layers := 0
		var committed_normal_layers := 0
		var slab_count := 0
		for bucket: TextureBucket in _texture_buckets.values():
			if bucket.atlas_size != atlas_size:
				continue
			slab_count += 1
			texture_layers += bucket.all_array_images.size()
			committed_texture_layers += bucket.committed_texture_array_layers
			normal_layers += bucket.all_normal_images.size()
			committed_normal_layers += bucket.committed_normal_array_layers
		s["far_texture_layers_%d" % atlas_size] = texture_layers
		s["far_committed_texture_layers_%d" % atlas_size] = committed_texture_layers
		s["far_normal_layers_%d" % atlas_size] = normal_layers
		s["far_committed_normal_layers_%d" % atlas_size] = committed_normal_layers
		s["far_texture_slabs_%d" % atlas_size] = slab_count
	s["far_multimesh_dirty"] = _impostors_dirty
	s["far_enabled"] = _streaming_enabled and visible
	s["far_visibility_begin_m"] = _visibility_begin_distance
	s["far_visibility_end_m"] = _visibility_end_distance
	var hlod_page_stats := _get_hlod_page_coverage_stats()
	s["far_hlod_covered_pages"] = hlod_page_stats.get("covered_pages", 0)
	s["far_hlod_uncovered_pages"] = hlod_page_stats.get("uncovered_pages", 0)
	s["far_hlod_covered_impostors"] = hlod_page_stats.get("covered_impostors", 0)
	s["far_hlod_page_overrides"] = hlod_page_stats.get("page_overrides", 0)
	s["process_enabled"] = is_processing()
	s["has_candidates"] = impostor_candidates != null
	return s


func _get_hlod_page_coverage_stats() -> Dictionary:
	var covered_pages := 0
	var uncovered_pages := 0
	var covered_impostors := 0
	var page_overrides := 0
	for page: ImpostorPage in _impostor_pages.values():
		var is_hlod_override := _visibility_begin_distance < DU.HLOD_END \
			and is_equal_approx(page.visibility_begin_distance, DU.HLOD_END)
		if is_hlod_override:
			covered_pages += 1
			page_overrides += 1
			covered_impostors += page.impostor_ids.size()
		else:
			uncovered_pages += 1
	return {
		"covered_pages": covered_pages,
		"uncovered_pages": uncovered_pages,
		"covered_impostors": covered_impostors,
		"page_overrides": page_overrides,
	}


## Detailed diagnostic output - call this to debug rendering issues
func dump_diagnostic() -> String:
	var lines: Array[String] = []
	lines.append("=== NativeImpostorRenderer Diagnostic ===")

	# Paged MultiMesh state
	lines.append("\n[Paged MultiMesh State]")
	lines.append("  page_count: %d" % _impostor_pages.size())
	lines.append("  dirty_pages: %d" % _dirty_page_keys.size())
	lines.append("  uploaded_instances: %d" % _get_uploaded_instance_count())
	if not _impostor_pages.is_empty():
		var first_page: ImpostorPage = _impostor_pages.values()[0]
		lines.append("  first_page_key: %s" % str(first_page.key))
		lines.append("  first_page_instances: %d" % (first_page.multimesh.instance_count if first_page.multimesh else 0))
		lines.append("  first_page_aabb: %s" % str(first_page.instance.custom_aabb if first_page.instance else AABB()))

	# Material/Shader state
	lines.append("\n[Material State]")
	if _billboard_material:
		lines.append("  shader: %s" % (_billboard_material.shader != null))
		if _billboard_material.shader:
			lines.append("  shader_code_length: %d chars" % _billboard_material.shader.code.length())
		lines.append("  debug_mode: %s" % _billboard_material.get_shader_parameter("debug_mode"))
		lines.append("  fade_distance: %s" % _billboard_material.get_shader_parameter("fade_distance"))
	else:
		lines.append("  ERROR: _billboard_material is null!")

	lines.append("\n[Mesh Surface Material]")
	if _quad_mesh:
		lines.append("  mesh_type: %s" % _quad_mesh.get_class())
		lines.append("  surface_count: %d" % _quad_mesh.get_surface_count())
		if _quad_mesh.get_surface_count() > 0:
			var surface_mat: Material = _quad_mesh.surface_get_material(0)
			lines.append("  surface_0_material: %s" % (surface_mat != null))
	else:
		lines.append("  ERROR: shared quad mesh is null!")

	# Texture array state
	lines.append("\n[Texture Array State]")
	lines.append("  texture_buckets: %d" % _texture_buckets.size())
	lines.append("  texture_array_layers: %d" % _get_total_texture_layers())
	for bucket_key: String in _texture_buckets.keys():
		var bucket: TextureBucket = _texture_buckets[bucket_key]
		lines.append("  bucket %s: textures=%d normals=%d committed=%d/%d" % [
			bucket_key,
			bucket.all_array_images.size(),
			bucket.all_normal_images.size(),
			bucket.committed_texture_array_layers,
			bucket.committed_normal_array_layers
		])

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
func update_impostor_area(center_cell: Vector2i, radius: int, deadline_usec: int = 0) -> bool:
	_last_center_cell = center_cell
	# SubsystemToggles gate: when `impostors` is toggled off, refuse to queue
	# any impostor cells. `_process` already bails early on `_streaming_enabled`,
	# but the producer side needs the same gate or `_pending_impostor_cells`
	# grows unbounded as the camera moves. Matches the pattern in
	# static_object_renderer.add_instance / object_paging.update_for_camera.
	if not _streaming_enabled:
		return true
	if not impostor_candidates:
		push_warning("[NativeImpostorRenderer] update_impostor_area called but impostor_candidates is null!")
		return true

	var radius_meters := float(radius) * DU.CELL_SIZE_METERS
	var radius_sq := radius_meters * radius_meters

	# Differential update: if we moved only 1-2 cells, compute only the delta ring
	var delta := Vector2i(absi(center_cell.x - _prev_impostor_center.x), absi(center_cell.y - _prev_impostor_center.y))
	var use_differential := _prev_impostor_center != Vector2i(999999, 999999) and delta.x <= 2 and delta.y <= 2
	if not _area_update_active and center_cell == _prev_impostor_center and radius == _prev_impostor_radius:
		return true

	if not _area_update_active and use_differential and center_cell != _prev_impostor_center:
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
						if lead_grid not in _loaded_impostor_cells and not _pending_impostor_cell_set.has(lead_grid):
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
						if lead_grid not in _loaded_impostor_cells and not _pending_impostor_cell_set.has(lead_grid):
							cells_to_load.append(lead_grid)
							_loaded_impostor_cells[lead_grid] = true
					var trail_grid := Vector2i(_prev_impostor_center.x + cx, trail_y)
					if DU.cell_distance_squared(_prev_impostor_center, trail_grid) <= radius_sq:
						if trail_grid in _loaded_impostor_cells:
							cells_to_unload.append(trail_grid)

		if not cells_to_unload.is_empty():
			_unload_impostors_in_cells(cells_to_unload)

		if not cells_to_load.is_empty():
			_queue_impostor_cells(cells_to_load)

		Log.debug("impostors", "Differential: +%d -%d impostor cells (move:%s, scanned:%d)" % [
			cells_to_load.size(), cells_to_unload.size(), move,
			(absi(move.x) + absi(move.y)) * (2 * radius + 1) * 2])

	else:
		if not _area_update_active or center_cell != _area_update_center or radius != _area_update_radius:
			_begin_full_area_update(center_cell, radius, radius_sq)
		return _process_pending_area_update(deadline_usec)

	_prev_impostor_center = center_cell
	_prev_impostor_radius = radius
	return true


func _deadline_reached(deadline_usec: int) -> bool:
	return deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec


func _begin_full_area_update(center_cell: Vector2i, radius: int, radius_sq: float) -> void:
	_area_update_active = true
	_area_update_center = center_cell
	_area_update_radius = radius
	_area_update_radius_sq = radius_sq
	_area_update_dx = -radius
	_area_update_dy = -radius
	_area_update_phase = 0
	_area_update_desired_cells.clear()
	_area_update_loaded_keys.clear()
	_area_update_loaded_index = 0
	_area_update_desired_keys.clear()
	_area_update_desired_index = 0
	_area_update_new_cells = 0
	if debug_enabled:
		_debug("Full impostor recalc started: center=%s, radius=%d" % [center_cell, radius])


func _process_pending_area_update(deadline_usec: int = 0) -> bool:
	if not _area_update_active:
		return true

	while true:
		if _deadline_reached(deadline_usec):
			return false

		if _area_update_phase == 0:
			while _area_update_dy <= _area_update_radius:
				while _area_update_dx <= _area_update_radius:
					if _deadline_reached(deadline_usec):
						return false
					var grid := Vector2i(_area_update_center.x + _area_update_dx, _area_update_center.y + _area_update_dy)
					if DU.cell_distance_squared(_area_update_center, grid) <= _area_update_radius_sq:
						_area_update_desired_cells[grid] = true
					_area_update_dx += 1
				_area_update_dx = -_area_update_radius
				_area_update_dy += 1
			_area_update_loaded_keys = [] as Array[Vector2i]
			for grid: Vector2i in _loaded_impostor_cells:
				_area_update_loaded_keys.append(grid)
			_area_update_phase = 1

		elif _area_update_phase == 1:
			var unload_batch: Array[Vector2i] = []
			while _area_update_loaded_index < _area_update_loaded_keys.size():
				if _deadline_reached(deadline_usec):
					if not unload_batch.is_empty():
						_unload_impostors_in_cells(unload_batch)
					return false
				var loaded_grid: Vector2i = _area_update_loaded_keys[_area_update_loaded_index]
				_area_update_loaded_index += 1
				if loaded_grid not in _area_update_desired_cells:
					unload_batch.append(loaded_grid)
				if unload_batch.size() >= 64:
					_unload_impostors_in_cells(unload_batch)
					unload_batch.clear()
			if not unload_batch.is_empty():
				_unload_impostors_in_cells(unload_batch)
			_area_update_dx = -_area_update_radius
			_area_update_dy = -_area_update_radius
			_area_update_phase = 2

		elif _area_update_phase == 2:
			while _area_update_dy <= _area_update_radius:
				while _area_update_dx <= _area_update_radius:
					if _deadline_reached(deadline_usec):
						return false
					var desired_grid := Vector2i(_area_update_center.x + _area_update_dx, _area_update_center.y + _area_update_dy)
					_area_update_dx += 1
					if DU.cell_distance_squared(_area_update_center, desired_grid) > _area_update_radius_sq:
						continue
					if desired_grid in _loaded_impostor_cells or _pending_impostor_cell_set.has(desired_grid):
						continue
					_pending_impostor_cells.append(desired_grid)
					_pending_impostor_cell_set[desired_grid] = true
					_loaded_impostor_cells[desired_grid] = true
					_area_update_new_cells += 1
				_area_update_dx = -_area_update_radius
				_area_update_dy += 1
			if _initial_pending_count == 0:
				_initial_pending_count = _pending_impostor_cells.size()
			if _area_update_new_cells > 0:
				Log.info("impostors", "Queued %d impostor cells for deferred loading (total pending: %d)" % [
					_area_update_new_cells, _pending_impostor_cells.size()])
			_prev_impostor_center = _area_update_center
			_prev_impostor_radius = _area_update_radius
			_area_update_active = false
			_area_update_desired_cells.clear()
			_area_update_loaded_keys.clear()
			_area_update_desired_keys.clear()
			return true

		else:
			_area_update_active = false
			return true
	return false


## Unload impostors belonging to specific cells
func _unload_impostors_in_cells(grids: Array[Vector2i]) -> void:
	for g: Vector2i in grids:
		_loaded_impostor_cells.erase(g)
		_pending_impostor_cell_set.erase(g)
	_discard_pending_impostor_cells(grids)

	# Use spatial index for O(cell_count) lookup instead of O(total_impostors)
	var ids_to_remove: Array[int] = []
	var dirty_pages: Dictionary[String, bool] = {}
	for grid: Vector2i in grids:
		if grid not in _cell_index:
			continue
		for id: int in _cell_index[grid]:
			var imp: ImpostorData = _impostors.get(id)
			if imp:
				ids_to_remove.append(id)
				dirty_pages[imp.page_key] = true
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
		for page_key: String in dirty_pages.keys():
			_mark_page_dirty(page_key)

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


func _discard_pending_impostor_cells(grids: Array[Vector2i]) -> void:
	if grids.is_empty() or (_pending_impostor_cells.is_empty() and not _has_resume):
		return
	var drop_set: Dictionary[Vector2i, bool] = {}
	for grid: Vector2i in grids:
		drop_set[grid] = true
	if _has_resume and drop_set.has(_resume_cell_grid):
		_has_resume = false
		_resume_ref_index = 0
		_resume_cell_grid = Vector2i.ZERO
	if _pending_impostor_cells.is_empty():
		return
	var old_index := _pending_cell_index
	var compacted: Array[Vector2i] = []
	var compacted_index := 0
	for i in range(_pending_impostor_cells.size()):
		var grid: Vector2i = _pending_impostor_cells[i]
		if drop_set.has(grid):
			continue
		if i < old_index:
			compacted_index += 1
		compacted.append(grid)
	_pending_impostor_cells = compacted
	_pending_cell_index = mini(compacted_index, _pending_impostor_cells.size())


## Internal helper to load impostors from ESM record
## Load impostors from a cell record with intra-cell budget checking.
## Returns -1 if the cell was fully processed, or the reference index to resume from
## if the budget was exceeded mid-cell.
func _load_impostors_from_cell_record_budgeted(grid: Vector2i, start_ref: int, deadline_usec: int) -> int:
	if _world_object_source == null:
		Log.error("impostors", "WorldObjectSource not available!")
		return -1

	var refs: Array = _world_object_source.get_objects_in_cell(grid, WorldObjectRecordScript.CAP_IMPOSTOR)
	if refs.is_empty():
		if abs(grid.x) < 30 and abs(grid.y) < 30:
			_debug("No impostor-capable objects for grid %s" % grid)
		return -1

	var ref_count := refs.size()
	var impostor_count := 0
	var model_count := 0
	var i := start_ref
	while i < ref_count:
		if Time.get_ticks_usec() >= deadline_usec:
			return i

		var record: RefCounted = refs[i]
		i += 1
		var ref_id_str: String = str(record.source_ref_id)
		var model_path: String = record.model_path
		if model_path.is_empty():
			continue

		model_count += 1
		var should_create_impostor := impostor_candidates.should_have_impostor(model_path)
		if Time.get_ticks_usec() >= deadline_usec:
			return i - 1

		if should_create_impostor:
			impostor_count += 1
			var transform: Transform3D = record.transform
			var pos: Vector3 = transform.origin
			var scale_vec: Vector3 = transform.basis.get_scale()
			var rot_euler: Vector3 = transform.basis.orthonormalized().get_euler()
			if Time.get_ticks_usec() >= deadline_usec:
				return i - 1
			add_impostor(model_path, grid, pos, rot_euler, scale_vec, ref_id_str, 0, record.object_id)

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


func _record_cell_scan_stats(elapsed_usec: int, cells_processed: int) -> void:
	_stats["far_cell_scan_us"] = elapsed_usec
	_stats["far_cells_processed_last_frame"] = cells_processed


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
	_impostor_textures[hash_key] = true
	_stats["texture_cache_size"] = _impostor_textures.size()
	var atlas_size: int = _hash_to_atlas_size.get(hash_key, DEFAULT_ATLAS_SIZE)
	var bucket := _get_or_assign_bucket_for_hash(hash_key, atlas_size)
	if bucket == null:
		_drop_pending_impostor_hash(hash_key)
		return

	# Add to texture array - check for failure
	var texture_index := _add_to_texture_array(hash_key, image, bucket)
	if texture_index < 0:
		# Texture array full and compaction didn't help - skip these impostors
		if debug_enabled:
			_debug("Texture array full, skipping %d impostors for hash %s" % [
				(_pending_impostors[hash_key] as Array).size(), hash_key])
		_drop_pending_impostor_hash(hash_key)
		_stats["texture_cache_size"] = _impostor_textures.size()
		return

	var pending_list: Array = _pending_impostors[hash_key]
	var queued_count := pending_list.size()
	if hash_key in bucket.normal_index_map:
		_queue_ready_texture_hash(hash_key)
	if debug_enabled:
		_debug("Texture loaded, %d impostors waiting for complete v6 data for hash %s" % [queued_count, hash_key])


func _create_impostor(
	model_path: String,
	cell_grid: Vector2i,
	ref_id: String,
	ref_num: int,
	source_object_id: StringName,
	hash_key: String,
	bucket: TextureBucket,
	position: Vector3,
	rotation: Vector3,
	scale: Vector3,
	texture_size: Vector2,
	aabb_center: Vector3
) -> int:
	if bucket == null:
		return -1
	if not _loaded_impostor_cells.has(cell_grid):
		return -1
	var texture_index: int = bucket.texture_index_map.get(hash_key, 0)

	var impostor := ImpostorData.new()
	impostor.id = _next_id
	impostor.cell_grid = cell_grid
	impostor.bucket_key = bucket.key
	impostor.atlas_size = bucket.atlas_size
	impostor.slab_index = bucket.slab_index
	impostor.page_key = _page_key_for_cell(cell_grid, bucket)
	impostor.ref_id = ref_id
	impostor.ref_num = ref_num
	impostor.source_object_id = source_object_id
	impostor.model_path = model_path
	impostor.texture_hash = hash_key
	impostor.texture_index = texture_index
	impostor.position = position
	impostor.rotation = rotation
	impostor.scale = scale
	impostor.texture_size = texture_size
	impostor.aabb_center = aabb_center

	_next_id += 1
	_impostors[impostor.id] = impostor
	_stats["total_impostors"] = _impostors.size()

	var page := _get_or_create_page(impostor.page_key, _spatial_page_key_for_cell(cell_grid), bucket)
	if page == null:
		_impostors.erase(impostor.id)
		_stats["total_impostors"] = _impostors.size()
		return -1
	page.impostor_ids.append(impostor.id)
	page.visibility_begin_distance = _page_visibility_begin_distance(page)
	_configure_page_visibility(page.instance, page.visibility_begin_distance)
	_mark_page_dirty(impostor.page_key)

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


func _add_to_texture_array(hash_key: String, image: Image, bucket: TextureBucket) -> int:
	if bucket == null:
		return -1
	if hash_key in bucket.texture_index_map:
		return bucket.texture_index_map[hash_key]

	# If at capacity, try to compact by removing unused textures
	if bucket.all_array_images.size() >= TEXTURE_ARRAY_SLAB_LAYERS:
		_compact_texture_array(bucket.key)
		# Check again after compaction
		if bucket.all_array_images.size() >= TEXTURE_ARRAY_SLAB_LAYERS:
			# Log warning only once per overflow event (not every impostor)
			if not _stats.get("_logged_array_full", false):
				push_warning("[NativeImpostorRenderer] Texture array slab limit reached (%d layers for %s). New impostors will be skipped until cells unload." % [TEXTURE_ARRAY_SLAB_LAYERS, bucket.key])
				_stats["_logged_array_full"] = true
			return -1  # Return -1 to indicate failure (not 0 which is a valid index)

	var index := bucket.all_array_images.size()
	bucket.texture_index_map[hash_key] = index

	# Resize image to standard size (256×256 balances quality vs VRAM)
	var img_copy := image
	if img_copy.get_size() != Vector2i(bucket.atlas_size, bucket.atlas_size):
		img_copy = image.duplicate() as Image
		img_copy.resize(bucket.atlas_size, bucket.atlas_size, Image.INTERPOLATE_LANCZOS)

	bucket.all_array_images.append(img_copy)
	bucket.texture_array_dirty = true
	_last_texture_add_time = Time.get_ticks_msec() / 1000.0

	_stats["texture_array_layers"] = _get_total_texture_layers()

	return index


## Compact the texture array by removing unreferenced textures
## This rebuilds the array with only textures that have active impostors using them
func _compact_texture_array(bucket_key: String = "") -> void:
	if bucket_key.is_empty():
		for key: String in _texture_buckets.keys():
			_compact_texture_array(key)
		return
	if bucket_key not in _texture_buckets:
		return
	var bucket: TextureBucket = _texture_buckets[bucket_key]
	# Find which textures are still in use (have reference count > 0)
	var used_hashes: Array[String] = []
	for hash_key: String in bucket.texture_index_map:
		if (
			(hash_key in _texture_ref_counts and _texture_ref_counts[hash_key] > 0)
			or hash_key in _pending_impostors
			or hash_key in _ready_texture_hash_set
			or hash_key in _pending_job_ids
			or (hash_key + "_normal") in _pending_job_ids
		):
			used_hashes.append(hash_key)

	var removed_count := bucket.texture_index_map.size() - used_hashes.size()
	for hash_key: String in bucket.normal_index_map:
		if hash_key not in used_hashes:
			removed_count += 1
	if removed_count == 0:
		return  # Nothing to compact

	if debug_enabled:
		_debug("Compacting texture array: removing %d unused textures" % removed_count)

	# Build new arrays with only used textures
	var new_images: Array[Image] = []
	var new_index_map: Dictionary[String, int] = {}

	for i in used_hashes.size():
		var hash_key: String = used_hashes[i]
		var old_index: int = bucket.texture_index_map[hash_key]
		new_images.append(bucket.all_array_images[old_index])
		new_index_map[hash_key] = i

	# Also compact normal arrays in parallel
	var new_normal_images: Array[Image] = []
	var new_normal_index_map: Dictionary[String, int] = {}

	for i in used_hashes.size():
		var hash_key: String = used_hashes[i]
		if hash_key in bucket.normal_index_map:
			var old_normal_idx: int = bucket.normal_index_map[hash_key]
			new_normal_images.append(bucket.all_normal_images[old_normal_idx])
			new_normal_index_map[hash_key] = new_normal_images.size() - 1

	# Update impostor texture indices to match new array positions
	for id: int in _impostors:
		var imp: ImpostorData = _impostors[id]
		if imp.bucket_key == bucket.key and imp.texture_hash in new_index_map:
			imp.texture_index = new_index_map[imp.texture_hash]
			imp.normal_texture_index = new_normal_index_map.get(imp.texture_hash, -1)

	# Clear old cached textures that are no longer in the array
	for hash_key: String in _impostor_textures.keys():
		if _hash_to_bucket_key.get(hash_key, "") == bucket.key and hash_key not in new_index_map:
			_impostor_textures.erase(hash_key)
			_impostor_normal_images.erase(hash_key)
			_hash_to_bucket_key.erase(hash_key)

	# Replace arrays
	bucket.all_array_images = new_images
	bucket.texture_index_map = new_index_map
	bucket.all_normal_images = new_normal_images
	bucket.normal_index_map = new_normal_index_map
	bucket.committed_texture_array_layers = 0
	bucket.committed_normal_array_layers = 0
	bucket.texture_array_dirty = true
	bucket.normal_array_dirty = true
	_mark_all_pages_dirty()

	_stats["texture_array_layers"] = _get_total_texture_layers()
	_stats["texture_cache_size"] = _impostor_textures.size()

	# Reset "array full" warning flag since we freed space
	if removed_count > 0:
		_stats["_logged_array_full"] = false


## Phase 6 (2026-04-17): async rebuild.
## Kicks a WorkerThreadPool task to do the image-conversion + copy loop on a
## worker, returns immediately. Completion is polled by `_poll_rebuild_task`
## each frame (called from _process). Main thread does the final
## `Texture2DArray.create_from_images` (RenderingServer allocation is main-
## thread only in Godot 4.6) then atomic-swaps the shader param.
##
## If a rebuild task is already in flight, re-queue is a no-op — the task's
## completion will pick up the latest dirty images once it lands. This
## matches the debounce contract at the _process call site.
func _rebuild_texture_array() -> void:
	var bucket := _get_dirty_rebuild_bucket()
	if bucket == null:
		return

	if _rebuild_task_id != -1:
		## Still running — the next debounce tick will retry.
		return

	var pending_cells_done := _pending_cell_index >= _pending_impostor_cells.size() and not _has_resume
	var upload_albedo := bucket.texture_array_dirty and not bucket.all_array_images.is_empty()
	var upload_normals := pending_cells_done and bucket.normal_array_dirty and not bucket.all_normal_images.is_empty()
	if not upload_albedo and not upload_normals:
		return

	## Snapshot current inputs so the worker sees a stable view even if
	## new impostors land mid-rebuild. Images are RefCounted; the snapshot
	## is a cheap shallow copy.
	var albedo_snapshot: Array[Image] = []
	if upload_albedo:
		albedo_snapshot.assign(bucket.all_array_images)
	var normal_snapshot: Array[Image] = []
	if upload_normals:
		normal_snapshot.assign(bucket.all_normal_images)
	_rebuild_bucket_key = bucket.key

	_rebuild_task_id = WorkerThreadPool.add_task(
		_rebuild_worker.bind(albedo_snapshot, normal_snapshot),
		true,
		"impostor texture array rebuild"
	)


## Worker-thread body. CPU-only work: iterate images, convert format to
## RGBA8 in place on a duplicate (not the original — the original is still
## referenced by the index map), stash the results for the main thread.
## No RenderingServer calls — those are main-thread only in Godot 4.6.
func _rebuild_worker(albedo: Array[Image], normals: Array[Image]) -> void:
	var albedo_out: Array[Image] = []
	albedo_out.resize(albedo.size())
	for i in range(albedo.size()):
		var img: Image = albedo[i]
		if img.get_format() != Image.FORMAT_RGBA8:
			## Duplicate before mutating — the source Image may be shared with
			## the shader's live texture array via an internal RID.
			img = img.duplicate()
			img.convert(Image.FORMAT_RGBA8)
		albedo_out[i] = img

	var normal_out: Array[Image] = []
	if not normals.is_empty():
		normal_out.resize(normals.size())
		for i in range(normals.size()):
			var img: Image = normals[i]
			if img.get_format() != Image.FORMAT_RGBA8:
				img = img.duplicate()
				img.convert(Image.FORMAT_RGBA8)
			normal_out[i] = img

	_rebuild_pending_albedo = albedo_out
	_rebuild_pending_normals = normal_out


## Poll the worker rebuild task. Called from _process every frame.
## When the task completes, do the main-thread finalisation:
##   1. Create new Texture2DArray via create_from_images (main-thread only).
##   2. Hold the OLD texture_array in _old_texture_array for one frame
##      (double-buffer — frees any GPU-side command-buffer reference).
##   3. Swap the shader param.
##   4. Release last frame's _old_texture_array.
func _poll_rebuild_task(deadline_usec: int = 0) -> void:
	## One-frame-delayed free of the previous texture array. Keeps the
	## old GPU texture alive for at least one command buffer submit after
	## the shader rebind, avoiding a use-after-free on batched drivers.
	for bucket: TextureBucket in _texture_buckets.values():
		bucket.old_texture_array = null
		bucket.old_normal_texture_array = null

	if _rebuild_task_id == -1:
		return
	if not WorkerThreadPool.is_task_completed(_rebuild_task_id):
		return
	if deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec:
		return

	WorkerThreadPool.wait_for_task_completion(_rebuild_task_id)
	_rebuild_task_id = -1
	var bucket: TextureBucket = _texture_buckets.get(_rebuild_bucket_key)
	_rebuild_bucket_key = ""
	if bucket == null:
		_rebuild_pending_albedo = []
		_rebuild_pending_normals = []
		return

	var albedo_images: Array[Image] = _rebuild_pending_albedo
	var normal_images: Array[Image] = _rebuild_pending_normals
	_rebuild_pending_albedo = []
	_rebuild_pending_normals = []

	if albedo_images.is_empty() and normal_images.is_empty():
		return

	## Main-thread RenderingServer allocation. This is the unavoidable
	## residual main-thread cost per rebuild — the texture upload itself.
	## Converting + duplicating the images (the CPU half) already ran on
	## the worker.
	var albedo_upload_usec := 0
	_stats["far_texture_upload_us"] = albedo_upload_usec
	_stats["far_texture_upload_us_%d" % bucket.atlas_size] = albedo_upload_usec
	if not albedo_images.is_empty():
		var new_array := Texture2DArray.new()
		var albedo_upload_start := Time.get_ticks_usec()
		var err := new_array.create_from_images(albedo_images)
		albedo_upload_usec = Time.get_ticks_usec() - albedo_upload_start
		_stats["far_texture_upload_us"] = albedo_upload_usec
		_stats["far_texture_upload_us_%d" % bucket.atlas_size] = albedo_upload_usec
		_stats["texture_array_upload_last_ms"] = float(albedo_upload_usec) / 1000.0
		_stats["texture_array_upload_max_ms"] = maxf(float(_stats.get("texture_array_upload_max_ms", 0.0)), float(albedo_upload_usec) / 1000.0)
		if err != OK:
			push_error("[NativeImpostorRenderer] Failed to create texture array: %s" % error_string(err))
			bucket.texture_array_dirty = false
			return

		## Swap. Old array kept alive one frame via _old_texture_array.
		bucket.old_texture_array = bucket.texture_array
		bucket.texture_array = new_array
		bucket.material.set_shader_parameter("texture_atlas", bucket.texture_array)
		bucket.committed_texture_array_layers = albedo_images.size()
		_texture_array_committed_this_frame = true
		bucket.texture_array_dirty = bucket.all_array_images.size() > albedo_images.size()
		_mark_all_pages_dirty()
		Log.debug("impostors", "Rebuilt texture array with %d layers (async)" % albedo_images.size())

	var normal_upload_usec := 0
	_stats["far_normal_upload_us"] = normal_upload_usec
	_stats["far_normal_upload_us_%d" % bucket.atlas_size] = normal_upload_usec
	if not normal_images.is_empty():
		var new_normal := Texture2DArray.new()
		var normal_upload_start := Time.get_ticks_usec()
		var err := new_normal.create_from_images(normal_images)
		normal_upload_usec = Time.get_ticks_usec() - normal_upload_start
		_stats["far_normal_upload_us"] = normal_upload_usec
		_stats["far_normal_upload_us_%d" % bucket.atlas_size] = normal_upload_usec
		if err != OK:
			push_error("[NativeImpostorRenderer] Failed to create normal texture array: %s" % error_string(err))
		else:
			bucket.old_normal_texture_array = bucket.normal_texture_array
			bucket.normal_texture_array = new_normal
			bucket.material.set_shader_parameter("normal_atlas", bucket.normal_texture_array)
			bucket.committed_normal_array_layers = normal_images.size()
			_mark_all_pages_dirty()
			Log.debug("impostors", "Rebuilt normal texture array with %d layers (async)" % normal_images.size())
		bucket.normal_array_dirty = bucket.all_normal_images.size() > normal_images.size()
	_stats["texture_array_rebuild_count"] = int(_stats.get("texture_array_rebuild_count", 0)) + 1


func _rebuild_page(page_key: String) -> Dictionary:
	if page_key not in _impostor_pages:
		return {"rebuilt": 0, "pack_usec": 0, "upload_usec": 0, "instances": 0}

	var page: ImpostorPage = _impostor_pages[page_key]
	if page.bucket_key not in _texture_buckets:
		return {"rebuilt": 0, "pack_usec": 0, "upload_usec": 0, "instances": 0}
	var bucket: TextureBucket = _texture_buckets[page.bucket_key]
	var all_live_ids: Array[int] = []
	var live_ids: Array[int] = []
	for id: int in page.impostor_ids:
		if id in _impostors:
			all_live_ids.append(id)
			var live_imp: ImpostorData = _impostors[id]
			if _is_impostor_ready_for_page(live_imp, bucket):
				live_ids.append(id)

	if all_live_ids.is_empty():
		_free_page(page_key)
		return {"rebuilt": 1, "pack_usec": 0, "upload_usec": 0, "instances": 0}
	page.impostor_ids = all_live_ids

	if live_ids.is_empty():
		page.multimesh.instance_count = 0
		page.multimesh.visible_instance_count = 0
		return {"rebuilt": 0, "pack_usec": 0, "upload_usec": 0, "instances": 0}

	var stride := 16
	var buffer := PackedFloat32Array()
	buffer.resize(live_ids.size() * stride)

	var pack_start_usec := Time.get_ticks_usec()
	var offset := 0
	var aabb_min := Vector3.ZERO
	var aabb_max := Vector3.ZERO
	var has_aabb := false
	for impostor_id: int in live_ids:
		var impostor: ImpostorData = _impostors[impostor_id]
		var center_offset := Vector3(
			impostor.aabb_center.x * impostor.scale.x,
			impostor.aabb_center.y * impostor.scale.y,
			impostor.aabb_center.z * impostor.scale.z
		)
		center_offset = Basis(Vector3.UP, impostor.rotation.y) * center_offset
		var billboard_pos := impostor.position + center_offset
		var local_pos := billboard_pos - page.center
		var sx := impostor.texture_size.x * impostor.scale.x
		var sy := impostor.texture_size.y * impostor.scale.y

		buffer[offset +  0] = sx
		buffer[offset +  1] = 0.0
		buffer[offset +  2] = 0.0
		buffer[offset +  3] = local_pos.x
		buffer[offset +  4] = 0.0
		buffer[offset +  5] = sy
		buffer[offset +  6] = 0.0
		buffer[offset +  7] = local_pos.y
		buffer[offset +  8] = 0.0
		buffer[offset +  9] = 0.0
		buffer[offset + 10] = 1.0
		buffer[offset + 11] = local_pos.z
		buffer[offset + 12] = float(impostor.texture_index)
		buffer[offset + 13] = impostor.rotation.y
		var normal_index := impostor.normal_texture_index
		if normal_index < 0 or normal_index >= bucket.committed_normal_array_layers:
			normal_index = -1
		buffer[offset + 14] = float(normal_index)
		buffer[offset + 15] = impostor.variant_flag
		offset += stride

		var half_xz := maxf(1.0, sx * 0.5) + IMPOSTOR_PAGE_AABB_MARGIN
		var half_y := maxf(1.0, sy * 0.5) + IMPOSTOR_PAGE_AABB_MARGIN
		var imp_min := local_pos - Vector3(half_xz, half_y, half_xz)
		var imp_max := local_pos + Vector3(half_xz, half_y, half_xz)
		if not has_aabb:
			aabb_min = imp_min
			aabb_max = imp_max
			has_aabb = true
		else:
			aabb_min = Vector3(minf(aabb_min.x, imp_min.x), minf(aabb_min.y, imp_min.y), minf(aabb_min.z, imp_min.z))
			aabb_max = Vector3(maxf(aabb_max.x, imp_max.x), maxf(aabb_max.y, imp_max.y), maxf(aabb_max.z, imp_max.z))

	var pack_usec := Time.get_ticks_usec() - pack_start_usec
	var upload_start_usec := Time.get_ticks_usec()
	page.multimesh.instance_count = live_ids.size()
	page.multimesh.visible_instance_count = live_ids.size()
	page.multimesh.set_buffer(buffer)
	if has_aabb:
		page.instance.custom_aabb = AABB(aabb_min, aabb_max - aabb_min)
	var upload_usec := Time.get_ticks_usec() - upload_start_usec
	return {"rebuilt": 1, "pack_usec": pack_usec, "upload_usec": upload_usec, "instances": live_ids.size()}


static func _is_impostor_ready_for_page(impostor: ImpostorData, bucket: TextureBucket) -> bool:
	if impostor == null or bucket == null:
		return false
	if impostor.texture_index < 0 or impostor.texture_index >= bucket.committed_texture_array_layers:
		return false
	return true


func _get_or_load_metadata(model_path: String) -> Dictionary:
	var hash_key := ImpostorCandidatesScript.get_hash_key(model_path)

	if hash_key in _impostor_metadata:
		return _impostor_metadata[hash_key]

	# v6-only. Do not fall back to legacy metadata; scale/projection
	# mismatches should skip the impostor rather than render stale data.
	var v6_path := ImpostorCandidatesScript.get_impostor_metadata_path_v6(model_path)
	if not FileAccess.file_exists(v6_path):
		return {}

	var file := FileAccess.open(v6_path, FileAccess.READ)
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
