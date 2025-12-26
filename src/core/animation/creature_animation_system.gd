## CreatureAnimationSystem - Animation system for non-humanoid creatures
##
## Handles creatures with various skeletal structures:
## - Bipeds (similar to humanoids but different proportions)
## - Quadrupeds (4-legged creatures)
## - Flying creatures
## - Snakes/serpents
## - Custom skeletons
@tool
class_name CreatureAnimationSystem
extends "res://src/core/animation/character_animation_system.gd"

# Preload for typed access
const _IKControllerScript := preload("res://src/core/animation/ik_controller.gd")

# Creature types for IK configuration
enum CreatureType {
	UNKNOWN,
	BIPED,       # Two-legged (humanoid-like)
	QUADRUPED,   # Four-legged
	FLYING,      # Flying creatures (no ground IK)
	SERPENT,     # Snake-like (no leg IK)
	MULTI_LEG,   # More than 4 legs
}

# Configuration
@export var creature_type: CreatureType = CreatureType.UNKNOWN
@export var auto_detect_type: bool = true

# Creature info
var _creature_record_id: String = ""
var _leg_count: int = 0
var _has_wings: bool = false
var _has_tail: bool = false


## Setup for creature
func setup_creature(p_skeleton: Skeleton3D, p_character_body: CharacterBody3D,
		creature_record_id: String = "") -> void:
	_creature_record_id = creature_record_id

	# Detect creature type from skeleton if auto-detect enabled
	if auto_detect_type:
		_detect_creature_type(p_skeleton)

	# Call parent setup
	setup(p_skeleton, p_character_body)

	# Configure IK based on creature type
	_configure_creature_ik()


## Detect creature type from skeleton structure
func _detect_creature_type(p_skeleton: Skeleton3D) -> void:
	if not p_skeleton:
		return

	# Count legs, wings, tail
	var left_legs := 0
	var right_legs := 0

	for i in p_skeleton.get_bone_count():
		var name_lower := p_skeleton.get_bone_name(i).to_lower()

		# Count leg bones
		if "leg" in name_lower or "thigh" in name_lower or "calf" in name_lower:
			if "left" in name_lower or " l " in name_lower or "_l" in name_lower:
				left_legs += 1
			elif "right" in name_lower or " r " in name_lower or "_r" in name_lower:
				right_legs += 1

		# Check for wings
		if "wing" in name_lower:
			_has_wings = true

		# Check for tail
		if "tail" in name_lower:
			_has_tail = true

	# Determine leg count (using the max of left/right)
	_leg_count = max(left_legs, right_legs) * 2

	# Determine creature type
	if _has_wings and _leg_count == 0:
		creature_type = CreatureType.FLYING
	elif _leg_count == 0:
		creature_type = CreatureType.SERPENT
	elif _leg_count == 2:
		creature_type = CreatureType.BIPED
	elif _leg_count == 4:
		creature_type = CreatureType.QUADRUPED
	elif _leg_count > 4:
		creature_type = CreatureType.MULTI_LEG
	else:
		creature_type = CreatureType.UNKNOWN

	if debug_mode:
		print("CreatureAnimationSystem: Detected type %s (legs: %d, wings: %s, tail: %s)" % [
			_get_type_name(), _leg_count, _has_wings, _has_tail
		])


## Configure IK based on creature type
func _configure_creature_ik() -> void:
	var ik_ctrl: _IKControllerScript = ik_controller as _IKControllerScript
	if not ik_ctrl:
		return

	match creature_type:
		CreatureType.BIPED:
			# Similar to humanoid - foot IK enabled
			ik_ctrl.enable_foot_ik = true
			ik_ctrl.enable_look_at = true
			ik_ctrl.enable_hand_ik = false  # Creatures don't have hands

		CreatureType.QUADRUPED:
			# Need 4-foot IK (not yet implemented)
			ik_ctrl.enable_foot_ik = false  # TODO: Implement quadruped IK
			ik_ctrl.enable_look_at = true
			ik_ctrl.enable_hand_ik = false

		CreatureType.FLYING:
			# No ground IK for flying creatures
			ik_ctrl.enable_foot_ik = false
			ik_ctrl.enable_look_at = true
			ik_ctrl.enable_hand_ik = false

		CreatureType.SERPENT:
			# No leg IK for serpents
			ik_ctrl.enable_foot_ik = false
			ik_ctrl.enable_look_at = true
			ik_ctrl.enable_hand_ik = false

		_:
			# Unknown - disable IK to be safe
			ik_ctrl.set_all_enabled(false)


## Get creature type name for debugging
func _get_type_name() -> String:
	match creature_type:
		CreatureType.BIPED: return "BIPED"
		CreatureType.QUADRUPED: return "QUADRUPED"
		CreatureType.FLYING: return "FLYING"
		CreatureType.SERPENT: return "SERPENT"
		CreatureType.MULTI_LEG: return "MULTI_LEG"
		_: return "UNKNOWN"


## Get creature record ID
func get_creature_record_id() -> String:
	return _creature_record_id


## Check creature features
func has_wings() -> bool:
	return _has_wings


func has_tail() -> bool:
	return _has_tail


func get_leg_count() -> int:
	return _leg_count
