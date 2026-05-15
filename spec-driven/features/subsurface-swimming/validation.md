# Validation: Subsurface Swimming

Status: not started

## Required Checks

- Player can dive below the surface in first person.
- Player can dive below the surface in fixed third person.
- Player can remain underwater while continuing downward/level swim input.
- Player can resurface predictably.
- Surface swim remains stable near the waterline.
- Vanity orbit pitch does not affect underwater vertical swim intent.
- Underwater state is published for future drowning/audio/combat rules.
- Underwater visuals use the compositor-owned path from
  `docs/systems/underwater.md`; do not reintroduce deleted spatial-volume
  underwater renderers.

## Runtime Verification

Codex cannot reliably launch Godot from this workspace. A human/user must run
the focused visual scene once this feature exists. The scene must be interactive
and must not use automated screenshot/auto-capture acceptance.
