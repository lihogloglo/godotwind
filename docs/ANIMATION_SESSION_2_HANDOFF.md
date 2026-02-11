# Animation Session 2 — Agent Handoff Document

**Created:** 2026-02-11
**Status:** IN PROGRESS — MW animations working, Mixamo retargeting has one remaining bug
**Parent plan:** `docs/ANIMATION_CLEANUP_PLAN.md` (Session 2)
**Memory:** `C:\Users\metzo\.claude\projects\d--Gamedev-Godotwind-godotwind\memory\MEMORY.md`

---

## TL;DR — What's Left

One bug remains: **Mixamo retargeted Hips position is 2x too high (2.18m vs expected ~1.09m)**. The position formula in `_retarget_animation_absolute()` adds the scaled Mixamo position ON TOP of the MW rest position instead of using the delta from the source rest. Fix is straightforward — see "Remaining Bug" section.

Everything else works: MW animations play correctly, AnimationTree rebuild doesn't leak, autotest pipeline runs end-to-end with full NPC pipeline.

---

## The MW Skeleton Absolute-Value Quirk

This is the single most important thing to understand about the animation system.

**How Godot normally works:** `bone_local = bone_rest * bone_pose`. Animation keyframes provide `bone_pose`, which is REST-RELATIVE (identity = rest pose).

**How the MW skeleton works:** KF animation keyframes are **100% ABSOLUTE** parent-local transforms. When you read idle frame 0, you get the EXACT same value as the bone's rest pose. The KF loader stores these absolute values directly as Godot `bone_pose`.

**Why this works despite being mathematically weird:** When `pose = rest` (idle), Godot computes `local = rest * rest = rest²`. Despite rest being applied twice, the skeleton visually looks correct because Godot's bone chain computation and the NIF rest poses conspire to produce the right shape. We confirmed this empirically:
- S1 PASS: MW Hips height 1.09m (correct for Wood Elf)
- All proportions correct (arms at sides, legs standing, head upright)

**Why rest-relative conversion FAILS:** Converting KF absolute values to rest-relative (`pose = rest⁻¹ * kf`) produces identity for idle, which collapses the skeleton to a single point at Y≈-0.2. This was the original Session 1 bug. The fix was to **remove** the rest-relative conversion and use raw KF absolute values directly.

**Key code:** `src/core/animation/character_factory_v2.gd` → `_remap_and_cache_library()` — the `_convert_library_to_rest_relative()` call was removed. Raw KF values are used as-is.

**Headless proof:** `tests/test_animation_poses.gd` confirms: idle frame 0 === rest pose for all 33 bones (0.00° difference, 0.0000m delta).

---

## What's Working

### MW Animations on MW Skeleton
- 132 animations loaded from KF files via BSA
- Tracks remapped from Bip01 names → SkeletonProfileHumanoid names (67/69 tracks, 2 unmapped aux bones)
- KF track paths use `".:BoneName"` format (REQUIRED — without `.:` prefix, `NodePath.get_subname_count()` returns 0 and remapping skips the track)
- AnimationTree created as child of Skeleton3D (REQUIRED — default `root_node` is `".."` which must resolve to Skeleton3D)
- State machine with Idle/Walk/Run/Jump/Fall/Land states, auto-matched to animation names via case-insensitive search

### Mixamo Animation Loading + Retargeting
- 5 Mixamo FBX files loaded from `assets/animations/mixamo/`: idle, walk, jump, jump_up, jump_down
- Bone names remapped from `mixamorig1_*` → profile names via `skeleton_profile_adapter.gd`
- Source rest poses extracted from FBX skeleton (65 bones)
- Target rest poses extracted from MW skeleton (33 bones)
- Retargeting uses `_retarget_animation_absolute()` — a special formula for the MW absolute-value skeleton
- 32 bones compensated (those present in both source and target)

### AnimationTree Lifecycle
- `_cleanup_controllers()` in `character_animation_system.gd` now explicitly removes AnimationTree from Skeleton3D before freeing AnimationManager
- No more "two AnimationTrees fighting" bug (verified: S4 PASS — count stays at 1 after toggle)
- `_rebuild_animation_tree()` has two paths:
  - Full pipeline NPC: `anim_system.reset()` + `anim_system.setup()` (uses animation system)
  - Prebaked NPC: `_rebuild_animation_tree_direct()` (builds state machine from scratch)

### Test Infrastructure
- Autotest via `--autotest` command line flag forces full pipeline (skips prebaked NPC fast path)
- `_force_full_pipeline` flag set when autotest detected
- 8-stage validation: S1 MW idle, S2 tree count, S3 toggle, S4 leak check, S5 Mixamo idle, S6 anim list, S7 tree state, S8 MW restore

---

## Remaining Bug — Mixamo Hips Position 2x Too High

### Symptom
S5 reports Hips at Y=2.177m after Mixamo toggle. Expected ~1.09m (same as MW idle).

### Root Cause
In `animation_loader.gd` → `_retarget_animation_absolute()`, the root/Hips position formula is:

```gdscript
result = tgt_rest.origin + original_pos * height_ratio
```

For Mixamo idle, `original_pos` is the Mixamo rest position (~1.001). This gets scaled by `height_ratio` (~1.09) and ADDED to `tgt_rest.origin` (~1.091):
```
result = 1.091 + 1.001 * 1.09 = 1.091 + 1.091 = 2.182
```

### Fix
The formula should use the DELTA from source rest, not the full position:

```gdscript
# Current (wrong):
result.position_track_insert_key(new_idx, time, tgt_rest.origin + original_pos * height_ratio)

# Correct:
var delta := original_pos - src_rest.origin
result.position_track_insert_key(new_idx, time, tgt_rest.origin + delta * height_ratio)
```

For idle (`original_pos ≈ src_rest.origin`), delta ≈ 0, so result ≈ `tgt_rest.origin` (1.091m). For walking/jumping motions, delta captures the movement and scales it to the MW skeleton's proportions.

### Location
`src/core/animation/animation_loader.gd`, lines 558-564, inside `_retarget_animation_absolute()`:

```gdscript
for key_idx in source.track_get_key_count(track_idx):
    var time := source.track_get_key_time(track_idx, key_idx)
    var original_pos: Vector3 = source.track_get_key_value(track_idx, key_idx)
    if is_root and original_pos.length() > 0.001:
        # Scale root translation by height ratio
        var height_ratio := tgt_rest.origin.length() / maxf(0.001, src_rest.origin.length())
        result.position_track_insert_key(new_idx, time, tgt_rest.origin + original_pos * height_ratio)  # <-- BUG
    else:
        # Non-root bones: keep MW rest position
        result.position_track_insert_key(new_idx, time, tgt_rest.origin)
```

---

## Retargeting Math

### Standard (Rest-Relative Target) — `_retarget_animation()`
For skeletons that use standard Godot rest-relative poses:
- **Rotation:** `corrected = tgt_rest_rot⁻¹ * src_rest_rot * original_rot`
- **Position:** `corrected = tgt_basis⁻¹ * (src_origin - tgt_origin + src_basis * original_pos)`

### MW Absolute Target — `_retarget_animation_absolute()`
For the MW skeleton that uses absolute values as poses:
- **Rotation:** `corrected = src_rest_rot * original_rot * src_rest_rot⁻¹ * tgt_rest_rot`
  - Pre-computed: `basis_change = src_rot_inv * tgt_rot`
  - Per-key: `corrected = src_rot * original * basis_change`
  - For idle (`original = identity`): produces `tgt_rest_rot` — same as MW idle
- **Position (root/hips):** `tgt_rest_pos + (original_pos - src_rest_pos) * height_ratio` (AFTER fix)
- **Position (non-root):** `tgt_rest_pos` (preserve MW skeleton shape)

---

## How to Test

### Automated Test (primary verification method)
```
D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe --path "d:\Gamedev\Godotwind\godotwind" "res://src/tools/animation_integration_test.tscn" -- --autotest
```

**Expected output after fix:**
- S1 PASS — MW Hips height ~1.09m
- S4 PASS — AnimationTree count 1 (no leak)
- S5 PASS — Mixamo Hips height ~1.09m (currently FAILS at 2.18m)
- S5b PASS — Spine-Head distance >0.1m (skeleton not collapsed)
- S8 PASS — MW restored, height ~1.09m

### Manual Test (visual verification)
Run the scene normally (no --autotest flag), press [M] to toggle Mixamo. Visually confirm:
- Character stands at ground level (not floating)
- Arms at sides (not T-pose or stretched)
- Walk animation looks natural (press [W] to enable wander)
- Switching back to MW with [M] restores correct MW idle

### Headless Test (bone-level validation)
```
D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe --headless --path "d:\Gamedev\Godotwind\godotwind" --script "res://tests/test_animation_poses.gd"
```
Validates KF keyframes are absolute (idle frame 0 === rest for all bones).

### Controls in Test Scene
| Key | Action |
|-----|--------|
| W | Toggle wander (NPC walks around) |
| I | Toggle IK |
| M | Toggle Mixamo/Morrowind animations |
| D | Dump debug info to console |
| R | Rebuild NPC (full pipeline) |
| Tab | Enter animation browser |
| 1/2/3 | Switch NPC: Fargoth/Arrille/Sellus Gravius |

---

## All Bugs Found and Fixed This Session

### Bug 1: AnimationTree Leak (FIXED)
**File:** `src/core/animation/character_animation_system.gd` → `_cleanup_controllers()`
**Problem:** AnimationTree is created as child of Skeleton3D, not AnimationManager. When `_cleanup_controllers()` called `animation_manager.queue_free()`, the AnimationTree survived. Next `setup()` created a second AnimationTree → two fighting for bone control.
**Fix:** Explicitly deactivate, remove from parent, and queue_free the AnimationTree before freeing AnimationManager.

### Bug 2: Retargeting Formula (FIXED — rotation only)
**File:** `src/core/animation/animation_loader.gd` → `_retarget_animation_absolute()`
**Problem:** Standard retargeting formula produces rest-relative values that collapse the MW skeleton.
**Fix:** Added MW-specific `_retarget_animation_absolute()` with formula `corrected = src_rest * original * src_rest⁻¹ * tgt_rest`. For idle (original=identity), this produces `tgt_rest` — preserving MW idle shape.

### Bug 3: Prebaked NPC During Autotest (FIXED)
**File:** `src/tools/animation_integration_test.gd` → `_spawn_npc()`, `_ready()`
**Problem:** `_spawn_npc()` always tried prebaked NPC first, even during autotest. Prebaked NPCs lack `animation_system` meta, so `_rebuild_animation_tree()` failed and the AnimationTree was never rebuilt with Mixamo animation names.
**Fix:** Set `_force_full_pipeline = true` when `--autotest` detected. Both `_ready()` and `_spawn_npc()` now check this flag.

### Bug 4: No AnimationTree Rebuild for Prebaked NPCs (FIXED)
**File:** `src/tools/animation_integration_test.gd` → `_rebuild_animation_tree()`, `_rebuild_animation_tree_direct()`
**Problem:** When no animation system was available, `_rebuild_animation_tree()` just logged an error and returned.
**Fix:** Added `_rebuild_animation_tree_direct()` fallback that removes old AnimationTree, builds a new state machine from the current AnimationPlayer library, and creates a fresh AnimationTree.

### Bug 5: Root Position Formula (NOT YET FIXED)
**File:** `src/core/animation/animation_loader.gd` → `_retarget_animation_absolute()`, lines 558-564
**Problem:** Root/Hips position adds scaled Mixamo position on top of MW rest position instead of using delta.
**Fix:** Change `tgt_rest.origin + original_pos * height_ratio` to `tgt_rest.origin + (original_pos - src_rest.origin) * height_ratio`

---

## Key Files

### Core Animation Pipeline
| File | Purpose |
|------|---------|
| `src/core/animation/animation_loader.gd` | Unified FBX/GLB loading, bone remap, retargeting |
| `src/core/animation/animation_manager.gd` | AnimationTree setup, state machine, blend parameters |
| `src/core/animation/character_animation_system.gd` | Base class — creates/manages AnimationManager, IKController, etc. |
| `src/core/animation/character_factory_v2.gd` | NPC creation pipeline (skeleton + body parts + animations) |
| `src/core/animation/retarget_setup.gd` | Bone renaming, remap building, animation track remapping |
| `src/core/animation/skeleton_profile_adapter.gd` | Mixamo/MW bone name → profile name mapping |
| `src/core/animation/morrowind_character_system.gd` | MW-specific animation system (extends Humanoid) |
| `src/core/animation/humanoid_animation_system.gd` | Humanoid animation system (extends CharacterAnimationSystem) |

### Test Files
| File | Purpose |
|------|---------|
| `src/tools/animation_integration_test.gd` | **PRIMARY** — end-to-end NPC + animation verification scene |
| `src/tools/animation_integration_test.tscn` | Scene file for above |
| `tests/test_animation_poses.gd` | Headless bone-level validation (KF absolute check) |
| `tests/test_npc_loader.gd` | Prebaked NPC loader for fast test startup |
| `tests/data/test_npc_fargoth.scn` | Prebaked Fargoth NPC scene |

### Animation Data
| File | Purpose |
|------|---------|
| `assets/animations/mixamo/Idle.fbx` | Mixamo idle animation |
| `assets/animations/mixamo/Walking.fbx` | Mixamo walk animation |
| `assets/animations/mixamo/Jump.fbx` | Mixamo jump animation |
| `assets/animations/mixamo/Jumping Up.fbx` | Mixamo jump-up animation |
| `assets/animations/mixamo/Jumping Down.fbx` | Mixamo jump-down animation |

### Documentation
| File | Purpose |
|------|---------|
| `docs/ANIMATION_CLEANUP_PLAN.md` | 6-session cleanup plan (this is Session 2) |
| `docs/ANIMATION_SYSTEM.md` | Architecture reference |
| `.claude/CLAUDE.md` | Project-wide instructions and gotchas |

---

## Critical Gotchas for the Next Agent

1. **KF track paths MUST be `".:BoneName"`** — without the `.:` prefix, `NodePath.get_subname_count()` returns 0 and animation remapping silently skips the track. This was a previous root cause bug.

2. **AnimationTree MUST be child of Skeleton3D** — default `root_node = ".."` resolves to parent. If parent isn't Skeleton3D, bone tracks silently fail.

3. **Don't convert KF values to rest-relative** — this collapses the skeleton. Use raw absolute KF values directly as Godot bone poses.

4. **`Log` autoload, not `Logger`** — Godot 4.6 has a built-in `Logger` class that conflicts.

5. **Headless tests can't reference autoloads at compile time** — use `load()` not `preload()`, defer work to `_process()` not `_init()`.

6. **The Godot path is:** `D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe`

---

## What to Do Next

1. **Fix Bug 5** — the Hips position formula in `_retarget_animation_absolute()` (5-line change)
2. **Re-run autotest** — all S1-S8 should PASS
3. **Visual verification** — run scene without --autotest, toggle Mixamo with [M], confirm character looks correct
4. **Consider:** After Mixamo works, Session 3-6 from `ANIMATION_CLEANUP_PLAN.md` are cleanup tasks (dead code deletion, test consolidation, doc cleanup) — independent of animation fixes
