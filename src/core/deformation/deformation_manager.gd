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

## Terrain3D Integration
var terrain_3d: Terrain3D = null  ## Reference to Terrain3D node
var terrain_material: ShaderMaterial = null  ## Terrain3D's shader material
var deformation_texture_array: Texture2DArray = null  ## Combined deformation textures
var deformation_map: Array[int] = []  ## Terrain region index -> deformation texture layer (-1 = no deformation)
var texture_array_dirty: bool = false  ## Needs texture array rebuild

## Persistence
var save_timer: float = 0.0
var persistence_path: String = "user://deformation_cache/"

## Signals
signal chunk_created(chunk: DeformationChunk)
signal chunk_unloaded(chunk_coord: Vector2i)
signal chunk_texture_updated(chunk: DeformationChunk)
signal terrain_shader_updated()


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

	# Initialize deformation map (1024 regions max in Terrain3D)
	deformation_map.resize(1024)
	for i in range(1024):
		deformation_map[i] = -1  # No deformation by default

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

	# Update Terrain3D shader if texture array changed
	if texture_array_dirty and terrain_3d and terrain_material:
		_update_terrain_shader()
		texture_array_dirty = false


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

	# Mark texture array as dirty for shader update
	texture_array_dirty = true

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

	# Mark texture array as dirty for shader update
	texture_array_dirty = true


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


## Set Terrain3D reference for shader integration
func set_terrain_3d(terrain: Terrain3D) -> void:
	terrain_3d = terrain

	if terrain_3d and terrain_3d.material:
		terrain_material = terrain_3d.material as ShaderMaterial

		if not terrain_material:
			push_warning("[DeformationManager] Terrain3D material is not a ShaderMaterial. Deformation will not be visible.")
		else:
			print("[DeformationManager] Connected to Terrain3D with ShaderMaterial")
			_update_terrain_shader()


## Build Texture2DArray from all active chunk textures
func _build_deformation_texture_array() -> Texture2DArray:
	if active_chunks.is_empty():
		return null

	# Sort chunks by coordinate for consistent ordering
	var sorted_coords := active_chunks.keys()
	sorted_coords.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x
	)

	# Collect images from chunks
	var images: Array[Image] = []
	var coord_to_layer: Dictionary = {}  # Vector2i -> texture layer index

	for i in range(sorted_coords.size()):
		var coord: Vector2i = sorted_coords[i]
		var chunk: DeformationChunk = active_chunks[coord]

		# Get chunk's deformation texture as image
		var img: Image = chunk.get_deformation_texture().get_image()
		if img:
			images.append(img)
			coord_to_layer[coord] = i

	# Create Texture2DArray from images
	if images.is_empty():
		return null

	var texture_array := Texture2DArray.new()
	texture_array.create_from_images(images)

	# Update deformation_map: terrain region index -> texture layer
	# This maps Terrain3D's region indices to our deformation texture layers
	_update_deformation_map(coord_to_layer)

	return texture_array


## Update deformation map: Terrain3D region index -> deformation texture layer
func _update_deformation_map(coord_to_layer: Dictionary) -> void:
	# Reset all to -1 (no deformation)
	for i in range(1024):
		deformation_map[i] = -1

	if not terrain_3d or not terrain_3d.data:
		return

	# Map each deformation chunk to its Terrain3D region index
	for coord in coord_to_layer.keys():
		var layer: int = coord_to_layer[coord]

		# Calculate world position of this chunk
		var world_pos := Vector3(
			coord.x * chunk_size + chunk_size / 2.0,
			0.0,
			coord.y * chunk_size + chunk_size / 2.0
		)

		# Get Terrain3D region index at this position
		var region_loc: Vector2i = terrain_3d.data.get_region_location(world_pos)

		# Calculate region index in _region_map (Terrain3D uses 32x32 grid)
		# Region indices are offset by +16 to center the grid
		var region_map_x := region_loc.x + 16
		var region_map_y := region_loc.y + 16

		if region_map_x >= 0 and region_map_x < 32 and region_map_y >= 0 and region_map_y < 32:
			var region_index := region_map_y * 32 + region_map_x
			deformation_map[region_index] = layer


## Update Terrain3D shader uniforms with deformation data
func _update_terrain_shader() -> void:
	if not terrain_material:
		return

	# Build texture array from active chunks
	deformation_texture_array = _build_deformation_texture_array()

	# Update shader parameters
	terrain_material.set_shader_parameter("enable_deformation", enabled and deformation_texture_array != null)
	terrain_material.set_shader_parameter("deformation_textures", deformation_texture_array)
	terrain_material.set_shader_parameter("deformation_region_count", active_chunks.size())
	terrain_material.set_shader_parameter("deformation_scale", deformation_depth_max)
	terrain_material.set_shader_parameter("deformation_normal_strength", current_preset.normal_strength if current_preset else 0.8)

	# Update deformation map (array of 1024 ints)
	# Note: Godot shaders require arrays to be passed as shader parameters
	# We need to convert our Array[int] to a PackedInt32Array or pass individual values
	for i in range(min(1024, deformation_map.size())):
		terrain_material.set_shader_parameter("deformation_map[%d]" % i, deformation_map[i])

	terrain_shader_updated.emit()

	print("[DeformationManager] Updated Terrain3D shader: %d chunks, array=%s" % [
		active_chunks.size(),
		"valid" if deformation_texture_array else "null"
	])


## Print debug statistics
func print_stats() -> void:
	print("=== Deformation System Stats ===")
	print("Active chunks: %d" % active_chunks.size())
	print("Pooled viewports: %d" % viewport_pool.size())
	print("Dirty chunks: %d" % dirty_chunks.size())
	print("Texture array: %s" % ("valid" if deformation_texture_array else "null"))
	print("Terrain3D: %s" % ("connected" if terrain_3d else "not connected"))
	print("Memory (est): %.1f MB" % _estimate_memory_mb())

func _estimate_memory_mb() -> float:
	var bytes_per_chunk := texture_resolution * texture_resolution * 8  # RGBA16F
	return (active_chunks.size() * bytes_per_chunk) / (1024.0 * 1024.0)
