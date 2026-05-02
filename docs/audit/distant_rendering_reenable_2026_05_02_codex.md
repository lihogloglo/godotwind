# Distant Rendering Re-enable Verification

Date: 2026-05-02
Owner: codex

## Change Summary

- FAR impostors are default-on again in `world_explorer.gd`.
- HLOD remains implemented but opt-in via `hlod_enable` / benchmark toggles.
- `--near-only` parks HLOD and impostors.
- `--no-hlod` and `--no-impostors` were added for tier-isolation runs.
- `bench_progressive` includes `hlod` again so automated sweeps can measure it.

## Automated Results

Build and unit checks:

- `dotnet build Godotwind.sln`: passed, existing nullable warnings only.
- `res://tests/run_tests.tscn`: passed.
- `git diff --check`: passed.

Stress runs:

| Run | Path | Result | Notes |
| --- | --- | --- | --- |
| `distant_default_on_rerun_2026_05_02` | HLOD + FAR impostors default-on candidate | failed | avg 19.1 FPS, max frame 97.9ms, `frames_over_50=643`, `max_stream_total_ms=255.6`, draw calls averaged ~2058 and peaked 4462. |
| `distant_no_hlod_2026_05_02` | FAR impostors on, HLOD off | failed gate but recovered steady | avg 37.8 FPS over full run because early frames exceeded 50ms; no streaming-total failure, last frames were ~193 FPS with ~881 draws. |

## Decision

Do not ship HLOD default-on yet. The failure mode is not a crash; it is a
persistent draw-call / surface-count problem in runtime HLOD chunks. Keep HLOD
available for targeted verification, but leave the default game path on
MID 0-500m plus FAR impostors until HLOD chunk material/surface reduction lands.

## Next Work

1. Add HLOD stats for active chunk surface counts and per-tier chunk counts to
   stress CSV/summary.
2. Fix HLOD material/surface reduction. The likely canonical route is material
   deduplication/atlasing for chunk proxy meshes, not world-scoped MultiMesh.
3. Re-run dense/east/reclaim stress with `hlod_enable` and require no 50ms+
   frames, no `material_set_shader`, no stale bucket, and no collision finalize
   errors before making HLOD default-on.
4. Smooth FAR impostor startup uploads; the no-HLOD run recovers to high FPS
   but still fails the full-run gate from early >50ms frames.
