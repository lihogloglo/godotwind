# Individual texture entry for terrain deformation configuration
class_name TerrainDeformationTextureEntry
extends Resource

## Terrain3D texture slot ID (0-31)
@export_range(0, 31, 1) var texture_id: int = 0

## Deformation rest height in meters (0.0 = no deformation)
@export_range(0.0, 1.0, 0.01, "or_greater") var rest_height: float = 0.0

## Human-readable name for this texture (optional, for editor clarity)
@export var texture_name: String = ""

## Category/type hint (optional)
@export_enum("Soft", "Medium", "Hard") var category: String = "Medium"

## Notes (optional)
@export_multiline var notes: String = ""
