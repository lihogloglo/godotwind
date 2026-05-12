# Validation: <Feature Name>

## What Must Be Proven

- <Acceptance criterion or visual/performance requirement>

## Automated Checks

- Command or procedure:
- Expected result:

## Visual Test Scene

Scene path:

- `<path/to/test_scene.tscn>`

Purpose:

- <What this scene proves>

Expected visual result:

- <What a human should see>

Failure signs:

- <Obvious signs the feature is broken>

Suggested controls or debug views:

- <Toggle, slider, camera preset, debug overlay>

## Performance Check

Scenario:

- <Representative workload>

Budget or target:

- <Frame time, memory, draw calls, import time, etc.>

How to measure:

- <Procedure>

## Modding Check

Custom content scenario:

- <Small mod fixture, alternate resource, override config, replacement asset, or not applicable>

Expected result:

- <How the custom content should load, override, or coexist>

Failure signs:

- <Hard-coded bundled content, ignored overrides, load-order bugs, broken fallback behavior>

## Manual Review Checklist

- [ ] Acceptance criteria are satisfied.
- [ ] Generic framework code has no game-specific assumptions.
- [ ] Moddable content and behavior can be added, replaced, configured, or disabled as specified.
- [ ] Visual output matches the spec.
- [ ] Performance-sensitive paths have been checked.
- [ ] Known limitations are documented.
