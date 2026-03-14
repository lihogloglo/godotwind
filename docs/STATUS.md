# Status

What works, what doesn't.

## Working

| System | Notes |
|--------|-------|
| World Streaming | Async cell loading, 2ms/frame budget, frustum priority, object pooling |
| 3-Tier LOD | NEAR 0-150m (Node3D), MID 150-500m (RS instances), FAR 500-5km (impostors) |
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

## Not Started

Combat, magic, AI, dialogue UI, quests, inventory, save/load, character creation, interior transitions.

## Known Issues

1. NiParticleSystem not converted
2. Interior lighting exists but not tuned
3. Animation action layers stubbed (upper body blend not wired)
4. No automated tests (0% coverage)

## Performance

| Metric | Value |
|--------|-------|
| FPS | 60+ (streaming) |
| View distance | 585m+ |
| Cell load budget | 2ms/frame |
| Memory | ~2GB |
