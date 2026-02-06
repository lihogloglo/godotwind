# Prebaking Pipeline

**Core Philosophy:** Prebake everything possible to avoid runtime conversion overhead.

---

## Why Prebake?

| Approach | Load Time | First-Run Experience | Disk Usage |
|----------|-----------|---------------------|------------|
| **Runtime conversion** | 50-200ms per NIF | Stuttery, unpredictable | Minimal |
| **Prebaked assets** | 1-5ms per .res | Smooth, instant | ~2-5GB cache |

---

## What We Prebake

| Asset Type | Source Format | Output Format | Location |
|------------|---------------|---------------|----------|
| **Meshes** | NIF (binary) | `.res` (ArrayMesh) | `cache/meshes/` |
| **LOD Meshes** | Generated from NIF | `.res` (simplified) | `cache/meshes/` |
| **Materials** | NIF properties | `.tres` (StandardMaterial3D) | `cache/materials/` |
| **Textures** | DDS/TGA | `.res` (CompressedTexture2D) | `cache/textures/` |
| **Impostors** | Rendered from mesh | `.png` (octahedral atlas) | `cache/impostors/` |
| **Terrain** | ESM heightmap data | Terrain3D format | `cache/terrain/` |
| **NavMesh** | Generated from geometry | `.res` (NavigationMesh) | `cache/navmesh/` |
| **Cell Data** | ESM records | `.tres` (CellData) | `cache/cells/` |
| **Collision** | NIF/generated | `.res` (Shape3D) | `cache/collision/` |

---

## Pipeline Stages

```
Stage 1: Parse ESM/BSA
|- Extract all records from Morrowind.esm, Tribunal.esm, Bloodmoon.esm
|- Build spatial index (cell grid -> references)
|- Output: cache/cells/*.tres

Stage 2: Convert Textures
|- Extract DDS/TGA from BSA archives
|- Convert to Godot CompressedTexture2D
|- Generate mipmaps if missing
|- Output: cache/textures/*.res

Stage 3: Convert Meshes
|- Parse all NIF files (C# for speed)
|- Convert to Godot ArrayMesh
|- Apply material references
|- Generate collision shapes (auto-detect primitives)
|- Output: cache/meshes/*.res, cache/collision/*.res

Stage 4: Generate LODs
|- For each mesh, generate 3 LOD levels
|  |- LOD1: 75% triangles (150-250m)
|  |- LOD2: 50% triangles (250-375m)
|  |- LOD3: 25% triangles (375-500m)
|- Output: cache/meshes/*_LOD1.res, *_LOD2.res, *_LOD3.res

Stage 5: Generate Impostors
|- For significant objects (buildings, large statics)
|- Render 8 octahedral views
|- Composite into single atlas texture
|- Output: cache/impostors/*.png

Stage 6: Generate Terrain
|- Extract heightmap data from ESM LAND records
|- Convert to Terrain3D format
|- Generate terrain texture splatmaps
|- Output: cache/terrain/

Stage 7: Generate NavMesh
|- Process walkable geometry per cell
|- Generate NavigationMesh resources
|- Link adjacent cells for seamless navigation
|- Output: cache/navmesh/*.res
```

---

## Prebaking Tools

**Main prebaking UI:** `src/tools/prebaking_ui.gd`

```gdscript
func run_full_prebake() -> void:
    await _prebake_textures()
    await _prebake_meshes()
    await _prebake_lods()
    await _prebake_impostors()
    await _prebake_terrain()
    await _prebake_navmesh()
    await _prebake_cells()
```

**Incremental prebaking:**
```gdscript
func run_incremental_prebake() -> void:
    var modified := _get_modified_source_files()
    for file in modified:
        await _prebake_single_asset(file)
```

---

## Cache Directory Structure

```
cache/
|- meshes/
|  |- architecture/
|  |  |- door_wood_01.res
|  |  |- door_wood_01_LOD1.res
|  |  |- door_wood_01_LOD2.res
|  |  |- door_wood_01_LOD3.res
|  |- statics/
|- materials/     [hash-based deduplication]
|- textures/
|- impostors/
|- terrain/       [Terrain3D data]
|- navmesh/
|- cells/
|- manifest.json  # Tracks prebake versions
```

---

## Runtime Loading (Post-Prebake)

```gdscript
# Instead of: parse NIF -> convert -> create mesh (50-200ms)
# We do: load prebaked resource (1-5ms)
func load_mesh(model_path: String) -> Mesh:
    var cache_path := _get_cache_path(model_path)
    return load(cache_path)

func load_cell_data(grid: Vector2i) -> CellData:
    var path := "res://cache/cells/cell_%d_%d.tres" % [grid.x, grid.y]
    return load(path)
```

---

## Prebake Validation

```gdscript
func validate_cache() -> bool:
    var manifest := _load_manifest()
    if manifest.version != CURRENT_CACHE_VERSION:
        push_warning("Cache version mismatch, full rebake required")
        return false
    for i in 100:
        var random_file := manifest.files.pick_random()
        if not FileAccess.file_exists(random_file):
            return false
    return true
```

---

## When to Rebake

- First installation (no cache exists)
- After updating Godotwind version (cache format may change)
- After modifying source Morrowind files
- After installing new mods that add/modify NIFs
- NOT during normal gameplay (use existing cache)
