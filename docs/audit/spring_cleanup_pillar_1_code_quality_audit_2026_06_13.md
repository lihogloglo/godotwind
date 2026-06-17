# Spring Cleanup Pillar 1 Audit: Code Quality And Architecture

Date: 2026-06-13

Scope: read-only audit of the current working tree for code quality,
architecture, maintainability, modularity, ownership clarity, dead/duplicate
systems, stale comments, and cleanup sequencing. No runtime code was changed.

Inputs:

- `docs/audit/spring_cleanup_program_2026_06_13.md`
- `docs/audit/spring_cleanup_pillar_1_code_quality_charter_2026_06_13.md`
- `docs/STATUS.md`
- `docs/systems/adapter_boundary.md`
- `docs/systems/distance_rendering.md`
- `docs/systems/streaming_rendering_bible.md`
- Focused agent reviews: ownership explorer, architecture critic,
  Godot-engine expert, open-world streaming expert.

## Verdict

Godotwind's broad architecture is pointed in the right direction: normalized
world sources now feed the main streaming/rendering systems, static visuals are
moving through cell-local bucket ownership, RID lifetimes are much more explicit
than earlier streaming generations, and the current default runtime avoids the
worst Godot threading traps.

The main Pillar 1 risk is overlapping ownership, not a single bad function.
Parser-shaped `CellRecord` / `CellReference` paths, normalized
`WorldObjectRecord` paths, private subsystem reach-through, parked experimental
paths, and stale compatibility aliases all coexist. Cleanup should therefore
start by making ownership observable and explicit before deleting large code.

First cleanup priority: remove or quarantine the paths that make ownership hard
to reason about:

1. dual legacy/normalized object pipelines in `CellManager` and
   `ReferenceInstantiator`;
2. private-field wiring between `NativeStreamingManager`, `CellManager`,
   `world_explorer`, and diagnostics;
3. disabled but re-enableable worker-thread prototype preregistration;
4. stale compatibility aliases and dead parked rendering paths.

## Mechanical Inventory

Commands run during this session:

- `git status --short`
- `rg --files src docs tests | Measure-Object`
- line-count scan for `src/**/*.gd` and `src/**/*.cs`
- debt marker scan for `TODO|FIXME|HACK|workaround|temporary|legacy`
- `print` / `push_error` / `push_warning` scan in `src/core`
- threading/deferred scan for `WorkerThreadPool`, `call_deferred`,
  `wait_for_task_completion`, and transform writes
- source-boundary scan for `CellRecord`, `CellReference`, `get_source_*`,
  `ESM`, `BSA`, `NIF`, and Morrowind markers in generic paths
- private-field reach-through scan for `._*` from orchestration files

Current tree caveat: the audit ran over an already dirty worktree. Modified
runtime files include `cell_manager.gd`, `native_streaming_manager.gd`,
`reference_instantiator.gd`, `interior_pocket_manager.gd`,
`world_explorer.gd`, hydrology, transition, render-layer, C#, and test files.
Before implementation, compare each cleanup target against the intended branch
baseline so active feature work is not mistaken for accepted architecture debt.

Repository inventory:

| Metric | Value |
|---|---:|
| `src` + `docs` + `tests` tracked paths from `rg --files` | 1270 |
| Largest GDScript/C# file | `src/core/world/cell_manager.gd` at 4125 lines |
| Largest tool scene script | `src/tools/world_explorer.gd` at 3908 lines |

Largest files sampled:

| Lines | Path |
|---:|---|
| 4125 | `src/core/world/cell_manager.gd` |
| 3908 | `src/tools/world_explorer.gd` |
| 3173 | `src/core/world/native_streaming_manager.gd` |
| 2544 | `src/core/world/native_impostor_renderer.gd` |
| 2516 | `src/core/nif/nif_converter.gd` |
| 2443 | `src/core/water/ocean_fft_provider.gd` |
| 2162 | `src/core/world/interior_pocket_manager.gd` |
| 2156 | `src/core/world/reference_instantiator.gd` |
| 1860 | `src/core/world/object_paging.gd` |
| 1767 | `src/core/world/static_object_renderer.gd` |

Hotspot shape scan:

| Path | Lines | Funcs | Source markers | Deferred markers | RS calls | Worker markers |
|---|---:|---:|---:|---:|---:|---:|
| `src/core/world/cell_manager.gd` | 4125 | 153 | 99 | 56 | 0 | 22 |
| `src/tools/world_explorer.gd` | 3908 | 158 | 58 | 12 | 0 | 0 |
| `src/core/world/native_streaming_manager.gd` | 3173 | 106 | 12 | 18 | 0 | 1 |
| `src/core/world/native_impostor_renderer.gd` | 2544 | 97 | 15 | 10 | 0 | 12 |
| `src/core/world/reference_instantiator.gd` | 2156 | 85 | 137 | 31 | 20 | 22 |
| `src/core/world/interior_pocket_manager.gd` | 2162 | 87 | 33 | 2 | 0 | 0 |
| `src/core/world/object_paging.gd` | 1860 | 56 | 64 | 1 | 8 | 0 |
| `src/core/world/static_object_renderer.gd` | 1767 | 66 | 57 | 1 | 14 | 2 |

Highest debt-marker concentrations:

| Markers | Path |
|---:|---|
| 22 | `src/core/world/static_object_renderer.gd` |
| 6 | `src/core/world/reference_instantiator.gd` |
| 6 | `src/tools/world_explorer.gd` |
| 5 | `src/core/water/ocean_fft_provider.gd` |
| 3 | `src/core/world/object_paging.gd` |
| 2 | `src/core/world/cell_manager.gd` |
| 2 | `src/core/world/native_streaming_manager.gd` |

## Ownership Map

### `CellManager`

Current responsibility: owns cell load requests, parser/manifest bridging,
async request tables, model request queues, instantiation queues,
proximity-deferred interactives, static collision publication, and
`ReferenceInstantiator` configuration.

Evidence:

- File contract says it loads and instantiates cells:
  `src/core/world/cell_manager.gd:1`.
- It owns `ModelLoader`, `ReferenceInstantiator`, `StaticShapeCache`,
  `CellStaticCollision`, and source providers:
  `src/core/world/cell_manager.gd:14`.
- Source-cell accessors still call `get_source_cell` and
  `get_source_exterior_cell`: `src/core/world/cell_manager.gd:155`,
  `src/core/world/cell_manager.gd:165`.
- `LoadProfile`, `AsyncCellRequest`, and `InstantiationEntry` live inside this
  file: `src/core/world/cell_manager.gd:1093`.
- Static collision dispatch and finalization live here:
  `src/core/world/cell_manager.gd:4226`.
- It still queues parser-shaped `CellReference` payloads:
  `src/core/world/cell_manager.gd:4539`.

Assessment: this is the central ownership knot. Its size alone is not the
problem; the problem is that it is both a generic streaming coordinator and a
migration bridge for parser-shaped source data.

### `ReferenceInstantiator`

Current responsibility: turns legacy `CellReference` values and normalized
`WorldObjectRecord` values into either Node3D gameplay objects or static
renderer entries, while also managing source-adapter helper calls, worker
pre-registration, interaction shape generation, actor/light handling, and
diagnostic side channels.

Evidence:

- File contract is ESM reference conversion:
  `src/core/world/reference_instantiator.gd:1`.
- It keeps injected source and spawn adapters:
  `src/core/world/reference_instantiator.gd:43`.
- Legacy `instantiate_reference(ref: CellReference)` remains:
  `src/core/world/reference_instantiator.gd:367`.
- Normalized `instantiate_world_object_record()` also exists:
  `src/core/world/reference_instantiator.gd:405`.
- It exposes mutable last-call diagnostics read by `CellManager`:
  `src/core/world/reference_instantiator.gd:343`.
- Actor fallback remains explicitly legacy:
  `src/core/world/reference_instantiator.gd:1851`.

Assessment: this is the second half of the central ownership knot. The
highest-value cleanup is not splitting every builder out immediately; it is
first replacing mutable `last_*` side channels with an explicit result object.

### `NativeStreamingManager`

Current responsibility: top-level streaming orchestrator, camera tracking,
frame phase budget, loaded/unloading cell maps, startup and teleport handling,
HLOD/FAR/distant-light publication, tier toggles, persistent carried-node
evacuation, and stats.

Evidence:

- File contract says it coordinates cell loading and native visibility:
  `src/core/world/native_streaming_manager.gd:1`.
- Publication lanes are declared in this class:
  `src/core/world/native_streaming_manager.gd:45`.
- Initialization requires source, spawn adapter, coordinate mapper, and asset
  provider: `src/core/world/native_streaming_manager.gd:547`.
- It reaches into `CellManager` internals:
  `src/core/world/native_streaming_manager.gd:577`,
  `src/core/world/native_streaming_manager.gd:586`,
  `src/core/world/native_streaming_manager.gd:3052`.
- It owns persistent-node/orphan cleanup:
  `src/core/world/native_streaming_manager.gd:3279`.

Assessment: the class is the correct owner for frame orchestration, but the
private-field wiring makes subsystem boundaries brittle.

### `StaticObjectRenderer`

Current responsibility: owns static visual rendering through
`CellStaticBucket`, plus compatibility direct RS instance paths, parked
`PrototypeRegistry` branches, HLOD coverage handoff, visual proxies, and stats.

Evidence:

- File contract still says "each object is one RS instance":
  `src/core/world/static_object_renderer.gd:6`, while current docs say MID is
  cell-local buckets.
- Parked world-scoped `PrototypeRegistry` path is documented as wrong for a
  large open world: `src/core/world/static_object_renderer.gd:34`.
- `USE_PROTOTYPE_REGISTRY` is hardcoded false:
  `src/core/world/static_object_renderer.gd:90`.
- Active cell bucket dictionaries are present:
  `src/core/world/static_object_renderer.gd:63`.
- Legacy branch still remains in `add_instance()`:
  `src/core/world/static_object_renderer.gd:905`.
- Legacy registry stats remain exposed:
  `src/core/world/static_object_renderer.gd:1931`.

Assessment: the active direction is good, but dead/parked branches make the
renderer harder to audit and easier to accidentally re-enable incorrectly.

### `InteriorPocketManager`

Current responsibility: classic interior/exterior/interior transitions,
pocket slots, door registry, async pocket loading, fade/environment/camera
layer changes, and experimental seamless portal/walk-through behavior.

Evidence:

- File contract combines transition and pocket management:
  `src/core/world/interior_pocket_manager.gd:1`.
- It contains Morrowind building pattern heuristics:
  `src/core/world/interior_pocket_manager.gd:100`.
- Classic fade-to-black is the default; seamless is disabled:
  `src/core/world/interior_pocket_manager.gd:311`.
- Async pocket loading goes through `CellManager`:
  `src/core/world/interior_pocket_manager.gd:787`.
- Seamless path mutates camera masks, physics masks, exterior building meshes,
  collision, and clip shader materials:
  `src/core/world/interior_pocket_manager.gd:1470`,
  `src/core/world/interior_pocket_manager.gd:1937`,
  `src/core/world/interior_pocket_manager.gd:2189`.

Assessment: classic transition ownership is understandable. The experimental
seamless visual surgery is the mixed concern, and it should not drive cleanup
until the feature is either accepted or moved behind a dev-only surface.

### `world_explorer`

Current responsibility: main scene composition root and dev harness. It wires
Morrowind data, terrain, streaming, water, ocean controls, weather, UI, debug
systems, benchmark commands, interaction/carry, and interior transitions.

Evidence:

- File contract names it as the main scene orchestrator:
  `src/tools/world_explorer.gd:1`.
- It preloads a broad set of source, tool, runtime, UI, and interaction systems:
  `src/tools/world_explorer.gd:29`.
- It reaches into private runtime state:
  `src/tools/world_explorer.gd:533`,
  `src/tools/world_explorer.gd:588`,
  `src/tools/world_explorer.gd:3056`,
  `src/tools/world_explorer.gd:3218`.
- It exposes HLOD/debug commands and a `proto_registry` command:
  `src/tools/world_explorer.gd:3055`.

Assessment: its breadth is expected for a tool scene and composition root.
Do not split it just because it is large. The useful cleanup is replacing
private field reads with public inspection/debug APIs.

## Findings, Ranked

### 1. High: `CellManager` still owns two live object pipelines

Classification: must fix before broad deletion/refactor.

Evidence:

- `CellManager` still calls source-cell bridges:
  `src/core/world/cell_manager.gd:155`,
  `src/core/world/cell_manager.gd:165`.
- `CellManager` still carries parser-shaped `CellRecord` and `CellReference`
  in request and queue types: `src/core/world/cell_manager.gd:1130`,
  `src/core/world/cell_manager.gd:1164`.
- `ReferenceInstantiator` exposes both legacy and normalized entry points:
  `src/core/world/reference_instantiator.gd:367`,
  `src/core/world/reference_instantiator.gd:405`.
- `docs/STATUS.md` explicitly says remaining near/interior routes still bridge
  through adapter-local parser-shaped records.

Risk: cleanup can delete a path that looks old but still handles interiors,
fallback exterior loading, or near interactives.

Canonical target: one framework-facing object stream contract. Parser-shaped
data remains private to adapter/provider layers.

Small cleanup slice:

1. Add route counters for manifest/world-object vs source-cell/source-ref
   streaming paths.
2. Expose route stats in `get_loading_stats()`.
3. Add tests that assert no new core callsites of `get_source_cell`,
   `get_source_exterior_cell`, or `CellReference` appear outside accepted
   migration files.
4. Only then migrate one load route at a time.

Verification for implementation: focused unit boundary tests, then
`dotnet build Godotwind.sln` if C# touched, then the narrowest interactive
main-world or interior transition smoke depending on the route changed.

### 2. High: private-field wiring breaks local ownership reasoning

Classification: must fix early.

Evidence:

- `NativeStreamingManager` sets `CellManager._static_renderer` and calls
  `_sync_instantiator_config()` directly:
  `src/core/world/native_streaming_manager.gd:577`.
- It passes `_cell_manager._instantiator` and `_cell_manager._model_loader`
  into `CellPreloader`: `src/core/world/native_streaming_manager.gd:586`.
- It passes `_cell_manager._model_loader` into ObjectPaging/HLOD:
  `src/core/world/native_streaming_manager.gd:3052`.
- `world_explorer` reaches into `cell_manager._model_loader`:
  `src/tools/world_explorer.gd:533`,
  `src/tools/world_explorer.gd:588`.
- `world_explorer` reaches into `native_streaming_manager._loaded_cells` and
  `_static_renderer`: `src/tools/world_explorer.gd:3056`,
  `src/tools/world_explorer.gd:3218`.

Risk: any internal cleanup can break startup, HLOD, preloading, terrain/cache
prewarm, or diagnostics without compiler/test visibility.

Canonical target: explicit dependency injection and debug-inspection APIs.

Small cleanup slice:

1. Add `CellManager` public accessors only for stable dependencies that truly
   need to be shared, or better inject those dependencies from the composition
   root.
2. Add `NativeStreamingManager.get_loaded_cell_node(grid)` and
   `get_static_renderer_debug_target()` style debug APIs if they are needed.
3. Replace private reads in `world_explorer` and HLOD setup.

Verification: startup smoke, HLOD enable/disable, model cache prewarm, debug
overlay/collision visualizer command, and one cell load/unload traversal.

### 3. High: `CellManager` / `ReferenceInstantiator` communicate through mutable side channels

Classification: must fix early, pairs with finding 2.

Evidence:

- `ReferenceInstantiator` keeps mutable `last_type_name`, `last_inst_route`,
  and timing fields: `src/core/world/reference_instantiator.gd:343`.
- `CellManager` calls private methods and then reads those fields during the
  queue drain: `src/core/world/cell_manager.gd:3443`,
  `src/core/world/cell_manager.gd:3477`,
  `src/core/world/cell_manager.gd:3494`,
  `src/core/world/cell_manager.gd:3537`.
- `CellManager` also calls private helpers:
  `src/core/world/cell_manager.gd:4169`,
  `src/core/world/cell_manager.gd:4172`,
  `src/core/world/cell_manager.gd:4175`.

Risk: the result of a spawn depends on mutable global state in a shared
instantiator object. That makes concurrent/interleaved request reasoning
harder and hides API contracts from tests.

Canonical target: typed result object or dictionary envelope containing
`node`, `route`, `type_name`, `timings`, `static_data`, and `deferred_reason`.

Small cleanup slice:

1. Introduce an `InstantiationResult` helper.
2. Convert one route first, preferably the worker/static route or one
   non-interactive static path.
3. Remove the corresponding `last_*` read.
4. Repeat route-by-route.

Verification: unit tests for result envelope and a visual/benchmark smoke for
the route changed.

### 4. High: disabled Phase F worker preregistration remains one flag away from a known-crashy path

Classification: should fix before performance work; not default-runtime
active, but dangerous as a re-enableable bridge.

Evidence:

- `DEBUG_DISABLE_PHASE_F_PREREG` defaults true:
  `src/core/world/streaming_config.gd:542`.
- `world_explorer` can re-enable it via `--enable-phase-f-prereg`:
  `src/tools/world_explorer.gd:411`.
- Prereg schedules WorkerThreadPool tasks:
  `src/core/world/reference_instantiator.gd:1028`,
  `src/core/world/reference_instantiator.gd:1167`.
- Worker path still loads, instantiates, and registers prototypes:
  `src/core/world/reference_instantiator.gd:1245`,
  `src/core/world/reference_instantiator.gd:1251`.
- The streaming bible says off-thread `PackedScene.instantiate()` is not
  accepted without a harness.

Risk: a benchmark/dev flag can reactivate a path that violates the current
Godotwind threading contract and has prior crash history.

Canonical target: worker threads do pure data/resource IO; main thread
publishes/walks scene resources unless a dedicated Godot 4.6 harness proves the
exact pattern.

Small cleanup slice:

1. Decide: delete Phase F prereg, or convert it to data-only worker plus
   main-thread publish.
2. Remove the command-line re-enable surface until proof exists.
3. Add a unit/static test that prevents `PackedScene.instantiate()` or
   `register_from_prototype()` from worker bodies.

Verification: if deleted, run static bucket startup/streaming smoke. If
replaced, run dense/east route and worker-drain tests.

### 5. Medium-High: frame-budget ownership is still split across several layers

Classification: should fix before performance Pillar 3 implementation.

Evidence:

- `NativeStreamingManager` declares separate publication lanes:
  `src/core/world/native_streaming_manager.gd:45`.
- It locally tracks frame timing phases:
  `src/core/world/native_streaming_manager.gd:1035`.
- HLOD/FAR/distant-light/unload/static/near phases claim separate slices in
  the frame loop.
- `CellManager` also owns model request starts, instantiation drains, static
  prepare, and collision finalize budget decisions:
  `src/core/world/cell_manager.gd:1038`,
  `src/core/world/cell_manager.gd:3320`,
  `src/core/world/cell_manager.gd:4226`.
- `docs/STATUS.md` says runtime budgets still include transitional 8ms/4ms
  values and a target of roughly 1ms streaming publish at 150 FPS.

Risk: every subsystem can be individually budgeted while total publish time
still exceeds target. This blocks honest performance cleanup.

Canonical target: one publication budget owner passes explicit deadlines to
each lane and records total publish time.

Small cleanup slice:

1. Make `StreamingPublicationBudget` the explicit owner for per-frame publish
   time.
2. Pass deadlines to every streaming subphase, including preloader/static cull
   if they remain in the same publish accounting.
3. Add benchmark output for total publish time and per-lane overrun.

Verification: benchmark/smoke only after code changes; no visual proof needed
for budget counters alone, but rendering/streaming changes still require the
project visual smoke.

### 6. Medium: parked `PrototypeRegistry` duplicates active static bucket ownership

Classification: should fix as dead/duplicate code after static bucket tests are
available.

Status 2026-06-14: implemented as cleanup Slice 5. The production renderer no
longer preloads or routes through the parked registry, the `proto_registry`
console command is removed, static-cull registry throttle constants are gone,
and benchmark compatibility stats remain as zero-valued fields.

Evidence:

- Comment says world-scoped registry is wrong for large open worlds:
  `src/core/world/static_object_renderer.gd:34`.
- `USE_PROTOTYPE_REGISTRY` is false:
  `src/core/world/static_object_renderer.gd:90`.
- Registry branch remains in `add_instance()`:
  `src/core/world/static_object_renderer.gd:905`.
- Registry diagnostics and `proto_registry` command still exist:
  `src/core/world/static_object_renderer.gd:1931`,
  `src/tools/world_explorer.gd:3055`.

Risk: a known-wrong world-scoped MultiMesh path remains in the production
renderer and debug surface.

Canonical target: spatially local per-cell/per-area buckets only.

Small cleanup slice:

1. Confirm no test or command needs registry stats.
2. Delete `USE_PROTOTYPE_REGISTRY` branch and `proto_registry` command in one
   focused slice.
3. Keep compatibility stat fields at zero only if benchmark readers still
   require them.

Verification: static bucket visual/benchmark route, MID debug HUD, and static
renderer unit tests.

### 7. Medium: HLOD coverage metadata uses stale `source_ref_nums` aliases carrying object IDs

Classification: should fix soon; small and high leverage.

Status 2026-06-14: implemented as cleanup Slice 6. HLOD coverage manifests and
handoff APIs now use `source_object_ids` only; the stale `source_ref_nums`
manifest key and `set_hlod_covered_ref_nums()` alias are removed.

Evidence:

- ObjectPaging has both `source_object_ids` and `source_ref_nums` fields:
  `src/core/world/object_paging.gd:1528`.
- It writes `"source_ref_nums": state.source_object_ids.duplicate()`:
  `src/core/world/object_paging.gd:1533`.
- `NativeStreamingManager` still falls back to source ref nums in coverage
  handoff paths.
- Critic report also found `NativeImpostorRenderer.set_hlod_covered_ref_nums()`
  aliasing to object IDs.

Risk: future HLOD/FAR cleanup can interpret object IDs as numeric source ref
nums and suppress the wrong impostors or buckets.

Canonical target: one manifest contract named by the identity it actually
contains.

Small cleanup slice:

1. Lock manifest contract to `source_object_ids`.
2. Migrate fallback readers.
3. Add a unit test that generated manifests do not use `source_ref_nums`.
4. Delete alias APIs after one compatibility pass.

Verification: HLOD unit test plus HLOD enable/disable smoke if runtime code is
touched.

### 8. Medium: experimental seamless interiors are mixed into the production transition manager

Classification: should decide, but do not broadly delete during Pillar 1.

Evidence:

- `docs/STATUS.md` says seamless portal/walk-through remains experimental and
  parked.
- `InteriorPocketManager` defaults `seamless_enabled = false`:
  `src/core/world/interior_pocket_manager.gd:311`.
- The path is still exposed in UI according to the critic report.
- Seamless code mutates render masks, physics masks, exterior building
  visibility/collision, and clip materials:
  `src/core/world/interior_pocket_manager.gd:1470`,
  `src/core/world/interior_pocket_manager.gd:1937`,
  `src/core/world/interior_pocket_manager.gd:2189`.

Risk: classic transition cleanup must preserve restoration state for an
experimental feature, and users can accidentally exercise a parked mode.

Canonical target: classic transition path remains production. Seamless either
gets accepted with visual coverage or moves behind a dev-only command/test
scene.

Small cleanup slice:

1. Hide seamless UI from normal main-scene controls or label it as dev-only.
2. Move visual surgery helpers behind a separate helper only if the feature is
   being revived.
3. Do not delete the whole path until a product decision is made.

Verification: interior transition visual tests for classic path; seamless
matrix only if that feature is kept.

### 9. Medium: strict typing policy is not enforced by project settings

Classification: should fix or explicitly document as tooling gap.

Evidence:

- Godot expert reported `untyped_declaration` appears only in a commented line
  in `project.godot`, so Godot does not enforce it.
- Modified/new core files include untyped loop examples in
  `src/core/world/morrowind/morrowind_transition_provider.gd`.
- Project policy says strict typing is required in `src/core/`.

Risk: style policy depends on agent discipline instead of a mechanical guard.

Canonical target: CI/static lint or real Godot warning setting for core
GDScript typing.

Small cleanup slice:

1. Decide whether to enforce Godot warning settings globally or add a targeted
   audit script for `src/core`.
2. Fix current new untyped core declarations.
3. Add the check to Spring cleanup verification.

Verification: lint/static typing command plus focused gdUnit if behavior is
touched.

### 10. Low-Medium: synchronous and parked paths remain reachable enough to pollute measurements

Classification: should classify before performance Pillar 3.

Evidence:

- `async_loading_enabled` can be disabled:
  `src/core/world/native_streaming_manager.gd:119`.
- Sync pending load fallback warns it stutters:
  `src/core/world/native_streaming_manager.gd:2295`.
- Phase F prereg is disabled by config but re-enableable by command line.
- `CellPreloader` has disabled worker warm code:
  `src/core/world/cell_preloader.gd:36`,
  `src/core/world/cell_preloader.gd:332`.

Risk: benchmark results can accidentally include unsupported modes, and dead
code can keep old assumptions alive.

Canonical target: unsupported modes are deleted or clearly excluded from
benchmark validity.

Small cleanup slice:

1. Add benchmark metadata flags for sync mode, Phase F prereg, HLOD, FAR, and
   near-only.
2. Delete disabled worker-warm code if `ModelLoader.request_model_async` is
   the accepted path.
3. Remove unsupported command-line switches or mark their output invalid.

Verification: benchmark metadata unit/smoke.

### 11. Low: O(n) front-array operations remain in hot-ish queues

Classification: acceptable debt until queue-size telemetry proves pressure.

Evidence:

- Critic/open-world agents found `push_front`, `pop_front`, and `remove_at(0)`
  in `cell_payload.gd`, `object_paging.gd`, and `cell_manager.gd`.
- Project anti-patterns explicitly warn against `pop_front()` / `push_front()`.

Risk: probably bounded today, but dense HLOD and model-completion queues can
turn this into hidden churn.

Small cleanup slice:

1. Add queue-size telemetry first.
2. Replace only queues that exceed a measured threshold with cursor/ring-buffer
   patterns.

Verification: synthetic queue test plus dense/HLOD benchmark.

### 12. Low: logging policy drift remains in core

Classification: cleanup as touched, not a top-level refactor.

Evidence:

- `push_warning` / `push_error` remain in core world files, including
  `cell_manager.gd`, `static_object_renderer.gd`, and
  `native_impostor_renderer.gd`.
- `CellPreloader` still has raw `print()` diagnostics:
  `src/core/world/cell_preloader.gd:291`,
  `src/core/world/cell_preloader.gd:312`,
  `src/core/world/cell_preloader.gd:361`.

Risk: expected conditions are not consistently category-gated.

Small cleanup slice: convert expected/diagnostic conditions to `Log` when
touching the relevant file. Leave critical `push_error` decisions for a
separate error-policy pass.

## Dead/Duplicate Code Candidates

Needs proof before deletion:

- `StaticObjectRenderer` parked `PrototypeRegistry` path:
  `src/core/world/static_object_renderer.gd:34`,
  `src/core/world/static_object_renderer.gd:90`,
  `src/core/world/static_object_renderer.gd:905`.
- `world_explorer` `proto_registry` command:
  `src/tools/world_explorer.gd:3055`.
- Phase F worker preregistration re-enable flag and worker path:
  `src/tools/world_explorer.gd:411`,
  `src/core/world/reference_instantiator.gd:1028`,
  `src/core/world/reference_instantiator.gd:1245`.
- `CellPreloader` disabled `WORKER_RESOURCE_WARM_ENABLED` worker body:
  `src/core/world/cell_preloader.gd:36`,
  `src/core/world/cell_preloader.gd:332`.
- `source_ref_nums` compatibility aliases in HLOD/FAR coverage metadata.
- `ARCHITECTURE.md` older distance-tier wording, especially MID 0-500m and
  HLOD 300-1000m language, which contradicts `distance_rendering.md` and
  `distance_utils.gd`.

Do not delete without product/verification decision:

- Synchronous load fallback, if it is still a deliberate debug mode.
- Seamless interior path, if it is still a planned feature rather than dead
  code.
- Legacy `CellReference` paths, until route counters prove they are no longer
  load-bearing.

## Over-Engineering / Bespoke Bridge Candidates

- `ReferenceInstantiator.last_*` mutable diagnostics bridge. Replace with a
  return/result envelope.
- `NativeStreamingManager` and `world_explorer` private-field reach-through.
  Replace with explicit APIs or composition-root injection.
- `CellManager.LoadProfile` as an inner class consumed externally by interior
  loading. This is safer than old shared flag mutation, but should become a
  small standalone load policy if it grows.
- Seamless transition wall/building clip/hide logic inside
  `InteriorPocketManager`. Keep parked unless seamless is actively resumed.
- Phase F worker preregistration. It is a time-boxed performance experiment
  without current proof; delete or rebuild around data-only worker work.

## Positive Findings

Keep these patterns:

- `CellStaticBucket` owns/pins resources behind RS RIDs according to the Godot
  server lifetime rule, per agent review.
- `CellStaticCollision` does data work off-thread and publishes PhysicsServer
  resources on main, with strong shape refs.
- Current carry controller uses the canonical velocity-drive pattern rather
  than direct held-body transform writes, per Godot expert review.
- Interaction `Area3D` targets use passive raycast settings (`collision_mask=0`,
  monitoring/monitorable false), avoiding Jolt broadphase overhead.
- `docs/systems/distance_rendering.md` and
  `src/core/world/distance_utils.gd` now agree on the 150/400/1000/5000m
  distance contract.

## Test And Verification Coverage

Audit-only verification completed:

- Verified the charter and program docs exist.
- Verified referenced hotspot paths exist in the current worktree.
- Ran current mechanical inventory commands.
- Used four focused read-only agents and reconciled their reports manually.
- Created this docs-only report.

No Godot visual launch was run because no gameplay, streaming, rendering, or
performance runtime code was changed. No shader cache/import artifacts were
cleared because no shader files changed.

Implementation-slice verification requirements:

- C# touched: run `dotnet build Godotwind.sln`.
- GDScript behavior touched: run focused gdUnit tests.
- Gameplay/streaming/rendering/performance touched: run the narrowest Godot
  scene, benchmark, or interactive smoke that exercises the changed path.
- Shader touched: clear the relevant import/shader cache before visual check.
- Do not use automated screenshots as visual proof.

Implementation verification completed:

- 2026-06-13 Slice 1 route observability:
  `dotnet build Godotwind.sln` passed.
- The gdUnit run included `test_route_usage_stats` with 3 tests, 0 failures.
  That suite exercises
  world-manifest async/sync routes, source-cell async routes, and
  `ReferenceInstantiator` source-vs-normalized entry counters.
- The same gdUnit run still contained unrelated pre-existing failures in
  other unit suites, including `test_adapter_boundary`; do not treat the full
  report as an all-green run.
- 2026-06-13 Slice 2 owner APIs:
  `dotnet build Godotwind.sln` passed.
- The gdUnit run included `test_spring_cleanup_owner_apis` with 3 tests, 0 failures and
  `test_route_usage_stats` with 3 tests, 0 failures. That report still has
  unrelated pre-existing failures in other suites, including adapter-boundary,
  hydrology, subsystem-toggle, water-interaction, and world-source suites.
- Main-scene changed-path smoke launched `scenes/Godotwind.tscn` for 10
  seconds, reached `_ready()` successfully, and was closed manually. This
  exercised the main composition-root startup path touched by the owner-API
  seam.
- 2026-06-13 Slice 3 instantiation result envelope:
  `dotnet build Godotwind.sln` passed.
- Focused gdUnit included `test_route_usage_stats` with 5 tests, 0 failures.
  The new coverage asserts
  the `InstantiationResult` envelope for normalized world-object records and
  guards the source-cell route counter regression.
- Main-scene changed-path smoke launched `scenes/Godotwind.tscn` for 12
  seconds, reached `_ready()` successfully (`_ready() total: 685 ms` in
  `reports/spring_cleanup_slice3_godotwind_smoke.out.log`), and the process was
  closed. This exercised the main-world streaming startup path touched by the
  result-envelope migration.
- No shader cache/import artifacts were cleared because no shader files
  changed.
- 2026-06-14 Slice 8 core strict typing guard:
  `dotnet build Godotwind.sln` passed.
- Focused gdUnit included `test_core_strict_typing_policy` with 3 tests,
  0 failures. The new suite
  asserts the project enables `gdscript/warnings/untyped_declaration=1`, keeps
  core `@warning_ignore("untyped_declaration")` suppressions on an explicit
  ledger, and prevents the new transition provider from drifting back to
  untyped portal-loop variables.
- Focused gdUnit included `test_spring_cleanup_owner_apis` with 7 tests,
  0 failures.
- Changed-path transition smoke launched
  `tests/visual/test_interior_transition.tscn -- --auto-test`, entered and
  exited Arrille's Tradehouse through the normal fade path, and completed
  cleanup without script errors or a crash. The smoke's own frametime verdict
  logged `[FAIL]` on both attempts: first run last transition peak 23.33 ms in
  `reports/spring_cleanup_slice8_interior_transition_smoke.out.log`; rerun last
  transition peak 13.87 ms in
  `reports/spring_cleanup_slice8_interior_transition_smoke_rerun.out.log`.
  This is a verification caveat for the transition performance harness; Slice
  8 changed typing/tooling only. No shader cache/import artifacts were cleared
  because no shader files changed.
- 2026-06-13 Slice 4 Phase F preregistration quarantine:
  `dotnet build Godotwind.sln` passed.
- Focused gdUnit included `test_spring_cleanup_owner_apis` with 4 tests,
  0 failures. The new coverage
  asserts the compatibility preregistration APIs are inert and guards against
  restoring the `--enable-phase-f-prereg` switch or retired worker prereg
  symbols.
- Focused gdUnit included `test_route_usage_stats` with 5 tests, 0 failures.
- Main-scene changed-path smoke launched `scenes/Godotwind.tscn` for 12
  seconds, reached `_ready()` successfully (`_ready() total: 627 ms` in
  `reports/spring_cleanup_slice4_godotwind_smoke.out.log`), and the process was
  closed. This exercised the main-world startup path that still calls the
  compatibility preregistration methods.
- No shader cache/import artifacts were cleared because no shader files
  changed.
- 2026-06-14 Slice 6 HLOD coverage naming:
  `dotnet build Godotwind.sln` passed.
- The gdUnit run included `test_object_paging_kernel` with 75 tests,
  0 failures. The new coverage
  asserts generated HLOD manifests include `source_object_ids` and omit
  `source_ref_nums`.
- The same run included `test_spring_cleanup_owner_apis` with 6 tests, 0
  failures. The new Spring cleanup guard keeps the stale manifest key and
  `set_hlod_covered_ref_nums()` alias from returning to runtime source.
- The same full unit report still contains unrelated pre-existing failures in
  adapter-boundary, hydrology, subsystem-toggle, water-interaction, and
  world-source suites.
- HLOD changed-path smoke launched `tests/visual/test_hlod_benchmark.tscn` for
  25 seconds. The scene loaded ESM, initialized the streaming manager,
  auto-enabled HLOD, logged `[audit HLOD +5s] visual=2 ... merged=2 ...
  refs=385`, and was closed. Logs:
  `reports/spring_cleanup_slice6_hlod_benchmark_smoke.out.log` and
  `reports/spring_cleanup_slice6_hlod_benchmark_smoke.err.log`. The stderr log
  contains expected streaming overrun/autopsy warnings during HLOD startup, not
  script errors.
- No shader cache/import artifacts were cleared because no shader files
  changed.
- 2026-06-14 Slice 7 seamless-interior posture:
  `dotnet build Godotwind.sln` passed.
- Focused gdUnit included `test_spring_cleanup_owner_apis` with 7 tests,
  0 failures. The new coverage
  asserts the main scene no longer exposes the parked seamless-interior
  checkbox or direct `_pocket_manager.seamless_enabled =` UI write.
- Classic transition smoke launched
  `tests/visual/test_interior_transition.tscn -- --auto-test`, entered and
  exited Arrille's Tradehouse through the normal fade path, logged
  `[AUTO-TEST] RESULT: enter+exit complete ... [PASS]`, and exited 0. Logs:
  `reports/spring_cleanup_slice7_interior_transition_smoke.out.log` and
  `reports/spring_cleanup_slice7_interior_transition_smoke.err.log`.
- No shader cache/import artifacts were cleared because no shader files
  changed.

## Cleanup Backlog

### Slice 1: Make legacy vs normalized routes observable

Status: completed 2026-06-13.

Add counters and tests for `CellManager` / `ReferenceInstantiator` route usage.
Goal: know which paths are load-bearing before deleting or moving them.

Expected proof: main-world route stats showing exterior, interior, static, and
interactive load routes; boundary tests reject new generic parser bridges.

### Slice 2: Replace private field reach-through

Status: completed 2026-06-13 for the smallest `world_explorer` /
`NativeStreamingManager` seam.

Add explicit public APIs or constructor/configuration injection for model
loader, static renderer, loaded cell lookup, and debug/HLOD access.

Expected proof: no `._model_loader`, `._static_renderer`, `._loaded_cells`,
or `._instantiator` reads from `world_explorer` or `NativeStreamingManager`
except internal owner methods.

Completed proof: `CellManager` owns static-renderer/model-loader/instantiator
access through named methods; `NativeStreamingManager` configures `CellManager`
through those methods, exposes loaded-cell/debug accessors for the composition
root, and HLOD initialization no longer reaches into `CellManager` private
fields. `world_explorer` uses those owner APIs. The regression guard is
`tests/unit/test_spring_cleanup_owner_apis.gd`.

### Slice 3: Replace `last_*` instantiation side channel

Status: completed 2026-06-13 for the normalized `world_object_record` route.

Introduce an explicit `InstantiationResult` and migrate one route at a time.

Expected proof: one route no longer reads `ReferenceInstantiator.last_*`;
tests cover the result envelope.

Completed proof: `ReferenceInstantiator` now exposes an `InstantiationResult`
envelope and `instantiate_world_object_record_result()`. The `CellManager`
async drain consumes that envelope for `entry.world_object_record` instead of
reading the mutable `last_*` diagnostics for that route. Legacy source-ref,
world-object-id, worker-node, and worker-static routes still use `last_*` and
remain future one-route slices.

### Slice 4: Delete or quarantine Phase F preregistration

Status: completed 2026-06-13.

Remove `--enable-phase-f-prereg` or replace the worker body with data-only work
and main-thread publish.

Expected proof: no worker body calls `PackedScene.instantiate()` or
`register_from_prototype()`.

Completed proof: `ReferenceInstantiator.preregister_cell_statics()` and
`preregister_world_cell_statics()` are compatibility no-ops, and
`drain_prereg_tasks()` is inert because there are no prereg tasks to drain. The
`--enable-phase-f-prereg` command-line switch was removed; the default-disabled
config flag remains only as a compatibility/diagnostic marker. The regression
guard is `tests/unit/test_spring_cleanup_owner_apis.gd`.

### Slice 5: Delete parked PrototypeRegistry path

Status: completed 2026-06-14.

Remove the world-scoped registry branch and debug command after confirming
bench/debug readers do not depend on it.

Expected proof: static bucket visual/benchmark still passes; registry stats
are gone or permanently compatibility-zero.

### Slice 6: Clean HLOD coverage naming

Status: completed 2026-06-14.

Migrate `source_ref_nums` to `source_object_ids` only.

Expected proof: unit test on ObjectPaging manifest shape and FAR/HLOD handoff.

Completed proof: `ObjectPaging` manifests expose only `source_object_ids` for
coverage identity; `NativeStreamingManager` syncs only that manifest key to FAR
impostors; `NativeImpostorRenderer` no longer exposes the stale ref-num alias.
The regression guards are `tests/unit/test_object_paging_kernel.gd` and
`tests/unit/test_spring_cleanup_owner_apis.gd`.

### Slice 7: Decide seamless-interior posture

Status: completed 2026-06-14.

Move seamless toggle/dev UI out of normal main scene controls unless the
feature is being accepted now.

Expected proof: classic interior transition still works; seamless has its own
test matrix if kept.

Completed proof: the normal main-scene escape menu no longer exposes a
"Seamless interior transitions" checkbox or writes directly to
`_pocket_manager.seamless_enabled`. The parked seamless path remains available
only through dedicated visual/lab coverage, such as
`tests/visual/test_interior_transition.gd`'s F5 test-scene toggle.

### Slice 8: Enforce core typing

Status: completed 2026-06-14 with verification caveat on the unrelated
transition smoke frametime gate.

Fix project warning setting or add a static typing audit script for `src/core`.

Expected proof: no new untyped declarations in core outside explicitly allowed
test/tool paths.

Completed proof: `project.godot` now enables the real
`gdscript/warnings/untyped_declaration=1` setting, and
`tests/unit/test_core_strict_typing_policy.gd` ratchets core
`untyped_declaration` suppressions through an explicit debt ledger. The new
Morrowind transition provider portal loops are typed as `Variant`, preserving
the source-adapter boundary while making the strict-typing warning useful.

### Slice 9: Align docs with live distance contract

Status: completed 2026-06-14.

Update `docs/ARCHITECTURE.md` and stale comments that still describe older
300m/500m handoffs or "one RS instance per object" as the current MID path.

Expected proof: docs agree with `distance_rendering.md`,
`distance_utils.gd`, and `STATUS.md`.

Completed proof: `docs/ARCHITECTURE.md`, `docs/systems/lighting.md`,
`docs/systems/streaming_rendering_bible.md`, and current-state comments in
`src/core/world/static_object_renderer.gd`,
`src/core/world/object_paging_kernel.gd`, and
`src/core/world/streaming_config.gd` now describe MID as the 150-400m
`CellStaticBucket` bridge, FAR as the 400-5000m impostor tier capped by view
distance, and HLOD as an optional 400-1000m comparison tier. Verification was
the focused stale-text scan over current docs and world source comments; no
Godot visual smoke was required because runtime behavior did not change. No
shader cache/import artifacts were cleared because no shader files changed.

### Slice 10: Classify sync and parked benchmark modes

Status: completed 2026-06-14.

Make unsupported or non-comparable loading modes visible in benchmark metadata
before deleting sync fallback code.

Expected proof: benchmark/loading metadata explicitly labels sync fallback,
Phase F posture, HLOD, FAR, and near-only modes; stress/benchmark summaries
cannot silently treat sync-mode results as baseline performance.

Completed proof: `NativeStreamingManager.get_benchmark_mode_metadata()` now
returns a `godotwind_benchmark_mode_v1` envelope and `get_stats()` exposes it as
`benchmark_mode_metadata`. The envelope marks `async_loading_enabled=false` and
any executed sync fallback frames as invalid for performance baselines, counts
sync fallback frames/cells, reports Phase F preregistration as quarantined, and
classifies NEAR-only, NEAR+MID-only, FAR-only, HLOD-only, default distant, and
full distant/HLOD modes. Benchmark HUD, `StreamingBenchmark`,
`ProgressiveBenchmark`, `AutoBenchRunner`, `BenchLadderRunner`, and
`StreamingStressRunner` now carry or display that metadata. Stress gates add
`benchmark_invalid:*` failure reasons for unsupported metadata.

Verification: focused gdUnit CLI runs passed for
`test_benchmark_mode_metadata`, `test_streaming_stress_runner_gates`,
`test_auto_bench_runner`, and `test_bench_ladder_runner`. A capped startup
smoke launched `scenes/Godotwind.tscn` with world streaming disabled and
reached `_ready()` / `_init_async()` without script, parse, or compile errors.
No shader/import cache artifacts were cleared because no shader files changed.

## Do Not Touch Yet

- Do not broadly split `world_explorer.gd` just because it is large. It is the
  composition root and dev harness; remove private reach-through first.
- Do not delete legacy `CellReference` routes until route counters prove they
  are not load-bearing.
- Do not re-architect static bucket lifetime. Current RID/resource ownership
  is one of the healthier areas.
- Do not resume seamless portal cleanup unless the feature is explicitly back
  in scope.
- Do not treat HLOD surface/material draw-call reduction as Pillar 1 code
  cleanliness. It belongs primarily to performance Pillar 3, after ownership
  cleanup makes measurement honest.
- Do not genericize Morrowind-specific terrain/hydrology/dialogue details in
  this pillar unless a code-quality cleanup directly requires it. Framework
  boundary is Pillar 2.

## Next Prompt

```text
Continue Spring cleanup. Either take the next small Pillar 1 deletion slice
from bloat control (retired PrototypeRegistry files, Phase F no-op plumbing,
or disabled CellPreloader worker-warm branch), or move to Pillar 2 for the
Morrowind/framework boundary audit now that the explicit Pillar 1 cleanup
backlog is complete.
```
