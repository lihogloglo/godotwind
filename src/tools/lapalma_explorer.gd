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

# Ocean toggle
var _show_ocean_toggle: CheckBox = null
var _show_ocean: bool = false  # Default OFF - enable for ocean rendering
var _ocean_initialized: bool = false

# Fog slider (Environment fog)
var _fog_slider: HSlider = null
var _fog_label: Label = null
var _fog_density: float = 0.00001  # Default very low fog for extended view

# ShaderManager post-processing effects
var _shader_manager_attached: bool = false
var _volumetric_fog_toggle: CheckBox = null
var _volumetric_clouds_toggle: CheckBox = null
var _color_grading_toggle: CheckBox = null

# SkyManager is created lazily - only on first toggle
var _sky_manager: SkyManager = null
var _sky_initialized: bool = false

# Fallback environment for when sky is disabled (Godot default-like sky)
var _fallback_world_env: WorldEnvironment = null
var _fallback_light: DirectionalLight3D = null

# Extended view distance for seeing the whole island
const EXTENDED_FAR_PLANE: float = 150000.0  # 150km - enough to see whole island
const OCEAN_RADIUS: float = 100000.0  # 100km ocean clipmap radius

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

	# Configure LOD for large terrain - maximum distance to see entire island
	# Render distance = mesh_size × vertex_spacing × 2^mesh_lods
	# With mesh_size=48, vertex_spacing=1.0, mesh_lods=10: 48 × 1 × 1024 = ~49km
	terrain_3d.mesh_lods = 10  # Maximum LOD levels (10 = max) for full island view
	terrain_3d.mesh_size = 48  # Mesh chunk size (larger = more detail per LOD)

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

	# Disable macro variation (color noise) which can look foggy at distance
	if terrain_3d.material:
		var mat_rid: RID = terrain_3d.material.get_material_rid()
		RenderingServer.material_set_param(mat_rid, &"macro_variation_enabled", false)
	_log("Disabled macro_variation for clearer distance view")

	_log("Material settings: checkered=false, colormap=true")

	# Setup assets
	if not terrain_3d.assets:
		terrain_3d.set_assets(Terrain3DAssets.new())

	# Calculate and log render distance
	var render_distance := terrain_3d.mesh_size * terrain_3d.vertex_spacing * pow(2, terrain_3d.mesh_lods)
	_log("Terrain3D configured: mesh_size=%d, lods=%d, render_dist=%.0fkm" % [
		terrain_3d.mesh_size, terrain_3d.mesh_lods, render_distance / 1000.0
	])


## Setup sky and ocean toggle checkboxes in the UI
func _setup_sky_toggle() -> void:
	# Find the VBox container in stats panel
	var vbox: VBoxContainer = stats_panel.get_node_or_null("VBox")
	if not vbox:
		return

	# Find or create a container for toggles (before QuickLabel)
	var quick_label: Label = vbox.get_node_or_null("QuickLabel")
	var insert_idx: int = quick_label.get_index() if quick_label else vbox.get_child_count()

	# Create a container for toggles
	var toggle_container := VBoxContainer.new()
	toggle_container.name = "ToggleContainer"

	# Create "Sky" checkbox
	_show_sky_toggle = CheckBox.new()
	_show_sky_toggle.text = "Sky/Day-Night [K]"
	_show_sky_toggle.button_pressed = _show_sky
	_show_sky_toggle.toggled.connect(_on_show_sky_toggled)
	toggle_container.add_child(_show_sky_toggle)

	# Create "Ocean" checkbox
	_show_ocean_toggle = CheckBox.new()
	_show_ocean_toggle.text = "Ocean [O]"
	_show_ocean_toggle.button_pressed = _show_ocean
	_show_ocean_toggle.toggled.connect(_on_show_ocean_toggled)
	toggle_container.add_child(_show_ocean_toggle)

	# Create fog density slider
	var fog_container := HBoxContainer.new()
	fog_container.name = "FogContainer"

	_fog_label = Label.new()
	_fog_label.text = "Fog:"
	_fog_label.custom_minimum_size.x = 30
	fog_container.add_child(_fog_label)

	_fog_slider = HSlider.new()
	_fog_slider.min_value = 0.0
	_fog_slider.max_value = 1.0
	_fog_slider.step = 0.01
	_fog_slider.value = 0.0  # Default: no fog (0 maps to very low density)
	_fog_slider.custom_minimum_size.x = 120
	_fog_slider.value_changed.connect(_on_fog_changed)
	fog_container.add_child(_fog_slider)

	toggle_container.add_child(fog_container)

	# Add separator before shader effects
	var sep := HSeparator.new()
	sep.name = "ShaderSeparator"
	toggle_container.add_child(sep)

	# Add shader effects label
	var shader_label := Label.new()
	shader_label.text = "Post-Processing:"
	shader_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	toggle_container.add_child(shader_label)

	# Create volumetric fog toggle
	_volumetric_fog_toggle = CheckBox.new()
	_volumetric_fog_toggle.text = "Vol. Fog [F]"
	_volumetric_fog_toggle.button_pressed = false
	_volumetric_fog_toggle.toggled.connect(_on_volumetric_fog_toggled)
	toggle_container.add_child(_volumetric_fog_toggle)

	# Create volumetric clouds toggle
	_volumetric_clouds_toggle = CheckBox.new()
	_volumetric_clouds_toggle.text = "Vol. Clouds [C]"
	_volumetric_clouds_toggle.button_pressed = false
	_volumetric_clouds_toggle.toggled.connect(_on_volumetric_clouds_toggled)
	toggle_container.add_child(_volumetric_clouds_toggle)

	# Create color grading toggle
	_color_grading_toggle = CheckBox.new()
	_color_grading_toggle.text = "Color Grade [G]"
	_color_grading_toggle.button_pressed = false
	_color_grading_toggle.toggled.connect(_on_color_grading_toggled)
	toggle_container.add_child(_color_grading_toggle)

	vbox.add_child(toggle_container)
	vbox.move_child(toggle_container, insert_idx)

	# Create fallback environment and light for when sky is disabled
	_setup_fallback_environment()


## Toggle sky visibility and day/night cycle
func _on_show_sky_toggled(enabled: bool) -> void:
	_show_sky = enabled

	if enabled:
		# Create SkyManager lazily on first enable
		if not _sky_initialized:
			_create_sky_manager()

		# Enable SkyManager, remove fallback from tree (only one WorldEnvironment can be active)
		if _sky_manager:
			if not _sky_manager.is_inside_tree():
				add_child(_sky_manager)
			_sky_manager.enabled = true
			_sky_manager.update(10.0)
		if _fallback_world_env and _fallback_world_env.is_inside_tree():
			remove_child(_fallback_world_env)
		if _fallback_light:
			_fallback_light.visible = false
	else:
		# Disable SkyManager, add fallback back to tree
		if _sky_manager:
			if _sky_manager.is_inside_tree():
				remove_child(_sky_manager)
			_sky_manager.enabled = false
		if _fallback_world_env and not _fallback_world_env.is_inside_tree():
			add_child(_fallback_world_env)
		if _fallback_light:
			_fallback_light.visible = true

	_log("Sky/Day-Night: %s" % ("ON" if enabled else "OFF"))
	_update_stats()


## Create SkyManager lazily (only called on first toggle)
func _create_sky_manager() -> void:
	if _sky_initialized:
		return

	_log("Initializing SkyManager...")

	# Remove fallback before adding SkyManager (only one WorldEnvironment can be active)
	if _fallback_world_env and _fallback_world_env.is_inside_tree():
		remove_child(_fallback_world_env)
	if _fallback_light:
		_fallback_light.visible = false

	_sky_manager = SkyManager.new()
	_sky_manager.name = "SkyManager"
	add_child(_sky_manager)

	# Configure fog for extended view distance
	_configure_sky_fog()

	_sky_initialized = true
	_log("SkyManager initialized")


## Configure SkyManager fog for extended view distance
func _configure_sky_fog() -> void:
	if not _sky_manager:
		return

	var env: Environment = _sky_manager.get_environment()
	if env:
		env.fog_enabled = _fog_density > 0.0
		env.fog_light_color = Color(0.8, 0.85, 0.9)
		env.fog_light_energy = 0.5
		env.fog_sun_scatter = 0.3
		env.fog_density = _fog_density
		env.fog_aerial_perspective = 0.3
		env.fog_sky_affect = 0.5
		_log("Sky fog configured (density: %.6f)" % _fog_density)


## Toggle ocean visibility
func _on_show_ocean_toggled(enabled: bool) -> void:
	_show_ocean = enabled

	if enabled:
		# Initialize ocean lazily on first enable
		if not _ocean_initialized:
			_initialize_ocean()

		# Enable ocean rendering
		if OceanManager.is_system_enabled():
			OceanManager.set_enabled(true)
			_log("Ocean: ON (mode: %s)" % OceanManager.get_water_quality_name())
		else:
			_log("[color=yellow]Ocean: Failed to enable[/color]")
	else:
		# Disable ocean rendering
		if OceanManager.is_system_enabled():
			OceanManager.set_enabled(false)
		_log("Ocean: OFF")

	_update_stats()


## Initialize OceanManager for La Palma (sea level at 2m, flat mode)
func _initialize_ocean() -> void:
	if _ocean_initialized:
		return

	_log("Initializing Ocean system (flat mode)...")

	# Configure ocean for La Palma's extended view distance
	OceanManager.ocean_radius = OCEAN_RADIUS
	OceanManager.sea_level = 10.0  # Sea level at 10 meters altitude

	# Force FLAT quality mode (0 = flat) before initialization
	OceanManager.water_quality = 0

	# Force initialize (since ocean is disabled by default in project settings)
	OceanManager.force_initialize()

	# Ensure FLAT mode is set after initialization
	OceanManager.set_water_quality(0)  # 0 = FLAT

	# Set the terrain for shore mask generation
	if terrain_3d:
		OceanManager.set_terrain(terrain_3d)

	# Set the camera
	OceanManager.set_camera(camera)

	_ocean_initialized = true
	_log("Ocean initialized: FLAT mode, sea_level=10m, radius=%.0fkm" % (OCEAN_RADIUS / 1000.0))


## Handle fog slider change
func _on_fog_changed(value: float) -> void:
	# Map slider 0-1 to fog density
	# 0 = no fog, 1 = heavy fog
	# Using exponential scale: 0 to 0.0001 (very light) to 0.01 (heavy)
	if value <= 0.05:
		_fog_density = 0.0  # Disable fog completely for first 5% of slider
	else:
		# Remap 0.05-1.0 to exponential range
		var t := (value - 0.05) / 0.95  # Normalize to 0-1
		_fog_density = 0.0000001 * pow(100000, t)  # Range: 0.0000001 to 0.01

	_apply_fog_density()


## Apply fog density to active environment
func _apply_fog_density() -> void:
	# Apply to SkyManager environment if active
	if _show_sky and _sky_manager:
		var env: Environment = _sky_manager.get_environment()
		if env:
			env.fog_enabled = _fog_density > 0.0
			env.fog_density = _fog_density

	# Apply to fallback environment if active
	if not _show_sky and _fallback_world_env and _fallback_world_env.environment:
		_fallback_world_env.environment.fog_enabled = _fog_density > 0.0
		_fallback_world_env.environment.fog_density = _fog_density


## Ensure ShaderManager is attached to the active WorldEnvironment
func _ensure_shader_manager_attached() -> void:
	if _shader_manager_attached:
		return

	# Attach to whichever WorldEnvironment is currently active
	if _fallback_world_env:
		ShaderManager.attach_to(_fallback_world_env)
		_shader_manager_attached = true
		_log("ShaderManager attached to fallback environment")


## Toggle volumetric fog effect
func _on_volumetric_fog_toggled(enabled: bool) -> void:
	_ensure_shader_manager_attached()

	if enabled:
		ShaderManager.enable_effect("volumetric_fog", 0.3)
		_log("Volumetric Fog: ON")
	else:
		ShaderManager.disable_effect("volumetric_fog", 0.3)
		_log("Volumetric Fog: OFF")


## Toggle volumetric clouds effect
func _on_volumetric_clouds_toggled(enabled: bool) -> void:
	_ensure_shader_manager_attached()

	if enabled:
		ShaderManager.enable_effect("volumetric_clouds", 0.3)
		_log("Volumetric Clouds: ON")
	else:
		ShaderManager.disable_effect("volumetric_clouds", 0.3)
		_log("Volumetric Clouds: OFF")


## Toggle color grading effect
func _on_color_grading_toggled(enabled: bool) -> void:
	_ensure_shader_manager_attached()

	if enabled:
		ShaderManager.enable_effect("color_grading", 0.3)
		# Apply Morrowind-style warm tones preset
		var effect = ShaderManager.get_effect("color_grading")
		if effect and effect.has_method("apply_morrowind_preset"):
			effect.apply_morrowind_preset()
		_log("Color Grading: ON (Morrowind preset)")
	else:
		ShaderManager.disable_effect("color_grading", 0.3)
		_log("Color Grading: OFF")


## Setup fallback environment and light for when sky is disabled
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

	# Fog disabled by default (slider at 0 = no fog)
	env.fog_enabled = false

	# Disable volumetric fog completely
	env.volumetric_fog_enabled = false

	# Disable glow (can cause haze-like effects)
	env.glow_enabled = false

	# Disable SSAO/SSIL (can darken distant terrain)
	env.ssao_enabled = false
	env.ssil_enabled = false

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
## Since SkyManager is lazily created, this just ensures fallback is in tree
func _sync_sky_state() -> void:
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

	# Get time info from SkyManager
	var time_str := "N/A"
	if _sky_manager and _show_sky:
		time_str = "%.1f" % _sky_manager.game_hour

	# Get ocean info
	var ocean_str := "OFF"
	if _show_ocean and OceanManager.is_system_enabled():
		ocean_str = "ON (%s)" % OceanManager.get_water_quality_name()

	stats_text.text = """[b]Performance[/b]
FPS: [color=%s]%.1f[/color] (%.2f ms)

[b]Terrain[/b]
Regions loaded: %d
Est. VRAM: %.1f MB

[b]Settings[/b]
Sky [K]: %s %s
Ocean [O]: %s
View: %.0f km

[b]Camera[/b]
Position: (%.0f, %.0f, %.0f)
Above terrain: %.0f m

[color=gray]F3: Stats | K: Sky | O: Ocean
F: Fog | C: Clouds | G: Color[/color]""" % [
		fps_color, fps, frame_ms,
		region_count,
		estimated_vram_mb,
		"ON" if _show_sky else "OFF",
		("(" + time_str + ")") if _show_sky else "",
		ocean_str,
		camera.far / 1000.0,
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
	Log.info("tools", message.replace("[color=green]", "").replace("[color=red]", "").replace("[color=yellow]", "").replace("[/color]", "").replace("[b]", "").replace("[/b]", ""))


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
				KEY_O:  # Toggle ocean
					if _show_ocean_toggle:
						_show_ocean_toggle.button_pressed = not _show_ocean_toggle.button_pressed
				KEY_F:  # Toggle volumetric fog
					if _volumetric_fog_toggle:
						_volumetric_fog_toggle.button_pressed = not _volumetric_fog_toggle.button_pressed
				KEY_C:  # Toggle volumetric clouds
					if _volumetric_clouds_toggle:
						_volumetric_clouds_toggle.button_pressed = not _volumetric_clouds_toggle.button_pressed
				KEY_G:  # Toggle color grading
					if _color_grading_toggle:
						_color_grading_toggle.button_pressed = not _color_grading_toggle.button_pressed


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
