# Adapter Boundary

Godotwind is a source-agnostic open-world framework. Morrowind is the first
source adapter, not the framework architecture.

## Rule

Core systems consume normalized framework contracts:

- `WorldSource`
- `WorldCoordinateMapper`
- `WorldObjectSource`
- `WorldObjectRecord`
- `WorldDataProvider`
- `WorldAssetProvider`
- `WorldObjectSpawnAdapter`

Source-specific parsing, unit conversion, asset lookup, gameplay record
translation, skeleton naming, weather tables, dialogue condition semantics, and
content heuristics belong in importer or adapter folders.

## Allowed Source-Specific Domains

The following paths may know about source formats directly:

- `src/core/esm/**`
- `src/core/bsa/**`
- `src/core/nif/**`
- `src/native/*ESM*`, `src/native/*BSA*`, `src/native/*NIF*`
- `src/core/**/morrowind/**`
- explicitly named source tools, fixtures, and visual tests

Generic framework paths outside those domains must not add direct dependencies
on source parser records, source archive managers, source model formats, or
Morrowind-specific coordinate/gameplay conventions.

`tests/unit/test_adapter_boundary.gd` ratchets this with baselines for
source-specific terms, parser/archive/model-format names, dialogue condition
tokens, character skeleton markers, and direct `preload()` / `load()` /
`extends` references into adapter paths. The test prevents new drift; it does
not prove all existing framework files are clean.

## Migration-Only APIs

The old public world-object escape hatches were removed in the 2026-05-21
cleanup slice:

- `WorldObjectSource.get_legacy_*`
- `WorldObjectRecord.legacy_*`
- `WorldCellManifest.legacy_cell_record`

Morrowind parser records now stay in the Morrowind adapter's private caches and
spawn payloads. Generic framework code should consume normalized
`WorldObjectRecord` instances, provider asset handles, and adapter spawn
metadata instead of parser-shaped records.

Temporary source accessors named `get_source_*` remain only on the Morrowind
adapter. Generic `ReferenceInstantiator` and `CellManager` no longer call the
base-record accessor directly; that bridge is owned by the injected spawn
adapter. `CellManager` still uses source cell accessors during the migration
away from parser-shaped `CellRecord` / `CellReference` data. Treat those
remaining calls as known debt, not as an accepted framework contract. New
generic core code must not add similar source-record bridges, and cleanup
should delete the remaining generic calls rather than widening the bridge.

## Test Caveats

The current boundary tests are ratchets, not a certificate of framework
purity. A file can stay under its allowed count while swapping one source leak
for another. Dirty parser-bridge method names now have per-marker ledgers so a
cleanup can lower old debt without allowing a different source-record bridge to
appear quietly.

The scan covers broad source-specific markers, known parser bridge terms such
as `get_source_cell` and `source_base_record`, active docs/plans, shaders, and
`src/native/**/*.cs` instead of only `.gd` files.

## Boot Ownership

Runtime boot code owns the active `WorldSource` and injects it into framework
systems. Generic managers must fail clearly when required providers are missing;
they must not silently create a Morrowind source.

The current Morrowind demo uses `MorrowindWorldSource` as the sample adapter.
Future object-streaming sources should be able to provide their own mapper,
object source, asset provider, and spawn adapter without fabricating
parser-shaped records. Terrain/world-scale sources can remain valid by
providing only the existing `WorldDataProvider` capability, as La Palma does.
