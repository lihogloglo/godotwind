## Game Setting Record (GMST)
## Game settings control various gameplay parameters
## Ported from OpenMW components/esm3/loadgmst.cpp
class_name GameSettingRecord
extends ESMRecord

enum ValueType {
	TYPE_STRING,
	TYPE_INT,
	TYPE_FLOAT
}

var value_type: ValueType
var string_value: String
var int_value: int
var float_value: float

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_GMST

static func get_record_type_name() -> String:
	return "GameSetting"

func load(esm: ESMReader) -> void:
	super.load(esm)

	# NAME - setting name (determines type by first letter)
	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	# Determine type from first character of name
	# s* = string, f* = float, i* = int
	if record_id.length() > 0:
		var first_char := record_id[0].to_lower()
		match first_char:
			"s":
				value_type = ValueType.TYPE_STRING
			"f":
				value_type = ValueType.TYPE_FLOAT
			"i":
				value_type = ValueType.TYPE_INT
			_:
				# Unknown type, try to detect from data
				value_type = ValueType.TYPE_STRING

	# Pre-compute FourCC values
	var STRV := ESMDefs.four_cc("STRV")  # String value
	var INTV := ESMDefs.four_cc("INTV")  # Integer value
	var FLTV := ESMDefs.four_cc("FLTV")  # Float value

	# Load the rest
	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == STRV:
			string_value = esm.get_h_string()
			value_type = ValueType.TYPE_STRING
		elif sub_name == INTV:
			var data := esm.get_h_t(4)
			int_value = data.decode_s32(0)
			value_type = ValueType.TYPE_INT
		elif sub_name == FLTV:
			var data := esm.get_h_t(4)
			float_value = data.decode_float(0)
			value_type = ValueType.TYPE_FLOAT
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

## Get the value as a Variant
func get_value() -> Variant:
	match value_type:
		ValueType.TYPE_STRING:
			return string_value
		ValueType.TYPE_INT:
			return int_value
		ValueType.TYPE_FLOAT:
			return float_value
	return null

func _to_string() -> String:
	return "GMST('%s' = %s)" % [record_id, get_value()]
