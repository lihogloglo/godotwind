# Mixamo Animation Retargeting Debug — Handoff

## Problem
Mixamo FBX animations show **wrong limb directions** when retargeted onto Morrowind (MW) NPC skeletons. MW native KF animations work fine on the same skeleton.

## What We Know
- MW idle: works correctly (absolute KF rotations as Godot bone poses)
- Mixamo idle: "seems okay" but motion animations have wrong limb directions
- All diagnostics PASS (skeleton renamed, tracks remapped, AnimationTree active, 132 MW anims + 5 Mixamo anims loaded)
- Retarget formula: `corrected = tgt_rot * src_rot^-1 * original` (absolute-to-absolute)
- MW Hips rest has 90° Y rotation `(0,0.707,0,0.707)` — Z-up conversion. Mixamo Hips rest is identity.
- 32 of 65 Mixamo bones overlap with MW skeleton's 33 bones
- **Most likely root cause:** bone axis/roll convention mismatch between Mixamo and MW skeletons. The retarget formula handles rotation value differences but NOT different local axis orientations.

## Test Scene
`src/tools/animation_integration_test.tscn` — run with Godot at `D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe`

**Controls:**
- `M` — Toggle Mixamo/MW animations
- `N` — Toggle raw mode (Mixamo WITHOUT retargeting, for A/B comparison)
- `B` — Dump bone axis comparison (Mixamo vs MW, flags >30° mismatches)
- `I` — Toggle IK on/off
- `W` — Toggle wander (walk)
- `D` — Debug dump to console
- `Tab` — Browse animations
- `1/2/3` — Switch NPCs

## Debugging Steps (in progress)
1. ~~Visual baseline + IK elimination~~ DONE — idle OK, IK not the issue
2. **Run bone axis comparison** (`B` key) — check if axes differ >30° per bone
3. **A/B test** — press `N` then `M` for raw Mixamo vs retargeted Mixamo
4. **Apply fix** based on findings

## Key Files
- `src/tools/animation_integration_test.gd` — test scene (~1150 lines)
- `src/core/animation/animation_loader.gd` — retarget formula in `_retarget_animation_absolute()` (line ~590)
- `src/core/animation/retarget_setup.gd` — has RetargetModifier3D infrastructure (unused for Mixamo currently)
- `src/core/animation/animation_manager.gd` — state machine setup
- `src/core/animation/character_factory_v2.gd` — NPC creation pipeline

## Docs to Read
- `.claude/CLAUDE.md` — project overview, anti-patterns, gotchas
- `docs/ANIMATION_SYSTEM.md` — animation retargeting reference
- MEMORY.md sections: "Mixamo Retarget Quality Fix", "Animation Playback Bug", "Body Part Mirroring Fix"

## Potential Fixes (ranked)
1. **Axis-corrected conjugation** — compute per-bone axis correction quat from rest basis difference, apply in retarget formula (modify `_retarget_animation_absolute()`)
2. **Godot RetargetModifier3D** — use existing infrastructure in `retarget_setup.gd` for runtime retargeting instead of offline formula
3. **Global-space retargeting** — decompose to global rotations, transfer motion delta, reconstruct local

## Always Ask User for Visual Confirmation
After ANY change, relaunch the test scene and ask the user to confirm what they see.
