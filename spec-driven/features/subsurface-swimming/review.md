# Review: Subsurface Swimming

Status: not started

## Current Review Notes

- This feature is intentionally separate from player-camera-modes. Camera modes
  own visual yaw/pitch routing and movement-reference separation; subsurface
  swimming owns whether movement can carry the player below the water surface.
- OpenMW is a required research reference, especially `turn to movement
  direction`, `swim upward correction`, and `swim upward coef`.
- The Godotwind implementation should be generic first. Morrowind/OpenMW-style
  swim upward correction belongs in config/preset behavior.
- The feature must coordinate with compositor-owned underwater optics rather
  than bringing back deleted legacy underwater volume renderers.

## Residual Risk

Player-camera-modes Phase 4 cannot fully accept below-surface swim pitch until
this feature is implemented and visually verified.
