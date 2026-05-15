## MidairMove - Falling/airborne state with air control
class_name MidairMove
extends Move


func _init() -> void:
	move_name = &"midair"
	animation_state = &"Fall"
	priority = 4  # Above locomotion, below jump


func default_lifecycle(input: InputPackage) -> StringName:
	var config := get_movement_config()
	if input.is_in_water and config.can_swim and container and container.has_move(&"swim_idle"):
		return &"swim_idle"
	if player.is_on_floor():
		return best_input_that_can_be_paid(input)
	return &"okay"


func update(input: InputPackage, delta: float) -> void:
	var config := get_movement_config()
	player.velocity.y -= gravity * delta

	if input.input_direction != Vector2.ZERO:
		var input_dir_3d := (input.movement_basis * Vector3(
			input.input_direction.x, 0.0, input.input_direction.y)).normalized()
		var target_h := input_dir_3d * config.air_speed
		player.velocity.x = lerpf(player.velocity.x, target_h.x, config.air_control * delta * 10.0)
		player.velocity.z = lerpf(player.velocity.z, target_h.z, config.air_control * delta * 10.0)
