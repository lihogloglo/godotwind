# Spec: Subsurface Swimming

Date: 2026-05-15
Owner: Codex
Status: not started; created as blocker target

## Summary

Add intentional below-surface swimming so the player can dive, remain underwater,
and resurface through a coherent movement and water-state contract. This is
outside the player-camera-modes feature, but that feature's Phase 4 swim-pitch
visual acceptance is blocked for below-surface behavior until this exists.

## Goals

- Allow the player to swim below the water surface intentionally.
- Preserve surface swimming and repeated upward swim-stroke behavior where it
  still makes sense.
- Distinguish surface-swim and underwater-swim state for movement, camera,
  optics, audio, and future gameplay rules.
- Keep OpenMW behavior as research/reference, with Morrowind-specific upward
  correction exposed as config or preset behavior.
- Keep vanity camera pitch isolated from swim movement pitch.

## Non-Goals

- Do not implement this inside player-camera-modes.
- Do not hard-code OpenMW settings into generic swim movement.
- Do not solve underwater rendering/art direction here beyond consuming the
  shared underwater/waterline state exposed by the water system.

## Acceptance Criteria

- In first person and fixed third person, looking/swimming downward can move the
  player below the water surface and keep them there while input continues.
- The player can resurface predictably without being pinned upward every frame.
- Surface swimming remains stable near the waterline.
- Vanity orbit pitch still does not affect vertical swim intent.
- Underwater state is queryable for future drowning/audio/combat/restriction
  systems.
- OpenMW's `turn to movement direction`, `swim upward correction`, and
  `swim upward coef` behavior has been reviewed before implementation.

## Blocked Consumers

- `spec-driven/features/player-camera-modes/` Phase 4 can only accept
  surface-swim pitch isolation until this feature lands. Full below-surface
  swimming acceptance is blocked here.
