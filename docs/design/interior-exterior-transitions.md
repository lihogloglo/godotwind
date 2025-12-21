# Interior/Exterior Transition System - Design Document

**Author:** Claude
**Date:** 2025-12-21
**Status:** Ideation / Proposal
**Target:** General-purpose framework with Morrowind as primary use case

---

## Table of Contents
1. [Executive Summary](#executive-summary)
2. [Industry Analysis](#industry-analysis)
3. [Current Morrowind Architecture](#current-morrowind-architecture)
4. [Proposed Framework](#proposed-framework)
5. [Implementation Roadmap](#implementation-roadmap)
6. [Performance Considerations](#performance-considerations)
7. [References](#references)

---

## Executive Summary

This document proposes a general-purpose interior/exterior transition system for Godot 4, designed to eliminate loading screens and create seamless player experiences. While Morrowind is the primary use case, the architecture should support any game with discrete interior spaces connected to open-world exteriors.

### Goals
- **Seamless transitions:** No visible loading screens or freezes
- **Performance:** Maintain 60+ FPS during transitions
- **Flexibility:** Support multiple transition styles (fade, portal, instant)
- **Generality:** Work beyond Morrowind (modern games, procedural worlds, etc.)
- **Memory efficiency:** Keep memory footprint reasonable (< 200MB overhead)

### Key Challenges
1. **Morrowind's architecture:** Binary interior/exterior cell distinction
2. **Asynchronous loading:** Hiding load times without blocking gameplay
3. **Spatial coherence:** Maintaining player orientation and nearby geometry
4. **Occlusion:** Efficiently rendering both spaces when visible simultaneously

---

## Industry Analysis

### 1. Games That Do It Right

#### **The Witcher 3: Wild Hunt - Umbra 3 Streaming System**

**What they achieved:** True seamless transitions - players walk into buildings, bars, and interiors with **zero loading screens**. Only fast travel and game start/death have loads.

**Technical implementation:**
- **Umbra 3 visibility system** integrated into REDengine 3 ([GDC Talk: "Solving Visibility and Streaming in The Witcher 3"](https://www.gdcvault.com/play/1020231/Solving-Visibility-and-Streaming-in))
- **Background streaming:** REDengine 3's "advanced streaming load system" silently loads new environments during gameplay
- **Portal-based occlusion culling:** Pre-computed visibility graphs for indoor scenes
- **Independent world blocks** matched at borders for seamless stitching
- **Dynamic LOD system:** Developed specifically for TW3's massive world scale

**Why it matters:** The world feels completely continuous - entering a tavern or shop requires no mental reset. CD Projekt Red explicitly stated their goal was to "keep players in the world" without loading interruptions taking them out of the adventure.

**Relevance to Morrowind:** Direct parallel - discrete interiors (houses, guilds) connected to open exteriors, similar cell-based structure but with invisible streaming instead of loading screens.

Sources: [GDC Vault - Witcher 3 Umbra 3](https://www.gdcvault.com/play/1020231/Solving-Visibility-and-Streaming-in), [PC Gamer - Witcher 3 Tech](https://www.pcgamer.com/the-amazing-technology-of-the-witcher-3/), [No Loading Screens](https://www.pcgamesn.com/the-witcher-3-wild-hunt/the-witcher-3-does-away-with-pesky-loading-screens)

---

#### **World of Warcraft - Portal-Based WMO System**

**What they achieved:** Seamless building entries since 2004 - players walk through doorways into inns, shops, dungeons with no loading screens (compared to Skyrim/Oblivion from the same era which had loads).

**Technical implementation:**
- **WMO files (World Map Objects):** Buildings stored as separate geometry with embedded portal data
- **Portal occlusion culling:** Polygon planes (usually quads) at doorways/entrances define separation between interior/exterior "groups"
- **Portal crossing detection:** When player crosses portal plane, visibility toggles - interior becomes visible, exterior culled (or vice versa)
- **Maximum 128 portals per WMO** (hardcoded limit)
- **Prebaked lighting:** Interior vertex colors calculated offline, no runtime lighting transitions needed
- **Flying support:** Complex portal calculations when flying through arch-shaped portals (e.g., gryphon into Ironforge)

**Portal structure:**
```
Portal {
    start_vertex: int
    vertex_count: int (usually 4 for quads)
    plane_equation: Vector4  // Used for "which side is player on?"
}
```

**Why it matters:** This is the **classic portal rendering approach** - proven over 20+ years, works on low-end hardware, extremely memory efficient.

**Relevance to Morrowind:** Door frames in Morrowind cells could be converted to portals. When player crosses threshold, toggle visibility and optionally trigger cell streaming.

Sources: [WoW WMO Technical Docs](https://wowdev.wiki/WMO), [WMO Rendering Details](https://wowdev.wiki/WMO/Rendering), [Portal Culling Algorithm](https://github.com/lpiwowar/portal-culling)

---

#### **General Industry Techniques**

From analysis of modern open-world games (Elden Ring, Genshin Impact, RDR2 caves/mines):

**Level Streaming with Trigger Volumes:**
- Place trigger volume (Area3D in Godot) at building entrance
- When player enters trigger, automatically load interior sublevel
- When player exits trigger, unload interior and reload exterior
- **Asynchronous loading on separate thread** while main thread handles rendering
- **Pre-streaming:** Anticipate player movement, load likely destinations proactively

**Occlusion Culling:**
- Only render objects visible to player
- Critical for complex indoor environments (buildings, caves)
- Can reduce GPU load by 50-80% in occluded scenes

**Performance strategy:**
- Time-budget async loading to prevent frame spikes
- Use lower-detail proxies/LODs for distant interiors
- Stream in texture mipmaps progressively

Sources: [Level Streaming Guide](https://www.wayline.io/blog/level-streaming-massive-game-worlds), [Medium - Level Streaming](https://medium.com/@business.sebastian1524/level-streaming-in-open-world-games-revolutionizing-immersive-experiences-0afdd8ffed88), [Occlusion Culling](https://www.numberanalytics.com/blog/ultimate-guide-occlusion-culling)

---

### 2. Games That Don't Do It Well (Learn What NOT to Do)

#### **Bethesda Games (Skyrim, Starfield) - The Anti-Pattern**

**Problem:** Hard loading screens between ALL cells, even small interiors
- Skyrim (2011): 3-10 second loads entering houses
- Starfield (2023): Still has loading screens despite "next-gen" claims

**Why it fails:** Creation Engine treats interiors as completely separate "worlds" - full scene unload/reload required

**Modding workarounds:**
- "Open Cities Skyrim" / "Seamless City Interiors" (Starfield)
- **Trick:** Mark interior cells as exterior cells in engine data
- **Problems:** Crashes, lighting bugs, memory issues, all objects always loaded

**Lesson:** Retrofitting seamlessness into an engine designed for loading screens is unstable. Better to design for it from the start.

Sources: [Starfield Seamless Mod Issues](https://www.pcgamesn.com/starfield/seamless-city-travel-mod), [Creation Engine Problems](https://screenrant.com/starfield-loading-screens-problem-creation-engine-open-universe/)

---

#### **GTA V / Red Dead Redemption 2**

**Surprising finding:** Despite being acclaimed open-world games, they **don't do seamless building interiors natively**.

- Most building interiors are locked or separate instances
- "Open All Interiors" mods exist to unlock content hidden in files
- Interior spaces used in missions often aren't accessible in free roam

**Lesson:** Even Rockstar doesn't solve this perfectly - they prioritize other aspects (physics, NPC AI) over interior streaming.

Sources: [GTA V Seamless Interiors Mod](https://wccftech.com/gta-mod-enables-seamless-buildings-interiors-loading/), [RDR2 Open Interiors](https://allmods.net/red-dead-redemption-2/scripts/open-all-interiors/)

---

### 3. Proven Techniques Summary

| Technique | Use Case | Pros | Cons |
|-----------|----------|------|------|
| **Portal rendering** | Visible interiors from exterior | Exact visibility, efficient | Requires convex portals, pre-computation |
| **Fade transitions** | Completely hidden loads | Simple, universal, hides latency | Immersion break, player can't see destination |
| **Proxy geometry** | Distant interiors | Cheap, pre-baked | Not seamless, pop-in artifacts |
| **Streaming zones** | Open world with trigger areas | Predictive loading, smooth | Requires spatial coherence |
| **Dual-space rendering** | Simultaneous interior + exterior | True seamless, no tricks | High memory, complex culling |

---

### 5. Key Takeaways for Godotwind

Based on successful implementations in The Witcher 3 and World of Warcraft, here's what we should adopt:

#### **Hybrid Approach: Trigger-Based Streaming + Optional Portals**

**Phase 1 - Trigger-based streaming (like Witcher 3):**
1. Place Area3D triggers at door entrances (2-5m radius)
2. When player approaches door, **pre-stream interior in background** (Witcher 3 approach)
3. When player activates door (E key), either:
   - **Option A:** Fade transition while completing load (1-2 seconds)
   - **Option B:** If already loaded, instant transition
4. Unload exterior cells to free memory (keep 1 cell for quick exit)
5. When exiting, reverse process

**Phase 2 - Portal rendering (like WoW):**
1. Create portal plane at doorway (quad mesh with portal script)
2. Detect when player crosses portal plane (using Area3D or raycast)
3. Toggle interior/exterior visibility based on camera side of portal
4. Optionally render interior through doorway using SubViewport
5. No loading screen needed - both spaces stay loaded simultaneously

**Why this hybrid works:**
- **Trigger-based** is simple, works for all doors, handles memory well
- **Portal-based** is advanced, works for "showpiece" locations (guild halls, important buildings)
- Both use the same underlying cell management system
- Can mix-and-match: triggers for common doors, portals for special ones

#### **Recommended Approach for Morrowind**

**Start with Trigger + Fade (Witcher 3 style):**
- Morrowind has **hundreds of small interiors** (houses, shops) - can't keep all loaded
- Pre-streaming gives players instant transitions if interior loads fast enough
- Fade fallback ensures smooth experience even on slow systems
- Memory efficient - unload exterior while in interior

**Later add Portal option for key locations:**
- Guild halls (Mages Guild, Fighters Guild)
- Major shops (Creeper, Mudcrab Merchant)
- Player homes
- These are "destination" locations where seeing inside adds value

**Why NOT full portal rendering everywhere:**
- Morrowind interiors aren't spatially coherent with exteriors (deliberate design)
- Interior is often larger than exterior suggests ("bigger on the inside")
- Double memory cost for all active portals
- Most doors aren't visible simultaneously (narrow streets)

---

### 6. Godot 4 Capabilities & Limitations

#### **Strengths**
- **Background loading:** `ResourceLoader.load_threaded_request()` for async scene loading ([Godot Docs](https://docs.godotengine.org/en/stable/tutorials/io/background_loading.html))
- **Scene instancing:** Lightweight Node3D hierarchy, fast add_child/remove_child
- **VisualServer (RenderingServer):** Direct GPU control for occlusion, frustum culling
- **Area3D triggers:** Built-in collision detection for proximity-based loading

#### **Limitations**
- **No built-in streaming:** Community proposals for `StreamingScene` node exist ([godot-proposals#2889](https://github.com/godotengine/godot-proposals/issues/2889)) but not yet implemented
- **Manual LOD:** No automatic Nanite-like system
- **Occlusion culling:** Basic frustum only, no portal system out-of-box

#### **Best Practices**
- **Modular scenes:** Small, reusable PackedScenes ([GDQuest Scene Transitions](https://www.gdquest.com/tutorial/godot/2d/scene-transition-rect/))
- **Scene caching:** Keep recently-used scenes in memory ([Toxigon Scene Management](https://toxigon.com/godot-4-best-practices-for-scene-management))
- **Transition effects:** ColorRect fade with SceneTree.change_scene_to() ([Shaggy Dev](https://shaggydev.com/2022/06/13/godot-scene-transitions/))

---

## Current Morrowind Architecture

### Cell Structure
```gdscript
# Cell distinction (src/core/esm/records/cell_record.gd)
func is_interior() -> bool:
    return (flags & ESMDefs.CELL_INTERIOR) != 0

# Interior cells: Identified by name (String)
var interior = ESMManager.get_cell("Balmora, Guild of Mages")

# Exterior cells: Identified by grid (Vector2i)
var exterior = ESMManager.get_exterior_cell(-2, -9)
```

**Key properties:**
- **Cell size:** 8192 game units ≈ 117 meters
- **Interior lighting:** Per-cell ambient, sunlight, fog colors
- **Exterior lighting:** Global weather system
- **Quasi-exteriors:** Interiors that render sky (e.g., courtyards)

### Door/Teleport Data
```gdscript
# Door instances have teleport metadata (src/core/esm/records/cell_reference.gd)
class CellReference:
    var teleport_pos: Vector3    # DODT - destination position
    var teleport_rot: Vector3    # DODT - destination rotation
    var teleport_cell: String    # DNAM - destination cell name
    var is_teleport: bool        # True if door has destination
```

**Status:** Door data is **parsed but unused**. No interaction system exists.

### Streaming System
```gdscript
# Current streaming manager (src/components/world_streaming_manager.gd)
WorldStreamingManager
├── _loaded_cells: Dictionary          # Vector2i -> Node3D
├── _loading_cells: Dictionary         # Vector2i -> bool (async)
├── _last_camera_cell: Vector2i        # Current exterior cell
└── process_async_instantiation()      # Time-budgeted (3ms/frame)

# Loading
CellManager.request_cell_async(cell_name: String, callback: Callable)
```

**Limitations:**
1. **Exterior-only tracking:** Interior cells not tracked by `_last_camera_cell`
2. **No door triggers:** Player can't interact with doors
3. **Grid-based streaming:** Interior cells don't fit radius-based queries
4. **No transition UI:** Instant cell swaps with no feedback

**Opportunities:**
1. ✅ Async loading infrastructure exists
2. ✅ Object pooling for fast unload/reload
3. ✅ Time-budgeted instantiation prevents frame drops
4. ✅ Door teleport data already parsed and available

---

## Proposed Framework

### Design Principles
1. **Separation of concerns:** Transition logic ≠ cell loading ≠ rendering
2. **State machine:** Clear states (EXTERIOR, TRANSITION_IN, INTERIOR, TRANSITION_OUT)
3. **Plugin architecture:** Modular transition styles (fade, portal, instant)
4. **Event-driven:** Signals for door activation, load completion, player repositioning
5. **Performance budget:** 3ms/frame for background work, < 100ms for critical path

---

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    TransitionManager                        │
│  - State machine (EXTERIOR ↔ TRANSITION ↔ INTERIOR)       │
│  - Coordinates loading, rendering, player movement          │
└─────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
┌──────────────────┐ ┌──────────────────┐ ┌─────────────────┐
│  DoorInteraction │ │ StreamingContext │ │ TransitionStyle │
│  - Area3D zones  │ │ - Cell queuing   │ │ - Fade plugin   │
│  - Player input  │ │ - Memory mgmt    │ │ - Portal plugin │
│  - Door signals  │ │ - LOD tiers      │ │ - Instant plugin│
└──────────────────┘ └──────────────────┘ └─────────────────┘
```

---

### Core Components

#### 1. **TransitionManager** (Singleton)
**Responsibilities:**
- Track current space type (interior/exterior)
- Handle door activation events
- Coordinate async cell loading
- Manage player repositioning
- Invoke transition styles

**State Machine:**
```
EXTERIOR ──[door_activated]──> TRANSITION_TO_INTERIOR
    ↑                                    │
    │                          [load_complete]
    │                                    ▼
    └──[door_activated]──────── INTERIOR
```

**API:**
```gdscript
class TransitionManager extends Node:
    signal transition_started(from: SpaceType, to: SpaceType)
    signal transition_completed(space: SpaceType)
    signal door_activated(door_ref: CellReference)

    enum SpaceType { EXTERIOR, INTERIOR, QUASI_EXTERIOR }
    enum State { IDLE, LOADING, TRANSITIONING }

    var current_space: SpaceType = SpaceType.EXTERIOR
    var current_state: State = State.IDLE
    var transition_style: TransitionStyle  # Plugin

    func activate_door(door_ref: CellReference) -> void:
        # 1. Determine destination space type
        # 2. Start transition style (fade, portal, etc.)
        # 3. Queue cell load (priority)
        # 4. Wait for load completion
        # 5. Reposition player
        # 6. Complete transition

    func set_transition_style(style: TransitionStyle) -> void
```

---

#### 2. **DoorInteractionSystem** (Component)
**Responsibilities:**
- Add Area3D collision zones to door objects
- Detect player proximity (e.g., 2m radius)
- Emit door activation signals on interaction (E key press)

**Integration:**
```gdscript
# Added to ReferenceInstantiator during door creation
func _create_door_trigger(door_node: Node3D, ref: CellReference) -> void:
    if not ref.is_teleport:
        return  # Not a transition door

    var area = Area3D.new()
    var collision = CollisionShape3D.new()
    var shape = SphereShape3D.new()
    shape.radius = 2.0  # 2 meter activation range

    collision.shape = shape
    area.add_child(collision)
    door_node.add_child(area)

    # Store reference data for activation
    area.set_meta("door_reference", ref)
    area.body_entered.connect(_on_player_near_door)

func _on_player_near_door(body: Node3D) -> void:
    if body.is_in_group("player"):
        # Show UI prompt: "Press E to enter"
        _show_interaction_prompt()
```

**User input:**
```gdscript
# In player controller
func _unhandled_input(event: InputEvent) -> void:
    if event.is_action_pressed("interact"):  # E key
        var nearby_door = _get_nearby_door()
        if nearby_door:
            TransitionManager.activate_door(nearby_door)
```

---

#### 3. **StreamingContext** (Data Structure)
**Responsibilities:**
- Track which cells to keep loaded during transitions
- Manage memory budget (e.g., max 2 cells: 1 interior + 1 exterior)
- Prioritize cell load requests (transitions = high priority)

**Design:**
```gdscript
class StreamingContext:
    var active_interior: String = ""  # Current interior cell name
    var active_exterior: Vector2i = Vector2i(0, 0)  # Current exterior grid
    var transition_target: Variant = null  # String or Vector2i

    var memory_budget_mb: int = 200
    var max_concurrent_cells: int = 2  # Interior + 1 exterior cell

    func enter_interior(cell_name: String, keep_exterior: bool = false) -> void:
        active_interior = cell_name
        if not keep_exterior:
            # Unload all exterior cells except player's last cell
            _unload_exterior_cells(except_cell = active_exterior)

    func exit_interior(destination_exterior: Vector2i) -> void:
        active_interior = ""
        # Unload interior, reload exterior from pool
        _unload_interior_cell()
        _reload_exterior_cells(center = destination_exterior)
```

**Memory strategy:**
- **During transition:** Keep both spaces loaded (brief memory spike)
- **After transition:** Unload previous space via object pool
- **LRU cache:** Recently-exited interiors stay pooled (fast re-entry)

---

#### 4. **TransitionStyle** (Plugin Interface)
**Responsibilities:**
- Define how transitions appear visually
- Control timing (fade duration, portal render, etc.)
- Support multiple implementations

**Interface:**
```gdscript
class TransitionStyle extends RefCounted:
    signal style_started()
    signal style_completed()

    # Override in subclasses
    func start_transition(context: TransitionContext) -> void:
        pass

    func update(delta: float) -> void:
        pass

    func is_complete() -> bool:
        return true
```

**Built-in styles:**

##### **a) FadeTransition**
- Screen fades to black (1 second)
- Cell loads during fade
- Player repositioned
- Fade in from black (1 second)
- **Total:** ~2 seconds

```gdscript
class FadeTransition extends TransitionStyle:
    var fade_shader: ColorRect  # Fullscreen quad
    var fade_duration: float = 1.0
    var elapsed: float = 0.0

    func start_transition(context: TransitionContext) -> void:
        fade_shader.modulate.a = 0.0
        var tween = create_tween()
        tween.tween_property(fade_shader, "modulate:a", 1.0, fade_duration)
        tween.finished.connect(_on_fade_out_complete)

    func _on_fade_out_complete() -> void:
        # Trigger cell load + player repositioning
        context.load_destination_cell()
        context.reposition_player()

        # Fade in
        var tween = create_tween()
        tween.tween_property(fade_shader, "modulate:a", 0.0, fade_duration)
        tween.finished.connect(style_completed.emit)
```

##### **b) PortalTransition** (Advanced)
- Render destination cell through doorway
- Player steps through (no fade)
- Requires portal rendering system (see below)

```gdscript
class PortalTransition extends TransitionStyle:
    var portal_renderer: PortalRenderer

    func start_transition(context: TransitionContext) -> void:
        # Start loading destination cell
        context.preload_destination_cell()

        # Create portal viewport rendering destination
        portal_renderer.set_destination_cell(context.destination_cell)
        portal_renderer.visible = true

    func update(delta: float) -> void:
        # When player crosses portal plane, complete transition
        if portal_renderer.player_crossed_threshold():
            context.reposition_player()
            portal_renderer.visible = false
            style_completed.emit()
```

##### **c) InstantTransition**
- No visual effect
- Immediate cell swap
- **Use case:** Fast travel, console commands, debugging

```gdscript
class InstantTransition extends TransitionStyle:
    func start_transition(context: TransitionContext) -> void:
        context.load_destination_cell()  # Blocking load (acceptable for instant)
        context.reposition_player()
        style_completed.emit()
```

---

### Advanced Feature: Portal Rendering

**Goal:** Render interior through doorway before entering (true seamless)

**Architecture:**
```
DoorFrame (Node3D)
├── PortalViewport (SubViewport)
│   └── DestinationCellInstance (Node3D)  # Loaded async
├── PortalQuad (MeshInstance3D)            # Textured with viewport
└── OcclusionArea (Area3D)                 # Cull when not visible
```

**Process:**
1. **Pre-loading:** When player is within 10m of door, start loading destination cell
2. **Portal activation:** When within 5m, attach loaded cell to SubViewport
3. **Rendering:** SubViewport camera matches door's view frustum
4. **Culling:** If door is off-screen, disable SubViewport rendering (save GPU)
5. **Crossing:** When player crosses portal plane, perform instant space swap

**Performance:**
- **Cost:** 1 additional camera + render pass (expensive)
- **Optimization:** Reduce SubViewport resolution (e.g., 512x512 for distant portals)
- **Budget:** Max 2-3 active portals simultaneously

**Godot implementation:**
```gdscript
func _create_portal(door_node: Node3D, destination_cell: Node3D) -> void:
    var viewport = SubViewport.new()
    viewport.size = Vector2i(512, 512)  # Lower res for performance
    viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

    var camera = Camera3D.new()
    camera.transform = door_node.transform  # Match door orientation
    viewport.add_child(camera)
    viewport.add_child(destination_cell)

    # Create quad to display viewport texture
    var quad = MeshInstance3D.new()
    var material = StandardMaterial3D.new()
    material.albedo_texture = viewport.get_texture()
    quad.set_surface_override_material(0, material)

    door_node.add_child(viewport)
    door_node.add_child(quad)
```

---

### The Window Problem: Seeing Outside from Inside

**The Challenge:** Windows are one of the hardest unsolved problems in seamless interiors. If portals work bidirectionally (you can see in from outside), you should also be able to see out from inside - but this is **extremely difficult** to implement properly.

#### **Why Windows Are Hard**

1. **Multiple render passes:** Each window = 1 SubViewport = 1 extra camera render
   - A room with 4 windows = 4 additional render passes
   - Building with 20 rooms × 4 windows each = 80 render passes (impossible)

2. **Spatial incoherence:** Morrowind interiors are **not** positioned where they appear to be
   - Interior is often larger than exterior ("bigger on the inside")
   - Interior may be rotated/offset from exterior door location
   - No canonical "correct" view to show through windows

3. **Dynamic exteriors:** What if exterior cell isn't loaded while you're inside?
   - Need to keep exterior loaded (memory cost)
   - Or show outdated/frozen view (breaks immersion)
   - Or fake it (see solutions below)

#### **Industry Solutions: How Games Handle Windows**

| Game | Approach | Details | Quality |
|------|----------|---------|---------|
| **World of Warcraft (2025)** | **Fake/No windows** | Housing windows are "frosted over", can't see outside. Players use skybox textures on walls to fake outdoor views | ⭐ Poor |
| **GTA San Andreas** | **No windows** | Interiors teleported to sky, windows show void or have curtain textures | ⭐ Poor |
| **GTA V** | **Curtains + Emissive** | Windows use curtain textures and emissive lighting to hide mismatch. Portals/occlusions block rendering | ⭐⭐ Acceptable |
| **Spider-Man (PS4/5)** | **Interior Mapping** | Shader-based fake interiors - raycast trick, no actual geometry. Perspectively correct but not real | ⭐⭐⭐⭐ Good |
| **Modern Games (General)** | **Cubemap/Skybox** | Baked cubemap texture shows static view of exterior. Low overhead, high quality, but not dynamic | ⭐⭐⭐ Good |
| **True Portal (Rare)** | **Real-time render** | Actually render exterior through window. Only viable for 1-2 showcase windows | ⭐⭐⭐⭐⭐ Excellent |

Sources: [WoW Housing Windows](https://us.forums.blizzard.com/en/wow/t/can-we-look-outside-of-our-houses-through-windows/2183637), [GTA Interior Techniques](https://gta.fandom.com/wiki/Hidden_Interiors_Universe), [Interior Mapping](https://www.gamedeveloper.com/programming/interior-mapping-rendering-real-rooms-without-geometry), [Cubemap Windows](https://www.artstation.com/artwork/W290vD)

#### **Recommended Solutions for Godotwind**

##### **Option 1: Fake Static Windows (Recommended for Most Interiors)**

Use pre-baked cubemap textures on window surfaces:

```gdscript
func _create_fake_window(window_mesh: MeshInstance3D, exterior_cell: Vector2i) -> void:
    # Render exterior view to cubemap at build/bake time
    var cubemap = _bake_exterior_cubemap(exterior_cell)

    # Apply to window material
    var mat = StandardMaterial3D.new()
    mat.albedo_texture = cubemap
    mat.emission_enabled = true
    mat.emission_energy = 0.3  # Slight glow for realism
    window_mesh.material_override = mat
```

**Pros:**
- Near-zero runtime cost
- Looks good for static exteriors
- Works even when exterior cell unloaded

**Cons:**
- Not dynamic (weather/time of day frozen)
- Pre-computation required
- Doesn't match current exterior state

##### **Option 2: Skybox/Generic View (Cheapest)**

Use generic sky texture or solid color:

```gdscript
func _create_skybox_window(window_mesh: MeshInstance3D, cell: CellRecord) -> void:
    var mat = StandardMaterial3D.new()

    if cell.is_quasi_exterior():
        # Show actual sky
        mat.albedo_texture = world_sky_texture
    else:
        # Solid color or generic outdoor texture
        mat.albedo_color = Color(0.6, 0.7, 0.9)  # Light blue
        mat.emission_enabled = true
        mat.emission_energy = 0.5

    window_mesh.material_override = mat
```

**Pros:**
- Instant, no pre-baking
- Minimal memory/CPU cost
- Works for all interiors

**Cons:**
- Not realistic
- Same view for all windows
- No sense of location

##### **Option 3: Interior Mapping Shader (Advanced)**

Shader trick that raycasts fake geometry - see [Interior Mapping technique](https://80.lv/articles/interior-mapping-rendering-real-rooms-without-geometry):

```gdscript
# Custom shader for windows
shader_type spatial;

uniform sampler2D room_texture;
uniform vec3 room_size = vec3(4.0, 3.0, 4.0);  // Interior room dimensions

void fragment() {
    // Raycast from camera through window surface
    vec3 ray_dir = normalize(VIEW);

    // Intersect with fake room bounds
    // ... (complex shader math here)

    ALBEDO = texture(room_texture, fake_uv).rgb;
}
```

**Pros:**
- Perspectively correct depth
- Looks real from any angle
- Low geometry cost

**Cons:**
- Complex shader development
- Still not truly dynamic
- Doesn't match actual exterior

##### **Option 4: True Portal Windows (Showcase Only)**

For 1-2 special interiors (e.g., Telvanni towers, Guild of Mages observatory):

```gdscript
func _create_portal_window(window_node: Node3D, exterior_cell: Vector2i) -> void:
    # Same as door portal, but always active
    var viewport = SubViewport.new()
    viewport.size = Vector2i(256, 256)  # Lower res than doors

    var camera = Camera3D.new()
    # Position camera to look at exterior
    camera.global_position = window_node.global_position
    camera.rotation = window_node.rotation

    # Add exterior cell to viewport
    var exterior_scene = await load_exterior_cell(exterior_cell)
    viewport.add_child(camera)
    viewport.add_child(exterior_scene)

    # Apply to window material
    var mat = StandardMaterial3D.new()
    mat.albedo_texture = viewport.get_texture()
    window_node.get_child(0).material_override = mat
```

**Performance budget:** Max 2 portal windows per scene (4-6ms per window)

**Pros:**
- True real-time view
- Fully dynamic (weather, time, NPCs)
- Actual bidirectional portal

**Cons:**
- Very expensive (5-10ms per window)
- Requires exterior stay loaded
- Only viable for handful of locations

---

#### **Hybrid Strategy for Morrowind**

**Tier 1 - Generic windows (90% of interiors):**
- Small houses, shops: **Skybox/solid color** (Option 2)
- Cost: ~0ms, instant

**Tier 2 - Atmospheric windows (9% of interiors):**
- Guild halls, manor houses: **Pre-baked cubemap** (Option 1)
- Cost: Pre-computation, ~0.1ms runtime

**Tier 3 - Showcase windows (1% of interiors):**
- Tel Fyr exterior view, Guild of Mages observatory: **True portal** (Option 4)
- Cost: 5-10ms per window, max 2 simultaneously

**Why NOT everywhere:**
- Most Morrowind interiors are windowless or have tiny slits
- Players rarely stare out windows for long periods
- Better to spend performance budget on other features (AI, physics, particles)

#### **Implementation Notes**

1. **Window detection:** During cell load, identify objects with "window" in name or specific texture
2. **Auto-assignment:** Apply tier based on cell importance (script or manual tagging)
3. **Fallback:** If performance drops, disable portal windows and use cubemap fallback
4. **User setting:** "Window Quality" option (Low=skybox, Medium=cubemap, High=portal)

---

### Morrowind-Specific Adaptations

#### **1. Cell Type Detection**
```gdscript
func _get_space_type(cell_id: Variant) -> TransitionManager.SpaceType:
    var cell: CellRecord

    if cell_id is String:
        cell = ESMManager.get_cell(cell_id)
    elif cell_id is Vector2i:
        cell = ESMManager.get_exterior_cell(cell_id.x, cell_id.y)

    if cell.is_interior():
        if cell.is_quasi_exterior():
            return SpaceType.QUASI_EXTERIOR  # Render sky
        return SpaceType.INTERIOR
    return SpaceType.EXTERIOR
```

#### **2. Lighting Transitions**
- **Interior → Exterior:** Fade from cell ambient light to global DirectionalLight3D
- **Exterior → Interior:** Apply cell's ambient_color, sunlight_color, fog_density

```gdscript
func _apply_interior_lighting(cell: CellRecord) -> void:
    var env = get_viewport().world_3d.environment
    env.ambient_light_color = cell.ambient_color
    env.ambient_light_energy = 0.5

    # Disable global sun for true interiors
    if not cell.is_quasi_exterior():
        world_sun.visible = false

    # Apply fog
    env.fog_enabled = true
    env.fog_density = cell.fog_density
    env.fog_light_color = cell.fog_color
```

#### **3. Exterior Cell Radius Management**
- **While in interior:** Reduce exterior streaming radius to 1 cell (save memory)
- **When exiting:** Restore full radius (e.g., 3 cells) before transition completes

```gdscript
func _on_enter_interior(cell_name: String) -> void:
    # Reduce exterior streaming to just player's last cell
    WorldStreamingManager.set_view_distance_override(1)  # 1 cell radius
    WorldStreamingManager.unload_distant_cells()

func _on_exit_interior(exterior_pos: Vector3) -> void:
    # Restore normal exterior streaming before player sees it
    WorldStreamingManager.set_view_distance_override(-1)  # Reset to default
    WorldStreamingManager.preload_cells_around_position(exterior_pos)
```

#### **4. Door Pairing (Bi-directional)**
Morrowind doors are **unidirectional** in ESM data. Need to infer reverse teleport:

```gdscript
# Build reverse lookup during cell load
var _door_reverse_map: Dictionary = {}  # destination -> source

func _register_door(door_ref: CellReference, source_cell: String) -> void:
    if not door_ref.is_teleport:
        return

    var dest_key = "%s|%v" % [door_ref.teleport_cell, door_ref.teleport_pos]
    _door_reverse_map[dest_key] = {
        "cell": source_cell,
        "pos": door_ref.translation,  # Original door position
        "rot": door_ref.rotation
    }

func _find_exit_door(current_cell: String, player_pos: Vector3) -> CellReference:
    var key = "%s|%v" % [current_cell, player_pos.snapped(Vector3.ONE * 0.1)]
    if _door_reverse_map.has(key):
        return _door_reverse_map[key]
    return null  # Fallback: teleport to exterior cell center
```

---

## Implementation Roadmap

### Phase 1: Foundation (Week 1-2)
**Goal:** Basic fade transitions working

- [ ] Create `TransitionManager` singleton
- [ ] Implement `FadeTransition` style
- [ ] Add `DoorInteractionSystem` to `ReferenceInstantiator`
- [ ] Modify `WorldStreamingManager` to support interior/exterior mode
- [ ] Add player input handling for door activation
- [ ] Test: Enter/exit Balmora interiors with fade

**Deliverable:** Working fade transitions for 5 test interiors

---

### Phase 2: Optimization (Week 3-4)
**Goal:** Performance and memory efficiency

- [ ] Implement `StreamingContext` with memory budget
- [ ] Add LRU cache for recently-exited interiors
- [ ] Priority queue for transition cell loads
- [ ] Reduce exterior streaming radius while in interior
- [ ] Profile memory usage (target: < 200MB overhead)
- [ ] Test: Rapid door cycling (stress test)

**Deliverable:** Stable transitions with < 100MB memory overhead

---

### Phase 3: Visual Polish (Week 5-6)
**Goal:** Lighting and atmosphere transitions

- [ ] Implement interior lighting application (ambient, fog)
- [ ] Smooth lighting transitions (1-second lerp)
- [ ] Quasi-exterior support (sky rendering in courtyards)
- [ ] Door reverse lookup (bi-directional teleport)
- [ ] Test: All cell types (interior, exterior, quasi-exterior)

**Deliverable:** Visually correct transitions matching Morrowind's atmosphere

---

### Phase 4: Advanced Features (Week 7-8)
**Goal:** Portal rendering and seamless mode

- [ ] Implement `PortalTransition` style
- [ ] SubViewport-based portal rendering
- [ ] Pre-loading when near doors (10m radius)
- [ ] Occlusion culling for off-screen portals
- [ ] Portal crossing detection (Area3D threshold)
- [ ] Test: Performance with 3 active portals

**Deliverable:** Optional portal mode for high-end systems

---

### Phase 5: Generalization (Week 9-10)
**Goal:** Framework usable beyond Morrowind

- [ ] Extract Morrowind-specific code to adapter pattern
- [ ] Create `ISpaceProvider` interface for cell queries
- [ ] Document plugin architecture for custom transition styles
- [ ] Example: Procedural dungeon with room-to-room transitions
- [ ] Example: Modern city with apartment interiors

**Deliverable:** Reusable transition framework + documentation

---

## Performance Considerations

### Memory Budget
| Component | Memory Cost | Notes |
|-----------|-------------|-------|
| Interior cell | 50-100 MB | Depends on object count |
| Exterior cell | 20-50 MB | Terrain + static objects |
| Portal SubViewport | 10-30 MB | 512x512 texture + scene |
| LRU cache (5 interiors) | 100-200 MB | Pooled objects |
| **Total (worst case)** | **~400 MB** | During portal transition |

**Mitigation:**
- Reduce SubViewport resolution for distant portals (256x256)
- Limit LRU cache to 3 most recent interiors
- Unload exterior cells beyond player's last cell while in interior

---

### GPU/CPU Cost
| Operation | Cost | Frequency | Budget |
|-----------|------|-----------|--------|
| Async cell load | 200-500ms | Per transition | Amortized during fade |
| Portal render | 5-10ms | Per frame | Max 3 portals |
| Lighting transition | 1ms | Once per transition | Acceptable |
| Object pooling | < 1ms | Per exit | Negligible |

**Target:** 60 FPS maintained (16.67ms frame budget)

---

### Godot-Specific Optimizations

#### **1. Visibility Layers**
```gdscript
# Assign cells to different render layers
interior_cell.layers = 0b0010  # Layer 2
exterior_cell.layers = 0b0001  # Layer 1

# Portal camera only sees destination layer
portal_camera.cull_mask = 0b0010  # Only interior
main_camera.cull_mask = 0b0001   # Only exterior (during transition)
```

#### **2. LOD Management**
```gdscript
# Reduce LOD for portal-rendered cells
if rendering_through_portal:
    destination_cell.lod_bias = 2.0  # Lower detail
else:
    destination_cell.lod_bias = 1.0  # Full detail
```

#### **3. Background Loading**
```gdscript
# Use Godot's ResourceLoader for async
ResourceLoader.load_threaded_request(cell_scene_path)

# Poll during fade transition
while not ResourceLoader.load_threaded_get_status(cell_scene_path) == ResourceLoader.THREAD_LOAD_LOADED:
    await get_tree().process_frame

var cell_scene = ResourceLoader.load_threaded_get(cell_scene_path)
```

---

## References

### Industry Research
- [Unreal Engine 5 World Partition](https://www.artemisiacollege.com/blog/unreal-engine-5-future-gaming-industry/)
- [Umbra 3D Portal-Based Occlusion Culling](https://medium.com/@Umbra3D/introduction-to-occlusion-culling-3d6cfb195c79)
- [Visualization Library Portal Tutorial](https://visualizationlibrary.org/documentation/pag_guide_portals.html)
- [Starfield Seamless City Interiors Mod](https://www.pcgamesn.com/starfield/seamless-city-travel-mod)
- [Skyrim Open Cities Analysis](https://screenrant.com/starfield-seamless-city-interiors-mod-creation-engine/)

### Godot Documentation
- [Background Loading (Official Docs)](https://docs.godotengine.org/en/stable/tutorials/io/background_loading.html)
- [Scene Management Best Practices](https://toxigon.com/godot-4-best-practices-for-scene-management)
- [Scene Transitions Tutorial](https://www.gdquest.com/tutorial/godot/2d/scene-transition-rect/)
- [Godot Streaming Proposals (GitHub)](https://github.com/godotengine/godot-proposals/issues/2889)

### Codebase Files (Godotwind)
- `src/components/world_streaming_manager.gd` - Cell streaming
- `src/components/cell_manager.gd` - Cell loading
- `src/core/esm/records/cell_record.gd` - Cell data structure
- `src/core/esm/records/door_record.gd` - Door data
- `src/core/esm/records/cell_reference.gd` - Teleport metadata

---

## Appendix: Comparison Matrix

| Approach | Seamlessness | Performance | Complexity | Morrowind Fit |
|----------|--------------|-------------|------------|---------------|
| **Fade transition** | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐⭐⭐ |
| **Portal rendering** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |
| **Instant swap** | ⭐ | ⭐⭐⭐⭐⭐ | ⭐ | ⭐⭐ |
| **Bethesda "trick"** | ⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐ | ⭐ |

**Recommendation:** Start with **fade transitions** (simple, robust), then add **portal rendering** as optional high-end feature.

---

## Open Questions

1. **Weather transitions:** How to handle weather when entering/exiting quasi-exteriors?
2. **Audio:** Should interior ambience fade in during transition, or snap immediately?
3. **NPC pathing:** What if NPC follows player through door? (Morrowind doesn't support this)
4. **Multiplayer:** How would this work in co-op? (Future consideration)
5. **Scripting hooks:** Should mods be able to inject custom transition logic?

---

**End of Document**
