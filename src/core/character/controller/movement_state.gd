## MovementState -- public per-frame snapshot published by CharacterMotor.
##
## Animation, camera, interaction, debug UI, and gameplay should observe this
## state instead of reaching into MoveContainer internals.
class_name MovementState
extends Resource

var active_move_name: StringName = &""
var animation_state: StringName = &""
var posture: StringName = &"standing"
var is_grounded: bool = false
var is_in_water: bool = false
var input_direction: Vector2 = Vector2.ZERO
var input_strength: float = 0.0
var desired_world_direction: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO
var is_sprinting: bool = false
var is_walking: bool = false
var is_crouching: bool = false
var is_jumping: bool = false
var is_swimming: bool = false
var elapsed_time: float = 0.0
var last_transition_reason: StringName = &""


func copy_from(other: MovementState) -> void:
	active_move_name = other.active_move_name
	animation_state = other.animation_state
	posture = other.posture
	is_grounded = other.is_grounded
	is_in_water = other.is_in_water
	input_direction = other.input_direction
	input_strength = other.input_strength
	desired_world_direction = other.desired_world_direction
	velocity = other.velocity
	is_sprinting = other.is_sprinting
	is_walking = other.is_walking
	is_crouching = other.is_crouching
	is_jumping = other.is_jumping
	is_swimming = other.is_swimming
	elapsed_time = other.elapsed_time
	last_transition_reason = other.last_transition_reason
