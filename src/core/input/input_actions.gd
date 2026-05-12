## InputActions — single source of truth for the Godotwind action namespace.
##
## This is a STATIC class. NOT an autoload. NOT instantiated.
##
## Action definitions live in `project.godot [input]` (loaded automatically by
## every scene including test scenes — that is the test-scene contract).
##
## This file's job is:
##   1. Document the canonical action list as code constants
##   2. Provide a verify() function that asserts every required action exists
##   3. Document the AZERTY / controller / mouse-not-bindable design decisions
##
## See `docs/systems/input_system.md` for the full design rationale, action table,
## addon survey, and decision history.
##
## COORDINATION CONTRACT (per docs/systems/interaction_system.md §3.1):
##   - The active input context owns `interact`: PlayerGameplayContext routes it
##     through PlayerController, FlyCameraContext routes it through world_explorer.
##     Do NOT redefine it or add an ungated listener.
##
## REDUNDANCY NOTE:
##   `PlayerController._ensure_input_actions` (player_controller.gd:381) is a
##   runtime safety net that re-creates these actions if missing. After K.0
##   it is REDUNDANT (the actions live in project.godot) but it is left in
##   place because (a) it is idempotent — `InputMap.add_action` is gated on
##   `has_action`, (b) removing it would force a `PlayerController` edit which
##   K.0 explicitly forbids per the coordination contract above.
##   Cleanup is queued for a follow-up phase AFTER K.0.5 ships.
class_name InputActions
extends RefCounted


# =============================================================================
# ACTION NAMESPACE
# =============================================================================
# Grouped by category. Reviewer requirement: explicit namespace tree so future
# agents do not collide on action names.

## Movement actions — read by PlayerInputGatherer + FlyCamera
const MOVEMENT: Array[StringName] = [
	&"move_forward",
	&"move_backward",
	&"move_left",
	&"move_right",
	&"jump",
	&"crouch",
	&"sprint",
	&"walk",
]

## Camera actions — controller right stick ONLY. Mouse motion stays event-driven
## in PlayerController._input(InputEventMouseMotion). See MOUSE-NOT-BINDABLE note.
const CAMERA: Array[StringName] = [
	&"look_left",
	&"look_right",
	&"look_up",
	&"look_down",
	&"toggle_camera",
]

## Interaction actions — `interact` is owned by exactly one active context.
## See coordination contract above.
const INTERACTION: Array[StringName] = [
	&"interact",
]

## UI actions — `ui_cancel` and `ui_accept` are Godot built-ins, no rebinding
## needed. Listed here for documentation only.
const UI: Array[StringName] = [
	&"ui_cancel",
	&"ui_accept",
]

## Debug actions — developer-only, may be unbound or rebound freely
const DEBUG: Array[StringName] = [
	&"debug_console",
	&"debug_screenshot",
]

## Visual-test actions — optional developer controls for standalone test scenes.
const VISUAL_TEST: Array[StringName] = [
	&"impostor_sun_left",
	&"impostor_sun_right",
	&"impostor_sun_up",
	&"impostor_sun_down",
	&"impostor_bake_v6",
	&"impostor_debug_normals",
	&"impostor_toggle_models",
	&"impostor_toggle_billboard",
	&"hlod_toggle",
	&"hlod_benchmark_toggle",
	&"hlod_dump_stats",
	&"hlod_teleport_tier",
	&"hlod_debug_chunks_toggle",
	&"hlod_fade_toggle",
	&"impostor_stress_toggle_bounds",
	&"impostor_stress_force_visible",
	&"impostor_stress_reload_area",
	&"character_controller_preset_1",
	&"character_controller_preset_2",
	&"character_controller_preset_3",
	&"character_controller_preset_4",
	&"character_controller_preset_5",
	&"character_controller_toggle_debug_hud",
	&"character_controller_dump_kf_bones",
	&"step_solver_respawn",
	&"teleport_test_player",
	&"teleport_test_fly_camera",
	&"teleport_test_transition_write",
	&"teleport_test_reset",
]


## Required actions — verify() asserts every entry exists in InputMap.
## Excludes `walk` (intentionally unbound by default per K.0 SF2 ruling) and
## the UI built-ins.
const REQUIRED_ACTIONS: Array[StringName] = [
	&"move_forward",
	&"move_backward",
	&"move_left",
	&"move_right",
	&"jump",
	&"crouch",
	&"sprint",
	&"look_left",
	&"look_right",
	&"look_up",
	&"look_down",
	&"toggle_camera",
	&"interact",
	&"debug_console",
	&"debug_screenshot",
]


# =============================================================================
# CONSTANTS
# =============================================================================

## Stick deadzone reference value. NOTE: Godot stores deadzone per-binding in
## project.godot (`deadzone=0.2` field on each action's events array). This
## constant is DOC ONLY — the live value lives in project.godot. If you change
## one, change BOTH. K.0 SF4 design call.
const STICK_DEADZONE: float = 0.2

## Hold threshold for `interact` long-press detection. Mirrored from
## InteractionIntent.DEFAULT_HOLD_THRESHOLD for cross-reference only — the live
## value lives in `src/core/interaction/interaction_intent.gd`.
const INTERACT_HOLD_THRESHOLD: float = 0.20


# =============================================================================
# VERIFICATION
# =============================================================================

## Assert every required action exists in the live InputMap.
## Call once from scene roots (Godotwind.tscn, every test scene) in _ready().
## Both Log.error AND assert: release builds strip asserts but keep Log.error,
## debug builds get both. Per K.0 MF3 ruling.
static func verify() -> void:
	var missing: Array[StringName] = []
	for action_name in REQUIRED_ACTIONS:
		if not InputMap.has_action(action_name):
			missing.append(action_name)
	if missing.is_empty():
		Log.info("input", "InputActions.verify() OK — %d required actions present" % REQUIRED_ACTIONS.size())
		return
	Log.error("input", "InputActions.verify() FAIL — missing actions: %s" % str(missing))
	assert(missing.is_empty(), "missing required input actions: %s" % str(missing))
