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
	if input.is_in_water and container and container.has_move(&"swim_idle"):
		return &"swim_idle"
	if not player.is_on_floor() and container and container.has_move(&"midair"):
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
