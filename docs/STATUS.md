# Status

What works, what doesn't.

## Working

| System | Notes |
|--------|-------|
| World Streaming | Async cell loading, shared 8ms/frame budget across all phases, frustum priority, object pooling, deferred RS cleanup with immediate-hide |
| Modular Streaming Ownership | Generic `WorldObjectSource` manifests now feed HLOD, FAR impostors, distant lights, and streaming orchestration; Morrowind/ESM lookup is isolated in the Morrowind adapter. Canonical toggles are `near_gameplay`, `static_visuals`, `hlod`, `far_impostors`, and `distant_lights`, with temporary aliases for old benchmark names. |
| 4-Tier LOD | NEAR 0-150m (scene-tree gameplay/physics). MID is the fixed 150-400m bridge via cell-local `CellStaticBucket` draw groups: groups use local MultiMeshes under one ownership path, singleton groups use the single-slot transform API instead of a bulk buffer upload, and embedded mesh LOD stays engine-driven via `mesh_lod_threshold` + `lod_bias`. FAR impostor pages are default-on from 400m. HLOD is now default-off through `src/core/world/object_paging.gd`; `--hlod` / `hlod_enable` keep it available as an optional 400-1000m comparison tier. MID→NEAR promotion at 250m, demotion at 280m (`streaming_config.gd:78-81`). Canonical B-wide rewrite landed 2026-04-10 — see `docs/systems/distance_rendering.md` + `docs/archive/plans/lod_refactor_b_wide.md`. Dead standalone `octahedral_impostor.gdshader` deleted 2026-04-12 (inline shader in `native_impostor_renderer.gd` is the single source). 12/937 impostors rebaked to v5; full v5 rebake pending. Differential impostor updates on cell crossing (~1ms vs 14-158ms before). |
| Interior Transitions | Async pocket load via CellManager.request_cell_async + LoadProfile + priority lane + fade-to-black bridge fallback. NORMAL-path transitions peak ≤ ~6 ms real-renderer (verified 2026-04-06, Seyda Neen, Census and Excise Office 268 refs). First-visit cells may hit ~10 ms due to shader warm-up. BRIDGE path (player rushes load) ~12 ms, bounded. See `src/core/world/interior_pocket_manager.gd` + `src/core/world/cell_manager.gd` LoadProfile class. |
| Terrain | Terrain3D, multi-region, edge stitching |
| ESM Parsing | 47 record types, grid-indexed cells, thread-safe |
| NIF Conversion | Geometry, materials (glow maps, HILIGHT, ZBuffer, specular color), skeletons, animations (keyframe + vis/UV/alpha/path controllers), collision, particles, lights |
| BSA Archives | Thread-safe, 256MB LRU cache |
| Textures | DDS/TGA loading, material deduplication (90% reduction), 7 NIF texture slots parsed |
| NPC Assembly | Race + head + hair, body part mirroring, full-body skin detection |
| Animations | 132 MW animations, state machine (idle/walk/run/jump) |
| Deformation | RTT-based (snow, mud, ash) |
| Console | Command registry, object picking, selection outline |
| Fly Camera | Free camera + FPS controller (toggle P) |
| Dialogue System | Framework panel (`DialogueUI`) + MW provider (OpenMW 4-step filter + 74 functions), 574 books + 1698 dialogue topics + 632 journal topics + ~24k INFO records loaded. Typed `Response` envelope (`SPEAKER_NOT_FOUND` / `NO_INFO_MATCH` / `OK`). Topic cross-referencing with clickable links. Goodbye flow. See `docs/systems/dialogue.md`. **Not yet wired into main streaming scene — only the `test_interaction` visual test scene demonstrates it end-to-end.** |
| Quest Journal | `QuestManager` state machine (`INACTIVE → ACTIVE → COMPLETED/FAILED`), `JournalPanel` UI with Active/Completed tabs, 629 MW quests parsed with correctly ordered journal entries. `MWQuestAdapter.on_response_selected()` signal handler auto-advances the journal when a chosen INFO has QSTN/QSTF/QSTR flags. Quest IDs still raw (`a1_2_antabolisinformant`) — Phase C will extract display names from first journal entry. |
| Interaction Framework | `src/core/interaction/` - generic `Interactable` base class + `InteractionRaycaster` on collision layer 3 ("Interactable"). Walk-up-parent lookup lets prefab roots own adapters while child collision objects receive hits. `interact` remains one InputMap action, owned by exactly one active context: `PlayerGameplayContext` in player mode or `FlyCameraContext` in fly/debug mode. Main-scene `world_explorer.gd` wires player and fly raycasters; dialogue/book/journal UI wiring is still a separate dialogue carry-forward. |
| Carry / Pickup System (I.0-I.7 + post-Phase 7 hardening) | `src/core/interaction/{carryable_registry,carryable_body_factory,inventory_service,carry_controller}.gd` + Morrowind adapters under `src/core/interaction/morrowind/`. Tap routes to inventory/primary verbs; hold routes to `CarryController`. Carry now uses the HL2/Source-style velocity-drive pattern: held bodies stay dynamic, Jolt integrates them, and per-physics-tick velocity commands chase the camera-relative hold target. Prompt updates are suppressed while carrying, and tap interaction is ignored during carry mode. Main-scene `world_explorer.gd` wires player/fly carry controllers and passes the streaming manager for persistent-node registration; re-home-on-cell-load and bounded orphan cleanup remain follow-up work. |
| Book Viewer | `BookViewer` CanvasLayer renders MW HTML-tagged book text via `TextFormatter` → BBCode, with inline images loaded from BSA via `add_image()`. Scroll/book distinction ready (`BookRecord.is_scroll`), two-page spread not yet implemented. |
| UI Theme | `assets/ui/themes/default_theme.tres` with Pelagiad (OFL) font at 18pt default. Style variations: Parchment / ParchmentTight / Toast / TopicsList / ParchmentSeparator / TitleLabel / DispositionLabel / ToastLabel / CloseButton. Single `default_font_size` value controls all body text. See `assets/ui/themes/BEFORE_STYLE_CATALOG.md` for the source values captured during extraction. |

## Framework Ready (Not Integrated)

| System | Notes |
|--------|-------|
| Ocean/Water | OceanManager, FFT waves, GPU-readback buoyancy, real depth-driven Beer-Lambert absorption + refraction UV offset + custom in-shader SSR raymarch for object reflections (2026-04-06). Native Godot 4.6 SSR is disabled on this material (declaring hint_depth_texture/hint_screen_texture kills the native SSR pass in Forward+); custom SSR trace ported from GodotSSRWater replaces it. Known residuals: waterline discontinuity on half-submerged objects, underwater POV renders as flat dark. Not wired into main scene. See `docs/systems/ocean.md`. |
| Character Controller (physics, swimming) | `PlayerController` with Move-as-Node state machine shipped (see `docs/systems/character_controller.md`). Post-Phase 7 hardening through Phase 6 is complete for available content: active input contexts, teleport interpolation resets, body-driven carry cleanup, prompt suppression, honest movement config fields, InputMap-driven visual-test controls, split jump/airborne state semantics, scripted step-solver fixtures, and available-content main-scene smoke. Human/user validation: `reports/report_215/results.xml` passed 51 character-controller tests with 0 failures/errors/skips; `tests/visual/test_character_controller.tscn` and `tests/visual/test_teleport_interpolation_reset.tscn` were confirmed working; `scenes/Godotwind.tscn` passed fly/player switching, movement, sprint, jump, crouch, camera toggle, streaming boundary crossing, water, and controller-scope log review. Main-scene interact/carry/prompt and teleport/interior checks are blocked future integration gates until those paths are implemented in the scene. |

## Project-wide settings flipped 2026-04-08

- `physics/common/physics_interpolation = true` (Godot 4.4+ canonical pattern, Glenn Fiedler "Fix Your Timestep!" architecture). Per-node carve-outs in `player_controller.gd::camera_pivot` and `fly_camera.gd` set `physics_interpolation_mode = OFF` so mouse-driven rotation stays render-rate fresh. Carry now uses velocity drive on dynamic bodies instead of render-rate transform writes.
- `rendering/anti_aliasing/quality/msaa_3d = 2` (4x multisample). Project was previously running with zero AA — every thin specular highlight on clutter would shimmer in motion regardless of physics jitter.

## In Progress

- **I.6 Phase 2** — re-home on cell load + bound policy (5 min OR 8 cells away despawn, spec §13 Q7) + walk-back case (orphan re-homed when its origin cell reloads). Currently the orphan registry is write-only; evacuated items live forever in `OrphanedCarriedItems`. Spec §10.

## Not Started

Combat, magic, AI, inventory, save/load, character creation.

## In Progress (Dialogue/Quest carry-forwards)

- **Dialogue/quest main scene integration:** `DialogueUI`, `BookViewer`, and `JournalPanel` still need full persistent main-scene wiring. The generic `InteractionRaycaster` and carry stack are now wired by `world_explorer.gd`; the remaining dialogue vertical slice is to spawn the UI panels and add `NPCInteractable` to streamed NPC prefabs at construction time.
- **Result script (BNAM) interpreter:** MW dialogue INFO records carry a result script that mutates game state (`AddItem`, `Journal`, `SetGlobal`, `Choice`, etc). Currently parsed but not executed. Dialogue can't affect the world until this lands. Next biggest blocker after main-scene integration.
- **Derived disposition formula:** `NPCInteractable.interact()` copies the raw `NPCRecord.disposition` into the context. OpenMW's `getDerivedDisposition()` formula (base + faction reaction + race reaction + personality + reputation + per-NPC persuasion modifiers) needs to be ported into the MW adapter for accurate filtering.
- **Quest display names:** Journal panel still shows raw IDs like `a1_2_antabolisinformant`. Extract from first QSTN entry text.
- **Two-page book spread:** `BookRecord.is_scroll` wired through `BookInteractable` prompt ("Unroll") but the BookViewer still uses single-column layout.
- **Persuasion mechanics:** admire/intimidate/taunt/bribe wheel.
- **Service UIs:** merchant, trainer, spellmaker, enchanter — all accessed via dialogue.
- **`DialogueProvider.get_speaker_name()` silent fallback:** returns `speaker_id` when NPC lookup fails. Flagged by review — should either return empty string or a typed error. Deferred.

## Known Issues

1. NiGeomMorpherController (blend shapes/face morphs) parsed but not applied — dialogue blocker
2. Dark texture (36 objs), detail/decal/env map textures not applied (0.2% of vanilla, deferred to mod support)
3. Interior lighting exists but not tuned
4. Animation action layers stubbed (upper body blend not wired)
5. Automated tests: gdUnit4 13 unit tests + visual test scenes in tests/visual/
6. **NEAR-tier stabilization + distant rendering re-enable (branch `perf/distant-rendering-2026-04-17`).** HLOD and FAR impostors are default-on again; use `--near-only` to park both for focused NEAR tests, and `--no-hlod` / `hlod_disable` for HLOD ablation. **State:** Phase 0A/0B (dead-path deletion + `CellPayload.publish_step()` seam), Phase 1 lane 1 (model callback ownership), Phase 1 lane 2 (collision publish ownership), Phase 2A (static refs routed out of `add_child()`), P0.4 (lifecycle audit + ownership map + Phase F shape-cache ordering fix + `StaticShapeCache` single-flight + reclaim-after-unload-limbo invariant proven via boomerang route), and the Phase 2B structural bucket implementation are present in code. `CellStaticBucket` now owns local MultiMeshes / RS instance RIDs plus strong Mesh/Material/resource-handle refs, has a `frozen` iteration gate, and `StaticObjectRenderer.remove_cell_instances()` detaches buckets before cleanup. The original 2026-04-29 cache-eviction crash (`ModelLoader._evict_if_over_budget -> _model_cache.erase`) was fixed earlier by `StreamedResourceHandle` ownership; eviction is active again without releasing live handles. **Acceptance gates still matter:** before treating distant tiers as fully accepted, run dense/east/reclaim stress with collision enabled, material/RID iteration-order stress, no `material_set_shader`, no stale-bucket discovery, no collision finalize errors, and no changed-path 50ms+ outliers. Still outstanding: HLOD chunk surface/material draw-call reduction and frame budget split per lane (target 1ms/frame publish at 150 FPS; runtime budgets still include 8ms/4ms transitional values). Architecture north star: `docs/systems/streaming_rendering_bible.md`. Active Phase 2B design/acceptance checklist: `docs/plans/near_streaming_phase_2b_design_2026_05_01.md`. Historical tracker/handoff/P0.4 audit material is archived under `docs/archive/`.

## Performance

| Metric | Value |
|--------|-------|
| FPS | 60+ (streaming) |
| View distance | 5km (impostors) |
| Shared frame budget | 8ms across all streaming phases |
| Worst cell-crossing stall | ~35ms (down from 307ms, 2026-03-30 optimization) |
| Impostor count | ~63K candidates in last accepted run; runtime arrays currently cap at 256 layers |
| Impostor crossing cost | ~1ms (differential border-strip update) |
| MultiMesh rebuild | single `set_buffer()` call (PackedFloat32Array) |
| Memory | ~2GB |

## Profiling Infrastructure

| Tool | Usage |
|------|-------|
| PerformanceProfiler | Frame timing, P50/P95/P99, draw calls, memory (automatic) |
| StreamingProfiler | Per-subsystem microsecond timing with section breakdown |
| StreamingBenchmark | Scripted camera path, CSV output. Console: `benchmark_streaming` |
| LodTransitionTest | Automated LOD boundary crossing test with CSV output |
| ProfilingReport | Full report dump via F4 key |
| BatchDebugHUD | Real-time RS instance stats. Console: `mid_debug` |
| DebugSystem | F9 overlay, F12 auto-test mode |
| Per-phase overrun logs | `[streaming] Frame overrun: Xms [unload:X async:X inst:X ...]` |
