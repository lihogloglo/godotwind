## Player Controller - 3rd-person character controller with SpringArm3D camera
##
## CharacterBody3D-based player controller with:
## - SpringArm3D orbit camera with collision avoidance
## - First/third-person camera toggle with smooth transition
## - Move-as-Node state machine for movement + combat (via CharacterMotor)
## - Character model + animation system integration
## - Freeze/unfreeze for dialogue, cutscenes
## - IK wiring (foot, look-at, hand) via CharacterAnimationSystem
class_name PlayerController
extends CharacterBody3D

const GameplayPhysicsLayersScript := preload("res://src/core/physics/gameplay_physics_layers.gd")
const InteractionIntentScript := preload("res://src/core/interaction/interaction_intent.gd")

const _DefaultMovementConfig := preload("res://src/core/character/controller/movement_presets/default_movement_config.tres")
const _CharacterMotor := preload("res://src/core/character/character_motor.gd")

#region Signals

## Emitted when player lands on ground
signal landed

## Emitted when player enters water (future)
signal entered_water

## Emitted when player exits water (future)
signal exited_water

## Emitted when camera mode changes
signal camera_mode_changed(mode: int)

# --- Interaction (I.0) -------------------------------------------------------
# In PlayerGameplayContext, `PlayerController` owns the raw `interact` action.
# FlyCameraContext owns the same action while fly mode is active. Both contexts
# feed the shared InteractionIntent helper so tap/hold/release semantics stay
# identical. See docs/systems/interaction_system.md §3.1 for the contract.

## Quick press + release inside HOLD_THRESHOLD. Default verb on the
## current Interactable target (Talk / Read / Take / Open / Activate).
signal interact_tap()

## Press held longer than HOLD_THRESHOLD. Carry start (I.3+).
signal interact_hold_begin()

## Release after `interact_hold_begin` already fired. Drop or throw (I.4).
signal interact_release()

#endregion


#region Enums

enum CameraMode {
	FIRST_PERSON,
	THIRD_PERSON,
}

#endregion


#region Export Variables

@export_group("Movement")
@export var movement_config: CharacterMovementConfig = _DefaultMovementConfig
## Normal run speed in meters per second
@export_range(0.1, 20.0, 0.1) var run_speed: float = 5.0
## Walking speed (when walk key held)
@export_range(0.1, 10.0, 0.1) var walk_speed: float = 2.5
## Sprint speed (when sprint key held)
@export_range(0.1, 30.0, 0.1) var sprint_speed: float = 8.0
## Vertical velocity applied when jumping
@export_range(1.0, 20.0, 0.1) var jump_velocity: float = 4.5
## Whether the walk key is enabled
@export var can_walk: bool = true

@export_group("Camera")
## Mouse sensitivity for camera rotation
@export_range(0.0, 1.0, 0.001) var mouse_sensitivity: float = 0.005
## Enable controller stick support for camera look
@export var controller_support: bool = true
## Controller stick sensitivity for camera rotation
@export_range(0.1, 10.0, 0.1) var controller_sensitivity: float = 2.0
## Maximum vertical camera tilt angle in degrees
@export_range(0.0, 89.0, 1.0) var tilt_limit_degrees: float = 75.0
## Speed at which the character mesh rotates to face movement direction
@export_range(0.1, 50.0, 0.1) var rotation_speed: float = 10.0
## Camera mode: FIRST_PERSON or THIRD_PERSON
@export var camera_mode: CameraMode = CameraMode.THIRD_PERSON:
	set(value):
		camera_mode = value
		if is_node_ready():
			_update_camera_mode()
## Camera distance (SpringArm length) for third-person mode
@export_range(0.0, 10.0, 0.1) var camera_distance: float = 3.5
## Speed of smooth camera transitions between modes
@export_range(1.0, 20.0, 0.1) var camera_transition_speed: float = 8.0
## Allow switching between camera modes
@export var allow_camera_mode_switch: bool = true

@export_group("Collision")
## Player capsule height
@export var player_height: float = 1.8
## Player capsule radius
@export var player_radius: float = 0.35

@export_group("Root Motion")
## Use root motion to drive movement (animation drives position)
@export var use_root_motion: bool = false
## Base rotation offset for character facing direction (radians)
@export var character_facing_offset: float = 0.0

#endregion


#region Node References

## Camera pivot node (rotates with mouse)
var camera_pivot: Node3D

## SpringArm3D for collision avoidance
var spring_arm: SpringArm3D

## The actual camera
var camera: Camera3D

## Collision shape
var collision_shape: CollisionShape3D

## Character model root (set via attach_character)
var character_root: Node3D

## Animation system (set via attach_character)
var animation_system: Node

## Movement motor owned by the player/character stack
var movement_motor: CharacterMotor = null

## Input gatherer (creates InputPackage each frame for MoveContainer)
var _input_gatherer: Node = null  # PlayerInputGatherer, owned by CharacterMotor

#endregion


#region Public State

## Whether player controls are active
var enabled: bool = false

## Movement input direction (exposed for animation driver)
var input_direction: Vector2 = Vector2.ZERO

## Input magnitude (0-1, for analog stick support)
var input_strength: float = 0.0

## Camera-relative movement direction in world space
var direction: Vector3 = Vector3.ZERO

## Whether player is sprinting
var is_sprinting: bool = false

## Whether player is walking (slow)
var is_walking: bool = false

## Whether player is crouching
var is_crouching: bool = false

## Whether player is in the jump-family airborne state (`jump` or `midair`).
## Kept as a compatibility alias; prefer `is_jump_move` or `is_airborne`.
var is_jumping: bool = false

## Whether player is in the actual launch move, before normal midair/fall state.
var is_jump_move: bool = false

## Whether player is in either launch or falling midair movement.
var is_airborne: bool = false

## Whether player is swimming
var is_swimming: bool = false

## Current posture from MovementState
var current_posture: StringName = &"standing"

## Freeze all movement (for dialogue, cutscenes)
var frozen: bool = false

## Whether player is in water (future)
var in_water: bool = false

## Compatibility with CharacterMovementController (factory sets this)
var wander_enabled: bool = false

## Current camera mode
## (use set_camera_mode() or camera_mode export setter)

#endregion


#region Private State

## Target SpringArm distance for smooth transitions
var _target_camera_distance: float = 3.5

## Was on floor last frame (for landing detection)
var _was_on_floor: bool = false

## Tilt limit in radians (computed from degrees)
var _tilt_limit_rad: float = deg_to_rad(75.0)

## Water surface height at player position
var _water_surface_y: float = -INF

## Whether player is inside a static water volume (Area3D)
var _in_water_volume: bool = false

## Surface Y of the current static water volume
var _water_volume_surface_y: float = -INF

# --- Interaction (I.0) -------------------------------------------------------

## Threshold (seconds) above which a press becomes "hold" instead of "tap".
const HOLD_THRESHOLD: float = InteractionIntentScript.DEFAULT_HOLD_THRESHOLD

## Modal UI gate registry. Each entry must implement `is_open() -> bool`.
## While ANY registered gate is open, interact_* signals are suppressed.
var _modal_gates: Array[Node] = []

var _interaction_intent: InteractionIntent = InteractionIntentScript.new(HOLD_THRESHOLD) as InteractionIntent

## Optional reference to the InteractionRaycaster owned by this player.
## Set via `set_interaction_raycaster()` after the raycaster is parented.
## When set, `PlayerController` automatically routes interact_tap to the
## raycaster's current target. Tests/scenes that don't use the raycaster
## can leave this null and connect to the signals directly.
var _interaction_raycaster: Node = null

## Optional reference to the CarryController owned by this player (I.3).
## Set via `set_carry_controller()` after the controller is parented and
## `setup(camera, player)` has been called. When set, `PlayerController`
## automatically routes `interact_hold_begin` → `try_grab(target)` and
## `interact_release` → `release()`. Held-body state lives entirely in
## CarryController per `docs/systems/interaction_system.md`.
var _carry_controller: CarryController = null

## Tracks the previous frame's modal gate state so we can edge-detect
## open→closed and re-capture the mouse automatically. Without this the
## cursor stays visible after closing a dialogue/book and the user has
## to left-click to re-capture for camera-look.
var _was_modal_open: bool = false

#endregion


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	_sync_legacy_exports_from_movement_config()
	_ensure_input_actions()
	_setup_collision()
	_setup_camera()

	_tilt_limit_rad = deg_to_rad(tilt_limit_degrees)
	_target_camera_distance = 0.0 if camera_mode == CameraMode.FIRST_PERSON else camera_distance
	spring_arm.spring_length = _target_camera_distance

	set_physics_process(true)
	set_process_input(true)


func _physics_process(delta: float) -> void:
	if not enabled:
		return

	# Interact hold polling — input events fire on press/release only,
	# so "held past threshold" detection requires per-frame polling.
	# See docs/systems/interaction_system.md §3.1.
	_poll_interact_hold()

	# Modal gate edge detection — re-capture the mouse on the open→closed
	# falling edge so the player goes straight back to camera-look without
	# needing a left-click. Symmetric VISIBLE on the rising edge so panels
	# don't have to set mouse mode themselves (C.2.5 cleanup target).
	_poll_modal_mouse_mode()

	# Camera (always updated regardless of movement mode)
	_handle_camera_transition(delta)
	_handle_controller_camera(delta)

	if frozen:
		_handle_frozen_movement()
		move_and_slide()
		return

	# Water detection (ocean height check each frame)
	_update_water_state()

	# CharacterMotor owns input gathering and movement. Animation observes the
	# resulting MovementState, so movement keeps working without animation.
	if movement_motor:
		var state: MovementState = movement_motor.process(delta, in_water, _water_surface_y)
		_apply_movement_state(state)
		if animation_system and animation_system.has_method("update_from_movement_state"):
			animation_system.update_from_movement_state(state)

	# Landing detection
	if is_on_floor() and not _was_on_floor:
		landed.emit()
	_was_on_floor = is_on_floor()

	# Update look-at IK target
	if camera_mode == CameraMode.THIRD_PERSON:
		_update_look_target()


# =============================================================================
# INPUT
# =============================================================================

func _unhandled_input(event: InputEvent) -> void:
	if not enabled or frozen:
		return

	# Modal UI gate — if any registered modal UI is open, do NOT consume
	# the interact event. Let it propagate to the panel's own
	# `_unhandled_input` so panels can handle E-to-close themselves.
	# See docs/systems/interaction_system.md §3.1 + reviewer M1 (id=3945).
	# The internal checks in `_on_interact_pressed` / `_on_interact_released`
	# are kept as belt-and-braces for the rare race where a modal opens
	# between this entry point and the inner dispatch.
	if is_modal_ui_open():
		return

	# Interact action — owned by PlayerGameplayContext while this controller
	# is active. FlyCameraContext owns the same action in fly mode.
	# See docs/systems/interaction_system.md §3.1.
	if InputMap.has_action("interact"):
		if event.is_action_pressed("interact"):
			_on_interact_pressed()
			get_viewport().set_input_as_handled()
			return
		if event.is_action_released("interact"):
			_on_interact_released()
			get_viewport().set_input_as_handled()
			return

	# ESC releases mouse
	if event is InputEventKey and event.physical_keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Click captures mouse
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Mouse look
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera_pivot.rotation.x -= event.relative.y * mouse_sensitivity
		camera_pivot.rotation.x = clampf(camera_pivot.rotation.x, -_tilt_limit_rad, _tilt_limit_rad)
		camera_pivot.rotation.y -= event.relative.x * mouse_sensitivity


func _input(event: InputEvent) -> void:
	if not enabled:
		return

	# Camera mode toggle
	if allow_camera_mode_switch and event.is_action_pressed("toggle_camera"):
		if character_root:
			if camera_mode == CameraMode.FIRST_PERSON:
				set_camera_mode(CameraMode.THIRD_PERSON)
			else:
				set_camera_mode(CameraMode.FIRST_PERSON)


# =============================================================================
# SETUP
# =============================================================================

func _setup_collision() -> void:
	collision_shape = CollisionShape3D.new()
	collision_shape.name = "CollisionShape"
	var capsule := CapsuleShape3D.new()
	var config := get_movement_config()
	capsule.radius = config.player_radius
	capsule.height = config.standing_height
	collision_shape.shape = capsule
	collision_shape.position.y = config.standing_height / 2.0
	add_child(collision_shape)
	# Morrowind terrain can be steep — allow ~50° slopes before sliding
	floor_max_angle = config.get_max_floor_angle_radians()
	# Snap to ground — handles stair steps naturally via Godot's built-in floor snap.
	# Custom step-up in MoveContainer handles larger obstacles (0.3-0.5m).
	floor_snap_length = config.floor_snap_length
	# Allow pushing RigidBody3D objects (barrels, crates, etc.)
	collision_layer = GameplayPhysicsLayersScript.PLAYER
	collision_mask = GameplayPhysicsLayersScript.ENVIRONMENT | GameplayPhysicsLayersScript.PLAYER


func _setup_camera() -> void:
	camera_pivot = Node3D.new()
	camera_pivot.name = "CameraPivot"
	camera_pivot.position.y = get_movement_config().standing_eye_height
	# Vibration spike (§17.2.1 / @roaster verdict): with project-wide
	# `physics/common/physics_interpolation = true`, the camera_pivot
	# must be carved out so mouse rotation in `_unhandled_input` stays
	# render-rate-fresh. Per Godot 4.4+ advanced physics interpolation
	# docs: "If you use the traditional get_global_transform() on a
	# Camera3D target node, it can be better to disable physics
	# interpolation for the camera node and directly apply the mouse
	# input to the camera rotation, rather than apply it in
	# _physics_process." That's exactly our setup.
	camera_pivot.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(camera_pivot)

	spring_arm = SpringArm3D.new()
	spring_arm.name = "SpringArm3D"
	spring_arm.spring_length = camera_distance
	spring_arm.collision_mask = 1  # World collision layer
	spring_arm.margin = 0.2
	camera_pivot.add_child(spring_arm)

	camera = Camera3D.new()
	camera.name = "PlayerCamera"
	camera.far = 2000.0
	camera.current = false
	spring_arm.add_child(camera)


## Create and wire up the PlayerInputGatherer
func _setup_input_gatherer() -> void:
	_setup_movement_motor()
	_input_gatherer = movement_motor.input_gatherer if movement_motor else null


func _setup_movement_motor() -> void:
	if not movement_motor:
		movement_motor = _CharacterMotor.new() as CharacterMotor
		movement_motor.name = "CharacterMotor"
		add_child(movement_motor)
	movement_motor.setup(self, character_root, get_movement_config(), camera_pivot,
		_find_skeleton(character_root) if character_root else null)
	_input_gatherer = movement_motor.input_gatherer


## Register required input actions if they don't exist
func _ensure_input_actions() -> void:
	var actions: Dictionary = {
		"move_forward": [KEY_W],
		"move_backward": [KEY_S],
		"move_left": [KEY_A],
		"move_right": [KEY_D],
		"sprint": [KEY_SHIFT],
		"walk": [],
		"jump": [KEY_SPACE],
		"crouch": [KEY_C, KEY_CTRL],
		"toggle_camera": [KEY_TAB],
		"interact": [KEY_E],
	}
	for action_name: String in actions:
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)
			var keys: Array = actions[action_name]
			for physical_keycode: int in keys:
				var key_event := InputEventKey.new()
				key_event.physical_keycode = physical_keycode
				InputMap.action_add_event(action_name, key_event)


# =============================================================================
# PUBLIC API
# =============================================================================

## Attach a character model and animation system to this controller.
## character: Node3D root from any character factory (MW or Humanoid).
## anim_sys: CharacterAnimationSystem (or subclass) for animation state updates.
func attach_character(character: Node3D, anim_sys: Node = null) -> void:
	character_root = character

	# Add character root as child if not already parented
	if character_root.get_parent() != self:
		if character_root.get_parent():
			character_root.get_parent().remove_child(character_root)
		add_child(character_root)

	animation_system = anim_sys
	if animation_system and animation_system.has_method("set_movement_config"):
		animation_system.set_movement_config(get_movement_config())

	# Wire IK controller to use this CharacterBody3D for raycasts
	if anim_sys and anim_sys.has_method("set_character_body"):
		anim_sys.set_character_body(self)

	# Create movement motor (owns input gathering, MoveContainer, MovementState)
	_setup_input_gatherer()

	# Default to third person when character is attached
	set_camera_mode(CameraMode.THIRD_PERSON)


func get_movement_config() -> CharacterMovementConfig:
	return movement_config if movement_config else _DefaultMovementConfig


func get_movement_motor() -> CharacterMotor:
	return movement_motor


func get_movement_state() -> MovementState:
	if movement_motor:
		return movement_motor.get_movement_state()
	return null


func _sync_legacy_exports_from_movement_config() -> void:
	var config := get_movement_config()
	walk_speed = config.walk_speed
	run_speed = config.run_speed
	sprint_speed = config.sprint_speed
	jump_velocity = config.jump_velocity
	can_walk = config.can_walk
	player_height = config.standing_height
	player_radius = config.player_radius


func _apply_movement_state(state: MovementState) -> void:
	if not state:
		return
	input_direction = state.input_direction
	input_strength = state.input_strength
	direction = state.desired_world_direction
	is_sprinting = state.is_sprinting
	is_walking = state.is_walking
	is_crouching = state.is_crouching
	is_jumping = state.is_jumping
	is_jump_move = state.is_jump_move
	is_airborne = state.is_airborne
	is_swimming = state.is_swimming
	current_posture = state.posture
	_apply_camera_posture(state.posture)


func _apply_camera_posture(posture: StringName) -> void:
	if not camera_pivot:
		return
	camera_pivot.position.y = _get_eye_height_for_posture(posture)


func _get_eye_height_for_posture(posture: StringName) -> float:
	var config := get_movement_config()
	if posture == &"crouching":
		return config.crouch_eye_height
	return config.standing_eye_height


func _reset_public_movement_state() -> void:
	input_direction = Vector2.ZERO
	input_strength = 0.0
	direction = Vector3.ZERO
	is_sprinting = false
	is_walking = false
	is_jumping = false
	is_jump_move = false
	is_airborne = false


## Set camera mode (first or third person)
func set_camera_mode(mode: CameraMode) -> void:
	camera_mode = mode
	_update_camera_mode()
	camera_mode_changed.emit(mode)


## Toggle between first and third person
func toggle_camera_mode() -> void:
	if camera_mode == CameraMode.FIRST_PERSON:
		set_camera_mode(CameraMode.THIRD_PERSON)
	else:
		set_camera_mode(CameraMode.FIRST_PERSON)


## Enable the player controller and capture mouse
func enable() -> void:
	enabled = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if camera:
		camera.current = true


## Disable the player controller and release mouse
func disable() -> void:
	enabled = false
	cancel_interaction_intent()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if camera:
		camera.current = false
	velocity = Vector3.ZERO
	_reset_public_movement_state()


## Freeze character (pause movement, e.g. for dialogue)
func freeze() -> void:
	frozen = true
	velocity = Vector3.ZERO
	_reset_public_movement_state()


## Unfreeze character
func unfreeze() -> void:
	frozen = false


## Teleport player to a position
func teleport_to(pos: Vector3) -> void:
	global_position = pos
	reset_physics_interpolation()
	velocity = Vector3.ZERO


## Get the camera's global position (useful for streaming systems)
func get_camera_position() -> Vector3:
	if camera:
		return camera.global_position
	return global_position + Vector3(0, 1.5, 0)


## Get the camera node
func get_camera() -> Camera3D:
	return camera


## Enable/disable root motion
func set_root_motion(p_enabled: bool) -> void:
	use_root_motion = p_enabled


# =============================================================================
# INTERACTION (I.0 — see docs/systems/interaction_system.md §3.1)
# =============================================================================

## Register a modal UI as an input gate. While ANY registered gate's
## `is_open()` returns true, PlayerController suppresses interact_*
## signal emission. Gate must implement `is_open() -> bool`.
## Idempotent — re-registering an existing gate is a no-op.
func register_modal_gate(gate: Node) -> void:
	if gate == null:
		push_warning("PlayerController.register_modal_gate: null gate")
		return
	if gate in _modal_gates:
		return
	assert(gate.has_method("is_open"),
			"modal gate '%s' must implement is_open() -> bool" % gate.name)
	_modal_gates.append(gate)
	# Auto-clean if the gate is freed without explicit unregister.
	if not gate.tree_exiting.is_connected(_on_gate_tree_exiting):
		gate.tree_exiting.connect(_on_gate_tree_exiting.bind(gate), CONNECT_ONE_SHOT)


## Unregister a previously registered modal gate. Idempotent.
func unregister_modal_gate(gate: Node) -> void:
	_modal_gates.erase(gate)


## Returns true if any registered modal gate is currently open.
## Used internally to gate interact_* signal emission. Public so external
## systems (raycaster, FlyCamera) can also consult it during the C.2.5
## transition; once C.2.5 lands, only PlayerController itself reads this.
func is_modal_ui_open() -> bool:
	for gate in _modal_gates:
		if not is_instance_valid(gate):
			continue  # Self-heal: stale entry from a freed gate
		if gate.is_open():
			return true
	return false


## Number of currently registered modal gates. For tests + diagnostics.
func get_modal_gate_count() -> int:
	return _modal_gates.size()


## Attach an InteractionRaycaster so PlayerController can route the
## interact_tap default verb to whatever the raycaster is currently
## targeting. Without this attachment, consumers must connect to the
## interact_* signals themselves and read the target via their own means.
func set_interaction_raycaster(raycaster: Node) -> void:
	_interaction_raycaster = raycaster
	_update_prompt_suppression_for_carry()


## Returns the attached InteractionRaycaster, or null.
func get_interaction_raycaster() -> Node:
	return _interaction_raycaster


## Attach a CarryController (I.3). When set, PlayerController routes
## `interact_hold_begin` → `try_grab(raycaster.get_current_target())` and
## `interact_release` → `release()`. The controller must be parented and
## `setup(camera, player)` already called.
func set_carry_controller(cc: CarryController) -> void:
	if _carry_controller != null and is_instance_valid(_carry_controller):
		if _carry_controller.grabbed.is_connected(_on_carry_grabbed):
			_carry_controller.grabbed.disconnect(_on_carry_grabbed)
		if _carry_controller.released.is_connected(_on_carry_released):
			_carry_controller.released.disconnect(_on_carry_released)
	_carry_controller = cc
	if _carry_controller != null:
		if not _carry_controller.grabbed.is_connected(_on_carry_grabbed):
			_carry_controller.grabbed.connect(_on_carry_grabbed)
		if not _carry_controller.released.is_connected(_on_carry_released):
			_carry_controller.released.connect(_on_carry_released)
	_update_prompt_suppression_for_carry()


## Returns the attached CarryController, or null.
func get_carry_controller() -> CarryController:
	return _carry_controller


func _on_carry_grabbed(_body: RigidBody3D) -> void:
	_set_interaction_prompt_suppressed(true)


func _on_carry_released(_body: RigidBody3D) -> void:
	_set_interaction_prompt_suppressed(false)


func _update_prompt_suppression_for_carry() -> void:
	_set_interaction_prompt_suppressed(_carry_controller != null and _carry_controller.is_carrying())


func _set_interaction_prompt_suppressed(suppressed: bool) -> void:
	if _interaction_raycaster == null:
		return
	if _interaction_raycaster.has_method("set_prompt_suppressed"):
		_interaction_raycaster.set_prompt_suppressed(suppressed)


func cancel_interaction_intent() -> void:
	_interaction_intent.cancel()


func _on_gate_tree_exiting(gate: Node) -> void:
	_modal_gates.erase(gate)


## Called from `_unhandled_input` on `interact` press.
func _on_interact_pressed(now_msec: int = -1) -> void:
	if is_modal_ui_open():
		_interaction_intent.cancel()
		return
	if now_msec < 0:
		now_msec = Time.get_ticks_msec()
	_interaction_intent.press(now_msec)


## Called from `_unhandled_input` on `interact` release.
func _on_interact_released(now_msec: int = -1) -> void:
	if not _interaction_intent.is_pressed():
		return
	# A modal UI may have opened mid-press; in that case suppress emission.
	if is_modal_ui_open():
		_interaction_intent.cancel()
		return
	if now_msec < 0:
		now_msec = Time.get_ticks_msec()
	var outcome: int = _interaction_intent.release(now_msec)
	if outcome == InteractionIntent.Outcome.HOLD_RELEASE:
		interact_release.emit()
		_route_carry_release()
	elif outcome == InteractionIntent.Outcome.TAP:
		_emit_interact_tap()


## Polled from `_physics_process`. Edge-detects modal gate state so the
## mouse cursor mode follows it automatically:
##   - rising edge (none open → some open): release cursor (VISIBLE)
##   - falling edge (some open → none open): re-capture (CAPTURED)
## This is the C.2.5 single-owner replacement for per-panel
## `Input.set_mouse_mode` writes — panels can stop touching mouse mode
## entirely once they trust this loop. Until then it is idempotent: any
## panel that ALSO sets mouse_mode itself will agree on the same value.
func _poll_modal_mouse_mode() -> void:
	var open_now: bool = is_modal_ui_open()
	if open_now == _was_modal_open:
		return
	_was_modal_open = open_now
	if open_now:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Polled from `_physics_process`. Emits `interact_hold_begin` once when
## the active press crosses the threshold.
func _poll_interact_hold(now_msec: int = -1) -> void:
	if not _interaction_intent.is_pressed():
		return
	if is_modal_ui_open():
		return
	if now_msec < 0:
		now_msec = Time.get_ticks_msec()
	if _interaction_intent.poll(now_msec) == InteractionIntent.Outcome.HOLD_BEGIN:
		interact_hold_begin.emit()
		_route_carry_grab()


## Default routing for `interact_tap`: forward to the raycaster's current
## target if one is attached and pointing at an Interactable. External
## listeners can also connect to `interact_tap` for additional behavior.
func _emit_interact_tap() -> void:
	interact_tap.emit()
	# If a CarryController is attached and currently holding something,
	# the tap is consumed by the carry stack — don't ALSO forward to the
	# raycaster target (which would tap-pickup whatever the player is
	# looking at while still holding the previous item). The hold-vs-tap
	# splitter handles this implicitly, but defensive: if a tap somehow leaks
	# through while carrying, refuse it here.
	if _carry_controller != null and _carry_controller.has_method("is_carrying"):
		if _carry_controller.is_carrying():
			return
	if _interaction_raycaster == null:
		return
	if not _interaction_raycaster.has_method("get_current_target"):
		return
	var target: Node = _interaction_raycaster.get_current_target()
	if target == null:
		return
	if not target.has_method("interact"):
		return
	target.interact(self)


## Default routing for `interact_hold_begin` (I.3): forward the
## raycaster's current target to the CarryController. The controller
## decides whether the target is grabbable; we just hand it the target.
func _route_carry_grab() -> void:
	if _carry_controller == null:
		return
	if not _carry_controller.has_method("try_grab"):
		return
	if _interaction_raycaster == null:
		return
	if not _interaction_raycaster.has_method("get_current_target"):
		return
	var target: Node = _interaction_raycaster.get_current_target()
	if target == null:
		return
	_carry_controller.try_grab(target)


## Default routing for `interact_release` (I.3): tell the carry
## controller to release whatever it's holding. No target lookup needed.
func _route_carry_release() -> void:
	if _carry_controller == null:
		return
	if not _carry_controller.has_method("release"):
		return
	_carry_controller.release()


# =============================================================================
# MOVEMENT (legacy — kept for fallback when CharacterMotor is not active)
# =============================================================================
# Movement is now handled by individual Move nodes (IdleMove, RunMove, etc.)
# via the MoveContainer owned by CharacterMotor.


func _handle_frozen_movement() -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	_reset_public_movement_state()


# =============================================================================
# CAMERA
# =============================================================================

func _update_camera_mode() -> void:
	if camera_mode == CameraMode.FIRST_PERSON:
		_target_camera_distance = 0.0
	else:
		_target_camera_distance = camera_distance


func _handle_camera_transition(delta: float) -> void:
	if not spring_arm:
		return
	spring_arm.spring_length = lerpf(
		spring_arm.spring_length, _target_camera_distance, camera_transition_speed * delta)

	# Show/hide character based on transition progress
	if character_root and camera_distance > 0.0:
		var progress := spring_arm.spring_length / camera_distance
		_set_character_visible(progress > 0.3)
	elif character_root:
		_set_character_visible(camera_mode == CameraMode.THIRD_PERSON)


func _handle_controller_camera(delta: float) -> void:
	if not controller_support or frozen:
		return
	if not InputMap.has_action("look_left") or not InputMap.has_action("look_right"):
		return
	if not InputMap.has_action("look_up") or not InputMap.has_action("look_down"):
		return
	var look_dir := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	if look_dir != Vector2.ZERO:
		camera_pivot.rotation.y -= look_dir.x * controller_sensitivity * delta
		camera_pivot.rotation.x += look_dir.y * controller_sensitivity * delta
		camera_pivot.rotation.x = clampf(camera_pivot.rotation.x, -_tilt_limit_rad, _tilt_limit_rad)


func _set_character_visible(p_visible: bool) -> void:
	if not character_root:
		return
	for child in character_root.get_children():
		if child is Skeleton3D:
			for skel_child in child.get_children():
				if skel_child is MeshInstance3D:
					skel_child.visible = p_visible
		elif child is MeshInstance3D:
			child.visible = p_visible


# =============================================================================
# IK
# =============================================================================

func _update_look_target() -> void:
	if not animation_system or not camera:
		return

	# Check for nearby points of interest first
	var poi_pos := _find_nearest_poi()
	if poi_pos != Vector3.INF:
		if animation_system.has_method("set_look_position"):
			animation_system.set_look_position(poi_pos)
		return

	# Default: look forward from character (not camera — camera looks down in 3rd person)
	var char_forward := -global_transform.basis.z.normalized()
	var head_height := global_position + Vector3.UP * 1.6
	var look_pos := head_height + char_forward * 10.0
	if animation_system.has_method("set_look_position"):
		animation_system.set_look_position(look_pos)


## Find the nearest POI within a forward cone. Returns Vector3.INF if none found.
func _find_nearest_poi() -> Vector3:
	var pois := get_tree().get_nodes_in_group("poi")
	if pois.is_empty():
		return Vector3.INF

	var head_pos := global_position + Vector3.UP * 1.6
	var char_forward := -global_transform.basis.z.normalized()
	var best_dist := 15.0  # Max look distance
	var best_pos := Vector3.INF

	for poi: Node in pois:
		if not poi is Node3D:
			continue
		var poi_node: Node3D = poi as Node3D
		var to_poi := poi_node.global_position - head_pos
		var dist := to_poi.length()
		if dist > best_dist or dist < 0.5:
			continue
		# Check if POI is within a 120-degree forward cone
		var angle := char_forward.angle_to(to_poi.normalized())
		if angle > deg_to_rad(60.0):
			continue
		if dist < best_dist:
			best_dist = dist
			best_pos = poi_node.global_position

	return best_pos


# =============================================================================
# WATER DETECTION
# =============================================================================

## Check ocean/water height at player position each frame.
## Uses OceanManager's shared water surface, or static water volumes (Area3D).
func _update_water_state() -> void:
	var pos := global_position

	# Static water volumes take priority (set by Area3D body_entered/exited)
	if _in_water_volume:
		_water_surface_y = _water_volume_surface_y
	elif OceanManager.is_system_enabled():
		# Same water-height contract used by buoyant objects; character response
		# remains controller-specific instead of RigidBody buoyancy.
		_water_surface_y = OceanManager.get_wave_height(pos)
	else:
		_water_surface_y = -INF

	var was_in_water := in_water
	# Player is "in water" when their feet are below the surface
	in_water = pos.y < _water_surface_y
	if in_water and not was_in_water:
		entered_water.emit()
	elif not in_water and was_in_water:
		exited_water.emit()


## Called by water volume Area3D when player enters
func enter_water_volume(surface_y: float) -> void:
	_in_water_volume = true
	_water_volume_surface_y = surface_y


## Called by water volume Area3D when player exits
func exit_water_volume() -> void:
	_in_water_volume = false
	_water_volume_surface_y = -INF


# =============================================================================
# HELPERS
# =============================================================================

func _get_animation_tree() -> AnimationTree:
	if not animation_system:
		return null
	# AnimationTree is on the skeleton, accessible through the animation manager
	if animation_system.has_method("get_animation_tree"):
		return animation_system.get_animation_tree()
	# Fallback: search character hierarchy
	if character_root:
		return _find_node_of_type(character_root, "AnimationTree") as AnimationTree
	return null


func _find_node_of_type(node: Node, type_name: String) -> Node:
	if node.get_class() == type_name:
		return node
	for child in node.get_children():
		var result := _find_node_of_type(child, type_name)
		if result:
			return result
	return null


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var result := _find_skeleton(child)
		if result:
			return result
	return null
