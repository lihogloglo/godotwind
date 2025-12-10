## NPC Record (NPC_)
## Non-player characters
## Ported from OpenMW components/esm3/loadnpc.hpp
class_name NPCRecord
extends ESMRecord

# NPC flags
const FLAG_FEMALE: int = 0x01
const FLAG_ESSENTIAL: int = 0x02
const FLAG_RESPAWN: int = 0x04
const FLAG_BASE: int = 0x08  # Not used in Morrowind
const FLAG_AUTOCALC: int = 0x10

# Services flags
const SERVICE_WEAPON: int = 0x00001
const SERVICE_ARMOR: int = 0x00002
const SERVICE_CLOTHING: int = 0x00004
const SERVICE_BOOKS: int = 0x00008
const SERVICE_INGREDIENTS: int = 0x00010
const SERVICE_PICKS: int = 0x00020
const SERVICE_PROBES: int = 0x00040
const SERVICE_LIGHTS: int = 0x00080
const SERVICE_APPARATUS: int = 0x00100
const SERVICE_REPAIR: int = 0x00200
const SERVICE_MISC: int = 0x00400
const SERVICE_SPELLS: int = 0x00800
const SERVICE_MAGIC_ITEMS: int = 0x01000
const SERVICE_POTIONS: int = 0x02000
const SERVICE_TRAINING: int = 0x04000
const SERVICE_SPELLMAKING: int = 0x08000
const SERVICE_ENCHANTING: int = 0x10000
const SERVICE_REPAIR_SERVICE: int = 0x20000

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

# Travel destination
class TravelDest:
	var pos_x: float
	var pos_y: float
	var pos_z: float
	var rot_x: float
	var rot_y: float
	var rot_z: float
	var cell_name: String

# Basic info
var name: String
var model: String
var script_id: String
var race_id: String
var class_id: String
var faction_id: String
var head_id: String
var hair_id: String
var npc_flags: int

# Stats (NPDT subrecord - 52 bytes or 12 bytes for autocalc)
var level: int
var attributes: Array[int]  # 8 attributes
var skills: Array[int]      # 27 skills
var health: int
var mana: int
var fatigue: int
var disposition: int
var reputation: int
var rank: int
var gold: int

# AI
var ai_data: AIData

# Inventory, spells, travel
var inventory: Array[InventoryItem]
var spells: Array[String]  # Spell IDs
var travel_destinations: Array[TravelDest]

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_NPC_

static func get_record_type_name() -> String:
	return "NPC"

func load(esm: ESMReader) -> void:
	super.load(esm)

	# Reset defaults
	name = ""
	model = ""
	script_id = ""
	race_id = ""
	class_id = ""
	faction_id = ""
	head_id = ""
	hair_id = ""
	npc_flags = 0
	level = 1
	attributes = []
	attributes.resize(8)
	attributes.fill(0)
	skills = []
	skills.resize(27)
	skills.fill(0)
	health = 0
	mana = 0
	fatigue = 0
	disposition = 0
	reputation = 0
	rank = 0
	gold = 0
	ai_data = null
	inventory = []
	spells = []
	travel_destinations = []

	# NAME - object ID
	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	# Pre-compute FourCC values
	var RNAM := ESMDefs.four_cc("RNAM")
	var CNAM := ESMDefs.four_cc("CNAM")
	var ANAM := ESMDefs.four_cc("ANAM")
	var BNAM := ESMDefs.four_cc("BNAM")
	var KNAM := ESMDefs.four_cc("KNAM")
	var NPDT := ESMDefs.four_cc("NPDT")
	var FLAG := ESMDefs.four_cc("FLAG")
	var NPCO := ESMDefs.four_cc("NPCO")
	var NPCS := ESMDefs.four_cc("NPCS")
	var AIDT := ESMDefs.four_cc("AIDT")
	var DODT := ESMDefs.four_cc("DODT")
	var DNAM := ESMDefs.four_cc("DNAM")
	var AI_W := ESMDefs.four_cc("AI_W")
	var AI_T := ESMDefs.four_cc("AI_T")
	var AI_F := ESMDefs.four_cc("AI_F")
	var AI_E := ESMDefs.four_cc("AI_E")
	var AI_A := ESMDefs.four_cc("AI_A")

	var current_dest: TravelDest = null

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
		elif sub_name == RNAM:
			race_id = esm.get_h_string()
		elif sub_name == CNAM:
			class_id = esm.get_h_string()
		elif sub_name == ANAM:
			faction_id = esm.get_h_string()
		elif sub_name == BNAM:
			head_id = esm.get_h_string()
		elif sub_name == KNAM:
			hair_id = esm.get_h_string()
		elif sub_name == NPDT:
			_load_npc_data(esm)
		elif sub_name == FLAG:
			var data := esm.get_h_t(4)
			npc_flags = data.decode_s32(0)
		elif sub_name == NPCO:
			_load_inventory_item(esm)
		elif sub_name == NPCS:
			var spell_id := esm.get_h_string()
			spells.append(spell_id.strip_edges())
		elif sub_name == AIDT:
			_load_ai_data(esm)
		elif sub_name == DODT:
			# Travel destination position
			if current_dest != null:
				travel_destinations.append(current_dest)
			current_dest = TravelDest.new()
			_load_travel_dest(esm, current_dest)
		elif sub_name == DNAM:
			# Travel destination cell name
			if current_dest != null:
				current_dest.cell_name = esm.get_h_string()
			else:
				esm.skip_h_sub()
		elif sub_name == AI_W or sub_name == AI_T or sub_name == AI_F or sub_name == AI_E or sub_name == AI_A:
			# AI packages - skip for now
			esm.skip_h_sub()
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

	# Don't forget the last destination
	if current_dest != null:
		travel_destinations.append(current_dest)

func _load_npc_data(esm: ESMReader) -> void:
	esm.get_sub_header()
	var size := esm.get_sub_size()

	if size == 52:
		# Full NPC data
		level = esm.get_s16()

		# 8 attributes
		for i in range(8):
			attributes[i] = esm.get_byte()

		# 27 skills
		for i in range(27):
			skills[i] = esm.get_byte()

		# Skip 1 byte padding
		esm.get_byte()

		health = esm.get_u16()
		mana = esm.get_u16()
		fatigue = esm.get_u16()

		disposition = esm.get_byte()
		reputation = esm.get_byte()
		rank = esm.get_byte()

		# Skip 1 byte padding
		esm.get_byte()

		gold = esm.get_s32()
	elif size == 12:
		# Autocalculated NPC
		level = esm.get_s16()
		disposition = esm.get_byte()
		reputation = esm.get_byte()
		rank = esm.get_byte()
		# Skip 3 bytes padding
		esm.get_byte()
		esm.get_byte()
		esm.get_byte()
		gold = esm.get_s32()
	else:
		# Unknown size, skip
		esm.skip(size)

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

func _load_travel_dest(esm: ESMReader, dest: TravelDest) -> void:
	dest.pos_x = esm.get_float()
	dest.pos_y = esm.get_float()
	dest.pos_z = esm.get_float()
	dest.rot_x = esm.get_float()
	dest.rot_y = esm.get_float()
	dest.rot_z = esm.get_float()

## Check NPC flags
func is_female() -> bool:
	return (npc_flags & FLAG_FEMALE) != 0

func is_essential() -> bool:
	return (npc_flags & FLAG_ESSENTIAL) != 0

func does_respawn() -> bool:
	return (npc_flags & FLAG_RESPAWN) != 0

func is_autocalc() -> bool:
	return (npc_flags & FLAG_AUTOCALC) != 0

## Check if NPC offers a service
func offers_service(service: int) -> bool:
	if ai_data == null:
		return false
	return (ai_data.services & service) != 0

func _to_string() -> String:
	var gender := "F" if is_female() else "M"
	return "NPC('%s', '%s', %s, L%d)" % [record_id, name, gender, level]
