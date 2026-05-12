# Tasks: <Feature Name>

Complete tasks in order unless the plan is revised.
Each task should be independently reviewable.

## Setup

- [ ] Confirm the current branch and working tree state.
- [ ] Read `spec.md`, `plan.md`, and `validation.md`.

## Implementation

- [ ] Define or update the modding/extension points described in `spec.md` and `plan.md`.
  - Validate: <How to check custom content, overrides, or configuration>

- [ ] <Task>
  - Validate: <How to check it>

- [ ] <Task>
  - Validate: <How to check it>

## Validation

- [ ] Run automated checks listed in `validation.md`.
- [ ] Open the visual test scene, if applicable.
- [ ] Record results in `review.md`.

## Cleanup

- [ ] Remove temporary debug code that is not part of the planned validation UI.
- [ ] Add or refine comments for non-obvious code, Godot quirks, shader math, performance-sensitive paths, and architectural boundaries.
- [ ] Update docs for any changed decisions.
- [ ] Update feature or architecture documentation for changed behavior, data flow, module boundaries, or validation procedures.
- [ ] Confirm content or behavior intended for modding is not hard-coded in shared systems.
- [ ] Confirm no game-specific assumptions leaked into generic code.
