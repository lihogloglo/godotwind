## ShoreMaskGenerator - Runtime shore distance map generation from terrain
##
## Creates a texture where each pixel stores the shore factor:
## - 0.0 = at shore or on land (full wave dampening)
## - 1.0 = far from shore (full waves, beyond fade_distance)
##
## Uses Jump Flooding Algorithm (JFA) for efficient Euclidean distance computation.
## This is used for wave dampening near coastlines (OpenMW-style).
class_name ShoreMaskGenerator
extends Node

const CS := preload("res://src/core/coordinate_system.gd")

## Shore mask texture
var _shore_mask: ImageTexture = null
var _shore_image: Image = null
var _mask_resolution: int = 2048

## World bounds covered by the mask
var _world_bounds: Rect2 = Rect2()

## User override mask (for manual editing)
var _user_mask: Image = null
var _user_mask_path: String = ""

## Cached terrain reference
var _terrain: Terrain3D = null

## Cached sea level
var _sea_level: float = 0.0

## Fade distance for shore gradient
var _fade_distance: float = 50.0

## Internal: seed map for JFA
var _seeds: PackedInt32Array


## Generate shore distance map from terrain using JFA
## fade_distance: horizontal distance in meters over which waves should fade (e.g., 50m)
func generate_from_terrain(terrain: Terrain3D, resolution: int, fade_distance: float, sea_level: float = 0.0) -> void:
	_terrain = terrain
	_mask_resolution = resolution
	_sea_level = sea_level
	_fade_distance = fade_distance

	# Determine world bounds from terrain
	_calculate_world_bounds()

	Log.info("water", "ShoreMaskGenerator: Generating shore distance map %dx%d, fade=%.0fm, sea_level=%.1f..." % [
		_mask_resolution, _mask_resolution, fade_distance, _sea_level])

	var start_time := Time.get_ticks_msec()

	# Step 1: Create binary mask and find shore pixels
	var binary_mask := PackedByteArray()
	binary_mask.resize(_mask_resolution * _mask_resolution)

	_seeds = PackedInt32Array()
	_seeds.resize(_mask_resolution * _mask_resolution)
	_seeds.fill(-1)

	# Classify water vs land
	for y in range(_mask_resolution):
		for x in range(_mask_resolution):
			var world_pos := _pixel_to_world(x, y)
			var terrain_height := _get_terrain_height(world_pos)
			var idx := y * _mask_resolution + x
			binary_mask[idx] = 1 if terrain_height < _sea_level else 0

	# Find shore pixels (water adjacent to land, 8-connected)
	var shore_count := 0
	for y in range(_mask_resolution):
		for x in range(_mask_resolution):
			var idx := y * _mask_resolution + x
			if binary_mask[idx] == 1:  # Water
				var adjacent_to_land := false
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if dx == 0 and dy == 0:
							continue
						var nx := x + dx
						var ny := y + dy
						if nx >= 0 and nx < _mask_resolution and ny >= 0 and ny < _mask_resolution:
							if binary_mask[ny * _mask_resolution + nx] == 0:
								adjacent_to_land = true
								break
					if adjacent_to_land:
						break
				if adjacent_to_land:
					_seeds[idx] = idx
					shore_count += 1

	Log.debug("water", "ShoreMaskGenerator: Found %d shore pixels" % shore_count)

	# Step 2: Jump Flooding Algorithm
	var step := _mask_resolution / 2
	while step >= 1:
		_jfa_pass(step, binary_mask)
		step /= 2

	# Step 3: Compute shore factor with smoothstep
	_shore_image = Image.create(_mask_resolution, _mask_resolution, false, Image.FORMAT_R8)
	var texel_size := _world_bounds.size.x / float(_mask_resolution)

	for y in range(_mask_resolution):
		for x in range(_mask_resolution):
			var idx := y * _mask_resolution + x
			var is_water := binary_mask[idx] == 1

			if not is_water:
				_shore_image.set_pixel(x, y, Color(0.0, 0, 0, 1))
			else:
				var seed_idx := _seeds[idx]
				var shore_factor: float

				if seed_idx < 0:
					shore_factor = 1.0
				elif seed_idx == idx:
					shore_factor = 0.0
				else:
					var seed_x := seed_idx % _mask_resolution
					var seed_y := seed_idx / _mask_resolution
					var dx := float(x - seed_x)
					var dy := float(y - seed_y)
					var pixel_distance := sqrt(dx * dx + dy * dy)
					var world_distance := pixel_distance * texel_size
					shore_factor = _smoothstep(0.0, _fade_distance, world_distance)

				_shore_image.set_pixel(x, y, Color(shore_factor, 0, 0, 1))

	# Apply user override if available
	if _user_mask:
		for y in range(_mask_resolution):
			for x in range(_mask_resolution):
				var current := _shore_image.get_pixel(x, y).r
				var user_value := _user_mask.get_pixel(x, y).r
				_shore_image.set_pixel(x, y, Color(current * user_value, 0, 0, 1))

	# Create texture from image
	_shore_mask = ImageTexture.create_from_image(_shore_image)

	var elapsed := (Time.get_ticks_msec() - start_time) / 1000.0
	Log.info("water", "ShoreMaskGenerator: Shore distance map generated in %.2fs, bounds: (%.0f, %.0f) to (%.0f, %.0f)" % [
		elapsed,
		_world_bounds.position.x, _world_bounds.position.y,
		_world_bounds.end.x, _world_bounds.end.y
	])


## JFA pass with given step size (8-connected)
func _jfa_pass(step: int, binary_mask: PackedByteArray) -> void:
	var offsets: Array[Vector2i] = [
		Vector2i(-step, -step), Vector2i(0, -step), Vector2i(step, -step),
		Vector2i(-step, 0),                          Vector2i(step, 0),
		Vector2i(-step, step),  Vector2i(0, step),  Vector2i(step, step)
	]

	var new_seeds := _seeds.duplicate()

	for y in range(_mask_resolution):
		for x in range(_mask_resolution):
			var idx := y * _mask_resolution + x
			if binary_mask[idx] == 0:
				continue

			var best_seed := _seeds[idx]
			var best_dist_sq := _distance_squared_to_seed(x, y, best_seed)

			for offset in offsets:
				var nx := x + offset.x
				var ny := y + offset.y
				if nx < 0 or nx >= _mask_resolution or ny < 0 or ny >= _mask_resolution:
					continue

				var neighbor_seed := _seeds[ny * _mask_resolution + nx]
				if neighbor_seed < 0:
					continue

				var dist_sq := _distance_squared_to_seed(x, y, neighbor_seed)
				if dist_sq < best_dist_sq:
					best_dist_sq = dist_sq
					best_seed = neighbor_seed

			new_seeds[idx] = best_seed

	_seeds = new_seeds


func _distance_squared_to_seed(x: int, y: int, seed_idx: int) -> float:
	if seed_idx < 0:
		return INF
	var seed_x := seed_idx % _mask_resolution
	var seed_y := seed_idx / _mask_resolution
	var dx := float(x - seed_x)
	var dy := float(y - seed_y)
	return dx * dx + dy * dy


func _calculate_world_bounds() -> void:
	if not _terrain or not _terrain.data:
		_world_bounds = Rect2(-8000, -8000, 16000, 16000)
		Log.debug("water", "ShoreMaskGenerator: Using default world bounds (no terrain data)")
		return

	var region_count := _terrain.data.get_region_count()
	if region_count == 0:
		_world_bounds = Rect2(-8000, -8000, 16000, 16000)
		Log.debug("water", "ShoreMaskGenerator: Using default world bounds (no regions)")
		return

	# Calculate bounds from terrain regions
	var region_size: float = _terrain.get_region_size() * _terrain.get_vertex_spacing()
	var region_locations: Array[Vector2i] = _terrain.data.get_region_locations()

	if region_locations.is_empty():
		_world_bounds = Rect2(-8000, -8000, 16000, 16000)
		Log.debug("water", "ShoreMaskGenerator: Using default world bounds (no region locations)")
		return

	var min_loc := region_locations[0]
	var max_loc := region_locations[0]
	for loc in region_locations:
		min_loc.x = mini(min_loc.x, loc.x)
		min_loc.y = mini(min_loc.y, loc.y)
		max_loc.x = maxi(max_loc.x, loc.x)
		max_loc.y = maxi(max_loc.y, loc.y)

	var world_min := Vector2(min_loc.x, min_loc.y) * region_size
	var world_max := Vector2(max_loc.x + 1, max_loc.y + 1) * region_size

	_world_bounds = Rect2(
		world_min.x,
		world_min.y,
		world_max.x - world_min.x,
		world_max.y - world_min.y
	)

	# No padding — terrain data outside loaded regions returns 0.0 (sea level)
	# which gets classified as land, creating a false gap. The shader returns
	# shore_factor=1.0 for positions outside mask bounds, so the ocean is seamless.
	var padding := 0.0
	_world_bounds = Rect2(
		_world_bounds.position.x - padding,
		_world_bounds.position.y - padding,
		_world_bounds.size.x + padding * 2,
		_world_bounds.size.y + padding * 2
	)

	Log.debug("water", "ShoreMaskGenerator: Calculated world bounds from %d regions: %s" % [region_count, _world_bounds])


func _get_terrain_height(world_pos: Vector3) -> float:
	if _terrain and _terrain.data:
		return CS.get_terrain_height(world_pos, _terrain)
	# Outside terrain = assume ocean
	return _sea_level - 1.0


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


func _smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t := clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Get shore factor at world position (0 = at shore/land, 1 = deep ocean)
func get_shore_factor(world_pos: Vector3) -> float:
	if not _shore_image:
		# Fallback: check terrain height directly
		if _terrain and _terrain.data:
			var height := CS.get_terrain_height(world_pos, _terrain)
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
		Log.info("water", "ShoreMaskGenerator: Loaded user mask: %s" % path)
		return true

	return false


## Export the shore mask for manual editing
func export_mask(path: String) -> bool:
	if not _shore_image:
		push_warning("[ShoreMaskGenerator] No shore mask to export")
		return false

	var error := _shore_image.save_png(path)
	if error == OK:
		Log.info("water", "ShoreMaskGenerator: Exported shore mask to: %s" % path)
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
		generate_from_terrain(_terrain, _mask_resolution, fade_distance, _sea_level)
