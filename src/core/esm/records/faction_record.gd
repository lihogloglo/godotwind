## Faction Record (FACT)
## Faction/guild definitions
## Ported from OpenMW components/esm3/loadfact.hpp
class_name FactionRecord
extends ESMRecord

const FLAG_HIDDEN: int = 0x01

var name: String
var rank_names: Array[String] = []  # Up to 10 ranks

# FADT subrecord (240 bytes)
var favorite_attributes: Array[int] = []  # 2 attributes
var rank_data: Array[Dictionary] = []     # 10 ranks
var favorite_skills: Array[int] = []      # 7 skills (-1 for none)
var is_hidden: bool

# Faction reactions (ANAM + INTV pairs)
var reactions: Dictionary = {}  # faction_id -> reaction value

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_FACT

static func get_record_type_name() -> String:
	return "Faction"

func load(esm: ESMReader) -> void:
	super.load(esm)

	name = ""
	rank_names.clear()
	favorite_attributes = [0, 0]
	rank_data.clear()
	favorite_skills = [-1, -1, -1, -1, -1, -1, -1]
	is_hidden = false
	reactions.clear()

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var FADT := ESMDefs.four_cc("FADT")
	var RNAM := ESMDefs.four_cc("RNAM")
	var ANAM := ESMDefs.four_cc("ANAM")
	var current_reaction_faction := ""

	while esm.has_more_subs():
		esm.get_sub_name()
		var sub_name := esm.get_current_sub_name()

		if sub_name == ESMDefs.SubRecordType.SREC_FNAM:
			name = esm.get_h_string()
		elif sub_name == FADT:
			_load_faction_data(esm)
		elif sub_name == RNAM:
			rank_names.append(esm.get_h_string())
		elif sub_name == ANAM:
			current_reaction_faction = esm.get_h_string()
		elif sub_name == ESMDefs.SubRecordType.SREC_INTV:
			esm.get_sub_header()
			var reaction := esm.get_s32()
			if not current_reaction_faction.is_empty():
				reactions[current_reaction_faction.to_lower()] = reaction
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_faction_data(esm: ESMReader) -> void:
	esm.get_sub_header()

	# 2 favorite attributes
	favorite_attributes[0] = esm.get_s32()
	favorite_attributes[1] = esm.get_s32()

	# 10 rank requirements
	for i in range(10):
		var rank := {
			"attribute1": esm.get_s32(),
			"attribute2": esm.get_s32(),
			"primary_skill": esm.get_s32(),
			"favoured_skill": esm.get_s32(),
			"faction_reaction": esm.get_s32(),
		}
		rank_data.append(rank)

	# 7 skills
	for i in range(7):
		favorite_skills[i] = esm.get_s32()

	is_hidden = esm.get_s32() != 0

func get_reaction(faction_id: String) -> int:
	return reactions.get(faction_id.to_lower(), 0)

func _to_string() -> String:
	return "Faction('%s', ranks=%d)" % [record_id, rank_names.size()]
