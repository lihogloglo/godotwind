# Animation/NPC/Rig System — Multi-Session Cleanup Plan

**Created:** 2026-02-10
**Updated:** 2026-02-10 (Session 1 partial, fix attempted and reverted)
**Status:** Session 1B next — need fast loading + headless validation tests before fixing animations

## Context

Since commit `f494cf0`, the animation, NPC creation, and rig systems have been heavily refactored over many sessions. The result: NPCs assemble correctly (body parts, normals, mirroring all fixed), but the codebase accumulated significant debt:
- **Animation quality issue**: Mixamo animations on Morrowind rig don't match the originals (likely rest pose mismatch — RetargetModifier3D not wired for cross-skeleton)
- **~1,360 lines of dead code** in 4 superseded Mixamo files
- **~600 lines duplicated** between test and production assembly code
- **~5,830 lines across 9 test files**, many overlapping
- **~120KB of stale docs** across 6 animation-related documents

## Approach: 6 Sessions, Impact-First

Each session is self-contained (~1 hour), maintains a working system at the boundary, and can be picked up cold by reading only this plan + MEMORY.md.

---

### Session 1: Diagnose Animation Quality

**Status:** PARTIALLY DONE (2026-02-10) — code analysis + visual test done, fix attempted and reverted
**Goal:** Visually verify what works and what doesn't — native MW animations vs Mixamo — and pinpoint the root cause.

**Why first:** Everything else is cleanup. This is the one functional bug.

**What was found (2026-02-10):**

1. **Visual observation:** MW animations on MW skeleton are BROKEN — character floats in air, arms forward, legs bent in a sitting position. This is NOT just a Mixamo retargeting issue.

2. **Code analysis confirmed:**
   - KF loader coordinate conversion (quaternion + position) is mathematically correct
   - Bone remap pipeline works: Bip01 → profile names, tracks remapped, cached
   - AnimationTree is set up correctly (child of Skeleton3D, state machine starts)
   - The _find_animation_for_state_name() correctly finds "idle" in the MW animation library

3. **Hypothesis tested and FAILED — "absolute vs rest-relative keyframes":**
   - Theory: MW KF keyframes are absolute transforms, but Godot computes `final = rest * pose`, so rest gets applied twice
   - Attempted fix: `pose_rot = rest_rot^-1 * keyframe_rot` for all rotation tracks, `pose_pos = rest_rot^-1 * (key_pos - rest_pos)` for position tracks
   - **Result with both rotation + position conversion:** Character becomes a pile of body parts at origin (total skeleton collapse). This means position keyframes are NOT absolute in the way assumed, OR the conversion has a bug.
   - **Result with rotation-only conversion:** Character is folded/twisted to the side, worse than original. Animation freezes after adopting the folded pose. This means the simple `rest_rot^-1 * key_rot` formula is wrong — the relationship between KF keyframes, NIF rest poses, and Godot's animation system is more complex than assumed.
   - **Both approaches reverted.** Code is back to original state.

4. **What the root cause is NOT:**
   - NOT coordinate conversion bugs (verified mathematically correct)
   - NOT bone naming mismatch (remap pipeline confirmed working)
   - NOT AnimationTree misconfiguration (structure is correct)
   - NOT a simple "absolute vs relative" keyframe issue (conversion made things worse)

5. **What still needs investigation:**
   - How exactly does Godot's Skeleton3D combine rest + pose? Need to read Godot C++ source or write targeted unit tests.
   - What format are MW KF keyframes actually in? Compare raw keyframe values vs rest pose values for the same bone. If keyframe[0] == rest for idle, they're absolute. If keyframe[0] ≈ identity, they're already relative.
   - Are there additional transforms in the NIF pipeline (skin_transform, bone_offset) that affect the relationship?
   - Compare against OpenMW's animation playback code to understand the expected transform chain.

**Key files:**
- `src/tools/animation_integration_test.gd` — primary verification scene
- `src/core/nif/nif_kf_loader.gd` — KF animation loading + coord conversion
- `src/core/animation/character_factory_v2.gd` — NPC creation pipeline
- `src/core/nif/nif_skeleton_builder.gd` — skeleton rest pose setup (lines 273-298)
- `src/core/coordinate_system.gd` — MW→Godot coordinate conversion

**Verify:** Screenshot/recording of current animation state as baseline

---

### Session 1B: Infrastructure for Animation Debugging (NEW — DO THIS BEFORE Session 2)

**Status:** DONE (2026-02-10)
**Goal:** Make test iteration fast and build headless validation tests.

**Why:** The animation_integration_test.tscn takes 2-3 seconds to load because it initializes ALL ESM/BSA archives including DLC. Rapid iteration on animation bugs requires faster loading. Additionally, visual-only testing is unreliable — we need numerical validation that bone poses match expected values.

**Task 1: Speed up test scene loading**

Current bottleneck breakdown:
- BSA archive indexing: ~100-500ms (indexes ALL .bsa files)
- ESM parsing: ~500-1500ms (parses ENTIRE Morrowind.esm — 10,000+ records)
- Animation preload: ~200-400ms (parses 3 KF files from BSA)
- Mixamo FBX load: ~50ms (loaded even if not needed)

Options (implement one or more):
- **Quick win (5 min):** Skip Mixamo loading unless [M] key is pressed. Currently loaded eagerly in `_ready()` at lines 67-75 of `animation_integration_test.gd`.
- **Lazy animation preload (10 min):** Defer `CharacterFactoryV2.preload_character_assets()` to first NPC spawn instead of `_ready()`.
- **Lightweight ESM (20 min):** Add `ESMManager.load_file_lightweight()` that only parses NPC_, RACE, BODY, CLAS record types (skip items/dialogue/spells/cells). Would be ~5x faster for character-only tests.
- **ESM cache already exists:** C# native loader saves `.esmcache` files. Second run is ~10x faster. Just ensure cache is valid.

**Task 2: Build headless animation validation tests**

Create a script (e.g., `tests/test_animation_poses.gd`) that:
1. Loads a skeleton from the NIF skeleton cache
2. Loads animations from the KF cache
3. Applies an animation frame (e.g., idle frame 0) to the skeleton
4. Reads back the resulting bone global transforms
5. Compares against expected values (extracted from OpenMW or from a known-good reference)

Specific checks:
- **Rest pose sanity:** For each bone, verify rest transform matches NIF node transform (after coordinate conversion)
- **Idle frame 0 = rest pose?** Compare first keyframe of idle animation against rest pose for each bone. If they match, keyframes are absolute. If first keyframe ≈ identity, they're relative.
- **Bone hierarchy integrity:** `bone_global[child] = bone_global[parent] * bone_rest[child] * bone_pose[child]`
- **Position deltas:** Most bones should have position near rest position (only root moves significantly)
- **Rotation magnitudes:** No bone should rotate >180° from rest in idle animation

Output format: Print a table of bone names, rest rotations, keyframe rotations, and computed pose rotations. This data is needed to understand the actual transform chain and design the correct fix.

**Key insight:** The animation fix (Session 2) CANNOT be done reliably without this numerical data. The visual approach (run scene, observe, tweak, repeat) is too slow and imprecise.

**Verify:** Headless test runs in <1 second and produces a clear pass/fail report.

**Results (2026-02-10):**

1. **Test scene speedup:** Mixamo animations deferred to [M] key press (was eagerly loaded on startup).

2. **Headless test created:** `tests/test_animation_poses.gd` — runs via `godot --headless --script`.

3. **CRITICAL FINDING — keyframes are 100% ABSOLUTE:**
   - All 33 bones: idle frame 0 rotation === rest pose rotation (0.00° difference)
   - All 33 bones: idle frame 0 position === rest pose position (0.0000m delta)
   - Both raw (MW space) and converted (Godot space) comparisons confirm this
   - Exception: "Weapon Bone" (90° offset — attachment bone, not in skeleton)

4. **Bone hierarchy integrity: PASS** — `global_rest[child] == global_rest[parent] * rest[child]`

5. **Implication for Session 2:** Since keyframes ARE absolute and Godot computes `final = rest * pose`, the correct conversion is `pose = rest^-1 * kf_absolute`. Session 1's failed attempt at this conversion must have had a bug in the implementation (possibly related to bone renaming, position handling, or which rest pose was used). Session 2 now has a clear target: implement `rest^-1 * kf` correctly, with the headless test to validate each step.

---

### Session 2: Fix MW Animation Playback + Mixamo Retargeting

**Status:** DONE (2026-02-13) — All bugs fixed, autotest S1-S8 PASS
**Goal:** Fix native MW animations on MW skeleton, then wire Mixamo retargeting.

**IMPORTANT — Session 1 showed MW animations are ALSO broken (not just Mixamo). The original plan assumed MW animations would work and only Mixamo needed retargeting. This is wrong. Fix MW animations FIRST, then Mixamo.**

**What Sessions 1 + 1B established:**
- The KF loader, bone remap, AnimationTree setup all appear correct in isolation
- **Keyframes are 100% ABSOLUTE** — idle frame 0 === rest pose for all 33 bones (0.00° difference)
- Godot computes `final = rest * pose`, so passing absolute KF values directly as `pose` applies rest TWICE
- Session 1's naive `rest_rot^-1 * key_rot` conversion made things WORSE — but the approach is correct in principle
- The Session 1 implementation likely had a bug (wrong rest used, position handling, or bone renaming interaction)
- Bone hierarchy integrity PASS — coordinate conversion and skeleton structure are correct

**Approach for MW fix (informed by Session 1B data):**
- Implement `pose = rest^-1 * kf_absolute` in the KF loader (convert at load time, before caching)
- For rotation: `pose_rot = rest_rot.inverse() * kf_rot`
- For position: `pose_pos = rest_rot.inverse() * (kf_pos - rest_pos)` (rotate the delta into parent-local space)
- Use headless test to validate: after conversion, idle frame 0 should be ≈ identity for all bones
- Debug with headless test if conversion produces unexpected values — compare bone-by-bone
- Compare against OpenMW source (`animation.cpp`) if issues persist

**Approach for Mixamo retargeting (after MW fix):**
- `retarget_setup.gd` has `create_source_skeleton()`, `create_modifier()` — API exists, just not wired
- Add code path in `character_factory_v2.gd` using `RetargetModifier3D`
- Use `animation_loader.gd`'s `build_mixamo_remap()` for Mixamo anims

**Key files:**
- `src/core/animation/character_factory_v2.gd` — animation loading + (future) retargeting
- `src/core/animation/retarget_setup.gd` — retargeting API
- `src/core/nif/nif_skeleton_builder.gd` — rest pose setup (lines 273-298)
- `src/core/nif/nif_kf_loader.gd` — KF keyframe loading
- `src/core/coordinate_system.gd` — transform conversions
- OpenMW source: `components/nifosg/nifloader.cpp`, `apps/openmw/mwrender/animation.cpp`

**Verify:** Headless tests pass (bone poses within tolerance). Visual test shows natural idle/walk/run.

---

### Session 3: Delete Dead Mixamo Code + Improve Mixamo Retarget

**Status:** DONE (2026-02-13)
**Goal:** Remove 4 superseded files (~1,360 lines), relocate misplaced `mesh_extractor.gd`, fix Mixamo retarget quality.

**Files to delete:**
- `src/core/character/mixamo/bone_mapper.gd` (294L) — replaced by `skeleton_profile_adapter.gd`
- `src/core/character/mixamo/mixamo_animation_loader.gd` (323L) — replaced by `animation_loader.gd`
- `src/core/character/mixamo/mixamo_skeleton_template.gd` (297L) — unused, MW uses native skeleton
- `src/core/character/mixamo/skin_rebinder.gd` (445L) — replaced by native skin attachment in assembler

**File to move:**
- `src/core/character/mixamo/mesh_extractor.gd` -> `src/core/character/mesh_extractor.gd`

**Update references in:**
- `src/core/character/morrowind/morrowind_npc_assembler.gd`
- `src/tools/character_assembly_test.gd`
- `src/tools/native_skeleton_test.gd`

**Verify:** Project loads, `world_explorer.tscn` runs, NPCs appear correctly.

**Estimated scope:** ~1,360 lines deleted, ~10 lines path updates

---

### Session 4: Consolidate Test Files

**Status:** NOT STARTED
**Goal:** Reduce 9 test files (~5,830 lines) to ~5 focused scenes with non-overlapping purposes.

**Keep (distinct purposes):**
- `animation_integration_test.gd` (663L) — end-to-end NPC animation verification
- `ik_visual_test.gd` (1,135L) — interactive IK testing
- `body_part_diagnostic.gd` (650L) — body part assembly debugging
- `morrowind_adapter_test.gd` (417L) — skeleton profile adapter testing
- `ik_animation_showcase.gd` (1,001L) — IK showcase/demo

**Delete (overlapping or obsolete):**
- `character_assembly_test.gd` (1,248L) — ~600 lines duplicate assembler; unique features folded into `body_part_diagnostic.gd`
- `npc_assembly_test.gd` (590L) — overlaps with animation_integration_test + body_part_diagnostic
- `bone_mapping_test.gd` (342L) — overlaps with morrowind_adapter_test
- `native_skeleton_test.gd` (259L) — Phase 3B verification, redundant with integration test

**Also delete** corresponding `.tscn` files.

**Verify:** Remaining test scenes run without errors. Grep for deleted filenames — no broken references.

**Estimated scope:** ~2,440 lines deleted, ~50 lines moved to remaining files

---

### Session 5: Code Cleanup Pass

**Status:** NOT STARTED
**Goal:** Trim dead references, stale comments, and redundant data from core animation files.

**Tasks:**
1. Clean up `MORROWIND_BONE_MAP` reference dict in `morrowind_character_system.gd` (~75 lines of reference-only data)
2. Remove stale Mixamo references in comments across animation files
3. Clean up any dead imports/preloads left from Session 3 deletions
4. Verify all animation files have accurate header comments

**Note:** The 5 "unused framework" files (`procedural_modifier_controller`, `animation_priority`, `animation_lod_controller`, `animation_blend_mask`, `creature_animation_system`) are actually ALL wired into the production pipeline — they just haven't been visually verified. They stay.

**Verify:** Project loads, no errors.

**Estimated scope:** ~80 lines removed, ~20 lines comment updates

---

### Session 6: Documentation Consolidation

**Status:** NOT STARTED
**Goal:** Reduce 6 animation docs (~120KB) to 2 current docs + archive.

**Keep and update:**
- `docs/ANIMATION_SYSTEM.md` — rewrite to reflect actual current architecture
- `docs/ANIMATION_OVERHAUL.md` — mark completed phases, trim speculative future phases

**Archive to `docs/archive/`:**
- `docs/design/CHARACTER_ANIMATION_SYSTEM.md` (35K) — V2 design spec, decisions implemented
- `docs/NPC_ASSEMBLY_RESEARCH.md` (29K) — research complete, key findings in MEMORY.md
- `docs/NPC_ASSEMBLY_BUGS.md` (7.9K) — bugs fixed
- `docs/OPENMW_BODY_SYMMETRY.md` (19K) — reference research

**Also update:** `docs/STATUS.md`, `.claude/CLAUDE.md` doc table, `MEMORY.md`

**Verify:** All doc links in CLAUDE.md work.

---

## Summary

| Session | Goal | Lines Removed | Risk | Status |
|---------|------|--------------|------|--------|
| 1 | Diagnose animation quality | 0 | — | DONE (partial) |
| **1B** | **Fast loading + headless tests** | **~0 (net +200)** | **None** | **DONE** |
| 2 | Fix MW anims + Mixamo retargeting | ~0 (net +300) | pose=rest^-1*kf | **DONE** |
| 3 | Delete dead Mixamo + retarget fix | ~1,460 | Hidden reference | **DONE** |
| 4 | Consolidate test files | ~2,440 | Losing useful diagnostic | NOT STARTED |
| 5 | Code cleanup pass | ~80 | None | NOT STARTED |
| 6 | Doc consolidation | ~90K archived | None | NOT STARTED |

**Total: ~3,980 lines of dead code removed, ~90K docs archived, animation quality fixed.**

**Session dependency chain:** 1B → 2 → 3 → 4 → 5 → 6. Sessions 3-6 (cleanup) are independent of 1B/2 (animation fix) and can proceed in parallel if desired.

---

## Context Continuity Between Sessions

Each session starts fresh. Here's how we avoid losing context:

1. **This plan file** is the roadmap — each session starts by reading it and checking off completed sessions
2. **MEMORY.md** already has detailed notes on architecture, gotchas, and fixes — it persists across sessions
3. **After each session**, update MEMORY.md with:
   - What was done (completed session + key decisions)
   - What was discovered (any surprises that affect future sessions)
   - What to watch out for next
4. **Session ordering is dependency-aware** — Session 1B must come before Session 2. Sessions 3-6 can proceed independently.
5. **Each session's "Verify" step** produces a concrete artifact (screenshot, passing run, clean grep) that the next session can check

**To start any session**, just say: "Let's do Session N of the animation cleanup plan."
