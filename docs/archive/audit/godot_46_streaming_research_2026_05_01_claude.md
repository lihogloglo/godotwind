# Godot 4.6 NEAR Streaming Primary-Source Research

Archived: durable conclusions were consolidated into
`docs/systems/streaming_rendering_bible.md` on 2026-05-01. Keep this file only
as forensic source material.

Date: 2026-05-01
Author: claude (architect / third-opinion reviewer role)
Scope: input for the Phase 2B written design pass
Branch: `perf/distant-rendering-2026-04-17`

## Source-Priority Order Used

1. **Official Godot 4.6 documentation** (`docs.godotengine.org/en/4.6/...`) — `D` only when the page actually contains the claim verbatim.
2. **Godot GitHub issues / PRs** (with priority on `4.6.x` label, then any open thread with the exact signature) — `D` for engine-confirmed behavior, `I` when I am inferring from a closed-but-unfixed thread.
3. **OpenMW master source** (`gitlab.com/OpenMW/openmw/-/raw/master/...`) — `D` for what the code does today; cited verbatim with function names.
4. **godot-jolt repo and Godot Jolt module issues** — `D` when an issue/PR exists, `I` when only forum/release notes.
5. **Community articles, Reddit, Discord, forums** — `I` only, never used as fact.

Tagging convention used inline: **`D`** = primary doc/source-code claim. **`I`** = inferred from symptoms or community discussion.

---

## Section 1 — `material_set_shader null material` loop on engine shutdown

**Empirical signature in this project (from tracker entries and post-`BENCH_QUIT` logs):**
- Repeated runtime `Parameter "material" is null` lines emitted by `RenderingServer::material_set_shader`, looping until the watchdog kills PID.
- Always observed *after* automated `BENCH_QUIT` / `READY_QUIT` paths drain project autoload teardown (`LOG_EXIT done`).
- Visible manual `WM_CLOSE_REQUEST` quit (ALT-F4) does **not** reproduce.

**What the docs / engine issues say:**

- The exact error string `material_set_shader: Parameter "material" is null` was **not found** in any Godot GitHub issue or PR I could locate. No primary-source evidence that this specific loop is a known engine-side bug. **`I`**
- Issue [#69910](https://github.com/godotengine/godot/issues/69910) — "Destructing leaking `RenderingServer` RID objects can crash the engine on exit as `RenderingServer` singleton is already deleted" — describes a related but **distinct** failure mode: SIGSEGV inside `RID_Owner` destructor during `~RenderingServerDefault()` because leaked RID objects' destructors run after the singleton is already gone. **`D`**
- PR [#69972](https://github.com/godotengine/godot/pull/69972) — "Add safety-checks before some servers `free()`" — merged 2023-01-03, added `ERR_FAIL_NULL()` guards in NavigationServer2D/3D, PhysicsServer2D/3D, RenderingServer to prevent crashes when leaks occur during engine exit. The PR added safety, **did not establish a canonical free order**. **`D`**
- Issue [#84966](https://github.com/godotengine/godot/issues/84966) — "Editor crash when setting shader parameter for type uniform sampler2D array (`Attempting to initialize the wrong RID`)" — closest to our error string but is about *setting* params on a sampler2D array, not about shutdown loops. Likely unrelated. **`I`**

**My assessment:**
- The pattern (an *infinite loop* of null-material errors after summary write) is consistent with **a render iteration walking a list whose entries point to freed materials**, not with a one-shot RID-destructor crash. **`I`**
- Likely candidates within this project, in order of probability:
  1. `static_object_renderer.gd` cull/upload tick still iterating a per-cell or world-scoped list after the materials were freed.
  2. `prototype_batch.gd` fade material chain (per the codebase context) holding a stale ref.
  3. The two backed-out Phase 2B attempts (per-bucket RID hide cursor, bounded bucket splitting) both hit this signature — that is the strongest hint that **bucket free-order is the cause**, not engine teardown. **`I`**
- The fact that visible `WM_CLOSE_REQUEST` quit does not reproduce, while `SceneTree.quit()` from `BENCH_QUIT` does, suggests `_exit_tree()` / autoload-shutdown ordering differs between the two paths. The benchmark path tears down the scene tree before the rendering loop drains, so a tick can fire on freed material RIDs. **`I`**

**Implications for Godotwind Phase 2B design:**
- The bucket-hide and bucket-free paths must specify, in writing: which list they walk, in what order, and *what proves the list does not contain freed materials when the walk happens*.
- The Phase 2B design must include a teardown ordering invariant: stop iteration first, free RIDs second, drop strong refs third — and the iteration-stop must be observable (a flag the cull/upload tick checks at the head of every iteration).
- Do **not** assume a canonical engine free order will save us. Per [#69910 / PR #69972](https://github.com/godotengine/godot/pull/69972), the engine adds safety guards but does not enforce ordering; the project must own it.

---

## Section 2 — RenderingServer RID free ordering during cell unload

**What the docs say:**

- `tutorials/performance/using_servers.html` ([4.6](https://docs.godotengine.org/en/4.6/tutorials/performance/using_servers.html)): the only directly relevant guidance is *"References to a resource's RID are not counted when determining whether the resource is still in use. Make sure to keep a reference to the resource outside the server. Otherwise, both the resource and its RID will be erased."* **`D`** — but this addresses *premature* free, not free-ordering.
- `class_renderingserver.html` ([4.6](https://docs.godotengine.org/en/4.6/classes/class_renderingserver.html)): the actual class page does not contain a documented free-order specification, shutdown-behavior note, or thread-safety guarantee for `free_rid()`. **`D` (negative finding — the page is silent).**
- Issue [#69910](https://github.com/godotengine/godot/issues/69910) confirms shutdown ordering matters and is the implementer's responsibility (PR #69972 added guards, not order). **`D`**

**OpenMW comparison (Section 6 detail):** OpenMW does not free server RIDs explicitly. It calls `mRendering.removeCell(cell)` and `mResourceSystem->updateCache()` and lets `osg::ref_ptr` reference counting handle the rest. **`D`**

**My assessment:**
- There is **no documented canonical free order** in Godot 4.6 official docs. **`D` (negative).**
- The project's existing pattern (`hide → defer → free with mutex`) is not contradicted by anything in the docs, but is also not blessed by them. **`I`**
- The closest the docs come to an order is implicit in the using_servers warning: the source `Resource` (Mesh/Material) must outlive any RID derived from it. By extension, `instance_set_base(rid, mesh.get_rid())` requires the mesh to outlive the instance RID. **`I` from chained reasoning.**

**Implications for Godotwind Phase 2B design:**
- The design must specify the order explicitly in this project, since the engine does not. Proposed canonical order, derived from the using_servers contract:
  1. `RenderingServer.instance_set_visible(rid, false)` — stop draws.
  2. `RenderingServer.free_rid(instance_rid)` — drop the instance.
  3. `RenderingServer.free_rid(multimesh_rid)` (if MultiMesh) — drop the buffer holder.
  4. Drop strong `Material` ref → engine refcount free → material RID auto-released.
  5. Drop strong `Mesh` ref → same.
- Cite this reasoning chain in the design doc with the using_servers URL. Mark each step as derived, not documented.
- The mutex in `static_object_renderer.gd::_mesh_types_mutex` aligns with `thread_safe_apis.html` ([4.6](https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html)) which states *"Use one thread for loading and modifying resources, and then the main thread for adding them"* **`D`** — keep it.

---

## Section 3 — MultiMesh per-cell lifetime under streaming

**What the docs say:**

- `class_multimesh.html` ([4.6](https://docs.godotengine.org/en/4.6/classes/class_multimesh.html)): *"they are spatially indexed as one, for the whole object"* and *"if the instances are too far away from each other, performance may be reduced as every single instance will always render."* **`D`** — confirms world-scoped MultiMesh is wrong for our cell sizes.
- `using_multimesh.html` ([4.6](https://docs.godotengine.org/en/4.6/tutorials/performance/using_multimesh.html)): *"A workaround is to create several MultiMeshes for different areas of the world."* **`D`** — confirms per-cell-bucket is the documented pattern.
- `instance_count` *"clears and (re)sizes the buffers"*; `visible_instance_count` does not. Use `visible_instance_count` for steady-state count varying. **`D`**
- `set_buffer()` threading: *"The array can be created with multiple threads, then set in one call, providing high cache efficiency."* No deeper threading contract documented. **`D`**
- Per-instance fade / transparency: **not documented in the MultiMesh page**. Only `set_instance_color()` exists, and only when material has `vertex_color_use_as_albedo`. **`D` (negative finding).**
- I found **no 4.6-specific MultiMesh issues** of relevance in the GitHub label search above. **`I`**

**Why prior Phase 2B bucket-MultiMesh attempts failed (recap from project tracker):**
- Per the tracker `2026-04-30` entries, two attempted MultiMesh approaches both produced `material_set_shader null material` loops on shutdown. **`D`** (project tracker).
- Combined with Section 1's negative finding (no engine-side issue matches our exact signature), this is **strong evidence the failures are project-side ordering bugs, not Godot 4.6 MultiMesh bugs.** **`I`**

**Implications for Godotwind Phase 2B design:**
- Per-cell, per-prototype `CellStaticBucket` with `multimesh.mesh = handle.meshes[idx]` (strong-ref holds resource) is the documented-blessed shape. **`D`-backed.**
- Use `instance_count` once at bucket construction, never resize. Use `visible_instance_count` if you need to vary draw count. **`D`-backed.**
- `set_buffer()` from worker thread is permitted; the bucket's RS instance must be created on main thread, but the buffer can be filled off-thread. **`D`-backed.**
- Per-instance fade on a MultiMesh is **not documented** to work in 4.6. The current crossfade shader in this project must be retained or proven separately; engine `visibility_range_fade_self` documentation is for `GeometryInstance3D`, not per-MultiMesh-instance. **`D`-backed (negative).**
- The Phase 2B design's bucket free-order block (from Section 2) must be the same one that previously failed in the backed-out attempts; design must explain *what was different* in those attempts and how the new design fixes it.

---

## Section 4 — WorkerThreadPool / ResourceLoader interactions

**What the docs say:**

- `class_workerthreadpool.html` ([4.6](https://docs.godotengine.org/en/4.6/classes/class_workerthreadpool.html)): *"Every task must be waited for completion using `wait_for_task_completion()` or `wait_for_group_task_completion()` at some point so that any allocated resources inside the task can be cleaned up."* **`D`** — wait is mandatory.
- The same page is silent on: behavior when task references freed objects, cleanup responsibility for bound data, shutdown task draining. **`D` (negative).**
- `thread_safe_apis.html` ([4.6](https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html)): *"creating scene chunks (nodes in tree arrangement) outside the active tree is fine"* but *"Attempting to load or create scene chunks from multiple threads may work, but you risk resources... being tweaked by multiple threads, resulting in unexpected behaviors."* Recommends *"one thread for loading and modifying resources, and then the main thread for adding them."* **`D`**
- `class_packedscene.html`: thread-safety of `instantiate()` is **not documented**. **`D` (negative).**

**GitHub state of off-thread `PackedScene.instantiate()`:**

- Issue [#79194](https://github.com/godotengine/godot/issues/79194) — "PackedScene loading and instancing in separate threads respectively triggers thread guards" — *open* with labels `discussion`, `documentation`, `needs testing`, `topic:core`. Introduced in 4.1 (worked in 4.0). Workaround: `set_thread_safety_checks_enabled(false)` or load + instantiate on the same thread. **`D`** — confirms the official position is "fragile / not formally supported."
- Forum thread (Oct 2025): community member ("normalized") said "It's safe" referring to forum guidance. **`I`** — community opinion only, not a primary source. Mark as inference.

**ResourceLoader.load_threaded_request ownership semantics:**
- `class_resourceloader.html`: documents `load_threaded_request`, `load_threaded_get_status`, `load_threaded_get`. Does **not** specify what happens if the requester dies before `load_threaded_get`. **`D` (negative).**

**Implications for Godotwind Phase 2B design (and Phase 4 sequencing):**
- Keep `PHASE_A_OFFTHREAD_INSTANTIATE = false` until either:
  - (a) Issue #79194 closes with a documented fix, or
  - (b) The project lands an isolated harness that proves the exact `load → instantiate` shape works on Godot 4.6.x in use.
- `wait_for_task_completion()` is mandatory; the existing `_drain_collision_worker_for_request` and `drain_prereg_tasks` patterns are correct. Keep them.
- Per-task ownership of bound data (the `CellPayload.collision_payload` pattern just landed in P0.4) is the right shape — task-bound data must outlive the wait. **`D`-backed by the wait_for_task_completion mandate.**

---

## Section 5 — Post-quit native signal 11 / WorkerThreadPool finalization

**Project signature:** `0xC0000005` (Windows access violation) after `LOG_EXIT done`, only on automated `--quit-after-ready` and `BENCH_QUIT` paths. Visible `WM_CLOSE_REQUEST` quit clean.

**What the engine issues say:**

- Issue [#118354](https://github.com/godotengine/godot/issues/118354) — "Godot 4.6.2 stable crashes with an access violation when running a minimal project in headless mode with `--quit` on Windows" — *open*. Crash at `make_dir_recursive (core/io/dir_access.cpp:178)` while creating `user://logs`. **`D`** — confirms 4.6.2 has a `--quit` crash class on Windows, but the crash site is logging, not rendering. Different from ours; same family.
- Issue [#106228](https://github.com/godotengine/godot/issues/106228) — "Godot 4.4.1 Crash on Quit is still not fixed" — *open*. NVIDIA OpenGL driver involved (`nvoglv64.dll`). ~20% repro rate. **`D`** — confirms a quit crash class involves GPU driver teardown, not just engine shutdown.
- Issue [#96978](https://github.com/godotengine/godot/issues/96978) — "Application stops responding upon calling SceneTree.Quit" — *closed by PR #96959* in 4.4. Was specific to "Run on Separate Thread" for physics. **`D`**
- Issue [#84265](https://github.com/godotengine/godot/issues/84265) — "Read access violation crash when closing game if a node is no longer a child of the scene tree." **`D`** — confirms stray-node lifetime is a known quit-crash class.

**What this project's evidence says (from tracker):**

- All accepted post-`BENCH_QUIT` runs reach `LOG_EXIT done` first, with all tracked WorkerThreadPool tasks at zero (`background_processor.active_tasks=0`, `cell_preloader.task_ids=0`, etc., per tracker `2026-04-29 Reviewer Follow-Up Checks`).
- The crash is *after* project teardown completes. Native frames only; no GDScript backtrace.
- Visible manual `WM_CLOSE_REQUEST` does not reproduce.

**My assessment:**
- This is **almost certainly the same family of engine quit-crash issues** as #118354 / #106228 / #84265 — Godot's `SceneTree.quit()` path on Windows hits driver/finalizer access violations in some configurations. **`I`** (inference from issue family).
- The fact that `WM_CLOSE_REQUEST` works while `SceneTree.quit()` does not is consistent with #84265 and #96978 — both are about non-WM_CLOSE quit paths having stricter teardown ordering. **`I`**
- It is **not** evidence of a NEAR streaming bug. The streaming pipeline drains cleanly *before* the crash window. **`D`** (project tracker confirms zero tasks at LOG_EXIT).

**Implications for Godotwind Phase 2B design:**
- Park this as a known engine-family teardown issue. Do **not** make it a Phase 2B blocker.
- Acceptance criteria for Phase 2B (and any subsequent perf work) should accept: summary written + log clean *before* `BENCH_QUIT` = pass; post-`BENCH_QUIT` access violation is allowed if it matches the parked signature and no new GDScript backtrace appears.
- Document the engine-issue references (#118354, #84265, #69910) in the project tracker so the next agent does not redo this triage.

---

## Section 6 — OpenMW cell paging canonical pattern

**Sources read verbatim:**
- [`apps/openmw/mwworld/scene.cpp` (master)](https://gitlab.com/OpenMW/openmw/-/raw/master/apps/openmw/mwworld/scene.cpp)
- [`apps/openmw/mwworld/cellpreloader.hpp` (master)](https://gitlab.com/OpenMW/openmw/-/raw/master/apps/openmw/mwworld/cellpreloader.hpp)
- [`apps/openmw/mwworld/cellpreloader.cpp` (master)](https://gitlab.com/OpenMW/openmw/-/raw/master/apps/openmw/mwworld/cellpreloader.cpp)

**Cell load FSM:** **`D`** — There is no FSM. State is procedural via `mActiveCells` (CellStoreCollection), `mCurrentCell`, `mCellChanged`, `mCellLoaded`. Load sequence in `Scene::loadCell` (~line 469):
1. Insert cell into `mActiveCells`.
2. Add heightfield and pathgrid.
3. Call `insertCell()`.
4. Register rendering and sound.
5. Set `mCellLoaded = true`.

Transition triggers: `playerMoved()` → `requestChangeCellGrid()` → `changeCellGrid()`. Interior switch goes through `changeToInteriorCell()`, which **unloads all cells then loads the single interior** (no return-window).

**Threading boundary:** **`D`** — Main thread owns cell load/unload, physics/rendering insertion, navigator updates. Worker threads handle:
- `PreloadMeshItem::doWork()` — mesh template loading.
- `preloadCell()` — queued via `mPreloader->preload()`.
- Terrain preloading via `mPreloader->setTerrainPreloadPositions()`.
- The boundary handoff is `mRendering.getWorkQueue()->addWorkItem(item)`.

**`CellPreloader`:** **`D`** — Public API:
```cpp
void preload(MWWorld::CellStore& cell, double timestamp);
void notifyLoaded(MWWorld::CellStore* cell);
void clear();
void updateCache(double timestamp);  // "Removes preloaded cells that have not had a preload request for a while."
void setExpiryDelay(double); void setMinCacheSize(size_t); void setMaxCacheSize(size_t);
void setPreloadInstances(bool);
void setTerrainPreloadPositions(...); void syncTerrainLoad(); bool isTerrainLoaded();
```

State: `PreloadMap mPreloadCells`, `double mExpiryDelay`, `size_t mMinCacheSize/mMaxCacheSize`, counters `mEvicted / mAdded / mExpired / mLoaded`.

**`preload()` body:** **`D`** — submits a `PreloadItem` to `mWorkQueue->addWorkItem(item)`, stores `(cell, PreloadEntry(timestamp, item))` in `mPreloadCells`, evicts oldest if at max capacity.

**`updateCache()` body:** **`D`** — for each entry where `size >= mMinCacheSize && timestamp < now - mExpiryDelay`, abort the work item and erase. Then clear resource cache *from the worker thread* explicitly (the source comment: *"the resource cache is cleared from the worker thread so that we're not holding up the main thread with delete operations"*).

**`notifyLoaded()`:** **`D`** — when a cell actually loads, abort the preload work item and erase from `mPreloadCells`. Counter `++mLoaded`.

**Predictive prefetch:** **`D`** — **CORRECTION 2026-05-01 (post-roaster-review).** The prior text in this row claimed OpenMW had no velocity-based prediction. That was wrong. Re-verified via primary-source WebFetch of `apps/openmw/mwworld/scene.cpp` master: `Scene::preloadCells(float dt)` computes `predictedPos = playerPos + (playerPos - mLastPlayerPos) / dt * mPredictionTime` and feeds the predicted position into `preloadTeleportDoorDestinations`, `preloadExteriorGrid`, and terrain preload calls. `mPredictionTime` is the velocity-extrapolation time horizon, NOT a cache expiry timer, NOT a radius. The original streaming-reference-doc claim "OpenMW has the simplest implementation we can copy" was directionally correct. The real narrower distinction lies in the return-window/reclaim path and resource lifetime model, not prefetch.

**Cell unload sequence (`Scene::unloadCell`, ~line 413):** **`D`**
1. Iterate objects via `ListAndResetObjectsVisitor`.
2. Remove physics: `mPhysics->remove(ptr)`.
3. Remove navigator agents/objects.
4. Clear heightfield/pathgrid.
5. Drop mechanics: `getMechanicsManager()->drop(cell)`.
6. Remove rendering: `mRendering.removeCell(cell)`.
7. Erase from `mActiveCells`.
8. Notify world-space changed if empty.

**Return-window / reclaim:** **`D` (negative).** OpenMW has **no return-window or reclaim mechanism**. Cells are loaded/unloaded atomically. Cache expiry is timestamp-based, not navigation-based. There is no equivalent of our `_unloading_cells` / `_unloading_request_ids` parking. Closest mechanism is `removeFromPagedRefs()`, which moves hidden refs from paging to active rendering — not the same thing.

**Implications for Godotwind Phase 2B design:**
- OpenMW's pattern validates *part* of our design: per-cell ownership, off-thread preload, timestamp+size cache eviction. **`D`-backed.**
- OpenMW's pattern does **not** validate our reclaim-after-unload-limbo path — they don't have one. The reclaim path is a Godotwind-specific feature, justified by P0.4 verification but **not industry-standard**. The Phase 2B design should explicitly own this as a project-specific extension and document why we want it (returning fast cell crossings) versus the simpler atomic-unload that OpenMW uses.
- Resource cleanup *from the worker thread* (OpenMW's `updateCache`) is a pattern Godotwind does not currently use. Worth considering: the post-`BENCH_QUIT` `material_set_shader` loop may be partially attributable to main-thread cleanup hitting RIDs the renderer is still iterating. **`I`** — speculative; would need a project test.
- OpenMW DOES have velocity-based predictive prefetch via `Scene::preloadCells` (corrected 2026-05-01); Godotwind's `cell_preloader.gd` direction is consistent with it. Phase 2B should keep it.
- The OpenMW cache eviction signature (`mEvicted / mExpired / mLoaded` counters) is similar to what the lifecycle-event capture instrumentation already produces in this project. Convergent design = good signal.

---

## Cross-cutting findings (top 5)

1. **Our `material_set_shader null material` loop is almost certainly project-side, not engine-side.** No engine issue matches the exact signature. Both backed-out Phase 2B attempts hit it. The Phase 2B design must own iteration-stop ordering before bucket free, not assume engine guards.
2. **There is no documented canonical RID free order in Godot 4.6.** The project must specify and own its own order, derived from the using_servers strong-ref contract. The docs only say "keep strong refs to source resources"; everything else is implementation responsibility.
3. **Per-cell MultiMesh buckets are documentation-blessed**; world-scoped batching is documentation-condemned. The Phase 2B design lands on the right architectural shape; only the lifetime/free-order ownership needs proving.
4. **Off-thread `PackedScene.instantiate()` remains officially undocumented and engine-side fragile in 4.6** (Issue #79194 still open). Keep the flag off; revisit only if the issue closes with a fix, or after an isolated harness on the engine version in use.
5. **The post-`BENCH_QUIT` signal 11 belongs to a documented family of engine quit-crash issues** (#118354, #106228, #84265, #96978). It is not a NEAR streaming bug. Park it permanently with citations; do not gate Phase 2B on it.

## Findings the streaming reference doc should be updated with

Suggested edits to `docs/reference/how to streaming.md` (separate PR, not part of this research note):
- Update the `U` tag on `PackedScene.instantiate()` thread-safety to cite Issue #79194 (still open) as primary source.
- Add citation for Issue #69910 / PR #69972 to the RID-lifetime section.
- The "OpenMW has the simplest implementation we can copy" claim was directionally correct on prefetch (corrected 2026-05-01 — OpenMW DOES have velocity-based predicted-position preload via `Scene::preloadCells` + `mPredictionTime`). The narrower correct distinction is: OpenMW has **no return-window/reclaim mechanism** (cells unload atomically) and uses **OSG `osg::ref_ptr`** rather than Godot `RenderingServer` RIDs for resource lifetime. Phase 2B and the existing P0.4 reclaim path must own those design justifications locally — those parts are Godotwind-specific, not OpenMW-derived.

## What this research note does NOT cover (deliberate scope cuts)

- Specific Godot 4.6 → 4.7-dev render-graph changes. (Out of scope; gate on a separate research lane if Phase 4 wants to bump the engine version.)
- Vulkan vs D3D12 driver-specific shutdown crash signatures. (Out of scope; #106228 hints they exist but our Windows-D3D12 tracker entries match the engine-family parked signature already.)
- Decima / UE5 / Unity DOTS cell paging source — these are proprietary and the streaming reference doc's citations are second-hand. Calling them out here would not produce primary-source D claims.
