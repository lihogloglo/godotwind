## MWDialogueFilter — Morrowind's 4-step dialogue INFO matching algorithm
##
## Morrowind-specific translation layer. Implements OpenMW's filter.cpp logic:
##   Step 1: testActor — actor ID, race, class, faction+rank, gender
##   Step 2: testPlayer — PC faction+rank, current cell (prefix match)
##   Step 3: testSelectStructs — all SCVR conditions
##   Step 4: testDisposition — NPC disposition >= threshold
##
## First matching INFO wins. ESM load order = priority order.
## Assumption: dialogue_infos arrays are in ESM load order (valid for base MW).
class_name MWDialogueFilter
extends RefCounted

const MWConditionParserScript := preload("res://src/core/dialogue/morrowind/mw_condition_parser.gd")
const MWDialogueFunctionsScript := preload("res://src/core/dialogue/morrowind/mw_dialogue_functions.gd")


## Search a topic's INFO list for the first matching entry
## Returns the matching DialogueInfoRecord or null
static func search(topic_id: String, npc: NPCRecord, context: MWDialogueContext) -> DialogueInfoRecord:
	var infos: Array = ESMManager.get_dialogue_infos(topic_id)
	if infos.is_empty():
		return null

	for info: DialogueInfoRecord in infos:
		if info.is_deleted:
			continue
		if _test_actor(info, npc) and _test_player(info, npc, context) and _test_select_structs(info, npc, context) and _test_disposition(info, npc, context):
			return info

	return null


## Search with disposition fallback — returns {info, refused} dict
## If conditions 1-3 pass but disposition fails, sets refused=true
static func search_with_refusal(topic_id: String, npc: NPCRecord, context: MWDialogueContext) -> Dictionary:
	var infos: Array = ESMManager.get_dialogue_infos(topic_id)
	if infos.is_empty():
		return {"info": null, "refused": false}

	var refused := false

	for info: DialogueInfoRecord in infos:
		if info.is_deleted:
			continue
		if not _test_actor(info, npc):
			continue
		if not _test_player(info, npc, context):
			continue
		if not _test_select_structs(info, npc, context):
			continue
		if not _test_disposition(info, npc, context):
			refused = true
			continue
		return {"info": info, "refused": false}

	return {"info": null, "refused": refused}


## Relaxed search: skips SCVR conditions (for testing when game state is incomplete)
## Still checks actor, player, and disposition filters
static func search_relaxed(topic_id: String, npc: NPCRecord, context: MWDialogueContext) -> DialogueInfoRecord:
	var infos: Array = ESMManager.get_dialogue_infos(topic_id)
	if infos.is_empty():
		return null

	for info: DialogueInfoRecord in infos:
		if info.is_deleted:
			continue
		if _test_actor(info, npc) and _test_player(info, npc, context) and _test_disposition(info, npc, context):
			return info

	return null


## Debug search: logs why each INFO was rejected (use sparingly — verbose)
static func debug_search(topic_id: String, npc: NPCRecord, context: MWDialogueContext, max_log: int = 5) -> DialogueInfoRecord:
	var infos: Array = ESMManager.get_dialogue_infos(topic_id)
	Log.info("dialogue", "DEBUG: Searching '%s' for %s (%d INFOs)" % [topic_id, npc.record_id, infos.size()])

	var logged := 0
	for info: DialogueInfoRecord in infos:
		if info.is_deleted:
			continue
		var actor_ok := _test_actor(info, npc)
		var player_ok := _test_player(info, npc, context)
		var select_ok := _test_select_structs(info, npc, context)
		var disp_ok: bool = context.disposition >= info.disposition

		if actor_ok and player_ok and select_ok and disp_ok:
			Log.info("dialogue", "  MATCH: %s (disp=%d)" % [info.record_id, info.disposition])
			return info

		if logged < max_log:
			var reasons: Array[String] = []
			if not actor_ok: reasons.append("actor(id=%s race=%s class=%s fac=%s sex=%d)" % [info.actor_id, info.actor_race, info.actor_class, info.actor_faction, info.speaker_sex])
			if not player_ok: reasons.append("player(fac=%s rank=%d cell=%s)" % [info.pc_faction, info.player_rank, info.actor_cell])
			if not select_ok: reasons.append("conditions(%d)" % info.conditions.size())
			if not disp_ok: reasons.append("disposition(%d>=%d)" % [context.disposition, info.disposition])
			Log.info("dialogue", "  REJECT %s: %s" % [info.record_id, ", ".join(reasons)])
			logged += 1

	return null


## Quick check: could ANY info in this topic possibly match this NPC?
## Used for pre-filtering in topic discovery (avoids full filter on 2000+ topics)
static func could_match_npc(topic_id: String, npc: NPCRecord) -> bool:
	var infos: Array = ESMManager.get_dialogue_infos(topic_id)
	for info: DialogueInfoRecord in infos:
		if info.is_deleted:
			continue
		# An INFO can match if: no actor filter, or actor matches
		if info.actor_id.is_empty() or info.actor_id.to_lower() == npc.record_id.to_lower():
			# And: no race filter, or race matches
			if info.actor_race.is_empty() or info.actor_race.to_lower() == npc.race_id.to_lower():
				return true
	return false


#region Step 1: testActor

static func _test_actor(info: DialogueInfoRecord, npc: NPCRecord) -> bool:
	# Actor ID filter
	if not info.actor_id.is_empty():
		if info.actor_id.to_lower() != npc.record_id.to_lower():
			return false
	# If no actor_id set and this is a creature, reject (creatures only get actor-specific)
	# NPCs pass through to race/class/faction checks

	# Race filter
	if not info.actor_race.is_empty():
		if info.actor_race.to_lower() != npc.race_id.to_lower():
			return false

	# Class filter
	if not info.actor_class.is_empty():
		if info.actor_class.to_lower() != npc.class_id.to_lower():
			return false

	# Faction filter
	if not info.actor_faction.is_empty():
		if info.actor_faction.to_lower() != npc.faction_id.to_lower():
			return false
		# If faction matches, NPC rank must be >= speaker_rank
		if info.speaker_rank >= 0 and npc.rank < info.speaker_rank:
			return false
	elif info.speaker_rank >= 0:
		# No faction filter but rank filter: check NPC's own faction rank
		if npc.rank < info.speaker_rank:
			return false

	# Gender filter
	if info.speaker_sex >= 0:
		var npc_is_female := npc.is_female()
		var info_wants_female := (info.speaker_sex == 1)
		if npc_is_female != info_wants_female:
			return false

	return true

#endregion

#region Step 2: testPlayer

static func _test_player(info: DialogueInfoRecord, npc: NPCRecord, context: MWDialogueContext) -> bool:
	# PC faction filter
	if not info.pc_faction.is_empty():
		if info.pc_faction.to_lower() != context.pc_faction.to_lower():
			return false
		if info.player_rank >= 0 and context.pc_rank < info.player_rank:
			return false
	elif info.player_rank >= 0:
		# No pc_faction but rank specified: use NPC's faction
		if npc.faction_id.is_empty():
			return false
		if context.pc_faction.to_lower() != npc.faction_id.to_lower():
			return false
		if context.pc_rank < info.player_rank:
			return false

	# Cell filter (prefix match, case-insensitive)
	if not info.actor_cell.is_empty():
		if not context.current_cell.to_lower().begins_with(info.actor_cell.to_lower()):
			return false

	return true

#endregion

#region Step 3: testSelectStructs (SCVR conditions)

static func _test_select_structs(info: DialogueInfoRecord, npc: NPCRecord, context: MWDialogueContext) -> bool:
	if info.conditions.is_empty():
		return true

	var parsed: Array = MWConditionParserScript.parse_all(info.conditions)

	for cond: MWConditionParserScript.ParsedCondition in parsed:
		if not _evaluate_condition(cond, npc, context):
			return false

	return true


static func _evaluate_condition(cond: MWConditionParserScript.ParsedCondition, npc: NPCRecord, context: MWDialogueContext) -> bool:
	var target: float = cond.get_value()

	match cond.type:
		MWConditionParserScript.ConditionType.FUNCTION:
			var value := MWDialogueFunctionsScript.evaluate(cond.function_id, npc, context)
			return MWConditionParserScript.compare(value, cond.compare_op, target)

		MWConditionParserScript.ConditionType.GLOBAL:
			var global_val: float = context.get_global(cond.variable_name)
			return MWConditionParserScript.compare(global_val, cond.compare_op, target)

		MWConditionParserScript.ConditionType.LOCAL:
			# Check local script variable (stub: return 0)
			return MWConditionParserScript.compare(0.0, cond.compare_op, target)

		MWConditionParserScript.ConditionType.JOURNAL:
			var journal_index: float = float(context.get_journal_index(cond.variable_name))
			return MWConditionParserScript.compare(journal_index, cond.compare_op, target)

		MWConditionParserScript.ConditionType.ITEM:
			# Check item count in player inventory (stub: return 0)
			return MWConditionParserScript.compare(0.0, cond.compare_op, target)

		MWConditionParserScript.ConditionType.DEAD:
			# Check dead count for actor (stub: return 0)
			return MWConditionParserScript.compare(0.0, cond.compare_op, target)

		MWConditionParserScript.ConditionType.NOT_ID:
			# Pass if NPC's record_id does NOT match
			var matches := npc.record_id.to_lower() == cond.variable_name.to_lower()
			return not matches

		MWConditionParserScript.ConditionType.NOT_FACTION:
			var matches := npc.faction_id.to_lower() == cond.variable_name.to_lower()
			return not matches

		MWConditionParserScript.ConditionType.NOT_CLASS:
			var matches := npc.class_id.to_lower() == cond.variable_name.to_lower()
			return not matches

		MWConditionParserScript.ConditionType.NOT_RACE:
			var matches := npc.race_id.to_lower() == cond.variable_name.to_lower()
			return not matches

		MWConditionParserScript.ConditionType.NOT_CELL:
			# Cell prefix match (inverted)
			var cell_matches: bool = context.current_cell.to_lower().begins_with(cond.variable_name.to_lower())
			return not cell_matches

		MWConditionParserScript.ConditionType.NOT_LOCAL:
			# Check NOT local variable (stub: return 0)
			return MWConditionParserScript.compare(0.0, cond.compare_op, target)

	return true  # Unknown type — pass

#endregion

#region Step 4: testDisposition

static func _test_disposition(info: DialogueInfoRecord, _npc: NPCRecord, context: MWDialogueContext) -> bool:
	return context.disposition >= info.disposition

#endregion
