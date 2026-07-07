# Interior / Exterior Transition Production Refactor Plan - 2026-05-30

## Purpose

This plan turns the findings in
`docs/audit/interior_exterior_transition_audit_2026_05_30.md` into a production
architecture for travel doors, interior pockets, and future non-Morrowind world
transitions.

The target is not a patch that makes one door work. The target is a stable
transition system that treats interiors as explicit world topology, keeps core
framework code source-neutral, and separates preload, readiness, commit, and
reveal the way production open-world engines do.

## Canonical Pattern

The architecture follows the standard pattern used by mature open-world and
scene-streaming systems:

- Author or derive explicit portal topology. A portal has a source space, target
  space, target transform, prompt data, and required activation affordances.
- Start loading before the player reaches the door.
- Keep loading and publishing asynchronous/budgeted.
- Gate player commit on transition readiness, not merely visual readiness.
- Hide unavoidable blocking work behind an explicitly owned black/loading phase,
  not during visible fade frames.
- Commit a streaming origin after teleporting so world streaming reconciles
  around the new player anchor immediately.

External baseline checked during planning:

- OpenMW treats teleport doors as placed door data with destination cell,
  destination position, and facing.
- Unreal level streaming volumes are sized so content is loaded before the
  player reaches the door, and door state can gate streaming.
- Unity Addressables scene loading separates async load from activation.
- Godot 4.6 allows threaded resource loading and detached data preparation, but
  active scene-tree mutation, node publication, signal connection, and layer
  finalization belong on the main thread.

References:

- OpenMW doors and teleports:
  https://openmw.readthedocs.io/en/latest/reference/modding/doors-and-teleports.html
- Unreal level streaming volumes:
  https://dev.epicgames.com/documentation/en-us/unreal-engine/level-streaming-volumes-reference-in-unreal-engine
- Unity Addressables scene loading:
  https://docs.unity.cn/Packages/com.unity.addressables@1.21/manual/LoadingScenes.html
- Godot 4.6 threaded loading:
  https://docs.godotengine.org/en/4.6/classes/class_resourceloader.html
- Godot 4.6 thread-safe APIs:
  https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html
- Godot 4.6 ray casting:
  https://docs.godotengine.org/en/4.6/tutorials/physics/ray-casting.html
- Godot 4.6 input actions:
  https://docs.godotengine.org/en/4.6/tutorials/inputs/inputevent.html

## Non-Negotiable Invariants

1. Core transition code must not know about ESM records, DODT/DNAM, Morrowind
   coordinate flips, Morrowind interior/exterior classification, or building
   model path patterns.
2. Interaction query layers are not physics collision policy. Raycast-only
   `Area3D` affordances stay on layer 3 with mask 0 unless the interaction
   system itself changes.
3. `visual_ready` is not `transition_ready`. A destination can be visually
   playable while critical floor, collision, exit doors, or query targets are not
   published yet.
4. Runtime door travel must not fall back to synchronous `load_cell()`.
5. Transition fade/black-screen state is owned by the transition state machine,
   not inferred from `ColorRect.color.a`.
6. Exterior exit is a teleport/origin commit. It must force streaming
   reconciliation around the new exterior position.
7. Tests and visual scenes must exercise the real input path:
   `InputMap -> raycast -> DoorInteractable -> handler -> transition`.

## Target Architecture

### Core Contracts

Add source-neutral descriptors under `src/core/world/transition/` or equivalent:

- `WorldSpaceHandle`
  - Identifies a streamed world space without source-specific fields.
  - Examples: exterior tile, interior pocket, dungeon room, ship cabin.
- `TransitionPortalDescriptor`
  - Stable placed-portal key.
  - Source space handle.
  - Target space handle.
  - Prompt/display data.
  - Source-space transform and activation range.
  - Target transform/facing.
  - Preload policy.
  - Required transition affordances.
- `TransitionDestinationDescriptor`
  - Load request data for the target space.
  - Target player/camera transform.
  - Environment/render/physics handoff policy.
- `TransitionAffordanceRequirement`
  - Critical conditions required before commit/reveal.
  - Examples: spawn collision/floor ready, exit portal query target ready,
    activation handler connected, camera cull mask prepared.
- `TransitionReadiness`
  - `data_ready`
  - `visual_ready`
  - `interactive_ready`
  - `transition_ready`
  - `complete`

### Morrowind Adapter

Move Morrowind-specific work into an adapter/provider, likely under
`src/core/world/morrowind/`:

- Extract teleport door references into generic `TransitionPortalDescriptor`s.
- Resolve DODT/DNAM into source-neutral target handles and transforms.
- Decide interior vs exterior destinations.
- Convert MW coordinates and yaw into Godot transforms.
- Assign stable placed-door keys before spawn for both exterior and interior
  doors.
- Own building/seamless metadata such as model path pattern matching.
- Provide Morrowind prompt text such as `Travel to <cell>`.

Core should consume the descriptors and never walk `CellRecord.references` to
discover transition topology.

### Runtime Services

Split current `InteriorPocketManager` responsibilities into smaller owners:

- `TransitionPortalRegistry`
  - Stores descriptors by placed key.
  - Receives descriptors from the active source adapter.
  - Supports idempotent connect/reconnect for already-published interactables.
- `TransitionStateMachine`
  - Owns `idle`, `candidate`, `prefetching`, `ready`, `committing`,
    `stabilizing`, `complete`, and `failed`.
  - Owns fade/loading overlay state.
  - Owns timeout, rollback, double-activation rejection, and diagnostic state.
- `PocketLifecycleManager`
  - Owns pocket slots, load tokens, pinned target loads, eviction, and cleanup.
  - Exposes readiness separately from full async request completion.
- `TransitionStreamingCoordinator`
  - Requests target preloads.
  - Raises/lower priorities.
  - Cancels or demotes stale prefetches.
  - Commits exterior streaming origins after teleport.
- `InteractionPromptService`
  - Keeps prompt display generic and raycast-driven.
  - Retires or marks proximity prompt paths as debug-only.

This can be implemented incrementally, but the ownership boundaries should be
named before broad rewrites begin.

## Phase 0 - Ratchet Tests And Diagnostics

Before moving architecture, add small tests/diagnostics that define the new
invariants.

Work:

- Add diagnostics that explain why a destination is not transition-ready:
  missing collision/floor, missing required portal, missing layer-3 query target,
  missing activation handler, pending critical publish, async failure, timeout.
- Add a readiness enum/value object distinct from `is_async_visual_playable()`.
- Add debug counters for portal prefetch kicked, ready, activated, cancelled,
  evicted, and failed.
- Update or add tests that prove `visual_ready != transition_ready`.

Acceptance:

- A rushed transition cannot commit from `visual_ready` alone.
- Logs say what blocked transition readiness.
- Existing visual tests are marked as direct-manager tests if they bypass
  input/raycast, so they are not mistaken for gameplay coverage.

## Phase 1 - Immediate Correctness Gates

These fixes make the current path safe enough to refactor without chasing
phantom bugs.

Work:

1. Preserve raycast interaction affordances during pocket finalization.
   - `InteractionArea` should remain layer 3, mask 0, `monitoring = false`.
   - Physical bodies receive pocket physics masks.
   - Add a helper/policy instead of another broad recursive layer rewrite.
2. Move proximity-deferred requeue into normal streaming maintenance.
   - It stays owned by the streaming manager/cell manager, not UI code.
   - It remains throttled and should become cursor/budget based if deferred
     counts can become large.
3. Install door activation handler before door registration/spawn and add an
   idempotent reconnect pass for existing `DoorInteractable` nodes.
4. Remove runtime sync `load_cell()` fallback from door travel.
   - If async capacity is full, reserve capacity, cancel/demote stale prefetch,
     boost target priority, or wait/fail under state-machine control.
5. Make fade state explicit and idempotent.
   - If the bridge is already black, commit stays black.
   - Reveal happens once, from `stabilizing` to `complete`.
6. Add an explicit exterior streaming origin commit API.
   - Unfreeze tracking.
   - Set the new anchor.
   - Force desired-cell reconciliation.
   - Arm the same post-teleport burst behavior used for long-distance camera
     jumps.

Acceptance:

- Visible exterior proxy doors become promptable after approach without requiring
  a cell boundary crossing.
- Interior exit and interior-to-interior doors keep layer-3 raycast targets.
- Door activation always reaches the installed handler after setup or reconnect.
- No runtime door path calls sync `load_cell()`.
- Exterior exit refreshes loaded cells around the new destination immediately.
- The old world never flashes between black bridge and commit.

## Phase 2 - Source-Neutral Transition Descriptors

This is the framework boundary fix.

Work:

- Add descriptor classes/resources for portals, spaces, destinations, and
  readiness requirements.
- Add a Morrowind transition provider that emits descriptors from DOOR refs.
- Route exterior door registration through the provider, not direct ESM reads in
  core.
- Route interior door registration through the same provider.
- Teach spawn code to receive/apply the placed portal key before a
  `DoorInteractable` is published.
- Keep `DoorUtils.find_by_ref_id()` as a diagnostic fallback only.

Acceptance:

- `InteriorPocketManager` or its replacement no longer calls `ESMManager` or
  iterates parser-shaped `CellRecord.references` for transition topology.
- MW DODT/DNAM, coordinate conversion, and building model heuristics live in the
  Morrowind adapter.
- Core transition code can be explained without mentioning Morrowind.
- Existing Morrowind doors still activate by the same placed-door keys.

## Phase 3 - Transition State Machine

Replace `_is_transitioning`, implicit fade alpha, and scattered activation guards
with a single transition owner.

States:

- `idle`
- `candidate`
- `prefetching`
- `ready`
- `committing`
- `stabilizing`
- `complete`
- `failed`

Responsibilities:

- Own fade/loading overlay and active tween cancellation.
- Own target load pinning and priority.
- Own exterior tracking freeze/unfreeze and origin commit.
- Own player/camera teleport.
- Own environment, cull mask, and physics policy handoff.
- Own timeouts and rollback.
- Emit structured state changes for tests and logs.

Acceptance:

- Double activation while committing is rejected by state, not by scattered
  boolean checks.
- Failed preload returns to the previous space with tracking and fade restored.
- The black bridge cannot be reset by a later `_do_transition()` call.
- State transitions are testable without launching the full main scene.

## Phase 4 - Portal Prefetch Policy

Door preloading should be a streaming policy, not a side effect of closest-door
UI tracking.

Work:

- Treat portal destinations as streaming requests with priority, cancellation,
  and telemetry.
- Replace the hard 10m-only preload radius with a speed-aware policy:
  `radius = max(base_radius, player_speed * target_ready_budget_s + margin)`.
- Use 25m as the conservative default for walking/sprinting/fly-camera approach,
  then tune from benchmark data.
- In dense towns, consider top 2-3 candidate portals by distance/frustum, but
  allow only one active publish target per frame and keep resident slots bounded.
- Pin the portal selected by activation so incidental slot eviction cannot cancel
  the committed target.

Acceptance:

- Rapidly passing many doors does not wedge both slots in stale loading states.
- Activated destination loads cannot be evicted/cancelled by ordinary proximity
  churn.
- Prefetch stats show kicked, ready, activated, cancelled, and evicted counts.
- Door readiness is stable under fly-camera rush tests.

## Phase 5 - Publish Budgets And Readiness Lanes

Split destination preparation into lanes instead of treating a cell request as
one blob.

Lanes:

- Data/model warm: worker/threaded loading and source parsing.
- Visual publish: main-thread render/node publication.
- Critical interactive publish: floor/collision, spawn clearance, required
  portal/interactable query targets.
- Noncritical tail: clutter, lights, or optional objects that can continue after
  reveal.

Budget policy:

- Visible fade frames should spend no more than roughly 2ms on transition
  publishing.
- Fully black hidden drain may temporarily spend more, but should be explicitly
  logged as hidden loading work. Target 8-12ms before considering 25ms.
- A 25ms drain is a loading-screen frame, not a seamless fade frame.

Acceptance:

- `transition_ready` requires zero pending critical affordances, not zero total
  pending instantiations.
- Noncritical tails may continue after reveal without breaking prompts,
  collision, or exit doors.
- Benchmarks distinguish visible fade budget from opaque drain budget.
- No visible fade frame is allowed to hide a 25ms publish spike.

## Phase 6 - Pocket Lifecycle And Eviction Ownership

Pocket slots need explicit lifecycle and owner tokens so cancellation/eviction
cannot race transition commit.

Lifecycle:

- `empty`
- `prefetching`
- `data_ready`
- `publishing`
- `transition_ready`
- `active`
- `inactive_grace`
- `evicting`
- `evicted`
- `failed`

Cleanup order:

1. Stop discovery/iteration.
2. Stop drawing.
3. Free server RIDs while resources are still pinned.
4. Queue-free nodes.
5. Drop handles/cache pins.
6. Erase bookkeeping.

Acceptance:

- Active or committing pockets are not evictable.
- Cancelled prefetches drain/await their owned worker tasks.
- Resource/RID ownership is explicit.
- Repeated enter/exit cycles do not leak pocket nodes, RIDs, or async requests.

## Phase 7 - Interaction And Prompt Cleanup

The gameplay path is raycast-driven. The plan should delete or quarantine the
old proximity-prompt model.

Work:

- Rename generic prompt UI away from `DoorPrompt`.
- Remove `_update_door_prompt()` from runtime flow or mark it debug-only.
- Keep `door_in_range` only if a debug overlay or prefetch telemetry uses it.
- Ensure visual tests and main-scene smokes use InputMap actions, not raw
  keycode polling.
- Keep `InteractionRaycaster` generic; it should not learn door semantics.

Acceptance:

- There is one production prompt owner.
- Prompt text comes from the focused `Interactable`.
- Door transition tests cover the real `interact` action path.
- No new test scene hardcodes raw `KEY_*` input loops.

## Phase 8 - Documentation And Status Ratchet

Docs must move with the architecture so future agents do not preserve stale
assumptions.

Work:

- Update `docs/STATUS.md` after each accepted phase.
- Update `docs/systems/interior_transitions.md` to describe descriptors,
  readiness, state machine, and verification.
- Update `docs/systems/interaction_system.md` to remove stale layer-OR/raw-key
  references.
- Archive or mark superseded sections about the old proximity prompt and direct
  manager visual tests.
- Add a short audit closeout once the refactor lands.

Acceptance:

- Status docs no longer claim fully working behavior for paths that still rely on
  direct-manager tests.
- Source-neutral boundaries are documented in the system doc.
- Verification instructions name both automated smokes and the required
  interactive visual pass.

## Verification Matrix

Automated tests/smokes:

- Unit: pocket finalization preserves passive layer-3 `InteractionArea`s.
- Unit: physical collision layer policy does not touch query affordance layers.
- Unit: exterior and interior placed portal keys are descriptor-owned before
  spawn.
- Unit/integration: `visual_ready` does not imply `transition_ready`.
- Integration: rushed activation waits for critical affordances.
- Integration: exterior exit forces streaming-origin refresh.
- Integration: fade bridge remains black through commit and reveals once.
- Integration: activated target pocket cannot be evicted by nearby door churn.
- Main-scene smoke: `--interior-door-smoke`.
- Main-scene smoke: `--interior-door-smoke-rush`.

Interactive verification after gameplay/streaming changes:

```powershell
dotnet build Godotwind.sln
<godot-executable> --path <project-path> scenes/Godotwind.tscn
```

Manual route:

1. Enter a real exterior door through the raycast prompt.
2. Rush a door before preload finishes and verify the black bridge waits cleanly.
3. Use an interior exit door and verify exterior streaming refreshes at the exit
   destination.
4. Use an interior-to-interior door.
5. Repeat enter/exit cycles and watch for missing prompts, missing collision,
   fade flashes, stale exterior anchors, and frame spikes.

Shader cache/import clearing is not relevant unless the implementation changes
`.glsl`, `.gdshader`, or `.gdshaderinc` files.

## First Implementation Slice

The first code slice should be deliberately small and correctness-heavy:

1. Add layer policy helper/tests so interaction query areas survive pocket
   finalization.
2. Add per-frame/budgeted proximity-deferred maintenance.
3. Install/reconnect door activation handlers idempotently.
4. Add `transition_ready` diagnostics without changing broad architecture yet.
5. Add exterior streaming-origin commit API and use it on interior exit.
6. Remove runtime sync fallback from door travel or gate it behind explicit
   tool/test-only code.

Only after this slice is verified should the descriptor/provider extraction
begin. That keeps the refactor from moving broken behavior into prettier boxes.
