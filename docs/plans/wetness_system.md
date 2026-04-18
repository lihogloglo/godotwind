# Wetness System — Canonical Plan (Submersion + Rain + Memory)

**Status:** Post-review canonical plan. Cleared for Phase 1 implementation.
**Authors:** `@moist` (original draft 2026-04-14) · `@roaster` (review + correction pass 2026-04-14, this revision).
**Review history:** Draft rejected 2026-04-14 21:14 for three critical technical errors (NORMAL_ROUGHNESS_TEXTURE alpha semantics, missing `normal_roughness_compatibility()` requirement, alpha-LSB stencil marker inferior to native stencil) plus four moderate issues. This document folds the corrections in. The plan now represents the baseline for any session touching wetness.

**Industry pattern basis:** Sébastien Lagarde — *Water drop 3a & 3b — Physically based wet surfaces* (2013). Shipped in Stalker, Uncharted 2–4, Assassin's Creed 3, Crysis 2/3, MGSV, Killzone: Shadow Fall, Horizon FW, RDR2 (variant), Crimson Desert 2025 (modern variant with exposure mask). This is the standard; we are not re-deriving it.

---

## 1. Goals & Scope

Unified wetness for all rendered surfaces under two driving signals:

- **Submersion** — any fragment whose reconstructed world-space `y < sea_level + wet_margin` appears wet.
- **Rain** — any surface exposed to the sky (upward-bias + sky visibility) accumulates wetness while raining; dries when sheltered.

Plus **memory** for carry items and characters: once dunked or rained on, surfaces stay wet for `~wet_dry_rate⁻¹` seconds before drying. Matches AAA standard behaviour.

**Out of scope v1:**
- Puddle accumulation (world-space 2D buffer) — Phase 3.
- Per-ref rain splash decals — Phase 3.
- Dynamic run-off / rivulet shaders — Phase 3.
- Per-material porosity textures — Phase 4.

---

## 2. Canonical Formula — Lagarde Practical Approximation

All three rendering paths (compositor / per-material / terrain) share one formula, copied from Lagarde part 3b.

```glsl
// Inputs:
//   diffuse   — pre-lighting albedo (linear)
//   gloss     — 1.0 - roughness
//   wet_level — 0..1 wetness mask (§4)
//   porosity  — 0..1 absorbency (§7)
//   metalness — 0..1; metals skip the effect
// Uniforms from WetnessManager (§8):
//   wet_albedo_darken, wet_roughness_target

float factor = mix(1.0, 1.0 - wet_albedo_darken, porosity);
diffuse *= mix(1.0, factor, wet_level);
gloss   = mix(1.0, max(gloss, 1.0 - wet_roughness_target),
                   mix(1.0, factor, 0.5 * wet_level));

if (metalness > 0.5) {
    // Metals: skip diffuse darkening, keep original gloss
    diffuse_out = diffuse_in;
    gloss_out   = gloss_in;
}
```

**Uniform constants (all owned by `WetnessManager`, pushed per frame via RS):**

| Uniform | Default | Purpose |
|---|---|---|
| `wet_albedo_darken` | 0.6 | Max albedo attenuation at full wet + full porosity (`factor_min = 0.4`) |
| `wet_roughness_target` | 0.05 | Gloss target for fully wet surfaces (near-mirror) |
| `wet_margin` | 0.3 m | Capillary rise above `sea_level` |
| `wet_dry_rate` | 0.1 / s | Memory decay (fully wet → dry in 10 s) |
| `rain_saturation_time` | 15.0 s | Time to reach full rain wet on exposed surface |
| `sea_level` | `OceanManager` or `ProjectSettings("ocean/sea_level")` | Water plane Y |
| `rain_intensity` | 0.0 (0..1) | Driven by weather system (future) |

**Roaster correction:** moist's draft declared `wet_albedo_darken = 0.6` in the table but hardcoded `mix(1.0, 0.2, porosity)` in the formula — 3× discrepancy. Resolved: literal removed, formula reads `mix(1.0, 1.0 - wet_albedo_darken, porosity)` so art-direction controls the target.

---

## 3. Architecture Overview

Three rendering paths, one driver, one shared formula.

```
                 ┌──────────────────────────────────┐
                 │       WetnessManager             │
                 │       (autoload, §8)             │
                 │                                  │
                 │  Global state:                   │
                 │    sea_level, wet_margin,        │
                 │    wet_albedo_darken,            │
                 │    wet_roughness_target,         │
                 │    rain_intensity,               │
                 │    rain_accumulation (s)         │
                 │                                  │
                 │  Per-frame:                      │
                 │    _push_global_uniforms()       │
                 │    _update_memory_holders(dt)    │
                 └──┬──────────────────┬────────────┘
                    │                  │
    ┌───────────────▼──────┐   ┌───────▼──────────────────────┐
    │ CompositorEffect     │   │ per-material shaders         │
    │ (§3.A)               │   │                              │
    │ screen-space,        │   │  object_wet.gdshader         │
    │ compute pass,        │   │    - carry items (§3.B)      │
    │ samples depth +      │   │    - character meshes (§3.C) │
    │ normal_roughness,    │   │                              │
    │ reconstructs world   │   │  terrain_horizon.gdshader    │
    │ pos, applies Lagarde.│   │    - Terrain3D override      │
    │                      │   │      (§3.D, already shipped) │
    │ Covers: terrain,     │   │                              │
    │ walls, buildings,    │   │  Carve-out: stencil bit 0x1  │
    │ rocks, flora, NPCs,  │   │  written by memory holders   │
    │ any rendered geo.    │   │  skips compositor path (§6). │
    └──────────────────────┘   └──────────────────────────────┘
```

---

## 3.A. Screen-Space CompositorEffect — primary world path

**New file:** `src/core/shaders/effects/wet_compositor_effect.gd` (extends `PostProcessEffect`).
**New file:** `src/core/shaders/compute/wet_compositor.glsl` (compute shader).
**Pattern reference:** `src/core/shaders/effects/underwater_compositor_effect.gd` — same plumbing (depth + normal_roughness access, world-pos reconstruction, POST_TRANSPARENT stage, render_priority), different math.

### Access flags

```gdscript
access_resolved_color = true
access_resolved_depth = true
needs_normal_roughness = true
effect_callback_type  = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
render_priority       = 9   # runs before godrays (11) and underwater (12)
```

### Buffer semantics (corrected)

**Roaster correction #1 — moist's draft was wrong about `NORMAL_ROUGHNESS_TEXTURE` layout.**

Forward+ `NORMAL_ROUGHNESS_TEXTURE` is RGBA8 storing:
- `.rg` — octahedral-encoded view-space normal
- `.b`  — roughness
- `.a`  — reserved / validity bit (**not AO**)

SSAO output is a separate compute buffer and is **not exposed to `CompositorEffect` in Godot 4.6.** There is no `needs_ssao` flag. Attempting `texture(NORMAL_ROUGHNESS_TEXTURE, uv).a` for occlusion reads garbage.

Consequence: rain-path sky-visibility **cannot** use SSAO in Phase 1. See §5.

### Compat functions (mandatory)

**Roaster correction #2.** Godot stores normal+roughness in an optimised format different from Spatial shaders. Compute shaders sampling the buffer must **inline `normal_roughness_compatibility()` from Godot source** to decode both channels. Without this, normals are garbage → every downstream math (up-bias, metal exclusion) is broken. Reference: `godotengine/godot-docs#9591`.

The shader must ship a `// COMPAT FUNCTIONS — ported from servers/rendering/renderer_rd/shaders/effects/` header with the helper inlined. Maintain parity with the upstream function signature:

```glsl
vec4 normal_roughness_compatibility(vec4 p_normal_roughness) {
    float roughness = p_normal_roughness.w;
    if (roughness > 0.5) roughness = 1.0 - roughness;
    roughness /= 127.0 / 255.0;
    return vec4(normalize(p_normal_roughness.xyz * 2.0 - 1.0), roughness);
}
```

(Exact body to be copied from `godot/servers/rendering/renderer_rd/shaders/effects/` at implementation time — check the source at the Godot version pinned in project before copying; do not trust this snippet verbatim.)

### Core compute pass (per pixel)

1. Sample depth, reconstruct world position via `inv_proj * inv_view` (pattern from `underwater_compositor_effect`).
2. Sample normal_roughness, apply `normal_roughness_compatibility()`, decode normal to view→world.
3. Compute `wet_level` per §4 (submersion + rain).
4. Sample color; apply Lagarde (§2); write back.
5. **Stencil gate** — if `stencil & 0x1` (memory-holder marker, §6) skip Lagarde; memory path owns those pixels.

### Coverage

Every fragment that wrote depth: terrain, walls, rocks, buildings, flora, NPCs, carry items (but carved out by stencil — the per-material path handles them instead). Transparents run before this effect (POST_TRANSPARENT = after all 3D geometry writes depth + color), so alpha-blended flora is also wet.

---

## 3.B. Per-Material `object_wet.gdshader` — carry items

Existing shader: `src/core/shaders/object_wet.gdshader` (tested via `tests/visual/test_wet_map.gd`).

**Integration point:** `src/core/interaction/carry_controller.gd::_do_grab()` / `_do_release()`.

### Material-type fallback (roaster moderate #5)

Held objects may carry any of: `StandardMaterial3D`, `ORMMaterial3D`, existing `ShaderMaterial`, or `null` (material lives on the mesh surface). Plan must handle all four:

```gdscript
var source_mat := body.get_surface_material_or_override(0)
match source_mat:
    StandardMaterial3D:
        _inject_from_standard(source_mat, body)        # full wet path
    ORMMaterial3D:
        _inject_from_orm(source_mat, body)             # full wet path
    ShaderMaterial:
        if source_mat.shader == object_wet_shader:
            _enable_wet_on_existing(body, source_mat)  # already our shader, just flip flag
        else:
            _fallback_compositor_only(body)            # no memory, compositor still wets
    null:
        var surf_mat := body.mesh.surface_get_material(0)
        _route_by_type(surf_mat, body)                 # recurse on surface material
```

**Fallback behaviour:** when the per-material wet shader cannot inject (bespoke ShaderMaterial), the held object participates in compositor-path wet only (§3.A) with **no memory** and **no stencil carve-out disable** — i.e. stencil is not written, compositor path handles it, item dries instantly on lift-out. Acceptable degradation. Logged at `Log.warn("wetness", ...)` for artist-pipeline visibility.

### Grab path

1. Save `_saved_material_override` on the body.
2. Build `ShaderMaterial(object_wet)`, extract albedo/roughness/metalness/albedo_texture from source, push to shader uniforms.
3. Enable stencil write: `stencil_mode = STENCIL_MODE_WRITE, stencil_value = 1` on the ShaderMaterial (per §6).
4. `body.material_override = wet_mat`.
5. `WetnessManager.register_memory_holder(body, mesh_bottom_local_y)`.

### Release path

1. `WetnessManager.unregister_memory_holder(body)`.
2. `body.material_override = _saved_material_override`.

**Rationale for per-material on carry items:** 1 object at a time (or small stack in inventory preview). Zero perf concern. Gives memory (stays wet after lifted from water).

---

## 3.C. Per-Material `object_wet.gdshader` — characters

**Integration points (moderate #10 confirmed):**
- `src/core/character/humanoid/humanoid_equipment.gd` — inject on clothing mesh equip.
- `src/core/character/humanoid/humanoid_character_factory.gd` — inject on body-part mesh creation.

Both apply the same material-type fallback ladder from §3.B.

**State model:** one `wet_line_y_local` per character root (not per mesh). `WetnessManager.register_memory_holder(character_root, -1.0)` where `-1.0` is a sentinel meaning "use bottom of character's AABB at runtime" (feet). WetnessManager drives each holder's per-shader uniform every frame.

**Cost ceiling:** ~10–30 meshes per visible NPC × ~8 NPCs max in view = ~240 ShaderMaterial instances peak. Versus ~3,000+ deduped static materials (compositor path handles those). Acceptable.

---

## 3.D. Terrain — `terrain_horizon.gdshader` (already shipped)

Kept as-is. `HorizonMapManager` already applies as Terrain3D's shader override. Formula already Lagarde.

**Change v1:** `HorizonMapManager`'s local uniform push is replaced by `WetnessManager` per-frame push (§8). HorizonMapManager retains shader-override setup only; stops owning wet uniforms. No behaviour regression — terrain tracks runtime sea_level + rain.

Terrain normal.y is always ≈1 (mostly horizontal). Rain exposure is effectively 1.0 for terrain; no special handling.

---

## 4. Wet-Level Composition

Per-fragment mask combining submersion + rain.

```glsl
float submersion = smoothstep(sea_level + wet_margin, sea_level, world_y);

// Rain contribution (§5): exposure × intensity × saturation curve
float rain_contrib = rain_intensity
                   * sky_exposure
                   * saturate(rain_accumulation / rain_saturation_time);

float wet_level = max(submersion, rain_contrib);
```

**Choice of `max` vs additive-cap (moderate #8):** `max` is simpler and always shippable. Continuous additive form `saturate(submersion + 0.5 * rain_contrib)` avoids a hard seam where rain-soaked terrain crosses shore and transitions to submersion-soaked. Visual seam under `max` is imperceptible because both branches converge to 1.0 near the shoreline; if an artist-facing seam appears in Phase 1, switch to additive. Ship `max` first.

**Memory-holder per-object wet** (§3.B, §3.C) is blended on top inside the per-material shader itself — the per-material shader uses `wet_level = max(submersion_from_world_y, holder_decay_state)` where `holder_decay_state` is a uniform pushed by `WetnessManager` tracking dunk + rain accumulation over time.

---

## 5. Rain-Path Exposure Mask

**Roaster correction #1 (continued).** The original plan relied on SSAO's occlusion as a sky-visibility proxy via `NORMAL_ROUGHNESS_TEXTURE.a`. That channel doesn't carry AO. The correction below replaces §5 entirely.

### Phase 1 — pure upward-bias (ship first)

Simplest version that works for exposed flat/upward surfaces (roof tops, ground, rock upsides). Fails for surfaces under overhangs (treated as exposed even when sheltered).

```glsl
vec4 nr   = normal_roughness_compatibility(texture(NORMAL_ROUGHNESS_TEXTURE, uv));
vec3 nv   = nr.xyz;                       // view-space normal
vec3 nw   = (inv_view * vec4(nv, 0.0)).xyz;
float up  = saturate(nw.y * 0.5 + 0.5);   // 0 down, 0.5 horizontal, 1 up
float sky_exposure = smoothstep(0.2, 1.0, up);
```

The 0.2 cutoff kills rain on down-facing surfaces (undersides of rocks, bottoms of overhangs) even when the rest of the mask is wrong. Correctness trade-off is explicit and acceptable for Phase 1.

### Phase 2 — screen-space sky-visibility ray-march

Phase 2 upgrade matches Crimson Desert / Uncharted 4's published approach. From each fragment, ray-march the depth buffer upward along world-space `+y` (projected back into screen space). If the ray escapes the depth buffer without intersecting any occluder within `sky_march_max_length` (e.g. 30 m world-space), the fragment is sky-visible. Returns `sky_visibility = 1.0`. If intersected, returns `0.0`.

Implementation notes for Phase 2:
- Step count: 16–32 screen-space steps with exponential stride (compute-shader friendly).
- Early-out when stride exceeds remaining depth budget.
- Hi-Z depth pyramid optional optimisation (defer unless budget overruns).
- Cost estimate: +0.2–0.4 ms at 1440p. Pushes total wet-compositor budget to ~0.4–0.6 ms.

### Phase 2 alternative — baked per-cell sky visibility cubemap

Offline prebake per MW cell. Sampled at runtime via world-pos → cell lookup. Robust, cheap at runtime, expensive at bake time. Evaluated for Phase 3+ if screen-space approach proves insufficient.

### Rain accumulation integration

`WetnessManager` holds a single global `rain_accumulation` scalar:

```gdscript
func _process(delta: float) -> void:
    if rain_intensity > 0.0:
        rain_accumulation = min(rain_accumulation + delta * rain_intensity,
                                rain_saturation_time)
    else:
        rain_accumulation = max(rain_accumulation - delta / rain_saturation_time * wet_dry_rate * rain_saturation_time, 0.0)
    _push_global_uniforms()
```

Per-object memory holders (§6) track their own `holder_decay_state` locally via `_update_memory_holders(delta)`.

---

## 6. Memory-Holder ↔ Compositor Reconciliation — Stencil

**Roaster correction #3.** moist's draft proposed alpha-LSB marker with stencil as an "open question". Closed: use stencil. Alpha-LSB is rejected for three reasons:
1. Godot 4.6 forward+ does not guarantee alpha-channel preservation through multiple compositor stages; subsequent effects (tonemap, bloom, underwater) legitimately write into alpha.
2. 1 bit of alpha precision loss IS visible on alpha-blended content on held items (glass, decals, UI overlays).
3. Godot 4.6 native stencil exists for exactly this use case (`Material.stencil_mode`, `stencil_value`).

### Stencil protocol

- Project setting: ensure `rendering/driver/stencil_buffer` is enabled (verify default; if not, enable in `project.godot`).
- Memory-holder materials (per-material `object_wet.gdshader` instance, wrapped as `ShaderMaterial`):
  ```gdscript
  mat.stencil_mode  = BaseMaterial3D.STENCIL_MODE_WRITE
  mat.stencil_value = 1
  ```
- Compositor compute shader samples `STENCIL_TEXTURE` (or the packed depth-stencil texture; verify Godot 4.6 naming at implementation). Early-out when `stencil & 0x1 == 1`:
  ```glsl
  if ((stencil_sample(uv) & 0x1u) != 0u) { return; }  // memory holder owns this pixel
  ```
- Other compositor effects (underwater, godrays) are unaffected — they ignore stencil or use different bits.

### Reservation register

Stencil bit allocation (document at implementation time in `docs/audit/STENCIL_BITS.md`):
- Bit 0x1 — memory-holder marker (this system).
- Bits 0x2–0x80 — unreserved, available for future systems.

### Fallback escalation

If Godot 4.6 stencil integration proves broken at implementation (hardware-specific, Vulkan/D3D12 driver bug, unimplemented compositor access), escalate to user with reproduction + decide alternative (depth-compare, custom G-buffer channel, dedicated low-res memory-holder mask buffer). **Do not silently fall back to alpha-LSB.** Alpha-LSB is out of the design space.

---

## 7. Porosity Source

Roughness-derived for all paths in v1. Matches Lagarde's canonical fallback when per-material porosity textures are not authored.

```glsl
float porosity = saturate(-2.5 * (1.0 - roughness) + 1.25);
```

| Path | Porosity source | Metal exclusion |
|---|---|---|
| Terrain (3.D) | Roughness-derived | Terrain is never metal — skip check |
| Compositor (3.A) | Roughness-derived from `NORMAL_ROUGHNESS_TEXTURE.b` | **Open** — see below |
| Per-material (3.B, 3.C) | Roughness-derived from material uniform | `metallic > 0.5` check inline |

### Metal exclusion in compositor path (moderate / open)

Godot forward+ does not expose a dedicated metalness buffer to compositor effects in 4.6. Options:
- (a) Ship v1 with no metal exclusion on compositor path. Metal helmets darken slightly when submerged. Low visual cost, ship.
- (b) Write metalness into a reserved stencil bit (bit 0x2) from spatial shader at material level, read from compositor. Precise, requires touching every metal-using material.
- (c) Custom G-buffer addition (heavy infra).

**Decision:** ship (a) for Phase 1. If the artifact is visible on specific meshes (plate armour, metal doors), upgrade to (b) in Phase 2 alongside rain sky-visibility work.

### Phase 4 — per-material porosity textures

Deferred. Requires touching the prebaking pipeline to propagate an extra texture channel (G of ORM or dedicated). Out of scope until rain ships.

---

## 8. Driver Ownership — `WetnessManager` Autoload

**Decision:** new `WetnessManager` autoload. **Not** an extension of `HorizonMapManager`.

| Option | Pros | Cons |
|---|---|---|
| Extend `HorizonMapManager` | No new autoload | Name mismatch (it's scoped to terrain-shader + horizon shadow baking). Piles unrelated weather state into a terrain manager. Violates single-responsibility. |
| New `WetnessManager` autoload | Single purpose, clear API, owns rain state / registry / memory holders. Future weather hook lands naturally. | +1 autoload. 6 → 7. Within reason. |

### API

```gdscript
extends Node
class_name WetnessManager

# Global tunables (pushed every frame)
var sea_level: float = 0.0
var wet_margin: float = 0.3
var wet_albedo_darken: float = 0.6
var wet_roughness_target: float = 0.05
var wet_dry_rate: float = 0.1                # /s
var rain_saturation_time: float = 15.0       # s

# Weather inputs (set by weather system, stubbed in Phase 1)
var rain_intensity: float = 0.0              # 0..1
var rain_accumulation: float = 0.0           # integrated; read by shaders

# Registration
func register_material(mat_rid: RID) -> void
func unregister_material(mat_rid: RID) -> void
func register_memory_holder(node: Node3D, bottom_local_y: float) -> void
func unregister_memory_holder(node: Node3D) -> void

# Per-frame (automatic in _process)
func _push_global_uniforms() -> void         # RS material param writes
func _update_memory_holders(delta: float) -> void
```

### Integration points

- `world_explorer.gd::_setup_cameras()` — `WetnessManager.register_material(compositor.material_rid)` after compositor attaches.
- `HorizonMapManager.initialize()` — `WetnessManager.register_material(terrain_material_rid)`.
- `HorizonMapManager` loses its local wet uniform push path (moderate #11).
- `CarryController._do_grab()` — `WetnessManager.register_memory_holder(body, bottom_y)`.
- `CarryController._do_release()` — `WetnessManager.unregister_memory_holder(body)`.
- `HumanoidCharacterFactory.create_character()` — `WetnessManager.register_memory_holder(root, -1.0)`.

---

## 9. Stage Placement + Perf Budget

**Stage:** `EFFECT_CALLBACK_TYPE_POST_TRANSPARENT`, PRE-tonemap.
- `POST_OPAQUE` misses transparent flora — rejected.
- `POST_TRANSPARENT` matches `underwater_compositor_effect.gd` slot — approved.
- Pre-tonemap because Lagarde math is linear-space.

**Render priority:** 9.
- Order: wet (9) → godrays (11) → underwater (12).
- Rationale: wet tinting happens first in linear light; godrays then shafts through the wet-tinted scene; underwater absorbs the final composite. Verified ordering during implementation.

**Perf estimate (submersion-only, Phase 1):** 0.15–0.25 ms at 1440p on RTX 3060-class.
- 1 compute pass, 16×16 workgroup, 14,400 workgroups at 1440p.
- ~2 texture fetches + `normal_roughness_compatibility()` + ~20 ALU per pixel.
- Compared to `underwater_compositor_effect` measured ~0.4 ms (with caustics + wobble + ray-march) — wet is strictly lighter.

**Perf estimate (Phase 2, rain + sky-march):** 0.4–0.6 ms at 1440p.
- Adds 16–32 step screen-space ray-march along `+y`. Dominates the new cost.
- If over 0.6 ms budget: drop march step count to 12, or early-out below horizon plane.

**Measurement plan:** Phase 1 ships with `ProjectSettings("wetness/enabled")` toggle. Measure with Godot's built-in frame profiler + RenderDoc on `test_wet_compositor.tscn` after each phase lands. Acceptance: ≤ 0.3 ms Phase 1, ≤ 0.6 ms Phase 2.

---

## 10. File-Level Breakdown

### New files

- `src/core/water/wetness_manager.gd` — autoload; global state + memory-holder registry.
- `src/core/shaders/effects/wet_compositor_effect.gd` — `PostProcessEffect` subclass.
- `src/core/shaders/compute/wet_compositor.glsl` — compute shader.
- `tests/visual/test_wet_compositor.tscn` + `.gd` — submersion + (Phase 2) rain sliders.
- `tests/visual/test_wet_memory.tscn` + `.gd` — dunk + decay curve validation.
- `tests/unit/test_wetness_manager.gd` — pure-logic decay curve test.
- `docs/audit/STENCIL_BITS.md` — stencil bit allocation registry (created alongside stencil work).

### Modified files

- `project.godot` — add `WetnessManager` autoload; confirm `rendering/driver/stencil_buffer` enabled.
- `src/tools/world_explorer.gd` — remove one-shot `_horizon_map_manager.push_wet_map()` call (lines ~389–395); attach wet compositor to main camera; register compositor material with `WetnessManager` at `_setup_cameras()`.
- `src/core/world/horizon_map_manager.gd` — delete local uniform-push path; retain shader-override apply only; call `WetnessManager.register_material()` at init.
- `src/core/interaction/carry_controller.gd` — material-swap + stencil + registration on `_do_grab()` / `_do_release()` per §3.B.
- `src/core/character/humanoid/humanoid_equipment.gd` — inject object_wet on clothing equip.
- `src/core/character/humanoid/humanoid_character_factory.gd` — inject on body-part mesh creation; register with `WetnessManager` on character create.
- `src/core/shaders/object_wet.gdshader` — add `rain_level`, `holder_decay_state`, updated Lagarde formula per §2, stencil write mode per §6.

---

## 11. Test Coverage

### 11.A `tests/visual/test_wet_compositor.tscn`
- Flat environment + walls + rocks. `sea_level` slider (−5..+5 m). `rain_intensity` slider (0..1, Phase 2).
- `debug_show_mask` toggle → `wet_level` as red overlay.
- **Accept:** raising sea darkens submerged surfaces; rain slider ramps up-facing surfaces over `rain_saturation_time`; debug mask matches §4.

### 11.B `tests/visual/test_wet_memory.tscn`
- 3 carry items + 1 humanoid. `sea_level` slider. "Dunk 2s" command: auto-lifts, lowers sea, waits, restores.
- HUD: per-object `wet_line_y` + decay timer.
- **Accept:** dunked item holds wet_line at mesh top; linear decay at `wet_dry_rate`; dry at `1 / wet_dry_rate ± 0.5s`.

### 11.C `tests/visual/test_wet_terrain.tscn`
- Extend existing `test_wet_map.tscn`. Add `rain_intensity` slider (Phase 2).
- **Accept:** terrain wetting unchanged after WetnessManager refactor; rain slider affects terrain uniformly (normal.y ≈ 1).

### 11.D `tests/unit/test_wetness_manager.gd`
- No rendering. Pure logic.
- Simulate 15 s steady rain → `rain_accumulation == rain_saturation_time`.
- Simulate 10 s dry → `rain_accumulation == 0`.
- Holder registered with `holder_decay_state = 1.0`, tick 10 s dry → `holder_decay_state ≈ 0` ± tolerance.

### 11.E Main-scene manual verification
- Per feedback_never_launch_main_game_unprompted: user launches `Godotwind.tscn` when ready. Flies to Seyda Neen coast, observes terrain + rock wetting at shoreline. Rain verified once weather system lands.

**No auto-capture.** Per feedback `docs/audit/` policy.

---

## 12. Phased Rollout

### Phase 1 — Submersion foundation (bundled to avoid terrain regression)

**Roaster moderate #6: steps 2 + 3 bundled.** Terrain's existing wet behaviour must not regress during a dev branch; bundle the driver migration with the new compositor so terrain never loses its push.

1. Write `WetnessManager` (submersion uniforms only; no rain yet).
2. Write `wet_compositor_effect.gd` + `.glsl` (submersion) **AND** migrate `HorizonMapManager` / `world_explorer.gd` to `WetnessManager`-driven pushes in the same commit.
3. Integrate `object_wet.gdshader` into `CarryController` with stencil write + material-type fallback.
4. Integrate into `HumanoidEquipment` + `HumanoidCharacterFactory`.
5. Land `test_wet_compositor.tscn` + `test_wet_memory.tscn` + `test_wetness_manager.gd`.
6. User-driven main-scene verification.

### Phase 2 — Rain

1. Extend `WetnessManager` with `rain_intensity`, `rain_accumulation`; add weather-system stub.
2. Extend `wet_compositor.glsl` with upward-bias rain exposure (§5 Phase 1 spec).
3. Extend `object_wet.gdshader` with rain contribution + per-holder rain accumulation.
4. Extend `test_wet_compositor.tscn` + `test_wet_memory.tscn` with rain sliders; add rain decay unit test cases.
5. Optional follow-up: screen-space sky-visibility ray-march (§5 Phase 2 spec). Ship upward-bias first, upgrade if visually insufficient.

### Phase 3 — Puddle accumulation (deferred)

World-space 2D accumulation buffer (RGB16, ~1 texel per m). Rain adds, sun subtracts. Compositor samples via world-pos → uv. Pre-req: weather + sun state system.

### Phase 4 — Per-material porosity textures (deferred)

Artist-authored porosity channel. Pre-req: prebaking pipeline revised for extra channel.

---

## 13. Risks & Open Questions

| # | Risk | Mitigation |
|---|---|---|
| 1 | Godot 4.6 stencil compositor-side read has implementation gotchas | Prototype stencil sampling first thing in Phase 1, on a minimal test shader. If broken, escalate to user with repro; pick alternative (not alpha-LSB). |
| 2 | `normal_roughness_compatibility()` implementation differs across Godot versions | Copy function from the Godot source at the currently pinned version; retest on Godot upgrades. |
| 3 | Metal exclusion absent in compositor Phase 1 (§7) | Accept for Phase 1. Flag visually-degraded meshes for §7 option (b) (stencil bit 0x2) in Phase 2. |
| 4 | `object_wet.gdshader` does not reproduce full `StandardMaterial3D` lighting (no sheen / anisotropy / clearcoat) | Restrict per-material path to albedo + roughness + metallic only. If a specific mesh needs sheen, use `next_pass` overlay pattern instead of `material_override`. Case-by-case. |
| 5 | Low-end hardware (Steam Deck) perf | `ProjectSettings("wetness/enabled")` toggle. Disabled → compositor effect removed from stack; `WetnessManager` still drives terrain + per-material paths (cost near zero). |
| 6 | Per-material shader doesn't match compositor path exactly on submerged held items | Stencil carve-out makes them visually consistent. If the two formulas diverge, align by shared GLSL include (refactor both to `#include "wet_common.glsl"` in Phase 2). |

---

## 14. Review Trail (roaster → moist → roaster)

Closed items from the 2026-04-14 21:14 review:

| # | Issue | Resolution (this revision) |
|---|---|---|
| 1 | NORMAL_ROUGHNESS_TEXTURE alpha misidentified as AO | §3.A + §5 rewritten. AO is not in this buffer. Rain Phase 1 = upward-bias only. Phase 2 = screen-space sky-march (canonical). |
| 2 | `normal_roughness_compatibility()` missing | Added as mandatory subsection in §3.A "Compat functions". |
| 3 | Alpha-LSB stencil marker vs native stencil | Closed to native stencil (§6). Alpha-LSB removed from design space. |
| 4 | Uniform table internal inconsistency | §2 formula reads `1.0 - wet_albedo_darken`; literal removed. |
| 5 | Missing material-type fallback in per-material path | §3.B adds explicit match on `StandardMaterial3D` / `ORMMaterial3D` / `ShaderMaterial` / null. |
| 6 | Phase 1 step ordering (terrain regression risk) | §12 Phase 1 bundles compositor + driver migration in one step. |
| 7 | "Measure double-application severity first" defer-motivation | Removed. Stencil lands in Phase 1. |
| 8 | `max` vs additive in §4 | Noted. Ship `max`; revisit if seam visible. |
| 9 | `rain_saturation_time` missing from constants table | Added to §2. |
| 10 | Body part factory file | Confirmed `humanoid_character_factory.gd`; written in §3.C + §10. |
| 11 | HorizonMapManager push "remove" wording | §10 clarifies — local uniform push path deleted; shader-override apply retained. |
| 12 | Perf estimate grows with rain | §9 tracks Phase 1 vs Phase 2 budget explicitly. |

---

## 15. References

- Sébastien Lagarde — *Water drop 3a: Physically based wet surfaces* — https://seblagarde.wordpress.com/2013/04/14/water-drop-3a-physically-based-wet-surfaces/
- Sébastien Lagarde — *Water drop 3b: Physically based wet surfaces* — https://seblagarde.wordpress.com/2013/04/28/water-drop-3b-physically-based-wet-surfaces/
- Godot 4.6 `CompositorEffect` — https://docs.godotengine.org/en/stable/classes/class_compositoreffect.html
- Godot-docs #9591 — `normal_roughness_compatibility()` requirement — https://github.com/godotengine/godot-docs/issues/9591
- Godot forum — accessing normal/roughness buffer through compositor — https://forum.godotengine.org/t/accessing-the-normal-and-roughness-buffer-through-the-compositor/130455
- Godot `Material` / `stencil_mode` — https://docs.godotengine.org/en/stable/classes/class_material.html
- Project reference: `src/core/shaders/effects/underwater_compositor_effect.gd` (pattern twin).
- Project reference: `src/core/shaders/object_wet.gdshader` (existing per-material base).
- Project reference: `src/core/water/horizon_map_manager.gd` (existing terrain path).

---

## 16. Ownership & Next Steps

- Current plan owner: `@moist`.
- Plan review owner: `@roaster` (this revision — cleared).
- Implementation owner (Phase 1): `@moist`.
- Implementation review owner (Phase 1): `@roaster`, one pass after first draft lands.
- Do not start Phase 2 work in the same PR as Phase 1 — separate plan-review-implement-review loop per CLAUDE.md reviewer engagement scope.

Phase 1 is cleared for implementation. Rain path (Phase 2) spec is in this doc but implementation is gated on weather system scaffolding (out of scope v1).
