# Terrain — Godotwind

What Godotwind actually ships for terrain rendering. For industry-standard techniques and recommendations not yet implemented (horizon maps, composite maps, POM theory, AAA references), see `docs/reference/terrain_research.md`.

---

## Status (2026-04-18)

- **Terrain3D v1.0.1 stable** — in-tree at `addons/terrain_3d/`, GDExtension, all platforms.
- **Multi-region streaming works** — `generic_terrain_streamer.gd` handles priority queue + frustum culling at a 3-region (~4.6 km) view distance.
- **RTT deformation framework ready** — `src/core/deformation/` ships the Texture2DArray pipeline, shader uniforms, and per-texture rest-height config, but the **stamp rendering pass is NOT wired**: no SubViewport stamper, no foot-contact detection, no decay loop.
- **Custom build from source was reverted** — the v1.1-dev DLL experiment is archived. Reference material at `docs/archive/reference/terrain3d_build_from_source.md`.
- **Alignment saga resolved** — import-position + Z-up + physics-re-enable gotchas are documented in `.claude/CLAUDE.md` gotchas #8, #9, and #10.

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
| `src/core/world/morrowind/morrowind_data_provider.gd` | Morrowind terrain adapter provider (LAND records) |
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

### Known Quality Limits

Several factors cap terrain texture quality with vanilla Morrowind data:

1. **Source resolution:** Morrowind textures are typically 256x256 or 512x512 — low by modern standards
2. **No normal maps in vanilla Morrowind:** LTEX records only reference a diffuse texture. The auto-PBR detection (`_n`, `_normal` suffixes) won't find anything because vanilla Morrowind assets don't have them
3. **Decompressed in VRAM:** DDS textures are decompressed for mipmap generation, meaning they consume more VRAM than necessary (no GPU-compressed format like BC7)
4. **32-texture limit:** Morrowind has more than 32 unique land textures. Overflow textures are dropped with a warning — some cells may use incorrect textures
5. **256x256 control maps:** Per-region control map resolution limits blend precision
6. **No macro variation on source textures:** The shader supports macro variation noise, but it can only modulate what's there — low-res tiled textures still look tiled

### Texture Streaming

Godot 4.6 has no engine-level virtual texturing or mipmap-level streaming. Once a texture loads, all mip levels sit in VRAM. Workarounds: material deduplication (~10k → ~1k unique materials), BSAManager 256 MB LRU cache, impostors for distant objects. Terrain3D's clipmap handles geometry LOD, not texture LOD.

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

The `terrain_texture_loader.gd` already searches for PBR companions:

```gdscript
var normal_suffixes := ["_n", "_normal", "_nrm"]
var height_suffixes := ["_h", "_height", "_disp"]
var roughness_suffixes := ["_r", "_rough", "_roughness", "_spec"]
var ao_suffixes := ["_ao", "_ambient", "_occlusion"]
```

If replacement texture packs (e.g., from Morrowind modding community) provide `_n.dds` files alongside the albedo, the pipeline would pick them up automatically and assign them to `Terrain3DTextureAsset`.

---

## 6. Dynamic Terrain Displacement (RTT Footprints)

### What Godotwind Already Has

The `src/core/deformation/` directory contains:

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
