## CharacterAnimationSystem - Base class for character animation
##
## Provides a unified interface for character animation with:
## - Animation state management via AnimationManager
## - IK control (foot, look-at, hand) via IKController
## - Procedural modifiers (lean, breathing, hit reactions)
## - LOD-based performance optimization
##
## Subclass this for specific character types (humanoid, creature, etc.)
@tool
class_name CharacterAnimationSystem
extends Node

# Preload controller classes to avoid dependency issues
const _AnimationManager := preload("res://src/core/animation/animation_manager.gd")
const _IKController := preload("res://src/core/animation/ik_controller.gd")
const _ProceduralModifierController := preload("res://src/core/animation/procedural_modifier_controller.gd")
const _AnimationLODController := preload("res://src/core/animation/animation_lod_controller.gd")

# Signals
signal animation_state_changed(old_state: StringName, new_state: StringName)
signal animation_finished(animation_name: StringName)
signal ik_target_reached(ik_type: StringName)

# Child controllers (created in setup)
# Note: Using Node type to avoid cyclic dependency issues with preloaded scripts
var animation_manager: Node = null  # AnimationManager
var ik_controller: Node = null  # IKController
var procedural_modifiers: Node = null  # ProceduralModifierController
var lod_controller: Node = null  # AnimationLODController

# References
var skeleton: Skeleton3D = null
var character_body: CharacterBody3D = null
var character_root: Node3D = null

# Configuration
@export_group("System")
@export var auto_setup: bool = true
@export var debug_mode: bool = false

@export_group("Features")
@export var enable_ik: bool = true
@export var enable_procedural: bool = true
@export var enable_lod: bool = true

# State
var _is_setup: bool = false


func _ready() -> void:
	if auto_setup:
		# Defer setup to allow scene tree to be ready
		call_deferred("_auto_setup")


func _auto_setup() -> void:
	# Try to find skeleton and character body in parent hierarchy
	var parent := get_parent()
	if parent is CharacterBody3D:
		character_body = parent as CharacterBody3D
		# Look for skeleton in siblings or children
		skeleton = _find_skeleton(parent)
		if skeleton:
			setup(skeleton, character_body)


## Main setup - call this to initialize the animation system
func setup(p_skeleton: Skeleton3D, p_character_body: CharacterBody3D = null,
		p_character_root: Node3D = null) -> void:
	if _is_setup:
		push_warning("CharacterAnimationSystem: Already setup, call reset() first")
		return

	skeleton = p_skeleton
	character_body = p_character_body
	character_root = p_character_root if p_character_root else skeleton.get_parent()

	if not skeleton:
		push_error("CharacterAnimationSystem: Skeleton is required")
		return

	# Create child controllers
	_create_controllers()

	# Setup each controller
	_setup_controllers()

	_is_setup = true

	if debug_mode:
		print("CharacterAnimationSystem: Setup complete")
		_print_debug_info()


## Reset the animation system (allows re-setup)
func reset() -> void:
	_cleanup_controllers()
	_is_setup = false
	skeleton = null
	character_body = null
	character_root = null


## Process - called every frame
func _process(delta: float) -> void:
	if not _is_setup:
		return

	# Update procedural modifiers
	if enable_procedural and procedural_modifiers:
		var proc: _ProceduralModifierController = procedural_modifiers as _ProceduralModifierController
		if proc:
			proc.update(delta)


## Physics process - called every physics frame
func _physics_process(delta: float) -> void:
	if not _is_setup:
		return

	# Update IK
	if enable_ik and ik_controller:
		var ik: _IKController = ik_controller as _IKController
		if ik:
			ik.update(delta)

	# Update LOD
	if enable_lod and lod_controller:
		var lod: _AnimationLODController = lod_controller as _AnimationLODController
		if lod:
			lod.update(delta)


# =============================================================================
# ANIMATION STATE API
# =============================================================================

## Transition to a new animation state
func set_state(state_name: StringName) -> void:
	var anim: _AnimationManager = animation_manager as _AnimationManager
	if anim:
		anim.transition_to(state_name)


## Get current animation state
func get_state() -> StringName:
	var anim: _AnimationManager = animation_manager as _AnimationManager
	if anim:
		return anim.get_current_state()
	return &""


## Play a one-shot animation on top of current state
func play_oneshot(animation: StringName, layer: StringName = &"action") -> void:
	var anim: _AnimationManager = animation_manager as _AnimationManager
	if anim:
		anim.play_oneshot(animation, layer)


## Set a blend parameter (for blend spaces)
func set_blend_parameter(param_name: StringName, value: Variant) -> void:
	var anim: _AnimationManager = animation_manager as _AnimationManager
	if anim:
		anim.set_blend_parameter(param_name, value)


## Get a blend parameter value
func get_blend_parameter(param_name: StringName) -> Variant:
	var anim: _AnimationManager = animation_manager as _AnimationManager
	if anim:
		return anim.get_blend_parameter(param_name)
	return null


## Update animation based on movement (convenience method)
func update_from_movement(velocity: Vector3, is_grounded: bool = true) -> void:
	var anim: _AnimationManager = animation_manager as _AnimationManager
	if anim:
		anim.update_from_velocity(velocity, is_grounded)


# =============================================================================
# IK API
# =============================================================================

## Set look-at target
func set_look_target(target: Node3D) -> void:
	var ik: _IKController = ik_controller as _IKController
	if ik:
		ik.set_look_target(target)


## Set look-at position (world space)
func set_look_position(pos: Vector3) -> void:
	var ik: _IKController = ik_controller as _IKController
	if ik:
		ik.set_look_position(pos)


## Clear look-at target
func clear_look_target() -> void:
	var ik: _IKController = ik_controller as _IKController
	if ik:
		ik.clear_look_target()


## Set hand IK target
func set_hand_target(hand: StringName, target: Node3D, weight: float = 1.0) -> void:
	var ik: _IKController = ik_controller as _IKController
	if ik:
		ik.set_hand_target(hand, target, weight)


## Clear hand IK target
func clear_hand_target(hand: StringName) -> void:
	var ik: _IKController = ik_controller as _IKController
	if ik:
		ik.clear_hand_target(hand)


## Enable/disable foot IK
func set_foot_ik_enabled(enabled: bool) -> void:
	var ik: _IKController = ik_controller as _IKController
	if ik:
		ik.set_foot_ik_enabled(enabled)


## Enable/disable all IK
func set_ik_enabled(enabled: bool) -> void:
	enable_ik = enabled
	var ik: _IKController = ik_controller as _IKController
	if ik:
		ik.set_all_enabled(enabled)


# =============================================================================
# PROCEDURAL ANIMATION API
# =============================================================================

## Apply hit reaction impulse
func apply_hit_reaction(direction: Vector3, strength: float = 1.0) -> void:
	var proc: _ProceduralModifierController = procedural_modifiers as _ProceduralModifierController
	if proc:
		proc.apply_hit(direction, strength)


## Set lean amount manually (usually auto-calculated from velocity)
func set_lean(lean: Vector2) -> void:
	var proc: _ProceduralModifierController = procedural_modifiers as _ProceduralModifierController
	if proc:
		proc.set_lean(lean)


## Enable/disable breathing
func set_breathing_enabled(enabled: bool) -> void:
	var proc: _ProceduralModifierController = procedural_modifiers as _ProceduralModifierController
	if proc:
		proc.set_breathing_enabled(enabled)


# =============================================================================
# LOD API
# =============================================================================

## Get current LOD level
func get_lod_level() -> int:
	var lod: _AnimationLODController = lod_controller as _AnimationLODController
	if lod:
		return lod.get_current_level()
	return 0


## Get LOD level name for debugging
func get_lod_level_name() -> String:
	var lod: _AnimationLODController = lod_controller as _AnimationLODController
	if lod:
		return lod.get_level_name()
	return "NONE"


## Force a specific LOD level (for testing)
func force_lod_level(level: int) -> void:
	var lod: _AnimationLODController = lod_controller as _AnimationLODController
	if lod:
		lod.force_level(level)


## Clear forced LOD level
func clear_forced_lod() -> void:
	var lod: _AnimationLODController = lod_controller as _AnimationLODController
	if lod:
		lod.clear_forced_level()


# =============================================================================
# INTERNAL METHODS
# =============================================================================

## Create child controller nodes
func _create_controllers() -> void:
	# Animation Manager
	animation_manager = _AnimationManager.new()
	animation_manager.name = "AnimationManager"
	add_child(animation_manager)

	# IK Controller
	if enable_ik:
		ik_controller = _IKController.new()
		ik_controller.name = "IKController"
		add_child(ik_controller)

	# Procedural Modifiers
	if enable_procedural:
		procedural_modifiers = _ProceduralModifierController.new()
		procedural_modifiers.name = "ProceduralModifiers"
		add_child(procedural_modifiers)

	# LOD Controller
	if enable_lod:
		lod_controller = _AnimationLODController.new()
		lod_controller.name = "LODController"
		add_child(lod_controller)


## Setup each controller with references
func _setup_controllers() -> void:
	# Setup Animation Manager
	var anim: _AnimationManager = animation_manager as _AnimationManager
	if anim:
		anim.setup(skeleton)
		anim.state_changed.connect(_on_animation_state_changed)
		anim.animation_finished.connect(_on_animation_finished)

	# Setup IK Controller
	var ik: _IKController = ik_controller as _IKController
	if ik:
		ik.setup(skeleton, character_body)
		ik.target_reached.connect(_on_ik_target_reached)

	# Setup Procedural Modifiers
	var proc: _ProceduralModifierController = procedural_modifiers as _ProceduralModifierController
	if proc:
		proc.setup(skeleton, character_body, animation_manager)

	# Setup LOD Controller
	var lod: _AnimationLODController = lod_controller as _AnimationLODController
	if lod:
		lod.setup(self, character_body)


## Cleanup controllers on reset
func _cleanup_controllers() -> void:
	if animation_manager:
		animation_manager.queue_free()
		animation_manager = null

	if ik_controller:
		ik_controller.queue_free()
		ik_controller = null

	if procedural_modifiers:
		procedural_modifiers.queue_free()
		procedural_modifiers = null

	if lod_controller:
		lod_controller.queue_free()
		lod_controller = null


## Find skeleton in node hierarchy
func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D

	for child in node.get_children():
		var result := _find_skeleton(child)
		if result:
			return result

	return null


# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

func _on_animation_state_changed(old_state: StringName, new_state: StringName) -> void:
	animation_state_changed.emit(old_state, new_state)

	if debug_mode:
		print("CharacterAnimationSystem: State %s -> %s" % [old_state, new_state])


func _on_animation_finished(animation_name: StringName) -> void:
	animation_finished.emit(animation_name)


func _on_ik_target_reached(ik_type: StringName) -> void:
	ik_target_reached.emit(ik_type)


# =============================================================================
# DEBUG
# =============================================================================

func _print_debug_info() -> void:
	print("  Skeleton: %s (%d bones)" % [skeleton.name, skeleton.get_bone_count()])
	print("  CharacterBody: %s" % (character_body.name if character_body else "None"))
	print("  IK: %s" % ("Enabled" if enable_ik and ik_controller else "Disabled"))
	print("  Procedural: %s" % ("Enabled" if enable_procedural and procedural_modifiers else "Disabled"))
	print("  LOD: %s" % ("Enabled" if enable_lod and lod_controller else "Disabled"))
