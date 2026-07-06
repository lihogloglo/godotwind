# Distant Rendering Recovery Plan — 2026-07

Follows the 2026-07-05 audit (`docs/audit/distant_rendering_perf_audit_2026_07_05.md`)
and interactive visual verification with the user. Decisions locked with user
2026-07-05: runtime HLOD merger parked now / deleted after replacement lands;
Phase 1 hot loops go to C# directly; empty-ring approach = impostors first,
gated on the impostor storage-format fix (disk budget constraint: no multi-GB
caches).

## Problem statements (data-backed)

1. **Traversal churn (perf):** standing still = ~142 FPS full stack
   (render_cpu 2.7 ms, render_gpu 3.2 ms); moving flyby = 56.7 FPS avg,
   p95 23.8 ms. Named offenders from autopsy: unload 9–75 ms
   (budget 4 ms), cell_preloader_update 53–60 ms (even with all tiers off),
   pending_loads_async 253 ms, single instantiate 38 ms. Budgets check time
   between work items; items are too coarse.
2. **Empty 400–1000 m ring (visual):** default stack renders only FAR
   impostors there; coverage is sparse (208/937 candidates baked, v5/v6
   partial, name-pattern candidacy, 256-layer runtime cap). User-verified
   jarring gap.
3. **Dishonest instruments:** `static_visuals` toggle clamps range to 150 m
   (doesn't hide), changes loaded-cell ring, re-arms impostor suppression —
   three effects in one switch; tier_view overlay draws ground-projected
   rings that lie at altitude; benchmarks run under a user 144 FPS cap;
   9 cells sit in `loading` forever.

## Disk budget facts (measured 2026-07-05)

- models cache 3.0 GB (9,249 .res), impostors 905 MB for 208 candidates
  (normal atlas stored as uncompressed ImageTexture .res ≈ 4 MB vs 0.5 MB
  albedo PNG), terrain 169 MB, ESM cache 80 MB.
- Rejected on size: naive merged full-res per-cell bake (≈ 8 GB).
- Accepted: cooked per-cell manifests (~15–20 MB total), impostor
  densification after storage fix (≤ 1 GB, and −750 MB on existing),
  optional simplified far proxies (0.2–0.8 GB) only if impostors prove
  insufficient.

## Phase 0 — Honest instruments (prerequisite for everything)

1. `toggle static_visuals` = pure visibility ablation: hide ALL static
   renderer output (buckets, direct instances, visual proxies); do NOT touch
   loaded-cell ring or impostor suppression. Move range clamping to a new
   `static_range <m>` console command.
2. tier_view overlay: shrink rings with altitude (`r = sqrt(R² − h²)`,
   band vanishes when h > R) so the overlay matches the engine's 3D
   camera-distance semantics.
3. Diagnose + fix the 9 permanently-`loading` cells.
4. Benchmark hygiene: record `Engine.max_fps`/vsync in report metadata and
   warn when capped; add render_cpu/render_gpu (added to heartbeat
   2026-07-05) to benchmark CSV columns; ladder runs set max_fps=0 for the
   duration.
5. Correct `PAGING_MIN_SIZE` provenance comment (OpenMW default is 0.01,
   ratio is unit-free; 0.14 claim is wrong) — value retune deferred to
   Phase 2 candidacy work.

Acceptance: toggling static_visuals changes ONLY rendering (cells/queue
stats unchanged); ladder rung deltas become pure render ablations; overlay
matches reality when flying.

**Status 2026-07-05: implemented.** Streaming policy split into
`set_static_streaming_enabled()` (9 sites moved off `_mid_tier_visible`);
`static_range` command added; overlay projects camera-distance spheres
(`sqrt(R² − h²)`, drift-rebuild at 5 m); never-completed cells now unload via
the existing request-parking limbo (leak fix), and the heartbeat reports
`loading=N (tail=M)` to separate in-flight from deferred-tail; benchmark
reports record max_fps/vsync, CSVs carry `render_cpu_ms`/`render_gpu_ms`,
and `bench_ladder` uncaps Engine.max_fps AND vsync for the run (user
settings default vsync ON — that was the mystery 144 cap). PAGING_MIN_SIZE
provenance corrected. Unit tests green (mode metadata 9, ladder 16,
contract 3 — the contract test had a pre-existing `contains_key` API bug,
fixed). First verification ladder (`ladder_phase0_purity_check`, vsync still
on) proved the headline claim by controlled ablation: rung 2
(+near_gameplay, statics HIDDEN but streaming the full ring) = 58.3 avg FPS
/ 17.15 ms at **93** draw calls; rung 3 (statics visible) = 47.0 / 21.28 ms
at 709 draws (rung 3 partially contaminated by a concurrently-running gdUnit
process — treat the +4 ms render delta as an upper bound). The moving-flyby
cost is streaming churn, not rendering. With vsync disabled by the new
ladder hygiene, the spawn scene settles at **~597 FPS** — the old "144 FPS
empty baseline" was a vsync ceiling hiding 4× headroom. Notes: pre-Phase-0
ladder numbers are NOT comparable to new ones (empty rung now streams
hidden statics; FPS uncapped). One uncapped ladder run crashed natively
~25 s in near an interior-pocket load (`phase0_purity_check_b`); it did NOT
reproduce (`_c` completed cleanly) — flaky pre-existing timing race
surfaced at ~600 FPS, tracked for Phase 1 which owns the churn paths.

**Clean uncapped baseline for Phase 1** (`ladder_phase0_purity_check_c`,
fps_capped=false in metadata, no concurrent processes):

| rung | stack | avg FPS | avg ms | p95 | draws |
|---|---|---|---|---|---|
| 2 | terrain+near, statics hidden-but-streaming | 63.5 | 15.74 | 21.9 | 93 |
| 3 | + statics visible | 52.6 | 18.99 | 25.6 | 735 |

Empty scene settles ~597 FPS (~1.7 ms). So during the moving flyby:
**streaming churn ≈ 14 ms/frame; rendering all visible statics ≈ 3.3 ms.**
Phase 1's job is the 14 ms. Phase 1 acceptance reads against THESE numbers.

## Phase 1 — Traversal churn (C# per user decision)

**Wave 1 diagnosis + fixes (2026-07-05).** The four offenders turned out to
be I/O-bound / engine-call-bound, not compute loops — so wave 1 is slicing
and I/O fixes; C# applies in wave 2 to whatever compute cost survives
re-measurement (per this plan's own "optimize one measured subpath" rule):

1. **Unload 9-75 ms → CrashBreadcrumb file I/O.** Every breadcrumb was
   `FileAccess.open+store+close` (4-8 ms each on this machine per the
   project's own 2026-04-20 note); the unload tick wrote 2/frame plus 1 per
   drained cell, inside the `unload` bracket. The sub-brackets showed
   `unload_cell:total` at only ~2 ms — the rest was breadcrumbs. Fix:
   persistent handle + seek(0) + fixed-width write + flush (OS page cache
   survives SIGSEGV; same forensics, ~µs cost).
2. **cell_preloader_update 53-60 ms → per-cell model-warm burst.** One new
   predicted cell = get_objects_in_cell + `request_model_async` for every
   unique model in ONE frame; each request does main-thread file I/O
   (file_exists + load_threaded_request). Fix: entries start in a "kicking"
   state and drain a few paths per frame under a 1 ms deadline passed from
   the streaming manager (prediction window is 0.3-4 s; latency unaffected).
3. **pending_loads_async 253 ms one-shot → instrumented**, not guessed:
   `[cell-request-start]` warn (8 ms threshold) splits manifest-build vs
   profile-filter cost. Rare event; data will name the fix.
4. **instantiate 38 ms one-shots → indivisible engine atoms**
   (PackedScene.instantiate of large prefabs; completion add_child ≈13 ms is
   already capped at 1/frame and documented as throughput-not-latency).
   Structural fix arrives with Phase 3 prebaked payloads; parked.

Bonus finds while attributing:
- `StaticObjectRenderer.get_stats()` walked all ~1,700 buckets with
  reflective `.get()`s **every frame during benchmarks** (and computed HLOD
  override counts with HLOD off). Early-out + per-frame memo — also removes
  a benchmark observer effect.
- ~10-15 ms/frame of flyby time is attributed to NOTHING (streaming ≈0.3 ms,
  render_cpu ≈2.4 ms, render_gpu ≈4 ms, frames 19-21 ms). New
  `[we-autopsy]` breakdown times world_explorer._process blocks (pocket
  manager, weather, ocean, horizon, stats) to name it. Wave 2 acts on this.

**Wave 1 verification (ladder_phase1_wave1, uncapped, clean run):**

| rung | baseline (a.m.) | wave 1 | delta |
|---|---|---|---|
| 2 statics hidden | 63.5 FPS / 15.74 ms / p95 21.9 | **101.8 / 9.82 / p95 14.2** | −5.9 ms |
| 3 statics visible | 52.6 FPS / 18.99 ms / p95 25.6 | **78.6 / 12.72 / p95 18.3** | −6.3 ms |

Confirmed by section timings: `unload` now 2-4 ms (was 9-75 — breadcrumbs),
`cell_preloader_update` 0-1.2 ms (was 53-60 — slicing).

**Wave 2 shipped (2026-07-05, same session):**
1. Pocket load retry treadmill: a failed `_load_pocket` (async capacity
   busy) re-ran the full pipeline every frame near a door — space-info
   lookup, portal premark, push_warning with backtrace. Now a 500 ms
   per-cell retry cooldown (`LOAD_RETRY_COOLDOWN_MSEC`); the preload radius
   gives seconds of margin.
2. Pocket finish-up 228 ms atom: progressive attach. Children are stripped
   off the detached async result (no tree notifications), the empty root is
   added, then children attach under a 2 ms/frame budget with per-child
   finalize walks (`_pocket_finish_up_attach_step`, phase 0); environment /
   door registration / lightbox run after the drain. The rush path
   (player at door, fade waiting) keeps the old single-frame collapse.
   Eviction mid-drain frees pending detached children (leak guard in
   `PocketSlot.clear()`).
3. The pending_loads_async 118-241 ms residual root-caused: NOT the
   manifest build — it was door registration on the `cell_loading` signal:
   `_identify_shell_for_portal` re-walked every cell ref per door with
   base-record lookups + pattern matches (O(doors × refs), twice with the
   fallback pass). Fix: `_build_shell_candidates` one-pass prefilter per
   cell (records resolved once, patterns precomputed) + per-cell descriptor
   cache in `MorrowindTransitionProvider` (door layout is static data —
   revisits are free). Semantics preserved exactly (radius-gated
   non-seamless flag, building-pattern primary, 3 m static fallback).
   Unit tests: interior_door_identity 3/3, interior_transition_phase1 10/10.

4. Collapse trigger fixed (wave 2b): the finish-up fast path used a
   proximity heuristic (within 2× interact radius when the load completes)
   — a flyby merely passing a door collapsed a 50-child interior attach
   into one frame (measured 408 ms, no intent to enter). Now collapse fires
   only when `_is_transitioning` (a fade is actually waiting). The
   progressive path keeps the pocket invisible until phase 1, so the
   "unlit empty geometry" rationale for the proximity rule is obsolete.
5. `[door-register]` warn (8 ms threshold) added around
   `register_exterior_cell_doors` — wave 3 scoping data for the remaining
   first-touch cost (shell-candidate classification: ~400-600 base-record
   lookups + ~38 substring matches per static, compute-bound GDScript →
   the C# port target alongside the 9-22 ms manifest build).

Manual visual check still owed (user, next interactive session): enter an
interior through a door normally (fade path) and rush-enter immediately on
arrival — the collapse path (now gated on `_is_transitioning`) preserves old
behavior there, but the progressive path changes WHEN children enter the
tree for preloaded pockets.

**Wave 2b verification (ladder_phase1_wave2b, uncapped, clean):**
rung 2 = **128.6 FPS / p95 11.4 ms** (baseline 63.5 / 21.9); rung 3 = 86.7 /
p95 16.0. Worst pocket frame 408 → 154 ms (collapse-trigger fix verified).
Full arc today, statics-visible flyby: **52.6 → 78.6 → 88.9 → 86.7 FPS**;
statics-hidden: **63.5 → 101.8 → 128.6 FPS**.

**Wave 3 shipped (2026-07-05, same session):**
1. Door sync tree-walks DELETED for exterior registration: the whole-scene
   walk per door (41 doors × walk = 166-211 ms/cell, recurring — proven by
   cell (-3,-2) paying twice despite the descriptor cache) was fully
   redundant. The spawn adapter already stamps `door_instance_key` on every
   spawned door with the identical key format
   (`morrowind_object_spawn_adapter._attach_door`,
   `make_exterior_portal_key` == `make_exterior_door_instance_key` ==
   "ext:x,y:refid:num"). Interior pockets keep the sync — their search root
   is the small pocket subtree.
2. Pocket completion residual instrumented (`[pocket-complete]` warn around
   `get_async_result` — suspect: payload unpin cascading resource frees).
   Data pending from the next run that loads a large interior.
3. Cold manifest builds throttled to ONE per frame in
   `_process_pending_loads_async` (new `has_cell_manifest()` probe): two
   cold 9-22 ms atoms no longer stack in a single frame; warm cells
   (usually prepaid by the CellPreloader) submit freely.

**Wave 3 verification (ladder_phase1_wave3):** rung 3 (statics visible) =
**94.1 FPS / p95 14.1 ms** — best yet. Full rung-3 arc for the day:
52.6 → 78.6 → 88.9 → 86.7 → 94.1 FPS. Door-register worst case
210.7 → 50.2 ms (tree-walk removal verified; the remaining 15-50 ms is the
first-touch shell classification, once per cell per session). Rung 2 is
run-to-run noisy (75-128 FPS across waves) — dominated by cold-start
one-shots, not a regression signal; rung 3 is the stable indicator.

**Wave 4 shipped (2026-07-05, session 2):**
1. **First-touch door/shell classification** (15-50 ms/cell): three fixes in
   `morrowind_transition_provider.gd`, no API change:
   - per-base-record classification memo (`_ref_class_cache`) — the
     classification is a pure function of static ESM data; every cell was
     re-paying base-record lookup + to_lower + up to 38 substring matches
     per ref;
   - uniform-grid spatial hash (`_bucket_shell_candidates`, bucket edge =
     the 5 m search radius) — the per-door scan was O(doors × candidates)
     (41 doors × hundreds of candidates on grid (-3,-2)) and now scans a
     3×3 bucket neighborhood;
   - per-portal shell logs demoted info/warn → debug. This was the sleeper:
     a single no-shell `Log.warn` measured 18 ms in the unit-test env
     (push_warning collects a script backtrace; 41 doors = 41 log lines
     per cell). Same "hot loop is actually I/O" pattern as waves 1-3.
   New `[door-shell]` warn (>8 ms) splits build vs identify for any residual.
   Smoke-verified: zero [door-register]/[door-shell] warns at Seyda Neen
   spawn (previously 15-50 ms warns on first touch).
2. **Instantiate atom attribution**: `[inst-atom]` warn (>30 ms) in
   `cell_manager.process_async_instantiation` names route/type/model/grid
   of each big indivisible instantiate, feeding the Phase 3 prebake-split
   candidate list.
3. **Pocket first-attach probe**: `[pocket-begin]` / `[pocket-attach]`
   warns (>8 ms) with per-step pipeline-compile deltas
   (`PipelineCompileMonitor.snapshot()`) and the worst child named, at both
   `_begin_pocket_finish_up` paths and each attach step. Confirms/refutes
   the pipeline-compile hypothesis next time a slow first-attach fires.

**Wave 4 verification (BLOCKED at rung 3 — see crash section):** rung 2
(statics hidden) = **127.0 FPS / p95 11.8 ms** (wave 2b: 128.6/11.4 — in
family, rung 2 is cold-noisy; no regression). Rung 3 numbers unavailable:
3/3 ladder attempts segfaulted mid-run. Unit suite 10/10; interactive smoke
clean (0 SCRIPT ERRORs, standing 137-144 FPS).

**BLOCKER — native crash class in streaming churn (3/3 ladders, 2026-07-05
session 2).** Three segfaults at three different points, all inside the
concurrent-streaming window (static bucket publish + pocket load + unload
churn), all with uncapped FPS:
1. Run 1: main thread, `material.get_rid()` in
   `cell_static_bucket._get_valid_material_rid` (line 437) during
   `configure_step` publish; `is_instance_valid` passed immediately before
   → use-after-free or engine lazy-material-RID race. Breadcrumb: camera
   cell (-3,-2), 12 cells unloaded in the final 1.4 s, 17 queued, MID=3778.
   Settle was 615 FPS.
2. Run 2: non-script thread (C++ backtrace only, no symbols), during the
   statics-visible rung after a pocket load + wet-shader tangent warnings.
   Settle was 43 FPS — this run survived longest.
3. Run 3: abrupt segfault (no backtrace at all) during a pocket load retry
   ("async busy") at settle 643 FPS — matches session 1's documented flaky
   crash ("near an interior-pocket load at ~600 FPS") exactly. Zero pocket
   finish-ups had run → wave 4's probe code never executed → wave 4 is
   excluded as the cause for this signature.
Reading: a PRE-EXISTING thread-safety race (same class as the April
"second SIGSEGV" parked in the NEAR-tier notes) whose reproduction rate
scales with FPS — session 2's faster streaming frames (waves 1-4 removed
the 15-50 ms stalls that used to slow exactly these churny windows) widened
the 600+ FPS regime where the race window gets hit hundreds of times per
second.

**Wave 5 CRASH FIX (2026-07-05, session 3) — RESOLVED via single-flight
loading.** Root cause identified and verified against the engine tracker:
Godot ≤4.6's threaded resource loader races when multiple loads pull the
same sub-resource concurrently — the anti-deadlock logic misclassifies
concurrent loaders and double-loads the dependency, producing use-after-free
(upstream godotengine/godot#111202; fixed for 4.7 by PR #118824, which
names a `resource_changed_connections` UAF — materials connect to their
textures, matching our `material.get_rid()` main-thread crash). Our baked
models share textures/materials, so 16 concurrent model loads + impostor
worker loads + shape-pack worker loads = contested sub-resources at high
frequency. Three subsystems had independently half-fenced this engine bug
already (MAX_CONCURRENT_ASYNC_LOADS "segfaults when hammered" comment,
StaticShapeCache per-key semaphores, the impostor "ResourceLoader IS
thread-safe" comment — now corrected).
Fix shipped: `MAX_CONCURRENT_ASYNC_LOADS` 16 → 1 (model pipeline
single-flight; enforced at request time AND deferred-drain time) and
`TEXTURE_LOAD_MAX_ACTIVE_TASKS` 2 → 1 (impostor atlas jobs single-flight).
At most two loader operations engine-wide. Revisit when the engine carries
the upstream fix (4.7 / a 4.6.x cherry-pick) — restoring concurrency is a
one-constant change per pool.
**Verified: 2/2 consecutive ladders completed** (previously 3/3 crashed),
both settling in the 600+ FPS danger regime (628 / 613):
- wave5a: rung 2 = 130.1 FPS / p95 11.2, rung 3 = **95.9 / 13.9**
- wave5b: rung 2 = 128.6 / 11.4, rung 3 = **96.3 / 14.0**
Single-flight cost NOTHING — both rungs are the best numbers of the arc
(rung-3 day arc: 52.6 → 96.3). The at-exit backtrace after "sequence
complete" remains (known, parked). Wave-4 rung-3 verification is hereby
complete too.

**Wave 6 shipped (2026-07-05, session 3, continued):**
1. **Impostor atlas 525 ms one-shot FIXED — incremental layer commits.**
   Root cause: every atlas change re-uploaded the ENTIRE Texture2DArray via
   `create_from_images` on the main thread (O(n²) upload over a session;
   525 ms measured at the startup atlas completion). Canonical fix
   (texture-streaming pattern): full rebuilds now allocate capacity padded
   to the next power of two (unused layers never sampled — instances
   address layers by index), and append-only changes drain per-frame via
   `ImageTextureLayered.update_layer` (verified against 4.6 docs) under
   the publication-slice deadline. Full rebuild remains only for: first
   build, capacity growth (O(log n) times), and compaction remaps
   (`array_layout_dirty`). Verified by smoke: worst `imp:` frame
   525 → 11.6 ms (bounded by its granted slice budget), 0 errors.
   NOTE: the bench ladder rungs 2-3 never enable the FAR tier — this class
   of hitch is only visible in default-stack smokes.
2. **Phase 3 M.0 SHIPPED — C# `NativeCellManifest`**
   (src/native/NativeCellManifest.cs + factory method): custom binary
   format (magic GWM1 v1, interned string table, fixed per-record block),
   `CookFromRecords` (offline, via prebake UI when wired in M.1) +
   `LoadFromFile` (plain FileAccess — safe on background threads, no
   ResourceLoader involvement, immune to the ≤4.6 loader race and never
   queued behind single-flight model loads). Derived-at-load fields
   (object_id, source_key, adapter_payload_id, model_item_id) mirror
   `_make_record`. Round-trip unit test green
   (tests/unit/test_native_cell_manifest.gd, 2/2).
3. `[inst-atom]` warn now includes the `ml=` model-load subslice — splits
   blocked-sync-load time from node construction for the Furn_rug_02 class
   of atoms (the .res is only 180 KB, so file size is innocent).

**Wave 6 verification (ladder_phase1_wave6, sequence complete):** rung 2 =
128.4 / p95 11.3, rung 3 = 93.2 / p95 14.1 — both within the post-crash-fix
band (rung 3: 95.9 / 96.3 / 93.2), no regression. Third consecutive
completed ladder since single-flight loading.

**Wave 7a shipped (2026-07-05, session 4): no sync model loads in the
instantiate lane.** The `Furn_rug_02.NIF` class of atoms (102-119 ms) was
100% blocked model load (`ml=110.4` of 110.5 ms — zero node construction):
the sync branches (node_sync / static_cold / light) fell back to a blocking
`get_model` on a cache miss, queued behind the single-flight loader. Fix in
`cell_manager.process_async_instantiation`: cache-miss entries park (the
existing deferred-requeue mechanism), request their model via
`request_model_async`, and unpark when (a) a relevant cache key lands
(item key, or plain key — a plain hit makes the sync path an engine-cache
hit) or (b) the loader callback fires — callbacks run for EVERY joiner of
a deduped disk-path load, which covers item-variant keys (one disk file,
many cache keys; only the first requester's key fills). A 5 s bounded wait
falls back to the old sync path so termination is guaranteed
(`[inst-model-wait]` warn names any entry that hits it). Verified across
three smokes: zero [inst-atom], zero [inst-model-wait] in the final run,
0 script errors, standing FPS 121-140.

**Wave 7b: full-worldspace manifest cook SHIPPED + RUN (2026-07-05).**
Standalone runner `src/tools/prebaking/cell_manifest_cook_runner.tscn`
(hydrology-runner pattern; cooks through the existing runtime build so
output equals it by construction). First full cook: **1,189 cells, 142,858
records, 16.4 MB total, 24.5 s, 0 failures** (215 empty ocean cells
skipped) → `<cache>/manifests/cell_<x>_<y>.gwm`. Inside the 15-20 MB
target; the rejected naive geometry bake was ≈8 GB.

**Wave 7 verification (ladder_phase1_wave7, sequence complete):** rung 2 =
120.0 / p95 12.2 (rung-2 cold noise band), rung 3 = **93.8 / p95 14.5** —
in band (93.2-96.3), no regression. Exterior [inst-atom] warns GONE.

**Wave 8 M.1a shipped + MEASURED A WASH (2026-07-05, session 5).**
Flag-gated cooked-manifest consumption landed in
`morrowind_world_object_source.gd` (`use_cooked_manifests`): hydrates
records from .gwm via the C# codec, preserves both runtime-build side
effects (`_source_cell_cache` for door registration; `_spawn_payload_cache`
via new lazy ESM resolution on first interactive use). Split measured with
the new `[cooked-manifest]` warn: **binary load = 0.4-0.9 ms** (format
vindicated) but **hydration = 8-50 ms per cell** — constructing ~300
GDScript WorldObjectRecord objects (+ per-record Dictionary marshalling)
IS the manifest cost; the classification work the cook removes was never
dominant. Exactly what the wave-3 C# honesty note predicted. Flag default
**OFF** (don't ship a wash); all infrastructure kept for M.1b.

**Remaining named work (wave 8, revised by the M.1a measurement):**
1. Phase 3 **M.1b — the real win**: streaming consumers read the C#-held
   manifest data directly (packed arrays / indexed accessors), no
   per-record GDScript objects in the streaming path. Scope: the
   classification loop (`request.classify_index`), static-prepare counts,
   and instantiation-entry queueing consume codec accessors; NODE-route
   interactive spawns can still hydrate single records lazily (rare,
   proximity-gated). First step: batch accessors on NativeCellManifest
   (parallel packed arrays in one marshal) replacing per-record
   GetRecordFields. This is the honest C# scope and a substantial,
   session-sized refactor — start it fresh.
2. **Item-variant model loads ~114 ms (interior pockets)** — wave-7
   ladder data: the two surviving [inst-atom]s are
   `f\Furn_rug_02.NIF grid=(0,0) (interior)`, ml=114.8/112.9 of ~115 ms.
   The rug is carryable ⇒ item-keyed `get_model(path, item_id)` ignores
   the plain-key cached PackedScene and pays the item-variant load/
   post-process path. Suspect `_load_packed_scene_from_disk` + item
   collision variant processing, not disk I/O (180 KB file). Fires during
   pocket async loads (hidden latency, not a visible hitch unless
   rushing). Investigate the item-variant path before fixing.
3. "silver shortsword" 151 ms pocket attach (needs churny repro),
   `light:` 3-15 ms startup sections, transition-frame 36-49 ms peaks
   (fade-covered) — carried from wave 6.
3. Pocket first-attach: worst child = "silver shortsword" 151.5 ms with
   ZERO pipe delta (**pipeline-compile hypothesis REFUTED**); did NOT
   reproduce in a quiet scene (walk/rush door tests: no pocket-attach warn
   at all) — churn-dependent. Suspects: first CollisionObject3D waking
   Jolt, interactable wiring, wettable adapt. Needs a churny repro.
4. Recurring `light:` sections 2.6-14.6 ms in startup-burst overruns.
5. Transition-frame peak 36-49 ms (fade-covered; walk/rush door tests) —
   cosmetic priority only.

**C# port decision (honest note against the "C# now" mandate):** every
offender Phase 1 actually found was file I/O (breadcrumbs, model warms), an
O(n²) algorithm (door shells), a redundant walk (door sync), or an unsliced
atom (pocket attach) — C# would have fixed none of them. The one genuinely
compute-bound loop left is `_make_manifest_from_cell` (9-22 ms/cell): its
cost is constructing GDScript `WorldObjectRecord` objects consumed by
GDScript callers, so a C# port pays Variant marshalling both ways and keeps
most of the cost. The industry answer is Phase 3 (cook manifests offline,
load as .res) which deletes the runtime build outright; the 1-cold-per-frame
throttle bounds it until then. If the user still wants the C# port as an
interim, the honest scope is "C#-owned record data + packed-array manifest"
— a consumer-side refactor, not a loop port.

**Wave 2 scope (named by the new instrumentation):**
1. `InteriorPocketManager` — THE dominant remaining offender. `[we-autopsy]`
   attributes pocket=6.7-61.7 ms spikes during the flyby and one 228.8 ms
   frame = interior finish-up attaching ~50 children in one synchronous gulp
   (`async complete: 'Balmora, Itan's House' → finish-up`). Slice finish-up
   under an attach budget; review whether shell preloads should trigger at
   flyby distances at all.
2. `pending_loads_async` residual 170-224 ms one-shots — bigger than the sum
   of visible `[cell-request-start]` warns (max 21.6 ms); needs one more
   attribution level inside `_request_cell_async`.
3. Cold manifest build: 9-21 ms per cell for 136-248 objects
   (`[cell-request-start]` data) — compute-bound GDScript record
   construction; the first concrete **C# port target** per the user's
   decision.
4. Steady tail: `instantiate` 3-8 ms and `unload_cell:emit_unloaded` ~1.2 ms
   per crossing — attack after 1-3.

Port the four proven offenders to C# kernels with per-item deadline checks
(pattern: frame-budgeted incremental work, preemptible at item granularity):

1. Cell unload path: detach immediately, free N nodes/RIDs per frame from a
   drain queue owned by the payload. No single frame may free a whole cell.
2. `cell_preloader_update`: find why it burns 50–60 ms with zero tiers
   enabled (suspect: synchronous list walk or threaded-load polling);
   move scan/dispatch to C#; cap per-frame work.
3. `pending_loads_async` burst: slice manifest build/classification;
   C# `NativeCellClassifier` fed by packed arrays from the ESM cache.
4. Instantiate one-shots: identify the >30 ms atoms (large PackedScenes);
   split at prebake if possible, else amortize sub-tree attach.

Acceptance (standard flyby, HEAD, clean worktree, max_fps=0): no streaming
section > 4 ms in autopsy; p95 ≤ 12 ms; moving avg FPS within ~20% of
standing FPS; heartbeat render split unchanged (proves we didn't shift cost
into rendering).

## Phase 2 (REVISED 2026-07-05, user-approved) — Fill the 400–1200 m ring
## with OFFLINE-baked merged chunk proxies; impostors retreat to ≥1.2 km

**Course change after the strategic review (session 6).** The original
impostors-first plan for the ring is reversed; the old "fallback" is now
primary. Rationale (research-verified):
- Both proven Morrowind distant-rendering solutions use REAL geometry in
  this band: MGE XE bakes merged, polygon-reduced statics offline
  (explicitly because MW's bottleneck is draw count, not triangles);
  OpenMW's object paging merges real geometry. Neither uses billboards at
  400 m.
- Impostors of hard-edged architecture at 400 m read flat: baked lighting
  fights the dynamic sun, parallax breaks under camera translation. They
  are the right tool ≥1.2 km (where ours already work).
- Storage/VRAM: Godot 4.x has NO texture/mesh streaming (verified — the
  engine's own "missing for AAA" list); impostor atlases at ring quality
  strain both disk (905 MB for 208 bakes already) and resident VRAM.
  Merged low-poly MW geometry is cheap on both.
- No engine rescue incoming: the GPU-driven renderer (reduz's design,
  Vulkanised 2026) is explicitly deferred.
- Our own data: draw calls are not the bottleneck at ~650-2k draws
  (halving them changed FPS by 0.2), GPU render sits at 2-6 ms — but a
  naive MID extension to 1.2 km would produce 5-9k draws; merging
  (chunk = 1 draw) is what makes real geometry affordable. The RUNTIME
  merger failed (861 ms stalls, no simplify, segfault class) — offline
  baking removes every one of those failure modes.

**Constants:** `CHUNK_START = MID_END (400)`, `CHUNK_END = 1200` in
distance_utils.gd. `FAR_START` stays at MID_END until the chunk tier
ships (moving it early would empty the ring), then moves to CHUNK_END.

**Baker STATUS (2026-07-05, session 6):** v2 verified on the Seyda Neen
test region (7×7 cells → 16 chunks): **16/16 baked, 0 failures, 2,441 refs,
14.0 MB total, 10.1 s single-threaded**. v1 measured 92.3 MB — diagnosed
(headless inspect script): geometry was fine (~55k verts/chunk, compressed
attributes active) but every chunk re-embedded its materials' RAW textures.
v2 fix = shared material library: dedup by albedo-image hash BEFORE the
merge (also collapses kernel surface groups), textures GPU-compressed once
via PortableCompressedTexture2D S3TC, chunks reference materials
EXTERNALLY. 184 shared materials for the region. Worldwide extrapolation:
~350 chunks × ~0.7 MB + library ≈ **~250 MB** — inside the constraint
BEFORE the decimation lever.
**Bake-speed budget (user requirement):** whole-world chunk bake must stay
≤ ~2 min for new players. Measured trajectory: ~3-4 min single-threaded →
parallelize chunk merges across WorkerThreadPool (kernel is thread-safe by
design) → well under budget. Texture compression is once-per-material
(~1.4 s first material = encoder warmup, then fast).
**Decimation lever (later, if size/quality warrants):** Godot bundles
meshoptimizer (generate_lods IS meshoptimizer) but exposes no direct
simplifier to scripts; the clean route is a small C# P/Invoke binding of
the meshoptimizer C library to decimate stored LOD0 for ring-only meshes.
**Lesson (runner scenes):** a GDScript parse error leaves the runner as a
scriptless idle window — looks like a hang (cost one 19-min false hang).
The visible symptom: autoload init lines then silence, zero output files.
Check the launch log for "Parse Error" FIRST; `--check-only` is unusable
here (headless autoload false-negatives).

**Baker (offline, runner-scene pattern):**
1. Group exterior cells into 2×2-cell chunks (single size to start —
   measure before adding the adaptive 4×4 outer band).
2. Per chunk, gather static records (world-object source manifests — the
   Phase 3 cook infrastructure is the feedstock), min-size gate at the
   OpenMW ratio 0.01 against CHUNK_START (radius ≥ ~4 m).
3. Load each unique model's baked .res once, extract MeshInstance3D
   surfaces (mesh arrays + resolved material + relative transform),
   build ObjectPagingKernel.RefInput/SubMeshInput shapes.
4. Merge via `ObjectPagingKernel.merge_refs(force_merge_all=true)` —
   the existing C# kernel (material-grouped, ≤64 surfaces/chunk) — then
   `ObjectPagingKernel.generate_lods()` for the embedded LOD chain.
5. Save one ArrayMesh .res per chunk + an index; report totals.
   Disk estimate 0.2–0.8 GB (within the no-multi-GB constraint).

**Runtime consumer SHIPPED (2026-07-05, session 6):**
`src/core/world/chunk_proxy_renderer.gd` — server-direct chunk pages:
single-flight threaded loads (chunk files share the material library;
≤4.6 loader race discipline), 1 RS instance per chunk, visibility band
[CHUNK_START−radius, CHUNK_END+radius] with FADE margins, shadows OFF,
distance eviction with hysteresis, rescan every 32 m of camera travel.
Wired in native_streaming_manager (created at init, auto-enables when a
bake exists, driven per-frame under a 1 ms budget with a `chunk_tier`
profiler section); `_apply_impostor_request` flips impostor start
MID_END ↔ CHUNK_END based on chunk-tier state. Console:
`chunks_enable` / `chunks_disable` / `chunks_stats`.
Smoke-verified: 16-chunk test bake indexed + rendering in-game (prims
390k → 1,055k standing at Seyda Neen, +~480 draws, 128 FPS, 0 errors).

**Full-world bake (2026-07-05):** 321 chunks, 58,522 refs, 18.8M verts,
**391 MB** (373 geometry + 17 shared materials), 956 unique models, 503
shared materials, **146.7 s serial, 0 failures**. Slightly over the 2-min
budget → parallelize merges across WorkerThreadPool (kernel is
thread-safe) when convenient. Size lever if wanted: meshoptimizer
decimation of stored LOD0 via C# P/Invoke (~2× reduction expected).

**MID↔CHUNK boundary — CONTENT SELECTION SHIPPED (2026-07-06).** Both
range-fence attempts failed with an irreducible ±radius error (begin =
CHUNK_START − radius → coplanar solid/solid z-fight shimmer; begin =
CHUNK_START + radius → cell-sized holes until MID streams in — both
user-verified 2026-07-05). Root cause: one origin-distance band per merged
chunk cannot express a per-object seam against per-group MID culling.
OpenMW study (`inspos/openmw/apps/openmw/mwrender/objectpaging.cpp`)
confirmed the canonical answer is selection by IDENTITY, not distance:
paged chunks are keyed on the active grid and rebuilt to exclude
active-cell content. Since runtime re-merging is rejected here, the
adaptation is the UE World Partition HLOD pattern (one HLOD per streaming
cell, swapped on cell load/unload):

1. **Bake granularity = streaming granularity.** The baker now emits
   PER-CELL proxies (`CHUNK_CELLS = 1`, index version 2, stale outputs
   wiped per run). The toggle unit must equal the publication unit.
2. **Proxy visible ⟺ cell has no published MID buckets.**
   StaticObjectRenderer fires `cell_static_presence_changed` on a cell's
   first bucket publish / first bucket hide / detach; the streaming
   manager routes it to `ChunkProxyRenderer.set_cell_covered`. Covered
   proxies stay resident but hidden, so the unload swap is same-frame,
   never behind a single-flight load.
3. **Proxy near band deleted (begin = 0).** Proxies double as instant
   stand-ins for cells the streamer hasn't published yet — kills the
   fast-flight void. Far band unchanged (CHUNK_END + radius → FAR
   impostors).
4. **Covered MID bucket types run band-free** while the chunk tier is
   active: types passing the shared min-size gate
   (`DU.CHUNK_PROXY_MIN_WORLD_RADIUS`, 4 m at CHUNK_START — same constant
   the baker gates refs with, evaluated against prototype AABB radius ×
   max ref scale) get `visibility_range_end = 0` (engine band disabled).
   Their far cutoff becomes the streaming-ring unload (~460 m bounds +
   hysteresis) — exactly where the proxy swap fires. Small clutter keeps
   its screen-size cutoffs (no proxy copies exist for it; its 400 m cull
   is invisible by construction). Direct (non-bucket) instances keep the
   plain 400 m band — the bake only carries `static_batch_allowed`
   content, so they have no proxy copies either.
5. **Instruments stay honest:** a `static_range` override disables the
   band release for its duration (`_apply_paged_coverage`); the
   static_visuals ablation now hides proxies too
   (`ChunkProxyRenderer.set_globally_visible`) per the Phase 0 "hide ALL
   static output" contract. Legacy 2×2 bakes are refused at index load
   (warn + dormant tier) — re-bake required.

Net effect: no tier ever renders a cell's statics while the other does
(z-fight class deleted), and every cell is covered by exactly one tier at
all times (gap class deleted), with the swap driven by the same event that
creates/destroys the MID copies. Costs to verify by ladder: covered types
render to the ring edge (~460-625 m) instead of 400 m while published, and
per-cell meshes split some formerly-shared chunk surfaces (partially
recovered by 4× tighter frustum culling; the bake-time texture atlas
remains the named lever if the ring cost needs to come down).
LADDER COMPARABILITY: rung 2 (statics hidden) now hides the proxy ring as
well — draws drop back near the pre-chunk ~93 baseline; do not compare
rung-2 draw counts across this change.

**Ladder with the FULL ring (ladder_chunk_tier_v1, sequence complete,
0 errors):** rung 3 = 77.2 FPS / p95 16.8 / 1,607 draws (vs 93.8 / 14.5 /
766 with the ring empty) — the populated ring costs ~2.3 ms/frame
(~840 draw surfaces from ~30 in-range chunks × ≤64 material surfaces).
Above the ≤1 ms acceptance — the named tuning lever is per-chunk surface
reduction via bake-time texture ATLASING (the full MGE XE treatment),
which would collapse most chunks to a handful of surfaces. Decide after
the user's visual verdict on the ring. NOTE for ladder comparability:
the chunk tier is NOT in the rung ablation toggles — rung 2 now includes
the ring (draws 93 → 967); read historical rung deltas accordingly, or
add a chunk toggle to the ladder rungs later.

**Then:** delete runtime ObjectPaging (object_paging.gd stays parked and
untouched until the chunk tier is verified; the kernel + kernel wrapper
survive — the baker uses them).

**Impostor work (demoted, when next touching FAR):** storage format fix
(compressed normal atlases), candidacy retune against 0.01 at the new
1.2 km start, aerial bake angles.

Acceptance: user flyover — the 400–1200 m band reads as populated real
geometry, no cliff at the MID→CHUNK handoff; frame cost of the chunk
tier ≤ ~1 ms render_cpu at ~40-60 visible chunks; no multi-GB cache.

## Phase 3 — Cooked per-cell static manifests (structural)

Bake per exterior cell, offline via prebake UI: classification results,
cluster layout, packed transforms, AABBs, draw-group composition — but NOT
merged geometry (meshes stay shared in the models cache; zero duplication;
~15–20 MB total). Runtime cell publish becomes: threaded-load manifest →
create MultiMeshes/RS instances from already-shared meshes. Deletes the
runtime classification + clustering + descriptor-build machinery from the
hot path.

Acceptance: cell crossing publish cost ≤ 1 ms/frame sustained; measurable
LOC deletion in cell_manager/static_object_renderer configure paths;
first-playable time improves (less startup classification).

**Implementation plan (drafted 2026-07-05, session 3 — C# per user mandate):**

Design decisions:
- **Custom binary format, NOT .res** — manifests are loaded with plain
  `FileAccess` reads in C#, which (a) sidesteps the Godot ≤4.6 threaded
  ResourceLoader race entirely (no shared sub-resources, no loader
  machinery), (b) doesn't queue behind the single-flight model loads, and
  (c) reads packed arrays without per-object Variant construction.
- **C#-owned data model** (`src/native/` CellManifest): one class owns
  cook + load + the in-memory representation. GDScript consumers receive
  whole packed arrays (one marshalling boundary per array, not per
  object) — this is the honest C# scope the wave-3 note identified: the
  win comes from deleting per-record GDScript object construction, not
  from porting a loop.
- **Cooked offline via the prebake UI only** (project rule: no runtime
  generation). Runtime keeps the existing build as fallback for uncooked
  cells behind a `use_cooked_manifests` flag until M.2.

Contents per exterior cell: string table (model paths, deduped), per-ref
records as parallel packed arrays (model index, type enum, flags,
transform as 12 floats, AABB, item/cache ids where needed), plus the
classification outputs the runtime currently derives per load
(static-render worthiness, mid-worthiness, interactive routing).

Stages:
- **M.0**: C# CellManifest (format vX, write + read + validate) + prebake
  UI "cook manifests" batch + an equality checker against the
  runtime-built manifest for N sample cells. Expected total ≤ 20 MB.
- **M.1**: runtime consumption behind the flag: `_request_cell_async`
  loads the manifest (C#, background thread, plain FileAccess) and feeds
  instantiation/static-prepare from packed arrays; runtime build remains
  the fallback. Verify with ladder A/B (target: [cell-request-start]
  manifest cost 9-22 ms → ≤ 1 ms).
- **M.2**: extend cooked data to draw-group/cluster layout (deletes
  configure-time clustering), then delete the runtime classification and
  manifest build outright.

## Explicitly rejected

- Runtime HLOD merging (object_paging): merge-without-simplify renders LOD0
  geometry at distance with no LOD chain, 861 ms stalls, segfault class.
  Parked default-off; deleted when Phase 2 (or its fallback) lands.
- Naive merged per-cell geometry bake: ≈ 8 GB disk. Cooked manifests keep
  geometry deduped.
- Changing the tier distance metric: 3D camera distance is the correct,
  industry-standard screen-size proxy. The overlay gets fixed, not the
  metric.

## Sequencing note

Phases 0 → 1 → 2 strictly ordered (0 makes 1 measurable, 1 frees the frame
budget 2's extra impostors will slightly tax). Phase 3 can start once
Phase 1 acceptance holds; it reuses Phase 2's prebake-UI plumbing.
