# Spring Cleanup Pillar 2 Charter: Morrowind / Framework Boundary

Date: 2026-06-14

Scope: charter for the Spring cleanup Pillar 2 audit. This is an audit-first
document. It does not authorize broad framework rewrites or gameplay
genericization.

## Pillar Question

Can Godotwind's framework runtime be extended to another open-world source by
implementing source adapters, without fabricating Morrowind-shaped parser
records or touching generic core systems?

For this pillar, "framework boundary" means the runtime direction of
dependencies:

- Generic framework systems consume normalized contracts:
  `WorldSource`, `WorldCoordinateMapper`, `WorldObjectSource`,
  `WorldCellManifest`, `WorldObjectRecord`, `WorldDataProvider`,
  `WorldAssetProvider`, and `WorldObjectSpawnAdapter`.
- Morrowind adapter systems own ESM/ESP records, BSA archives, NIF/DDS quirks,
  LAND/LTEX conversion, Morrowind units/axes/cell size, SCVR/dialogue
  semantics, journal/disposition rules, and Morrowind-specific spawn wrapping.
- Migration bridges such as generic `get_source_cell`,
  `get_source_exterior_cell`, and parser-shaped `CellRecord` /
  `CellReference` routes are known debt, not accepted architecture.

## Inputs Reused

- `docs/audit/morrowind_framework_boundary_mega_audit_2026_05_21.md`
- `docs/audit/framework_morrowind_boundary_adr_2026_05_22.md`
- `docs/systems/adapter_boundary.md`
- `tests/unit/test_adapter_boundary.gd`
- `tests/unit/test_world_source_boundary.gd`
- `tests/unit/test_streaming_modular_boundaries.gd`
- `tests/unit/test_model_loader_asset_provider.gd`
- `tests/unit/test_morrowind_world_object_spawn_adapter.gd`
- `docs/audit/spring_cleanup_state.md`
- `docs/audit/bloat_control_state.md`
- `docs/STATUS.md`

Mechanical evidence collected for this charter:

- `git status --short`
- `python .agents/skills/bloat-control/scripts/bloat_scan.py --root .`
- Boundary marker scans over `src/core/world`, `src/core`, `src/tools`,
  `tests/unit`, `docs/audit`, and `docs/systems`
- Boundary-oriented gdUnit command:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd --add res://tests/unit/test_adapter_boundary.gd --add res://tests/unit/test_world_source_boundary.gd --add res://tests/unit/test_streaming_modular_boundaries.gd --continue`

The gdUnit runner generated a full unit report at `reports/report_9` despite
the boundary-oriented `--add` arguments. That report is generated evidence and
should remain untracked.

## Canonical Pattern

The canonical architecture is ports and adapters, also known as hexagonal
architecture: framework code owns source-neutral ports, while source packages
own adapters that translate parser/importer/gameplay-specific facts into those
ports.

The Godot-specific implementation pattern is composition-root injection plus
explicit provider objects. `world_explorer` / scene setup owns the active
source, then injects its mapper, object source, asset provider, spawn adapter,
terrain provider, water provider, and transition provider into runtime systems.
Autoloads remain global services only where they are intentionally global; the
Godot 4.6 documentation describes autoloads as always-loaded nodes accessible
from any scene, so they should not become an accidental source-selection
mechanism for generic managers.

This matches the May ADR: generic managers must fail clearly when required
providers are missing; they must not silently create a Morrowind source.

## Acceptance Bar

Pillar 2 is accepted at the world-runtime layer when all of the following are
true:

1. Generic world streaming can boot from an injected non-Morrowind source with
   its own `WorldCoordinateMapper`, object source, asset provider, spawn
   adapter, and terrain provider.
2. The active fake-source object path can classify and instantiate static,
   interactive, actor, light, and collision-capable records without
   `CellRecord`, `CellReference`, ESM records, BSA archives, or NIF conversion
   in generic code.
3. `CellManager` no longer calls generic `get_source_cell` or
   `get_source_exterior_cell` bridges for active runtime paths, or any
   remaining calls are explicitly quarantined behind a Morrowind-owned demo or
   migration surface with route counters.
4. `ReferenceInstantiator` no longer exposes a load-bearing parser-shaped
   `CellReference` tail for framework-owned routes; Morrowind-specific
   wrapping is owned by `MorrowindObjectSpawnAdapter`.
5. Boundary tests are exact enough that debt cannot swap shape while staying
   under a broad term-count budget.
6. La Palma remains valid as a terrain/world-scale source without object
   streaming capability, proving that terrain-only sources do not need to
   fabricate Morrowind object contracts.

Gameplay systems are outside this acceptance bar unless they block the
world-runtime proof. Weather, dialogue, journals, disposition, character
assembly, skeleton remaps, NIF text keys, and Morrowind-flavored UI text remain
real inventory, but they are not Pillar 2's first implementation target.

## Current State

Strong seams already exist:

- `WorldSource` separates source capabilities instead of requiring every source
  to provide terrain, objects, water, transitions, assets, and gameplay.
- `WorldObjectSource`, `WorldCellManifest`, and `WorldObjectRecord` are the
  active normalized object contracts.
- `WorldAssetProvider` moved model resource lookup and source-native parse /
  conversion ownership out of `ModelLoader`.
- `WorldObjectSpawnAdapter` owns Morrowind wrapping, carryable metadata, door
  behavior, actor/light handling, and source-reference base-record lookup.
- `CellPayload`, `CellStaticCollision`, `CellPreloader`, and
  `DistantLightManager` have already moved away from several direct
  Morrowind-parser dependencies.
- `MorrowindTransitionProvider` is now adapter-owned, and
  `InteriorPocketManager` consumes source-neutral transition descriptors.
- `LaPalmaDataProvider` remains the real non-Morrowind terrain/scale signal.

Known debt remains:

- `src/core/world/cell_manager.gd` still owns parser-shaped source-cell
  migration bridges and many `CellRecord` / `CellReference` routes.
- `src/core/world/reference_instantiator.gd` still exposes
  `instantiate_reference(ref: CellReference)` and several legacy helper paths.
- `src/core/world/terrain_manager.gd` still encodes LAND/control-map
  conversion in generic world paths.
- `src/core/world/impostor_candidates.gd` still owns Morrowind landmark/flora
  patterns and BSA/NIF scans.
- Boundary ratchets currently mix useful exact ledgers with broad source-word
  counts in docs/native/shader files.

## Current Test Signal

The 2026-06-14 boundary-oriented run produced a full unit report at
`reports/report_9`.

Useful passes:

- `test_streaming_modular_boundaries`: 5 tests, 0 failures.
- `test_model_loader_asset_provider`: 6 tests, 0 failures.
- Many provider seams and Spring cleanup owner-API guards passed in the same
  run.

Current red boundary signal:

- `test_adapter_boundary` failed because several files exceed broad forbidden
  source-marker baselines:
  `src/core/native_bridge.gd`,
  `src/core/shaders/effects/surface_refraction_compositor_effect.gd`,
  `src/core/shaders/effects/underwater_compositor_effect.gd`,
  `src/core/shaders/effects/waterline_compositor_effect.gd`,
  `src/core/water/surface_refraction_layer.gd`,
  `src/core/water/water_interaction_sim.gd`,
  `docs/STATUS.md`,
  `docs/plans/interior_exterior_transition_refactor_2026_05_30.md`,
  `src/native/NativeFactory.cs`,
  `src/native/NativeMorrowindHydrologyAtlasBuilder.cs`, and
  `src/core/water/shaders/ocean_boujie_experimental_common.gdshaderinc`.
- The exact world ledger also failed in the good direction for some files:
  `InteriorPocketManager` now has fewer `CellRecord` / `CellReference` /
  `ESMManager` markers than the ledger allows, and
  `ReferenceInstantiator` has one fewer `CellReference` marker than allowed.
  That means the ledger is stale after recent cleanup and should be lowered
  once the broader failures are triaged.
- `test_world_source_boundary` failed on the fake-source async visual-playable
  expectation and one sync exterior spawn assertion. This is the most important
  executable proof to triage before changing runtime boundary code.

Current bloat scan signal:

- Worktree diff at charter time: 653 changed files, +2214 / -199380.
- `src/core/world/cell_manager.gd`: 4838 lines.
- `src/core/world/native_streaming_manager.gd`: 3708 lines.
- `src/core/world/interior_pocket_manager.gd`: 2606 lines.
- `src/core/world/reference_instantiator.gd`: 2253 lines.
- `src/core/world/model_loader.gd`: 1732 lines.
- `src/native/NativeMorrowindHydrologyAtlasBuilder.cs`: 1304 lines.

The diff is already broad and dirty. Pillar 2 implementation must avoid
touching unrelated water, hydrology, transition, and report cleanup work.

## Evidence Plan

Pillar 2 audit should answer these in order:

1. Which red boundary tests are stale ratchets versus real architectural
   regressions?
2. Which generic runtime paths still need `CellRecord` / `CellReference` to
   stream active main-world or interior content?
3. Which `get_source_cell` / `get_source_exterior_cell` calls are still
   load-bearing after the current transition-provider work?
4. What is the smallest fake-source smoke that proves the active object route,
   not just isolated helper methods?
5. Does `NativeMorrowindHydrologyAtlasBuilder.cs` belong under the current
   adapter-boundary allowance, need a native adapter namespace rule, or need to
   move?
6. Are water/hydrology source markers genuine framework leaks, or Morrowind
   source-content comments that the current broad ratchet should not hard-fail?
7. Which docs are current authority and which should be excluded from hard
   ratchets in favor of explicit review notes?

Mechanical scans to run during the audit:

- `rg -n "get_source_cell|get_source_exterior_cell|CellRecord|CellReference|ESMManager|BSAManager|NIF|BSA|LAND|LTEX|mw_|Morrowind" src/core/world -g "*.gd"`
- `rg -n "get_source_cell|get_source_exterior_cell|source_base_record|get_source_base_record" src/core src/tools tests/unit docs/audit docs/systems`
- `rg -n "Morrowind|ESM|BSA|NIF|LAND|LTEX|CellReference|CellRecord|mw_" src/core/water src/core/shaders src/native docs/plans docs/STATUS.md`
- Current focused gdUnit boundary suite, then targeted reruns as each finding
  is classified.

## Cleanup Backlog

### Slice 1: Boundary Test Triage And Ledger Repair

Classify each current `test_adapter_boundary` failure as one of:

- real generic-framework leak,
- source-adapter/native-source code in an allowed but missing ownership bucket,
- comment/doc false positive,
- stale ledger that should be lowered because debt decreased.

Expected output: update `tests/unit/test_adapter_boundary.gd` only after each
failure has a written classification in the Pillar 2 audit. This is a test/doc
slice, not runtime cleanup.

Verification: focused `test_adapter_boundary`, plus `test_world_source_boundary`
if any fake-source expectations are touched.

### Slice 2: Fix Fake-Source World Runtime Proof

Triage and repair the two failing fake-source assertions in
`test_world_source_boundary` without weakening the proof. The target is not
"make the test green"; the target is to prove that a non-Morrowind source can
exercise the same active runtime route.

Verification: focused `test_world_source_boundary`, then the narrowest
runtime smoke only if runtime streaming behavior changes.

### Slice 3: Remove Or Quarantine Generic Source-Cell Bridges

Use route counters and the transition-provider state to decide whether
`CellManager._get_cell_record()` and `_get_exterior_cell_record()` can leave
generic runtime ownership, or whether one legacy route still needs a
Morrowind-owned bridge.

Verification: `test_route_usage_stats`, `test_streaming_modular_boundaries`,
`test_world_source_boundary`, then an interior-transition smoke if interior
routes change.

### Slice 4: Replace The Remaining `ReferenceInstantiator` Parser Tail

Continue the Pillar 1 result-envelope direction until remaining framework-owned
routes consume `WorldObjectRecord` / spawn-adapter descriptors instead of
`CellReference`.

Verification: route-specific unit tests, `test_morrowind_world_object_spawn_adapter`,
and a narrow main-world or interaction smoke for changed spawn behavior.

### Slice 5: Native And Water Source Ownership Classification

Decide whether hydrology/native/water source markers are:

- Morrowind adapter implementation that should live under an explicit adapter
  path/namespace rule,
- generic water framework code with source-specific comments or constants that
  should be rewritten,
- or broad-ratchet noise that should move out of the hard gate.

Verification: focused boundary tests only unless runtime files change.

## Do Not Touch Yet

- Do not genericize weather, dialogue, journal/disposition, character assembly,
  skeleton remaps, or NIF text-key systems in the first Pillar 2 implementation
  slice.
- Do not split `world_explorer.gd` as a boundary cleanup unless a concrete
  source-injection seam requires it.
- Do not add new provider layers such as a parallel terrain provider until
  La Palma or Morrowind terrain shows a real missing capability in
  `WorldDataProvider`.
- Do not lower broad ratchets just to get a green test run. Classify first,
  then lower only stale ledgers or false-positive scopes.
- Do not delete parser-shaped legacy routes until route counters and a focused
  smoke prove they are no longer load-bearing.

## First Cleanup Slice Decision

No runtime cleanup slice is safe from this charter alone.

There is a tiny test-only candidate: lower exact debt ledgers where
`InteriorPocketManager` and `ReferenceInstantiator` already reduced boundary
markers. However, that edit should wait until the broader `test_adapter_boundary`
failures are classified, because otherwise it hides the useful signal inside a
still-red test. The next session should therefore be a short Pillar 2 audit
triage, not an implementation cleanup.

## Boundary Failure Classification — 2026-06-14 Focused Run

Evidence: focused gdUnit run generated `reports/report_11` with
`test_adapter_boundary` at 7 tests / 15 failures and
`test_world_source_boundary` at 15 tests / 2 failures / 1 runtime error.

| Suite | Failure | Label | Decision |
|---|---|---|---|
| `test_adapter_boundary` | `src/core/native_bridge.gd` exceeded broad source-marker baseline. | Real framework leak | `NativeBridge` is generic core but exposes source-specific native parser/hydrology factories. Keep red for a later native/source-adapter ownership slice; do not lower this in Slice 1. |
| `test_adapter_boundary` | `src/core/shaders/effects/surface_refraction_compositor_effect.gd` exceeded broad source-marker baseline. | False-positive ratchet | Matches come from renderer terms such as `UNIFORM_TYPE`, not source-format ownership. The broad marker scan should be narrowed later; do not lower blindly in Slice 1. |
| `test_adapter_boundary` | `src/core/shaders/effects/underwater_compositor_effect.gd` exceeded broad source-marker baseline. | False-positive ratchet | Matches come from renderer `UNIFORM_TYPE` usage, not Morrowind/adapter coupling. |
| `test_adapter_boundary` | `src/core/shaders/effects/waterline_compositor_effect.gd` exceeded broad source-marker baseline. | False-positive ratchet | Matches come from renderer `UNIFORM_TYPE` usage, not source-specific runtime ownership. |
| `test_adapter_boundary` | `src/core/water/surface_refraction_layer.gd` exceeded broad source-marker baseline. | False-positive ratchet | The added marker is `legacy_` in a water-rendering source-mode name, not framework dependence on parser-shaped data. |
| `test_adapter_boundary` | `src/core/water/water_interaction_sim.gd` exceeded broad source-marker baseline. | False-positive ratchet | Matches come from renderer `UNIFORM_TYPE` usage, not source-specific runtime ownership. |
| `test_adapter_boundary` | `src/core/world/interior_pocket_manager.gd` has 0 `CellRecord` markers while ledger allows 7. | Stale ledger | Debt decreased; lower the exact ledger to 0. |
| `test_adapter_boundary` | `src/core/world/interior_pocket_manager.gd` has 0 `CellReference` markers while ledger allows 4. | Stale ledger | Debt decreased; lower the exact ledger to 0. |
| `test_adapter_boundary` | `src/core/world/interior_pocket_manager.gd` has 0 `ESMManager` markers while ledger allows 5. | Stale ledger | Debt decreased; lower the exact ledger to 0. |
| `test_adapter_boundary` | `src/core/world/reference_instantiator.gd` has 20 `CellReference` markers while ledger allows 21. | Stale ledger | Debt decreased; lower the exact ledger to 20. |
| `test_adapter_boundary` | `docs/STATUS.md` exceeded broad text baseline. | False-positive ratchet | Status documentation intentionally names source-specific shipped/debt areas. It should not be treated like runtime framework code. |
| `test_adapter_boundary` | `docs/plans/interior_exterior_transition_refactor_2026_05_30.md` exceeded broad text baseline. | False-positive ratchet | This is an architecture plan that intentionally explains the Morrowind-to-framework split. It needs doc-scope handling, not runtime cleanup. |
| `test_adapter_boundary` | `src/native/NativeFactory.cs` exceeded broad native baseline. | Allowed adapter/native ownership | Native source/parser factories are centralized here today. Needs an explicit native adapter ownership rule or later split, not a generic runtime rewrite in Slice 1. |
| `test_adapter_boundary` | `src/native/NativeMorrowindHydrologyAtlasBuilder.cs` exceeded broad native baseline. | Allowed adapter/native ownership | This is Morrowind adapter-owned native code in a missing ownership bucket. Keep classified for the native/water slice. |
| `test_adapter_boundary` | `src/core/water/shaders/ocean_boujie_experimental_common.gdshaderinc` exceeded broad shader baseline. | False-positive ratchet | Matches are `legacy_` shader compatibility names, not source parser/archive ownership. |
| `test_world_source_boundary` | `test_cell_manager_world_cell_async_uses_fake_records_without_legacy_cell` expected `is_async_visual_playable()` immediately after classification. | Fake-source proof bug | The active streaming route separates classification from model-request starts. The proof must drain the provider-resource lane once before asserting visual readiness. |
| `test_world_source_boundary` | `test_cell_manager_sync_exterior_uses_world_manifest_without_legacy_cell` could not find `fake:static:1` child and then dereferenced null. | Fake-source proof bug | Godot node names are not the object identity contract. The proof should find spawned nodes by generic object metadata instead of raw node name text. |

Smallest safe slice after this classification: update only the exact stale
ledger and the fake-source proof harness. Leave broad ratchet/native/water
ownership failures red until their scoped slice.

Post-slice verification: focused rerun generated `reports/report_13`.
`test_world_source_boundary` passed all 15 tests. In `test_adapter_boundary`,
`test_generic_world_boundary_markers_match_exact_debt_ledger` passed after the
ledger repair; the remaining 11 failures are the classified broad
ratchet/native/water/doc ownership findings above.

## Boundary Ratchet Scope Repair - 2026-06-14 Follow-up

The broad ratchet was narrowed after the classification pass so it no longer
mixes renderer/doc false positives with framework boundary leaks:

- Excluded the classified renderer false positives from the generic-core broad
  ratchet: `RenderingDevice.UNIFORM_TYPE` substring matches in compositor/water
  code and the `legacy_exclusion` water-rendering source-mode label.
- Excluded active status/transition plan prose from the outside-GDScript hard
  ratchet because those docs intentionally inventory source-specific shipped
  state, debt, and adapter ownership.
- Excluded the Boujie experimental shader compatibility variable names from
  the broad text ratchet; they are shader math compatibility names, not
  Morrowind/framework ownership.
- Ratcheted current native adapter ownership explicitly:
  `src/native/NativeFactory.cs` now uses its current count, and
  `src/native/NativeMorrowindHydrologyAtlasBuilder.cs` has an explicit native
  source-adapter allowance.

Verification: focused gdUnit rerun generated `reports/report_15` with
27 tests, 1 failure. `test_world_source_boundary` passed all 15 tests and
`test_streaming_modular_boundaries` passed all 5 tests. `test_adapter_boundary`
is down to one intentional red signal:
`src/core/native_bridge.gd` still exposes source-specific native parser and
hydrology factories from generic core.

Decision: do not lower `src/core/native_bridge.gd` in the broad generic-core
ratchet. It is real architecture debt, not a false positive. The next runtime
ownership slice should decide the canonical native port shape before moving
NIF/ESM/BSA/hydrology factory access out of the generic bridge.

## Native Bridge Ownership Slice - 2026-06-14

Implemented decision: split native service access by ownership while keeping
the existing C# `NativeFactory` architecture.

- `src/core/native_bridge.gd` is now source-neutral. It loads the C# factory,
  reports native availability, exposes generic factory helpers, and keeps
  generic native services such as terrain, binary reader, shore mask, and river
  mesh builders.
- Importer/adapter-owned wrappers now carry source-specific native method
  names: `src/core/nif/native_nif_bridge.gd`,
  `src/core/esm/native_esm_bridge.gd`, and
  `src/core/world/morrowind/morrowind_native_bridge.gd`.
- `NIFConverter`, `ESMManager`, the Morrowind hydrology prebaker/tests/visual
  lab, and `ObjectPagingKernel` were moved to the owned wrapper/public factory
  APIs. `ObjectPagingKernel` no longer reaches into `NativeBridge._factory`.
- `tests/unit/test_adapter_boundary.gd` lowered the
  `src/core/native_bridge.gd` broad source-marker ledger from 21 to 0 because
  the ownership move deleted the generic-core leak.

Verification:

- Focused gdUnit `reports/report_17`: 88 tests, 0 failures across
  `test_adapter_boundary`, `test_world_object_source`,
  `test_object_paging_kernel`, and `test_morrowind_terrain_index_map`.
- Temporary native bridge probe exited 0 after resolving generic, NIF, ESM, and
  Morrowind hydrology native services.
- `tests/visual/test_hlod_benchmark.tscn` ran for 45 seconds, loaded native C#
  and Morrowind, enabled HLOD, started benchmark recording, and logged HLOD
  audit progress through `merged=12 surfaces=707 refs=7279` with no script,
  parse, compile, fatal, or exception errors.
- No C# files changed, so `dotnet build` was not required. No shader/import
  cache artifacts were cleared because no shader files changed.

## Parser-Cell Bridge Quarantine - 2026-06-14

Implemented decision: quarantine the remaining parser-shaped cell fallback
behind an explicitly injected bridge instead of letting generic `CellManager`
call source-cell methods on the normalized `WorldObjectSource` port.

- `WorldSource` now exposes an optional `parser_cell_bridge`. This is a
  migration bridge for parser-shaped cells, not part of the normalized object
  streaming contract.
- `MorrowindWorldSource` owns the bridge implementation and delegates to the
  Morrowind object source's source-cell accessors.
- `CellManager._get_cell_record()` and `_get_exterior_cell_record()` now call
  `get_interior_cell_record()` / `get_exterior_cell_record()` on the injected
  parser bridge. `CellManager` no longer contains direct `get_source_cell` or
  `get_source_exterior_cell` calls.
- `NativeStreamingManager.set_world_source()` forwards the full source to an
  initialized `CellManager`, so the parser bridge updates alongside the mapper,
  asset provider, object source, and spawn adapter during source injection.
- Boundary and streaming tests now ratchet this: `CellManager` may still carry
  parser-shaped `CellRecord` / `CellReference` debt, but it cannot reach back
  through the `WorldObjectSource` port for source-cell access.

Verification:

- Focused gdUnit `reports/report_20`: 32 tests, 0 failures across
  `test_adapter_boundary`, `test_streaming_modular_boundaries`,
  `test_route_usage_stats`, and `test_world_source_boundary`.
- `tests/visual/test_interior_transition.tscn -- --auto-test` launched twice
  and exited 0 both times. The stdout/stderr capture files were empty, so this
  is recorded as a crash/exit smoke rather than a logged transition verdict.
- No C# files changed, so `dotnet build` was not required.
- No shader/import cache artifacts were cleared because no shader files
  changed.

Next slice: keep the parser-cell bridge temporary and continue route-by-route
work on the remaining `ReferenceInstantiator.instantiate_reference()` /
`CellReference` parser tail. Do not lower or delete parser-route ledgers until
route counters and a focused smoke prove the affected route is not
load-bearing.

## Source-Reference Result Envelope Slice - 2026-06-14

Implemented decision: reduce one more mutable side-channel dependency before
attempting parser-tail deletion.

- `ReferenceInstantiator.instantiate_source_reference_result()` now returns an
  `InstantiationResult` for the legacy source-ref path.
- `CellManager.process_async_instantiation()` now uses that result envelope for
  the legacy fallback and reads route, type, timing, static-data, and
  proximity-deferred diagnostics from the return value when available.
- This deliberately does not delete `instantiate_reference()` or any
  `CellReference` route. It makes the remaining route easier to migrate
  safely, because the queue drain now has the same return contract for
  normalized records and legacy refs.
- The production boundary marker count did not increase; the wrapper accepts a
  typed `Variant` and delegates to the existing quarantined function.

Verification:

- Focused gdUnit `reports/report_23`: 33 tests, 0 failures across
  `test_adapter_boundary`, `test_world_source_boundary`,
  `test_streaming_modular_boundaries`, and `test_route_usage_stats`.
- `test_route_usage_stats` now includes
  `test_reference_instantiator_source_reference_result_envelopes_diagnostics`.
- `tests/visual/test_interior_transition.tscn -- --auto-test` launched and
  exited 0. Captured stdout/stderr were empty, so this is a crash/exit smoke
  rather than a logged transition verdict.
- No C# files changed, so `dotnet build` was not required.
- No shader/import cache artifacts were cleared because no shader files
  changed.

Next slice: convert one legacy async source-ref queue case into a
`WorldObjectRecord` with adapter-owned spawn payload, then use route counters
and a narrow transition or main-world smoke before lowering parser-tail ledgers.

## No-Model Source-Ref Record Slice - 2026-06-14

Implemented decision: convert the smallest load-bearing legacy source-ref
queue case without deleting the parser tail.

- `WorldObjectSpawnAdapter` now has a temporary
  `make_world_object_record_from_source_reference()` bridge. This keeps the
  quarantine explicit: source-specific parser refs can be wrapped during
  migration, but generic core does not own their spawn payload semantics.
- `MorrowindObjectSpawnAdapter` implements the bridge and stores the source ref
  plus base record in an adapter-owned payload cache keyed by
  `adapter_payload_id`.
- `CellManager._classify_request_refs()` now sends no-model legacy source refs
  through that record bridge before `_queue_instantiation()`. The practical
  effect is that no-model lights/interactives use
  `instantiate_world_object_record_result()` and the spawn adapter, not the raw
  `CellReference` instantiation fallback.
- This deliberately does not lower the `CellReference` ledger yet. The parser
  route still exists for model-backed delayed refs, worker paths, and direct
  legacy sync routes.

Verification:

- Focused gdUnit `reports/report_29`: 19 tests, 0 failures / 0 errors across
  `test_route_usage_stats`, `test_adapter_boundary`, and
  `test_streaming_modular_boundaries`.
- The route test proves the converted no-model source-ref case increments
  `world_object_record_calls`, keeps `source_reference_calls` at 0, and lets
  the adapter observe its owned payload.
- `reports/report_31` includes a passing Morrowind adapter payload-cache test,
  but the larger `test_morrowind_world_object_spawn_adapter` suite still has a
  separate fake-record carryable-registry error outside this route.
- `tests/visual/test_interior_transition.tscn -- --auto-test` exited 0 with an
  empty capture log:
  `reports/spring_cleanup_pillar2_source_ref_record_smoke.log`.
- No C# files changed. No shader/import cache artifacts were cleared because no
  shader files changed.

Next slice: convert the model-backed delayed legacy source-ref path
(`references_to_process` and model-load callbacks) to carry an adapter-owned
`WorldObjectRecord` before queueing, then use route counters before lowering
parser-tail ledgers.

## Model-Backed Delayed Source-Ref Record Slice - 2026-06-15

Implemented decision: convert the next delayed parser-tail route without
deleting the remaining `CellReference` API.

- Disk-cache model callbacks now retain the resolved base record in their
  pending payload and convert legacy source refs into adapter-owned
  `WorldObjectRecord` payloads before queueing instantiation.
- Provider-conversion callbacks in `_queue_references_for_model()` now make the
  same conversion for legacy pending refs before queueing.
- The instantiation queue receives the normalized record for these model-backed
  delayed refs, so `ReferenceInstantiator.instantiate_world_object_record_result()`
  handles the route and `instantiate_source_reference_result()` is not used for
  the converted case.
- This still deliberately keeps the parser-cell bridge and direct
  `instantiate_reference()` API as migration debt for other load-bearing
  routes.

Verification:

- Focused gdUnit `reports/report_34`: 20 tests, 0 failures across
  `test_route_usage_stats`, `test_adapter_boundary`, and
  `test_streaming_modular_boundaries`.
- The new route test proves a model-backed delayed source ref increments
  `world_object_record_calls`, keeps `source_reference_calls` at 0, and lets
  the spawn adapter observe its cached source payload after model readiness.
- `tests/visual/test_interior_transition.tscn -- --auto-test` launched for the
  changed path and returned successfully. The capture log
  `reports/spring_cleanup_pillar2_model_ref_record_smoke.log` was empty, and a
  leftover Godot debug process was closed manually afterward, so this is
  recorded as a crash/exit smoke rather than a logged transition verdict.
- No C# files changed. No shader/import cache artifacts were cleared because no
  shader files changed.

Next slice: inspect remaining direct `instantiate_reference()` call sites and
convert one still-load-bearing synchronous/interior parser route to the
adapter-owned record path before lowering any `CellReference` ledgers.

## Sync Source-Ref Record Slice - 2026-06-15

Implemented decision: convert the synchronous parser-cell instantiation loops
without deleting the quarantined parser API.

- `CellManager` now has a local `_instantiate_source_reference_record()` helper
  that resolves a parser ref through the injected spawn adapter, builds the
  adapter-owned `WorldObjectRecord`, and calls
  `ReferenceInstantiator.instantiate_world_object_record()`.
- `_instantiate_cell()`, `load_characters_into_cell()`, and the MultiMesh
  fallback path now use that helper instead of calling
  `instantiate_reference()` directly.
- The helper accepts the source ref as `Variant`, so this slice did not expand
  the exact `CellReference` boundary ledger in generic core.
- The remaining direct runtime call in `CellManager` is the async queue
  fallback for entries that still lack a `WorldObjectRecord`; that is the next
  parser-tail target.

Verification:

- Focused gdUnit `reports/report_37`: 21 tests, 0 failures across
  `test_route_usage_stats`, `test_adapter_boundary`, and
  `test_streaming_modular_boundaries`.
- The new route test proves a sync interior parser-cell light increments
  `world_object_record_calls`, keeps `source_reference_calls` at 0, and lets
  the spawn adapter observe its cached source payload.
- `tests/visual/test_interior_transition.tscn -- --auto-test` launched for the
  changed path and returned successfully. The capture log
  `reports/spring_cleanup_pillar2_sync_ref_record_smoke.log` was empty, so this
  is recorded as a crash/exit smoke rather than a logged transition verdict.
- No C# files changed. No shader/import cache artifacts were cleared because no
  shader files changed.

Next slice: inspect the remaining async queue fallback to determine which
entries can still reach `instantiate_source_reference_result()` without a
`WorldObjectRecord`, then convert that route or prove it is dead before
lowering parser-tail ledgers.

## Async Queue Fallback Source-Ref Record Slice - 2026-06-15

Implemented decision: remove `CellManager`'s final async queue dependency on
the parser-reference result fallback.

- The async instantiation drain no longer calls
  `ReferenceInstantiator.instantiate_source_reference_result()` or
  `instantiate_reference()` when an entry lacks a `WorldObjectRecord`.
- Instead, the fallback resolves the source ref through the injected spawn
  adapter, builds the same adapter-owned `WorldObjectRecord` payload used by
  the earlier no-model/model-backed/sync slices, and publishes through
  `instantiate_world_object_record_result()`.
- The quarantined legacy `ReferenceInstantiator` parser API still exists for
  direct migration tests and remaining non-`CellManager` parser-tail cleanup,
  but generic queue publication no longer depends on it.
- This does not delete the parser-cell bridge or lower broad `CellReference`
  ledgers yet. It only removes the last known `CellManager` call site to the
  raw source-reference instantiation route.

Verification:

- Focused gdUnit command exited 0 for `test_route_usage_stats`,
  `test_adapter_boundary`, and `test_streaming_modular_boundaries`.
- The new route test forces a legacy queue entry with only `ref` and proves it
  increments `world_object_record_calls`, leaves `source_reference_calls` at 0,
  and lets the spawn adapter observe its cached source payload.
- Static scan now finds no `instantiate_source_reference_result()` or
  `instantiate_reference()` call sites in `src/core/world/cell_manager.gd`.
  Remaining matches are the quarantined API in
  `src/core/world/reference_instantiator.gd` and direct unit tests.
- `tests/visual/test_interior_transition.tscn -- --auto-test` launched for the
  changed path and the command exited 0 with an empty capture log:
  `reports/spring_cleanup_pillar2_queue_fallback_smoke.log`. A leftover Godot
  process remained after the command returned and was closed manually, so this
  remains a crash/exit smoke rather than a logged transition verdict.
- No C# files changed. No shader/import cache artifacts were cleared because no
  shader files changed.

Next slice: audit the remaining parser-tail ownership outside `CellManager`.
Start from `ReferenceInstantiator.instantiate_reference()` and direct
`CellReference` helper dependencies, then either move the legacy source-ref API
behind Morrowind adapter ownership or prove which remaining runtime owner still
needs it before lowering any ledgers.

## Legacy Source-Reference API Deletion Slice - 2026-06-15

Implemented decision: remove the public parser-reference instantiation entry
point now that route proof shows `CellManager` no longer calls it.

- Deleted `ReferenceInstantiator.instantiate_reference()` and
  `instantiate_source_reference_result()`.
- Deleted the now-unreachable private sync parser-reference chain:
  `_instantiate_resolved_reference()`, `_instantiate_model_object()`, and
  `_instantiate_static_object()`.
- Removed the dedicated `source_reference_calls` route counter. Route tests now
  guard that the legacy public methods and counter stay absent while converted
  `CellManager` routes still publish through `WorldObjectRecord`.
- Lowered exact boundary ledgers for current debt:
  `CellManager` `CellReference` 21 -> 20 and `ReferenceInstantiator`
  `CellReference` 20 -> 15.
- Fixed a parity bug exposed by the changed-path smoke: the Morrowind adapter
  light route now bypasses small-light proximity deferral whenever
  `is_source_static_renderer_effective()` is false, matching the old legacy
  behavior for interior/pocket loads.

Verification:

- Focused gdUnit `reports/report_45`: 21 tests, 0 failures across
  `test_route_usage_stats`, `test_adapter_boundary`, and
  `test_streaming_modular_boundaries`.
- Broader Morrowind spawn-adapter run `reports/report_43`: the new
  light-deferral regression test passed; the suite still contains the known
  unrelated fake-record carryable-registry error.
- `tests/visual/test_interior_transition.tscn -- --auto-test` loaded Arrille's
  pocket in 820 ms and completed enter+exit cleanup after the light gate fix.
  The smoke remains a functional/crash proof because its existing frametime
  verdict logged `[FAIL]`.
- No C# files changed, so `dotnet build` was not required. No shader/import
  cache artifacts were cleared because no shader files changed.

Next slice: move or shrink the remaining `ReferenceInstantiator` source-helper
methods typed on `CellReference`. The public legacy source-ref entry point is
gone; the remaining question is which helper behavior belongs in the Morrowind
spawn adapter and which is still generic spawn mechanics.

## Public Spawn-Adapter Hook Slice - 2026-06-15

Implemented decision: keep generic Godot spawn mechanics in
`ReferenceInstantiator`, but make source-specific wrapping an explicit public
adapter contract instead of a private `_source_*` reach-through.

- Added public hook methods to `WorldObjectSpawnAdapter` for source carryable
  classification, model-object postprocessing, actor postprocessing, and
  source light-animation translation.
- Updated `MorrowindObjectSpawnAdapter` to implement those public hooks and
  updated its tests to call the public names.
- Updated `ReferenceInstantiator` to call the public hook names and loosened
  the two hook-wrapper ref parameters from `CellReference` to `Variant`.
- Added a boundary guard so `ReferenceInstantiator` cannot resume calling
  private `_source_*` adapter methods.
- Lowered the exact `ReferenceInstantiator` `CellReference` ledger from 15 to
  13 after the ratchet reported the drop.

Verification:

- Focused gdUnit `reports/report_47`: 22 tests, 0 failures across
  `test_adapter_boundary`, `test_streaming_modular_boundaries`, and
  `test_route_usage_stats`.
- Broader Morrowind spawn-adapter run `reports/report_46` showed the renamed
  hook tests passing, while the suite still has the known unrelated fake-record
  carryable-registry error.
- `tests/visual/test_interior_transition.tscn -- --auto-test` exited 0 with an
  empty capture log at
  `reports/spring_cleanup_pillar2_public_spawn_hooks_smoke.log`; a leftover
  Godot process was closed manually. This is crash/exit proof, not a logged
  transition verdict.
- No C# files changed, so `dotnet build` was not required. No shader/import
  cache artifacts were cleared because no shader files changed.

Next slice: audit the visual-proxy/source-key helpers in
`ReferenceInstantiator` (`make_source_key`, `_ensure_visual_proxy_for_ref`,
`_suppress_visual_proxy_for_ref`). Decide whether proxy identity should come
from `WorldObjectRecord.source_key` / the source adapter instead of generic
`CellReference` fields.

## Record-Based Visual-Proxy Identity Slice - 2026-06-15

Implemented decision: proxy identity belongs to the normalized world-object
record, not to generic parser-ref key reconstruction.

- Replaced the public ref-based visual-proxy hook surface with record-based
  hooks:
  `ensure_source_visual_proxy_for_record`,
  and `apply_source_visual_proxy_runtime_for_record`. The adapter reads
  `WorldObjectRecord.source_key` directly when it only needs the key.
- `MorrowindObjectSpawnAdapter` now passes the active `WorldObjectRecord` to
  those hooks for proximity-deferred proxy creation and realized-node proxy
  suppression/restore. Container dirty marking uses the same
  `WorldObjectRecord.source_key`.
- `ReferenceInstantiator` now has one generic source-key proxy helper for
  static-renderer proxy creation/suppression. The remaining `make_source_key()`
  use in `complete_worker_instantiate()` is deliberately left as worker-tail
  migration debt until that route is converted or explicitly quarantined.
- `test_adapter_boundary` guards that the old ref-based proxy hooks do not
  return.
- Lowered the exact `ReferenceInstantiator` `CellReference` ledger from 13 to
  11 after the boundary ratchet confirmed the reduction.

Verification:

- Focused gdUnit `reports/report_52`: 23 tests, 0 failures across
  `test_adapter_boundary`, `test_route_usage_stats`, and
  `test_streaming_modular_boundaries`.
- Spawn-adapter gdUnit `reports/report_53`: the new record-proxy tests passed.
  The suite still has the known unrelated fake-record carryable-registry error
  in `test_morrowind_spawn_adapter_routes_node_payload`.
- `tests/visual/test_interior_transition.tscn -- --auto-test` exited 0 with an
  empty capture log at
  `reports/spring_cleanup_pillar2_record_proxy_smoke.log`; a leftover Godot
  process was closed manually. This is crash/exit proof, not a logged
  transition verdict.
- No C# files changed, so `dotnet build` was not required. No shader/import
  cache artifacts were cleared because no shader files changed.

Next slice: audit the remaining worker-tail/source-helper methods in
`ReferenceInstantiator` that still depend on `CellReference`
(`complete_worker_instantiate`, `_apply_metadata`, `_apply_transform`,
`_auto_play_nif_animation`, actor/light helpers). Decide whether the worker
tail can carry `WorldObjectRecord`, or document it as quarantined parser
migration debt until route conversion.

## Worker-Tail Record-Identity Slice - 2026-06-16

Implemented decision: the parked Phase A worker-node tail should carry the same
record identity as the active normalized queue path before anyone considers
re-enabling it.

- `CellManager._phase_a_dispatch_pass()` now wraps legacy source refs into an
  adapter-owned `WorldObjectRecord` before scheduling `_worker_instantiate()`.
- `_worker_instantiate()` uses `WorldObjectRecord.transform` and record
  metadata when the entry carries a record; the legacy parser metadata helper
  remains only as a fallback for non-record callers.
- `complete_worker_instantiate()` uses `WorldObjectRecord.source_key` for
  visual proxy suppression/restore instead of the removed `make_source_key()`
  parser-key helper. It still passes the source ref as `Variant` to the
  Morrowind spawn-adapter postprocess hook because that is still the adapter
  payload during migration.
- The exact `ReferenceInstantiator` `CellReference` ledger dropped from 11 to
  6, and `test_adapter_boundary` now guards against restoring parser-ref
  source-key generation in the worker tail.

Verification:

- Focused gdUnit `reports/report_54`: 24 tests, 0 failures across
  `test_adapter_boundary`, `test_route_usage_stats`, and
  `test_streaming_modular_boundaries`.
- `tests/visual/test_interior_transition.tscn -- --auto-test` exited 0 with an
  empty capture log at
  `reports/spring_cleanup_pillar2_worker_tail_record_smoke.log`; a leftover
  Godot process was closed manually afterward. This is crash/exit proof, not a
  logged transition verdict.
- No C# files changed, so `dotnet build` was not required. No shader/import
  cache artifacts were cleared because no shader files changed.

Next slice: audit the remaining source light/actor helper group in
`ReferenceInstantiator` (`_instantiate_light`, `_instantiate_actor`,
`_instantiate_actor_legacy`, `_create_actor_placeholder`, and
`_is_light_proximity_deferred`). Move only source-specific behavior that has a
clear adapter owner; keep generic Godot node mechanics in the instantiator.

## Source Light/Actor Record-Callback Slice - 2026-06-16

Implemented decision: source light/actor spawn callbacks should consume the
active `WorldObjectRecord` identity instead of handing parser-shaped refs back
to generic callback entry points.

- `MorrowindObjectSpawnAdapter` now calls
  `instantiate_source_light_record(record, light_record)` and
  `instantiate_source_actor_record(record, actor_record, actor_type)`.
- `ReferenceInstantiator` uses `WorldObjectRecord` transform/source id/object id
  for light and actor naming, placement, metadata, proximity identity, and
  visual identity. Raw parser refs remain only inside the Morrowind adapter
  payload cache for source-owned postprocessing.
- The old ref-based `instantiate_source_light()` and
  `instantiate_source_actor()` callback names are guarded against returning.
- The exact `ReferenceInstantiator` executable `CellReference` ledger dropped
  from 6 to 0. This closes the targeted `ReferenceInstantiator` parser-tail
  slice; remaining parser debt is now primarily in `CellManager` and other
  explicitly listed source-cell bridge areas.
- The broader spawn-adapter suite previously hit the known fake-record
  carryable-registry error. This slice fixed the test double by giving
  `FakeStaticRecord` the `weight` field expected when that fixture is routed as
  a Morrowind carryable `misc` record.

Verification:

- Focused gdUnit `reports/report_58`: 43 tests, 0 failures / 0 errors across
  `test_adapter_boundary`, `test_route_usage_stats`,
  `test_streaming_modular_boundaries`, and
  `test_morrowind_world_object_spawn_adapter`.
- Separate spawn-adapter rerun `reports/report_57`: 18 tests, 0 failures /
  0 errors.
- `tests/visual/test_interior_transition.tscn -- --auto-test` exited 0 with an
  empty capture log:
  `reports/spring_cleanup_pillar2_light_actor_record_smoke.log`. A leftover
  Godot process was closed manually afterward, so this is crash/exit proof
  rather than a logged transition verdict.
- No C# files changed, so `dotnet build` was not required.
- No shader/import cache artifacts were cleared because no shader files
  changed.

Next slice: audit the remaining load-bearing parser-cell bridge in
`CellManager` and its `CellRecord` / `CellReference` ledger group. Keep the
bridge quarantined until route counters, focused boundary tests, and a narrow
interior or main-world smoke prove a route can move fully to
`WorldCellManifest` / `WorldObjectRecord` or must stay Morrowind-owned.

## Retired ObjectStreamer Parser-Hook Deletion Slice - 2026-06-16

Implemented decision: delete the dead per-object deferred streaming hooks
before attempting a broader parser-cell bridge rewrite.

- `CellManager.get_cell_references()` and
  `instantiate_deferred_object()` were old `ObjectStreamer` API hooks. A
  repo-wide scan found no live callers; active cell streaming is owned by
  `NativeStreamingManager` and the world-manifest/source-ref queue paths.
- The deleted hooks still forced generic `CellManager` to read raw exterior
  parser cells for a per-object streamer that no longer exists. Removing them
  reduces parser-cell surface without changing the load-bearing interior or
  exterior streaming routes.
- `test_adapter_boundary` now guards that the retired `CellManager` method
  names stay absent.
- The exact `CellManager` `CellRecord` ledger dropped from 9 to 8. The
  remaining `CellRecord` / `CellReference` debt is still load-bearing or
  unclassified and should stay route-by-route.

Verification:

- Baseline and post-edit focused gdUnit exited 0 for
  `test_adapter_boundary`, `test_route_usage_stats`, and
  `test_streaming_modular_boundaries`.
- Static scan finds no `get_cell_references()` or
  `instantiate_deferred_object()` match in `src/core/world/cell_manager.gd`.
  Remaining matches are the guard test and adapter-local
  `src/core/esm/native_esm_bridge.gd::get_cell_references()`.
- Changed-path transition smoke launched
  `tests/visual/test_interior_transition.tscn -- --auto-test`, exited 0, and
  left an empty capture log:
  `reports/spring_cleanup_pillar2_objectstreamer_hooks_deleted_smoke.log`.
  No lingering Godot process remained after recheck.
- Post-edit bloat scan: `src-core` 609 files / 108626 lines;
  `tests-unit` 80 files / 9235 lines.
- No C# files changed, so `dotnet build` was not required.
- No shader/import cache artifacts were cleared because no shader files
  changed.

Next slice: audit exterior character toggling in
`CellManager.load_characters_into_cell()`. That path is still an exterior
parser-cell fallback even when a `WorldCellManifest` exists. Do not apply this
to named interior/pocket loading until there is a normalized interior manifest
or an explicit Morrowind-owned transition/loading contract for that route.

## Exterior Character-Toggle Manifest Slice - 2026-06-16

Implemented decision: manifest-backed exterior cells should toggle characters
from normalized actor records, not by re-opening the parser-cell bridge.

- `CellManager.load_characters_into_cell()` now checks the cell node's
  `world_cell_manifest` metadata first, then the active world object source's
  manifest, before falling back to `_get_exterior_cell_record()`.
- Manifest actor/NPC/creature records instantiate through
  `instantiate_world_object_record()`. This keeps the default exterior
  character-toggle path on `WorldCellManifest` / `WorldObjectRecord` instead of
  raw `CellRecord` / `CellReference`.
- Spawned top-level cell children are tagged with `is_character` so the
  existing world-explorer character toggle can remove the wrapper node on the
  next toggle.
- The parser-cell bridge remains as a quarantined fallback for cells without a
  manifest. Named interior and pocket loading were not changed because there is
  no normalized interior manifest contract yet.
- Route counters now separate `character_world_manifest_cells` from
  `character_source_exterior_cells`.
- The exact `CellManager` boundary ledger did not change: static scan still
  reports `CellRecord` 8 and `CellReference` 20.

Verification:

- Focused gdUnit `reports/report_65`: `test_world_source_boundary`, 16 tests,
  0 failures. The new test proves a metadata-only fake-source exterior cell
  toggles one manifest actor, restores the load flags, avoids a legacy
  exterior-cell lookup, and records the manifest route counter.
- Focused gdUnit `reports/report_62`: `test_adapter_boundary`,
  `test_route_usage_stats`, and `test_streaming_modular_boundaries`, 26 tests,
  0 failures.
- Earlier main-scene hotkey smoke attempts launched successfully but did not
  reliably deliver the toggle key to the Godot window, so they are not counted
  as proof for this slice.
- This slice did not edit C# files, but the shared worktree already had dirty
  C# files, so `dotnet build Godotwind.sln` was run and passed with 0 warnings
  / 0 errors.
- No shader/import cache artifacts were cleared because no shader files changed.

Next slice: continue `CellManager` parser-cell cleanup one route at a time.
Good candidates are remaining exterior sync/fallback/parser-loop routes where a
manifest or adapter-owned contract can be proven. Do not touch named
interior/pocket parser loading until an interior manifest or explicitly
Morrowind-owned loading contract exists.

## Manifest Sync Result-Envelope Slice - 2026-06-16

Implemented decision: keep manifest-backed sync exterior loading on the same
explicit publication contract as async world-object records, and delete one
stale parser-ref wrapper that no runtime route calls.

- `_instantiate_world_cell_manifest()` now calls
  `instantiate_world_object_record_result()` when available and reads route
  classification from that result envelope. This mirrors the async drain path
  and avoids treating `last_inst_route` as the primary contract for normalized
  manifest publication.
- Deleted the unused `CellManager._apply_transform(node, ref: CellReference,
  ...)` wrapper. A repo scan found no call sites; the real transform helper
  remains in `ReferenceInstantiator`, where worker-tail/source spawn mechanics
  still live.
- Lowered the exact `CellManager` `CellReference` ledger from 20 to 19 after
  the static marker count dropped. `CellRecord` remains at 8.
- Added a boundary guard so the retired `CellManager` transform wrapper does
  not return.

Verification:

- `dotnet build Godotwind.sln` passed with 0 warnings / 0 errors.
- Focused gdUnit `reports/report_66`: 42 tests, 0 failures / 0 errors across
  `test_adapter_boundary`, `test_route_usage_stats`,
  `test_world_source_boundary`, and `test_streaming_modular_boundaries`.
- Changed-path transition smoke launched
  `tests/visual/test_interior_transition.tscn -- --auto-test`, exited 0, and
  left an empty capture log:
  `reports/spring_cleanup_pillar2_manifest_result_smoke.log`. A leftover Godot
  process was observed immediately after the command returned but exited before
  it could be stopped; no lingering process remained.
- Post-edit bloat scan: `src-core` 609 files / 108693 lines; `tests-unit`
  80 files / 9270 lines.
- No C# behavior changed, but `dotnet build` was still run because the shared
  worktree has dirty C# files. No shader/import cache artifacts were cleared
  because no shader files changed.

Next slice: pick one remaining exterior parser fallback in `CellManager` and
prove whether it can move to `WorldCellManifest` / `WorldObjectRecord` or must
stay behind the parser-cell bridge. Good candidates remain parser-backed sync
exterior fallback, metadata/source exterior fallback, and static/collision/
MultiMesh parser loops. Do not touch named interior/pocket parser loading until
there is a normalized interior manifest or explicitly Morrowind-owned loading
contract.

## Sync Exterior Fallback Manifest Slice - 2026-06-16

Implemented decision: the sync exterior parser fallback can publish through the
same manifest/result-envelope route as normalized world cells, without changing
named interior or pocket parser loading.

- `load_exterior_cell()` still asks the injected `WorldObjectSource` for a
  `WorldCellManifest` first.
- If that normalized source misses and the quarantined parser-cell bridge
  returns an exterior parser cell, `CellManager` now builds a transient
  `WorldCellManifest` from adapter-owned `WorldObjectRecord` payloads, then
  calls `_instantiate_world_cell_manifest()`.
- The fallback still uses the parser-cell bridge to fetch the source cell; this
  remains migration debt, not a final framework contract. The improvement is
  that publication no longer hands the whole parser cell to `_instantiate_cell()`
  on this exterior route.
- Exact ledger update: `CellManager` `CellRecord` 8 -> 7. `CellReference`
  remains 19.
- Added a focused route test that forces the parser fallback with no
  `WorldObjectSource` manifest and proves `world_object_record_calls` is the
  publication route while `source_reference_calls` stays absent.

Verification:

- `dotnet build Godotwind.sln` passed with 0 warnings / 0 errors.
- Focused gdUnit `reports/report_67`: 43 tests, 0 failures / 0 errors across
  `test_adapter_boundary`, `test_route_usage_stats`,
  `test_world_source_boundary`, and `test_streaming_modular_boundaries`.
- Main-world smoke launched `scenes/Godotwind.tscn` for 15 seconds, reached
  `_ready()` in 583 ms, and logged no script, parse, fatal, or exception
  errors. Smoke logs:
  `reports/spring_cleanup_pillar2_sync_exterior_manifest_smoke.out.log` and
  `.err.log`. A lingering Godot process was closed after the smoke.
- Post-edit bloat scan: `src-core` 609 files / 108740 lines; `tests-unit`
  80 files / 9305 lines.
- No shader files changed, so no shader cache/import artifacts were cleared.

Next slice: continue the `CellManager` parser-cell cleanup route-by-route.
Good candidates are metadata/source exterior fallback or static/collision/
MultiMesh parser loops. Do not touch named interior/pocket parser loading until
there is a normalized interior manifest or explicitly Morrowind-owned loading
contract.

## Metadata Exterior Fallback Manifest Slice - 2026-06-16

Implemented decision: metadata-only exterior parser fallback should publish
normalized manifest metadata instead of exposing raw parser-cell metadata on
the cell node.

- `load_exterior_cell_metadata_only()` still asks the injected
  `WorldObjectSource` for a `WorldCellManifest` first.
- If that normalized source misses and the quarantined parser-cell bridge
  returns an exterior parser cell, `CellManager` now builds a transient
  `WorldCellManifest` from adapter-owned `WorldObjectRecord` payloads and
  attaches it as `world_cell_manifest` metadata.
- The metadata-only fallback no longer sets raw `cell_record` metadata. This
  prevents follow-up systems such as character toggling from depending on a
  parser-shaped node payload when a normalized manifest envelope can be built.
- The parser-cell bridge still exists and still fetches the exterior cell; this
  remains migration debt, not a final framework contract.
- Exact ledger update: `CellManager` `CellRecord` 7 -> 6. `CellReference`
  remains 19.
- Added focused route proof that forces the parser-backed metadata fallback and
  proves the node has `world_cell_manifest`, lacks `cell_record`, keeps
  `source_reference_calls` absent, and does not instantiate records during
  metadata-only loading.

Verification:

- `dotnet build Godotwind.sln` passed with 0 warnings / 0 errors.
- Focused gdUnit `reports/report_68`: 44 tests, 0 failures / 0 errors across
  `test_adapter_boundary`, `test_route_usage_stats`,
  `test_world_source_boundary`, and `test_streaming_modular_boundaries`.
- Main-world smoke launched `scenes/Godotwind.tscn` for 15 seconds with world
  streaming disabled, reached `_ready()` in 646 ms, and matched no script,
  parse, fatal, or exception errors in
  `reports/spring_cleanup_pillar2_metadata_manifest_smoke.out.log` and
  `.err.log`. A lingering Godot process was closed after the smoke.
- Post-edit bloat scan: `src-core` 609 files / 108741 lines; `tests-unit`
  80 files / 9332 lines.
- No shader files changed, so no shader cache/import artifacts were cleared.

Next slice: continue the `CellManager` parser-cell cleanup route-by-route.
Good candidates are static/collision/MultiMesh parser loops that can move to
`WorldCellManifest` / `WorldObjectRecord` payloads or be explicitly
quarantined. Do not touch named interior/pocket parser loading until there is a
normalized interior manifest or explicitly Morrowind-owned loading contract.

## Async Exterior Fallback Manifest Slice - 2026-06-17

Implemented decision: async exterior parser fallback should classify the same
transient manifest records as the sync exterior fallback instead of storing a
raw parser cell on `AsyncCellRequest`.

- `request_exterior_cell_async()` still tries the injected
  `WorldObjectSource.get_cell_manifest()` route first.
- If that misses and the quarantined parser-cell bridge returns an exterior
  parser cell, `CellManager` now builds a transient `WorldCellManifest` from
  adapter-owned `WorldObjectRecord` payloads and starts the async request with
  `uses_world_manifest=true`.
- This moves the async exterior classification/static/collision publication
  lane onto normalized records. The parser bridge itself remains temporary
  migration debt because the fallback still needs it to fetch the source cell.
- Exact ledger update: `CellManager` `CellRecord` 6 -> 5. `CellReference`
  remains 19.
- Added focused route proof that forces the parser fallback and proves the
  async request has `cell_record=null`, one manifest record to classify,
  `world_object_record_calls=1`, and no retired `source_reference_calls`.

Verification:

- Focused gdUnit exited 0 across `test_adapter_boundary`,
  `test_route_usage_stats`, `test_world_source_boundary`, and
  `test_streaming_modular_boundaries`.
- `dotnet build Godotwind.sln` passed with 0 warnings / 0 errors because the
  shared worktree still has dirty C# files.
- Main-world smoke launched `scenes/Godotwind.tscn` for 15 seconds, reached
  `_ready()` in 818 ms, left no lingering Godot process, and matched no script,
  parse, fatal, exception, or error lines in
  `reports/spring_cleanup_pillar2_async_exterior_manifest_smoke.out.log` and
  `.err.log`. Existing stderr warnings were the deprecated physics
  interpolation compatibility warning and a Terrain3D editor-texture warning.
- Post-edit bloat scan: `src-core` 609 files / 108756 lines;
  `tests-unit` 80 files / 9360 lines.
- No shader files changed, so no shader cache/import artifacts were cleared.

Next slice: continue `CellManager` parser cleanup only where a route has clear
ownership proof. Exterior sync, metadata-only, async, and character-toggle
fallbacks now all repackage through transient manifests. The remaining obvious
debt is interior parser loading, which should not move until there is either a
normalized interior manifest contract or an explicitly Morrowind-owned loading
surface.

## Retired ObjectPositionIndex Deletion Slice - 2026-06-17

Implemented decision: delete the unused generic world `ObjectPositionIndex`
instead of preserving an uncalled Morrowind-shaped spatial index.

- Repo-wide search found no runtime or unit-test callers. Remaining references
  were the Pillar 2 charter, `docs/systems/object_paging.md`, and the boundary
  test allowance.
- The file lived in generic `src/core/world` but built directly from
  `ESMManager`, `CellRecord`, and `CellReference`. That made it boundary debt
  without current runtime proof value.
- Deleted `src/core/world/object_position_index.gd` and its `.uid`, removed the
  hard boundary allowance, and updated the ObjectPaging docs so HLOD continues
  to point at the active `WorldObjectSource`/manifest path.

Verification:

- Focused gdUnit exited 0 across `test_adapter_boundary`,
  `test_route_usage_stats`, `test_world_source_boundary`, and
  `test_streaming_modular_boundaries`.
- Post-edit bloat scan: `src-core` 607 files / 108267 lines;
  `tests-unit` 80 files / 9354 lines.
- Main-world startup smoke launched `scenes/Godotwind.tscn` for 15 seconds
  with world streaming disabled, reached `_ready()` in 614 ms, left no
  lingering Godot process, and matched no script, parse, fatal, exception, or
  error lines in
  `reports/spring_cleanup_pillar2_object_position_index_deleted_smoke.out.log`
  and `.err.log`. Existing stderr warnings were the deprecated physics
  interpolation compatibility warning and a Terrain3D editor-texture warning.
- No C# files changed, so `dotnet build` was not required. No shader files
  changed, so no shader cache/import artifacts were cleared.

Next slice: keep named interior parser loading deferred until an interior
manifest or explicitly Morrowind-owned loading surface exists. Continue Pillar
2 with another unused or adapter-owned boundary candidate rather than forcing
interior routes through a speculative contract.

## Static-Render Precompute Transform Slice - 2026-06-17

Implemented decision: the generic static renderer should consume normalized
rendering data, not parser refs.

- `StaticObjectRenderer.precompute_instance()` now takes a `Transform3D`,
  `ref_id`, and `ref_num` instead of a `CellReference`.
- The practical effect is that Morrowind coordinate conversion stays outside
  the generic renderer. The renderer only sees a world-space transform and
  identity metadata needed for promotion/debug lookup.
- `test_phase_e_precompute` now proves the precompute/add path preserves the
  supplied transform and ref metadata.
- The exact `StaticObjectRenderer` `CellReference` ledger dropped from 1 to 0.

Verification:

- Focused gdUnit `reports/report_72`: 20 tests, 0 failures / 0 errors across
  `test_phase_e_precompute`, `test_adapter_boundary`, and
  `test_streaming_modular_boundaries`.
- `dotnet build Godotwind.sln` passed with 0 warnings / 0 errors.
- Main-world startup smoke launched `scenes/Godotwind.tscn` for 15 seconds,
  reached `_ready()` in 603 ms, left no lingering Godot process, and matched no
  script, parse, fatal, exception, or error lines in
  `reports/spring_cleanup_pillar2_static_precompute_transform_smoke.out.log`
  and `.err.log`. Existing stderr warnings were the deprecated physics
  interpolation compatibility warning and a Terrain3D editor-texture warning.
- Post-edit bloat scan: `src-core` 607 files / 108258 lines; `tests-unit` 80
  files / 9334 lines.
- No shader files changed, so no shader cache/import artifacts were cleared.

Next slice: keep interior parser loading deferred. Good candidates are another
small source-neutral API cleanup or an unused/adapter-owned boundary candidate;
do not start a broad `ImpostorCandidates` or terrain path move without a
separate proof slice.

## Phase E Precompute Call-Contract Slice - 2026-06-17

Implemented decision: finish the static-render precompute boundary slice by
updating the worker call site to the renderer's new source-neutral contract.

- `ReferenceInstantiator._worker_static_precompute()` no longer passes
  `entry.ref` as the second argument to
  `StaticObjectRenderer.precompute_instance()`.
- The worker now converts the still-quarantined source ref to a plain
  `Transform3D` and passes source identity as `ref_id` / `ref_num`. The generic
  renderer continues to receive only rendering data.
- `test_phase_e_precompute` now directly guards the worker call contract with a
  fake renderer typed to the new signature.

Verification:

- Focused gdUnit `reports/report_74`: 21 tests, 0 failures / 0 errors across
  `test_phase_e_precompute`, `test_adapter_boundary`, and
  `test_streaming_modular_boundaries`.
- `dotnet build Godotwind.sln` passed with 0 warnings / 0 errors.
- Main-world startup smoke launched `scenes/Godotwind.tscn` for 15 seconds,
  reached `_ready()` in 774 ms, left no lingering Godot process, and matched no
  script, parse, fatal, or exception lines in
  `reports/spring_cleanup_pillar2_phase_e_precompute_contract_smoke.out.log`
  and `.err.log`. Stderr still reports existing shutdown resource/RID leak
  warnings and `ERROR: 4 resources still in use at exit`.
- Post-edit bloat scan: `src-core` 607 files / 108276 lines; `tests-unit`
  80 files / 9393 lines.
- No shader files changed, so no shader cache/import artifacts were cleared.

Next slice: keep interior parser loading deferred. Prefer another small
source-neutral API cleanup or unused/adapter-owned boundary candidate. The
shutdown resource leak observed during smoke is not a Pillar 2 ownership slice;
only take it up under a lifecycle/debugability cleanup.

## Light Metadata Boundary Slice - 2026-06-17

Implemented decision: generic animated-light nodes should expose only the
source-neutral light metadata that current systems read.

- `ReferenceInstantiator._attach_animated_omni_light()` no longer writes the
  unused `mw_radius` metadata key.
- The stale comment that still described `mw_flags` metadata now points at the
  active `light_animation` metadata consumed by `LightAnimator`.
- The exact `ReferenceInstantiator` `mw_` ledger dropped from 1 to 0.
- This did not change light animation behavior. Morrowind flag translation
  remains owned by `MorrowindObjectSpawnAdapter`, and generic light animation
  continues to read `WorldObjectRecord.LightAnimation` values.

Verification:

- Focused gdUnit `reports/report_75`: 42 tests, 0 failures / 0 errors across
  `test_adapter_boundary`, `test_route_usage_stats`, and
  `test_morrowind_world_object_spawn_adapter`.
- Static grep found no `mw_`, `mw_radius`, or `mw_flags` markers in
  `ReferenceInstantiator`.
- Interior transition smoke loaded Arrille's Tradehouse with 16 lights,
  completed enter and exit cleanup, and matched no script, parse, fatal,
  exception, or `ERROR:` lines in
  `reports/spring_cleanup_pillar2_light_metadata_cleanup_smoke.out.log` and
  `.err.log`. Existing transition frametime `[FAIL]` verdicts remain; a rerun
  hit the known lingering-process cleanup quirk before useful logs were
  produced.
- Post-edit bloat scan: `src-core` 607 files / 108273 lines; `tests-unit` 80
  files / 9393 lines.
- No C# files or shader files changed, so no dotnet build or shader cache
  clearing was required.

Next slice: keep interior parser loading deferred. Continue with another small
source-neutral API cleanup or unused/adapter-owned boundary candidate; avoid a
broad terrain or impostor move until there is a separate proof slice.

## Light-Scale Marker Slice - 2026-06-17

Implemented decision: remove source-specific light-scale naming from generic
world runtime code without changing light behavior.

- Deleted unused `CellManager.MW_LIGHT_SCALE`.
- Renamed `ReferenceInstantiator.MW_LIGHT_SCALE` to
  `SOURCE_LIGHT_RADIUS_SCALE`; both animated OmniLight3D and server-direct
  light paths still use `CS.SCALE_FACTOR` for range conversion.
- Lowered the current broad marker ratchets for `CellManager` and
  `ReferenceInstantiator` in `test_adapter_boundary`.

Verification:

- Focused gdUnit `reports/report_76`: 42 tests, 0 failures / 0 errors across
  `test_adapter_boundary`, `test_route_usage_stats`, and
  `test_morrowind_world_object_spawn_adapter`.
- Interior transition smoke exited 0 and matched no script, parse, fatal,
  exception, or `ERROR:` lines in
  `reports/spring_cleanup_pillar2_light_scale_boundary_smoke.log`. The capture
  log was empty and a lingering Godot process had to be closed manually, so
  count this as crash/exit proof only.
- Post-edit bloat scan: `src-core` 607 files / 108269 lines; `tests-unit`
  80 files / 9393 lines.
- No C# files or shader files changed, so no dotnet build or shader cache
  clearing was required.

Next slice: keep interior parser loading deferred. Continue with another small
source-neutral API cleanup or unused/adapter-owned boundary candidate.

## Static-Render/ObjectPaging Source-Marker Slice - 2026-06-17

Implemented decision: remove stale source-specific marker wording from generic
world rendering/HLOD code without changing behavior.

- `StaticObjectRenderer` direct-RS fallback locals are now
  `direct_mesh_rid` / `direct_material_rid` instead of `legacy_*_rid`.
- `StaticObjectRenderer.InstanceData` inline comments now describe source
  reference identity rather than ESM reference identity.
- `ObjectPaging` empty-HLOD debug logging now says "no source refs" instead of
  "no ESM refs".
- `test_adapter_boundary` ratchets the broad source-marker baselines for
  `src/core/world/static_object_renderer.gd` and
  `src/core/world/object_paging.gd` to 0.

This is a small wording/naming cleanup, not a renderer architecture change.
The practical effect is that the generic static renderer and HLOD pager no
longer preserve stale source-specific broad-marker debt after their active
contracts already moved to source-neutral IDs.

Verification:

- Local marker count found zero broad forbidden source markers in
  `src/core/world/static_object_renderer.gd` and
  `src/core/world/object_paging.gd`.
- Focused gdUnit exited 0 across `test_adapter_boundary`,
  `test_static_object_renderer_bwide`, and
  `test_streaming_modular_boundaries`.
- HLOD benchmark smoke launched `tests/visual/test_hlod_benchmark.tscn` for
  25 seconds, reached HLOD enabled plus benchmark recording, logged
  `[audit HLOD +5s] visual=2 ... merged=2`, and matched no script, parse,
  fatal, exception, or `ERROR:` lines in
  `reports/spring_cleanup_pillar2_static_renderer_object_paging_smoke.out.log`
  and `.err.log`. The capped smoke was closed after the observation window.
- Post-edit bloat scan: `src-core` 607 files / 108269 lines; `tests-unit`
  80 files / 9393 lines.
- No C# files or shader files changed, so no dotnet build or shader cache
  clearing was required.

Next slice: keep interior parser loading deferred. Continue with another small
source-neutral API cleanup or unused/adapter-owned boundary candidate. Do not
start broad terrain or impostor ownership moves without a separate proof slice.

## Interior Pocket Broad-Ratchet Slice - 2026-06-17

Implemented decision: tighten the boundary guard after existing interior pocket
cleanup lowered executable-code marker debt.

- `InteriorPocketManager` already had only 2 broad forbidden source markers in
  executable code.
- `test_adapter_boundary` still allowed 24 markers for that file, so the
  ratchet could hide future regression.
- Lowered only the test baseline from 24 to 2. No runtime code changed.

Verification:

- Focused gdUnit `reports/report_78`: 12 `test_adapter_boundary` tests, 0
  failures / 0 errors.
- No C# files, runtime files, or shaders changed, so no `dotnet build`, visual
  launch, or shader cache/import clearing was required.
- No Godot process was left running after the focused test.

Next slice: continue with another small source-neutral API cleanup, stale
ratchet, or unused/adapter-owned boundary candidate. Keep named interior parser
loading deferred until there is a normalized interior manifest or explicitly
Morrowind-owned loading surface.

## Impostor Candidate Archive-Scan Ownership Slice - 2026-06-17

Implemented decision: generic impostor candidate classification should not scan
Morrowind archives.

- `ImpostorCandidates` now keeps source-neutral responsibilities: classify a
  provided model path, resolve settings, and generate deterministic impostor
  cache paths/hashes.
- New `MorrowindImpostorCandidates` owns the BSA-backed landmark/all-candidate
  catalog scan.
- `prebaking_manager.gd` and `full_rebake_headless.gd` now use the Morrowind
  subclass when they need to discover the full source archive catalog.
- The generic helper still contains Morrowind-shaped pattern tables. That is
  the next real slice for this file: move the pattern/profile data behind a
  source-owned profile. Do not spend another slice on marker-only renames.

Verification:

- Focused gdUnit `reports/report_80`: 24 tests, 0 failures / 0 errors across
  `test_adapter_boundary`, `test_streaming_modular_boundaries`, and
  `test_native_impostor_renderer_queue`.
- `test_adapter_boundary` now explicitly proves the BSA catalog scan is
  Morrowind-owned.
- Marker scan: generic `src/core/world/impostor_candidates.gd` has `BSA=0`,
  `BSAManager=0`, and `Morrowind=0` in executable code. The Morrowind subclass
  carries the source-specific archive markers.
- Post-edit bloat scan: `src-core` 607 files / 108130 lines,
  `src-morrowind-adapter` 59 files / 8725 lines, `tests-unit` 80 files /
  9409 lines.
- A dedicated impostor stress scene launch returned 0 but did not honor its
  auto-duration/summary path in this shell and was closed manually; count it
  only as launch evidence, not accepted automated visual proof.
- No C# or shader files changed, so no `dotnet build` or shader cache/import
  clearing was required.

Next slice: either move the remaining Morrowind-specific pattern/profile data
out of the generic helper, or leave impostors and take another real Pillar 2
boundary. Keep named interior parser loading deferred.

## CellManager Parser-Class Boundary Slice - 2026-06-17

Implemented decision: generic `CellManager` should not name parser classes
directly while the parser-cell bridge remains quarantined.

- Replaced remaining concrete `CellRecord` / `CellReference` annotations and
  casts in `CellManager` with typed `Variant` source-ref payloads.
- Left runtime behavior unchanged: the injected parser-cell bridge still owns
  temporary parser access, exterior parser fallbacks still repackage through
  transient manifests, and named interior/pocket parser loading is still
  deferred until a normalized interior manifest or explicitly Morrowind-owned
  loading surface exists.
- Lowered the exact `CellManager` boundary ledger in `test_adapter_boundary`
  to `CellRecord=0` and `CellReference=0`.

Verification:

- Focused gdUnit `reports/report_84`: 25 tests, 0 failures / 0 errors across
  `test_adapter_boundary` and `test_route_usage_stats`.
- Static grep found no `CellRecord` or `CellReference` hits in
  `src/core/world/cell_manager.gd`.
- `tests/visual/test_interior_transition.tscn -- --auto-test` exited 0 and
  left no lingering Godot process. The capture log was empty, so count this as
  crash/exit proof only.
- Post-edit bloat scan: `src-core` 607 files / 107985 lines; `tests-unit`
  80 files / 9420 lines.
- No C# or shader files changed; no `dotnet build` or shader cache/import
  clearing was required.

Next slice: keep named interior parser loading deferred. Continue with another
small source-neutral API cleanup or unused/adapter-owned boundary candidate;
do not spend another slice on `CellManager` parser-class marker cleanup.

## Named Interior Space-Manifest Loading Slice - 2026-06-17

Implemented decision: named interiors are source-neutral world spaces, not a
separate parser-cell loading special case.

- `WorldObjectSource.get_space_manifest(space_handle)` is the generic lookup
  for non-grid spaces. The default implementation maps exterior grid handles
  back to `get_cell_manifest()`.
- `MorrowindWorldObjectSource` owns named interior manifest creation through
  its Morrowind adapter data and returns normalized `WorldObjectRecord`s for
  `WorldSpaceHandle.interior(name)`.
- `CellManager.request_world_space_async()` starts the existing manifest-backed
  async request path with `uses_world_manifest=true`; the old
  `request_cell_async(cell_name)` remains as a compatibility wrapper.
- `InteriorPocketManager` now requests pocket async loading by space handle.
  Transition metadata/environment still keep a parser payload from
  `TransitionProvider.get_transition_space_payload()` and should be the next
  focused boundary follow-up.
- OpenMW source review confirmed the model: exterior cells are grid-addressed,
  interiors are named, placed door refs own `DODT` arrival data, and exterior
  teleports leave `DNAM` empty. Godotwind docs were corrected so exterior
  target grids are derived from `DODT` position, not `DNAM` grid values.

Verification:

- Focused gdUnit exited 0 across `test_adapter_boundary`,
  `test_route_usage_stats`, `test_world_source_boundary`, and
  `test_streaming_modular_boundaries`.
- The new route test proves a named interior `WorldSpaceHandle` async request
  stores `cell_record=null`, sets `uses_world_manifest=true`, classifies one
  manifest record, and instantiates through `world_object_record_calls`.
- `tests/visual/test_interior_transition.tscn -- --auto-test` entered and
  exited Arrille's Tradehouse with no script, parse, fatal, exception, or
  `ERROR:` log lines. The existing frametime verdict still logs `[FAIL]`, so
  this is functional crash/regression proof, not performance acceptance.
- No C# or shader files changed; no `dotnet build` or shader cache/import
  clearing was required.

Next slice: either migrate transition-space payload/environment off parser
payloads, or fix Morrowind exterior target-space resolution from DODT position.
Do not broaden this into the full transition state-machine refactor in the same
slice.

## Parser-Cell Bridge Deletion Slice - 2026-06-17

Implemented decision: the generic world loader must not keep a parser-cell
escape hatch now that exterior and named interior spaces have normalized
manifest loading.

- Removed the `WorldSource.parser_cell_bridge` contract and the
  `MorrowindWorldSource.ParserCellBridge` adapter.
- Removed `CellManager` parser-cell lookup and fallback instantiation routes:
  no `get_source_cell`, no `get_source_exterior_cell`, no `_instantiate_cell`,
  and no parser-cell bridge setter/getter.
- `WorldObjectSource.get_space_manifest()` now routes interior
  `WorldSpaceHandle`s to `get_interior_cell_manifest()`, while exterior handles
  continue to route to `get_cell_manifest()`.
- `MorrowindWorldObjectSource` remains the adapter boundary for parser access:
  it builds exterior and named interior `WorldCellManifest`s and gives interior
  objects stable `interior:*` object ids.
- `CellManager.load_cell()`, `load_exterior_cell()`,
  `load_exterior_cell_metadata_only()`, character toggles, and async requests
  now consume manifest records only.

Verification:

- Focused gdUnit `reports/report_96`: 40 tests, 0 failures / 0 errors across
  `test_adapter_boundary`, `test_route_usage_stats`, and
  `test_world_source_boundary`. The process returned gdUnit exit 101 because
  the suites still report existing orphan/resource warnings, but the XML
  report is clean.
- Static grep found retired parser-cell bridge symbols only in guard tests.
- `tests/visual/test_interior_transition.tscn -- --auto-test` loaded
  Arrille's Tradehouse, entered, exited, and finished with final `[PASS]`.
  It still logged one enter-transition frametime sample over threshold
  (35.77 ms), so treat this as functional runtime proof, not performance
  acceptance.
- Bloat scan after the slice: `src-core` 607 files / 107561 lines,
  `tests-unit` 80 files / 9385 lines.
- No C# or shader files changed; no `dotnet build` or shader cache/import
  clearing was required.

Next slice: transition-space payload/environment migration is now the concrete
remaining parser-owned boundary. Keep it source-neutral and focused; do not
restore parser-cell loading in `CellManager`.

## DODT Exterior Target-Space Slice - 2026-06-17

Implemented decision: Morrowind exterior transition targets are grid-addressed
from placed-ref `DODT` arrival position, not from empty exterior `DNAM`.

- `MorrowindTransitionProvider.get_interior_transition_portals()` now maps
  empty/non-interior `teleport_cell` to `WorldSpaceHandle.exterior_grid()` via
  `CoordinateSystem.world_to_cell_grid(ref.teleport_pos)`.
- Interior exit descriptors now carry a real exterior grid key such as
  `-2,-9` instead of the previous empty exterior handle.
- The change stays adapter-owned. Generic transition descriptors and
  `InteriorPocketManager` did not gain Morrowind parser or coordinate logic.

Verification:

- `reports/report_97`: `test_interior_transition_phase1` ran 9 tests with 0
  failures / 0 errors. The overall report also discovered unrelated suites and
  still contains pre-existing failures outside the changed suite.
- The regression assertion proves an interior exit door with empty `DNAM` and
  DODT position inside Seyda Neen resolves `get_target_space_key()` to `-2,-9`.
- `tests/visual/test_interior_transition.tscn -- --auto-test` entered
  Arrille's Tradehouse and exited back to exterior with
  `exit_to_exterior() called: '-2,-9'`. The first run produced final
  enter+exit `[PASS]`; the clean captured rerun exited 2 because the existing
  frametime threshold marked the final 10.19 ms sample `[FAIL]`, but it had no
  script, parse, fatal, or exception errors and still exercised the corrected
  target-space key.
- Raw post-edit scan: `src-core` 666 files / 112571 lines and `tests-unit` 80
  files / 7599 lines.
- No C# or shader files changed; no `dotnet build` or shader cache/import
  clearing was required.

Next slice: transition-space payload/environment migration remains. The DODT
target-space fix is settled; do not broaden the next pass into the full
transition state-machine refactor.

## Transition-Space Info / Environment Slice - 2026-06-17

Implemented decision: generic transition runtime should consume source-neutral
space info, not parser cell payloads.

- Added `TransitionSpaceInfo` as the small neutral envelope for transition
  space display/environment/quasi-exterior data.
- Removed `TransitionProvider.get_transition_space_payload()` and the public
  `build_transition_environment()` parser-payload hook.
- `InteriorPocketManager` now stores `space_info` on pocket slots and asks the
  provider for interior portal descriptors by `WorldSpaceHandle` plus pocket
  offset. It no longer stores or passes parser cells.
- `MorrowindTransitionProvider` privately resolves source cells from its
  adapter-owned object source and converts Morrowind AMBI/quasi-exterior data
  into the neutral `TransitionSpaceInfo.environment`.

Verification:

- `reports/report_101`: `test_interior_transition_phase1` ran 10 tests with 0
  failures / 0 errors, and `test_adapter_boundary` also ran clean. The unit
  runner still scanned the whole unit directory and reported 8 unrelated
  failures elsewhere, then crashed after writing XML with the existing
  shutdown/RID leak pattern.
- Static scan found no `get_transition_space_payload`, `cell_record`, or public
  `build_transition_environment` use in the live core transition path.
- `tests/visual/test_interior_transition.tscn -- --auto-test` loaded
  Arrille's Tradehouse through `[POCKET] Space info found`, completed enter and
  exit, and logged `exit_to_exterior() called: '-2,-9'`. Exit code was 2 from
  the existing frametime threshold; there were no script, parse, fatal, or
  exception errors.
- Raw post-edit scan: `src-core` 667 files / 112544 lines and `tests-unit` 80
  files / 7620 lines.
- No C# or shader files changed; no `dotnet build` or shader cache/import
  clearing was required.

Next slice: choose a fresh Pillar 2 boundary candidate from current evidence;
do not reopen parser-cell loading, DODT exterior target-space resolution, or
transition-space payload/environment migration without a new concrete failure.

## Morrowind Terrain Texture Loader Ownership Slice - 2026-06-17

Implemented decision: Morrowind LTEX slot loading is adapter-owned terrain
translation, not generic world runtime.

- Moved `TerrainTextureLoader` from `src/core/world/terrain_texture_loader.gd`
  to `src/core/world/morrowind/morrowind_terrain_texture_loader.gd` and renamed
  the class to `MorrowindTerrainTextureLoader`.
- Updated Morrowind terrain callers in `MorrowindDataProvider`,
  `world_explorer`, prebaking, terrain labs, and terrain visual tests to use
  the adapter path.
- Removed the old generic `terrain_texture_loader.gd` boundary allowances from
  `test_adapter_boundary`; its strict-typing suppression ledger now points at
  the adapter file.
- Updated live terrain docs to point LTEX/PBR terrain texture ownership at the
  Morrowind adapter path.

Verification:

- Focused gdUnit `reports/report_103`: 21 tests, 0 failures / 0 errors across
  `test_adapter_boundary`, `test_core_strict_typing_policy`, and
  `test_morrowind_terrain_index_map`.
- `tests/visual/test_terrain_baking.tscn` launched, loaded BSA/ESM data,
  loaded 31 terrain textures through
  `src/core/world/morrowind/morrowind_terrain_texture_loader.gd`, and imported
  terrain regions before the smoke window was closed. No script, parse, fatal,
  or exception errors were logged. Existing warnings remain: deprecated
  physics-interpolation compatibility, Terrain3D's 32-slot LTEX overflow, and
  unmapped texture-index fallback warnings.
- No C# or shader files changed; no `dotnet build` or shader cache/import
  clearing was required.

Next slice: continue terrain ownership with `terrain_manager.gd` LAND/control
map generation. Keep it source-neutral only where there is a clear provider
contract; do not move `terrain_horizon.gdshader` or rewrite terrain texturing
in the same pass.

## Morrowind Terrain Manager Ownership Slice - 2026-06-17

Implemented decision: Morrowind LAND height/control/color map generation is
adapter-owned terrain translation, not generic world runtime.

- Added `MorrowindTerrainManager` under
  `src/core/world/morrowind/morrowind_terrain_manager.gd` for LAND image
  generation and Terrain3D region import.
- Reduced generic `src/core/world/terrain_manager.gd` to source-neutral
  Terrain3D region helpers.
- Updated Morrowind terrain callers in `MorrowindDataProvider`,
  `world_explorer`, prebaking, terrain preprocessing, terrain labs, and terrain
  visual tests to use the adapter path.
- Updated `test_adapter_boundary` so generic `terrain_manager.gd` has zero
  source-marker allowance and the Morrowind adapter file is the proved owner of
  LAND control-map generation.

Verification:

- Focused gdUnit `reports/report_106`: 22 tests, 0 failures / 0 errors across
  `test_adapter_boundary`, `test_core_strict_typing_policy`, and
  `test_morrowind_terrain_index_map`.
- Static marker scan found no `LandRecord`, `ESMManager`, `LAND`, `LTEX`,
  `Morrowind`, or `mw_` hits in generic `terrain_manager.gd`.
- `tests/visual/test_terrain_baking.tscn` imported 94/94 terrain regions
  through `MorrowindTerrainManager`, saved terrain, and reached horizon baking
  50/60 before the capped smoke was closed. No script, parse, fatal,
  exception, crash, or `ERROR:` matches were logged. Existing warnings remain:
  deprecated physics-interpolation compatibility, Terrain3D's 32-slot LTEX
  overflow, and unmapped texture-index fallback warnings.
- No C# or shader files changed; no `dotnet build` or shader cache/import
  clearing was required.

Next slice: choose a fresh Pillar 2 boundary candidate from current evidence.
Do not move `terrain_horizon.gdshader` or rewrite terrain texturing without a
separate rendering proof slice.

## Verification Path

Docs-only audit work:

- Verify referenced files exist.
- Run focused boundary gdUnit suites and record pass/fail signal.
- No Godot visual launch is required unless runtime gameplay, streaming,
  rendering, or performance code changes.
- No shader cache/import clearing is required unless `.glsl`, `.gdshader`, or
  `.gdshaderinc` files change.

Runtime implementation work:

- C# changed: run `dotnet build Godotwind.sln`.
- GDScript behavior changed: run focused gdUnit.
- Gameplay, streaming, rendering, or performance behavior changed: run the
  narrowest relevant Godot scene, visual smoke, or benchmark.
- Shader changed: clear relevant shader/import cache before visual verification.

## Handoff Prompt

```text
Spring cleanup, continue Pillar 2. Use
docs/audit/spring_cleanup_state.md and this charter. Continue the next
small source-neutral API cleanup from current evidence. Do not reopen
parser-cell loading, DODT exterior target-space resolution, or transition-space
payload/environment migration without a new concrete failure.
```
