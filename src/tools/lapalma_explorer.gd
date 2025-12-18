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
##
## Resolution: 2m vertex spacing (native MDT02), 512m per region
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
@onready var overview_btn: Button = $UI/StatsPanel/VBox/QuickButtons/OverviewBtn

# Managers
var _provider: RefCounted = null  # LaPalmaDataProvider
var _streamer: Node = null  # GenericTerrainStreamer

# Camera controls
var camera_speed: float = 300.0
var mouse_sensitivity: float = 0.003
var mouse_captured: bool = false

# Sky toggle
var _show_sky_toggle: CheckBox = null
var _show_sky: bool = false  # Default OFF - enable for day/night cycle

# Sky3D is created lazily - only on first toggle
var sky_3d: Node = null  # Sky3D node (created on demand)
var _sky3d_initialized: bool = false  # Track if Sky3D has ever been created

# Fallback environment for when Sky3D is disabled (Godot default-like sky)
var _fallback_world_env: WorldEnvironment = null
var _fallback_light: DirectionalLight3D = null

# State
var _initialized: bool = false
var _stats_visible: bool = true
# At 2m vertex spacing: each region = 512m
# 6 regions = ~3km view distance (good balance of quality and performance)
# Overview mode uses 50 regions (~25km) to see the whole island
var _current_view_distance: int = 6
var _overview_mode: bool = false


func _ready() -> void:
	# Connect quick teleport buttons
	# World bounds: ~34km x 48km, centered at origin
	# X range: -16896 to +16896, Z range: -23808 to +23808
	# Highest point (Roque) is around region (1, 6) -> world pos ~(2300, 0, -10000)
	roque_btn.pressed.connect(func(): _teleport_to_position(Vector3(2000, 2500, -10000)))  # Roque de los Muchachos
	caldera_btn.pressed.connect(func(): _teleport_to_position(Vector3(-3000, 1500, -12000)))  # Caldera de Taburiente
	coast_btn.pressed.connect(func(): _teleport_to_position(Vector3(8000, 200, -8000)))  # East coast
	origin_btn.pressed.connect(func(): _teleport_to_position(Vector3(0, 500, 0)))  # Origin (center)
	overview_btn.pressed.connect(_toggle_overview_mode)  # Bird's eye view of entire island

	# Setup sky toggle
	_setup_sky_toggle()

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

	# Sync sky state with toggle to ensure consistent initial state
	_sync_sky_state()

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
	# With 2m resolution we have smaller regions, so we can use smaller mesh chunks
	terrain_3d.mesh_lods = 7  # LOD levels for distant terrain
	terrain_3d.mesh_size = 32  # Mesh chunk size (must be power of 2)

	# Setup material - use the scene's material if it exists, otherwise create one
	if not terrain_3d.material:
		terrain_3d.set_material(Terrain3DMaterial.new())
		_log("Created new Terrain3DMaterial")
	else:
		_log("Using existing Terrain3DMaterial from scene")

	# Show colormap with procedural height-based colors
	# NOTE: show_checkered is on both the node AND the material
	terrain_3d.show_checkered = false  # Node property
	terrain_3d.material.show_checkered = false  # Material property
	terrain_3d.material.show_colormap = true  # Use procedural height colors

	_log("Material settings: checkered=false, colormap=true (procedural)")

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
	# At 2m resolution: regions are 512m, so we need more regions for same view distance
	_streamer.view_distance_regions = _current_view_distance
	_streamer.unload_distance_regions = _current_view_distance + 3  # Unload 3 regions beyond view
	_streamer.max_loads_per_frame = 4  # Allow 4 regions per frame (smaller regions = faster to load)
	_streamer.max_unloads_per_frame = 4
	_streamer.generation_budget_ms = 20.0  # Allow more time for loading
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


## Setup sky toggle checkbox in the UI
func _setup_sky_toggle() -> void:
	# Find the VBox container in stats panel
	var vbox: VBoxContainer = stats_panel.get_node_or_null("VBox")
	if not vbox:
		return

	# Find or create a container for toggles (before QuickLabel)
	var quick_label: Label = vbox.get_node_or_null("QuickLabel")
	var insert_idx: int = quick_label.get_index() if quick_label else vbox.get_child_count()

	# Create a container for the toggle
	var toggle_container := HBoxContainer.new()
	toggle_container.name = "SkyToggle"

	# Create "Sky" checkbox
	_show_sky_toggle = CheckBox.new()
	_show_sky_toggle.text = "Sky/Day-Night [K]"
	_show_sky_toggle.button_pressed = _show_sky
	_show_sky_toggle.toggled.connect(_on_show_sky_toggled)
	toggle_container.add_child(_show_sky_toggle)

	vbox.add_child(toggle_container)
	vbox.move_child(toggle_container, insert_idx)

	# Create fallback environment and light for when Sky3D is disabled
	_setup_fallback_environment()


## Toggle sky visibility and day/night cycle
func _on_show_sky_toggled(enabled: bool) -> void:
	_show_sky = enabled

	if enabled:
		# Create Sky3D lazily on first enable
		if not _sky3d_initialized:
			_create_sky3d()

		# Enable Sky3D, remove fallback from tree (WorldEnvironment has no visible property)
		if sky_3d:
			sky_3d.sky3d_enabled = true
		if _fallback_world_env and _fallback_world_env.is_inside_tree():
			remove_child(_fallback_world_env)
		if _fallback_light:
			_fallback_light.visible = false
	else:
		# Disable Sky3D (if it exists), add fallback back to tree
		if sky_3d:
			sky_3d.sky3d_enabled = false
		if _fallback_world_env and not _fallback_world_env.is_inside_tree():
			add_child(_fallback_world_env)
		if _fallback_light:
			_fallback_light.visible = true

	_log("Sky/Day-Night: %s" % ("ON" if enabled else "OFF"))
	_update_stats()


## Create Sky3D node lazily (only called on first toggle)
func _create_sky3d() -> void:
	if _sky3d_initialized:
		return

	_log("Initializing Sky3D...")

	# Load and instantiate Sky3D
	var Sky3DScript = load("res://addons/sky_3d/src/Sky3D.gd")
	sky_3d = WorldEnvironment.new()
	sky_3d.set_script(Sky3DScript)
	sky_3d.name = "Sky3D"

	# Add to scene tree FIRST - this triggers Sky3D's _initialize() which creates the environment
	add_child(sky_3d)

	# Configure AFTER adding to tree so _initialize() has run and environment exists
	sky_3d.current_time = 10.0
	sky_3d.minutes_per_day = 60.0

	# Start enabled
	sky_3d.sky3d_enabled = true

	_sky3d_initialized = true
	_log("Sky3D initialized")


## Setup fallback environment and light for when Sky3D is disabled
## This provides a Godot default-like appearance instead of black sky
func _setup_fallback_environment() -> void:
	# Create fallback WorldEnvironment with procedural sky (like Godot's default)
	_fallback_world_env = WorldEnvironment.new()
	_fallback_world_env.name = "FallbackEnvironment"

	# Create environment with procedural sky material (Godot's default look)
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	# Create procedural sky (similar to Godot's default new scene sky)
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()

	# Configure for a pleasant daytime look (similar to Godot's default)
	sky_material.sky_top_color = Color(0.385, 0.454, 0.55)  # Godot default blue
	sky_material.sky_horizon_color = Color(0.646, 0.656, 0.67)
	sky_material.ground_bottom_color = Color(0.2, 0.169, 0.133)
	sky_material.ground_horizon_color = Color(0.646, 0.656, 0.67)
	sky_material.sun_angle_max = 30.0
	sky_material.sun_curve = 0.15

	sky.sky_material = sky_material
	env.sky = sky

	# Ambient lighting from sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 1.0

	# Reflected light from sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# Tonemapping (ACES for better contrast)
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0

	_fallback_world_env.environment = env
	add_child(_fallback_world_env)

	# Create fallback directional light
	_fallback_light = DirectionalLight3D.new()
	_fallback_light.name = "FallbackLight"

	# Strong daylight settings
	_fallback_light.light_color = Color(1.0, 0.98, 0.95)  # Slightly warm white
	_fallback_light.light_energy = 1.2  # Stronger light
	_fallback_light.shadow_enabled = true
	_fallback_light.shadow_bias = 0.03
	_fallback_light.directional_shadow_max_distance = 5000.0  # Larger for La Palma

	# Point downward at an angle (like midday sun)
	_fallback_light.rotation_degrees = Vector3(-45, -30, 0)

	add_child(_fallback_light)


## Sync sky state with toggle on initialization
## Since Sky3D is lazily created, this just ensures fallback is in tree
func _sync_sky_state() -> void:
	# Sky3D is not created yet (lazy init), so fallback should be in tree
	# WorldEnvironment doesn't have visible property - it's controlled by being in tree
	if _fallback_light:
		_fallback_light.visible = not _show_sky


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

	# Get time info from Sky3D
	var time_str := "N/A"
	if sky_3d and _show_sky:
		time_str = sky_3d.game_time if sky_3d.game_time else "N/A"

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
Sky [K]: %s %s

[b]Camera[/b]
Position: (%.0f, %.0f, %.0f)
Above terrain: %.0f m

[color=gray]F3: Stats | F4: Cleanup
+/-: View distance | K: Sky[/color]""" % [
		fps_color, fps, frame_ms,
		stats.get("loaded_regions", 0),
		t3d_regions,
		stats.get("queue_size", 0),
		estimated_vram_mb,
		stats.get("total_loaded", 0),
		stats.get("total_unloaded", 0),
		stats.get("view_distance", _current_view_distance),
		stats.get("unload_distance", _current_view_distance + 3),
		"ON" if _show_sky else "OFF",
		("(" + time_str + ")") if _show_sky else "",
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
			KEY_K:  # Toggle sky/day-night cycle
				if _show_sky_toggle:
					_show_sky_toggle.button_pressed = not _show_sky_toggle.button_pressed


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
	var max_dist := 50 if _overview_mode else 15
	_current_view_distance = clampi(_current_view_distance + delta, 1, max_dist)
	if _streamer:
		_streamer.view_distance_regions = _current_view_distance
		_streamer.unload_distance_regions = _current_view_distance + 3

	var km_distance: float = 0.0
	if _provider:
		km_distance = _current_view_distance * _provider.region_size * _provider.vertex_spacing / 1000.0
	_log("View distance: %d regions (~%.1f km)" % [_current_view_distance, km_distance])
	_update_stats()


func _toggle_overview_mode() -> void:
	_overview_mode = not _overview_mode

	if _overview_mode:
		# Enable overview: high altitude, large view distance
		_current_view_distance = 50  # ~25km, covers most of island
		camera.position = Vector3(0, 25000, 5000)  # 25km altitude, slightly south
		camera.look_at(Vector3(0, 0, -10000))  # Look at island center
		_log("[color=yellow]Overview mode ON - Loading entire island...[/color]")
	else:
		# Return to normal exploration mode
		_current_view_distance = 6
		_teleport_to_position(Vector3(0, 1000, 0))
		_log("[color=yellow]Overview mode OFF[/color]")

	if _streamer:
		_streamer.view_distance_regions = _current_view_distance
		_streamer.unload_distance_regions = _current_view_distance + 5

	_update_stats()


func _force_cleanup() -> void:
	if _streamer:
		_streamer.force_cleanup()
		_log("[color=yellow]Forced cleanup of distant regions[/color]")
		_update_stats()
