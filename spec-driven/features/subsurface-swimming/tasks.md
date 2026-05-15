# Tasks: Subsurface Swimming

- [x] Create blocker feature folder.
  - Validate: `research.md`, `spec.md`, and `plan.md` identify this as the
    blocker for below-surface swim acceptance in player-camera-modes Phase 4.

- [x] Record OpenMW research anchors.
  - Validate: `research.md` references OpenMW settings docs, local OpenMW
    defaults, and `mwmechanics/character.cpp` swim behavior.

- [ ] Complete pre-code research.
  - Validate: confirm current Godotwind water-body/state APIs, underwater
    compositor contract, and OpenMW swim/dive/upward-correction behavior before
    editing runtime code.

- [ ] Specify the final subsurface movement contract.
  - Validate: `spec.md` defines surface swim, underwater swim, resurface, input,
    and gameplay-state semantics.

- [ ] Implement subsurface swimming.
  - Validate: unit tests cover dive, sustain, resurface, and vanity pitch
    isolation.

- [ ] Human/user visual verification.
  - Validate: focused scene allows diving below the surface, swimming
    underwater, resurfacing, and checking underwater optics interactively.
