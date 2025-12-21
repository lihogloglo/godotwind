# TODO - Prioritized Next Steps

## High Impact Features

### 1. Water System Integration
The ocean framework exists in `src/core/water/` but isn't connected to the main scene.

**Tasks:**
- [ ] Add OceanManager to world_explorer.tscn
- [ ] Connect shore mask to Terrain3D data
- [ ] Tune wave parameters for Morrowind sea level
- [ ] Add underwater post-processing (fog, tint)

**Files:** `ocean_manager.gd`, `wave_generator.gd`, `shore_mask_generator.gd`

### 2. Seamless Interior Transitions
Currently interiors are separate. Goal: walk through doors with no loading screen.

**Tasks:**
- [ ] Async load interior cell when player approaches door
- [ ] Stream interior in parallel with exterior (don't unload exterior)
- [ ] Smooth camera transition through doorway
- [ ] Interior/exterior lighting blend at threshold

**Files:** `cell_manager.gd`, `world_streaming_manager.gd`

### 3. Weather & Day/Night
Sky3D plugin is installed but not integrated.

**Tasks:**
- [ ] Integrate Sky3D with time-of-day controller
- [ ] Hook up Morrowind region weather data (ESM REGN records)
- [ ] Weather transitions (clear → rain → storm)
- [ ] DirectionalLight3D rotation for sun/moon

## Gameplay Foundation

### 4. Player Controller
Toggle between fly camera and proper character controller with P key.

**Tasks:**
- [x] CharacterBody3D setup (`src/core/player/player_controller.gd`)
- [x] Movement (walk, run, jump)
- [x] First-person camera
- [x] FlyCamera script (`src/core/player/fly_camera.gd`)
- [x] Toggle between modes (P key in world_explorer)
- [ ] Swimming (water Area3D detection)
- [ ] Third-person camera option

### 5. Basic NPC Presence
NPCs are loaded but static.

**Tasks:**
- [ ] Wire Beehave behavior trees
- [ ] Basic idle/wander behavior
- [ ] NavMesh generation for cells
- [ ] Dialogue initiation (click to talk)

### 6. Dialogue UI
Records are parsed, need UI.

**Tasks:**
- [ ] Basic dialogue panel
- [ ] Topic list from DIAL records
- [ ] Response text from INFO records
- [ ] Condition checking (disposition, faction, etc.)

## Performance & Polish

### 7. Animation System Optimization ✅ **PHASE 1 COMPLETE**
Production-ready animation features implemented (2025-12-21).

**Completed:**
- [x] Foot IK for terrain adaptation
- [x] Slope detection and character body tilt
- [x] Animation LOD system (distance-based update rates)
- [x] NavMesh pathfinding integration
- [x] 5-10x performance improvement for large NPC counts

**See:** `docs/PHASE1_ANIMATION_ENHANCEMENTS.md`

### 8. Draw Call Reduction
Currently ~8000 draw calls with full objects.

**Tasks:**
- [ ] MultiMesh for repeated objects (flora, rocks)
- [ ] Mesh merging for static objects per cell
- [ ] Verify Terrain3D LOD settings optimal

### 9. Occlusion Culling
Godot's baked occlusion has limitations.

**Tasks:**
- [ ] Portal system for interiors (custom)
- [ ] Evaluate GPU Hi-Z occlusion for dynamic objects
- [ ] Tune view distance vs performance

## Technical Debt

### 10. Testing
No automated tests currently.

**Tasks:**
- [ ] Unit tests for CoordinateSystem
- [ ] Integration tests for cell loading
- [ ] Performance benchmarks
- [ ] Phase 1 animation system in-game validation

### 11. NIF Edge Cases
Some NIF features not fully supported.

**Tasks:**
- [ ] NiParticleSystem conversion
- [ ] Multi-material mesh support
- [ ] Morph targets

---

## Completed (Reference)

These were in previous TODOs but are now done:

- [x] Async cell loading (BackgroundProcessor)
- [x] Thread-safe NIF parsing (NIFParseResult)
- [x] Async terrain generation
- [x] BSA thread safety (mutex protection)
- [x] GenericTerrainStreamer for multi-world
- [x] WorldDataProvider interface
- [x] La Palma terrain demo
- [x] Terrain edge stitching
- [x] Combined regions (4x4 cells per Terrain3D region)
- [x] RTT deformation system (DeformationManager, shaders, streaming)

---

## Quick Reference: Key Files to Modify

| Task | Primary Files |
|------|---------------|
| Water integration | `world_explorer.gd`, `ocean_manager.gd` |
| Interior transitions | `cell_manager.gd`, `world_streaming_manager.gd` |
| Weather | `world_explorer.gd`, need new sky controller |
| Player controller | New file: `src/core/player/player_controller.gd` |
| NPC AI | `cell_manager.gd`, new behavior tree files |
| Dialogue | New file: `src/ui/dialogue_ui.gd` |
| Performance | `cell_manager.gd`, `nif_converter.gd` |
