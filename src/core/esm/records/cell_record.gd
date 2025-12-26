## Cell Record (CELL)
## Cells contain data about a location in the game world
## Ported from OpenMW components/esm3/loadcell.cpp
class_name CellRecord
extends ESMRecord

const CellReferenceScript = preload("res://src/core/esm/records/cell_reference.gd")

# Pre-computed FourCC constants for performance (avoid repeated four_cc() calls)
const FOURCC_RGNN: int = 0x4E4E4752  # "RGNN"
const FOURCC_NAM5: int = 0x354D414E  # "NAM5"
const FOURCC_WHGT: int = 0x54474857  # "WHGT"
const FOURCC_AMBI: int = 0x49424D41  # "AMBI"
const FOURCC_NAM0: int = 0x304D414E  # "NAM0"
const FOURCC_FRMR: int = 0x524D5246  # "FRMR"
const FOURCC_MVRF: int = 0x4652564D  # "MVRF"

# Cell data
var name: String           # Display name (interior cells use this as ID)
var region_id: String      # Region reference for exterior cells

# DATA subrecord
var flags: int
var grid_x: int
var grid_y: int

# AMBI subrecord - ambient lighting
var ambient_color: Color
var sunlight_color: Color
var fog_color: Color
var fog_density: float
var has_ambient: bool

# Water
var water_height: float
var has_water_height: bool

# Map color
var map_color: int

# Reference counter (for editor)
var ref_num_counter: int

# Cell references - objects placed in this cell
var references: Array = []  # Array of CellReference objects

# File context for lazy loading of cell contents
var context_positions: Array[int]  # File positions for each content file

const CELL_SIZE: int = 8192  # Morrowind cell size in game units

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_CELL

static func get_record_type_name() -> String:
	return "Cell"

func load(esm: ESMReader) -> void:
	super.load(esm)

	# Reset defaults
	name = ""
	region_id = ""
	flags = 0
	grid_x = 0
	grid_y = 0
	has_ambient = false
	water_height = 0.0
	has_water_height = false
	map_color = 0
	ref_num_counter = 0
	references = []
	context_positions = []

	# First, load NAME and DATA
	_load_name_and_data(esm)

	# Then load the rest
	_load_cell_data(esm)

func _load_name_and_data(esm: ESMReader) -> void:
	# NAME - cell name
	if esm.is_next_sub(ESMDefs.SubRecordType.SREC_NAME):
		name = esm.get_h_string()

	# DATA - cell data (flags and grid position)
	if esm.is_next_sub(ESMDefs.SubRecordType.SREC_DATA):
		esm.get_sub_header()
		var size := esm.get_sub_size()

		flags = esm.get_s32()

		if size >= 12:
			grid_x = esm.get_s32()
			grid_y = esm.get_s32()

	# Update record_id based on cell type
	if is_interior():
		record_id = name
	else:
		record_id = "%d,%d" % [grid_x, grid_y]

func _load_cell_data(esm: ESMReader) -> void:
	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name: int = esm.get_current_sub_name()

		if sub_name == FOURCC_RGNN:
			region_id = esm.get_h_string()
		elif sub_name == FOURCC_NAM5:
			var data: PackedByteArray = esm.get_h_t(4)
			map_color = data.decode_s32(0)
		elif sub_name == FOURCC_WHGT:
			var data: PackedByteArray = esm.get_h_t(4)
			water_height = data.decode_float(0)
			has_water_height = true
		elif sub_name == FOURCC_AMBI:
			_load_ambient(esm)
		elif sub_name == FOURCC_NAM0:
			var data: PackedByteArray = esm.get_h_t(4)
			ref_num_counter = data.decode_s32(0)
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		elif sub_name == FOURCC_MVRF:
			# Moved reference - skip for now (handled by plugin system)
			# MVRF contains ref_num (4 bytes) + CNDT target cell (8 bytes)
			esm.skip_h_sub()
			# The following FRMR belongs to the moved ref, skip it too
			if esm.is_next_sub(FOURCC_FRMR):
				_skip_cell_ref(esm)
		elif sub_name == FOURCC_FRMR:
			# Cell reference - parse it
			var ref: CellReference = CellReferenceScript.new()
			ref.load(esm)
			if not ref.is_deleted:
				references.append(ref)
		else:
			# Unknown subrecord - skip
			esm.skip_h_sub()


## Skip a cell reference without fully parsing it
func _skip_cell_ref(esm: ESMReader) -> void:
	# Skip FRMR subrecord data (ref_num)
	esm.skip_h_sub()

	# Skip remaining subrecords until next FRMR/MVRF or end of record
	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name: int = esm.get_current_sub_name()

		if sub_name == FOURCC_FRMR or sub_name == FOURCC_MVRF:
			esm.cache_sub_name()
			break

		esm.skip_h_sub()

func _load_ambient(esm: ESMReader) -> void:
	esm.get_sub_header()
	has_ambient = true

	# Ambient color (4 bytes)
	var amb := esm.get_u32()
	ambient_color = Color8(amb & 0xFF, (amb >> 8) & 0xFF, (amb >> 16) & 0xFF, (amb >> 24) & 0xFF)

	# Sunlight color (4 bytes)
	var sun := esm.get_u32()
	sunlight_color = Color8(sun & 0xFF, (sun >> 8) & 0xFF, (sun >> 16) & 0xFF, (sun >> 24) & 0xFF)

	# Fog color (4 bytes)
	var fog := esm.get_u32()
	fog_color = Color8(fog & 0xFF, (fog >> 8) & 0xFF, (fog >> 16) & 0xFF, (fog >> 24) & 0xFF)

	# Fog density (4 bytes)
	fog_density = esm.get_float()

## Check if this is an interior cell
func is_interior() -> bool:
	return (flags & ESMDefs.CELL_INTERIOR) != 0

## Check if this is an exterior cell
func is_exterior() -> bool:
	return not is_interior()

## Check if the cell has water
func has_water() -> bool:
	return ((flags & ESMDefs.CELL_HAS_WATER) != 0) or is_exterior()

## Check if sleeping is allowed
func can_sleep() -> bool:
	return (flags & ESMDefs.CELL_NO_SLEEP) == 0

## Check if interior cell behaves like exterior (has sky/weather)
func is_quasi_exterior() -> bool:
	return (flags & ESMDefs.CELL_QUASI_EXTERIOR) != 0

## Get a description of the cell
func get_description() -> String:
	if is_interior():
		return name if not name.is_empty() else "(unnamed interior)"
	else:
		if name.is_empty():
			return "%.0f, %.0f" % [grid_x, grid_y]
		else:
			return "%s (%.0f, %.0f)" % [name, grid_x, grid_y]

func _to_string() -> String:
	var type_str := "Interior" if is_interior() else "Exterior"
	return "Cell('%s', %s, refs=%d)" % [get_description(), type_str, references.size()]
