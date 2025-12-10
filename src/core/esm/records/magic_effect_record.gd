## Magic Effect Record (MGEF)
## Magic effect definitions (hardcoded IDs 0-136)
## Ported from OpenMW components/esm3/loadmgef.hpp
class_name MagicEffectRecord
extends ESMRecord

# Effect flags
const FLAG_TARGET_SKILL: int = 0x01
const FLAG_TARGET_ATTR: int = 0x02
const FLAG_NO_DURATION: int = 0x04
const FLAG_NO_MAGNITUDE: int = 0x08
const FLAG_HARMFUL: int = 0x10
const FLAG_CONTINUOUS_VFX: int = 0x20
const FLAG_CAST_SELF: int = 0x40
const FLAG_CAST_TOUCH: int = 0x80
const FLAG_CAST_TARGET: int = 0x100
const FLAG_SPELLMAKING: int = 0x200
const FLAG_ENCHANTING: int = 0x400
const FLAG_NEGATIVE_LIGHTING: int = 0x800

var effect_index: int  # Hardcoded effect ID
var icon: String
var particle_texture: String
var cast_sound: String
var bolt_sound: String
var hit_sound: String
var area_sound: String

# MEDT subrecord (36 bytes)
var school: int       # Magic school (0-5)
var base_cost: float
var flags: int
var red: int
var green: int
var blue: int
var speed: float
var size: float
var size_cap: float

var description: String

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_MGEF

static func get_record_type_name() -> String:
	return "MagicEffect"

func load(esm: ESMReader) -> void:
	super.load(esm)

	effect_index = 0
	icon = ""
	particle_texture = ""
	cast_sound = ""
	bolt_sound = ""
	hit_sound = ""
	area_sound = ""
	school = 0
	base_cost = 0.0
	flags = 0
	red = 0
	green = 0
	blue = 0
	speed = 1.0
	size = 1.0
	size_cap = 0.0
	description = ""

	var MEDT := ESMDefs.four_cc("MEDT")
	var ITEX := ESMDefs.SubRecordType.SREC_ITEX
	var PTEX := ESMDefs.four_cc("PTEX")
	var CVFX := ESMDefs.four_cc("CVFX")
	var BVFX := ESMDefs.four_cc("BVFX")
	var HVFX := ESMDefs.four_cc("HVFX")
	var AVFX := ESMDefs.four_cc("AVFX")
	var DESC := ESMDefs.four_cc("DESC")

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_INDX:
			esm.get_sub_header()
			effect_index = esm.get_s32()
			record_id = str(effect_index)
		elif sub_name == MEDT:
			_load_effect_data(esm)
		elif sub_name == ITEX:
			icon = esm.get_h_string()
		elif sub_name == PTEX:
			particle_texture = esm.get_h_string()
		elif sub_name == CVFX:
			cast_sound = esm.get_h_string()
		elif sub_name == BVFX:
			bolt_sound = esm.get_h_string()
		elif sub_name == HVFX:
			hit_sound = esm.get_h_string()
		elif sub_name == AVFX:
			area_sound = esm.get_h_string()
		elif sub_name == DESC:
			description = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_effect_data(esm: ESMReader) -> void:
	esm.get_sub_header()
	school = esm.get_s32()
	base_cost = esm.get_float()
	flags = esm.get_s32()
	red = esm.get_s32()
	green = esm.get_s32()
	blue = esm.get_s32()
	speed = esm.get_float()
	size = esm.get_float()
	size_cap = esm.get_float()

func is_harmful() -> bool:
	return (flags & FLAG_HARMFUL) != 0

func can_spellmaking() -> bool:
	return (flags & FLAG_SPELLMAKING) != 0

func can_enchanting() -> bool:
	return (flags & FLAG_ENCHANTING) != 0

func get_color() -> Color:
	return Color(red / 255.0, green / 255.0, blue / 255.0)

func _to_string() -> String:
	return "MagicEffect('%s', school=%d)" % [record_id, school]
