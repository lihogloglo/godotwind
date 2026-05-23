---
name: "Godot Animation System"
description: "Comprehensive Godot 4.6 animation reference: IK (TwoBoneIK3D, FABRIK, LookAtModifier3D), root motion, animation blending, foot contact systems, and industry best practices. Use when implementing or debugging character animation, IK, root motion extraction, animation state machines, or locomotion systems."
---

# Godot 4.6 Animation System — Industry Best Practices

## Quick Reference: When to Use This Skill

- Implementing or debugging IK (foot, hand, look-at)
- Setting up AnimationTree blend trees or state machines
- Extracting or applying root motion
- Building foot contact / terrain adaptation systems
- Debugging animation timing, looping, or bone pose issues
- Converting external animation formats (KF, FBX, GLB) to Godot

---

## 1. Godot 4.6 Animation Pipeline Architecture

### Processing Order (Critical for Debugging)

```
Frame lifecycle:
1. _physics_process()     — game logic, velocity, input
2. _process()             — AnimationTree evaluates (default: IDLE mode)
3. SkeletonModifier3D     — IK solvers run (TwoBoneIK3D, FABRIK, LookAt)
4. Render                 — final bone poses sent to GPU
```

**Key implication:** Bone poses set in `_physics_process()` are overwritten by AnimationTree in `_process()`. To modify bones AFTER animation, use SkeletonModifier3D or the `modification_processed` signal.

### AnimationTree Process Modes

```gdscript
# Default — evaluates during _process() (render rate)
animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE

# Physics — evaluates during _physics_process() (physics rate)
animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
```

**Use IDLE** for visual smoothness (interpolates at render framerate).
**Use PHYSICS** only when animation must be frame-synchronized with physics (root motion driving CharacterBody3D).

---

## 2. Inverse Kinematics (IK)

### 2.1 TwoBoneIK3D (Godot 4.6) — Primary IK Solver

Two-bone analytical solver for limbs (arms, legs). Uses settings-indexed API.

```gdscript
var ik := TwoBoneIK3D.new()
ik.name = "LeftFootIK"

# Settings-indexed API — MUST set setting count first
ik.set_setting_count(1)
ik.set_root_bone_name(0, "LeftUpperLeg")
ik.set_middle_bone_name(0, "LeftLowerLeg")
ik.set_end_bone_name(0, "LeftFoot")

# Target — REQUIRED (solver silently skips without it)
ik.set_target_node(0, target_marker.get_path())

# Pole — REQUIRED (solver silently skips without it!)
ik.set_pole_node(0, pole_marker.get_path())

# Directions
ik.set_end_bone_direction(0, SkeletonModifier3D.BONE_DIRECTION_FROM_PARENT)
ik.set_pole_direction(0, SkeletonModifier3D.SECONDARY_DIRECTION_MINUS_Z)

# Add as child of Skeleton3D (NOT the scene root)
skeleton.add_child(ik)
ik.active = true  # Enable/disable — no start()/stop()
```

**Critical gotchas:**
- Both `target_node` and `pole_node` are REQUIRED — solver silently does nothing without them
- Must be a child of Skeleton3D
- No `start()`/`stop()` — uses `active = bool`
- `is_valid()`, `process_modification()`, `get_configuration_warnings()` are NOT exposed to GDScript
- Bone pose reading via `get_bone_pose_rotation()` in `_process()` returns PRE-modifier values. IK solution is only visible during `modification_processed` signal and to the renderer

**Pole positions (industry standard):**
- Knees: forward from foot (Z+) — prevents knees bending backward
- Elbows: backward/down from hand — natural arm bend direction

### 2.2 LookAtModifier3D (Godot 4.6) — Head/Eye Tracking

```gdscript
var look_at := LookAtModifier3D.new()
look_at.bone_name = "Head"
look_at.target_node = target.get_path()
look_at.blend_weight = 1.0  # 0.0-1.0 for smooth blend

# Angle limits prevent unnatural head rotation
look_at.angle_limit_x = deg_to_rad(60.0)  # vertical
look_at.angle_limit_y = deg_to_rad(80.0)  # horizontal

skeleton.add_child(look_at)
```

**Best practice:** Blend weight should lerp toward 0 when target is behind the character or beyond angle limits — prevents head snapping.

### 2.3 Full IK Modifier Hierarchy (Godot 4.6)

```
IKModifier3D (base)
  +-- TwoBoneIK3D           (deterministic, 2-bone chains — limbs)
  +-- ChainIK3D             (base for multi-bone)
       +-- SplineIK3D       (deterministic, spline-based — tails, tentacles)
       +-- IterateIK3D      (iterative base)
            +-- FABRIK3D     (Forward And Backward Reaching IK)
            +-- CCDIK3D      (Cyclic Coordinate Descent)
            +-- JacobianIK3D (Jacobian-based)
```

All inherit from `SkeletonModifier3D` (introduced 4.4).

| Solver | Deterministic | Best For |
|--------|--------------|----------|
| TwoBoneIK3D | Always | Limbs (arms, legs) — fast, stable |
| SplineIK3D | Always | Tails, tentacles, spines |
| FABRIK3D | Configurable | Multi-joint chains, reaching |
| CCDIK3D | Configurable | Multi-joint with constraints |
| JacobianIK3D | Configurable | Complex multi-target setups |

**Deterministic vs non-deterministic:** Deterministic solvers produce the same result regardless of previous frame state — ideal for networked games (only sync targets). Non-deterministic solvers can carry previous frame state for smoother convergence. Use `LimitAngularVelocityModifier3D` to smooth deterministic solvers.

### 2.4 SkeletonModifier3D — Base Class

**Processing pipeline:**
1. `AnimationMixer` applies animations (via `mixer_applied` signal)
2. `Skeleton3D` update process executes
3. `SkeletonModifier3D` instances run **in child list order** (top-to-bottom)
4. Pose is applied to skin
5. Original pose is restored for next frame

**Key properties:**
- `influence` (float 0-1): Engine handles interpolation automatically. Implementors apply at 100% inside `_process_modification()`.
- `modifier_callback_mode_process`: Controls `_process()` vs `_physics_process()` timing
- `active` (bool): Enable/disable

**Recommended child order on Skeleton3D:**
1. RetargetModifier3D (if used)
2. AnimationTree / AnimationPlayer
3. Foot IK (TwoBoneIK3D x2)
4. Look-at (LookAtModifier3D)
5. Hand IK (TwoBoneIK3D x2)
6. Constraints (LimitAngularVelocityModifier3D, BoneConstraint3D)

**Signals:**
- `Skeleton3D.modification_processed` — after ALL modifiers run (safe to read final poses)
- `Skeleton3D.skeleton_updated` — when final pose applies to skin

```gdscript
skeleton.modification_processed.connect(_on_all_ik_done)

func _on_all_ik_done() -> void:
    # Safe to read bone poses here — IK has been applied
    var foot_pos := skeleton.get_bone_global_pose(foot_idx).origin
```

**Custom modifier pattern:**
```gdscript
@tool
class_name CustomModifier extends SkeletonModifier3D

@export_enum(" ") var bone: String

func _process_modification() -> void:
    var skel := get_skeleton()
    if not skel:
        return
    var bone_idx := skel.find_bone(bone)
    var pose := skel.get_bone_global_pose(bone_idx)
    # Modify pose, then:
    skel.set_bone_global_pose(bone_idx, modified_pose)
```

### 2.5 Other Useful Modifiers (4.4-4.6)

- `SpringBoneSimulator3D` — Physics-based secondary motion (hair, cloth, ears)
- `BoneTwistDisperser3D` — Twist distribution across bone chain
- `BoneConstraint3D` — Accepts both bone references AND Node3D targets (4.6)
- `ConvertTransformModifier3D` — Transform space conversions
- `LimitAngularVelocityModifier3D` — Smooths rapid IK changes

### 2.6 SkeletonIK3D (DEPRECATED)

`SkeletonIK3D` is deprecated since 4.4. Migrate to TwoBoneIK3D or FABRIK3D. Still exists in 4.6 for compatibility but receives no new features.

---

## 3. Root Motion

### 3.1 Godot 4.x Root Motion System

```gdscript
# Set which bone track to extract root motion from
animation_tree.root_motion_track = NodePath(".:Hips")

# Each frame, read the extracted delta
func _physics_process(delta: float) -> void:
    var root_pos := animation_tree.get_root_motion_position()
    var root_rot := animation_tree.get_root_motion_rotation()

    # Apply to CharacterBody3D
    velocity = (global_transform.basis * root_pos) / delta
    # Rotation
    global_transform.basis *= Basis(root_rot)
    move_and_slide()
```

**How it works:**
- Setting `root_motion_track` tells AnimationTree to EXTRACT position/rotation from that bone track
- The bone's animation is NOT applied to the skeleton — it's available via `get_root_motion_position()` etc.
- Game code reads the delta each frame and applies it as CharacterBody3D velocity
- Other bones animate normally

**When to use root motion:**
- Animations authored with locomotion baked in (Morrowind KF, mocap data)
- Precise foot placement matters (combat, climbing)
- Animation-driven movement (cutscenes, root motion attacks)

**When NOT to use root motion:**
- Simple in-place animations (standard Mixamo/Quaternius)
- Movement speed must be independent of animation (most action games)
- Blending between animations with different root motion speeds

### 3.2 Root Motion with Morrowind KF Animations

MW animations use absolute bone transforms. The "Bip01 NonAccum" bone is where the engine strips accumulated root motion.

**MW bone hierarchy:** `Bip01 → Bip01 NonAccum → Bip01 Pelvis → ...`
- **Bip01**: Accumulates horizontal movement (forward/backward, strafe)
- **Bip01 NonAccum**: Vertical movement (jump arcs, flying). Resets each cycle.
- **Bip01 Pelvis** (→ Hips): Static pelvis height, not locomotion

**Strategy (3 options):**
1. **Strip position tracks** (current approach): In-place animation, code-driven velocity. Simplest.
2. **Root motion extraction**: Keep tracks, set `root_motion_track`, consume `get_root_motion_position()`. Proper but requires PHYSICS callback mode.
3. **OpenMW velocity subtraction**: Calculate animation velocity, subtract from engine-commanded velocity to prevent skating while preserving animation subtleties:
```gdscript
# OpenMW approach:
var anim_velocity := (bip01_end_pos - bip01_start_pos) / anim_duration
var final_velocity := commanded_velocity - anim_velocity
```

```gdscript
# Strip root bone position tracks at load time (Option A)
for track_idx in range(anim.get_track_count() - 1, -1, -1):
    var path := anim.track_get_path(track_idx)
    if path.get_subname_count() > 0:
        var bone := String(path.get_subname(0))
        if bone in ROOT_BONES and anim.track_get_type(track_idx) == Animation.TYPE_POSITION_3D:
            anim.remove_track(track_idx)
```

### 3.3 Anti-Foot-Sliding (Root Motion Phase 4)

Foot sliding happens when animation speed doesn't match movement speed. Solutions:

1. **Scale animation playback speed** to match actual velocity:
```gdscript
var anim_speed := actual_velocity.length() / animation_root_velocity.length()
animation_tree.set("parameters/locomotion/Walk/TimeScale/scale", anim_speed)
```

2. **Use root motion for velocity** (animation drives speed exactly)

3. **Foot locking IK** (most complex, best results):
   - Detect foot plant events
   - Lock foot world position during contact phase
   - IK adjusts leg to keep foot planted while body moves
   - Release on lift-off

---

## 4. Animation Blending

### 4.1 AnimationTree Node Types

| Node | Use Case |
|------|----------|
| AnimationNodeStateMachine | Discrete states (idle, walk, run, jump) with transitions |
| AnimationNodeBlendTree | Continuous blending (blend spaces, additive layers) |
| AnimationNodeBlendSpace1D | 1D parameter blend (speed → walk/run) |
| AnimationNodeBlendSpace2D | 2D parameter blend (direction + speed) |
| AnimationNodeTransition | Cross-fade between states |
| AnimationNodeAdd2 | Additive blending (upper body overlay) |
| AnimationNodeOneShot | One-shot actions over base (attack, emote) |

### 4.2 State Machine Best Practices

```gdscript
# Create state machine
var sm := AnimationNodeStateMachine.new()

# Add states
sm.add_node("Idle", AnimationNodeAnimation.new())
sm.add_node("Walk", AnimationNodeAnimation.new())
sm.add_node("Run", AnimationNodeAnimation.new())

# Transitions with crossfade
var t := AnimationNodeStateMachineTransition.new()
t.xfade_time = 0.2  # 200ms crossfade
t.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END  # or IMMEDIATE
sm.add_transition("Idle", "Walk", t)
```

**Transition modes:**
- `SWITCH_MODE_IMMEDIATE` — cut/blend immediately (locomotion, combat)
- `SWITCH_MODE_AT_END` — wait for current animation to finish (attacks, emotes)
- `SWITCH_MODE_AT_START` — transition at next animation start

### 4.3 Additive / Layer Blending

```gdscript
# Upper body overlay (e.g., aiming while running)
var blend_tree := AnimationNodeBlendTree.new()
var add := AnimationNodeAdd2.new()
blend_tree.add_node("add_upper", add)
# Connect base locomotion + upper body additive
# Filter: only affect spine, arms, head bones
```

**Industry pattern — 3-layer system:**
1. **Base layer:** Full body locomotion (walk, run, idle)
2. **Override layer:** Upper body actions (attack, cast, aim)
3. **Additive layer:** Procedural overlays (breathing, hit reactions, leaning)

### 4.4 Animation Loop Modes

```gdscript
animation.loop_mode = Animation.LOOP_NONE    # One-shot (attack, death)
animation.loop_mode = Animation.LOOP_LINEAR  # Seamless loop (walk, idle)
animation.loop_mode = Animation.LOOP_PINGPONG  # Bounce (breathing)
```

**Morrowind KF convention:** Text keys with "Loop Start"/"Loop Stop" → `LOOP_LINEAR`. Plain "Start"/"Stop" → `LOOP_NONE`.

---

## 5. Foot IK — Industry Standard Implementation

### 5.1 The Problem

Raw animations play feet at predetermined positions. Real terrain is uneven. Without foot IK:
- Feet float above slopes
- Feet clip through steps
- Character slides on uneven ground

### 5.2 Proper Foot Contact System (AAA Standard)

**Phase 1: Foot contact detection**
```gdscript
# Method A: Animation events / text keys (best for hand-authored animations)
# Standard: Add "foot_plant_left" / "foot_lift_left" events to animations
# Morrowind: KF text keys "SoundGen: Left" / "SoundGen: Right" mark footsteps
#   — these are already in the KF data and can serve as foot contact markers

# Method B: Velocity-based (best for procedural / many animations)
func _detect_foot_contact(foot_bone_idx: int) -> bool:
    var current_pos := skeleton.get_bone_global_pose(foot_bone_idx).origin
    var velocity := (current_pos - _prev_foot_pos) / delta
    _prev_foot_pos = current_pos
    return velocity.length() < PLANT_THRESHOLD  # foot is "planted" when barely moving

# Method C: Height-based (simplest)
func _detect_foot_contact(foot_bone_idx: int) -> bool:
    var foot_y := (skeleton.global_transform * skeleton.get_bone_global_pose(foot_bone_idx)).origin.y
    return foot_y < GROUND_THRESHOLD  # foot near ground level
```

**Phase 2: Ground adaptation (Y-only during plant)**
```gdscript
func _update_foot_ik(delta: float) -> void:
    for foot in [left_foot, right_foot]:
        # Get animated foot world position
        var anim_pos := skeleton.global_transform * skeleton.get_bone_global_pose(foot.bone_idx).origin

        # Raycast straight down from animated position
        var ray_origin := anim_pos + Vector3.UP * RAY_LIFT
        var ray_end := anim_pos + Vector3.DOWN * RAY_DROP
        var result := space_state.intersect_ray(PhysicsRayQueryParameters3D.create(ray_origin, ray_end))

        if result:
            var ground_y := result.position.y
            # ONLY adjust Y — preserve animation's X/Z (don't fight locomotion)
            foot.ik_target.global_position = Vector3(anim_pos.x, ground_y, anim_pos.z)

            # Align foot to ground normal
            var normal := result.normal
            foot.ik_target.global_transform.basis = _align_to_normal(foot.ik_target.global_transform.basis, normal)

        # Blend IK weight based on contact phase
        var target_weight := 1.0 if foot.is_planted else 0.0
        foot.ik_modifier.blend_weight = lerpf(foot.ik_modifier.blend_weight, target_weight, IK_BLEND_SPEED * delta)
```

**Phase 3: Pelvis offset (slope adaptation)**
```gdscript
# When one foot is lower (downhill), drop the pelvis to compensate
var left_ground_y := left_foot_ground_hit.y
var right_ground_y := right_foot_ground_hit.y
var lower_y := minf(left_ground_y, right_ground_y)
var pelvis_offset := lower_y - character_body.global_position.y

# Apply pelvis drop (prevents leg over-extension on slopes)
var hips_idx := skeleton.find_bone("Hips")
var hips_pos := skeleton.get_bone_pose_position(hips_idx)
hips_pos.y += clampf(pelvis_offset, -MAX_PELVIS_DROP, 0.0)
skeleton.set_bone_pose_position(hips_idx, hips_pos)
```

### 5.3 IK Weight by Movement State

| State | Foot IK Weight | Reason |
|-------|---------------|--------|
| Idle / Standing | 1.0 | Full terrain adaptation |
| Walking | 0.5-0.8 | Partial — adjust height, don't fight stride |
| Running | 0.0-0.3 | Minimal — feet move too fast for IK to track |
| Sprinting | 0.0 | Disabled — animation speed makes IK counterproductive |
| Jumping / Falling | 0.0 | No ground contact |
| Swimming | 0.0 | No ground contact |
| Landing | 0.0 → 1.0 | Ramp up over ~0.2s after landing |

**Critical rule:** During swing phase (foot in air), IK weight MUST be 0. Only adjust during plant phase. Otherwise IK fights the animation's leg swing.

### 5.4 Common Foot IK Bugs

| Symptom | Cause | Fix |
|---------|-------|-----|
| Feet drag behind during walk | IK target is world-space, doesn't move with character | Use animated foot position as raycast origin, only adjust Y |
| Feet snap on stop | IK enables instantly when velocity drops | Add 0.1-0.2s delay or lerp blend weight |
| Knees bend backward | Pole target missing or wrong direction | Set pole node in front of foot, facing forward |
| One foot floats | Pelvis not adjusted for slope | Implement pelvis offset (Phase 3 above) |
| Jittery feet on stairs | Raycast hits stair edges | Use SphereCast or average multiple raycasts |
| IK solver does nothing | Missing target_node or pole_node | Both are REQUIRED for TwoBoneIK3D |

---

## 6. Animation Format Conversion

### 6.1 Morrowind KF → Godot Animation

```
KF Binary → nif_kf_loader.gd → Animation resources
  - Text keys define animation boundaries ("Idle: Loop Start" / "Idle: Loop Stop")
  - Bone transforms are ABSOLUTE (world-space in bone hierarchy)
  - Root bones (Bip01, NonAccum) carry locomotion — strip or extract
  - Coordinate conversion: Vector3(mw.x, mw.z, -mw.y)
```

**Loop detection:** "Loop Start"/"Loop Stop" → `LOOP_LINEAR`. Plain "Start"/"Stop" → `LOOP_NONE`.

### 6.2 GLB/FBX → Godot Animation

```
GLB/FBX → Godot importer → AnimationLibrary
  - Bone names may need remapping to SkeletonProfileHumanoid
  - animation_loader.gd handles unified remap pipeline
  - Import settings: Skeleton3D → Retarget → BoneMap → SkeletonProfileHumanoid
```

---

## 7. Debugging Checklist

### Animation Not Playing
1. Is `AnimationTree.active = true`?
2. Is `AnimationPlayer.root_node` pointing to correct node?
3. Does the state machine playback have a valid current node?
4. Do track bone names match skeleton bone names? (check after renaming)
5. Is `root_motion_track` set? (silently eats bone position if nobody reads it)
6. Is another AnimationTree fighting for the same skeleton? (only 1 per skeleton)

### IK Not Working
1. Is the modifier a child of Skeleton3D? (required)
2. Are both `target_node` and `pole_node` set? (required for TwoBoneIK3D)
3. Is `active = true`?
4. Are bone names correct? (case-sensitive)
5. Is `setting_count` set to at least 1?

### Animation Freezes After Playing Once
1. Check `animation.loop_mode` — should be `LOOP_LINEAR` for locomotion
2. Check state machine transition — does it auto-advance to a stopped state?
3. Check if the Animation resource has correct duration

### Model Drifts Away From Controller
1. Root bone position tracks are translating the skeleton
2. Fix: Strip position tracks from root bones at load time
3. Or: Set `root_motion_track` AND consume `get_root_motion_position()` every frame
4. Bone pinning in `_physics_process` does NOT work — AnimationTree in `_process` overwrites it

---

## 8. Godotwind-Specific Notes

### Our IK Setup (ik_controller.gd)
- Uses TwoBoneIK3D for foot IK (left/right legs)
- LookAtModifier3D for head tracking (POI system)
- TwoBoneIK3D for hand IK (weapon grip, future)
- Foot IK currently disabled during locomotion (interim fix)
- **TODO:** Implement proper foot contact detection (Phase 4)

### Our Animation Pipeline
- KF → nif_kf_loader.gd → Animation → animation_loader.gd remap → AnimationLibrary
- Root bone position tracks stripped at KF load time (Bip01, Bip01 NonAccum)
- MORROWIND_ANIM_MAP in morrowind_character_system.gd maps states to KF names
- AnimationManager handles state machine + oneshot layers
- MoveContainer (Move-as-Node pattern) drives animation state from gameplay

### Morrowind Text Keys Reference
- `Start` / `Stop` — animation boundaries (non-looping)
- `Loop Start` / `Loop Stop` — loop region (set LOOP_LINEAR)
- `SoundGen: Left` / `SoundGen: Right` — footstep events (USE FOR FOOT CONTACT DETECTION)
- `hit` — weapon damage frame
- `chop` / `slash` / `thrust` — attack type markers

### Known Limitations
- FABRIK3D available in 4.6 but not yet used — TwoBoneIK3D sufficient for humanoid limbs
- No foot contact detection — binary on/off by velocity threshold (SoundGen text keys available but unused)
- No pelvis offset for slope adaptation
- No root motion extraction (position tracks stripped, not captured)
- AnimationTree processes in IDLE mode (default) — bone modifications in _physics_process are overwritten
- Godot lacks native animation layers — simulated with Blend2 + bone filters
- AnimationNodeAdd2 is NOT true additive (no reference pose subtraction) — use Sub2 + Add2 workaround
