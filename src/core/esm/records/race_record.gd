## Race Record (RACE)
## Playable and non-playable race definitions
## Ported from OpenMW components/esm3/loadrace.hpp
class_name RaceRecord
extends ESMRecord

const FLAG_PLAYABLE: int = 0x01
const FLAG_BEAST: int = 0x02

var name: String
var description: String

# RADT subrecord (140 bytes)
var skill_bonuses: Array[Dictionary] = []  # Up to 7 skill bonuses
var male_attributes: Array[int] = []       # 8 attributes
var female_attributes: Array[int] = []     # 8 attributes
var male_height: float
var female_height: float
var male_weight: float
var female_weight: float
var flags: int

# Powers/abilities (NPCS subrecords)
var powers: Array[String] = []

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_RACE

static func get_record_type_name() -> String:
	return "Race"

func load(esm: ESMReader) -> void:
	super.load(esm)

	name = ""
	description = ""
	skill_bonuses.clear()
	male_attributes = [0, 0, 0, 0, 0, 0, 0, 0]
	female_attributes = [0, 0, 0, 0, 0, 0, 0, 0]
	male_height = 1.0
	female_height = 1.0
	male_weight = 1.0
	female_weight = 1.0
	flags = 0
	powers.clear()

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var RADT := ESMDefs.four_cc("RADT")
	var DESC := ESMDefs.four_cc("DESC")
	var NPCS := ESMDefs.four_cc("NPCS")

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_FNAM:
			name = esm.get_h_string()
		elif sub_name == RADT:
			_load_race_data(esm)
		elif sub_name == DESC:
			description = esm.get_h_string()
		elif sub_name == NPCS:
			powers.append(esm.get_h_string())
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_race_data(esm: ESMReader) -> void:
	esm.get_sub_header()

	# 7 skill bonuses (skill_id, bonus)
	for i in range(7):
		var skill_id := esm.get_s32()
		var bonus := esm.get_s32()
		if skill_id >= 0:
			skill_bonuses.append({"skill": skill_id, "bonus": bonus})

	# 8 male attributes, then 8 female attributes
	for i in range(8):
		male_attributes[i] = esm.get_s32()
	for i in range(8):
		female_attributes[i] = esm.get_s32()

	male_height = esm.get_float()
	female_height = esm.get_float()
	male_weight = esm.get_float()
	female_weight = esm.get_float()

	flags = esm.get_s32()

func is_playable() -> bool:
	return (flags & FLAG_PLAYABLE) != 0

func is_beast() -> bool:
	return (flags & FLAG_BEAST) != 0

func _to_string() -> String:
	return "Race('%s', playable=%s, beast=%s)" % [record_id, is_playable(), is_beast()]
