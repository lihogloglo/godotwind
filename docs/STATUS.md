# Status

What works, what doesn't.

## Working

| System | Notes |
|--------|-------|
| World Streaming | Async cell loading, shared 8ms/frame budget across all phases, frustum priority, object pooling, deferred RS cleanup with immediate-hide |
| Modular Streaming Ownership | Generic `WorldObjectSource` manifests now feed HLOD, FAR impostors, distant lights, the new world-cell async path, and streaming orchestration. Morrowind/ESM lookup is isolated for provider-driven paths and source-reference wrapping now goes through the injected spawn adapter before `ReferenceInstantiator` publishes `WorldObjectRecord` payloads. Remaining near/interior legacy routes in `CellManager` still bridge through adapter-local parser-shaped records, and `ReferenceInstantiator` still has source-helper methods typed on parser-shaped refs for Morrowind-owned spawn behavior. Canonical toggles are `near_gameplay`, `static_visuals`, `hlod`, `far_impostors`, and `distant_lights`, with temporary aliases for old benchmark names. |
| Framework Boundary | Public world-object legacy escape hatches are removed: no `get_legacy_*`, `WorldObjectRecord.legacy_*`, `WorldCellManifest.legacy_cell_record`, or public `ReferenceInstantiator.instantiate_reference()` parser-ref entry point in generic APIs. `CellPayload` and static collision now consume normalized records/transforms, `MorrowindDataProvider` lives under the Morrowind adapter path, distant lights receive generic animation/fire metadata instead of raw MW flag masks, distant-light page/ring math can use the active `WorldCoordinateMapper`, and source-ref base-record lookup from `ReferenceInstantiator` is adapter-owned. Remaining known debt includes the temporary parser-cell bridge, coordinate/distance policy, terrain LAND/LTEX handling, impostor-candidate content policy, weather/dialogue compatibility, and character/NIF assumptions; see `docs/audit/morrowind_framework_boundary_mega_audit_2026_05_21.md`. |
| 4-Tier LOD | NEAR 0-150m (scene-tree gameplay/physics). MID is the fixed 150-400m bridge via cell-local `CellStaticBucket` draw groups: groups use local MultiMeshes under one ownership path, singleton groups use the single-slot transform API instead of a bulk buffer upload, and embedded mesh LOD stays engine-driven via `mesh_lod_threshold` + `lod_bias`. FAR impostor pages are default-on from 400m. HLOD is now default-off through `src/core/world/object_paging.gd`; `--hlod` / `hlod_enable` keep it available as an optional 400-1000m comparison tier. MID→NEAR promotion at 250m, demotion at 280m (`streaming_config.gd:78-81`). Canonical B-wide rewrite landed 2026-04-10 — see `docs/systems/distance_rendering.md` + `docs/archive/plans/lod_refactor_b_wide.md`. Dead standalone `octahedral_impostor.gdshader` deleted 2026-04-12 (inline shader in `native_impostor_renderer.gd` is the single source). 12/937 impostors rebaked to v5; full v5 rebake pending. Differential impostor updates on cell crossing (~1ms vs 14-158ms before). |
| Interior Transitions | Classic travel-door path is wired into the main scene. `DoorInteractable` activation routes by placed-door `instance_key` (base record id + ref_num + source cell), so duplicate DOOR records no longer collide. Phase 2 of the 2026-05-30 refactor moved travel-door topology extraction behind source-neutral transition descriptors: `InteriorPocketManager` consumes provider descriptors, while Morrowind ESM/DODT/DNAM translation and shell metadata live in `src/core/world/morrowind/morrowind_transition_provider.gd`. `NativeStreamingManager.set_world_tracking_frozen()` freezes exterior camera tracking while keeping async completions and `CellManager.process_async_instantiation()` alive, so rush-entering a pocket cannot starve the bridge. Exterior→interior, interior→exterior, and interior→interior use the same fade/priority/wait path. Seamless portal/walk-through remains experimental and parked. |
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
| Interaction Framework | `src/core/interaction/` — generic `Interactable` base class + `InteractionRaycaster` on collision layer 3 ("Interactable"). Walk-up-parent lookup so any prefab with the Interactable at its root + a child CollisionObject3D on layer 3 is interactable. `interact` InputMap action bound to physical E key. MW adapters `NPCInteractable` and `BookInteractable` live in `src/core/dialogue/morrowind/`. **Not yet wired into main streaming scene.** |
| Carry / Pickup System (I.0-I.7) | `src/core/interaction/{carryable_registry,carryable_body_factory,inventory_service,carry_controller}.gd` + `morrowind/{mw_carryable_registry,mw_inventory_service,pickup_interactable,door_interactable,container_interactable,activator_interactable}.gd`. **Phases I.0-I.4 shipped 2026-04-07. I.5 + I.6 (plumbing + carry-side wiring) + I.7 shipped 2026-04-08.** PlayerController is single input owner, modal-gate registry, three-signal split (tap/hold_begin/release). Reference instantiator routes 12 MW carryable types (WEAP/ARMO/CLOT/BOOK/ALCH/INGR/MISC/APPA/LOCK/PROB/REPA + LIGH FLAG_CAN_CARRY) through factory → frozen RigidBody3D wrapped in PickupInteractable. Tap E → InventoryService → despawn (atomic deferred quiesce). Hold E → CarryController kinematic-style hold via direct global_transform writes (NOT reparent — see INTERACTION_SYSTEM.md §17.5). Throw on fast camera swing (lever-arm cross product impulse + tumble, ring buffer 50 ms time-keyed window). Weight cap refusal at grab (>50 kg). Wall pushback raycast pulls hold pose back. **I.5 auto-buoyancy:** `BuoyancyBody3D` substituted into factory when ocean is initialized, AABB-derived 5-probe layout auto-generated, frozen-body tick guard. **I.6 streaming safety:** `register_persistent_node`/`unregister_persistent_node`/`find_grid_for_node` API on `NativeStreamingManager` + `OrphanedCarriedItems` child container + evacuation hook in `_unload_cell`; `CarryController` calls register/unregister via `set_streaming_manager()` setter (coupling by inversion, type-erased to `Node`). Re-home on cell load + bound policy = Phase 2. **I.7 door/container/activator adapters:** stub adapters in `morrowind/`, emit `door_activated` / `container_opened` / `activator_triggered` signals for future portal driver / container UI / BNAM script interpreter to consume. **Wall pushback non-restore (§17.2.2) FIXED 2026-04-08.** **Sig 11 shutdown crash (§17.3) FIXED 2026-04-08** via `CarryController._exit_tree`. **Hold-pose vibration (§6.2.1 / §17.2.1) parked 2026-04-08** in "much better but slight residual" state — full diagnostic trail + 3 remaining suspects (physics tick rate, SpringArm internals, ProcessMode timing) documented in §17.2.1. Test scenes `test_interaction_phase_I0..I7.tscn` exist, all self-tests PASS. **Main scene `world_explorer` integration is the next deliverable.** See `docs/systems/interaction_system.md` §17 for full ship dossier. |
| Book Viewer | `BookViewer` CanvasLayer renders MW HTML-tagged book text via `TextFormatter` → BBCode, with inline images loaded from BSA via `add_image()`. Scroll/book distinction ready (`BookRecord.is_scroll`), two-page spread not yet implemented. |
| UI Theme | `assets/ui/themes/default_theme.tres` with Pelagiad (OFL) font at 18pt default. Style variations: Parchment / ParchmentTight / Toast / TopicsList / ParchmentSeparator / TitleLabel / DispositionLabel / ToastLabel / CloseButton. Single `default_font_size` value controls all body text. See `assets/ui/themes/BEFORE_STYLE_CATALOG.md` for the source values captured during extraction. |

## Framework Ready (Not Integrated)

| System | Notes |
|--------|-------|
| Ocean/Water | OceanManager, FFT waves, GPU-readback buoyancy, visible FFT ocean surface, depth-derived Beer-Lambert tint, shore mask, custom surface SSR, `WaterSurfaceState`, `UnderwaterCompositorEffect`, retained object wetness, live contact wetness, and receiver waterline diagnostics. World Explorer now force-initializes ocean through `OceanControls` with High FFT, Clipmap mesh, and `Boujie High` as the main-scene surface shader, and its per-frame ocean control sync keeps `UnderwaterCompositorEffect` attached to the active view with high-quality underwater particulates enabled. Boujie High keeps Godotwind FFT/shore/SSS/foam/spray but uses transparent screen-reading Boujie-style refraction/fog/Fresnel/Snell optics; Ocean Lab still exposes it as a reversible `Shader: Default/Boujie High` control and disables the separate controlled surface-refraction layer while Boujie is active to avoid double refraction. The `Boujie Full` lab preset exercises the broader visual stack together: Boujie surface, FFT-aware `WaterSurfaceState`, live wetness, high underwater medium, underwater particulates, caustics, spray, and SSR. Receiver waterline remains available through `WL Inspect`/`WL Replace` diagnostics, not as a second production underwater-medium path. Retained terrain wetness is not accepted yet; it needs a GPU accumulation mask rather than CPU-side terrain sampling. The 2026-05-23 Ocean Lab controlled-refraction prototype uses a half-resolution water-excluded source, renderer-native source matrices, and a depth-guided receiver ray/depth solve; it remains an exact receiver-waterline tool, not the default open-ocean surface path. See `docs/systems/ocean/architecture.md`, `docs/systems/ocean/godot_4_6_water_rendering_rules.md`, and `docs/audit/openmw_style_refraction_source_2026_05_23.md`. |
| Character Controller (physics, swimming) | `PlayerController` with Move-as-Node state machine shipped (see `docs/systems/character_controller.md`) but not yet wired into main streaming scene — only test scene `tests/visual/test_character_controller.tscn`. |

## Project-wide settings flipped 2026-04-08

- `physics/common/physics_interpolation = true` (Godot 4.4+ canonical pattern, Glenn Fiedler "Fix Your Timestep!" architecture). Per-node carve-outs in `player_controller.gd::camera_pivot` and `fly_camera.gd` set `physics_interpolation_mode = OFF` so mouse-driven rotation stays render-rate fresh. Carry held body also carved out on grab + restored on release. See `docs/systems/interaction_system.md` §17.1 for the migration plan + remaining audit (`grep "global_transform = " in _process` callsites).
- `rendering/anti_aliasing/quality/msaa_3d = 2` (4x multisample). Project was previously running with zero AA — every thin specular highlight on clutter would shimmer in motion regardless of physics jitter.

## In Progress

- **Carry stack main-scene integration** — I.0-I.7 all shipped + tested in isolated test scenes. Main scene `world_explorer.gd` does NOT yet wire the player → CarryController → InteractionRaycaster → streaming manager chain. When this lands, add `carry.set_streaming_manager(streaming_manager)` after both nodes exist so cell-unload survival activates in real gameplay. See `docs/systems/interaction_system.md` §17.4.
- **I.6 Phase 2** — re-home on cell load + bound policy (5 min OR 8 cells away despawn, spec §13 Q7) + walk-back case (orphan re-homed when its origin cell reloads). Currently the orphan registry is write-only; evacuated items live forever in `OrphanedCarriedItems`. Spec §10.
- **§17.2.3 throw mass weighting** — `var rate = HOLD_LERP_RATE / sqrt(rb.mass)` in `_process` lerp + cap throw lever-arm contribution. Was parked on vibration; now unparked. Strength-stat link still deferred until combat lands.
- **§17.2.1 vibration residual** — parked. 5 attempts shipped (manual snapshot → project flip → body MODE_OFF → interpolated swap → Option C manual composition + MSAA 4x), all rejected. 3 remaining suspects on the bench: physics_ticks=120, SpringArm dynamics, ProcessMode timing. See `docs/systems/interaction_system.md` §17.2.1 for the full diagnostic trail before retrying.

## Not Started

Combat, magic, AI, inventory, save/load, character creation.

## In Progress (Dialogue/Quest carry-forwards)

- **Main scene integration:** `DialogueUI`, `BookViewer`, `JournalPanel`, and `InteractionRaycaster` need to be wired into `scenes/Godotwind.tscn`. Currently only `tests/visual/test_interaction.tscn` demonstrates the vertical slice. Integration means: spawn `DialogueUI` + `BookViewer` as persistent singletons in the main scene, attach `InteractionRaycaster` to the player camera, and add `NPCInteractable` to each spawned NPC prefab at streaming time (likely in `src/core/world/reference_instantiator.gd` or wherever NPC instances are constructed).
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
