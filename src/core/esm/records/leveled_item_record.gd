## Leveled Item Record (LEVI)
## Leveled lists of items (for random loot)
## Ported from OpenMW components/esm3/loadlevlist.hpp
class_name LeveledItemRecord
extends ESMRecord

# Leveled list flags
const FLAG_EACH_ITEM_ONCE: int = 0x01  # Pick each item only once
const FLAG_CALCULATE_ALL: int = 0x02  # Calculate all items at once

# DATA subrecord
var flags: int
var chance_none: int  # Chance that nothing is picked (0-100)

# Items in this list (INAM + INTV pairs)
var items: Array[Dictionary] = []  # {item_id, level}

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_LEVI

static func get_record_type_name() -> String:
	return "LeveledItem"

func load(esm: ESMReader) -> void:
	super.load(esm)

	flags = 0
	chance_none = 0
	items.clear()

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var INAM := ESMDefs.four_cc("INAM")
	var NNAM := ESMDefs.four_cc("NNAM")
	var current_item := ""

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_DATA:
			esm.get_sub_header()
			flags = esm.get_s32()
		elif sub_name == NNAM:
			esm.get_sub_header()
			chance_none = esm.get_byte()
		elif sub_name == ESMDefs.SubRecordType.SREC_INDX:
			esm.get_sub_header()
			esm.get_s32()  # Item count (we build array dynamically)
		elif sub_name == INAM:
			current_item = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_INTV:
			esm.get_sub_header()
			var level := esm.get_u16()
			if not current_item.is_empty():
				items.append({"item_id": current_item, "level": level})
				current_item = ""
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func pick_once() -> bool:
	return (flags & FLAG_EACH_ITEM_ONCE) != 0

func calculate_all() -> bool:
	return (flags & FLAG_CALCULATE_ALL) != 0

func _to_string() -> String:
	return "LeveledItem('%s', items=%d)" % [record_id, items.size()]
