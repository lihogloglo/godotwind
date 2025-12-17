## OceanManager - Main coordinator for the ocean water system
## Manages ocean mesh, wave generation, shore dampening, and buoyancy queries
## Autoload singleton: accessible via OceanManager global
class_name OceanManagerClass
extends Node

# Ocean configuration
@export var ocean_radius: float = 8000.0  # 8km clipmap radius
@export var wave_update_rate: int = 30    # Wave updates per second
@export var shore_fade_distance: float = 50.0  # Meters to fade waves near shore
@export var shore_mask_resolution: int = 2048  # Shore mask texture size

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
@export var water_color: Color = Color(0.02, 0.08, 0.15, 1.0)
@export var foam_color: Color = Color(0.9, 0.9, 0.9, 1.0)
@export var depth_color_absorption: Vector3 = Vector3(7.5, 22.0, 38.0)

# Internal state
var _ocean_mesh: OceanMesh = null
var _wave_generator: WaveGenerator = null
var _shore_mask: ShoreMaskGenerator = null
var _terrain: Terrain3D = null
var _camera: Camera3D = null
var _enabled: bool = true
var _time: float = 0.0
var _wave_update_timer: float = 0.0
var _auto_find_camera: bool = true  # Auto-detect camera if not set

# Displacement texture for CPU sampling (for buoyancy)
var _displacement_image: Image = null
var _displacement_map_size: int = 256

# Signals
signal ocean_initialized()
signal wave_updated()


func _ready() -> void:
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


func _deferred_init() -> void:
	# Run hardware detection first
	HardwareDetection.detect()

	# Try to find terrain in scene
	_find_terrain()

	# Initialize wave generator
	_wave_generator.initialize(_displacement_map_size)
	_wave_generator.set_wind(wind_speed, wind_direction)

	# Initialize ocean mesh with quality setting
	_ocean_mesh.initialize(ocean_radius, water_quality)
	_update_shader_parameters()

	# Generate initial shore mask if terrain available
	if _terrain:
		_shore_mask.generate_from_terrain(_terrain, shore_mask_resolution, shore_fade_distance, sea_level)

	var quality_name := HardwareDetection.quality_name(_ocean_mesh.get_quality())
	ocean_initialized.emit()
	print("[OceanManager] Initialized - sea level: %.1f, radius: %.0fm, quality: %s" % [sea_level, ocean_radius, quality_name])


func _process(delta: float) -> void:
	if not _enabled:
		return

	_time += delta

	# Auto-find camera if not set
	if not _camera and _auto_find_camera:
		_camera = _find_active_camera()
		if _camera:
			print("[OceanManager] Auto-detected camera: %s" % _camera.name)

	# Update wave generator at configured rate
	_wave_update_timer += delta
	var update_interval := 1.0 / float(wave_update_rate)
	if _wave_update_timer >= update_interval:
		_wave_update_timer -= update_interval
		_wave_generator.update(_time)
		wave_updated.emit()

	# Update ocean mesh position to follow camera
	if _camera:
		var cam_pos := _camera.global_position
		_ocean_mesh.update_position(Vector3(cam_pos.x, sea_level, cam_pos.z))

	# Update shader time
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


## Get the wave height at a world position (for buoyancy)
## Returns height in world Y coordinate
func get_wave_height(world_pos: Vector3) -> float:
	if not _enabled or not _wave_generator:
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
	if not _enabled or not _wave_generator:
		return Vector3.ZERO

	return _wave_generator.sample_displacement(world_pos) * wave_scale


## Get wave normal at world position
func get_wave_normal(world_pos: Vector3) -> Vector3:
	if not _enabled or not _wave_generator:
		return Vector3.UP

	return _wave_generator.sample_normal(world_pos)


## Check if a position is in ocean water
func is_in_ocean(world_pos: Vector3) -> bool:
	if not _enabled:
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
	# Regenerate shore mask with new sea level if terrain available
	if _terrain and _shore_mask:
		_shore_mask.generate_from_terrain(_terrain, shore_mask_resolution, shore_fade_distance, sea_level)


## Get current sea level
func get_sea_level() -> float:
	return sea_level


## Set the terrain for shore mask generation
func set_terrain(terrain: Terrain3D) -> void:
	_terrain = terrain
	if _shore_mask and _terrain:
		_shore_mask.generate_from_terrain(_terrain, shore_mask_resolution, shore_fade_distance, sea_level)


## Regenerate shore mask (call after terrain changes)
func regenerate_shore_mask() -> void:
	if _shore_mask and _terrain:
		_shore_mask.generate_from_terrain(_terrain, shore_mask_resolution, shore_fade_distance, sea_level)


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


## Get current water quality level
func get_water_quality() -> HardwareDetection.WaterQuality:
	if _ocean_mesh:
		return _ocean_mesh.get_quality()
	return HardwareDetection.get_recommended_quality()


## Set water quality level (-1 = auto, 0-3 = specific level)
func set_water_quality(quality: int) -> void:
	water_quality = quality
	if _ocean_mesh:
		_ocean_mesh.set_quality(quality as HardwareDetection.WaterQuality, ocean_radius)
		print("[OceanManager] Quality changed to: %s" % HardwareDetection.quality_name(_ocean_mesh.get_quality()))


## Get water quality name as string
func get_water_quality_name() -> String:
	return HardwareDetection.quality_name(get_water_quality())


## Check if running on integrated GPU
func is_integrated_gpu() -> bool:
	return HardwareDetection.is_integrated_gpu()


## Get GPU name
func get_gpu_name() -> String:
	return HardwareDetection.get_gpu_name()
