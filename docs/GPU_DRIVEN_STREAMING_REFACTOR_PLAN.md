# GPU-Driven Streaming Architecture Refactor Plan

## Implementation Status (Updated 2026-01-02)

| Phase | Status | Notes |
|-------|--------|-------|
| Phase 1: Foundation Cleanup | ✅ Complete | Sparse readback, incremental stats |
| Phase 2: GPU-Controlled MID/FAR | ✅ Complete | MID/FAR visibility via GPU compute |
| Phase 3: NEAR Tier Sparse Updates | ✅ Complete | Sparse change buffer for CPU handling |
| Phase 4: Object Registration Optimization | ⏳ Pending | Batch registration API |

### Phase 2 Implementation Details

**MID Tier (MultiMesh LODs)**:
- `GPUVisibilityRenderer` computes visibility for all registered objects
- Visibility applied via `custom_data` only (no transform updates needed)
- Connected to `LODMultiMeshBatcher` via `set_batcher()`

**FAR Tier (Impostors)**:
- `ImpostorManager` connected via `set_impostor_manager()`
- GPU-driven mode enabled automatically when Phase 2 active
- CPU `update_visibility()` bypassed when GPU mode active

**NEAR Tier**:
- Sparse change buffer outputs only objects transitioning to/from NEAR
- CPU processes these changes for Node3D instantiation/pooling

## Comprehensive Audit Summary (2026-01-02)

### Industry Compliance ✅

The following techniques are correctly implemented per AAA standards:

| Technique | Status | Reference |
|-----------|--------|-----------|
| 3-Tier LOD (NEAR/MID/FAR) | ✅ Correct | Horizon Zero Dawn pattern |
| GPU Compute Visibility | ✅ Correct | visibility_compute.glsl w/ sparse readback |
| Screen-Door Dithering | ✅ Correct | 4x4 Bayer matrix (Witcher 3/HZD) |
| Time-Based Crossfade | ✅ Correct | 0.3s event-driven fades |
| Object Pooling | ✅ Correct | 2048 pool w/ eviction |
| Texture Array Batching | ✅ Correct | 512-layer impostor array |
| Hysteresis Anti-Flicker | ✅ Correct | Per-tier enter/exit thresholds |
| Chunk-Based FAR Tier | ✅ Correct | 8x8 chunks, 35x reduction |

### Known Gaps

| Issue | Priority | Notes |
|-------|----------|-------|
| Frustum culling disabled | HIGH | Bug in frustum test - filtered ALL cells |
| No HZB occlusion in compute | LOW | Godot limitation - using built-in culling |
| Async mesh loading | LOW | Currently synchronous on cache miss |

### Key Files Updated

- `gpu_visibility_renderer.gd` - New GPU-driven renderer using Godot 4.4 APIs
- `gpu_visibility_compute.glsl` - Compute shader for tier/visibility calculation
- `lod_multimesh_batcher.gd` - Added `use_indirect` support for GPU-driven batches
- `world_streaming_manager.gd` - Enabled Phase 2 GPU visibility path

### Godot 4.4 API Availability

The implementation now correctly uses Godot 4.4's new APIs:
- ✅ `multimesh_get_buffer_rd_rid()` - [PR #98788](https://github.com/godotengine/godot/pull/98788)
- ✅ `multimesh_allocate_data(..., use_indirect=true)` - [PR #99455](https://github.com/godotengine/godot/pull/99455)

---

## Executive Summary

This document outlines a major architectural refactor to implement true GPU-driven visibility for Godotwind's streaming system. The goal is to eliminate CPU-GPU synchronization bottlenecks and create a future-proof open-world framework capable of handling 100,000+ objects at 60 FPS.

**Current State:** ~60ms/frame streaming overhead (target: <5ms)
**Root Cause:** CPU readback of GPU visibility results + O(n) iterations every frame
**Solution:** Hybrid architecture where GPU controls MID/FAR rendering directly, CPU only manages NEAR tier

---

## Table of Contents

1. [Problem Analysis](#problem-analysis)
2. [Industry Standard Architecture](#industry-standard-architecture)
3. [Godot 4 Constraints](#godot-4-constraints)
4. [Proposed Architecture](#proposed-architecture)
5. [Implementation Phases](#implementation-phases)
6. [Technical Challenges](#technical-challenges)
7. [File Changes Summary](#file-changes-summary)
8. [Testing Strategy](#testing-strategy)
9. [References](#references)

---

## Problem Analysis

### Current Performance Issues

| Issue | Location | Impact |
|-------|----------|--------|
| Full buffer upload every frame | `gpu_visibility_manager.gd:827` | 10-20ms |
| O(n) tier array rebuild | `gpu_visibility_manager.gd:864-876` | 30-50ms |
| O(n) stats update on register | `object_streamer.gd:2463-2479` | 50ms+ initial |
| Synchronous GPU readback | `gpu_visibility_manager.gd:601-603` | 1-5ms |

### Why Current GPU Approach Fails

The current implementation uses GPU compute to calculate tiers, then **reads results back to CPU**, then CPU tells MultiMesh/Impostors what to show. This defeats the purpose of GPU compute:

```
Current Flow (BAD):
┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────────┐
│   GPU   │───>│   CPU   │───>│   GPU   │───>│   Render    │
│ Compute │    │ Readback│    │ Upload  │    │  (finally)  │
└─────────┘    └─────────┘    └─────────┘    └─────────────┘
     ↑              │              │
     │              ▼              │
     │         STALL HERE          │
     │         (sync wait)         │
     └─────────────────────────────┘
```

### Object Counts (Typical Scene)

- **NEAR tier (0-150m):** ~200-500 objects (need Node3D + physics)
- **MID tier (150-500m):** ~1,500-3,000 objects (LOD meshes via MultiMesh)
- **FAR tier (500-5000m):** ~3,000-6,000 objects (impostors)
- **Total tracked:** ~5,000-10,000 objects

---

## Industry Standard Architecture

### What AAA Games Do

From [Vulkan Guide - GPU Driven Engines](https://vkguide.dev/docs/gpudriven/gpu_driven_engines/):

> "The engine can render huge scenes at high performance because it will only render whatever is visible on the screen, **without a roundtrip to the CPU**."

Key principles:

1. **Zero CPU Readback**: GPU decides visibility, GPU controls rendering
2. **Indirect Draw Commands**: `DrawIndirect`/`MultiDrawIndirect` let GPU control instance counts
3. **Bindless Resources**: All meshes/textures in large arrays, indexed by GPU
4. **1-3 Frame Latency Accepted**: Stale visibility data is OK with enlarged bounds

### Reference Implementations

| Engine | Approach | Objects | Performance |
|--------|----------|---------|-------------|
| Nanite (UE5) | Visibility buffer, software rasterizer | Millions | 60+ FPS |
| DOOM Eternal | <500 pipelines, ubershaders | 250K+ | 60+ FPS |
| Wicked Engine | HiZ occlusion, predicated queries | 100K+ | 60+ FPS |
| RDR2 | Amortized streaming, LOD crossfade | 500K+ | 30 FPS |

---

## Godot 4 Constraints

### Godot 4.4+ GPU Features (Available Now)

These APIs were added in Godot 4.4 and enable true GPU-driven rendering:

1. **`multimesh_get_buffer_rd_rid()`** - [PR #98788](https://github.com/godotengine/godot/pull/98788), merged Nov 2024
   - Returns the RenderingDevice RID of the MultiMesh buffer
   - Allows compute shaders to directly access/write to the buffer

2. **`multimesh_allocate_data()` with `use_indirect`** - [PR #99455](https://github.com/godotengine/godot/pull/99455), merged Jan 2025
   - New 6th parameter enables GPU-controlled instance counts
   - Compute shaders can modify visible instance count without CPU

3. **Compute Shaders**: Full RenderingDevice access, GLSL compute
4. **INSTANCE_CUSTOM Data**: 4 floats per instance (fade, visibility, tier)
5. **Shader Instance ID**: `INSTANCE_ID` available in vertex shader

### Known Limitations

1. **Compute Buffer → Visual Shader**: Cannot directly bind storage buffers to materials ([Issue #6989](https://github.com/godotengine/godot-proposals/issues/6989))
2. **Async Readback**: `buffer_get_data_async` has issues in 4.4.x ([Issue #105256](https://github.com/godotengine/godot/issues/105256))
3. **Buffer Sync Issue**: Without `use_indirect`, compute writes don't render until `set_buffer()` is called ([Issue #105100](https://github.com/godotengine/godot/issues/105100))

### Our Implementation Approach

With Godot 4.4's new APIs, we can now use **GPU-driven visibility** without full CPU roundtrip:

1. **Setup**: Allocate MultiMesh with `use_indirect=true`
2. **Per-frame GPU**: Compute shader calculates visibility and writes directly to buffer
3. **Visibility control**: Zero-scale transforms hide instances (GPU culled)
4. **NEAR tier only**: CPU reads sparse changes for Node3D instantiation

**Key insight**: With `use_indirect=true`, the GPU can control what renders without CPU involvement for MID/FAR tiers. Only NEAR tier changes (for physics/interaction) need CPU readback.

---

## Proposed Architecture

### High-Level Design

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         WorldStreamingManager                            │
│                         (Orchestrator - Minimal)                         │
└───────────────────────────────────┬─────────────────────────────────────┘
                                    │
         ┌──────────────────────────┼──────────────────────────┐
         │                          │                          │
         ▼                          ▼                          ▼
┌─────────────────┐      ┌─────────────────────┐      ┌─────────────────┐
│   NEAR Tier     │      │    GPU Visibility   │      │  CellManager    │
│   (CPU-Only)    │      │      Manager        │      │ (Data Loading)  │
│                 │      │                     │      │                 │
│ • Node3D pool   │      │ • Compute shader    │      │ • Async ESM     │
│ • Physics       │      │ • Position buffer   │      │ • Object index  │
│ • 200-500 objs  │      │ • Tier output       │      │ • Cell queue    │
│ • CPU distance  │      │ • No CPU readback   │      │                 │
└────────┬────────┘      └──────────┬──────────┘      └─────────────────┘
         │                          │
         │              ┌───────────┴───────────┐
         │              │                       │
         │              ▼                       ▼
         │    ┌─────────────────┐     ┌─────────────────┐
         │    │  MID Tier GPU   │     │  FAR Tier GPU   │
         │    │   Renderer      │     │   Renderer      │
         │    │                 │     │                 │
         │    │ • MultiMesh     │     │ • MultiMesh     │
         │    │ • LOD1/2/3      │     │ • Impostors     │
         │    │ • GPU fade      │     │ • GPU fade      │
         │    │ • 1.5-3K objs   │     │ • 3-6K objs     │
         │    └─────────────────┘     └─────────────────┘
         │              │                       │
         │              └───────────┬───────────┘
         │                          │
         ▼                          ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           Render Frame                                   │
│  • NEAR: Node3D scene tree (CPU-managed visibility)                     │
│  • MID:  MultiMesh draw call (GPU-controlled instance visibility)       │
│  • FAR:  MultiMesh draw call (GPU-controlled instance visibility)       │
└─────────────────────────────────────────────────────────────────────────┘
```

### Data Flow (Per Frame)

```
Frame N:
1. CPU updates camera position in uniform (4 bytes)
2. GPU compute shader:
   - Reads object positions from buffer (static, uploaded once)
   - Calculates distance² for each object
   - Determines tier (NEAR/MID/FAR/HIDDEN)
   - Writes visibility + fade to output buffer
   - Writes NEAR tier object IDs to sparse change buffer (for CPU)

3. CPU (async, uses Frame N-2 data):
   - Reads ONLY NEAR tier changes from sparse buffer (~10-50 objects)
   - Queues Node3D instantiation/destruction
   - Does NOT read MID/FAR tier data

4. GPU rendering:
   - MID MultiMesh: Shader reads visibility from INSTANCE_CUSTOM
   - FAR MultiMesh: Shader reads visibility from INSTANCE_CUSTOM
   - Instances with visibility=0 are scaled to zero (GPU culled)

5. At frame end:
   - GPU copies visibility buffer → INSTANCE_CUSTOM buffers
   - No CPU involvement for MID/FAR visibility
```

### Key Differences from Current System

| Aspect | Current | Proposed |
|--------|---------|----------|
| MID/FAR visibility | CPU reads from GPU, applies per-object | GPU writes directly, shader culls |
| Tier changes | CPU iterates all objects | GPU writes, CPU reads only NEAR changes |
| Fade calculation | CPU per-object per-frame | GPU shader, time-based uniform |
| Buffer uploads | Every frame (1MB+) | Once on register, sparse updates |
| CPU involvement | O(all objects) | O(NEAR objects only) |

---

## Implementation Phases

### Phase 1: Foundation Cleanup (3-5 days)

**Goal:** Fix immediate O(n) issues without architectural changes.

**Tasks:**

1. **Remove unconditional buffer dirty flag**
   - File: `gpu_visibility_manager.gd:827`
   - Change: Only set `_buffers_dirty = true` when objects registered/unregistered/moved

2. **Incremental stats tracking**
   - File: `object_streamer.gd:2463-2479`
   - Change: Track `_deferred_count` and `_instantiated_count` incrementally

3. **Return dictionary sets directly**
   - File: `gpu_visibility_manager.gd:860-883`
   - Change: Don't rebuild arrays from sets; return sets or keep arrays synchronized incrementally

4. **Reduce CPU-side tier iteration**
   - File: `distance_tier_manager.gd:301` (loop over `_registered_objects`)
   - Change: Only iterate objects near tier boundaries using spatial index

**Success Criteria:** Streaming overhead < 20ms/frame

---

### Phase 2: GPU-Controlled MID/FAR Rendering (1-2 weeks)

**Goal:** GPU controls MultiMesh visibility without CPU readback.

**Tasks:**

1. **Create GPUVisibilityRenderer class**
   - New file: `src/core/world/gpu_visibility_renderer.gd`
   - Manages MID and FAR tier MultiMeshes
   - Uploads object positions once on registration
   - Compute shader calculates visibility + fade per frame
   - Copies results to INSTANCE_CUSTOM buffer (GPU-to-GPU)

2. **Modify LODMultiMeshBatcher for GPU control**
   - File: `lod_multimesh_batcher.gd`
   - Add: Method to expose MultiMesh buffer RID
   - Add: Support for external INSTANCE_CUSTOM updates
   - Remove: CPU-side `update_fade()` per-object calls

3. **Modify ImpostorManager for GPU control**
   - File: `impostor_manager.gd`
   - Add: Method to expose MultiMesh buffer RID
   - Add: Support for GPU-driven visibility
   - Remove: CPU-side visibility calculations

4. **Create unified visibility compute shader**
   - New file: `src/core/world/shaders/unified_visibility.glsl`
   - Input: Camera position, object positions, tier thresholds
   - Output: Per-object visibility (0/1) + fade (0-1) + tier (for NEAR sparse)
   - Sparse output: NEAR tier changes only (atomic counter + compact buffer)

5. **Modify crossfade shaders for GPU visibility**
   - Files: `lod_crossfade_node3d.gdshader`, impostor shader
   - Add: Read `INSTANCE_CUSTOM.w` as visibility multiplier
   - Add: Scale to zero when visibility = 0 (GPU cull)

**Challenges:**

- **GPU-to-GPU buffer copy**: Need to copy compute output to MultiMesh INSTANCE_CUSTOM
  - Solution: Use `RenderingDevice.buffer_copy()` or compute shader write to same buffer
  - Alternative: Use `RenderingServer.multimesh_set_buffer()` with byte array (requires CPU touch)

- **MultiMesh buffer format**: INSTANCE_CUSTOM is interleaved with transforms
  - Solution: Compute shader must write to correct stride offsets
  - Reference: MultiMesh buffer layout is `[Transform3D (48 bytes) + Color (16 bytes) + Custom (16 bytes)]` per instance

**Success Criteria:** MID/FAR visibility updates without CPU tier iteration

---

### Phase 3: NEAR Tier Sparse Updates (1 week)

**Goal:** CPU only processes NEAR tier changes, not all objects.

**Tasks:**

1. **Implement sparse NEAR readback**
   - GPU writes NEAR tier changes to compact buffer (object_id, old_tier, new_tier)
   - CPU reads only this buffer (~10-50 entries per frame)
   - CPU queues Node3D instantiation/destruction

2. **Implement 2-frame latency tolerance**
   - NEAR tier boundary expanded by `player_speed * 2_frames * safety_margin`
   - Objects enter NEAR tier early, leave late
   - Prevents popping when using stale GPU data

3. **Remove ObjectStreamer's full object iteration**
   - File: `object_streamer.gd`
   - Change: `update()` only processes NEAR tier queue
   - MID/FAR completely hands-off

**Success Criteria:** ObjectStreamer.update() < 2ms

---

### Phase 4: Object Registration Optimization (3-5 days)

**Goal:** Eliminate O(n) operations during object registration.

**Tasks:**

1. **Batch registration API**
   - New method: `register_objects_batch(objects: Array[ObjectData])`
   - Single buffer upload for multiple objects
   - Single stats update

2. **Lazy MultiMesh capacity growth**
   - Pre-allocate capacity based on cell object density
   - Avoid per-object growth operations

3. **Streaming buffer uploads**
   - Upload positions in chunks over multiple frames
   - Prevents frame spike during initial load

**Success Criteria:** Initial load spike < 100ms

---

### Phase 5: Advanced Optimizations (Future)

**Goal:** Further performance improvements for very large worlds.

**Tasks:**

1. **Hierarchical visibility (HLOD)**
   - Cluster distant objects into single impostor
   - Reduce FAR tier object count 10x

2. **Temporal reprojection**
   - Use previous frame depth for occlusion
   - Skip compute for occluded regions

3. **LOD crossfade in compute**
   - Calculate MID tier LOD level in GPU
   - Write to INSTANCE_CUSTOM.y for shader LOD selection

**Success Criteria:** Support 100K+ objects at 60 FPS

---

## Technical Challenges

### Challenge 1: GPU-to-MultiMesh Buffer Copy

**Problem:** Godot's MultiMesh buffer is managed internally. We need to write compute results to it.

**Solutions (in order of preference):**

1. **Direct buffer access via RID** (Best if possible)
   ```gdscript
   var mm_rid := multimesh.get_rid()
   var buffer_rid := RenderingServer.multimesh_get_buffer_rid(mm_rid)  # May not exist
   rd.buffer_copy(compute_output_rid, buffer_rid, ...)
   ```

2. **RenderingServer.multimesh_set_buffer()** (Works but touches CPU)
   ```gdscript
   var data := rd.buffer_get_data(compute_output_rid)  # Sync readback
   RenderingServer.multimesh_set_buffer(mm_rid, data)
   ```

3. **Compute shader writes to same buffer** (Requires buffer sharing)
   - Create buffer via RenderingDevice
   - Share with MultiMesh (may not be possible in current Godot)

4. **Per-instance updates** (Fallback, slow)
   ```gdscript
   for i in range(instance_count):
       multimesh.set_instance_custom_data(i, Color(vis, fade, 0, 0))
   ```

**Research needed:** Test if `RenderingServer` exposes MultiMesh buffer RID.

---

### Challenge 2: Compute Shader Synchronization

**Problem:** Compute shader must complete before rendering uses the visibility data.

**Solutions:**

1. **Barrier in compute shader**
   - Use `memoryBarrierBuffer()` before writing final results
   - Godot handles render/compute synchronization

2. **Double buffering**
   - Frame N: Render with visibility from Frame N-1
   - Frame N: Compute visibility for Frame N
   - 1-frame latency (acceptable)

3. **Explicit sync point**
   ```gdscript
   rd.submit()
   rd.sync()  # Bad but works
   ```

**Recommendation:** Use double buffering with 1-frame latency.

---

### Challenge 3: INSTANCE_CUSTOM Buffer Layout

**Problem:** MultiMesh interleaves transform + color + custom data. Compute shader must write to correct offsets.

**MultiMesh Buffer Layout (with custom data enabled):**
```
Instance 0: Transform3D (48 bytes) + Color (16 bytes) + Custom (16 bytes) = 80 bytes
Instance 1: Transform3D (48 bytes) + Color (16 bytes) + Custom (16 bytes) = 80 bytes
...
```

**Compute Shader Write Pattern:**
```glsl
uint instance_stride = 80;  // bytes
uint custom_offset = 64;    // after transform + color

uint byte_offset = instance_id * instance_stride + custom_offset;
// Write visibility to custom.x (first float of custom data)
output_buffer[byte_offset / 4] = visibility;  // As uint for atomics
```

**Note:** Verify actual buffer layout in Godot source or via experimentation.

---

### Challenge 4: Handling Object Movement

**Problem:** Objects can move (NPCs, physics). Position buffer becomes stale.

**Solutions:**

1. **Static vs Dynamic objects**
   - Static: Upload once, never update
   - Dynamic: Track dirty set, upload changed positions each frame

2. **Hybrid approach**
   - Most objects static (terrain, buildings, flora)
   - Dynamic objects use separate smaller buffer
   - Or: Dynamic objects always NEAR tier (CPU-managed)

3. **Per-frame position update region**
   - Only update positions in current cell + neighbors
   - ~500 objects max per frame

**Recommendation:** Treat all MID/FAR objects as static. Dynamic objects stay in NEAR tier.

---

## File Changes Summary

### New Files

| File | Purpose |
|------|---------|
| `src/core/world/gpu_visibility_renderer.gd` | GPU-driven MID/FAR tier renderer |
| `src/core/world/shaders/unified_visibility.glsl` | Combined visibility compute shader |
| `src/core/world/near_tier_manager.gd` | CPU-only NEAR tier with sparse GPU input |

### Modified Files

| File | Changes |
|------|---------|
| `gpu_visibility_manager.gd` | Remove CPU-side tier tracking, add sparse NEAR output |
| `distance_tier_manager.gd` | Delegate MID/FAR to GPU renderer, keep NEAR logic |
| `object_streamer.gd` | Remove MID/FAR visibility logic, NEAR-only focus |
| `lod_multimesh_batcher.gd` | Expose buffer RID, accept external visibility updates |
| `impostor_manager.gd` | Expose buffer RID, accept GPU-driven visibility |
| `world_streaming_manager.gd` | Wire up new components |
| `lod_crossfade_node3d.gdshader` | Add INSTANCE_CUSTOM visibility check |

### Deprecated Files (Remove After Refactor)

| File | Reason |
|------|--------|
| `visibility_compute.glsl` | Replaced by unified shader |

---

## Testing Strategy

### Unit Tests

1. **GPU compute correctness**
   - Known positions → expected tiers
   - Boundary cases (exactly at threshold)
   - Hysteresis behavior

2. **Buffer layout verification**
   - Write known pattern → read back → verify
   - Test INSTANCE_CUSTOM offset calculation

3. **Sparse NEAR output**
   - Move camera → verify only NEAR changes reported
   - Verify no MID/FAR in sparse buffer

### Integration Tests

1. **Visual verification**
   - Objects appear at correct distances
   - Crossfade smooth at tier boundaries
   - No popping or flickering

2. **Performance benchmarks**
   - Measure frame time with 5K, 10K, 50K objects
   - Profile GPU compute time
   - Profile CPU overhead (should be minimal)

3. **Stress tests**
   - Fast camera movement
   - Teleportation
   - Object spawn/despawn bursts

### Compatibility Tests

1. **GPU fallback**
   - Test on hardware without compute shader support
   - Verify CPU fallback works

2. **Different object counts**
   - Empty world
   - Dense city
   - Sparse wilderness

---

## References

### Industry Resources

- [Vulkan Guide - GPU Driven Engines](https://vkguide.dev/docs/gpudriven/gpu_driven_engines/)
- [Vulkan Guide - Compute Culling](https://vkguide.dev/docs/gpudriven/compute_culling/)
- [Wicked Engine 2024 Graphics](https://wickedengine.net/2024/12/wicked-engines-graphics-in-2024/)
- [SIGGRAPH 2024 Advances in Real-Time Rendering](https://advances.realtimerendering.com/s2024/index.html)
- [The Forge Visibility Buffer 2.0](https://x.com/TheForge_FX/status/1788315834383048767)

### Godot Resources

- [Godot Compute Shaders Documentation](https://docs.godotengine.org/en/stable/tutorials/shaders/compute_shaders.html)
- [GPU-Driven Renderer Proposal by Juan Linietsky](https://gist.github.com/reduz/c5769d0e705d8ab7ac187d63be0099b5)
- [Indirect Rendering Discussion #8647](https://github.com/godotengine/godot-proposals/discussions/8647)
- [Compute Buffer to Shader Proposal #6989](https://github.com/godotengine/godot-proposals/issues/6989)
- [MultiMesh Shared Buffer Proposal #12978](https://github.com/godotengine/godot-proposals/issues/12978)
- [Async Readback Bug #105256](https://github.com/godotengine/godot/issues/105256)

### Project Files

- Current GPU visibility: `src/core/world/gpu_visibility_manager.gd`
- Current tier manager: `src/core/world/distance_tier_manager.gd`
- Current object streamer: `src/core/world/object_streamer.gd`
- Current MultiMesh batcher: `src/core/world/lod_multimesh_batcher.gd`
- Current impostor manager: `src/core/world/impostor_manager.gd`
- Streaming config: `src/core/world/streaming_config.gd`

---

## Success Metrics

| Metric | Current | Phase 1 Target | Final Target |
|--------|---------|----------------|--------------|
| Streaming overhead | 60ms+ | <20ms | <5ms |
| ObjectStreamer.update | 157ms | <50ms | <2ms |
| DistanceTierManager.update_visibility | 40ms | <10ms | <1ms |
| Initial load spike | 200ms+ | <150ms | <50ms |
| Max supported objects | ~10K | ~20K | 100K+ |

---

## Glossary

| Term | Definition |
|------|------------|
| **DrawIndirect** | GPU-controlled draw call where instance count comes from GPU buffer |
| **INSTANCE_CUSTOM** | Per-instance vec4 data in MultiMesh, accessible in vertex shader |
| **Sparse Readback** | Reading only changed data instead of all data |
| **Tier** | Distance-based LOD category: NEAR, MID, FAR, HIDDEN |
| **Visibility Buffer** | Technique storing only primitive IDs, deferring shading |
| **HiZ** | Hierarchical Z-buffer for fast occlusion queries |

---

## Appendix A: MultiMesh Buffer Investigation

Before implementing Phase 2, run this test to determine buffer access options:

```gdscript
# Test script to investigate MultiMesh buffer access
extends Node3D

func _ready():
    var mm := MultiMesh.new()
    mm.transform_format = MultiMesh.TRANSFORM_3D
    mm.use_custom_data = true
    mm.instance_count = 10

    var mesh := BoxMesh.new()
    mm.mesh = mesh

    # Get RID
    var mm_rid := mm.get_rid()
    print("MultiMesh RID: ", mm_rid)

    # Try to get buffer
    var rs := RenderingServer

    # Check available methods
    for method in rs.get_method_list():
        if "multimesh" in method.name.to_lower() and "buffer" in method.name.to_lower():
            print("Found method: ", method.name)

    # Try buffer access
    var buffer := rs.multimesh_get_buffer(mm_rid)
    print("Buffer size: ", buffer.size(), " bytes")
    print("Expected per instance: 48 (transform) + 16 (custom) = 64 bytes")
    print("Instance stride: ", buffer.size() / 10, " bytes")
```

Run this and document the output in the implementation PR.

---

## Appendix B: Compute Shader Template

```glsl
#[compute]
#version 450

// Workgroup size - 256 is good balance for most GPUs
layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

// Push constants for per-frame data
layout(push_constant, std430) uniform PushConstants {
    vec4 camera_pos;      // xyz = position, w = unused
    float near_end_sq;    // 150² = 22500
    float mid_end_sq;     // 500² = 250000
    float far_end_sq;     // 5000² = 25000000
    float fade_margin;    // 50.0
    float time;           // For time-based fade animation
    uint object_count;
    uint padding[2];
} pc;

// Object positions (static, uploaded once)
layout(set = 0, binding = 0, std430) readonly buffer Positions {
    vec4 positions[];  // xyz = position, w = object_id
};

// Output: visibility + fade for MID/FAR (GPU rendering)
// Layout matches MultiMesh INSTANCE_CUSTOM: [vis, fade, lod, flags]
layout(set = 0, binding = 1, std430) writeonly buffer VisibilityOutput {
    vec4 visibility[];
};

// Output: sparse NEAR tier changes (CPU readback)
layout(set = 0, binding = 2, std430) buffer NearChanges {
    uint change_count;          // Atomic counter
    uint changes[];             // Packed: object_id | (old_tier << 24) | (new_tier << 28)
};

// Previous frame tiers (for change detection)
layout(set = 0, binding = 3, std430) buffer PrevTiers {
    uint prev_tiers[];  // 0=HIDDEN, 1=FAR, 2=MID, 3=NEAR
};

const uint TIER_HIDDEN = 0;
const uint TIER_FAR = 1;
const uint TIER_MID = 2;
const uint TIER_NEAR = 3;

uint calculate_tier(float dist_sq) {
    if (dist_sq < pc.near_end_sq) return TIER_NEAR;
    if (dist_sq < pc.mid_end_sq) return TIER_MID;
    if (dist_sq < pc.far_end_sq) return TIER_FAR;
    return TIER_HIDDEN;
}

float calculate_fade(float dist_sq, uint tier) {
    // Fade at tier boundaries
    float fade = 1.0;
    float margin_sq = pc.fade_margin * pc.fade_margin;

    if (tier == TIER_MID) {
        // Fade in from NEAR
        float near_boundary = pc.near_end_sq;
        if (dist_sq < near_boundary + margin_sq) {
            fade = smoothstep(near_boundary - margin_sq, near_boundary + margin_sq, dist_sq);
        }
        // Fade out to FAR
        float mid_boundary = pc.mid_end_sq;
        if (dist_sq > mid_boundary - margin_sq) {
            fade = min(fade, 1.0 - smoothstep(mid_boundary - margin_sq, mid_boundary + margin_sq, dist_sq));
        }
    } else if (tier == TIER_FAR) {
        // Fade in from MID
        float mid_boundary = pc.mid_end_sq;
        if (dist_sq < mid_boundary + margin_sq) {
            fade = smoothstep(mid_boundary - margin_sq, mid_boundary + margin_sq, dist_sq);
        }
        // Fade out to HIDDEN
        float far_boundary = pc.far_end_sq;
        if (dist_sq > far_boundary - margin_sq) {
            fade = min(fade, 1.0 - smoothstep(far_boundary - margin_sq, far_boundary + margin_sq, dist_sq));
        }
    }

    return fade;
}

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= pc.object_count) return;

    vec3 obj_pos = positions[idx].xyz;
    vec3 delta = obj_pos - pc.camera_pos.xyz;
    float dist_sq = dot(delta, delta);

    uint new_tier = calculate_tier(dist_sq);
    uint old_tier = prev_tiers[idx];

    // Calculate visibility and fade
    float vis = (new_tier != TIER_HIDDEN) ? 1.0 : 0.0;
    float fade = calculate_fade(dist_sq, new_tier);

    // Write visibility output (for MID/FAR MultiMesh)
    visibility[idx] = vec4(vis, fade, float(new_tier), 0.0);

    // Update prev tier
    prev_tiers[idx] = new_tier;

    // Sparse output for NEAR tier changes only
    if (new_tier == TIER_NEAR || old_tier == TIER_NEAR) {
        if (new_tier != old_tier) {
            uint slot = atomicAdd(change_count, 1);
            // Pack: object_id (20 bits) | old_tier (4 bits) | new_tier (4 bits) | unused (4 bits)
            changes[slot] = idx | (old_tier << 20) | (new_tier << 24);
        }
    }
}
```

---

*Document Version: 1.0*
*Created: 2026-01-02*
*Author: Claude (via Godotwind development)*