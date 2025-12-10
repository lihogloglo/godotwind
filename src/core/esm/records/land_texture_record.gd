## Land Texture Record (LTEX)
## Landscape texture definitions
## Ported from OpenMW components/esm3/loadltex.hpp
class_name LandTextureRecord
extends ESMRecord

var texture_path: String
var texture_index: int  # Index used by LAND records

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_LTEX

static func get_record_type_name() -> String:
	return "LandTexture"

func load(esm: ESMReader) -> void:
	super.load(esm)

	texture_path = ""
	texture_index = 0

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_INTV:
			esm.get_sub_header()
			texture_index = esm.get_s32()
		elif sub_name == ESMDefs.SubRecordType.SREC_DATA:
			texture_path = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _to_string() -> String:
	return "LandTexture('%s', idx=%d)" % [record_id, texture_index]
