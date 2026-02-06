## Environment control logic for WorldExplorer.
##
## Extracted from world_explorer.gd (Session 5). Manages shader effects
## (fog, clouds, color grading), sky/day-night cycle, and fallback environment.
## World-affecting side effects (scene tree) are delegated back via callbacks.
##
## Usage:
## [codeblock]
## var controls := EnvironmentControls.new(callbacks)
## controls.setup_fallback_environment()
## controls.set_panels(panels)
## [/codeblock]
class_name EnvironmentControls
extends RefCounted

# ── Public state (readable by world_explorer) ──

var show_sky: bool = false
var sky_3d: Sky3D = null


# ── Private state ──

var _sky3d_initialized: bool = false
var _shader_manager_attached: bool = false
var _fallback_world_env: WorldEnvironment = null
var _fallback_light: DirectionalLight3D = null
var _panels: ExplorerPanels = null

## Callback dictionary — keys are action names, values are Callables on world_explorer
var _cb: Dictionary = {}


## Create the environment controls.
## [param callbacks] Dictionary mapping action names to Callables:
##   log, add_child, remove_child, update_stats
func _init(callbacks: Dictionary) -> void:
	_cb = callbacks


## Set the ExplorerPanels reference (called after panels are constructed).
func set_panels(panels: ExplorerPanels) -> void:
	_panels = panels


## Setup fallback environment and light for when Sky3D is disabled.
## This provides a Godot default-like appearance instead of black sky.
## Must be called before panels are built (needs to be in scene tree first).
func setup_fallback_environment() -> void:
	# Create fallback WorldEnvironment with procedural sky (Godot's default look)
	_fallback_world_env = WorldEnvironment.new()
	_fallback_world_env.name = "FallbackEnvironment"

	# Create environment with procedural sky material (Godot's default look)
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	# Create procedural sky (similar to Godot's default new scene sky)
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()

	# Configure for a pleasant daytime look (similar to Godot's default)
	sky_material.sky_top_color = Color(0.385, 0.454, 0.55)
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

	# Screen-Space Reflections for water
	env.ssr_enabled = true
	env.ssr_max_steps = 64
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.2

	# Tonemapping (Filmic for good contrast without crushing blacks)
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.tonemap_white = 1.0

	_fallback_world_env.environment = env
	_add_child(_fallback_world_env)

	# Create fallback directional light
	_fallback_light = DirectionalLight3D.new()
	_fallback_light.name = "FallbackLight"

	# Strong daylight settings
	_fallback_light.light_color = Color(1.0, 0.98, 0.95)
	_fallback_light.light_energy = 1.2
	_fallback_light.shadow_enabled = true
	_fallback_light.shadow_bias = 0.03
	_fallback_light.directional_shadow_max_distance = 500.0

	# Point downward at an angle (like midday sun)
	_fallback_light.rotation_degrees = Vector3(-45, -30, 0)

	_add_child(_fallback_light)


## Sync sky state with toggle on initialization.
## Since Sky3D is lazily created, this just ensures fallback is in tree.
func sync_sky_state() -> void:
	if _fallback_light:
		_fallback_light.visible = not show_sky


# ── Shader Effect Callbacks ──

## Ensure ShaderManager is attached to the scene.
func ensure_shader_manager_attached() -> void:
	if _shader_manager_attached:
		return

	if _fallback_world_env and _fallback_world_env.is_inside_tree():
		ShaderManager.attach_to(_fallback_world_env)
		_shader_manager_attached = true
		_log("ShaderManager attached to fallback environment")
	elif sky_3d and sky_3d.is_inside_tree():
		ShaderManager.attach_to(sky_3d)
		_shader_manager_attached = true
		_log("ShaderManager attached to Sky3D")


func on_fog_effect_toggled(enabled: bool) -> void:
	ensure_shader_manager_attached()
	if enabled:
		ShaderManager.enable_effect("volumetric_fog", 0.3)
	else:
		ShaderManager.disable_effect("volumetric_fog", 0.3)
	_log("Volumetric Fog: %s" % ("ON" if enabled else "OFF"))


func on_fog_intensity_changed(value: float) -> void:
	ShaderManager.set_effect_param("volumetric_fog", "fog_intensity", value)


func on_clouds_effect_toggled(enabled: bool) -> void:
	ensure_shader_manager_attached()
	if enabled:
		ShaderManager.enable_effect("volumetric_clouds", 0.3)
	else:
		ShaderManager.disable_effect("volumetric_clouds", 0.3)
	_log("Volumetric Clouds: %s" % ("ON" if enabled else "OFF"))


func on_cloud_coverage_changed(value: float) -> void:
	ShaderManager.set_effect_param("volumetric_clouds", "cloud_coverage", value)


func on_color_grading_toggled(enabled: bool) -> void:
	ensure_shader_manager_attached()
	if enabled:
		ShaderManager.enable_effect("color_grading", 0.3)
	else:
		ShaderManager.disable_effect("color_grading", 0.3)
	_log("Color Grading: %s" % ("ON" if enabled else "OFF"))


func on_morrowind_color_preset() -> void:
	var effect := ShaderManager.get_effect("color_grading")
	if effect and effect.has_method("apply_morrowind_preset"):
		effect.apply_morrowind_preset()
		if _panels and not _panels.color_grading_toggle.button_pressed:
			_panels.color_grading_toggle.button_pressed = true
		_log("Applied Morrowind color preset")


func on_dramatic_color_preset() -> void:
	var effect := ShaderManager.get_effect("color_grading")
	if effect and effect.has_method("apply_dramatic_preset"):
		effect.apply_dramatic_preset()
		if _panels and not _panels.color_grading_toggle.button_pressed:
			_panels.color_grading_toggle.button_pressed = true
		_log("Applied Dramatic color preset")


func on_reset_color_grading() -> void:
	var effect := ShaderManager.get_effect("color_grading")
	if effect:
		effect.reset_all_params()
		_log("Reset color grading to defaults")


# ── Sky/Day-Night Cycle ──

## Toggle sky/day-night cycle visibility.
func on_show_sky_toggled(enabled: bool) -> void:
	show_sky = enabled

	if enabled:
		# Create Sky3D lazily on first enable
		if not _sky3d_initialized:
			_create_sky3d()

		# Enable Sky3D - add to tree if not already there
		if sky_3d:
			if not sky_3d.is_inside_tree():
				_add_child(sky_3d)
			sky_3d.sky3d_enabled = true
		# Remove fallback from tree (only one WorldEnvironment can be active)
		if _fallback_world_env and _fallback_world_env.is_inside_tree():
			_remove_child(_fallback_world_env)
		if _fallback_light:
			_fallback_light.visible = false
	else:
		# Disable and remove Sky3D from tree so fallback can take over
		if sky_3d:
			if sky_3d.is_inside_tree():
				_remove_child(sky_3d)
			sky_3d.sky3d_enabled = false
		# Add fallback back to tree AFTER Sky3D is removed
		if _fallback_world_env:
			if not _fallback_world_env.is_inside_tree():
				_add_child(_fallback_world_env)
			_fallback_world_env.environment = _fallback_world_env.environment
		if _fallback_light:
			_fallback_light.visible = true

	_log("Sky/Day-Night: %s" % ("ON" if enabled else "OFF"))
	_update_stats()


# ── Private methods ──

## Create Sky3D node lazily (only called on first toggle).
func _create_sky3d() -> void:
	if _sky3d_initialized:
		return

	_log("Initializing Sky3D...")

	# Remove fallback environment BEFORE adding Sky3D (only one WorldEnvironment can be active)
	if _fallback_world_env and _fallback_world_env.is_inside_tree():
		_remove_child(_fallback_world_env)
	if _fallback_light:
		_fallback_light.visible = false

	# Instantiate standard Sky3D with 2D texture clouds
	sky_3d = Sky3D.new()
	sky_3d.name = "Sky3D"

	# Add to scene tree FIRST - this triggers Sky3D's _initialize() which creates the environment
	_add_child(sky_3d)

	# Configure AFTER adding to tree so _initialize() has run and environment exists
	sky_3d.current_time = 12.0
	sky_3d.ambient_energy = 0.5

	# Use Filmic tonemapping instead of ACES to avoid crushing blacks
	if sky_3d.environment:
		sky_3d.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	# Start enabled
	sky_3d.sky3d_enabled = true

	_sky3d_initialized = true
	_log("Sky3D initialized")


## Log a message via callback.
func _log(message: String) -> void:
	var cb: Callable = _cb.get("log", Callable())
	if cb.is_valid():
		cb.call(message)


## Add a child node to the scene via callback.
func _add_child(node: Node) -> void:
	var cb: Callable = _cb.get("add_child", Callable())
	if cb.is_valid():
		cb.call(node)


## Remove a child node from the scene via callback.
func _remove_child(node: Node) -> void:
	var cb: Callable = _cb.get("remove_child", Callable())
	if cb.is_valid():
		cb.call(node)


## Update stats via callback.
func _update_stats() -> void:
	var cb: Callable = _cb.get("update_stats", Callable())
	if cb.is_valid():
		cb.call()
