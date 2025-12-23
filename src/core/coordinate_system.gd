## Unified Coordinate System Conversion
## Single source of truth for ALL Morrowind <-> Godot coordinate conversions
##
## DESIGN PRINCIPLE:
##   The Godotwind framework works in METERS (Godot's native unit).
##   Morrowind-specific conversion (units + axis swap) happens at the IMPORT BOUNDARY.
##   All game logic, physics, rendering works in standard Godot meters.
##
## Morrowind/NIF coordinate system:
##   - X-axis: East (positive) / West (negative)
##   - Y-axis: North (positive) / South (negative)  [Forward]
##   - Z-axis: Up (positive) / Down (negative)
##   - Units: ~70 units = 1 meter (1.4 units = 1 inch)
##   - Right-handed coordinate system
##
## Godot coordinate system:
##   - X-axis: East (positive) / West (negative)
##   - Y-axis: Up (positive) / Down (negative)
##   - Z-axis: South (positive) / North (negative)  [Back = -Forward]
##   - Units: meters
##   - Right-handed coordinate system
##
## The fundamental conversion:
##   MW (x, y, z) -> Godot (x, z, -y) * scale
##   - X stays the same (both East)
##   - MW Y (North) -> Godot -Z (North is negative Z)
##   - MW Z (Up) -> Godot Y (Up)
##   - Scale by 1/70 to convert to meters
##
## USAGE:
##   All NIF geometry, world positions, rotations, and transforms should use
##   these functions. No other file should implement coordinate conversion.
##   After conversion, all values are in METERS with Godot's axis convention.
class_name CoordinateSystem
extends RefCounted


#region Constants

## Morrowind units per meter (approximate)
## Morrowind uses roughly 70 units per meter (1.4 units per inch)
const UNITS_PER_METER: float = 70.0

## Morrowind cell size in game units
const CELL_SIZE_MW: float = 8192.0

## Morrowind cell size in Godot meters
const CELL_SIZE_GODOT: float = CELL_SIZE_MW / UNITS_PER_METER  # ~117.03

## Terrain3D configuration constants (for consistent setup across tools)
## Morrowind LAND records have 65x65 vertices per cell (we crop to 64 to avoid overlap)
const TERRAIN_VERTICES_PER_CELL: int = 64
## Vertex spacing in Godot meters (cell size / vertices = ~1.83m per vertex)
const TERRAIN_VERTEX_SPACING: float = CELL_SIZE_GODOT / TERRAIN_VERTICES_PER_CELL
## Terrain3D region size: 256 vertices = 4x4 MW cells per region
const TERRAIN_REGION_SIZE: int = 256

## Whether to apply unit scaling when converting positions
## TRUE: All positions converted to meters (RECOMMENDED - framework standard)
## FALSE: Keep raw MW units (legacy mode, requires manual scaling)
const APPLY_SCALE: bool = true  # Framework works in meters

## Scale factor for converting MW units to meters
const SCALE_FACTOR: float = 1.0 / UNITS_PER_METER

## The coordinate conversion matrix
## Transforms MW coords to Godot coords: (x,y,z) -> (x,z,-y)
## This is an orthogonal matrix so inverse = transpose
const CONVERSION_MATRIX := Basis(
	Vector3(1, 0, 0),   # MW X -> Godot X
	Vector3(0, 0, 1),   # MW Z -> Godot Y
	Vector3(0, -1, 0)   # MW Y -> Godot -Z
)

#endregion


#region Vector Conversion

## Convert a position/vector from Morrowind to Godot coordinates
## Use for: world positions, NIF vertices, NIF normals, bone positions
static func vector_to_godot(mw: Vector3, apply_scale: bool = APPLY_SCALE) -> Vector3:
	var converted := Vector3(mw.x, mw.z, -mw.y)
	if apply_scale:
		return converted * SCALE_FACTOR
	return converted


## Convert a position/vector from Godot to Morrowind coordinates
static func vector_to_mw(godot: Vector3, apply_scale: bool = APPLY_SCALE) -> Vector3:
	var unscaled := godot / SCALE_FACTOR if apply_scale else godot
	return Vector3(unscaled.x, -unscaled.z, unscaled.y)


## Convert an array of vectors from Morrowind to Godot coordinates
## Use for: vertex arrays, normal arrays
static func vectors_to_godot(mw_vectors: PackedVector3Array, apply_scale: bool = APPLY_SCALE) -> PackedVector3Array:
	var result := PackedVector3Array()
	result.resize(mw_vectors.size())
	for i in range(mw_vectors.size()):
		result[i] = vector_to_godot(mw_vectors[i], apply_scale)
	return result

#endregion


#region Rotation Conversion

## Convert a quaternion from Morrowind to Godot coordinates
## Use for: NIF keyframe rotations, bone rotations
##
## For quaternions representing rotation around axis (x,y,z):
## MW axis (x,y,z) -> Godot axis (x,z,-y)
## The quaternion components transform as: (x,y,z,w) -> (x,z,-y,w)
static func quaternion_to_godot(mw: Quaternion) -> Quaternion:
	return Quaternion(mw.x, mw.z, -mw.y, mw.w)


## Convert a quaternion from Godot to Morrowind coordinates
static func quaternion_to_mw(godot: Quaternion) -> Quaternion:
	return Quaternion(godot.x, -godot.z, godot.y, godot.w)


## Convert Euler angles (radians) from Morrowind to Godot
## Use for: ESM cell reference rotations
##
## Morrowind Euler convention (intrinsic XYZ order):
##   X = pitch (tilt forward/back around X/East axis)
##   Y = roll (tilt left/right around Y/North axis)
##   Z = yaw (turn around Z/Up vertical axis)
##   Order: First X, then Y, then Z (intrinsic XYZ)
##   Reference: OpenMW apps/openmw/mwworld/worldimp.cpp
##
## Godot Euler (after coordinate conversion):
##   X = pitch (MW X -> Godot X, stays same)
##   Y = yaw (MW Z -> Godot Y, because vertical axis Z->Y)
##   Z = roll (MW Y -> Godot -Z, because forward axis Y->-Z)
##   Order: Intrinsic XYZ in MW becomes intrinsic XZY in Godot
##
## IMPORTANT: When applying, use Basis.from_euler(euler, EULER_ORDER_XZY)
static func euler_to_godot(mw: Vector3) -> Vector3:
	return Vector3(mw.x, mw.z, -mw.y)


## Convert Euler angles from Godot to Morrowind
static func euler_to_mw(godot: Vector3) -> Vector3:
	return Vector3(godot.x, -godot.z, godot.y)

#endregion


#region Basis/Transform Conversion

## Convert a basis (rotation matrix) from Morrowind to Godot coordinates
## Use for: NIF node transforms, bone transforms, collision shape orientations
##
## For a rotation matrix R, the converted matrix is: R' = C * R * C^T
## where C is CONVERSION_MATRIX and C^T is its transpose (= inverse for orthogonal)
static func basis_to_godot(mw: Basis) -> Basis:
	# Optimized form of C * mw * C^T
	# Each column of result = C * (column of mw transformed by C^T)
	return Basis(
		Vector3(mw.x.x, mw.x.z, -mw.x.y),   # Column 0
		Vector3(mw.z.x, mw.z.z, -mw.z.y),   # Column 1 (was MW Z)
		Vector3(-mw.y.x, -mw.y.z, mw.y.y)   # Column 2 (was MW -Y)
	)


## Convert a basis from Godot to Morrowind coordinates
static func basis_to_mw(godot: Basis) -> Basis:
	# Inverse operation: C^T * godot * C
	return Basis(
		Vector3(godot.x.x, -godot.x.z, godot.x.y),
		Vector3(-godot.z.x, godot.z.z, -godot.z.y),
		Vector3(godot.y.x, -godot.y.z, godot.y.y)
	)


## Convert a full transform from Morrowind to Godot coordinates
## Use for: NIF node transforms, bone rest poses
static func transform_to_godot(mw: Transform3D, apply_scale: bool = APPLY_SCALE) -> Transform3D:
	return Transform3D(
		basis_to_godot(mw.basis),
		vector_to_godot(mw.origin, apply_scale)
	)


## Convert a full transform from Godot to Morrowind coordinates
static func transform_to_mw(godot: Transform3D, apply_scale: bool = APPLY_SCALE) -> Transform3D:
	return Transform3D(
		basis_to_mw(godot.basis),
		vector_to_mw(godot.origin, apply_scale)
	)

#endregion


#region Scale Conversion

## Convert Morrowind uniform scale to Godot scale vector
## Morrowind uses a single float for uniform scaling
static func scale_to_godot(mw_scale: float) -> Vector3:
	return Vector3.ONE * mw_scale

#endregion


#region Cell Grid Utilities

## Get exterior cell grid coordinates from Morrowind world position
## Each exterior cell is 8192 x 8192 Morrowind units
static func world_to_cell_grid(mw_pos: Vector3) -> Vector2i:
	return Vector2i(
		floori(mw_pos.x / CELL_SIZE_MW),
		floori(mw_pos.y / CELL_SIZE_MW)
	)


## Get Morrowind world position of cell origin (southwest corner)
static func cell_grid_to_world_mw(grid: Vector2i) -> Vector3:
	return Vector3(
		grid.x * CELL_SIZE_MW,
		grid.y * CELL_SIZE_MW,
		0.0
	)


## Get Godot world position of cell origin (southwest corner)
## Note: In Godot coords, SW corner has minimum X and MAXIMUM Z (south = +Z)
static func cell_grid_to_world_godot(grid: Vector2i, apply_scale: bool = APPLY_SCALE) -> Vector3:
	return vector_to_godot(cell_grid_to_world_mw(grid), apply_scale)


## Get Godot world position of cell CENTER
## This is the correct position for terrain region placement and camera teleports
static func cell_grid_to_center_godot(grid: Vector2i, apply_scale: bool = APPLY_SCALE) -> Vector3:
	var origin := cell_grid_to_world_godot(grid, apply_scale)
	var half_cell := CELL_SIZE_GODOT / 2.0 if apply_scale else CELL_SIZE_MW / 2.0
	# X: add half to move from west edge toward east (center)
	# Z: subtract half to move from south edge toward north (center)
	#    Because in Godot, north = -Z, south = +Z
	return origin + Vector3(half_cell, 0.0, -half_cell)


## Get cell grid from Godot world position
static func godot_pos_to_cell_grid(godot_pos: Vector3, apply_scale: bool = APPLY_SCALE) -> Vector2i:
	var mw_pos := vector_to_mw(godot_pos, apply_scale)
	return world_to_cell_grid(mw_pos)

#endregion


#region Height Conversion (for Terrain)

## Convert a Morrowind height value to Godot height
## Heights are typically stored as deltas in LAND records
## The decoded MW height should be scaled to meters
static func height_to_godot(mw_height: float) -> float:
	return mw_height * SCALE_FACTOR


## Convert terrain Y index for image generation
## Morrowind: y=0 is south, y=64 is north
## Godot/Image: y=0 is top (north in world), y=64 is bottom (south)
## This flips the Y axis for heightmap images
static func terrain_y_to_image_y(mw_y: int, size: int = 65) -> int:
	return size - 1 - mw_y

#endregion


#region Terrain3D Configuration

## Configure a Terrain3D node with Morrowind-appropriate settings
## This is the single source of truth for terrain configuration.
## Use this instead of repeating configuration in multiple files.
##
## Parameters:
##   terrain: The Terrain3D node to configure
##   create_material: Whether to create a new Terrain3DMaterial if missing (default: true)
##   create_assets: Whether to create new Terrain3DAssets if missing (default: true)
##
## Returns: true if configuration succeeded, false otherwise
static func configure_terrain3d(terrain: Terrain3D, create_material: bool = true, create_assets: bool = true) -> bool:
	if not terrain:
		push_error("CoordinateSystem.configure_terrain3d: terrain is null")
		return false

	# Set vertex spacing for Morrowind cells
	terrain.vertex_spacing = TERRAIN_VERTEX_SPACING

	# Set region size (256 = 4x4 MW cells per region)
	# Suppressing warnings because Godot's enum handling is strict
	@warning_ignore("int_as_enum_without_cast", "int_as_enum_without_match")
	terrain.change_region_size(TERRAIN_REGION_SIZE)

	# Configure mesh LOD settings for performance
	terrain.mesh_lods = 7
	terrain.mesh_size = 48

	# Create material if needed
	if create_material and not terrain.material:
		terrain.set_material(Terrain3DMaterial.new())
		terrain.material.show_checkered = false

	# Create assets if needed
	if create_assets and not terrain.assets:
		terrain.set_assets(Terrain3DAssets.new())

	return true

#endregion
