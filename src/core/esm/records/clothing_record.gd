## Clothing Record (CLOT)
## Non-armor wearable items
## Ported from OpenMW components/esm3/loadclot.hpp
class_name ClothingRecord
extends ESMRecord

# Clothing types
enum ClothingType {
	PANTS = 0,
	SHOES = 1,
	SHIRT = 2,
	BELT = 3,
	ROBE = 4,
	RIGHT_GLOVE = 5,
	LEFT_GLOVE = 6,
	SKIRT = 7,
	RING = 8,
	AMULET = 9
}

var name: String
var model: String
var icon: String
var script_id: String
var enchant_id: String

# CTDT subrecord (12 bytes)
var clothing_type: int
var weight: float
var value: int
var enchant_points: int

# Body parts (INDX + BNAM pairs)
var body_parts: Array[Dictionary] = []

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_CLOT

static func get_record_type_name() -> String:
	return "Clothing"

func load(esm: ESMReader) -> void:
	super.load(esm)

	name = ""
	model = ""
	icon = ""
	script_id = ""
	enchant_id = ""
	clothing_type = ClothingType.SHIRT
	weight = 0.0
	value = 0
	enchant_points = 0
	body_parts.clear()

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var CTDT := ESMDefs.four_cc("CTDT")
	var ENAM := ESMDefs.four_cc("ENAM")
	var CNAM := ESMDefs.four_cc("CNAM")
	var current_part_index := -1

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
		elif sub_name == ENAM:
			enchant_id = esm.get_h_string()
		elif sub_name == CTDT:
			_load_clothing_data(esm)
		elif sub_name == ESMDefs.SubRecordType.SREC_INDX:
			esm.get_sub_header()
			current_part_index = esm.get_byte()
		elif sub_name == ESMDefs.SubRecordType.SREC_BNAM:
			var part_name := esm.get_h_string()
			body_parts.append({"index": current_part_index, "male": part_name})
		elif sub_name == CNAM:
			var part_name := esm.get_h_string()
			if body_parts.size() > 0:
				body_parts[-1]["female"] = part_name
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_clothing_data(esm: ESMReader) -> void:
	esm.get_sub_header()
	clothing_type = esm.get_s32()
	weight = esm.get_float()
	value = esm.get_u16()
	enchant_points = esm.get_u16()

func is_enchanted() -> bool:
	return not enchant_id.is_empty()

func _to_string() -> String:
	return "Clothing('%s', type=%d)" % [record_id, clothing_type]
