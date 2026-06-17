# Spring Cleanup Session Template

Use this template when ending a Spring cleanup session or when a detailed
handoff is needed. For normal starts, prefer the repo-local skill and the short
prompt `Spring cleanup, continue.`

## Start Prompt

Fallback only. The normal entry point is `Spring cleanup, continue.`

```text
Continue Spring cleanup.

Pillar:
Scope:
Mode: audit-only / cleanup implementation / verification

Use the Spring cleanup program:
docs/audit/spring_cleanup_program_2026_06_13.md

Use any relevant pillar charter:
docs/audit/spring_cleanup_pillar_1_code_quality_charter_2026_06_13.md

Recall memory for "Godotwind Spring cleanup".

Rules:
- Work one pillar at a time.
- Produce evidence before edits.
- Use agents only for bounded expert questions.
- Do not touch unrelated dirty worktree changes.
- For runtime changes, verify with the narrowest relevant test, benchmark,
  visual scene, or smoke.
```

## Session Header

```markdown
# Spring Cleanup: <Pillar / Topic>

Date:
Mode:
Scope:
Worktree note:
Relevant docs:
Relevant tests:
```

## Audit Finding Format

```markdown
## <Severity>: <Finding>

Evidence:

- `<path>`: <line/function/module evidence>
- `<path>`: <line/function/module evidence>

Why it matters:

<Plain-English risk.>

Canonical pattern:

<Godot / industry standard, if one applies.>

Recommendation:

<Smallest clean next step.>

Verification:

<How to prove the recommendation later.>
```

## Cleanup Slice Format

Use this section shape in the session audit doc:

```text
## Cleanup Slice: Name

Finding addressed:

Files expected:

Out of scope:

Plan:

1. <Small step>
2. <Small step>
3. <Verification>

Acceptance:

- <Concrete outcome>
- <Concrete outcome>

Verification command/scene:
```

## End-Of-Session Handoff

Use this section shape at the end of the session audit doc:

```text
## Handoff

Completed:

- 

Important evidence:

- 

Open questions:

- 

Do not touch yet:

- 

Next best prompt:

...
```

Also save a short memory note with:

- pillar and scope,
- audit doc path,
- must-fix findings,
- cleanup backlog,
- verification status,
- any dirty-worktree caveats.
