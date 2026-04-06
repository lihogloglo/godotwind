# Godotwind — Future Steps & Godot Wishlist

Last updated: 2026-04-06

## Tracked Follow-ups

### Interior transition — explicit `NativeStreamingManager.pause()/resume()` during fade

**Context:** The P0 interior-load hiccup fix (2026-04-06) replaced the sync `CellManager.load_cell()` call in `InteriorPocketManager._load_pocket()` with `request_cell_async()` + a priority lane that boosts in-flight interior entries during a transition. The priority lane is the *effective* pause for the test scene (`tests/visual/test_interior_transition.tscn`) because it doesn't run the full streaming pipeline.

**What's missing:** `world_explorer.gd` DOES run `NativeStreamingManager` alongside the pocket manager. When a transition begins (`InteriorPocketManager.transition_started`), the streaming manager should:
1. Stop accepting new exterior cell requests (`request_exterior_cell_async` returns -1 until resumed)
2. Keep draining the existing `_instantiation_queue` (the priority lane already routes interior entries first)
3. Resume on `transition_completed` OR `interior_load_timeout`

**Where to wire it:**
- `NativeStreamingManager` already has a pause API at `world_explorer.gd:1855` (grep for `## Pause/resume the streaming manager`). Verify it matches the semantics above.
- Connect `_pocket_manager.transition_started` → `_streaming_manager.pause()` and `transition_completed` → `_streaming_manager.resume()` in `world_explorer._setup_pocket_manager()`.
- Same wiring for the new `interior_load_timeout` signal (resume on timeout too).

**Why not this session:** The test scene doesn't use `NativeStreamingManager` so the fix can't be validated there. Deferring keeps the P0 change surgical. The test scene's pass criteria (frame-time peak ≤ 8 ms) are met by the priority-lane boost alone; adding the explicit pause is a belt-and-suspenders hardening for the main scene.

**Verification after wiring:** Main scene (`scenes/Godotwind.tscn`), walk to a Seyda Neen door while looking 90° sideways (so exterior cell loading is still active in your peripheral view). Press E. Frame time peak during the transition window should stay ≤ 8 ms. Confirm `_cell_manager._async_requests` shows no new exterior entries created during the fade window.



This document covers where the project is heading, what we're building next, and which Godot engine features we're waiting for (or working around).

---

## Current State (March 2026)

Godotwind runs on **Godot 4.6 stable** (Forward+, Jolt Physics, D3D12 on Windows).

**What works today:** World streaming at 60+ FPS, terrain (Terrain3D), 3-tier LOD (NEAR/MID/FAR impostors), ESM/NIF/BSA parsing, NPC body assembly with Morrowind skeleton, 132 MW animations, material deduplication, developer console, fly camera + FPS controller, ocean shader (analytical Gerstner).

**What doesn't exist yet:** Combat, magic, AI, dialogue, quests, inventory, weather, interior transitions, save/load. See `docs/STATUS.md` for the full breakdown.

---

## Roadmap Summary

The full roadmap lives in `docs/audit/MASTERPLAN.md`. Here's the short version:

| Phase | Focus | Status |
|-------|-------|--------|
| 1 | Stabilization & debt reduction | **COMPLETE** |
| 2 | Core foundation (GPU scene DB, record cache, save/load, input) | **ACTIVE** |
| 3 | Scalable world & logic (NPCs, interaction, navmesh, audio) | Planned |
| 4 | Atmosphere & polish (IK, HLOD, ocean FFT, weather, interiors) | Planned |
| 5 | Gameplay systems (dialogue, inventory, combat, quests, NPC AI) | Planned |
| 6 | Technical push (motion matching, Godot 4.7 RT, GPU culling, HDR) | Future |

---

## Godot Features We're Waiting For

### Ray Tracing Acceleration Structures (Godot 4.7)

**What:** `GL_EXT_ray_query` support for GPU occlusion culling via RT acceleration structures.

**Why we need it:** Our GPU-Driven Renderer design (Phase 5 in `docs/GPU_DRIVEN_RENDERER.md`) uses ray queries to determine if objects are hidden behind terrain/buildings. This is the most accurate occlusion culling method — no CPU readback, no conservative errors.

**Status:** [PR #99119](https://github.com/godotengine/godot/pull/99119) merged into Godot master (Jan 2026), targeting **Godot 4.7**. Vulkan only — no Metal or D3D12 RT support yet.

**Our workaround:** The system degrades gracefully without RT. Phases 1-4 of the GPU-Driven Renderer work with frustum + distance culling only. RT occlusion is a bonus, not a requirement.

---

### Engine-Level GPU-Driven Renderer (No Timeline)

**What:** Reduz's [GPU-driven renderer vision](https://gist.github.com/reduz/c5769d0e705d8ab7ac187d63be0099b5) — deferred G-buffer, bindless textures, RT shadows, all opaque rendering via indirect draw.

**Why we want it:** Would replace our entire application-level GPU-Driven Renderer (`docs/GPU_DRIVEN_RENDERER.md`) and MID-tier batching system. Engine-level integration would be dramatically more efficient.

**Status:** Multi-year effort, **not actively being developed**, not mentioned in [Godot's rendering priorities (Sep 2024)](https://godotengine.org/article/rendering-priorities-september-2024/). Don't wait for it.

**Our workaround:** We're building our own application-level GPU-driven system in 6 phases. Uses compute shader culling + SSBO storage + MultiMesh readback. When/if Godot ships engine-level GPU rendering, our system can be retired.

---

### Built-in Impostor System (Not Planned)

**What:** Automatic billboard/octahedral impostor generation for distant objects.

**Why we need it:** Open-world games need impostors for objects beyond LOD range. Godot has `visibility_range` but no impostor generation.

**Status:** Not on any Godot roadmap.

**Our workaround:** Custom octahedral impostor system with `NativeImpostorRenderer` — prebaked impostor atlases, MultiMesh rendering, 70k+ instances in a single draw call. Works well but required significant development effort.

---

### Automatic Texture Atlasing (Not Planned)

**What:** Engine-level texture array/atlas packing for draw call reduction.

**Why we want it:** Morrowind has ~10,000 unique materials. We deduplicate to ~1,000, but further batching requires texture arrays.

**Status:** Not on any Godot roadmap.

**Our workaround:** Manual `Texture2DArray` packing (512 layers, 512x512 per texture) in our material library. Phase 3 of the GPU-Driven Renderer designs a bindless material system on top of this.

---

### `draw_list_draw_indirect()` Maturity (Available but Unproven)

**What:** GPU indirect drawing — the GPU decides what to draw without CPU readback.

**Why we want it:** Zero-latency GPU-driven rendering. Our preferred path for Phase 4 of the GPU-Driven Renderer.

**Status:** API exists since Godot 4.4.dev4, but:
- Zero community usage examples
- [Known Mac Metal bug](https://github.com/godotengine/godot/issues/103488)
- Undocumented beyond API reference
- Compatibility renderer doesn't support it

**Our workaround:** MultiMesh readback fallback (GPU cull → async readback → MultiMesh update, 1-frame latency). Plan to switch to indirect draw when the ecosystem matures.

---

### Outdoor Occlusion Culling Fix (Bug)

**What:** Godot's built-in occlusion culling has an [angle bug (#106184)](https://github.com/godotengine/godot/issues/106184) that makes it unreliable for exterior scenes.

**Why we need it:** Dense areas (Balmora, Vivec) have many objects behind buildings that should be culled.

**Our workaround:** GPU compute shader frustum + distance culling (Phases 2-4), with RT ray query occlusion planned for Phase 5 (Godot 4.7).

---

### GDScript Language Features (Proposed)

Several GDScript language improvements would significantly help the codebase:

| Feature | Why We Want It | Status |
|---------|---------------|--------|
| **Structs / value types** | ESM records, NIF data, cell references — thousands of small data objects that currently require `RefCounted` or `Resource` with GC overhead | [GIP-1](https://github.com/godotengine/godot-proposals/issues/7329) proposed, no implementation timeline |
| **Traits / interfaces** | Framework-First architecture needs proper interfaces (InventoryInterface, DialogueInterface, etc.) — currently using duck-typing or abstract base classes | [Proposal #6416](https://github.com/godotengine/godot-proposals/issues/6416) discussed, no implementation timeline |
| **Typed dictionaries** | `Dictionary[StringName, Record]` exists in 4.4+ but typed Dictionary literals and better inference would help | Partially available |

---

### Asset Streaming (Engine-Level)

**What:** Native background asset loading with priority queues and memory budgets.

**Why we want it:** We built our own streaming pipeline (~2,000 lines) with frame budgeting, frustum priority, LRU eviction, and tier transitions. Engine-level support would be more robust.

**Status:** Godot has `ResourceLoader.load_threaded_request()` which we use, but no higher-level streaming system (priority, budgeting, spatial awareness). Not on any roadmap.

**Our workaround:** Custom streaming pipeline in `src/core/world/` — works well after 10 sessions of optimization.

---

### Texture Streaming / Virtual Textures (Not Available)

**What:** Engine-level mipmap streaming that loads only the mip levels needed for the current view, keeping VRAM usage bounded regardless of total texture count.

**Why we need it:** Morrowind has thousands of unique textures. When streaming many cells, all their textures load at full resolution into VRAM. With no texture streaming, VRAM fills up fast — especially on GPUs with 4-8 GB. This is one of our biggest scalability constraints.

**Status:** Godot has no texture streaming or virtual texture system. Not on any public roadmap. Unreal has "Virtual Textures" and Unity has "Mipmap Streaming" — both solve this problem at engine level.

**Our workarounds:**
- Material deduplication (~10,000 → ~1,000 unique materials) reduces duplicate texture loads
- LRU cache eviction in BSAManager (256MB cap) limits disk-side memory
- Impostor system replaces distant objects with atlas textures (much smaller VRAM footprint)
- But there's no mip-level control — once a texture is loaded, all mips are in VRAM

**What would help:** Even basic mipmap streaming (load mip 0-1 first, stream higher mips on demand) would dramatically reduce VRAM pressure. This is a hard engine-level feature — not something we can easily build at application level.

---

### Bindless Textures (Not Available)

**What:** GPU descriptor indexing (`GL_EXT_nonuniform_qualifier`) — the GPU picks textures from a heap via integer ID, allowing thousands of differently-textured objects in a single draw call.

**Why we need it:** This is the single biggest draw call reduction opportunity for MID/FAR tiers. We have ~1,000 unique materials across 100k+ objects. Without bindless, every unique material = separate draw call (or complex Texture2DArray workarounds). With bindless, all objects can share one shader and one draw call regardless of texture count.

**Status:** Not exposed in Godot. Part of Reduz's GPU-driven vision, no implementation timeline. Vulkan and D3D12 both support it at hardware level — it's a Godot integration gap.

**Our workaround:** Manual `Texture2DArray` packing (512 layers per array, 512x512 per texture). Objects index into the array via custom instance data. Works but requires texture format normalization, atlas management, and limits flexibility. True bindless would be dramatically simpler.

---

### Background Thread Scene Instantiation (Engine Limitation)

**What:** Ability to call `PackedScene.instantiate()` from worker threads.

**Why we need it:** Cell streaming creates dozens of Node3D instances per frame. `instantiate()` is main-thread only — we must defer all instantiation through frame budgeting (2ms/frame cap). True threaded instantiation would let us stream cells faster without frame hitches.

**Status:** Godot architecture limitation. `duplicate()` works from threads but `instantiate()` does not. No public proposals to change this.

**Our workaround:** Frame-budgeted main-thread instantiation with frustum-priority queuing. Works well but adds latency — distant cells may take several frames to fully populate.

---

### Native Mesh Simplification / LOD Generation (Not Available)

**What:** Automatic mesh decimation for LOD generation (like UE's Nanite or even basic simplification).

**Why we want it:** We prebake 3 LOD levels per object for the MID tier. Engine-level simplification would eliminate the prebake step and allow dynamic LOD quality adjustment.

**Status:** Godot has `visibility_range` for LOD switching but no mesh simplification pipeline. `SurfaceTool` and `MeshDataTool` exist but have no decimation. `mesh_simplifier.gd` exists in our codebase but is disabled — Godot's `ImporterMesh.generate_lods()` is import-time only, not available at runtime.

**Our workaround:** Prebaked LODs via the asset pipeline. Custom impostor system for FAR tier. Works but requires offline processing.

---

## How These Blockers Affect the Roadmap

| Blocker | Phases Affected | Impact |
|---------|----------------|--------|
| No RT acceleration (until 4.7) | Phase 6 | Low — RT occlusion is optional enhancement |
| No engine GPU-driven renderer | Phase 2, 6 | Medium — we build our own (significant effort) |
| No impostor system | Phase 4 | Low — already solved with custom system |
| Indirect draw immaturity | Phase 2 | Low — MultiMesh fallback works |
| Occlusion culling bug | Phase 2 | Medium — must implement GPU culling ourselves |
| No GDScript structs | Phase 2, 3 | Medium — RefCounted overhead for data objects |
| No GDScript traits | Phase 3, 5 | Low — abstract base classes work, just less elegant |
| No texture streaming | Phase 2, 4 | **High** — VRAM fills up with many loaded cells, no engine-level fix possible |
| No bindless textures | Phase 2, 4 | **High** — limits draw call reduction for 100k+ uniquely-textured objects |
| No threaded instantiation | Phase 2 | Medium — streaming latency, must frame-budget all instantiation |
| No mesh simplification | Phase 4 | Low — prebaking works, just adds offline step |

**Bottom line:** Nothing in Godot's pipeline is blocking our next steps. The biggest effort is building our own GPU-driven rendering system, which we'd need regardless given the project's scale (100k+ objects). Godot 4.7's RT features will be a nice upgrade when they arrive.

---

## Where Contributors Can Help

See `docs/STATUS.md` for detailed system status. High-impact areas:

1. **Phase 2 specs are written** — `docs/specs/` has designs for RecordCache, GPU Scene DB, HLOD pipeline, and ESM batch export. Implementation welcome.
2. **Interior transitions** — Full design doc at `docs/design/interior-exterior-transitions.md`. Phase 1 (fade transitions) is straightforward.
3. **Console commands** — Easy entry point. See `docs/CONSOLE_COMMANDS.md`.
4. **Audio foundation** — Not started. Godot's AudioStreamPlayer3D + occlusion raycasts.
5. **Weather system** — Sky3D plugin installed but not wired. Day/night cycle + fog.

---

*For the full roadmap, architecture decisions, and design rationale, see `docs/audit/MASTERPLAN.md`.*
