# OpenMW Player/NPC Movement Animation Analysis

Date: 2026-05-13
OpenMW source audited: `openmw-master`, branch `master`, commit `55e3585`
Requested filename note: Windows cannot store `/` inside a filename, so this file uses `player-npc`.

## Scope

This is a source audit of how OpenMW chooses, names, plays, blends, and extracts movement from player, humanoid NPC, and beast-race NPC animations. It focuses on the player/NPC path, not general creature animation, combat animation timing, or NIF import internals except where they affect movement.

OpenMW should be treated as a Morrowind compatibility reference for Godotwind, not as architecture to copy wholesale. The useful pattern is the separation between desired movement, animation-state selection, animation asset resolution, playback/blending, and final motion application.

## High-Level Findings

OpenMW uses one `CharacterController` state machine for both the player and NPCs. Player input, AI packages, Lua controls, and obstacle avoidance all write into the same `MWMechanics::Movement` intent object. The controller then reads world state, actor stances, race/skeleton data, available animation groups, and game settings to choose a movement animation group name.

The core movement group names are simple lowercase text-key groups: `walkforward`, `runback`, `swimwalkleft`, `sneakright`, `turnleft`, and so on. Weapon-ready variants are built by adding short suffixes such as `1h`, `2c`, `bow`, or `spell` to non-swimming movement groups when those variants exist.

Humanoid and beast races share the same movement state names and controller logic. Beast races differ at the asset layer: OpenMW selects `base_animkna` skeletons for beast races, and Argonians in third person get an extra high-priority `xargonian_swimkna` animation source for custom swim behavior.

OpenMW normally uses animation root motion for third-person movement, then queues that motion into physics. First-person player movement is a major exception: first-person animations lack usable root velocity, so OpenMW uses hardcoded fallback movement speeds and marks that movement as not animation-controlled.

## Source Map

- Movement intent: `openmw-master/apps/openmw/mwmechanics/movement.hpp:8`
- Character states and controller fields: `openmw-master/apps/openmw/mwmechanics/character.hpp:48`
- Movement state to animation group names: `openmw-master/apps/openmw/mwmechanics/character.cpp:124`
- Movement animation resolution and fallback: `openmw-master/apps/openmw/mwmechanics/character.cpp:641`
- Per-frame movement state selection: `openmw-master/apps/openmw/mwmechanics/character.cpp:1965`
- Root-motion application and movement queuing: `openmw-master/apps/openmw/mwmechanics/character.cpp:2450`
- Movement animation control gate: `openmw-master/apps/openmw/mwmechanics/character.cpp:2719`
- Direction capability masks for AI: `openmw-master/apps/openmw/mwmechanics/character.cpp:3152`
- Animation playback/core root-motion extraction: `openmw-master/apps/openmw/mwrender/animation.cpp:886`, `openmw-master/apps/openmw/mwrender/animation.cpp:1272`, `openmw-master/apps/openmw/mwrender/animation.cpp:1340`
- NPC race/skeleton/animation source selection: `openmw-master/apps/openmw/mwrender/npcanimation.cpp:452`
- Actor skeleton selection helper: `openmw-master/apps/openmw/mwrender/actorutil.cpp:5`
- Model settings and default animation assets: `openmw-master/files/settings-default.cfg:1080`
- Weapon short group table: `openmw-master/apps/openmw/mwmechanics/weapontype.cpp:20`
- AI pathing using supported movement directions: `openmw-master/apps/openmw/mwmechanics/aipackage.cpp:99`
- Launcher smoothness setting defaults: `openmw-master/files/settings-default.cfg:300`, `openmw-master/files/settings-default.cfg:339`
- Smooth movement and turn-to-movement core logic: `openmw-master/apps/openmw/mwmechanics/character.cpp:2031`, `openmw-master/apps/openmw/mwmechanics/character.cpp:2080`
- Smooth animation-transition controller setup: `openmw-master/apps/openmw/mwrender/animation.cpp:742`, `openmw-master/apps/openmw/mwrender/animblendcontroller.cpp:163`

## Core Data Flow

1. Input, AI, scripts, or Lua write local-space desired movement into `Movement.mPosition`.
   - `mPosition[0]`: side movement.
   - `mPosition[1]`: forward/back movement.
   - `mPosition[2]`: jump or vertical movement intent.
   - `mRotation[0..2]`: pitch/roll/yaw deltas.
   - The vector length controls desired speed, with `1.0` meaning max speed.

2. `CharacterController::update` reads that intent once per frame and computes:
   - whether the actor is player, first person, on ground, swimming, flying, solid, sneaking, or running;
   - normalized movement direction and `mSpeedFactor`;
   - whether the actor should strafe, turn lower body toward movement, or play a pure turn animation.

3. The controller selects three independent state buckets:
   - `idlestate`: `idle`, `idlesneak`, `idleswim`, or special scripted idle;
   - `movestate`: walk/run/sneak/swim/turn directional state;
   - `jumpstate`: none, in-air, or landing.

4. `refreshCurrentAnims` updates hit, jump, movement, then idle animation. Idle runs last because it depends on whether movement/hit/scripted states are active.

5. `refreshMovementAnims` converts the movement state to a group name, applies fallbacks, checks whether the animation exists, calculates animation velocity, and calls `playBlendedAnimation`.

6. `MWRender::Animation::play` resolves the group through active animation sources, using later-added sources as higher priority. It creates an `AnimState`, binds the relevant controllers per bone group, and uses text keys such as `start`, `loop start`, `loop stop`, and `stop`.

7. `runAnimation` advances active animation states and returns accumulated root movement from the accumulation bone. `CharacterController` then decides whether to use this root motion or the direct movement vector and queues the result with `world->queueMovement`.

## Movement Animation Names

These names are the core player/NPC movement animation groups OpenMW expects from NIF/KF text keys.

| Situation | Group names |
| --- | --- |
| Ground walk | `walkforward`, `walkback`, `walkleft`, `walkright` |
| Ground run | `runforward`, `runback`, `runleft`, `runright` |
| Ground sneak | `sneakforward`, `sneakback`, `sneakleft`, `sneakright` |
| Swim walk | `swimwalkforward`, `swimwalkback`, `swimwalkleft`, `swimwalkright` |
| Swim run | `swimrunforward`, `swimrunback`, `swimrunleft`, `swimrunright` |
| Ground turn | `turnleft`, `turnright` |
| Swim turn | `swimturnleft`, `swimturnright` |
| Idle support | `idle`, `idlesneak`, `idleswim` |
| Jump support | `jump` |

OpenMW also treats these movement and idle names as looping even if loop text keys are absent. It also recognizes suffixed weapon variants of looped groups by stripping known weapon short groups before checking the hardcoded looping set.

## How Movement State Is Chosen

OpenMW chooses movement by reading the normalized local vector after speed smoothing:

- If `movementSettings.mIsStrafing` is true, positive X selects right movement and negative X selects left movement.
- If not strafing and there is horizontal movement, non-negative Y selects forward and negative Y selects back.
- If there is no horizontal movement, a turning actor may play `turnleft`, `turnright`, `swimturnleft`, or `swimturnright`.
- Turn animations are only used for biped actors, not in first person, and not while sneaking.
- Swimming swaps walk/run/turn states to the `swim*` families.
- Sneaking swaps ground walk/run states to `sneak*`, but sneak is disabled while swimming or flying.
- Running is ignored while flying.
- If in water, idle becomes `idleswim` even if another idle would otherwise be selected.

The `turn to movement direction` setting changes biped behavior. When disabled, side input mostly becomes strafe when X is much larger than Y. When enabled and not in first person, OpenMW can rotate the lower body toward travel direction, rotate upper body partly, slow movement during sharp lower-body turns, and only keep strafing for drawn weapons or swimming at large side angles.

The `smooth movement` setting filters movement direction and speed before state selection. This affects animation selection because the state machine sees the smoothed vector, not raw input.

## Playback and Blending Pattern

Movement animations are played with `Priority_Movement`, usually over `BlendMask_All`, from `start` to `stop`, with effectively infinite loops and loop fallback enabled. OpenMW's animation system has four bone groups: lower body, torso, left arm, and right arm. Each active animation carries a priority per bone group. On reset, each bone group chooses the active animation with the highest priority for that group.

Weapon animations can override upper-body groups while movement remains active. For biped actors, weapon priority is high on the upper body but intentionally lower on the lower body, so locomotion keeps control of legs. Non-bipeds invert that expectation: movement takes priority over weapon blending.

Root and posture offsets are applied outside the source animations:

- `setLegsYawRadians` rotates the lower body/root for movement-direction alignment.
- `setUpperBodyYawRadians` partially counters or follows lower-body yaw.
- `setBodyPitchRadians` pitches the body while swimming when `turn to movement direction` is enabled.
- Head tracking is layered separately.

## Root Motion and Actual Movement

For actors, OpenMW sets animation accumulation to X/Y only. The accumulation root is detected from `bip01` first, then `root bone`. During `runAnimation`, if the lower-body active animation owns that root controller, OpenMW samples translation delta from the animation and returns it as movement for this frame.

That returned animation movement can replace the originally calculated movement vector when `isMovementAnimationControlled()` is true. This reproduces Morrowind-style third-person movement where the visible animation affects actual travel. OpenMW then rotates root-motion movement toward the intended direction for diagonal movement because many diagonal directions do not have dedicated animation groups.

Movement is not animation-controlled when:

- the actor is in a jump;
- `player movement ignores animation` is enabled and the actor is the player;
- a selected movement animation has no meaningful root velocity, which happens for first-person player animations.

Hit and death states always count as animation-controlled. Idle also counts as animation-controlled when there is no movement state.

## Speed Scaling

OpenMW calculates animation velocity from the accumulation root between movement text keys. It adjusts the active movement animation speed so animation pace matches the actor's gameplay speed.

Important quirks:

- Non-flying creatures use equivalent walk animation velocity to scale run movement. OpenMW notes this is required for Morrowind compatibility.
- If animation velocity is missing or too small for player/NPC movement, OpenMW falls back to hardcoded third-person values:
  - sneak: `33.5452`
  - walk: `154.064`
  - run: `222.857`
- This fallback marks `mMovementAnimationHasMovement = false`, so the gameplay movement vector drives motion instead of root motion.
- Runtime animation speed multiplier is capped at `10.0`. If root motion is controlling movement and the gameplay speed needs more than that, OpenMW scales the queued movement to keep actual travel speed correct.

## Fallback Resolution

Movement animation resolution follows this order:

1. Start with the group from `movementStateToAnimGroup`.
2. If it is a swimming group and the exact group is missing, remove the `swim` prefix: `swimrunforward` can fall back to `runforward`, `swimwalkleft` to `walkleft`, and `swimturnright` to `turnright`.
3. If it is not a swimming group and the actor has a weapon/spell short group, try a weapon-specific group:
   - normal movement uses `base + shortGroup`, such as `walkforward1h`;
   - spell turning uses `spell + base`, such as `spellturnleft`.
4. If the weapon-specific group is missing, fall back to canonical one-handed or two-handed groups where appropriate.
5. If a run group is still missing, replace `run` with `walk`.
6. If no group exists after fallback, reset the movement animation state.

Idle fallback is separate:

- `idleswim` and `idlesneak` are only used if they exist.
- Otherwise OpenMW falls back to `idle`, then tries weapon-specific idle variants when relevant.

Jump fallback is also separate:

- It tries `jump + shortGroup`, for example `jump1h`.
- If missing, it falls back through the same weapon short-group fallback path.
- In-air playback starts from `start` or `loop start`; landing plays from `loop stop` to `stop`.

## Weapon Short Groups

OpenMW's movement and idle variant suffixes come from the weapon type table.

| Short group | Typical meaning |
| --- | --- |
| `1h` | one-handed fallback, pick/probe |
| `1s` | short blade one hand |
| `1b` | blunt/axe one hand |
| `2c` | two-handed close, long blade two hand |
| `2b` | two-handed blunt/axe |
| `2w` | two-handed wide, spear/wide blunt |
| `bow` | bow |
| `crossbow` | crossbow |
| `1t` | thrown weapon |
| `hh` | hand to hand |
| `spell` | spell stance |

Examples OpenMW can request when groups exist:

- `walkforward1h`
- `runback2c`
- `walkleftbow`
- `turnrightcrossbow`
- `spellturnleft`
- `idlehh`
- `jump1h`

Swimming movement does not get weapon suffixes because the fallback path only appends weapon short groups after confirming the selected group is not a swim group.

## Launcher Smoothness Settings

OpenMW exposes three relevant launcher settings in the Animations tab:

- `smooth movement = false`
- `turn to movement direction = false`
- `smooth animation transitions = false`

They are separate systems. `smooth movement` changes the input/AI movement vector before animation selection. `turn to movement direction` changes how biped bodies are rotated relative to that movement vector. `smooth animation transitions` changes how render controllers blend between animation tracks after an animation group has already been selected.

### Smooth Movement

`smooth movement` is implemented mostly in `CharacterController::update`, with supporting AI/steering changes.

Without this setting, OpenMW uses the current desired local movement vector directly. With the setting enabled, OpenMW keeps a persistent `mSmoothedSpeed` vector in world-facing 2D space:

1. Rotate the current local input vector by negative actor yaw into a stable reference frame.
2. Multiply by `movementSettings.mSpeedFactor`.
3. Compare that target vector to `mSmoothedSpeed`.
4. Clamp the per-frame delta by a context-dependent maximum.
5. Rotate the smoothed vector back into actor-local space.
6. Recompute `movementSettings.mSpeedFactor` from the smoothed vector length.

The max delta rules are:

| Case | Max smoothing delta |
| --- | --- |
| First-person player | instant, `1` |
| Mostly turning, not changing speed | player: `duration / smooth movement player turning delay`; NPC: `duration * 6` |
| Player stopping | instant, `1` |
| Other acceleration/deceleration | `duration * 3` |

The default player turning delay is `0.333` seconds. OpenMW also has a small backward/forward hysteresis guard: when smoothed movement crosses the forward/back axis, it biases `vec.y` with a tiny epsilon instead of immediately flipping `mIsMovingBackward`. This avoids animation state jitter around zero.

For NPCs and AI, `smooth movement` also changes pathing behavior:

- `smoothTurn` reduces angular velocity near the target angle by multiplying the turn limit by `min(absDiff / pi + 0.1, 0.5)`.
- Path following enables `UpdateFlag_ShortenIfAlmostStraight`, which removes nearly-straight intermediate path points when a navmesh shortcut is valid.
- Near path points, AI may use diagonal local movement `sin(diffAngle), max(cos(diffAngle), 0)` instead of only walking straight forward and snapping rotation.
- `Actors::updateMovementSpeed` early-outs when smooth movement is enabled, so the older "slow down near variable-speed AI destination" behavior is bypassed.
- Greeting turn-to-player behavior becomes less eager: with smooth movement enabled, actors only enter the explicit turn-to-player state when the angle is over 60 degrees.

Practical effect: movement intent becomes a small acceleration/turning model. The animation selector still asks for the same animation names, but it receives a less abrupt direction and speed factor, so state changes and speed multipliers change less sharply.

### Turn To Movement Direction

`turn to movement direction` only affects biped actors and is skipped for the first-person player. It is not an animation blend by itself; it is a layered pose/rotation policy around the same movement animation names.

When disabled, or when the actor is non-biped/first-person, OpenMW:

- sets `movementSettings.mIsStrafing` only when side movement is much larger than forward/back movement: `abs(x) > abs(y) * 2`;
- clears `stats.sideMovementAngle` to `0`;
- leaves the whole body oriented to view/facing direction.

When enabled for a movable biped, OpenMW:

1. Computes a target lower-body movement angle from the local movement vector:
   - forward-ish movement uses `atan2(-x, y)`;
   - backward-ish movement uses `atan2(x, -y)`.
2. Decides whether the actor should still strafe. In combat/drawn state or water, side angles over 60 degrees become strafing and target lower-body angle is forced back to `0`.
3. Computes delta from the current `sideMovementAngle`.
4. Slows movement while the lower body is turning by multiplying speed factor by `clamp(cos(delta), 0..1) + 0.3`, capped at `1`.
5. Updates the backward/forward mode only once the lower-body delta is within 20 degrees.
6. Clamps lower-body turn rate by `pi * duration * (2.5 - cos(delta))`.
7. Adds that lower-body delta into `effectiveRotation`, which feeds pure turn animation selection when not translating.

Then it layers pose yaw into the render animation:

- legs/root yaw gets the full `sideMovementAngle`;
- upper body gets half of that yaw when unarmed or swimming;
- upper body gets one quarter of that yaw when in a drawn/combat state;
- if `smooth movement` is also enabled for a non-player NPC on land, head yaw contributes an extra half-head-yaw upper-body adjustment.

This is why the launcher description says diagonal movement becomes realistic. The character can keep the head/view direction while the lower body turns into the travel direction. In combat, the body remains more forward-facing and uses strafing for large side movement.

Swimming gets one extra turn-to-movement behavior: for biped swim forward/back movement, OpenMW gradually pitches the body toward the actor's pitch at up to `3 radians/second`. If the setting is not active, first person is active, or the movement is not a forward/back swim, body pitch is reset to zero.

### Smooth Animation Transitions

`smooth animation transitions` lives in the render animation layer, not in `CharacterController` movement-state selection.

When OpenMW loads an animation source and this setting is enabled, it loads blending rules:

1. Build a per-source blend config path by changing the `.kf` source name to `.yaml`.
2. For actors, load the global actor config `animations/animation-config.yaml`.
3. If a per-source override config exists, append its rules after the global rules.
4. Store the resulting `AnimBlendRules` on the animation source.

When active animation groups are reset, OpenMW normally attaches the raw `KeyframeController` callback to each animated node. With smooth transitions enabled, it wraps those callbacks:

- `NifAnimBlendController` for `NifOsg::MatrixTransform` nodes.
- `BoneAnimBlendController` for `osgAnimation::Bone` nodes.
- `BoneAnimBlendControllerWrapper` for child bones beneath a blended bone root.

The wrapper is reused per node. When the active group, start key, or keyframe track changes, `setKeyframeTrack` marks a blend trigger and finds a rule matching:

- previous group name;
- previous start key;
- new group name;
- new start key.

Rules support wildcard matching at the beginning or end, plus `$` as "same group" for destination group. The search runs from the bottom of the rule list upward, so later override rules have higher priority.

The default global config uses:

| Transition | Easing | Duration |
| --- | --- | --- |
| Any unmatched transition | `sineOut` | `0.25` |
| Anything to `idlesneak*` or `sneakforward*` | `springOutWeak` | `0.4` |
| Anything to attack prep keys like `*:shoot*`, `*:chop*`, `*:thrust*`, `*:slash*` | `sineOut` | `0.1` |
| Attack prep to attack key, `*:*start` -> `*:*attack` | `sineOut` | `0.05` |
| Weapon swing to follow-through, `*` -> `*:*follow start` | `linear` | `0` |
| Jump start to anything | `sineOut` | `0.1` |
| To/from inventory poses | `linear` | `0` |
| From no-state `""` to anything | `linear` | `0` |

At runtime, the blend controller samples the old transform at the exact point of change, then blends toward the new animation's sampled transform over the rule duration. Rotation uses quaternion slerp. Translation uses linear interpolation. Scale is not blended because OpenMW assumes scale tracks are often used to instantly hide/show parts.

For bone animation, OpenMW gathers recursive bone transforms before the next update because the root bone itself may be part of the blend. Child wrapper callbacks then apply the same interpolation down the bone subtree after the new animation sample has been evaluated.

For NIF matrix transforms, OpenMW also compensates for nested rotate-controller offsets so first-person camera/hand transitions do not jump when a rotate controller sits after the blend controller in the callback chain.

Practical effect: selected movement groups do not change, but the visible skeleton no longer snaps from the previous pose to the next pose. The transition is data-driven by YAML/JSON rules and mod-overridable per animation source.

## Player-Specific Behavior

The player and NPCs use the same controller. The player is updated after other actors so cell transitions and deferred preview rotations can be handled safely.

First-person player behavior differs from third person:

- First-person uses first-person skeleton/animation assets.
- First-person does not play turn locomotion animations.
- First-person animations lack root velocity, so OpenMW uses fallback movement speeds and direct movement.
- Player death forces a switch to third-person death camera because first-person animations do not include death.

The default setting `player movement ignores animation = false` means third-person player movement is animation-driven, including the visible camera sway and vanilla animation movement oddities. Enabling it makes player movement ignore animation root motion, matching older OpenMW behavior.

## NPC and AI Behavior

NPC AI writes to the same movement intent object as the player path. For example, path following sets forward movement toward path points, combat rotates combat-local movement into actor-local movement, and obstacle avoidance may request side/back evasive movement.

AI also queries `CharacterController::getSupportedMovementDirections()`. That function asks the animation system which loaded group names end in `forward`, `back`, `left`, or `right`, using the same fallback families as movement resolution. Obstacle avoidance uses this mask so it prefers evasive directions that have an available animation.

This is an important design pattern for Godotwind: animation availability is not just visual metadata. In OpenMW it feeds AI movement choices.

## Humanoid, Female, Beast, and Argonian Asset Selection

The state machine does not branch into separate humanoid and beast movement names. The race-specific behavior happens when `NpcAnimation::updateNpcBase` chooses skeletons and animation sources.

Default model selection:

| Actor case | Third-person skeleton/source behavior |
| --- | --- |
| Normal male humanoid | base source `xbase_anim.nif`, default skeleton `base_anim.nif` |
| Female humanoid | base source `xbase_anim.nif`, default skeleton `base_anim_female.nif` |
| Beast race | base source `xbase_anim.nif`, default skeleton `base_animkna.nif` |
| Argonian beast | beast setup plus `xargonian_swimkna.nif` as an extra source |
| Werewolf | `wolf/skin.nif` path, outside this humanoid/beast audit |

First-person selection:

| Actor case | First-person skeleton/source behavior |
| --- | --- |
| Normal male humanoid | `xbase_anim.1st.nif` |
| Female humanoid | `xbase_anim.1st.nif` plus `base_anim_female.1st.nif` |
| Beast race | `xbase_anim.1st.nif` plus `base_animkna.1st.nif` |
| Argonian beast | no special Argonian swim source in first person |
| Werewolf | `wolf/skin.1st.nif` path |

Animation source priority is source insertion order: later sources are searched first. That means a custom NPC model can override default animation groups, and Argonian swim is inserted last for eligible Argonians, giving it priority for groups it contains.

The `Beast` flag comes from the race record. Argonian detection is string-based on the race id containing `argonian`, and only applies when not first person and not werewolf.

## Default Animation Asset Settings

OpenMW's defaults are configured in `settings-default.cfg`:

- `xbaseanim = meshes/xbase_anim.nif`
- `baseanim = meshes/base_anim.nif`
- `xbaseanim1st = meshes/xbase_anim.1st.nif`
- `baseanimkna = meshes/base_animkna.nif`
- `baseanimkna1st = meshes/base_animkna.1st.nif`
- `xbaseanimfemale = meshes/xbase_anim_female.nif`
- `baseanimfemale = meshes/base_anim_female.nif`
- `baseanimfemale1st = meshes/base_anim_female.1st.nif`
- `xargonianswimkna = meshes/xargonian_swimkna.nif`
- `xbaseanimkf = meshes/xbase_anim.kf`
- `xbaseanim1stkf = meshes/xbase_anim.1st.kf`
- `xbaseanimfemalekf = meshes/xbase_anim_female.kf`
- `xargonianswimknakf = meshes/xargonian_swimkna.kf`

When `addAnimSource` receives a `.nif`, OpenMW looks for the corresponding `.kf`. It can also load extra animation sources from the `animations/` folder when the relevant setting is enabled.

## Exhaustive Default File-to-Movement Mapping

Important limit: the OpenMW source tree does not include Bethesda's actual NIF/KF assets, so source audit can prove which files OpenMW selects and which movement group names it asks for. It cannot prove the exact text-key contents of every game-data file without inspecting the game assets. In the tables below, "associated movement names" means the movement groups OpenMW may resolve from that file when the file is in the actor's animation-source stack.

OpenMW derives runtime keyframe filenames by changing the selected `.nif` source to `.kf`. The explicit `*kf` settings are used for preloading common assets; the active animation path itself is driven by `addAnimSource`.

### Movement Group Sets

| Set | Movement names |
| --- | --- |
| Ground walk | `walkforward`, `walkback`, `walkleft`, `walkright` |
| Ground run | `runforward`, `runback`, `runleft`, `runright` |
| Ground sneak | `sneakforward`, `sneakback`, `sneakleft`, `sneakright` |
| Ground turn | `turnleft`, `turnright` |
| Swim walk | `swimwalkforward`, `swimwalkback`, `swimwalkleft`, `swimwalkright` |
| Swim run | `swimrunforward`, `swimrunback`, `swimrunleft`, `swimrunright` |
| Swim turn | `swimturnleft`, `swimturnright` |
| Movement idles | `idle`, `idlesneak`, `idleswim` |
| Jump | `jump` |

For non-swimming movement, OpenMW can also request weapon/spell variants. The full suffix set is `1h`, `1s`, `1b`, `2c`, `2b`, `2w`, `bow`, `crossbow`, `1t`, `hh`, and `spell`. This means the possible non-swim movement variant names are:

| Base movement names | Variant pattern |
| --- | --- |
| `walkforward`, `walkback`, `walkleft`, `walkright` | `walkforward1h`, `walkforward1s`, `walkforward1b`, `walkforward2c`, `walkforward2b`, `walkforward2w`, `walkforwardbow`, `walkforwardcrossbow`, `walkforward1t`, `walkforwardhh`, `walkforwardspell`, and the same suffix pattern for `walkback`, `walkleft`, `walkright` |
| `runforward`, `runback`, `runleft`, `runright` | same suffix pattern as walk |
| `sneakforward`, `sneakback`, `sneakleft`, `sneakright` | same suffix pattern as walk |
| `turnleft`, `turnright` | same suffix pattern as walk, except spell turning is special-cased to `spellturnleft` and `spellturnright` |
| `idle` | `idle1h`, `idle1s`, `idle1b`, `idle2c`, `idle2b`, `idle2w`, `idlebow`, `idlecrossbow`, `idle1t`, `idlehh`, `idlespell` |
| `jump` | `jump1h`, `jump1s`, `jump1b`, `jump2c`, `jump2b`, `jump2w`, `jumpbow`, `jumpcrossbow`, `jump1t`, `jumphh`, `jumpspell` |

Swimming movement names do not get weapon suffixes in the movement resolver. If a swim movement group is missing, OpenMW first tries the non-swim equivalent by removing `swim`, then the normal non-swim fallback logic can apply.

### Runtime Animation Source Stacks

These are listed from highest priority to lowest priority for movement group resolution. Later `addAnimSource` calls win over earlier calls when both contain the same movement group.

| Actor/view case | Runtime animation files that can provide movement groups | Associated movement names |
| --- | --- | --- |
| Third-person normal male humanoid | optional custom NPC model `.kf`; `meshes/base_anim.kf`; `meshes/xbase_anim.kf` | All core third-person movement names, movement idles, jump, and non-swim weapon/spell variants |
| Third-person female humanoid | optional custom NPC model `.kf`; `meshes/base_anim_female.kf`; `meshes/xbase_anim.kf` | All core third-person movement names, movement idles, jump, and non-swim weapon/spell variants |
| Third-person beast race, non-Argonian | optional custom NPC model `.kf`; `meshes/base_animkna.kf`; `meshes/xbase_anim.kf` | All core third-person movement names, movement idles, jump, and non-swim weapon/spell variants |
| Third-person Argonian beast race | `meshes/xargonian_swimkna.kf`; optional custom NPC model `.kf`; `meshes/base_animkna.kf`; `meshes/xbase_anim.kf` | `xargonian_swimkna.kf` is the high-priority Argonian swim override, so movement-relevant groups are `swimwalkforward`, `swimwalkback`, `swimwalkleft`, `swimwalkright`, `swimrunforward`, `swimrunback`, `swimrunleft`, `swimrunright`, `swimturnleft`, `swimturnright`, and `idleswim`; lower-priority sources still cover the full beast set |
| First-person normal male humanoid | `meshes/xbase_anim.1st.kf` | First-person requested movement groups: ground walk/run/sneak, swim walk/run, movement idles, and jump. Turn movement is not selected in first person |
| First-person female humanoid | `meshes/base_anim_female.1st.kf`; `meshes/xbase_anim.1st.kf` | Same first-person requested movement groups as normal male; female first-person source can override shared first-person groups |
| First-person beast race | `meshes/base_animkna.1st.kf`; `meshes/xbase_anim.1st.kf` | Same first-person requested movement groups as normal male; beast first-person source can override shared first-person groups |
| First-person Argonian beast race | `meshes/base_animkna.1st.kf`; `meshes/xbase_anim.1st.kf` | Same as first-person beast. OpenMW does not add `xargonian_swimkna.kf` in first person |
| Werewolf NPC/player form, third person | `meshes/wolf/skin.kf` | Outside the humanoid/beast-race scope above, but this is the NPCAnimation source path if werewolf form is considered; associated names are whichever player/NPC movement groups the werewolf file contains |
| Werewolf NPC/player form, first person | `meshes/wolf/skin.1st.kf` | Same caveat as third-person werewolf |

### File Name Inventory

| File name | How OpenMW uses it for player/NPC movement | Movement association |
| --- | --- | --- |
| `meshes/xbase_anim.nif` | Third-person shared non-werewolf base animation source setting; runtime keyframes are `meshes/xbase_anim.kf` | All core third-person movement names, movement idles, jump, and non-swim weapon/spell variants, unless overridden by later sources |
| `meshes/xbase_anim.kf` | Runtime keyframes for `xbase_anim.nif`; explicitly preloaded as `xbaseanimkf` | Same as `xbase_anim.nif` |
| `meshes/base_anim.nif` | Third-person normal male humanoid skeleton/source; runtime keyframes are `meshes/base_anim.kf` if present | All core third-person movement names, movement idles, jump, and non-swim weapon/spell variants for normal male humanoids |
| `meshes/base_anim.kf` | Derived runtime keyframe name for `base_anim.nif` | Same as `base_anim.nif` |
| `meshes/base_anim_female.nif` | Third-person female humanoid skeleton/source; runtime keyframes are `meshes/base_anim_female.kf` if present | All core third-person movement names, movement idles, jump, and non-swim weapon/spell variants for female humanoids |
| `meshes/base_anim_female.kf` | Derived runtime keyframe name for `base_anim_female.nif` | Same as `base_anim_female.nif` |
| `meshes/base_animkna.nif` | Third-person beast-race skeleton/source; runtime keyframes are `meshes/base_animkna.kf` if present | All core third-person movement names, movement idles, jump, and non-swim weapon/spell variants for beast races |
| `meshes/base_animkna.kf` | Derived runtime keyframe name for `base_animkna.nif` | Same as `base_animkna.nif` |
| `meshes/xargonian_swimkna.nif` | Third-person Argonian beast swim override source; runtime keyframes are `meshes/xargonian_swimkna.kf` | Highest-priority Argonian swim movement source: `swimwalk*`, `swimrun*`, `swimturn*`, and `idleswim` when present |
| `meshes/xargonian_swimkna.kf` | Runtime keyframes for `xargonian_swimkna.nif`; explicitly preloaded as `xargonianswimknakf` | Same as `xargonian_swimkna.nif` |
| `meshes/xbase_anim.1st.nif` | First-person shared base animation source and normal male first-person skeleton; runtime keyframes are `meshes/xbase_anim.1st.kf` | First-person requested movement groups: ground walk/run/sneak, swim walk/run, movement idles, and jump; no first-person turn locomotion |
| `meshes/xbase_anim.1st.kf` | Runtime keyframes for `xbase_anim.1st.nif`; explicitly preloaded as `xbaseanim1stkf` | Same as `xbase_anim.1st.nif` |
| `meshes/base_anim_female.1st.nif` | First-person female humanoid skeleton/source; runtime keyframes are `meshes/base_anim_female.1st.kf` if present | Same first-person requested movement groups as `xbase_anim.1st`, with female override priority |
| `meshes/base_anim_female.1st.kf` | Derived runtime keyframe name for `base_anim_female.1st.nif` | Same as `base_anim_female.1st.nif` |
| `meshes/base_animkna.1st.nif` | First-person beast-race skeleton/source; runtime keyframes are `meshes/base_animkna.1st.kf` if present | Same first-person requested movement groups as `xbase_anim.1st`, with beast override priority |
| `meshes/base_animkna.1st.kf` | Derived runtime keyframe name for `base_animkna.1st.nif` | Same as `base_animkna.1st.nif` |
| `meshes/xbase_anim_female.nif` | Present in settings and preloaded as a common model, but not directly added by the audited `NpcAnimation::updateNpcBase` runtime source stack | No direct player/NPC movement association in the audited runtime path |
| `meshes/xbase_anim_female.kf` | Explicitly preloaded as `xbaseanimfemalekf`, but not directly added by the audited runtime source stack | No direct player/NPC movement association in the audited runtime path |
| `meshes/wolf/skin.nif` | Werewolf third-person skeleton/source; runtime keyframes are `meshes/wolf/skin.kf` if present | Outside normal humanoid/beast-race scope; can satisfy whichever player/NPC movement groups the file contains |
| `meshes/wolf/skin.kf` | Derived runtime keyframe name for `wolf/skin.nif` | Same as `wolf/skin.nif` |
| `meshes/wolf/skin.1st.nif` | Werewolf first-person skeleton/source; runtime keyframes are `meshes/wolf/skin.1st.kf` if present | Outside normal humanoid/beast-race scope; can satisfy whichever first-person movement groups the file contains |
| `meshes/wolf/skin.1st.kf` | Derived runtime keyframe name for `wolf/skin.1st.nif` | Same as `wolf/skin.1st.nif` |
| Custom NPC model path from `mNpc->mModel` | Third-person, non-werewolf custom NPC model source; runtime keyframes are the same model path with `.kf` | Any movement group contained in that custom file; it overrides default race/gender sources but is below the Argonian swim source |
| `animations/<source-stem>/**/*.kf` | Optional extra animation sources when `use additional anim sources = true`; default is false | Open-ended modded association. Any contained movement group can override earlier sources according to insertion order |

## Design Patterns Worth Carrying Into Godotwind

1. Keep movement intent separate from animation choice.
   Godotwind should let input, AI, scripts, and tools produce a generic local movement intent, then have a locomotion-animation resolver decide which animation to play.

2. Keep Morrowind names in an adapter.
   Names like `swimrunforward`, `base_animkna`, and `xargonian_swimkna` belong in a Morrowind animation profile or importer layer, not in generic character movement code.

3. Make animation availability queryable.
   OpenMW exposes supported movement directions based on actual loaded animation groups. Godotwind should expose a similar capability mask so AI and obstacle avoidance do not request impossible movement animations.

4. Treat root motion as optional per animation and per view mode.
   Third-person Morrowind-style movement can be root-motion-driven. First-person or missing-root-motion cases should fall back to gameplay velocity without pretending the animation provided motion.

5. Resolve variants through data, not condition spaghetti.
   OpenMW's group name convention is simple enough to model as data: base locomotion family, direction, medium, stance, weapon suffix, and fallback chain.

6. Separate skeleton/source selection from state selection.
   Beast races do not need a different movement state machine. They need a different asset profile with the same group contract plus optional overrides.

7. Preserve source priority for modding.
   Later/higher-priority animation sources allow race, gender, custom model, and mod-provided animation sets to override standard groups without rewriting locomotion logic.

## Suggested Godotwind Adapter Contract

A Morrowind movement animation profile should provide:

- movement families: `walk`, `run`, `sneak`, `swimwalk`, `swimrun`, `turn`, `swimturn`;
- directions: `forward`, `back`, `left`, `right`, plus turn `left/right`;
- idle groups: `idle`, `idlesneak`, `idleswim`;
- jump group base: `jump`;
- weapon short suffix table;
- fallback chain: swim to ground, weapon suffix to canonical fallback, run to walk;
- root-motion availability and velocity metadata per group;
- race/gender/view-mode source stack;
- direction capability mask derived from loaded groups.

Generic Godotwind systems should consume a profile through neutral concepts such as locomotion family, direction, stance, medium, view mode, source priority, and root-motion policy.

## Risks and Open Questions

- The OpenMW source identifies expected group names and source-selection rules, but the actual Bethesda NIF/KF assets are not present in the OpenMW source tree. Exact text-key coverage per race/gender asset still needs validation against the game data or imported asset cache.
- This audit did not trace the full NIF/KF text-key parser. For Godotwind implementation, import validation should confirm that text-key group names survive conversion exactly.
- OpenMW's root-motion quirks intentionally reproduce vanilla Morrowind behavior. Godotwind should support them in the Morrowind adapter, but the generic character motor should not be designed around those quirks.
- `turn to movement direction`, `smooth movement`, and `player movement ignores animation` are compatibility/gameplay settings in OpenMW. Godotwind should decide which of these are baseline framework features and which are Morrowind profile options.
