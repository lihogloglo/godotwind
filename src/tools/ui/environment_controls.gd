## Environment control logic for WorldExplorer.
##
## Extracted from world_explorer.gd (Session 5). Manages shader effects
## (fog, clouds, color grading), sky/day-night cycle, native rendering quality
## toggles (SSAO, SSIL, glow, volumetric fog, depth fog, TAA, tonemapping),
## and fallback environment.
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

## Custom sky system
var sky_manager: SkyManager = null

## When true, weather system owns fog/ambient base values
var weather_active: bool = false


# ── Private state ──

var _shader_manager_attached: bool = false
var _fallback_world_env: WorldEnvironment = null
var _fallback_light: DirectionalLight3D = null
var _panels: ExplorerPanels = null

## Callback dictionary — keys are action names, values are Callables on world_explorer
var _cb: Dictionary = {}

## Tracks native environment toggles so they survive sky <-> fallback swaps.
## Keys match Environment property groups; values are Dictionaries of property->value.
var _visual_state: Dictionary = {
	"ssao": false,
	"ssil": false,
	"ssr": true,
	# Glow default ON (2026-07-06 lighting pass): light-source meshes now carry
	# boosted emission (reference_instantiator._boost_light_model_emission) and
	# rely on bloom for the fire halo. Cost is a fixed-resolution mip chain.
	"glow": true,
	"volumetric_fog": false,
	# Depth fog defaults ON (2026-07-06): the terrain heightmap is a finite
	# square slab — from altitude its edge/corners are visible without a
	# horizon-closing haze. MGE XE distant land uses the same fix.
	"depth_fog": true,
	# Independent per-fog strength (Fog panel sliders). Multiply the fixed
	# weather-off densities; WeatherRenderer applies its own copies while weather
	# is active. Tracked here so they survive sky <-> fallback swaps.
	"depth_fog_strength": 1.0,
	"volumetric_fog_strength": 1.0,
	# SDFGI default OFF (2026-07-06): camera-centered cascades produce a bright
	# GI bubble around the camera at night, plus a frame-time cost on open
	# terrain. When enabled from the Rendering tab, SkyManager dims its energy
	# with the day/night cycle so the halo doesn't return.
	"sdfgi": false,
	"tonemap_mode": Environment.TONE_MAPPER_FILMIC,
	"shadow_cascades": false,
}


## Create the environment controls.
## [param callbacks] Dictionary mapping action names to Callables:
##   log, add_child, remove_child, update_stats
func _init(callbacks: Dictionary) -> void:
	_cb = callbacks


## Set the ExplorerPanels reference (called after panels are constructed).
func set_panels(panels: ExplorerPanels) -> void:
	_panels = panels


## Setup fallback environment and light for when sky is disabled.
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
	# Use Godot defaults for sun disc (sun_angle_max=1.0, sun_curve=0.15)
	# Don't override — any mismatch can cause visible artifacts

	sky.sky_material = sky_material
	env.sky = sky

	# Ambient lighting from sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 1.0

	# Reflected light from sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# Tonemapping (Filmic for good contrast without crushing blacks)
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.tonemap_white = 1.0

	_fallback_world_env.environment = env
	_add_child(_fallback_world_env)

	# Apply all tracked visual state (SSR, SSAO, etc.) to the fallback env
	_apply_visual_state(env)

	# Create fallback directional light
	_fallback_light = DirectionalLight3D.new()
	_fallback_light.name = "FallbackLight"

	# Strong daylight settings
	_fallback_light.light_color = Color(1.0, 0.98, 0.95)
	_fallback_light.light_energy = 1.2
	_fallback_light.shadow_enabled = true
	_fallback_light.shadow_bias = 0.02
	_fallback_light.shadow_normal_bias = 1.5
	_fallback_light.directional_shadow_max_distance = 500.0

	# Point downward at an angle (like midday sun)
	_fallback_light.rotation_degrees = Vector3(-45, -30, 0)

	_add_child(_fallback_light)
	ensure_shader_manager_attached()


## Sync sky state with toggle on initialization.
## Since SkyManager is lazily created, this just ensures fallback is in tree.
func sync_sky_state() -> void:
	if _fallback_light:
		_fallback_light.visible = not show_sky


# ── Cirrus ──

func on_cirrus_changed(value: float) -> void:
	if sky_manager:
		sky_manager.cirrus_coverage = value
	_log("Cirrus coverage: %.2f" % value)


func on_cirrus_size_changed(value: float) -> void:
	if sky_manager:
		sky_manager.cirrus_size = value
	_log("Cirrus size: %.2f" % value)


func on_cirrus_thickness_changed(value: float) -> void:
	if sky_manager:
		sky_manager.cirrus_thickness = value
	_log("Cirrus thickness: %.2f" % value)


# ── Shader Effect Callbacks ──

## Ensure ShaderManager is attached to the scene.
## Prefers SkyManager's WorldEnvironment when sky is active, falls back to
## the fallback environment. Re-attaches when the active target changes
## (e.g. sky toggled on after initial attach to fallback).
func ensure_shader_manager_attached() -> void:
	# When sky is active, prefer SkyManager's WorldEnvironment
	if show_sky and sky_manager and sky_manager.is_inside_tree():
		var sky_world_env: WorldEnvironment = sky_manager.get_world_environment()
		if sky_world_env and sky_world_env.is_inside_tree():
			ShaderManager.attach_to(sky_world_env)
			_shader_manager_attached = true
			return

	if _shader_manager_attached:
		return

	if _fallback_world_env and _fallback_world_env.is_inside_tree():
		ShaderManager.attach_to(_fallback_world_env)
		_shader_manager_attached = true
		_log("ShaderManager attached to fallback environment")


func on_godrays_toggled(enabled: bool) -> void:
	ensure_shader_manager_attached()
	if enabled:
		ShaderManager.enable_effect("godrays", 0.3)
	else:
		ShaderManager.disable_effect("godrays", 0.3)
	_log("God Rays: %s" % ("ON" if enabled else "OFF"))


## Ground fog + cloud banks — the raymarch effect (valley fog that
## also covers the sky, altitude-band cloud deck). Distinct from the engine
## froxel volumetric fog handled by on_native_volumetric_fog_toggled.
func on_ground_fog_toggled(enabled: bool) -> void:
	ensure_shader_manager_attached()
	if enabled:
		ShaderManager.enable_effect("volumetric_fog", 0.5)
	else:
		ShaderManager.disable_effect("volumetric_fog", 0.5)
	_log("Ground Fog + Cloud Banks: %s" % ("ON" if enabled else "OFF"))


func on_ground_fog_param_changed(value: float, param_name: String) -> void:
	ShaderManager.set_effect_param("volumetric_fog", param_name, value)


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


# ── Native Rendering Quality Toggles ──
# These set properties directly on the active Environment resource.
# State is tracked in _visual_state so it survives sky <-> fallback swaps.

## Get whichever Environment is currently active.
func _get_active_environment() -> Environment:
	if show_sky and sky_manager:
		return sky_manager.get_environment()
	if _fallback_world_env and _fallback_world_env.environment:
		return _fallback_world_env.environment
	return null


## Public getter for active environment (used by WeatherRenderer)
func get_active_environment() -> Environment:
	return _get_active_environment()


## Public getter for fallback directional light
func get_fallback_light() -> DirectionalLight3D:
	return _fallback_light


## Re-apply all tracked visual state to an Environment resource.
func _apply_visual_state(env: Environment) -> void:
	if not env:
		return

	# SSAO
	env.ssao_enabled = _visual_state["ssao"]
	if _visual_state["ssao"]:
		env.ssao_radius = 1.5
		env.ssao_intensity = 3.0
		env.ssao_power = 1.5
		env.ssao_detail = 0.7
		env.ssao_sharpness = 0.98
		env.ssao_light_affect = 0.0

	# SSIL
	env.ssil_enabled = _visual_state["ssil"]
	if _visual_state["ssil"]:
		env.ssil_radius = 5.0
		env.ssil_intensity = 1.0
		env.ssil_sharpness = 0.98
		env.ssil_normal_rejection = 1.0

	# SSR (Screen-Space Reflections) — critical for water reflections
	env.ssr_enabled = _visual_state["ssr"]
	if _visual_state["ssr"]:
		env.ssr_max_steps = 64
		env.ssr_fade_in = 0.15
		env.ssr_fade_out = 2.0
		env.ssr_depth_tolerance = 0.2

	# Glow
	env.glow_enabled = _visual_state["glow"]
	if _visual_state["glow"]:
		env.glow_intensity = 0.4
		env.glow_bloom = 0.15
		env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
		env.glow_hdr_threshold = 0.8
		env.glow_hdr_scale = 2.0
		env.glow_hdr_luminance_cap = 12.0
		env.glow_mix = 0.05
		env.glow_strength = 1.15
		env.set("glow_levels/1", 0.2)
		env.set("glow_levels/2", 0.8)
		env.set("glow_levels/3", 0.5)
		env.set("glow_levels/4", 0.15)

	# Godot native volumetric fog (god rays via anisotropy)
	env.volumetric_fog_enabled = _visual_state["volumetric_fog"]
	if _visual_state["volumetric_fog"]:
		_apply_volumetric_fog_defaults(env)

	# Depth fog (aerial perspective + height fog)
	env.fog_enabled = _visual_state["depth_fog"]
	if _visual_state["depth_fog"]:
		_apply_depth_fog_defaults(env)

	# SDFGI (cascaded SDF global illumination)
	env.sdfgi_enabled = _visual_state["sdfgi"]
	if _visual_state["sdfgi"]:
		env.sdfgi_cascades = 4
		env.sdfgi_y_scale = Environment.SDFGI_Y_SCALE_75_PERCENT
		env.sdfgi_use_occlusion = true
		env.sdfgi_bounce_feedback = 0.3
		env.sdfgi_read_sky_light = true
		env.sdfgi_energy = 1.0
		env.sdfgi_normal_bias = 1.1
		env.sdfgi_probe_bias = 1.1

	# Tonemapping
	env.tonemap_mode = _visual_state["tonemap_mode"]


## Apply default volumetric fog parameters to an Environment.
## Single source of truth — called by _apply_visual_state() and on_native_volumetric_fog_toggled().
func _apply_volumetric_fog_defaults(env: Environment) -> void:
	env.volumetric_fog_density = 0.0015 * float(_visual_state["volumetric_fog_strength"])
	env.volumetric_fog_albedo = Color(0.95, 0.95, 0.98)
	env.volumetric_fog_emission = Color.BLACK
	env.volumetric_fog_anisotropy = 0.55
	env.volumetric_fog_length = 800.0
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_gi_inject = 0.5
	env.volumetric_fog_sky_affect = 0.15
	env.volumetric_fog_temporal_reprojection_enabled = true
	env.volumetric_fog_temporal_reprojection_amount = 0.7


## Apply default depth fog parameters to an Environment.
## Single source of truth — called by _apply_visual_state() and on_depth_fog_toggled().
func _apply_depth_fog_defaults(env: Environment) -> void:
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	# 0.00025: ~74% visibility at the CHUNK boundary (1.2km), ~8% at 10km —
	# geometry is fully hazed out before the terrain-data edge (~8-15km) so
	# the square map boundary can't be seen from altitude.
	env.fog_density = 0.00025 * float(_visual_state["depth_fog_strength"])
	env.fog_light_color = Color(0.7, 0.75, 0.82)
	env.fog_light_energy = 1.0
	env.fog_sun_scatter = 0.5
	# 1.0 = fog fades toward the actual per-pixel sky color, so fogged
	# geometry merges seamlessly into the horizon.
	env.fog_aerial_perspective = 1.0
	env.fog_sky_affect = 0.15
	env.fog_height = 0.0
	env.fog_height_density = 0.003 * float(_visual_state["depth_fog_strength"])


## Re-assert fog defaults after weather deactivation.
## Called synchronously by WeatherControls AFTER WeatherRenderer.cleanup_on_deactivate().
## Ensures EnvironmentControls reclaims authority over fog parameter values.
func reassert_fog_defaults() -> void:
	var env := _get_active_environment()
	if not env:
		return
	if _visual_state["volumetric_fog"]:
		_apply_volumetric_fog_defaults(env)
	if _visual_state["depth_fog"]:
		_apply_depth_fog_defaults(env)


## Apply shadow cascade settings to a DirectionalLight3D.
func _apply_shadow_cascades(light: DirectionalLight3D) -> void:
	if not light:
		return
	# Always set bias values to reduce blockiness/swimming
	light.shadow_bias = 0.02
	light.shadow_normal_bias = 1.5
	if _visual_state["shadow_cascades"]:
		light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		light.directional_shadow_blend_splits = true
		light.directional_shadow_fade_start = 0.8
		light.directional_shadow_split_1 = 0.1
		light.directional_shadow_split_2 = 0.25
		light.directional_shadow_split_3 = 0.5
	else:
		light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		light.directional_shadow_blend_splits = false


func on_taa_toggled(enabled: bool) -> void:
	# Legacy toggle — now controls FSR 2.2 (superior temporal AA replacement for TAA)
	var viewport := _get_viewport()
	if viewport:
		if enabled:
			viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
			viewport.scaling_3d_scale = 1.0
			viewport.fsr_sharpness = 0.2
			viewport.use_taa = false
		else:
			viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
			viewport.scaling_3d_scale = 1.0
			viewport.use_taa = false
	_log("FSR 2.2: %s" % ("ON" if enabled else "OFF"))


func on_sdfgi_toggled(enabled: bool) -> void:
	_visual_state["sdfgi"] = enabled
	var env := _get_active_environment()
	if env:
		env.sdfgi_enabled = enabled
		if enabled:
			env.sdfgi_cascades = 4
			env.sdfgi_y_scale = Environment.SDFGI_Y_SCALE_75_PERCENT
			env.sdfgi_use_occlusion = true
			env.sdfgi_bounce_feedback = 0.3
			env.sdfgi_read_sky_light = true
			env.sdfgi_energy = 1.0
			env.sdfgi_normal_bias = 1.1
			env.sdfgi_probe_bias = 1.1
	_log("SDFGI: %s" % ("ON" if enabled else "OFF"))


func on_ssao_toggled(enabled: bool) -> void:
	_visual_state["ssao"] = enabled
	var env := _get_active_environment()
	if env:
		env.ssao_enabled = enabled
		if enabled:
			env.ssao_radius = 1.0
			env.ssao_intensity = 2.0
			env.ssao_power = 1.5
			env.ssao_detail = 0.5
			env.ssao_sharpness = 0.98
			env.ssao_light_affect = 0.0
	_log("SSAO: %s" % ("ON" if enabled else "OFF"))


func on_ssil_toggled(enabled: bool) -> void:
	_visual_state["ssil"] = enabled
	var env := _get_active_environment()
	if env:
		env.ssil_enabled = enabled
		if enabled:
			env.ssil_radius = 5.0
			env.ssil_intensity = 1.0
			env.ssil_sharpness = 0.98
			env.ssil_normal_rejection = 1.0
	_log("SSIL: %s" % ("ON" if enabled else "OFF"))


func on_glow_toggled(enabled: bool) -> void:
	_visual_state["glow"] = enabled
	var env := _get_active_environment()
	if env:
		env.glow_enabled = enabled
		if enabled:
			env.glow_intensity = 0.3
			env.glow_bloom = 0.0
			env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
			env.glow_hdr_threshold = 1.0
			env.glow_hdr_scale = 2.0
			env.glow_hdr_luminance_cap = 12.0
			env.glow_mix = 0.05
			env.glow_strength = 1.0
			env.set("glow_levels/2", 0.8)
			env.set("glow_levels/3", 0.4)
			env.set("glow_levels/4", 0.1)
	_log("Glow: %s" % ("ON" if enabled else "OFF"))


## Engine froxel volumetric fog ONLY — light scattering near the camera that
## lets the sun/lights form shafts (god rays). This toggle used to ALSO enable
## the ground-fog compute effect ("volumetric_fog" in ShaderManager), which
## is why turning volumetric fog on silently brought the ground fog + cloud banks
## with it. The two are now fully separate: ground fog has its own toggle
## (on_ground_fog_toggled).
func on_native_volumetric_fog_toggled(enabled: bool) -> void:
	_visual_state["volumetric_fog"] = enabled
	var env := _get_active_environment()
	if env:
		env.volumetric_fog_enabled = enabled
		# Only write parameter values when weather is NOT active.
		# When weather is active, WeatherRenderer owns these values.
		if enabled and not weather_active:
			_apply_volumetric_fog_defaults(env)
	# Boost sun's volumetric fog energy for stronger god rays
	if not weather_active:
		_set_sun_volumetric_energy(6.0 if enabled else 1.0)
	_log("Volumetric Fog (engine froxel): %s" % ("ON" if enabled else "OFF"))


## Set the Depth Fog strength (independent per-fog). Writes the Environment only
## when weather is off — WeatherRenderer owns the density while weather is active.
func set_depth_fog_strength(value: float) -> void:
	_visual_state["depth_fog_strength"] = value
	if weather_active:
		return
	var env := _get_active_environment()
	if env and _visual_state["depth_fog"]:
		env.fog_density = 0.00025 * value
		env.fog_height_density = 0.003 * value


## Set the Volumetric (froxel) Fog strength (independent per-fog). Weather-off
## only; WeatherRenderer owns the density while weather is active.
func set_volumetric_fog_strength(value: float) -> void:
	_visual_state["volumetric_fog_strength"] = value
	if weather_active:
		return
	var env := _get_active_environment()
	if env and _visual_state["volumetric_fog"]:
		env.volumetric_fog_density = 0.0015 * value


func on_depth_fog_toggled(enabled: bool) -> void:
	_visual_state["depth_fog"] = enabled
	var env := _get_active_environment()
	if env:
		env.fog_enabled = enabled
		# Only write parameter values when weather is NOT active.
		# When weather is active, WeatherRenderer owns these values.
		if enabled and not weather_active:
			_apply_depth_fog_defaults(env)
	_log("Depth Fog: %s" % ("ON" if enabled else "OFF"))


func on_tonemapper_changed(index: int) -> void:
	var modes := [
		Environment.TONE_MAPPER_FILMIC,
		Environment.TONE_MAPPER_ACES,
		Environment.TONE_MAPPER_AGX,
		Environment.TONE_MAPPER_LINEAR,
	]
	var names := ["Filmic", "ACES", "AgX", "Linear"]
	if index < 0 or index >= modes.size():
		return
	_visual_state["tonemap_mode"] = modes[index]
	var env := _get_active_environment()
	if env:
		env.tonemap_mode = modes[index]
	_log("Tonemapper: %s" % names[index])


func on_shadow_cascades_toggled(enabled: bool) -> void:
	_visual_state["shadow_cascades"] = enabled
	# Apply to fallback light
	_apply_shadow_cascades(_fallback_light)
	# Apply to SkyManager sun if available
	if sky_manager:
		_apply_shadow_cascades(sky_manager.get_sun_light())
	_log("Shadow 4-split cascades: %s" % ("ON" if enabled else "OFF"))


## Set the volumetric fog energy on the active sun DirectionalLight3D.
## Higher values = brighter god rays without increasing overall fog density.
func _set_sun_volumetric_energy(energy: float) -> void:
	# Try SkyManager's sun first
	if sky_manager and show_sky:
		var sun: DirectionalLight3D = sky_manager.get_sun_light()
		if sun:
			sun.light_volumetric_fog_energy = energy
			return
	# Fallback light
	if _fallback_light:
		_fallback_light.light_volumetric_fog_energy = energy


## Get the root viewport (via callback or fallback).
func _get_viewport() -> Viewport:
	var cb: Callable = _cb.get("get_viewport", Callable())
	if cb.is_valid():
		return cb.call()
	return null


# ── Sky/Day-Night Cycle ──

## Toggle sky/day-night cycle visibility.
func on_show_sky_toggled(enabled: bool) -> void:
	show_sky = enabled

	if enabled:
		# Create SkyManager lazily on first enable
		if not sky_manager:
			_create_sky_manager()

		# Enable SkyManager — add to tree if not already there
		if sky_manager:
			if not sky_manager.is_inside_tree():
				_add_child(sky_manager)
			sky_manager.enabled = true
		# Remove fallback from tree (only one WorldEnvironment can be active)
		if _fallback_world_env and _fallback_world_env.is_inside_tree():
			_remove_child(_fallback_world_env)
		if _fallback_light:
			_fallback_light.visible = false
	else:
		# Disable and remove SkyManager from tree so fallback can take over
		if sky_manager:
			if sky_manager.is_inside_tree():
				_remove_child(sky_manager)
			sky_manager.enabled = false
		# Add fallback back to tree AFTER SkyManager is removed
		if _fallback_world_env:
			if not _fallback_world_env.is_inside_tree():
				_add_child(_fallback_world_env)
			_fallback_world_env.environment = _fallback_world_env.environment
		if _fallback_light:
			_fallback_light.visible = true

	# Re-apply visual state to the newly active environment
	_apply_visual_state(_get_active_environment())

	# Re-apply shadow cascades to the active light
	if enabled and sky_manager:
		_apply_shadow_cascades(sky_manager.get_sun_light())
		# Wire sun into ShaderManager so godrays/fog get the sun reference
		ShaderManager.set_sun(sky_manager.get_sun_light())
		# Enable sun-dependent effects (only if their toggle is actually ON)
		ensure_shader_manager_attached()
		ShaderManager.enable_effect("sky_transmittance", 0.0)
		if _panels and _panels.godrays_toggle and _panels.godrays_toggle.button_pressed:
			ShaderManager.enable_effect("godrays", 0.3)
	else:
		_apply_shadow_cascades(_fallback_light)
		# Disable sun-dependent effects when sky is off
		ShaderManager.disable_effect("godrays", 0.3)
		ShaderManager.disable_effect("sky_transmittance", 0.0)

	# Enable/disable godrays checkbox based on sky state (godrays need sun)
	if _panels and _panels.godrays_toggle:
		_panels.godrays_toggle.disabled = not enabled
		if not enabled and _panels.godrays_toggle.button_pressed:
			_panels.godrays_toggle.set_pressed_no_signal(false)

	# Notify weather_controls so SunshineClouds2 enables/disables with sky
	var sky_cb: Callable = _cb.get("sky_visibility_changed", Callable())
	if sky_cb.is_valid():
		sky_cb.call(enabled)

	_log("Sky/Day-Night: %s" % ("ON" if enabled else "OFF"))
	_update_stats()


# ── Private methods ──

## Create SkyManager lazily (only called on first sky toggle).
func _create_sky_manager() -> void:
	if sky_manager:
		return

	_log("Initializing SkyManager...")

	# Remove fallback environment BEFORE adding SkyManager (only one WorldEnvironment can be active)
	if _fallback_world_env and _fallback_world_env.is_inside_tree():
		_remove_child(_fallback_world_env)
	if _fallback_light:
		_fallback_light.visible = false

	sky_manager = SkyManager.new()
	sky_manager.name = "SkyManager"

	# Add to scene tree — triggers _ready() → _initialize()
	_add_child(sky_manager)

	# Apply tracked visual state to SkyManager's environment
	var env: Environment = sky_manager.get_environment()
	if env:
		env.tonemap_mode = _visual_state["tonemap_mode"]
		_apply_visual_state(env)

	# Initial update at noon
	sky_manager.update(12.0)

	_log("SkyManager initialized")


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
