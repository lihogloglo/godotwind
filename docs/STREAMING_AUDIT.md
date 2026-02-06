# Streaming Pipeline Audit

**Date:** 2026-02-06 (updated 2026-02-06)
**Status:** Audit Complete, Phases 0-3 Fixed, Phases 4-6 Pending
**Scope:** Full streaming pipeline from camera movement to object on screen
**Godot Version:** 4.6 (Forward+, D3D12, Jolt Physics)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture Overview](#architecture-overview)
3. [Godot Threading Model](#godot-threading-model)
4. [Data Flow — What Actually Happens](#data-flow)
5. [Critical Problems](#critical-problems)
6. [GPU Driven Renderer Analysis](#gpu-driven-renderer-analysis)
7. [Proposed Fix Plan](#proposed-fix-plan)
8. [File Reference](#file-reference)
9. [Metrics to Track](#metrics-to-track)

---

## Executive Summary

The streaming pipeline initially had a ~3.3 second time-to-playable on initial spawn and significant frame drops during camera movement. Phases 0-3 addressed the most critical issues. Remaining problems:

**Resolved (Phases 0-3):**
- ~~"Parallel duplicate" system was synchronous~~ — removed, replaced with simple sequential loop
- ~~Unloading was unbounded~~ — now budget-controlled via `_process_budgeted_unloading()` (4ms/frame)
- ~~No frustum-aware prioritization~~ — `_sort_queue_by_priority()` gives 4x penalty to behind-camera objects

**Remaining (Phases 4-6):**
- **10,000+ objects** queued for instantiation across 49 cells on spawn
- **Redundant visibility configuration** — recursive tree walk on every cell after load, despite prebaked values
- **MultiMesh batching is cell-scoped** — identical objects in adjacent cells create separate draw calls
- **Every object gets full scene tree presence** regardless of distance tier
- **No velocity-based priority** — camera movement direction not factored into load order
- **No object recycling** — objects freed on cell unload and re-duplicated on adjacent cell load
- **Unbounded prototype cache** — model_loader memory cache grows without eviction

The GPU Driven Renderer proposal (`docs/GPU_DRIVEN_RENDERER.md`) addresses rendering efficiency (draw calls, GPU culling) but does not fix the streaming bottleneck itself. Both systems are needed, but streaming fixes come first.

---

## Architecture Overview

### Key Files and Responsibilities

| File | Lines | Role |
|------|-------|------|
| `src/core/world/native_streaming_manager.gd` | ~928 | Top-level orchestrator. Tracks camera, decides which cells to load/unload, budgeted unloading, frustum-priority queuing |
| `src/core/world/cell_manager.gd` | ~1799 | Cell loading engine. Handles sync/async loading, instantiation queue, pool pre-warming |
| `src/core/world/model_loader.gd` | ~970 | Model cache (memory + disk). Loads prebaked .res files, async loading via ResourceLoader |
| `src/core/world/reference_instantiator.gd` | ~762 | Converts ESM cell references into Node3D objects. Handles lights, actors, static objects, fade-in |
| `src/core/streaming/background_processor.gd` | ~270 | WorkerThreadPool wrapper with priority heap. Used for NIF parsing (prebaking only, idle at runtime) |
| `src/core/world/streaming_config.gd` | ~293 | All tunable constants: distances, budgets, pool sizes, quality presets |
| `src/core/world/lod_configurator.gd` | ~288 | Sets visibility_range properties on GeometryInstance3D nodes |
| `src/core/world/static_object_renderer.gd` | ~378 | RenderingServer-direct rendering for flora (bypasses scene tree). Proven pattern for scene-tree-free rendering |
| `src/core/world/native_impostor_renderer.gd` | ~400 | FAR tier octahedral impostor MultiMesh rendering |
| `src/core/world/distance_utils.gd` | ~143 | Distance constants (NEAR_END=150m, MID_END=500m, FAR_END=5000m), coordinate utilities |

### Dependency Graph

```
NativeStreamingManager
├── CellManager
│   ├── ModelLoader (disk cache → memory cache → prototype)
│   ├── ReferenceInstantiator
│   │   ├── ModelLoader (get_model → duplicate)
│   │   ├── ObjectPool (acquire/release)
│   │   ├── StaticObjectRenderer (flora only)
│   │   ├── CharacterFactoryV2 (NPCs/creatures)
│   │   └── ImpostorCandidates (significant object detection)
│   ├── BackgroundProcessor (WorkerThreadPool — idle at runtime)
│   └── LODConfigurator (visibility_range setup)
├── NativeImpostorRenderer (FAR tier MultiMesh)
└── ImpostorCandidates
```

### Distance Tiers

| Tier | Range | Representation | Loading |
|------|-------|---------------|---------|
| NEAR | 0-150m | Full Node3D + physics + collision | Scene tree, `add_child()` |
| MID | 150-500m | LOD meshes (_LOD1, _LOD2, _LOD3) via visibility_range | Same Node3D, hidden by distance |
| FAR | 500-5000m | Octahedral impostors via MultiMesh | Separate renderer, no Node3D |

---

## Godot Threading Model

Understanding what Godot allows on worker threads vs. main thread is critical to understanding the streaming pipeline's constraints.

### Main Thread ONLY (will crash or corrupt if called from workers)

| Operation | Why |
|-----------|-----|
| `Node.duplicate()` | Internal resource path tracking is not thread-safe; causes "cyclic resource inclusion" errors |
| `PackedScene.instantiate()` | Same resource tracking issue as `duplicate()` |
| `Node.add_child()` / `remove_child()` | Scene tree mutations must happen on main thread |
| `Node.queue_free()` | Deferred to end-of-frame, but registration is main-thread |
| Signal emission (typed connections) | Receiver code runs on emitting thread — unsafe if receiver touches scene tree |
| `RenderingServer` most calls | Some are thread-safe (transform updates), most are not |

### Worker Thread OK

| Operation | Notes |
|-----------|-------|
| `ResourceLoader.load_threaded_request()` | Godot's built-in async loading — returns status, result retrieved on main thread |
| Math / spatial calculations | `Vector3`, `Transform3D`, `AABB` operations are value types, fully thread-safe |
| `PackedArray` operations | `PackedVector3Array`, `PackedFloat32Array` etc. — contiguous memory, no Variant overhead |
| Dictionary / Array reads | Safe if no concurrent writes (use Mutex if writing) |
| File I/O (`FileAccess`) | Thread-safe per handle |
| C# binary parsing | Ideal use case for `WorkerThreadPool` |

### Implications for Streaming

This is why the old "parallel duplicate" system was fake — `duplicate()` cannot run off-thread. And it's why **tiered loading** (Phase 5) is the real solution: MID-tier objects can be registered via pre-computed data (position, mesh RID, material RID) that's assembled on a worker thread, then applied via a single batch of `RenderingServer` calls on the main thread.

---

## Data Flow

### Initial Spawn Sequence

```
1. world_explorer.gd calls streaming_manager.initialize(cell_manager, camera)
2. streaming_manager._update_loaded_cells()
3. _get_cells_in_radius(camera_cell, 3)
   → Returns ~49 cells (7x7 diamond minus corners)
   → Sorted by distance to camera
4. Cells queued in _pending_load_queue

PER FRAME (in _process):
5. _process_pending_loads_async()
   → Submits up to 2 cell requests per frame
   → Each cell: ESMManager.get_exterior_cell(x, y) → CellRecord
   → request_exterior_cell_async() creates AsyncCellRequest
   → For each reference in cell:
     a. Check model_loader memory cache (Dictionary lookup)
     b. Check model_loader disk cache (FileAccess.file_exists → ResourceLoader.load)
     c. If cached: queue {ref, model_path, position} in _instantiation_queue
     d. If not cached: model returns null (runtime_mode=true, no NIF conversion)

6. process_async_instantiation(8ms budget)
   → Pop entries from _instantiation_queue (sorted by frustum-priority every 10 frames)
   → Priority = distance² × (4.0 if behind camera, 1.0 if in front)  [Phase 3]
   → For each entry (up to 50/frame or 8ms):
     a. Try object pool acquire (fast path)
     b. Else: model_loader.get_model() → prototype.duplicate() (EXPENSIVE, main-thread only)
     c. Set name, transform, metadata
     d. _hide_lod_nodes() — recursive walk to hide materialless meshes
     e. Add to pending_children batch
   → Batch add_child() (or call_deferred if >20 objects)

7. _process_async_completions()
   → Check if all references for a cell are instantiated
   → If complete: _configure_cell_visibility(cell_node)
     → RECURSIVE walk of entire node tree (Problem 4 — should be prebaked)
     → Set visibility_range_begin/end on every GeometryInstance3D
   → Emit cell_loaded signal
```

### Movement Sequence

```
1. Camera crosses cell boundary
2. _update_loaded_cells()
3. For each cell no longer in radius:
   → Mark cell as "unloading" in _unloading_cells dict  [Phase 2]
   → Cancel any in-progress async requests
   → Remove pending instantiation queue entries (filter scan)
4. _process_budgeted_unloading() runs each frame (4ms budget)  [Phase 2]
   → Remove up to UNLOAD_BATCH_SIZE children per frame per cell
   → Return poolable objects to ObjectPool
   → When cell has no children left, free the empty container
5. Queue new cells (same as initial spawn, step 3-7)
```

### Not Yet Implemented: Object Recycling

When cell A unloads and cell B loads, they often share many identical models (rocks, barrels, flora). Currently, objects in A are freed and identical objects in B are freshly `duplicate()`'d. A recycling system could `remove_child()` matching objects from the unloading cell, set new transforms, and `add_child()` to the loading cell — skipping both the `free()` and the `duplicate()`. This requires tracking model paths per cell and matching during the load/unload overlap window.

### Not Yet Implemented: Velocity-Based Priority

The frustum-priority sort (Phase 3) only considers camera position and facing direction. It does not factor camera velocity. A player moving north at speed should see northern cells prioritized over equidistant southern cells. This can be layered onto the existing sort:

```
priority = distance² × frustum_penalty × velocity_penalty
velocity_penalty = 1.0 if cam_velocity.dot(to_object) > 0 else 2.0
```

### Per-Object Instantiation Cost Breakdown

| Operation | Typical Cost | Notes |
|-----------|-------------|-------|
| Dictionary cache lookup | <0.01ms | Memory cache hit |
| FileAccess.file_exists | ~0.1ms | Cached after first check |
| ResourceLoader.load (disk cache) | 1-5ms | PackedScene from .res file |
| prototype.duplicate() | 0.3-2ms | Depends on node tree depth, mesh/material count |
| _hide_lod_nodes() recursive walk | 0.05-0.2ms | Walks all children |
| add_child() | 0.1-0.5ms | Scene tree insertion, signal emission |
| _configure_cell_visibility() | 0.5-2ms/cell | After all objects placed, recursive walk |
| Fade-in shader setup | 0.2-0.5ms | Per mesh: create ShaderMaterial, copy params, start Tween |

**Total per object (cache hit):** ~0.5-3ms
**Total per object (disk load):** ~2-8ms
**Total per cell (200 objects):** ~100-600ms (spread across frames via budget)

---

## Critical Problems

### Problem 1: "Parallel Duplicate" is Synchronous — RESOLVED

**Severity:** High (code complexity with zero performance benefit)
**Status:** RESOLVED in Phase 1. Parallel duplicate system removed, replaced with sequential `duplicate()` in instantiation loop.
**File:** `src/core/world/cell_manager.gd` (formerly lines 1340-1559, now removed)

The old `_dispatch_parallel_duplicates()` function was 140 lines of code that pretended to be parallel but ran entirely on the main thread (see [Godot Threading Model](#godot-threading-model) — `duplicate()` is main-thread only). The mutex, result queue, stats tracking, and instance ID indirection added overhead and complexity for identical performance to a simple for-loop.

**Resolution:** Replaced with a straightforward sequential `duplicate()` call in the instantiation loop. ~200 lines removed.

---

### Problem 2: Unloading is Unbounded — RESOLVED

**Severity:** Critical (direct cause of movement stutter)
**Status:** RESOLVED in Phase 2. `_process_budgeted_unloading()` replaces `queue_free()` with staged child removal (4ms budget, pool return).
**File:** `src/core/world/native_streaming_manager.gd:438-467`

Previously, when a cell exited the load radius, `cell_node.queue_free()` freed the entire subtree (300-1500 nodes) in one frame. With 4-8 cells unloading simultaneously during diagonal movement, that meant 1200-12000 nodes freed in one frame, causing 15-40ms spikes.

**Resolution:** `_process_budgeted_unloading()` now removes children in batches over multiple frames (4ms budget, UNLOAD_BATCH_SIZE=30 children/frame). Poolable objects are returned to ObjectPool. Empty container nodes are freed only after all children are removed.

---

### Problem 3: Loading 10,000 Objects Regardless of Visibility — RESOLVED

**Severity:** High (wastes 40-60% of loading budget on invisible objects)
**Status:** RESOLVED in Phase 3. `_sort_queue_by_priority()` uses camera forward dot product to give 4x penalty to behind-camera objects.
**File:** `src/core/world/native_streaming_manager.gd`

Previously, `_get_cells_in_radius()` queued all ~9,800 objects (49 cells × 200 objects/cell) with equal priority regardless of camera facing. Only 30-40% of the loaded radius was actually visible, wasting 40-60% of the loading budget.

**Resolution:** `_sort_queue_by_priority()` now uses `cam_forward.dot(direction_to_object)` to give a 4x distance penalty to objects behind the camera (dot < 0.3). Visible objects load first, behind-camera objects fill in later.

**Still missing:** Object importance weighting (buildings before clutter) and velocity-based priority (see [Velocity-Based Priority](#not-yet-implemented-velocity-based-priority) above).

---

### Problem 4: Redundant Visibility Configuration

**Severity:** Medium (wasted CPU cycles on every cell load)
**Files:**
- `src/core/world/native_streaming_manager.gd:453-495`
- `src/core/world/lod_configurator.gd`

After every cell finishes async loading, `_configure_cell_visibility()` recursively walks the entire node tree and sets `visibility_range_begin`, `visibility_range_end`, `visibility_range_begin_margin`, `visibility_range_end_margin`, and `visibility_range_fade_mode` on every `GeometryInstance3D`.

**This should be done during prebaking, not at runtime.**

The prebaked .res files already contain the node hierarchy. If visibility_range values were set during the prebaking step and saved into the PackedScene, this entire runtime pass could be eliminated.

**Cost:** 0.5-2ms per cell × 49 cells = 25-100ms total during initial load, spread across frames.

**Fix:** Bake visibility_range into the prebaked models. Add a prebaking step that sets these values before saving the PackedScene.

---

### Problem 5: Cell-Scoped MultiMesh Batching

**Severity:** Medium (missed optimization, more draw calls than necessary)
**File:** `src/core/world/cell_manager.gd:228-491`

MultiMesh instancing groups references by model path, but only within a single cell. The `min_instances_for_multimesh = 10` threshold means:
- Cell A has 8 barrels → 8 individual Node3D instances
- Cell B has 8 barrels → 8 individual Node3D instances
- Total: 16 individual draw calls instead of 1 MultiMesh with 16 instances

Cross-cell batching would reduce draw calls significantly for common objects like:
- Rocks (terrain_rock variants)
- Containers (barrels, crates, sacks)
- Light fixtures
- Dwemer pipes/gears

**Fix:** World-level MultiMesh manager that batches identical models across cells. This is essentially what Phase 4 of the GPU Driven Renderer proposes (`MultiMeshBatchPool`).

---

### Problem 6: Every Object Gets Full Scene Tree Presence

**Severity:** High (fundamental architectural issue)
**Files:** `src/core/world/cell_manager.gd`, `src/core/world/reference_instantiator.gd`

Whether an object is at 10m or 490m, it goes through:
1. `model_loader.get_model()` — disk cache load
2. `prototype.duplicate()` — deep clone of entire node tree
3. `_hide_lod_nodes()` — recursive child walk
4. `add_child()` — scene tree insertion
5. `_configure_cell_visibility()` — recursive visibility setup
6. Potential fade-in animation (ShaderMaterial creation + Tween)

An object at 300m that will be immediately hidden by `visibility_range_end = 150m` still pays the full cost. The only exception is flora, which uses `StaticObjectRenderer` (RenderingServer direct API, no Node3D).

**Impact:** ~70% of loaded objects are in MID tier and could use a lightweight representation.

**Fix:** Tiered loading:
- NEAR (0-150m): Full Node3D with collision (current behavior)
- MID (150-500m): RenderingServer multimesh or individual instances (no Node3D)
- FAR (500-5000m): Impostor system (already working)

---

### Problem 7: BackgroundProcessor Underutilized at Runtime

**Severity:** Low (wasted infrastructure, minor resource overhead)
**File:** `src/core/streaming/background_processor.gd`

The `BackgroundProcessor` is a well-implemented WorkerThreadPool wrapper with a priority binary heap. However, at runtime (`runtime_mode = true` in ModelLoader):
- NIF parsing is disabled (prebaked models only)
- Disk loading uses `ResourceLoader.load_threaded_request()` separately
- The processor runs as a Node in the scene tree, calling `_process()` every frame to check for completions — but there are none

It was designed for async NIF parsing during prebaking. At runtime, it's overhead.

**Fix:** Either repurpose it for actual runtime work (async disk loads, scene instantiation) or don't add it to the scene tree in runtime mode.

---

### Problem 8: Fade-In System Creates Per-Object Shader Materials

**Severity:** Low-Medium (GC pressure, material creation overhead)
**File:** `src/core/world/reference_instantiator.gd:642-727`

Each fade-in creates a new `ShaderMaterial` per `MeshInstance3D`, copies texture parameters from the original `StandardMaterial3D`, creates a `Tween`, and then restores the original material on completion.

For a cell with 200 objects averaging 2 meshes each = 400 ShaderMaterial allocations + 400 Tweens, all running concurrently. The materials are GC'd when the tween completes, causing allocation pressure.

`streaming_config.gd` defines `MATERIAL_POOL_SIZE = 256` and `MATERIAL_POOL_PREWARM = 64`, but **no pool is actually implemented** — these are just unused constants.

**Compounding factor: Shader compilation stutter.** The crossfade shader must be compiled on first use. When 200 objects fade in simultaneously on initial spawn, the first batch triggers shader compilation on top of the allocation pressure. **Mitigation:** Pre-warm the crossfade shader at startup by rendering a single invisible quad with it before any cells load.

**Fix:** Implement the material pool as described in the config constants. Pre-allocate crossfade materials and reuse them. Pre-warm the crossfade shader during initialization.

---

### Problem 9: Unbounded Prototype Cache

**Severity:** Medium (memory growth, no eviction)
**File:** `src/core/world/model_loader.gd`

The `model_loader` memory cache (`_model_cache: Dictionary`) stores every loaded prototype indefinitely. With 49 cells × 50-100 unique models, this cache grows to hundreds of entries. When the player travels across the world, prototypes from distant cells remain cached forever.

No LRU eviction, no memory budget, no monitoring. On a long play session, this can consume significant RAM as the cache accumulates prototypes for models the player may never see again.

**Fix:** Add LRU eviction with a configurable max cache size. Track last-access time per entry. Evict least-recently-used prototypes when cache exceeds budget. Monitor via `Performance.MEMORY_STATIC`.

---

### Problem 10: No Terrain-Object Loading Coordination

**Severity:** Low-Medium (visual artifact, objects floating/sinking)
**Files:** `src/core/world/native_streaming_manager.gd`, Terrain3D integration

Object streaming and terrain streaming are independent. If objects for a cell load before the terrain chunk is ready, objects placed on the ground may be visible floating in mid-air or sunken below terrain until the terrain mesh appears.

**Fix options:**
- **Soft dependency:** Load objects normally but keep them hidden (`visible = false`) until terrain for that cell reports ready. Avoids blocking the loading pipeline.
- **Hard dependency:** Don't start object loading for a cell until terrain is confirmed loaded. Simpler but may increase time-to-playable.

---

## GPU Driven Renderer Analysis

**Document:** `docs/GPU_DRIVEN_RENDERER.md` (787 lines, 6 phases)

### What It Proposes

A CompositorEffect-based GPU pipeline that:
1. Stores all MID/FAR objects in GPU SSBOs (80 bytes/object)
2. Runs frustum culling + LOD selection on GPU compute shader (256 objects/workgroup)
3. Packs textures into Texture2DArray for bindless-style material access
4. Renders via indirect draw (Vulkan/D3D12) or MultiMesh readback (fallback)
5. Optionally uses RT acceleration structures for occlusion culling (Godot 4.7+)

### Architectural Strengths

- **Dual rendering path** with clean fallback (indirect draw → MultiMesh readback)
- **Reuses existing infrastructure** (RenderingContext, PostProcessEffect, MaterialLibrary)
- **Well-defined data structures** (SSBO layouts, push constants at exactly 128-byte limit)
- **Incremental streaming updates** via free-list slot allocation
- **Double-buffered SSBOs** matching the ocean FFT pattern
- **NEAR tier untouched** — physics/collision/animation kept as standard Node3D

### What It Solves

| Metric | Current | After GPU Renderer |
|--------|---------|-------------------|
| MID/FAR draw calls | 500-2000 | ~50-100 |
| Culling method | CPU per-object visibility_range | GPU compute (256 objects/cycle) |
| Material switches | Per-object StandardMaterial3D | Per-batch Texture2DArray lookup |
| MID/FAR Node3D count | Thousands | Zero (SSBO data only) |
| Impostor integration | Separate MultiMesh system | Unified batch pool |

### What It Does NOT Solve

| Problem | GPU Renderer Impact |
|---------|-------------------|
| 3+ second initial population | **No fix** — disk loading + instantiation still needed for NEAR |
| FPS drop on camera movement | **No fix** — scene tree teardown is NEAR-tier problem |
| `duplicate()` main thread bottleneck | **No fix** — NEAR tier still uses Node3D |
| Unbounded unloading spikes | **No fix** — `queue_free()` still synchronous |
| Objects behind camera loading first | **No fix** — streaming decision is pre-GPU |
| 10,000 objects in instantiation queue | **Partial fix** — MID/FAR skip Node3D, but still need data registration |

### Dependency Assessment

The GPU Driven Renderer requires the streaming pipeline to feed it object data. Currently, the streaming pipeline assumes every object becomes a Node3D. To enable the GPU path, `CellManager` and `NativeStreamingManager` need to be modified to:

1. **Classify objects by distance tier** before instantiation
2. **Route MID/FAR objects** to GPU scene database (SSBO registration only)
3. **Route NEAR objects** to the existing Node3D pipeline

This means streaming pipeline fixes (Problem 6 — tiered loading) are a **prerequisite** for GPU renderer integration. They should be implemented first.

### Recommended Phase Order

```
Phase 0: Benchmark scene (measure baseline)
Phase 1: Streaming pipeline fixes (this document)
Phase 2: GPU Driven Renderer Phase 1-2 (scene database + culling)
Phase 3: GPU Driven Renderer Phase 3-4 (materials + rendering)
Phase 4: GPU Driven Renderer Phase 5-6 (RT occlusion + polish)
```

---

## Proposed Fix Plan

### Status Overview

| Phase | Description | Status | Problems Addressed |
|-------|-------------|--------|-------------------|
| 0 | Benchmark Scene | DONE | Measurement baseline |
| 1 | Remove Dead Code | DONE | Problem 1 (parallel duplicate) |
| 2 | Budgeted Unloading | DONE | Problem 2 (unbounded free) |
| 3 | Frustum-Priority Loading | DONE | Problem 3 (no visibility awareness) |
| 4 | Bake Visibility Range | PENDING | Problem 4 (redundant config) |
| 5 | Tiered Loading | PENDING | Problem 6 (full scene tree for all), Problem 9 (cache), Problem 10 (terrain) |
| 6 | World-Level MultiMesh | PENDING | Problem 5 (cell-scoped batching) |

### Phase 0: Benchmark Scene (Prerequisite) — DONE

**Goal:** Repeatable, automated performance measurement.
**Priority:** IMMEDIATE — cannot validate any optimization without this.
**Estimated effort:** 1 session.
**Status:** Implemented in `src/tools/streaming_benchmark.gd` (786 lines).

Create `src/tools/streaming_benchmark.tscn` + `streaming_benchmark.gd`:

- Place known models from prebaked cache at fixed positions across 4-5 cells
- Camera follows a spline path: approach from distance → fly through → orbit
- Per-frame logging: frame_time_ms, objects_loaded, objects_in_tree, draw_calls, memory_mb
- Output CSV to `user://benchmark_results/`
- Console command: `benchmark_streaming` to run from world explorer

See [Benchmark Scene Specification](#benchmark-scene-specification) for full details.

### Phase 1: Remove Dead Code — DONE

**Goal:** Reduce complexity before optimizing.
**Priority:** High (makes all subsequent work easier).
**Estimated effort:** 1 session.
**Status:** Parallel duplicate system removed (~220 lines). Dead constants removed from streaming_config.gd.

1. **Replace parallel duplicate with sequential loop** — remove `_dispatch_parallel_duplicates()`, `_process_parallel_duplicate_results()`, `_parallel_duplicate_mutex`, `_parallel_duplicate_results`, `_parallel_duplicate_active`, `_parallel_duplicate_pending`, `_parallel_duplicate_stats`. Replace with inline `duplicate()` in the instantiation loop.

2. **Remove unused streaming_config constants** — `MATERIAL_POOL_SIZE`, `MATERIAL_POOL_PREWARM` (pool not implemented), `GPU_OBJECT_THRESHOLD`, `GPU_VISIBILITY` section (GPU renderer not integrated yet).

3. **Simplify BackgroundProcessor** — don't add to scene tree in runtime mode, or repurpose for actual runtime work.

**Expected impact:** ~300 fewer lines, simpler debugging, no behavior change.

### Phase 2: Budgeted Unloading — DONE

**Goal:** Eliminate frame spikes during cell transitions.
**Priority:** Critical (direct cause of movement stutter).
**Estimated effort:** 1 session.
**Status:** `_process_budgeted_unloading()` added with 4ms budget, pool return, cell reclaim on re-entry.

Replace `cell_node.queue_free()` with staged unloading:

```
Frame 1: Remove cell from _loaded_cells, mark as "unloading"
Frame 2-N: Remove up to K children per frame (budget: 4ms)
Frame N+1: Free empty cell container node
```

Objects closest to camera boundary free last (they might re-enter radius). Objects farthest from camera free first.

**Implementation approach:**
- New `_unloading_cells` dictionary: `Vector2i → {node: Node3D, children_remaining: int}`
- In `_process()`: before loading, spend up to 4ms on unloading
- Track `_stats["unloading_cells"]` for diagnostics

**Expected impact:** Eliminate 15-40ms frame spikes during cell transitions. Replace with steady 4ms/frame unloading cost.

### Phase 3: Frustum-Priority Loading — DONE

**Goal:** Load visible objects 4x faster than non-visible.
**Priority:** High (40-60% loading budget was wasted before fix).
**Estimated effort:** 1 session.
**Status:** `_sort_queue_by_priority()` replaces distance-only sort. Camera forward dot product gives 4x penalty to behind-camera objects.

Modify `_sort_queue_by_distance()` to incorporate frustum awareness:

```gdscript
func _sort_queue_by_priority() -> void:
    var cam_transform := _camera.global_transform
    var cam_forward := -cam_transform.basis.z
    var cam_pos := cam_transform.origin

    _instantiation_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        var pos_a: Vector3 = a.get("position", Vector3.ZERO)
        var pos_b: Vector3 = b.get("position", Vector3.ZERO)

        # Dot product with camera forward = how "in front" the object is
        var dir_a := (pos_a - cam_pos).normalized()
        var dir_b := (pos_b - cam_pos).normalized()
        var dot_a := cam_forward.dot(dir_a)
        var dot_b := cam_forward.dot(dir_b)

        # Objects in front (dot > 0.3) get 4x priority boost
        var priority_a := cam_pos.distance_squared_to(pos_a)
        var priority_b := cam_pos.distance_squared_to(pos_b)
        if dot_a < 0.3:
            priority_a *= 4.0  # Behind camera = lower priority
        if dot_b < 0.3:
            priority_b *= 4.0

        return priority_a < priority_b
    )
```

**Expected impact:** Visible objects populate 2-4x faster. Time-to-visually-complete drops from ~3.3s to ~1-1.5s (objects behind camera still load, just slower).

### Phase 4: Bake Visibility Range into Prebaked Models

**Goal:** Eliminate redundant `_configure_cell_visibility()` pass.
**Priority:** Medium (saves 25-100ms across initial load).
**Estimated effort:** 1 session.

Modify the prebaking pipeline (`model_prebaker.gd`) to set visibility_range on every GeometryInstance3D before saving the PackedScene. At runtime, skip `_configure_cell_visibility()` entirely for prebaked cells.

**Changes:**
1. `model_prebaker.gd`: After converting NIF, call `_lod_configurator.configure_near_object()` / `configure_mid_object()` on each mesh before saving
2. `native_streaming_manager.gd`: Remove `_configure_cell_visibility()` call for async-loaded cells (keep for sync fallback/debug)
3. Add metadata to prebaked scenes: `cell_node.set_meta("visibility_prebaked", true)`

**Expected impact:** Save 0.5-2ms per cell × 49 cells = 25-100ms total, plus code simplification.

### Phase 5: Tiered Loading (MID Objects Skip Scene Tree)

**Goal:** 70% of objects bypass expensive Node3D pipeline.
**Priority:** High (foundational for GPU renderer integration).
**Estimated effort:** 2 sessions.

Classify objects by their distance to camera AT QUEUE TIME:

- **NEAR tier (< 150m):** Full Node3D pipeline (current behavior)
- **MID tier (150-500m):** Register with RenderingServer directly (like StaticObjectRenderer) or with a world-level MultiMesh manager. No Node3D, no `add_child()`, no collision.
- **FAR tier (> 500m):** Impostor system (already working, no change)

**When an object transitions from MID → NEAR** (camera approaches):
1. Promote: Create full Node3D, add collision, add to scene tree
2. Remove lightweight RenderingServer representation
3. Apply crossfade during transition (reuse existing fade-in shader)

**When NEAR → MID** (camera recedes):
1. Demote: Remove Node3D, create lightweight representation
2. `queue_free()` the full node (budgeted)

This is the critical prerequisite for GPU Driven Renderer integration (Phase 2 of the GPU doc routes MID/FAR to SSBO instead of Node3D).

**Proven pattern:** `static_object_renderer.gd` (378 lines) already implements scene-tree-free rendering for flora using `RenderingServer.instance_create()` + `instance_set_base()` / `instance_set_scenario()` / `instance_set_transform()`. This should be generalized for all MID-tier objects, not just flora.

**Godot-specific constraints to address:**

- **Animated objects:** Objects with `AnimationPlayer` nodes (NPCs, creatures, animated doors) CANNOT use RenderingServer RIDs — they must remain as Node3D even in MID tier. Filter by `has_animation` metadata during classification.
- **Multi-surface meshes:** A single `MeshInstance3D` with multiple surfaces requires one RenderingServer instance RID per surface (each surface can have different material). Track surface count in prebaked metadata.
- **MID→NEAR crossfade:** When promoting, the lightweight RID instance and the new Node3D briefly coexist to prevent a visible pop. Remove the RID instance after the fade-in completes (~0.3s).
- **Memory for MID data:** Each MID object needs: mesh RID, material RID(s), Transform3D, cell reference. ~80-120 bytes/object vs. ~2-8KB for a full Node3D subtree. At 7000 MID objects, that's ~560KB-840KB vs. ~14-56MB.

**Expected impact:** ~70% fewer `duplicate()` calls, ~70% fewer `add_child()` calls, ~70% fewer nodes in scene tree. Time-to-playable drops to < 1 second.

### Phase 6: World-Level MultiMesh Batching

**Goal:** Reduce draw calls for common repeated objects.
**Priority:** Medium (rendering optimization, superseded by GPU renderer).
**Estimated effort:** 1 session.

Create `MultiMeshWorldBatcher` that:
1. Maintains one MultiMesh per unique model (world-scope, not cell-scope)
2. On cell load: add instances to the batch
3. On cell unload: remove instances from the batch
4. Rebuild MultiMesh buffer when dirty (batched, max 4 rebuilds/sec)

This is a simpler version of GPU Driven Renderer Phase 4 (`MultiMeshBatchPool`) and can serve as a stepping stone.

**Expected impact:** 30-50% fewer draw calls for common objects (barrels, rocks, containers).

---

## Benchmark Reference

**Implementation:** `src/tools/streaming_benchmark.gd` (786 lines) + `src/tools/streaming_benchmark.tscn`

6-segment camera path: idle → approach → orbit → sprint → teleport → return. Per-frame metrics logged to CSV (`user://benchmark_results/`). Console commands: `benchmark_streaming`, `benchmark_streaming_quick`.

### Console Commands

```
benchmark_streaming          — Full benchmark run, print summary
benchmark_streaming_quick    — Abbreviated run
```

### Success Criteria

| Metric | Baseline (run benchmark) | Target (after Phase 6) |
|--------|--------------------------|----------------------|
| Time to stable 60 FPS | TBD | < 1.0 seconds |
| Max frame time during movement | TBD | < 20ms |
| P99 frame time (steady state) | TBD | < 12ms |
| Objects in scene tree (3-cell radius) | TBD | < 3,000 (NEAR only) |
| Draw calls (loaded area) | TBD | < 200 (before GPU renderer) |

**Action:** Run `benchmark_streaming` to establish baseline values before starting Phase 4.

---

## File Reference

### Already Modified (Phases 0-3)

| File | Changes | Status |
|------|---------|--------|
| `src/core/world/cell_manager.gd` | Removed parallel duplicate system, simplified instantiation loop | DONE |
| `src/core/world/native_streaming_manager.gd` | Added budgeted unloading, frustum-priority queuing | DONE |
| `src/core/world/streaming_config.gd` | Removed unused constants, added unloading budget constants | DONE |
| `src/tools/streaming_benchmark.gd` | Created benchmark (786 lines, 6-segment camera path, CSV output) | DONE |
| `src/tools/streaming_benchmark.tscn` | Created benchmark scene | DONE |

### Files to Modify (Phases 4-6)

| File | Changes | Phase |
|------|---------|-------|
| `src/core/world/lod_configurator.gd` | Add prebake-time configuration method | 4 |
| `src/tools/prebaking/model_prebaker.gd` | Bake visibility_range into PackedScene | 4 |
| `src/core/world/native_streaming_manager.gd` | Tiered loading (route MID to RenderingServer) | 5 |
| `src/core/world/cell_manager.gd` | Distance-tier classification at queue time | 5 |
| `src/core/world/reference_instantiator.gd` | Lightweight MID representation path | 5 |
| `src/core/world/static_object_renderer.gd` | Generalize for all MID-tier objects (not just flora) | 5 |
| `src/core/world/model_loader.gd` | LRU cache eviction, memory budget | 5-6 |

### Files to Create (Phases 5-6)

| File | Purpose | Phase |
|------|---------|-------|
| `src/core/world/multimesh_world_batcher.gd` | Cross-cell MultiMesh batching | 6 |

---

## Metrics to Track

### Frame Budget Breakdown (Target: 16.67ms at 60 FPS)

| System | Budget | Current (est.) | Notes |
|--------|--------|---------------|-------|
| Rendering (Godot engine) | 8ms | 6-10ms | Varies by scene complexity |
| Streaming: instantiation | 4ms | 8ms (configured) | Reduced from 8ms after fixes |
| Streaming: unloading | 2ms | 2-4ms (budgeted) | Fixed in Phase 2. Was UNBOUNDED (40ms spikes) |
| Physics (Jolt) | 2ms | 1-2ms | Generally fine |
| GDScript overhead | 0.67ms | ~1ms | Signals, _process, etc. |

### Key Performance Indicators

1. **Time-to-playable (TTP):** Frames from scene load to stable 60+ FPS
2. **Movement stutter (P99):** 99th percentile frame time during camera movement
3. **Object throughput:** Objects instantiated per second
4. **Scene tree node count:** Total nodes in tree (lower = better)
5. **Draw call count:** Via `Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)`
6. **Memory usage:** Static + dynamic via `Performance.get_monitor(Performance.MEMORY_STATIC)`

---

## Appendix: Constants Reference

From `src/core/world/streaming_config.gd`:

| Constant | Value | Purpose |
|----------|-------|---------|
| NEAR_END | 150.0m | NEAR→MID boundary |
| MID_END | 500.0m | MID→FAR boundary |
| FAR_END | 5000.0m | FAR→nothing boundary |
| INSTANTIATION_BUDGET_MS | 8.0ms | Per-frame loading budget |
| NEAR_BURST_BUDGET_MS | 12.0ms | Burst loading for close objects |
| MAX_INSTANTIATIONS_PER_FRAME | 50 | Hard cap on objects/frame |
| MAX_ASYNC_REQUESTS | 6 | Concurrent cell load requests |
| MAX_INSTANTIATION_QUEUE | 8000 | Queue size cap |
| UNLOAD_BUDGET_MS | 4.0ms | Per-frame unloading budget (new) |
| UNLOAD_BATCH_SIZE | 30 | Max children per unloading cell per frame (new) |
| FADE_DURATION | 0.3s | Object fade-in time |
| CELL_SIZE | 117.12m | Morrowind cell dimension |

From `src/core/world/native_streaming_manager.gd`:

| Property | Default | Purpose |
|----------|---------|---------|
| load_radius_cells | 3 | Cells to keep loaded (~49 cells in diamond) |
| max_load_distance | 800.0m | Hard distance cap |
| frame_budget_ms | 8.0ms | Instantiation time budget |
| async_loading_enabled | true | Use async path |
| impostor_radius_cells | 60 | Impostor coverage (~7km) |
| STARTUP_PHASE_FRAMES | 30 | Staggered loading duration |
