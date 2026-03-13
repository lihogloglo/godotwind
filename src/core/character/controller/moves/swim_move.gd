## SwimMove — Directional swimming with 3D camera-relative movement
class_name SwimMove
extends Move

@export var swim_speed: float = 3.5
@export var swim_acceleration: float = 5.0
@export var buoyancy_strength: float = 4.0
@export var water_drag: float = 2.0


func _init() -> void:
	move_name = &"swim"
	animation_state = &"SwimForward"
	priority = 7  # Above swim_idle (6)
	tracking_angular_speed = 8.0


func default_lifecycle(input: InputPackage) -> StringName:
	# Left the water
	if not input.is_in_water:
		if player.is_on_floor():
			return &"idle"
		if container and container.has_move(&"midair"):
			return &"midair"
		return &"idle"
	# No input — return to swim idle
	if input.input_direction == Vector2.ZERO and absf(input.vertical_input) < 0.1:
		if container and container.has_move(&"swim_idle"):
			return &"swim_idle"
	return &"okay"


func update(input: InputPackage, delta: float) -> void:
	# Camera-relative 3D movement
	var target_velocity := Vector3.ZERO
	if input.input_direction != Vector2.ZERO:
		var input_dir_3d := (input.camera_basis * Vector3(
			input.input_direction.x, 0.0, input.input_direction.y)).normalized()
		target_velocity = input_dir_3d * swim_speed

	# Vertical intent (jump = ascend, crouch = descend, camera pitch contributes)
	target_velocity.y += input.vertical_input * swim_speed

	# Lerp to target for smooth acceleration
	player.velocity = player.velocity.lerp(target_velocity, swim_acceleration * delta)

	# Buoyancy: nudge toward surface
	var depth := input.water_surface_y - player.global_position.y
	player.velocity.y += clampf(depth * buoyancy_strength, -2.0, 2.0) * delta

	# Rotate character to face movement direction (horizontal only)
	if input.input_direction != Vector2.ZERO:
		var facing: Node3D = character_root if character_root else player
		var face_dir := (input.camera_basis * Vector3(
			input.input_direction.x, 0.0, input.input_direction.y)).normalized()
		var face_direction := -facing.basis.z
		var angle := face_direction.signed_angle_to(face_dir, Vector3.UP)
		facing.rotate_y(clampf(angle,
			-tracking_angular_speed * delta, tracking_angular_speed * delta))
