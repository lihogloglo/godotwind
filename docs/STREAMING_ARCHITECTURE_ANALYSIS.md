# Godotwind Streaming & Distant Rendering Architecture Analysis

## Status: REPLACED BY NATIVE SYSTEM (January 2026)

**⚠️ HISTORICAL DOCUMENT**: This architecture has been replaced by a native Godot-based streaming system. See [STREAMING_AUDIT_REPORT.md](STREAMING_AUDIT_REPORT.md) for the current implementation.

The custom 10,000+ line streaming system described in this document has been deprecated and moved to `src/core/world/deprecated/`. The new system uses Godot 4.x native `visibility_range` features and consists of ~1,500 lines of code.

---

## Executive Summary (Historical)

This document provides a comprehensive audit of the **original** Godotwind asset streaming pipeline, analyzing how the system handled rendering from near to far distances. The codebase implemented a **sophisticated 4-tier rendering system** with GPU compute acceleration, following industry-standard patterns from games like RDR2 and Horizon Zero Dawn.

**This system has been replaced** - kept for historical reference only.

### Recent Simplifications (January 2026)

The streaming architecture has been simplified:
- **NEAR_ONLY mode removed**: Always uses FULL_AAA mode with all tiers active
- **Phase 2 GPU visibility disabled**: Kept for future use but not activated
- **NEAR tier budgets increased**: 30ms budget, 300 objects/frame during burst
- **Queue sorting disabled**: FIFO order is sufficient, saves O(n log n) per-frame
- **distant_tiers_enabled always true**: MID+FAR tiers always active
- **LOD audit logging gated**: Debug logging only runs when `debug_enabled = true`

---

## 1. Industry Background: Distant Rendering Techniques

### 1.1 How Open-World Games Achieve Distant Rendering

Open-world games use **tiered Level of Detail (LOD) systems** to maintain performance while rendering vast worlds:

| Technique | Distance | GPU Cost | Use Case |
|-----------|----------|----------|----------|
| Full Geometry | 0-200m | High | Player interaction, physics, shadows |
| LOD Meshes | 200-1000m | Medium | Simplified geometry, no physics |
| Impostors/Billboards | 1-10km | Very Low | Pre-rendered 2D textures |
| HLOD/Merged Chunks | 5-20km | Low | Combined terrain+buildings |
| Horizon/Skybox | >10km | Minimal | Background imagery |

**Key optimizations used in AAA titles:**
- **GPU-driven rendering**: Compute shaders decide visibility (avoids CPU iteration)
- **Indirect drawing**: GPU controls draw call counts directly
- **Screen-door dithering**: Smooth crossfades between LOD levels via TAA
- **Sparse data structures**: Only process changed objects, not all objects

### 1.2 Godot 4's Capabilities for Complex Rendering

Godot 4 provides several features for distant rendering:

| Feature | Status in Godotwind | Notes |
|---------|---------------------|-------|
| `visibility_range_begin/end` | **NOT USED** | Custom system preferred for more control |
| MultiMesh batching | **USED** | Single draw call per mesh type |
| RenderingServer compute | **USED** | GPU visibility calculations |
| `multimesh_get_buffer_rd_rid()` | **USED** (4.4+) | Direct GPU buffer access |
| Indirect drawing | **PARTIALLY** | Prepared for, not fully enabled |
| Compute shaders | **HEAVILY USED** | Visibility, FFT ocean, etc. |

---

## 2. Godotwind's 4-Tier Visibility System

### 2.1 Tier Definitions

The system divides rendering into 4 distance-based tiers:

```
NEAR  (0-150m)     Full Node3D with physics/collision
MID   (150-500m)   MultiMesh LOD instances (3 sub-levels: LOD1/LOD2/LOD3)
FAR   (500-5000m)  Octahedral impostor billboards
HORIZON (5km+)    Skybox only
```

**Configuration Source:** `src/core/world/distance_utils.gd` (single source of truth)

### 2.2 Architecture Diagram

```
WorldStreamingManager (orchestrator)
├── DistanceTierManager (UNIFIED VISIBILITY AUTHORITY)
│   ├── CPU path: Per-object tier calculation with hysteresis
│   ├── GPU path: Compute shader for 600+ objects (<1ms for 10K objects)
│   └── Sparse readback: Only returns changed objects O(changes) not O(n)
│
├── ObjectStreamer (per-object LOD coordinator)
│   ├── NEAR: Direct Node3D children (pooled, 2048 max)
│   ├── MID: Delegates to LODMultiMeshBatcher
│   │   └── 3 LOD levels: LOD1 (150-250m), LOD2 (250-375m), LOD3 (375-500m)
│   └── FAR: Delegates to ImpostorManager
│
├── LODMultiMeshBatcher
│   ├── Batches instances by (mesh_rid, lod_level)
│   ├── 256 initial capacity (pre-warmed)
│   ├── Per-instance fade via INSTANCE_CUSTOM.x
│   └── GPU buffer support for Godot 4.4+
│
├── ImpostorManager
│   ├── STANDALONE impostors: Cell-level visibility (cheap)
│   ├── LOD-MANAGED impostors: Object-level crossfade (quality)
│   ├── Texture array batching (single draw call)
│   ├── 16-frame octahedral atlas per model
│   └── Async texture loading via BackgroundJobSystem
│
├── CellManager (cell loading/parsing)
│   ├── 117m cells (Morrowind standard)
│   ├── Async loading with time budgets
│   └── Deferred object registration
│
└── GPUVisibilityManager (compute acceleration)
    ├── 65,536 objects max
    ├── Workgroup size: 256 threads
    ├── Sparse readback with atomic counters
    └── Hysteresis in shader
```

### 2.3 Key Files

| File | Purpose |
|------|---------|
| `src/core/world/distance_tier_manager.gd` | Unified visibility authority |
| `src/core/world/object_streamer.gd` | Per-object LOD lifecycle |
| `src/core/world/lod_multimesh_batcher.gd` | MID tier MultiMesh batching |
| `src/core/world/impostor_manager.gd` | FAR tier impostor rendering |
| `src/core/world/gpu_visibility_manager.gd` | GPU compute visibility |
| `src/core/world/shaders/visibility_compute.glsl` | GPU tier calculation |
| `src/core/world/shaders/lod_crossfade_multimesh.gdshader` | Dithered LOD fading |
| `src/core/world/world_streaming_manager.gd` | Top-level orchestrator |
| `src/core/world/distance_utils.gd` | Centralized distance config |
| `src/core/world/streaming_config.gd` | Quality presets |

---

## 3. Asset Pipeline: Prebaking Requirements

### 3.1 Overview

For the Morrowind port, all assets must go through a **prebaking pipeline** before runtime use. The streaming system does NOT convert assets at runtime - it only loads prebaked resources.

### 3.2 Prebaking Pipeline

```
Source Assets (Morrowind)          Prebaked Assets (Godot)
─────────────────────────          ────────────────────────
NIF meshes (.nif)         ──────►  Godot resources (.res)
                                   ├── Full geometry (LOD0)
                                   ├── LOD1 mesh (simplified)
                                   ├── LOD2 mesh (more simplified)
                                   └── LOD3 mesh (minimal)

DDS/TGA textures          ──────►  Converted textures (.png/.webp)

Model + camera renders    ──────►  Impostor atlases
                                   ├── 16-frame octahedral atlas (.png)
                                   └── Metadata (.json)
```

### 3.3 Prebaking Components

| Component | Tool | Output | Status |
|-----------|------|--------|--------|
| **Models** | `NIFConverter` via `PrebakingManager` | `.res` files with embedded LODs | Working |
| **LODs** | Generated during model conversion | Embedded in `.res` | **Material issues** |
| **Impostors** | `ImpostorBakerV2` | `.png` atlas + `.json` metadata | Working |
| **Terrain** | `TerrainManager` | Terrain3D regions | Working |
| **NavMeshes** | `NavMeshBaker` | Navigation meshes | Working |

### 3.4 Prebaking UI

Access via: `src/tools/prebaking/prebaking_ui.gd`

```
PrebakingManager
├── ModelPrebaker
│   └── NIFConverter (with embedded LOD generation)
├── ImpostorBakerV2
│   └── Octahedral texture atlases
├── NavMeshBaker
├── ShoreMaskBaker
└── TerrainManager (Terrain3D preprocessing)
```

### 3.5 Known Prebaking Issues

#### LOD Material Problems

**Status:** LOD prebaking has material issues that need resolution.

**Symptoms:**
- LOD meshes may render with incorrect or missing materials
- Material properties not correctly transferred from LOD0 to LOD1/2/3
- Crossfade materials may fail to create due to null source materials

**Root Cause:** During LOD mesh generation, material references may be lost or incorrectly assigned.

**Affected Files:**
- `src/core/nif/nif_converter.gd` - LOD generation during NIF conversion
- `src/core/world/lod_multimesh_batcher.gd` - Material creation for batches
- `src/core/world/object_streamer.gd` - LOD mesh extraction and caching

**Workaround:** Currently, MID tier rendering may not display correctly until material pipeline is fixed.

### 3.6 Runtime Model Loading

At runtime, `model_loader.gd` follows this path:

```gdscript
func get_model(model_path, item_id):
    # 1. Check memory cache (fastest)
    if model_path in _memory_cache:
        return _memory_cache[model_path]

    # 2. Check disk cache (fast - loads .res directly)
    if enable_disk_cache and _disk_cache_exists(model_path):
        return _load_from_disk_cache(model_path)

    # 3. RUNTIME MODE: Return null (no conversion at runtime!)
    if not _is_prebaking_mode:
        return null  # Model not prebaked - won't render

    # 4. PREBAKING MODE ONLY: Convert NIF and save to cache
    # ... conversion code ...
```

**Critical:** If a model isn't prebaked, it returns `null` at runtime and won't render.

---

## 4. Detailed Component Analysis

### 4.1 DistanceTierManager - The Visibility Authority

**Design Pattern:** Single Source of Truth

The `DistanceTierManager` is the **only system** that calculates visibility. All other components query it rather than computing distances themselves.

**Key Features:**
- Per-object hysteresis (prevents tier flickering)
- Frustum culling for MID/FAR tiers
- Camera position-based distances (not cell-center)
- GPU acceleration threshold: Enable at 600 objects, disable at 400 (hysteresis)

**GPU Compute Path:**
```
Objects > 600 → GPU compute shader
  ├── Parallel distance calculation (256 threads/workgroup)
  ├── Hysteresis logic in shader
  ├── Atomic counter for tier changes
  └── Sparse readback: Only read changed objects
```

**Performance:**
- CPU path: ~20ms for 7,000 objects
- GPU path: <1ms for 10,000 objects
- Sparse readback: ~0.05ms when stable

### 4.2 ObjectStreamer - LOD Lifecycle Management

**Responsibilities:**
- Receives tier assignments from `DistanceTierManager`
- Manages object lifecycle across NEAR/MID/FAR tiers
- Delegates rendering to specialized systems
- Does NOT calculate visibility itself

**Object Pool:**
- Max 2048 Node3D instances
- Max-heap for O(log n) eviction of farthest objects
- 5-second keepalive before freeing hidden objects

**Crossfade Coordination:**
- 30m overlap zones at tier boundaries
- 4x4 Bayer matrix dithering (requires TAA)
- Both tiers visible during transition

### 4.3 LODMultiMeshBatcher - MID Tier Rendering

**Batching Strategy:**
- Groups instances by (mesh_rid, lod_level)
- Single draw call per batch
- Initial capacity: 256 (minimizes growth copies)
- Max: 4096 instances per batch

**Per-Instance Data:**
```gdscript
INSTANCE_CUSTOM.x = fade_amount  # 0.0-1.0
```

**GPU Features (Godot 4.4+):**
- `multimesh_allocate_data(use_indirect=true)`
- `multimesh_get_buffer_rd_rid()` for compute access
- Prepared for GPU-driven visibility (not fully enabled)

### 4.4 ImpostorManager - FAR Tier Rendering

**Dual Impostor System:**

| Type | Visibility | Crossfade | Use Case |
|------|-----------|-----------|----------|
| Standalone | Cell-level | None (instant) | Trees, rocks, clutter |
| LOD-managed | Object-level | Dithered | Landmarks, buildings |

**Why Two Systems?**
- Not every object needs a full LOD chain
- Common vegetation uses standalone (very cheap)
- Important landmarks use LOD-managed (high quality)

**Technical Details:**
- 16-frame octahedral atlas per model
- Texture array: 512 layers max
- Async loading via 2 worker threads
- Y-axis billboards (face camera horizontally)

### 4.5 GPU Visibility Compute Shader

**File:** `src/core/world/shaders/visibility_compute.glsl`

```glsl
layout(local_size_x = 256) in;

// Per-object tier calculation with hysteresis
uint calculate_tier_with_hysteresis(uint prev_tier, float dist_sq) {
    // Switch on previous tier to determine thresholds
    // NEAR objects need to move further to leave NEAR
    // MID objects need to move closer to enter NEAR
    // etc.
}

// Sparse readback: Only output changed objects
if (did_change) {
    uint slot = atomicAdd(change_count, 1u);
    if (slot < MAX_CHANGES) {
        // Pack: (index << 8) | (old_tier << 4) | new_tier
        changed_data[slot] = packed;
    }
}
```

---

## 5. Audit Findings

### 5.1 What's Working Well

1. **Unified Visibility Authority**: Single source of truth prevents inconsistencies
2. **GPU Compute Acceleration**: 20x speedup for visibility calculations
3. **Sparse Readback**: O(changes) instead of O(all_objects)
4. **Screen-Door Dithering**: Industry-standard crossfade technique
5. **Dual Impostor System**: Balances quality and performance
6. **Object Pooling**: Reduces allocation overhead
7. **Time-Budgeted Instantiation**: Prevents frame spikes
8. **Hysteresis**: Prevents tier flickering

### 5.2 Current Issues and Gaps

#### Issue 1: LOD Material Pipeline Broken

**Observation:** LOD prebaking has material issues that prevent proper MID tier rendering.

**Details:**
- LOD meshes generated during NIF conversion may lose material references
- `_create_crossfade_material()` requires source material which may be null
- Materials not correctly transferred from LOD0 to simplified LOD meshes

**Impact:** MID tier (150-500m) may not render correctly even with prebaked models.

#### Issue 2: LOD Meshes Require Prebaking

**Observation:** The code is well-structured, but runtime depends entirely on prebaked assets.

1. **LOD mesh extraction depends on prebaking**: `model_loader.gd` returns null at runtime if disk cache misses
2. **`lod_meshes_loaded` flag**: If this is false, MID tier won't render
3. **No fallback**: Unlike some engines, there's no automatic LOD generation at runtime

#### Issue 3: Distant Rendering Toggle (`distant_tiers_enabled`) - RESOLVED

**Status:** FIXED in January 2026 simplification.

`distant_tiers_enabled` now defaults to `true` in `object_streamer.gd`. MID/FAR tiers are always active.

#### Issue 4: Phase 2 GPU-Driven Not Fully Connected - DISABLED

**Status:** Phase 2 GPU visibility code is kept but disabled for simplification.

The Phase 2 GPU path (`GPUVisibilityRenderer`) was partially integrated. It has been disabled to reduce complexity:
- Setup call commented out in `world_streaming_manager.gd`
- `_gpu_driven_enabled` stays `false`
- Code preserved for future completion

#### Issue 5: Godot's Built-in `visibility_range` Not Used

**Finding:** The custom system is more sophisticated, but Godot's built-in `visibility_range_begin/end` on `MeshInstance3D` would provide a fallback culling layer essentially for free.

### 5.3 Performance Bottlenecks

| Component | Current | Optimal | Issue |
|-----------|---------|---------|-------|
| GPU visibility | <1ms | <1ms | Good |
| Sparse readback | <0.1ms | <0.1ms | Good |
| MultiMesh rebuild | ~2ms/batch | <1ms | Batch rebuilds could be deferred more |
| Impostor texture array | ~100ms | <50ms | Large texture rebuilds block main thread |
| Object instantiation | 30ms budget | Variable | Increased from 12ms, burst mode uses 50ms |
| Queue sorting | DISABLED | 0ms | FIFO order is sufficient, no sorting overhead |

---

## 6. Improvement Recommendations

### 6.1 Critical: Fix LOD Material Pipeline

**Priority:** HIGH - Required for MID tier rendering

1. **Audit `nif_converter.gd` LOD generation**
   - Ensure materials are correctly assigned to simplified meshes
   - Verify material references survive the simplification process

2. **Fix `lod_multimesh_batcher.gd` material handling**
   - Add fallback for null materials
   - Create default material when source is missing

3. **Test end-to-end LOD pipeline**
   - Prebake a model, verify LOD1/2/3 have correct materials
   - Load at runtime, verify MID tier renders

### 6.2 Quick Wins (Low Effort, High Impact)

1. ~~**Enable `distant_tiers_enabled` by default**~~ **DONE**
   - `distant_tiers_enabled = true` is now default in `object_streamer.gd`
   - MID/FAR tier system is always active

2. **Add Godot's `visibility_range` as backup culling**
   - Set `visibility_range_end` on NEAR tier Node3D instances
   - Zero performance cost, provides backup culling

3. **Reduce impostor texture array rebuild frequency**
   - Current: Rebuilds whenever textures load
   - Better: Batch multiple textures, rebuild every 500ms max

### 6.3 Medium Effort Improvements

4. **Complete Phase 2 GPU-Driven Visibility**
   - Wire up `GPUVisibilityRenderer` activation
   - Enable `multimesh_allocate_data(use_indirect=true)`
   - Direct GPU buffer writes for MID/FAR visibility

5. **Implement Texture LOD System**
   - Currently: Only mipmap-based
   - Better: Aggressive texture resolution downsampling at distance
   - 4K textures → 512x512 at 500m+

6. **Per-Impostor Frustum Culling**
   - Current: Cell-level frustum culling only
   - Better: Skip individual impostors outside view frustum

### 6.4 Advanced Optimizations

7. **Compute Shader Draw Call Counts (Indirect Drawing)**
   - GPU compute determines how many instances to draw
   - No CPU readback needed at all
   - Requires Godot 4.4+ with full indirect support

8. **Tile-Based Compute Processing**
   - Current: Process all objects every frame
   - Better: Spatial tiles, only process tiles that intersect tier boundaries

9. **Octahedral Impostor Rotation**
   - Current: Billboards always face camera
   - Better: Select from multiple angles for tall structures

---

## 7. Summary: Is the System Working Correctly?

### Prebaking Pipeline

| Asset Type | Status | Notes |
|------------|--------|-------|
| Models (.nif → .res) | Working | NIFConverter handles conversion |
| LOD meshes | **Material Issues** | LODs generated but materials broken |
| Impostors | Working | 16-frame octahedral atlases |
| Terrain | Working | Terrain3D integration |

### Runtime Rendering

| Tier | Status | Blockers |
|------|--------|----------|
| **NEAR (0-150m)** | Working | Requires prebaked .res files |
| **MID (150-500m)** | **Needs Testing** | Material issues may persist, `distant_tiers_enabled` now true |
| **FAR (500-5000m)** | Working | Requires prebaked impostors, always active |

### Best of Godot Features: Mostly Yes

- **MultiMesh**: Yes, heavily used for MID tier batching
- **Compute shaders**: Yes, for visibility calculations
- **RenderingServer**: Yes, for GPU buffer access
- **Texture arrays**: Yes, for impostor batching
- **Built-in visibility_range**: NO - custom system used instead

### Overall Assessment

The architecture is **production-grade and well-designed**, following industry best practices.

**Resolved Issues (January 2026):**
1. ~~Activation issues~~ - `distant_tiers_enabled` now defaults to true
2. ~~NEAR_ONLY mode confusion~~ - Removed, always uses FULL_AAA
3. ~~Queue sorting overhead~~ - Disabled, using FIFO order

**Remaining Issues:**
1. **LOD material pipeline** - MID tier may have material issues

---

## 8. Next Steps

### Immediate Actions

1. **Test NEAR tier performance** with increased budgets (30ms, 300 objects/frame)
   - Monitor FPS during initial world load
   - Verify objects appear faster than before

2. **Fix LOD material pipeline** in `nif_converter.gd` if MID tier has issues
   - Audit material assignment during mesh simplification
   - Test with a single model end-to-end

### Future Work

3. **Complete Phase 2 GPU-driven mode** (currently disabled)
4. **Add runtime LOD fallback** (generate simplified mesh if prebake missing)
5. **Integrate Godot's `visibility_range`** as backup culling

---

*Document generated by Claude Code architecture analysis*
*Last updated: January 2026 (Simplified architecture)*
