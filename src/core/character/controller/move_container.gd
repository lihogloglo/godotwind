## MoveContainer — Holds Move nodes and manages state transitions
##
## Child of CharacterMotor. Move nodes are added as children either manually
## or by a factory. On setup, accept_moves() wires each Move with references
## to the player, model root, skeleton, resources, and movement config.
class_name MoveContainer
extends Node

const _DefaultMovementConfig := preload("res://src/core/character/controller/movement_presets/default_movement_config.tres")

## Emitted on every state transition
signal state_changed(old_move: StringName, new_move: StringName)

# --- Registered moves ---
var moves: Dictionary[StringName, Move] = {}
var current_move: Move = null
var movement_state: MovementState = MovementState.new()

# --- References (set by CharacterMotor during setup) ---
var player: CharacterBody3D = null
var character_root: Node3D = null  # Model root for rotation (may differ from player)
var animator: Node = null  # AnimationManager
var skeleton: Skeleton3D = null
var resources: Node = null  # HumanoidResources (Phase 4)
var combat: Node = null  # HumanoidCombat (Phase 5)
var legs: Node = null  # Legs (Phase 4)
@export var movement_config: CharacterMovementConfig = _DefaultMovementConfig

# --- Step-up ---
## Maximum obstacle height the character can step over without jumping
var max_step_height: float = 0.45
## Force applied to RigidBody3D objects the player walks into
var rigid_body_push_force: float = 8.0

# --- State ---
var _is_setup: bool = false
var _time_since_grounded: float = INF
var _jump_buffer_timer: float = 0.0


func set_movement_config(config: CharacterMovementConfig) -> void:
	movement_config = config if config else _DefaultMovementConfig
	max_step_height = movement_config.step_up_height
	for move: Move in moves.values():
		move.movement_config = movement_config


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
			move.movement_config = movement_config
			move.assign_combos()

	if moves.is_empty():
		push_warning("MoveContainer: No moves found as children")
		return

	# Start in idle (or first available move)
	max_step_height = movement_config.step_up_height
	var start_move: StringName = &"idle" if moves.has(&"idle") else moves.keys()[0]
	current_move = moves[start_move]
	current_move._on_enter_state()
	_is_setup = true
	_publish_movement_state(null)

	Log.info("controller", "MoveContainer: Accepted %d moves, starting in '%s'" % [
		moves.size(), start_move])


# =============================================================================
# PER-FRAME UPDATE — Called from CharacterMotor
# =============================================================================

## Process one physics frame: check relevance, maybe switch, then update.
## move_and_slide() is called HERE, once, after the move sets velocity.
func process(input: InputPackage, delta: float) -> void:
	if not _is_setup or current_move == null:
		return

	if player:
		_prepare_jump_grace_actions(input, delta, player.is_on_floor())

	# Let the current move decide if we should transition
	var relevance: StringName = current_move.check_relevance(input)
	if relevance != &"okay":
		switch_to(relevance)
		if relevance == &"jump":
			_consume_jump_grace()

	# Update the (possibly new) current move — sets velocity only
	current_move._update(input, delta)

	# Single move_and_slide() call per frame — with step-up for small obstacles
	if player:
		_move_with_step_up(delta)
		_push_rigid_bodies(delta)
	_publish_movement_state(input)


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


func get_movement_state() -> MovementState:
	return movement_state


func _publish_movement_state(input: InputPackage) -> void:
	if not movement_state:
		movement_state = MovementState.new()
	var active_name: StringName = current_move.move_name if current_move else &""
	movement_state.active_move_name = active_name
	movement_state.animation_state = _resolve_animation_state(input)
	movement_state.posture = _resolve_posture(active_name)
	movement_state.is_grounded = player.is_on_floor() if player else false
	movement_state.is_in_water = input.is_in_water if input else false
	movement_state.input_direction = input.input_direction if input else Vector2.ZERO
	movement_state.input_strength = movement_state.input_direction.length()
	movement_state.desired_world_direction = _resolve_desired_world_direction(input)
	movement_state.velocity = player.velocity if player else Vector3.ZERO
	movement_state.is_sprinting = active_name == &"sprint"
	movement_state.is_walking = active_name == &"walk"
	movement_state.is_crouching = active_name == &"crouch"
	movement_state.is_jump_move = active_name == &"jump"
	movement_state.is_airborne = active_name == &"jump" or active_name == &"midair"
	movement_state.is_jumping = movement_state.is_airborne
	movement_state.is_swimming = active_name == &"swim" or active_name == &"swim_idle"
	movement_state.elapsed_time = current_move.get_progress() if current_move else 0.0


func _prepare_jump_grace_actions(input: InputPackage, delta: float, grounded: bool) -> void:
	if not input:
		return
	var safe_delta: float = maxf(delta, 0.0)
	if grounded:
		_time_since_grounded = 0.0
	else:
		_time_since_grounded += safe_delta

	var config := movement_config if movement_config else _DefaultMovementConfig
	var jump_pressed_this_frame := input.actions.has(&"jump")
	if jump_pressed_this_frame:
		_jump_buffer_timer = config.jump_buffer_time
	else:
		_jump_buffer_timer = maxf(_jump_buffer_timer - safe_delta, 0.0)

	var has_ground_grace := grounded or _time_since_grounded <= config.coyote_time
	var has_jump_intent := jump_pressed_this_frame or _jump_buffer_timer > 0.0
	var jump_available := config.can_jump and has_move(&"jump") and has_jump_intent and has_ground_grace
	if jump_available:
		if not input.actions.has(&"jump"):
			input.actions.append(&"jump")
	else:
		input.actions.erase(&"jump")


func _consume_jump_grace() -> void:
	_jump_buffer_timer = 0.0
	_time_since_grounded = INF


func _resolve_animation_state(input: InputPackage) -> StringName:
	if not current_move:
		return &""
	var active_name := current_move.move_name
	match active_name:
		&"walk":
			return &"WalkBack" if _is_backward_input(input) else &"Walk"
		&"run":
			return &"RunBack" if _is_backward_input(input) else &"Run"
		&"crouch":
			if input and input.input_direction != Vector2.ZERO:
				return &"CrouchBack" if _is_backward_input(input) else &"CrouchWalk"
			return &"Crouch"
		&"swim_idle":
			return &"SwimIdle"
		&"swim":
			return &"SwimForward"
	return current_move.animation_state


func _resolve_posture(active_name: StringName) -> StringName:
	match active_name:
		&"crouch":
			return &"crouching"
		&"swim", &"swim_idle":
			return &"swimming"
	return &"standing"


func _resolve_desired_world_direction(input: InputPackage) -> Vector3:
	if not input or input.input_direction == Vector2.ZERO:
		return Vector3.ZERO
	return (input.camera_basis * Vector3(
		input.input_direction.x, 0.0, input.input_direction.y)).normalized()


func _is_backward_input(input: InputPackage) -> bool:
	if not input or input.input_direction == Vector2.ZERO:
		return false
	var desired := _resolve_desired_world_direction(input)
	var facing: Node3D = character_root if character_root else player
	if not facing:
		return false
	var face_direction := -facing.basis.z
	var config := movement_config if movement_config else _DefaultMovementConfig
	return absf(face_direction.signed_angle_to(desired, Vector3.UP)) > config.get_backward_angle_radians()


# =============================================================================
# MOVEMENT — Canonical pre-move step probe + unstuck recovery
# =============================================================================
# Pattern matches HL2 `CGameMovement::StepMove` / OpenMW `Stepper::step` +
# `MovementSolver::unstuck` / UE `CharacterMovementComponent::StepUp`:
# trace obstruction FIRST, try an up/forward/down probe BEFORE committing the
# slide. This avoids the post-slide-rewind fragility of the earlier bespoke
# implementation and eliminates the "horizontal_gain heuristic" that could
# reject legitimate step-ups against angled walls.
#
# See CLAUDE.md § Engineering Principle — Industry Standard, Never Kludge
# and § Simplicity Over Over-Engineering for the rationale behind replacing
# the previous bespoke version wholesale instead of patching it further.

## Small upward offset used when testing penetration recovery.
const _UNSTUCK_STEP: float = 0.02
## Maximum total upward displacement permitted during unstuck recovery.
const _UNSTUCK_MAX: float = 0.5
## Safety margin used when consuming traced travel (prevents re-catching the
## edge we just cleared). Matches OpenMW's `sCollisionMargin` role.
const _STEP_COLLISION_MARGIN: float = 0.001
## Minimum horizontal progress (meters) required at raised height to justify
## committing the step — below this, revert and slide normally.
const _STEP_MIN_FORWARD: float = 0.01
## Cosine threshold for a "walkable-looking" hit normal during the probe —
## hits with `normal.y >= 0.7` (~45°) are treated as slopes, not walls.
const _STEP_WALL_NORMAL_Y: float = 0.7


func _move_with_step_up(delta: float) -> void:
	# ----- Phase A: unstuck recovery --------------------------------------
	# Push the body out of any penetrating geometry before it tries to move.
	# Fixes spawn-into-terrain, thin-mesh tunneling, and edge penetration
	# around bridges / interior seams.
	_unstuck_if_penetrating()

	var horizontal_vel: Vector3 = Vector3(player.velocity.x, 0.0, player.velocity.z)
	var has_horizontal: bool = horizontal_vel.length_squared() > 0.0001

	# Only attempt step-up when grounded, moving horizontally, and not jumping.
	# Airborne / idle / ascending frames go straight through move_and_slide.
	if not player.is_on_floor() or not has_horizontal or player.velocity.y > 0.1:
		player.move_and_slide()
		return

	# ----- Phase B: pre-move obstruction probe ----------------------------
	var motion: Vector3 = horizontal_vel * delta
	var probe: KinematicCollision3D = KinematicCollision3D.new()
	var blocked: bool = player.test_move(player.global_transform, motion, probe)

	if not blocked:
		# Clear path — let the slide handle gravity, floor snap, and slope slide.
		player.move_and_slide()
		return

	# Ignore pushable rigid bodies (barrels, crates) — handled by the push loop.
	if probe.get_collider() is RigidBody3D:
		player.move_and_slide()
		return

	# Walkable-slope obstructions fall through to slide — slope handling
	# belongs to move_and_slide + floor_max_angle, not the step-up probe.
	var hit_normal: Vector3 = probe.get_normal()
	if hit_normal.y >= _STEP_WALL_NORMAL_Y:
		player.move_and_slide()
		return

	# ----- Phase C: up / forward / down probe -----------------------------
	# 1. Up-trace: how high can we raise before hitting a ceiling?
	var up_motion: Vector3 = Vector3.UP * (max_step_height + 0.02)
	var up_collision: KinematicCollision3D = KinematicCollision3D.new()
	var up_blocked: bool = player.test_move(player.global_transform, up_motion, up_collision)
	var up_distance: float = max_step_height + 0.02
	if up_blocked:
		up_distance = up_collision.get_travel().y - _STEP_COLLISION_MARGIN
		if up_distance <= 0.0:
			# No vertical clearance — can't step, slide instead.
			player.move_and_slide()
			return

	# 2. Save state, warp to raised height, probe forward.
	var original_position: Vector3 = player.global_position
	var original_velocity: Vector3 = player.velocity
	player.global_position.y += up_distance

	# Forward reach: bump to a minimum clearance so a single-frame velocity
	# at 5 m/s (≈ 0.08 m per tick) still reaches past a typical step depth.
	var forward_dir: Vector3 = horizontal_vel.normalized()
	var forward_len: float = maxf(motion.length(), 0.1)
	var forward_motion: Vector3 = forward_dir * forward_len
	var forward_collision: KinematicCollision3D = KinematicCollision3D.new()
	var forward_blocked: bool = player.test_move(
		player.global_transform, forward_motion, forward_collision)
	var forward_travel: Vector3 = forward_motion
	if forward_blocked:
		forward_travel = forward_collision.get_travel()
		if forward_travel.length() < _STEP_MIN_FORWARD:
			# The raised path is ALSO walled off — this wasn't a step, it was
			# a tall wall. Revert and slide normally.
			player.global_position = original_position
			player.velocity = original_velocity
			player.move_and_slide()
			return
	player.global_position += forward_travel

	# 3. Down-trace: snap onto the step surface below.
	var down_motion: Vector3 = Vector3.DOWN * _get_step_down_probe_distance(up_distance)
	var down_collision: KinematicCollision3D = KinematicCollision3D.new()
	var down_hit: bool = player.test_move(
		player.global_transform, down_motion, down_collision)
	if not down_hit:
		# No ground within step range — not a step, revert.
		player.global_position = original_position
		player.velocity = original_velocity
		player.move_and_slide()
		return

	# Reject landing on slopes steeper than the character can walk — matches
	# OpenMW's `canStepDown` + CharacterBody3D's own floor_max_angle gate.
	var down_normal: Vector3 = down_collision.get_normal()
	var floor_cos: float = cos(player.floor_max_angle)
	if down_normal.y < floor_cos:
		player.global_position = original_position
		player.velocity = original_velocity
		player.move_and_slide()
		return

	var landing_y: float = player.global_position.y + down_collision.get_travel().y
	if not _is_step_height_accepted(original_position.y, landing_y):
		player.global_position = original_position
		player.velocity = original_velocity
		player.move_and_slide()
		return

	# ----- Phase D: commit the step ---------------------------------------
	# Apply the downward travel, restore horizontal velocity, null vy so
	# gravity doesn't immediately fight the new floor contact. A single
	# move_and_slide then establishes floor state + consumes any remaining
	# motion (slope slide, residual collision) — same idiom OpenMW uses
	# between its step loop and the ground test.
	player.global_position += down_collision.get_travel()
	player.velocity = original_velocity
	player.velocity.y = 0.0
	player.move_and_slide()


func _get_step_down_probe_distance(up_distance: float) -> float:
	var config := movement_config if movement_config else _DefaultMovementConfig
	return up_distance + config.step_down_height


func _is_step_height_accepted(original_y: float, landing_y: float) -> bool:
	var config := movement_config if movement_config else _DefaultMovementConfig
	return landing_y - original_y >= config.min_step_height


## Push the player out of penetrating geometry. Runs every frame at the top
## of `_move_with_step_up()`. Mirrors OpenMW `MovementSolver::unstuck`: if the
## body is currently overlapping the world, raise it in small increments up
## to `_UNSTUCK_MAX` until clear. Beyond that cap we stop and warn — deeper
## penetration is a signal of bad geometry, not something to silently patch.
func _unstuck_if_penetrating() -> void:
	# test_move with Vector3.ZERO reports true when the current transform is
	# already intersecting world geometry. Cheap: no sweep, pure contact test.
	if not player.test_move(player.global_transform, Vector3.ZERO):
		return
	var total_pushed: float = 0.0
	while total_pushed < _UNSTUCK_MAX:
		player.global_position.y += _UNSTUCK_STEP
		total_pushed += _UNSTUCK_STEP
		if not player.test_move(player.global_transform, Vector3.ZERO):
			return
	# Still penetrating after the cap — revert and warn rather than teleport.
	player.global_position.y -= total_pushed
	Log.warn("controller", "unstuck: unable to escape penetration after %.2fm at %s" % [
		total_pushed, player.global_position])


## Push any RigidBody3D objects the player collided with during move_and_slide().
func _push_rigid_bodies(delta: float) -> void:
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
				rb.apply_impulse(push_dir * rigid_body_push_force * delta, offset)
