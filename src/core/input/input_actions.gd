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
## See `docs/INPUT_SYSTEM.md` for the full design rationale, action table,
## addon survey, and decision history.
##
## COORDINATION CONTRACT (per docs/INTERACTION_SYSTEM.md §3.1):
##   - The `interact` action is OWNED by `PlayerController`. Do NOT add a
##     second listener on it. Do NOT redefine it. Do NOT touch mouse mode
##     from input code — that is also `PlayerController`'s job.
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

## Interaction actions — `interact` is OWNED by PlayerController. Do not add
## a second listener. See coordination contract above.
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
## PlayerController.HOLD_THRESHOLD for cross-reference only — the live value
## lives in player_controller.gd. If you change one, change BOTH.
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
