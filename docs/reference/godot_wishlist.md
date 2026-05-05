# Godot Wishlist

> Reference material. Godot 4.6 engine features Godotwind is blocked on,
> working around, or waiting for. This is not a roadmap and not a status doc.
> Verify against current Godot release notes, docs, and issue history before
> treating any entry as current.

---

## Reddit-Style Summary

Godot is not "bad at 3D" in the lazy meme sense. You can absolutely build a
good-looking 3D game in it, and Godot 4.x has moved fast. The pain starts when
you try to build the kind of world that other engines have spent decades
specializing around: continuous open spaces, thousands of unique assets, huge
material variety, heavy transparency, long view distances, dynamic loading, and
no loading screen every time the player crosses an invisible line.

The main thing we learned building Godotwind is that Godot gives you a renderer
and a scene system, but not yet the production open-world middleware layer that
Unreal/Unity users often take for granted. There is threaded resource loading,
but not a streaming system. There are MultiMeshes and RenderingServer APIs, but
not an engine-level GPU-driven renderer. There are compositor callbacks, but not
yet a full render-graph/custom-pass story. There are mipmaps, but not texture
streaming or virtual textures. There are ways to build scene chunks off-thread,
but the active SceneTree, rendering nodes, resources, and GPU uploads still make
runtime spawning a careful frame-budgeting problem.

So the takeaway is not "do not use Godot." The takeaway is: for ambitious
open-world 3D, expect to become an engine team much earlier than you would in
Unreal. You will write the asset pipeline, visibility system, impostors,
material deduplication, shader warmup, LOD policy, streaming scheduler, and VRAM
strategy yourself. That is exciting if you want control. It is brutal if you
expected the engine to already have the AAA scaffolding.

---

## Top Blockers For Ambitious Open-World 3D

### 1. Texture Streaming / Virtual Textures

**What:** Engine-level mip residency: load tiny mips first, stream higher mips
as objects approach the camera, evict unused detail under a VRAM budget.

**Why it matters:** Open worlds are not limited only by draw calls or triangle
count. They are limited by how many unique textures can be resident without
blowing up VRAM. Morrowind's data set has thousands of unique textures. Modern
open worlds are much worse.

**Godot 4.6 status:** Godot has mipmaps and texture compression, but no runtime
texture streaming or virtual texture system. Proposal
[godot-proposals#3177](https://github.com/godotengine/godot-proposals/issues/3177)
is open. Godot's own AA/AAA article identifies streaming as the most important
missing feature for large scenes/open worlds:
<https://godotengine.org/article/whats-missing-in-godot-for-aaa/>.

**Our workaround:**
- Material deduplication reduces duplicate materials.
- Manual `Texture2DArray` packing supports some batching paths.
- FAR impostors collapse distant objects into atlas textures.
- Object streaming and eviction reduce scene residency.

**Remaining gap:** Once a normal texture is loaded, Godot does not expose
engine-level per-mip residency control. We can reduce what we load, but not make
Godot's texture system behave like Unreal Virtual Textures or Unity Mipmap
Streaming.

**Impact:** **Critical.** This is one of the hardest open-world scalability
limits to solve cleanly outside the engine.

---

### 2. Asset / Scene Streaming Is Primitive

**What:** A full streaming system with priority queues, spatial awareness,
loading budgets, memory budgets, dependency warmup, cancellation, eviction, and
hitch-free activation.

**Why it matters:** `ResourceLoader.load_threaded_request()` is useful, but it
loads resources. It is not a complete streaming architecture. Open-world games
need to continuously decide what to load, what to keep warm, what to evict, and
what can be activated this frame without blowing the frame budget.

**Godot 4.6 status:** Godot supports threaded resource loading:
<https://docs.godotengine.org/en/4.6/classes/class_resourceloader.html>. The
docs recommend polling status across frames rather than blocking on
`load_threaded_get()`. There is no built-in spatial streaming manager, asset
priority system, memory budget, or world-partition equivalent.

**Our workaround:** Custom streaming in `src/core/world/`: frame-budgeted
activation, frustum priority, LRU-style eviction, tier transitions, and
prebaked asset loading.

**Impact:** **High.** Solvable at project/framework level, but it is a major
engineering cost and easy to get wrong.

---

### 3. No Engine-Level GPU-Driven Renderer / Bindless Materials

**What:** A modern renderer path where GPU-side culling, indirect draw,
bindless/material indexing, and draw compaction are core engine features rather
than project-specific hacks.

**Why it matters:** Open worlds want to draw huge numbers of objects with tiny
CPU overhead. Godot has useful primitives (`RenderingServer`, `RenderingDevice`,
`MultiMesh`, compute shaders), but not the integrated renderer architecture
that lets all opaque rendering be GPU-driven with thousands of materials.

**Godot 4.6 status:** No engine-level GPU-driven renderer or exposed bindless
texture/material system. Reduz's design notes describe a possible future
GPU-driven renderer, including bindless-style shader compatibility:
<https://gist.github.com/reduz/c5769d0e705d8ab7ac187d63be0099b5>. Godot's
rendering priorities article says performance is now the top rendering priority
because higher-fidelity games are making the renderer a limiting factor:
<https://godotengine.org/article/rendering-priorities-september-2024/>.

**Our workaround:**
- MID-tier batching with raw `RenderingServer` instances.
- HLOD chunks.
- FAR impostors in MultiMesh.
- Manual `Texture2DArray` material packing.
- Compute-culling experiments with MultiMesh/indirect-draw fallbacks.

**Impact:** **High.** The work is possible, but the framework must own systems
that a mature open-world renderer would normally provide.

---

### 4. Renderer Customization / Compositor Is Not Yet A Full Render Graph

**What:** Fine-grained custom render passes, custom buffers, material pass
assignment, stencil control, depth/color copies at chosen stages, portals,
planar reflections, terrain-to-geometry blending, custom post processes, and
renderer callbacks between major passes.

**Why it matters:** Advanced rendering effects often need to happen in the
middle of the pipeline, not just as "draw the world, then run a post-process."

**Godot 4.6 status:** `CompositorEffect` exists and is important, but it is
experimental and exposes a limited callback model:
<https://docs.godotengine.org/en/4.6/classes/class_compositoreffect.html>.
The broader compositor proposal remains open:
<https://github.com/godotengine/godot-proposals/issues/7916>. That proposal
exists because Godot's renderer is still relatively monolithic for advanced
custom rendering.

**Our workaround:** Use built-in pipeline stages where possible; use shader
workarounds, extra viewports, or project-specific render paths only when the
engine path is insufficient.

**Impact:** **High for advanced visuals, medium for core open-world streaming.**
This affects water, transparency, shore blending, portals, decals, outlines,
debug visualization, and other effects that want real pass control.

---

### 5. Runtime Spawning, SceneTree, And GPU Uploads Are Hitch-Prone

**What:** Hitch-free creation, warmup, and activation of complex object trees.

**Why it matters:** Open worlds constantly bring objects in and out of
existence. Even if file I/O is threaded, activation can still hitch if it
touches the active SceneTree, creates rendering nodes, compiles pipelines, or
uploads GPU resources at the wrong time.

**Godot 4.6 status:** This is more nuanced than "PackedScene.instantiate() is
main-thread only." The official thread-safe API docs say building or
instantiating scene chunks outside the active tree is possible from a thread,
but interacting with the active SceneTree is not thread-safe. They also warn
that rendering-node instancing is not thread-safe by default, multiple loading
threads can race shared resources, and direct GPU interaction from threads can
stall:
<https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html>.

**Our workaround:** Frame-budgeted main-thread activation, off-thread data
preparation where safe, direct server APIs for high-volume objects, and careful
resource ownership.

**Impact:** **High.** Manageable, but expert-only in practice.

---

### 6. Pipeline / Shader Compilation Stutter

**What:** Avoiding runtime stalls when a material, shader variant, or pipeline
is first needed by the GPU.

**Why it matters:** Streaming is not finished when a resource is loaded from
disk. It is finished when the object can appear without a frame spike.

**Godot 4.6 status:** Godot documents pipeline compilation as expensive. In the
Compatibility renderer, the docs still recommend the legacy warmup approach:
displaying materials, shaders, and particles in view for at least one frame
during loading:
<https://docs.godotengine.org/en/4.6/tutorials/performance/pipeline_compilations.html>.

**Our workaround:** Prefer prebaked assets, reduce material permutations, warm
assets before they enter the player view, and treat shader warmup as part of
streaming rather than an afterthought.

**Impact:** **Medium to high.** It does not block features, but it can destroy
frame pacing if ignored.

---

### 7. Transparency And Screen-Space Effects Have Hard Limits

**What:** Correct interaction between transparency, SSR/refraction, depth,
normal/roughness buffers, MSAA, SSS, and custom effects.

**Why it matters:** Water, glass, particles, foliage, fog cards, magic effects,
and wet surfaces all lean on the transparency/screen-space boundary.

**Godot 4.6 status:** The docs explicitly state that transparent materials
cannot cast shadows or appear in `hint_screen_texture` / `hint_depth_texture`,
which prevents them from appearing in screen-space reflections or refraction in
the same way opaque objects do:
<https://docs.godotengine.org/en/4.6/tutorials/shaders/shader_reference/spatial_shader.html>.
SSR documentation also says transparent materials are not reflected because
they do not write to the depth buffer:
<https://docs.godotengine.org/en/stable/tutorials/3d/environment_and_post_processing.html>.
Godot's rendering priorities call out screen-space effects as an area needing
significant improvement.

**Our workaround:** Prefer opaque/alpha-hash when possible, use reflection
probes or custom water paths, avoid relying on transparent objects participating
in every screen-space effect, and design effects around known renderer limits.

**Impact:** **Medium to high.** Especially important for water, foliage, and
high-end VFX.

---

### 8. Dynamic Mesh / CPU-Updated Vertex Workflows Are Sharp-Edged

**What:** Efficiently updating mesh vertex/attribute data at runtime.

**Why it matters:** Terrain edits, deformation, decals, trails, procedural
geometry, generated impostors, and custom debug geometry all need predictable
dynamic mesh APIs.

**Godot 4.6 status:** The common complaint that Godot has "no way to update
verts in-place" is too strong. `ArrayMesh` exposes
`surface_update_vertex_region()`, `surface_update_attribute_region()`, and
`surface_update_skin_region()`. The real problem is that these methods are
low-level, underdocumented, byte-offset based, and easy to misuse:
<https://docs.godotengine.org/en/4.6/classes/class_arraymesh.html>.

**Our workaround:** Prefer prebake for static assets. For dynamic systems, use
server-level APIs or tightly controlled `ArrayMesh` update paths with explicit
binary layout knowledge.

**Impact:** **Medium.** Not impossible, but far less ergonomic than mature
dynamic mesh workflows in bigger engines.

---

### 9. Built-In Occlusion Culling Is Not An Open-World Silver Bullet

**What:** Reliable outdoor occlusion for dense cities, terrain, buildings, and
large object counts.

**Why it matters:** Dense areas like Balmora/Vivec need many hidden objects to
disappear before they cost CPU/GPU time.

**Godot 4.6 status:** Godot has occlusion culling, but it is not a complete
open-world visibility solution. The previously cited angle regression
[godot#106184](https://github.com/godotengine/godot/issues/106184) is closed
with milestone 4.5, so do not cite it as a current active blocker. Treat the
remaining issue as broader: outdoor occlusion is workload-dependent, requires
authoring/occluder setup, and does not replace project-specific streaming,
distance culling, HLOD, or GPU culling.

**Our workaround:** Frustum + distance culling, tiered LOD/HLOD/impostor
systems, and project-specific compute culling experiments.

**Impact:** **Medium.** Important, but not as fundamental as texture streaming
or renderer architecture.

---

## Important Future / In-Progress Engine Work

### Vulkan Ray Tracing Plumbing

**What:** Low-level Vulkan ray tracing support in `RenderingDevice`.

**Status:** PR
[godot#99119](https://github.com/godotengine/godot/pull/99119) was merged into
`master` on January 27, 2026. This is useful foundation work, not a shipped
Godot 4.6 open-world occlusion solution.

**Caveat:** Vulkan-focused. Do not assume D3D12, Metal, or production renderer
integration is complete.

**Impact for Godotwind:** Low short-term, potentially high long-term for GPU
occlusion and advanced rendering experiments.

---

### Compositor API Expansion

**What:** More complete custom pass/buffer/render-order control.

**Status:** `CompositorEffect` exists in 4.6, but the broader compositor design
proposal remains open.

**Impact for Godotwind:** High for water, shore blending, custom visibility
debugging, decals, outlines, and advanced effects.

---

## Lower-Priority Missing Features

### Built-In Impostor System

**What:** Automatic billboard/octahedral impostor generation for distant
objects.

**Status:** Not a public roadmap item.

**Our workaround:** Custom octahedral impostor system with prebaked atlases and
MultiMesh rendering.

**Impact:** Low for us now because we built it, but high effort for any new
open-world Godot project.

---

### Native Runtime Mesh Simplification / LOD Generation

**What:** Engine-level mesh decimation and runtime LOD generation.

**Status:** Godot has import-time LOD generation and `visibility_range`, but no
general runtime mesh simplification pipeline comparable to mature content
pipelines in larger engines.

**Our workaround:** Prebaked LODs and impostors.

**Impact:** Low to medium. Offline preprocessing works, but it increases asset
pipeline complexity.

---

### GDScript Value Types / Traits / Interfaces

**What:** Better language support for data-heavy framework code.

**Why it matters:** Framework code wants compact value-like records and explicit
interfaces. GDScript currently pushes many data models toward `RefCounted`,
`Resource`, dictionaries, abstract base classes, or duck typing.

**Status:** Proposals exist/discussions continue, but no dependency should be
taken on them for Godotwind.

**Our workaround:** C# for new hot paths and data-heavy systems; GDScript for
thin orchestration glue.

**Impact:** Medium for ergonomics, low for capability.

