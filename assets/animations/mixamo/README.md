# Mixamo Animations for NextGen Characters

This folder contains Mixamo animations for the NextGen character system.

## How to Download Animations from Mixamo

1. Go to [Mixamo.com](https://www.mixamo.com/) and sign in with an Adobe account (free)

2. For each animation you want:
   - Search for the animation (e.g., "Idle", "Walking", "Running")
   - Click on the animation to preview it
   - Click "Download" with these settings:
     - **Format**: FBX for Unity (.fbx) or GLB
     - **Skin**: Without Skin (we only need the skeleton animation)
     - **Frames per Second**: 30
     - **Keyframe Reduction**: None (or light compression)

3. Place the downloaded files in this folder

4. Rename files to match expected names (or the loader will auto-detect):
   - `idle.glb` - Standing idle animation
   - `walking.glb` - Walking forward animation
   - `running.glb` - Running forward animation
   - `jump.glb` - Jump animation
   - `fall.glb` - Falling/in-air animation

## Recommended Animations

### Basic Locomotion
- **Idle** - "Breathing Idle" or "Standing Idle"
- **Walking** - "Walking"
- **Running** - "Running" or "Jogging"
- **Jump** - "Jump"
- **Fall** - "Falling Idle"
- **Land** - "Landing"

### Combat (Optional)
- **Attack** - "Sword Slash" or "Punch"
- **Block** - "Blocking"
- **Hit** - "Hit Reaction"
- **Death** - "Dying"

### Social (Optional)
- **Wave** - "Waving"
- **Bow** - "Bow"
- **Sit** - "Sitting"

## File Format Notes

- GLB format is preferred (single file, smaller size)
- FBX also works but may require .import file regeneration
- Animations should use the standard Mixamo skeleton (mixamorig_)

## Testing

After adding animations, reload the Asset Viewer and select an NPC.
The Animations tab will show all loaded animations.
