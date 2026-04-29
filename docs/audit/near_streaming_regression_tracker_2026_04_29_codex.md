# NEAR Streaming Regression Tracker - 2026-04-29 Codex

Purpose: hand off the exact state after an unsuccessful stabilization attempt.
Do not treat the latest work as proven stable. Manual visual traversal still
crashes and moving around has bad FPS.

## Goal

Stabilize Godotwind NEAR streaming during normal player/camera movement across
exterior cells.

The intended end state is:

- no movement/unload crash while crossing cells
- no unsafe world-scoped `MultiMesh.set_buffer()` upload during unload churn
- per-cell static collision publishes only during quiet periods and under budget
- player-local interactives stay prioritized near the camera
- boot/loading readiness does not timeout incorrectly
- transition spikes from instantiate, unload, static cull, and collision publish
  are reduced enough for visual play

## Files Touched In This Attempt

- `src/core/world/prototype_batch.gd`
- `src/core/world/prototype_registry.gd`
- `src/core/world/static_object_renderer.gd`
- `src/core/world/native_streaming_manager.gd`
- `src/core/world/cell_manager.gd`
- `src/core/world/streaming_config.gd`
- `src/tools/streaming_stress_runner.gd`
- `src/tools/auto_bench_runner.gd`

Working tree remains dirty in those files.

## Important Flags

Keep these disabled unless explicitly re-auditing their crash classes:

- `STATIC_CULL_NATIVE_ENABLED = false`
- `STATIC_PREPARE_CREATE_BATCHES = false`
- `DEBUG_DISABLE_PHASE_F_PREREG = true`

Additional late-session change:

- `PHASE_A_OFFTHREAD_INSTANTIATE = false`

That last change was an emergency rollback attempt after visual traversal
crashed near the child attach lane. It did not fix the visual crash.

## What Was Changed

### Static MultiMesh Upload Deferral

In `prototype_batch.gd`:

- Added upload deferral after slot release.
- Added `_upload_defer_ticks`, `_upload_deferred_last_tick`, and
  `_last_visible_count`.
- `cull_and_upload()` now skips upload while the defer counter is active and
  keeps the last visible count.
- Zero-live batches clear visibility and reset upload deferral state.

In `prototype_registry.gd`:

- Added `defer_uploads(frames)`.
- Added registry-level upload barrier state.
- Dirty bookkeeping now stays dirty when a batch skipped upload due to deferral.

In `static_object_renderer.gd`:

- Added `defer_prototype_uploads(frames)`.

In `native_streaming_manager.gd`:

- Called static renderer upload deferral during unload/hide/cleanup paths.

Config:

- Added `STATIC_CULL_UPLOAD_DEFER_FRAMES_AFTER_UNLOAD = 4`.

Intent: keep `MultiMesh.set_buffer()` away from unload-driven slot release/free
churn.

### Collision Quiet-Period Gating

In `cell_manager.gd`:

- Extended `process_async_instantiation(..., allow_collision_finalize := true)`.
- Added quiet-period checks so collision dispatch/finalize waits until visual
  work is idle.
- Added `_has_collision_blocking_visual_work()`.
- Fixed a bug where collision finalize could still run after the queue drained
  inside a call where `allow_collision_finalize=false`.
- Changed `_tick_static_collision_build()` and
  `_maybe_finalize_static_collision_when_idle()` to return finalize time so
  logging can attribute cost.
- Added `dispatch=` and `cfin=` fields to `[inst-spike]`.
- Added visible-cell guard before collision finalize if `winner.cell_node.visible`
  is false.

In `native_streaming_manager.gd`:

- Collision finalize is blocked while unload queues are active and for
  `CELL_STATIC_COLLISION_FINALIZE_DEFER_FRAMES_AFTER_UNLOAD` frames after unload.

Config:

- Added `CELL_STATIC_COLLISION_FINALIZE_DEFER_FRAMES_AFTER_UNLOAD = 30`.
- Reduced `CELL_STATIC_COLLISION_FINALIZE_MAX_TRIS_PER_FRAME` from `8000` to
  `1000` by the end of the session.

Intent: avoid collision publish during unload/visual churn and reduce per-frame
collision cost.

### Benchmark Quit Changes

In `streaming_stress_runner.gd` and `auto_bench_runner.gd`:

- Added benchmark quit sentinels.
- Tried routing benchmark exit through fast cleanup.
- Then changed benchmark exit to set `_quitting`, stop streaming processing,
  and skip manual RS teardown.

Result: did not fix shutdown crash. Even a short no-collision stress smoke still
crashed after summary flush and `BENCH_QUIT`.

## Validation That Passed

Both cheap checks passed after the latest edits:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --headless --path . --quit
dotnet build Godotwind.sln --configfile NuGet.Config
```

These checks only prove parsing/build, not runtime stability.

## Stress Results - Useful But Misleading

The stress harness completed runs and wrote summaries, but manual visual testing
still crashed. Do not over-weight stress completion.

Collision enabled:

- `stress_summary_collision_quiet_all_lane_slice1000_dense_loop_2026_04_29_codex.json`
- 75s dense loop
- 62 transitions
- max frame `28.327ms`
- `0` frames over `33.33ms`
- max inst `16.794ms`
- max static cull `3.217ms`
- crashed after summary flush during quit

No-collision ablation:

- `stress_summary_no_collision_quiet_all_lane_slice1000_dense_loop_2026_04_29_codex.json`
- 75s dense loop
- avg `197.1 FPS`
- max frame `26.276ms`
- `13` frames over `16.67ms`
- `0` frames over `33.33ms`
- max inst `10.597ms`
- also crashed after summary flush during quit

Short no-collision quit smoke:

- `stress_summary_quit_smoke_no_manual_rs_teardown_2026_04_29_codex.json`
- summary wrote successfully
- still crashed after `BENCH_QUIT - ... skipping manual RS teardown`

## Manual Visual Failures

### Visual Crash 1 - Before Disabling Phase A

User moved into another cell in a normal, no-benchmark launch.

Crash signals:

- crash breadcrumb:
  - `cm::attach_done :: attached=0 pending=0`
- crash report:
  - camera cell `(-1, -8)`
  - queue `12 pending`
- log showed huge attach lane spikes:
  - `[inst-spike 912.4ms] ... addc=911.4 ...`
  - `[inst-spike 660.3ms] ... addc=659.5 ...`

Interpretation at the time:

- The crash was not collision finalize.
- The crash was not only benchmark teardown.
- It looked tied to child attach / detached Node3D publish.

Action taken:

- Set `PHASE_A_OFFTHREAD_INSTANTIATE = false`.

### Visual Crash 2 - After Disabling Phase A

User tested again and reported it was still broken, with bad FPS while moving.

Latest captured crash report:

- generated `2026-04-29T12:57:11`
- session duration `94.9s`
- camera position `(754.3, 41.9, 822.8)`
- camera cell `(6, -8)`
- queue `111 pending`
- NEAR cells `4`
- MID `702`
- last operations were repeated cell unloads

Latest crash breadcrumb:

```text
[100373] cm::attach_done :: attached=0 pending=0
```

Latest Godot/GDScript backtrace at crash:

```text
Terrain3D NOTIFICATION_CRASH
GDScript backtrace:
  _evict_if_over_budget (res://src/core/world/model_loader.gd:337)
  _drain_pending_instantiate_queue (res://src/core/world/model_loader.gd:780)
  process_async_loads (res://src/core/world/model_loader.gd:605)
  process_async_disk_loads (res://src/core/world/cell_manager.gd:1915)
  process_async_instantiation (res://src/core/world/cell_manager.gd:2059)
  _process (res://src/core/world/native_streaming_manager.gd:897)
```

Late movement logs also showed bad FPS / heavy instantiate:

- `[inst-breakdown 5s] container(n=392 tot=1510.7ms avg=3853us)`
- door/light/activator Node3D path had large model-load costs
- repeated `[inst-spike]` around 16-21ms with `node=.../1`, `ml=...`
- queue remained high (`~111-130`) during traversal

Interpretation:

- Disabling Phase A did not solve visual crash.
- Crash moved/manifested in `ModelLoader` eviction while draining async loads.
- Current runtime is not stable and not performant during manual movement.
- The model cache eviction / async load drain path should be considered a prime
  suspect, especially under high queue pressure and rapid cell traversal.

## Known Bad Conclusions To Avoid

Avoid saying "movement/unload is stable" based only on dense-loop stress summary.
That was wrong.

Avoid treating the crash as teardown-only. There is a teardown crash, but there
is also a manual visual movement crash.

Avoid assuming collision is the only culprit. No-collision stress looked much
better, but manual visual crash after disabling Phase A landed in `model_loader`
eviction / async load draining.

Avoid assuming `PHASE_A_OFFTHREAD_INSTANTIATE=false` is a real fix. It was a
triage rollback and did not fix the user-visible problem.

## Likely Next Investigation Targets

1. `model_loader.gd` eviction / pending instantiate drain
   - Latest visual crash backtrace points here.
   - Look at `_evict_if_over_budget`, `_drain_pending_instantiate_queue`,
     resource lifetimes, and whether evicted scenes/resources are still
     referenced by payloads, static prepare, or queued entries.

2. Child attach lane / breadcrumbs
   - Breadcrumb remains `cm::attach_done`.
   - Earlier visual crash had enormous `addc` spikes.
   - Determine whether breadcrumb is stale/noisy or whether attach drain still
     participates in the crash.

3. Interactive Node3D model-load pressure
   - After Phase A was disabled, logs show containers/doors/lights dominate
     per-type instantiate time.
   - Queue grew past 100 while moving.
   - Consider stricter proximity gating, lower disk drain budgets, or avoiding
     cache eviction while queued refs still depend on resources.

4. Static prepare spike
   - Boot visual run showed:
     - `[static-prepare-spike 626.9ms] state=303.7 batch=323.1/1 type=ex_ship_plank.nif`
   - Earlier runs showed similar `ex_ship_plank.nif`/ship plank batch reserve
     spikes.
   - This is a severe boot/runtime hitch independent of the crash.

5. Benchmark teardown crash
   - Still exists, but do not prioritize over visual movement crash.
   - It occurs after summaries flush and after `BENCH_QUIT`.

## Suggested Next Session Prompt

```text
Continue NEAR streaming stabilization in Godotwind.

Read:
- docs/audit/near_streaming_regression_tracker_2026_04_29_codex.md
- docs/audit/near_streaming_clean_slate_handoff_2026_04_27.md

Do not trust prior claims that movement/unload is stable. Manual visual
traversal still crashes and FPS tanks while moving.

Current dirty files include:
- src/core/world/prototype_batch.gd
- src/core/world/prototype_registry.gd
- src/core/world/static_object_renderer.gd
- src/core/world/native_streaming_manager.gd
- src/core/world/cell_manager.gd
- src/core/world/streaming_config.gd
- src/tools/streaming_stress_runner.gd
- src/tools/auto_bench_runner.gd

Important current flags:
- STATIC_CULL_NATIVE_ENABLED = false
- STATIC_PREPARE_CREATE_BATCHES = false
- DEBUG_DISABLE_PHASE_F_PREREG = true
- PHASE_A_OFFTHREAD_INSTANTIATE = false (triage rollback; did not fix crash)

Latest visual crash after disabling Phase A:
- crash report generated 2026-04-29T12:57:11
- camera cell (6, -8)
- queue 111 pending
- repeated unload operations before crash
- breadcrumb: cm::attach_done :: attached=0 pending=0
- GDScript backtrace:
  _evict_if_over_budget (model_loader.gd:337)
  _drain_pending_instantiate_queue (model_loader.gd:780)
  process_async_loads (model_loader.gd:605)
  process_async_disk_loads (cell_manager.gd:1915)
  process_async_instantiation (cell_manager.gd:2059)
  native_streaming_manager._process (native_streaming_manager.gd:897)

Priority:
1. Investigate model_loader eviction/pending instantiate drain crash under
   movement, not benchmark teardown.
2. Determine whether resource eviction is racing queued refs/payload-pinned
   PackedScenes/static prepare.
3. Reproduce with normal visual launch or a harness that matches manual camera
   movement better than the dense-loop stress runner.
4. Fix bad movement FPS from interactive Node3D model-load pressure and queue
   buildup.
5. Only then revisit benchmark teardown crash and static collision tuning.

Validation rule:
Parser/build passing and stress summary flush are not enough. User must be able
to move visually across cells without crash and without severe FPS collapse.
```

