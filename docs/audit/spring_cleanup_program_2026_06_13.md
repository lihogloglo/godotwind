# Spring Cleanup Audit Program

Date: 2026-06-13

Purpose: run a multi-session audit before new feature work. The goal is not to
make the project smaller for its own sake. The goal is to make Godotwind easier
to reason about, safer to extend, faster to stream, easier to debug, and more
honest about the boundary between the framework and the Morrowind adapter.

This is an audit program first and an implementation program second. Do not
start broad refactors from vibes. Produce evidence, rank findings, then turn
the highest-confidence findings into small cleanup slices.

## Priority Order

1. Code quality, architecture, maintainability, modularity, cleanliness.
2. Separation between the source-agnostic framework and the Morrowind adapter.
3. Performance, especially streaming, computation, rendering, and memory.
4. Debugability, including A/B testing, diagnostics, panels, console commands,
   and reproducible profiling.
5. Loading time, including app startup, source data boot, cache use, prebakes,
   and Morrowind asset loading.

## Operating Rules

- Work one pillar at a time unless a finding clearly crosses pillar boundaries.
- Start every pillar with a charter: question, acceptance bar, evidence plan,
  canonical industry/Godot pattern, and verification path.
- Prefer mechanical evidence over narrative confidence: file size, dependency
  direction, call graphs, ownership maps, benchmark output, tests, and visual
  smokes.
- Use agents for bounded expert review, not as a substitute for synthesis.
  The main implementer owns the final verdict and checks the evidence.
- Do not genericize systems only because a source-specific word appears. Move
  logic only when the boundary is load-bearing or a concrete second source
  needs the seam.
- Do not preserve a complicated inherited approach if the canonical industry
  pattern is simpler.
- Do not ship "cleanup" that reduces line count but makes ownership less clear.
- Keep cleanup slices small enough to verify with the narrowest relevant test,
  visual scene, benchmark, or smoke.

## Agent Model

Use multi-agent work only when it is explicitly authorized for the session.
Useful roles:

- `explorer`: map a concrete subsystem, call path, or ownership question.
- `critic`: find bugs, hidden coupling, dead code, kludges, and regressions.
- `godot-expert`: check Godot lifecycle, RenderingServer, PhysicsServer,
  threading, resource ownership, and GDScript/C# API usage.
- `openworld-expert`: check streaming, LOD, culling, memory, draw calls,
  frame budgets, and open-world architecture.
- `judge`: synthesize expert reports into a consensus. The judge should work
  from reports, not independently invent source facts.

Preferred pattern:

1. Main agent reads the relevant docs and code first.
2. Main agent assigns distinct, non-overlapping questions to agents.
3. Main agent continues local mechanical inventory while agents work.
4. Main agent reconciles reports, checks key claims, and writes the audit.

## Per-Pillar Loop

1. Charter
   - Define the pillar question.
   - Name the canonical pattern or research target.
   - Define what "good enough" means for this project.

2. Inventory
   - Run mechanical scans.
   - Read the live docs before trusting old plans or comments.
   - Build a small evidence table of hotspots.

3. Expert Review
   - Spawn focused agents only for questions that can be answered
     independently.
   - Ask for file paths, exact evidence, and ranked findings.

4. Synthesis
   - Classify findings as must fix, should fix, acceptable debt, false alarm,
     or needs proof.
   - Identify the smallest cleanup slices that remove real risk.

5. Verification
   - Docs-only audit: verify links, paths, and handoff completeness.
   - GDScript changes: run relevant gdUnit suites and the narrowest Godot
     visual/smoke when gameplay, streaming, rendering, or performance paths
     changed.
   - C# changes: run `dotnet build Godotwind.sln` before Godot launch.
   - Shader changes: clear relevant shader/import cache before launch as
     required by the project rules.

6. Handoff
   - Update the audit doc with current state, open questions, and next prompt.
   - Save important cross-session decisions to memory.

## Artifact Naming

Use these names unless there is a strong reason not to:

- Master program: `docs/audit/spring_cleanup_program_YYYY_MM_DD.md`
- Pillar charter: `docs/audit/spring_cleanup_pillar_N_topic_charter_YYYY_MM_DD.md`
- Pillar audit: `docs/audit/spring_cleanup_pillar_N_topic_audit_YYYY_MM_DD.md`
- Cleanup implementation note:
  `docs/audit/spring_cleanup_pillar_N_topic_cleanup_YYYY_MM_DD.md`

## Existing Ground Truth To Reuse

- `docs/STATUS.md`
- `docs/systems/adapter_boundary.md`
- `docs/audit/morrowind_framework_boundary_mega_audit_2026_05_21.md`
- `docs/audit/framework_morrowind_boundary_adr_2026_05_22.md`
- `docs/systems/streaming_rendering_bible.md`
- `tests/unit/test_adapter_boundary.gd`
- `tests/unit/test_world_source_boundary.gd`
- `tests/unit/test_streaming_modular_boundaries.gd`

Treat old docs, comments, and previous plans as evidence, not authority. If a
doc contradicts current code or current Godot behavior, update or supersede the
doc instead of preserving the stale claim.

## Current Session State

At setup time, the worktree already contained unrelated modified and untracked
runtime files, including transition, hydrology, interior, render-layer, and
test changes. Spring cleanup setup intentionally stays documentation-only so it
does not mix audit scaffolding with active feature work.

## Recommended Entry Point

```text
Spring cleanup, continue.
```

This repo now has a local `spring-cleanup` skill and a live state file:

- `./.agents/skills/spring-cleanup/SKILL.md`
- `docs/audit/spring_cleanup_state.md`

Use those as the durable entry point instead of asking the user to paste a long
prompt.
