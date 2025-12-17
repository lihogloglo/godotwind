## DeformableAgent - Component for entities that create terrain deformation
## Attach to player, NPCs, or vehicles to create footprints/tracks
class_name DeformableAgent
extends Node3D

## Configuration
@export_group("Deformation Settings")
@export var deformation_radius: float = 0.3  ## Footprint/stamp size in meters
@export_range(0.0, 2.0) var deformation_strength: float = 1.0  ## Pressure multiplier
@export var deformation_frequency: float = 10.0  ## Stamps per second (Hz)
@export var min_velocity: float = 0.1  ## Minimum movement speed to deform

## Advanced
@export_group("Advanced")
@export var velocity_affects_strength: bool = true  ## Higher velocity = deeper impressions
@export var raycast_to_ground: bool = true  ## Only deform when on ground
@export var raycast_length: float = 2.0

## State
var last_deformation_time: float = 0.0
var last_deformation_pos: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO


func _ready() -> void:
	last_deformation_pos = global_position


func _physics_process(delta: float) -> void:
	if not DeformationManager.enabled:
		return

	# Calculate velocity
	velocity = (global_position - last_deformation_pos) / delta
	var speed := velocity.length()

	# Check movement threshold
	if speed < min_velocity:
		return

	# Check deformation frequency
	var current_time := Time.get_ticks_msec() / 1000.0
	if current_time - last_deformation_time < 1.0 / deformation_frequency:
		return

	# Optional ground check
	if raycast_to_ground:
		if not _is_on_ground():
			return

	# Calculate deformation strength
	var strength := deformation_strength
	if velocity_affects_strength:
		strength *= clamp(speed / 5.0, 0.5, 2.0)  # Scale with velocity

	# Apply deformation
	DeformationManager.apply_deformation(global_position, {
		"radius": deformation_radius,
		"strength": strength,
	})

	last_deformation_time = current_time
	last_deformation_pos = global_position


## Check if agent is on ground via raycast
func _is_on_ground() -> bool:
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		global_position + Vector3.UP * 0.5,
		global_position + Vector3.DOWN * raycast_length
	)

	var result := space_state.intersect_ray(query)
	return not result.is_empty()
