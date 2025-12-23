## OceanManager - Main coordinator for the ocean water system
## Manages ocean mesh, wave generation, shore dampening, and buoyancy queries
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
@export var ocean_radius: float = 8000.0  # 8km clipmap radius
@export var wave_update_rate: int = 30    # Wave updates per second
@export var shore_fade_distance: float = 50.0  # Meters to fade waves near shore
@export var shore_mask_resolution: int = 2048  # Shore mask texture size
@export var use_prebaked_shore_mask: bool = true  # Try to load prebaked shore mask first

# Sea level - can be configured per world
@export var sea_level: float = 0.0

# Quality settings
@export_group("Quality Settings")
## Water quality level: -1 = auto-detect, 0 = ultra low, 1 = low, 2 = medium, 3 = high
@export_range(-1, 3) var water_quality: int = -1

# Wave parameters
@export_group("Wave Settings")
@export var wind_speed: float = 10.0  # m/s
@export var wind_direction: float = 0.0  # radians
@export var wave_scale: float = 1.0
@export var choppiness: float = 1.0

# Visual settings
@export_group("Visual Settings")
@export var water_color: Color = Color(0.1, 0.15, 0.18, 1.0)
@export var foam_color: Color = Color(0.9, 0.9, 0.9, 1.0)
@export var depth_color_absorption: Vector3 = Vector3(7.5, 22.0, 38.0)

# System state
var _system_initialized: bool = false
var _system_enabled: bool = false  # Whether ocean system is enabled via project settings

# Internal state
var _ocean_mesh: OceanMesh = null
var _wave_generator: WaveGenerator = null
var _shore_mask: ShoreMaskGenerator = null
var _terrain: Terrain3D = null
var _camera: Camera3D = null
var _enabled: bool = true  # Runtime enable/disable (for gameplay)
var _time: float = 0.0
var _wave_update_timer: float = 0.0
var _auto_find_camera: bool = true  # Auto-detect camera if not set

# Displacement texture for CPU sampling (for buoyancy)
var _displacement_image: Image = null
var _displacement_map_size: int = 256

# Wave cascade parameters (for GPU compute mode)
var _wave_parameters: Array[WaveCascadeParameters] = []
var _use_compute: bool = false
var _rng := RandomNumberGenerator.new()

# Signals
signal ocean_initialized()
signal wave_updated()


func _ready() -> void:
	# Register project settings if they don't exist
	_register_project_settings()

	# Only check project settings if we're the autoload singleton
	# Manual instances (created by scenes) should always initialize
	var is_autoload := get_parent() == get_tree().root and name == "OceanManager"

	if is_autoload:
		# Check if system is enabled via project settings
		_system_enabled = ProjectSettings.get_setting(SETTING_ENABLED, false)

		if not _system_enabled:
			print("[OceanManager] System disabled via project settings - skipping initialization")
			return
	else:
		# Manual instance - always enable
		_system_enabled = true

	# Create child systems
	_ocean_mesh = OceanMesh.new()
	_ocean_mesh.name = "OceanMesh"
	add_child(_ocean_mesh)

	_wave_generator = WaveGenerator.new()
	_wave_generator.name = "WaveGenerator"
	add_child(_wave_generator)

	_shore_mask = ShoreMaskGenerator.new()
	_shore_mask.name = "ShoreMaskGenerator"
	add_child(_shore_mask)

	# Defer initialization until terrain is available
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
		ProjectSettings.set_setting(SETTING_RADIUS, 8000.0)
		ProjectSettings.set_initial_value(SETTING_RADIUS, 8000.0)
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
			"hint_string": "-1,3,1"  # -1 = auto, 0-3 = quality levels
		})


func _deferred_init() -> void:
	# Load configuration from project settings
	sea_level = ProjectSettings.get_setting(SETTING_SEA_LEVEL, 0.0)
	ocean_radius = ProjectSettings.get_setting(SETTING_RADIUS, 8000.0)
	water_quality = ProjectSettings.get_setting(SETTING_QUALITY, -1)

	# Run hardware detection first
	HardwareDetection.detect()

	# Try to find terrain in scene
	_find_terrain()

	# Initialize ocean mesh first - it determines quality and mode
	_ocean_mesh.initialize(ocean_radius, water_quality)
	var actual_quality := _ocean_mesh.get_quality()

	# Determine if we use compute based on quality level
	# ONLY HIGH uses GPU FFT compute, MEDIUM/LOW use vertex Gerstner
	_use_compute = actual_quality == HardwareDetection.WaterQuality.HIGH

	if _use_compute:
		# Initialize wave generator for compute mode (HIGH quality only)
		var map_size := 256
		_wave_generator.initialize(map_size)

		if _wave_generator.is_using_compute():
			_setup_wave_cascades(actual_quality)
			# Initialize GPU resources BEFORE trying to get textures
			# This creates the displacement/normal map textures
			_wave_generator.init_gpu(maxi(2, _wave_parameters.size()))

			if _wave_generator.is_initialized():
				_ocean_mesh.set_wave_textures(
					_wave_generator.get_displacement_texture(),
					_wave_generator.get_normal_texture(),
					_wave_parameters.size()
				)
			else:
				# GPU init failed
				_use_compute = false
				push_warning("[OceanManager] GPU compute init failed, using vertex Gerstner")
		else:
			# Compute failed to init - fall back to Gerstner
			_use_compute = false
			push_warning("[OceanManager] GPU compute failed, using vertex Gerstner")

	_update_shader_parameters()

	# Load or generate shore mask
	var shore_mask_loaded := false

	# Try prebaked shore mask first
	var shore_mask_path := _get_shore_mask_path()
	if use_prebaked_shore_mask and FileAccess.file_exists(shore_mask_path):
		var prebaked := ShoreMaskBaker.load_prebaked(shore_mask_path)
		if not prebaked.is_empty():
			_ocean_mesh.set_shore_mask(prebaked.texture, prebaked.bounds)
			shore_mask_loaded = true
			print("[OceanManager] Using prebaked shore mask from %s" % shore_mask_path)

	# Fall back to runtime generation if terrain available
	if not shore_mask_loaded and _terrain:
		print("[OceanManager] Generating shore mask at runtime...")
		_shore_mask.generate_from_terrain(_terrain, shore_mask_resolution, shore_fade_distance, sea_level)
		# Pass shore mask to ocean mesh shader
		_ocean_mesh.set_shore_mask(
			_shore_mask.get_shore_mask_texture(),
			_shore_mask.get_world_bounds()
		)
		shore_mask_loaded = true

	if not shore_mask_loaded:
		print("[OceanManager] Warning: No shore mask available - ocean will appear everywhere")

	_system_initialized = true
	ocean_initialized.emit()

	var mode: String
	match actual_quality:
		HardwareDetection.WaterQuality.HIGH:
			mode = "GPU FFT (3 cascades)"
		HardwareDetection.WaterQuality.MEDIUM:
			mode = "Vertex Gerstner (high detail)"
		HardwareDetection.WaterQuality.LOW:
			mode = "Vertex Gerstner (low detail)"
		_:
			mode = "Flat Plane"
	print("[OceanManager] Initialized - sea level: %.1f, radius: %.0fm, quality: %s, mode: %s" % [
		sea_level, ocean_radius, HardwareDetection.quality_name(actual_quality), mode])
	print("[OceanManager] Ocean mesh visible: %s, vertices: %d" % [
		_ocean_mesh.visible,
		_ocean_mesh.mesh.get_faces().size() / 3 if _ocean_mesh.mesh else 0])


func _setup_wave_cascades(quality: HardwareDetection.WaterQuality) -> void:
	_wave_parameters.clear()
	_rng.seed = 1234  # Consistent seed for reproducible waves

	# Configure cascades based on quality level
	var cascade_configs: Array
	if quality == HardwareDetection.WaterQuality.HIGH:
		# HIGH: 3 cascades for full detail
		cascade_configs = [
			{ "tile_length": Vector2(250, 250), "displacement_scale": 1.0, "normal_scale": 1.0 },
			{ "tile_length": Vector2(67, 67), "displacement_scale": 0.5, "normal_scale": 0.5 },
			{ "tile_length": Vector2(17, 17), "displacement_scale": 0.25, "normal_scale": 0.25 }
		]
	else:
		# MEDIUM: 1 cascade for lighter GPU load
		cascade_configs = [
			{ "tile_length": Vector2(100, 100), "displacement_scale": 1.0, "normal_scale": 1.0 }
		]

	for i in range(cascade_configs.size()):
		var config: Dictionary = cascade_configs[i]
		var params := WaveCascadeParameters.new()
		params.tile_length = config["tile_length"]
		params.displacement_scale = config["displacement_scale"]
		params.normal_scale = config["normal_scale"]
		params.wind_speed = wind_speed
		params.wind_direction = wind_direction
		params.fetch_length = 550.0
		params.swell = 0.8
		params.spread = 0.2
		params.detail = 1.0
		params.whitecap = 0.5
		params.foam_amount = 5.0
		params.spectrum_seed = Vector2i(_rng.randi_range(-10000, 10000), _rng.randi_range(-10000, 10000))
		params.time = 120.0 + PI * i  # Offset to prevent interference
		_wave_parameters.append(params)

	print("[OceanManager] Configured %d wave cascade(s)" % cascade_configs.size())


func _process(delta: float) -> void:
	if not _system_enabled or not _enabled:
		return

	_time += delta

	# Auto-find camera if not set
	if not _camera and _auto_find_camera:
		_camera = _find_active_camera()
		if _camera:
			print("[OceanManager] Auto-detected camera: %s at %s" % [_camera.name, _camera.global_position])

	# Update wave generator
	if _use_compute and _wave_parameters.size() > 0:
		# GPU compute mode - use cascade-based update
		_wave_update_timer += delta
		var update_interval := 1.0 / float(wave_update_rate)
		if _wave_update_timer >= update_interval:
			_wave_update_timer -= update_interval
			_wave_generator.update(update_interval, _wave_parameters)
			wave_updated.emit()
	# For flat plane mode, nothing to update

	# Update ocean mesh position to follow camera
	if _camera:
		var cam_pos := _camera.global_position
		var new_pos := Vector3(cam_pos.x, sea_level, cam_pos.z)
		_ocean_mesh.update_position(new_pos)
		# Debug: print position once
		if _time < 0.1:
			print("[OceanManager] Ocean mesh positioned at: %s (camera: %s)" % [new_pos, cam_pos])

	# Update shader time (for vertex Gerstner animation)
	_ocean_mesh.set_shader_time(_time)


func _find_active_camera() -> Camera3D:
	# Try to find the current camera from viewport
	var viewport := get_viewport()
	if viewport:
		var cam := viewport.get_camera_3d()
		if cam:
			return cam

	# Fallback: search scene tree for any Camera3D
	var cameras := get_tree().get_nodes_in_group("camera")
	if cameras.size() > 0 and cameras[0] is Camera3D:
		return cameras[0] as Camera3D

	# Last resort: find by class
	return _find_node_by_class(get_tree().root, "Camera3D") as Camera3D


func _find_terrain() -> void:
	# Look for Terrain3D in the scene tree
	var terrains := get_tree().get_nodes_in_group("terrain")
	if terrains.size() > 0 and terrains[0] is Terrain3D:
		_terrain = terrains[0] as Terrain3D
		return

	# Fallback: search by class
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

	_ocean_mesh.set_water_color(water_color)
	_ocean_mesh.set_foam_color(foam_color)
	_ocean_mesh.set_depth_absorption(depth_color_absorption)
	_ocean_mesh.set_wave_scale(wave_scale)


## Get the wave height at a world position (for buoyancy)
## Returns height in world Y coordinate
func get_wave_height(world_pos: Vector3) -> float:
	if not _system_enabled or not _enabled or not _wave_generator:
		return sea_level

	# Check shore mask - if we're on land, return terrain height
	if _shore_mask and _terrain:
		var shore_factor := _shore_mask.get_shore_factor(world_pos)
		if shore_factor <= 0.01:
			# We're on land, no ocean here
			return sea_level - 1000.0  # Return very low value to indicate no water

	# Sample wave displacement
	var displacement := _wave_generator.sample_displacement(world_pos)
	return sea_level + displacement.y * wave_scale


## Get wave displacement vector at world position (includes XZ horizontal displacement)
func get_wave_displacement(world_pos: Vector3) -> Vector3:
	if not _system_enabled or not _enabled or not _wave_generator:
		return Vector3.ZERO

	return _wave_generator.sample_displacement(world_pos) * wave_scale


## Get wave normal at world position
func get_wave_normal(world_pos: Vector3) -> Vector3:
	if not _system_enabled or not _enabled or not _wave_generator:
		return Vector3.UP

	return _wave_generator.sample_normal(world_pos)


## Check if a position is in ocean water
func is_in_ocean(world_pos: Vector3) -> bool:
	if not _system_enabled or not _enabled:
		return false

	# Check if below sea level
	if world_pos.y > sea_level + 10.0:  # 10m buffer
		return false

	# Check shore mask
	if _shore_mask:
		return _shore_mask.get_shore_factor(world_pos) > 0.01

	# Fallback: check terrain height
	if _terrain and _terrain.data:
		var terrain_height: float = _terrain.data.get_height(world_pos)
		return terrain_height < sea_level

	return true


## Set the camera to follow (ocean mesh centers on camera)
func set_camera(camera: Camera3D) -> void:
	_camera = camera
	_auto_find_camera = false  # Disable auto-find once manually set


## Set the sea level (call before initialization or regenerate shore mask after)
func set_sea_level(level: float) -> void:
	sea_level = level
	if not _system_enabled:
		return
	# Regenerate shore mask with new sea level if terrain available
	if _terrain and _shore_mask:
		_shore_mask.generate_from_terrain(_terrain, shore_mask_resolution, shore_fade_distance, sea_level)


## Get current sea level
func get_sea_level() -> float:
	return sea_level


## Set the terrain for shore mask generation
## Prefers prebaked shore mask if available, falls back to runtime generation
func set_terrain(terrain: Terrain3D) -> void:
	_terrain = terrain
	if not _system_enabled:
		return

	# Try to use prebaked shore mask first (same logic as _deferred_init)
	var shore_mask_loaded := false
	var shore_mask_path := _get_shore_mask_path()
	if use_prebaked_shore_mask and FileAccess.file_exists(shore_mask_path):
		var prebaked := ShoreMaskBaker.load_prebaked(shore_mask_path)
		if not prebaked.is_empty():
			if _ocean_mesh:
				_ocean_mesh.set_shore_mask(prebaked.texture, prebaked.bounds)
			shore_mask_loaded = true
			print("[OceanManager] Using prebaked shore mask from %s" % shore_mask_path)

	# Fall back to runtime generation if no prebaked mask
	if not shore_mask_loaded and _shore_mask and _terrain:
		print("[OceanManager] No prebaked shore mask, generating at runtime...")
		_shore_mask.generate_from_terrain(_terrain, shore_mask_resolution, shore_fade_distance, sea_level)
		if _ocean_mesh:
			_ocean_mesh.set_shore_mask(
				_shore_mask.get_shore_mask_texture(),
				_shore_mask.get_world_bounds()
			)


## Regenerate shore mask (call after terrain changes)
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


## Enable/disable ocean rendering
func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	if _ocean_mesh:
		_ocean_mesh.visible = enabled


## Get current time (for debugging)
func get_time() -> float:
	return _time


## Get wave generator (for advanced configuration)
func get_wave_generator() -> WaveGenerator:
	return _wave_generator


## Get ocean mesh node
func get_ocean_mesh() -> OceanMesh:
	return _ocean_mesh


## Get shore mask generator
func get_shore_mask_generator() -> ShoreMaskGenerator:
	return _shore_mask


## Check if system is enabled via project settings
func is_system_enabled() -> bool:
	return _system_enabled


## Check if system is fully initialized
func is_initialized() -> bool:
	return _system_initialized


## Toggle ocean on/off at runtime (for settings menus)
## Returns the new enabled state
func toggle_ocean() -> bool:
	if _system_enabled and _system_initialized:
		# Disable
		set_enabled(false)
		_system_enabled = false
		print("[OceanManager] Ocean disabled")
	else:
		# Enable - may need to initialize first
		if not _system_initialized:
			force_initialize()
		# force_initialize sets _system_enabled = true
		set_enabled(true)
		var mode: String
		match get_water_quality():
			HardwareDetection.WaterQuality.HIGH:
				mode = "GPU FFT"
			HardwareDetection.WaterQuality.MEDIUM, HardwareDetection.WaterQuality.LOW:
				mode = "Vertex Gerstner"
			_:
				mode = "Flat Plane"
		print("[OceanManager] Ocean enabled (mode: %s, quality: %s)" % [mode, get_water_quality_name()])
	return _system_enabled


## Static helper to check if ocean should be enabled for current hardware
## Call this before enabling ocean on low-end systems
static func is_hardware_suitable() -> bool:
	HardwareDetection.detect()
	var quality := HardwareDetection.get_recommended_quality()
	# Only suitable if hardware can handle at least LOW quality without severe impact
	# ULTRA_LOW means software renderer - definitely not suitable
	return quality != HardwareDetection.WaterQuality.ULTRA_LOW


## Force-enable and initialize the ocean system
## Call this from scenes that need ocean but have ocean/enabled = false in project settings
## This allows the autoload to stay disabled by default while scenes can opt-in
func force_initialize() -> void:
	if _system_initialized:
		print("[OceanManager] Already initialized, skipping force_initialize")
		return

	print("[OceanManager] Force initializing ocean system...")
	_system_enabled = true

	# Create child systems if not already created
	if not _ocean_mesh:
		_ocean_mesh = OceanMesh.new()
		_ocean_mesh.name = "OceanMesh"
		add_child(_ocean_mesh)
		print("[OceanManager] Created OceanMesh")

	if not _wave_generator:
		_wave_generator = WaveGenerator.new()
		_wave_generator.name = "WaveGenerator"
		add_child(_wave_generator)
		print("[OceanManager] Created WaveGenerator")

	if not _shore_mask:
		_shore_mask = ShoreMaskGenerator.new()
		_shore_mask.name = "ShoreMaskGenerator"
		add_child(_shore_mask)
		print("[OceanManager] Created ShoreMaskGenerator")

	# Run deferred init
	_deferred_init()

	# Ensure mesh is visible and positioned
	if _ocean_mesh:
		_ocean_mesh.visible = true
		print("[OceanManager] Ocean mesh visible: %s, position: %s" % [_ocean_mesh.visible, _ocean_mesh.global_position])


## Get current water quality level
func get_water_quality() -> HardwareDetection.WaterQuality:
	if _ocean_mesh:
		return _ocean_mesh.get_quality()
	return HardwareDetection.get_recommended_quality()


## Set water quality level (-1 = auto, 0-3 = specific level)
func set_water_quality(quality: int) -> void:
	water_quality = quality
	if not _system_enabled:
		return
	if not _ocean_mesh:
		return

	var needs_wave_textures := _ocean_mesh.set_quality(quality as HardwareDetection.WaterQuality, ocean_radius)
	var actual_quality := _ocean_mesh.get_quality()

	# Update compute mode flag
	_use_compute = actual_quality == HardwareDetection.WaterQuality.HIGH

	# If switching to HIGH quality, need to reconnect wave textures
	if needs_wave_textures and _wave_generator and _wave_generator.is_initialized():
		_ocean_mesh.set_wave_textures(
			_wave_generator.get_displacement_texture(),
			_wave_generator.get_normal_texture(),
			_wave_parameters.size()
		)
		print("[OceanManager] Reconnected wave textures for HIGH quality")
	elif needs_wave_textures:
		# Need to initialize wave generator for HIGH quality
		if not _wave_generator.is_initialized():
			_setup_wave_cascades(actual_quality)
			_wave_generator.initialize(256)
			if _wave_generator.is_using_compute():
				_wave_generator.init_gpu(maxi(2, _wave_parameters.size()))
				if _wave_generator.is_initialized():
					_ocean_mesh.set_wave_textures(
						_wave_generator.get_displacement_texture(),
						_wave_generator.get_normal_texture(),
						_wave_parameters.size()
					)
					print("[OceanManager] Initialized wave generator for HIGH quality switch")

	print("[OceanManager] Quality changed to: %s (use_compute: %s)" % [
		HardwareDetection.quality_name(actual_quality), _use_compute])


## Get water quality name as string
func get_water_quality_name() -> String:
	return HardwareDetection.quality_name(get_water_quality())


## Check if running on integrated GPU
func is_integrated_gpu() -> bool:
	return HardwareDetection.is_integrated_gpu()


## Get GPU name
func get_gpu_name() -> String:
	return HardwareDetection.get_gpu_name()
