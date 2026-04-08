## Unit tests for PlayerController's I.0 interaction contract.
##
## Covers the contract from `docs/INTERACTION_SYSTEM.md` §3.1:
##   - modal gate registry (register / unregister / idempotent / null guard)
##   - tree_exiting self-heal removes freed gates
##   - is_modal_ui_open() reflects gate state
##   - interact_tap / interact_hold_begin / interact_release semantics
##   - modal gate suppresses interact_* signal emission
##   - _emit_interact_tap routes to raycaster's get_current_target
##
## ## Test seam notes
## - We bypass the viewport input chain and call PlayerController's
##   internal handlers (`_on_interact_pressed`, `_on_interact_released`,
##   `_poll_interact_hold`) directly. The viewport-input integration is
##   covered by the visual scene `tests/visual/test_interaction_phase_I0.tscn`.
## - HOLD_THRESHOLD is real-time (0.2s). Instead of `await` we manufacture
##   stale `_interact_press_time_msec` values so polling crosses the
##   threshold synchronously.
## - All gate stubs live as inner classes in this file — self-contained.
extends GdUnitTestSuite

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


# --- Helpers ----------------------------------------------------------------

func _make_player() -> PlayerController:
	var p: PlayerController = PlayerControllerScript.new() as PlayerController
	add_child(p)
	auto_free(p)
	p.enabled = true
	return p


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
	p._on_interact_pressed()
	# Manufacture a stale press timestamp 250ms in the past so the next
	# poll crosses HOLD_THRESHOLD (200ms) synchronously.
	p._interact_press_time_msec = Time.get_ticks_msec() - 250
	p._poll_interact_hold()
	await assert_signal(monitor).is_emitted("interact_hold_begin")


func test_release_emits_after_hold() -> void:
	var p := _make_player()
	@warning_ignore("inferred_declaration") var monitor := monitor_signals(p)
	p._on_interact_pressed()
	p._interact_press_time_msec = Time.get_ticks_msec() - 250
	p._poll_interact_hold()
	p._on_interact_released()
	await assert_signal(monitor).is_emitted("interact_release")


func test_modal_gate_suppresses_press() -> void:
	var p := _make_player()
	var g: AlwaysOpenGate = auto_free(AlwaysOpenGate.new())
	add_child(g)
	p.register_modal_gate(g)
	p._on_interact_pressed()
	# Press should be ignored — _interact_press_time_msec stays at -1.
	assert_int(p._interact_press_time_msec).is_equal(-1)


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
