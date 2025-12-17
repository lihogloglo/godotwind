# DeformationManager.gd
# Autoload singleton that manages the RTT deformation system
# Coordinates rendering, streaming, and integration with Terrain3D
extends Node

# Material type constants
enum MaterialType {
	SNOW = 0,
	MUD = 1,
	ASH = 2,
	SAND = 3
}

# Configuration constants
const REGION_SIZE_METERS: float = 256.0 * 1.83  # ~469m (matches Terrain3D)
const DEFORMATION_TEXTURE_SIZE: int = 1024
const TEXELS_PER_METER: float = DEFORMATION_TEXTURE_SIZE / REGION_SIZE_METERS
const MAX_ACTIVE_REGIONS: int = 9  # 3x3 grid around player
const DEFORMATION_UPDATE_BUDGET_MS: float = 2.0
const DEFORMATION_UNLOAD_DISTANCE: int = 5

# Core components
var _renderer: Node  # DeformationRenderer
var _streamer: Node  # DeformationStreamer
var _compositor: Node  # DeformationCompositor

# Active deformation regions
var _active_regions: Dictionary = {}  # Vector2i -> RegionData

# Pending deformations queue
var _pending_deformations: Array = []

# Settings
var deformation_enabled: bool = true
var recovery_enabled: bool = false
var recovery_rate: float = 0.01  # Units per second
var deformation_depth_scale: float = 0.1  # Max 10cm deformation

# Region data structure
class RegionData:
	var texture: ImageTexture
	var image: Image
	var dirty: bool = false
	var last_update_time: float = 0.0
	var region_coord: Vector2i

	func _init(coord: Vector2i):
		region_coord = coord
		# Create RG16F texture (Red=depth, Green=material type)
		image = Image.create(
			DeformationManager.DEFORMATION_TEXTURE_SIZE,
			DeformationManager.DEFORMATION_TEXTURE_SIZE,
			false,
			Image.FORMAT_RGF
		)
		image.fill(Color(0.0, 0.0, 0.0, 0.0))
		texture = ImageTexture.create_from_image(image)

func _ready():
	print("[DeformationManager] Initializing RTT deformation system...")

	# Create child components
	_renderer = preload("res://src/core/deformation/deformation_renderer.gd").new()
	add_child(_renderer)

	_streamer = preload("res://src/core/deformation/deformation_streamer.gd").new()
	add_child(_streamer)

	_compositor = preload("res://src/core/deformation/deformation_compositor.gd").new()
	add_child(_compositor)

	# Connect signals
	_streamer.connect("region_load_requested", _on_region_load_requested)
	_streamer.connect("region_unload_requested", _on_region_unload_requested)

	print("[DeformationManager] System initialized successfully")

func _process(delta: float):
	if not deformation_enabled:
		return

	# Process pending deformations with time budget
	_process_pending_deformations()

	# Update recovery system
	if recovery_enabled:
		_compositor.process_recovery(delta, _active_regions)

# Main API: Add deformation at world position
func add_deformation(world_pos: Vector3, material_type: int, strength: float):
	if not deformation_enabled:
		return

	_pending_deformations.append({
		"position": world_pos,
		"material_type": material_type,
		"strength": strength,
		"timestamp": Time.get_ticks_msec()
	})

# Process pending deformations with time budget
func _process_pending_deformations():
	if _pending_deformations.is_empty():
		return

	var start_time = Time.get_ticks_usec()
	var budget_us = DEFORMATION_UPDATE_BUDGET_MS * 1000.0

	while not _pending_deformations.is_empty():
		var elapsed = Time.get_ticks_usec() - start_time
		if elapsed > budget_us:
			break  # Defer to next frame

		var deform = _pending_deformations.pop_front()
		_apply_deformation_stamp(deform)

# Apply a single deformation stamp
func _apply_deformation_stamp(deform: Dictionary):
	var world_pos: Vector3 = deform["position"]
	var material_type: int = deform["material_type"]
	var strength: float = deform["strength"]

	# Convert world position to region coordinate
	var region_coord = world_to_region_coord(world_pos)

	# Check if region is loaded
	if not _active_regions.has(region_coord):
		# Region not loaded, skip deformation
		return

	# Get region-local UV
	var region_uv = world_to_region_uv(world_pos, region_coord)

	# Get region data
	var region_data: RegionData = _active_regions[region_coord]

	# Render stamp using renderer
	_renderer.render_stamp(
		region_data,
		region_uv,
		material_type,
		strength
	)

	region_data.dirty = true
	region_data.last_update_time = Time.get_ticks_msec() / 1000.0

# Region management
func load_deformation_region(region_coord: Vector2i):
	if _active_regions.has(region_coord):
		return  # Already loaded

	# Create new region or load from disk
	var region_data = RegionData.new(region_coord)

	# Try to load saved deformation from disk
	var save_path = _get_deformation_save_path(region_coord)
	if FileAccess.file_exists(save_path):
		_load_region_from_disk(region_data, save_path)

	_active_regions[region_coord] = region_data

	print("[DeformationManager] Loaded deformation region: ", region_coord)

func unload_deformation_region(region_coord: Vector2i):
	if not _active_regions.has(region_coord):
		return  # Not loaded

	var region_data: RegionData = _active_regions[region_coord]

	# Save if dirty
	if region_data.dirty:
		var save_path = _get_deformation_save_path(region_coord)
		_save_region_to_disk(region_data, save_path)

	_active_regions.erase(region_coord)

	print("[DeformationManager] Unloaded deformation region: ", region_coord)

# Get deformation texture for a region (for shader binding)
func get_region_texture(region_coord: Vector2i) -> ImageTexture:
	if _active_regions.has(region_coord):
		return _active_regions[region_coord].texture
	return null

# Coordinate conversion utilities
func world_to_region_coord(world_pos: Vector3) -> Vector2i:
	return Vector2i(
		floori(world_pos.x / REGION_SIZE_METERS),
		floori(world_pos.z / REGION_SIZE_METERS)
	)

func world_to_region_uv(world_pos: Vector3, region_coord: Vector2i) -> Vector2:
	var region_origin = Vector2(region_coord) * REGION_SIZE_METERS
	var local_pos = Vector2(world_pos.x, world_pos.z) - region_origin
	return local_pos / REGION_SIZE_METERS

# Persistence
func _get_deformation_save_path(region_coord: Vector2i) -> String:
	return "user://deformation_regions/region_%d_%d.exr" % [region_coord.x, region_coord.y]

func _save_region_to_disk(region_data: RegionData, path: String):
	# Ensure directory exists
	var dir_path = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	# Save as EXR (lossless 16-bit float)
	var err = region_data.image.save_exr(path)
	if err != OK:
		push_error("[DeformationManager] Failed to save region to: " + path)
	else:
		print("[DeformationManager] Saved deformation region to: ", path)

func _load_region_from_disk(region_data: RegionData, path: String):
	var loaded_image = Image.load_from_file(path)
	if loaded_image == null:
		push_error("[DeformationManager] Failed to load region from: " + path)
		return

	region_data.image = loaded_image
	region_data.texture = ImageTexture.create_from_image(loaded_image)
	print("[DeformationManager] Loaded deformation region from: ", path)

# Signal handlers
func _on_region_load_requested(region_coord: Vector2i):
	load_deformation_region(region_coord)

func _on_region_unload_requested(region_coord: Vector2i):
	unload_deformation_region(region_coord)

# Settings API
func set_recovery_enabled(enabled: bool):
	recovery_enabled = enabled

func set_recovery_rate(rate: float):
	recovery_rate = rate

func set_deformation_enabled(enabled: bool):
	deformation_enabled = enabled

# Cleanup
func cleanup_distant_regions(camera_position: Vector3):
	var camera_region = world_to_region_coord(camera_position)

	var regions_to_remove = []
	for region_coord in _active_regions.keys():
		var distance = region_coord.distance_to(camera_region)
		if distance > DEFORMATION_UNLOAD_DISTANCE:
			regions_to_remove.append(region_coord)

	for region_coord in regions_to_remove:
		unload_deformation_region(region_coord)
