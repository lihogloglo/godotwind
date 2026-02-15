## AnimationManager - Manages animation state machine and blending
##
## Handles:
## - AnimationTree setup and control
## - State machine transitions
## - Blend parameters (direction, speed)
## - Animation layers (locomotion, action, additive)
## - One-shot animations
## - Text key event handling for footsteps, hit timing, etc.
class_name AnimationManager
extends Node

# Preload TextKeyHandler, BlendMask, and Priority
const _TextKeyHandler := preload("res://src/core/animation/text_key_handler.gd")
const _BlendMask := preload("res://src/core/animation/animation_blend_mask.gd")
const _Priority := preload("res://src/core/animation/animation_priority.gd")

# Signals
signal state_changed(old_state: StringName, new_state: StringName)
signal animation_finished(animation_name: StringName)

# Text key signals (forwarded from TextKeyHandler)
signal sound_triggered(sound_id: String, position: Vector3)
signal hit_triggered(position: Vector3)
signal footstep_triggered(foot: String, position: Vector3)

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
var character_node: Node3D = null  # For position in sound emission

# Retargeting: when set, AnimationPlayer/AnimationTree target this skeleton
# instead of the main skeleton. Used with RetargetModifier3D hierarchy where
# animations play on a source skeleton and get retargeted to the target.
var retarget_source: Skeleton3D = null

# Text key handler
var _text_key_handler: RefCounted = null  # TextKeyHandler

# Blend masks for layered animation
var _blend_masks: RefCounted = null  # AnimationBlendMask
var _upper_body_filter: PackedInt32Array = PackedInt32Array()

# Animation priority system
var _priority_system: RefCounted = null  # AnimationPriority

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
func setup(p_skeleton: Skeleton3D, p_character_node: Node3D = null) -> void:
	skeleton = p_skeleton
	character_node = p_character_node
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

	# Setup text key handler
	_setup_text_key_handler()

	# Setup blend masks
	_setup_blend_masks()

	# Setup priority system
	_priority_system = _Priority.new()

	_is_setup = true
	set_process(true)


## Setup blend masks for layered animation
func _setup_blend_masks() -> void:
	_blend_masks = _BlendMask.new()
	var masks: _BlendMask = _blend_masks as _BlendMask
	masks.build_masks(skeleton)

	# Create upper body filter for action layer
	_upper_body_filter = masks.create_filter_array(_BlendMask.MaskType.TORSO)

	if debug_state_changes:
		Log.debug("animation", masks.get_debug_info())


## Setup text key handler for animation events
func _setup_text_key_handler() -> void:
	_text_key_handler = _TextKeyHandler.new()

	var handler: _TextKeyHandler = _text_key_handler as _TextKeyHandler
	handler.setup(animation_player, character_node)

	# Connect signals
	handler.sound_triggered.connect(_on_sound_triggered)
	handler.hit_triggered.connect(_on_hit_triggered)
	handler.soundgen_triggered.connect(_on_soundgen_triggered)


## Register text keys for an animation (call from animation loading)
func register_animation_text_keys(animation_name: String, text_keys: Array) -> void:
	if _text_key_handler:
		var handler: _TextKeyHandler = _text_key_handler as _TextKeyHandler
		handler.register_text_keys(animation_name, text_keys)


## Get hit timing for an attack animation
func get_hit_time(animation_name: String) -> float:
	if _text_key_handler:
		var handler: _TextKeyHandler = _text_key_handler as _TextKeyHandler
		return handler.get_hit_time(animation_name)
	return -1.0


## Get loop points for an animation
func get_loop_points(animation_name: String) -> Variant:
	if _text_key_handler:
		var handler: _TextKeyHandler = _text_key_handler as _TextKeyHandler
		return handler.get_loop_points(animation_name)
	return null


# Text key signal handlers
func _on_sound_triggered(sound_id: String, position: Vector3) -> void:
	sound_triggered.emit(sound_id, position)


func _on_hit_triggered(position: Vector3) -> void:
	hit_triggered.emit(position)


func _on_soundgen_triggered(sound_type: String, position: Vector3) -> void:
	# Map soundgen types to footstep signals
	var lower := sound_type.to_lower()
	if "left" in lower:
		footstep_triggered.emit("left", position)
	elif "right" in lower:
		footstep_triggered.emit("right", position)


func _process(_delta: float) -> void:
	if not _is_setup:
		return

	# Update blend parameters in AnimationTree
	_sync_blend_parameters()

	# Process text key events based on current animation time
	_process_text_keys()

	# Check for one-shot completion
	if _oneshot_active:
		_check_oneshot_completion()


## Process text keys for current animation frame
func _process_text_keys() -> void:
	if not _text_key_handler or not _state_machine:
		return

	var current_node := _state_machine.get_current_node()
	if current_node.is_empty():
		return

	# Map state machine node name to actual animation name
	var anim_name: StringName = _state_animation_map.get(current_node, current_node)
	var current_time := _state_machine.get_current_play_position()
	var handler: _TextKeyHandler = _text_key_handler as _TextKeyHandler
	handler.process_animation_time(anim_name, current_time)


## Transition to a new state
func transition_to(state: StringName, force: bool = false) -> void:
	if not _is_setup or not _state_machine:
		return

	if state == _current_state and not force:
		return

	# Check priority system - can this transition happen?
	if _priority_system and not force:
		var prio: _Priority = _priority_system as _Priority
		if not prio.request_animation(state, force):
			# Blocked by higher priority animation
			return

	# Check if state exists in the state machine
	if not _state_machine.get_current_node():
		# State machine not ready yet
		return

	# Skip if the target state has no animation (wasn't added to the state machine)
	if state not in _state_animation_map:
		return

	_previous_state = _current_state
	_current_state = state

	# Travel to the new state
	_state_machine.travel(state)

	state_changed.emit(_previous_state, _current_state)

	if debug_state_changes:
		Log.debug("animation", "AnimationManager: %s -> %s" % [_previous_state, _current_state])


## Get current state name
func get_current_state() -> StringName:
	return _current_state


## Set a blend parameter
func set_blend_parameter(name: StringName, value: Variant) -> void:
	_blend_parameters[name] = value

	if debug_blend_values:
		Log.debug("animation", "AnimationManager: Blend param '%s' = %s" % [name, value])


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

	# Fall back if target state has no animation mapped
	if target_state not in _state_animation_map:
		# Try nearby states: Idle→Walk, Walk→Idle, Run→Walk, Sprint→Run
		var fallbacks: Dictionary = {
			&"Idle": [&"Walk"],
			&"Walk": [&"Idle"],
			&"Run": [&"Walk", &"Sprint"],
			&"Sprint": [&"Run", &"Walk"],
			&"Jump": [&"Fall"],
			&"Fall": [&"Jump"],
		}
		var found := false
		for fb: StringName in fallbacks.get(target_state, []):
			if fb in _state_animation_map:
				target_state = fb
				found = true
				break
		if not found:
			return

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

## Find AnimationPlayer in skeleton hierarchy.
## When retarget_source is set, searches there instead (animations play on source skeleton).
func _find_animation_player() -> AnimationPlayer:
	var search_skel: Skeleton3D = retarget_source if retarget_source else skeleton
	if not search_skel:
		return null

	# Check parent's children (siblings)
	var parent := search_skel.get_parent()
	if parent:
		for child in parent.get_children():
			if child is AnimationPlayer:
				return child as AnimationPlayer

	# Check skeleton's children
	for child in search_skel.get_children():
		if child is AnimationPlayer:
			return child as AnimationPlayer

	return null


## Create AnimationTree with state machine.
## When retarget_source is set, AnimationTree is added near the source skeleton.
func _create_animation_tree() -> void:
	if not animation_player:
		return

	# Remove any pre-existing AnimationTree (e.g., leftover from prebaked scene)
	var anim_skel: Skeleton3D = retarget_source if retarget_source else skeleton
	if anim_skel:
		for child in anim_skel.get_children():
			if child is AnimationTree:
				child.active = false
				anim_skel.remove_child(child)
				child.queue_free()

	# Create AnimationTree
	animation_tree = AnimationTree.new()
	animation_tree.name = "AnimationTree"

	# Create the tree structure
	var root := _create_tree_structure()
	animation_tree.tree_root = root

	# Add to skeleton so default root_node ("..") resolves to Skeleton3D.
	# This is required for bone track paths (".:BoneName") to find the skeleton.
	anim_skel = retarget_source if retarget_source else skeleton
	anim_skel.add_child(animation_tree)

	# Now set the animation player path
	animation_tree.anim_player = animation_tree.get_path_to(animation_player)

	# Activate
	animation_tree.active = true

	# Get state machine playback
	_state_machine = animation_tree.get("parameters/locomotion/playback")

	# Apply blend mask filters to upper body blend node
	_apply_blend_mask_filters()


## Create the animation tree structure.
## Currently: locomotion state machine only (full body).
## Upper body blend + additive layers deferred until combat/spellcasting.
func _create_tree_structure() -> AnimationNodeBlendTree:
	var root := AnimationNodeBlendTree.new()

	# Locomotion state machine (base layer - full body)
	var locomotion_sm := _create_locomotion_state_machine()
	root.add_node(&"locomotion", locomotion_sm, Vector2(0, 0))

	# Connect locomotion directly to output
	root.connect_node(&"output", 0, &"locomotion")

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

	# Set start state: prefer Idle, fall back to Walk, then first available
	var start_state: StringName = &""
	if sm.has_node(&"Idle"):
		start_state = &"Idle"
	elif sm.has_node(&"Walk"):
		start_state = &"Walk"
	else:
		# Use first available state
		for state_name: StringName in states:
			if sm.has_node(state_name):
				start_state = state_name
				break

	if not start_state.is_empty():
		var start_trans := AnimationNodeStateMachineTransition.new()
		start_trans.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
		sm.add_transition(&"Start", start_state, start_trans)

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

	# Search animations: exact match first, then substring fallback
	var animations := animation_player.get_animation_list()

	# Pass 1: exact match (case-insensitive)
	for term in search_terms:
		var term_lower := term.to_lower()
		for anim in animations:
			if anim.to_lower() == term_lower:
				return StringName(anim)

	# Pass 2: substring match (case-insensitive)
	for term in search_terms:
		var term_lower := term.to_lower()
		for anim in animations:
			if term_lower in anim.to_lower():
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


## Apply blend mask filters to AnimationTree nodes
func _apply_blend_mask_filters() -> void:
	if not animation_tree or not _blend_masks or not skeleton:
		return

	var masks: _BlendMask = _blend_masks as _BlendMask
	if not masks.is_valid():
		return

	# Get the tree root
	var root: AnimationNodeBlendTree = animation_tree.tree_root as AnimationNodeBlendTree
	if not root:
		return

	# Apply upper body filter to the blend node
	# In Godot 4.x, we need to set filters via the tree parameters
	# The filter path is: parameters/<node_name>/filters/<bone_path>

	# Get upper body bones (torso + arms)
	var upper_bones: Array[int] = masks.get_mask_bones(_BlendMask.MaskType.TORSO)
	var left_arm: Array[int] = masks.get_mask_bones(_BlendMask.MaskType.LEFT_ARM)
	var right_arm: Array[int] = masks.get_mask_bones(_BlendMask.MaskType.RIGHT_ARM)

	# Combine for upper body
	for bone_idx: int in left_arm:
		if bone_idx not in upper_bones:
			upper_bones.append(bone_idx)
	for bone_idx: int in right_arm:
		if bone_idx not in upper_bones:
			upper_bones.append(bone_idx)

	# Set filter for upper_body_blend node
	# In AnimationTree, we need to enable filters per-bone using the skeleton path
	for bone_idx: int in upper_bones:
		var bone_name := skeleton.get_bone_name(bone_idx)
		var filter_path := "parameters/upper_body_blend/filters/%s:%s" % [
			skeleton.get_path(), bone_name
		]
		animation_tree.set(filter_path, true)

	if debug_state_changes:
		Log.debug("animation", "AnimationManager: Applied upper body filter to %d bones" % upper_bones.size())


## Sync blend parameters to AnimationTree
func _sync_blend_parameters() -> void:
	if not animation_tree:
		return

	# Sync movement speed to blend space (if using BlendSpace)
	var speed: float = _blend_parameters.get(&"movement_speed", 0.0)
	var direction: Vector2 = _blend_parameters.get(&"movement_direction", Vector2.ZERO)

	# Sync upper body blend weight for action animations
	# When action is active, blend to 1.0; when not, blend to 0.0
	var upper_blend_weight: float = 0.0
	if _oneshot_active and _oneshot_layer == LAYER_ACTION:
		upper_blend_weight = 1.0
	animation_tree.set("parameters/upper_body_blend/blend_amount", upper_blend_weight)


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
