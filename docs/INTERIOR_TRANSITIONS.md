# Interior/Exterior Transitions — Architecture & Industry Analysis

## Morrowind Data Model

Interior transitions are encoded in ESM door references:

- `is_teleport` flag marks a reference as a door transition
- `DODT` subrecord: destination position + rotation (player arrival facing, yaw only)
- `DNAM` subrecord: destination cell name (string for interiors, grid coords for exteriors)
- Interior cells have their own `water_height`, `ambient_color`, `sunlight_color`, `fog_color`, `fog_density`
- `is_quasi_exterior()` flag: some interiors share exterior sky/weather (e.g., Vivec plazas)

### Morrowind-Specific Challenges

1. **Coordinate mismatch:** Interior cells use their own local origin, unrelated to world space
2. **Size mismatch (TARDIS):** Interior geometry often exceeds the exterior building shell
3. **Lighting isolation:** Interiors have ambient/fog from AMBI data, completely different from exterior
4. **Interior-to-interior chains:** Dungeons have doors between interior cells

### ESM Rotation Conventions

Two different rotation fields exist per door and they serve different purposes:

- **`door_rotation_mw`** (cell reference rotation): The door OBJECT's physical orientation
  in the cell. Tells us which way the door mesh faces in the wall. Used for pocket alignment.
- **`teleport_rot_mw`** (DODT rotation): Where the PLAYER faces after teleporting.
  A gameplay hint — designers can point toward NPCs, tables, etc. NOT a geometric property.

Both use MW coordinate conventions (Z-up, rotate around -Z for yaw). When converting
to Godot (Y-up), yaw is negated: `Basis(Vector3.UP, -rot_mw.z)`.

---

## Current Architecture: Cell Pocket System

See `docs/PORTAL_SYSTEM.md` for full technical details.

**Cell pockets:** Interiors loaded as isolated "pockets" at Y=-500 in the same World3D:
- Visual layers: Exterior = 1-2, Interior = 3-4
- Physics layers: Exterior = 1-4, Interior = 5-6 per slot
- Spatial offset: Y=-500 with 1km X spacing between slots
- 2-slot reusable pool with distance-based eviction

**Two modes:**
- **Classic (default):** ENTER key → fade-to-black → teleport. Original MW behavior.
- **Seamless (experimental):** Stencil portal preview + walk-through + building hiding.

Toggle: `InteriorPocketManager.seamless_enabled` (escape menu checkbox or F5 in test scene).

### Key Insight: Why TARDIS Is a Non-Issue

The doorframe is the mask. The player can ONLY see the interior through the door opening.
As long as what's visible through that opening looks continuous with the exterior, the
transition is seamless — even if the interior is 10x larger than the exterior shell.

This is exactly how Portal (Valve) works: two portals connect spaces of any size/orientation,
and the player never notices because each portal shows only what fits through its opening.

---

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
7. **Async pocket loading** (budgeted instantiation instead of synchronous)
