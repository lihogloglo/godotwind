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
static func evaluate(function_id: int, npc: NPCRecord, context: RefCounted) -> float:
	# Extract typed fields from context to avoid Variant inference warnings
	var ctx_pc_level: int = context.pc_level
	var ctx_pc_gender: int = context.pc_gender
	var ctx_pc_race: String = context.pc_race
	var ctx_pc_faction: String = context.pc_faction
	var ctx_pc_rank: int = context.pc_rank

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
			var detected: bool = context.detected
			return 1.0 if detected else 0.0
		FuncID.ATTACKED:
			var attacked: bool = context.attacked
			return 1.0 if attacked else 0.0
		FuncID.TALKED_TO_PC:
			var talked: bool = context.talked_to_pc
			return 1.0 if talked else 0.0
		FuncID.ALARMED:
			var alarmed: bool = context.alarmed
			return 1.0 if alarmed else 0.0
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
			return float(ctx_pc_level)
		FuncID.PC_GENDER:
			return float(ctx_pc_gender)
		FuncID.PC_REPUTATION:
			var rep: int = context.pc_reputation
			return float(rep)
		FuncID.PC_CRIME_LEVEL:
			var crime: int = context.pc_crime_level
			return float(crime)

		# --- PC health/stats ---
		FuncID.PC_HEALTH_PERCENT:
			var hp_pct: int = context.pc_health_percent
			return float(hp_pct)
		FuncID.PC_HEALTH:
			var hp: int = context.pc_health
			return float(hp)
		FuncID.PC_MAGICKA:
			var mp: int = context.pc_magicka
			return float(mp)
		FuncID.PC_FATIGUE:
			var fat: int = context.pc_fatigue
			return float(fat)
		FuncID.PC_CLOTHING_MODIFIER:
			var clothing: int = context.pc_clothing_value
			return float(clothing)

		# --- PC attributes (10-17) ---
		FuncID.PC_STRENGTH, FuncID.PC_INTELLIGENCE, FuncID.PC_WILLPOWER, \
		FuncID.PC_AGILITY, FuncID.PC_SPEED, FuncID.PC_ENDURANCE, \
		FuncID.PC_PERSONALITY, FuncID.PC_LUCK:
			var attr_index: int = function_id - FuncID.PC_STRENGTH  # 0-7
			var attr_val: int = context.get_attribute(attr_index)
			return float(attr_val)

		# --- PC skills (18-37 maps to skill indices 0-19, 38 is gender) ---
		# Skills 18-37: Block(0) through HandToHand(19+)
		# Note: function_id 38 = PC_GENDER, not a skill

		# --- PC status flags ---
		FuncID.PC_EXPELLED:
			var expelled: bool = context.pc_expelled
			return 1.0 if expelled else 0.0
		FuncID.PC_COMMON_DISEASE:
			var disease: bool = context.pc_common_disease
			return 1.0 if disease else 0.0
		FuncID.PC_BLIGHT_DISEASE:
			var blight: bool = context.pc_blight_disease
			return 1.0 if blight else 0.0
		FuncID.PC_CORPRUS:
			var corprus: bool = context.pc_corprus
			return 1.0 if corprus else 0.0
		FuncID.PC_VAMPIRE:
			var vampire: bool = context.pc_vampire
			return 1.0 if vampire else 0.0
		FuncID.WEREWOLF:
			var werewolf: bool = context.pc_werewolf
			return 1.0 if werewolf else 0.0
		FuncID.PC_WEREWOLF_KILLS:
			var kills: int = context.pc_werewolf_kills
			return float(kills)

		# --- Comparison functions ---
		FuncID.SAME_SEX:
			if npc == null:
				return 0.0
			var npc_female: bool = npc.is_female()
			return 1.0 if (ctx_pc_gender == 1) == npc_female else 0.0
		FuncID.SAME_RACE:
			if npc == null:
				return 0.0
			return 1.0 if ctx_pc_race.to_lower() == npc.race_id.to_lower() else 0.0
		FuncID.SAME_FACTION:
			if npc == null or npc.faction_id.is_empty():
				return 0.0
			return 1.0 if ctx_pc_faction.to_lower() == npc.faction_id.to_lower() else 0.0
		FuncID.FACTION_RANK_DIFFERENCE:
			if npc == null or npc.faction_id.is_empty():
				return 0.0
			if ctx_pc_faction.to_lower() != npc.faction_id.to_lower():
				return 0.0
			return float(ctx_pc_rank - npc.rank)

		# --- Dialogue state ---
		FuncID.CHOICE:
			var choice_val: int = context.choice
			return float(choice_val)
		FuncID.WEATHER:
			var weather_val: int = context.weather
			return float(weather_val)

		_:
			# Skills range (18-37)
			if function_id >= 18 and function_id <= 37:
				var skill_index: int = function_id - 18  # 0-19
				var skill_val: int = context.get_skill(skill_index)
				return float(skill_val)
			return 0.0
