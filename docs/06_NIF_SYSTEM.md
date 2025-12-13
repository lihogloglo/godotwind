# NIF Model Conversion System

## Overview

The NIF (NetImmerse File) conversion system transforms Morrowind's proprietary 3D models into Godot-compatible Node3D scenes with geometry, materials, skeletons, animations, and physics collision. It supports the full NIF feature set including skinned meshes, keyframe animations, and complex node hierarchies.

---

## Status Audit

### ✅ Completed
- Binary NIF file parsing
- Triangle mesh conversion
- UV mapping
- Material creation (PBR conversion)
- Texture loading (albedo + normal maps)
- Skeleton construction (bones + hierarchy)
- Skin weights (vertex → bone mapping)
- Collision shape generation (multiple modes)
- YAML-based collision shape library
- Pattern matching for auto-shapes
- Coordinate conversion (Z-up → Y-up)
- Rotation conversion (ZYX → YZX Euler)
- Node hierarchy preservation
- KF animation file loading
- Keyframe animation conversion
- AnimationLibrary integration
- Controller data parsing (transforms, visibility, UVs)

### ⚠️ In Progress
- Animation blending (Godot supports it but not wired up)
- Particle systems (NiParticleSystem nodes exist but not converted)
- Billboard nodes (NiBillboardNode not converted)

### ❌ Not Started
- Morph targets (facial expressions)
- Havok physics simulation (Morrowind uses Havok, Godot uses Bullet/Jolt)
- Texture animations (animated water, fire)
- LOD nodes (NiLODNode not implemented)
- Multi-material meshes (currently one material per mesh)

---

## Architecture

### Conversion Pipeline

```
NIF Binary File (.nif)
         │
         ▼
   NIFReader (binary parser)
         │
         ├─ Parse header (version, endianness)
         ├─ Parse blocks (nodes, meshes, materials, etc.)
         └─ Build block tree (parent/child relationships)
         │
         ▼
   NIFConverter (main conversion)
         │
         ├─ Node Hierarchy
         │  ├─ NiNode → Node3D
         │  ├─ NiBone → Skeleton3D bone
         │  └─ Preserve transforms
         │
         ├─ Geometry
         │  ├─ NiTriShape → MeshInstance3D
         │  ├─ Vertices → ArrayMesh
         │  ├─ UVs → ARRAY_TEX_UV
         │  └─ Normals → ARRAY_NORMAL
         │
         ├─ Skinning (NIFSkeletonBuilder)
         │  ├─ NiSkinInstance → Skeleton3D
         │  ├─ Bone weights → ARRAY_BONES
         │  └─ Bind poses
         │
         ├─ Materials
         │  ├─ NiMaterialProperty → StandardMaterial3D
         │  ├─ NiTexturingProperty → Textures
         │  └─ PBR conversion
         │
         ├─ Collision (NIFCollisionBuilder)
         │  ├─ Trimesh (for architecture)
         │  ├─ Convex hulls (for furniture)
         │  ├─ Primitives (for items)
         │  └─ YAML library lookup
         │
         └─ Animations (NIFAnimationConverter)
            ├─ NIF embedded keyframes
            ├─ External KF files
            ├─ Transform tracks
            └─ Visibility tracks
         │
         ▼
   Godot Scene (Node3D tree)
   ├─ MeshInstance3D (geometry + material)
   ├─ Skeleton3D (bones)
   ├─ AnimationPlayer (keyframes)
   └─ CollisionShape3D (physics)
```

---

## Key Files

| File | Path | Purpose |
|------|------|---------|
| **NIFConverter** | [src/core/nif/nif_converter.gd](../src/core/nif/nif_converter.gd) | Main conversion entry point |
| **NIFReader** | [src/core/nif/nif_reader.gd](../src/core/nif/nif_reader.gd) | Binary NIF parser |
| **NIFSkeletonBuilder** | [src/core/nif/nif_skeleton_builder.gd](../src/core/nif/nif_skeleton_builder.gd) | Skeleton + skinning |
| **NIFAnimationConverter** | [src/core/nif/nif_animation_converter.gd](../src/core/nif/nif_animation_converter.gd) | Keyframe animations |
| **NIFCollisionBuilder** | [src/core/nif/nif_collision_builder.gd](../src/core/nif/nif_collision_builder.gd) | Collision shapes |
| **CollisionShapeLibrary** | [src/core/nif/collision_shape_library.gd](../src/core/nif/collision_shape_library.gd) | YAML shape patterns |
| **NIFKFLoader** | [src/core/nif/nif_kf_loader.gd](../src/core/nif/nif_kf_loader.gd) | External KF animations |
| **collision-shapes.yaml** | [collision-shapes.yaml](../collision-shapes.yaml) | Shape pattern database |

---

## NIF File Format

### Structure

NIF files are **binary containers** with a block-based structure:

```
NIF File
├─ Header
│  ├─ Version string ("NetImmerse File Format, Version 4.0.0.2")
│  ├─ Endianness
│  ├─ User version
│  └─ Block count
│
└─ Blocks (nodes)
   ├─ Block 0: NiNode (root)
   │  ├─ Name
   │  ├─ Transform (position, rotation, scale)
   │  ├─ Children (indices to other blocks)
   │  └─ Properties
   │
   ├─ Block 1: NiTriShape (mesh)
   │  ├─ Vertices (float[3])
   │  ├─ Normals (float[3])
   │  ├─ UVs (float[2])
   │  ├─ Triangles (int[3])
   │  └─ Data block index
   │
   ├─ Block 2: NiMaterialProperty
   │  ├─ Ambient color
   │  ├─ Diffuse color
   │  ├─ Specular color
   │  ├─ Emissive color
   │  ├─ Glossiness
   │  └─ Alpha
   │
   ├─ Block 3: NiTexturingProperty
   │  ├─ Base texture
   │  ├─ Dark texture
   │  ├─ Detail texture
   │  ├─ Gloss texture
   │  ├─ Glow texture
   │  └─ Bump map
   │
   ├─ Block 4: NiSourceTexture
   │  ├─ Filename
   │  ├─ Pixel data (optional)
   │  └─ External file flag
   │
   ├─ Block 5: NiSkinInstance (skinning)
   │  ├─ Skeleton root
   │  ├─ Bone list
   │  └─ Skin data block
   │
   └─ ...
```

---

## NIFConverter

### Core API

```gdscript
class_name NIFConverter

enum CollisionMode {
    NONE,           # No collision
    TRIMESH,        # Exact mesh (for architecture)
    CONVEX,         # Convex hull (for furniture)
    AUTO_PRIMITIVE, # Auto-detect box/sphere/capsule
    PRIMITIVES      # Use YAML library
}

func convert(nif_data: PackedByteArray, file_path: String, collision_mode: CollisionMode = CollisionMode.AUTO_PRIMITIVE) -> Node3D:
    var reader := NIFReader.new()
    var nif_file := reader.parse(nif_data)

    if not nif_file:
        return _create_placeholder()

    var root := Node3D.new()
    root.name = file_path.get_file().get_basename()

    # Convert node hierarchy
    _convert_node(nif_file.root_node, root, nif_file)

    # Build skeleton if skinned
    if _has_skinning(nif_file):
        _build_skeleton(root, nif_file)

    # Add collision
    if collision_mode != CollisionMode.NONE:
        _build_collision(root, nif_file, collision_mode, file_path)

    # Load animations
    _load_animations(root, nif_file, file_path)

    return root
```

---

## Geometry Conversion

### Mesh Creation

```gdscript
func _convert_mesh(nif_shape: NiTriShape) -> MeshInstance3D:
    var mesh_instance := MeshInstance3D.new()
    var array_mesh := ArrayMesh.new()

    # Build mesh arrays
    var arrays := []
    arrays.resize(Mesh.ARRAY_MAX)

    # Vertices
    var vertices := PackedVector3Array()
    for v in nif_shape.vertices:
        vertices.append(_convert_position(v))  # Z-up → Y-up
    arrays[Mesh.ARRAY_VERTEX] = vertices

    # Normals
    if nif_shape.normals.size() > 0:
        var normals := PackedVector3Array()
        for n in nif_shape.normals:
            normals.append(_convert_normal(n))  # Z-up → Y-up
        arrays[Mesh.ARRAY_NORMAL] = normals

    # UVs
    if nif_shape.uvs.size() > 0:
        var uvs := PackedVector2Array()
        for uv in nif_shape.uvs:
            uvs.append(Vector2(uv.x, 1.0 - uv.y))  # Flip V
        arrays[Mesh.ARRAY_TEX_UV] = uvs

    # Triangles (indices)
    var indices := PackedInt32Array()
    for tri in nif_shape.triangles:
        # Reverse winding order (NIF uses clockwise, Godot uses counter-clockwise)
        indices.append(tri.z)
        indices.append(tri.y)
        indices.append(tri.x)
    arrays[Mesh.ARRAY_INDEX] = indices

    # Add surface
    array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

    # Material
    var material := _convert_material(nif_shape)
    array_mesh.surface_set_material(0, material)

    mesh_instance.mesh = array_mesh
    return mesh_instance
```

### Coordinate Conversion

```gdscript
# NIF: Z-up, Y-forward, X-right
# Godot: Y-up, -Z-forward, X-right

func _convert_position(nif_pos: Vector3) -> Vector3:
    return Vector3(
        nif_pos.x,
        nif_pos.z,   # Z → Y
        -nif_pos.y   # Y → -Z
    ) / CoordinateSystem.UNITS_PER_METER  # Scale to meters

func _convert_normal(nif_normal: Vector3) -> Vector3:
    return Vector3(
        nif_normal.x,
        nif_normal.z,
        -nif_normal.y
    ).normalized()

func _convert_rotation(nif_rot: Basis) -> Basis:
    # Convert rotation matrix axes
    var x_axis := _convert_normal(nif_rot.x)
    var y_axis := _convert_normal(nif_rot.y)
    var z_axis := _convert_normal(nif_rot.z)
    return Basis(x_axis, y_axis, z_axis)
```

---

## Material Conversion

### PBR Translation

Morrowind uses **legacy fixed-function materials**, Godot uses **PBR**:

```gdscript
func _convert_material(nif_shape: NiTriShape) -> StandardMaterial3D:
    var mat := StandardMaterial3D.new()

    # Get material properties
    var mat_prop: NiMaterialProperty = nif_shape.material_property
    if mat_prop:
        # Legacy → PBR approximation
        mat.albedo_color = mat_prop.diffuse_color
        mat.emission = mat_prop.emissive_color
        mat.emission_enabled = mat_prop.emissive_color.v > 0.1
        mat.metallic = 0.0  # Morrowind has no metallic
        mat.roughness = 1.0 - (mat_prop.glossiness / 100.0)
        mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if mat_prop.alpha < 1.0 else BaseMaterial3D.TRANSPARENCY_DISABLED

    # Get textures
    var tex_prop: NiTexturingProperty = nif_shape.texturing_property
    if tex_prop:
        # Albedo (base texture)
        if tex_prop.base_texture:
            var albedo := _load_texture(tex_prop.base_texture.filename)
            mat.albedo_texture = albedo

        # Normal map (bump map)
        if tex_prop.bump_map:
            var normal := _load_texture(tex_prop.bump_map.filename)
            mat.normal_texture = normal
            mat.normal_enabled = true

        # Glow map → Emission
        if tex_prop.glow_texture:
            var glow := _load_texture(tex_prop.glow_texture.filename)
            mat.emission_texture = glow
            mat.emission_enabled = true

    # Texture filtering
    mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

    # Deduplication via MaterialLibrary
    return MaterialLibrary.get_or_create_material(mat.albedo_texture, mat.normal_texture)
```

---

## Skeleton & Skinning

### NIFSkeletonBuilder

```gdscript
class_name NIFSkeletonBuilder

func build_skeleton(root: Node3D, nif_file: NIFFile) -> Skeleton3D:
    var skeleton := Skeleton3D.new()
    skeleton.name = "Skeleton"

    # Find all bones
    var bones := _find_bones(nif_file)

    # Add bones to skeleton
    for bone in bones:
        var bone_idx := skeleton.get_bone_count()
        skeleton.add_bone(bone.name)

        # Set parent
        if bone.parent:
            var parent_idx := skeleton.find_bone(bone.parent.name)
            skeleton.set_bone_parent(bone_idx, parent_idx)

        # Set rest pose
        var rest := Transform3D()
        rest.origin = _convert_position(bone.position)
        rest.basis = _convert_rotation(bone.rotation)
        skeleton.set_bone_rest(bone_idx, rest)

    root.add_child(skeleton)
    return skeleton

func apply_skin_weights(mesh_instance: MeshInstance3D, nif_skin: NiSkinInstance, skeleton: Skeleton3D) -> void:
    var mesh := mesh_instance.mesh as ArrayMesh
    var arrays := mesh.surface_get_arrays(0)

    # Build bone/weight arrays
    var bone_indices := PackedInt32Array()
    var bone_weights := PackedFloat32Array()

    for vertex_idx in range(arrays[Mesh.ARRAY_VERTEX].size()):
        var bones := [0, 0, 0, 0]
        var weights := [0.0, 0.0, 0.0, 0.0]

        # Find influencing bones for this vertex
        var influence_count := 0
        for bone_idx in range(nif_skin.bones.size()):
            var bone_data := nif_skin.bones[bone_idx]
            if vertex_idx in bone_data.vertex_weights:
                var weight := bone_data.vertex_weights[vertex_idx]
                if influence_count < 4:
                    bones[influence_count] = bone_idx
                    weights[influence_count] = weight
                    influence_count += 1

        # Normalize weights
        var total_weight := weights[0] + weights[1] + weights[2] + weights[3]
        if total_weight > 0:
            weights[0] /= total_weight
            weights[1] /= total_weight
            weights[2] /= total_weight
            weights[3] /= total_weight

        bone_indices.append_array(bones)
        bone_weights.append_array(weights)

    # Update mesh
    arrays[Mesh.ARRAY_BONES] = bone_indices
    arrays[Mesh.ARRAY_WEIGHTS] = bone_weights

    var new_mesh := ArrayMesh.new()
    new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    new_mesh.surface_set_material(0, mesh.surface_get_material(0))
    mesh_instance.mesh = new_mesh
    mesh_instance.skeleton = skeleton.get_path()
```

---

## Collision Shapes

### Collision Modes

```gdscript
enum CollisionMode {
    NONE,           # No collision (visual only)
    TRIMESH,        # Exact mesh (slow, for static architecture)
    CONVEX,         # Convex hull (fast, for furniture)
    AUTO_PRIMITIVE, # Auto-detect box/sphere/capsule/cylinder
    PRIMITIVES      # Use YAML pattern library
}
```

### Auto-Primitive Detection

```gdscript
func _detect_primitive_shape(mesh: ArrayMesh) -> Shape3D:
    var aabb := _calculate_aabb(mesh)
    var size := aabb.size
    var aspect_ratio := Vector3(
        size.x / size.y,
        size.y / size.z,
        size.x / size.z
    )

    # Sphere (all axes similar)
    if abs(aspect_ratio.x - 1.0) < 0.2 and abs(aspect_ratio.y - 1.0) < 0.2:
        var radius := (size.x + size.y + size.z) / 6.0
        var sphere := SphereShape3D.new()
        sphere.radius = radius
        return sphere

    # Capsule (two axes similar, one longer)
    if abs(aspect_ratio.x - 1.0) < 0.2 and aspect_ratio.y > 1.5:
        var capsule := CapsuleShape3D.new()
        capsule.radius = (size.x + size.z) / 4.0
        capsule.height = size.y
        return capsule

    # Cylinder (two axes similar)
    if abs(aspect_ratio.x - 1.0) < 0.2:
        var cylinder := CylinderShape3D.new()
        cylinder.radius = (size.x + size.z) / 4.0
        cylinder.height = size.y
        return cylinder

    # Box (fallback)
    var box := BoxShape3D.new()
    box.size = size
    return box
```

### YAML Pattern Library

```yaml
# collision-shapes.yaml

# Patterns (glob-style matching)
patterns:
  # Architecture (Trimesh)
  - pattern: "ex_*"
    shape: trimesh
  - pattern: "in_*"
    shape: trimesh
  - pattern: "*_wall_*"
    shape: trimesh

  # Furniture (Convex or Box)
  - pattern: "furn_*_table_*"
    shape: box
  - pattern: "furn_*_chair_*"
    shape: box
  - pattern: "furn_*_bed_*"
    shape: box

  # Bottles (Cylinder)
  - pattern: "misc_*_bottle_*"
    shape: cylinder
    size: [0.05, 0.15]  # radius, height

  # Barrels (Cylinder)
  - pattern: "contain_barrel_*"
    shape: cylinder
    size: [0.3, 0.6]

  # Crates (Box)
  - pattern: "contain_crate_*"
    shape: box
    size: [0.6, 0.6, 0.6]

  # Potions (Capsule)
  - pattern: "misc_*_potion_*"
    shape: capsule
    size: [0.03, 0.1]  # radius, height

  # Actors (Capsule)
  - pattern: "*_npc_*"
    shape: capsule
    size: [0.3, 1.8]  # Human-sized
```

### Pattern Matching

```gdscript
class_name CollisionShapeLibrary

var _patterns: Array[Dictionary] = []

func load_from_yaml(path: String) -> void:
    var file := FileAccess.open(path, FileAccess.READ)
    var yaml_text := file.get_as_text()
    var data := _parse_yaml(yaml_text)

    for pattern_data in data["patterns"]:
        _patterns.append(pattern_data)

func get_shape_for_model(model_path: String) -> Shape3D:
    var model_name := model_path.get_file().get_basename().to_lower()

    for pattern in _patterns:
        if _matches_pattern(model_name, pattern["pattern"]):
            return _create_shape(pattern)

    return null  # No match, fallback to auto-detect

func _matches_pattern(text: String, pattern: String) -> bool:
    # Simple glob matching (* = wildcard)
    var regex := RegEx.new()
    var regex_pattern := pattern.replace("*", ".*")
    regex.compile(regex_pattern)
    return regex.search(text) != null

func _create_shape(pattern: Dictionary) -> Shape3D:
    match pattern["shape"]:
        "box":
            var box := BoxShape3D.new()
            if pattern.has("size"):
                box.size = Vector3(pattern["size"][0], pattern["size"][1], pattern["size"][2])
            return box

        "sphere":
            var sphere := SphereShape3D.new()
            if pattern.has("size"):
                sphere.radius = pattern["size"][0]
            return sphere

        "capsule":
            var capsule := CapsuleShape3D.new()
            if pattern.has("size"):
                capsule.radius = pattern["size"][0]
                capsule.height = pattern["size"][1]
            return capsule

        "cylinder":
            var cylinder := CylinderShape3D.new()
            if pattern.has("size"):
                cylinder.radius = pattern["size"][0]
                cylinder.height = pattern["size"][1]
            return cylinder

        "trimesh":
            return null  # Special case, handled separately

        "convex":
            return null  # Special case, handled separately

    return null
```

---

## Animation System

### NIF Embedded Animations

Some NIFs have keyframe data embedded:

```gdscript
func _convert_animation(nif_node: NIFNode) -> Animation:
    var anim := Animation.new()
    anim.length = _calculate_animation_length(nif_node.controllers)

    for controller in nif_node.controllers:
        match controller.type:
            "NiTransformController":
                _add_transform_track(anim, controller, nif_node.name)
            "NiVisController":
                _add_visibility_track(anim, controller, nif_node.name)
            "NiUVController":
                _add_uv_track(anim, controller, nif_node.name)

    return anim

func _add_transform_track(anim: Animation, controller: NIFController, node_name: String) -> void:
    var track_idx := anim.add_track(Animation.TYPE_POSITION_3D)
    anim.track_set_path(track_idx, NodePath(node_name))

    for keyframe in controller.position_keys:
        var time := keyframe.time
        var position := _convert_position(keyframe.value)
        anim.position_track_insert_key(track_idx, time, position)

    # Rotation
    track_idx = anim.add_track(Animation.TYPE_ROTATION_3D)
    anim.track_set_path(track_idx, NodePath(node_name))

    for keyframe in controller.rotation_keys:
        var time := keyframe.time
        var rotation := _convert_rotation_quaternion(keyframe.value)
        anim.rotation_track_insert_key(track_idx, time, rotation)

    # Scale
    track_idx = anim.add_track(Animation.TYPE_SCALE_3D)
    anim.track_set_path(track_idx, NodePath(node_name))

    for keyframe in controller.scale_keys:
        var time := keyframe.time
        var scale := keyframe.value
        anim.scale_track_insert_key(track_idx, time, scale)
```

### External KF Files

Character animations are in separate `.kf` files:

```gdscript
class_name NIFKFLoader

func load_animation(kf_path: String) -> Animation:
    var kf_data := BSAManager.get_file(kf_path)
    if not kf_data:
        return null

    var reader := NIFReader.new()
    var kf_file := reader.parse(kf_data)

    return _convert_kf_to_animation(kf_file)

# Example:
# "xbase_anim.kf" contains:
# - Idle
# - Walk forward
# - Run
# - Jump
# - Attack 1H
# - etc.
```

---

## Best Practices

### 1. Use Collision Mode Appropriately

```gdscript
# Architecture: Trimesh (exact)
var building := nif_converter.convert(nif_data, path, NIFConverter.CollisionMode.TRIMESH)

# Furniture: Convex (fast approximation)
var chair := nif_converter.convert(nif_data, path, NIFConverter.CollisionMode.CONVEX)

# Items: Primitives (YAML library)
var bottle := nif_converter.convert(nif_data, path, NIFConverter.CollisionMode.PRIMITIVES)

# Visual only: None
var grass := nif_converter.convert(nif_data, path, NIFConverter.CollisionMode.NONE)
```

### 2. Cache Converted Models

```gdscript
var _model_cache: Dictionary = {}  # path -> Node3D

func get_model(path: String) -> Node3D:
    if _model_cache.has(path):
        return _model_cache[path].duplicate()

    var nif_data := BSAManager.get_file(path)
    var model := nif_converter.convert(nif_data, path)
    _model_cache[path] = model
    return model.duplicate()
```

### 3. Validate Conversion Results

```gdscript
func _validate_model(model: Node3D) -> bool:
    # Check for meshes
    var has_mesh := false
    for child in model.get_children():
        if child is MeshInstance3D:
            has_mesh = true
            break

    if not has_mesh:
        push_warning("Model has no meshes: %s" % model.name)

    return has_mesh
```

---

## Common Issues

### Issue: Models Appear Upside-Down
**Cause:** Coordinate conversion not applied
**Solution:** Verify `_convert_position()` and `_convert_rotation()`

### Issue: Textures Missing
**Cause:** Texture path not found in BSA
**Solution:** Check BSA is loaded, verify texture path casing

### Issue: Collision Not Working
**Cause:** Collision shapes not created or in wrong layer
**Solution:** Verify `CollisionMode`, check collision layers/masks

### Issue: Animations Don't Play
**Cause:** AnimationPlayer not connected to skeleton
**Solution:** Verify skeleton path in animation tracks

---

## Task Tracker

- [x] Binary NIF parsing
- [x] Mesh conversion (vertices, normals, UVs)
- [x] Material conversion (PBR)
- [x] Texture loading
- [x] Skeleton construction
- [x] Skin weights
- [x] Collision shapes (all modes)
- [x] YAML collision library
- [x] Pattern matching
- [x] Coordinate conversion
- [x] Animation conversion (embedded)
- [x] KF file loading
- [x] Transform tracks
- [x] Visibility tracks
- [ ] Animation blending
- [ ] Particle systems
- [ ] Billboard nodes
- [ ] Morph targets
- [ ] Texture animations
- [ ] LOD nodes
- [ ] Multi-material meshes

---

**See Also:**
- [05_ESM_SYSTEM.md](05_ESM_SYSTEM.md) - ESM records (STAT models)
- [07_ASSET_MANAGEMENT.md](07_ASSET_MANAGEMENT.md) - Texture loading, BSA archives
- [10_DEVELOPMENT_STATUS.md](10_DEVELOPMENT_STATUS.md) - Overall roadmap
