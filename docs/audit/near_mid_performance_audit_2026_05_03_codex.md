# NEAR + MID Performance Audit

Date: 2026-05-03
Owner: Codex

## Scope

This audit is code-grounded. It does not treat `docs/STATUS.md` or distance
rendering docs as truth; the active paths were read directly from:

- `src/tools/world_explorer.gd`
- `src/core/world/native_streaming_manager.gd`
- `src/core/world/cell_manager.gd`
- `src/core/world/static_object_renderer.gd`
- `src/core/world/cell_static_bucket.gd`
- `src/core/world/native_impostor_renderer.gd`
- `src/core/world/distant_light_manager.gd`
- `src/core/world/reference_instantiator.gd`

The user explicitly postponed FAR impostor work. FAR/HLOD findings are recorded
only so the next session does not rediscover them; the active implementation
work should target the NEAR + MID path first.

## Verification Run

Command launched:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn --bench-stress=codex_default_20260503 --stress-route=dense-loop --stress-duration=30 --stress-speed=100 --stress-altitude=100
```

`dotnet build Godotwind.sln` succeeded first, with existing nullable warnings
only.

The fresh run opened the Godotwind scene but terminated before writing a stress
summary. Crash report:

```text
C:\Users\metzo\AppData\Roaming\Godot\app_userdata\Godotwind\logs\crash_report.txt
```

Crash report state:

- Session duration: 32.5s
- Camera: `(-58.5, 100.0, 929.2)`, cell `(-1, -8)`
- NEAR cells: 7
- MID instances: 1519
- FAR impostors: 2833
- HLOD: 0
- Ocean: off
- Sky: off

Last relevant log before termination:

```text
[autopsy 769.7ms stream_proc] top: instantiate=769.5
```

This is a hard stall/crash path in the streaming/instantiation lane, not merely
a lower average FPS problem.

## Existing Benchmark Evidence

Existing benchmark artifacts from today under:

```text
C:\Users\metzo\AppData\Roaming\Godot\app_userdata\Godotwind\benchmark_results
```

Dense loop comparison:

| Mode | Avg FPS | p95 ms | p99 ms | Frames >50ms | Max stream ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| `--near-only` | ~130 | 11.6 | 25.3 | 1 | 42.5 |
| default distant | ~106 | 16.9 | 30.4 | 15 | 84.7 |

Important caveat: current `--near-only` is not literally "NEAR only". Code in
`world_explorer.gd` only disables HLOD and impostors. MID remains on, and
distant lights, sky, weather, shadows, and postfx remain at their defaults.

Ladder benchmark:

```text
empty             503.6 FPS
+terrain          326.2 FPS
+near_objects     244.1 FPS
+mid_objects      241.2 FPS
+hlod             179.8 FPS
+impostors        160.6 FPS, min 48 FPS
+distant_lights   238.9 FPS
+sky              104.4 FPS
+ocean             62.2 FPS
+postfx            57.9 FPS
+characters        51.8 FPS
```

The ladder is static/additive and has some asynchronous settling noise, but it
still shows that:

- HLOD and impostors are not ready to be default-on.
- Sky/ocean/postfx/characters are large steady-state costs.
- NEAR + MID alone should be much higher than 100 FPS if other systems are
truly off.

## Current Code Reality

`world_explorer.gd` default subsystem flags:

- `terrain`: true
- `sky`: true
- `weather`: true
- `impostors`: true
- `mid_objects`: true
- `near_objects`: true
- `hlod`: false
- `distant_lights`: true
- `shadows`: true
- `postfx`: true
- `ocean`: false
- `characters`: false

`--near-only` currently does this:

```gdscript
_subsystem_toggles.set_flag("hlod", false)
_subsystem_toggles.set_flag("impostors", false)
```

It does not disable distant lights, sky, weather, shadows, or postfx. So a user
can believe they are measuring "NEAR + MID" while still paying for several
non-NEAR/MID systems.

`NativeStreamingManager._process()` is the central dense loop. In one frame it
can run:

- camera/cell update
- `_update_loaded_cells()`
- deferred impostor update
- HLOD queue/completion/update, when enabled
- distant light update
- orphan pruning
- predictive preloader
- budgeted unload
- async completions
- payload publish
- `CellManager.process_async_instantiation()`
- pending load submission
- static renderer cull tick
- phase telemetry

Each sub-lane has budgets, but the budgets are independent and can still stack.
The architecture is closer to "many local budgets" than a single global
streaming work scheduler.

## Canonical Godot Pattern Check

Checked against Godot 4.6 official docs:

- Thread-safe APIs:
  https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html
- WorkerThreadPool:
  https://docs.godotengine.org/en/4.6/classes/class_workerthreadpool.html
- MultiMesh:
  https://docs.godotengine.org/en/4.6/classes/class_multimesh.html
- GeometryInstance3D visibility ranges:
  https://docs.godotengine.org/en/4.6/classes/class_geometryinstance3d.html

Findings:

1. MID cell buckets mostly follow the canonical Godot pattern.
   `CellStaticBucket` uses server-owned instances, `MultiMesh`, `custom_aabb`,
   visibility ranges, and shadow settings. This is the right family of solution.

2. Distant lights do not follow the canonical pattern well enough.
   A single large/global distant-light `MultiMesh` plus synchronous radius scan
   is the wrong shape for Godot. MultiMeshes should be spatially partitioned and
   given correct AABBs so culling remains local.

3. WorkerThreadPool cleanup is incomplete.
   Godot documents that task IDs should be completed with
   `wait_for_task_completion()`. The prereg path prunes completed task IDs
   without waiting, and some cleanup paths clear task IDs instead of waiting.

4. Threaded scene instancing/prototype registration remains suspect.
   Comments claim `PackedScene.instantiate()` is safe, but the path also walks
   scene resources and calls renderer registration from workers. Treat project
   comments as secondary evidence; the Godot docs are conservative about scene
   tree/resource work across threads.

## NEAR + MID Suspects

### 1. Benchmark isolation is lying

This is the first fix because it affects every measurement.

`--near-only` is described as the distant-tier opt-out, but it only disables
HLOD and impostors. Distant lights still scan/update, and sky/weather/postfx
remain live. For a NEAR + MID measurement, the command line should disable every
non-NEAR/MID renderer path.

Minimal fix:

- Update `--near-only` to also disable `distant_lights`.
- Add a clearer `--near-mid-only` alias.
- Add optional isolation flags for `--no-sky`, `--no-weather`, `--no-postfx`,
  and `--no-shadows` so benchmark names match what is actually running.

### 2. Distant lights can dominate even with HLOD/impostors off

Fresh log evidence:

```text
_update_loaded_cells: 215.8ms [... lights:215.8 ...]
DistantLightManager: added 2962 distant lights
```

Code path:

- `NativeStreamingManager._update_loaded_cells()`
- calls `DistantLightManager.scan_cells_around(_camera_cell, impostor_radius_cells)`
- default radius is the impostor radius, not the loaded-cell radius

If HLOD and impostors are off but distant lights remain on, this is still a
distant rendering path consuming main-thread time.

### 3. MID draw groups may be too granular

`CellStaticBucket` batches by cell, payload/model key, sub-mesh, and then splits
into 0.5-cell clusters. This is safe for culling, but Morrowind content often
has many one-off meshes per cell, so the active MID set can still produce
hundreds of RS instances/draw groups.

Observed benchmark stats:

- MID instances: ~1500
- MID buckets: ~404
- MID draw groups: ~650
- Draw calls in dense/default heartbeat: hundreds before sky/ocean/postfx

The implementation is canonical in kind, but not necessarily aggressive enough.
The next step is not to hand-roll per-frame culling; it is to reduce the number
of submitted draw groups using bigger static batches, material/type clustering,
or offline/runtime merged chunk meshes with a strict budget.

### 4. Instantiation lane can still blow the frame

The fresh crash was preceded by:

```text
[autopsy 769.7ms stream_proc] top: instantiate=769.5
```

Relevant code:

- `NativeStreamingManager._process()`
- `CellManager.process_async_instantiation()`
- pre-loop classify/model-request/disk/conversion/pool-prewarm
- main loop instantiate/reference routing
- child attach
- static collision dispatch/finalize

There are many local budgets in this lane, but the 769ms stall proves at least
one operation is unbounded or blocking inside a supposedly budgeted section.

## Parked FAR/HLOD Findings

These are real but intentionally postponed:

- FAR impostor texture array rebuild/upload spikes are large.
- HLOD adds significant draw/merge/coverage cost when enabled.
- HLOD/MID/FAR coverage sync adds another visibility authority and can remap
  active buckets/pages.

Do not tune these before the NEAR + MID baseline is restored.

## Recommended Work Order

1. Make benchmark/isolation flags truthful.
   A "NEAR + MID" run must disable HLOD, impostors, distant lights, sky,
   weather, postfx, ocean, and characters unless specifically included.

2. Re-run dense-loop at load radius 2 and 3 with true NEAR + MID only.
   Capture FPS, draw calls, objects, primitives, MID buckets/draw groups,
   streaming phase timings, and inst-spike lines.

3. If FPS is still below target with true isolation, attack MID draw group
   count first.
   The canonical direction is fewer, larger static submissions with stable
   spatial AABBs, not a custom per-frame visibility system.

4. Fix the 769ms instantiation stall.
   Add or use existing inst-spike breakdown logs to determine whether the spike
   is classify, model request, disk drain, static register/add, child attach,
   or collision finalize. Then bound that exact operation.

5. Only after NEAR + MID is healthy, revisit FAR impostors and HLOD.

## Follow-Up Implemented Same Session

Code changes made after this audit:

- Added `--near-mid-only` for hard isolation: terrain + NEAR + MID only.
- Changed `--near-only` so it also disables distant-light billboards.
- Added CLI isolation flags: `--no-distant-lights`, `--no-sky`,
  `--no-weather`, `--no-postfx`, `--no-shadows`.
- Added `--load-radius-cells` / `--view-distance-cells` so dense-loop runs can
  explicitly test radius 2 or 3 instead of inheriting user settings.
- Moved subsystem toggle application before `set_camera()`.
- Fixed `NativeStreamingManager.initialize(null)` so it no longer auto-grabs
  the viewport camera and starts streaming before toggles are applied.
- Stopped disabled impostors from receiving deferred cell-change update work.
- Removed synchronous cold visual-proxy registration from the proximity-deferred
  interactive path. Visual proxies are now opportunistic: if the type is not
  already registered, the full interactive object remains deferred for proximity
  rather than spending hundreds of milliseconds in the streaming frame.

Verification after these changes:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn --near-mid-only --load-radius-cells=2 --bench-stress=codex_nearmid_r2_final_20260503 --stress-route=dense-loop --stress-duration=10 --stress-speed=100 --stress-altitude=100
```

Result:

- FAR/HLOD/impostors stayed at zero.
- No distant-light scan was logged.
- No `inst-spike` from visual-proxy registration was logged.
- No disabled-impostor deferred update was logged.
- The run still failed performance gates: average FPS ~58.5 over the short
  10s dense-loop smoke, p95 28.7ms, p99 46.5ms, max frame 59.9ms.
- Godot still crashed on shutdown after `BENCH_QUIT`; the summary JSON was
  written before the shutdown crash.

The remaining problem is not FAR/HLOD. The clean NEAR + MID run still submits
too much active MID work: up to ~3,600 MID instances, ~1,700 MID draw groups,
and ~1,500 rendered objects at radius 2. A brief experiment that split large
static buckets into smaller publish chunks reduced one local prepare spike but
increased draw groups and made FPS worse, so it was reverted. The next fix must
reduce total MID submissions/draw groups, not split them further.
