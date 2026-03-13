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
const _MoveContainer := preload("res://src/core/character/controller/move_container.gd")

# Signals
signal animation_state_changed(old_state: StringName, new_state: StringName)
signal animation_finished(animation_name: StringName)
signal ik_target_reached(ik_type: StringName)
signal sound_triggered(sound_id: String, position: Vector3)
signal hit_triggered(position: Vector3)
signal footstep_triggered(foot: String, position: Vector3)

# Child controllers (created in setup)
# Note: Using Node type to avoid cyclic dependency issues with preloaded scripts
var animation_manager: Node = null  # AnimationManager
var ik_controller: Node = null  # IKController
var procedural_modifiers: Node = null  # ProceduralModifierController
var lod_controller: Node = null  # AnimationLODController
var move_container: Node = null  # MoveContainer

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
@export var enable_moves: bool = true

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
		Log.debug("animation", "CharacterAnimationSystem: Setup complete")
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


## Update animation based on movement (convenience method).
## input_direction, is_sprinting, is_walking forwarded for BlendSpace2D.
func update_from_movement(velocity: Vector3, is_grounded: bool = true,
		input_direction: Vector2 = Vector2.ZERO,
		p_is_sprinting: bool = false, p_is_walking: bool = false) -> void:
	var anim: _AnimationManager = animation_manager as _AnimationManager
	if anim:
		anim.update_from_velocity(velocity, is_grounded, input_direction,
			p_is_sprinting, p_is_walking)


# =============================================================================
# WIRING API
# =============================================================================

## Late-bind the CharacterBody3D (e.g. from PlayerController.attach_character)
func set_character_body(body: CharacterBody3D) -> void:
	character_body = body
	var ik: _IKController = ik_controller as _IKController
	if ik:
		ik.character_body = body


## Set root motion track on the AnimationTree
func set_root_motion_track(bone_path: NodePath) -> void:
	var anim: _AnimationManager = animation_manager as _AnimationManager
	if anim:
		anim.set_root_motion_track(bone_path)


## Get the AnimationTree (for root motion queries from PlayerController)
func get_animation_tree() -> AnimationTree:
	var anim: _AnimationManager = animation_manager as _AnimationManager
	if anim:
		return anim.get_animation_tree()
	return null


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

	# Move Container (state machine for character actions)
	if enable_moves:
		move_container = _MoveContainer.new()
		move_container.name = "MoveContainer"
		add_child(move_container)
		_add_default_moves()


## Setup each controller with references
func _setup_controllers() -> void:
	# Setup Animation Manager
	var anim: _AnimationManager = animation_manager as _AnimationManager
	if anim:
		anim.setup(skeleton, character_body)
		anim.state_changed.connect(_on_animation_state_changed)
		anim.animation_finished.connect(_on_animation_finished)
		anim.sound_triggered.connect(_on_sound_triggered)
		anim.hit_triggered.connect(_on_hit_triggered)
		anim.footstep_triggered.connect(_on_footstep_triggered)

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

	# Setup Move Container
	var mc: _MoveContainer = move_container as _MoveContainer
	if mc:
		mc.player = character_body
		mc.character_root = character_root
		mc.animator = animation_manager
		mc.skeleton = skeleton
		mc.accept_moves()
		mc.state_changed.connect(_on_move_state_changed)


## Cleanup controllers on reset
func _cleanup_controllers() -> void:
	# Clean up AnimationTree FIRST — it lives on the Skeleton3D, not the
	# AnimationManager, so queue_free() on the manager won't remove it.
	# Leaving it causes two AnimationTrees fighting for bone control.
	if animation_manager:
		var anim: _AnimationManager = animation_manager as _AnimationManager
		if anim and anim.animation_tree and is_instance_valid(anim.animation_tree):
			anim.animation_tree.active = false
			var parent := anim.animation_tree.get_parent()
			if parent:
				parent.remove_child(anim.animation_tree)
			anim.animation_tree.queue_free()
			anim.animation_tree = null
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

	if move_container:
		move_container.queue_free()
		move_container = null


## Add default locomotion moves to the MoveContainer.
## Subclasses can override this to add different or additional moves.
func _add_default_moves() -> void:
	if not move_container:
		return
	var IdleMoveClass := preload("res://src/core/character/controller/moves/idle_move.gd")
	var WalkMoveClass := preload("res://src/core/character/controller/moves/walk_move.gd")
	var RunMoveClass := preload("res://src/core/character/controller/moves/run_move.gd")
	var SprintMoveClass := preload("res://src/core/character/controller/moves/sprint_move.gd")
	var JumpMoveClass := preload("res://src/core/character/controller/moves/jump_move.gd")
	var MidairMoveClass := preload("res://src/core/character/controller/moves/midair_move.gd")
	var CrouchMoveClass := preload("res://src/core/character/controller/moves/crouch_move.gd")
	var SwimIdleMoveClass := preload("res://src/core/character/controller/moves/swim_idle_move.gd")
	var SwimMoveClass := preload("res://src/core/character/controller/moves/swim_move.gd")

	var idle := IdleMoveClass.new()
	idle.name = "IdleMove"
	move_container.add_child(idle)

	var walk := WalkMoveClass.new()
	walk.name = "WalkMove"
	move_container.add_child(walk)

	var run := RunMoveClass.new()
	run.name = "RunMove"
	move_container.add_child(run)

	var sprint := SprintMoveClass.new()
	sprint.name = "SprintMove"
	move_container.add_child(sprint)

	var jump := JumpMoveClass.new()
	jump.name = "JumpMove"
	move_container.add_child(jump)

	var midair := MidairMoveClass.new()
	midair.name = "MidairMove"
	move_container.add_child(midair)

	var crouch := CrouchMoveClass.new()
	crouch.name = "CrouchMove"
	move_container.add_child(crouch)

	var swim_idle := SwimIdleMoveClass.new()
	swim_idle.name = "SwimIdleMove"
	move_container.add_child(swim_idle)

	var swim := SwimMoveClass.new()
	swim.name = "SwimMove"
	move_container.add_child(swim)


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
		Log.debug("animation", "CharacterAnimationSystem: State %s -> %s" % [old_state, new_state])


func _on_animation_finished(animation_name: StringName) -> void:
	animation_finished.emit(animation_name)


func _on_ik_target_reached(ik_type: StringName) -> void:
	ik_target_reached.emit(ik_type)


func _on_sound_triggered(sound_id: String, position: Vector3) -> void:
	sound_triggered.emit(sound_id, position)


func _on_hit_triggered(position: Vector3) -> void:
	hit_triggered.emit(position)


func _on_footstep_triggered(foot: String, position: Vector3) -> void:
	footstep_triggered.emit(foot, position)


func _on_move_state_changed(old_move: StringName, new_move: StringName) -> void:
	if debug_mode:
		Log.debug("animation", "CharacterAnimationSystem: Move %s -> %s" % [old_move, new_move])


# =============================================================================
# MOVE CONTAINER API
# =============================================================================

## Process moves for this frame (call from PlayerController with gathered input)
func process_moves(input: Resource, delta: float) -> void:
	var mc: _MoveContainer = move_container as _MoveContainer
	if mc:
		mc.process(input, delta)


## Get the MoveContainer node (for direct access from PlayerController)
func get_move_container() -> Node:
	return move_container


# =============================================================================
# TEXT KEY API
# =============================================================================

## Register text keys for an animation (from NIF/KF loading)
func register_text_keys(animation_name: String, text_keys: Array) -> void:
	var anim: _AnimationManager = animation_manager as _AnimationManager
	if anim:
		anim.register_animation_text_keys(animation_name, text_keys)


# =============================================================================
# DEBUG
# =============================================================================

func _print_debug_info() -> void:
	var info := "  Skeleton: %s (%d bones)" % [skeleton.name, skeleton.get_bone_count()]
	info += "\n  CharacterBody: %s" % (character_body.name if character_body else "None")
	info += "\n  IK: %s" % ("Enabled" if enable_ik and ik_controller else "Disabled")
	info += "\n  Procedural: %s" % ("Enabled" if enable_procedural and procedural_modifiers else "Disabled")
	info += "\n  LOD: %s" % ("Enabled" if enable_lod and lod_controller else "Disabled")
	Log.debug("animation", info)
