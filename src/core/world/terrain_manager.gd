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

# External texture slot mapper (TerrainTextureLoader)
var _texture_slot_mapper: RefCounted = null


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
## This creates a control map with texture blending at boundaries
## Returns: Image in FORMAT_RF (Terrain3D control map format)
##
## Note: Terrain3D control maps use a packed uint32 format:
## - Base texture ID (5 bits)
## - Overlay texture ID (5 bits)
## - Blend value (8 bits)
## - etc.
##
## We implement smooth blending between adjacent texture cells:
## - At the center of a texture cell, blend = 0 (100% base texture)
## - Near texture cell boundaries, blend increases toward neighboring texture
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

	# Each MW texture cell covers ~4 height vertices
	# We blend at the boundaries between texture cells
	var vertices_per_tex := float(MW_LAND_SIZE - 1) / float(MW_TEXTURE_SIZE)  # ~4.0

	for y in range(MW_LAND_SIZE):
		for x in range(MW_LAND_SIZE):
			# Calculate fractional position within texture grid
			var tex_x_f := float(x) / vertices_per_tex
			var tex_y_f := float(y) / vertices_per_tex

			# Integer texture cell coordinates
			var tex_x := mini(int(tex_x_f), MW_TEXTURE_SIZE - 1)
			var tex_y := mini(int(tex_y_f), MW_TEXTURE_SIZE - 1)

			# Get base texture
			var mw_tex_idx := land.get_texture_index(tex_x, tex_y)
			var base_slot := _get_terrain3d_texture_slot(mw_tex_idx)

			# Calculate blend with neighboring textures
			var frac_x := tex_x_f - float(tex_x)  # 0.0-1.0 within cell
			var frac_y := tex_y_f - float(tex_y)

			var overlay_slot := base_slot
			var blend := 0

			# Determine which neighbor to blend with based on position in cell
			# Blend zone is the outer 40% of each cell edge
			var blend_threshold := 0.3
			var blend_strength := 0.0

			# Check if we're near an edge and should blend
			if frac_x > (1.0 - blend_threshold) and tex_x < MW_TEXTURE_SIZE - 1:
				# Near right edge - blend with right neighbor
				var neighbor_idx := land.get_texture_index(tex_x + 1, tex_y)
				var neighbor_slot := _get_terrain3d_texture_slot(neighbor_idx)
				if neighbor_slot != base_slot:
					overlay_slot = neighbor_slot
					blend_strength = (frac_x - (1.0 - blend_threshold)) / blend_threshold
			elif frac_x < blend_threshold and tex_x > 0:
				# Near left edge - blend with left neighbor
				var neighbor_idx := land.get_texture_index(tex_x - 1, tex_y)
				var neighbor_slot := _get_terrain3d_texture_slot(neighbor_idx)
				if neighbor_slot != base_slot:
					overlay_slot = neighbor_slot
					blend_strength = (blend_threshold - frac_x) / blend_threshold

			# Y-axis blending (combine with X if applicable)
			if frac_y > (1.0 - blend_threshold) and tex_y < MW_TEXTURE_SIZE - 1:
				var neighbor_idx := land.get_texture_index(tex_x, tex_y + 1)
				var neighbor_slot := _get_terrain3d_texture_slot(neighbor_idx)
				if neighbor_slot != base_slot:
					var y_blend := (frac_y - (1.0 - blend_threshold)) / blend_threshold
					if y_blend > blend_strength:
						overlay_slot = neighbor_slot
						blend_strength = y_blend
			elif frac_y < blend_threshold and tex_y > 0:
				var neighbor_idx := land.get_texture_index(tex_x, tex_y - 1)
				var neighbor_slot := _get_terrain3d_texture_slot(neighbor_idx)
				if neighbor_slot != base_slot:
					var y_blend := (blend_threshold - frac_y) / blend_threshold
					if y_blend > blend_strength:
						overlay_slot = neighbor_slot
						blend_strength = y_blend

			# Convert blend strength (0-1) to 8-bit value (0-255)
			blend = int(blend_strength * 255.0)

			var control := _encode_control_value(base_slot, overlay_slot, blend)
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


## Set the texture slot mapper (TerrainTextureLoader instance)
## This allows proper mapping of MW texture indices to Terrain3D slots
func set_texture_slot_mapper(mapper: RefCounted) -> void:
	_texture_slot_mapper = mapper


## Get the Terrain3D texture slot for a Morrowind texture index
## MW texture index 0 = default texture
## MW texture index N > 0 = LTEX record with index N-1
func _get_terrain3d_texture_slot(mw_tex_idx: int) -> int:
	if mw_tex_idx == 0:
		return 0  # Default texture

	# Use external mapper if available (proper texture loading)
	if _texture_slot_mapper and _texture_slot_mapper.has_method("get_slot_for_mw_index"):
		return _texture_slot_mapper.get_slot_for_mw_index(mw_tex_idx)

	# Check cache for fallback mapping
	if mw_tex_idx in _texture_map:
		return _texture_map[mw_tex_idx]

	# Fallback: simple modulo mapping (Terrain3D supports 32 textures)
	# This is used when no texture loader is configured
	var ltex_index := mw_tex_idx - 1
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


## Stitch adjacent cell heights at shared edges
## This ensures seamless terrain between cells
## call_order: Array of LandRecords in row-major order for a grid
## grid_width: Number of cells wide
## Returns: True if stitching was applied
func stitch_cell_edges(lands: Array, grid_width: int) -> bool:
	if lands.size() < 2:
		return false

	var grid_height := lands.size() / grid_width
	var stitched := false

	for i in range(lands.size()):
		var land: LandRecord = lands[i]
		if not land or not land.has_heights():
			continue

		var gx := i % grid_width
		var gy := i / grid_width

		# Stitch right edge with left edge of neighbor to the right
		if gx < grid_width - 1:
			var right_idx := i + 1
			if right_idx < lands.size():
				var right_land: LandRecord = lands[right_idx]
				if right_land and right_land.has_heights():
					for y in range(MW_LAND_SIZE):
						# Average the shared edge
						var h1 := land.get_height(MW_LAND_SIZE - 1, y)
						var h2 := right_land.get_height(0, y)
						var avg := (h1 + h2) * 0.5
						land.heights[(MW_LAND_SIZE - 1) + y * MW_LAND_SIZE] = avg
						right_land.heights[0 + y * MW_LAND_SIZE] = avg
					stitched = true

		# Stitch bottom edge with top edge of neighbor below
		if gy < grid_height - 1:
			var below_idx := i + grid_width
			if below_idx < lands.size():
				var below_land: LandRecord = lands[below_idx]
				if below_land and below_land.has_heights():
					for x in range(MW_LAND_SIZE):
						# Average the shared edge
						var h1 := land.get_height(x, MW_LAND_SIZE - 1)
						var h2 := below_land.get_height(x, 0)
						var avg := (h1 + h2) * 0.5
						land.heights[x + (MW_LAND_SIZE - 1) * MW_LAND_SIZE] = avg
						below_land.heights[x + 0 * MW_LAND_SIZE] = avg
					stitched = true

	return stitched
