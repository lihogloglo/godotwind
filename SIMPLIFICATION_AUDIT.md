# Godotwind Simplification Audit

## Current State Analysis

### Existing Tools (5 main tools + 1 utility)

1. **cell_viewer.gd** (467 lines)
   - Purpose: View individual Morrowind cells (interior/exterior)
   - Features: Cell browser, search, quick load buttons, free-fly camera
   - Objects: Loads static objects, lights, NPCs, creatures

2. **main.gd** (176 lines)
   - Purpose: Basic ESM test scene
   - Features: Load ESM, show statistics, sample data
   - Simple file loader with progress bar

3. **nif_viewer.gd** (790 lines)
   - Purpose: View individual NIF models from BSA
   - Features: Model browser, categories, animations, collision visualization
   - Camera: Orbit camera with auto-rotate

4. **streaming_demo.gd** (905 lines)
   - Purpose: Navigate the Morrowind world with streaming
   - Features: Infinite terrain, multi-region, object streaming, LOD, profiling
   - Camera: Free-fly camera
   - **Missing**: Interior cell viewing

5. **terrain_viewer.gd** (909 lines)
   - Purpose: Test terrain visualization with Terrain3D
   - Features: Live conversion, pre-processing, single/multi-terrain modes
   - Overlaps heavily with streaming_demo

6. **settings_tool.gd** (156 lines)
   - Purpose: Configure Morrowind data path
   - Type: Utility (not a main tool)

### Problems Identified

#### 1. **Redundancy & Overlap**
- **Cell viewing**: Both `cell_viewer` and `streaming_demo` load cells
- **Terrain handling**: Both `terrain_viewer` and `streaming_demo` handle terrain
- **World navigation**: `streaming_demo` should be the canonical way to explore the world
- **Testing**: `main.gd` is just a basic test harness, not needed as a separate tool

#### 2. **Confusion**
- Too many entry points for users
- Unclear which tool to use for which purpose
- Feature duplication makes maintenance harder

#### 3. **Complexity**
- 5 main tools when only 2 are needed
- Each tool has its own UI, camera controls, loading logic
- Shared functionality not properly abstracted

## Target State (Simplification Cascade)

### Two Core Tools

#### 1. **NIF Viewer** (`nif_viewer.gd`)
**Purpose**: View individual 3D models and assets
- **Keep as-is**: Already well-focused
- Model browser with categories
- Animation playback
- Collision visualization
- Orbit camera perfect for model inspection

#### 2. **Streaming Demo** → Rename to **"World Explorer"** (`streaming_demo.gd`)
**Purpose**: Navigate and explore the Morrowind world
- **Current features** (keep):
  - Infinite terrain with multi-region streaming
  - Exterior cell object loading
  - Free-fly camera
  - LOD and performance profiling
  - Quick teleport buttons

- **Add from cell_viewer**:
  - Interior cell browser/viewer
  - Cell search functionality
  - Option to toggle between exterior (terrain) and interior mode

- **Add from terrain_viewer**:
  - Terrain preprocessing UI (already has this)

#### 3. **Settings Tool** (utility, not a main tool)
**Keep**: Essential utility for configuration

## Simplification Plan

### Phase 1: Enhance Streaming Demo
**Goal**: Make it a complete world exploration tool

1. **Add Interior Cell Viewing**
   - Port cell browser UI from cell_viewer
   - Add toggle: "World Mode" vs "Cell Mode"
   - In Cell Mode: Show interior cell list, allow loading specific interiors
   - In World Mode: Current behavior (exterior terrain + streaming)

2. **Improve UI Organization**
   - Tabbed interface: [World] [Interiors] [Settings]
   - World tab: Current terrain navigation
   - Interiors tab: Cell browser from cell_viewer
   - Settings tab: Quick settings (view distance, LOD, etc.)

3. **Rename**: `streaming_demo.gd` → `world_explorer.gd`
   - More descriptive name
   - Reflects its comprehensive purpose

### Phase 2: Remove Redundant Tools

1. **Delete cell_viewer.gd** and its scene
   - Functionality moved to World Explorer
   - Interior viewing preserved

2. **Delete terrain_viewer.gd** and its scene
   - Terrain preprocessing already in streaming_demo
   - Terrain viewing is streaming_demo's core feature

3. **Delete main.gd** and its scene
   - Was just a test harness
   - Not needed for end users

### Phase 3: Update Entry Points

1. **Update project.godot**
   - Main scene: World Explorer
   - Remove references to deleted tools

2. **Update documentation**
   - README: Two tools (NIF Viewer, World Explorer)
   - Clear separation of concerns

3. **Update SETTINGS.md**
   - Simplify to focus on two tools

## Benefits of Simplification

### 1. **Clarity**
- Clear purpose for each tool
- No confusion about which to use
- Single source of truth for each feature

### 2. **Maintainability**
- Less code to maintain
- No duplicate functionality
- Easier to add new features

### 3. **User Experience**
- Simpler learning curve
- One tool for world exploration
- One tool for model inspection

### 4. **Code Quality**
- Force proper abstraction of shared logic
- Better separation of concerns
- Easier testing

## Implementation Order

1. ✅ **Audit complete** (this document)
2. ⏭️ **Add interior cell viewing to streaming_demo**
   - Port UI components from cell_viewer
   - Implement mode toggle
   - Test with various interior cells
3. ⏭️ **Rename streaming_demo → world_explorer**
4. ⏭️ **Remove redundant tools**
   - Delete files
   - Update project references
   - Clean up git
5. ⏭️ **Update documentation**
   - README
   - SETTINGS.md
   - Code comments

## Risk Mitigation

- **Backup before deletion**: Commit before removing files
- **Preserve git history**: Don't force-push, keep deleted files in history
- **Test thoroughly**: Ensure all cell_viewer features work in world_explorer
- **Documentation**: Update docs immediately after changes

## Success Metrics

- ✓ Only 2 main tools (NIF Viewer, World Explorer) + 1 utility (Settings)
- ✓ No feature loss (all cell_viewer features in world_explorer)
- ✓ Clearer project structure
- ✓ Updated documentation reflects new structure
- ✓ All tests pass

## Alignment with Simplification Cascades

This plan follows key simplification principles:

1. **Eliminate Redundancy**: Remove duplicate terrain and cell viewing
2. **Consolidate**: Merge related features into single tools
3. **Clarify Purpose**: Each tool has one clear job
4. **Reduce Cognitive Load**: Fewer choices, clearer paths
5. **Preserve Functionality**: No features lost, just reorganized
