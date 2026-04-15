# Godotwind Masterplan: 2026 Audit & Future-Proofing

This document outlines the high-level roadmap for stabilizing, cleaning, and future-proofing the Godotwind framework.

## Phase 1: Stabilization & Debt Reduction — COMPLETE

### C1: Streaming Pipeline Audit (16/16 findings resolved)
- [x] Purge dead code (mesh_simplifier_v2, static_mesh_merger)
- [x] Algorithmic cleanup (pop_front, ObjectPool O(1), spatial index)
- [x] Architectural robustness (worker handle leak, instance validation)
- [x] Performance optimization (file_exists cache, spatial index for impostors)
- [x] Type-safety sweep (ESM, NIF, BSA, streaming, cell_manager)
- [x] Hardcoded paths fix, priority queue optimization (S-06, S-07, S-10)

### C2: Animation/NPC Audit (17 findings, 14 resolved)
- [x] Verify Quaternius migration
- [x] Fix broken `get_upper_body()` blend mask (A-01)
- [x] Extract duplicate fallback logic `_resolve_fallback_state()` (A-02)
- [x] Remove dead code: `get_bone_weights()`, queue system (A-03, A-04)
- [x] Remove duplicate bone map from morrowind_character_system (A-05)
- [x] Fix AnimationTree structure: add action/upper/additive layers (A-18/A-19)
- [x] Type safety: `_state_animation_map`, `_mask_bones`, `_bone_indices` (A-13-A-16)
- [x] Bone mapping cache (A-11)
- [ ] Fix substring animation matching bug (A-12)
- [ ] Incomplete subsystems: LOD controller, procedural modifiers, creature detection (A-06 to A-10)
- [ ] Character controller `_build_bone_map()` needs type cleanup (A-17)

### G1-G3: General Quality
- [x] ModRegistry architecture (RefCounted, not autoload)
- [x] Asset override layer in specialized loaders
- [x] Dead code purge (~20k lines removed)
- [x] Typed collections sweep across core systems

## Phase 2: Core Foundation II (ACTIVE)
**Goal:** Establish the high-performance technical baseline and data layer.

1. **GPU Scene Database** — SSBO-backed storage for MID/FAR objects (100k+ instances)
2. **RecordCache (ESM Query Layer)** — In-memory queryable cache for ESM records (O(1) lookups)
3. **Save/Load Architecture** — Delta-based world persistence using Godot 4.6 Unique IDs
4. **Input Refactor** — Move from raw keys to Godot's Action-based input system
5. **Environmental Cleanup** — Fix double-singleton OceanManager and Sky3D integration

## Phase 3: Scalable World & Logic
**Goal:** Player agency and data-oriented NPC management.

1. **Data-Oriented NPC Spawning** — Batch-processed AI LOD (WorkerThreadPool)
2. **Core Gameplay Interfaces** — Abstract Inventory/Dialogue/Interaction APIs (Framework-First)
3. **Interaction System** — Pick up objects, open doors, activate NPCs
4. **NavMesh Foundation** — Pathfinding and NavigationServer3D integration
5. **Audio Foundation** — 3D spatialization + occlusion (raycast-based low-pass filters)

## Phase 4: World Atmosphere & Polish
**Goal:** High-fidelity visuals and advanced character interaction.

1. **Modular IK Integration** — Godot 4.6 SkeletonModifier3D for foot planting and LookAt
2. **HLOD Prebake Pipeline** — Spatially clustered mesh merging (MeshOptimizer). **Runtime alternative in progress:** `object_paging.gd` ships OpenMW-style distance-adaptive merging; Phases 1-5 done as of 2026-04-15. Disabled by default pending bench validation. Plan: `docs/audit/OBJECT_PAGING_PLAN.md`.
3. **Ocean/Water Integration** — FFT ocean with SSR/Octahedral probe polish (Godot 4.6)
4. **Weather & Day/Night** — Sky3D + DirectionalLight3D + Weather-Audio Sync
5. **Interior Transitions** — Stencil buffer portal rendering at doorways

## Phase 5: Gameplay Systems
**Goal:** Implement Morrowind-specific logic using the framework interfaces.

1. **Dialogue System** — Topic-based branching dialogue (Dialogic 2 or custom backend)
2. **Inventory System** — Weight+slots management (GLoot or custom backend)
3. **Combat Engine** — Melee/ranged/magic using Morrowind formulas
4. **Quest System** — Topic-based journal tracking (Questify or custom backend)
5. **NPC AI (Near Tier)** — Full Behavior Trees (Beehave) for nearest 20 NPCs

## Phase 6: Technical Push (Future Proofing)
**Goal:** Leverage Godot 4.7+ and advanced motion tech.

1. **Motion Matching** — Precomputed trajectory matching for next-gen locomotion
2. **Godot 4.7 Upgrade** — Vulkan Raytracing (Shadows, AO, GI)
3. **GPU-Driven Culling** — Full compute-shader frustum/occlusion pipeline
4. **HDR Output** — Native Windows HDR display support
5. **Advanced VFX** — Volumetric particles and fluid simulation

---

## Architecture Principles

- **Framework-First:** Build abstract systems; Morrowind is the "reference mod" (Decided 2026-03-01)
- **Interface-First:** RPG systems use abstract Godot-native interfaces; addons (GLoot, Beehave) are swappable backends
- **Documentation is Memory:** Docs are the ONLY thing that persists across sessions and devices. Keep them alive, current, and debated.
- **RT-Ready Renderer:** Abstract shadow/AO/GI systems so RT can be swapped in
- **Compute-First Hot Paths:** Impostor culling, grass placement, crowd sim → compute shaders
- **Data-Oriented NPCs:** AI LOD tiers matching distance rendering tiers

---

## Interface Architecture (Framework-First)

```
src/core/systems/          # Abstract interfaces (framework layer)
  inventory_interface.gd   # InventoryInterface: add/remove/query items
  dialogue_interface.gd    # DialogueInterface: start/advance/branch conversations
  ai_interface.gd          # AIInterface: tick/query/command NPCs
  save_interface.gd        # SaveInterface: serialize/deserialize world state
  interaction_interface.gd # InteractionInterface: activate/use/inspect objects

src/morrowind/             # Morrowind-specific implementations
  morrowind_inventory.gd   # MW weight+slots, ingredient effects
  morrowind_dialogue.gd    # MW topic-based conversation
  morrowind_combat.gd      # MW dice-roll hit chance, damage formulas
  morrowind_save.gd        # MW save format (ESS-compatible or custom)

addons/                    # Optional swappable backends
  gloot/                   # Inventory backend (optional)
  dialogic/                # Dialogue backend (optional)
  beehave/                 # AI behavior tree backend (optional)
```

## Documentation Structure

```
docs/
  STATUS.md               # Per-system implementation status (ground truth)
  DESIGN_PATTERNS.md      # Code patterns: NativeBridge, pooling, batching
  DATA_PIPELINE.md        # ESM/NIF/BSA format details, coordinate conversion
  ESM_SYSTEM.md           # ESM/ESP parsing reference
  NIF_SYSTEM.md           # NIF model conversion reference
  ASSET_MANAGEMENT.md     # Asset loading pipeline
  PERFORMANCE_GUIDE.md    # Frame budgeting, async loading, profiling
  DISTANCE_RENDERING_AUDIT.md  # 3-tier LOD system audit
  GPU_DRIVEN_RENDERER.md  # Future GPU-driven culling design
  MID_TIER_BATCHING.md    # MID-tier rendering optimization
  PREBAKING_PIPELINE.md   # Asset prebaking stages
  RENDERING_SHADERS.md    # Shader reference
  GODOT_46_FEATURES.md    # Godot 4.6 API reference
  CONSOLE_COMMANDS.md     # Developer console commands
  SETTINGS.md             # Configuration reference
  audit/
    MASTERPLAN.md          # This file: roadmap + decisions + architecture
    FINDINGS.md            # Work tracker (resolved items stay for history)
    STREAMING.md           # Historical reference
  specs/                   # Forward-looking design specs (pre-implementation)
    record_cache.md        # ESM query layer (drafted)
    save_load.md           # Save/load architecture (not yet created)
    interaction.md         # Player-world interaction (not yet created)
    weather.md             # WeatherManager + Sky3D + Ocean sync (not yet created)
  design/                  # Pre-implementation ideation
    CHARACTER_ANIMATION_SYSTEM.md
    CONSOLE_IDEATION.md
    interior-exterior-transitions.md
  archive/                 # Completed trackers (historical reference)
    animation/             # Animation cleanup plan, original system docs, overhaul tracker
    character/             # Dual character system, NPC assembly research
    tests/                 # Deleted test files
.claude/CLAUDE.md          # Conventions + quick reference (lean, links to docs/)
```

---

## Decision Log
* **Decision #1:** ModRegistry as RefCounted (not autoload), compiled asset map for O(1) resolution. (Approved 2026-03-01)
* **Decision #2:** Quaternius CC0 animations replace Mixamo (license restriction). Single GLB source. (Approved 2026-02-15)
* **Decision #3:** Use `Log` (not `Logger`) for autoload — avoids Godot 4.6 native `Logger` class conflict. (Approved 2026-02-13)
* **Decision #4:** Use `Dictionary[Vector2i, Array]` for cell-based spatial indexing (O(1) hash). (Approved 2026-03-01)
* **Decision #5:** Prioritize Shadow/AO/GI abstractions for rasterization while maintaining Godot 4.7 RT-readiness. (Approved 2026-03-01)
* **Decision #6:** Use Stencil Portals for simple interior transitions; Sub-Viewports reserved for complex scenarios. (Approved 2026-03-01)
* **Decision #7:** 3-tier AI LOD: Behavior Tree (Near) -> State Machine (Mid) -> Frozen (Far). (Approved 2026-03-01)
* **Decision #8:** Phase 2 priority shift: Foundation II (Save/Load, Records) before Atmosphere. (Approved 2026-03-01)
* **Decision #9:** **Framework-First Identity.** The project is a general RPG framework; Morrowind implementation follows the framework API. (Approved 2026-03-01)

---

## Roast Review Consensus (2026-03-01)

Architectural decisions agreed upon after cross-agent code review:

### Spatial Index
- `Dictionary[Vector2i, Array]` is correct for cell-aligned impostor lookup (O(1) hash).
- QuadTree deferred until profiling shows bottleneck in high-density areas (e.g. Balmora).

### Raytracing vs GPU-Driven Culling
- Build **abstractions now** (Shadow/AO/GI interfaces) so RT can be plugged in when Godot 4.7 RT matures.
- Keep current rasterized paths as stable baseline. RT is not a near-term priority.
- GPU-driven culling (compute shader frustum/occlusion) is higher priority than RT effects.

### Interior Transitions
- **Stencil portals first** for simple doors (cheaper — only renders visible portal region).
- **Sub-Viewports** reserved for complex cases (open-window houses, magical mirrors).

### NPC AI Architecture
- **Beehave** for nearest 10-20 NPCs only (full behavior trees).
- **Data-oriented state stacks** for mid-range NPCs (simplified state machine).
- **Frozen position** for distant NPCs. Matches 3-tier distance rendering LOD.

### file_exists Cache (S-03)
- Keep cache as pragmatic short-term fix.
- Long-term: ModRegistry becomes single disk accessor, eliminating file_exists from hot loops.

### ModRegistry Integration Gap
- `mod_registry.gd` exists but is not wired into world_explorer or loading paths.
- Needs: path normalization fix (forward slashes, not backslashes), schema validation, integration pass.
- Deferred to Phase 3.

### AnimationTree Structure
- Was locomotion-only — missing action_oneshot, upper_body_blend, additive layers.
- Fixed by Gemini (A-18/A-19). play_oneshot() and blend mask filters now target real nodes.
- Status corrected from "Working" to "Locomotion working, action layers stubbed".
