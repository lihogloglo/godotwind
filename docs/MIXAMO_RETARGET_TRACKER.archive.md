# Mixamo Retarget Tracker

## Problem Statement
Mixamo FBX animations retargeted onto the MW (Morrowind) skeleton look broken.
- **Idle looks OK** — character stands correctly
- **Movement animations are wrong** — e.g. walking shows legs going sideways, not front-to-back
- Tested in `animation_integration_test.tscn` (click Mixamo list item to play)

## Pipeline Overview

### Data flow (Mixamo → MW skeleton)
```
1. FBX file loaded via AnimationLoader.load_from_directory_with_rest()
   └─ Instantiates PackedScene, finds Skeleton3D + AnimationPlayer
   └─ Builds bone remap: mixamorig1_LeftUpLeg → LeftUpperLeg (profile names)
   └─ Extracts skeleton geometric rest: skeleton.get_bone_rest() per bone
   └─ Fixes track paths to ".:ProfileBoneName" format
   └─ Returns { library: AnimationLibrary, source_rest: Dictionary }

2. extract_anim_rest_poses(library, source_rest)
   └─ Finds idle animation, reads frame 0 rotation per bone
   └─ Returns source_rest copy with rotations replaced by idle frame 0 values
   └─ Reason: FBX importer applies pre-rotations that don't match anim data

3. get_skeleton_rest_poses(mw_skeleton)
   └─ MW skeleton already has profile bone names (renamed from Bip01)
   └─ Returns { bone_name: Transform3D } from skeleton.get_bone_rest()

4. retarget_library(raw_lib, anim_rest, mw_rest, true, geometric_rest)
   └─ target_uses_absolute=true → calls _retarget_animation_absolute()
   └─ source_geometric_rest not empty → computes CoB via _compute_global_change_of_basis()
   └─ Per keyframe: corrected = left[bone] * anim * right[bone]
```

### Key parameters at retarget time
| Parameter | Value | Description |
|-----------|-------|-------------|
| source_rest | anim_rest (idle frame 0) | Used as `idle_s` in CoB |
| target_rest | MW skeleton rest | Used as `R_t` in CoB |
| source_geometric_rest | FBX skeleton.get_bone_rest() | Used as `R_s_geom` in CoB |
| target_uses_absolute | true | MW uses raw KF values as pose |

### MW animation model
- Godot computes: `local = rest * pose`
- MW KF files store **absolute** bone-local rotations as `pose`
- At idle: `pose ≈ rest`, so `local ≈ rest²`
- This is the "double rest" quirk — the skeleton works despite rest² because the KF values encode the correct absolute orientations

### Mixamo animation model
- FBX animations also store absolute bone-local rotations
- Godot's FBX importer may apply pre-rotations to skeleton bind pose
- `skeleton.get_bone_rest()` (geometric rest) ≠ animation idle frame 0 values
- The ~2-5° per-bone mismatch compounds down the chain
- Fix: `extract_anim_rest_poses()` uses idle frame 0 as source rest

## CoB Retarget Formula

### Per-bone computation
```
R_s_geom = source_geometric_rest[bone].rotation   # FBX geometric rest
idle_s   = source_rest[bone].rotation              # Anim rest (idle frame 0)
R_t      = target_rest[bone].rotation              # MW rest

F_s = G_s_parent * R_s_geom    # Source pose-space frame
F_t = G_t_parent * R_t         # Target pose-space frame
C   = F_t⁻¹ * F_s              # Change of basis
```

### Current formula (WRONG — in code at animation_loader.gd:546-547)
```
left  = R_t * C * idle_s⁻¹
right = C⁻¹
→ corrected = R_t * C * idle_s⁻¹ * anim * C⁻¹
```

### Correct formula (derived below)
```
left  = C
right = idle_s⁻¹ * C⁻¹ * R_t
→ corrected = C * anim * idle_s⁻¹ * C⁻¹ * R_t
```

### Idle verification
Both formulas produce R_t when anim = idle_s:
```
Current:  R_t * C * idle_s⁻¹ * idle_s * C⁻¹ = R_t  ✓
Correct:  C * idle_s * idle_s⁻¹ * C⁻¹ * R_t = R_t   ✓
```
This is why idle always looks correct regardless of the bug.

### Motion delta
For anim = idle_s * delta:
```
Current:  R_t * C * delta * C⁻¹
  → conjugates delta by C directly — but delta is in the idle-bone frame, not pose-space
Correct:  C * idle_s * delta * idle_s⁻¹ * C⁻¹ * R_t
  → maps delta from idle-frame to pose-space (idle_s * delta * idle_s⁻¹),
    THEN conjugates by C, THEN appends R_t
```

### Derivation (world-space delta preservation)

Goal: the world-space rotation delta between idle and posed bone must match.

```
Source at idle:  W_s_idle = F_s * idle_s       (pose-space frame × idle value)
Source at pose:  W_s_pose = F_s * anim         (pose-space frame × anim value)
World delta:     Δ = W_s_pose * W_s_idle⁻¹

Target must match:
  W_t_pose * W_t_idle⁻¹ = Δ
  where W_t_idle = F_t * R_t   (MW idle ≈ rest)
        W_t_pose = F_t * corrected

Solving:
  F_t * corrected * (F_t * R_t)⁻¹ = F_s * anim * (F_s * idle_s)⁻¹
  F_t * corrected * R_t⁻¹ * F_t⁻¹ = F_s * anim * idle_s⁻¹ * F_s⁻¹
  corrected = F_t⁻¹ * F_s * anim * idle_s⁻¹ * F_s⁻¹ * F_t * R_t
            = C * anim * idle_s⁻¹ * C⁻¹ * R_t      (where C = F_t⁻¹ * F_s)

Therefore: left = C, right = idle_s⁻¹ * C⁻¹ * R_t
```

### Why the wrong formula causes sideways legs

The bone-local delta `delta = idle_s⁻¹ * anim` is expressed in the bone's
idle frame. To conjugate it correctly, it must first be mapped from the
idle-bone frame to the pose-space frame via `idle_s * delta * idle_s⁻¹`.

The current formula skips this step — it conjugates `delta` by `C` directly.
`C` maps between pose-space frames, but `delta` lives in the idle-bone frame,
which is offset from pose-space by `idle_s`.

For bones like LeftUpperLeg where the Hips parent has a ~90° rest rotation
difference between Mixamo and MW, the missing frame mapping causes
flexion/extension (forward/back leg swing) to be mapped onto a sideways axis.

### Parent chain accumulation (CORRECT — after 2026-02-14 fix)
```
src_global[bone] = F_s * idle_s    # rest_geom * idle per parent
tgt_global[bone] = F_t * R_t      # rest * rest per parent (MW idle ≈ rest)
```

### Parent chain accumulation (PREVIOUS — before 2026-02-14)
```
src_global[bone] = F_s             # rest_geom only, no idle
tgt_global[bone] = F_t             # rest only, no idle
```

## What Was Tried

### Attempt 1: Idle-inclusive parent chain (2026-02-14) — NECESSARY BUT INSUFFICIENT
**Hypothesis:** The rest-only chain was missing one factor of idle per ancestor,
causing ~90° axis mapping errors for leg bones (MW Hips has significant rest rotation).

**Change:** `src_global = F_s * idle_s`, `tgt_global = F_t * R_t`

**Result:** Did not fix the sideways legs by itself.

**Analysis:** The chain fix was a CORRECT and NECESSARY prerequisite — the parent
chain WAS wrong. But the actual root cause is the left/right multiplier formula
(Attempt 2), which was still wrong even after fixing the chain.

### Attempt 2: Left/right multiplier formula fix (2026-02-14) — APPLIED, DID NOT FIX

**Hypothesis:** The left/right multipliers conjugate the bone-local delta in the wrong
frame (pose-space vs idle-bone frame).

**Change:** Replace `animation_loader.gd` lines 546-547:
```gdscript
# OLD:
bone_left[bone_name] = R_t * C * idle_s.inverse()
bone_right[bone_name] = C.inverse()
# NEW:
bone_left[bone_name] = C
bone_right[bone_name] = idle_s.inverse() * C.inverse() * R_t
```

**Result:** Did NOT fix the sideways legs. The formula derivation was correct
(world-space delta preservation), but the root cause was elsewhere — the C values
being fed into the formula were wrong because of the hierarchy mismatch (Attempt 3).

### Attempt 3: Actual skeleton hierarchy for CoB (2026-02-14) — THE REAL ROOT CAUSE

**Root cause:** `_compute_global_change_of_basis()` used the SkeletonProfileHumanoid
hierarchy to compute the pose-space frame F_t for each bone. But the profile hierarchy
doesn't include intermediate bones like "Bip01 Pelvis" that exist in the actual MW
skeleton between "Hips" (Bip01) and child bones like "LeftUpperLeg" (Bip01 L Thigh).

The actual MW skeleton hierarchy (after profile renaming):
```
Hips (was Bip01)
└── Bip01 Pelvis  ← NOT in profile, but contributes rest rotation to chain!
    ├── Spine (was Bip01 Spine)
    ├── LeftUpperLeg (was Bip01 L Thigh)
    └── RightUpperLeg (was Bip01 R Thigh)
```

The profile says Hips→LeftUpperLeg (direct parent). But Bip01 Pelvis sits between them.
The CoB computed F_t(LeftUpperLeg) = G_t(Hips) * R_t(LeftUpperLeg), missing Bip01 Pelvis's
rest rotation entirely. This wrong F_t produces a wrong C, which maps rotation axes
incorrectly for ALL bones below Bip01 Pelvis (legs, spine, arms, head).

Note: Attempt 2 was ALSO necessary — the formula fix is correct. But it couldn't
fix the problem because C itself was wrong due to the hierarchy mismatch.

**Fix:** New function `compute_skeleton_global_idles(skeleton, idle_overrides)` walks
the ACTUAL skeleton hierarchy (including non-profile bones) to compute the true global
idle orientation at each bone. These are passed to `_compute_global_change_of_basis()`
which uses them for F_t instead of building the chain from the profile.

```gdscript
F_t(bone) = global_idle_actual(bone) * R_t(bone)⁻¹
```

The Mixamo side is unaffected (Mixamo has no intermediate non-profile bones, so the
profile hierarchy is correct for the source).

**Status:** Implemented. Hierarchy diagnostic confirmed 120.8° F_t correction for
LeftUpperLeg. Visually getting CLOSER with CoB but legs still not matching reference.

### Attempt 4: Side-by-side visual comparison (2026-02-15) — DIAGNOSTIC TOOL

**Finding:** Mixamo FBX reference character faces OPPOSITE direction from MW character.
Both skeleton root transforms are identity (no root rotation on either side). The 180°
facing difference comes entirely from bone data: MW Hips `local = rest² ≈ (0°, 180°, 0°)`
vs Mixamo Hips `local ≈ identity`.

**Transform chain diagnostic:**
```
MW:     root=(0,0,0), skeleton=(0,0,0), Hips rest=(0,90,0), Hips WORLD forward=(-1,0,0)
Mixamo: root=(0,0,0), skeleton=(0,0,0), Hips rest≈(0,0,0), faces opposite direction
```

**Retarget delta analysis (walk, LeftUpperLeg):**
```
Mixamo delta from idle: X≈-16° (forward leg swing)
MW retarget delta from rest: Y≈+17° (sideways swing)
→ Forward/back swing maps to wrong axis — 90° rotation error in CoB
```

**Tools added to `animation_integration_test.gd`:**
- Mixamo reference wireframe (cyan, 65 bones) — rotated 180° Y to face same direction
- MW skeleton wireframe (orange, 33 bones) — overlaid on NPC mesh
- CoB toggle checkbox — switches between CoB and simple swap (`R_t * idle_s⁻¹ * anim`)
- Collapsible UI panel (< / > toggle button)
- Transform chain diagnostic (`_dump_transform_chain()`)

**Visual result with CoB:** Getting closer to matching the Mixamo reference but still off.
CoB produces better results than simple swap. The motion direction is improving but not
yet matching the reference skeleton's bone trajectories.

**Status:** Diagnostic infrastructure in place. Next step: see Attempt 5.

### Attempt 5: Live retarget + FK-chain baked retarget (2026-02-15) — NEW APPROACH

**Analysis:** The per-bone CoB formula `corrected = C * anim * idle_s⁻¹ * C⁻¹ * R_t`
is mathematically proven to preserve WORLD-SPACE rotation deltas. However:
1. The two skeletons face opposite directions (MW ~180° Y from Mixamo)
2. Per-bone CoB uses IDLE-TIME parent globals; during motion, parents animate and the
   actual pose-space frame changes — this is an inherent approximation
3. The mix of R_s_geom (FBX geometric rest) and idle_s (anim frame 0 rest) for F_s
   may introduce errors since they're in slightly different coordinate spaces

**New approach 1: Live retarget** (runtime, no baking)
- Play animation on Mixamo reference skeleton
- Each frame, read Mixamo bone global orientations
- For each MW bone: `correction = tgt_idle_global * src_idle_global⁻¹`
  then `tgt_desired = correction * src_current_global`
- Derive pose from desired global using CURRENT parent global (not idle)
- This uses actual runtime FK chain → no idle-time approximation
- Toggle: "Live retarget" checkbox in test scene

**New approach 2: FK-chain baked retarget** (offline, per-keyframe FK)
- At each keyframe time, compute full source FK chain (global orientations)
- Process target bones root-to-leaf, using parent's CORRECTED value for children
- Same correction formula as live mode: `correction * src_global`
- Pre-populates intermediate non-profile bone globals (Bip01 Pelvis etc.)
- Toggle: "FK chain" checkbox in test scene
- Function: `AnimationLoader.retarget_library_fk_chain()`

**Why this should work:** Both approaches use a per-bone correction that maps source
absolute orientation to target absolute orientation. At idle, correction maps
src_idle → tgt_idle. At motion, the same correction maps src_current → tgt_desired.
The FK chain approach propagates corrected parent values to children, avoiding the
idle-time parent approximation.

**Status:** Implemented. 3 retarget modes available in test scene:
- CoB retarget (existing per-bone change of basis)
- FK chain (new baked FK-chain retarget)
- Live retarget (new runtime per-frame retarget)

### Attempt 6: Rest chain computation bug (2026-02-15) — ROOT CAUSE FOUND!

**New diagnostic data (2026-02-15):** Runtime per-bone orientation comparison shows:
```
Average error: 103-107° across 10 bones
Worst offenders:
  - LeftShoulder: 150-176° error
  - RightHand: 132-141° error
  - RightFoot: 114-121° error
  - Hips: 95° error (src Y=-3°, tgt Y=+92° → 90° Y-axis offset!)
  - Spine: 97° error (src Z=-2°, tgt Z=+95° → 90° Z-axis offset!)
```

**Root cause identified:** `compute_skeleton_global_idles()` was computing the global
IDLE orientation (with idle poses applied), not the global REST orientation (pose=identity).

The buggy code (line 300):
```gdscript
# WRONG: computes parent_global * rest * idle
result[bone_name] = parent_global * rest_rot * idle_rot
```

For MW where `idle ≈ rest`, this builds:
- Hips: `IDENTITY * Hips_rest * Hips_rest = Hips_rest²`
- Pelvis: `Hips_rest² * Pelvis_rest * Pelvis_rest = Hips_rest² * Pelvis_rest²`
- Spine: `Hips_rest² * Pelvis_rest² * Spine_rest * Spine_rest`

Then in CoB computation:
```gdscript
F_t = target_global_idles[bone_name] * R_t.inverse()
```

For Spine:
```
F_t = (Hips_rest² * Pelvis_rest² * Spine_rest²) * Spine_rest⁻¹
    = Hips_rest² * Pelvis_rest² * Spine_rest
```

But it SHOULD be (just the rest chain):
```
F_t = Hips_rest * Pelvis_rest * Spine_rest
```

**The extra squared rest factors in the parent chain cause 90° axis mapping errors!**

**Fix:** Changed line 300 to:
```gdscript
# Correct: computes parent_global * rest (pose = identity)
result[bone_name] = parent_global * rest_rot
```

And updated line 578 from:
```gdscript
F_t = target_global_idles[bone_name] * R_t.inverse()  # OLD
```
to:
```gdscript
F_t = target_global_idles[bone_name]  # NEW (already includes full rest chain)
```

Also updated the parent chain accumulation (lines 589-594) from idle-chain to rest-chain:
```gdscript
# OLD (wrong — mixed rest and idle):
src_global[bone_name] = F_s * idle_s
tgt_global[bone_name] = target_global_idles[bone_name] (or F_t * R_t)

# NEW (correct — pure rest chain):
src_global[bone_name] = F_s
tgt_global[bone_name] = F_t
```

**Status:** Fixed (2026-02-15). Ready to test in `animation_integration_test.tscn`.

**Expected result:** The 90° Hips Y-axis and Spine Z-axis offsets should disappear.
Average error should drop significantly. Legs should move forward/back instead of sideways.

## Known Facts

### Things that definitely work
- MW animations on MW skeleton: correct (raw KF values used directly)
- Mixamo idle on MW skeleton: correct (character stands in right pose)
- Bone name mapping: correct (Mixamo → profile ← MW both map correctly)
- Animation track format: correct (".:ProfileBoneName")
- Parent chain accumulation: correct (idle-inclusive, fixed 2026-02-14)

### Things that are definitely wrong
- Mixamo walk/run/jump on MW skeleton: legs go sideways
- The motion AXIS is wrong, not the magnitude — coordinate frame issue
- Left/right multiplier formula conjugates delta in wrong frame (idle-bone vs pose-space)

### Key architectural facts
1. Both Mixamo and MW animations store ABSOLUTE bone-local rotations (not deltas)
2. Godot computes `local = rest * pose` — pose is NOT relative to rest
3. MW idle KF values ≈ MW rest (so local ≈ rest² at idle)
4. Mixamo idle FBX values ≈ Mixamo geometric rest (approximately)
5. FBX pre-rotations may put geometric rest and anim values in different coord systems
6. The MW skeleton is Bip01 convention (3ds Max Biped) converted from Z-up to Y-up
7. The Mixamo skeleton is Y-up native (no coordinate conversion needed)

### Resolved Questions
1. **R_s_geom and idle_s coordinate system:** Both are in Godot's post-import space.
   FBX pre-rotations affect `get_bone_rest()` AND animation values consistently
   (Godot adjusts both during import). The ~2-5° mismatch is small and handled by
   `extract_anim_rest_poses()`. Not the root cause.

2. **Profile hierarchy vs skeleton hierarchy:** ~~Bip01 Pelvis has identity rest,
   so the chain wouldn't be affected~~ **WRONG — THIS WAS THE ROOT CAUSE.**
   Bip01 Pelvis sits between Hips and ALL descendant bones in the actual MW skeleton.
   Whether Bip01 Pelvis has identity rest or not, the profile hierarchy completely
   misses it, computing F_t from the wrong parent chain. See Attempt 3.

3. **Is CoB needed?** YES — the skeletons have fundamentally different rest
   orientations (MW Hips has ~90° Y offset vs Mixamo). Without CoB, the simple
   formula `R_t * idle_s⁻¹ * anim` can't remap bone-local axes. The CoB approach
   is correct in principle — the formula was just assembled wrong.

### MW skeleton hierarchy (confirmed 2026-02-15)
```
Hips (rest=(0,90,0))
└── Bip01 Pelvis (rest=(0,-90,88))  ← NOT in profile
    ├── Spine (rest=(-1.6,2.0,1.9))
    │   ├── LeftUpperLeg (rest=(6.0,-0.9,-179.5))  ← parent=Spine, NOT Hips!
    │   ├── RightUpperLeg (rest=(-9.6,-12.4,-175.3))
    │   └── Chest → UpperChest → Neck → Shoulders → Arms
    └── (no other direct children)
```
Note: LeftUpperLeg parent = Spine in actual skeleton, but profile says parent = Hips.
Both Bip01 Pelvis AND Spine are intermediate bones between Hips and UpperLeg.

### Remaining Questions
1. **Position delta axis mapping:** Root (Hips) position deltas are currently scaled
   but NOT rotated through C. This could cause sideways drift during walk locomotion.
   Should be checked after the rotation fix is applied.

2. **Fallback path quality:** When a bone has no `source_geometric_rest`, the code
   falls back to `left = tgt_rot * idle_src⁻¹, right = IDENTITY`. This is the simple
   baseline swap with no axis remapping. May be wrong for bones with different local axes.

3. **Source hierarchy check needed:** The Mixamo source side uses the profile hierarchy
   for parent chain computation. While Mixamo likely matches the profile, this has NOT
   been verified. If the Mixamo skeleton also has intermediate bones, the source F_s
   computation would also be wrong.

4. **90° axis rotation in retarget deltas:** Walk animation LeftUpperLeg shows forward
   swing (X-axis ~16°) mapping to sideways swing (Y-axis ~17°). The 90° axis error
   matches MW Hips rest (90° Y). Possible that C is leaking the Hips rotation into
   child bone axis mapping. Needs detailed C value inspection.

## Diagnostic Plan

### Step 1: Apply left/right multiplier fix
Change `animation_loader.gd` lines 546-547:
```gdscript
bone_left[bone_name] = C
bone_right[bone_name] = idle_s.inverse() * C.inverse() * R_t
```
Also update the docstring at line 493 to match the correct formula.
Run `animation_integration_test.tscn`, play walk animation.
**Expected:** legs swing forward/back instead of sideways.

### Step 2: Verify idle is unchanged
Play idle animation after the fix. Must still produce correct standing pose.
(Mathematically guaranteed: `C * idle_s * idle_s⁻¹ * C⁻¹ * R_t = R_t`)

### Step 3: Check all limbs
Test walk, run, jump animations. Check:
- Legs: forward/back swing (not sideways)
- Arms: correct swing direction
- Spine: forward lean during run (not sideways tilt)
Log the diagnostic dump and compare raw_delta vs ret_delta euler angles.

### Step 4: Root position axis mapping (if needed)
If character drifts sideways during walk, the root position delta also needs
rotation through C:
```gdscript
var delta := original_pos - src_rest.origin
if bone_name in cob_left:
    delta = cob_left[bone_name] * delta  # Rotate delta axes through CoB
result.position_track_insert_key(new_idx, time, tgt_rest.origin + delta * length_ratio)
```

### Step 5: Verify factory code path
After confirming the fix works in the test scene, verify the same
`retarget_library()` call in `character_factory_v2.gd:225` also produces
correct results (it uses the same code path, no changes needed).

## Proposed Fix

### Primary: animation_loader.gd lines 546-547

File: `src/core/animation/animation_loader.gd`
Function: `_compute_global_change_of_basis()` (line 497)

```gdscript
# OLD (wrong frame for conjugation):
bone_left[bone_name] = R_t * C * idle_s.inverse()
bone_right[bone_name] = C.inverse()

# NEW (correct: world-space delta preservation):
bone_left[bone_name] = C
bone_right[bone_name] = idle_s.inverse() * C.inverse() * R_t
```

Also update docstring at line 493:
```
##   corrected = C * anim * idle_s⁻¹ * C⁻¹ * R_t
```

### Secondary (if needed): position axis rotation

File: `src/core/animation/animation_loader.gd`
Function: `_retarget_animation_absolute()` lines 752-775

For root position deltas, rotate through CoB before scaling:
```gdscript
var delta := original_pos - src_rest.origin
if bone_name in cob_left:
    delta = cob_left[bone_name] * delta
result.position_track_insert_key(new_idx, time, tgt_rest.origin + delta * length_ratio)
```

NOTE: Only apply if Step 4 diagnostic reveals sideways drift.

## Relevant Files
| File | Role |
|------|------|
| `src/core/animation/animation_loader.gd` | Retarget logic, CoB computation |
| `src/core/animation/character_factory_v2.gd` | Mixamo preload, retarget call |
| `src/core/animation/retarget_setup.gd` | Bone remap, rename utilities |
| `src/core/animation/skeleton_profile_adapter.gd` | Bone name mappings (MW, Mixamo) |
| `src/tools/animation_integration_test.gd` | Test scene, diagnostic dump |
| `src/core/animation/ik_controller.gd` | IK (not involved in retarget) |

## Relevant Code Locations
- CoB computation: `animation_loader.gd:497` (`_compute_global_change_of_basis`)
- **CoB left/right bug: `animation_loader.gd:546-547`** (bone_left/bone_right assignment)
- CoB docstring: `animation_loader.gd:493` (formula comment)
- Absolute retarget: `animation_loader.gd:686` (`_retarget_animation_absolute`)
- Position handling: `animation_loader.gd:752-775` (root position delta)
- Mixamo load in test: `animation_integration_test.gd:399` (`_load_mixamo`)
- Mixamo preload in factory: `character_factory_v2.gd:199` (`preload_mixamo_animations`)
- Diagnostic dump: `animation_integration_test.gd:611` (`_dump_retarget_diagnostic`)
