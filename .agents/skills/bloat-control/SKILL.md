---
name: bloat-control
description: Audit and reduce Godotwind code bloat, LOC growth, dead code, duplicate systems, generated-artifact sprawl, side-project drift, misplaced tests/tools, and cleanup scaffolding. Use when the user says "Check for bloat", "bloat control", "LOC audit", "code bloat", "dead code cleanup", "delete dead code", "project sprawl", or asks whether new lines/tests/side projects are justified.
---

# Bloat Control

## Purpose

Use this skill to keep Godotwind from accumulating LLM-generated sprawl. The
goal is not smallest possible LOC; the goal is that every production line has
clear ownership, current use, and a verification story.

## Start Here

Read these first:

1. `docs/audit/bloat_control_state.md`

Then run the deterministic scan:

```powershell
python .agents/skills/bloat-control/scripts/bloat_scan.py --root .
```

If the user says "Check for bloat", do not ask for a longer prompt. Run the
workflow below.

## Workflow

1. Check `git status --short` and note unrelated dirty worktree changes.
2. Run `bloat_scan.py` and summarize production/test/docs/generated counts.
3. Classify new or changed files by category:
   - production runtime,
   - source adapter,
   - tools/prebaking,
   - tests/visual/benchmark/diagnostic,
   - docs/audit/plans/archive,
   - generated artifacts/reports,
   - cleanup scaffolding,
   - unknown/misplaced.
4. Apply the rent test: every new production API, wrapper, counter, test, or
   helper must say what risk it removes or what proof it provides.
5. Find deletion candidates with evidence: no references, parked feature,
   compatibility alias, duplicate path, stale generated artifact, or obsolete
   side-project file.
6. Delete ruthlessly only after proof. For runtime paths, prove with references,
   tests, and the project-required smoke/benchmark. For docs/generated reports,
   prove by repo policy and current references.
7. Update `docs/audit/bloat_control_state.md` before finishing.
8. Save memory with the deleted/kept decisions and next cleanup target.

## Rules

- Fight unowned LOC, not LOC itself.
- Prefer deleting old paths over adding permanent guardrails around them.
- Keep tests that protect architectural invariants, but organize them under the
  right `tests/` category and remove obsolete tests when the feature is gone.
- Keep side projects out of generic runtime paths unless they are load-bearing.
  Morrowind-specific experiments belong under adapter/tool/test ownership.
- Generated reports are not source architecture. Track only deliberate
  evidence artifacts; otherwise keep them out of the lasting codebase.
- Compatibility aliases, route counters, no-op APIs, and migration ledgers need
  an owner and a deletion condition.
- Do not delete legacy gameplay/streaming routes just because they look old.
  Use route counters, references, and changed-path verification first.
- Do not touch unrelated dirty worktree changes.

## Organization Expectations

- Runtime framework: `src/core/`
- Morrowind adapter/source logic: `src/core/**/morrowind/`
- C# hot paths/native builders: `src/native/`
- Editor/dev/prebake tools: `src/tools/`
- Unit tests: `tests/unit/`
- Visual/manual smokes: `tests/visual/`
- Benchmarks/perf harnesses: `tests/benchmark/`
- Diagnostics: `tests/diagnostic/`
- Audit findings/state: `docs/audit/`
- Active plans: `docs/plans/`
- Superseded plans/session logs: `docs/archive/`

If a file does not fit one of these homes, flag it as misplaced before adding
more code around it.

## Output Shape

For an audit-only bloat check, produce:

- LOC and file-count summary by category,
- top production growth hotspots,
- generated-artifact/report sprawl,
- dead/duplicate code candidates,
- misplaced side-project/test/tool files,
- keep/delete/defer decisions,
- next deletion slice.

For deletion/cleanup implementation, include:

- proof that the code is unused or superseded,
- exact files deleted/edited,
- tests/static checks run,
- Godot visual/benchmark smoke if runtime behavior changed,
- shader cache/import note if shader files changed.

## Official Method Notes

This workflow follows current Codex guidance: use skills for repeated workflows,
keep each skill focused, prefer instructions unless deterministic scripts help,
keep durable state in repo files, and avoid deprecated custom prompt files.
