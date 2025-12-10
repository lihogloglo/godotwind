## Apparatus Record (APPA)
## Alchemy apparatus (mortar, retort, alembic, calcinator)
## Ported from OpenMW components/esm3/loadappa.hpp
class_name ApparatusRecord
extends ESMRecord

# Apparatus types
enum ApparatusType {
	MORTAR_PESTLE = 0,
	ALEMBIC = 1,
	CALCINATOR = 2,
	RETORT = 3
}

var name: String
var model: String
var icon: String
var script_id: String

# AADT subrecord (16 bytes)
var apparatus_type: int
var quality: float
var weight: float
var value: int

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_APPA

static func get_record_type_name() -> String:
	return "Apparatus"

func load(esm: ESMReader) -> void:
	super.load(esm)

	name = ""
	model = ""
	icon = ""
	script_id = ""
	apparatus_type = ApparatusType.MORTAR_PESTLE
	quality = 0.0
	weight = 0.0
	value = 0

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var AADT := ESMDefs.four_cc("AADT")

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
		elif sub_name == AADT:
			esm.get_sub_header()
			apparatus_type = esm.get_s32()
			quality = esm.get_float()
			weight = esm.get_float()
			value = esm.get_s32()
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _to_string() -> String:
	return "Apparatus('%s', type=%d, quality=%.2f)" % [record_id, apparatus_type, quality]
