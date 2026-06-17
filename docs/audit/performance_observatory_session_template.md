# Performance Observatory Session Template

Use this for each Pillar 3.0 session.

## Prompt

```text
Performance Observatory, continue.
```

## Required First Reads

- `.agents/skills/performance-observatory/SKILL.md`
- `docs/audit/performance_observatory_state.md`
- `docs/audit/spring_cleanup_pillar_3_0_performance_observatory_charter_2026_06_15.md`
- `docs/systems/benchmarking.md`
- `tests/benchmark/benchmark_thresholds.gd`

## Required Scan

```powershell
python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .
```

## Session Output

- What changed in the observability picture.
- Coverage matrix updates.
- New/changed report paths.
- Benchmark or smoke commands run, if any.
- Whether C# build was required.
- Whether shader cache/import artifacts were cleared.
- Next smallest slice.

## State Update

Update `docs/audit/performance_observatory_state.md` with:

- completed slice,
- evidence paths,
- verification,
- known caveats,
- next best action.
