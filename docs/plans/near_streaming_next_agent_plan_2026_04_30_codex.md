# NEAR Streaming Next Agent Plan

Date: 2026-04-30  
Author: Codex  
Starting commit: `e8338e3` (`Stabilize streamed resource ownership`)  
Branch: `perf/distant-rendering-2026-04-17`

## Starting State

P0.2 is checkpointed. The `ModelLoader._evict_if_over_budget ->
_model_cache.erase` crash class was addressed by moving streamed resource
lifetime to `StreamedResourceHandle` ownership. Cache eviction is active again.
The visible `scenes/Godotwind.tscn` manual traversal gate passed and the user
quit cleanly.

Do not reopen P0.2 unless the user-visible traversal regresses. Hidden automated
ready-quit probes can still hit a native signal 11 during finalization, but that
did not reproduce in the visible manual quit path.

## Read First

Read these in order before editing code:

1. `docs/STATUS.md`
   - Ground truth for current project state.
   - Confirms NEAR stabilization is still the priority and distant rendering is
     parked.
2. `docs/plans/near_streaming_p0_fix_tracker_2026_04_29_codex.md`
   - Incident tracker, P0.1/P0.2 results, verification evidence, and pending
     P0.3/P0.4 work.
3. `docs/reference/how to streaming.md`
   - Architecture guide for fast Godot 4.6 streaming.
   - Separates official Godot-doc-backed rules from inferred industry patterns.
4. `src/core/streaming/streamed_resource_handle.gd`
   - The new P0.2 ownership primitive.
5. `src/core/world/model_loader.gd`
   - Cache, async load, eviction, and handle lookup.
6. `src/core/world/cell_payload.gd`
   - Current per-cell ownership state and the natural home for P0.3.
7. `src/core/world/cell_manager.gd`
   - Current global queue driver. This is where most P0.3 simplification will
     happen.

## Priority Order

### Priority 1: Preserve The Stable Baseline

Before any rewrite, run a quick normal launch or short smoke to make sure the
checkout still starts. If a user can manually launch and fly, prefer that over a
hidden harness. Do not start distant rendering, HLOD, impostor, or feature work
until P0.3 is either completed or explicitly deferred by the user.

### Priority 2: Start P0.3 Per-Payload Publish Scheduling

Goal: make `CellPayload` own its own publish lifecycle instead of scattering one
cell's state across global queues in `CellManager`.

Target shape:

```text
NativeStreamingManager
  rotates active payloads and gives each a frame budget

CellPayload
  owns model request state, static prepare state, child attach state,
  collision publish state, completion, cancellation, and unload cleanup

CellManager
  becomes a coordinator and compatibility layer, not the owner of every queue
```

Start small. Do not big-bang rewrite the entire streaming manager. Pick one
queue lane and move it behind a payload-owned method while preserving behavior.
The safest first candidate is usually static prepare/publish because it already
uses payload resource handles and has clear per-cell ownership.

### Priority 3: Keep Resource Lifetime Explicit

Every path that touches a server RID must keep a strong `Resource` reference.
Use `StreamedResourceHandle` or an already-owned strong `Mesh`/`Material`
reference. Do not restore cache-key pin walking as the main lifetime model.

For each moved queue lane, answer:

- Which payload owns this work?
- Which handle/resource keeps the RID alive?
- What happens if the cell unloads before the work publishes?
- Where is the WorkerThreadPool task waited on?
- What does cancellation mean if Godot cannot cancel the task?

### Priority 4: Verification Gates

For every non-trivial P0.3 slice:

1. Run `git diff --check`.
2. If C# changed, run `dotnet build Godotwind.sln`.
3. Run a short Godot smoke that exercises the changed path.
4. Launch `scenes/Godotwind.tscn` visibly for manual traversal before claiming a
   gameplay/streaming/rendering change done.

Useful commands:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn
```

Short smoke, not a final gate:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --bench-stress=<stamp> --stress-duration=20 --stress-route=east --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision
```

## Do Not Do

- Do not resume distant rendering before P0.3 is checkpointed or explicitly
  deferred.
- Do not re-disable `ModelLoader` eviction as a final fix.
- Do not add defer-frame constants or timer delays to solve ownership bugs.
- Do not add broad shutdown instrumentation back into manager `_exit_tree`
  methods unless the user asks to investigate shutdown specifically.
- Do not treat `dense-loop` as broad traversal coverage. It is only a local
  churn probe.
- Do not use automated screenshots as visual verification.

## Expected First Slice

Recommended first P0.3 slice:

1. Map the current `CellManager` queues and ownership fields:
   - `_static_prepare_queue`
   - `_instantiation_queue`
   - `_pending_child_attaches`
   - collision publish/finalize queues
   - preload/pending async request handoff
2. Pick one lane, preferably static prepare.
3. Add a small payload-owned state/method such as
   `payload.publish_static_step(cell_manager, budget_usec)`.
4. Keep `CellManager` as the caller for now.
5. Verify equivalent behavior with a short smoke and then visible manual
   traversal.

Success for the first slice is not "all queues gone." Success is one lane moved
so a future agent can repeat the pattern without guessing ownership.

