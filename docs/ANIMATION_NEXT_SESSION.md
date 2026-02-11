# Animation — Next Session Handoff

## What Was Done (2026-02-11)

Removed `_convert_library_to_rest_relative()` call from the animation pipeline. MW animations now play correctly — 1.61m humanoid, correct proportions, all diagnostic sections pass (S6/S7/S8/S9).

**Changed files:**
- `src/core/animation/character_factory_v2.gd` — removed conversion call in `_remap_and_cache_library()` (line ~829). The conversion function is kept but marked unused.
- `tests/animation_diagnostic.gd` — added rest-pose dump (S5.0), cache-clear on startup, relative anatomy check, updated S8 labels
- `docs/ANIMATION_DIAGNOSTIC_HANDOFF.md` — updated with fix results

## Known Issue: Y-Offset

The character is shifted ~0.4m downward when using AnimationTree vs manual pose injection. Proportions are always correct (1.61m). This is because Godot computes `bone_local = rest * pose` and our raw KF values already include the rest transform (KF ≈ rest for idle), causing double-application on root bones. The CharacterBody3D world positioning should compensate.

## Visual Verification

Open `tests/animation_diagnostic.tscn` and press F5. You should see Fargoth standing with correct proportions. Press D for full report dump.

For world integration: open `src/tools/world_explorer.tscn` and check NPCs in the streaming world.

## What's Next

1. **Visual check** — verify NPCs look correct in world_explorer
2. **Y-offset fix** — either zero out root bone (Bip01) rest position, or add a Y compensation offset on the character root
3. **Mixamo animations** — wire RetargetModifier3D in `retarget_setup.gd`
4. **Cleanup** — sessions 3-6 from `docs/ANIMATION_CLEANUP_PLAN.md` (dead code, test consolidation)
