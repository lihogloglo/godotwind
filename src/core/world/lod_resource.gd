## LODResource - Container for prebaked LOD meshes
##
## Stores LOD meshes and materials separately from the main model file.
## This allows on-demand loading of LODs only when objects enter MID tier,
## reducing memory usage for NEAR tier objects.
##
## File format: <model_name>.lod.res
## Contains: Dictionary[lod_level: int] -> {mesh: ArrayMesh, material: Material}
##
## Usage:
##   var lod_res := ResourceLoader.load("path/to/model.lod.res") as LODResource
##   var lod1_mesh := lod_res.get_mesh(1)
##   var lod1_material := lod_res.get_material(1)
class_name LODResource
extends Resource

## LOD data storage: lod_level (1, 2, 3) -> {mesh: ArrayMesh, material: Material}
@export var lod_data: Dictionary = {}


## Get mesh for a specific LOD level
## Returns null if level doesn't exist
func get_mesh(lod_level: int) -> ArrayMesh:
	if lod_level not in lod_data:
		return null
	var entry: Variant = lod_data[lod_level]
	if entry is Dictionary:
		return entry.get("mesh") as ArrayMesh
	return null


## Get material for a specific LOD level
## Returns null if level doesn't exist or has no material
func get_material(lod_level: int) -> Material:
	if lod_level not in lod_data:
		return null
	var entry: Variant = lod_data[lod_level]
	if entry is Dictionary:
		return entry.get("material") as Material
	return null


## Get all available LOD levels
func get_lod_levels() -> Array[int]:
	var levels: Array[int] = []
	for key: int in lod_data.keys():
		levels.append(key)
	levels.sort()
	return levels


## Check if a specific LOD level exists
func has_lod(lod_level: int) -> bool:
	return lod_level in lod_data


## Get count of LOD levels
func get_lod_count() -> int:
	return lod_data.size()
