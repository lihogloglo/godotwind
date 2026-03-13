## MoveContainer — Holds Move nodes and manages state transitions
##
## Child of CharacterAnimationSystem. Move nodes are added as children
## either manually or by a factory. On setup, accept_moves() wires each
## Move with references to the player, animator, skeleton, etc.
class_name MoveContainer
extends Node

## Emitted on every state transition
signal state_changed(old_move: StringName, new_move: StringName)

# --- Registered moves ---
var moves: Dictionary[StringName, Move] = {}
var current_move: Move = null

# --- References (set by CharacterAnimationSystem during setup) ---
var player: CharacterBody3D = null
var character_root: Node3D = null  # Model root for rotation (may differ from player)
var animator: Node = null  # AnimationManager
var skeleton: Skeleton3D = null
var resources: Node = null  # HumanoidResources (Phase 4)
var combat: Node = null  # HumanoidCombat (Phase 5)
var legs: Node = null  # Legs (Phase 4)

# --- State ---
var _is_setup: bool = false


# =============================================================================
# SETUP
# =============================================================================

## Wire all Move children with shared references and register them by name.
## Call after all references (player, animator, skeleton) are set.
func accept_moves() -> void:
	moves.clear()
	for child in get_children():
		if child is Move:
			var move: Move = child as Move
			if move.move_name.is_empty():
				push_warning("MoveContainer: Move '%s' has no move_name, skipping" % child.name)
				continue
			moves[move.move_name] = move
			move.player = player
			move.character_root = character_root
			move.animator = animator
			move.skeleton = skeleton
			move.resources = resources
			move.combat = combat
			move.container = self
			move.legs = legs
			move.assign_combos()

	if moves.is_empty():
		push_warning("MoveContainer: No moves found as children")
		return

	# Start in idle (or first available move)
	var start_move: StringName = &"idle" if moves.has(&"idle") else moves.keys()[0]
	current_move = moves[start_move]
	current_move._on_enter_state()
	_is_setup = true

	Log.info("controller", "MoveContainer: Accepted %d moves, starting in '%s'" % [
		moves.size(), start_move])


# =============================================================================
# PER-FRAME UPDATE — Called from CharacterAnimationSystem or PlayerController
# =============================================================================

## Process one physics frame: check relevance, maybe switch, then update.
## move_and_slide() is called HERE, once, after the move sets velocity.
func process(input: InputPackage, delta: float) -> void:
	if not _is_setup or current_move == null:
		return

	# Let the current move decide if we should transition
	var relevance: StringName = current_move.check_relevance(input)
	if relevance != &"okay":
		switch_to(relevance)

	# Update the (possibly new) current move — sets velocity only
	current_move._update(input, delta)

	# Single move_and_slide() call per frame
	if player:
		player.move_and_slide()


# =============================================================================
# STATE TRANSITIONS
# =============================================================================

## Switch to a new move by name
func switch_to(state: StringName) -> void:
	if not moves.has(state):
		push_warning("MoveContainer: Unknown move '%s'" % state)
		return

	var old_name: StringName = current_move.move_name if current_move else &""
	current_move._on_exit_state()
	current_move = moves[state]
	current_move._on_enter_state()

	Log.debug("controller", "%s -> %s" % [old_name, state])
	state_changed.emit(old_name, state)


# =============================================================================
# QUERY API
# =============================================================================

## Get a Move by name (used by Move.best_input_that_can_be_paid)
func get_move(move_name: StringName) -> Move:
	return moves.get(move_name) as Move


## Get current move name
func get_current_move_name() -> StringName:
	return current_move.move_name if current_move else &""


## Check if a move exists
func has_move(move_name: StringName) -> bool:
	return moves.has(move_name)


## Check if setup is complete
func is_ready() -> bool:
	return _is_setup
