## TerrainManager - Converts Morrowind LAND data to Terrain3D format
## Handles heightmap generation, texture splatting, and region management
## Reference: OpenMW components/terrain/ and components/esmterrain/storage.cpp
class_name TerrainManager
extends RefCounted

# Preload coordinate utilities
const CS := preload("res://src/core/coordinate_system.gd")

# Morrowind terrain constants (from CoordinateSystem)
const MW_CELL_SIZE: float = CS.CELL_SIZE_MW  # Cell size in Morrowind units
const MW_LAND_SIZE: int = 65                  # Vertices per cell side
const MW_TEXTURE_SIZE: int = 16               # Texture tiles per cell side

# Terrain3D region size (should match Terrain3D settings)
# With region_size=256, we can fit 4x4 MW cells per region
# This allows 32 regions × 4 cells = 128 cells per axis = ~15km coverage
var region_size: int = 256

## Number of MW cells per Terrain3D region axis (4 = 4x4 cells per region)
## With cells_per_region=4 and region_size=256:
##   - Each MW cell contributes 64 vertices (cropped from 65)
##   - 4 cells × 64 = 256 vertices = perfect fit for region_size=256
##   - Coverage: 32 regions × 4 cells × 117m = ~15km per axis
const CELLS_PER_REGION: int = 4

## Calculate which Terrain3D region a cell belongs to
## Returns the region index (each region holds CELLS_PER_REGION x CELLS_PER_REGION cells)
static func cell_to_region(cell_coord: Vector2i) -> Vector2i:
	# Integer division to get region index
	# Note: Python-style floor division for negative numbers
	var region_x: int = floori(float(cell_coord.x) / float(CELLS_PER_REGION))
	var region_y: int = floori(float(cell_coord.y) / float(CELLS_PER_REGION))
	return Vector2i(region_x, region_y)

## Calculate the local position of a cell within its region (0 to CELLS_PER_REGION-1)
static func cell_local_in_region(cell_coord: Vector2i) -> Vector2i:
	# Use positive modulo for consistent results with negative numbers
	var local_x: int = posmod(cell_coord.x, CELLS_PER_REGION)
	var local_y: int = posmod(cell_coord.y, CELLS_PER_REGION)
	return Vector2i(local_x, local_y)

## Get the southwest corner cell of a region (minimum x, minimum y)
static func region_to_sw_cell(region_coord: Vector2i) -> Vector2i:
	return Vector2i(region_coord.x * CELLS_PER_REGION, region_coord.y * CELLS_PER_REGION)

# Height scale for converting MW heights to Godot
# MW heights are in game units, Terrain3D expects meters
# This ALWAYS applies scale regardless of CS.APPLY_SCALE because
# terrain must be in consistent Godot units for proper rendering
var height_scale: float = 1.0 / CS.UNITS_PER_METER

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
##
## Morrowind height grid: 65x65 vertices
##   - In Morrowind: x=0 is west edge, x=64 is east edge
##   - In Morrowind: y=0 is south edge, y=64 is north edge
##
## Godot/Terrain3D Image coordinates:
##   - Image x=0 is left (west), x increases east
##   - Image y=0 is top, y increases downward
##
## Terrain3D world Z-axis: -Z is north, +Z is south
## So when we look at terrain from above:
##   - Image row 0 should correspond to the NORTH edge (negative Z)
##   - Image row 63 should correspond to the SOUTH edge (positive Z)
##
## This means we need to FLIP the Y axis:
##   - MW y=64 (north) -> Image y=0 (top) -> Terrain3D -Z (north)
##   - MW y=0 (south) -> Image y=63 (bottom) -> Terrain3D +Z (south)
##
## Adjacent cells share edges: Cell A's east edge (x=64) == Cell B's west edge (x=0)
## When we crop to 64x64, we keep [0-63] and discard [64].
## After Y-flip: we keep what was MW y=[1-64] and discard y=0 (south edge).
## The cell to the south provides the south edge for this cell in Terrain3D.
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

			# FLIP Y axis: MW y=0 (south) goes to image y=64 (bottom)
			#              MW y=64 (north) goes to image y=0 (top)
			var img_y := MW_LAND_SIZE - 1 - y
			img.set_pixel(x, img_y, Color(godot_height, 0, 0, 1))

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
## Note: Y-axis is flipped to match heightmap orientation (see generate_heightmap)
func generate_color_map(land: LandRecord) -> Image:
	var img := Image.create(MW_LAND_SIZE, MW_LAND_SIZE, false, Image.FORMAT_RGB8)

	if not land.has_colors():
		# Fill with white if no colors
		img.fill(Color.WHITE)
		return img

	for y in range(MW_LAND_SIZE):
		for x in range(MW_LAND_SIZE):
			var color := land.get_color(x, y)
			# FLIP Y axis to match heightmap orientation
			var img_y := MW_LAND_SIZE - 1 - y
			img.set_pixel(x, img_y, color)

	return img


## Generate a control map for Terrain3D from LAND texture indices
## This creates a control map with texture blending at boundaries
## Returns: Image in FORMAT_RF (Terrain3D control map format)
##
## Note: Y-axis is flipped to match heightmap orientation (see generate_heightmap)
##
## We implement smooth blending between adjacent texture cells:
## - At the center of a texture cell, blend = 0 (100% base texture)
## - Near texture cell boundaries, blend increases toward neighboring texture
##
## Debug flag to print control map encoding details (set to true to diagnose)
var _debug_control_map: bool = false

## Fast mode skips expensive per-pixel blending for better performance
## Set to false for higher quality texture transitions
var fast_control_map: bool = true

func generate_control_map(land: LandRecord) -> Image:
	# Terrain3D expects control map at same resolution as heightmap
	# MW texture grid is 16x16, so we need to upscale
	var img := Image.create(MW_LAND_SIZE, MW_LAND_SIZE, false, Image.FORMAT_RF)

	if not land.has_textures():
		# Fill with default texture (index 0)
		var default_control := _encode_control_value(0, 0, 0)
		img.fill(Color(default_control, 0, 0, 1))
		_stats["control_maps_generated"] += 1
		if _debug_control_map:
			print("TerrainManager: Cell (%d,%d) has NO texture data - using default" % [land.cell_x, land.cell_y])
		return img

	# Each MW texture cell covers ~4 height vertices
	var vertices_per_tex := float(MW_LAND_SIZE - 1) / float(MW_TEXTURE_SIZE)  # ~4.0

	# FAST MODE: Simple nearest-neighbor texture mapping (no blending)
	# This is ~10x faster than full blending and looks acceptable
	if fast_control_map:
		for y in range(MW_LAND_SIZE):
			for x in range(MW_LAND_SIZE):
				var tex_x := mini(int(float(x) / vertices_per_tex), MW_TEXTURE_SIZE - 1)
				var tex_y := mini(int(float(y) / vertices_per_tex), MW_TEXTURE_SIZE - 1)
				var mw_tex_idx := land.get_texture_index(tex_x, tex_y)
				var slot := _get_terrain3d_texture_slot(mw_tex_idx)
				var img_y := MW_LAND_SIZE - 1 - y
				var control := _encode_control_value(slot, 0, 0)
				img.set_pixel(x, img_y, Color(control, 0, 0, 1))

		_stats["control_maps_generated"] += 1
		return img

	# QUALITY MODE: Full per-pixel blending (expensive but prettier)
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

			# Calculate position within cell (0.0-1.0)
			var frac_x := tex_x_f - float(tex_x)
			var frac_y := tex_y_f - float(tex_y)

			# Use bilinear-style blending for smoother transitions
			# Sample the 4 corners of the current position and blend based on distance
			var overlay_slot := base_slot
			var blend_strength := 0.0

			# Get neighboring texture slots
			var slot_right := base_slot
			var slot_top := base_slot
			var slot_diag := base_slot  # top-right diagonal

			if tex_x < MW_TEXTURE_SIZE - 1:
				slot_right = _get_terrain3d_texture_slot(land.get_texture_index(tex_x + 1, tex_y))
			if tex_y < MW_TEXTURE_SIZE - 1:
				slot_top = _get_terrain3d_texture_slot(land.get_texture_index(tex_x, tex_y + 1))
			if tex_x < MW_TEXTURE_SIZE - 1 and tex_y < MW_TEXTURE_SIZE - 1:
				slot_diag = _get_terrain3d_texture_slot(land.get_texture_index(tex_x + 1, tex_y + 1))

			# Determine dominant blend direction using smooth interpolation
			# Weight blend by distance to cell edges (wider blend zone)
			var blend_x := frac_x  # 0 at left edge, 1 at right edge
			var blend_y := frac_y  # 0 at bottom edge, 1 at top edge

			# Apply smoothstep for smoother transitions
			blend_x = blend_x * blend_x * (3.0 - 2.0 * blend_x)
			blend_y = blend_y * blend_y * (3.0 - 2.0 * blend_y)

			# Determine which neighbor has the strongest influence
			# Priority: diagonal > vertical > horizontal (for corners)
			var max_blend := 0.0

			# Check diagonal (corner) blending first
			if slot_diag != base_slot:
				var diag_blend := blend_x * blend_y
				if diag_blend > max_blend:
					max_blend = diag_blend
					overlay_slot = slot_diag
					blend_strength = diag_blend

			# Check horizontal blending
			if slot_right != base_slot:
				var h_blend := blend_x * (1.0 - blend_y)
				if h_blend > max_blend:
					max_blend = h_blend
					overlay_slot = slot_right
					blend_strength = h_blend

			# Check vertical blending
			if slot_top != base_slot:
				var v_blend := blend_y * (1.0 - blend_x)
				if v_blend > max_blend:
					max_blend = v_blend
					overlay_slot = slot_top
					blend_strength = v_blend

			# Convert blend strength (0-1) to 8-bit value (0-255)
			# Scale up blend for more visible transitions
			var blend := int(clampf(blend_strength * 2.0, 0.0, 1.0) * 255.0)

			# FLIP Y axis to match heightmap orientation
			var img_y := MW_LAND_SIZE - 1 - y
			var control := _encode_control_value(base_slot, overlay_slot, blend)
			img.set_pixel(x, img_y, Color(control, 0, 0, 1))

	# Debug: Print texture usage for first few control maps
	if _debug_control_map and _stats["control_maps_generated"] < 5:
		var tex_usage: Dictionary = {}
		var mw_indices: Dictionary = {}
		for y in range(MW_TEXTURE_SIZE):
			for x in range(MW_TEXTURE_SIZE):
				var mw_idx := land.get_texture_index(x, y)
				var slot := _get_terrain3d_texture_slot(mw_idx)
				if not tex_usage.has(slot):
					tex_usage[slot] = 0
				tex_usage[slot] += 1
				if not mw_indices.has(mw_idx):
					mw_indices[mw_idx] = slot
		print("TerrainManager: Cell (%d,%d) MW->Slot mappings: %s" % [land.cell_x, land.cell_y, mw_indices])
		print("TerrainManager: Cell (%d,%d) slot usage counts: %s" % [land.cell_x, land.cell_y, tex_usage])
		# Sample control values from different slots to verify encoding
		for mw_idx: int in mw_indices.keys():
			var slot: int = mw_indices[mw_idx]
			var sample_ctrl := _encode_control_value(slot, 0, 0)
			var decoded_slot := (_float_to_bits(sample_ctrl) >> 27) & 0x1F
			print("TerrainManager: Verify encoding - MW idx %d -> slot %d -> bits %d -> decoded %d [%s]" % [
				mw_idx, slot, _float_to_bits(sample_ctrl), decoded_slot,
				"OK" if decoded_slot == slot else "MISMATCH!"])

	# Verify the control map image actually stored correct values
	if _debug_control_map and _stats["control_maps_generated"] < 3:
		print("TerrainManager: Verifying control map image values for cell (%d,%d):" % [land.cell_x, land.cell_y])
		# Sample a few pixels and decode them
		for sample_y in [0, 32, 63]:
			for sample_x in [0, 32, 63]:
				var pixel_color := img.get_pixel(sample_x, sample_y)
				var stored_float := pixel_color.r
				var stored_bits := _float_to_bits(stored_float)
				var decoded_base := (stored_bits >> 27) & 0x1F
				var decoded_overlay := (stored_bits >> 22) & 0x1F
				var decoded_blend := (stored_bits >> 14) & 0xFF
				print("  Pixel (%d,%d): base_slot=%d, overlay=%d, blend=%d (bits=0x%08X)" % [
					sample_x, sample_y, decoded_base, decoded_overlay, decoded_blend, stored_bits])

	_stats["control_maps_generated"] += 1
	return img


## Debug: Enable/disable control map debug output
func set_debug_control_map(enabled: bool) -> void:
	_debug_control_map = enabled


## Convert float back to int bits for debugging
func _float_to_bits(f: float) -> int:
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_float(0, f)
	return bytes.decode_u32(0)


## Debug: Print binary representation of control value
func _debug_control_bits(bits: int) -> String:
	var s := ""
	for i in range(31, -1, -1):
		if i == 26 or i == 21 or i == 13 or i == 9 or i == 6 or i == 2 or i == 1:
			s += "_"
		s += "1" if (bits >> i) & 1 else "0"
	return s


## Encode a Terrain3D control map value
## base_tex: Base texture slot (0-31)
## overlay_tex: Overlay texture slot (0-31)
## blend: Blend amount (0-255)
## Returns: Float representation of packed uint32
##
## Terrain3D Control Map Format (from documentation):
## https://terrain3d.readthedocs.io/en/stable/docs/controlmap_format.html
##
## | Field              | Range   | Bits | Position | Decode Formula    |
## |--------------------|---------|------|----------|-------------------|
## | Base texture ID    | 0-31    | 5    | 32-28    | x >> 27 & 0x1F    |
## | Overlay texture ID | 0-31    | 5    | 27-23    | x >> 22 & 0x1F    |
## | Texture blend      | 0-255   | 8    | 22-15    | x >> 14 & 0xFF    |
## | UV angle           | 0-15    | 4    | 14-11    | x >> 10 & 0xF     |
## | UV scale           | 0-7     | 3    | 10-8     | x >> 7 & 0x7      |
## | (unused)           | -       | 4    | 7-4      | -                 |
## | Hole flag          | 0-1     | 1    | 3        | x >> 2 & 0x1      |
## | Navigation flag    | 0-1     | 1    | 2        | x >> 1 & 0x1      |
## | Autoshader flag    | 0-1     | 1    | 1        | x & 0x1           |
##
func _encode_control_value(base_tex: int, overlay_tex: int, blend: int) -> float:
	var value: int = 0
	value |= (base_tex & 0x1F) << 27      # Bits 27-31: Base texture ID
	value |= (overlay_tex & 0x1F) << 22   # Bits 22-26: Overlay texture ID
	value |= (blend & 0xFF) << 14         # Bits 14-21: Blend value
	# UV angle = 0 (bits 10-13)
	# UV scale = 0 (bits 7-9)
	# Hole = 0 (bit 2)
	# Navigation = 0 (bit 1)
	# Autoshader = 0 (bit 0)

	# Convert to float for storage in FORMAT_RF image
	# We need to reinterpret the bits as float, not convert numerically
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
		var slot: int = _texture_slot_mapper.get_slot_for_mw_index(mw_tex_idx)
		if _debug_control_map and _stats["control_maps_generated"] < 3:
			print("TerrainManager: _get_terrain3d_texture_slot(%d) -> slot %d (via mapper)" % [mw_tex_idx, slot])
		return slot

	# Check cache for fallback mapping
	if mw_tex_idx in _texture_map:
		return _texture_map[mw_tex_idx]

	# Fallback: simple modulo mapping (Terrain3D supports 32 textures)
	# This is used when no texture loader is configured
	var ltex_index := mw_tex_idx - 1
	var slot := (ltex_index % 31) + 1  # Slot 0 is default, 1-31 are LTEX
	_texture_map[mw_tex_idx] = slot
	if _debug_control_map:
		push_warning("TerrainManager: Using fallback mapping for MW index %d -> slot %d (no mapper!)" % [mw_tex_idx, slot])
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


## Import a single LAND record into Terrain3D at a specific local coordinate
## This is the unified method for terrain importing used by:
##   - terrain_preprocessor.gd (single-terrain mode)
##   - multi_terrain_preprocessor.gd (multi-terrain/chunked mode)
##   - terrain_viewer.gd (live conversion mode)
##   - streaming_demo.gd (runtime terrain generation)
##
## Parameters:
##   terrain: The Terrain3D node to import into
##   land: The LAND record containing height/color/texture data
##   local_coord: Optional local coordinate within a chunk (-16 to +15).
##                If Vector2i.ZERO, uses the cell's world coordinates directly.
##   use_local_coord: If true, uses local_coord for positioning (chunk mode).
##                    If false, uses land.cell_x/cell_y (global mode).
##
## Returns: true if import succeeded, false if cell is out of bounds
func import_cell_to_terrain(terrain: Terrain3D, land: LandRecord, local_coord: Vector2i = Vector2i.ZERO, use_local_coord: bool = false) -> bool:
	if not terrain or not terrain.data:
		return false

	# Determine the cell coordinate to use for positioning
	var cell_x: int
	var cell_y: int

	if use_local_coord:
		cell_x = local_coord.x
		cell_y = local_coord.y
	else:
		cell_x = land.cell_x
		cell_y = land.cell_y

	# LEGACY MODE (region_size=64, 1 cell per region):
	#   - Valid cell indices: -16 to +15 (32 cells per axis = ~3.7km)
	# NEW COMBINED MODE (region_size=256, 4x4 cells per region):
	#   - Use import_combined_region() instead for larger terrain support
	#   - Valid cell indices: -64 to +63 (128 cells per axis = ~15km)
	#
	# This function is kept for backward compatibility but the combined mode
	# is recommended for large terrains like Morrowind's Vvardenfell.
	if cell_x < -16 or cell_x > 15 or cell_y < -16 or cell_y > 15:
		return false

	# Generate maps from LAND record (65x65)
	var heightmap: Image = generate_heightmap(land)
	var colormap: Image = generate_color_map(land)
	var controlmap: Image = generate_control_map(land)

	# Crop from 65x65 to 64x64 by keeping pixels [0-63] and discarding pixel 64
	# This preserves exact edge values - the east/north edges we discard will be
	# provided by the adjacent cell's west/south edges (which are their pixel 0)
	const REGION_SIZE := 64
	var cropped_heightmap := Image.create(REGION_SIZE, REGION_SIZE, false, Image.FORMAT_RF)
	var cropped_colormap := Image.create(REGION_SIZE, REGION_SIZE, false, Image.FORMAT_RGB8)
	var cropped_controlmap := Image.create(REGION_SIZE, REGION_SIZE, false, Image.FORMAT_RF)

	cropped_heightmap.blit_rect(heightmap, Rect2i(0, 0, REGION_SIZE, REGION_SIZE), Vector2i(0, 0))
	cropped_colormap.blit_rect(colormap, Rect2i(0, 0, REGION_SIZE, REGION_SIZE), Vector2i(0, 0))
	cropped_controlmap.blit_rect(controlmap, Rect2i(0, 0, REGION_SIZE, REGION_SIZE), Vector2i(0, 0))

	# Calculate world position for this cell
	# With vertex_spacing configured, each region represents one MW cell
	var region_world_size := float(REGION_SIZE) * terrain.get_vertex_spacing()

	# Calculate the import position
	# CRITICAL: Terrain3D's import_images() uses ABSOLUTE world coordinates,
	# NOT coordinates relative to the terrain node's position!
	# When terrain.position = (1000, 0, 0) and we import at (100, 0, 0),
	# Terrain3D creates the region at WORLD position (100, 0, 0), not (1100, 0, 0).
	# Therefore, we must ALWAYS add the terrain node's position to get absolute coords.
	var world_x: float
	var world_z: float

	if use_local_coord:
		# In local coord mode, cell_x/cell_y are in range [-16, +15]
		# We need to:
		# 1. Convert local coords [-16, +15] to chunk offset [0, 31] by adding 16
		# 2. Calculate position relative to chunk's origin (southwest corner)
		# 3. Add the terrain node's world position to get absolute world coords
		var offset_x := float(cell_x + 16) * region_world_size + region_world_size * 0.5
		var offset_z := float(-(cell_y + 16)) * region_world_size - region_world_size * 0.5
		# Add terrain node's position to get absolute world coordinates
		world_x = terrain.global_position.x + offset_x
		world_z = terrain.global_position.z + offset_z
	else:
		# In global mode, cell_x/cell_y are absolute cell coordinates
		# MW Y axis is North, Godot Z axis is South, so negate Y
		# Position at the center of the region for proper snapping
		world_x = float(cell_x) * region_world_size + region_world_size * 0.5
		world_z = float(-cell_y) * region_world_size - region_world_size * 0.5

	# Create import array [heightmap, controlmap, colormap]
	var imported_images: Array[Image] = []
	imported_images.resize(Terrain3DRegion.TYPE_MAX)
	imported_images[Terrain3DRegion.TYPE_HEIGHT] = cropped_heightmap
	imported_images[Terrain3DRegion.TYPE_CONTROL] = cropped_controlmap
	imported_images[Terrain3DRegion.TYPE_COLOR] = cropped_colormap

	# Import into Terrain3D at the calculated position
	var import_pos := Vector3(world_x, 0, world_z)

	# DEBUG: Log import position for verification
	if use_local_coord and (cell_x == 0 and cell_y == 0) or (cell_x == -8 and cell_y == -8):
		print("[TerrainManager] Importing cell (%d,%d) at world pos: (%.1f, %.1f, %.1f)" % [
			cell_x, cell_y, import_pos.x, import_pos.y, import_pos.z
		])
		print("  Terrain global_position: (%.1f, %.1f, %.1f)" % [
			terrain.global_position.x, terrain.global_position.y, terrain.global_position.z
		])
		print("  use_local_coord: %s, region_world_size: %.2f" % [use_local_coord, region_world_size])

	terrain.data.import_images(imported_images, import_pos, 0.0, 1.0)

	_stats["regions_created"] += 1
	return true


## Import a combined region (CELLS_PER_REGION x CELLS_PER_REGION cells) into a single Terrain3D region
## This is the NEW method for large terrain support (region_size=256, 4x4 cells per region)
##
## With this approach:
##   - Each Terrain3D region holds 4x4 = 16 MW cells
##   - 32 regions × 4 cells = 128 cells per axis = ~15km coverage
##   - Morrowind's Vvardenfell (~100x100 cells = ~12km) fits easily!
##
## Parameters:
##   terrain: The Terrain3D node to import into
##   region_coord: The region coordinate (-16 to +15 for each axis)
##   get_land_func: Callable that takes (cell_x, cell_y) and returns LandRecord or null
##
## Returns: true if any terrain data was imported, false if region is empty
func import_combined_region(terrain: Terrain3D, region_coord: Vector2i, get_land_func: Callable) -> bool:
	if not terrain or not terrain.data:
		return false

	# Terrain3D region bounds: -16 to +15 (32 regions per axis)
	if region_coord.x < -16 or region_coord.x > 15 or region_coord.y < -16 or region_coord.y > 15:
		return false

	# Combined region size: CELLS_PER_REGION × 64 pixels = 256 pixels
	const CELL_SIZE := 64  # Cropped cell size
	var region_size_pixels: int = CELLS_PER_REGION * CELL_SIZE  # 256

	# Create combined images for the entire region
	var combined_heightmap := Image.create(region_size_pixels, region_size_pixels, false, Image.FORMAT_RF)
	var combined_colormap := Image.create(region_size_pixels, region_size_pixels, false, Image.FORMAT_RGB8)
	var combined_controlmap := Image.create(region_size_pixels, region_size_pixels, false, Image.FORMAT_RF)

	# Fill with defaults
	combined_heightmap.fill(Color(0, 0, 0, 1))  # Flat terrain
	combined_colormap.fill(Color.WHITE)          # White vertex color
	var default_control := _encode_control_value(0, 0, 0)
	combined_controlmap.fill(Color(default_control, 0, 0, 1))

	# Get the southwest corner cell of this region
	var sw_cell := region_to_sw_cell(region_coord)
	var any_data := false

	# Iterate through all cells in this region (from SW to NE)
	for local_y in range(CELLS_PER_REGION):
		for local_x in range(CELLS_PER_REGION):
			var cell_x := sw_cell.x + local_x
			var cell_y := sw_cell.y + local_y

			# Get LAND record for this cell
			var land: LandRecord = get_land_func.call(cell_x, cell_y)
			if not land or not land.has_heights():
				continue

			any_data = true

			# Generate maps from LAND record (65x65)
			var cell_heightmap: Image = generate_heightmap(land)
			var cell_colormap: Image = generate_color_map(land)
			var cell_controlmap: Image = generate_control_map(land)

			# Calculate pixel offset within the combined image
			# Note: In the combined image, local_y=0 (south cells) go to the BOTTOM (higher y in image)
			# because we flipped Y in generate_heightmap to match Terrain3D convention
			# So local_y=0 -> img_y = (CELLS_PER_REGION - 1 - 0) * CELL_SIZE = highest y
			# And local_y=3 -> img_y = (CELLS_PER_REGION - 1 - 3) * CELL_SIZE = 0 (top)
			var img_offset_x := local_x * CELL_SIZE
			var img_offset_y := (CELLS_PER_REGION - 1 - local_y) * CELL_SIZE

			# Blit the 64x64 cropped cell data into the combined image
			combined_heightmap.blit_rect(cell_heightmap, Rect2i(0, 0, CELL_SIZE, CELL_SIZE), Vector2i(img_offset_x, img_offset_y))
			combined_colormap.blit_rect(cell_colormap, Rect2i(0, 0, CELL_SIZE, CELL_SIZE), Vector2i(img_offset_x, img_offset_y))
			combined_controlmap.blit_rect(cell_controlmap, Rect2i(0, 0, CELL_SIZE, CELL_SIZE), Vector2i(img_offset_x, img_offset_y))

	if not any_data:
		return false

	# Calculate world position for this region
	# Each cell is (64 vertices × vertex_spacing) meters wide
	# Each region is (CELLS_PER_REGION × 64 × vertex_spacing) meters wide
	var vertex_spacing := terrain.get_vertex_spacing()
	var cell_world_size := float(CELL_SIZE) * vertex_spacing
	var region_world_size := float(CELLS_PER_REGION) * cell_world_size

	# Position at the center of the region for proper Terrain3D snapping
	# SW cell corner is at (sw_cell.x * cell_world_size, -sw_cell.y * cell_world_size)
	# Region center offset from SW corner: (region_world_size/2, -region_world_size/2)
	var world_x := float(sw_cell.x) * cell_world_size + region_world_size * 0.5
	var world_z := float(-sw_cell.y) * cell_world_size - region_world_size * 0.5

	# Create import array [heightmap, controlmap, colormap]
	var imported_images: Array[Image] = []
	imported_images.resize(Terrain3DRegion.TYPE_MAX)
	imported_images[Terrain3DRegion.TYPE_HEIGHT] = combined_heightmap
	imported_images[Terrain3DRegion.TYPE_CONTROL] = combined_controlmap
	imported_images[Terrain3DRegion.TYPE_COLOR] = combined_colormap

	# Import into Terrain3D at the calculated position
	var import_pos := Vector3(world_x, 0, world_z)
	terrain.data.import_images(imported_images, import_pos, 0.0, 1.0)

	_stats["regions_created"] += 1
	return true


## Check if a combined region contains any terrain data
## Useful for determining which regions need to be loaded
func region_has_terrain_data(region_coord: Vector2i, get_land_func: Callable) -> bool:
	var sw_cell := region_to_sw_cell(region_coord)

	for local_y in range(CELLS_PER_REGION):
		for local_x in range(CELLS_PER_REGION):
			var cell_x := sw_cell.x + local_x
			var cell_y := sw_cell.y + local_y
			var land: LandRecord = get_land_func.call(cell_x, cell_y)
			if land and land.has_heights():
				return true

	return false


## Debug: Compare edge heights between adjacent cells
## Returns a dictionary with comparison results
static func debug_compare_cell_edges(land_a: LandRecord, land_b: LandRecord, edge: String) -> Dictionary:
	var result := {
		"edge": edge,
		"cell_a": Vector2i(land_a.cell_x, land_a.cell_y),
		"cell_b": Vector2i(land_b.cell_x, land_b.cell_y),
		"matches": 0,
		"mismatches": 0,
		"max_diff": 0.0,
		"samples": []
	}

	if not land_a.has_heights() or not land_b.has_heights():
		result["error"] = "Missing height data"
		return result

	# Compare edges based on adjacency type
	# edge = "horizontal" means A is west of B (A's east edge vs B's west edge)
	# edge = "vertical" means A is south of B (A's north edge vs B's south edge)

	for i in range(MW_LAND_SIZE):
		var h_a: float
		var h_b: float

		if edge == "horizontal":
			# A's east edge (x=64) vs B's west edge (x=0)
			h_a = land_a.get_height(MW_LAND_SIZE - 1, i)  # x=64, y=i
			h_b = land_b.get_height(0, i)                  # x=0, y=i
		else:  # vertical
			# A's north edge (y=64) vs B's south edge (y=0)
			h_a = land_a.get_height(i, MW_LAND_SIZE - 1)  # x=i, y=64
			h_b = land_b.get_height(i, 0)                  # x=i, y=0

		var diff := absf(h_a - h_b)
		if diff < 0.01:
			result["matches"] += 1
		else:
			result["mismatches"] += 1
			result["max_diff"] = maxf(result["max_diff"], diff)

		# Store some samples
		if i % 16 == 0:
			result["samples"].append({
				"idx": i,
				"h_a": h_a,
				"h_b": h_b,
				"diff": diff
			})

	return result


## Stitch adjacent cell heights at shared edges
## This ensures seamless terrain between cells
## lands: Array of LandRecords in row-major order for a grid (Y ascending = south to north)
## grid_width: Number of cells wide
## Returns: True if stitching was applied
##
## Grid layout (MW coordinate system, Y increases north):
##   gy=2: [cell(-1,1)] [cell(0,1)] [cell(1,1)]   <- northmost row
##   gy=1: [cell(-1,0)] [cell(0,0)] [cell(1,0)]
##   gy=0: [cell(-1,-1)][cell(0,-1)][cell(1,-1)]  <- southmost row
##         gx=0         gx=1        gx=2
##
## Shared edges:
##   - Horizontal: Cell's east edge (x=64) matches cell-to-east's west edge (x=0)
##   - Vertical: Cell's north edge (y=64) matches cell-to-north's south edge (y=0)
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

		# Stitch east edge with west edge of cell to the east
		if gx < grid_width - 1:
			var east_idx := i + 1
			if east_idx < lands.size():
				var east_land: LandRecord = lands[east_idx]
				if east_land and east_land.has_heights():
					for y in range(MW_LAND_SIZE):
						# Average the shared edge: this cell's x=64 with east cell's x=0
						var h1 := land.get_height(MW_LAND_SIZE - 1, y)
						var h2 := east_land.get_height(0, y)
						var avg := (h1 + h2) * 0.5
						land.heights[(MW_LAND_SIZE - 1) + y * MW_LAND_SIZE] = avg
						east_land.heights[0 + y * MW_LAND_SIZE] = avg
					stitched = true

		# Stitch north edge with south edge of cell to the north
		# In our grid, gy+1 is to the north (higher Y in MW coords)
		if gy < grid_height - 1:
			var north_idx := i + grid_width
			if north_idx < lands.size():
				var north_land: LandRecord = lands[north_idx]
				if north_land and north_land.has_heights():
					for x in range(MW_LAND_SIZE):
						# Average the shared edge: this cell's y=64 with north cell's y=0
						var h1 := land.get_height(x, MW_LAND_SIZE - 1)
						var h2 := north_land.get_height(x, 0)
						var avg := (h1 + h2) * 0.5
						land.heights[x + (MW_LAND_SIZE - 1) * MW_LAND_SIZE] = avg
						north_land.heights[x + 0 * MW_LAND_SIZE] = avg
					stitched = true

	return stitched


# =============================================================================
# ASYNC TERRAIN GENERATION API
# =============================================================================
# These methods separate image generation from Terrain3D import.
# generate_region_data() is THREAD-SAFE and can run on WorkerThreadPool.
# import_region_data() MUST run on main thread (accesses Terrain3D).
# =============================================================================

## Container for pre-generated terrain region data
## Can be safely passed between threads
class RegionData:
	extends RefCounted

	var region_coord: Vector2i
	var heightmap: Image
	var controlmap: Image
	var colormap: Image
	var has_data: bool = false
	var vertex_spacing: float = 1.0  # For world position calculation

	func _init(coord: Vector2i = Vector2i.ZERO) -> void:
		region_coord = coord


## Generate terrain region data without importing (THREAD-SAFE)
## This can be called from a worker thread via BackgroundProcessor.
##
## Parameters:
##   region_coord: The region coordinate (-16 to +15 for each axis)
##   lands: Array of LandRecord objects for the 4x4 cells in this region
##          Expected order: SW corner first, then east, then next row north
##          Array size should be CELLS_PER_REGION * CELLS_PER_REGION = 16
##   vertex_spacing: The Terrain3D vertex spacing (for world position calculation)
##
## Returns: RegionData containing the generated images
func generate_region_data(region_coord: Vector2i, lands: Array, vertex_spacing: float = 1.0) -> RegionData:
	var result := RegionData.new(region_coord)
	result.vertex_spacing = vertex_spacing

	# Terrain3D region bounds check
	if region_coord.x < -16 or region_coord.x > 15 or region_coord.y < -16 or region_coord.y > 15:
		return result

	# Combined region size: CELLS_PER_REGION × 64 pixels = 256 pixels
	const CELL_SIZE := 64
	var region_size_pixels: int = CELLS_PER_REGION * CELL_SIZE  # 256

	# Create combined images for the entire region
	var combined_heightmap := Image.create(region_size_pixels, region_size_pixels, false, Image.FORMAT_RF)
	var combined_colormap := Image.create(region_size_pixels, region_size_pixels, false, Image.FORMAT_RGB8)
	var combined_controlmap := Image.create(region_size_pixels, region_size_pixels, false, Image.FORMAT_RF)

	# Fill with defaults
	combined_heightmap.fill(Color(0, 0, 0, 1))
	combined_colormap.fill(Color.WHITE)
	var default_control := _encode_control_value(0, 0, 0)
	combined_controlmap.fill(Color(default_control, 0, 0, 1))

	var any_data := false

	# Iterate through all cells in this region
	for local_y in range(CELLS_PER_REGION):
		for local_x in range(CELLS_PER_REGION):
			var land_idx := local_y * CELLS_PER_REGION + local_x

			# Get LAND record from array
			var land: LandRecord = null
			if land_idx < lands.size() and lands[land_idx] != null:
				land = lands[land_idx] as LandRecord

			if not land or not land.has_heights():
				continue

			any_data = true

			# Generate maps from LAND record (65x65)
			var cell_heightmap: Image = generate_heightmap(land)
			var cell_colormap: Image = generate_color_map(land)
			var cell_controlmap: Image = generate_control_map(land)

			# Calculate pixel offset within the combined image
			var img_offset_x := local_x * CELL_SIZE
			var img_offset_y := (CELLS_PER_REGION - 1 - local_y) * CELL_SIZE

			# Blit the 64x64 cropped cell data into the combined image
			combined_heightmap.blit_rect(cell_heightmap, Rect2i(0, 0, CELL_SIZE, CELL_SIZE), Vector2i(img_offset_x, img_offset_y))
			combined_colormap.blit_rect(cell_colormap, Rect2i(0, 0, CELL_SIZE, CELL_SIZE), Vector2i(img_offset_x, img_offset_y))
			combined_controlmap.blit_rect(cell_controlmap, Rect2i(0, 0, CELL_SIZE, CELL_SIZE), Vector2i(img_offset_x, img_offset_y))

	result.heightmap = combined_heightmap
	result.colormap = combined_colormap
	result.controlmap = combined_controlmap
	result.has_data = any_data

	return result


## Import pre-generated region data into Terrain3D (MAIN THREAD ONLY)
## This uses data generated by generate_region_data().
##
## Parameters:
##   terrain: The Terrain3D node to import into
##   region_data: The RegionData from generate_region_data()
##
## Returns: true if import succeeded
func import_region_data(terrain: Terrain3D, region_data: RegionData) -> bool:
	if not terrain or not terrain.data:
		return false

	if not region_data or not region_data.has_data:
		return false

	# Calculate world position for this region
	const CELL_SIZE := 64
	var sw_cell := region_to_sw_cell(region_data.region_coord)

	var vertex_spacing := region_data.vertex_spacing
	if vertex_spacing <= 0:
		vertex_spacing = terrain.get_vertex_spacing()

	var cell_world_size := float(CELL_SIZE) * vertex_spacing
	var region_world_size := float(CELLS_PER_REGION) * cell_world_size

	# Position at the center of the region
	var world_x := float(sw_cell.x) * cell_world_size + region_world_size * 0.5
	var world_z := float(-sw_cell.y) * cell_world_size - region_world_size * 0.5

	# Create import array [heightmap, controlmap, colormap]
	var imported_images: Array[Image] = []
	imported_images.resize(Terrain3DRegion.TYPE_MAX)
	imported_images[Terrain3DRegion.TYPE_HEIGHT] = region_data.heightmap
	imported_images[Terrain3DRegion.TYPE_CONTROL] = region_data.controlmap
	imported_images[Terrain3DRegion.TYPE_COLOR] = region_data.colormap

	# Import into Terrain3D at the calculated position
	var import_pos := Vector3(world_x, 0, world_z)
	terrain.data.import_images(imported_images, import_pos, 0.0, 1.0)

	_stats["regions_created"] += 1
	return true


## Collect LAND records for a region (helper for async loading)
## Returns an array of CELLS_PER_REGION * CELLS_PER_REGION elements
## in row-major order from SW corner
static func collect_lands_for_region(region_coord: Vector2i, get_land_func: Callable) -> Array:
	var lands: Array = []
	lands.resize(CELLS_PER_REGION * CELLS_PER_REGION)

	var sw_cell := region_to_sw_cell(region_coord)

	for local_y in range(CELLS_PER_REGION):
		for local_x in range(CELLS_PER_REGION):
			var cell_x := sw_cell.x + local_x
			var cell_y := sw_cell.y + local_y
			var land_idx := local_y * CELLS_PER_REGION + local_x

			lands[land_idx] = get_land_func.call(cell_x, cell_y)

	return lands
