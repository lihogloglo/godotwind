# NIF Collision Coordinate Bug — Prebaker Hand-Off

**Status:** diagnosed, NOT fixed
**Discovered:** 2026-04-09 during character controller debug session
**Scope:** `src/core/nif/nif_collision_builder.gd`, cascades into every cached model with non-trivial NIF hierarchy
**Impact:** stair clipping, floating collision wireframes hundreds of meters from their visual meshes, characters falling through static geometry

---

## Symptom

When launching `scenes/Godotwind.tscn` with `--debug-collisions`, cyan collision wireframes appear as expected on many objects, but:

1. **Many objects (including stairs) have no visible collision outline at all** — characters walk straight through them.
2. **Many outlines float in midair, dozens to hundreds of meters away from the visual mesh they should be attached to.**
3. **Only objects at/near the NIF origin with trivial (identity or near-identity) hierarchy transforms appear correct.**

Downstream consequences:
- Characters clip through stair meshes in Balmora, guild halls, temples — the step-up code has nothing to probe against.
- Characters fall through terrain or bridges in specific spots, triggering swim mode at arbitrary ground positions.
- Visual-coordinate bugs (floating trees, mis-placed rocks) are a SEPARATE but adjacent failure mode, likely traceable to the same asymmetric coordinate handling in the NIF import chain.

---

## Root Cause — Asymmetric Coordinate Conversion

The NIF importer has two parallel paths that walk the same NIF scene graph:

### Visual mesh path (CORRECT)

`src/core/nif/nif_converter.gd:943` + `:978` + `:1072`:

```gdscript
node.transform = _convert_nif_transform(ni_node.transform.to_transform3d())
mesh_instance.transform = _convert_nif_transform(shape.transform.to_transform3d())
```

Each local transform is converted from MW Z-up to Godot Y-up via `_convert_nif_transform` (which delegates to `CoordinateSystem.transform_to_godot`) BEFORE being assigned to a Node3D. Godot's scene graph then accumulates the converted locals correctly.

### Collision shape path (BUGGY)

`src/core/nif/nif_collision_builder.gd:189-190`:

```gdscript
var local_transform := node.transform.to_transform3d()        # NOT converted
var world_transform := parent_transform * local_transform     # accumulated in NIF Z-up
```

And the same pattern in `_process_collision_geometry` at `:243-244`. Transforms stay in NIF Z-up space all the way through the traversal.

Then at `:352` inside `_create_shape_from_geometry`, VERTICES are converted:

```gdscript
converted_vertices[i] = _convert_nif_vector(vertices[i])
```

So the final collision shape has:
- **Y-up vertices** (converted)
- Positioned by a **Z-up world transform** (un-converted)

These two are in **different coordinate spaces** being multiplied together at the same matrix product. The result is placed at an arbitrary position in world space that bears no geometric relationship to where the visual mesh sits.

The bounding-volume path (`_create_shape_from_bounding_volume` at `:268`) has the same problem: `bv.sphere.center`, `bv.box.center`, `bv.box.extents`, `bv.capsule.center`, and `bv.capsule.axis` are all converted via `_convert_nif_vector` or `_convert_nif_basis` while the enclosing `transform` parameter is still in NIF Z-up.

### Why some objects work and some don't

- **Object at origin with identity NIF hierarchy**: `world_transform = identity`, so `world_transform * v_godot = v_godot`. Collision lands where the visual mesh is. **Appears correct.**
- **Object with non-trivial hierarchy** (nested NiNodes, translations, rotations — typical for architecture meshes including multi-step staircases): each level of the tree multiplies the wrong matrix, the error compounds. Collision drifts progressively further from visual as depth increases. **Appears floating.**

Morrowind stair NIFs typically use a `root → stair_group → step_N` hierarchy with per-node translations expressed in NIF Z-up coordinates. Compound multiplication of un-converted transforms scatters the step collision shapes across the cell.

---

## Math Check

`CoordinateSystem.transform_to_godot` (`src/core/coordinate_system.gd:195`) is a pure similarity transform:

```gdscript
static func transform_to_godot(mw: Transform3D) -> Transform3D:
    return Transform3D(basis_to_godot(mw.basis), vector_to_godot(mw.origin))
```

where `basis_to_godot` implements `R' = C * R * C^T` with `C` the MW→Godot change-of-basis matrix (`:173-180`).

Similarity transforms distribute over concatenation:

```
transform_to_godot(A * B) == transform_to_godot(A) * transform_to_godot(B)
```

Therefore either (a) converting each local transform before accumulation, or (b) converting the final accumulated world transform, will give identical results. The current code does **neither** at the transform level and **only** converts vertices — the single approach guaranteed to produce an incoherent shape.

---

## Canonical Fix

### Part 1 — Symmetry with the visual path (primary fix)

In `nif_collision_builder.gd`:

1. **`_process_collision_node` (`:189-190`)** — convert the local transform before accumulation:
   ```gdscript
   var local_transform := CS.transform_to_godot(node.transform.to_transform3d())
   var world_transform := parent_transform * local_transform
   ```
   (Add `const CS := preload("res://src/core/coordinate_system.gd")` to the file header if not already present — it is, at line 28.)

2. **`_process_collision_geometry` (`:243-244`)** — same conversion.

3. **`_create_shape_from_geometry` (`:352`)** — REMOVE the `_convert_nif_vector` loop on vertices. The parent `transform` is now in Godot space, so the vertices must stay in NIF-local space and be positioned by the converted transform. Double conversion would scramble them back.

4. **`_create_shape_from_bounding_volume` (`:275, 288, 290, 303, 305`)** — remove the per-component `_convert_nif_vector` / `_convert_nif_basis` calls. The enclosing `transform` parameter now handles placement correctly.

5. **`create_actor_collision` (`:756, 778`)** — same: stop converting `bounding_box_extents` and `bounding_box_center` if those are being combined with an already-converted parent. Audit the call site at `nif_converter.gd:641-642` to see what space the metadata is stored in.

Expected change: ~15 lines modified + several conversion calls removed.

### Part 2 — Safety net for NIFs with no collision at all (independent)

In `nif_converter.gd:630`:

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

`_build_trimesh_fallback_from_visuals` walks the visible MeshInstance3D descendants, aggregates their triangles via `create_trimesh_shape()`, and wraps them in a single StaticBody3D. Skip meshes marked with the `_is_foliage` / `_is_glow` / particle metadata that shouldn't block movement.

This Part is OPTIONAL if Part 1 fixes all the affected NIFs (i.e. most stairs actually do have collision blocks, they were just placed wrong). Run Part 1 first and see what's still missing before committing to Part 2.

---

## Verification Procedure

After applying Part 1:

1. **Clear the cache.** Delete `C:/Users/metzo/Documents/Godotwind/cache/models/` (or the current `SettingsManager.get_cache_dir() + "/models"`) so the prebaker rebuilds every model. No incremental rebake — this is a global coordinate change.
2. **Rebake.** Run the model prebaker via `src/tools/prebaking/model_prebaker.gd` (or whatever editor tool invokes it). Expect several minutes for the full Morrowind model set.
3. **Relaunch with debug collisions on:**
   ```
   "D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" --debug-collisions scenes/Godotwind.tscn
   ```
4. **Visual check.** Fly to the same stairs that were clipping. Cyan wireframes should now overlay the visible step geometry with no drift. Fly to any architecture cell with compound hierarchies (guild halls, temples, cantons) — no floating outlines hundreds of meters out.
5. **Character check.** Press P to enter player mode, walk up the stairs. The `_move_with_step_up` pre-move probe in `src/core/character/controller/move_container.gd` should detect the step risers and smoothly climb them. If it still fails, the character controller has a secondary bug; if it works, Part 1 is complete.

---

## Related — Adjacent Bugs in the Same Failure Class

The user reported (2026-04-09) that MANY visual-side objects also float — trees, rocks. These are NOT caused by `nif_collision_builder.gd` but almost certainly come from an analogous asymmetric handling somewhere in the visual chain (cell instantiation, ESM reference placement, or NIF scene-root transform). Worth investigating in the same session while the coordinate pipeline is in the reader's head:

- `src/core/world/reference_instantiator.gd` — check whether `CS.esm_rotation_to_godot_basis` is applied consistently on every placement path.
- `src/core/nif/nif_converter.gd:943` assigns converted local transforms to NiNode descendants, but what about the scene ROOT? Verify the top-level Node3D of the prebaked scene also starts with an identity (not an un-converted NIF root transform).
- Objects that float in air probably went through a path where a rotation was applied in NIF space and a translation in Godot space, or vice versa.

These should be handled by the same prebaker agent that takes this doc — they are sister symptoms.

---

## Character-Controller-Side Work That Depends on This Fix

The following changes live in `src/core/character/controller/move_container.gd` + `src/core/interaction/interaction_raycaster.gd` + `src/tools/world_explorer.gd` from the 2026-04-09 character-debug session:

1. **Canonical pre-move step-up probe** — up/forward/down test_move pattern matching OpenMW `Stepper::step` / HL2 `CGameMovement::StepMove` / UE `CharacterMovementComponent::StepUp`. Replaces the earlier bespoke post-slide-rewind implementation.
2. **Unstuck recovery** — `test_move(transform, Vector3.ZERO)` penetration detection + iterative UP push, mirror of OpenMW `MovementSolver::unstuck`.
3. **Third-person-friendly raycast** — `InteractionRaycaster.ray_origin_node` override so the interaction ray starts at the character's head (`camera_pivot` at eye height) rather than the camera position. Works in both first and third person without losing reach to the `SpringArm3D` offset.
4. **Coder's forced-first-person bridge reverted** — world_explorer now starts the player in THIRD_PERSON with TAB switching re-enabled.

All four changes are functionally correct. They CANNOT be validated against real Morrowind geometry until the collision coordinate bug in this document is fixed, because most of the static world currently has collision in the wrong place or no collision at all. Once the collision pipeline is repaired, re-run the verification procedure above and test step-up + interaction against Balmora / guild / temple cells.

---

## Credits & References

- Discovered during character-debug session, agent `character-debug`, 2026-04-09 19:00 local.
- Brief posted in `#general` message id 187.
- Canonical step-up references: `inspos/openmw/apps/openmw/mwphysics/stepper.cpp`, `movementsolver.cpp`, `constants.hpp`.
- Coordinate system helpers: `src/core/coordinate_system.gd:168-207`.
