## ShoreMaskBaker - Tool for pre-generating shore distance mask from terrain
##
## Generates a shore distance texture where each pixel stores the distance to the nearest shoreline:
## - 0.0 = at shore or on land (full wave dampening)
## - 1.0 = far from shore (full waves, beyond fade_distance)
##
## This is used for wave dampening near coastlines (OpenMW-style approach).
##
## Usage:
##   var baker := ShoreMaskBaker.new()
##   baker.terrain = $Terrain3D
##   baker.bake_shore_mask()  # Saves to cache/ocean/shore_mask.png
class_name ShoreMaskBaker
extends RefCounted

## Output directory for shore mask (set in initialize from SettingsManager)
var output_dir: String = ""

## Default output filename
var output_filename: String = "shore_mask.png"

## Mask resolution (higher = more detail, larger file)
var resolution: int = 2048

## Sea level height in world units
var sea_level: float = 0.0

## Horizontal distance from shore where waves fully return (in meters)
## Smaller values = smaller calm zone, larger = waves calm further out
var fade_distance: float = 50.0

## World bounds to cover (auto-calculated from terrain if not set)
var world_bounds: Rect2 = Rect2()

## Terrain reference
var terrain: Terrain3D = null

## Progress tracking
signal progress(percent: float, message: String)
signal bake_complete(success: bool, output_path: String)


## Initialize the baker and create output directory
func initialize() -> Error:
	# Get output directory from settings manager
	if output_dir.is_empty():
		output_dir = SettingsManager.get_ocean_path()

	# Ensure cache directories exist
	var err := SettingsManager.ensure_cache_directories()
	if err != OK:
		push_error("ShoreMaskBaker: Failed to create cache directories")
		return err

	print("ShoreMaskBaker: Initialized - output dir: %s" % output_dir)
	return OK


## Bake shore mask and save to file
## Returns: Dictionary with { success: bool, output_path: String, error: String }
func bake_shore_mask(custom_output_path: String = "") -> Dictionary:
	progress.emit(0.0, "Initializing...")

	if initialize() != OK:
		bake_complete.emit(false, "")
		return {"success": false, "output_path": "", "error": "Failed to create output directory"}

	if not terrain:
		var error := "No terrain set - assign terrain before baking"
		push_error("ShoreMaskBaker: %s" % error)
		bake_complete.emit(false, "")
		return {"success": false, "output_path": "", "error": error}

	# Calculate world bounds from terrain if not set
	if world_bounds.size == Vector2.ZERO:
		_calculate_world_bounds()

	progress.emit(5.0, "Creating binary water/land mask...")

	# Step 1: Create binary mask (1 = water, 0 = land)
	var binary_mask := Image.create(resolution, resolution, false, Image.FORMAT_R8)

	for y in range(resolution):
		for x in range(resolution):
			var world_pos := _pixel_to_world(x, y)
			var terrain_height := _get_terrain_height(world_pos)

			# Water = below sea level, Land = above sea level
			var is_water := terrain_height < sea_level
			binary_mask.set_pixel(x, y, Color(1.0 if is_water else 0.0, 0, 0, 1))

		if y % 100 == 0:
			progress.emit(5.0 + (float(y) / float(resolution)) * 15.0, "Creating binary mask... %d%%" % int((float(y) / float(resolution)) * 100))

	progress.emit(20.0, "Finding shore pixels...")

	# Step 2: Find shore pixels (water pixels adjacent to land)
	var shore_pixels: Array[Vector2i] = []

	for y in range(resolution):
		for x in range(resolution):
			var is_water := binary_mask.get_pixel(x, y).r > 0.5
			if is_water:
				# Check if adjacent to land (4-connected)
				var adjacent_to_land := false
				for offset: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
					var nx: int = x + offset.x
					var ny: int = y + offset.y
					if nx >= 0 and nx < resolution and ny >= 0 and ny < resolution:
						if binary_mask.get_pixel(nx, ny).r < 0.5:
							adjacent_to_land = true
							break
				if adjacent_to_land:
					shore_pixels.append(Vector2i(x, y))

	print("ShoreMaskBaker: Found %d shore pixels" % shore_pixels.size())
	progress.emit(30.0, "Computing distance field...")

	# Step 3: Compute distance transform using iterative flood fill
	var meters_per_pixel := world_bounds.size.x / float(resolution)
	var fade_pixels := fade_distance / meters_per_pixel

	# Create distance image (float format for precision)
	var distance_image := Image.create(resolution, resolution, false, Image.FORMAT_RF)

	# Initialize: water pixels get large distance, land pixels get 0
	for y in range(resolution):
		for x in range(resolution):
			var is_water := binary_mask.get_pixel(x, y).r > 0.5
			if is_water:
				distance_image.set_pixel(x, y, Color(999999.0, 0, 0, 1))
			else:
				# Land = 0 distance (will be masked out anyway)
				distance_image.set_pixel(x, y, Color(0.0, 0, 0, 1))

	# Set shore pixels to 0 distance
	for shore_px in shore_pixels:
		distance_image.set_pixel(shore_px.x, shore_px.y, Color(0.0, 0, 0, 1))

	progress.emit(40.0, "Propagating distances...")

	# Propagate distances using iterative approach
	var max_iterations := int(fade_pixels * 1.5) + 10
	for iteration in range(max_iterations):
		var changed := false
		for y in range(resolution):
			for x in range(resolution):
				var current_dist := distance_image.get_pixel(x, y).r
				if current_dist <= 0.0:
					continue  # Already at shore or land

				# Check neighbors
				var best_dist := current_dist
				for offset: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
					var nx: int = x + offset.x
					var ny: int = y + offset.y
					if nx >= 0 and nx < resolution and ny >= 0 and ny < resolution:
						var neighbor_dist := distance_image.get_pixel(nx, ny).r + 1.0
						if neighbor_dist < best_dist:
							best_dist = neighbor_dist
							changed = true

				if best_dist < current_dist:
					distance_image.set_pixel(x, y, Color(best_dist, 0, 0, 1))

		if not changed:
			print("ShoreMaskBaker: Distance propagation converged at iteration %d" % iteration)
			break

		if iteration % 10 == 0:
			progress.emit(40.0 + (float(iteration) / float(max_iterations)) * 40.0, "Propagating distances... iteration %d" % iteration)

	progress.emit(80.0, "Converting to shore factor...")

	# Step 4: Convert to shore factor: 0 = at shore, 1 = far from shore
	var result_image := Image.create(resolution, resolution, false, Image.FORMAT_R8)

	for y in range(resolution):
		for x in range(resolution):
			var is_water := binary_mask.get_pixel(x, y).r > 0.5
			if not is_water:
				# Land = 0 (no ocean)
				result_image.set_pixel(x, y, Color(0.0, 0, 0, 1))
			else:
				var dist_pixels := distance_image.get_pixel(x, y).r
				var dist_meters := dist_pixels * meters_per_pixel
				# Smoothstep from 0 (at shore) to 1 (at fade_distance)
				var shore_factor := _smoothstep(0.0, fade_distance, dist_meters)
				result_image.set_pixel(x, y, Color(shore_factor, 0, 0, 1))

	progress.emit(90.0, "Saving shore mask...")

	# Determine output path
	var output_path := custom_output_path
	if output_path.is_empty():
		output_path = output_dir.path_join(output_filename)

	# Save as PNG
	var save_err := result_image.save_png(output_path)
	if save_err != OK:
		var error := "Failed to save image: error %d" % save_err
		push_error("ShoreMaskBaker: %s - %s" % [error, output_path])
		bake_complete.emit(false, "")
		return {"success": false, "output_path": "", "error": error}

	progress.emit(95.0, "Saving metadata...")

	# Save metadata (bounds info)
	_save_metadata(output_path)

	progress.emit(100.0, "Complete!")

	print("ShoreMaskBaker: Saved shore distance mask to %s" % output_path)
	print("  Resolution: %dx%d" % [resolution, resolution])
	print("  World bounds: (%.0f, %.0f) to (%.0f, %.0f)" % [
		world_bounds.position.x, world_bounds.position.y,
		world_bounds.end.x, world_bounds.end.y
	])
	print("  Sea level: %.1f, Fade distance: %.1fm" % [sea_level, fade_distance])
	print("  Shore pixels found: %d" % shore_pixels.size())

	bake_complete.emit(true, output_path)
	return {
		"success": true,
		"output_path": output_path,
		"error": "",
		"bounds": world_bounds
	}


## Calculate world bounds from terrain
func _calculate_world_bounds() -> void:
	if not terrain or not terrain.data:
		# Default to large bounds
		world_bounds = Rect2(-8000, -8000, 16000, 16000)
		print("ShoreMaskBaker: Using default world bounds (no terrain data)")
		return

	# Try to get bounds from terrain data
	var region_count := terrain.data.get_region_count()
	if region_count == 0:
		world_bounds = Rect2(-8000, -8000, 16000, 16000)
		print("ShoreMaskBaker: Using default world bounds (no regions)")
		return

	# Calculate bounds from region locations
	var region_size: float = terrain.get_region_size() * terrain.get_vertex_spacing()
	var region_locations: Array[Vector2i] = terrain.data.get_region_locations()

	if region_locations.is_empty():
		world_bounds = Rect2(-8000, -8000, 16000, 16000)
		print("ShoreMaskBaker: Using default world bounds (no region locations)")
		return

	# Find min/max region coordinates
	var min_loc := region_locations[0]
	var max_loc := region_locations[0]
	for loc in region_locations:
		min_loc.x = mini(min_loc.x, loc.x)
		min_loc.y = mini(min_loc.y, loc.y)
		max_loc.x = maxi(max_loc.x, loc.x)
		max_loc.y = maxi(max_loc.y, loc.y)

	# Convert region coordinates to world bounds
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

	print("ShoreMaskBaker: Calculated world bounds: %s" % world_bounds)


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


## Smoothstep interpolation
func _smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t := clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Save metadata alongside the image
func _save_metadata(image_path: String) -> void:
	var config := ConfigFile.new()
	config.set_value("shore_mask", "resolution", resolution)
	config.set_value("shore_mask", "sea_level", sea_level)
	config.set_value("shore_mask", "fade_distance", fade_distance)
	config.set_value("shore_mask", "bounds_x", world_bounds.position.x)
	config.set_value("shore_mask", "bounds_y", world_bounds.position.y)
	config.set_value("shore_mask", "bounds_width", world_bounds.size.x)
	config.set_value("shore_mask", "bounds_height", world_bounds.size.y)
	config.set_value("shore_mask", "type", "distance")  # Mark as distance-based

	var cfg_path := image_path.replace(".png", ".cfg")
	config.save(cfg_path)
	print("ShoreMaskBaker: Saved metadata to %s" % cfg_path)


## Load prebaked shore mask from file
## Returns: Dictionary with { texture: ImageTexture, bounds: Rect2 } or empty on failure
static func load_prebaked(image_path: String) -> Dictionary:
	if not FileAccess.file_exists(image_path):
		push_warning("ShoreMaskBaker: Prebaked shore mask not found: %s" % image_path)
		return {}

	# Load image
	var image := Image.load_from_file(image_path)
	if not image:
		push_error("ShoreMaskBaker: Failed to load shore mask image: %s" % image_path)
		return {}

	var texture := ImageTexture.create_from_image(image)

	# Load metadata
	var cfg_path := image_path.replace(".png", ".cfg")
	var bounds := Rect2(-8000, -8000, 16000, 16000)  # Default

	if FileAccess.file_exists(cfg_path):
		var config := ConfigFile.new()
		if config.load(cfg_path) == OK:
			var bounds_x: float = config.get_value("shore_mask", "bounds_x", -8000.0)
			var bounds_y: float = config.get_value("shore_mask", "bounds_y", -8000.0)
			var bounds_w: float = config.get_value("shore_mask", "bounds_width", 16000.0)
			var bounds_h: float = config.get_value("shore_mask", "bounds_height", 16000.0)
			bounds = Rect2(bounds_x, bounds_y, bounds_w, bounds_h)
			var mask_type: String = config.get_value("shore_mask", "type", "height")
			print("ShoreMaskBaker: Loaded %s-based shore mask" % mask_type)

	print("ShoreMaskBaker: Loaded prebaked shore mask from %s" % image_path)
	print("  Bounds: %s" % bounds)

	return {
		"texture": texture,
		"bounds": bounds
	}
