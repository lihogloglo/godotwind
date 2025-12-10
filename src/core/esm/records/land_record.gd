## Land Record (LAND)
## Landscape/terrain data for exterior cells
## Ported from OpenMW components/esm3/loadland.cpp
class_name LandRecord
extends ESMRecord

# Land data flags
const DATA_VNML: int = 0x01  # Has vertex normals
const DATA_VHGT: int = 0x02  # Has vertex heights
const DATA_WNAM: int = 0x04  # Has world map data
const DATA_VCLR: int = 0x08  # Has vertex colors
const DATA_VTEX: int = 0x10  # Has texture indices

# Constants - matches OpenMW LandRecordData
const LAND_SIZE: int = 65          # Vertices per side (sLandSize)
const LAND_NUM_VERTS: int = 4225   # 65 * 65 (sLandNumVerts)
const LAND_TEXTURE_SIZE: int = 16  # Texture cells per side
const LAND_NUM_TEXTURES: int = 256 # 16 * 16
const HEIGHT_SCALE: float = 8.0    # sHeightScale - multiplier for height deltas
const CELL_SIZE: float = 8192.0    # Cell size in game units

# Cell coordinates
var cell_x: int
var cell_y: int

# DATA flags
var data_flags: int

# Vertex heights (VHGT subrecord) - decoded to actual heights
var heights: PackedFloat32Array  # 65x65 grid, actual height values
var min_height: float = 0.0
var max_height: float = 0.0

# Vertex normals (VNML subrecord)
var normals: PackedByteArray  # 65x65x3 (x,y,z per vertex as signed bytes)

# Vertex colors (VCLR subrecord)
var vertex_colors: PackedByteArray  # 65x65x3 (r,g,b per vertex)

# Texture indices (VTEX subrecord) - transposed from ESM format
var texture_indices: PackedInt32Array  # 16x16 grid (already transposed)

# World map data (WNAM subrecord) - 9x9 low-res heights
var world_map_heights: PackedByteArray

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_LAND

static func get_record_type_name() -> String:
	return "Land"

func load(esm: ESMReader) -> void:
	super.load(esm)

	cell_x = 0
	cell_y = 0
	data_flags = 0
	heights = PackedFloat32Array()
	min_height = 0.0
	max_height = 0.0
	normals = PackedByteArray()
	vertex_colors = PackedByteArray()
	texture_indices = PackedInt32Array()
	world_map_heights = PackedByteArray()

	var INTV := ESMDefs.SubRecordType.SREC_INTV
	var VHGT := ESMDefs.four_cc("VHGT")
	var VNML := ESMDefs.four_cc("VNML")
	var VCLR := ESMDefs.four_cc("VCLR")
	var VTEX := ESMDefs.four_cc("VTEX")
	var WNAM := ESMDefs.four_cc("WNAM")

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == INTV:
			esm.get_sub_header()
			cell_x = esm.get_s32()
			cell_y = esm.get_s32()
			record_id = "%d,%d" % [cell_x, cell_y]
		elif sub_name == ESMDefs.SubRecordType.SREC_DATA:
			esm.get_sub_header()
			data_flags = esm.get_s32()
		elif sub_name == VHGT:
			_load_heights(esm)
		elif sub_name == VNML:
			esm.get_sub_header()
			normals = esm.get_exact(esm.get_sub_size())
		elif sub_name == VCLR:
			esm.get_sub_header()
			vertex_colors = esm.get_exact(esm.get_sub_size())
		elif sub_name == VTEX:
			_load_textures(esm)
		elif sub_name == WNAM:
			esm.get_sub_header()
			world_map_heights = esm.get_exact(esm.get_sub_size())
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()


## Load heightmap data using OpenMW's delta decoding algorithm
## Reference: OpenMW loadland.cpp lines 315-345
func _load_heights(esm: ESMReader) -> void:
	esm.get_sub_header()

	# VHGT format: float heightOffset + 4225 int8 deltas + 1 padding byte
	var height_offset := esm.get_float()

	# Read all height deltas as raw bytes
	var height_data := esm.get_exact(LAND_NUM_VERTS)
	# Skip padding byte
	esm.get_byte()

	heights.resize(LAND_NUM_VERTS)
	min_height = INF
	max_height = -INF

	# Decode using OpenMW algorithm:
	# - First column of each row: accumulate from row_offset
	# - Subsequent columns: accumulate from col_offset
	var row_offset := height_offset

	for y in range(LAND_SIZE):
		# First column: add to row_offset
		var delta := _signed_byte(height_data[y * LAND_SIZE])
		row_offset += delta

		var height := row_offset * HEIGHT_SCALE
		heights[y * LAND_SIZE] = height
		min_height = minf(min_height, height)
		max_height = maxf(max_height, height)

		# Remaining columns in this row
		var col_offset := row_offset
		for x in range(1, LAND_SIZE):
			delta = _signed_byte(height_data[y * LAND_SIZE + x])
			col_offset += delta

			height = col_offset * HEIGHT_SCALE
			heights[x + y * LAND_SIZE] = height
			min_height = minf(min_height, height)
			max_height = maxf(max_height, height)


## Convert unsigned byte to signed (-128 to 127)
func _signed_byte(b: int) -> int:
	if b > 127:
		return b - 256
	return b


## Load texture indices with transposition
## Reference: OpenMW loadland.cpp transposeTextureData() lines 31-39
func _load_textures(esm: ESMReader) -> void:
	esm.get_sub_header()

	# Read raw texture data (stored in transposed 4x4x4x4 pattern)
	var raw_tex: PackedInt32Array = []
	raw_tex.resize(LAND_NUM_TEXTURES)
	for i in range(LAND_NUM_TEXTURES):
		raw_tex[i] = esm.get_u16()

	# Transpose from ESM's 4x4x4x4 interleaved pattern to standard 16x16 grid
	texture_indices.resize(LAND_NUM_TEXTURES)
	var read_pos := 0
	for y1 in range(4):
		for x1 in range(4):
			for y2 in range(4):
				for x2 in range(4):
					var out_idx := (y1 * 4 + y2) * LAND_TEXTURE_SIZE + (x1 * 4 + x2)
					texture_indices[out_idx] = raw_tex[read_pos]
					read_pos += 1


func has_heights() -> bool:
	return heights.size() > 0

func has_normals() -> bool:
	return normals.size() > 0

func has_colors() -> bool:
	return vertex_colors.size() > 0

func has_textures() -> bool:
	return texture_indices.size() > 0

## Get height at grid position (0-64, 0-64)
func get_height(x: int, y: int) -> float:
	if x < 0 or x >= LAND_SIZE or y < 0 or y >= LAND_SIZE:
		return 0.0
	if heights.size() == 0:
		return 0.0
	return heights[y * LAND_SIZE + x]

## Get interpolated height at normalized position (0.0-1.0, 0.0-1.0) within cell
func get_height_at(norm_x: float, norm_y: float) -> float:
	if heights.size() == 0:
		return 0.0

	# Convert to grid coordinates
	var fx := norm_x * (LAND_SIZE - 1)
	var fy := norm_y * (LAND_SIZE - 1)

	var x0 := int(fx)
	var y0 := int(fy)
	var x1 := mini(x0 + 1, LAND_SIZE - 1)
	var y1 := mini(y0 + 1, LAND_SIZE - 1)

	var tx := fx - x0
	var ty := fy - y0

	# Bilinear interpolation
	var h00 := get_height(x0, y0)
	var h10 := get_height(x1, y0)
	var h01 := get_height(x0, y1)
	var h11 := get_height(x1, y1)

	var h0 := lerpf(h00, h10, tx)
	var h1 := lerpf(h01, h11, tx)

	return lerpf(h0, h1, ty)

## Get normal at grid position (returns normalized Vector3)
func get_normal(x: int, y: int) -> Vector3:
	if x < 0 or x >= LAND_SIZE or y < 0 or y >= LAND_SIZE:
		return Vector3.UP
	if normals.size() == 0:
		return Vector3.UP

	var idx := (y * LAND_SIZE + x) * 3
	var nx := _signed_byte(normals[idx]) / 127.0
	var ny := _signed_byte(normals[idx + 1]) / 127.0
	var nz := _signed_byte(normals[idx + 2]) / 127.0

	return Vector3(nx, ny, nz).normalized()

## Get vertex color at grid position
func get_color(x: int, y: int) -> Color:
	if x < 0 or x >= LAND_SIZE or y < 0 or y >= LAND_SIZE:
		return Color.WHITE
	if vertex_colors.size() == 0:
		return Color.WHITE

	var idx := (y * LAND_SIZE + x) * 3
	return Color8(vertex_colors[idx], vertex_colors[idx + 1], vertex_colors[idx + 2])

## Get texture index at texture grid position (0-15, 0-15)
## Returns texture index (0 = default, >0 = LTEX index + 1)
func get_texture_index(x: int, y: int) -> int:
	if x < 0 or x >= LAND_TEXTURE_SIZE or y < 0 or y >= LAND_TEXTURE_SIZE:
		return 0
	if texture_indices.size() == 0:
		return 0
	return texture_indices[y * LAND_TEXTURE_SIZE + x]

func _to_string() -> String:
	var info := "Land('%d,%d'" % [cell_x, cell_y]
	if has_heights():
		info += ", heights=[%.1f,%.1f]" % [min_height, max_height]
	info += ")"
	return info
