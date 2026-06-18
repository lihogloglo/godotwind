# Spring Cleanup State

Last updated: 2026-06-18

Purpose: durable state file for the Godotwind Spring cleanup audit. When the
user says "Spring cleanup, continue" or "continue the audit", read this file
first and choose the next unfinished item.

## How To Resume

Use the repo-local skill:

- `.agents/skills/spring-cleanup/SKILL.md`

Then read:

- `docs/audit/spring_cleanup_program_2026_06_13.md`
- the current pillar charter or audit doc listed below
- `docs/STATUS.md`

Do not ask the user to paste a long prompt. The short prompt "Spring cleanup,
continue" is enough.

## Current Pillar

Pillar 3 preparation: systematic performance/loading optimization.

Current mode: charter prepared. Pillar 3.0 observability is the evidence gate;
Pillar 3 optimization may change runtime code only after a current scenario
report identifies a bottleneck and the slice names the canonical Godot or
industry pattern. Keep each optimization slice small, compare before/after
reports from the same scenario, and verify with the narrowest changed-path
test, benchmark, visual scene, or smoke.

Current docs:

- Program: `docs/audit/spring_cleanup_program_2026_06_13.md`
- Pillar 1 charter:
  `docs/audit/spring_cleanup_pillar_1_code_quality_charter_2026_06_13.md`
- Pillar 1 audit draft:
  `docs/audit/spring_cleanup_pillar_1_code_quality_audit_2026_06_13.md`
- Pillar 2 charter:
  `docs/audit/spring_cleanup_pillar_2_morrowind_framework_boundary_charter_2026_06_14.md`
- Pillar 3.0 observability charter:
  `docs/audit/spring_cleanup_pillar_3_0_performance_observatory_charter_2026_06_15.md`
- Pillar 3 optimization charter:
  `docs/audit/spring_cleanup_pillar_3_optimization_charter_2026_06_18.md`
- Pillar 3.0 state:
  `docs/audit/performance_observatory_state.md`
- Session template: `docs/audit/spring_cleanup_session_template.md`

## Pillar Progress

| Pillar | Topic | Status |
|---:|---|---|
| 1 | Code quality / architecture | Slices 1-10 implemented; bloat-control deletion candidates remain optional future work |
| 2 | Morrowind/framework boundary | Many ownership slices completed through terrain manager cleanup; remaining boundary work is optional unless it blocks Pillar 3 |
| 3.0 | Performance Observatory | Benchmark/report/loading/lifetime/hot-path evidence foundation complete enough to gate optimization |
| 3 | Performance + loading optimization | Lane evidence and loading-speed attribution collected 2026-06-18; next step is one measured loading optimization target from the warm-start attribution report |
| 4 | Debugability | Not started |
| 5 | Loading time | Folded into Pillar 3 optimization because the same systems own startup, streaming, and runtime frame cost |

## Known Context

- Slice 1 added route-usage counters for `CellManager` and
  `ReferenceInstantiator`, exposed them through loading/stats dictionaries, and
  added `tests/unit/test_route_usage_stats.gd`.
- Slice 2 replaced the smallest private reach-through seam with explicit owner
  APIs: `CellManager` now exposes model-loader/instantiator/static-renderer
  access through named methods, `NativeStreamingManager` exposes loaded-cell,
  static-renderer debug, and impostor debug methods, and `StaticObjectRenderer`
  exposes prototype-registry distribution for the parked debug command.
- Slice 2 added `tests/unit/test_spring_cleanup_owner_apis.gd` to guard the
  target private reach-through patterns.
- Slice 3 added `ReferenceInstantiator.InstantiationResult` and migrated the
  normalized `world_object_record` async drain route in `CellManager` to consume
  an explicit result envelope instead of reading the shared `last_*` diagnostics
  for that route. Legacy/source routes still use `last_*` and should be
  migrated one at a time.
- Slice 3 also fixed the source-cell route counters that had been placed after
  the early guard returns during Slice 1.
- Verification on 2026-06-13: `dotnet build Godotwind.sln` passed. The gdUnit
  run included `test_route_usage_stats` with 3 tests, 0 failures. The same run still had
  unrelated pre-existing unit failures in other suites, including
  `test_adapter_boundary`.
- Verification on 2026-06-13 for Slice 2: `dotnet build Godotwind.sln`
  passed. The gdUnit run included
  `test_route_usage_stats` with 3 tests, 0 failures and
  `test_spring_cleanup_owner_apis` with 3 tests, 0 failures. The full unit run
  still has unrelated pre-existing failures in adapter-boundary, hydrology,
  subsystem-toggle, water-interaction, and world-source suites. Main scene
  crash smoke launched `scenes/Godotwind.tscn` for 10 seconds, reached
  `_ready()` successfully, and was closed manually.
- Verification on 2026-06-13 for Slice 3: `dotnet build Godotwind.sln`
  passed. Focused gdUnit included `test_route_usage_stats` with 5 tests,
  0 failures. Main scene smoke launched
  `scenes/Godotwind.tscn` for 12 seconds, reached `_ready()` successfully
  (`_ready() total: 685 ms` in
  `reports/spring_cleanup_slice3_godotwind_smoke.out.log`), and the process was
  closed. No shader/import cache artifacts were cleared because no shader files
  changed.
- Verification on 2026-06-13 for Slice 4: `dotnet build Godotwind.sln`
  passed. Focused gdUnit included
  `test_spring_cleanup_owner_apis` with 4 tests, 0 failures; the new test keeps
  Phase F preregistration quarantined and guards against restoring the
  `--enable-phase-f-prereg` switch or worker prereg symbols. A second focused
  gdUnit run included `test_route_usage_stats` with 5 tests, 0 failures. Main
  scene smoke launched `scenes/Godotwind.tscn`
  for 12 seconds, reached `_ready()` successfully (`_ready() total: 627 ms` in
  `reports/spring_cleanup_slice4_godotwind_smoke.out.log`), and the process was
  closed. No shader/import cache artifacts were cleared because no shader files
  changed.
- Slice 5 deleted the parked world-scoped `PrototypeRegistry` production path
  from `StaticObjectRenderer`, removed the `proto_registry` console/debug
  command, and removed the now-orphaned static-cull throttle constants. A later
  bloat pass removed the last `registry_batches` / `registry_slots`
  compatibility fields from runtime stats, benchmark readers, and helper tests
  after those readers stopped needing the dead PrototypeRegistry counters.
- Verification on 2026-06-14 for Slice 5: `dotnet build Godotwind.sln`
  passed. Focused gdUnit included
  `test_static_object_renderer_bwide`, `test_phase_e_precompute`,
  `test_bench_ladder_runner`, and `test_spring_cleanup_owner_apis` with 36
  tests, 0 failures; the new Spring cleanup test keeps the deleted registry
  path and console command from returning. Main scene smoke launched
  `scenes/Godotwind.tscn` for 12 seconds, reached `_ready()` successfully
  (`_ready() total: 988 ms` in
  `reports/spring_cleanup_slice5_godotwind_smoke.out.log`), and the process was
  closed. No shader/import cache artifacts were cleared because no shader files
  changed.
- Slice 6 aligned HLOD coverage metadata with the identity it actually carries:
  `source_object_ids`. `ObjectPaging` no longer emits or stores
  `source_ref_nums`, `NativeStreamingManager` no longer falls back to the stale
  manifest key or alias method, and `NativeImpostorRenderer` no longer exposes
  `set_hlod_covered_ref_nums()`.
- Verification on 2026-06-14 for Slice 6: `dotnet build Godotwind.sln`
  passed. The gdUnit run included
  `test_object_paging_kernel` with 75 tests, 0 failures and
  `test_spring_cleanup_owner_apis` with 6 tests, 0 failures. The same full
  report still has unrelated pre-existing failures in adapter-boundary,
  hydrology, subsystem-toggle, water-interaction, and world-source suites.
  HLOD changed-path smoke launched `tests/visual/test_hlod_benchmark.tscn`,
  auto-enabled HLOD, logged `[audit HLOD +5s] visual=2 ... merged=2 ...
  refs=385`, saved `reports/spring_cleanup_slice6_hlod_benchmark_smoke.out.log`,
  and the process was closed. No shader/import cache artifacts were cleared
  because no shader files changed.
- Slice 7 removed the normal main-scene escape-menu checkbox that toggled
  parked seamless interior transitions. Classic travel-door transitions remain
  the production path; the dedicated `tests/visual/test_interior_transition.gd`
  lab scene still owns its explicit F5 seamless/dev toggle.
- Verification on 2026-06-14 for Slice 7: `dotnet build Godotwind.sln`
  passed. Focused gdUnit included
  `test_spring_cleanup_owner_apis` with 7 tests, 0 failures; the new guard
  keeps the main scene from restoring the seamless checkbox or direct
  `_pocket_manager.seamless_enabled =` control write. Classic transition smoke
  launched `tests/visual/test_interior_transition.tscn -- --auto-test`, entered
  and exited Arrille's Tradehouse through the normal fade path, logged
  `[AUTO-TEST] RESULT: enter+exit complete ... [PASS]`, saved
  `reports/spring_cleanup_slice7_interior_transition_smoke.out.log`, and the
  process exited 0. No shader/import cache artifacts were cleared because no
  shader files changed.
- Slice 8 enabled the real Godot `gdscript/warnings/untyped_declaration=1`
  setting, added `tests/unit/test_core_strict_typing_policy.gd` as a focused
  static guard for the core strict-typing policy, and typed the new
  `MorrowindTransitionProvider` portal loops instead of relying on untyped
  iterator declarations.
- Verification on 2026-06-14 for Slice 8: `dotnet build Godotwind.sln`
  passed. Focused gdUnit included
  `test_core_strict_typing_policy` with 3 tests, 0 failures; another focused
  gdUnit run included
  `test_spring_cleanup_owner_apis` with 7 tests, 0 failures. The interior
  transition smoke launched
  `tests/visual/test_interior_transition.tscn -- --auto-test`, entered and
  exited Arrille's Tradehouse through the normal fade path, and saved
  `reports/spring_cleanup_slice8_interior_transition_smoke.out.log`. The smoke
  completed cleanup without script errors or a crash, but its own frametime
  verdict logged `[FAIL]` twice (first run last peak 23.33 ms; rerun last peak
  13.87 ms in `reports/spring_cleanup_slice8_interior_transition_smoke_rerun.out.log`).
  Treat this as a verification caveat for the transition performance harness,
  not as evidence that Slice 8 changed runtime behavior. No shader/import cache
  artifacts were cleared because no shader files changed.
- Slice 9 aligned current distance-rendering docs and current-state comments
  with the live 400m handoff contract: `docs/ARCHITECTURE.md`,
  `docs/systems/lighting.md`, `docs/systems/streaming_rendering_bible.md`,
  `src/core/world/static_object_renderer.gd`,
  `src/core/world/object_paging_kernel.gd`, and
  `src/core/world/streaming_config.gd` now describe MID as the 150-400m
  `CellStaticBucket` bridge, FAR as 400-5000m capped by view distance, and
  HLOD as the optional 400-1000m ObjectPaging comparison tier.
- Verification on 2026-06-14 for Slice 9: focused stale-text scan over
  current docs and world source comments no longer finds the retired 300m/500m
  current-state handoff wording or "one RS instance per object" MID wording in
  the Slice 9 target set. No Godot visual smoke was required because this slice
  changed documentation/comments only. No shader/import cache artifacts were
  cleared because no shader files changed.
- Slice 10 made benchmark/loading mode classification explicit. `NativeStreamingManager`
  now exposes `benchmark_mode_metadata` through `get_stats()` and a direct
  `get_benchmark_mode_metadata()` API. The metadata labels sync loading as
  invalid for performance baselines, counts executed sync fallback frames/cells,
  reports Phase F preregistration as quarantined, and makes NEAR/FAR/HLOD mode
  flags visible. Benchmark HUD, streaming benchmark JSON/summary, progressive
  CSV, auto-bench JSON, bench-ladder JSON, and stress summaries now carry the
  metadata; stress gates fail with `benchmark_invalid:*` reasons when a run
  uses unsupported metadata.
- Verification on 2026-06-14 for Slice 10: focused gdUnit CLI runs passed for
  `test_benchmark_mode_metadata`, `test_streaming_stress_runner_gates`,
  `test_auto_bench_runner`, and `test_bench_ladder_runner`. A capped main-scene
  startup smoke launched `scenes/Godotwind.tscn -- --disable-world-streaming
  --near-only --no-lights --disable-cell-static-collision`, reached `_ready()`
  and `_init_async()` successfully, and saved
  `reports/spring_cleanup_slice10_startup_smoke.out.log`. The smoke stderr had
  no script/parse/compile errors; it still logged the existing quit-time
  resource leak warning (`4 resources still in use at exit`). No shader/import
  cache artifacts were cleared because no shader files changed.
- Existing boundary evidence lives in
  `docs/audit/morrowind_framework_boundary_mega_audit_2026_05_21.md`,
  `docs/audit/framework_morrowind_boundary_adr_2026_05_22.md`,
  `docs/systems/adapter_boundary.md`, and
  `tests/unit/test_adapter_boundary.gd`.
- Pillar 2 charter created on 2026-06-14:
  `docs/audit/spring_cleanup_pillar_2_morrowind_framework_boundary_charter_2026_06_14.md`.
  The charter reused the May boundary audit/ADR, current adapter-boundary docs
  and tests, bloat-control state, `docs/STATUS.md`, and a fresh boundary run.
  It explicitly keeps Pillar 2 audit-first and does not authorize broad
  gameplay genericization.
- Fresh boundary-oriented run on 2026-06-14 generated a full unit report at
  `reports/report_9`. Useful pass: `test_streaming_modular_boundaries` had
  5 tests and 0 failures. Current red boundary signal:
  `test_adapter_boundary` fails on broad ratchet drift and stale exact ledgers,
  while `test_world_source_boundary` fails two fake-source runtime-proof
  assertions. The next step is classification, not a silent ratchet edit.
- Pillar 2 Slice 1/2 triage is now implemented in the working tree:
  `tests/unit/test_adapter_boundary.gd` lowered exact ledgers only where
  `InteriorPocketManager` / `ReferenceInstantiator` already reduced debt, and
  `tests/unit/test_world_source_boundary.gd` now proves fake-source async
  visual readiness by draining the resource lane and finds spawned sync nodes
  by generic `object_id` metadata instead of raw Godot node names.
- Pillar 2 ratchet-scope follow-up narrowed the broad ratchet after
  classification. Renderer `UNIFORM_TYPE` substring hits, the water
  `legacy_exclusion` source-mode label, active status/transition prose, and
  Boujie shader compatibility names no longer count as hard framework leaks.
  Native source-adapter ownership is explicit for
  `NativeMorrowindHydrologyAtlasBuilder.cs` and the current `NativeFactory.cs`
  count.
- Verification on 2026-06-14: focused gdUnit generated `reports/report_15`.
  `test_world_source_boundary` passed 15/15 and
  `test_streaming_modular_boundaries` passed 5/5. `test_adapter_boundary` is
  down to one intentional failure: `src/core/native_bridge.gd` still exposes
  source-specific native parser and hydrology factories from generic core.
- Pillar 2 native bridge ownership slice completed on 2026-06-14. Generic
  `NativeBridge` now owns only source-neutral C# availability and generic
  factory calls. Source-specific/native parser wrappers moved to
  `src/core/nif/native_nif_bridge.gd`,
  `src/core/esm/native_esm_bridge.gd`, and
  `src/core/world/morrowind/morrowind_native_bridge.gd`. `NIFConverter`,
  `ESMManager`, the Morrowind hydrology prebaker/tests/visual lab, and
  `ObjectPagingKernel` now use the owned wrapper/public factory APIs instead
  of source-specific methods or private `_factory` reach-through on
  `NativeBridge`.
- Verification on 2026-06-14 for the native bridge slice: focused gdUnit
  generated `reports/report_17` with 88 tests, 0 failures
  (`test_adapter_boundary`, `test_world_object_source`,
  `test_object_paging_kernel`, and `test_morrowind_terrain_index_map`). A
  temporary native bridge probe exited 0 after creating the generic, NIF, ESM,
  and Morrowind hydrology native services. A 45-second HLOD benchmark smoke
  launched `tests/visual/test_hlod_benchmark.tscn`, loaded native C# and
  Morrowind, enabled HLOD, started benchmark recording, and logged HLOD audit
  progress up to `merged=12 surfaces=707 refs=7279` with no script, parse,
  compile, fatal, or exception errors. Stderr contained existing
  frame-overrun/autopsy warnings during HLOD warmup. No C# files changed, so
  `dotnet build` was not required. No shader/import cache artifacts were
  cleared because no shader files changed.
- Pillar 2 parser-cell bridge quarantine completed on 2026-06-14.
  `CellManager` no longer calls `get_source_cell` or
  `get_source_exterior_cell` on the generic `WorldObjectSource` port. The
  remaining parser-shaped `CellRecord` fallback now travels through an
  explicitly injected parser-cell bridge. `MorrowindWorldSource` owns that
  bridge and delegates to the Morrowind object source's adapter-local source
  cell accessors. `NativeStreamingManager.set_world_source()` now forwards the
  full source to an initialized `CellManager` so source swaps carry the same
  parser bridge as mapper/assets/spawn adapter injection.
- Verification on 2026-06-14 for the parser-cell bridge slice: focused gdUnit
  generated `reports/report_20` with 32 tests, 0 failures across
  `test_adapter_boundary`, `test_streaming_modular_boundaries`,
  `test_route_usage_stats`, and `test_world_source_boundary`. The route tests
  still prove the source/interior fallback counters while the boundary tests
  now require `CellManager` to stay free of direct `get_source_cell` /
  `get_source_exterior_cell` calls. The changed-path interior scene smoke
  launched `tests/visual/test_interior_transition.tscn -- --auto-test` twice
  and exited 0 both times; stdout/stderr capture was empty, so the proof is a
  crash/exit smoke rather than a logged transition verdict. No C# files
  changed, so `dotnet build` was not required. No shader/import cache artifacts
  were cleared because no shader files changed.
- Pillar 2 source-reference result-envelope slice completed on 2026-06-14.
  `ReferenceInstantiator.instantiate_source_reference_result()` now wraps the
  remaining legacy source-ref call in the same `InstantiationResult` envelope
  used by normalized `WorldObjectRecord` spawning. `CellManager`'s async
  instantiation drain now consumes route, type, timing, static-data, and
  proximity-deferred diagnostics from that envelope for the source-ref fallback
  instead of reading `last_*` mutable diagnostics for this route. This is a
  quarantine and observability cleanup, not deletion of the parser tail.
- Verification on 2026-06-14 for the source-reference envelope slice:
  `reports/report_23` ran 33 focused Pillar 2 tests with 0 failures across
  `test_adapter_boundary`, `test_world_source_boundary`,
  `test_streaming_modular_boundaries`, and `test_route_usage_stats`; the route
  suite now includes
  `test_reference_instantiator_source_reference_result_envelopes_diagnostics`.
  `tests/visual/test_interior_transition.tscn -- --auto-test` launched and
  exited 0 as the changed-path streaming/transition smoke; stdout/stderr
  capture was empty, so this is recorded as a crash/exit smoke. Post-edit bloat
  scan showed `src-core` at 108734 lines and `tests-unit` at 8876 lines. No C#
  files changed, so `dotnet build` was not required. No shader/import cache
  artifacts were cleared because no shader files changed.
- Pillar 2 no-model source-ref record slice completed on 2026-06-14.
  `WorldObjectSpawnAdapter` now exposes a temporary
  `make_world_object_record_from_source_reference()` bridge. The Morrowind
  spawn adapter implements it and keeps the original source ref/base-record
  details in an adapter-owned payload cache. `CellManager` now uses that
  adapter record when a legacy async source ref has no model path, so that
  route enters the instantiation queue as a `WorldObjectRecord` instead of
  falling through to raw `CellReference` instantiation.
- Verification on 2026-06-14 for the no-model source-ref record slice:
  focused gdUnit `reports/report_29` ran 19 tests with 0 failures / 0 errors
  across `test_route_usage_stats`, `test_adapter_boundary`, and
  `test_streaming_modular_boundaries`. The new route test proves the converted
  no-model source-ref case increments `world_object_record_calls` and leaves
  `source_reference_calls` at 0 while the spawn adapter sees its owned payload.
  `reports/report_31` also shows the new Morrowind spawn-adapter payload-cache
  test passing, but that broader suite still has a separate fake-record
  carryable-registry error in `test_morrowind_spawn_adapter_routes_node_payload`,
  so it is not recorded as a clean suite. The changed-path smoke launched
  `tests/visual/test_interior_transition.tscn -- --auto-test` and exited 0;
  `reports/spring_cleanup_pillar2_source_ref_record_smoke.log` was empty, so
  this remains a crash/exit smoke like the previous parser-tail slice. No C#
  files changed, so `dotnet build` was not required. No shader/import cache
  artifacts were cleared because no shader files changed.
- Pillar 2 model-backed delayed source-ref record slice completed on
  2026-06-15. Delayed legacy source refs that wait for model availability now
  carry the same adapter-owned `WorldObjectRecord` payload before entering the
  instantiation queue. This covers both payload model-load callbacks and the
  provider-conversion `_queue_references_for_model()` path. The practical
  effect is that model-backed source refs no longer need to fall back through
  raw `CellReference` instantiation once their model is ready.
- Verification on 2026-06-15 for the model-backed delayed source-ref slice:
  focused gdUnit `reports/report_34` ran 20 tests with 0 failures across
  `test_route_usage_stats`, `test_adapter_boundary`, and
  `test_streaming_modular_boundaries`. The new route test proves the
  model-backed delayed source-ref case increments `world_object_record_calls`
  and leaves `source_reference_calls` at 0 after model readiness. The changed
  path smoke launched `tests/visual/test_interior_transition.tscn --
  --auto-test`; the process returned successfully, but the capture log
  `reports/spring_cleanup_pillar2_model_ref_record_smoke.log` was empty and a
  leftover Godot debug process had to be closed manually, so this is recorded
  as a crash/exit smoke rather than a logged transition verdict. No C# files
  changed, so `dotnet build` was not required. No shader/import cache artifacts
  were cleared because no shader files changed.
- Pillar 2 sync source-ref record slice completed on 2026-06-15. The
  synchronous parser-cell loops now wrap parser refs into adapter-owned
  `WorldObjectRecord` payloads before instantiation. This covers
  `_instantiate_cell()`, `load_characters_into_cell()`, and the MultiMesh
  fallback path, so sync interior/source-cell loads no longer call raw
  `ReferenceInstantiator.instantiate_reference()` for those refs. The helper
  accepts the source ref as `Variant`, keeping the generic-core `CellReference`
  boundary ledger from expanding.
- Verification on 2026-06-15 for the sync source-ref record slice: focused
  gdUnit `reports/report_37` ran 21 tests with 0 failures across
  `test_route_usage_stats`, `test_adapter_boundary`, and
  `test_streaming_modular_boundaries`. The new route test proves a sync
  interior parser-cell light increments `world_object_record_calls`, leaves
  `source_reference_calls` at 0, and lets the spawn adapter observe its cached
  source payload. The changed-path smoke launched
  `tests/visual/test_interior_transition.tscn -- --auto-test` and exited 0;
  `reports/spring_cleanup_pillar2_sync_ref_record_smoke.log` was empty, so this
  is recorded as a crash/exit smoke rather than a logged transition verdict. No
  C# files changed, so `dotnet build` was not required. No shader/import cache
  artifacts were cleared because no shader files changed.
- Pillar 2 async queue fallback source-ref record slice completed on
  2026-06-15. `CellManager.process_async_instantiation()` no longer calls
  `ReferenceInstantiator.instantiate_source_reference_result()` or
  `instantiate_reference()` when an async queue entry lacks a
  `WorldObjectRecord`. The drain now wraps that legacy `ref` through the
  injected spawn adapter into an adapter-owned `WorldObjectRecord`, then
  publishes through `instantiate_world_object_record_result()`.
- Verification on 2026-06-15 for the async queue fallback slice: focused
  gdUnit exited 0 for `test_route_usage_stats`, `test_adapter_boundary`, and
  `test_streaming_modular_boundaries`. The new route test forces a legacy
  ref-only queue entry and proves it increments `world_object_record_calls`,
  leaves `source_reference_calls` at 0, and lets the spawn adapter observe its
  cached source payload. A static scan now finds no
  `instantiate_source_reference_result()` / `instantiate_reference()` calls in
  `src/core/world/cell_manager.gd`; the remaining matches are the quarantined
  API in `ReferenceInstantiator` and direct unit tests. The changed-path smoke
  launched `tests/visual/test_interior_transition.tscn -- --auto-test`; the
  command exited 0 with empty capture log
  `reports/spring_cleanup_pillar2_queue_fallback_smoke.log`, and a leftover
  Godot process was closed manually afterward. No C# files changed, so
  `dotnet build` was not required. No shader/import cache artifacts were
  cleared because no shader files changed.
- Pillar 2 legacy source-reference API deletion slice completed on
  2026-06-15. `ReferenceInstantiator` no longer exposes
  `instantiate_reference()` or `instantiate_source_reference_result()`, and the
  dedicated `source_reference_calls` route counter was removed. The old private
  sync source-ref chain (`_instantiate_resolved_reference()`,
  `_instantiate_model_object()`, and `_instantiate_static_object()`) was
  deleted; framework publication now goes through `WorldObjectRecord` and the
  injected spawn adapter. Exact boundary ledgers were lowered for
  `CellManager` (`CellReference` 21 -> 20) and `ReferenceInstantiator`
  (`CellReference` 20 -> 15).
- The deletion smoke exposed a normalized-route parity bug: Morrowind
  adapter-owned light spawning still proximity-deferred small lights even when
  the instantiator reported static-renderer/proximity deferral disabled for
  interior pocket loads. `MorrowindObjectSpawnAdapter._is_light_proximity_deferred()`
  now mirrors the generic record gate and returns false when
  `is_source_static_renderer_effective()` is false. Without this, Arrille's
  Tradehouse could sit with two deferred lights and never satisfy the pocket
  load completion wait.
- Verification on 2026-06-15 for the legacy source-ref API deletion slice:
  focused gdUnit `reports/report_45` ran 21 tests with 0 failures across
  `test_route_usage_stats`, `test_adapter_boundary`, and
  `test_streaming_modular_boundaries`. A broader
  `test_morrowind_world_object_spawn_adapter` run generated `reports/report_43`;
  the new light-deferral regression test passed, while the suite still has the
  known unrelated fake-record carryable-registry error. The changed-path smoke
  launched `tests/visual/test_interior_transition.tscn -- --auto-test`;
  after the light gate fix it loaded Arrille's pocket in 820 ms and completed
  enter+exit cleanup in
  `reports/spring_cleanup_pillar2_legacy_ref_api_deleted_smoke_fixed.log`.
  The smoke still logged the existing transition-frametime `[FAIL]` verdicts
  (48.98 ms enter, 14.08 ms exit), so treat it as functional/crash proof, not
  a performance pass. No C# files changed, so `dotnet build` was not required.
  No shader/import cache artifacts were cleared because no shader files
  changed.
- Pillar 2 public spawn-adapter hook slice completed on 2026-06-15. Existing
  Morrowind-specific spawn hooks are now explicit public
  `WorldObjectSpawnAdapter` methods instead of private `_source_*` reach-through
  calls from `ReferenceInstantiator`: carryable classification,
  model-object postprocessing, actor postprocessing, and light-animation
  translation. The two generic instantiator hook wrappers now accept the
  migration ref as `Variant`, dropping the exact `ReferenceInstantiator`
  `CellReference` ledger from 15 to 13. `test_adapter_boundary` now includes a
  guard that fails if `ReferenceInstantiator` calls private `_source_*` adapter
  methods again.
- Verification on 2026-06-15 for the public spawn-adapter hook slice:
  focused gdUnit `reports/report_47` ran 22 tests with 0 failures across
  `test_adapter_boundary`, `test_streaming_modular_boundaries`, and
  `test_route_usage_stats`. An earlier broader spawn-adapter run
  `reports/report_46` showed the renamed door/light hook tests passing, while
  the suite still contains the known unrelated fake-record
  carryable-registry error. The changed-path smoke launched
  `tests/visual/test_interior_transition.tscn -- --auto-test`; the command
  exited 0 with empty capture log
  `reports/spring_cleanup_pillar2_public_spawn_hooks_smoke.log`, and a leftover
  Godot process was closed manually afterward. Treat it as crash/exit proof,
  not a logged transition verdict. No C# files changed, so `dotnet build` was
  not required. No shader/import cache artifacts were cleared because no shader
  files changed.
- Pillar 2 record-based visual-proxy identity slice completed on 2026-06-15.
  The Morrowind spawn adapter now asks `ReferenceInstantiator` to create,
  suppress, restore, and dirty render proxies from `WorldObjectRecord.source_key`
  instead of rebuilding proxy identity from parser-shaped `CellReference`
  fields. `ReferenceInstantiator` keeps the key-driven generic proxy mechanics,
  while adapter payloads remain the owner of parser refs. The old public
  ref-based proxy hook names are guarded against returning.
- Verification on 2026-06-15 for the record-proxy slice: focused gdUnit
  `reports/report_52` ran 23 tests with 0 failures across
  `test_adapter_boundary`, `test_route_usage_stats`, and
  `test_streaming_modular_boundaries`. Focused spawn-adapter run
  `reports/report_53` shows the two new proxy identity tests passing; that
  suite still has the known unrelated fake-record carryable-registry error in
  `test_morrowind_spawn_adapter_routes_node_payload`. The exact
  `ReferenceInstantiator` `CellReference` ledger dropped from 13 to 11. The
  changed-path transition smoke launched
  `tests/visual/test_interior_transition.tscn -- --auto-test`, exited 0, and
  left an empty capture log at
  `reports/spring_cleanup_pillar2_record_proxy_smoke.log`; a leftover Godot
  process was closed manually afterward. Treat this as crash/exit proof, not a
  logged transition verdict. No C# files changed, so `dotnet build` was not
  required. No shader/import cache artifacts were cleared because no shader
  files changed.
- Pillar 2 worker-tail record-identity slice completed on 2026-06-16. The
  parked Phase A worker-node path remains disabled by
  `PHASE_A_OFFTHREAD_INSTANTIATE=false`, but if it is ever re-enabled it now
  wraps legacy source refs into adapter-owned `WorldObjectRecord` payloads
  before dispatch. The worker and main-thread tail use the record transform,
  record metadata, and `WorldObjectRecord.source_key` for proxy identity
  instead of rebuilding identity from parser-shaped refs. The parser ref is
  still passed as a `Variant` only where Morrowind adapter postprocessing needs
  the source payload. The old `make_source_key()` helper was deleted, and the
  exact `ReferenceInstantiator` `CellReference` ledger dropped from 11 to 6.
- Verification on 2026-06-16 for the worker-tail slice: focused gdUnit
  `reports/report_54` ran 24 tests with 0 failures across
  `test_adapter_boundary`, `test_route_usage_stats`, and
  `test_streaming_modular_boundaries`. The changed-path transition smoke
  launched `tests/visual/test_interior_transition.tscn -- --auto-test`, exited
  0, and left an empty capture log at
  `reports/spring_cleanup_pillar2_worker_tail_record_smoke.log`; a leftover
  Godot process was closed manually afterward. Treat this as crash/exit proof,
  not a logged transition verdict. No C# files changed, so `dotnet build` was
  not required. No shader/import cache artifacts were cleared because no
  shader files changed.
- Pillar 2 source light/actor record-callback slice completed on 2026-06-16.
  `MorrowindObjectSpawnAdapter` now calls
  `ReferenceInstantiator.instantiate_source_light_record()` and
  `instantiate_source_actor_record()` with the active `WorldObjectRecord`
  instead of handing raw parser refs back to generic callback entry points.
  `ReferenceInstantiator` uses record transform, source key, object id, and
  record metadata for light/actor naming, placement, metadata, and visual
  identity. The adapter still owns the cached source-ref payload where
  Morrowind-specific door/container/carryable/NPC wrapping needs it.
  `ReferenceInstantiator`'s executable `CellReference` boundary count is now
  0, and `test_adapter_boundary` guards against restoring the old
  `instantiate_source_light()` / `instantiate_source_actor()` callbacks.
- Verification on 2026-06-16 for the light/actor callback slice: focused
  gdUnit `reports/report_58` ran 43 tests with 0 failures / 0 errors across
  `test_adapter_boundary`, `test_route_usage_stats`,
  `test_streaming_modular_boundaries`, and
  `test_morrowind_world_object_spawn_adapter`. A separate spawn-adapter rerun
  `reports/report_57` also passed 18/18 after the fake static-record fixture
  gained a `weight` field required by the existing carryable-registry test
  route. The changed-path transition smoke launched
  `tests/visual/test_interior_transition.tscn -- --auto-test`, exited 0, and
  left an empty capture log at
  `reports/spring_cleanup_pillar2_light_actor_record_smoke.log`; the leftover
  Godot process was closed manually afterward. Treat this as crash/exit proof,
  not a logged transition verdict. No C# files changed, so `dotnet build` was
  not required. No shader/import cache artifacts were cleared because no
  shader files changed.
- Pillar 2 retired ObjectStreamer parser-hook deletion slice completed on
  2026-06-16. `CellManager.get_cell_references()` and
  `instantiate_deferred_object()` were deleted after a repo-wide reference scan
  found no live callers. These methods belonged to the old per-object
  `ObjectStreamer` architecture and still forced exterior parser-cell access
  from generic `CellManager`; current streaming goes through
  `NativeStreamingManager`, `WorldCellManifest`, `WorldObjectRecord`, and the
  spawn adapter. `test_adapter_boundary` now guards that the retired
  `CellManager` hook names stay absent, and the exact `CellManager`
  `CellRecord` boundary ledger dropped from 9 to 8.
- Verification on 2026-06-16 for the retired ObjectStreamer hook deletion:
  baseline and post-edit focused gdUnit exited 0 for
  `test_adapter_boundary`, `test_route_usage_stats`, and
  `test_streaming_modular_boundaries`. Static scan finds no retired hook names
  in `src/core/world/cell_manager.gd`; remaining matches are the guard test and
  adapter-local `src/core/esm/native_esm_bridge.gd::get_cell_references()`.
  The changed-path transition smoke launched
  `tests/visual/test_interior_transition.tscn -- --auto-test`, exited 0, and
  left an empty capture log at
  `reports/spring_cleanup_pillar2_objectstreamer_hooks_deleted_smoke.log`.
  No lingering Godot process remained after recheck. No C# files changed, so
  `dotnet build` was not required. No shader/import cache artifacts were
  cleared because no shader files changed.
- Pillar 2 exterior character-toggle manifest slice completed on 2026-06-16.
  `CellManager.load_characters_into_cell()` now prefers an existing
  `WorldCellManifest` actor route before opening the quarantined exterior
  parser-cell bridge. Metadata-only exterior cells reuse the manifest attached
  to the cell node, actor records instantiate through the normalized
  `WorldObjectRecord` instantiator path, and spawned top-level children are
  tagged with `is_character` so the existing toggle-removal caller can find
  them. The parser-cell fallback remains only for cells without a manifest;
  named interior/pocket parser loading was deliberately left untouched.
- Verification on 2026-06-16 for the exterior character-toggle manifest slice:
  focused gdUnit `reports/report_65` ran `test_world_source_boundary` with
  16 tests, 0 failures, including the new manifest-backed character-toggle
  proof. Earlier focused gdUnit `reports/report_62` ran
  `test_adapter_boundary`, `test_route_usage_stats`, and
  `test_streaming_modular_boundaries` with 26 tests, 0 failures. Static marker
  scan still reports `CellManager` at `CellRecord` 8 and `CellReference` 20,
  so no exact boundary ledger was lowered. This slice did not edit C# files,
  but the shared worktree already had dirty C# files, so
  `dotnet build Godotwind.sln` was run and passed with 0 warnings / 0 errors.
  No shader/import cache artifacts were cleared because no shader files
  changed.
- Pillar 2 manifest sync result-envelope / stale wrapper slice completed on
  2026-06-16. `_instantiate_world_cell_manifest()` now consumes
  `ReferenceInstantiator.instantiate_world_object_record_result()` when
  available, matching the async publication path's explicit result envelope
  instead of reading `last_inst_route` for normal route classification. The
  unused `CellManager._apply_transform(node, ref: CellReference, ...)`
  wrapper was deleted after a repo scan found no live call sites; the remaining
  transform logic stays owned by `ReferenceInstantiator`.
- Verification on 2026-06-16 for the manifest result-envelope slice:
  `dotnet build Godotwind.sln` passed with 0 warnings / 0 errors. Focused
  gdUnit `reports/report_66` ran 42 tests with 0 failures / 0 errors across
  `test_adapter_boundary`, `test_route_usage_stats`,
  `test_world_source_boundary`, and `test_streaming_modular_boundaries`.
  Static marker scan reports `CellManager` at `CellRecord` 8 and
  `CellReference` 19, so the exact boundary ledger was lowered by one. The
  changed-path transition smoke launched
  `tests/visual/test_interior_transition.tscn -- --auto-test`, exited 0, and
  left an empty capture log at
  `reports/spring_cleanup_pillar2_manifest_result_smoke.log`. A leftover
  Godot process was observed immediately after the smoke command returned, but
  it exited before the close command ran; no lingering Godot process remained.
  No shader/import cache artifacts were cleared because no shader files
  changed.
- Pillar 2 sync exterior fallback manifest slice completed on 2026-06-16.
  `CellManager.load_exterior_cell()` still prefers an injected
  `WorldCellManifest` when the active `WorldObjectSource` can provide one. If
  that normalized route misses and the quarantined parser-cell bridge returns
  an exterior parser cell, `CellManager` now builds a transient
  `WorldCellManifest` from adapter-owned `WorldObjectRecord` payloads and
  publishes through `_instantiate_world_cell_manifest()` instead of handing the
  parser cell directly to `_instantiate_cell()`. The parser-cell bridge remains
  a temporary fallback; named interior/pocket parser loading was not changed.
  The exact `CellManager` `CellRecord` ledger dropped from 8 to 7 while
  `CellReference` stayed at 19.
- Verification on 2026-06-16 for the sync exterior fallback manifest slice:
  `dotnet build Godotwind.sln` passed with 0 warnings / 0 errors. Focused
  gdUnit `reports/report_67` ran 43 tests with 0 failures / 0 errors across
  `test_adapter_boundary`, `test_route_usage_stats`,
  `test_world_source_boundary`, and `test_streaming_modular_boundaries`. The
  new route test forces an exterior parser fallback with no world manifest and
  proves it still increments `world_object_record_calls`, keeps the retired
  `source_reference_calls` route absent, and attaches the transient
  `world_cell_manifest` metadata to the cell node. A main-world smoke launched
  `scenes/Godotwind.tscn` for 15 seconds, reached `_ready()` in 583 ms, and
  logged no script, parse, fatal, or exception errors; a lingering Godot process
  was closed afterward. Logs:
  `reports/spring_cleanup_pillar2_sync_exterior_manifest_smoke.out.log` and
  `.err.log`. Post-edit bloat scan reports `src-core` 609 files / 108740 lines
  and `tests-unit` 80 files / 9305 lines. No shader/import cache artifacts were
  cleared because no shader files changed.
- Pillar 2 metadata exterior fallback manifest slice completed on 2026-06-16.
  `CellManager.load_exterior_cell_metadata_only()` still prefers an injected
  `WorldCellManifest`. If that normalized route misses and the temporary
  parser-cell bridge returns an exterior parser cell, the metadata-only node
  now receives a transient `world_cell_manifest` made from adapter-owned
  `WorldObjectRecord` payloads instead of exposing raw `cell_record` metadata.
  This keeps metadata-only exterior containers and follow-up character toggles
  on the same normalized manifest identity contract when the parser fallback is
  the only source. The parser bridge itself remains temporary migration debt.
  The exact `CellManager` `CellRecord` ledger dropped from 7 to 6 while
  `CellReference` stayed at 19.
- Verification on 2026-06-16 for the metadata fallback slice:
  `dotnet build Godotwind.sln` passed with 0 warnings / 0 errors. Focused
  gdUnit `reports/report_68` ran 44 tests with 0 failures / 0 errors across
  `test_adapter_boundary`, `test_route_usage_stats`,
  `test_world_source_boundary`, and `test_streaming_modular_boundaries`. The
  new route test proves parser-backed metadata-only fallback attaches
  `world_cell_manifest`, does not attach `cell_record`, keeps
  `source_reference_calls` absent, and does not instantiate records while
  building metadata. A main-world startup smoke launched
  `scenes/Godotwind.tscn` for 15 seconds with world streaming disabled, reached
  `_ready()` in 646 ms, and matched no script, parse, fatal, or exception
  errors in the smoke logs:
  `reports/spring_cleanup_pillar2_metadata_manifest_smoke.out.log` and
  `.err.log`. A lingering Godot process was closed after the smoke.
  Post-edit bloat scan reports `src-core` 609 files / 108741 lines and
  `tests-unit` 80 files / 9332 lines. No shader/import cache artifacts were
  cleared because no shader files changed.
- Pillar 2 async exterior fallback manifest slice completed on 2026-06-17.
  `CellManager.request_exterior_cell_async()` still prefers an injected
  `WorldObjectSource` manifest first. If that normalized route misses and the
  temporary parser-cell bridge returns an exterior parser cell, the async
  fallback now builds a transient `WorldCellManifest` from adapter-owned
  `WorldObjectRecord` payloads and starts the async request with manifest
  records instead of storing the raw parser cell on `AsyncCellRequest`.
  The parser-cell bridge lookup remains quarantined migration debt, but the
  async exterior classification/static/collision publication lane now uses the
  same normalized record shape as the sync exterior fallback. The exact
  `CellManager` `CellRecord` ledger dropped from 6 to 5 while `CellReference`
  stayed at 19.
- Verification on 2026-06-17 for the async exterior fallback slice:
  focused gdUnit exited 0 across `test_adapter_boundary`,
  `test_route_usage_stats`, `test_world_source_boundary`, and
  `test_streaming_modular_boundaries`. The new route test proves the parser
  fallback request has `uses_world_manifest=true`, `cell_record=null`, one
  `world_objects_to_classify` record, `world_object_record_calls=1`, and no
  retired `source_reference_calls` route. `dotnet build Godotwind.sln` passed
  with 0 warnings / 0 errors because the shared worktree still has dirty C#
  files. A main-world startup smoke launched `scenes/Godotwind.tscn` for
  15 seconds, reached `_ready()` in 818 ms, left no lingering Godot process,
  and matched no script, parse, fatal, exception, or error lines in
  `reports/spring_cleanup_pillar2_async_exterior_manifest_smoke.out.log` and
  `.err.log`. Existing stderr warnings were the deprecated physics
  interpolation compatibility warning and a Terrain3D editor-texture warning.
  Post-edit bloat scan reports `src-core` 609 files / 108756 lines and
  `tests-unit` 80 files / 9360 lines. No shader/import cache artifacts were
  cleared because no shader files changed.
- The worktree had unrelated active runtime changes when Spring cleanup was
  set up. Continue to avoid touching unrelated dirty files.
- Pillar 2 retired ObjectPositionIndex deletion slice completed on
  2026-06-17. Repo-wide search found no runtime or unit-test callers for
  `src/core/world/object_position_index.gd`; only docs and the boundary ledger
  referenced it. The file lived in generic `src/core/world` but built directly
  from `ESMManager`, `CellRecord`, and `CellReference`, so it was uncalled
  boundary debt rather than a load-bearing framework contract. The slice
  deleted the script and `.uid`, removed its boundary allowances, and updated
  ObjectPaging docs to describe the active `WorldObjectSource`/manifest path.
  Focused boundary gdUnit exited 0, the post-edit bloat scan reported
  `src-core` 607 files / 108267 lines, and a capped main-world startup smoke
  reached `_ready()` in 614 ms with no matched script/parse/fatal/exception or
  error lines. No shader cache/import artifacts were cleared because no shader
  files changed.
- Pillar 2 static-render precompute boundary slice completed on 2026-06-17.
  `StaticObjectRenderer.precompute_instance()` now consumes an already
  normalized `Transform3D` plus source identity metadata instead of accepting a
  parser-shaped `CellReference` and doing Morrowind coordinate conversion
  inside the generic renderer. This keeps parser transform conversion in the
  quarantined `CellManager`/adapter-owned source-ref path while making the
  static renderer API source-neutral. The exact `StaticObjectRenderer`
  `CellReference` ledger dropped from 1 to 0.
- Verification on 2026-06-17 for the static-render precompute boundary slice:
  focused gdUnit `reports/report_72` ran 20 tests with 0 failures across
  `test_phase_e_precompute`, `test_adapter_boundary`, and
  `test_streaming_modular_boundaries`. `dotnet build Godotwind.sln` passed
  with 0 warnings / 0 errors. A main-world startup smoke launched
  `scenes/Godotwind.tscn` for 15 seconds, reached `_ready()` in 603 ms, left no
  lingering Godot process, and matched no script, parse, fatal, exception, or
  error lines in
  `reports/spring_cleanup_pillar2_static_precompute_transform_smoke.out.log`
  and `.err.log`. Existing stderr warnings were the deprecated physics
  interpolation compatibility warning and a Terrain3D editor-texture warning.
  Post-edit bloat scan reports `src-core` 607 files / 108258 lines and
  `tests-unit` 80 files / 9334 lines. No shader cache/import artifacts were
  cleared because no shader files changed.
- Pillar 2 Phase E precompute call-contract slice completed on 2026-06-17.
  The previous slice made `StaticObjectRenderer.precompute_instance()`
  source-neutral, but the worker call in `ReferenceInstantiator` still passed
  the old parser-ref argument shape through `call()`. `_worker_static_precompute`
  now converts the quarantined source ref to a plain `Transform3D` plus
  `ref_id` / `ref_num` before calling the renderer. The practical effect is
  that the Phase E worker path can actually use the renderer's new contract
  instead of falling back or passing mismatched arguments.
- Verification on 2026-06-17 for the Phase E call-contract slice: focused
  gdUnit `reports/report_74` ran 21 tests with 0 failures / 0 errors across
  `test_phase_e_precompute`, `test_adapter_boundary`, and
  `test_streaming_modular_boundaries`. The new test directly exercises
  `ReferenceInstantiator._worker_static_precompute()` and proves it passes
  `Vector2i`, `Transform3D`, `ref_id`, and `ref_num` to the renderer.
  `dotnet build Godotwind.sln` passed with 0 warnings / 0 errors because the
  shared worktree still has dirty C# files. A main-world startup smoke launched
  `scenes/Godotwind.tscn` for 15 seconds, reached `_ready()` in 774 ms, left no
  lingering Godot process, and matched no script, parse, fatal, or exception
  lines in
  `reports/spring_cleanup_pillar2_phase_e_precompute_contract_smoke.out.log`
  and `.err.log`. Stderr still contains existing shutdown resource/RID leak
  warnings plus `ERROR: 4 resources still in use at exit`; treat that as an
  existing shutdown caveat, not proof of a new Phase E failure. Post-edit
  bloat scan reports `src-core` 607 files / 108276 lines and `tests-unit`
  80 files / 9393 lines. No shader cache/import artifacts were cleared because
  no shader files changed.
- Pillar 2 light metadata boundary slice completed on 2026-06-17.
  `ReferenceInstantiator._attach_animated_omni_light()` no longer writes the
  unused `mw_radius` metadata key, and the stale comment that still described
  `mw_flags` now points at the source-neutral `light_animation` metadata
  contract. This removes the last exact `mw_` boundary marker from
  `ReferenceInstantiator`; `tests/unit/test_adapter_boundary.gd` now keeps
  that ledger at 0.
- Verification on 2026-06-17 for the light metadata slice: focused gdUnit
  `reports/report_75` ran 42 tests with 0 failures / 0 errors across
  `test_adapter_boundary`, `test_route_usage_stats`, and
  `test_morrowind_world_object_spawn_adapter`. Static grep found no
  `mw_`, `mw_radius`, or `mw_flags` markers in
  `ReferenceInstantiator`. The changed-path interior transition smoke loaded
  Arrille's Tradehouse with 16 lights, completed enter and exit cleanup, and
  matched no script, parse, fatal, exception, or `ERROR:` lines in
  `reports/spring_cleanup_pillar2_light_metadata_cleanup_smoke.out.log` and
  `.err.log`. The smoke kept the existing transition frametime `[FAIL]`
  caveat, and a rerun hit the known lingering-process cleanup quirk before
  producing useful logs. Post-edit bloat scan: `src-core` 607 files / 108273
  lines, `tests-unit` 80 files / 9393 lines. No C# files or shader files
  changed. Shader cache/import artifacts were not cleared.
- Pillar 2 light-scale marker cleanup completed on 2026-06-17.
  Deleted unused `CellManager.MW_LIGHT_SCALE` and renamed
  `ReferenceInstantiator.MW_LIGHT_SCALE` to `SOURCE_LIGHT_RADIUS_SCALE`.
  The light range math is unchanged; the practical effect is that generic
  world/runtime light code no longer carries that Morrowind-named constant.
  `test_adapter_boundary` now ratchets current broad marker counts for
  `CellManager` and `ReferenceInstantiator`.
- Verification on 2026-06-17 for the light-scale marker cleanup: focused
  gdUnit `reports/report_76` ran 42 tests with 0 failures / 0 errors across
  `test_adapter_boundary`, `test_route_usage_stats`, and
  `test_morrowind_world_object_spawn_adapter`. The changed-path interior
  transition smoke exited 0 and matched no script, parse, fatal, exception, or
  `ERROR:` lines in
  `reports/spring_cleanup_pillar2_light_scale_boundary_smoke.log`; the capture
  log was empty and the known lingering-process cleanup quirk occurred, so the
  smoke is crash/exit proof only. The lingering Godot process was closed
  afterward. Post-edit bloat scan: `src-core` 607 files / 108269 lines,
  `tests-unit` 80 files / 9393 lines. No C# files or shader files changed.
  Shader cache/import artifacts were not cleared.
- Pillar 2 static-render/ObjectPaging source-marker cleanup completed on
  2026-06-17. `StaticObjectRenderer` direct-RS fallback locals were renamed
  from `legacy_*_rid` to `direct_*_rid`, and inline `InstanceData` comments now
  describe source reference identity instead of ESM reference identity.
  `ObjectPaging` now logs empty HLOD chunks as having no source refs instead
  of no ESM refs. The practical effect is behavior-neutral: the active
  renderer/HLOD paths are unchanged, but these generic world files no longer
  carry broad source-specific marker debt from stale wording.
- Verification on 2026-06-17 for the static-render/ObjectPaging marker
  cleanup: local marker count found zero broad forbidden source markers in
  `src/core/world/static_object_renderer.gd` and
  `src/core/world/object_paging.gd`, and `test_adapter_boundary` now ratchets
  both files to 0. Focused gdUnit exited 0 across `test_adapter_boundary`,
  `test_static_object_renderer_bwide`, and
  `test_streaming_modular_boundaries`. HLOD benchmark smoke launched
  `tests/visual/test_hlod_benchmark.tscn` for 25 seconds, reached HLOD enabled
  plus benchmark recording, logged `[audit HLOD +5s] visual=2 ... merged=2`,
  and matched no script, parse, fatal, exception, or `ERROR:` lines in
  `reports/spring_cleanup_pillar2_static_renderer_object_paging_smoke.out.log`
  and `.err.log`. The capped smoke was closed after the observation window.
  Post-edit bloat scan: `src-core` 607 files / 108269 lines, `tests-unit`
  80 files / 9393 lines. No C# files or shader files changed. Shader
  cache/import artifacts were not cleared.
- Pillar 2 interior pocket broad-ratchet tightening completed on 2026-06-17.
  `InteriorPocketManager` executable-code broad source-marker debt was already
  down to 2 markers, but `test_adapter_boundary` still allowed 24. The test
  ratchet now matches the lower current count. This is a guard cleanup only:
  no runtime interior loading behavior changed, and named interior parser
  loading remains deferred until there is a normalized interior manifest or
  explicitly Morrowind-owned loading surface.
- Verification on 2026-06-17 for the interior pocket ratchet tightening:
  focused gdUnit `reports/report_78` ran 12 `test_adapter_boundary` tests with
  0 failures / 0 errors. No C# files, runtime files, or shader files changed,
  so no `dotnet build`, visual launch, or shader cache/import clearing was
  required. No Godot process was left running after the focused test.
- Pillar 2 impostor candidate archive-scan ownership slice completed on
  2026-06-17. `ImpostorCandidates` no longer scans BSA archives directly; it
  now remains the generic model-path classifier/hash/cache helper. New
  `MorrowindImpostorCandidates` owns the BSA-backed landmark/all-candidate
  catalog scan, and the prebake catalog builders now instantiate that
  Morrowind-owned subclass. The practical effect is that generic world code no
  longer reaches into `BSAManager` to discover source archive contents.
- Verification on 2026-06-17 for the impostor candidate archive-scan slice:
  focused gdUnit `reports/report_80` ran 24 tests with 0 failures / 0 errors
  across `test_adapter_boundary`, `test_streaming_modular_boundaries`, and
  `test_native_impostor_renderer_queue`. `test_adapter_boundary` now has an
  explicit guard proving the BSA catalog scan is Morrowind-owned. Marker scan:
  generic `src/core/world/impostor_candidates.gd` has `BSA=0`,
  `BSAManager=0`, and `Morrowind=0` in executable code; the Morrowind subclass
  carries the source-specific archive markers. Post-edit bloat scan reports
  `src-core` 607 files / 108130 lines, `src-morrowind-adapter` 59 files /
  8725 lines, and `tests-unit` 80 files / 9409 lines. A dedicated impostor
  stress scene launch returned 0 but did not honor its auto-duration/summary
  path in this shell and had to be closed manually, so treat that as
  launch-only evidence; the focused unit tests are the accepted proof for this
  non-behavioral ownership move. No C# or shader files changed, so no
  `dotnet build` or shader cache/import clearing was required.
- Pillar 2 impostor candidate profile ownership slice completed on
  2026-06-17. The remaining model-name pattern/profile policy moved out of
  generic `ImpostorCandidates` and into `MorrowindImpostorCandidates`.
  Generic `ImpostorCandidates` now only owns source-neutral candidate plumbing:
  explicit custom candidates, default bake settings, hashing, cache paths, and
  empty virtual pattern hooks. `MorrowindWorldSource` exposes the Morrowind
  candidate provider through `WorldSource.get_impostor_candidates()`, and
  `NativeStreamingManager`, `CellManager`, and `ReferenceInstantiator` forward
  that provider instead of constructing source policy in generic code. The
  impostor stress scene now uses `MorrowindImpostorCandidates`, so future FAR
  visual smoke still exercises the real Morrowind policy.
- Verification on 2026-06-17 for the impostor profile ownership slice:
  direct gdUnit `reports/report_83` ran 24 focused tests with 0 failures /
  0 errors across `test_adapter_boundary`,
  `test_streaming_modular_boundaries`, and
  `test_native_impostor_renderer_queue`. A short launch smoke of
  `tests/visual/test_impostor_stress.tscn` with
  `--auto-duration=3 --stamp=pillar2_impostor_policy` exited 0 after the scene
  was updated to instantiate `MorrowindImpostorCandidates`. A full accidental
  unit run at `reports/report_81` still has unrelated pre-existing hydrology,
  subsystem-toggle, and water-ripple failures; the focused changed-path report
  is `report_83`. Current code-count scan: `src-core-code` 341 files / 95991
  lines, `src-morrowind-adapter-code` 13 files / 4847 lines, and
  `tests-unit-code` 42 files / 7585 lines. No C# or shader files changed, so
  no `dotnet build` or shader cache/import clearing was required.
- Pillar 2 CellManager parser-class boundary cleanup completed on 2026-06-17.
  `CellManager` still owns the temporary injected parser-cell bridge, but it
  no longer names parser classes directly: all `CellRecord` / `CellReference`
  annotations and casts in the generic manager were replaced with typed
  `Variant` source-ref payloads at the migration boundary. Runtime behavior is
  unchanged; named interior/pocket parser loading remains deferred until there
  is a normalized interior manifest or explicitly Morrowind-owned loading
  contract. The exact `CellManager` ledger in `test_adapter_boundary` is now
  `CellRecord=0`, `CellReference=0`, `get_source_cell=0`, and
  `get_source_exterior_cell=0`.
- Verification on 2026-06-17 for the CellManager parser-class boundary slice:
  focused gdUnit `reports/report_84` ran 25 tests with 0 failures / 0 errors
  across `test_adapter_boundary` and `test_route_usage_stats`. Static grep
  found no `CellRecord` or `CellReference` hits in
  `src/core/world/cell_manager.gd`. The changed-path interior transition
  smoke launched `tests/visual/test_interior_transition.tscn -- --auto-test`
  and exited 0, left no lingering Godot process, and wrote an empty capture log
  at `reports/spring_cleanup_pillar2_cellmanager_variant_boundary_smoke.out.log`,
  so count it as crash/exit proof only. Post-edit bloat scan reports
  `src-core` 607 files / 107985 lines and `tests-unit` 80 files / 9420 lines.
  No C# files or shader files changed, so no `dotnet build` or shader
  cache/import clearing was required.
- Pillar 2 named interior space-manifest loading slice completed on 2026-06-17.
  The accepted architecture is the OpenMW-shaped split with Godotwind contracts:
  exterior spaces are grid-addressed, named interiors are `WorldSpaceHandle`
  spaces, and both load through normalized `WorldCellManifest` /
  `WorldObjectRecord` data. `WorldObjectSource.get_space_manifest()` is the new
  source-neutral lookup; `MorrowindWorldObjectSource` serves named interiors
  through its existing interior manifest builder; `CellManager` exposes
  `request_world_space_async()` and keeps `request_cell_async()` as a wrapper;
  `InteriorPocketManager` now requests pockets by `WorldSpaceHandle` instead of
  by raw cell-name async API. Runtime pocket transition metadata still keeps a
  parser payload through `TransitionProvider.get_transition_space_payload()` for
  door registration/environment until the next follow-up removes that surface.
- Verification on 2026-06-17 for the named interior space-manifest slice:
  focused gdUnit exited 0 across `test_adapter_boundary`,
  `test_route_usage_stats`, `test_world_source_boundary`, and
  `test_streaming_modular_boundaries`. The new route proof asserts a named
  interior `WorldSpaceHandle` request uses `uses_world_manifest=true`,
  `cell_record=null`, one manifest record, and `world_object_record_calls=1`.
  The changed-path interior transition smoke entered and exited Arrille's
  Tradehouse with no script, parse, fatal, exception, or `ERROR:` lines in
  `reports/spring_cleanup_pillar2_space_manifest_interior_smoke.out.log` and
  `.err.log`; its existing frametime verdict still logged `[FAIL]`, so count it
  as functional crash/regression proof, not performance acceptance. No C# or
  shader files changed, so no `dotnet build` or shader cache/import clearing
  was required. OpenMW source review also corrected the docs: exterior teleport
  `DNAM` is empty and exterior grid is resolved from `DODT` position.
- Pillar 2 parser-cell bridge deletion completed on 2026-06-17.
  `WorldSource` no longer exposes `parser_cell_bridge`, `MorrowindWorldSource`
  no longer installs `ParserCellBridge`, and `CellManager` no longer calls
  `get_source_cell` / `get_source_exterior_cell` or parser-cell fallback
  instantiation. Interior and exterior cell loading now enter `CellManager`
  through normalized `WorldCellManifest` data. The practical effect is that
  generic cell loading no longer has a parser-cell escape hatch; Morrowind
  parser access stays inside `MorrowindWorldObjectSource` and transition
  provider adapter code.
- Verification on 2026-06-17 for parser-cell bridge deletion: focused gdUnit
  `reports/report_96` ran 40 tests with 0 failures / 0 errors across
  `test_adapter_boundary`, `test_route_usage_stats`, and
  `test_world_source_boundary`. Static grep found the retired bridge symbols
  only in guard tests. `tests/visual/test_interior_transition.tscn --
  --auto-test` loaded Arrille's Tradehouse, entered, exited, and finished with
  final auto-test verdict `[PASS]`; it still logged one enter-transition
  frametime sample over threshold at 35.77 ms, so count the smoke as functional
  proof, not performance acceptance. Post-edit bloat scan reports `src-core`
  607 files / 107561 lines and `tests-unit` 80 files / 9385 lines. No C# or
  shader files changed, so no `dotnet build` or shader cache/import clearing
  was required.
- Pillar 2 DODT exterior target-space slice completed on 2026-06-17.
  `MorrowindTransitionProvider.get_interior_transition_portals()` now resolves
  empty/non-interior `DNAM` exterior targets from the placed ref's `DODT`
  arrival position using `CoordinateSystem.world_to_cell_grid()`. The
  practical effect is that an interior exit door now carries a real exterior
  `WorldSpaceHandle` key such as `-2,-9` instead of an empty exterior handle,
  while Morrowind coordinate logic stays inside the adapter.
- Verification on 2026-06-17 for the DODT target-space slice:
  `reports/report_97` shows `test_interior_transition_phase1` ran 9 tests with
  0 failures / 0 errors; the overall report also discovered unrelated unit
  suites with pre-existing failures outside the changed suite. The transition
  smoke entered Arrille's Tradehouse and exited back to exterior while logging
  `exit_to_exterior() called: '-2,-9'`. The first smoke produced final
  enter+exit `[PASS]`; the clean captured rerun exited 2 because the existing
  frametime threshold failed at 10.19 ms, but it still had no script, parse,
  fatal, or exception errors. Raw post-edit scan: `src-core` 666 files /
  112571 lines and `tests-unit` 80 files / 7599 lines. No C# or shader files
  changed, so no `dotnet build` or shader cache/import clearing was required.
- Pillar 2 transition-space info/environment slice completed on 2026-06-17.
  `TransitionProvider.get_transition_space_payload()` and the public
  `build_transition_environment()` hook are gone. Generic
  `InteriorPocketManager` now stores a source-neutral `TransitionSpaceInfo`
  with display/environment/quasi-exterior data, while
  `MorrowindTransitionProvider` privately resolves parser cells and converts
  Morrowind AMBI/quasi-exterior state into that neutral info. Interior portal
  enumeration now asks the provider by `WorldSpaceHandle` and pocket offset;
  the parser cell is no longer passed through or stored on pocket slots.
- Verification on 2026-06-17 for the transition-space info slice:
  `reports/report_101` shows `test_interior_transition_phase1` ran 10 tests
  with 0 failures / 0 errors, and `test_adapter_boundary` also ran clean. The
  unit runner still executed the whole unit directory, reported 8 unrelated
  failures elsewhere, and crashed after writing the XML with the existing
  shutdown/RID leak pattern. The changed-path smoke loaded Arrille's
  Tradehouse through `[POCKET] Space info found`, completed enter+exit, and
  logged `exit_to_exterior() called: '-2,-9'`; it exited 2 only because the
  existing frametime threshold failed, with no script, parse, fatal, or
  exception errors. Raw post-edit scan: `src-core` 667 files / 112544 lines
  and `tests-unit` 80 files / 7620 lines. No C# or shader files changed, so
  no `dotnet build` or shader cache/import clearing was required.
- Pillar 2 Morrowind terrain texture-loader ownership slice completed on
  2026-06-17. The LTEX slot loader moved from generic
  `src/core/world/terrain_texture_loader.gd` to
  `src/core/world/morrowind/morrowind_terrain_texture_loader.gd` and is now
  named `MorrowindTerrainTextureLoader`. `MorrowindDataProvider`,
  `world_explorer`, prebaking, terrain labs, and terrain visual tests now
  preload the adapter-owned loader. `test_adapter_boundary` no longer carries
  a generic-world allowance for `terrain_texture_loader.gd`; the strict-typing
  suppression ledger follows the adapter file. Practical effect: Morrowind
  LTEX/PBR texture translation is no longer housed as a generic world helper.
- Verification on 2026-06-17 for the Morrowind terrain texture-loader slice:
  focused gdUnit `reports/report_103` ran 21 tests with 0 failures / 0 errors
  across `test_adapter_boundary`, `test_core_strict_typing_policy`, and
  `test_morrowind_terrain_index_map`. `tests/visual/test_terrain_baking.tscn`
  loaded BSA/ESM data, loaded 31 terrain textures through the new adapter path,
  and imported terrain regions before the smoke window was closed. It logged no
  script, parse, fatal, or exception errors; existing warnings remain for the
  deprecated physics-interpolation compatibility shim, Terrain3D's 32-slot
  texture cap, and unmapped texture-index fallback. No C# or shader files
  changed, so no `dotnet build` or shader cache/import clearing was required.
- Pillar 2 Morrowind terrain-manager ownership slice completed on 2026-06-17.
  `MorrowindTerrainManager` now lives at
  `src/core/world/morrowind/morrowind_terrain_manager.gd` and owns
  LAND-to-height/control/color map generation plus Terrain3D region import.
  The generic `src/core/world/terrain_manager.gd` is now only source-neutral
  Terrain3D region math. Morrowind terrain callers in `MorrowindDataProvider`,
  `world_explorer`, prebaking, terrain preprocessing, and terrain visual tests
  preload the adapter path.
- Verification on 2026-06-17 for the terrain-manager ownership slice:
  focused gdUnit `reports/report_106` ran 22 tests with 0 failures / 0 errors
  across `test_adapter_boundary`, `test_core_strict_typing_policy`, and
  `test_morrowind_terrain_index_map`. Static scan found no `LandRecord`,
  `ESMManager`, `LAND`, `LTEX`, `Morrowind`, or `mw_` markers in generic
  `terrain_manager.gd`. `tests/visual/test_terrain_baking.tscn` imported 94/94
  terrain regions through `MorrowindTerrainManager`, saved terrain, and reached
  horizon baking 50/60 before the capped smoke was closed. Logs at
  `reports/spring_cleanup_pillar2_terrain_manager_smoke.*.log` had no script,
  parse, fatal, exception, crash, or `ERROR:` matches. Existing warnings remain
  for the deprecated physics-interpolation compatibility shim, Terrain3D's
  32-slot LTEX cap, and unmapped texture-index fallback. No C# or shader files
  changed, so no `dotnet build` or shader cache/import clearing was required.
- Pillar 3 lane-timing evidence slice completed on 2026-06-18. The static
  observatory scan was rerun and regenerated `reports/performance_observatory_scan.*`.
  `AutoBenchRunner` now copies existing `NativeStreamingManager` phase timings,
  queue depths, and `CellManager.get_frame_inst_route_times()` buckets into
  autobench JSON samples/summaries. This is instrumentation only; no runtime
  streaming budgets, queue behavior, loading policy, cache policy, C# code, or
  renderer behavior changed. Current real-renderer reports:
  `user://benchmark_results/summary_2026-06-18_12-26-41.json`,
  `user://benchmark_results/benchmark_2026-06-18_12-26-41.csv`, and
  `user://benchmark_results/autobench_spring_pillar3_lane_timing_2026_06_18/bench_teleport.json`.
  Practical result: both `flythrough_streaming` and `fast_travel_streaming`
  identify `CellManager` instantiation/publication as the steady first
  bottleneck. Flythrough averaged 39.3 FPS / 25.46 ms, p95 31.29 ms, p99
  38.19 ms, max 91.51 ms; the streaming lane averaged 8.49 ms on active
  frames and `phase_inst` averaged 7.63 ms, with a 115.41 ms max in settle
  and a 21.15 ms run-segment max. The run segment also had a one-off
  `phase_queue` spike at 100.93 ms, so queue bookkeeping should be inspected
  but is not the steady cost. Fast travel averaged 52.9 FPS in the 20 s
  sample; `stream_total_ms` averaged 9.40 ms, `phase_inst` averaged 7.60 ms,
  `phase_unload` maxed at 8.83 ms on the first sample, and the instantiation
  queue climbed to 1748 after 20 s. Route buckets did not explain the whole
  `phase_inst` cost, so the next slice should inspect `CellManager`'s broader
  instantiation/publication path before choosing a code change.
- Verification on 2026-06-18 for the lane-timing instrumentation slice:
  focused gdUnit `test_auto_bench_runner.gd` and
  `test_performance_report_contract.gd` both exited 0. The first attempt ran
  them in parallel and left two Godot processes; they were closed and the tests
  were rerun sequentially, closing each lingering process before the next
  launch. The real-renderer autobench with
  `--bench-auto=spring_pillar3_lane_timing_2026_06_18 --start-cell=-3,-2`
  completed and wrote current `flythrough_streaming` and
  `fast_travel_streaming` evidence. No C# files changed, so no `dotnet build`
  was required. No `.glsl`, `.gdshader`, or `.gdshaderinc` files changed, so
  shader cache/import artifacts were not cleared.
- Pillar 3 loading attribution slice completed on 2026-06-18. The static
  observatory scan was rerun and regenerated
  `reports/performance_observatory_scan.*`. `LoadingBaselineReport` now
  summarizes first-playable warm-start attribution by source-data total/other,
  ESM native primary, GDScript ESM populate/supplement, BSA/cache, terrain,
  model/material warmup, inner-ring gate wait, and accumulated CellManager
  publication work inside that gate. `ESMManager` exposes the last load timing
  snapshot so the report no longer depends on scraping the ESM log line.
  Practical result from
  `user://benchmark_results/loading_baseline_warm_start_2026-06-18_13-13-10.json`:
  valid warm-start first playable reached in 36.359 s; source-data total
  8.364 s; ESM native primary 2.422 s; GDScript ESM populate/supplement
  4.820 s; BSA/cache 1.119 s; terrain 5.143 s; model/material warmup
  0.226 s; inner-ring gate wait 6.675 s; accumulated CellManager publication
  inside that gate 2.566 s; unattributed/other init 15.951 s. This is
  instrumentation/attribution only: no streaming budget, queue behavior, cache
  policy, terrain loading policy, or C# migration changed.
- Verification on 2026-06-18 for the loading attribution slice: focused gdUnit
  `test_loading_baseline_report.gd` exited 0 after closing a pre-existing
  Godot process and rerunning sequentially. The integrated warm-start launch
  `scenes/Godotwind.tscn -- --quit-after-ready=60 --loading-baseline=warm_start`
  exited 0 and wrote the attribution JSON above. No C# files changed, so
  `dotnet build` was not required. No shader files changed, so shader
  cache/import artifacts were not cleared.
- Pillar 3 startup attribution/preload slice completed on 2026-06-18. Online
  research confirmed the native Godot pattern is `ResourceLoader` background
  loading with status polling, main-thread SceneTree publication, and load-time
  pipeline evidence rather than custom loader threads. The startup report now
  splits first-playable attribution into engine scene ready, ready-to-init
  delay, source-data, terrain, model/cache index, init misc,
  post-init-to-boot-gate handoff, and inner-ring gate wait. `world_explorer`
  keeps the cheap model cache index but no longer synchronously calls
  `cell_manager.preload_common_models()` before streaming starts; first-cell
  model loads use the existing budgeted threaded `ResourceLoader` path. The
  accepted warm-start report is
  `user://benchmark_results/loading_baseline_warm_start_2026-06-18_13-51-59.json`:
  first playable 33.788 s, valid, `ready_to_init_async_start_ms=8.139 s`,
  `post_init_to_boot_gate_ms=6.273 s`, `inner_ring_gate_wait_ms=6.658 s`,
  `terrain_ms=4.166 s`, `gdscript_supplement_populate_ms=4.358 s`, and
  model/cache index 0.133 s. A direct `_init_async()` scheduling probe was
  rejected because it worsened first playable to 35.040 s. Focused
  `test_loading_baseline_report.gd` exited 0 after final code. No C# files or
  shader files changed, so no `dotnet build` or shader cache/import clearing
  was required.
- The preferred recurring entry point is the `spring-cleanup` skill, not pasted
  prompts.

## Next Best Action

Use the completed loading-speed attribution before runtime streaming
optimization:

1. Read `docs/audit/spring_cleanup_pillar_3_optimization_charter_2026_06_18.md`
   and `docs/audit/performance_observatory_state.md`.
2. Run
   `python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .`.
3. Treat the 2026-06-18 lane reports as the runtime-streaming baseline, but do
   not optimize runtime `CellManager` yet. Loading still compounds every later
   benchmark run, and the current valid warm-start first-playable report is
   33.788 s.
4. The next smallest loading slice is to split the 6.273 s
   `post_init_to_boot_gate_ms` bucket inside `world_explorer` /
   `NativeStreamingManager.set_camera()`, then decide whether the synchronous
   initial `_update_loaded_cells()` handoff can be bounded or moved without
   merely shifting the same work into the boot gate.
5. Then choose one named loading owner for a same-scenario before/after:
   ready-to-init delay (8.139 s), post-init camera/streaming handoff (6.273 s),
   terrain/horizon startup (4.166 s), GDScript ESM populate/supplement
   (4.358 s), or boot-gate wait/publication (6.658 s wall clock with 2.350 s
   accumulated CellManager publication work inside the gate).
6. Do not tune shared streaming budgets or migrate broad files to C# without
   a same-scenario warm-start report showing the chosen owner improving.
7. Keep the runtime streaming evidence in mind: `CellManager`
   instantiation/publication is the next runtime target after loading
   iteration time improves.
8. Keep the Pillar 2 guardrails: do not recreate parser-cell bridges or move
   Morrowind-specific source logic back into generic framework code.

## Useful Short Prompts

- `Spring cleanup, continue.`
- `Spring cleanup, start pillar 1.`
- `Spring cleanup, use agents for pillar 1.`
- `Spring cleanup, move to pillar 2.`
- `Spring cleanup, start Pillar 3 optimization.`
