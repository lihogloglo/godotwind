# Bloat Control State

Last updated: 2026-06-18

Purpose: durable state for Godotwind LOC, dead-code, generated-artifact,
side-project, and cleanup-scaffolding control. When the user says "Check for
bloat", read this file and use `.agents/skills/bloat-control/SKILL.md`.

## How To Resume

Run:

```powershell
python .agents/skills/bloat-control/scripts/bloat_scan.py --root .
```

Then classify findings into keep/delete/defer decisions.

## Current Context

- The dedicated seasonal cleanup workflow is retired. Do not look for its skill,
  state file, charters, prompts, or session logs.
- Bloat control remains active as a general guard against unowned LOC, stale
  generated artifacts, dead compatibility paths, misplaced tools/tests, and
  cleanup scaffolding that outlives its proof value.
- Prefer deletion of obsolete docs/generated evidence over new tracking docs.
- Runtime deletions still need references, focused tests, and the project
  required Godot smoke or benchmark for the changed path.

## Next Best Action

Run the bloat scan, compare the output to the current worktree, and choose one
small deletion candidate with proof. Do not revive retired seasonal cleanup
docs as evidence.
