# Godotwind Streaming Architecture Audit & Recommendation (January 2026)

## ✅ MIGRATION COMPLETE (January 2026)

**Status: The rewrite has been successfully completed and deployed.**

The custom 10,000+ line streaming system has been replaced with a native Godot-based implementation (~1,500 lines). The legacy system remains in `src/core/world/deprecated/` for reference.

---

## Executive Summary (Original Recommendation)

**Recommendation: HYBRID REWRITE — Targeted component replacement using Godot native features**

After comprehensive audit of the codebase (~10,700+ lines of custom streaming code) and Godot 4.4/4.5 capabilities, the recommendation was to rewrite the system to leverage engine-native visibility features while preserving the valuable octahedral impostor pipeline.

**This recommendation has been implemented.**

---

## 1. Code Metrics (Current Implementation)

| Component | Lines | Purpose | Verdict |
|-----------|-------|---------|---------|
| `object_streamer.gd` | 3,273 | Object pool, heap eviction, tier state machines | DELETE - Engine handles this |
| `world_streaming_manager.gd` | 2,235 | Orchestration, queue management | SIMPLIFY drastically |
| `distance_tier_manager.gd` | 1,574 | Visibility authority, GPU compute | DELETE - Use `visibility_range` |
| `impostor_manager.gd` | 1,529 | Octahedral impostor rendering | KEEP - Godot doesn't have this |
| `gpu_visibility_manager.gd` | 941 | GPU sparse readback optimization | DELETE - Engine does this in C++ |
| `lod_multimesh_batcher.gd` | 903 | MultiMesh batch management | DELETE - Native LOD handles batching |
| `visibility_compute.glsl` | 230 | GPU tier calculation | DELETE - Unnecessary with native |
| **Total** | **~10,700** | Custom visibility engine | ~90% can be deleted |

---

## 2. Godot 4.4/4.5 Native Capabilities (2026)

### What the Engine Does For Free

| Feature | Native API | Performance |
|---------|-----------|-------------|
| **Distance culling** | `visibility_range_begin/end` | C++ engine core |
| **LOD swapping** | Automatic with `visibility_range` | Zero GDScript overhead |
| **Hysteresis** | `visibility_range_begin_margin/end_margin` | Built-in flicker prevention |
| **Fade transitions** | `visibility_range_fade_mode = DEPENDENCIES` | Native dithering with TAA |
| **Frustum culling** | Automatic | Engine core |
| **Async loading** | `ResourceLoader.load_threaded_request` | Engine threading |

### What Godot Does NOT Have Natively

| Feature | Status | Action |
|---------|--------|--------|
| **Octahedral Impostors** | ❌ Not native (community plugins only) | KEEP your `ImpostorManager` |
| **16-frame atlas rendering** | ❌ Not native | KEEP your `ImpostorBakerV2` |

---

## 3. The Core Problem: Fighting the Engine

The current architecture manually replicates what Godot does efficiently in C++:

```
CURRENT: GDScript visibility loops (20ms CPU) → GPU compute (1ms) → Readback → Apply
NATIVE:  Set visibility_range properties once → Engine handles everything (0ms GDScript)
```

**Example of unnecessary complexity:**

```gdscript
# CURRENT: 1,574 lines in distance_tier_manager.gd
func update_visibility(camera_cell: Vector2i, delta: float) -> void:
    # ... 500+ lines of tier calculation, hysteresis, GPU dispatch ...

# NATIVE: Zero lines of code
# Just set these properties on the MeshInstance3D:
mesh_instance.visibility_range_begin = 0.0
mesh_instance.visibility_range_end = 150.0
mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES
```

---

## 4. Proposed New Architecture (~1,000 lines total)

```
NativeStreamingManager (simplified coordinator, ~300 lines)
├── CellLoader (~200 lines)
│   └── Loads cells, sets visibility_range on spawned MeshInstance3D
│
├── ImpostorRenderer (~400 lines, kept from current)
│   └── Octahedral impostor rendering with visibility_range integration
│
├── LODConfigurator (~100 lines)
│   └── Helper to set up LOD chains with proper visibility_range
│
└── Godot Engine (Native, 0 lines)
    ├── visibility_range_begin/end (C++ culling)
    ├── visibility_range_fade_mode (native crossfade)
    ├── Automatic frustum culling
    └── ResourceLoader.load_threaded_request
```

### Key Design Decisions

1. **No custom visibility authority** — Engine is the authority
2. **No GPU compute shaders for visibility** — Engine does this in C++
3. **No tier state machines** — Just set `visibility_range` once per object
4. **Keep impostors** — Use `visibility_range_begin = 500.0` to trigger swap

---

## 5. Migration Strategy

### Phase 1: Proof of Concept (Day 1)
- Create minimal test scene with LOD chain + impostor
- Verify native `visibility_range` works correctly
- Document exact property values needed

### Phase 2: Core Implementation (Days 2-3)
- Create `NativeStreamingManager` from scratch
- Integrate with existing `CellManager` data loading
- Implement `LODConfigurator` helper

### Phase 3: Impostor Integration (Day 4)
- Extract impostor rendering from `ImpostorManager`
- Add `visibility_range` integration for LOD→Impostor transition
- Keep octahedral shader and texture array logic

### Phase 4: Cleanup (Day 5)
- Move deprecated files to `src/core/world/deprecated/`
- Update documentation
- Performance validation

---

## 6. Files to Keep vs Delete

### ✅ KEEP (Valuable Custom Code)
```
src/core/world/impostor_manager.gd     # Octahedral rendering (refactor to use visibility_range)
src/core/world/shaders/               # Impostor shaders, crossfade shaders
src/core/world/cell_manager.gd        # Cell data loading
src/core/world/model_loader.gd        # Model loading and caching
src/core/world/distance_utils.gd      # Distance constants (reference only)
src/tools/prebaking/                  # Asset prebaking pipeline
```

### ❌ DELETE (Replaced by Native Features)
```
src/core/world/distance_tier_manager.gd      # Native visibility_range replaces this
src/core/world/object_streamer.gd            # Tier state machines unnecessary
src/core/world/gpu_visibility_manager.gd     # GPU compute unnecessary
src/core/world/gpu_visibility_renderer.gd    # Phase 2 never completed
src/core/world/shaders/visibility_compute.glsl    # Unnecessary
src/core/world/shaders/unified_visibility.glsl    # Unnecessary
src/core/world/lod_multimesh_batcher.gd      # Native LOD handles batching
src/core/world/streaming_profiler.gd         # Much simpler profiling needed
```

### 🔄 SIMPLIFY (Keep but drastically reduce)
```
src/core/world/world_streaming_manager.gd    # 2,235 → ~300 lines
src/core/world/streaming_config.gd           # Simplify quality presets
```

---

## 7. Risk Assessment

| Risk | Mitigation |
|------|------------|
| Native visibility_range may have edge cases | Phase 1 proof-of-concept validates before full migration |
| Impostor transition quality | Keep crossfade shaders, just change trigger mechanism |
| Performance regression | Native is faster; benchmark to confirm |
| Data migration | Cell/model loading unchanged; only rendering changes |

---

## 8. Verification Plan

### Automated Tests
- FPS benchmark: Load Balmora with 5,000+ objects
- Memory benchmark: Track VRAM usage during streaming
- Visibility test: Walk through world, verify tier transitions

### Manual Verification
- Visual quality: No popping, smooth LOD transitions
- Impostor quality: Octahedral rendering still works
- Edge cases: Teleportation, fast movement, turning around

---

## 9. Conclusion

**Rewrite is the correct choice.** The current codebase is a "game engine inside a game engine" that manually manages visibility in ~10,000 lines of GDScript when Godot handles this natively in C++ with zero lines of code.

The impostor pipeline is valuable and should be preserved. Everything else should be replaced with native Godot features.

---

*Last updated: January 7, 2026*
*Audited by: Claude (Gemini/Opus audit confirmed)*




###################################


# Godot Native Streaming Migration Walkthrough

## Overview
We have migrated the custom GDScript-based streaming system to Godot's native `visibility_range` system. This simplifies the codebase, improves performance, and reduces engine API overhead.

## Key Changes

### 1. Architecture Shift
| Old System | New System |
|------------|------------|
| **Streaming Logic** | Custom GDScript spatial hashing and distance checks | Native `visibilty_range` + Simplified Grid Manager |
| **Culling** | Manual `visible = false` / GPU Compute | Engine-handled Culling (Frustum + Distance) |
| **LOD** | Custom `LODManager` swapping meshes | Native `visibility_range_begin/end` |
| **Impostors** | Complex `ImpostorManager` | `NativeImpostorRenderer` (Shader-based fading) |

### 2. New Components
*   **`NativeStreamingManager.gd`**: Lightweight orchestrator. Manages cell loading radius and instantiates the impostor renderer.
*   **`NativeImpostorRenderer.gd`**: Handles "Far" objects (~500m to 5km). Uses `MultiMesh` with a custom octahedral shader.
*   **`LODConfigurator.gd`**: Helper to configure visual ranges for standard objects.

### 3. Impostor Integration
The new impostor system is fully integrated:
*   **Smart Loading**: Impostors are loaded in chunks (cells) around the camera.
*   **Cross-Fading**: 
    *   Real objects fade OUT at ~500m (handled by `LODConfigurator`).
    *   Impostors fade IN at ~500m (handled by custom shader).
    *   This provides a seamless transition without popping.
*   **Rotation Support**: Impostors correctly respect object rotation using per-instance custom data in the shader.

## Verification

### Migration Status
**✅ Migration Complete**: The native streaming system is now the only implementation. The legacy system has been removed from `world_explorer.gd`.

### Verification Steps
1.  **Run World Explorer**: Launch the World Explorer tool.
2.  **Check Overlay**: Ensure the debug overlay shows "Native Streaming: Active".
3.  **Fly Around**: 
    *   Move fast (Shift/Sprint) to verify cell loading speed.
    *   Check memory usage in the debugger.
4.  **Observe Distant Objects**:
    *   Look at landmarks (Vivec, Red Mountain).
    *   Fly closer and watch the transition from Impostor -> Real Object.
    *   It should be a smooth cross-fade, not a hard pop.
5.  **Check Stats**:
    *   Verify "Total Impostors" count in the stats panel.
    *   Verify "Loaded Cells" updates as you move.

## Troubleshooting
*   **Missing Impostors**: Ensure `impostor_radius_cells` in `NativeStreamingManager` is large enough (default 40).
*   **Hard Popping**: Check `DU.FADE_MARGIN` in `distance_utils.gd`. Default is 50m.

## Next Steps

### Cleanup Complete ✅
1. ✅ Orphaned files moved to `src/core/world/deprecated/` (chunk_renderer.gd, quadtree_chunk_manager.gd)
2. ✅ Legacy streaming system removed from world_explorer.gd
3. ✅ References to deprecated code cleaned up in active files
4. ✅ Documentation updated to reflect migration

### Future Actions (Optional)
1. After thorough testing, the entire `src/core/world/deprecated/` directory can be deleted
2. Remove the `valid_model_paths` cache if necessary
