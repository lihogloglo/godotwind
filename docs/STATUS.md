# Status

What works, what doesn't.

## Working

| System | Notes |
|--------|-------|
| World Streaming | Async cell loading, shared 8ms/frame budget across all phases, frustum priority, object pooling, deferred RS cleanup with immediate-hide |
| 3-Tier LOD | NEAR 0-150m (Node3D), MID 150-500m (RS instances), FAR 500-5km (impostors). Differential impostor updates on cell crossing (~1ms vs 14-158ms before) |
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
| Dialogue System | Framework panel (`DialogueUI`) + MW provider (OpenMW 4-step filter + 74 functions), 574 books + 2358 topics + 24k INFO records loaded. Typed `Response` envelope (`SPEAKER_NOT_FOUND` / `NO_INFO_MATCH` / `OK`). Topic cross-referencing with clickable links. Goodbye flow. See `docs/TEXT_DIALOGUE_SYSTEM.md`. **Not yet wired into main streaming scene — only the `test_interaction` visual test scene demonstrates it end-to-end.** |
| Quest Journal | `QuestManager` state machine (`INACTIVE → ACTIVE → COMPLETED/FAILED`), `JournalPanel` UI with Active/Completed tabs, 629 MW quests parsed with correctly ordered journal entries. `MWQuestAdapter.on_response_selected()` signal handler auto-advances the journal when a chosen INFO has QSTN/QSTF/QSTR flags. Quest IDs still raw (`a1_2_antabolisinformant`) — Phase C will extract display names from first journal entry. |
| Interaction Framework | `src/core/interaction/` — generic `Interactable` base class + `InteractionRaycaster` on collision layer 3 ("Interactable"). Walk-up-parent lookup so any prefab with the Interactable at its root + a child CollisionObject3D on layer 3 is interactable. `interact` InputMap action bound to physical E key. MW adapters `NPCInteractable` and `BookInteractable` live in `src/core/dialogue/morrowind/`. **Not yet wired into main streaming scene.** |
| Book Viewer | `BookViewer` CanvasLayer renders MW HTML-tagged book text via `TextFormatter` → BBCode, with inline images loaded from BSA via `add_image()`. Scroll/book distinction ready (`BookRecord.is_scroll`), two-page spread not yet implemented. |
| UI Theme | `assets/ui/themes/default_theme.tres` with Pelagiad (OFL) font at 18pt default. Style variations: Parchment / ParchmentTight / Toast / TopicsList / ParchmentSeparator / TitleLabel / DispositionLabel / ToastLabel / CloseButton. Single `default_font_size` value controls all body text. See `assets/ui/themes/BEFORE_STYLE_CATALOG.md` for the source values captured during extraction. |

## Framework Ready (Not Integrated)

| System | Notes |
|--------|-------|
| Ocean/Water | OceanManager, Gerstner waves, buoyancy — not wired into main scene |
| Weather/Sky | Sky3D addon installed, not integrated |
| Character Controller | Basic FPS controller, no physics-based movement yet |

## In Progress

(none currently — interior transitions P0 landed 2026-04-06, see Working row)

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

## Performance

| Metric | Value |
|--------|-------|
| FPS | 60+ (streaming) |
| View distance | 5km (impostors) |
| Shared frame budget | 8ms across all streaming phases |
| Worst cell-crossing stall | ~35ms (down from 307ms, 2026-03-30 optimization) |
| Impostor count | ~63K (497 texture layers) |
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
