## CrouchMove - Crouched locomotion with reduced speed and shorter collision
class_name CrouchMove
extends Move

var _current_crouch_anim: StringName = &""


func _init() -> void:
	move_name = &"crouch"
	animation_state = &"Crouch"
	priority = 4  # Phase 1 contract: crouch posture wins over run/sprint.


func default_lifecycle(input: InputPackage) -> StringName:
	var config := get_movement_config()
	if input.is_in_water and config.can_swim and container and container.has_move(&"swim_idle"):
		return &"swim_idle"
	if should_enter_midair(input):
		return &"midair"
	# Stay crouching while crouch is held, otherwise uncrouch
	if not input.actions.has(&"crouch"):
		# Check if we can stand up (ceiling check)
		if _can_stand_up():
			return best_input_that_can_be_paid(input)
	return &"okay"


func update(input: InputPackage, delta: float) -> void:
	# Gravity
	if not player.is_on_floor():
		player.velocity.y -= gravity * delta

	# Movement while crouched - switch animation based on input direction
	if input.input_direction != Vector2.ZERO:
		var config := get_movement_config()
		# Check if moving backward relative to facing
		var input_dir_3d := (input.camera_basis * Vector3(
			input.input_direction.x, 0.0, input.input_direction.y)).normalized()
		var facing: Node3D = character_root if character_root else player
		var face_direction := -facing.basis.z
		var angle := face_direction.signed_angle_to(input_dir_3d, Vector3.UP)

		var target_anim: StringName = &"CrouchBack" if absf(angle) > config.get_backward_angle_radians() else &"CrouchWalk"
		if _current_crouch_anim != target_anim:
			_current_crouch_anim = target_anim
			if animator:
				animator.transition_to(target_anim, true)
		_apply_crouch_movement(input, delta)
	else:
		if _current_crouch_anim != &"Crouch":
			_current_crouch_anim = &"Crouch"
			if animator:
				animator.transition_to(&"Crouch", true)
		player.velocity.x = 0.0
		player.velocity.z = 0.0


func on_enter_state() -> void:
	_current_crouch_anim = &"Crouch"
	# Shrink collision shape
	_set_collision_height(get_movement_config().crouch_height)


func on_exit_state() -> void:
	# Restore collision shape
	_set_collision_height(get_movement_config().standing_height)


func _apply_crouch_movement(input: InputPackage, delta: float) -> void:
	var config := get_movement_config()
	var input_dir_3d := (input.camera_basis * Vector3(
		input.input_direction.x, 0.0, input.input_direction.y)).normalized()
	var facing: Node3D = character_root if character_root else player
	var face_direction := -facing.basis.z
	var angle := face_direction.signed_angle_to(input_dir_3d, Vector3.UP)

	var move_dir: Vector3
	if absf(angle) > config.get_backward_angle_radians():
		move_dir = -face_direction * config.crouch_speed * config.backward_speed_multiplier
	elif absf(angle) >= config.ground_tracking_angular_speed * delta:
		move_dir = face_direction.rotated(
			Vector3.UP, signf(angle) * config.ground_tracking_angular_speed * delta) * config.crouch_speed
		facing.rotate_y(signf(angle) * config.ground_tracking_angular_speed * delta)
	else:
		move_dir = face_direction.rotated(Vector3.UP, angle) * config.crouch_speed
		facing.rotate_y(angle)

	player.velocity.x = move_dir.x
	player.velocity.z = move_dir.z


func _set_collision_height(height: float) -> void:
	# Find the CollisionShape3D on the player
	for child in player.get_children():
		if child is CollisionShape3D and child.shape is CapsuleShape3D:
			var capsule: CapsuleShape3D = child.shape as CapsuleShape3D
			capsule.height = height
			child.position.y = height / 2.0
			break


func _can_stand_up() -> bool:
	var space_state := player.get_world_3d().direct_space_state
	if not space_state:
		return true
	var config := get_movement_config()
	var margin: float = clampf(config.stand_up_clearance_margin, 0.0, config.player_radius * 0.5)
	var capsule := CapsuleShape3D.new()
	capsule.radius = config.player_radius
	capsule.height = maxf(config.standing_height - margin * 2.0, config.player_radius * 2.0)

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.transform = Transform3D(player.global_transform.basis,
		player.global_position + Vector3.UP * (config.standing_height * 0.5))
	query.collision_mask = player.collision_mask
	var excluded: Array[RID] = []
	excluded.append(player.get_rid())
	query.exclude = excluded
	query.collide_with_bodies = true
	query.collide_with_areas = false
	var result := space_state.intersect_shape(query, 1)
	return result.is_empty()
