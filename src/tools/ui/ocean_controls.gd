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

# ── Public state (readable by world_explorer) ──

var show_ocean: bool = false


# ── Private state ──

var _ocean_configured: bool = false
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


## Per-frame ocean sync hook. Screen-reading water no longer needs a receiver stack.
func process(_delta: float) -> void:
	pass


## Handle wave scale change.
func on_wave_scale_changed(value: float) -> void:
	_panels.update_slider_label(_panels.wave_scale_slider, value)
	if OceanManager:
		OceanManager.wave_scale = value
		if OceanManager._ocean_mesh:
			OceanManager._ocean_mesh.set_wave_scale(value)


## Handle choppiness change. Routes through OceanManager.set_choppiness
## which writes per-cascade swell + spread (directionality).
func on_choppiness_changed(value: float) -> void:
	_panels.update_slider_label(_panels.choppiness_slider, value)
	if OceanManager and OceanManager.has_method("set_choppiness"):
		OceanManager.set_choppiness(value)


## Toggle debug shore mask visualization.
func on_debug_shore_toggled(enabled: bool) -> void:
	if OceanManager and OceanManager._ocean_mesh:
		OceanManager._ocean_mesh.set_debug_shore_mask(enabled)
		_log("Debug shore mask: %s" % ("ON" if enabled else "OFF"))


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

	_ocean_configured = true
	_sync_ocean_render_layers()
	_sync_water_quality_dropdown()
	_log("Ocean configured (quality: %s, sea level: %.1f)" % [
		OceanManager.get_water_quality_name(), OceanManager.sea_level])


func _sync_ocean_render_layers() -> void:
	if not OceanManager:
		return
	if OceanManager._ocean_mesh:
		OceanManager._ocean_mesh.layers = WATER_RENDER_LAYER_MASK
	if OceanManager.has_method("set_sea_spray_render_layers"):
		OceanManager.set_sea_spray_render_layers(WATER_RENDER_LAYER_MASK)


## Sync ocean slider values with current ocean manager settings.
func _sync_ocean_sliders() -> void:
	if not OceanManager or not _panels:
		return
	if _panels.wave_scale_slider:
		_panels.wave_scale_slider.value = OceanManager.wave_scale
		_panels.update_slider_label(_panels.wave_scale_slider, OceanManager.wave_scale)


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
