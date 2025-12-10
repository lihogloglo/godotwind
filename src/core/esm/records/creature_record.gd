## Creature Record (CREA)
## Creatures include monsters, animals, and other non-humanoid entities
## Ported from OpenMW components/esm3/loadcrea.hpp
class_name CreatureRecord
extends ESMRecord

# Creature types
enum CreatureType {
	CREATURE = 0,
	DAEDRA = 1,
	UNDEAD = 2,
	HUMANOID = 3,
}

# Creature flags
const FLAG_BIPEDAL: int = 0x01
const FLAG_RESPAWN: int = 0x02
const FLAG_WEAPON_AND_SHIELD: int = 0x04
const FLAG_BASE: int = 0x08
const FLAG_SWIMS: int = 0x10
const FLAG_FLIES: int = 0x20
const FLAG_WALKS: int = 0x40
const FLAG_ESSENTIAL: int = 0x80

# Inventory item
class InventoryItem:
	var count: int
	var item_id: String

# AI data
class AIData:
	var hello: int       # Greeting distance
	var fight: int       # Fight probability [0-100]
	var flee: int        # Flee probability [0-100]
	var alarm: int       # Alarm probability [0-100]
	var services: int    # Services bitmask

# Basic info
var name: String
var model: String
var script_id: String
var original_id: String  # Base creature for modifications
var creature_flags: int
var scale: float

# Stats (NPDT subrecord - 96 bytes)
var creature_type: int
var level: int
var attributes: Array[int]  # 8 attributes (32-bit each)
var health: int
var mana: int
var fatigue: int
var soul: int
var combat: int
var magic: int
var stealth: int
var attack_min: Array[int]  # 3 attack min values
var attack_max: Array[int]  # 3 attack max values
var gold: int

# AI
var ai_data: AIData

# Inventory and spells
var inventory: Array[InventoryItem]
var spells: Array[String]  # Spell IDs

# Sound generator type
var sound_gen_type: int

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_CREA

static func get_record_type_name() -> String:
	return "Creature"

func load(esm: ESMReader) -> void:
	super.load(esm)

	# Reset defaults
	name = ""
	model = ""
	script_id = ""
	original_id = ""
	creature_flags = 0
	scale = 1.0
	creature_type = 0
	level = 1
	attributes = []
	attributes.resize(8)
	attributes.fill(0)
	health = 0
	mana = 0
	fatigue = 0
	soul = 0
	combat = 0
	magic = 0
	stealth = 0
	attack_min = [0, 0, 0]
	attack_max = [0, 0, 0]
	gold = 0
	ai_data = null
	inventory = []
	spells = []
	sound_gen_type = 0

	# NAME - object ID
	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	# Pre-compute FourCC values
	var NPDT := ESMDefs.four_cc("NPDT")
	var FLAG := ESMDefs.four_cc("FLAG")
	var XSCL := ESMDefs.four_cc("XSCL")
	var NPCO := ESMDefs.four_cc("NPCO")
	var NPCS := ESMDefs.four_cc("NPCS")
	var AIDT := ESMDefs.four_cc("AIDT")
	var CNAM := ESMDefs.four_cc("CNAM")
	var AI_W := ESMDefs.four_cc("AI_W")
	var AI_T := ESMDefs.four_cc("AI_T")
	var AI_F := ESMDefs.four_cc("AI_F")
	var AI_E := ESMDefs.four_cc("AI_E")
	var AI_A := ESMDefs.four_cc("AI_A")

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
		elif sub_name == CNAM:
			original_id = esm.get_h_string()
		elif sub_name == NPDT:
			_load_creature_data(esm)
		elif sub_name == FLAG:
			var data := esm.get_h_t(4)
			creature_flags = data.decode_s32(0)
		elif sub_name == XSCL:
			var data := esm.get_h_t(4)
			scale = data.decode_float(0)
		elif sub_name == NPCO:
			_load_inventory_item(esm)
		elif sub_name == NPCS:
			var spell_id := esm.get_h_string()
			spells.append(spell_id.strip_edges())
		elif sub_name == AIDT:
			_load_ai_data(esm)
		elif sub_name == AI_W or sub_name == AI_T or sub_name == AI_F or sub_name == AI_E or sub_name == AI_A:
			# AI packages - skip for now
			esm.skip_h_sub()
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_creature_data(esm: ESMReader) -> void:
	esm.get_sub_header()

	creature_type = esm.get_s32()
	level = esm.get_s32()

	# 8 attributes (32-bit each)
	for i in range(8):
		attributes[i] = esm.get_s32()

	health = esm.get_s32()
	mana = esm.get_s32()
	fatigue = esm.get_s32()
	soul = esm.get_s32()
	combat = esm.get_s32()
	magic = esm.get_s32()
	stealth = esm.get_s32()

	# 3 attacks (min/max pairs)
	for i in range(3):
		attack_min[i] = esm.get_s32()
		attack_max[i] = esm.get_s32()

	gold = esm.get_s32()

func _load_inventory_item(esm: ESMReader) -> void:
	esm.get_sub_header()

	var item := InventoryItem.new()
	item.count = esm.get_s32()
	item.item_id = esm.get_string(32).strip_edges()
	inventory.append(item)

func _load_ai_data(esm: ESMReader) -> void:
	esm.get_sub_header()

	ai_data = AIData.new()
	ai_data.hello = esm.get_u16()
	ai_data.fight = esm.get_byte()
	ai_data.flee = esm.get_byte()
	ai_data.alarm = esm.get_byte()
	# Skip 3 bytes padding
	esm.get_byte()
	esm.get_byte()
	esm.get_byte()
	ai_data.services = esm.get_s32()

## Check creature flags
func is_bipedal() -> bool:
	return (creature_flags & FLAG_BIPEDAL) != 0

func does_respawn() -> bool:
	return (creature_flags & FLAG_RESPAWN) != 0

func has_weapon_and_shield() -> bool:
	return (creature_flags & FLAG_WEAPON_AND_SHIELD) != 0

func can_swim() -> bool:
	return (creature_flags & FLAG_SWIMS) != 0

func can_fly() -> bool:
	return (creature_flags & FLAG_FLIES) != 0

func can_walk() -> bool:
	return (creature_flags & FLAG_WALKS) != 0

func is_essential() -> bool:
	return (creature_flags & FLAG_ESSENTIAL) != 0

## Get creature type name
func get_creature_type_name() -> String:
	match creature_type:
		CreatureType.CREATURE: return "Creature"
		CreatureType.DAEDRA: return "Daedra"
		CreatureType.UNDEAD: return "Undead"
		CreatureType.HUMANOID: return "Humanoid"
		_: return "Unknown"

func _to_string() -> String:
	return "Creature('%s', '%s', %s, L%d)" % [record_id, name, get_creature_type_name(), level]
