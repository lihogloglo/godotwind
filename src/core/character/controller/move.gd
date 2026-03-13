## Move — Base class for character states in the Move-as-Node pattern
##
## Each concrete Move (Idle, Run, Attack, Roll...) is a Node child of MoveContainer.
## Moves own their movement physics, animation control, and transition logic.
## Adapted from Gab-ani's Universal Controller with strict typing.
class_name Move
extends Node

# --- References (wired by MoveContainer.accept_moves()) ---
var player: CharacterBody3D = null
var character_root: Node3D = null  # Model root for rotation (separate from player when camera is child)
var animator: Node = null  # AnimationManager
var skeleton: Skeleton3D = null
var resources: Node = null  # HumanoidResources (Phase 4)
var combat: Node = null  # HumanoidCombat (Phase 5)
var container: Node = null  # MoveContainer
var legs: Node = null  # Legs (Phase 4)

# --- Configuration ---
@export var move_name: StringName = &""
@export var animation_state: StringName = &""  # Maps to AnimationManager state name
@export var priority: int = 0
@export var stamina_cost: float = 0.0
@export var tracking_angular_speed: float = 10.0

# --- Physics ---
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

# --- State tracking ---
var enter_state_time: float = 0.0
var initial_position: Vector3 = Vector3.ZERO

# --- Forced / queued move system ---
var has_forced_move: bool = false
var forced_move: StringName = &""
var has_queued_move: bool = false
var queued_move: StringName = &""

# --- Combos (child Combo nodes) ---
var combos: Array[Node] = []  # Array[Combo]


# =============================================================================
# LIFECYCLE — Called by MoveContainer
# =============================================================================

## Main relevance check: should we stay in this move or transition?
## Returns &"okay" to stay, or a move_name to transition to.
func check_relevance(input: InputPackage) -> StringName:
	# Check combo queueing windows
	if accepts_queueing():
		_check_combos(input)

	# Dequeue if in transition window
	if has_queued_move and transitions_to_queued():
		try_force_move(queued_move)
		has_queued_move = false

	# Forced move takes priority
	if has_forced_move:
		has_forced_move = false
		return forced_move

	return default_lifecycle(input)


## Override in subclasses to define transition logic.
## Default: stay until duration expires, then pick best available input.
func default_lifecycle(input: InputPackage) -> StringName:
	return best_input_that_can_be_paid(input)


## Called every physics frame while this is the active move.
## Internal wrapper that handles input vector processing before subclass update.
func _update(input: InputPackage, delta: float) -> void:
	update(input, delta)


## Override in subclasses for per-frame logic (movement, weapon activation, etc.)
func update(_input: InputPackage, _delta: float) -> void:
	pass


## Called when entering this move state
func _on_enter_state() -> void:
	initial_position = player.global_position if player.is_inside_tree() else player.position
	mark_enter_state()
	on_enter_state()
	# Tell AnimationManager to transition to our animation state
	if animator and not animation_state.is_empty():
		if animator.has_method("transition_to"):
			animator.transition_to(animation_state, true)

func on_enter_state() -> void:
	pass


## Called when leaving this move state
func _on_exit_state() -> void:
	on_exit_state()

func on_exit_state() -> void:
	pass


# =============================================================================
# INPUT RESOLUTION
# =============================================================================

## Pick the highest-priority action that the player can afford (stamina-wise).
## Returns &"okay" if we should stay in the current move.
func best_input_that_can_be_paid(input: InputPackage) -> StringName:
	# Sort by priority (highest first)
	var sorted_actions: Array[StringName] = input.actions.duplicate()
	sorted_actions.sort_custom(_priority_sort)

	for action: StringName in sorted_actions:
		var move: Move = _get_move(action)
		if move == null:
			continue
		if _can_afford(move):
			if move == self:
				return &"okay"
			return action

	return &"okay"


## Compare two action names by their Move priority (descending)
func _priority_sort(a: StringName, b: StringName) -> bool:
	var move_a: Move = _get_move(a)
	var move_b: Move = _get_move(b)
	var prio_a: int = move_a.priority if move_a else 0
	var prio_b: int = move_b.priority if move_b else 0
	return prio_a > prio_b


## Look up a Move by name from the container
func _get_move(name: StringName) -> Move:
	if container and container.has_method("get_move"):
		return container.get_move(name)
	return null


## Check if a move can be paid for (stamina). Always true until Phase 4.
func _can_afford(_move: Move) -> bool:
	if resources and resources.has_method("can_be_paid"):
		return resources.can_be_paid(_move)
	return true


# =============================================================================
# MOVEMENT HELPERS
# =============================================================================

## Camera-relative direction calculation + character rotation.
## Called by locomotion moves that track input direction.
## Rotates character_root (not player, since camera is parented to player).
func process_input_vector(input: InputPackage, delta: float) -> void:
	var input_dir_3d := (input.camera_basis * Vector3(
		input.input_direction.x, 0.0, input.input_direction.y)).normalized()
	var facing: Node3D = character_root if character_root else player
	var face_direction := -facing.basis.z
	var angle := face_direction.signed_angle_to(input_dir_3d, Vector3.UP)
	facing.rotate_y(clampf(angle,
		-tracking_angular_speed * delta, tracking_angular_speed * delta))


# =============================================================================
# TIMING HELPERS
# =============================================================================

func mark_enter_state() -> void:
	enter_state_time = Time.get_unix_time_from_system()

func get_progress() -> float:
	return Time.get_unix_time_from_system() - enter_state_time

func works_longer_than(time: float) -> bool:
	return get_progress() >= time

func works_less_than(time: float) -> bool:
	return get_progress() < time

func works_between(start: float, finish: float) -> bool:
	var progress := get_progress()
	return progress >= start and progress <= finish


# =============================================================================
# COMBO / QUEUE / FORCE SYSTEM
# =============================================================================

## Override in subclasses or use MovesDataRepository (Phase 5)
func accepts_queueing() -> bool:
	return false

## Override in subclasses or use MovesDataRepository (Phase 5)
func transitions_to_queued() -> bool:
	return false

func _check_combos(input: InputPackage) -> void:
	for combo: Node in combos:
		if combo.has_method("is_triggered") and combo.is_triggered(input):
			var triggered_name: StringName = combo.get("triggered_move")
			var triggered_move: Move = _get_move(triggered_name)
			if triggered_move and _can_afford(triggered_move):
				has_queued_move = true
				queued_move = triggered_name

## Force transition to a move (used by hit reactions, death, etc.)
func try_force_move(new_forced_move: StringName) -> void:
	if not has_forced_move:
		has_forced_move = true
		forced_move = new_forced_move
	else:
		# Higher priority forced move wins
		var new_move: Move = _get_move(new_forced_move)
		var old_move: Move = _get_move(forced_move)
		if new_move and old_move and new_move.priority >= old_move.priority:
			forced_move = new_forced_move

## Assign child Combo nodes
func assign_combos() -> void:
	combos.clear()
	for child in get_children():
		if child.has_method("is_triggered"):
			combos.append(child)
			if "move" in child:
				child.move = self
