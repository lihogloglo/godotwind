## Static Object Record (STAT)
## A static is basically just a reference to a NIF model file
## Ported from OpenMW components/esm3/loadstat.cpp
class_name StaticRecord
extends ESMRecord

var model: String  # Path to NIF model file

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_STAT

static func get_record_type_name() -> String:
	return "Static"

func load(esm: ESMReader) -> void:
	super.load(esm)
	is_deleted = false
	record_id = ""
	model = ""

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		match sub_name:
			ESMDefs.SubRecordType.SREC_NAME:
				record_id = esm.get_h_string()
			ESMDefs.SubRecordType.SREC_MODL:
				model = esm.get_h_string()
			ESMDefs.SubRecordType.SREC_DELE:
				esm.skip_h_sub()
				is_deleted = true
			_:
				# Skip unknown subrecords
				esm.skip_h_sub()

	if record_id.is_empty() and not is_deleted:
		esm.fail("Static record missing NAME subrecord")

func _to_string() -> String:
	return "Static('%s', model='%s')" % [record_id, model]
