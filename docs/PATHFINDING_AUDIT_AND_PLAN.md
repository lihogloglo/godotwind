# Pathfinding & Navigation Mesh System - Audit and Implementation Plan

**Date:** 2025-12-21
**Status:** Design Phase
**Branch:** `claude/pathfinding-audit-plan-p8b5A`

---

## Executive Summary

This document provides a comprehensive audit of the current pathfinding implementation, research into best practices from OpenMW and Godot ecosystem, and a detailed implementation plan for a production-ready navigation system for the Morrowind port.

**Key Findings:**
- ✅ Basic NavigationAgent3D pathfinding is implemented and functional
- ✅ Runtime navmesh baking exists but needs optimization for large worlds
- ❌ Morrowind PathGrid data is loaded but not integrated
- ❌ No per-cell navmesh prebaking pipeline exists yet
- ⚠️ Performance concerns for large-scale world with current runtime-only approach

**Recommended Approach:** Hybrid system combining prebaked per-cell navmeshes (OpenMW-style) with selective runtime baking for dynamic content.

---

## 1. Current Codebase Audit

### 1.1 Implemented Components

#### ✅ CharacterMovementController (`src/core/character/character_movement_controller.gd`)
**Status:** Fully functional, Phase 1 complete

**Features:**
- NavigationAgent3D integration for pathfinding
- NavMesh-based path following with periodic updates (0.5s intervals)
- Direct movement targeting (`move_to` method)
- Wander behavior with random patrol points
- Slope adaptation with body tilt and speed modification
- IK integration for terrain-aware movement

**Key Methods:**
- `navigate_to(target)` - NavMesh-based navigation
- `_update_navmesh_pathfinding()` - Updates navigation path periodically
- `_calculate_navmesh_movement()` - Calculates velocity from path

**Reference:** `src/core/character/character_movement_controller.gd:1-500`

#### ✅ RuntimeNavigationBaker (`addons/demo/src/RuntimeNavigationBaker.gd`)
**Status:** Functional but performance-limited

**Features:**
- Creates NavigationRegion3D with streaming NavMesh updates
- Uses WorkerThreadPool for async baking (non-blocking)
- Terrain3D integration for generating nav mesh geometry
- Configurable mesh size (default 256×512×256)
- Bake distance threshold (64m) with cooldown (1.0s)

**Limitations:**
- Only suitable for small-medium areas around player
- Cannot handle full Morrowind world (perf/memory constraints)
- No persistent cache - rebakes on every session

**Reference:** `addons/demo/src/RuntimeNavigationBaker.gd:1-200`

#### ✅ Enemy AI with Navigation (`addons/demo/src/Enemy.gd`)
**Status:** Demo implementation, needs production enhancement

**Features:**
- NavigationAgent3D pathfinding toward player
- Detection range (10m) with line-of-sight raycast
- Patrol behavior with random waypoints (5m radius)
- Chase behavior when player detected
- Attack range detection and melee combat

**Gaps:**
- No behavior tree integration (Beehave addon installed but not wired)
- Simple state machine, needs more complex AI
- No interior navigation support

**Reference:** `addons/demo/src/Enemy.gd:1-300`

### 1.2 Data Loading (Not Integrated)

#### ⚠️ PathgridRecord (`src/core/esm/records/pathgrid_record.gd`)
**Status:** Data loaded, not used at runtime

**Contains:**
- Path points with X, Y, Z coordinates from Morrowind ESM
- Connections between points (edges)
- Cell grid information (interior/exterior)
- Point metadata (auto_generated, connection_count)

**Opportunity:** Could be converted to Godot NavigationMesh or used as seed data for navmesh baking

**Reference:** `src/core/esm/records/pathgrid_record.gd:1-100`

#### ⚠️ NPCRecord AI Data (`src/core/esm/records/npc_record.gd`)
**Status:** Data loaded, not integrated with behavior

**Contains:**
- AI parameters (fight, flee, alarm probabilities)
- Travel destinations for NPCs
- Services and dialogue data

**Opportunity:** Use for behavior tree configuration

**Reference:** `src/core/esm/records/npc_record.gd:1-200`

### 1.3 Preprocessing Infrastructure

#### 🔧 MorrowindPreprocessor (`src/tools/morrowind_preprocessor.gd`)
**Status:** Framework exists, navmesh step marked "Future"

**Current Steps:**
1. IMPOSTORS - ✅ Implemented
2. MERGED_MESHES - ✅ Implemented
3. TEXTURE_ATLASES - 🔜 Future
4. NAVMESHES - 🔜 **Future (this is what we need!)**

**Note:** Infrastructure exists for offline navmesh baking, just needs implementation

**Reference:** `src/tools/morrowind_preprocessor.gd:1-500`

---

## 2. OpenMW's Approach - Research Findings

### 2.1 Recastnavigation Library

OpenMW uses the industry-standard [Recastnavigation](https://github.com/recastnavigation/recastnavigation) library for pathfinding.

**Architecture:**
- Tile-based navmesh generation (allows streaming and caching)
- SQLite database for persistent tile cache
- Parallel generation using all CPU cores
- Handles ACTI, CELL, CONT, DOOR, STAT ESM records

### 2.2 Navmeshtool - Prebaking Pipeline

**Tool:** `openmw-navmeshtool` (command-line binary)

**Features:**
- Processes all content listed in openmw.cfg (mods included)
- Generates navmesh database (~435 MiB for full Morrowind + mods)
- Parallel processing with all CPUs (or configurable thread count)
- Optional interior cell processing: `--process-interior-cells 1`

**Database Structure:**
- **shapes table:** All collision meshes used
- **tiles table:** Navmesh tile data (serialized PreparedNavMeshData)

**Tile Key Composition:**
- Worldspace identifier
- Tile coordinate (X, Y)
- Binary structure containing:
  - Recast scale factor
  - rcConfig parameters
  - RecastMesh geometry

### 2.3 Tile System Architecture

**Limitations (Recastnavigation):**
- Max tiles × max polygons per tile ≤ 4,194,304
- Polygon identifier: 22 bits total (10 bits tile, 12 bits polygon)

**Runtime Behavior:**
- Memory cache for active tiles
- Disk cache fallback for inactive tiles
- Dynamic loading as actors move through world
- Off-mesh connections for doors/pathgrids

**Sources:**
- [Navigator Settings | OpenMW](https://openmw.readthedocs.io/en/latest/reference/modding/settings/navigator.html)
- [Navmesh disk cache merge request](https://gitlab.com/OpenMW/openmw/-/merge_requests/1058)
- [Generate A Navmesh Cache Guide](https://modding-openmw.com/mods/generate-a-navmesh-cache/)
- [Tips: Navmeshtool](https://modding-openmw.com/tips/navmeshtool/)
- [Use recastnavigation PR](https://github.com/OpenMW/openmw/pull/1633)

---

## 3. Godot Navigation - Best Practices

### 3.1 Core Principle: Chunking is Mandatory

**The "Single Big Soap" Anti-Pattern:**
> "Common among all Godot projects with navmesh performance issues is that they use navmesh in a way called 'the single big soap' option - essentially trying to use one massive navmesh instead of breaking it into chunks."

**Best Practice:**
- Use partitioned game world with reasonably sized chunks
- Only load/query chunks where they matter (near player/active NPCs)
- Trying to load full large world navmesh is "almost impossible due to sheer memory and performance requirements"

**Source:** [Optimizing Navigation Performance - Godot Docs](https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_optimizing_performance.html)

### 3.2 NavigationServer API (Godot 4.0+)

**Modern Approach:**
- Use NavigationServer3D directly instead of NavigationMeshGenerator (deprecated)
- Supports async baking with `bake_from_source_geometry_data_async()`
- Can parse geometry once, bake multiple times
- Thread-safe, non-blocking

**Workflow:**
1. `parse_source_geometry_data()` - Parse geometry to reusable resource
2. `bake_from_source_geometry_data()` - Bake navmesh from parsed data
3. `bake_from_source_geometry_data_async()` - Async version (preferred)

**Sources:**
- [Navigation Server for Godot 4.0](https://godotengine.org/article/navigation-server-godot-4-0/)
- [Using navigation meshes - Godot Docs](https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_using_navigationmeshes.html)
- [NavigationMeshGenerator Class](https://docs.godotengine.org/en/stable/classes/class_navigationmeshgenerator.html)

### 3.3 Prebaking Options

#### Editor Baking (Design Time)
- Use NavigationRegion3D in editor
- Bake navmesh, save as .tres resource
- Fast loading, no runtime overhead
- **Best for static geometry**

#### Headless Baking (Build Time)
- Run Godot editor in headless mode with tool scripts
- `godot.exe --editor --headless res://SomeScene.tscn`
- Automate navmesh baking in preprocessing pipeline
- **Perfect for per-cell prebaking**

#### Runtime Baking
- Call `bake_navigation_mesh()` on NavigationRegion3D
- Use async API to avoid blocking
- Slow (especially on large areas)
- **Only for dynamic/procedural content**

**Sources:**
- [Headless NavigationMesh baking discussion](https://godotforums.org/discussion/23047/how-to-use-the-godot-headless-version-to-bake-navigationmeshinstance)
- [Runtime baking discussion](https://forum.godotengine.org/t/bake-navmesh-during-runtime/22181)

### 3.4 Large World Streaming

**Community Solutions:**

**Chunx Plugin:**
- Godot 4 plugin for open world streaming
- Streams objects in/out as player moves
- Keeps overhead minimal
- [GitHub: SlashScreen/chunx](https://github.com/SlashScreen/chunx)

**Official Proposal (In Progress):**
- Godot working on automated navmesh chunking system
- Multiple new node classes for chunk management
- NavigationWorld2D/3D for high-performance large worlds
- [GitHub Proposal #12707](https://github.com/godotengine/godot-proposals/issues/12707)

### 3.5 Performance Considerations

**Critical Points:**
- MeshInstance3D unusable for runtime baking (GPU data stalls rendering)
- TileMap unusable after certain size (queries iterate all cells)
- Navigation baking is "slow" - editor/compile-time preferred
- Async baking essential for non-blocking experience

**Source:** [Optimizing Navigation Performance](https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_optimizing_performance.html)

---

## 4. AI Behavior Tree Plugins

### 4.1 Beehave (Already Installed)
**Status:** ✅ Addon installed, ❌ Not wired to NPC system

**Features:**
- Visual behavior tree editor using Godot nodes
- Designed for NPC AI and boss battles
- GDScript implementation (easy to extend)
- Supports Godot 3.x and 4.x

**Links:**
- [Godot Asset Library](https://godotengine.org/asset-library/asset/1349)
- [GitHub: bitbrain/beehave](https://github.com/bitbrain/beehave)
- [GameFromScratch Overview](https://gamefromscratch.com/beehave-behavior-trees-for-godot/)

### 4.2 Alternative: LimboAI
**Features:**
- C++ plugin (better performance)
- Combines Behavior Trees AND State Machines
- Can nest trees inside state machines
- More complex but more powerful

**Links:**
- [GitHub: limbonaut/limboai](https://github.com/limbonaut/limboai)

### 4.3 Recommendation
**Use Beehave** - Already installed, GDScript-based (easier maintenance), sufficient for Morrowind-style AI

---

## 5. Performance & Maintenance Analysis

### 5.1 Morrowind World Scale

**Challenges:**
- **~300 exterior cells** in base Morrowind
- **~400+ interior cells**
- Mods can add hundreds more
- Total world space: massive (9km × 6km base game)

**Implication:** Runtime-only navmesh baking is NOT viable for full world

### 5.2 Memory Budget

**OpenMW Reference:**
- Full navmesh database: ~435 MiB (for all content + mods)
- Compressed, serialized tile format
- Only active tiles in memory (~10-50 MiB typical)

**Godot Equivalent:**
- Per-cell navmesh resources (~1-5 MiB each uncompressed)
- Need streaming system to load/unload
- Estimated total: 500-1000 MiB for full prebaked navmeshes

### 5.3 Baking Time

**Runtime Baking (Current):**
- ~1-2 seconds per cell (async, threaded)
- Causes hitches even with async (memory allocation, GC)
- 300 cells × 2s = **10 minutes** to bake world (unacceptable)

**Prebaking (Proposed):**
- Offline preprocessing: ~30-60 minutes for full world (one-time)
- Fast loading at runtime (~10-50ms per cell)
- No runtime hitches
- Can be parallelized across all CPU cores

### 5.4 Maintenance Considerations

**Prebaking Pros:**
- ✅ Predictable performance (no runtime surprises)
- ✅ Faster loading (pre-optimized data)
- ✅ Better debugging (can inspect baked meshes)
- ✅ Modding-friendly (prebake once per mod load order)

**Prebaking Cons:**
- ❌ Requires preprocessing step (adds to build pipeline)
- ❌ Increases storage requirements (~500MB-1GB)
- ❌ Need to rebake when content changes (acceptable for Morrowind port)

**Hybrid Approach:**
- Prebake static world geometry (cells, buildings, terrain)
- Runtime bake for dynamic/scripted content (spawned objects, moving platforms)
- Best of both worlds

---

## 6. Implementation Plan

### Phase 1: Per-Cell Navmesh Prebaking Pipeline ⭐ **PRIORITY**

**Goal:** Implement offline navmesh baking similar to OpenMW's approach

**Tasks:**

#### 1.1 Extend MorrowindPreprocessor
**File:** `src/tools/morrowind_preprocessor.gd`

**Implementation:**
```gdscript
func _bake_navmeshes():
    print("=== STEP 4: NAVMESHES ===")

    # For each cell in ESM data
    for cell_id in cell_registry.get_all_cells():
        var cell = cell_registry.get_cell(cell_id)

        # Create NavigationMesh resource
        var nav_mesh = NavigationMesh.new()
        _configure_navmesh_parameters(nav_mesh)

        # Parse cell geometry
        var source_geometry = NavigationMeshSourceGeometryData3D.new()
        _parse_cell_geometry(cell, source_geometry)

        # Bake using NavigationServer
        NavigationServer3D.bake_from_source_geometry_data(nav_mesh, source_geometry)

        # Save to disk
        var output_path = "res://data/navmeshes/%s.tres" % cell_id
        ResourceSaver.save(nav_mesh, output_path)

    print("Baked %d navmeshes" % cell_registry.get_all_cells().size())
```

**Key Points:**
- Use NavigationServer3D API (not deprecated NavigationMeshGenerator)
- Process cells in parallel using WorkerThreadPool
- Save as .tres binary resources (fast loading)
- Organize by cell ID for easy lookup

**Estimated Effort:** 3-5 days

#### 1.2 Configure Navmesh Parameters
**File:** `src/core/navigation/navmesh_config.gd` (new)

**Parameters to tune:**
```gdscript
class NavMeshConfig:
    # Agent properties
    const AGENT_RADIUS = 0.6  # NPC radius
    const AGENT_HEIGHT = 2.0  # NPC height
    const AGENT_MAX_CLIMB = 0.5  # Max step height
    const AGENT_MAX_SLOPE = 45.0  # Max walkable slope (degrees)

    # Cell properties
    const CELL_SIZE = 0.3  # Rasterization cell size (smaller = more detailed)
    const CELL_HEIGHT = 0.2  # Vertical cell size

    # Region properties
    const REGION_MIN_SIZE = 8  # Min region size (square cells)
    const REGION_MERGE_SIZE = 20  # Merge nearby regions

    # Polygon detail
    const DETAIL_SAMPLE_DIST = 6.0
    const DETAIL_SAMPLE_MAX_ERROR = 1.0

    # Edge properties
    const EDGE_MAX_LENGTH = 12.0  # Max edge length
    const EDGE_MAX_ERROR = 1.3
```

**Reference:** Match OpenMW's rcConfig parameters for consistency

**Estimated Effort:** 1 day (tuning may take longer)

#### 1.3 Cell Geometry Parser
**File:** `src/core/navigation/cell_geometry_parser.gd` (new)

**Responsibilities:**
- Extract all collision geometry from cell:
  - Static objects (STAT records)
  - Containers (CONT)
  - Doors (DOOR)
  - Activators (ACTI)
  - Terrain (LAND)
- Convert Morrowind meshes to Godot geometry
- Apply transformations (position, rotation, scale)
- Filter out non-walkable surfaces (water, lava)

**Integration Points:**
- Reuse existing NIFLoader for mesh data
- Use LAND record for terrain heightmap
- Respect object flags (not walkable, etc.)

**Estimated Effort:** 5-7 days

#### 1.4 Headless Baking Tool
**File:** `src/tools/bake_navmeshes.gd` (new)

**Purpose:** Command-line tool for CI/CD and mod management

**Usage:**
```bash
godot --headless --script res://src/tools/bake_navmeshes.gd -- --cells all
godot --headless --script res://src/tools/bake_navmeshes.gd -- --cells "Balmora,-2,-3"
godot --headless --script res://src/tools/bake_navmeshes.gd -- --interior-only
```

**Features:**
- Progress reporting
- Error handling (skip invalid cells)
- Parallelization (use all CPU cores)
- Statistics (time, file sizes, polygon counts)

**Estimated Effort:** 2-3 days

**Phase 1 Total Estimate:** 2-3 weeks

---

### Phase 2: Runtime Navmesh Loading & Streaming

**Goal:** Load prebaked navmeshes dynamically as cells stream in

**Tasks:**

#### 2.1 NavMeshManager Singleton
**File:** `src/core/navigation/navmesh_manager.gd` (new)

**Responsibilities:**
- Load navmesh resources for active cells
- Unload navmeshes when cells stream out
- Manage NavigationRegion3D instances
- Cache navmeshes in memory (LRU cache)

**Architecture:**
```gdscript
class NavMeshManager extends Node:
    var _loaded_navmeshes: Dictionary = {}  # cell_id -> NavigationRegion3D
    var _navmesh_cache: Dictionary = {}  # cell_id -> NavigationMesh (resource)
    const MAX_CACHE_SIZE = 50  # Keep 50 navmeshes in memory

    func load_cell_navmesh(cell_id: String, position: Vector3):
        if _loaded_navmeshes.has(cell_id):
            return  # Already loaded

        # Load resource (from cache or disk)
        var nav_mesh = _get_cached_navmesh(cell_id)

        # Create NavigationRegion3D
        var region = NavigationRegion3D.new()
        region.navigation_mesh = nav_mesh
        region.position = position
        add_child(region)

        _loaded_navmeshes[cell_id] = region

    func unload_cell_navmesh(cell_id: String):
        if not _loaded_navmeshes.has(cell_id):
            return

        var region = _loaded_navmeshes[cell_id]
        region.queue_free()
        _loaded_navmeshes.erase(cell_id)
```

**Integration:** Hook into existing cell streaming system

**Estimated Effort:** 3-4 days

#### 2.2 Connect to Cell Streaming
**Files to modify:**
- `src/core/world/cell_manager.gd` (or equivalent)

**Changes:**
- When cell loads, call `NavMeshManager.load_cell_navmesh()`
- When cell unloads, call `NavMeshManager.unload_cell_navmesh()`
- Ensure navmesh loads BEFORE NPCs spawn

**Estimated Effort:** 2 days

#### 2.3 Fallback Runtime Baking
**File:** `src/core/navigation/runtime_navmesh_backer.gd` (enhance existing)

**Purpose:** Bake navmesh at runtime if prebaked version missing

**Use Cases:**
- Modded cells without prebaked navmesh
- Dynamically created interiors
- Debugging/development (bypass prebaking step)

**Implementation:**
- Check if prebaked navmesh exists
- If not, trigger async bake
- Cache result to avoid rebaking
- Log warning (modders should prebake)

**Estimated Effort:** 2 days

**Phase 2 Total Estimate:** 1-1.5 weeks

---

### Phase 3: Morrowind PathGrid Integration

**Goal:** Use Morrowind's original pathgrid data to enhance navmesh

**Tasks:**

#### 3.1 PathGrid to Off-Mesh Connections
**File:** `src/core/navigation/pathgrid_converter.gd` (new)

**Concept:**
- Morrowind pathgrids define hand-placed waypoints and connections
- Convert to Godot's off-mesh connections (NavigationLink3D)
- Allows NPCs to use ladders, teleports, complex routes

**Implementation:**
```gdscript
func convert_pathgrid_to_offmesh_links(pathgrid: PathgridRecord, region: NavigationRegion3D):
    for connection in pathgrid.connections:
        var start_point = pathgrid.points[connection.start_index]
        var end_point = pathgrid.points[connection.end_index]

        # Create NavigationLink3D
        var link = NavigationLink3D.new()
        link.start_position = Vector3(start_point.x, start_point.y, start_point.z)
        link.end_position = Vector3(end_point.x, end_point.y, end_point.z)
        link.bidirectional = connection.is_bidirectional

        region.add_child(link)
```

**Benefits:**
- Preserves original Morrowind pathing behavior
- Handles special cases (bridges, narrow passages, etc.)
- Improves NPC movement authenticity

**Estimated Effort:** 3-4 days

#### 3.2 Pathgrid Visualization (Debug)
**File:** `src/debug/pathgrid_visualizer.gd` (new)

**Purpose:** Visualize pathgrids in editor/debug mode

**Features:**
- Draw waypoints as spheres
- Draw connections as lines
- Toggle visibility per cell
- Useful for debugging navigation issues

**Estimated Effort:** 2 days

**Phase 3 Total Estimate:** 1 week

---

### Phase 4: Beehave Behavior Tree Integration

**Goal:** Wire up Beehave addon for NPC AI

**Tasks:**

#### 4.1 Create Base NPC Behavior Tree
**File:** `src/core/npc/behaviors/base_npc_behavior.tscn`

**Tree Structure:**
```
Selector (root)
├── Sequence: Combat
│   ├── Condition: IsInCombat
│   ├── Action: ChaseTarget
│   └── Action: AttackTarget
├── Sequence: Flee
│   ├── Condition: ShouldFlee (check flee probability)
│   └── Action: FleeFromThreat
├── Sequence: Wander
│   ├── Condition: IsIdle
│   └── Action: WanderRandomly
└── Action: Idle
```

**Estimated Effort:** 3 days

#### 4.2 Create Behavior Actions
**Files:** `src/core/npc/behaviors/actions/*.gd`

**Actions to implement:**
- `ChaseTargetAction` - Use NavigationAgent3D to chase
- `AttackTargetAction` - Trigger combat animations/logic
- `FleeFromThreatAction` - Navigate away from threat
- `WanderRandomlyAction` - Pick random waypoint, navigate
- `IdleAction` - Stand still, play idle animations

**Integration Points:**
- Use CharacterMovementController.navigate_to()
- Use CharacterAnimationController for animations
- Read NPC AI data (fight/flee probabilities) from NPCRecord

**Estimated Effort:** 4-5 days

#### 4.3 Create Behavior Conditions
**Files:** `src/core/npc/behaviors/conditions/*.gd`

**Conditions to implement:**
- `IsInCombatCondition` - Check combat state
- `ShouldFleeCondition` - Check health + flee probability
- `IsIdleCondition` - No current task
- `CanSeePlayerCondition` - LOS check (reuse from Enemy.gd)

**Estimated Effort:** 2-3 days

#### 4.4 Integrate with CharacterFactory
**File:** `src/core/character/character_factory.gd`

**Changes:**
- Attach behavior tree to NPC instances
- Configure behavior based on NPC type (guard, merchant, etc.)
- Pass NPC AI data to behavior tree

**Estimated Effort:** 2 days

**Phase 4 Total Estimate:** 2 weeks

---

### Phase 5: Optimization & Polish

**Goal:** Ensure production-ready performance

**Tasks:**

#### 5.1 Navmesh Compression
**Investigation:** Can we compress navmesh .tres files?

**Options:**
- Use binary .res instead of .tres (already binary)
- Implement custom compression (zstd?)
- Trade-off: decompression time vs disk space

**Estimated Effort:** 2-3 days

#### 5.2 Navmesh LOD System
**Concept:** Use simpler navmeshes for distant cells

**Implementation:**
- Bake high-detail navmesh for player cell + adjacent
- Bake low-detail navmesh for distant cells (larger cell size)
- Swap based on distance
- Reduces memory and query time

**Estimated Effort:** 4-5 days

#### 5.3 Performance Profiling
**Tasks:**
- Profile navmesh loading time
- Profile pathfinding query performance
- Profile memory usage
- Optimize bottlenecks

**Tools:**
- Godot profiler
- Custom instrumentation
- Stress test with 100+ NPCs

**Estimated Effort:** 3-4 days

#### 5.4 Interior Navigation Polish
**Challenges:**
- Multi-level interiors (Vivec cantons)
- Vertical pathfinding (stairs, ramps)
- Doors as off-mesh connections

**Solutions:**
- Ensure proper NavMesh connectivity between floors
- Use NavigationLink3D for door transitions
- Test complex interiors thoroughly

**Estimated Effort:** 4-5 days

**Phase 5 Total Estimate:** 2-3 weeks

---

## 7. Alternative Approach: Runtime-Only (Not Recommended)

**For completeness, here's why runtime-only won't work:**

**Pros:**
- ✅ No preprocessing step
- ✅ Simpler pipeline
- ✅ Handles dynamic content automatically

**Cons:**
- ❌ 10+ minute initial load time (unacceptable)
- ❌ Hitches during gameplay (cell streaming)
- ❌ Higher memory usage (less optimized)
- ❌ Unpredictable performance
- ❌ Difficult to debug

**Verdict:** Runtime baking should be fallback only, not primary approach.

---

## 8. Risks & Mitigations

### Risk 1: Navmesh Quality Issues
**Scenario:** Prebaked navmeshes have holes, misaligned geometry, unreachable areas

**Mitigation:**
- Implement navmesh validation tool
- Visualize navmeshes in editor
- Test with automated pathfinding tests
- Fallback to runtime baking if prebaked mesh invalid

### Risk 2: Storage Requirements
**Scenario:** 1GB of navmesh data too large for users

**Mitigation:**
- Compress navmesh resources
- Offer "minimal" download (core game only)
- Allow runtime baking for users with storage constraints
- Incremental download (download navmeshes on demand)

### Risk 3: Modding Compatibility
**Scenario:** Mods add cells, prebaked navmeshes missing

**Mitigation:**
- Detect missing navmeshes, trigger runtime bake
- Provide modding guide for prebaking custom cells
- Include navmeshtool in mod SDK
- Graceful degradation (NPCs still work, just slower first load)

### Risk 4: Implementation Complexity
**Scenario:** Integration more complex than estimated

**Mitigation:**
- Break into smaller phases (already done)
- Prototype critical components first
- Allow extra time buffer (30% contingency)
- Re-evaluate after Phase 1 before committing to full plan

---

## 9. Success Metrics

### Performance Targets
- ✅ Navmesh loading: <50ms per cell
- ✅ Pathfinding query: <1ms for 95th percentile
- ✅ Memory usage: <100MB for navmeshes (50 cells loaded)
- ✅ No frame drops during cell streaming
- ✅ Support 100+ NPCs pathfinding simultaneously

### Quality Targets
- ✅ NPCs navigate smoothly across all terrain types
- ✅ No stuck NPCs (detect and resolve within 5 seconds)
- ✅ Pathgrids integrated for all Morrowind cells
- ✅ Behavior trees functional for combat, flee, wander
- ✅ Interior navigation works for multi-level structures

### Development Targets
- ✅ Preprocessing pipeline automated (one command)
- ✅ Modding documentation complete
- ✅ Debug visualization tools available
- ✅ Unit tests for critical components

---

## 10. Timeline Summary

| Phase | Duration | Dependencies |
|-------|----------|--------------|
| Phase 1: Prebaking Pipeline | 2-3 weeks | None |
| Phase 2: Runtime Loading | 1-1.5 weeks | Phase 1 |
| Phase 3: PathGrid Integration | 1 week | Phase 2 |
| Phase 4: Beehave Integration | 2 weeks | Phase 2 |
| Phase 5: Optimization | 2-3 weeks | Phases 1-4 |
| **Total** | **8-10.5 weeks** | |

**Critical Path:** Phase 1 → Phase 2 → Phase 5

**Parallelization Opportunity:** Phase 3 and Phase 4 can be done in parallel after Phase 2

---

## 11. Recommendations

### Immediate Next Steps (Priority Order)

1. **✅ Approve this plan** - Review and validate approach
2. **🔧 Implement Phase 1** - Prebaking pipeline is foundation
3. **🧪 Test with subset** - Bake navmeshes for Seyda Neen + 5-10 cells
4. **📊 Measure performance** - Validate assumptions before full implementation
5. **🔁 Iterate** - Adjust parameters based on results

### Technical Decisions Required

**Decision 1: NavMesh Granularity**
- Option A: One navmesh per cell (simple, aligns with Morrowind)
- Option B: Subdivide large cells into tiles (complex, better performance)
- **Recommendation:** Option A initially, Option B if needed

**Decision 2: Storage Format**
- Option A: Binary .res files (fast, compact)
- Option B: Text .tres files (debuggable, merge-friendly)
- **Recommendation:** Option A for production, Option B for development

**Decision 3: Behavior Tree Complexity**
- Option A: Start simple (idle, wander, chase, attack)
- Option B: Full Morrowind AI (schedules, dialogue-triggered behaviors)
- **Recommendation:** Option A for Phase 4, expand in Phase 6+

### Long-Term Considerations

**Future Enhancement: Dynamic Obstacles**
- Track moving objects (NPCs, physics bodies)
- Update navmesh locally (avoidance layer)
- Recastnavigation has "dynamic navmesh" support
- Godot 4.3+ has avoidance improvements

**Future Enhancement: Multi-Agent Pathfinding**
- Implement flocking behaviors
- Avoid NPC clustering (RVO - Reciprocal Velocity Obstacles)
- Godot has AvoidanceAgent3D (not yet used)

**Future Enhancement: Scripted Routes**
- NPC daily schedules (Morrowind feature)
- Predefined patrol routes
- Use pathgrid points as waypoints

---

## 12. Conclusion

The current implementation has solid foundations (CharacterMovementController, RuntimeNavigationBaker, basic AI) but lacks the scalability needed for full Morrowind world.

**The recommended hybrid approach:**
- ✅ Prebake navmeshes offline (OpenMW-style)
- ✅ Stream navmeshes at runtime (Godot best practice)
- ✅ Fallback to runtime baking (modding flexibility)
- ✅ Integrate behavior trees (Beehave)
- ✅ Preserve pathgrid data (Morrowind authenticity)

This balances **performance** (prebaking), **maintainability** (Godot ecosystem), and **authenticity** (Morrowind features).

**Estimated total effort:** 8-10.5 weeks for full implementation.

**Next step:** Begin Phase 1 implementation after plan approval.

---

## References

### OpenMW Resources
- [Navigator Settings | OpenMW](https://openmw.readthedocs.io/en/latest/reference/modding/settings/navigator.html)
- [Navmesh disk cache merge request](https://gitlab.com/OpenMW/openmw/-/merge_requests/1058)
- [Generate A Navmesh Cache Guide](https://modding-openmw.com/mods/generate-a-navmesh-cache/)
- [Tips: Navmeshtool](https://modding-openmw.com/tips/navmeshtool/)
- [Use recastnavigation PR](https://github.com/OpenMW/openmw/pull/1633)
- [OpenMW 0.50.0 Release](https://openmw.org/2025/openmw-0-50-0-released/)

### Godot Resources
- [Optimizing Navigation Performance](https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_optimizing_performance.html)
- [Using navigation meshes](https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_using_navigationmeshes.html)
- [Navigation Server for Godot 4.0](https://godotengine.org/article/navigation-server-godot-4-0/)
- [NavigationMeshGenerator Class](https://docs.godotengine.org/en/stable/classes/class_navigationmeshgenerator.html)
- [Large World Navmesh Proposal](https://github.com/godotengine/godot-proposals/issues/12707)
- [3D navigation overview](https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_introduction_3d.html)
- [Connecting navigation meshes](https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_connecting_navmesh.html)

### Plugin Resources
- [Beehave - Godot Asset Library](https://godotengine.org/asset-library/asset/1349)
- [Beehave GitHub](https://github.com/bitbrain/beehave)
- [LimboAI GitHub](https://github.com/limbonaut/limboai)
- [Chunx - World Streaming Plugin](https://github.com/SlashScreen/chunx)
- [BehaviourToolkit](https://godotengine.org/asset-library/asset/2333)
- [GameFromScratch - Beehave Overview](https://gamefromscratch.com/beehave-behavior-trees-for-godot/)

---

**Document Version:** 1.0
**Last Updated:** 2025-12-21
**Authors:** Claude Code AI Assistant
**Status:** Awaiting Approval
