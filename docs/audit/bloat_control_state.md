# Bloat Control State

Last updated: 2026-06-17

Purpose: durable state for Godotwind LOC, dead-code, generated-artifact,
side-project, and cleanup-scaffolding control. When the user says "Check for
bloat", read this file and use `.agents/skills/bloat-control/SKILL.md`.

## How To Resume

Use the repo-local skill:

- `.agents/skills/bloat-control/SKILL.md`

Run:

```powershell
python .agents/skills/bloat-control/scripts/bloat_scan.py --root .
```

Then classify findings into keep/delete/defer decisions.

## Current Context

- Spring cleanup Pillar 1 has implemented slices 1-10. Slice 10 classified
  synchronous/parked benchmark modes so sync fallback can no longer silently
  pollute performance results.
- The user is concerned that LLM cleanup can add too many lines, tests,
  counters, wrappers, side projects, and reports.
- Bloat control should run after Slice 9 as a Pillar 1 closing gate before
  moving to framework-boundary Pillar 2.

## 2026-06-14 Bloat Check

Command run:

```powershell
python .agents/skills/bloat-control/scripts/bloat_scan.py --root .
```

Scan summary:

| Category | Files | Lines |
|---|---:|---:|
| `src-core` | 613 | 110311 |
| `src-morrowind-adapter` | 57 | 8387 |
| `src-native` | 34 | 11546 |
| `src-tools` | 148 | 36663 |
| `tests-unit` | 80 | 8966 |
| `tests-visual` | 206 | 30209 |
| `docs-audit` | 18 | 6076 |
| `docs-archive` | 47 | 27957 |
| `generated` | 453 | 8676 |
| `agent-skills` | 17 | 11087 |

Worktree shape:

- Total diff shortstat was 471 files changed, +1969/-149056.
- Real source/docs/test tracked delta excluding `reports/` was 41 files,
  +1969/-1208.
- Generated report churn dominated the deletion count: `reports/` alone was
  430 tracked files and 147848 deleted lines.
- Before cleanup, `reports/` was not ignored. Tracked reports were
  `report_367` through `report_386`; `report_367` through `report_380` were
  already deleted in the worktree, while `report_387` through `report_400`
  were untracked.
- Existing audit docs referenced some untracked evidence reports
  (`report_390`, `report_392`, `report_394` through `report_400`) and also
  referenced `reports/report_1/results.xml`, which was absent. The live Spring
  cleanup state and Pillar 1 audit now summarize the gdUnit proof instead of
  depending on numbered report directories.

Top current production/test hotspots:

- `src/core/world/cell_manager.gd`: 4850 lines. Still the central route
  migration knot; do not split blindly, continue route-by-route normalization.
- `src/tools/world_explorer.gd`: 4456 lines. Large but valid composition root;
  avoid broad splitting until private reach-through in helper tools is gone.
- `src/core/world/native_streaming_manager.gd`: valid frame orchestrator.
  Sync/parked benchmark mode classification is now complete; remaining cleanup
  is deletion of proven-dead compatibility paths, not more metadata.
- `src/native/NativeMorrowindHydrologyAtlasBuilder.cs`: 1223 new/native lines.
  Keep for now because it is adapter-owned, used through `NativeFactory` /
  `NativeBridge`, and covered by hydrology unit/visual paths; rent due is a
  performance and maintainability proof after the hydrology atlas behavior
  settles.
- `tests/visual/test_interior_transition.gd`: largest tracked active test diff
  at +459/-91. Keep only if it remains the narrow transition smoke/lab owner;
  avoid folding unrelated water/render-layer experiments into it.

Keep/delete/defer decisions:

- Keep permanently: `src/core/world/transition/*` generic transition contract.
  It is small, source-neutral, and used by `MorrowindTransitionProvider`,
  `InteriorPocketManager`, and transition tests.
- Keep permanently: `src/core/world/render_layers.gd`. It is tiny, removes
  duplicated cull-mask bit math, and is covered by `tests/unit/test_render_layers.gd`.
- Keep temporarily: route usage counters and
  `tests/unit/test_route_usage_stats.gd`. Delete condition: legacy
  `CellReference`/source-cell routes are migrated or explicitly accepted.
- Keep temporarily: `ReferenceInstantiator.preregister_*` no-op compatibility
  APIs and their guard tests. Delete condition: no remaining callers in
  `CellManager` / `CellPreloader` / archived docs that could re-enable Phase F.
- Deleted: `registry_batches` / `registry_slots` compatibility-zero stats.
  Benchmark readers and helper tests now use live HLOD/FAR/static-bucket
  metrics and benchmark mode metadata instead of the dead PrototypeRegistry
  counters.
- Defer: synchronous loading fallback and `async_loading_enabled=false`.
  Slice 10 now labels benchmark output invalid/unsupported for sync mode; any
  deletion still needs a product/debug-role decision.
- Deleted/ignored: generated `reports/report_*` HTML/XML directories. Keep
  only deliberate evidence artifacts, preferably summarized in audit docs with
  a stable log/result path; otherwise leave numbered report directories
  untracked.
- Fixed evidence rot: the live Spring cleanup state and Pillar 1 audit no
  longer claim `reports/report_1/results.xml` exists.
- Defer: `CellPreloader.WORKER_RESOURCE_WARM_ENABLED=false` worker-warm code.
  Needs route/caller proof before deletion.
- Defer: remaining `._loaded_cells` and `._static_renderer` reads in
  `src/tools/lod_debug_commands.gd`. They are helper-tool reach-through, not
  default runtime, but should move to `NativeStreamingManager` debug APIs.

Reports cleanup completed 2026-06-14:

1. Added `.gitignore` rule: `reports/report_*/`.
2. Deleted generated numbered report directories present on disk:
   `report_381` through `report_400`.
3. Preserved named smoke logs under `reports/` because current audit docs cite
   them as deliberate evidence.
4. Left older historical audit references to `report_235` / `report_236`
   untouched; they are past-session provenance, not current proof targets.

Runtime-only dead-code candidate pass 2026-06-14:

Commands run:

```powershell
python .agents/skills/bloat-control/scripts/bloat_scan.py --root .
rg -n "preregister|Phase F|DEBUG_DISABLE_PHASE_F_PREREG|enable-phase-f-prereg|drain_prereg" src/core src/native src/tools tests docs/audit
rg -n "WORKER_RESOURCE_WARM_ENABLED|worker warm|warm_resource|request_model_async" src/core src/native
rg -n "prototype_registry\.gd|prototype_batch\.gd|PrototypeBatchScript|PrototypeRegistryScript|_prototype_registry|get_prototype_registry_distribution|registry_batches|registry_slots" src/core src/native src/tools tests
rg -n "async_loading_enabled|_process_pending_loads_sync|sync load|synchronous" src/core src/native src/tools tests docs/audit
rg -n "seamless_enabled|seamless|portal|_update_seamless|clip|building" src/core/world/interior_pocket_manager.gd src/core/world src/tools tests/unit tests/visual docs/audit
```

Ranked runtime candidates:

1. Delete next: `src/core/world/prototype_registry.gd` and
   `src/core/world/prototype_batch.gd`. Production `StaticObjectRenderer`
   no longer preloads or owns them, and remaining live references are the old
   unit test plus broken/debug-tool reach-throughs to `_prototype_registry`.
   Required cleanup: delete `tests/unit/test_prototype_registry.gd`, update or
   delete registry-specific debug-tool branches, and remove stale shader/comment
   references to `PrototypeRegistry`.
2. Delete next: Phase F preregistration no-op plumbing. The runtime still calls
   `ReferenceInstantiator.preregister_cell_statics()`,
   `preregister_world_cell_statics()`, and `drain_prereg_tasks()`, but those
   methods now return 0/pass. Remove the no-op methods, the `CellManager`
   calls, `StreamingConfig.DEBUG_DISABLE_PHASE_F_PREREG`, and stale Phase F
   comments after updating the Spring cleanup guard test.
3. Delete next: `CellPreloader.WORKER_RESOURCE_WARM_ENABLED`,
   `_worker_warm_resource()`, and `PreloadEntry.task_ids`. The constant is
   permanently false and the active canonical path is
   `ModelLoader.request_model_async()`. Keep `pending_model_paths`; remove the
   worker-task polling branch.
4. Completed: zero-valued `registry_batches` / `registry_slots` runtime stats,
   benchmark reader fields, helper-test expectations, and the matching
   `NativeStreamingManager` heartbeat reads were deleted once they were proven
   to describe no active renderer path.
5. Defer with product decision: default-disabled seamless interior portal
   surgery in `InteriorPocketManager` plus `door_clip.gdshader`. Normal main
   scene controls no longer expose it, but the dedicated visual lab still
   toggles it. This is parked runtime feature code, not proven delete-safe
   without deciding whether seamless portals are future product work.
6. Defer: synchronous cell-loading fallback
   `NativeStreamingManager.async_loading_enabled=false` and
   `_process_pending_loads_sync()`. It is not the production path and is now
   labeled unsupported/invalid in benchmark metadata, but deletion still needs
   a product/debug-role decision.
7. Defer: `HorizonMapManager` parked horizon-map APIs. `set_enabled()` and
   `update_sun_direction()` are no-ops, but the manager still applies terrain
   shader/wet fallback plumbing and is instantiated by `world_explorer`.

Verification note: no runtime files were changed in this pass, so no Godot
visual smoke or shader cache clearing was required.

Runtime dead-code deletion completed 2026-06-14:

Proof agents checked the runtime candidates before deletion:

- `PrototypeRegistry` / `PrototypeBatch`: proven dead. Deleted
  `src/core/world/prototype_registry.gd`,
  `src/core/world/prototype_batch.gd`,
  `src/core/world/shaders/lod_crossfade_multimesh.gdshader`,
  `src/native/WorldMidCuller.cs`, their `.uid` files, the obsolete unit test,
  stale native bridge/factory hooks, debug reach-through branches, and dead
  streaming config constants.
- Phase F preregistration: proven dead. Removed the no-op
  `ReferenceInstantiator.preregister_*` / `drain_prereg_tasks()` methods,
  `CellManager` callers, `StreamingConfig.DEBUG_DISABLE_PHASE_F_PREREG`, the
  world-explorer command-line toggle, and Phase F benchmark metadata.
- `CellPreloader` worker-warm branch: proven dead. Removed
  `WORKER_RESOURCE_WARM_ENABLED`, `_worker_warm_resource()`, `PreloadEntry`
  task/cancel bookkeeping, and worker-task polling. The preloader now stays on
  the canonical `ModelLoader.request_model_async()` lane.
- `registry_batches` / `registry_slots`: proven dead after benchmark reader
  cleanup. Removed the compatibility-zero fields from
  `StaticObjectRenderer.get_stats()`, removed heartbeat logging reads from
  `NativeStreamingManager`, removed auto-bench and bench-ladder sample/summary
  fields, and changed the Spring cleanup guard to assert the fields stay
  absent.

Verification:

- `dotnet build Godotwind.sln` passed with 0 warnings and 0 errors.
- Full gdUnit unit-directory run executed 368 tests. The touched suites passed:
  `test_spring_cleanup_owner_apis.gd`, `test_static_object_renderer_bwide.gd`,
  `test_streaming_modular_boundaries.gd`, `test_benchmark_mode_metadata.gd`,
  `test_auto_bench_runner.gd`, and `test_bench_ladder_runner.gd`. The full
  repo still reported pre-existing unrelated failures: 6 errors, 38 failures,
  and 24 orphans in adapter-boundary, hydrology, spawn adapter, subsystem
  toggle, water ripple shader contract, and world-source boundary tests.
- `tests/visual/test_hlod_benchmark.tscn` launched for 25 seconds with HLOD
  auto-enabled and benchmark recording started. It loaded the Morrowind cache,
  initialized streaming/HLOD, showed `reg_batches=0 reg_slots=0`, and had no
  `ERROR`, `SCRIPT ERROR`, or `FATAL` log lines. The warnings were existing
  frame-overrun profiler/autopsy logs during HLOD warmup.
- Shader cache/import artifacts were not cleared. The only shader touched was
  a deleted, orphaned shader, and no active shader was modified.

Registry stats compatibility cleanup completed 2026-06-14:

- Removed the dead PrototypeRegistry stat fields from runtime and benchmark
  output: `registry_batches`, `registry_slots`, and their `*_max` summary
  derivatives.
- Cleaned stale debug-tool wording in `src/tools/mid_tier_debugger.gd` and
  `src/tools/lod_debug_commands.gd`; the tools now describe the live
  CellStaticBucket/direct-RS fallback shape instead of the retired registry
  path.
- Updated `tests/unit/test_auto_bench_runner.gd` and
  `tests/unit/test_bench_ladder_runner.gd` so their samples and assertions no
  longer depend on retired PrototypeRegistry stats.
- Updated `tests/unit/test_spring_cleanup_owner_apis.gd` so
  `StaticObjectRenderer.get_stats()` must not reintroduce the dead fields.

Verification:

- `test_benchmark_mode_metadata.gd` passed via focused gdUnit launch.
- `test_auto_bench_runner.gd` passed via focused gdUnit launch.
- `test_bench_ladder_runner.gd` passed via focused gdUnit launch.
- `test_spring_cleanup_owner_apis.gd` passed via focused gdUnit launch.
- Short HLOD benchmark smoke launched
  `tests/visual/test_hlod_benchmark.tscn` for 25 seconds, auto-enabled HLOD,
  started benchmark recording, and logged heartbeat lines without the retired
  registry fields. Logs:
  `reports/bloat_registry_stats_hlod_smoke.out.log` and
  `reports/bloat_registry_stats_hlod_smoke.err.log`. Stderr contained existing
  frame-overrun/autopsy warnings during HLOD warmup, not script/parse/fatal
  errors.
- Shader cache/import artifacts were not cleared because no shader files were
  changed.

Pillar 2 boundary-ratchet cleanup completed 2026-06-14:

- Encoded the already-classified broad-ratchet false positives in
  `tests/unit/test_adapter_boundary.gd` instead of leaving renderer/doc/shader
  substring noise mixed with real framework leaks.
- Kept the exact world-runtime debt ledger strict: reduced
  `InteriorPocketManager` and `ReferenceInstantiator` marker allowances only
  where the current code already removed debt.
- Kept the real `src/core/native_bridge.gd` source-specific native bridge leak
  red for a future ownership slice instead of hiding it under a new allowance.
- Verification: focused gdUnit `reports/report_15` ran 27 tests with one
  intentional remaining failure in `test_adapter_boundary`; fake-source world
  proof and streaming modular boundary suites passed.

No runtime files changed in this pass, so no Godot visual smoke was required.
Shader cache/import artifacts were not cleared because no shader files changed.

Pillar 2 native bridge ownership cleanup completed 2026-06-14:

- `src/core/native_bridge.gd` was reduced to source-neutral C# availability and
  generic factory helpers.
- Added owned wrappers for source-specific native methods:
  `src/core/nif/native_nif_bridge.gd`,
  `src/core/esm/native_esm_bridge.gd`, and
  `src/core/world/morrowind/morrowind_native_bridge.gd`.
- Updated `NIFConverter`, `ESMManager`, Morrowind hydrology tooling/tests, and
  `ObjectPagingKernel` to use the owned wrapper/public factory APIs.
- Lowered the `NativeBridge` boundary ledger to zero only after the source
  terms moved out of generic core.

Verification:

- `reports/report_17`: 88 focused gdUnit tests, 0 failures.
- Temporary native bridge probe exited 0 for generic, NIF, ESM, and Morrowind
  hydrology native services.
- 45-second HLOD benchmark smoke reached HLOD enabled + benchmark recording and
  logged HLOD audit progress without script/parse/compile/fatal errors. Existing
  frame-overrun/autopsy warnings remained.
- No C# files changed; no shader/import cache clearing was required.

Next deletion slice:

Pillar 2 parser-cell bridge quarantine completed 2026-06-14:

- The remaining parser-shaped `CellRecord` cell fallback in `CellManager` is
  now behind an injected parser-cell bridge instead of direct
  `WorldObjectSource.get_source_cell` / `get_source_exterior_cell` calls.
- `MorrowindWorldSource` owns the bridge implementation; generic source
  injection carries it through `set_world_source()`.
- This is a quarantine, not permanent architecture. The rent due is deletion
  or conversion of the remaining `CellReference` parser tail route-by-route.

Verification:

- `reports/report_20`: 32 focused boundary/route tests, 0 failures.
- `tests/visual/test_interior_transition.tscn -- --auto-test` launched twice
  and exited 0; captured stdout/stderr logs were empty.
- No C# files or shader files changed.

Next deletion slice:

1. Decide the sync fallback's debug/product role before any deletion.
2. Decide whether seamless interior portals are future product work or parked
   runtime bloat.
3. Continue Pillar 2 parser-tail cleanup only route-by-route, starting with
   `ReferenceInstantiator.instantiate_reference()` routes that can move to
   `WorldObjectRecord` plus spawn-adapter payload.

Pillar 2 source-reference result-envelope cleanup completed 2026-06-14:

- Added `ReferenceInstantiator.instantiate_source_reference_result()` so the
  remaining legacy source-ref path can report through the same
  `InstantiationResult` shape as normalized `WorldObjectRecord` spawning.
- Updated `CellManager.process_async_instantiation()` to consume that envelope
  for route, type, timing, static-data, and proximity-deferred diagnostics
  before falling back to old mutable `last_*` diagnostics.
- Added focused route coverage for the new envelope.
- Rent test: kept as a small temporary migration aid because it removes one
  shared mutable side-channel from the parser tail without increasing
  production `CellReference` marker debt. It should disappear once the affected
  legacy route is converted to `WorldObjectRecord` plus adapter payload.

Verification:

- `reports/report_23`: 33 focused Pillar 2 tests, 0 failures.
- `tests/visual/test_interior_transition.tscn -- --auto-test` exited 0 with
  empty captured stdout/stderr.
- Post-edit bloat scan: `src-core` 609 files / 108734 lines; `tests-unit`
  80 files / 8876 lines. The broader dirty worktree remained 658 changed files
  with +2388/-199963, dominated by prior report cleanup and earlier slices.
- No C# files or shader files changed.

Next deletion slice:

1. Convert one legacy async source-ref queue case into `WorldObjectRecord` plus
   adapter-owned spawn payload.
2. Use route counters to prove `source_reference_calls` drops for that case.
3. Only then lower `CellReference` ledgers or delete a parser-tail branch.

Pillar 2 no-model source-ref record cleanup completed 2026-06-14:

- Added a temporary
  `WorldObjectSpawnAdapter.make_world_object_record_from_source_reference()`
  port so parser-shaped legacy refs can be converted by the source adapter
  instead of by generic queue-drain code.
- `MorrowindObjectSpawnAdapter` now owns a source-reference payload cache for
  records produced by that bridge. The cache lets the adapter recover the
  original ref/base-record details while `CellManager` queues a
  `WorldObjectRecord`.
- `CellManager` now uses this bridge for legacy no-model source refs. That
  case moves from raw `CellReference` instantiation to
  `WorldObjectRecord`/spawn-adapter instantiation.
- Rent test: this is temporary migration scaffolding. It is justified because
  it removes one raw parser-tail queue case without deleting load-bearing
  legacy routes or lowering debt ledgers prematurely. Delete condition: all
  remaining legacy source-ref paths are converted to normalized records or the
  parser-cell bridge is removed.

Verification:

- `reports/report_29`: 19 focused tests, 0 failures / 0 errors across route
  usage, adapter boundary, and streaming modular boundary suites.
- `reports/report_31`: new Morrowind adapter payload-cache test passed, but
  the broader suite still has a separate fake-record carryable-registry error.
- Interior transition changed-path smoke exited 0 with empty captured log at
  `reports/spring_cleanup_pillar2_source_ref_record_smoke.log`.
- Post-edit bloat scan: `src-core` 609 files / 108765 lines;
  `src-morrowind-adapter` 58 files / 8613 lines; `tests-unit` 80 files /
  9005 lines. The worktree remains broadly dirty with generated report
  deletions and prior Spring cleanup slices.

Next deletion slice:

1. Convert model-backed delayed source-ref queueing in `references_to_process`
   and model-load callbacks to adapter-owned `WorldObjectRecord` payloads.
2. Then use route counters to confirm `source_reference_calls` drops for that
   delayed path before lowering any parser-tail ledger.

Pillar 2 parser-tail cleanup continued 2026-06-15:

- Model-backed delayed source refs now carry adapter-owned
  `WorldObjectRecord` payloads through both disk-cache model callbacks and
  `_queue_references_for_model()` before queueing instantiation.
- Synchronous parser-cell loops in `_instantiate_cell()`,
  `load_characters_into_cell()`, and the MultiMesh fallback now instantiate
  through adapter-owned records instead of raw `CellReference` calls.
- The final `CellManager` async queue fallback was converted too: ref-only
  queue entries now resolve through `WorldObjectSpawnAdapter` into a
  `WorldObjectRecord` and publish through
  `instantiate_world_object_record_result()`.
- Static scan now finds no `instantiate_source_reference_result()` or
  `instantiate_reference()` call sites in `src/core/world/cell_manager.gd`.
  Remaining matches are the quarantined legacy API in
  `ReferenceInstantiator` and direct unit tests.
- Rent test: this keeps the temporary spawn-adapter wrapping bridge justified
  because it removes the last known `CellManager` dependency on raw
  source-reference instantiation. Delete condition is now narrower: decide the
  remaining `ReferenceInstantiator.instantiate_reference()` ownership and move
  or delete it once no runtime owner needs it.

Verification:

- Focused gdUnit for the async queue fallback slice exited 0 for
  `test_route_usage_stats`, `test_adapter_boundary`, and
  `test_streaming_modular_boundaries`.
- Interior transition changed-path smoke command exited 0 with empty capture
  log at `reports/spring_cleanup_pillar2_queue_fallback_smoke.log`; a leftover
  Godot process was closed manually afterward.
- Post-edit bloat scan: `src-core` 609 files / 108888 lines;
  `tests-unit` 80 files / 9080 lines; `docs-audit` 19 files / 7395 lines.
  The worktree remains broadly dirty with generated report deletions and prior
  Spring cleanup slices.
- No C# files or shader files changed.

Next deletion slice:

1. Audit remaining parser-tail ownership outside `CellManager`, starting with
   `ReferenceInstantiator.instantiate_reference()` and helper paths typed on
   `CellReference`.
2. Decide whether the legacy source-ref API should move behind Morrowind
   adapter ownership or be deleted after route proof.
3. Do not lower parser-tail ledgers until route counters, focused boundary
   tests, and a narrow runtime smoke prove the affected route is not
   load-bearing.

Pillar 2 legacy source-ref API deletion completed 2026-06-15:

- Deleted the unused public `ReferenceInstantiator.instantiate_reference()` and
  `instantiate_source_reference_result()` entry points after static scan and
  route tests proved `CellManager` no longer calls them.
- Deleted the unreachable private sync parser-reference chain:
  `_instantiate_resolved_reference()`, `_instantiate_model_object()`, and
  `_instantiate_static_object()`.
- Removed the `source_reference_calls` route counter; route tests now guard
  that the old public methods/counter stay absent.
- Lowered exact boundary ledgers for current debt:
  `CellManager` `CellReference` 21 -> 20 and `ReferenceInstantiator`
  `CellReference` 20 -> 15.
- Fixed the normalized Morrowind light route to bypass proximity deferral when
  static-renderer/proximity deferral is disabled, preventing interior pocket
  loads from getting stuck on deferred small lights.

Verification:

- Focused gdUnit `reports/report_45`: 21 tests, 0 failures across route usage,
  adapter boundary, and streaming modular boundary suites.
- `reports/report_43` proves the new Morrowind light-deferral regression test
  passed, though the broader spawn-adapter suite still has the known unrelated
  fake-record carryable-registry error.
- Interior transition smoke completed enter+exit cleanup after the light-gate
  fix; log:
  `reports/spring_cleanup_pillar2_legacy_ref_api_deleted_smoke_fixed.log`.
  It still logged the existing transition frametime `[FAIL]` verdict, so this
  is functional/crash proof rather than a performance pass.
- Post-edit bloat scan: `src-core` 609 files / 108565 lines, `tests-unit`
  80 files / 9093 lines, `docs-audit` 19 files / 7511 lines.
- No C# files or shader files changed.

Next deletion slice:

1. Continue Pillar 2 by moving or shrinking the remaining
   `ReferenceInstantiator` source-helper methods typed on `CellReference`.
2. Keep the parser-cell bridge temporary until no runtime route needs
   parser-shaped cell records.
3. Do not treat the transition smoke frametime verdict as a performance pass;
   use it only as functional/crash evidence for this cleanup slice.

Pillar 2 record-based visual-proxy identity cleanup completed 2026-06-15:

- Visual proxy ownership moved one step farther from parser-shaped refs:
  Morrowind adapter routes now call record-based proxy hooks on
  `ReferenceInstantiator`, using `WorldObjectRecord.source_key` for deferred
  proxy creation, runtime suppression/restore, and container dirty marking.
- Deleted the public ref-key proxy hook surface:
  `ensure_source_visual_proxy_for_ref`, `apply_source_visual_proxy_runtime`,
  and `make_source_visual_proxy_key`. The replacement surface is only the two
  used record hooks; the adapter reads `WorldObjectRecord.source_key` directly
  where it only needs the key. Boundary tests now guard against the retired
  names returning.
- Kept `make_source_key()` and the worker-tail `CellReference` route for now.
  That is still migration debt, but this slice avoided pretending the worker
  tail is normalized before route proof exists.
- Exact boundary ledger update: `ReferenceInstantiator` `CellReference` marker
  count is now 11, down from 13.

Verification:

- Focused gdUnit `reports/report_52`: 23 tests, 0 failures across
  `test_adapter_boundary`, `test_route_usage_stats`, and
  `test_streaming_modular_boundaries`.
- Spawn-adapter gdUnit `reports/report_53`: the two new record-proxy tests
  passed. The suite still has the known unrelated fake-record
  carryable-registry error in `test_morrowind_spawn_adapter_routes_node_payload`.
- Changed-path transition smoke exited 0 with empty capture log:
  `reports/spring_cleanup_pillar2_record_proxy_smoke.log`. A leftover Godot
  process was closed manually afterward, so this is crash/exit proof rather
  than a logged transition verdict.
- Post-edit bloat scan: `src-core` 609 files / 108643 lines,
  `src-morrowind-adapter` 58 files / 8595 lines, `tests-unit` 80 files /
  9192 lines. The worktree remains broadly dirty with prior report deletions
  and Spring cleanup slices.
- No C# files or shader files changed. Shader cache/import artifacts were not
  cleared.

Next deletion slice:

1. Audit the remaining `ReferenceInstantiator` worker-tail/source-helper
   methods typed on `CellReference`: `complete_worker_instantiate`,
   `_apply_metadata`, `_apply_transform`, `_auto_play_nif_animation`, and
   actor/light helpers.
2. Decide whether the worker tail can carry a `WorldObjectRecord`, or document
   it as explicitly quarantined parser migration debt until the route is
   converted.
3. Keep sync fallback and seamless portal deletion decisions deferred; they are
   product/debug-role questions, not proven-dead code from this slice.

Pillar 2 worker-tail record-identity cleanup completed 2026-06-16:

- Phase A worker-node dispatch remains disabled by default, but its dormant
  route now creates an adapter-owned `WorldObjectRecord` before scheduling work.
  If the path is re-enabled later, worker publish uses record transform,
  record metadata, and `WorldObjectRecord.source_key` instead of rebuilding
  proxy identity from parser-shaped refs.
- Deleted the old `make_source_key()` helper and loosened the worker metadata,
  transform, and animation helpers from `CellReference`-typed signatures to
  migration `Variant` inputs. The remaining parser ref is only the Morrowind
  adapter payload passed into source postprocessing.
- Exact `ReferenceInstantiator` `CellReference` marker debt dropped from 11 to
  6. This was small code growth, not a deletion-heavy slice, but it removes a
  stale parser identity branch from the parked worker path.

Verification:

- Focused gdUnit `reports/report_54`: 24 tests, 0 failures across
  `test_adapter_boundary`, `test_route_usage_stats`, and
  `test_streaming_modular_boundaries`.
- Changed-path transition smoke exited 0 with empty capture log:
  `reports/spring_cleanup_pillar2_worker_tail_record_smoke.log`. A leftover
  Godot process was closed manually afterward, so this is crash/exit proof
  rather than a logged transition verdict.
- Post-edit bloat scan: `src-core` 609 files / 108665 lines,
  `src-morrowind-adapter` 58 files / 8595 lines, `tests-unit` 80 files /
  9204 lines.
- No C# files or shader files changed. Shader cache/import artifacts were not
  cleared.

Next deletion slice:

1. Audit the remaining `ReferenceInstantiator` source light/actor helpers typed
   on `CellReference`.
2. Move only source-specific behavior with a clear adapter owner; do not move
   generic Godot node creation mechanics just to reduce marker counts.
3. Keep sync fallback and seamless portal deletion decisions deferred.

Pillar 2 retired ObjectStreamer parser-hook deletion completed 2026-06-16:

- Deleted `CellManager.get_cell_references()` and
  `instantiate_deferred_object()`. Repo-wide scan found no live callers; these
  were old per-object `ObjectStreamer` hooks in a project now using
  `NativeStreamingManager`, world manifests, and normalized object records.
- Bloat/rent decision: delete now. The hooks provided no current proof value,
  kept a parser-cell lookup surface in generic `CellManager`, and duplicated
  object-pool/model-load behavior outside the accepted streaming pipeline.
- Added a focused boundary guard so the retired `CellManager` method names do
  not return.
- Exact boundary ledger: `CellManager` `CellRecord` marker debt dropped from
  9 to 8. Remaining parser-cell bridge debt stays deferred and route-by-route.

Verification:

- Focused gdUnit exited 0 for `test_adapter_boundary`,
  `test_route_usage_stats`, and `test_streaming_modular_boundaries`.
- Transition smoke `tests/visual/test_interior_transition.tscn -- --auto-test`
  exited 0 with empty log
  `reports/spring_cleanup_pillar2_objectstreamer_hooks_deleted_smoke.log`; no
  lingering Godot process remained after recheck.
- Post-edit bloat scan: `src-core` 609 files / 108626 lines; `tests-unit`
  80 files / 9235 lines. The broader worktree remains dirty from prior Spring
  cleanup/report-deletion work.
- No C# files or shader files changed. Shader cache/import artifacts were not
  cleared.

Next deletion slice:

1. Audit `CellManager.load_characters_into_cell()` as the next exterior
   parser-cell fallback. Prefer a manifest actor/creature route if it can be
   proven with fake-source tests and the character-toggle caller.
2. Do not touch named interior/pocket parser-cell loading until a normalized
   interior manifest or explicitly Morrowind-owned loading contract exists.
3. Keep sync fallback and seamless portal deletion decisions deferred.

Pillar 2 exterior character-toggle manifest cleanup completed 2026-06-16:

- `CellManager.load_characters_into_cell()` now uses `WorldCellManifest` actor
  records when a manifest is already attached to the exterior cell node, or
  when the active world object source can provide one. It only opens the
  quarantined exterior parser-cell bridge when no manifest exists.
- Added route counters for `character_world_manifest_cells` and
  `character_source_exterior_cells`, plus a focused fake-source test that
  proves character toggling does not request a legacy exterior cell when the
  metadata-only cell already has a manifest.
- Bloat/rent decision: keep. This adds a small helper group and one focused
  test, but it removes a load-bearing parser access from the default
  manifest-backed character-toggle route and gives the remaining fallback a
  route counter. It is not enough to lower the exact parser ledgers because the
  parser fallback still exists.

Verification:

- `reports/report_65`: `test_world_source_boundary`, 16 tests, 0 failures.
- `reports/report_62`: adapter-boundary, route-usage, and streaming modular
  boundary suites, 26 tests, 0 failures.
- Static marker scan: `CellManager` remains at `CellRecord` 8 and
  `CellReference` 20.
- This slice did not edit C# files, but the shared worktree already had dirty
  C# files, so `dotnet build Godotwind.sln` was run and passed with 0 warnings
  / 0 errors.
- No shader files changed. Shader cache/import artifacts were not cleared.

Next deletion slice:

1. Continue `CellManager` parser-cell cleanup route-by-route after the
   character-toggle manifest path. Start with one remaining exterior route that
   has a clear manifest or adapter-owned replacement.
2. Do not lower exact ledgers until marker counts actually drop and focused
   route proof exists.
3. Keep named interior/pocket parser-cell loading deferred until there is a
   normalized interior manifest or explicit Morrowind-owned loading contract.

Pillar 2 manifest sync result-envelope cleanup completed 2026-06-16:

- `CellManager._instantiate_world_cell_manifest()` now consumes
  `instantiate_world_object_record_result()` when available, so sync
  manifest-backed exterior loading uses the same explicit result envelope as
  async publication for route classification.
- Deleted the unused `CellManager._apply_transform(node, ref: CellReference,
  ...)` wrapper. Repo scan found no live callers; the remaining transform
  implementation stays in `ReferenceInstantiator`.
- Bloat/rent decision: keep. This is a small net source increase because the
  sync manifest path now stores the result envelope defensively, but it removes
  one stale parser-ref API surface and lowers the exact `CellManager`
  `CellReference` marker ledger from 20 to 19.

Verification:

- `dotnet build Godotwind.sln` passed with 0 warnings / 0 errors.
- `reports/report_66`: adapter-boundary, route-usage, world-source-boundary,
  and streaming modular boundary suites, 42 tests, 0 failures / 0 errors.
- Static marker scan: `CellManager` remains at `CellRecord` 8 and drops to
  `CellReference` 19.
- Changed-path transition smoke exited 0 with empty capture log:
  `reports/spring_cleanup_pillar2_manifest_result_smoke.log`. A leftover Godot
  debug process was observed immediately after the command returned but exited
  before it could be stopped; no lingering process remained after recheck.
- Post-edit bloat scan: `src-core` 609 files / 108693 lines; `tests-unit`
  80 files / 9270 lines. The broader worktree remains dirty from prior Spring
  cleanup/report-deletion work.
- No shader files changed. Shader cache/import artifacts were not cleared.

Next deletion slice:

1. Continue `CellManager` parser-cell cleanup route-by-route after the
   manifest result-envelope cleanup.
2. Prefer one exterior parser fallback with manifest or adapter-owned proof
   before touching interior/pocket parser loading.
3. Keep sync fallback and seamless portal deletion decisions deferred.

Pillar 2 sync exterior fallback manifest cleanup completed 2026-06-16:

- `CellManager.load_exterior_cell()` now keeps the normal injected
  `WorldCellManifest` path first, then converts the quarantined exterior
  parser-cell fallback into a transient `WorldCellManifest` made of
  adapter-owned `WorldObjectRecord` payloads before publication.
- Added focused route proof for the fallback with no `WorldObjectSource`
  manifest: the parser bridge supplies an exterior cell, the spawn adapter sees
  its cached source payload, the cell node receives `world_cell_manifest`
  metadata, `world_object_record_calls` increments, and the retired
  `source_reference_calls` route remains absent.
- Bloat/rent decision: keep temporarily. The slice adds a small helper and one
  route test, but it moves a load-bearing sync exterior fallback onto the same
  manifest/result-envelope publication contract as normalized world cells and
  lowers exact `CellManager` `CellRecord` debt from 8 to 7. Delete condition:
  remove this transient parser-cell manifest builder once exterior parser
  fallback is either fully replaced by `WorldObjectSource.get_cell_manifest()`
  or moved behind an explicitly Morrowind-owned loading surface.

Verification:

- `dotnet build Godotwind.sln` passed with 0 warnings / 0 errors.
- `reports/report_67`: adapter-boundary, route-usage,
  world-source-boundary, and streaming modular boundary suites, 43 tests,
  0 failures / 0 errors.
- Static marker scan: `CellManager` is now `CellRecord` 7 and
  `CellReference` 19.
- Main-world smoke launched `scenes/Godotwind.tscn` for 15 seconds, reached
  `_ready()` in 583 ms, and logged no script, parse, fatal, or exception
  errors. Logs:
  `reports/spring_cleanup_pillar2_sync_exterior_manifest_smoke.out.log` and
  `.err.log`; a lingering Godot process was closed afterward.
- Post-edit bloat scan: `src-core` 609 files / 108740 lines; `tests-unit`
  80 files / 9305 lines.
- No shader files changed. Shader cache/import artifacts were not cleared.

Next deletion slice:

1. Continue `CellManager` parser-cell cleanup route-by-route.
2. Prefer metadata/source exterior fallback or static/collision/MultiMesh
   parser loops before touching named interior/pocket parser loading.
3. Keep sync fallback and seamless portal deletion decisions deferred.

Pillar 2 metadata exterior fallback manifest cleanup completed 2026-06-16:

- `CellManager.load_exterior_cell_metadata_only()` still prefers the normal
  injected `WorldCellManifest` route. If that route misses and the quarantined
  exterior parser-cell bridge returns a parser cell, the metadata-only cell
  node now receives a transient `world_cell_manifest` made of adapter-owned
  `WorldObjectRecord` payloads instead of raw `cell_record` metadata.
- Added focused route proof for the parser-backed metadata fallback: the
  parser bridge supplies an exterior cell, the spawn adapter builds payload
  records, the node receives `world_cell_manifest`, raw `cell_record` metadata
  stays absent, no instantiation occurs for metadata-only loading, and the
  retired `source_reference_calls` route remains absent.
- Bloat/rent decision: keep temporarily. This is a small source/test increase,
  but it removes one raw parser metadata escape hatch and lets follow-up
  character toggles reuse normalized manifest identity. Delete condition:
  remove the transient parser-cell manifest builder once the parser fallback is
  replaced by `WorldObjectSource.get_cell_manifest()` or moved behind an
  explicitly Morrowind-owned loading surface.

Verification:

- `dotnet build Godotwind.sln` passed with 0 warnings / 0 errors.
- `reports/report_68`: adapter-boundary, route-usage,
  world-source-boundary, and streaming modular boundary suites, 44 tests,
  0 failures / 0 errors.
- Static marker scan: `CellManager` is now `CellRecord` 6 and
  `CellReference` 19.
- Main-world smoke launched `scenes/Godotwind.tscn` for 15 seconds with world
  streaming disabled, reached `_ready()` in 646 ms, and logged no script,
  parse, fatal, or exception errors. Logs:
  `reports/spring_cleanup_pillar2_metadata_manifest_smoke.out.log` and
  `.err.log`; a lingering Godot process was closed afterward.
- Post-edit bloat scan: `src-core` 609 files / 108741 lines; `tests-unit`
  80 files / 9332 lines.
- No shader files changed. Shader cache/import artifacts were not cleared.

Next deletion slice:

1. Continue `CellManager` parser-cell cleanup route-by-route.
2. Prefer static/collision/MultiMesh parser loops before touching named
   interior/pocket parser loading.
3. Keep sync fallback and seamless portal deletion decisions deferred.

Pillar 2 async exterior fallback manifest cleanup completed 2026-06-17:

- `CellManager.request_exterior_cell_async()` now repackages the quarantined
  exterior parser-cell fallback through a transient `WorldCellManifest` made
  of adapter-owned `WorldObjectRecord` payloads before starting the async
  request.
- Bloat/rent decision: keep temporarily. This adds a small request-shaping
  branch and one focused route test, but it removes one raw parser cell from
  the async exterior classification/static/collision lane and lowers exact
  `CellManager` `CellRecord` debt from 6 to 5. Delete condition: remove the
  transient parser-cell manifest builder once the parser fallback is replaced
  by `WorldObjectSource.get_cell_manifest()` or moved behind an explicitly
  Morrowind-owned loading surface.

Verification:

- Focused gdUnit exited 0 for `test_adapter_boundary`,
  `test_route_usage_stats`, `test_world_source_boundary`, and
  `test_streaming_modular_boundaries`.
- `dotnet build Godotwind.sln` passed with 0 warnings / 0 errors because the
  shared worktree still has dirty C# files.
- Main-world smoke launched `scenes/Godotwind.tscn` for 15 seconds, reached
  `_ready()` in 818 ms, left no lingering Godot process, and matched no script,
  parse, fatal, exception, or error lines in the smoke logs:
  `reports/spring_cleanup_pillar2_async_exterior_manifest_smoke.out.log` and
  `.err.log`.
- Post-edit bloat scan: `src-core` 609 files / 108756 lines;
  `tests-unit` 80 files / 9360 lines.
- No shader files changed. Shader cache/import artifacts were not cleared.

Next deletion slice:

1. Exterior parser fallbacks now all route through transient manifests; do not
   keep patching exterior unless route proof identifies another raw parser
   escape hatch.
2. Treat interior parser loading as deferred until there is a normalized
   interior manifest or explicitly Morrowind-owned loading surface.
3. Continue Pillar 2 with the next boundary candidate if no safe interior slice
   exists.

Pillar 2 ObjectPositionIndex deletion completed 2026-06-17:

- Deleted unused `src/core/world/object_position_index.gd` and `.uid`.
  Repo-wide search found no runtime/test callers; only docs and the boundary
  ledger referenced it.
- Bloat/rent decision: delete now. The file was parked generic runtime code
  that built directly from `ESMManager`, `CellRecord`, and `CellReference`,
  duplicating object discovery concepts already owned by
  `WorldObjectSource`/`WorldCellManifest` for active HLOD/FAR/streaming paths.
- Updated `tests/unit/test_adapter_boundary.gd` and
  `docs/systems/object_paging.md` so the deleted path is not preserved as an
  accepted boundary allowance or current HLOD component.

Verification:

- Focused gdUnit exited 0 across `test_adapter_boundary`,
  `test_route_usage_stats`, `test_world_source_boundary`, and
  `test_streaming_modular_boundaries`.
- Post-edit bloat scan: `src-core` 607 files / 108267 lines;
  `tests-unit` 80 files / 9354 lines.
- Main-world startup smoke reached `_ready()` in 614 ms, left no lingering
  Godot process, and matched no script, parse, fatal, exception, or error
  lines in
  `reports/spring_cleanup_pillar2_object_position_index_deleted_smoke.out.log`
  and `.err.log`.
- No C# files or shader files changed. Shader cache/import artifacts were not
  cleared.

Next deletion slice:

1. Keep named interior parser loading deferred until there is a normalized
   interior manifest or explicitly Morrowind-owned loading surface.
2. Continue Pillar 2 with another unused or adapter-owned boundary candidate
   before touching load-bearing interior routes.

Pillar 2 Phase E precompute call-contract cleanup completed 2026-06-17:

- Fixed the remaining call-site mismatch from the static-render precompute
  boundary slice. `ReferenceInstantiator._worker_static_precompute()` now
  converts the quarantined parser ref to `Transform3D`, `ref_id`, and `ref_num`
  before calling `StaticObjectRenderer.precompute_instance()`.
- Bloat/rent decision: keep. This adds a small helper and one focused unit
  test, but removes a real contract mismatch in the Phase E worker path and
  prevents the source-neutral renderer API from being bypassed by the old
  argument shape.

Verification:

- Focused gdUnit `reports/report_74`: `test_phase_e_precompute`,
  `test_adapter_boundary`, and `test_streaming_modular_boundaries`, 21 tests,
  0 failures / 0 errors.
- `dotnet build Godotwind.sln` passed with 0 warnings / 0 errors.
- Main-world startup smoke reached `_ready()` in 774 ms, left no lingering
  Godot process, and matched no script, parse, fatal, or exception lines in
  `reports/spring_cleanup_pillar2_phase_e_precompute_contract_smoke.out.log`
  and `.err.log`. Existing shutdown resource/RID leak warnings remain, including
  `ERROR: 4 resources still in use at exit`.
- Post-edit bloat scan: `src-core` 607 files / 108276 lines;
  `tests-unit` 80 files / 9393 lines.
- No shader files changed. Shader cache/import artifacts were not cleared.

Next deletion slice:

1. Keep named interior parser loading deferred until there is a normalized
   interior manifest or explicitly Morrowind-owned loading surface.
2. Continue Pillar 2 with another small source-neutral API cleanup or
   unused/adapter-owned boundary candidate.
3. Do not spend the next Pillar 2 slice on the shutdown resource leak; that is
   lifecycle/debugability debt unless tied to a boundary cleanup.

Pillar 2 light metadata boundary cleanup completed 2026-06-17:

- Deleted the unused `mw_radius` metadata write from
  `ReferenceInstantiator._attach_animated_omni_light()` and corrected the stale
  `mw_flags` comment to the active `light_animation` metadata contract.
- Bloat/rent decision: delete now. Repo-wide search found no reader for
  `mw_radius`; keeping it only preserved source-specific diagnostic metadata in
  generic light instantiation. The exact `ReferenceInstantiator` `mw_` ledger
  is now 0.

Verification:

- Focused gdUnit `reports/report_75`: `test_adapter_boundary`,
  `test_route_usage_stats`, and `test_morrowind_world_object_spawn_adapter`,
  42 tests, 0 failures / 0 errors.
- Static grep found no `mw_`, `mw_radius`, or `mw_flags` in
  `src/core/world/reference_instantiator.gd`.
- Interior transition smoke loaded Arrille's Tradehouse with 16 lights,
  completed enter and exit cleanup, and matched no script, parse, fatal,
  exception, or `ERROR:` lines in
  `reports/spring_cleanup_pillar2_light_metadata_cleanup_smoke.out.log` and
  `.err.log`. Existing transition frametime `[FAIL]` verdicts remain, and a
  rerun hit the known lingering-process cleanup quirk before useful logs were
  produced.
- Post-edit bloat scan: `src-core` 607 files / 108273 lines;
  `tests-unit` 80 files / 9393 lines.
- No C# files or shader files changed. Shader cache/import artifacts were not
  cleared.

Next deletion slice:

1. Keep named interior parser loading deferred until there is a normalized
   interior manifest or explicitly Morrowind-owned loading surface.
2. Continue Pillar 2 with another small source-neutral API cleanup or
   unused/adapter-owned boundary candidate.
3. Do not start a broad terrain or impostor ownership move without a separate
   proof slice.

Pillar 2 light-scale marker cleanup completed 2026-06-17:

- Deleted unused `CellManager.MW_LIGHT_SCALE`.
- Renamed `ReferenceInstantiator.MW_LIGHT_SCALE` to
  `SOURCE_LIGHT_RADIUS_SCALE`; behavior is unchanged because both light paths
  still multiply by `CS.SCALE_FACTOR`.
- Lowered `test_adapter_boundary` broad marker ceilings for the current
  `CellManager` and `ReferenceInstantiator` counts.
- Bloat/rent decision: keep. This is a net deletion/source-neutral naming
  cleanup with a small test-ratchet edit. It does not create a new migration
  helper or touch the parser-cell bridge.

Verification:

- Focused gdUnit `reports/report_76`: `test_adapter_boundary`,
  `test_route_usage_stats`, and `test_morrowind_world_object_spawn_adapter`,
  42 tests, 0 failures / 0 errors.
- Interior transition smoke exited 0 with empty capture log
  `reports/spring_cleanup_pillar2_light_scale_boundary_smoke.log`; no script,
  parse, fatal, exception, or `ERROR:` lines were matched. A lingering Godot
  process remained after the command returned and was closed manually, so treat
  this as crash/exit proof only.
- Post-edit bloat scan: `src-core` 607 files / 108269 lines; `tests-unit`
  80 files / 9393 lines.
- No C# files or shader files changed. Shader cache/import artifacts were not
  cleared.

Next deletion slice:

1. Keep named interior parser loading deferred until there is a normalized
   interior manifest or explicitly Morrowind-owned loading surface.
2. Continue Pillar 2 with another small source-neutral API cleanup or
   unused/adapter-owned boundary candidate.
3. Avoid broad terrain moves unless the next session first writes a separate
   proof slice. The impostor candidate profile/pattern cleanup is complete as
   of 2026-06-17; only revisit it for a new concrete leak.

Pillar 2 impostor profile ownership cleanup completed on 2026-06-17:

- Generic `ImpostorCandidates` no longer owns Morrowind model-name pattern
  policy. It keeps source-neutral hashing, cache-path, custom-candidate, and
  settings plumbing.
- `MorrowindImpostorCandidates` owns the source-specific candidate profile and
  archive-backed catalog scan.
- `MorrowindWorldSource.get_impostor_candidates()` now feeds that provider into
  `NativeStreamingManager`, `CellManager`, `ReferenceInstantiator`, and the FAR
  impostor stress scene.

Verification:

- Direct gdUnit `reports/report_83`: 24 focused tests, 0 failures across
  `test_adapter_boundary`, `test_streaming_modular_boundaries`, and
  `test_native_impostor_renderer_queue`.
- `tests/visual/test_impostor_stress.tscn -- --auto-duration=3
  --stamp=pillar2_impostor_policy` exited 0 after the scene was updated to use
  the Morrowind candidate provider.
- No C# or shader files changed. Shader cache/import artifacts were not
  cleared.

Pillar 2 static-render/ObjectPaging marker cleanup completed on 2026-06-17:

- Renamed direct-RS fallback locals in `StaticObjectRenderer` from
  `legacy_*_rid` to `direct_*_rid`.
- Reworded `StaticObjectRenderer.InstanceData` inline comments from ESM
  reference identity to source reference identity.
- Reworded the `ObjectPaging` empty-HLOD debug log from no ESM refs to no
  source refs.
- Ratcheted `test_adapter_boundary` broad source-marker baselines for
  `src/core/world/static_object_renderer.gd` and
  `src/core/world/object_paging.gd` to 0.
- Bloat/rent decision: keep. This is behavior-neutral naming/comment/log
  cleanup with a test ratchet; it removes stale source-specific wording from
  generic rendering/HLOD files without adding runtime scaffolding.

Verification:

- Local marker count found zero broad forbidden source markers in the two
  touched generic runtime files.
- Focused gdUnit exited 0 across `test_adapter_boundary`,
  `test_static_object_renderer_bwide`, and
  `test_streaming_modular_boundaries`.
- HLOD benchmark smoke reached HLOD enabled plus benchmark recording and
  matched no script, parse, fatal, exception, or `ERROR:` lines in
  `reports/spring_cleanup_pillar2_static_renderer_object_paging_smoke.out.log`
  and `.err.log`; the capped smoke was closed after 25 seconds.
- Post-edit bloat scan: `src-core` 607 files / 108269 lines; `tests-unit`
  80 files / 9393 lines.
- No C# files or shader files changed. Shader cache/import artifacts were not
  cleared.

Next deletion slice:

1. Keep named interior parser loading deferred until there is a normalized
   interior manifest or explicitly Morrowind-owned loading surface.
2. Continue Pillar 2 with another small source-neutral API cleanup or
   unused/adapter-owned boundary candidate.
3. Avoid broad terrain or impostor moves unless the next session first writes
   a separate proof slice.

Pillar 2 CellManager parser-class boundary cleanup completed on 2026-06-17:

- Replaced the remaining concrete `CellRecord` / `CellReference` annotations
  and casts in generic `CellManager` with typed `Variant` source-ref payloads.
  The injected parser-cell bridge still exists as temporary quarantine, but
  `CellManager` no longer names the parser classes directly.
- Ratcheted `test_adapter_boundary` so `src/core/world/cell_manager.gd` now
  stays at `CellRecord=0` and `CellReference=0`.
- Bloat/rent decision: keep. This is a behavior-neutral boundary contraction:
  no new helpers, counters, or runtime branches were added, and the remaining
  named interior parser loading route stays deferred until a normalized
  interior manifest or explicitly Morrowind-owned loading contract exists.

Verification:

- Focused gdUnit `reports/report_84`: `test_adapter_boundary` and
  `test_route_usage_stats`, 25 tests, 0 failures / 0 errors.
- Static grep found no `CellRecord` or `CellReference` hits in
  `src/core/world/cell_manager.gd`.
- Interior transition smoke launched
  `tests/visual/test_interior_transition.tscn -- --auto-test`, exited 0, and
  left no lingering Godot process; the capture log
  `reports/spring_cleanup_pillar2_cellmanager_variant_boundary_smoke.out.log`
  was empty, so this is crash/exit proof only.
- Post-edit bloat scan: `src-core` 607 files / 107985 lines; `tests-unit`
  80 files / 9420 lines.
- No C# files or shader files changed. Shader cache/import artifacts were not
  cleared.

Next deletion slice:

1. Superseded by the parser-cell bridge deletion slice below.
2. Continue Pillar 2 with transition-space payload/environment migration or
   DODT-based exterior target-space resolution.
3. Do not do more `CellManager` parser-class marker cleanup; the generic
   parser-cell loading bridge is gone.

Pillar 2 parser-cell bridge deletion completed on 2026-06-17:

- Deleted the generic parser-cell bridge contract. `WorldSource` no longer has
  `parser_cell_bridge`, `MorrowindWorldSource` no longer creates
  `ParserCellBridge`, and `CellManager` no longer calls parser-cell lookup or
  fallback instantiation helpers.
- `WorldObjectSource.get_space_manifest()` now delegates interior handles to
  `get_interior_cell_manifest()`, so named interiors and exterior grids both
  load through normalized manifests.
- `MorrowindWorldObjectSource` owns interior manifest creation and caches
  source-specific parser access inside the Morrowind adapter.
- Bloat/rent decision: keep the small `cell_name` manifest field, route
  counters, and deletion guard tests. They are the minimum contract and proof
  needed to prevent the parser-cell bridge from being restored.

Verification:

- Focused gdUnit `reports/report_96`: 40 tests, 0 failures / 0 errors across
  `test_adapter_boundary`, `test_route_usage_stats`, and
  `test_world_source_boundary`. The gdUnit process still returned 101 because
  these suites report existing orphan-node/resource warnings.
- Static grep found retired bridge symbols only in guard tests.
- `tests/visual/test_interior_transition.tscn -- --auto-test` loaded, entered,
  and exited Arrille's Tradehouse with final auto-test verdict `[PASS]`; one
  enter-transition frametime sample still exceeded the threshold at 35.77 ms.
- Post-edit bloat scan: `src-core` 607 files / 107561 lines; `tests-unit`
  80 files / 9385 lines.
- No C# or shader files changed. Shader cache/import artifacts were not
  cleared.

Next deletion slice:

1. Do not recreate the parser-cell bridge in generic world code.
2. Migrate `TransitionProvider.get_transition_space_payload()` toward a
   source-neutral transition-space payload/environment contract.
3. Keep the next slice focused; do not start the full transition state-machine
   refactor in the same pass.

Pillar 2 DODT exterior target-space cleanup completed on 2026-06-17:

- `MorrowindTransitionProvider.get_interior_transition_portals()` now derives
  exterior target handles from `DODT` arrival position with
  `CoordinateSystem.world_to_cell_grid()`, so interior exit doors carry real
  grid keys such as `-2,-9` instead of empty exterior handles.
- Regression coverage lives in `test_interior_transition_phase1`; the runtime
  transition smoke logged `exit_to_exterior() called: '-2,-9'`.
- Verification caveat: the clean captured smoke rerun exited 2 on the existing
  frametime threshold, but it completed enter/exit with no script, parse,
  fatal, or exception errors. No C# or shader files changed, and shader
  cache/import artifacts were not cleared.

## First Bloat-Control Targets

1. Separate real production growth from generated report churn.
2. Decide which `reports/report_*` artifacts should remain tracked, archived,
   ignored, or deleted.
3. Review cleanup scaffolding added during slices 1-8:
   route counters, compatibility no-ops, owner APIs, strict-typing ledgers,
   tests, and audit docs.
4. Check side-project organization:
   - hydrology/native atlas builder,
   - transition provider files,
   - render layer files,
   - visual/unit test additions.
5. Produce a deletion ledger with proof requirements for every dead-code
   candidate.

## Decision Categories

- Keep permanently: load-bearing runtime, explicit framework contract,
  high-value invariant test, or source adapter with clear owner.
- Keep temporarily: migration counter, compatibility alias, or audit scaffold
  with a named deletion condition.
- Delete now: unused generated artifact, duplicate stale test/report, parked
  command/path with proof of no references.
- Defer: legacy runtime path that needs route-counter or visual-smoke proof.
- Move: valid code/test/tool in the wrong home.

## Useful Short Prompts

- `Check for bloat.`
- `Bloat control, continue.`
- `Run the LOC audit.`
- `Find dead code ruthlessly.`
- `Organize side projects and tests.`
