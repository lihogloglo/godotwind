## Dialogue Info Record (INFO)
## Individual dialogue entries/responses
## Ported from OpenMW components/esm3/loadinfo.hpp
class_name DialogueInfoRecord
extends ESMRecord

# Filter comparison types
enum FilterType {
	NOTHING = 0,
	FUNCTION = 1,
	GLOBAL = 2,
	LOCAL = 3,
	JOURNAL = 4,
	ITEM = 5,
	DEAD = 6,
	NOT_ID = 7,
	NOT_FACTION = 8,
	NOT_CLASS = 9,
	NOT_RACE = 10,
	NOT_CELL = 11,
	NOT_LOCAL = 12
}

var prev_id: String  # Previous INFO in chain
var next_id: String  # Next INFO in chain

# DATA subrecord
var disposition: int
var speaker_rank: int   # -1 for any
var speaker_sex: int    # 0=male, 1=female, -1=any
var player_rank: int    # -1 for any

var actor_id: String
var actor_race: String
var actor_class: String
var actor_faction: String
var actor_cell: String
var pc_faction: String
var sound_file: String

# Response text (NAME subrecord)
var response: String

# Result script (BNAM subrecord)
var result_script: String

# Conditions (SCVR/INTV/FLTV subrecords)
var conditions: Array[Dictionary] = []

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_INFO

static func get_record_type_name() -> String:
	return "DialogueInfo"

func load(esm: ESMReader) -> void:
	super.load(esm)

	prev_id = ""
	next_id = ""
	disposition = 0
	speaker_rank = -1
	speaker_sex = -1
	player_rank = -1
	actor_id = ""
	actor_race = ""
	actor_class = ""
	actor_faction = ""
	actor_cell = ""
	pc_faction = ""
	sound_file = ""
	response = ""
	result_script = ""
	conditions.clear()

	var INAM := ESMDefs.four_cc("INAM")
	var PNAM := ESMDefs.four_cc("PNAM")
	var NNAM := ESMDefs.four_cc("NNAM")
	var ONAM := ESMDefs.four_cc("ONAM")
	var RNAM := ESMDefs.four_cc("RNAM")
	var CNAM := ESMDefs.four_cc("CNAM")
	var ANAM := ESMDefs.four_cc("ANAM")
	var DNAM := ESMDefs.four_cc("DNAM")
	var SNAM := ESMDefs.four_cc("SNAM")
	var QSTN := ESMDefs.four_cc("QSTN")
	var QSTF := ESMDefs.four_cc("QSTF")
	var QSTR := ESMDefs.four_cc("QSTR")
	var SCVR := ESMDefs.four_cc("SCVR")
	var FLTV := ESMDefs.four_cc("FLTV")

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == INAM:
			record_id = esm.get_h_string()
		elif sub_name == PNAM:
			prev_id = esm.get_h_string()
		elif sub_name == NNAM:
			next_id = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_DATA:
			_load_data(esm)
		elif sub_name == ONAM:
			actor_id = esm.get_h_string()
		elif sub_name == RNAM:
			actor_race = esm.get_h_string()
		elif sub_name == CNAM:
			actor_class = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_FNAM:
			actor_faction = esm.get_h_string()
		elif sub_name == ANAM:
			actor_cell = esm.get_h_string()
		elif sub_name == DNAM:
			pc_faction = esm.get_h_string()
		elif sub_name == SNAM:
			sound_file = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_NAME:
			response = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_BNAM:
			result_script = esm.get_h_string()
		elif sub_name == SCVR:
			_load_condition(esm)
		elif sub_name == ESMDefs.SubRecordType.SREC_INTV:
			_load_condition_int(esm)
		elif sub_name == FLTV:
			_load_condition_float(esm)
		elif sub_name in [QSTN, QSTF, QSTR]:
			esm.skip_h_sub()  # Quest flags
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_data(esm: ESMReader) -> void:
	esm.get_sub_header()
	var size := esm.get_sub_size()
	if size >= 12:
		esm.get_s32()  # Unknown
		disposition = esm.get_s32()
		speaker_rank = esm.get_byte()
		speaker_sex = esm.get_byte()
		player_rank = esm.get_byte()
		esm.get_byte()  # Padding

func _load_condition(esm: ESMReader) -> void:
	esm.get_sub_header()
	var condition_str := esm.get_string(esm.get_sub_size())
	conditions.append({"raw": condition_str})

func _load_condition_int(esm: ESMReader) -> void:
	esm.get_sub_header()
	var value := esm.get_s32()
	if conditions.size() > 0:
		conditions[-1]["int_value"] = value

func _load_condition_float(esm: ESMReader) -> void:
	esm.get_sub_header()
	var value := esm.get_float()
	if conditions.size() > 0:
		conditions[-1]["float_value"] = value

func _to_string() -> String:
	return "DialogueInfo('%s')" % record_id
