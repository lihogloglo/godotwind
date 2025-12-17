## DeformationManager - Singleton managing RTT-based terrain deformation
## Handles chunk streaming, viewport pooling, and material presets
class_name DeformationManagerClass
extends Node

## Configuration
@export var enabled: bool = true
@export var chunk_size: float = 256.0  ## Must match Terrain3D region size
@export_range(256, 2048, 256) var texture_resolution: int = 512
@export var max_active_chunks: int = 25  ## 5×5 grid around camera
@export var deformation_depth_max: float = 0.3  ## Max depth in meters

## Performance
@export_group("Performance")
@export var chunk_init_budget_ms: float = 2.0  ## Time budget per frame
@export var enable_persistence: bool = true
@export var persistence_save_interval: float = 10.0  ## Auto-save interval

## Material presets
var snow_preset: DeformationPreset
var mud_preset: DeformationPreset
var ash_preset: DeformationPreset
var current_preset: DeformationPreset

## State
var active_chunks: Dictionary = {}  ## Vector2i -> DeformationChunk
var viewport_pool: Array[SubViewport] = []
var chunk_creation_queue: Array[Vector2i] = []
var dirty_chunks: Array[DeformationChunk] = []
var camera: Camera3D
var last_camera_chunk: Vector2i = Vector2i(-9999, -9999)

## Persistence
var save_timer: float = 0.0
var persistence_path: String = "user://deformation_cache/"

## Signals
signal chunk_created(chunk: DeformationChunk)
signal chunk_unloaded(chunk_coord: Vector2i)
signal chunk_texture_updated(chunk: DeformationChunk)


func _ready() -> void:
	# Initialize presets
	snow_preset = DeformationPreset.create_snow_preset()
	mud_preset = DeformationPreset.create_mud_preset()
	ash_preset = DeformationPreset.create_ash_preset()
	current_preset = snow_preset

	# Create persistence directory
	if enable_persistence:
		if not DirAccess.dir_exists_absolute(persistence_path):
			DirAccess.make_dir_recursive_absolute(persistence_path)

	# Initialize viewport pool
	_initialize_viewport_pool(5)  ## Start with 5 pooled viewports

	print("[DeformationManager] Initialized - chunk size: %.0fm, resolution: %d" % [chunk_size, texture_resolution])


func _process(delta: float) -> void:
	if not enabled:
		return

	# Find camera if not set
	if not camera:
		camera = get_viewport().get_camera_3d()
		return

	# Update chunks around camera
	_update_chunks_around_camera()

	# Process chunk creation queue (time-budgeted)
	_process_chunk_creation_queue(delta)

	# Render dirty chunks
	_render_dirty_chunks()

	# Update decay
	_update_decay(delta)

	# Auto-save persistence data
	if enable_persistence:
		save_timer += delta
		if save_timer >= persistence_save_interval:
			save_dirty_chunks()
			save_timer = 0.0


## Update active chunks based on camera position
func _update_chunks_around_camera() -> void:
	if not camera:
		return

	var camera_pos := camera.global_position
	var camera_chunk := world_pos_to_chunk_coord(camera_pos)

	# Early exit if camera hasn't moved to new chunk
	if camera_chunk == last_camera_chunk:
		return

	last_camera_chunk = camera_chunk

	# Calculate which chunks should be active
	var chunks_to_keep: Dictionary = {}
	var view_radius := int(sqrt(max_active_chunks) / 2)  ## 5×5 = radius 2

	for x in range(-view_radius, view_radius + 1):
		for y in range(-view_radius, view_radius + 1):
			var chunk_coord := camera_chunk + Vector2i(x, y)
			chunks_to_keep[chunk_coord] = true

			# Queue for creation if not active
			if not active_chunks.has(chunk_coord) and not chunk_creation_queue.has(chunk_coord):
				chunk_creation_queue.append(chunk_coord)

	# Unload chunks outside view
	var chunks_to_unload: Array[Vector2i] = []
	for chunk_coord in active_chunks.keys():
		if not chunks_to_keep.has(chunk_coord):
			chunks_to_unload.append(chunk_coord)

	for chunk_coord in chunks_to_unload:
		_unload_chunk(chunk_coord)


## Process chunk creation queue with time budget
func _process_chunk_creation_queue(delta: float) -> void:
	if chunk_creation_queue.is_empty():
		return

	var budget_start := Time.get_ticks_usec()
	var budget_us := chunk_init_budget_ms * 1000.0

	while chunk_creation_queue.size() > 0:
		if (Time.get_ticks_usec() - budget_start) > budget_us:
			break  # Defer to next frame

		var chunk_coord := chunk_creation_queue.pop_front()
		_create_chunk(chunk_coord)


## Create a new deformation chunk
func _create_chunk(chunk_coord: Vector2i) -> DeformationChunk:
	var chunk := DeformationChunk.new()
	chunk.name = "DeformationChunk_%d_%d" % [chunk_coord.x, chunk_coord.y]

	# Get pooled viewport or create new
	var pooled_viewport: SubViewport = null
	if viewport_pool.size() > 0:
		pooled_viewport = viewport_pool.pop_back()

	chunk.initialize(chunk_coord, chunk_size, texture_resolution, current_preset, pooled_viewport)
	add_child(chunk)

	# Try to load persistence data
	if enable_persistence:
		var save_path := _get_chunk_save_path(chunk_coord)
		chunk.load_from_disk(save_path)

	active_chunks[chunk_coord] = chunk
	chunk_created.emit(chunk)

	return chunk


## Unload a chunk and return viewport to pool
func _unload_chunk(chunk_coord: Vector2i) -> void:
	if not active_chunks.has(chunk_coord):
		return

	var chunk: DeformationChunk = active_chunks[chunk_coord]

	# Save to disk if dirty
	if enable_persistence and chunk.is_dirty:
		var save_path := _get_chunk_save_path(chunk_coord)
		chunk.save_to_disk(save_path)

	# Return viewport to pool
	var viewport := chunk.cleanup()
	if viewport and viewport_pool.size() < max_active_chunks + 5:
		viewport_pool.append(viewport)
	else:
		viewport.queue_free()

	chunk.queue_free()
	active_chunks.erase(chunk_coord)
	chunk_unloaded.emit(chunk_coord)


## Render all dirty chunks
func _render_dirty_chunks() -> void:
	for chunk in dirty_chunks:
		chunk.render_pending_brushes()
		chunk_texture_updated.emit(chunk)

	dirty_chunks.clear()


## Update decay for all chunks
func _update_decay(delta: float) -> void:
	# Limit to 1 chunk per frame to avoid performance spikes
	var chunks_array := active_chunks.values()
	if chunks_array.size() > 0:
		var chunk_index := int(Time.get_ticks_msec() / 100) % chunks_array.size()
		chunks_array[chunk_index].update_decay(delta)


## Apply deformation at world position
func apply_deformation(world_pos: Vector3, brush_settings: Dictionary) -> void:
	if not enabled:
		return

	var radius: float = brush_settings.get("radius", 1.0)
	var strength: float = brush_settings.get("strength", 1.0)

	# Find affected chunks
	var chunk_coord := world_pos_to_chunk_coord(world_pos)
	var chunk := active_chunks.get(chunk_coord)

	if chunk:
		chunk.queue_brush(world_pos, radius, strength)
		if not dirty_chunks.has(chunk):
			dirty_chunks.append(chunk)


## Get chunk at world position
func get_chunk_at(world_pos: Vector3) -> DeformationChunk:
	var chunk_coord := world_pos_to_chunk_coord(world_pos)
	return active_chunks.get(chunk_coord)


## Convert world position to chunk coordinate
func world_pos_to_chunk_coord(world_pos: Vector3) -> Vector2i:
	return Vector2i(
		floori(world_pos.x / chunk_size),
		floori(world_pos.z / chunk_size)
	)


## Set active material preset
func set_material_preset(preset_name: String) -> void:
	match preset_name.to_lower():
		"snow":
			current_preset = snow_preset
		"mud":
			current_preset = mud_preset
		"ash":
			current_preset = ash_preset
		_:
			push_warning("[DeformationManager] Unknown preset: " + preset_name)
			return

	print("[DeformationManager] Switched to preset: " + preset_name)


## Initialize viewport pool
func _initialize_viewport_pool(count: int) -> void:
	for i in range(count):
		var vp := SubViewport.new()
		vp.size = Vector2i(texture_resolution, texture_resolution)
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		viewport_pool.append(vp)


## Get save path for chunk
func _get_chunk_save_path(chunk_coord: Vector2i) -> String:
	return persistence_path + "chunk_%d_%d.png" % [chunk_coord.x, chunk_coord.y]


## Save all dirty chunks to disk
func save_dirty_chunks() -> void:
	for chunk in active_chunks.values():
		if chunk.is_dirty:
			var save_path := _get_chunk_save_path(chunk.chunk_coord)
			chunk.save_to_disk(save_path)
			chunk.is_dirty = false


## Clear all deformations
func clear_all_deformations() -> void:
	for chunk in active_chunks.values():
		chunk.pending_brushes.clear()
		chunk.is_dirty = false

	dirty_chunks.clear()


## Print debug statistics
func print_stats() -> void:
	print("=== Deformation System Stats ===")
	print("Active chunks: %d" % active_chunks.size())
	print("Pooled viewports: %d" % viewport_pool.size())
	print("Dirty chunks: %d" % dirty_chunks.size())
	print("Memory (est): %.1f MB" % _estimate_memory_mb())

func _estimate_memory_mb() -> float:
	var bytes_per_chunk := texture_resolution * texture_resolution * 8  # RGBA16F
	return (active_chunks.size() * bytes_per_chunk) / (1024.0 * 1024.0)
