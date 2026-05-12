## WalkMove - Slow ground locomotion when the walk action is active
class_name WalkMove
extends Move

var _current_dir_anim: StringName = &""


func _init() -> void:
	move_name = &"walk"
	animation_state = &"Walk"
	priority = 1  # Below run (2), above idle (0)


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


func on_enter_state() -> void:
	_current_dir_anim = &"Walk"


func _apply_movement(input: InputPackage, delta: float) -> void:
	var config := get_movement_config()

	var move_dir := _resolve_tracked_motion(
		input, delta, config.walk_speed, config.walk_turn_speed,
		config.walk_tracking_angular_speed)
	if _is_backward_movement_input(input):
		if _current_dir_anim != &"WalkBack":
			_current_dir_anim = &"WalkBack"
			if animator:
				animator.transition_to(&"WalkBack", true)
	else:
		if _current_dir_anim != &"Walk":
			_current_dir_anim = &"Walk"
			if animator:
				animator.transition_to(&"Walk", true)

	player.velocity.x = move_dir.x
	player.velocity.z = move_dir.z
