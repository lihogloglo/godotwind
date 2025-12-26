## Cell Reference - An object instance placed in a cell
## Ported from OpenMW components/esm3/cellref.cpp
class_name CellReference
extends RefCounted

# Pre-computed FourCC constants for performance (avoid repeated four_cc() calls)
const FOURCC_UNAM: int = 0x4D414E55  # "UNAM"
const FOURCC_XSCL: int = 0x4C435358  # "XSCL"
const FOURCC_ANAM: int = 0x4D414E41  # "ANAM"
const FOURCC_BNAM: int = 0x4D414E42  # "BNAM"
const FOURCC_XSOL: int = 0x4C4F5358  # "XSOL"
const FOURCC_CNAM: int = 0x4D414E43  # "CNAM"
const FOURCC_INDX: int = 0x58444E49  # "INDX"
const FOURCC_XCHG: int = 0x47484358  # "XCHG"
const FOURCC_INTV: int = 0x56544E49  # "INTV"
const FOURCC_NAM9: int = 0x394D414E  # "NAM9"
const FOURCC_DODT: int = 0x54444F44  # "DODT"
const FOURCC_DNAM: int = 0x4D414E44  # "DNAM"
const FOURCC_FLTV: int = 0x56544C46  # "FLTV"
const FOURCC_KNAM: int = 0x4D414E4B  # "KNAM"
const FOURCC_TNAM: int = 0x4D414E54  # "TNAM"
const FOURCC_DATA: int = 0x41544144  # "DATA"
const FOURCC_NAM0: int = 0x304D414E  # "NAM0"
const FOURCC_FRMR: int = 0x524D5246  # "FRMR"
const FOURCC_MVRF: int = 0x4652564D  # "MVRF"

# Core identity
var ref_num: int = 0           # FRMR - unique reference number
var ref_id: StringName         # NAME - base object ID (e.g., "barrel_01")
var is_deleted: bool = false   # DELE marker

# Transform (required for visualization)
var position: Vector3 = Vector3.ZERO  # DATA pos[3] - game units
var rotation: Vector3 = Vector3.ZERO  # DATA rot[3] - radians (Euler angles)
var scale: float = 1.0                # XSCL (clamped 0.5-2.0)

# Ownership data
var owner_id: StringName       # ANAM - owner NPC
var global_variable: String    # BNAM - global variable for temporary ownership
var faction_id: StringName     # CNAM - owning faction
var faction_rank: int = -2     # INDX - required faction rank
var reference_blocked: int = -1  # UNAM - blocked flag

# Item state
var count: int = 1             # NAM9 - stack count
var charge_int: int = -1       # INTV - charge remaining (weapons/armor)
var enchantment_charge: float = -1.0  # XCHG - enchantment charge
var soul_id: StringName        # XSOL - trapped soul creature ID

# Lock/trap data
var lock_level: int = 0        # FLTV - lock level (0 = unlocked)
var is_locked: bool = false    # Derived from lock_level and key
var key_id: StringName         # KNAM - key ID
var trap_id: StringName        # TNAM - trap spell ID

# Door teleport data
var teleport_pos: Vector3 = Vector3.ZERO  # DODT pos[3]
var teleport_rot: Vector3 = Vector3.ZERO  # DODT rot[3]
var teleport_cell: String      # DNAM - destination cell name
var is_teleport: bool = false  # True if DODT was present

## Load a cell reference starting from FRMR subrecord
## The ESMReader should be positioned at the FRMR subrecord
func load(esm: ESMReader) -> void:
	# Reset to defaults
	_blank()

	# FRMR subrecord contains the reference number (already read by caller as sub_name)
	# We need to read the actual ref_num value
	esm.get_sub_header()
	ref_num = esm.get_u32()

	# NAME subrecord - the base object ID
	if esm.is_next_sub(ESMDefs.SubRecordType.SREC_NAME):
		ref_id = StringName(esm.get_h_string())

	if ref_id.is_empty():
		push_warning("CellRef with empty RefId at offset %d" % esm.get_file_offset())

	# Parse remaining subrecords until we hit another FRMR or end of cell
	_load_data(esm)


## Load data subrecords after NAME
func _load_data(esm: ESMReader) -> void:
	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name: int = esm.get_current_sub_name()

		# Check if we've reached the next reference
		if sub_name == FOURCC_FRMR or sub_name == FOURCC_MVRF:
			# Put the subrecord back so the cell can read it
			esm.cache_sub_name()
			break

		if sub_name == FOURCC_UNAM:
			esm.get_sub_header()
			reference_blocked = esm.get_s8()
		elif sub_name == FOURCC_XSCL:
			esm.get_sub_header()
			scale = esm.get_float()
			# Clamp scale to valid range per OpenMW
			scale = clampf(scale, 0.5, 2.0)
		elif sub_name == FOURCC_ANAM:
			owner_id = StringName(esm.get_h_string())
		elif sub_name == FOURCC_BNAM:
			global_variable = esm.get_h_string()
		elif sub_name == FOURCC_XSOL:
			soul_id = StringName(esm.get_h_string())
		elif sub_name == FOURCC_CNAM:
			faction_id = StringName(esm.get_h_string())
		elif sub_name == FOURCC_INDX:
			esm.get_sub_header()
			faction_rank = esm.get_s32()
		elif sub_name == FOURCC_XCHG:
			esm.get_sub_header()
			enchantment_charge = esm.get_float()
		elif sub_name == FOURCC_INTV:
			esm.get_sub_header()
			charge_int = esm.get_s32()
		elif sub_name == FOURCC_NAM9:
			esm.get_sub_header()
			count = esm.get_s32()
		elif sub_name == FOURCC_DODT:
			_load_door_destination(esm)
		elif sub_name == FOURCC_DNAM:
			teleport_cell = esm.get_h_string()
		elif sub_name == FOURCC_FLTV:
			esm.get_sub_header()
			lock_level = esm.get_s32()
		elif sub_name == FOURCC_KNAM:
			key_id = StringName(esm.get_h_string())
		elif sub_name == FOURCC_TNAM:
			trap_id = StringName(esm.get_h_string())
		elif sub_name == FOURCC_DATA:
			_load_position(esm)
		elif sub_name == FOURCC_NAM0:
			# Temp refs marker - skip
			esm.skip_h_sub()
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			# Unknown subrecord - stop parsing this reference
			# and let the cell handle it
			esm.cache_sub_name()
			break

	# Determine if locked
	is_locked = not key_id.is_empty() or lock_level > 0


## Load position/rotation from DATA subrecord
func _load_position(esm: ESMReader) -> void:
	esm.get_sub_header()
	# Position: 3 floats
	var px := esm.get_float()
	var py := esm.get_float()
	var pz := esm.get_float()
	position = Vector3(px, py, pz)

	# Rotation: 3 floats (radians)
	var rx := esm.get_float()
	var ry := esm.get_float()
	var rz := esm.get_float()
	rotation = Vector3(rx, ry, rz)


## Load door destination from DODT subrecord
func _load_door_destination(esm: ESMReader) -> void:
	esm.get_sub_header()
	is_teleport = true

	# Position: 3 floats
	var px := esm.get_float()
	var py := esm.get_float()
	var pz := esm.get_float()
	teleport_pos = Vector3(px, py, pz)

	# Rotation: 3 floats (radians)
	var rx := esm.get_float()
	var ry := esm.get_float()
	var rz := esm.get_float()
	teleport_rot = Vector3(rx, ry, rz)


## Reset all fields to defaults
func _blank() -> void:
	ref_num = 0
	ref_id = &""
	is_deleted = false
	position = Vector3.ZERO
	rotation = Vector3.ZERO
	scale = 1.0
	owner_id = &""
	global_variable = ""
	faction_id = &""
	faction_rank = -2
	reference_blocked = -1
	count = 1
	charge_int = -1
	enchantment_charge = -1.0
	soul_id = &""
	lock_level = 0
	is_locked = false
	key_id = &""
	trap_id = &""
	teleport_pos = Vector3.ZERO
	teleport_rot = Vector3.ZERO
	teleport_cell = ""
	is_teleport = false


func _to_string() -> String:
	return "CellRef(%d, '%s', pos=%s, rot=%s, scale=%.2f)" % [
		ref_num, ref_id, position, rotation, scale
	]
