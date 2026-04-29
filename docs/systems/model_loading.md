# Model Loading — PackedScene Cache

Async-streaming pattern adapted from Unreal `StreamableManager` / Unity Addressables: the model cache stores `PackedScene`, callers `instantiate()` on demand. No shared `Node3D` instances, no mid-load file races, no reparent-owner hazards.

## Files

- `src/core/world/model_loader.gd` — `_model_cache: Dictionary` keyed by cache_key, holds `PackedScene` (or `null` for failed loads). Async + sync load paths, MAX_CACHE_SIZE LRU eviction.
- `src/core/world/reference_instantiator.gd` — per-ref instantiation. Calls `model_loader.get_model()` and routes the resulting `Node3D` into the scene graph.
- `src/core/world/cell_static_collision.gd` — owns per-cell merged-trimesh collision (see below).

## Cache invariant

`_model_cache` stores `PackedScene`, not pre-instantiated `Node3D`. Every cell stream calls `PackedScene.instantiate()` for a fresh tree. Cache walks at `_model_cache[cache_key]` (`model_loader.gd:54`).

## Static collision — per-cell merged trimesh (current canonical, 2026-04-25)

Static collision is **not** per-prefab `CollisionShape3D`. Win 1 + Win 2 of the NEAR-tier refactor (2026-04-25) replaced that with one merged `ConcavePolygonShape3D` per cell, registered via `PhysicsServer3D.body_create()` (server-direct, no `StaticBody3D` Node wrapper).

Three-step pipeline in `cell_static_collision.gd`:

1. `collect_classified_refs(grid, cell_record, use_static)` — MAIN thread. Filters refs via the static classifier, resolves shape-pack sidecars, packs into a `BuildPayload`.
2. `worker_collect_triangles(payload)` — WORKER thread (WorkerThreadPool). Walks shapes, transforms to world space, packs into `payload.vertices`. Reads from a worker-safe shape cache.
3. `finalize_body(payload, world_3d)` — MAIN thread. `set_faces` (BVH build) + `PhysicsServer3D.body_create` + space registration. Returns a `FinalizedBody` (body RID + strong-ref to the trimesh Shape3D so its internal RID stays alive).

Driven by `_tick_static_collision_build` in `cell_manager.gd`. One cell finalized per frame; body lifetime tracked on `AsyncCellRequest.collision_body`, freed via `free_body` on cancel / unload / shutdown. Shapes come from the shared `StaticShapeCache` (per-prototype LRU keyed on `model_path`); first-time extraction loads the prebaked `.shapes.res` sidecar (~sub-ms) or falls back to a PackedScene walker (~20-50ms).

**Why per-cell rather than per-prefab:** statics_no_node3d (T.1) moved static rendering to RenderingServer-direct (MultiMesh slots, no Node3D). That eliminated ~10k per-object `StaticBody3D` registrations in Jolt's broadphase but also removed collision. Per-cell merged trimesh restores it without re-introducing the broadphase storm.

**Debug visibility caveat:** server-direct bodies do NOT show up in Godot's "Visible Collision Shapes" overlay. Per-cell collision counts surface via the `print_streaming_stats` console command. For visual wireframe debugging, walk the manager's RID list and ImmediateMesh-draw — see `docs/research/server_direct_pattern.md`.

## Carry held-body carve-out

The held `RigidBody3D` from the carry/pickup system has its own physics-interpolation carve-out and does **not** follow the streaming-level collision flow. See `docs/systems/interaction_system.md` §6 (HL2 physics-gun velocity drive) and `carry_controller.gd`.

## Cross-refs

- `docs/research/server_direct_pattern.md` — reduz's server-direct pattern that motivated Win 2.
- `docs/audit/godot_46_near_streaming_aaa_audit_2026_04_29_codex.md` — current authoritative audit covering Wins 0-5.
