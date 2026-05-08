# Shore Overhaul Plan

Date: 2026-04-13
Status: Plan approved, implementation pending
Branch: `refactor/lod-b-wide` (or dedicated shore branch TBD)

---

## Problem Statement

Commit `0e88f63` removed the prebaked shore mask from the ocean shader pipeline. This fixed two bugs (fragment `discard` causing hard shore edges, `VERTEX.y += 0.15` z-fighting hack) but also removed vertex displacement dampening as collateral. Result: FFT waves run at full amplitude near shore and punch through terrain geometry. Fragment-side dampening (normals, foam, color blend via `water_thickness`) is cosmetic only — it cannot prevent vertex penetration.

## Current State (post-0e88f63)

### Working (fragment-side, depth-driven)
- Normal dampening: `gradient *= smoothstep(0.0, 1.0, water_thickness)` — flattens normals at shore
- Shore color blend: `smoothstep(0.0, 0.5, water_thickness)` — blends toward shallow color
- Shore intersection foam: `(1.0 - smoothstep(0.0, foam_edge_width, water_thickness)) * foam_detail`
- Jacobian whitecap foam: FFT-driven, dual-layer flow-mapped textures
- Beer-Lambert absorption, refraction, SSR, SSS — all depth-driven

### Broken (vertex-side)
- **No vertex displacement dampening** — waves at full amplitude everywhere
- Waves visually penetrate terrain at coastlines
- Was previously `VERTEX += displacement * shore` where `shore = sample_shore(VERTEX.xz) * wave_scale`

### Still Alive (CPU-side)
- `ShoreMaskGenerator` (JFA-based) — instantiated in `ocean_manager.gd`, used for CPU buoyancy queries
- `get_shore_factor(world_pos)` returns smoothstep-blended distance (0=shore, 1=deep)
- Texture is generated at 4096×4096 covering terrain world bounds
- NOT currently pushed to any shader uniform

## Root Cause Analysis — Why Shore Mask Was Removed

The old pipeline (`pre-0e88f63`) had three entangled behaviors:
1. **Fragment `discard` when `v_shore_factor < 0.01`** — killed ocean pixels over land. Unnecessary (depth buffer naturally occludes) and caused hard visible edges at the shore boundary.
2. **Z-fighting bias `VERTEX.y += 0.15`** — raised entire ocean 15cm to prevent z-fighting with terrain. Caused a visible offset artifact at shoreline.
3. **Vertex dampening `VERTEX += displacement * shore`** — scaled displacement by shore factor. This was CORRECT behavior.

All three were removed together because they shared the `v_shore_factor` varying. Items (1) and (2) were the actual bugs; item (3) was collateral damage.

---

## Phase Plan

### Phase 1 — Vertex Displacement Dampening (fixes the reported bug)

**Canonical pattern:** CREST `OceanDepthCache` — prebaked depth texture sampled in vertex shader.

**Implementation (reuse existing infrastructure):**

1. Re-add `shore_mask` (sampler2D) + `shore_mask_bounds` (vec4) uniforms to `ocean_fft_common.gdshaderinc`
   - Vertex-only usage. Do NOT reintroduce `v_shore_factor` varying or fragment-side mask reads.
2. In `ocean_fft.gdshader` vertex function:
   ```glsl
   vec2 shore_uv = (VERTEX.xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
   float shore = texture(shore_mask, clamp(shore_uv, vec2(0), vec2(1))).r;
   // ...
   VERTEX += displacement * shore * wave_scale;
   ```
3. **Do NOT** reintroduce fragment `discard` — depth buffer handles occlusion.
4. **Do NOT** reintroduce z-fighting bias — unnecessary with proper dampening.
5. In `ocean_manager.gd`: re-enable `_load_shore_mask()` call during `_deferred_init()` to push `ShoreMaskGenerator` texture + bounds to the shader material.
6. Fragment-side dampening stays as-is (depth-driven `water_thickness`). No regression.
7. Same `_shore_mask` texture serves BOTH GPU vertex shader AND CPU buoyancy — single source of truth.

**Texture format:** RG16 from the start (R = shore distance for Phase 1, G = reserved for Phase 2 SDF gradient magnitude). Full-world single bake at 4096×4096 (~4m/texel over ~16km). No per-frame camera-follow update — MW scale doesn't warrant it.

**What this fixes:** Vertex displacement fades to zero at shore. No terrain penetration. Fragment visuals unchanged.

### Phase 2 — Shore Distance SDF + Shore Waves ("waves lapping on beach")

**Canonical pattern:** Outerra — skewed trochoidal shore waves oriented by SDF gradient.

**Implementation:**

1. Compute shore SDF gradient from Phase 1 depth texture:
   - Option A: Sobel filter on R channel in a compute pass → store direction in GB channels
   - Option B: Bake gradient at `ShoreMaskGenerator` time (JFA already has distance, gradient is cheap)
2. Add analytical shore wave layer in vertex shader:
   ```glsl
   // Skewed trochoidal wave, oriented perpendicular to coastline
   vec2 shore_dir = texture(shore_mask, shore_uv).gb; // gradient direction from SDF
   float shore_depth = texture(shore_mask, shore_uv).r;
   float shore_amp = shore_wave_amplitude * smoothstep(0.0, shore_wave_max_depth, shore_depth)
                   * (1.0 - smoothstep(shore_wave_max_depth, shore_wave_max_depth * 2.0, shore_depth));
   // Trochoidal swash with skew parameter for asymmetric breaking shape
   // Phase driven by distance-to-shore (waves "arrive" at shore)
   ```
3. Tune: amplitude curve, skew (steep leading face), phase speed, octave count.

**What this adds:** Visible gentle waves pushing up beaches, oriented correctly to coastline shape. Asymmetric breaking wave profile that FFT alone cannot produce in shallows.

### Phase 3 — Wet Map (visual polish)

**Canonical pattern:** Sebastien Lagarde's PBR wet surfaces (Remember Me, 2013). Shipped in AC3, Uncharted 2/3, Crysis 2/3, MGSV.

**Implementation:**

1. Push `sea_level` uniform from `OceanManager` to terrain/object shaders.
2. In terrain fragment shader:
   ```glsl
   float wetness = smoothstep(sea_level + wet_margin, sea_level, world_y);
   float porosity = saturate(((1.0 - glossiness) - 0.5) / 0.4);
   float effective_porosity = (1.0 - metalness) * porosity;
   albedo *= mix(1.0, 0.2, wetness * effective_porosity);
   roughness = mix(roughness, 0.0, wetness * effective_porosity);
   ```
3. `wet_margin` = 0.5–2.0m (capillary rise simulation). Configurable per-material.
4. Optional per-material porosity: sand=high, rock=medium, metal=none.

**What this adds:** Sand/rocks near water darken and get glossy. No extra render pass needed — just a uniform and ~5 lines of shader.

### Phase 4 (Future) — Wake/Interaction Foam

World-space foam simulation texture for boat wakes, character splashes. Separate system, not blocking shore quality. Deferred.

---

## Architecture Decisions

| Decision | Rationale |
|----------|-----------|
| Reuse `ShoreMaskGenerator` JFA texture | Already exists, serves CPU buoyancy. No new infrastructure. |
| Full-world bake, not camera-follow | MW is ~16km. 4096px = ~4m/texel. Adequate for 50m fade. Camera-follow adds per-frame cost + edge artifacts for no benefit at this scale. |
| RG16 texture format | R = shore distance (Phase 1), G = gradient magnitude (Phase 2). Plan format upfront to avoid rebake. |
| Vertex dampening only, no fragment mask reads | Fragment-side depth-driven dampening (normals, foam, blend) already works well. Shore mask in fragment would be redundant and add a texture sample. |
| No fragment discard | Depth buffer naturally occludes ocean behind terrain. Discard caused hard edges — the bug that triggered the removal. |
| No z-fighting bias | Proper vertex dampening eliminates z-fighting at shore. The `+0.15m` hack is unnecessary. |
| No separate shore mesh | Sea of Thieves, CREST, AC4, Outerra all use one ocean mesh with data-driven shore behavior. Separate shore mesh is an indie hack that doesn't scale to procedural coastlines. |

## Key Files

| File | Role |
|------|------|
| `src/core/water/shaders/ocean_fft.gdshader` | Vertex shader — displacement dampening goes here |
| `src/core/water/shaders/ocean_fft_common.gdshaderinc` | Fragment shared code — shore uniforms declared here |
| `src/core/water/shaders/ocean_fft_projected.gdshader` | Projected grid vertex shader — needs same dampening |
| `src/core/water/shore_mask_generator.gd` | JFA shore distance map — texture source |
| `src/core/water/ocean_manager.gd` | Orchestrator — pushes texture to shader |
| `src/core/water/ocean_mesh.gd` | Mesh generation — no changes expected |

## References

- [CREST Ocean — Shallows & Shorelines](https://crest.readthedocs.io/en/stable/user/shallows-and-shorelines.html)
- [GPU Gems Ch.1 — Effective Water Simulation (Finch)](https://developer.nvidia.com/gpugems/gpugems/part-i-natural-effects/chapter-1-effective-water-simulation-physical-models)
- [Outerra Ocean Rendering](https://outerra.blogspot.com/2011/02/ocean-rendering.html)
- [Sebastien Lagarde — PBR Wet Surfaces](https://seblagarde.wordpress.com/2013/03/19/water-drop-3a-physically-based-wet-surfaces/)
- [Sea of Thieves SIGGRAPH 2018](https://history.siggraph.org/wp-content/uploads/2022/09/2018-Talks-Ang_The-Technical-Art-of-Sea-of-Thieves.pdf)
- [AC4 Black Flag Water Analysis](https://simonschreibt.de/gat/black-flag-waterplane/)
