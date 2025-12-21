## NavMeshConfig - Centralized configuration for navigation mesh baking
##
## Provides consistent parameters for NavigationMesh generation across the codebase.
## Based on OpenMW's recastnavigation configuration and tuned for Morrowind-scale NPCs.
##
## Usage:
##   var nav_mesh := NavigationMesh.new()
##   NavMeshConfig.apply_to_navmesh(nav_mesh)
class_name NavMeshConfig
extends RefCounted


## Agent dimensions (based on typical NPC size)
## Average humanoid NPC in Morrowind is roughly 1.8m tall with 0.5-0.6m radius
const AGENT_RADIUS: float = 0.6          # NPC capsule radius (meters)
const AGENT_HEIGHT: float = 2.0          # NPC height (meters)
const AGENT_MAX_CLIMB: float = 0.5       # Max step/obstacle height (meters)
const AGENT_MAX_SLOPE: float = 45.0      # Max walkable slope (degrees)

## Cell properties (voxelization resolution)
## Smaller = more detailed but slower baking and larger memory
## cell_size should be AGENT_RADIUS / 2 to 4 for good quality
const CELL_SIZE: float = 0.3             # Horizontal rasterization cell size (meters)
const CELL_HEIGHT: float = 0.2           # Vertical rasterization cell size (meters)

## Region properties (connected navmesh areas)
## Regions smaller than min_size are discarded (removes tiny disconnected islands)
const REGION_MIN_SIZE: float = 8.0       # Min region size (square cells)
const REGION_MERGE_SIZE: float = 20.0    # Merge nearby small regions (square cells)

## Polygon detail (controls mesh simplification)
## Higher sample_dist = less detail but smaller navmesh
## Lower max_error = more accurate height representation
const DETAIL_SAMPLE_DIST: float = 6.0    # Sample distance for detail mesh
const DETAIL_SAMPLE_MAX_ERROR: float = 1.0  # Max error for detail mesh (meters)

## Edge properties (polygon edge matching)
const EDGE_MAX_LENGTH: float = 12.0      # Max polygon edge length (meters)
const EDGE_MAX_ERROR: float = 1.3        # Max edge matching error (meters)

## Filtering (post-processing cleanup)
const FILTER_LOW_HANGING_OBSTACLES: bool = true   # Filter obstacles below agent height
const FILTER_LEDGE_SPANS: bool = true              # Filter narrow ledges
const FILTER_WALKABLE_LOW_HEIGHT_SPANS: bool = true  # Filter low ceilings

## Baking performance
const USE_PARALLEL_PROCESSING: bool = true  # Use WorkerThreadPool for baking
const BAKE_TIMEOUT_SECONDS: float = 60.0    # Max time per cell before timeout


## Apply configuration to a NavigationMesh resource
static func apply_to_navmesh(nav_mesh: NavigationMesh) -> void:
	# Agent properties
	nav_mesh.agent_radius = AGENT_RADIUS
	nav_mesh.agent_height = AGENT_HEIGHT
	nav_mesh.agent_max_climb = AGENT_MAX_CLIMB
	nav_mesh.agent_max_slope = AGENT_MAX_SLOPE

	# Cell properties
	nav_mesh.cell_size = CELL_SIZE
	nav_mesh.cell_height = CELL_HEIGHT

	# Region properties
	nav_mesh.region_min_size = REGION_MIN_SIZE
	nav_mesh.region_merge_size = REGION_MERGE_SIZE

	# Detail properties
	nav_mesh.detail_sample_distance = DETAIL_SAMPLE_DIST
	nav_mesh.detail_sample_max_error = DETAIL_SAMPLE_MAX_ERROR

	# Edge properties
	nav_mesh.edge_max_length = EDGE_MAX_LENGTH
	nav_mesh.edge_max_error = EDGE_MAX_ERROR

	# Filtering
	nav_mesh.filter_low_hanging_obstacles = FILTER_LOW_HANGING_OBSTACLES
	nav_mesh.filter_ledge_spans = FILTER_LEDGE_SPANS
	nav_mesh.filter_walkable_low_height_spans = FILTER_WALKABLE_LOW_HEIGHT_SPANS


## Create a new NavigationMesh with default configuration
static func create_navmesh() -> NavigationMesh:
	var nav_mesh := NavigationMesh.new()
	apply_to_navmesh(nav_mesh)
	return nav_mesh


## Get estimated memory usage for a baked navmesh (rough estimate)
## Based on typical polygon counts for a 117m × 117m Morrowind cell
static func estimate_navmesh_size_mb(cell_count: int = 1) -> float:
	# Typical baked navmesh: ~500-2000 polygons per exterior cell
	# Each polygon: ~100-200 bytes (vertices, edges, adjacency)
	# Plus metadata and lookup structures
	const BYTES_PER_CELL_AVERAGE: int = 150_000  # ~150 KB per cell
	return (cell_count * BYTES_PER_CELL_AVERAGE) / 1_048_576.0  # Convert to MB


## Get configuration summary for logging
static func get_config_summary() -> String:
	return """NavMesh Configuration:
  Agent: radius=%.2fm, height=%.2fm, climb=%.2fm, slope=%.1f°
  Cells: size=%.2fm, height=%.2fm
  Regions: min=%.0f, merge=%.0f
  Detail: dist=%.1f, error=%.1f
  Edges: max_length=%.1f, max_error=%.1f
  Filtering: obstacles=%s, ledges=%s, low_height=%s""" % [
		AGENT_RADIUS, AGENT_HEIGHT, AGENT_MAX_CLIMB, AGENT_MAX_SLOPE,
		CELL_SIZE, CELL_HEIGHT,
		REGION_MIN_SIZE, REGION_MERGE_SIZE,
		DETAIL_SAMPLE_DIST, DETAIL_SAMPLE_MAX_ERROR,
		EDGE_MAX_LENGTH, EDGE_MAX_ERROR,
		FILTER_LOW_HANGING_OBSTACLES, FILTER_LEDGE_SPANS, FILTER_WALKABLE_LOW_HEIGHT_SPANS
	]


## Validate that navmesh parameters are reasonable
static func validate_config() -> Dictionary:
	var warnings: Array[String] = []
	var errors: Array[String] = []

	# Check for invalid values
	if AGENT_RADIUS <= 0:
		errors.append("AGENT_RADIUS must be > 0")
	if AGENT_HEIGHT <= 0:
		errors.append("AGENT_HEIGHT must be > 0")
	if CELL_SIZE <= 0:
		errors.append("CELL_SIZE must be > 0")
	if CELL_HEIGHT <= 0:
		errors.append("CELL_HEIGHT must be > 0")

	# Check for suboptimal values
	if CELL_SIZE > AGENT_RADIUS:
		warnings.append("CELL_SIZE > AGENT_RADIUS may produce coarse navmesh")
	if CELL_SIZE < AGENT_RADIUS / 8.0:
		warnings.append("CELL_SIZE very small - baking will be slow")
	if REGION_MIN_SIZE < 4:
		warnings.append("REGION_MIN_SIZE very small - may keep tiny islands")

	return {
		"valid": errors.is_empty(),
		"errors": errors,
		"warnings": warnings
	}
