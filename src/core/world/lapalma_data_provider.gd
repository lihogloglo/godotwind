## LaPalmaDataProvider - WorldDataProvider implementation for La Palma island
##
## Loads preprocessed heightmap data from raw binary files created by
## tools/preprocess_lapalma.py
##
## Data format:
##   lapalma_processed/
##     metadata.json       # World configuration and region list
##     regions/
##       region_X_Y.raw    # 1024x1024 float32 heightmaps (region_size from metadata)
class_name LaPalmaDataProvider
extends "res://src/core/world/world_data_provider.gd"

## Path to preprocessed data directory
var data_path: String = "res://lapalma_processed"

## Metadata loaded from JSON
var _metadata: Dictionary = {}

## Cached region info: Vector2i -> Dictionary
var _region_info: Dictionary = {}

## Cached heightmaps: Vector2i -> Image (LRU cache)
var _heightmap_cache: Dictionary = {}
var _cache_order: Array[Vector2i] = []
var _max_cache_size: int = 32


func _init(path: String = "res://lapalma_processed") -> void:
	data_path = path
	world_name = "La Palma"


func initialize() -> Error:
	# Load metadata
	var meta_path := data_path.path_join("metadata.json")

	if not FileAccess.file_exists(meta_path):
		push_error("LaPalmaDataProvider: metadata.json not found at %s" % meta_path)
		push_error("Run 'python3 tools/preprocess_lapalma.py' to generate heightmap data")
		return ERR_FILE_NOT_FOUND

	var file := FileAccess.open(meta_path, FileAccess.READ)
	if not file:
		push_error("LaPalmaDataProvider: Failed to open %s" % meta_path)
		return ERR_CANT_OPEN

	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	file.close()

	if err != OK:
		push_error("LaPalmaDataProvider: Failed to parse metadata.json: %s" % json.get_error_message())
		return ERR_PARSE_ERROR

	_metadata = json.data

	# Apply configuration from metadata
	world_name = _metadata.get("world_name", "La Palma")
	vertex_spacing = _metadata.get("vertex_spacing", 6.0)
	region_size = _metadata.get("region_size", 256)
	sea_level = _metadata.get("sea_level", 0.0)

	# Calculate cell_size (one region = one cell for La Palma)
	cell_size = float(region_size) * vertex_spacing

	# Build world bounds
	var width_m: float = _metadata.get("world_width_m", 0.0)
	var height_m: float = _metadata.get("world_height_m", 0.0)
	var num_x: int = _metadata.get("num_regions_x", 1)
	var num_y: int = _metadata.get("num_regions_y", 1)

	# Bounds centered around origin
	var half_w := width_m * 0.5
	var half_h := height_m * 0.5
	world_bounds = Rect2(-half_w, -half_h, width_m, height_m)

	# Build region lookup
	var regions: Array = _metadata.get("regions", [])
	for region_data in regions:
		var coord := Vector2i(int(region_data["x"]), int(region_data["y"]))
		_region_info[coord] = region_data

	print("LaPalmaDataProvider initialized:")
	print("  World: %s" % world_name)
	print("  Size: %.1f x %.1f km" % [width_m / 1000.0, height_m / 1000.0])
	print("  Vertex spacing: %.1fm" % vertex_spacing)
	print("  Regions: %d (of %d x %d grid)" % [_region_info.size(), num_x, num_y])
	print("  Height range: %.1f to %.1f m" % [
		_metadata.get("min_height", 0.0),
		_metadata.get("max_height", 0.0)
	])

	return OK


func get_heightmap_for_region(region_coord: Vector2i) -> Image:
	# Check cache first
	if region_coord in _heightmap_cache:
		# Move to front of LRU
		_cache_order.erase(region_coord)
		_cache_order.push_front(region_coord)
		return _heightmap_cache[region_coord]

	# Check if region exists
	if region_coord not in _region_info:
		return null

	var info: Dictionary = _region_info[region_coord]
	var filename: String = info.get("file", "")
	var filepath := data_path.path_join("regions").path_join(filename)

	# Load raw heightmap
	var file := FileAccess.open(filepath, FileAccess.READ)
	if not file:
		push_warning("LaPalmaDataProvider: Failed to open %s" % filepath)
		return null

	var expected_size := region_size * region_size * 4  # float32
	var data := file.get_buffer(expected_size)
	file.close()

	if data.size() != expected_size:
		push_warning("LaPalmaDataProvider: Invalid file size for %s" % filepath)
		return null

	# Create Image directly from raw float32 data (much faster than pixel-by-pixel)
	var img := Image.create_from_data(region_size, region_size, false, Image.FORMAT_RF, data)

	# Add to cache
	_heightmap_cache[region_coord] = img
	_cache_order.push_front(region_coord)

	# Evict old entries if cache is full
	while _cache_order.size() > _max_cache_size:
		var old_coord: Vector2i = _cache_order.pop_back()
		_heightmap_cache.erase(old_coord)

	return img


func get_controlmap_for_region(region_coord: Vector2i) -> Image:
	# Return null to use default texture (much faster)
	# TODO: Precompute control maps in preprocessing script for height-based texturing
	return null


func get_colormap_for_region(region_coord: Vector2i) -> Image:
	# Generate procedural height-based colors for the terrain
	var heightmap := get_heightmap_for_region(region_coord)
	if not heightmap:
		return null

	var colormap := Image.create(region_size, region_size, false, Image.FORMAT_RGB8)

	# Height color gradient (La Palma: sea level to ~2426m)
	# Sea level: sandy/coastal
	# Low: green vegetation
	# Mid: darker green/brown
	# High: volcanic rock/gray
	# Peak: light gray/snow-like

	for y in range(region_size):
		for x in range(region_size):
			var height: float = heightmap.get_pixel(x, y).r
			var color := _height_to_color(height)
			colormap.set_pixel(x, y, color)

	return colormap


## Convert height to terrain color
func _height_to_color(height: float) -> Color:
	# Height ranges for La Palma (0 to ~2426m)
	if height <= 0:
		# Sea level / beaches - sandy
		return Color(0.76, 0.70, 0.50)
	elif height < 100:
		# Coastal - light green with brown
		var t := height / 100.0
		return Color(0.45, 0.55, 0.35).lerp(Color(0.35, 0.50, 0.25), t)
	elif height < 500:
		# Low vegetation - rich green
		var t := (height - 100) / 400.0
		return Color(0.35, 0.50, 0.25).lerp(Color(0.30, 0.42, 0.22), t)
	elif height < 1200:
		# Mid elevation - pine forest, darker green
		var t := (height - 500) / 700.0
		return Color(0.30, 0.42, 0.22).lerp(Color(0.35, 0.32, 0.25), t)
	elif height < 1800:
		# High elevation - sparse vegetation, brown/gray
		var t := (height - 1200) / 600.0
		return Color(0.35, 0.32, 0.25).lerp(Color(0.45, 0.42, 0.40), t)
	elif height < 2200:
		# Very high - volcanic rock, gray
		var t := (height - 1800) / 400.0
		return Color(0.45, 0.42, 0.40).lerp(Color(0.55, 0.52, 0.50), t)
	else:
		# Peak - light gray (Roque de los Muchachos)
		var t := clampf((height - 2200) / 300.0, 0, 1)
		return Color(0.55, 0.52, 0.50).lerp(Color(0.65, 0.62, 0.60), t)


func has_terrain_at_region(region_coord: Vector2i) -> bool:
	return region_coord in _region_info


func get_height_at_position(world_pos: Vector3) -> float:
	var region := world_pos_to_region(world_pos)

	if not has_terrain_at_region(region):
		return sea_level

	var heightmap := get_heightmap_for_region(region)
	if not heightmap:
		return sea_level

	# Calculate position within region
	var region_world_size := float(region_size) * vertex_spacing
	var region_origin := region_to_world_pos(region)

	# Local position within region (0 to region_world_size)
	var local_x := world_pos.x - (region_origin.x - region_world_size * 0.5)
	var local_z := -(world_pos.z - (region_origin.z + region_world_size * 0.5))

	# Convert to pixel coordinates
	var px := clampi(int(local_x / vertex_spacing), 0, region_size - 1)
	var py := clampi(int(local_z / vertex_spacing), 0, region_size - 1)

	return heightmap.get_pixel(px, py).r


func get_all_terrain_regions() -> Array[Vector2i]:
	var regions: Array[Vector2i] = []
	for coord in _region_info.keys():
		regions.append(coord)
	return regions


## Encode Terrain3D control map value
func _encode_control_value(base_tex: int, overlay_tex: int, blend: int) -> float:
	var value: int = 0
	value |= (base_tex & 0x1F) << 27
	value |= (overlay_tex & 0x1F) << 22
	value |= (blend & 0xFF) << 14

	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, value)
	return bytes.decode_float(0)


## Clear the heightmap cache
func clear_cache() -> void:
	_heightmap_cache.clear()
	_cache_order.clear()


## Get cache statistics
func get_cache_stats() -> Dictionary:
	return {
		"cached_regions": _heightmap_cache.size(),
		"max_cache_size": _max_cache_size,
	}


#region Distant Rendering Configuration


## Get tier unit counts optimized for La Palma's large 1536m regions
func get_tier_unit_counts() -> Dictionary:
	# La Palma regions are HUGE (1536m), so we need far fewer per tier
	# These prevent loading too much data while still providing good coverage
	const DistanceTier := preload("res://src/core/world/distance_tier_manager.gd")
	return {
		DistanceTier.Tier.NEAR: 5,       # ~7.7km radius (5 large regions)
		DistanceTier.Tier.MID: 10,       # ~15.4km radius (simplified)
		DistanceTier.Tier.FAR: 20,       # ~30.8km radius (impostors)
		DistanceTier.Tier.HORIZON: 0,    # Ocean skybox (no per-region processing)
	}


## La Palma max view distance (clear island, can see far)
func get_max_view_distance() -> float:
	return 10000.0  # 10km max view distance (island is ~40km tall)


## Distant rendering support for La Palma
func supports_distant_rendering() -> bool:
	# La Palma doesn't need pre-baked assets (real-world GeoTIFF data)
	# But we still want to check if the system is ready
	return false  # TODO: Enable when distant rendering system is tested


## Get impostor candidates for La Palma landmarks
func get_impostor_candidates() -> Array[String]:
	# Real-world landmarks on La Palma island
	return [
		# Observatories (Roque de los Muchachos)
		"models/observatory_roque.glb",
		"models/observatory_magic.glb",
		"models/observatory_herschel.glb",

		# Lighthouses
		"models/lighthouse_fuencaliente.glb",
		"models/lighthouse_punta_cumplida.glb",

		# Major buildings from OSM data
		"models/building_large_01.glb",
		"models/building_large_02.glb",

		# Volcanic features
		"models/volcano_teneguia.glb",
		"models/volcano_san_juan.glb",

		# Churches/landmarks
		"models/church_las_nieves.glb",
		"models/church_santa_cruz.glb",
	]


## Get horizon layer for La Palma ocean view
func get_horizon_layer_path() -> String:
	return "res://assets/horizons/la_palma_ocean_horizon.png"


## La Palma uses large 1536m regions
func get_cell_size_meters() -> float:
	return cell_size  # 1536m regions


## No tier distance overrides for La Palma (clear weather)
func get_tier_distances() -> Dictionary:
	return {}  # Use defaults


#endregion
