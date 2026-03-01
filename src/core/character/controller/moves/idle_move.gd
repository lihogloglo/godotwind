## IdleMove — Standing still, waiting for input
class_name IdleMove
extends Move


func _init() -> void:
	move_name = &"idle"
	animation_state = &"Idle"
	priority = 0


func default_lifecycle(input: InputPackage) -> StringName:
	if not player.is_on_floor() and container and container.has_method("has_move"):
		if container.has_move(&"midair"):
			return &"midair"
	return best_input_that_can_be_paid(input)


func update(_input: InputPackage, delta: float) -> void:
	# Apply gravity even while idle, and move_and_slide to stay grounded
	if not player.is_on_floor():
		player.velocity.y -= gravity * delta
	player.move_and_slide()


func on_enter_state() -> void:
	player.velocity = Vector3.ZERO
