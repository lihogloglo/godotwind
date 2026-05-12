## SwimIdleMove - Treading water, buoyant, no gravity
class_name SwimIdleMove
extends Move

var _swim_jump_cooldown: float = 0.0


func _init() -> void:
	move_name = &"swim_idle"
	animation_state = &"SwimIdle"
	priority = 6  # Above midair (4) and jump (5)


func on_enter_state() -> void:
	_swim_jump_cooldown = 0.0


func default_lifecycle(input: InputPackage) -> StringName:
	if not input.is_in_water:
		if player.is_on_floor():
			return &"idle"
		if container and container.has_move(&"midair"):
			return &"midair"
		return &"idle"
	if input.input_direction != Vector2.ZERO or absf(input.vertical_input) > 0.1:
		if container and container.has_move(&"swim"):
			return &"swim"
	return &"okay"


func update(input: InputPackage, delta: float) -> void:
	var config := get_movement_config()
	var depth := input.water_surface_y - player.global_position.y - config.swim_submersion_depth
	player.velocity.y += clampf(depth * config.swim_buoyancy_strength, -2.0, 2.0) * delta * 10.0

	player.velocity.x = lerpf(player.velocity.x, 0.0, config.swim_idle_drag * delta)
	player.velocity.z = lerpf(player.velocity.z, 0.0, config.swim_idle_drag * delta)

	if absf(depth) < 0.3:
		player.velocity.y = lerpf(player.velocity.y, 0.0, config.swim_idle_drag * delta)
	_apply_swim_jump(input, config, delta)
	_clamp_to_water_surface(input, config)


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
