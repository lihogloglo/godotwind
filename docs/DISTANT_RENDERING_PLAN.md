# Distant Rendering & LOD System - Implementation Plan

**Date:** 2025-12-18
**Project:** Godotwind - Next-Gen Open World Features
**Goal:** Implement large view distances with billboards/impostors/LODs to eliminate pop-in

---

## Executive Summary

This plan addresses the current limitation where models only load within ~351m (3 cells), causing:
- Objects popping into existence as you approach
- Empty far backgrounds (terrain only, no structures)
- Unrealistic view distances for next-gen open world

**Solution:** Multi-tiered distant rendering system with:
1. **Near objects (0-500m)**: Full 3D meshes with existing LOD system ✅ Already implemented
2. **Mid-distance objects (500m-2km)**: Simplified mesh LODs or merged static geometry
3. **Far objects (2km-5km)**: Octahedral impostors (pre-rendered billboards)
4. **Horizon objects (5km+)**: Simple billboards or skybox integration

**Expected Results:**
- 5-10× view distance increase
- Elimination of pop-in artifacts
- Maintained 60+ FPS performance
- Works for any scene type (Morrowind, La Palma, etc.)

---

## Current System Analysis

### Existing Strengths ✅

**Already Implemented (from PERFORMANCE_OPTIMIZATION_ROADMAP.md):**
1. **Mesh LOD System** - 4 levels (20m, 50m, 150m, 500m) with VisibilityRange
2. **GPU Instancing** - MultiMesh batching for repeated objects (10+ instances)
3. **Occlusion Culling** - RenderingServer culling + auto-generated occluders
4. **Time-Budgeted Streaming** - 2ms/frame cell loading, async NIF parsing
5. **Object Pooling** - 50-100 instances per common model type
6. **Material Caching** - Global deduplication

### Current Limitations ❌

1. **Hard view distance cap**: 3 cells (~351m) - nothing loads beyond
2. **No distant object representation**: Terrain visible to horizon, but structures/trees invisible
3. **Pop-in artifacts**: Objects suddenly appear at cell boundary
4. **Empty backgrounds**: Cities/landmarks not visible from distance

### Current LOD Configuration

**From `nif_converter.gd:709-800`:**
```gdscript
LOD0: 0-20m    (100% polygons, original mesh)
LOD1: 20-50m   (75% polygons, Quadric Error Metrics)
LOD2: 50-150m  (50% polygons)
LOD3: 150-500m (25% polygons)
Beyond 500m: Culled entirely ❌ THIS IS THE PROBLEM
```

---

## Architecture Research Summary

### OpenMW's Approach (Object Paging)

**Key Techniques:**
1. **Mesh Merging** - Groups nearby static objects into single meshes
2. **LOD Chunking** - Keeps only LOD levels needed for chunk distance
3. **2D Distance Approximation** - Compute min/max distances before chunk split
4. **Merge Cost Multiplier** - Balances visual fidelity vs performance

**Source:** [OpenMW Object Paging](https://gitlab.com/OpenMW/openmw/-/merge_requests/209), [LOD Support MR](https://gitlab.com/OpenMW/openmw/-/merge_requests/2439)

### Godot 4 Capabilities

**Built-in:**
- ✅ VisibilityRange (already used)
- ✅ MultiMesh GPU instancing (already used)
- ✅ Occlusion culling (already enabled)
- ❌ No automatic impostor generation

**Available Plugins:**
1. **godot-imposter** ([GitHub](https://github.com/zhangjt93/godot-imposter)) - Godot 4.x compatible
2. **Godot-Octahedral-Impostors** ([GitHub](https://github.com/wojtekpil/Godot-Octahedral-Impostors)) - Original Godot 3

**Technique:** Octahedral impostors
- Renders object from multiple angles (hemisphere coverage)
- Stores views in texture atlas
- Single quad with shader selects correct view based on camera angle
- 90%+ polygon reduction for distant objects

### Industry Standards (from research)

**Recent Implementations (2025):**
- Frozen Fractal blog: Pre-render meshes to textures from viewpoints, single quad impostor
- LOD transitions still noticeable but acceptable beyond 2km
- Best for: Trees, buildings, rocks, static structures
- Not suitable for: Animated objects, player characters, interactive items

---

## Proposed Architecture

### Multi-Tier Distance System

```
┌────────────────────────────────────────────────────────────────┐
│                     CAMERA POSITION                             │
└────────────┬───────────────────────────────────────────────────┘
             │
    ┌────────┴────────┐
    │                 │
    ▼                 ▼
┌─────────────┐  ┌──────────────────────┐
│  Near Zone  │  │   Extended Zones     │
│   0-500m    │  │   500m - 5km+        │
│  (Existing) │  │   (NEW SYSTEM)       │
└─────────────┘  └──────────┬───────────┘
                            │
                ┌───────────┴───────────────────┐
                │                               │
                ▼                               ▼
      ┌──────────────────┐          ┌──────────────────┐
      │  Mid-Distance    │          │  Far Distance    │
      │   500m - 2km     │          │   2km - 5km      │
      │                  │          │                  │
      │  • Simplified    │          │  • Impostors     │
      │    meshes        │          │  • Billboards    │
      │  • Merged statics│          │  • Skybox blend  │
      └──────────────────┘          └──────────────────┘
```

### Zone Breakdown

#### Zone 1: Near (0-500m) ✅ EXISTING SYSTEM
**Current Implementation:**
- Full 3D meshes with 4 LOD levels
- VisibilityRange automatic transitions
- MultiMesh batching for repeated objects
- Occlusion culling

**No changes needed** - works excellently

#### Zone 2: Mid-Distance (500m-2km) 🔧 NEW - SIMPLIFIED GEOMETRY
**Approach: Static Mesh Merging + Ultra-Low LOD**

**What to render:**
- **Large structures**: Buildings, towers, walls, bridges
- **Landmarks**: Notable locations (Vivec cantons, Red Mountain)
- **Terrain features**: Large rock formations, cliffs
- **Vegetation clusters**: Tree groups (not individual grass)

**Rendering strategy:**
1. **Pre-generate merged meshes** per cell or region
2. **Single draw call** per merged chunk
3. **Ultra-low poly**: 5-10% of original polycount
4. **Simplified materials**: Single albedo texture, no normal maps
5. **Distance-based loading**: Load merged chunks for cells 4-17 (500m-2km)

**Implementation:**
- New class: `DistantStaticRenderer` (similar to `StaticObjectRenderer` for flora)
- Offline preprocessing: Generate merged meshes during asset import
- Runtime: Load pre-merged chunks based on camera position

#### Zone 3: Far Distance (2km-5km) 🔧 NEW - IMPOSTORS
**Approach: Octahedral Impostors**

**What to render:**
- **Major landmarks only**: Red Mountain, Vivec cantons, Ghostfence towers
- **Large structures**: Castles, major cities, lighthouses
- **Distinctive features**: Anything recognizable from distance

**Rendering strategy:**
1. **Pre-bake impostor textures** for important objects
2. **Single quad** with octahedral shader per object
3. **Texture atlas**: Multiple objects in one texture (reduce draw calls)
4. **Camera-facing rotation**: Shader selects correct view angle

**Implementation:**
- Integrate `godot-imposter` plugin for Godot 4.x
- Offline tool: Bake impostors for curated list of objects
- Runtime: Spawn impostor quads for distant cells
- New class: `ImpostorManager`

#### Zone 4: Horizon (5km+) 🔧 NEW - SKYBOX/BILLBOARD
**Approach: Static Skybox Elements**

**What to render:**
- **Red Mountain silhouette** (Morrowind)
- **Island outlines** (La Palma)
- **Distant mountain ranges**

**Rendering strategy:**
1. **Pre-rendered skybox layers** for major locations
2. **Parallax scrolling** based on camera position
3. **Blend with sky shader**

**Implementation:**
- Extend existing Sky3D addon
- Add location-specific distant layers
- Minimal performance cost

---

## Detailed Implementation Plan

### Phase 1: Foundation (Week 1-2) - Extend Loading Distance

**Goal:** Load more cells without rendering everything at full detail

#### Step 1.1: Extend WorldStreamingManager
**File:** `src/core/world/world_streaming_manager.gd`

**Changes:**
1. Add new configuration:
   ```gdscript
   @export var near_view_distance_cells: int = 3        # Full detail (current)
   @export var mid_view_distance_cells: int = 17        # Simplified (500m-2km)
   @export var far_view_distance_cells: int = 43        # Impostors (2km-5km)
   ```

2. Modify `_get_visible_cells()` to return cells with distance tier:
   ```gdscript
   enum DistanceTier { NEAR, MID, FAR }

   func _get_visible_cells_tiered(center: Vector2i) -> Dictionary:
       # Returns: { cell_pos: DistanceTier }
   ```

3. Add priority system for distant cells (load after near cells)

#### Step 1.2: Create DistanceTierManager
**New File:** `src/core/world/distance_tier_manager.gd`

**Responsibilities:**
- Determines which tier a cell belongs to based on distance
- Provides loading strategy for each tier
- Coordinates between existing CellManager and new distant renderers

**API:**
```gdscript
class_name DistanceTierManager extends RefCounted

enum Tier { NEAR, MID, FAR, HORIZON }

func get_tier_for_distance(distance_cells: float) -> Tier
func get_load_strategy(tier: Tier) -> LoadStrategy
func should_load_full_geometry(tier: Tier) -> bool
```

### Phase 2: Mid-Distance System (Week 2-3) - Simplified Geometry

#### Step 2.1: Static Mesh Merger
**New File:** `src/core/world/static_mesh_merger.gd`

**Responsibilities:**
- Combines multiple static meshes into single mesh
- Applies transform baking
- Generates simplified materials
- Caches merged results

**Algorithm:**
```gdscript
func merge_cell_statics(cell_refs: Array[CellReference]) -> MeshInstance3D:
    var surface_tool = SurfaceTool.new()

    for ref in cell_refs:
        if not _should_merge(ref):
            continue

        var mesh = _get_simplified_mesh(ref.model_path)
        var transform = _calculate_transform(ref)

        surface_tool.append_from(mesh, 0, transform)

    return _create_merged_instance(surface_tool)

func _should_merge(ref: CellReference) -> bool:
    # Merge if:
    # - Static (not NPC, creature, door)
    # - Larger than 2m (skip clutter)
    # - Not unique landmark (those get impostors)
    pass
```

**Integration:**
- Called by `DistanceTierManager` for MID tier cells
- Results cached in `ModelLoader` with special key prefix "merged_cell_"

#### Step 2.2: Ultra-Low LOD Generation
**File:** `src/core/nif/mesh_simplifier.gd` (extend existing)

**Changes:**
1. Add aggressive simplification mode:
   ```gdscript
   func simplify_mesh_aggressive(mesh: ArrayMesh, target: float = 0.05) -> ArrayMesh:
       # 95% polygon reduction
       # Remove all detail, keep silhouette only
   ```

2. Strip complex materials:
   ```gdscript
   func create_distance_material(base_mat: Material) -> Material:
       # Single texture, no normal maps, no specular
       # Unshaded for far distances
   ```

#### Step 2.3: DistantStaticRenderer
**New File:** `src/core/world/distant_static_renderer.gd`

**Similar to:** `StaticObjectRenderer` (RenderingServer-based flora rendering)

**Responsibilities:**
- Manages merged meshes for mid-distance cells
- Uses RenderingServer RIDs for efficiency
- Handles loading/unloading based on camera movement

**API:**
```gdscript
class_name DistantStaticRenderer extends Node

func add_cell(cell_grid: Vector2i, merged_mesh: MeshInstance3D) -> void
func remove_cell(cell_grid: Vector2i) -> void
func update_visibility_by_distance(camera_pos: Vector3) -> void
```

### Phase 3: Far Distance System (Week 3-4) - Impostors

#### Step 3.1: Integrate Impostor Plugin
**Plugin:** [godot-imposter](https://github.com/zhangjt93/godot-imposter)

**Installation:**
1. Add as git submodule: `addons/godot-imposter/`
2. Enable in project settings
3. Test impostor generation in editor

#### Step 3.2: Curate Impostor Candidate List
**New File:** `src/core/world/impostor_candidates.gd`

**Contents:**
```gdscript
class_name ImpostorCandidates extends RefCounted

# Objects that should have impostors
const LANDMARKS = [
    "meshes/x/ex_vivec_canton_00.nif",     # Vivec cantons
    "meshes/x/ex_stronghold_01.nif",       # Strongholds
    "meshes/x/ex_dwrv_ruin_01.nif",        # Dwemer ruins
    "meshes/f/flora_tree_02.nif",          # Large trees
    # ... 50-100 important objects
]

const IMPOSTOR_SETTINGS = {
    "texture_size": 1024,        # Resolution per impostor
    "frames": 16,                # Viewing angles (hemisphere)
    "use_alpha": true,
    "optimize_size": true,
}

func should_have_impostor(model_path: String) -> bool
```

**Criteria for impostors:**
- Visible from >1km
- Distinctive silhouette
- Static (no animation)
- Important landmark or common object
- Not too small (<5m in any dimension)

#### Step 3.3: Impostor Baker Tool
**New File:** `src/tools/impostor_baker.gd` (editor script)

**Purpose:**
- Batch-process all impostor candidates
- Generate octahedral impostor textures
- Save to `res://assets/impostors/`
- Create impostor metadata (size, bounds)

**Usage:**
```gdscript
# Run in editor via Tools menu
ImpostorBaker.bake_all_candidates()
# Generates: assets/impostors/[model_hash]_impostor.png + .json
```

#### Step 3.4: ImpostorManager
**New File:** `src/core/world/impostor_manager.gd`

**Responsibilities:**
- Loads pre-baked impostor textures
- Spawns impostor quads for far cells
- Manages impostor visibility based on distance
- Handles impostor→mesh transition when player approaches

**API:**
```gdscript
class_name ImpostorManager extends Node

func add_impostor(
    model_path: String,
    position: Vector3,
    rotation: Vector3,
    scale: Vector3
) -> void

func remove_impostors_for_cell(cell_grid: Vector2i) -> void
func update_impostor_visibility(camera_pos: Vector3) -> void
```

**Rendering:**
- Uses Sprite3D with octahedral shader (from plugin)
- Batched into atlas for draw call reduction
- Fades in/out at transition distances

### Phase 4: Horizon System (Week 4-5) - Skybox Integration

#### Step 4.1: Distant Layer Generator
**New File:** `src/tools/horizon_layer_baker.gd`

**Purpose:**
- Renders panoramic view from specific locations
- Extracts distant objects (>5km) as silhouettes
- Generates skybox layers for Sky3D

**Process:**
1. Position camera at location (e.g., Balmora center)
2. Render 360° panorama at far distance
3. Mask out near/mid/far objects
4. Extract horizon silhouette
5. Save as skybox texture layer

#### Step 4.2: Extend Sky3D Integration
**File:** `addons/sky_3d/` (extend existing)

**Changes:**
- Add location-based horizon layers
- Parallax shift based on camera position
- Blend with atmospheric scattering

**Configuration:**
```gdscript
# Example for Morrowind
"seyda_neen": {
    "horizon_layer": "res://assets/horizons/seyda_neen_horizon.png",
    "center": Vector2(2, -9),     # Cell grid center
    "blend_distance": 10000.0,    # 10km blend radius
}
```

### Phase 5: Integration & Optimization (Week 5-6)

#### Step 5.1: Unified Streaming Coordinator
**File:** `src/core/world/world_streaming_manager.gd` (extend)

**New logic:**
```gdscript
func _process_cell_loading(delta: float) -> void:
    var camera_pos = _get_camera_position()
    var camera_cell = godot_pos_to_cell_grid(camera_pos)

    var cells_by_tier = _get_visible_cells_tiered(camera_cell)

    for cell_pos in cells_by_tier.keys():
        var tier = cells_by_tier[cell_pos]

        match tier:
            DistanceTierManager.Tier.NEAR:
                # Existing system
                _request_full_cell_load(cell_pos)

            DistanceTierManager.Tier.MID:
                # New: Merged mesh system
                _request_merged_cell_load(cell_pos)

            DistanceTierManager.Tier.FAR:
                # New: Impostor system
                _request_impostor_load(cell_pos)

            DistanceTierManager.Tier.HORIZON:
                # New: Skybox layer (already loaded)
                pass
```

#### Step 5.2: Transition Management
**New File:** `src/core/world/lod_transition_manager.gd`

**Purpose:**
- Smooth transitions between tiers
- Prevents double-rendering (impostor + mesh visible simultaneously)
- Manages fade-in/fade-out

**Logic:**
```gdscript
func update_transitions(camera_pos: Vector3) -> void:
    for cell in _all_loaded_cells:
        var distance = _calculate_distance(camera_pos, cell)
        var current_tier = _get_tier_for_distance(distance)
        var loaded_tier = _cells[cell].tier

        if current_tier != loaded_tier:
            _handle_tier_change(cell, loaded_tier, current_tier)

func _handle_tier_change(cell: Vector2i, from: Tier, to: Tier) -> void:
    # Example: FAR→MID (player approaching)
    if from == Tier.FAR and to == Tier.MID:
        _fade_out_impostor(cell)
        _fade_in_merged_mesh(cell)

    # Example: MID→NEAR (player very close)
    if from == Tier.MID and to == Tier.NEAR:
        _fade_out_merged_mesh(cell)
        _load_full_cell(cell)
```

#### Step 5.3: Performance Budgeting
**File:** `src/core/world/world_streaming_manager.gd`

**Updated budgets:**
```gdscript
# Existing
@export var cell_load_budget_ms: float = 2.0        # Near cells

# New
@export var merged_load_budget_ms: float = 1.0      # Mid cells
@export var impostor_spawn_budget_ms: float = 0.5   # Far cells

# Priorities (higher = sooner)
const PRIORITY_NEAR = 100
const PRIORITY_MID = 50
const PRIORITY_FAR = 25
const PRIORITY_HORIZON = 0
```

### Phase 6: Scene-Agnostic Design (Week 6)

#### Step 6.1: WorldDataProvider Extensions
**File:** `src/core/world/world_data_provider.gd` (extend interface)

**New methods:**
```gdscript
class_name WorldDataProvider extends RefCounted

# Existing methods
func get_world_name() -> String
func get_land_func() -> Callable
func get_cell_grid_at_position(pos: Vector3) -> Vector2i

# NEW: Distant rendering support
func get_impostor_candidates() -> Array[String]:
    # Return list of objects important for this world
    return []

func get_horizon_layer_path() -> String:
    # Return skybox horizon texture path
    return ""

func get_max_view_distance() -> float:
    # World-specific max distance (Morrowind: 5km, La Palma: 10km)
    return 5000.0

func supports_distant_rendering() -> bool:
    # Can this world use impostor system?
    return true
```

#### Step 6.2: Morrowind Implementation
**File:** `src/core/world/morrowind_data_provider.gd` (extend)

```gdscript
func get_impostor_candidates() -> Array[String]:
    return ImpostorCandidates.LANDMARKS  # From Step 3.2

func get_horizon_layer_path() -> String:
    return "res://assets/horizons/vvardenfell_horizon.png"

func get_max_view_distance() -> float:
    return 5000.0  # 5km view distance

func supports_distant_rendering() -> bool:
    return true
```

#### Step 6.3: La Palma Implementation
**File:** `src/core/world/lapalma_data_provider.gd` (extend)

```gdscript
func get_impostor_candidates() -> Array[String]:
    # Real-world locations: Buildings, lighthouses, observatories
    return [
        "models/observatory_roque.glb",
        "models/lighthouse_fuencaliente.glb",
        # ... buildings from OSM data
    ]

func get_horizon_layer_path() -> String:
    return "res://assets/horizons/la_palma_ocean_horizon.png"

func get_max_view_distance() -> float:
    return 10000.0  # 10km (island is small, ocean visible far)

func supports_distant_rendering() -> bool:
    return true
```

---

## Configuration & Tuning

### Distance Thresholds

**Default Configuration:**
```gdscript
# src/core/world/distance_tier_manager.gd

const TIER_DISTANCES = {
    Tier.NEAR: 0.0,          # 0m - 500m (0-4 cells)
    Tier.MID: 500.0,         # 500m - 2km (4-17 cells)
    Tier.FAR: 2000.0,        # 2km - 5km (17-43 cells)
    Tier.HORIZON: 5000.0,    # 5km+ (skybox)
}

const TRANSITION_MARGINS = {
    # Hysteresis to prevent flickering
    Tier.NEAR: 50.0,         # ±50m transition zone
    Tier.MID: 100.0,         # ±100m transition zone
    Tier.FAR: 200.0,         # ±200m transition zone
}
```

**Per-World Overrides:**
```gdscript
# Morrowind: Shorter view distance (foggy world)
MorrowindDataProvider.TIER_DISTANCES = {
    Tier.FAR: 3000.0,    # 3km instead of 5km
}

# La Palma: Longer view distance (clear island)
LaPalmaDataProvider.TIER_DISTANCES = {
    Tier.FAR: 7000.0,    # 7km instead of 5km
}
```

### Performance Budgets

**Target: 60 FPS on mid-range hardware**

```gdscript
# Time budgets per frame (milliseconds)
const BUDGETS = {
    "near_cell_load": 2.0,        # Full geometry loading
    "mid_mesh_merge": 1.0,         # Merge static meshes
    "far_impostor_spawn": 0.5,     # Spawn impostor quads
    "transition_fade": 0.3,        # Cross-fade effects
}

# Object limits
const LIMITS = {
    "max_near_cells": 12,          # ~1.4km radius
    "max_mid_cells": 60,           # ~2.5km radius
    "max_far_cells": 200,          # ~5km radius
    "max_impostors_visible": 500,  # Total impostor quads
    "max_merged_chunks": 60,       # Merged mesh instances
}
```

### Quality Presets

**User-facing settings:**
```gdscript
enum ViewDistanceQuality { LOW, MEDIUM, HIGH, ULTRA }

const QUALITY_PRESETS = {
    ViewDistanceQuality.LOW: {
        "near_distance": 350.0,   # 3 cells
        "mid_distance": 1000.0,   # ~9 cells
        "far_distance": 0.0,      # Disabled
        "impostors": false,
    },

    ViewDistanceQuality.MEDIUM: {
        "near_distance": 500.0,   # 4 cells
        "mid_distance": 1500.0,   # ~13 cells
        "far_distance": 3000.0,   # ~26 cells
        "impostors": true,
    },

    ViewDistanceQuality.HIGH: {
        "near_distance": 700.0,   # 6 cells
        "mid_distance": 2000.0,   # 17 cells
        "far_distance": 5000.0,   # 43 cells
        "impostors": true,
    },

    ViewDistanceQuality.ULTRA: {
        "near_distance": 1000.0,  # 9 cells
        "mid_distance": 3000.0,   # 26 cells
        "far_distance": 10000.0,  # 85 cells
        "impostors": true,
    },
}
```

---

## File Structure

### New Files
```
src/core/world/
├── distance_tier_manager.gd          # Determines tier for cells
├── distant_static_renderer.gd        # Mid-distance merged meshes
├── impostor_manager.gd                # Far-distance impostors
├── impostor_candidates.gd             # Curated impostor list
├── lod_transition_manager.gd          # Smooth tier transitions

src/tools/
├── impostor_baker.gd                  # Batch impostor generation
├── horizon_layer_baker.gd             # Skybox horizon generator

assets/
├── impostors/                         # Pre-baked impostor textures
│   ├── [model_hash]_impostor.png
│   └── [model_hash]_impostor.json
├── horizons/                          # Skybox horizon layers
│   ├── vvardenfell_horizon.png
│   └── la_palma_ocean_horizon.png

docs/
├── DISTANT_RENDERING_PLAN.md          # This document
└── DISTANT_RENDERING_GUIDE.md         # User guide (to be created)
```

### Modified Files
```
src/core/world/
├── world_streaming_manager.gd         # Extended distance tiers
├── world_data_provider.gd             # New interface methods
├── morrowind_data_provider.gd         # Impostor candidates
├── lapalma_data_provider.gd           # Impostor candidates

src/core/nif/
├── mesh_simplifier.gd                 # Aggressive simplification mode
```

---

## Testing Strategy

### Phase-by-Phase Testing

**Phase 1 Test: Extended Loading**
- Load 43 cells (5km) without rendering
- Verify memory usage stable (<2GB)
- Confirm no frame drops during streaming

**Phase 2 Test: Merged Meshes**
- Test in Balmora (many buildings)
- Verify single draw call per merged chunk
- Measure FPS improvement (target: 2×)
- Check visual quality from 500m-2km

**Phase 3 Test: Impostors**
- Test Vivec canton from 3km
- Verify impostor visibility
- Test rotation (16 viewing angles)
- Measure performance (target: <0.5ms overhead)

**Phase 4 Test: Horizon**
- Test Red Mountain visibility from Seyda Neen (8km)
- Verify parallax scrolling
- Check blend with sky

**Phase 5 Test: Transitions**
- Walk from 5km → 0km toward landmark
- Verify smooth transitions (no pop-in)
- Confirm only one representation visible at a time

**Phase 6 Test: Multi-World**
- Test in Morrowind (3km view)
- Test in La Palma (10km view)
- Verify per-world configuration works

### Benchmark Locations

**Morrowind:**
1. **Seyda Neen → Red Mountain** (8km) - Long-distance visibility
2. **Balmora city center** - Dense static merging
3. **Vivec cantons** - Impostor landmark test
4. **Bitter Coast** - Flora + structures
5. **Ashlands** - Large rock formations

**La Palma:**
1. **Observatory viewpoint** - 10km ocean view
2. **Coastal town** - Building impostors
3. **Mountain peak** - Island-wide visibility

### Performance Targets

| Scenario | Current FPS | Target FPS | Max View Distance |
|----------|-------------|------------|-------------------|
| Seyda Neen (clear view) | 60 | 60 | 8km (Red Mountain visible) |
| Balmora (merged city) | 60 | 60 | 2km (merged meshes) |
| Vivec (impostor test) | 60 | 60 | 5km (cantons as impostors) |
| La Palma observatory | 60 | 60 | 10km (ocean + island) |

### Quality Checks

**Visual Quality Criteria:**
1. **No pop-in artifacts**: Smooth transitions between tiers
2. **Recognizable landmarks**: Red Mountain, Vivec visible from distance
3. **Plausible silhouettes**: Merged meshes look like buildings (not blobs)
4. **Impostor believability**: Rotation tracking looks natural
5. **Horizon integration**: Skybox blends seamlessly

**Performance Criteria:**
1. **60 FPS maintained**: All quality presets at target
2. **Memory stable**: <3GB total (was <2GB before)
3. **No stuttering**: Transitions happen smoothly
4. **Quick cell loads**: Still within 2ms/frame budget

---

## Risks & Mitigation

### Technical Risks

**Risk 1: Performance Regression**
- **Probability:** Medium
- **Impact:** High
- **Mitigation:**
  - Implement feature flags to disable systems
  - Add per-tier performance budgets
  - Profile each phase before moving forward
  - Keep existing LOD system as fallback

**Risk 2: Impostor Visual Quality**
- **Probability:** Medium
- **Impact:** Medium
- **Mitigation:**
  - Curate only important landmarks (50-100 objects max)
  - High-resolution impostor textures (1024px+)
  - Test from multiple distances
  - Fallback to simplified mesh if impostor fails

**Risk 3: Memory Exhaustion**
- **Probability:** Low
- **Impact:** High
- **Mitigation:**
  - Strict cell limits per tier
  - Aggressive unloading of distant tiers
  - Texture compression for impostors
  - Monitor memory in profiler

**Risk 4: Transition Artifacts**
- **Probability:** High
- **Impact:** Medium
- **Mitigation:**
  - Generous transition margins (50m-200m)
  - Cross-fade shaders
  - User-tunable thresholds
  - Disable transitions in performance mode

### Project Risks

**Risk 1: Scope Creep**
- **Mitigation:** Implement in phases, test each phase independently

**Risk 2: Plugin Compatibility**
- **Mitigation:** Test godot-imposter plugin early, have fallback plan

**Risk 3: Time Overrun**
- **Mitigation:** Phases 1-3 are must-have, Phases 4-6 are nice-to-have

---

## Success Criteria

### Must-Have (Phases 1-3)
- ✅ View distance extended to 2-3km (current: 351m)
- ✅ Mid-distance merged meshes working (500m-2km)
- ✅ Impostors for major landmarks (2km-5km)
- ✅ No pop-in artifacts with proper transitions
- ✅ 60 FPS maintained on mid-range hardware
- ✅ Works for Morrowind scene

### Should-Have (Phases 4-5)
- ✅ Horizon skybox integration (5km+)
- ✅ Smooth tier transitions with fading
- ✅ Performance budgets respected
- ✅ Quality presets (Low/Med/High/Ultra)

### Nice-to-Have (Phase 6)
- ✅ Works for La Palma scene
- ✅ Scene-agnostic architecture
- ✅ User tools for adding custom impostors
- ✅ Editor integration for testing

---

## Future Enhancements

### Beyond Initial Implementation

**1. Dynamic Impostor Generation**
- Runtime impostor baking (not just offline)
- Cache generated impostors for modded content
- Automatic impostor for any object >20m tall

**2. Temporal Coherence**
- Track player movement patterns
- Predictive loading based on velocity
- Preload likely destination cells

**3. Weather Integration**
- Fog reduces view distance dynamically
- Impostors fade in fog
- Horizon visibility based on weather

**4. Night/Day Transitions**
- Different impostor textures for day/night
- Emissive impostors for lit buildings
- Stars replace distant land at night

**5. VR Optimization**
- Stereoscopic impostor rendering
- Higher LOD thresholds (VR = closer inspection)
- Performance budget adjustments

---

## References

### Research Sources

**OpenMW:**
- [Distant Terrain Blog Post](https://openmw.org/2017/distant-terrain/)
- [Object Paging Issue #2386](https://gitlab.com/OpenMW/openmw/-/issues/2386)
- [Object Paging Merge Request](https://gitlab.com/OpenMW/openmw/-/merge_requests/209)
- [LOD Support Merge Request](https://gitlab.com/OpenMW/openmw/-/merge_requests/2439)

**Godot Plugins:**
- [godot-imposter (Godot 4.x)](https://github.com/zhangjt93/godot-imposter)
- [Godot-Octahedral-Impostors](https://github.com/wojtekpil/Godot-Octahedral-Impostors)

**Industry Techniques:**
- [Frozen Fractal: Impostor Rendering (2025)](https://frozenfractal.com/blog/2025/12/12/around-the-world-28-scaling-up/)
- [Grass LOD Tricks (Godot)](https://hexaquo.at/pages/grass-rendering-series-part-4-level-of-detail-tricks-for-infinite-plains-of-grass-in-godot/)

### Internal Documentation
- `docs/ARCHITECTURE_AUDIT.md` - Current system analysis
- `docs/STREAMING.md` - Streaming architecture
- `docs/PERFORMANCE_OPTIMIZATION_ROADMAP.md` - Existing optimizations
- `src/core/nif/nif_converter.gd` - LOD system implementation
- `src/core/world/world_streaming_manager.gd` - Cell loading

---

## Timeline Estimate

### Conservative Estimate (6 weeks)

| Phase | Duration | Dependencies |
|-------|----------|-------------|
| Phase 1: Foundation | 1-2 weeks | None |
| Phase 2: Mid-Distance | 1 week | Phase 1 |
| Phase 3: Impostors | 1-2 weeks | Phase 1 |
| Phase 4: Horizon | 3-5 days | Phase 1 |
| Phase 5: Integration | 1 week | Phases 1-4 |
| Phase 6: Multi-World | 3-5 days | Phase 5 |

**Total:** 6 weeks (can be parallelized: Phases 2-4 can overlap)

### Aggressive Estimate (3-4 weeks)

- Week 1: Phases 1-2 (foundation + merged meshes)
- Week 2: Phase 3 (impostors)
- Week 3: Phases 4-5 (horizon + integration)
- Week 4: Phase 6 + polish (multi-world)

---

## Next Steps

### Immediate Actions

1. **Review this plan** - Confirm architecture approach
2. **Test impostor plugin** - Verify godot-imposter works in project
3. **Create feature branch** - `feature/distant-rendering`
4. **Implement Phase 1** - Extend streaming distance
5. **Benchmark baseline** - Record current performance before changes

### Questions to Resolve

1. **View distance target**: 5km sufficient, or push to 10km?
2. **Quality presets**: Should default be Medium or High?
3. **Impostor count**: 50-100 landmarks reasonable, or more?
4. **La Palma priority**: Implement multi-world from start, or later?
5. **Editor tools**: How important is impostor baker UI vs command-line?

---

**Plan Complete - Ready for Implementation** ✅

---

**Document Version:** 1.0
**Author:** Claude AI
**Last Updated:** 2025-12-18
**Status:** Ready for Review
