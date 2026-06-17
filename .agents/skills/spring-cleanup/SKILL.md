---
name: spring-cleanup
description: Run the Godotwind Spring cleanup audit workflow. Use when the user says "Spring cleanup", "continue the audit", "project audit", "codebase cleanup", "framework cleanup", "audit cleanup", or asks to continue/plan one of the cleanup pillars: code quality, Morrowind/framework boundary, performance, debugability, or loading time.
---

# Spring Cleanup

## Purpose

Use this skill to run Godotwind's multi-session Spring cleanup audit without
requiring the user to paste long prompts. Treat the checked-in audit docs and
state file as the durable workflow.

## Start Here

Always read these files first:

1. `docs/audit/spring_cleanup_state.md`
2. `docs/audit/spring_cleanup_program_2026_06_13.md`

Then read the current pillar charter or audit doc named in the state file. If
the state file is missing or stale, recreate the current state from the newest
`docs/audit/spring_cleanup_*` docs and memory recall for "Godotwind Spring
cleanup".

## User Shortcuts

Interpret these as valid invocations:

- "Spring cleanup, continue"
- "Continue the audit"
- "Start pillar 1"
- "Next Spring cleanup session"
- "Run the code quality audit"
- "Use agents for Spring cleanup"

Do not ask the user to paste the long prompt template. Choose the next action
from the state file and proceed.

## Workflow

1. Check `git status --short` and note unrelated dirty worktree changes.
2. Read the state file and current pillar docs.
3. If the request is ambiguous, choose the next unfinished item from
   `spring_cleanup_state.md`.
4. Work one pillar at a time.
5. Produce evidence before edits. For audit-only sessions, do not change runtime
   code.
6. Use subagents only when the user explicitly authorizes agent/parallel work
   or asks for multi-agent review.
7. If subagents are used, assign bounded questions and synthesize their reports;
   do not treat agent output as final truth without checking key evidence.
8. Update the relevant audit doc and `spring_cleanup_state.md` before finishing.
9. Save a short memory note with the pillar, audit doc path, key findings, next
   step, and verification status.

## Pillar Order

1. Code quality, architecture, maintainability, modularity, cleanliness.
2. Morrowind translation-layer versus framework separation.
3. Performance: streaming, computation, rendering, memory.
3.0 Performance Observatory: benchmark/debug/diagnostic foundation before
   Pillar 3/5 optimization. Use `.agents/skills/performance-observatory/SKILL.md`
   when the user says "Performance Observatory", "Pillar 3.0", or asks for the
   benchmark/diagnostic foundation.
4. Debugability: A/B testing, debug panels, console, tooling.
5. Loading time: startup, source data boot, cache use, prebakes, asset loading.

## Output Rules

For audit-only work, produce:

- ranked findings with file/path evidence,
- cleanup backlog,
- "do not touch yet" list,
- verification and evidence notes,
- next best action.

For implementation cleanup, keep slices small and verify with the narrowest
relevant test, benchmark, visual scene, or smoke. Follow the project
verification rules in `AGENTS.md`.

## Important Boundaries

- Do not genericize systems just because they mention Morrowind. Move logic only
  when the boundary is load-bearing or a concrete second source needs the seam.
- Do not refactor broad systems during an audit-only session.
- Do not touch unrelated dirty worktree changes.
- Do not use memory as the sole source of required project rules. Required
  workflow state belongs in checked-in docs.
- Do not use deprecated custom prompt/slash-command files for this workflow;
  this repo uses this skill plus `AGENTS.md` routing and audit state docs.
