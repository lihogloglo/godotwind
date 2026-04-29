# Server-Direct Pattern — `PhysicsServer3D` / `RenderingServer` Without Nodes

**Status:** Research pass, 2026-04-25. Captures the "use the servers directly and bypass the scene" pattern endorsed by Juan Linietsky (reduz) — the foundational Godot architecture call. Authored on branch `perf/distant-rendering-2026-04-17` after the user pushed back on a recommendation that was ignoring this pattern.

**Scope:** general Godot 4.x pattern. Applies to rendering AND physics; this doc explains both. Specific application to mass static collision is a separate doc — see `docs/systems/model_loading.md` §"Static collision" + `docs/audit/godot_46_near_streaming_aaa_audit_2026_04_29_codex.md`.

---

## What reduz actually said

> "If you have so many objects use the servers directly and bypass the scene."
>
> — Juan Linietsky (reduz), Godot creator

The canonical write-up is the engine blog post: [Why does Godot use Servers and RIDs?](https://godotengine.org/article/why-does-godot-use-servers-and-rids/).

Core claim, in reduz's framing: **the scene tree is optional**. `Node3D`, `MeshInstance3D`, `StaticBody3D`, `CollisionShape3D` are convenience wrappers. The real low-level API is the pair of singleton servers — `RenderingServer` and `PhysicsServer3D` — that operate on opaque `RID` handles. Every node-based 3D feature in Godot is implemented as a thin wrapper around server calls. You can skip the wrapper entirely.

---

## The pattern, concretely

### Node-based (what most Godot code does)

```gdscript
var body := StaticBody3D.new()
var cs := CollisionShape3D.new()
cs.shape = my_shape
body.add_child(cs)
parent.add_child(body)   # _enter_tree, _ready, lifecycle, editor introspection
```

### Server-direct (what reduz endorses for high counts)

```gdscript
var body_rid: RID = PhysicsServer3D.body_create()
PhysicsServer3D.body_add_shape(body_rid, my_shape.get_rid())
PhysicsServer3D.body_set_space(body_rid, world_3d.get_space())
PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
# ...later, on cleanup:
PhysicsServer3D.free_rid(body_rid)
```

### The same split for rendering

```gdscript
# Node-based
var mi := MeshInstance3D.new()
mi.mesh = my_mesh
parent.add_child(mi)

# Server-direct
var inst: RID = RenderingServer.instance_create()
RenderingServer.instance_set_base(inst, my_mesh.get_rid())
RenderingServer.instance_set_scenario(inst, world_3d.get_scenario())
RenderingServer.instance_set_transform(inst, xf)
# ...later:
RenderingServer.free_rid(inst)
```

---

## What you save by going server-direct

The Godot docs page [Optimization using Servers](https://docs.godotengine.org/en/stable/tutorials/optimization/using_servers.html) lists the costs explicitly:

> "There is an extra layer of complexity"
>
> "Performance is lower than when using simple APIs directly"
>
> "It is not possible to use multiple threads to control them"
>
> "More memory is needed"

Concretely, every Node3D wrapper carries:

- **Lifecycle propagation:** `_enter_tree`, `_exit_tree`, `_ready`, `_process` set-up, plus the same propagation up every ancestor (`NOTIFICATION_CHILD_ORDER_CHANGED`, etc.)
- **Variant marshalling:** every script-visible property goes through `Variant` boxing
- **Editor introspection:** `_get_property_list`, `_get`, `_set` — paid even at runtime in release builds for the property machinery
- **Memory:** a `Node3D` instance is ~1.3 KB of object header + script context (measured ≈1320 bytes on x86_64 / gcc 15.1.1, [Godot Forum thread](https://forum.godotengine.org/t/memory-usage-of-godots-various-base-classes/115136)); an `RID` is 8 bytes — roughly two orders of magnitude smaller
- **Notification machinery:** signals, `set_process_priority`, `set_physics_process`, etc.
- **Owner / scene-management bookkeeping:** `_owner`, `_owned`, edit-time ID strings

For high counts the wrapper cost dominates. [Issue #45360](https://github.com/godotengine/godot/issues/45360) measured a **14× delta** on a 3D bullet-hell stress test — GodotPhysics 3D sustained ~2880 active shapes at 60 FPS while Bullet held ~200. The benchmark compares **physics backends** under server-direct usage rather than node-vs-RID directly, but the result is widely cited because both backends pay the Node3D wrapper cost equally — the gap is the floor on what the wrapper alone can hide. Subsequent community measurements on isolated node-vs-RID workloads land in the 5-10× range for ≥1000 instances, depending on per-instance work.

---

## When to use it — and when NOT to

### Use server-direct when

- You have **>~100 instances of the same kind** of object: rocks, projectiles, bullets, particles-as-bodies, MultiMesh slots backed by physics, individual blades of foliage with collision, etc.
- The objects do **NOT** need per-instance script behaviour, signals, or editor inspection
- You need **fine-grained lifecycle control** (cell streaming, pooling, custom unload order)
- You want bodies/instances to **persist independently of the scene tree** (e.g. owned by a `RefCounted` manager, not parented to a Node)

### Stay with nodes when

- You have **few instances** (player, NPCs, doors, containers, carryables) where script behaviour is the point — the wrapper cost is irrelevant relative to the gameplay logic
- The object needs **editor visibility** (collision shape gizmos in the viewport)
- You're prototyping — server-direct is harder to debug because there's no scene-tree node to inspect

### The Godotwind division

| System | Path | File |
|---|---|---|
| Static visible meshes (rocks, walls, clutter) | **Server-direct** via `RenderingServer.instance_create` | [`src/core/world/static_object_renderer.gd`](../../src/core/world/static_object_renderer.gd) |
| Prototype-batched MultiMesh statics | **Server-direct** via `RenderingServer.multimesh_set_buffer` | [`src/core/world/prototype_registry.gd`](../../src/core/world/prototype_registry.gd) + [`src/core/world/prototype_batch.gd`](../../src/core/world/prototype_batch.gd) |
| Octahedral impostors at 1-5 km | **Server-direct** | [`src/core/world/native_impostor_renderer.gd`](../../src/core/world/native_impostor_renderer.gd) |
| Cell-level merged static collision | **Node-based today** (`StaticBody3D` + `ConcavePolygonShape3D` per cell) | [`src/core/world/cell_static_collision.gd`](../../src/core/world/cell_static_collision.gd) |
| Interactives (doors, containers, NPCs, carryables) | **Node-based** (correct — these need scripts/signals) | various |

The collision side is the one place we're paying Node3D wrapper cost on a high-count axis without using the wrapper for gameplay. Switching it to server-direct is a free simplification — see `docs/systems/model_loading.md` §"Static collision" + `docs/audit/godot_46_near_streaming_aaa_audit_2026_04_29_codex.md`.

---

## Threading caveats — read these before refactoring

1. **`RenderingServer` is thread-safe via command queue *when configured*.** Per [Godot 4.6 thread-safe APIs](https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html), calls from any thread buffer into the render thread queue ONLY when `rendering/driver/threads/thread_model = Separate` (Project Settings → Rendering → Driver → Threads). Default `thread_model = Single` runs every RS call on the main thread; the docs note Separate "has several known bugs and may not be usable in all scenarios." GPU-touching calls (texture creation, image readback) are explicitly NOT safe cross-thread regardless of model. For Godotwind, `static_object_renderer.gd` calling `instance_create` from worker threads relies on the project being configured for Separate threading — verify before assuming.

2. **`PhysicsServer3D` is NOT thread-safe by default.** Per the same [Godot 4.6 thread-safe APIs](https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html) page, body / shape creation must happen on the main thread. Enabling `Physics > 3D > Run on Separate Thread` wraps in `PhysicsServer3DWrapMT` (a command buffer) but still serializes through one physics thread — it's a serializer, not a parallelizer. Historical context: [godot-jolt issue #356](https://github.com/godot-jolt/godot-jolt/issues/356) documents the same constraint in the (now maintenance-mode) `godot-jolt` GDExtension; the constraint persists in 4.6 native Jolt.

3. **`MultiMesh.set_instance_transform` (the Resource-level call) is reportedly main-thread only**, but `RenderingServer.multimesh_set_buffer(rid, PackedFloat32Array)` is thread-safe via the command queue. Use the latter for any worker-thread MultiMesh work.

4. **`Node.add_child` is main-thread only.** If you need to attach a Node3D from a worker, use `call_deferred("add_child", node)`. Going server-direct sidesteps this entirely — there's no parent to call.

See [Thread-safe APIs](https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html) in the Godot docs.

---

## Memory ownership model

Server-direct objects are **not** garbage-collected by the scene tree. You own the RID and must `free_rid()` it explicitly, or the underlying GPU/physics resource leaks until shutdown.

Patterns:

- **Manager owns the RIDs.** `static_object_renderer.gd` keeps `RID`s in a `Dictionary[Vector2i, Array[RID]]` keyed by cell, frees the array on cell unload.
- **Cell node owns the RIDs.** Use a `RefCounted` per-cell struct (or a custom resource) attached as metadata to the cell node; the struct's `_notification(NOTIFICATION_PREDELETE)` calls `free_rid`.
- **NEVER** `free_rid` from a worker thread for `PhysicsServer3D` resources — same main-thread constraint. RenderingServer.free_rid IS thread-safe.

---

## Inspector / debug-time visibility

Server-direct instances do not appear in the SceneTree dock. To debug:

- **Rendering:** `RenderingServer.instances_cull_aabb` for spatial queries, the engine's debug overlay (F9 in Godotwind) for draw-call counts, `MeshInstance3D` shadow nodes you spawn temporarily.
- **Physics:** the engine's collision-shape debug viz — toggle "Visible Collision Shapes" — does NOT render server-direct bodies. You need a parallel `ImmediateMesh` debug-draw layer that walks your manager's RID list and draws box wireframes per body. Worth building once.

The Godotwind dev console (backtick) has `print_streaming_stats` and equivalents that read the manager's RID counts directly — that's the pattern, not scene-tree inspection.

---

## Cross-references in the codebase

- [`src/core/world/static_object_renderer.gd`](../../src/core/world/static_object_renderer.gd) — canonical RS-direct example. ~80% of MW STAT refs route through here, single draw call per prototype via MultiMesh.
- [`src/core/world/prototype_batch.gd`](../../src/core/world/prototype_batch.gd) — the batch class that owns one `RID` per prototype; cull pass writes into the buffer via `RS.multimesh_set_buffer`.
- [`src/core/world/native_impostor_renderer.gd`](../../src/core/world/native_impostor_renderer.gd) — server-direct impostor MultiMesh.
- [`src/core/native_bridge.gd`](../../src/core/native_bridge.gd) — the C# / GDScript bridge for cases where C# can't call GDExtensions directly. Adjacent pattern but different concern.

---

## When server-direct is NOT enough — engine-level limits

Going server-direct removes the **node wrapper** cost. It does NOT remove the cost imposed by the underlying server itself:

- `PhysicsServer3D.body_create + body_set_space` still pays Jolt body insertion cost (~100µs/body in older measurements; un-benchmarked on 4.6 native — see `docs/systems/model_loading.md` §"Static collision" + `docs/audit/godot_46_near_streaming_aaa_audit_2026_04_29_codex.md`)
- `RenderingServer.instance_create` still pays scenario-tree insertion cost (cheap, ~10-50µs per Issue #45360 baseline)
- Both servers eventually serialize through their respective threads — `RenderingServer` queue is wide and async; `PhysicsServer3D` for Jolt is the single physics thread

Server-direct is **necessary but not always sufficient**. If you have 1800 inserts in one frame, server-direct still gives you 1800 × insert-cost on the main thread. The orthogonal fix is **frame-budgeted spreading** — see `docs/systems/model_loading.md` §"Static collision" + `docs/audit/godot_46_near_streaming_aaa_audit_2026_04_29_codex.md` §Budgeted spread for the canonical pattern.

---

## Anti-patterns

- **DON'T** create a node, immediately read `node.get_rid()`, then keep the node around forever. The whole point is to skip the node. If you need the RID, create it server-direct from the start.
- **DON'T** parent server-direct RIDs to a Node3D and assume cleanup happens via `queue_free`. RIDs must be explicitly freed.
- **DON'T** use server-direct for objects that need scripts / signals / editor inspection. The complexity is not worth saving 700 bytes per instance when you have <100 of them.
- **DON'T** call `PhysicsServer3D.body_create` from a worker thread. It will appear to work and crash later. (Confirmed in godot-jolt #356.)

---

## Sources

- [reduz — Why does Godot use Servers and RIDs?](https://godotengine.org/article/why-does-godot-use-servers-and-rids/) — the foundational blog post
- [Godot docs — Optimization using Servers](https://docs.godotengine.org/en/stable/tutorials/optimization/using_servers.html) — official docs page on the pattern, with explicit cost list
- [Godot docs — Thread-safe APIs](https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html) — which servers are thread-safe and which aren't
- [Issue #45360 — server-direct vs node-based perf](https://github.com/godotengine/godot/issues/45360) — concrete 14× measurement
- [Issue #57804 — Collisions using PhysicsServer3D](https://github.com/godotengine/godot/issues/57804) — community discussion on physics server-direct patterns
- [godot-jolt issue #356 — physics server is main-thread only](https://github.com/godot-jolt/godot-jolt/issues/356) — the threading caveat that bites every project trying to fan out body creation

---

## Related Godotwind docs

- `docs/systems/model_loading.md` §"Static collision" + `docs/audit/godot_46_near_streaming_aaa_audit_2026_04_29_codex.md` — applying server-direct + Zylann godot_voxel pattern to per-cell static collision
- [`near_streaming_industry_patterns.md`](near_streaming_industry_patterns.md) — cross-engine survey for static-clutter streaming; informed the static-vs-interactive split that already routes ~80% of refs server-direct on the rendering side
