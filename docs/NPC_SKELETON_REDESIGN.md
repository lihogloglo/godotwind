# NPC Skeleton System Redesign

## Implementation Status: COMPLETE & PRODUCTION READY

### New Files Created

**Core Layer (Game-Agnostic):**
- [skeleton_factory.gd](../src/core/character/skeleton_factory.gd) - Builds Skeleton3D from bone data
- [skin_builder.gd](../src/core/character/skin_builder.gd) - Creates Skin resources, remaps bones
- [mesh_attacher.gd](../src/core/character/mesh_attacher.gd) - Attaches meshes to skeletons

**Game Layer (Morrowind-Specific):**
- [morrowind_bone_translator.gd](../src/core/character/morrowind/morrowind_bone_translator.gd) - Bone name handling
- [morrowind_body_part_slots.gd](../src/core/character/morrowind/morrowind_body_part_slots.gd) - Slot definitions
- [morrowind_npc_assembler.gd](../src/core/character/morrowind/morrowind_npc_assembler.gd) - High-level assembly

### Updated Files
- [character_factory_v2.gd](../src/core/animation/character_factory_v2.gd) - Now uses MorrowindNPCAssembler internally

### Deleted Files
- `body_part_assembler.gd` - Replaced by MorrowindNPCAssembler (~1,069 lines removed)
- `skeleton_pose_fixer.gd` - No longer needed (~208 lines removed)
- `character_factory.gd` - Replaced by CharacterFactoryV2 (~400 lines removed)

### Test Script
- [test_new_npc_system.gd](../test_new_npc_system.gd) - All 6 tests pass

---

## OpenMW Architecture Summary

OpenMW's NPC system is elegantly simple:

### Core Components
1. **Skeleton** - Just a bone hierarchy with transform matrices
2. **RigGeometry** - Skinned mesh that references bones by name
3. **attach()** - Function that copies skinned geometry to a skeleton

### Key Insights

1. **Bone names are the contract** - Everything uses lowercased bone names for matching
2. **Inverse bind matrices are per-mesh** - Each body part stores its own bind poses
3. **Skinning formula is straightforward**:
   ```
   finalVertex = (invBindMatrix * boneWorldMatrix) * skinTransform * vertex
   ```
4. **Left/right mirroring** - Simply scale X by -1 and flip face culling
5. **Filter-based attachment** - Body parts use name prefixes ("hair", "head") to select which geometries to copy

### What OpenMW Does NOT Do
- Does NOT modify skeleton rest poses based on body parts
- Does NOT try to "fix" mismatched poses
- Simply uses Skin resources with proper inverse bind matrices

---

## Current Godotwind Problems

### Accumulated Complexity
Our current system has ~1,700 lines across multiple files trying to solve problems that shouldn't exist:

1. **skeleton_pose_fixer.gd** (208 lines) - Attempts to "fix" skeleton rest poses. Now disabled.
2. **BONE_MIRROR_MAP** (50+ entries) - Hardcoded in two places
3. **Metadata copying workarounds** - Fighting against Godot's duplicate() behavior
4. **Multiple skinning code paths** - Skin resource vs direct bone remapping
5. **Race matching by substring** - Fragile string parsing

### Root Cause
We tried to make the skeleton match the body parts, when we should have made the body parts work with any skeleton (via proper Skin resources).

---

## Proposed New Architecture

### Design Principles
1. **Data-driven over hardcoded** - Bone mappings in configuration, not code
2. **Skin resources are the answer** - Godot's Skin system handles inverse bind matrices correctly
3. **Separation of concerns** - Parse NIF → Build Skin → Attach to Skeleton
4. **Game-agnostic core** - Morrowind specifics in a translation layer

### Component Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Game Layer (Morrowind)                   │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │ MorrowindNPC    │  │ MorrowindRace   │  │ MorrowindBone│ │
│  │ Manager         │  │ Registry        │  │ Translator   │ │
│  └────────┬────────┘  └────────┬────────┘  └──────┬──────┘ │
└───────────┼─────────────────────┼─────────────────┼────────┘
            │                     │                 │
┌───────────▼─────────────────────▼─────────────────▼────────┐
│                    Core Engine Layer                        │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │ SkeletonFactory │  │ SkinBuilder     │  │ MeshAttacher│ │
│  │                 │  │                 │  │             │ │
│  │ - from_hierarchy│  │ - from_nif_data │  │ - skinned   │ │
│  │ - from_bone_list│  │ - remap_bones   │  │ - static    │ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## Core Engine Layer (Game-Agnostic)

### 1. SkeletonFactory (120 lines max)

Creates Skeleton3D from bone data. No game-specific logic.

```gdscript
class_name SkeletonFactory

## Build skeleton from hierarchical bone data
static func from_hierarchy(bones: Array[BoneData]) -> Skeleton3D:
    var skeleton := Skeleton3D.new()
    for bone in bones:
        var idx := skeleton.add_bone(bone.name)
        if bone.parent_name:
            skeleton.set_bone_parent(idx, skeleton.find_bone(bone.parent_name))
        skeleton.set_bone_rest(idx, bone.rest_transform)
    return skeleton

## Simple data class
class BoneData:
    var name: String
    var parent_name: String  # empty for root
    var rest_transform: Transform3D
```

### 2. SkinBuilder (150 lines max)

Creates Godot Skin resources. This is the critical piece.

```gdscript
class_name SkinBuilder

## Build Skin from bone names and inverse bind matrices
static func from_bind_data(
    bone_names: PackedStringArray,
    inv_bind_matrices: Array[Transform3D],
    skeleton: Skeleton3D,
    bone_translator: Callable = func(n): return n  # Optional name translation
) -> Skin:
    var skin := Skin.new()

    for i in bone_names.size():
        var source_name := bone_names[i]
        var target_name := bone_translator.call(source_name)
        var bone_idx := skeleton.find_bone(target_name)

        if bone_idx < 0:
            push_warning("Bone not found: %s (from %s)" % [target_name, source_name])
            continue

        skin.add_bind(bone_idx, inv_bind_matrices[i])

    return skin

## Remap mesh bone indices to match a different skeleton
static func remap_mesh_bones(
    mesh: ArrayMesh,
    source_bones: PackedStringArray,
    target_skeleton: Skeleton3D,
    bone_translator: Callable = func(n): return n
) -> ArrayMesh:
    # Create index mapping: source_idx -> target_idx
    var bone_map: PackedInt32Array
    bone_map.resize(source_bones.size())

    for i in source_bones.size():
        var target_name := bone_translator.call(source_bones[i])
        bone_map[i] = target_skeleton.find_bone(target_name)

    # Remap each surface
    var new_mesh := ArrayMesh.new()
    for surf_idx in mesh.get_surface_count():
        var arrays := mesh.surface_get_arrays(surf_idx)
        if arrays[Mesh.ARRAY_BONES]:
            arrays[Mesh.ARRAY_BONES] = _remap_bone_array(arrays[Mesh.ARRAY_BONES], bone_map)
        new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
        # Copy material
        new_mesh.surface_set_material(surf_idx, mesh.surface_get_material(surf_idx))

    return new_mesh
```

### 3. MeshAttacher (100 lines max)

Attaches meshes to skeletons. Simple and focused.

```gdscript
class_name MeshAttacher

## Attach a skinned mesh to a skeleton
static func attach_skinned(
    mesh: ArrayMesh,
    skin: Skin,
    skeleton: Skeleton3D,
    mirror_x: bool = false
) -> MeshInstance3D:
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.skin = skin
    instance.skeleton = skeleton.get_path()

    if mirror_x:
        instance.scale.x = -1.0
        # Flip face culling
        # ... material override for CULL_FRONT

    skeleton.add_child(instance)
    return instance

## Attach a static mesh to a bone
static func attach_static(
    mesh: ArrayMesh,
    skeleton: Skeleton3D,
    bone_name: String,
    offset: Transform3D = Transform3D.IDENTITY
) -> BoneAttachment3D:
    var bone_idx := skeleton.find_bone(bone_name)
    if bone_idx < 0:
        push_error("Bone not found: %s" % bone_name)
        return null

    var attachment := BoneAttachment3D.new()
    attachment.bone_name = bone_name

    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.transform = offset

    attachment.add_child(instance)
    skeleton.add_child(attachment)
    return attachment
```

---

## Game Layer (Morrowind-Specific)

### 4. MorrowindBoneTranslator (80 lines max)

Handles Morrowind's bone naming conventions.

```gdscript
class_name MorrowindBoneTranslator

## Standard bone name normalization
static func normalize(name: String) -> String:
    return name.to_lower().strip_edges()

## Mirror bone name (left <-> right)
static func mirror(name: String) -> String:
    var n := normalize(name)
    if " r " in n:
        return n.replace(" r ", " l ")
    elif " l " in n:
        return n.replace(" l ", " r ")
    # Handle suffix patterns
    if n.ends_with(" r"):
        return n.substr(0, n.length() - 2) + " l"
    elif n.ends_with(" l"):
        return n.substr(0, n.length() - 2) + " r"
    return name  # No mirroring needed

## Translate NIF bone name to skeleton bone name
static func translate(nif_name: String, _context: Dictionary = {}) -> String:
    # Morrowind uses consistent naming, just normalize case
    return normalize(nif_name)
```

### 5. MorrowindBodyPartSlots (50 lines max)

Defines the slot-to-bone mapping.

```gdscript
class_name MorrowindBodyPartSlots

enum Slot {
    HEAD, HAIR, NECK, CHEST, GROIN, SKIRT,
    HAND_R, HAND_L, WRIST_R, WRIST_L,
    FOREARM_R, FOREARM_L, UPPER_ARM_R, UPPER_ARM_L,
    FOOT_R, FOOT_L, ANKLE_R, ANKLE_L,
    KNEE_R, KNEE_L, UPPER_LEG_R, UPPER_LEG_L,
    CLAVICLE_R, CLAVICLE_L, WEAPON, SHIELD, TAIL
}

const SLOT_TO_BONE := {
    Slot.HEAD: "bip01 head",
    Slot.HAIR: "bip01 head",
    Slot.NECK: "bip01 neck",
    Slot.CHEST: "bip01 spine1",
    Slot.GROIN: "bip01 pelvis",
    Slot.HAND_R: "bip01 r hand",
    Slot.HAND_L: "bip01 l hand",
    # ... etc
}

## Get the bone name for a slot
static func get_bone(slot: Slot) -> String:
    return SLOT_TO_BONE.get(slot, "")

## Check if slot is left-side (needs mirroring)
static func is_left_side(slot: Slot) -> bool:
    return slot in [Slot.HAND_L, Slot.WRIST_L, Slot.FOREARM_L,
                    Slot.UPPER_ARM_L, Slot.FOOT_L, Slot.ANKLE_L,
                    Slot.KNEE_L, Slot.UPPER_LEG_L, Slot.CLAVICLE_L]
```

### 6. MorrowindNPCAssembler (200 lines max)

High-level NPC assembly using the core components.

```gdscript
class_name MorrowindNPCAssembler

static var _skeleton_cache: Dictionary = {}  # race_key -> Skeleton3D template

## Assemble a complete NPC
static func assemble(npc: NPCRecord, race: RaceRecord) -> Node3D:
    var root := Node3D.new()
    root.name = npc.name if npc.name else npc.id

    # Get or create skeleton
    var skeleton := _get_skeleton(race, npc.is_female())
    root.add_child(skeleton)

    # Collect body parts
    var parts := _collect_body_parts(npc, race)

    # Attach each body part
    for slot in parts:
        var part_data: BodyPartData = parts[slot]
        _attach_body_part(skeleton, slot, part_data)

    return root

static func _get_skeleton(race: RaceRecord, female: bool) -> Skeleton3D:
    var key := "%s_%s" % [race.id, "f" if female else "m"]
    if key in _skeleton_cache:
        return _skeleton_cache[key].duplicate()

    var skel_path := _get_skeleton_path(race, female)
    var skeleton := _load_skeleton(skel_path)
    _skeleton_cache[key] = skeleton
    return skeleton.duplicate()

static func _attach_body_part(skeleton: Skeleton3D, slot: int, data: BodyPartData) -> void:
    var is_left := MorrowindBodyPartSlots.is_left_side(slot)
    var translator := func(n):
        var t := MorrowindBoneTranslator.normalize(n)
        return MorrowindBoneTranslator.mirror(t) if is_left else t

    if data.is_skinned:
        # Remap bones and create skin
        var remapped := SkinBuilder.remap_mesh_bones(
            data.mesh, data.bone_names, skeleton, translator)
        var skin := SkinBuilder.from_bind_data(
            data.bone_names, data.inv_binds, skeleton, translator)
        MeshAttacher.attach_skinned(remapped, skin, skeleton, is_left)
    else:
        # Static attachment
        var bone := MorrowindBodyPartSlots.get_bone(slot)
        MeshAttacher.attach_static(data.mesh, skeleton, bone)
```

---

## Total Line Count Estimate

| Component | Lines | Purpose |
|-----------|-------|---------|
| SkeletonFactory | ~120 | Build skeletons |
| SkinBuilder | ~150 | Build Skin resources, remap bones |
| MeshAttacher | ~100 | Attach meshes to skeletons |
| MorrowindBoneTranslator | ~80 | Bone name handling |
| MorrowindBodyPartSlots | ~50 | Slot definitions |
| MorrowindNPCAssembler | ~200 | High-level assembly |
| **Total** | **~700** | vs current ~1,700 |

---

## Migration Path

### Phase 1: Create Core Layer
1. Implement `SkeletonFactory`, `SkinBuilder`, `MeshAttacher`
2. Unit test each with synthetic data

### Phase 2: Create Morrowind Layer
1. Implement `MorrowindBoneTranslator`, `MorrowindBodyPartSlots`
2. Implement `MorrowindNPCAssembler`

### Phase 3: Integration
1. Add NIF data extraction helpers (bone names, inv bind matrices)
2. Connect to existing ESM data loading
3. Test with actual game data

### Phase 4: Deprecate Old System
1. Mark old files as deprecated
2. Migrate dependent code
3. Remove old implementation

---

## Audit Conclusion: Start Fresh

**Recommendation: YES, start from scratch with the new architecture.**

### Reasons:
1. **Current code has wrong assumptions** - Trying to fix skeletons instead of using proper Skins
2. **Hardcoded mappings scattered** - BONE_MIRROR_MAP in multiple files
3. **Disabled systems** - skeleton_pose_fixer.gd is disabled but still in codebase
4. **Metadata workarounds** - Fighting against Godot instead of working with it
5. **No clear separation** - Game-specific logic mixed with core engine

### What to Keep:
1. **NIF parsing** - `nif_reader.gd` is solid
2. **ESM records** - `body_part_record.gd`, `npc_record.gd`, etc. are clean
3. **Animation loading** - `nif_kf_loader.gd` works
4. **Some bone maps** - As reference for the new MorrowindBodyPartSlots

### What to Delete:
1. `body_part_assembler.gd` - Replace with new system
2. `skeleton_pose_fixer.gd` - No longer needed
3. `character_factory.gd` / `character_factory_v2.gd` - Rebuild simpler version

### Time Investment:
The new system is ~700 lines vs ~1,700 current. More importantly, it's **correct by design** rather than patched to work.

---

## Appendix: Godot Skinning Reference

### How Godot Skin Works
```gdscript
# Skin binds: (bone_index, inverse_bind_pose)
# The inverse_bind_pose transforms from BONE SPACE to MESH SPACE at bind time
#
# At runtime, Godot computes:
#   final_vertex = bone_global_transform * inverse_bind_pose * vertex
#
# This is exactly what OpenMW does!
```

### Key Godot Methods
```gdscript
# Skeleton3D
skeleton.add_bone(name: String) -> int
skeleton.set_bone_parent(idx: int, parent_idx: int)
skeleton.set_bone_rest(idx: int, rest: Transform3D)
skeleton.find_bone(name: String) -> int

# Skin
skin.add_bind(bone_idx: int, inverse_bind_pose: Transform3D)

# MeshInstance3D
instance.mesh = mesh
instance.skin = skin
instance.skeleton = skeleton.get_path()
```

### ArrayMesh Bone Data
```gdscript
# Mesh surfaces have:
# ARRAY_BONES - PackedInt32Array, 4 indices per vertex
# ARRAY_WEIGHTS - PackedFloat32Array, 4 weights per vertex
#
# Indices reference bones in the order they were added to Skin
# OR in the order of bone_names metadata if using direct binding
```
