## HumanoidAnimationSystem - Animation system for bipedal humanoid characters
##
## Extends CharacterAnimationSystem with humanoid-specific features:
## - Standard humanoid bone mapping
## - Two-leg foot IK
## - Look-at with head/neck/spine chain
## - Two-hand IK for weapons and interactions
## - Combat animation states
@tool
class_name HumanoidAnimationSystem
extends "res://src/core/animation/character_animation_system.gd"

# Preload for constants access
const _AnimationManagerScript := preload("res://src/core/animation/animation_manager.gd")
const _ProceduralModifierScript := preload("res://src/core/animation/procedural_modifier_controller.gd")
const _SPA := preload("res://src/core/animation/skeleton_profile_adapter.gd")

# Humanoid-specific signals
signal combat_mode_changed(enabled: bool)
signal weapon_drawn(weapon_type: StringName)
signal weapon_sheathed

# Combat states
enum CombatState {
	NONE,
	IDLE,
	ATTACKING,
	BLOCKING,
	CASTING,
	STAGGERED
}

# Configuration
@export_group("Combat")
@export var enable_combat_animations: bool = true
@export var combat_blend_time: float = 0.3

@export_group("Weapons")
@export var enable_weapon_ik: bool = true
@export var two_handed_weapon: bool = false

# State
var _is_in_combat: bool = false
var _combat_state: CombatState = CombatState.NONE
var _current_weapon_type: StringName = &""

# Bone mapping (standard humanoid names)
var _bone_map: Dictionary = {}


## Override setup to add humanoid-specific initialization
func setup(p_skeleton: Skeleton3D, p_character_body: CharacterBody3D = null,
		p_character_root: Node3D = null) -> void:
	# Call parent setup
	super.setup(p_skeleton, p_character_body, p_character_root)

	if not _is_setup:
		return

	# Build humanoid bone map
	_build_bone_map()

	# Configure IK for humanoid
	_configure_humanoid_ik()


## Build bone name mapping using _SPA
func _build_bone_map() -> void:
	if not skeleton:
		return

	var bone_map := _SPA.create_bone_map(skeleton)
	if not bone_map:
		return

	# Populate _bone_map: profile_name -> bone_index
	var profile := bone_map.profile
	for i in profile.bone_size:
		var profile_name := profile.get_bone_name(i)
		var skel_name := bone_map.get_skeleton_bone_name(profile_name)
		if not skel_name.is_empty():
			var idx := skeleton.find_bone(skel_name)
			if idx >= 0:
				_bone_map[profile_name] = idx


## Configure IK for humanoid skeleton
func _configure_humanoid_ik() -> void:
	# IK controller should already be set up by parent
	# We can adjust settings here if needed
	pass


# =============================================================================
# COMBAT API
# =============================================================================

## Enter combat mode
func enter_combat() -> void:
	if _is_in_combat:
		return

	_is_in_combat = true
	_combat_state = CombatState.IDLE

	var anim: _AnimationManagerScript = animation_manager as _AnimationManagerScript
	if anim:
		anim.transition_to(&"CombatIdle")

	combat_mode_changed.emit(true)


## Exit combat mode
func exit_combat() -> void:
	if not _is_in_combat:
		return

	_is_in_combat = false
	_combat_state = CombatState.NONE

	var anim: _AnimationManagerScript = animation_manager as _AnimationManagerScript
	if anim:
		anim.transition_to(&"Idle")

	combat_mode_changed.emit(false)


## Check if in combat mode
func is_in_combat() -> bool:
	return _is_in_combat


## Play attack animation
func play_attack(attack_type: StringName = &"attack1") -> void:
	if not _is_in_combat:
		enter_combat()

	_combat_state = CombatState.ATTACKING

	var anim: _AnimationManagerScript = animation_manager as _AnimationManagerScript
	if anim:
		anim.play_oneshot(attack_type, _AnimationManagerScript.LAYER_ACTION)


## Play block animation
func play_block() -> void:
	if not _is_in_combat:
		enter_combat()

	_combat_state = CombatState.BLOCKING

	var anim: _AnimationManagerScript = animation_manager as _AnimationManagerScript
	if anim:
		anim.play_oneshot(&"block", _AnimationManagerScript.LAYER_ACTION)


## Play spell cast animation
func play_spell_cast(spell_type: StringName = &"spellcast") -> void:
	_combat_state = CombatState.CASTING

	var anim: _AnimationManagerScript = animation_manager as _AnimationManagerScript
	if anim:
		anim.play_oneshot(spell_type, _AnimationManagerScript.LAYER_ACTION)


## Play hit/stagger reaction
func play_hit_reaction(direction: Vector3 = Vector3.ZERO, strength: float = 1.0) -> void:
	_combat_state = CombatState.STAGGERED

	# Apply procedural hit reaction
	var proc: _ProceduralModifierScript = procedural_modifiers as _ProceduralModifierScript
	if proc:
		proc.apply_hit(direction, strength)

	# Play hit animation
	var anim: _AnimationManagerScript = animation_manager as _AnimationManagerScript
	if anim:
		anim.play_oneshot(&"hit", _AnimationManagerScript.LAYER_ACTION)


## Play death animation
func play_death() -> void:
	_is_in_combat = false
	_combat_state = CombatState.NONE

	var anim: _AnimationManagerScript = animation_manager as _AnimationManagerScript
	if anim:
		anim.transition_to(&"Death")


# =============================================================================
# WEAPON API
# =============================================================================

## Draw weapon
func draw_weapon(weapon_type: StringName = &"melee") -> void:
	_current_weapon_type = weapon_type

	# Play draw animation if available
	var anim: _AnimationManagerScript = animation_manager as _AnimationManagerScript
	if anim:
		anim.play_oneshot(&"draw_weapon", _AnimationManagerScript.LAYER_ACTION)

	weapon_drawn.emit(weapon_type)


## Sheathe weapon
func sheathe_weapon() -> void:
	_current_weapon_type = &""

	var anim: _AnimationManagerScript = animation_manager as _AnimationManagerScript
	if anim:
		anim.play_oneshot(&"sheathe_weapon", _AnimationManagerScript.LAYER_ACTION)

	weapon_sheathed.emit()


## Get current weapon type
func get_weapon_type() -> StringName:
	return _current_weapon_type


## Set weapon grip IK target (for hand placement on weapon)
func set_weapon_grip(left_grip: Node3D, right_grip: Node3D) -> void:
	if not enable_weapon_ik:
		return

	if left_grip:
		set_hand_target(&"left", left_grip)
	else:
		clear_hand_target(&"left")

	if right_grip:
		set_hand_target(&"right", right_grip)
	else:
		clear_hand_target(&"right")


## Clear weapon grip
func clear_weapon_grip() -> void:
	clear_hand_target(&"left")
	clear_hand_target(&"right")


# =============================================================================
# LOCOMOTION
# =============================================================================

## Update animation from movement (override for combat awareness)
func update_from_movement(velocity: Vector3, is_grounded: bool = true) -> void:
	if _is_in_combat and velocity.length() < 0.1:
		# Stay in combat idle when stationary in combat
		var anim: _AnimationManagerScript = animation_manager as _AnimationManagerScript
		if anim:
			anim.transition_to(&"CombatIdle")
		return

	# Otherwise use parent implementation
	super.update_from_movement(velocity, is_grounded)


# =============================================================================
# UTILITY
# =============================================================================

## Get bone index by standard humanoid name
func get_bone_index(standard_name: StringName) -> int:
	return _bone_map.get(standard_name, -1)


## Get bone name in skeleton from standard name
func get_bone_name(standard_name: StringName) -> String:
	var idx: int = _bone_map.get(standard_name, -1)
	if idx >= 0 and skeleton:
		return skeleton.get_bone_name(idx)
	return ""


## Check if skeleton has a standard bone
func has_bone(standard_name: StringName) -> bool:
	return standard_name in _bone_map
