# Shadow, GI, and Anti-Aliasing Audit

**Date:** 2026-04-13
**Branch:** `refactor/lod-b-wide`
**Scope:** Shadow flickering/blockiness, global illumination, anti-aliasing quality.

---

## 1. Shadows — Blocky & Swimming

### Problem
Directional shadows are blocky (low texel density) and swim as the sun moves (texels shift sub-pixel between frames).

### Root Cause
- Sun light in `sky_manager.gd` had NO `shadow_normal_bias` set (Godot default is 1.0, but not explicit).
- NO `shadow_bias` set on sky_manager sun (only the fallback light had `shadow_bias = 0.03`).
- Project had no explicit `directional_shadow/size` — relied on Godot's default 4096.
- `soft_shadow_filter_quality` defaulted to `Soft Low` — too few PCF samples, makes block edges visible.
- Godot has built-in texel snapping for directional shadow stabilization (since 2.x, confirmed #84510). Swimming is caused by insufficient filter quality making the snapping grid visible, not by missing stabilization.

### Industry Standard
- **Cascaded Shadow Maps (CSM)**: 4 cascades, texel snapping, blend splits. Every major engine (Unreal, Unity, Source, id Tech).
- **Shadow filter**: PCF Soft Medium or higher. Hard/Very Low exposes texel grid.
- **PCSS (contact-hardening)**: via `light_size > 0`. Expensive — only for hero lights.
- **Shadow map resolution**: 4096 standard, 8192 for high-end.

### Fix Applied
- Set `shadow_bias = 0.02`, `shadow_normal_bias = 1.5` on sun DirectionalLight3D.
- Set `directional_shadow/soft_shadow_filter_quality = 3` (Soft Medium) in project settings.
- Cascade config already correct: 4 splits, blend enabled, splits [0.05, 0.15, 0.4], max_distance=200m.

---

## 2. Global Illumination — SDFGI

### Problem
No GI enabled. SSAO + SSIL provide screen-space approximation but no indirect light bounce, no color bleeding. Scene looks flat under indirect lighting.

### Why SDFGI
| System | Open World? | Streaming? | Dynamic ToD? |
|--------|------------|-----------|-------------|
| **SDFGI** | Yes (cascaded) | Yes (no baking) | Yes |
| VoxelGI | No (fixed box) | No | Yes |
| LightmapGI | No (8-node limit) | No | No |

SDFGI is the only viable GI for a streaming open world in Godot. No baking, cascades follow camera (like CSM), works with dynamic time-of-day. Known Godot 4.6 regression #115599 — may need monitoring.

### Industry Context
Most shipped AAA open-world titles (RDR2, Horizon, Far Cry) use NO fully real-time GI — they use baked probe grids + SSAO + artistic ambient. SDFGI is comparable to UE5 Lumen in concept (SDF-based cascaded GI) but lighter. Using it puts Godotwind ahead of most shipped titles for indirect lighting quality.

### Config Applied
```
sdfgi_enabled = true
sdfgi_cascades = 4
sdfgi_y_scale = 75%
sdfgi_use_occlusion = true
sdfgi_bounce_feedback = 0.3
sdfgi_read_sky_light = true
sdfgi_energy = 1.0
sdfgi_normal_bias = 1.1
sdfgi_probe_bias = 1.1

# Project setting:
rendering/global_illumination/gi/use_half_resolution = true
```

---

## 3. Anti-Aliasing — FSR 2.2 Replaces TAA

### Problem
TAA looks ugly — ghosting behind moving objects, temporal blur during camera movement, no built-in sharpening in Godot's TAA implementation.

### Why FSR 2.2
AMD FSR 2.2 is built into Godot 4.6. At `scale = 1.0` (native resolution), it acts as a **superior temporal AA**:
- Same jitter+accumulate principle as TAA
- Better motion vector handling → less ghosting
- Built-in sharpening via `fsr_sharpness` parameter
- At sub-native scale (0.75), provides upscaling + AA with net perf gain

FSR 2.2 at native replaces TAA in every way — strictly better quality. No MSAA needed alongside (FSR2 handles both geometric and specular aliasing).

### Other Options Available
- **SMAA 1x** (new in Godot 4.5): Better than FXAA, sharper, good for no-temporal setups
- **MSAA 2x + SMAA**: Sharpest possible, zero temporal artifacts, but specular aliasing unsolved
- **MSAA 4x/8x**: Avoid — black square artifacts with SSAO/SSR on AMD GPUs (#103669)

### Config Applied
```
# project.godot:
rendering/scaling_3d/mode = 2          # FSR 2.2
rendering/scaling_3d/scale = 1.0       # native resolution (pure AA mode)
rendering/scaling_3d/fsr_sharpness = 0.2

# Removed:
anti_aliasing/quality/msaa_3d = 0      # disabled (FSR2 handles it)
```

Settings enum updated: TAA replaced by FSR2 Native + FSR2 Quality (0.75 scale).

---

## Key Files Modified

| File | Change |
|------|--------|
| `project.godot` | Shadow filter quality, FSR 2.2 mode, GI half-res |
| `src/core/sky/sky_manager.gd` | Sun shadow bias/normal_bias, SDFGI on environment |
| `src/tools/ui/environment_controls.gd` | SDFGI in visual_state + apply, FSR2 toggle replaces TAA |
| `src/core/settings_manager.gd` | AntiAliasing enum updated |
| `src/tools/settings_tool.gd` | _apply_anti_aliasing updated for FSR2 |

---

## References

- Godot shadow stabilization: built-in since 2.x (#84510)
- SDFGI docs: `docs.godotengine.org/en/stable/tutorials/3d/global_illumination/using_sdfgi.html`
- FSR 2.2 in Godot: `docs.godotengine.org/en/stable/tutorials/3d/resolution_scaling.html`
- MSAA + screen-space artifacts: #103669
- SDFGI 4.6 regression: #115599
- Existing lighting audit: `docs/LIGHTING_AUDIT.md`
