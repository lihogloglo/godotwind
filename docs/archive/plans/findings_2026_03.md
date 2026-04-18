# Master Audit Findings & Tracker

This document tracks all issues identified during the 2026 Audit & Future-Proofing initiative.

## Domain Prefix Key:
- **S**: Streaming & World Logic (C1)
- **A**: Animation & NPCs (C2)
- **N**: NIF & Assets (C3)
- **G**: General Code Quality & Architecture (G1-G3)

---

## Streaming & World Logic (C1)
- [x] **S-01** CRIT: `pop_front()` in impostor hot loop — owner:gemini
- [x] **S-02** CRIT: Missing `wait_for_task_completion()` on worker handles — owner:claude
- [x] **S-03** PERF: Uncached `FileAccess.file_exists()` in impostor renderer — owner:claude
- [x] **S-04** TECH: `CELL_SIZE` inconsistency across config/utils — owner:gemini
- [x] **S-05** PERF: Impostor spatial index missing (linear search in unload) — owner:claude
- [x] **S-06** ARCH: `world_explorer.gd` has hardcoded "WorldStreamingManager" node paths — owner:gemini
- [x] **S-07** PERF: Priority queue sorting optimization — owner:gemini
- [x] **S-08** PERF: `ObjectPool` release is O(n) — owner:gemini
- [x] **S-09** TECH: Deprecated `update_visibility_by_distance` lingering — owner:gemini
- [x] **S-10** CRIT: `is_instance_valid()` checks missing in deferred unloader — owner:gemini
- [x] **S-11** DEAD: `model_loader.gd` unused resource preparation methods — owner:gemini
- [x] **S-12** TECH: LOD sub-tier boundaries duplicated across config/configurator — owner:gemini
- [x] **S-13** DOCS: Stale line-count and architecture comments — owner:gemini
- [x] **S-14** TYPE: `NativeImpostorRenderer` internal dictionaries untyped — owner:gemini
- [x] **S-15** TYPE: `CellManager` instantiation queue untyped — owner:gemini
- [x] **S-16** TYPE: `get_loaded_cell(x, y)` completely untyped params — owner:gemini
- [ ] **S-17** PERF: `StaticObjectRenderer` (MID tier) renders LOD0 meshes instead of LOD1/2/3 — owner:gemini
- [ ] **S-18** PERF: MID tier individual RS instances (200-500) causing draw call bottleneck — owner:gemini
- [ ] **S-19** BUG: 500m (MID/FAR) boundary missing `HYSTERESIS_MID` oscillation fix — owner:gemini
- [ ] **S-20** TECH: Sibling LODs use `FADE_DEPENDENCIES` incorrectly (should use `FADE_SELF`) — owner:gemini

## General Architecture & Quality
- [x] **G-01** DEAD: `mesh_simplifier_v2.gd` (broken fallback) — owner:gemini
- [x] **G-02** DEAD: `static_mesh_merger.gd` (unused infra) — owner:gemini
- [x] **G-03** TYPE: `ESMManager` record storage dictionaries untyped — owner:gemini
- [x] **G-04** TYPE: `NIFReader` / `NIFConverter` resource caches untyped — owner:gemini
- [x] **G-05** TYPE: `BackgroundJobSystem` / `Logger` untyped collections — owner:gemini
- [x] **G-06** ARCH: `ModRegistry` (RefCounted) — owner:gemini
- [x] **G-07** ARCH: Asset override layer in specialized loaders — owner:gemini

## Animation & NPCs (C2)

### Critical / High Priority
- [x] **A-01** BUG: `animation_blend_mask.gd:194` `get_upper_body()` passes bone INDEX as MaskType — fixed: manual 3-mask union. — owner:claude
- [x] **A-02** DUP: `animation_manager.gd:272-288` and `:381-397` duplicate fallback logic — extracted to `_resolve_fallback_state()`. — owner:claude
- [x] **A-03** DEAD: `animation_blend_mask.gd` `get_bone_weights()` — removed (never called). — owner:claude
- [x] **A-04** DEAD: `animation_priority.gd` queue system — removed (`_animation_queue`, `queue_animation()`, `pop_queued_animation()`, `clear_queue()`). — owner:claude
- [x] **A-18** ARCH: `AnimationManager` missing `upper_body_blend` and `oneshot` nodes in `AnimationTree` — owner:gemini
- [x] **A-19** TECH: `play_oneshot()` and `_apply_blend_mask_filters()` wiring — owner:gemini

### Moderate Priority
- [x] **A-05** DUP: `morrowind_character_system.gd` bone map duplication — owner:gemini
- [ ] **A-06** INCOMPLETE: `animation_lod_controller.gd` created but not integrated — `animation_manager.gd` never checks LOD level. — owner:claude
- [ ] **A-07** INCOMPLETE: `procedural_modifier_controller.gd` (lean, breathing, hit reactions) created but rarely wired. — owner:claude
- [ ] **A-08** INCOMPLETE: `creature_animation_system.gd:98-100` creature type detection uses `"left" in name_lower`. — owner:claude
- [ ] **A-09** INCOMPLETE: `character_movement_controller.gd` Phase 1 features declared but code stops early. — owner:claude
- [ ] **A-10** INCOMPLETE: `src/core/character/controller/` move system not integrated into main gameplay flow. — owner:claude
- [x] **A-11** PERF: `humanoid_animation_system.gd:60` `_build_bone_map()` caching — owner:gemini
- [ ] **A-12** BUG: `morrowind_character_system.gd:117-135` animation search uses case-insensitive substring match. — owner:claude

### Low Priority / Type Safety
- [x] **A-13** TYPE: `animation_manager.gd:103` `_state_animation_map` → `Dictionary[StringName, StringName]`. — owner:claude
- [x] **A-14** TYPE: `animation_blend_mask.gd:34` `_mask_bones` → `Dictionary[int, Array]`. — owner:claude
- [x] **A-15** TYPE: `ik_controller.gd:52` `_bone_indices` → `Dictionary[StringName, int]`. — owner:claude
- [x] **A-16** TYPE: `text_key_handler.gd:62` — already `Dictionary[String, Array]`, GDScript doesn't support nested typed arrays. Kept as-is. — owner:claude
- [ ] **A-17** TYPE: `character_animation_system.gd:31-34` child controller nodes typed as `Node` instead of specific types. — owner:claude

### Architecture Notes (Not Bugs)
- **A-NOTE-1**: `animation_priority.gd:173` `can_interrupt()` uses `<=` (same-priority can transition). This is intentional.
- **A-NOTE-2**: `character_factory_v2.gd:256` BoneAttachment update condition `if not rename_map.is_empty()` is CORRECT.
- **A-NOTE-3**: `ik_controller.gd` quadruped IK (140+ lines) exists but untested.
- **A-NOTE-4**: `text_key_handler.gd` is complete and correct but text keys are registered and never connected to AnimationManager events.
- **A-NOTE-5**: `character_factory_v2.gd` 4-stage animation loading is complex but necessary.
- **A-NOTE-6**: Large files — `ik_controller.gd`, `character_factory_v2.gd`, `morrowind_npc_assembler.gd` — defer refactoring to C4.

## NIF & Assets (C3)
*(Upcoming Deep Audit)*

## Code Dedup & Refactoring (C4)
- [ ] **G-10** TECH: Queue anti-pattern (manual index + lazy slice) in `native_impostor_renderer.gd` and `cell_manager.gd`. Should use a proper `Deque` or reverse+`pop_back()`. — owner:gemini

## Distance Rendering & Streaming Audit (2026-03-02, Claude + Gemini)
- [x] **DR-01** MAJOR: MID tier renders LOD0 at 500m — Fixed: `MidTierBatchPool` extracts LOD1/2/3 from prototypes, falls back LOD0→all bands. — owner:claude
- [x] **DR-02** MAJOR: Cell unload threshold (411m) < grid diagonal load distance (496m) — Chebyshev load vs Euclidean unload mismatch caused corner cell oscillation. Fixed: use `sqrt(2) * radius * cell_size` for unload base distance. — owner:claude
- [ ] **DR-03** MINOR: NEAR/MID fade margin (5m) may pop on complex architecture — consider 8m, needs visual testing. — owner:claude
- [x] **DR-04** INFO: GPU Scene Database SSBO storage has no compute cull shader consumer — deferred to future GPU-driven work.
- [x] **DR-05** INFO: `pop_front()` in doc examples (PERFORMANCE_GUIDE.md, DESIGN_PATTERNS.md) — hot path code already fixed. Doc examples corrected.
- [x] **DR-06** VERIFIED: FADE_DEPENDENCIES correct for sibling LODs — margins symmetric at all boundaries.
- [x] **DR-07** MAJOR: MID tier 200-500 individual RS draw calls — Fixed: `MidTierBatchPool` MultiMesh batching reduces to ~30-80. Gemini-roasted: fixed Transform3D() glitch pile, GPU buffer thrashing, O(n²) bulk unload, O(n) rebuild scan. — owner:claude
- [x] **DR-08** MAJOR: `_is_mid_worthy()` and `_should_generate_lods()` filter mismatch — 393 models (40,012 instances) MID-worthy but lacked LODs; 52 models had LODs but were rejected. Fixed: consolidated into `StreamingPolicy` class (`streaming_policy.gd`). Both `cell_manager.gd` and `nif_converter.gd` now reference single source of truth. Diagnostic: `test_mid_tier_diagnostic.tscn`. — owner:claude
- [x] **DR-09** REBAKE: Targeted rebake completed — `targeted_rebake.gd` deleted 961 stale cache files and re-baked with LODs. Result: MID+LODs went from 585→678, wasted LODs from 52→1. 437 models still without LODs are all <300 verts (too simple to simplify). Tool: `src/tools/prebaking/targeted_rebake.tscn`. — owner:claude
