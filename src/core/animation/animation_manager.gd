## AnimationManager - Manages animation state machine and blending
##
## Handles:
## - AnimationTree setup and control
## - State machine transitions
## - Blend parameters (direction, speed)
## - Animation layers (locomotion, action, additive)
## - One-shot animations
class_name AnimationManager
extends Node

# Signals
signal state_changed(old_state: StringName, new_state: StringName)
signal animation_finished(animation_name: StringName)

# Animation states enum (can be extended by subclasses)
enum State {
	IDLE,
	WALK,
	RUN,
	SPRINT,
	JUMP,
	FALL,
	LAND,
	SWIM_IDLE,
	SWIM_FORWARD,
	COMBAT_IDLE,
	ATTACK,
	BLOCK,
	HIT,
	DEATH,
	SPELL_CAST,
	CUSTOM  # For custom states added at runtime
}

# Layer names
const LAYER_LOCOMOTION := &"locomotion"
const LAYER_ACTION := &"action"
const LAYER_ADDITIVE := &"additive"

# Configuration
@export_group("Blending")
@export var default_blend_time: float = 0.2
@export var fast_blend_time: float = 0.1
@export var slow_blend_time: float = 0.4

@export_group("Movement Detection")
@export var idle_threshold: float = 0.1
@export var walk_threshold: float = 2.0
@export var run_threshold: float = 5.0

@export_group("Debug")
@export var debug_state_changes: bool = false
@export var debug_blend_values: bool = false

# References
var skeleton: Skeleton3D = null
var animation_player: AnimationPlayer = null
var animation_tree: AnimationTree = null

# State machine
var _state_machine: AnimationNodeStateMachinePlayback = null
var _current_state: StringName = &"Idle"
var _previous_state: StringName = &""

# Blend parameters
var _blend_parameters: Dictionary = {
	&"movement_direction": Vector2.ZERO,  # X = strafe, Y = forward/back
	&"movement_speed": 0.0,               # 0 = idle, 1 = walk, 2 = run
	&"is_grounded": true,
}

# Animation name mappings (state -> animation name)
var _state_animation_map: Dictionary = {}

# One-shot state
var _oneshot_active: bool = false
var _oneshot_layer: StringName = &""

# Setup state
var _is_setup: bool = false


func _ready() -> void:
	set_process(false)  # Enable after setup


## Setup the animation manager
func setup(p_skeleton: Skeleton3D) -> void:
	skeleton = p_skeleton
	if not skeleton:
		push_error("AnimationManager: Skeleton is required")
		return

	# Find or create AnimationPlayer
	animation_player = _find_animation_player()
	if not animation_player:
		push_warning("AnimationManager: No AnimationPlayer found")
		return

	# Create AnimationTree
	_create_animation_tree()

	# Build state-to-animation mapping
	_build_animation_map()

	_is_setup = true
	set_process(true)


func _process(_delta: float) -> void:
	if not _is_setup:
		return

	# Update blend parameters in AnimationTree
	_sync_blend_parameters()

	# Check for one-shot completion
	if _oneshot_active:
		_check_oneshot_completion()


## Transition to a new state
func transition_to(state: StringName, force: bool = false) -> void:
	if not _is_setup or not _state_machine:
		return

	if state == _current_state and not force:
		return

	# Check if state exists
	if not _state_machine.get_current_node():
		# State machine not ready yet
		return

	_previous_state = _current_state
	_current_state = state

	# Travel to the new state
	_state_machine.travel(state)

	state_changed.emit(_previous_state, _current_state)

	if debug_state_changes:
		print("AnimationManager: %s -> %s" % [_previous_state, _current_state])


## Get current state name
func get_current_state() -> StringName:
	return _current_state


## Set a blend parameter
func set_blend_parameter(name: StringName, value: Variant) -> void:
	_blend_parameters[name] = value

	if debug_blend_values:
		print("AnimationManager: Blend param '%s' = %s" % [name, value])


## Get a blend parameter
func get_blend_parameter(name: StringName) -> Variant:
	return _blend_parameters.get(name)


## Play a one-shot animation
func play_oneshot(animation: StringName, layer: StringName = LAYER_ACTION) -> void:
	if not _is_setup or not animation_tree:
		return

	# Find the oneshot node path for this layer
	var oneshot_path := "parameters/%s_oneshot/request" % layer

	# Check if we have an animation with this name
	if not animation_player.has_animation(animation):
		push_warning("AnimationManager: Animation '%s' not found" % animation)
		return

	# Set the animation
	var anim_path := "parameters/%s_animation/animation" % layer
	animation_tree.set(anim_path, animation)

	# Fire the oneshot
	animation_tree.set(oneshot_path, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)

	_oneshot_active = true
	_oneshot_layer = layer


## Update animation state based on velocity
func update_from_velocity(velocity: Vector3, is_grounded: bool = true) -> void:
	# Calculate horizontal speed
	var horizontal_velocity := Vector3(velocity.x, 0, velocity.z)
	var speed := horizontal_velocity.length()

	# Update blend parameters
	set_blend_parameter(&"movement_speed", speed)
	set_blend_parameter(&"is_grounded", is_grounded)

	# Determine target state based on speed and grounded state
	var target_state: StringName

	if not is_grounded:
		if velocity.y > 0:
			target_state = &"Jump"
		else:
			target_state = &"Fall"
	elif speed < idle_threshold:
		target_state = &"Idle"
	elif speed < walk_threshold:
		target_state = &"Walk"
	elif speed < run_threshold:
		target_state = &"Run"
	else:
		target_state = &"Sprint"

	# Transition if needed
	transition_to(target_state)


## Add a custom animation state
func add_custom_state(state_name: StringName, animation_name: StringName) -> void:
	_state_animation_map[state_name] = animation_name

	# Add to state machine if it exists
	if _state_machine and animation_player.has_animation(animation_name):
		var anim_node := AnimationNodeAnimation.new()
		anim_node.animation = animation_name
		# Note: In Godot 4.x, we can't easily add nodes to an active state machine
		# This would need to be done before activation


## Get animation name for a state
func get_animation_for_state(state: StringName) -> StringName:
	return _state_animation_map.get(state, &"")


## Check if manager is ready
func is_ready() -> bool:
	return _is_setup


# =============================================================================
# INTERNAL METHODS
# =============================================================================

## Find AnimationPlayer in skeleton hierarchy
func _find_animation_player() -> AnimationPlayer:
	if not skeleton:
		return null

	# Check parent's children (siblings)
	var parent := skeleton.get_parent()
	if parent:
		for child in parent.get_children():
			if child is AnimationPlayer:
				return child as AnimationPlayer

	# Check skeleton's children
	for child in skeleton.get_children():
		if child is AnimationPlayer:
			return child as AnimationPlayer

	return null


## Create AnimationTree with state machine
func _create_animation_tree() -> void:
	if not animation_player:
		return

	# Create AnimationTree
	animation_tree = AnimationTree.new()
	animation_tree.name = "AnimationTree"

	# Create the tree structure
	var root := _create_tree_structure()
	animation_tree.tree_root = root

	# Add to scene tree first (required for get_path_to in Godot 4.5)
	skeleton.get_parent().add_child(animation_tree)

	# Now set the animation player path
	animation_tree.anim_player = animation_tree.get_path_to(animation_player)

	# Activate
	animation_tree.active = true

	# Get state machine playback
	_state_machine = animation_tree.get("parameters/locomotion/playback")


## Create the animation tree structure
func _create_tree_structure() -> AnimationNodeBlendTree:
	var root := AnimationNodeBlendTree.new()

	# Create locomotion state machine
	var locomotion_sm := _create_locomotion_state_machine()
	root.add_node(&"locomotion", locomotion_sm, Vector2(0, 0))

	# Create action oneshot layer
	var action_oneshot := AnimationNodeOneShot.new()
	root.add_node(&"action_oneshot", action_oneshot, Vector2(300, 0))

	# Create action animation node
	var action_anim := AnimationNodeAnimation.new()
	root.add_node(&"action_animation", action_anim, Vector2(300, 100))

	# Create additive blend
	var additive := AnimationNodeAdd2.new()
	root.add_node(&"additive", additive, Vector2(600, 0))

	# Create additive animation node
	var additive_anim := AnimationNodeAnimation.new()
	root.add_node(&"additive_animation", additive_anim, Vector2(600, 100))

	# Connect nodes
	root.connect_node(&"action_oneshot", 0, &"locomotion")
	root.connect_node(&"action_oneshot", 1, &"action_animation")
	root.connect_node(&"additive", 0, &"action_oneshot")
	root.connect_node(&"additive", 1, &"additive_animation")

	# Set output
	root.connect_node(&"output", 0, &"additive")

	return root


## Create locomotion state machine
func _create_locomotion_state_machine() -> AnimationNodeStateMachine:
	var sm := AnimationNodeStateMachine.new()

	# Add states
	var states := [&"Idle", &"Walk", &"Run", &"Sprint", &"Jump", &"Fall", &"Land"]

	for state_name: StringName in states:
		var anim_name := _find_animation_for_state_name(state_name)
		if not anim_name.is_empty():
			var anim_node := AnimationNodeAnimation.new()
			anim_node.animation = anim_name
			sm.add_node(state_name, anim_node)

	# Add transitions
	_add_locomotion_transitions(sm)

	# Set start state
	if sm.has_node(&"Idle"):
		var start_trans := AnimationNodeStateMachineTransition.new()
		start_trans.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
		sm.add_transition(&"Start", &"Idle", start_trans)

	return sm


## Add transitions to locomotion state machine
func _add_locomotion_transitions(sm: AnimationNodeStateMachine) -> void:
	var transitions := [
		# Ground movement
		[&"Idle", &"Walk"],
		[&"Walk", &"Idle"],
		[&"Walk", &"Run"],
		[&"Run", &"Walk"],
		[&"Run", &"Sprint"],
		[&"Sprint", &"Run"],

		# Jumping
		[&"Idle", &"Jump"],
		[&"Walk", &"Jump"],
		[&"Run", &"Jump"],
		[&"Jump", &"Fall"],
		[&"Fall", &"Land"],
		[&"Land", &"Idle"],
	]

	for trans: Array in transitions:
		var from: StringName = trans[0]
		var to: StringName = trans[1]

		if sm.has_node(from) and sm.has_node(to):
			var transition := AnimationNodeStateMachineTransition.new()
			transition.xfade_time = default_blend_time
			sm.add_transition(from, to, transition)


## Find animation name for a state (searches animation library)
func _find_animation_for_state_name(state_name: StringName) -> StringName:
	if not animation_player:
		return &""

	var search_terms: Array[String] = []

	match state_name:
		&"Idle":
			search_terms = ["idle", "Idle"]
		&"Walk":
			search_terms = ["walk", "Walk"]
		&"Run":
			search_terms = ["run", "Run"]
		&"Sprint":
			search_terms = ["run", "Run", "sprint", "Sprint"]  # Fall back to run
		&"Jump":
			search_terms = ["jump", "Jump"]
		&"Fall":
			search_terms = ["fall", "Fall", "jumploop", "JumpLoop"]
		&"Land":
			search_terms = ["land", "Land", "jumpland", "JumpLand"]
		_:
			search_terms = [state_name.to_lower(), state_name]

	# Search animations
	var animations := animation_player.get_animation_list()
	for term in search_terms:
		for anim in animations:
			if term in anim or anim.to_lower().contains(term.to_lower()):
				return StringName(anim)

	return &""


## Build animation state map from available animations
func _build_animation_map() -> void:
	if not animation_player:
		return

	var states := [
		&"Idle", &"Walk", &"Run", &"Sprint",
		&"Jump", &"Fall", &"Land",
		&"SwimIdle", &"SwimForward",
		&"CombatIdle", &"Attack", &"Block", &"Hit", &"Death", &"SpellCast"
	]

	for state: StringName in states:
		var anim := _find_animation_for_state_name(state)
		if not anim.is_empty():
			_state_animation_map[state] = anim


## Sync blend parameters to AnimationTree
func _sync_blend_parameters() -> void:
	if not animation_tree:
		return

	# Sync movement speed to blend space (if using BlendSpace)
	var speed: float = _blend_parameters.get(&"movement_speed", 0.0)
	var direction: Vector2 = _blend_parameters.get(&"movement_direction", Vector2.ZERO)

	# These paths depend on tree structure - adjust as needed
	# animation_tree.set("parameters/locomotion_blend/blend_position", direction)


## Check if one-shot animation is complete
func _check_oneshot_completion() -> void:
	if not animation_tree or not _oneshot_active:
		return

	var oneshot_path := "parameters/%s_oneshot/active" % _oneshot_layer
	var is_active: bool = animation_tree.get(oneshot_path)

	if not is_active:
		_oneshot_active = false

		# Get animation name that finished
		var anim_path := "parameters/%s_animation/animation" % _oneshot_layer
		var anim_name: StringName = animation_tree.get(anim_path)
		animation_finished.emit(anim_name)
