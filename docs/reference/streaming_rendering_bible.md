# Streaming + Rendering Audit Against The Bible

Date: 2026-05-02
Auditor: codex
Slice: NEAR-tier ownership / threading / benchmarks / preload / distant-tier defaults
Bible: `docs/systems/streaming_rendering_bible.md`

This document refreshes the 2026-05-01 audit against current code. It is an
audit snapshot, not the source of truth. The architecture source of truth
remains `docs/systems/streaming_rendering_bible.md`; shipped-vs-open status
remains `docs/STATUS.md`.

The main correction: the previous report treated Phase 2B as structurally
outstanding. Current code has the Phase 2B bucket ownership and cleanup shape.
Acceptance proof is still separate: the benchmark / stress gates still need a
fresh run before calling Phase 2B accepted in performance terms.

---

## Headline Verdict

**The high-level architecture still matches the bible.** Static visuals route
server-direct, interactives stay sparse `Node3D`, the payload / handle owner
chain exists, thread boundaries remain conservative, static collision follows
the canonical per-cell shape, and `WorkerThreadPool` task ownership remains
explicit.

**Phase 2B is structurally implemented, not yet acceptance-proven.**
`CellStaticBucket` now owns per-cell/payload draw groups, local `MultiMesh`
objects for all groups, single-slot transform uploads for singleton groups, strong
Mesh/Material refs, and the resource handle owner pin. Bucket cleanup now has a `frozen` gate and
`StaticObjectRenderer.remove_cell_instances()` detaches buckets from renderer
indexes before freeing their RIDs.

**`PrototypeRegistry` is parked.** The world-scoped registry path still exists
in source, but `USE_PROTOTYPE_REGISTRY = false` is documented as the safety
gate. The active MID static path is the per-cell `CellStaticBucket` path.

**FAR impostors are no longer parked by default in the current session.**
`world_explorer.gd` initializes `impostors`, `mid_objects`, and `near_objects`
to `true`, logs distant tiers active, and keeps `--near-only` as an explicit
focused-test override that disables HLOD / impostors. HLOD remains implemented
but opt-in after the 2026-05-02 default-on stress run exposed a persistent
chunk-surface draw-call blow-up.

**Benchmarks are stronger than the stale audit said, but proof still needs a
run.** `tests/benchmark/benchmark_thresholds.gd` now carries bible-aligned
constants: 6.67ms frame target, 1.0ms streaming publish target, 3.5ms render
budget, and 50ms blocking-frame failure. `streaming_stress_runner.gd` imports
those constants and fails summaries for blocking frames / publish spikes. That
is materially better than "loggers only." It does not replace a fresh
dense/east/reclaim run with collision and log scan.

---

## Bible Rule -> Score Matrix

PASS = current code matches the bible. RISK = matches but fragile or gated.
GAP = missing proof or missing follow-through. VIOLATION = breaks the rule.

### Accepted Claims

| Bible claim | Verdict | Evidence |
|---|---|---|
| `StreamedResourceHandle` exists and pins resources | PASS | `src/core/streaming/streamed_resource_handle.gd` owns extracted meshes/materials and owner refs |
| `CellPayload` owns model callbacks, prepare entries, handles, collision state | PASS | `src/core/world/cell_payload.gd` still carries those inventories and publishes static buckets |
| Completed cell nodes receive handles in metadata | PASS | `CellPayload.bind_resource_handles_to_node()` keeps handles attached to completed nodes |
| Phase 2A routed heavy static refs out of scene children | PASS | Still true, but superseded by Phase 2B bucket ownership |
| Phase 2B bucket ownership | PASS structurally | `cell_static_bucket.gd` owns draw groups, local MultiMeshes, RS instance RIDs, strong resource refs, and handle owner pins |
| Phase 2B frozen cleanup | PASS structurally | `CellStaticBucket.frozen`, `freeze()`, `cleanup()`; renderer detaches buckets before cleanup |
| P0.4 unload-limbo reclaim path | PASS | `_unloading_cells` / `_unloading_request_ids` remain in `native_streaming_manager.gd` |
| `StaticShapeCache` sidecar loading is single-flight | PASS | Existing mutex-protected pack-load path remains the intended shape |
| `PHASE_A_OFFTHREAD_INSTANTIATE = false` | PASS | Scene instantiation remains main-thread gated |
| `StaticObjectRenderer.USE_PROTOTYPE_REGISTRY = false` | PASS | Parked legacy path, documented as world-scoped and unsafe to re-enable unchanged |
| `StreamingConfig.STATIC_CULL_NATIVE_ENABLED = false` | PASS | Native static cull remains disabled |
| `StreamingConfig.DEBUG_DISABLE_PHASE_F_PREREG = true` | PASS | Off-thread prototype prereg remains opt-in research |
| FAR impostors default active in main scene | PASS current session | `world_explorer.gd` default toggles set `impostors=true`; `--near-only` parks HLOD/impostors explicitly |

### Former "Outstanding" Items

| Former item | Current verdict | Evidence / note |
|---|---|---|
| Phase 2B material/RID lifetime + bucket cleanup | PASS structurally, GAP proof | Bucket owns strong refs and frees RIDs before dropping refs. Needs stress proof. |
| Per-cell/per-area MultiMesh buckets vs RS-instance-per-transform | PASS structurally | `CellStaticBucket` creates local `MultiMesh` objects for draw groups; singleton groups use `set_instance_transform()` instead of a bulk buffer upload. |
| `_mesh_types` must stop being hidden lifetime owner | PASS structurally | `_mesh_types` supplies immutable prototypes; bucket pins Mesh/Material refs and resource handle ownership. |
| Bucket detach-before-free cleanup | PASS structurally | `remove_cell_instances()` calls `_detach_cell_buckets()` before `_cleanup_detached_buckets()`. |
| Frame budget split for 150 FPS | PARTIAL | Benchmark constants now express 6.67ms / 1ms / 3.5ms targets, but runtime publish budgets still include transitional 8ms/4ms values. |
| East-route 50ms+ outlier attribution | GAP | Requires fresh benchmark run and log alignment. |
| HLOD/FAR re-enable parked | UPDATED | FAR impostors are default-on; HLOD is implemented but opt-in pending chunk-surface proof. |

---

## Phase 2B Bucket Contract

Current code now matches the structural contract the stale audit called missing:

- `CellStaticBucket.configure()` receives the resource handle and calls
  `add_owner("bucket:<cell,payload>")`.
- It pins Mesh, Material, and surface material refs in `_resource_refs`.
- It uses local `MultiMesh` objects for draw groups; singleton groups use the single-slot transform API.
- It stores all live draw state in `DrawGroup` records owned by the bucket.
- `set_visible()` bails when `frozen` is true.
- `cleanup()` freezes, frees RS instance RIDs, drops local MultiMesh/resource
  refs, removes the handle owner pin, and clears bucket state.
- `StaticObjectRenderer` indexes buckets by cell and bucket key, and
  `_detach_cell_buckets()` removes them from renderer discovery structures
  before cleanup.

What this proves: the lifecycle shape is no longer the Phase 2A transitional
shape.

What this does not prove: that every changed-path stress route stays under
budget, that no `material_set_shader` / RID ordering regression remains, or
that HLOD default-on boot is performance-clean. Those require execution.

---

## Primary-Source Facts Applied To Current Code

| Bible rule | Verdict | Evidence |
|---|---|---|
| Server RIDs do not own resources; strong refs required | PASS | Bucket `DrawGroup` and `_resource_refs`; `StreamedResourceHandle`; static collision shape refs |
| Scene tree is main-thread-owned | PASS | Off-thread instantiation paths remain disabled/gated |
| Server publication stays main-thread unless project settings prove otherwise | PASS | Active static visual publication happens through main-thread renderer code |
| `WorkerThreadPool` tasks must be awaited | PASS/RISK | Existing tracked-task pattern remains; impostor texture-array rebuild lifecycle should still be included in the next stress run review |
| `ResourceLoader` is transport, not lifetime owner | PASS | Handles and buckets own/pin lifetime |
| MultiMesh must be spatially local | PASS active path, RISK parked code | Active `CellStaticBucket` path is cell-local; `PrototypeRegistry` remains world-scoped and parked |
| Visibility ranges per `GeometryInstance3D`, not per MultiMesh slot | PASS | Bucket RS instances set visibility range; per-slot fading remains shader-domain if needed |
| Off-thread `PackedScene.instantiate` not accepted | PASS | Phase A/F gates remain off by default |
| Cleanup order removes from discovery before freeing | PASS structurally | `_detach_cell_buckets()` erases cell/key indexes and freezes before `_cleanup_detached_buckets()` frees |

---

## Benchmark / Proof Status

The stale report said benchmarks were "loggers" and `benchmark_thresholds.gd`
was unused 60-FPS-era data. That is no longer accurate.

Current benchmark state:

| Gate area | Current status |
|---|---|
| Shared threshold constants | PASS: `BenchmarkThresholds` defines 6.67ms frame, 1.0ms publish, 3.5ms render, 50ms blocking |
| Stress runner imports thresholds | PASS: `streaming_stress_runner.gd` preloads `benchmark_thresholds.gd` |
| Blocking frame failure | PASS structurally: stress summary checks `max_frame_ms >= BLOCKING_FRAME_MS` |
| Publish spike failure | PASS structurally: stress gate checks streaming publish blocking threshold |
| Static publish spike visibility | PASS structurally: threshold exists and unit tests cover gate constants |
| Dense/east/reclaim with collision | GAP until run |
| Material/RID iteration-order stress | GAP until run/log scan |
| No `material_set_shader` errors | GAP until run/log scan |
| No stale bucket discovery after detach | GAP until run/log scan |
| No collision finalize errors | GAP until run/log scan |
| Changed-path p99/max-frame under budget | GAP until run |

Recommended acceptance language: "Phase 2B is structurally present" is fair.
"Phase 2B accepted" is not fair until the bible gates run clean.

---

## Distant Rendering Defaults

The previous audit and some older docs describe HLOD / FAR as parked while
NEAR stabilizes. Current main-scene code has moved past that for FAR impostors:

- `world_explorer.gd` builds `SubsystemToggles` with `impostors=true`,
  `mid_objects=true`, `near_objects=true`, and `hlod=false`.
- It logs distant tiers active and uses the default fallback ranges: MID
  0-500m, impostors 500m+.
- `hlod_enable` starts HLOD work at 300m. MID remains the 0-500m safety
  fallback, but buckets with complete HLOD coverage cap at 300m; impostors stay
  available from 500m until exact HLOD coverage ownership exists.
- `--near-only` remains as the explicit focused-testing override; it disables
  HLOD / impostors and restores MID fallback behavior.
- Console controls `hlod_enable`, `hlod_disable`, and `hlod_stats` remain.

Audit status: FAR is structurally re-enabled by default. HLOD is structurally
implemented but not default-on until its chunk-surface draw-call issue is fixed.

---

## Cell Preload Pattern Gaps

These findings remain useful from the stale audit:

| Bible item | Status |
|---|---|
| `CellPreloader` exists | PASS |
| Predict from velocity + prediction time | PASS |
| Preload outer grid around predicted position | PARTIAL: warm cache is velocity-aware; main load priority still needs verification for direction bias |
| Door/teleport destination pre-warm | NOT IMPLEMENTED / not proven |
| Bounded cache: max + min + expiry | PASS |
| Update timestamps on reuse | PASS |
| Abort work on load/clear/expiry | PASS |
| Fast teleports abort + reseed | PASS abort, PARTIAL destination pre-warm |

---

## Anti-Patterns Still Worth Watching

| Anti-pattern | Verdict | Note |
|---|---|---|
| Re-enable `PrototypeRegistry` unchanged | RISK | Source still exists and is world-scoped. Keep parked unless rewritten spatially local. |
| Permanent diagnostic defers / debug disables | RISK | Existing flags remain; they should keep explicit owner/expiry/follow-up notes when touched. |
| HLOD default-on without proof | GAP | HLOD is structurally wired but not default-on; acceptance requires chunk-surface reduction plus benchmark verification. |
| Runtime publish budget still 8ms/4ms in places | PARTIAL | Benchmark targets are stronger; runtime budget split still needs follow-through. |
| Raw logging / expected-condition warnings in hot code | LOW RISK | Not re-audited in this refresh; previous minor cleanup recommendations can stand if still present. |

---

## Recommended Action List

1. Run the Phase 2B acceptance gates: dense, east, and reclaim/boomerang routes
   with collision enabled.
2. Scan the run logs for `material_set_shader`, stale bucket discovery,
   collision finalize errors, and 50ms+ changed-path outliers.
3. Record p99/max frame results against `BenchmarkThresholds` and attach the
   generated JSON/CSV path in the acceptance note.
4. Interactively launch `scenes/Godotwind.tscn` with default FAR impostors on
   and visually check MID->FAR transitions; separately run `hlod_enable` to
   verify MID->HLOD->FAR once the draw-call issue is fixed.
5. Keep `PrototypeRegistry` parked unless it is replaced with a spatially local
   design.
6. Split runtime streaming publish budgets toward the bible's 1ms lane target;
   keep the current 8ms/4ms values described as transitional until changed.
7. Update older status docs that still say FAR is parked. Keep HLOD described
   as opt-in until its default-on run is accepted.

---

## What This Audit Is Not Saying

- It is not claiming Phase 2B performance acceptance. It is claiming the code
  now has the structural bucket ownership and cleanup shape.
- It is not recommending `PrototypeRegistry` re-enable. The active path is
  `CellStaticBucket`; the registry remains parked.
- It is not treating stronger threshold constants as benchmark proof. A gate
  only proves something after it runs.
- It is not treating FAR-impostor default-on wiring or HLOD opt-in wiring as
  visual/performance acceptance.

---

## Confidence

- Phase 2B structural status: HIGH. Read `cell_static_bucket.gd` and
  `static_object_renderer.gd` bucket creation / detach / cleanup paths.
- Distant-tier default status: HIGH. Read `world_explorer.gd` toggle defaults
  and `--near-only` override.
- Benchmark threshold status: HIGH. Read `benchmark_thresholds.gd`,
  `streaming_stress_runner.gd`, and unit references.
- Benchmark proof status: HIGH that proof is missing in this refresh. I did not
  run Godot or the stress routes for a documentation-only audit update.
- Cell preload details: MEDIUM. Preserved prior findings where still plausible;
  not re-audited end-to-end in this refresh.

End of report.
