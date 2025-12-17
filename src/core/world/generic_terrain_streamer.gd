## GenericTerrainStreamer - Streams terrain from any WorldDataProvider into Terrain3D
##
## This component handles terrain streaming independent of the data source.
## It works with MorrowindDataProvider, LaPalmaDataProvider, or any other
## implementation of WorldDataProvider.
##
## CRITICAL: This version properly unloads distant regions to prevent memory leaks!
##
## Supports both synchronous and asynchronous terrain generation:
## - Sync mode (default): Generates terrain on main thread with time budgeting
## - Async mode: Uses BackgroundProcessor for parallel terrain generation
##
## Usage:
##   var streamer = GenericTerrainStreamer.new()
##   streamer.set_provider(my_provider)
##   streamer.set_terrain_3d(terrain_node)
##   streamer.set_tracked_node(camera)
##   streamer.set_background_processor(bg_processor)  # Optional: enables async
##   add_child(streamer)
class_name GenericTerrainStreamer
extends Node

const WorldDataProviderBase := preload("res://src/core/world/world_data_provider.gd")

## Emitted when a terrain region is loaded
signal terrain_region_loaded(region_coord: Vector2i)

## Emitted when a terrain region is unloaded
signal terrain_region_unloaded(region_coord: Vector2i)

## Emitted when terrain loading completes for current view
signal terrain_load_complete()

#region Configuration

## View distance in regions around camera (REDUCED from 8 to 3 for performance)
## Each region at 6m spacing covers 1.536km, so 3 regions = ~4.6km view distance
@export var view_distance_regions: int = 3

## Unload distance - regions beyond this are removed (should be > view_distance)
@export var unload_distance_regions: int = 5

## Maximum regions to load per frame (prevents frame spikes)
@export var max_loads_per_frame: int = 1

## Maximum regions to unload per frame
@export var max_unloads_per_frame: int = 2

## Time budget for terrain generation per frame (ms)
@export var generation_budget_ms: float = 8.0

## Enable frustum-based priority (regions in front load first)
@export var frustum_priority: bool = true

## Skip loading regions behind camera entirely (aggressive culling)
@export var skip_behind_camera: bool = true

## Enable debug output
@export var debug_enabled: bool = false

#endregion

#region References

## The world data provider
var _provider: WorldDataProviderBase = null

## The Terrain3D node to populate
var _terrain_3d: Terrain3D = null

## The node to track (camera/player)
var _tracked_node: Node3D = null

#endregion

#region State

## Regions that have been loaded: Vector2i -> Vector3 (world_pos used for loading)
## true = has terrain, false = checked but empty (ocean)
var _loaded_regions: Dictionary = {}

## Map from region coord to the world position we used to import it
## Needed for proper unloading
var _region_world_positions: Dictionary = {}

## Priority queue: Array of { region: Vector2i, priority: float }
var _generation_queue: Array = []

## Last tracked region (to detect movement)
var _last_tracked_region: Vector2i = Vector2i(999999, 999999)

## Is streaming active
var _active: bool = false

## Frame counter for throttling unload checks
var _frame_counter: int = 0

## Stats tracking
var _stats_regions_loaded: int = 0
var _stats_regions_unloaded: int = 0
var _stats_load_time_ms: float = 0.0

#endregion

#region Async State

## BackgroundProcessor for async terrain generation (optional)
var _background_processor: Node = null

## Pending async generation tasks: region_coord -> task_id
var _pending_generation: Dictionary = {}

## Completed generation results waiting for import: Array of RegionData
var _pending_import: Array = []

## Whether async mode is enabled (has background processor)
var _async_enabled: bool = false

#endregion


func _process(_delta: float) -> void:
	if not _active or not _provider or not _terrain_3d or not _tracked_node:
		return

	_frame_counter += 1

	# Check if tracked node moved to new region
	var current_region := _provider.world_pos_to_region(_tracked_node.global_position)
	if current_region != _last_tracked_region:
		_last_tracked_region = current_region
		_on_region_changed(current_region)

	# Process pending imports (from async generation)
	if not _pending_import.is_empty():
		_process_pending_imports()

	# Process generation queue (load new regions)
	if not _generation_queue.is_empty():
		_process_queue()

	# Periodically check for regions to unload (every 30 frames)
	if _frame_counter % 30 == 0:
		_unload_distant_regions(current_region)


#region Public API

## Set the world data provider
func set_provider(provider: WorldDataProviderBase) -> void:
	_provider = provider
	if _terrain_3d:
		_configure_terrain3d()
	_debug("Provider set: %s" % (provider.world_name if provider else "null"))


## Set the Terrain3D node
func set_terrain_3d(terrain: Terrain3D) -> void:
	_terrain_3d = terrain
	if _provider:
		_configure_terrain3d()
	_debug("Terrain3D set")


## Set the node to track for streaming
func set_tracked_node(node: Node3D) -> void:
	_tracked_node = node
	_debug("Tracking: %s" % (node.name if node else "null"))

	# Force immediate update
	if node and _provider:
		var region := _provider.world_pos_to_region(node.global_position)
		_last_tracked_region = region
		_on_region_changed(region)


## Set the BackgroundProcessor for async terrain generation
## When set, terrain generation runs on worker threads instead of main thread
func set_background_processor(processor: Node) -> void:
	if _background_processor and _background_processor.task_completed.is_connected(_on_generation_completed):
		_background_processor.task_completed.disconnect(_on_generation_completed)

	_background_processor = processor
	_async_enabled = processor != null

	if _background_processor:
		_background_processor.task_completed.connect(_on_generation_completed)
		_debug("Async mode enabled with BackgroundProcessor")
	else:
		_debug("Async mode disabled")


## Start streaming
func start() -> void:
	_active = true
	_debug("Streaming started (async=%s)" % _async_enabled)

	if _tracked_node and _provider:
		var region := _provider.world_pos_to_region(_tracked_node.global_position)
		_on_region_changed(region)


## Stop streaming
func stop() -> void:
	_active = false
	_generation_queue.clear()

	# Cancel pending async tasks
	if _async_enabled and _background_processor:
		for task_id in _pending_generation.values():
			_background_processor.cancel_task(task_id)
	_pending_generation.clear()
	_pending_import.clear()

	_debug("Streaming stopped")


## Clear all loaded terrain and reset state
func reset() -> void:
	# Unload all terrain regions from Terrain3D
	if _terrain_3d and _terrain_3d.data:
		for region_coord: Vector2i in _loaded_regions.keys():
			if _loaded_regions[region_coord] == true:  # Only unload actual terrain
				_unload_region(region_coord)

	_loaded_regions.clear()
	_region_world_positions.clear()
	_generation_queue.clear()
	_last_tracked_region = Vector2i(999999, 999999)
	_stats_regions_loaded = 0
	_stats_regions_unloaded = 0
	_debug("State reset - all terrain cleared")


## Check if a region is loaded
func is_region_loaded(region_coord: Vector2i) -> bool:
	return _loaded_regions.get(region_coord, false) == true


## Get statistics
func get_stats() -> Dictionary:
	var active_regions := 0
	var empty_regions := 0
	for coord: Vector2i in _loaded_regions:
		if _loaded_regions[coord] == true:
			active_regions += 1
		else:
			empty_regions += 1

	# Get actual Terrain3D region count for verification
	var t3d_regions := 0
	if _terrain_3d and _terrain_3d.data:
		t3d_regions = _terrain_3d.data.get_region_count()

	return {
		"loaded_regions": active_regions,
		"empty_regions": empty_regions,
		"terrain3d_regions": t3d_regions,
		"queue_size": _generation_queue.size(),
		"tracked_region": _last_tracked_region,
		"view_distance": view_distance_regions,
		"unload_distance": unload_distance_regions,
		"total_loaded": _stats_regions_loaded,
		"total_unloaded": _stats_regions_unloaded,
		"last_load_time_ms": _stats_load_time_ms,
	}


## Force unload all regions outside current view
func force_cleanup() -> void:
	if _tracked_node and _provider:
		var current_region := _provider.world_pos_to_region(_tracked_node.global_position)
		_unload_distant_regions(current_region, true)  # Force mode

#endregion


#region Internal

## Configure Terrain3D based on provider settings
func _configure_terrain3d() -> void:
	if not _terrain_3d or not _provider:
		return

	# Set vertex spacing from provider
	_terrain_3d.vertex_spacing = _provider.vertex_spacing

	# Set region size (256 is standard) - MUST be done before creating data
	@warning_ignore("int_as_enum_without_cast", "int_as_enum_without_match")
	_terrain_3d.change_region_size(_provider.region_size)

	# Ensure data object exists
	if not _terrain_3d.data:
		_debug("WARNING: Terrain3D has no data object!")

	# Ensure material exists
	if not _terrain_3d.material:
		_terrain_3d.set_material(Terrain3DMaterial.new())
	_terrain_3d.material.show_checkered = false

	# Ensure assets exist
	if not _terrain_3d.assets:
		_terrain_3d.set_assets(Terrain3DAssets.new())

	var actual_region_size := _terrain_3d.get_region_size()
	var actual_vertex_spacing := _terrain_3d.get_vertex_spacing()
	_debug("Terrain3D configured: vertex_spacing=%.2f (actual=%.2f), region_size=%d (actual=%d)" % [
		_provider.vertex_spacing, actual_vertex_spacing,
		_provider.region_size, actual_region_size
	])


## Called when tracked node moves to a new region
func _on_region_changed(new_region: Vector2i) -> void:
	_debug("Region changed: %s" % new_region)

	# Get camera forward for priority
	var camera_forward := Vector3.FORWARD
	if _tracked_node is Camera3D:
		camera_forward = -(_tracked_node as Camera3D).global_transform.basis.z
	camera_forward.y = 0
	camera_forward = camera_forward.normalized()

	# Queue regions within view distance
	for dy in range(-view_distance_regions, view_distance_regions + 1):
		for dx in range(-view_distance_regions, view_distance_regions + 1):
			var distance := sqrt(dx * dx + dy * dy)
			if distance > view_distance_regions:
				continue

			var region := Vector2i(new_region.x + dx, new_region.y + dy)

			# Skip if already loaded or marked as empty
			if region in _loaded_regions:
				continue

			# Skip if already generating (async mode)
			if region in _pending_generation:
				continue

			# Skip if already queued
			var already_queued := false
			for entry in _generation_queue:
				if entry.region == region:
					already_queued = true
					break
			if already_queued:
				continue

			# Skip if no terrain at this region
			if not _provider.has_terrain_at_region(region):
				_loaded_regions[region] = false  # Mark as checked (empty)
				continue

			# Calculate priority (lower = higher priority)
			var priority := distance

			# Frustum culling: check if region is behind camera
			if skip_behind_camera or frustum_priority:
				var dir := Vector3(dx, 0, -dy).normalized()
				var dot := camera_forward.dot(dir)

				# Skip regions directly behind camera (aggressive culling)
				if skip_behind_camera and dot < -0.3 and distance > 1:
					continue  # Don't even queue regions behind us

				# Frustum bonus: regions in front of camera load faster
				if frustum_priority:
					priority -= dot * 3.0  # Up to 3 priority levels bonus

			_queue_region(region, priority)


## Add region to priority queue
func _queue_region(region: Vector2i, priority: float) -> void:
	var entry := { "region": region, "priority": priority }

	# Insert in sorted order
	var inserted := false
	for i in range(_generation_queue.size()):
		if priority < _generation_queue[i].priority:
			_generation_queue.insert(i, entry)
			inserted = true
			break

	if not inserted:
		_generation_queue.append(entry)


## Process the generation queue with time budgeting
func _process_queue() -> void:
	var start_time := Time.get_ticks_usec()
	var budget_usec := generation_budget_ms * 1000.0
	var loads_this_frame := 0

	while not _generation_queue.is_empty():
		# Check time budget
		var elapsed := Time.get_ticks_usec() - start_time
		if elapsed >= budget_usec:
			break

		# Limit loads per frame to prevent spikes
		if loads_this_frame >= max_loads_per_frame:
			break

		var entry: Dictionary = _generation_queue.pop_front()
		var region: Vector2i = entry.region

		# Skip if already loaded (race condition)
		if region in _loaded_regions:
			continue

		_load_region(region)
		loads_this_frame += 1

	_stats_load_time_ms = (Time.get_ticks_usec() - start_time) / 1000.0

	# Check if loading is complete
	if _generation_queue.is_empty():
		terrain_load_complete.emit()


## Load a single terrain region
## In async mode, submits to BackgroundProcessor. In sync mode, generates inline.
func _load_region(region_coord: Vector2i) -> void:
	if not _provider or not _terrain_3d or not _terrain_3d.data:
		return

	if _async_enabled and _background_processor:
		_load_region_async(region_coord)
	else:
		_load_region_sync(region_coord)


## Load region synchronously (original behavior)
func _load_region_sync(region_coord: Vector2i) -> void:
	# Get heightmap from provider
	var heightmap: Image = _provider.get_heightmap_for_region(region_coord)
	if not heightmap:
		_loaded_regions[region_coord] = false  # Empty
		return

	# Get optional control and color maps
	var controlmap: Image = _provider.get_controlmap_for_region(region_coord)
	var colormap: Image = _provider.get_colormap_for_region(region_coord)

	# Create default maps if not provided
	if not controlmap:
		controlmap = _create_default_controlmap()
	if not colormap:
		colormap = _create_default_colormap()

	# Calculate world position for this region
	var world_pos := _provider.region_to_world_pos(region_coord)

	# Create import array
	var images: Array[Image] = []
	images.resize(Terrain3DRegion.TYPE_MAX)
	images[Terrain3DRegion.TYPE_HEIGHT] = heightmap
	images[Terrain3DRegion.TYPE_CONTROL] = controlmap
	images[Terrain3DRegion.TYPE_COLOR] = colormap

	# Import into Terrain3D
	var region_world_size := float(_provider.region_size) * _provider.vertex_spacing
	_debug("Importing region %s: heightmap=%s, world_pos=(%.0f, 0, %.0f), region_size=%.0fm" % [
		region_coord,
		"%dx%d" % [heightmap.get_width(), heightmap.get_height()],
		world_pos.x, world_pos.z,
		region_world_size
	])

	_terrain_3d.data.import_images(images, world_pos, 0.0, 1.0)

	# Verify region was added and check its location
	var t3d_count := _terrain_3d.data.get_region_count()
	var t3d_loc := _terrain_3d.data.get_region_location(world_pos)
	_debug("Terrain3D: %d regions, this one at T3D loc %s" % [t3d_count, t3d_loc])

	# Track this region
	_loaded_regions[region_coord] = true
	_region_world_positions[region_coord] = world_pos
	_stats_regions_loaded += 1

	terrain_region_loaded.emit(region_coord)
	_debug("Loaded region: %s at world pos (%.0f, %.0f)" % [region_coord, world_pos.x, world_pos.z])


## Load region asynchronously using BackgroundProcessor
func _load_region_async(region_coord: Vector2i) -> void:
	# Check if already generating
	if region_coord in _pending_generation:
		return

	# Capture data needed for background generation
	var vertex_spacing := _terrain_3d.get_vertex_spacing()
	var region_size := _provider.region_size

	# Submit generation task
	var task_id: int = _background_processor.submit_task(func():
		return _generate_region_on_worker(region_coord, vertex_spacing, region_size)
	)

	_pending_generation[region_coord] = task_id
	_debug("Async generation started for region %s (task %d)" % [region_coord, task_id])


## Generate region data on worker thread (THREAD-SAFE)
## This runs on a background worker, no scene tree access allowed!
func _generate_region_on_worker(region_coord: Vector2i, vertex_spacing: float, region_size: int) -> Dictionary:
	# Get heightmap from provider (must be thread-safe)
	var heightmap: Image = _provider.get_heightmap_for_region(region_coord)
	if not heightmap:
		return {"region_coord": region_coord, "has_data": false}

	# Get optional control and color maps
	var controlmap: Image = _provider.get_controlmap_for_region(region_coord)
	var colormap: Image = _provider.get_colormap_for_region(region_coord)

	# Create default maps if not provided
	if not controlmap:
		controlmap = _create_default_controlmap_static(region_size)
	if not colormap:
		colormap = _create_default_colormap_static(region_size)

	# Calculate world position (pure math, thread-safe)
	var region_world_size := float(region_size) * vertex_spacing
	var world_x := float(region_coord.x) * region_world_size + region_world_size * 0.5
	var world_z := float(-region_coord.y) * region_world_size - region_world_size * 0.5

	return {
		"region_coord": region_coord,
		"has_data": true,
		"heightmap": heightmap,
		"controlmap": controlmap,
		"colormap": colormap,
		"world_pos": Vector3(world_x, 0, world_z)
	}


## Handle generation completion from BackgroundProcessor
func _on_generation_completed(task_id: int, result: Variant) -> void:
	# Find which region this was for
	var region_coord: Vector2i = Vector2i.ZERO
	var found := false

	for coord in _pending_generation:
		if _pending_generation[coord] == task_id:
			region_coord = coord
			found = true
			break

	if not found:
		return  # Unknown task, ignore

	_pending_generation.erase(region_coord)

	# Queue the result for main thread import
	if result is Dictionary:
		_pending_import.append(result)
		_debug("Async generation completed for region %s" % region_coord)


## Process pending imports on main thread
func _process_pending_imports() -> void:
	var start_time := Time.get_ticks_usec()
	var budget_usec := generation_budget_ms * 1000.0
	var imports_this_frame := 0

	while not _pending_import.is_empty():
		# Check time budget
		var elapsed := Time.get_ticks_usec() - start_time
		if elapsed >= budget_usec:
			break

		# Limit imports per frame
		if imports_this_frame >= max_loads_per_frame:
			break

		var data: Dictionary = _pending_import.pop_front()
		_import_generated_data(data)
		imports_this_frame += 1


## Import pre-generated data into Terrain3D (MAIN THREAD ONLY)
func _import_generated_data(data: Dictionary) -> void:
	var region_coord: Vector2i = data.get("region_coord", Vector2i.ZERO)

	if not data.get("has_data", false):
		_loaded_regions[region_coord] = false  # Mark as empty
		return

	if not _terrain_3d or not _terrain_3d.data:
		return

	var heightmap: Image = data.get("heightmap")
	var controlmap: Image = data.get("controlmap")
	var colormap: Image = data.get("colormap")
	var world_pos: Vector3 = data.get("world_pos", Vector3.ZERO)

	if not heightmap:
		_loaded_regions[region_coord] = false
		return

	# Create import array
	var images: Array[Image] = []
	images.resize(Terrain3DRegion.TYPE_MAX)
	images[Terrain3DRegion.TYPE_HEIGHT] = heightmap
	images[Terrain3DRegion.TYPE_CONTROL] = controlmap
	images[Terrain3DRegion.TYPE_COLOR] = colormap

	_debug("Importing async region %s: world_pos=(%.0f, 0, %.0f)" % [
		region_coord, world_pos.x, world_pos.z
	])

	_terrain_3d.data.import_images(images, world_pos, 0.0, 1.0)

	# Track this region
	_loaded_regions[region_coord] = true
	_region_world_positions[region_coord] = world_pos
	_stats_regions_loaded += 1

	terrain_region_loaded.emit(region_coord)
	_debug("Loaded async region: %s" % region_coord)


## Create default control map (static version for worker threads)
static func _create_default_controlmap_static(size: int) -> Image:
	var img := Image.create(size, size, false, Image.FORMAT_RF)

	# Default to texture slot 0
	var value: int = 0
	value |= (0 & 0x1F) << 27
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, value)
	var default_value := bytes.decode_float(0)

	img.fill(Color(default_value, 0, 0, 1))
	return img


## Create default color map (static version for worker threads)
static func _create_default_colormap_static(size: int) -> Image:
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	img.fill(Color.WHITE)
	return img


## Unload a terrain region from Terrain3D
func _unload_region(region_coord: Vector2i) -> void:
	if not _terrain_3d or not _terrain_3d.data:
		return

	if region_coord not in _region_world_positions:
		return

	var world_pos: Vector3 = _region_world_positions[region_coord]

	# Use Terrain3D's get_region_location API to find the region location
	var t3d_loc: Vector2i = _terrain_3d.data.get_region_location(world_pos)

	# Find and remove the region with this location
	var removed := false
	for t3d_region in _terrain_3d.data.get_regions_active():
		if t3d_region.get_location() == t3d_loc:
			_terrain_3d.data.remove_region(t3d_region, false)
			removed = true
			_stats_regions_unloaded += 1
			terrain_region_unloaded.emit(region_coord)
			_debug("Unloaded region: %s (T3D loc: %s)" % [region_coord, t3d_loc])
			break

	if not removed:
		_debug("Warning: No T3D region at loc %s for our region %s" % [t3d_loc, region_coord])

	# Clean up our tracking regardless
	_loaded_regions.erase(region_coord)
	_region_world_positions.erase(region_coord)


## Unload regions that are too far from the camera
func _unload_distant_regions(current_region: Vector2i, force: bool = false) -> void:
	var unload_dist := unload_distance_regions
	var to_unload: Array[Vector2i] = []

	for region_coord: Vector2i in _loaded_regions.keys():
		# Skip empty regions (just markers, no GPU resources)
		if _loaded_regions[region_coord] != true:
			continue

		var dx := region_coord.x - current_region.x
		var dy := region_coord.y - current_region.y
		var distance := sqrt(dx * dx + dy * dy)

		if distance > unload_dist:
			to_unload.append(region_coord)

	# Limit unloads per frame unless forced
	if not force and to_unload.size() > max_unloads_per_frame:
		# Sort by distance (farthest first)
		to_unload.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			var da := Vector2(a - current_region).length()
			var db := Vector2(b - current_region).length()
			return da > db
		)
		to_unload.resize(max_unloads_per_frame)

	for region_coord in to_unload:
		_unload_region(region_coord)

	# Also clean up stale empty region markers (keep memory tidy)
	if _frame_counter % 300 == 0:  # Every ~5 seconds
		var stale_empties: Array[Vector2i] = []
		for region_coord: Vector2i in _loaded_regions.keys():
			if _loaded_regions[region_coord] == false:
				var dx := region_coord.x - current_region.x
				var dy := region_coord.y - current_region.y
				var distance := sqrt(dx * dx + dy * dy)
				if distance > unload_dist * 2:
					stale_empties.append(region_coord)

		for region_coord in stale_empties:
			_loaded_regions.erase(region_coord)


## Create default control map (single texture)
func _create_default_controlmap() -> Image:
	var size := _provider.region_size if _provider else 256
	var img := Image.create(size, size, false, Image.FORMAT_RF)

	# Default to texture slot 0
	var default_value := _encode_control_value(0, 0, 0)
	img.fill(Color(default_value, 0, 0, 1))

	return img


## Create default color map (white)
func _create_default_colormap() -> Image:
	var size := _provider.region_size if _provider else 256
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	img.fill(Color.WHITE)
	return img


## Encode Terrain3D control value
func _encode_control_value(base_tex: int, overlay_tex: int, blend: int) -> float:
	var value: int = 0
	value |= (base_tex & 0x1F) << 27
	value |= (overlay_tex & 0x1F) << 22
	value |= (blend & 0xFF) << 14

	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, value)
	return bytes.decode_float(0)


func _debug(msg: String) -> void:
	if debug_enabled:
		print("GenericTerrainStreamer: %s" % msg)

#endregion
