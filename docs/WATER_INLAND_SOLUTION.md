# Water Inland Rendering & Morrowind Lake Integration

## Problem Statement

Currently, the ocean shows **everywhere** including inland. This is because:
1. The ocean is an infinite plane that follows the camera
2. Shore masks only dampen waves, they don't hide the ocean
3. Morrowind ESM data doesn't include lake boundaries for exteriors

## Solution Overview

### 1. Ocean Shore Masking (DONE for ocean_compute.gdshader, ocean_gerstner.gdshader)

**What I Fixed:**
- Added `shore_mask` uniform to ocean shaders
- Modified `ALPHA` to multiply by `shore_factor` (0.0 = land, 1.0 = ocean)
- Ocean now becomes invisible on land based on terrain height vs sea level

**How It Works:**
```glsl
// In vertex shader:
shore_factor = sample_shore_mask(VERTEX.xz);  // 0.0 on land, 1.0 in ocean

// In fragment shader:
ALPHA = mix(water_clarity, 1.0, fresnel * 0.5) * shore_factor;  // Invisible on land
```

**Still TODO:**
- Add shore mask to `ocean_low.gdshader`
- Add shore mask to `ocean_flat.gdshader`

### 2. Inland Water: WaterVolume System (DONE)

**Already Implemented:**
- `WaterVolume` class for lakes, rivers, pools
- Box-based bounding volumes
- Swimming/buoyancy detection
- Independent water properties per volume

**Limitation:**
- Currently uses **BoxShape3D** - doesn't fit complex lake shapes

## Morrowind Lake Data Integration

### The Challenge

Morrowind ESM exterior cells have:
- ✅ Terrain heightmap data
- ✅ Single global `water_height` value (usually ignored, ocean plane used instead)
- ❌ **NO lake boundary data** - just one infinite water plane

### Solution: Manual Lake Definition

Since Morrowind doesn't store lake boundaries, we need to **manually define** them.

#### Option A: Polygon-Based Volumes (RECOMMENDED)

Instead of boxes, use **polygon shapes** that match lake contours:

```gdscript
# Enhanced WaterVolume with polygon support
extends WaterVolume
class_name PolygonWaterVolume

@export var polygon_points: PackedVector2Array  # Lake boundary in XZ plane
@export var water_height: float = 0.0
@export var depth: float = 10.0

func _ready():
    _create_polygon_collision()
    _create_polygon_mesh()

func _create_polygon_collision():
    # Convert 2D polygon to 3D extruded shape
    var shape = ConvexPolygonShape3D.new()
    var points_3d: PackedVector3Array = []

    # Bottom vertices
    for point in polygon_points:
        points_3d.append(Vector3(point.x, water_height - depth, point.y))

    # Top vertices (water surface)
    for point in polygon_points:
        points_3d.append(Vector3(point.x, water_height, point.y))

    shape.points = points_3d
    _collision_shape.shape = shape

func _create_polygon_mesh():
    # Create water surface mesh from polygon
    var arrays = []
    arrays.resize(Mesh.ARRAY_MAX)

    # Triangulate polygon for water surface
    var vertices = PackedVector3Array()
    var uvs = PackedVector2Array()
    var indices = PackedInt32Array()

    # Use Delaunay triangulation or simple fan triangulation
    _triangulate_polygon(polygon_points, vertices, uvs, indices)

    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_TEX_UV] = uvs
    arrays[Mesh.ARRAY_INDEX] = indices

    var mesh = ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    _water_mesh.mesh = mesh
```

#### Option B: Heightmap-Based Lake Detection

Use terrain heightmap to automatically detect lakes:

```gdscript
# Automatic lake detection from terrain
class_name LakeDetector

func detect_lakes_from_terrain(terrain: Terrain3D, sea_level: float) -> Array[PolygonWaterVolume]:
    var lakes: Array[PolygonWaterVolume] = []

    # Sample terrain heightmap
    var heightmap = terrain.data.get_height_map()
    var resolution = terrain.data.get_resolution()

    # Find contiguous regions below sea level
    var lake_regions = _flood_fill_below_sea_level(heightmap, sea_level)

    # For each region, trace boundary polygon
    for region in lake_regions:
        var polygon = _trace_boundary(region)
        var lake = PolygonWaterVolume.new()
        lake.polygon_points = polygon
        lake.water_height = sea_level
        lakes.append(lake)

    return lakes
```

#### Option C: Manual JSON Lake Database

Create a JSON file with Morrowind lake definitions:

```json
// data/morrowind_lakes.json
{
  "vvardenfell_lakes": [
    {
      "name": "Lake Amaya",
      "region": "Ascadian Isles",
      "water_height": -1000.0,
      "polygon": [
        [12500, 8200],
        [12800, 8150],
        [13000, 8300],
        [12900, 8500],
        [12600, 8450]
      ],
      "depth": 15.0,
      "water_type": "lake",
      "clarity": 0.3,
      "color": [0.02, 0.12, 0.18]
    },
    {
      "name": "Odai River",
      "region": "Ascadian Isles",
      "water_height": -1000.0,
      "polygon": [ /* river path points */ ],
      "depth": 8.0,
      "water_type": "river",
      "flow_direction": [1.0, 0.5],
      "flow_speed": 2.0
    }
  ]
}
```

Load and instantiate:

```gdscript
func load_morrowind_lakes(json_path: String) -> void:
    var file = FileAccess.open(json_path, FileAccess.READ)
    var json = JSON.parse_string(file.get_as_text())

    for lake_data in json["vvardenfell_lakes"]:
        var lake = PolygonWaterVolume.new()
        lake.name = lake_data["name"]
        lake.polygon_points = _array_to_vector2_array(lake_data["polygon"])
        lake.water_surface_height = lake_data["water_height"]
        lake.size.y = lake_data["depth"]

        match lake_data["water_type"]:
            "lake": lake.water_type = WaterVolume.WaterType.LAKE
            "river": lake.water_type = WaterVolume.WaterType.RIVER

        if "flow_direction" in lake_data:
            lake.flow_direction = Vector2(lake_data["flow_direction"][0], lake_data["flow_direction"][1])
            lake.flow_speed = lake_data["flow_speed"]

        world.add_child(lake)
```

## Transitions Between Water Types

### Ocean ↔ Lake Transition

**Problem:** Sharp boundary between ocean and lake at coastlines

**Solution:** Blend zones

```gdscript
# In lake water shader, detect proximity to ocean
uniform float blend_distance = 50.0;  // Blend over 50m

void fragment() {
    float dist_to_ocean = get_distance_to_ocean_edge(VERTEX.xz);
    float ocean_blend = smoothstep(0.0, blend_distance, dist_to_ocean);

    // Blend lake properties with ocean properties
    vec4 lake_color = mix(refracted_color, lake_water_color.rgb, ...);
    vec4 ocean_color = mix(refracted_color, ocean_water_color.rgb, ...);
    ALBEDO = mix(ocean_color, lake_color, ocean_blend);
}
```

### Lake ↔ River Transition

**Solution:** Rivers connect to lakes naturally via flow

```gdscript
# River WaterVolume extends into lake
var river = WaterVolume.new()
river.water_type = WaterType.RIVER
river.flow_direction = Vector2(1, 0)  # Flows into lake

# Where river meets lake, water_type transitions automatically
# based on which volume the player is in
```

### River ↔ Ocean Transition

**Solution:** River deltas

```gdscript
# River mouth expands as it approaches ocean
# Water gradually loses directional flow
func update_river_flow_near_ocean():
    var dist_to_ocean = get_distance_to_ocean()
    var flow_reduction = smoothstep(0.0, 100.0, dist_to_ocean)
    current_strength = base_current_strength * flow_reduction
```

## Recommended Approach for Morrowind

### Phase 1: Ocean Shore Masking (IN PROGRESS)
1. ✅ Add shore mask to all ocean shaders
2. ✅ Make ocean invisible on land via ALPHA
3. Generate shore masks from Terrain3D heightmap

### Phase 2: Major Lake Database
1. **Manually map major lakes** from Morrowind game
   - Lake Amaya (Ascadian Isles)
   - Odai River system
   - Foyada Mamaea (lava river)
   - Any significant water bodies
2. Store in JSON with polygon boundaries
3. Create tool to visualize and edit polygons in editor

### Phase 3: Automatic Minor Water Detection
1. Use heightmap analysis to find small ponds/streams
2. Auto-generate WaterVolumes for these
3. Allow manual override/refinement

### Phase 4: Blending & Polish
1. Implement blend zones between water types
2. Add foam/splash at boundaries
3. Ensure consistent water height across adjacent volumes

## Tools Needed

### Lake Polygon Editor (Godot Editor Plugin)

```gdscript
@tool
extends EditorPlugin

var lake_editor: Control

func _enter_tree():
    lake_editor = preload("res://addons/lake_editor/lake_editor.tscn").instantiate()
    add_control_to_bottom_panel(lake_editor, "Lake Editor")

func _handles(object):
    return object is PolygonWaterVolume

func _edit(object):
    if object is PolygonWaterVolume:
        lake_editor.edit_lake(object)

# Lake editor allows:
# - Click to add polygon points
# - Drag to adjust points
# - Export to JSON
# - Import from JSON
# - Preview in viewport
```

### Morrowind Lake Extractor (Python Script)

```python
# Extract water plane data from Morrowind ESM
import openmw_esm_reader

def extract_water_bodies(esm_file):
    """
    Since Morrowind doesn't have lake data, this would:
    1. Load all exterior cells
    2. Find cells with water_height != default
    3. Group contiguous water cells
    4. Trace boundary polygons
    5. Export to JSON
    """
    lakes = []
    # ... implementation
    return lakes
```

## Implementation Checklist

- [x] Add shore mask to ocean_compute.gdshader
- [x] Add shore mask to ocean_gerstner.gdshader
- [ ] Add shore mask to ocean_low.gdshader
- [ ] Add shore mask to ocean_flat.gdshader
- [ ] Create PolygonWaterVolume class
- [ ] Create lake database JSON schema
- [ ] Build lake polygon editor tool
- [ ] Map major Morrowind lakes manually
- [ ] Implement heightmap-based detection for minor water
- [ ] Add transition blending between water types
- [ ] Test with full Vvardenfell terrain

## Performance Considerations

**Polygon Water Volumes:**
- ✅ More accurate lake shapes
- ✅ Better for complex coastlines
- ⚠️ More complex collision detection
- ⚠️ More vertices in water mesh

**Optimization:**
- Use LOD for distant water surfaces
- Simplify polygons far from player
- Cull underwater portions
- Share materials between similar water volumes

## Alternative: Hybrid Approach

**Best of Both Worlds:**

1. **Ocean plane** - Handles majority of water (coastline, far distance)
2. **Polygon lakes** - Only for landlocked lakes that ocean can't reach
3. **Box rivers** - For narrow flowing water (simpler than polygons)

This minimizes the number of complex polygon volumes needed while still handling all water types correctly.

---

## Conclusion

The key insight is that **Morrowind doesn't have lake boundary data**, so we must:
1. Use shore masking to hide ocean on land
2. Manually define lake boundaries (polygons preferred over boxes)
3. Store lake data in external file (JSON)
4. Implement smooth transitions between water types

The ocean shader fixes I've made will prevent ocean from showing inland. Combined with polygon-based WaterVolumes for lakes, this creates a complete water system for Morrowind's complex water geography.
