## Benchmark thresholds — single source of truth for performance expectations.
## Agents read this file to know what "good" looks like.
class_name BenchmarkThresholds
extends RefCounted

## Maximum time for _update_loaded_cells() on a 1-cell crossing
const CELL_CROSSING_MS: float = 10.0

## Maximum time for differential impostor update per crossing
const IMPOSTOR_CROSSING_MS: float = 2.0

## Maximum streaming frame budget (shared across all phases)
const FRAME_BUDGET_MS: float = 8.0

## Maximum time for MultiMesh set_buffer() rebuild (incremental, future)
const MULTIMESH_REBUILD_MS: float = 5.0

## Maximum cells scanned in differential impostor update (border strip)
const IMPOSTOR_DIFF_MAX_CELLS: int = 500
