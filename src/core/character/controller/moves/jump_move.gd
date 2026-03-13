## JumpMove — Jump initiation, applies upward velocity then transitions to midair
class_name JumpMove
extends Move

@export var jump_velocity: float = 4.5
## Minimum time in jump state before transitioning to midair (prevents instant transition)
@export var min_jump_time: float = 0.1


func _init() -> void:
	move_name = &"jump"
	animation_state = &"Jump"  # Direct Idle→Jump path in state machine (avoids intermediate hops)
	priority = 5  # Higher than locomotion, lower than combat


func default_lifecycle(_input: InputPackage) -> StringName:
	# After min time, transition to midair
	if works_longer_than(min_jump_time):
		if container and container.has_move(&"midair"):
			return &"midair"
	return &"okay"


func update(_input: InputPackage, delta: float) -> void:
	# Gravity applied while jumping
	player.velocity.y -= gravity * delta


func on_enter_state() -> void:
	# Apply jump impulse — preserve horizontal velocity
	player.velocity.y = jump_velocity
