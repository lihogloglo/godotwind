## Skill Record (SKIL)
## Skill definitions (27 skills in Morrowind)
## Ported from OpenMW components/esm3/loadskil.hpp
class_name SkillRecord
extends ESMRecord

# Skill indices (for reference)
enum SkillIndex {
	BLOCK = 0,
	ARMORER = 1,
	MEDIUM_ARMOR = 2,
	HEAVY_ARMOR = 3,
	BLUNT_WEAPON = 4,
	LONG_BLADE = 5,
	AXE = 6,
	SPEAR = 7,
	ATHLETICS = 8,
	ENCHANT = 9,
	DESTRUCTION = 10,
	ALTERATION = 11,
	ILLUSION = 12,
	CONJURATION = 13,
	MYSTICISM = 14,
	RESTORATION = 15,
	ALCHEMY = 16,
	UNARMORED = 17,
	SECURITY = 18,
	SNEAK = 19,
	ACROBATICS = 20,
	LIGHT_ARMOR = 21,
	SHORT_BLADE = 22,
	MARKSMAN = 23,
	MERCANTILE = 24,
	SPEECHCRAFT = 25,
	HAND_TO_HAND = 26
}

var description: String

# SKDT subrecord (24 bytes)
var attribute: int        # Governing attribute
var specialization: int   # 0=Combat, 1=Magic, 2=Stealth
var use_values: Array[float] = []  # 4 use values for skill gain

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_SKIL

static func get_record_type_name() -> String:
	return "Skill"

func load(esm: ESMReader) -> void:
	super.load(esm)

	description = ""
	attribute = 0
	specialization = 0
	use_values = [0.0, 0.0, 0.0, 0.0]

	# SKIL records use INDX instead of NAME for ID
	var INDX := ESMDefs.SubRecordType.SREC_INDX
	var SKDT := ESMDefs.four_cc("SKDT")
	var DESC := ESMDefs.four_cc("DESC")

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == INDX:
			esm.get_sub_header()
			var index := esm.get_s32()
			record_id = str(index)  # Use index as ID
		elif sub_name == SKDT:
			_load_skill_data(esm)
		elif sub_name == DESC:
			description = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_skill_data(esm: ESMReader) -> void:
	esm.get_sub_header()
	attribute = esm.get_s32()
	specialization = esm.get_s32()
	for i in range(4):
		use_values[i] = esm.get_float()

func _to_string() -> String:
	return "Skill('%s', attr=%d, spec=%d)" % [record_id, attribute, specialization]
