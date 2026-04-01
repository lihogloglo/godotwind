## ShoreMaskBaker - Tool for pre-generating shore distance mask from terrain
##
## Generates a shore distance texture using Jump Flooding Algorithm (JFA)
## for efficient Euclidean distance field computation.
##
## Output texture (single channel R8):
## - 0.0 = at shore or on land (full wave dampening)
## - 1.0 = far from shore (full waves, beyond fade_distance)
##
## This is used for wave dampening near coastlines (OpenMW-style approach).
##
## Usage:
##   var baker := ShoreMaskBaker.new()
##   baker.terrain = $Terrain3D
##   await baker.bake_shore_mask()  # Saves to cache/ocean/shore_mask.png
class_name ShoreMaskBaker
extends RefCounted

const CS := preload("res://src/core/coordinate_system.gd")

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

## Internal: seed map for JFA (stores nearest shore pixel coordinates)
## Packed as y * resolution + x, -1 = no seed yet
var _seeds: PackedInt32Array


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

	Log.info("tools", "ShoreMaskBaker: Initialized - output dir: %s" % output_dir)
	return OK


## Bake shore mask and save to file (async version - must be awaited)
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

	progress.emit(5.0, "Classifying terrain (water/land)...")

	# Get scene tree for yielding - CRITICAL for UI responsiveness
	var tree: SceneTree = terrain.get_tree() if terrain else Engine.get_main_loop() as SceneTree
	if not tree:
		push_error("ShoreMaskBaker: No scene tree available for async processing")
		bake_complete.emit(false, "")
		return {"success": false, "output_path": "", "error": "No scene tree"}

	# Step 1: Create binary mask and initialize JFA seeds
	# Shore pixels (water adjacent to land) become seeds with distance 0
	var binary_mask := PackedByteArray()
	binary_mask.resize(resolution * resolution)

	_seeds = PackedInt32Array()
	_seeds.resize(resolution * resolution)
	_seeds.fill(-1)  # -1 = no seed

	# First pass: classify water vs land
	Log.info("tools", "ShoreMaskBaker: Classifying terrain (%dx%d pixels)..." % [resolution, resolution])
	for y in range(resolution):
		for x in range(resolution):
			var world_pos := _pixel_to_world(x, y)
			var terrain_height := _get_terrain_height(world_pos)
			var idx := y * resolution + x

			# 1 = water, 0 = land
			binary_mask[idx] = 1 if terrain_height < sea_level else 0

		# Yield every 64 rows to keep UI responsive
		if y % 64 == 0:
			var pct := 5.0 + (float(y) / float(resolution)) * 10.0
			progress.emit(pct, "Classifying terrain... %d%%" % int((float(y) / float(resolution)) * 100))
			await tree.process_frame

	progress.emit(15.0, "Finding shore pixels...")
	await tree.process_frame

	# Step 2: Find shore pixels (water pixels adjacent to land using 8-connected)
	# These become the seeds for JFA
	var shore_count := 0

	Log.info("tools", "ShoreMaskBaker: Finding shore pixels...")
	for y in range(resolution):
		for x in range(resolution):
			var idx := y * resolution + x
			var is_water := binary_mask[idx] == 1

			if is_water:
				# Check 8-connected neighbors for land
				var adjacent_to_land := false
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if dx == 0 and dy == 0:
							continue
						var nx := x + dx
						var ny := y + dy
						if nx >= 0 and nx < resolution and ny >= 0 and ny < resolution:
							var nidx := ny * resolution + nx
							if binary_mask[nidx] == 0:  # Land
								adjacent_to_land = true
								break
					if adjacent_to_land:
						break

				if adjacent_to_land:
					# This is a shore pixel - seed points to itself (distance 0)
					_seeds[idx] = idx
					shore_count += 1

		# Yield every 128 rows
		if y % 128 == 0:
			var pct := 15.0 + (float(y) / float(resolution)) * 10.0
			progress.emit(pct, "Finding shore pixels... %d%%" % int((float(y) / float(resolution)) * 100))
			await tree.process_frame

	Log.info("tools", "ShoreMaskBaker: Found %d shore pixels" % shore_count)

	if shore_count == 0:
		push_warning("ShoreMaskBaker: No shore pixels found - terrain may be entirely above or below sea level")

	progress.emit(25.0, "Running Jump Flooding Algorithm...")
	await tree.process_frame

	# Step 3: Jump Flooding Algorithm
	# Process in log2(resolution) passes with decreasing step sizes
	var step := resolution / 2
	var pass_num := 0
	var total_passes := int(ceil(log(float(resolution)) / log(2.0)))

	Log.info("tools", "ShoreMaskBaker: Running JFA (%d passes)..." % total_passes)
	while step >= 1:
		await _jfa_pass_async(step, binary_mask, tree)
		pass_num += 1
		var pct := 25.0 + (float(pass_num) / float(total_passes)) * 50.0
		progress.emit(pct, "JFA pass %d/%d (step=%d)..." % [pass_num, total_passes, step])
		Log.debug("tools", "ShoreMaskBaker: JFA pass %d/%d complete (step=%d)" % [pass_num, total_passes, step])
		await tree.process_frame
		step /= 2

	progress.emit(75.0, "Computing shore factor gradient...")
	await tree.process_frame

	# Step 4: Convert distances to shore factor with smoothstep
	var result_image := Image.create(resolution, resolution, false, Image.FORMAT_R8)
	var texel_size := world_bounds.size.x / float(resolution)

	Log.info("tools", "ShoreMaskBaker: Computing gradient...")
	for y in range(resolution):
		for x in range(resolution):
			var idx := y * resolution + x
			var is_water := binary_mask[idx] == 1

			if not is_water:
				# Land = 0 (no ocean rendering here)
				result_image.set_pixel(x, y, Color(0.0, 0, 0, 1))
			else:
				var seed_idx := _seeds[idx]
				var shore_factor: float

				if seed_idx < 0:
					# No shore found - open ocean, full waves
					shore_factor = 1.0
				elif seed_idx == idx:
					# This IS a shore pixel
					shore_factor = 0.0
				else:
					# Calculate Euclidean distance to nearest shore
					var seed_x := seed_idx % resolution
					var seed_y := seed_idx / resolution
					var dx := float(x - seed_x)
					var dy := float(y - seed_y)
					var pixel_distance := sqrt(dx * dx + dy * dy)
					var world_distance := pixel_distance * texel_size

					# Smoothstep from 0 (at shore) to 1 (at fade_distance)
					shore_factor = _smoothstep(0.0, fade_distance, world_distance)

				result_image.set_pixel(x, y, Color(shore_factor, 0, 0, 1))

		# Yield every 64 rows
		if y % 64 == 0:
			var pct := 75.0 + (float(y) / float(resolution)) * 20.0
			progress.emit(pct, "Computing gradient... %d%%" % int((float(y) / float(resolution)) * 100))
			await tree.process_frame

	progress.emit(95.0, "Saving shore mask...")
	await tree.process_frame

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

	# Save metadata (bounds info)
	_save_metadata(output_path)

	progress.emit(100.0, "Complete!")

	Log.info("tools", "ShoreMaskBaker: Saved shore mask to %s" % output_path)
	Log.info("tools", "  Resolution: %dx%d" % [resolution, resolution])
	Log.info("tools", "  World bounds: (%.0f, %.0f) to (%.0f, %.0f)" % [
		world_bounds.position.x, world_bounds.position.y,
		world_bounds.end.x, world_bounds.end.y
	])
	Log.info("tools", "  Sea level: %.1f, Fade distance: %.1fm" % [sea_level, fade_distance])
	Log.info("tools", "  Shore pixels found: %d" % shore_count)

	bake_complete.emit(true, output_path)
	return {
		"success": true,
		"output_path": output_path,
		"error": "",
		"bounds": world_bounds
	}


## Jump Flooding Algorithm - single pass with given step size (async version)
## Checks 8 neighbors at distance 'step' and updates seeds
func _jfa_pass_async(step: int, binary_mask: PackedByteArray, tree: SceneTree) -> void:
	# Neighbor offsets (8-connected at step distance)
	var offsets: Array[Vector2i] = [
		Vector2i(-step, -step), Vector2i(0, -step), Vector2i(step, -step),
		Vector2i(-step, 0),                          Vector2i(step, 0),
		Vector2i(-step, step),  Vector2i(0, step),  Vector2i(step, step)
	]

	# Create copy for reading while writing
	var new_seeds := _seeds.duplicate()

	for y in range(resolution):
		for x in range(resolution):
			var idx := y * resolution + x

			# Only process water pixels
			if binary_mask[idx] == 0:
				continue

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

		# Yield every 128 rows to keep UI responsive
		if y % 128 == 0:
			await tree.process_frame

	_seeds = new_seeds


## Jump Flooding Algorithm - single pass (synchronous, kept for compatibility)
func _jfa_pass(step: int, binary_mask: PackedByteArray) -> void:
	# Neighbor offsets (8-connected at step distance)
	var offsets: Array[Vector2i] = [
		Vector2i(-step, -step), Vector2i(0, -step), Vector2i(step, -step),
		Vector2i(-step, 0),                          Vector2i(step, 0),
		Vector2i(-step, step),  Vector2i(0, step),  Vector2i(step, step)
	]

	# Create copy for reading while writing
	var new_seeds := _seeds.duplicate()

	for y in range(resolution):
		for x in range(resolution):
			var idx := y * resolution + x

			# Only process water pixels
			if binary_mask[idx] == 0:
				continue

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


## Calculate squared Euclidean distance from pixel (x, y) to the pixel at seed_idx
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
		# Default to large bounds
		world_bounds = Rect2(-8000, -8000, 16000, 16000)
		Log.warn("tools", "ShoreMaskBaker: Using default world bounds (no terrain data)")
		return

	# Try to get bounds from terrain data
	var region_count := terrain.data.get_region_count()
	if region_count == 0:
		world_bounds = Rect2(-8000, -8000, 16000, 16000)
		Log.warn("tools", "ShoreMaskBaker: Using default world bounds (no regions)")
		return

	# Calculate bounds from region locations
	var region_size: float = terrain.get_region_size() * terrain.get_vertex_spacing()
	var region_locations: Array[Vector2i] = terrain.data.get_region_locations()

	if region_locations.is_empty():
		world_bounds = Rect2(-8000, -8000, 16000, 16000)
		Log.warn("tools", "ShoreMaskBaker: Using default world bounds (no region locations)")
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

	# No padding — terrain data outside loaded regions returns 0.0 (sea level)
	# which gets classified as land, creating a false gap. The shader returns
	# shore_factor=1.0 for positions outside mask bounds, so the ocean is seamless.
	var padding := 0.0
	world_bounds = Rect2(
		world_bounds.position.x - padding,
		world_bounds.position.y - padding,
		world_bounds.size.x + padding * 2,
		world_bounds.size.y + padding * 2
	)

	Log.info("tools", "ShoreMaskBaker: Calculated world bounds: %s (with %.0fm padding)" % [world_bounds, padding])


## Get terrain height at world position
func _get_terrain_height(world_pos: Vector3) -> float:
	if terrain and terrain.data:
		return CS.get_terrain_height(world_pos, terrain)
	# Outside terrain = assume ocean (below sea level)
	return sea_level - 1.0


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
	config.set_value("shore_mask", "algorithm", "jfa")  # Mark as JFA-based
	config.set_value("shore_mask", "version", 2)

	var cfg_path := image_path.replace(".png", ".cfg")
	config.save(cfg_path)
	Log.debug("tools", "ShoreMaskBaker: Saved metadata to %s" % cfg_path)


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

	# Clear mipmaps if present - ImageTexture.create_from_image() fails with embedded mipmaps
	if image.has_mipmaps():
		image.clear_mipmaps()

	var texture := ImageTexture.create_from_image(image)
	if not texture:
		push_error("ShoreMaskBaker: Failed to create texture from image: %s" % image_path)
		return {}

	# Load metadata
	var cfg_path := image_path.replace(".png", ".cfg")
	var bounds := Rect2(-8000, -8000, 16000, 16000)  # Default
	var fade_dist := 50.0

	if FileAccess.file_exists(cfg_path):
		var config := ConfigFile.new()
		if config.load(cfg_path) == OK:
			var bounds_x: float = config.get_value("shore_mask", "bounds_x", -8000.0)
			var bounds_y: float = config.get_value("shore_mask", "bounds_y", -8000.0)
			var bounds_w: float = config.get_value("shore_mask", "bounds_width", 16000.0)
			var bounds_h: float = config.get_value("shore_mask", "bounds_height", 16000.0)
			bounds = Rect2(bounds_x, bounds_y, bounds_w, bounds_h)
			fade_dist = config.get_value("shore_mask", "fade_distance", 50.0)
			var algorithm: String = config.get_value("shore_mask", "algorithm", "iterative")
			Log.debug("tools", "ShoreMaskBaker: Loaded %s-based shore mask (fade=%.0fm)" % [algorithm, fade_dist])

	Log.info("tools", "ShoreMaskBaker: Loaded prebaked shore mask from %s" % image_path)
	Log.debug("tools", "  Bounds: %s" % bounds)

	return {
		"texture": texture,
		"bounds": bounds,
		"fade_distance": fade_dist
	}
