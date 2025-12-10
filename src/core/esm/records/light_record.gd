## Light Record (LIGH)
## Light sources - can be static or carried
## Ported from OpenMW components/esm3/loadligh.cpp
class_name LightRecord
extends ESMRecord

# Light flags
const FLAG_DYNAMIC: int = 0x0001
const FLAG_CAN_CARRY: int = 0x0002
const FLAG_NEGATIVE: int = 0x0004
const FLAG_FLICKER: int = 0x0008
const FLAG_FIRE: int = 0x0010
const FLAG_OFF_BY_DEFAULT: int = 0x0020
const FLAG_FLICKER_SLOW: int = 0x0040
const FLAG_PULSE: int = 0x0080
const FLAG_PULSE_SLOW: int = 0x0100

var name: String         # Display name
var model: String        # Path to NIF model
var script_id: String       # Script ID
var icon: String         # Inventory icon
var sound: String        # Sound ID

# LHDT subrecord
var weight: float
var value: int
var time: int            # Duration in seconds (0 = permanent)
var radius: int          # Light radius
var color: Color         # Light color
var flags: int           # Light flags

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_LIGH

static func get_record_type_name() -> String:
	return "Light"

func load(esm: ESMReader) -> void:
	super.load(esm)

	# Reset defaults
	name = ""
	model = ""
	script_id = ""
	icon = ""
	sound = ""
	weight = 0.0
	value = 0
	time = 0
	radius = 0
	color = Color.WHITE
	flags = 0

	# NAME - object ID
	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	# Pre-compute FourCC values
	var SNAM := ESMDefs.four_cc("SNAM")  # Sound
	var LHDT := ESMDefs.four_cc("LHDT")  # Light data

	# Load the rest
	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_MODL:
			model = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_FNAM:
			name = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_SCRI:
			script_id = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_ITEX:
			icon = esm.get_h_string()
		elif sub_name == SNAM:
			sound = esm.get_h_string()
		elif sub_name == LHDT:
			_load_light_data(esm)
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_light_data(esm: ESMReader) -> void:
	esm.get_sub_header()

	weight = esm.get_float()
	value = esm.get_s32()
	time = esm.get_s32()
	radius = esm.get_s32()

	# Color is stored as RGBA bytes
	var col := esm.get_u32()
	color = Color8(col & 0xFF, (col >> 8) & 0xFF, (col >> 16) & 0xFF, 255)

	flags = esm.get_s32()

## Check light flags
func is_dynamic() -> bool:
	return (flags & FLAG_DYNAMIC) != 0

func can_carry() -> bool:
	return (flags & FLAG_CAN_CARRY) != 0

func is_negative() -> bool:
	return (flags & FLAG_NEGATIVE) != 0

func is_flicker() -> bool:
	return (flags & FLAG_FLICKER) != 0

func is_fire() -> bool:
	return (flags & FLAG_FIRE) != 0

func is_off_by_default() -> bool:
	return (flags & FLAG_OFF_BY_DEFAULT) != 0

func _to_string() -> String:
	return "Light('%s', radius=%d, color=%s)" % [record_id, radius, color]
