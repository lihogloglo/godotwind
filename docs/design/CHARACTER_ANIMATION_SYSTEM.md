# Character Animation System - Design Document

**Version:** 2.0
**Date:** 2025-12-26
**Status:** Design Phase

---

## Executive Summary

This document outlines the design for a **next-generation character animation system** that serves two purposes:

1. **Morrowind Port** - Load and enhance Morrowind's skeletal characters with modern features
2. **Generic Game Engine** - Provide a flexible, extensible system for any humanoid or creature

The goal is to achieve AAA-quality character animation while maintaining the flexibility to support Morrowind's unique body-part assembly system and legacy animation format.

---

## Table of Contents

1. [Design Goals](#1-design-goals)
2. [Godot 4.x Animation Capabilities](#2-godot-4x-animation-capabilities)
3. [Modern Game Engine Standards](#3-modern-game-engine-standards)
4. [Plugin Ecosystem](#4-plugin-ecosystem)
5. [Architecture Overview](#5-architecture-overview)
6. [Core Systems](#6-core-systems)
7. [IK System](#7-ik-system)
8. [Animation Blending & Layering](#8-animation-blending--layering)
9. [Procedural Animation](#9-procedural-animation)
10. [Morrowind Integration](#10-morrowind-integration)
11. [Performance Considerations](#11-performance-considerations)
12. [Implementation Roadmap](#12-implementation-roadmap)

---

## 1. Design Goals

### Primary Goals

| Goal | Description | Priority |
|------|-------------|----------|
| **Next-Gen Quality** | IK, blending, additive animations, procedural motion | Critical |
| **100 Active Characters** | Maintain 60 FPS with 100 fully animated NPCs | Critical |
| **Morrowind Compatibility** | Load .kf animations, body-part assembly, retargeting | High |
| **Generic Architecture** | Support non-Morrowind characters (Mixamo, custom rigs) | High |
| **Extensibility** | Easy to add new IK targets, animation layers, behaviors | Medium |
| **Runtime Flexibility** | Hot-swap equipment, change animations at runtime | Medium |

### Non-Goals

- Motion capture pipeline (out of scope)
- Facial animation system (separate system)
- Ragdoll physics (Phase 3+)
- Motion matching (future enhancement)

---

## 2. Godot 4.x Animation Capabilities

### What Godot Does Well

| Feature | Status | Notes |
|---------|--------|-------|
| **AnimationTree** | Mature | State machines, blend trees, transitions |
| **BlendSpace1D/2D** | Good | Directional movement blending |
| **AnimationPlayer** | Excellent | Keyframe playback, libraries |
| **Skeleton3D** | Good | Bone hierarchy, poses |
| **BoneAttachment3D** | Good | Props, weapons, body parts |
| **Retargeting** | Good | BoneMap + SkeletonProfile (4.0+) |

### Known Limitations

| Feature | Issue | Workaround |
|---------|-------|------------|
| **SkeletonIK3D** | Deprecated (still works) | Use SkeletonModifier3D or plugins |
| **Animation Layers** | Manual bone filtering | Custom SkeletonMask resource |
| **Additive Animation** | Blender workflow awkward | Runtime pose subtraction |
| **Root Motion** | Offset bugs in 4.2-4.3 | Use plugin or disable |
| **IK Ecosystem** | Immature native support | Third-party plugins |

### Godot's Animation Architecture

```
AnimationTree (Brain)
├── AnimationNodeStateMachine (States)
│   ├── State: Idle
│   ├── State: Walk
│   ├── State: Run
│   └── Transitions (auto/travel)
├── AnimationNodeBlendTree (Complex Blending)
│   ├── BlendSpace2D (directional)
│   ├── OneShot (layered actions)
│   └── Add2/Add3 (additive)
└── AnimationPlayer (Playback)
    └── AnimationLibrary (Clips)
```

### SkeletonModifier3D (Godot 4.3+)

The new foundation for IK and procedural animation:

```gdscript
# Base class for all skeleton modifiers
class_name SkeletonModifier3D extends Node3D

# Godot's planned implementations:
# - TwoBoneIK3D (limbs)
# - ChainIK3D (FABRIK/CCDIK replacement)
# - LookAt3D (head tracking)
# - PhysicalBone3D integration
```

**Current Status:** Foundation exists, but implementations are sparse. Third-party plugins fill the gap.

---

## 3. Modern Game Engine Standards

### What AAA Games Do

| Feature | Unreal | Unity | Our Target |
|---------|--------|-------|------------|
| **Foot Placement IK** | Control Rig | Animation Rigging | Yes |
| **Look-At IK** | Built-in | Animation Rigging | Yes |
| **Hand IK** | Control Rig | Animation Rigging | Yes |
| **Layered Animation** | Anim Layers | Avatar Mask | Yes |
| **Additive Animation** | Built-in | Built-in | Yes |
| **Root Motion** | Built-in | Built-in | Optional |
| **Motion Matching** | Built-in (5.0+) | Third-party | Future |
| **Procedural Lean** | Control Rig | Custom | Yes |
| **Blend Spaces** | Built-in | Blend Trees | Yes |

### Unreal's Control Rig

Key concepts to emulate:
- **Modular Rigs** - Compose from smaller, reusable parts
- **Runtime Evaluation** - IK and procedural animation in Animation Blueprint
- **Layered Control** - Additive adjustments without full rig assets
- **FK/IK Switching** - Seamless blend between keyframe and procedural

### Unity's Animation Rigging

Key concepts:
- **Constraint-Based** - TwoBoneIK, MultiAim, DampedTransform
- **Rig Builder** - Stack of rig groups with weights
- **Runtime Setup** - Create constraints at runtime
- **World Interaction** - IK for environment (ledges, props, cover)

### Motion Matching (Reference)

Not implementing now, but understanding the concept:
- Large database of motion capture
- Feature extraction (positions, velocities, trajectory)
- Runtime search for best matching frame
- Inertialization for smooth transitions
- **Benefit:** Near-mocap quality with responsive control
- **Cost:** Large animation databases, preprocessing

---

## 4. Plugin Ecosystem

### Recommended Plugins

#### IK Solutions

| Plugin | Type | Cost | Notes |
|--------|------|------|-------|
| **Twisted IK 2** | Multiple solvers | $20 | Stable, no longer developed |
| **RenIK** | Full-body humanoid | Free | VR-ready, pure GDScript |
| **V-Sekai Motion Matching** | IK + Motion Matching | Free | TwoBoneIK, LookAt included |

#### Motion Matching

| Plugin | Godot Version | Notes |
|--------|---------------|-------|
| **godot-motion-matching** | 4.4+ | Full implementation as AnimationTree node |
| **V-Sekai Motion Matching** | 4.2+ | Modular design |
| **Remi123/MotionMatching** | 4.x | Generic implementation |

### Recommendation

**Start with built-in + V-Sekai IK nodes**, then evaluate Twisted IK 2 if needed:

```gdscript
# V-Sekai provides:
# - PPIKTwoBone3D (limb IK)
# - PPIKLookAt3D (head tracking)
# - MMAnimationPlayer (inertialized transitions)
```

---

## 5. Architecture Overview

### High-Level Design

```
┌─────────────────────────────────────────────────────────────────┐
│                    CharacterAnimationSystem                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │  Animation   │  │     IK       │  │  Procedural  │           │
│  │   Manager    │  │  Controller  │  │  Modifiers   │           │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘           │
│         │                 │                 │                    │
│         ▼                 ▼                 ▼                    │
│  ┌─────────────────────────────────────────────────────┐        │
│  │              Skeleton3D + AnimationTree              │        │
│  └─────────────────────────────────────────────────────┘        │
│                            │                                     │
│         ┌──────────────────┼──────────────────┐                 │
│         ▼                  ▼                  ▼                 │
│  ┌────────────┐    ┌────────────┐    ┌────────────┐            │
│  │ Locomotion │    │   Action   │    │  Additive  │            │
│  │   Layer    │    │   Layer    │    │   Layer    │            │
│  └────────────┘    └────────────┘    └────────────┘            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Class Hierarchy

```
CharacterAnimationSystem (base class)
├── AnimationManager
│   ├── AnimationTree setup/control
│   ├── State machine management
│   ├── Blend parameter control
│   └── Animation library management
│
├── IKController
│   ├── FootIK (2x TwoBoneIK)
│   ├── LookAtIK (head/spine chain)
│   ├── HandIK (2x TwoBoneIK)
│   └── IK target management
│
├── ProceduralModifiers
│   ├── LeanController (acceleration-based)
│   ├── BreathingController (idle oscillation)
│   └── HitReactionController (impact response)
│
└── LODController
    ├── Distance-based quality
    └── Frustum culling
```

### Inheritance for Morrowind

```
CharacterAnimationSystem (generic)
    │
    ├── HumanoidAnimationSystem (bipeds)
    │   │
    │   └── MorrowindCharacterSystem
    │       ├── BodyPartAssembler integration
    │       ├── KF animation loading
    │       └── Morrowind bone mapping
    │
    └── CreatureAnimationSystem (non-humanoid)
        │
        └── MorrowindCreatureSystem
            └── Creature-specific skeletons
```

---

## 6. Core Systems

### 6.1 AnimationManager

Manages AnimationTree state and transitions.

```gdscript
class_name AnimationManager extends Node

# Configuration
@export var blend_time: float = 0.2
@export var use_root_motion: bool = false

# References
var animation_tree: AnimationTree
var animation_player: AnimationPlayer
var state_machine: AnimationNodeStateMachinePlayback

# State
var current_state: StringName = &"idle"
var blend_parameters: Dictionary = {}

# API
func setup(skeleton: Skeleton3D, animations: AnimationLibrary) -> void
func transition_to(state: StringName, force: bool = false) -> void
func set_blend_parameter(name: StringName, value: Variant) -> void
func play_oneshot(animation: StringName, layer: StringName = &"action") -> void
func get_current_state() -> StringName
```

**Responsibilities:**
- Create and configure AnimationTree
- Manage state machine transitions
- Control blend parameters (speed, direction)
- Handle oneshot animations (attacks, interactions)
- Provide animation events/callbacks

### 6.2 Animation Layers

Three primary layers with bone filtering:

| Layer | Bones | Purpose | Blend Mode |
|-------|-------|---------|------------|
| **Locomotion** | Full body (or lower) | Movement animations | Replace |
| **Action** | Upper body | Attacks, interactions | Replace (filtered) |
| **Additive** | Full body | Lean, breathing, reactions | Additive |

```gdscript
# Layer configuration
var layers: Dictionary = {
    "locomotion": {
        "bones": [], # Empty = all bones
        "blend_mode": "replace",
        "priority": 0
    },
    "action": {
        "bones": ["Spine", "Chest", "Neck", "Head",
                  "Left Shoulder", "Left Upper Arm", "Left Forearm", "Left Hand",
                  "Right Shoulder", "Right Upper Arm", "Right Forearm", "Right Hand"],
        "blend_mode": "replace",
        "priority": 1
    },
    "additive": {
        "bones": [],
        "blend_mode": "additive",
        "priority": 2
    }
}
```

### 6.3 Blend Parameters

Standard parameters for locomotion:

```gdscript
# Movement blend space
var movement_direction: Vector2 = Vector2.ZERO  # -1 to 1 (strafe, forward/back)
var movement_speed: float = 0.0                  # 0 = idle, 1 = walk, 2 = run

# Additional modifiers
var turn_rate: float = 0.0      # Angular velocity (for turn animations)
var slope_angle: float = 0.0    # Ground slope (for incline blending)
var is_grounded: bool = true    # Air vs ground state
```

---

## 7. IK System

### 7.1 IK Architecture

```
IKController
├── FootIK
│   ├── LeftFootIK (TwoBoneIK)
│   │   ├── Root: Left Upper Leg
│   │   ├── Joint: Left Lower Leg
│   │   └── Tip: Left Foot
│   └── RightFootIK (TwoBoneIK)
│       ├── Root: Right Upper Leg
│       ├── Joint: Right Lower Leg
│       └── Tip: Right Foot
│
├── LookAtIK
│   ├── HeadLookAt (single bone or chain)
│   └── SpineLookAt (optional, weight falloff)
│
└── HandIK
    ├── LeftHandIK (TwoBoneIK)
    │   ├── Root: Left Upper Arm
    │   ├── Joint: Left Forearm
    │   └── Tip: Left Hand
    └── RightHandIK (TwoBoneIK)
        ├── Root: Right Upper Arm
        ├── Joint: Right Forearm
        └── Tip: Right Hand
```

### 7.2 Foot Placement IK

**Algorithm:**

```gdscript
func _process_foot_ik(delta: float) -> void:
    for foot in [left_foot, right_foot]:
        # 1. Get animated foot position
        var anim_pos: Vector3 = skeleton.get_bone_global_pose(foot.bone_idx).origin

        # 2. Raycast down from hip height
        var ray_origin: Vector3 = anim_pos + Vector3.UP * raycast_height
        var ray_end: Vector3 = anim_pos - Vector3.UP * raycast_depth
        var hit: Dictionary = raycast(ray_origin, ray_end)

        # 3. Calculate target position
        if hit:
            var ground_pos: Vector3 = hit.position + Vector3.UP * foot_offset
            var target_pos: Vector3 = ground_pos

            # 4. Clamp adjustment distance
            var adjustment: float = (target_pos - anim_pos).length()
            if adjustment > max_adjustment:
                target_pos = anim_pos + (target_pos - anim_pos).normalized() * max_adjustment

            # 5. Smooth interpolation
            foot.target.global_position = foot.target.global_position.lerp(
                target_pos,
                ik_smoothing * delta
            )

            # 6. Rotate foot to match surface
            var surface_normal: Vector3 = hit.normal
            foot.target.global_basis = _calculate_foot_rotation(surface_normal)

        # 7. Adjust pelvis height (average of both feet)
        _adjust_pelvis_height()
```

**Pelvis Adjustment:**

```gdscript
func _adjust_pelvis_height() -> void:
    # Find lowest foot adjustment
    var left_offset: float = left_foot.target.global_position.y - left_foot.anim_position.y
    var right_offset: float = right_foot.target.global_position.y - right_foot.anim_position.y
    var pelvis_offset: float = min(left_offset, right_offset)

    # Apply to character root (not skeleton)
    character_root.position.y += pelvis_offset * pelvis_adjustment_strength
```

### 7.3 Look-At IK

**Algorithm:**

```gdscript
func _process_look_at(delta: float) -> void:
    if not look_target:
        return

    # 1. Get direction to target
    var head_pos: Vector3 = skeleton.get_bone_global_pose(head_bone_idx).origin
    var target_dir: Vector3 = (look_target.global_position - head_pos).normalized()

    # 2. Check if target is in valid cone
    var forward: Vector3 = -skeleton.global_transform.basis.z
    var angle: float = forward.angle_to(target_dir)
    if angle > max_look_angle:
        return  # Don't look at targets behind us

    # 3. Calculate weight based on angle (smooth falloff)
    var weight: float = 1.0 - (angle / max_look_angle)
    weight = smoothstep(0.0, 1.0, weight)

    # 4. Apply rotation to head (and optionally spine chain)
    var target_rotation: Basis = _calculate_look_rotation(target_dir)

    # Head gets full weight
    _apply_bone_rotation(head_bone_idx, target_rotation, weight * head_weight)

    # Spine gets diminishing weight
    for i in range(spine_bones.size()):
        var spine_weight: float = weight * spine_weight_curve[i]
        _apply_bone_rotation(spine_bones[i], target_rotation, spine_weight)
```

### 7.4 Hand IK

Used for:
- Weapon grip adjustment
- Prop interaction (doors, levers)
- Wall bracing
- Two-handed weapon poses

```gdscript
class HandIKTarget:
    var bone_idx: int
    var target: Node3D
    var weight: float = 1.0
    var pole_target: Node3D  # Elbow direction

func set_hand_target(hand: StringName, target: Node3D, weight: float = 1.0) -> void:
    var ik: HandIKTarget = left_hand_ik if hand == &"left" else right_hand_ik
    ik.target = target
    ik.weight = weight

func clear_hand_target(hand: StringName) -> void:
    set_hand_target(hand, null, 0.0)
```

---

## 8. Animation Blending & Layering

### 8.1 State Machine Design

```
                    ┌─────────────┐
                    │   GROUND    │
                    │   STATES    │
         ┌──────────┴─────────────┴──────────┐
         │                                    │
    ┌────▼────┐    ┌─────────┐    ┌─────────┐
    │  Idle   │◄───│  Walk   │◄───│   Run   │
    └────┬────┘    └────┬────┘    └────┬────┘
         │              │              │
         └──────────────┼──────────────┘
                        │
                   ┌────▼────┐
                   │  Jump   │
                   └────┬────┘
                        │
    ┌───────────────────┼───────────────────┐
    │                   │                   │
┌───▼───┐         ┌────▼────┐         ┌────▼────┐
│ Fall  │         │  Land   │         │  Land   │
│       │         │  Soft   │         │  Hard   │
└───────┘         └─────────┘         └─────────┘
```

### 8.2 Locomotion BlendSpace2D

```
           Forward (+Y)
              │
              │    Run
              │   ┌───┐
              │   │ R │
         Walk │   └───┘
        ┌───┐ │
        │ W │ │
        └───┘ │
              │
 Left ────────┼──────── Right
    (-X)      │         (+X)
              │
        ┌───┐ │
        │ I │ │  Idle (center)
        └───┘ │
              │
           Backward (-Y)

BlendSpace2D Parameters:
- X axis: strafe direction (-1 to 1)
- Y axis: forward/backward (-1 to 1)
- Blend points: Idle(0,0), WalkF(0,0.5), RunF(0,1), etc.
```

### 8.3 OneShot Layer (Upper Body Actions)

```gdscript
# AnimationTree structure for action layer:
#
# BlendTree (root)
# ├── Locomotion (state machine)
# └── OneShot
#     ├── Input: Locomotion output
#     ├── Shot: Action animation
#     └── Filter: Upper body bones only

func play_action(animation: StringName) -> void:
    # Trigger oneshot
    animation_tree.set("parameters/ActionOneShot/request",
                       AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
    animation_tree.set("parameters/ActionOneShot/internal_active", true)

    # Set animation
    animation_tree.set("parameters/ActionAnimation/animation", animation)
```

### 8.4 Additive Animation Layer

Use cases:
- **Lean** - Tilt based on acceleration/turning
- **Breathing** - Subtle idle motion
- **Hit Reactions** - Impact response overlay
- **Fatigue** - Tired modifier on all animations

```gdscript
# Additive animations are DELTA from base pose
# They add rotation/position changes on top of current animation

func set_additive_weight(animation: StringName, weight: float) -> void:
    var param_path: String = "parameters/%s/blend_amount" % animation
    animation_tree.set(param_path, weight)

# Example: Set lean based on velocity change
func _update_lean(delta: float) -> void:
    var acceleration: Vector3 = (velocity - previous_velocity) / delta

    # Forward/back lean
    var forward_lean: float = -acceleration.dot(transform.basis.z) * lean_strength

    # Side lean
    var side_lean: float = acceleration.dot(transform.basis.x) * lean_strength

    set_additive_weight(&"lean_forward", clamp(forward_lean, -1, 1))
    set_additive_weight(&"lean_side", clamp(side_lean, -1, 1))
```

---

## 9. Procedural Animation

### 9.1 Lean Controller

Adds natural body lean based on movement dynamics.

```gdscript
class_name LeanController extends Node

@export var lean_strength: float = 0.3
@export var lean_smoothing: float = 5.0
@export var max_lean_angle: float = 15.0  # degrees

var current_lean: Vector2 = Vector2.ZERO
var target_lean: Vector2 = Vector2.ZERO

func _physics_process(delta: float) -> void:
    var character: CharacterBody3D = get_parent()
    var velocity: Vector3 = character.velocity
    var acceleration: Vector3 = _calculate_acceleration(velocity, delta)

    # Calculate lean from acceleration
    var forward_accel: float = acceleration.dot(-character.transform.basis.z)
    var side_accel: float = acceleration.dot(character.transform.basis.x)

    target_lean.x = clamp(side_accel * lean_strength, -1, 1)
    target_lean.y = clamp(forward_accel * lean_strength, -1, 1)

    # Smooth interpolation
    current_lean = current_lean.lerp(target_lean, lean_smoothing * delta)

    # Apply to animation system
    animation_system.set_additive_blend(&"lean_side", current_lean.x)
    animation_system.set_additive_blend(&"lean_forward", current_lean.y)
```

### 9.2 Breathing Controller

Subtle idle motion that adds life to standing characters.

```gdscript
class_name BreathingController extends Node

@export var breathing_rate: float = 0.2  # Hz (breaths per second)
@export var breathing_strength: float = 0.3
@export var breathing_variation: float = 0.1

var breathing_phase: float = 0.0

func _process(delta: float) -> void:
    # Advance phase with slight variation
    var rate: float = breathing_rate + randf_range(-breathing_variation, breathing_variation)
    breathing_phase += delta * rate * TAU

    # Sine wave for breathing cycle
    var breathing_value: float = sin(breathing_phase) * breathing_strength

    # Only apply when mostly stationary
    var movement_factor: float = 1.0 - clamp(character.velocity.length() / 2.0, 0, 1)
    breathing_value *= movement_factor

    animation_system.set_additive_blend(&"breathing", breathing_value)
```

### 9.3 Hit Reaction Controller

Impulse-based reactions to damage.

```gdscript
class_name HitReactionController extends Node

@export var reaction_decay: float = 5.0
@export var max_reaction_strength: float = 1.0

var current_reaction: Vector3 = Vector3.ZERO

func apply_hit(direction: Vector3, strength: float) -> void:
    # Add impulse in hit direction
    var impulse: Vector3 = direction.normalized() * min(strength, max_reaction_strength)
    current_reaction += impulse

func _process(delta: float) -> void:
    if current_reaction.length() < 0.01:
        current_reaction = Vector3.ZERO
        return

    # Decay over time
    current_reaction = current_reaction.lerp(Vector3.ZERO, reaction_decay * delta)

    # Apply to additive animation
    animation_system.set_additive_blend(&"hit_back", max(0, current_reaction.z))
    animation_system.set_additive_blend(&"hit_forward", max(0, -current_reaction.z))
    animation_system.set_additive_blend(&"hit_left", max(0, current_reaction.x))
    animation_system.set_additive_blend(&"hit_right", max(0, -current_reaction.x))
```

---

## 10. Morrowind Integration

### 10.1 Skeleton Mapping

Morrowind uses non-standard bone names. Create a BoneMap for retargeting:

```gdscript
# Morrowind bone names → Godot humanoid profile
const MORROWIND_BONE_MAP: Dictionary = {
    # Spine
    "Bip01": "Hips",
    "Bip01 Spine": "Spine",
    "Bip01 Spine1": "Chest",
    "Bip01 Spine2": "UpperChest",
    "Bip01 Neck": "Neck",
    "Bip01 Head": "Head",

    # Left Arm
    "Bip01 L Clavicle": "LeftShoulder",
    "Bip01 L UpperArm": "LeftUpperArm",
    "Bip01 L Forearm": "LeftLowerArm",
    "Bip01 L Hand": "LeftHand",

    # Right Arm
    "Bip01 R Clavicle": "RightShoulder",
    "Bip01 R UpperArm": "RightUpperArm",
    "Bip01 R Forearm": "RightLowerArm",
    "Bip01 R Hand": "RightHand",

    # Left Leg
    "Bip01 L Thigh": "LeftUpperLeg",
    "Bip01 L Calf": "LeftLowerLeg",
    "Bip01 L Foot": "LeftFoot",
    "Bip01 L Toe0": "LeftToes",

    # Right Leg
    "Bip01 R Thigh": "RightUpperLeg",
    "Bip01 R Calf": "RightLowerLeg",
    "Bip01 R Foot": "RightFoot",
    "Bip01 R Toe0": "RightToes",
}
```

### 10.2 Body Part Assembly Integration

The existing BodyPartAssembler works well. Integration points:

```gdscript
class MorrowindCharacterSystem extends HumanoidAnimationSystem:
    var body_part_assembler: BodyPartAssembler

    func setup_morrowind_character(npc_record: NPCRecord) -> void:
        # 1. Assemble body parts (existing system)
        var character_root: Node3D = body_part_assembler.assemble_npc(npc_record)
        var skeleton: Skeleton3D = _find_skeleton(character_root)

        # 2. Load Morrowind animations
        var animations: AnimationLibrary = _load_morrowind_animations(npc_record)

        # 3. Apply bone mapping for IK
        _apply_bone_mapping(skeleton, MORROWIND_BONE_MAP)

        # 4. Initialize base animation system
        super.setup(skeleton, animations)

        # 5. Configure IK with mapped bones
        ik_controller.setup_humanoid(skeleton, MORROWIND_BONE_MAP)
```

### 10.3 KF Animation Enhancement

Morrowind animations are basic. Enhance them:

```gdscript
func _enhance_morrowind_animation(animation: Animation) -> Animation:
    # 1. Add root motion extraction (optional)
    if extract_root_motion:
        _extract_root_motion(animation)

    # 2. Generate additive variants
    _generate_additive_variants(animation)

    # 3. Adjust timing for modern feel
    if adjust_timing:
        animation.speed_scale = morrowind_speed_adjustment

    return animation

func _generate_additive_variants(base_animation: Animation) -> void:
    # Create lean variants from existing animations
    # These are deltas from T-pose that can be blended additively

    var lean_forward: Animation = _create_additive_from_pose(
        base_animation,
        "lean_forward_pose"
    )
    animation_library.add_animation(&"lean_forward", lean_forward)
```

### 10.4 Creature Support

Creatures have unique skeletons. Handle generically:

```gdscript
class MorrowindCreatureSystem extends CreatureAnimationSystem:

    func setup_creature(creature_record: CreatureRecord) -> void:
        var skeleton: Skeleton3D = _load_creature_skeleton(creature_record)
        var animations: AnimationLibrary = _load_creature_animations(creature_record)

        # Detect creature type and configure IK appropriately
        var creature_type: StringName = _detect_creature_type(skeleton)

        match creature_type:
            &"biped":
                ik_controller.setup_biped(skeleton)
            &"quadruped":
                ik_controller.setup_quadruped(skeleton)
            &"flying":
                ik_controller.disable()  # No ground IK for flying creatures
            &"snake":
                ik_controller.setup_snake(skeleton)
            _:
                ik_controller.disable()

        super.setup(skeleton, animations)
```

---

## 11. Performance Considerations

### 11.1 LOD System

Distance-based quality reduction:

| LOD | Distance | IK | Blending | Update Rate | Active |
|-----|----------|-----|----------|-------------|--------|
| **Full** | < 15m | Yes | Full | 60 FPS | ~20 NPCs |
| **High** | 15-30m | Yes | Reduced | 30 FPS | ~30 NPCs |
| **Medium** | 30-60m | No | Simple | 15 FPS | ~30 NPCs |
| **Low** | 60-100m | No | Single anim | 5 FPS | ~20 NPCs |
| **Culled** | > 100m | No | Frozen | 0 FPS | Unlimited |

### 11.2 Budget Allocation

For 100 active NPCs at 60 FPS:

```
Total Animation Budget: 8ms per frame

Breakdown:
├── AnimationTree evaluation: 3ms (100 × 0.03ms)
├── IK solving: 2ms (40 × 0.05ms, only close NPCs)
├── Procedural modifiers: 1ms (100 × 0.01ms)
├── Skeleton updates: 1.5ms (100 × 0.015ms)
└── Buffer: 0.5ms

Optimization strategies:
- Batch AnimationTree updates
- Skip IK for distant characters
- Pool animation players
- Use simpler state machines for background NPCs
```

### 11.3 Memory Considerations

```
Per Character:
├── Skeleton3D: ~2KB
├── AnimationTree: ~1KB
├── Animation references: ~0.5KB
├── IK targets: ~0.3KB
└── Controllers: ~0.2KB
Total: ~4KB per character

100 Characters: ~400KB (acceptable)

Animation Libraries:
├── Morrowind humanoid: ~50 animations × 10KB = 500KB
├── Morrowind creatures: ~30 types × 200KB = 6MB
└── Shared (instanced): Minimal overhead
```

---

## 12. Implementation Roadmap

### Phase 1: Foundation (Current)
- [x] Basic AnimationTree setup
- [x] State machine (13 states)
- [x] FootIK (existing implementation)
- [x] Animation LOD
- [x] Morrowind KF loading

### Phase 2: Core Enhancement
- [ ] Refactor into CharacterAnimationSystem base class
- [ ] Proper animation layering (upper/lower body)
- [ ] LookAtIK implementation
- [ ] HandIK implementation
- [ ] Procedural lean controller
- [ ] Breathing controller

### Phase 3: Polish
- [ ] Hit reaction system
- [ ] Blend space locomotion (directional movement)
- [ ] Root motion support (optional)
- [ ] Equipment attachment IK
- [ ] Creature IK variants

### Phase 4: Advanced (Future)
- [ ] Motion matching evaluation
- [ ] Ragdoll blend-in
- [ ] Facial animation system
- [ ] Crowd animation optimization

---

## Appendix A: Bone Names Reference

### Standard Humanoid (Godot Profile)

```
Hips
├── Spine
│   ├── Chest
│   │   ├── UpperChest
│   │   │   ├── Neck
│   │   │   │   └── Head
│   │   │   ├── LeftShoulder
│   │   │   │   └── LeftUpperArm
│   │   │   │       └── LeftLowerArm
│   │   │   │           └── LeftHand
│   │   │   └── RightShoulder
│   │   │       └── RightUpperArm
│   │   │           └── RightLowerArm
│   │   │               └── RightHand
├── LeftUpperLeg
│   └── LeftLowerLeg
│       └── LeftFoot
│           └── LeftToes
└── RightUpperLeg
    └── RightLowerLeg
        └── RightFoot
            └── RightToes
```

### Morrowind Humanoid

```
Bip01
├── Bip01 Spine
│   ├── Bip01 Spine1
│   │   ├── Bip01 Spine2
│   │   │   ├── Bip01 Neck
│   │   │   │   └── Bip01 Head
│   │   │   ├── Bip01 L Clavicle
│   │   │   │   └── Bip01 L UpperArm
│   │   │   │       └── Bip01 L Forearm
│   │   │   │           └── Bip01 L Hand
│   │   │   └── Bip01 R Clavicle
│   │   │       └── Bip01 R UpperArm
│   │   │           └── Bip01 R Forearm
│   │   │               └── Bip01 R Hand
├── Bip01 L Thigh
│   └── Bip01 L Calf
│       └── Bip01 L Foot
│           └── Bip01 L Toe0
└── Bip01 R Thigh
    └── Bip01 R Calf
        └── Bip01 R Foot
            └── Bip01 R Toe0
```

---

## Appendix B: Animation State Reference

### Locomotion States

| State | Morrowind Name | Blend Type | Transitions To |
|-------|----------------|------------|----------------|
| Idle | `idle` | Single | Walk, Run, Jump |
| Walk | `walkforward` | BlendSpace | Idle, Run, Jump |
| Run | `runforward` | BlendSpace | Walk, Jump |
| Jump | `jump` | Single | Fall, Land |
| Fall | `jumploop` | Single | Land |
| Land | `jumpland` | Single | Idle, Walk |

### Combat States

| State | Morrowind Name | Layer | Notes |
|-------|----------------|-------|-------|
| Combat Idle | `idlecombat` | Full | Replaces normal idle |
| Attack | `attack1` | Upper | OneShot overlay |
| Block | `blockstart` | Upper | Hold pose |
| Hit | `hit1` | Full | Interrupt current |
| Death | `death1` | Full | Final state |

### Action States (OneShot)

| Action | Morrowind Name | Duration | Interruptible |
|--------|----------------|----------|---------------|
| Spell Cast | `spellcast` | 1.5s | Yes |
| Use Item | `useitem` | 1.0s | Yes |
| Pickup | `pickup` | 0.5s | No |
| Activate | `activate` | 0.3s | No |

---

## Appendix C: Configuration Reference

### AnimationManager Exports

```gdscript
@export_group("Blending")
@export var default_blend_time: float = 0.2
@export var fast_blend_time: float = 0.1
@export var slow_blend_time: float = 0.5

@export_group("Root Motion")
@export var use_root_motion: bool = false
@export var root_motion_scale: float = 1.0

@export_group("Debug")
@export var debug_state_changes: bool = false
@export var debug_blend_values: bool = false
```

### IKController Exports

```gdscript
@export_group("Foot IK")
@export var enable_foot_ik: bool = true
@export var foot_raycast_length: float = 1.5
@export var foot_offset: float = 0.05
@export var max_foot_adjustment: float = 0.4
@export var ik_smoothing: float = 10.0

@export_group("Look At IK")
@export var enable_look_at: bool = true
@export var max_look_angle: float = 90.0  # degrees
@export var head_weight: float = 0.8
@export var spine_weight: float = 0.3
@export var look_smoothing: float = 5.0

@export_group("Hand IK")
@export var enable_hand_ik: bool = true
@export var hand_smoothing: float = 15.0
```

### LODController Exports

```gdscript
@export_group("Distance Thresholds")
@export var lod_full_distance: float = 15.0
@export var lod_high_distance: float = 30.0
@export var lod_medium_distance: float = 60.0
@export var lod_low_distance: float = 100.0

@export_group("Update Rates")
@export var full_update_rate: int = 60
@export var high_update_rate: int = 30
@export var medium_update_rate: int = 15
@export var low_update_rate: int = 5
```

---

## Document History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-12-21 | Initial CHARACTER_ANIMATION.md |
| 2.0 | 2025-12-26 | Complete rewrite as design document |

---

**Next Steps:**
1. Review and approve this design
2. Create implementation tasks based on Phase 2 roadmap
3. Begin refactoring existing code into new architecture
