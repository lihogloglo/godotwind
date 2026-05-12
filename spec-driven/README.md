# GodotWind Spec-Driven Development

This folder is the working agreement for building GodotWind features with AI assistance.
It turns ideas into durable specs, plans, tasks, validation scenes, and review notes so future Codex sessions can continue the work without rediscovering the same context.

## Agent Start Protocol

For any non-trivial GodotWind change, read these files before editing code:

1. `00-constitution.md`
2. `01-workflow.md`
3. The active feature folder under `features/<feature-slug>/`, if one exists

If no feature folder exists, create one from `templates/feature-folder/`.
Do not skip directly from a vague idea to implementation unless the requested change is clearly small and local.

## Feature Folder Shape

Each feature should live in its own folder:

```text
spec-driven/
  features/
    rivers-flowmaps/
      research.md
      spec.md
      plan.md
      tasks.md
      validation.md
      review.md
```

Use this order:

1. Research the problem and Godot-specific constraints.
2. Write the product/spec behavior: what, why, success criteria.
3. Plan the technical design: architecture, data flow, risks.
4. Break the plan into small tasks.
5. Implement one task at a time.
6. Validate with automated checks and visual test scenes where relevant.
7. Review against the spec before broadening or polishing.

## Core Rule

When implementation diverges from intent, update the spec or plan first unless the issue is a tiny local defect.
The spec is the source of truth; code is the current attempt to satisfy it.

## Included Files

- `00-constitution.md`: standing principles for all GodotWind AI-assisted development.
- `01-workflow.md`: the repeatable spec-driven process.
- `templates/feature-folder/`: copyable documents for a new feature.
- `features/rivers-flowmaps/brief.md`: a seed idea for the rivers and flowmaps system.

