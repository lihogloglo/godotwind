## Ocean/water control logic for WorldExplorer.
##
## Extracted from world_explorer.gd (Session 4). Manages ocean configuration,
## parameter changes, quality settings, and slider sync using the global OceanManager.
##
## Usage:
## [codeblock]
## var controls := OceanControls.new(callbacks)
## controls.set_panels(panels)
## [/codeblock]
class_name OceanControls
extends RefCounted

const WATER_RENDER_LAYER_MASK: int = 1 << 19
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
	if OceanManager and OceanManager.has_method("set_camera"):
		OceanManager.set_camera(cam)


## Enable or disable the ocean (convenience for mode switching).
func set_enabled(enabled: bool) -> void:
	if OceanManager and OceanManager.has_method("set_enabled"):
		OceanManager.set_enabled(enabled)
	if WetnessManager:
		WetnessManager.set_enabled(enabled)
		if WetnessManager.has_method("set_live_compositor_enabled"):
			WetnessManager.set_live_compositor_enabled(enabled)
	if not enabled:
		_set_main_scene_underwater_enabled(false)


## Per-frame ocean sync hook.
func process(_delta: float) -> void:
	if not show_ocean:
		return
	_sync_main_scene_underwater()


## Toggle ocean visibility.
func on_show_ocean_toggled(enabled: bool) -> void:
	show_ocean = enabled

	if _panels and _panels.ocean_controls_container:
		_panels.ocean_controls_container.visible = enabled

	if enabled:
		# Force-initialize if the system hasn't been started yet
		# (ocean/enabled defaults to false in project settings)
		if not OceanManager.is_initialized():
			OceanManager.force_initialize()
		if not _ocean_configured:
			_configure_global_ocean()
		set_enabled(true)
		_sync_ocean_sliders()
	else:
		set_enabled(false)

	_log("Ocean: %s" % ("ON" if enabled else "OFF"))
	_update_stats()


## Handle water quality change.
func on_water_quality_changed(index: int) -> void:
	if not OceanManager:
		return
	var quality: int = _panels.water_quality_btn.get_item_id(index)
	OceanManager.set_water_quality(quality)
	_sync_ocean_render_layers()
	_log("Water quality: %s" % OceanManager.get_water_quality_name())
	_update_stats()


## Handle wave scale change.
func on_wave_scale_changed(value: float) -> void:
	_panels.update_slider_label(_panels.wave_scale_slider, value)
	if OceanManager:
		if OceanManager.has_method("set_wave_scale"):
			OceanManager.set_wave_scale(value)
		else:
			OceanManager.wave_scale = value
			if OceanManager._ocean_mesh:
				OceanManager._ocean_mesh.set_wave_scale(value)


## Handle choppiness change. Routes through OceanManager.set_choppiness
## which writes per-cascade swell + spread (directionality).
func on_choppiness_changed(value: float) -> void:
	_panels.update_slider_label(_panels.choppiness_slider, value)
	if OceanManager and OceanManager.has_method("set_choppiness"):
		OceanManager.set_choppiness(value)


func on_water_turbidity_changed(value: float) -> void:
	_panels.update_slider_label(_panels.water_turbidity_slider, value)
	set_water_turbidity(value)


func on_water_visibility_changed(value: float) -> void:
	_panels.update_slider_label(_panels.water_visibility_slider, value)
	set_water_visibility_distance(value)


func set_water_turbidity(value: float) -> void:
	if OceanManager and OceanManager.has_method("set_water_scattering_strength"):
		OceanManager.set_water_scattering_strength(value)


func set_water_visibility_distance(value: float) -> void:
	if OceanManager and OceanManager.has_method("set_water_visibility_distance"):
		OceanManager.set_water_visibility_distance(value)


func set_water_color(value: Color) -> void:
	if OceanManager and OceanManager.has_method("set_absorption_tint_color"):
		OceanManager.set_absorption_tint_color(value)


## Toggle debug shore mask visualization.
func on_debug_shore_toggled(enabled: bool) -> void:
	if OceanManager and OceanManager._ocean_mesh:
		OceanManager._ocean_mesh.set_debug_shore_mask(enabled)
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
	if OceanManager and OceanManager.has_method("set_underwater_particles_enabled"):
		OceanManager.set_underwater_particles_enabled(enabled)
	_log("Underwater particles: %s" % ("ON" if enabled else "OFF"))


func set_underwater_particles_quality(quality: int) -> void:
	if OceanManager and OceanManager.has_method("set_underwater_particles_quality"):
		OceanManager.set_underwater_particles_quality(quality)


func set_underwater_particles_opacity(value: float) -> void:
	if OceanManager and OceanManager.has_method("set_underwater_particles_opacity"):
		OceanManager.set_underwater_particles_opacity(value)


func set_surface_ssr_enabled(enabled: bool) -> void:
	if OceanManager and OceanManager.has_method("set_surface_ssr_enabled"):
		OceanManager.set_surface_ssr_enabled(enabled)
	_log("Water surface SSR: %s" % ("ON" if enabled else "OFF"))


func set_sea_spray_enabled(enabled: bool) -> void:
	if OceanManager and OceanManager.has_method("set_sea_spray_enabled"):
		OceanManager.set_sea_spray_enabled(enabled)
	_log("Sea spray: %s" % ("ON" if enabled else "OFF"))


func set_sea_spray_quality(quality: int) -> void:
	if OceanManager and OceanManager.has_method("set_sea_spray_quality"):
		OceanManager.set_sea_spray_quality(quality)


func get_runtime_status() -> Dictionary:
	var effect := _get_underwater_effect()
	var status := {
		"ocean_enabled": show_ocean,
		"underwater_medium_enabled": underwater_medium_enabled,
		"underwater_particles_enabled": underwater_particles_enabled,
		"underwater_features": underwater_features.duplicate(),
		"underwater_effect_loaded": effect != null,
	}
	if OceanManager:
		if OceanManager.has_method("get_underwater_particles_status"):
			status["underwater_particles"] = OceanManager.get_underwater_particles_status()
		if OceanManager.has_method("get_sea_spray_status"):
			status["sea_spray"] = OceanManager.get_sea_spray_status()
		if OceanManager.has_method("is_surface_ssr_enabled"):
			status["surface_ssr_enabled"] = OceanManager.is_surface_ssr_enabled()
		status["optics"] = {
			"visibility_m": OceanManager.get_water_visibility_distance() if OceanManager.has_method("get_water_visibility_distance") else 0.0,
			"turbidity": OceanManager.get_water_scattering_strength() if OceanManager.has_method("get_water_scattering_strength") else 0.0,
			"color": OceanManager.get_absorption_tint_color() if OceanManager.has_method("get_absorption_tint_color") else Color.BLACK,
		}
	return status


# ── Private methods ──

## Configure the global OceanManager after force_initialize().
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
			OceanManager.set_camera(active_camera)

	# Set terrain for shore mask generation (if not already found by force_initialize)
	var get_terrain_cb: Callable = _cb.get("get_terrain", Callable())
	if get_terrain_cb.is_valid():
		var terrain: Terrain3D = get_terrain_cb.call()
		if terrain and not OceanManager._terrain:
			OceanManager.set_terrain(terrain)

	_apply_main_scene_ocean_defaults()
	_ocean_configured = true
	_sync_ocean_render_layers()
	_sync_water_quality_dropdown()
	_log("Ocean configured (quality: %s, mesh: %s, shader: %s, sea level: %.1f)" % [
		OceanManager.get_water_quality_name(),
		"Projected" if OceanManager.get_mesh_mode() == OceanMesh.MeshMode.PROJECTED else "Clipmap",
		OceanManager.get_surface_shader_mode_name(),
		OceanManager.sea_level,
	])


func _apply_main_scene_ocean_defaults() -> void:
	if not OceanManager:
		return
	OceanManager.set_water_quality(MAIN_SCENE_WATER_QUALITY)
	if OceanManager.has_method("rebuild_mesh_with_mode") and OceanManager.get_mesh_mode() != MAIN_SCENE_MESH_MODE:
		OceanManager.rebuild_mesh_with_mode(MAIN_SCENE_MESH_MODE)
	if OceanManager.has_method("set_surface_shader_mode"):
		OceanManager.set_surface_shader_mode(MAIN_SCENE_SURFACE_SHADER)


func _sync_main_scene_underwater() -> void:
	if not OceanManager or not OceanManager.is_initialized():
		return
	if not _attach_shader_manager_to_active_view():
		return
	if underwater_medium_enabled and not ShaderManager.is_effect_enabled(UNDERWATER_EFFECT_NAME):
		ShaderManager.enable_effect(UNDERWATER_EFFECT_NAME, 0.0)

	var effect := ShaderManager.get_effect(UNDERWATER_EFFECT_NAME)
	if effect == null:
		_apply_underwater_particle_defaults()
		return

	effect.effect_enabled = underwater_medium_enabled
	effect.blend_factor = 1.0 if underwater_medium_enabled else 0.0
	_configure_underwater_effect(effect)

	var state: WaterSurfaceState = OceanManager.get_water_surface_state()
	if effect.has_method("sync_from_water_state"):
		effect.call("sync_from_water_state", state)
	if effect.has_method("set_camera_water_level"):
		effect.call("set_camera_water_level", _get_camera_water_level(state))


func _set_main_scene_underwater_enabled(enabled: bool) -> void:
	if enabled:
		_sync_main_scene_underwater()
		return
	if ShaderManager and ShaderManager.is_effect_enabled(UNDERWATER_EFFECT_NAME):
		ShaderManager.disable_effect(UNDERWATER_EFFECT_NAME, 0.0)
	if OceanManager and OceanManager.has_method("set_underwater_particles_enabled"):
		OceanManager.set_underwater_particles_enabled(false)
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
	if _underwater_particle_defaults_applied or not OceanManager:
		return
	if OceanManager.has_method("set_underwater_particles_render_layers"):
		OceanManager.set_underwater_particles_render_layers(WATER_RENDER_LAYER_MASK)
	if OceanManager.has_method("set_underwater_particles_enabled"):
		OceanManager.set_underwater_particles_enabled(underwater_particles_enabled)
	if OceanManager.has_method("set_underwater_particles_quality"):
		OceanManager.set_underwater_particles_quality(MAIN_SCENE_UNDERWATER_PARTICLE_QUALITY)
	if OceanManager.has_method("set_underwater_particles_count"):
		OceanManager.set_underwater_particles_count(MAIN_SCENE_UNDERWATER_PARTICLE_COUNT)
	if OceanManager.has_method("set_underwater_particles_size_scale"):
		OceanManager.set_underwater_particles_size_scale(MAIN_SCENE_UNDERWATER_PARTICLE_SIZE)
	if OceanManager.has_method("set_underwater_particles_speed_scale"):
		OceanManager.set_underwater_particles_speed_scale(MAIN_SCENE_UNDERWATER_PARTICLE_SPEED)
	if OceanManager.has_method("set_underwater_particles_opacity"):
		OceanManager.set_underwater_particles_opacity(MAIN_SCENE_UNDERWATER_PARTICLE_OPACITY)
	_underwater_particle_defaults_applied = true


func _get_underwater_effect() -> PostProcessEffect:
	if not ShaderManager:
		return null
	return ShaderManager.get_effect(UNDERWATER_EFFECT_NAME)


func _get_camera_water_level(state: WaterSurfaceState) -> float:
	var camera := _get_active_camera()
	if camera == null:
		return OceanManager.sea_level
	if state != null and state.can_sample_height():
		return state.sample_height(camera.global_position, state.sea_level)
	return OceanManager.sea_level


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
	if not OceanManager:
		return
	if OceanManager._ocean_mesh:
		OceanManager._ocean_mesh.layers = WATER_RENDER_LAYER_MASK
	if OceanManager.has_method("set_sea_spray_render_layers"):
		OceanManager.set_sea_spray_render_layers(WATER_RENDER_LAYER_MASK)
	if OceanManager.has_method("set_underwater_particles_render_layers"):
		OceanManager.set_underwater_particles_render_layers(WATER_RENDER_LAYER_MASK)


## Sync ocean slider values with current ocean manager settings.
func _sync_ocean_sliders() -> void:
	if not OceanManager or not _panels:
		return
	if _panels.wave_scale_slider:
		_panels.wave_scale_slider.value = OceanManager.wave_scale
		_panels.update_slider_label(_panels.wave_scale_slider, OceanManager.wave_scale)
	if _panels.water_turbidity_slider and OceanManager.has_method("get_water_scattering_strength"):
		var turbidity := OceanManager.get_water_scattering_strength()
		_panels.water_turbidity_slider.value = turbidity
		_panels.update_slider_label(_panels.water_turbidity_slider, turbidity)
	if _panels.water_visibility_slider and OceanManager.has_method("get_water_visibility_distance"):
		var visibility_m := OceanManager.get_water_visibility_distance()
		_panels.water_visibility_slider.value = visibility_m
		_panels.update_slider_label(_panels.water_visibility_slider, visibility_m)
	if _panels.water_color_picker and OceanManager.has_method("get_absorption_tint_color"):
		_panels.water_color_picker.color = OceanManager.get_absorption_tint_color()


## Sync the water quality dropdown with the current ocean quality.
func _sync_water_quality_dropdown() -> void:
	if not _panels or not _panels.water_quality_btn or not OceanManager:
		return
	var current_quality := OceanManager.get_water_quality()
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
