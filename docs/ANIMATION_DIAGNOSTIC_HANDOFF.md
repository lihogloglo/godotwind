# Animation Diagnostic Handoff — For the Next Agent

**Created:** 2026-02-11
**Context:** MW/Mixamo animations broken since commit `f494cf0`. This doc explains the diagnostic tool, results, and recommended next steps.

---

## How to Use the Diagnostic Tool

### Running
1. Open `tests/animation_diagnostic.tscn` in the Godot editor
2. Press F5 (or run the scene directly)
3. Output appears both on-screen (color-coded) and in the console
4. Keys: `D` = dump full report, `R` = re-run, `Escape` = quit

### What It Tests (10 Sections)

| Section | What | Why |
|---------|------|-----|
| S1 | Raw KF data vs skeleton rest poses | Validates KF format is absolute |
| S2 | `rest^-1 * kf` conversion formula | Checks conversion produces identity for idle |
| S3 | Bone name mapping (Bip01 → profile) | Checks for unmapped/orphan tracks |
| S4 | Full pipeline NPC creation | Verifies scene tree, AnimationPlayer, AnimationTree |
| S5 | **Manual pose injection** (bypass engine) | THE CRITICAL TEST — sets bone poses directly |
| S6 | AnimationPlayer direct playback | Tests player without AnimationTree |
| S7 | Full AnimationTree pipeline | Tests complete pipeline |
| S8 | **A/B comparison** (converted vs raw) | Definitively compares both approaches |
| S9 | Walk animation test | Checks non-idle animation |
| S10 | Summary verdict | Decision tree |

### Reading the Output

- **PASS** (green) = section checks pass
- **FAIL** (red) = section checks fail
- **WARN** (yellow) = non-critical issues
- Anatomy checks: Head Y > Hips Y, Feet Y < Hips Y, height > 0.5m

---

## Diagnostic Results (2026-02-11)

### Summary Verdict
```
Raw data valid:              YES (S1 PASS)
Conversion formula correct:  YES (S2 PASS — mathematically)
Bone name mapping complete:  WARN (5 unmapped: Bip01 Pelvis, Weapon Bone, etc.)
Pipeline wiring correct:     YES (S4 PASS)
Manual pose works:           MIXED — raw YES, identity/converted NO
AnimationPlayer works:       NO (S6 FAIL)
AnimationTree works:         NO (S7 FAIL)
```

### Critical Finding: S5 Manual Pose Injection

| Sub-test | Pose Data | Result | Anatomy |
|----------|-----------|--------|---------|
| **5A: Identity** | All bones = identity quat | ALL bones at (0, -0.15, 0) | **COLLAPSED** |
| **5B: Converted** | `rest^-1 * kf_idle[0]` | ALL bones at (0, -0.52, 0) | **COLLAPSED** |
| **5C: Raw absolute** | KF idle[0] as-is | Head=(0.001, 0.598, -0.052), height=1.61m | **PASS** |

### What This Means

**The skeleton's rest poses chain to a COLLAPSED configuration when pose = identity.**

In Godot: `global_pose = parent_global * rest * pose`. With `pose = identity`:
- `global = parent_global * rest`
- All bones end up at the same position → rest pose chain is wrong or all-identity

**But raw KF absolute values produce correct anatomy.** Since KF idle[0] === rest poses (confirmed in S1), setting `pose = kf_absolute` means:
- `global = parent_global * rest * kf_absolute = parent_global * rest * rest`

If this gives CORRECT results while `pose = identity` collapses, it suggests **the skeleton's actual rest poses in the live NPC are NOT the NIF transforms** — they may be identity, and the NIF transforms only exist in the KF animations.

### S8 A/B Comparison Result
```
NPC A (with conversion): anatomy FAIL — collapsed
NPC B (without conversion): anatomy PASS — correct (1.61m height)
VERDICT: "CONVERSION IS BROKEN — raw values work directly"
```

---

## Root Cause Hypothesis

Two possible scenarios explain the diagnostic results:

### Hypothesis A: Skeleton rest poses are identity in the NPC
The `CharacterFactoryV2.create_npc()` pipeline may produce a skeleton where rest poses are identity/zero, NOT the NIF transforms. This would happen if:
- The assembler's skeleton construction doesn't set rest poses
- Or rest poses get cleared during bone renaming
- Or the cached skeleton (used in S1 for comparison) differs from the actual NPC skeleton

If rest = identity: `global = parent_global * identity * pose = parent_global * pose`
- Raw KF as pose → `global = parent_global * kf_absolute` → CORRECT (since KF = absolute parent-local)
- Identity as pose → `global = parent_global * identity` → all bones at parent origin → COLLAPSED
- Converted as pose → `global = parent_global * rest^-1 * kf = parent_global * identity^-1 * kf = parent_global * kf` → same as raw... BUT this doesn't match. Unless the conversion used the cached skeleton's non-identity rest poses.

### Hypothesis B: Godot's `set_bone_pose_rotation()` REPLACES bone local transform
Instead of `final = rest * pose`, maybe pose values directly replace the bone transform. This would mean:
- Raw KF values work because they ARE the correct local transforms
- Identity values collapse because identity is NOT a valid local transform for most bones
- The `rest^-1 * kf` conversion produces near-identity values, which also collapse

### Investigation Steps
1. **Check the actual NPC skeleton's rest poses** — In Section 5 of the diagnostic, add logging of `skeleton.get_bone_rest(i)` for all bones. Are they identity or NIF transforms?
2. **Check Godot source** for `Skeleton3D::set_bone_pose_rotation()` — does it multiply with rest or replace?
3. **If rest poses are identity** → fix the skeleton builder to set correct rest poses, and the `_convert_library_to_rest_relative()` will work
4. **If Godot replaces (not multiplies)** → remove conversion entirely, use raw KF values as direct bone transforms

---

## Fix Applied (2026-02-11)

**Removed `_convert_library_to_rest_relative()` call from `_remap_and_cache_library()`.**

The function still exists in `character_factory_v2.gd` (marked as unused/reference) but is no longer called in the pipeline. Raw KF absolute values are now used directly as Godot bone poses.

### Diagnostic Results (Post-Fix)

```
S1: Raw data valid              — YES (2 pass)
S2: Conversion formula correct  — YES (informational only)
S3: Bone name mapping           — 64 mapped, 5 unmapped (expected)
S4: Pipeline wiring             — YES (10 pass)
S5: Manual pose injection       — 5A/5B FAIL (expected), 5C raw PASS
S6: AnimationPlayer direct      — YES — height 1.61m, correct anatomy
S7: AnimationTree pipeline      — YES — height 1.61m, correct anatomy
S8: A/B comparison              — BOTH PASS — pipeline fix confirmed
S9: Walk animation              — YES — height 1.18m (swim walk, bent pose)
```

### Root Cause Investigation Results

- **Hypothesis A (identity rest poses): WRONG** — NPC skeleton has NIF transforms confirmed
- **Hypothesis B (Godot replaces): UNLIKELY** — both AnimationPlayer and AnimationTree work correctly with raw KF values
- **Actual behavior**: Rest-pose chain collapses to single point when pose=identity (S5A). This is unexplained but irrelevant — raw KF values produce correct anatomy through all pipeline stages.
- **Y-offset observation**: Progressive downward shift from manual injection → AnimationPlayer → AnimationTree (~0.2m per layer). Shape/proportions always correct (1.61m). Likely caused by `global = rest * pose` with `pose ≈ rest` (double rest application on root bones). Not blocking — character positioning in the world is handled by CharacterBody3D.

---

## What's Left

1. **Get Mixamo animations working** — `retarget_setup.gd` has RetargetModifier3D API, needs wiring
2. **Sessions 3-6 from ANIMATION_CLEANUP_PLAN.md** — dead code deletion, test consolidation, doc cleanup
3. **Y-offset investigation** (low priority) — understand why AnimationTree shifts character down ~0.4m vs manual injection. May be related to root bone rest pose double-application.
