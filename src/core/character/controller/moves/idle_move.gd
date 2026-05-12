## IdleMove - Standing still, waiting for input
class_name IdleMove
extends Move


func _init() -> void:
	move_name = &"idle"
	animation_state = &"Idle"
	priority = 0


func default_lifecycle(input: InputPackage) -> StringName:
	var config := get_movement_config()
	if input.is_in_water and config.can_swim and container and container.has_move(&"swim_idle"):
		return &"swim_idle"
	if should_enter_midair(input):
		return &"midair"
	return best_input_that_can_be_paid(input)


func update(_input: InputPackage, delta: float) -> void:
	if not player.is_on_floor():
		player.velocity.y -= gravity * delta
	player.velocity.x = 0.0
	player.velocity.z = 0.0


func on_enter_state() -> void:
	player.velocity.x = 0.0
	player.velocity.z = 0.0
