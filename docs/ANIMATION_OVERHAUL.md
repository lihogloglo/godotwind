# Character Animation System — Overhaul Tracker

**Started:** 2026-02-08
**Goal:** General-purpose, industry-standard animation system. Morrowind as one adapter module.

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Retargeting approach | RetargetModifier3D | Characters keep native skeletons; no mesh rebinding |
| Bone mapping | Godot 4.6 SkeletonProfileHumanoid + BoneMap | Replaces 3 scattered custom mapping implementations |
| Future extensions | Ragdoll + procedural IK locomotion | Extension points designed from Phase 1 |
| Morrowind role | Pure adapter module | MORROWIND_ANIM_MAP stays; bone mapping delegates to shared system |
| Test method | Headless automated scenes | `extends SceneTree` + `--headless --script` |

---

## Existing Codebase (Pre-Overhaul)

### Animation Files (~5,500 lines across 14 files)

**Core animation system** (`src/core/animation/`):

| File | Lines | Role | Status |
|------|-------|------|--------|
| `character_animation_system.gd` | 414 | Base orchestrator: manages animation_manager, ik_controller, procedural_modifiers, lod_controller | Working but disconnected |
| `humanoid_animation_system.gd` | 369 | Humanoid specialization: combat, weapons, custom bone mapping | Has duplicate bone mapping logic |
| `morrowind_character_system.gd` | 310 | Morrowind specialization: MORROWIND_BONE_MAP, MORROWIND_ANIM_MAP, swimming, beast races | Has yet another bone mapping |
| `creature_animation_system.gd` | ~200 | Creature specialization: quadruped, n-legged | Framework only |
| `animation_manager.gd` | 661 | AnimationTree + 3-layer state machine, text key processing | Working |
| `ik_controller.gd` | 656 | TwoBoneIK3D foot/hand/look-at IK, quadruped mode | Complete but NOT integrated |
| `animation_blend_mask.gd` | ~150 | Bone blend masks (OpenMW-style), hardcoded Morrowind names | Working but hardcoded |
| `animation_priority.gd` | ~120 | Per-group animation priority system | Working |
| `procedural_modifier_controller.gd` | ~200 | Breathing, sway, hit reactions | Working |
| `animation_lod_controller.gd` | ~150 | LOD-based animation quality scaling | Working |
| `text_key_handler.gd` | ~200 | Morrowind .kf text key parsing (footsteps, sounds, hit timing) | Parses but unused |
| `character_factory_v2.gd` | ~250 | Character assembly pipeline | Working |
| `skeleton_profile_adapter.gd` | 387 | **NEW** — BoneMap creation for any skeleton type | Phase 1A complete |

**Character system** (`src/core/character/`):

| File | Lines | Role |
|------|-------|------|
| `character_movement_controller.gd` | ~300 | CharacterBody3D with walk/run/swim — does NOT call animation system |
| `morrowind/morrowind_npc_assembler.gd` | ~400 | 27-slot body part assembly |
| `morrowind/morrowind_body_part_slots.gd` | ~100 | Slot definitions |
| `mixamo/bone_mapper.gd` | 295 | MORROWIND_TO_MIXAMO bidirectional mapping (40+ entries) |
| `mixamo/mixamo_skeleton_template.gd` | 298 | Programmatic T-pose skeleton creation (FULL/SIMPLIFIED/BEAST) |
| `mixamo/mixamo_animation_loader.gd` | ~200 | Mixamo FBX animation import |
| `mixamo/mesh_extractor.gd` | ~150 | Mesh extraction utilities |
| `mixamo/skin_rebinder.gd` | ~300 | Skin rebinding (to be replaced by RetargetModifier3D) |

### Key Problems Identified

1. **Bone mapping duplicated 3 times:** `humanoid_animation_system.gd`, `morrowind_character_system.gd`, `mixamo/bone_mapper.gd` all have their own mapping logic
2. **IK complete but never called:** `ik_controller.gd` (656 lines) has full TwoBoneIK3D implementation — zero callers
3. **Movement doesn't drive animation:** `character_movement_controller.gd` never calls animation system
4. **Text keys parsed but unused:** `.kf` file events (footsteps, sounds) are parsed by `text_key_handler.gd` but never registered
5. **No SkeletonProfileHumanoid usage:** Custom mapping instead of Godot 4.6 native BoneMap/profile
6. **Hardcoded Morrowind names in blend masks:** `animation_blend_mask.gd` uses "Bip01 Spine1" etc.
7. **Skin rebinding instead of RetargetModifier3D:** Characters get rebinded to Mixamo skeleton instead of keeping native

### Class Hierarchy

```
CharacterAnimationSystem (base orchestrator)
├── HumanoidAnimationSystem (combat, weapons, custom bone mapping)
│   └── MorrowindCharacterSystem (Morrowind-specific: swimming, beast races, MW bone map)
└── CreatureAnimationSystem (quadruped, n-legged — framework only)
```

---

## Testing Method

### Headless Automated Tests

Tests run via Godot CLI without GPU rendering:

```bash
"D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64_console.exe" --headless --path "d:\Gamedev\Godotwind\godotwind" --script res://tests/test_skeleton_profile.gd
```

### Test Pattern

All tests use `extends SceneTree` (not `extends Node3D`) because headless `--script` mode doesn't create a scene tree automatically:

```gdscript
extends SceneTree

# CRITICAL: Must preload classes — headless mode doesn't load class_name registry
const SPA := preload("res://src/core/animation/skeleton_profile_adapter.gd")

var _pass_count := 0
var _fail_count := 0

func _init() -> void:
    # Run tests after 1 frame so everything initializes
    await process_frame
    _run_tests()
    _report()
    quit(1 if _fail_count > 0 else 0)

func _run_tests() -> void:
    _test_something()
    # ...

func _assert_eq(actual: Variant, expected: Variant, desc: String) -> void:
    if actual == expected:
        _pass_count += 1
        print("  PASS: %s" % desc)
    else:
        _fail_count += 1
        print("  FAIL: %s (got %s, expected %s)" % [desc, str(actual), str(expected)])

func _report() -> void:
    print("=== %d/%d passed ===" % [_pass_count, _pass_count + _fail_count])
```

### Headless Mode Gotchas

| Gotcha | Solution |
|--------|----------|
| `class_name` types not available | Use `const X := preload("res://path.gd")` |
| Static methods on preloaded scripts may fail | Create helper functions in the test instead |
| `Log` autoload not loaded at compile time | Use `load()` instead of `preload()` for scripts that reference `Log` |
| `BoneMap.get_skeleton_bone_name()` errors on unknown profile bone | Guard with `profile.find_bone(name) >= 0` before querying |
| RenderingServer calls fail in headless | Avoid visual tests; use transform/bone assertions |
| AnimationTree `connect_node` error in headless | Pre-existing Godot issue; non-fatal, state machine still works |
| AnimationTree process callbacks crash in headless | Call `set_process(false)` on AnimationManager before testing |
| Segfault on exit with AnimationTree | Set `animation_tree.active = false` before `queue_free()` |

---

## Phase 1: Native Retargeting Foundation

Replace custom bone mapping with Godot 4.6 SkeletonProfileHumanoid + BoneMap.

### Session 1A: SkeletonProfile Integration Layer — COMPLETE

- [x] **Created:** `src/core/animation/skeleton_profile_adapter.gd` (387 lines)
  - Auto-detects skeleton type (Morrowind Bip01 / Mixamo / Generic)
  - Creates BoneMap with correct SkeletonProfileHumanoid mappings
  - Full finger mapping for Morrowind (30 finger bones) and Mixamo
  - Heuristic matching for unknown skeletons
  - Stores BoneMap as skeleton metadata for retrieval by other systems
  - Public API: `create_bone_map()`, `get_bone_map()`, `get_skeleton_bone()`, `get_bone_index()`, `detect_skeleton_type()`, `count_mapped_bones()`, `get_unmapped_bones()`

- [x] **Created:** `tests/test_skeleton_profile.gd` (headless test)
  - 94/94 tests pass (expanded in 1B)
  - Tests Morrowind skeleton: 22 core bones + finger bones
  - Tests Mixamo skeleton: 22 core bones + finger bones
  - Tests Generic skeleton: 19 bones via heuristic matching
  - Tests type detection and utility methods
  - Tests IK bone resolution via BoneMap (16 tests)
  - Tests blend mask bone resolution via BoneMap (9 tests)
  - Creates skeletons programmatically (self-contained, no file dependencies)

- [x] **Created:** `src/tools/bone_mapping_test.tscn` (visual test scene)
  - 3 skeletons side-by-side: Morrowind, Mixamo, Generic
  - Color-coded bones: green = mapped, red = unmapped
  - Profile name labels, detection type, mapped count

**Key mapping detail:** Morrowind "Bip01 Spine1" maps to profile "Chest" (not "Spine1"), "Bip01 Spine2" maps to "UpperChest". This is correct per SkeletonProfileHumanoid's naming convention.

### Session 1B: Refactor Systems to Use BoneMap — COMPLETE

- [x] **Modified:** `ik_controller.gd`
  - Replaced 75-line `_find_bone_indices()` with 20-line `_IK_TO_PROFILE` dict + SPA lookup
  - Removed `_is_left_bone()` and `_is_right_bone()` helpers (~55 lines removed)
  - Quadruped mode stays custom (no standard profile for quadrupeds)

- [x] **Modified:** `humanoid_animation_system.gd`
  - Replaced 105-line `_build_bone_map()` + `_map_bone_name()` + `_is_left()`/`_is_right()` with 12-line BoneMap iteration (~93 lines removed)
  - `_bone_map` now uses profile names as keys

- [x] **Modified:** `animation_blend_mask.gd`
  - Replaced hardcoded `BLEND_MASK_ROOTS` with profile names (`"Chest"`, `"LeftShoulder"`, `"RightShoulder"`)
  - Removed `BONE_ALIASES` dict and `_find_bone()` method (~30 lines removed)
  - Mask resolution delegates to SPA

- [x] **Extended test:** 94/94 pass — IK resolution (16 tests) + blend mask resolution (9 tests) on both Morrowind and Mixamo skeletons

### Session 1C: Morrowind as Pure Adapter — COMPLETE

- [x] **Modified:** `morrowind_character_system.gd`
  - Removed `_build_bone_map()` override entirely — parent's SPA-based implementation auto-detects Morrowind (Bip01 prefix)
  - The old override was already broken (called removed `_map_bone_name()` method) and used non-standard names ("Spine1" instead of "Chest")
  - `MORROWIND_BONE_MAP` dict kept as reference documentation, marked with comment
  - `MORROWIND_ANIM_MAP` unchanged (genuinely Morrowind-specific animation names)

- [x] **Created:** `src/tools/ik_visual_test.tscn` (interactive visual IK test)
  - Humanoid skeleton on uneven terrain with foot IK (TwoBoneIK3D), look-at IK, hand target
  - **Interactive:** Left-click drag to move look orb / hand cube, WASD to walk character
  - Shift+click spawns terrain steps, R resets position, Space resumes auto-motion
  - Info panel shows IK state, head-to-target angle, foot targets, pelvis offset, character pos

- [x] **Created:** `src/tools/morrowind_adapter_test.tscn` (Phase 1C verification)
  - Runs full pipeline: SPA → HumanoidAnimationSystem bone map → IK resolution → blend masks
  - Color-coded bones: green=mapped, yellow=IK, cyan=blend mask root, red=unmapped
  - Info panel shows all mappings, IK bone resolution, blend mask details

**Phase 1 Test:** 94/94 headless mapping tests pass. IK behavior test validates look-at rotation, angle limits, foot IK pelvis offset, and enable/disable. Interactive visual test allows mouse-driven target dragging and WASD walking to verify IK response in real-time.

---

## Phase 2: Wire Up Disconnected Systems

### Session 2A: Movement-to-Animation Bridge — COMPLETE

- [x] **Modified:** `character_movement_controller.gd`
  - Added `var animation_system: Node = null`
  - In `_physics_process()` after `move_and_slide()`: calls `animation_system.update_from_movement(velocity, is_on_floor())`

- [x] **Modified:** `character_factory_v2.gd`
  - Wired `movement_controller.animation_system = anim_system` in both `create_npc()` and `create_creature()`
  - Kept `set_meta("animation_system", ...)` for external queries

### Session 2B: Text Key Pipeline Completion — COMPLETE

- [x] **Modified:** `animation_manager.gd`
  - Fixed `_process_text_keys()` to use `_state_machine.get_current_node()` + `get_current_play_position()` instead of `animation_player.current_animation`
  - Maps state machine node name → animation name via `_state_animation_map`

- [x] **Modified:** `character_animation_system.gd`
  - Added signals: `sound_triggered`, `hit_triggered`, `footstep_triggered`
  - Connected AnimationManager text key signals in `_setup_controllers()`
  - Added `register_text_keys()` convenience method

- [x] **Created:** `tests/test_animation_wiring.gd` — 16/16 pass
  - Movement drives state: Idle→Walk→Run→Idle→Jump→Fall (8 tests)
  - Signal forwarding: sound, hit, footstep propagate through CAS (6 tests)
  - Text key registration: call chain works, handler queryable (2 tests)
  - Uses runtime `load()` instead of `preload()` (headless autoload timing)
  - Disables AnimationTree process callbacks (headless mode limitation)

---

## Phase 3: RetargetModifier3D — Replace Mesh Rebinding

Characters keep native skeletons; animations retarget at runtime.

### Session 3A: RetargetModifier3D Setup — COMPLETE

- [x] **Created:** `src/core/animation/retarget_setup.gd` (175 lines)
  - `rename_bones_to_profile(skeleton, bone_map)` — renames skeleton bones from native to SkeletonProfileHumanoid names
  - `build_remap(skeleton)` — computes native → profile name map without modifying skeleton
  - `create_source_skeleton(reference, custom_rest_poses)` — creates source skeleton for retarget hierarchy
  - `create_modifier(use_global_pose)` — creates configured RetargetModifier3D
  - `remap_animation(animation, name_map)` — remaps bone names in animation track paths (non-destructive)
  - `remap_library(library, name_map)` — remaps all animations in a library
  - `setup_retargeting(target, source_type)` — convenience: full setup (rename + create source + create modifier)
  - Uses BoneMap from Phase 1 (SPA) for all bone name resolution

- [x] **Modified:** `animation_manager.gd`
  - Added `retarget_source: Skeleton3D` property
  - `_find_animation_player()` and `_create_animation_tree()` use retarget_source when set
  - Allows AnimationPlayer/AnimationTree to target source skeleton while IK targets character skeleton

- [x] **Created:** `tests/test_retargeting.gd` — 87/87 pass
  - 14 test suites covering all RetargetSetup functions:
  - `build_remap`: computes Morrowind → profile name map without modifying skeleton
  - `rename_bones_to_profile` (Morrowind): renames Bip01 bones, verifies old names gone, count preserved
  - `rename_bones_to_profile` (Mixamo): renames mixamorig1_ bones
  - Unmapped bones preserved (extra bones like "Bip01 Weapon" not touched)
  - `create_source_skeleton`: copies structure, hierarchy, rest poses from reference
  - Custom rest poses: overrides specific bone rests while copying the rest
  - `create_modifier`: correct profile, name, use_global_pose settings
  - `remap_animation`: remaps bone names in track subpaths, preserves node path
  - Empty/non-matching remap maps: returns original unchanged
  - `remap_library`: remaps all animations, original library not modified
  - `setup_retargeting`: returns null for same type, returns result for different type
  - Hierarchy assembly: source > modifier > target, all bones match

**Key design insight:** RetargetModifier3D requires both skeletons to share bone names matching the profile. Solution: rename both to SkeletonProfileHumanoid names. Skin uses bone indices (renaming is safe for already-skinned meshes). Animation track paths get remapped via `remap_animation()`.

### Session 3B: Rework NPC Assembly Pipeline — COMPLETE

- [x] **Modified:** `morrowind_npc_assembler.gd`
  - Replaced Mixamo skeleton with native Morrowind skeleton (from xbase_anim.nif via NIFConverter)
  - Removed all Mixamo dependencies (MixamoSkeletonTemplate, BoneMapper, SkinRebinder)
  - New `_create_native_skin()` — maps mesh bone names directly to skeleton by name
  - Body parts attach without rebinding — bone names match natively
  - Two skeleton variants: humanoid (xbase_anim.nif) / beast (xbase_animkna.nif)

- [x] **Modified:** `character_factory_v2.gd`
  - After assembly: renames skeleton bones to profile names via `RetargetSetup.rename_bones_to_profile()`
  - Bone remap (Bip01 → profile) built lazily and cached per skeleton type
  - Animation libraries remapped from Bip01 → profile bone names via `RetargetSetup.remap_library()`
  - Remapped libraries cached for sharing (remap happens once per library type)
  - Preload pipeline: builds remaps from skeleton cache, then remaps preloaded animations

- [x] **Created:** `src/tools/native_skeleton_test.tscn` (visual pipeline verification)
  - Step 1: Loads native skeleton from xbase_anim.nif, verifies expected Bip01 bones
  - Step 2: Builds bone remap (Bip01 → profile), shows sample mappings
  - Step 3: Renames bones, verifies profile names exist (Hips, Spine, Chest, etc.)
  - Step 4: Verifies SPA creates BoneMap on renamed skeleton
  - Step 5: Tests animation track remapping (Bip01 Spine → Spine/Chest)
  - Step 6: Bone visualization (green=mapped, red=unmapped)

**Key design insight:** Skin binds use bone *indices* (not names), so renaming bones after creating Skin resources is safe. Animation track paths use bone *names*, so they must be remapped via `RetargetSetup.remap_library()`.

**Phase 3 Test:** 94/94 skeleton profile, 16/16 animation wiring, 87/87 retargeting — all passing.

### Session 3C: Animation Integration Test & Bug Fixes — COMPLETE

- [x] **Created:** `src/tools/animation_integration_test.gd` + `.tscn` (end-to-end NPC animation test)
  - Spawns NPC via CharacterFactoryV2, runs full diagnostic pipeline
  - Verifies: skeleton bones renamed, animations loaded & remapped, AnimationTree active, state machine working
  - Controls: W=wander, I=IK, D=debug, R=reload, 1/2/3=switch NPC
  - Ground plane with StaticBody3D collision for CharacterBody3D physics

- [x] **Fixed:** `nif_kf_loader.gd` — Track path format always `".:BoneName"`
  - Root cause: preloading with `skeleton=null` produced bare `"BoneName"` tracks; `remap_animation()` skipped them
  - Fix: Always use `".:bone_name"` — these are always bone tracks targeting a Skeleton3D

- [x] **Fixed:** `character_factory_v2.gd` — BoneAttachment3D name update after bone renaming

- [x] **Fixed:** `animation_manager.gd` — Exact-first animation name matching (prevents "idlecombat" matching before "idle")

- [x] **Fixed:** `animation_manager.gd` — Guard against missing state machine states in `transition_to()`

- [x] **Simplified:** `animation_manager.gd` — Blend tree now locomotion-only (upper body + additive layers deferred to Phase 6)

**Result:** 132 MW animations loaded, 67/69 tracks remapped to profile names (2 unmapped aux bones expected). Zero errors.

### Session 3D: Visual Fix & Mixamo Loading — COMPLETE

- [x] **Fixed:** `animation_manager.gd` — AnimationTree added to Skeleton3D (was added to parent Node3D)
  - Root cause: AnimationTree's default `root_node` is `".."` (parent). When AnimationTree was a child of Character (Node3D), `".."` resolved to Character. Track paths `".:BoneName"` then tried to find bones on Character (not Skeleton3D), silently failing → mesh stayed in rest pose.
  - Fix: `anim_skel.add_child(animation_tree)` instead of `anim_skel.get_parent().add_child(animation_tree)`. Now `".."` resolves to Skeleton3D, and `".:Hips"` correctly finds bones.

- [x] **Created:** `src/core/animation/animation_loader.gd` (~230 lines) — Phase 7 unified animation loader
  - Loads FBX, GLB, GLTF files via Godot's importer
  - Normalizes track paths to `".:ProfileBoneName"` format
  - Auto-detects skeleton type (Mixamo, Morrowind, Generic) and remaps bone names
  - Standard name normalization: file name → canonical names (idle, walk, run, jump, etc.)
  - Sets loop mode for locomotion animations
  - API: `load_from_fbx()`, `load_from_glb()`, `load_from_directory()`

- [x] **Enhanced:** `animation_integration_test.gd` — Mixamo toggle and diagnostics
  - [M] key toggles between Morrowind and Mixamo animations on current NPC
  - Loads Mixamo FBX files via AnimationLoader, remaps to profile names
  - Diagnostics now verify AnimationTree `root_node` resolves to Skeleton3D
  - Diagnostics now verify AnimationPlayer `root_node` resolves to Skeleton3D

- [x] **Wired:** `world_explorer.gd` — `CharacterFactoryV2.preload_character_assets()` called at startup
  - After BSA + ESM loaded, before streaming starts (~85% loading progress)
  - Preloads skeletons, bone remaps, animation libraries for all character types

---

## Phase 4: Head Animation & Equipment Attachment

### Session 4A: Head Animation Controller

- [ ] **New:** `src/core/animation/head_animation_controller.gd` (~200 lines)
  - Talk: jaw/head modulation from AudioStreamPlayer3D loudness
  - Blink: random interval (3-7s), ~0.15s duration
  - Eye tracking: anticipatory eye movement if eye bones exist
  - Uses BoneMap for bone discovery

### Session 4B: Equipment Attachment System

- [ ] **New:** `src/core/animation/attachment_point_manager.gd` (~180 lines)
  - BoneAttachment3D nodes for slots: right_hand, left_hand, back, head, hip
  - `attach_item(slot, scene)` / `detach_item(slot)`
  - Uses BoneMap for bone lookup

- [ ] **New test:** `tests/test_head_and_attachments.gd`
  - Counts blink events over 10s (should be 1-3)
  - Attaches MeshInstance3D to "right_hand" slot, asserts it follows hand bone

---

## Phase 5: Advanced IK

### Session 5A: SplineIK for Tails & Chains

- [ ] **New:** `src/core/animation/spline_ik_controller.gd` (~150 lines)
  - Wraps SplineIK3D for bone chains (tails, tentacles, spines)
  - Procedural tail physics: lag-based follow with stiffness/damping

- [ ] **Modify:** `creature_animation_system.gd` — SplineIK for tails
- [ ] **Modify:** `morrowind_character_system.gd` — SplineIK for Argonian/Khajiit

### Session 5B: Pole Targets & FABRIK

- [ ] **Modify:** `ik_controller.gd` — Pole targets for TwoBoneIK3D (knees forward, elbows backward)
- [ ] **New:** `src/core/animation/reach_ik_controller.gd` (~120 lines) — FABRIK3D for multi-bone reaching
- [ ] **New test:** `tests/test_advanced_ik.gd`

---

## Phase 6: Multi-Layer Animation Blending

### Session 6A: Multi-Layer AnimationTree

- [ ] **Modify:** `animation_manager.gd`
  - Layer 0: Lower body (locomotion)
  - Layer 1: Upper body (attack, cast)
  - Layer 2: Left arm (shield/block)
  - Layer 3: Right arm (weapon)
  - Layer 4: Head (talk, look)
  - Layer 5: Additive (breathing, hit reactions)

### Session 6B: Priority-Driven Layer Control

- [ ] **Modify:** `animation_priority.gd` — Add `resolve_conflicts() -> Dictionary`
- [ ] **New test:** `tests/test_multilayer_blend.gd`
  - Walk + attack + block on different body parts simultaneously

---

## Phase 7: Unified Animation Loader — PARTIAL (FBX/GLB done, KF separate)

- [x] **Created:** `src/core/animation/animation_loader.gd` (~230 lines) — Session 3D
  - `load_from_fbx(path) -> AnimationLibrary`
  - `load_from_glb(path) -> AnimationLibrary`
  - `load_from_directory(path) -> AnimationLibrary`
  - Auto-detects skeleton type, remaps bone names to profile, normalizes track paths to `".:ProfileBone"`
  - Standard name normalization (idle, walk, run, jump, etc.)
- [ ] `load_from_kf(path)` — KF loading still handled by NIFKFLoader + CharacterFactoryV2 pipeline
- [ ] **New test:** `tests/test_animation_loader.gd`

---

## Phase 8: Extensibility — Ragdoll & Procedural Locomotion

### Session 8A: Modifier Registration System

- [ ] **Modify:** `character_animation_system.gd`
  - `register_modifier(modifier)` / `unregister_modifier(modifier)`
  - Sorted by priority, updated in order

- [ ] **New:** `src/core/animation/animation_modifier_interface.gd` (~50 lines)
  - Base class: `setup(skeleton)`, `update(delta)`, `get_priority()`, `get_lod_minimum()`

### Session 8B: Ragdoll & Procedural Locomotion Stubs

- [ ] **New:** `src/core/animation/ragdoll_controller.gd` (~80 lines, stub)
- [ ] **New:** `src/core/animation/procedural_locomotion_controller.gd` (~80 lines, stub)
- [ ] **New test:** `tests/test_modifier_system.gd`

---

## Dependency Graph

```
Phase 1 (Foundation) --> Phase 2 (Wiring) --> Phase 6 (Multi-layer)
         |                       |
         +--> Phase 3 (Retarget) | (can parallel with Phase 4)
         |                       |
         +--> Phase 4 (Head+Attach) <--+
         |
         +--> Phase 5 (Advanced IK)
         |
         +--> Phase 7 (Loader) --> Phase 8 (Extensibility)
```

---

## New Files Summary

| File | Est. Lines | Purpose | Phase |
|------|-----------|---------|-------|
| `skeleton_profile_adapter.gd` | 387 | BoneMap creation for any skeleton | 1A DONE |
| `retarget_setup.gd` | 175 | RetargetModifier3D utilities (rename, remap, hierarchy) | 3A DONE |
| `native_skeleton_test.gd` | ~200 | Visual pipeline test (skeleton + remap + visualization) | 3B DONE |
| `head_animation_controller.gd` | ~200 | Talk, blink, eye tracking | 4A |
| `attachment_point_manager.gd` | ~180 | Equipment slots via BoneAttachment3D | 4B |
| `spline_ik_controller.gd` | ~150 | SplineIK3D for tails/chains | 5A |
| `reach_ik_controller.gd` | ~120 | FABRIK3D reaching | 5B |
| `animation_loader.gd` | 230 | Unified animation loading (FBX/GLB) | 7 DONE |
| `animation_modifier_interface.gd` | ~50 | Base class for animation modifiers | 8A |
| `ragdoll_controller.gd` | ~80 | Ragdoll stub | 8B |
| `procedural_locomotion_controller.gd` | ~80 | Procedural locomotion stub | 8B |

### Test Files

| File | Phase | What It Tests |
|------|-------|---------------|
| `tests/test_skeleton_profile.gd` | 1 | Bone mapping (MW/Mixamo/Generic), IK bone discovery, blend masks — 94/94 PASS |
| `tests/test_ik_behavior.gd` | 1 | IK behavior: look-at rotation, angle limits, foot pelvis offset, enable/disable |
| `src/tools/ik_visual_test.tscn` | 1 | Interactive: mouse drag targets, WASD walk, Shift+click spawn terrain, toggle IK |
| `src/tools/morrowind_adapter_test.tscn` | 1C | Visual: full pipeline (SPA→bone map→IK→blend masks), color-coded |
| `tests/test_animation_wiring.gd` | 2 | State transitions (Idle↔Walk↔Run, Jump, Fall), signal forwarding, text key registration — 16/16 PASS |
| `tests/test_retargeting.gd` | 3A | Bone renaming, animation remapping, source skeleton, modifier config, hierarchy — 87/87 PASS |
| `src/tools/native_skeleton_test.tscn` | 3B | Visual: native skeleton load, bone rename, animation remap, bone visualization |
| `src/tools/animation_integration_test.tscn` | 3C | End-to-end: spawn NPC, verify remapped tracks, AnimationTree, state machine, ground physics |
| `tests/test_head_and_attachments.gd` | 4 | Blinks happen, attached item follows hand bone |
| `tests/test_advanced_ik.gd` | 5 | SplineIK tails, knee pole targets, FABRIK reach |
| `tests/test_multilayer_blend.gd` | 6 | Walk+attack+block on different body parts |
| `tests/test_animation_loader.gd` | 7 | All animation formats load correctly |
| `tests/test_modifier_system.gd` | 8 | Modifiers register, execute in order, respect LOD |
