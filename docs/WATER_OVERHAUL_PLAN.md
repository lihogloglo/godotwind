# Water System Overhaul — Consensus Plan

**Date:** 2026-03-04
**Contributors:** coder, roaster, arbiter
**Status:** Approved — implementation started

---

## Summary

Replace the current analytical Gerstner ocean with an FFT compute-based ocean (Tessendorf/JONSWAP), while keeping Gerstner as a mid-tier fallback. Extend the water framework to support multiple water body types (ocean, lakes, ponds) at arbitrary altitudes. Rivers deferred to a future phase.

---

## Architecture Decisions

### 1. FFT Replaces Gerstner for Ocean (HIGH tier)

**Why:** FFT captures wave-wave interaction, spectral realism, and Jacobian-based foam that hand-tuned Gerstner cannot. Industry standard (Sea of Thieves, RDR2, GTA V, AC4: Black Flag). The `godotoceanbuoyancy` inspo project proves the compute pipeline works in Godot 4.x.

**How:** Port the 6 GLSL compute shaders + `RenderingContext` wrapper + `WaveGenerator` + `WaveCascadeParameters` from `inspos/godotoceanbuoyancy/`. Adapt to Godotwind conventions (Log system, strict typing, RID lifecycle management).

### 2. Quality Tiers

| Tier | Technique | Compute Required | Target Hardware |
|------|-----------|-----------------|-----------------|
| FLAT | Colored plane, no waves | No | Integrated GPU / emergency fallback |
| STANDARD | Analytical Gerstner (current `ocean_standard.gdshader`) | No | Mid-range GPU (GTX 1050 Ti class) |
| HIGH | FFT compute, 2-4 cascades, Jacobian foam | Yes | Discrete GPU (GTX 1060+ class) |

Gerstner shader is archived to `src/core/water/archive/gerstner/` but remains the STANDARD tier — not deleted.

### 3. CPU-Side Buoyancy (Hybrid Approach)

**Decision:** CPU Gerstner approximation fed from FFT cascade parameters. NOT GPU readback.

**Rationale (3 independent arguments):**
- GPU readback (`texture_get_data()`) adds 1-frame latency (16ms physics desync at 60fps)
- GPU readback stalls the rendering pipeline
- Godot 4.4+ thread guard regression (issue #99750) restricts `texture_get_data()` to render thread only

**Implementation:** Extract dominant wave parameters from JONSWAP cascade configs (wind speed, fetch, tile length → peak wavelength/amplitude/direction via dispersion relation). Feed top 4-6 frequency bins into `GerstnerMath.gd` (renamed `WaveMath.gd`). Precompute once per weather state, evaluate per-frame on CPU. ~90-95% visual match with FFT surface, zero latency.

**Precedent:** Sea of Thieves uses this exact approach (pre-computed lookup table from FFT spectrum for CPU-side queries).

### 4. OceanManager Stays — No Rewrite

`OceanManager` keeps its responsibilities (FFT pipeline coordination, shore mask, height queries). No "WaterManager" replacement.

**Addition:** `WaterBodyRegistry` — lightweight Dictionary-based lookup table for "which water body am I in?" queries. WaterVolumes continue to handle their own physics via Area3D locally.

### 5. Shore Mask — Unchanged

JFA-based `shore_mask_generator.gd` is shader-agnostic. FFT shader reads `shore_factor`, multiplies displacement to dampen waves near coast. Additionally, JONSWAP's TMA depth attenuation naturally reduces waves in shallow water within the spectrum itself.

### 6. Compute Barrier Policy

Keep manual `compute_list_add_barrier()` calls from the inspo. Godot 4.3+ DAG manages raster pass barriers automatically, but compute-to-render texture dependencies via `RenderingDevice` are outside the scene render path — DAG likely doesn't track them. Test removing barriers only after everything works.

### 7. Foam Compositing Rule

Three foam sources, clear blending:
```
foam = max(jacobian_foam, shore_foam) + object_foam * 0.5
```
- **Jacobian foam** (whitecaps): From FFT displacement field Jacobian determinant. Dominates offshore.
- **Shore foam**: From shore mask + depth edge. Dominates near coast.
- **Object foam**: Localized splashes. Additive (doesn't compete with surface foam).

`max()` for the two surface sources prevents double-bright seams at the shore-ocean boundary.

### 8. Clipmap Mesh — No Changes

Existing 11-ring clipmap stays. Distance-faded displacement handles vertex density concerns:
- Inner rings: All cascades (swell + chop + ripple)
- Outer rings: Swell-only via `smoothstep(fade_start, fade_end, distance)`
- No extra subdivision — defeats clipmap O(1) vertex count guarantee

### 9. SSR Approach

Godot 4.6 native SSR + ReflectionProbe. Known limitation: SSR breaks where `ALPHA < 1.0` (shore edges). Acceptable for Morrowind — shore edges are rocky/swampy, reflections aren't the visual focus there.

### 10. RID Memory Management

All compute pipeline RIDs require manual `free_rid()`. Port must include proper cleanup in `_notification(NOTIFICATION_PREDELETE)` and `_exit_tree()`. Known leak source — the inspo handles this via `RenderingContext.free()`.

---

## Phase Plan

### Phase 0: Archive Current Gerstner Ocean
- Move `ocean_standard.gdshader` and `gerstner_math.gd` to `src/core/water/archive/gerstner/`
- Keep all other water infrastructure (ocean_manager, ocean_mesh, shore_mask, water volumes, buoyant_body)

### Phase 1a: Port RenderingContext Wrapper (~300 lines)
- Port `RenderingContext` from inspo to `src/core/water/rendering_context.gd`
- Handles shader loading, pipeline creation, descriptor sets, uniform sets
- Adapt to Godotwind conventions (strict typing, Log system, error handling)

### Phase 1b: Port FFT Compute Pipeline
- Port 6 GLSL compute shaders to `src/core/water/shaders/compute/`:
  - `spectrum_compute.glsl` — JONSWAP spectrum generation (expensive, runs once per weather state)
  - `spectrum_modulate.glsl` — Time-domain modulation
  - `fft_butterfly.glsl` — Pre-computed butterfly factors (runs once per resolution)
  - `fft_compute.glsl` — Stockham FFT (runs per cascade per frame)
  - `transpose.glsl` — Matrix transpose for column-wise FFT
  - `fft_unpack.glsl` — Displacement/normal/foam extraction
- Port `wave_generator.gd` and `wave_cascade_parameters.gd`
- Load-balance: 1 cascade update per frame (existing inspo pattern)

### Phase 2: New Ocean FFT Shader
- Write `ocean_fft.gdshader` sampling FFT displacement/normal maps from `Texture2DArrayRD`
- Cascade UVs: `VERTEX.xz / tile_length[i]` (world_vertex_coords render mode)
- Keep from current shader: shore mask, Fresnel (Schlick f0=0.02), native SSR, refraction via SCREEN_TEXTURE
- Improve: exponential depth-based absorption (current one leaks ocean floor)
- Foam: Jacobian-based from FFT alpha channel + shore foam from shore mask
- Distance-faded displacement per cascade

### Phase 3: Shore Mask Integration + Testing
- Verify shore mask dampens FFT displacement correctly
- Test clipmap + FFT at all distance tiers
- Profile GPU cost on target hardware
- Adjust cascade count/resolution based on measured performance
- **Performance target:** <3ms total GPU for water on GTX 1060-class card

### Phase 4: Buoyancy Overhaul
- Rename `GerstnerMath` → `WaveMath`
- Extract dominant wave params from JONSWAP cascade configs
- Parametrically-driven CPU evaluation (not hardcoded constants)
- `buoyant_body.gd` swaps height query source (GerstnerMath → WaveMath)
- Existing WaterVolume Area3D pattern unchanged

### Phase 5a: Multi-Water-Body Framework (Lakes + Ponds)
- Add `water_type` enum to WaterVolume: `OCEAN`, `LAKE`, `POND`
- Add `water_altitude` property
- Lakes: bounded mesh at custom Y, Gerstner shader (STANDARD tier) with reduced amplitude
- Ponds: static plane + simple ripple shader
- `WaterBodyRegistry`: lightweight Dictionary for "which water body am I in?" lookups
- ESM cell water levels feed lake altitudes via existing `lake_database_loader.gd`

### Phase 5b: Underwater Rendering
- Detect camera below water surface (camera.y vs water height at camera.xz)
- Apply underwater Environment: fog color shift, reduced draw distance, blue-green tint
- Stretch goals: caustics (projected texture), bubble particles

### Phase 6: Quality & Polish
- Weather-driven spectrum transitions (dual-spectrum blending, 2x memory during transition, lerp over ~5 seconds)
- Spray particles on wave crests
- Audio: wave sounds varying with wind/proximity

### Future (Phase 7+)
- Rivers: spline-based mesh, flowmap UV distortion, current forces (Witcher 3 approach)
- Object wake/splash interaction
- GPU Driven Renderer integration

---

## What We Keep vs Replace

| Keep | Replace |
|------|---------|
| Shore mask (JFA generator) | Gerstner shader → FFT shader (for HIGH tier) |
| Clipmap mesh (11-ring) | Hardcoded wave constants → cascade-driven |
| Fresnel/SSR/refraction approach | Single ocean-only architecture → multi-body |
| Water volumes (Area3D pattern) | CPU GerstnerMath (hardcoded) → WaveMath (parametric) |
| Buoyant body (adapted) | — |
| Lake database loader | — |
| OceanManager (extended) | — |

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Compute shader compat (integrated GPUs) | No FFT on low-end | STANDARD (Gerstner) fallback |
| Performance exceeds 3ms budget | Stuttering | Profile before commit; reduce cascade count/resolution |
| RID leaks from compute pipeline | Memory growth | Careful `free_rid()` in cleanup, `_exit_tree()` force-cleanup |
| Tiling artifacts at cascade boundaries | Visual seam | Distance-faded displacement, cascade overlap |
| Weather spectrum transition hitches | Visual pop | Dual-spectrum blending (2x memory during transition) |
| RenderingContext port complexity | Schedule risk | Scope as Phase 1a, 300 lines, proven pattern |

---

## Key References

- **Inspo (FFT + buoyancy):** `inspos/godotoceanbuoyancy/` — 2Retr0/GodotOceanWaves fork with buoyancy
- **Inspo (FFT base):** `inspos/GodotOceanWaves-main/` — Original FFT implementation
- **Inspo (visual water):** `inspos/Godot-Water-Shader-Prototype-4.4/` — Flow maps, beach waves, SSS
- **OpenMW water:** `inspos/openmw/apps/openmw/mwrender/water.cpp` — Per-cell water heights
- **Current ocean:** `src/core/water/shaders/ocean_standard.gdshader` — Analytical Gerstner (to become STANDARD tier)
- **Current buoyancy:** `src/core/water/gerstner_math.gd` — CPU wave evaluation
- **Sea of Thieves GDC 2018:** "The Technical Art of Sea of Thieves" — FFT ocean + CPU lookup table for buoyancy
- **Tessendorf 2001:** "Simulating Ocean Water" — Foundational FFT ocean paper
- **Adrian Courreges GTA V study:** Frame-by-frame ocean rendering analysis
