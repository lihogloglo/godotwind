## Sound Record (SOUN)
## Sound effect definitions
## Ported from OpenMW components/esm3/loadsoun.hpp
class_name SoundRecord
extends ESMRecord

var sound_file: String  # Path to the sound file

# DATA subrecord (3 bytes)
var volume: int      # 0-255
var min_range: int   # Minimum hearing distance
var max_range: int   # Maximum hearing distance

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_SOUN

static func get_record_type_name() -> String:
	return "Sound"

func load(esm: ESMReader) -> void:
	super.load(esm)

	sound_file = ""
	volume = 255
	min_range = 0
	max_range = 255

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_FNAM:
			sound_file = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_DATA:
			esm.get_sub_header()
			volume = esm.get_byte()
			min_range = esm.get_byte()
			max_range = esm.get_byte()
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func get_volume_normalized() -> float:
	return volume / 255.0

func _to_string() -> String:
	return "Sound('%s', file='%s')" % [record_id, sound_file]
