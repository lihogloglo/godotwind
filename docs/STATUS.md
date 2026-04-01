# Status

What works, what doesn't.

## Working

| System | Notes |
|--------|-------|
| World Streaming | Async cell loading, shared 8ms/frame budget across all phases, frustum priority, object pooling, deferred RS cleanup with immediate-hide |
| 3-Tier LOD | NEAR 0-150m (Node3D), MID 150-500m (RS instances), FAR 500-5km (impostors). Differential impostor updates on cell crossing (~1ms vs 14-158ms before) |
| Terrain | Terrain3D, multi-region, edge stitching |
| ESM Parsing | 47 record types, grid-indexed cells, thread-safe |
| NIF Conversion | Geometry, materials, skeletons, animations, collision |
| BSA Archives | Thread-safe, 256MB LRU cache |
| Textures | DDS/TGA loading, material deduplication (90% reduction) |
| NPC Assembly | Race + head + hair, body part mirroring, full-body skin detection |
| Animations | 132 MW animations, state machine (idle/walk/run/jump) |
| Deformation | RTT-based (snow, mud, ash) |
| Console | Command registry, object picking, selection outline |
| Fly Camera | Free camera + FPS controller (toggle P) |

## Framework Ready (Not Integrated)

| System | Notes |
|--------|-------|
| Ocean/Water | OceanManager, Gerstner waves, buoyancy — not wired into main scene |
| Weather/Sky | Sky3D addon installed, not integrated |
| Character Controller | Basic FPS controller, no physics-based movement yet |

## In Progress

| System | Notes |
|--------|-------|
| Interior Transitions | Classic mode (fade-to-black) working. Pocket repositioning at Y=-500. Streaming manager MUST be paused during transitions (prevents cell unloading at underground camera position → segfault). Terrain3D hidden during interior (cosmetic). |

## Not Started

Combat, magic, AI, dialogue UI, quests, inventory, save/load, character creation.

## Known Issues

1. NiParticleSystem not converted
2. Interior lighting exists but not tuned
3. Animation action layers stubbed (upper body blend not wired)
4. Automated tests: gdUnit4 13 unit tests + visual test scenes in tests/visual/

## Performance

| Metric | Value |
|--------|-------|
| FPS | 60+ (streaming) |
| View distance | 5km (impostors) |
| Shared frame budget | 8ms across all streaming phases |
| Worst cell-crossing stall | ~35ms (down from 307ms, 2026-03-30 optimization) |
| Impostor count | ~63K (497 texture layers) |
| Impostor crossing cost | ~1ms (differential border-strip update) |
| MultiMesh rebuild | single `set_buffer()` call (PackedFloat32Array) |
| Memory | ~2GB |

## Profiling Infrastructure

| Tool | Usage |
|------|-------|
| PerformanceProfiler | Frame timing, P50/P95/P99, draw calls, memory (automatic) |
| StreamingProfiler | Per-subsystem microsecond timing with section breakdown |
| StreamingBenchmark | Scripted camera path, CSV output. Console: `benchmark_streaming` |
| LodTransitionTest | Automated LOD boundary crossing test with CSV output |
| ProfilingReport | Full report dump via F4 key |
| BatchDebugHUD | Real-time RS instance stats. Console: `mid_debug` |
| DebugSystem | F9 overlay, F12 auto-test mode |
| Per-phase overrun logs | `[streaming] Frame overrun: Xms [unload:X async:X inst:X ...]` |
