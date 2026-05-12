## CarryController — HL2-style physics-gun carry
##
## Framework class. Owns the "held body" state for the player and drives
## a held `RigidBody3D` toward a camera-relative target via per-physics-
## tick velocity commands. The body stays DYNAMIC the entire time it is
## held — Jolt integrates it normally and Godot 4.6's project-wide
## physics interpolation smooths the rendered position between ticks.
##
## ## Architecture (post-2026-04-08 rewrite)
##
## See `AGENTS.md` "Engineering Principle - Simplicity Over Over-Engineering"
## for the full saga. The short version: previous
## sessions tried four flavors of kinematic direct-transform-write
## (frozen body + `body.global_transform = X` from `_process`), all of
## which fought Godot's physics interpolation system and produced render-
## rate-vs-physics-rate beat-frequency vibration. The user pasted the
## HL2 physics-gun snippet, the agent recognized the canonical pattern,
## and this rewrite shipped. Old approach: ~600 lines + manual chain
## composition + wall pushback raycast + per-node interp carve-outs.
## New approach: ~250 lines, no carve-outs, no manual composition.
##
## ## Contract
##
## **On grab** (deferred from `try_grab` → `_do_grab`):
##   - `freeze = false` — body stays dynamic, Jolt integrates
##   - `gravity_scale = 0` — body floats while held (the canonical
##     trade-off: small "sag" disabled in exchange for predictable
##     hold position. The user piloted gravity-on + force-at-grab-point
##     and gravity-off + center-grab side by side and picked the
##     simpler one — see chat history 2026-04-08 ~22:25)
##   - `linear_damp` / `angular_damp` bumped — prevents oscillation
##   - `collision_mask` excludes the player's current layer bits — held body
##     doesn't push the player during normal play or interior layer rewrites
##   - `linear_velocity` / `angular_velocity` zeroed — clean chase start
##
## **Each `_physics_process` tick (while held)**:
##   - Compute world target pose from camera-rig marker
##   - `linear_velocity = clamp((target_pos - body_pos) * PULL, MAX_SPEED)`
##   - `angular_velocity = axis * angle * ANG_PULL` (shortest-path slerp)
##
## **On release** (deferred from `release` → `_do_release`):
##   - Restore `gravity_scale`, `collision_mask`, damping
##   - DO NOT zero velocity — body retains its last-frame chase velocity
##     as the natural throw impulse. Camera-swing release == fast throw,
##     stationary release == drop. No threshold, no ring buffer, no
##     lever-arm cross product. Physics gives it for free.
##
## ## Single-owner contract (MF1)
##
## `CarryController` is the SOLE owner of "held body" state. The
## `InteractionRaycaster` does NOT track held targets. `PlayerController`
## queries `is_carrying()` if it needs to gate other interactions while
## holding.
##
## ## Deferred-mutation rule (§6.2)
##
## All `RigidBody3D` STATE MUTATIONS (freeze, gravity_scale, collision_mask,
## damping) at grab/release time go through `call_deferred` so they run
## OUTSIDE any physics callback. The per-frame `linear_velocity` /
## `angular_velocity` writes in `_physics_process` are exempt — Godot
## physics state writes from `_physics_process` are the canonical safe
## path (the entire purpose of the callback). Per-tick velocity writes
## are how `CharacterBody3D.move_and_slide` works internally.
##
## ## Framework/adapter boundary
##
## Zero game-specific imports. Reads `carryable_wrapper` meta to validate
## grab targets — that meta is set by `CarryableBodyFactory` regardless
## of the underlying game (MW or otherwise).
class_name CarryController
extends Node3D

const GameplayPhysicsLayersScript := preload("res://src/core/physics/gameplay_physics_layers.gd")


# --- Signals

## Emitted when `try_grab` refuses a grab. Reason is a short string the
## prompt UI surfaces ("Too heavy", "Already carrying", "Not carryable").
signal grab_refused(reason: String)

## Emitted on successful grab + on release.
signal grabbed(body: RigidBody3D)
signal released(body: RigidBody3D)


# --- Tunables

## Linear chase gain — `velocity = (target - body) * PULL_STRENGTH`.
## Higher = stiffer chase, lower = floatier. Tuned via interactive
## playtest in `tests/visual/test_carry_velocity_drive.tscn`.
const PULL_STRENGTH: float = 14.0

## Angular chase gain — `angular_velocity = axis * angle * ANGULAR_PULL`.
const ANGULAR_PULL: float = 12.0

## Safety caps so far grabs / fast camera swings don't teleport the body.
const MAX_LINEAR_SPEED: float = 12.0  # m/s
const MAX_ANGULAR_SPEED: float = 20.0  # rad/s

## Damping applied to the held body during the hold. The damp is what
## prevents oscillation around the target — proportional chase + constant
## damping is the standard physics-gun control loop.
const HELD_LINEAR_DAMP: float = 4.0
const HELD_ANGULAR_DAMP: float = 6.0

## Hold-pose distance clamp. Per-grab capture uses the body's actual
## camera-local position (so "grab where you aim"), clamped to keep the
## hold pose between the camera and arm's-length.
const MIN_HOLD_DISTANCE: float = 0.6
const MAX_HOLD_DISTANCE: float = 2.5

## Fallback hold offset — used only if the per-grab capture is degenerate
## (camera-local position not finite, e.g. body somehow at the camera
## origin). Real captures override this on every grab.
const FALLBACK_HOLD_OFFSET: Vector3 = Vector3(0.0, -0.2, -1.2)

## Gameplay weight cap (spec §13 Q4). Bodies heavier than this refuse
## the grab path with a "Too heavy" prompt. Tap-to-take inventory path
## is independent and can still take heavy items.
const MAX_GRAB_MASS_KG: float = 50.0


# --- Wiring (set by PlayerController via setup())

var camera: Camera3D = null
var player: CharacterBody3D = null

## I.6 — optional streaming manager reference for cell-unload survival.
## Type-erased to `Node` so this framework class doesn't import the
## streaming script. Methods called via duck-typing:
## `register_persistent_node`, `unregister_persistent_node`,
## `find_grid_for_node`. NULL is fine for test scenes that don't load
## the streaming pipeline.
var _streaming_manager: Node = null


# --- Held state (single source of truth, MF1)

var _held_body: RigidBody3D = null
var _held_pickup: Interactable = null
var _held_origin_parent: Node = null
var _hold_target_marker: Marker3D = null

# Pre-grab state captured at grab time so `_do_release` can restore the
# body to its exact pre-hold configuration. The collision mask snapshot
# also satisfies the §6.5 "exact restore" contract.
var _saved_collision_mask: int = 0
var _saved_gravity_scale: float = 1.0
var _saved_linear_damp: float = 0.0
var _saved_angular_damp: float = 0.0
var _held_excluded_player_layers: int = 0


## Public configuration. Called by PlayerController during setup.
func setup(p_camera: Camera3D, p_player: CharacterBody3D) -> void:
	camera = p_camera
	player = p_player
	if camera == null:
		push_error("CarryController.setup: camera is null")
		return
	if _hold_target_marker == null:
		_hold_target_marker = Marker3D.new()
		_hold_target_marker.name = "HoldTarget"
		# Initial position is the fallback — overwritten on each grab
		# with the actual camera-local position of the grabbed body.
		_hold_target_marker.position = FALLBACK_HOLD_OFFSET
		camera.add_child(_hold_target_marker)


## I.6 — optional streaming manager reference. See type doc above.
func set_streaming_manager(p_streaming_manager: Node) -> void:
	_streaming_manager = p_streaming_manager


## Is something currently being held?
func is_carrying() -> bool:
	return _held_body != null and is_instance_valid(_held_body)


## Returns the held RigidBody3D, or null.
func get_held_body() -> RigidBody3D:
	return _held_body


## Returns the held Pickup wrapper, or null.
func get_held_pickup() -> Interactable:
	return _held_pickup


## Returns the Marker3D parented to the camera that represents the
## current hold target pose. Diagnostic / introspection use.
func get_hold_target_marker() -> Marker3D:
	return _hold_target_marker


## Attempt to grab the given Interactable. Returns true on success.
##
## Validation: target must be a wrapper produced by `CarryableBodyFactory`
## (i.e. parent has `carryable_wrapper` meta and the wrapper contains a
## `RigidBody3D` child). Mass-cap refusal happens here too.
##
## All RB state mutation is deferred via `_do_grab.call_deferred`. The
## controller-side state (`_held_body`, etc.) is set immediately so that
## `is_carrying()` returns true to other systems right away.
func try_grab(target: Interactable) -> bool:
	if is_carrying():
		grab_refused.emit("Already carrying")
		return false
	if target == null:
		return false
	if camera == null:
		push_warning("CarryController.try_grab: not configured (camera missing)")
		return false

	# Validate that the target's parent is a tagged carryable wrapper.
	var parent_root := target.get_parent()
	if parent_root == null or not parent_root.has_meta("carryable_wrapper"):
		# Not a Pickup from the factory — could be an NPC, book, door,
		# etc. Refuse silently. Tap path still works for those.
		return false

	# Find the RigidBody3D child of the wrapper.
	var rb: RigidBody3D = null
	for child in target.get_children():
		if child is RigidBody3D:
			rb = child
			break
	if rb == null:
		push_warning("CarryController.try_grab: Pickup wrapper has no RigidBody3D child")
		return false

	# Weight cap (spec §13 Q4). The hold path is gated; the tap-to-
	# inventory path is independent and still works on heavy items.
	if rb.mass > MAX_GRAB_MASS_KG:
		grab_refused.emit("Too heavy")
		return false

	# Capture the hold-pose marker BEFORE deferring — uses the body's
	# camera-local position at THIS instant (so the player grabs where
	# they're aiming, not where the body ends up after a tick of physics).
	if _hold_target_marker != null:
		var body_world_pos: Vector3 = rb.global_position
		var capture_local: Vector3 = camera.global_transform.affine_inverse() * body_world_pos
		var dist: float = capture_local.length()
		if dist < MIN_HOLD_DISTANCE:
			capture_local = capture_local.normalized() * MIN_HOLD_DISTANCE
		elif dist > MAX_HOLD_DISTANCE:
			capture_local = capture_local.normalized() * MAX_HOLD_DISTANCE
		if not capture_local.is_finite():
			capture_local = FALLBACK_HOLD_OFFSET
		_hold_target_marker.position = capture_local

	# Snapshot pre-grab state on the controller side immediately so
	# `is_carrying()` returns true to consumers right away. Body-side
	# mutation is deferred below.
	_held_body = rb
	_held_pickup = target
	_held_origin_parent = parent_root
	_saved_collision_mask = rb.collision_mask
	_saved_gravity_scale = rb.gravity_scale
	_saved_linear_damp = rb.linear_damp
	_saved_angular_damp = rb.angular_damp

	_do_grab.call_deferred(target, rb)
	grabbed.emit(rb)
	return true


## Deferred grab body — runs OUTSIDE the physics callback. Switches the
## body from "frozen at rest" to "dynamic + chased by velocity drive".
##
## Per §6.2: in-callback RB state mutation can crash Jolt with sig 11
## and no GDScript stack. Deferring batches the entire transition into
## a single safe post-physics-tick atomic operation.
func _do_grab(target: Interactable, rb: RigidBody3D) -> void:
	if not is_instance_valid(target) or not is_instance_valid(rb):
		# Target was freed between try_grab() and the deferred call.
		# Roll back the controller state.
		_held_body = null
		_held_pickup = null
		_held_origin_parent = null
		_saved_collision_mask = 0
		_saved_gravity_scale = 1.0
		_saved_linear_damp = 0.0
		_saved_angular_damp = 0.0
		_held_excluded_player_layers = 0
		return
	if camera == null:
		return

	# Switch from frozen-at-rest to dynamic-while-held.
	rb.freeze = false
	rb.gravity_scale = 0.0
	rb.linear_damp = HELD_LINEAR_DAMP
	rb.angular_damp = HELD_ANGULAR_DAMP

	# Mask flip -- clear the player body's current layer bits so the held body
	# doesn't push the player capsule around. Bit-precise. Restored exactly on
	# release per §6.5.
	_apply_held_player_collision_exclusion(rb)

	# Zero starting velocity so the chase doesn't inherit whatever the
	# body was doing pre-grab (falling, sliding off a table, etc.).
	rb.linear_velocity = Vector3.ZERO
	rb.angular_velocity = Vector3.ZERO

	# I.6 — register the held body with the streaming manager (if wired)
	# so cell unload doesn't free it. Duck-typed call — test scenes
	# without a streaming pipeline run with `_streaming_manager == null`
	# and skip cleanly.
	if _streaming_manager != null and _streaming_manager.has_method("find_grid_for_node"):
		var origin_grid: Vector2i = _streaming_manager.find_grid_for_node(rb)
		_streaming_manager.register_persistent_node(rb, origin_grid)


## Release the held body. The body retains its last-frame chase velocity
## as a natural throw impulse — no threshold detection, no ring buffer,
## no lever-arm cross product. A camera swing produces a fast throw, a
## stationary release produces a soft drop. Physics handles it.
##
## Same defer-everything pattern as `try_grab` for the same reason.
func release() -> void:
	if not is_carrying():
		return
	var rb := _held_body
	var saved_mask := _saved_collision_mask
	var saved_gs := _saved_gravity_scale
	var saved_ld := _saved_linear_damp
	var saved_ad := _saved_angular_damp

	# Clear state up front so re-entrancy and signal handlers see a
	# clean controller. The deferred body below validates from captured
	# locals.
	released.emit(rb)
	_held_body = null
	_held_pickup = null
	_held_origin_parent = null
	_saved_collision_mask = 0
	_saved_gravity_scale = 1.0
	_saved_linear_damp = 0.0
	_saved_angular_damp = 0.0
	_held_excluded_player_layers = 0

	if rb == null or not is_instance_valid(rb):
		return

	_do_release.call_deferred(rb, saved_mask, saved_gs, saved_ld, saved_ad)


## Deferred release body — restore exact pre-grab state. Critically does
## NOT zero velocity: whatever chase velocity the body had at the moment
## of release becomes the throw impulse, automatically.
func _do_release(
	rb: RigidBody3D,
	saved_mask: int,
	saved_gs: float,
	saved_ld: float,
	saved_ad: float,
) -> void:
	if not is_instance_valid(rb):
		return

	# §6.5: restore mask EXACTLY, before any other state change.
	rb.collision_mask = saved_mask
	rb.gravity_scale = saved_gs
	rb.linear_damp = saved_ld
	rb.angular_damp = saved_ad
	# Body is already `freeze = false` from grab time. Leave it that way
	# so Jolt continues integrating it as a normal dynamic rigid body
	# until `can_sleep` puts it to rest naturally.

	# I.6 — unregister from streaming persistent set. Body is no longer
	# protected from cell unload.
	if _streaming_manager != null and _streaming_manager.has_method("unregister_persistent_node"):
		_streaming_manager.unregister_persistent_node(rb)


func _apply_held_player_collision_exclusion(rb: RigidBody3D) -> void:
	if rb == null or not is_instance_valid(rb):
		return
	if not is_carrying() and _saved_collision_mask == 0:
		return
	var player_layers := GameplayPhysicsLayersScript.get_body_collision_layers(
		player,
		GameplayPhysicsLayersScript.PLAYER
	)
	_held_excluded_player_layers = player_layers
	rb.collision_mask = GameplayPhysicsLayersScript.exclude_layers(_saved_collision_mask, player_layers)


func _refresh_held_player_collision_exclusion() -> void:
	if not is_carrying():
		return
	var player_layers := GameplayPhysicsLayersScript.get_body_collision_layers(
		player,
		GameplayPhysicsLayersScript.PLAYER
	)
	if player_layers == _held_excluded_player_layers:
		return
	_apply_held_player_collision_exclusion.call_deferred(_held_body)


# --- Per-tick chase loop (the entire hold logic in one function)

## Velocity-drive chase. Runs in `_physics_process` because that is the
## ONLY place velocity writes are guaranteed to be picked up by the next
## physics integrator step. Reading body / target world positions here
## also gets the freshest values (post-`move_and_slide` on the player).
##
## Per the deferred-mutation rule: STATE writes (freeze, mask, gravity)
## are deferred via call_deferred. VELOCITY writes from `_physics_process`
## are the canonical safe path — that's how `move_and_slide` works.
func _physics_process(_delta: float) -> void:
	if not is_carrying():
		return
	if _hold_target_marker == null or camera == null:
		return
	if not is_instance_valid(_held_body):
		# External code freed the body — clear state and bail.
		_held_body = null
		_held_pickup = null
		_held_origin_parent = null
		return
	_refresh_held_player_collision_exclusion()

	var target_xf: Transform3D = _hold_target_marker.global_transform
	var target_pos: Vector3 = target_xf.origin
	var body_pos: Vector3 = _held_body.global_position

	# --- Linear velocity drive ---
	#   v = (target - current) * PULL_STRENGTH
	# Jolt integrates this over the physics tick; engine interpolation
	# smooths the rendered position between ticks. Body is MODE_INHERIT
	# (default) so engine interpolation applies — no carve-outs needed.
	var delta_pos: Vector3 = target_pos - body_pos
	var desired_v: Vector3 = delta_pos * PULL_STRENGTH
	var speed: float = desired_v.length()
	if speed > MAX_LINEAR_SPEED:
		desired_v = desired_v * (MAX_LINEAR_SPEED / speed)
	# NaN guard — if any input was non-finite, fall back to zero so we
	# don't propagate NaN into the physics server.
	if not desired_v.is_finite():
		desired_v = Vector3.ZERO
	_held_body.linear_velocity = desired_v

	# --- Angular velocity drive ---
	# Target basis: camera yaw + pitch, roll locked to world up per
	# §6.2 hold-pose rotation contract. Build target basis from camera
	# Euler with roll component dropped, then compute shortest-path
	# rotation as a quaternion → axis-angle → angular velocity.
	var cam_euler: Vector3 = target_xf.basis.get_euler()
	var target_basis: Basis = Basis.from_euler(Vector3(cam_euler.x, cam_euler.y, 0.0))
	var current_basis: Basis = _held_body.global_basis
	var delta_basis: Basis = target_basis * current_basis.inverse()
	var q: Quaternion = delta_basis.get_rotation_quaternion()
	# Shortest-path: negate q if w < 0 (long-way rotation).
	if q.w < 0.0:
		q = Quaternion(-q.x, -q.y, -q.z, -q.w)
	var w: float = clampf(q.w, -1.0, 1.0)
	var angle: float = 2.0 * acos(w)
	var desired_ang_v: Vector3 = Vector3.ZERO
	if angle > 0.0001:
		var sin_half: float = sqrt(maxf(0.0, 1.0 - w * w))
		if sin_half > 0.0001:
			var axis: Vector3 = Vector3(q.x, q.y, q.z) / sin_half
			desired_ang_v = axis * (angle * ANGULAR_PULL)
	var ang_speed: float = desired_ang_v.length()
	if ang_speed > MAX_ANGULAR_SPEED:
		desired_ang_v = desired_ang_v * (MAX_ANGULAR_SPEED / ang_speed)
	if not desired_ang_v.is_finite():
		desired_ang_v = Vector3.ZERO
	_held_body.angular_velocity = desired_ang_v


## Shutdown safety — restore any held body to a clean state before the
## scene tree continues unwinding. Inline mutation is safe in `_exit_tree`
## because Jolt has stopped integrating (project shutdown) and no other
## system can reference the body. This is the one exception to the §6.2
## deferred-mutation rule.
##
## Simpler than the previous architecture's `_exit_tree` because the body
## was never frozen in the first place — we only need to restore mask,
## gravity, damping, and null our refs.
func _exit_tree() -> void:
	if _held_body != null and is_instance_valid(_held_body):
		_held_body.collision_mask = _saved_collision_mask
		_held_body.gravity_scale = _saved_gravity_scale
		_held_body.linear_damp = _saved_linear_damp
		_held_body.angular_damp = _saved_angular_damp
		_held_body.linear_velocity = Vector3.ZERO
		_held_body.angular_velocity = Vector3.ZERO
		_held_body = null
		_held_pickup = null
		_held_excluded_player_layers = 0
	_hold_target_marker = null
