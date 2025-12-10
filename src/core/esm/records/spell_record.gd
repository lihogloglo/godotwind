## Spell Record (SPEL)
## Spells, abilities, powers, diseases, and curses
## Ported from OpenMW components/esm3/loadspel.hpp
class_name SpellRecord
extends ESMRecord

# Spell types
enum SpellType {
	SPELL = 0,    # Normal spell, costs mana
	ABILITY = 1,  # Always active ability
	BLIGHT = 2,   # Blight disease
	DISEASE = 3,  # Common disease
	CURSE = 4,    # Curse
	POWER = 5     # Power, once per day
}

# Spell flags
const FLAG_AUTOCALC: int = 0x01  # NPC auto-calc can select
const FLAG_PC_START: int = 0x02  # Player auto-calc can select
const FLAG_ALWAYS: int = 0x04    # Casting always succeeds

var name: String

# SPDT subrecord (12 bytes)
var spell_type: int
var cost: int
var flags: int

# Effects list (ENAM subrecords)
var effects: Array[Dictionary] = []

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_SPEL

static func get_record_type_name() -> String:
	return "Spell"

func load(esm: ESMReader) -> void:
	super.load(esm)

	name = ""
	spell_type = SpellType.SPELL
	cost = 0
	flags = 0
	effects.clear()

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var SPDT := ESMDefs.four_cc("SPDT")
	var ENAM := ESMDefs.four_cc("ENAM")

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_FNAM:
			name = esm.get_h_string()
		elif sub_name == SPDT:
			_load_spell_data(esm)
		elif sub_name == ENAM:
			_load_effect(esm)
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_spell_data(esm: ESMReader) -> void:
	esm.get_sub_header()
	spell_type = esm.get_s32()
	cost = esm.get_s32()
	flags = esm.get_s32()

func _load_effect(esm: ESMReader) -> void:
	esm.get_sub_header()
	var effect := {
		"effect_id": esm.get_s16(),
		"skill": esm.get_byte(),
		"attribute": esm.get_byte(),
		"range": esm.get_s32(),  # 0=self, 1=touch, 2=target
		"area": esm.get_s32(),
		"duration": esm.get_s32(),
		"magnitude_min": esm.get_s32(),
		"magnitude_max": esm.get_s32(),
	}
	effects.append(effect)

func is_autocalc() -> bool:
	return (flags & FLAG_AUTOCALC) != 0

func always_succeeds() -> bool:
	return (flags & FLAG_ALWAYS) != 0

func _to_string() -> String:
	return "Spell('%s', type=%d, cost=%d)" % [record_id, spell_type, cost]
