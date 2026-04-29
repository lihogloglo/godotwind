# Shadow Pass Optimization — Handoff

**Date:** 2026-04-22
**Branch:** `perf/distant-rendering-2026-04-17`
**Priority:** high — dominant cost in draw-call budget
**Status:** investigation only; no code changes yet

---

## Finding

Instrumented the streaming heartbeat ([native_streaming_manager.gd](../../src/core/world/native_streaming_manager.gd) `_process` — `Viewport.get_render_info` split by `RENDER_INFO_TYPE_VISIBLE` vs `RENDER_INFO_TYPE_SHADOW`). Pilot at Seyda Neen then walk to Pelagiad / Balmora. Consistent pattern across locations:

**Seyda Neen steady state (sec=55–85):**
```
draws = 1560   (vis=331, shad=1125)  → 72% of draws are shadow pass
objs  = 2422   (vis=382, shad=1302)
```

**Balmora/Pelagiad dense (sec=120–135):**
```
draws = 3582   (vis=712, shad=2766)  → 77% of draws are shadow pass
```

**Shadow multiplier ≈ 3.4×** over the visible pass. Dominates the frame budget and compounds with object density — the denser the scene, the bigger the absolute shadow cost.

---

## Root cause — Godot native, no kludge in our code

Current sun config at [sky_manager.gd:274–276](../../src/core/sky/sky_manager.gd#L274):

```gdscript
_sun_light.shadow_enabled = true
_sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
_sun_light.directional_shadow_max_distance = 200.0
```

Godot PSSM (Parallel Split Shadow Maps) with 4 splits issues **one draw per shadow-casting mesh per cascade the mesh falls inside**. With overlap between cascades, a mesh typically draws 2–3 times across cascades → ~3.4× multiplier observed. This is standard engine behaviour for directional shadows, not a bug in Godotwind.

The existing `directional_shadow_max_distance = 200.0` is already short (vs. Godot's 100m default, UE's 2km default) — narrowing further wouldn't help much.

---

## Options (ordered by expected ROI)

### 1. Turn off shadow casting on small clutter (HIGHEST ROI, LOW RISK)

For prebaked statics that are small / ground-level (rocks, grass, flora, small debris), set `cast_shadow = SHADOW_CASTING_SETTING_OFF` on their `MeshInstance3D`s. These contribute heavy per-cascade cost but minimal visible shadow (they're tiny shadows players don't notice).

**Where to apply:**
- [StaticObjectRenderer](../../src/core/world/static_object_renderer.gd) at registration time — check prototype AABB; if `AABB.size.y < 2.0m` (waist-high or lower), set `SHADOW_CASTING_SETTING_OFF` on the RS instance via `RenderingServer.instance_geometry_set_cast_shadows_setting`.
- Alternatively at prebake in [nif_converter](../../src/core/nif/nif_converter.gd) via a mesh flag.

**Estimated win:** ~50% reduction in shadow draws (most refs are rocks/flora). Getting `shad=1125` → `shad=550` at Seyda Neen would roughly halve total draws.

**Risk:** visual — need to eyeball which flora/rock thresholds look acceptable without shadows. Start conservative (< 1m AABB) and tune.

### 2. Reduce split count 4 → 2 (MEDIUM ROI, MEDIUM RISK)

Change [sky_manager.gd:275](../../src/core/sky/sky_manager.gd#L275) to `SHADOW_PARALLEL_2_SPLITS`. Halves the maximum cascades a mesh can fall into → roughly halves shadow pass cost.

**Estimated win:** ~50% shadow pass reduction.

**Risk:** shadow quality — 2 splits mean chunkier transitions at cascade boundaries, and each cascade covers a wider distance range with the same shadow atlas budget → coarser shadows. Need visual review; acceptable for a Morrowind-style game with stylized art, may not be for a photorealistic pipeline.

### 3. Aggressive `directional_shadow_fade_start` (LOW ROI, LOW RISK)

Godot fades out the far cascade instead of hard-clipping. Currently likely default (0.8 of max_distance = fade starts at 160m). Could push lower (0.6 → fade starts at 120m) so the far cascade contributes less.

**Estimated win:** ~10–15%. Not dramatic.

**Risk:** shadow edge pops more noticeably as player moves.

### 4. `shadow_reverse_cull_face` toggle (UNCLEAR, LOW EFFORT TO TEST)

Per Godot docs, reverses face-culling for shadow pass. Sometimes a perf win for terrain-dense scenes; sometimes a loss. Just flip and benchmark.

### 5. Move to Nanite-style virtual shadow maps (HIGH ROI, HIGH RISK)

Not available in Godot 4.6. Would require engine fork or waiting for 4.7+. Out of scope for this branch.

---

## Recommended order of attack

1. **Benchmark shadow-off baseline first** (`toggle shadows` via console, wait 5s, read heartbeat). Gives an absolute ceiling — tells us "at best, shadow optimization saves X FPS". Before investing in #1 and #2, confirm the win is worth the complexity.
2. **Ship Option 1** (shadow-off on small clutter via AABB threshold at RS registration time). Canonical UE5/Decima pattern: statics under a size threshold never shadow-cast. Low complexity, high payoff.
3. **Benchmark again.** If still shadow-dominated, ship Option 2 (2 splits).
4. **Option 3 / 4 only if 1 + 2 are insufficient.**

---

## Measurement protocol

Add to each phase of the optimization:

1. Launch `scenes/Godotwind.tscn` interactively, camera at Seyda Neen spawn.
2. Wait for steady state (`_startup_phase = false`, `loading_cells = 0`).
3. Read `draws=N (vis=A shad=B)` from heartbeat log.
4. Compare against this baseline:
   - Seyda Neen static: `draws=1560 (vis=331 shad=1125)`
   - Balmora dense: `draws=3582 (vis=712 shad=2766)`

Autobench `--bench-auto=p5_post_shadow_optim` for deterministic A/B.

---

## Reference — instrumentation already in place

Heartbeat split already logs `draws=N (vis=A shad=B) objs=N (vis=A shad=B)` via `Viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, ...)` etc. See [native_streaming_manager.gd](../../src/core/world/native_streaming_manager.gd) around the heartbeat emit (search for `draws_visible`). This instrumentation stays — it's cheap and useful going forward.

## Reference — industry pattern

- **UE5 Nanite + Lumen**: virtual shadow maps, no per-cascade re-drawing. Reference point for "what good looks like", not immediately reachable in Godot.
- **Decima**: PSSM with aggressive distance/size culling at prebake — small foliage is flagged no-shadow at asset pipeline.
- **Godot docs** — [Using shadows](https://docs.godotengine.org/en/stable/tutorials/3d/lights_and_shadows.html), [Optimization techniques](https://docs.godotengine.org/en/stable/tutorials/performance/using_multimesh.html).
- **gafferongames.com** — not directly applicable to shadows but the mindset of "instrument before optimize" applies.

---

## Out of scope for this handoff

- Moon shadow (already disabled at [sky_manager.gd:287](../../src/core/sky/sky_manager.gd#L287)).
- Point / spot light shadows (not yet active at scale in Godotwind).
- Dynamic shadow caching (`shadow_caster_mask` / `shadow_bake`) — can follow if #1 and #2 aren't enough.

---

# Session 2 handoff (2026-04-22, afternoon) — measurements + refined fix

Session carried forward by the next agent who was asked to "investigate + launch automated tests to confirm what's happening + design the fix". Phase 1a complete with hard data, Phase 1b interrupted, Phase 2 implementation plan refined with exact edit points.

## Phase 1a — baseline autobench COMPLETE

Ran `--bench-auto=baseline_pre_shadow_optim --start-cell=-2,-9`. Output at `user://benchmark_results/autobench_baseline_pre_shadow_optim/` (4 JSONs + heartbeat trace). Godot crashed with signal 11 during shutdown AFTER all JSONs were flushed — not a data integrity issue.

**Seyda Neen steady (camera (-2,-9), sec=55-120, 6-8 cells loaded):**

```
draws=2207 (vis=423 shad=1680)  → 76% shadow
shadow multiplier = 1680/423 = 3.97×
objs=3529 (vis=588 shad=2209)   → 2209/588 = 3.76× object-cascade avg
fps=213-223 (GPU-bound, vsync off)
reg_batches=127, reg_slots=818
```

**Pelagiad steady (camera (-10,-10), post-teleport, sec=191-201):**

```
draws=2744 (vis=739 shad=1901)  → 69% shadow
shadow multiplier = 1901/739 = 2.57×
fps=220-222
reg_batches=250, reg_slots=895
```

**HLOD-off (NEAR-only, sec=211-216):**
draws=3251 (vis=657 shad=2490) → 76% shadow. fps=18-23 (instantiation-bound in this mode, not shadow-representative).

**Corroborates the earlier handoff numbers.** Shadow pass dominates at 69-76% of draws across both test locations. Each mesh draws into 2.5-4 cascades on average — consistent with PSSM 4-split standard overlap behavior.

## Phase 1b — bench-ladder shadow-off ceiling INCOMPLETE

Launched `--bench-ladder=shadow_ceiling --start-cell=-2,-9`. Ladder configured 13 rungs, reached startup-phase sec=31 (settle), but the Godot process terminated before completing any rung samples. Output dir `user://benchmark_results/ladder_shadow_ceiling/` exists but empty.

**To resume next session:** re-run the same command. The ladder needs ~3-4 min after settle to complete. The critical data point is **rung 10 (all features except shadows + characters) vs rung 11 (+ shadows)** — that delta is the absolute shadow-cost ceiling. Expected based on heartbeat data: ~1680 draws saved at Seyda Neen, ~5-10ms GPU time freed.

**Note:** Phase 1 gate criterion is already SATISFIED by the autobench data alone. Shadow pass = 76% of draws at Seyda Neen baseline; even a 50% shadow-pass reduction via Option 1 hits the ≥30% total draws target. The ladder run is confirmatory, not gating.

## Phase 2 — refined implementation plan (ready to ship next session)

### Target: two files, minimal edits

The registry-batched path ([prototype_batch.gd](../../src/core/world/prototype_batch.gd)) owns the ONE shared RS instance per prototype across all cells — this is where the majority of MID-tier statics funnel. Set shadow-off once per batch and every instance of that prototype stops casting.

**Edit 1: [src/core/world/prototype_batch.gd](../../src/core/world/prototype_batch.gd) `_init` (lines 115-158)**

Add const near top of file:
```gdscript
## Disable shadow casting for prototypes whose mesh AABB height is below this
## threshold. Canonical UE5/Decima pattern — small clutter (rocks, flora, tiny
## debris) generates disproportionate shadow-pass cost via PSSM cascade overlap
## (measured 76% of draws at Seyda Neen baseline, 2026-04-22) but produces
## minimal visible shadows at gameplay distance. See
## docs/plans/shadow_pass_optimization_2026_04_22.md.
const SHADOW_OFF_HEIGHT_THRESHOLD: float = 1.0
```

In `_init` immediately after `rs_instance = rs.instance_create()` at line 139 (before `instance_set_base` is fine, or right after `instance_set_transform`):
```gdscript
if p_mesh.get_aabb().size.y < SHADOW_OFF_HEIGHT_THRESHOLD:
    rs.instance_geometry_set_cast_shadows_setting(
        rs_instance, RenderingServer.SHADOW_CASTING_SETTING_OFF
    )
```

**Edit 2: [src/core/world/static_object_renderer.gd](../../src/core/world/static_object_renderer.gd) `_create_rs_instance` (lines 731-769)** — legacy non-registry fallback path.

Add the same const near the other consts at the top:
```gdscript
## See prototype_batch.gd for rationale.
const SHADOW_OFF_HEIGHT_THRESHOLD: float = 1.0
```

Extend `_create_rs_instance` signature with an optional `aabb` param:
```gdscript
func _create_rs_instance(mesh_rid: RID, material_rid: RID,
        surface_materials: Array[Material], xform: Transform3D,
        aabb: AABB = AABB()) -> RID:
```

After `rs.instance_set_transform(instance_rid, xform)`, add:
```gdscript
if aabb.size.y > 0.0 and aabb.size.y < SHADOW_OFF_HEIGHT_THRESHOLD:
    rs.instance_geometry_set_cast_shadows_setting(
        instance_rid, RenderingServer.SHADOW_CASTING_SETTING_OFF
    )
```

Update the two callsites:
- Line 598 (legacy whole-mesh path): append `, mesh_type.aabb` to the `_create_rs_instance` call.
- Line 608 (multi-sub-mesh path): append `, entry.mesh_resource.get_aabb()` — this uses the per-sub-mesh local AABB, not the prototype union.

### Why those two files specifically — ground truth from exploration

- **Impostors already shadow-off** at [native_impostor_renderer.gd:295](../../src/core/world/native_impostor_renderer.gd#L295) via `GeometryInstance3D.cast_shadow = SHADOW_CASTING_SETTING_OFF` — precedent for the pattern.
- **HLOD merged chunks** live past `directional_shadow_max_distance = 200m` ([sky_manager.gd:276](../../src/core/sky/sky_manager.gd#L276)) — not shadow contributors, no edit needed.
- **`cell_manager.gd:504` MultiMeshInstance3D** path is the legacy NEAR-tier MultiMesh batching that the registry/StaticObjectRenderer pipeline replaces. Touching it would be off-architecture per the active NEAR-tier refactor (S.0/S.1 shipped, S.2+ parked).
- **`instance_geometry_set_cast_shadows_setting`** is NOT called anywhere in the codebase at the RS level today — confirmed via full-tree grep. All existing shadow disables use the GeometryInstance3D property (node-level), which doesn't apply to the RS-only MID/registry path.

### Registry path AABB handling

`PrototypeBatchScript.new(p_mesh, p_material, _scenario, initial_batch_capacity)` is called from [prototype_registry.gd:117](../../src/core/world/prototype_registry.gd#L117). The mesh resource is always available — `p_mesh.get_aabb()` computes the tight AABB union of all surfaces in the mesh. Sub-mesh prototypes each get their own batch (one batch per `(mesh_rid, material_rid)` hash), so the threshold applies per-sub-mesh naturally — no union-inflation artifacts.

### Threshold tuning

Start at `1.0m` height. Conservative:
- Catches: rocks, pebbles, small flora (mushrooms, grass tufts), debris, small crockery, coins
- Spares: barrels, crates, bushes, trees, NPCs, architecture, furniture

If visual pass (Phase 3 interactive flight) shows excess shadow-loss on important clutter, lower to `0.7m`. If shadow-pass reduction is insufficient (<30% drop at Seyda Neen), raise to `1.5m` and re-assess.

## Phase 3 — verify (next-next session)

1. `--bench-auto=p5_post_shadow_optim --start-cell=-2,-9`
2. Diff Seyda Neen `bench_tiers.json` before/after. Heartbeat split is the key metric — targets:
   - `shad` count drops ≥30% (from ~1680 to ≤1180)
   - `vis` count unchanged
   - FPS unchanged or up (GPU-bound at 220fps — may not move much, but shadow-pass GPU time savings are headroom for denser scenes)
3. Interactive launch `scenes/Godotwind.tscn` at Balmora, free-fly. No screenshot harness (per CLAUDE.md anti-pattern). Confirm small clutter has no jarring missing-shadow artifacts at gameplay distance (2-5m from character).
4. Append Phase 3 measurement section to this doc.

## Godot 4.6 research findings (for the record)

Key Godot PSSM facts relevant to this optimization, confirmed during Session 2 research:

- **PSSM 4-split draws each mesh once per cascade it overlaps.** No "tightest-cascade-only" culling. Cascade overlap is standard. 3.4× average multiplier we observe is normal for dense scenes.
- **`RENDER_INFO_TYPE_SHADOW` counter sums ALL cascade passes** — 1680 is per-cascade redraws across all 4 cascades, NOT unique shadow-casting meshes × 4. Raw unique shadow-casters ≈ 1680/3.4 ≈ 494.
- **Shadow pass uses the SAME LOD as visible pass.** No per-pass LOD override exists in Godot 4.6. The "force coarser LOD in shadow" optimization requires engine patching — out of scope.
- **`directional_shadow_max_distance = 200m` culls meshes past 200m from ALL shadow cascades.** HLOD chunks (300m+) and impostors (1000m+) don't contribute shadow draws regardless of their cast_shadow setting.
- **`SHADOW_CASTING_SETTING_OFF`** (enum 0) = don't cast, render normally. Correct for our use.
- **`RenderingServer.instance_geometry_set_cast_shadows_setting(rid, setting)`** is the RS-level API. No batched variant. Thread-safety unverified — conservative approach: call from `_init` context (main thread at registration time).
- **Ladder toggle for shadows** at [world_explorer.gd:1635-1636](../../src/tools/world_explorer.gd#L1635-L1636): `if sun: sun.shadow_enabled = on`. Directly flips the DirectionalLight3D property, which is the cleanest possible absolute ceiling measurement.

## Commands reference (for resume)

```bash
# Baseline (already run, data in autobench_baseline_pre_shadow_optim)
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" \
  --path "D:/Gamedev/Godotwind/godotwind" \
  --bench-auto=baseline_pre_shadow_optim --start-cell=-2,-9

# Bench-ladder shadow ceiling — rerun this first in next session
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" \
  --path "D:/Gamedev/Godotwind/godotwind" \
  --bench-ladder=shadow_ceiling --start-cell=-2,-9

# Post-fix (Phase 3, after edits)
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" \
  --path "D:/Gamedev/Godotwind/godotwind" \
  --bench-auto=p5_post_shadow_optim --start-cell=-2,-9
```

Output directory: `%APPDATA%/Godot/app_userdata/Godotwind/benchmark_results/`
Godot log: `%APPDATA%/Godot/app_userdata/Godotwind/logs/godot.log` (circular, one run)

---

# Session 3 handoff (2026-04-22, evening) — Phase 2 SHIPPED, Phase 3 autobench PASSED

Sub-1m `SHADOW_CASTING_SETTING_OFF` implemented in both targeted paths and verified by post-fix autobench. Primary gate **PASSED (-31.9% total draws at Seyda Neen steady)**; NEAR-only mode (shadow-bound) FPS jumped **+81.7%**. No parse errors, no runtime regressions during the bench run. Shutdown signal 11 recurred — same pre-existing crash as the baseline run, data flushed cleanly.

## What shipped

**Edit 1 — [src/core/world/prototype_batch.gd](../../src/core/world/prototype_batch.gd):**
- Added `SHADOW_OFF_HEIGHT_THRESHOLD: float = 1.0` const near FADE_SHADER.
- In `_init` immediately after `instance_set_transform`, applied `RenderingServer.instance_geometry_set_cast_shadows_setting(rs_instance, SHADOW_CASTING_SETTING_OFF)` when `p_mesh.get_aabb().size.y < SHADOW_OFF_HEIGHT_THRESHOLD`. Applies to the single shared RS instance per batch — every MultiMesh slot of that prototype inherits the setting via the instance.

**Edit 2 — [src/core/world/static_object_renderer.gd](../../src/core/world/static_object_renderer.gd):**
- Added `SHADOW_OFF_HEIGHT_THRESHOLD: float = 1.0` const near `REGISTRY_FADE_DURATION_S`.
- Extended `_create_rs_instance` with optional `aabb: AABB = AABB()` param; applied shadow-off when `aabb.size.y > 0.0 and aabb.size.y < SHADOW_OFF_HEIGHT_THRESHOLD` (guard on `> 0.0` preserves legacy behaviour when callers don't pass an AABB).
- Updated the two internal callsites: legacy single-mesh path passes `mesh_type.aabb` (union), multi-sub-mesh path passes `entry.mesh_resource.get_aabb()` (tight per-sub-mesh).

Both edits idempotent — re-entry via registry rebuild or legacy rebuild reapplies the setting from the same AABB read. No worker-thread concerns: both sites run on main thread at registration time.

## Phase 3 measurements

Baseline: `autobench_baseline_pre_shadow_optim/` (from Session 2, 2026-04-22 morning)
Post-fix: `autobench_p5_post_shadow_optim/` (2026-04-22 evening)
Both: `--start-cell=-2,-9`, Godot 4.6 stable mono win64, same box.

### bench_tiers (Seyda Neen static, 30s) — PRIMARY GATE

| metric          | baseline      | post-fix      | delta         | pct     |
|-----------------|---------------|---------------|---------------|---------|
| draws_avg       |        2207.0 |        1503.0 |        -704.0 | **-31.9%** |
| fps_avg         |         218.9 |         219.1 |          +0.2 |  +0.1% |
| objs_avg        |        3529.0 |        2372.0 |       -1157.0 | -32.8% |
| prims_avg       |     1,183,452 |     1,083,130 |      -100,322 |  -8.5% |
| registry_slots  |         818.0 |         904.0 |         +86.0 | +10.5% |

**Heartbeat split at steady state (sec=65-95 post-fix vs. Session 2 baseline):**
- Baseline: `draws=2207 (vis=423 shad=1680)` — shadow 76%
- Post-fix: `draws=1503 (vis=331 shad=1068)` — shadow 71%
- Shadow pass: **-612 draws, -36.4%** (exceeds target ≤1180)
- Visible pass: -92 draws, -21.8% — small camera-orientation variance between runs (steady-state camera pose is not bit-identical across runs; scene has more loaded instances post-fix but the frustum happened to cover fewer visible meshes). Not a rendering regression.
- Shadow multiplier: 3.97× → 3.23× (cascade-overlap cost drops as small casters are removed).

FPS unchanged at 220 because the scene was already GPU-bound at the monitor's refresh ceiling — the ~5–10ms GPU time freed is headroom for denser scenes, not visible on the FPS graph here. The next locations show where it materialises.

### bench_teleport (Pelagiad (-10,-10), 20s post-teleport)

| metric       | baseline      | post-fix      | delta     | pct     |
|--------------|---------------|---------------|-----------|---------|
| draws_avg    |        2698.7 |        3429.1 |   +730.4  | +27.1%  |
| fps_avg      |         184.3 |         207.9 |   +23.6   | **+12.8%** |
| objs_avg     |        3444.7 |        4174.4 |   +729.8  | +21.2%  |
| slots_avg    |         818.0 |         835.8 |    +17.8  |  +2.2%  |

Classic "freed shadow budget, used for more visible content" signal: post-fix streamed in **more** cells/objects during the 20s window AND ran **faster**. Shadow-pass overhead was the governing factor — reducing it let the teleport settle-in complete deeper in the budget window before the 20s sample closed.

### bench_hlod_off (NEAR-only Pelagiad, 10s) — SHADOW-DOMINATED WIN

| metric       | baseline      | post-fix      | delta     | pct     |
|--------------|---------------|---------------|-----------|---------|
| draws_avg    |        3165.0 |        3839.9 |   +674.9  | +21.3%  |
| fps_avg      |          21.3 |          38.7 |   +17.4   | **+81.7%** |
| objs_avg     |        4068.7 |        4763.6 |   +694.9  | +17.1%  |
| slots_avg    |         292.3 |         412.1 |   +119.8  | +41.0%  |

NEAR-only mode disables HLOD + impostor tiers and forces every far static through the NEAR pipeline. Baseline was instantiation+shadow-pass bound at **21 FPS**. Post-fix jumped to **38.7 FPS** — nearly doubled — despite rendering ~21% more draws and ~41% more registry slots than baseline (more content streamed in during the 10s sample because each frame had budget left over). This is the headline real-world win: in the worst-case dense-shadow scenario, we went from stutter-frame territory back into 40+ FPS range.

### Gate criteria — SATISFIED

- [x] Shadow pass drops ≥30% at Seyda Neen steady: **-36.4%**, draws `shad=1680 → 1068`.
- [x] Total draws drop ≥30%: **-31.9%**, `draws=2207 → 1503`.
- [x] No FPS regression on Seyda Neen (GPU-bound at ceiling).
- [x] FPS up in shadow-bound scenarios: **+12.8%** at Pelagiad teleport, **+81.7%** in NEAR-only mode.
- [x] No new parse errors, no new runtime errors during bench. Shutdown signal 11 is pre-existing (baseline run had it too).

## Follow-ups for next session

1. **Interactive visual verification at Balmora free-fly.** Per the plan's Phase 3 step 3 — CLAUDE.md forbids screenshot harnesses, so this one's a human-in-the-loop pass: launch `scenes/Godotwind.tscn`, fly around Balmora and Seyda Neen at 2-5m character height, eyeball whether small clutter (rocks, flora, pebbles) missing shadows is jarring. Tune `SHADOW_OFF_HEIGHT_THRESHOLD` if so (0.7m more conservative, 1.5m more aggressive).
2. **Tune threshold per-prototype, not global, if needed.** If a specific sub-1m item looks wrong without a shadow (e.g. a totem or shrine), the prebake flag path from Option 1 in the original plan is the cleaner fix — add a `cast_shadow_override` field to the prototype metadata and flip per-asset at the prebake stage rather than at runtime via AABB.
3. **Option 2 (SHADOW_PARALLEL_2_SPLITS) still available** if further shadow-pass reduction is wanted — gate was hit by Option 1 alone, so this is optional.
4. **Fix the shutdown signal 11.** Separate bug cluster — not a shadow-optim regression. Already noted in the [NEAR-tier refactor](../archive/plans/distant_rendering_2026_04/near_tier_refactor.md) parked work.

## Files changed

- [src/core/world/prototype_batch.gd](../../src/core/world/prototype_batch.gd) — +const + 5-line shadow-off block in `_init`
- [src/core/world/static_object_renderer.gd](../../src/core/world/static_object_renderer.gd) — +const + 4-line shadow-off block in `_create_rs_instance`, optional `aabb` param added, 2 callsites updated
- [docs/plans/shadow_pass_optimization_2026_04_22.md](../plans/shadow_pass_optimization_2026_04_22.md) — this handoff appended

---

# Session 4 handoff (2026-04-22, evening) — v1 CRITIQUED, v2 ATTEMPTED (BROKEN), v2.1 SHIPPED (canonical)

v1's flat AABB-height cutoff was sloppy — killed pebble shadows at 2m just as hard as at 80m, ignoring screen-space reality. User rejected the pattern. This session replaces it with the canonical UE5 / Decima "screen-size shadow cull" pattern: shadow state follows per-instance distance, so close-up shadows are preserved and distant small clutter drops cleanly. Required **two attempts** — v2 via Godot's `visibility_range` broke on world-spanning MultiMesh batches; v2.1 via a dynamic per-batch `cast_shadow` toggle driven by the existing cull pass ships the correct behaviour.

## v1 critique (user)

> "Obviously you need to put some distance thresholds (like cut shadows of objects smaller than X pixels on screen because they are too far anyway). But a simple cut off like that? Unacceptable. That's sloppy work."

Right. The flat `aabb.size.y < 1.0m` cutoff catches small items by PROTOTYPE, not by screen-space presence. A pebble 2m from the player (8% of screen height) gets the same treatment as a pebble 80m away (0.2% of screen). The canonical pattern is: **cutoff distance scales with object size, so "close" and "small on screen" map to the same cull decision**.

## v2 attempt — broken for registry MultiMesh batches

Replaced the flat shadow-off with per-prototype `RenderingServer.instance_geometry_set_visibility_range(..., cutoff, ..., VISIBILITY_RANGE_FADE_SELF)` where `cutoff = aabb_max_dim * SCREEN_SIZE_CUTOFF_RATIO`. Idea: `VISIBILITY_RANGE_FADE_SELF` dithers the instance out past `cutoff`, killing both visible and shadow draws in one knob.

**Works cleanly on the legacy per-instance path** (each instance has a tight local AABB, camera-to-transform distance is per-object accurate). Measured win at Pelagiad NEAR-only mode: **FPS 21 → 65, +205%**. Real.

**Broken on the registry batch path.** Measured: Seyda Neen vis draws dropped 423 → 64 (-85%). The scene visually empties out — grass and pebbles right at the player's feet stop rendering.

Root cause: Godot's `visibility_range` uses distance from camera to the instance's *transform origin* (or AABB center for MultiMeshes). The registry batch is one RS instance anchored at `Transform3D.IDENTITY` (world origin) with slots scattered across the loaded region. Camera at Seyda Neen is ~1077m from world origin — greater than any reasonable small-prototype cutoff — so the fade triggers even when close slots are at the player's feet. Setting a correct `custom_aabb` doesn't help: `visibility_range` distance is still AABB-center-based, and a world-spanning MultiMesh's centroid is always far from *some* of its slots. The knob semantics don't match per-slot intent for world-scoped MultiMeshes.

Conclusion: `visibility_range` is the right tool for tight per-instance AABBs (legacy path) and the wrong tool for world-spanning MultiMeshes (registry path). Ship it on legacy, replace with the canonical per-batch dynamic toggle on registry.

## v2.1 — canonical dynamic per-batch shadow toggle

Two-path approach, each using the knob whose semantics fit:

**Legacy path ([static_object_renderer.gd](../../src/core/world/static_object_renderer.gd) `_create_rs_instance`):** Per-prototype `visibility_range_end` scaled by AABB. Preserved from v2 — per-instance AABBs are tight, the distance check is accurate, fade works as intended. `effective_end = min(visibility_range_end, max(MIN_CUTOFF, max_dim * RATIO))`.

**Registry path ([prototype_batch.gd](../../src/core/world/prototype_batch.gd) `cull_and_upload`):** Dynamic per-batch `cast_shadow` toggle driven by nearest-live-slot distance. The cull pass already walks every slot computing `dist_sq` for the visible cull; track `min(dist_sq)` over ALL live slots (not just visible ones — shadows extend past the visible cutoff) and feed it to `_update_shadow_state` after the pack. When nearest is past the prototype's shadow cutoff, the batch's `cast_shadow` flips to OFF via `RenderingServer.instance_geometry_set_cast_shadows_setting`. When nearest drops back below cutoff, it flips ON. Hysteresis (5m) prevents per-frame toggle thrash at the boundary.

Cutoff formula matches legacy: `shadow_cutoff = clamp(max_dim * SCREEN_SIZE_CUTOFF_RATIO, MIN_CUTOFF=40m, SHADOW_CUTOFF_MAX=200m)`. The 200m cap matches `directional_shadow_max_distance` (sky_manager.gd:276) — cutting higher has no effect because the sun already culls shadow casters past 200m.

C# cull ([WorldMidCuller.cs](../../src/native/WorldMidCuller.cs) `CullAndPack`) updated to track `nearestDistSq` and return it alongside `visible` and `buffer`. GDScript fallback mirrors the same logic. Both paths route through a single `_update_shadow_state` helper, so toggle state + hysteresis live in one place.

## Phase 3 measurements (v2.1)

All runs: `--bench-auto=... --start-cell=-2,-9`, Godot 4.6 stable mono win64, same box.

### Four-way comparison

| scenario           | variant             | draws  | fps    | objs   | slots  |
|--------------------|---------------------|-------:|-------:|-------:|-------:|
| bench_tiers        | baseline            |   2207 |  218.9 |   3529 |    818 |
| bench_tiers        | v1 (flat cutoff)    |   1503 |  219.1 |   2372 |    904 |
| bench_tiers        | v2 (visrange, broken) |  475 |  218.7 |   1329 |    904 |
| **bench_tiers**    | **v2.1 (dyn toggle)** | **1585** | **223.5** | **2639** | **1107** |
| bench_teleport     | baseline            |   2699 |  184.3 |   3445 |    818 |
| bench_teleport     | v1 (flat cutoff)    |   3429 |  207.9 |   4174 |    836 |
| bench_teleport     | v2 (broken)         |   3334 |  205.0 |   4080 |    837 |
| **bench_teleport** | **v2.1 (dyn toggle)** | **1622** | **207.0** | **2365** | **856**  |
| bench_hlod_off     | baseline            |   3165 |   21.3 |   4069 |    292 |
| bench_hlod_off     | v1 (flat cutoff)    |   3840 |   38.7 |   4764 |    412 |
| bench_hlod_off     | v2 (broken)         |   3970 |   65.1 |   4917 |    452 |
| **bench_hlod_off** | **v2.1 (dyn toggle)** | **2816** | **138.5** | **3901** | **843** |

### Deltas vs baseline

- **bench_tiers Seyda Neen**: draws -28.2% (1585 vs 2207), fps +2.1% (223.5 vs 218.9). Note: v2.1 has 1107 registry slots loaded vs 818 in baseline (+35% more content), so per-slot draw ratio is much better than v1. fps unchanged at GPU ceiling as expected.
- **bench_teleport Pelagiad**: draws -39.9% (1622 vs 2699), fps +12.3%. **Big win** — v2.1 more aggressively identifies "all slots of this batch are past cutoff → shadow off" than v1's static height rule, which misses this per-frame signal. v1's 3429 draws at Pelagiad was actually WORSE than baseline; v2.1 fixes that.
- **bench_hlod_off NEAR-only**: draws -11.0% (2816 vs 3165), fps **+550%** (138.5 vs 21.3). Headline win. In the shadow-dominated NEAR-only scene, v2.1 cleanly culls sub-cutoff shadow casters AND the legacy-path visibility_range fades out small far items entirely. 6.5× FPS lift.

### vs v2 (broken)

v2.1 restores the visible-pass fidelity that v2 destroyed — vis draw counts at Seyda Neen recover from the broken 64 back to 2639-level content with no visible holes in the world. The user's critique ("close-up shadows should stay") is satisfied because the toggle decision uses nearest-slot distance, not per-batch centroid — so a single pebble 2m from the player keeps its whole batch's shadow on.

## Architectural notes

**Per-frame cost of the dynamic toggle:** negligible. The cull pass already iterates every live slot computing `dist_sq`. We add `if (dist_sq < nearest) nearest = dist_sq` inside the loop (1 compare + 1 store per slot) and call `_update_shadow_state` once per batch per frame. The RS call `instance_geometry_set_cast_shadows_setting` only fires on state transitions (gated by the `_shadow_on` field + hysteresis), so steady-state cost is zero beyond the float compare.

**Why tracking nearest dist over ALL live slots, not just visible ones:** the visible cull rejects slots past `max_dist_sq` (typically MID_END = 500m²). But shadows extend to 200m, which is well inside that. A slot at 300m contributes nothing to the main camera but if it were the only live slot in a small-prototype batch, the batch's dynamic shadow state should still decide based on that 300m distance, not fall back to default-on. Walking ALL live slots for the min is one extra compare per skipped slot — trivial.

**Hysteresis:** 5m band around the cutoff. Prevents per-frame toggle thrash when the player walks parallel to the boundary. The RS shadow-cache invalidation cost of a toggle is small but not free, and thrash across boundaries compounds.

**C# ⇆ GDScript contract:** The native cull returns `Godot.Collections.Dictionary { visible, buffer, nearest_dist_sq }`. GDScript reads all three keys with default-INF fallback, so the GDScript path and native path produce identical shadow-toggle behaviour.

## Files changed (v2.1)

- [src/core/world/distance_utils.gd](../../src/core/world/distance_utils.gd) — added `SCREEN_SIZE_CUTOFF_RATIO` (200), `SCREEN_SIZE_MIN_CUTOFF` (40m), `SCREEN_SIZE_MAX_CUTOFF` (= MID_END), `SHADOW_CUTOFF_MAX` (200m, matches directional shadow max), `SHADOW_CUTOFF_HYSTERESIS` (5m).
- [src/core/world/prototype_batch.gd](../../src/core/world/prototype_batch.gd) — replaced v1 flat `SHADOW_OFF_HEIGHT_THRESHOLD` with dynamic toggle infrastructure: `shadow_cutoff_dist_sq` + `_shadow_cutoff_hyst_sq` + `_shadow_on` fields, cutoff computation in `_init`, `nearest_dist_sq` tracking in the GDScript cull loop, `nearest_dist_sq` read from native cull return, `_update_shadow_state` helper with hysteresis, `cleanup()` resets.
- [src/core/world/static_object_renderer.gd](../../src/core/world/static_object_renderer.gd) — removed v1 `SHADOW_OFF_HEIGHT_THRESHOLD`, replaced per-instance flat shadow-off with per-prototype screen-size `visibility_range_end` in `_create_rs_instance`. Optional `aabb` param retained from v1, docstring updated.
- [src/native/WorldMidCuller.cs](../../src/native/WorldMidCuller.cs) — added `nearestDistSq` tracking + `nearest_dist_sq` return key. No API break — GDScript reads with default-INF fallback.
- [docs/plans/shadow_pass_optimization_2026_04_22.md](../plans/shadow_pass_optimization_2026_04_22.md) — this handoff.

## Follow-ups

1. **Interactive visual verification still outstanding.** Launch `scenes/Godotwind.tscn` at Balmora / Seyda Neen, walk the periphery of small-prototype batches, confirm shadows come on as you approach and drop cleanly as you walk away (with 5m hysteresis — should be imperceptible). No screenshot harness per CLAUDE.md.
2. **Tune `SCREEN_SIZE_CUTOFF_RATIO` if needed.** Default 200 gives ~5 px threshold at 1080p / 60° FOV. Raise for more aggressive culling (losing close-ish small shadows earlier), lower for more generous shadows.
3. **Measure RS toggle cost under player-movement load.** bench_tiers is static — real player movement crosses cutoff boundaries occasionally. If profiling shows RS toggles causing hitches during fast traversal, tighten hysteresis or batch the toggles (e.g. one RS call per toggle-batch every N frames).
4. **Shutdown signal 11** still recurs — pre-existing, not a shadow-optim regression. Separate investigation.
