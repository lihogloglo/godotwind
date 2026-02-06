# Animation System

---

## Architecture (V2 System)

**Modular components:**
- `MorrowindCharacterSystem` — NPC animation (`src/core/character/`)
- `CreatureAnimationSystem` — Creature animation
- `AnimationLibrary` — Shared animation storage
- `Skeleton3D` templates — Cached skeletons

**Current status:**
- Animations load from .kf files
- Bone mapping exists (MORROWIND_BONE_MAP, MORROWIND_ANIM_MAP)
- Animation blending is NOT fully working yet
- IK system documented but NOT integrated into production

---

## Animation Retargeting

```gdscript
var skeleton := preload("res://characters/nif_skeleton.tscn").instantiate()
var bone_map := BoneMap.new()
bone_map.profile = SkeletonProfileHumanoid.new()

# Auto-mapping for common names
bone_map.auto_map(skeleton)

# Manual mapping for non-standard Morrowind bones
bone_map.set_skeleton_bone_name("Bip01 Head", "Head")
bone_map.set_skeleton_bone_name("Bip01 L Hand", "LeftHand")
```

**Share animations between skeletons:**
```gdscript
var shared_anim := animation_library.get_animation("walk")
animation_player.add_animation_library("shared", animation_library)
animation_player.play("shared/walk")
```

---

## AnimationTree with State Machine

```gdscript
var anim_tree := AnimationTree.new()
var state_machine := AnimationNodeStateMachine.new()

# Add states
var idle_state := AnimationNodeAnimation.new()
idle_state.animation = "idle"
state_machine.add_node("idle", idle_state)

var walk_state := AnimationNodeAnimation.new()
walk_state.animation = "walk"
state_machine.add_node("walk", walk_state)

# Add transitions
state_machine.add_transition("idle", "walk", auto_advance = false)
state_machine.add_transition("walk", "idle", auto_advance = false)

var idle_to_walk := state_machine.get_transition("idle", "walk")
idle_to_walk.xfade_time = 0.2
idle_to_walk.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END

anim_tree.tree_root = state_machine
```

---

## BlendSpace2D for Locomotion

```gdscript
var blend_space := AnimationNodeBlendSpace2D.new()

blend_space.add_blend_point(idle_anim, Vector2(0, 0))
blend_space.add_blend_point(walk_forward, Vector2(1, 0))
blend_space.add_blend_point(run_forward, Vector2(2, 0))
blend_space.add_blend_point(walk_left, Vector2(1, -1))
blend_space.add_blend_point(walk_right, Vector2(1, 1))

anim_tree.set("parameters/locomotion/blend_position", Vector2(speed, direction))
```

---

## Animation Caching

```gdscript
class_name AnimationCache

static var _skeleton_templates: Dictionary = {}
static var _animation_libraries: Dictionary = {}

static func get_skeleton_template(nif_path: String) -> Skeleton3D:
    if _skeleton_templates.has(nif_path):
        return _skeleton_templates[nif_path]
    var skeleton := _parse_skeleton_from_nif(nif_path)
    _skeleton_templates[nif_path] = skeleton
    return skeleton

static func get_animation_library(kf_path: String) -> AnimationLibrary:
    if _animation_libraries.has(kf_path):
        return _animation_libraries[kf_path]
    var library := _parse_animations_from_kf(kf_path)
    _animation_libraries[kf_path] = library
    return library
```

---

## IK System (TwoBoneIK3D)

> **Status:** API documented and ik_controller.gd exists, but IK is NOT actively used in the character pipeline. This is ready for future integration.

See `docs/GODOT_46_FEATURES.md` for full TwoBoneIK3D API reference.

**Quick reference:**
```gdscript
var ik := TwoBoneIK3D.new()
ik.set_setting_count(1)
ik.set_root_bone_name(0, "UpperLeg")
ik.set_middle_bone_name(0, "LowerLeg")
ik.set_end_bone_name(0, "Foot")
ik.set_target_node(0, path_to_target)
# No start()/stop() — auto-solves as SkeletonModifier3D
# Use ik.active = true/false to enable/disable
```
