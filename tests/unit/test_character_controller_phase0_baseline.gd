## Phase 0 baseline tests for the player character controller.
##
## Purpose:
## - Give later implementation phases a small, fast harness around the
##   controller's movement-input seams.
## - Document current behavior explicitly, including defects already fixed by
##   the controller productionization phases.
## - Avoid loading Morrowind data, scenes, meshes, or animation libraries so
##   failures point at controller logic instead of asset availability.
##
## Important convention:
## This suite started as a baseline for the controller audit. When a phase fixes
## one of those findings, the matching assertion becomes the new contract.
extends GdUnitTestSuite

const InputPackageScript := preload("res://src/core/character/controller/input_package.gd")
const CharacterMovementConfigScript := preload("res://src/core/character/controller/character_movement_config.gd")
const DefaultMovementConfigResource := preload("res://src/core/character/controller/movement_presets/default_movement_config.tres")
const MorrowindMovementConfigResource := preload("res://src/core/character/controller/movement_presets/morrowind_movement_config.tres")
const PlayerInputGathererScript := preload("res://src/core/character/controller/player_input_gatherer.gd")
const MoveContainerScript := preload("res://src/core/character/controller/move_container.gd")
const MovementStateScript := preload("res://src/core/character/controller/movement_state.gd")
const CharacterMotorScript := preload("res://src/core/character/character_motor.gd")
const PlayerControllerScript := preload("res://src/core/player/player_controller.gd")
const InteractionRaycasterScript := preload("res://src/core/interaction/interaction_raycaster.gd")
const InteractionIntentScript := preload("res://src/core/interaction/interaction_intent.gd")
const CarryControllerScript := preload("res://src/core/interaction/carry_controller.gd")
const GameplayPhysicsLayersScript := preload("res://src/core/physics/gameplay_physics_layers.gd")
const InputActionsScript := preload("res://src/core/input/input_actions.gd")
const AnimationManagerScript := preload("res://src/core/animation/animation_manager.gd")
const MoveScript := preload("res://src/core/character/controller/move.gd")
const IdleMoveScript := preload("res://src/core/character/controller/moves/idle_move.gd")
const WalkMoveScript := preload("res://src/core/character/controller/moves/walk_move.gd")
const RunMoveScript := preload("res://src/core/character/controller/moves/run_move.gd")
const SprintMoveScript := preload("res://src/core/character/controller/moves/sprint_move.gd")
const JumpMoveScript := preload("res://src/core/character/controller/moves/jump_move.gd")
const MidairMoveScript := preload("res://src/core/character/controller/moves/midair_move.gd")
const CrouchMoveScript := preload("res://src/core/character/controller/moves/crouch_move.gd")
const SwimIdleMoveScript := preload("res://src/core/character/controller/moves/swim_idle_move.gd")
const SwimMoveScript := preload("res://src/core/character/controller/moves/swim_move.gd")
const StepSolverScene := preload("res://tests/visual/test_character_controller_steps.tscn")
const CarryPromptSuppressionScene := preload("res://tests/visual/test_carry_prompt_suppression.tscn")
const TeleportInterpolationResetScene := preload("res://tests/visual/test_teleport_interpolation_reset.tscn")
const CharacterControllerVisualScene := preload("res://tests/visual/test_character_controller.tscn")

const TEST_ACTIONS: Array[StringName] = [
	&"move_forward",
	&"move_backward",
	&"move_left",
	&"move_right",
	&"jump",
	&"crouch",
	&"sprint",
	&"walk",
	&"camera_vanity",
]


## Test seam for Phase 1.
## This spy replaces the physics-heavy movement body with a tiny version,
## letting the push pass be measured without constructing a live 3D collision
## scenario.
class CountingMoveContainer extends MoveContainer:
	var push_count: int = 0
	var last_step_delta: float = -1.0
	var last_push_delta: float = -1.0

	func _move_with_step_up(delta: float) -> void:
		last_step_delta = delta

	func _push_rigid_bodies(delta: float) -> void:
		last_push_delta = delta
		push_count += 1


class ResetNotificationSpy extends Node:
	var reset_count: int = 0

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESET_PHYSICS_INTERPOLATION:
			reset_count += 1


class FakeAnimationManager extends Node:
	var transitioned_state: StringName = &""
	var transition_force: bool = false
	var blend_parameters: Dictionary[StringName, Variant] = {}

	func transition_to(state: StringName, force: bool = false) -> void:
		transitioned_state = state
		transition_force = force

	func set_blend_parameter(name: StringName, value: Variant) -> void:
		blend_parameters[name] = value


class RejectingAnimationManager extends Node:
	var transition_calls: Array[StringName] = []
	var accept_transition: bool = false

	func transition_to(state: StringName, _force: bool = false) -> bool:
		transition_calls.append(state)
		return accept_transition

	func set_blend_parameter(_name: StringName, _value: Variant) -> void:
		pass


func before_test() -> void:
	_release_test_actions()


func after_test() -> void:
	_release_test_actions()


# --- MoveContainer baseline -------------------------------------------------

func test_process_runs_one_push_pass_after_movement() -> void:
	var mc := CountingMoveContainer.new()
	add_child(mc)
	auto_free(mc)

	var player := CharacterBody3D.new()
	add_child(player)
	auto_free(player)
	mc.player = player

	var idle := MoveScript.new()
	idle.move_name = &"idle"
	mc.add_child(idle)
	mc.accept_moves()

	var pkg := InputPackageScript.new() as InputPackage
	mc.process(pkg, 1.0 / 60.0)

	assert_int(mc.push_count).is_equal(1)
	assert_float(mc.last_step_delta).is_equal_approx(1.0 / 60.0, 0.0001)
	assert_float(mc.last_push_delta).is_equal_approx(1.0 / 60.0, 0.0001)


# --- Move priority baseline -------------------------------------------------

func test_moving_crouch_resolves_to_crouch() -> void:
	var mc := _make_locomotion_container()
	var idle := mc.get_move(&"idle")
	var pkg := _make_input_package([&"idle", &"run", &"crouch"])

	var chosen := idle.best_input_that_can_be_paid(pkg)

	assert_str(str(chosen)).is_equal("crouch")


func test_sprint_priority_beats_default_run() -> void:
	var mc := _make_locomotion_container()
	var idle := mc.get_move(&"idle")
	var pkg := _make_input_package([&"idle", &"run", &"sprint"])

	var chosen := idle.best_input_that_can_be_paid(pkg)

	assert_str(str(chosen)).is_equal("sprint")


func test_jump_priority_beats_sprint_and_run() -> void:
	var mc := _make_locomotion_container()
	var idle := mc.get_move(&"idle")
	var pkg := _make_input_package([&"idle", &"run", &"sprint", &"jump"])

	var chosen := idle.best_input_that_can_be_paid(pkg)

	assert_str(str(chosen)).is_equal("jump")


# --- Input gatherer baseline ------------------------------------------------

func test_forward_input_defaults_to_run_action() -> void:
	var gatherer := _make_gatherer()
	Input.action_press(&"move_forward")

	var pkg := gatherer.gather_input()

	assert_bool(pkg.actions.has(&"idle")).is_true()
	assert_bool(pkg.actions.has(&"run")).is_true()
	assert_bool(pkg.actions.has(&"walk")).is_false()
	assert_vector(pkg.input_direction).is_equal(Vector2(0.0, -1.0))


func test_sprint_is_added_only_on_top_of_movement() -> void:
	var gatherer := _make_gatherer()
	Input.action_press(&"sprint")

	var standing_pkg := gatherer.gather_input()
	assert_bool(standing_pkg.actions.has(&"sprint")).is_false()

	Input.action_press(&"move_forward")
	var moving_pkg := gatherer.gather_input()
	assert_bool(moving_pkg.actions.has(&"run")).is_true()
	assert_bool(moving_pkg.actions.has(&"sprint")).is_true()


func test_walk_action_is_intentionally_unbound() -> void:
	assert_bool(InputMap.has_action(&"walk")).is_true()

	assert_int(InputMap.action_get_events(&"walk").size()).is_equal(0)


func test_input_gatherer_uses_explicit_movement_basis_provider() -> void:
	var gatherer := _make_gatherer()
	var pivot := Node3D.new()
	add_child(pivot)
	auto_free(pivot)
	gatherer.camera_pivot = pivot
	gatherer.set_movement_reference_providers(
		Callable(self, "_test_actor_forward_basis"),
		Callable(self, "_test_flat_movement_pitch"))

	pivot.rotation.y = PI
	Input.action_press(&"move_forward")

	var pkg := gatherer.gather_input()
	var world_forward := (pkg.movement_basis * Vector3(0.0, 0.0, -1.0)).normalized()
	var legacy_world_forward := (pkg.camera_basis * Vector3(0.0, 0.0, -1.0)).normalized()

	assert_vector(world_forward).is_equal(Vector3(0.0, 0.0, -1.0))
	assert_vector(legacy_world_forward).is_equal(Vector3(0.0, 0.0, -1.0))


func test_move_container_resolves_direction_from_movement_basis_not_camera_alias() -> void:
	var mc := _make_locomotion_container()
	var pkg := _make_input_package([&"idle", &"run"])
	pkg.input_direction = Vector2(0.0, -1.0)
	pkg.movement_basis = Basis.IDENTITY
	pkg.camera_basis = Basis(Vector3.UP, PI)

	var desired := mc._resolve_desired_world_direction(pkg)

	assert_vector(desired).is_equal(Vector3(0.0, 0.0, -1.0))


func test_swim_pitch_uses_water_context_during_input_gather() -> void:
	var gatherer := _make_gatherer()
	var pivot := Node3D.new()
	add_child(pivot)
	auto_free(pivot)
	gatherer.camera_pivot = pivot

	pivot.rotation.x = -0.5
	Input.action_press(&"move_forward")

	var pkg := gatherer.gather_input(true, 0.0)

	assert_float(pkg.vertical_input).is_greater(0.0)


func test_swim_pitch_can_use_explicit_movement_pitch_provider() -> void:
	var gatherer := _make_gatherer()
	var pivot := Node3D.new()
	add_child(pivot)
	auto_free(pivot)
	gatherer.camera_pivot = pivot
	gatherer.set_movement_reference_providers(
		Callable(self, "_test_actor_forward_basis"),
		Callable(self, "_test_upward_swim_pitch"))

	pivot.rotation.x = 0.0
	Input.action_press(&"move_forward")

	var pkg := gatherer.gather_input(true, 0.0)

	assert_float(pkg.movement_pitch).is_equal_approx(-0.5, 0.001)
	assert_float(pkg.vertical_input).is_greater(0.0)


func test_third_person_movement_basis_uses_character_facing_not_camera_pivot() -> void:
	var player := PlayerControllerScript.new() as PlayerController
	add_child(player)
	auto_free(player)

	var character_root := Node3D.new()
	player.attach_character(character_root, null)
	player.set_camera_mode(PlayerController.CameraMode.THIRD_PERSON)

	character_root.rotation.y = 0.0
	player.camera_pivot.rotation.y = PI

	var world_forward := (player._get_movement_basis() * Vector3(0.0, 0.0, -1.0)).normalized()

	assert_vector(world_forward).is_equal(Vector3(0.0, 0.0, -1.0))


func test_third_person_look_yaw_turns_facing_and_syncs_camera_follow() -> void:
	var player := PlayerControllerScript.new() as PlayerController
	add_child(player)
	auto_free(player)

	var character_root := Node3D.new()
	player.attach_character(character_root, null)
	player.set_camera_mode(PlayerController.CameraMode.THIRD_PERSON)

	character_root.rotation.y = 0.0
	player.camera_pivot.rotation.y = PI
	player._apply_look_delta(0.4, -0.2)

	assert_float(character_root.rotation.y).is_equal_approx(0.4, 0.001)
	assert_float(player.camera_pivot.rotation.y).is_equal_approx(character_root.rotation.y, 0.001)
	assert_float(player.camera_pivot.rotation.x).is_equal_approx(-0.2, 0.001)


func test_player_controller_left_right_input_strafes_without_turning_facing() -> void:
	var source_config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	source_config.turn_to_movement_direction = true
	source_config.run_speed = 5.0
	source_config.ground_tracking_angular_speed = 20.0

	var player := PlayerControllerScript.new() as PlayerController
	player.movement_config = source_config
	add_child(player)
	auto_free(player)

	var character_root := Node3D.new()
	player.attach_character(character_root, null)

	var run := player.get_movement_motor().get_move_container().get_move(&"run")
	var pkg := _make_input_package([&"idle", &"run"])
	pkg.input_direction = Vector2(-1.0, 0.0)
	pkg.movement_basis = player._get_movement_basis()

	character_root.rotation.y = 0.0
	run._update(pkg, 1.0 / 60.0)

	assert_bool(source_config.turn_to_movement_direction).is_true()
	assert_bool(player.get_movement_config().turn_to_movement_direction).is_false()
	assert_float(character_root.rotation.y).is_equal_approx(0.0, 0.001)
	assert_float(player.velocity.x).is_equal_approx(-5.0, 0.001)
	assert_float(player.velocity.z).is_equal_approx(0.0, 0.001)


func test_camera_vanity_orbits_without_changing_movement_basis() -> void:
	var player := PlayerControllerScript.new() as PlayerController
	add_child(player)
	auto_free(player)

	var character_root := Node3D.new()
	player.attach_character(character_root, null)
	player.set_camera_mode(PlayerController.CameraMode.THIRD_PERSON)

	character_root.rotation.y = 0.0
	player.camera_pivot.rotation.y = 0.0
	player.begin_camera_vanity()
	player._apply_look_delta(PI, 0.25)

	var world_forward := (player._get_movement_basis() * Vector3(0.0, 0.0, -1.0)).normalized()

	assert_int(player.camera_mode).is_equal(PlayerController.CameraMode.THIRD_PERSON_VANITY)
	assert_float(character_root.rotation.y).is_equal_approx(0.0, 0.001)
	assert_float(player.camera_pivot.rotation.y).is_equal_approx(PI, 0.001)
	assert_vector(world_forward).is_equal(Vector3(0.0, 0.0, -1.0))


func test_camera_vanity_release_returns_to_primary_mode() -> void:
	var player := PlayerControllerScript.new() as PlayerController
	add_child(player)
	auto_free(player)

	var character_root := Node3D.new()
	player.attach_character(character_root, null)
	player.set_camera_mode(PlayerController.CameraMode.FIRST_PERSON)

	player.begin_camera_vanity()
	assert_int(player.camera_mode).is_equal(PlayerController.CameraMode.THIRD_PERSON_VANITY)

	player.end_camera_vanity()

	assert_int(player.camera_mode).is_equal(PlayerController.CameraMode.FIRST_PERSON)


func test_camera_vanity_pitch_does_not_change_swim_movement_pitch() -> void:
	var player := PlayerControllerScript.new() as PlayerController
	add_child(player)
	auto_free(player)

	var character_root := Node3D.new()
	player.attach_character(character_root, null)
	player.set_camera_mode(PlayerController.CameraMode.THIRD_PERSON)
	player._apply_look_delta(0.0, -0.25)

	player.begin_camera_vanity()
	player._apply_look_delta(0.0, 0.75)

	assert_float(player._get_movement_pitch()).is_equal_approx(-0.25, 0.001)
	assert_float(player.camera_pivot.rotation.x).is_equal_approx(0.5, 0.001)


func test_camera_vanity_action_is_required_input_action() -> void:
	assert_bool(InputActionsScript.CAMERA.has(&"camera_vanity")).is_true()
	assert_bool(InputActionsScript.REQUIRED_ACTIONS.has(&"camera_vanity")).is_true()
	assert_bool(InputMap.has_action(&"camera_vanity")).is_true()
	for event in InputMap.action_get_events(&"camera_vanity"):
		assert_bool(event is InputEventKey).is_false()


func test_camera_tab_tap_toggles_first_and_third_person() -> void:
	var player := PlayerControllerScript.new() as PlayerController
	add_child(player)
	auto_free(player)

	var character_root := Node3D.new()
	player.attach_character(character_root, null)
	player.set_camera_mode(PlayerController.CameraMode.THIRD_PERSON)

	player._on_camera_mode_pressed(1000)
	player._on_camera_mode_released(1050)
	assert_int(player.camera_mode).is_equal(PlayerController.CameraMode.FIRST_PERSON)

	player._on_camera_mode_pressed(1100)
	player._on_camera_mode_released(1150)
	assert_int(player.camera_mode).is_equal(PlayerController.CameraMode.THIRD_PERSON)


func test_camera_tab_hold_enters_vanity_then_returns_to_third_person() -> void:
	var player := PlayerControllerScript.new() as PlayerController
	add_child(player)
	auto_free(player)

	var character_root := Node3D.new()
	player.attach_character(character_root, null)
	player.set_camera_mode(PlayerController.CameraMode.THIRD_PERSON)

	player._on_camera_mode_pressed(1000)
	player._poll_camera_mode_hold(1000 + int(InteractionIntentScript.DEFAULT_HOLD_THRESHOLD * 1000.0))

	assert_int(player.camera_mode).is_equal(PlayerController.CameraMode.THIRD_PERSON_VANITY)

	player._on_camera_mode_released(1300)

	assert_int(player.camera_mode).is_equal(PlayerController.CameraMode.THIRD_PERSON)


func test_camera_tab_hold_from_first_person_enters_vanity_then_returns_to_first_person() -> void:
	var player := PlayerControllerScript.new() as PlayerController
	add_child(player)
	auto_free(player)

	var character_root := Node3D.new()
	player.attach_character(character_root, null)
	player.set_camera_mode(PlayerController.CameraMode.FIRST_PERSON)

	player._on_camera_mode_pressed(1000)
	player._poll_camera_mode_hold(1000 + int(InteractionIntentScript.DEFAULT_HOLD_THRESHOLD * 1000.0))

	assert_int(player.camera_mode).is_equal(PlayerController.CameraMode.THIRD_PERSON_VANITY)

	player._on_camera_mode_released(1300)

	assert_int(player.camera_mode).is_equal(PlayerController.CameraMode.FIRST_PERSON)


func test_directional_ground_animation_state_uses_lateral_input() -> void:
	var mc := _make_locomotion_container()
	mc.switch_to(&"run")
	var pkg := _make_input_package([&"idle", &"run"])

	pkg.input_direction = Vector2(-1.0, 0.0)
	assert_str(str(mc._resolve_animation_state(pkg))).is_equal("RunLeft")

	pkg.input_direction = Vector2(1.0, 0.0)
	assert_str(str(mc._resolve_animation_state(pkg))).is_equal("RunRight")


func test_directional_ground_animation_state_preserves_diagonal_intent() -> void:
	var mc := _make_locomotion_container()
	mc.switch_to(&"run")
	var pkg := _make_input_package([&"idle", &"run"])

	pkg.input_direction = Vector2(-1.0, -1.0)
	assert_str(str(mc._resolve_animation_state(pkg))).is_equal("RunForwardLeft")

	pkg.input_direction = Vector2(1.0, 1.0)
	assert_str(str(mc._resolve_animation_state(pkg))).is_equal("RunBackRight")


func test_directional_crouch_animation_state_uses_sneak_cardinals() -> void:
	var mc := _make_locomotion_container()
	mc.switch_to(&"crouch")
	var pkg := _make_input_package([&"idle", &"run", &"crouch"])

	pkg.input_direction = Vector2(-1.0, 0.0)
	assert_str(str(mc._resolve_animation_state(pkg))).is_equal("SneakLeft")

	pkg.input_direction = Vector2(1.0, 1.0)
	assert_str(str(mc._resolve_animation_state(pkg))).is_equal("SneakBackRight")


func test_directional_swim_animation_state_uses_cardinal_groups() -> void:
	var mc := _make_locomotion_container()
	mc.switch_to(&"swim")
	var pkg := _make_input_package([&"idle", &"run"])

	pkg.input_direction = Vector2(-1.0, 0.0)
	assert_str(str(mc._resolve_animation_state(pkg))).is_equal("SwimWalkLeft")

	pkg.actions.append(&"sprint")
	pkg.input_direction = Vector2(1.0, -1.0)
	assert_str(str(mc._resolve_animation_state(pkg))).is_equal("SwimRunForwardRight")


func test_swim_jump_is_impulse_intent_not_vertical_axis() -> void:
	var gatherer := _make_gatherer()
	Input.action_press(&"jump")

	var pkg := gatherer.gather_input(true, 0.0)

	assert_bool(pkg.swim_jump_held).is_true()
	assert_float(pkg.vertical_input).is_equal_approx(0.0, 0.001)
	assert_bool(pkg.actions.has(&"jump")).is_false()


func test_midair_reenters_swim_when_water_context_returns() -> void:
	var mc := _make_locomotion_container()
	mc.switch_to(&"midair")

	var pkg := _make_input_package([&"idle", &"run"])
	pkg.is_in_water = true
	pkg.water_surface_y = 0.0
	pkg.input_direction = Vector2(0.0, -1.0)

	mc.process(pkg, 1.0 / 60.0)
	assert_str(str(mc.get_current_move_name())).is_equal("swim_idle")

	mc.process(pkg, 1.0 / 60.0)
	var state := mc.get_movement_state()

	assert_str(str(state.active_move_name)).is_equal("swim")
	assert_str(str(state.animation_state)).is_equal("SwimForward")
	assert_str(str(state.posture)).is_equal("swimming")
	assert_bool(state.is_swimming).is_true()


func test_swim_surface_clamp_keeps_player_submerged() -> void:
	var mc := _make_locomotion_container()
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	config.swim_speed = 3.5
	config.swim_acceleration = 20.0
	config.swim_buoyancy_strength = 4.0
	config.swim_min_feet_submersion = 0.35
	mc.set_movement_config(config)

	var pkg := _make_input_package([&"idle", &"run"])
	pkg.is_in_water = true
	pkg.water_surface_y = 0.0
	pkg.input_direction = Vector2(0.0, -1.0)
	pkg.vertical_input = 1.0

	mc.player.global_position.y = -0.2
	mc.player.velocity.y = 3.0
	var swim := mc.get_move(&"swim")
	swim._update(pkg, 1.0 / 60.0)

	assert_float(mc.player.velocity.y).is_less_equal(0.0)


func test_held_swim_jump_repeats_as_impulse_after_cooldown() -> void:
	var mc := _make_locomotion_container()
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	config.swim_speed = 0.0
	config.swim_acceleration = 20.0
	config.swim_buoyancy_strength = 0.0
	config.swim_jump_velocity = 2.5
	config.swim_jump_repeat_time = 0.2
	config.swim_min_feet_submersion = 0.0
	mc.set_movement_config(config)

	var pkg := _make_input_package([&"idle", &"run"])
	pkg.is_in_water = true
	pkg.water_surface_y = 10.0
	pkg.swim_jump_held = true

	var swim := mc.get_move(&"swim")
	swim._on_enter_state()
	mc.player.velocity.y = 0.0
	swim._update(pkg, 0.016)
	assert_float(mc.player.velocity.y).is_equal_approx(2.5, 0.001)

	mc.player.velocity.y = 0.0
	swim._update(pkg, 0.1)
	assert_float(mc.player.velocity.y).is_equal_approx(0.0, 0.001)

	swim._update(pkg, 0.1)
	assert_float(mc.player.velocity.y).is_equal_approx(2.5, 0.001)


# --- Movement config contracts ----------------------------------------------

func test_movement_config_presets_load() -> void:
	assert_bool(DefaultMovementConfigResource is CharacterMovementConfig).is_true()
	assert_bool(MorrowindMovementConfigResource is CharacterMovementConfig).is_true()
	assert_bool(MorrowindMovementConfigResource.swim_upward_correction_enabled).is_false()


func test_movement_config_status_table_covers_exported_fields() -> void:
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	var statuses := CharacterMovementConfig.get_exported_field_statuses()
	var missing: Array[StringName] = []

	for property: Dictionary in config.get_property_list():
		var usage := int(property.get("usage", 0))
		if (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		if (usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		var field_name := StringName(str(property.get("name", "")))
		if not statuses.has(field_name):
			missing.append(field_name)

	assert_int(missing.size()).is_equal(0)
	assert_str(str(CharacterMovementConfig.get_exported_field_status(&"turn_to_movement_direction"))).is_equal("active")
	assert_str(str(CharacterMovementConfig.get_exported_field_status(&"step_down_height"))).is_equal("active")
	assert_str(str(CharacterMovementConfig.get_exported_field_status(&"min_step_height"))).is_equal("active")
	assert_str(str(CharacterMovementConfig.get_exported_field_status(&"smooth_movement"))).is_equal("reserved")
	assert_str(str(CharacterMovementConfig.get_exported_field_status(&"smooth_player_turning_delay"))).is_equal("reserved")
	assert_str(str(CharacterMovementConfig.get_exported_field_status(&"swim_upward_correction_enabled"))).is_equal("reserved")
	assert_str(str(CharacterMovementConfig.get_exported_field_status(&"swim_upward_coef"))).is_equal("reserved")

func test_movement_config_controls_run_speed() -> void:
	var mc := _make_locomotion_container()
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	config.run_speed = 11.0
	config.run_turn_speed = 11.0
	config.ground_tracking_angular_speed = 20.0
	mc.set_movement_config(config)

	var run := mc.get_move(&"run")
	var pkg := _make_input_package([&"idle", &"run"])
	pkg.input_direction = Vector2(0.0, -1.0)
	run._update(pkg, 1.0 / 60.0)

	assert_float(absf(mc.player.velocity.z)).is_equal_approx(11.0, 0.001)


func test_turn_to_movement_direction_false_prevents_auto_turning() -> void:
	var mc := _make_locomotion_container()
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	config.turn_to_movement_direction = false
	config.run_speed = 6.0
	config.backward_angle_degrees = 170.0
	mc.set_movement_config(config)

	var run := mc.get_move(&"run")
	var pkg := _make_input_package([&"idle", &"run"])
	pkg.input_direction = Vector2(1.0, 0.0)
	run._update(pkg, 1.0 / 60.0)

	assert_float(mc.character_root.rotation.y).is_equal_approx(0.0, 0.001)
	assert_float(mc.player.velocity.x).is_equal_approx(6.0, 0.001)
	assert_float(mc.player.velocity.z).is_equal_approx(0.0, 0.001)


func test_movement_config_controls_jump_velocity() -> void:
	var mc := _make_locomotion_container()
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	config.jump_velocity = 9.25
	mc.set_movement_config(config)

	var jump := mc.get_move(&"jump")
	jump._on_enter_state()

	assert_float(mc.player.velocity.y).is_equal_approx(9.25, 0.001)


func test_movement_config_controls_step_height() -> void:
	var mc := _make_locomotion_container()
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	config.step_up_height = 0.72
	mc.set_movement_config(config)

	assert_float(mc.max_step_height).is_equal_approx(0.72, 0.001)


func test_movement_config_controls_step_down_and_min_step_height() -> void:
	var mc := _make_locomotion_container()
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	config.step_down_height = 0.25
	config.min_step_height = 0.15
	mc.set_movement_config(config)

	assert_float(mc._get_step_down_probe_distance(0.5)).is_equal_approx(0.75, 0.001)
	assert_bool(mc._is_step_height_accepted(1.0, 1.14)).is_false()
	assert_bool(mc._is_step_height_accepted(1.0, 1.16)).is_true()


func test_movement_config_controls_backward_run_multiplier() -> void:
	var mc := _make_locomotion_container()
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	config.run_speed = 10.0
	config.backward_angle_degrees = 90.0
	config.backward_speed_multiplier = 0.25
	mc.set_movement_config(config)

	var run := mc.get_move(&"run")
	var pkg := _make_input_package([&"idle", &"run"])
	pkg.input_direction = Vector2(0.0, 1.0)
	run._update(pkg, 1.0 / 60.0)

	assert_float(mc.player.velocity.z).is_equal_approx(2.5, 0.001)


func test_movement_config_can_disable_sprint() -> void:
	var mc := _make_locomotion_container()
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	config.can_sprint = false
	mc.set_movement_config(config)

	var idle := mc.get_move(&"idle")
	var pkg := _make_input_package([&"idle", &"run", &"sprint"])
	var chosen := idle.best_input_that_can_be_paid(pkg)

	assert_str(str(chosen)).is_equal("run")


# --- Phase 4 timing contracts -----------------------------------------------

func test_move_elapsed_time_uses_supplied_physics_delta() -> void:
	var move := MoveScript.new() as Move
	add_child(move)
	auto_free(move)

	var player := CharacterBody3D.new()
	add_child(player)
	auto_free(player)
	move.player = player

	var pkg := InputPackageScript.new() as InputPackage
	move._on_enter_state()
	move._update(pkg, 0.25)
	move._update(pkg, 0.125)

	assert_float(move.get_progress()).is_equal_approx(0.375, 0.0001)
	assert_bool(move.works_between(0.37, 0.38)).is_true()


func test_movement_config_has_explicit_jump_grace_defaults() -> void:
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig

	assert_float(config.coyote_time).is_equal_approx(0.1, 0.001)
	assert_float(config.jump_buffer_time).is_equal_approx(0.12, 0.001)


func test_coyote_time_keeps_jump_available_after_ground_loss() -> void:
	var mc := _make_locomotion_container()
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	config.coyote_time = 0.1
	config.jump_buffer_time = 0.12
	config.ground_to_midair_lockout = 0.03
	mc.set_movement_config(config)

	var pkg := _make_input_package([&"idle", &"run", &"jump"])
	mc._time_since_grounded = 0.04
	mc._prepare_jump_grace_actions(pkg, 0.02, false)

	assert_bool(pkg.actions.has(&"jump")).is_true()

	var run := mc.get_move(&"run")
	run._on_enter_state()
	run.advance_time(0.05)
	var chosen := run.default_lifecycle(pkg)

	assert_str(str(chosen)).is_equal("jump")


func test_expired_coyote_time_rejects_late_jump() -> void:
	var mc := _make_locomotion_container()
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	config.coyote_time = 0.08
	config.jump_buffer_time = 0.12
	mc.set_movement_config(config)

	var pkg := _make_input_package([&"idle", &"run", &"jump"])
	mc._time_since_grounded = 0.1
	mc._prepare_jump_grace_actions(pkg, 0.02, false)

	assert_bool(pkg.actions.has(&"jump")).is_false()


func test_jump_buffer_fires_on_landing_frame() -> void:
	var mc := _make_locomotion_container()
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	config.coyote_time = 0.1
	config.jump_buffer_time = 0.12
	mc.set_movement_config(config)

	var pkg := _make_input_package([&"idle", &"run"])
	mc._jump_buffer_timer = 0.05
	mc._prepare_jump_grace_actions(pkg, 0.016, true)

	assert_bool(pkg.actions.has(&"jump")).is_true()


func test_zero_jump_buffer_keeps_immediate_ground_jump() -> void:
	var mc := _make_locomotion_container()
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	config.coyote_time = 0.0
	config.jump_buffer_time = 0.0
	mc.set_movement_config(config)

	var pkg := _make_input_package([&"idle", &"jump"])
	mc._prepare_jump_grace_actions(pkg, 0.016, true)

	assert_bool(pkg.actions.has(&"jump")).is_true()


# --- Phase 4 posture contracts ---------------------------------------------

func test_player_controller_camera_pivot_follows_movement_posture() -> void:
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	config.standing_eye_height = 1.65
	config.crouch_eye_height = 0.85

	var player := PlayerControllerScript.new() as PlayerController
	player.movement_config = config
	add_child(player)
	auto_free(player)

	var crouch_state := MovementStateScript.new() as MovementState
	crouch_state.posture = &"crouching"
	crouch_state.is_crouching = true
	player._apply_movement_state(crouch_state)

	assert_str(str(player.current_posture)).is_equal("crouching")
	assert_bool(player.is_crouching).is_true()
	assert_float(player.camera_pivot.position.y).is_equal_approx(0.85, 0.001)

	var standing_state := MovementStateScript.new() as MovementState
	standing_state.posture = &"standing"
	player._apply_movement_state(standing_state)

	assert_str(str(player.current_posture)).is_equal("standing")
	assert_bool(player.is_crouching).is_false()
	assert_float(player.camera_pivot.position.y).is_equal_approx(1.65, 0.001)


func test_interaction_ray_origin_follows_camera_pivot_posture() -> void:
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	config.standing_eye_height = 1.6
	config.crouch_eye_height = 0.75

	var player := PlayerControllerScript.new() as PlayerController
	player.movement_config = config
	add_child(player)
	auto_free(player)

	var raycaster := InteractionRaycasterScript.new() as InteractionRaycaster
	raycaster.camera = player.get_camera()
	raycaster.ray_origin_node = player.camera_pivot
	add_child(raycaster)
	auto_free(raycaster)

	var crouch_state := MovementStateScript.new() as MovementState
	crouch_state.posture = &"crouching"
	crouch_state.is_crouching = true
	player._apply_movement_state(crouch_state)

	assert_bool(raycaster.ray_origin_node == player.camera_pivot).is_true()
	assert_float(raycaster.ray_origin_node.global_position.y).is_equal_approx(
		player.global_position.y + config.crouch_eye_height, 0.001)


func test_move_container_publishes_crouch_posture() -> void:
	var mc := _make_locomotion_container()
	var pkg := _make_input_package([&"idle", &"crouch"])

	mc.switch_to(&"crouch")
	mc.process(pkg, 1.0 / 60.0)
	var state := mc.get_movement_state()

	assert_str(str(state.active_move_name)).is_equal("crouch")
	assert_str(str(state.posture)).is_equal("crouching")
	assert_bool(state.is_crouching).is_true()


# --- Phase 3 ownership contracts --------------------------------------------

func test_character_motor_processes_movement_without_animation_system() -> void:
	var player := CharacterBody3D.new()
	add_child(player)
	auto_free(player)

	var character_root := Node3D.new()
	add_child(character_root)
	auto_free(character_root)

	var motor := CharacterMotorScript.new() as CharacterMotor
	player.add_child(motor)
	motor.setup(player, character_root)

	Input.action_press(&"move_forward")
	var state := motor.process(1.0 / 60.0)

	assert_str(str(state.active_move_name)).is_equal("run")
	assert_float(absf(player.velocity.z)).is_greater(0.0)
	assert_vector(state.input_direction).is_equal(Vector2(0.0, -1.0))


func test_player_controller_attaches_character_motor_without_animation_system() -> void:
	var player := PlayerControllerScript.new() as PlayerController
	add_child(player)
	auto_free(player)

	var character_root := Node3D.new()
	player.attach_character(character_root, null)

	assert_bool(player.animation_system == null).is_true()
	assert_bool(player.get_movement_motor() != null).is_true()
	assert_bool(player.get_movement_motor().get_move_container() != null).is_true()


func test_animation_system_observes_movement_state() -> void:
	var anim_system := CharacterAnimationSystem.new()
	add_child(anim_system)
	auto_free(anim_system)

	var fake_manager := FakeAnimationManager.new()
	anim_system.animation_manager = fake_manager

	var state := MovementStateScript.new() as MovementState
	state.active_move_name = &"run"
	state.animation_state = &"Run"
	state.velocity = Vector3(0.0, 0.0, -5.0)
	state.is_grounded = true
	state.input_direction = Vector2(0.0, -1.0)

	anim_system.update_from_movement_state(state)

	assert_float(fake_manager.blend_parameters[&"movement_speed"]).is_equal_approx(5.0, 0.001)
	assert_vector(fake_manager.blend_parameters[&"movement_direction"]).is_equal(Vector2(0.0, -1.0))
	assert_str(str(fake_manager.transitioned_state)).is_equal("Run")
	assert_bool(fake_manager.transition_force).is_true()


func test_animation_system_forces_idle_after_sprint_state() -> void:
	var anim_system := CharacterAnimationSystem.new()
	add_child(anim_system)
	auto_free(anim_system)

	var fake_manager := FakeAnimationManager.new()
	anim_system.animation_manager = fake_manager

	var sprint_state := MovementStateScript.new() as MovementState
	sprint_state.animation_state = &"Sprint"
	sprint_state.velocity = Vector3(0.0, 0.0, -8.0)
	sprint_state.is_grounded = true
	sprint_state.input_direction = Vector2(0.0, -1.0)
	sprint_state.is_sprinting = true
	anim_system.update_from_movement_state(sprint_state)

	var idle_state := MovementStateScript.new() as MovementState
	idle_state.animation_state = &"Idle"
	idle_state.velocity = Vector3.ZERO
	idle_state.is_grounded = true
	anim_system.update_from_movement_state(idle_state)

	assert_str(str(fake_manager.transitioned_state)).is_equal("Idle")
	assert_bool(fake_manager.transition_force).is_true()
	assert_float(fake_manager.blend_parameters[&"movement_speed"]).is_equal_approx(0.0, 0.001)


func test_animation_manager_resolves_spaced_swim_animation_names() -> void:
	var anim_manager := AnimationManagerScript.new() as AnimationManager
	add_child(anim_manager)
	auto_free(anim_manager)

	var anim_player := AnimationPlayer.new()
	add_child(anim_player)
	auto_free(anim_player)
	var lib := AnimationLibrary.new()
	lib.add_animation(&"Idle Swim", Animation.new())
	lib.add_animation(&"Swim Walk Forward", Animation.new())
	anim_player.add_animation_library("", lib)
	anim_manager.animation_player = anim_player

	assert_str(str(anim_manager._find_animation_for_state_name(&"SwimIdle"))).is_equal("Idle Swim")
	assert_str(str(anim_manager._find_animation_for_state_name(&"SwimForward"))).is_equal("Swim Walk Forward")


func test_animation_manager_resolves_directional_morrowind_names() -> void:
	var anim_manager := AnimationManagerScript.new() as AnimationManager
	add_child(anim_manager)
	auto_free(anim_manager)

	var anim_player := AnimationPlayer.new()
	add_child(anim_player)
	auto_free(anim_player)
	var lib := AnimationLibrary.new()
	lib.add_animation(&"Run Left", Animation.new())
	lib.add_animation(&"RunForwardRight1h", Animation.new())
	lib.add_animation(&"Sneak Right", Animation.new())
	lib.add_animation(&"Swim Walk Left", Animation.new())
	anim_player.add_animation_library("", lib)
	anim_manager.animation_player = anim_player

	assert_str(str(anim_manager._find_animation_for_state_name(&"RunLeft"))).is_equal("Run Left")
	assert_str(str(anim_manager._find_animation_for_state_name(&"RunForwardRight"))).is_equal("RunForwardRight1h")
	assert_str(str(anim_manager._find_animation_for_state_name(&"SneakRight"))).is_equal("Sneak Right")
	assert_str(str(anim_manager._find_animation_for_state_name(&"SwimWalkLeft"))).is_equal("Swim Walk Left")


func test_animation_manager_directional_diagonal_falls_back_to_cardinal() -> void:
	var anim_manager := AnimationManagerScript.new() as AnimationManager
	add_child(anim_manager)
	auto_free(anim_manager)

	anim_manager._state_animation_map = {
		&"Run": &"RunForward",
		&"RunLeft": &"RunLeft",
		&"RunBack": &"RunBack",
		&"SwimForward": &"SwimWalkForward",
		&"SwimWalkRight": &"SwimWalkRight",
	}

	assert_str(str(anim_manager._resolve_fallback_state(&"RunForwardLeft"))).is_equal("RunLeft")
	assert_str(str(anim_manager._resolve_fallback_state(&"RunBackRight"))).is_equal("RunBack")
	assert_str(str(anim_manager._resolve_fallback_state(&"SwimWalkForwardRight"))).is_equal("SwimWalkRight")


func test_animation_system_retries_movement_state_after_failed_transition() -> void:
	var anim_system := CharacterAnimationSystem.new()
	add_child(anim_system)
	auto_free(anim_system)

	var fake_manager := RejectingAnimationManager.new()
	anim_system.animation_manager = fake_manager

	var state := MovementStateScript.new() as MovementState
	state.animation_state = &"SwimForward"
	state.velocity = Vector3(0.0, 0.0, -3.0)
	state.is_in_water = true
	state.is_swimming = true
	state.input_direction = Vector2(0.0, -1.0)

	anim_system.update_from_movement_state(state)
	assert_int(fake_manager.transition_calls.size()).is_equal(1)

	fake_manager.accept_transition = true
	anim_system.update_from_movement_state(state)

	assert_int(fake_manager.transition_calls.size()).is_equal(2)


func test_player_controller_ensure_input_actions_keeps_walk_unbound() -> void:
	var had_walk := InputMap.has_action(&"walk")
	var saved_walk_events := InputMap.action_get_events(&"walk") if had_walk else []
	if had_walk:
		InputMap.erase_action(&"walk")

	var player := PlayerControllerScript.new() as PlayerController
	add_child(player)
	auto_free(player)
	player._ensure_input_actions()

	assert_bool(InputMap.has_action(&"walk")).is_true()
	assert_int(InputMap.action_get_events(&"walk").size()).is_equal(0)

	InputMap.erase_action(&"walk")
	if had_walk:
		InputMap.add_action(&"walk")
		for event: InputEvent in saved_walk_events:
			InputMap.action_add_event(&"walk", event)


func test_player_controller_ensure_input_actions_binds_ctrl_to_crouch() -> void:
	var had_crouch := InputMap.has_action(&"crouch")
	var saved_crouch_events := InputMap.action_get_events(&"crouch") if had_crouch else []
	if had_crouch:
		InputMap.erase_action(&"crouch")

	var player := PlayerControllerScript.new() as PlayerController
	add_child(player)
	auto_free(player)
	player._ensure_input_actions()

	var has_ctrl := false
	for event: InputEvent in InputMap.action_get_events(&"crouch"):
		if event is InputEventKey and (event as InputEventKey).physical_keycode == KEY_CTRL:
			has_ctrl = true
			break

	assert_bool(has_ctrl).is_true()

	InputMap.erase_action(&"crouch")
	if had_crouch:
		InputMap.add_action(&"crouch")
		for event: InputEvent in saved_crouch_events:
			InputMap.action_add_event(&"crouch", event)


# --- Post-Phase 7 Phase 2 hardening contracts -------------------------------

func test_player_controller_teleport_resets_physics_interpolation() -> void:
	var player := PlayerControllerScript.new() as PlayerController
	add_child(player)
	auto_free(player)
	var reset_spy := ResetNotificationSpy.new()
	player.add_child(reset_spy)
	player.velocity = Vector3(1.0, 2.0, 3.0)

	player.teleport_to(Vector3(4.0, 5.0, 6.0))

	assert_vector(player.global_position).is_equal(Vector3(4.0, 5.0, 6.0))
	assert_vector(player.velocity).is_equal(Vector3.ZERO)
	assert_int(reset_spy.reset_count).is_equal(1)


func test_fly_camera_teleport_resets_physics_interpolation() -> void:
	var fly := FlyCamera.new()
	add_child(fly)
	auto_free(fly)
	var reset_spy := ResetNotificationSpy.new()
	fly.add_child(reset_spy)

	fly.teleport_to(Vector3(10.0, 20.0, 30.0))

	assert_vector(fly.position).is_equal(Vector3(10.0, 20.0, 30.0))
	assert_int(reset_spy.reset_count).is_equal(1)


func test_carry_release_restores_valid_body_when_pickup_wrapper_missing() -> void:
	var carry := CarryControllerScript.new() as CarryController
	add_child(carry)
	auto_free(carry)

	var rb := RigidBody3D.new()
	rb.collision_mask = 0
	rb.gravity_scale = 0.0
	rb.linear_damp = 4.0
	rb.angular_damp = 6.0
	add_child(rb)
	auto_free(rb)

	carry._held_body = rb
	carry._held_pickup = null
	carry._saved_collision_mask = 0x2B
	carry._saved_gravity_scale = 1.25
	carry._saved_linear_damp = 0.15
	carry._saved_angular_damp = 0.25

	carry.release()
	await get_tree().process_frame

	assert_bool(carry.is_carrying()).is_false()
	assert_int(rb.collision_mask).is_equal(0x2B)
	assert_float(rb.gravity_scale).is_equal_approx(1.25, 0.001)
	assert_float(rb.linear_damp).is_equal_approx(0.15, 0.001)
	assert_float(rb.angular_damp).is_equal_approx(0.25, 0.001)


# --- Phase 5 gameplay physics layer contracts -------------------------------

func test_gameplay_physics_layers_is_not_an_autoload() -> void:
	assert_bool(ProjectSettings.has_setting("autoload/GameplayPhysicsLayers")).is_false()
	assert_int(GameplayPhysicsLayersScript.PLAYER).is_equal(1 << 1)
	assert_int(GameplayPhysicsLayersScript.CARRYABLE_MASK).is_equal(
		GameplayPhysicsLayersScript.ENVIRONMENT | GameplayPhysicsLayersScript.PLAYER)


func test_carry_held_mask_excludes_current_player_collision_bits() -> void:
	var player := CharacterBody3D.new()
	player.collision_layer = 0x33
	add_child(player)
	auto_free(player)

	var carry := CarryControllerScript.new() as CarryController
	carry.player = player
	add_child(carry)
	auto_free(carry)

	var rb := RigidBody3D.new()
	rb.collision_mask = 0x3F
	add_child(rb)
	auto_free(rb)
	carry._saved_collision_mask = rb.collision_mask

	carry._apply_held_player_collision_exclusion(rb)

	assert_int(rb.collision_mask).is_equal(0x3F & ~0x33)

	player.collision_layer = 0x30
	carry._apply_held_player_collision_exclusion(rb)

	assert_int(rb.collision_mask).is_equal(0x3F & ~0x30)


func test_carry_release_restores_exact_previous_collision_mask() -> void:
	var carry := CarryControllerScript.new() as CarryController
	add_child(carry)
	auto_free(carry)

	var rb := RigidBody3D.new()
	rb.collision_mask = 0
	rb.gravity_scale = 0.0
	rb.linear_damp = 4.0
	rb.angular_damp = 6.0
	add_child(rb)
	auto_free(rb)

	carry._do_release(rb, 0x2B, 1.25, 0.15, 0.25)

	assert_int(rb.collision_mask).is_equal(0x2B)
	assert_float(rb.gravity_scale).is_equal_approx(1.25, 0.001)
	assert_float(rb.linear_damp).is_equal_approx(0.15, 0.001)
	assert_float(rb.angular_damp).is_equal_approx(0.25, 0.001)


# --- Phase 6 step solver validation surface ---------------------------------

func test_phase6_step_visual_scene_exposes_required_cases() -> void:
	var scene := StepSolverScene.instantiate()
	auto_free(scene)

	assert_bool(scene.has_method("get_step_case_names")).is_true()
	var case_names := Array(scene.get_step_case_names())

	assert_int(case_names.size()).is_equal(6)
	assert_bool(case_names.has("small_step")).is_true()
	assert_bool(case_names.has("tall_wall")).is_true()
	assert_bool(case_names.has("angled_wall")).is_true()
	assert_bool(case_names.has("ceiling_blocked_step")).is_true()
	assert_bool(case_names.has("down_step_no_floor")).is_true()
	assert_bool(case_names.has("rigidbody_obstacle")).is_true()
	assert_bool(scene.has_method("get_respawn_action_name")).is_true()
	assert_str(str(scene.get_respawn_action_name())).is_equal("step_solver_respawn")
	assert_bool(InputMap.has_action(&"step_solver_respawn")).is_true()


func test_phase6_step_solver_scripted_fixture_categories() -> void:
	var small_step := await _run_step_solver_fixture(&"small_step")
	assert_bool(bool(small_step[&"did_climb"])).is_true()
	assert_bool(bool(small_step[&"moved_forward"])).is_true()

	var tall_wall := await _run_step_solver_fixture(&"tall_wall")
	assert_bool(bool(tall_wall[&"did_climb"])).is_false()

	var ceiling_blocked := await _run_step_solver_fixture(&"ceiling_blocked_step")
	assert_bool(bool(ceiling_blocked[&"did_climb"])).is_false()

	var no_floor := await _run_step_solver_fixture(&"down_step_no_floor")
	assert_bool(bool(no_floor[&"did_climb"])).is_false()

	var rigidbody_obstacle := await _run_step_solver_fixture(&"rigidbody_obstacle")
	assert_bool(bool(rigidbody_obstacle[&"did_climb"])).is_false()


# --- Post-Phase 7 Phase 2 visual validation surfaces ------------------------

func test_phase2_carry_prompt_visual_scene_exposes_required_cases() -> void:
	var scene := CarryPromptSuppressionScene.instantiate()
	auto_free(scene)

	assert_bool(scene.has_method("get_validation_case_names")).is_true()
	var case_names := Array(scene.get_validation_case_names())

	assert_int(case_names.size()).is_equal(4)
	assert_bool(case_names.has("prompt_visible_before_carry")).is_true()
	assert_bool(case_names.has("prompt_hidden_while_carrying")).is_true()
	assert_bool(case_names.has("tap_ignored_while_carrying")).is_true()
	assert_bool(case_names.has("prompt_returns_after_release")).is_true()


func test_phase2_teleport_visual_scene_exposes_required_cases_and_actions() -> void:
	var scene := TeleportInterpolationResetScene.instantiate()
	auto_free(scene)

	assert_bool(scene.has_method("get_validation_case_names")).is_true()
	var case_names := Array(scene.get_validation_case_names())

	assert_int(case_names.size()).is_equal(4)
	assert_bool(case_names.has("player_controller_teleport_to")).is_true()
	assert_bool(case_names.has("fly_camera_teleport_to")).is_true()
	assert_bool(case_names.has("transition_style_body_write")).is_true()
	assert_bool(case_names.has("transition_style_camera_write")).is_true()

	assert_bool(scene.has_method("get_teleport_action_names")).is_true()
	var action_names := Array(scene.get_teleport_action_names())
	assert_int(action_names.size()).is_equal(4)
	assert_bool(action_names.has("teleport_test_player")).is_true()
	assert_bool(action_names.has("teleport_test_fly_camera")).is_true()
	assert_bool(action_names.has("teleport_test_transition_write")).is_true()
	assert_bool(action_names.has("teleport_test_reset")).is_true()
	for action_name in action_names:
		assert_bool(InputMap.has_action(StringName(str(action_name)))).is_true()


# --- Post-Phase 7 Phase 4 visual input and state contracts -------------------

func test_phase4_character_controller_visual_actions_are_registered() -> void:
	var expected_actions := [
		&"character_controller_preset_1",
		&"character_controller_preset_2",
		&"character_controller_preset_3",
		&"character_controller_preset_4",
		&"character_controller_preset_5",
		&"character_controller_toggle_debug_hud",
		&"character_controller_dump_kf_bones",
	]

	var scene := CharacterControllerVisualScene.instantiate()
	auto_free(scene)
	assert_bool(scene.has_method("get_visual_test_action_names")).is_true()
	var scene_actions := Array(scene.get_visual_test_action_names())

	for action_name in expected_actions:
		assert_bool(InputMap.has_action(action_name)).is_true()
		assert_bool(InputActionsScript.VISUAL_TEST.has(action_name)).is_true()
		assert_bool(scene_actions.has(action_name)).is_true()


func test_phase4_character_controller_visual_scene_uses_input_actions_for_debug_controls() -> void:
	var source := FileAccess.get_file_as_string("res://tests/visual/test_character_controller.gd")

	assert_bool(source.contains("KEY_1")).is_false()
	assert_bool(source.contains("KEY_2")).is_false()
	assert_bool(source.contains("KEY_3")).is_false()
	assert_bool(source.contains("KEY_4")).is_false()
	assert_bool(source.contains("KEY_5")).is_false()
	assert_bool(source.contains("KEY_F1")).is_false()
	assert_bool(source.contains("KEY_F2")).is_false()
	assert_bool(source.contains("event.keycode")).is_false()


func test_phase4_character_controller_visual_scene_keeps_player_animation_lod_disabled() -> void:
	var source := FileAccess.get_file_as_string("res://tests/visual/test_character_controller.gd")

	assert_bool(source.contains("_factory.enable_lod = false")).is_true()


func test_phase4_movement_state_splits_jump_move_from_airborne_state() -> void:
	var mc := _make_locomotion_container()
	var pkg := _make_input_package([])

	mc.switch_to(&"midair")
	mc._publish_movement_state(pkg)
	var midair_state := mc.get_movement_state()
	assert_bool(midair_state.is_airborne).is_true()
	assert_bool(midair_state.is_jump_move).is_false()
	assert_bool(midair_state.is_jumping).is_true()

	mc.switch_to(&"jump")
	mc._publish_movement_state(pkg)
	var jump_state := mc.get_movement_state()
	assert_bool(jump_state.is_airborne).is_true()
	assert_bool(jump_state.is_jump_move).is_true()
	assert_bool(jump_state.is_jumping).is_true()


# --- Helpers ----------------------------------------------------------------

func _run_step_solver_fixture(step_case: StringName) -> Dictionary:
	var root := Node3D.new()
	root.name = "StepSolverFixture_%s" % step_case
	add_child(root)
	auto_free(root)

	_add_step_fixture_floor(root, "ApproachFloor", Vector3(0.0, -0.05, 1.6), Vector3(3.0, 0.1, 4.0))
	match step_case:
		&"small_step":
			_add_step_fixture_floor(root, "LandingFloor", Vector3(0.0, 0.25, -1.2), Vector3(3.0, 0.1, 3.0))
			_add_step_fixture_static_box(root, "SmallStepBlock", Vector3(0.0, 0.15, 0.45), Vector3(2.0, 0.3, 0.4))
		&"tall_wall":
			_add_step_fixture_floor(root, "LandingFloor", Vector3(0.0, 0.0, -1.2), Vector3(3.0, 0.1, 3.0))
			_add_step_fixture_static_box(root, "TallWallBlock", Vector3(0.0, 0.7, 0.45), Vector3(2.0, 1.4, 0.4))
		&"ceiling_blocked_step":
			_add_step_fixture_floor(root, "LandingFloor", Vector3(0.0, 0.25, -1.2), Vector3(3.0, 0.1, 3.0))
			_add_step_fixture_static_box(root, "CeilingStepBlock", Vector3(0.0, 0.15, 0.45), Vector3(2.0, 0.3, 0.4))
			_add_step_fixture_static_box(root, "LowCeiling", Vector3(0.0, 1.95, 0.35), Vector3(2.4, 0.2, 1.6))
		&"down_step_no_floor":
			pass
		&"rigidbody_obstacle":
			_add_step_fixture_floor(root, "LandingFloor", Vector3(0.0, 0.0, -1.2), Vector3(3.0, 0.1, 3.0))
			_add_step_fixture_rigidbody_box(root, "PushableCrate", Vector3(0.0, 0.35, 0.45), Vector3(0.7, 0.7, 0.7))

	var player := CharacterBody3D.new()
	player.name = "FixturePlayer"
	player.collision_layer = GameplayPhysicsLayersScript.PLAYER
	player.collision_mask = GameplayPhysicsLayersScript.ENVIRONMENT | GameplayPhysicsLayersScript.CARRYABLE_LAYER
	player.floor_snap_length = 0.15
	player.global_position = Vector3(0.0, 0.0, 1.15)
	var player_shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.3
	capsule.height = 1.8
	player_shape.shape = capsule
	player_shape.position.y = 0.9
	player.add_child(player_shape)
	root.add_child(player)

	var mc := MoveContainerScript.new() as MoveContainer
	mc.player = player
	var config := CharacterMovementConfigScript.new() as CharacterMovementConfig
	config.step_up_height = 0.45
	config.step_down_height = 0.45
	config.min_step_height = 0.0
	mc.set_movement_config(config)
	root.add_child(mc)

	await get_tree().physics_frame
	player.velocity = Vector3.DOWN
	player.move_and_slide()
	await get_tree().physics_frame

	var initial_position := player.global_position
	player.velocity = Vector3(0.0, 0.0, -5.0)
	mc._move_with_step_up(0.12)
	await get_tree().physics_frame

	var final_position := player.global_position
	return {
		&"did_climb": final_position.y > initial_position.y + 0.08,
		&"moved_forward": final_position.z < initial_position.z - 0.08,
		&"initial_position": initial_position,
		&"final_position": final_position,
	}


func _add_step_fixture_floor(root: Node3D, body_name: String, pos: Vector3, size: Vector3) -> StaticBody3D:
	return _add_step_fixture_static_box(root, body_name, pos, size)


func _add_step_fixture_static_box(root: Node3D, body_name: String, pos: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = body_name
	body.position = pos
	body.collision_layer = GameplayPhysicsLayersScript.ENVIRONMENT
	body.collision_mask = GameplayPhysicsLayersScript.PLAYER

	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)

	root.add_child(body)
	return body


func _add_step_fixture_rigidbody_box(root: Node3D, body_name: String, pos: Vector3, size: Vector3) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = body_name
	body.position = pos
	body.mass = 1.0
	body.collision_layer = GameplayPhysicsLayersScript.CARRYABLE_LAYER
	body.collision_mask = GameplayPhysicsLayersScript.ENVIRONMENT | GameplayPhysicsLayersScript.PLAYER

	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)

	root.add_child(body)
	return body


func _make_locomotion_container() -> MoveContainer:
	var mc := MoveContainerScript.new() as MoveContainer
	add_child(mc)
	auto_free(mc)

	var player := CharacterBody3D.new()
	add_child(player)
	auto_free(player)
	mc.player = player

	var character_root := Node3D.new()
	add_child(character_root)
	auto_free(character_root)
	mc.character_root = character_root

	var idle := IdleMoveScript.new()
	var walk := WalkMoveScript.new()
	var run := RunMoveScript.new()
	var sprint := SprintMoveScript.new()
	var jump := JumpMoveScript.new()
	var midair := MidairMoveScript.new()
	var crouch := CrouchMoveScript.new()
	var swim_idle := SwimIdleMoveScript.new()
	var swim := SwimMoveScript.new()
	mc.add_child(idle)
	mc.add_child(walk)
	mc.add_child(run)
	mc.add_child(sprint)
	mc.add_child(jump)
	mc.add_child(midair)
	mc.add_child(crouch)
	mc.add_child(swim_idle)
	mc.add_child(swim)
	mc.accept_moves()
	return mc


func _make_input_package(actions: Array[StringName]) -> InputPackage:
	var pkg := InputPackageScript.new() as InputPackage
	pkg.actions = actions
	return pkg


func _make_gatherer() -> PlayerInputGatherer:
	var gatherer := PlayerInputGathererScript.new() as PlayerInputGatherer
	add_child(gatherer)
	auto_free(gatherer)
	return gatherer


func _test_actor_forward_basis() -> Basis:
	return Basis.IDENTITY


func _test_flat_movement_pitch() -> float:
	return 0.0


func _test_upward_swim_pitch() -> float:
	return -0.5


func _release_test_actions() -> void:
	for action_name in TEST_ACTIONS:
		if InputMap.has_action(action_name):
			Input.action_release(action_name)
