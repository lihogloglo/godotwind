# Next-Gen Character System Design

## Overview

A modern character system that uses Morrowind's original meshes with a Mixamo-compatible skeleton. This enables:
- Import of thousands of free Mixamo animations
- Modern Godot 4.x animation features (AnimationTree, SkeletonModifier3D, retargeting)
- IK, procedural animation, ragdoll physics
- Easy integration with motion matching systems

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Character Assembly Pipeline                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │  Morrowind   │    │   Mixamo     │    │   Modern     │      │
│  │  NIF Meshes  │───▶│   Skeleton   │───▶│  Animation   │      │
│  │  (geometry)  │    │   Template   │    │    System    │      │
│  └──────────────┘    └──────────────┘    └──────────────┘      │
│         │                   │                   │               │
│         ▼                   ▼                   ▼               │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │    Mesh      │    │    Bone      │    │  AnimTree +  │      │
│  │  Extractor   │    │   Mapper     │    │   IK + LOD   │      │
│  └──────────────┘    └──────────────┘    └──────────────┘      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## 1. Mixamo Skeleton Standard

### Bone Hierarchy
```
mixamorig:Hips                          (root)
├── mixamorig:Spine
│   ├── mixamorig:Spine1
│   │   └── mixamorig:Spine2
│   │       ├── mixamorig:Neck
│   │       │   └── mixamorig:Head
│   │       │       └── mixamorig:HeadTop_End
│   │       ├── mixamorig:LeftShoulder
│   │       │   └── mixamorig:LeftArm
│   │       │       └── mixamorig:LeftForeArm
│   │       │           └── mixamorig:LeftHand
│   │       │               └── (fingers...)
│   │       └── mixamorig:RightShoulder
│   │           └── mixamorig:RightArm
│   │               └── mixamorig:RightForeArm
│   │                   └── mixamorig:RightHand
│   │                       └── (fingers...)
├── mixamorig:LeftUpLeg
│   └── mixamorig:LeftLeg
│       └── mixamorig:LeftFoot
│           └── mixamorig:LeftToeBase
└── mixamorig:RightUpLeg
    └── mixamorig:RightLeg
        └── mixamorig:RightFoot
            └── mixamorig:RightToeBase
```

### Bone Count
- Core skeleton: 65 bones (Mixamo standard)
- With fingers: 65 bones
- Simplified (no fingers): 25 bones

## 2. Morrowind to Mixamo Bone Mapping

| Morrowind (Bip01)      | Mixamo                      | Transform Correction |
|------------------------|-----------------------------|--------------------|
| Bip01                  | mixamorig:Hips              | Rotate 180° Y      |
| Bip01 Pelvis           | (merged with Hips)          | -                  |
| Bip01 Spine            | mixamorig:Spine             | None               |
| Bip01 Spine1           | mixamorig:Spine1            | None               |
| Bip01 Spine2           | mixamorig:Spine2            | None               |
| Bip01 Neck             | mixamorig:Neck              | None               |
| Bip01 Head             | mixamorig:Head              | None               |
| Bip01 L Clavicle       | mixamorig:LeftShoulder      | None               |
| Bip01 L UpperArm       | mixamorig:LeftArm           | Rotate 90° Z       |
| Bip01 L Forearm        | mixamorig:LeftForeArm       | None               |
| Bip01 L Hand           | mixamorig:LeftHand          | None               |
| Bip01 R Clavicle       | mixamorig:RightShoulder     | None               |
| Bip01 R UpperArm       | mixamorig:RightArm          | Rotate -90° Z      |
| Bip01 R Forearm        | mixamorig:RightForeArm      | None               |
| Bip01 R Hand           | mixamorig:RightHand         | None               |
| Bip01 L Thigh          | mixamorig:LeftUpLeg         | None               |
| Bip01 L Calf           | mixamorig:LeftLeg           | None               |
| Bip01 L Foot           | mixamorig:LeftFoot          | None               |
| Bip01 L Toe0           | mixamorig:LeftToeBase       | None               |
| Bip01 R Thigh          | mixamorig:RightUpLeg        | None               |
| Bip01 R Calf           | mixamorig:RightLeg          | None               |
| Bip01 R Foot           | mixamorig:RightFoot         | None               |
| Bip01 R Toe0           | mixamorig:RightToeBase      | None               |

### Finger Mapping (optional, for detailed hand animations)
| Morrowind              | Mixamo                      |
|------------------------|-----------------------------|
| Bip01 L Finger0        | mixamorig:LeftHandThumb1    |
| Bip01 L Finger01       | mixamorig:LeftHandThumb2    |
| Bip01 L Finger02       | mixamorig:LeftHandThumb3    |
| Bip01 L Finger1        | mixamorig:LeftHandIndex1    |
| Bip01 L Finger11       | mixamorig:LeftHandIndex2    |
| Bip01 L Finger12       | mixamorig:LeftHandIndex3    |
| ... (etc for all fingers)                            |

## 3. Mesh Extraction Pipeline

### Step 1: Extract Raw Geometry from NIF
```gdscript
class MeshExtractor:
    ## Extract pure geometry from a Morrowind NIF body part
    ## Returns: { vertices, normals, uvs, indices, bone_weights }
    static func extract_from_nif(nif_path: String) -> Dictionary:
        # Load NIF
        # Extract NiTriShape/NiTriStrips data
        # Do NOT apply skeleton transforms
        # Keep vertex positions in MESH-LOCAL space
        # Extract bone names and weights
        return {
            "vertices": PackedVector3Array,
            "normals": PackedVector3Array,
            "uvs": PackedVector2Array,
            "indices": PackedInt32Array,
            "bone_names": PackedStringArray,  # Original Bip01 names
            "bone_weights": Array[PackedFloat32Array],  # Per-vertex
            "bone_indices": Array[PackedInt32Array],    # Per-vertex
            "material_path": String,  # Texture path
        }
```

### Step 2: Coordinate System Conversion
```gdscript
## Convert from NIF space to Godot space
## NIF: X-right, Y-forward, Z-up, 70 units/meter
## Godot: X-right, Y-up, Z-back, 1 unit/meter
static func convert_vertex(nif_pos: Vector3) -> Vector3:
    return Vector3(
        nif_pos.x / 70.0,
        nif_pos.z / 70.0,
        -nif_pos.y / 70.0
    )
```

### Step 3: Remap Bone Assignments
```gdscript
## Remap bone indices from Morrowind to Mixamo
static func remap_bone_weights(
    bone_names: PackedStringArray,
    bone_indices: Array[PackedInt32Array],
    bone_weights: Array[PackedFloat32Array],
    mixamo_skeleton: Skeleton3D
) -> Dictionary:
    # Build mapping: morrowind_name -> mixamo_index
    var bone_map := {}
    for i in bone_names.size():
        var mw_name := bone_names[i].to_lower()
        var mixamo_name := MORROWIND_TO_MIXAMO[mw_name]
        var mixamo_idx := mixamo_skeleton.find_bone(mixamo_name)
        bone_map[i] = mixamo_idx

    # Remap all vertex bone indices
    var new_indices: Array[PackedInt32Array] = []
    for vertex_idx in bone_indices.size():
        var new_vert_indices := PackedInt32Array()
        for bi in bone_indices[vertex_idx]:
            new_vert_indices.append(bone_map.get(bi, 0))
        new_indices.append(new_vert_indices)

    return { "indices": new_indices, "weights": bone_weights }
```

## 4. Skin Rebinding with Transform Correction

The key insight: Morrowind meshes were authored with bones at SPECIFIC positions. We need to compute the transform that maps from where Morrowind expected the bone to be → where Mixamo places it.

### Bind Pose Correction Matrix
```gdscript
## For each bone, compute the correction transform
static func compute_bind_correction(
    morrowind_bind_pose: Transform3D,  # From NiSkinData inverse bind
    mixamo_rest_pose: Transform3D       # From Mixamo skeleton
) -> Transform3D:
    # The mesh vertices are in "model space" relative to Morrowind bind
    # We need to transform them to be relative to Mixamo rest

    # correction = mixamo_rest * inverse(morrowind_bind)
    # This transforms: mw_bind_space → world → mixamo_rest_space
    return mixamo_rest_pose * morrowind_bind_pose.affine_inverse()
```

### Building the Godot Skin Resource
```gdscript
static func create_skin(
    bone_names: PackedStringArray,
    morrowind_inv_binds: Array[Transform3D],
    mixamo_skeleton: Skeleton3D
) -> Skin:
    var skin := Skin.new()

    for i in bone_names.size():
        var mw_name := bone_names[i].to_lower()
        var mixamo_name := MORROWIND_TO_MIXAMO.get(mw_name, "")
        if mixamo_name.is_empty():
            continue

        var bone_idx := mixamo_skeleton.find_bone(mixamo_name)
        if bone_idx < 0:
            continue

        # Get transforms
        var mw_inv_bind := morrowind_inv_binds[i]
        var mixamo_rest := mixamo_skeleton.get_bone_global_rest(bone_idx)

        # Compute corrected inverse bind for Godot
        # Godot's formula: vertex' = bone_world * inv(bone_rest) * vertex
        # We want: vertex' = bone_world * corrected_inv_bind * vertex
        # So: corrected_inv_bind = inv(bone_rest) * correction_matrix

        # The correction transforms MW mesh-space vertices to Mixamo rest-space
        var mw_bind := mw_inv_bind.affine_inverse()
        var correction := mixamo_rest * mw_bind.affine_inverse()
        var godot_inv_bind := mixamo_rest.affine_inverse() * correction.affine_inverse()

        # Simplifies to:
        godot_inv_bind = mw_inv_bind

        skin.add_bind(bone_idx, godot_inv_bind)

    return skin
```

## 5. Mixamo Skeleton Template

### Creating the Template
Option A: Import a Mixamo FBX and extract the skeleton
Option B: Programmatically create the skeleton with correct bone positions

```gdscript
## Create Mixamo skeleton programmatically
class MixamoSkeletonTemplate:
    # Standard Mixamo bone data (rest poses in T-pose)
    const BONE_DATA := {
        "mixamorig:Hips": {
            "parent": "",
            "position": Vector3(0, 1.0, 0),  # ~waist height
            "rotation": Quaternion.IDENTITY,
        },
        "mixamorig:Spine": {
            "parent": "mixamorig:Hips",
            "position": Vector3(0, 0.1, 0),
            "rotation": Quaternion.IDENTITY,
        },
        # ... etc for all bones
    }

    static func create() -> Skeleton3D:
        var skeleton := Skeleton3D.new()
        skeleton.name = "MixamoSkeleton"

        # Add bones in order
        for bone_name in BONE_ORDER:
            var idx := skeleton.add_bone(bone_name)
            var data: Dictionary = BONE_DATA[bone_name]

            if not data["parent"].is_empty():
                var parent_idx := skeleton.find_bone(data["parent"])
                skeleton.set_bone_parent(idx, parent_idx)

            var rest := Transform3D(
                Basis(data["rotation"]),
                data["position"]
            )
            skeleton.set_bone_rest(idx, rest)

        skeleton.reset_bone_poses()
        return skeleton
```

## 6. Character Assembly

### Complete Pipeline
```gdscript
class NextGenCharacterFactory:
    var mixamo_template: Skeleton3D
    var mesh_cache: Dictionary = {}

    func create_character(npc_record: NPCRecord, race_record: RaceRecord) -> CharacterBody3D:
        # 1. Create skeleton instance
        var skeleton := mixamo_template.duplicate()

        # 2. Get body parts for this NPC
        var body_parts := get_body_parts(npc_record, race_record)

        # 3. For each body part, extract and rebind mesh
        for part in body_parts:
            var mesh_data := MeshExtractor.extract_from_nif(part.model_path)
            var remapped := remap_to_mixamo(mesh_data, skeleton)
            var mesh_instance := create_skinned_mesh(remapped, skeleton)
            skeleton.add_child(mesh_instance)

        # 4. Create character controller
        var character := CharacterBody3D.new()
        character.add_child(skeleton)

        # 5. Setup modern animation system
        setup_animation_system(character, skeleton)

        return character

    func setup_animation_system(character: CharacterBody3D, skeleton: Skeleton3D) -> void:
        # AnimationTree with state machine
        var anim_tree := AnimationTree.new()
        var state_machine := AnimationNodeStateMachine.new()

        # Add locomotion blend space
        var locomotion := AnimationNodeBlendSpace2D.new()
        # ... configure idle, walk, run, strafe

        # Add combat layer
        var combat_layer := AnimationNodeBlendTree.new()
        # ... configure attack, block, cast

        # IK setup
        var ik_controller := IKController.new()
        ik_controller.setup(skeleton, character)

        # Procedural modifiers
        var proc_controller := ProceduralModifierController.new()
        proc_controller.setup(skeleton)

        character.add_child(anim_tree)
        character.add_child(ik_controller)
        character.add_child(proc_controller)
```

## 7. Benefits of This Approach

### Animation Compatibility
- Direct import of any Mixamo animation
- Works with motion capture data
- Compatible with Godot's animation retargeting
- Easy to share animations between NPCs

### Modern Features
- Full AnimationTree with blend spaces
- SkeletonModifier3D for procedural effects
- Physical bone simulation for hair/cloaks
- Spring bones, jiggle physics

### Performance
- GPU skinning (standard Godot)
- LOD-based animation quality
- Animation sharing across instances
- Efficient bone transforms

### Modding
- Export characters as GLTF/GLB
- Import custom Mixamo animations
- Replace skeleton with custom rigs
- Blend original + custom animations

## 8. Implementation Phases

### Phase 1: Core Infrastructure
- [ ] Create Mixamo skeleton template
- [ ] Implement bone mapping table
- [ ] Build mesh extraction (geometry only)
- [ ] Test with single body part

### Phase 2: Mesh Binding
- [ ] Implement skin rebinding
- [ ] Handle transform corrections
- [ ] Support all body part types
- [ ] Add texture loading

### Phase 3: Animation System
- [ ] AnimationTree setup
- [ ] Import sample Mixamo animations
- [ ] Create locomotion blend space
- [ ] Implement animation retargeting

### Phase 4: Advanced Features
- [ ] IK integration (foot, look-at, hands)
- [ ] Procedural animation (breathing, sway)
- [ ] Physical simulation (hair, cloth)
- [ ] Expression/morph targets

## 9. File Structure

```
src/core/character/
├── nextgen/
│   ├── mixamo_skeleton_template.gd    # Skeleton definition
│   ├── bone_mapper.gd                 # MW → Mixamo mapping
│   ├── mesh_extractor.gd              # NIF geometry extraction
│   ├── skin_rebinder.gd               # Skin resource creation
│   ├── nextgen_character_factory.gd   # Main assembly
│   └── nextgen_animation_system.gd    # Animation controller
├── animation/
│   ├── locomotion_controller.gd       # Movement animation
│   ├── combat_controller.gd           # Combat animation
│   └── expression_controller.gd       # Facial animation
└── physics/
    ├── spring_bone_controller.gd      # Secondary motion
    └── cloth_simulation.gd            # Cloth physics
```

## 10. Migration Path

1. **Parallel implementation**: Keep old system working while building new
2. **Feature flag**: `use_nextgen_characters` in settings
3. **Gradual rollout**: Start with one race, expand
4. **Fallback**: If new system fails, fall back to placeholder

---

## Next Steps

1. Create `mixamo_skeleton_template.gd` with full bone hierarchy
2. Build `bone_mapper.gd` with complete MW→Mixamo mapping
3. Refactor `mesh_extractor.gd` to extract geometry only (no skeleton)
4. Test with Imperial Male body parts