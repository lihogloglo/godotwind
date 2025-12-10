## Activator Record (ACTI)
## Activators are interactive objects with scripts
## Ported from OpenMW components/esm3/loadacti.cpp
class_name ActivatorRecord
extends ESMRecord

var name: String     # Display name
var model: String    # Path to NIF model
var script_id: String   # Script ID

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_ACTI

static func get_record_type_name() -> String:
	return "Activator"

func load(esm: ESMReader) -> void:
	super.load(esm)

	# Reset defaults
	name = ""
	model = ""
	script_id = ""

	# NAME - object ID
	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	# Load the rest
	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		match sub_name:
			ESMDefs.SubRecordType.SREC_MODL:  # Model path
				model = esm.get_h_string()
			ESMDefs.SubRecordType.SREC_FNAM:  # Display name
				name = esm.get_h_string()
			ESMDefs.SubRecordType.SREC_SCRI:  # Script
				script_id = esm.get_h_string()
			ESMDefs.SubRecordType.SREC_DELE:
				esm.skip_h_sub()
				is_deleted = true
			_:
				esm.skip_h_sub()

func _to_string() -> String:
	return "Activator('%s', '%s')" % [record_id, name]
