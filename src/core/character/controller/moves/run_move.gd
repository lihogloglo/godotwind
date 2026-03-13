## RunMove — Default ground locomotion
class_name RunMove
extends Move

@export var speed: float = 5.0
@export var turn_speed: float = 3.0

var _current_dir_anim: StringName = &""


func _init() -> void:
	move_name = &"run"
	animation_state = &"Run"
	priority = 2  # Above walk (1), below sprint (3)
	tracking_angular_speed = 10.0


func default_lifecycle(input: InputPackage) -> StringName:
	if input.is_in_water and container and container.has_move(&"swim_idle"):
		return &"swim_idle"
	# Landing lockout: don't transition to midair for 0.1s after entering (prevents Jolt bounce)
	if works_longer_than(0.1) and not player.is_on_floor() and container and container.has_move(&"midair"):
		return &"midair"
	return best_input_that_can_be_paid(input)


func update(_input: InputPackage, delta: float) -> void:
	# Apply gravity — Y only
	if not player.is_on_floor():
		player.velocity.y -= gravity * delta


func _update(input: InputPackage, delta: float) -> void:
	if input.input_direction != Vector2.ZERO:
		_apply_movement(input, delta)
	update(input, delta)


func _apply_movement(input: InputPackage, delta: float) -> void:
	var input_dir_3d := (input.camera_basis * Vector3(
		input.input_direction.x, 0.0, input.input_direction.y)).normalized()
	var facing: Node3D = character_root if character_root else player
	var face_direction := -facing.basis.z
	var angle := face_direction.signed_angle_to(input_dir_3d, Vector3.UP)

	var move_dir: Vector3
	# Backward movement: if input is mostly behind the character, move backward
	# without rotating (MW-style). Threshold: >120 degrees from facing.
	if absf(angle) > 2.1:  # ~120 degrees
		# Move backward along facing direction
		move_dir = -face_direction * speed * 0.7  # Backward is slower
		if _current_dir_anim != &"RunBack":
			_current_dir_anim = &"RunBack"
			if animator:
				animator.transition_to(&"RunBack", true)
	else:
		if _current_dir_anim != &"Run":
			_current_dir_anim = &"Run"
			if animator:
				animator.transition_to(&"Run", true)
		if absf(angle) >= tracking_angular_speed * delta:
			move_dir = face_direction.rotated(
				Vector3.UP, signf(angle) * tracking_angular_speed * delta) * turn_speed
			facing.rotate_y(signf(angle) * tracking_angular_speed * delta)
		else:
			move_dir = face_direction.rotated(Vector3.UP, angle) * speed
			facing.rotate_y(angle)

	# Only set horizontal velocity — preserve Y for gravity/jump
	player.velocity.x = move_dir.x
	player.velocity.z = move_dir.z

	# Scale animation speed proportional to actual horizontal velocity
	var h_speed := Vector2(player.velocity.x, player.velocity.z).length()
	var vel_ratio := h_speed / speed
	if animator and animator.has_method("set_speed_scale"):
		animator.set_speed_scale(vel_ratio)


func on_enter_state() -> void:
	_current_dir_anim = &"Run"


func on_exit_state() -> void:
	_current_dir_anim = &""
	if animator and animator.has_method("set_speed_scale"):
		animator.set_speed_scale(1.0)
