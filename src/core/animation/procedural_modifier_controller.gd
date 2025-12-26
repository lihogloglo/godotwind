## ProceduralModifierController - Procedural animation overlays
##
## Handles procedural animation effects that modify the base animation:
## - Lean (acceleration-based body tilt)
## - Breathing (idle oscillation)
## - Hit reactions (impulse-based responses)
##
## These are applied as additive or blend modifications on top of the base animation
class_name ProceduralModifierController
extends Node

# Signals
signal hit_reaction_started
signal hit_reaction_ended

# Configuration
@export_group("Lean")
@export var enable_lean: bool = true
@export var lean_strength: float = 0.3
@export var lean_smoothing: float = 5.0
@export var max_lean_angle: float = 15.0  # Degrees

@export_group("Breathing")
@export var enable_breathing: bool = true
@export var breathing_rate: float = 0.2  # Breaths per second
@export var breathing_strength: float = 0.02  # Scale factor
@export var breathing_variation: float = 0.05  # Random variation

@export_group("Hit Reactions")
@export var enable_hit_reactions: bool = true
@export var hit_reaction_decay: float = 5.0
@export var max_hit_strength: float = 1.0

# References
var skeleton: Skeleton3D = null
var character_body: CharacterBody3D = null
var animation_manager: Node = null  # AnimationManager (avoid cyclic dep)

# Bone indices
var _spine_bones: Array[int] = []
var _chest_bone_idx: int = -1

# Lean state
var _current_lean: Vector2 = Vector2.ZERO
var _target_lean: Vector2 = Vector2.ZERO
var _previous_velocity: Vector3 = Vector3.ZERO

# Breathing state
var _breathing_phase: float = 0.0
var _breathing_value: float = 0.0

# Hit reaction state
var _hit_impulse: Vector3 = Vector3.ZERO
var _is_reacting: bool = false

# Setup state
var _is_setup: bool = false


## Setup the procedural modifiers
func setup(p_skeleton: Skeleton3D, p_character_body: CharacterBody3D,
		p_animation_manager: Node) -> void:
	skeleton = p_skeleton
	character_body = p_character_body
	animation_manager = p_animation_manager

	if not skeleton:
		push_error("ProceduralModifierController: Skeleton is required")
		return

	# Find spine/chest bones for modifications
	_find_bones()

	_is_setup = true


## Update procedural modifiers (called each frame)
func update(delta: float) -> void:
	if not _is_setup:
		return

	if enable_lean and character_body:
		_update_lean(delta)

	if enable_breathing:
		_update_breathing(delta)

	if enable_hit_reactions:
		_update_hit_reactions(delta)


# =============================================================================
# LEAN
# =============================================================================

## Update lean based on acceleration
func _update_lean(delta: float) -> void:
	if not character_body:
		return

	var velocity: Vector3 = character_body.velocity
	var acceleration: Vector3 = (velocity - _previous_velocity) / maxf(delta, 0.001)
	_previous_velocity = velocity

	# Get character-relative acceleration
	var forward: Vector3 = -character_body.global_transform.basis.z
	var right: Vector3 = character_body.global_transform.basis.x

	var forward_accel: float = acceleration.dot(forward)
	var side_accel: float = acceleration.dot(right)

	# Calculate target lean
	_target_lean.x = clampf(side_accel * lean_strength, -1.0, 1.0)
	_target_lean.y = clampf(-forward_accel * lean_strength, -1.0, 1.0)  # Negative = lean forward when accelerating

	# Smooth interpolation
	_current_lean = _current_lean.lerp(_target_lean, lean_smoothing * delta)

	# Apply lean to spine
	_apply_lean()


## Set lean manually (bypasses acceleration calculation)
func set_lean(lean: Vector2) -> void:
	_target_lean = lean.clampf(-1.0, 1.0)


## Apply lean to spine bones
func _apply_lean() -> void:
	if _spine_bones.is_empty():
		return

	var total_weight := 0.0
	for bone_idx in _spine_bones:
		total_weight += 1.0

	if total_weight == 0:
		return

	# Distribute lean across spine bones
	var lean_per_bone := max_lean_angle / total_weight

	for i in _spine_bones.size():
		var bone_idx: int = _spine_bones[i]
		var weight := 1.0 - (float(i) / _spine_bones.size()) * 0.5  # Decrease toward head

		# Calculate rotation
		var side_rotation := deg_to_rad(_current_lean.x * lean_per_bone * weight)
		var forward_rotation := deg_to_rad(_current_lean.y * lean_per_bone * weight)

		# Apply as additive rotation
		_apply_additive_rotation(bone_idx, Vector3(forward_rotation, 0, side_rotation))


# =============================================================================
# BREATHING
# =============================================================================

## Update breathing animation
func _update_breathing(delta: float) -> void:
	# Only breathe when mostly idle
	var speed_factor := 1.0
	if character_body:
		var speed := character_body.velocity.length()
		speed_factor = 1.0 - clampf(speed / 2.0, 0.0, 1.0)

	if speed_factor < 0.1:
		# Moving too fast, no breathing effect
		_breathing_value = lerpf(_breathing_value, 0.0, 5.0 * delta)
		return

	# Advance breathing phase with slight variation
	var rate := breathing_rate + randf_range(-breathing_variation * 0.1, breathing_variation * 0.1)
	_breathing_phase += delta * rate * TAU

	# Keep phase in range
	if _breathing_phase > TAU:
		_breathing_phase -= TAU

	# Calculate breathing value (smooth sine wave)
	_breathing_value = sin(_breathing_phase) * breathing_strength * speed_factor

	# Apply to chest
	_apply_breathing()


## Set breathing enabled
func set_breathing_enabled(enabled: bool) -> void:
	enable_breathing = enabled
	if not enabled:
		_breathing_value = 0.0


## Apply breathing to chest bone
func _apply_breathing() -> void:
	if _chest_bone_idx < 0:
		return

	# Breathing expands chest slightly
	var scale_offset := Vector3(_breathing_value, _breathing_value * 0.5, _breathing_value * 0.3)

	# Apply as scale modification (subtle)
	# Note: Godot's skeleton system doesn't easily support per-bone scale
	# So we apply as a subtle rotation instead
	var rotation := Vector3(_breathing_value * 0.02, 0, 0)
	_apply_additive_rotation(_chest_bone_idx, rotation)


# =============================================================================
# HIT REACTIONS
# =============================================================================

## Apply a hit reaction impulse
func apply_hit(direction: Vector3, strength: float = 1.0) -> void:
	if not enable_hit_reactions:
		return

	var impulse: Vector3 = direction.normalized() * minf(strength, max_hit_strength)
	_hit_impulse += impulse

	if not _is_reacting:
		_is_reacting = true
		hit_reaction_started.emit()


## Update hit reaction decay
func _update_hit_reactions(delta: float) -> void:
	if not _is_reacting:
		return

	# Decay the impulse
	_hit_impulse = _hit_impulse.lerp(Vector3.ZERO, hit_reaction_decay * delta)

	# Check if reaction is done
	if _hit_impulse.length() < 0.01:
		_hit_impulse = Vector3.ZERO
		_is_reacting = false
		hit_reaction_ended.emit()
		return

	# Apply hit reaction to spine
	_apply_hit_reaction()


## Apply hit reaction to spine
func _apply_hit_reaction() -> void:
	if _spine_bones.is_empty():
		return

	# Convert world-space impulse to character-local
	var local_impulse := _hit_impulse
	if character_body:
		local_impulse = character_body.global_transform.basis.inverse() * _hit_impulse

	# Apply rotation based on hit direction
	var rotation := Vector3(
		local_impulse.z * 0.3,  # Hit from front/back
		0,
		-local_impulse.x * 0.3  # Hit from sides
	)

	# Apply stronger to upper spine
	for i in _spine_bones.size():
		var bone_idx: int = _spine_bones[i]
		var weight := float(i + 1) / _spine_bones.size()  # Increase toward head
		_apply_additive_rotation(bone_idx, rotation * weight)


# =============================================================================
# UTILITY
# =============================================================================

## Apply additive rotation to a bone
func _apply_additive_rotation(bone_idx: int, euler: Vector3) -> void:
	if bone_idx < 0 or not skeleton:
		return

	# Get current pose
	var current_pose := skeleton.get_bone_pose(bone_idx)

	# Create additive rotation
	var additive := Basis.from_euler(euler)

	# Apply additively
	var new_basis := current_pose.basis * additive

	# Set new rotation
	skeleton.set_bone_pose_rotation(bone_idx, new_basis.get_rotation_quaternion())


## Find spine and chest bones
func _find_bones() -> void:
	if not skeleton:
		return

	_spine_bones.clear()

	var bone_count := skeleton.get_bone_count()
	var spine_candidates: Array[Dictionary] = []

	for i in bone_count:
		var name_lower := skeleton.get_bone_name(i).to_lower()

		# Find chest
		if "chest" in name_lower:
			_chest_bone_idx = i

		# Find spine bones
		if "spine" in name_lower:
			# Try to extract number for ordering
			var num := -1
			if "1" in name_lower:
				num = 1
			elif "2" in name_lower:
				num = 2
			elif "3" in name_lower:
				num = 3
			else:
				num = 0

			spine_candidates.append({"idx": i, "order": num})

	# Sort spine bones by number
	spine_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.order < b.order
	)

	for candidate in spine_candidates:
		_spine_bones.append(candidate.idx as int)

	# If no chest found, use last spine
	if _chest_bone_idx < 0 and not _spine_bones.is_empty():
		_chest_bone_idx = _spine_bones[-1]
