## MorrowindDataProvider - WorldDataProvider implementation for Morrowind ESM data
##
## Wraps the existing ESMManager and TerrainManager to provide terrain data
## through the unified WorldDataProvider interface.
##
## Uses combined regions (4x4 MW cells per Terrain3D region) for large world support.
##
## Terrain texturing:
## ------------------
## Morrowind terrain textures are owned by MorrowindTerrainTextureBridge.
## Terrain3D's built-in control map is kept valid for flags/defaults, but it is
## not used as the production MW texture-selection path because it only exposes
## 32 texture slots.
class_name MorrowindDataProvider
extends "res://src/core/world/world_data_provider.gd"

const TerrainManagerScript := preload("res://src/core/world/terrain_manager.gd")
const TerrainTextureLoaderScript := preload("res://src/core/world/terrain_texture_loader.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const DU := preload("res://src/core/world/distance_utils.gd")

## Internal terrain manager for heightmap generation
var _terrain_manager: RefCounted = null

## Texture loader for terrain textures
var _texture_loader: RefCounted = null

## Terrain3D assets (for texture slot mapping)
var _terrain_assets: Terrain3DAssets = null

## Optional MW Terrain3D sidecar texture bridge
var _terrain_texture_bridge: RefCounted = null

## Cells per Terrain3D region (4x4 = 16 cells per region)
const CELLS_PER_REGION: int = 4

## Morrowind texture grid size per cell
const MW_TEXTURE_SIZE: int = 16

## Height vertices per cell (including shared edge)
const MW_LAND_SIZE: int = 65

## Cropped cell size in pixels (without shared edge)
const CELL_SIZE_PX: int = 64


func _init() -> void:
	world_name = "Morrowind"
	# Morrowind cell = 8192 MW units = ~117m in Godot
	cell_size = CS.CELL_SIZE_GODOT
	# Each MW cell is 64 vertices (cropped from 65)
	# 4 cells × 64 = 256 pixels per region
	region_size = 256
	# vertex_spacing = cell_size / 64 vertices ≈ 1.83m
	vertex_spacing = cell_size / 64.0
	# Morrowind sea level is 0
	sea_level = 0.0


func initialize() -> Error:
	# Check ESMManager is loaded
	if ESMManager.lands.is_empty():
		push_warning("MorrowindDataProvider: ESMManager has no LAND data")
		return ERR_DOES_NOT_EXIST

	# Create terrain manager
	_terrain_manager = TerrainManagerScript.new()
	_terrain_manager.set("region_size", region_size)

	# Create texture loader
	_texture_loader = TerrainTextureLoaderScript.new()

	# Calculate world bounds from LAND records
	_calculate_world_bounds()

	Log.info("streaming", "MorrowindDataProvider initialized: %d LAND records" % ESMManager.lands.size())
	return OK


## Set Terrain3D assets for texture slot mapping
func set_terrain_assets(assets: Terrain3DAssets) -> void:
	_terrain_assets = assets
	if assets:
		Log.info("streaming", "MorrowindDataProvider: Terrain3D assets configured; MW terrain textures use sidecar Texture2DArray")


func set_terrain_texture_bridge(bridge: RefCounted) -> void:
	_terrain_texture_bridge = bridge


func on_terrain_region_imported(region_coord: Vector2i, t3d_loc: Vector2i) -> void:
	if _terrain_texture_bridge and _terrain_texture_bridge.has_method("on_terrain_region_imported"):
		_terrain_texture_bridge.call("on_terrain_region_imported", region_coord, t3d_loc)


func on_terrain_region_unloading(region_coord: Vector2i, t3d_loc: Vector2i) -> void:
	if _terrain_texture_bridge and _terrain_texture_bridge.has_method("on_terrain_region_unloading"):
		_terrain_texture_bridge.call("on_terrain_region_unloading", region_coord, t3d_loc)


## Map types for unified generation
enum MapType { HEIGHT, CONTROL, COLOR }


func get_heightmap_for_region(region_coord: Vector2i) -> Image:
	return _get_combined_map(region_coord, MapType.HEIGHT)


func get_controlmap_for_region(region_coord: Vector2i) -> Image:
	return _get_combined_map(region_coord, MapType.CONTROL)


func get_colormap_for_region(region_coord: Vector2i) -> Image:
	return _get_combined_map(region_coord, MapType.COLOR)


## Unified map generation for heightmap, controlmap, and colormap
## Eliminates code duplication across the three map types
func _get_combined_map(region_coord: Vector2i, map_type: MapType) -> Image:
	if not _terrain_manager:
		return null

	const CELL_SIZE_PX := 64
	var region_size_px: int = CELLS_PER_REGION * CELL_SIZE_PX

	# Create combined image with appropriate format and fill
	var combined: Image
	match map_type:
		MapType.HEIGHT:
			combined = Image.create(region_size_px, region_size_px, false, Image.FORMAT_RF)
			# Fill with ocean floor depth so areas without data appear as deep ocean
			combined.fill(Color(CS.OCEAN_FLOOR_GODOT, 0, 0, 1))
		MapType.CONTROL:
			combined = Image.create(region_size_px, region_size_px, false, Image.FORMAT_RF)
			var default_control := _encode_control_value(0, 0, 0)
			combined.fill(Color(default_control, 0, 0, 1))
		MapType.COLOR:
			combined = Image.create(region_size_px, region_size_px, false, Image.FORMAT_RGB8)
			combined.fill(Color.WHITE)

	var sw_cell := _region_to_sw_cell(region_coord)
	var any_data := false

	for local_y in range(CELLS_PER_REGION):
		for local_x in range(CELLS_PER_REGION):
			var cell_x := sw_cell.x + local_x
			var cell_y := sw_cell.y + local_y

			var land: LandRecord = ESMManager.get_land(cell_x, cell_y)
			if not land:
				continue

			# Check data availability based on map type
			match map_type:
				MapType.HEIGHT:
					if not land.has_heights():
						continue
				MapType.COLOR:
					if not land.has_colors():
						continue
				# CONTROL doesn't require specific data check

			any_data = true

			# Generate cell map using appropriate method
			var cell_map: Image
			match map_type:
				MapType.HEIGHT:
					cell_map = _terrain_manager.call("generate_heightmap", land)
				MapType.CONTROL:
					cell_map = _terrain_manager.call("generate_control_map", land)
				MapType.COLOR:
					cell_map = _terrain_manager.call("generate_color_map", land)

			# Calculate offset in combined image
			# Y is flipped: local_y=0 (south) goes to bottom of image
			var img_x := local_x * CELL_SIZE_PX
			var img_y := (CELLS_PER_REGION - 1 - local_y) * CELL_SIZE_PX

			# Blit 64x64 (crop the shared edge)
			combined.blit_rect(cell_map, Rect2i(0, 0, CELL_SIZE_PX, CELL_SIZE_PX), Vector2i(img_x, img_y))

	# Return combined map even if no LAND data exists
	# The map is pre-filled with ocean floor depth / default values
	# This ensures ocean areas render at correct depth instead of height 0
	return combined


## Generate region-level control map with cross-cell texture blending
##
## This implements OpenMW-style blending where texture samples are taken
## from neighboring cells at boundaries, eliminating the chessboard effect.
##
## The key insight is that MW's texture grid (16x16 per cell) must be sampled
## continuously across cell boundaries, not per-cell in isolation.
func _generate_region_controlmap_with_blending(region_coord: Vector2i) -> Image:
	var region_size_px: int = CELLS_PER_REGION * CELL_SIZE_PX  # 256

	# Create control map image
	var controlmap := Image.create(region_size_px, region_size_px, false, Image.FORMAT_RF)
	var default_control := _encode_control_value(0, 0, 0)
	controlmap.fill(Color(default_control, 0, 0, 1))

	var sw_cell := _region_to_sw_cell(region_coord)
	var any_data := false

	# Pre-cache LAND records for this region + 1-cell border for neighbor sampling
	# This matches OpenMW's LandCache approach: startCellX - 1, startCellY - 1, +2 buffer
	var land_cache: Dictionary[Vector2i, LandRecord] = {}
	for cache_y in range(-1, CELLS_PER_REGION + 1):
		for cache_x in range(-1, CELLS_PER_REGION + 1):
			var cell_coord := Vector2i(sw_cell.x + cache_x, sw_cell.y + cache_y)
			var land: LandRecord = ESMManager.get_land(cell_coord.x, cell_coord.y)
			if land:
				land_cache[cell_coord] = land
				if cache_x >= 0 and cache_x < CELLS_PER_REGION and cache_y >= 0 and cache_y < CELLS_PER_REGION:
					if land.has_textures():
						any_data = true

	# If no texture data exists, return the default-filled control map
	# This ensures ocean regions still get valid control data
	if not any_data:
		return controlmap

	# Vertices per texture cell (~4.0)
	var vertices_per_tex := float(MW_LAND_SIZE - 1) / float(MW_TEXTURE_SIZE)

	# Generate control map with cross-cell blending
	# Iterate through each pixel in the combined region image
	for local_y in range(CELLS_PER_REGION):
		for local_x in range(CELLS_PER_REGION):
			var cell_coord := Vector2i(sw_cell.x + local_x, sw_cell.y + local_y)

			# Calculate image offset for this cell
			# Y is flipped: local_y=0 (south) goes to bottom of image
			var img_offset_x := local_x * CELL_SIZE_PX
			var img_offset_y := (CELLS_PER_REGION - 1 - local_y) * CELL_SIZE_PX

			# Generate control values for each pixel in this cell
			for py in range(CELL_SIZE_PX):
				for px in range(CELL_SIZE_PX):
					# Calculate continuous position in MW texture space
					# This extends across cell boundaries for proper blending
					var tex_x_f := (float(px) / vertices_per_tex) - 0.5
					var tex_y_f := (float(CELL_SIZE_PX - 1 - py) / vertices_per_tex) - 0.5  # Flip Y

					# Sample 4 corners with cross-cell awareness
					var control := _sample_texture_bilinear(
						cell_coord, tex_x_f, tex_y_f, land_cache
					)

					controlmap.set_pixel(
						img_offset_x + px,
						img_offset_y + py,
						Color(control, 0, 0, 1)
					)

	return controlmap


## Sample texture index with bilinear interpolation, crossing cell boundaries
##
## tex_x_f, tex_y_f: Continuous position in texture space (0-16 range, can be negative)
## Returns: Encoded control value with base, overlay, and blend
func _sample_texture_bilinear(
	cell_coord: Vector2i,
	tex_x_f: float,
	tex_y_f: float,
	land_cache: Dictionary[Vector2i, LandRecord]
) -> float:
	# Get the 4 surrounding texture cells for bilinear interpolation
	var tx0 := int(floorf(tex_x_f))
	var ty0 := int(floorf(tex_y_f))
	var tx1 := tx0 + 1
	var ty1 := ty0 + 1

	# Bilinear weights
	var fx := tex_x_f - float(tx0)
	var fy := tex_y_f - float(ty0)
	fx = clampf(fx, 0.0, 1.0)
	fy = clampf(fy, 0.0, 1.0)

	# Get texture slots for all 4 corners (with cross-cell sampling)
	var slot_00 := _get_texture_slot_at(cell_coord, tx0, ty0, land_cache)
	var slot_10 := _get_texture_slot_at(cell_coord, tx1, ty0, land_cache)
	var slot_01 := _get_texture_slot_at(cell_coord, tx0, ty1, land_cache)
	var slot_11 := _get_texture_slot_at(cell_coord, tx1, ty1, land_cache)

	# Calculate bilinear weights for each corner
	var w00 := (1.0 - fx) * (1.0 - fy)
	var w10 := fx * (1.0 - fy)
	var w01 := (1.0 - fx) * fy
	var w11 := fx * fy

	# Find dominant texture (highest weight) as base
	var weights := [w00, w10, w01, w11]
	var slots := [slot_00, slot_10, slot_01, slot_11]

	var max_weight := 0.0
	var base_slot := slot_00
	for i in 4:
		if weights[i] > max_weight:
			max_weight = weights[i]
			base_slot = slots[i]

	# Find best overlay texture (highest weight among different textures)
	var overlay_slot := base_slot
	var overlay_weight := 0.0
	for i in 4:
		if slots[i] != base_slot and weights[i] > overlay_weight:
			overlay_weight = weights[i]
			overlay_slot = slots[i]

	# Calculate blend value
	var blend := 0
	if overlay_slot != base_slot:
		# Total weight of non-base textures
		var total_other_weight := 0.0
		for i in 4:
			if slots[i] != base_slot:
				total_other_weight += weights[i]
		blend = int(clampf(total_other_weight, 0.0, 1.0) * 255.0)

	return _encode_control_value(base_slot, overlay_slot, blend)


## Get texture slot at a position that may cross cell boundaries
##
## cell_coord: The base cell we're processing
## tx, ty: Texture coordinates that may be outside 0-15 range
## land_cache: Pre-cached LAND records including neighbors
func _get_texture_slot_at(
	cell_coord: Vector2i,
	tx: int,
	ty: int,
	land_cache: Dictionary[Vector2i, LandRecord]
) -> int:
	# Determine which cell this texture coordinate belongs to
	var actual_cell := cell_coord
	var actual_tx := tx
	var actual_ty := ty

	# Handle crossing into neighboring cells
	if tx < 0:
		actual_cell.x -= 1
		actual_tx = MW_TEXTURE_SIZE + tx  # tx is negative, so this wraps correctly
	elif tx >= MW_TEXTURE_SIZE:
		actual_cell.x += 1
		actual_tx = tx - MW_TEXTURE_SIZE

	if ty < 0:
		actual_cell.y -= 1
		actual_ty = MW_TEXTURE_SIZE + ty
	elif ty >= MW_TEXTURE_SIZE:
		actual_cell.y += 1
		actual_ty = ty - MW_TEXTURE_SIZE

	# Clamp to valid range after cell adjustment
	actual_tx = clampi(actual_tx, 0, MW_TEXTURE_SIZE - 1)
	actual_ty = clampi(actual_ty, 0, MW_TEXTURE_SIZE - 1)

	# Get LAND record from cache
	if actual_cell not in land_cache:
		return 0  # Default texture for missing cells

	var land: LandRecord = land_cache[actual_cell]
	if not land.has_textures():
		return 0  # Default texture

	# Get MW texture index and convert to Terrain3D slot
	var mw_tex_idx := land.get_texture_index(actual_tx, actual_ty)
	return _get_terrain3d_slot(mw_tex_idx)


## Get Terrain3D texture slot for MW texture index
func _get_terrain3d_slot(mw_tex_idx: int) -> int:
	if mw_tex_idx == 0:
		return 0
	if _texture_loader and _texture_loader.has_method("get_slot_for_mw_index"):
		return _texture_loader.call("get_slot_for_mw_index", mw_tex_idx)
	# Fallback: modulo mapping
	return ((mw_tex_idx - 1) % 31) + 1


func has_terrain_at_region(region_coord: Vector2i) -> bool:
	# Check if region is within extended world bounds (includes ocean buffer)
	# This ensures ocean floor terrain is generated beyond LAND data boundaries
	if not _is_region_in_extended_bounds(region_coord):
		return false

	# Always return true for regions within bounds - we'll generate ocean floor
	# for areas without LAND data
	return true


## Check if region is within extended world bounds
## Adds an ocean buffer around the actual LAND data for seamless ocean rendering
func _is_region_in_extended_bounds(region_coord: Vector2i) -> bool:
	# Ocean buffer in regions (each region = 4 cells × 117m ≈ 468m)
	# 3 regions = ~1.4km of ocean around the island
	const OCEAN_BUFFER_REGIONS: int = 3

	# Calculate region bounds from world bounds
	var region_world_size := float(region_size) * vertex_spacing
	var min_region_x := floori(world_bounds.position.x / region_world_size) - OCEAN_BUFFER_REGIONS
	var max_region_x := ceili(world_bounds.end.x / region_world_size) + OCEAN_BUFFER_REGIONS
	var min_region_y := floori(world_bounds.position.y / region_world_size) - OCEAN_BUFFER_REGIONS
	var max_region_y := ceili(world_bounds.end.y / region_world_size) + OCEAN_BUFFER_REGIONS

	return (region_coord.x >= min_region_x and region_coord.x <= max_region_x and
			region_coord.y >= min_region_y and region_coord.y <= max_region_y)


## Check if region has actual LAND data (not just ocean)
func _region_has_land_data(region_coord: Vector2i) -> bool:
	var sw_cell := _region_to_sw_cell(region_coord)

	for local_y in range(CELLS_PER_REGION):
		for local_x in range(CELLS_PER_REGION):
			var cell_x := sw_cell.x + local_x
			var cell_y := sw_cell.y + local_y
			var land: LandRecord = ESMManager.get_land(cell_x, cell_y)
			if land and land.has_heights():
				return true

	return false


func get_height_at_position(world_pos: Vector3) -> float:
	# Convert Godot position to MW cell coordinates
	var cell_x := floori(world_pos.x / cell_size)
	var cell_y := floori(-world_pos.z / cell_size)

	var land: LandRecord = ESMManager.get_land(cell_x, cell_y)
	if not land or not land.has_heights():
		return NAN

	# Calculate position within cell (0-1)
	var local_x := fmod(world_pos.x, cell_size) / cell_size
	var local_y := fmod(-world_pos.z, cell_size) / cell_size
	if local_x < 0:
		local_x += 1.0
	if local_y < 0:
		local_y += 1.0

	# Convert to vertex indices (0-64)
	var vx := int(local_x * 64.0)
	var vy := int(local_y * 64.0)
	vx = clampi(vx, 0, 64)
	vy = clampi(vy, 0, 64)

	# Get height and convert from MW units
	var mw_height := land.get_height(vx, vy)
	return mw_height / CS.UNITS_PER_METER


func get_all_terrain_regions() -> Array[Vector2i]:
	var regions: Array[Vector2i] = []
	var seen: Dictionary[Vector2i, bool] = {}

	for key: String in ESMManager.lands:
		var land: LandRecord = ESMManager.lands[key]
		if land and land.has_heights():
			var region := _cell_to_region(Vector2i(land.cell_x, land.cell_y))
			if region not in seen:
				seen[region] = true
				regions.append(region)

	return regions


## Convert cell coordinate to region coordinate
func _cell_to_region(cell_coord: Vector2i) -> Vector2i:
	var region_x := floori(float(cell_coord.x) / float(CELLS_PER_REGION))
	var region_y := floori(float(cell_coord.y) / float(CELLS_PER_REGION))
	return Vector2i(region_x, region_y)


## Get SW corner cell of a region
func _region_to_sw_cell(region_coord: Vector2i) -> Vector2i:
	return Vector2i(region_coord.x * CELLS_PER_REGION, region_coord.y * CELLS_PER_REGION)


## Calculate world bounds from LAND records
func _calculate_world_bounds() -> void:
	var min_x := 999999
	var max_x := -999999
	var min_y := 999999
	var max_y := -999999

	for key: String in ESMManager.lands:
		var land: LandRecord = ESMManager.lands[key]
		if land:
			min_x = mini(min_x, land.cell_x)
			max_x = maxi(max_x, land.cell_x)
			min_y = mini(min_y, land.cell_y)
			max_y = maxi(max_y, land.cell_y)

	# Convert to world units
	var west := float(min_x) * cell_size
	var east := float(max_x + 1) * cell_size
	var south := float(min_y) * cell_size
	var north := float(max_y + 1) * cell_size

	world_bounds = Rect2(west, south, east - west, north - south)
	Log.info("streaming", "MorrowindDataProvider: World bounds = %.1f x %.1f km" % [
		world_bounds.size.x / 1000.0, world_bounds.size.y / 1000.0
	])


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


#region Distant Rendering Configuration


## Get tier unit counts optimized for Morrowind's small 117m cells
func get_tier_unit_counts() -> Dictionary:
	# Morrowind cells are small (117m), so we can have more per tier
	# These limits prevent queue overflow while providing good view distance
	return {
		TierUtils.Tier.NEAR: 50,      # ~585m radius (full 3D geometry)
		TierUtils.Tier.MID: 100,      # ~1170m radius (pre-merged meshes)
		TierUtils.Tier.HLOD: 150,     # ~1755m radius (chunk proxies)
		TierUtils.Tier.FAR: 200,      # ~2340m radius (impostors)
		TierUtils.Tier.HIDDEN: 0,     # Skybox only (no per-cell processing)
	}


## Morrowind max view distance (foggy volcanic island aesthetic)
func get_max_view_distance() -> float:
	return DU.FAR_END


## Distant rendering support
func supports_distant_rendering() -> bool:
	# Always enable distant rendering - LOD system works without pre-baked impostors
	# MID tier uses embedded LODs from NIFConverter, FAR tier uses impostors if available
	return true


## Get impostor candidates for Morrowind landmarks
func get_impostor_candidates() -> Array[String]:
	# Major landmarks that should be visible from distance
	return [
		# Vivec cantons (massive)
		"meshes\\x\\ex_vivec_canton_00.nif",
		"meshes\\x\\ex_vivec_canton_01.nif",
		"meshes\\x\\ex_vivec_canton_02.nif",
		"meshes\\x\\ex_vivec_plaza_01.nif",

		# Strongholds
		"meshes\\x\\ex_stronghold_01.nif",
		"meshes\\x\\ex_stronghold_02.nif",
		"meshes\\x\\ex_hlaalu_b_21.nif",  # Hlaalu manor
		"meshes\\x\\ex_redoran_b_21.nif",  # Redoran manor

		# Telvanni towers
		"meshes\\x\\ex_t_tower_01.nif",
		"meshes\\x\\ex_t_tower_02.nif",
		"meshes\\x\\ex_t_tower_03.nif",

		# Dwemer ruins
		"meshes\\x\\ex_dwrv_ruin00.nif",
		"meshes\\x\\ex_dwrv_ruin01.nif",
		"meshes\\x\\ex_dwrv_tower00.nif",

		# Ghostfence
		"meshes\\x\\ex_ghostfence_01.nif",
		"meshes\\x\\ex_ghostfence_02.nif",

		# Daedric shrines
		"meshes\\x\\ex_dae_shrine_01.nif",
		"meshes\\x\\ex_dae_shrine_02.nif",

		# Large trees (for forest visibility)
		"meshes\\f\\flora_tree_02.nif",
		"meshes\\f\\flora_tree_03.nif",
		"meshes\\f\\flora_tree_04.nif",
		"meshes\\f\\flora_tree_06.nif",

		# Red Mountain features
		"meshes\\x\\ex_redmtn_plant_01.nif",
		"meshes\\x\\ex_redmtn_rock_01.nif",
	]


## Get horizon layer for Vvardenfell silhouette
func get_horizon_layer_path() -> String:
	return "res://assets/horizons/vvardenfell_horizon.png"


## Morrowind uses standard 117m cells
func get_cell_size_meters() -> float:
	return CS.CELL_SIZE_GODOT


## Override tier distances for foggy Morrowind atmosphere
func get_tier_distances() -> Dictionary:
	# Reduce FAR tier slightly due to volcanic fog
	return {
		TierUtils.Tier.FAR: 4000.0,  # 4km instead of default 5km
	}


#endregion
