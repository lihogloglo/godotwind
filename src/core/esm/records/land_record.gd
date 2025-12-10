## Land Record (LAND)
## Landscape/terrain data for exterior cells
## Ported from OpenMW components/esm3/loadland.hpp
class_name LandRecord
extends ESMRecord

# Land data flags
const DATA_VNML: int = 0x01  # Has vertex normals
const DATA_VHGT: int = 0x02  # Has vertex heights
const DATA_WNAM: int = 0x04  # Has world map data
const DATA_VCLR: int = 0x08  # Has vertex colors
const DATA_VTEX: int = 0x10  # Has texture indices

# Constants
const LAND_SIZE: int = 65       # Vertices per side
const LAND_NUM_VERTS: int = 4225  # 65 * 65
const LAND_TEXTURE_SIZE: int = 16  # Texture cells per side

# Cell coordinates
var cell_x: int
var cell_y: int

# DATA flags
var data_flags: int

# Vertex heights (VHGT subrecord) - stored as offsets from base height
var height_offset: float
var heights: PackedFloat32Array  # 65x65 grid

# Vertex normals (VNML subrecord)
var normals: PackedByteArray  # 65x65x3 (x,y,z per vertex)

# Vertex colors (VCLR subrecord)
var vertex_colors: PackedByteArray  # 65x65x3 (r,g,b per vertex)

# Texture indices (VTEX subrecord)
var texture_indices: PackedInt32Array  # 16x16 grid

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
	height_offset = 0.0
	heights = PackedFloat32Array()
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

func _load_heights(esm: ESMReader) -> void:
	esm.get_sub_header()
	height_offset = esm.get_float()

	heights.resize(LAND_NUM_VERTS)
	var row_offset := height_offset

	for y in range(LAND_SIZE):
		var col_offset := row_offset
		for x in range(LAND_SIZE):
			if y == 0 and x == 0:
				# Skip - first value is the row offset delta
				var delta := esm.get_byte()
				if delta > 127:
					delta -= 256
				col_offset = row_offset
			else:
				var delta := esm.get_byte()
				if delta > 127:
					delta -= 256
				col_offset += delta

			heights[y * LAND_SIZE + x] = col_offset * 8.0

		# Row offset for next row
		var row_delta := esm.get_byte()
		if row_delta > 127:
			row_delta -= 256
		row_offset += row_delta * 8.0

	# Skip unused byte at end
	esm.get_byte()

func _load_textures(esm: ESMReader) -> void:
	esm.get_sub_header()
	texture_indices.resize(LAND_TEXTURE_SIZE * LAND_TEXTURE_SIZE)
	for i in range(texture_indices.size()):
		texture_indices[i] = esm.get_u16()

func has_heights() -> bool:
	return (data_flags & DATA_VHGT) != 0

func has_normals() -> bool:
	return (data_flags & DATA_VNML) != 0

func has_colors() -> bool:
	return (data_flags & DATA_VCLR) != 0

func has_textures() -> bool:
	return (data_flags & DATA_VTEX) != 0

func get_height(x: int, y: int) -> float:
	if x < 0 or x >= LAND_SIZE or y < 0 or y >= LAND_SIZE:
		return 0.0
	return heights[y * LAND_SIZE + x]

func _to_string() -> String:
	return "Land('%d,%d')" % [cell_x, cell_y]
