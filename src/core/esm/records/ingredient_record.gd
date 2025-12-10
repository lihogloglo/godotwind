## Ingredient Record (INGR)
## Alchemy ingredients with magical properties
## Ported from OpenMW components/esm3/loadingr.hpp
class_name IngredientRecord
extends ESMRecord

var name: String
var model: String
var icon: String
var script_id: String

# IRDT subrecord (56 bytes)
var weight: float
var value: int
var effect_ids: Array[int] = []      # 4 effects (-1 for none)
var skill_ids: Array[int] = []       # 4 skills related to effects
var attribute_ids: Array[int] = []   # 4 attributes related to effects

static func get_record_type() -> int:
	return ESMDefs.RecordType.REC_INGR

static func get_record_type_name() -> String:
	return "Ingredient"

func load(esm: ESMReader) -> void:
	super.load(esm)

	name = ""
	model = ""
	icon = ""
	script_id = ""
	weight = 0.0
	value = 0
	effect_ids = [-1, -1, -1, -1]
	skill_ids = [-1, -1, -1, -1]
	attribute_ids = [-1, -1, -1, -1]

	record_id = esm.get_hn_string(ESMDefs.SubRecordType.SREC_NAME)

	var IRDT := ESMDefs.four_cc("IRDT")

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
		elif sub_name == IRDT:
			_load_ingredient_data(esm)
		elif sub_name == ESMDefs.SubRecordType.SREC_DELE:
			esm.skip_h_sub()
			is_deleted = true
		else:
			esm.skip_h_sub()

func _load_ingredient_data(esm: ESMReader) -> void:
	esm.get_sub_header()
	weight = esm.get_float()
	value = esm.get_s32()

	# 4 effect IDs
	for i in range(4):
		effect_ids[i] = esm.get_s32()

	# 4 skill IDs
	for i in range(4):
		skill_ids[i] = esm.get_s32()

	# 4 attribute IDs
	for i in range(4):
		attribute_ids[i] = esm.get_s32()

func get_effect_count() -> int:
	var count := 0
	for effect in effect_ids:
		if effect >= 0:
			count += 1
	return count

func _to_string() -> String:
	return "Ingredient('%s', effects=%d)" % [record_id, get_effect_count()]
