## Streaming Demo - Demonstrates unified terrain + object streaming
##
## This demo showcases the WorldStreamingManager which coordinates:
## - Terrain3D for terrain LOD and streaming
## - OWDB for object streaming (statics, lights, NPCs, etc.)
##
## Both systems work together based on camera/player position.
##
## Performance Profiling:
## Press F3 to toggle performance overlay
## Press F4 to dump detailed profiling report
## Use +/- to adjust view distance for testing
extends Node3D

# Preload dependencies
const WorldStreamingManagerScript := preload("res://src/core/world/world_streaming_manager.gd")
const TerrainManagerScript := preload("res://src/core/world/terrain_manager.gd")
const TerrainTextureLoaderScript := preload("res://src/core/world/terrain_texture_loader.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const MWCoords := preload("res://src/core/morrowind_coords.gd")
const PerformanceProfilerScript := preload("res://src/core/world/performance_profiler.gd")

# Pre-processed terrain data directory (shared with terrain_viewer)
const TERRAIN_DATA_DIR := "user://terrain_data/"

# Node references
@onready var camera: Camera3D = $FlyCamera
@onready var terrain_3d: Terrain3D = $Terrain3D
@onready var loading_overlay: ColorRect = $UI/LoadingOverlay
@onready var loading_label: Label = $UI/LoadingOverlay/VBox/LoadingLabel
@onready var progress_bar: ProgressBar = $UI/LoadingOverlay/VBox/ProgressBar
@onready var status_label: Label = $UI/LoadingOverlay/VBox/StatusLabel
@onready var stats_panel: Panel = $UI/StatsPanel
@onready var stats_text: RichTextLabel = $UI/StatsPanel/VBox/StatsText
@onready var log_text: RichTextLabel = $UI/LogPanel/VBox/LogText

# Quick teleport buttons
@onready var seyda_neen_btn: Button = $UI/StatsPanel/VBox/QuickButtons/SeydaNeenBtn
@onready var balmora_btn: Button = $UI/StatsPanel/VBox/QuickButtons/BalmoraBtn
@onready var vivec_btn: Button = $UI/StatsPanel/VBox/QuickButtons/VivecBtn
@onready var origin_btn: Button = $UI/StatsPanel/VBox/QuickButtons/OriginBtn

# Managers
var world_streaming_manager: Node3D = null  # WorldStreamingManager
var terrain_manager: RefCounted = null  # TerrainManager
var texture_loader: RefCounted = null  # TerrainTextureLoader
var cell_manager: RefCounted = null  # CellManager
var profiler: RefCounted = null  # PerformanceProfiler

# Camera controls
var camera_speed: float = 200.0
var mouse_sensitivity: float = 0.003
var mouse_captured: bool = false

# State
var _data_path: String = ""
var _initialized: bool = false
var _using_preprocessed: bool = false
var _perf_overlay_visible: bool = true
var _current_view_distance: int = 2


func _ready() -> void:
	# Initialize managers
	terrain_manager = TerrainManagerScript.new()
	texture_loader = TerrainTextureLoaderScript.new()
	cell_manager = CellManagerScript.new()
	cell_manager.load_npcs = false  # Skip NPCs for now
	cell_manager.load_creatures = true

	# Initialize object pool for frequently used models
	cell_manager.init_object_pool()

	# Initialize profiler
	profiler = PerformanceProfilerScript.new()
	profiler.start_session()

	# Connect quick teleport buttons
	seyda_neen_btn.pressed.connect(func(): _teleport_to_cell(-2, -9))
	balmora_btn.pressed.connect(func(): _teleport_to_cell(-3, -2))
	vivec_btn.pressed.connect(func(): _teleport_to_cell(5, -6))
	origin_btn.pressed.connect(func(): _teleport_to_cell(0, 0))

	# Get Morrowind data path
	_data_path = ProjectSettings.get_setting("morrowind/data_path", "")
	if _data_path.is_empty():
		_hide_loading()
		_log("[color=red]ERROR: Morrowind data path not configured[/color]")
		return

	# Start async initialization
	_show_loading("Initializing World Streaming", "Loading game data...")
	call_deferred("_init_async")


func _init_async() -> void:
	# Load BSA archives
	await _update_loading(10, "Loading BSA archives...")
	var bsa_count := BSAManager.load_archives_from_directory(_data_path)
	_log("Loaded %d BSA archives" % bsa_count)

	# Load ESM file
	await _update_loading(30, "Loading ESM file...")
	var esm_file: String = ProjectSettings.get_setting("morrowind/esm_file", "Morrowind.esm")
	var esm_path := _data_path.path_join(esm_file)
	var error := ESMManager.load_file(esm_path)

	if error != OK:
		_log("[color=red]ERROR: Failed to load ESM: %s[/color]" % error_string(error))
		_hide_loading()
		return

	_log("[color=green]ESM loaded successfully[/color]")
	_log("LAND records: %d, CELL records: %d" % [ESMManager.lands.size(), ESMManager.cells.size()])

	# Check for pre-processed terrain
	await _update_loading(50, "Checking terrain data...")
	_check_preprocessed_terrain()

	# Initialize Terrain3D
	await _update_loading(60, "Initializing Terrain3D...")
	_init_terrain3d()

	# Load pre-processed terrain if available
	if _using_preprocessed:
		await _update_loading(70, "Loading terrain data...")
		_load_preprocessed_terrain()
	else:
		_log("[color=yellow]No pre-processed terrain found.[/color]")
		_log("Run TerrainViewer and click 'Preprocess ALL Terrain' first.")

	# Create and setup WorldStreamingManager
	await _update_loading(85, "Setting up streaming system...")
	_setup_world_streaming_manager()

	# Done
	await _update_loading(100, "Ready!")
	await get_tree().create_timer(0.3).timeout
	_hide_loading()

	_initialized = true
	_log("[color=green]World streaming initialized![/color]")
	_log("Use WASD to move, Right-click to look")
	_log("Cells stream automatically based on camera position")

	# Start at Seyda Neen
	_teleport_to_cell(-2, -9)


func _check_preprocessed_terrain() -> void:
	var dir := DirAccess.open(TERRAIN_DATA_DIR)
	if dir:
		var count := 0
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if file_name.ends_with(".res"):
				count += 1
			file_name = dir.get_next()
		dir.list_dir_end()

		if count > 0:
			_using_preprocessed = true
			_log("Found %d pre-processed terrain regions" % count)


func _init_terrain3d() -> void:
	if not terrain_3d:
		_log("[color=red]ERROR: Terrain3D node not found[/color]")
		return

	if not ClassDB.class_exists("Terrain3DData"):
		_log("[color=red]ERROR: Terrain3D addon not loaded[/color]")
		return

	# Create resources if needed
	if not terrain_3d.data:
		terrain_3d.set_data(Terrain3DData.new())

	if not terrain_3d.material:
		terrain_3d.set_material(Terrain3DMaterial.new())

	if not terrain_3d.assets:
		terrain_3d.set_assets(Terrain3DAssets.new())

	# Configure for Morrowind (same as terrain_viewer)
	var mw_cell_size_godot := MWCoords.CELL_SIZE_GODOT
	@warning_ignore("int_as_enum_without_cast", "int_as_enum_without_match")
	terrain_3d.change_region_size(128)
	var vertex_spacing := mw_cell_size_godot / 64.0
	terrain_3d.vertex_spacing = vertex_spacing

	_log("Terrain3D configured: region_size=128, vertex_spacing=%.4f" % vertex_spacing)


func _load_preprocessed_terrain() -> void:
	if not terrain_3d or not terrain_3d.data:
		return

	# Load textures first
	var textures_loaded: int = texture_loader.load_terrain_textures(terrain_3d.assets)
	_log("Loaded %d terrain textures" % textures_loaded)
	terrain_manager.set_texture_slot_mapper(texture_loader)

	# Load terrain data
	var path := ProjectSettings.globalize_path(TERRAIN_DATA_DIR)
	terrain_3d.data.load_directory(path)
	var region_count := terrain_3d.data.get_region_count()
	_log("Loaded %d terrain regions" % region_count)


func _setup_world_streaming_manager() -> void:
	# Create WorldStreamingManager
	world_streaming_manager = Node3D.new()
	world_streaming_manager.set_script(WorldStreamingManagerScript)
	world_streaming_manager.name = "WorldStreamingManager"

	# Configure
	world_streaming_manager.view_distance_cells = _current_view_distance
	world_streaming_manager.load_objects = true
	world_streaming_manager.load_terrain = true
	world_streaming_manager.debug_enabled = true

	# OWDB configuration for Morrowind objects
	# Use typed array to match the @export Array[float] type
	var chunk_sizes: Array[float] = [8.0, 16.0, 64.0]
	world_streaming_manager.owdb_chunk_sizes = chunk_sizes
	world_streaming_manager.owdb_chunk_load_range = 3
	world_streaming_manager.owdb_batch_time_limit_ms = 5.0

	add_child(world_streaming_manager)

	# Connect signals
	world_streaming_manager.cell_loaded.connect(_on_cell_loaded)
	world_streaming_manager.cell_unloaded.connect(_on_cell_unloaded)

	# Provide managers
	world_streaming_manager.set_cell_manager(cell_manager)
	world_streaming_manager.set_terrain_manager(terrain_manager)
	world_streaming_manager.set_terrain_3d(terrain_3d)

	# Track camera
	world_streaming_manager.set_tracked_node(camera)

	# Initialize after all configuration is set
	world_streaming_manager.initialize()

	_log("WorldStreamingManager created and configured")


func _on_cell_loaded(grid: Vector2i, node: Node3D) -> void:
	var obj_count := node.get_child_count()
	_log("Cell loaded: (%d, %d) - %d objects" % [grid.x, grid.y, obj_count])

	# Record cell load in profiler
	if profiler and world_streaming_manager:
		var stats: Dictionary = world_streaming_manager.get_stats()
		profiler.record_cell_load(stats.get("load_time_ms", 0.0), obj_count)

	_update_stats()


func _on_cell_unloaded(grid: Vector2i) -> void:
	_log("Cell unloaded: (%d, %d)" % [grid.x, grid.y])
	_update_stats()


func _teleport_to_cell(cell_x: int, cell_y: int) -> void:
	if not terrain_3d:
		return

	# Clear load queue for faster response when teleporting
	if world_streaming_manager and world_streaming_manager.has_method("clear_load_queue"):
		world_streaming_manager.clear_load_queue()

	# Calculate cell center position in Godot coordinates
	# X: cell origin is west edge, add half to get center
	# Z: cell origin (SW corner) is at (-cell_y * size), which is the SOUTH edge
	#    To get center, we need to move NORTH (decrease Z), so subtract half
	var region_world_size := 64.0 * terrain_3d.get_vertex_spacing()
	var world_x := float(cell_x) * region_world_size + region_world_size * 0.5
	var world_z := float(-cell_y) * region_world_size - region_world_size * 0.5

	var height := 50.0
	if terrain_3d.data:
		height = terrain_3d.data.get_height(Vector3(world_x, 0, world_z))
		if is_nan(height) or height > 10000:
			height = 50.0

	camera.position = Vector3(world_x, height + 100.0, world_z + 50.0)
	camera.look_at(Vector3(world_x, height, world_z))
	_log("Teleported to cell (%d, %d)" % [cell_x, cell_y])


func _update_stats() -> void:
	if not world_streaming_manager:
		return

	var stats: Dictionary = world_streaming_manager.get_stats()
	@warning_ignore("unused_variable")
	var region_count: int = terrain_3d.data.get_region_count() if terrain_3d and terrain_3d.data else 0

	# Get profiler data
	var fps := 0.0
	var frame_ms := 0.0
	var draw_calls := 0
	var primitives := 0
	var mem_mb := 0.0
	var p95_ms := 0.0

	if profiler:
		fps = profiler.get_fps()
		frame_ms = profiler.get_avg_frame_time_ms()
		var render: Dictionary = profiler.get_render_stats()
		draw_calls = int(render.draw_calls)
		primitives = int(render.primitives)
		var mem: Dictionary = profiler.get_memory_stats()
		mem_mb = float(mem.static_memory_mb)
		var percentiles: Dictionary = profiler.get_frame_time_percentiles()
		p95_ms = float(percentiles.p95)

	# Get LOD stats
	var lod_full: int = stats.get("lod_objects_full", 0)
	var lod_low: int = stats.get("lod_objects_low", 0)
	var lod_culled: int = stats.get("lod_objects_culled", 0)
	var lod_total: int = stats.get("lod_total_tracked", 0)

	stats_text.text = """[b]Performance[/b]
FPS: %.1f (%.2f ms)
P95: %.2f ms
Draw calls: %d
Primitives: %dk
Memory: %.1f MB

[b]Streaming[/b]
Loaded cells: %d
Queue: %d (peak: %d)
View dist: %d cells [+/-]

[b]LOD[/b]
Full/Low/Culled: %d/%d/%d
Total tracked: %d

[b]Camera[/b]
Cell: (%d, %d)

[color=gray]F3: Overlay | F4: Report[/color]""" % [
		fps, frame_ms,
		p95_ms,
		draw_calls,
		primitives / 1000.0,
		mem_mb,
		stats.get("loaded_cells", 0),
		stats.get("load_queue_size", 0),
		stats.get("queue_high_water_mark", 0),
		_current_view_distance,
		lod_full, lod_low, lod_culled,
		lod_total,
		stats.get("camera_cell", Vector2i(0, 0)).x,
		stats.get("camera_cell", Vector2i(0, 0)).y,
	]


# ==================== UI Helpers ====================

func _show_loading(title: String, status: String) -> void:
	loading_overlay.visible = true
	loading_label.text = title
	status_label.text = status
	progress_bar.value = 0


func _hide_loading() -> void:
	loading_overlay.visible = false


func _update_loading(progress: float, status: String) -> void:
	progress_bar.value = progress
	status_label.text = status
	await get_tree().process_frame


func _log(message: String) -> void:
	if log_text:
		log_text.append_text(message + "\n")
	print(message.replace("[color=green]", "").replace("[color=red]", "").replace("[color=yellow]", "").replace("[/color]", "").replace("[b]", "").replace("[/b]", ""))


# ==================== Camera Controls ====================

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				mouse_captured = true
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
				mouse_captured = false

	if event is InputEventMouseMotion and mouse_captured:
		camera.rotate_y(-event.relative.x * mouse_sensitivity)
		camera.rotate_object_local(Vector3.RIGHT, -event.relative.y * mouse_sensitivity)

	# Profiling hotkeys
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_F3:
				# Toggle performance overlay
				_perf_overlay_visible = not _perf_overlay_visible
				stats_panel.visible = _perf_overlay_visible
				_log("Performance overlay: %s" % ("ON" if _perf_overlay_visible else "OFF"))
			KEY_F4:
				# Dump detailed profiling report
				_dump_profiling_report()
			KEY_EQUAL, KEY_KP_ADD:  # + key
				_adjust_view_distance(1)
			KEY_MINUS, KEY_KP_SUBTRACT:  # - key
				_adjust_view_distance(-1)


func _process(delta: float) -> void:
	if not _initialized:
		return

	# Record frame timing for profiler
	if profiler:
		profiler.record_frame(delta)

	# Update stats periodically
	if Engine.get_frames_drawn() % 30 == 0:
		_update_stats()

	if not mouse_captured:
		return

	# WASD movement
	var input_dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		input_dir.z -= 1
	if Input.is_key_pressed(KEY_S):
		input_dir.z += 1
	if Input.is_key_pressed(KEY_A):
		input_dir.x -= 1
	if Input.is_key_pressed(KEY_D):
		input_dir.x += 1
	if Input.is_key_pressed(KEY_SPACE):
		input_dir.y += 1
	if Input.is_key_pressed(KEY_SHIFT):
		input_dir.y -= 1

	var speed := camera_speed
	if Input.is_key_pressed(KEY_CTRL):
		speed *= 3.0

	if input_dir != Vector3.ZERO:
		var move_dir := camera.global_transform.basis * input_dir.normalized()
		camera.position += move_dir * speed * delta


## Adjust view distance and update streaming manager
func _adjust_view_distance(delta: int) -> void:
	_current_view_distance = clampi(_current_view_distance + delta, 1, 8)
	if world_streaming_manager:
		world_streaming_manager.view_distance_cells = _current_view_distance
		world_streaming_manager.refresh_cells()
	_log("View distance: %d cells (~%dm)" % [_current_view_distance, _current_view_distance * 117])
	_update_stats()


## Dump detailed profiling report to console and log
func _dump_profiling_report() -> void:
	if not profiler:
		_log("[color=red]Profiler not initialized[/color]")
		return

	# Count lights in scene
	profiler.count_lights(self)

	var report: Dictionary = profiler.get_report()

	# Log summary
	_log("\n[b]====== PROFILING REPORT ======[/b]")
	_log("Session duration: %.1f seconds" % report.session.duration_sec)
	_log("")
	_log("[b]Frame Timing[/b]")
	_log("  FPS: %.1f (%.2f ms avg)" % [report.frame_timing.fps, report.frame_timing.avg_ms])
	_log("  P50: %.2f ms | P95: %.2f ms | P99: %.2f ms" % [
		report.frame_timing.p50_ms, report.frame_timing.p95_ms, report.frame_timing.p99_ms
	])
	_log("  Max frame: %.2f ms" % report.frame_timing.max_ms)
	_log("")
	_log("[b]Rendering[/b]")
	_log("  Draw calls: %d (peak: %d)" % [report.rendering.draw_calls, report.rendering.peak_draw_calls])
	_log("  Primitives: %d (peak: %d)" % [report.rendering.primitives, report.rendering.peak_primitives])
	_log("  Objects visible: %d" % report.rendering.objects_visible)
	_log("")
	_log("[b]Memory[/b]")
	_log("  Static: %.1f MB" % report.memory.static_memory_mb)
	_log("  Nodes: %d | Resources: %d" % [report.memory.nodes_in_tree, report.memory.resources_in_use])
	_log("")
	_log("[b]Cell Loading[/b]")
	_log("  Cells loaded: %d" % report.session.total_cells_loaded)
	_log("  Objects loaded: %d" % report.session.total_objects_loaded)
	_log("  Avg load time: %.1f ms" % report.cell_loading.avg_load_time_ms)
	_log("")
	_log("[b]Lights[/b]")
	_log("  Total: %d | With shadows: %d" % [report.lights.total, report.lights.with_shadows])

	if report.materials and not report.materials.is_empty():
		_log("")
		_log("[b]Materials[/b]")
		_log("  Unique materials: %d" % report.materials.get("cached_materials", 0))
		_log("  Cache hits: %d" % report.materials.get("cache_hits", 0))
		_log("  Hit rate: %.1f%%" % (report.materials.get("hit_rate", 0.0) * 100.0))

	if report.textures and not report.textures.is_empty():
		_log("")
		_log("[b]Textures[/b]")
		_log("  Loaded: %d" % report.textures.get("textures_loaded", 0))
		_log("  Cache hits: %d" % report.textures.get("cache_hits", 0))

	# Add object pool stats
	if cell_manager:
		var cell_stats: Dictionary = cell_manager.get_stats()
		if cell_stats.get("pool_available", 0) > 0 or cell_stats.get("pool_in_use", 0) > 0:
			_log("")
			_log("[b]Object Pool[/b]")
			_log("  Available: %d | In use: %d" % [
				cell_stats.get("pool_available", 0),
				cell_stats.get("pool_in_use", 0)
			])
			_log("  From pool: %d" % cell_stats.get("objects_from_pool", 0))
			_log("  Hit rate: %.1f%%" % (cell_stats.get("pool_hit_rate", 0.0) * 100.0))

	if not report.slowest_models.is_empty():
		_log("")
		_log("[b]Slowest Models[/b]")
		for model in report.slowest_models:
			_log("  %.2f ms - %s (x%d)" % [model.avg_ms, model.path.get_file(), model.count])

	_log("[b]==============================[/b]")

	# Also print full report to console for easy copying
	print("\n" + JSON.stringify(report, "  "))
