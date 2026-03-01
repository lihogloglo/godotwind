# Spec: GPU Scene Database

**Status:** Draft
**Owner:** gemini
**Priority:** Critical (Phase 2 Foundation)

## Context
Godotwind currently manages MID (150-500m) objects via `StaticObjectRenderer` (using `RenderingServer.instance_create()`). While this avoids Node3D overhead, it still requires CPU-side management for thousands of objects and relies on Godot's internal frustum culling. For "next-gen" scale, we need to move the entire MID+FAR scene state to the GPU to enable compute-shader-driven culling and batching.

## Goals
- **GPU-Resident State:** Store transforms, AABBs, and material IDs in SSBOs.
- **Scalability:** Support up to 100,000 objects in a 5km radius.
- **Zero-Latency Updates:** Async streaming of cell data into GPU buffers.
- **Foundation for Culling:** Provide the data structure for the upcoming GPU Culling Compute Pipeline.

## Architecture

### 1. The GPU Scene Database (`src/core/gpu_driven/gpu_scene_database.gd`)
Manages the lifecycle of SSBOs and slot allocation.

**Structures (std430):**
```glsl
struct ObjectData {
    vec4 position_radius;     // xyz: world pos, w: bounding radius
    vec4 aabb_extent_meshID;  // xyz: half-extents, w: mesh_id (as float)
    vec4 transform_col0;      // 3x4 affine transform (col 0)
    vec4 transform_col1;      // 3x4 affine transform (col 1)
    vec4 transform_col2;      // 3x4 affine transform (col 2)
    uint lod_mask;
    uint pad0, pad1, pad2;    // Align to 16 bytes (96 bytes total)
};
```
*Total Stride: 96 bytes/object.*
*100,000 objects = ~9.6MB VRAM.*

### 2. Hybrid Rendering Path
Instead of full `draw_list_draw_indirect()` (which is undocumented/risky in 4.6), we will use a **GPU-Cull/CPU-Sync** hybrid:
1. **GPU Cull**: Compute shader performs frustum/distance culling on the `ObjectData` buffer.
2. **Visibility Bitset**: Shader writes a bitset of visibility results to a small SSBO.
3. **Async Readback**: CPU reads back the visibility bitset (double-buffered, 1-frame latency).
4. **RS Drive**: CPU calls `RenderingServer.instance_set_visible()` based on the bitset.
   - This keeps objects in Godot's standard rendering pipeline (shadows, GI, etc.) while offloading the culling logic to the GPU.

### 3. Synchronization & Barriers
- **Compute Barriers**: Use `RenderingDevice.barrier_add()` to ensure the scene database updates are complete before culling begins.
- **Double Buffering**: Visibility bitsets are ping-ponged to avoid stalling the CPU during readback.

## Success Criteria
- [ ] Successful upload and management of 100k objects without frame hitches.
- [ ] Correct spatial mapping (objects rendered as debug points match their coordinates).
- [ ] >50% reduction in CPU-side culling overhead in dense scenes.


## Next Steps
1. Create `src/core/gpu_driven/gpu_scene_database.gd`.
2. Wire into `NativeStreamingManager` as an optional alternative to `StaticObjectRenderer`.
3. Verify with a "GPU Debug View" in the console.
