# Lighting Research — Godot 4.6 Capabilities & Industry Practice

> Reference material. This document compares Godotwind's lighting against Godot 4.6 capabilities and AAA industry practice. For the current Godotwind config, see `docs/systems/lighting.md`.

---

## 1. Godot 4.6 Capabilities

### 1.1 Light Types — Full Feature Set

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

### 1.2 Global Illumination

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

### 1.3 Reflections

| System | Runtime Cost | Quality | Coverage |
|--------|-------------|---------|----------|
| **SSR** | Medium | Good for on-screen | Screen-space only |
| **ReflectionProbe** | Low (Once) / High (Always) | Excellent | Local volume |
| **SDFGI specular** | Included with SDFGI | Rough only | Global |
| **Sky reflections** | Free | Distant only | Global |

Godot blends these automatically: SSR → ReflectionProbe → SDFGI → Sky.

For **metallic armor**: `metallic=0.8–1.0, roughness=0.15–0.4` in StandardMaterial3D + this reflection stack handles it out of the box.

### 1.4 Emissive Materials

- `StandardMaterial3D.emission_enabled` + `emission_texture` + `emission_energy_multiplier`
- `ShaderMaterial`: write to `EMISSION` in fragment()
- Emission is **visual self-glow only** — does NOT illuminate nearby surfaces
- Pair with OmniLight3D or LightmapGI baking for actual illumination
- High emission_energy (>1.0) triggers glow/bloom via the Environment glow system

### 1.5 Volumetric Fog

- Built-in froxel-based system (frustum-aligned voxel grid)
- `light_volumetric_fog_energy` on each light for interaction
- FogVolume nodes for localized fog (swamp mist, cave fog, lava haze)
- Custom fog shaders write DENSITY, ALBEDO, EMISSION
- We have a **custom** ray-marched volumetric fog — may want to evaluate if Godot's built-in is sufficient

### 1.6 Shadow Performance

- Shadow atlas shared among non-directional lights (default 4096)
- Each shadow pass is expensive — our budget system (max 8) is correct
- `distance_fade_shadow` lets lights remain visible while dropping their shadow cost
- PCSS soft shadows via `light_size > 0` — use sparingly (expensive)

---

## 2. Industry Standards

### 2.1 How AAA Open Worlds Handle Lighting

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

### 2.2 Distant Lights — The Big Trick

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

### 2.3 Emissive Surfaces

| Surface | Typical Approach |
|---------|-----------------|
| **Lava** | Emissive shader + distortion + heat haze post-process + local OmniLight3D |
| **Fire/Torches** | GPUParticles3D + emissive material + OmniLight3D with flicker |
| **Windows at night** | Material variant swap based on time-of-day (NOT real interior lights) |
| **Magic effects** | Emissive particles + additive blend + high bloom |
| **Armor/Metal** | PBR metallic+roughness + environment reflections (no special system needed) |

### 2.4 Fake GI Techniques

- Light probes (SH or irradiance volumes) on a grid
- Baked directional ambient (ambient cubes — 6 directional colors)
- Bent normals for better AO directionality
- SSIL + SSAO for screen-space detail
- Color-tinted ambient based on nearby surface colors

---

## 3. Gap Analysis

### 3.1 What We Have vs What We Need

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

### 3.2 Critical Gaps (Ranked by Visual Impact)

1. **No distant lights** — Towns/dungeons invisible beyond 150m at night. Massive immersion break.
2. **No GI (SDFGI)** — Flat ambient lighting, no indirect color bounce. Scene looks artificially lit.
3. **No emissive materials** — Lava, fire, magic, torches have no self-glow. No bloom from light sources.
4. **No night variants** — Buildings/objects look the same day and night at MID/FAR distances.
5. **No interior ReflectionProbes** — Armor and metallic items lack convincing reflections indoors.

---

## 4. Raytracing

### 4.1 Available Options

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

### 4.2 Verdict

**Not viable for production today or in the near term.** Path tracing an open world at 60fps is computationally prohibitive. The rasterized pipeline with SDFGI + SSR + SSAO + SSIL is the correct approach. Monitor the NVIDIA fork and Godot 4.7 native RT for future hybrid approaches (RT shadows, RT reflections as optional quality tier).
