# NIF Unsupported Records — Prebaking Failure Catalog

> Reference — bug catalog. 64 NIF models from Morrowind vanilla data that currently fail to parse through Godotwind's NIF pipeline as of 2026-04-08. Useful when fixing the parser. Updated manually.

Recorded from bake run on **2026-04-08** after wiping `cache/models/` and re-baking against commit `b89a1f8` + LOD error-budget patch.

**Result:** `4884 baked, 0 skipped, 64 failed` (98.7% success rate).

This is a pre-existing parser limitation, not a regression. The bake path uses the GDScript `NIFReader` (`src/core/nif/nif_reader.gd`) via `NIFConverter.convert_buffer()`, not the C# `NativeNIFReader`. Fixing the underlying record-type gap needs to land in `nif_reader.gd::_read_record` (line 144 / 352).

---

## Failure signature

Every logged failure produces the same two-line pattern:

```
ERROR: NIFReader: Invalid string length 1399410176 at pos <N> - parser out of sync
ERROR: NIFReader: Unknown record type '' at index <K> in '<PATH>' - aborting
```

`1399410176 = 0x53694E00` — as little-endian bytes `[0x00, 0x4E, 0x69, 0x53]`, ASCII `"\0NiS"`. This is the signature of a string-length field being read at a misaligned offset where the preceding record wrote a null terminator followed by the start of the next record's type name (`"NiS..."` — likely `NiSourceTexture`, `NiStringExtraData`, `NiSpecularProperty`, `NiStencilProperty`, etc.).

**Interpretation:** a record type handler under-reads the stream by exactly 4 bytes, propagating the parser cursor past the end of its record into the next record's type-name field. The NEXT `_read_record` call then reads `0x53694E00` as the length of a string and aborts.

Root cause is almost certainly **a single missing field or under-counted flags word** in one of the property record readers. Because so many visually different NIFs (armor, weapons, portals, Telvanni organic, effects) share the same exact byte signature, the culprit is a record type that is COMMON across all of them — a shared property/extra-data node, not a gameplay-specific one. Best candidates:

- `NiStringExtraData` (shader flags, enchant glow hooks)
- `NiTextKeyExtraData` (animation text keys)
- `NiVertexColorProperty` (recently touched in `NativeNIFReader.cs` — worth double-checking the GDScript sibling parser)
- `NiZBufferProperty` / `NiSpecularProperty` (just added to C# in commit `8bf17e4`; the GDScript `nif_reader.gd` reader may still be on the old "skip 2 bytes" stub)
- `NiParticleSystemController` + subclasses (for the `magic_*` and `active_port_*` families)
- `NiBSAnimationNode` / `NiBSParticleNode` (Bethesda-specific subclasses)

**First thing to try when fixing:** diff `nif_reader.gd::_read_record` against the updated `NativeNIFReader.cs::ReadNiZBufferProperty` / `ReadNiSpecularProperty`. If the GDScript side still does `_skip(2)` where C# now reads `ZBufFlags` as `u16` — that's a candidate but the delta is only 2 bytes, not 4. Keep looking for a 4-byte under-read.

---

## Logged failures (30 unique paths, visible in bake log)

### Armor — glass / ebony / imperial (8)

| Path | Aborted at record index |
|---|---|
| `a\A_Ebony_Cuirass.NIF` | 12 |
| `a\A_Glass_Boots_A.nif` | 17 |
| `a\A_Glass_Boots_GND.nif` | 17 |
| `a\A_Glass_Pauldron_FA.nif` | 15 |
| `a\A_Glass_Pauldron_GND.nif` | 19 |
| `a\A_Glass_Pauldron_UA.nif` | 19 |
| `a\A_Imperial_Pauldron_GND.nif` | 3 |
| `a\Towershield_Glass.nif` | 11 |

### Weapons — enchant/glow candidates (4)

| Path | Index |
|---|---|
| `w\W_Silver_Claymore.nif` | 7 |
| `w\W_battleaxe_daedric.NIF` | 25 |
| `w\W_shortsword00.nif` | 23 |
| `w\W_staff00.nif` | 11 |

### Magic effect NIFs (2)

| Path | Index |
|---|---|
| `e\magic_area_alt.NIF` | 103 |
| `e\magic_cast_restore.NIF` | 5 |

### Vivec active portals (11)

All 10 `active_port_*` abort at the same index (4), strongly suggesting identical tree structure authored by the same script. `in_strong_portal_chamber` aborts later at index 34.

| Path | Index |
|---|---|
| `i\active_port_Andra.NIF` | 4 |
| `i\active_port_Beran.NIF` | 4 |
| `i\active_port_Falag.NIF` | 4 |
| `i\active_port_Falen.NIF` | 4 |
| `i\active_port_Hlor.NIF` | 4 |
| `i\active_port_Indo.NIF` | 4 |
| `i\active_port_Maran.NIF` | 4 |
| `i\active_port_Roth.NIF` | 4 |
| `i\active_port_Telas.NIF` | 4 |
| `i\active_port_Valen.NIF` | 4 |
| `i\in_strong_portal_chamber.NIF` | 34 |

### Telvanni organic interiors (3)

| Path | Index |
|---|---|
| `i\In_T_councilhall.nif` | 4 |
| `i\In_T_crystal_01.NIF` | 3 |
| `i\In_T_crystal_02.NIF` | 3 |

### Architecture (2)

| Path | Index |
|---|---|
| `x\Ex_common_dormer_round.NIF` | 4 |
| `x\ex_dwrv_ruin30.nif` | 3 |

---

## Previously-silent failures (34) — reason-tagged after Log.warn instrumentation landed

Re-baked after `model_prebaker.gd::bake_model` got `Log.warn("prebaking", "FAIL (<reason>):")` calls on all three failure branches. Result: the 64 = 30 parser failures (above) + 28 effect-only NIFs that produce zero meshes + 6 NIFs missing from BSA.

### `FAIL (no meshes)` — 28 files, particle-only NIFs

These parse successfully but `_save_model_to_cache` returns `mesh_count == 0` because the NIF root tree is entirely particle systems / effect nodes / animation controllers — no `NiTriShape` or `NiTriStrips` geometry. Not actually broken, the prebaker is just scanning them as if they were normal static models. **Fix is to filter at `_collect_unique_models()` time, not to make them parse harder.**

```
e\SoulTrapHit.NIF
e\corprus.NIF
e\hand01.NIF
e\magic_area_ill.NIF
e\magic_cast.NIF
e\magic_cast_S.NIF
e\magic_cast_alt.NIF
e\magic_cast_conjure.NIF
e\magic_cast_fortify.NIF
e\magic_cast_frost.NIF
e\magic_cast_ill.NIF
e\magic_cast_levitate.NIF
e\magic_cast_poison.NIF
e\magic_hit.NIF
e\magic_hit_dst.NIF
e\magic_hit_ill.NIF
e\magic_hit_myst.NIF
e\vfx_pattern02.NIF
e\vfx_pattern03.nif
e\vfx_pattern04.NIF
e\vfx_pattern05.NIF
e\vfx_pattern06.NIF
e\vfx_pattern07.NIF
e\vfx_pattern08.NIF
w\magic_target.NIF
w\magic_target_dst.NIF
w\magic_target_myst.NIF
w\magic_target_poison.NIF
```

All in `meshes/e\` (magic effects) or `meshes/w\` (weapon-attached effects). These reference particle systems, animated meshes, and shader-only nodes. The pipeline should treat them as a separate "effect NIF" category and route them through whatever VFX system handles particles at runtime — currently nothing because particles aren't wired up yet.

### `FAIL (not in BSA)` — 6 files, missing data references

ESM records reference NIFs that don't exist in any loaded BSA. Either Bethesda dev leftovers, mod-only assets, or paths that got renamed in a patch. Nothing parsable to fix here — the right behaviour is to log once at ESM scan time and silently skip during bake.

```
i\active_akula_fire.NIF
i\active_akula_frost.NIF
i\active_akula_lightning.NIF
i\active_akula_shield.NIF
w\magic_target_L.NIF
w\magic_target_S.NIF
```

The four `active_akula_*` are particle effect placeholders for Akulakhan in Vivec, never shipped as static NIFs. The two `magic_target_L/S` are large/small variants of `magic_target` that exist in the ESM but not the BSA — likely was meant to be procedurally scaled at runtime.

---

## Real fix scope

After categorising, **only the 30 `FAIL (conversion)` files need a parser fix.** The other 34 are pipeline / data classification problems, not parser bugs:

- 28 particle-only NIFs → filter out of `_collect_unique_models()` or route to a `bake_effect_nif()` path that doesn't expect mesh output
- 6 BSA-missing → log once at ESM scan and drop from the pending list

So the user's "100% model import" target collapses to **30 NIFs sharing a single 4-byte under-read bug in `nif_reader.gd::_read_record`** plus a small `model_prebaker.gd::_collect_unique_models` filter rewrite.

---

## Follow-up tickets (deferred until parser fix lands)

Both items are noise reduction, not correctness — they make the failure count meaningful so a real regression actually stands out.

1. **Particle-only bypass filter** — add `should_bake_as_mesh(nif_path) -> bool` to `_collect_unique_models()` in `src/tools/prebaking/model_prebaker.gd`. Detect particle-system NIFs upfront via header peek (NIF root has only `NiParticleSystemController` / `NiAutoNormalParticles` / etc.) OR pattern match on `meshes/e\*` + `meshes/w\magic_target_*`. Route to a particle/effect handler or drop from the candidate list. Removes the 28 false positives from every future bake summary. ~5-line change once the discriminator is chosen.

2. **Missing-BSA pre-scan** — at ESM scanner startup, walk the model paths once and emit `Log.warn("prebaking", "ESM references missing NIF: %s (skipping)" % path)` for the orphans, then exclude from the pending list. Don't re-check on every bake run. If a future BSA ships them they automatically rejoin the candidate list.

Both file as a single follow-up commit after the parser fix lands.

---

## Next-step checklist when picking this up

1. Re-run `res://src/tools/prebaking/prebaking_ui.tscn` → Bake Models (skip_existing does the right thing — only the 64 failures retry).
2. Grep the new log for `FAIL (` prefix to get the complete 64-model list.
3. Split by reason tag (`not in BSA` / `conversion` / `no meshes`).
4. For the 30 parser failures: write a small test case against one of the `active_port_*` NIFs (they're the cleanest — all abort at index 4, identical tree). Dump the raw bytes from BSA, read records 0..3 manually, identify which record under-reads by 4 bytes.
5. Patch `nif_reader.gd` (not `NativeNIFReader.cs` — the prebake path is still GDScript-side).
6. Rebake just the affected NIFs via `targeted_rebake.tscn` (or hand-delete + re-run).

---

## Notes for future bake runs

- Cosmetic: the GDScript `NIFReader` backtrace shows `nif_reader.gd:2023`, `:144`, `:115`, `:71` — the "Invalid string length" error could carry the NIF path in the same message as "Unknown record type" so failures show up as a single log line instead of two.
- `MeshOptimizer: Using native meshoptimizer library` prints once per `MeshOptimizer.new()` — currently spams the log thousands of times during bake. Should use `Log.debug` or a static-once guard.
- `prebaking_manager.gd:671` receives `model_baked` signal but doesn't write `failed_models` to `PrebakeState.models.failed`. The state file's `models.failed=[]` misrepresents what happened. A two-line fix in the connect-lambda would persist the list for later inspection.
