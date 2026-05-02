# Godot 4.6 NEAR Streaming + AAA Pattern Audit

Date: 2026-04-29

Baseline commit: `a84d9a962578ffcd94ba6f1113a334680a92fc30`

Audited head: `0a45c9c` plus the current dirty working tree described in
`docs/audit/near_streaming_regression_tracker_2026_04_29_codex.md`.

Scope: NEAR-only rendering/streaming with distant rendering disabled. The target
is a stable runtime that does not drop below 150 FPS on the test hardware, while
still allowing player interaction and collision around the player.

> **Currency note (2026-05-02):** this audit is historical NEAR-only guidance.
> FAR impostor rendering is default-on again through `SubsystemToggles`
> (`impostors=true`). HLOD remains implemented but opt-in (`hlod_enable`) after
> the 2026-05-02 default-on stress run exposed a chunk-surface draw-call blow-up.
> `--near-only` is now the explicit full distant-tier opt-out.
> Use `docs/systems/streaming_rendering_bible.md`,
> `docs/systems/distance_rendering.md`, and `docs/systems/object_paging.md` for
> the current HLOD/FAR policy.

## Executive Verdict

The current branch is not production-ready. The codebase is using several of the
right Godot 4.6 techniques, especially server-direct static rendering,
`MultiMesh` batching, threaded resource requests, and budgeted streaming queues.
But the current runtime is still unstable during manual traversal, and the most
recent crash evidence points away from a single "collision only" explanation.

The fast baseline `a84d9a9` is the correct recovery anchor. Changes after it
contain good ideas, but they also increased queue lifetime, resource lifetime
complexity, collision publish complexity, and unload/upload interleaving. Those
systems now need to be reintroduced one at a time with crash and stutter gates.

The NEAR design should stay data-first:

- static visuals as RenderingServer / MultiMesh state
- gameplay objects as sparse Node3D promotions
- collision on a separate player-local lane
- no full-cell scan, load, instantiate, upload, collision finalize, and unload
  in the same frame

That is the same broad shape used by production open-world engines: data is
streamed and promoted through priority queues, while only a small playable bubble
has full gameplay objects and collision.

## Current Production Readiness

Status: not functional enough to call production-ready.

What is present:

- NEAR cells can stream and render.
- Bulk statics have a server-direct path in `static_object_renderer.gd`,
  `prototype_registry.gd`, and `prototype_batch.gd`.
- Doors, containers, activators, lights, actors, and carryables still have
  Node3D promotion paths through `reference_instantiator.gd`.
- A server-direct static collision lane exists in `cell_static_collision.gd`.
- Loading readiness now has `is_async_visual_playable()` so the game can stop
  waiting for proximity-deferred tail work.

What blocks production:

- Manual traversal still crashes. The latest captured crash went through
  `_evict_if_over_budget()` in `model_loader.gd` while draining async loads.
- Movement FPS is poor after the latest mitigations; queues around 111-130 were
  observed during traversal.
- Collision lane is explicitly marked as started but buggy at `0a45c9c`.
- Benchmark teardown also crashes, which means the lifecycle is not clean even
  outside traversal.
- The current dirty mitigations reduce some race windows but are not proven
  fixes.

The player can interact in principle, but the system is not yet reliable enough
to promise interaction and collision around the player under normal movement.
Collision is the main functional gap: it exists, but publish latency, crash risk,
and runtime cost are not yet bounded well enough.

## Godot 4.6 Ground Rules

The official Godot 4.6 docs support the current high-level direction, with some
important caveats.

### Scene Tree And Threads

Godot's active scene tree is not thread-safe. Creating scene chunks off-tree can
be useful, but Godot warns that doing this from multiple threads risks shared
resource mutation and crashes because resources are loaded once and shared by
path.

Implication for this project:

- Worker threads should prepare plain data, sort refs, compute transforms,
  gather collision triangles, and request resources.
- Main-thread code should publish to the scene tree, RenderingServer, and
  PhysicsServer under explicit budgets.
- Any path that mass-instantiates `PackedScene` or creates rendering/physics
  nodes off-thread should stay experimental until it survives long manual runs.

### Servers And RIDs

Godot's server APIs exist specifically so the scene system can be bypassed for
performance-sensitive work. The docs also warn against querying servers every
frame because readback can stall asynchronous server work.

Implication:

- The server-direct static renderer is the right direction.
- Runtime server operations should be mostly one-way: create, update, hide,
  free.
- The project should continue avoiding per-frame server readback.
- RID lifetime needs strict ownership. Crashes around unload/upload often mean
  ownership and publish ordering need to be simpler, not cleverer.

### MultiMesh

Godot's MultiMesh is designed for drawing many copies of the same mesh in a
small number of draw calls. Its key limitation is that individual instances are
not frustum culled independently; a MultiMesh is visible all-or-nothing, unless
the project splits instances into spatially smaller MultiMeshes.

Implication:

- World-scoped prototype batches are dangerous if they become too large.
- Area/chunk-bounded batches are safer for NEAR and mandatory for distant.
- `MultiMesh.set_buffer()` should be treated as a GPU upload, not as a cheap
  property write.
- Empty batch handling should avoid zero-visible edge cases that have already
  triggered instability.

### Collision

Godot's concave/trimesh collision is accurate but slow, static-only, and best for
level geometry. The docs recommend simplified collision meshes when small visual
details do not matter for play feel.

Implication:

- Runtime full-cell trimesh publish is the wrong thing to do during a visual
  streaming spike.
- The correct long-term answer is prebaked or sidecar collision data, simplified
  where possible.
- The correct runtime answer is a player-local collision bubble with its own
  readiness and budget gates.

## Baseline Delta

### `a84d9a9`: Fast Baseline

This is the point to recover from. It was fast enough to be worth protecting. It
should be treated as the last known good performance anchor, not necessarily as a
complete production design.

### `916116f`: Budgeted Classification And Safer Static Batch Visibility

Good ideas:

- Split request classification and model-load drains into separate budgeted
  lanes.
- Avoided doing every cell classification task in one frame.
- Hid empty static batches through RenderingServer visibility instead of relying
  on fragile zero-visible upload behavior.

Risks introduced:

- More queues hold resources and callbacks for longer.
- Cache eviction now runs in a hotter async-load path.
- Longer request lifetimes make resource pinning harder to reason about.
- Manual movement can keep many requests partially classified, queued, or
  pending disk load while unloads are happening.

Recommendation: keep this architectural split only after fixing model cache
eviction and adding active resource pinning.

### `0a45c9c`: Collision Lane

Good ideas:

- Adds a dedicated static collision build/finalize path.
- Uses `is_async_visual_playable()` so visual readiness does not need to wait on
  all proximity-deferred work.
- Slices collision finalization instead of publishing an entire cell body at
  once.

Risks introduced:

- `ConcavePolygonShape3D.set_faces()` is still a costly atomic operation per
  slice.
- Slicing a cell into many static bodies increases PhysicsServer body count and
  broadphase churn.
- Collision publish now competes with visual streaming, unload, and RS cleanup.
- Current dirty state defers collision in quiet periods, but that can create
  long backlogs if the visual system never becomes quiet.

Recommendation: do not ship this collision lane as default until it is isolated,
benchmarked, and correctness-tested around the player.

### Dirty Working Tree

The current dirty changes are mitigation attempts:

- `PHASE_A_OFFTHREAD_INSTANTIATE = false`
- static MultiMesh upload deferral after unload
- collision finalization gated behind visual quiet periods
- benchmark runner clean-quit metadata
- reduced collision slice size

These are useful forensic edits, not proven fixes. The tracker explicitly says
manual traversal still crashes and movement FPS is bad.

## Code Audit

### `model_loader.gd`

High-risk area: model cache eviction and async instantiate drain.

Current facts:

- `MAX_CACHE_SIZE` is 500.
- `_evict_if_over_budget()` evicts down to 80 percent of that size.
- `process_async_loads()` drains pending instantiate queue first, polls threaded
  loads second, then drains the deferred queue.
- `_drain_pending_instantiate_queue()` caches a newly loaded `PackedScene`, calls
  `_evict_if_over_budget()`, then invokes callbacks and may instantiate scenes.
- The latest manual traversal crash points at `_evict_if_over_budget()` from
  `_drain_pending_instantiate_queue()`.

Main concern:

Eviction is happening inside the same hot path that is resolving async loads and
firing callbacks. Even if GDScript references should keep the immediate
`PackedScene` alive, the system has many other holders: active payloads, pending
requests, pending instantiate callbacks, static prepare queues, proximity
deferred objects, and cell unload limbo. The eviction code does not appear to
know which cache keys are currently pinned by those systems.

Required fix:

- Add a real active pin set for resource/cache keys.
- Pin keys held by pending async loads, pending instantiate entries, active cell
  payloads, static prepare work, deferred interactives, and queued callbacks.
- Make `_evict_if_over_budget()` skip pinned keys.
- Defer eviction to a low-pressure lane instead of running it inside callback
  drain.
- Add telemetry for attempted, skipped, and completed evictions.

Until this is fixed, the manual crash should be treated as a P0 issue.

### `cell_manager.gd`

Good structure:

- Budgeted request classification is the right shape.
- Payload-first design is better than direct scene construction.
- Static refs are separated from interactive refs.
- `is_async_visual_playable()` is a useful readiness concept.

Current issues:

- `process_async_instantiation()` still multiplexes too many lanes:
  classification, disk load drain, conversion, pool prewarm, static prepare,
  collision dispatch/finalize, attach, static add, light add, actor add, Node3D
  add, worker-static completion, and defer bookkeeping.
- A single frame can still become a negotiation between unrelated systems.
- `PHASE_A_OFFTHREAD_INSTANTIATE=false` is only a triage flag. It did not fix the
  visual crash and it increases main-thread Node3D pressure.
- Interactive Node3D model-load pressure remains visible in logs, especially for
  containers, doors, activators, and lights.

Required fix:

Split the visual publish path into smaller explicit lanes:

- static visual publish
- interactive spawn/promote
- light publish
- collision publish
- unload/free
- resource eviction

Each lane needs its own budget, queue length telemetry, and spike counter.

### `cell_static_collision.gd`

Good direction:

- Static collision is server-direct instead of scene-tree-heavy.
- Triangle collection can happen away from the visual publish path.

Current issues:

- Runtime `ConcavePolygonShape3D.set_faces()` remains a hard cost.
- `finalize_body_slice()` turns one cell into many PhysicsServer bodies when
  sliced.
- This can reduce one giant spike but trade it for sustained body creation,
  broadphase insertion, and cleanup churn.

Required fix:

- Move toward prebaked simplified collision resources per cell/chunk.
- Publish only the current cell and a short player-local ring.
- Treat visual cell readiness and collision readiness separately.
- Keep player movement gated only when collision for the immediate bubble is not
  ready.

### `native_streaming_manager.gd`

Good structure:

- The manager now has budgeted unload and RS hide queues.
- Desired-state reversal during unload limbo is better than immediately freeing
  everything.

Current issues:

- Unload, RS hide, RS cleanup, static uploads, collision finalize, and model
  eviction can still overlap in ways that are difficult to reason about.
- Collision quiet-period gating prevents one crash class but can starve collision
  under continuous movement.
- Benchmark clean quit still crashes, so lifecycle ordering is not solved.

Required fix:

- Add an explicit streaming phase order per frame.
- Forbid collision finalize and model eviction in frames with unload/free or
  static buffer upload.
- Make shutdown run the same lifecycle as normal unload, then wait for all async
  queues before quitting.

### `prototype_batch.gd` / `prototype_registry.gd` / `static_object_renderer.gd`

Good structure:

- RenderingServer and MultiMesh batching are the correct Godot primitives for
  static clutter.
- The RS visibility path for empty batches is better than frequent zero-visible
  buffer mutations.

Current issues:

- World/prototype-scoped batches can become too spatially broad for MultiMesh
  culling rules.
- Buffer upload deferral is defensive, but it does not remove the underlying
  upload hazard.
- If slot release and buffer upload can interleave during unload churn, the
  system needs stronger ownership state, not only frame delays.

Required fix:

- Keep batches spatially bounded.
- Upload only dirty spatial batches.
- Never upload a batch in the same frame its slots were released by unload.
- Track upload bytes, upload count, skipped uploads, hidden batches, and live
  slots per frame.

## Are We Using Godot 4.6 To The Best Of Its Abilities?

Partly.

Best-use areas:

- Server-direct statics instead of thousands of MeshInstance3D nodes.
- MultiMesh for repeated static prototypes.
- Threaded `ResourceLoader` requests instead of blocking load calls.
- Request queues and per-frame budgets.
- Avoiding server readback in hot paths.
- Treating interactives differently from passive static clutter.

Not-best-yet areas:

- Too much high-cost work still drains through one visual instantiation driver.
- Resource cache eviction is not pin-aware enough for the current queue graph.
- Collision is still built/published too late and too expensively at runtime.
- Off-thread scene/PackedScene work remains risky and should not be normalized.
- Static batch upload safety is being handled by timing deferrals instead of a
  simpler ownership model.
- The test harness does not yet reproduce the manual traversal failure reliably.
- Startup warmup can hide runtime spikes by moving them into load time, but that
  is not the same as a production streaming solution.

For a 150 FPS target, the frame budget is 6.67 ms. That leaves little room for
streaming. A production NEAR runtime should usually spend around 1-2 ms on
streaming publish in normal movement, with rare controlled bursts during loading
screens or explicit startup warmup.

## AAA And Open-World Research

Public details for RDR2 and The Witcher 3 are incomplete. The safe conclusion is
not "copy a secret RDR2 system"; it is that production open-world engines use
the same repeated principles:

- spatial cells/sectors/chunks
- async IO and async CPU preparation
- strict frame budgets for CPU publish and GPU uploads
- distance, frustum, velocity, and importance priority
- dense NEAR gameplay bubble
- sparse distant visuals
- authored LODs, HLODs, impostors, and billboards
- prebaked or simplified collision/nav data
- aggressive content rules so assets are streamable
- benchmark routes that match real player motion

### The Witcher 3

CD Projekt RED's SIGGRAPH 2015 abstract explicitly calls out an open-world
rendering pipeline with threading considerations, distant lights, foliage, and
texture streaming work needed for an open-world RPG. That supports the same
lesson: the old-hardware result came from specialized streaming/rendering
systems, not from treating every object as an always-live gameplay node.

### Red Dead Redemption 2

Rockstar's public support material exposes the practical side: RDR2 has many
separate performance-sensitive settings, including volumetrics, shadows,
texture quality, tessellation, and other systems. Its SIGGRAPH 2019 material is
mostly about atmosphere/cloud/fog/sky lighting, not object streaming internals.
So any claim about exact RDR2 object streaming internals would be speculative.

The useful inference is modest: RDR2's performance on constrained hardware comes
from multiple tunable systems, heavy content authoring, and carefully budgeted
rendering work. That matches the direction here: one giant "show everything as
full objects" path cannot be the target.

### OpenMW Object Paging

OpenMW is directly relevant because it solves a Morrowind-like world problem.
Its object paging docs describe:

- chunking and LOD for distant terrain
- object paging for non-terrain objects outside the active grid
- cost/benefit merging for distant statics
- projected-size filtering
- active-grid object paging for CPU-limited areas
- caveats when merged objects interact with lighting limits

That is close to the right shape for Godotwind. The existing
`docs/systems/object_paging.md` already maps this into MID/HLOD/FAR chunk bands.
The important lesson for NEAR is that merging can improve CPU/draw-call cost,
but it changes lighting, culling, and gameplay semantics. It must be controlled
by distance band and object type.

## NEAR Improvement Plan

### P0: Stabilize The Baseline

Create or return to an `a84d9a9`-derived recovery branch. Reintroduce later
changes only behind gates.

Acceptance:

- 10 minute manual traversal through dense exterior cells with no crash.
- No movement crash with collision disabled.
- No movement crash with collision enabled.
- Clean benchmark shutdown.
- Queue length remains bounded and drains after crossings.

### P0: Fix Model Cache Eviction

Add pin-aware eviction before trusting any later result.

Implementation shape:

- `ModelLoader` exposes `pin_cache_key(key, owner)` and
  `unpin_cache_key(key, owner)`, or a lower-level counted pin map.
- `CellPayload`, pending async loads, pending instantiate queue, static prepare,
  deferred interactives, and active cells pin their resources.
- Eviction skips pinned keys and logs why.
- Eviction runs from a quiet/idle lane, not in the async callback drain.

### P1: Separate Player-Local Collision

Do not make every visible NEAR cell wait for full collision publish.

Implementation shape:

- Build collision readiness for current cell plus immediate neighbors.
- Defer or skip collision for NEAR cells the player cannot reach soon.
- Prefer prebaked simplified cell/chunk collision resources.
- Keep server-direct physics bodies, but publish them in tiny chunks and never
  during unload/upload frames.

### P1: Thin Interactive Node3D Pressure

Interactives must exist around the player, not across the whole visual radius.

Implementation shape:

- Doors, containers, activators, carryables, and lights get priority by distance
  and facing.
- Non-interacted distant interactives use cheap placeholders or metadata until
  promoted.
- Lights should have a server-direct or pooled path where possible.
- Containers/doors should not keep the whole cell "unfinished" if they are far
  outside interaction range.

### P1: Make Static Publish Predictable

The static renderer should be boring.

Implementation shape:

- spatially bounded batches
- no first-use batch allocation during boundary crossing
- no buffer upload in the same frame as slot release
- upload budget in bytes and count, not only time
- explicit ownership state for live, hidden, dirty, and releasing batches

### P2: Rebuild The Benchmark Gate

The current automated runs are useful but insufficient.

Required benchmark types:

- dense manual-route replay with real camera movement
- no-collision NEAR benchmark
- collision-enabled NEAR benchmark
- teleport stress
- shutdown/lifecycle stress
- resource-cache churn stress

Metrics to gate on:

- average FPS
- p95, p99, p99.9 frame time
- frames over 6.67 ms, 10 ms, 16.67 ms, and 33.33 ms
- queue length by lane
- uploaded bytes per frame
- PhysicsServer body creates/frees per frame
- ModelLoader evictions, skipped evictions, and pinned count
- active Node3D count by type

## When Can Distant Rendering Resume?

Historical 2026-04-29 answer: not yet.

Current 2026-05-02 answer: FAR impostors have resumed by default. HLOD remains
implemented but opt-in pending chunk-surface draw-call reduction. The phased
sequence below is retained as the historical rationale for why the tiers were
parked during NEAR stabilization; it is no longer the active launch policy.
Current default: MID 0-500m, FAR impostors 500m+. HLOD opt-in:
`hlod_enable` keeps MID fallback as the 0-500m visual owner and renders HLOD
only from 500-1000m until per-chunk coverage gating can remove overlap without
creating holes or Z-fighting.
Current opt-outs: `--near-only`, `--no-impostors`, `hlod_disable`, and the
`SubsystemToggles` UI/console flags.

Distant rendering should resume only after NEAR has a stable contract. Otherwise
MID/HLOD/FAR will mask, amplify, or confuse the existing failures.

Resume distant work when all of these are true:

- `a84d9a9`-derived NEAR branch survives 10 minute manual traversal without
  crash.
- Benchmark shutdown is clean.
- No-collision NEAR route sustains at least 150 FPS with no severe spikes.
- Collision-enabled NEAR route has correct player-local collision and no
  movement crash.
- Queue lengths remain bounded under dense traversal.
- ModelLoader eviction is pin-aware and no longer appears in crash traces.
- Static upload/unload ordering has explicit ownership and telemetry.
- The automated route reproduces the manual traversal stress.

Then distant rendering should come back in this order:

1. MID prototype/static paging only, no HLOD generation changes.
2. HLOD chunks with object paging and strict upload budgets.
3. FAR impostors only after MID/HLOD is stable.
4. Distant collision never, except authored gameplay/nav requirements.

Each stage should be a single variable with NEAR frozen.

## Direct Answers

Are we using Godot 4.6 to the best of its abilities?

Partly. The server-direct and MultiMesh direction is right. The current lane
mixing, model eviction, runtime collision publish, and off-thread scene work are
not yet disciplined enough for Godot's limits.

Is it functional / production-ready?

No. It has the pieces, but current manual traversal crash, poor movement FPS,
and incomplete collision stability mean it is not production-ready.

What other improvements should we do to NEAR?

Fix model cache eviction first, split streaming lanes harder, make collision
player-local and prebaked/simplified, thin interactive Node3D promotion, and
make static uploads spatially bounded with explicit ownership.

When can we work on distant rendering again?

After NEAR is stable, measurable, and collision-correct. Distant rendering should
not resume while the model loader can crash during traversal or while collision
publish competes unpredictably with visual streaming.

## Sources

- Godot 4.6 Thread-safe APIs:
  https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html
- Godot 4.6 Optimization using Servers:
  https://docs.godotengine.org/en/4.6/tutorials/performance/using_servers.html
- Godot 4.6 Optimization using MultiMeshes:
  https://docs.godotengine.org/en/4.6/tutorials/performance/using_multimesh.html
- Godot 4.6 ResourceLoader:
  https://docs.godotengine.org/en/4.6/classes/class_resourceloader.html
- Godot 4.6 Collision shapes:
  https://docs.godotengine.org/en/4.6/tutorials/physics/collision_shapes_3d.html
- Godot blog, "Why does Godot use Servers and RIDs?":
  https://godotengine.org/article/why-does-godot-use-servers-and-rids/
- The Rendering Features of The Witcher 3: Wild Hunt, SIGGRAPH 2015 abstract:
  https://history.siggraph.org/wp-content/uploads/2022/10/2015-Talks-Torok_The-Rendering-Features-of-The-Witcher-3-Wild-Hunt.pdf
- SIGGRAPH 2019 Advances in Real-Time Rendering, RDR2 atmosphere talk listing:
  https://www.advances.realtimerendering.com/s2019/index.htm
- Rockstar support, RDR2 graphics performance tuning:
  https://support.rockstargames.com/articles/4dhIZ7x25mF7gO4NEhlUO9/graphics-performance-tuning-in-red-dead-redemption-2-on-pc
- OpenMW object paging overview:
  https://openmw.org/2020/openmw-spotlight-turning-the-pages/
- OpenMW terrain/object paging settings:
  https://openmw-improved-docs.readthedocs.io/en/latest/reference/modding/settings/terrain.html
