# NPC Body Part Assembly — Research & Fix Plan

**Date:** 2026-02-09
**Status:** Research complete, implementation pending
**Context:** Characters show only chest + hands. Other body parts (arms, legs, head, feet) are missing.

---

## Table of Contents

1. [Problem Statement](#problem-statement)
2. [How Morrowind NIF Body Parts Work](#how-morrowind-nif-body-parts-work)
3. [How OpenMW Assembles NPCs (Reference Implementation)](#how-openmw-assembles-npcs)
4. [OpenMW Skinning Math](#openmw-skinning-math)
5. [Our Current Implementation & What's Wrong](#our-current-implementation--whats-wrong)
6. [Fix Plan — Generic Body Part Assembly](#fix-plan)
7. [Architecture: Morrowind as Adapter](#architecture-morrowind-as-adapter)
8. [Key Source Files](#key-source-files)

---

## Problem Statement

When assembling Morrowind NPCs from body parts:
- Only the **"skins" file** (chest + hands + wrists) renders correctly
- Individual body parts (upper arm, forearm, knee, ankle, foot, neck, head, etc.) are **missing**
- The `character_assembly_test.tscn` confirms: only skinned meshes show, other parts vanish

Root cause: **Morrowind body parts use two different attachment methods** (skinned vs bone-parented), and our code only handles the skinned path correctly. Most individual body parts are non-skinned rigid meshes that should be attached to specific bones.

---

## How Morrowind NIF Body Parts Work

### The Two Types of Body Part Meshes

Morrowind body part NIFs come in **two forms**:

#### Type A: Skinned Meshes (have NiSkinInstance + NiSkinData)

- The NIF contains `NiTriShape` nodes with a `skin_index >= 0`
- Vertices are deformed per-frame by multiple bones (GPU skinning)
- Used for parts that **span joints**: the "skins" file (chest + hands + wrists), and potentially some multi-bone parts
- The "skins" file (`b_n_<race>_<gender>_skins.nif`) is the primary example — it contains sub-meshes for the torso, hands, and wrists as a single skinned unit
- NiSkinData contains:
  - `skin_transform`: overall transform from mesh space → skeleton root space
  - Per-bone: inverse bind matrix (mesh space → bone-local space at bind time)
  - Per-bone: vertex weight list

#### Type B: Non-Skinned Meshes (no NiSkinInstance)

- The NIF contains `NiTriShape` nodes with `skin_index == -1`
- Vertices are in bone-local space (authored relative to the attachment bone)
- The mesh follows a single bone rigidly — no per-vertex deformation
- Used for parts that are **single-bone segments**: upper arm, forearm, upper leg, knee, ankle, foot, head, hair, neck, wrist
- In the original Morrowind engine, body parts are segmented at joints. Each segment is a rigid piece that follows its bone. The joints between segments have slight overlaps hidden by the low-poly geometry.

#### How to Tell Which Type a NIF Contains

Check `NiTriShape.skin_index`:
- `>= 0` → Skinned (Type A). Has NiSkinInstance referencing bones.
- `== -1` → Non-skinned (Type B). Static mesh, needs bone attachment.

### Morrowind Skeleton Structure

The base skeleton comes from `xbase_anim.nif` (humanoid) or `xbase_animkna.nif` (beast races).

The skeleton NIF contains **only NiNode hierarchy** — no geometry. Bone NiNodes use the `Bip01` naming convention:

```
Bip01 (root)
├── Bip01 Pelvis
│   ├── Bip01 Spine
│   │   ├── Bip01 Spine1
│   │   │   ├── Bip01 Spine2
│   │   │   │   ├── Bip01 Neck
│   │   │   │   │   └── Bip01 Head
│   │   │   │   ├── Bip01 L Clavicle
│   │   │   │   │   └── Bip01 L UpperArm
│   │   │   │   │       └── Bip01 L Forearm
│   │   │   │   │           └── Bip01 L Hand (+ finger chains)
│   │   │   │   └── Bip01 R Clavicle (mirrors L side)
│   ├── Bip01 L Thigh
│   │   └── Bip01 L Calf
│   │       └── Bip01 L Foot
│   │           └── Bip01 L Toe0
│   └── Bip01 R Thigh (mirrors L side)
```

**Important:** The NiNode hierarchy also contains non-bone nodes like "Scene Root" and named attachment points like "Head", "Chest", "Right Hand", etc. OpenMW uses these **readable names** (not Bip01 names) for body part attachment. However, our skeleton builder only collects nodes with `Bip01` prefix as bones.

### Left-Side Mirroring

Morrowind ships only **right-side body part meshes** for symmetrical parts. Left-side geometry is created at runtime by:
1. Loading the same right-side mesh
2. Attaching it to the corresponding left bone
3. Applying `scale(-1, 1, 1)` on the X axis (mirror)
4. Inverting face culling (CW → CCW) to compensate for the negative scale

This means each body part mesh may reference BOTH left and right bones (if skinned) or only the right bone (if non-skinned, then mirrored for left).

---

## How OpenMW Assembles NPCs

Source: `inspos/openmw/apps/openmw/mwrender/npcanimation.cpp`

### Step 1: Load Base Skeleton

```cpp
// From actorutil.cpp — select skeleton based on race/gender
if (isBeast) return "meshes/xbase_animkna.nif";
else if (isFemale) return "meshes/xbase_anim_female.nif";
else return "meshes/xbase_anim.nif";

// Load as scene graph root — skeleton is the root node
setObjectRoot(skeletonModel, true, true, false);
```

### Step 2: Part-to-Bone Mapping

OpenMW defines a static mapping from body part type → bone **NiNode name**:

```cpp
// npcanimation.cpp:236-250
const NpcAnimation::PartBoneMap sPartList = {
    { PRT_Head,       "Head" },
    { PRT_Hair,       "Head" },           // same bone as head, filtered by name
    { PRT_Neck,       "Neck" },
    { PRT_Cuirass,    "Chest" },
    { PRT_Groin,      "Groin" },
    { PRT_Skirt,      "Groin" },
    { PRT_RHand,      "Right Hand" },
    { PRT_LHand,      "Left Hand" },
    { PRT_RWrist,     "Right Wrist" },
    { PRT_LWrist,     "Left Wrist" },
    { PRT_RForearm,   "Right Forearm" },
    { PRT_LForearm,   "Left Forearm" },
    { PRT_RUpperarm,  "Right Upper Arm" },
    { PRT_LUpperarm,  "Left Upper Arm" },
    { PRT_RFoot,      "Right Foot" },
    { PRT_LFoot,      "Left Foot" },
    { PRT_RAnkle,     "Right Ankle" },
    { PRT_LAnkle,     "Left Ankle" },
    { PRT_RKnee,      "Right Knee" },
    { PRT_LKnee,      "Left Knee" },
    { PRT_RLeg,       "Right Upper Leg" },
    { PRT_LLeg,       "Left Upper Leg" },
    { PRT_RPauldron,  "Right Clavicle" },
    { PRT_LPauldron,  "Left Clavicle" },
    { PRT_Weapon,     "Weapon Bone" },
    { PRT_Tail,       "Tail" },
};
```

**Note:** These bone names ("Head", "Chest", "Right Hand") are **NiNode names** in the xbase_anim.nif hierarchy — NOT the `Bip01` bone names. The xbase_anim.nif hierarchy contains both: Bip01 bones for animation AND named nodes for attachment. Our skeleton builder only keeps Bip01 nodes, so we use `SLOT_TO_BONE` which maps to Bip01 names instead.

### Step 3: Collect Body Parts

```cpp
// For each body part slot (Neck through Tail):
const std::vector<const ESM::BodyPart*>& parts = getBodyParts(race, isFemale, ...);
for (int part = PRT_Neck; part < PRT_Count; ++part) {
    if (mPartPriorities[part] < 1) {
        if (const ESM::BodyPart* bodypart = parts[part])
            addOrReplaceIndividualPart(part, -1, 1, bodypart->mModel);
    }
}
// Head and hair handled separately (can be overridden per-NPC)
```

### Step 4: Attach via `SceneUtil::attach()`

Source: `inspos/openmw/components/sceneutil/attach.cpp`

This is where the **two-path logic** lives:

```cpp
osg::ref_ptr<osg::Node> attach(toAttach, master, filter, attachNode, ...) {
    if (dynamic_cast<const Skeleton*>(toAttach.get())) {
        // PATH A: Body part NIF contains a skeleton (has RigGeometry)
        // → Copy RigGeometry nodes directly into the master skeleton scene graph
        // → RigGeometry will find bones by name at render time
        CopyRigVisitor copyVisitor(handle, filter);
        toAttach->accept(copyVisitor);
        copyVisitor.doCopy(sceneManager);
        master->asGroup()->addChild(handle);
    } else {
        // PATH B: Body part NIF is a plain mesh (no skeleton)
        // → Clone the mesh
        // → Look for "BoneOffset" node for position adjustment
        // → If bone name contains "Left", apply scale(-1, 1, 1) for mirroring
        // → Attach as child of the bone node
        clonedToAttach = sceneManager->getInstance(toAttach);

        // Left-side mirroring
        if (attachNode->getName().find("Left") != std::string::npos) {
            trans->setScale(osg::Vec3f(-1.f, 1.f, 1.f));
            // Invert face culling to compensate
        }

        attachNode->addChild(clonedToAttach);
    }
}
```

**Key insight:** RigGeometry finds the skeleton by walking UP the scene graph (`initFromParentSkeleton`), then looks up each bone **by name** (`mSkeleton->getBone(info.mName)`). Bones are matched case-insensitively. This means skinned body parts don't need to be children of a specific bone — they just need to be somewhere in the skeleton's scene subtree.

---

## OpenMW Skinning Math

Source: `inspos/openmw/components/sceneutil/riggeometry.cpp:140-235`

### Per-Frame Vertex Skinning

```cpp
// Step 1: Compute per-bone skinning matrix
// For each bone i:
boneMat[i] = InvBind[i] * BoneCurrent[i];
//   InvBind[i]    = from NiSkinData.bones[i].transform (stored as-is, already inverted)
//   BoneCurrent[i] = bone's accumulated transform in skeleton space (from animation)

// Step 2: Compute skin transform (overall mesh offset)
if (mSkinToSkelMatrix)
    transform = skinToSkelMatrix * NiSkinData.transform;  // with hierarchy offset
else
    transform = NiSkinData.transform;                      // direct

// Step 3: For each vertex group (vertices sharing same bone influences):
resultMat = Σ(boneMat[i] * weight[i]);   // weighted sum of bone matrices
resultMat *= transform;                   // apply skin transform AFTER blending

// Step 4: Transform vertex
v_out = resultMat.preMult(v_in);  // OSG convention: v * M (row vector)
```

### Convention Translation: OSG → Godot

OSG uses **row-major** matrices with **row-vector** multiplication (`v_out = v_in × M`).
Godot uses **column-major** matrices with **column-vector** multiplication (`v_out = M × v_in`).

The equivalent Godot formula:
```
v_out = Σ(BoneCurrent[i] × InvBind[i] × w[i]) × SkinTransform × v_in
```

Which in Godot's `Transform3D` multiplication (where `A * B` means "apply B first, then A"):
```
v_out = SkinTransform × Σ(BoneCurrent[i] × InvBind[i] × w[i]) × v_in
```

### What Godot's Skin Resource Expects

Godot's GPU skinning uses:
```
v_out = Σ(BoneGlobalPose[i] × BindPose[i] × v_in × w[i])
```

Where `BindPose[i]` (the `inv_bind` parameter in `Skin.add_bind()`) should transform from **mesh vertex space** to **bone-local space at bind time**.

For NIF data:
- `NiSkinData.transform` = mesh space → skeleton root space
- `NiSkinData.bones[i].transform` = skeleton root space → bone-local space (at bind time)

Therefore:
```gdscript
# Correct composition for Godot's Skin.add_bind():
bind_pose[i] = per_bone_inv_bind[i] * skin_transform
# In Godot A*B: apply skin_transform first (mesh→skeleton), then per_bone (skeleton→bone)
```

This is what our code currently does in `_create_native_skin()`, so the math for **skinned** parts is correct.

### Coordinate Conversion Validity

`CS.transform_to_godot()` applies `G(M) = C × M × C^T` (conjugation by the conversion matrix).
For orthogonal C where `C^T × C = I`, this distributes over multiplication:
```
G(A) × G(B) = G(A × B)    ✓ (proven by expanding the conjugation)
```
The scale factor (÷70) only affects translation, not basis, so the composition remains valid.

---

## Our Current Implementation & What's Wrong

### Current Pipeline

```
MorrowindNPCAssembler.assemble(npc, race)
├── _get_morrowind_skeleton(is_beast)    → loads xbase_anim.nif as Skeleton3D
├── _collect_body_parts(npc, race)       → gets body part paths from ESM
└── for each body part:
    └── _attach_body_part_native(skeleton, slot, part_data)
        ├── if is_skinned:  _attach_skinned_mesh_native()   ← creates Skin resource
        └── else:           _attach_static_mesh()            ← BoneAttachment3D
```

### Issue 1: Non-Skinned Parts Use Wrong Bone Lookup

**File:** `src/core/character/morrowind/morrowind_npc_assembler.gd`, `_attach_static_mesh()` (line 261)

The current code uses `mesh_data.parent_bone_name` to find the attachment bone. This comes from `MeshExtractor._extract_recursive()` which sets it to the name of the parent NiNode of the geometry in the NIF hierarchy.

**Problem:** For a body part NIF like `b_n_dark elf_m_upper arm.nif`, the hierarchy is typically:
```
NiNode "Scene Root"         ← parent_bone_name becomes "Scene Root"
  └─ NiTriShape "Upper Arm" ← the mesh
```
"Scene Root" doesn't match any skeleton bone → fallback to direct skeleton child with `node_transform` positioning → mesh is static, doesn't follow any bone during animation.

**Fix:** Use the **slot-to-bone mapping** (`BodyPartSlots.SLOT_TO_BONE`) to determine which bone to attach to. The slot is known from the body part collection step but is currently NOT passed through to `_attach_static_mesh()`.

### Issue 2: Test Scene Only Shows Skinned Parts

**File:** `src/tools/character_assembly_test.gd`, `_build_character()` (line 330)

```gdscript
if not extracted.is_skinned:
    continue  # ← All non-skinned body parts are SKIPPED
```

Since most individual body parts (upper arm, forearm, knee, ankle, foot, head, etc.) are non-skinned rigid meshes, they're invisible in the test. Only the "skins" file (which IS skinned) shows up.

**Fix:** Handle both skinned and non-skinned parts in the test visualization.

### Issue 3: No Left-Side Mirroring

**File:** `src/core/character/morrowind/morrowind_body_part_slots.gd`, `part_type_to_slots()` (line 116)

The comment says "each naked body part mesh contains geometry for BOTH sides" and returns only the right slot. However, this may only be true for the "skins" file (which contains geometry for both hands/wrists). Individual body parts likely need explicit mirroring.

OpenMW mirrors left-side parts with `scale(-1, 1, 1)` + inverted face culling.

**Current state:** Left-side slots never receive body part data → half the body is missing.

**Fix:** For non-skinned parts, load the same mesh for both L and R slots, applying X-axis mirror transform for the L side. For skinned parts that reference both L and R bones in their NiSkinData, a single mesh handles both sides (no mirroring needed).

### Issue 4: Slot Not Passed to Attachment Functions

**File:** `src/core/character/morrowind/morrowind_npc_assembler.gd`, `_attach_body_part_native()` (line 167)

The slot integer IS passed to `_attach_body_part_native()` and forwarded to `_attach_skinned_mesh_native()` and `_attach_static_mesh()` — but only for naming. It's **not used for bone lookup**. The static attachment function tries to derive the bone from the NIF hierarchy, which fails.

### Issue 5: Potential inv_bind Accuracy for Skinned Parts

For the skinned parts that DO work (skins file), the inv_bind composition `inv_bind_poses[i] * skin_transform` is mathematically correct. However, if any body part has unusual NiSkinData (non-identity skin_transform, non-standard bone names), the fallback to skeleton rest pose (`skeleton.get_bone_global_rest(bone_idx).affine_inverse()`) would be more robust.

The `character_assembly_test.gd` already has a `BindMode.SKELETON_REST` mode that uses this fallback. If `SKELETON_REST` mode shows all parts correctly but `COMPOSED` doesn't, the NIF inv_bind data has conversion issues.

---

## Fix Plan

### Phase 1: Core Body Part Attachment Fix

**Goal:** All body parts render at correct positions on the skeleton.

#### 1A. Pass slot to bone lookup (morrowind_npc_assembler.gd)

Modify `_attach_static_mesh()` to accept the slot and use `SLOT_TO_BONE` for bone lookup:

```gdscript
static func _attach_static_mesh(skeleton, mesh_data, slot) -> void:
    # PRIMARY: Use slot-to-bone mapping (authoritative)
    var bone_name := BodyPartSlots.get_bone(slot)
    var bone_idx := skeleton.find_bone(bone_name)

    # FALLBACK: Try NIF parent bone name (case-insensitive)
    if bone_idx < 0 and not mesh_data.parent_bone_name.is_empty():
        bone_idx = _find_bone_ci(skeleton, mesh_data.parent_bone_name)

    # Attach via BoneAttachment3D
    if bone_idx >= 0:
        var attachment := BoneAttachment3D.new()
        attachment.bone_name = skeleton.get_bone_name(bone_idx)
        skeleton.add_child(attachment)
        attachment.add_child(instance)
    else:
        # Absolute fallback: root-level with node_transform
        instance.transform = mesh_data.node_transform
        skeleton.add_child(instance)
```

Also pass slot to `_attach_skinned_mesh_native()` for better logging/debugging.

#### 1B. Left-side mirroring (morrowind_npc_assembler.gd)

Add mirroring support for left-side body parts:

```gdscript
static func _attach_static_mesh(skeleton, mesh_data, slot) -> void:
    # ... (create mesh instance as before) ...

    if BodyPartSlots.is_left_side(slot):
        # Mirror on X axis (Morrowind convention matches OpenMW)
        instance.scale.x = -1.0
        # If material exists, disable backface culling to compensate
        # (or set cull_mode = CULL_FRONT instead of CULL_BACK)
```

#### 1C. Populate left-side slots (morrowind_npc_assembler.gd)

In `_collect_body_parts()`, after collecting right-side parts, duplicate them for left slots:

```gdscript
# After collecting all right-side body parts:
for right_slot in parts.keys():
    if not BodyPartSlots.is_left_side(right_slot):
        var left_slot := BodyPartSlots.get_left_equivalent(right_slot)
        if left_slot != right_slot and left_slot not in parts:
            parts[left_slot] = parts[right_slot]  # Same mesh, will be mirrored
```

Note: `get_left_equivalent()` doesn't exist yet — we need a reverse of `get_right_equivalent()`.

### Phase 2: Fix Test Visualization

#### 2A. Show non-skinned parts in character_assembly_test.gd

Remove the `if not extracted.is_skinned: continue` gate. For non-skinned parts, use BoneAttachment3D with the slot-to-bone mapping:

```gdscript
for mesh_data in meshes:
    if extracted.is_skinned:
        # ... existing skin-based attachment ...
    else:
        # Attach as static mesh on the correct bone
        var bone_name: String = SLOT_TO_BONE_MAP.get(slot_name, "")
        var bone_idx := _find_bone_ci(skeleton, bone_name)
        if bone_idx >= 0:
            var attachment := BoneAttachment3D.new()
            attachment.bone_name = skeleton.get_bone_name(bone_idx)
            skeleton.add_child(attachment)
            attachment.add_child(instance)
```

### Phase 3: Robustness

#### 3A. Fallback inv_bind mode

If `COMPOSED` mode produces wrong results for some parts, add a per-part fallback:

```gdscript
# In _create_native_skin():
# If more than N% of bones are unmapped, fall back to skeleton rest
if float(unmapped.size()) / mesh_data.bone_names.size() > 0.3:
    # Too many unmapped bones — use skeleton rest poses instead
    for i in mesh_data.bone_names.size():
        var bone_idx := _find_bone_ci(skeleton, mesh_data.bone_names[i])
        if bone_idx < 0: bone_idx = 0
        skin.add_bind(bone_idx, skeleton.get_bone_global_rest(bone_idx).affine_inverse())
    return skin
```

#### 3B. Debug visualization

Add a debug mode that color-codes body parts by attachment method:
- **Green** = skinned (Skin resource)
- **Blue** = bone-attached (BoneAttachment3D)
- **Red** = fallback (root-level, likely broken)
- **Yellow** = mirrored left-side

---

## Architecture: Morrowind as Adapter

The body part assembly system should be **generic**, with Morrowind as one adapter module. Here's how the layers should work:

### Generic Layer (engine-agnostic)

```
src/core/animation/
├── body_part_assembler.gd          ← Generic interface
│   class BodyPartAssembler:
│       func assemble(skeleton, parts: Array[BodyPartData]) -> void
│       func attach_skinned(skeleton, mesh, skin, slot) -> void
│       func attach_static(skeleton, mesh, bone_name, mirror) -> void
│
├── skeleton_profile_adapter.gd     ← Already exists (Phase 1A)
│   Maps any skeleton to SkeletonProfileHumanoid
│
├── retarget_setup.gd              ← Already exists (Phase 3A)
│   Handles bone renaming and animation remapping
│
└── ik_controller.gd               ← Already exists
    TwoBoneIK3D, FABRIK, etc.
```

### Morrowind Adapter Layer

```
src/core/character/morrowind/
├── morrowind_npc_assembler.gd      ← Morrowind-specific NPC assembly
│   - Knows Morrowind body part types (27 slots)
│   - Knows xbase_anim.nif skeleton variants
│   - Maps ESM BodyPart records → generic BodyPartData
│   - Handles Morrowind-specific mirroring convention
│   - Handles NIF skin data extraction
│
├── morrowind_body_part_slots.gd    ← Morrowind slot definitions
│   - Slot enum matching ESM::PartReferenceType
│   - SLOT_TO_BONE mapping (Bip01 names)
│   - Left/right mirroring info
│
└── morrowind_body_parts.gd         ← (future) ESM body part queries
    - Race → body part list resolution
    - Equipment overlay priority system
```

### Target Skeleton: SkeletonProfileHumanoid

After assembly, bones are renamed to **SkeletonProfileHumanoid** names (Godot 4.6 standard). This enables:

- **IK** via `ik_controller.gd` (TwoBoneIK3D uses profile bone names)
- **FABRIK** for multi-bone chains (future Phase 5)
- **Blend masks** via `animation_blend_mask.gd` (uses profile bone names)
- **RetargetModifier3D** for cross-skeleton animation sharing
- **Mixamo animation import** (Mixamo skeletons also map to SkeletonProfileHumanoid)

The pipeline:
```
1. Morrowind skeleton (Bip01 names) + body parts assembled
2. Bones renamed to SkeletonProfileHumanoid names (RetargetSetup)
3. Animation tracks remapped from Bip01 → profile names
4. IK, blend masks, retargeting all use profile names
```

### Future: Non-Morrowind Characters

For Mixamo/custom characters:
```
1. Load skeleton from FBX/GLB (already has standard-ish bone names)
2. SPA auto-detects skeleton type, creates BoneMap
3. Meshes already skinned correctly — just add to scene
4. Same IK, blend masks, animation system works
```

The generic `BodyPartAssembler` would have a simpler path for modern characters where the mesh is already a single skinned unit (no body part segmentation).

---

## Key Source Files

### Our Code

| File | Role | Issues |
|------|------|--------|
| `src/core/character/morrowind/morrowind_npc_assembler.gd` | NPC body part assembly | `_attach_static_mesh` uses wrong bone lookup; no left-side mirroring |
| `src/core/character/morrowind/morrowind_body_part_slots.gd` | Slot → bone mapping | Has correct `SLOT_TO_BONE` mapping, but it's not used during attachment |
| `src/core/character/mixamo/mesh_extractor.gd` | NIF mesh extraction | `parent_bone_name` derived from NIF hierarchy, not from slot |
| `src/core/nif/nif_skeleton_builder.gd` | Skeleton building | `build_skeleton_from_hierarchy()` only collects Bip01-prefixed nodes |
| `src/core/animation/character_factory_v2.gd` | Character creation orchestrator | Calls assembler, handles bone rename + animation remap |
| `src/tools/character_assembly_test.gd` | Visual test scene | Skips non-skinned parts (line 330) |
| `src/core/coordinate_system.gd` | MW↔Godot coordinate conversion | Correct; `G(A*B) = G(A)*G(B)` holds |

### OpenMW Reference (in `inspos/openmw/`)

| File | What to Learn |
|------|---------------|
| `apps/openmw/mwrender/npcanimation.cpp:236-250` | Part-to-bone mapping (`sPartList`) |
| `apps/openmw/mwrender/npcanimation.cpp:554-675` | `updateParts()` — full assembly flow |
| `apps/openmw/mwrender/npcanimation.cpp:677-685` | `insertBoundedPart()` — attachment entry point |
| `apps/openmw/mwrender/actoranimation.cpp:89-105` | `attach()` — finds bone node, calls SceneUtil |
| `components/sceneutil/attach.cpp:114-200` | **THE KEY FILE** — two-path logic (skinned vs static) |
| `components/sceneutil/riggeometry.cpp:102-138` | `initFromParentSkeleton()` — how skinned meshes find the skeleton |
| `components/sceneutil/riggeometry.cpp:140-235` | Per-frame skinning math |
| `components/nif/data.hpp:205-275` | NiSkinInstance / NiSkinData / BSSkinInstance structures |
| `components/nifosg/nifloader.cpp:1601-1630` | NIF→RigGeometry conversion for skinned meshes |
| `apps/openmw/mwrender/actorutil.cpp:8-30` | `getActorSkeleton()` — skeleton file selection |

---

## Root Cause Analysis — Static Part Transform (2026-02-09)

### Confirmed Symptom

All non-skinned body parts **cluster at the skeleton root** (origin). They are visible but positioned at (0,0,0) instead of at their corresponding bones.

### Root Cause

The transform formula in `_attach_static_mesh()` is **wrong**:

```gdscript
# BROKEN — undoes the BoneAttachment3D positioning:
instance.transform = skeleton.get_bone_global_rest(bone_idx).affine_inverse() * mesh_data.node_transform
```

**Why it fails:** Body part NIF vertices are in **bone-local space** (near origin, authored relative to the attachment bone). The NIF hierarchy transforms (`node_transform`) are approximately identity. When we apply `bone_global_rest_inv`, we cancel out the BoneAttachment3D's bone positioning:

1. BoneAttachment3D applies `bone_global_rest` → positions mesh at bone
2. `bone_global_rest_inv` undoes that → moves mesh back to origin
3. `node_transform ≈ IDENTITY` → no additional positioning
4. Result: all parts appear at skeleton root

### OpenMW Reference — How It Actually Works

From `inspos/openmw/components/sceneutil/attach.cpp:144-198` (PATH B, non-skinned):

```
1. Clone the body part NIF (preserving internal scene graph transforms)
2. Search for "BoneOffset" NiNode → extract TRANSLATION ONLY, remove node
3. If left-side → apply scale(-1, 1, 1) + invert face culling
4. Attach cloned NIF as child of the bone node
```

**No inverse-rest compensation.** The NIF scene graph is attached directly under the bone. The NIF's internal transforms (Scene Root → geometry) provide bone-relative positioning.

Full transform chain in OpenMW:
```
v_world = skeleton * bone_pose * [BoneOffset_translation] * NIF_scene_root * geometry_local * v
```

### The Fix

```gdscript
# CORRECT — bone-relative, matching OpenMW:
instance.transform = mesh_data.node_transform

# Apply BoneOffset if present (translation only, per OpenMW)
if mesh_data.has_bone_offset:
    instance.transform = Transform3D(Basis.IDENTITY, mesh_data.bone_offset_position) * instance.transform
```

### BoneOffset Node

Some body part NIFs contain a `NiNode` named "BoneOffset" that provides a **translation offset** relative to the bone attachment point. OpenMW extracts only the translation (not rotation/scale) and removes the node from the scene graph. Our `MeshExtractor` needs to detect this node and pass the offset separately.

If BoneOffset is a **sibling** of the geometry in the NIF (not an ancestor), its transform is NOT included in `node_transform` and would be lost. If it's an **ancestor**, it IS included but OpenMW removes it — the net effect is the same since only translation is extracted.

---

## Progress Tracker

| Step | Status | Description |
|------|--------|-------------|
| **P0 DONE** | ✅ | `SLOT_TO_BONE` lookup for non-skinned parts |
| **P0 DONE** | ✅ | Slot passed through to `_attach_static_mesh()` |
| **P1 DONE** | ✅ | Left-side mirroring (X=-1 scale + cull flip) |
| **P1 DONE** | ✅ | Left-side slot population from right-side data |
| **P2 DONE** | ✅ | Non-skinned parts shown in test scene |
| **Diagnostics** | ✅ | Static attachment mode toggle (BONE_REST_INV/DIRECT/IDENTITY) — keys 4/5/6 |
| **Diagnostics** | ✅ | Vertex AABB + full transform logging in debug dump (D key) |
| **Diagnostics** | ✅ | BoneOffset detection in MeshExtractor (`_find_bone_offset()`) |
| **Fix** | ✅ | Remove `bone_global_rest_inv` from transform formula — use `node_transform` directly |
| **Fix** | ✅ | Add BoneOffset support (translation only, per OpenMW) |
| **Fix** | ✅ | Apply fix to production `morrowind_npc_assembler.gd` |
| **Verify** | ⬜ | Run `character_assembly_test.tscn` — all parts at correct bones |
| **Verify** | ⬜ | Run `world_explorer.tscn` — NPCs look correct in-world |
