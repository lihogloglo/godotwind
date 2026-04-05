# Godotwind Lighting Audit

**Date:** 2026-04-05
**Scope:** Full audit of current lighting systems, comparison against Godot 4.6 capabilities and AAA industry standards.

---

## Table of Contents

1. [Current State — What We Have](#1-current-state)
2. [Godot 4.6 Capabilities — What's Available](#2-godot-46-capabilities)
3. [Industry Standards — What AAA Games Do](#3-industry-standards)
4. [Gap Analysis — What We're Missing](#4-gap-analysis)
5. [Raytracing — Future Considerations](#5-raytracing)
6. [Recommendations — Priority Roadmap](#6-recommendations)
7. [Key Files Reference](#7-key-files)

---

## 1. Current State

### 1.1 Light Sources

**ESM Light Records → OmniLight3D** (`reference_instantiator.gd:264-333`)
- Morrowind LIGH records are converted to OmniLight3D nodes
- Range: `radius * MW_LIGHT_SCALE (1/70)`, minimum 0.125m (matches OpenMW)
- Color from ESM, energy 1.2 (fire) or 0.8 (non-fire)
- Negative light support (`light_negative = true`)
- Shadows disabled by default (managed by shadow budget system)
- **Distance fade: 120m start → 150m fully gone** — matches NEAR tier boundary

**NIF Lights** (`nif_converter.gd:2353-2410`)
- NiPointLight → OmniLight3D, NiSpotLight → SpotLight3D
- Attenuation computed from NIF coefficients (constant/linear/quadratic)
- NIF light data is parsed and converted, but secondary to ESM-driven lights

**Celestial Lights** (`sky_manager.gd`)
- DirectionalLight3D for sun (energy=22.0) and moon (energy=0.5)
- Driven by sky system's celestial position calculations
- Sun contributes to volumetric fog for god rays

**No SpotLight3D usage** from ESM data — all Morrowind lights are omnidirectional.

### 1.2 Light Animation

**File:** `light_animator.gd` (123 lines)
- Flicker, FlickerSlow, Pulse, PulseSlow — from MW light flags
- Random brightness targets [0.25, 1.0]
- Effective 15 FPS with temporal smoothing
- Matches OpenMW's LightController behavior

### 1.3 Shadow Management

**File:** `light_shadow_budget.gd` (162 lines)
- **Budget:** Max 8 shadow-casting lights simultaneously
- **Distance tiers (with hysteresis):**
  - 0–8m: SHADOW_CUBE (6 passes, best quality)
  - 8–30m: SHADOW_DUAL_PARABOLOID (2 passes)
  - 30m+: No shadows
- Update interval: 0.5s, purge interval: 5s
- This is a solid system — well-architected for performance

### 1.4 Environment & Post-Processing

**File:** `environment_controls.gd`

| Feature | Status | Settings |
|---------|--------|----------|
| **SSAO** | Enabled | radius=1.5, intensity=3.0, detail=0.7 |
| **SSIL** | Enabled | radius=5.0, intensity=1.0 |
| **SSR** | Enabled | max_steps=64, depth_tolerance=0.2 |
| **Glow/Bloom** | Enabled | intensity=0.4, bloom=0.15, HDR threshold=0.8 |
| **Volumetric Fog** | Enabled | density=0.0015, length=800m, temporal reprojection |
| **Depth Fog** | Enabled | exponential, density=0.00008, height fog at y=0 |
| **Tonemap** | Filmic | exposure=1.0, white=8.0 |
| **SDFGI** | NOT enabled | — |
| **VoxelGI** | NOT used | — |
| **LightmapGI** | NOT used | — |
| **ReflectionProbe** | Only for ocean | — |

**Ambient light:** Source = SKY, contribution = 1.0, energy = 1.0
**Reflected light:** Source = SKY

### 1.5 Sky & Weather

- Custom atmospheric scattering shader (Rayleigh + Mie, Hillaire 2020 multi-scatter)
- Sun disc, moon, procedural stars
- Weather system modulates fog density/color, volumetric fog, sun energy, sky turbidity
- Thunder flash via volumetric emission spike
- God rays via sun volumetric fog energy

### 1.6 Custom Volumetric Effects

- `volumetric_fog_effect.gd` — ray-marched compute shader (ported from OpenMW VAIO)
- `godrays_effect.gd` — custom compute shader god rays
- These operate alongside Godot's built-in volumetric fog

### 1.7 Terrain Lighting

- `terrain_horizon.gdshader` — horizon map self-shadowing
- Baked horizon angles per 8 compass directions
- Sun elevation/azimuth mapped to shadow angles
- PBR terrain with albedo, normal maps, roughness, AO per texture

### 1.8 Impostor Lighting (FAR Tier, 500m–5km)

- `octahedral_impostor.gdshader` — 16-frame octahedral atlas (4x4)
- 2-pass baking: albedo (unlit) + normals (world-space RGB + depth A)
- PBR lighting applied: roughness=0.85, specular=0.3
- Frame interpolation with angular blending
- **No emissive data baked** — impostors are dark at night

### 1.9 Distance Rendering & Lights

| Tier | Range | Dynamic Lights | Shadows |
|------|-------|---------------|---------|
| **NEAR** | 0–150m | OmniLight3D + animation | Budget-managed (max 8) |
| **MID** | 150–500m | **None** | None |
| **FAR** | 500–5km | **None** (impostor-baked normals only) | None |

**Key gap:** Lights are completely invisible beyond 150m. A town 300m away is pitch black at night.

---

## 2. Godot 4.6 Capabilities

### 2.1 Light Types — Full Feature Set

**OmniLight3D / SpotLight3D:**
- `distance_fade_enabled/begin/length` — fades the light contribution
- `distance_fade_shadow` — **separate** distance to disable shadow (keeps light visible but unshadowed) — we don't use this
- `light_size` > 0 enables PCSS soft shadows
- `light_indirect_energy` — GI contribution multiplier
- `light_volumetric_fog_energy` — fog interaction
- `light_cull_mask` — 20-bit selective lighting (used for interior/exterior isolation)

**DirectionalLight3D:**
- PSSM 4 splits with configurable cascade distances
- `light_angular_distance` for penumbra size
- `directional_shadow_max_distance` — critical for quality/cost tradeoff
- `sky_mode` — LIGHT_AND_SKY, LIGHT_ONLY, SKY_ONLY

**Cluster Limits:**
- 512 clustered elements (OmniLight + SpotLight + Decal + ReflectionProbe combined)
- Configurable in Project Settings
- In practice, 100–200 active OmniLight3D with distance_fade is comfortable

### 2.2 Global Illumination

| System | Type | Best For | Open World? | Dynamic ToD? |
|--------|------|----------|-------------|-------------|
| **SDFGI** | Real-time, cascaded SDF | Large outdoor scenes | Yes | Yes |
| **VoxelGI** | Real-time, voxel grid | Single rooms, small areas | No (limited volume) | Yes |
| **LightmapGI** | Fully baked | Static interiors | No | No |

**SDFGI is the correct choice for Godotwind:**
- No baking, works with streaming content
- Provides diffuse GI bounces + rough specular reflections
- Works with dynamic time-of-day
- Cascaded volumes follow camera (like cascaded shadow maps)
- **Known issue:** Godot 4.6 regression ([#115599](https://github.com/godotengine/godot/issues/115599)) — SDFGI/VoxelGI rendering broken compared to 4.5. Expected fix in 4.6.x or 4.7.

**Recommended SDFGI config for open world:**
- Cascades: 4–6
- Half resolution: enabled
- Bounce count: 2
- Cell size: 0.5–1.0 for outdoor

### 2.3 Reflections

| System | Runtime Cost | Quality | Coverage |
|--------|-------------|---------|----------|
| **SSR** | Medium | Good for on-screen | Screen-space only |
| **ReflectionProbe** | Low (Once) / High (Always) | Excellent | Local volume |
| **SDFGI specular** | Included with SDFGI | Rough only | Global |
| **Sky reflections** | Free | Distant only | Global |

Godot blends these automatically: SSR → ReflectionProbe → SDFGI → Sky.

For **metallic armor**: `metallic=0.8–1.0, roughness=0.15–0.4` in StandardMaterial3D + this reflection stack handles it out of the box.

### 2.4 Emissive Materials

- `StandardMaterial3D.emission_enabled` + `emission_texture` + `emission_energy_multiplier`
- `ShaderMaterial`: write to `EMISSION` in fragment()
- Emission is **visual self-glow only** — does NOT illuminate nearby surfaces
- Pair with OmniLight3D or LightmapGI baking for actual illumination
- High emission_energy (>1.0) triggers glow/bloom via the Environment glow system

### 2.5 Volumetric Fog

- Built-in froxel-based system (frustum-aligned voxel grid)
- `light_volumetric_fog_energy` on each light for interaction
- FogVolume nodes for localized fog (swamp mist, cave fog, lava haze)
- Custom fog shaders write DENSITY, ALBEDO, EMISSION
- We have a **custom** ray-marched volumetric fog — may want to evaluate if Godot's built-in is sufficient

### 2.6 Shadow Performance

- Shadow atlas shared among non-directional lights (default 4096)
- Each shadow pass is expensive — our budget system (max 8) is correct
- `distance_fade_shadow` lets lights remain visible while dropping their shadow cost
- PCSS soft shadows via `light_size > 0` — use sparingly (expensive)

---

## 3. Industry Standards

### 3.1 How AAA Open Worlds Handle Lighting

**RDR2** (Rockstar's RAGE engine):
- Deferred rendering with separate global/local lighting passes
- Top-down world lightmap for large-scale ambient/AO
- Cascaded Shadow Maps (4 cascades, 1024x4096 atlas)
- Tiered shadow quality: 2048 (near), 1024 (mid), 512 (far)
- Point light shadows: mostly **baked cubemaps**, real-time only near player
- Environment cubemaps for IBL
- **No true real-time GI** — uses baked probes + SSAO + contact shadows

**Horizon Forbidden West** (Decima engine):
- Dense light probe grid for indirect lighting
- Screen-space GI for local color bleeding
- Temporal accumulation for SSR quality
- Physically-based cloud/sky lighting (Nubis system)

**Key takeaway:** No AAA open-world game uses fully real-time GI. All use **hybrid approaches** (baked probes + screen-space effects + artistic ambient).

### 3.2 Distant Lights — The Big Trick

**AAA distant lights are NOT real lights.** They are:

1. **Billboard quads** — MultiMesh of tiny quads with glow texture, additive blend, warm color
2. **Emissive impostor textures** — building impostors have "night variant" with glowing windows
3. **Particle system** — distant "light dot" particles, constant screen-space size
4. **Pre-baked emissive atlases** — LOD meshes with emission baked into material

**Implementation pattern:**
- 0–150m: Real OmniLight3D (what we do)
- 150–300m: OmniLight3D with shadow disabled (via `distance_fade_shadow`)
- 300m+: Switch to emissive material on LOD mesh
- 1km+: Billboard sprite / MultiMesh point with glow

**This is the single biggest gap in Godotwind.** Towns beyond 150m are dark.

### 3.3 Emissive Surfaces

| Surface | Typical Approach |
|---------|-----------------|
| **Lava** | Emissive shader + distortion + heat haze post-process + local OmniLight3D |
| **Fire/Torches** | GPUParticles3D + emissive material + OmniLight3D with flicker |
| **Windows at night** | Material variant swap based on time-of-day (NOT real interior lights) |
| **Magic effects** | Emissive particles + additive blend + high bloom |
| **Armor/Metal** | PBR metallic+roughness + environment reflections (no special system needed) |

### 3.4 Fake GI Techniques

- Light probes (SH or irradiance volumes) on a grid
- Baked directional ambient (ambient cubes — 6 directional colors)
- Bent normals for better AO directionality
- SSIL + SSAO for screen-space detail
- Color-tinted ambient based on nearby surface colors

---

## 4. Gap Analysis

### 4.1 What We Have vs What We Need

| Feature | Current State | Industry Standard | Gap |
|---------|--------------|-------------------|-----|
| **Dynamic lights (NEAR)** | Working (OmniLight3D, animation, shadow budget) | Same | None |
| **GI** | SSIL only (no SDFGI/VoxelGI) | SDFGI or probe-based | **Major** |
| **Distant lights (MID/FAR)** | Nothing — lights gone at 150m | Billboard/emissive system | **Critical** |
| **Emissive materials** | Not used anywhere | Standard for lava, fire, windows | **Major** |
| **Metallic reflections** | SSR enabled (for ocean), no ReflectionProbes for characters | SSR + ReflectionProbe + env reflections | **Moderate** |
| **Shadow cascades** | 4 splits, blend enabled | Same | None |
| **Volumetric fog** | Custom compute shader (good) | Custom or built-in | None |
| **God rays** | Custom compute shader (good) | Same | None |
| **SSAO** | Enabled, good settings | Same | None |
| **Glow/Bloom** | Enabled | Same | None |
| **Time-of-day material swap** | Not implemented | Standard for night windows | **Major** |
| **Interior ReflectionProbes** | Not implemented | Standard for interiors | **Moderate** |
| **FogVolume (localized fog)** | Not used | Used for caves, swamps, lava | **Minor** |
| **Night impostor variants** | Not implemented | Emissive bake for FAR tier | **Major** |
| **Contact shadows** | Not enabled | Used in RDR2 etc. | **Minor** |

### 4.2 Critical Gaps (Ranked by Visual Impact)

1. **No distant lights** — Towns/dungeons invisible beyond 150m at night. Massive immersion break.
2. **No GI (SDFGI)** — Flat ambient lighting, no indirect color bounce. Scene looks artificially lit.
3. **No emissive materials** — Lava, fire, magic, torches have no self-glow. No bloom from light sources.
4. **No night variants** — Buildings/objects look the same day and night at MID/FAR distances.
5. **No interior ReflectionProbes** — Armor and metallic items lack convincing reflections indoors.

---

## 5. Raytracing

### 5.1 Available Options

**NVIDIA RTX Godot Fork** (March 2026):
- Full path tracing replacing rasterized lighting
- Based on latest Godot dev branch (not 4.6 stable)
- Requires RTX hardware + DLSS Ray Reconstruction denoiser
- **Experimental, not production-ready**
- Open world at 60fps is beyond current hardware capabilities

**Godot 4.7 Native Vulkan RT** (In Development):
- Initial low-level RT plumbing by Antonio Caggiano
- Currently: demo renders a reflective sphere
- Months to years from production readiness

**Community Fork** (gvvim/Godot4-Raytracing):
- Compute shader-based, abandoned since 2023

### 5.2 Verdict

**Not viable for production today or in the near term.** Path tracing an open world at 60fps is computationally prohibitive. The rasterized pipeline with SDFGI + SSR + SSAO + SSIL is the correct approach. Monitor the NVIDIA fork and Godot 4.7 native RT for future hybrid approaches (RT shadows, RT reflections as optional quality tier).

---

## 6. Recommendations

### Priority 1: Quick Wins (Configuration Only)

**Enable SDFGI:**
```gdscript
env.sdfgi_enabled = true
env.sdfgi_cascades = 4
env.sdfgi_use_occlusion = true
env.sdfgi_bounce_feedback = 0.5
env.sdfgi_energy = 1.0
env.sdfgi_normal_bias = 1.1
env.sdfgi_probe_bias = 1.1
```
- Instant GI quality improvement across entire world
- Note: check for 4.6 regression ([#115599](https://github.com/godotengine/godot/issues/115599)) — may need to wait for patch

**Extend light distance fade:**
```gdscript
# In reference_instantiator.gd, change from:
omni.distance_fade_begin = 120.0
omni.distance_fade_length = 30.0
# To:
omni.distance_fade_begin = 200.0
omni.distance_fade_length = 100.0
omni.distance_fade_shadow = 60.0  # Disable shadow early, keep light visible longer
```
- Lights visible to 300m (unshadowed beyond 60m)
- Immediate visual improvement at moderate cost

**Add emissive to existing light-associated meshes:**
- Torch meshes, lantern meshes, candle meshes should have `emission_enabled = true`
- Fire textures should emit with `emission_energy_multiplier = 2.0–3.0` to trigger bloom
- Lava terrain textures should have emission channel

### Priority 2: Medium-Term Systems

**Billboard Light MultiMesh (Distant Town Lights):**
- New system: `src/core/world/distant_light_manager.gd`
- MultiMesh of billboard quads at known ESM light positions
- Additive blend, warm color, soft glow texture
- Size scales with distance for constant screen-space size
- Toggle based on time-of-day (sun elevation threshold)
- One draw call for hundreds of "distant lights"
- **This is the highest-impact visual feature for open-world night scenes**

**Interior ReflectionProbes:**
- Place one ReflectionProbe per interior cell
- Update mode: Once (cheap — bake on cell load)
- `interior = true` to prevent sky leaking in
- Dramatically improves metallic/shiny material quality indoors

**Emissive Material System:**
- Material variant system that swaps emission on/off based on time-of-day
- For MW: light-source objects get an emission texture derived from their albedo
- Applied at object instantiation time in reference_instantiator

### Priority 3: Polish

**Night Impostor Variants:**
- Extend `impostor_baker_v2.gd` to bake a "night" atlas pass
- During night pass: enable emission on light-source objects
- At runtime: blend between day/night impostor based on sun elevation
- Allows towns to glow at FAR tier (500m–5km)

**FogVolume for Localized Effects:**
- Lava pools: FogVolume (box shape) with warm emission
- Caves: FogVolume with dense fog at entrance
- Swamps: FogVolume with ground-hugging fog

**Contact Shadows:**
```gdscript
# On DirectionalLight3D:
light.shadow_contact = 0.3  # Small-scale contact darkening
```

---

## 7. Key Files Reference

| File | Lines | Purpose |
|------|-------|---------|
| `src/core/esm/records/light_record.gd` | 119 | ESM LIGH record parsing |
| `src/core/world/reference_instantiator.gd` | 264–333 | OmniLight3D creation from ESM |
| `src/core/world/light_animator.gd` | 123 | Flicker/pulse animation |
| `src/core/world/light_shadow_budget.gd` | 162 | Dynamic shadow allocation |
| `src/core/sky/sky_manager.gd` | ~150 | Celestial lights + sky shader |
| `src/tools/ui/environment_controls.gd` | ~400 | Environment/post-processing setup |
| `src/core/weather/weather_renderer.gd` | ~150 | Weather → visual state |
| `src/tools/prebaking/impostor_baker_v2.gd` | ~150 | FAR tier impostor baking |
| `src/tools/prebaking/shaders/octahedral_impostor.gdshader` | 123 | Impostor rendering shader |
| `src/core/sky/shaders/sky.gdshader` | ~180 | Atmospheric scattering |
| `src/core/water/shaders/ocean_fft.gdshader` | ~180 | Ocean SSS lighting |
| `src/core/world/terrain_horizon.gdshader` | 366 | Terrain horizon self-shadow |
| `src/core/nif/nif_converter.gd` | 2353–2410 | NIF light → Godot conversion |
| `src/core/nif/nif_defs.gd` | 592–608 | NIF light class definitions |
| `src/core/shaders/effects/volumetric_fog_effect.gd` | — | Custom volumetric fog (OpenMW port) |
| `src/core/shaders/effects/godrays_effect.gd` | — | Custom god rays |

---

## Summary

**What's solid:** Light instantiation, animation, shadow budgeting, sky/atmosphere, volumetric fog, god rays, terrain self-shadowing, SSAO/SSIL/SSR, glow. The foundation is good.

**What's missing:** SDFGI (easy to enable), distant visible lights (the biggest gap), emissive materials, night material variants, interior ReflectionProbes. These are what separate "tech demo" from "industry standard."

**The single most impactful improvement:** A billboard MultiMesh system for distant lights. Being able to see the lights of Balmora from a mountain at night would be transformative for immersion. This is exactly what RDR2 and similar games do — the "lights" you see from distance aren't real lights at all, they're tiny emissive billboards.
