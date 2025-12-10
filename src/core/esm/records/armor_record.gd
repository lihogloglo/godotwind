## Armor Record (ARMO)
## Armor pieces that can be equipped
## Ported from OpenMW components/esm3/loadarmo.hpp
class_name ArmorRecord
extends ESMRecord

# Armor types (body slots)
enum ArmorType {
	HELMET = 0,
	CUIRASS = 1,
	L_PAULDRON = 2,
	R_PAULDRON = 3,
	GREAVES = 4,
	BOOTS = 5,
	L_GAUNTLET = 6,
	R_GAUNTLET = 7,
	SHIELD = 8,
	L_BRACER = 9,
	R_BRACER = 10,
}

# Body part reference for rendering
class PartReference:
	var part: int        # PartReferenceType
	var male_id: String  # Male body part ID
	var female_id: String  # Female body part ID

# Basic info
var name: String
var model: String
var icon: String
var script_id: String
var enchant_id: String

# AODT subrecord (24 bytes)
var armor_type: int
var weight: float
var value: int
var health: int
var enchant_points: int
var armor_rating: int

# Body parts
var parts: Array[PartReference]

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_ARMO

static func get_record_type_name() -> String:
	return "Armor"

func load(esm: ESMReader) -> void:
	super.load(esm)

	# Reset defaults
	name = ""
	model = ""
	icon = ""
	script_id = ""
	enchant_id = ""
	armor_type = 0
	weight = 0.0
	value = 0
	health = 0
	enchant_points = 0
	armor_rating = 0
	parts = []

	# NAME - object ID
	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	# Pre-compute FourCC values
	var AODT := ESMDefs.four_cc("AODT")
	var ENAM := ESMDefs.four_cc("ENAM")
	var INDX := ESMDefs.four_cc("INDX")
	var BNAM := ESMDefs.four_cc("BNAM")
	var CNAM := ESMDefs.four_cc("CNAM")

	var current_part: PartReference = null

	# Load the rest
	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_MODL:
			model = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_FNAM:
			name = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_ITEX:
			icon = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_SCRI:
			script_id = esm.get_h_string()
		elif sub_name == ENAM:
			enchant_id = esm.get_h_string()
		elif sub_name == AODT:
			_load_armor_data(esm)
		elif sub_name == INDX:
			# Start of a new body part reference
			if current_part != null:
				parts.append(current_part)
			current_part = PartReference.new()
			var data := esm.get_h_t(1)
			current_part.part = data[0]
		elif sub_name == BNAM:
			# Male body part
			if current_part != null:
				current_part.male_id = esm.get_h_string()
			else:
				esm.skip_h_sub()
		elif sub_name == CNAM:
			# Female body part
			if current_part != null:
				current_part.female_id = esm.get_h_string()
			else:
				esm.skip_h_sub()
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

	# Don't forget the last part
	if current_part != null:
		parts.append(current_part)

func _load_armor_data(esm: ESMReader) -> void:
	esm.get_sub_header()

	armor_type = esm.get_s32()
	weight = esm.get_float()
	value = esm.get_s32()
	health = esm.get_s32()
	enchant_points = esm.get_s32()
	armor_rating = esm.get_s32()

## Get the real enchant value (stored as x10)
func get_enchant_value() -> float:
	return enchant_points / 10.0

## Get armor type name
func get_armor_type_name() -> String:
	match armor_type:
		ArmorType.HELMET: return "Helmet"
		ArmorType.CUIRASS: return "Cuirass"
		ArmorType.L_PAULDRON: return "Left Pauldron"
		ArmorType.R_PAULDRON: return "Right Pauldron"
		ArmorType.GREAVES: return "Greaves"
		ArmorType.BOOTS: return "Boots"
		ArmorType.L_GAUNTLET: return "Left Gauntlet"
		ArmorType.R_GAUNTLET: return "Right Gauntlet"
		ArmorType.SHIELD: return "Shield"
		ArmorType.L_BRACER: return "Left Bracer"
		ArmorType.R_BRACER: return "Right Bracer"
		_: return "Unknown"

func _to_string() -> String:
	return "Armor('%s', %s, AR=%d)" % [record_id, get_armor_type_name(), armor_rating]
