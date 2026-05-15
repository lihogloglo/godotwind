# Plan: Subsurface Swimming

Status: not started

## Architecture Direction

Treat subsurface swimming as a movement/water-state feature, not a camera-mode
patch. The implementation should extend the generic swim move/state contract so
water bodies, movement, camera, interaction, underwater optics, and future
gameplay systems agree on whether the player is at the surface or underwater.

## Likely Affected Areas

- `src/core/character/controller/player_input_gatherer.gd`
- `src/core/character/controller/input_package.gd`
- `src/core/character/controller/moves/swim_move.gd`
- `src/core/character/controller/moves/swim_idle_move.gd`
- `src/core/character/controller/movement_state.gd`
- `src/core/player/player_controller.gd`
- `src/core/water/water_surface_state.gd`
- `docs/systems/character_controller.md`
- `docs/systems/underwater.md`
- focused character-controller visual scene/tests

## Implementation Notes

- Start from `research.md`; inspect OpenMW source/settings again before coding.
- Keep the existing explicit movement pitch provider from player-camera-modes.
- Replace the current always-surface-biased swim behavior with explicit
  surface/underwater policy and config.
- Model OpenMW-style swim upward correction as optional preset/config behavior,
  not a mandatory generic rule.
- Coordinate underwater movement state with the compositor-owned underwater
  optics path documented in `docs/systems/underwater.md`.

## Validation Strategy

- Add unit coverage for surface swim, downward dive, sustained underwater swim,
  resurfacing, and vanity-pitch isolation.
- Add or extend a visual scene with enough water depth to dive below the
  surface interactively.
- Require human/editor verification; no automated screenshot acceptance.
