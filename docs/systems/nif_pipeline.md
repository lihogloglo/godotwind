# NIF Pipeline — Parse, Convert, Bake

**Status:** shipping. Geometry, materials (glow maps, HILIGHT, ZBuffer, specular color), skeletons, animations (five controller types), collision, particles, and lights all flow through per `docs/STATUS.md`. See open items at bottom.

Godotwind's NIF pipeline reads Bethesda `.nif` models from BSA archives, converts them to Godot-native scenes, and caches the results as `PackedScene` resources for async streaming. Binary parsing is split between a GDScript reader used by the prebake path and a C# reader used at runtime — the GDScript side is authoritative when you are fixing record-type gaps (see Open Items).

## Key Files

| Path | Role |
|---|---|
| `src/core/nif/nif_reader.gd` | GDScript NIF binary reader — used by model prebaker |
| `src/core/nif/nif_converter.gd` | NIF record tree → Godot scene (Node3D / MeshInstance3D / Skeleton3D) |
| `src/core/nif/nif_collision_builder.gd` | NIF collision nodes → `CollisionShape3D` + `StaticBody3D` |
| `src/native/NativeNIFReader.cs` | C# NIF binary reader — used at runtime paths |
| `src/native/NativeNIFConverter.cs` | C# record → Godot mesh conversion |

## Coordinate invariant

Morrowind's NIF format is Z-up right-handed, units of 1/70 m. Godot is Y-up right-handed, units of 1 m. Every transform and every vector crossing the NIF → Godot boundary goes through `src/core/coordinate_system.gd`:

```gdscript
# src/core/coordinate_system.gd:88
static func vector_to_godot(mw: Vector3, apply_scale: bool = APPLY_SCALE) -> Vector3:
    # returns Vector3(mw.x, mw.z, -mw.y) * (1/70)
```

The full transform form is `transform_to_godot(mw: Transform3D) -> Transform3D` at `:195`, which delegates to `basis_to_godot` (`:173`) for the rotation and `vector_to_godot` for the origin. Similarity transforms distribute over concatenation, so local-then-accumulate and accumulate-then-convert give identical results — but mixing the two produces scrambled axes, which is exactly the bug §NIF_COLLISION_COORDINATE_BUG documented.

**Invariant:** inside `nif_collision_builder.gd` after Part 1 of the coordinate fix (shipped 2026-04-15), every `Transform3D` in scope is Godot-space. The two accumulation sites (`_process_collision_node` at `:189-190` and `_process_collision_geometry` at `:243-244`) both call `CS.transform_to_godot(node.transform.to_transform3d())` before composing with `parent_transform`. Downstream vertex / bounding-volume conversions remain in place on the leaf side, so `T_godot * v_godot` is a coherent product.

**Part 2 is still open** — trimesh fallback for NIFs that have no `RootCollisionNode` or `bhkCollisionObject` at all. Cross-ref: `docs/plans/nif_collision_part2.md`.

## Audit statistics (2026-04-05 bake, 7319 NIFs)

### Texture slots

| Slot | Count | % of base | Notes |
|---|---|---|---|
| Base (0) | 25600 | 100% | — |
| Dark (1) | 36 | 0.1% | daedric chest, daedric key, 6th ash statue, menu_help, menu_main |
| Detail (2) | 0 | 0.0% | unused |
| Gloss (3) | 0 | 0.0% | unused |
| Glow (4) | 20 | 0.1% | ice troll, udyrfrykte, draugrlord |
| Bump (5) | 0 | 0.0% | unused |
| Decal (6) | 0 | 0.0% | unused |

Multi-texture slot usage is 56 instances across 25600 base textures (0.2%). Routing decision: hybrid `StandardMaterial3D` + `ShaderMaterial` — 99.8% land on SM3D.

### Apply modes

| Mode | Count |
|---|---|
| MODULATE (2) | 25322 |
| HILIGHT (3) | 283 |
| REPLACE / DECAL / HILIGHT2 | 0 |

HILIGHT examples: redguard knee / neck / ankle meshes.

### Animation controllers

| Controller | Count |
|---|---|
| NiKeyframeController | 5954 |
| NiParticleSystemController | 665 |
| NiGeomMorpherController | 318 |
| NiVisController | 309 |
| NiAlphaController | 183 |
| NiUVController | 98 |
| NiPathController | 56 |
| NiMaterialColorController | 10 |
| NiFlipController / NiRollController / NiLookAtController | 0 |

### Properties

| Property | Count | Notes |
|---|---|---|
| NiZBufferProperty | 1330 | 1030 non-default |
| NiWireframeProperty | 12 | |
| NiSpecularProperty | 8 | all enabled |
| NiStencilProperty / NiFogProperty | 0 | |

### Environment maps

Zero `NiTextureEffect` instances across the dataset — no sphere maps, no cube maps. Env-map code paths are dead weight and can be stripped when the reader sees cleanup.

## Parse failures — 64 NIFs (Morrowind vanilla)

98.7% success rate on the 2026-04-08 bake run (`4884 baked, 0 skipped, 64 failed`). Of the 64:

- **30 parser failures** — all produce the same signature: `Invalid string length 1399410176 at pos N - parser out of sync`. `1399410176 = 0x53694E00` — little-endian `[0x00, 0x4E, 0x69, 0x53]`, ASCII `"\0NiS"`. A record handler under-reads the stream by exactly 4 bytes; the next `_read_record` call reads the trailing null + start of the next type name (`NiS...`, likely `NiSourceTexture` / `NiStringExtraData` / `NiSpecularProperty` / `NiStencilProperty`) as a string length. Since all 30 share the signature across armor, weapons, portals, Telvanni interiors, and effects, the culprit is a shared property/extra-data node, not a gameplay-specific one.
- **28 particle-only NIFs** — parse successfully, produce zero meshes. Should be filtered at `_collect_unique_models()` time, not "made to parse harder".
- **6 NIFs missing from BSA** — ESM references to assets that don't exist in any loaded archive (Bethesda dev leftovers / removed-in-patch paths). Belongs in a one-shot ESM pre-scan log.

Full catalog with paths + abort indices: `docs/reference/nif_unsupported.md`.

Fix target is `src/core/nif/nif_reader.gd::_read_record` — the prebake path is still GDScript-side. `NativeNIFReader.cs` was updated in commit `8bf17e4` with new `NiZBufferProperty` / `NiSpecularProperty` readers; diff the GDScript sibling against that C# update as a starting point.

## Open items

1. **`NiGeomMorpherController` parsed but not applied** — 318 instances in the dataset, including most creature and NPC face meshes. Blocks dialogue facial animation. Reader walks the record, converter drops the keys. Per `docs/STATUS.md:65`.
2. **Collision Part 2** — trimesh fallback for NIFs with no collision nodes. Plan: `docs/plans/nif_collision_part2.md`.
3. **Parser 4-byte under-read** — the 30 failing NIFs, see §Parse failures. Catalog: `docs/reference/nif_unsupported.md`.

## History

- `docs/reference/nif_audit_statistics.md` — 2026-04-05 statistical dump, source for §Audit statistics.
- Collision coordinate bug — 2026-04-09 diagnosis + 2026-04-15 Part 1 fix folded into this doc above; Part 2 split out to `docs/plans/nif_collision_part2.md`.
- `docs/reference/nif_unsupported.md` — 2026-04-08 bake failure catalog.
