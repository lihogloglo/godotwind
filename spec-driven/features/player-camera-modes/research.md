# Research: Player Camera Modes

Date: 2026-05-12
Owner: Codex
Status: research revised; Phase 2 follow/movement code implemented

## Purpose

Godotwind's current third-person player camera can orbit around the character,
and movement is resolved from that camera yaw. This means the same forward input
can move the character in opposite world directions after the camera moves from
behind the character to in front of the character.

This research compares the current Godotwind path with OpenMW 0.51.0 RC2 and
identifies the camera/movement ownership split needed for three player camera
modes:

- first person;
- third-person fixed follow;
- third-person vanity/orbit, where camera position does not remap movement.

## Local Findings

Current player movement and camera input are coupled:

- `PlayerController` owns a `camera_pivot` and rotates it from mouse/gamepad
  look.
- `PlayerInputGatherer` builds `InputPackage.camera_basis` directly from
  `camera_pivot.rotation.y`.
- `Move._get_input_world_direction()` and `MoveContainer._resolve_desired_world_direction()`
  multiply `input_direction` by that camera basis.

Practical effect: orbiting the camera changes the movement reference frame. The
camera rig is both the visual view and the movement basis.

This is correct for a modern camera-relative action controller, but it does not
match the requested behavior or OpenMW's default Morrowind-style behavior.

## OpenMW 0.51.0 RC2 Findings

OpenMW 0.51.0 RC2 was verified from the GitHub release page. The current RC tag
is `openmw-51-rc2` at commit `673981c`.

OpenMW separates camera mode from movement intent:

- `MWRender::Camera::Mode` includes `Static`, `FirstPerson`, `ThirdPerson`,
  `Vanity`, and `Preview`.
- The public Lua camera API describes `ThirdPerson` as a mode where the player
  turns to view direction, `Preview` as third-person where the character does
  not turn to view direction, and `Vanity` as similar to Preview while the
  camera slowly moves around the player.
- Mouse/controller look calls `world->vanityRotateCamera(rot)`. If that returns
  true, look input rotates only the camera. If it returns false and player look
  is allowed, look input rotates the player.
- `World::vanityRotateCamera()` only returns true in Vanity or Preview mode.
  It applies pitch/yaw to the camera, not to the player.
- `RenderingManager::rotateObject()` syncs the camera to the tracked player
  when the tracked object rotates, except in Vanity/Preview.
- `MWMechanics::Movement` stores desired movement relative to the actor's
  current orientation.

Practical effect:

- In OpenMW ThirdPerson, look input turns the player, and the camera follows
  the tracked player direction.
- In OpenMW Vanity/Preview, look input rotates/orbits the camera without turning
  the player, so actor-relative forward remains actor-forward.
- OpenMW's Lua camera script auto-enters Vanity after idle time exceeds the
  Morrowind `fVanityDelay` GMST, rotates camera yaw slowly, and exits to the
  primary first/third-person mode when player input/activity resumes.

OpenMW also has an optional `move360` Lua feature. It deliberately rewrites
movement controls in Preview mode to behave more like a camera-relative modern
controller. That is not the behavior requested here and should not be copied
as the default.

## Movement Animation Clarification

The 2026-05-13 OpenMW player/NPC movement-animation audit corrected a stale
Phase 2 assumption: vanilla Morrowind/OpenMW does not depend on dedicated
diagonal movement clips such as `WalkForwardLeft` or `RunBackRight`.

Local reference:

- `spec-driven/features/movement animation/openmw player-npc movement animation analysis.md`

OpenMW selects cardinal movement groups:

- ground walk/run/sneak: `walkforward`, `walkback`, `walkleft`, `walkright`,
  `runforward`, `runback`, `runleft`, `runright`, `sneakforward`,
  `sneakback`, `sneakleft`, `sneakright`;
- swim walk/run: `swimwalkforward`, `swimwalkback`, `swimwalkleft`,
  `swimwalkright`, `swimrunforward`, `swimrunback`, `swimrunleft`,
  `swimrunright`;
- turns, idles, and jump use their own cardinal/simple groups.

OpenMW's diagonal-looking movement comes from `turn to movement direction`, not
from diagonal clip lookup. When enabled for movable bipeds, OpenMW rotates the
lower body/root toward the local movement vector, slows movement while that
lower-body angle catches up, and applies upper-body compensation while the same
cardinal movement groups continue to play.

Implications for Godotwind:

- Phase 2 fixed follow is not blocked by missing diagonal animation assets.
- `PlayerController` should keep look-owned facing for the camera feature and
  must not re-enable movement-vector facing just to imitate diagonal body
  presentation.
- If Godotwind wants OpenMW-style diagonal presentation, implement it as a
  separate movement-animation/profile feature around turn-to-movement-direction
  pose control and cardinal animation groups.

## OpenMW Code-Shaped Ideas

These are not verbatim ports. They are the implementation ideas that matter for
Godotwind.

### Source anchors to inspect

Use these OpenMW lines as anchors during implementation research:

- `Camera::Vanity` and `Camera::Preview` are distinct modes in
  `apps/openmw/mwrender/camera.hpp`.
- `world->vanityRotateCamera(rot)` is the mouse-look gate in
  `apps/openmw/mwinput/mousemanager.cpp`.
- `mCamera->rotateCamera(rot)` is only reached for Vanity/Preview in
  `apps/openmw/mwworld/worldimp.cpp`.
- `mPosition[0]`, `mPosition[1]`, and `mPosition[2]` in
  `apps/openmw/mwmechanics/movement.hpp` are documented as movement relative to
  actor orientation.

Do not port these files directly. The useful idea is the ownership split:
camera-only modes consume look at the camera layer; normal player modes route
look to actor facing, and movement stays actor-relative.

### Mode enum as behavior contract

OpenMW has separate modes for normal third person and camera-only orbit. The
Godotwind equivalent should be explicit:

```gdscript
enum CameraMode {
	FIRST_PERSON,
	THIRD_PERSON,
	THIRD_PERSON_VANITY,
}
```

`THIRD_PERSON` should mean fixed follow. `THIRD_PERSON_VANITY` should mean the
camera can orbit without changing the movement basis.

### Look input split

OpenMW routes look input through a camera-mode gate: vanity/preview consumes the
look as camera rotation; otherwise player look rotates the player. Godotwind's
equivalent should centralize that split instead of letting movement code infer
it from the camera node:

```gdscript
func _apply_look_delta(yaw_delta: float, pitch_delta: float) -> void:
	if camera_mode == CameraMode.THIRD_PERSON_VANITY:
		_orbit_yaw += yaw_delta
		_orbit_pitch = clampf(_orbit_pitch + pitch_delta, -_tilt_limit_rad, _tilt_limit_rad)
		return
	_facing_yaw += yaw_delta
	_look_pitch = clampf(_look_pitch + pitch_delta, -_tilt_limit_rad, _tilt_limit_rad)
```

The exact owner of `_facing_yaw` still needs implementation research. It may be
the `PlayerController`, `character_root`, or a small facing helper, depending
on what produces the least transform churn in the current scene tree.

### Separate visual yaw from movement yaw

OpenMW keeps movement relative to the actor while Vanity rotates the camera. In
Godotwind, that becomes two explicit accessors:

```gdscript
func _get_visual_camera_yaw() -> float:
	return _orbit_yaw if camera_mode == CameraMode.THIRD_PERSON_VANITY else _facing_yaw

func _get_movement_yaw() -> float:
	return _facing_yaw

func _get_movement_basis() -> Basis:
	return Basis(Vector3.UP, _get_movement_yaw())
```

This is the core fix. `PlayerInputGatherer` should receive this movement basis
from the player/camera mode owner instead of reading `camera_pivot.rotation.y`.

### Primary mode and vanity return

OpenMW tracks a primary first/third-person mode and treats Vanity as a temporary
mode. Godotwind should copy that idea:

```gdscript
var _primary_camera_mode: CameraMode = CameraMode.THIRD_PERSON

func _set_primary_camera_mode(mode: CameraMode) -> void:
	assert(mode != CameraMode.THIRD_PERSON_VANITY)
	_primary_camera_mode = mode
	set_camera_mode(mode)

func _exit_vanity_if_player_is_active() -> void:
	if camera_mode == CameraMode.THIRD_PERSON_VANITY and _has_movement_or_action_input():
		set_camera_mode(_primary_camera_mode)
```

If idle auto-vanity is implemented later, it should enter Vanity only as a
temporary view mode and return to `_primary_camera_mode` on movement/activity.

### Do not copy optional 360 movement by default

OpenMW's optional 360 movement script rotates movement input by the delta
between camera yaw and actor yaw. That is exactly the class of behavior the
user does not want as Godotwind's default.

```gdscript
# Default vanity mode must NOT do this:
# input_direction = input_direction.rotated(camera_yaw - actor_yaw)
```

Such behavior could be a future optional modern-control preset, but it should
be a separate spec.

## Canonical Pattern

The canonical pattern is to keep two explicit frames of reference:

1. Visual camera transform: where the camera is and what it is looking at.
2. Movement reference transform: what forward/back/left/right mean.

OpenMW's implementation is one concrete example of this pattern:

- ThirdPerson: visual camera follows the actor; movement is actor-relative
  because look has rotated the actor.
- Vanity/Preview: visual camera can orbit; movement stays actor-relative
  because the actor has not rotated with the camera.

For Godotwind, the same principle should be implemented generically rather than
copying OpenMW's exact C++/Lua architecture.

## Godot 4.6 Research Update

The 2026-05-12 research pass re-checked current Godot docs before runtime
implementation. The existing direction still holds, with one important
interpolation refinement.

### SpringArm3D

Godot's `SpringArm3D` remains the native feature for third-person camera
collision. The class casts a ray or optional shape along its Z axis, moves its
direct children inward when blocked, supports `spring_length`, `collision_mask`,
`margin`, and can exclude the player's own physics body by RID.

Implications for Godotwind:

- Keep `SpringArm3D` for first implementation slices.
- Keep an explicit collision mask instead of broad world queries.
- Exclude the player body from the spring-arm collision check after the body RID
  exists. Godotwind currently does not call `spring_arm.add_excluded_object(get_rid())`;
  add this during implementation unless a local collision-layer audit proves the
  current mask cannot hit the player.
- Do not introduce a custom ray/shape camera collision solver unless
  `SpringArm3D` fails a concrete validation case.
- A custom `Shape3D` on the arm can be a later polish item if ray-only collision
  allows near-wall clipping, but it is not required for the camera/movement
  split.

### Camera3D and interaction rays

`Camera3D` does not change the camera-mode architecture. Its relevant built-in
helpers are still view-space/ray helpers such as `project_ray_origin()` and
`project_ray_normal()`. If interaction targeting is revised during vanity work,
the ray should follow the active view camera; movement should continue to use
the explicit movement reference.

### Physics interpolation and camera timing

Godot's interpolation docs support the current `camera_pivot.physics_interpolation_mode = OFF`
carve-out for mouse look, but they also recommend a manual camera-follow pattern
for sensitive cameras: update the camera in `_process()`, read the follow target
with `Node3D.get_global_transform_interpolated()`, and keep the camera transform
independent of a moving parent when doing full manual interpolation. The docs
also state `reset_physics_interpolation()` should be called after a discontinuous
transform change, not before it.

Implications for Godotwind:

- Phase 1 should not move the whole camera rig. Keep the existing camera pivot
  carve-out while the movement basis is split from visual camera yaw.
- If fixed follow or vanity introduces visible shimmer after yaw ownership
  changes, the proper next step is a small manual camera-follow rig that either
  lives on an independent branch or is `top_level`, follows the player's
  interpolated transform in `_process()`, and applies render-rate mouse yaw/pitch
  locally.
- Mode transitions that jump camera orientation or distance should reset
  interpolation after applying the new transform.
- If implementation calls `get_global_transform_interpolated()` for a follow
  target, prime it before teleport/reset validation so the interpolation pump is
  established.

### InputMap

Godot's `InputMap` API continues to fit project policy: actions are registered
by name, `InputEvent`s are attached to actions, deadzones are action-level data,
and project actions can be reloaded from ProjectSettings. The project-local
input-system doc remains correct that mouse motion is not a normal action-vector
source for look; mouse look should stay in `_input`/`_unhandled_input`, while
gamepad look can keep using `InputMap` actions.

Implications for Godotwind:

- Any explicit vanity control must be an `InputMap` action in `project.godot`
  and `src/core/input/input_actions.gd`.
- Do not route mouse motion through `Input.get_vector("look_*")`.
- Avoid runtime-only key registration for the new camera mode except as the
  existing defensive safety net.

## Public Godot 4 Examples Surveyed

These examples are useful as pattern evidence, not implementation source. Most
public Godot third-person controllers intentionally make movement camera-relative,
which is exactly the behavior Godotwind must avoid in vanity mode.

| Example | License / Version | Node Structure | Movement Model | Useful Idea | Do Not Copy |
| --- | --- | --- | --- | --- | --- |
| GDQuest `godot-4-3d-third-person-controller` / RoboBlast | MIT code, CC-BY 4.0 assets. Godot 4 demo, original release required Godot 4 beta 7; repository is still active. | `Player` `CharacterBody3D` owns a `CameraController` `Node3D`; camera controller owns `SpringArm3D`, pivots, `Camera3D`, and a camera raycast. | Camera-relative. Player input is multiplied by camera controller basis; aim mode points movement/facing toward camera aim. | Good separation of a camera-controller component from movement code; good use of `SpringArm3D.add_excluded_object()` and a camera raycast for aim/interaction style targeting. | Its movement transform is the current Godotwind bug class. Do not copy its camera-relative movement as vanity behavior. |
| Selgesel `godot4-third-person-controller` | MIT. Godot 4 only; latest listed release is `0.1.2 - Godot 4 Release Version Compatibility` from 2023-03-10. | Player scene contains `ControllableCamera`, states, and mobile/touch controls. | Camera/look-direction-relative. README states touch drag moves/swims in current look direction; underwater swimming is affected by camera horizontal and vertical angles. | Useful input-surface split between movement gesture, camera gesture, zoom, desktop, and touch. | Do not copy camera-pitch-driven swim intent into vanity mode; that would preserve the current coupling. |
| JeanKouss `godot-third-person-camera` | MIT. Godot Asset Library version 1.5.0, supported engine 4.0. | Camera addon scene `ThirdPersonCamera.tscn` is added as a child of a character or target node and exposes Camera3D properties. | Camera-only addon; movement policy belongs to the host controller. | Useful as evidence that a reusable camera component can support dynamic follow, fixed perspective, shoulder, and over-the-shoulder variants without owning locomotion. | Do not import the addon for this feature; Godotwind already has the required rig and needs a movement-reference contract, not a wholesale camera package. |

## Industry Pattern Cross-Check

Unity Cinemachine's Third Person Follow docs frame the camera as tracking a
target rig; direct camera input is provided by rotating the target, and the
target may be an invisible object that rotates independently from the character
model. Unreal exposes the same broad separation through controller/view rotation,
camera boom control rotation, and character movement rotation settings.

The shared pattern is not "always move relative to the camera." The shared
pattern is to name the reference frame that owns movement and the target frame
that owns camera/aim, then choose per mode whether those frames are the same
object or intentionally decoupled.

## Recommendation

Add a small player-camera mode contract around the existing `PlayerController`
and `CharacterMotor` path:

- Keep `PlayerController` as the owner of player camera/input mode.
- Keep `SpringArm3D` for third-person collision avoidance.
- Extend the current camera mode enum so the existing `THIRD_PERSON` behavior
  becomes fixed follow, and add a separate `THIRD_PERSON_VANITY` mode.
- Split `InputPackage.camera_basis` into a movement-facing basis supplied by
  the player/camera mode owner. A future rename to `movement_basis` would make
  the contract honest.
- For first person and fixed follow, mouse/controller yaw changes the player
  facing and the camera follows that facing.
- For vanity, mouse/controller yaw/pitch changes only the orbit camera. Movement
  input still uses the actor-facing basis, not the orbit camera basis.
- For swimming, do not let vanity camera pitch create vertical swim intent.
  The input package should carry an explicit movement/look pitch chosen by the
  active mode.

This is a small architecture correction, not a new input framework. It preserves
the current Move-as-Node movement system and fixes the root cause by separating
visual camera orientation from movement orientation.

## Remaining Research Before Coding

The pre-code research gate is complete as of 2026-05-12. Before a future
implementation session edits runtime files, re-open the official docs only if
Godotwind has upgraded engine versions or if the implementation chooses the
manual top-level camera-follow refinement. No surveyed public example changes
the core plan.

## Sources

Local:

- `spec-driven/README.md`
- `spec-driven/00-constitution.md`
- `spec-driven/01-workflow.md`
- `docs/systems/character_controller.md`
- `docs/systems/input_system.md`
- `src/core/player/player_controller.gd`
- `src/core/character/controller/player_input_gatherer.gd`
- `src/core/character/controller/input_package.gd`
- `src/core/character/controller/move.gd`
- `src/core/character/controller/move_container.gd`
- `src/core/character/controller/moves/swim_move.gd`

External:

- OpenMW 0.51.0 RC2 release: https://github.com/OpenMW/openmw/releases/tag/openmw-51-rc2
- OpenMW camera modes API: https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_camera.html
- OpenMW `Camera::Mode`: https://github.com/OpenMW/openmw/blob/openmw-51-rc2/apps/openmw/mwrender/camera.hpp#L29-L36
- OpenMW third-person camera position/collision: https://github.com/OpenMW/openmw/blob/openmw-51-rc2/apps/openmw/mwrender/camera.cpp#L160-L209
- OpenMW camera mode switching: https://github.com/OpenMW/openmw/blob/openmw-51-rc2/apps/openmw/mwrender/camera.cpp#L217-L245
- OpenMW vanity/preview camera rotation gate: https://github.com/OpenMW/openmw/blob/openmw-51-rc2/apps/openmw/mwworld/worldimp.cpp#L2196-L2205
- OpenMW mouse look player-vs-camera split: https://github.com/OpenMW/openmw/blob/openmw-51-rc2/apps/openmw/mwinput/mousemanager.cpp#L239-L245
- OpenMW actor-relative movement data: https://github.com/OpenMW/openmw/blob/openmw-51-rc2/apps/openmw/mwmechanics/movement.hpp#L8-L15
- OpenMW bundled Lua camera script vanity behavior: https://github.com/OpenMW/openmw/blob/openmw-51-rc2/files/data/scripts/omw/camera/camera.lua#L111-L124
- OpenMW bundled Lua third-person script: https://github.com/OpenMW/openmw/blob/openmw-51-rc2/files/data/scripts/omw/camera/third_person.lua#L129-L161
- OpenMW optional 360 movement script: https://github.com/OpenMW/openmw/blob/openmw-51-rc2/files/data/scripts/omw/camera/move360.lua#L54-L81
- Godot `SpringArm3D` docs: https://docs.godotengine.org/en/stable/classes/class_springarm3d.html
- Godot `Camera3D` docs: https://docs.godotengine.org/en/stable/classes/class_camera3d.html
- Godot `InputMap` docs: https://docs.godotengine.org/en/stable/classes/class_inputmap.html
- Godot `Node.reset_physics_interpolation()` docs: https://docs.godotengine.org/en/stable/classes/class_node.html#class-node-method-reset-physics-interpolation
- Godot `Node3D.get_global_transform_interpolated()` docs: https://docs.godotengine.org/en/stable/classes/class_node3d.html#class-node3d-method-get-global-transform-interpolated
- Godot physics interpolation docs: https://docs.godotengine.org/en/stable/tutorials/physics/interpolation/using_physics_interpolation.html
- Godot advanced physics interpolation camera notes: https://docs.godotengine.org/en/latest/tutorials/physics/interpolation/advanced_physics_interpolation.html
- GDQuest Godot 4 third-person controller: https://github.com/gdquest-demos/godot-4-3d-third-person-controller
- GDQuest controller license: https://github.com/gdquest-demos/godot-4-3d-third-person-controller/blob/main/LICENSE
- Selgesel Godot 4 third-person controller: https://github.com/selgesel/godot4-third-person-controller
- JeanKouss Godot third-person camera addon: https://github.com/JeanKouss/godot-third-person-camera
- JeanKouss addon Asset Library entry: https://godotassetlibrary.com/asset/emvi4w/third-person-camera
- Unity Cinemachine Third Person Follow: https://docs.unity.cn/Packages/com.unity.cinemachine%403.1/manual/ThirdPersonCameras.html
- Unreal Controller rotation reference: https://dev.epicgames.com/documentation/en-us/unreal-engine/python-api/class/Controller?application_version=5.5
