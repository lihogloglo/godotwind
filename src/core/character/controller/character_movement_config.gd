## CharacterMovementConfig - single source of character movement tuning.
##
## Generic framework resource. Game-specific adapters, such as Morrowind, should
## populate this resource instead of hard-coding behavior in shared move scripts.
class_name CharacterMovementConfig
extends Resource

@export_group("Ground Speeds")
@export_range(0.0, 10.0, 0.1) var walk_speed: float = 2.5
@export_range(0.0, 20.0, 0.1) var run_speed: float = 5.0
@export_range(0.0, 30.0, 0.1) var sprint_speed: float = 8.0
@export_range(0.0, 10.0, 0.1) var crouch_speed: float = 2.0

@export_group("Turning")
@export_range(0.0, 20.0, 0.1) var walk_turn_speed: float = 1.5
@export_range(0.0, 20.0, 0.1) var run_turn_speed: float = 3.0
@export_range(0.0, 20.0, 0.1) var sprint_turn_speed: float = 5.0
@export_range(0.0, 20.0, 0.1) var walk_tracking_angular_speed: float = 8.0
@export_range(0.0, 20.0, 0.1) var ground_tracking_angular_speed: float = 10.0
@export_range(0.0, 20.0, 0.1) var swim_tracking_angular_speed: float = 8.0
@export var turn_to_movement_direction: bool = true
@export var smooth_movement: bool = true
@export_range(0.0, 1.0, 0.01) var smooth_player_turning_delay: float = 0.0

@export_group("Backward Movement")
@export_range(0.0, 180.0, 1.0, "degrees") var backward_angle_degrees: float = 120.0
@export_range(0.0, 1.0, 0.01) var backward_speed_multiplier: float = 0.7

@export_group("Jump And Air")
@export_range(0.0, 20.0, 0.1) var jump_velocity: float = 4.5
@export_range(0.0, 1.0, 0.01) var jump_min_time: float = 0.1
@export_range(0.0, 1.0, 0.01) var ground_to_midair_lockout: float = 0.1
@export_range(0.0, 1.0, 0.01) var coyote_time: float = 0.1
@export_range(0.0, 1.0, 0.01) var jump_buffer_time: float = 0.12
@export_range(0.0, 1.0, 0.01) var air_control: float = 0.3
@export_range(0.0, 20.0, 0.1) var air_speed: float = 5.0

@export_group("Crouch Posture")
@export_range(0.5, 3.0, 0.05) var standing_height: float = 1.8
@export_range(0.5, 3.0, 0.05) var crouch_height: float = 1.0
@export_range(0.1, 1.0, 0.01) var player_radius: float = 0.35
@export_range(0.0, 3.0, 0.05) var standing_eye_height: float = 1.7
@export_range(0.0, 3.0, 0.05) var crouch_eye_height: float = 1.58
@export_range(0.0, 0.1, 0.005) var stand_up_clearance_margin: float = 0.02

@export_group("Swimming")
@export_range(0.0, 20.0, 0.1) var swim_speed: float = 3.5
@export_range(0.0, 20.0, 0.1) var swim_acceleration: float = 5.0
@export_range(0.0, 20.0, 0.1) var swim_buoyancy_strength: float = 4.0
@export_range(0.0, 20.0, 0.1) var swim_drag: float = 2.0
@export_range(0.0, 20.0, 0.1) var swim_idle_drag: float = 3.0
@export_range(0.0, 3.0, 0.05) var swim_submersion_depth: float = 1.2
@export_range(0.0, 2.0, 0.05) var swim_min_feet_submersion: float = 0.35
@export_range(0.0, 10.0, 0.1) var swim_jump_velocity: float = 2.4
@export_range(0.05, 2.0, 0.01) var swim_jump_repeat_time: float = 0.45
@export var swim_upward_correction_enabled: bool = false
@export_range(0.0, 10.0, 0.1) var swim_upward_coef: float = 1.0

@export_group("Step And Floor")
@export_range(0.0, 90.0, 1.0, "degrees") var max_floor_angle_degrees: float = 50.0
@export_range(0.0, 2.0, 0.01) var floor_snap_length: float = 0.3
@export_range(0.0, 2.0, 0.01) var step_up_height: float = 0.45
@export_range(0.0, 2.0, 0.01) var step_down_height: float = 0.45
@export_range(0.0, 1.0, 0.01) var min_step_height: float = 0.0

@export_group("Capabilities")
@export var can_walk: bool = true
@export var can_sprint: bool = true
@export var can_crouch: bool = true
@export var can_jump: bool = true
@export var can_swim: bool = true


func get_backward_angle_radians() -> float:
	return deg_to_rad(backward_angle_degrees)


func get_max_floor_angle_radians() -> float:
	return deg_to_rad(max_floor_angle_degrees)
