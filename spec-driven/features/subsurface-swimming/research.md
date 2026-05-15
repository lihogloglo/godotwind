# Research: Subsurface Swimming

Date: 2026-05-15
Owner: Codex
Status: seed research; implementation not started

## Purpose

Godotwind's current character-controller swimming keeps the player near the
water surface. The player cannot intentionally dive and continue swimming below
the surface. This blocks full first-person/third-person swim-pitch visual
acceptance in the player-camera-modes Phase 4 work, but it is a separate
movement/water feature and should not be solved inside the camera-mode split.

## Local Current State

Current Godotwind swimming is surface-biased:

- `docs/systems/character_controller.md` documents that swim movement keeps the
  player's feet below the water surface by at least
  `swim_min_feet_submersion`.
- `SwimMove` and `SwimIdleMove` apply buoyancy and a surface clamp around
  `water_surface_y`.
- Jump in water is a repeated upward swim stroke, not a general vertical axis.
- `PlayerInputGatherer` now computes vertical swim intent from explicit
  movement pitch, but the swim moves still do not support persistent diving
  below the surface.

That means player-camera-modes can verify that vanity pitch does not leak into
swim intent, but it cannot fully accept below-surface swim pitch behavior until
this feature exists.

## OpenMW Research Anchors

OpenMW should be used as a Morrowind compatibility reference, not copied
wholesale. The useful behavior to study is that OpenMW distinguishes swimming,
underwater, and surface-follow behavior rather than treating all swimming as a
surface clamp.

Primary anchors:

- OpenMW game settings docs:
  https://openmw.readthedocs.io/en/latest/reference/modding/settings/game.html
- Local OpenMW settings source:
  `openmw-master/docs/source/reference/modding/settings/game.rst`
- Local OpenMW defaults:
  `openmw-master/files/settings-default.cfg`
- Local OpenMW movement source:
  `openmw-master/apps/openmw/mwmechanics/character.cpp`
- Existing Godotwind source audit:
  `docs/audit/character_controller_code_audit_2026_05_09_codex.md`
- Existing movement-animation audit:
  `spec-driven/features/movement animation/openmw player-npc movement animation analysis.md`

Findings to carry forward:

- OpenMW's `turn to movement direction` setting also affects swimming
  presentation: when enabled, the body can turn up or down according to swim
  movement direction.
- In `character.cpp`, OpenMW applies swim body pitch for biped forward/back
  swim movement when `turn to movement direction` is enabled and the player is
  not in first person.
- OpenMW's `swim upward correction` is an optional gameplay setting, default
  false. The docs describe it as making third-person player swimming bias upward
  from line of sight to simplify swimming without diving.
- `swim upward coef` defaults to `0.2` and controls the strength/sign of that
  correction. In source, when the correction is enabled, OpenMW adds vertical
  movement from forward/back swim movement and slightly reduces forward/back
  movement to keep the vector bounded.
- OpenMW code also has explicit underwater/submerged checks for drowning,
  combat restrictions, spell/ranged restrictions, and water landing sounds.
  Future Godotwind work should account for gameplay state changes when the
  camera/body is underwater, not only movement math.

## Godotwind Direction

The likely Godotwind direction is a generic swim-depth movement feature:

- let water bodies define surface height, depth range, and whether diving is
  allowed;
- distinguish surface-swim, underwater-swim, and exit-water states;
- let camera/look pitch contribute to vertical swim intent in normal
  first-person/follow modes;
- keep vanity camera pitch isolated from swim intent;
- make any OpenMW-style upward correction a Morrowind preset/config option, not
  hard-coded generic movement behavior;
- coordinate with `docs/systems/underwater.md` so underwater optics and
  underwater movement share the same water-state contract.

## Open Questions

- Should surface swimming auto-float the player unless a dive input/look pitch
  overcomes buoyancy, or should any downward pitch immediately dive?
- Should jump remain an upward stroke while underwater, or become a surface-only
  stroke with a separate ascend input?
- How should third-person camera collision and waterline optics behave while
  the player is below the surface?
- Which gameplay systems need explicit underwater state first: drowning,
  casting restrictions, ranged weapon restrictions, AI pathing, audio, or
  interaction?
