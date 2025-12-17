## WorldDataProvider - Abstract base class for world terrain data sources
##
## This abstraction allows different world types (Morrowind, La Palma, etc.)
## to share the same streaming infrastructure (Terrain3D, ocean, LOD, etc.)
##
## Implementations must provide:
##   - Heightmap data for terrain regions
##   - World bounds and configuration
##   - Cell/region coordinate mapping
##
## The streaming system calls these methods to load terrain on-demand.
class_name WorldDataProvider
extends RefCounted


## World configuration - set by subclasses
var world_name: String = "Unknown"
var world_bounds: Rect2 = Rect2()  # In world units (meters)
var cell_size: float = 256.0  # Size of one cell in meters
var region_size: int = 256  # Pixels per Terrain3D region
var vertex_spacing: float = 1.0  # Meters per terrain vertex
var sea_level: float = 0.0  # Water level in meters


## Get the heightmap Image for a terrain region
## region_coord: Terrain3D region coordinate (e.g., Vector2i(-5, 3))
## Returns: Image in FORMAT_RF (32-bit float heights), or null if no data
func get_heightmap_for_region(region_coord: Vector2i) -> Image:
	push_error("WorldDataProvider.get_heightmap_for_region() not implemented")
	return null


## Get the control map (texture splatting) for a terrain region
## region_coord: Terrain3D region coordinate
## Returns: Image in FORMAT_RF (Terrain3D control format), or null for default
func get_controlmap_for_region(region_coord: Vector2i) -> Image:
	# Default: return null (use default texture)
	return null


## Get the color map (vertex colors) for a terrain region
## region_coord: Terrain3D region coordinate
## Returns: Image in FORMAT_RGB8, or null for white
func get_colormap_for_region(region_coord: Vector2i) -> Image:
	# Default: return null (white vertex colors)
	return null


## Check if a region has terrain data (for sparse worlds)
## Returns true if the region contains terrain, false for ocean/empty
func has_terrain_at_region(region_coord: Vector2i) -> bool:
	push_error("WorldDataProvider.has_terrain_at_region() not implemented")
	return false


## Get height at a specific world position (for camera placement, etc.)
## world_pos: Position in Godot world coordinates (X east, Z south)
## Returns: Height in meters, or NAN if no data
func get_height_at_position(world_pos: Vector3) -> float:
	return NAN


## Convert world position to region coordinate
func world_pos_to_region(world_pos: Vector3) -> Vector2i:
	var region_world_size := float(region_size) * vertex_spacing
	var rx := floori(world_pos.x / region_world_size)
	var ry := floori(-world_pos.z / region_world_size)  # Z is south in Godot
	return Vector2i(rx, ry)


## Convert region coordinate to world position (CENTER of region for Terrain3D import)
## Terrain3D import_images expects center position for proper region snapping
## Based on terrain_manager.gd which uses: x * size + size * 0.5
func region_to_world_pos(region_coord: Vector2i) -> Vector3:
	var region_world_size := float(region_size) * vertex_spacing
	# CENTER position for proper snapping (matches terrain_manager.gd)
	var x := float(region_coord.x) * region_world_size + region_world_size * 0.5
	var z := -float(region_coord.y) * region_world_size - region_world_size * 0.5  # Negate Y, offset for center
	return Vector3(x, 0, z)


## Get all region coordinates that contain terrain data
## Used for preprocessing or full-world operations
func get_all_terrain_regions() -> Array[Vector2i]:
	push_error("WorldDataProvider.get_all_terrain_regions() not implemented")
	return []


## Get regions within a radius of a center region
## Useful for streaming based on camera position
func get_regions_in_radius(center: Vector2i, radius: int) -> Array[Vector2i]:
	var regions: Array[Vector2i] = []
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx * dx + dy * dy <= radius * radius:
				var coord := Vector2i(center.x + dx, center.y + dy)
				if has_terrain_at_region(coord):
					regions.append(coord)
	return regions


## Initialize the provider (load metadata, etc.)
## Returns OK on success, or an error code
func initialize() -> Error:
	push_error("WorldDataProvider.initialize() not implemented")
	return FAILED


## Get configuration dictionary for UI display
func get_config() -> Dictionary:
	return {
		"name": world_name,
		"bounds": world_bounds,
		"cell_size": cell_size,
		"region_size": region_size,
		"vertex_spacing": vertex_spacing,
		"sea_level": sea_level,
	}
