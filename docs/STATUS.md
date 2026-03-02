# Implementation Status

Ground truth for what works, what doesn't, and what's where.
For the roadmap, see [MASTERPLAN.md](audit/MASTERPLAN.md).

## Core Systems

| System | Status | Notes |
|--------|--------|-------|
| **World Streaming** | Complete | Time-budgeted async, priority queues, no hitches |
| **Terrain** | Complete | Terrain3D integration, multi-region, edge stitching |
| **Deformation System** | Complete | RTT-based ground deformation (snow, mud, ash) |
| **Cell Loading** | Complete | Async API, object instantiation, pooling |
| **ESM Parsing** | Complete | 47 record types, all game data accessible |
| **NIF Conversion** | 90% | Geometry, materials, skeletons, collision, animations. Missing: NiParticleSystem |
| **BSA Archives** | Complete | Thread-safe extraction, 256MB LRU cache |
| **Texture Loading** | 90% | DDS/TGA, material deduplication |
| **Async/Threading** | Complete | BackgroundProcessor, thread-safe NIF parsing |
| **Coordinate System** | Complete | MW-to-Godot conversion (position, rotation, scale) |

## Rendering & Optimization

| System | Status | Notes |
|--------|--------|-------|
| **3-Tier LOD** | Complete | NEAR (0-150m Node3D), MID (150-500m per-instance RS visibility_range, 3 LOD levels), FAR (500-5km impostors) |
| **Terrain LOD** | Complete | Handled by Terrain3D clipmap |
| **Object LOD** | Complete | Native Godot VisibilityRange |
| **Object Pooling** | Complete | Hit rate tracking, O(1) release |
| **Material Dedup** | Complete | Shared materials for VRAM efficiency |

## Character & Animation

| System | Status | Notes |
|--------|--------|-------|
| **NPC Body Assembly** | Complete | Race + head + hair meshes, body part mirroring, full-body skin detection |
| **MW Animation Pipeline** | Working | 132 animations loaded, state machine (idle/walk/run/jump), locomotion working |
| **Animation Action Layers** | Stubbed | Upper body blend + oneshot nodes created, not fully wired |
| **Humanoid Characters** | Working | Quaternius GLB, separate skeleton from MW |
| **IK System** | Working | TwoBoneIK3D for hands/feet, pole nodes required |

## Framework Features

| System | Status | Notes |
|--------|--------|-------|
| **Multi-world Support** | Complete | WorldDataProvider interface (Morrowind, La Palma) |
| **GenericTerrainStreamer** | Complete | Works with any data provider |
| **Water/Ocean** | Framework Ready | OceanManager exists, not integrated into main scene |
| **Interior Transitions** | Not Started | Door code exists but not seamless |

## Tools

| Tool | Status | Notes |
|------|--------|-------|
| **World Explorer** | Production | Full Morrowind streaming demo |
| **NIF Viewer** | Production | Model browser, animations, collision viz |
| **La Palma Explorer** | WIP | Terrain-only, minimal features |
| **Settings Tool** | Production | Morrowind path config |
| **Developer Console** | Production | Object picking, commands, scripting |
| **Streaming Benchmark** | Production | 6-phase automated benchmark, CSV output |

## Gameplay Systems (Not Implemented)

| System | Status |
|--------|--------|
| Player Controller | Basic FPS controller + fly camera, toggle with P |
| Character Creation | Not started |
| Stats/Skills | Not started |
| Combat | Not started |
| Magic | Not started |
| AI/NPCs | Beehave installed, not wired |
| Dialogue | Records parsed, no UI |
| Quests | Questify installed, not wired |
| Inventory | GLoot installed, not wired |
| Weather | Sky3D installed, not integrated |
| Save/Load | Not started |

## What's in src/core/

```
src/core/
├── animation/              # Character animation system
│   ├── animation_manager.gd         # State machine, blend tree
│   ├── animation_blend_mask.gd      # Upper/lower body masks
│   ├── animation_priority.gd        # Priority-based transitions
│   ├── character_animation_system.gd # Base orchestrator
│   ├── humanoid_animation_system.gd  # Humanoid specialization
│   ├── morrowind_character_system.gd # MW specialization
│   ├── ik_controller.gd             # TwoBoneIK3D (humanoid + quadruped)
│   └── text_key_handler.gd          # Animation event keys
├── bsa/                    # BSA archive reading
│   ├── bsa_manager.gd      # Thread-safe singleton (autoload)
│   ├── bsa_reader.gd
│   └── bsa_defs.gd
├── character/              # Character assembly
│   ├── mesh_extractor.gd            # NIF mesh extraction
│   ├── morrowind/                   # MW NPC assembly
│   │   └── morrowind_npc_assembler.gd
│   ├── humanoid/                    # Humanoid (Quaternius) characters
│   │   ├── humanoid_character_factory.gd
│   │   └── humanoid_equipment.gd
│   └── controller/                  # Character movement
│       └── moves/
├── console/                # Developer console
│   ├── console.gd
│   ├── console_ui.gd
│   ├── command_registry.gd
│   ├── object_picker.gd
│   └── shaders/
├── deformation/            # RTT deformation system
│   ├── deformation_manager.gd       # Autoload singleton
│   ├── deformation_renderer.gd
│   ├── deformation_streamer.gd
│   └── deformation_compositor.gd
├── esm/                    # ESM/ESP parsing (47 record types)
│   ├── esm_manager.gd              # Autoload singleton
│   ├── esm_reader.gd
│   └── records/
├── logging/                # Structured logging
│   └── logger.gd                   # Log autoload (debug/info/warn/error)
├── modding/                # Mod support
│   └── mod_registry.gd             # RefCounted, compiled load-order cache
├── navigation/             # Pathfinding
├── nif/                    # NIF model conversion
│   ├── nif_converter.gd             # Main converter (async API)
│   ├── nif_reader.gd
│   ├── nif_skeleton_builder.gd
│   ├── nif_animation_converter.gd
│   └── nif_kf_loader.gd            # KF animation files
├── player/                 # Player/camera systems
│   ├── fly_camera.gd
│   └── player_controller.gd        # FPS CharacterBody3D
├── streaming/              # Async processing
│   └── background_processor.gd
├── texture/                # Texture loading
│   └── texture_loader.gd
├── threading/              # Background job system
│   └── background_job_system.gd
├── water/                  # Ocean system (framework ready)
│   ├── ocean_manager.gd
│   ├── ocean_mesh.gd
│   ├── wave_generator.gd
│   ├── shore_mask_generator.gd
│   ├── buoyant_body.gd
│   └── shaders/
├── world/                  # World streaming & terrain
│   ├── native_streaming_manager.gd
│   ├── cell_manager.gd
│   ├── generic_terrain_streamer.gd
│   ├── world_data_provider.gd
│   ├── morrowind_data_provider.gd
│   ├── native_impostor_renderer.gd
│   ├── static_object_renderer.gd
│   ├── object_pool.gd
│   ├── model_loader.gd
│   ├── streaming_config.gd
│   ├── distance_utils.gd
│   └── lod_configurator.gd
├── coordinate_system.gd
└── native_bridge.gd                # C# <-> GDScript interop
```

## Known Issues

1. **Particle systems** — NiParticleSystem not converted
2. **Interior lighting** — Lights created but not tuned
3. **Animation action layers** — Stubbed, not fully wired (A-18/A-19 in FINDINGS.md)
4. **No automated tests** — 0% coverage, all verification is manual
5. **ModRegistry** — Exists but not wired into loading paths (deferred to Phase 3)

## Performance (Measured)

| Metric | Value |
|--------|-------|
| FPS (streaming) | 60+ |
| View distance | 585m+ |
| Cell load budget | 2ms/frame |
| Memory usage | ~2GB |
| Initial load | ~5s |
