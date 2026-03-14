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

# --- Step-up ---
## Maximum obstacle height the character can step over without jumping
var max_step_height: float = 0.45
## Force applied to RigidBody3D objects the player walks into
var rigid_body_push_force: float = 8.0

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

	# Single move_and_slide() call per frame — with step-up for small obstacles
	if player:
		_move_with_step_up()
		_push_rigid_bodies()


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


# =============================================================================
# STEP-UP — Separate body for step detection + smooth Y interpolation
# =============================================================================

## Smoothed Y position for visual step climbing (avoids jerky teleports)
var _step_target_y: float = 0.0
var _step_initialized: bool = false
## Speed at which the body interpolates to step height
var step_smooth_speed: float = 12.0

## Move with automatic step-up over small obstacles (stairs, curbs, bumps).
## Uses a two-phase approach:
## 1. test_move() probes ahead at raised height to detect climbable steps
## 2. If step found, smoothly interpolate Y up instead of teleporting
func _move_with_step_up() -> void:
	if not _step_initialized:
		_step_target_y = player.global_position.y
		_step_initialized = true

	var has_horizontal := absf(player.velocity.x) > 0.01 or absf(player.velocity.z) > 0.01
	if not player.is_on_floor() or not has_horizontal or player.velocity.y > 0.1:
		# Not grounded, not moving, or jumping — normal move
		player.move_and_slide()
		_step_target_y = player.global_position.y
		return

	# Save pre-move state
	var original_pos := player.global_position
	var original_vel := player.velocity

	# Normal move first
	player.move_and_slide()

	# Check if we hit a static obstacle (wall-like normal) — skip RigidBody3D (pushable)
	var hit_wall := false
	for i in player.get_slide_collision_count():
		var col := player.get_slide_collision(i)
		if col.get_normal().y < 0.5 and not (col.get_collider() is RigidBody3D):
			hit_wall = true
			break

	if not hit_wall:
		_step_target_y = player.global_position.y
		return  # Normal move succeeded

	# Step detection: try moving from a raised position
	var post_normal_pos := player.global_position
	var post_normal_vel := player.velocity

	# Reset to original position for the raised test
	player.global_position = original_pos
	player.velocity = original_vel

	# Check ceiling clearance
	var raise_height := max_step_height + 0.05
	if player.test_move(player.global_transform, Vector3.UP * raise_height):
		# No room above — stick with normal result
		player.global_position = post_normal_pos
		player.velocity = post_normal_vel
		_step_target_y = player.global_position.y
		return

	# Raise, move forward, snap down — all via test_move (no move_and_slide)
	player.global_position.y += raise_height

	# Test horizontal movement at raised height.
	# Use enough forward distance to clear the step's depth — per-frame velocity
	# (0.08m at 5m/s) is often too short to reach past a step edge.
	var h_vel := Vector3(original_vel.x, 0.0, original_vel.z)
	var h_speed := h_vel.length()
	var h_dir := h_vel / h_speed if h_speed > 0.01 else Vector3.ZERO
	var h_motion := h_dir * maxf(h_speed * get_physics_process_delta_time(), 0.4)
	var h_collision := KinematicCollision3D.new()
	var h_blocked := player.test_move(player.global_transform, h_motion, h_collision)

	# Apply horizontal travel (full or partial)
	if h_blocked:
		player.global_position += h_collision.get_travel()
	else:
		player.global_position += h_motion

	# Snap down to find the step surface
	var down_motion := Vector3.DOWN * (raise_height + max_step_height)
	var down_collision := KinematicCollision3D.new()
	if player.test_move(player.global_transform, down_motion, down_collision):
		var landed_y := player.global_position.y + down_collision.get_travel().y
		var horizontal_gain := Vector2(
			player.global_position.x - original_pos.x,
			player.global_position.z - original_pos.z).length()
		var normal_gain := Vector2(
			post_normal_pos.x - original_pos.x,
			post_normal_pos.z - original_pos.z).length()

		if horizontal_gain > normal_gain * 1.1 and landed_y >= original_pos.y - 0.1:
			# Step-up succeeded — use the new position
			player.global_position.y = landed_y
			player.velocity = original_vel
			player.velocity.y = 0.0
			# Force floor detection with a tiny move_and_slide
			player.move_and_slide()
			_step_target_y = player.global_position.y
			return

	# Step-up didn't improve — revert to normal move result
	player.global_position = post_normal_pos
	player.velocity = post_normal_vel
	_step_target_y = player.global_position.y


## Push any RigidBody3D objects the player collided with during move_and_slide().
func _push_rigid_bodies() -> void:
	if rigid_body_push_force <= 0.0:
		return
	for i: int in player.get_slide_collision_count():
		var col: KinematicCollision3D = player.get_slide_collision(i)
		if col == null:
			continue
		var collider: Object = col.get_collider()
		if collider is RigidBody3D:
			var rb: RigidBody3D = collider as RigidBody3D
			var push_dir: Vector3 = -col.get_normal()
			push_dir.y = 0.0
			if push_dir.length_squared() > 0.001:
				push_dir = push_dir.normalized()
				var contact: Vector3 = col.get_position()
				var offset: Vector3 = contact - rb.global_position
				rb.apply_impulse(push_dir * rigid_body_push_force * get_physics_process_delta_time(), offset)
