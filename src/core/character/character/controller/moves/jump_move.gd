## JumpMove - Jump initiation, applies upward velocity then transitions to midair
class_name JumpMove
extends Move


func _init() -> void:
	move_name = &"jump"
	animation_state = &"Jump"
	priority = 5  # Higher than locomotion, lower than combat


func default_lifecycle(_input: InputPackage) -> StringName:
	if works_longer_than(get_movement_config().jump_min_time):
		if container and container.has_move(&"midair"):
			return &"midair"
	return &"okay"


func update(_input: InputPackage, delta: float) -> void:
	player.velocity.y -= gravity * delta


func on_enter_state() -> void:
	player.velocity.y = get_movement_config().jump_velocity
