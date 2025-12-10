## Morrowind Coordinate System Utilities
## Handles conversion between Morrowind and Godot coordinate systems
##
## Morrowind coordinate system:
##   - X-axis: East (positive) / West (negative)
##   - Y-axis: North (positive) / South (negative)
##   - Z-axis: Up (positive) / Down (negative)
##   - Units: ~1.4 units = 1 inch, so ~70 units ≈ 1 meter
##
## Godot coordinate system:
##   - X-axis: Right/East (positive) / Left/West (negative)
##   - Y-axis: Up (positive) / Down (negative)
##   - Z-axis: Forward/South (negative) / Back/North (positive)
##
## Conversion strategy:
##   - X stays the same (both are East)
##   - Y (MW North) -> -Z (Godot)
##   - Z (MW Up) -> Y (Godot)
##
## IMPORTANT: NIF models already have coordinate conversion applied via rotation
## in nif_converter.gd (rotation.x = -PI/2). Cell positions need manual conversion.
class_name MorrowindCoords
extends RefCounted

## Morrowind units per meter (approximate)
## Morrowind uses roughly 70 units per meter (1.4 units per inch)
const UNITS_PER_METER: float = 70.0

## Scale factor to convert Morrowind units to Godot meters
## Set to 1.0 to keep original scale (Morrowind units)
## Set to 1.0/70.0 to convert to meters
const SCALE_FACTOR: float = 1.0  # Keep original Morrowind scale for now


## Convert a Morrowind world position to Godot position
## This is for ESM cell reference positions, NOT for NIF internal coordinates
## NIF coordinates are handled by the rotation in nif_converter.gd
static func position_to_godot(mw_pos: Vector3) -> Vector3:
	# MW: X=East, Y=North, Z=Up
	# Godot: X=East, Y=Up, Z=-North (South)
	return Vector3(
		mw_pos.x * SCALE_FACTOR,
		mw_pos.z * SCALE_FACTOR,
		-mw_pos.y * SCALE_FACTOR
	)


## Convert a Godot position back to Morrowind world position
static func position_to_morrowind(godot_pos: Vector3) -> Vector3:
	return Vector3(
		godot_pos.x / SCALE_FACTOR,
		-godot_pos.z / SCALE_FACTOR,
		godot_pos.y / SCALE_FACTOR
	)


## Convert Morrowind Euler rotation (radians) to Godot Euler rotation
## for use with NIF models that have been pre-rotated by nif_converter.gd
##
## Since NIF models have a -90° X rotation applied at the root to convert
## from Z-up to Y-up, the model's local coordinate system is already Godot-compatible.
## The ESM rotation values just need to be applied directly to the Y axis (yaw).
##
## Morrowind rotation convention:
##   - X rotation: pitch (tilt forward/back)
##   - Y rotation: roll (tilt left/right)
##   - Z rotation: yaw (turn left/right around vertical axis)
##
## For a pre-rotated NIF model in Godot:
##   - Y rotation in Godot = Z rotation in MW (yaw around vertical)
##   - X rotation in Godot = X rotation in MW (pitch)
##   - Z rotation in Godot = -Y rotation in MW (roll, negated due to axis flip)
static func rotation_to_godot(mw_rot: Vector3) -> Vector3:
	return Vector3(
		mw_rot.x,   # Pitch stays on X
		mw_rot.z,   # MW Z-yaw becomes Godot Y-yaw
		-mw_rot.y   # MW Y-roll becomes Godot -Z-roll
	)


## Convert Godot Euler rotation back to Morrowind
static func rotation_to_morrowind(godot_rot: Vector3) -> Vector3:
	return Vector3(
		godot_rot.x,
		-godot_rot.z,
		godot_rot.y
	)


## Convert Morrowind scale to Godot scale
## Morrowind uses uniform scale as a single float
static func scale_to_godot(mw_scale: float) -> Vector3:
	return Vector3.ONE * mw_scale


## Get exterior cell grid coordinates from world position
## Each exterior cell is 8192 x 8192 Morrowind units
static func world_to_cell_grid(mw_pos: Vector3) -> Vector2i:
	const CELL_SIZE: float = 8192.0
	return Vector2i(
		floori(mw_pos.x / CELL_SIZE),
		floori(mw_pos.y / CELL_SIZE)
	)


## Get world position of cell origin (southwest corner)
static func cell_grid_to_world(grid: Vector2i) -> Vector3:
	const CELL_SIZE: float = 8192.0
	return Vector3(
		grid.x * CELL_SIZE,
		grid.y * CELL_SIZE,
		0.0
	)


## Convert cell grid position to Godot coordinates
static func cell_grid_to_godot(grid: Vector2i) -> Vector3:
	return position_to_godot(cell_grid_to_world(grid))
