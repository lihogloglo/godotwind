## ShoreMaskGenerator - Generates shore dampening mask from terrain
## Auto-generates based on terrain height, allows manual editing
class_name ShoreMaskGenerator
extends Node

# Shore mask texture
var _shore_mask: ImageTexture = null
var _shore_image: Image = null
var _mask_resolution: int = 2048

# World bounds covered by the mask
var _world_bounds: Rect2 = Rect2(-8000, -8000, 16000, 16000)

# User override mask (for manual editing)
var _user_mask: Image = null
var _user_mask_path: String = ""

# Cached terrain reference
var _terrain: Terrain3D = null

# Cached sea level
var _sea_level: float = 0.0


func generate_from_terrain(terrain: Terrain3D, resolution: int, fade_distance: float, sea_level: float = 0.0) -> void:
	_terrain = terrain
	_mask_resolution = resolution
	_sea_level = sea_level

	# Determine world bounds from terrain
	_calculate_world_bounds()

	# Create shore mask image
	_shore_image = Image.create(_mask_resolution, _mask_resolution, false, Image.FORMAT_R8)

	print("[ShoreMaskGenerator] Generating shore mask %dx%d at sea level %.1f..." % [_mask_resolution, _mask_resolution, _sea_level])

	# Sample terrain heights
	for y in range(_mask_resolution):
		for x in range(_mask_resolution):
			var world_pos := _pixel_to_world(x, y)
			var terrain_height := _get_terrain_height(world_pos)

			# Calculate shore factor:
			# - Below sea level: 1.0 (full ocean)
			# - At sea level: 0.5 (transition)
			# - Above sea level + fade_distance: 0.0 (no ocean)
			var height_above_sea := terrain_height - _sea_level
			var shore_factor: float

			if height_above_sea < 0:
				# Below sea level - full ocean, but fade at deep water
				shore_factor = 1.0
			elif height_above_sea > fade_distance:
				# Above fade distance - no ocean
				shore_factor = 0.0
			else:
				# Transition zone - smooth fade
				shore_factor = 1.0 - smoothstep(0.0, fade_distance, height_above_sea)

			# Apply user override if available
			if _user_mask:
				var user_value := _user_mask.get_pixel(x, y).r
				# Blend: user mask acts as multiplier
				shore_factor *= user_value

			_shore_image.set_pixel(x, y, Color(shore_factor, 0, 0, 1))

	# Create texture from image
	_shore_mask = ImageTexture.create_from_image(_shore_image)

	print("[ShoreMaskGenerator] Shore mask generated, bounds: (%.0f, %.0f) to (%.0f, %.0f)" % [
		_world_bounds.position.x, _world_bounds.position.y,
		_world_bounds.end.x, _world_bounds.end.y
	])


func _calculate_world_bounds() -> void:
	if not _terrain or not _terrain.data:
		# Default to large bounds
		_world_bounds = Rect2(-8000, -8000, 16000, 16000)
		return

	# Get terrain bounds from Terrain3D
	# Terrain3D uses region-based storage
	var region_count := _terrain.data.get_region_count()
	if region_count == 0:
		_world_bounds = Rect2(-8000, -8000, 16000, 16000)
		return

	# Calculate bounds from regions
	var min_x := INF
	var min_z := INF
	var max_x := -INF
	var max_z := -INF

	var vertex_spacing := _terrain.get_vertex_spacing()
	var region_size := 256  # Terrain3D default region size in vertices

	# Iterate through regions to find bounds
	# This is approximate - Terrain3D doesn't expose region list directly
	# Use a reasonable default
	min_x = -4000
	min_z = -4000
	max_x = 4000
	max_z = 4000

	# Add padding
	var padding := 500.0
	_world_bounds = Rect2(
		min_x - padding,
		min_z - padding,
		(max_x - min_x) + padding * 2,
		(max_z - min_z) + padding * 2
	)


func _get_terrain_height(world_pos: Vector3) -> float:
	if _terrain and _terrain.data:
		return _terrain.data.get_height(world_pos)
	return 0.0


func _pixel_to_world(x: int, y: int) -> Vector3:
	var u := float(x) / float(_mask_resolution)
	var v := float(y) / float(_mask_resolution)

	return Vector3(
		_world_bounds.position.x + u * _world_bounds.size.x,
		0.0,
		_world_bounds.position.y + v * _world_bounds.size.y
	)


func _world_to_pixel(world_pos: Vector3) -> Vector2i:
	var u := (world_pos.x - _world_bounds.position.x) / _world_bounds.size.x
	var v := (world_pos.z - _world_bounds.position.y) / _world_bounds.size.y

	return Vector2i(
		clampi(int(u * _mask_resolution), 0, _mask_resolution - 1),
		clampi(int(v * _mask_resolution), 0, _mask_resolution - 1)
	)


func smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t := clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Get shore factor at world position (0 = no ocean, 1 = full ocean)
func get_shore_factor(world_pos: Vector3) -> float:
	if not _shore_image:
		# Fallback: check terrain height directly
		if _terrain and _terrain.data:
			var height := _terrain.data.get_height(world_pos)
			return 1.0 if height < _sea_level else 0.0
		return 1.0  # Assume ocean everywhere

	var pixel := _world_to_pixel(world_pos)
	return _shore_image.get_pixel(pixel.x, pixel.y).r


## Get the shore mask texture for shader use
func get_shore_mask_texture() -> ImageTexture:
	return _shore_mask


## Get the world bounds of the shore mask
func get_world_bounds() -> Rect2:
	return _world_bounds


## Load a user-edited mask to override auto-generation
func load_user_mask(path: String) -> bool:
	if not FileAccess.file_exists(path):
		push_warning("[ShoreMaskGenerator] User mask not found: %s" % path)
		return false

	_user_mask = Image.load_from_file(path)
	if _user_mask:
		_user_mask_path = path
		# Resize to match our resolution
		if _user_mask.get_size() != Vector2i(_mask_resolution, _mask_resolution):
			_user_mask.resize(_mask_resolution, _mask_resolution)
		print("[ShoreMaskGenerator] Loaded user mask: %s" % path)
		return true

	return false


## Export the shore mask for manual editing
func export_mask(path: String) -> bool:
	if not _shore_image:
		push_warning("[ShoreMaskGenerator] No shore mask to export")
		return false

	var error := _shore_image.save_png(path)
	if error == OK:
		print("[ShoreMaskGenerator] Exported shore mask to: %s" % path)
		return true
	else:
		push_error("[ShoreMaskGenerator] Failed to export shore mask: %d" % error)
		return false


## Clear user mask override
func clear_user_mask() -> void:
	_user_mask = null
	_user_mask_path = ""


## Regenerate mask (call after terrain changes or user mask load)
func regenerate(fade_distance: float) -> void:
	if _terrain:
		generate_from_terrain(_terrain, _mask_resolution, fade_distance)
