## Ocean/water control logic for WorldExplorer.
##
## Extracted from world_explorer.gd (Session 4). Manages ocean creation,
## parameter changes, quality settings, and slider sync. World-affecting
## side effects (scene tree, camera, terrain) are delegated back via callbacks.
##
## Usage:
## [codeblock]
## var controls := OceanControls.new(callbacks)
## controls.set_panels(panels)
## [/codeblock]
class_name OceanControls
extends RefCounted

const OceanManagerScript := preload("res://src/core/water/ocean_manager.gd")

# ── Public state (readable by world_explorer) ──

var ocean_manager: OceanManagerClass = null
var show_ocean: bool = false


# ── Private state ──

var _ocean_initialized: bool = false
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
	if ocean_manager and ocean_manager.has_method("set_camera"):
		ocean_manager.set_camera(cam)


## Enable or disable the ocean (convenience for mode switching).
func set_enabled(enabled: bool) -> void:
	if ocean_manager and ocean_manager.has_method("set_enabled"):
		ocean_manager.set_enabled(enabled)


## Toggle ocean visibility.
func on_show_ocean_toggled(enabled: bool) -> void:
	show_ocean = enabled

	# Show/hide ocean controls panel
	if _panels and _panels.ocean_controls_container:
		_panels.ocean_controls_container.visible = enabled

	if enabled:
		# Create ocean lazily on first enable
		if not _ocean_initialized:
			_create_ocean()

		# Enable ocean
		set_enabled(true)

		# Sync sliders with ocean manager values
		_sync_ocean_sliders()
	else:
		# Disable ocean (if it exists)
		set_enabled(false)

	_log("Ocean: %s" % ("ON" if enabled else "OFF"))
	_update_stats()


## Handle water quality change.
func on_water_quality_changed(index: int) -> void:
	if not ocean_manager:
		return

	# Get the quality value from item ID (-1 = auto, 0-3 = specific quality)
	var quality: int = _panels.water_quality_btn.get_item_id(index)
	ocean_manager.set_water_quality(quality)

	var quality_name: String = ocean_manager.get_water_quality_name()
	_log("Water quality: %s" % quality_name)
	_update_stats()


## Handle wind speed change.
func on_wind_speed_changed(value: float) -> void:
	_panels.update_slider_label(_panels.wind_speed_slider, value)
	if ocean_manager:
		ocean_manager.wind_speed = value
		_update_ocean_wave_params()


## Handle wind direction change.
func on_wind_dir_changed(value: float) -> void:
	_panels.update_slider_label(_panels.wind_dir_slider, value)
	if ocean_manager:
		ocean_manager.wind_direction = deg_to_rad(value)
		_update_ocean_wave_params()


## Handle wave scale change.
func on_wave_scale_changed(value: float) -> void:
	_panels.update_slider_label(_panels.wave_scale_slider, value)
	if ocean_manager:
		ocean_manager.wave_scale = value
		if ocean_manager.has_method("_update_shader_parameters"):
			ocean_manager._update_shader_parameters()


## Handle choppiness change.
func on_choppiness_changed(value: float) -> void:
	_panels.update_slider_label(_panels.choppiness_slider, value)
	if ocean_manager:
		ocean_manager.choppiness = value
		_update_ocean_wave_params()


## Toggle debug shore mask visualization.
func on_debug_shore_toggled(enabled: bool) -> void:
	if ocean_manager and ocean_manager._ocean_mesh:
		ocean_manager._ocean_mesh.set_debug_shore_mask(enabled)
		_log("Debug shore mask: %s" % ("ON" if enabled else "OFF"))


# ── Private methods ──

## Create ocean system lazily (only called on first toggle).
func _create_ocean() -> void:
	if _ocean_initialized:
		return

	_log("Initializing ocean system...")

	if OceanManagerScript == null:
		_log("[color=yellow]Warning: OceanManager script not found[/color]")
		return

	# Run hardware detection and log GPU info
	HardwareDetection.detect()
	_log("[b]GPU Detection:[/b] %s" % HardwareDetection.get_gpu_name())
	if HardwareDetection.is_integrated_gpu():
		_log("[color=yellow]Integrated GPU detected - using optimized water[/color]")
	_log("Recommended water quality: %s" % HardwareDetection.quality_name(HardwareDetection.get_recommended_quality()))

	# Create ocean manager
	ocean_manager = OceanManagerScript.new()
	ocean_manager.name = "OceanManager"

	# Configure for Morrowind
	ocean_manager.ocean_radius = 8000.0  # 8km radius
	ocean_manager.sea_level = 0.0  # Sea level at Y=0 in Godot coords
	ocean_manager.water_quality = -1  # Auto-detect quality based on hardware

	# Add to scene via callback
	var add_child_cb: Callable = _cb.get("add_child", Callable())
	if add_child_cb.is_valid():
		add_child_cb.call(ocean_manager)

	# Set camera for ocean to follow
	var get_camera_cb: Callable = _cb.get("get_active_camera", Callable())
	if get_camera_cb.is_valid():
		var active_camera: Camera3D = get_camera_cb.call()
		if active_camera:
			ocean_manager.set_camera(active_camera)

	# Set terrain reference if available (for shore mask)
	var get_terrain_cb: Callable = _cb.get("get_terrain", Callable())
	if get_terrain_cb.is_valid():
		var terrain: Terrain3D = get_terrain_cb.call()
		if terrain:
			ocean_manager.set_terrain(terrain)

	# Start enabled
	ocean_manager.set_enabled(true)

	_ocean_initialized = true

	# Sync UI dropdown with actual quality
	_sync_water_quality_dropdown()

	_log("Ocean system initialized (quality: %s)" % ocean_manager.get_water_quality_name())


## Sync ocean slider values with current ocean manager settings.
func _sync_ocean_sliders() -> void:
	if not ocean_manager or not _panels:
		return
	if _panels.wind_speed_slider:
		_panels.wind_speed_slider.value = ocean_manager.wind_speed
		_panels.update_slider_label(_panels.wind_speed_slider, ocean_manager.wind_speed)
	if _panels.wind_dir_slider:
		_panels.wind_dir_slider.value = rad_to_deg(ocean_manager.wind_direction)
		_panels.update_slider_label(_panels.wind_dir_slider, rad_to_deg(ocean_manager.wind_direction))
	if _panels.wave_scale_slider:
		_panels.wave_scale_slider.value = ocean_manager.wave_scale
		_panels.update_slider_label(_panels.wave_scale_slider, ocean_manager.wave_scale)
	if _panels.choppiness_slider:
		_panels.choppiness_slider.value = ocean_manager.choppiness
		_panels.update_slider_label(_panels.choppiness_slider, ocean_manager.choppiness)


## Sync the water quality dropdown with the current ocean quality.
func _sync_water_quality_dropdown() -> void:
	if not _panels or not _panels.water_quality_btn or not ocean_manager:
		return

	var current_quality := ocean_manager.get_water_quality()
	# Map QualityMode enum to dropdown item ID
	# FLAT=0, GERSTNER=1, FFT=2, Auto=-1
	var target_id: int
	match current_quality:
		OceanMesh.QualityMode.FLAT:
			target_id = 0
		OceanMesh.QualityMode.GERSTNER:
			target_id = 1
		OceanMesh.QualityMode.FFT:
			target_id = 2
		_:
			target_id = -1  # Auto

	# Find and select the item with matching ID
	for i in _panels.water_quality_btn.get_item_count():
		if _panels.water_quality_btn.get_item_id(i) == target_id:
			_panels.water_quality_btn.selected = i
			break


## Update wave cascade parameters when ocean settings change.
func _update_ocean_wave_params() -> void:
	if not ocean_manager:
		return
	# Update wave parameters in cascades if they exist
	var wave_params: Array[WaveCascadeParameters] = ocean_manager._wave_parameters
	if wave_params.size() > 0:
		for params: WaveCascadeParameters in wave_params:
			params.wind_speed = ocean_manager.wind_speed
			params.wind_direction = ocean_manager.wind_direction


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
