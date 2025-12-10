## Cell Reference - An object instance placed in a cell
## Ported from OpenMW components/esm3/cellref.cpp
class_name CellReference
extends RefCounted

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
	# Pre-compute FourCC values
	var UNAM := ESMDefs.four_cc("UNAM")
	var XSCL := ESMDefs.four_cc("XSCL")
	var ANAM := ESMDefs.four_cc("ANAM")
	var BNAM := ESMDefs.four_cc("BNAM")
	var XSOL := ESMDefs.four_cc("XSOL")
	var CNAM := ESMDefs.four_cc("CNAM")
	var INDX := ESMDefs.four_cc("INDX")
	var XCHG := ESMDefs.four_cc("XCHG")
	var INTV := ESMDefs.four_cc("INTV")
	var NAM9 := ESMDefs.four_cc("NAM9")
	var DODT := ESMDefs.four_cc("DODT")
	var DNAM := ESMDefs.four_cc("DNAM")
	var FLTV := ESMDefs.four_cc("FLTV")
	var KNAM := ESMDefs.four_cc("KNAM")
	var TNAM := ESMDefs.four_cc("TNAM")
	var DATA := ESMDefs.four_cc("DATA")
	var NAM0 := ESMDefs.four_cc("NAM0")
	var DELE := ESMDefs.SubRecordType.SREC_DELE
	var FRMR := ESMDefs.four_cc("FRMR")
	var MVRF := ESMDefs.four_cc("MVRF")

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		# Check if we've reached the next reference
		if sub_name == FRMR or sub_name == MVRF:
			# Put the subrecord back so the cell can read it
			esm.cache_sub_name()
			break

		if sub_name == UNAM:
			esm.get_sub_header()
			reference_blocked = esm.get_s8()
		elif sub_name == XSCL:
			esm.get_sub_header()
			scale = esm.get_float()
			# Clamp scale to valid range per OpenMW
			scale = clampf(scale, 0.5, 2.0)
		elif sub_name == ANAM:
			owner_id = StringName(esm.get_h_string())
		elif sub_name == BNAM:
			global_variable = esm.get_h_string()
		elif sub_name == XSOL:
			soul_id = StringName(esm.get_h_string())
		elif sub_name == CNAM:
			faction_id = StringName(esm.get_h_string())
		elif sub_name == INDX:
			esm.get_sub_header()
			faction_rank = esm.get_s32()
		elif sub_name == XCHG:
			esm.get_sub_header()
			enchantment_charge = esm.get_float()
		elif sub_name == INTV:
			esm.get_sub_header()
			charge_int = esm.get_s32()
		elif sub_name == NAM9:
			esm.get_sub_header()
			count = esm.get_s32()
		elif sub_name == DODT:
			_load_door_destination(esm)
		elif sub_name == DNAM:
			teleport_cell = esm.get_h_string()
		elif sub_name == FLTV:
			esm.get_sub_header()
			lock_level = esm.get_s32()
		elif sub_name == KNAM:
			key_id = StringName(esm.get_h_string())
		elif sub_name == TNAM:
			trap_id = StringName(esm.get_h_string())
		elif sub_name == DATA:
			_load_position(esm)
		elif sub_name == NAM0:
			# Temp refs marker - skip
			esm.skip_h_sub()
		elif sub_name == DELE:
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
