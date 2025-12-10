## Script Record (SCPT)
## Morrowind script definitions
## Ported from OpenMW components/esm3/loadscpt.hpp
class_name ScriptRecord
extends ESMRecord

# SCHD subrecord (52 bytes)
var num_shorts: int
var num_longs: int
var num_floats: int
var script_data_size: int
var local_var_size: int

# Variable names (SCVR subrecord)
var local_vars: Array[String] = []

# Compiled script data (SCDT subrecord)
var compiled_data: PackedByteArray

# Script source text (SCTX subrecord)
var source_text: String

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_SCPT

static func get_record_type_name() -> String:
	return "Script"

func load(esm: ESMReader) -> void:
	super.load(esm)

	num_shorts = 0
	num_longs = 0
	num_floats = 0
	script_data_size = 0
	local_var_size = 0
	local_vars.clear()
	compiled_data = PackedByteArray()
	source_text = ""

	var SCHD := ESMDefs.four_cc("SCHD")
	var SCVR := ESMDefs.four_cc("SCVR")
	var SCDT := ESMDefs.four_cc("SCDT")
	var SCTX := ESMDefs.four_cc("SCTX")

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == SCHD:
			_load_header(esm)
		elif sub_name == SCVR:
			_load_variables(esm)
		elif sub_name == SCDT:
			esm.get_sub_header()
			compiled_data = esm.get_exact(esm.get_sub_size())
		elif sub_name == SCTX:
			source_text = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_header(esm: ESMReader) -> void:
	esm.get_sub_header()
	# Script name is 32 bytes
	record_id = esm.get_string(32)
	num_shorts = esm.get_s32()
	num_longs = esm.get_s32()
	num_floats = esm.get_s32()
	script_data_size = esm.get_s32()
	local_var_size = esm.get_s32()

func _load_variables(esm: ESMReader) -> void:
	esm.get_sub_header()
	var size := esm.get_sub_size()
	var data := esm.get_exact(size)

	# Parse null-separated variable names
	var current := ""
	for byte in data:
		if byte == 0:
			if not current.is_empty():
				local_vars.append(current)
				current = ""
		else:
			current += char(byte)
	if not current.is_empty():
		local_vars.append(current)

func get_total_locals() -> int:
	return num_shorts + num_longs + num_floats

func _to_string() -> String:
	return "Script('%s', locals=%d)" % [record_id, get_total_locals()]
