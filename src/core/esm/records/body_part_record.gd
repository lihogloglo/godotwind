## Body Part Record (BODY)
## Body part definitions for NPCs/creatures
## Ported from OpenMW components/esm3/loadbody.hpp
class_name BodyPartRecord
extends ESMRecord

# Body part types
enum PartType {
	HEAD = 0,
	HAIR = 1,
	NECK = 2,
	CHEST = 3,
	GROIN = 4,
	HAND = 5,
	WRIST = 6,
	FOREARM = 7,
	UPPER_ARM = 8,
	FOOT = 9,
	ANKLE = 10,
	KNEE = 11,
	UPPER_LEG = 12,
	CLAVICLE = 13,
	TAIL = 14
}

# Body part flags
const FLAG_FEMALE: int = 0x01
const FLAG_PLAYABLE: int = 0x02

# Mesh types
enum MeshType {
	SKIN = 0,
	CLOTHING = 1,
	ARMOR = 2
}

var model: String

# BYDT subrecord (4 bytes)
var part_type: int
var is_vampire: bool
var flags: int
var mesh_type: int

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_BODY

static func get_record_type_name() -> String:
	return "BodyPart"

func load(esm: ESMReader) -> void:
	super.load(esm)

	model = ""
	part_type = PartType.HEAD
	is_vampire = false
	flags = 0
	mesh_type = MeshType.SKIN

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var BYDT := ESMDefs.four_cc("BYDT")

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_MODL:
			model = esm.get_h_string()
		elif sub_name == BYDT:
			esm.get_sub_header()
			part_type = esm.get_byte()
			is_vampire = esm.get_byte() != 0
			flags = esm.get_byte()
			mesh_type = esm.get_byte()
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func is_female() -> bool:
	return (flags & FLAG_FEMALE) != 0

func is_playable() -> bool:
	return (flags & FLAG_PLAYABLE) != 0

func _to_string() -> String:
	return "BodyPart('%s', type=%d)" % [record_id, part_type]
