# NPC Assembly — Bug Report & Code Quality Issues

Date: 2026-02-09
Test scene: `src/tools/body_part_diagnostic.tscn`

---

## Active Bugs

### Bug 1: Left-side limbs have wrong normals (dark/inverted lighting) — FIXED (2026-02-10)

**Root cause:** The old code used a hybrid approach — mesh-level winding reversal + transform-level
`scale(-1,1,1)`. This depended on Godot's `MODEL_NORMAL_MATRIX` behavior for negative-determinant
transforms, which proved unreliable across multiple attempts (double-flip, hollow, dark).

**Fix:** Replaced with **full mesh-space mirror** — flip vertex X, normal X, and reverse winding
all in mesh data. Transform uses NO negative scale (conjugated node_transform instead).
This is the same strategy already working for skinned parts (`_attach_skinned_mesh_mirrored()`).
`_create_mirrored_mesh()` replaces the old `_create_mirrored_static_mesh()`.

**Transform derivation:**
```
right_att * mirror * node_xf * vertex = right_att * (M * node_xf * M) * mirrored_vertex
T = att * bone_offset * Transform3D(M * basis * M, M * origin)  # NO negative scale
```

**Visually confirmed** with `body_part_diagnostic.tscn` — press N for normal vis, left side
now shows correct mirrored normals (cyan where right shows red).

---

### Bug 2: 6+ floating hand meshes around the character — FIXED (2026-02-10)

**Symptom:** 6+ hand-shaped meshes floating at various positions around the character (above head,
at waist level to left/right), completely detached from the body.

**Root cause (two problems):**

1. **Full-body NIF sub-meshes with <=4 bones routed to static path:** When a race has a full-body
   "body.nif" or "skins.nif" that enters the CHEST slot (part_type=3), its sub-meshes are each
   evaluated independently. Sub-meshes with <=4 bones bypassed `is_full_body_skin` and went
   through `_attach_static_mesh()` — but their `node_transform` is in skeleton-root space (e.g.,
   hand geometry positioned at the hand's skeleton-root location). Attaching these to the CHEST
   bone with that large offset produces floating meshes.

2. **Individual limb parts stacking on top of full-body skin:** The CHEST NIF's skinned sub-meshes
   already render the full body (including hands, feet, arms). Individual limb parts (HAND_R/L,
   WRIST_R/L, FOREARM_R/L, etc.) are ALSO loaded and rendered as static attachments. Each pair
   (right + mirrored left) produces 2 more meshes. With 3+ limb types that have hand-like
   geometry (hand, wrist, forearm), this easily reaches 6+ extra meshes.

**Fix (two-part):**

1. **Force skinned path for ALL sub-meshes from full-body NIFs:** In `_attach_body_part_native()`,
   when processing a non-limb slot (CHEST, GROIN), if ANY sub-mesh has >4 bones, ALL skinned
   sub-meshes from that NIF go through the skinned path. Their `inv_bind_poses` and
   `skin_transform` correctly position the geometry via the skinning pipeline.

2. **Skip individual limb parts when full-body skin covers them:** In `_collect_body_parts()`,
   after loading all ESM parts, detect if any non-limb slot contains a full-body skin. If so,
   remove individual limb slots (HAND_R, WRIST_R, FOREARM_R, etc.) since the full-body skin
   already provides that geometry via bone weights.

**Debug logging:** Enable `MorrowindNPCAssembler.debug_mode = true` (diagnostic scene does this
automatically) to see: ESM parts found, slot assignments, full-body skin detection, limb part
skipping, and per-mesh routing decisions (SKINNED vs STATIC).

---

### Bug 3: Vertex stretching at hand/wrist area — likely fixed by Bug 2 fix

**Symptom:** In the textured view, vertices near the hands/wrists are stretched or distorted, creating spiky geometry artifacts around the wrist joints.

**Suspected cause:** Was related to Bug 2. Individual limb NIFs with skin data were being routed
through the GPU skinned path when the CHEST slot contained a full-body NIF. The inv_bind matrices
assumed the mesh would be rendered as a complete body, producing wrong vertex positions for
individual parts. With Bug 2's fix (individual limb parts are now skipped when a full-body skin is
present), this should no longer occur.

---

## Code Quality Issues

### 1. Massive duplication (~600 lines)

`character_assembly_test.gd` (1249 lines) re-implements nearly every function from `morrowind_npc_assembler.gd` (788 lines):

| Function | In assembler | In test | Status |
|----------|-------------|---------|--------|
| `_mirror_bone_name()` | line 730 | line 1174 | Identical copy |
| `_find_bone_ci()` | line 750 | line 640 | Identical copy |
| `_duplicate_skeleton()` | line 192 | line 1234 | Identical copy |
| `_create_mirrored_static_mesh()` | line 696 | line 1069 | Identical copy |
| `_create_mirrored_skinned_mesh()` | inline in 274 | line 1099 | Variant |
| `_create_mirrored_skin()` | inline in 274 | line 1147 | Variant |
| `_collect_attachment_transforms()` | line 534 | line 339 | Identical logic |
| Attachment node name constants | line 67 | line 330 | Identical copy |
| Material creation | line 658 | line 1191 | Near-identical |

These copies drift out of sync. Fixes in one file don't propagate.

### 2. Three sources of truth for slot-to-bone mappings

- `morrowind_body_part_slots.gd:40` — `SLOT_TO_BONE` (enum int → Bip01 bone name)
- `morrowind_npc_assembler.gd:36` — `SLOT_TO_ATTACHMENT_NAME` (enum int → OpenMW attachment node name)
- `character_assembly_test.gd:48` — `TEST_SLOT_TO_BONE` + `SLOT_TO_ATTACHMENT` (string → bone/attachment name)

These represent two different naming systems (NIF skeleton bones vs OpenMW attachment nodes) but the distinction is not clear in the code.

### 3. Four overlapping test files

| File | Lines | What it tests |
|------|-------|---------------|
| `character_assembly_test.gd` | 1249 | Full re-implementation with toggleable modes |
| `npc_assembly_test.gd` | 591 | End-to-end pipeline (calls assembler directly) |
| `native_skeleton_test.gd` | ~300 | Phase 3B skeleton verification |
| `animation_integration_test.gd` | ~400 | Phase 3C animation test |

All test the same pipeline with different levels of duplication. `npc_assembly_test.gd` is the cleanest — it actually calls the assembler. `character_assembly_test.gd` is the worst — it rebuilds everything from scratch.

### 4. mesh_extractor.gd in wrong directory

Lives at `src/core/character/mixamo/mesh_extractor.gd` but is the primary mesh extraction tool for the Morrowind pipeline. The "mixamo" path is a leftover from the original architecture.

### 5. Fragile `is_full_body_skin` heuristic

```gdscript
var is_full_body_skin: bool = extracted.is_skinned and extracted.bone_names.size() > 4
```

Magic number 4. OpenMW checks if the NIF root node is a `Skeleton` type — much more robust. The current heuristic misclassifies hand meshes from skins files (which have many bones but should be treated differently).

### 6. Static-only architecture

`MorrowindNPCAssembler` uses entirely `static` functions with `static var` caches. This makes it hard to test in isolation, impossible to inject dependencies, and the global `debug_mode` static var is a code smell.

---

## Diagnostic Test

`src/tools/body_part_diagnostic.tscn` — uses `MorrowindNPCAssembler.assemble()` directly with zero duplicated logic.

| Key | Function |
|-----|----------|
| N | Normal visualization (world-space normals as RGB) |
| H | Hand/foot bone markers (yellow spheres) |
| B | Full skeleton overlay with bone connections |
| W | Wireframe |
| 1-5 | Preset NPCs (Fargoth, Caius, Ranis, Arrille, Sugar-Lips) |
| RMB | Orbit camera |
| Scroll | Zoom |

---

## Reference Documents

- `docs/OPENMW_BODY_SYMMETRY.md` — How OpenMW handles mirroring (Path A vs Path B)
- `docs/ANIMATION_OVERHAUL.md` — Animation pipeline phases
- `docs/DATA_PIPELINE.md` — NIF/ESM data format details
