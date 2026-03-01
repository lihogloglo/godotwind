## MorrowindCharacterSystem - Animation system for Morrowind characters
##
## Extends HumanoidAnimationSystem with Morrowind-specific features:
## - Morrowind bone naming (Bip01 convention)
## - KF animation loading
## - Body part assembly integration
## - Race-specific skeleton variants (male, female, beast)
@tool
class_name MorrowindCharacterSystem
extends "res://src/core/animation/humanoid_animation_system.gd"

# Preload dependencies
const SkeletonUtilsScript := preload("res://src/core/animation/skeleton_utils.gd")

# _AnimationManagerScript is inherited from parent class

# Character info
# Maps animation states to Morrowind animation names
const MORROWIND_ANIM_MAP: Dictionary = {
	&"Idle": ["idle", "Idle"],
	&"Walk": ["walkforward", "WalkForward", "walk"],
	&"Run": ["runforward", "RunForward", "run"],
	&"Jump": ["jump", "Jump"],
	&"Fall": ["jumploop", "JumpLoop"],
	&"Land": ["jumpland", "JumpLand"],
	&"SwimIdle": ["swimidle", "SwimIdle"],
	&"SwimForward": ["swimforward", "SwimForward"],
	&"CombatIdle": ["idlecombat", "IdleCombat", "idle"],
	&"Attack": ["attack1", "Attack1", "attackchop1"],
	&"Block": ["blockstart", "BlockStart", "block"],
	&"Hit": ["hit1", "Hit1", "hit"],
	&"Death": ["death1", "Death1", "death"],
	&"SpellCast": ["spellcast", "SpellCast", "cast"],
}

# Character info
var _is_female: bool = false
var _is_beast: bool = false
var _race_id: String = ""
var _npc_record_id: String = ""


## Setup for Morrowind character
func setup_morrowind(p_skeleton: Skeleton3D, p_character_body: CharacterBody3D,
		is_female: bool, is_beast: bool, race_id: String = "",
		npc_record_id: String = "") -> void:
	_is_female = is_female
	_is_beast = is_beast
	_race_id = race_id
	_npc_record_id = npc_record_id

	# Call parent setup
	setup(p_skeleton, p_character_body)


## Find animation by Morrowind name
func find_morrowind_animation(state: StringName) -> StringName:
	var anim_mgr: _AnimationManagerScript = animation_manager as _AnimationManagerScript
	if not anim_mgr or not anim_mgr.animation_player:
		return &""

	var anim_player: AnimationPlayer = anim_mgr.animation_player
	var animations: PackedStringArray = anim_player.get_animation_list()

	# Get search terms from mapping
	var search_terms: Array = MORROWIND_ANIM_MAP.get(state, [state])

	for term: String in search_terms:
		var term_lower := term.to_lower()

		# Pass 1: exact match (case-insensitive)
		for anim in animations:
			if anim.to_lower() == term_lower:
				return StringName(anim)

		# Pass 2: word-boundary match (term must be delimited by _ or start/end)
		for anim in animations:
			var anim_lower := anim.to_lower()
			var pos := anim_lower.find(term_lower)
			if pos >= 0:
				var before_ok := (pos == 0 or anim_lower[pos - 1] == "_")
				var after_pos := pos + term_lower.length()
				var after_ok := (after_pos >= anim_lower.length() or anim_lower[after_pos] == "_")
				if before_ok and after_ok:
					return StringName(anim)

	return &""



## Check if character is female
func is_female() -> bool:
	return _is_female


## Check if character is beast race
func is_beast_race() -> bool:
	return _is_beast


## Get race ID
func get_race_id() -> String:
	return _race_id


## Get NPC record ID
func get_npc_record_id() -> String:
	return _npc_record_id


# =============================================================================
# MORROWIND-SPECIFIC ANIMATIONS
# =============================================================================

## Play weapon-specific attack
func play_weapon_attack(weapon_type: StringName) -> void:
	var anim_name: StringName

	match weapon_type:
		&"short_blade", &"long_blade":
			anim_name = find_morrowind_animation(&"Attack") # attackchop/slash/thrust
		&"blunt", &"axe":
			anim_name = find_morrowind_animation(&"Attack")
		&"spear":
			anim_name = find_morrowind_animation(&"Attack")
		&"bow":
			anim_name = _find_animation_containing("bowequip")
		&"crossbow":
			anim_name = _find_animation_containing("crossbow")
		&"thrown":
			anim_name = _find_animation_containing("throw")
		&"hand_to_hand":
			anim_name = find_morrowind_animation(&"Attack")
		_:
			anim_name = find_morrowind_animation(&"Attack")

	if not anim_name.is_empty():
		play_attack(anim_name)
	else:
		play_attack()


## Play magic effect animation
func play_magic_effect(effect_type: StringName) -> void:
	var anim_name := _find_animation_containing(effect_type)
	if anim_name.is_empty():
		anim_name = find_morrowind_animation(&"SpellCast")

	var anim_mgr: _AnimationManagerScript = animation_manager as _AnimationManagerScript
	if anim_mgr and not anim_name.is_empty():
		anim_mgr.play_oneshot(anim_name, _AnimationManagerScript.LAYER_ACTION)


## Find animation containing a substring (word-boundary aware)
func _find_animation_containing(substring: String) -> StringName:
	var anim_mgr: _AnimationManagerScript = animation_manager as _AnimationManagerScript
	if not anim_mgr or not anim_mgr.animation_player:
		return &""

	var animations: PackedStringArray = anim_mgr.animation_player.get_animation_list()
	var substring_lower := substring.to_lower()

	# Pass 1: Exact match
	for anim: String in animations:
		if anim.to_lower() == substring_lower:
			return StringName(anim)

	# Pass 2: Word-boundary match
	for anim: String in animations:
		var anim_lower := anim.to_lower()
		var pos := anim_lower.find(substring_lower)
		if pos >= 0:
			var before_ok := (pos == 0 or anim_lower[pos - 1] == "_")
			var after_pos := pos + substring_lower.length()
			var after_ok := (after_pos >= anim_lower.length() or anim_lower[after_pos] == "_")
			if before_ok and after_ok:
				return StringName(anim)

	return &""


# =============================================================================
# SWIMMING (Morrowind-specific water detection)
# =============================================================================

var _water_level: float = 0.0
var _is_swimming: bool = false

## Set water level for swimming detection
func set_water_level(level: float) -> void:
	_water_level = level


## Update swimming state
func update_swimming(character_height: float) -> void:
	if not character_body:
		return

	var char_y := character_body.global_position.y
	var head_y := char_y + character_height * 0.9

	# Check if submerged enough to swim
	var was_swimming := _is_swimming
	_is_swimming = head_y < _water_level

	if _is_swimming != was_swimming:
		var anim_mgr: _AnimationManagerScript = animation_manager as _AnimationManagerScript
		if _is_swimming:
			if anim_mgr:
				anim_mgr.transition_to(&"SwimIdle")
		else:
			if anim_mgr:
				anim_mgr.transition_to(&"Idle")


## Check if currently swimming
func is_swimming() -> bool:
	return _is_swimming


# =============================================================================
# BEAST RACE SPECIFIC
# =============================================================================

## Check if beast race has tail bone
func has_tail() -> bool:
	if not skeleton:
		return false

	for i in skeleton.get_bone_count():
		if "tail" in skeleton.get_bone_name(i).to_lower():
			return true

	return false


## Get tail bone index (for tail animation)
func get_tail_bone_index() -> int:
	if not skeleton:
		return -1

	for i in skeleton.get_bone_count():
		if "tail" in skeleton.get_bone_name(i).to_lower():
			return i

	return -1
