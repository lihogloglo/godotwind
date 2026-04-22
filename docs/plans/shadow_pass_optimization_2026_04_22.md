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
