# Interior / Exterior Transition Audit - 2026-05-30

## Scope

This audit reviews the current outdoor-to-indoor transition pipeline in Godotwind:

- how doors become interactable
- how prompts appear
- how the `interact` action reaches a door
- how interior pockets are preloaded and committed
- where the architecture violates the framework/adapter boundary
- which dead or duplicate paths are still present

This is an audit, not a fix. No gameplay code was changed as part of this pass.

## Veracity Follow-up

2026-05-30 follow-up review: the major code-facing claims below were checked
against the current workspace after the first draft of this document. The first
draft was directionally accurate, but incomplete. In particular, it missed two
transition-critical risks and underplayed one fade-state risk:

- a pocket can become "visual playable" before its critical interactables are
  published
- exterior tracking unfreeze can update the cached camera cell without forcing a
  desired-cell refresh
- the fade-to-black bridge can reset alpha during commit because fade state is
  implicit instead of owned by the transition state machine

Those findings are now included below. Existing project docs and comments remain
evidence only; code and current engine documentation are the authority.

## Research Baseline

Production open-world RPGs generally treat interiors as explicit world topology, not as generic triggers.

- OpenMW models exterior travel as continuous grid traversal and interior travel as explicit door teleport data on placed door instances. A door placement carries destination cell, destination position, and facing. Source: <https://openmw.readthedocs.io/en/latest/reference/modding/doors-and-teleports.html>
- Unreal's production pattern is level/world streaming controlled by authored volumes or explicit runtime requests. Epic's level streaming volume docs call out sizing volumes so content is loaded before the player reaches it, and even mention door state gating for locked/openable doors. Source: <https://dev.epicgames.com/documentation/en-us/unreal-engine/level-streaming-volumes-reference-in-unreal-engine>
- Unity's production async scene pattern is additive async loading with activation control; the final scene activation still has main-thread cost. Source: <https://docs.unity.cn/Packages/com.unity.addressables@1.21/manual/LoadingScenes.html>
- Godot 4.6 supports threaded resource loading through `ResourceLoader.load_threaded_request()`, but active scene tree mutation is not thread-safe and must return to the main thread. Sources: <https://docs.godotengine.org/en/4.6/classes/class_resourceloader.html> and <https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html>
- Godot's native input architecture favors `InputMap` actions instead of raw key polling. Source: <https://docs.godotengine.org/en/4.6/tutorials/inputs/inputevent.html>
- Godot `Area3D` is the native 3D region/query node, but query layers must be treated separately from physics collision policy. Source: <https://docs.godotengine.org/en/4.6/classes/class_area3d.html>

The production-ready target for Godotwind should be:

1. Source-neutral transition descriptors in core.
2. Game-specific door/DODT/DNAM parsing in the Morrowind adapter.
3. A transition state machine with explicit states: idle, candidate, prefetching, ready, committing, stabilizing, complete, failed.
4. Async destination preparation with bounded main-thread publishing.
5. A promptable door even when destination preload is still in progress.
6. A fade/loading bridge only when the destination is not ready by activation time.
7. Exterior tracking frozen only during committed interior travel, while async completions keep draining.
8. Interaction query layers preserved independently from physics collision layers.

## Current Pipeline

### Input and prompt

- `project.godot:58` binds `interact` to physical E.
- `PlayerController` owns player-mode `interact` press/release and routes tap to the current raycast target in `src/core/player/player_controller.gd:323` and `src/core/player/player_controller.gd:703`.
- Fly mode has a separate input owner in `src/tools/world_explorer.gd:3788`, which mirrors player tap/hold behavior.
- `InteractionRaycaster` casts against collision layer 3 only, walks up to an `Interactable` ancestor, checks `can_interact()`, and emits `prompt_changed` in `src/core/interaction/interaction_raycaster.gd:50` and `src/core/interaction/interaction_raycaster.gd:220`.
- `world_explorer` displays the prompt from the raycaster in `src/tools/world_explorer.gd:4151`.

Important: current prompts are crosshair/raycast prompts, not proximity prompts. Standing near a door is not sufficient if the ray does not hit a layer-3 interaction shape.

### Door spawning and activation

- The Morrowind spawn adapter attaches `DoorInteractable` only for teleport doors in `src/core/world/morrowind/morrowind_object_spawn_adapter.gd:86`.
- It sets `record_id`, `door_instance_key`, prompt fields, and generates a passive layer-3 `InteractionArea` in `src/core/world/morrowind/morrowind_object_spawn_adapter.gd:344` and `src/core/world/morrowind/morrowind_object_spawn_adapter.gd:369`.
- The generated query target is an `Area3D` on layer 3 in `src/core/world/reference_instantiator.gd:2068`.
- `DoorInteractable.interact()` emits `door_activated` with a placed-door key in `src/core/interaction/morrowind/door_interactable.gd:24`.
- `CellManager.set_door_activated_handler()` installs the main-scene callback in `src/core/world/cell_manager.gd:301`.
- `world_explorer._on_door_interactable_activated()` resolves the placed key to `InteriorPocketManager.DoorInfo`, then calls `_activate_door()` in `src/tools/world_explorer.gd:4116` and `src/tools/world_explorer.gd:4256`.

### Door registration

- `InteriorPocketManager.register_exterior_cell_doors()` scans loaded exterior cell references and registers only teleport doors whose destination is an interior cell in `src/core/world/interior_pocket_manager.gd:398`.
- Exterior door keys are built by `make_exterior_door_instance_key()` in `src/core/world/interior_pocket_manager.gd:172`.
- Interior door keys are built later by `make_interior_door_instance_key()` in `src/core/world/interior_pocket_manager.gd:176`.
- Interior door interactables are not born with their final key. They are spawned with a default exterior-style key by the adapter and later patched by `_sync_door_interactable_instance_key()` through `DoorUtils.find_by_ref_id()` in `src/core/world/interior_pocket_manager.gd:494`.

### Interior preload and commit

- `world_explorer._process()` calls `_pocket_manager.update(camera.global_position, delta)` every frame in `src/tools/world_explorer.gd:3953`.
- Exterior update chooses the closest registered door and preloads only that door's target pocket inside `PRELOAD_RADIUS` in `src/core/world/interior_pocket_manager.gd:610`.
- `PRELOAD_RADIUS` is currently 10m and `INTERACT_RADIUS` is 3m in `src/core/world/interior_pocket_manager.gd:43`.
- `_load_pocket()` uses `CellManager.request_cell_async(cell_name, LoadProfile.interior_pocket())` in `src/core/world/interior_pocket_manager.gd:836` and `src/core/world/interior_pocket_manager.gd:874`.
- `LoadProfile.interior_pocket()` disables static RenderingServer batching for pockets so objects render under the pocket offset instead of ESM world position.
- `_prepare_target_pocket_for_transition()` forces priority, fades to black, waits for the async pocket and finish-up phases, and times out after 20s in `src/core/world/interior_pocket_manager.gd:1187`.
- `world_explorer._activate_door()` freezes exterior tracking before exterior-to-interior travel and unfreezes after exit in `src/tools/world_explorer.gd:4256`.
- `NativeStreamingManager.set_world_tracking_frozen()` preserves the exterior anchor while still allowing async completions in `src/core/world/native_streaming_manager.gd:658`.

## Findings

### 1. Exterior doors can be visible but not promptable

Severity: high. Likelihood: high.

Interactive doors are proximity-deferred at 25m when static renderer mode is active:

- threshold: `src/core/world/reference_instantiator.gd:263`
- defer decision: `src/core/world/reference_instantiator.gd:764`
- requeue function: `src/core/world/cell_manager.gd:2636`

The only runtime call found for `tick_proximity_deferred()` is inside `NativeStreamingManager._update_loaded_cells()` at `src/core/world/native_streaming_manager.gd:1604`. That function normally runs on cell load/unload/update work, not as a guaranteed per-frame proximity pump. So a player can approach a visible door proxy in an already-loaded cell and never get the actual `DoorInteractable` node published. Result: no layer-3 ray target, no prompt, and E does nothing.

Practical symptom: "Not all doors show the interaction prompt even when they should."

Production fix direction: move proximity-deferred requeue to a throttled runtime tick that runs regardless of cell-grid changes. The function already self-throttles, so the architecture should make it part of the streaming manager's normal per-frame maintenance path.

### 2. Interior pocket finalization can erase door interaction layers

Severity: high. Likelihood: high.

Door interaction shapes start correctly as passive `Area3D` query objects on layer 3:

- `src/core/world/morrowind/morrowind_object_spawn_adapter.gd:369`
- `src/core/world/reference_instantiator.gd:2068`

But pocket finalization overwrites every `CollisionObject3D` with the slot physics mask in `src/core/world/interior_pocket_manager.gd:1062`. That includes `Area3D` interaction shapes under interior doors. The raycaster only checks layer 3 in `src/core/interaction/interaction_raycaster.gd:50`.

Result: once inside a pocket, exit doors and interior-to-interior doors can lose their prompt/activation target.

Production fix direction: query layers and physics collision layers must be separate policies. Interior finalization should preserve the interactable query bit on passive interaction areas, or identify them by group/script/name and avoid treating them as physical collision bodies.

### 3. Already-spawned doors can miss the activation handler in reordered startup

Severity: medium. Likelihood: medium.

`world_explorer._setup_pocket_manager()` registers doors from already-loaded cells before installing `cell_manager.set_door_activated_handler()`:

- register loaded cells: `src/tools/world_explorer.gd:4035`
- install handler: `src/tools/world_explorer.gd:4047`

The normal startup order probably avoids the bug because tracking starts after pocket manager setup. But the order is brittle. In hot reload, test scenes, or future initialization changes, a door can show a prompt and emit `door_activated` with no connected handler.

Production fix direction: install the activation handler before any cell can publish interactables, and make handler connection idempotent for existing `DoorInteractable` nodes.

### 4. Blocking sync fallback remains in the interior load path

Severity: medium. Likelihood: medium.

`InteriorPocketManager._load_pocket()` falls back to `_cell_manager.load_cell(cell_name)` when async capacity is unavailable in `src/core/world/interior_pocket_manager.gd:880`. The comment notes the old sync path can stall 35-250ms.

This is exactly the class of hitch the pocket system is supposed to avoid. A production transition should reserve capacity, cancel stale loads, prioritize the target, or wait under fade. It should not synchronously load an interior on the main thread during gameplay.

Production fix direction: remove sync fallback for runtime door travel. Keep sync load only for explicit tools/tests if needed.

### 5. Fade bridge can still spend 25ms/frame on publishing

Severity: medium. Likelihood: medium.

When tracking is frozen, `NativeStreamingManager` raises instantiation budget to 25ms in `src/core/world/native_streaming_manager.gd:1265`. This may be acceptable under full black, but it is not smooth-frame compliant and can affect fade frames or input feel.

Production fix direction: if using a black bridge, explicitly split "hidden blocking drain" and "visible fade" phases. Do not spend 25ms while the fade tween is visible unless the target UX is a loading screen, not a seamless fade.

### 6. Core architecture is not source-neutral yet

Severity: high. Likelihood: certain.

`InteriorPocketManager` lives in `src/core/world`, but it directly depends on Morrowind concepts:

- `CellRecord`, `CellReference`, `ESMManager`
- DODT/DNAM teleport semantics
- MW coordinate and yaw conversion
- Morrowind model-name building patterns
- destination checks through `ESMManager.get_cell()`

Examples:

- door registration: `src/core/world/interior_pocket_manager.gd:398`
- building pattern classification: `src/core/world/interior_pocket_manager.gd:506`

This violates the project rule that core world systems must be generic and game-specific logic belongs in adapter/provider layers.

Production fix direction: core should consume a source-neutral `TransitionDoorDescriptor` and `WorldSpaceDescriptor`. The Morrowind adapter should resolve DODT/DNAM, exterior vs interior destination rules, coordinate conversion, and building metadata.

### 7. Door identity is assigned in two places

Severity: medium. Likelihood: high.

Exterior spawned doors get a key from the spawn adapter in `src/core/world/morrowind/morrowind_object_spawn_adapter.gd:354`. Interior doors get patched later by `InteriorPocketManager._sync_door_interactable_instance_key()` via a recursive scene search in `src/core/world/interior_pocket_manager.gd:494`.

This is brittle because placed-door identity should come from the source record at spawn time. Tree search should be a diagnostic fallback, not the authority.

Production fix direction: make placed instance keys source-owned before spawn for both exterior and interior cells.

### 8. Dead and duplicate interaction paths remain

Severity: medium. Likelihood: high.

- `_update_door_prompt()` is a legacy proximity prompt path in `src/tools/world_explorer.gd:4093`, but the main prompt is raycast-driven through `_on_interact_prompt_changed()`.
- `door_in_range` signals are emitted by the pocket manager but not used by the main prompt path.
- The label named `DoorPrompt` now displays all prompts, not only doors.
- Visual transition tests call `enter_interior()` directly, so they bypass the actual E -> raycast -> DoorInteractable -> handler path.
- `docs/STATUS.md` and `docs/systems/interaction_system.md` contain stale statements about main-scene interaction wiring.

Production fix direction: delete or explicitly mark legacy proximity UI, rename generic prompt UI, and add regression coverage for the real input/raycast path.

### 9. Pocket "visual playable" is not the same as transition-ready

Severity: high. Likelihood: high.

`CellManager._is_request_visual_playable()` returns true once classification,
model loads, static preparation, and reference processing are done, but it does
not require `pending_instantiations <= 0` in `src/core/world/cell_manager.gd:1349`.
That is intentional for exterior cells because proximity-deferred interactives
can keep the full request incomplete for a long time.

However, `InteriorPocketManager._update_async_loads()` accepts
`is_async_visual_playable()` as enough to grab the in-progress cell node and
start finish-up in `src/core/world/interior_pocket_manager.gd:916`. Finish-up
then applies layers and registers interior doors from the cell record before all
queued Node3D tails are necessarily published. That can mark a pocket occupied
while the exit door `DoorInteractable`, floor collision, or other critical
transition affordances are not actually present yet.

Production fix direction: split readiness into at least `data_ready`,
`visual_ready`, and `interactive_ready` / `transition_ready`. Door travel should
commit only after the destination floor/collision, destination spawn clearance,
and required exit/interior door interactables are published. Noncritical clutter
can continue to stream in after reveal.

### 10. Exterior unfreeze can skip the required streaming refresh

Severity: high. Likelihood: medium-high.

`NativeStreamingManager.set_world_tracking_frozen(false)` rewrites
`_camera_position` and `_camera_cell` from the live camera in
`src/core/world/native_streaming_manager.gd:668`, but it does not call
`_update_loaded_cells()`. The normal `_process()` path triggers a cell refresh
only when `new_cell != _camera_cell` in
`src/core/world/native_streaming_manager.gd:1113`.

After an interior exit, the camera has teleported to the exterior destination
before unfreeze. Because unfreeze already updates `_camera_cell`, the next frame
can see no cell change and therefore skip the desired-cell reconciliation for
the new exterior anchor.

Production fix direction: treat exterior exit as an explicit streaming-origin
commit/teleport. After unfreezing, force the same desired-cell refresh and
post-teleport burst behavior used by other long-distance camera jumps.

### 11. Fade bridge is not stateful/idempotent

Severity: medium-high. Likelihood: medium.

When a target pocket is still loading, `_prepare_target_pocket_for_transition()`
fades to black in `src/core/world/interior_pocket_manager.gd:1204` and waits for
the load. The later `_do_transition()` path always starts by resetting the fade
from 0 to 1 in `src/core/world/interior_pocket_manager.gd:1350` and
`src/core/world/interior_pocket_manager.gd:1699`.

If the bridge is already black, resetting alpha to 0 before the second fade can
briefly reveal the old world during commit, depending on frame timing. Even when
not visible, the code is encoding transition phase in fade alpha side effects
instead of in an explicit state.

Production fix direction: make the transition state machine own fade state.
`black_bridge` should remain black through `committing` and only reveal in a
single `stabilizing -> complete` path.

## Most Likely Explanation For The Reported Bugs

The current bug report has four likely root causes:

1. Some exterior doors do not show prompts because the visible door is only a visual proxy; the real `DoorInteractable` was proximity-deferred and did not requeue as the player approached within the same loaded cell.
2. Pressing interaction after a pocket is loaded can fail for interior exit/interior-to-interior doors because pocket finalization overwrites layer-3 query areas with interior physics layers.
3. A pocket can become visual-ready before it is interaction-ready, so a rushed transition can reveal a destination before critical door/collision Node3Ds are published.
4. Exiting to exterior can update the streaming manager's cached camera cell during unfreeze without forcing the loaded-cell set to reconcile around the new anchor.

If "I cannot enter indoors" means exterior doors never activate at all, prioritize finding whether the exterior door Node3D was actually spawned and whether its `door_activated` signal is connected. If prompts appear but pressing E does nothing, inspect the placed `door_instance_key` and handler connection. If prompts do not appear, inspect proximity-deferred counts and layer-3 interaction shapes.

## Production Architecture Target

### Core

Core should own:

- `TransitionPortal`: generic interactable portal/door descriptor
- `WorldSpaceHandle`: exterior cell, interior pocket, dungeon, ship cabin, or future non-Morrowind space
- `TransitionStateMachine`: explicit states and failure handling
- `InteriorTransitionManager`: pocket lifecycle, readiness, fade, player move, environment handoff
- `StreamingCoordinator`: async requests, priorities, cancellation, publish budgets
- `InteractionPromptService`: one prompt owner fed by raycast/focus results

Core should not know:

- ESM record types
- DODT/DNAM
- Morrowind exterior grid conventions
- MW coordinate flips
- MW building model path patterns

### Morrowind adapter

The Morrowind adapter should own:

- parsing/reflection of DOOR refs into generic `TransitionDoorDescriptor`
- deciding whether a destination is interior or exterior
- translating DODT position/rotation into Godot transforms
- assigning stable placed-door keys
- optional building/entrance metadata for seamless mode
- display text such as "Travel to Seyda Neen, Census and Excise Office"

### Runtime behavior

1. Exterior streaming publishes door descriptors and visual proxies.
2. A throttled proximity pump ensures real interactables publish before interaction range.
3. Raycast focus shows prompt from `Interactable`.
4. Approaching a door preloads the target pocket.
5. Pressing E commits the transition through the state machine.
6. If target is transition-ready, fade/move/reveal is fast.
7. If target is not transition-ready, fade to black, boost target priority, drain async completion to interactive readiness, then move/reveal or fail cleanly.
8. On exit, commit the new exterior streaming origin, force a desired-cell refresh, restore environment/render/physics masks, and apply pocket eviction policy.

## Recommended Work Plan

### Immediate correctness fixes

1. Preserve layer-3 interaction areas during interior pocket finalization.
2. Run `tick_proximity_deferred()` from a throttled per-frame streaming maintenance path.
3. Install `door_activated_handler` before any door can spawn, and add an idempotent reconnect pass for existing doors.
4. Remove runtime sync `load_cell()` fallback from `_load_pocket()`.
5. Add transition-ready gating so visual-ready pockets cannot be committed before critical interactables/collision are published.
6. Force a streaming refresh when exterior tracking is unfrozen after an interior exit.
7. Make fade state explicit so the black bridge is not reset during commit.
8. Add diagnostics for visible door without prompt:
   - no `DoorInteractable` node
   - no layer-3 `InteractionArea`
   - key mismatch
   - signal not connected
   - raycast miss

### Architecture cleanup

1. Introduce source-neutral transition descriptors.
2. Move MW door extraction and destination resolution out of `InteriorPocketManager`.
3. Split `InteriorPocketManager` responsibilities: pocket lifecycle, transition state, portal/seamless rendering, lighting/environment setup.
4. Retire legacy proximity prompt UI or make it a debug-only overlay.
5. Update stale docs after code fixes land.

### Tests and verification

Add narrow tests before broad scene launches:

- unit: pocket finalization preserves query-only layer-3 interaction areas
- unit: placed door keys are correct for exterior and interior doors
- unit: proximity-deferred door requeues when camera approaches without a cell change
- unit/integration: visual-ready pocket does not commit until required exit door and collision are transition-ready
- integration: exterior exit forces loaded-cell reconciliation around the exit destination
- unit/integration: black bridge remains black through commit and reveals only once
- integration/visual: E on exterior raycast door enters an interior
- integration/visual: E on interior exit raycast door returns to exterior
- integration/visual: E on interior-to-interior raycast door transitions correctly

For gameplay verification after fixes:

```powershell
dotnet build Godotwind.sln
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn
```

Then interactively verify a real exterior door, a rushed approach before preload finishes, an interior exit door, and repeated enter/exit cycles. The existing `--interior-door-smoke` and `--interior-door-smoke-rush` commands are useful crash/regression smokes, but they should not replace an interactive pilot pass for final gameplay acceptance.

Shader cache clearing was not relevant to this audit because no `.glsl`, `.gdshader`, or `.gdshaderinc` files were changed.

## Audit Inputs

This audit combined:

- local code inspection
- an independent code-veracity subagent audit
- an independent open-world streaming/architecture subagent audit
- direct checks against official OpenMW, Unreal, Unity, and Godot documentation

A separate Godot-specific subagent was started during the follow-up review but
did not complete before synthesis; its partial work was not used as evidence.

No visual launch was run because this pass only added a documentation audit and did not claim a gameplay, streaming, rendering, or performance fix complete.
