## Potion Record (ALCH)
## Alchemy potions and beverages
## Ported from OpenMW components/esm3/loadalch.hpp
class_name PotionRecord
extends ESMRecord

const FLAG_AUTOCALC: int = 0x01

var name: String
var model: String
var icon: String
var script_id: String

# ALDT subrecord (12 bytes)
var weight: float
var value: int
var flags: int

# Effects list (ENAM subrecords)
var effects: Array[Dictionary] = []

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_ALCH

static func get_record_type_name() -> String:
	return "Potion"

func load(esm: ESMReader) -> void:
	super.load(esm)

	name = ""
	model = ""
	icon = ""
	script_id = ""
	weight = 0.0
	value = 0
	flags = 0
	effects.clear()

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var ALDT := ESMDefs.four_cc("ALDT")
	var ENAM := ESMDefs.four_cc("ENAM")
	var TEXT := ESMDefs.four_cc("TEXT")

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_MODL:
			model = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_FNAM:
			name = esm.get_h_string()
		elif sub_name == TEXT:
			icon = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_SCRI:
			script_id = esm.get_h_string()
		elif sub_name == ALDT:
			_load_potion_data(esm)
		elif sub_name == ENAM:
			_load_effect(esm)
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_potion_data(esm: ESMReader) -> void:
	esm.get_sub_header()
	weight = esm.get_float()
	value = esm.get_s32()
	flags = esm.get_s32()

func _load_effect(esm: ESMReader) -> void:
	esm.get_sub_header()
	var effect := {
		"effect_id": esm.get_s16(),
		"skill": esm.get_byte(),
		"attribute": esm.get_byte(),
		"range": esm.get_s32(),
		"area": esm.get_s32(),
		"duration": esm.get_s32(),
		"magnitude_min": esm.get_s32(),
		"magnitude_max": esm.get_s32(),
	}
	effects.append(effect)

func is_autocalc() -> bool:
	return (flags & FLAG_AUTOCALC) != 0

func _to_string() -> String:
	return "Potion('%s', value=%d)" % [record_id, value]
