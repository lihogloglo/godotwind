## TerrainManager - Converts Morrowind LAND data to Terrain3D format
## Handles heightmap generation, texture splatting, and region management
## Reference: OpenMW components/terrain/ and components/esmterrain/storage.cpp
class_name TerrainManager
extends RefCounted

# Preload coordinate utilities
const MWCoords := preload("res://src/core/morrowind_coords.gd")

# Morrowind terrain constants
const MW_CELL_SIZE: float = 8192.0     # Cell size in Morrowind units
const MW_LAND_SIZE: int = 65           # Vertices per cell side
const MW_TEXTURE_SIZE: int = 16        # Texture tiles per cell side

# Terrain3D region size (should match Terrain3D settings)
# Default Terrain3D region = 256m, we'll use 1 MW cell = 1 region for simplicity
var region_size: int = 256

# Height scale for converting MW heights to Godot
# MW heights are in game units, typically ranging from -2000 to +8000
# Godot/Terrain3D expects meters, and we use our standard conversion
var height_scale: float = 1.0 / 70.0  # Same as MWCoords

# Statistics
var _stats: Dictionary = {
	"regions_created": 0,
	"heightmaps_generated": 0,
	"control_maps_generated": 0,
}

# Cached texture mapping: LTEX index -> texture slot in Terrain3D
var _texture_map: Dictionary = {}


## Generate a heightmap Image from a single LAND record
## Returns: Image in FORMAT_RF (32-bit float per pixel)
func generate_heightmap(land: LandRecord) -> Image:
	if not land.has_heights():
		push_warning("TerrainManager: LAND record %d,%d has no height data" % [land.cell_x, land.cell_y])
		return _create_flat_heightmap()

	# Create 65x65 heightmap image (FORMAT_RF = 32-bit float)
	var img := Image.create(MW_LAND_SIZE, MW_LAND_SIZE, false, Image.FORMAT_RF)

	for y in range(MW_LAND_SIZE):
		for x in range(MW_LAND_SIZE):
			# Get height in Morrowind units and convert to Godot scale
			var mw_height := land.get_height(x, y)
			var godot_height := mw_height * height_scale

			# Store as single float in red channel (FORMAT_RF)
			img.set_pixel(x, y, Color(godot_height, 0, 0, 1))

	_stats["heightmaps_generated"] += 1
	return img


## Generate a combined heightmap for multiple cells (NxN grid)
## cell_coords: Array of Vector2i cell coordinates
## Returns: Combined heightmap Image
func generate_combined_heightmap(cell_coords: Array[Vector2i]) -> Image:
	if cell_coords.is_empty():
		return _create_flat_heightmap()

	# Find bounds
	var min_x := cell_coords[0].x
	var max_x := cell_coords[0].x
	var min_y := cell_coords[0].y
	var max_y := cell_coords[0].y

	for coord in cell_coords:
		min_x = mini(min_x, coord.x)
		max_x = maxi(max_x, coord.x)
		min_y = mini(min_y, coord.y)
		max_y = maxi(max_y, coord.y)

	var grid_width := max_x - min_x + 1
	var grid_height := max_y - min_y + 1

	# Calculate combined image size
	# Each cell is 65 vertices, but adjacent cells share edge vertices
	# So NxM cells = (N*64+1) x (M*64+1) pixels
	var img_width := grid_width * 64 + 1
	var img_height := grid_height * 64 + 1

	var combined := Image.create(img_width, img_height, false, Image.FORMAT_RF)

	# Fill with zero height initially
	combined.fill(Color(0, 0, 0, 1))

	# Copy each cell's heightmap into the combined image
	for coord in cell_coords:
		var land: LandRecord = ESMManager.get_land(coord.x, coord.y)
		if not land or not land.has_heights():
			continue

		# Calculate position in combined image
		var offset_x := (coord.x - min_x) * 64
		var offset_y := (coord.y - min_y) * 64

		for y in range(MW_LAND_SIZE):
			for x in range(MW_LAND_SIZE):
				var mw_height := land.get_height(x, y)
				var godot_height := mw_height * height_scale
				combined.set_pixel(offset_x + x, offset_y + y, Color(godot_height, 0, 0, 1))

	_stats["heightmaps_generated"] += 1
	return combined


## Generate a color map from LAND vertex colors
## Returns: Image in FORMAT_RGB8
func generate_color_map(land: LandRecord) -> Image:
	var img := Image.create(MW_LAND_SIZE, MW_LAND_SIZE, false, Image.FORMAT_RGB8)

	if not land.has_colors():
		# Fill with white if no colors
		img.fill(Color.WHITE)
		return img

	for y in range(MW_LAND_SIZE):
		for x in range(MW_LAND_SIZE):
			var color := land.get_color(x, y)
			img.set_pixel(x, y, color)

	return img


## Generate a control map for Terrain3D from LAND texture indices
## This creates a simple control map mapping MW textures to Terrain3D texture slots
## Returns: Image in FORMAT_RF (Terrain3D control map format)
##
## Note: Terrain3D control maps use a packed uint32 format:
## - Base texture ID (5 bits)
## - Overlay texture ID (5 bits)
## - Blend value (8 bits)
## - etc.
## For simplicity, we only set the base texture with no blending.
func generate_control_map(land: LandRecord) -> Image:
	# Terrain3D expects control map at same resolution as heightmap
	# MW texture grid is 16x16, so we need to upscale
	var img := Image.create(MW_LAND_SIZE, MW_LAND_SIZE, false, Image.FORMAT_RF)

	if not land.has_textures():
		# Fill with default texture (index 0)
		var default_control := _encode_control_value(0, 0, 0)
		img.fill(Color(default_control, 0, 0, 1))
		_stats["control_maps_generated"] += 1
		return img

	# Map each height vertex to its corresponding texture cell
	# 65 vertices map to 16 texture cells, so ~4 vertices per texture
	for y in range(MW_LAND_SIZE):
		for x in range(MW_LAND_SIZE):
			# Convert vertex position to texture grid position
			var tex_x := mini(x * MW_TEXTURE_SIZE / MW_LAND_SIZE, MW_TEXTURE_SIZE - 1)
			var tex_y := mini(y * MW_TEXTURE_SIZE / MW_LAND_SIZE, MW_TEXTURE_SIZE - 1)

			var mw_tex_idx := land.get_texture_index(tex_x, tex_y)

			# Convert MW texture index to Terrain3D slot
			var terrain3d_slot := _get_terrain3d_texture_slot(mw_tex_idx)

			# Encode control value (base texture only, no blend)
			var control := _encode_control_value(terrain3d_slot, 0, 0)
			img.set_pixel(x, y, Color(control, 0, 0, 1))

	_stats["control_maps_generated"] += 1
	return img


## Encode a Terrain3D control map value
## base_tex: Base texture slot (0-31)
## overlay_tex: Overlay texture slot (0-31)
## blend: Blend amount (0-255)
## Returns: Float representation of packed uint32
func _encode_control_value(base_tex: int, overlay_tex: int, blend: int) -> float:
	# Terrain3D control map format (32-bit):
	# Bits 0-4: Base texture ID
	# Bits 5-9: Overlay texture ID
	# Bits 10-17: Blend value
	# Bits 18-21: UV angle
	# Bits 22-24: UV scale
	# Bit 25: Hole flag
	# Bit 26: Navigation flag
	# Bit 27: Autoshader flag

	var value: int = 0
	value |= (base_tex & 0x1F)           # 5 bits for base
	value |= (overlay_tex & 0x1F) << 5   # 5 bits for overlay
	value |= (blend & 0xFF) << 10        # 8 bits for blend

	# Convert to float for storage in FORMAT_RF image
	# We need to reinterpret the bits, not convert numerically
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, value)
	return bytes.decode_float(0)


## Get the Terrain3D texture slot for a Morrowind texture index
## MW texture index 0 = default texture
## MW texture index N > 0 = LTEX record with index N-1
func _get_terrain3d_texture_slot(mw_tex_idx: int) -> int:
	if mw_tex_idx == 0:
		return 0  # Default texture

	# Check cache
	if mw_tex_idx in _texture_map:
		return _texture_map[mw_tex_idx]

	# Look up the LTEX record
	# MW stores texture_index in LTEX, and VTEX stores texture_index + 1
	var ltex_index := mw_tex_idx - 1

	# For now, just use a simple mapping
	# In a full implementation, we'd need to:
	# 1. Look up the LTEX record by index
	# 2. Get the texture path
	# 3. Map it to a Terrain3D texture slot
	# 4. Load the texture into Terrain3D's texture array

	# Simple modulo mapping for now (Terrain3D supports 32 textures)
	var slot := (ltex_index % 31) + 1  # Slot 0 is default, 1-31 are LTEX
	_texture_map[mw_tex_idx] = slot
	return slot


## Create a flat heightmap (all zeros)
func _create_flat_heightmap() -> Image:
	var img := Image.create(MW_LAND_SIZE, MW_LAND_SIZE, false, Image.FORMAT_RF)
	img.fill(Color(0, 0, 0, 1))
	return img


## Get cells in a radius around a center cell
## Returns array of Vector2i cell coordinates
static func get_cells_in_radius(center_x: int, center_y: int, radius: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for y in range(center_y - radius, center_y + radius + 1):
		for x in range(center_x - radius, center_x + radius + 1):
			cells.append(Vector2i(x, y))
	return cells


## Convert Morrowind world position to cell coordinates
static func world_to_cell(world_pos: Vector3) -> Vector2i:
	# MW world position (x, y are horizontal, z is up)
	# Cell grid: each cell is 8192 units
	var cell_x := int(floor(world_pos.x / MW_CELL_SIZE))
	var cell_y := int(floor(world_pos.y / MW_CELL_SIZE))
	return Vector2i(cell_x, cell_y)


## Convert cell coordinates to Morrowind world position (center of cell)
static func cell_to_world(cell_x: int, cell_y: int) -> Vector3:
	return Vector3(
		(cell_x + 0.5) * MW_CELL_SIZE,
		(cell_y + 0.5) * MW_CELL_SIZE,
		0.0
	)


## Get statistics
func get_stats() -> Dictionary:
	return _stats.duplicate()


## Clear cached data
func clear_cache() -> void:
	_texture_map.clear()
	_stats = {
		"regions_created": 0,
		"heightmaps_generated": 0,
		"control_maps_generated": 0,
	}
