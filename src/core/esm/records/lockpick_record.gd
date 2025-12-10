## Lockpick Record (LOCK)
## Lockpicking tools
## Ported from OpenMW components/esm3/loadlock.hpp
class_name LockpickRecord
extends ESMRecord

var name: String
var model: String
var icon: String
var script_id: String

# LKDT subrecord (16 bytes)
var weight: float
var value: int
var quality: float
var uses: int

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_LOCK

static func get_record_type_name() -> String:
	return "Lockpick"

func load(esm: ESMReader) -> void:
	super.load(esm)

	name = ""
	model = ""
	icon = ""
	script_id = ""
	weight = 0.0
	value = 0
	quality = 0.0
	uses = 0

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var LKDT := ESMDefs.four_cc("LKDT")

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
		elif sub_name == LKDT:
			esm.get_sub_header()
			weight = esm.get_float()
			value = esm.get_s32()
			quality = esm.get_float()
			uses = esm.get_s32()
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _to_string() -> String:
	return "Lockpick('%s', quality=%.2f)" % [record_id, quality]
