# DeformationManager.gd
# Autoload singleton that manages the RTT deformation system
# Coordinates rendering, streaming, and integration with Terrain3D
# OPTIONAL SYSTEM - Can be completely disabled via project settings
extends Node

# Material type constants
enum MaterialType {
	SNOW = 0,
	MUD = 1,
	ASH = 2,
	SAND = 3,
	ROCK = 4  # No deformation
}

# Configuration constants
const REGION_SIZE_METERS: float = 256.0 * 1.83  # ~469m (matches Terrain3D)

# Dynamic configuration (loaded from DeformationConfig)
var DEFORMATION_TEXTURE_SIZE: int = 1024
var TEXELS_PER_METER: float = 1024.0 / REGION_SIZE_METERS
var MAX_ACTIVE_REGIONS: int = 9
var DEFORMATION_UPDATE_BUDGET_MS: float = 2.0
var DEFORMATION_UNLOAD_DISTANCE: int = 5

# System state
var _system_initialized: bool = false
var _system_enabled: bool = false

# Core components (only created if system is enabled)
var _renderer: Node = null
var _streamer: Node = null
var _compositor: Node = null
var _terrain_integration: Node = null

# Active deformation regions
var _active_regions: Dictionary = {}  # Vector2i -> RegionData

# Pending deformations queue
var _pending_deformations: Array = []

# Settings (loaded from config)
var deformation_enabled: bool = false
var recovery_enabled: bool = false
var recovery_rate: float = 0.01
var deformation_depth_scale: float = 0.1

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
	# Register project settings if they don't exist
	DeformationConfig.register_project_settings()

	# Load configuration from project settings
	DeformationConfig.load_from_project_settings()

	# Check if system is enabled
	if not DeformationConfig.enabled:
		print("[DeformationManager] System disabled via project settings - skipping initialization")
		_system_enabled = false
		return

	print("[DeformationManager] Initializing RTT deformation system...")

	# Load configuration values
	_load_configuration()

	# Initialize system
	if not _initialize_system():
		push_error("[DeformationManager] Failed to initialize system")
		_system_enabled = false
		return

	_system_enabled = true
	_system_initialized = true
	print("[DeformationManager] System initialized successfully")

# Load configuration from DeformationConfig
func _load_configuration():
	DEFORMATION_TEXTURE_SIZE = DeformationConfig.texture_size
	TEXELS_PER_METER = float(DEFORMATION_TEXTURE_SIZE) / REGION_SIZE_METERS
	MAX_ACTIVE_REGIONS = DeformationConfig.max_active_regions
	DEFORMATION_UPDATE_BUDGET_MS = DeformationConfig.update_budget_ms

	deformation_enabled = DeformationConfig.enabled
	recovery_enabled = DeformationConfig.enable_recovery
	recovery_rate = DeformationConfig.recovery_rate

	# Validate configuration
	if not DeformationConfig.validate():
		push_warning("[DeformationManager] Configuration validation failed, using defaults")

# Initialize system components
func _initialize_system() -> bool:
	# Create child components with error handling
	if not _create_renderer():
		return false

	if DeformationConfig.enable_streaming:
		if not _create_streamer():
			push_warning("[DeformationManager] Streamer initialization failed, continuing without streaming")

	if DeformationConfig.enable_recovery:
		if not _create_compositor():
			push_warning("[DeformationManager] Compositor initialization failed, continuing without recovery")

	if DeformationConfig.enable_terrain_integration:
		if not _create_terrain_integration():
			push_warning("[DeformationManager] Terrain integration failed, deformations won't be visible")

	return true

func _create_renderer() -> bool:
	var renderer_script = load("res://src/core/deformation/deformation_renderer.gd")
	if renderer_script == null:
		push_error("[DeformationManager] Failed to load renderer script")
		return false

	_renderer = renderer_script.new()
	add_child(_renderer)
	return true

func _create_streamer() -> bool:
	var streamer_script = load("res://src/core/deformation/deformation_streamer.gd")
	if streamer_script == null:
		push_error("[DeformationManager] Failed to load streamer script")
		return false

	_streamer = streamer_script.new()
	add_child(_streamer)

	# Connect signals
	_streamer.connect("region_load_requested", _on_region_load_requested)
	_streamer.connect("region_unload_requested", _on_region_unload_requested)
	return true

func _create_compositor() -> bool:
	var compositor_script = load("res://src/core/deformation/deformation_compositor.gd")
	if compositor_script == null:
		push_error("[DeformationManager] Failed to load compositor script")
		return false

	_compositor = compositor_script.new()
	add_child(_compositor)
	return true

func _create_terrain_integration() -> bool:
	var integration_script = load("res://src/core/deformation/terrain_deformation_integration.gd")
	if integration_script == null:
		push_error("[DeformationManager] Failed to load terrain integration script")
		return false

	_terrain_integration = integration_script.new()
	add_child(_terrain_integration)
	return true

func _process(delta: float):
	if not _system_enabled or not deformation_enabled:
		return

	# Process pending deformations with time budget
	_process_pending_deformations()

	# Update recovery system
	if recovery_enabled and _compositor != null:
		_compositor.process_recovery(delta, _active_regions)

# Main API: Add deformation at world position
func add_deformation(world_pos: Vector3, material_type: int, strength: float):
	# Safety checks
	if not _system_enabled:
		return
	if not deformation_enabled:
		return
	if _renderer == null:
		push_warning("[DeformationManager] Cannot add deformation: renderer not initialized")
		return

	_pending_deformations.append({
		"position": world_pos,
		"material_type": material_type,
		"strength": strength,
		"timestamp": Time.get_ticks_msec()
	})

# Main API: Set player node for camera following (only used in player-following mode)
func set_player(player: Node3D) -> void:
	if _renderer != null:
		_renderer.set_player(player)
	else:
		push_warning("[DeformationManager] Cannot set player: renderer not initialized")

# Process pending deformations with time budget
# Groups stamps by region for batch processing
func _process_pending_deformations():
	if _pending_deformations.is_empty():
		return

	var start_time = Time.get_ticks_usec()
	var budget_us = DEFORMATION_UPDATE_BUDGET_MS * 1000.0

	# Group pending deformations by region for batch processing
	var stamps_by_region: Dictionary = {}  # Vector2i -> Array[Dictionary]

	# Collect stamps within budget
	var stamps_to_process: Array = []
	while not _pending_deformations.is_empty():
		var elapsed = Time.get_ticks_usec() - start_time
		if elapsed > budget_us * 0.5:  # Use half budget for collection
			break  # Save remaining budget for actual rendering

		var deform = _pending_deformations.pop_front()
		stamps_to_process.append(deform)

	# Group stamps by region
	for deform in stamps_to_process:
		var world_pos: Vector3 = deform["position"]
		var region_coord = world_to_region_coord(world_pos)

		if not stamps_by_region.has(region_coord):
			stamps_by_region[region_coord] = []
		stamps_by_region[region_coord].append(deform)

	# Process each region's stamps (potentially in batch)
	for region_coord in stamps_by_region.keys():
		var elapsed = Time.get_ticks_usec() - start_time
		if elapsed > budget_us:
			# Out of budget, re-queue remaining stamps
			for remaining_deform in stamps_by_region[region_coord]:
				_pending_deformations.push_front(remaining_deform)
			break

		var region_stamps = stamps_by_region[region_coord]

		# Apply all stamps for this region
		for deform in region_stamps:
			_apply_deformation_stamp(deform)

# Apply a single deformation stamp
func _apply_deformation_stamp(deform: Dictionary):
	if _renderer == null:
		return

	var world_pos: Vector3 = deform["position"]
	var material_type: int = deform["material_type"]
	var strength: float = deform["strength"]

	# Convert world position to region coordinate
	var region_coord = world_to_region_coord(world_pos)

	# Check if region is loaded
	if not _active_regions.has(region_coord):
		# Region not loaded, skip deformation silently
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
		strength,
		world_pos  # Pass world position for player-following mode
	)

	region_data.dirty = true
	region_data.last_update_time = Time.get_ticks_msec() / 1000.0

	# Update terrain integration if available
	if _terrain_integration != null:
		_terrain_integration.update_region_texture(region_coord, region_data.texture)

# Region management
func load_deformation_region(region_coord: Vector2i):
	# Safety checks
	if not _system_enabled:
		return
	if _active_regions.has(region_coord):
		return  # Already loaded

	# Check region limit
	if _active_regions.size() >= MAX_ACTIVE_REGIONS:
		push_warning("[DeformationManager] Max active regions reached, cannot load region: ", region_coord)
		return

	# Create new region or load from disk
	var region_data = RegionData.new(region_coord)

	# Try to load saved deformation from disk (if persistence enabled)
	if DeformationConfig.enable_persistence:
		var save_path = _get_deformation_save_path(region_coord)
		if FileAccess.file_exists(save_path):
			_load_region_from_disk(region_data, save_path)

	_active_regions[region_coord] = region_data

	# Update terrain integration
	if _terrain_integration != null:
		_terrain_integration.update_region_texture(region_coord, region_data.texture)

	if DeformationConfig.debug_mode:
		print("[DeformationManager] Loaded deformation region: ", region_coord)

func unload_deformation_region(region_coord: Vector2i):
	# Safety checks
	if not _system_enabled:
		return
	if not _active_regions.has(region_coord):
		return  # Not loaded

	var region_data: RegionData = _active_regions[region_coord]

	# Save if dirty and persistence enabled
	if region_data.dirty and DeformationConfig.enable_persistence and DeformationConfig.auto_save_on_unload:
		var save_path = _get_deformation_save_path(region_coord)
		_save_region_to_disk(region_data, save_path)

	# Remove from terrain integration
	if _terrain_integration != null:
		_terrain_integration.remove_region_texture(region_coord)

	_active_regions.erase(region_coord)

	if DeformationConfig.debug_mode:
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
	if not _system_enabled:
		push_warning("[DeformationManager] Cannot change settings: system not enabled")
		return
	recovery_enabled = enabled
	DeformationConfig.enable_recovery = enabled

func set_recovery_rate(rate: float):
	if not _system_enabled:
		push_warning("[DeformationManager] Cannot change settings: system not enabled")
		return
	recovery_rate = rate
	DeformationConfig.recovery_rate = rate

func set_deformation_enabled(enabled: bool):
	if not _system_enabled:
		push_warning("[DeformationManager] Cannot change settings: system not enabled")
		return
	deformation_enabled = enabled
	DeformationConfig.enabled = enabled

# Check if system is enabled
func is_system_enabled() -> bool:
	return _system_enabled

func is_initialized() -> bool:
	return _system_initialized

# Cleanup
func cleanup_distant_regions(camera_position: Vector3):
	if not _system_enabled:
		return

	var camera_region = world_to_region_coord(camera_position)

	var regions_to_remove = []
	for region_coord in _active_regions.keys():
		var distance = region_coord.distance_to(camera_region)
		if distance > DEFORMATION_UNLOAD_DISTANCE:
			regions_to_remove.append(region_coord)

	for region_coord in regions_to_remove:
		unload_deformation_region(region_coord)

# Shutdown system (for cleanup on exit)
func shutdown():
	if not _system_enabled:
		return

	print("[DeformationManager] Shutting down deformation system...")

	# Save all dirty regions if persistence enabled
	if DeformationConfig.enable_persistence and DeformationConfig.auto_save_on_unload:
		for region_coord in _active_regions.keys():
			var region_data = _active_regions[region_coord]
			if region_data.dirty:
				var save_path = _get_deformation_save_path(region_coord)
				_save_region_to_disk(region_data, save_path)

	# Clear all regions
	_active_regions.clear()
	_pending_deformations.clear()

	_system_enabled = false
	print("[DeformationManager] System shutdown complete")

func _exit_tree():
	shutdown()
