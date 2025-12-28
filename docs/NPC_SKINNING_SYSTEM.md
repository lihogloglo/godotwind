# NPC Skinning System - Technical Documentation

## Overview

Morrowind NPCs are assembled from multiple separate body part NIF files attached to a shared skeleton from `base_anim.nif`. This document covers the skinning pipeline and the solution for Godot compatibility.

## Architecture

### File Structure
- **base_anim.nif** / **base_anim_female.nif**: Skeleton hierarchy (NiNode tree)
- **b_n_<race>_<gender>_<part>.nif**: Body part meshes (hands, chest, head, etc.)
  - Example: `b_n_imperial_m_skins.nif` contains hands mesh + chest/torso mesh
  - Some parts are skinned (NiTriShape with NiSkinInstance)
  - Some parts are static (attached to bones via BoneAttachment3D)

### Key Data Structures

#### NiSkinInstance
- Links a skinned mesh to its bones
- `bone_indices`: Array of NiNode record indices for each bone
- `data_index`: Points to NiSkinData

#### NiSkinData
- `skin_transform`: Overall transform for the skin
- `bones`: Array of per-bone data containing:
  - `transform`: The **inverse bind matrix** (NIF space)
  - `bounding_sphere_offset/radius`: Culling data
  - `vertex_weights`: Per-vertex bone weights

#### Inverse Bind Matrix
The inverse bind matrix transforms a vertex from **model space** to **bone space**. It represents:
```
inv_bind = inverse(bone_world_transform_at_bind_time)
```

To get the bind pose (where the bone was when the mesh was authored):
```
bind_pose = inverse(inv_bind)
```

## Skinning Formulas

### OpenMW (CPU Skinning)
```cpp
// From components/sceneutil/riggeometry.cpp
osg::Matrixf boneMat = boneInfo->mInvBindMatrix * (*bone)->mMatrixInSkeletonSpace;
vertex = boneMat * vertex;
```

### Godot (GPU Skinning)
```
vertex' = boneWorld * inverse(boneRest) * vertex
```

Where:
- `boneWorld`: Current animated world transform of bone
- `boneRest`: The skeleton's rest pose for that bone
- `vertex`: Original vertex position in model space

## The Problem

### Mismatch Between Skeleton Rest Poses and Mesh Expectations

1. **Skeleton from base_anim.nif**: Rest poses come from NiNode hierarchy transforms
   - Example: Hand bone at ~1.5m from origin (full arm length)

2. **Body part meshes**: Inverse bind matrices expect bones at different positions
   - Example: Hand mesh expects hand bone at ~2cm from origin (local to hand)

3. **Result**: Godot's `inverse(boneRest)` doesn't match what the mesh expects, causing vertices to end up in wrong positions and orientations.

### The Matrix Order Problem

The key insight is that OpenMW and Godot use different matrix multiplication orders:
- **OpenMW**: `vertex' = invBind * boneWorld * vertex`
- **Godot**: `vertex' = boneWorld * inverse(boneRest) * vertex`

Matrix multiplication is NOT commutative! So `A * B ≠ B * A` in general.

However, if we ensure `boneRest = bindPose` (i.e., `inverse(boneRest) = invBind`), then at bind pose where `boneWorld = bindPose`, both formulas reduce to identity and work correctly.

## Solution: SkeletonPoseFixer

### Approach
Extract inverse bind matrices from body part NIFs and use them to set correct skeleton rest poses. This ensures `inverse(boneRest) = invBind` for all bones.

### Implementation ([skeleton_pose_fixer.gd](../src/core/character/skeleton_pose_fixer.gd))

1. Parse body part NIF
2. Find ALL skinned meshes (NiTriShape/NiTriStrips with skin_index >= 0)
3. For each skinned mesh, extract inverse bind matrices from NiSkinData
4. Convert from NIF coordinates to Godot coordinates
5. Compute bind pose: `bind_pose = inv_bind.affine_inverse()`
6. **CRITICAL**: Use the BIND POSE of the parent (not skeleton rest pose) when computing local rest
7. Set skeleton rest poses: `skeleton.set_bone_rest(bone_idx, local_rest)`

### Critical Fix #1 (Dec 2024) - Parent Pose Consistency

The original implementation incorrectly mixed skeleton rest poses with bind poses when computing local transforms. The fix ensures we use bind poses consistently throughout the hierarchy:

```gdscript
# Get parent's global pose - prefer bind pose if available
if parent_name in global_bind_poses:
    # Parent has bind pose - use it for consistency
    parent_global = global_bind_poses[parent_name]
elif parent_idx in final_global_poses:
    # Parent was updated - use its new global pose
    parent_global = final_global_poses[parent_idx]
else:
    # Parent not updated - use skeleton's current global rest
    parent_global = skeleton.get_bone_global_rest(parent_idx)

# Compute local rest: local = inv(parent_global) * global
var local_rest := parent_global.affine_inverse() * global_bind
```

### Critical Fix #2 (Dec 2024) - Bip01 Root Bone Inference

**Problem**: The root bone `Bip01` is NOT weighted to any vertices in body part meshes (it's just a pivot point). Therefore, `Bip01` never appears in the inverse bind matrix data, but all its children do. This created an inconsistent skeleton:
- `Bip01` stayed at original rest pose (`Y ≈ 1.09m` - standing)
- `Bip01 Pelvis` was updated to bind pose (`Y ≈ -0.32m` - origin-centered)
- **Result**: ~1.4m mismatch between parent and children

**Solution**: Added `_infer_missing_parent_bones()` function that detects when `Bip01 Pelvis` has a bind pose but `Bip01` doesn't, and computes `Bip01`'s bind pose from the parent-child relationship:

```gdscript
func _infer_missing_parent_bones(skeleton: Skeleton3D, global_bind_poses: Dictionary) -> void:
    if "bip01 pelvis" in global_bind_poses and "bip01" not in global_bind_poses:
        var pelvis_bind: Transform3D = global_bind_poses["bip01 pelvis"]
        var bip01_idx := skeleton.find_bone("Bip01")
        var pelvis_idx := skeleton.find_bone("Bip01 Pelvis")

        if bip01_idx >= 0 and pelvis_idx >= 0:
            # Get original relationship and apply to new pelvis position
            var orig_bip01 := skeleton.get_bone_global_rest(bip01_idx)
            var orig_pelvis := skeleton.get_bone_global_rest(pelvis_idx)
            var offset := orig_bip01.affine_inverse() * orig_pelvis
            var bip01_bind := pelvis_bind * offset.affine_inverse()
            global_bind_poses["bip01"] = bip01_bind
```

**Note**: In Morrowind, `Bip01` and `Bip01 Pelvis` are co-located (same position), so after the fix both are at `Y ≈ -0.32m`.

### Verification Results (Dec 2024)

After applying the fix, the skinning formula test shows:

```
=== bip01 head ===
  Position diff: 0.0000
  bind_pose euler: (0.0, -0.0, 90.0)
  skel_rest euler: (0.0, -0.0, 90.0)   <- NOW MATCHES!

  At bind pose (boneWorld = bindPose):
    OpenMW (invBind * boneWorld * v): (-0.0, -0.0, 0.1)
    Godot (boneWorld * inv(rest) * v): (-0.0, 0.0, 0.1)
    Difference: 0.000000   <- IDENTICAL!
```

All bones now show 0.000000 difference between OpenMW and Godot formulas.

## Coordinate System Conversion

### NIF (Morrowind) Space
- X = Right
- Y = Forward (North)
- Z = Up
- Scale: 70 units = 1 meter

### Godot Space
- X = Right
- Y = Up
- Z = Back (negative forward)
- Scale: 1 unit = 1 meter

### Conversion ([coordinate_system.gd](../src/core/coordinate_system.gd))
```gdscript
static func transform_to_godot(nif_t: Transform3D) -> Transform3D:
    # Swap Y/Z, negate new Z, scale position
    var pos = Vector3(nif_t.origin.x, nif_t.origin.z, -nif_t.origin.y) / 70.0
    var basis = basis_to_godot(nif_t.basis)
    return Transform3D(basis, pos)
```

## Current Status (Dec 2024)

### What Works
- Mathematical verification passes: OpenMW and Godot formulas produce identical results
- SkeletonPoseFixer correctly extracts bind poses from skins.nif
- Bones are being updated with correct rest poses

### What's Still Broken - Visual Rendering

**Symptom**: Despite mathematical verification passing (skeleton rest poses match bind matrices), visual NPC rendering still shows issues:
- Thighs horizontal (pointing sideways instead of down)
- Head tilted sideways
- Arms appear flipped
- One side has inverted faces (mirroring issue)

**Mathematical State After Fixes**:
```
test_full_npc.gd output:
Bone                 | Skeleton Rest Y | Bind Pose Y     | Match?
bip01                | -0.3168         | -0.3168         | YES
bip01 pelvis         | -0.3168         | -0.3168         | YES
bip01 spine          | -0.2081         | -0.2081         | YES
...
Matching bones: 11 / 11
PASS: All skeleton rest poses match bind poses!
```

**Conclusion**: The skeleton pose data is mathematically correct, but visual rendering still fails. The issue is NOT in SkeletonPoseFixer. The problem lies elsewhere in the pipeline.

### Root Cause Analysis (In Progress)

#### Finding 1: Not All Body Parts Are Skinned
Debug output shows warnings:
```
WARNING: SkeletonPoseFixer: No skinned mesh found in: meshes\b\b_n_dark elf_m_upper arm.nif
WARNING: SkeletonPoseFixer: No skinned mesh found in: meshes\b\b_n_dark elf_m_upper leg.nif
```

**Implication**: Upper arm and upper leg NIF files are **static meshes**, not skinned meshes. They are attached to bones via BoneAttachment3D, not GPU skinning.

#### Finding 2: skins.nif Contains All Bone Data
The `skins.nif` file (chest/torso mesh) contains NiSkinData with inverse bind matrices for 28 bones including:
- Spine, neck, head
- Clavicle, upper arm, forearm, hand, fingers
- Pelvis, thigh (but NOT calf, ankle, foot, toe)

The thigh bones ARE being updated from skins.nif:
```
SkeletonPoseFixer: Updated bone 27 'bip01 l thigh' local_rest.origin=(-0.108747, 0.094562, -0.000182) euler=(0.000164, -1.775221, 180.0)
SkeletonPoseFixer: Updated bone 30 'bip01 r thigh' local_rest.origin=(-0.108747, -0.094562, -0.000183) euler=(0.000164, -1.775221, 180.0)
```

#### Finding 3: The 180-Degree Rotation Mystery
The thigh bones have euler Z rotation of 180 degrees both BEFORE and AFTER the fix:
- **BEFORE**: `euler=(-9.649468, -12.44251, -175.3394)` (close to 180)
- **AFTER**: `euler=(0.000164, -1.775221, 180.0)` (exactly 180)

This 180-degree Z rotation means the thighs are rotated 180 degrees around their local axis, which could explain the horizontal appearance.

### Hypotheses for Visual Issue

1. **The bind pose data in skins.nif may not accurately represent leg poses**
   - skins.nif is a torso mesh that has skin weights for thighs but the thigh vertices might not actually deform much
   - The inverse bind matrices might be reference data, not actual binding for leg deformation

2. **Static body parts (upper_leg.nif) ignore skeleton rest poses entirely**
   - They attach via BoneAttachment3D which follows bone animated position
   - But the mesh itself has its own transform relative to the bone
   - The problem might be in how static meshes are positioned on attachment

3. **Coordinate system conversion issue specific to certain rotations**
   - The 180-degree Z rotation after conversion might indicate something wrong in how certain orientations are converted

4. **The skeleton hierarchy vs flat bone list mismatch**
   - base_anim.nif builds skeleton from NiNode hierarchy
   - skins.nif has a flat list of bones with inverse bind matrices
   - Parent-child relationships might not be consistent

## Known Issues / TODO

### Issue 1: Left/Right Mirroring Problem
One side has inverted faces. The left vs right bones have different orientations:
- Left bones have one Y direction
- Right bones have opposite Y direction

This might be:
1. Incorrect handling of mirrored geometry in `body_part_assembler.gd`
2. Node-level scale.x = -1 not working correctly for skinned meshes
3. Need to also flip normals when mirroring

**See**: `_apply_node_level_mirror()` in body_part_assembler.gd

### Issue 2: Static vs Skinned Body Parts
- **Skinned parts** (skins.nif, hand.nif): Use GPU skinning, need correct skeleton rest poses
- **Static parts** (upper_leg.nif, upper_arm.nif): Use BoneAttachment3D
- The pose fixer only affects skinned parts
- Static parts might need different handling

### Issue 3: Missing Bone Data
- 28/33 bones have inverse bind matrices from skins.nif
- Missing 5 bones: calf, ankle, foot, toe (lower leg bones)
- These bones ARE in skeleton but NOT in skins.nif
- Lower leg/foot parts may be static attachments

## Debug Tools

### Verbose Debug in body_part_assembler.gd
The `_try_fix_skeleton_poses` function now prints:
- All race parts being processed
- Skeleton bone states BEFORE and AFTER fix
- Which parts are processed and how many bones updated

### test_skinning_formula.gd (deleted)
Verified that OpenMW and Godot skinning formulas produce identical results.

### test_skinning_diagnostic.gd
Compares skeleton rest poses before/after fix:
- Shows position differences
- Verifies 0.0000m diff after fix

### test_rotation_diagnostic.gd
Analyzes bone rotations in bind poses:
- Compares left vs right bones
- Shows euler angles for debugging

### Asset Viewer
- Load NPCs to visualize assembly
- Debug output shows bone updates
- Check mesh attachments

## Next Steps for Investigation

### Priority 1: Verify Mesh Vertex Data
The skeleton is correct, so the issue may be in how mesh vertices are loaded/converted:
1. Check if vertex positions in ArrayMesh match expected positions in NIF space
2. Verify normal directions are correct (not inverted)
3. Check if triangle winding order is correct (affects face culling)

### Priority 2: Check Bone Weight Application
1. Verify bone indices in ARRAY_BONES are correctly remapped to skeleton
2. Check if ARRAY_WEIGHTS values are properly normalized
3. Test if GPU skinning is actually being applied (vs static mesh)

### Priority 3: Investigate Static Body Parts
1. Check what transforms upper_leg.nif and upper_arm.nif have internally
2. Compare to OpenMW: see how OpenMW attaches non-skinned body parts
3. BoneAttachment3D might need different transform handling

### Priority 4: Test Isolated Components
1. Render just skins.nif (skinned torso) alone to see if that part is correct
2. Render one arm/leg without mirroring
3. Check if the issue is in rest pose or in animated pose

### Priority 5: OpenMW Comparison
Key OpenMW files to study:
- `components/sceneutil/riggeometry.cpp`: CPU skinning implementation
- `components/nifosg/nifloader.cpp`: NIF loading and skeleton building
- `apps/openmw/mwrender/npcanimation.cpp`: NPC assembly logic

## File References

- [body_part_assembler.gd](../src/core/character/body_part_assembler.gd): Main assembly logic
- [skeleton_pose_fixer.gd](../src/core/character/skeleton_pose_fixer.gd): Rest pose correction
- [nif_skeleton_builder.gd](../src/core/nif/nif_skeleton_builder.gd): Builds Skeleton3D from NIF
- [nif_converter.gd](../src/core/nif/nif_converter.gd): Converts NIF meshes to Godot
- [coordinate_system.gd](../src/core/coordinate_system.gd): NIF<->Godot coordinate conversion

## OpenMW Reference

Key files in OpenMW source:
- `components/sceneutil/riggeometry.cpp`: CPU skinning implementation
- `components/nifosg/nifloader.cpp`: NIF loading and skeleton building
- `components/sceneutil/skeleton.cpp`: Skeleton management
