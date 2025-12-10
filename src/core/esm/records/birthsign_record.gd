## Birthsign Record (BSGN)
## Birthsign/star sign definitions
## Ported from OpenMW components/esm3/loadbsgn.hpp
class_name BirthsignRecord
extends ESMRecord

var name: String
var description: String
var texture: String  # Image file for the sign

# Powers/abilities granted by this sign (NPCS subrecords)
var powers: Array[String] = []

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_BSGN

static func get_record_type_name() -> String:
	return "Birthsign"

func load(esm: ESMReader) -> void:
	super.load(esm)

	name = ""
	description = ""
	texture = ""
	powers.clear()

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var DESC := ESMDefs.four_cc("DESC")
	var TNAM := ESMDefs.four_cc("TNAM")
	var NPCS := ESMDefs.four_cc("NPCS")

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_FNAM:
			name = esm.get_h_string()
		elif sub_name == DESC:
			description = esm.get_h_string()
		elif sub_name == TNAM:
			texture = esm.get_h_string()
		elif sub_name == NPCS:
			powers.append(esm.get_h_string())
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _to_string() -> String:
	return "Birthsign('%s', powers=%d)" % [record_id, powers.size()]
