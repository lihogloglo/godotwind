## Carry velocity-drive — HL2 physics-gun pattern test scene
##
## Replaces the kinematic direct-transform-write carry loop with the
## canonical industry pattern: body stays DYNAMIC, we set its linear
## and angular velocity each physics tick to chase a target pose
## derived from the camera rig. Jolt integrates the body at physics
## rate; Godot 4.6's engine-side physics interpolation smooths the
## rendered position between ticks. No manual composition bridges,
## no per-node interpolation carve-outs, no wall-pushback raycast —
## Jolt handles wall collisions naturally because the body is a real
## rigid body being pushed by a velocity command.
##
## ## Why this pattern
##
## See `.claude/CLAUDE.md` "Engineering Principle — Simplicity Over
## Over-Engineering". After three sessions of patching the kinematic
## approach, the user pasted the HL2 snippet and asked why we weren't
## already doing this. The kinematic approach had the inherent flaw
## that `body.global_transform = X` from `_process` bypasses Jolt's
## own interpolation and collides with the engine's own transform
## cache in ways that produce visible render-rate-vs-physics-rate
## beats.
##
## The velocity-drive pattern is how:
##   - Source / HL2 physgun does it
##   - Unreal PhysicsHandle component does it internally
##   - Unity FixedJoint + damped spring does it
##   - Rigidbody grab in every Oblivion / Skyrim mod does it
## 20+ years of commercial-game pedigree.
##
## ## Contract
##
## On grab:
##   - `freeze = false` — body is dynamic, Jolt integrates it
##   - `gravity_scale = 0` — don't fight gravity while held
##   - `linear_damp / angular_damp` bumped up — prevents oscillation
##   - `collision_mask` excludes the player's current layer bits
##
## Each physics tick (while held):
##   - Compute world-space target pose from camera rig
##   - `linear_velocity = clamp((target.origin - body.origin) * PULL, MAX_SPEED)`
##   - `angular_velocity = axis * angle * ANG_PULL` (shortest-path rotation)
##
## On release:
##   - Restore `gravity_scale`, `collision_mask`, damping
##   - Stop overwriting velocity — body retains its last-frame chase velocity
##     as the NATURAL throw impulse (no lever-arm cross product needed)
##
## ## Toggles
##
## F1 — cycle physics ticks per second (60 / 120 / 144)
## F4 — dump telemetry CSV to user://
## F5 — toggle snap mode (instant position, for A/B comparison)
## F6 — clear telemetry buffer
## F7 — auto camera wiggle (1 Hz yaw oscillation, reproducible motion)
## F8 — cycle pull strength: 6 → 10 → 14 → 18 → 22 → back
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access", "unsafe_cast")
extends Node

const InteractionRaycasterScript := preload("res://src/core/interaction/interaction_raycaster.gd")
const PlayerControllerScript := preload("res://src/core/player/player_controller.gd")
const CarryableRegistryScript := preload("res://src/core/interaction/carryable_registry.gd")
const CarryableBodyFactoryScript := preload("res://src/core/interaction/carryable_body_factory.gd")
const GameplayPhysicsLayersScript := preload("res://src/core/physics/gameplay_physics_layers.gd")
const PickupInteractableScript := preload("res://src/core/interaction/morrowind/pickup_interactable.gd")
const MWCarryableRegistryScript := preload("res://src/core/interaction/morrowind/mw_carryable_registry.gd")
const InventoryServiceScript := preload("res://src/core/interaction/inventory_service.gd")
const MWInventoryServiceScript := preload("res://src/core/interaction/morrowind/mw_inventory_service.gd")
const CarryTelemetryLoggerScript := preload("res://tests/visual/carry_telemetry_logger.gd")


class FakeRecord:
	var record_id: String
	var name: String
	var weight: float
	var _can_carry: bool = true
	func _init(id: String, n: String, w: float, cc: bool = true) -> void:
		record_id = id
		name = n
		weight = w
		_can_carry = cc
	func can_carry() -> bool:
		return _can_carry


# ----------------------------------------------------------------------------
# Tuning constants
# ----------------------------------------------------------------------------

## Linear chase gain — velocity = (target - body) * PULL_STRENGTH.
## Higher = stiffer chase, lower = floatier. Tunable via F8.
const PULL_STRENGTHS: Array[float] = [6.0, 10.0, 14.0, 18.0, 22.0]
var _pull_strength_index: int = 2  # default 14.0

## Angular chase gain — angular_velocity = axis * angle * ANGULAR_PULL.
const ANGULAR_PULL: float = 12.0

## Safety cap on chase velocity so far grabs don't teleport the body
## through the world. Any body more than (MAX_SPEED / PULL) meters
## away gets velocity-capped and drags in over multiple ticks.
const MAX_LINEAR_SPEED: float = 12.0  # m/s
const MAX_ANGULAR_SPEED: float = 20.0  # rad/s

## Hold distance clamp. Grab capture uses the body's camera-local
## position at grab time, clamped to this range so the marker always
## sits between the camera and arm's-length.
const MIN_HOLD_DISTANCE: float = 0.8
const MAX_HOLD_DISTANCE: float = 1.8

## Damping applied to the held body while it's in the chase loop.
## Prevents oscillation around the target pose without needing an
## integral term or critical damping math — the proportional chase
## + constant damping combo is standard for physics-gun tuning.
const HELD_LINEAR_DAMP: float = 4.0
const HELD_ANGULAR_DAMP: float = 6.0

## Walking params for the test scene movement loop.
const WALK_SPEED: float = 4.0
const GRAVITY: float = 18.0
const JUMP_VELOCITY: float = 6.0


# ----------------------------------------------------------------------------
# Refs
# ----------------------------------------------------------------------------

var _player: PlayerController
var _raycaster: InteractionRaycaster
var _hold_marker: Marker3D
var _logger: Node  # CarryTelemetryLogger — type-erased to dodge class_name order

# Held body state — the ENTIRE grab/hold/release implementation for
# this scene lives inline here. We deliberately do NOT use the
# existing `CarryController` class because this scene is the A/B
# comparison against it. The point is to prove a simpler
# implementation works before touching the framework class.
var _held_body: RigidBody3D = null
var _saved_mask: int = 0
var _saved_gravity_scale: float = 1.0
var _saved_linear_damp: float = 0.0
var _saved_angular_damp: float = 0.0

# HUD
var _hud_stats_label: Label
var _hud_help_label: Label
var _hud_toggles_label: Label
var _hud_prompt_label: Label

# Toggle state mirrors the audit scene for consistency.
const TICK_RATES: Array[int] = [60, 120, 144]
var _tick_rate_index: int = 0
var _snap_mode: bool = false
var _auto_wiggle: bool = false
var _auto_wiggle_time: float = 0.0


# ----------------------------------------------------------------------------
# Lifecycle
# ----------------------------------------------------------------------------

func _ready() -> void:
	CarryableRegistryScript.clear()
	MWCarryableRegistryScript.register_all()
	InventoryServiceScript.set_current(MWInventoryServiceScript.new())

	# Scene root runs _process AFTER physics tick work but BEFORE the
	# logger, so the HUD refresh sees the latest body state each frame.
	process_priority = 500

	_build_world()
	_build_player()
	_spawn_props()
	_build_ui()
	_build_logger()

	_player.interact_tap.connect(_on_interact_tap)
	_player.interact_hold_begin.connect(_on_interact_hold_begin)
	_player.interact_release.connect(_on_interact_release)
	_raycaster.prompt_changed.connect(_on_prompt_changed)

	_apply_tick_rate()
	_refresh_toggles_label()

	Log.info("interaction",
		"[vel-drive] ready — tick rate %d Hz · pull %.1f"
		% [Engine.physics_ticks_per_second, PULL_STRENGTHS[_pull_strength_index]])


func _exit_tree() -> void:
	set_physics_process(false)
	set_process(false)
	# Restore the held body to canonical state before teardown starts
	# freeing nodes out from under the physics server. Mirrors the
	# `CarryController._exit_tree` safety pattern.
	if _held_body != null and is_instance_valid(_held_body):
		_held_body.gravity_scale = _saved_gravity_scale
		_held_body.collision_mask = _saved_mask
		_held_body.linear_damp = _saved_linear_damp
		_held_body.angular_damp = _saved_angular_damp
		_held_body.linear_velocity = Vector3.ZERO
		_held_body.angular_velocity = Vector3.ZERO
	_held_body = null
	_logger = null
	_player = null
	_raycaster = null
	_hold_marker = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_dump_csv_silent_on_exit()


# ----------------------------------------------------------------------------
# World / player / props
# ----------------------------------------------------------------------------

func _build_world() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	add_child(floor_body)

	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 0.2, 40)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)

	var floor_mesh := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(40, 0.2, 40)
	floor_mesh.mesh = mesh
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.22, 0.22, 0.26)
	floor_mesh.material_override = floor_mat
	floor_body.add_child(floor_mesh)

	# Reference posts every 2 m so the eye has stationary features
	# to compare against for any residual vibration.
	for x in range(-6, 7, 2):
		for z in range(-6, 7, 2):
			if x == 0 and z == 0:
				continue
			var post_mesh := MeshInstance3D.new()
			var post := BoxMesh.new()
			post.size = Vector3(0.05, 0.6, 0.05)
			post_mesh.mesh = post
			post_mesh.position = Vector3(x, 0.4, z)
			var post_mat := StandardMaterial3D.new()
			post_mat.albedo_color = Color(0.6, 0.55, 0.45)
			post_mesh.material_override = post_mat
			add_child(post_mesh)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-PI / 4, PI / 4, 0)
	sun.light_energy = 1.2
	add_child(sun)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.14, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.5
	env_node.environment = env
	add_child(env_node)


func _build_player() -> void:
	_player = PlayerControllerScript.new()
	_player.position = Vector3(0, 0.1, 4.0)
	add_child(_player)
	_player.set_camera_mode(PlayerControllerScript.CameraMode.FIRST_PERSON)
	_player.spring_arm.spring_length = 0.0
	_player.enable()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	_raycaster = InteractionRaycasterScript.new()
	_raycaster.camera = _player.get_camera()
	_raycaster.max_distance = 8.0
	_player.get_camera().add_child(_raycaster)
	_player.set_interaction_raycaster(_raycaster)

	# Hold marker — child of the camera so it rides the camera
	# transform naturally via scene-tree inheritance. We never write
	# to its transform from `_physics_process`; the local position is
	# set ONCE at grab time (to the body's camera-local capture pose)
	# and left alone. The scene-tree composition at physics tick time
	# produces a world-space target pose from the marker.
	_hold_marker = Marker3D.new()
	_hold_marker.name = "HoldTarget"
	_player.get_camera().add_child(_hold_marker)


func _spawn_props() -> void:
	# Three props at varying masses + positions so the pull + damp
	# tuning is testable across the weight range.
	_spawn_prop("apple", Vector3(-1.5, 0.5, 0), &"ingredient",
		FakeRecord.new("ingred_apple_01", "Apple", 0.2),
		Vector3(0.15, 0.15, 0.15), Color(0.85, 0.2, 0.2))

	_spawn_prop("barrel", Vector3(0, 0.5, 0), &"misc",
		FakeRecord.new("barrel_vel_01", "Barrel", 5.0),
		Vector3(0.4, 0.5, 0.4), Color(0.55, 0.35, 0.20))

	_spawn_prop("book", Vector3(1.5, 0.5, 0), &"book",
		FakeRecord.new("book_vel_01", "Book", 2.0),
		Vector3(0.2, 0.25, 0.05), Color(0.3, 0.2, 0.6))


func _spawn_prop(label: String, pos: Vector3, type_name: StringName,
		record: Variant, mesh_size: Vector3, color: Color) -> void:
	var instance := _build_fake_prop(label, mesh_size, color)
	instance.position = pos
	add_child(instance)
	var mass: float = CarryableRegistryScript.get_mass(type_name, record)
	var rb := CarryableBodyFactoryScript.convert_static_to_rigid(
		instance, mass, StringName(record.record_id), record.name, PickupInteractableScript)
	if rb == null:
		push_error("[vel-drive] factory returned null for %s" % label)


func _build_fake_prop(label: String, size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	root.name = "Prop_%s" % label
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "Mesh"
	var box := BoxMesh.new()
	box.size = size
	mesh_inst.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh_inst.material_override = mat
	root.add_child(mesh_inst)

	var body := StaticBody3D.new()
	body.name = "CollisionBody"
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	body.add_child(shape)
	root.add_child(body)
	return root


# ----------------------------------------------------------------------------
# Telemetry
# ----------------------------------------------------------------------------

func _build_logger() -> void:
	_logger = CarryTelemetryLoggerScript.new()
	_logger.name = "CarryTelemetryLogger"
	_logger.player = _player
	_logger.camera_pivot = _player.camera_pivot
	_logger.spring_arm = _player.spring_arm
	_logger.camera = _player.get_camera()
	_logger.marker = _hold_marker
	# Type-erased: the logger's `carry` field duck-types `get_held_body`
	# and `is_carrying`, so we can pass ANY node that implements those.
	# We pass `self` and expose both methods on the test scene.
	_logger.carry = self
	add_child(_logger)


## Duck-typed for CarryTelemetryLogger. Returns the currently held body.
func get_held_body() -> RigidBody3D:
	return _held_body


## Duck-typed for CarryTelemetryLogger. Whether anything is held.
func is_carrying() -> bool:
	return _held_body != null and is_instance_valid(_held_body)


# ----------------------------------------------------------------------------
# Grab / Hold / Release — the whole point of this scene
# ----------------------------------------------------------------------------

## Called from `_on_interact_hold_begin` — resolves the raycaster target
## into a carryable RigidBody3D, snapshots pre-grab state, then defers
## the actual body-side mutations outside the physics callback.
func _try_grab_from_interact() -> void:
	if is_carrying():
		return
	if _raycaster == null:
		return
	var target: Interactable = _raycaster.get_current_target()
	if target == null:
		return
	var parent_root := target.get_parent()
	if parent_root == null or not parent_root.has_meta("carryable_wrapper"):
		return

	var rb: RigidBody3D = null
	for child in target.get_children():
		if child is RigidBody3D:
			rb = child
			break
	if rb == null:
		return

	# Capture pre-grab state.
	_held_body = rb
	_saved_mask = rb.collision_mask
	_saved_gravity_scale = rb.gravity_scale
	_saved_linear_damp = rb.linear_damp
	_saved_angular_damp = rb.angular_damp

	# Set the hold marker to the body's CURRENT camera-local position,
	# clamped to a reasonable distance range. Same capture semantics
	# as the original CarryController — keeps "grab where you aim".
	var camera := _player.get_camera()
	var body_world_pos := rb.global_position
	var capture_local: Vector3 = camera.global_transform.affine_inverse() * body_world_pos
	var dist: float = capture_local.length()
	if dist < MIN_HOLD_DISTANCE:
		capture_local = capture_local.normalized() * MIN_HOLD_DISTANCE
	elif dist > MAX_HOLD_DISTANCE:
		capture_local = capture_local.normalized() * MAX_HOLD_DISTANCE
	if not capture_local.is_finite():
		capture_local = Vector3(0.0, -0.2, -1.2)
	_hold_marker.position = capture_local

	_do_grab.call_deferred(rb)


## Deferred body-side mutation — unfreeze, zero gravity, bump damping,
## clear player collision bit. Runs OUTSIDE the physics callback to
## avoid Jolt crashes on in-tick state mutation (same rule as
## CarryController._do_grab per §6.2).
func _do_grab(rb: RigidBody3D) -> void:
	if not is_instance_valid(rb):
		_held_body = null
		return
	rb.freeze = false
	rb.gravity_scale = 0.0
	rb.linear_damp = HELD_LINEAR_DAMP
	rb.angular_damp = HELD_ANGULAR_DAMP
	rb.collision_mask = GameplayPhysicsLayersScript.get_held_body_mask(_saved_mask, _player)
	# Zero out whatever velocity the body had pre-grab so the chase
	# starts from a clean state. The velocity drive will ramp it up
	# as needed over the next few ticks.
	rb.linear_velocity = Vector3.ZERO
	rb.angular_velocity = Vector3.ZERO


## Release — stop overwriting velocity. The body retains its last
## chase velocity as the natural throw impulse (no manual lever-arm
## cross product computation, no ring buffer — physics gives it for
## free because we never stopped using physics).
func _try_release() -> void:
	if not is_carrying():
		return
	var rb := _held_body
	_held_body = null
	_do_release.call_deferred(rb, _saved_mask, _saved_gravity_scale,
		_saved_linear_damp, _saved_angular_damp)


func _do_release(
	rb: RigidBody3D,
	saved_mask: int,
	saved_gs: float,
	saved_ld: float,
	saved_ad: float,
) -> void:
	if not is_instance_valid(rb):
		return
	rb.gravity_scale = saved_gs
	rb.collision_mask = saved_mask
	rb.linear_damp = saved_ld
	rb.angular_damp = saved_ad
	# DO NOT zero velocity here — the body keeps its current chase
	# velocity, which provides a natural throw based on how fast the
	# camera was moving in the last tick. This is how Source physgun
	# throws work: release = stop commanding, let momentum carry.


# ----------------------------------------------------------------------------
# Physics tick — the chase loop
# ----------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _player == null:
		return

	# --- Walking (scene-owned movement loop) ---
	var input_dir: Vector2 = Input.get_vector(
		"move_left", "move_right", "move_forward", "move_backward")
	var cam := _player.get_camera()
	var cam_basis := cam.global_transform.basis
	var forward := -Vector3(cam_basis.z.x, 0, cam_basis.z.z).normalized()
	var right := Vector3(cam_basis.x.x, 0, cam_basis.x.z).normalized()
	var move := (right * input_dir.x + forward * -input_dir.y) * WALK_SPEED
	_player.velocity.x = move.x
	_player.velocity.z = move.z
	if _player.is_on_floor():
		if Input.is_action_just_pressed("jump"):
			_player.velocity.y = JUMP_VELOCITY
	else:
		_player.velocity.y -= GRAVITY * delta

	# --- F7 auto-wiggle — runs in physics tick, which means the
	# camera_pivot updates at physics rate. That's fine here: the
	# chase ALSO runs at physics rate, so both inputs are synced.
	if _auto_wiggle:
		_auto_wiggle_time += delta
		_player.camera_pivot.rotation.y = sin(_auto_wiggle_time * TAU * 1.0) * 0.6
		_player.camera_pivot.rotation.x = sin(_auto_wiggle_time * TAU * 0.5) * 0.2

	_player.move_and_slide()

	# --- Velocity-drive chase ---
	if not is_carrying():
		return
	if _hold_marker == null:
		return

	var target_xf: Transform3D = _hold_marker.global_transform
	var target_pos: Vector3 = target_xf.origin
	var body_pos: Vector3 = _held_body.global_position

	if _snap_mode:
		# A/B comparison: hard-set the transform (same as the old
		# audit scene's snap mode). Not a real carry mode — just
		# the baseline for "what does zero lag look like".
		_held_body.linear_velocity = Vector3.ZERO
		_held_body.angular_velocity = Vector3.ZERO
		_held_body.global_position = target_pos
		var cam_euler_snap: Vector3 = target_xf.basis.get_euler()
		_held_body.global_basis = Basis.from_euler(Vector3(cam_euler_snap.x, cam_euler_snap.y, 0.0))
		return

	# --- Linear velocity drive ---
	# v = (target - current) * pull_strength. Jolt integrates this
	# over the physics tick; engine interpolation smooths the rendered
	# position between ticks. No manual interp bridge, no direct
	# transform writes.
	var pull: float = PULL_STRENGTHS[_pull_strength_index]
	var delta_pos: Vector3 = target_pos - body_pos
	var desired_v: Vector3 = delta_pos * pull
	var speed: float = desired_v.length()
	if speed > MAX_LINEAR_SPEED:
		desired_v = desired_v * (MAX_LINEAR_SPEED / speed)
	if not desired_v.is_finite():
		desired_v = Vector3.ZERO
	_held_body.linear_velocity = desired_v

	# --- Angular velocity drive ---
	# Target basis: camera yaw + pitch, roll locked to world up per
	# §6.2. Compute shortest-path rotation from body basis to target
	# basis as a quaternion, convert to axis-angle, scale by ANG_PULL.
	var cam_euler: Vector3 = target_xf.basis.get_euler()
	var target_basis: Basis = Basis.from_euler(Vector3(cam_euler.x, cam_euler.y, 0.0))
	var current_basis: Basis = _held_body.global_basis
	var delta_basis: Basis = target_basis * current_basis.inverse()
	var q: Quaternion = delta_basis.get_rotation_quaternion()
	# Shortest-path: if w is negative, the quaternion represents the
	# long-way rotation; negate to get the short way.
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


# ----------------------------------------------------------------------------
# HUD + input toggles
# ----------------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)

	var crosshair := ColorRect.new()
	crosshair.color = Color(1, 1, 1, 0.85)
	crosshair.size = Vector2(4, 4)
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.offset_left = -2
	crosshair.offset_top = -2
	crosshair.offset_right = 2
	crosshair.offset_bottom = 2
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(crosshair)

	_hud_prompt_label = Label.new()
	_hud_prompt_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hud_prompt_label.offset_top = -80
	_hud_prompt_label.offset_left = -300
	_hud_prompt_label.offset_right = 300
	_hud_prompt_label.offset_bottom = -40
	_hud_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud_prompt_label.add_theme_font_size_override("font_size", 22)
	_hud_prompt_label.add_theme_color_override("font_color", Color(1, 1, 0.85))
	layer.add_child(_hud_prompt_label)

	_hud_stats_label = Label.new()
	_hud_stats_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_hud_stats_label.offset_left = 16
	_hud_stats_label.offset_top = 16
	_hud_stats_label.offset_right = 560
	_hud_stats_label.offset_bottom = 420
	_hud_stats_label.add_theme_font_size_override("font_size", 14)
	_hud_stats_label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	layer.add_child(_hud_stats_label)

	_hud_toggles_label = Label.new()
	_hud_toggles_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_hud_toggles_label.offset_left = -420
	_hud_toggles_label.offset_top = 16
	_hud_toggles_label.offset_right = -16
	_hud_toggles_label.offset_bottom = 260
	_hud_toggles_label.add_theme_font_size_override("font_size", 14)
	_hud_toggles_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7))
	layer.add_child(_hud_toggles_label)

	_hud_help_label = Label.new()
	_hud_help_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_hud_help_label.offset_left = 16
	_hud_help_label.offset_top = -220
	_hud_help_label.offset_right = 760
	_hud_help_label.offset_bottom = -16
	_hud_help_label.add_theme_font_size_override("font_size", 13)
	_hud_help_label.add_theme_color_override("font_color", Color(0.75, 0.80, 0.90))
	_hud_help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hud_help_label.text = (
		"carry velocity-drive — HL2 physics gun pattern\n"
		+ "WASD walk · mouse look · hold E to grab (apple / barrel / book)\n"
		+ "F1: cycle physics tick rate (60 / 120 / 144)\n"
		+ "F4: dump telemetry CSV to user://carry_vel_<ts>.csv\n"
		+ "F5: toggle SNAP mode (instant position, A/B baseline)\n"
		+ "F6: clear telemetry buffer\n"
		+ "F7: scripted camera wiggle (reproducible motion)\n"
		+ "F8: cycle pull strength — 6 / 10 / 14 / 18 / 22\n"
		+ "click to capture mouse · esc to release\n"
		+ "\n"
		+ "compare to test_carry_vibration_audit.tscn (direct-write kinematic loop).\n"
		+ "this one uses dynamic bodies + velocity commands — Jolt + engine interp handle smoothing."
	)
	layer.add_child(_hud_help_label)


func _process(_delta: float) -> void:
	_refresh_stats_label()


func _refresh_stats_label() -> void:
	if _hud_stats_label == null or not is_instance_valid(_hud_stats_label):
		return
	if _logger == null or not is_instance_valid(_logger):
		return
	var phys_stats: Dictionary = _logger.compute_jitter_stats(
		CarryTelemetryLoggerScript.SampleSource.PHYS, 200)
	var rend_stats: Dictionary = _logger.compute_jitter_stats(
		CarryTelemetryLoggerScript.SampleSource.REND, 200)
	var held_str: String = "no"
	var chase_lag_mm: float = NAN
	var body_speed: float = NAN
	if is_carrying():
		held_str = "yes"
		var held: RigidBody3D = _held_body
		if held != null and is_instance_valid(held) and _hold_marker != null:
			var target: Vector3 = _hold_marker.global_position
			chase_lag_mm = held.global_position.distance_to(target) * 1000.0
			body_speed = held.linear_velocity.length()
	var fps: float = Engine.get_frames_per_second()
	var phys_hz: int = Engine.physics_ticks_per_second
	var pif: float = Engine.get_physics_interpolation_fraction()
	_hud_stats_label.text = (
		"[tick %d Hz · fps %d · phys_interp_frac %.3f]\n" % [phys_hz, int(fps), pif]
		+ "held: %s · chase lag: %.2f mm · body |v|: %.3f m/s\n\n" % [held_str, chase_lag_mm, body_speed]
		+ "per-sample Δ (last 200 samples, mm)\n"
		+ "PHYS (n=%d)\n" % int(phys_stats.get("n", 0))
		+ "  body Δ  max %.3f · rms %.3f\n" % [phys_stats.get("max_dpos_mm", NAN), phys_stats.get("rms_dpos_mm", NAN)]
		+ "  tgt  Δ  max %.3f · rms %.3f\n" % [phys_stats.get("max_target_dpos_mm", NAN), phys_stats.get("rms_target_dpos_mm", NAN)]
		+ "REND (n=%d)\n" % int(rend_stats.get("n", 0))
		+ "  body Δ  max %.3f · rms %.3f\n" % [rend_stats.get("max_dpos_mm", NAN), rend_stats.get("rms_dpos_mm", NAN)]
		+ "  tgt  Δ  max %.3f · rms %.3f\n\n" % [rend_stats.get("max_target_dpos_mm", NAN), rend_stats.get("rms_target_dpos_mm", NAN)]
		+ "expected behavior\n"
		+ "  chase lag > 0 mm while moving (that's the 'weight' feel)\n"
		+ "  body Δ rms REND ~ target Δ rms REND (smooth 1:1 chase)\n"
		+ "  no vibration-frequency beat between ticks"
	)


func _refresh_toggles_label() -> void:
	if _hud_toggles_label == null:
		return
	_hud_toggles_label.text = (
		"toggles\n"
		+ "  tick rate:   %d Hz\n" % TICK_RATES[_tick_rate_index]
		+ "  pull:        %.1f\n" % PULL_STRENGTHS[_pull_strength_index]
		+ "  snap mode:   %s\n" % ("ON (no chase)" if _snap_mode else "off")
		+ "  auto-wiggle: %s\n" % ("ON (1 Hz yaw)" if _auto_wiggle else "off")
	)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var key_event := event as InputEventKey
	match key_event.physical_keycode:
		KEY_F1:
			_tick_rate_index = (_tick_rate_index + 1) % TICK_RATES.size()
			_apply_tick_rate()
			_refresh_toggles_label()
			get_viewport().set_input_as_handled()
		KEY_F4:
			_dump_csv()
			get_viewport().set_input_as_handled()
		KEY_F5:
			_snap_mode = not _snap_mode
			_refresh_toggles_label()
			Log.info("interaction", "[vel-drive] snap mode = %s" % _snap_mode)
			get_viewport().set_input_as_handled()
		KEY_F6:
			if _logger != null:
				_logger.clear_samples()
				Log.info("interaction", "[vel-drive] telemetry buffer cleared")
			get_viewport().set_input_as_handled()
		KEY_F7:
			_auto_wiggle = not _auto_wiggle
			_auto_wiggle_time = 0.0
			_refresh_toggles_label()
			Log.info("interaction", "[vel-drive] auto wiggle = %s" % _auto_wiggle)
			get_viewport().set_input_as_handled()
		KEY_F8:
			_pull_strength_index = (_pull_strength_index + 1) % PULL_STRENGTHS.size()
			_refresh_toggles_label()
			Log.info("interaction",
				"[vel-drive] pull strength -> %.1f"
				% PULL_STRENGTHS[_pull_strength_index])
			get_viewport().set_input_as_handled()


func _apply_tick_rate() -> void:
	Engine.physics_ticks_per_second = TICK_RATES[_tick_rate_index]
	Log.info("interaction",
		"[vel-drive] physics tick rate -> %d Hz" % TICK_RATES[_tick_rate_index])


func _dump_csv() -> void:
	if _logger == null:
		return
	var ts: String = Time.get_datetime_string_from_system(true).replace(":", "-")
	var path: String = "user://carry_vel_%s.csv" % ts
	var err: int = _logger.export_csv(path)
	if err != OK:
		Log.error("interaction", "[vel-drive] CSV export failed: %d" % err)
		return
	var abs_path: String = ProjectSettings.globalize_path(path)
	Log.info("interaction",
		"[vel-drive] CSV dumped (%d samples) -> %s" % [_logger.sample_count(), abs_path])
	if _hud_prompt_label != null:
		_hud_prompt_label.text = "CSV -> %s" % abs_path
		get_tree().create_timer(3.0).timeout.connect(func() -> void:
			if _hud_prompt_label != null:
				_hud_prompt_label.text = "")


func _dump_csv_silent_on_exit() -> void:
	if _logger == null or not is_instance_valid(_logger):
		return
	if _logger.sample_count() == 0:
		return
	var ts: String = Time.get_datetime_string_from_system(true).replace(":", "-")
	var path: String = "user://carry_vel_exit_%s.csv" % ts
	var err: int = _logger.export_csv(path)
	if err == OK:
		Log.info("interaction",
			"[vel-drive] auto-dumped %d samples on exit -> %s"
			% [_logger.sample_count(), ProjectSettings.globalize_path(path)])


# ----------------------------------------------------------------------------
# Signal handlers
# ----------------------------------------------------------------------------

func _on_prompt_changed(interactable: Interactable, distance: float) -> void:
	if _hud_prompt_label == null:
		return
	if interactable == null:
		_hud_prompt_label.text = ""
		return
	_hud_prompt_label.text = "[hold E] %s  (%.1fm)" % [interactable.get_prompt_text(), distance]


func _on_interact_tap() -> void:
	Log.debug("interaction", "[vel-drive] interact_tap")


func _on_interact_hold_begin() -> void:
	Log.info("interaction", "[vel-drive] interact_hold_begin -> grab")
	_try_grab_from_interact()


func _on_interact_release() -> void:
	Log.info("interaction", "[vel-drive] interact_release -> drop/throw")
	_try_release()
