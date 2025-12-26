## MorrowindDataProvider - WorldDataProvider implementation for Morrowind ESM data
##
## Wraps the existing ESMManager and TerrainManager to provide terrain data
## through the unified WorldDataProvider interface.
##
## Uses combined regions (4x4 MW cells per Terrain3D region) for large world support.
class_name MorrowindDataProvider
extends "res://src/core/world/world_data_provider.gd"

const TerrainManagerScript := preload("res://src/core/world/terrain_manager.gd")
const TerrainTextureLoaderScript := preload("res://src/core/world/terrain_texture_loader.gd")
const CS := preload("res://src/core/coordinate_system.gd")

## Internal terrain manager for heightmap generation
var _terrain_manager: RefCounted = null

## Texture loader for terrain textures
var _texture_loader: RefCounted = null

## Terrain3D assets (for texture slot mapping)
var _terrain_assets: Terrain3DAssets = null

## Cells per Terrain3D region (4x4 = 16 cells per region)
const CELLS_PER_REGION: int = 4


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

	print("MorrowindDataProvider initialized: %d LAND records" % ESMManager.lands.size())
	return OK


## Set Terrain3D assets for texture slot mapping
func set_terrain_assets(assets: Terrain3DAssets) -> void:
	_terrain_assets = assets
	if _texture_loader and assets:
		var loaded: int = _texture_loader.call("load_terrain_textures", assets)
		print("MorrowindDataProvider: Loaded %d terrain textures" % loaded)
		if _terrain_manager:
			_terrain_manager.call("set_texture_slot_mapper", _texture_loader)


func get_heightmap_for_region(region_coord: Vector2i) -> Image:
	if not _terrain_manager:
		return null

	# Combined region size (4x4 cells = 256 pixels)
	const CELL_SIZE_PX := 64
	var region_size_px: int = CELLS_PER_REGION * CELL_SIZE_PX

	# Create combined heightmap
	var combined := Image.create(region_size_px, region_size_px, false, Image.FORMAT_RF)
	combined.fill(Color(0, 0, 0, 1))  # Flat default

	# Get SW corner cell of this region
	var sw_cell := _region_to_sw_cell(region_coord)
	var any_data := false

	# Fill in each cell
	for local_y in range(CELLS_PER_REGION):
		for local_x in range(CELLS_PER_REGION):
			var cell_x := sw_cell.x + local_x
			var cell_y := sw_cell.y + local_y

			var land: LandRecord = ESMManager.get_land(cell_x, cell_y)
			if not land or not land.has_heights():
				continue

			any_data = true

			# Generate 65x65 heightmap
			var cell_hm: Image = _terrain_manager.call("generate_heightmap", land)

			# Calculate offset in combined image
			# Y is flipped: local_y=0 (south) goes to bottom of image
			var img_x := local_x * CELL_SIZE_PX
			var img_y := (CELLS_PER_REGION - 1 - local_y) * CELL_SIZE_PX

			# Blit 64x64 (crop the shared edge)
			combined.blit_rect(cell_hm, Rect2i(0, 0, CELL_SIZE_PX, CELL_SIZE_PX), Vector2i(img_x, img_y))

	return combined if any_data else null


func get_controlmap_for_region(region_coord: Vector2i) -> Image:
	if not _terrain_manager:
		return null

	const CELL_SIZE_PX := 64
	var region_size_px: int = CELLS_PER_REGION * CELL_SIZE_PX

	# Default control value (texture slot 0)
	var default_control := _encode_control_value(0, 0, 0)
	var combined := Image.create(region_size_px, region_size_px, false, Image.FORMAT_RF)
	combined.fill(Color(default_control, 0, 0, 1))

	var sw_cell := _region_to_sw_cell(region_coord)
	var any_data := false

	for local_y in range(CELLS_PER_REGION):
		for local_x in range(CELLS_PER_REGION):
			var cell_x := sw_cell.x + local_x
			var cell_y := sw_cell.y + local_y

			var land: LandRecord = ESMManager.get_land(cell_x, cell_y)
			if not land:
				continue

			any_data = true
			var cell_cm: Image = _terrain_manager.call("generate_control_map", land)

			var img_x := local_x * CELL_SIZE_PX
			var img_y := (CELLS_PER_REGION - 1 - local_y) * CELL_SIZE_PX

			combined.blit_rect(cell_cm, Rect2i(0, 0, CELL_SIZE_PX, CELL_SIZE_PX), Vector2i(img_x, img_y))

	return combined if any_data else null


func get_colormap_for_region(region_coord: Vector2i) -> Image:
	if not _terrain_manager:
		return null

	const CELL_SIZE_PX := 64
	var region_size_px: int = CELLS_PER_REGION * CELL_SIZE_PX

	var combined := Image.create(region_size_px, region_size_px, false, Image.FORMAT_RGB8)
	combined.fill(Color.WHITE)

	var sw_cell := _region_to_sw_cell(region_coord)
	var any_data := false

	for local_y in range(CELLS_PER_REGION):
		for local_x in range(CELLS_PER_REGION):
			var cell_x := sw_cell.x + local_x
			var cell_y := sw_cell.y + local_y

			var land: LandRecord = ESMManager.get_land(cell_x, cell_y)
			if not land or not land.has_colors():
				continue

			any_data = true
			var cell_colm: Image = _terrain_manager.call("generate_color_map", land)

			var img_x := local_x * CELL_SIZE_PX
			var img_y := (CELLS_PER_REGION - 1 - local_y) * CELL_SIZE_PX

			combined.blit_rect(cell_colm, Rect2i(0, 0, CELL_SIZE_PX, CELL_SIZE_PX), Vector2i(img_x, img_y))

	return combined if any_data else null


func has_terrain_at_region(region_coord: Vector2i) -> bool:
	var sw_cell := _region_to_sw_cell(region_coord)

	# Check if any cell in this region has terrain
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
	var seen: Dictionary = {}

	for key: Variant in ESMManager.lands:
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

	for key: Variant in ESMManager.lands:
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
	print("MorrowindDataProvider: World bounds = %.1f x %.1f km" % [
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
	const DistanceTier := preload("res://src/core/world/distance_tier_manager.gd")
	return {
		DistanceTier.Tier.NEAR: 50,      # ~585m radius (full 3D geometry)
		DistanceTier.Tier.MID: 100,      # ~1170m radius (pre-merged meshes)
		DistanceTier.Tier.FAR: 200,      # ~2340m radius (impostors)
		DistanceTier.Tier.HORIZON: 0,    # Skybox only (no per-cell processing)
	}


## Morrowind max view distance (foggy volcanic island aesthetic)
func get_max_view_distance() -> float:
	return 5000.0  # 5km max view distance


## Distant rendering support (requires pre-baked assets)
func supports_distant_rendering() -> bool:
	# Check if pre-baked assets exist in cache directory
	var has_impostors := DirAccess.dir_exists_absolute(SettingsManager.get_impostors_path())
	var has_merged := DirAccess.dir_exists_absolute(SettingsManager.get_merged_cells_path())

	# Only enable if assets are ready (or return true to force enable for testing)
	# For now, return false until preprocessing is complete
	return false  # TODO: Enable after running MorrowindPreprocessor


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
	const DistanceTier := preload("res://src/core/world/distance_tier_manager.gd")
	return {
		DistanceTier.Tier.FAR: 4000.0,  # 4km instead of default 5km
	}


#endregion
