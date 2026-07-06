# Water / Ocean Performance Audit — 2026-07-06

Static audit of the water stack's per-frame costs (`src/core/water/`), requested
alongside the sky/clouds perf work. Fixes shipped same day; verification notes
at the bottom.

## Findings

### 1. Water-body atlas rebuild every 2 m of movement — FIXED (main offender)

`ocean_fft_provider.gd` and `water_world.gd` each maintain a 128×128 world-space
"water body atlas" (coverage + height of rivers/lakes around the camera,
512 m window). A rebuild is **16,384 CPU registry samples on the main thread**,
each iterating every registered water body/provider with polygon point tests,
Variant `call()` dispatch, and a Dictionary allocation per candidate
(`water_body_registry.get_best_candidate`).

The re-center threshold was **2 m** — while flying, the rebuild re-ran
near-continuously. Raised to **32 m** (camera stays within 6% of the window
extent from center; waterline/underwater consumers reach ≤140 m, always well
inside). Added a `Log.warn` when a rebuild exceeds 8 ms so real-world cost shows
up in logs.

**Still open (only if the warn fires in practice):** move the rebuild off the
main thread (WorkerThreadPool over immutable registry data) or time-slice rows
across frames; kill the per-sample Dictionary allocation in
`get_best_candidate`.

### 2. `get_water_surface_state()` rebuilt from scratch on every call — FIXED

Called ~6-8× per frame (waterline compositor, underwater compositor,
particulates, physics interactors, player controller, buoyant bodies). Each
call did 2-3 registry polygon-samples at the camera position. Worse,
`water_world.get_water_surface_state()` (the path WaterSystem uses):

- always overwrote the provider's camera samples with its own — the provider's
  registry sampling was pure waste on that path, and
- rebuilt the **entire provider state a second time** just to read
  `coverage_source`.

Fixed: camera-position registry samples are cached per process frame in both
files (the camera can't move mid-frame); the double provider build is replaced
by capturing `coverage_source` from the state already in hand.

### 3. Things checked and found healthy

- **GPU wave readback** (`use_gpu_wave_readback`): a full-pipeline
  `texture_get_data` sync per cascade per frame — but **defaults to false**;
  the default buoyancy path is the CPU spectral evaluator
  (`OceanPhysicsEvaluator`), which is the canonical pattern. Leave the sync
  path as the debug/exact-match option it is.
- **FFT cascade updates**: rate-limited via `fft_updates_per_second`. Healthy.
- **Per-frame uniform pushes**: `ocean_time`, `sun_dir_world` (with a 60-frame
  scan gate for finding the light) — trivial.
- **RD texture getters** return cached RIDs; no per-frame value-returning
  RenderingServer calls in the hot path.
- **PrewaterCaptureRenderer**: an extra receiver-only scene render at 0.5×
  resolution into a SubViewport — expensive by nature, but activation-gated to
  near-waterline (≤140 m fade) and explicitly avoids GPU syncs. By design for
  the waterline effect. Verify its viewports stay `UPDATE_DISABLED` when far
  from water during the next profiling flight.

### 4. Noted, not changed

- `state.optical_profile = _optical_profile.duplicate_profile()` allocates a
  Resource copy per state build (defensive copy). Cheap in isolation; if
  profiling shows it, cache the duplicate per frame.
- `water_world.gd` duplicates the whole atlas + interactor pipeline of
  `ocean_fft_provider.gd`. Which of the two registries actually carries river
  sources at runtime decides which atlas rebuilds; the new warn logs will name
  the culprit. Longer-term the duplication should collapse into one owner.

## How to verify

Fly along a river/lake shoreline and over open ocean for ~60 s. In the log:

- No "atlas rebuild took X ms" warnings (or rare ones with the new 32 m gate —
  if they fire at all, escalate to the async rebuild).
- Frame time near water should no longer dip on movement specifically
  (standing still vs. flying used to differ because of the 2 m rebuild gate).
