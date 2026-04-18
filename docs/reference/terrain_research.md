# Terrain Research — Industry Survey & Recommendations

> Reference material. This document is industry research + recommendations for terrain rendering techniques, not a description of what Godotwind currently implements. For the current state, see `docs/systems/terrain.md`. Not all sections describe shipped features.

---

## Table of Contents

1. [POM (Theoretical)](#pom-theoretical)
2. [Horizon Maps (Terrain Self-Shadowing)](#horizon-maps-terrain-self-shadowing)
3. [Composite Maps (OpenMW)](#composite-maps-openmw)
4. [Dynamic Terrain Displacement — Industry Approach](#dynamic-terrain-displacement--industry-approach)
5. [Industry Standards (2023-2025)](#industry-standards-2023-2025)
6. [Godot 4.6 Capabilities & Limitations](#godot-46-capabilities--limitations)
7. [Recommendations](#recommendations)

---

## POM (Theoretical)

### Would POM Work?

**Partially.** Godot's `BaseMaterial3D` supports POM (`heightmap_deep_parallax`), but for terrain:
- Does not work with tri-planar mapping (problematic for cliff faces)
- Does not change mesh silhouette
- Approximately doubles per-fragment cost with self-shadowing
- No tessellation available in Godot as an alternative (proposal #5995, status "needs consensus", no timeline)

**Verdict:** POM is viable for close-up flat terrain but not a general solution. Normal maps alone would give 80% of the visual improvement at near-zero cost.

---

## Horizon Maps (Terrain Self-Shadowing)

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

## Composite Maps (OpenMW)

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

## Dynamic Terrain Displacement — Industry Approach

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

### Unreal's Approach (for Reference)

Unreal uses **Runtime Virtual Textures (RVT)** — GPU-generated texel data cached on demand. More scalable than raw render targets. Not replicable in Godot due to lack of virtual texturing.

### Shipping Games

- **SnowRunner/MudRunner:** Persistent terrain deformation with extrusion physics, variable viscosity per surface
- **Horizon Forbidden West:** Deferred texturing via visibility buffer + compute shaders
- **Ghost of Tsushima:** GPU-interpreted bytecode for procedural terrain rules

---

## Industry Standards (2023-2025)

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

## Godot 4.6 Capabilities & Limitations

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

## Recommendations

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
