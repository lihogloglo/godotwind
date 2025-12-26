## AnimationLODController - Distance-based animation quality control
##
## Manages animation performance by adjusting quality based on:
## - Distance from camera
## - Frustum visibility
## - Character importance
##
## LOD Levels:
## - FULL: All features enabled (IK, procedural, full blend)
## - HIGH: IK enabled, reduced procedural
## - MEDIUM: No IK, simple blending
## - LOW: Single animation, minimal updates
## - CULLED: No animation updates
class_name AnimationLODController
extends Node

# Preload for typed access
const _CharacterAnimationSystemScript := preload("res://src/core/animation/character_animation_system.gd")

# LOD levels
enum LODLevel {
	FULL,    # < 15m - everything enabled
	HIGH,    # 15-30m - IK on, reduced procedural
	MEDIUM,  # 30-60m - No IK, simple blend
	LOW,     # 60-100m - Single anim, slow updates
	CULLED   # > 100m or off-screen - frozen
}

# Configuration
@export_group("Distance Thresholds")
@export var full_distance: float = 15.0
@export var high_distance: float = 30.0
@export var medium_distance: float = 60.0
@export var low_distance: float = 100.0

@export_group("Update Rates")
@export var full_fps: int = 60
@export var high_fps: int = 30
@export var medium_fps: int = 15
@export var low_fps: int = 5

@export_group("Features")
@export var use_frustum_culling: bool = true
@export var importance_boost: float = 0.0  # Reduce effective distance

# References
var animation_system: Node = null  # CharacterAnimationSystem (avoid cyclic dep)
var character_body: CharacterBody3D = null
var camera: Camera3D = null

# State
var _current_level: LODLevel = LODLevel.FULL
var _forced_level: int = -1  # -1 means not forced
var _frame_counter: int = 0
var _update_interval: int = 1
var _distance_to_camera: float = 0.0
var _is_visible: bool = true

# Cached
var _is_setup: bool = false


## Setup LOD controller
func setup(p_animation_system: Node,
		p_character_body: CharacterBody3D = null) -> void:
	animation_system = p_animation_system
	character_body = p_character_body

	# Find camera
	_find_camera()

	_is_setup = true


## Update LOD (called each physics frame)
func update(delta: float) -> void:
	if not _is_setup:
		return

	# Update frame counter
	_frame_counter += 1

	# Check if we should update this frame
	if _frame_counter < _update_interval:
		return

	_frame_counter = 0

	# Recalculate LOD level
	_update_lod_level()


## Get current LOD level
func get_current_level() -> int:
	if _forced_level >= 0:
		return _forced_level
	return _current_level


## Get LOD level name for debugging
func get_level_name() -> String:
	var level := get_current_level()
	match level:
		LODLevel.FULL: return "FULL"
		LODLevel.HIGH: return "HIGH"
		LODLevel.MEDIUM: return "MEDIUM"
		LODLevel.LOW: return "LOW"
		LODLevel.CULLED: return "CULLED"
		_: return "UNKNOWN"


## Get distance to camera
func get_distance_to_camera() -> float:
	return _distance_to_camera


## Force a specific LOD level (for testing)
func force_level(level: int) -> void:
	_forced_level = level
	_apply_lod_settings(level)


## Clear forced LOD level
func clear_forced_level() -> void:
	_forced_level = -1
	_apply_lod_settings(_current_level)


## Set character importance (reduces effective distance)
func set_importance(boost: float) -> void:
	importance_boost = boost


# =============================================================================
# INTERNAL
# =============================================================================

## Find the active camera
func _find_camera() -> void:
	var viewport := get_viewport()
	if viewport:
		camera = viewport.get_camera_3d()


## Update LOD level based on distance and visibility
func _update_lod_level() -> void:
	if _forced_level >= 0:
		return  # Level is forced

	# Ensure we have a camera
	if not camera:
		_find_camera()
		if not camera:
			return

	# Calculate distance to camera
	var char_pos := Vector3.ZERO
	if character_body:
		char_pos = character_body.global_position
	else:
		var anim_sys: _CharacterAnimationSystemScript = animation_system as _CharacterAnimationSystemScript
		if anim_sys and anim_sys.skeleton:
			char_pos = anim_sys.skeleton.global_position

	_distance_to_camera = char_pos.distance_to(camera.global_position)

	# Apply importance boost (makes character seem closer)
	var effective_distance := _distance_to_camera - importance_boost

	# Check frustum visibility
	if use_frustum_culling:
		_is_visible = _check_frustum_visibility(char_pos)
		if not _is_visible:
			_set_lod_level(LODLevel.CULLED)
			return

	# Determine level based on distance
	var new_level: LODLevel
	if effective_distance < full_distance:
		new_level = LODLevel.FULL
	elif effective_distance < high_distance:
		new_level = LODLevel.HIGH
	elif effective_distance < medium_distance:
		new_level = LODLevel.MEDIUM
	elif effective_distance < low_distance:
		new_level = LODLevel.LOW
	else:
		new_level = LODLevel.CULLED

	# Apply if changed
	if new_level != _current_level:
		_set_lod_level(new_level)


## Set LOD level and apply settings
func _set_lod_level(level: LODLevel) -> void:
	_current_level = level
	_apply_lod_settings(level)


## Apply LOD settings to animation system
func _apply_lod_settings(level: int) -> void:
	var anim_sys: _CharacterAnimationSystemScript = animation_system as _CharacterAnimationSystemScript
	if not anim_sys:
		return

	match level:
		LODLevel.FULL:
			_update_interval = maxi(1, 60 / full_fps)
			anim_sys.enable_ik = true
			anim_sys.enable_procedural = true
			_set_animation_active(true)

		LODLevel.HIGH:
			_update_interval = maxi(1, 60 / high_fps)
			anim_sys.enable_ik = true
			anim_sys.enable_procedural = false
			_set_animation_active(true)

		LODLevel.MEDIUM:
			_update_interval = maxi(1, 60 / medium_fps)
			anim_sys.enable_ik = false
			anim_sys.enable_procedural = false
			_set_animation_active(true)

		LODLevel.LOW:
			_update_interval = maxi(1, 60 / low_fps)
			anim_sys.enable_ik = false
			anim_sys.enable_procedural = false
			_set_animation_active(true)

		LODLevel.CULLED:
			_update_interval = 999  # Rarely update
			anim_sys.enable_ik = false
			anim_sys.enable_procedural = false
			_set_animation_active(false)


## Set animation tree active state
func _set_animation_active(active: bool) -> void:
	var anim_sys: _CharacterAnimationSystemScript = animation_system as _CharacterAnimationSystemScript
	if anim_sys and anim_sys.animation_manager:
		var anim_mgr: Node = anim_sys.animation_manager
		if anim_mgr.get("animation_tree"):
			var tree: AnimationTree = anim_mgr.get("animation_tree") as AnimationTree
			if tree:
				tree.active = active


## Check if character is in camera frustum
func _check_frustum_visibility(position: Vector3) -> bool:
	if not camera:
		return true

	# Simple frustum check using camera projection
	var screen_pos := camera.unproject_position(position)
	var viewport_size := camera.get_viewport().get_visible_rect().size

	# Add margin for character size
	var margin := 100.0

	if screen_pos.x < -margin or screen_pos.x > viewport_size.x + margin:
		return false
	if screen_pos.y < -margin or screen_pos.y > viewport_size.y + margin:
		return false

	# Check if behind camera
	var to_char := position - camera.global_position
	var forward := -camera.global_transform.basis.z
	if to_char.dot(forward) < 0:
		return false

	return true
