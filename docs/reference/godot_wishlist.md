# Godot Wishlist

> Reference material. Godot 4.6 engine features Godotwind is blocked on, working around, or waiting for. Not a roadmap, not a status doc — just the list of engine-level gaps and our workarounds. Verify against current Godot release notes before acting on any entry (several were last updated 2026-03).

---

## Godot Features We're Waiting For

### Ray Tracing Acceleration Structures (Godot 4.7)

**What:** `GL_EXT_ray_query` support for GPU occlusion culling via RT acceleration structures.

**Why we need it:** Ray queries are the most accurate occlusion culling method — they determine if objects are hidden behind terrain/buildings with no CPU readback and no conservative errors.

**Status:** [PR #99119](https://github.com/godotengine/godot/pull/99119) merged into Godot master (Jan 2026), targeting **Godot 4.7**. Vulkan only — no Metal or D3D12 RT support yet.

**Our workaround:** The system degrades gracefully without RT. Frustum + distance culling work without ray queries. RT occlusion is a bonus, not a requirement.

---

### Engine-Level GPU-Driven Renderer (No Timeline)

**What:** Reduz's [GPU-driven renderer vision](https://gist.github.com/reduz/c5769d0e705d8ab7ac187d63be0099b5) — deferred G-buffer, bindless textures, RT shadows, all opaque rendering via indirect draw.

**Why we want it:** Would replace our application-level GPU-driven work and MID-tier batching system. Engine-level integration would be dramatically more efficient.

**Status:** Multi-year effort, **not actively being developed**, not mentioned in [Godot's rendering priorities (Sep 2024)](https://godotengine.org/article/rendering-priorities-september-2024/). Don't wait for it.

**Our workaround:** Application-level GPU-driven system using compute shader culling + SSBO storage + MultiMesh readback. When/if Godot ships engine-level GPU rendering, our system can be retired.

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

**Our workaround:** Manual `Texture2DArray` packing (512 layers, 512x512 per texture) in our material library. A bindless material system would build on top of this.

---

### `draw_list_draw_indirect()` Maturity (Available but Unproven)

**What:** GPU indirect drawing — the GPU decides what to draw without CPU readback.

**Why we want it:** Zero-latency GPU-driven rendering. Our preferred path for GPU culling output.

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

**Our workaround:** GPU compute shader frustum + distance culling, with RT ray query occlusion planned once Godot 4.7 ships RT support.

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

## Impact Summary

| Blocker | Impact |
|---|---|
| No RT acceleration (until 4.7) | Low — RT occlusion is optional enhancement |
| No engine GPU-driven renderer | Medium — we build our own (significant effort) |
| No impostor system | Low — already solved with custom system |
| Indirect draw immaturity | Low — MultiMesh fallback works |
| Occlusion culling bug | Medium — must implement GPU culling ourselves |
| No GDScript structs | Medium — RefCounted overhead for data objects |
| No GDScript traits | Low — abstract base classes work, less elegant |
| No texture streaming | **High** — VRAM fills up with many loaded cells, no engine-level fix |
| No bindless textures | **High** — limits draw call reduction for 100k+ uniquely-textured objects |
| No threaded instantiation | Medium — streaming latency, must frame-budget all instantiation |
| No mesh simplification | Low — prebaking works, adds offline step |

**Bottom line:** Nothing in Godot's pipeline is blocking our next steps. The biggest effort is building our own GPU-driven rendering system, which we'd need regardless given the project's scale (100k+ objects). Godot 4.7's RT features will be a nice upgrade when they arrive.
