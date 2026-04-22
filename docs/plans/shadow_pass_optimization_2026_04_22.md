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
