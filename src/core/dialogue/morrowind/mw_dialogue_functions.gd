## MWDialogueFunctions — Evaluates Morrowind's 74 built-in dialogue filter functions
##
## Morrowind-specific translation layer. These functions are MW's dialogue condition system.
## Function IDs match OpenMW's selectComparisonType enum in selectwrapper.hpp.
## Maps generic DialogueContext fields to MW-specific function return values.
class_name MWDialogueFunctions
extends RefCounted


## Built-in function IDs (from OpenMW selectwrapper.hpp)
enum FuncID {
	FAC_REACTION_LOWEST = 0,
	FAC_REACTION_HIGHEST = 1,
	RANK_REQUIREMENT = 2,
	REPUTATION = 3,       # NPC's reputation
	HEALTH_PERCENT = 4,   # NPC's health %
	PC_REPUTATION = 5,
	PC_LEVEL = 6,
	PC_HEALTH_PERCENT = 7,
	PC_MAGICKA = 8,
	PC_FATIGUE = 9,
	# 10-17: PC attributes (Strength through Luck)
	PC_STRENGTH = 10,
	PC_INTELLIGENCE = 11,
	PC_WILLPOWER = 12,
	PC_AGILITY = 13,
	PC_SPEED = 14,
	PC_ENDURANCE = 15,
	PC_PERSONALITY = 16,
	PC_LUCK = 17,
	# 18-44: PC skills (Block through HandToHand) — 27 skills mapped to indices 0-26
	PC_BLOCK = 18,
	PC_GENDER = 38,
	PC_EXPELLED = 39,
	PC_COMMON_DISEASE = 40,
	PC_BLIGHT_DISEASE = 41,
	PC_CLOTHING_MODIFIER = 42,
	PC_CRIME_LEVEL = 43,
	SAME_SEX = 44,
	SAME_RACE = 45,
	SAME_FACTION = 46,
	FACTION_RANK_DIFFERENCE = 47,
	DETECTED = 48,
	ALARMED = 49,
	CHOICE = 50,
	# 51-57: duplicate attribute range (not used in standard conditions)
	PC_CORPRUS = 58,
	WEATHER = 59,
	PC_VAMPIRE = 60,
	LEVEL = 61,           # NPC's level
	ATTACKED = 62,
	TALKED_TO_PC = 63,
	PC_HEALTH = 64,
	CREATURE_TARGET = 65,
	FRIEND_HIT = 66,
	FIGHT = 67,
	HELLO = 68,
	ALARM = 69,
	FLEE = 70,
	SHOULD_ATTACK = 71,
	WEREWOLF = 72,
	PC_WEREWOLF_KILLS = 73,
}


## Evaluate a built-in function given the dialogue context
## Returns the function's current value as a float
static func evaluate(function_id: int, npc: NPCRecord, context: MWDialogueContext) -> float:
	match function_id:
		# --- NPC state ---
		FuncID.REPUTATION:
			return float(npc.reputation) if npc != null else 0.0
		FuncID.HEALTH_PERCENT:
			return 100.0  # NPC at full health (no combat system yet)
		FuncID.LEVEL:
			return float(npc.level) if npc != null else 0.0

		# --- NPC AI state ---
		FuncID.DETECTED:
			return 1.0 if context.detected else 0.0
		FuncID.ATTACKED:
			return 1.0 if context.attacked else 0.0
		FuncID.TALKED_TO_PC:
			return 1.0 if context.talked_to_pc else 0.0
		FuncID.ALARMED:
			return 1.0 if context.alarmed else 0.0
		FuncID.SHOULD_ATTACK:
			return 0.0  # No combat system
		FuncID.CREATURE_TARGET:
			return 0.0  # No combat system
		FuncID.FRIEND_HIT:
			return 0.0  # No combat system

		# NPC AI data fields
		FuncID.FIGHT:
			if npc != null and npc.ai_data != null:
				return float(npc.ai_data.fight)
			return 0.0
		FuncID.HELLO:
			if npc != null and npc.ai_data != null:
				return float(npc.ai_data.hello)
			return 0.0
		FuncID.ALARM:
			if npc != null and npc.ai_data != null:
				return float(npc.ai_data.alarm)
			return 0.0
		FuncID.FLEE:
			if npc != null and npc.ai_data != null:
				return float(npc.ai_data.flee)
			return 0.0

		# --- Faction reactions (stub — needs faction reaction table) ---
		FuncID.FAC_REACTION_LOWEST:
			return 0.0
		FuncID.FAC_REACTION_HIGHEST:
			return 100.0
		FuncID.RANK_REQUIREMENT:
			return 0.0

		# --- PC identity ---
		FuncID.PC_LEVEL:
			return float(context.pc_level)
		FuncID.PC_GENDER:
			return float(context.pc_gender)
		FuncID.PC_REPUTATION:
			return float(context.pc_reputation)
		FuncID.PC_CRIME_LEVEL:
			return float(context.pc_crime_level)

		# --- PC health/stats ---
		FuncID.PC_HEALTH_PERCENT:
			return float(context.pc_health_percent)
		FuncID.PC_HEALTH:
			return float(context.pc_health)
		FuncID.PC_MAGICKA:
			return float(context.pc_magicka)
		FuncID.PC_FATIGUE:
			return float(context.pc_fatigue)
		FuncID.PC_CLOTHING_MODIFIER:
			return float(context.pc_clothing_value)

		# --- PC attributes (10-17) ---
		FuncID.PC_STRENGTH, FuncID.PC_INTELLIGENCE, FuncID.PC_WILLPOWER, \
		FuncID.PC_AGILITY, FuncID.PC_SPEED, FuncID.PC_ENDURANCE, \
		FuncID.PC_PERSONALITY, FuncID.PC_LUCK:
			var attr_index: int = function_id - FuncID.PC_STRENGTH  # 0-7
			return float(context.get_attribute(attr_index))

		# --- PC skills (18-37 maps to skill indices 0-19, 38 is gender) ---
		# Skills 18-37: Block(0) through HandToHand(19+)
		# Note: function_id 38 = PC_GENDER, not a skill

		# --- PC status flags ---
		FuncID.PC_EXPELLED:
			return 1.0 if context.pc_expelled else 0.0
		FuncID.PC_COMMON_DISEASE:
			return 1.0 if context.pc_common_disease else 0.0
		FuncID.PC_BLIGHT_DISEASE:
			return 1.0 if context.pc_blight_disease else 0.0
		FuncID.PC_CORPRUS:
			return 1.0 if context.pc_corprus else 0.0
		FuncID.PC_VAMPIRE:
			return 1.0 if context.pc_vampire else 0.0
		FuncID.WEREWOLF:
			return 1.0 if context.pc_werewolf else 0.0
		FuncID.PC_WEREWOLF_KILLS:
			return float(context.pc_werewolf_kills)

		# --- Comparison functions ---
		FuncID.SAME_SEX:
			if npc == null:
				return 0.0
			var npc_female: bool = npc.is_female()
			return 1.0 if (context.pc_gender == 1) == npc_female else 0.0
		FuncID.SAME_RACE:
			if npc == null:
				return 0.0
			return 1.0 if context.pc_race.to_lower() == npc.race_id.to_lower() else 0.0
		FuncID.SAME_FACTION:
			if npc == null or npc.faction_id.is_empty():
				return 0.0
			return 1.0 if context.pc_faction.to_lower() == npc.faction_id.to_lower() else 0.0
		FuncID.FACTION_RANK_DIFFERENCE:
			if npc == null or npc.faction_id.is_empty():
				return 0.0
			if context.pc_faction.to_lower() != npc.faction_id.to_lower():
				return 0.0
			return float(context.pc_rank - npc.rank)

		# --- Dialogue state ---
		FuncID.CHOICE:
			return float(context.choice)
		FuncID.WEATHER:
			return float(context.weather)

		_:
			# Skills range (18-37)
			if function_id >= 18 and function_id <= 37:
				var skill_index: int = function_id - 18  # 0-19
				return float(context.get_skill(skill_index))
			return 0.0
