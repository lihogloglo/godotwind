## Source-neutral Terrain3D region helpers.
class_name TerrainManager
extends RefCounted

## Number of source cells per Terrain3D region axis.
const CELLS_PER_REGION: int = 4


## Calculate which Terrain3D region a source cell belongs to.
static func cell_to_region(cell_coord: Vector2i) -> Vector2i:
	return Vector2i(
		floori(float(cell_coord.x) / float(CELLS_PER_REGION)),
		floori(float(cell_coord.y) / float(CELLS_PER_REGION))
	)


## Calculate the local position of a source cell within its Terrain3D region.
static func cell_local_in_region(cell_coord: Vector2i) -> Vector2i:
	return Vector2i(
		posmod(cell_coord.x, CELLS_PER_REGION),
		posmod(cell_coord.y, CELLS_PER_REGION)
	)


## Get the southwest/minimum source cell of a Terrain3D region.
static func region_to_sw_cell(region_coord: Vector2i) -> Vector2i:
	return Vector2i(region_coord.x * CELLS_PER_REGION, region_coord.y * CELLS_PER_REGION)


## Get cells in a square radius around a center cell.
static func get_cells_in_radius(center_x: int, center_y: int, radius: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for y in range(center_y - radius, center_y + radius + 1):
		for x in range(center_x - radius, center_x + radius + 1):
			cells.append(Vector2i(x, y))
	return cells
