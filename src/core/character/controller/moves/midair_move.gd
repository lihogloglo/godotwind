## MidairMove — Falling/airborne state with air control
class_name MidairMove
extends Move

## Air control factor (0 = no control, 1 = full ground-like control)
@export var air_control: float = 0.3
## Maximum horizontal air speed
@export var air_speed: float = 5.0
## Minimum time on ground before we can go back to midair (prevents bounce)
@export var landing_lockout: float = 0.1


func _init() -> void:
	move_name = &"midair"
	animation_state = &"Fall"
	priority = 4  # Above locomotion, below jump


func default_lifecycle(input: InputPackage) -> StringName:
	# Swimming takes priority
	if input.is_in_water and container and container.has_move(&"swim_idle"):
		return &"swim_idle"
	# Landed — return to idle (best_input will pick run/walk if input held)
	if player.is_on_floor():
		return best_input_that_can_be_paid(input)
	return &"okay"


func update(input: InputPackage, delta: float) -> void:
	# Gravity
	player.velocity.y -= gravity * delta

	# Air control — nudge horizontal velocity toward input direction
	if input.input_direction != Vector2.ZERO:
		var input_dir_3d := (input.camera_basis * Vector3(
			input.input_direction.x, 0.0, input.input_direction.y)).normalized()
		var target_h := input_dir_3d * air_speed
		player.velocity.x = lerpf(player.velocity.x, target_h.x, air_control * delta * 10.0)
		player.velocity.z = lerpf(player.velocity.z, target_h.z, air_control * delta * 10.0)
