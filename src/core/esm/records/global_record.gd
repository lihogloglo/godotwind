## Global Variable Record (GLOB)
## Global variables used by scripts
## Ported from OpenMW components/esm3/loadglob.cpp
class_name GlobalRecord
extends ESMRecord

enum ValueType {
	TYPE_SHORT = ord('s'),
	TYPE_LONG = ord('l'),
	TYPE_FLOAT = ord('f')
}

var value_type: int  # 's', 'l', or 'f'
var value: float     # Stored as float regardless of type

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_GLOB

static func get_record_type_name() -> String:
	return "Global"

func load(esm: ESMReader) -> void:
	super.load(esm)

	# Reset defaults
	value_type = 0
	value = 0.0

	# NAME - variable name
	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	# Pre-compute FourCC values
	var FNAM := ESMDefs.four_cc("FNAM")  # Type (string: "s", "l", or "f")
	var FLTV := ESMDefs.four_cc("FLTV")  # Float value

	# Load the rest
	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == FNAM:
			# FNAM is a string containing "s", "l", or "f"
			var type_str := esm.get_h_string()
			if type_str.length() > 0:
				value_type = type_str.unicode_at(0)
		elif sub_name == FLTV:
			var data := esm.get_h_t(4)
			value = data.decode_float(0)
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

## Get value as integer (for short/long types)
func get_int_value() -> int:
	return int(value)

## Get value as float
func get_float_value() -> float:
	return value

func _to_string() -> String:
	var type_char := char(value_type) if value_type > 0 else "?"
	return "GLOB('%s' [%s] = %s)" % [record_id, type_char, value]
