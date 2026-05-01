## Benchmark thresholds - single source of truth for performance expectations.
## Agents read this file to know what "good" looks like.
class_name BenchmarkThresholds
extends RefCounted

## Bible target for a 150 FPS frame. Historical 8ms callers should keep using
## FRAME_BUDGET_MS by name; the value now reflects the current target.
const FRAME_BUDGET_MS: float = 6.67

## Historical shared streaming budget kept explicit for comparisons/migrations.
const LEGACY_SHARED_STREAMING_BUDGET_MS: float = 8.0

## Main-thread streaming publish target per frame.
const STREAMING_PUBLISH_BUDGET_MS: float = 1.0

## Render-side budget target at 150 FPS.
const RENDER_BUDGET_MS: float = 3.5

## Any frame at or above this is a blocking benchmark failure.
const BLOCKING_FRAME_MS: float = 50.0

## One 60 FPS frame; used for spike attribution warnings in benchmark summaries.
const SPIKE_FRAME_MS: float = 16.67

## Hard-gate streaming publish spikes separately from the 1ms target so callers
## can adopt the bible target without making every transitional run fail.
const STREAMING_PUBLISH_BLOCKING_MS: float = BLOCKING_FRAME_MS

## Static publish/prepare spikes should be visible in gate output when the
## per-frame timing field or log token is available.
const STATIC_PUBLISH_SPIKE_MS: float = SPIKE_FRAME_MS

## Maximum time for _update_loaded_cells() on a 1-cell crossing
const CELL_CROSSING_MS: float = 10.0

## Maximum time for differential impostor update per crossing
const IMPOSTOR_CROSSING_MS: float = 2.0

## Maximum time for MultiMesh set_buffer() rebuild (incremental, future)
const MULTIMESH_REBUILD_MS: float = 5.0

## Maximum cells scanned in differential impostor update (border strip)
const IMPOSTOR_DIFF_MAX_CELLS: int = 500
