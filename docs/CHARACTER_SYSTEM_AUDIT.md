# Character System Audit: OpenMW vs Godotwind (Mixamo)

## Executive Summary

| Aspect | OpenMW | Godotwind (Mixamo) |
|--------|--------|-------------------|
| Skeleton | Uses original Morrowind Bip01 hierarchy | Uses Mixamo skeleton with bone mapping |
| Mesh Binding | Original NIF inverse bind matrices | Rebinds meshes to Mixamo skeleton |
| Animation | NIF keyframe controllers | Mixamo FBX animations |
| Skinning | RigGeometry with original bone weights | Same weights, remapped bone indices |
| Body Parts | Fetched from ESM, attached to bones | Same source, different target skeleton |
| **Symmetrical Limbs** | **Same mesh assigned to L+R slots** | **Single slot only (mesh has both sides)** |

---

## Part 1: OpenMW Character System

### 1.1 High-Level Flow

```
ESM::NPC Record
    ↓
MWClass::Npc::insertObjectRendering()
    ↓
NpcAnimation constructor
    ├─ setObjectRoot() → Load skeleton from base_anim.nif
    ├─ updateNpcBase() → Load head/hair models
    ├─ updateParts() → Apply body parts + equipment
    └─ addAnimSource() → Load animation keyframes
    ↓
Rendered Character
```

### 1.2 Body Part Fetching

**Source**: `npcanimation.cpp:1149` - `getBodyParts()`

```cpp
// Cached per (race, female, firstPerson, werewolf)
for each part_type in [Head, Hand, Wrist, Forearm, UpperArm, Foot, Ankle, Knee, UpperLeg, Groin, Tail]:
    1. Search ESMStore for ESM::BodyPart matching:
       - race
       - gender (female flag)
       - type = ESP_Skin
       - part_type
    2. Priority fallbacks:
       - Same gender + view mode (1st/3rd)
       - Opposite gender if not found
       - 1st-person male arms as fallback for female
```

**Body Part Mapping** (slot → bone name):
- `Head` → "Head"
- `RHand/LHand` → "Right Hand" / "Left Hand"
- `Cuirass` → "Chest"
- `Groin` → "Groin"
- `RWrist/LWrist` → "Right Wrist" / "Left Wrist"
- etc.

### 1.3 Skeleton Creation

**Key File**: `sceneutil/skeleton.cpp`

1. **Load base skeleton NIF** (xbase_anim.nif for males, xbase_anim_female.nif)
2. **NIF→OSG conversion** (nifosg/nifloader.cpp):
   - Each NiNode becomes `osg::MatrixTransform`
   - Hierarchy preserved exactly as in NIF
3. **Skeleton wrapper** created if mesh uses skinning:
   - Detects `nif.getUseSkinning()` flag
   - Wraps scene in `SceneUtil::Skeleton`
4. **Bone cache** built on first access:
   - Maps lowercase bone names → transform paths
   - Thread-safe with frame tracking

**Morrowind Skeleton Bones** (Bip01 naming):
```
Bip01 (root)
├─ Bip01 Pelvis
│  └─ Bip01 Spine → Spine1 → Spine2 → Neck → Head
├─ Bip01 L Thigh → L Calf → L Foot → L Toe0
├─ Bip01 R Thigh → R Calf → R Foot → R Toe0
├─ Bip01 L Clavicle → L UpperArm → L Forearm → L Hand → fingers
└─ Bip01 R Clavicle → R UpperArm → R Forearm → R Hand → fingers
```

### 1.4 Skinning System

**Key File**: `sceneutil/riggeometry.cpp`

**Data Extraction** from NIF:
```cpp
NiSkinInstance → NiSkinData {
    bones[i] {
        mTransform: Transform (inverse bind matrix)
        mWeights: [(vertex_idx, weight), ...]
    }
}
```

**RigGeometry Setup**:
```cpp
RigGeometry rig;
rig.setSourceGeometry(original_mesh);

// For each bone in NiSkinData:
BoneInfo {
    mName = bone_name
    mInvBindMatrix = inverse_bind_pose
}
influences[bone_idx] = vertex_weights

rig.setInfluences(influences);
```

**GPU Skinning Formula**:
```
vertex' = Σ (bone_global_pose[i] × inv_bind[i] × vertex) × weight[i]
```

### 1.5 Animation System

**Key Files**: `animation.hpp`, `nifosg/controller.cpp`

1. **AnimSource**: Container for one animation file
   - Loads KeyframeControllers from NIF
   - TextKeyMap for event markers ("start", "hit", "loop")

2. **KeyframeController**: Bone animation driver
   - Interpolates position, rotation, scale
   - Supports linear/bezier/TCB interpolation

3. **Animation Blending**:
   - Multiple AnimStates can play simultaneously
   - BlendMask determines which bones each affects
   - Priority system for animation layering

---

## Part 2: Godotwind (Mixamo) Character System

### 2.1 High-Level Flow

```
ESM NPC Record
    ↓
MixamoCharacterFactory.create_npc()
    ├─ _get_skeleton() → Create Mixamo skeleton template
    ├─ _get_body_parts_for_npc() → Fetch from ESMManager
    ├─ _attach_body_part() → Extract mesh, rebind, attach
    └─ _load_mixamo_animations() → Load FBX animations
    ↓
CharacterBody3D with Mixamo skeleton
```

### 2.2 Body Part Fetching

**Source**: `mixamo/character_factory.gd:141`

```gdscript
func _get_body_parts_for_npc(npc_record, race_record, is_female) -> Array[BodyPartInfo]:
    var parts_by_type: Dictionary = {}

    # 1. Get race body parts (skip HEAD/HAIR)
    var race_parts = ESMManager.get_body_parts_for_race(race_id, is_female)
    for part in race_parts:
        if part.part_type not in [HEAD, HAIR]:
            parts_by_type[part.part_type] = BodyPartInfo.new(part.model, part.part_type)

    # 2. Override with NPC-specific head
    if npc_record.head_id:
        var head = ESMManager.get_body_part(npc_record.head_id)
        parts_by_type[HEAD] = BodyPartInfo.new(head.model, HEAD)

    # 3. Override with NPC-specific hair
    if npc_record.hair_id:
        var hair = ESMManager.get_body_part(npc_record.hair_id)
        parts_by_type[HAIR] = BodyPartInfo.new(hair.model, HAIR)

    return parts_by_type.values()
```

**Part Type → Mixamo Bone Mapping**:
```gdscript
const PART_TYPE_TO_BONE := {
    0: "mixamorig1_Head",        # HEAD
    1: "mixamorig1_Head",        # HAIR
    2: "mixamorig1_Neck",        # NECK
    3: "mixamorig1_Spine2",      # CHEST
    4: "mixamorig1_Hips",        # GROIN
    5: "mixamorig1_LeftHand",    # HAND
    # ... etc
}
```

### 2.3 Skeleton Creation

**Source**: `mixamo/mixamo_skeleton_template.gd`

Godotwind creates a **pre-defined Mixamo skeleton template** (not from NIF):

```gdscript
const BONE_DEFS := [
    # [name, parent, local_position, rotation]
    ["mixamorig1_Hips", "", Vector3(0, 1.0, 0)],
    ["mixamorig1_Spine", "mixamorig1_Hips", Vector3(0, 0.1, 0)],
    ["mixamorig1_Spine1", "mixamorig1_Spine", Vector3(0, 0.12, 0)],
    # ... full Mixamo hierarchy
]

static func create_full() -> Skeleton3D:
    var skeleton := Skeleton3D.new()
    for def in BONE_DEFS + FINGER_DEFS:
        var idx := skeleton.add_bone(def[0])
        skeleton.set_bone_parent(idx, parent_idx)
        skeleton.set_bone_rest(idx, Transform3D(Basis(), def[2]))
    return skeleton
```

**Skeleton Types**:
- `FULL`: 65 bones including all fingers
- `SIMPLIFIED`: 25 core bones (no fingers, for LOD)
- `BEAST`: Full + tail bones for Argonians/Khajiit

### 2.4 Mesh Extraction & Rebinding

**Source**: `mixamo/mesh_extractor.gd` and `mixamo/skin_rebinder.gd`

#### Step 1: Extract Raw Mesh from NIF
```gdscript
# mesh_extractor.gd
class MeshData:
    var vertices: PackedVector3Array    # Converted to Godot space
    var normals: PackedVector3Array
    var uvs: PackedVector2Array
    var indices: PackedInt32Array
    var bone_names: PackedStringArray   # Original MW names
    var bone_weights: Array             # Per-vertex [4 floats]
    var bone_indices: Array             # Per-vertex [4 ints]
    var inv_bind_poses: Array           # Original MW matrices

# Coordinate conversion: NIF → Godot
# NIF: X-right, Y-forward, Z-up, 70 units/meter
# Godot: X-right, Y-up, Z-back, 1 unit/meter
result[i] = Vector3(v.x/70, v.z/70, -v.y/70)
```

#### Step 2: Build Bone Mapping
```gdscript
# bone_mapper.gd
const MORROWIND_TO_MIXAMO := {
    "bip01": "mixamorig1_Hips",
    "bip01 spine": "mixamorig1_Spine",
    "bip01 l upperarm": "mixamorig1_LeftArm",
    "bip01 l forearm": "mixamorig1_LeftForeArm",
    # ... 50+ mappings
}

static func to_mixamo(morrowind_name: String) -> String:
    return MORROWIND_TO_MIXAMO.get(morrowind_name.to_lower(), "")
```

#### Step 3: Rebind Skin to Mixamo
```gdscript
# skin_rebinder.gd
static func rebind(mesh_data, mixamo_skeleton) -> RebindResult:
    # 1. Build bone index mapping
    var bone_map := {}  # mw_idx → mixamo_idx
    for i in mesh_data.bone_names.size():
        var mixamo_name := BoneMapper.to_mixamo(mesh_data.bone_names[i])
        var mixamo_idx := mixamo_skeleton.find_bone(mixamo_name)
        bone_map[i] = mixamo_idx

    # 2. Remap bone indices in mesh
    for i in mesh_data.vertices.size():
        for j in 4:
            new_bone_indices[i][j] = bone_map[old_bone_indices[i][j]]

    # 3. Create Skin resource with ORIGINAL inv_bind matrices
    var skin := Skin.new()
    for i in mesh_data.bone_names.size():
        var mixamo_idx = bone_map[i]
        skin.add_bind(mixamo_idx, mesh_data.inv_bind_poses[i])

    return RebindResult.ok(mesh, skin)
```

**Critical Insight**: The original Morrowind inverse bind matrices are **reused directly**. This works because:
- MW inv_bind transforms vertices to bone-local space
- When Mixamo skeleton is at rest, GPU computes: `vertex' = Mixamo_rest × MW_inv_bind × vertex`
- Vertices end up at Mixamo bone positions + local offset

### 2.5 Animation System

**Source**: `mixamo/mixamo_animation_loader.gd`

```gdscript
static func get_animation_library() -> AnimationLibrary:
    var library := AnimationLibrary.new()

    # Load FBX animations from assets/animations/
    for file in glob("res://assets/animations/*.fbx"):
        var anim := load_fbx_animation(file)
        library.add_animation(anim.name, anim)

    return library

# Loaded into AnimationPlayer
var anim_player := AnimationPlayer.new()
anim_player.add_animation_library("mixamo", library)
skeleton.add_child(anim_player)
```

**Animation System Components**:
- `AnimationPlayer`: Plays animations on skeleton
- `AnimationTree`: State machine for transitions (idle ↔ walk ↔ run)
- `IKController`: Foot placement, head look-at

---

## Part 3: System Comparison

### 3.1 Skeleton Architecture

| Feature | OpenMW | Godotwind |
|---------|--------|-----------|
| Origin | From NIF (xbase_anim.nif) | Hardcoded template |
| Naming | Bip01 convention | mixamorig1_ convention |
| Hierarchy | Morrowind's original | Standard Mixamo |
| Bone Count | ~50 bones | 25-65 (LOD variants) |
| Coordinate System | NIF (Y-forward, Z-up) | Godot (Y-up, Z-back) |

**Trade-offs**:
- OpenMW: Perfect compatibility with original animations
- Godotwind: Access to huge Mixamo animation library

### 3.2 Body Part Pipeline

| Step | OpenMW | Godotwind |
|------|--------|-----------|
| Source | ESM::BodyPart records | Same |
| Model | NIF → OSG scene | NIF → MeshData → ArrayMesh |
| Attachment | OSG bone attachment | BoneAttachment3D or Skin |
| Skinned meshes | RigGeometry | MeshInstance3D + Skin |
| Non-skinned | Matrix transform | BoneAttachment3D |
| **Symmetrical limbs** | **Duplicates to L+R slots** | **Single slot only** |

**Differences**:
- OpenMW preserves NIF scene graph structure
- Godotwind extracts only mesh data, discards hierarchy

### 3.2.1 Symmetrical Limb Handling (Critical Difference)

**OpenMW** uses a **multimap** to assign the same body part mesh to BOTH left and right slots:

```cpp
// npcanimation.cpp:1169 - sBodyPartMap is a MULTIMAP
static const BodyPartMapType sBodyPartMap = {
    { ESM::BodyPart::MP_Hand, ESM::PRT_RHand },
    { ESM::BodyPart::MP_Hand, ESM::PRT_LHand },  // SAME part → 2 slots
    { ESM::BodyPart::MP_Forearm, ESM::PRT_RForearm },
    { ESM::BodyPart::MP_Forearm, ESM::PRT_LForearm },
    // ... etc for all symmetrical limbs
};

// Loop iterates and assigns SAME mesh to BOTH slots:
while (bIt != sBodyPartMap.end() && bIt->first == bodypart.mData.mPart)
{
    parts[bIt->second] = &bodypart;  // Assigns to BOTH R and L
    ++bIt;
}
```

**Godotwind** only assigns to ONE slot (the right side):

```gdscript
# morrowind_body_part_slots.gd:116 - Returns only ONE slot
static func part_type_to_slots(part_type: int) -> Array[int]:
    match part_type:
        5:  # HAND
            return [Slot.HAND_R]      # Only right, NOT both
        7:  # FOREARM
            return [Slot.FOREARM_R]   # Only right, NOT both
        # ... etc
```

**Why this works for skinned meshes**: Morrowind body part NIFs contain geometry skinned to BOTH left and right bones (e.g., vertices weighted to both "Bip01 L Hand" and "Bip01 R Hand"). The mesh is added once, and GPU skinning deforms it to both sides.

**Potential issue**: If any code tries to look up `Slot.HAND_L` or `Slot.FOREARM_L`, it won't find anything in Godotwind's `parts` dictionary. This could break:
- Equipment overlay systems that need per-slot tracking
- Visibility toggling for individual limbs
- Any logic that iterates over all slots expecting both L and R to be populated

### 3.3 Skinning Approach

| Aspect | OpenMW | Godotwind |
|--------|--------|-----------|
| Bone indices | Original NIF indices | Remapped to Mixamo |
| Weights | Original | Original (unchanged) |
| Inv bind matrices | Original | Original (reused) |
| Deformation | RigGeometry (CPU/GPU) | Godot Skin (GPU) |

**Key Difference**: Godotwind remaps bone indices but keeps weights and inverse bind matrices identical. This is mathematically valid because:

```
OpenMW:  vertex' = MW_bone_pose × MW_inv_bind × vertex
Godotwind: vertex' = Mixamo_pose × MW_inv_bind × vertex
```

When Mixamo is in T-pose (same as Morrowind rest pose), the result is the same. Animations work because both skeletons have matching bone orientations after mapping.

### 3.4 Animation Pipeline

| Feature | OpenMW | Godotwind |
|---------|--------|-----------|
| Source format | NIF keyframes | FBX/GLB animations |
| Controller | KeyframeController | AnimationPlayer |
| Blending | Custom BlendMask | AnimationTree |
| Events | TextKeyMap | Animation markers |
| IK | None built-in | Godot IK system |

**Animation Compatibility**:
- OpenMW: Uses original Morrowind animations perfectly
- Godotwind: Morrowind animations would need retargeting; uses Mixamo instead

### 3.5 Strengths & Weaknesses

#### OpenMW Approach
**Strengths**:
- 100% faithful to original game
- All original animations work unchanged
- Equipment/mod compatibility
- Proven, battle-tested

**Weaknesses**:
- Locked to Morrowind animation format
- Limited modern animation features
- Custom bone hierarchy

#### Godotwind (Mixamo) Approach
**Strengths**:
- Access to 2500+ Mixamo animations
- Modern Godot animation tools (AnimationTree, IK)
- Easier to create new animations
- Standard skeleton for tools compatibility

**Weaknesses**:
- Bone mapping not 100% perfect (edge cases)
- Original Morrowind animations require conversion
- Slight vertex position differences possible
- Additional complexity in rebinding step

---

## Part 4: Potential Issues in Godotwind

### 4.1 Bone Mapping Gaps

Some Morrowind bones have no Mixamo equivalent:
- `Bip01 Tail` (Argonian/Khajiit) → Custom `mixamorig1_Tail`
- Some finger bones may differ in count

**Impact**: Beast races and detailed hand animations need special handling.

### 4.2 Transform Differences

Morrowind skeleton is tiny (centered at origin, ~0.02 units tall).
Mixamo skeleton is human-scale (~1.8m tall).

**Solution in code** (skin_rebinder.gd:318):
```gdscript
# USE THE ORIGINAL MORROWIND INV_BIND!
# This automatically repositions vertices because:
# vertex' = Mixamo_rest × MW_inv_bind × vertex
#         = (Mixamo bone position) + (bone-local offset)
skin.add_bind(mixamo_idx, mw_inv_bind)
```

This is **correct** but relies on Mixamo bones having similar orientations to Morrowind bones in T-pose.

### 4.3 Rest Pose Orientation

If Mixamo and Morrowind bones have different rest orientations:
```
Example: UpperArm orientation
MW:     Axis points down arm (Y-forward in local space)
Mixamo: Axis points along arm (X-forward in local space)
```

This could cause mesh distortion. Current code applies no rotation correction (BoneMapper.get_transform_correction returns IDENTITY for most bones).

### 4.4 Recommendations

1. **Add bone orientation correction** for arms/legs if mesh appears twisted
2. **Validate beast race tails** with custom animations
3. **Consider hybrid approach**: Use Morrowind skeleton for accurate reproduction, with animation retargeting for Mixamo anims
4. **Add fallback**: If bone mapping fails, attach mesh statically to approximate bone

---

## Appendix: Key Files Reference

### OpenMW
- `apps/openmw/mwrender/npcanimation.cpp` - NPC character assembly
- `apps/openmw/mwrender/animation.hpp` - Base animation system
- `components/sceneutil/skeleton.cpp` - Skeleton container
- `components/sceneutil/riggeometry.cpp` - Mesh skinning
- `components/nifosg/nifloader.cpp` - NIF → OSG conversion

### Godotwind
- `src/core/character/mixamo/character_factory.gd` - Main NPC assembly
- `src/core/character/mixamo/mixamo_skeleton_template.gd` - Skeleton creation
- `src/core/character/mixamo/mesh_extractor.gd` - NIF mesh extraction
- `src/core/character/mixamo/skin_rebinder.gd` - Mesh rebinding
- `src/core/character/mixamo/bone_mapper.gd` - Bone name mapping
