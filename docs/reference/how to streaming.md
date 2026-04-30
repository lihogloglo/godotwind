# NEAR Streaming Recovery Handoff

Date: 2026-04-29  
Author: Codex  
Branch observed: `perf/distant-rendering-2026-04-17`  
Current HEAD observed: `5b20857`

## Purpose

This is the handoff for the next agent that did not attend the 2026-04-29
architecture discussion. The goal is to stabilize Godotwind's NEAR streaming
and rendering before any distant rendering, HLOD, impostor, or feature work
continues.

Do not resume distant rendering or feature work until the NEAR stabilization
slice is checkpointed. The original 2026-04-29 failure was a traversal-time
streaming/resource-eviction crash, not a confirmed launch crash. On
2026-04-30, the P0.2 `StreamedResourceHandle` slice removed the diagnostic
eviction bridge, re-enabled cache eviction, survived automated traversal
smokes, and passed a visible `scenes/Godotwind.tscn` user traversal/quit check.
The next architectural phase is P0.3 per-payload publish scheduling.

## Executive Verdict

The high-level target is not out of scope for Godot 4.6. The intended shape is
still the right one:

- static visuals use `RenderingServer` / server-direct rendering
- gameplay objects are sparse `Node3D` promotions
- resources load asynchronously
- collision is separate from visual readiness
- distant systems stay disabled until NEAR is stable

The problem is the current orchestration implementation. It has accumulated
too many queues, phase generations, defensive gates, and time-delay bridges.
The result is a fragile lifetime graph where no single owner can prove when a
resource, RID, node, payload, or queued callback is safe to release.

In short: this is mostly an implementation architecture problem, not a Godot
capability problem.

## Reference Architecture (claude, 2026-04-29)

This section is the positive mental model. Read it first when joining this
project — it tells you what the system *should* look like, separate from what
the current code does. Use it as a north star while you read the recovery
sections below.

### Tiered Distance Strategy

Every AAA open-world engine separates "what's near the player" from "what's far
from the player" because the per-object cost is fundamentally different.
Godotwind uses three tiers + horizon (single source of truth in
`src/core/world/distance_utils.gd`):

| Tier | Range | Per-Object Cost | Technique |
|------|-------|-----------------|-----------|
| NEAR | 0-150 m | Highest (full sim) | Node3D + collision + animation + interactive |
| MID | 150-500 m | Mid | One RS instance per object, embedded LOD chain |
| HLOD | 300-1000 m | Low (chunked) | One merged RS instance per chunk |
| FAR | 1000-5000 m | Lowest (impostor) | MultiMesh of octahedral billboards |

Rule: an object exists in **exactly one tier at a time**. Tier transitions are
managed by hysteresis margins (`distance_utils.gd::HYSTERESIS_*`) to prevent
oscillation.

### Per-Cell Pipeline (the canonical shape)

A cell is the unit of streaming I/O. Every AAA engine has this concept (UE5
World Partition cells, Decima tiles, RAGE sectors, OpenMW exterior cells). In
Godot 4.6 the canonical lifecycle for one cell is:

```
Disk -> Memory (off-thread):
    [ ResourceLoader.load_threaded_request(cell.esm_path) ]
       -> [ classify cell refs into static / interactive ]
       -> [ resolve PackedScene paths via cache or load_threaded ]

Memory -> Off-tree Construction (off-thread, optional):
    [ build per-cell static MultiMesh transform buffer ]
    [ pre-compute static collision triangle list ]

Off-tree -> Scene Tree (main thread, deferred + budgeted):
    [ add_child(cell_node, deferred) ]
    [ for each interactive ref:
          PackedScene.instantiate() (main thread)
          parent.add_child(instance) (deferred or main, budgeted) ]
    [ publish per-cell MultiMesh: instance_set_base + set_buffer ]
    [ publish per-cell static StaticBody3D + ConcavePolygonShape3D ]

Steady state (main thread):
    [ engine handles visibility_range, frustum cull, LOD selection ]
    [ no per-frame GDScript work for static visuals ]

Player exits -> Unload (main thread, budgeted):
    [ free interactive Node3D children (queue_free) ]
    [ free per-cell MultiMesh + RS instance ]
    [ free StaticBody3D + ConcavePolygonShape3D ]
    [ release StreamedResourceHandle refs ]
    [ when no consumer holds handle -> Mesh/Material/PackedScene free ]
```

### Ownership Topology

Resources flow from disk to GPU through a chain of strong references. The
canonical rule (`tutorials/performance/using_servers.html`):

> "References to a resource's RID are not counted when determining whether
> the resource is still in use. Make sure to keep a reference to the resource
> outside the server."

So every level in the chain holds strong refs:

```
ResourceLoader cache (weak / non-owning lookup)
        |
        v
StreamedResourceHandle  (refcounted, the "pin")
   - PackedScene (strong)
   - extracted Mesh[]      (strong)
   - extracted Material[]  (strong)
        |
        v
CellPayload  (one per loaded cell, holds N handles)
        |
        v
Per-Cell consumers:
   - MultiMesh.mesh = mesh_resource          (strong via property)
   - MeshInstance3D.mesh = mesh_resource     (strong via property)
   - RS instance (RID only — relies on above strong refs)
        |
        v
Cell unload -> CellPayload release -> handle refcount drops
   when no consumer holds handle -> Mesh/Material/PackedScene free safely
```

### Threading Topology

Godot 4.6 has two thread models that matter for streaming:

1. **Main thread** (always): scene tree, RenderingServer (default Single mode),
   PhysicsServer (default Single mode), Node lifecycle, all
   `add_child` / `queue_free` operations.
2. **WorkerThreadPool** (cooperative): off-tree resource preparation, threaded
   `ResourceLoader` requests, off-tree node construction (with care), pure
   computation (transform building, collision triangle gathering).

Optional: `Driver > Thread Model = Separate` puts RenderingServer on its own
thread, but the docs flag "several known bugs". Default to Single until you
need it.

Topology by lane:

```
Main thread:
   - cell load orchestration (NativeStreamingManager._process)
   - PackedScene.instantiate (until proven thread-safe in 4.6)
   - add_child / queue_free
   - RS instance create/free, MultiMesh.set_buffer
   - Jolt body / shape create

WorkerThreadPool:
   - ResourceLoader.load_threaded_request issue/poll
   - cell ref classification (ESM walk, type filter)
   - per-cell static MultiMesh transform array build
   - cell static collision triangle gather
   - any pure-computation pass with no scene/server side effects
```

### Frame Budget Math

| Target FPS | Budget per frame |
|------------|------------------|
| 60         | 16.67 ms         |
| 120        | 8.33 ms          |
| 144        | 6.94 ms          |
| **150 (target)** | **6.67 ms** |
| 240        | 4.17 ms          |

Indicative split for 150 FPS NEAR-tier (all values approximate, hardware-dependent):

| Budget (ms) | What |
|-------------|------|
| 3.0-4.0 | Render (RS instance cull, draw submission, shadow pass) |
| 1.0 | Physics step (Jolt 60 Hz, amortized) |
| 0.5 | Animation update (skeleton, IK, root motion) |
| 0.5-1.0 | Streaming publish (one frame's worth) |
| 0.5 | Gameplay GDScript (input, AI, NPCs) |
| 0.5 | UI |
| ~6.0 | Total (leaves ~0.6 ms safety margin) |

Implications:

- Streaming budget is ~1 ms per frame at 150 FPS, NOT 8 ms.
- A single 8 ms instantiate spike = 1 dropped frame at 150 FPS, 0.5 dropped
  frame at 120 FPS, no impact at 60 FPS.
- The current `INSTANTIATION_BUDGET_MS = 8.0` was reasonable for a 60 FPS
  target. After NEAR stabilizes, this constant must drop or the system must
  amortize the 8 ms across multiple frames more aggressively.

### When To Promote vs Keep Sparse

Default rule: every static clutter object stays in `RenderingServer` and never
becomes a Node3D. The vast majority of refs in any AAA cell file are static
clutter.

Promote to Node3D ONLY for:

- objects the player can interact with (doors, containers, activators)
- objects that move (NPCs, creatures, dynamic lights)
- objects that the player can manipulate (carryables, levers)
- objects that need per-frame logic (lights with day/night fade, animated
  decorations)

In Morrowind data terms, and as a generic AAA rule of thumb: typically less
than 20% of cell refs need promotion. The other 80%+ are pure visual statics
that should never touch the scene tree.

## Current Crash Evidence

Command run:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --headless --path D:/Gamedev/Godotwind/godotwind --quit
```

Result: the project launched, streamed for roughly 175 seconds, then crashed
with SIGSEGV.

Log:

```text
C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/logs/godot2026-04-29T19.55.13.log
```

Crash backtrace:

```text
Terrain3D NOTIFICATION_CRASH
GDScript backtrace:
  _evict_if_over_budget (res://src/core/world/model_loader.gd:437)
  _try_drain_requested_eviction (res://src/core/world/model_loader.gd:405)
  process_async_loads (res://src/core/world/model_loader.gd:729)
  process_async_disk_loads (res://src/core/world/cell_manager.gd:1966)
  process_async_instantiation (res://src/core/world/cell_manager.gd:2154)
  _process (res://src/core/world/native_streaming_manager.gd:903)
```

At current HEAD, `model_loader.gd:437` is:

```gdscript
_model_cache.erase(key)
```

Important correction from the discussion: the pin API already exists in
`model_loader.gd`:

- `pin_cached_model`
- `unpin_cached_model`
- `unpin_cache_key`
- `unpin_cache_owner`
- `_is_cache_key_pinned`
- `_queue_eviction_if_over_budget`
- `_try_drain_requested_eviction`

Therefore the crash is not simply "there is no pin set." It is stronger
evidence that the pin set is at the wrong granularity for the current ownership
graph. A key can be unpinned according to `ModelLoader` while some live
renderer, payload, scene instance, material, mesh, RID, or queued callback still
depends on resources originating from the erased `PackedScene`.

## Why Cache Erase Is Suspicious

`Dictionary.erase()` itself is probably not the true semantic bug. Erasing the
last strong reference to a `PackedScene` can release inner resources, including
meshes, materials, shaders, and their RIDs. If any still-live rendering path
holds only a RID, or a resource reference not protected by the same lifetime
owner, the renderer can later walk freed state.

There are good lifetime patterns already present in parts of the tree:

- `static_object_renderer.gd` stores strong `Mesh` / `Material` references in
  mesh-type data and derives RIDs from those strong resources.
- `prototype_batch.gd` has comments and fields intended to keep mesh resources
  alive through batch lifetime.

The unresolved question is whether every consumer, especially interactive
`Node3D` paths for doors, containers, activators, and lights, holds resource
lifetimes through a single coherent owner. Current evidence says no.

## Dominant Architectural Problem

`cell_manager.gd::process_async_instantiation()` is the central problem area.
It currently multiplexes too many responsibilities through one frame-budgeted
driver:

- request classification
- disk load drain
- conversion drain
- object pool prewarm
- static prototype prepare
- worker dispatch/result handling
- sync instantiate fallback
- proximity-deferred interactive parking
- child attach
- request finalization
- collision dispatch
- collision finalization

That function is not just long. It is a cross-cutting lifetime scheduler. It
has to understand resources, queue state, cell unload limbo, child attach
state, static renderer readiness, collision readiness, and gameplay object
publication all at once.

The second problem area is `native_streaming_manager.gd`, which coordinates:

- loaded/loading/unloading cell state
- state-reversal unload limbo
- RS hide and cleanup queues
- collision finalize deferral
- cell preloader updates
- static renderer cull/upload ticks
- HLOD/impostor/distant-light toggles

The design has too many global queues crossing cell lifetime boundaries.

## Kludge Signals To Avoid Repeating

These are not all equally wrong, but together they show the pattern that must
stop:

- `STATIC_CULL_UPLOAD_DEFER_FRAMES_AFTER_UNLOAD`
- `CELL_STATIC_COLLISION_FINALIZE_DEFER_FRAMES_AFTER_UNLOAD`
- `UPLOAD_DEFER_TICKS_AFTER_SLOT_RELEASE`
- `UPLOAD_DEFER_TICKS_AFTER_BATCH_CREATE`
- quiet-period collision gating
- permanent feature flags around crashy systems
- phase naming generations: S.0-S.7, Phase A/E/F, Fix B/C/D/E, Win 1-5

Do not add another defer-frame constant as a final fix. If a temporary bridge is
needed, it must obey the project bridge rule: symptom, canonical replacement,
follow-up removal commit, and dated owner TODO.

## Current Risk Flags

At current HEAD or recent handoff state, these paths are considered risky:

- `STATIC_CULL_NATIVE_ENABLED = false`
- `STATIC_PREPARE_CREATE_BATCHES = false`
- `DEBUG_DISABLE_PHASE_F_PREREG = true`
- `PHASE_A_OFFTHREAD_INSTANTIATE = false`
- `BOOT_STATIC_PREWARM_ENABLED = false`
- `StaticObjectRenderer.USE_PROTOTYPE_REGISTRY = false`

`USE_PROTOTYPE_REGISTRY = false` means statics currently fall back to direct
per-submesh `RenderingServer` instances rather than the intended
PrototypeRegistry/MultiMesh path. That may be a valid triage gate, but it also
means the intended high-performance static batch path is not trusted at current
HEAD.

## P0 Objective

Recover a stable NEAR baseline before any distant rendering or feature work.
The current branch cannot be the production base until it survives the manual
traversal gate.

### P0.1 Recovery Anchor

Use `a84d9a9` as the recovery anchor, or create a cleanup branch that returns to
that behavior behind gates.

Do not stack more feature work on top of the current branch while it still
crashes during basic streaming.

### P0.2 Freeze Risky Paths

While stabilizing, keep these off:

- PrototypeRegistry/MultiMesh static path
- Phase A off-thread instantiate
- Phase F prereg
- runtime collision finalize
- model cache eviction

Model cache eviction may be disabled only as a diagnostic bridge. It is not an
acceptable final fix.

### P0.3 Prove Baseline

Launch interactively:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn
```

Acceptance:

- 10 minutes of manual traversal through dense exterior cells
- no crash
- no queue runaway
- no severe FPS collapse
- no reliance on automated stress alone

The automated stress harness previously completed runs that manual traversal
still disproved. Manual traversal is mandatory for the user-visible failure.

### P0.4 Replace Cache Lifetime Model

Before re-enabling eviction, replace the current `Dictionary[String,
PackedScene]` plus pin-set approach with an owner-based lifetime model.

Canonical intended shape:

```gdscript
class_name StreamedResourceHandle
extends RefCounted

var cache_key: String
var packed_scene: PackedScene
var extracted_meshes: Array[Mesh]
var extracted_materials: Array[Material]
var owners: Dictionary
```

Expected ownership rule:

- cache may keep weak references or non-owning lookup state
- cell payloads hold strong handles
- static renderer batches hold strong handles or strong extracted resources
- interactive scene instances are associated with the handle that produced them
- queued callbacks and pending publish entries hold strong handles
- unload releases the payload/handle
- eviction is allowed only when no strong handle exists

The refcounted handle is the pin. Avoid a separate queue-walking pin API as the
source of truth.

### P0.5 Reintroduce Systems One At A Time

Order:

1. direct RS static fallback only
2. player-local collision
3. PrototypeRegistry/MultiMesh path
4. MID/HLOD
5. impostors/FAR

Every step gets the same 10-minute manual traversal gate.

## Diagnostic Bridge Proposal

If the user greenlights a cheap decisive probe, temporarily disable
`_evict_if_over_budget()` with an early return.

Required bridge block:

```gdscript
# DIAGNOSTIC BRIDGE (2026-04-29, codex/claude)
# Symptom: SIGSEGV in ModelLoader._evict_if_over_budget at _model_cache.erase(key)
# during traversal.
# Canonical replacement: RefCounted StreamedResourceHandle owns PackedScene plus
# extracted Mesh/Material resources; cache lookup is non-owning/weak and
# refcount is the pin.
# Follow-up: remove this bridge in the ResourceHandle PR before re-enabling
# eviction.
# TODO(codex/claude, 2026-04-29): remove by 2026-05-13.
return
```

Run the 10-minute manual traversal.

Outcomes:

- If traversal becomes stable, the cache/handle lifetime model is the next real
  fix.
- If traversal still crashes, the problem is broader unload/RID lifecycle and
  the cleanup must focus beyond `ModelLoader`.

Do not commit this as "stable." It is a diagnostic bridge only.

## Proposed Cleanup Direction

Replace the mega-driver with per-cell payload ownership:

```text
NativeStreamingManager
  rotates active payloads under a frame budget

CellPayload
  owns resources, queues, publish state, collision state, and unload state
  publish_step(budget_usec) -> bool
  unload_step(budget_usec) -> bool

StreamedResourceHandle
  owns PackedScene and extracted resources until all payloads/instances release
```

The goal is to collapse cross-cutting global queues into per-payload queues:

- classification queue belongs to the payload
- model requests belong to the payload
- pending callbacks belong to the payload
- child attach belongs to the payload
- static publish entries belong to the payload
- collision publish belongs to the payload
- unload cleanup belongs to the payload

The streaming manager should not need to know the internals of resource
lifetime or publication stages. It should only rotate payloads and enforce the
global frame budget.

## Code Recipes (claude, 2026-04-29)

This section gives an inheriting agent concrete skeletons for the canonical
patterns. None of this code is committed — these are reference shapes to copy
from when implementing the cleanup. Adapt names/types as the codebase evolves.

**Source classification:** every recipe in this section follows a Godot-doc-
backed rule. Where a step touches an undocumented Godot behavior (off-thread
`PackedScene.instantiate()`, per-MultiMesh-instance fade) the recipe marks it
EXPERIMENTAL — verify with an isolated harness before relying on it.

### Recipe 1 — `StreamedResourceHandle`

The refcounted lifetime owner. Replaces `Dictionary[String, PackedScene] +
pin API`. Refcount IS the pin.

Doc backing: `tutorials/performance/using_servers.html` (RID consumer must
hold strong ref to source Resource); `classes/class_resource.html` (RefCounted
auto-free).

```gdscript
class_name StreamedResourceHandle
extends RefCounted

var cache_key: String
var packed_scene: PackedScene
# Strong refs to inner resources extracted from the PackedScene. Required because
# RID consumers (MultiMesh, RS instance) do not extend Resource lifetime.
var meshes: Array[Mesh] = []
var materials: Array[Material] = []
var shaders: Array[Shader] = []

func _init(p_key: String, p_scene: PackedScene) -> void:
    cache_key = p_key
    packed_scene = p_scene
    _extract_inner_resources()

func _extract_inner_resources() -> void:
    # Walk the PackedScene's bundled state, pull strong refs to every Mesh /
    # Material / Shader. PackedScene.GEN_EDIT_STATE_DISABLED produces shared
    # (not duplicated) inner resources per class_resource.html shallow-copy
    # rule. We hold our own strong refs so the resources outlive the
    # PackedScene if needed.
    var temp_root: Node = packed_scene.instantiate()
    _harvest(temp_root)
    temp_root.queue_free()

func _harvest(node: Node) -> void:
    if node is MeshInstance3D and (node as MeshInstance3D).mesh:
        meshes.append((node as MeshInstance3D).mesh)
    # ... walk for Materials, Shaders, etc.
    for child in node.get_children():
        _harvest(child)
```

Cache becomes a non-owning lookup:

```gdscript
# In ModelLoader (post-cleanup):
var _handle_cache: Dictionary[String, WeakRef] = {}

func get_or_load(path: String) -> StreamedResourceHandle:
    var cached: WeakRef = _handle_cache.get(path)
    if cached:
        var ref: StreamedResourceHandle = cached.get_ref()
        if ref:
            return ref  # cache hit; refcount inc via Variant return
    # cache miss or expired weak ref — load
    var packed: PackedScene = ResourceLoader.load(path)
    var handle: StreamedResourceHandle = StreamedResourceHandle.new(path, packed)
    _handle_cache[path] = weakref(handle)
    return handle
```

Eviction is automatic — when no `CellPayload` / consumer holds the handle, the
WeakRef expires and the handle's refcount hits zero. No `_evict_if_over_budget`,
no pin set, no defer-frames-after-X.

### Recipe 2 — `CellPayload.publish_step`

Per-cell ownership of the publish state machine. Replaces `cell_manager.gd::
process_async_instantiation` (currently a multi-thousand-line mega-driver).

Doc backing: matches UE5's `ULevelStreaming` per-sublevel state model and
OpenMW's per-cell load pipeline. Godot-side: `_process` per-frame budget +
deferred attach (`thread_safe_apis.html`).

```gdscript
class_name CellPayload
extends RefCounted

enum State { CLASSIFYING, RESOURCE_LOADING, INSTANTIATING, ATTACHING,
             STATIC_PUBLISHING, COLLISION_PUBLISHING, READY, UNLOADING }

var state: State = State.CLASSIFYING
var cell_node: Node3D
var handles: Array[StreamedResourceHandle] = []
var pending_refs: Array  # ESM CellReference still to process
var pending_attach: Array[Node3D]  # off-tree-built, awaiting add_child

# Returns true if this payload still has work; false if READY or UNLOADING done.
# `budget_usec` is the hard frame slice this payload may consume.
func publish_step(budget_usec: int) -> bool:
    var start: int = Time.get_ticks_usec()
    while Time.get_ticks_usec() - start < budget_usec:
        match state:
            State.CLASSIFYING:
                if not _step_classify():
                    state = State.RESOURCE_LOADING
            State.RESOURCE_LOADING:
                if not _step_load_resources():
                    state = State.INSTANTIATING
            State.INSTANTIATING:
                if not _step_instantiate_one():
                    state = State.ATTACHING
            State.ATTACHING:
                if not _step_attach_one():
                    state = State.STATIC_PUBLISHING
            State.STATIC_PUBLISHING:
                if not _step_publish_static():
                    state = State.COLLISION_PUBLISHING
            State.COLLISION_PUBLISHING:
                if not _step_publish_collision():
                    state = State.READY
            State.READY, State.UNLOADING:
                return false
    return true  # ran out of budget but still has work
```

The `NativeStreamingManager` rotates payloads:

```gdscript
func _process(delta: float) -> void:
    var frame_budget_usec: int = int(SC.STREAMING_BUDGET_MS * 1000.0)
    var per_payload_usec: int = int(frame_budget_usec / max(1, _active_payloads.size()))
    for payload in _active_payloads:
        payload.publish_step(per_payload_usec)
```

This collapses the cross-cutting global queues into N per-payload queues, each
with one owner. Eviction never races with classification. Collision finalize
never races with unload — they're in the same FSM, same payload, same thread.

### Recipe 3 — Per-Cell Static MultiMesh Bucket

Replaces world-scoped `PrototypeRegistry`, which violates the MultiMesh
documented all-or-nothing culling rule. One MultiMesh per (cell, prototype).

Doc backing: `classes/class_multimesh.html` ("every single instance will
always render (they are spatially indexed as one, for the whole object)") +
`tutorials/performance/using_multimesh.html` ("create several MultiMeshes for
different areas of the world").

```gdscript
class_name CellStaticBucket
extends RefCounted

var prototype_handle: StreamedResourceHandle  # strong ref → keeps Mesh alive
var multimesh: MultiMesh                       # strong, owned
var rs_instance: RID                           # owned, must be freed
var instance_count: int

func _init(handle: StreamedResourceHandle, transforms: Array[Transform3D],
        scenario: RID, mesh_index: int = 0) -> void:
    prototype_handle = handle
    multimesh = MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.mesh = handle.meshes[mesh_index]   # strong ref via property
    multimesh.instance_count = transforms.size()
    for i in transforms.size():
        multimesh.set_instance_transform(i, transforms[i])
    rs_instance = RenderingServer.instance_create()
    RenderingServer.instance_set_base(rs_instance, multimesh.get_rid())
    RenderingServer.instance_set_scenario(rs_instance, scenario)

func cleanup() -> void:
    if rs_instance.is_valid():
        RenderingServer.free_rid(rs_instance)
        rs_instance = RID()
    multimesh = null
    prototype_handle = null  # refcount drop; Mesh frees if last consumer
```

A `CellPayload` owns an `Array[CellStaticBucket]` — one per prototype that
appears in the cell. Each bucket is spatially scoped to ~117 m × 117 m, so
Godot's all-or-nothing MultiMesh culling works at cell granularity.

### Recipe 4 — Off-Thread Build, Main-Thread Attach

The Godot-canonical pattern from `thread_safe_apis.html`:

> "Build scene chunks outside the active tree in threads, then added in the
> main thread"

```gdscript
# WorkerThreadPool task — runs off-thread
func _build_cell_node_offthread(refs: Array) -> Node3D:
    var cell_node: Node3D = Node3D.new()
    cell_node.name = "Cell_%s" % grid_to_string()
    for ref in refs:
        # EXPERIMENTAL: PackedScene.instantiate from worker thread is NOT
        # documented as safe in Godot 4.6. Keep this commented out until a
        # small isolated harness proves it on the engine version in use.
        # var inst: Node3D = ref.handle.packed_scene.instantiate() as Node3D
        # inst.transform = ref.transform
        # cell_node.add_child(inst)
        pass
    return cell_node  # still detached from active tree

# Main-thread caller
func _on_worker_done(task_id: int) -> void:
    WorkerThreadPool.wait_for_task_completion(task_id)
    var cell_node: Node3D = _harvest_worker_result(task_id)
    # Now safe — main thread, deferred to next idle moment.
    get_tree().root.add_child.call_deferred(cell_node)
```

Two important rules visible here:

1. `wait_for_task_completion` is **mandatory** per the WorkerThreadPool docs.
   Don't fire-and-forget tasks.
2. `add_child` from worker is forbidden — must be deferred to main thread.

### Recipe 5 — Diagnostic Bridge Template

When a temporary fix is unavoidable (rare), it must follow CLAUDE.md's bridge
rule (`## Engineering Principle — Industry Standard, Never Kludge` rule 3).
Template:

```gdscript
# DIAGNOSTIC BRIDGE (YYYY-MM-DD, owner)
# Symptom: <one-line description of what this papers over>
# Canonical replacement: <the doc-blessed pattern this stands in for>
# Follow-up: <PR / commit that removes this bridge>
# TODO(owner, YYYY-MM-DD): remove by YYYY-MM-DD (typically 2 weeks)
return  # or whatever the bridge mechanism is
```

The four fields are non-optional. A bridge without an expiry date is a kludge.

## Official Godot 4.6 Research

Claude researched official Godot 4.6 documentation on 2026-04-29. Codex
spot-checked the load-bearing items against the official docs while merging
this section. Tags:

- `D`: documented in official Godot docs.
- `U`: undocumented or only inferable; treat as unproven until an isolated
  harness or manual traversal verifies it.

### Resource And RID Lifetime

Status: `D`, load-bearing.

Godot's server docs explicitly state that resources are ref-counted, but RID
references do not count as resource references. A project using server APIs must
keep a strong reference to the source `Resource` somewhere outside the server,
or the resource and its RID can be erased while the server-side object still
appears to have a RID.

Implication for the current crash:

`_model_cache.erase(key)` can drop the last strong `PackedScene` reference. If
no other owner holds strong refs to the inner `Mesh`, `Material`, `Shader`, or
other resources used by live RS instances, MultiMeshes, or scene instances,
their RIDs can become invalid. This makes the `StreamedResourceHandle` design
not optional: every consumer of server-bound resources must have a real strong
owner, not only a cache-key pin.

This is the most important finding. The current `ModelLoader` pin API is too
coarse because it pins a cache key, not all resources extracted from that cache
entry and handed to renderer/scene consumers.

Source:

- https://docs.godotengine.org/en/4.6/tutorials/performance/using_servers.html
- https://docs.godotengine.org/en/4.6/classes/class_resource.html

### PackedScene Instantiation And Inner Resources

Status: `U`.

The official `PackedScene` class page does not document thread-safety for
`PackedScene.instantiate()`. It also does not precisely document whether meshes
and materials inside instantiated subtrees are shared with the source
`PackedScene` internals in every relevant case.

The thread-safe APIs page shows off-tree scene construction in a thread as a
supported shape, then warns that creating/loading scene chunks from multiple
threads can cause unexpected behavior or crashes when shared resources are
touched by multiple threads.

Operational rule:

- Keep `PHASE_A_OFFTHREAD_INSTANTIATE = false` unless a small isolated Godot 4.6
  harness proves the exact pattern safe.
- Main-thread `PackedScene.instantiate()` remains the conservative default for
  production streaming until proven otherwise.
- Do not use the claim "PackedScene.instantiate is thread-safe since Godot 4.1"
  as an architectural premise unless a primary source is found.

Sources:

- https://docs.godotengine.org/en/4.6/classes/class_packedscene.html
- https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html

### Scene Tree And Thread-Safe APIs

Status: `D`.

The active scene tree is not thread-safe. Godot's documented pattern is:

- build or prepare off-tree data/nodes away from the active scene tree
- attach to the active scene tree via deferred/main-thread calls
- use servers directly for high-volume threaded creation when possible

The same page documents that:

- reading/writing existing GDScript array/dictionary elements from multiple
  threads is allowed
- changing container size, such as adding/removing keys, requires a `Mutex`
- handling resource references across threads is supported
- modifying the same unique resource from multiple threads is not supported
- loading the same resource from multiple threads needs care because resources
  are loaded once and shared

Implications:

- `_mesh_types_mutex` in `static_object_renderer.gd` is conceptually correct.
- Any worker path that adds/removes global dictionary entries needs the same
  discipline.
- `_pending_child_attaches` / main-thread attach is the right broad shape.
- Multiple off-thread `PackedScene.instantiate()` or resource mutation workers
  should be treated as experimental, not a default production lane.

Source:

- https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html

### ResourceLoader Threaded Loading

Status: mixed.

Documented:

- `ResourceLoader.load_threaded_request` starts a threaded load request.
- `load_threaded_get_status` reports invalid, in-progress, failed, or loaded.
- `load_threaded_get` blocks if called before the load is complete.
- default cache reuse can return an already-loaded shared `Resource`.
- using sub-threads may affect the main thread and cause slowdowns.

Undocumented or insufficiently specified:

- exact concurrent-request dedup semantics
- whether all call sites must be main-thread
- what happens if the logical request owner dies before `load_threaded_get`
- what lifetime guarantees exist for subresources after callback/publish
  handoff

Operational rule:

ResourceLoader is valid for async loading, but request ownership must be outside
ResourceLoader. A `CellPayload` or `StreamedResourceHandle` must own the request
state and decide when the loaded resource can be released.

Source:

- https://docs.godotengine.org/en/4.6/classes/class_resourceloader.html

### WorkerThreadPool

Status: `D`, hard rule.

Godot documents that every WorkerThreadPool task must eventually be waited on
with `wait_for_task_completion()` or `wait_for_group_task_completion()` so
allocated resources can be cleaned up. It also documents that completion checks
are only for the interval between adding and awaiting a task.

Undocumented:

- task cancellation semantics
- behavior if a bound object is freed before a task runs

Implications:

- cleanup design must wait out owned workers; it cannot assume cancellation
  exists
- bound objects/payloads must stay alive until the worker is done
- `drain_prereg_tasks()` is correct in principle
- every new WorkerThreadPool lane must have an explicit owner and drain path

Source:

- https://docs.godotengine.org/en/4.6/classes/class_workerthreadpool.html

### MultiMesh

Status: `D`.

Godot's MultiMesh docs state the key trade-off: a MultiMesh is spatially indexed
as one object, so widely separated instances render together and can hurt
performance. The official optimization tutorial recommends using multiple
MultiMeshes for different world areas when spatial separation matters.

The docs also state that changing `instance_count` clears/resizes buffers, while
`visible_instance_count` is the typical way to allocate a maximum and then vary
how many instances are drawn.

`set_buffer()` is documented, but no detailed threading contract is given. The
tutorial describes preparing the array with multiple threads and setting it in
one call, which supports the main-thread upload pattern.

Implications:

- a world-scoped per-prototype MultiMesh is contrary to the docs for a large
  open world
- per-cell or per-chunk MultiMesh buckets are the canonical Godot shape
- avoid `instance_count` churn during streaming
- keep buffer uploads explicit and budgeted
- `PrototypeRegistry` should not return as a world-scoped batcher; it should
  return, if at all, as spatial buckets

Sources:

- https://docs.godotengine.org/en/4.6/classes/class_multimesh.html
- https://docs.godotengine.org/en/4.6/classes/class_multimeshinstance3d.html
- https://docs.godotengine.org/en/4.6/tutorials/performance/using_multimesh.html

### Visibility Ranges And Fade

Status: mixed.

Documented:

- `visibility_range` is an engine-supported distance visibility feature
- fade mode `SELF` uses transparent rendering during transition and has a
  performance cost
- margins drive fade distance for fade modes and hysteresis for hard-cull mode

Undocumented or not settled for this project:

- exact fade implementation details relevant to custom dither shaders
- per-MultiMesh-instance fade compatibility
- shadow behavior during per-instance MultiMesh fades

Implication:

Do not delete custom MultiMesh crossfade shaders based only on the assumption
that engine `visibility_range` covers per-instance MultiMesh transitions. The
engine feature clearly applies to `GeometryInstance3D`; per-instance MultiMesh
fade needs an experiment before removing bespoke shader code.

Sources:

- https://docs.godotengine.org/en/4.6/tutorials/3d/visibility_ranges.html
- https://docs.godotengine.org/en/4.6/classes/class_geometryinstance3d.html

### Jolt And PhysicsServer3D

Status: mixed.

Godot's Jolt page documents that the built-in Jolt module has thread-safety
support, including the separate physics-thread project setting, but says this
has not been tested thoroughly and should be considered experimental.

Undocumented:

- body/shape creation requirements in this exact streaming pattern
- `ConcavePolygonShape3D.set_faces()` cost profile
- shape modification during physics steps
- body/shape lifetime behavior when parent scene nodes are freed mid-step

Implications:

- treat off-thread or aggressively interleaved physics publishing as unproven
- keep `--disable-jolt-attach` and collision ablations for diagnosis
- prefer player-local collision and conservative main-thread publication until
  manual traversal proves otherwise

Source:

- https://docs.godotengine.org/en/4.6/tutorials/physics/using_jolt_physics.html

### Net Design Consequences

1. `StreamedResourceHandle` is the correct ownership direction. Godot's server
   docs put the responsibility on every RID/resource consumer to keep strong
   resource references alive.
2. Replace `_model_cache` as ownership source. The cache should be a lookup,
   probably with weak refs or non-owning entries, while payloads/handles own
   resources.
3. Keep off-thread `PackedScene.instantiate()` disabled until proven in a small
   harness and then manual traversal.
4. Worker tasks must be waited on. Do not design cancellation paths that drop
   task-owned data before completion.
5. MultiMesh batching must be spatially bucketed. World-scoped batches violate
   the documented culling trade-off.
6. Do not assume engine visibility fade replaces per-instance MultiMesh shaders.
   Verify first.
7. Treat Jolt off-thread and interleaved runtime physics publication as
   experimental.
8. Keep the broad shape of off-tree preparation plus main-thread/deferred scene
   attach. That is the Godot-documented scene-tree pattern.

## AAA Streaming Patterns Side-By-Side (claude, 2026-04-29)

For each Godotwind subsystem, here's what an AAA engine does. Use this as a
sanity-check: if our approach diverges from all four reference engines, we're
probably wrong. Source classification: this section is **inferred / industry
analysis**, not Godot-doc-backed. Detailed case studies in
`docs/reference/near_streaming_industry_patterns.md`.

| Subsystem | Godotwind canonical | UE5 World Partition | Decima (HZD/HFW) | Unity DOTS/BRG | OpenMW |
|-----------|---------------------|---------------------|------------------|----------------|--------|
| Streaming I/O unit | 117 m exterior cell | 128 m grid cell | StaticTile (rect) | Addressable scene group | 8192 MW unit cell |
| Static clutter | Per-cell MultiMesh per prototype | HLOD merged mesh actor | Tile transform GPU buffer | BatchRendererGroup | Object paging chunks |
| Interactive objects | Per-ref Node3D | Per-actor sublevel + OFPA | Limited; mostly tile-based | GameObject (limited) | Per-ref MWWorld objects |
| Async load | ResourceLoader + WorkerThreadPool | Async sublevel load | Async tile load | Addressables.LoadAsync | osgDB::DatabasePager |
| Scene attach | Main thread + call_deferred | Main thread, budgeted spread | Main thread, budgeted | Main thread (LoadSceneAsync) | Main thread, frame-budgeted |
| Far visuals | FAR impostors (5 km) | HLOD layers + lower grid | activeGrid promotion | LOD groups + impostors | Distant terrain LOD chunks |
| Predictive prefetch | CellPreloader + velocity | StreamingSourceComponent | activeGrid expansion | Streaming priority | mPredictionTime + mPreloadCells |
| Frame budget | StreamingConfig (ms) | s.LevelStreamingActorsUpdateTimeLimit | Async + GPU compute | Coroutine-based | mLoadingThreads |

Two takeaways for an inheriting agent:

1. **No engine spawns full GameObjects/Actors for static clutter.** The
   per-cell GPU instance buffer is universal. Godotwind's `StaticObjectRenderer`
   direction is correct; the implementation must reach the per-cell-bucket
   shape.
2. **Every engine has a velocity prefetch.** OpenMW has the simplest
   implementation we can copy. Godotwind's `cell_preloader.gd` exists but is
   not yet wired into the streaming manager.

## Anti-Pattern Checklist (claude, 2026-04-29)

Before committing any streaming change, run this checklist. Each "yes" is a
red flag. Source: synthesized from CLAUDE.md `## Engineering Principle —
Simplicity Over Over-Engineering` + `## Engineering Principle — Industry
Standard, Never Kludge`.

- [ ] Does the fix add a new `*_DEFER_FRAMES_*` or `*_DEFER_TICKS_*` constant?
      Papering over an ownership bug. Find the lifetime issue instead.
- [ ] Does the fix add a new permanent `DEBUG_DISABLE_*` flag around a
      crashy system? Not a fix, a quarantine. Fix the system or rip it out.
- [ ] Does the fix introduce a new "phase" naming generation (Phase X.Y, Fix Z,
      Win N)? Strong signal the architecture isn't held in any one head.
- [ ] Does the fix add a new global queue that crosses cell lifetime
      boundaries? Wrong direction. Ownership should be per-payload.
- [ ] Does the fix add a new mutex or atomic on top of an existing one?
      Likely an ownership bug masquerading as a thread bug. Re-examine
      who owns the data.
- [ ] Does the fix make a function longer than 100 lines or cover more than
      5 responsibilities? Probably symptomatic. Split or rewrite.
- [ ] Does the fix write a new comment longer than the function body?
      CLAUDE.md flags this as a tell that the code requires defending,
      not just explaining.
- [ ] Does the fix require the next agent to read 3+ phase comments to
      understand intent? Not reducing complexity, just moving it.
- [ ] Does the fix involve a `call_deferred` chain longer than one hop?
      Restructure the call site. Multi-hop deferred chains are race
      generators.
- [ ] Does the fix touch C# / C++ / GDExtension to bypass a Godot rule?
      Unless the rule is documented broken, risk of stepping on undocumented
      engine state. Default to the GDScript canonical path.

Pass: every box checked "no". One yes = pause and find the root cause. Two
yeses = revert and try a different approach.

## Verification Gates (claude, 2026-04-29)

The 10-minute manual traversal is the *minimum* gate, not the complete gate.
For a system claiming "AAA-class streaming on Godot 4.6", these all apply.
Source classification: gates 1-3 reproduce documented failures from this
project's history. Gates 4-6 are inferred best practice.

### Gate 1 — Manual Traversal (mandatory, hard)

10 minutes interactive in `scenes/Godotwind.tscn`, dense exterior cells.
Acceptance:

- no SIGSEGV / NOTIFICATION_CRASH
- no severe FPS collapse (under 100 FPS on target hardware)
- no queue runaway (instantiation queue stays bounded under 50)
- no memory growth over 100 MB during the run

### Gate 2 — Teleport Stress (hard)

Spawn at 5 different exterior cells in sequence, 30 seconds each, fast-travel
distances over 1 km. Acceptance:

- no crash on each teleport
- streaming queues drain within 5 seconds of arrival
- old cells unload completely (verify via memory delta)

### Gate 3 — Lifecycle / Shutdown (hard)

Launch, traverse 30 seconds, ALT+F4. Acceptance:

- exit code 139 + log shows `WM_CLOSE_REQUEST` / `USER_QUIT`: user quit (OK)
- exit code 139 WITHOUT user quit: crash on teardown (FAIL)
- clean shutdown after the benchmark stress runner (no `BENCH_QUIT` SIGSEGV)

### Gate 4 — Resource Cache Churn (hard)

Movement loop crossing cell boundaries every 2 seconds for 5 minutes.
Acceptance:

- ModelLoader cache size stabilizes (no unbounded growth)
- evictions happen, eviction count is logged, no SIGSEGV in eviction
- no resource leak (final cache size approximately matches initial steady state)

### Gate 5 — Frame Time Distribution (soft, target-dependent)

Capture 60 seconds of normal traversal frame times. Compute:

- p50, p95, p99, p99.9 frame time
- count of frames over each threshold (6.67 ms, 10 ms, 16.67 ms, 33.33 ms)

For 150 FPS target:

- p50 under 6.0 ms
- p95 under 8.0 ms
- p99 under 16.67 ms
- p99.9 under 33.33 ms
- frames over 33.33 ms (perceptible hitch): zero in 60 seconds

For 60 FPS target (interim):

- p50 under 14.0 ms
- p99 under 33.33 ms

### Gate 6 — Memory Snapshot (soft, diagnostic)

Use Godot's ObjectDB snapshot to confirm:

- no orphaned Node3D growing over time
- no leaked RID (PhysicsServer / RenderingServer body/instance count stable
  after unload)
- no leaked Resource instances (Mesh, Material count tracks active cells)

### Gate Order

A new system must clear gates 1-3 before it ships. Gates 4-5 are the second
PR, after the system has soaked. Gate 6 is best-effort diagnostic — useful
when memory/lifetime concerns are open, optional otherwise.

Stress harness alone is **not** a gate. It missed the manual movement crash
that triggered this entire review. The harness reproduces some failure
modes; manual traversal reproduces others.

## Glossary (claude, 2026-04-29)

Terms used across this doc and the streaming code. Useful for fresh agents.

- **AABB** — axis-aligned bounding box. Used for visibility_range measurement
  reference (per-mesh) and culling.
- **Bucket** — a spatially scoped subset of instances of one prototype. One
  MultiMesh per bucket; Godot's all-or-nothing MultiMesh culling works
  correctly at bucket granularity.
- **Cell** — the streaming I/O unit. In Morrowind data: 8192 MW units = 117 m
  per side. Cell coords are integer Vector2i grids.
- **CellPayload** — refcounted owner of one loaded cell's state, queues, and
  resources. Replaces global per-lane queues in the canonical design.
- **Crossfade** — per-instance opacity blend during a tier transition.
  `visibility_range_fade_self` is the engine-native implementation
  (GeometryInstance3D level only); per-MultiMesh-instance crossfade is
  custom shader territory and not documented.
- **Detached subtree** — a Node3D constructed off-tree (via
  `PackedScene.instantiate` returning a root with no parent yet). Safe to
  hold off-thread within Godot's documented rules.
- **FAR tier** — 1000-5000 m. Octahedral impostors via single MultiMesh draw
  call.
- **GeometryInstance3D** — Godot 3D node base for renderable instances.
  Supports `visibility_range_*` properties.
- **Handle** — short for `StreamedResourceHandle`. Refcounted owner that holds
  strong refs to a `PackedScene` plus extracted Mesh/Material/Shader resources.
- **HLOD tier** — 300-1000 m. One merged RS instance per chunk (1×1, 2×2, 4×4
  cell groups).
- **Hysteresis** — gap between tier-up and tier-down distance thresholds,
  preventing oscillation at the boundary. See `distance_utils.gd::HYSTERESIS_*`.
- **Impostor** — pre-rendered billboard texture array used for FAR-tier
  rendering. Octahedral encoding gives view-direction-correct silhouette.
- **Instance** (RS instance) — RenderingServer's render-able object,
  identified by RID. Created via `RenderingServer.instance_create`. Bound to
  a mesh resource via `instance_set_base`.
- **MID tier** — 150-500 m (or 150-300 m with HLOD enabled). One RS instance
  per object, with embedded LOD chain inside the ArrayMesh
  (`surface_lod_indices`).
- **NEAR tier** — 0-150 m. Full Node3D + collision + physics + interactive.
- **NIF** — Bethesda's mesh format. Parsed by `src/core/nif/`, prebaked to
  Godot resources at tool time.
- **Node3D** — Godot's 3D scene tree node. Living scene-tree object with
  per-frame _process, transform inheritance, and full engine integration.
  Highest per-instance cost.
- **Off-tree** — a Node not attached to the active scene tree. Safe to
  construct from worker threads per Godot's thread-safe APIs page.
- **Pin** — lifetime extension for a cache entry. In the canonical design,
  pin is implicit via refcount of a `StreamedResourceHandle`. The current
  `ModelLoader.pin_cached_model` API is wrong-granularity (pins cache key,
  not extracted resources).
- **Prototype** — the unique geometry+material identity of a static object.
  Many cell instances share one prototype. Identified by NIF path.
- **Refcount** — Godot's RefCounted reference counting for `Resource` and
  `RefCounted` subclasses. Reaches zero → instance freed.
- **RenderingServer (RS)** — Godot's rendering subsystem. Accessed via RID
  for performance.
- **RID** — Resource ID. Opaque handle into a server (Rendering, Physics,
  Audio). NOT a refcount holder. Becomes invalid when source resource is
  freed.
- **Scenario** — RenderingServer's per-world rendering context. All RS
  instances must be assigned to a scenario.
- **Slot** — one instance index inside a MultiMesh. `slot_freelist` /
  `slot_live` is a freelist allocator pattern.
- **StaticBody3D** — Jolt Physics static body. Holds CollisionShape3D
  children. One per cell in the canonical design.
- **StreamedResourceHandle** — see Handle.
- **Tier** — distance band (NEAR / MID / HLOD / FAR / HORIZON). An object
  belongs to one tier at a time.
- **WorkerThreadPool** — Godot's task-based thread pool. Tasks must be
  awaited via `wait_for_task_completion` per the docs.

## Files To Read First

- `docs/audit/godot_46_near_streaming_aaa_audit_2026_04_29_codex.md`
- `docs/audit/near_streaming_regression_tracker_2026_04_29_codex.md`
- `docs/plans/streaming_stutter_2026_04_25.md`
- `docs/systems/distance_rendering.md`
- `src/core/world/model_loader.gd`
- `src/core/world/cell_manager.gd`
- `src/core/world/native_streaming_manager.gd`
- `src/core/world/static_object_renderer.gd`
- `src/core/world/prototype_batch.gd`
- `src/core/world/prototype_registry.gd`
- `src/core/world/cell_payload.gd`
- `src/core/world/cell_static_collision.gd`

## Non-Goals Until P0 Passes

- no HLOD work
- no impostor work
- no distant rendering re-enable
- no new gameplay integration
- no new performance feature flags
- no additional defer-frame constants
- no "stress harness passed, therefore stable" claims

## Verification Rule

For any code change in this area:

1. If C# changed, run:

```powershell
dotnet build Godotwind.sln --configfile NuGet.Config
```

2. Launch interactively:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn
```

3. Manually traverse dense exterior cells for 10 minutes.

4. Only then call the NEAR streaming path stable.

If manual traversal cannot be run, say exactly why in the final response.
