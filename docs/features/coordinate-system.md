# Coordinate System

The coordinate system module handles conversion between Morrowind's coordinate space and Godot's coordinate space.

## Overview

Morrowind and Godot use different coordinate conventions:

- **Morrowind**: Right-handed, Z-up coordinate system
- **Godot**: Right-handed, Y-up coordinate system

Additionally, Morrowind uses its own unit scale that must be converted to Godot's meter-based scale.

## Location

- `src/core/coordinate_system.gd` - Active system (use this)
- `src/core/morrowind_coords.gd` - Legacy/deprecated (do not use)

## Key Constants

```gdscript
const CELL_SIZE_MW = 8192.0          # Morrowind cell size in game units
const UNITS_PER_METER = 70.0         # Morrowind units per real-world meter
const CELL_SIZE_GODOT = 117.028...   # Cell size in Godot meters
```

### Derivation

```
CELL_SIZE_GODOT = CELL_SIZE_MW / UNITS_PER_METER
                = 8192.0 / 70.0
                = 117.02857 meters
```

This means each Morrowind cell is approximately 117 meters × 117 meters in Godot.

## Core Functions

### Position Conversion

```gdscript
# Convert Morrowind position to Godot
func mw_to_godot(mw_pos: Vector3) -> Vector3

# Convert Godot position to Morrowind
func godot_to_mw(godot_pos: Vector3) -> Vector3
```

**Transformation**:
```
Morrowind (X, Y, Z) → Godot (X/70, Z/70, -Y/70)
              ↑              ↑   ↑     ↑
              │              │   │     └─ Y → -Z (axis swap + flip)
              │              │   └─────── Z → Y (axis swap)
              │              └─────────── X → X (no change)
              └──────────────────────────── Scale by 1/70
```

### Cell Grid Conversion

```gdscript
# Get cell center position in Godot space
func cell_grid_to_center_godot(grid_x: int, grid_y: int) -> Vector3

# Get cell grid coordinates from Godot position
func godot_to_cell_grid(godot_pos: Vector3) -> Vector2i
```

**Example**:
```gdscript
# Seyda Neen is at cell (0, -2)
var center = CoordinateSystem.cell_grid_to_center_godot(0, -2)
# Returns: Vector3(58.51, 0, 234.06)
#          (half cell size in X, ground level, -2 cells in Z)
```

## Usage Examples

### Converting Object Positions

```gdscript
# Loading an object from ESM
var cell = ESMManager.get_exterior_cell(0, -2)
for ref in cell.references:
    var mw_pos = ref.position  # Morrowind coordinates
    var godot_pos = CoordinateSystem.mw_to_godot(mw_pos)

    var model = NIFConverter.load_and_convert(ref.model_path)
    model.position = godot_pos
    add_child(model)
```

### Camera Position to Cell Grid

```gdscript
# Get which cell the camera is in
var camera_pos = camera.global_position
var cell_coords = CoordinateSystem.godot_to_cell_grid(camera_pos)
print("Camera in cell: ", cell_coords)  # e.g., Vector2i(0, -2)
```

### Loading Cells Around Position

```gdscript
# Load cells in a radius around camera
var center_cell = CoordinateSystem.godot_to_cell_grid(camera.global_position)
var radius = 2

for y in range(center_cell.y - radius, center_cell.y + radius + 1):
    for x in range(center_cell.x - radius, center_cell.x + radius + 1):
        load_cell(x, y)
```

## Coordinate Space Details

### Morrowind World Space

- Origin (0, 0, 0): Somewhere in the Bitter Coast region
- Cell (0, -2): Seyda Neen (starting town)
- Each cell: 8192 units × 8192 units
- Z-axis: Up
- Rotation: Radians around Z-axis (heading)

### Godot World Space

- Origin (0, 0, 0): Converted from Morrowind (0, 0, 0)
- Cell (0, -2): Approximately (58.5, 0, 234) meters
- Each cell: ~117m × ~117m
- Y-axis: Up
- Rotation: Uses Godot's standard Euler angles

## Rotation Conversion

Morrowind uses a different rotation system than Godot:

```gdscript
# Morrowind rotation (radians around Z)
var mw_rotation = ref.rotation

# Convert to Godot rotation
# Note: Morrowind's Z-up rotation becomes Y-up rotation in Godot
var godot_rotation = Vector3(
    mw_rotation.x,      # Pitch
    -mw_rotation.z,     # Yaw (Z → Y, negated)
    mw_rotation.y       # Roll
)
```

## Terrain Heightmap Conversion

Terrain requires special handling because heightmaps have their own coordinate system:

```gdscript
# Morrowind LAND record has 65×65 heightmap
# Coordinates: (0,0) = NW corner, (64,64) = SE corner

# When converting to Godot:
# - Y-axis must be flipped (Morrowind's north → Godot's south)
# - Heights scaled by 1/UNITS_PER_METER

func convert_heightmap(land: LandRecord) -> Image:
    var img = Image.create(65, 65, false, Image.FORMAT_RF)

    for y in range(65):
        for x in range(65):
            var mw_height = land.get_height(x, y)
            var godot_height = mw_height / UNITS_PER_METER

            # Flip Y-axis
            var godot_y = 64 - y

            img.set_pixel(x, godot_y, Color(godot_height, 0, 0))

    return img
```

## Integration Points

Every system that deals with spatial data uses `CoordinateSystem`:

- **CellManager**: Converts object positions when loading cells
- **TerrainManager**: Converts heightmaps and cell positions
- **WorldStreamingManager**: Converts camera position to cell grid
- **NIFConverter**: Applies coordinate conversion to model transforms

## Common Pitfalls

### Don't Mix Coordinate Spaces

```gdscript
# BAD: Using Morrowind coordinates directly
var mw_pos = Vector3(1000, 2000, 100)
model.position = mw_pos  # Wrong scale and axes!

# GOOD: Always convert
var godot_pos = CoordinateSystem.mw_to_godot(mw_pos)
model.position = godot_pos
```

### Don't Forget Height Conversion

```gdscript
# BAD: Using Morrowind height units
var height = land.get_height(x, y)
terrain.set_height(x, y, height)  # Way too tall!

# GOOD: Scale to Godot meters
var height = land.get_height(x, y) / CoordinateSystem.UNITS_PER_METER
terrain.set_height(x, y, height)
```

### Cell Grid vs World Position

```gdscript
# Cell grid coordinates are integers
var cell_grid = Vector2i(0, -2)

# World positions are floats
var world_pos = Vector3(58.5, 0, 234.0)

# Don't confuse them:
# BAD
load_cell(world_pos.x, world_pos.z)  # Wrong!

# GOOD
var cell_grid = CoordinateSystem.godot_to_cell_grid(world_pos)
load_cell(cell_grid.x, cell_grid.y)
```

## Testing Coordinate Conversion

Use the Cell Viewer tool to verify conversions:

1. Open `src/tools/cell_viewer.tscn`
2. Load a known cell (e.g., "Seyda Neen, Census and Excise Office")
3. Verify objects appear in correct positions
4. Check that the world looks correct (not scaled weird or upside-down)

## Performance

Coordinate conversion is very fast:
- Simple arithmetic operations
- No allocations
- Typically <0.01ms per conversion
- Called thousands of times per cell load, but not a bottleneck

## Summary

- Always use `CoordinateSystem.mw_to_godot()` for positions
- Cell grid uses integer coordinates, world uses floats
- Heightmaps require Y-axis flip
- Morrowind cell = ~117m × ~117m in Godot
- Rotations need special handling (Z-up → Y-up)
