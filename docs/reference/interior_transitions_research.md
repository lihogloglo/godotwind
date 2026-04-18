# Interior Transitions — Industry & Godot Reference

> Reference material. Industry survey and Godot 4.6 capabilities relevant to interior/exterior transitions. For Godotwind's current implementation, see `docs/systems/interior_transitions.md`.

## Industry References

| Game | Technique | TARDIS? | Notes |
|------|-----------|---------|-------|
| **Morrowind/Skyrim/Starfield** | Fade-to-black + cell swap | Yes | Loading screen between exterior/interior |
| **The Witcher 3** | Contiguous geometry + Umbra 3 | No | Interiors part of same world |
| **GTA V / RDR2** | MLO shell + room portals | No | Interior at world position |
| **Prey (2017)** | Looking Glass (SubViewport-like) | No | Same-scale interiors |
| **Half-Life: Alyx** | Stencil portal + teleport | Minor | VR seamless transitions |
| **Portal (Valve)** | Stencil + dual camera | No | Same-scale portal connections |
| **God of War (2018)** | Squeeze-through corridors | N/A | Hides loading behind narrow passages |

### The Witcher 3 (REDengine 3)

TW3 interiors are **contiguous with the exterior** — no separate cells. Umbra 3
(middleware) handles automatic occlusion culling. When outside, interior geometry
is occluded by walls. When walking through door, Umbra sees interior through opening.
Single lighting system, no environment swap needed.

**Not applicable to us:** TW3 interiors fit their buildings (no TARDIS), and all
geometry was custom-built for spatial alignment.

### RDR2 / GTA V (RAGE Engine)

"Shell + MLO" architecture: exterior building has door/window holes cut out, interior
MLO streams in at the same world position. Room+portal system for interior occlusion.
Single deferred lighting pipeline handles transition naturally.

**Most relevant to our approach:** The proximity-based interior streaming and
portal-controlled visibility are similar to our pocket + stencil system. The key
difference: RAGE places interiors at world position (no coordinate gap).

### Comparison

| Aspect | TW3 | RDR2/GTA V | Godotwind |
|--------|-----|------------|-----------|
| Interior position | At building | At building (MLO) | Y=-500 pocket |
| TARDIS problem | None | None | Yes (Morrowind data) |
| Occlusion | Umbra 3 (auto) | Room+portal (manual) | Stencil + render layers |
| Lighting transition | Same system | Same pipeline | WorldEnvironment swap |
| Visual continuity | Natural | Shell hole alignment | Stencil portal |

Our approach is closest to **Valve's Portal**: two disconnected spaces linked by a
visual "window" at the doorframe, with a coordinate teleport on crossing.

---

## Godot 4.6 Capabilities & Limitations

### What we use:
- **Stencil buffer** (StandardMaterial3D) — portal rendering, no custom pipeline needed
- **Render layers** (20 layers) — exterior/interior visual separation
- **Physics layers** — per-slot collision isolation
- **visibility_range** — distance-based LOD (not used for portals, but for world streaming)

### What Godot lacks:
- **Built-in oblique clip planes** — must use shader `discard`
- **Portal culling** — removed in 4.0 (was in 3.x)
- **Rendering compositor** — still a proposal

### Stencil caveat:
Stencil READ requires `transparency=ALPHA` (Godot issue #107731). This pushes
interior materials into the transparent queue, which affects depth sorting.

---

## Future Directions

1. **Exterior wall clip** → enables `no_depth_test=false` → proper depth sorting
2. **Environment blend** in seamless path (distance-based interpolation)
3. **Interior→exterior portal** (reverse stencil for looking out from inside)
4. **Window parallax** (SubViewport for windows — small viewport, big atmosphere)
5. **Interior-to-interior seamless** (currently uses classic fade-to-black)
6. **Horizontal doors** (ship hatches — need pitch-based alignment)
7. **Async pocket loading** (budgeted instantiation instead of synchronous) — shipped 2026-04-06, see `docs/systems/interior_transitions.md`
