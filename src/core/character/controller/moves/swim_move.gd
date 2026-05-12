## SwimMove - Directional swimming with 3D camera-relative movement
class_name SwimMove
extends Move

var _swim_jump_cooldown: float = 0.0


func _init() -> void:
	move_name = &"swim"
	animation_state = &"SwimForward"
	priority = 7  # Above swim_idle (6)


func on_enter_state() -> void:
	_swim_jump_cooldown = 0.0


func default_lifecycle(input: InputPackage) -> StringName:
	if not input.is_in_water:
		if player.is_on_floor():
			return &"idle"
		if container and container.has_move(&"midair"):
			return &"midair"
		return &"idle"
	if input.input_direction == Vector2.ZERO and absf(input.vertical_input) < 0.1:
		if container and container.has_move(&"swim_idle"):
			return &"swim_idle"
	return &"okay"


func update(input: InputPackage, delta: float) -> void:
	var config := get_movement_config()
	var target_velocity := Vector3.ZERO
	if input.input_direction != Vector2.ZERO:
		var input_dir_3d := (input.camera_basis * Vector3(
			input.input_direction.x, 0.0, input.input_direction.y)).normalized()
		target_velocity = input_dir_3d * config.swim_speed

	target_velocity.y += input.vertical_input * config.swim_speed
	player.velocity = player.velocity.lerp(target_velocity, config.swim_acceleration * delta)

	var depth := input.water_surface_y - player.global_position.y - config.swim_submersion_depth
	player.velocity.y += clampf(depth * config.swim_buoyancy_strength, -2.0, 2.0) * delta * 10.0
	_apply_swim_jump(input, config, delta)
	_clamp_to_water_surface(input, config)

	if input.input_direction != Vector2.ZERO:
		var facing: Node3D = character_root if character_root else player
		if facing and config.turn_to_movement_direction:
			var face_dir := (input.camera_basis * Vector3(
				input.input_direction.x, 0.0, input.input_direction.y)).normalized()
			var face_direction := -facing.basis.z
			var angle := face_direction.signed_angle_to(face_dir, Vector3.UP)
			facing.rotate_y(clampf(angle,
				-config.swim_tracking_angular_speed * delta, config.swim_tracking_angular_speed * delta))


func _apply_swim_jump(input: InputPackage, config: CharacterMovementConfig, delta: float) -> void:
	_swim_jump_cooldown = maxf(_swim_jump_cooldown - delta, 0.0)
	if not input.swim_jump_held or _swim_jump_cooldown > 0.0:
		return
	player.velocity.y = maxf(player.velocity.y, config.swim_jump_velocity)
	_swim_jump_cooldown = config.swim_jump_repeat_time


func _clamp_to_water_surface(input: InputPackage, config: CharacterMovementConfig) -> void:
	if input.water_surface_y == -INF:
		return
	var max_feet_y := input.water_surface_y - config.swim_min_feet_submersion
	if player.global_position.y >= max_feet_y and player.velocity.y > 0.0:
		player.velocity.y = 0.0
	if player.global_position.y > max_feet_y:
		player.velocity.y = minf(
			player.velocity.y,
			(max_feet_y - player.global_position.y) * config.swim_buoyancy_strength
		)
