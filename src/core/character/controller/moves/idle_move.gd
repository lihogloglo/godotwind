## IdleMove — Standing still, waiting for input
class_name IdleMove
extends Move


func _init() -> void:
	move_name = &"idle"
	animation_state = &"Idle"
	priority = 0


func default_lifecycle(input: InputPackage) -> StringName:
	# Swimming takes priority over midair check
	if input.is_in_water and container and container.has_move(&"swim_idle"):
		return &"swim_idle"
	if not player.is_on_floor() and container and container.has_move(&"midair"):
		return &"midair"
	return best_input_that_can_be_paid(input)


func update(_input: InputPackage, delta: float) -> void:
	# Apply gravity — only touch Y, preserve horizontal for slope sliding
	if not player.is_on_floor():
		player.velocity.y -= gravity * delta
	# Zero horizontal movement while idle
	player.velocity.x = 0.0
	player.velocity.z = 0.0


func on_enter_state() -> void:
	# Only zero horizontal — preserve Y for gravity/landing
	player.velocity.x = 0.0
	player.velocity.z = 0.0
