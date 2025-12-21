## AnimationLODManager - Manages Level of Detail for character animations
##
## Adjusts animation update rates based on distance from camera to optimize performance
## Critical for handling 100+ NPCs in open world environments
##
## Phase 1 implementation for production-ready animation system
class_name AnimationLODManager
extends Node

# LOD Configuration
enum LODLevel {
	HIGH,      # Full animation updates (close)
	MEDIUM,    # Reduced updates (medium distance)
	LOW,       # Minimal updates (far)
	CULLED     # No updates (very far or off-screen)
}

# Distance thresholds (in meters)
@export var lod_high_distance: float = 15.0
@export var lod_medium_distance: float = 40.0
@export var lod_low_distance: float = 80.0
@export var lod_cull_distance: float = 150.0

# Update rates (frames per second)
@export var high_update_rate: float = 60.0    # Full framerate
@export var medium_update_rate: float = 20.0  # Reduced
@export var low_update_rate: float = 5.0      # Minimal
@export var culled_update_rate: float = 0.0   # Frozen

# Current state
var current_lod_level: LODLevel = LODLevel.HIGH
var update_timer: float = 0.0
var seconds_per_update: float = 0.0

# References
var animation_controller: CharacterAnimationController
var character_body: CharacterBody3D
var camera: Camera3D  # Will be set by manager or found automatically

# Culling
var is_in_view_frustum: bool = true


func _ready() -> void:
	set_process(false)  # Only enable after setup


## Setup LOD manager
func setup(anim_controller: CharacterAnimationController, char_body: CharacterBody3D) -> void:
	animation_controller = anim_controller
	character_body = char_body

	if not animation_controller or not character_body:
		push_warning("AnimationLODManager: Invalid animation controller or character body")
		return

	# Find camera if not set
	if not camera:
		_find_camera()

	# Start at high LOD
	_set_lod_level(LODLevel.HIGH)
	set_process(true)


## Find active camera in scene
func _find_camera() -> void:
	var viewport := get_viewport()
	if viewport:
		camera = viewport.get_camera_3d()


func _process(delta: float) -> void:
	if not camera or not character_body or not animation_controller:
		return

	# Calculate distance to camera
	var distance := camera.global_position.distance_to(character_body.global_position)

	# Determine appropriate LOD level
	var target_lod := _calculate_lod_level(distance)

	# Check frustum culling (optional optimization)
	if is_instance_valid(camera):
		is_in_view_frustum = _is_in_camera_frustum()
		if not is_in_view_frustum and distance > lod_medium_distance:
			target_lod = LODLevel.CULLED

	# Update LOD if changed
	if target_lod != current_lod_level:
		_set_lod_level(target_lod)

	# Handle throttled updates
	_handle_throttled_updates(delta)


## Calculate LOD level based on distance
func _calculate_lod_level(distance: float) -> LODLevel:
	if distance < lod_high_distance:
		return LODLevel.HIGH
	elif distance < lod_medium_distance:
		return LODLevel.MEDIUM
	elif distance < lod_low_distance:
		return LODLevel.LOW
	elif distance < lod_cull_distance:
		return LODLevel.LOW  # Still update minimally
	else:
		return LODLevel.CULLED


## Set LOD level and update configuration
func _set_lod_level(level: LODLevel) -> void:
	current_lod_level = level

	# Configure update rate
	match level:
		LODLevel.HIGH:
			seconds_per_update = 1.0 / high_update_rate if high_update_rate > 0 else 0
			_set_animation_active(true)
		LODLevel.MEDIUM:
			seconds_per_update = 1.0 / medium_update_rate if medium_update_rate > 0 else 0
			_set_animation_active(true)
		LODLevel.LOW:
			seconds_per_update = 1.0 / low_update_rate if low_update_rate > 0 else 0
			_set_animation_active(true)
		LODLevel.CULLED:
			seconds_per_update = 0
			_set_animation_active(false)

	update_timer = 0.0


## Handle throttled animation updates
func _handle_throttled_updates(delta: float) -> void:
	if current_lod_level == LODLevel.HIGH:
		# High LOD - update every frame (no throttling)
		return

	if current_lod_level == LODLevel.CULLED:
		# Culled - no updates
		return

	# Throttled updates for MEDIUM and LOW
	update_timer += delta

	if update_timer >= seconds_per_update:
		# Time for an update
		update_timer = 0.0

		# Force animation tree to update (if it was paused)
		if animation_controller and animation_controller.animation_tree:
			animation_controller.animation_tree.advance(seconds_per_update)


## Set animation active state
func _set_animation_active(active: bool) -> void:
	if not animation_controller:
		return

	if animation_controller.animation_tree:
		animation_controller.animation_tree.active = active

	if animation_controller.animation_player:
		if active:
			# Resume playback
			animation_controller.animation_player.speed_scale = 1.0
		else:
			# Freeze animation
			animation_controller.animation_player.speed_scale = 0.0


## Check if character is in camera frustum
func _is_in_camera_frustum() -> bool:
	if not camera or not character_body:
		return true  # Assume visible if we can't check

	# Get camera frustum planes
	var frustum := camera.get_frustum()

	# Simple sphere check using character position
	var character_pos := character_body.global_position
	var check_radius := 2.0  # Approximate character radius

	# Check if point is outside any plane
	for plane in frustum:
		if plane.distance_to(character_pos) < -check_radius:
			return false  # Outside frustum

	return true


## Force update LOD level (useful for debugging)
func force_lod_level(level: LODLevel) -> void:
	_set_lod_level(level)


## Get current LOD level
func get_lod_level() -> LODLevel:
	return current_lod_level


## Get LOD level as string (for debugging)
func get_lod_level_name() -> String:
	match current_lod_level:
		LODLevel.HIGH:
			return "HIGH"
		LODLevel.MEDIUM:
			return "MEDIUM"
		LODLevel.LOW:
			return "LOW"
		LODLevel.CULLED:
			return "CULLED"
		_:
			return "UNKNOWN"


## Set camera manually (useful if camera changes)
func set_camera(new_camera: Camera3D) -> void:
	camera = new_camera


## Get current distance to camera
func get_distance_to_camera() -> float:
	if camera and character_body:
		return camera.global_position.distance_to(character_body.global_position)
	return 0.0
