# Impostor Generation Speedup Plan

Date: 2026-05-02

Goal: make v6 impostor generation faster without compromising the newly verified
scale, overlap, alpha, and normal correctness.

## Canonical Basis

- Godot SubViewport render targets support one-shot updates (`UPDATE_ONCE`);
  the baker should eventually use explicit render updates instead of
  timer-driven `UPDATE_ALWAYS` waits.
- Standard LOD/HLOD/impostor systems gate proxy work by screen size or
  distance. Impostor eligibility should be based on projected screen size at the
  first distance where the impostor can appear.

## Phase 0 - Instrument Before Optimizing

Add per-model timing breakdowns:

- `convert_albedo`
- `convert_normal`
- `capture_albedo`
- `capture_normal`
- `readback`
- `pack`
- `save_png`
- `save_res`
- `state_save`

Also log model bounds, projected pixels at the impostor start distance, chosen
atlas tier, grid size, and total bake seconds.

Success metric: every slow model has a concrete timing breakdown before the
pipeline is changed.

## Phase 1 - Projected-Size Eligibility

Enforce impostor eligibility using real model bounds, not just filename
patterns. At the production impostor start distance, many small objects occupy
only a few pixels and should not be baked.

Projected pixel estimate:

```text
pixels = object_extent_m / distance_m * viewport_height / (2 * tan(fov / 2))
```

At 1000m, 1080p, 60 degree FOV:

- 2m object: about 3.7 px
- 4m object: about 7.5 px
- 8m object: about 15 px
- 16m object: about 30 px

Initial policy:

- `< 4 px at 1000m`: skip.
- `4-8 px`: skip unless explicitly whitelisted as a readable landmark.
- `8+ px`: eligible.

This is expected to be the largest total-time win because skipped assets avoid
all captures, conversions, and artifact writes.

## Phase 2 - Resolution By In-Game Size

Keep one v6 impostor logic path, but choose atlas resolution from projected
screen size.

Initial tier table:

| Projected size at start | Bake decision |
| --- | --- |
| `< 8 px` | Skip unless whitelisted |
| `8-16 px` | 256 atlas, 32 px frame, 8x8 grid |
| `16-32 px` | 512 atlas, 64 px frame, 8x8 grid |
| `32+ px` or landmark | 1024 atlas, 128 px frame, 8x8 grid |

Add metadata fields:

- `projected_px_at_start`
- `size_tier`
- `capture_size_m`
- `impostor_start_distance_m`

## Phase 3 - Capture Loop Speed

Replace timer-based capture waits with explicit one-shot viewport updates:

1. Set both cameras and transforms for a direction.
2. Set both SubViewports to `UPDATE_ONCE`.
3. Await the render/post-render frame.
4. Read albedo and normal/depth textures.

Capture albedo and normal/depth in lockstep per direction instead of two
sequential 64-frame passes. Keep two scene copies alive if needed: original
materials for albedo, normal-override materials for normal/depth.

After a validation pass, reduce settle from three frames to one frame if stale
captures do not occur.

## Phase 4 - Avoid Repeated Work

- Convert/load once per model where possible, then duplicate the scene for the
  normal/depth capture.
- Save prebake state every N models or every few seconds instead of after every
  model. Flush on pause, finish, and error.
- Make normal debug PNG output optional. Keep it enabled for validation builds;
  disable it for production full bakes.

## Phase 5 - Validation Gates

Create a deterministic bake benchmark set:

- tree
- rock
- building
- ruin
- wall
- prop

Compare before and after:

- seconds per model
- total skipped by projected-size filter
- atlas alpha/color sanity
- runtime smoke uploaded count and texture layers
- no missing required v6 artifacts

After changes, launch:

- single-model visualizer
- all-impostor stress scene

## Expected Impact Order

1. Projected-size skip filter: biggest total-time reduction.
2. Lockstep albedo + normal/depth capture: biggest per-baked-model reduction.
3. One-shot/one-frame capture instead of timer waits: large per-baked-model
   reduction.
4. Optional debug PNG and batched state saves: smaller but straightforward.
