## Door Record (DOOR)
## Doors can be opened/closed and may teleport to other cells
## Ported from OpenMW components/esm3/loaddoor.cpp
class_name DoorRecord
extends ESMRecord

var name: String         # Display name
var model: String        # Path to NIF model
var script_id: String       # Script ID
var open_sound: String   # Sound ID for opening
var close_sound: String  # Sound ID for closing

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_DOOR

static func get_record_type_name() -> String:
	return "Door"

func load(esm: ESMReader) -> void:
	super.load(esm)

	# Reset defaults
	name = ""
	model = ""
	script_id = ""
	open_sound = ""
	close_sound = ""

	# NAME - object ID
	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	# Pre-compute FourCC values
	var SNAM := ESMDefs.four_cc("SNAM")  # Open sound
	var ANAM := ESMDefs.four_cc("ANAM")  # Close sound

	# Load the rest
	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_MODL:
			model = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_FNAM:
			name = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_SCRI:
			script_id = esm.get_h_string()
		elif sub_name == SNAM:
			open_sound = esm.get_h_string()
		elif sub_name == ANAM:
			close_sound = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _to_string() -> String:
	return "Door('%s', '%s')" % [record_id, name]
