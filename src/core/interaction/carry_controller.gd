## CarryController — Generic kinematic-reparent hold-and-carry
##
## Framework class. Owns the "held body" state for the player. Sits as a
## child of the player rig (typically `PlayerController`), exposes a
## `Marker3D` hold target parented to the camera, and routes
## `try_grab` / `release` from the player controller's interact signals.
##
## ## Phase scope (I.3 — see `INTERACTION_SYSTEM.md` §6.2 / §6.5)
##
## Implements:
## - **Grab**: kinematic reparent of the carryable wrapper (`Pickup`) to
##   the camera-relative `HoldTarget` Marker3D. Snapshot original
##   collision mask, clear `LAYER_PLAYER` bit so the held body doesn't
##   collide with the player capsule.
## - **Hold**: per-physics-frame lerp toward the marker position + roll
##   lock (yaw + pitch tracked, world-up enforced). NaN/inf force clamp.
## - **Release**: restore original mask EXACTLY, reparent back to the
##   original parent (cell), `freeze = false`, `linear_velocity =
##   player_velocity`. No throw impulse — that's I.4. No orphan registry —
##   that's I.6.
##
## Defers to later phases:
## - I.4: throw impulse + camera angular velocity ring buffer
## - I.4: weight cap refusal at grab time
## - I.4: hold spring wall pushback
## - I.6: orphan registry for released items in unloaded cells
##
## ## Framework/adapter boundary
##
## ZERO game-specific imports. Reads `carryable_wrapper` meta to validate
## grab targets — that meta is set by `CarryableBodyFactory` regardless
## of the underlying game (MW or otherwise). The wrapper is duck-typed:
## must contain at least one `RigidBody3D` child.
##
## ## Single owner contract (MF1)
##
## `CarryController` is the SOLE owner of "held body" state. The
## `InteractionRaycaster` does NOT track held targets — it keeps casting
## normally and may report a different Interactable under the crosshair
## while the player is holding something. `PlayerController` queries
## `is_carrying()` if it needs to gate other interactions while held.
##
## ## Reparent safety (MF2)
##
## All reparent calls go through `call_deferred("reparent", ...)`. A
## reparent during a physics callback (or during the same frame as a
## raycast hit on the body) is a use-after-free hazard — see bug A from
## I.2 for the same failure mode.
class_name CarryController
extends Node3D

const CarryableBodyFactoryScript := preload("res://src/core/interaction/carryable_body_factory.gd")


# --- Signals

## Emitted when `try_grab` refuses a grab. Reason is a short string the
## prompt UI surfaces ("Too heavy", "Already carrying", "Not carryable").
## Listeners are typically the test scene or a UI overlay; the signal is
## fire-and-forget.
signal grab_refused(reason: String)

## Emitted on successful grab + on release, so consumers can react
## (e.g. UI prompt change, weapon-swap gating).
signal grabbed(body: RigidBody3D)
signal released(body: RigidBody3D)


# --- Tunables (SF1: constants block, no magic numbers in _physics_process)

## Fallback hold offset used ONLY if grab is called with a body whose
## camera-local position can't be computed (degenerate case). The real
## hold pose is captured per-grab from the body's actual position in
## camera space at the moment of grab — see `_do_grab`. This means the
## object stays at the spot you aimed at when you grabbed it (Oblivion
## telekinesis feel), with inertia from the position lerp as the camera
## moves and the marker drags the object after it.
const FALLBACK_HOLD_OFFSET: Vector3 = Vector3(0.0, -0.2, -1.2)

## Min/max distance from the camera the per-grab capture is allowed to
## use. Prevents the held object from sticking inside the camera or
## getting yanked from across the room.
const MIN_HOLD_DISTANCE: float = 0.6
const MAX_HOLD_DISTANCE: float = 2.5

## Exponential-decay rate for the position lerp. Higher = stiffer.
## Used as `1.0 - exp(-HOLD_LERP_RATE * delta)` so the apparent
## stiffness is framerate-independent. Drives the position chase from
## `_process` (idle frame) at render rate, not `_physics_process` —
## fixes the visual jitter that comes from updating a directly-written
## kinematic body at 60Hz while the camera renders at 120/144 Hz.
## ~15 gives a snappy chase that lags by ~70 ms.
const HOLD_LERP_RATE: float = 15.0

## Exponential-decay rate for the rotation slerp.
const HOLD_ROT_LERP_RATE: float = 12.0

## NaN / inf guard ceiling on the spring force magnitude. Even though
## the I.3 implementation uses lerp (not spring forces directly), this
## constant exists for the I.4 throw + impulse path that lands on top.
const MAX_HOLD_FORCE: float = 2000.0

## Max pullback distance before force-drop (spec §6.2). I.4 wall pushback.
const HOLD_PULLBACK_MAX: float = 0.6

## Time at max pullback before force-drop, in seconds (spec §6.2).
const HOLD_PULLBACK_TIMEOUT: float = 0.3

## I.4 weight cap — bodies heavier than this refuse the hold path
## with a "too heavy" prompt. Tap-to-take inventory path still works.
## Spec §13 Q4: "treat all as one-handed; gate weight-cap on hold
## (refuse grab if mass > 50 kg, show 'too heavy' prompt)".
const MAX_GRAB_MASS_KG: float = 50.0

## I.4 throw — release detected as throw if camera angular velocity
## OR player linear velocity exceeds these thresholds. Spec §6.3.
const THROW_THRESHOLD_ANGULAR_RAD_S: float = 1.5
const THROW_THRESHOLD_LINEAR_M_S: float = 4.0

## I.4 throw — base impulse magnitude added along camera forward.
## Tunable starting value, expect playtest adjustment.
const THROW_IMPULSE_LINEAR: float = 6.0  # m/s

## I.4 throw — camera angular velocity ring buffer window (ms).
## Framerate-independent: samples are keyed by Time.get_ticks_msec()
## and any sample older than this window is dropped at read time.
## Spec §6.3 calls for 50 ms.
const THROW_SAMPLE_WINDOW_MS: int = 50

## I.4 throw — random angular velocity magnitude on tumble (rad/s).
const THROW_IMPULSE_ANGULAR_TUMBLE: float = 3.0

## §17.2.1 — physics interpolation is project-wide.
## Requires:
##   1. `physics/common/physics_interpolation = true` in `project.godot`
##   2. `camera_pivot.physics_interpolation_mode = PHYSICS_INTERPOLATION_MODE_OFF`
##      in `player_controller.gd::_setup_camera` (and equivalent on any
##      other Camera3D / camera_pivot that owns mouse-look — see also
##      `fly_camera.gd`)
##
## Per Godot 4.4+ advanced physics interpolation docs (Glenn Fiedler
## "Fix Your Timestep" pattern, the canonical 20-year industry standard).
## The engine interpolates the player capsule between physics ticks at
## render rate; the camera carve-out keeps mouse rotation render-rate
## fresh. The marker rides the camera, the held body lerps toward the
## marker's directly-read world position in `_process`. No manual
## snapshot bridge required — that was the old kludge.
##
## Locked into the codebase 2026-04-08 after @roaster verdict +
## @user industry-standard principle decision.


# --- Wiring (set by PlayerController via set_camera / set_player)

var camera: Camera3D = null
var player: CharacterBody3D = null

## I.6 — optional streaming manager reference for cell-unload survival.
## When set, `_do_grab` registers the held body as persistent so the
## streaming manager evacuates it from a cell unload instead of freeing
## it. NULL by default — test scenes that don't load the streaming
## pipeline (`tests/visual/test_interaction_phase_I*.tscn`) work without
## this. Set via `set_streaming_manager(...)` from the world setup.
##
## Type-erased to `Node` so this framework class doesn't need to import
## the streaming script (cross-system coupling avoidance per @roaster).
## Methods called via duck-typing: `register_persistent_node`,
## `unregister_persistent_node`, `find_grid_for_node`.
var _streaming_manager: Node = null


# --- Held state (single source of truth, MF1)

var _held_body: RigidBody3D = null
var _held_pickup: Interactable = null
var _held_origin_parent: Node = null
var _saved_collision_mask: int = 0
var _hold_target_marker: Marker3D = null

# I.4 throw — camera angular velocity ring buffer for the lever-arm
# impulse. Each entry is `[time_msec, basis]`. We compute angular
# velocity at release time by taking the basis delta over the window.
# Time-keyed (not frame-keyed) so the threshold is framerate-independent.
class CameraSample:
	var time_msec: int
	var basis: Basis
	func _init(t: int, b: Basis) -> void:
		time_msec = t
		basis = b

var _camera_basis_history: Array[CameraSample] = []

# I.4 wall pushback — track time-at-max-pullback so the force-drop
# timeout fires after sustained `HOLD_PULLBACK_MAX` for `HOLD_PULLBACK_TIMEOUT`.
var _pullback_max_time_msec: int = -1

# §17.2.2 fix — original camera-local capture position from `_do_grab`.
# `_apply_wall_pushback` reads THIS as the "ideal" hold pose, NOT the
# marker's current local position (which gets mutated by prior pushback
# frames and would silently no-op the restore when the wall clears).
# The marker's local position is the *applied* (possibly pulled-back)
# value, used only as the lerp target.
var _hold_capture_local: Vector3 = Vector3.ZERO


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


## I.6 — optional streaming manager reference. Wired by the world
## setup (e.g. `world_explorer.gd`) so this controller can register
## held bodies as persistent across cell unloads. Test scenes without
## a streaming pipeline don't need to call this.
##
## Type-erased to `Node` to avoid a hard import of the streaming
## script. Caller must pass a node that implements:
##   - `register_persistent_node(node: Node3D, original_grid: Vector2i)`
##   - `unregister_persistent_node(node: Node3D)`
##   - `find_grid_for_node(node: Node3D) -> Vector2i`
func set_streaming_manager(p_streaming_manager: Node) -> void:
	_streaming_manager = p_streaming_manager


## Is something currently being held?
func is_carrying() -> bool:
	return _held_body != null and is_instance_valid(_held_body)


## Returns the held RigidBody3D, or null. For consumers (UI, streaming
## skip-list in I.6) that need to read the current held body without
## owning the state.
func get_held_body() -> RigidBody3D:
	return _held_body


## Returns the held Pickup wrapper, or null.
func get_held_pickup() -> Interactable:
	return _held_pickup


## Attempt to grab the given Interactable. Returns true on success.
## The target must be a Pickup wrapper produced by `CarryableBodyFactory`
## (i.e. its parent has the `carryable_wrapper` meta and it contains a
## `RigidBody3D` child). Returns false silently otherwise.
##
## All state mutation is deferred so the actual reparent + mask flip
## happen OUTSIDE any physics callback. Mutating a RigidBody3D's
## collision_mask or transform from within a physics tick can crash Jolt
## (signal 11, no GDScript stack — same failure mode as MF2's reparent
## warning). The defer batches the whole transition into a single
## post-physics-tick operation.
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

	# I.4 weight cap (spec §13 Q4). The hold path is gated; the tap-to-
	# inventory path is independent and still works on heavy items
	# through `PickupInteractable.interact()`.
	if rb.mass > MAX_GRAB_MASS_KG:
		grab_refused.emit("Too heavy")
		return false

	# Snapshot pre-grab state on the controller side immediately so
	# `is_carrying()` returns true to consumers right away. Body-side
	# mutation is deferred below.
	_held_body = rb
	_held_pickup = target
	_held_origin_parent = parent_root
	_saved_collision_mask = rb.collision_mask

	_do_grab.call_deferred(target, rb)
	grabbed.emit(rb)
	return true


## Deferred grab body — runs OUTSIDE the physics callback. Captures the
## body's camera-local position at grab time, parks the marker there,
## freezes the body, flips the mask. Does NOT reparent — the held body
## is driven by direct `global_transform` writes from `_physics_process`
## per @reviewer id=4041 architecture call.
##
## Why no reparent: Godot's `RigidBody3D` is physics-server-owned. Its
## transform is written each tick by Jolt; the parent-chain transform
## inheritance that works for plain `Node3D`s does NOT propagate to the
## body's physics-server transform. Reparenting an RB under a moving
## anchor leaves the physics body stuck while only the wrapper Node3D
## moves. The fix is to drive carry through direct `body.global_transform`
## writes — that's the canonical way to move a frozen kinematic body.
func _do_grab(target: Interactable, rb: RigidBody3D) -> void:
	if not is_instance_valid(target) or not is_instance_valid(rb):
		# Target was freed between try_grab() and the deferred call.
		# Roll back the controller state.
		_held_body = null
		_held_pickup = null
		_held_origin_parent = null
		_saved_collision_mask = 0
		return
	if _hold_target_marker == null or camera == null:
		return

	# Capture the BODY's position in camera-local space at the moment
	# of grab. NOT the wrapper's — the wrapper stays at its original
	# cell spot the entire hold lifetime (no reparent), so its
	# `global_position` is stale after the first grab/release cycle
	# and would cause hold pose drift on every subsequent grab. The
	# RigidBody3D is what physics actually moves, so it carries the
	# real "where the prop currently is" answer.
	var body_world_pos: Vector3 = rb.global_position
	var capture_local: Vector3 = camera.global_transform.affine_inverse() * body_world_pos
	# Clamp distance from the camera to keep the hold pose sane —
	# objects grabbed at extreme angles or right against the camera
	# get pulled to a usable distance.
	var dist: float = capture_local.length()
	if dist < MIN_HOLD_DISTANCE:
		capture_local = capture_local.normalized() * MIN_HOLD_DISTANCE
	elif dist > MAX_HOLD_DISTANCE:
		capture_local = capture_local.normalized() * MAX_HOLD_DISTANCE
	# Edge case: capture position was exactly at the camera origin,
	# normalize gives NaN. Fall back to the canonical pose.
	if not capture_local.is_finite():
		capture_local = FALLBACK_HOLD_OFFSET
	_hold_target_marker.position = capture_local
	# §17.2.2 — cache the immutable capture for wall pushback "ideal".
	_hold_capture_local = capture_local
	# Reset pullback timer in case the previous hold ended at max pullback.
	_pullback_max_time_msec = -1

	# Re-freeze the body. After a previous release the body is in a
	# free-falling state (`freeze = false`); without re-freezing, the
	# direct global_transform writes in `_physics_process` would be
	# overwritten by Jolt's dynamic-body integration each tick.
	rb.freeze = true
	rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	rb.linear_velocity = Vector3.ZERO
	rb.angular_velocity = Vector3.ZERO

	# MF3 mask flip — clear the LAYER_PLAYER bit so the held body
	# doesn't collide with the player capsule. Bit-precise.
	rb.collision_mask = rb.collision_mask & ~CarryableBodyFactoryScript.LAYER_PLAYER

	# §17.2.1 / @third combination 4 — opt the held body OUT of physics
	# interpolation while held, AND keep the interpolated marker read
	# in `_process` (which we already do). MODE_OFF means the renderer
	# reads `body.global_transform` LIVE each frame instead of lerping
	# stale physics-tick snapshots, so our render-rate writes from
	# `_process` apply visually each frame.
	#
	# Per Godot Node.xml: "Disables physics interpolation for this node
	# and for children set to PHYSICS_INTERPOLATION_MODE_INHERIT."
	# Visual mesh children of the RB inherit OFF from parent, no need
	# to walk children. Verified from source 2026-04-08.
	#
	# Reset clears the snapshot pair so the body doesn't smear from
	# its pre-grab world pos to the new hold pose across the air.
	#
	# Earlier confusion: this same flip was tried with a LIVE marker
	# read (`marker.global_position`) which produced 60-Hz-stepped
	# chase target → made vibration worse. With the interpolated
	# marker read shipped earlier, the chase target is smooth, so
	# the body's render-rate writes are smooth too. Together they
	# form the canonical Unreal/Unity "kinematic body driven from
	# Tick with smooth source" pair.
	rb.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	rb.reset_physics_interpolation()

	# I.6 — register the held body with the streaming manager (if wired)
	# so cell unload doesn't free it. Duck-typed call — test scenes
	# without a streaming pipeline run with `_streaming_manager == null`
	# and skip this. The grid is looked up via the streaming manager's
	# ancestor walk; we pass the resulting Vector2i back so the orphan
	# registry knows which cell to re-home this item to on reload.
	if _streaming_manager != null and _streaming_manager.has_method("find_grid_for_node"):
		var origin_grid: Vector2i = _streaming_manager.find_grid_for_node(rb)
		_streaming_manager.register_persistent_node(rb, origin_grid)


## Release the held body. Detects throw vs drop:
## - **Throw** (camera angular velocity OR player linear velocity above
##   threshold): unfreeze + restore mask + apply lever-arm cross product
##   impulse + base camera_forward impulse + small tumble. Spec §6.3.
## - **Drop** (under threshold): unfreeze + restore mask + velocity =
##   player velocity, no impulse. The I.3 path.
##
## Same defer-everything pattern as `try_grab` — the entire state
## transition runs as a single post-physics-tick atomic operation to
## avoid Jolt crashes from in-callback mutation.
func release() -> void:
	if not is_carrying():
		return
	var pickup := _held_pickup
	var rb := _held_body
	var origin_parent := _held_origin_parent
	var saved_mask := _saved_collision_mask
	var player_velocity: Vector3 = Vector3.ZERO
	if player != null:
		player_velocity = player.velocity

	# I.4 throw detection — measure NOW, before clearing state, while
	# the camera basis history is still valid relative to the held body.
	var cam_ang_vel: Vector3 = _measure_camera_angular_velocity()
	var ang_speed: float = cam_ang_vel.length()
	var lin_speed: float = player_velocity.length()
	var is_throw: bool = (ang_speed > THROW_THRESHOLD_ANGULAR_RAD_S or lin_speed > THROW_THRESHOLD_LINEAR_M_S)

	# Capture body world position relative to camera for the lever-arm
	# cross product (rad/s × m → m/s, dimensionally clean — see spec
	# §6.3 fix M3 from reviewer round 1).
	var body_world_pos: Vector3 = rb.global_position
	var camera_world_pos: Vector3 = camera.global_position if camera != null else Vector3.ZERO
	var lever_arm: Vector3 = body_world_pos - camera_world_pos
	var camera_forward: Vector3 = -camera.global_transform.basis.z if camera != null else Vector3.FORWARD

	# Clear state up front so re-entrancy and signal handlers see a
	# clean controller. The deferred body below validates everything
	# from its captured locals.
	released.emit(rb)
	_held_body = null
	_held_pickup = null
	_held_origin_parent = null
	_saved_collision_mask = 0
	_pullback_max_time_msec = -1
	_hold_capture_local = Vector3.ZERO

	if pickup == null or not is_instance_valid(pickup):
		return
	if rb == null or not is_instance_valid(rb):
		return

	_do_release.call_deferred(
		pickup, rb, origin_parent, saved_mask, player_velocity,
		is_throw, cam_ang_vel, lever_arm, camera_forward,
	)


## Deferred release body — runs OUTSIDE the physics callback. Restores
## mask, unfreezes, applies velocity (drop or throw). No reparent —
## the wrapper was never moved out of its origin parent. The body
## picks up from whatever world position the per-frame transform
## writes left it at (typically in front of the camera) and Jolt
## integrates from there.
##
## I.4 unifies throw + drop into the same helper per @reviewer MF5.
## `is_throw` decides whether to apply the lever-arm impulse + tumble.
func _do_release(
	pickup: Interactable,
	rb: RigidBody3D,
	_origin_parent: Node,
	saved_mask: int,
	player_velocity: Vector3,
	is_throw: bool,
	cam_ang_vel: Vector3,
	lever_arm: Vector3,
	camera_forward: Vector3,
) -> void:
	if not is_instance_valid(pickup) or not is_instance_valid(rb):
		return

	# MF3 mask restore — exact snapshot value. §6.5: restore BEFORE
	# unfreezing so the body never spends a tick in (held mask, free)
	# state.
	rb.collision_mask = saved_mask

	# §17.2.1 — restore physics interpolation now that Jolt is going to
	# integrate the body again, and reset so the body doesn't smear
	# from its hold pose into its physics-driven trajectory.
	rb.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_INHERIT
	rb.reset_physics_interpolation()

	# I.6 — unregister from streaming persistent set. The body is no
	# longer protected from cell unload; if it's currently in a cell
	# that gets unloaded, it'll be freed normally. (Future: Phase 2
	# re-home logic could detect dropped items and orphan-register them
	# until their cell unloads.)
	if _streaming_manager != null and _streaming_manager.has_method("unregister_persistent_node"):
		_streaming_manager.unregister_persistent_node(rb)

	# Unfreeze and apply velocity. Throw and drop differ only in the
	# velocity computation; the rest of the state transition is shared.
	rb.freeze = false

	if is_throw:
		# §6.3 throw composition:
		#   linear_velocity = player_velocity
		#                   + camera_forward * THROW_IMPULSE_LINEAR
		#                   + camera_angular_velocity.cross(lever_arm)
		# Cross product is dimensionally clean (rad/s × m → m/s) per
		# the M3 fix in reviewer round 1. Lever arm = body world pos
		# minus camera world pos.
		var throw_v: Vector3 = player_velocity
		throw_v += camera_forward * THROW_IMPULSE_LINEAR
		throw_v += cam_ang_vel.cross(lever_arm)
		rb.linear_velocity = throw_v
		# Small angular velocity perpendicular to motion for natural tumble.
		var motion_dir: Vector3 = throw_v
		if motion_dir.length_squared() > 0.0001:
			motion_dir = motion_dir.normalized()
			# Pick a vector roughly perpendicular to motion via cross
			# with world up; if motion is near-vertical, fall back to
			# cross with world right.
			var perp: Vector3 = motion_dir.cross(Vector3.UP)
			if perp.length_squared() < 0.001:
				perp = motion_dir.cross(Vector3.RIGHT)
			perp = perp.normalized()
			rb.angular_velocity = perp * THROW_IMPULSE_ANGULAR_TUMBLE
		else:
			rb.angular_velocity = Vector3.ZERO
	else:
		# Drop path (I.3): velocity = player velocity, no impulse.
		rb.linear_velocity = player_velocity
		rb.angular_velocity = Vector3.ZERO


# --- Hold spring (per-frame lerp + roll lock, MF6)
#
# Direct global_transform writes to the held RigidBody3D each render
# frame. This is the canonical Godot/Jolt way to drive a frozen
# kinematic body — parent-chain transform inheritance does NOT
# propagate to a physics body's server-side transform, so reparenting
# under a moving anchor would invisibly leave the body stuck. See
# @reviewer id=4041.
#
# Lerp runs from `_process`, NOT `_physics_process`, so the chase is
# at render rate (120/144 Hz on most setups) instead of fixed 60 Hz.
# Without this the held object visibly stutters at high refresh — the
# camera updates per-render-frame but a `_physics_process`-driven
# transform write only updates 60 times/sec, creating relative jitter.
# Delta-aware exponential lerp keeps the apparent stiffness constant
# regardless of framerate.
#
# Per `INTERACTION_SYSTEM.md` §6.2 deferred-mutation rule: that rule
# scopes RB state mutation (freeze, mask, velocity, transform writes
# DURING TRANSITIONS) to deferred helpers. Steady-state per-frame
# kinematic transform writes are the documented Godot pattern and are
# safe from any Godot frame callback because the body is frozen — Jolt
# is not integrating it; we own its transform completely.

## Physics-tick handler — feeds the I.4 throw ring buffer with camera
## basis samples. The marker world position is NOT snapshotted here
## anymore — `_process` reads `marker.global_position` directly because
## the engine handles physics interpolation project-wide and the camera
## is carved out (mouse rotation stays render-rate fresh).
func _physics_process(_delta: float) -> void:
	# I.4 — sample camera basis into the ring buffer regardless of
	# whether we're currently holding (cheap, ~10 entries kept), so the
	# 50 ms window is already populated when a grab happens.
	if camera != null:
		_sample_camera_basis()


## I.4 ring buffer push — appends current camera basis with the wall
## clock time, drops anything older than `THROW_SAMPLE_WINDOW_MS`.
func _sample_camera_basis() -> void:
	var now: int = Time.get_ticks_msec()
	_camera_basis_history.append(CameraSample.new(now, camera.global_basis))
	# Drop stale samples — older than the window. Walk from the front
	# (oldest first) and pop until the head is within the window. The
	# CLAUDE.md anti-pattern says no `pop_front` because it's O(n);
	# the buffer is bounded to ~10 entries (60Hz * 0.05s + a couple),
	# so using `pop_front` here is microscopic. Documented exception.
	var cutoff: int = now - THROW_SAMPLE_WINDOW_MS
	while _camera_basis_history.size() > 0 and _camera_basis_history[0].time_msec < cutoff:
		_camera_basis_history.pop_front()


## I.4 wall pushback — raycast camera → hold pose. If occluded, pull
## marker back along camera forward to keep clear. Sustained pullback
## at max for `HOLD_PULLBACK_TIMEOUT` triggers force-drop.
##
## Read-only against the physics server (intersect_ray query) + writes
## ONLY to the marker's local position (Marker3D is a Node3D, not an
## RB — safe to mutate from `_process` per MF4). Force-drop fires
## `release()`, which goes through `_do_release.call_deferred(...)`,
## so no RB mutation happens inline.
func _apply_wall_pushback() -> void:
	if camera == null or _hold_target_marker == null or _held_body == null:
		return
	# §17.2.2 fix — read the IMMUTABLE capture from grab time, not the
	# marker's current local position. The marker has already been
	# mutated by prior pushback frames; using it as ideal causes the
	# restore to no-op when the wall clears (the "ideal" already drifted
	# inward to match the wall, so there's nothing to restore back to).
	var ideal_local: Vector3 = _hold_capture_local
	var ideal_dist: float = ideal_local.length()
	if ideal_dist < 0.001:
		return
	var ideal_dir: Vector3 = ideal_local / ideal_dist  # camera-local

	# Cast from camera origin along the ideal direction (in world space)
	# out to the ideal distance.
	var space_state := camera.get_world_3d().direct_space_state
	var from_world: Vector3 = camera.global_position
	var ideal_world_offset: Vector3 = camera.global_transform.basis * ideal_local
	var to_world: Vector3 = from_world + ideal_world_offset

	var query := PhysicsRayQueryParameters3D.create(from_world, to_world)
	# Hit only environment layer 1; skip the held body (Interactable
	# layer 3) and the player (layer 2).
	query.collision_mask = CarryableBodyFactoryScript.LAYER_ENVIRONMENT
	query.exclude = [_held_body.get_rid()]

	var hit := space_state.intersect_ray(query)
	var pullback: float = 0.0
	if not hit.is_empty():
		var hit_pos: Vector3 = hit.get("position", to_world)
		var hit_dist: float = from_world.distance_to(hit_pos)
		# Pull the marker back so the body sits just inside the hit point.
		var clearance: float = 0.1  # tiny gap so the body isn't intersecting
		var clear_dist: float = maxf(hit_dist - clearance, 0.0)
		pullback = ideal_dist - clear_dist
		if pullback > 0.0:
			# Move the marker LOCAL position toward the camera by pullback.
			_hold_target_marker.position = ideal_dir * clear_dist
		else:
			pullback = 0.0
			_hold_target_marker.position = ideal_local

	# Force-drop on sustained max pullback. Track time-at-max in msec.
	var now: int = Time.get_ticks_msec()
	if pullback >= HOLD_PULLBACK_MAX:
		if _pullback_max_time_msec < 0:
			_pullback_max_time_msec = now
		elif now - _pullback_max_time_msec >= int(HOLD_PULLBACK_TIMEOUT * 1000.0):
			# Force-drop. release() goes through deferred helper — no
			# inline RB mutation from _process.
			release()
			_pullback_max_time_msec = -1
	else:
		_pullback_max_time_msec = -1


## I.4 throw — compute the camera angular velocity vector from the
## ring buffer. Uses the oldest and newest samples in the window to get
## a basis delta, converts to axis-angle / dt for an angular velocity.
## Returns Vector3.ZERO if not enough samples.
func _measure_camera_angular_velocity() -> Vector3:
	if _camera_basis_history.size() < 2:
		return Vector3.ZERO
	var oldest: CameraSample = _camera_basis_history[0]
	var newest: CameraSample = _camera_basis_history[_camera_basis_history.size() - 1]
	var dt_msec: int = newest.time_msec - oldest.time_msec
	if dt_msec <= 0:
		return Vector3.ZERO
	var dt: float = float(dt_msec) / 1000.0
	# Relative basis: newest = delta * oldest, so delta = newest * oldest^-1.
	# Then convert delta to axis-angle and scale by 1/dt.
	var delta_basis: Basis = newest.basis * oldest.basis.inverse()
	var quat: Quaternion = delta_basis.get_rotation_quaternion()
	# Convert quaternion to angle * axis. Quaternion = (sin(θ/2) * axis, cos(θ/2)).
	var angle: float = 2.0 * acos(clampf(quat.w, -1.0, 1.0))
	if angle < 0.0001:
		return Vector3.ZERO
	var sin_half: float = sqrt(1.0 - quat.w * quat.w)
	if sin_half < 0.0001:
		return Vector3.ZERO
	var axis: Vector3 = Vector3(quat.x, quat.y, quat.z) / sin_half
	return axis * (angle / dt)


func _process(delta: float) -> void:
	if not is_carrying() or _hold_target_marker == null or camera == null:
		return
	if not is_instance_valid(_held_body):
		# External code freed the held body — clear state and bail.
		_held_body = null
		_held_pickup = null
		_held_origin_parent = null
		_saved_collision_mask = 0
		return

	# I.4 wall pushback. Read-only raycast from camera to hold pose;
	# if the hold pose is occluded, pull the marker back along the
	# camera forward axis to keep clear. Sustained max pullback for
	# `HOLD_PULLBACK_TIMEOUT` triggers a force-drop via the standard
	# deferred release path (MF4 — no inline RB mutation from `_process`).
	_apply_wall_pushback()

	# Framerate-independent exponential lerp factor.
	#   `1 - exp(-rate * dt)` → 0 at dt=0, → 1 as dt→∞.
	# At HOLD_LERP_RATE=15 and 60 fps (dt≈0.0167), this gives ~22% per
	# frame — nearly identical perceived stiffness to the old fixed 0.25.
	# At 144 fps (dt≈0.007), it gives ~10% per frame, which is the
	# correct smaller step for the higher refresh rate.
	var pos_t: float = 1.0 - exp(-HOLD_LERP_RATE * delta)
	var rot_t: float = 1.0 - exp(-HOLD_ROT_LERP_RATE * delta)

	# §17.2.1 / @roaster Option C — manual chain composition.
	#
	# Why this is needed: setting `camera_pivot.physics_interpolation_mode
	# = OFF` recursively cascades to all descendants (verified Godot doc:
	# "If you turn off interpolation for a Node, the children will
	# recursively also be affected"). So spring_arm, camera, and
	# `_hold_target_marker` are ALL effectively OFF.
	#
	# Calling `marker.get_global_transform_interpolated()` on an OFF
	# subtree node is a NO-OP — the node has no prev/current snapshot
	# pair, so the API returns the live `global_transform`. That's why
	# combinations 1-4 didn't kill the residual: the marker chase
	# target was always the LIVE composition with stepped player position.
	#
	# Real fix: assemble the target manually from
	#   interp(player_xf) × live(camera_pivot.local) × live(spring_arm.local)
	#                    × live(camera.local) × live(marker.local)
	# This composes the engine-smoothed player capsule (renders at 144 Hz
	# via interpolation) with the live render-rate camera rig offset
	# (mouse rotation, spring_arm collision shortening, marker offset).
	# Both axes clean: position smooth, rotation render-rate fresh.
	#
	# Body keeps `MODE_OFF` (set in `_do_grab`) so our render-rate writes
	# apply directly without engine smoothing on top.
	var player_xf_interp: Transform3D = player.get_global_transform_interpolated() if player != null else Transform3D.IDENTITY
	# Walk the rig chain — camera is set in setup; walk up to find pivot/arm.
	var spring_arm: Node3D = camera.get_parent() as Node3D if camera != null else null
	var camera_pivot: Node3D = spring_arm.get_parent() as Node3D if spring_arm != null else null
	var rig_offset_in_player: Transform3D = Transform3D.IDENTITY
	if camera_pivot != null and spring_arm != null and camera != null and _hold_target_marker != null:
		rig_offset_in_player = (
			camera_pivot.transform
			* spring_arm.transform
			* camera.transform
			* _hold_target_marker.transform
		)
	var target_xf: Transform3D = player_xf_interp * rig_offset_in_player
	var target_world_pos: Vector3 = target_xf.origin

	var current_world_pos: Vector3 = _held_body.global_position
	var new_world_pos: Vector3 = current_world_pos.lerp(target_world_pos, pos_t)
	# MF5 NaN/inf guard.
	if not new_world_pos.is_finite():
		push_warning("CarryController: hold spring produced non-finite position, snapping to target")
		new_world_pos = target_world_pos

	# MF6 roll lock: target basis = camera yaw + pitch only, roll dropped.
	# Use the basis from the SAME composed chain so the rotation tracks
	# the renderer's actual camera transform, not a stale tick read.
	var cam_euler: Vector3 = target_xf.basis.get_euler()
	var target_basis: Basis = Basis.from_euler(Vector3(cam_euler.x, cam_euler.y, 0.0))
	var current_basis: Basis = _held_body.global_basis
	var new_basis: Basis = current_basis.slerp(target_basis, rot_t)
	# MF5 NaN/inf guard on the rotation path.
	if not new_basis.is_finite():
		push_warning("CarryController: hold spring produced non-finite basis, snapping to target")
		new_basis = target_basis

	# Direct global_transform write. Frozen kinematic body — this is
	# the canonical update path. Visual mesh children of the body
	# inherit via standard scene-tree propagation (MF4 mesh-follow
	# restructure already moved the meshes under the RigidBody3D).
	_held_body.global_transform = Transform3D(new_basis, new_world_pos)


## I.7 / §17.3 — sig 11 shutdown crash fix.
##
## Throughout I.3 + I.4 development the test scene exit consistently
## crashed with `signal 11 / no GDScript backtrace` when the user closed
## the window while holding an item. Crash always happened AFTER successful
## gameplay — Jolt body cleanup ordering when the scene tree tears down
## with a frozen kinematic body under direct-transform-write control.
##
## Fix: when the scene tree tears down, explicitly release any held body
## (restore it to a sane Jolt state — unfrozen, default mask, INHERIT
## interpolation) and null out our marker reference BEFORE the tree
## continues unwinding. This gives Jolt a clean window to release the
## body's RID without our `_process` writes still hammering its transform.
func _exit_tree() -> void:
	if _held_body != null and is_instance_valid(_held_body):
		# Restore Jolt-canonical state before scene teardown frees the
		# body. We can't use the deferred helper path here because the
		# tree is in the middle of unwinding — defer would queue work
		# that runs after this node is gone. Inline mutation is safe
		# in `_exit_tree` because Jolt has stopped integrating the body
		# (project shutdown) and no other system can reference it.
		_held_body.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_INHERIT
		_held_body.freeze = false
		_held_body.linear_velocity = Vector3.ZERO
		_held_body.angular_velocity = Vector3.ZERO
		_held_body.collision_mask = _saved_collision_mask
		# Drop our reference so `_process` (if it somehow fires once
		# more during teardown) bails out via the is_carrying() guard.
		_held_body = null
		_held_pickup = null
	_hold_target_marker = null
