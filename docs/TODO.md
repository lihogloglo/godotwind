# TODO - Prioritized Next Steps

## High Impact Features

### 1. RTT Ground Deformation System
Production-ready ground deformation (snow, mud, ash) with grass integration.

**Tasks:**
- [ ] Implement core RTT system (DeformationManager, DeformationRenderer)
- [ ] Create deformation stamp and recovery shaders
- [ ] Integrate with GenericTerrainStreamer (region streaming)
- [ ] Modify Terrain3D shader for vertex displacement
- [ ] Implement grass system with deformation support
- [ ] Add persistence (save/load deformation textures)
- [ ] Optimize with LOD and batching

**Files:** See `docs/RTT_DEFORMATION_SYSTEM_DESIGN.md` for full details
**Quick Start:** See `docs/RTT_DEFORMATION_QUICK_START.md`

### 2. Water System Integration
The ocean framework exists in `src/core/water/` but isn't connected to the main scene.

**Tasks:**
- [ ] Add OceanManager to world_explorer.tscn
- [ ] Connect shore mask to Terrain3D data
- [ ] Tune wave parameters for Morrowind sea level
- [ ] Add underwater post-processing (fog, tint)

**Files:** `ocean_manager.gd`, `wave_generator.gd`, `shore_mask_generator.gd`

### 3. Seamless Interior Transitions
Currently interiors are separate. Goal: walk through doors with no loading screen.

**Tasks:**
- [ ] Async load interior cell when player approaches door
- [ ] Stream interior in parallel with exterior (don't unload exterior)
- [ ] Smooth camera transition through doorway
- [ ] Interior/exterior lighting blend at threshold

**Files:** `cell_manager.gd`, `world_streaming_manager.gd`

### 4. Weather & Day/Night
Sky3D plugin is installed but not integrated.

**Tasks:**
- [ ] Integrate Sky3D with time-of-day controller
- [ ] Hook up Morrowind region weather data (ESM REGN records)
- [ ] Weather transitions (clear → rain → storm)
- [ ] DirectionalLight3D rotation for sun/moon

## Gameplay Foundation

### 5. Player Controller
Replace fly camera with proper character controller.

**Tasks:**
- [ ] CharacterBody3D setup
- [ ] Movement (walk, run, jump)
- [ ] Camera (1st/3rd person)
- [ ] Swimming (water Area3D detection)
- [ ] Collision with world

### 6. Basic NPC Presence
NPCs are loaded but static.

**Tasks:**
- [ ] Wire Beehave behavior trees
- [ ] Basic idle/wander behavior
- [ ] NavMesh generation for cells
- [ ] Dialogue initiation (click to talk)

### 7. Dialogue UI
Records are parsed, need UI.

**Tasks:**
- [ ] Basic dialogue panel
- [ ] Topic list from DIAL records
- [ ] Response text from INFO records
- [ ] Condition checking (disposition, faction, etc.)

## Performance & Polish

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

### 11. NIF Edge Cases
Some NIF features not fully supported.

**Tasks:**
- [ ] NiParticleSystem conversion
- [ ] Animation blending
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

---

## Quick Reference: Key Files to Modify

| Task | Primary Files |
|------|---------------|
| RTT Deformation | See `docs/RTT_DEFORMATION_SYSTEM_DESIGN.md` |
| Water integration | `world_explorer.gd`, `ocean_manager.gd` |
| Interior transitions | `cell_manager.gd`, `world_streaming_manager.gd` |
| Weather | `world_explorer.gd`, need new sky controller |
| Player controller | New file: `src/core/player/player_controller.gd` |
| NPC AI | `cell_manager.gd`, new behavior tree files |
| Dialogue | New file: `src/ui/dialogue_ui.gd` |
| Performance | `cell_manager.gd`, `nif_converter.gd` |
