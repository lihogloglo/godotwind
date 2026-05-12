## RunMove - Default ground locomotion
class_name RunMove
extends Move

var _current_dir_anim: StringName = &""


func _init() -> void:
	move_name = &"run"
	animation_state = &"Run"
	priority = 2  # Above walk (1), below sprint (3)


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


func _update(input: InputPackage, delta: float) -> void:
	if input.input_direction != Vector2.ZERO:
		_apply_movement(input, delta)
	update(input, delta)


func _apply_movement(input: InputPackage, delta: float) -> void:
	var config := get_movement_config()

	var move_dir := _resolve_tracked_motion(
		input, delta, config.run_speed, config.run_turn_speed,
		config.ground_tracking_angular_speed)
	if _is_backward_movement_input(input):
		if _current_dir_anim != &"RunBack":
			_current_dir_anim = &"RunBack"
			if animator:
				animator.transition_to(&"RunBack", true)
	else:
		if _current_dir_anim != &"Run":
			_current_dir_anim = &"Run"
			if animator:
				animator.transition_to(&"Run", true)

	player.velocity.x = move_dir.x
	player.velocity.z = move_dir.z

	var h_speed := Vector2(player.velocity.x, player.velocity.z).length()
	var vel_ratio := h_speed / maxf(config.run_speed, 0.001)
	if animator and animator.has_method("set_speed_scale"):
		animator.set_speed_scale(vel_ratio)


func on_enter_state() -> void:
	_current_dir_anim = &"Run"


func on_exit_state() -> void:
	_current_dir_anim = &""
	if animator and animator.has_method("set_speed_scale"):
		animator.set_speed_scale(1.0)
