# NIF Collision — Part 2: Trimesh Fallback

> Open plan. Split out from `docs/audit/NIF_COLLISION_COORDINATE_BUG.md` during 2026-04-18 cleanup. Part 1 (primitive-collision coordinate fix) shipped 2026-04-15. Part 2 below is still open. Current coordinate invariant documented in `docs/systems/nif_pipeline.md`.

**Status:** deferred. Run Part 1 verification first (clear cache, rebake, launch with `--debug-collisions`) and see what's still missing before committing to Part 2 — most stairs actually have collision blocks, they were just placed wrong, and Part 1 may have unblocked them.

## Scope

Safety net for NIFs with **no collision at all** — no `RootCollisionNode`, no `bhkCollisionObject`, nothing for `nif_collision_builder.gd::build_collision()` to build from. Today those models instantiate with zero collision and characters walk straight through them. Some stair meshes were reported in this state during the 2026-04-09 character-debug session.

## Design

In `src/core/nif/nif_converter.gd:630`:

```gdscript
if load_collision:
    var collision_result := _collision_builder.build_collision()
    if collision_result.has_collision:
        # ... existing path
    else:
        # Fallback: generate a concave trimesh from visual surfaces so the
        # character can't walk through. Catches NIFs with no RootCollisionNode
        # or bhkCollisionObject at all (some stair meshes are in this state).
        var fallback_body := _build_trimesh_fallback_from_visuals(root)
        if fallback_body != null:
            root.add_child(fallback_body)
```

`_build_trimesh_fallback_from_visuals` walks the visible `MeshInstance3D` descendants, aggregates their triangles via `create_trimesh_shape()`, and wraps them in a single `StaticBody3D`. Skip meshes marked with the `_is_foliage` / `_is_glow` / particle metadata that shouldn't block movement.

## Caveats

- Trimesh collision is expensive per-contact vs primitive shapes. Keep this path as a fallback, not a default.
- Coordinate frame: the visual meshes are already Godot-space (converted at bake by `nif_converter.gd:943`), so the fallback collision inherits correct coordinates for free.
- Animated / skinned meshes should be excluded — trimesh collision on a skinned body is meaningless.

## Verification

After adding the fallback:

1. Identify NIFs that enter the `else` branch (log on first hit per path).
2. Launch `scenes/Godotwind.tscn --debug-collisions`, fly to cells containing those NIFs, confirm cyan wireframe now overlays the visible geometry.
3. Press P for player mode, verify step-up / walk-through is blocked.

## References

- `docs/audit/NIF_COLLISION_COORDINATE_BUG.md` — full diagnostic + Part 1 math
- `docs/systems/nif_pipeline.md` — coordinate invariant post-Part-1
- Canonical step-up: `inspos/openmw/apps/openmw/mwphysics/stepper.cpp`
