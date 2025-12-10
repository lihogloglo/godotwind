## Class Record (CLAS)
## Character class definitions
## Ported from OpenMW components/esm3/loadclas.hpp
class_name ClassRecord
extends ESMRecord

# Specializations
enum Specialization {
	COMBAT = 0,
	MAGIC = 1,
	STEALTH = 2
}

const FLAG_PLAYABLE: int = 0x01

var name: String
var description: String

# CLDT subrecord (60 bytes)
var primary_attributes: Array[int] = []  # 2 attributes
var specialization: int
var major_skills: Array[int] = []  # 5 major skills
var minor_skills: Array[int] = []  # 5 minor skills
var is_playable: bool
var services: int  # For service-providing NPCs

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_CLAS

static func get_record_type_name() -> String:
	return "Class"

func load(esm: ESMReader) -> void:
	super.load(esm)

	name = ""
	description = ""
	primary_attributes = [0, 0]
	specialization = Specialization.COMBAT
	major_skills = [0, 0, 0, 0, 0]
	minor_skills = [0, 0, 0, 0, 0]
	is_playable = false
	services = 0

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var CLDT := ESMDefs.four_cc("CLDT")
	var DESC := ESMDefs.four_cc("DESC")

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_FNAM:
			name = esm.get_h_string()
		elif sub_name == CLDT:
			_load_class_data(esm)
		elif sub_name == DESC:
			description = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_class_data(esm: ESMReader) -> void:
	esm.get_sub_header()

	# 2 primary attributes
	primary_attributes[0] = esm.get_s32()
	primary_attributes[1] = esm.get_s32()

	specialization = esm.get_s32()

	# 5 skill pairs (minor, major)
	for i in range(5):
		minor_skills[i] = esm.get_s32()
		major_skills[i] = esm.get_s32()

	is_playable = esm.get_s32() != 0
	services = esm.get_s32()

func _to_string() -> String:
	return "Class('%s', spec=%d, playable=%s)" % [record_id, specialization, is_playable]
