## Leveled Creature Record (LEVC)
## Leveled lists of creatures (for spawning)
## Ported from OpenMW components/esm3/loadlevlist.hpp
class_name LeveledCreatureRecord
extends ESMRecord

# Leveled list flags
const FLAG_CALCULATE_ALL: int = 0x01  # Calculate all creatures at once

# DATA subrecord
var flags: int
var chance_none: int  # Chance that nothing spawns (0-100)

# Creatures in this list (CNAM + INTV pairs)
var creatures: Array[Dictionary] = []  # {creature_id, level}

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_LEVC

static func get_record_type_name() -> String:
	return "LeveledCreature"

func load(esm: ESMReader) -> void:
	super.load(esm)

	flags = 0
	chance_none = 0
	creatures.clear()

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var CNAM := ESMDefs.four_cc("CNAM")
	var NNAM := ESMDefs.four_cc("NNAM")
	var current_creature := ""

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
			esm.get_s32()  # Creature count (we build array dynamically)
		elif sub_name == CNAM:
			current_creature = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_INTV:
			esm.get_sub_header()
			var level := esm.get_u16()
			if not current_creature.is_empty():
				creatures.append({"creature_id": current_creature, "level": level})
				current_creature = ""
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func calculate_all() -> bool:
	return (flags & FLAG_CALCULATE_ALL) != 0

func _to_string() -> String:
	return "LeveledCreature('%s', creatures=%d)" % [record_id, creatures.size()]
