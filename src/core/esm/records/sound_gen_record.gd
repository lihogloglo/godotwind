## Sound Generator Record (SNDG)
## Creature/NPC sound generators
## Ported from OpenMW components/esm3/loadsndg.hpp
class_name SoundGenRecord
extends ESMRecord

# Sound generator types
enum SoundType {
	LEFT_FOOT = 0,
	RIGHT_FOOT = 1,
	SWIM_LEFT = 2,
	SWIM_RIGHT = 3,
	MOAN = 4,
	ROAR = 5,
	SCREAM = 6,
	LAND = 7
}

var creature_id: String
var sound_id: String
var sound_type: int

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_SNDG

static func get_record_type_name() -> String:
	return "SoundGenerator"

func load(esm: ESMReader) -> void:
	super.load(esm)

	creature_id = ""
	sound_id = ""
	sound_type = SoundType.LEFT_FOOT

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var CNAM := ESMDefs.four_cc("CNAM")
	var SNAM := ESMDefs.four_cc("SNAM")

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_DATA:
			esm.get_sub_header()
			sound_type = esm.get_s32()
		elif sub_name == CNAM:
			creature_id = esm.get_h_string()
		elif sub_name == SNAM:
			sound_id = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _to_string() -> String:
	return "SoundGen('%s', creature='%s')" % [record_id, creature_id]
