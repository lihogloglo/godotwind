# Terrain System

## Overview

The terrain system converts Morrowind's LAND records into high-performance Terrain3D instances with heightmaps, texture splatting, and vertex colors. It supports both **single-terrain** mode (one Terrain3D for 32×32 cells) and **multi-terrain** mode (unlimited world size via terrain chunks).

---

## Status Audit

### ✅ Completed
- LAND record → Terrain3D conversion
- Heightmap generation (65×65 vertices → 64×64 Terrain3D)
- Texture splatting (32 texture slots with blending)
- Vertex color support (ambient occlusion, tinting)
- Edge stitching (seamless cell boundaries)
- Coordinate system conversion (Z-up → Y-up)
- Normal/scale axis flipping for correct orientation
- Material library for texture deduplication
- Single-terrain mode (32×32 cells, ~3.7km²)
- Multi-terrain mode (infinite chunks)
- Terrain data caching (`user://terrain_data/`)
- Terrain preprocessor tool

### ⚠️ In Progress
- Dynamic terrain editing (Terrain3D supports it but not exposed)
- Terrain LOD (Terrain3D has built-in LOD but needs tuning)
- Terrain holes (for caves/tunnels - Terrain3D supports it)

### ❌ Not Started
- Procedural terrain generation (beyond ESM data)
- Terrain physics materials (different friction/bounce per texture)
- Splat map painting tools (runtime editing)
- Terrain decals (blood, scorch marks)

---

## Architecture

### Data Flow

```
ESM LAND Record (Morrowind format)
├─ height_data: Array[int] (65x65 vertices, Z-up, signed offsets)
├─ texture_indices: Array[int] (16x16 texture IDs per vertex quad)
├─ vertex_colors: Array[Color] (65x65 RGB values)
└─ normals: Array[Vector3] (optional, usually generated)
         │
         ▼
   TerrainManager / MultiTerrainManager
         │
         ├─ Heightmap Conversion
         │  ├─ Flip Y axis (north/south correction)
         │  ├─ Scale to meters (70 units = 1m)
         │  ├─ Apply base height offset
         │  └─ Normalize to 0-1 range
         │
         ├─ Control Map Conversion
         │  ├─ Map LTEX indices → Terrain3D slots (0-31)
         │  ├─ Encode texture blending (bilinear interpolation)
         │  ├─ UV rotation/scale (per texture)
         │  └─ Pack into Terrain3D control format
         │
         ├─ Color Map Conversion
         │  └─ Direct RGB → RGB (no conversion needed)
         │
         └─ Edge Stitching
            └─ Ensure vertex alignment at cell boundaries
         │
         ▼
  Terrain3D Instance (Godot native)
  ├─ HeightMap (Image, FORMAT_RF)
  ├─ ControlMap (Image, custom format)
  ├─ ColorMap (Image, FORMAT_RGB8)
  └─ TextureList (32 slots, albedo + normal)
```

---

## Key Files

| File | Path | Purpose |
|------|------|---------|
| **TerrainManager** | [src/core/world/terrain_manager.gd](../src/core/world/terrain_manager.gd) | Single-terrain conversion |
| **MultiTerrainManager** | [src/core/world/multi_terrain_manager.gd](../src/core/world/multi_terrain_manager.gd) | Multi-chunk terrain |
| **TerrainTextureLoader** | [src/core/texture/terrain_texture_loader.gd](../src/core/texture/terrain_texture_loader.gd) | LTEX → texture slots |
| **TerrainPreprocessor** | [src/tools/terrain_preprocessor.gd](../src/tools/terrain_preprocessor.gd) | Batch conversion tool |
| **CoordinateSystem** | [src/core/coordinate_system.gd](../src/core/coordinate_system.gd) | Morrowind ↔ Godot coords |

---

## Terrain3D Integration

### Plugin Version
**Terrain3D 1.0.1** - High-performance editable terrain system for Godot 4

### Features Used
- **Region-based storage** (64×64 vertices per region, 1 region = 1 cell)
- **32 texture slots** (slot 0 = default grass, slots 1-31 from LTEX)
- **Control map** (texture blending + UV transforms)
- **Color map** (vertex tinting)
- **Auto-generated normals** (from heightmap)
- **LOD system** (built-in, auto-scales detail with distance)
- **Clipmap rendering** (efficient GPU streaming)

### Not Yet Used
- **Editing tools** (Terrain3D has brush painting, not exposed)
- **Holes** (for caves/overhangs, supported but not implemented)
- **Instancer** (for automatic grass/rock placement)
- **Navigation mesh baking** (for AI pathfinding)

---

## Heightmap Conversion

### Morrowind Format
- **Size:** 65×65 vertices per cell
- **Values:** Signed int offsets from base height
- **Range:** -2048 to +2047 units
- **Base Height:** Per-cell offset in LAND record
- **Coordinate System:** Z-up, Y-forward, X-right

### Godot Format (Terrain3D)
- **Size:** 64×64 vertices per region (1 less than Morrowind!)
- **Values:** Float heights in meters
- **Range:** Unlimited (float)
- **Coordinate System:** Y-up, -Z-forward, X-right

### Conversion Algorithm

```gdscript
func _convert_heightmap(land: LandRecord) -> PackedFloat32Array:
    var heights := PackedFloat32Array()
    heights.resize(65 * 65)

    for y in range(65):
        for x in range(65):
            var mw_index := y * 65 + x
            var raw_height: int = land.height_data[mw_index]

            # Scale from units to meters (70 units = 1 meter)
            var height_meters := raw_height / 70.0

            # Add base height
            height_meters += land.base_height / 70.0

            # CRITICAL: Flip Y axis (Morrowind north/south is inverted)
            var flipped_y := 64 - y
            var godot_index := flipped_y * 65 + x

            heights[godot_index] = height_meters

    # Terrain3D uses 64x64, downsample or crop edges
    return _crop_to_64x64(heights)

func _crop_to_64x64(heights_65x65: PackedFloat32Array) -> PackedFloat32Array:
    var heights_64x64 := PackedFloat32Array()
    heights_64x64.resize(64 * 64)

    for y in range(64):
        for x in range(64):
            var src_index := y * 65 + x
            var dst_index := y * 64 + x
            heights_64x64[dst_index] = heights_65x65[src_index]

    return heights_64x64
```

---

## Control Map (Texture Splatting)

### Morrowind Format
- **LTEX Records:** Texture definitions (file path, index)
- **Texture Indices:** 16×16 grid of texture IDs per cell (one per vertex quad)
- **Blending:** Hard edges (no smooth blending)

### Terrain3D Format
- **32 Texture Slots:** Base + 31 splatted textures
- **Control Map:** Per-vertex texture weights
- **Encoding:** Custom format with UV rotation/scale
- **Blending:** Smooth interpolation between textures

### Conversion Algorithm

```gdscript
func _convert_control_map(land: LandRecord) -> Image:
    var control_map := Image.create(64, 64, false, Image.FORMAT_RGB8)

    for y in range(16):
        for x in range(16):
            var texture_index: int = land.texture_indices[y * 16 + x]

            # Map LTEX index to Terrain3D slot (0-31)
            var slot := _map_texture_index(texture_index)

            # Fill 4x4 vertex quad with this texture
            for qy in range(4):
                for qx in range(4):
                    var pixel_x := x * 4 + qx
                    var pixel_y := (15 - y) * 4 + qy  # Flip Y

                    # Encode slot into RGB channels
                    # (Terrain3D custom format, see documentation)
                    var color := _encode_texture_slot(slot)
                    control_map.set_pixel(pixel_x, pixel_y, color)

    return control_map

func _encode_texture_slot(slot: int) -> Color:
    # Terrain3D control map encoding:
    # R channel: Primary texture slot (0-31)
    # G channel: Secondary texture slot (for blending)
    # B channel: Blend weight (0-255)
    return Color(slot / 31.0, 0, 0)  # 100% primary, no blend

func _map_texture_index(ltex_index: int) -> int:
    # LTEX 0 = default (Terrain3D slot 0)
    if ltex_index == 0:
        return 0

    # Map LTEX records to slots 1-31
    var ltex := ESMManager.land_textures.get(ltex_index)
    if not ltex:
        return 0  # Fallback

    # Use texture file path as key
    return _texture_to_slot.get(ltex.texture_path, 0)
```

---

## Color Map (Vertex Colors)

### Morrowind Format
- **Size:** 65×65 vertices
- **Values:** RGB colors (0-255 per channel)
- **Purpose:** Ambient occlusion, shadows, tinting

### Godot Format
- **Size:** 64×64 (same as heightmap)
- **Values:** RGB8 (same as Morrowind)
- **Purpose:** Same (multiply with albedo texture)

### Conversion Algorithm

```gdscript
func _convert_color_map(land: LandRecord) -> Image:
    if not land.vertex_colors or land.vertex_colors.size() == 0:
        return _create_default_color_map()  # White

    var color_map := Image.create(64, 64, false, Image.FORMAT_RGB8)

    for y in range(64):
        for x in range(64):
            # Flip Y axis
            var src_y := 64 - y
            var src_index := src_y * 65 + x
            var color: Color = land.vertex_colors[src_index]

            color_map.set_pixel(x, y, color)

    return color_map

func _create_default_color_map() -> Image:
    var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
    img.fill(Color.WHITE)  # No tinting
    return img
```

---

## Edge Stitching

### Problem
Morrowind cells are independent - adjacent cells may have height mismatches at edges, causing cracks or overlaps.

### Solution
**Shared edge vertices** - Ensure cells agree on boundary heights.

```gdscript
func _stitch_edges(cell: Vector2i, heights: PackedFloat32Array) -> PackedFloat32Array:
    # Get neighboring cells
    var neighbors := {
        "north": ESMManager.lands.get("%d,%d" % [cell.x, cell.y + 1]),
        "south": ESMManager.lands.get("%d,%d" % [cell.x, cell.y - 1]),
        "east":  ESMManager.lands.get("%d,%d" % [cell.x + 1, cell.y]),
        "west":  ESMManager.lands.get("%d,%d" % [cell.x - 1, cell.y])
    }

    # North edge (y=0)
    if neighbors["north"]:
        for x in range(64):
            var neighbor_height := _get_south_edge_height(neighbors["north"], x)
            heights[0 * 64 + x] = neighbor_height

    # South edge (y=63)
    if neighbors["south"]:
        for x in range(64):
            var neighbor_height := _get_north_edge_height(neighbors["south"], x)
            heights[63 * 64 + x] = neighbor_height

    # East edge (x=63)
    if neighbors["east"]:
        for y in range(64):
            var neighbor_height := _get_west_edge_height(neighbors["east"], y)
            heights[y * 64 + 63] = neighbor_height

    # West edge (x=0)
    if neighbors["west"]:
        for y in range(64):
            var neighbor_height := _get_east_edge_height(neighbors["west"], y)
            heights[y * 64 + 0] = neighbor_height

    return heights
```

---

## Texture System

### Texture Slots (32 Total)

| Slot | Purpose | Source |
|------|---------|--------|
| 0 | Default (base grass) | Hardcoded |
| 1-31 | Morrowind LTEX records | Loaded from BSA |

### TerrainTextureLoader

```gdscript
class_name TerrainTextureLoader

var _slot_map: Dictionary = {}  # ltex_index -> slot
var _loaded_textures: Array[Texture2D] = []

func load_textures() -> void:
    _loaded_textures.resize(32)
    _loaded_textures[0] = _load_default_texture()

    var slot := 1
    for ltex_index in ESMManager.land_textures.keys():
        if slot >= 32:
            push_warning("Exceeded 32 texture slots!")
            break

        var ltex: LandTextureRecord = ESMManager.land_textures[ltex_index]
        var texture := _load_texture_from_bsa(ltex.texture_path)

        if texture:
            _loaded_textures[slot] = texture
            _slot_map[ltex_index] = slot
            slot += 1

func _load_texture_from_bsa(path: String) -> Texture2D:
    # Try albedo
    var albedo_data := BSAManager.get_file(path)
    if not albedo_data:
        return null

    var img := TextureLoader.load_dds(albedo_data)
    return ImageTexture.create_from_image(img)
```

### Normal Maps

Morrowind doesn't have normal maps (2002 game!), but we can:
1. **Generate from heightmap** (Terrain3D does this automatically)
2. **Use placeholder normals** (flat blue)
3. **Add custom normal maps** (for next-gen enhancement)

---

## Single-Terrain vs Multi-Terrain

### Single-Terrain Mode

**Pros:**
- Simpler implementation
- One Terrain3D instance
- Better for small worlds

**Cons:**
- Limited to 32×32 cells (~3.7km²)
- Morrowind Vvardenfell is 46×40 cells (exceeds limit!)
- Wastes memory (loads entire terrain at once)

**Use Case:** Testing, small islands, interior landscapes

```gdscript
# TerrainManager
@onready var terrain: Terrain3D = $Terrain3D

func load_all_cells() -> void:
    for x in range(-16, 16):
        for y in range(-16, 16):
            load_cell_terrain(Vector2i(x, y))
```

### Multi-Terrain Mode

**Pros:**
- Unlimited world size
- Loads chunks on-demand (memory efficient)
- Supports Daggerfall-scale maps

**Cons:**
- More complex (multiple Terrain3D instances)
- Potential seams between chunks (mitigated by edge stitching)
- Higher overhead per chunk

**Use Case:** Full Morrowind, Daggerfall, procedural worlds

```gdscript
# MultiTerrainManager
var _active_chunks: Dictionary = {}  # Vector2i -> Terrain3D
const CHUNK_SIZE := 8  # 8x8 cells per chunk

func load_chunk(cell: Vector2i) -> void:
    var chunk_coord := Vector2i(cell.x / CHUNK_SIZE, cell.y / CHUNK_SIZE)

    if _active_chunks.has(chunk_coord):
        return

    var terrain := Terrain3D.new()
    terrain.position = Vector3(
        chunk_coord.x * CHUNK_SIZE * 117.0,
        0,
        chunk_coord.y * CHUNK_SIZE * 117.0
    )
    add_child(terrain)

    # Load 8x8 cells
    for cx in range(CHUNK_SIZE):
        for cy in range(CHUNK_SIZE):
            var cell_in_chunk := chunk_coord * CHUNK_SIZE + Vector2i(cx, cy)
            _load_cell_into_chunk(cell_in_chunk, terrain)

    _active_chunks[chunk_coord] = terrain
```

---

## Terrain Preprocessing

### Why Preprocess?
Converting LAND records to Terrain3D is expensive (5-10ms per cell). Preprocessing converts all cells once and caches results to disk.

### TerrainPreprocessor Tool

```gdscript
# src/tools/terrain_preprocessor.gd
func preprocess_all_terrain() -> void:
    var cells := ESMManager.lands.keys()
    print("Preprocessing %d cells..." % cells.size())

    for i in range(cells.size()):
        var cell_key: String = cells[i]
        var parts := cell_key.split(",")
        var cell := Vector2i(int(parts[0]), int(parts[1]))

        _preprocess_cell(cell)

        if i % 10 == 0:
            print("Progress: %d / %d" % [i, cells.size()])

func _preprocess_cell(cell: Vector2i) -> void:
    var land: LandRecord = ESMManager.lands.get("%d,%d" % [cell.x, cell.y])
    if not land:
        return

    # Convert to Terrain3D format
    var terrain_data := Terrain3DData.new()
    terrain_data.heightmap = _convert_heightmap(land)
    terrain_data.control_map = _convert_control_map(land)
    terrain_data.color_map = _convert_color_map(land)

    # Save to disk
    var save_path := "user://terrain_data/cell_%d_%d.res" % [cell.x, cell.y]
    ResourceSaver.save(terrain_data, save_path)
```

### Usage

```gdscript
# Run once after loading ESM
terrain_preprocessor.preprocess_all_terrain()

# Later, load from cache
func load_cell_terrain(cell: Vector2i) -> void:
    var cache_path := "user://terrain_data/cell_%d_%d.res" % [cell.x, cell.y]
    if FileAccess.file_exists(cache_path):
        var terrain_data: Terrain3DData = load(cache_path)
        terrain.apply_data(terrain_data)
    else:
        # Fallback: convert on-the-fly
        _convert_cell_terrain(cell)
```

---

## Coordinate System Details

### Morrowind Cell Coordinates
- **Origin:** (0, 0) near Seyda Neen
- **X:** East (positive) / West (negative)
- **Y:** North (positive) / South (negative)
- **Cell Size:** 8192 units (117m)

### Godot World Coordinates
- **Origin:** (0, 0, 0)
- **X:** East (positive) / West (negative)
- **Z:** South (positive) / North (negative) ← **Inverted Y!**
- **Cell Size:** 117m

### Conversion

```gdscript
# CoordinateSystem.gd
const CELL_SIZE := 117.0  # meters
const UNITS_PER_METER := 70.0

static func cell_to_world_position(cell: Vector2i) -> Vector3:
    return Vector3(
        cell.x * CELL_SIZE,
        0,
        -cell.y * CELL_SIZE  # Flip Y → -Z
    )

static func world_position_to_cell(pos: Vector3) -> Vector2i:
    return Vector2i(
        int(pos.x / CELL_SIZE),
        int(-pos.z / CELL_SIZE)  # Flip -Z → Y
    )
```

---

## Best Practices

### 1. Always Flip Y Axis
Morrowind's north/south is inverted in Godot:

```gdscript
# ❌ Wrong: Direct copy
for y in range(65):
    heights[y * 65 + x] = land.height_data[y * 65 + x]

# ✅ Correct: Flip Y
for y in range(65):
    var flipped_y := 64 - y
    heights[flipped_y * 65 + x] = land.height_data[y * 65 + x]
```

### 2. Preprocess for Production
Never convert terrain on-the-fly in production:

```gdscript
# Development: On-the-fly conversion
terrain_manager.load_cell_terrain(cell)

# Production: Load from cache
terrain_manager.load_cached_terrain(cell)
```

### 3. Use Multi-Terrain for Large Worlds
Single-terrain is limited to 1024×1024 vertices (32×32 cells):

```gdscript
if world_size > Vector2i(32, 32):
    use_multi_terrain = true
```

### 4. Stitch Edges
Always stitch cell boundaries to avoid cracks:

```gdscript
heights = _stitch_edges(cell, heights)
```

### 5. Validate Terrain Data
Check for invalid heights before uploading:

```gdscript
for h in heights:
    if is_nan(h) or is_inf(h):
        push_error("Invalid height: %s" % h)
        h = 0.0
```

---

## Debugging

### Visualize Heightmap

```gdscript
func _debug_draw_heightmap(heights: PackedFloat32Array) -> void:
    for y in range(64):
        for x in range(64):
            var h := heights[y * 64 + x]
            var color := Color(h / 100.0, h / 100.0, h / 100.0)  # Grayscale
            DebugDraw.draw_point(Vector3(x, h, y), color)
```

### Visualize Control Map

```gdscript
func _debug_draw_control_map(control: Image) -> void:
    for y in range(64):
        for x in range(64):
            var color := control.get_pixel(x, y)
            DebugDraw.draw_point(Vector3(x, 0, y), color)
```

### Terrain Stats

```gdscript
func get_terrain_stats() -> Dictionary:
    return {
        "active_chunks": _active_chunks.size(),
        "total_vertices": _active_chunks.size() * 64 * 64,
        "memory_mb": _estimate_memory_usage(),
        "texture_slots_used": _get_used_texture_slots()
    }
```

---

## Common Issues

### Issue: Terrain Has Visible Seams
**Cause:** Edge stitching not working
**Solution:** Verify neighbor cells are loaded before stitching

### Issue: Terrain Is Too Flat/Steep
**Cause:** Height scale incorrect
**Solution:** Adjust `UNITS_PER_METER` constant (default 70.0)

### Issue: Textures Look Wrong
**Cause:** Y-axis not flipped in control map
**Solution:** Flip Y in `_convert_control_map()`

### Issue: Terrain Offset from Objects
**Cause:** Coordinate conversion mismatch
**Solution:** Ensure both terrain and objects use `CoordinateSystem`

---

## Future Improvements

### ⚠️ Dynamic Terrain Editing
Allow runtime modification:

```gdscript
func dig_crater(position: Vector3, radius: float) -> void:
    var affected_cells := _get_cells_in_radius(position, radius)
    for cell in affected_cells:
        var terrain := _get_terrain_for_cell(cell)
        terrain.modify_heightmap(position, radius, -5.0)  # Dig down 5m
```

### ⚠️ Terrain Holes
For caves and tunnels:

```gdscript
func create_cave_entrance(position: Vector3, radius: float) -> void:
    var terrain := _get_terrain_at_position(position)
    terrain.set_hole(position, radius, true)
```

### ❌ Procedural Generation
Generate terrain beyond ESM data:

```gdscript
func generate_procedural_terrain(cell: Vector2i) -> void:
    var noise := FastNoiseLite.new()
    var heights := PackedFloat32Array()

    for y in range(64):
        for x in range(64):
            var world_x := cell.x * 64 + x
            var world_y := cell.y * 64 + y
            var h := noise.get_noise_2d(world_x, world_y) * 50.0
            heights.append(h)

    terrain.set_region_heights(cell, heights)
```

---

## Task Tracker

- [x] LAND → heightmap conversion
- [x] LAND → control map conversion
- [x] LAND → color map conversion
- [x] Edge stitching
- [x] Coordinate conversion (Z-up → Y-up)
- [x] Y-axis flipping
- [x] Texture loading (32 slots)
- [x] Single-terrain mode
- [x] Multi-terrain mode
- [x] Terrain preprocessing
- [x] Terrain caching
- [ ] Dynamic terrain editing
- [ ] Terrain holes (caves)
- [ ] Terrain physics materials
- [ ] Procedural generation
- [ ] Normal map generation/loading
- [ ] Terrain LOD tuning

---

**See Also:**
- [02_WORLD_STREAMING.md](02_WORLD_STREAMING.md) - How terrain integrates with streaming
- [07_ASSET_MANAGEMENT.md](07_ASSET_MANAGEMENT.md) - Texture loading from BSA
- [10_DEVELOPMENT_STATUS.md](10_DEVELOPMENT_STATUS.md) - Overall roadmap
