# GodotWind Development Constitution

These rules guide all AI-assisted GodotWind work. They should be treated as project-level constraints unless a human maintainer explicitly overrides them.

## 1. Build General Systems First

GodotWind should prefer reusable framework code over game-specific code.
Morrowind behavior belongs in an adapter, data layer, import layer, or configuration layer on top of the general system.

Good:

- `RiverFlowMap`, `TerrainMaterialLayer`, `WorldCellStreamer`
- `MorrowindRiverAdapter`, `EsmTerrainSource`, `MwWaterMaterialPreset`

Avoid:

- hard-coded Morrowind names inside generic rendering, terrain, water, streaming, shader, or tooling systems
- systems that only work because they assume Morrowind data shapes
- framework APIs that leak one game format into unrelated modules

OpenMW may be used as a research and compatibility reference for Morrowind-specific behavior, formulas, settings, file interpretation, and edge cases.
It should not be treated as the default architecture for GodotWind's generic systems.
When OpenMW behavior is needed, translate it into one Morrowind-oriented implementation on top of a more general framework.

## 2. Prefer Native Godot Features

Before creating bespoke infrastructure:

1. Try Godot's built-in systems.
2. Check whether the Godot community or engine documentation already solves the problem.
3. Only build a custom solution when native and known solutions cannot satisfy the spec.

Custom code should exist because the project needs it, not because the agent happened to generate it.

## 3. Treat Modding as a First-Class Requirement

Bethesda-style worlds are defined partly by how deeply players and creators can modify them.
GodotWind systems should be designed so content, rules, assets, settings, and game-specific behavior can be extended or replaced without editing generic framework code.

Prefer:

- data-driven resources, configs, importers, and registries
- stable extension points for game-specific behavior
- clear separation between engine/framework code and content packs
- documented file formats, resource fields, and override behavior
- validation scenes or fixtures that can exercise custom content

Avoid:

- hard-coded content assumptions in shared systems
- special cases that only work for bundled assets
- hidden coupling between importers, runtime systems, and specific game data
- APIs that make mod support possible only through code edits

When a feature touches content loading, rendering, gameplay rules, assets, editor tools, or world data, the spec and plan should describe how mods can add, replace, configure, or disable that behavior.

## 4. Keep It Simple and Maintainable

Prefer clear data flow, small modules, and boring names.
Avoid clever abstractions until repeated use proves they are needed.

Every feature should be understandable by reading:

1. the spec,
2. the plan,
3. the primary runtime node/resource/script,
4. the validation scene or test.

## 5. Godot Constraints Matter

Plans must account for Godot's actual behavior, not generic engine advice.
Be explicit about Godot version assumptions, rendering backend assumptions, shader limitations, resource loading behavior, editor/runtime differences, and performance constraints.

If a feature depends on a Godot version-specific capability, name it in the plan.

## 6. Visual Features Need Visual Validation

Rendering, shader, terrain, water, VFX, UI, and editor-tool changes need a runnable validation scene or equivalent visual check.

The validation scene should make failure obvious:

- exaggerated debug colors or overlays where useful
- fixed camera positions
- representative assets
- controls or presets for edge cases
- clear expected visual outcomes in `validation.md`

AI cannot reliably judge shaders from code alone. Do not treat shader compilation as proof of visual correctness.

## 7. Performance Is a Feature

GodotWind targets large outdoor worlds and must stay performance-conscious.
Plans should define performance-sensitive paths, expected scale, and a lightweight way to measure regressions.

When relevant, include budgets for:

- frame time
- draw calls
- shader complexity
- memory footprint
- streaming cost
- editor import time

## 8. Specs Drive Review

Review code against the accepted spec and plan.
Do not review only from taste or intuition.

If the code reveals that the spec was incomplete, update the spec before widening the implementation.

## 9. Leave a Trail

Each substantial feature should leave enough documentation for the next session to continue:

- what was decided
- why it was decided
- what remains risky
- how to run validation
- what should not be generalized yet

## 10. Documentation Is Part of the Change

Code should be documented at the level needed for a future maintainer to understand intent, boundaries, and safe extension points.

Use comments for:

- non-obvious algorithms or engine workarounds
- Godot-specific quirks that affected the implementation
- shader math, rendering assumptions, and coordinate-space conversions
- performance-sensitive decisions
- places where generic framework code intentionally stops and adapter-specific code begins

Avoid comments that merely repeat what the code says.
Prefer clear names and small functions first, then add comments where context would otherwise be lost.

Feature and architectural changes should update the relevant spec-driven documents:

- `spec.md` for behavior, acceptance criteria, and user-facing intent
- `plan.md` for architecture, data flow, module boundaries, and important tradeoffs
- `validation.md` for test scenes, manual checks, performance checks, and expected visual results
- `review.md` for known risks, follow-up work, and spec compliance
