# Character Controller Post-Phase 7 Audit

Date: 2026-05-10  
Auditor: Codex  
Scope: Read-only follow-up audit after `spec-driven/features/character-controller-productionization/review.md` and `next_audit_brief.md`.

## Executive Summary

The Phase 7 repair moved the character controller in the right architectural direction. The largest prior issue, animation owning movement state, is resolved: `PlayerController` now drives `CharacterMotor`, `CharacterMotor` owns `MoveContainer`, and `CharacterAnimationSystem` observes the resulting `MovementState`. The carry controller also now follows the Source/HL2-style velocity-drive pattern instead of the older direct-transform carry approach.

The controller is not production-complete yet. The remaining risks are mostly contract drift: fly-camera interaction lacks a documented active input-context owner, several exported movement config fields are no-ops, teleport paths skip Godot's required physics interpolation reset, and docs/status files still describe older interaction and carry behavior. These are fixable without replacing the new Phase 7 ownership model.

Runtime/editor verification is still pending. Per the project's Codex limitation, this audit did not launch Godot, run gdUnit, or interactively verify `scenes/Godotwind.tscn`.

## Findings

### P1 - Fly-Camera Interaction Lacks a Formal Input-Context Owner

Follow-up research changed the framing of this finding. A fly/free camera is allowed to have its own input owner in a production engine, but that owner needs to be a formal mode-scoped input context. The current Godotwind issue is not "fly camera reads input at all"; it is that the project contract says `PlayerController` is the only owner of raw `interact`, while `world_explorer.gd` also implements a parallel owner without documenting the active-context handoff.

The current Godotwind input contract says `PlayerController` is the only owner of raw `interact` input:

- `src/core/player/player_controller.gd:33-36` says no other gameplay system should read `Input.is_action_pressed("interact")` directly.
- `docs/systems/input_system.md:38` lists `interact` as owned by `PlayerController ONLY`.
- `docs/systems/input_system.md:73` says interaction input is owned exclusively by `PlayerController`.

However, `src/tools/world_explorer.gd` owns a parallel raw-interact path for fly-camera mode:

- `world_explorer.gd:224-230` declares fly interaction press/hold state.
- `world_explorer.gd:3032-3044` reads `event.is_action_pressed(&"interact")` and `event.is_action_released(&"interact")`.
- `world_explorer.gd:3184-3190` polls fly interaction hold state every frame.
- `world_explorer.gd:3420-3444` duplicates the tap/hold split.
- `world_explorer.gd:3456-3476` routes fly taps directly to interaction/carry behavior.

The industry pattern is "one active context owns an action at a time", not necessarily "the player controller owns every action forever":

- OpenMW exposes explicit input and control APIs, including control overrides and camera modes. Its `MODE.Static` camera is a formal camera mode where the camera no longer follows the player and is driven through explicit static camera position/orientation calls.
- Godot's editor shortcuts are context-sensitive: the same physical input can mean different things depending on the active editor context, and 3D editor freelook uses editor-specific action names rather than player gameplay actions.
- Unreal Enhanced Input models this with add/remove/prioritized mapping contexts.
- Unity's Input System models this with separate `InputActionMap`s for gameplay, UI, vehicles, and other active modes.
- Source/id-family noclip is the alternative standard: the player remains the input owner, but movement/collision mode changes. Valve's `noclip`, ZDoom/GZDoom player cheat flags, and OpenMW's debug collision controls follow this family.
- Ocarina of Time's debug camera is an older but still illustrative separation: debug-camera input is isolated from normal player input rather than hidden as a duplicate normal gameplay reader.

This means Godotwind currently sits halfway between two valid patterns. It has a separate fly/editor camera mode, but it duplicates gameplay `interact` tap/hold semantics outside `PlayerController` while the docs still claim `PlayerController ONLY`. Future interaction fixes can easily land in one path and miss the other.

Suggested repair: define an explicit input-context ownership model. For example, document `PlayerGameplayContext` as the owner of `interact` in player mode and `FlyCameraContext` as the owner in fly/debug mode, with exactly one context active at a time. Shared semantics like tap-vs-hold should live in a small reusable interaction-intent helper so player mode and fly mode do not drift. If the intended design is Source-style noclip instead, keep `PlayerController` as the sole owner and convert fly movement into a player movement/collision mode instead of a second interaction path.

### P2 - Several `CharacterMovementConfig` Fields Are Exported but Not Enforced

`CharacterMovementConfig` is now the right place for movement tuning, but several exposed fields appear to be inert despite being preset/documented as behavioral controls:

- `character_movement_config.gd:21-23` exports `turn_to_movement_direction`, `smooth_movement`, and `smooth_player_turning_delay`.
- `character_movement_config.gd:56-57` exports `swim_upward_correction_enabled` and `swim_upward_coef`.
- `character_movement_config.gd:63-64` exports `step_down_height` and `min_step_height`.
- `morrowind_movement_config.tres:7-8` and `morrowind_movement_config.tres:15-17` set some of these values as if they are active behavior.

The move implementations always rotate toward movement without checking the turn policy or smooth-turn flags:

- `run_move.gd:54-60`
- `walk_move.gd:58-64`
- `sprint_move.gd:45-51`
- `crouch_move.gd:80-86`
- `swim_move.gd:47-54`

The step solver only appears to use `max_step_height` and `step_up_height`:

- `move_container.gd:336-339`
- `move_container.gd:373`

Swim movement and input do not appear to use the upward correction fields:

- `player_input_gatherer.gd:35-38`
- `swim_move.gd:39-43`

The practical issue is modding trust. A creator can override a `.tres` field that looks supported and see no behavior change, while the spec frames movement config as a source of truth.

Suggested repair: either implement these fields or mark them as reserved/future-only in the resource, docs, and tests. The important part is that exported mod-facing knobs should not silently do nothing.

### P2 - Teleport Paths Do Not Consistently Reset Physics Interpolation

Godot's physics interpolation docs require an interpolation reset after discontinuous teleports to avoid visual streaking. Project-wide physics interpolation is enabled, so teleport helpers need to own this consistently.

`PlayerController.teleport_to()` directly changes position and velocity without resetting interpolation:

- `player_controller.gd:604-607`

That helper is used when switching into main player mode:

- `world_explorer.gd:1412-1422`

`InteriorPocketManager` also writes player/camera transforms directly during transitions without an interpolation reset:

- `interior_pocket_manager.gd:1363-1370`

The project already demonstrates the correct pattern in the Phase 6 step test scene:

- `test_character_controller_steps.gd:298-303` calls `reset_physics_interpolation()` after `teleport_to()`.

Suggested repair: make `PlayerController.teleport_to()` reset interpolation after assigning the transform, and add the same reset to any direct transition path that bypasses that helper. Prefer `Node3D.reset_physics_interpolation()` over older server-level reset calls.

### P2 - Carry Release Can Skip Restoring a Valid Body if the Pickup Wrapper Is Invalid

`CarryController.release()` captures the carried rigid body, emits `released`, clears controller state, then returns early if `pickup` is invalid:

- `carry_controller.gd:323-351`

Because `_do_release()` is skipped behind the `pickup` validity guard, a still-valid `RigidBody3D` can miss restoration of collision mask, gravity scale, damping, and streaming registration if the `Interactable` wrapper has been detached/freed first.

The unit coverage validates `_do_release()` directly:

- `tests/unit/test_character_controller_phase0_baseline.gd:736-754`

That does not cover the public `release()` edge case where `pickup` is invalid but `rb` is still valid.

Suggested repair: restore based on the captured rigid body validity, not the pickup wrapper validity. The release path can still tolerate a missing pickup for logging/signals, but physics cleanup should be body-driven.

### P2 - Carry-Mode Prompt Suppression Is Documented but Not Implemented

`docs/systems/interaction_system.md:197` says that while carrying an object, raycaster prompt updates are suppressed and tap interaction is ignored.

The tap interaction gate exists:

- `player_controller.gd:774-783`

Prompt suppression does not appear to exist in the raycaster or prompt callback:

- `interaction_raycaster.gd:246-253` emits prompt changes for target changes.
- `world_explorer.gd:3375-3384` shows any non-null prompt target.

The practical result is a UI mismatch: while the player is holding an item, the HUD may still show an interaction prompt even though `PlayerController` will ignore the tap.

Suggested repair: hide or suppress prompts while the relevant carry controller is carrying, or update the docs if prompt visibility is intentionally independent. The smaller production behavior is to match the documented exclusive carry mode.

### P2 - Main Visual Controller Test Still Uses Raw Keycode Hotkeys

The project rule says visual/integration/manual test scenes must use the unified `InputMap` actions, not raw keycode branches. `tests/visual/test_character_controller.gd` still uses direct keycode checks for its debug/test commands:

- `test_character_controller.gd:66-77`

The newer step visual test does verify the input action contract:

- `test_character_controller_steps.gd:28-30`

This does not appear to affect movement input itself, which still flows through `PlayerController`, but the scene is part of the validation surface and should follow the same input portability rules.

Suggested repair: add namespaced visual-test actions for preset switching, HUD toggle, and debug dump, then route this scene through `InputMap` actions.

### P2 - `docs/STATUS.md` Is No Longer Ground Truth for Interaction and Carry

`docs/STATUS.md` is documented as the ground truth, but its interaction/carry sections describe older behavior that contradicts current code and newer system docs:

- `docs/STATUS.md:25` says the interaction framework is not wired into the main streaming scene.
- `docs/STATUS.md:26` says carry is still kinematic direct-transform hold logic with main-scene integration as a next deliverable.
- `docs/STATUS.md:44` says the main scene does not wire player, carry, raycaster, and streaming-manager handoff.

Current code does wire interaction/carry in `world_explorer.gd`:

- `world_explorer.gd:1051-1076`
- `world_explorer.gd:3281-3284`

The carry implementation is now velocity-driven:

- `carry_controller.gd:417-476`

`docs/systems/character_controller.md:9-16` is more accurate about partial main-scene verification and remaining blocked checks. `STATUS.md` should be reconciled with that.

Suggested repair: update `docs/STATUS.md` so future implementers do not plan work against stale "not wired" / "kinematic carry" assumptions.

### P3 - Movement State Jump Semantics Are Ambiguous

`PlayerController.is_jumping` is documented as "upward velocity while airborne":

- `player_controller.gd:167-168`

`MoveContainer._publish_movement_state()` sets `is_jumping` true when the current move is either `jump` or `midair`:

- `move_container.gd:180-185`

That means the public flag can be true while falling. If no gameplay code consumes this yet, this is a maintainability issue rather than a live bug. It is still a confusing API surface for future gameplay, animation, debug UI, or mod scripts.

Suggested repair: either rename/split the state (`is_airborne`, `is_jump_move`, `has_upward_jump_velocity`) or update comments/docs so the public meaning is clear.

### P3 - Stale Comments and Doc Paths Remain After the Refactor

Several comments still point to old docs or pre-refactor ownership:

- `world_explorer.gd:1571` says animation wiring includes `MoveContainer`, but movement is no longer animation-owned.
- `input_actions.gd:13-16` references old root-level docs paths instead of `docs/systems/input_system.md` and `docs/systems/interaction_system.md`.
- `player_controller.gd:36`, `player_controller.gd:275`, `player_controller.gd:325`, `player_controller.gd:333`, and `player_controller.gd:628` reference `docs/INTERACTION_SYSTEM.md`.
- `interaction_raycaster.gd:11` and `world_explorer.gd:1418` reference the same old path.
- `carry_controller.gd:11` points to `.claude/CLAUDE.md` instead of the current project instruction surface.

Suggested repair: update these comments during the next cleanup pass. No behavior change is needed, but stale comments are especially risky in this repo because architecture docs are used as handoff contracts.

## Positive Findings

- The previous critical animation/movement ownership violation appears repaired. `PlayerController._physics_process()` drives movement first and then forwards the resulting movement state to animation (`player_controller.gd:296-302`).
- `CharacterMotor` owns `PlayerInputGatherer`, `MoveContainer`, and `MovementState` (`character_motor.gd:17-42`).
- `CharacterAnimationSystem` observes movement state rather than creating/owning movement components (`character_animation_system.gd:200-221`).
- Movement remains centralized around `CharacterBody3D.move_and_slide()` in `MoveContainer`, which matches the canonical Godot pattern.
- Move timing is delta-driven through the move stack (`move.gd:78-80`, `move.gd:217-218`).
- Carry control now uses velocity drive (`carry_controller.gd:417-476`), aligning with the requested HL2/Source-style pattern.
- The codebase now has useful focused unit coverage around character controller contracts, carry restore behavior, and input actions in `tests/unit/test_character_controller_phase0_baseline.gd`.

## Open Questions and Assumptions

- I treated `world_explorer.gd` fly-camera interaction as in scope because `next_audit_brief.md` explicitly asked for input ownership and main-scene wiring review. If fly mode is meant to be an editor-only exception, the docs should say so and name its owner.
- I did not classify no-op config fields as P1 because the controller can still run without them. They become P1 only if a production preset or modding requirement currently depends on those fields.
- I assumed `docs/STATUS.md` should remain the highest-level shipped/not-shipped source because `AGENTS.md` says it is ground truth.

## Suggested Next Repair Plan

1. Resolve the `interact` ownership contract first. Pick the active-context model for player mode and fly mode, update docs, then remove duplicate tap/hold semantics where possible.
2. Patch teleport helpers to reset physics interpolation after discontinuous position/basis writes. This is small and should be done before more visual verification.
3. Decide which `CharacterMovementConfig` fields are shipping in this milestone. Implement the shipping fields and mark the rest reserved/future-only.
4. Fix carry release cleanup to restore valid rigid bodies even when the pickup wrapper has gone invalid, then add a public `release()` regression test.
5. Reconcile prompt behavior during carry mode with `docs/systems/interaction_system.md`.
6. Update `docs/STATUS.md` and stale comment paths so the next implementation pass starts from accurate contracts.

## Validation Status

Static audit only:

- Read the Phase 7 review and next audit brief.
- Read the spec-driven workflow/constitution context.
- Inspected controller, movement, animation, interaction, carry, input, main-scene wiring, visual tests, and live docs.
- Checked official Godot 4.6 docs for `CharacterBody3D`, physics interpolation reset expectations, `InputMap` behavior, and editor shortcut context behavior.
- Checked OpenMW, Godot editor, Unreal Enhanced Input, Unity Input System, Valve/Source noclip, ZDoom/GZDoom player flag documentation, and Ocarina of Time debug-camera references for fly/free-camera input ownership patterns.

Not run:

- Godot editor launch.
- `scenes/Godotwind.tscn` interactive player-mode check.
- gdUnit4 test scene.
- C# build.

Human verification remains pending per the project rule. No C# or shader files changed during this audit, so no `dotnet build` or shader cache clear was required for the audit document itself.

## External References Checked

- Godot 4.6 `CharacterBody3D`: https://docs.godotengine.org/en/4.6/classes/class_characterbody3d.html
- Godot 4.6 physics interpolation: https://docs.godotengine.org/en/4.6/tutorials/physics/interpolation/using_physics_interpolation.html
- Godot 4.6 `InputMap`: https://docs.godotengine.org/en/4.6/classes/class_inputmap.html
- Godot editor shortcut context / 3D freelook shortcuts: https://docs.godotengine.org/en/4.6/tutorials/editor/default_key_mapping.html
- OpenMW input API: https://openmw-master.readthedocs.io/en/latest/reference/lua-scripting/openmw_input.html
- OpenMW camera API: https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_camera.html
- OpenMW controls interface: https://openmw.readthedocs.io/en/openmw-0.49.0/reference/lua-scripting/interface_controls.html
- OpenMW debug API: https://openmw.readthedocs.io/en/stable/reference/lua-scripting/openmw_debug.html
- Unreal Engine Enhanced Input overview: https://dev.epicgames.com/documentation/en-us/unreal-engine/input-overview-in-unreal-engine
- Unity Input System `InputActionMap`: https://docs.unity.cn/Packages/com.unity.inputsystem@1.13/api/UnityEngine.InputSystem.InputActionMap.html
- Valve Developer Community `noclip`: https://developer.valvesoftware.com/wiki/Noclip
- ZDoom player info flags: https://zdoom.org/wiki/Structs:PlayerInfo
- Ocarina of Time debug camera notes: https://xnamkcor.tripod.com/oot_debug.htm
- zeldaret Ocarina of Time camera source: https://github.com/zeldaret/oot/blob/main/src/code/z_camera.c
