## InputPackage — Clean data container for per-frame input state
##
## Gathered by PlayerInputGatherer (player) or AIInputGatherer (NPC) each frame.
## Consumed by MoveContainer → current Move to decide transitions and movement.
class_name InputPackage
extends Resource

## Available actions this frame (e.g. "idle", "run", "sprint", "jump_run", "roll")
var actions: Array[StringName] = []

## Combat-specific inputs (e.g. "light_attack_pressed", "heavy_attack_pressed")
var combat_actions: Array[StringName] = []

## Movement stick direction (normalized, camera-relative 2D)
var input_direction: Vector2 = Vector2.ZERO

## Camera orientation basis (for converting input_direction to world-space 3D)
var camera_basis: Basis = Basis.IDENTITY

## Vertical input for swimming/flying: camera pitch / crouch-driven continuous axis.
var vertical_input: float = 0.0

## Held jump intent while swimming. Swim moves consume this as repeated
## upward strokes instead of a continuous ascend axis.
var swim_jump_held: bool = false

## Whether the player is currently in water (set by PlayerController)
var is_in_water: bool = false

## Water surface Y height at player position (set by PlayerController)
var water_surface_y: float = 0.0
