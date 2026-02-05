# GPU-Driven Renderer Architecture

**Last Updated:** 2026-02-05
**Status:** Design Phase
**Godot Version:** 4.6
**Related:** [PR #99119 — Vulkan Raytracing Plumbing](https://github.com/godotengine/godot/pull/99119)

---

## Motivation

The current rendering pipeline manages MID (150-500m) and FAR (500-5000m) tier objects via individual `MeshInstance3D` nodes with CPU-side `visibility_range` culling. This results in:

- **500-2000 draw calls** in a loaded area
- **No MID tier batching** — each object has 3 separate nodes (one per LOD level)
- **All culling is CPU-side** — Godot's engine-level per-object visibility checks
- **GPU visibility compute shader exists but is unused** (`gpu_visibility_compute.glsl`)
- **Impostor MultiMesh rebuilds** every 0.5s can spike when many impostors change

A GPU-driven approach moves scene data and culling decisions to the GPU, enabling massively parallel visibility determination and minimal draw calls.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│              Godot Scene Graph                   │
│  NEAR Tier (0-150m): Standard Node3D            │
│  - MeshInstance3D with physics/collision         │
│  - AnimationTree state machines                  │
│  - Standard Godot rendering pipeline             │
│  - Managed by NativeStreamingManager             │
└─────────────────┬───────────────────────────────┘
                  │ (depth buffer shared)
┌─────────────────▼───────────────────────────────┐
│        GPU-Driven Compositor Effect              │
│                                                  │
│  ┌────────────────────────────────────────┐      │
│  │     GPU Scene Buffer (SSBOs)           │      │
│  │     All MID+FAR object data:           │      │
│  │     transform, AABB, mesh_id,          │      │
│  │     material_id, LOD mask              │      │
│  └──────────────┬─────────────────────────┘      │
│                 │                                 │
│  ┌──────────────▼─────────────────────────┐      │
│  │     Culling Compute Pipeline            │      │
│  │     Pass 1: Frustum Cull (6-plane AABB) │      │
│  │     Pass 2: Distance LOD Select         │      │
│  │     Pass 3: RT Occlusion Cull (opt.)    │      │
│  │     Pass 4: Compact + Atomic Append     │      │
│  └──────────────┬─────────────────────────┘      │
│                 │                                 │
│  ┌──────────────▼─────────────────────────┐      │
│  │     CPU Readback (double-buffered)      │      │
│  │     Read compact visible list (N-1)     │      │
│  │     Group by (mesh_type, lod_level)     │      │
│  └──────────────┬─────────────────────────┘      │
│                 │                                 │
│  ┌──────────────▼─────────────────────────┐      │
│  │     MultiMesh Batch Pool                │      │
│  │     One MultiMesh per (type, LOD)       │      │
│  │     Bindless material via Texture2DArray │      │
│  │     ~50-100 draw calls total            │      │
│  └────────────────────────────────────────┘      │
│                                                  │
│  ┌────────────────────────────────────────┐      │
│  │     RT Acceleration Structures (opt.)   │      │
│  │     BLAS: terrain + large buildings     │      │
│  │     TLAS: scene-level                   │      │
│  │     Ray queries for occlusion testing   │      │
│  └────────────────────────────────────────┘      │
└──────────────────────────────────────────────────┘
```

---

## Key Architectural Decisions

### 1. NEAR tier stays as standard Godot nodes

NEAR tier (0-150m) must remain standard `Node3D`/`MeshInstance3D` because:
- Physics/collision requires `CollisionShape3D` in the scene tree
- Interaction systems (console object picker) need scene tree queries
- NPCs/creatures use `AnimationTree` state machines
- The 150m boundary is already well-defined in `distance_utils.gd`

The GPU-driven pipeline handles **MID (150-500m) and FAR (500-5000m) tiers only**.

### 2. Dual rendering path — Indirect draw preferred, MultiMesh readback fallback

Godot's `RenderingDevice` has exposed `draw_list_draw_indirect()` since **4.4.dev4**, enabling true GPU-driven rendering without CPU readback. However, there is a [known Mac bug](https://github.com/godotengine/godot/issues/103488) and the Compatibility renderer doesn't support it. We use a dual-path strategy:

**Preferred path (Vulkan/D3D12): GPU Cull → Indirect Draw Buffer → `draw_list_draw_indirect()`**

- GPU cull shader writes `DrawIndirectCommand` structs directly to an SSBO
- `draw_list_draw_indirect()` consumes the buffer — **zero CPU readback, zero latency**
- Entire MID/FAR pipeline stays on GPU
- Requires Forward+ or Mobile renderer on Vulkan or D3D12

**Fallback path (Mac, Compatibility): GPU Cull → Async Readback → MultiMesh Update**

- GPU compute shader writes compact visible list (object indices + LOD levels)
- CPU reads back from **previous frame** (double-buffered, 1-frame latency)
- CPU groups results by `(mesh_type_id, lod_level)` and updates MultiMesh instances
- Godot renders MultiMeshes normally (inherits lighting, shadows, environment)
- The 1-frame latency is imperceptible at 150m+ distances (16ms at 60fps)

**Path selection at startup:**
```gdscript
# HardwareDetection chooses the rendering path
var use_indirect_draw: bool = HardwareDetection.has_indirect_draw_support()
# Falls back to MultiMesh readback on Mac or Compatibility renderer
```

MultiMesh fallback chosen over `RenderingServer.instance_set_visible()` because:
- MultiMesh = **1 draw call per mesh type** (proven at 70k+ instances by impostor system)
- Visibility toggling still incurs per-instance engine overhead

### 3. CompositorEffect integration

The GPU cull runs as a `CompositorEffect` at `EFFECT_CALLBACK_TYPE_PRE_OPAQUE`, accessing the depth buffer written by NEAR tier. This integration pattern is already proven by the existing `VolumetricFogEffect`.

### 4. Reuse RenderingContext

All GPU buffer/shader operations use the existing `RenderingContext` wrapper (`src/core/water/rendering_context.gd`), which provides:
- `DeletionQueue` for automatic GPU resource cleanup
- Shader caching (load once, reuse)
- Pipeline-as-Callable pattern for dispatch
- Storage buffer and texture creation helpers

### 5. Texture2DArray for materials

Extends the proven pattern from `NativeImpostorRenderer` (512-layer `sampler2DArray`). After `MaterialLibrary` deduplication (~10,000 → ~1,000 unique materials), textures are packed into arrays indexed by per-instance `material_id`.

### 6. Double-buffered SSBOs

Ping-pong buffers: Frame N reads from buffer A while GPU writes cull results to buffer B. Frame N+1 swaps. Same pattern used by ocean FFT dual temp buffers in `wave_generator.gd`.

### 7. Depth integration

NEAR tier renders first through Godot's normal pipeline. The GPU-driven MID/FAR tier reads the existing depth buffer via `access_resolved_depth = true` on the `CompositorEffect`. NEAR objects correctly occlude MID/FAR objects.

---

## Data Structures

### Object SSBO (80 bytes/object, std430)

```glsl
struct ObjectData {
    vec4 position_radius;     // xyz = world position, w = bounding sphere radius (-1 = inactive)
    vec4 aabb_min_meshID;     // xyz = AABB min, w = mesh_type_id (uint as float)
    vec4 aabb_max_lodMask;    // xyz = AABB max, w = LOD availability bitmask
    vec4 transform_col0;      // First column of 3x4 transform matrix
    vec4 transform_col1;      // Second column
};
// 5 * vec4 = 80 bytes per object
// 100,000 objects = 8MB (well within GPU limits)
```

### Visibility Output SSBO (16 bytes/object)

```glsl
struct VisibilityResult {
    uint visible;           // 0 = culled, 1 = visible
    uint selected_lod;      // 0-3 (LOD level chosen by distance)
    float fade_factor;      // 0.0-1.0 for crossfade at tier boundaries
    float distance;         // Distance to camera (for sorting)
};
```

### Compact Visible List SSBO (variable size)

```glsl
layout(set = 0, binding = 2, std430) restrict buffer CompactVisibleBuffer {
    uint visible_count;       // Atomic counter
    uint visible_indices[];   // Object indices that passed culling
};
```

### Push Constants (128 bytes — at RenderingDevice limit)

```glsl
layout(push_constant) uniform PushConstants {
    vec4 camera_pos;         // xyz = position, w = time
    mat4 view_projection;    // For frustum plane extraction (Gribb-Hartmann)
    vec4 tier_thresholds;    // x = near_end(150), y = mid_end(500), z = far_end(5000), w = fade_margin(50)
    vec4 hysteresis;         // Per-tier hysteresis values
    uvec4 counts;            // x = object_count, y = max_visible, z = buffer_idx, w = flags
};
// 4 + 16 + 4 + 4 + 4 = 32 floats = 128 bytes exactly
```

### Material Registry SSBO (16 bytes/material)

```glsl
struct MaterialData {
    uint albedo_layer;       // Layer index in albedo Texture2DArray
    uint normal_layer;       // Layer index in normal Texture2DArray
    float roughness;
    float metallic;
};
```

### MultiMesh Instance Custom Data

```
INSTANCE_CUSTOM.x = material_id   (index into MaterialBuffer)
INSTANCE_CUSTOM.y = fade_factor   (0.0-1.0 for crossfade)
INSTANCE_CUSTOM.z = lod_level     (for debug visualization)
INSTANCE_CUSTOM.w = reserved
```

---

## Implementation Phases

### Phase 1: GPU Scene Database

**Goal:** Store all MID/FAR object data on GPU in SSBOs with incremental streaming updates.

**Create:**
- `src/core/gpu_driven/gpu_scene_database.gd` — SSBO management, free-list slot allocation, double-buffering
- `src/core/gpu_driven/gpu_scene_types.gd` — Shared constants (SSBO sizes, max objects, struct sizes)

**Modify:**
- `src/core/world/native_streaming_manager.gd` — On cell load/unload, call `gpu_scene_db.add_cell_objects()` / `remove_cell_objects()`

**Incremental update pattern:**

```gdscript
var _free_slots: Array[int] = []      # Available SSBO indices
var _cell_slot_map: Dictionary = {}   # Vector2i -> Array[int]

func add_cell_objects(grid: Vector2i, objects: Array) -> void:
    var slots: Array[int] = []
    for obj in objects:
        var slot: int
        if _free_slots.is_empty():
            slot = _total_objects
            _total_objects += 1
        else:
            slot = _free_slots.pop_back()
        slots.append(slot)
        _upload_object_at_slot(slot, obj)
    _cell_slot_map[grid] = slots

func remove_cell_objects(grid: Vector2i) -> void:
    if grid in _cell_slot_map:
        for slot in _cell_slot_map[grid]:
            _mark_slot_inactive(slot)  # Set radius = -1
            _free_slots.append(slot)
        _cell_slot_map.erase(grid)
```

**Double-buffering:**

```gdscript
var _buffers: Array[Array] = [[], []]  # Two sets of SSBOs
var _current: int = 0

func get_write_index() -> int: return _current
func get_read_index() -> int: return 1 - _current
func swap() -> void: _current = 1 - _current
```

**Verify:** Debug overlay drawing dots at GPU-stored positions. Console command `gpu_scene_stats` printing total objects, free slots, buffer memory.

**Dependencies:** None — this is the foundation.

---

### Phase 2: GPU Culling Compute Pipeline

**Goal:** GPU-parallel frustum culling, distance tier assignment, and LOD selection for all MID/FAR objects.

**Create:**
- `src/core/gpu_driven/gpu_cull_effect.gd` — CompositorEffect extending `PostProcessEffect`
- `src/core/gpu_driven/shaders/gpu_cull_compute.glsl` — Extends existing `gpu_visibility_compute.glsl`

**Builds on:** Existing `src/core/world/shaders/gpu_visibility_compute.glsl` which already has:
- 256 objects/workgroup
- Distance-based tier assignment with hysteresis
- Atomic change counters
- SSBO layout for positions and visibility output

**Compute shader pseudocode:**

```glsl
#version 450
layout(local_size_x = 256) in;

// SSBOs from Phase 1
layout(set = 0, binding = 0, std430) restrict readonly buffer ObjectDataBuffer { ObjectData objects[]; };
layout(set = 0, binding = 1, std430) restrict buffer VisibilityBuffer { VisibilityResult visibility[]; };
layout(set = 0, binding = 2, std430) restrict buffer CompactVisibleBuffer {
    uint visible_count;
    uint visible_indices[];
};

layout(push_constant) uniform PushConstants { /* 128 bytes */ };

// Extract frustum planes from view_projection (Gribb-Hartmann method)
void extract_frustum_planes(mat4 vp, out vec4 planes[6]) {
    planes[0] = vp[3] + vp[0]; // left
    planes[1] = vp[3] - vp[0]; // right
    planes[2] = vp[3] + vp[1]; // bottom
    planes[3] = vp[3] - vp[1]; // top
    planes[4] = vp[3] + vp[2]; // near
    planes[5] = vp[3] - vp[2]; // far
    for (int i = 0; i < 6; i++) planes[i] /= length(planes[i].xyz);
}

bool frustum_test_sphere(vec4 planes[6], vec3 center, float radius) {
    for (int i = 0; i < 6; i++)
        if (dot(planes[i].xyz, center) + planes[i].w < -radius) return false;
    return true;
}

uint select_lod(float distance, uint lod_mask) {
    if (distance < 250.0 && (lod_mask & 0x1u) != 0u) return 0u;
    if (distance < 375.0 && (lod_mask & 0x2u) != 0u) return 1u;
    if ((lod_mask & 0x4u) != 0u) return 2u;
    // Fallback to best available
    if ((lod_mask & 0x1u) != 0u) return 0u;
    if ((lod_mask & 0x2u) != 0u) return 1u;
    return 2u;
}

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= pc.counts.x) return;

    ObjectData obj = objects[idx];
    float radius = obj.position_radius.w;
    if (radius < 0.0) { visibility[idx].visible = 0u; return; } // Inactive

    float dist = distance(obj.position_radius.xyz, pc.camera_pos.xyz);

    // Skip NEAR (Godot handles) and beyond FAR
    if (dist < pc.tier_thresholds.x || dist > pc.tier_thresholds.z) {
        visibility[idx].visible = 0u;
        return;
    }

    // Frustum test
    vec4 planes[6];
    extract_frustum_planes(pc.view_projection, planes);
    if (!frustum_test_sphere(planes, obj.position_radius.xyz, radius)) {
        visibility[idx].visible = 0u;
        return;
    }

    // LOD selection + fade + write output
    uint lod_mask = floatBitsToUint(obj.aabb_max_lodMask.w);
    visibility[idx] = VisibilityResult(1u, select_lod(dist, lod_mask), /*fade*/, dist);

    // Atomic append to compact list
    uint compact_idx = atomicAdd(visible_count, 1u);
    if (compact_idx < pc.counts.y) visible_indices[compact_idx] = idx;
}
```

**GDScript orchestration:**

```gdscript
class_name GPUCullEffect extends PostProcessEffect

func _render_callback(effect_type: int, render_data: RenderData) -> void:
    var scene_data := render_data.get_render_scene_data() as RenderSceneDataRD
    var cam_transform := scene_data.get_cam_transform()
    var cam_projection := scene_data.get_cam_projection()
    var vp := cam_projection * cam_transform.affine_inverse()

    # Build push constants from camera + tier thresholds
    _reset_compact_buffer()
    var workgroups := ceili(float(gpu_scene_db.total_objects) / 256.0)
    _cull_pipeline.call(context, compute_list, push_constants)
```

**Readback (runs on CPU, reads frame N-1):**

```gdscript
func readback_visibility() -> void:
    var read_idx := gpu_scene_db.get_read_index()
    var count_data := rd.buffer_get_data(compact_buffers[read_idx], 0, 4)
    var visible_count := count_data.decode_u32(0)
    if visible_count == 0: return

    var indices := rd.buffer_get_data(compact_buffers[read_idx], 4, visible_count * 4)
    _update_multimeshes(indices, visible_count)
```

**Verify:** Run GPU and CPU culling simultaneously, compare results. Console command `gpu_cull_stats`.

**Dependencies:** Phase 1.

---

### Phase 3: Bindless Material System

**Goal:** Pack all MID/FAR textures into Texture2DArrays indexed by material_id. Eliminates material switches.

**Create:**
- `src/core/gpu_driven/gpu_material_registry.gd` — Builds texture arrays, assigns material IDs
- `src/core/gpu_driven/shaders/gpu_driven_mesh.gdshader` — Spatial shader sampling from arrays

**Texture arrays (3 arrays, 512 layers each, 512x512):**
- `albedo_array` — Albedo textures (source_color)
- `normal_array` — Normal maps (hint_normal)
- `orm_array` — Occlusion/Roughness/Metallic packed

Built from `MaterialLibrary`'s deduplicated material set (~1000 unique after hash-based dedup).

**GPU-driven mesh shader:**

```glsl
shader_type spatial;
render_mode cull_back;

uniform sampler2DArray albedo_atlas : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2DArray normal_atlas : hint_normal, filter_linear_mipmap_anisotropic;

varying flat float v_material_id;
varying flat float v_fade;

void vertex() {
    v_material_id = INSTANCE_CUSTOM.x;
    v_fade = INSTANCE_CUSTOM.y;
}

void fragment() {
    vec4 albedo = texture(albedo_atlas, vec3(UV, v_material_id));

    // Crossfade dithering at tier boundaries
    float dither = fract(dot(vec2(FRAGCOORD.xy), vec2(12.9898, 78.233)));
    if (dither >= v_fade) discard;

    ALBEDO = albedo.rgb;
    ALPHA_SCISSOR_THRESHOLD = 0.5;
    ROUGHNESS = 0.8;
    METALLIC = 0.0;
}
```

**Prebake integration:** New stage after texture conversion — resize all unique textures to 512x512, pack into Texture2DArray, save mapping as `cache/materials/material_registry.json`.

**Verify:** A/B toggle between StandardMaterial3D and texture-array shader. Check for UV seams, mipmap artifacts.

**Dependencies:** Phase 1 (material IDs in object SSBO). Independent of Phase 2.

---

### Phase 4: GPU-Driven MID/FAR Rendering

**Goal:** Unified rendering fed by GPU cull results. Two paths: indirect draw (preferred) or MultiMesh readback (fallback). Target: ~50-100 draw calls.

**Create:**
- `src/core/gpu_driven/gpu_driven_renderer.gd` — Dual-path renderer (indirect draw or MultiMesh readback)
- `src/core/gpu_driven/multimesh_batch_pool.gd` — Pool of MultiMesh per (mesh_type, lod_level) (fallback path)

**Modify:**
- `src/core/world/native_streaming_manager.gd` — MID/FAR objects → GPU database only (skip Node3D creation)
- `src/core/world/native_impostor_renderer.gd` — Subsume into unified batch pool (impostors = another mesh type)
- `src/core/water/hardware_detection.gd` — Add indirect draw capability detection

#### Path A: Indirect Draw (Vulkan/D3D12 — preferred)

`draw_list_draw_indirect()` is available since Godot 4.4. The cull shader writes `DrawIndirectCommand` structs directly to an SSBO, and the draw call consumes that buffer with zero CPU involvement.

**Per-frame pipeline:**

```
1. GPU cull compute shader dispatched (Phase 2)
   - Writes DrawIndirectCommand structs to indirect draw SSBO
   - One command per (mesh_type, lod_level) group
2. draw_list_draw_indirect() consumes the buffer directly
3. Zero CPU readback, zero latency
```

**Caveats:**
- [Mac bug](https://github.com/godotengine/godot/issues/103488): `draw_list_draw_indirect` may not work on Metal — use fallback path
- Requires Forward+ or Mobile renderer (not Compatibility)

#### Path B: MultiMesh Readback (fallback)

**Per-frame pipeline:**

```
1. GPU cull compute shader dispatched (Phase 2)
2. CPU reads back compact visible list from previous frame (double-buffered)
3. Group visible objects by batch_key = mesh_type_id * 4 + lod_level
4. For each group:
   a. Get or create MultiMesh from pool
   b. Set visible_instance_count = group.size
   c. Bulk upload transforms + custom data (material_id, fade)
5. Godot renders MultiMeshes (inherits lighting, shadows, environment)
```

The 1-frame latency is imperceptible at 150m+ distances.

**Path selection:**

```gdscript
func _select_rendering_path() -> void:
    if HardwareDetection.has_indirect_draw_support():
        _renderer = IndirectDrawRenderer.new()
    else:
        _renderer = MultiMeshReadbackRenderer.new()
```

**MultiMesh batch pool (fallback path):**

```gdscript
class_name MultiMeshBatchPool extends Node3D

var _batches: Dictionary = {}  # batch_key -> BatchData

class BatchData:
    var multimesh: MultiMesh
    var instance: MultiMeshInstance3D
    var capacity: int = 256
    var active_count: int = 0

func update_batch(key: int, transforms: PackedFloat32Array,
                  custom_data: PackedFloat32Array, count: int) -> void:
    var batch := _batches.get(key)
    if count > batch.capacity:
        batch.capacity = next_power_of_2(count)
        batch.multimesh.instance_count = batch.capacity
    batch.multimesh.visible_instance_count = count
    batch.multimesh.buffer = _build_buffer(transforms, custom_data, count)
```

**LOD mesh selection:** Batch key encodes both mesh type and LOD level. `LODResource` already stores meshes per level. Each (type, LOD) combination = one MultiMesh (fallback) or one indirect draw command (preferred).

**Impostor integration:** The existing `NativeImpostorRenderer`'s `_master_multimesh` becomes one batch in the pool. Its `sampler2DArray texture_atlas` maps directly to the material system.

**Verify:** Draw call counter via `Performance.get_monitor()`. Frame time comparison in Balmora. Visual regression flythrough. Test both paths explicitly.

**Dependencies:** Phase 1, 2, 3.

---

### Phase 5: RT Occlusion Culling (Godot 4.7+ — Optional Enhancement)

**Goal:** GPU occlusion culling using RT acceleration structures from [PR #99119](https://github.com/godotengine/godot/pull/99119).

**Availability:** PR #99119 merged Jan 27, 2026 into `master`, targeting **Godot 4.7**. Not available in 4.6. Vulkan only — no Metal or D3D12 RT support yet.

**Create:**
- `src/core/gpu_driven/rt_occlusion_culler.gd` — BLAS/TLAS management
- `src/core/gpu_driven/shaders/rt_occlusion_compute.glsl` — Ray queries for occlusion

**Why:** The project currently has NO exterior occlusion culling (Godot's built-in has an [angle bug](https://github.com/godotengine/godot/issues/106184)). In dense areas like Balmora or Vivec, many objects are behind buildings and should be culled.

**Approach:**
- Build BLAS from terrain chunks + large buildings (AABB > 10m)
- Build TLAS from BLAS instances (update when cells stream in/out)
- For each frustum-visible candidate: trace ray from camera → object center
- If ray hits closer geometry → object is occluded, remove from visible list

**Occlusion compute shader:**

```glsl
#version 450
#extension GL_EXT_ray_query : require

layout(local_size_x = 256) in;
layout(set = 0, binding = 0) uniform accelerationStructureEXT tlas;
layout(set = 0, binding = 1, std430) buffer CandidateBuffer { uint candidates[]; };
layout(set = 0, binding = 2, std430) buffer ObjectDataBuffer { ObjectData objects[]; };
layout(set = 0, binding = 3, std430) buffer OcclusionResult { uint occluded[]; };

layout(push_constant) uniform PC { vec4 camera_pos; uint candidate_count; };

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= candidate_count) return;

    uint obj_idx = candidates[idx];
    vec3 obj_pos = objects[obj_idx].position_radius.xyz;
    float radius = objects[obj_idx].position_radius.w;

    vec3 ray_dir = normalize(obj_pos - camera_pos.xyz);
    float ray_dist = distance(obj_pos, camera_pos.xyz) - radius;

    rayQueryEXT rq;
    rayQueryInitializeEXT(rq, tlas, gl_RayFlagsTerminateOnFirstHitEXT,
        0xFF, camera_pos.xyz, 0.1, ray_dir, ray_dist * 0.95);
    rayQueryProceedEXT(rq);

    occluded[idx] = (rayQueryGetIntersectionTypeEXT(rq, true)
        != gl_RayQueryCommittedIntersectionNoneEXT) ? 1u : 0u;
}
```

**Graceful degradation:**

```gdscript
# Extend HardwareDetection (src/core/water/hardware_detection.gd)
static var _has_ray_tracing: bool = false

static func detect() -> void:
    var rd := RenderingServer.get_rendering_device()
    if rd and rd.has_feature(RenderingDevice.FEATURE_RAYTRACING):
        _has_ray_tracing = true
```

If RT unavailable, occlusion pass is skipped. System works fine without it (just fewer objects culled).

**Verify:** Fly behind buildings, check that hidden objects don't render. Toggle on/off, compare frame time in urban areas.

**Dependencies:** Phase 1, 2. Independent of Phase 3-4 (but output feeds into Phase 4's visible list).

---

### Phase 6: Integration & Polish

**Goal:** Production-ready system with smooth transitions, streaming coherence, fallbacks, and debug tools.

**Create:**
- `src/core/gpu_driven/gpu_renderer_manager.gd` — Top-level coordinator for all GPU subsystems
- `src/core/gpu_driven/tier_transition_controller.gd` — NEAR↔MID crossfade
- `src/core/gpu_driven/gpu_debug_overlay.gd` — Debug visualization

**NEAR→MID tier transition:**

When an object crosses the 150m boundary, both representations exist briefly with opposing crossfade:

```gdscript
class_name TierTransitionController extends RefCounted

const FADE_DURATION: float = 0.5  # seconds

class TransitionState:
    var node3d: Node3D
    var gpu_slot: int
    var fade_progress: float = 0.0  # 0 = fully NEAR, 1 = fully MID
    var direction: int = 1           # +1 = to MID, -1 = to NEAR

func update(delta: float) -> void:
    for id in _transitioning.keys():
        var state: TransitionState = _transitioning[id]
        state.fade_progress = clampf(
            state.fade_progress + delta / FADE_DURATION * state.direction,
            0.0, 1.0
        )
        # NEAR node uses dither (decreasing), GPU instance uses fade (increasing)
        _apply_near_fade(state.node3d, 1.0 - state.fade_progress)
        gpu_scene_db.set_fade(state.gpu_slot, state.fade_progress)

        if state.fade_progress >= 1.0 and state.direction == 1:
            state.node3d.queue_free()
            _transitioning.erase(id)
        elif state.fade_progress <= 0.0 and state.direction == -1:
            gpu_scene_db.deactivate(state.gpu_slot)
            _transitioning.erase(id)
```

**Streaming coherence:** New GPU objects start at `fade = 0.0` and ramp to `1.0` over the fade duration. No pops.

**Fallback:** If compute shaders unavailable, entire GPU system disabled, existing Node3D rendering continues:

```gdscript
func initialize() -> Error:
    if not HardwareDetection.has_compute_support():
        push_warning("[GPURenderer] No compute support, using CPU rendering")
        _use_gpu_driven = false
        return OK
    # ... initialize subsystems ...
```

**Performance monitoring:**

```gdscript
func get_stats() -> Dictionary:
    return {
        "gpu_objects_total": gpu_scene_db.total_objects,
        "gpu_cull_visible": _last_visible_count,
        "gpu_cull_time_ms": _last_cull_time_ms,
        "gpu_draw_calls": _batch_pool.active_batch_count,
        "gpu_instances_rendered": _batch_pool.total_visible_instances,
        "gpu_readback_time_ms": _last_readback_time_ms,
        "tier_transitions_active": _transition_controller.active_count,
        "gpu_buffer_memory_mb": gpu_scene_db.memory_usage / (1024.0 * 1024.0),
    }
```

**Verify:** 10-minute flight test (no pops, leaks, crashes). Stress test with rapid cell loading. Fallback test with compute disabled.

**Dependencies:** All previous phases (Phase 5 optional).

---

## File Structure

```
src/core/gpu_driven/
├── gpu_scene_database.gd          # Phase 1: SSBO management, free-list, double-buffering
├── gpu_scene_types.gd             # Phase 1: Shared constants and struct definitions
├── gpu_cull_effect.gd             # Phase 2: CompositorEffect for compute culling
├── gpu_material_registry.gd       # Phase 3: Texture array packing, material ID mapping
├── gpu_driven_renderer.gd         # Phase 4: Reads cull output, updates MultiMesh batches
├── multimesh_batch_pool.gd        # Phase 4: Pool of MultiMesh per (type, LOD)
├── rt_occlusion_culler.gd         # Phase 5: BLAS/TLAS management (optional)
├── gpu_renderer_manager.gd        # Phase 6: Top-level coordinator
├── tier_transition_controller.gd  # Phase 6: NEAR↔MID crossfade
├── gpu_debug_overlay.gd           # Phase 6: Debug visualization
└── shaders/
    ├── gpu_cull_compute.glsl      # Phase 2: Frustum + distance + LOD culling
    ├── gpu_driven_mesh.gdshader   # Phase 3: Texture-array material shader
    └── rt_occlusion_compute.glsl  # Phase 5: Ray query occlusion
```

## Existing Files to Reuse

| File | What to reuse |
|------|--------------|
| `src/core/water/rendering_context.gd` | RenderingDevice wrapper — SSBOs, pipelines, DeletionQueue, shader caching |
| `src/core/shaders/post_process_effect.gd` | CompositorEffect base class — thread-safe params, compute dispatch |
| `src/core/shaders/shader_manager.gd` | Register GPU cull effect as compositor effect |
| `src/core/world/shaders/gpu_visibility_compute.glsl` | Starting point for cull shader (distance/hysteresis/atomics) |
| `src/core/texture/material_library.gd` | Deduplicated material set → feed into texture arrays |
| `src/core/world/native_impostor_renderer.gd` | Proven 70k MultiMesh + Texture2DArray pattern |
| `src/core/world/distance_utils.gd` | Tier boundary constants (NEAR_END, MID_END, FAR_END) |
| `src/core/world/lod_resource.gd` | LOD mesh storage per level |
| `src/core/water/hardware_detection.gd` | Extend for indirect draw + RT feature detection |

## Existing Files to Modify

| File | Changes |
|------|---------|
| `src/core/world/native_streaming_manager.gd` | Route MID/FAR objects to GPU database instead of Node3D instantiation |
| `src/core/world/native_impostor_renderer.gd` | Subsume into unified batch pool |
| `src/core/world/cell_manager.gd` | Conditional: Node3D for NEAR, GPU registration for MID/FAR |
| `src/core/world/streaming_config.gd` | Add GPU-driven configuration constants |
| `src/core/water/hardware_detection.gd` | Add indirect draw + RT feature detection |

---

## Risks & Mitigations

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| 1-frame readback latency causes visual artifacts | High probability, low impact | Objects at 150m+ — 16ms lag imperceptible | Double-buffered readback |
| SSBO size exceeds GPU limits | Low | High | Cap at 100k objects (8MB), covers 5km radius |
| Texture2DArray 512-layer limit hit | Medium | Medium | ~1000 materials after dedup → may need 2 arrays, or atlas-pack similar materials |
| RT acceleration structures unavailable | High (4.6) | Low | Phase 5 requires Godot 4.7+ ([PR #99119](https://github.com/godotengine/godot/pull/99119)). Graceful skip — system works without it |
| GPU cull disagrees with Godot frustum | Low | Medium | Use same projection matrix from `RenderSceneDataRD` |
| MultiMesh buffer upload stalls (fallback path) | Medium | Medium | Grow capacity in powers of 2, never shrink `instance_count`, use `visible_instance_count` |
| `draw_list_draw_indirect` Mac bug | Medium | Low | [GitHub #103488](https://github.com/godotengine/godot/issues/103488) — fallback to MultiMesh readback path on Mac |
| Indirect draw not supported on Compatibility renderer | Certain | Low | Compatibility renderer lacks compute — entire GPU system disabled, existing Node3D rendering continues |

---

## Configuration Constants

```gdscript
# Add to streaming_config.gd
const GPU_DRIVEN_ENABLED := true
const GPU_MAX_OBJECTS := 100_000        # Max objects in SSBO
const GPU_OBJECT_STRIDE := 80           # Bytes per object in SSBO
const GPU_READBACK_LATENCY := 1         # Frames of double-buffer lag
const GPU_BATCH_INITIAL_CAPACITY := 256
const GPU_BATCH_MAX_CAPACITY := 4096
const GPU_TEXTURE_ARRAY_LAYERS := 512   # Layers per Texture2DArray
const GPU_TEXTURE_RESOLUTION := 512     # Pixels per texture in array
const GPU_OCCLUDER_MIN_SIZE := 10.0     # Min AABB size for TLAS occluder
const GPU_CULL_WORKGROUP_SIZE := 256    # Threads per cull workgroup
```

---

## Future: Engine-Level GPU-Driven Rendering

`draw_list_draw_indirect()` has been available since Godot 4.4.dev4, and our architecture already uses it as the preferred rendering path (Phase 4, Path A). The MultiMesh readback path exists only as a fallback for platforms without indirect draw support.

**What Godot's engine team is working toward (longer term):**

[Reduz's GPU-driven renderer vision](https://gist.github.com/reduz/c5769d0e705d8ab7ac187d63be0099b5) describes a full engine-level overhaul: deferred G-buffer, bindless textures, RT shadows replacing shadow maps, and all opaque rendering via indirect draw. This is a multi-year effort not on the near-term roadmap ([rendering priorities, Sep 2024](https://godotengine.org/article/rendering-priorities-september-2024/)).

**If/when Godot ships an engine-level GPU-driven renderer:**

Our application-level system can be retired gracefully. The separation of concerns (GPU scene database → cull → render) means individual phases can be replaced with engine equivalents as they become available. Until then, our CompositorEffect-based approach gives us the same benefits at the application layer.
