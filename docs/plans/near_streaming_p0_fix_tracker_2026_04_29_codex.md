# NEAR Streaming P0 Fix Tracker

Date: 2026-04-29  
Owner: Codex  
Branch: `perf/distant-rendering-2026-04-17`  
Related handoff: `docs/audit/near_streaming_recovery_handoff_2026_04_29_codex.md`

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

Status: pending

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
