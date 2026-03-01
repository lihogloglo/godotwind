## WalkMove — Slow movement when walk key is held
class_name WalkMove
extends Move

@export var speed: float = 2.5
@export var turn_speed: float = 1.5


func _init() -> void:
	move_name = &"walk"
	animation_state = &"Walk"
	priority = 1  # Below run (2), above idle (0)
	tracking_angular_speed = 8.0


func default_lifecycle(input: InputPackage) -> StringName:
	if not player.is_on_floor() and container and container.has_method("has_move"):
		if container.has_move(&"midair"):
			return &"midair"
	return best_input_that_can_be_paid(input)


func update(_input: InputPackage, delta: float) -> void:
	if not player.is_on_floor():
		player.velocity.y -= gravity * delta
	player.move_and_slide()


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
