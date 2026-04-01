# Terrain Audit — Godotwind

Comprehensive audit of the terrain rendering pipeline: what we have, what's possible, and what's worth pursuing.

---

## Table of Contents

1. [Current Setup](#1-current-setup)
2. [Texture Quality & Mipmaps](#2-texture-quality--mipmaps)
3. [PBR Pipeline](#3-pbr-pipeline)
4. [Horizon Maps (Terrain Self-Shadowing)](#4-horizon-maps-terrain-self-shadowing)
5. [Composite Maps (OpenMW)](#5-composite-maps-openmw)
6. [Dynamic Terrain Displacement (RTT Footprints)](#6-dynamic-terrain-displacement-rtt-footprints)
7. [Industry Standards (2023-2025)](#7-industry-standards-2023-2025)
8. [Godot 4.6 Capabilities & Limitations](#8-godot-46-capabilities--limitations)
9. [Recommendations](#9-recommendations)

---

## 1. Current Setup

### Terrain3D Addon

- **Version:** 1.0.1 (GDExtension, C++ native)
- **Technique:** Geometry clipmap (nested LOD grids centered on camera, as in The Witcher 3)
- **Region size:** 256x256 pixels per region
- **Mesh LOD:** Up to 10 clipmap levels
- **Max textures:** 32 slots (0-31)
- **Platforms:** Windows, Linux, macOS, Android, iOS, WebAssembly

### Godotwind Integration

| File | Purpose |
|------|---------|
| `src/core/world/terrain_manager.gd` | Heightmap/control map generation, region import |
| `src/core/world/generic_terrain_streamer.gd` | Real-time terrain streaming (priority queue, frustum cull) |
| `src/core/world/terrain_texture_loader.gd` | Morrowind LTEX loading, PBR auto-detection |
| `src/core/world/morrowind_data_provider.gd` | Morrowind data provider (LAND records) |
| `src/tools/ui/terrain_preprocessor.gd` | Offline prebaking (4x4 cells per region) |
| `src/core/deformation/` | RTT deformation system (already integrated into shader) |

### Streaming Configuration

- **View distance:** 3 regions (~4.6 km)
- **Unload distance:** 5 regions
- **Generation budget:** 8ms/frame (sync mode)
- **Frustum culling:** Aggressive (skip regions behind camera)
- **Morrowind mapping:** 4x4 MW cells per Terrain3D region (117m x 4 = 468m per axis)

### Shader

Two shader options in `addons/terrain_3d/extras/shaders/`:

| Shader | Lines | Features |
|--------|-------|----------|
| `lightweight.gdshader` | 431 | Full PBR, macro variation, detiling, deformation |
| `minimum.gdshader` | 217 | Base/overlay blend only, performance mode |

Render mode: `blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx, skip_vertex_transform`

---

## 2. Texture Quality & Mipmaps

### What We Have

**Mipmaps: YES, generated and required.** The `terrain_texture_loader.gd` ensures all textures have mipmaps:

```gdscript
# From terrain_texture_loader.gd
if not img.has_mipmaps():
    if img.is_compressed():
        img.decompress()   # DDS/DXT must decompress first
    img.generate_mipmaps()
var new_texture := ImageTexture.create_from_image(img)
```

**Filtering:** `filter_linear_mipmap_anisotropic` (16x) — good quality at distance.

**DDS handling:** Morrowind textures are DXT-compressed DDS files. They must be decompressed before mipmap generation because `generate_mipmaps()` is incompatible with compressed formats. This means textures sit uncompressed in VRAM.

### Why Textures Don't Look Great

Several factors contribute:

1. **Source resolution:** Morrowind textures are typically 256x256 or 512x512 — low by modern standards
2. **No normal maps in vanilla Morrowind:** LTEX records only reference a diffuse texture. The auto-PBR detection (`_n`, `_normal` suffixes) won't find anything because vanilla Morrowind assets don't have them
3. **Decompressed in VRAM:** DDS textures are decompressed for mipmap generation, meaning they consume more VRAM than necessary (no GPU-compressed format like BC7)
4. **32-texture limit:** Morrowind has more than 32 unique land textures. Overflow textures are dropped with a warning — some cells may use incorrect textures
5. **256x256 control maps:** Per-region control map resolution limits blend precision
6. **No macro variation on source textures:** The shader supports macro variation noise, but it can only modulate what's there — low-res tiled textures still look tiled

### Texture Streaming

**Not available in Godot.** There is no mipmap-level streaming — once a texture loads, all mip levels are in VRAM. No engine-level virtual texture system exists, and none is on Godot's public roadmap.

**Current workarounds:**
- Material deduplication (~10,000 -> ~1,000 unique materials)
- BSAManager LRU cache (256MB cap)
- Impostor system for distant objects
- Terrain3D's clipmap handles geometry LOD, but not texture LOD

This is identified in `docs/FUTURE_STEPS.md` as one of the **biggest scalability constraints**.

---

## 3. PBR Pipeline

### What the Shader Supports

The lightweight shader has **full PBR support** per texture slot:

```glsl
uniform sampler2DArray _texture_array_albedo : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2DArray _texture_array_normal : hint_normal, filter_linear_mipmap_anisotropic;
uniform float _texture_normal_depth_array[32];      // Per-texture normal intensity
uniform float _texture_ao_strength_array[32];       // Per-texture AO strength
uniform float _texture_roughness_mod_array[32];     // Per-texture roughness modifier
```

### What We Actually Use

| Channel | Status | Notes |
|---------|--------|-------|
| Albedo | Working | Loaded from Morrowind LTEX -> BSA |
| Normal maps | **Framework ready, no data** | Auto-detected via `_n`/`_normal` suffixes, but vanilla MW has none |
| Roughness | **Framework ready, no data** | `_roughness_mod_array` uniform exists, defaults to 0 |
| AO | **Framework ready, no data** | `_ao_strength_array` uniform exists, defaults to 0 |
| Height (for blending) | Partial | Control map height-based blend exists in shader |

### Would Normal Maps Work If We Had Them?

**Yes.** The `terrain_texture_loader.gd` already searches for PBR companions:

```gdscript
var normal_suffixes := ["_n", "_normal", "_nrm"]
var height_suffixes := ["_h", "_height", "_disp"]
var roughness_suffixes := ["_r", "_rough", "_roughness", "_spec"]
var ao_suffixes := ["_ao", "_ambient", "_occlusion"]
```

If replacement texture packs (e.g., from Morrowind modding community) provide `_n.dds` files alongside the albedo, the pipeline would pick them up automatically and assign them to `Terrain3DTextureAsset`.

### Would POM Work?

**Partially.** Godot's `BaseMaterial3D` supports POM (`heightmap_deep_parallax`), but for terrain:
- Does not work with tri-planar mapping (problematic for cliff faces)
- Does not change mesh silhouette
- Approximately doubles per-fragment cost with self-shadowing
- No tessellation available in Godot as an alternative (proposal #5995, status "needs consensus", no timeline)

**Verdict:** POM is viable for close-up flat terrain but not a general solution. Normal maps alone would give 80% of the visual improvement at near-zero cost.

---

## 4. Horizon Maps (Terrain Self-Shadowing)

*Reference: [Fun With Horizon Maps — Gabriel Felipe da Silva](https://dasilvagf.github.io/posts/2020/08/fun-with-horizon-maps/)*

### What They Are

Horizon maps precompute terrain self-shadowing offline. For each heightmap texel, march outward in **8 compass directions** and record the maximum elevation angle encountered. At runtime, compare the sun's elevation against the stored angle — if `sun_elevation < horizon_angle`, the point is in shadow.

### How They Work

**Offline baking (DDA ray-march):**
1. For each texel P(x,y), march outward in 8 directions (N, NE, E, SE, S, SW, W, NW)
2. At each step, compute angle between horizontal and the vector to the sample point
3. Track maximum angle per direction = horizon angle
4. Store 8 angles per texel in 2 RGBA8 textures (4 channels each)

**Runtime (2 shader instructions):**
1. Project sun direction onto XZ plane to select stored direction
2. Load horizon angle, compare to sun elevation
3. `sun_elevation < horizon_angle` = shadow

### Performance

| Aspect | Cost |
|--------|------|
| Runtime | 2 shader instructions per fragment (texture load + compare) — essentially free |
| Precompute | ~2 minutes at 512x512, scales with resolution and march distance |
| Storage | 2x RGBA8 textures per region (2 x W x H x 4 bytes) |
| Dynamic sun | Works for any sun angle — no re-baking needed |

### vs. Shadow Maps

- No per-frame shadow pass
- No shadow acne, peter-panning, or cascade seam artifacts
- Resolution-independent (tied to heightmap, not shadow map resolution)
- Works naturally with very large terrains
- But: **static geometry only**, no soft penumbra (basic), no dynamic object shadows

### vs. Composite Maps (Are They the Same Thing?)

**No.** They are completely different techniques:

| | Horizon Maps | Composite Maps |
|-|-------------|----------------|
| Purpose | Precompute self-shadowing angles | Bake blended textures for distant LOD |
| Data | Elevation angles (8 dirs) | Color + normals + vertex colors |
| Problem solved | Terrain shadows | Expensive multi-layer blending at distance |
| Runtime cost | 2 instructions | 1 texture sample (replaces N-layer blend) |

### Integration with Terrain3D

**Very feasible:**
1. Bake horizon maps alongside heightmaps in `terrain_preprocessor.gd`
2. Store as 2 RGBA8 textures per region
3. Pass as uniform sampler2D to the lightweight shader
4. Sample in `fragment()` — 2 lines of GLSL
5. Multiply shadow factor into `ALBEDO` or feed into `SPECULAR`/`AO`

Terrain3D supports `set_shader_parameter()` for injecting custom uniforms. The deformation system already demonstrates this pattern.

### Advanced: Soft Shadows

Peter-Pike Sloan's "Interactive Horizon Mapping" (Microsoft Research) extends the technique with a multi-resolution pyramid for soft penumbra. Runtime cost increases to ~4-8 texture fetches but still far cheaper than shadow maps.

---

## 5. Composite Maps (OpenMW)

*Reference: [OpenMW GitLab #7800](https://gitlab.com/OpenMW/openmw/-/work_items/7800)*

### What They Are

Composite maps are **prebaked terrain texture atlases** for distant LOD. Instead of blending all terrain texture layers per-fragment at distance (where texel density is low anyway), composite maps bake the final visual result into a single texture.

### What Data They Contain

Per annalithic's OpenMW branch (`compositemaps`, Dec 2023 - Mar 2024):
1. **Composite color map** — final blended albedo after all layers are mixed
2. **Composite normal map** — baked terrain normals from heightmap
3. **Vertex color data** — Morrowind vertex colors baked in for per-vertex tinting

Key quote from the issue: "allows the composite maps to retain a shocking amount of detail, even when the terrain is extremely low poly" (tested at LOD -2).

### Relevance to Godotwind

Terrain3D's clipmap already handles geometry LOD, but the outermost LOD rings still sample all 32 texture layers. A composite map for the farthest rings would:
- Reduce texture sampling from N layers to 1 per fragment
- Preserve visual fidelity at distance (baked-in normals + vertex colors)
- Could be prebaked in `terrain_preprocessor.gd` alongside heightmaps

**Priority:** Medium. The clipmap already mipmaps textures at distance, so the visual improvement is moderate. But the performance saving (fewer texture array samples) could be meaningful.

---

## 6. Dynamic Terrain Displacement (RTT Footprints)

### How It Works (Industry Standard)

```
Character foot contacts ground
  -> Invisible "stamper" mesh rendered to RTT viewport
    -> Deformation texture updated (accumulative)
      -> Terrain shader samples deformation texture
        -> Vertex displacement + material blend applied
```

**Key components:**
1. **Deformation render target** — SubViewport with top-down orthographic camera, additive blending
2. **Stamp system** — Invisible meshes with radial gradient textures at contact points
3. **Terrain shader** — Samples deformation texture, offsets vertex position along normal
4. **Persistence** — Texture persists across frames; optional decay (multiply by 0.99/frame for filling in)

### What Godotwind Already Has

**We already have most of this.** The `src/core/deformation/` directory contains:

| File | Purpose |
|------|---------|
| `terrain_deformation_integration.gd` | Texture2DArray for deformation (64 layers), region-to-index mapping, LRU eviction, shader parameter injection |
| `terrain_deformation_bridge.gd` | Per-texture rest heights (32 slots), auto-parse texture names for deformability |
| `terrain_deformation_texture_config.gd` | Config resource with presets (Morrowind, Snow World, Desert, etc.) |
| `terrain_texture_name_parser.gd` | Auto-detect material deformability from texture names |

**Shader uniforms already in lightweight.gdshader:**
```glsl
uniform highp sampler2DArray deformation_texture_array : filter_linear, repeat_disable;
uniform bool deformation_enabled = false;
uniform float deformation_depth_scale : hint_range(0.0, 1.0) = 0.1;
uniform float deformation_rest_height : hint_range(0.0, 0.5) = 0.1;
uniform bool deformation_affect_normals = true;
uniform float _texture_deform_rest_array[32];  // Per-texture deformation rest heights
```

### What's Missing

The deformation system is **framework-ready but not fully wired**:

1. **Stamp rendering** — No SubViewport stamper exists yet. Need a top-down camera + stamp meshes rendered on foot/wheel contact
2. **Region texture updates** — `update_region_texture()` exists but needs a source (the stamper viewport)
3. **Material blend** — Shader has deformation depth but doesn't blend to a "compressed" material variant (e.g., snow -> packed snow)
4. **Decay** — No gradual fill-in implemented
5. **Physics integration** — Need foot contact detection (raycasts or Area3D triggers)

### Compatibility with Terrain3D Clipmaps

**Yes, it works.** The deformation system already injects a `Texture2DArray` into Terrain3D's shader via `set_shader_parameter()`. The shader samples it using world-space UVs. Clipmap LOD changes vertex density, so:
- Inner rings: full deformation detail
- Outer rings: deformation naturally fades due to lower vertex density
- This is actually desirable — footprints are only visible up close anyway

### Unreal's Approach (for Reference)

Unreal uses **Runtime Virtual Textures (RVT)** — GPU-generated texel data cached on demand. More scalable than raw render targets. Not replicable in Godot due to lack of virtual texturing.

### Shipping Games

- **SnowRunner/MudRunner:** Persistent terrain deformation with extrusion physics, variable viscosity per surface
- **Horizon Forbidden West:** Deferred texturing via visibility buffer + compute shaders
- **Ghost of Tsushima:** GPU-interpreted bytecode for procedural terrain rules

---

## 7. Industry Standards (2023-2025)

### Terrain Rendering Stack (AAA)

| Technique | Description | Used By |
|-----------|-------------|---------|
| **Geometry clipmaps** | Nested LOD grids centered on camera | The Witcher 3, Terrain3D |
| **Virtual texturing** | Stream texture pages on demand, only visible tiles in VRAM | Far Cry 4+, id Tech (Megatexture) |
| **Full PBR stacks** | Albedo + Normal + Roughness + AO + Height per layer | Everyone |
| **Height-based blending** | Rocks poke through snow based on height channel | Everyone |
| **Tri-planar mapping** | Avoids UV stretch on cliffs | Ghost of Tsushima, most engines |
| **Macro variation** | Large-scale noise modulates tiling | Terrain3D has this |
| **Shadow height maps** | Terrain-aligned shadow data, eliminates shadow map aliasing | AMD GPUOpen technique |
| **Cascaded shadow maps** | Standard multi-cascade directional shadows | Every engine |
| **Deferred texturing** | Visibility buffer + compute shader material eval | Horizon Forbidden West |

### What We Can't Do in Godot

- **Virtual texturing** — No engine support, no roadmap
- **Tessellation** — Proposal #5995, "needs consensus", no timeline
- **Bindless textures** — Would solve 32-texture limit, not available
- **GPU-driven renderer** — Reduz has mentioned it, multi-year effort
- **Deferred texturing** — Requires compute shader material evaluation pipeline

### What We CAN Do

- **Horizon maps** — Prebake + 2 shader instructions
- **Composite maps** — Prebake + single texture sample for distant terrain
- **PBR terrain textures** — Pipeline ready, just need the data
- **RTT deformation** — Framework exists, need stamper system
- **Macro variation** — Already in Terrain3D shader
- **Shadow height maps** — Similar to horizon maps, different data encoding
- **Custom shader extensions** — Via `set_shader_parameter()` on Terrain3D

---

## 8. Godot 4.6 Capabilities & Limitations

### Terrain3D Feature Matrix

| Feature | Status |
|---------|--------|
| Geometry clipmap LOD | 10 levels, with geomorphing |
| PBR materials (32 slots) | Albedo + Normal + Roughness + AO |
| Texture detiling | Built-in repetition breaking |
| Macro variation | Dual noise textures |
| Auto-shader (slope blend) | Yes |
| Holes / navigation flags | Per-texel control map bits |
| Foliage instancing | Up to 10 LOD levels + shadow impostors |
| Custom shader uniforms | Via `set_shader_parameter()` |
| Runtime heightmap modification | Import new region data at runtime |

### Godot Engine Limitations

| Limitation | Impact | Workaround |
|-----------|--------|------------|
| No texture streaming | All mip levels in VRAM | Material dedup, LRU cache |
| No tessellation | No geometric displacement | Shader-only displacement (vertex offset) |
| No virtual texturing | Can't scale to massive unique textures | Texture atlas, impostor system |
| No bindless textures | 32-texture hard cap in Terrain3D | Priority-based slot assignment |
| Custom shader requires GDExtension fork | Can't fully replace Terrain3D shader | Use `set_shader_parameter()` for extensions |

### Future Godot Versions

**4.7 (next):** RT acceleration structures (`GL_EXT_ray_query`) — useful for GPU occlusion culling, not terrain-specific.

**No timeline:** Official terrain in core (proposal #6121), tessellation (#5995), virtual texturing, bindless textures, GPU-driven renderer.

---

## 9. Recommendations

### Priority Matrix

| Technique | Effort | Visual Impact | Perf Impact | Priority |
|-----------|--------|---------------|-------------|----------|
| **Horizon maps** | Medium | High (terrain self-shadows) | Near-zero runtime | **1 — Do first** |
| **PBR texture packs** | Low (pipeline ready) | High (normals transform look) | Near-zero | **2 — Easy win** |
| **RTT deformation stamper** | Medium (framework exists) | Medium-High (immersive) | Low | **3 — Complete what's started** |
| **Composite maps (distant)** | Medium | Medium (better far terrain) | Positive (fewer samples) | **4 — Nice to have** |
| **Texture recompression (BC7)** | Low-Medium | None (same quality) | Positive (less VRAM) | **5 — Optimization** |
| **POM on terrain** | Low | Low-Medium (close-up only) | Negative (doubles frag cost) | **6 — Optional** |

### Recommended Implementation Plan

**Phase 1: Horizon Maps (terrain self-shadows)**
1. Add baking pass to `terrain_preprocessor.gd` — DDA ray-march per heightmap texel, 8 directions
2. Store 2 RGBA8 textures per region alongside heightmap cache
3. Inject as `sampler2D` uniforms into `lightweight.gdshader`
4. Sample in `fragment()`: project sun dir -> load horizon angle -> compare
5. Multiply shadow factor into `ALBEDO` and reduce `SPECULAR`
6. Optional: Sloan's multi-resolution pyramid for soft penumbra

**Phase 2: PBR Texture Packs**
1. Source or create normal maps for Morrowind terrain textures (community replacers exist)
2. Place alongside originals with `_n.dds` suffix — auto-detected by existing loader
3. Optionally add roughness (`_r.dds`) and AO (`_ao.dds`)
4. No code changes needed — pipeline already handles this

**Phase 3: Complete RTT Deformation**
1. Create SubViewport with orthographic top-down camera following player
2. Create stamp scene (plane mesh + radial gradient material) for foot contacts
3. Wire foot contact detection (raycast from character feet)
4. Feed viewport texture to `terrain_deformation_integration.gd`'s `update_region_texture()`
5. Add decay pass (multiply deformation texture by 0.99/frame)
6. Add material blend in shader (fresh snow -> compressed snow visual)

**Phase 4: Composite Maps for Distant LOD**
1. During prebaking, render each region's final blended appearance into a single texture
2. Bake normals + vertex colors into the composite
3. In shader, branch on clipmap ring: inner rings = full splatting, outer rings = composite sample
4. Reduces per-fragment texture samples from N to 1 for distant terrain

**Phase 5: Texture VRAM Optimization**
1. After `generate_mipmaps()`, recompress to BC7 format via `Image.compress(Image.COMPRESS_BPTC)`
2. BC7 gives ~4:1 compression with near-lossless quality
3. Reduces terrain texture VRAM by ~75%
4. Test for quality — BC7 handles gradients better than DXT but verify with Morrowind palettes

---

## Appendix: Key Code Paths

```
Terrain texture loading:
  terrain_texture_loader.gd::_load_texture_for_slot()
    -> BSAManager.load_texture()
    -> _ensure_mipmaps() [decompress + generate]
    -> _detect_pbr_companions() [auto-detect _n, _h, _r, _ao]
    -> Terrain3DTextureAsset.set_albedo_texture() / set_normal_texture()

Terrain streaming:
  generic_terrain_streamer.gd::_process()
    -> _get_needed_regions() [frustum + distance priority]
    -> _load_region() [heightmap + control + color import]
    -> terrain_3d.data.import_images()

Deformation:
  terrain_deformation_integration.gd
    -> set_shader_parameter("deformation_texture_array", ...)
    -> update_region_texture() [called per-region on deformation event]

Preprocessor:
  terrain_preprocessor.gd::_preprocess_terrain()
    -> terrain_manager.generate_region() [per 4x4 cell block]
    -> terrain_3d.data.save_directory()
```
