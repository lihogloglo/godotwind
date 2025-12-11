## Morrowind Coordinate System Utilities
## Convenience wrapper around CoordinateSystem for Morrowind-specific imports.
##
## All functions output values in METERS (Godot's native unit).
## The axis conversion (Z-up to Y-up) and unit scaling happen automatically.
##
## For new code, you can use CoordinateSystem directly.
class_name MorrowindCoords
extends RefCounted

const CS := preload("res://src/core/coordinate_system.gd")

## Morrowind units per meter (approximate)
const UNITS_PER_METER: float = CS.UNITS_PER_METER

## Morrowind cell size in game units
const CELL_SIZE_MW: float = CS.CELL_SIZE_MW

## Morrowind cell size in Godot meters
const CELL_SIZE_GODOT: float = CS.CELL_SIZE_GODOT


## Convert a Morrowind world position to Godot position (in meters)
static func position_to_godot(mw_pos: Vector3) -> Vector3:
	return CS.vector_to_godot(mw_pos)  # Converts to meters


## Convert a Godot position (meters) back to Morrowind world position
static func position_to_morrowind(godot_pos: Vector3) -> Vector3:
	return CS.vector_to_mw(godot_pos)


## Convert Morrowind Euler rotation (radians) to Godot Euler rotation
static func rotation_to_godot(mw_rot: Vector3) -> Vector3:
	return CS.euler_to_godot(mw_rot)


## Convert Godot Euler rotation back to Morrowind
static func rotation_to_morrowind(godot_rot: Vector3) -> Vector3:
	return CS.euler_to_mw(godot_rot)


## Convert Morrowind scale to Godot scale
## Note: Scale is unitless, so no conversion needed
static func scale_to_godot(mw_scale: float) -> Vector3:
	return CS.scale_to_godot(mw_scale)


## Get exterior cell grid coordinates from Morrowind world position
static func world_to_cell_grid(mw_pos: Vector3) -> Vector2i:
	return CS.world_to_cell_grid(mw_pos)


## Get Morrowind world position of cell origin (southwest corner)
## Returns raw MW units (for use with MW data)
static func cell_grid_to_world(grid: Vector2i) -> Vector3:
	return CS.cell_grid_to_world_mw(grid)


## Convert cell grid position to Godot coordinates (in meters)
## Returns the cell origin (southwest corner)
static func cell_grid_to_godot(grid: Vector2i) -> Vector3:
	return CS.cell_grid_to_world_godot(grid)  # Converts to meters


## Convert cell grid position to Godot coordinates for the cell CENTER (in meters)
## Use this for terrain region placement and camera positioning
static func cell_grid_to_center_godot(grid: Vector2i) -> Vector3:
	return CS.cell_grid_to_center_godot(grid)
