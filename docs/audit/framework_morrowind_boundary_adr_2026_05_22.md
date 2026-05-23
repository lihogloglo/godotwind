# Framework / Morrowind Boundary ADR

Date: 2026-05-22

## Decision

Godotwind's core world runtime is a source-agnostic open-world framework.
Morrowind is a source adapter and demo content source, not the framework
architecture.

The framework owns normalized runtime concepts:

- `WorldSource` capability wiring.
- `WorldCoordinateMapper` grid math in Godot-world meters.
- `WorldObjectSource` and `WorldCellManifest` cell/object enumeration.
- `WorldObjectRecord` transforms, model handles, capability flags, categories,
  spawn routes, and generic light metadata.
- `WorldAssetProvider` source-neutral model/resource access.
- `WorldObjectSpawnAdapter` as the source-owned facade for object wrapping,
  interaction metadata, actors, lights, and parser-specific payloads.

The Morrowind adapter owns source-specific concepts:

- ESM/ESP records, BSA archives, NIF model quirks, LAND/LTEX terrain data, and
  DDS/material repair.
- Morrowind unit, axis, rotation, and cell-size conversion.
- SCVR/dialogue semantics, journal/disposition rules, source parser records,
  and source-specific gameplay metadata translation.
- Carryable, door, container, activator, NPC, creature, leveled-creature, light
  flag, and visual-proxy post-processing that depends on Morrowind data.

## Consequences

Generic core code may branch on normalized categories, capability flags, spawn
routes, model handles, transforms, and source-neutral metadata. It must not ask
for ESM records, NIF paths as a source format, MW unit conventions, SCVR fields,
cell refs, or Morrowind adapter classes.

`get_source_*` bridges in generic world code are migration debt. They are not
accepted framework API and should be deleted as normalized manifest/object
paths replace the remaining legacy cell routes.

## Contract Test

`tests/unit/test_world_source_boundary.gd` is the executable proof for the
current object-streaming boundary. The fake source must stream an exterior cell,
spawn static, interactive, actor, and light records through `CellManager`, use a
fake asset provider, attach interaction metadata in the spawn adapter, and do
all of that without Morrowind parser records or source-specific imports.

`tests/unit/test_adapter_boundary.gd` is the ratchet. It keeps exact ledgers for
known `src/core/world/` source-shaped debt and fails if new generic world files
start depending on Morrowind/parser/importer markers.
