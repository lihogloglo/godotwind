## La Palma Explorer - Explore the volcanic island of La Palma
##
## Features:
## - Terrain streaming from preprocessed GeoTIFF heightmaps
## - Proper region unloading to prevent memory leaks
## - Free-fly camera navigation
##
## Controls:
## - ZQSD/WASD to move, Right-click to look
## - Space/Shift for up/down
## - Ctrl for speed boost
## - +/- to adjust view distance
## - Press F3 to toggle stats overlay
## - Press F4 to force cleanup distant regions
extends Node3D

const LaPalmaDataProviderScript := preload("res://src/core/world/lapalma_data_provider.gd")
const GenericTerrainStreamerScript := preload("res://src/core/world/generic_terrain_streamer.gd")

# Preprocessed data directory
const DATA_DIR := "res://lapalma_processed"

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
@onready var roque_btn: Button = $UI/StatsPanel/VBox/QuickButtons/RoqueBtn
@onready var caldera_btn: Button = $UI/StatsPanel/VBox/QuickButtons/CalderaBtn
@onready var coast_btn: Button = $UI/StatsPanel/VBox/QuickButtons/CoastBtn
@onready var origin_btn: Button = $UI/StatsPanel/VBox/QuickButtons/OriginBtn

# Managers
var _provider: RefCounted = null  # LaPalmaDataProvider
var _streamer: Node = null  # GenericTerrainStreamer

# Camera controls
var camera_speed: float = 300.0
var mouse_sensitivity: float = 0.003
var mouse_captured: bool = false

# State
var _initialized: bool = false
var _stats_visible: bool = true
# REDUCED from 6 to 3 for much better performance!
# Each region = 1.536km, so 3 regions = ~4.6km view distance
var _current_view_distance: int = 3


func _ready() -> void:
	# Connect quick teleport buttons
	# World bounds: ~34km x 48km, centered at origin
	# X range: -16896 to +16896, Z range: -23808 to +23808
	# Highest point (Roque) is around region (1, 6) -> world pos ~(2300, 0, -10000)
	roque_btn.pressed.connect(func(): _teleport_to_position(Vector3(2000, 2500, -10000)))  # Roque de los Muchachos
	caldera_btn.pressed.connect(func(): _teleport_to_position(Vector3(-3000, 1500, -12000)))  # Caldera de Taburiente
	coast_btn.pressed.connect(func(): _teleport_to_position(Vector3(8000, 200, -8000)))  # East coast
	origin_btn.pressed.connect(func(): _teleport_to_position(Vector3(0, 500, 0)))  # Origin (center)

	# Start async initialization
	_show_loading("Initializing La Palma World", "Loading terrain data...")
	call_deferred("_init_async")


func _init_async() -> void:
	await _update_loading(10, "Creating data provider...")

	# Create La Palma data provider
	_provider = LaPalmaDataProviderScript.new(DATA_DIR)
	var err: Error = _provider.initialize()

	if err != OK:
		_log("[color=red]ERROR: Failed to initialize La Palma data[/color]")
		_log("Run 'python3 tools/preprocess_lapalma.py' first")
		_hide_loading()
		return

	_log("[color=green]La Palma data loaded[/color]")
	_log("World: %.1f x %.1f km" % [
		_provider.world_bounds.size.x / 1000.0,
		_provider.world_bounds.size.y / 1000.0
	])
	_log("Regions: %d terrain regions" % _provider.get_all_terrain_regions().size())

	await _update_loading(40, "Configuring Terrain3D...")
	_init_terrain3d()

	await _update_loading(60, "Setting up terrain streamer...")
	_setup_streamer()

	await _update_loading(90, "Ready!")
	await get_tree().create_timer(0.3).timeout
	_hide_loading()

	_initialized = true
	_log("[color=green]La Palma explorer ready![/color]")
	_log("Use WASD/ZQSD to move, Right-click to look")
	_log("Press F3 for stats, F4 to force cleanup")

	# Start at a scenic location - center of island
	_teleport_to_position(Vector3(0, 1000, 0))


func _init_terrain3d() -> void:
	if not terrain_3d:
		_log("[color=red]ERROR: Terrain3D node not found[/color]")
		return

	# Configure from provider
	terrain_3d.vertex_spacing = _provider.vertex_spacing

	@warning_ignore("int_as_enum_without_cast", "int_as_enum_without_match")
	terrain_3d.change_region_size(_provider.region_size)

	# Configure LOD for large terrain - optimized settings
	terrain_3d.mesh_lods = 8  # Maximum LOD levels for distant terrain
	terrain_3d.mesh_size = 32  # Reduced from 48 for better performance

	# Setup material - use the scene's material if it exists, otherwise create one
	if not terrain_3d.material:
		terrain_3d.set_material(Terrain3DMaterial.new())
		_log("Created new Terrain3DMaterial")
	else:
		_log("Using existing Terrain3DMaterial from scene")

	# Show colormap (white/gray terrain) since we don't have painted textures
	# NOTE: show_checkered is on both the node AND the material
	terrain_3d.show_checkered = false  # Node property
	terrain_3d.material.show_checkered = false  # Material property
	terrain_3d.material.show_colormap = true  # Use vertex colors (white)

	_log("Material settings: checkered=false, colormap=true")

	# Setup assets
	if not terrain_3d.assets:
		terrain_3d.set_assets(Terrain3DAssets.new())

	_log("Terrain3D configured: vertex_spacing=%.1fm, mesh_size=%d, lods=%d" % [
		_provider.vertex_spacing, terrain_3d.mesh_size, terrain_3d.mesh_lods
	])


func _setup_streamer() -> void:
	_streamer = GenericTerrainStreamerScript.new()
	_streamer.name = "TerrainStreamer"

	# Configure streaming parameters
	_streamer.view_distance_regions = _current_view_distance
	_streamer.unload_distance_regions = _current_view_distance + 2  # Unload 2 regions beyond view
	_streamer.max_loads_per_frame = 2  # Allow 2 regions per frame for faster initial loading
	_streamer.max_unloads_per_frame = 2
	_streamer.generation_budget_ms = 16.0  # Allow more time for loading
	_streamer.frustum_priority = true
	_streamer.skip_behind_camera = true  # Don't load regions behind camera
	_streamer.debug_enabled = true  # Enable debug to diagnose issues

	add_child(_streamer)

	# Connect signals
	_streamer.terrain_region_loaded.connect(_on_region_loaded)
	_streamer.terrain_region_unloaded.connect(_on_region_unloaded)
	_streamer.terrain_load_complete.connect(_on_load_complete)

	# Configure streamer
	_streamer.set_provider(_provider)
	_streamer.set_terrain_3d(terrain_3d)
	_streamer.set_tracked_node(camera)
	_streamer.start()

	_log("Terrain streamer started (view: %d, unload: %d regions)" % [
		_current_view_distance, _streamer.unload_distance_regions
	])


func _on_region_loaded(_region: Vector2i) -> void:
	_update_stats()


func _on_region_unloaded(_region: Vector2i) -> void:
	_update_stats()


func _on_load_complete() -> void:
	pass  # Silent - don't spam log


func _teleport_to_position(pos: Vector3) -> void:
	# Disabled for debugging - uncomment once unloading is confirmed working
	#if _streamer:
	#	_streamer.force_cleanup()

	# Get terrain height at position
	var height := pos.y
	if _provider:
		var terrain_height: float = _provider.get_height_at_position(pos)
		if not is_nan(terrain_height):
			height = terrain_height + 100.0  # 100m above terrain

	camera.position = Vector3(pos.x, height, pos.z)
	camera.look_at(Vector3(pos.x, height - 100, pos.z - 200))
	_log("Teleported to (%.0f, %.0f, %.0f)" % [pos.x, height, pos.z])


func _update_stats() -> void:
	if not _streamer:
		return

	var stats: Dictionary = _streamer.get_stats()
	var fps := Engine.get_frames_per_second()
	var frame_ms := 1000.0 / maxf(fps, 1.0)

	# Get terrain height at camera position
	var cam_height := camera.position.y
	var terrain_height := 0.0
	if _provider:
		terrain_height = _provider.get_height_at_position(camera.position)
		if is_nan(terrain_height):
			terrain_height = 0.0

	var height_above_terrain := cam_height - terrain_height

	# Calculate estimated VRAM usage (rough estimate)
	# Each region: 256x256 * 4 bytes * 3 maps (height, control, color) + GPU overhead
	var t3d_regions: int = stats.get("terrain3d_regions", 0)
	var estimated_vram_mb := t3d_regions * 256 * 256 * 4 * 3 / 1024.0 / 1024.0 * 1.5  # 1.5x for GPU overhead

	# Color code FPS
	var fps_color := "green" if fps >= 50 else ("yellow" if fps >= 30 else "red")

	stats_text.text = """[b]Performance[/b]
FPS: [color=%s]%.1f[/color] (%.2f ms)

[b]Terrain Streaming[/b]
Active regions: %d
Terrain3D regions: %d
Queue: %d
Est. VRAM: %.1f MB
Loaded/Unloaded: %d / %d

[b]Settings[/b]
View distance: %d [+/-]
Unload distance: %d

[b]Camera[/b]
Position: (%.0f, %.0f, %.0f)
Above terrain: %.0f m

[color=gray]F3: Stats | F4: Cleanup
+/-: View distance[/color]""" % [
		fps_color, fps, frame_ms,
		stats.get("loaded_regions", 0),
		t3d_regions,
		stats.get("queue_size", 0),
		estimated_vram_mb,
		stats.get("total_loaded", 0),
		stats.get("total_unloaded", 0),
		stats.get("view_distance", _current_view_distance),
		stats.get("unload_distance", _current_view_distance + 2),
		camera.position.x, camera.position.y, camera.position.z,
		height_above_terrain,
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

	# Hotkeys
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_F3:
				_stats_visible = not _stats_visible
				stats_panel.visible = _stats_visible
				_log("Stats: %s" % ("ON" if _stats_visible else "OFF"))
			KEY_F4:
				_force_cleanup()
			KEY_EQUAL, KEY_KP_ADD:
				_adjust_view_distance(1)
			KEY_MINUS, KEY_KP_SUBTRACT:
				_adjust_view_distance(-1)


func _process(delta: float) -> void:
	if not _initialized:
		return

	# Update stats periodically
	if Engine.get_frames_drawn() % 30 == 0:
		_update_stats()

	if not mouse_captured:
		return

	# ZQSD movement (AZERTY layout) + WASD (QWERTY)
	var input_dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_Z) or Input.is_key_pressed(KEY_W):
		input_dir.z -= 1
	if Input.is_key_pressed(KEY_S):
		input_dir.z += 1
	if Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_A):
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


func _adjust_view_distance(delta: int) -> void:
	_current_view_distance = clampi(_current_view_distance + delta, 1, 8)
	if _streamer:
		_streamer.view_distance_regions = _current_view_distance
		_streamer.unload_distance_regions = _current_view_distance + 2

	var km_distance: float = 0.0
	if _provider:
		km_distance = _current_view_distance * _provider.region_size * _provider.vertex_spacing / 1000.0
	_log("View distance: %d regions (~%.1f km)" % [_current_view_distance, km_distance])
	_update_stats()


func _force_cleanup() -> void:
	if _streamer:
		_streamer.force_cleanup()
		_log("[color=yellow]Forced cleanup of distant regions[/color]")
		_update_stats()
