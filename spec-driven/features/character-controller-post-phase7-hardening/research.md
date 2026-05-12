# Research: Character Controller Post-Phase 7 Hardening

Date: 2026-05-10
Owner: Codex
Status: draft implementation-plan research

## Purpose

Convert the post-Phase 7 audit into an implementation-ready repair package.

This research is narrow. The large Phase 7 ownership correction already landed:
`PlayerController` drives `CharacterMotor`, `CharacterMotor` owns movement, and
animation observes `MovementState`. The remaining work is contract hardening:
input ownership in fly/player modes, exported config truthfulness, teleport
interpolation reset, carry cleanup, prompt gating, test input portability, and
stale handoff docs.

Primary audit:

- `docs/audit/character_controller_post_phase7_audit_2026_05_10_codex.md`

## Questions

- How should Godotwind model fly-camera interaction without drifting from the
  `PlayerController` interaction contract?
- Which audit findings should be implemented as behavior changes, and which are
  documentation/API contract repairs?
- What Godot-specific requirements constrain teleport, input, and physics
  behavior?
- How can the work be split so each slice is independently testable by the
  human/user, given Codex cannot reliably launch Godot here?
- Which behavior must remain generic framework code versus Morrowind adapter
  behavior?

## Industry Patterns

### Active input contexts

Production input systems usually separate physical bindings from the currently
active gameplay context.

Unreal Enhanced Input models this with input mapping contexts that can be added,
removed, and prioritized per player. Higher-priority contexts can block lower
priority contexts when input is consumed.

Unity Input System models this with `InputActionMap`. Actions are owned by one
map at a time, maps can be enabled/disabled in bulk, and bindings can be masked
or scoped.

Godot does not ship a full runtime context stack over `InputMap`, but the same
principle can be implemented simply: the project has one canonical action
namespace, and the active mode decides which owner is allowed to interpret a
given action this frame.

### Editor/fly cameras

Godot's editor itself uses context-specific shortcut actions. The 3D editor has
freelook-specific action names such as `spatial_editor/freelook_forward`,
`spatial_editor/freelook_up`, and `spatial_editor/freelook_speed_modifier`.
The important lesson is not the exact names; it is that editor/fly controls are
a formal active context rather than invisible duplicates of player gameplay.

OpenMW exposes explicit camera modes. Its `Static` mode is a camera mode where
the camera does not track the player and player input does not affect the
camera; scripts move the static camera through dedicated API calls. OpenMW also
encourages actions/triggers over direct device reads for most mod-facing input.

### Source-style noclip alternative

Source/id-family noclip is also a valid pattern: keep the player/pawn as the
input owner, but switch the pawn's collision and movement mode. This avoids a
second camera owner, but it is a larger architectural change for Godotwind
because the current main scene already has a separate `FlyCamera` and separate
player-controller mode.

## Godot Findings

- `InputMap` is the native place for named actions. Scripts then query action
  state through action names rather than raw keycodes.
- Mouse motion is not an `InputMap` action in Godotwind's current input-system
  contract; mouse look remains event-driven in the active camera/controller.
- Godot editor shortcuts are context-sensitive: the same physical key can be
  meaningful in different editor tools depending on active context.
- Godot physics interpolation requires a reset after discontinuous teleport
  writes. Godot's `Node3D.reset_physics_interpolation()` is the intended local
  reset API for nodes that were just moved discontinuously.
- This feature should not add an autoload. Existing patterns prefer small
  helper scripts/resources and explicit wiring.

## OpenMW Reference

This feature is not a Morrowind formula/parity change. OpenMW is useful only as
a camera/input ownership reference.

- Relevant OpenMW APIs: `openmw.camera` modes and `openmw.input` actions and
  triggers.
- Formulas, constants, or settings found: none needed.
- Behavioral edge cases: a static/free camera is a formal mode; player input
  should not accidentally affect camera behavior in that mode.
- What should become Morrowind-specific adapter behavior: none.
- What belongs in the generic Godotwind framework: active input-context
  ownership, interaction intent splitting, teleport/interpolation safety,
  movement-config contract clarity, carry release cleanup, and prompt gating.

## Options

### Option A: Explicit Active Contexts Over Current Fly/Player Modes

- Benefits:
  - Matches Unreal/Unity/Godot editor context patterns.
  - Fits the current Godotwind scene architecture.
  - Allows `PlayerController` to own player-mode interact while fly mode has a
    named owner.
  - Keeps the implementation small and reviewable.
- Costs:
  - `docs/systems/input_system.md` and `docs/systems/interaction_system.md`
    must soften "PlayerController ONLY" into "one active context owns interact."
  - Shared tap/hold semantics need a helper so player and fly contexts do not
    drift.
- Risks:
  - If implemented as docs only, duplicate tap/hold code will drift again.
- Fit for Godotwind:
  - Best fit for the current codebase and the smallest canonical repair.

### Option B: Source-Style Noclip Through PlayerController

- Benefits:
  - Single gameplay input owner remains literal.
  - Fly interaction can reuse player interaction events without a second owner.
- Costs:
  - Larger rewrite: fly movement becomes a player movement/collision mode.
  - Could destabilize streaming/debug tooling that assumes a separate fly
    camera.
- Risks:
  - More invasive than the audit requires.
- Fit for Godotwind:
  - Valid long-term option only if the project wants to delete separate fly
    camera mode later.

### Option C: Leave Code As-Is and Update Docs Only

- Benefits:
  - Fastest.
- Costs:
  - Keeps duplicated tap/hold state and duplicate raw `interact` readers.
  - Does not prevent future fixes from landing in only one path.
- Risks:
  - Reintroduces the exact contract drift found in the audit.
- Fit for Godotwind:
  - Not recommended.

## Recommendation

Use Option A.

Define `PlayerGameplayContext` and `FlyCameraContext` as explicit active input
contexts. Exactly one context owns `interact` at a time:

- Player mode: `PlayerController` reads raw `interact` and emits semantic
  interaction intent.
- Fly/debug mode: `world_explorer.gd` owns fly-mode interaction, but it must use
  the same interaction-intent helper as player mode.

This keeps the current scene architecture and makes the exception explicit. It
also avoids a new autoload or speculative full input stack.

## Risks and Unknowns

- The main scene currently mixes gameplay, debug tools, fly camera, and UI in
  `world_explorer.gd`; extracting too much at once would become a refactor
  instead of hardening.
- Config fields need field-by-field decisions. Some should be enforced now;
  others should be marked reserved/future-only instead of silently no-oping.
- Prompt suppression may be cleaner in `InteractionRaycaster`, but the active
  carry controller lives outside it. The implementation should avoid importing
  `CarryController` into the raycaster.
- Runtime validation depends on the human/user because Codex cannot reliably
  launch Godot in this workspace.

## Sources

Local:

- `docs/audit/character_controller_post_phase7_audit_2026_05_10_codex.md`
- `spec-driven/README.md`
- `spec-driven/00-constitution.md`
- `spec-driven/01-workflow.md`
- `spec-driven/features/character-controller-productionization/*`
- `docs/systems/input_system.md`
- `docs/systems/interaction_system.md`
- `docs/STATUS.md`
- `src/tools/world_explorer.gd`
- `src/core/player/player_controller.gd`
- `src/core/interaction/carry_controller.gd`
- `src/core/interaction/interaction_raycaster.gd`
- `src/core/character/controller/character_movement_config.gd`

External:

- Godot 4.6 InputMap: https://docs.godotengine.org/en/4.6/classes/class_inputmap.html
- Godot 4.6 input examples: https://docs.godotengine.org/en/4.6/tutorials/inputs/input_examples.html
- Godot 4.6 physics interpolation: https://docs.godotengine.org/en/4.6/tutorials/physics/interpolation/using_physics_interpolation.html
- Godot 4.6 default editor shortcuts: https://docs.godotengine.org/en/4.6/tutorials/editor/default_key_mapping.html
- Unreal Enhanced Input subsystem API: https://dev.epicgames.com/documentation/en-us/unreal-engine/python-api/class/EnhancedInputSubsystemInterface?application_version=5.3
- Unity InputActionMap: https://docs.unity.cn/Packages/com.unity.inputsystem@1.13/api/UnityEngine.InputSystem.InputActionMap.html
- OpenMW camera API: https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_camera.html
- OpenMW input API: https://openmw-master.readthedocs.io/en/latest/reference/lua-scripting/openmw_input.html
