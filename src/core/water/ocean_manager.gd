## OceanManager - Main coordinator for the ocean water system
## Manages ocean mesh, shore dampening, and buoyancy queries via GerstnerMath
## Autoload singleton: accessible via OceanManager global
## OPTIONAL SYSTEM - Can be completely disabled via project settings
class_name OceanManagerClass
extends Node

# Project settings paths
const SETTING_ENABLED := "ocean/enabled"
const SETTING_SEA_LEVEL := "ocean/sea_level"
const SETTING_RADIUS := "ocean/radius"
const SETTING_QUALITY := "ocean/quality"

## Get prebaked shore mask path from SettingsManager
func _get_shore_mask_path() -> String:
	return SettingsManager.get_ocean_path().path_join("shore_mask.png")

# Ocean configuration
@export var ocean_radius: float = 50000.0  # 50km clipmap radius
@export var shore_fade_distance: float = 50.0  # Meters to fade waves near shore
@export var shore_mask_resolution: int = 4096
@export var use_prebaked_shore_mask: bool = true

# Sea level
@export var sea_level: float = 0.0

# Quality settings
@export_group("Quality Settings")
## Water quality: -1 = auto, 0 = flat, 1 = standard
@export_range(-1, 1) var water_quality: int = -1

# Wave parameters (exposed for UI control)
@export_group("Wave Settings")
@export var wave_scale: float = 1.0

# System state
var _system_initialized: bool = false
var _system_enabled: bool = false

# Internal state
var _ocean_mesh: OceanMesh = null
var _shore_mask: ShoreMaskGenerator = null
var _terrain: Terrain3D = null
var _camera: Camera3D = null
var _enabled: bool = true
var _time: float = 0.0
var _auto_find_camera: bool = true

# Signals
signal ocean_initialized()


func _ready() -> void:
	_register_project_settings()

	var is_autoload := get_parent() == get_tree().root and name == "OceanManager"
	if is_autoload:
		_system_enabled = ProjectSettings.get_setting(SETTING_ENABLED, false)
		if not _system_enabled:
			Log.info("water", "OceanManager: System disabled via project settings")
			return
	else:
		_system_enabled = true

	_ocean_mesh = OceanMesh.new()
	_ocean_mesh.name = "OceanMesh"
	add_child(_ocean_mesh)

	_shore_mask = ShoreMaskGenerator.new()
	_shore_mask.name = "ShoreMaskGenerator"
	add_child(_shore_mask)

	call_deferred("_deferred_init")


func _register_project_settings() -> void:
	if not ProjectSettings.has_setting(SETTING_ENABLED):
		ProjectSettings.set_setting(SETTING_ENABLED, false)
		ProjectSettings.set_initial_value(SETTING_ENABLED, false)
		ProjectSettings.add_property_info({
			"name": SETTING_ENABLED,
			"type": TYPE_BOOL,
			"hint_string": "Enable ocean water system globally"
		})

	if not ProjectSettings.has_setting(SETTING_SEA_LEVEL):
		ProjectSettings.set_setting(SETTING_SEA_LEVEL, 0.0)
		ProjectSettings.set_initial_value(SETTING_SEA_LEVEL, 0.0)
		ProjectSettings.add_property_info({
			"name": SETTING_SEA_LEVEL,
			"type": TYPE_FLOAT,
			"hint_string": "Sea level height in world units"
		})

	if not ProjectSettings.has_setting(SETTING_RADIUS):
		ProjectSettings.set_setting(SETTING_RADIUS, 25000.0)
		ProjectSettings.set_initial_value(SETTING_RADIUS, 25000.0)
		ProjectSettings.add_property_info({
			"name": SETTING_RADIUS,
			"type": TYPE_FLOAT,
			"hint_string": "Ocean clipmap radius in meters"
		})

	if not ProjectSettings.has_setting(SETTING_QUALITY):
		ProjectSettings.set_setting(SETTING_QUALITY, -1)
		ProjectSettings.set_initial_value(SETTING_QUALITY, -1)
		ProjectSettings.add_property_info({
			"name": SETTING_QUALITY,
			"type": TYPE_INT,
			"hint": PROPERTY_HINT_RANGE,
			"hint_string": "-1,1,1"
		})


func _deferred_init() -> void:
	sea_level = ProjectSettings.get_setting(SETTING_SEA_LEVEL, 0.0)
	ocean_radius = ProjectSettings.get_setting(SETTING_RADIUS, 8000.0)
	water_quality = ProjectSettings.get_setting(SETTING_QUALITY, -1)

	HardwareDetection.detect()
	_find_terrain()

	_ocean_mesh.initialize(ocean_radius, water_quality)
	_update_shader_parameters()
	_load_shore_mask()

	_system_initialized = true
	ocean_initialized.emit()

	var mode := "Standard" if _ocean_mesh.get_quality() == OceanMesh.QualityMode.STANDARD else "Flat"
	Log.info("water", "OceanManager: Initialized - sea level: %.1f, radius: %.0fm, mode: %s" % [
		sea_level, ocean_radius, mode])


func _load_shore_mask() -> void:
	var shore_mask_loaded := false

	# Try prebaked shore mask first
	var shore_mask_path := _get_shore_mask_path()
	if use_prebaked_shore_mask and FileAccess.file_exists(shore_mask_path):
		var prebaked := ShoreMaskBaker.load_prebaked(shore_mask_path)
		if not prebaked.is_empty():
			var tex: Texture2D = prebaked.texture
			var bounds: Rect2 = prebaked.bounds
			_ocean_mesh.set_shore_mask(tex, bounds)
			shore_mask_loaded = true
			Log.info("water", "OceanManager: Using prebaked shore mask from %s" % shore_mask_path)

	# Fall back to runtime generation if terrain available
	if not shore_mask_loaded and _terrain:
		Log.info("water", "OceanManager: Generating shore mask at runtime...")
		_shore_mask.generate_from_terrain(_terrain, shore_mask_resolution, shore_fade_distance, sea_level)
		_ocean_mesh.set_shore_mask(
			_shore_mask.get_shore_mask_texture(),
			_shore_mask.get_world_bounds()
		)
		shore_mask_loaded = true

	if not shore_mask_loaded:
		Log.warn("water", "OceanManager: No shore mask available - ocean will appear everywhere")


func _process(delta: float) -> void:
	if not _system_enabled or not _enabled:
		return

	_time = Time.get_ticks_msec() / 1000.0

	# Auto-find camera
	if not _camera and _auto_find_camera:
		_camera = _find_active_camera()

	# Update ocean mesh position to follow camera
	if _camera:
		var cam_pos := _camera.global_position
		var new_pos := Vector3(cam_pos.x, sea_level, cam_pos.z)
		_ocean_mesh.update_position(new_pos)


func _find_active_camera() -> Camera3D:
	var viewport := get_viewport()
	if viewport:
		var cam := viewport.get_camera_3d()
		if cam:
			return cam

	var cameras := get_tree().get_nodes_in_group("camera")
	if cameras.size() > 0 and cameras[0] is Camera3D:
		return cameras[0] as Camera3D

	return _find_node_by_class(get_tree().root, "Camera3D") as Camera3D


func _find_terrain() -> void:
	var terrains := get_tree().get_nodes_in_group("terrain")
	if terrains.size() > 0 and terrains[0] is Terrain3D:
		_terrain = terrains[0] as Terrain3D
		return
	_terrain = _find_node_by_class(get_tree().root, "Terrain3D") as Terrain3D


func _find_node_by_class(node: Node, class_name_str: String) -> Node:
	if node.get_class() == class_name_str:
		return node
	for child in node.get_children():
		var result := _find_node_by_class(child, class_name_str)
		if result:
			return result
	return null


func _update_shader_parameters() -> void:
	if not _ocean_mesh:
		return
	_ocean_mesh.set_wave_scale(wave_scale)


# ============================================================================
# WAVE QUERIES — Uses GerstnerMath for CPU-side wave evaluation
# ============================================================================

## Get the wave height at a world position (for buoyancy)
func get_wave_height(world_pos: Vector3) -> float:
	if not _system_enabled or not _enabled:
		return sea_level

	# Check shore mask — if on land, no water
	if _shore_mask and _terrain:
		var shore_factor := _shore_mask.get_shore_factor(world_pos)
		if shore_factor <= 0.01:
			return sea_level - 1000.0

	var shore_factor := _get_shore_factor(world_pos)
	var cam_pos := _camera.global_position if _camera else Vector3.ZERO
	var disp := GerstnerMath.get_displacement(world_pos, _time, shore_factor * wave_scale, cam_pos)
	return sea_level + disp.y


## Get wave displacement vector at world position
func get_wave_displacement(world_pos: Vector3) -> Vector3:
	if not _system_enabled or not _enabled:
		return Vector3.ZERO
	var shore_factor := _get_shore_factor(world_pos)
	var cam_pos := _camera.global_position if _camera else Vector3.ZERO
	return GerstnerMath.get_displacement(world_pos, _time, shore_factor * wave_scale, cam_pos)


## Get wave normal at world position
func get_wave_normal(world_pos: Vector3) -> Vector3:
	if not _system_enabled or not _enabled:
		return Vector3.UP
	var shore_factor := _get_shore_factor(world_pos)
	var cam_pos := _camera.global_position if _camera else Vector3.ZERO
	return GerstnerMath.get_normal(world_pos, _time, shore_factor * wave_scale, cam_pos)


func _get_shore_factor(world_pos: Vector3) -> float:
	if _shore_mask:
		return _shore_mask.get_shore_factor(world_pos)
	return 1.0


## Check if a position is in ocean water
func is_in_ocean(world_pos: Vector3) -> bool:
	if not _system_enabled or not _enabled:
		return false
	if world_pos.y > sea_level + 10.0:
		return false
	if _shore_mask:
		return _shore_mask.get_shore_factor(world_pos) > 0.01
	if _terrain and _terrain.data:
		var terrain_height: float = _terrain.data.get_height(world_pos)
		return terrain_height < sea_level
	return true


# ============================================================================
# PUBLIC API
# ============================================================================

func set_camera(camera: Camera3D) -> void:
	_camera = camera
	_auto_find_camera = false


func set_sea_level(level: float) -> void:
	sea_level = level
	if not _system_enabled:
		return
	if _terrain and _shore_mask:
		_shore_mask.generate_from_terrain(_terrain, shore_mask_resolution, shore_fade_distance, sea_level)
		if _ocean_mesh:
			_ocean_mesh.set_shore_mask(
				_shore_mask.get_shore_mask_texture(),
				_shore_mask.get_world_bounds()
			)


func get_sea_level() -> float:
	return sea_level


func set_terrain(terrain: Terrain3D) -> void:
	_terrain = terrain
	if not _system_enabled:
		return
	_load_shore_mask()


func regenerate_shore_mask() -> void:
	if not _system_enabled:
		return
	if _shore_mask and _terrain:
		_shore_mask.generate_from_terrain(_terrain, shore_mask_resolution, shore_fade_distance, sea_level)
		if _ocean_mesh:
			_ocean_mesh.set_shore_mask(
				_shore_mask.get_shore_mask_texture(),
				_shore_mask.get_world_bounds()
			)


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	if _ocean_mesh:
		_ocean_mesh.visible = enabled


func get_time() -> float:
	return _time


func get_ocean_mesh() -> OceanMesh:
	return _ocean_mesh


func get_shore_mask_generator() -> ShoreMaskGenerator:
	return _shore_mask


func is_system_enabled() -> bool:
	return _system_enabled


func is_initialized() -> bool:
	return _system_initialized


func toggle_ocean() -> bool:
	if _system_enabled and _system_initialized:
		set_enabled(false)
		_system_enabled = false
		Log.info("water", "OceanManager: Ocean disabled")
	else:
		if not _system_initialized:
			force_initialize()
		set_enabled(true)
		Log.info("water", "OceanManager: Ocean enabled (mode: %s)" % get_water_quality_name())
	return _system_enabled


static func is_hardware_suitable() -> bool:
	HardwareDetection.detect()
	var quality := HardwareDetection.get_recommended_quality()
	return quality != HardwareDetection.WaterQuality.ULTRA_LOW


func force_initialize() -> void:
	if _system_initialized:
		return
	Log.info("water", "OceanManager: Force initializing ocean system...")
	_system_enabled = true

	if not _ocean_mesh:
		_ocean_mesh = OceanMesh.new()
		_ocean_mesh.name = "OceanMesh"
		add_child(_ocean_mesh)

	if not _shore_mask:
		_shore_mask = ShoreMaskGenerator.new()
		_shore_mask.name = "ShoreMaskGenerator"
		add_child(_shore_mask)

	_deferred_init()

	if _ocean_mesh:
		_ocean_mesh.visible = true


func get_water_quality() -> OceanMesh.QualityMode:
	if _ocean_mesh:
		return _ocean_mesh.get_quality()
	return OceanMesh.QualityMode.STANDARD


func set_water_quality(quality: int) -> void:
	water_quality = quality
	if not _system_enabled or not _ocean_mesh:
		return

	var target_quality: OceanMesh.QualityMode
	if quality == 0:
		target_quality = OceanMesh.QualityMode.FLAT
	else:
		target_quality = OceanMesh.QualityMode.STANDARD

	_ocean_mesh.set_quality(target_quality, ocean_radius)
	Log.info("water", "OceanManager: Quality changed to: %s" % get_water_quality_name())


func get_water_quality_name() -> String:
	if _ocean_mesh:
		match _ocean_mesh.get_quality():
			OceanMesh.QualityMode.STANDARD:
				return "Standard"
			_:
				return "Flat"
	return "Unknown"


func is_integrated_gpu() -> bool:
	return HardwareDetection.is_integrated_gpu()


func get_gpu_name() -> String:
	return HardwareDetection.get_gpu_name()
