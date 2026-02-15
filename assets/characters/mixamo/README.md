# Mixamo Characters for Dual Character System

This folder contains Mixamo character FBX files for the **Mixamo Character Pipeline** (Phase 2 of Dual Character System).

## Current Files

- ✅ `Neck Stretching.fbx` - Idle animation (in-place)
- ✅ `Walking.fbx` - Walk cycle (with root motion)
- ✅ `Sneaking Forward.fbx` - Sneak animation (with root motion)
- ✅ `Sprinting Forward Roll.fbx` - Roll action (with root motion)

All files include character mesh (With Skin) - 34MB each.

## Testing

**Test scene:** `src/tools/mixamo_character_test.tscn`

1. Open the test scene in Godot
2. Press F6 to run the scene
3. Use these controls:
   - **1-4**: Switch between animations
   - **R**: Toggle root motion ON/OFF
   - **SPACE**: Reset character to origin
   - **B**: Print bone info to console

## Expected Results

✅ Character loads from FBX
✅ Skeleton extracted (should see ~65+ bones starting with "mixamorig:")
✅ Mesh instance visible
✅ Animations play smoothly
✅ Root motion moves character forward (when enabled)
✅ Animation transitions work

## Root Motion Details

Mixamo uses **"mixamorig:Hips"** as the root bone for root motion.

- **Idle** (Neck Stretching): No root motion, stays in place ✓
- **Walking**: Moves forward at walk speed ✓
- **Sneaking**: Slower forward movement ✓
- **Roll**: Fast forward + rotation ✓

Toggle root motion OFF to see animations play in-place (character won't move).

## Download More Characters/Animations

1. Go to [Mixamo.com](https://www.mixamo.com/)
2. Select a character OR animation
3. Download settings:
   - **Format**: FBX for Unity (.fbx)
   - **Skin**: With Skin (for base character) or Without Skin (for additional animations)
   - **Frames per Second**: 30
   - **In Place**: Unchecked (allow root motion)
   - **Keyframe Reduction**: None

4. Place files in this folder
5. Update `mixamo_character_test.gd` to include new files

## Recommended Additional Downloads

### Locomotion
- **Running** - Fast movement
- **Jogging** - Medium speed
- **Walking Backwards** - Reverse movement
- **Strafing Left/Right** - Side movement

### Actions
- **Jump** - Vertical movement
- **Dodge Roll** - Evasion
- **Slide** - Low movement
- **Crouch Walk** - Stealth

### Combat (Optional)
- **Sword Slash** - Attack
- **Block** - Defense
- **Hit Reaction** - Damage feedback

## Technical Notes

- All Mixamo FBX files use the same skeleton structure (mixamorig_)
- Character can be any Mixamo character - animations are skeleton-compatible
- File size: ~34MB with mesh, ~1MB without
- Bone count: ~65 bones (standard Mixamo rig)
- Root motion is extracted from Hips bone translation

## Integration with World

Once validated, Mixamo characters can be spawned in `world_explorer.tscn` alongside Morrowind characters using the `CharacterTypes` system.

See: `docs/DUAL_CHARACTER_SYSTEM.md` for architecture details.
