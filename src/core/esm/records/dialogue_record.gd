## Dialogue Topic Record (DIAL)
## Dialogue topics (keywords) and journal entries
## Ported from OpenMW components/esm3/loaddial.hpp
class_name DialogueRecord
extends ESMRecord

# Dialogue types
enum DialogueType {
	TOPIC = 0,      # Regular conversation topic
	VOICE = 1,      # Voice acting line
	GREETING = 2,   # NPC greeting
	PERSUASION = 3, # Persuasion attempt
	JOURNAL = 4     # Journal entry
}

var dialogue_type: int

# INFO records following this DIAL (loaded separately)
# These are stored in ESMManager as part of dialogue loading

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_DIAL

static func get_record_type_name() -> String:
	return "Dialogue"

func load(esm: ESMReader) -> void:
	super.load(esm)

	dialogue_type = DialogueType.TOPIC

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_DATA:
			esm.get_sub_header()
			dialogue_type = esm.get_byte()
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func is_topic() -> bool:
	return dialogue_type == DialogueType.TOPIC

func is_journal() -> bool:
	return dialogue_type == DialogueType.JOURNAL

func is_greeting() -> bool:
	return dialogue_type == DialogueType.GREETING

func _to_string() -> String:
	return "Dialogue('%s', type=%d)" % [record_id, dialogue_type]
