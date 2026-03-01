# C1: Streaming Pipeline Deep Audit

**Date:** 2026-03-01
**Auditor:** Claude
**Status:** Audit Complete, Fix Pass 1 In Progress

## Overview
Audited 15 core files (~10,000 lines) covering the full streaming pipeline from camera movement to RenderServer instantiation.

## Findings Summary

### Critical Issues
1. **pop_front() violations** (S-01) — `native_impostor_renderer.gd:521` and `cell_manager.gd` use `pop_front()` in hot loops (O(n)).
2. **Missing wait_for_task_completion()** (S-02) — `background_processor.gd` discards Job IDs for background tasks, making it impossible to wait for completion during `_exit_tree()` or cell priority changes.
3. **Dead SceneTree objects** (S-10) — `NativeStreamingManager` tracks `_unloading_cells` but doesn't check `is_instance_valid()` before accessing them in the deferred unloader.

### Performance Bottlenecks
1. **Impostor Spatial Index missing** (S-05) — `NativeImpostorRenderer` uses a linear search/dictionary keys for cell unloading. Needs a grid-based spatial hash for O(1) cell lookup.
2. **Uncached FileAccess.file_exists()** (S-03) — Impostor renderer checks disk every time for impostor existence.
3. **ObjectPool O(n) release** (S-08) — `object_pool.gd:155` iterates through the full `in_use` array to find an item.
4. **Redundant visibility calls** (S-09) — `StaticObjectRenderer` still has a `update_visibility_by_distance` method that is a no-op but called in some tool scripts.

### Technical Debt / Correctness
1. **CELL_SIZE Inconsistency** (S-04) — `streaming_config.gd` says 117.12, `distance_utils.gd` says 117.0. Needs one source of truth (CoordinateSystem).
2. **Dead Infra** (G-01, G-02, S-11) — `static_mesh_merger.gd` is never used. `mesh_simplifier_v2.gd` is a broken fallback. `model_loader.gd` has dead resource prep methods.
3. **Stale comments** (S-13) — Line counts and "removed node" comments are inaccurate in core managers.
4. **LOD boundary duplication** (S-12) — LOD sub-tier boundaries (250/375/500m) duplicated in `lod_configurator.gd` AND `streaming_config.gd`.

## Detailed Log
(See chat history for line-by-line audit notes)
