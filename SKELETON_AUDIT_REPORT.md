# NPC Character/Skeleton System Audit Report

## Executive Summary

After a thorough audit of the NPC character creation, skeleton building, and animation systems, I've identified **several critical bugs** that explain why body parts appear rotated/stretched. The primary issues are:

1. **CRITICAL: Matrix reading is transposed** (causes 90-degree rotation errors)
2. **CRITICAL: NIFTransform.to_transform3d() applies scale incorrectly**
3. **MODERATE: Bone name mapping uses "Bip01 X" format which matches NIF files correctly**
4. **VERIFIED CORRECT: bone_names metadata is properly set on meshes**
5. **VERIFIED CORRECT: Coordinate system conversion logic is sound**

---

## Issue #1: Matrix Reading is Transposed (CRITICAL)

### Location
`src/core/nif/nif_reader.gd`, function `_read_matrix3()` (lines 1923-1929)

### Current Code
```gdscript
func _read_matrix3() -> Basis:
    # Read 3x3 rotation matrix (row-major)
    var m := Basis()
    m.x = Vector3(_read_float(), _read_float(), _read_float())  # Row 0 -> Column x
    m.y = Vector3(_read_float(), _read_float(), _read_float())  # Row 1 -> Column y
    m.z = Vector3(_read_float(), _read_float(), _read_float())  # Row 2 -> Column z
    return m
```

### The Problem
NIF files store rotation matrices in **row-major** order:
```
[M00, M01, M02, M10, M11, M12, M20, M21, M22]
```

Godot's `Basis` stores columns in `x`, `y`, `z` properties:
- `Basis.x` = Column 0 (not Row 0!)
- `Basis.y` = Column 1
- `Basis.z` = Column 2

The current code reads rows directly into columns, which results in reading the **transposed** matrix.

### Evidence
Running a test with a 90-degree Z rotation:
- NIF stores: `[0,-1,0, 1,0,0, 0,0,1]` (rows)
- Current code produces Euler: `(0, 0, -90°)`
- Correct reading produces Euler: `(0, 0, 90°)`

### Comparison with OpenMW
OpenMW explicitly transposes when converting:
```cpp
// niftypes.hpp line 62
osgMat(i, j) = mValues[j][i]; // NB: column/row major difference
```

### Fix
```gdscript
func _read_matrix3() -> Basis:
    # Read 3x3 rotation matrix (row-major in file)
    var r0 := Vector3(_read_float(), _read_float(), _read_float())  # Row 0
    var r1 := Vector3(_read_float(), _read_float(), _read_float())  # Row 1
    var r2 := Vector3(_read_float(), _read_float(), _read_float())  # Row 2
    # Transpose: Godot Basis columns = file rows transposed
    return Basis(
        Vector3(r0.x, r1.x, r2.x),  # Column 0
        Vector3(r0.y, r1.y, r2.y),  # Column 1
        Vector3(r0.z, r1.z, r2.z)   # Column 2
    )
```

### Impact
This affects ALL rotation/orientation data:
- Bone rest poses
- Node transforms
- Collision shape orientations
- Texture effect matrices

---

## Issue #2: NIFTransform.to_transform3d() Scale Application (CRITICAL)

### Location
`src/core/nif/nif_defs.gd`, class `NIFTransform` (lines 190-196)

### Current Code
```gdscript
class NIFTransform:
    var translation: Vector3 = Vector3.ZERO
    var rotation: Basis = Basis.IDENTITY
    var scale: float = 1.0

    func to_transform3d() -> Transform3D:
        return Transform3D(rotation * scale, translation)
```

### The Problem
The expression `rotation * scale` is ambiguous in GDScript. When you multiply a `Basis` by a `float`, it's interpreted as:
- `Basis * float` = component-wise multiplication (correct for uniform scale)

But the issue is that the rotation basis may already be storing scale components (as noted in OpenMW's niftypes.hpp: "this can contain scale components too"). We're double-applying scale in some cases.

### Comparison with OpenMW
```cpp
// niftypes.hpp line 79-81
for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j)
        transform(j, i) = mRotation.mValues[i][j] * mScale; // Explicitly multiply each component
```

OpenMW:
1. Takes the rotation matrix as-is (may contain non-uniform scale)
2. Multiplies by the uniform scale factor

### Fix
Keep the current approach but ensure the matrix is correctly transposed first (from Issue #1). The scale multiplication itself is fine.

---

## Issue #3: Bone Name Mapping (VERIFIED CORRECT)

### Location
`src/core/character/body_part_assembler.gd`, `PART_SLOT_BONE_MAP` (lines 78-106)

### Current Code
```gdscript
const PART_SLOT_BONE_MAP := {
    PartSlot.PRT_Head: "Bip01 Head",
    PartSlot.PRT_Cuirass: "Bip01 Spine2",
    PartSlot.PRT_RHand: "Bip01 R Hand",
    # ...
}
```

### OpenMW's Approach
```cpp
// npcanimation.cpp line 238-250
{ ESM::PRT_Head, "Head" },
{ ESM::PRT_Cuirass, "Chest" },
{ ESM::PRT_RHand, "Right Hand" },
```

### Analysis
At first this looked like a bug, but checking the actual NIF files:
- Morrowind's `base_anim.nif` uses "Bip01 Head", "Bip01 Spine2", etc.
- OpenMW's shorter names ("Head", "Chest") work because OpenMW uses partial matching

**Godotwind's approach is actually correct** for exact bone name matching. The bone names in Morrowind NIF files ARE "Bip01 Head", "Bip01 R Hand", etc.

---

## Issue #4: Bone Names Metadata (VERIFIED CORRECT)

### Location
`src/core/nif/nif_converter.gd`, lines 971-981 and 1040-1050

### Code
```gdscript
# Store bone names for later remapping when attaching to different skeleton
if has_skin_data and skin_instance:
    var bone_names: Array[String] = []
    for bone_idx in skin_instance.bone_indices:
        var bone_node := _reader.get_record(bone_idx) as Defs.NiNode
        if bone_node and bone_node.name:
            bone_names.append(bone_node.name)
        else:
            bone_names.append("Bone_%d" % bone_idx)
    mesh_instance.set_meta("bone_names", bone_names)
```

This correctly:
1. Extracts bone names from the NiSkinInstance
2. Stores them as metadata on the MeshInstance3D
3. Preserves them when duplicating via `_duplicate_with_metadata()`

**This is implemented correctly.**

---

## Issue #5: Coordinate System Conversion (VERIFIED CORRECT)

### Location
`src/core/coordinate_system.gd`

### The Conversion
```
NIF (Morrowind):  X=East, Y=North, Z=Up
Godot:            X=East, Y=Up, Z=South(-North)

Conversion: (x, y, z) → (x, z, -y)
```

### For Rotation Matrices
The basis conversion formula `R' = C * R * C^T` is correctly implemented:
```gdscript
static func basis_to_godot(mw: Basis) -> Basis:
    return Basis(
        Vector3(mw.x.x, mw.x.z, -mw.x.y),   # Column 0
        Vector3(mw.z.x, mw.z.z, -mw.z.y),   # Column 1 (was MW Z)
        Vector3(-mw.y.x, -mw.y.z, mw.y.y)   # Column 2 (was MW -Y)
    )
```

**This is mathematically correct**, but it assumes the input Basis is already properly column-major. Since Issue #1 causes the Basis to be transposed, this conversion produces wrong results.

---

## Additional Observations

### Left/Right Body Part Mirroring (CORRECT)
The mirroring implementation matches OpenMW:
- Uses `scale.x = -1` at node level
- Inverts face culling to compensate
- Remaps bone names R→L using `BONE_MIRROR_MAP`

### Skeleton Building from Hierarchy (CORRECT)
`nif_skeleton_builder.gd` correctly:
- Builds bone hierarchy from NiNode parent-child relationships
- Uses `_convert_nif_transform()` for rest poses (which uses CoordinateSystem)

---

## Recommended Fix Order

### 1. Fix Matrix Reading (HIGHEST PRIORITY)
Edit `src/core/nif/nif_reader.gd`:

```gdscript
func _read_matrix3() -> Basis:
    # Read 3x3 rotation matrix - file is row-major, Godot Basis uses columns
    var r0 := Vector3(_read_float(), _read_float(), _read_float())
    var r1 := Vector3(_read_float(), _read_float(), _read_float())
    var r2 := Vector3(_read_float(), _read_float(), _read_float())
    # Transpose: each Basis column is formed from corresponding row components
    return Basis(
        Vector3(r0.x, r1.x, r2.x),  # Column 0 from all row[0]
        Vector3(r0.y, r1.y, r2.y),  # Column 1 from all row[1]
        Vector3(r0.z, r1.z, r2.z)   # Column 2 from all row[2]
    )
```

### 2. Clear Caches After Fix
After applying the fix, clear all cached skeleton templates and body parts:
```gdscript
BodyPartAssembler.clear_all_caches()
```

### 3. Test with a Simple Case
Run the World Explorer or Asset Viewer and load a single NPC to verify bones are oriented correctly.

---

## Files Modified in This Audit

### Test Scripts Created
- `test_matrix_analysis.gd` - Demonstrates the matrix transpose issue
- `test_real_bone_names.gd` - Examines actual NIF bone names
- `test_skeleton_orientation.gd` - Tests before/after conversion

### Files That Need Fixing
1. `src/core/nif/nif_reader.gd` - Matrix reading (line 1923-1929)

### Files Reviewed and Verified Correct
- `src/core/coordinate_system.gd`
- `src/core/nif/nif_skeleton_builder.gd`
- `src/core/nif/nif_converter.gd` (bone_names metadata)
- `src/core/character/body_part_assembler.gd`
- `src/core/nif/nif_kf_loader.gd`

---

## Summary

The root cause of body part orientation issues is **a single bug in matrix reading**. The NIF file stores rotation matrices in row-major order, but the current code reads them directly into Godot's column-major Basis structure without transposing. This causes all rotations to be incorrect.

Fixing `_read_matrix3()` in `nif_reader.gd` should resolve the body part orientation issues. The coordinate system conversion and skeleton building logic are otherwise correct.
