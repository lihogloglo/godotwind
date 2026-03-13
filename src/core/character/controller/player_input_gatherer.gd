## PlayerInputGatherer — Reads hardware input into an InputPackage each frame
##
## Mirrors Gab-ani's InputGatherer pattern. Requires a camera_pivot reference
## for camera_basis (set by PlayerController on setup).
class_name PlayerInputGatherer
extends Node

## Camera pivot node — set by PlayerController so we can compute camera-relative direction
var camera_pivot: Node3D = null


## Gather all input state for this physics frame
func gather_input() -> InputPackage:
	var pkg := InputPackage.new()

	# Movement direction (analog-stick or WASD)
	pkg.input_direction = Input.get_vector(
		&"move_left", &"move_right", &"move_forward", &"move_backward")

	# Camera basis for world-space direction
	if camera_pivot:
		pkg.camera_basis = Basis(Vector3.UP, camera_pivot.rotation.y)

	# Vertical intent for swimming/flying
	if Input.is_action_pressed(&"jump"):
		pkg.vertical_input += 1.0
	if Input.is_action_pressed(&"crouch"):
		pkg.vertical_input -= 1.0
	# Camera pitch contributes to vertical when swimming/flying
	if camera_pivot and pkg.is_in_water:
		pkg.vertical_input += clampf(-camera_pivot.rotation.x * pkg.input_direction.length(), -1.0, 1.0)
	pkg.vertical_input = clampf(pkg.vertical_input, -1.0, 1.0)

	# --- Actions ---
	pkg.actions.append(&"idle")  # Always available as fallback

	if pkg.input_direction != Vector2.ZERO:
		# Walk and run are mutually exclusive; sprint stacks on top
		if Input.is_action_pressed(&"walk"):
			pkg.actions.append(&"walk")
		else:
			pkg.actions.append(&"run")
		# Sprint only when moving (no standing sprint)
		if Input.is_action_pressed(&"sprint"):
			pkg.actions.append(&"sprint")

	# Jump (only on ground — midair/swim jumps handled by their respective moves)
	if Input.is_action_just_pressed(&"jump"):
		pkg.actions.append(&"jump")

	# Crouch
	if Input.is_action_pressed(&"crouch"):
		pkg.actions.append(&"crouch")

	# Future combat actions
	#if Input.is_action_pressed(&"block"):
	#	pkg.actions.append(&"block")
	#if Input.is_action_pressed(&"roll"):
	#	pkg.actions.append(&"roll")

	return pkg
