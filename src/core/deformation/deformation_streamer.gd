# DeformationStreamer.gd
# Manages streaming of deformation regions in sync with terrain streaming
# Handles load/unload queue and coordinates with GenericTerrainStreamer
extends Node

# Signals
signal region_load_requested(region_coord: Vector2i)
signal region_unload_requested(region_coord: Vector2i)

# Load/unload queues
var _load_queue: Array[Vector2i] = []
var _unload_queue: Array[Vector2i] = []

# Tracked regions
var _tracked_regions: Dictionary = {}  # Vector2i -> bool (loaded state)

# Camera tracking
var _camera_position: Vector3 = Vector3.ZERO
var _last_camera_region: Vector2i = Vector2i.ZERO

func _ready():
	print("[DeformationStreamer] Streamer initialized")

	# Try to connect to existing terrain streaming system
	_connect_to_terrain_streamer()

func _process(_delta: float):
	# Process load/unload queues
	_process_load_queue()
	_process_unload_queue()

# Connect to GenericTerrainStreamer events if available
func _connect_to_terrain_streamer():
	# Wait for tree to be ready
	await get_tree().process_frame

	# Try to find WorldStreamingManager
	var world_streaming_manager = get_node_or_null("/root/WorldStreamingManager")
	if world_streaming_manager == null:
		print("[DeformationStreamer] Warning: WorldStreamingManager not found, manual region management required")
		return

	# Try to find GenericTerrainStreamer
	var terrain_streamer = world_streaming_manager.get_node_or_null("GenericTerrainStreamer")
	if terrain_streamer == null:
		print("[DeformationStreamer] Warning: GenericTerrainStreamer not found")
		return

	# Connect to terrain streaming signals if they exist
	if terrain_streamer.has_signal("region_loaded"):
		terrain_streamer.connect("region_loaded", _on_terrain_region_loaded)
		print("[DeformationStreamer] Connected to terrain region_loaded signal")

	if terrain_streamer.has_signal("region_unloaded"):
		terrain_streamer.connect("region_unloaded", _on_terrain_region_unloaded)
		print("[DeformationStreamer] Connected to terrain region_unloaded signal")

# Terrain region loaded callback
func _on_terrain_region_loaded(region_coord: Vector2i):
	print("[DeformationStreamer] Terrain region loaded: ", region_coord)
	request_load_region(region_coord)

# Terrain region unloaded callback
func _on_terrain_region_unloaded(region_coord: Vector2i):
	print("[DeformationStreamer] Terrain region unloaded: ", region_coord)
	request_unload_region(region_coord)

# Request deformation region load
func request_load_region(region_coord: Vector2i):
	if _tracked_regions.has(region_coord) and _tracked_regions[region_coord]:
		return  # Already loaded

	if not _load_queue.has(region_coord):
		_load_queue.append(region_coord)

# Request deformation region unload
func request_unload_region(region_coord: Vector2i):
	if not _tracked_regions.has(region_coord):
		return  # Not tracked

	if not _unload_queue.has(region_coord):
		_unload_queue.append(region_coord)

# Process load queue (one region per frame for now)
func _process_load_queue():
	if _load_queue.is_empty():
		return

	# Load one region per frame
	var region_coord = _load_queue.pop_front()

	# Emit load request signal
	region_load_requested.emit(region_coord)

	# Mark as loaded
	_tracked_regions[region_coord] = true

# Process unload queue (one region per frame for now)
func _process_unload_queue():
	if _unload_queue.is_empty():
		return

	# Unload one region per frame
	var region_coord = _unload_queue.pop_front()

	# Emit unload request signal
	region_unload_requested.emit(region_coord)

	# Remove from tracked regions
	_tracked_regions.erase(region_coord)

# Update camera position and check for region changes
func update_camera_position(camera_pos: Vector3):
	_camera_position = camera_pos

	var current_region = DeformationManager.world_to_region_coord(camera_pos)

	if current_region != _last_camera_region:
		_on_camera_region_changed(current_region)
		_last_camera_region = current_region

# Camera region changed - load nearby regions, unload distant ones
func _on_camera_region_changed(camera_region: Vector2i):
	# Load 3x3 grid around camera
	for x in range(-1, 2):
		for y in range(-1, 2):
			var region_coord = camera_region + Vector2i(x, y)
			request_load_region(region_coord)

	# Unload distant regions
	var regions_to_unload = []
	for region_coord in _tracked_regions.keys():
		var distance = region_coord.distance_to(camera_region)
		if distance > DeformationManager.DEFORMATION_UNLOAD_DISTANCE:
			regions_to_unload.append(region_coord)

	for region_coord in regions_to_unload:
		request_unload_region(region_coord)

# Manual region management (for testing without terrain streamer)
func load_regions_around_position(world_pos: Vector3, radius: int = 1):
	var center_region = DeformationManager.world_to_region_coord(world_pos)

	for x in range(-radius, radius + 1):
		for y in range(-radius, radius + 1):
			var region_coord = center_region + Vector2i(x, y)
			request_load_region(region_coord)

func unload_all_regions():
	for region_coord in _tracked_regions.keys():
		request_unload_region(region_coord)
