# Wetness System — Complete Plan (Submersion + Rain + Memory)

**Status:** Plan draft — awaiting `@roaster` review pass.
**Author:** `@moist` (2026-04-14).
**Review scope:** architecture + phasing. Implementation review happens after first draft lands.

---

## 1. Goals & Scope

Deliver a unified wetness system that visually wets **all rendered surfaces** in the Godotwind main scene (`scenes/Godotwind.tscn`) under two driving signals:

- **Submersion** — any pixel whose reconstructed world-space `y < sea_level + wet_margin` appears wet.
- **Rain** — any surface exposed to the sky (sky-occlusion proxy + normal.y bias) accumulates wetness when it's raining; dries when protected.

Plus per-object **memory** for carry items and characters: once dunked / rained on, surfaces *stay wet* for ~5–15 s before drying, matching AAA standard behavior (Crimson Desert, Horizon FW, RDR2, MGSV).

Out of scope for this plan (but on the roadmap in §12 Phased Rollout):
- Puddle accumulation over long rain durations (world-space 2D accumulation buffer).
- Per-ref rain splash decals.
- Dynamic water run-off / rivulet shaders.

---

## 2. Canonical Formula — Lagarde Practical Approximation

All three rendering paths (compositor / per-material / terrain) compute wetness via the same formula, copied verbatim from Seb Lagarde's *Water drop 3b — Physically based wet surfaces* (2013), which is the AAA industry standard (shipped in Stalker, Uncharted 2/3, AC3, Crysis 2/3, MGSV, Killzone: Shadow Fall, and — per public breakdowns — Crimson Desert 2025).

```glsl
// Inputs:
//   diffuse    — pre-lighting albedo
//   gloss      — 1.0 - roughness, the material's glossiness
//   wet_level  — 0..1, the wetness mask (from §4)
//   porosity   — 0..1, how absorbent (from §7)
//
// Outputs: modified diffuse + gloss.

float factor = mix(1.0, 0.2, porosity);         // 0.2 = max darken, from Lagarde's material db
diffuse *= mix(1.0, factor, wet_level);
gloss   = mix(1.0, gloss, mix(1.0, factor, 0.5 * wet_level));

// Metals skip the effect:
if (metalness > 0.5) { diffuse_out = diffuse_in; gloss_out = gloss_in; }
```

Constants (locked as project-wide uniforms, pushed by the driver in §8):

| Uniform | Default | Purpose |
|---|---|---|
| `wet_albedo_darken` | 0.6 | Caps darkening at 60% for max wet + max porosity |
| `wet_roughness_target` | 0.05 | Water surface target gloss (near-mirror) |
| `wet_margin` | 0.3 m | Capillary rise above `wet_line_y` |
| `wet_dry_rate` | 0.1 / s | Memory-decay rate (fully wet → dry in ~10 s) |
| `sea_level` | from `OceanManager` / `ProjectSettings("ocean/sea_level")` | Water plane Y |

---

## 3. System Architecture

Three rendering paths driven by one authority, with a single shared formula.

```
                ┌──────────────────────────────────┐
                │       WetnessManager             │
                │       (autoload, §8)             │
                │                                  │
                │  - sea_level                     │
                │  - rain_intensity (0..1)         │
                │  - rain_accumulation (s)         │
                │  - wet_margin / darken / target  │
                │                                  │
                │  per frame:                      │
                │    push_global_uniforms()        │
                │    → all registered RIDs         │
                └────┬─────────────────────┬───────┘
                     │                     │
          ┌──────────▼──────┐   ┌──────────▼─────────────────┐
          │ CompositorEffect │   │ per-material shaders       │
          │ (§3.A, world)    │   │                            │
          │                  │   │  object_wet.gdshader       │
          │ compute pass     │   │   - carry items (§3.B)     │
          │ depth + nr tex   │   │   - character meshes (§3.C)│
          │ → Lagarde        │   │                            │
          │                  │   │  terrain_horizon.gdshader  │
          │ covers: terrain  │   │   - Terrain3D override     │
          │ walls, buildings,│   │                            │
          │ flora, NPCs,     │   │  (§3.D)                    │
          │ any rendered geo │   │                            │
          └──────────────────┘   └────────────────────────────┘
```

### 3.A. Screen-space CompositorEffect (primary world path)

**File:** `src/core/shaders/effects/wet_compositor_effect.gd` (extends `PostProcessEffect`)
**Shader:** `src/core/shaders/compute/wet_compositor.glsl`
**Pattern:** mirrors `underwater_compositor_effect.gd`, which already uses `PostProcessEffect` + compute shader + depth / matrix buffers. Same plumbing, different math.

Samples `DEPTH_TEXTURE` + `NORMAL_ROUGHNESS_TEXTURE` (both exposed via `access_resolved_depth = true` + `needs_normal_roughness = true` on the compositor effect). Reconstructs world position from depth using the inv-projection / inv-view buffer (same pattern as underwater effect). Computes `wet_level` from §4, applies §2 Lagarde, writes back to resolved color.

**Coverage:** every on-screen pixel that wrote depth — terrain, walls, rocks, buildings, flora, NPCs, even carry items (but see §6 for reconciliation with per-material path on carry/character memory).

**What it CANNOT do:** per-object memory (no per-pixel object ID in the GBuffer). That's delegated to §3.B / §3.C.

### 3.B. Per-material `object_wet.gdshader` — carry items

Already exists at `src/core/shaders/object_wet.gdshader`. Used by `tests/visual/test_wet_map.gd` to validate the per-object `wet_line_y` pattern.

**Integration point:** `src/core/interaction/carry_controller.gd::_do_grab()` — on successful grab, swap the held body's `MeshInstance3D.material_override` to a `ShaderMaterial` carrying this shader. Preserve the original material's `albedo_color` / `roughness` / `metallic` / `albedo_texture` by extracting from the `StandardMaterial3D` and copying into the shader's uniforms (one-time cost on grab).

On release (`_do_release`), restore the original `material_override` (saved in `_saved_material_override` alongside mask/gravity/damp).

**Rationale:** only ~1 object at a time is carried. Zero perf concern. Preserves wet memory after drop (see §6).

### 3.C. Per-material `object_wet.gdshader` — characters

**Integration points:**
- `src/core/character/humanoid/humanoid_equipment.gd` — when equipping clothing meshes, set `material_override` to `object_wet` (same injection pattern as §3.B).
- Body part factory (to find via Glob: `src/core/character/humanoid/*.gd`) — inject on body-part mesh creation.

**Cost:** ~10–30 meshes per visible NPC × up to 8 NPCs in view (estimate) = ~240 shader-material instances peak. Compare to current ~3,000+ deduped static materials. Acceptable — characters are a small fraction of total draws.

**Per-character wet state:** tracked in GDScript, one `wet_line_y_local` per character root (not per-mesh). `WetnessManager.register_memory_holder(character_root, bottom_y)` registers the character; WetnessManager drives each registered holder's wet_line_y every frame via RS push.

### 3.D. Terrain — `terrain_horizon.gdshader` (already shipped)

Kept as-is. `HorizonMapManager` already applies it as Terrain3D's shader override and pushes `sea_level_wet`, `wet_margin`, `wet_albedo_darken`, `wet_roughness_target`. Current one-shot push at init (`world_explorer.gd:395`) becomes per-frame under the new driver in §8, so the terrain tracks sea-level changes + rain accumulation in v2.

Terrain itself doesn't participate in rain-exposure wetness differently from walls — it's mostly flat and horizontal, so its normal.y is already ≈1, always getting full rain exposure. No special handling needed.

---

## 4. Wet-Level Composition

Per-fragment wet mask combines submersion and rain contributions.

```glsl
// Submersion: below water = fully wet, smoothed over `wet_margin` above the line.
float submersion = smoothstep(sea_level + wet_margin, sea_level, world_y);

// Rain exposure (§5): surfaces facing up + under open sky get wet over time.
float rain_contrib = rain_intensity * sky_exposure * saturate(rain_accumulation / rain_saturation_time);

// Combined: OR-like max so submersion always wins if fully submerged.
float wet_level = max(submersion, rain_contrib);
```

Per-material "memory" shaders also blend in their local `wet_line_y` (world-space decay tracker) — see §6.

---

## 5. Rain-Path Exposure Mask (roaster #1)

Rain doesn't uniformly wet everything — only surfaces *visible to the sky* and *facing upward* collect water. Crimson Desert's "realistic per-surface" wetness = this exposure mask.

**Sky-visibility proxy:** ambient-occlusion inverse.
- Forward+ pipeline: Godot exposes `AO` in `NORMAL_ROUGHNESS_TEXTURE`'s alpha channel when SSAO is on. Sample and invert.
- Fallback when SSAO off: sky-visibility cubemap baked per-cell (future; not in v1). For v1 rain, assume full sky exposure if SSAO disabled — acceptable approximation.

**Upward-facing bias:** sample the world-space normal.
```glsl
vec3 normal_world = decode_normal(texture(NORMAL_ROUGHNESS_TEXTURE, uv).rg);
float up_bias = saturate(normal_world.y * 0.5 + 0.5);  // 0 down, 0.5 horizontal, 1 up
```

**Combined exposure:**
```glsl
float ao = texture(NORMAL_ROUGHNESS_TEXTURE, uv).a;     // 0=occluded, 1=open sky
float sky_exposure = ao * smoothstep(0.2, 1.0, up_bias);
```

`up_bias` cutoff at 0.2 prevents down-facing surfaces (undersides of overhangs, lower faces of rocks) from ever rain-wetting even with bad AO.

**Rain accumulation time-integration:** `WetnessManager` tracks `rain_accumulation_seconds` as a global scalar that advances while `rain_intensity > 0` and decays while `rain_intensity == 0`. `rain_saturation_time` (default 15 s) caps contribution — after 15 s of steady rain, exposed surfaces are fully wet.

**Per-material memory holders (§6):** carry items + characters ALSO accumulate rain_contribution via a per-object scalar in GDScript. When held under open sky in rain, their `wet_line_y_local` rises toward the high-water line of the mesh; decays when sheltered/dry. Decay rate respects `wet_dry_rate` constant.

---

## 6. Memory-Holder ↔ Compositor Reconciliation (roaster #2)

The problem: if a carry item is submerged, BOTH the compositor (§3.A) and the per-material shader (§3.B) apply Lagarde darkening to the same pixel → double-application → artifact-dark submerged held item.

**Decision: stencil-mask carve-out.** The compositor effect SKIPS pixels owned by a memory-holder mesh.

**Implementation:**
1. `MeshInstance3D.set_layer_mask_value(layer_bit, true)` is not sufficient — Godot's forward+ doesn't expose a render-layer mask to compositor shaders.
2. Instead: memory-holder meshes render with a distinct `stencil_value`. Godot 4.6 supports stencil buffer via `rendering/driver/stencil` → but custom stencil values on spatial shaders require writing to the stencil during the main pass.
3. **Chosen pattern:** `object_wet.gdshader` writes a marker value to `RENDER_TARGET` alpha channel's lowest bit (or a dedicated custom buffer if the stencil path isn't viable). The compositor samples the marker and skips Lagarde application where marker == 1.

**Alternative evaluated + rejected:** depth-compare carve-out. Would need to bake a "memory-holder depth buffer" and compare against main depth. Two extra depth passes; doubles memory-holder render cost. Not worth vs. the alpha-bit approach.

**Alternative evaluated + rejected:** just accept the double-application. Measured estimate: `factor = 0.2` (max) → compositor applies `diffuse *= 0.2`, per-material applies `diffuse *= 0.2` again → final `diffuse *= 0.04`. That's 25× too dark. Not acceptable visually.

**Open question for @roaster:** Godot 4.6 stencil support in forward+ is viable per `rendering/driver/stencil` project setting, but our rendering path is not currently using stencil for anything else. The alpha-LSB marker is simpler, but loses 1 bit of alpha precision on held items (invisible in practice — alpha on opaque meshes is unused). Pick one before §12 phase 2 work begins.

---

## 7. Porosity Source (roaster #3)

AAA games use one of three porosity strategies; we pick per path:

| Path | Porosity source | Justification |
|---|---|---|
| **Terrain (3.D)** | Derived: `saturate(-2.5 * gloss + 1.25)` | Terrain has uniform ground material; no artist-authored porosity channel exists. Roughness-derived is the Lagarde fallback for exactly this case. |
| **Compositor (3.A) — world geo** | Derived from sampled roughness | Same reasoning — 3,000+ deduped static materials cannot carry a new texture channel without a full rebake pipeline. Roughness-derived is the canonical fallback. |
| **Per-material (3.B, 3.C) — carry items + characters** | Derived from material's `roughness` uniform, set once at shader injection | Consistent with other paths. If we want per-clothing-material porosity (leather vs metal), that's a future texture-channel addition — OUT OF SCOPE for v1. |

**Metal exclusion:** all three paths check `metallic > 0.5` and skip. Derived from material's metallic uniform (per-material) or sampled from `NORMAL_ROUGHNESS_TEXTURE` alpha if Godot packs metalness there (compositor) — **open question:** verify which buffer Godot 4.6 forward+ writes metalness to. If none: approximate via `specular > 0.7` from the spec buffer if available, else skip metal exclusion in the compositor and accept metal helmets darkening slightly. Low visual cost.

---

## 8. Driver Ownership — `WetnessManager` Autoload (roaster #4)

**Decision: new `WetnessManager` autoload, NOT extension of `HorizonMapManager`.**

**Trade-off analysis:**

| Option | Pros | Cons |
|---|---|---|
| Extend `HorizonMapManager` | One less autoload; already tied to terrain | Name mismatch — it's already mis-scoped to terrain + "horizon" (shadow baking). Piling wetness + rain into it violates single-responsibility. |
| New `WetnessManager` autoload | Single purpose; clear API; can own rain state, exposure params, memory-holder registry; future weather system hook | One more autoload. Godotwind already has 6 (`Log`, `SettingsManager`, `BSAManager`, `ESMManager`, `OceanManager`, `ShaderManager`) — +1 is fine per CLAUDE.md's limit vibe (it's a soft guideline). |

Chose the new autoload. `HorizonMapManager` keeps its existing terrain-shader-override narrow scope; `WetnessManager` drives the global state pushed to ALL three paths (terrain, compositor, per-material shaders).

**`WetnessManager` API:**
```gdscript
# Global state
var sea_level: float
var rain_intensity: float           # 0..1, set by weather/sky system (future)
var rain_accumulation: float        # seconds; integrated in _process
var wet_margin: float = 0.3
var wet_albedo_darken: float = 0.6
var wet_roughness_target: float = 0.05
var rain_saturation_time: float = 15.0

# Registration
func register_material(mat_rid: RID) -> void        # compositor + terrain + per-material shaders all register their RID
func unregister_material(mat_rid: RID) -> void
func register_memory_holder(node: Node3D, mesh_bottom_local_y: float) -> void
func unregister_memory_holder(node: Node3D) -> void

# Per-frame (called automatically in _process)
func _push_global_uniforms() -> void
func _update_memory_holders(delta: float) -> void   # decays each holder's wet_line_y + accumulates rain_contrib
```

Integration:
- `world_explorer.gd::_setup_cameras()` → `WetnessManager.register_material(compositor.material_rid)` after compositor creation.
- `HorizonMapManager.initialize()` → `WetnessManager.register_material(terrain_material_rid)`.
- `CarryController._do_grab()` → `WetnessManager.register_memory_holder(held_body, bottom_y)`.
- `CarryController._do_release()` → `WetnessManager.unregister_memory_holder(held_body)`.
- `HumanoidEquipment.create_character()` → `WetnessManager.register_memory_holder(character_root, -1.0)`.

---

## 9. CompositorEffect Stage Placement + Perf Budget (roaster #5)

**Stage placement: `EFFECT_CALLBACK_TYPE_POST_TRANSPARENT`, PRE-tonemap.**

- `POST_OPAQUE` runs before transparents render — would miss wetting glass/water/alpha-blended flora. Rejected.
- `POST_TRANSPARENT` runs after all 3D geometry (opaque + transparent) but BEFORE tonemap / bloom / SSAO finalize. This is the same slot `underwater_compositor_effect.gd` uses. ACCEPTED.
- Post-tonemap would require operating on final sRGB colors — Lagarde math is designed for linear-space albedo, so we want pre-tonemap. ACCEPTED.

**Render priority:** between `godrays` (11) and `underwater` (12) — let's use **`render_priority = 9`** (before underwater, so when the camera dunks, wet compositor runs first and THEN underwater adds its color. Order matters because underwater's absorption+caustics should apply to the already-wet-tinted scene). Verify with `@roaster` during review.

**Perf budget estimate (1440p forward+, Seyda Neen baseline):**

- Compute shader dispatches: 1 pass, workgroup size 16×16, total (2560/16) × (1440/16) = 14,400 workgroups.
- Per-pixel cost: 2 texture fetches (depth + normal_roughness), ~20 ALU ops (matrix reconstruct + Lagarde).
- Target hardware: mid-range desktop GPU (RTX 3060-class per `docs/audit/MASTERPLAN.md` baselines).
- **Estimate: 0.15–0.25 ms at 1440p.** For comparison: `underwater_compositor_effect.gd` measures ~0.4 ms with caustics + wobble + rays. Wet is strictly simpler (no caustic texture sample, no screen wobble uv warping, no ray-march loop), so ~50% of underwater's cost is a fair estimate.
- **Measurement plan:** after Phase 1 (§12) lands, use Godot's frame profiler + RenderDoc on the visual test scene to confirm within 0.3 ms budget. If over budget: drop work-group size to 8×8 or skip pixels where depth > compositor_far_cutoff (e.g. no wet beyond 500 m, where sea-level info is meaningless anyway).

---

## 10. File-Level Breakdown

**New files:**
- `src/core/water/wetness_manager.gd` — autoload, driver + memory-holder registry.
- `src/core/shaders/effects/wet_compositor_effect.gd` — extends `PostProcessEffect`, mirrors `underwater_compositor_effect.gd`.
- `src/core/shaders/compute/wet_compositor.glsl` — compute shader, samples depth + normal_roughness, applies Lagarde.
- `tests/visual/test_wet_compositor.tscn` + `.gd` — isolated scene that loads a cell, raises + lowers sea level, toggles rain on/off, validates compositor darkening visually.
- `tests/visual/test_wet_memory.tscn` + `.gd` — isolated scene that spawns carry items + a character, dunks them, times decay to verify `wet_dry_rate` curve.

**Modified files:**
- `project.godot` — add `WetnessManager` to `[autoload]`, register compositor effect path.
- `src/tools/world_explorer.gd` — remove the one-shot `_horizon_map_manager.push_wet_map()` call (replaced by WetnessManager's per-frame push); register terrain material with WetnessManager at init; attach compositor effect to the main camera's compositor stack via `ShaderManager`.
- `src/core/world/horizon_map_manager.gd` — delete local uniform-push path (WetnessManager takes over); keep shader-override apply logic only.
- `src/core/interaction/carry_controller.gd` — `_do_grab`: save original material_override, inject object_wet as override, extract albedo/roughness from original StandardMaterial3D + push to shader; register with WetnessManager. `_do_release`: restore original override, unregister.
- `src/core/character/humanoid/humanoid_equipment.gd` — same injection pattern for clothing meshes; register character with WetnessManager on creation.
- `src/core/character/humanoid/<body part factory>.gd` — same injection pattern for body part meshes (exact file TBD during implementation; locate via Glob).
- `src/core/shaders/object_wet.gdshader` — add `rain_level` uniform + the per-material Lagarde formula (currently has darken+gloss tweak but doesn't use the rain contribution); write the alpha-LSB stencil marker per §6.

---

## 11. Test Coverage (roaster #6)

Three visual test scenes, one per rendering path, plus an integration scene.

### 11.A. `tests/visual/test_wet_compositor.tscn`
- Loads a small flat environment (terrain + a few prefab walls + rocks).
- Slider: `sea_level` (−5 m to +5 m).
- Slider: `rain_intensity` (0 to 1).
- Toggle: `debug_show_mask` (false = rendered, true = visualize wet_level as red overlay).
- **Acceptance:** raising sea level visibly darkens submerged surfaces; lowering restores. Toggling rain intensity ramps exposed-face darkening over `rain_saturation_time`. Debug mask matches the formula in §4.

### 11.B. `tests/visual/test_wet_memory.tscn`
- Reuses + extends existing `tests/visual/test_wet_map.gd` infrastructure.
- Spawns 3 draggable carry items + 1 humanoid character.
- Slider: `sea_level`.
- Command: "dunk for 2 seconds" — auto-lifts the item, lowers sea level to cover it, waits 2 s, raises sea level back.
- **Acceptance:** dunked item's `wet_line_y` holds at top of mesh; decays linearly over `wet_dry_rate` (10 s default); dry at t = 10 s ± 0.5 s. HUD shows per-object wet_line + decay timer.

### 11.C. `tests/visual/test_wet_terrain.tscn`
- Existing `test_wet_map.tscn` — already validates terrain path. Keep + ensure it still passes after the WetnessManager refactor.
- Add: `rain_intensity` slider to verify terrain reacts to rain accumulation in addition to sea level.

### 11.D. Rain decay curve (unit test)
- `tests/unit/test_wetness_manager.gd` — pure-logic test, no rendering.
- Simulates 15 s of steady rain → checks `rain_accumulation` reaches `rain_saturation_time`.
- Simulates 10 s dry → checks `rain_accumulation` decays to 0.
- Simulates memory-holder registered with wet_line_y at 1.0, ticks 10 s of dry → checks `wet_line_y` decayed to 0 ± tolerance.

### 11.E. Integration test — main scene
- Manual (not automated — per CLAUDE.md "no auto-capture"): user launches Godotwind.tscn, flies to coast near Seyda Neen, observes terrain wetting at sea level and rocks wetting below the shoreline. Rain test deferred until weather system lands.

---

## 12. Phased Rollout

**Phase 1 — Submersion foundation (this ticket)**
1. Write `WetnessManager` autoload with sea_level + wet params only (no rain yet).
2. Write `wet_compositor_effect.gd` + `.glsl` — submersion-only wet.
3. Refactor `world_explorer.gd` + `HorizonMapManager` to use WetnessManager as driver.
4. Integrate `object_wet.gdshader` into CarryController.
5. Integrate into HumanoidEquipment + body parts.
6. Ship `test_wet_compositor.tscn` + `test_wet_memory.tscn` + unit tests.
7. Visual verification via main scene (manual, user-driven — per feedback_never_launch_main_game_unprompted).

**Phase 2 — Rain path**
1. Add `rain_intensity` + `rain_accumulation` to WetnessManager + weather-system stub (future hook).
2. Extend wet_compositor.glsl with exposure mask (normal.y + AO).
3. Extend object_wet.gdshader with rain contribution.
4. Extend memory-holder update loop to accumulate rain when under open sky.
5. Update test scenes with rain sliders.
6. Add rain decay unit tests.

**Phase 3 — Puddle accumulation (stretch, post-rain-system)**
1. World-space 2D accumulation buffer (RGB16 texture, one texel per ~1 m).
2. Rain adds to buffer over time; sun / heat subtracts.
3. Compositor samples buffer via world-pos → uv mapping.
4. Out of scope for v1 + v2.

**Phase 4 — Per-material porosity textures (stretch)**
1. Artist-authored porosity channel in a spare texture slot.
2. Update Lagarde formula to sample porosity instead of deriving from roughness.
3. Deferred until the prebaking pipeline is revised to support additional channels.

---

## 13. Risks & Open Questions

| # | Risk / Question | Mitigation / Decision Point |
|---|---|---|
| 1 | Godot 4.6 stencil buffer support in forward+ — may not cover the §6 carve-out cleanly | Fallback: alpha-LSB marker (already specified as Plan A). Decide during Phase 1 prototype. |
| 2 | `NORMAL_ROUGHNESS_TEXTURE` alpha channel may not carry AO on all hardware / pipeline configs | Feature-detect at init: if AO unavailable, treat `sky_exposure = 1.0` — full rain on all up-facing surfaces. Acceptable degradation. |
| 3 | Memory-holder double-application if §6 carve-out fails | Test in Phase 1 with carve-out DISABLED first; measure visual severity. If tolerable, defer stencil work to Phase 2. |
| 4 | `object_wet.gdshader` currently does not match `StandardMaterial3D` lighting exactly (spec / sheen / anisotropy not ported) | Restrict per-material path to materials that ONLY use albedo + roughness + metallic. Characters/carry meet this. If a specific clothing mesh needs anisotropy, use next_pass overlay pattern instead of material_override. Case-by-case. |
| 5 | Perf on low-end hardware (Steam Deck class) | Phase 1 ships with `ProjectSettings("wetness/enabled")` bool. Disabled → compositor effect removed from stack, WetnessManager still runs but only pushes to terrain. Cost goes to near-zero. |
| 6 | Reviewer checklist compliance | This doc structured around `@roaster`'s 6 points; each point's section header flags its mapping. |

---

## 14. Reviewer Checklist Mapping (@roaster)

| Roaster point | Covered in |
|---|---|
| (1) Rain exposure mask spec | §5 |
| (2) Memory-holder / compositor reconciliation | §6 |
| (3) Porosity source per subset of materials | §7 |
| (4) Driver ownership trade-off | §8 |
| (5) CompositorEffect stage + perf budget | §9 |
| (6) Test scene coverage for all 3 paths + rain decay | §11 |

Plus user requirement "prepare for rain now": §5 rain-path spec + §12 Phase 2 roadmap.

---

## 15. Next Steps

1. `@roaster` reviews this plan (one pass).
2. On approval → I (`@moist`) implement Phase 1, starting with `WetnessManager` autoload + compositor effect scaffold.
3. Phase 1 implementation review (one pass) — not before implementation draft is complete.
4. Phase 2 (rain) opened as a separate ticket, same plan-review-implement-review loop.
