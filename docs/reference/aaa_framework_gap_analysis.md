# Godotwind — AAA Open-World RPG Framework Gap Analysis

**Date:** 2026-04-07. **Reference targets:** RDR2, The Witcher 3, Cyberpunk 2077, Elden Ring, Skyrim SE.

> **Currency note (2026-04-29):** the streaming/rendering rows in this doc are partly superseded — HLOD shipped 2026-04-13, Wins 0-5 (off-thread cell-collision, server-direct cell static body, lazy-spawn lights, server-direct OmniLight3D) shipped 2026-04-25. For the current authoritative streaming+rendering AAA gap analysis, use `docs/audit/godot_46_near_streaming_aaa_audit_2026_04_29_codex.md`. The non-streaming sections (audio, weather, RPG systems, UI, dialogue) remain accurate as a feature inventory.

---

## Status legend

- **SHIPPED** — Working in-engine, integrated into main scene
- **FRAMEWORK** — Code exists, not wired into `scenes/Godotwind.tscn`
- **PARTIAL** — Fragments exist, major holes
- **MISSING** — Nothing in the repo

Effort scale: **S** = days, **M** = 1-3 weeks, **L** = 1-3 months, **XL** = 3+ months.

---

## Standout strengths (don't lose these in planning)

- **Streaming pipeline** — best-in-class for Godot (8 ms shared budget, frustum priority, tier transitions, LRU eviction)
- **Impostor system** — ~63k instances at 5 km in a single draw call
- **NIF/ESM/BSA pipeline** — 47 record types, 132 animations, 629 quests, 574 books parsed
- **Ocean shader** — FFT/flat surface path + Beer-Lambert + caustics
- **Volumetric clouds** — SunshineClouds2 (already integrated)
- **Per-object LOD chains** — prebaked via meshoptimizer in the asset pipeline
- **Dialogue engine** — OpenMW 4-step filter + 74 functions + 24k INFO records, topic cross-refs
- **Profiling infrastructure** — StreamingProfiler + F4 report + BatchDebugHUD + benchmark scene
- **Developer console** — object picking, selection outline, command registry

---

## Decision axes (apply to every gap)

1. **Maintenance** — actively maintained addon (last 12 mo commits, issues addressed)?
2. **Framework-first fit** — does it impose a data model that fights the MW adapter pattern?
3. **Performance envelope** — can it hit 60+ FPS at 100k+ instance scale?
4. **Integration cost vs build cost** — 1 week wiring beats 3 months building, unless wiring debt is permanent
5. **Precedent** — Terrain3D kept (solved a hard problem well, maintained, framework-compatible). Sky3D ditched (abandoned, opaque, fought our needs).

---

# Part 1 — Subsystem Inventory

Detailed feature-by-feature gap tables. Decisions are summarized in Part 2.

## 1. World & Streaming

| Feature | AAA Standard | Godotwind | Status |
|---|---|---|---|
| Seamless open-world streaming | tile/cell/sector, predictive | Async cell loading, 8 ms frame budget, frustum priority | **SHIPPED** |
| Interior/exterior transitions | Seamless or fast-fade, pre-warmed | Async pocket load + fade bridge, ≤6 ms peak | **SHIPPED** |
| Stencil/portal rendering for interiors | Common (TW3, RDR2) | Designed, not built (`PORTAL_SYSTEM.md`) | **MISSING** |
| Distance LOD (3+ tiers) | Yes, often with HLOD cluster merging | 3-tier NEAR/MID/FAR (0-150/150-500/500-5000m) | **SHIPPED** |
| HLOD (hierarchical LOD / mesh merging) | RDR2, TW3, UE5 Nanite proxies | Per-object LODs prebaked via meshoptimizer; cluster-merging not built | **PARTIAL** |
| Impostors (octahedral/billboard) | Engine-provided or proprietary | Custom octahedral system, ~63k instances | **SHIPPED** |
| GPU-driven culling / indirect draw | UE5, Frostbite | Designed, not built | **MISSING** |
| Occlusion culling | PVS, depth prepass, software Hi-Z | Engine outdoor path bug; manual workaround | **PARTIAL** |
| Texture virtual memory / streaming | UE5 VT, RDR2 megatexture | All mips resident, VRAM bound | **MISSING** |
| Spatial query / octree / BVH | Yes | Grid-indexed cells only | **PARTIAL** |

## 2. Rendering & Graphics

| Feature | AAA | Godotwind | Status |
|---|---|---|---|
| PBR materials | Yes | NIF → Godot StandardMaterial3D | **SHIPPED** |
| Global illumination | RT, baked probes, or SDFGI | Engine SDFGI/VoxelGI available; not tuned per biome | **PARTIAL** |
| Screen-space reflections | Yes | Engine SSR + custom in-shader SSR for ocean | **SHIPPED** |
| Screen-space AO | HBAO+, GTAO | Engine SSAO | **SHIPPED** |
| RT shadows / GI / reflections | Next-gen standard | Godot 4.7 gated, no D3D12 RT | **MISSING** |
| Cascaded shadow maps | 4+ cascades | Godot native | **SHIPPED** |
| Contact-hardening / PCSS shadows | Yes | Godot PCF only | **PARTIAL** |
| Volumetric fog + godrays | Physically-based | Fog overhauled, godrays working | **SHIPPED** |
| Volumetric clouds | TW3, RDR2 | SunshineClouds2 plugin | **SHIPPED** |
| Atmospheric scattering | Bruneton/Preetham | Custom sky shader, day/night cycle | **SHIPPED** |
| Tonemap / HDR display output | ACES + HDR10 | Engine tonemap only, no HDR10 | **PARTIAL** |
| Post-FX (bloom, DOF, motion blur, lens flare) | Full stack | Engine subset | **SHIPPED** |
| TAA / DLSS / FSR / XeSS | Standard | Godot TAA + FSR2 | **SHIPPED** |
| Decals | Yes | Engine Decal node | **SHIPPED** |
| Dynamic deformation (snow/mud/ash) | RDR2, Horizon | Custom RTT deformation | **SHIPPED** |
| Bindless textures / texture arrays | Standard since 2016 | Manual Texture2DArray packing only | **PARTIAL** |
| Debug rendering pipeline | Yes | F9 overlay, BatchDebugHUD | **SHIPPED** |

## 3. Terrain

| Feature | AAA | Godotwind | Status |
|---|---|---|---|
| Heightmap terrain with streaming regions | Yes | Terrain3D, multi-region, edge stitching | **SHIPPED** |
| Terrain texture blending (8+ layers) | RDR2 32+ | Terrain3D supports it | **SHIPPED** |
| Terrain holes / caves / overhangs | Limited | Mesh caves only | **PARTIAL** |
| Terrain tessellation / displacement | RDR2, TW3 | Not used | **MISSING** |
| Triplanar projection for cliffs | Yes | Terrain3D supports it | **SHIPPED** |
| Procedural detail meshes (grass/rocks) | Millions instanced | None wired | **MISSING** |
| Grass wind / interaction | TW3 bent, RDR2 footprint | None | **MISSING** |
| Footprints / trail persistence | RDR2 | Deformation RT exists, not wired to feet | **PARTIAL** |

## 4. Weather & Sky

| Feature | AAA | Godotwind | Status |
|---|---|---|---|
| Dynamic sky shader | Yes | Custom modular sky, day/night, stars | **SHIPPED** |
| Weather state machine (sunny/cloudy/rain/storm/snow) | Blended transitions | Sky3D ditched, no replacement | **MISSING** |
| Rain particles + wetness shader | Yes | None | **MISSING** |
| Snow accumulation | RDR2 | Deformation RT exists, no weather trigger | **PARTIAL** |
| Lightning + thunder sync | Yes | None | **MISSING** |
| Ash storms (Morrowind-specific) | N/A | None — critical for MW parity | **MISSING** |
| Weather-audio coupling | Yes | None | **MISSING** |
| Wind direction (grass/cloth/particles) | Yes | None | **MISSING** |

## 5. Water

| Feature | AAA | Godotwind | Status |
|---|---|---|---|
| Ocean waves (FFT/flat) | FFT standard | FFT with flat fallback | **SHIPPED** |
| Refraction + caustics | Yes | Beer-Lambert + refraction UV + custom SSR + caustics | **SHIPPED** |
| Underwater POV | Yes | Shader exists, flat dark POV bug | **PARTIAL** |
| Buoyancy / boat physics | Yes | GPU-readback buoyancy in framework, not wired | **FRAMEWORK** |
| River flow maps | TW3 | None | **MISSING** |
| Waterfalls | Yes | None | **MISSING** |
| Shore foam / wetness transition | Yes | Partial (shore mask sampler) | **PARTIAL** |
| Main-scene integration | Yes | Not in `scenes/Godotwind.tscn` | **FRAMEWORK** |

## 6. Audio

| Feature | AAA | Godotwind | Status |
|---|---|---|---|
| 3D spatialized audio | Yes | AudioStreamPlayer3D unused | **MISSING** |
| Reverb zones / room acoustics | Yes | Godot native unused | **MISSING** |
| Occlusion-based low-pass | Yes | None | **MISSING** |
| Footstep material detection | Yes | None | **MISSING** |
| Dynamic music | Wwise/FMOD tier | None | **MISSING** |
| Dialogue / VO playback | Yes | Text-only | **MISSING** |
| Ambient soundscape | Yes | None | **MISSING** |
| Weather SFX coupling | Yes | None | **MISSING** |

> **Audio is the single largest gap in Godotwind today.**

## 7. Animation & Character

| Feature | AAA | Godotwind | Status |
|---|---|---|---|
| Skeletal animation blending | Yes | AnimationTree state machine (idle/walk/run/jump) | **SHIPPED** |
| Additive upper-body layers | Yes | Stubbed, not wired (A-18/A-19) | **PARTIAL** |
| Root motion | Yes | Parsed, not driving movement | **PARTIAL** |
| IK (foot, look-at, hand) | UE Control Rig / TW3 custom | TwoBoneIK3D plumbed, not wired to character | **FRAMEWORK** |
| Motion matching | RDR2, TLOU2, UE5 MM | None — Phase 6 | **MISSING** |
| Ragdoll / physics animation | Yes | None | **MISSING** |
| Cloth simulation | TW3 Apex, RDR2 custom | None | **MISSING** |
| Hair simulation | TW3 HairWorks | Static hair meshes only | **MISSING** |
| Facial animation / FACS / lip sync | RDR2 tier-defining | Morpher PARSED, not applied (dialogue blocker) | **MISSING** |
| Gaze / eye tracking | Yes | None | **MISSING** |
| Procedural walk slope adaptation | Yes | None | **MISSING** |
| Character LOD (animation tiers) | Yes | Incomplete (A-06 to A-10) | **PARTIAL** |
| NPC body assembly from data | Bespoke AAA | Native MW skeleton, 132 anims, mirrored body parts | **SHIPPED** |

## 8. Navigation / AI

| Feature | AAA | Godotwind | Status |
|---|---|---|---|
| Navmesh generation | Yes | NavigationServer3D available, no per-cell bake | **MISSING** |
| Hierarchical pathfinding | Yes | None | **MISSING** |
| Dynamic obstacle avoidance (RVO) | Yes | Godot native unused | **MISSING** |
| Behavior trees | UE, Beehave | None — Phase 5 | **MISSING** |
| GOAP / utility AI | RDR2, F.E.A.R. | None | **MISSING** |
| NPC daily schedules (Radiant AI) | TES, Gothic, RDR2 | None | **MISSING** |
| Crowd simulation (LOD-tiered) | AC, RDR2 | None | **MISSING** |
| Perception (sight/sound/smell) | Yes | None | **MISSING** |
| Group/faction tactics | Yes | None | **MISSING** |
| AI LOD (near=full BT, far=scripted) | Yes | None — Phase 3 | **MISSING** |

## 9. Combat

| Feature | AAA | Godotwind | Status |
|---|---|---|---|
| Melee (attack/block/dodge/parry) | Yes | None | **MISSING** |
| Ranged (bows, guns) | Yes | None | **MISSING** |
| Magic combat | Yes | None | **MISSING** |
| Damage model (hitbox, armor, resist) | Yes | None | **MISSING** |
| Aim assist / lock-on | Yes | None | **MISSING** |
| Stealth (detection, cover) | Yes | None | **MISSING** |
| Mounted combat | RDR2, TW3 | None | **MISSING** |
| Finishers / contextual kills | Yes | None | **MISSING** |

## 10. RPG Systems

| Feature | AAA | Godotwind | Status |
|---|---|---|---|
| Inventory (weight, slots, stacking) | Yes | None — GLoot candidate | **MISSING** |
| Equipment / paper doll | Yes | None | **MISSING** |
| Character creation (race/class/stats) | Yes | None | **MISSING** |
| Leveling / skills / perks | Yes | None | **MISSING** |
| Magic system (spells, schools, effects) | Yes | None | **MISSING** |
| Alchemy / crafting / enchanting | Yes | None | **MISSING** |
| Economy / merchants | Yes | Framework slot, not built | **MISSING** |
| Reputation / factions | Yes | MW faction data parsed, no runtime | **PARTIAL** |
| Crime / bounty system | Yes | None | **MISSING** |

## 11. Dialogue / Narrative / Quest

| Feature | AAA | Godotwind | Status |
|---|---|---|---|
| Topic-based dialogue | Yes | DialogueUI + MW 4-step filter + 74 fns, 2358 topics, 24k INFO | **SHIPPED** |
| Result script execution | Yes | Parsed, not executed — **blocker** | **PARTIAL** |
| Quest journal | Yes | QuestManager + JournalPanel, 629 MW quests | **SHIPPED** |
| Quest display names | Yes | Raw IDs only | **PARTIAL** |
| Branching narrative (choices matter) | TW3 state-machine | None | **MISSING** |
| Cinematic dialogue camera | Yes | None | **MISSING** |
| Lip sync | Yes | None | **MISSING** |
| Voice over | Yes | None | **MISSING** |
| Subtitles + localization | Yes | None | **MISSING** |
| Main-scene integration | Yes | Only in test scene | **FRAMEWORK** |
| Book reader | TES series | BookViewer, 574 books, BSA images | **SHIPPED** (not integrated) |

## 12. Save / Load

| Feature | AAA | Godotwind | Status |
|---|---|---|---|
| Persistent world state (delta save) | Yes | None — Phase 2 | **MISSING** |
| Quick save / autosave / named slots | Yes | None | **MISSING** |
| Save migration / versioning | Yes | None | **MISSING** |
| Replays / death recorder | Sometimes | None | **MISSING** |

## 13. Input / UI / UX

| Feature | AAA | Godotwind | Status |
|---|---|---|---|
| Action-based input remapping | Yes | Partial — `interact` action added, raw keys elsewhere | **PARTIAL** |
| Controller + haptics | Yes | Godot native available, untuned | **PARTIAL** |
| HUD (health/stamina/minimap/compass) | Yes | None | **MISSING** |
| Main menu / options | Yes | Dev console only | **MISSING** |
| Pause menu | Yes | None | **MISSING** |
| Tutorials / tooltips | Yes | None | **MISSING** |
| Photo mode | RDR2, TW3, HZD | None | **MISSING** |
| Map / fast travel UI | Yes | None | **MISSING** |
| Dialogue panel theme | Yes | Pelagiad + StyleBoxes | **SHIPPED** |
| Accessibility (subs, colorblind, remap, scaling) | Standard since 2020 | None | **MISSING** |
| Localization | Yes | None | **MISSING** |

## 14. Data Pipeline / Modding

| Feature | AAA | Godotwind | Status |
|---|---|---|---|
| Offline asset cooking / prebake | Yes | Full ESM/NIF/BSA prebake | **SHIPPED** |
| Hot reload (shaders/scripts) | Yes | ShaderManager hot-swap | **SHIPPED** |
| Mod loader / load order | TES tradition | ModRegistry RefCounted, asset override layer | **SHIPPED** |
| In-game console / dev tools | Standard | Console, object picking, selection outline | **SHIPPED** |
| Streaming profiler | Yes | StreamingProfiler + Benchmark + F4 | **SHIPPED** |
| Performance HUD | Yes | PerformanceProfiler, BatchDebugHUD, F9 | **SHIPPED** |
| ESS-compatible save format | MW-specific | None | **MISSING** |
| ESP/ESM plugin chain | MW-specific | Parsing yes, no merge/patch | **PARTIAL** |

## 15. Physics

| Feature | AAA | Godotwind | Status |
|---|---|---|---|
| Rigid body | Yes | Jolt | **SHIPPED** |
| Character controller | Yes | Basic FPS, no slope/swim/climb polish | **PARTIAL** |
| Vehicles (horses, carts, boats) | Yes | None | **MISSING** |
| Destruction | Yes | None | **MISSING** |
| Rope / chains / constraints | Yes | Godot native unused | **MISSING** |
| Swimming | Yes | Framework spec, not wired | **PARTIAL** |
| Climbing / mantle | TW3 climb markup | None | **MISSING** |

## 16. VFX / Particles

| Feature | AAA | Godotwind | Status |
|---|---|---|---|
| GPU particles | Yes | GPUParticles3D available, NIF particles parsed | **PARTIAL** |
| Weather particles (rain/snow/ash/pollen) | Yes | None | **MISSING** |
| Magic VFX | Yes | None | **MISSING** |
| Impact VFX (sparks/blood/dust) | Yes | None | **MISSING** |
| Volumetric / fluid sim | UE5 Niagara | None | **MISSING** |

---

# Part 2 — Per-Gap Recommendations (Adopt / Build / Hybrid)

## Critical gaps

### 1. Audio
- **Options:** (a) Godot native (`AudioStreamPlayer3D`, `AudioServer`, built-in reverb/lowpass), (b) Wwise/FMOD GDExtension, (c) hybrid
- **Recommendation:** **Build in-house on Godot native (a)**
- **Rationale:**
  - Godot 4.6 audio is solid (3D spatialization, bus routing, AudioEffectReverb / LowPass, AudioStreamRandomizer). We use almost none of it.
  - Wwise/FMOD GDExtensions exist but introduce closed-source dependency + commercial licensing. Overkill for an MW-faithful framework.
  - Custom layers needed anyway: occlusion via raycasts, footstep material lookup from cell data, weather coupling — all MW-aware, belong in adapter.
- **Architecture:** `src/core/audio/` framework + `src/core/audio/morrowind/` adapter (sound IDs from ESM SOUN/SNDG, BSA WAV streaming).
- **Effort:** M (3D playback + buses + occlusion + footstep + ambient); +M for dynamic music
- **Risks:** WAV streaming from BSA at scene-load — measure cache pressure. Footstep raycasts must be budgeted (not every frame).

### 2. Weather
- **Options:** (a) Godot weather addon, (b) build, (c) hybrid
- **Recommendation:** **Build in-house (b)**
- **Rationale:**
  - **Sky3D precedent applies directly.** No actively maintained Godot weather addon meets quality bar.
  - Custom modular sky already exists — bolting weather state on is cheaper than rip-and-replace.
  - Ash storms are MW-specific and need adapter layer regardless.
- **Architecture:** `src/core/weather/` framework (state machine + transition blender) + `src/core/weather/morrowind/` (region weather tables, ash storms). Couples to: sky, audio, particles, deformation RT (snow), wind buffer (grass/cloth).
- **Effort:** M (state machine + 4 baseline weathers + transitions); +S per additional weather
- **Risks:** Particle perf at high density — GPUParticles3D with attractor zone around player, not global emit.

### 3. Grass / ground cover
- **Options:** (a) **Terrain3D Instancer** (already in repo), (b) ProtonScatter, (c) custom MultiMesh
- **Recommendation:** **Adopt Terrain3D Instancer (a)** with custom wind shader
- **Rationale:**
  - We already own Terrain3D. Instancer handles per-region streaming, density maps, LOD natively.
  - ProtonScatter is editor-time only — no streaming.
  - Custom system would duplicate Terrain3D's region streaming. Reinvention.
  - Wind/interaction shaders are easy to layer on top.
- **Architecture:** Terrain3D Instancer + custom `grass_wind.gdshader` reading the wind buffer weather will write. Footprint deformation reuses existing RT.
- **Effort:** S-M (instancer wiring + wind shader + LOD tuning)
- **Risks:** MultiMesh count vs draw call budget at far ranges — must integrate with MID/FAR tiers. Verify Instancer respects `distance_utils.gd` constants.

### 4. Combat
- **Options:** Build only (no general-purpose combat addon at this scale)
- **Recommendation:** **Build (b)**
- **Rationale:** Game-specific. MW combat formulas (hit chance, weapon skill, fatigue) belong in `morrowind/` adapter.
- **Architecture:** `src/core/combat/` (hitbox, damage, resist) + `src/core/combat/morrowind/` (formulas). Hooks: animation state machine, audio impact SFX, VFX.
- **Effort:** L
- **Risks:** Coupling with animation overhaul (additive upper-body still partial). **Don't start until A-18/A-19 land.**

### 5. Inventory / equipment
- **Options:** (a) **GLoot**, (b) build, (c) hybrid
- **Recommendation:** **Hybrid: GLoot for grid model + custom MW adapter (c)**
- **Rationale:**
  - GLoot is maintained, well-tested, has weight/slot/stack/drag, framework-compatible (Resource-based items).
  - Need MW adapter to map GLoot items → ESM ARMO/WEAP/CLOT/MISC and drive paper doll from BodyPartManager.
- **Architecture:** GLoot under `addons/gloot/`, wrapper in `src/core/inventory/`, `src/core/inventory/morrowind/` mapping ESM → GLoot.
- **Effort:** S-M (S GLoot wiring + S paper doll integration with HumanoidEquipment)
- **Risks:** GLoot UI is barebones — restyle with Pelagiad theme. **Scale spike required:** load full Tribunal+Bloodmoon item set into GLoot, measure load-time/memory. If it chokes, fall back to thin custom item model with GLoot only for the UI grid.

### 6. Save / load
- **Options:** Build only (generic save addons can't handle delta-state for streamed worlds)
- **Recommendation:** **Build (b)**
- **Rationale:** AAA save = delta-from-baseline + cell modification list. Generic addons serialize entire scene trees — wrong for streamed worlds.
- **Architecture:** `src/core/save/` framework — baseline = ESM state, save = delta (modified cells, NPC states, quest flags, inventory diff). Versioned with migration hooks. Godot Resource binary format.
- **Effort:** M
- **Risks:** Couples to every mutable system. **Define schema early** so each new system saves itself from day one (don't bolt on later).

### 7. AI / navmesh / behavior trees
- **Options:** (a) **Beehave + NavigationServer3D**, (b) build, (c) hybrid
- **Recommendation:** **Hybrid (c): Beehave + NavigationServer3D + custom perception/schedule layer**
- **Rationale:**
  - Beehave is the de facto Godot BT addon, maintained, lightweight, doesn't fight Node3D.
  - `NavigationServer3D` + `NavigationRegion3D` is solid post-4.x; per-cell bake on stream-in is the right pattern.
  - Perception, AI LOD, MW Radiant-style schedules are bespoke → `src/core/ai/morrowind/`.
- **Architecture:**
  - `src/core/ai/navigation/` — bake navmesh per cell on async stream-in, frame-budgeted
  - `src/core/ai/perception/` — sight cone + audio events, LOD-aware
  - `src/core/ai/behavior/` — Beehave trees, MW schedule adapter reads ESM AI packages (AIDT/AIWA/AIFO)
  - **AI LOD tiered with NEAR/MID/FAR** — full BT near, scripted at distance
- **Effort:** L
- **Risks:** Navmesh bake competes with the existing **8 ms shared streaming budget** in `cell_manager.gd` (currently split unload/async/instantiate/MID-promotion). **Reserve ~1-2 ms slice for navmesh bake** as part of the design or it starves the existing phases.

### 8. Main-scene integration (dialogue/books/interaction/ocean/water)
- **Options:** Build only — wiring task
- **Recommendation:** **Build (b)** — pure integration sprint
- **Rationale:** Frameworks exist, ship in `tests/visual/test_interaction.tscn`. Lift-and-shift into `scenes/Godotwind.tscn` per `docs/systems/dialogue.md` Phase C carry-forwards.
- **Effort:** S per system, M total
- **Risks:** Autoload ordering, signal lifetime, save/load coupling not yet defined → bolt rough but document touchpoints.
- **Note:** This is the **cheapest morale + validation win** on the list. Resequenced to #2 in the suggested order — it becomes the testbed for everything downstream.

### 9. Facial animation / lip sync
- **Options:** (a) Rhubarb Lip Sync (offline viseme generator), (b) build, (c) hybrid
- **Recommendation:** **Hybrid (c): build morpher driver in-engine, use Rhubarb (or similar) offline as viseme baker when VO arrives**
- **Rationale:**
  - Morpher already parsed — need a driver targeting existing blend shapes from a viseme stream.
  - Rhubarb is mature, MIT-licensed, runs offline `.wav → .json` viseme tracks. Perfect for prebake.
  - Text-only path needs phoneme-from-text generator (espeak-ng → visemes) — built later.
- **Architecture:** `src/core/character/face/` morpher driver + viseme blend layer. Build now without VO; wire Rhubarb in prebaker when VO assets exist.
- **Effort:** M
- **Risks:** MW Morpher data quality varies by NPC. Verify blend-shape names map to a standard viseme set or build a per-NPC retarget.

### 10. HUD / main menu / options
- **Options:** Build only
- **Recommendation:** **Build (b)** with existing `src/core/ui/` Pelagiad theme
- **Rationale:** Game-specific. Theme already shipped — this is layout work, not new infrastructure.
- **Architecture:** `src/core/ui/hud/`, `src/core/ui/menu/`, `src/core/ui/options/`. Reuse `theme/` and StyleBox variations. Options menu drives `SettingsManager`.
- **Effort:** M

---

## Important polish

| # | Gap | Decision | Why | Effort |
|---|---|---|---|---|
| 11 | Cluster-merging HLOD (per-object LOD already SHIPPED via meshoptimizer) | **Build (later)** | Designed in `GPU_DRIVEN_RENDERER.md`. Remaining gap = merge multiple distant objects into proxy mesh to crush draw calls in Balmora/Vivec. No addon. Impostors + per-object LOD already cover most of the win. | L |
| 12 | Volumetric clouds | **Already adopted (SunshineClouds2)** | SHIPPED. Action: couple to weather state machine (#2) so cloud cover responds to transitions. | S (coupling) |
| 13 | GI tuning per biome | **Adopt native** | Godot SDFGI / VoxelGI built-in. Tune per region via SettingsManager. | S |
| 14 | Ragdoll | **Build native** | `PhysicalBone3D` + Jolt — wire to skeleton. | S-M |
| 15 | Cloth (props) | **Adopt native (`SoftBody3D`)** for capes/banners | Skip character cloth (perf cost, marginal value). | S |
| 16 | Hair sim | **Skip** | Static meshes only. AAA hair sim is XL for low gameplay value. Revisit post-shipping. | — |
| 17 | Motion matching | **Skip / aspirational** | XL effort, depends on motion DB we don't have. State machine + additive layers get us 80%. | — |
| 18 | Photo mode | **Build** | Free camera + DOF + tonemap exposure already exist; bolt UI on top. | S |
| 19 | Accessibility | **Build** | Godot has primitives (UI scaling, color filters via post-FX, key remap via InputMap). Wire to options menu. | M |
| 20 | Localization | **Adopt native** | `TranslationServer` + CSV. MW dialogue adapter feeds it. | S infra, ongoing translations |
| — | Controller polish + haptics | **Build native** | InputMap + `Input.start_joy_vibration()`. | S |
| — | VO + subtitles | **Build subs (S)**, VO blocked on assets | — | S subs |

---

## Morrowind-specific must-haves

| # | Gap | Decision | Notes | Effort |
|---|---|---|---|---|
| 21 | Ash storms | **Build** as a weather state — depends on #2 | — | S after #2 |
| 22 | Persuasion (admire/intimidate/taunt/bribe) | **Build** | `dialogue/morrowind/persuasion.gd` | S |
| 23 | Service UIs (merchant/trainer/spellmaker/enchanter) | **Build** | Pelagiad theme, share dialogue panel infrastructure | M |
| 24 | BNAM result-script interpreter | **Build** — **dialogue blocker, prioritize** | — | M |
| 25 | Derived disposition formula | **Build** | Pure math, `dialogue/morrowind/disposition.gd` | S |

---

## Aspirational / engine-gated (no action)

- **RT shadows / GI / reflections** — Godot 4.7 + Vulkan; revisit when 4.7 drops
- **GPU-driven renderer** — we have a plan; gated on bandwidth
- **Texture virtual memory** — engine gap, no userland fix
- **Bindless textures** — engine gap
- **HDR10 output** — engine gap

---

## Adoption decisions summary

### Adopted addons

| Addon | Status | Use |
|---|---|---|
| Terrain3D | already in repo | keep — extend with Instancer for grass |
| SunshineClouds2 | already in repo | keep — couple to weather state machine |
| Beehave | new — `addons/beehave/` | behavior trees |
| GLoot | new — `addons/gloot/` | inventory grid model (wrapped in MW adapter) |

### Built in-house (no addon fits)

| System | Reason |
|---|---|
| Audio | Godot native covers 90%, MW-specific layers needed |
| Weather | Sky3D precedent — no maintained alternative |
| Combat | Game-specific |
| Save/load | Generic addons don't fit streamed worlds |
| Perception / schedules / AI LOD | MW Radiant-style is bespoke |
| Main-scene integration | Wiring, not architecture |
| Face/lip sync driver | Morpher already parsed; Rhubarb is offline-only |
| HUD / menus / options | Game-specific |
| Cluster-merging HLOD | No addon; impostors + per-object LOD already cover most of the win |
| Ragdoll, photo mode, accessibility | Native primitives + thin layers |

### Rejected addons

| Addon | Reason |
|---|---|
| Sky3D | abandoned, opaque, fought custom sky needs |
| Dialogic | imposes data model incompatible with MW provider |
| Wwise / FMOD GDExtensions | closed-source, licensing, overkill |
| ProtonScatter (for grass) | editor-time only, no streaming |
| Generic save addons | wrong model for delta-from-baseline streamed worlds |

---

## Suggested sequencing

Driven by **dependencies** and **what unblocks the most other systems**, not pure priority.

1. **BNAM interpreter (#24)** — unblocks dialogue mutation, prerequisite for quests changing world state
2. **Main-scene integration sprint (#8)** — cheap, high visible value; becomes testbed for everything downstream
3. **Audio (#1)** — touches everything; harder to retrofit later (need event hooks system-wide)
4. **Save/load schema (#6)** — define early so every new system saves itself from day one
5. **Weather (#2) → Ash storms (#21) → grass wind coupling**
6. **Grass via Terrain3D Instancer (#3)** — visual leap, low effort
7. **Inventory via GLoot (#5)** — unblocks economy, equipment, paper doll (run scale spike first)
8. **AI: navmesh + Beehave (#7)** — reserve 1-2 ms in streaming budget for per-cell navmesh bake
9. **Combat (#4)** — depends on animation additive layers (A-18/A-19) + AI + audio
10. **Face/lip sync (#9)**
11. **HUD / menu / options (#10)**
12. Polish pass: photo mode, GI tuning per biome, ragdoll, accessibility, localization, SunshineClouds2 ↔ weather coupling

---

*See also: `docs/STATUS.md`, `docs/audit/godot_46_near_streaming_aaa_audit_2026_04_29_codex.md`, `docs/systems/dialogue.md`.*
