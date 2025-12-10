## Book Record (BOOK)
## Books, scrolls, notes and other readable items
## Ported from OpenMW components/esm3/loadbook.hpp
class_name BookRecord
extends ESMRecord

# Basic info
var name: String
var model: String
var icon: String
var script_id: String
var enchant_id: String
var text: String

# BKDT subrecord (20 bytes)
var weight: float
var value: int
var is_scroll: bool
var skill_id: int  # Skill improved by reading (-1 for none)
var enchant_points: int

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_BOOK

static func get_record_type_name() -> String:
	return "Book"

func load(esm: ESMReader) -> void:
	super.load(esm)

	name = ""
	model = ""
	icon = ""
	script_id = ""
	enchant_id = ""
	text = ""
	weight = 0.0
	value = 0
	is_scroll = false
	skill_id = -1
	enchant_points = 0

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var BKDT := ESMDefs.four_cc("BKDT")
	var TEXT := ESMDefs.four_cc("TEXT")
	var ENAM := ESMDefs.four_cc("ENAM")

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
		elif sub_name == TEXT:
			text = esm.get_h_string()
		elif sub_name == BKDT:
			_load_book_data(esm)
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_book_data(esm: ESMReader) -> void:
	esm.get_sub_header()
	weight = esm.get_float()
	value = esm.get_s32()
	is_scroll = esm.get_s32() != 0
	skill_id = esm.get_s32()
	enchant_points = esm.get_s32()

func is_enchanted() -> bool:
	return not enchant_id.is_empty()

func teaches_skill() -> bool:
	return skill_id >= 0

func _to_string() -> String:
	return "Book('%s', scroll=%s)" % [record_id, is_scroll]
