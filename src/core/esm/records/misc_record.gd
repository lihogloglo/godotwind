## Miscellaneous Item Record (MISC)
## Misc inventory items including keys
## Ported from OpenMW components/esm3/loadmisc.hpp
class_name MiscRecord
extends ESMRecord

const FLAG_KEY: int = 0x01

var name: String
var model: String
var icon: String
var script_id: String

# MCDT subrecord (12 bytes)
var weight: float
var value: int
var flags: int

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_MISC

static func get_record_type_name() -> String:
	return "Miscellaneous"

func load(esm: ESMReader) -> void:
	super.load(esm)

	name = ""
	model = ""
	icon = ""
	script_id = ""
	weight = 0.0
	value = 0
	flags = 0

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var MCDT := ESMDefs.four_cc("MCDT")

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_MODL:
			model = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_FNAM:
			name = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_ITEX:
			icon = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_SCRI:
			script_id = esm.get_h_string()
		elif sub_name == MCDT:
			_load_misc_data(esm)
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_misc_data(esm: ESMReader) -> void:
	esm.get_sub_header()
	weight = esm.get_float()
	value = esm.get_s32()
	flags = esm.get_s32()

func is_key() -> bool:
	return (flags & FLAG_KEY) != 0

func _to_string() -> String:
	return "Misc('%s', key=%s)" % [record_id, is_key()]
