# Spring Cleanup Pillar 1 Charter: Code Quality And Architecture

Date: 2026-06-13

Question: is the architecture of Godotwind safe, sound, clean, maintainable,
modular, and industry-standard enough to keep building on?

This pillar comes first because it creates the ownership map for every later
pillar. Boundary cleanup, performance cleanup, debugability, and loading-time
work all become safer once the project has a clear map of oversized modules,
duplicated responsibilities, stale bridges, dead paths, and unclear ownership.

## Non-Goals

- Do not rewrite large systems during the audit.
- Do not delete code only because it is old or large.
- Do not genericize Morrowind-specific code during this pillar unless it is
  also a code-quality finding and the fix is obviously small.
- Do not use line count as a standalone quality judgment.
- Do not normalize style churn or comment churn into the audit diff.

## Acceptance Bar

The audit should produce:

- A ranked list of architecture/code-quality findings with file paths and
  evidence.
- A map of the highest-risk ownership knots.
- A list of likely dead or duplicate systems that need proof before deletion.
- A list of places where comments/docs appear stale or are defending an
  overcomplicated approach.
- A first cleanup backlog grouped into small, verifiable slices.
- A clear "do not touch yet" list for debt that is real but not currently
  load-bearing.

## Initial Hotspots

Mechanical setup scans found these very large files:

| Lines | Path |
|---:|---|
| 4125 | `src/core/world/cell_manager.gd` |
| 3904 | `src/tools/world_explorer.gd` |
| 3173 | `src/core/world/native_streaming_manager.gd` |
| 2544 | `src/core/world/native_impostor_renderer.gd` |
| 2516 | `src/core/nif/nif_converter.gd` |
| 2443 | `src/core/water/ocean_fft_provider.gd` |
| 2161 | `src/core/world/interior_pocket_manager.gd` |
| 2156 | `src/core/world/reference_instantiator.gd` |
| 1860 | `src/core/world/object_paging.gd` |
| 1767 | `src/core/world/static_object_renderer.gd` |

These files are not guilty by size alone. They are priority candidates for
ownership review, API surface review, and extraction/deletion opportunities.

Early marker scan also showed the highest TODO/FIXME/HACK/workaround/temporary/
legacy concentrations in:

- `src/core/world/static_object_renderer.gd`
- `src/core/world/reference_instantiator.gd`
- `src/tools/world_explorer.gd`
- `src/core/water/ocean_fft_provider.gd`
- `src/core/world/object_paging.gd`
- `src/core/world/cell_manager.gd`

## Mechanical Inventory Commands

Use these as a starting point. Adjust as needed for the live question.

```powershell
git status --short
```

```powershell
rg --files src docs tests | Measure-Object | Select-Object -ExpandProperty Count
```

```powershell
$items = @()
foreach ($p in (rg --files src | Where-Object { $_ -match '\.(gd|cs)$' })) {
  $lines = (Get-Content -LiteralPath $p -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
  $items += [PSCustomObject]@{Lines=$lines; Path=$p}
}
$items | Sort-Object Lines -Descending | Select-Object -First 40 | Format-Table -AutoSize
```

```powershell
$items = @()
foreach ($p in (rg --files src tests | Where-Object { $_ -match '\.(gd|cs)$' })) {
  $txt = Get-Content -Raw -LiteralPath $p -ErrorAction SilentlyContinue
  $items += [PSCustomObject]@{
    Markers=([regex]::Matches($txt,'TODO|FIXME|HACK|workaround|temporary|legacy')).Count
    Path=$p
  }
}
$items | Where-Object {$_.Markers -gt 0} |
  Sort-Object Markers -Descending |
  Select-Object -First 40 |
  Format-Table -AutoSize
```

```powershell
rg -n "print\(|push_error\(|push_warning\(" src/core --glob "*.gd"
```

```powershell
rg -n "Thread\.new|Thread\.start|WorkerThreadPool|call_deferred|get_node\(|global_transform\s*=" src/core --glob "*.gd"
```

```powershell
rg -n "RenderingServer\..*\(|PhysicsServer|ResourceLoader|load_threaded|wait_for_task_completion" src/core --glob "*.gd"
```

```powershell
rg -n "legacy|temporary|workaround|bridge|WHY:|deferred" src/core docs --glob "*.gd" --glob "*.md"
```

## Review Questions

Ask these of every major system under review:

- What owns this responsibility?
- Is there exactly one source of truth?
- Does the public API expose implementation debt?
- Would a new feature naturally know where to plug in?
- Is this doing orchestration, data translation, rendering, streaming, and
  gameplay in one file?
- Does the code use Godot's standard feature before custom machinery?
- Is there a repeated pattern that should be one helper or one contract?
- Is there a bespoke bridge that exists only because the earlier architecture
  was wrong?
- Is this path verified by tests, benchmarks, or visual scenes?
- Would deleting or replacing this code simplify future sessions?

## Suggested Agent Briefs

Use only when agent work is authorized for the session.

### Explorer: Ownership Map

Map ownership and call flow for one hotspot, such as `cell_manager.gd` or
`world_explorer.gd`. Report responsibilities, direct collaborators, public API,
likely mixed concerns, and exact file/line evidence. Do not propose broad
rewrites; identify seams and risk.

### Critic: Architecture Risks

Review one subsystem for hidden coupling, dead code, duplicate paths,
over-engineered bridges, stale comments, and cleanup risks. Rank findings by
severity and include exact evidence.

### Godot Expert: Engine Patterns

Review one subsystem for Godot 4.6 correctness: node lifecycle, threading,
RenderingServer use, resource ownership, physics/render boundary, signal
ownership, and GDScript typing. Name the canonical Godot pattern when a path
deviates.

### Open-World Expert: Streaming Architecture

Review one world/streaming/rendering subsystem for frame-budget ownership,
async loading, LOD/culling patterns, memory lifetime, draw-call strategy, and
spatial indexing. Compare with the project streaming bible and Godot's native
facilities.

### Judge: Synthesis

Given the expert reports, produce one ranked verdict. Separate must-fix,
should-fix, acceptable debt, false alarms, and needs-proof. Do not add new
source facts that are not in the reports.

## First Audit Output Shape

Create:

`docs/audit/spring_cleanup_pillar_1_code_quality_audit_YYYY_MM_DD.md`

Recommended sections:

- Verdict
- Scope
- Mechanical Inventory
- Ownership Map
- Findings, ranked by severity
- Dead/Duplicate Code Candidates
- Over-Engineering / Bespoke Bridge Candidates
- Test And Verification Coverage
- Cleanup Backlog
- Do Not Touch Yet
- Next Prompt

## Verification For This Pillar

For an audit-only session:

- Verify referenced paths exist.
- Verify mechanical command output was current for the session.
- Save the handoff to memory.

For implementation slices that follow:

- Run focused gdUnit suites for touched systems.
- Run `dotnet build Godotwind.sln` when C# changes.
- Run the narrowest Godot visual scene, benchmark, or smoke when gameplay,
  streaming, rendering, or performance behavior changed.
- Do not use automated screenshots as visual proof.
