## HLOD-only visual/performance test.
##
## Drives ObjectPaging directly without NativeStreamingManager's NEAR/MID/FAR
## scene representations. This isolates runtime HLOD chunk generation, publish
## cost, and draw-call quality while still using the real ESM + model-cache path.

extends Node3D

const DU := preload("res://src/core/world/distance_utils.gd")
const ObjectPagingScript := preload("res://src/core/world/object_paging.gd")
const StaticObjectRendererScript := preload("res://src/core/world/static_object_renderer.gd")
const BackgroundProcessorScript := preload("res://src/core/streaming/background_processor.gd")
const ModelLoaderScript := preload("res://src/core/world/model_loader.gd")

const ACTION_HLOD_BENCHMARK_TOGGLE := &"hlod_benchmark_toggle"
const ACTION_HLOD_DUMP_STATS := &"hlod_dump_stats"
const ACTION_HLOD_TELEPORT_TIER := &"hlod_teleport_tier"
const ACTION_HLOD_DEBUG_CHUNKS_TOGGLE := &"hlod_debug_chunks_toggle"
const ACTION_HLOD_FADE_TOGGLE := &"hlod_fade_toggle"

const START_CELL := Vector2i(-2, -9)
const START_POS := Vector3(-2.0 * 117.0 + 58.5, 52.0, 9.0 * 117.0 + 58.5)
const HLOD_UPDATE_DISTANCE := 25.0
const MODEL_LOADER_BUDGET_USEC := 2000
const HLOD_PUBLICATION_BUDGET_USEC := 2500
const STATS_INTERVAL := 0.25
const CSV_DIR := "user://benchmark_results"

const TELEPORT_DISTANCES: Array[float] = [300.0, 600.0, 1000.0]
const TELEPORT_LABELS: Array[String] = [
	"HLOD tier 1 begin",
	"HLOD tier 2 begin",
	"HLOD end",
]

var _camera: Camera3D
var _hud_label: RichTextLabel
var _static_renderer: StaticObjectRenderer
var _background_processor: BackgroundProcessor
var _model_loader: ModelLoader
var _hlod_merger: ObjectPaging
var _chunk_debug_instance: MeshInstance3D
var _chunk_debug_material: StandardMaterial3D

var _mouse_captured := true
var _mouse_sensitivity := 0.002
var _cam_speed := 90.0
var _camera_velocity_xz := Vector2.ZERO
var _chunk_debug_visible := false
var _fade_enabled := false

var _startup_done := false
var _fatal_error := ""
var _last_hlod_update_position := Vector3.INF
var _stats_timer := 0.0
var _teleport_index := 0

var _benchmarking := false
var _bench_frames: Array[Dictionary] = []
var _bench_start_time := 0.0


func _ready() -> void:
	InputActions.verify()
	_verify_test_actions()
	_setup_environment()
	_setup_camera()
	_setup_chunk_debug()
	_setup_hud()
	_hud_label.text = "[b]HLOD Only[/b]\nLoading ESM data..."
	_load_game_data.call_deferred()


func _exit_tree() -> void:
	if _benchmarking:
		_stop_benchmark()
	if _hlod_merger:
		_hlod_merger.cleanup()
		_hlod_merger = null
	if _background_processor:
		_background_processor.drain_all()
	if _static_renderer:
		_static_renderer.clear()


func _load_game_data() -> void:
	if ESMManager.cells.size() <= 0:
		var esm_file: String = SettingsManager.get_esm_file()
		var data_path: String = SettingsManager.get_data_path()
		var esm_path := data_path.path_join(esm_file)
		Log.info("hlod_only", "Loading ESM: %s" % esm_path)
		await get_tree().process_frame
		var err := ESMManager.load_file(esm_path)
		if err != OK:
			_fatal("Failed to load ESM: %s" % error_string(err))
			return

	await _setup_hlod_runtime()
	_startup_done = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_hlod_needs_update()
	_start_benchmark()
	Log.info("hlod_only", "Ready: direct ObjectPaging HLOD-only harness is running")


func _setup_environment() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45.0, 35.0, 0.0)
	light.shadow_enabled = false
	light.light_energy = 1.25
	add_child(light)

	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.34, 0.42, 0.52)
	sky_mat.sky_horizon_color = Color(0.67, 0.70, 0.73)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world_env.environment = env
	add_child(world_env)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "HLODOnlyCamera"
	_camera.position = START_POS
	_camera.rotation_degrees = Vector3(-12.0, 0.0, 0.0)
	_camera.far = 6000.0
	_camera.near = 0.1
	_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_camera)
	_camera.make_current()


func _setup_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "HUD"
	add_child(canvas)

	_hud_label = RichTextLabel.new()
	_hud_label.bbcode_enabled = true
	_hud_label.fit_content = true
	_hud_label.scroll_active = false
	_hud_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_label.position = Vector2(10.0, 10.0)
	_hud_label.size = Vector2(700.0, 520.0)
	_hud_label.add_theme_font_size_override("normal_font_size", 14)
	canvas.add_child(_hud_label)


func _setup_chunk_debug() -> void:
	_chunk_debug_material = StandardMaterial3D.new()
	_chunk_debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_chunk_debug_material.vertex_color_use_as_albedo = true
	_chunk_debug_material.no_depth_test = true

	_chunk_debug_instance = MeshInstance3D.new()
	_chunk_debug_instance.name = "HLODChunkBounds"
	_chunk_debug_instance.visible = false
	_chunk_debug_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_chunk_debug_instance.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_chunk_debug_instance)


func _setup_hlod_runtime() -> void:
	_background_processor = BackgroundProcessorScript.new()
	_background_processor.name = "BackgroundProcessor"
	add_child(_background_processor)

	_static_renderer = StaticObjectRendererScript.new()
	_static_renderer.name = "StaticObjectRendererPrototypeRegistry"
	add_child(_static_renderer)

	_model_loader = ModelLoaderScript.new()
	_hlod_merger = ObjectPagingScript.new()

	await get_tree().process_frame

	var scenario := get_viewport().get_world_3d().scenario
	_hlod_merger.initialize(scenario, _static_renderer, _background_processor, _model_loader)
	_hlod_merger.set_visual_begin_floor(DU.HLOD_START)
	_hlod_merger.set_visibility_fade_enabled(_fade_enabled)
	_hlod_merger.enabled = true
	_hlod_merger.set_all_visible(true)


func _verify_test_actions() -> void:
	for action_name: StringName in InputActions.VISUAL_TEST:
		if not InputMap.has_action(action_name):
			_fatal("Missing visual test action: %s" % action_name)
			assert(false, "missing visual test action: %s" % action_name)


@warning_ignore("untyped_declaration")
func _input(event: InputEvent) -> void:
	if _camera == null:
		return
	if event is InputEventMouseMotion and _mouse_captured:
		_camera.rotate_y(-event.relative.x * _mouse_sensitivity)
		_camera.rotate_object_local(Vector3.RIGHT, -event.relative.y * _mouse_sensitivity)
		var rot := _camera.rotation_degrees
		rot.x = clampf(rot.x, -89.0, 89.0)
		_camera.rotation_degrees = rot

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cam_speed = minf(_cam_speed * 1.25, 800.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cam_speed = maxf(_cam_speed / 1.25, 5.0)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			_mouse_captured = true

	if event is InputEventKey and event.pressed and not event.echo:
		if event.is_action_pressed(ACTION_HLOD_BENCHMARK_TOGGLE):
			if _benchmarking:
				_stop_benchmark()
			else:
				_start_benchmark()
		elif event.is_action_pressed(ACTION_HLOD_DUMP_STATS):
			_dump_stats()
		elif event.is_action_pressed(ACTION_HLOD_TELEPORT_TIER):
			_teleport_tier()
		elif event.is_action_pressed(ACTION_HLOD_DEBUG_CHUNKS_TOGGLE):
			_toggle_chunk_debug()
		elif event.is_action_pressed(ACTION_HLOD_FADE_TOGGLE):
			_toggle_distance_fade()
		elif event.is_action_pressed("ui_cancel"):
			if _mouse_captured:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				_mouse_captured = false
			else:
				get_tree().quit()


func _process(delta: float) -> void:
	_process_camera_movement(delta)
	if _model_loader:
		_model_loader.process_async_loads(MODEL_LOADER_BUDGET_USEC)

	if _startup_done and _hlod_merger:
		var hlod_deadline := Time.get_ticks_usec() + HLOD_PUBLICATION_BUDGET_USEC
		if _hlod_needs_update():
			var camera_cell := DU.world_to_cell(_camera.global_position)
			_hlod_merger.update_for_camera(camera_cell, _camera.global_position, _camera_velocity_xz)
			_last_hlod_update_position = _camera.global_position
		if Time.get_ticks_usec() < hlod_deadline:
			_hlod_merger.process_merge_queue(hlod_deadline)
		if Time.get_ticks_usec() < hlod_deadline:
			_hlod_merger.process_completions(hlod_deadline)

	_stats_timer += delta
	if _stats_timer >= STATS_INTERVAL:
		_stats_timer = 0.0
		_update_hud()
		_update_chunk_debug_mesh()

	if _benchmarking:
		_record_frame()


func _process_camera_movement(delta: float) -> void:
	if _camera == null or not _startup_done:
		return
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var velocity := Vector3.ZERO
	velocity += _camera.global_transform.basis.z * input_dir.y
	velocity += _camera.global_transform.basis.x * input_dir.x
	if Input.is_action_pressed("jump"):
		velocity.y += 1.0
	if Input.is_action_pressed("crouch"):
		velocity.y -= 1.0
	if velocity.length() > 0.0:
		var movement := velocity.normalized() * _cam_speed
		_camera_velocity_xz = Vector2(movement.x, movement.z)
		_camera.position += movement * delta
	else:
		_camera_velocity_xz = Vector2.ZERO


func _hlod_needs_update() -> bool:
	if _last_hlod_update_position == Vector3.INF:
		return true
	var current_xz := Vector2(_camera.global_position.x, _camera.global_position.z)
	var last_xz := Vector2(_last_hlod_update_position.x, _last_hlod_update_position.z)
	return current_xz.distance_to(last_xz) >= HLOD_UPDATE_DISTANCE


func _get_hlod_stats() -> Dictionary:
	if _hlod_merger == null:
		return {}
	return _hlod_merger.get_stats()


func _toggle_chunk_debug() -> void:
	_chunk_debug_visible = not _chunk_debug_visible
	if _chunk_debug_instance:
		_chunk_debug_instance.visible = _chunk_debug_visible
	_update_chunk_debug_mesh()
	Log.info("hlod_only", "Chunk bounds: %s" % ("ON" if _chunk_debug_visible else "OFF"))


func _toggle_distance_fade() -> void:
	_fade_enabled = not _fade_enabled
	if _hlod_merger:
		_hlod_merger.set_visibility_fade_enabled(_fade_enabled)
	Log.info("hlod_only", "HLOD distance fade: %s" % ("ON" if _fade_enabled else "OFF"))


func _dump_stats() -> void:
	var stats := _get_hlod_stats()
	Log.info("hlod_only", "=== HLOD ONLY STATS ===")
	for key: String in stats:
		Log.info("hlod_only", "  %s: %s" % [key, str(stats[key])])


func _update_hud() -> void:
	if _hud_label == null:
		return
	if not _fatal_error.is_empty():
		_hud_label.text = "[color=red]%s[/color]" % _fatal_error
		return

	var p := Performance
	var stats := _get_hlod_stats()
	var fps := p.get_monitor(p.TIME_FPS)
	var frame_ms := p.get_monitor(p.TIME_PROCESS) * 1000.0
	var draws := int(p.get_monitor(p.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var objects := int(p.get_monitor(p.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var prims := int(p.get_monitor(p.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var vram_mb := p.get_monitor(p.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0)
	var camera_cell := DU.world_to_cell(_camera.global_position) if _camera else START_CELL

	var active := int(stats.get("active_visual_chunks", 0))
	var desired := int(stats.get("desired_chunks", 0))
	var predictive := int(stats.get("predictive_desired_chunks", 0))
	var pending := int(stats.get("pending_merges", 0))
	var cached_publish := int(stats.get("cached_publish_queue_size", 0))
	var queued := int(stats.get("merge_queue_size", 0))
	var preparing := int(stats.get("preparing_chunks", 0))
	var negative := int(stats.get("negative_chunks", 0))
	var negative_sparse := int(stats.get("negative_sparse_chunks", 0))
	var negative_empty := int(stats.get("negative_empty_chunks", 0))
	var negative_filtered := int(stats.get("negative_filtered_chunks", 0))
	var negative_failed := int(stats.get("negative_failed_chunks", 0))
	var negative_surface := int(stats.get("negative_surface_cap_chunks", 0))
	var warmup := int(stats.get("warmup_queue_size", 0))
	var async_pending := int(stats.get("warmup_pending_async", 0))
	var surfaces := int(stats.get("total_chunk_surfaces", 0))
	var materials := int(stats.get("total_chunk_materials", 0))
	var null_material_surfaces := int(stats.get("null_material_surface_count", 0))
	var default_proxy_surfaces := int(stats.get("default_proxy_surface_count", 0))
	var overflow_proxy_surfaces := int(stats.get("overflow_proxy_surfaces", 0))
	var runtime_proxy_chunks := int(stats.get("runtime_surface_budget_proxy_chunks", 0))
	var vertices := int(stats.get("total_chunk_vertices", 0))
	var max_surfaces := int(stats.get("max_chunk_surfaces", 0))
	var stale := int(stats.get("stale_completions_discarded", 0))
	var surface_rejects := int(stats.get("surface_cap_rejections", 0))
	var over_budget_published := int(stats.get("surface_cap_over_budget_published", 0))
	var merge_us := int(stats.get("merge_queue_last_usec", 0))
	var completion_us := int(stats.get("completion_last_usec", 0))
	var complete := int(stats.get("active_complete_coverage_chunks", 0))
	var incomplete := int(stats.get("active_incomplete_coverage_chunks", 0))
	var fade_text := "[color=orange]ON[/color]" if _fade_enabled else "[color=green]OFF[/color]"
	var chunks_text := "[color=green]ON[/color]" if _chunk_debug_visible else "OFF"

	var bench_text := "[color=yellow]recording[/color]" if _benchmarking else "idle"
	var startup_text := "[color=green]ready[/color]" if _startup_done else "[color=yellow]loading[/color]"

	_hud_label.text = """[b]HLOD Only[/b]  %s  |  Bench: %s  |  Chunks: %s  |  Fade: %s

[b]Performance[/b]
  FPS %.0f  |  Frame %.1fms  |  Draws %d  |  Objects %d  |  Prims %dk  |  VRAM %.0f MB

[b]Chunks[/b]
  Desired %d  |  Prefetch %d  |  Visual %d  |  Pending %d  |  Cached publish %d  |  Queue %d  |  Preparing %d  |  Negative %d
  Desired T1/T2 %d/%d  |  Visual T1/T2 %d/%d  |  Warmup %d  |  Async %d
  Negative: sparse %d  |  empty %d  |  filtered %d  |  failed %d  |  surface %d

[b]Proxy Cost[/b]
  Surfaces %d  |  Materials %d  |  Verts %dk  |  Max surfaces/chunk %d
  Null mats %d  |  Proxy fallback %d  |  Overflow folded %d  |  Budget proxy chunks %d
  Merge %.2fms  |  Publish %.2fms  |  Stale %d  |  Surface rejects %d  |  Over-budget kept %d

[b]Coverage[/b]
  Complete chunks %d  |  Incomplete chunks %d  |  Covered refs %d  |  Covered cells %d

[b]Camera[/b]
  Cell %s  |  Speed %.0f m/s

[b]Controls[/b]
  F2 benchmark  |  F3 dump  |  F4 teleport  |  F5 chunks  |  F6 fade
  Boxes: cyan/orange active, blue queued, purple preparing/pending, grey desired
  olive empty/sparse negative, red failed/surface negative""" % [
		startup_text, bench_text, chunks_text, fade_text,
		fps, frame_ms, draws, objects, prims / 1000, vram_mb,
		desired, predictive, active, pending, cached_publish, queued, preparing, negative,
		int(stats.get("desired_chunks_tier_1", 0)), int(stats.get("desired_chunks_tier_2", 0)),
		int(stats.get("chunks_tier_1", 0)), int(stats.get("chunks_tier_2", 0)), warmup, async_pending,
		negative_sparse, negative_empty, negative_filtered, negative_failed, negative_surface,
		surfaces, materials, vertices / 1000, max_surfaces,
		null_material_surfaces, default_proxy_surfaces, overflow_proxy_surfaces, runtime_proxy_chunks,
		float(merge_us) / 1000.0, float(completion_us) / 1000.0, stale, surface_rejects, over_budget_published,
		complete, incomplete, int(stats.get("active_covered_refs", 0)), int(stats.get("active_covered_cells", 0)),
		camera_cell, _cam_speed,
	]


func _update_chunk_debug_mesh() -> void:
	if not _chunk_debug_visible or _chunk_debug_instance == null or _hlod_merger == null:
		return
	var chunk_data: Array[Dictionary] = _hlod_merger.get_active_chunk_debug_data()
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	for chunk: Dictionary in chunk_data:
		var level := int(chunk.get("size_level", 0))
		var status := str(chunk.get("status", "desired"))
		var reason := str(chunk.get("negative_reason", ""))
		var color := _chunk_debug_color(status, level, reason)
		_append_chunk_box(vertices, colors, chunk.get("origin", Vector3.ZERO), float(chunk.get("size_m", 0.0)), color)

	var mesh := ArrayMesh.new()
	if vertices.size() > 0:
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_COLOR] = colors
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
		mesh.surface_set_material(0, _chunk_debug_material)
	_chunk_debug_instance.mesh = mesh


func _chunk_debug_color(status: String, level: int, reason: String = "") -> Color:
	match status:
		"active":
			if level == 1:
				return Color(0.05, 0.95, 1.0, 1.0)
			if level == 2:
				return Color(1.0, 0.72, 0.05, 1.0)
			return Color(0.35, 1.0, 0.35, 1.0)
		"pending":
			return Color(1.0, 0.2, 1.0, 1.0)
		"preparing":
			return Color(0.85, 0.35, 1.0, 1.0)
		"queued":
			return Color(0.35, 0.45, 1.0, 1.0)
		"negative":
			return _negative_chunk_debug_color(reason)
		_:
			return Color(0.42, 0.42, 0.42, 1.0)


func _negative_chunk_debug_color(reason: String) -> Color:
	match reason:
		"empty":
			return Color(0.36, 0.34, 0.22, 1.0)
		"sparse", "filtered", "partial_bucket":
			return Color(0.58, 0.55, 0.18, 1.0)
		_:
			return Color(1.0, 0.05, 0.05, 1.0)


func _append_chunk_box(vertices: PackedVector3Array, colors: PackedColorArray, center: Vector3, size_m: float, color: Color) -> void:
	if size_m <= 0.0:
		return
	var half := size_m * 0.5
	var y0 := -20.0
	var y1 := 140.0
	var corners: Array[Vector3] = [
		Vector3(center.x - half, y0, center.z - half),
		Vector3(center.x + half, y0, center.z - half),
		Vector3(center.x + half, y0, center.z + half),
		Vector3(center.x - half, y0, center.z + half),
		Vector3(center.x - half, y1, center.z - half),
		Vector3(center.x + half, y1, center.z - half),
		Vector3(center.x + half, y1, center.z + half),
		Vector3(center.x - half, y1, center.z + half),
	]
	var edges: Array[Vector2i] = [
		Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 3), Vector2i(3, 0),
		Vector2i(4, 5), Vector2i(5, 6), Vector2i(6, 7), Vector2i(7, 4),
		Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
	]
	for edge: Vector2i in edges:
		vertices.append(corners[edge.x])
		vertices.append(corners[edge.y])
		colors.append(color)
		colors.append(color)


func _start_benchmark() -> void:
	_benchmarking = true
	_bench_frames.clear()
	_bench_start_time = Time.get_ticks_msec() / 1000.0
	Log.info("hlod_only", "Benchmark started")


func _stop_benchmark() -> void:
	_benchmarking = false
	_save_benchmark()


func _record_frame() -> void:
	var p := Performance
	var stats := _get_hlod_stats()
	_bench_frames.append({
		"frame": Engine.get_frames_drawn(),
		"time_ms": Time.get_ticks_msec(),
		"fps": p.get_monitor(p.TIME_FPS),
		"frame_ms": p.get_monitor(p.TIME_PROCESS) * 1000.0,
		"draw_calls": int(p.get_monitor(p.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"objects": int(p.get_monitor(p.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"primitives": int(p.get_monitor(p.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"hlod_visual": int(stats.get("active_visual_chunks", 0)),
		"hlod_desired": int(stats.get("desired_chunks", 0)),
		"hlod_predictive": int(stats.get("predictive_desired_chunks", 0)),
		"hlod_pending": int(stats.get("pending_merges", 0)),
		"hlod_cached_publish": int(stats.get("cached_publish_queue_size", 0)),
		"hlod_queue": int(stats.get("merge_queue_size", 0)),
		"hlod_preparing": int(stats.get("preparing_chunks", 0)),
		"hlod_negative": int(stats.get("negative_chunks", 0)),
		"hlod_negative_sparse": int(stats.get("negative_sparse_chunks", 0)),
		"hlod_negative_empty": int(stats.get("negative_empty_chunks", 0)),
		"hlod_negative_filtered": int(stats.get("negative_filtered_chunks", 0)),
		"hlod_negative_failed": int(stats.get("negative_failed_chunks", 0)),
		"hlod_negative_surface": int(stats.get("negative_surface_cap_chunks", 0)),
		"hlod_tier1": int(stats.get("chunks_tier_1", 0)),
		"hlod_tier2": int(stats.get("chunks_tier_2", 0)),
		"hlod_surfaces": int(stats.get("total_chunk_surfaces", 0)),
		"hlod_materials": int(stats.get("total_chunk_materials", 0)),
		"hlod_null_material_surfaces": int(stats.get("null_material_surface_count", 0)),
		"hlod_default_proxy_surfaces": int(stats.get("default_proxy_surface_count", 0)),
		"hlod_overflow_proxy_surfaces": int(stats.get("overflow_proxy_surfaces", 0)),
		"hlod_runtime_proxy_chunks": int(stats.get("runtime_surface_budget_proxy_chunks", 0)),
		"hlod_vertices": int(stats.get("total_chunk_vertices", 0)),
		"hlod_max_surfaces": int(stats.get("max_chunk_surfaces", 0)),
		"hlod_merge_us": int(stats.get("merge_queue_last_usec", 0)),
		"hlod_completion_us": int(stats.get("completion_last_usec", 0)),
		"hlod_surface_rejects": int(stats.get("surface_cap_rejections", 0)),
		"hlod_surface_over_budget_published": int(stats.get("surface_cap_over_budget_published", 0)),
		"hlod_covered_refs": int(stats.get("active_covered_refs", 0)),
		"fade_enabled": _fade_enabled,
		"cam_x": _camera.position.x,
		"cam_y": _camera.position.y,
		"cam_z": _camera.position.z,
	})


func _save_benchmark() -> void:
	if _bench_frames.is_empty():
		Log.warn("hlod_only", "No benchmark frames recorded")
		return
	DirAccess.make_dir_recursive_absolute(CSV_DIR)
	var ts := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var filename := "%s/hlod_only_%s.csv" % [CSV_DIR, ts]
	var file := FileAccess.open(filename, FileAccess.WRITE)
	if file == null:
		Log.error("hlod_only", "Failed to write %s" % filename)
		return

	file.store_line("frame,time_ms,fps,frame_ms,draw_calls,objects,primitives,hlod_desired,hlod_visual,hlod_pending,hlod_cached_publish,hlod_queue,hlod_preparing,hlod_negative,hlod_negative_sparse,hlod_negative_empty,hlod_negative_filtered,hlod_negative_failed,hlod_negative_surface,hlod_tier1,hlod_tier2,hlod_surfaces,hlod_materials,hlod_vertices,hlod_max_surfaces,hlod_merge_us,hlod_completion_us,hlod_surface_rejects,hlod_runtime_proxy_chunks,hlod_covered_refs,fade_enabled,cam_x,cam_y,cam_z")
	for f: Dictionary in _bench_frames:
		file.store_line("%d,%d,%.1f,%.2f,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%s,%.1f,%.1f,%.1f" % [
			f["frame"], f["time_ms"], f["fps"], f["frame_ms"],
			f["draw_calls"], f["objects"], f["primitives"],
			f["hlod_desired"], f["hlod_visual"], f["hlod_pending"], f["hlod_cached_publish"], f["hlod_queue"],
			f["hlod_preparing"], f["hlod_negative"],
			f["hlod_negative_sparse"], f["hlod_negative_empty"], f["hlod_negative_filtered"], f["hlod_negative_failed"], f["hlod_negative_surface"],
			f["hlod_tier1"], f["hlod_tier2"],
			f["hlod_surfaces"], f["hlod_materials"], f["hlod_vertices"], f["hlod_max_surfaces"],
			f["hlod_merge_us"], f["hlod_completion_us"], f["hlod_surface_rejects"], f["hlod_runtime_proxy_chunks"], f["hlod_covered_refs"],
			str(f["fade_enabled"]),
			f["cam_x"], f["cam_y"], f["cam_z"],
		])
	file.close()

	var fps_sum := 0.0
	var min_fps := INF
	var max_draws := 0
	var max_visual := 0
	var max_surfaces := 0
	for f: Dictionary in _bench_frames:
		fps_sum += float(f["fps"])
		min_fps = minf(min_fps, float(f["fps"]))
		max_draws = maxi(max_draws, int(f["draw_calls"]))
		max_visual = maxi(max_visual, int(f["hlod_visual"]))
		max_surfaces = maxi(max_surfaces, int(f["hlod_surfaces"]))
	var avg_fps := fps_sum / float(_bench_frames.size())
	Log.info("hlod_only", "Benchmark saved: %s" % filename)
	Log.info("hlod_only", "Summary: frames=%d avg_fps=%.1f min_fps=%.1f max_draws=%d max_visual_chunks=%d max_surfaces=%d" % [
		_bench_frames.size(), avg_fps, min_fps, max_draws, max_visual, max_surfaces,
	])


func _teleport_tier() -> void:
	var dist := TELEPORT_DISTANCES[_teleport_index]
	var label := TELEPORT_LABELS[_teleport_index]
	_camera.position = START_POS + Vector3(0.0, 20.0, dist)
	_camera.rotation_degrees = Vector3(-10.0, 0.0, 0.0)
	_last_hlod_update_position = Vector3.INF
	Log.info("hlod_only", "Teleported to %s (%.0fm)" % [label, dist])
	_teleport_index = (_teleport_index + 1) % TELEPORT_DISTANCES.size()


func _fatal(message: String) -> void:
	_fatal_error = message
	Log.error("hlod_only", message)
	if _hud_label:
		_hud_label.text = "[color=red]%s[/color]" % message
