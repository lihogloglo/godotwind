## La Palma Explorer - Explore the volcanic island of La Palma
##
## Features:
## - Uses preprocessed Terrain3D region files for fast loading
## - Free-fly camera navigation
##
## Controls:
## - ZQSD/WASD to move, Right-click to look
## - Space/Shift for up/down
## - Ctrl for speed boost
## - Press F3 to toggle stats overlay
##
## The terrain data is loaded from preprocessed .res files in res://lapalma_terrain/
## These are native Terrain3D region files that load much faster than raw heightmaps.
extends Node3D

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


func _ready() -> void:
	# Connect quick teleport buttons
	# World bounds: ~34km x 48km, centered at origin
	# X range: -16896 to +16896, Z range: -23808 to +23808
	# Highest point (Roque) is around region (1, 6) -> world pos ~(2300, 0, -10000)
	roque_btn.pressed.connect(func() -> void: _teleport_to_position(Vector3(2000, 2500, -10000)))  # Roque de los Muchachos
	caldera_btn.pressed.connect(func() -> void: _teleport_to_position(Vector3(-3000, 1500, -12000)))  # Caldera de Taburiente
	coast_btn.pressed.connect(func() -> void: _teleport_to_position(Vector3(8000, 200, -8000)))  # East coast
	origin_btn.pressed.connect(func() -> void: _teleport_to_position(Vector3(0, 500, 0)))  # Origin (center)
	overview_btn.pressed.connect(_toggle_overview_mode)  # Bird's eye view of entire island

	# Setup sky toggle
	_setup_sky_toggle()

	# Start async initialization
	_show_loading("Initializing La Palma World", "Loading terrain data...")
	call_deferred("_init_async")


func _init_async() -> void:
	await _update_loading(10, "Loading Terrain3D regions...")

	# Terrain3D automatically loads preprocessed regions from data_directory
	# configured in the scene (res://lapalma_terrain/)
	if not terrain_3d:
		_log("[color=red]ERROR: Terrain3D node not found[/color]")
		_hide_loading()
		return

	# Wait for Terrain3D to be ready
	if not terrain_3d.is_inside_tree():
		await terrain_3d.ready

	await _update_loading(40, "Configuring Terrain3D...")
	_init_terrain3d()

	# Get region count from Terrain3D data
	var region_count := 0
	if terrain_3d.data:
		region_count = terrain_3d.data.get_region_count()

	_log("[color=green]Terrain3D data loaded[/color]")
	_log("Regions: %d terrain regions" % region_count)
	_log("Data directory: %s" % terrain_3d.data_directory)

	await _update_loading(90, "Ready!")
	await get_tree().create_timer(0.3).timeout
	_hide_loading()

	_initialized = true
	_log("[color=green]La Palma explorer ready![/color]")
	_log("Use WASD/ZQSD to move, Right-click to look")
	_log("Press F3 for stats")

	# Sync sky state with toggle to ensure consistent initial state
	_sync_sky_state()

	# Start at a scenic location - center of island
	_teleport_to_position(Vector3(0, 1000, 0))


func _init_terrain3d() -> void:
	if not terrain_3d:
		_log("[color=red]ERROR: Terrain3D node not found[/color]")
		return

	# Terrain3D loads configuration from the preprocessed region files
	# The data_directory is set in the scene to res://lapalma_terrain/

	# Configure LOD for large terrain - optimized settings
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
		terrain_3d.vertex_spacing, terrain_3d.mesh_size, terrain_3d.mesh_lods
	])


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
			sky_3d.set("sky3d_enabled", true)
		if _fallback_world_env and _fallback_world_env.is_inside_tree():
			remove_child(_fallback_world_env)
		if _fallback_light:
			_fallback_light.visible = false
	else:
		# Disable Sky3D (if it exists), add fallback back to tree
		if sky_3d:
			sky_3d.set("sky3d_enabled", false)
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
	var Sky3DScript: GDScript = load("res://addons/sky_3d/src/Sky3D.gd") as GDScript
	sky_3d = WorldEnvironment.new()
	sky_3d.set_script(Sky3DScript)
	sky_3d.name = "Sky3D"

	# Add to scene tree FIRST - this triggers Sky3D's _initialize() which creates the environment
	add_child(sky_3d)

	# Configure AFTER adding to tree so _initialize() has run and environment exists
	sky_3d.set("current_time", 10.0)
	sky_3d.set("minutes_per_day", 60.0)

	# Start enabled
	sky_3d.set("sky3d_enabled", true)

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
	# Get terrain height at position using Terrain3D
	var height := pos.y
	if terrain_3d and terrain_3d.data:
		var terrain_height: float = terrain_3d.data.get_height(Vector3(pos.x, 0, pos.z))
		if not is_nan(terrain_height):
			height = terrain_height + 100.0  # 100m above terrain

	camera.position = Vector3(pos.x, height, pos.z)
	camera.look_at(Vector3(pos.x, height - 100, pos.z - 200))
	_log("Teleported to (%.0f, %.0f, %.0f)" % [pos.x, height, pos.z])


func _update_stats() -> void:
	if not terrain_3d:
		return

	var fps := Engine.get_frames_per_second()
	var frame_ms := 1000.0 / maxf(fps, 1.0)

	# Get terrain height at camera position
	var cam_height := camera.position.y
	var terrain_height := 0.0
	if terrain_3d.data:
		terrain_height = terrain_3d.data.get_height(camera.position)
		if is_nan(terrain_height):
			terrain_height = 0.0

	var height_above_terrain := cam_height - terrain_height

	# Get region count from Terrain3D
	var region_count := 0
	if terrain_3d.data:
		region_count = terrain_3d.data.get_region_count()

	# Calculate estimated VRAM usage (rough estimate)
	# Each region: 256x256 * 4 bytes * 3 maps (height, control, color) + GPU overhead
	var estimated_vram_mb := region_count * 256 * 256 * 4 * 3 / 1024.0 / 1024.0 * 1.5  # 1.5x for GPU overhead

	# Color code FPS
	var fps_color := "green" if fps >= 50 else ("yellow" if fps >= 30 else "red")

	# Get time info from Sky3D
	var time_str := "N/A"
	if sky_3d and _show_sky:
		var game_time_val: Variant = sky_3d.get("game_time")
		time_str = str(game_time_val) if game_time_val else "N/A"

	stats_text.text = """[b]Performance[/b]
FPS: [color=%s]%.1f[/color] (%.2f ms)

[b]Terrain[/b]
Regions loaded: %d
Est. VRAM: %.1f MB

[b]Settings[/b]
Sky [K]: %s %s

[b]Camera[/b]
Position: (%.0f, %.0f, %.0f)
Above terrain: %.0f m

[color=gray]F3: Stats | K: Sky[/color]""" % [
		fps_color, fps, frame_ms,
		region_count,
		estimated_vram_mb,
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
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_RIGHT:
			if mouse_event.pressed:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				mouse_captured = true
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
				mouse_captured = false

	if event is InputEventMouseMotion and mouse_captured:
		var motion_event := event as InputEventMouseMotion
		camera.rotate_y(-motion_event.relative.x * mouse_sensitivity)
		camera.rotate_object_local(Vector3.RIGHT, -motion_event.relative.y * mouse_sensitivity)

	# Hotkeys
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed:
			match key_event.keycode:
				KEY_F3:
					_stats_visible = not _stats_visible
					stats_panel.visible = _stats_visible
					_log("Stats: %s" % ("ON" if _stats_visible else "OFF"))
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


func _toggle_overview_mode() -> void:
	# Teleport to bird's eye view of the island
	camera.position = Vector3(0, 25000, 5000)  # 25km altitude, slightly south
	camera.look_at(Vector3(0, 0, -10000))  # Look at island center
	_log("[color=yellow]Overview mode - Bird's eye view[/color]")
	_update_stats()
