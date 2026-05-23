# Morrowind Framework Boundary Mega-Audit

Date: 2026-05-21

Scope: architecture audit and follow-up correction on whether Godotwind's framework layer is genuinely data-source agnostic, with Morrowind-specific formats and conventions isolated behind translation/adapter layers.

## Verdict

Godotwind has the right direction, but the boundary is not yet complete. The
important correction after reviewing the uncommitted work is that this should
not become a broad framework rewrite.

The strongest clean seams are `WorldObjectSource`, `WorldObjectRecord`, `WorldDataProvider`, the `src/core/**/morrowind/` adapter folders, and the generic interaction registry pattern. Those prove the architecture can become framework-first.

The problem is that many generic-looking systems still consume Morrowind parser records, Morrowind coordinate math, Morrowind asset formats, or Morrowind gameplay concepts directly. In practical terms, a new game source could not plug into the framework by only implementing adapters; it would need to fabricate ESM-shaped `CellRecord` / `CellReference` objects or bypass large parts of core.

However, Godotwind already has a second world signal: La Palma. `LaPalmaDataProvider`
is a real non-Morrowind terrain/world-scale provider with large 1:1-ish island
regions and a different cell size. That changes the acceptance strategy. We
should use La Palma as proof for terrain/scale boundaries and use fake providers
only for missing object/asset/interaction streaming paths. We should not pretend
the only alternative source is hypothetical.

## Implementation Status Update - 2026-05-21

This audit is no longer purely read-only. Cleanup slices have landed after the audit, but the full remediation ladder below is not complete.

Completed in this slice:

- Repaired the `ReferenceInstantiator` model-object regression where the normal model path referenced out-of-scope `actor_record` / `actor_type` values instead of returning the instantiated object.
- Removed Morrowind fallback selection from `NativeStreamingManager`; the generic streaming manager now requires injected world object source, object spawn adapter, coordinate mapper, and asset provider before initialization.
- Split `WorldSource` capability checks so terrain/world-scale providers such
  as La Palma can be valid without object-streaming services, while
  `is_object_streaming_configured()` still requires coordinate mapper, object
  source, object spawn adapter, and asset provider.
- Added the `WorldObjectSpawnAdapter` contract while keeping generic framework code from exposing Morrowind-specific legacy spawn hooks.
- Moved carryable, door, container, activator, NPC wrapping, and leveled-creature resolution hooks into `src/core/world/morrowind/morrowind_object_spawn_adapter.gd`.
- Delegated legacy source-reference base-record lookup from `ReferenceInstantiator` to `WorldObjectSpawnAdapter`; the Morrowind spawn adapter now owns the `get_source_base_record` / cached lookup bridge.
- Removed the public world-object legacy escape hatches: `WorldObjectSource.get_legacy_*`, `WorldObjectRecord.legacy_*`, `WorldCellManifest.legacy_cell_record`, and the generic `117.0` cell-size default on `WorldObjectSource`.
- Moved raw Morrowind parser payload ownership into the Morrowind adapter's private spawn/source caches; generic `WorldObjectRecord` and `WorldCellManifest` no longer store parser records directly.
- Converted `CellPayload` and `CellStaticCollision` to consume normalized `WorldObjectRecord` transforms/static payload entries instead of raw `CellReference` static refs.
- Moved `MorrowindDataProvider` from `src/core/world/` to `src/core/world/morrowind/`.
- Translated Morrowind distant-light bit flags inside the Morrowind object adapter; core `WorldObjectRecord` and `DistantLightManager` now use generic light animation/fire metadata instead of raw MW flag masks.
- Expanded the adapter-boundary ratchet to cover broad ESM/ESP/BSA/NIF/LAND/LTEX/OpenMW/dialogue/skeleton markers and direct `preload()` / `load()` / `extends` references into adapter paths.
- Injected `WorldCoordinateMapper` into `DistantLightManager`; distant-light ring distance, page keys, page centers, and visibility margins now use provider cell metrics when available.
- Added a fake non-Morrowind source smoke in `tests/unit/test_world_source_boundary.gd` that uses a 42m cell size, fake terrain provider, fake static object, fake light, and fake spawn adapter without ESM/BSA/NIF paths.
- Expanded `tests/unit/test_adapter_boundary.gd` beyond `.gd` core scanning to cover `project.godot`, active docs/plans, and `src/native/**/*.cs` with ratcheted baselines.
- Added `tests/unit/test_morrowind_world_object_spawn_adapter.gd` to keep the Morrowind routing logic on the adapter side.
- Wired `WorldAssetProvider` into `ModelLoader`, `CellManager`, and `NativeStreamingManager` so provider-native `PackedScene` resources and source-owned prebake conversion can feed the generic cache.
- Moved BSA extraction and NIF conversion fallback out of `ModelLoader` and into `src/core/world/morrowind/morrowind_asset_provider.gd`.
- Added `tests/unit/test_model_loader_asset_provider.gd` to prove a fake non-Morrowind asset provider can return a model resource, complete async model requests, and own source-native conversion without BSA/NIF code in `ModelLoader`.
- Ratcheted the generic-core boundary baseline for `src/core/world/model_loader.gd` to zero source-specific terms.
- Moved `CellManager`'s async source-model parse task behind `WorldAssetProvider`; BSA extraction and NIF parse/convert ownership now lives in `MorrowindAssetProvider` instead of the generic streaming manager.
- Added provider-owned parse-task and parse-result smokes to `tests/unit/test_model_loader_asset_provider.gd`.
- Strengthened `tests/unit/test_adapter_boundary.gd` with per-marker source-bridge debt ledgers and shader scanning, so bridge debt cannot silently swap shape while staying under a total count.
- Moved raw Morrowind light animation flag translation out of generic `LightAnimator` / `ReferenceInstantiator`; the Morrowind spawn adapter now translates flags to generic `WorldObjectRecord.LightAnimation`, and core light animation reads `light_animation` metadata.
- Ratcheted the generic-core boundary baselines for `src/core/world/cell_manager.gd` and `src/core/world/reference_instantiator.gd` after removing direct BSA/NIF parse ownership and raw light flag animation checks.
- Removed `CellPreloader`'s fallback to `ESMManager` / `CellReference` scanning; preload model discovery now uses the injected `WorldObjectSource.get_objects_in_cell()` path or becomes a no-op when no source is configured.
- Added `CellPreloader` to the modular streaming boundary guard and ratcheted its source-specific baseline to zero.
- Delegated `CellManager` legacy base-record lookup to the injected `WorldObjectSpawnAdapter`, matching the `ReferenceInstantiator` bridge pattern and removing generic calls to `get_source_base_record`.
- Ratcheted the source-bridge baseline for `src/core/world/cell_manager.gd` from 8 to 4; the remaining counted bridges are the source-cell accessors used by the parser-shaped cell migration path.
- Changed `CellManager.request_exterior_cell_async()` to prefer source-neutral `WorldCellManifest` loading when available, with the source-cell route retained only as a legacy fallback.
- Removed the ceremonial `WorldTerrainProvider` wrapper. Terrain/world-scale
  sources stay on the existing `WorldDataProvider` contract until a concrete
  missing capability appears.
- Made `MorrowindObjectSpawnAdapter` extend `WorldObjectSpawnAdapter` instead
  of relying only on duck-typed method names.
- Restored readable `CellPreloader` comments while preserving the provider-fed
  preload behavior.
- Added La Palma and terrain-only `WorldSource` smokes proving a terrain source
  can remain valid without fabricating object-streaming or Morrowind parser
  records.
- Changed `CellManager.load_exterior_cell()` and
  `load_exterior_cell_metadata_only()` to prefer source-neutral
  `WorldCellManifest` data when available, with the parser-shaped exterior
  cell route retained only as a legacy fallback.
- Added fake non-Morrowind sync exterior and metadata-only smokes so those
  helpers cannot regress back to requiring `CellRecord` / `CellReference`.

Verified:

- Ran `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn`.
- Latest full-suite report during this slice: `reports/report_235`.
- Latest targeted world-source report: `reports/report_236`.
- New and directly relevant suites passed: `test_adapter_boundary`, `test_model_loader_asset_provider`, `test_world_source_boundary`, `test_morrowind_world_object_spawn_adapter`, `test_world_object_source`, and `test_streaming_modular_boundaries`.
- Remaining failures in that run were pre-existing or unrelated to this boundary slice: `test_morrowind_terrain_index_map`, `test_object_paging_kernel`, `test_static_object_renderer_bwide`, and `test_wetness_manager`.
- No C# files were changed, so no `dotnet build Godotwind.sln` was required.
- No shader files were changed by this boundary cleanup, so shader cache/import artifacts were not cleared.

Still not complete:

- `CellManager` still contains migration paths that call adapter-local source-cell bridges and consume parser-shaped `CellRecord` / `CellReference` data. Public exterior async, sync exterior, and metadata-only exterior helpers now prefer source-neutral manifests, and `CellManager` / `ReferenceInstantiator` no longer call `get_source_base_record` directly. Interior loading, character injection, multimesh fallback tails, and the legacy `ReferenceInstantiator.instantiate_reference()` route still consume parser-shaped `CellReference` and ESM record classes. `CellPayload` and `CellStaticCollision` now consume normalized payload data, but the full legacy classification/instantiation route has not fully moved behind source-neutral records.
- Coordinate separation is partial. `WorldCoordinateMapper` and `MorrowindCoordinateMapper` exist, and `DistantLightManager` now consumes the active mapper, but other core distance/page systems still have direct dependencies on older Morrowind-oriented coordinate helpers and distance assumptions.
- Asset provider separation is partially load-bearing. Model resource loading, source-owned model conversion, and `CellManager` async source-model parse tasks now go through `WorldAssetProvider`, but texture loading, DDS repair, material translation, and several tools still need to move behind provider/importer implementation paths.
- Terrain/provider separation should be handled conservatively. `MorrowindDataProvider` now lives under `src/core/world/morrowind/`, and La Palma already proves the existing `WorldDataProvider` abstraction can support non-Morrowind terrain and large-region scale. Do not add a parallel terrain provider layer unless it replaces duplicated behavior across both providers or unblocks a real runtime path.
- Morrowind gameplay assumptions remain in dialogue, weather, journal/topic/disposition handling, animation/skeleton remaps, text-key handling, and character factory paths. These are inventory items, not current-slice implementation targets.

## Agent Reconciliation Update - 2026-05-21

This pass compared the audit against the changed codebase with focused agents for world streaming, coordinates/terrain, non-world systems, rendering/LOD, and enforcement docs.

Current state:

- The direction is good: `NativeStreamingManager` is now injection-based, `WorldObjectSource` / `WorldCellManifest` / `WorldObjectRecord` are the main contracts for new world-object streaming, `ModelLoader` is provider-driven, `DistantLightManager` no longer consumes raw Morrowind flag bits directly, and the active `ObjectPaging` path works from `WorldObjectSource`.
- The boundary is not complete: generic `CellManager` still calls adapter-local source-cell bridges such as `get_source_cell` and `get_source_exterior_cell` on legacy sync/interior paths; `CellManager` and `ReferenceInstantiator` still consume parser-shaped `CellReference` and ESM record classes even though base-record lookup now goes through the spawn adapter; coordinate, terrain, weather, dialogue compatibility, character/NIF, impostor-candidate, and some settings/loading paths remain Morrowind-shaped.
- The current boundary tests are ratchets, not proof. They allow known debt and can hide a leak swap if one old token disappears and a new one appears. They should become exact debt ledgers for dirty files, add scans for `get_source_` and `source_base_record`, and extend coverage to shaders, native C# files, and docs when claims are being audited.

Stale or softened claims found:

- `docs/STATUS.md` overclaimed that Morrowind/ESM lookup is isolated in the adapter. The provider path is much cleaner now, but near/interior legacy routes still bridge through parser-shaped records in generic world code.
- `docs/systems/adapter_boundary.md` described `get_source_*` as adapter-only migration APIs. That is now true for base-record resolution in both `ReferenceInstantiator` and `CellManager`, but generic `CellManager` still calls source-cell APIs. Treat the remaining calls as known transitional debt, not an acceptable final contract.
- The previous groundcover concern in this audit is only partly stale. `docs/plans/groundcover.md` now describes a provider-oriented contract, but that should be trimmed to a short boundary note until the renderer exists. The next groundcover implementation should still ship the concrete OpenMW-style/Morrowind adapter path first, then extract a provider contract from the working shape. This docs update also aligned `docs/plans/impostor_rebuild.md` with that authority instead of the older Terrain3D Instancer direction.
- The shore/wetness plans conflicted. This docs update marks `docs/plans/shore_overhaul.md` Phase 3 as superseded and points it to the active screen-space compositor direction in `docs/plans/wetness_system.md`.

Updated priority:

1. Simplify the uncommitted boundary slice before committing: keep the
   load-bearing provider work, revert/trim purely ceremonial abstractions and
   noisy doc/comment churn.
2. Strengthen boundary tests and debt ledgers only where they protect current
   code paths. Do not let broad term-count ratchets become a substitute for a
   real second-source smoke.
3. Finish the world-object migration by making generic `CellManager` consume
   source-neutral manifests and by replacing the remaining parser-shaped
   `ReferenceInstantiator` tail with spawn descriptors.
4. Use La Palma as the terrain/scale proof. Only add fake non-Morrowind
   providers for object, asset, light, collision, HLOD/FAR, and interaction
   paths that La Palma does not currently exercise.
5. Leave weather, dialogue compatibility, character/NIF animation assumptions,
   settings path labels, and loading UI text out of the current boundary slice
   unless a concrete source needs those abstractions.

## Scope Correction - 2026-05-21

This audit originally described every Morrowind-shaped core system as boundary
debt. That is useful as an inventory, but it is too broad as an implementation
plan. The current uncommitted work should be narrowed before commit.

The target is not "remove every Morrowind word from core." The target is:

- Generic streaming/runtime systems must not require ESM/BSA/NIF parser records
  to boot or stream.
- Core systems that already have a second-source consumer, such as terrain via
  La Palma, should use the existing provider contract rather than inventing a
  new parallel one.
- Morrowind-specific parsing, conversion, and gameplay wrapping should be
  allowed to exist, but it must live in parser/importer/adapter ownership.
- Abstractions should be added only when a real call path uses them, not as
  labels for future architecture.

### Keep From The Uncommitted Slice

Keep these changes. They reduce real coupling on load-bearing paths:

- `NativeStreamingManager` no longer silently creates a Morrowind object source
  when no source is injected. This is the correct boot contract for framework
  code.
- `WorldObjectSource`, `WorldCellManifest`, and `WorldObjectRecord` no longer
  expose public `get_legacy_*`, `legacy_*`, or `legacy_cell_record` fields.
  Morrowind parser payloads belong in adapter-private caches.
- `CellPayload` and `CellStaticCollision` now consume normalized object records
  and transforms rather than raw `CellReference` static refs.
- `ModelLoader` now owns generic cache/resource lifetime while
  `WorldAssetProvider` owns source-specific archive lookup and model
  conversion. Moving BSA extraction and NIF conversion to
  `MorrowindAssetProvider` is the right boundary.
- `DistantLightManager` uses generic light animation/fire metadata and can read
  page/cell metrics from an injected `WorldCoordinateMapper`.
- `CellPreloader` no longer reaches directly into `ESMManager`; preloading from
  `WorldObjectSource.get_objects_in_cell()` is the right ownership.
- `MorrowindDataProvider` moving under `src/core/world/morrowind/` is a good
  ownership correction, as long as the terrain contract remains the existing
  `WorldDataProvider` shape that La Palma already uses.

### Simplify Or Revert Before Commit

These parts look overdone or incomplete and should be simplified before this
work lands:

- Delete or defer `WorldTerrainProvider` unless it becomes a real contract with
  both Morrowind and La Palma migrated to it. Right now it only extends
  `WorldDataProvider` without adding behavior. The existing `WorldDataProvider`
  is already proven by `LaPalmaDataProvider`.
- Do not require every `WorldSource` to provide every subsystem. La Palma is a
  terrain/world-scale source, not an object-streaming source. Split checks into
  explicit capabilities such as "object streaming configured" instead of making
  `is_configured()` imply terrain, objects, spawn, assets, weather, dialogue,
  and characters all exist.
- Make `MorrowindObjectSpawnAdapter` extend `WorldObjectSpawnAdapter` if the
  base contract stays. Do not introduce a base class and then rely only on
  duck-typed method names.
- Revert the comment-only punctuation churn in `CellPreloader`. The behavior
  change is useful; the stripped punctuation makes old performance notes harder
  to read and creates noisy diff.
- Keep source-code boundary tests, but be careful with broad docs/plans term
  ratchets. They are useful during an audit, but they can also block legitimate
  prose or hide churn behind baseline numbers. Prefer exact ledgers for dirty
  source files and explicit doc review notes for documentation.
- Do not rewrite `docs/plans/groundcover.md` into a fully generic provider plan
  before the renderer exists. Keep a short boundary note, then ship the
  concrete OpenMW-style/Morrowind adapter path first. A future provider contract
  should fall out of that implementation, not precede it with speculative
  files.
- Do not treat weather, dialogue UI, journal/disposition, character factory,
  NIF text keys, or settings labels as next-session cleanup. Those are real
  source-specific areas, but genericizing them now would rewrite gameplay
  systems without a second gameplay data source.

### Do Not Revert

Do not roll back the entire boundary slice. The problem is not that the plan is
wrong; the problem is that the plan expanded past the load-bearing boundary.
Keep the streaming/object/asset seams and trim the speculative layer names and
scope creep.

### Next In Line

The next implementation slice should be small and verifiable:

1. Clean the uncommitted diff:
   - remove/defer `WorldTerrainProvider` unless it gains real contract value,
     **done: removed**,
   - restore readable `CellPreloader` comments, **done**,
   - make `MorrowindObjectSpawnAdapter` extend `WorldObjectSpawnAdapter`,
     **done**,
   - keep `docs/STATUS.md` claims conservative.

2. Add a real second-source acceptance test using La Palma where applicable:
   - assert La Palma still owns large-region terrain through
     `WorldDataProvider`,
   - assert its cell size remains provider-defined,
   - assert none of the boundary changes force La Palma to fabricate Morrowind
     parser records. **Done as a unit smoke; still worth adding a visual/scene
     smoke when terrain runtime code changes.**

3. Add one fake object-source smoke only for what La Palma does not cover:
   - fake object manifest,
   - fake asset provider returning a `PackedScene`,
   - fake spawn adapter creating a simple `Node3D`,
   - fake light metadata,
   - static collision payload from normalized transforms. **Mostly done in
     `test_world_source_boundary.gd`; keep expanding only for new load-bearing
     paths.**

4. Finish the `CellManager` parser-record migration:
   - replace remaining generic calls to `get_source_cell` and
     `get_source_exterior_cell`,
   - sync exterior helpers now prefer source-neutral manifests; interior
     loading still needs either manifest support or an explicit
     Morrowind-demo-only boundary,
   - remove `CellRecord` / `CellReference` from the generic active streaming
     path.

5. Stop there and verify. Do not proceed into weather/dialogue/character
   genericization until a new source actually needs those surfaces.

## Boundary Standard Used

Allowed in adapter/importer domains:

- `src/core/esm/**`, `src/core/nif/**`, `src/core/bsa/**`
- `src/native/*ESM*`, `src/native/*NIF*`, `src/native/*BSA*` parser/backend code
- `src/core/**/morrowind/**`
- explicitly named Morrowind tools, visual tests, fixtures, and sample/demo scenes

Framework leaks:

- Core files outside parser/adapter folders importing or typing against `ESMManager`, `BSAManager`, `CellRecord`, `CellReference`, `LandRecord`, `RegionRecord`, `NPCRecord`, `CreatureRecord`, `LightRecord`, `NIFConverter`, `.esm`, `.esp`, `.bsa`, `.nif`, `Morrowind`, `MW_`, or MW coordinate constants.
- Generic boot/runtime defaults that silently select Morrowind when no provider is injected.
- Generic APIs that expose parser-shaped records as permanent contracts.

## Ranked Findings

### Critical: The Global Coordinate System Is A Morrowind Adapter In Core

Evidence:

- `src/core/coordinate_system.gd:1` calls itself the single source of truth for Morrowind to Godot conversion.
- `src/core/coordinate_system.gd:42` hardcodes 70 Morrowind units per meter.
- `src/core/coordinate_system.gd:45` hardcodes 8192-unit Morrowind cells.
- `src/core/coordinate_system.gd:48` exposes the 117m Morrowind cell size as a global constant.
- `src/core/coordinate_system.gd:88`, `:141`, `:224`, `:269`, and `:316` mix vector conversion, ESM rotation conversion, MW cell-grid math, LAND height conversion, and Terrain3D configuration.
- `src/core/world/distance_utils.gd:13` preloads that coordinate system and `:15` declares Morrowind cell size as the distance utility's cell size.

Why it matters:

Every framework system that depends on `CoordinateSystem` inherits Morrowind's axes, units, cell size, terrain assumptions, and ESM rotation rules. A different game with meter-native data, different tile sizes, or a different up-axis cannot swap in cleanly.

Recommended fix:

Split this into:

- Core `WorldCoordinateMapper` / `WorldGridMapper` contract: Godot meters, world origin, cell/tile size, region conversion, optional provider grid.
- `MorrowindCoordinateMapper`: `Vector3(mw.x, mw.z, -mw.y)`, 70 units/meter, 8192-unit cells, ESM rotation order, LAND image Y flip.
- Distance/streaming code should read cell size and grid policy from the active provider, not global constants.

### Resolved After Audit: Generic Streaming Defaults To Morrowind

The original audit found that `NativeStreamingManager` could instantiate a
Morrowind object source when no source was injected. That default has been
removed: generic streaming now requires injected source, object-source,
spawn-adapter, coordinate-mapper, and asset-provider services before
initialization.

### High: World Loading And Instantiation Still Consume ESM Records Directly

Evidence:

- `src/core/world/cell_manager.gd:1` describes itself as loading Morrowind cells from ESM and placing NIF models.
- `src/core/world/cell_manager.gd:18` preloads `NIFConverter`.
- `src/core/world/cell_manager.gd:239`, `:249`, `:321`, and `:3534` type core loading around `CellRecord`.
- `src/core/world/cell_manager.gd:297`, `:346`, and `:357` iterate `CellReference`.
- `src/core/world/cell_manager.gd:3577` through `:3589` call `BSAManager` and parse NIF data during async work.
- `src/core/world/reference_instantiator.gd:1` says it converts ESM references into Node3D objects.
- Current reconciliation: direct Morrowind interaction/dialogue adapter preloads have been removed from `ReferenceInstantiator`, and `CellManager` no longer owns BSA/NIF async parse tasks, but generic core still consumes source-shaped records on legacy paths.
- `src/core/world/reference_instantiator.gd:334`, `:380`, `:395`, `:409`, `:413`, `:418`, `:1370`, and `:1756` type against `CellReference`, `LightRecord`, `NPCRecord`, `CreatureRecord`, and `LeveledCreatureRecord`.
- Resolved after audit: `CellPreloader` no longer queries `ESMManager`; `CellPayload` and `CellStaticCollision` now consume normalized `WorldObjectRecord` / payload transforms instead of raw static refs.

Why it matters:

`WorldObjectSource` exists, but the legacy path remains load-bearing. Core still asks, "what ESM record is this?" instead of "what framework object did the provider emit?"

Recommended fix:

Make the framework loading path consume only normalized data:

- `WorldCellManifest`
- `WorldObjectRecord`
- provider-supplied transforms, model/resource handles, bounds, capability flags, interaction factory IDs, collision metadata, light metadata, portal metadata

Move the remaining ESM lookup, type-name mapping, teleport fields, MW interaction wrappers, and NIF/BSA model resolution into a Morrowind world adapter. The public `get_legacy_*` APIs have been removed; the next step is deleting the remaining adapter-local `get_source_*` bridges from generic callers.

### Resolved After Audit: The Legacy Escape Hatch Was Becoming A Framework API

Original evidence:

- `src/core/world/world_object_source.gd:40` through `:60` exposes `get_legacy_exterior_cell`, `get_legacy_cell`, `get_legacy_base_record`, `get_legacy_creature`, and `get_legacy_leveled_creature`.
- `src/core/world/world_object_record.gd:34` through `:36` stores `legacy_ref`, `legacy_base_record`, and `legacy_type_name`.
- `src/core/world/morrowind/morrowind_world_object_source.gd:49` returns gameplay payloads containing raw `ref`, `base_record`, and `type_name`.

Current status:

The public `get_legacy_*`, `legacy_*`, and `legacy_cell_record` surfaces have
been removed. Morrowind raw parser payloads now live in private adapter caches
and spawn payloads while the remaining legacy instantiation path is migrated.

### High: Terrain Core Is Morrowind LAND/LTEX Conversion

Evidence:

- `src/core/world/terrain_manager.gd:1` says it converts Morrowind LAND data to Terrain3D.
- `src/core/world/terrain_manager.gd:29` through `:32` hardcode MW cell, LAND, and VTEX grid constants.
- `src/core/world/terrain_manager.gd:110`, `:197`, `:234`, `:655`, and `:762` accept `LandRecord` or callbacks returning `LandRecord`.
- `src/core/world/terrain_manager.gd:606` converts Morrowind world position to cell coordinates.
- `src/core/world/terrain_texture_loader.gd:1` says it loads Morrowind LTEX textures.
- `src/core/world/terrain_texture_loader.gd:69`, `:76`, `:142`, `:226`, `:309`, and `:321` read `ESMManager`, `LandTextureRecord`, LTEX indices, and MW texture indices.
- `src/core/world/terrain_horizon.gdshader:64` through `:68` expose `mw_*` texture uniforms in a core shader path.
- Resolved after audit: `MorrowindDataProvider` now lives at `src/core/world/morrowind/morrowind_data_provider.gd`.

Why it matters:

The framework terrain contract should be "give me region height/control/color data and terrain material inputs." LAND/LTEX is one source implementation, not the terrain architecture.

Recommended fix:

Move the remaining LAND/LTEX conversion into `src/core/world/morrowind/` or a future adapter package. Keep core terrain on `WorldDataProvider` images and generic texture/index resources.

### High: Core Asset Loading Assumes BSA/NIF/DDS

Evidence:

- Resolved after the original audit: `src/core/world/model_loader.gd` no longer imports `BSAManager` / `NIFConverter`; source-native model conversion is now delegated to `WorldAssetProvider`, with the Morrowind implementation in `src/core/world/morrowind/morrowind_asset_provider.gd`. `CellManager` also delegates async source-model parse tasks and parse-result conversion through `WorldAssetProvider`.
- `src/core/texture/texture_loader.gd:1` says it loads textures from BSA archives and supports Morrowind DDS quirks.
- `src/core/texture/texture_loader.gd:124` and `:190` search BSA archives via `BSAManager`.
- `src/core/texture/dds_loader.gd:1` is a custom DDS loader for malformed Morrowind textures.
- `src/core/texture/material_library.gd:54` through `:59` includes NIF material slots and apply modes.
- `src/core/modding/mod_registry.gd:76` scans for BSAs and ESPs.

Why it matters:

Generic rendering should not care whether a model came from BSA/NIF, GLTF, loose PNGs, a Unity asset bundle, or a generated resource cache. The asset contract is still source-format-shaped.

Recommended fix:

Introduce `AssetProvider` / `ModelProvider` / `TextureProvider` contracts that return Godot resources or source-neutral handles. Keep BSA lookup, DDS repair, NIF conversion, and NIF material interpretation in the Morrowind importer/provider.

### High: Character And Animation Core Is MW/NIF/NPC-Specific

Evidence:

- `src/core/animation/character_factory_v2.gd:1` through `:22` describes and imports a Morrowind character pipeline.
- `src/core/animation/character_factory_v2.gd:167`, `:171`, `:215`, `:222`, `:229`, `:575`, and `:677` use `BSAManager`, `ESMManager`, `NPCRecord`, `RaceRecord`, and `MorrowindNPCAssembler`.
- `src/core/animation/morrowind_character_system.gd:1` is explicitly Morrowind-specific but lives in the generic animation root.
- `src/core/animation/skeleton_utils.gd:1` through `:84` hardcode Bip01 to humanoid bone remapping.
- `src/core/animation/text_key_handler.gd:1` parses Morrowind/NIF/KF text-key semantics.
- `src/core/character/mesh_extractor.gd:1` extracts raw mesh geometry from Morrowind NIF files and uses `BSAManager`.
- `src/core/character/character_types.gd:8` has a `MORROWIND` source enum and Morrowind spawn helpers.

Why it matters:

Character assembly and animation are framework domains, but these files currently encode one source format and one skeleton naming scheme.

Recommended fix:

Future fix, not current slice:

Move Morrowind character factory, NIF mesh extraction, Bip01 remaps, and text-key parsing into Morrowind/NIF adapter folders when a second gameplay/character source needs the boundary. Core could eventually expose:

- `CharacterSource` or `CharacterFactory` interface
- normalized skeleton profile contracts
- animation state to clip alias maps supplied by the adapter
- generic animation event dispatcher, with NIF text-key parsing as an adapter input

### High: Weather Core Depends On ESM Regions And Morrowind Weather Tables

Evidence:

- `src/core/weather/weather_manager.gd:7` states that transitions follow Morrowind's model.
- `src/core/weather/weather_manager.gd:187` reads `RegionRecord` from `ESMManager`.
- `src/core/weather/weather_manager.gd:263` calls `ESMManager.get_exterior_cell()`.
- `src/core/weather/weather_data.gd:1` says the class contains default Morrowind weather parameters.
- `src/core/weather/weather_data.gd:67` extracts probabilities from `RegionRecord`.
- `src/core/weather/weather_types.gd:12` defines weather type indices matching Morrowind's 10 types.

Why it matters:

Weather is a framework system, but the state machine, data table, and region lookup are tied to MW/OpenMW data.

Recommended fix:

Future fix, not current slice:

Introduce `WeatherProvider` / `RegionWeatherProfile` resources only when weather becomes part of a source-neutral runtime smoke or a second source needs it. The framework weather manager should eventually consume active-region IDs and weather weights/parameters supplied by the provider. Move MW weather tables and `RegionRecord` extraction to the Morrowind adapter then.

### High: Generic Dialogue/UI Still Carries Morrowind Conversation Semantics

Evidence:

- `src/core/dialogue/dialogue_context.gd:14` through `:49` contains race, class, faction, rank, crime, magicka, fatigue, known topics, journal indices, disposition, weather, and globals.
- `src/core/ui/dialogue_panel.gd:17` through `:25` documents an NPC topic-list layout with disposition and synthetic Goodbye.
- `src/core/ui/dialogue_panel.gd:173`, `:189`, `:196`, `:244`, and `:267` render disposition, "NPC not found", topic discovery, and `get_response("goodbye", ...)` style behavior.
- `src/core/dialogue/dialogue_provider.gd:40` through `:66` documents MW-shaped metadata including `info_id`, `journal_index`, `quest_finish`, and `quest_restart`.
- `src/core/dialogue/quest_manager.gd:49` uses numeric journal indices and finish/restart flags mirroring MW journal behavior.

Why it matters:

The dialogue provider/adapter pattern is good, but the generic UI/context still assumes a Morrowind/OpenMW-style topic conversation with disposition and journal indices.

Recommended fix:

Future fix, not current slice:

Make base `DialogueContext` a minimal session blackboard or participant model when a second dialogue source exists. Move TES/MW condition fields to `MWDialogueContext` then. Have providers expose a dialogue view model/actions list so "Goodbye", disposition, topic discovery, and NPC-specific fallback strings can be adapter-supplied.

### Medium: Settings, Autoloads, And Loading Make Morrowind Project-Wide

Evidence:

- `project.godot:22` and `:23` autoload `BSAManager` and `ESMManager` globally.
- `src/core/settings_manager.gd:6`, `:85`, `:108`, and `:145` manage `MORROWIND_DATA_PATH`, `MORROWIND_ESM_FILE`, `Morrowind.esm`, and install autodetection in generic settings.
- `src/core/ui/loading_screen.gd:51` through `:88` directly loads BSA/ESM data from a reusable UI overlay.

Why it matters:

Any framework user inherits Morrowind startup and global parser managers. These are source configuration concerns, not framework settings.

Recommended fix:

Future fix, not current slice:

Split generic app/cache/graphics settings from source-specific configuration when source selection becomes a product feature. A scene-owned or autoloaded `DataSourceManager` can register a `MorrowindSource` that owns ESM/BSA managers internally. Keep `LoadingScreen` as UI only and inject a loader task/callable.

### Medium: LOD, Impostor, And Light Heuristics Include Morrowind Content Rules

Evidence:

- `src/core/world/impostor_candidates.gd:35`, `:133`, and `:146` contain Morrowind-specific landmark/flora patterns.
- `src/core/world/impostor_candidates.gd:429` and `:468` scan BSA archives for NIF files.
- Resolved after audit: `DistantLightManager` now consumes generic light metadata and the active coordinate mapper instead of raw MW light flag bits.
- `src/core/world/light_animator.gd:1` through `:20` animates lights from `mw_flags`.
- `src/core/world/object_paging.gd:1335` says some texture/mod support is omitted because Godotwind ships Morrowind data only.

Why it matters:

Core LOD policy should consume adapter-authored capabilities, bounds, tags, and representation metadata. It should not know that "Vivec canton" or a particular flag bit is special.

Recommended fix:

Move candidate pattern lists, BSA scans, MW light flags, and content-specific thresholds into the Morrowind source/provider. Core renderers should consume `CAP_HLOD`, `CAP_IMPOSTOR`, `CAP_DISTANT_LIGHT`, light animation mode, and authored proxy metadata.

### Medium: Main Scene And Docs Still Present Morrowind As The Architecture

Evidence:

- `scenes/Godotwind.tscn:170` through `:180` has Quick Teleport buttons for Seyda Neen, Balmora, and Vivec.
- `src/tools/world_explorer.gd:1` calls itself the Morrowind world exploration orchestrator.
- `src/tools/world_explorer.gd:467` through `:522` directly loads BSA/ESM/ESP data.
- `docs/ARCHITECTURE.md:18` through `:32` lists Morrowind path, ESM, NIF, BSA, and body-part systems under core architecture.
- `docs/ARCHITECTURE.md:78` makes MW coordinate conversion the global coordinate-system section.
- `docs/STATUS.md:14` through `:19` lists ESM/NIF/BSA/NPC/MW animation as top-level working systems.
- Current reconciliation: the active `docs/plans/groundcover.md` direction is now provider-oriented, and `docs/plans/impostor_rebuild.md` now defers to that plan instead of the older Terrain3D Instancer direction.
- Current reconciliation: `docs/plans/shore_overhaul.md` Phase 3 is now marked superseded by `docs/plans/wetness_system.md`, which owns the active screen-space compositor direction.

Why it matters:

Even if code improves, framework-facing docs and scenes steer future work back toward Morrowind-as-core.

Recommended fix:

Split docs and scenes into:

- Core framework architecture/status.
- Morrowind adapter/source status.
- Morrowind demo app / sample scene.

Update active plans before implementation so new work uses generic providers rather than `ESMManager`.

## Clean Boundary Examples

These are worth preserving and extending:

- `src/core/world/world_data_provider.gd:16` through `:25`: clean terrain/world config abstraction.
- `src/core/world/lapalma_data_provider.gd`: proof that non-Morrowind terrain data can fit the provider shape.
- `src/core/world/morrowind/morrowind_world_object_source.gd:117` through `:143`: translates ESM refs into normalized `WorldObjectRecord` capability flags.
- `src/core/world/morrowind/morrowind_terrain_texture_bridge.gd:1`: correctly scoped adapter-specific terrain texturing.
- `src/core/interaction/carryable_registry.gd:1` through `:14`: generic registry with adapter-supplied callables.
- `src/core/interaction/interactable.gd:21`: explicitly rejects ESM/MW imports in the framework base.
- `tests/unit/test_world_object_source.gd`: uses fake source data to test the generic boundary.
- `tests/unit/test_streaming_modular_boundaries.gd`: existing boundary guard concept.
- `src/core/world/cell_static_bucket.gd`: clean server-resource lifetime ownership; no Morrowind boundary issue found there.

## Recommended Remediation Ladder

1. Normalize the current diff before commit.
   - Keep the provider-fed world-object, asset, light, preloader, and static
     collision changes.
   - Revert noisy comment churn and ceremonial wrappers.
   - Keep documentation claims conservative about the remaining parser-shaped
     routes.

2. Lock only the boundary that is currently load-bearing.
   - Exact debt ledgers for `CellManager`, `ReferenceInstantiator`,
     `ModelLoader`, `CellPreloader`, `DistantLightManager`, and static
     collision.
   - Source code guards for new `ESMManager`, `BSAManager`, `NIFConverter`,
     `CellRecord`, `CellReference`, `.esm`, `.bsa`, `.nif`, and direct
     `res://src/core/**/morrowind/**` references in generic runtime code.
   - Avoid broad docs/plans ratchets as hard gates unless the doc is itself the
     artifact under review.

3. Preserve and use the existing terrain abstraction.
   - Treat `WorldDataProvider` as the terrain/world-scale contract until a real
     missing capability appears.
   - Use `LaPalmaDataProvider` as proof that non-Morrowind terrain can already
     fit the framework.
   - Do not add `WorldTerrainProvider` / `TerrainRegionData` layers until they
     remove concrete duplication or unblock a real source.

4. Finish object streaming normalization.
   - Make `CellManager`'s active async path consume only `WorldCellManifest`
     and `WorldObjectRecord`.
   - Replace remaining generic `get_source_cell` /
     `get_source_exterior_cell` calls with source-neutral manifest access, or
     move those helpers into Morrowind demo code.
   - Replace the remaining parser-shaped `ReferenceInstantiator` tail with
     adapter-owned spawn descriptors for node, static, light, actor, and skip
     routes.

5. Split coordinate/grid policy only where runtime code needs it.
   - Keep `WorldCoordinateMapper` for object streaming, light pages, HLOD/FAR
     page math, and future source scale differences.
   - Move Morrowind axis/unit/LAND image conversion into
     `MorrowindCoordinateMapper`.
   - Keep old `coordinate_system.gd` as a transitional helper until all active
     call sites have a mapper path; do not churn every historical utility at
     once.

6. Expand asset providers only after model loading is stable.
   - Current priority is model resource lookup, cache keys, prebake conversion,
     and async parse results.
   - Texture loading, DDS repair, and material translation can move later when
     a real source or renderer path needs source-neutral texture providers.

7. Defer gameplay genericization.
   - Weather, dialogue, journal/disposition, character factories, skeleton
     remaps, NIF text keys, and UI strings are not next in line.
   - Move them only when a second gameplay source needs them or when they block
     the object-streaming acceptance smoke.

8. Verify with one real and one fake non-Morrowind signal.
   - Real: La Palma terrain remains provider-defined and does not depend on
     Morrowind parser records.
   - Fake: a tiny object/asset/light/collision source streams through the same
     active object path without ESM/BSA/NIF globals.

## Practical Acceptance Bar

Godotwind can be considered properly deconnected at the world-runtime layer when
both of these are true:

Real-source proof:

- La Palma continues to run as a non-Morrowind world/terrain source through
  `WorldDataProvider`.
- La Palma can define its own large region/cell size without touching Morrowind
  constants or fabricating `CellRecord`, `CellReference`, `LandRecord`, or
  NIF/BSA paths.

Object-streaming proof:

- boot the streaming manager without `ESMManager` or `BSAManager` autoloads,
- define a different object cell/tile size through `WorldCoordinateMapper`,
- provide objects, transforms, assets, lights, static collision payloads, and
  interaction metadata through `WorldObjectSource`, `WorldObjectRecord`,
  `WorldAssetProvider`, and `WorldObjectSpawnAdapter`,
- run a smoke scene without fabricating `CellRecord`, `CellReference`, ESM
  records, or NIF/BSA paths.

Weather, dialogue, character assembly, journal semantics, and source-specific
UI text are outside this acceptance bar. They remain valid future boundary work,
but they are not required to call the current world-runtime boundary slice done.

Until then, Godotwind is best described as a Morrowind-centered RPG framework
with a real non-Morrowind terrain provider and increasingly clean object/asset
adapter seams, not yet a fully generic open-world RPG framework.

## Verification

Original audit pass was documentation-only. Follow-up boundary cleanup changed
streaming/runtime code and was verified with Godot test runs:

- Full gdUnit scene:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn`
  generated `reports/report_235`.
- Targeted world-source suite:
  `D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd --add res://tests/unit/test_world_source_boundary.gd --continue`
  generated `reports/report_236` with 13 tests, 0 failures.
- Directly relevant boundary suites passed in the full run:
  `test_adapter_boundary`, `test_model_loader_asset_provider`,
  `test_morrowind_world_object_spawn_adapter`,
  `test_streaming_modular_boundaries`, and `test_world_source_boundary`.
- Remaining full-run failures were the already-known unrelated suites:
  `test_morrowind_terrain_index_map`, `test_object_paging_kernel`,
  `test_static_object_renderer_bwide`, and `test_wetness_manager`.
- No C# files changed, so `dotnet build Godotwind.sln` was not required.
- No shader files changed in the boundary cleanup, so shader cache/import
  artifacts were not cleared.

## Handoff Prompt

Continue the Godotwind framework-boundary cleanup from
`docs/audit/morrowind_framework_boundary_mega_audit_2026_05_21.md`. Do not
genericize weather/dialogue/characters. Next target: finish
`CellManager`/`ReferenceInstantiator` object-streaming normalization by removing
remaining generic `get_source_cell` / `get_source_exterior_cell` dependence for
interior/legacy paths or explicitly moving those entry points into Morrowind
demo ownership. Keep changes small, use `WorldCellManifest` /
`WorldObjectRecord` / `WorldObjectSpawnAdapter`, update boundary tests, then
run gdUnit plus a Godot visual/smoke for any gameplay/streaming path changed.
