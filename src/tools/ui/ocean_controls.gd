## Ocean/water control logic for WorldExplorer.
##
## Extracted from world_explorer.gd (Session 4). Manages ocean configuration,
## parameter changes, quality settings, and slider sync using the global WaterSystem.
##
## Usage:
## [codeblock]
## var controls := OceanControls.new(callbacks)
## controls.set_panels(panels)
## [/codeblock]
class_name OceanControls
extends RefCounted

const RenderLayersScript := preload("res://src/core/world/render_layers.gd")

const WATER_RENDER_LAYER_MASK: int = RenderLayersScript.WATER_SURFACE
const MAIN_SCENE_WATER_QUALITY: int = OceanMesh.QualityMode.HIGH
const MAIN_SCENE_MESH_MODE: int = OceanMesh.MeshMode.CLIPMAP
const MAIN_SCENE_SURFACE_SHADER: int = OceanMesh.SurfaceShaderMode.BOUJIE_EXPERIMENTAL
const UNDERWATER_EFFECT_NAME := "underwater_medium"
const MAIN_SCENE_UNDERWATER_QUALITY: int = 2
const MAIN_SCENE_UNDERWATER_PARTICLE_QUALITY: int = 3
const MAIN_SCENE_UNDERWATER_PARTICLE_COUNT: int = 4096
const MAIN_SCENE_UNDERWATER_PARTICLE_SIZE: float = 4.0
const MAIN_SCENE_UNDERWATER_PARTICLE_SPEED: float = 1.5
const MAIN_SCENE_UNDERWATER_PARTICLE_OPACITY: float = 1.0

# ── Public state (readable by world_explorer) ──

var show_ocean: bool = true
var all_water_enabled: bool = true
var rivers_enabled: bool = true
var lakes_pools_enabled: bool = true
var underwater_medium_enabled: bool = true
var underwater_particles_enabled: bool = true
var underwater_features: Dictionary = {
	&"absorption_fog": true,
	&"snell": true,
	&"wobble": true,
	&"caustics": true,
}


# ── Private state ──

var _ocean_configured: bool = false
var _underwater_attached_target: Node = null
var _underwater_particle_defaults_applied: bool = false
var _world_space_ocean_visible: bool = true
var _panels: ExplorerPanels = null

## Callback dictionary — keys are action names, values are Callables on world_explorer
var _cb: Dictionary = {}


## Create the ocean controls.
## [param callbacks] Dictionary mapping action names to Callables:
##   log, add_child, get_active_camera, get_terrain, update_stats
func _init(callbacks: Dictionary) -> void:
	_cb = callbacks


## Set the ExplorerPanels reference (called after panels are constructed).
func set_panels(panels: ExplorerPanels) -> void:
	_panels = panels


## Update the ocean camera (convenience for camera switching).
func set_camera(cam: Camera3D) -> void:
	if cam != null:
		cam.cull_mask = cam.cull_mask | WATER_RENDER_LAYER_MASK
	if WaterSystem and WaterSystem.has_method("set_camera"):
		WaterSystem.set_camera(cam)


## Enable or disable the ocean (convenience for mode switching).
func set_enabled(enabled: bool) -> void:
	if WaterSystem and WaterSystem.has_method("set_enabled"):
		WaterSystem.set_enabled(enabled)
	if WetnessManager:
		WetnessManager.set_enabled(enabled)
		if WetnessManager.has_method("set_live_compositor_enabled"):
			WetnessManager.set_live_compositor_enabled(enabled)
	if not enabled:
		_set_main_scene_underwater_enabled(false)


## Per-frame ocean sync hook.
func process(_delta: float) -> void:
	if not all_water_enabled or not show_ocean or not _world_space_ocean_visible:
		return
	_sync_main_scene_underwater()


## Toggle ocean visibility.
func on_show_ocean_toggled(enabled: bool) -> void:
	show_ocean = enabled

	if _panels and _panels.ocean_controls_container:
		_panels.ocean_controls_container.visible = all_water_enabled

	if enabled and not all_water_enabled:
		set_all_water_enabled(true)

	if enabled:
		set_enabled(true)
		set_world_space_ocean_visible(true)
	else:
		set_world_space_ocean_visible(false)
		set_enabled(false)

	_log("Ocean: %s" % ("ON" if enabled else "OFF"))
	_update_stats()


## Temporarily show/hide exterior ocean rendering without destroying resources
## or changing the user's Ocean toggle preference.
func set_world_space_ocean_visible(visible: bool) -> void:
	_world_space_ocean_visible = visible
	if not WaterSystem:
		return
	if not visible:
		if WaterSystem.has_method("set_water_layer_enabled"):
			WaterSystem.set_water_layer_enabled(&"ocean_surface", false)
		_set_main_scene_underwater_enabled(false)
		return
	if not all_water_enabled or not show_ocean:
		return
	if not WaterSystem.is_initialized():
		WaterSystem.force_initialize()
	if not _ocean_configured:
		_configure_global_ocean()
	var active_camera := _get_active_camera()
	if active_camera:
		set_camera(active_camera)
	if WaterSystem.has_method("set_enabled") and not WaterSystem.is_system_enabled():
		WaterSystem.set_enabled(true)
	if WaterSystem.has_method("set_water_layer_enabled"):
		WaterSystem.set_water_layer_enabled(&"ocean_surface", true)
	_sync_ocean_render_layers()
	_sync_ocean_sliders()


func set_all_water_enabled(enabled: bool) -> void:
	all_water_enabled = enabled
	if _panels and _panels.ocean_controls_container:
		_panels.ocean_controls_container.visible = enabled
	if WaterSystem and WaterSystem.has_method("set_all_water_enabled"):
		WaterSystem.set_all_water_enabled(enabled)
	if WetnessManager:
		WetnessManager.set_enabled(enabled)
		if WetnessManager.has_method("set_live_compositor_enabled"):
			WetnessManager.set_live_compositor_enabled(enabled)
	if not enabled:
		_set_main_scene_underwater_enabled(false)
	elif underwater_medium_enabled:
		_sync_main_scene_underwater()
	_log("All water: %s" % ("ON" if enabled else "OFF"))
	_update_stats()


func set_rivers_enabled(enabled: bool) -> void:
	rivers_enabled = enabled
	if WaterSystem and WaterSystem.has_method("set_water_layer_enabled"):
		WaterSystem.set_water_layer_enabled(&"rivers", enabled)
	_log("Rivers: %s" % ("ON" if enabled else "OFF"))
	_update_stats()


func set_lakes_pools_enabled(enabled: bool) -> void:
	lakes_pools_enabled = enabled
	if WaterSystem and WaterSystem.has_method("set_water_layer_enabled"):
		WaterSystem.set_water_layer_enabled(&"lakes_pools", enabled)
	_log("Lakes/Pools: %s" % ("ON" if enabled else "OFF"))
	_update_stats()


## Handle water quality change.
func on_water_quality_changed(index: int) -> void:
	if not WaterSystem:
		return
	var quality: int = _panels.water_quality_btn.get_item_id(index)
	WaterSystem.set_water_quality(quality)
	_sync_ocean_render_layers()
	_log("Water quality: %s" % WaterSystem.get_water_quality_name())
	_update_stats()


## Handle wave scale change.
func on_wave_scale_changed(value: float) -> void:
	_panels.update_slider_label(_panels.wave_scale_slider, value)
	if WaterSystem:
		if WaterSystem.has_method("set_wave_scale"):
			WaterSystem.set_wave_scale(value)
		else:
			WaterSystem.wave_scale = value
			if WaterSystem._ocean_mesh:
				WaterSystem._ocean_mesh.set_wave_scale(value)


## Handle choppiness change. Routes through WaterSystem.set_choppiness
## which writes per-cascade swell + spread (directionality).
func on_choppiness_changed(value: float) -> void:
	_panels.update_slider_label(_panels.choppiness_slider, value)
	if WaterSystem and WaterSystem.has_method("set_choppiness"):
		WaterSystem.set_choppiness(value)


func on_water_turbidity_changed(value: float) -> void:
	_panels.update_slider_label(_panels.water_turbidity_slider, value)
	set_water_turbidity(value)


func on_water_visibility_changed(value: float) -> void:
	_panels.update_slider_label(_panels.water_visibility_slider, value)
	set_water_visibility_distance(value)


func set_water_turbidity(value: float) -> void:
	if WaterSystem and WaterSystem.has_method("set_water_scattering_strength"):
		WaterSystem.set_water_scattering_strength(value)


func set_water_visibility_distance(value: float) -> void:
	if WaterSystem and WaterSystem.has_method("set_water_visibility_distance"):
		WaterSystem.set_water_visibility_distance(value)


func set_water_color(value: Color) -> void:
	if WaterSystem and WaterSystem.has_method("set_absorption_tint_color"):
		WaterSystem.set_absorption_tint_color(value)


## Toggle debug shore mask visualization.
func on_debug_shore_toggled(enabled: bool) -> void:
	if WaterSystem and WaterSystem._ocean_mesh:
		WaterSystem._ocean_mesh.set_debug_shore_mask(enabled)
		_log("Debug shore mask: %s" % ("ON" if enabled else "OFF"))


func set_underwater_medium_enabled(enabled: bool) -> void:
	underwater_medium_enabled = enabled
	if not enabled and ShaderManager and ShaderManager.is_effect_enabled(UNDERWATER_EFFECT_NAME):
		ShaderManager.disable_effect(UNDERWATER_EFFECT_NAME, 0.0)
	elif enabled and show_ocean:
		_sync_main_scene_underwater()
	_log("Underwater medium: %s" % ("ON" if enabled else "OFF"))


func set_underwater_feature_enabled(feature_name: StringName, enabled: bool) -> void:
	if feature_name == &"particles":
		set_underwater_particles_enabled(enabled)
		return
	if not underwater_features.has(feature_name):
		Log.warn("water", "Unknown underwater feature: %s" % str(feature_name))
		return
	underwater_features[feature_name] = enabled
	var effect := _get_underwater_effect()
	if effect and effect.has_method("set_underwater_feature_enabled"):
		effect.call("set_underwater_feature_enabled", feature_name, enabled)
	_log("Underwater %s: %s" % [str(feature_name), "ON" if enabled else "OFF"])


func is_underwater_feature_enabled(feature_name: StringName) -> bool:
	if feature_name == &"particles":
		return underwater_particles_enabled
	return bool(underwater_features.get(feature_name, false))


func set_underwater_particles_enabled(enabled: bool) -> void:
	underwater_particles_enabled = enabled
	if WaterSystem and WaterSystem.has_method("set_underwater_particles_enabled"):
		WaterSystem.set_underwater_particles_enabled(enabled)
	_log("Underwater particles: %s" % ("ON" if enabled else "OFF"))


func set_underwater_particles_quality(quality: int) -> void:
	if WaterSystem and WaterSystem.has_method("set_underwater_particles_quality"):
		WaterSystem.set_underwater_particles_quality(quality)


func set_underwater_particles_opacity(value: float) -> void:
	if WaterSystem and WaterSystem.has_method("set_underwater_particles_opacity"):
		WaterSystem.set_underwater_particles_opacity(value)


func set_surface_ssr_enabled(enabled: bool) -> void:
	if WaterSystem and WaterSystem.has_method("set_surface_ssr_enabled"):
		WaterSystem.set_surface_ssr_enabled(enabled)
	_log("Water surface SSR: %s" % ("ON" if enabled else "OFF"))


func set_sea_spray_enabled(enabled: bool) -> void:
	if WaterSystem and WaterSystem.has_method("set_sea_spray_enabled"):
		WaterSystem.set_sea_spray_enabled(enabled)
	_log("Sea spray: %s" % ("ON" if enabled else "OFF"))


func set_sea_spray_quality(quality: int) -> void:
	if WaterSystem and WaterSystem.has_method("set_sea_spray_quality"):
		WaterSystem.set_sea_spray_quality(quality)


func get_runtime_status() -> Dictionary:
	var effect := _get_underwater_effect()
	var status := {
		"ocean_enabled": show_ocean,
		"all_water_enabled": all_water_enabled,
		"rivers_enabled": rivers_enabled,
		"lakes_pools_enabled": lakes_pools_enabled,
		"underwater_medium_enabled": underwater_medium_enabled,
		"underwater_particles_enabled": underwater_particles_enabled,
		"underwater_features": underwater_features.duplicate(),
		"underwater_effect_loaded": effect != null,
	}
	if WaterSystem:
		if WaterSystem.has_method("get_underwater_particles_status"):
			status["underwater_particles"] = WaterSystem.get_underwater_particles_status()
		if WaterSystem.has_method("get_sea_spray_status"):
			status["sea_spray"] = WaterSystem.get_sea_spray_status()
		if WaterSystem.has_method("is_surface_ssr_enabled"):
			status["surface_ssr_enabled"] = WaterSystem.is_surface_ssr_enabled()
		if WaterSystem.has_method("get_water_toggle_state"):
			status["water_layers"] = WaterSystem.get_water_toggle_state()
		status["optics"] = {
			"visibility_m": WaterSystem.get_water_visibility_distance() if WaterSystem.has_method("get_water_visibility_distance") else 0.0,
			"turbidity": WaterSystem.get_water_scattering_strength() if WaterSystem.has_method("get_water_scattering_strength") else 0.0,
			"color": WaterSystem.get_absorption_tint_color() if WaterSystem.has_method("get_absorption_tint_color") else Color.BLACK,
		}
	return status


# ── Private methods ──

## Configure the global WaterSystem after force_initialize().
## Sets camera and terrain, syncs UI. Called after force_initialize() creates the mesh.
func _configure_global_ocean() -> void:
	if _ocean_configured:
		return

	_log("Configuring ocean system...")
	_log("[b]GPU:[/b] %s" % HardwareDetection.get_gpu_name())
	if HardwareDetection.is_integrated_gpu():
		_log("[color=yellow]Integrated GPU — using optimized water[/color]")

	# Set camera so ocean follows the player
	var get_camera_cb: Callable = _cb.get("get_active_camera", Callable())
	if get_camera_cb.is_valid():
		var active_camera: Camera3D = get_camera_cb.call()
		if active_camera:
			active_camera.cull_mask = active_camera.cull_mask | WATER_RENDER_LAYER_MASK
			WaterSystem.set_camera(active_camera)

	# Set terrain for shore mask generation (if not already found by force_initialize)
	var get_terrain_cb: Callable = _cb.get("get_terrain", Callable())
	if get_terrain_cb.is_valid():
		var terrain: Terrain3D = get_terrain_cb.call()
		if terrain and not WaterSystem._terrain:
			WaterSystem.set_terrain(terrain)

	_apply_main_scene_ocean_defaults()
	_ocean_configured = true
	_sync_ocean_render_layers()
	_sync_water_quality_dropdown()
	_log("Ocean configured (quality: %s, mesh: %s, shader: %s, sea level: %.1f)" % [
		WaterSystem.get_water_quality_name(),
		"Projected" if WaterSystem.get_mesh_mode() == OceanMesh.MeshMode.PROJECTED else "Clipmap",
		WaterSystem.get_surface_shader_mode_name(),
		WaterSystem.sea_level,
	])


func _apply_main_scene_ocean_defaults() -> void:
	if not WaterSystem:
		return
	WaterSystem.set_water_quality(MAIN_SCENE_WATER_QUALITY)
	if WaterSystem.has_method("rebuild_mesh_with_mode") and WaterSystem.get_mesh_mode() != MAIN_SCENE_MESH_MODE:
		WaterSystem.rebuild_mesh_with_mode(MAIN_SCENE_MESH_MODE)
	if WaterSystem.has_method("set_surface_shader_mode"):
		WaterSystem.set_surface_shader_mode(MAIN_SCENE_SURFACE_SHADER)


func _sync_main_scene_underwater() -> void:
	if not WaterSystem or not WaterSystem.is_initialized():
		return
	if not _attach_shader_manager_to_active_view():
		return
	if underwater_medium_enabled and not ShaderManager.is_effect_enabled(UNDERWATER_EFFECT_NAME):
		ShaderManager.enable_effect(UNDERWATER_EFFECT_NAME, 0.0)

	var effect := ShaderManager.get_effect(UNDERWATER_EFFECT_NAME)
	if effect == null:
		_apply_underwater_particle_defaults()
		return

	_configure_underwater_effect(effect)

	var state: WaterSurfaceState = WaterSystem.get_water_surface_state()
	var camera_water := _get_camera_water_query(state)
	var local_water_level := float(camera_water.get("height", _get_fallback_water_level(state)))
	var underwater_active := underwater_medium_enabled and _is_camera_underwater(camera_water)
	effect.effect_enabled = underwater_active
	effect.blend_factor = 1.0 if underwater_active else 0.0
	if effect.has_method("sync_from_water_state"):
		effect.call("sync_from_water_state", state)
	if effect.has_method("set_camera_water_level"):
		effect.call("set_camera_water_level", local_water_level)


func _set_main_scene_underwater_enabled(enabled: bool) -> void:
	if enabled:
		_sync_main_scene_underwater()
		return
	if ShaderManager and ShaderManager.is_effect_enabled(UNDERWATER_EFFECT_NAME):
		ShaderManager.disable_effect(UNDERWATER_EFFECT_NAME, 0.0)
	if WaterSystem and WaterSystem.has_method("set_underwater_particles_enabled"):
		WaterSystem.set_underwater_particles_enabled(false)
	_underwater_particle_defaults_applied = false


func _attach_shader_manager_to_active_view() -> bool:
	var target: Node = _get_active_world_environment()
	if target == null:
		target = _get_active_camera()
	if target == null or not target.is_inside_tree():
		return false
	if _underwater_attached_target != target:
		ShaderManager.attach_to(target)
		_underwater_attached_target = target
	return true


func _configure_underwater_effect(effect: PostProcessEffect) -> void:
	if effect.has_method("set_quality_tier"):
		effect.call("set_quality_tier", MAIN_SCENE_UNDERWATER_QUALITY)
	if effect.has_method("set_underwater_feature_enabled"):
		for feature_name: StringName in underwater_features:
			effect.call("set_underwater_feature_enabled", feature_name, bool(underwater_features[feature_name]))
	_push_underwater_sun_direction(effect)
	_apply_underwater_particle_defaults()


func _push_underwater_sun_direction(effect: PostProcessEffect) -> void:
	if not effect.has_method("set_sun_direction"):
		return
	var sun := _get_active_sun()
	if sun == null:
		return
	effect.call(
		"set_sun_direction",
		sun.global_basis.z.normalized(),
		clampf(sun.light_energy, 0.0, 1.0)
	)


func _apply_underwater_particle_defaults() -> void:
	if _underwater_particle_defaults_applied or not WaterSystem:
		return
	if WaterSystem.has_method("set_underwater_particles_render_layers"):
		WaterSystem.set_underwater_particles_render_layers(WATER_RENDER_LAYER_MASK)
	if WaterSystem.has_method("set_underwater_particles_enabled"):
		WaterSystem.set_underwater_particles_enabled(underwater_particles_enabled)
	if WaterSystem.has_method("set_underwater_particles_quality"):
		WaterSystem.set_underwater_particles_quality(MAIN_SCENE_UNDERWATER_PARTICLE_QUALITY)
	if WaterSystem.has_method("set_underwater_particles_count"):
		WaterSystem.set_underwater_particles_count(MAIN_SCENE_UNDERWATER_PARTICLE_COUNT)
	if WaterSystem.has_method("set_underwater_particles_size_scale"):
		WaterSystem.set_underwater_particles_size_scale(MAIN_SCENE_UNDERWATER_PARTICLE_SIZE)
	if WaterSystem.has_method("set_underwater_particles_speed_scale"):
		WaterSystem.set_underwater_particles_speed_scale(MAIN_SCENE_UNDERWATER_PARTICLE_SPEED)
	if WaterSystem.has_method("set_underwater_particles_opacity"):
		WaterSystem.set_underwater_particles_opacity(MAIN_SCENE_UNDERWATER_PARTICLE_OPACITY)
	_underwater_particle_defaults_applied = true


func _get_underwater_effect() -> PostProcessEffect:
	if not ShaderManager:
		return null
	return ShaderManager.get_effect(UNDERWATER_EFFECT_NAME)


func _get_camera_water_level(state: WaterSurfaceState) -> float:
	return float(_get_camera_water_query(state).get("height", _get_fallback_water_level(state)))


func _get_camera_water_query(state: WaterSurfaceState) -> Dictionary:
	var camera := _get_active_camera()
	if camera == null:
		return {
			"has_water_body": false,
			"height": _get_fallback_water_level(state),
			"depth": 0.0,
		}
	if state != null:
		var query := state.sample_surface_query(camera.global_position)
		var water_y := float(query.get("height", _get_fallback_water_level(state)))
		var has_body := bool(query.get("has_water_body", false)) and not is_nan(water_y) and water_y > -1.0e20
		return {
			"has_water_body": has_body,
			"height": water_y if has_body else _get_fallback_water_level(state),
			"depth": water_y - camera.global_position.y if has_body else 0.0,
		}
	return {
		"has_water_body": false,
		"height": _get_fallback_water_level(state),
		"depth": 0.0,
	}


func _is_camera_underwater(camera_water: Dictionary) -> bool:
	return bool(camera_water.get("has_water_body", false)) and float(camera_water.get("depth", 0.0)) >= -0.02


func _get_fallback_water_level(state: WaterSurfaceState) -> float:
	if state != null:
		return state.sea_level
	return WaterSystem.sea_level if WaterSystem else ProjectSettings.get_setting("ocean/sea_level", 0.0)


func _get_active_world_environment() -> WorldEnvironment:
	var cb: Callable = _cb.get("get_active_world_environment", Callable())
	if not cb.is_valid():
		return null
	var result: Variant = cb.call()
	return result as WorldEnvironment


func _get_active_camera() -> Camera3D:
	var cb: Callable = _cb.get("get_active_camera", Callable())
	if not cb.is_valid():
		return null
	var result: Variant = cb.call()
	return result as Camera3D


func _get_active_sun() -> DirectionalLight3D:
	var cb: Callable = _cb.get("get_active_sun", Callable())
	if not cb.is_valid():
		return null
	var result: Variant = cb.call()
	return result as DirectionalLight3D


func _sync_ocean_render_layers() -> void:
	if not WaterSystem:
		return
	if WaterSystem._ocean_mesh:
		WaterSystem._ocean_mesh.layers = WATER_RENDER_LAYER_MASK
	if WaterSystem.has_method("set_sea_spray_render_layers"):
		WaterSystem.set_sea_spray_render_layers(WATER_RENDER_LAYER_MASK)
	if WaterSystem.has_method("set_underwater_particles_render_layers"):
		WaterSystem.set_underwater_particles_render_layers(WATER_RENDER_LAYER_MASK)


## Sync ocean slider values with current ocean manager settings.
func _sync_ocean_sliders() -> void:
	if not WaterSystem or not _panels:
		return
	if _panels.wave_scale_slider:
		_panels.wave_scale_slider.value = WaterSystem.wave_scale
		_panels.update_slider_label(_panels.wave_scale_slider, WaterSystem.wave_scale)
	if _panels.water_turbidity_slider and WaterSystem.has_method("get_water_scattering_strength"):
		var turbidity := WaterSystem.get_water_scattering_strength()
		_panels.water_turbidity_slider.value = turbidity
		_panels.update_slider_label(_panels.water_turbidity_slider, turbidity)
	if _panels.water_visibility_slider and WaterSystem.has_method("get_water_visibility_distance"):
		var visibility_m := WaterSystem.get_water_visibility_distance()
		_panels.water_visibility_slider.value = visibility_m
		_panels.update_slider_label(_panels.water_visibility_slider, visibility_m)
	if _panels.water_color_picker and WaterSystem.has_method("get_absorption_tint_color"):
		_panels.water_color_picker.color = WaterSystem.get_absorption_tint_color()


## Sync the water quality dropdown with the current ocean quality.
func _sync_water_quality_dropdown() -> void:
	if not _panels or not _panels.water_quality_btn or not WaterSystem:
		return
	var current_quality := WaterSystem.get_water_quality()
	var target_id: int
	match current_quality:
		OceanMesh.QualityMode.FLAT:
			target_id = 0
		OceanMesh.QualityMode.HIGH:
			target_id = 1
		_:
			target_id = 1

	for i in _panels.water_quality_btn.get_item_count():
		if _panels.water_quality_btn.get_item_id(i) == target_id:
			_panels.water_quality_btn.selected = i
			break


## Log a message via callback.
func _log(message: String) -> void:
	var cb: Callable = _cb.get("log", Callable())
	if cb.is_valid():
		cb.call(message)


## Update stats via callback.
func _update_stats() -> void:
	var cb: Callable = _cb.get("update_stats", Callable())
	if cb.is_valid():
		cb.call()
