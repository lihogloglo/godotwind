## Enchantment Record (ENCH)
## Enchantments applied to items
## Ported from OpenMW components/esm3/loadench.hpp
class_name EnchantmentRecord
extends ESMRecord

# Enchantment types
enum EnchantType {
	CAST_ONCE = 0,      # Single use, destroyed after
	WHEN_STRIKES = 1,   # Activates on weapon hit
	WHEN_USED = 2,      # Activates when used
	CONSTANT = 3        # Always active when equipped
}

const FLAG_AUTOCALC: int = 0x01

# ENDT subrecord (16 bytes)
var enchant_type: int
var cost: int
var charge: int
var flags: int

# Effects list (ENAM subrecords)
var effects: Array[Dictionary] = []

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_ENCH

static func get_record_type_name() -> String:
	return "Enchantment"

func load(esm: ESMReader) -> void:
	super.load(esm)

	enchant_type = EnchantType.CAST_ONCE
	cost = 0
	charge = 0
	flags = 0
	effects.clear()

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var ENDT := ESMDefs.four_cc("ENDT")
	var ENAM := ESMDefs.four_cc("ENAM")

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ENDT:
			_load_enchant_data(esm)
		elif sub_name == ENAM:
			_load_effect(esm)
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_enchant_data(esm: ESMReader) -> void:
	esm.get_sub_header()
	enchant_type = esm.get_s32()
	cost = esm.get_s32()
	charge = esm.get_s32()
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
	return "Enchantment('%s', type=%d, charge=%d)" % [record_id, enchant_type, charge]
