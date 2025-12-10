## Start Script Record (SSCR)
## Scripts to run when game starts
## Ported from OpenMW components/esm3/loadsscr.hpp
class_name StartScriptRecord
extends ESMRecord

var script_id: String

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_SSCR

static func get_record_type_name() -> String:
	return "StartScript"

func load(esm: ESMReader) -> void:
	super.load(esm)

	script_id = ""

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_NAME:
			script_id = esm.get_h_string()
			record_id = script_id
		elif sub_name == ESMDefs.SubRecordType.SREC_DATA:
			# DATA contains the same script name (32 bytes fixed)
			esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _to_string() -> String:
	return "StartScript('%s')" % record_id
