## StreamingTestScene - Minimal test scene for distant rendering pipeline debugging
##
## This scene provides:
## - Automated camera path for consistent testing
## - Comprehensive logging of all streaming events
## - No terrain (faster load, simpler debugging)
## - Automatic Models toggle on startup
## - Detailed stats display for LODs, impostors, tiers
##
## Usage: Run this scene directly to test the streaming pipeline
## The camera will automatically fly through the world and log all events
##
## Controls:
## - Hold Right-click + WASD to fly (same as world explorer)
## - Scroll wheel to adjust speed
## - Ctrl for speed boost
## - [D] Run diagnostics
## - [P] Toggle auto camera path
## - [1/2/3] Teleport to Seyda Neen/Balmora/Vivec
@tool
class_name StreamingTestScene
extends Node3D

# Preload dependencies
const WorldStreamingManagerScript := preload("res://src/core/world/world_streaming_manager.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const BackgroundProcessorScript := preload("res://src/core/streaming/background_processor.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const DU := preload("res://src/core/world/distance_utils.gd")
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")
const FlyCameraScript := preload("res://src/core/player/fly_camera.gd")

# Managers
var world_streaming_manager: WorldStreamingManager = null
var cell_manager: CellManager = null
var background_processor: BackgroundProcessor = null

# Camera
var camera: Camera3D = null
var camera_speed: float = 50.0  # meters per second
var camera_path_active: bool = false
var camera_path_index: int = 0
var camera_path_timer: float = 0.0

# Test path waypoints (cell coordinates)
var test_waypoints: Array[Vector2i] = [
	Vector2i(-2, -9),   # Seyda Neen
	Vector2i(-2, -8),   # North of Seyda Neen
	Vector2i(-1, -8),   # East
	Vector2i(-1, -9),   # Back south
	Vector2i(-2, -9),   # Return to start
]
var current_target: Vector3 = Vector3.ZERO
var waypoint_hold_time: float = 3.0  # seconds to wait at each waypoint

# UI
var stats_label: RichTextLabel = null
var log_label: RichTextLabel = null
var log_lines: Array[String] = []
const MAX_LOG_LINES: int = 50

# State
var _initialized: bool = false
var _data_path: String = ""
var _update_timer: float = 0.0
const UPDATE_INTERVAL: float = 0.5  # Update stats every 0.5 seconds

# Diagnostic counters
var _diag: Dictionary = {
	"objects_registered": 0,
	"objects_significant": 0,
	"objects_non_significant": 0,
	"lods_loaded": 0,
	"lods_failed": 0,
	"impostors_created": 0,
	"impostors_failed": 0,
	"tier_near": 0,
	"tier_mid": 0,
	"tier_far": 0,
	"tier_hidden": 0,
}


func _ready() -> void:
	_log("=== StreamingTestScene Starting ===")
	_log("Distance constants from DU:")
	_log("  NEAR_END: %.0fm" % DU.NEAR_END)
	_log("  MID_END: %.0fm" % DU.MID_END)
	_log("  FAR_END: %.0fm" % DU.FAR_END)
	_log("  FADE_MARGIN: %.0fm" % DU.FADE_MARGIN)

	_setup_scene()
	_setup_ui()

	# Start async initialization
	call_deferred("_init_async")


func _setup_scene() -> void:
	# Create fly camera (same controls as world explorer)
	camera = FlyCameraScript.new()
	camera.name = "TestCamera"
	camera.far = 20000.0  # 20km for distant impostors
	camera.current = true
	camera.move_speed = 100.0  # Start slower for close inspection
	add_child(camera)

	# Create environment with simple sky
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.3, 0.5, 0.8)
	sky_mat.sky_horizon_color = Color(0.6, 0.7, 0.8)
	sky_mat.ground_bottom_color = Color(0.2, 0.15, 0.1)
	sky_mat.ground_horizon_color = Color(0.5, 0.45, 0.4)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.5

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	# Create directional light
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-45, 30, 0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	add_child(sun)


func _setup_ui() -> void:
	# Create UI canvas
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	# Stats panel (left side)
	var stats_panel := Panel.new()
	stats_panel.name = "StatsPanel"
	stats_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	stats_panel.offset_right = 400
	stats_panel.offset_bottom = 600
	stats_panel.offset_left = 10
	stats_panel.offset_top = 10
	canvas.add_child(stats_panel)

	stats_label = RichTextLabel.new()
	stats_label.name = "StatsLabel"
	stats_label.bbcode_enabled = true
	stats_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stats_label.add_theme_font_size_override("normal_font_size", 12)
	stats_panel.add_child(stats_label)

	# Log panel (right side)
	var log_panel := Panel.new()
	log_panel.name = "LogPanel"
	log_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	log_panel.offset_left = -410
	log_panel.offset_right = -10
	log_panel.offset_top = 10
	log_panel.offset_bottom = 600
	canvas.add_child(log_panel)

	log_label = RichTextLabel.new()
	log_label.name = "LogLabel"
	log_label.bbcode_enabled = true
	log_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	log_label.add_theme_font_size_override("normal_font_size", 11)
	log_label.scroll_following = true
	log_panel.add_child(log_label)

	# Control buttons at bottom
	var btn_container := HBoxContainer.new()
	btn_container.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	btn_container.offset_top = -40
	btn_container.offset_left = 10
	btn_container.offset_right = -10
	btn_container.offset_bottom = -10
	canvas.add_child(btn_container)

	var start_path_btn := Button.new()
	start_path_btn.text = "Start Camera Path [P]"
	start_path_btn.pressed.connect(_toggle_camera_path)
	btn_container.add_child(start_path_btn)

	var teleport_btn := Button.new()
	teleport_btn.text = "Teleport to Seyda Neen [1]"
	teleport_btn.pressed.connect(func(): _teleport_to_cell(-2, -9))
	btn_container.add_child(teleport_btn)

	var reload_btn := Button.new()
	reload_btn.text = "Reload Cells [R]"
	reload_btn.pressed.connect(_reload_cells)
	btn_container.add_child(reload_btn)

	var diag_btn := Button.new()
	diag_btn.text = "Run Diagnostics [D]"
	diag_btn.pressed.connect(_run_diagnostics)
	btn_container.add_child(diag_btn)


func _init_async() -> void:
	_log("Loading game data...")

	# Get data path
	_data_path = SettingsManager.get_data_path()
	if _data_path.is_empty():
		_data_path = SettingsManager.auto_detect_installation()
		if _data_path.is_empty():
			_log("[color=red]ERROR: Morrowind data path not found![/color]")
			return
		SettingsManager.set_data_path(_data_path)

	_log("Data path: %s" % _data_path)

	# Load BSA archives
	var bsa_count := BSAManager.load_archives_from_directory(_data_path)
	_log("Loaded %d BSA archives" % bsa_count)

	# Load ESM
	var esm_file: String = SettingsManager.get_esm_file()
	var esm_path := _data_path.path_join(esm_file)
	var error := ESMManager.load_file(esm_path)
	if error != OK:
		_log("[color=red]ERROR: Failed to load ESM: %s[/color]" % error_string(error))
		return

	_log("ESM loaded: %d cells, %d lands" % [ESMManager.cells.size(), ESMManager.lands.size()])

	# Check cache directories
	_log("Cache paths:")
	_log("  Models: %s" % SettingsManager.get_models_path())
	_log("  Impostors: %s" % SettingsManager.get_impostors_path())
	_log("  NOTE: LODs are now embedded in prebaked models (no separate LOD files)")

	# Check if impostors exist
	var impostor_path := SettingsManager.get_impostors_path()
	if DirAccess.dir_exists_absolute(impostor_path):
		var imp_files := DirAccess.get_files_at(impostor_path)
		var png_count := 0
		for f in imp_files:
			if f.ends_with(".png"):
				png_count += 1
		_log("  Impostor textures found: %d" % png_count)
	else:
		_log("[color=yellow]  WARNING: Impostor directory not found![/color]")

	# Initialize background processor
	background_processor = BackgroundProcessorScript.new()
	background_processor.name = "BackgroundProcessor"
	add_child(background_processor)

	# Initialize cell manager
	cell_manager = CellManagerScript.new()
	cell_manager.load_npcs = false
	cell_manager.load_creatures = false
	cell_manager.init_object_pool()
	cell_manager.set_background_processor(background_processor)

	# Setup world streaming manager
	_setup_world_streaming_manager()

	# Teleport to Seyda Neen
	_teleport_to_cell(-2, -9)

	# Start tracking camera
	world_streaming_manager.set_tracked_node(camera)

	# Enable models (this is what user would do with the toggle)
	_enable_models()

	_initialized = true
	_log("[color=green]=== Initialization Complete ===[/color]")
	_log("Press [P] to start camera path test")
	_log("Press [D] to run diagnostics")

	# Auto-run diagnostics after a short delay (for headless testing)
	get_tree().create_timer(3.0).timeout.connect(_run_diagnostics)


func _setup_world_streaming_manager() -> void:
	var wsm_node := Node3D.new()
	wsm_node.set_script(WorldStreamingManagerScript)
	wsm_node.name = "WorldStreamingManager"
	world_streaming_manager = wsm_node as WorldStreamingManager

	# Configure for testing
	world_streaming_manager.view_distance_cells = 3
	world_streaming_manager.load_objects = true
	world_streaming_manager.distant_rendering_enabled = true
	world_streaming_manager.debug_enabled = true

	add_child(world_streaming_manager)

	# Connect signals
	world_streaming_manager.cell_loaded.connect(_on_cell_loaded)
	world_streaming_manager.cell_unloaded.connect(_on_cell_unloaded)

	# Provide cell manager
	world_streaming_manager.set_cell_manager(cell_manager)
	world_streaming_manager.set_background_processor(background_processor)

	# Initialize
	world_streaming_manager.initialize()

	_log("WorldStreamingManager created")

	# Hook into ObjectStreamer for detailed logging
	_hook_object_streamer()


func _hook_object_streamer() -> void:
	var object_streamer = world_streaming_manager.get_node_or_null("ObjectStreamer")
	if object_streamer:
		_log("ObjectStreamer found, debug_enabled=%s" % object_streamer.debug_enabled)
		object_streamer.debug_enabled = true
	else:
		_log("[color=yellow]ObjectStreamer not found![/color]")

	var impostor_mgr = world_streaming_manager.get_node_or_null("ImpostorManager")
	if impostor_mgr:
		_log("ImpostorManager found, debug_enabled=%s" % impostor_mgr.debug_enabled)
		impostor_mgr.debug_enabled = true
	else:
		_log("[color=yellow]ImpostorManager not found![/color]")

	var dist_tier_mgr = world_streaming_manager.get_node_or_null("DistanceTierManager")
	if dist_tier_mgr:
		_log("DistanceTierManager found")
	else:
		_log("[color=yellow]DistanceTierManager not found![/color]")


func _enable_models() -> void:
	_log("Enabling models (like toggling Models button)...")

	if not world_streaming_manager:
		_log("[color=red]WorldStreamingManager not ready![/color]")
		return

	world_streaming_manager.load_objects = true

	# Enable all tiers in ObjectStreamer
	var object_streamer = world_streaming_manager.get_node_or_null("ObjectStreamer")
	if object_streamer:
		if object_streamer.has_method("set_near_visible"):
			object_streamer.set_near_visible(true)
			object_streamer.set_mid_visible(true)
			object_streamer.set_far_visible(true)
			_log("ObjectStreamer tiers enabled: NEAR, MID, FAR")

		if "enabled" in object_streamer:
			object_streamer.enabled = true
			_log("ObjectStreamer.enabled = true")

	# Enable impostors
	var impostor_mgr = world_streaming_manager.get_node_or_null("ImpostorManager")
	if impostor_mgr and impostor_mgr.has_method("set_all_visible"):
		impostor_mgr.call("set_all_visible", true)
		_log("ImpostorManager visibility enabled")


func _on_cell_loaded(grid: Vector2i, node: Node3D) -> void:
	var obj_count := node.get_child_count()
	_log("Cell loaded: (%d, %d) with %d objects" % [grid.x, grid.y, obj_count])

	# Count significant vs non-significant
	_analyze_cell_objects(grid, node)


func _on_cell_unloaded(grid: Vector2i) -> void:
	_log("Cell unloaded: (%d, %d)" % [grid.x, grid.y])


func _analyze_cell_objects(grid: Vector2i, node: Node3D) -> void:
	var candidates := ImpostorCandidatesScript.new()
	var sig_count := 0
	var non_sig_count := 0

	for child in node.get_children():
		if child.has_meta("model_path"):
			var model_path: String = child.get_meta("model_path")
			if candidates.should_have_impostor(model_path):
				sig_count += 1
			else:
				non_sig_count += 1

	if sig_count > 0 or non_sig_count > 0:
		_log("  Cell (%d,%d): %d significant, %d non-significant" % [grid.x, grid.y, sig_count, non_sig_count])


func _teleport_to_cell(cell_x: int, cell_y: int) -> void:
	var cell_world_size := CS.CELL_SIZE_GODOT
	var world_x := float(cell_x) * cell_world_size + cell_world_size * 0.5
	var world_z := float(-cell_y) * cell_world_size - cell_world_size * 0.5
	# Lower camera height to get NEAR tier objects (objects on ground are ~0-20m high)
	var height := 30.0

	camera.position = Vector3(world_x, height, world_z)
	camera.rotation_degrees = Vector3(-15, 0, 0)

	_log("Teleported to cell (%d, %d) -> (%.0f, %.0f, %.0f)" % [cell_x, cell_y, world_x, height, world_z])


func _toggle_camera_path() -> void:
	camera_path_active = not camera_path_active
	if camera_path_active:
		camera_path_index = 0
		camera_path_timer = 0.0
		_set_waypoint_target(0)
		_log("[color=cyan]Camera path started[/color]")
	else:
		_log("[color=cyan]Camera path stopped[/color]")


func _set_waypoint_target(index: int) -> void:
	if index >= test_waypoints.size():
		camera_path_active = false
		_log("[color=green]Camera path complete![/color]")
		return

	var wp := test_waypoints[index]
	var cell_world_size := CS.CELL_SIZE_GODOT
	current_target = Vector3(
		float(wp.x) * cell_world_size + cell_world_size * 0.5,
		30.0,  # Lower height to see NEAR tier objects
		float(-wp.y) * cell_world_size - cell_world_size * 0.5
	)
	_log("Moving to waypoint %d: cell (%d, %d)" % [index, wp.x, wp.y])


func _reload_cells() -> void:
	_log("Reloading cells...")
	if world_streaming_manager and world_streaming_manager.has_method("reload_all_cells"):
		world_streaming_manager.reload_all_cells()


func _run_diagnostics() -> void:
	_log("")
	_log("[color=yellow]=== RUNNING DIAGNOSTICS ===[/color]")

	if not world_streaming_manager:
		_log("[color=red]WorldStreamingManager not initialized![/color]")
		return

	# Check camera position (critical for tier calculations)
	_log("[Camera Position]")
	_log("  Camera position: %s" % camera.global_position)
	var cam_cell := DU.world_to_cell(camera.global_position)
	_log("  Camera cell: %s" % cam_cell)

	# Check ObjectStreamer state
	var object_streamer = world_streaming_manager.get_node_or_null("ObjectStreamer")
	if object_streamer:
		_log("")
		_log("[ObjectStreamer State]")
		_log("  enabled: %s" % object_streamer.enabled)
		_log("  near_tier_visible: %s" % object_streamer.near_tier_visible)
		_log("  mid_tier_visible: %s" % object_streamer.mid_tier_visible)
		_log("  far_tier_visible: %s" % object_streamer.far_tier_visible)
		# Show internal camera position to detect initialization issues
		if "_camera_pos" in object_streamer:
			_log("  _camera_pos: %s" % object_streamer._camera_pos)

		if object_streamer.has_method("get_stats"):
			var stats: Dictionary = object_streamer.get_stats()
			_log("  total_objects: %d" % stats.get("total_objects", 0))
			_log("  near_visible: %d" % stats.get("near_visible", 0))
			_log("  mid_visible: %d" % stats.get("mid_visible", 0))
			_log("  far_visible: %d" % stats.get("far_visible", 0))
			_log("  hidden: %d" % stats.get("hidden", 0))

		# Get detailed debug info
		if object_streamer.has_method("get_debug_info"):
			var debug_info: Dictionary = object_streamer.get_debug_info()
			_log("  significant_objects: %d" % debug_info.get("significant_objects", 0))
			_log("  lods_loaded: %d" % debug_info.get("lods_loaded", 0))
			_log("  impostor_candidates_set: %s" % debug_info.get("impostor_candidates_set", false))
			_log("  distance_tier_manager_set: %s" % debug_info.get("distance_tier_manager_set", false))
			_log("  batcher_set: %s" % debug_info.get("batcher_set", false))
			_log("  aaa_registered: %d" % debug_info.get("aaa_registered_objects", 0))
			_log("  internal_camera_pos: %s" % debug_info.get("camera_pos", Vector3.ZERO))

			# Position index info
			var pos_idx_info: Dictionary = debug_info.get("position_index", {})
			if pos_idx_info.get("set", false):
				_log("  [color=green]position_index: SET[/color]")
				_log("    is_built: %s" % pos_idx_info.get("is_built", false))
				_log("    total_objects: %d" % pos_idx_info.get("total_objects", 0))
			else:
				_log("  [color=red]position_index: NOT SET[/color]")

			# Show sample objects
			var samples: Array = debug_info.get("sample_objects", [])
			if not samples.is_empty():
				_log("  Sample objects:")
				for sample: Dictionary in samples:
					_log("    %s: sig=%s tier=%d lods=%d dist=%.0fm" % [
						sample.get("model", "?"),
						sample.get("significant", false),
						sample.get("tier", -1),
						sample.get("lod_count", 0),
						sample.get("distance", 0.0)
					])
	else:
		_log("[color=red]ObjectStreamer not found![/color]")

	# Check ImpostorManager state
	var impostor_mgr = world_streaming_manager.get_node_or_null("ImpostorManager")
	if impostor_mgr:
		_log("")
		_log("[ImpostorManager State]")

		if impostor_mgr.has_method("get_stats"):
			var stats: Dictionary = impostor_mgr.get_stats()
			_log("  total_impostors: %d" % stats.get("total_impostors", 0))
			_log("  visible_impostors: %d" % stats.get("visible_impostors", 0))
			_log("  texture_cache_size: %d" % stats.get("texture_cache_size", 0))
			_log("  texture_array_layers: %d" % stats.get("texture_array_layers", 0))
			_log("  pending_loads: %d" % stats.get("pending_loads", 0))
			_log("  cells_with_impostors: %d" % stats.get("cells_with_impostors", 0))
	else:
		_log("[color=red]ImpostorManager not found![/color]")

	# Check DistanceTierManager
	var dist_tier_mgr = world_streaming_manager.get_node_or_null("DistanceTierManager")
	if dist_tier_mgr:
		_log("")
		_log("[DistanceTierManager State]")
		if dist_tier_mgr.has_method("get_stats"):
			var stats: Dictionary = dist_tier_mgr.get_stats()
			_log("  registered_objects: %d" % stats.get("registered_objects", 0))
			_log("  near_cells: %d" % stats.get("near_cells", 0))
			_log("  mid_cells: %d" % stats.get("mid_cells", 0))
			_log("  far_cells: %d" % stats.get("far_cells", 0))

	# Check ObjectPositionIndex
	_log("")
	_log("[ObjectPositionIndex State]")
	if "object_position_index" in world_streaming_manager and world_streaming_manager.object_position_index:
		var pos_idx = world_streaming_manager.object_position_index
		if pos_idx.has_method("get_stats"):
			var stats: Dictionary = pos_idx.get_stats()
			_log("  is_built: %s" % stats.get("is_built", false))
			_log("  total_objects: %d" % stats.get("total_objects", 0))
			_log("  cells_indexed: %d" % stats.get("cells_indexed", 0))
			_log("  hash_cells: %d" % stats.get("hash_cells", 0))

		# Test a query from camera position
		if pos_idx.has_method("get_objects_within_radius"):
			var nearby = pos_idx.get_objects_within_radius(camera.global_position, 500.0, false)
			_log("  objects within 500m: %d" % nearby.size())
	else:
		_log("  [color=red]Not set or null![/color]")

	# Check if ObjectStreamer has position index
	if object_streamer and "_position_index" in object_streamer:
		if object_streamer._position_index:
			_log("  ObjectStreamer._position_index: SET")
		else:
			_log("  [color=red]ObjectStreamer._position_index: NULL[/color]")

	# Test LOD extraction from ObjectStreamer cache
	# LODs are now embedded in models, not in separate files
	_log("")
	_log("[Embedded LOD System]")
	_log("  LODs are now embedded in prebaked models via NIFConverter")
	_log("  LOD meshes are extracted from scene tree when models enter NEAR tier")

	if object_streamer and object_streamer.has_method("get_stats"):
		var os_stats: Dictionary = object_streamer.get_stats()
		_log("  ObjectStreamer LOD cache size: %d" % os_stats.get("lod_cache_size", 0))
		_log("  ObjectStreamer LOD cache hits: %d" % os_stats.get("lod_cache_hits", 0))

	# Test impostor texture loading
	_log("")
	_log("[Impostor Texture Test]")
	var test_paths: Array[String] = [
		"meshes/x/ex_vivec_palace_01.nif",
		"meshes/x/ex_hlaalu_b_01.nif",
		"meshes/x/ex_stronghold_enter00.nif",
		"meshes/x/ex_dwe_tower00.nif",
	]
	for test_path in test_paths:
		var tex_path := ImpostorCandidatesScript.get_impostor_texture_path(test_path)
		var exists := FileAccess.file_exists(tex_path)
		if exists:
			_log("  [color=green]%s: Texture exists[/color]" % test_path.get_file())
		else:
			_log("  [color=red]%s: No texture at %s[/color]" % [test_path.get_file(), tex_path])

	_log("")
	_log("[color=yellow]=== DIAGNOSTICS COMPLETE ===[/color]")


func _process(delta: float) -> void:
	if not _initialized:
		return

	# Handle camera path movement
	if camera_path_active:
		_update_camera_path(delta)

	# Handle keyboard input
	_handle_input()

	# Update stats display
	_update_timer += delta
	if _update_timer >= UPDATE_INTERVAL:
		_update_timer = 0.0
		_update_stats_display()


func _update_camera_path(delta: float) -> void:
	var to_target := current_target - camera.position
	var dist := to_target.length()

	if dist < 10.0:
		# Reached waypoint, wait then move to next
		camera_path_timer += delta
		if camera_path_timer >= waypoint_hold_time:
			camera_path_timer = 0.0
			camera_path_index += 1
			_set_waypoint_target(camera_path_index)
	else:
		# Move towards target
		var move_dir := to_target.normalized()
		camera.position += move_dir * camera_speed * delta

		# Look at target
		camera.look_at(current_target, Vector3.UP)


func _handle_input() -> void:
	# FlyCamera handles movement via right-click + WASD
	# We only need to disable it during auto camera path
	if camera.has_method("enable") and camera.has_method("disable"):
		if camera_path_active:
			camera.call("disable")
		else:
			camera.call("enable")


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_P:
				_toggle_camera_path()
			KEY_1:
				_teleport_to_cell(-2, -9)  # Seyda Neen
			KEY_2:
				_teleport_to_cell(-3, -2)  # Balmora
			KEY_3:
				_teleport_to_cell(5, -6)   # Vivec
			KEY_R:
				_reload_cells()
			KEY_D:
				_run_diagnostics()


func _update_stats_display() -> void:
	if not stats_label or not world_streaming_manager:
		return

	var text := "[b]Streaming Test Scene[/b]\n\n"

	# Camera info
	var cam_cell := DU.world_to_cell(camera.position)
	text += "[u]Camera[/u]\n"
	text += "Position: (%.0f, %.0f, %.0f)\n" % [camera.position.x, camera.position.y, camera.position.z]
	text += "Cell: (%d, %d)\n" % [cam_cell.x, cam_cell.y]
	text += "Path: %s\n\n" % ("Active" if camera_path_active else "Inactive")

	# WorldStreamingManager stats
	if world_streaming_manager.has_method("get_stats"):
		var wsm_stats: Dictionary = world_streaming_manager.get_stats()
		text += "[u]WorldStreamingManager[/u]\n"
		text += "Loaded cells: %d\n" % wsm_stats.get("loaded_cells", 0)
		text += "Queue size: %d\n\n" % wsm_stats.get("queue_size", 0)

	# ObjectStreamer stats
	var object_streamer = world_streaming_manager.get_node_or_null("ObjectStreamer")
	if object_streamer and object_streamer.has_method("get_stats"):
		var os_stats: Dictionary = object_streamer.get_stats()
		text += "[u]ObjectStreamer[/u]\n"
		text += "Total: %d\n" % os_stats.get("total_objects", 0)
		text += "NEAR: [color=green]%d[/color]\n" % os_stats.get("near_visible", 0)
		text += "MID: [color=yellow]%d[/color]\n" % os_stats.get("mid_visible", 0)
		text += "FAR: [color=orange]%d[/color]\n" % os_stats.get("far_visible", 0)
		text += "Hidden: [color=gray]%d[/color]\n\n" % os_stats.get("hidden", 0)

	# ImpostorManager stats
	var impostor_mgr = world_streaming_manager.get_node_or_null("ImpostorManager")
	if impostor_mgr and impostor_mgr.has_method("get_stats"):
		var imp_stats: Dictionary = impostor_mgr.get_stats()
		text += "[u]ImpostorManager[/u]\n"
		text += "Total: %d\n" % imp_stats.get("total_impostors", 0)
		text += "Visible: %d\n" % imp_stats.get("visible_impostors", 0)
		text += "Textures: %d\n" % imp_stats.get("texture_cache_size", 0)
		text += "Tex Layers: %d\n" % imp_stats.get("texture_array_layers", 0)
		text += "Pending: %d\n\n" % imp_stats.get("pending_loads", 0)

	# FPS
	text += "[u]Performance[/u]\n"
	text += "FPS: %.1f\n" % Engine.get_frames_per_second()

	stats_label.text = text


func _log(message: String) -> void:
	var timestamp := "%.2f" % (Time.get_ticks_msec() / 1000.0)
	var line := "[%s] %s" % [timestamp, message]

	log_lines.append(line)
	if log_lines.size() > MAX_LOG_LINES:
		log_lines.pop_front()

	if log_label:
		log_label.text = "\n".join(log_lines)

	# Also print to console
	print(line)
