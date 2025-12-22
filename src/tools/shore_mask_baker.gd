## ShoreMaskBaker - Tool for pre-generating shore mask texture from terrain
##
## Generates a shore mask texture based on terrain height relative to sea level.
## The shore mask controls ocean visibility:
## - 1.0 = full ocean (below sea level)
## - 0.0 = no ocean (above sea level + fade distance)
##
## Usage:
##   var baker := ShoreMaskBaker.new()
##   baker.terrain = $Terrain3D
##   baker.bake_shore_mask()  # Saves to default path
##   # OR
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

## Distance above sea level where ocean fades out completely
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

	progress.emit(5.0, "Creating shore mask image...")

	# Create image
	var image := Image.create(resolution, resolution, false, Image.FORMAT_R8)

	var total_pixels := resolution * resolution
	var pixels_done := 0
	var last_progress := 0.0

	progress.emit(10.0, "Sampling terrain heights...")

	# Sample terrain heights
	for y in range(resolution):
		for x in range(resolution):
			var world_pos := _pixel_to_world(x, y)
			var terrain_height := _get_terrain_height(world_pos)

			# Calculate shore factor
			var height_above_sea := terrain_height - sea_level
			var shore_factor: float

			if height_above_sea < 0:
				# Below sea level - full ocean
				shore_factor = 1.0
			elif height_above_sea > fade_distance:
				# Above fade distance - no ocean
				shore_factor = 0.0
			else:
				# Transition zone - smooth fade
				shore_factor = 1.0 - _smoothstep(0.0, fade_distance, height_above_sea)

			image.set_pixel(x, y, Color(shore_factor, 0, 0, 1))

			pixels_done += 1

		# Update progress every row
		var current_progress := 10.0 + (float(pixels_done) / float(total_pixels)) * 80.0
		if current_progress - last_progress >= 5.0:
			progress.emit(current_progress, "Sampling terrain... %d%%" % int((float(y) / float(resolution)) * 100))
			last_progress = current_progress

	progress.emit(90.0, "Saving shore mask...")

	# Determine output path
	var output_path := custom_output_path
	if output_path.is_empty():
		output_path = output_dir.path_join(output_filename)

	# Save as PNG
	var save_err := image.save_png(output_path)
	if save_err != OK:
		var error := "Failed to save image: error %d" % save_err
		push_error("ShoreMaskBaker: %s - %s" % [error, output_path])
		bake_complete.emit(false, "")
		return {"success": false, "output_path": "", "error": error}

	progress.emit(95.0, "Saving metadata...")

	# Save metadata (bounds info)
	_save_metadata(output_path)

	progress.emit(100.0, "Complete!")

	print("ShoreMaskBaker: Saved shore mask to %s" % output_path)
	print("  Resolution: %dx%d" % [resolution, resolution])
	print("  World bounds: (%.0f, %.0f) to (%.0f, %.0f)" % [
		world_bounds.position.x, world_bounds.position.y,
		world_bounds.end.x, world_bounds.end.y
	])
	print("  Sea level: %.1f, Fade distance: %.1f" % [sea_level, fade_distance])

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
	# Terrain3D stores data in regions, we need to find the extent
	var region_count := terrain.data.get_region_count()
	if region_count == 0:
		world_bounds = Rect2(-8000, -8000, 16000, 16000)
		print("ShoreMaskBaker: Using default world bounds (no regions)")
		return

	# Use terrain's AABB if available
	var aabb: AABB = terrain.get_aabb()
	if aabb.size != Vector3.ZERO:
		world_bounds = Rect2(
			aabb.position.x,
			aabb.position.z,
			aabb.size.x,
			aabb.size.z
		)
	else:
		# Fallback to reasonable defaults
		world_bounds = Rect2(-8000, -8000, 16000, 16000)

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
	# Create a simple resource to store metadata
	var config := ConfigFile.new()
	config.set_value("shore_mask", "resolution", resolution)
	config.set_value("shore_mask", "sea_level", sea_level)
	config.set_value("shore_mask", "fade_distance", fade_distance)
	config.set_value("shore_mask", "bounds_x", world_bounds.position.x)
	config.set_value("shore_mask", "bounds_y", world_bounds.position.y)
	config.set_value("shore_mask", "bounds_width", world_bounds.size.x)
	config.set_value("shore_mask", "bounds_height", world_bounds.size.y)

	var cfg_path := image_path.replace(".png", ".cfg")
	config.save(cfg_path)
	print("ShoreMaskBaker: Saved metadata to %s" % cfg_path)


## Load prebaked shore mask from file
## Returns: Dictionary with { texture: ImageTexture, bounds: Rect2 } or null on failure
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
			bounds = Rect2(
				config.get_value("shore_mask", "bounds_x", -8000.0),
				config.get_value("shore_mask", "bounds_y", -8000.0),
				config.get_value("shore_mask", "bounds_width", 16000.0),
				config.get_value("shore_mask", "bounds_height", 16000.0)
			)

	print("ShoreMaskBaker: Loaded prebaked shore mask from %s" % image_path)
	print("  Bounds: %s" % bounds)

	return {
		"texture": texture,
		"bounds": bounds
	}
