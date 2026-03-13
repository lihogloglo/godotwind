## SwimIdleMove — Treading water, buoyant, no gravity
class_name SwimIdleMove
extends Move

## Buoyancy strength — how fast the player bobs to surface
@export var buoyancy_strength: float = 4.0
## Damping applied to velocity while treading water
@export var water_drag: float = 3.0


func _init() -> void:
	move_name = &"swim_idle"
	animation_state = &"SwimIdle"
	priority = 6  # Above midair (4) and jump (5) — roaster's note


func default_lifecycle(input: InputPackage) -> StringName:
	# Left the water — fall
	if not input.is_in_water:
		if player.is_on_floor():
			return &"idle"
		if container and container.has_move(&"midair"):
			return &"midair"
		return &"idle"
	# Has directional input — swim forward
	if input.input_direction != Vector2.ZERO or absf(input.vertical_input) > 0.1:
		if container and container.has_move(&"swim"):
			return &"swim"
	return &"okay"


func update(input: InputPackage, delta: float) -> void:
	# Buoyancy: nudge toward water surface
	var depth := input.water_surface_y - player.global_position.y
	player.velocity.y += clampf(depth * buoyancy_strength, -2.0, 2.0) * delta * 10.0

	# Water drag — slow horizontal movement
	player.velocity.x = lerpf(player.velocity.x, 0.0, water_drag * delta)
	player.velocity.z = lerpf(player.velocity.z, 0.0, water_drag * delta)

	# Damp vertical velocity toward zero when near surface
	if absf(depth) < 0.3:
		player.velocity.y = lerpf(player.velocity.y, 0.0, water_drag * delta)
