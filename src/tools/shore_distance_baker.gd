## ShoreDistanceBaker - Generates shore distance map using Jump Flooding Algorithm
##
## Based on OpenMW's shore distance map implementation.
## Uses JFA to efficiently compute approximate Euclidean distance fields.
##
## Output texture:
## - R channel: Normalized distance to shore (0.0 = at shore, 1.0 = far from shore/max distance)
## - G channel: Shore factor for wave dampening (1.0 = ocean, 0.0 = land)
##
## Usage:
##   var baker := ShoreDistanceBaker.new()
##   baker.terrain = $Terrain3D
##   baker.bake()  # Saves to cache/ocean/shore_distance.png
class_name ShoreDistanceBaker
extends RefCounted

## Output directory (set from SettingsManager)
var output_dir: String = ""

## Default output filename
var output_filename: String = "shore_distance.png"

## Map resolution (higher = more detail, larger file)
var resolution: int = 2048

## Sea level height in world units
var sea_level: float = 0.0

## Maximum shore distance in world units (beyond this = 1.0)
## Controls the gradient width from shore to open ocean
var max_shore_distance: float = 500.0

## Shore fade distance above sea level (for wave dampening)
## Much smaller than before - creates crisp shoreline
var shore_fade_distance: float = 5.0

## World bounds to cover (auto-calculated from terrain if not set)
var world_bounds: Rect2 = Rect2()

## Terrain reference
var terrain: Terrain3D = null

## Progress tracking
signal progress(percent: float, message: String)
signal bake_complete(success: bool, output_path: String)

## Internal: seed map for JFA (stores nearest land pixel coordinates)
var _seeds: PackedInt32Array  # Packed as y * resolution + x, -1 = no seed


## Initialize the baker and create output directory
func initialize() -> Error:
	if output_dir.is_empty():
		output_dir = SettingsManager.get_ocean_path()

	var err := SettingsManager.ensure_cache_directories()
	if err != OK:
		push_error("ShoreDistanceBaker: Failed to create cache directories")
		return err

	print("ShoreDistanceBaker: Initialized - output dir: %s" % output_dir)
	return OK


## Bake shore distance map and save to file
## Returns: Dictionary with { success: bool, output_path: String, error: String }
func bake(custom_output_path: String = "") -> Dictionary:
	progress.emit(0.0, "Initializing...")

	if initialize() != OK:
		bake_complete.emit(false, "")
		return {"success": false, "output_path": "", "error": "Failed to create output directory"}

	if not terrain:
		var error := "No terrain set - assign terrain before baking"
		push_error("ShoreDistanceBaker: %s" % error)
		bake_complete.emit(false, "")
		return {"success": false, "output_path": "", "error": error}

	# Calculate world bounds from terrain if not set
	if world_bounds.size == Vector2.ZERO:
		_calculate_world_bounds()

	progress.emit(5.0, "Classifying terrain...")

	# Step 1: Initialize seed map - classify each pixel as land or water
	_seeds = PackedInt32Array()
	_seeds.resize(resolution * resolution)
	_seeds.fill(-1)  # -1 = no seed (water)

	var land_pixels := PackedInt32Array()  # Store land pixel indices for JFA init

	for y in range(resolution):
		for x in range(resolution):
			var world_pos := _pixel_to_world(x, y)
			var terrain_height := _get_terrain_height(world_pos)
			var idx := y * resolution + x

			if terrain_height > sea_level:
				# This is land - it's its own seed
				_seeds[idx] = idx
				land_pixels.append(idx)

		if y % 64 == 0:
			progress.emit(5.0 + (float(y) / float(resolution)) * 20.0, "Classifying terrain... %d%%" % int((float(y) / float(resolution)) * 100))

	print("ShoreDistanceBaker: Found %d land pixels out of %d total" % [land_pixels.size(), resolution * resolution])

	progress.emit(25.0, "Running Jump Flooding Algorithm...")

	# Step 2: Jump Flooding Algorithm
	# Process in log2(resolution) passes with decreasing step sizes
	var step := resolution / 2
	var pass_num := 0
	var total_passes := int(ceil(log(resolution) / log(2)))

	while step >= 1:
		_jfa_pass(step)
		pass_num += 1
		var pct := 25.0 + (float(pass_num) / float(total_passes)) * 50.0
		progress.emit(pct, "JFA pass %d/%d (step=%d)..." % [pass_num, total_passes, step])
		step /= 2

	progress.emit(75.0, "Computing distances...")

	# Step 3: Compute final distance values and create image
	var image := Image.create(resolution, resolution, false, Image.FORMAT_RG8)
	var texel_size := world_bounds.size.x / float(resolution)

	for y in range(resolution):
		for x in range(resolution):
			var idx := y * resolution + x
			var seed_idx := _seeds[idx]

			var distance_normalized: float
			var shore_factor: float

			if seed_idx < 0:
				# No seed found - this shouldn't happen after JFA, treat as far ocean
				distance_normalized = 1.0
				shore_factor = 1.0
			elif seed_idx == idx:
				# This pixel IS land
				distance_normalized = 0.0
				shore_factor = 0.0
			else:
				# Water pixel - compute distance to nearest land
				var seed_x := seed_idx % resolution
				var seed_y := seed_idx / resolution
				var dx := float(x - seed_x)
				var dy := float(y - seed_y)
				var pixel_distance := sqrt(dx * dx + dy * dy)
				var world_distance := pixel_distance * texel_size

				# Normalize distance (0 = at shore, 1 = far from shore)
				distance_normalized = clampf(world_distance / max_shore_distance, 0.0, 1.0)

				# Shore factor for wave dampening
				# Use the terrain height at this water pixel to determine shore proximity
				var world_pos := _pixel_to_world(x, y)
				var terrain_height := _get_terrain_height(world_pos)
				var height_above_sea := terrain_height - sea_level

				if height_above_sea >= shore_fade_distance:
					# Above fade zone - no ocean
					shore_factor = 0.0
				elif height_above_sea > 0.0:
					# In fade zone above sea level
					shore_factor = 1.0 - (height_above_sea / shore_fade_distance)
				else:
					# Below sea level - full ocean, but attenuate slightly near shore
					# Use distance-based attenuation for the first few meters
					var shore_attenuation := smoothstep(0.0, 20.0, world_distance)
					shore_factor = 0.5 + 0.5 * shore_attenuation

			# R = distance normalized, G = shore factor
			image.set_pixel(x, y, Color(distance_normalized, shore_factor, 0.0, 1.0))

		if y % 64 == 0:
			progress.emit(75.0 + (float(y) / float(resolution)) * 20.0, "Computing distances... %d%%" % int((float(y) / float(resolution)) * 100))

	progress.emit(95.0, "Saving shore distance map...")

	# Determine output path
	var output_path := custom_output_path
	if output_path.is_empty():
		output_path = output_dir.path_join(output_filename)

	# Save as PNG
	var save_err := image.save_png(output_path)
	if save_err != OK:
		var error := "Failed to save image: error %d" % save_err
		push_error("ShoreDistanceBaker: %s - %s" % [error, output_path])
		bake_complete.emit(false, "")
		return {"success": false, "output_path": "", "error": error}

	# Save metadata
	_save_metadata(output_path)

	progress.emit(100.0, "Complete!")

	print("ShoreDistanceBaker: Saved shore distance map to %s" % output_path)
	print("  Resolution: %dx%d" % [resolution, resolution])
	print("  World bounds: (%.0f, %.0f) to (%.0f, %.0f)" % [
		world_bounds.position.x, world_bounds.position.y,
		world_bounds.end.x, world_bounds.end.y
	])
	print("  Max shore distance: %.1f, Shore fade: %.1f" % [max_shore_distance, shore_fade_distance])

	bake_complete.emit(true, output_path)
	return {
		"success": true,
		"output_path": output_path,
		"error": "",
		"bounds": world_bounds
	}


## Jump Flooding Algorithm - single pass with given step size
## Checks 8 neighbors at distance 'step' and updates seeds
func _jfa_pass(step: int) -> void:
	# Neighbor offsets (8-connected)
	var offsets := [
		Vector2i(-step, -step), Vector2i(0, -step), Vector2i(step, -step),
		Vector2i(-step, 0),                          Vector2i(step, 0),
		Vector2i(-step, step),  Vector2i(0, step),  Vector2i(step, step)
	]

	# Create copy for reading while writing
	var new_seeds := _seeds.duplicate()

	for y in range(resolution):
		for x in range(resolution):
			var idx := y * resolution + x
			var best_seed := _seeds[idx]
			var best_dist_sq := _distance_squared_to_seed(x, y, best_seed)

			# Check all neighbors at step distance
			for offset in offsets:
				var nx := x + offset.x
				var ny := y + offset.y

				# Bounds check
				if nx < 0 or nx >= resolution or ny < 0 or ny >= resolution:
					continue

				var neighbor_idx := ny * resolution + nx
				var neighbor_seed := _seeds[neighbor_idx]

				if neighbor_seed < 0:
					continue  # Neighbor has no seed

				var dist_sq := _distance_squared_to_seed(x, y, neighbor_seed)
				if dist_sq < best_dist_sq:
					best_dist_sq = dist_sq
					best_seed = neighbor_seed

			new_seeds[idx] = best_seed

	_seeds = new_seeds


## Calculate squared distance from pixel (x, y) to the pixel at seed_idx
func _distance_squared_to_seed(x: int, y: int, seed_idx: int) -> float:
	if seed_idx < 0:
		return INF

	var seed_x := seed_idx % resolution
	var seed_y := seed_idx / resolution
	var dx := float(x - seed_x)
	var dy := float(y - seed_y)
	return dx * dx + dy * dy


## Calculate world bounds from terrain
func _calculate_world_bounds() -> void:
	if not terrain or not terrain.data:
		world_bounds = Rect2(-8000, -8000, 16000, 16000)
		print("ShoreDistanceBaker: Using default world bounds (no terrain data)")
		return

	var region_count := terrain.data.get_region_count()
	if region_count == 0:
		world_bounds = Rect2(-8000, -8000, 16000, 16000)
		print("ShoreDistanceBaker: Using default world bounds (no regions)")
		return

	var region_size: float = terrain.get_region_size() * terrain.get_vertex_spacing()
	var region_locations: Array[Vector2i] = terrain.data.get_region_locations()

	if region_locations.is_empty():
		world_bounds = Rect2(-8000, -8000, 16000, 16000)
		print("ShoreDistanceBaker: Using default world bounds (no region locations)")
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

	world_bounds = Rect2(
		world_min.x,
		world_min.y,
		world_max.x - world_min.x,
		world_max.y - world_min.y
	)

	# Add padding
	var padding := 500.0
	world_bounds = Rect2(
		world_bounds.position.x - padding,
		world_bounds.position.y - padding,
		world_bounds.size.x + padding * 2,
		world_bounds.size.y + padding * 2
	)

	print("ShoreDistanceBaker: Calculated world bounds: %s" % world_bounds)


## Get terrain height at world position
func _get_terrain_height(world_pos: Vector3) -> float:
	if terrain and terrain.data:
		return terrain.data.get_height(world_pos)
	return 0.0


## Convert pixel coordinates to world position
func _pixel_to_world(x: int, y: int) -> Vector3:
	var u := float(x) / float(resolution)
	var v := float(y) / float(resolution)

	return Vector3(
		world_bounds.position.x + u * world_bounds.size.x,
		0.0,
		world_bounds.position.y + v * world_bounds.size.y
	)


## Attempt smooth step interpolation (kept for compatibility)
func smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t := clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Save metadata alongside the image
func _save_metadata(image_path: String) -> void:
	var config := ConfigFile.new()
	config.set_value("shore_distance", "resolution", resolution)
	config.set_value("shore_distance", "sea_level", sea_level)
	config.set_value("shore_distance", "max_shore_distance", max_shore_distance)
	config.set_value("shore_distance", "shore_fade_distance", shore_fade_distance)
	config.set_value("shore_distance", "bounds_x", world_bounds.position.x)
	config.set_value("shore_distance", "bounds_y", world_bounds.position.y)
	config.set_value("shore_distance", "bounds_width", world_bounds.size.x)
	config.set_value("shore_distance", "bounds_height", world_bounds.size.y)
	config.set_value("shore_distance", "version", 2)  # New JFA-based version

	var cfg_path := image_path.replace(".png", ".cfg")
	config.save(cfg_path)
	print("ShoreDistanceBaker: Saved metadata to %s" % cfg_path)


## Load prebaked shore distance map from file
## Returns: Dictionary with { texture: ImageTexture, bounds: Rect2, max_distance: float } or empty on failure
static func load_prebaked(image_path: String) -> Dictionary:
	if not FileAccess.file_exists(image_path):
		push_warning("ShoreDistanceBaker: Prebaked shore distance map not found: %s" % image_path)
		return {}

	var image := Image.load_from_file(image_path)
	if not image:
		push_error("ShoreDistanceBaker: Failed to load shore distance image: %s" % image_path)
		return {}

	var texture := ImageTexture.create_from_image(image)

	# Load metadata
	var cfg_path := image_path.replace(".png", ".cfg")
	var bounds := Rect2(-8000, -8000, 16000, 16000)
	var max_distance := 500.0

	if FileAccess.file_exists(cfg_path):
		var config := ConfigFile.new()
		if config.load(cfg_path) == OK:
			bounds = Rect2(
				config.get_value("shore_distance", "bounds_x", -8000.0),
				config.get_value("shore_distance", "bounds_y", -8000.0),
				config.get_value("shore_distance", "bounds_width", 16000.0),
				config.get_value("shore_distance", "bounds_height", 16000.0)
			)
			max_distance = config.get_value("shore_distance", "max_shore_distance", 500.0)

	print("ShoreDistanceBaker: Loaded prebaked shore distance map from %s" % image_path)
	print("  Bounds: %s, Max distance: %.1f" % [bounds, max_distance])

	return {
		"texture": texture,
		"bounds": bounds,
		"max_distance": max_distance
	}
