## Weapon Record (WEAP)
## Weapons include melee weapons, bows, crossbows, and ammunition
## Ported from OpenMW components/esm3/loadweap.hpp
class_name WeaponRecord
extends ESMRecord

# Weapon types
enum WeaponType {
	SHORT_BLADE_ONE_HAND = 0,
	LONG_BLADE_ONE_HAND = 1,
	LONG_BLADE_TWO_HAND = 2,
	BLUNT_ONE_HAND = 3,
	BLUNT_TWO_CLOSE = 4,
	BLUNT_TWO_WIDE = 5,
	SPEAR_TWO_WIDE = 6,
	AXE_ONE_HAND = 7,
	AXE_TWO_HAND = 8,
	MARKSMAN_BOW = 9,
	MARKSMAN_CROSSBOW = 10,
	MARKSMAN_THROWN = 11,
	ARROW = 12,
	BOLT = 13,
}

# Weapon flags
const FLAG_MAGICAL: int = 0x01
const FLAG_SILVER: int = 0x02

# Basic info
var name: String
var model: String
var icon: String
var script_id: String
var enchant_id: String

# WPDT subrecord (32 bytes)
var weight: float
var value: int
var weapon_type: int
var health: int
var speed: float
var reach: float
var enchant_points: int
var chop_min: int
var chop_max: int
var slash_min: int
var slash_max: int
var thrust_min: int
var thrust_max: int
var flags: int

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_WEAP

static func get_record_type_name() -> String:
	return "Weapon"

func load(esm: ESMReader) -> void:
	super.load(esm)

	# Reset defaults
	name = ""
	model = ""
	icon = ""
	script_id = ""
	enchant_id = ""
	weight = 0.0
	value = 0
	weapon_type = 0
	health = 0
	speed = 1.0
	reach = 1.0
	enchant_points = 0
	chop_min = 0
	chop_max = 0
	slash_min = 0
	slash_max = 0
	thrust_min = 0
	thrust_max = 0
	flags = 0

	# NAME - object ID
	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	# Pre-compute FourCC values
	var WPDT := ESMDefs.four_cc("WPDT")
	var ENAM := ESMDefs.four_cc("ENAM")

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
		elif sub_name == WPDT:
			_load_weapon_data(esm)
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_weapon_data(esm: ESMReader) -> void:
	esm.get_sub_header()

	weight = esm.get_float()
	value = esm.get_s32()
	weapon_type = esm.get_s16()
	health = esm.get_u16()
	speed = esm.get_float()
	reach = esm.get_float()
	enchant_points = esm.get_u16()
	chop_min = esm.get_byte()
	chop_max = esm.get_byte()
	slash_min = esm.get_byte()
	slash_max = esm.get_byte()
	thrust_min = esm.get_byte()
	thrust_max = esm.get_byte()
	flags = esm.get_s32()

## Check if weapon is magical
func is_magical() -> bool:
	return (flags & FLAG_MAGICAL) != 0

## Check if weapon is silver
func is_silver() -> bool:
	return (flags & FLAG_SILVER) != 0

## Check if this is a ranged weapon
func is_ranged() -> bool:
	return weapon_type >= WeaponType.MARKSMAN_BOW and weapon_type <= WeaponType.MARKSMAN_THROWN

## Check if this is ammunition
func is_ammo() -> bool:
	return weapon_type == WeaponType.ARROW or weapon_type == WeaponType.BOLT

## Check if this is a two-handed weapon
func is_two_handed() -> bool:
	return weapon_type in [
		WeaponType.LONG_BLADE_TWO_HAND,
		WeaponType.BLUNT_TWO_CLOSE,
		WeaponType.BLUNT_TWO_WIDE,
		WeaponType.SPEAR_TWO_WIDE,
		WeaponType.AXE_TWO_HAND,
		WeaponType.MARKSMAN_BOW,
		WeaponType.MARKSMAN_CROSSBOW,
	]

## Get the real enchant value (stored as x10)
func get_enchant_value() -> float:
	return enchant_points / 10.0

func _to_string() -> String:
	return "Weapon('%s', type=%d, damage=%d-%d)" % [record_id, weapon_type, chop_min, chop_max]
