# Spec-Driven Workflow

This process is for substantial GodotWind work: new systems, rendering changes, terrain/world features, tools, importers, performance-sensitive code, or anything that may affect architecture.

Small, local fixes can use a lighter path, but should still respect the constitution.

## Phase 0: Intake

Capture the idea in plain language.
Identify whether it is a feature, refactor, bug fix, tool, research task, or validation task.

Answer:

- What user or developer need does this serve?
- What should be true when this is done?
- What is explicitly out of scope?
- Does this need research before planning?

## Phase 1: Research

Use research when the work touches unfamiliar architecture, rendering, engine limitations, third-party formats, performance, or established industry techniques.

Research should cover:

- how comparable systems are usually built
- examples from target-quality games or tools when relevant
- Godot-specific capabilities and constraints
- OpenMW's implementation when the feature needs Morrowind-compatible formulas, settings, data interpretation, or behavioral edge cases
- likely failure modes
- recommended direction for GodotWind

Research output goes in `research.md`.
Do not turn research directly into code. Turn it into a spec first.

For Morrowind-adjacent features, OpenMW is a reference implementation, not a design mandate.
Cite the relevant OpenMW files, formulas, constants, or settings that informed the research.
Do not copy OpenMW architecture into generic GodotWind systems unless the plan explicitly justifies that fit.

## Phase 2: Spec

The spec describes what and why, not how.

It should include:

- user stories or developer workflows
- success criteria
- functional requirements
- non-functional requirements
- modding and content-extension requirements
- acceptance tests
- out-of-scope decisions
- open questions

Output goes in `spec.md`.

## Phase 3: Plan

The plan describes how to satisfy the spec.

It should include:

- architecture
- affected files and modules
- data structures and resources
- Godot nodes, resources, shaders, editor tools, or importers involved
- framework layer versus Morrowind-specific layer
- modding boundaries, extension points, override rules, and content-loading assumptions
- validation strategy
- risk register
- migration or compatibility concerns
- documentation updates needed for feature or architectural changes

Output goes in `plan.md`.

## Phase 4: Tasks

Tasks should be small enough that an agent can complete and verify them one at a time.
Each task should name the expected change and the validation step.

Good task shape:

```markdown
- [ ] Add `RiverFlowMapResource` with serialized flow texture, speed scale, and debug color fields.
  - Validate by loading the resource in a minimal scene and confirming exported properties appear in the inspector.
```

Output goes in `tasks.md`.

## Phase 5: Implementation

Implement in task order.

Rules:

- Keep changes scoped to the current task.
- Prefer existing project patterns.
- Preserve generic framework boundaries.
- Preserve modding and content-extension boundaries.
- Avoid broad rewrites unless the plan explicitly calls for them.
- Add comments where they preserve intent, explain Godot quirks, clarify shader/rendering math, or mark architectural boundaries.
- Update feature and architecture documentation as part of the same change when behavior, data flow, or module boundaries change.
- Update tasks as work completes.
- If implementation pressure reveals a bad plan, stop and revise the plan.

## Phase 6: Validation

Validation should prove the feature satisfies the spec.

Use the right mix of:

- automated tests
- editor/runtime smoke tests
- visual test scenes
- performance measurements
- import or conversion fixtures
- manual review checklist

For visual systems, validation must include a scene or procedure that a human can inspect.
Output goes in `validation.md`.

## Phase 7: Review

Review against the spec and plan.

Ask:

- Does the implementation satisfy every acceptance criterion?
- Did it stay within the generic framework boundary?
- Did it introduce game-specific assumptions in shared code?
- Can mods add, replace, configure, or disable the relevant content or behavior without changing generic framework code?
- Is there a visual test scene where needed?
- Is there a performance risk?
- Are code comments and feature/architecture docs sufficient for the next maintainer?
- Are docs, tasks, and open questions updated?

Output goes in `review.md`.

## Repair Loop

If something fails:

1. Decide whether the spec, plan, task, or code is wrong.
2. Update the earliest wrong document.
3. Re-run implementation from the corrected source.
4. Record what changed.

Tiny local defects can be patched directly, but repeated defects usually mean the spec or plan is underspecified.
