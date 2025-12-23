## CharacterAnimationController - Manages character animation states
##
## Handles animation state transitions and playback for NPCs and creatures
## Integrates with Godot's AnimationTree and AnimationStateMachine
##
## Based on OpenMW's character animation system with text key markers
class_name CharacterAnimationController
extends Node

# Animation states
enum AnimState {
	IDLE,
	WALK,
	RUN,
	JUMP,
	SWIM_IDLE,
	SWIM_FORWARD,
	COMBAT_IDLE,
	ATTACK,
	HIT,
	DEATH,
	SPELL_CAST,
	KNOCKDOWN,
	BLOCK
}

# References
var skeleton: Skeleton3D
var animation_player: AnimationPlayer
var animation_tree: AnimationTree
var state_machine: AnimationNodeStateMachine

# Current state
var current_state: AnimState = AnimState.IDLE
var is_in_combat: bool = false
var is_swimming: bool = false
var movement_speed: float = 0.0  # 0 = idle, 0-2 = walk, >2 = run

# Animation blending
var blend_time: float = 0.2

# Configuration
var debug_animations: bool = false


func _ready() -> void:
	# Find skeleton and animation components
	_find_components()


## Initialize with a character root node
func setup(character_root: Node3D) -> void:
	if not character_root:
		return

	# Find skeleton
	skeleton = _find_skeleton_recursive(character_root)
	if not skeleton:
		push_warning("CharacterAnimationController: No Skeleton3D found")
		return

	# Find or create AnimationPlayer
	animation_player = _find_animation_player(skeleton)
	if not animation_player:
		push_warning("CharacterAnimationController: No AnimationPlayer found")
		return

	# Create AnimationTree if it doesn't exist
	if not animation_tree:
		_create_animation_tree(character_root)

	if debug_animations:
		print("CharacterAnimationController: Setup complete - %d animations found" %
			animation_player.get_animation_list().size())


## Update animation state based on movement
func update_animation(delta: float, velocity: Vector3, is_grounded: bool = true) -> void:
	if not animation_tree or not animation_tree.active:
		return

	# Determine target state based on movement
	var target_state := _calculate_target_state(velocity, is_grounded)

	# Transition to new state if different
	if target_state != current_state:
		_transition_to_state(target_state)

	# Update movement speed for blend trees
	movement_speed = velocity.length()


## Play a specific animation by name
func play_animation(anim_name: String, blend: float = -1.0) -> void:
	if not animation_player:
		return

	if blend < 0:
		blend = blend_time

	if animation_player.has_animation(anim_name):
		animation_player.play(anim_name, blend)
		if debug_animations:
			print("CharacterAnimationController: Playing '%s'" % anim_name)
	else:
		push_warning("CharacterAnimationController: Animation '%s' not found" % anim_name)


## Set combat mode
func set_combat_mode(enabled: bool) -> void:
	if is_in_combat != enabled:
		is_in_combat = enabled
		# Re-evaluate current state
		_transition_to_state(_calculate_target_state(Vector3.ZERO, true))


## Set swimming mode
func set_swimming_mode(enabled: bool) -> void:
	if is_swimming != enabled:
		is_swimming = enabled
		_transition_to_state(_calculate_target_state(Vector3.ZERO, true))


## Play attack animation
func play_attack() -> void:
	_transition_to_state(AnimState.ATTACK)


## Play spell cast animation
func play_spell_cast() -> void:
	_transition_to_state(AnimState.SPELL_CAST)


## Play hit/stagger animation
func play_hit() -> void:
	_transition_to_state(AnimState.HIT)


## Play death animation
func play_death() -> void:
	_transition_to_state(AnimState.DEATH)


## Play block animation
func play_block() -> void:
	_transition_to_state(AnimState.BLOCK)


## Calculate target animation state
func _calculate_target_state(velocity: Vector3, is_grounded: bool) -> AnimState:
	# Priority: Death > Combat actions > Movement

	# Death state is permanent
	if current_state == AnimState.DEATH:
		return AnimState.DEATH

	# Swimming states
	if is_swimming:
		if velocity.length() > 0.1:
			return AnimState.SWIM_FORWARD
		else:
			return AnimState.SWIM_IDLE

	# Jump state
	if not is_grounded and velocity.y > 0:
		return AnimState.JUMP

	# Combat idle
	if is_in_combat and velocity.length() < 0.1:
		return AnimState.COMBAT_IDLE

	# Movement states
	var speed := Vector3(velocity.x, 0, velocity.z).length()

	if speed < 0.1:
		return AnimState.IDLE
	elif speed < 2.0:
		return AnimState.WALK
	else:
		return AnimState.RUN


## Transition to a new animation state
func _transition_to_state(new_state: AnimState) -> void:
	if new_state == current_state:
		return

	var old_state := current_state
	current_state = new_state

	# Use AnimationTree if available, otherwise direct playback
	if animation_tree and animation_tree.active and state_machine:
		var state_name := _get_state_name(new_state)
		if state_machine.has_node(state_name):
			animation_tree.set("parameters/playback", state_name)

			if debug_animations:
				print("CharacterAnimationController: %s -> %s" % [
					_get_state_name(old_state), state_name
				])
	else:
		# Fallback to direct animation playback
		_play_state_animation(new_state)


## Play animation for a state directly
func _play_state_animation(state: AnimState) -> void:
	if not animation_player:
		return

	var anim_name := _find_animation_for_state(state)
	if not anim_name.is_empty():
		play_animation(anim_name)


## Find animation name for a state
## Searches for animations with Morrowind naming convention
func _find_animation_for_state(state: AnimState) -> String:
	if not animation_player:
		return ""

	var animations := animation_player.get_animation_list()
	var search_terms: Array[String] = []

	match state:
		AnimState.IDLE:
			search_terms = ["idle", "Idle"]
		AnimState.WALK:
			search_terms = ["walk", "Walk"]
		AnimState.RUN:
			search_terms = ["run", "Run"]
		AnimState.JUMP:
			search_terms = ["jump", "Jump"]
		AnimState.SWIM_IDLE:
			search_terms = ["swimidle", "SwimIdle"]
		AnimState.SWIM_FORWARD:
			search_terms = ["swimforward", "SwimForward", "swim"]
		AnimState.COMBAT_IDLE:
			search_terms = ["idle", "Idle"]  # Use regular idle in combat stance
		AnimState.ATTACK:
			search_terms = ["attack", "Attack"]
		AnimState.HIT:
			search_terms = ["hit", "Hit"]
		AnimState.DEATH:
			search_terms = ["death", "Death"]
		AnimState.SPELL_CAST:
			search_terms = ["cast", "Cast", "spell"]
		AnimState.KNOCKDOWN:
			search_terms = ["knockdown", "Knockdown"]
		AnimState.BLOCK:
			search_terms = ["block", "Block"]

	# Search for matching animation
	for term in search_terms:
		for anim in animations:
			if term in anim:
				return anim

	# Fallback to first idle animation
	for anim in animations:
		if "idle" in anim.to_lower():
			return anim

	# Ultimate fallback - first animation
	if animations.size() > 0:
		return animations[0]

	return ""


## Get state name for AnimationTree
func _get_state_name(state: AnimState) -> String:
	match state:
		AnimState.IDLE: return "Idle"
		AnimState.WALK: return "Walk"
		AnimState.RUN: return "Run"
		AnimState.JUMP: return "Jump"
		AnimState.SWIM_IDLE: return "SwimIdle"
		AnimState.SWIM_FORWARD: return "SwimForward"
		AnimState.COMBAT_IDLE: return "CombatIdle"
		AnimState.ATTACK: return "Attack"
		AnimState.HIT: return "Hit"
		AnimState.DEATH: return "Death"
		AnimState.SPELL_CAST: return "SpellCast"
		AnimState.KNOCKDOWN: return "Knockdown"
		AnimState.BLOCK: return "Block"
		_: return "Idle"


## Find components in the scene tree
func _find_components() -> void:
	var parent := get_parent()
	if not parent:
		return

	skeleton = _find_skeleton_recursive(parent)

	if skeleton:
		animation_player = _find_animation_player(skeleton)


## Find Skeleton3D recursively
func _find_skeleton_recursive(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D

	for child in node.get_children():
		var result := _find_skeleton_recursive(child)
		if result:
			return result

	return null


## Find AnimationPlayer
func _find_animation_player(node: Node) -> AnimationPlayer:
	# Check siblings of skeleton
	var parent := node.get_parent()
	if parent:
		for child in parent.get_children():
			if child is AnimationPlayer:
				return child as AnimationPlayer

	# Check children of skeleton's parent
	if parent:
		for child in parent.get_children():
			if child is AnimationPlayer:
				return child as AnimationPlayer

	return null


## Create AnimationTree with state machine
func _create_animation_tree(character_root: Node3D) -> void:
	if not animation_player:
		return

	# Create AnimationTree
	animation_tree = AnimationTree.new()
	animation_tree.name = "AnimationTree"

	# Create state machine
	state_machine = AnimationNodeStateMachine.new()

	# Add states for each animation
	_add_animation_states()

	# Set up transitions
	_add_state_transitions()

	# Assign state machine to tree
	animation_tree.tree_root = state_machine

	# IMPORTANT: Add to scene tree FIRST, before calling get_path_to()
	# In Godot 4.5, get_path_to() requires both nodes to share a common ancestor
	character_root.add_child(animation_tree)

	# Now that both nodes are in the tree, we can compute the path
	# Use deferred call to ensure tree structure is fully resolved
	animation_tree.anim_player = animation_tree.get_path_to(animation_player)

	# Activate tree
	animation_tree.active = true

	if debug_animations:
		print("CharacterAnimationController: AnimationTree created with %d states" %
			state_machine.get_node_count())


## Add animation states to state machine
func _add_animation_states() -> void:
	if not state_machine:
		return

	var states: Array[AnimState] = [
		AnimState.IDLE,
		AnimState.WALK,
		AnimState.RUN,
		AnimState.JUMP,
		AnimState.SWIM_IDLE,
		AnimState.SWIM_FORWARD,
		AnimState.COMBAT_IDLE,
		AnimState.ATTACK,
		AnimState.HIT,
		AnimState.DEATH,
		AnimState.SPELL_CAST,
		AnimState.BLOCK
	]

	for state in states:
		var anim_name := _find_animation_for_state(state)
		if not anim_name.is_empty():
			var anim_node := AnimationNodeAnimation.new()
			anim_node.animation = anim_name
			state_machine.add_node(_get_state_name(state), anim_node)


## Add transitions between states
func _add_state_transitions() -> void:
	if not state_machine:
		return

	# Define transitions (from -> to)
	var transitions := [
		# Idle transitions
		["Idle", "Walk"],
		["Idle", "Run"],
		["Idle", "Jump"],
		["Idle", "CombatIdle"],
		["Idle", "SwimIdle"],

		# Walk transitions
		["Walk", "Idle"],
		["Walk", "Run"],
		["Walk", "Jump"],

		# Run transitions
		["Run", "Idle"],
		["Run", "Walk"],
		["Run", "Jump"],

		# Jump transitions
		["Jump", "Idle"],

		# Combat idle
		["CombatIdle", "Idle"],
		["CombatIdle", "Attack"],
		["CombatIdle", "Block"],
		["CombatIdle", "SpellCast"],

		# Combat actions
		["Attack", "CombatIdle"],
		["Block", "CombatIdle"],
		["SpellCast", "CombatIdle"],

		# Hit reactions
		["Hit", "Idle"],
		["Hit", "CombatIdle"],

		# Swimming
		["SwimIdle", "SwimForward"],
		["SwimIdle", "Idle"],
		["SwimForward", "SwimIdle"],
		["SwimForward", "Idle"],

		# Death (one-way)
		["Death", "Idle"],  # For resurrection
	]

	for trans in transitions:
		var from: String = trans[0]
		var to: String = trans[1]

		if state_machine.has_node(from) and state_machine.has_node(to):
			var transition := AnimationNodeStateMachineTransition.new()
			state_machine.add_transition(from, to, transition)

	# Set start node - In Godot 4.x, we create a transition from the built-in "Start" node
	# instead of using the deprecated set_start_node() method
	if state_machine.has_node("Idle"):
		var start_transition := AnimationNodeStateMachineTransition.new()
		start_transition.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
		state_machine.add_transition("Start", "Idle", start_transition)
