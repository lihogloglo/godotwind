## SprintMove — Fast ground movement, drains stamina
class_name SprintMove
extends Move

@export var speed: float = 8.0
@export var turn_speed: float = 5.0
@export var sprint_stamina_cost_per_sec: float = 20.0


func _init() -> void:
	move_name = &"sprint"
	animation_state = &"Sprint"
	priority = 3  # Highest locomotion priority
	tracking_angular_speed = 10.0


func default_lifecycle(input: InputPackage) -> StringName:
	if not player.is_on_floor() and container and container.has_method("has_move"):
		if container.has_move(&"midair"):
			return &"midair"
	return best_input_that_can_be_paid(input)


func update(_input: InputPackage, delta: float) -> void:
	if not player.is_on_floor():
		player.velocity.y -= gravity * delta
	player.move_and_slide()
	# Drain stamina while sprinting (Phase 4 — resources)
	if resources and resources.has_method("lose_stamina"):
		resources.lose_stamina(sprint_stamina_cost_per_sec * delta)


func _update(input: InputPackage, delta: float) -> void:
	if input.input_direction != Vector2.ZERO:
		_apply_movement(input, delta)
	update(input, delta)


func _apply_movement(input: InputPackage, delta: float) -> void:
	var input_dir_3d := (input.camera_basis * Vector3(
		input.input_direction.x, 0.0, input.input_direction.y)).normalized()
	var facing: Node3D = character_root if character_root else player
	var face_direction := facing.basis.z
	var angle := face_direction.signed_angle_to(input_dir_3d, Vector3.UP)

	if absf(angle) >= tracking_angular_speed * delta:
		player.velocity = face_direction.rotated(
			Vector3.UP, signf(angle) * tracking_angular_speed * delta) * turn_speed
		facing.rotate_y(signf(angle) * tracking_angular_speed * delta)
	else:
		player.velocity = face_direction.rotated(Vector3.UP, angle) * speed
		facing.rotate_y(angle)

	# Scale animation speed proportional to actual velocity
	var vel_ratio := player.velocity.length() / speed
	if animator and animator.has_method("set_speed_scale"):
		animator.set_speed_scale(vel_ratio)


func on_exit_state() -> void:
	if animator and animator.has_method("set_speed_scale"):
		animator.set_speed_scale(1.0)
