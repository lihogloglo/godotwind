## Carry vibration audit — diagnostic test scene
##
## Goal: separate the three possible causes of the residual hold-pose
## vibration described in `docs/INTERACTION_SYSTEM.md` §17.2.1, using
## hard numerical evidence instead of speculation.
##
## Setup:
##   - Flat floor, NO walls (wall pushback would perturb measurements)
##   - Player rig identical to the main-scene setup (so the SpringArm3D
##     camera chain is reproduced faithfully)
##   - Single 5 kg barrel the user can grab
##   - `CarryTelemetryLogger` attached to the scene root with references
##     to the player rig + the carry controller's hold marker
##
## What the logger captures on EACH physics tick AND each render frame:
##   - player.global_position (raw, just-written post-move_and_slide)
##   - player.get_global_transform_interpolated().origin (engine-smoothed)
##   - camera_pivot.rotation (euler, mouse-driven)
##   - spring_arm hit length (internal raycast result)
##   - camera.global_position (live — through the MODE_OFF subtree)
##   - marker.global_position (live)
##   - target_world_pos (logger-side recomputation of what carry.process
##     composes — player_interp × rig_offset_live, the thing the body chases)
##   - held_body.global_position + rotation (the final observable)
##   - Engine.get_physics_interpolation_fraction()
##
## A CSV export lets an external tool (spreadsheet, notebook) plot per-
## frame Δpos of each field over time to separate PHYSICAL stutter from
## VISUAL stutter from COMPOSITION jitter.
##
## Toggle keys (press while the scene is running):
##   F1 — cycle physics_ticks_per_second: 60 → 120 → 144 → 60 …
##   F2 — cycle held body physics_interpolation_mode: OFF → ON → INHERIT → OFF …
##   F3 — toggle spring_arm.collision_mask: 1 (on) ↔ 0 (disable internal raycast)
##   F4 — dump CSV to `user://carry_vibration_audit_<ts>.csv`
##   F5 — toggle "snap mode" on the held body (disables lerp — instant chase)
##   F6 — clear telemetry buffer (start a fresh recording window)
##   F7 — auto-wiggle the player (scripted camera yaw oscillation so the
##        vibration is reproducible without the tester moving the mouse)
##
## Real-time HUD shows:
##   - Current physics tick rate + render FPS
##   - Held body state (held / free)
##   - Per-source per-frame Δpos stats (max + RMS, last 200 samples)
##   - Target position Δ stats (the COMPOSITION jitter signal)
##   - Delta between held_body_pos and target_pos (the CHASE LAG — high
##     lag is not vibration, but it tells us the lerp is off)
##
## Run:
##   "<godot-executable>" \
##     --path "<project-path>" \
##     res://tests/visual/test_carry_vibration_audit.tscn
##
## WASD walks, mouse looks, E tap/hold. F1-F7 diagnostic toggles.
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access", "unsafe_cast")
extends Node

const InteractionRaycasterScript := preload("res://src/core/interaction/interaction_raycaster.gd")
const PlayerControllerScript := preload("res://src/core/player/player_controller.gd")
const CarryableRegistryScript := preload("res://src/core/interaction/carryable_registry.gd")
const CarryableBodyFactoryScript := preload("res://src/core/interaction/carryable_body_factory.gd")
const CarryControllerScript := preload("res://src/core/interaction/carry_controller.gd")
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


var _player: PlayerController
var _raycaster: InteractionRaycaster
var _carry: Node  # CarryController
var _logger: Node  # CarryTelemetryLogger — type-erased to avoid class_name resolution order issues

var _hud_stats_label: Label
var _hud_help_label: Label
var _hud_toggles_label: Label
var _hud_prompt_label: Label

# Toggle state
const TICK_RATES: Array[int] = [60, 120, 144]
var _tick_rate_index: int = 0

const BODY_INTERP_MODES: Array[int] = [
	Node.PHYSICS_INTERPOLATION_MODE_OFF,
	Node.PHYSICS_INTERPOLATION_MODE_ON,
	Node.PHYSICS_INTERPOLATION_MODE_INHERIT,
]
var _body_interp_mode_index: int = 0

var _spring_arm_collide: bool = true
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

	# Scene root runs _process AFTER carry_controller (priority 0) so
	# the snap-mode write in `_process` can override carry's chase
	# write. The logger is at priority 1000 so it samples the FINAL
	# body transform each frame (carry chase → scene snap → logger).
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
	# NOTE: we deliberately do NOT auto-reapply the F2 body interp mode
	# on grab. The carry controller always sets the held body to OFF in
	# its `_do_grab` helper; if the tester wants to diagnose a different
	# mode, they press F2 WHILE holding (the grab has landed by then).
	# An earlier iteration did this via a double-deferred reapply hooked
	# to the `grabbed` signal, which queued a stray call_deferred into
	# the scene-teardown window and caused sig 11 shutdown crashes when
	# the player closed the window while holding. Simpler = safer.

	# Apply initial toggle state so the HUD line matches reality.
	_apply_tick_rate()
	_apply_body_interp_mode()
	_apply_spring_arm_collision()
	_refresh_toggles_label()

	Log.info("interaction",
		"[carry audit] ready — tick rate %d Hz, body interp OFF, spring arm collide ON"
		% Engine.physics_ticks_per_second)


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
	# A 1 m grid so per-frame motion is easy to eyeball against a ruler.
	floor_mat.uv1_scale = Vector3(10, 10, 1)
	floor_mesh.material_override = floor_mat
	floor_body.add_child(floor_mesh)

	# Reference posts every 2 m so the eye has high-frequency features
	# to watch for wobble against.
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
	# First-person to see the held body as the user would in-game.
	_player.set_camera_mode(PlayerControllerScript.CameraMode.FIRST_PERSON)
	_player.spring_arm.spring_length = 0.0
	_player.enable()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	_raycaster = InteractionRaycasterScript.new()
	_raycaster.camera = _player.get_camera()
	_raycaster.max_distance = 8.0
	_player.get_camera().add_child(_raycaster)
	_player.set_interaction_raycaster(_raycaster)

	_carry = CarryControllerScript.new()
	_carry.name = "CarryController"
	_player.add_child(_carry)
	_carry.setup(_player.get_camera(), _player)
	_player.set_carry_controller(_carry)


func _spawn_props() -> void:
	# Just ONE barrel, light enough to hold. Placed at eye level in front.
	_spawn_prop("barrel", Vector3(0, 0.5, 0), &"misc",
		FakeRecord.new("barrel_audit_01", "Audit Barrel", 5.0),
		Vector3(0.4, 0.5, 0.4), Color(0.55, 0.35, 0.20))


func _spawn_prop(label: String, pos: Vector3, type_name: StringName,
		record: Variant, mesh_size: Vector3, color: Color) -> void:
	var instance := _build_fake_prop(label, mesh_size, color)
	instance.position = pos
	add_child(instance)
	var mass: float = CarryableRegistryScript.get_mass(type_name, record)
	var rb := CarryableBodyFactoryScript.convert_static_to_rigid(
		instance, mass, StringName(record.record_id), record.name, PickupInteractableScript)
	if rb == null:
		push_error("[carry audit] factory returned null for %s" % label)


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
	# Sharp contrasting stripes make per-frame micro-vibration visible
	# to the naked eye — any 1-pixel wobble is obvious against the stripe edges.
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
# Telemetry logger wiring
# ----------------------------------------------------------------------------

func _build_logger() -> void:
	_logger = CarryTelemetryLoggerScript.new()
	_logger.name = "CarryTelemetryLogger"
	_logger.player = _player
	_logger.camera_pivot = _player.camera_pivot
	_logger.spring_arm = _player.spring_arm
	_logger.camera = _player.get_camera()
	_logger.marker = _carry.get_hold_target_marker()
	_logger.carry = _carry
	# Parent to the scene root — priority=1000 guarantees it samples AFTER
	# carry_controller has written the body this frame.
	add_child(_logger)


# ----------------------------------------------------------------------------
# Walking — copy of the I.4 pattern (test-scene-owned movement loop)
# ----------------------------------------------------------------------------

const WALK_SPEED: float = 4.0
const GRAVITY: float = 18.0
const JUMP_VELOCITY: float = 6.0


func _physics_process(delta: float) -> void:
	if _player == null:
		return
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

	# Scripted camera oscillation (F7 toggle) for reproducible vibration
	# without needing a human moving the mouse. 0.6 rad amplitude, 1 Hz,
	# full sinusoid — both axes clean for spectrum analysis.
	if _auto_wiggle:
		_auto_wiggle_time += delta
		var yaw := sin(_auto_wiggle_time * TAU * 1.0) * 0.6
		_player.camera_pivot.rotation.y = yaw
		var pitch := sin(_auto_wiggle_time * TAU * 0.5) * 0.2
		_player.camera_pivot.rotation.x = pitch

	_player.move_and_slide()


# ----------------------------------------------------------------------------
# HUD
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
	_hud_prompt_label.offset_left = -250
	_hud_prompt_label.offset_right = 250
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
	_hud_help_label.offset_top = -200
	_hud_help_label.offset_right = 720
	_hud_help_label.offset_bottom = -16
	_hud_help_label.add_theme_font_size_override("font_size", 13)
	_hud_help_label.add_theme_color_override("font_color", Color(0.75, 0.80, 0.90))
	_hud_help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hud_help_label.text = (
		"carry vibration audit — WASD walk · mouse look · E hold to grab the barrel\n"
		+ "F1: cycle physics tick rate (60/120/144)\n"
		+ "F2: cycle held body interpolation mode (OFF/ON/INHERIT)\n"
		+ "F3: toggle SpringArm3D collision raycast (on/off)\n"
		+ "F4: dump telemetry CSV to user://carry_vibration_audit_<ts>.csv\n"
		+ "F5: toggle SNAP mode (bypass lerp, body locked to target)\n"
		+ "F6: clear telemetry buffer\n"
		+ "F7: toggle scripted camera wiggle (reproducible motion)\n"
		+ "esc: release mouse · click to recapture"
	)
	layer.add_child(_hud_help_label)


func _process(_delta: float) -> void:
	# Snap mode: after CarryController._process (priority 0) has written
	# its lerp chase, directly force the held body to the composed target
	# — bypassing the lerp. Runs here (priority 500) before the logger
	# (priority 1000) samples, so the logger sees the post-snap position.
	# Defensive is_instance_valid checks in case shutdown is in progress.
	if (_snap_mode
			and _carry != null and is_instance_valid(_carry)
			and _carry.has_method("is_carrying") and _carry.is_carrying()):
		var held: RigidBody3D = _carry.get_held_body()
		if held != null and is_instance_valid(held) and _logger != null and is_instance_valid(_logger):
			var target: Vector3 = _logger._compose_target_same_as_carry()
			if target.is_finite():
				held.global_position = target

	_refresh_stats_label()


## Scene-level shutdown hardening: stop frame callbacks + null refs so
## the HUD refresh can't try to read freed nodes mid-teardown. Same rule
## as `CarryTelemetryLogger._exit_tree` — any object that holds cross-
## subsystem refs nulls them in exit_tree.
func _exit_tree() -> void:
	set_physics_process(false)
	set_process(false)
	_logger = null
	_carry = null
	_player = null
	_raycaster = null


func _refresh_stats_label() -> void:
	if _hud_stats_label == null or not is_instance_valid(_hud_stats_label):
		return
	if _logger == null or not is_instance_valid(_logger):
		return
	var phys_stats: Dictionary = _logger.compute_jitter_stats(CarryTelemetryLoggerScript.SampleSource.PHYS, 200)
	var rend_stats: Dictionary = _logger.compute_jitter_stats(CarryTelemetryLoggerScript.SampleSource.REND, 200)
	var held_str: String = "no"
	var chase_lag_mm: float = NAN
	if (_carry != null and is_instance_valid(_carry)
			and _carry.has_method("is_carrying") and _carry.is_carrying()):
		held_str = "yes"
		var held: RigidBody3D = _carry.get_held_body()
		if held != null and is_instance_valid(held):
			var target: Vector3 = _logger._compose_target_same_as_carry()
			if target.is_finite():
				chase_lag_mm = held.global_position.distance_to(target) * 1000.0
	var fps: float = Engine.get_frames_per_second()
	var phys_hz: int = Engine.physics_ticks_per_second
	var pif: float = Engine.get_physics_interpolation_fraction()
	_hud_stats_label.text = (
		"[tick %d Hz · fps %d · phys_interp_fraction %.3f]\n" % [phys_hz, int(fps), pif]
		+ "held body: %s · chase lag: %.2f mm\n\n" % [held_str, chase_lag_mm]
		+ "per-sample Δ stats (last 200 samples, micro-meters)\n"
		+ "PHYS samples (n=%d)\n" % int(phys_stats.get("n", 0))
		+ "  body  Δ max %.3f mm · rms %.3f mm\n" % [phys_stats.get("max_dpos_mm", NAN), phys_stats.get("rms_dpos_mm", NAN)]
		+ "  target Δ max %.3f mm · rms %.3f mm\n" % [phys_stats.get("max_target_dpos_mm", NAN), phys_stats.get("rms_target_dpos_mm", NAN)]
		+ "REND samples (n=%d)\n" % int(rend_stats.get("n", 0))
		+ "  body  Δ max %.3f mm · rms %.3f mm\n" % [rend_stats.get("max_dpos_mm", NAN), rend_stats.get("rms_dpos_mm", NAN)]
		+ "  target Δ max %.3f mm · rms %.3f mm\n\n" % [rend_stats.get("max_target_dpos_mm", NAN), rend_stats.get("rms_target_dpos_mm", NAN)]
		+ "rubric:\n"
		+ "  body Δ rms >> target Δ rms → lerp is amplifying jitter\n"
		+ "  target Δ rms > 0.5 mm     → composition input is jittering\n"
		+ "  PHYS body Δ >> REND body Δ → body writes at tick rate only\n"
		+ "  both ≈ 0 in snap mode      → lerp isn't the root cause"
	)


func _refresh_toggles_label() -> void:
	if _hud_toggles_label == null:
		return
	var interp_str: String = "UNKNOWN"
	match BODY_INTERP_MODES[_body_interp_mode_index]:
		Node.PHYSICS_INTERPOLATION_MODE_OFF: interp_str = "OFF (render-rate live writes)"
		Node.PHYSICS_INTERPOLATION_MODE_ON: interp_str = "ON (engine smoothing forced on)"
		Node.PHYSICS_INTERPOLATION_MODE_INHERIT: interp_str = "INHERIT (follows project setting)"
	_hud_toggles_label.text = (
		"toggles\n"
		+ "  tick rate:   %d Hz\n" % TICK_RATES[_tick_rate_index]
		+ "  body interp: %s\n" % interp_str
		+ "  spring arm:  %s\n" % ("collide ON (mask=1)" if _spring_arm_collide else "collide OFF (mask=0)")
		+ "  snap mode:   %s\n" % ("ON (no lerp)" if _snap_mode else "off")
		+ "  auto-wiggle: %s\n" % ("ON (1 Hz yaw)" if _auto_wiggle else "off")
	)


# ----------------------------------------------------------------------------
# Input — diagnostic toggles (F1-F7)
# ----------------------------------------------------------------------------

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
		KEY_F2:
			_body_interp_mode_index = (_body_interp_mode_index + 1) % BODY_INTERP_MODES.size()
			_apply_body_interp_mode()
			_refresh_toggles_label()
			get_viewport().set_input_as_handled()
		KEY_F3:
			_spring_arm_collide = not _spring_arm_collide
			_apply_spring_arm_collision()
			_refresh_toggles_label()
			get_viewport().set_input_as_handled()
		KEY_F4:
			_dump_csv()
			get_viewport().set_input_as_handled()
		KEY_F5:
			_snap_mode = not _snap_mode
			_refresh_toggles_label()
			Log.info("interaction", "[carry audit] snap mode = %s" % _snap_mode)
			get_viewport().set_input_as_handled()
		KEY_F6:
			if _logger != null:
				_logger.clear_samples()
				Log.info("interaction", "[carry audit] telemetry buffer cleared")
			get_viewport().set_input_as_handled()
		KEY_F7:
			_auto_wiggle = not _auto_wiggle
			_auto_wiggle_time = 0.0
			if not _auto_wiggle:
				# Restore manual camera rotation to current mouse-look
				# (zero — so user's mouse regains control from center).
				pass
			_refresh_toggles_label()
			Log.info("interaction", "[carry audit] auto wiggle = %s" % _auto_wiggle)
			get_viewport().set_input_as_handled()


func _apply_tick_rate() -> void:
	Engine.physics_ticks_per_second = TICK_RATES[_tick_rate_index]
	Log.info("interaction",
		"[carry audit] physics tick rate -> %d Hz" % TICK_RATES[_tick_rate_index])


func _apply_body_interp_mode() -> void:
	if _carry == null or not _carry.has_method("get_held_body"):
		return
	var held: RigidBody3D = _carry.get_held_body()
	var mode: int = BODY_INTERP_MODES[_body_interp_mode_index]
	if held != null and is_instance_valid(held):
		held.physics_interpolation_mode = mode
		held.reset_physics_interpolation()
	Log.info("interaction",
		"[carry audit] body interpolation mode -> %d" % mode)


func _apply_spring_arm_collision() -> void:
	if _player == null or _player.spring_arm == null:
		return
	_player.spring_arm.collision_mask = 1 if _spring_arm_collide else 0
	Log.info("interaction",
		"[carry audit] spring_arm.collision_mask -> %d"
		% _player.spring_arm.collision_mask)


func _dump_csv() -> void:
	if _logger == null:
		return
	var ts: String = Time.get_datetime_string_from_system(true).replace(":", "-")
	var path: String = "user://carry_vibration_audit_%s.csv" % ts
	var err: int = _logger.export_csv(path)
	if err != OK:
		Log.error("interaction", "[carry audit] CSV export failed: %d" % err)
		return
	var abs_path: String = ProjectSettings.globalize_path(path)
	Log.info("interaction",
		"[carry audit] CSV dumped (%d samples) -> %s" % [_logger.sample_count(), abs_path])
	# Flash the prompt so the tester sees it landed.
	if _hud_prompt_label != null:
		_hud_prompt_label.text = "CSV -> %s" % abs_path
		get_tree().create_timer(3.0).timeout.connect(func() -> void:
			if _hud_prompt_label != null:
				_hud_prompt_label.text = "")


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
	Log.debug("interaction", "[carry audit] interact_tap")


func _on_interact_hold_begin() -> void:
	Log.info("interaction", "[carry audit] interact_hold_begin -> grab")


func _on_interact_release() -> void:
	Log.info("interaction", "[carry audit] interact_release -> drop/throw")


## Window close handler — flush the telemetry CSV to disk BEFORE the
## scene tree starts tearing down. Godot's shutdown path has historically
## been flaky when a held physics body is mid-chase (see §17.3 sig 11
## lineage) and the deferred-queue drain can race cell cleanup. Dumping
## the CSV on WM_CLOSE_REQUEST guarantees the data survives even if the
## subsequent teardown crashes.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_dump_csv_silent_on_exit()


func _dump_csv_silent_on_exit() -> void:
	if _logger == null or not is_instance_valid(_logger):
		return
	if _logger.sample_count() == 0:
		return
	var ts: String = Time.get_datetime_string_from_system(true).replace(":", "-")
	var path: String = "user://carry_vibration_audit_exit_%s.csv" % ts
	var err: int = _logger.export_csv(path)
	if err == OK:
		Log.info("interaction",
			"[carry audit] auto-dumped %d samples on exit -> %s"
			% [_logger.sample_count(), ProjectSettings.globalize_path(path)])
