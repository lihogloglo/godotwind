# NEAR Streaming P0 Fix Tracker

Date: 2026-04-29  
Owner: Codex  
Branch: `perf/distant-rendering-2026-04-17`  
Related handoff: `docs/reference/how to streaming.md`

## Goal

Recover a stable NEAR streaming baseline before any distant rendering, HLOD,
impostor, or new gameplay feature work continues.

The immediate user-visible failure is movement/streaming instability, not a
confirmed startup crash. A bounded normal launch probe on 2026-04-30 kept
`scenes/Godotwind.tscn` running for 45 seconds before Codex killed only the
probe process. The latest reproducible streaming crash captured before the
diagnostic eviction bridge was:

```text
_evict_if_over_budget (res://src/core/world/model_loader.gd:437)
_try_drain_requested_eviction (res://src/core/world/model_loader.gd:405)
process_async_loads (res://src/core/world/model_loader.gd:729)
process_async_disk_loads (res://src/core/world/cell_manager.gd:1966)
process_async_instantiation (res://src/core/world/cell_manager.gd:2154)
_process (res://src/core/world/native_streaming_manager.gd:903)
```

At that crash site, `model_loader.gd:437` is `_model_cache.erase(key)`.

## Current Hypothesis

`_model_cache.erase(key)` is a diagnostic symptom, not necessarily the semantic
bug. The official Godot 4.6 server docs require strong `Resource` references to
be held outside server RIDs. Erasing the last strong `PackedScene` reference can
free inner resources while live scene/server consumers still depend on them.

The current cache-key pin API is the wrong granularity. The long-term fix is a
ref-counted streamed resource handle owned by payloads/consumers, not a cache
dictionary that tries to infer liveness by walking queues.

## P0 Rules

- No distant rendering work until this tracker is closed.
- No new defer-frame constants as final fixes.
- Temporary bridges must be explicitly marked and removed by the canonical fix.
- Every streaming code change needs a runtime smoke or interactive traversal.
- Automated stress is useful, but manual 10-minute traversal is the final gate.
- The current `dense-loop` stress route is a local churn probe, not broad
  coverage: it repeatedly revisits the same 3x3 cell neighborhood. Use it to
  exercise load/unload/state-reversal churn, not to prove open-world traversal.

## Milestones

### P0.0 Tracker And Handoff

Status: tracker updated through visible manual traversal pass and post-cleanup smoke

- [x] Write recovery handoff with diagnosis and official-docs research.
- [x] Write this P0 fix tracker.
- [x] Update `docs/STATUS.md` after the first validated stabilization result.

### P0.1 Diagnostic Eviction Bridge

Status: superseded by P0.2; visible manual traversal passed after bridge removal

Purpose: determine whether the current crash class is specifically caused by
`ModelLoader` cache eviction releasing resources too early, or whether the crash
moves to broader unload/RID lifetime.

Implementation:

- [x] Add a temporary early return to `ModelLoader._evict_if_over_budget()`.
- [x] Include the required bridge block:
  - symptom papered over
  - canonical pattern standing in for it
  - follow-up removal commit
  - dated TODO with owner and expiration
- [x] Run a Godot stress smoke that exercises sustained cell transitions.
- [x] If smoke passes, launch interactively for user/manual traversal.

Acceptance:

- Crash smoke survives longer than the prior 19:55 crash window without hitting
  `_model_cache.erase`.
- No claim of "fixed" until manual traversal passes.

Exit criteria:

- If stable with eviction disabled, implement P0.2.
- If still crashing, pivot to P0.4 unload/RID lifecycle audit before touching
  `ResourceHandle`.
- If the route completes but quit/shutdown hangs or crashes, record that as a
  separate lifecycle failure. Do not call the bridge stable until shutdown and
  manual traversal both pass.

### P0.2 StreamedResourceHandle Ownership Model

Status: first ownership slice implemented; eviction active; visible manual traversal passed

Canonical target:

```gdscript
class_name StreamedResourceHandle
extends RefCounted

var cache_key: String
var packed_scene: PackedScene
var extracted_meshes: Array[Mesh]
var extracted_materials: Array[Material]
var owners: Dictionary
```

Required behavior:

- Cache lookup is non-owning or weak.
- `CellPayload` owns strong handles for every resource needed by that cell.
- Static renderer entries either hold strong handles or strong extracted
  `Mesh`/`Material` references.
- Interactive publish entries hold handles until the node is attached or safely
  discarded.
- Queued callbacks hold handles until completed or canceled.
- Unload releases payload-owned handles only after worker tasks are drained and
  node/server cleanup has completed.
- Eviction can only remove non-owning cache lookup state.

Acceptance:

- Eviction bridge removed.
- `_model_cache.erase` no longer releases resources still used by live payloads.
- Visible manual traversal passes.

### P0.3 Per-Payload Publish Scheduler

Status: first static-prepare ownership slice implemented; child-attach attempt backed out after visible crash

Goal: collapse cross-cutting global queues into payload-owned queues.

Target shape:

```text
NativeStreamingManager
  rotates CellPayload.publish_step(budget_usec)

CellPayload
  owns classification, model requests, callbacks, static publish,
  child attach, collision publish, and unload cleanup for one cell
```

Do not start this before P0.1 determines the current crash class. If P0.1 still
crashes with eviction disabled, P0.4 runs before both P0.2 and P0.3.

Acceptance:

- `process_async_instantiation()` no longer acts as the owner of every lifetime.
- A cell unload has one owner that can drain workers, release resources, free
  nodes, and free RIDs in order.
- Queue length telemetry is per payload and globally summarized.

First slice note, 2026-04-30:

- Static-prepare work item storage moved onto `CellPayload`.
- `NativeStreamingManager` now rotates active async request payloads and calls
  `CellPayload.publish_step(budget_usec)` for the static-prepare lane before
  the legacy instantiation drain.
- The old world-scoped static-prepare selector queue was removed. Queue size is
  now summarized from active payloads.
- `process_async_instantiation()` no longer owns static-prepare publishing; it
  still owns classification, disk-load drain, Node3D publish, child attach, and
  collision finalization until later lanes migrate.

Backed-out attempt, 2026-04-30:

- Pending child attach records were briefly moved onto `CellPayload`, but the
  visible manual gate crashed during traversal after cell unloads.
- That child-attach attempt was backed out. Keep the accepted static-prepare
  slice and choose a different next lane or redesign child-attach ownership with
  a stronger unload/lifetime proof before retrying it.
- This is intentionally not the full P0.3 scheduler rewrite. The accepted
  static-prepare slice establishes the repeatable ownership pattern for the
  next queue lane.

### P0.4 Unload / RID Lifecycle Audit

Status: pending

Required if the eviction-disabled probe still crashes.

Audit:

- RS instance creation/free ownership
- static renderer fallback RIDs
- PrototypeRegistry/MultiMesh RIDs if re-enabled
- interactive `MeshInstance3D` resource lifetimes
- collision body and shape lifetimes
- pending child attach discard paths
- state-reversal unload limbo
- WorkerThreadPool task drain paths

Acceptance:

- Every RID has a single owner and a documented free point.
- Every server-bound `Resource` has a strong owner until all RIDs using it are
  freed.
- Shutdown and cell unload use the same lifecycle rules.

Exit criteria:

- When this audit completes, return to P0.2 first and P0.3 second, informed by
  the audit findings. P0.4 is a diagnostic prerequisite, not a replacement for
  the handle model or scheduler cleanup.

### P0.5 Reintroduce Systems One At A Time

Status: pending

Order:

1. direct RS static fallback
2. player-local collision
3. spatial-bucketed MultiMesh/PrototypeRegistry
4. MID/HLOD
5. FAR/impostors

Each step must pass:

- Godot crash smoke
- 10-minute manual traversal
- teleport stress
- shutdown smoke
- cache churn smoke

## Verification Log

### 2026-04-29 Baseline Crash

Command:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --headless --path D:/Gamedev/Godotwind/godotwind --quit
```

Result:

- Crashed after roughly 175 seconds.
- Crash path: `model_loader.gd:_evict_if_over_budget`.
- Log: `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/logs/godot2026-04-29T19.55.13.log`

### 2026-04-29 Eviction Bridge Smoke

Status: diagnostic route completed; shutdown failed

Command:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --bench-stress=eviction_bridge_probe_2026_04_29_codex --stress-duration=75 --stress-route=dense-loop
```

Result:

- Stress summary was written after the 75 second dense-loop route.
- `cell_transitions`: 62
- `frames`: 4368
- `avg_fps`: 58.229
- `p95_ms`: 26.496
- `p99_ms`: 30.336
- `frames_over_33_33`: 23
- `max_stream_total_ms`: 106.698
- No `_evict_if_over_budget` crash was observed during the route.
- Godot did not exit cleanly after the summary. The process remained running and
  became non-responsive; Codex stopped PID 30648 manually.
- Log output repeated `material_set_shader` errors with a null `material`
  parameter during the hang.

Artifacts:

- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_summary_eviction_bridge_probe_2026_04_29_codex.json`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_events_eviction_bridge_probe_2026_04_29_codex.csv`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_eviction_bridge_probe_2026_04_29_codex.csv`

Interpretation:

The bridge appears to move past the immediate cache-eviction crash, but this is
not a stable baseline. Treat the quit hang and null-material renderer spam as a
separate lifecycle/shutdown failure that must pass before the bridge can be
accepted as a temporary stabilization point.

### 2026-04-29 Stress Runner Fast-Cleanup Probe

Status: route completed; shutdown still failed

Change under test:

- `src/tools/streaming_stress_runner.gd` benchmark quit path now calls
  `native_streaming_manager.fast_cleanup()` when available, matching the manual
  fast-quit shutdown contract before `get_tree().quit()`.

Command:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --bench-stress=quit_cleanup_probe_2026_04_29_codex --stress-duration=20 --stress-route=dense-loop
```

Result:

- Stress summary was written after the 20 second dense-loop route.
- `cell_transitions`: 17
- `frames`: 1056
- `avg_fps`: 52.763
- `p95_ms`: 28.02
- `p99_ms`: 32.451
- `frames_over_33_33`: 8
- `max_stream_total_ms`: 40.953
- Godot did not exit within the 120 second watchdog and Codex killed PID 21324.

Artifacts:

- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_summary_quit_cleanup_probe_2026_04_29_codex.json`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_events_quit_cleanup_probe_2026_04_29_codex.csv`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_quit_cleanup_probe_2026_04_29_codex.csv`

Interpretation:

Calling `fast_cleanup()` from the stress runner is correct because it aligns
the automated benchmark with the user/manual quit contract, but it does not fix
the shutdown hang. P0 must continue treating shutdown/material lifecycle as an
open failure.

### 2026-04-29 Shutdown Owner Probe

Status: project shutdown hooks completed; process still crashed after final
autoload exit

Commands:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --bench-stress=final_autoload_exit_probe_2026_04_29_codex --stress-duration=5 --stress-route=dense-loop
```

Result:

- Stress summary was written after the 5 second dense-loop route.
- `cell_transitions`: 4
- `frames`: 583
- `avg_fps`: 116.584
- `p95_ms`: 19.258
- `p99_ms`: 23.292
- `max_stream_total_ms`: 26.219
- Shutdown markers reached all known project owners:
  - `WORLD_EXPLORER_EXIT done`
  - `WEATHER_MANAGER_EXIT done`
  - `DEFORMATION_MANAGER_EXIT done`
  - `SHADER_MANAGER_EXIT done`
  - `OCEAN_MANAGER_EXIT done`
  - `ESM_MANAGER_EXIT done`
  - `BSA_MANAGER_EXIT done`
  - `SETTINGS_MANAGER_EXIT done`
  - `LOG_EXIT done`
- Godot then crashed with signal 11 after all project autoload teardown markers.

Artifacts:

- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_summary_final_autoload_exit_probe_2026_04_29_codex.json`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/logs/godot.log`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/logs/crash_report.txt`

Interpretation:

The automated quit failure is no longer localized to a project `_exit_tree()`
owner. It occurs after all instrumented project teardown hooks return, which
points to engine or native extension finalization seeing invalid render/native
state. Do not keep adding shutdown ordering patches without a clear owner.

### 2026-04-29 Reviewer Follow-Up Checks

Status: completed enough to park shutdown as non-blocking for P0.2

Reviewer request:

- Confirm no tracked `WorkerThreadPool` task IDs remain at final autoload exit.
- Run a no-streaming control to see whether the post-autoload shutdown crash
  still reproduces without camera tracking/cell streaming.

Commands:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --disable-world-streaming --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision --quit-after-ready=1
```

Result:

- Process exited with Windows access violation code `-1073741819`
  (`0xC0000005`).
- Shutdown reached final autoload marker `LOG_EXIT done`.
- Final tracked task diagnostic at `LOG_EXIT`:
  - `background_processor.active_tasks`: 0
  - `background_processor.pending_tasks`: 0
  - `background_processor.orphaned_wtp_handles`: 0
  - `cell_preloader.task_ids`: 0
  - `cell_manager.pending_parse_tasks`: 0
  - `cell_manager.collision_tasks`: 0
  - `cell_manager.worker_instance_tasks`: 0
  - `cell_manager.worker_static_tasks`: 0
  - `instantiator.prereg_tasks`: 0
  - `instantiator.prereg_dispatchers`: 0
  - `impostor_renderer.rebuild_task_id`: -1
- The diagnostic control still had non-worker queue state because the scene
  booted its normal managers before quitting:
  - `cell_manager.async_requests`: 6
  - `cell_manager.instantiation_queue`: 118
  - `cell_manager.static_prepare_queue`: 90
  - `cell_manager.proximity_deferred`: 62
- No tracked project-owned WorkerThreadPool task was left un-awaited at final
  teardown.
- The C++ crash report has no usable symbols in this local binary; the final
  GDScript marker before signal 11 is `LOG_EXIT done`, so the crash is not
  inside a project GDScript `_exit_tree()` frame.

Artifacts:

- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/logs/godot.log`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/logs/crash_report.txt`

Interpretation:

This rules out the specific WorkerThreadPool contract violation flagged in
review for currently tracked project task IDs. The shutdown crash still
reproduces after final autoload teardown with camera tracking disabled, so it is
parked as a native/engine finalization crash for now. P0.2 should proceed with
streaming resource ownership; do not block that work on post-`LOG_EXIT`
shutdown.

### 2026-04-29 StreamedResourceHandle Slice 1

Status: first ownership slice implemented; eviction bridge still enabled

Changes:

- Added `src/core/streaming/streamed_resource_handle.gd`.
- `ModelLoader` now maintains one `StreamedResourceHandle` per cached
  `PackedScene` key and exposes `get_cached_resource_handle()`.
- `CellPayload` can pin a loader-owned handle and releases only its per-cell
  owner token instead of clearing the handle.
- `CellManager` prefers the loader-owned handle when pinning payload resources
  for publish/static-prepare paths.

Verification commands:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --disable-world-streaming --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision --quit-after-ready=0.5
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --bench-stress=handle_slice_2026_04_29_codex --stress-duration=3 --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision
```

Results:

- No GDScript parse errors, compile errors, invalid calls, or `ERROR:` lines
  were found in either smoke.
- The 3 second dense-loop streaming smoke completed and wrote a summary:
  - `cell_transitions`: 3
  - `avg_fps`: 179.395
  - `p95_ms`: 9.382
  - `p99_ms`: 16.140
  - `max_stream_total_ms`: 17.310
- Final tracked task diagnostic at `LOG_EXIT` for the streaming smoke:
  - `background_processor.active_tasks`: 0
  - `background_processor.pending_tasks`: 0
  - `background_processor.orphaned_wtp_handles`: 0
  - `cell_preloader.task_ids`: 0
  - `cell_manager.pending_parse_tasks`: 0
  - `cell_manager.collision_tasks`: 0
  - `cell_manager.worker_instance_tasks`: 0
  - `cell_manager.worker_static_tasks`: 0
  - `instantiator.prereg_tasks`: 0
  - `instantiator.prereg_dispatchers`: 0
  - `impostor_renderer.rebuild_task_id`: -1
- Both smokes still hit the known post-`LOG_EXIT` native signal 11. The local
  Godot binary has no usable C++ symbols for that backtrace.
- After fixing duplicate payload re-pins to avoid incrementing the same cell
  owner twice, a final no-streaming ready-quit smoke again reached
  `LOG_EXIT done` with no GDScript parse/compile/invalid-call errors and zero
  tracked WorkerThreadPool tasks.

Next:

- Completed by 2026-04-30 slice 2: the diagnostic bridge was removed and
  eviction is active again.

### 2026-04-30 StreamedResourceHandle Slice 2

Status: eviction re-enabled; automated smokes completed; visible manual traversal passed

Changes:

- `CellPayload.bind_resource_handles_to_node()` transfers strong streamed
  resource handles onto the loaded `cell_node` before the async request is
  erased. This fixes the ownership hole where `get_async_result()` released
  payload handles while the loaded cell stayed alive in the world.
- `ModelLoader._evict_if_over_budget()` no longer uses the diagnostic early
  return.
- `ModelLoader._evict_if_over_budget()` now removes lookup state without
  calling `handle.release()` on an unowned handle. If another owner is holding
  the same `StreamedResourceHandle`, that refcounted object must remain
  authoritative for its own inner `PackedScene` / `Mesh` / `Material`
  resources.

Verification commands:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --disable-world-streaming --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision --quit-after-ready=0.5
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --bench-stress=handle_eviction_active_2026_04_30_codex --stress-duration=20 --stress-route=dense-loop --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision
```

Results:

- No GDScript parse errors, compile errors, invalid calls, or `ERROR:` lines
  were found in the no-streaming smoke.
- The no-streaming smoke still exited with the known post-`LOG_EXIT` native
  access violation (`-1073741819`).
- The 20 second dense-loop smoke completed and wrote a summary:
  - `cell_transitions`: 17
  - `avg_fps`: 160.281
  - `p95_ms`: 10.968
  - `p99_ms`: 18.533
  - `max_stream_total_ms`: 29.895
  - `frames_over_33_33`: 2
- No `_evict_if_over_budget` crash was observed during the route.
- The process did not exit within the 120 second watchdog after `LOG_EXIT done`,
  so Codex killed PID 6464. Treat this as the already-known shutdown/finalize
  failure, not a traversal pass.

Artifacts:

- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_summary_handle_eviction_active_2026_04_30_codex.json`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_events_handle_eviction_active_2026_04_30_codex.csv`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_handle_eviction_active_2026_04_30_codex.csv`

Next:

- Completed by the broad straight-route smoke below: a broader route entered
  38 fresh cells with eviction active and did not hit the old eviction crash.
- Completed by the visible manual traversal below.

### 2026-04-30 Broad Straight-Route Smoke

Status: traversal completed; shutdown still hit known post-`LOG_EXIT` native crash

Purpose:

- Address the user's concern that `dense-loop` stays in one local 3x3 area.
- Exercise continuous fresh-cell entry with eviction active after the handle
  ownership changes.

Command:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --bench-stress=handle_eviction_active_east_2026_04_30_codex --stress-duration=45 --stress-route=east --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision
```

Results:

- Straight east route covered 4500 m.
- The runner logged 38 cell transitions, from `(-2, -9)` through `(36, -9)`.
- The route completed and wrote a summary:
  - `avg_fps`: 216.164
  - `p95_ms`: 9.202
  - `p99_ms`: 15.805
  - `frames_over_33_33`: 2
  - `frames_over_50`: 1
  - `max_stream_total_ms`: 27.293
  - `max_queue_size`: 94
- No `_evict_if_over_budget` crash was observed.
- Final task diagnostics at `LOG_EXIT` had zero async requests, zero
  instantiation queue, zero proximity deferred, zero static prepare queue, and
  zero tracked WorkerThreadPool tasks.
- Process exited with the known post-`LOG_EXIT` signal 11 / Windows access
  violation (`-1073741819`).

Artifacts:

- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_summary_handle_eviction_active_east_2026_04_30_codex.json`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_events_handle_eviction_active_east_2026_04_30_codex.csv`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_handle_eviction_active_east_2026_04_30_codex.csv`

Interpretation:

This is stronger than dense-loop for traversal coverage, but it is still not
the final gate. The visible 10-minute manual traversal remains required before
claiming the streaming baseline stable.

### 2026-04-30 Visible Manual Traversal

Status: user-visible pass

Command:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn
```

Result:

- Codex launched the scene visibly as PID 1220.
- User reported: "works well. I quit the scene, it didn't crash".
- Follow-up process check found PID 1220 no longer running.

Interpretation:

This is the required user-visible traversal gate for the current P0.2 handle
slice. It is more important than the hidden automated probe shutdown crashes:
those remain useful diagnostic data, but they did not reproduce on the visible
manual scene quit reported here.

### 2026-04-30 Post-Cleanup Ready-Quit Smoke

Status: script/runtime smoke passed; native finalization crash still known

Command:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --disable-world-streaming --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision --quit-after-ready=0.5
```

Result:

- Scene initialized successfully with world streaming disabled.
- No GDScript parse errors or invalid-call errors were printed.
- The ready-quit timer fired and `BackgroundJobSystem stopped`.
- Process then hit the already-known native signal 11 during finalization.
- No Godot process was left running after the smoke.

Interpretation:

This confirms the post-review cleanup did not introduce script-level startup or
ready-quit regressions. It does not supersede the visible manual pass, which
remains the meaningful user-visible gate for P0.2.

### 2026-04-30 Normal Launch Probe

Status: startup did not crash within bounded probe

Command:

```powershell
$godot='D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe'
$proj='D:/Gamedev/Godotwind/godotwind'
$p = Start-Process -FilePath $godot -ArgumentList @('--path',$proj,'scenes/Godotwind.tscn') -PassThru -WindowStyle Hidden
$exited = $p.WaitForExit(45000)
if (-not $exited) { Stop-Process -Id $p.Id -Force }
```

Result:

- The process was still running after 45 seconds.
- Codex killed PID 26188 because this was a bounded launch probe, not an
  interactive/manual traversal session.
- The process was launched hidden, so this was not the user-visible manual
  verification gate.
- Treat this as evidence that the current known failure is not "crashes at
  launch." The unresolved failures remain movement/streaming traversal
  stability and the known post-`LOG_EXIT` native shutdown/finalization crash.

### 2026-04-30 P0.3 Static-Prepare Payload Slice

Status: automated smoke completed; visible manual verification passed

Changes:

- Moved static-prepare work item storage from `CellManager.StaticPrepareEntry`
  into `CellPayload`.
- Kept `CellManager` as the caller and retained a selector queue for global
  ordering/type-level dedupe so this first slice preserves the old scheduler
  behavior while shifting ownership of the work record to the payload.
- `fast_cleanup()`, per-request cancel, unload finalization, collision-blocking
  checks, and loading stats now route through the payload-owned work state.

Verification commands:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --disable-world-streaming --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision --quit-after-ready=0.5
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --bench-stress=p03_static_prepare_payload_selector_2026_04_30_codex --stress-duration=5 --stress-route=dense-loop --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision
```

Results:

- `git diff --check` passed; Git printed only existing CRLF normalization
  warnings for edited files.
- The initial no-streaming ready-quit launch reached startup without
  script-level parse/runtime errors. A direct shell invocation left a Godot
  process alive and Codex killed it; this matches the known automated quit
  fragility, not the user-visible manual quit path.
- The dense-loop smoke completed and wrote summary artifacts:
  - `frames`: 522
  - `cell_transitions`: 4
  - `avg_fps`: 104.458
  - `p95_ms`: 14.588
  - `p99_ms`: 17.318
  - `frames_over_33_33`: 0
  - `max_stream_total_ms`: 27.325
  - `max_queue_size`: 33
- The process exited afterward with the already-known native access violation
  during automated benchmark shutdown.
- Codex launched `scenes/Godotwind.tscn` visibly as PID 10164.
- User reported in `#general`: "It ran well. I quit it at the end of the
  test."
- Follow-up process check found PID 10164 no longer running.

Artifacts:

- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_summary_p03_static_prepare_payload_selector_2026_04_30_codex.json`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_events_p03_static_prepare_payload_selector_2026_04_30_codex.csv`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_p03_static_prepare_payload_selector_2026_04_30_codex.csv`

Interpretation:

The first P0.3 slice exercised the moved static-prepare path, completed the
automated traversal smoke, and passed the visible manual gate. This does not
close all of P0.3; it establishes the payload-owned work-record pattern for
the next queue lane.

### 2026-04-30 P0.3 Child-Attach Payload Attempt

Status: backed out after visible manual crash

Changes:

- Moved pending child attach records from `_pending_child_attaches` into
  `CellPayload`.
- Kept `CellManager` as the drain caller with a selector queue containing only
  `{request_id, attach_id}` so the old global LIFO attach order is preserved.
- Per-request cancel, unload finalization, and fast cleanup now free detached
  child nodes through the payload-owned attach records.

Verification commands:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --disable-world-streaming --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision --quit-after-ready=0.5
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --bench-stress=p03_child_attach_payload_selector_2026_04_30_codex --stress-duration=5 --stress-route=dense-loop --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision
```

Results:

- `git diff --check` passed; Git printed only existing CRLF normalization
  warnings for edited files.
- The no-streaming ready-quit launch reached startup without script-level
  parse/runtime errors and then hit the already-known native finalization
  access violation.
- The dense-loop smoke completed and wrote summary artifacts:
  - `frames`: 786
  - `cell_transitions`: 4
  - `avg_fps`: 157.159
  - `p95_ms`: 10.610
  - `p99_ms`: 17.294
  - `frames_over_33_33`: 0
  - `max_stream_total_ms`: 25.100
  - `max_queue_size`: 33
- The process exited afterward with the already-known native access violation
  during automated benchmark shutdown.
- Codex then launched `scenes/Godotwind.tscn` visibly as PID 12536.
- User reported in `#general`: "it crashed."
- Crash report:
  - session duration: 84.6 seconds
  - camera cell: `(-1, -8)`
  - streaming queue: 2 pending
  - loaded NEAR cells: 5
  - last operations: `CELL_UNLOADED: (-3, -9)`, then
    `CELL_UNLOADED: (-2, -10)`
  - no script errors recorded
- Because the static-prepare slice had already passed visible verification and
  this crash appeared after the child-attach move, the child-attach attempt was
  backed out.

Artifacts:

- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_summary_p03_child_attach_payload_selector_2026_04_30_codex.json`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_events_p03_child_attach_payload_selector_2026_04_30_codex.csv`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_p03_child_attach_payload_selector_2026_04_30_codex.csv`

Interpretation:

The automated smoke was not sufficient for this lane. The visible traversal
found a native crash around cell unload, so the child-attach ownership move is
not accepted. Do not repeat this exact approach without a stronger proof of
detached node lifetime across unload/state reversal.

### 2026-04-30 Post-Backout Dense-Loop Stress

Status: traversal completed; known automated benchmark shutdown crash remains

Context:

- The child-attach ownership attempt was backed out.
- This run kept the accepted static-prepare payload slice.
- `startup` had a non-overlapping boot-gate patch in
  `src/core/world/native_streaming_manager.gd` before this run, so the startup
  portion includes that separate change.

Command:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --bench-stress=p03_static_prepare_after_child_backout_dense90_2026_04_30_codex --stress-duration=90 --stress-route=dense-loop --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision
```

Results:

- The 90 second dense-loop route completed and wrote summary artifacts.
- `frames`: 14733
- `cell_transitions`: 74
- `avg_fps`: 163.713
- `p95_ms`: 10.158
- `p99_ms`: 17.424
- `frames_over_33_33`: 8
- `frames_over_50`: 2
- `max_stream_total_ms`: 51.992
- `max_queue_size`: 33
- Log reached `BENCH_QUIT - stress runner complete, graceful tree quit`.
- Process then hit the already-known native signal 11 during automated
  benchmark shutdown.

Artifacts:

- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_summary_p03_static_prepare_after_child_backout_dense90_2026_04_30_codex.json`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_events_p03_static_prepare_after_child_backout_dense90_2026_04_30_codex.csv`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_p03_static_prepare_after_child_backout_dense90_2026_04_30_codex.csv`

Interpretation:

After backing out the child-attach ownership move, dense-loop load/unload churn
completed without the visible traversal crash class seen in the child-attach
attempt. The remaining accepted P0.3 code slice is static-prepare payload
ownership.

### 2026-04-30 Post-Backout East Stress

Status: traversal completed; known automated benchmark shutdown crash remains

Context:

- The child-attach ownership attempt was backed out.
- This run kept the accepted static-prepare payload slice.
- `startup` had a non-overlapping boot-gate patch in
  `src/core/world/native_streaming_manager.gd`, so the startup portion includes
  that separate change.

Command:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --bench-stress=p03_static_prepare_after_child_backout_east60_2026_04_30_codex --stress-duration=60 --stress-route=east --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision
```

Results:

- The 60 second east route completed and wrote summary artifacts.
- `frames`: 13965
- `cell_transitions`: 51
- `avg_fps`: 232.743
- `p95_ms`: 9.926
- `p99_ms`: 15.966
- `p99_9_ms`: 28.513
- `frames_over_33_33`: 6
- `frames_over_50`: 1
- `max_stream_total_ms`: 32.214
- `max_queue_size`: 102
- `max_loaded_cells`: 9
- Log reached `BENCH_QUIT - stress runner complete, graceful tree quit`.
- Process then hit the already-known native signal 11 during automated
  benchmark shutdown.

Artifacts:

- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_summary_p03_static_prepare_after_child_backout_east60_2026_04_30_codex.json`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_events_p03_static_prepare_after_child_backout_east60_2026_04_30_codex.csv`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_p03_static_prepare_after_child_backout_east60_2026_04_30_codex.csv`

Interpretation:

The accepted static-prepare payload storage slice survived both dense-loop churn
and a broader fresh-cell east traversal after the child-attach backout. Unload
and instantiation spikes remain performance work; this run did not reproduce
the child-attach visible traversal crash.

### 2026-04-30 Static-Prepare SceneState Crash Follow-Up

Status: blocker remains; local fix attempts backed out

Trigger:

- `startup` reported that stationary `--quit-after-ready=20` verification for
  their boot-gate patch crashed before they could prove the gate.
- Crash path:
  `static_object_renderer.gd:430 register_from_packed_scene` ->
  `cell_manager.gd:_process_static_prepare_entry` ->
  legacy `_process_static_prepare_queue` -> `process_async_instantiation` ->
  `native_streaming_manager.gd:_process`.

Rejected attempts:

- Switching static-prepare registration to the live prototype path
  (`model_loader.get_model()` + `register_from_prototype()`) avoided the
  stationary `register_from_packed_scene` crash, but dense-loop verification hit
  a `723.4ms` static-prepare spike on `flora_kelp_02.nif` and then a native
  crash before a stress summary was written. This was backed out.
- Deferring material RID creation out of `register_from_packed_scene()` avoided
  the immediate `material_override.get_rid()` site, but produced a runaway
  `ERROR: Parameter "material" is null` loop in
  `material_set_shader`. The probe was killed and this was backed out.

Current state:

- No accepted code fix landed for this crash.
- The accepted P0.3 code remains only the static-prepare payload storage move.
- The unresolved blocker is the pre-existing `PackedScene.get_state()` /
  `SceneState` material extraction path in `register_from_packed_scene`, not
  the reverted live-prototype or RID-deferral experiments.

### 2026-04-30 Static Prototype Descriptor Slice

Status: first implementation draft; descriptor RID cleanup landed; automated shutdown parked

Changes:

- `StaticObjectRenderer.register_from_packed_scene()` and
  `register_from_prototype()` now build a validated
  `StaticPrototypeDescriptor` and publish through one helper.
- Descriptor construction stores strong `Mesh` / `Material` resources only.
  Mesh and material RIDs for descriptor-based static prototypes are derived at
  actual RS instance creation instead of during static prepare / descriptor
  publish. Direct `register_mesh_type()` remains the legacy/debug path that may
  cache caller-provided RIDs.
- This removes material RID creation from the `SceneState` static-prepare lane
  without changing the direct `register_mesh_type()` debug/test path.

Verification commands:

```powershell
git diff --check
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --bench-stress=static_descriptor_slice_2026_04_30_coder --stress-duration=5 --stress-route=dense-loop --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --quit-after-ready=20 --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision
```

Results:

- `git diff --check` passed with only existing CRLF normalization warnings.
- The 5 second dense-loop stress completed and wrote summary artifacts:
  - `frames`: 725
  - `cell_transitions`: 4
  - `avg_fps`: 144.980
  - `p95_ms`: 10.444
  - `p99_ms`: 18.345
  - `frames_over_33_33`: 2
  - `max_stream_total_ms`: 43.369
  - `max_queue_size`: 33
- The dense-loop process then hit the already-known post-`BENCH_QUIT` native
  signal 11.
- No script parse errors, invalid calls, `register_from_packed_scene` errors,
  or `material_set_shader` null-material loops were found in the dense-loop
  `godot.log`.
- The stationary `--quit-after-ready=20` hidden probe still exited with
  Windows access violation `-1073741819` before `READY_QUIT`.
- That stationary crash no longer logged the old `register_from_packed_scene`
  / `SceneState` GDScript backtrace. The last breadcrumb was
  `cm::inst_tail_done :: queue=54 child=0 cfin=0`; the last high-signal log was
  a `981.3ms` instantiation overrun dominated by `addc=976.4ms`.
- Follow-up cleanup after reviewer/third-opinion feedback removed the remaining
  descriptor RID inconsistency: `_publish_static_descriptor()` no longer caches
  `mesh_resource.get_rid()` either. Descriptor-published `MeshType`s now match
  the material policy: resources are strong-owned, RIDs are derived at
  `_create_rs_instance()` use-time.
- Follow-up dense-loop smoke
  `--bench-stress=descriptor_rid_cleanup_2026_04_30_coder --stress-duration=5
  --stress-route=dense-loop --disable-jolt-attach --disable-phase-f-prereg
  --disable-cell-static-collision` completed live traversal and wrote summary:
  `frames=800`, `cell_transitions=4`, `avg_fps=160.071`, `p95_ms=10.085`,
  `p99_ms=17.585`, `frames_over_33_33=1`, `max_stream_total_ms=34.539`,
  `max_queue_size=33`.
- That follow-up still hit the parked post-`BENCH_QUIT` signal 11 after summary
  write. No `material_set_shader` null-material loop,
  `register_from_packed_scene` error, script parse error, or invalid-call error
  was found in the log.

Artifacts:

- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_summary_static_descriptor_slice_2026_04_30_coder.json`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_events_static_descriptor_slice_2026_04_30_coder.csv`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_static_descriptor_slice_2026_04_30_coder.csv`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_summary_descriptor_rid_cleanup_2026_04_30_coder.json`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_events_descriptor_rid_cleanup_2026_04_30_coder.csv`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_descriptor_rid_cleanup_2026_04_30_coder.csv`

Interpretation:

This draft appears to remove the old static-prepare material RID crash site,
but it does not make the stationary startup probe production-safe. The next
blocker is now the child-attach / scene-tree publication lifecycle spike and
native crash, so the P0.4 lifecycle audit should cover child attach before
retrying the earlier payload-owned child-attach move.

### 2026-04-30 Child-Attach Lifecycle Audit And Diagnostics

Status: diagnostics landed; stationary ready-quit reached; automated shutdown/finalization parked as non-blocking harness/native finalization

Changes:

- Added `docs/audit/near_streaming_lifecycle_audit_2026_04_30_coder.md`.
- `CellManager._queue_child_attach()` now records source metadata on each
  detached child attach record: request id, grid, type, model path, item id,
  ref id, and ref num.
- `_drain_pending_child_attaches()` brackets each `add_child()` with
  `cm::attach_one_begin` / `cm::attach_one_done` breadcrumbs.
- Slow child attaches over 16ms now log `[child-attach-spike]` with direct
  child and descendant counts.

Verification commands:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --quit-after-ready=20 --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --bench-stress=child_attach_diag_dense_2026_04_30_coder --stress-duration=5 --stress-route=dense-loop --disable-jolt-attach --disable-phase-f-prereg --disable-cell-static-collision
```

Results:

- Stationary `--quit-after-ready=20` reached `READY_QUIT`, drained queue and
  child attach counts to zero, then hit the known post-quit native signal 11.
- No `[child-attach-spike]` line was produced during the stationary probe, so
  the earlier 976ms `addc` spike did not reproduce in this run.
- Dense-loop stress completed and wrote summary artifacts:
  - `frames`: 432
  - `cell_transitions`: 4
  - `avg_fps`: 86.426
  - `p95_ms`: 16.740
  - `p99_ms`: 22.209
  - `frames_over_33_33`: 1
  - `max_stream_total_ms`: 35.668
  - `max_queue_size`: 33
- The dense-loop process then hung after `BENCH_QUIT` in the known
  null-material/native finalization loop and was killed by Codex's watchdog.
- No GDScript parse errors or invalid-call errors were observed.

Artifacts:

- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_summary_child_attach_diag_dense_2026_04_30_coder.json`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_events_child_attach_diag_dense_2026_04_30_coder.csv`
- `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/stress_child_attach_diag_dense_2026_04_30_coder.csv`

Interpretation:

The child-attach path is now observable enough to name the exact ref if a heavy
`add_child()` recurs. The repeatable failure in these probes is automated
shutdown/finalization, not a live traversal crash. Do not retry the backed-out
payload-owned child attach move until a slow attach or unload-lifetime failure
is captured with this metadata, or until the broader P0.4 RID/lifecycle audit
chooses a smaller ownership lane.

### 2026-04-30 Automated Shutdown Ablation Boundary

Status: parked; not the next P0 implementation lane

Ablation evidence:

| Probe | Result | Interpretation |
| --- | --- | --- |
| Manual visible quit reported by user | Clean / no visible crash | User path is not blocked by the automated harness crash. |
| `--bench-stress=static_descriptor_slice_2026_04_30_coder` | Traversal summary written, then post-`BENCH_QUIT` signal 11 | Live dense-loop streaming path completed before finalization crash. |
| Stationary `--quit-after-ready=20` after child-attach diagnostics | Reached `READY_QUIT`, queue=0, child=0, then signal 11 | Shutdown crash occurs after streaming queues drain. |
| Stationary `--quit-after-ready=5 --disable-world-streaming` | `NativeStreamingManager.fast_cleanup()` returned; all instrumented streaming nodes exited; signal 11 occurred after `WorldExplorer._exit_tree` | Reproduces without active cell tracking/streaming, so this is not evidence for a NEAR traversal owner. |

Accepted narrow cleanup:

- `NativeImpostorRenderer.fast_cleanup()` now stops its private
  `BackgroundJobSystem` and drains its WTP texture-array rebuild task. This is
  a concrete owner cleanup that belongs under `NativeStreamingManager.fast_cleanup()`
  independent of the harness crash.
- Automated quit paths call the same fast-cleanup contract as the manual fast
  quit path before `SceneTree.quit()`.

Backed out / not accepted:

- Broad `ShaderManager` compositor teardown, Terrain3D forced detach/free, and
  autoload/scene exit marker instrumentation were removed. They were plausible
  teardown suspects but not proven owners of the crash signature.

Decision:

Park post-`READY_QUIT` / post-`BENCH_QUIT` native signal 11 as an automated
harness/native finalization issue unless it reproduces during live traversal or
on the user's manual visible quit path. Resume P0.3/P0.4 streaming lifecycle
work on concrete ownership lanes: descriptor RID consistency, model request
callbacks, collision publish ownership, RS instance / MultiMesh / registry slot
lifetime.

### 2026-04-30 Phase 0A/0B Architecture Collapse

Status: first implementation draft

Plain-English goal: keep one live ownership path per concern, delete dead
loading/warmup branches, and route payload-owned work through a payload method
before moving more queues.

Landed:

- Deleted the disabled boot static prewarm path:
  `BOOT_STATIC_PREWARM_ENABLED`, `BOOT_STATIC_PREWARM_BUDGET_MS`,
  `BATCH_PREWARM_COUNT`, `world_explorer._warmup_static_renderer_boot()`,
  `NativeStreamingManager.warmup_static_renderer_boot()`, and
  `CellManager.warmup_static_batches_for_cell_ring()`.
- Deleted the disabled static-prepare batch reservation path:
  `STATIC_PREPARE_CREATE_BATCHES`,
  `StaticObjectRenderer.prepare_batches_for_type()`,
  `warmup_static_batch_pipeline()`, and `reserve_batches_for_type()`.
- Removed the global static-prepare selector queue from `CellManager`; each
  `CellPayload` now owns its own static-prepare entries.
- Added the Phase 0B seam:
  `CellPayload.publish_step(budget_usec)` and
  `NativeStreamingManager._process_payload_publish_steps()`.

Triage table:

| Path / flag | Current decision | Delete target |
|---|---|---|
| `BOOT_STATIC_PREWARM_ENABLED` | Deleted. Disabled path was not production and duplicated runtime static prepare. | Done 2026-04-30 |
| `STATIC_PREPARE_CREATE_BATCHES` | Deleted. Batch reservation was disabled and contradicted the current type-registration-only prepare lane. | Done 2026-04-30 |
| global static-prepare selector queue | Deleted. Payload-owned queues are the accepted P0.3 direction. | Done 2026-04-30 |
| `PHASE_A_OFFTHREAD_INSTANTIATE` | Kept parked. The code is compiled out and still needs an isolated Godot 4.6 harness before production. | Delete or replace during Phase 1 model-callback lane, by 2026-05-02 |
| `DEBUG_DISABLE_PHASE_F_PREREG` | Kept as a crash-risk opt-in research gate. Default-disabled prereg is not production. | Delete when model callback ownership lane decides prereg fate, by 2026-05-02 |
| `STATIC_CULL_NATIVE_ENABLED` | Kept with `PrototypeRegistry`. Registry is still present but gated off; Phase 2A adds a transitional RS bucket path, not the final per-cell MultiMesh replacement. | Delete with world-scoped `PrototypeRegistry` in Phase 2B, by 2026-05-04 |
| `STATIC_CULL_UPLOAD_DEFER_FRAMES_AFTER_UNLOAD` | Kept with world-scoped `PrototypeRegistry` upload path. | Delete with world-scoped `PrototypeRegistry` in Phase 2B, by 2026-05-04 |
| `CELL_STATIC_COLLISION_FINALIZE_DEFER_FRAMES_AFTER_UNLOAD` | Kept. Collision worker payload/task/body ownership now lives on `CellPayload`; defer policy remains a lifecycle guard pending the P0.4 unload/finalize audit. | Delete or justify during P0.4 lifecycle audit, by 2026-05-03 |

Next lane:

- Phase 1 lane 1 is model request callback ownership. Do not move child attach
  until Phase 2 reduces heavy static-looking refs through per-cell buckets.

Verification:

- `git diff --check` passed with CRLF normalization warnings only.
- `--quit-after-ready=3 --disable-jolt-attach --disable-phase-f-prereg
  --disable-cell-static-collision` reached boot readiness, reported
  `static_prepare_queue=4`, called `WORLD_EXPLORER_FAST_CLEANUP`, then hit the
  already-parked post-`READY_QUIT` native signal 11.
- Dense-loop stress
  `p0a_p0b_payload_publish_dense_2026_04_30_coder` completed and wrote summary
  before the already-parked post-`BENCH_QUIT` signal 11: 753 frames, 4 cell
  transitions, avg 150.54 FPS, p95 10.528 ms, p99 18.149 ms, p99.9 32.665 ms,
  max stream total 27.264 ms, max queue 33, no frames over 33.33 ms.
- Log inspection found no `SCRIPT ERROR`, parse error, invalid call,
  `material_set_shader`, or `register_from_packed_scene` errors.

### 2026-04-30 Phase 1 Lane 1 Callback Ownership Draft

Status: implementation draft blocked by east-route child-attach crash

Changes drafted:

- `CellPayload` now owns disk-model waiter lists and completed model-load
  notifications.
- `ModelLoader` completion callbacks no longer queue refs into the global
  instantiation queue directly. They pin the loaded resource handle to the
  payload immediately, then mark the payload completion.
- `CellPayload.publish_step()` drains completed model callbacks under the
  payload publish budget and queues the waiting refs for legacy Node3D/static
  publish.
- `AsyncCellRequest.pending_disk_loads` was removed; completion/playable checks
  now summarize payload-owned pending/completed model callbacks.

Verification:

- `--quit-after-ready=3 --disable-jolt-attach --disable-phase-f-prereg
  --disable-cell-static-collision` reached boot readiness with no script or
  callback errors, then hit the already-parked post-`READY_QUIT` native signal
  11.
- Dense-loop stress `p1_model_callbacks_dense_2026_04_30_coder` completed and
  wrote summary before the already-parked post-`BENCH_QUIT` path: 901 frames,
  4 transitions, avg 180.145 FPS, p95 8.800 ms, p99 15.927 ms, p99.9
  30.479 ms, max stream total 25.448 ms, max queue 33, no frames over
  33.33 ms. Post-`BENCH_QUIT` logged the known null-material teardown loop.
- East-route stress crashed before summary. The crash was during live traversal,
  not post-quit: last route transition was `(0, -9) -> (1, -9)`, queue was 0,
  and the last logs show `addc=984.7ms` and `addc=698.0ms` instantiation spikes
  before the crash. Crash report showed no script errors and no recorded engine
  errors.

Decision:

Do not request implementation review for this draft as accepted. The broader
gate exposes the child-attach long pole that the plan intentionally parked
until static buckets reduce heavy Node3D attach volume. Next architecture step
needs plan adjustment: either start Phase 2 static bucket routing before more
Phase 1 lanes, or define a narrow non-kludge child-attach ownership fix with a
clear delete path.

### 2026-04-30 Phase 2A Static Bucket Draft

Status: accepted by reviewer as transitional Phase 2A, not full Phase 2

Changes drafted:

- Added `CellStaticBucket`, a renderer-owned transitional per-cell static
  publish bucket that creates/frees the RenderingServer instances for a model
  key as one lifetime unit.
- Static-routed refs no longer enter the Node3D instantiation / child-attach
  path. Classification records their transforms on the payload, pins the model
  resource handle, and lets the static-prepare lane create the bucket.
- `StaticObjectRenderer` now indexes bucket owners by cell so existing
  hide/remove/clear paths clean them up through the same facade as legacy
  static instances. Completed async requests currently erase their
  `CellPayload`, so live bucket lifetime is owned by this renderer index, not by
  the payload.
- `CellManager` completion/playable checks now wait for payload static-prepare
  work to drain, and hard request cancellation removes any bucket state for the
  request grid.
- The queue-priority sort is bounded to a 512-entry tail window after east-route
  probes exposed a long unbounded sort/diagnostic frame. The old recursive
  child-count diagnostic was also removed from the hot warning path.

Implementation note:

This draft deliberately uses the existing direct RS-instance primitive inside a
bucket owner, not `MultiMesh`. A same-scope MultiMesh bucket attempt was backed
out because it produced render-server `material_set_shader` null-material
errors and automated shutdown hangs. The live-behavior move still lands:
static-looking heavy refs leave scene-tree child attach and become renderer
bucket entries. Reviewer accepted this as Phase 2A only; Phase 2B must decide
the final per-cell bucket architecture before deleting the world-scoped
PrototypeRegistry/direct paths.

Required Phase 2B follow-up:

- Either move bucket lifetime to the loaded cell/payload owner or keep the
  renderer-owned contract explicit.
- Make bucket hide truly budgeted, or cap/split bucket size so dense unloads
  cannot hide an entire heavy bucket in one call.
- If buckets become real cell/payload owners, make them hold mesh/material
  resource refs or handles directly instead of relying on
  `StaticObjectRenderer._mesh_types`.

Verification:

- `git diff --check` passed with CRLF normalization warnings only.
- `--quit-after-ready=3 --disable-jolt-attach --disable-phase-f-prereg
  --disable-cell-static-collision` reached `READY_QUIT` with
  `static_prepare_queue=0`, then hit the already-parked post-quit signal 11.
- East-route stress
  `phase2_static_buckets_east_v5_2026_04_30_coder` completed 30 seconds and
  wrote summary before post-`BENCH_QUIT` signal 11: 6340 frames, 26 cell
  transitions, avg 211.333 FPS, p95 7.797 ms, p99 15.310 ms, p99.9 23.182 ms,
  max stream total 26.043 ms, max inst 18.563 ms, max queue 21, with one
  92.836 ms frame outside the measured stream/inst hot path.
- Dense-loop stress
  `phase2_static_buckets_dense_v2_2026_04_30_coder` completed 30 seconds and
  wrote summary before post-`BENCH_QUIT` signal 11: 5639 frames, 25 cell
  transitions, avg 187.956 FPS, p95 8.458 ms, p99 17.038 ms, p99.9 26.183 ms,
  max stream total 33.715 ms, max inst 18.812 ms, max queue 16, two frames over
  33.33 ms, zero frames over 50 ms.
- Log inspection found no `SCRIPT ERROR`, parse error, `ERROR:`,
  `material_set_shader`, or `child-attach-spike` lines in the accepted
  ready/east/dense logs. The only remaining crash signature is the already
  parked automated post-quit signal 11 after `READY_QUIT`/`BENCH_QUIT`.

Post-review cleanup:

- Reviewer accepted this as Phase 2A / transitional RS-bucket slice only, not
  full Phase 2.
- Code comments and tracker wording now describe live bucket lifetime as
  renderer-owned through `StaticObjectRenderer._cell_buckets`. `CellPayload`
  records the bucket while its async request is active, but completed requests
  erase the payload; unload cleanup therefore runs through the renderer facade.
- Phase 2B remains the final static bucket lane: choose the real per-cell
  owner contract, make bucket hide budgeted or cap/split dense buckets, and
  hold mesh/material resource refs directly if bucket ownership moves out of
  `StaticObjectRenderer._mesh_types`.

Post-review verification:

- `git diff --check` passed with CRLF normalization warnings only.
- Dense-loop stress `phase2a_postreview_dense_2026_04_30_coder` completed 30
  seconds and wrote summary before the parked post-`BENCH_QUIT` signal 11:
  5733 frames, 25 transitions, avg 191.093 FPS, p95 8.526 ms, p99 17.732 ms,
  p99.9 31.097 ms, max stream total 36.675 ms, max inst 20.851 ms, max queue
  16, three frames over 33.33 ms, zero over 50 ms.
- East-route stress `phase2a_postreview_east_2026_04_30_coder` completed 30
  seconds and wrote summary before the parked post-`BENCH_QUIT` signal 11:
  5392 frames, 26 transitions, avg 179.718 FPS, p95 9.581 ms, p99 18.339 ms,
  p99.9 29.408 ms, max stream total 34.166 ms, max inst 31.180 ms, max queue
  7, five frames over 33.33 ms, one frame over 50 ms, max frame 93.555 ms.
- Log inspection found no `SCRIPT ERROR`, parse error, `material_set_shader`,
  or `child-attach-spike` lines in the fresh dense/east runs. The east log's
  remaining terminal crash is the already parked automated post-quit signal 11.

Rejected Phase 2B budget experiments:

- Rejected: a partial per-bucket RID hide/free cursor approach was tested and backed out.
  Dense wrote a summary, but the process then entered a `material_set_shader`
  null-material loop after `BENCH_QUIT`.
- Rejected: a bounded bucket-splitting approach was then tested and backed out. Dense
  completed without the material loop, but east-route either entered the same
  post-`BENCH_QUIT` material loop or crashed during `CellStaticBucket.configure`
  before the stress summary.
- Do not land either approach as-is. Phase 2A remains the accepted transitional
  slice. Phase 2B needs a written material/RID lifetime design before changing
  bucket granularity or free ordering again.

### 2026-04-30 Phase 1 Lane 2 Collision Publish Ownership Draft

Status: implementation draft ready for review

Changes drafted:

- Moved per-cell static collision publish state from `AsyncCellRequest` onto
  `CellPayload`: worker build payload, worker task id, finalized
  PhysicsServer body, and built/dispatched flags.
- Kept `CellManager` as the driver for dispatch, nearest-ready finalization,
  cancellation, and body cleanup. This is an ownership move, not a scheduler
  rewrite.
- Cancellation and unload cleanup now drain the worker and free finalized
  collision bodies through the payload-owned fields before request teardown.
- Completion and collision-blocking gates now summarize payload-owned model
  callbacks/static-prepare state instead of request-owned callback queues.

Verification:

- Short ready smoke with collision disabled reached `READY_QUIT` with no script
  or material errors, then hit the already-parked post-quit signal 11:
  `--quit-after-ready=1 --disable-jolt-attach --disable-phase-f-prereg
  --disable-cell-static-collision`.
- Dense-loop stress with static collision enabled
  `collision_payload_owner_dense_2026_04_30_coder` completed 30 seconds and
  wrote summary before the parked post-`BENCH_QUIT` signal 11: 3418 frames, 25
  transitions, avg 113.967 FPS, p95 15.676 ms, p99 18.089 ms, p99.9
  25.321 ms, max stream total 31.403 ms, max inst 19.697 ms, max queue 18, two
  frames over 33.33 ms, zero frames over 50 ms.
- East-route stress with static collision enabled
  `collision_payload_owner_east_2026_04_30_coder` completed 30 seconds and
  wrote summary before the parked post-`BENCH_QUIT` signal 11: 3910 frames, 26
  transitions, avg 130.329 FPS, p95 15.508 ms, p99 18.087 ms, p99.9
  29.332 ms, max stream total 27.715 ms, max inst 20.629 ms, max queue 12, one
  frame over 33.33 ms, one frame over 50 ms, max frame 96.726 ms.
- Fresh log inspection found no `SCRIPT ERROR`, parse error, `ERROR:`,
  `material_set_shader`, or `child-attach-spike` lines in the collision-enabled
  dense/east runs. The only crash signature was the already-parked automated
  post-quit signal 11 after `READY_QUIT`/`BENCH_QUIT`.

Interpretation:

This accepts the collision-publish ownership move as a narrow Phase 1 slice. It
does not close the lifecycle audit: the unload/finalize defer flag and broader
worker/body lifetime proof still belong in P0.4.

## Open Questions

- Which remaining interactive paths hold only RIDs or implicit mesh refs without
  a strong `Resource` owner?
- Can `CellPayload` become the only owner of per-cell queue state without a
  large-bang rewrite?
- Should PrototypeRegistry be rebuilt as per-cell/per-chunk MultiMeshes instead
  of rehabilitating the world-scoped design?

Resolved during P0.2:

- The immediate eviction crash did not recur after `StreamedResourceHandle`
  ownership landed and eviction was re-enabled.
- `StreamedResourceHandle` lives in `src/core/streaming/`. The handle is
  framework-level, game-data agnostic, and `src/core/streaming/` already owns
  async streaming helpers.
