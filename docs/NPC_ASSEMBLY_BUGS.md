# NPC Assembly — Bug Report & Code Quality Issues

Date: 2026-02-09
Test scene: `src/tools/body_part_diagnostic.tscn`

---

## Active Bugs

### Bug 1: Left-side limbs have wrong normals (dark/inverted lighting) — FIXED

**Root cause:** Double normal flip. The code pre-flipped normal.x in mesh data AND Godot's
`MODEL_NORMAL_MATRIX` (`basis.inverse().transposed()`) also flips normal.x for `scale(-1,1,1)`.
The two flips cancel out, leaving normals pointing the same direction as the right side.

**Fix:** Removed the normal pre-flip from `_create_mirrored_static_mesh()`. Now only
Godot's MODEL_NORMAL_MATRIX handles the normal flip (single flip = correct).
Winding reversal is kept (cancels GPU winding flip from negative scale → CULL_BACK works).

**Key insight:** The MEMORY.md entry claiming "Godot's MODEL_NORMAL_MATRIX does NOT correctly
flip normals" was WRONG. `basis.inverse().transposed()` of `diag(-1,1,1)` = `diag(-1,1,1)`,
which correctly flips normal X. This matches what OpenMW's OSG does (inverse-transpose).

---

### Bug 2: Hand meshes floating above the character

**Symptom:** Two hand meshes appear high above the character's head, completely detached from the body. Small hand-shaped geometry visible floating in the air.

**Where it happens:** The hand meshes from the "skins" NIF file (e.g. `b_n_wood elf_m_skins.nif`) are full-body skinned meshes (many bones). The assembler's `_collect_body_parts()` assigns them to HAND_R, then creates HAND_L by copying the same data.

**Suspected cause:** The skins file contains a full-body mesh with geometry for BOTH hands already via bone weights. The assembler:
1. Assigns skins mesh data to HAND_R slot
2. Copies HAND_R data to HAND_L slot
3. For HAND_R: `is_full_body_skin = true` (many bones) → calls `_attach_skinned_mesh_native()` — renders the FULL body mesh as a "hand" part, but the inv_bind matrices position it incorrectly because the skin_transform composition is wrong for a part that was already correctly positioned
4. For HAND_L: `is_mirrored + is_full_body_skin` → calls `_attach_skinned_mesh_mirrored()` — X-flips vertices of a mesh that already has both-side geometry, producing garbage

**Root issue:** The `is_full_body_skin` heuristic (`bone_names.size() > 4`) routes hand meshes through the GPU skinning path when they should go through the static attachment path. OpenMW determines this by checking if the NIF root node is a Skeleton type — not by counting bones.

**Relevant code:**
- `morrowind_npc_assembler.gd:223` — `is_full_body_skin` heuristic
- `morrowind_npc_assembler.gd:597-601` — left-side slot creation from right-side data
- `morrowind_npc_assembler.gd:225-231` — routing based on `is_full_body_skin`

---

### Bug 3: Vertex stretching at hand/wrist area

**Symptom:** In the textured view, vertices near the hands/wrists are stretched or distorted, creating spiky geometry artifacts around the wrist joints.

**Suspected cause:** Related to Bug 2. The skinning composition `inv_bind_poses[i] * skin_transform` may be incorrect for meshes that are being attached as individual parts but treated as full-body skins. The inv_bind matrices from the NIF assume the mesh is rendered as a complete body — using them for a subset of the geometry (just hands) produces wrong vertex positions.

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
