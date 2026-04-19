# Statics Without Node3D — Terminal Architecture 2026-04-19

**Status:** DRAFT v2 — 2026-04-19. Primary plan for resolving `inst:13-60ms` overruns after the state-reversal fix. @user direction locked 2026-04-19 ("alright let's go, I'm convinced"). Supersedes: `lazy_jolt_activation.md`, `csharp_instantiate_bridge.md`.
**v2 patch (2026-04-19 post-review):** per @roaster plan-draft review (msg 1760) — B1 per-prototype shape cache added as §3.2.5 (20× instantiate reduction); B2 door classifier corrected (all doors interactive, not just teleport); T1 interior pockets carve-out LOCKED (stays Node3D, no deferral); T2 test scene moved from T.5 to T.2 acceptance; T3 §3.3 API corrected (`get_faces()` not `get_debug_mesh`); T4 character-controller slope/step-up verify added to T.2 acceptance. No further plan review pass — next engagement is T.5 user pilot or ad-hoc on unexpected complexity.
**Parent:** `near_tier_refactor.md` §S.6
**Scope:** Eliminate per-object Node3D spawn for non-interactive static geometry. Match OpenMW + UE5 World Partition canonical pattern. ~250 LOC net add, ~80 LOC of per-object instantiate path becomes dead code.

---

## 0. Resume Pointer

Read: §1 (goal + invariants) → §2 (current-state inventory) → §3 (delta) → §4 (phases). §5 (risks) + §6 (measurement) are referenced from phases.

**User directive, 2026-04-19:** *"no over-engineering, minimum code, 240 FPS target, architecture good and well thought of."* This plan is sized to that directive. If any phase grows beyond its stated budget, stop and escalate.

---

## 1. Goal + Invariants

**Goal:** statics (rocks, arches, clutter, flora, walls) render via `RS.instance_create2` + MultiMesh. No `Node3D`, no per-object `StaticBody3D`, no per-object `CollisionShape3D`. Collision via ONE `StaticBody3D` per cell holding ONE merged `ConcavePolygonShape3D` covering all statics in that cell.

**Invariants that must survive:**
1. Collision is fully preserved — player can't walk through rocks, carryables bounce off trees, raycasts hit per-triangle. Same user-visible behavior as today.
2. Interactive refs (doors, carryables, actors, lights, animated statics) **keep Node3D** — they're a tiny minority and legitimately need scene-tree lifecycle.
3. NEAR tier visual fidelity unchanged — same mesh quality, same LOD chain, same distance culling via `visibility_range`.
4. Prebake output format stays compatible — existing `.res` files still parse; new sidecars added, old ones don't break.
5. Per-cell tier transition lifecycle (`near_tier_refactor.md` §3.4) integrates cleanly — statics layer and interactive layer are independent within a cell.

---

## 2. Current-State Inventory

### 2.1 What's already built (survives unchanged)

| File | LOC | Role post-migration |
|---|---|---|
| `prototype_registry.gd` | 450 | Registry of mesh prototypes, MultiMesh-backed. Accepts `register_from_prototype(type, Node3D)` — works as-is. |
| `prototype_batch.gd` | 440 | Per-prototype MultiMesh sharding (fills/drains per cell). Works as-is. |
| `static_object_renderer.gd` | 905 | Cell-scoped lifecycle: `add_instance(type, xf, cell_grid)`, `remove_cell_instances(grid)`, `hide_cell_instances_budgeted`. Works as-is. |
| `object_paging.gd` | 998 | HLOD runtime merger. Untouched by this plan. |
| Flora + small-rock routing via `_is_static_render_model` | ~20 LOC in `reference_instantiator.gd` | Becomes a 1-line change (expand gate to all non-interactive statics). |

**Payoff:** the runtime renderer infrastructure is complete. This plan is primarily an ingress-side change (which refs go through the renderer) + a new collision-merge layer.

### 2.2 What exists but needs minor wiring

| Component | Current state | Delta |
|---|---|---|
| `reference_instantiator._instantiate_model_object` | Routes to static renderer ONLY if `_is_static_render_model(model_path)` (flora + small rocks). | Delete `_is_static_render_model` narrowing; route based on interactivity instead (per §3.1). |
| Metadata (form_id, record_type, ref_id) | Stored as `Node3D.meta` on each spawned Node. | Move to a side-table on `static_object_renderer`, keyed by `(cell_grid, instance_id)`. ~40 LOC. |
| Fade-in effect | `material_override` on Node3D + pooled ShaderMaterial. | Extend to MultiMesh via per-instance custom data + fade shader. ~50 LOC. (Or accept pop-in for statics — verified visually.) |

### 2.3 What's missing (the new work)

| Component | Purpose | Estimate |
|---|---|---|
| **Shape extraction** | Walk PackedScene at first-cell-load; pull every `CollisionShape3D.shape` + local `Transform3D` into a cell-scoped buffer. Free the PackedScene instance immediately after — we only needed it for shape data, not scene-tree nodes. | ~100 LOC |
| **Per-cell trimesh merge** | For each cell, accept an array of `(shape: Shape3D, local_xf: Transform3D)` tuples. Merge into a single `ConcavePolygonShape3D` — walk each shape's triangles, bake world transforms, push into one `PackedVector3Array`. | ~150 LOC |
| **Cell collision body** | Per-cell `StaticBody3D` holding the merged trimesh. Added to cell root on activation; removed on unload via existing cell lifecycle. | ~40 LOC |
| **Interactive ref classifier** | Single function: `is_interactive_ref(type_name, base_record)` → bool. Used at spawn routing. | ~20 LOC |

**Total new: ~350 LOC.** Removals offset: ~80 LOC of per-object instantiate path in `reference_instantiator` becomes dead for statics. Net: **~270 LOC add**.

---

## 3. Delta Specification

### 3.1 Spawn routing (where the single-line change happens)

`reference_instantiator.instantiate_reference` currently branches on `record_type` then calls `_instantiate_model_object` for standard statics. Change:

```gdscript
# Before (current):
_:
    return _instantiate_model_object(ref, base_record, cell_grid, type_name)

# After:
_:
    if is_interactive_ref(type_name, base_record):
        return _instantiate_model_object(ref, base_record, cell_grid, type_name)
    return _instantiate_static_object(ref, model_path, cell_grid)  # RS path
```

Where `is_interactive_ref` returns true for: `door` (teleport only), carryables (via `CarryableRegistry.is_carryable`), NIF-animated refs (detected via prebake flag). Everything else → static renderer.

Static renderer path already exists (`_instantiate_static_object` at line 363 of `reference_instantiator.gd`); it works for flora today. The migration is: remove the `_is_static_render_model` gate upstream at line 262 and route based on interactivity instead.

### 3.2 Shape extraction (the new collision ingest)

At cell load, after `_load_cell_async` completes, before cell activation:

```gdscript
# Pseudocode:
var cell_shapes: Array[Dictionary] = []
for ref in cell.static_refs:
    var prototype: Node3D = model_loader.get_model(ref.model_path)
    var shapes := _extract_shapes_recursive(prototype)  # walks CollisionShape3D nodes
    for shape_data in shapes:
        cell_shapes.append({
            "shape": shape_data.shape,
            "xf": ref.world_transform * shape_data.local_xf,
        })
    prototype.queue_free()  # we extracted what we needed
# cell_shapes feeds per-cell trimesh merge
```

`model_loader.get_model` already returns a fresh Node3D (same path `reference_instantiator` uses today). We just instantiate-extract-free. Cost: one `PackedScene.instantiate()` + shape walk + `queue_free`. Still main-thread but amortized over cell load (budgeted).

**Optimization (later, not required v1):** bake shape data into a sidecar `.shapes.res` at prebake time so runtime doesn't need to instantiate. ~300 LOC delta in `model_prebaker.gd` + cache rebuild. Flagged in §7.

### 3.2.5 Per-prototype shape cache (REQUIRED, not optional)

**Without caching, §3.2 degenerates into the original bottleneck.** Every ref would trigger its own `PackedScene.instantiate()` — 10k refs across 9 active cells = 10k main-thread instantiates, exactly the cost we're trying to kill.

**Cache strategy:** shape arrays are keyed by `model_path`, not by ref.

```gdscript
# model_loader.gd (or a new static_shape_cache.gd):
var _shape_cache: Dictionary[String, Array] = {}  # model_path -> Array[{shape, local_xf}]

func get_shape_entries_for_model(model_path: String) -> Array:
    if model_path in _shape_cache:
        return _shape_cache[model_path]
    var prototype := get_model(model_path)    # one-time instantiate
    var entries := _extract_shapes_recursive(prototype)
    _shape_cache[model_path] = entries
    prototype.queue_free()                    # prototype disposable — cache holds the shapes
    return entries
```

**Payoff:** MW has ~500 unique static prototypes vs ~10k refs in a 3×3 active grid. Cache reduces instantiates from O(refs) to O(unique prototypes) = **20× reduction**. Cache populates incrementally during first cell loads; subsequent cells hit warm cache at effectively zero cost.

**Memory:** each cached entry is `(Shape3D ref-counted reference, Transform3D)` — ~50-100 bytes per shape. 500 prototypes × avg 2 shapes/proto × 80 bytes = ~80 KB cache. Negligible.

**Thread safety:** main-thread-only access in v1. If T.6 moves to prebake sidecars, cache becomes a boot-loaded read-only dict (no sync concerns).

**Acceptance in T.2:** `inst:` time drops to single-digit ms after first ~30 seconds (warm-up period). Before warmup, expect transient hitches proportional to cache-miss rate.

### 3.3 Per-cell trimesh merge

Take `Array[{shape, xf}]` → emit `ConcavePolygonShape3D`:

```gdscript
func _merge_to_trimesh(entries: Array) -> ConcavePolygonShape3D:
    var vertices := PackedVector3Array()
    for entry in entries:
        var local_triangles := _shape_to_triangles(entry.shape)  # built-in Godot API
        for i in range(0, local_triangles.size(), 3):
            # Transform each triangle by its world xf
            vertices.push_back(entry.xf * local_triangles[i])
            vertices.push_back(entry.xf * local_triangles[i+1])
            vertices.push_back(entry.xf * local_triangles[i+2])
    var trimesh := ConcavePolygonShape3D.new()
    trimesh.set_faces(vertices)
    return trimesh
```

**Shape → triangles API (corrected per @roaster review):**
- `ConcavePolygonShape3D.get_faces() -> PackedVector3Array` — already triangles, direct read. MW NIFs almost always produce `bhkPackedNiTriStripsShape → ConcavePolygonShape3D`, so this is the fast path hitting 90%+ of shapes.
- `ConvexPolygonShape3D.points: PackedVector3Array` — convex hull vertices; triangulate via quickhull helper (small utility, ~30 LOC).
- `BoxShape3D / SphereShape3D / CapsuleShape3D` — analytical triangulation helpers (one function per primitive, ~50 LOC total).
- `Shape3D.get_debug_mesh()` is intentionally avoided — it's an editor-visualization helper that rebuilds each call; slow for runtime.

**Cost:** per-cell merge at load time, ~2-5 ms for a dense cell with ~200 statics. Runs on main thread during the cell activation transition — falls inside the existing `process_async_instantiation` budget. Low per-frame footprint (1-2 cells activated per cell-crossing event).

### 3.4 Interactive ref classifier

```gdscript
func is_interactive_ref(type_name: String, base_record: Variant) -> bool:
    match type_name:
        "door":
            return true  # ALL doors — teleport doors teleport, non-teleport doors still open/close/lock/animate.
                         # MW has no purely-decorative doors. (Corrected from v1 draft per @roaster B2.)
        "npc", "creature", "leveled_creature":
            return true
        "light":
            return true  # light node is the light source itself
    if CarryableRegistry.is_carryable(type_name, base_record):
        return true
    if _is_animated_static(base_record):  # runtime check: PackedScene has AnimationPlayer?
        return true
    return false
```

`_is_animated_static` checks a prebake-time flag (see §5.1). ~20 LOC for the classifier.

---

## 4. Phases (all phases keep game runnable)

### T.0 — Instrumentation baseline

Before any code change. Add per-phase timers in `process_async_instantiation` breaking down `inst:` time into:
- PackedScene.instantiate() wall-clock
- add_child cost
- metadata + misc
- (new) shape extract time when T.2 lands

Capture before-numbers for §6.

**Acceptance:** before-numbers in §6 table for FPS (steady + moving), `inst:` P95, Jolt body count at dense cell.

**Effort:** 1h.

### T.1 — Interactive ref classifier + routing

Add `is_interactive_ref` in `reference_instantiator` (or a new `ref_classifier.gd`). Delete `_is_static_render_model` gate at line 262. Replace with interactivity check.

Wire animated-static detection via runtime check: if the PackedScene has an `AnimationPlayer`, route interactive. Later (T.6) move this to prebake-time flag.

**Acceptance:**
- All statics that WERE going to Node3D (non-flora) now go to `_instantiate_static_object`
- Carryables, doors (teleport), NPCs, creatures, lights still Node3D
- NIF-animated statics (flags, banners) still Node3D (runtime check)
- Scene still boots + streams; render of statics uses MultiMesh (verify in log: `static_renderer_instances` stat rises, `objects_instantiated` drops)
- Collision is BROKEN — that's expected; fixed in T.2/T.3
- Measure: `inst:` time per frame, expect 40-60% drop

**Effort:** 2h.

### T.2 — Shape extraction + per-cell collision body

Add shape-extract module (`cell_static_collision.gd`) with:
- `extract_from_refs(refs: Array[CellReference]) -> Array[{shape, xf}]` (uses §3.2.5 per-prototype cache)
- `merge_to_trimesh(entries) -> ConcavePolygonShape3D`
- `spawn_cell_body(cell_node, trimesh) -> StaticBody3D` (attached as child of cell_node)

Wire into cell activation in `cell_manager.process_async_instantiation`: after all statics are queued to RS renderer, build the cell-level trimesh and attach.

Also in T.2: **add dedicated test scene `tests/visual/test_statics_no_node3d.tscn`** (promoted from T.5 per @roaster T2 review — fail-early matters most for the biggest deliverable). Scene contents:
- Programmatic dense static grid placement (~1500 refs)
- RS-rendered statics + merged per-cell trimesh body
- F-key prints body count + cache hit rate
- Debug draw shows merged trimesh triangles overlaid

**Acceptance:**
- Walking into a rock: blocked. Collision works.
- Carryables drop on surfaces.
- Raycasts hit triangles (verify via interaction raycaster).
- **Character controller slope/step-up (added per @roaster T4 review):** player walks up stairs, cliffs, gentle + steep slopes — identical behavior to pre-migration. 3-min interactive pilot check against a staircase/cliff area.
- Jolt body count at Seyda Neen: drops from ~1800 to ~9-15 (one per active cell).
- `inst:` time settles to single-digit ms after ~30s warmup (§3.2.5 cache effect).
- `test_statics_no_node3d.tscn` boots, all F-key reports match expectations, debug draw visible.
- Measure: `phys:` frame time, expect >50% drop.

**Effort:** 4h (includes test scene + slope verify).

### T.3 — Metadata side-table

Add `static_object_renderer._metadata: Dictionary[Vector2i, Dictionary[int, Dictionary]]` — keyed by `cell_grid → instance_id → {form_id, record_type, ref_id}`. Expose `get_metadata(cell_grid, instance_id) -> Dictionary`.

Update console object picker (`console.gd`) to look up via renderer when Node3D has no meta.

**Acceptance:** console `pick` command on a static returns form_id + record_type identical to pre-migration behavior.

**Effort:** 1.5h.

### T.4 — Fade-in (optional, non-blocking)

Extend MultiMesh instance custom data to carry `spawn_time`. Fade shader uses `TIME - spawn_time` to compute alpha. Reuses existing `lod_crossfade.gdshader` pattern.

**Acceptance:** newly-activated cells fade in smoothly (no pop-in). Verified interactively by user.

**Effort:** 2h. **Skip if user accepts pop-in** — gameplay unaffected.

### T.5 — Measurement + user sign-off

Re-measure all §6 metrics. Interactive user pilot: fly into/out of cells, verify collision behavior, confirm FPS target.

**Acceptance:**
- Steady-state FPS at Seyda Neen dock: **≥ 200 FPS** (stretch: 240)
- Mid-movement FPS (walking across cells): **≥ 120 FPS**
- No collision regressions in 5-min interactive pilot
- User confirms in chat: direction achieved

**Effort:** 1h.

### T.6 — Prebake-time shape sidecars (future optimization, NOT this plan)

Move shape extraction to prebake time via `.shapes.res` sidecars. Runtime loads shapes directly, skips PackedScene instantiate-extract-free. Saves T.2's instantiate cost (~1-2ms per cell load).

**Flagged here, not scoped.** Ship T.0-T.5 first; measure whether T.6 is needed for 240 FPS target.

---

## 5. Risk List (from @coder chat msg 1749, endorsed by @roaster)

### 5.1 NIF-animated statics

~50 prototypes in MW have keyframe animations (flags, banners, torches' glow rings, rotating Dwemer mechanisms). MultiMesh can't drive per-instance anim state. **Fix:** classifier routes animated refs to Node3D path unconditionally. Runtime detection via `AnimationPlayer` presence in T.1; prebake flag in T.6.

### 5.2 LOD crossfade

Current implementation uses `material_override` on Node3D's MeshInstance3D. **Fix:** T.4 extends the fade pattern to MultiMesh via per-instance custom data. If skipped (T.4 non-blocking): statics pop in/out visibly. Verify visually — may be acceptable for shipping.

### 5.3 Interior pockets — CARVE-OUT LOCKED

**Locked 2026-04-19 per @roaster T1 review.** Interior cells stay on the Node3D path unchanged. Reasoning:
- Interior cells are small + bounded + always <150m from camera — zero performance win from RS routing.
- Interior manager (`interior_pocket_manager.gd`) has its own lifecycle separate from exterior cell lifecycle.
- MultiMesh batching overhead per unique type may exceed Node3D per-object cost for low-count interior cells.
- No behavior change needed — `is_interactive_ref` at routing time treats interior context as an implicit whole-path carve-out via the existing `interior_pocket_manager` spawn entry.

Implementation: add a single early-return guard at the routing site — `if in_interior_context: return _instantiate_model_object(...)`. ~5 LOC. Interior code path UNTOUCHED.

### 5.4 Console object picker

Players rarely click rocks in console. **Fix:** metadata side-table (T.3). If users report missing form_id info on static targets, the side-table closes the gap.

### 5.5 Test scene / verification

`tests/visual/test_statics_no_node3d.tscn` — PROMOTED to T.2 acceptance per @roaster T2 review (previously T.5). Fail-early matters for T.2 because collision-restored is the biggest deliverable. Scene shows: dense static grid rendered via RS, collision via merged trimesh, metadata picker functional, slope/step-up verified.

---

## 6. Measurement Table (populate per phase)

| Phase | Metric | Before | After | Target |
|---|---|---|---|---|
| T.0 | Steady FPS, Seyda Neen dock | ~235 | — | ≥240 |
| T.0 | Mid-movement FPS | 30-60 | — | ≥120 |
| T.0 | `inst:` P95 during cell load | 60ms | — | <10ms |
| T.0 | Jolt body count, Seyda dense area | ~1800 | — | ~15 |
| T.0 | `phys:` frame time average | ~0.2ms | — | <0.1ms |
| T.1 | `inst:` P95 (statics via RS, no collision yet) | — | — | <8ms |
| T.2 | Jolt body count post-merge | — | — | ~15 |
| T.2 | `phys:` time with merged trimesh | — | — | <0.2ms |
| T.5 | Final FPS steady / moving | — | — | 240 / 120 |

---

## 7. Open Questions / Deferrals

1. **§2.2 fade-in migration** — ship T.4 or accept pop-in? Defer to user call after T.1/T.2 interactive test.
2. **§4 T.6 prebake sidecars** — defer unless T.5 measurement misses target.

Previously-open items now closed by @roaster review:
- ~~§5.3 interior pockets — defer to T.1~~ → **LOCKED as carve-out** in §5.3.
- ~~Character controller slope behavior — open question~~ → **folded into T.2 acceptance** with explicit stairs/cliff/slope verify.

---

## 8. Non-Goals

- Not touching NPC / creature / actor spawn path.
- Not redesigning the NIF → shape extraction pipeline (reuse Godot's `Shape3D` built-ins).
- Not building a visual editor for static prototypes (prebake is the authoring tool).
- Not changing ESM cell data model.
- Not touching terrain or water — statics only.

---

## 9. Cancellation Notice

The following plans are **superseded** by this one:
- `lazy_jolt_activation.md` — was middle-step, user picked terminal directly.
- `csharp_instantiate_bridge.md` — scope analysis confirmed C# bridge overlaps ~80% with terminal arch; CANCELLED.

Keep files for historical context but do NOT implement.
