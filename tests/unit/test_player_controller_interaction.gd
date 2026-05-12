## Unit tests for PlayerController's I.0 interaction contract.
##
## Covers the contract from `docs/systems/interaction_system.md` §3.1:
##   - modal gate registry (register / unregister / idempotent / null guard)
##   - tree_exiting self-heal removes freed gates
##   - is_modal_ui_open() reflects gate state
##   - InteractionIntent tap / hold-begin / hold-release semantics
##   - interact_tap / interact_hold_begin / interact_release semantics
##   - modal gate suppresses interact_* signal emission
##   - _emit_interact_tap routes to raycaster's get_current_target
##
## ## Test seam notes
## - We bypass the viewport input chain and call PlayerController's
##   internal handlers (`_on_interact_pressed`, `_on_interact_released`,
##   `_poll_interact_hold`) directly. The viewport-input integration is
##   covered by the visual scene `tests/visual/test_interaction_phase_I0.tscn`.
## - PlayerController handlers accept an optional test timestamp so polling
##   crosses the threshold synchronously without waiting.
## - All gate stubs live as inner classes in this file — self-contained.
extends GdUnitTestSuite

const InteractionIntentScript := preload("res://src/core/interaction/interaction_intent.gd")
const InteractionRaycasterScript := preload("res://src/core/interaction/interaction_raycaster.gd")
const CarryControllerScript := preload("res://src/core/interaction/carry_controller.gd")
const PlayerControllerScript := preload("res://src/core/player/player_controller.gd")


# --- Stubs ------------------------------------------------------------------

class AlwaysOpenGate extends Node:
	func is_open() -> bool:
		return true


class AlwaysClosedGate extends Node:
	func is_open() -> bool:
		return false


class TogglableGate extends Node:
	var open_state: bool = false
	func is_open() -> bool:
		return open_state


class FakeRaycaster extends Node:
	var target: Node = null
	func get_current_target() -> Node:
		return target


class FakeInteractable extends Node:
	var interact_count: int = 0
	func interact(_player: Node) -> void:
		interact_count += 1


class FakePromptTarget extends Interactable:
	func get_prompt_text() -> String:
		return "Use target"


# --- Helpers ----------------------------------------------------------------

func _make_player() -> PlayerController:
	var p: PlayerController = PlayerControllerScript.new() as PlayerController
	add_child(p)
	auto_free(p)
	p.enabled = true
	return p


# --- InteractionIntent helper -----------------------------------------------

func test_interaction_intent_tap_on_quick_release() -> void:
	var intent := InteractionIntentScript.new(0.20) as InteractionIntent
	intent.press(1000)
	assert_int(intent.release(1100)).is_equal(InteractionIntent.Outcome.TAP)
	assert_bool(intent.is_pressed()).is_false()


func test_interaction_intent_hold_begin_at_threshold() -> void:
	var intent := InteractionIntentScript.new(0.20) as InteractionIntent
	intent.press(1000)
	assert_int(intent.poll(1199)).is_equal(InteractionIntent.Outcome.NONE)
	assert_int(intent.poll(1200)).is_equal(InteractionIntent.Outcome.HOLD_BEGIN)
	assert_bool(intent.has_hold_emitted()).is_true()


func test_interaction_intent_release_after_hold() -> void:
	var intent := InteractionIntentScript.new(0.20) as InteractionIntent
	intent.press(1000)
	assert_int(intent.poll(1250)).is_equal(InteractionIntent.Outcome.HOLD_BEGIN)
	assert_int(intent.release(1300)).is_equal(InteractionIntent.Outcome.HOLD_RELEASE)
	assert_bool(intent.has_hold_emitted()).is_false()


func test_interaction_intent_missing_press_is_none() -> void:
	var intent := InteractionIntentScript.new(0.20) as InteractionIntent
	assert_int(intent.release(1000)).is_equal(InteractionIntent.Outcome.NONE)
	assert_int(intent.poll(1000)).is_equal(InteractionIntent.Outcome.NONE)


func test_interaction_intent_cancel_clears_press() -> void:
	var intent := InteractionIntentScript.new(0.20) as InteractionIntent
	intent.press(1000)
	intent.cancel()
	assert_bool(intent.is_pressed()).is_false()
	assert_int(intent.release(1300)).is_equal(InteractionIntent.Outcome.NONE)


func test_interaction_intent_long_release_without_poll_falls_back_to_tap() -> void:
	var intent := InteractionIntentScript.new(0.20) as InteractionIntent
	intent.press(1000)
	assert_int(intent.release(1400)).is_equal(InteractionIntent.Outcome.TAP)


# --- Modal gate registry ----------------------------------------------------

func test_register_gate_increments_count() -> void:
	var p := _make_player()
	var g: AlwaysClosedGate = auto_free(AlwaysClosedGate.new())
	add_child(g)
	p.register_modal_gate(g)
	assert_int(p.get_modal_gate_count()).is_equal(1)


func test_register_gate_idempotent() -> void:
	var p := _make_player()
	var g: AlwaysClosedGate = auto_free(AlwaysClosedGate.new())
	add_child(g)
	p.register_modal_gate(g)
	p.register_modal_gate(g)
	p.register_modal_gate(g)
	assert_int(p.get_modal_gate_count()).is_equal(1)


func test_unregister_gate_removes() -> void:
	var p := _make_player()
	var g: AlwaysClosedGate = auto_free(AlwaysClosedGate.new())
	add_child(g)
	p.register_modal_gate(g)
	p.unregister_modal_gate(g)
	assert_int(p.get_modal_gate_count()).is_equal(0)


func test_register_null_gate_is_safe() -> void:
	var p := _make_player()
	p.register_modal_gate(null)
	assert_int(p.get_modal_gate_count()).is_equal(0)


func test_tree_exiting_self_heal_removes_freed_gate() -> void:
	var p := _make_player()
	var g := AlwaysClosedGate.new()
	add_child(g)
	p.register_modal_gate(g)
	assert_int(p.get_modal_gate_count()).is_equal(1)
	g.queue_free()
	await get_tree().process_frame
	assert_int(p.get_modal_gate_count()).is_equal(0)


func test_is_modal_ui_open_reflects_state() -> void:
	var p := _make_player()
	var g: TogglableGate = auto_free(TogglableGate.new())
	add_child(g)
	p.register_modal_gate(g)
	assert_bool(p.is_modal_ui_open()).is_false()
	g.open_state = true
	assert_bool(p.is_modal_ui_open()).is_true()
	g.open_state = false
	assert_bool(p.is_modal_ui_open()).is_false()


# --- Interact tap / hold / release ------------------------------------------

func test_tap_emits_on_quick_press_release() -> void:
	var p := _make_player()
	@warning_ignore("inferred_declaration") var monitor := monitor_signals(p)
	p._on_interact_pressed()
	p._on_interact_released()
	await assert_signal(monitor).is_emitted("interact_tap")


func test_hold_begin_emits_after_threshold() -> void:
	var p := _make_player()
	@warning_ignore("inferred_declaration") var monitor := monitor_signals(p)
	p._on_interact_pressed(1000)
	p._poll_interact_hold(1250)
	await assert_signal(monitor).is_emitted("interact_hold_begin")


func test_release_emits_after_hold() -> void:
	var p := _make_player()
	@warning_ignore("inferred_declaration") var monitor := monitor_signals(p)
	p._on_interact_pressed(1000)
	p._poll_interact_hold(1250)
	p._on_interact_released(1300)
	await assert_signal(monitor).is_emitted("interact_release")


func test_modal_gate_suppresses_press() -> void:
	var p := _make_player()
	var g: AlwaysOpenGate = auto_free(AlwaysOpenGate.new())
	add_child(g)
	p.register_modal_gate(g)
	p._on_interact_pressed(1000)
	# Press should be ignored — no active interaction intent is recorded.
	assert_bool(p._interaction_intent.is_pressed()).is_false()


# --- Tap routing to raycaster -----------------------------------------------

func test_emit_interact_tap_routes_to_raycaster_target() -> void:
	var p := _make_player()
	var ray: FakeRaycaster = auto_free(FakeRaycaster.new())
	add_child(ray)
	var target: FakeInteractable = auto_free(FakeInteractable.new())
	add_child(target)
	ray.target = target
	p.set_interaction_raycaster(ray)
	p._emit_interact_tap()
	assert_int(target.interact_count).is_equal(1)


func test_emit_interact_tap_no_raycaster_is_safe() -> void:
	var p := _make_player()
	# No raycaster set — should not crash.
	p._emit_interact_tap()
	assert_object(p.get_interaction_raycaster()).is_null()


# --- Carry prompt suppression ------------------------------------------------

func test_raycaster_prompt_suppression_hides_and_restores_current_target() -> void:
	var ray := InteractionRaycasterScript.new() as InteractionRaycaster
	add_child(ray)
	auto_free(ray)
	var target: FakePromptTarget = auto_free(FakePromptTarget.new())
	add_child(target)
	ray._current_target = target
	ray._current_distance = 2.5

	ray.set_prompt_suppressed(true)
	assert_bool(ray.is_prompt_suppressed()).is_true()
	ray.set_prompt_suppressed(false)

	assert_bool(ray.is_prompt_suppressed()).is_false()
	assert_bool(ray.get_current_target() == target).is_true()


func test_player_carry_signals_toggle_raycaster_prompt_suppression() -> void:
	var p := _make_player()
	var ray := InteractionRaycasterScript.new() as InteractionRaycaster
	add_child(ray)
	auto_free(ray)
	var carry := CarryControllerScript.new() as CarryController
	add_child(carry)
	auto_free(carry)
	var rb := RigidBody3D.new()
	add_child(rb)
	auto_free(rb)

	p.set_interaction_raycaster(ray)
	p.set_carry_controller(carry)

	carry.grabbed.emit(rb)
	assert_bool(ray.is_prompt_suppressed()).is_true()

	carry.released.emit(rb)
	assert_bool(ray.is_prompt_suppressed()).is_false()
