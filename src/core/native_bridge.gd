## NativeBridge - Bridge to high-performance C# code
##
## This module provides access to C# implementations of performance-critical code.
## Falls back to GDScript implementations when C# is not available.
##
## For Godot 4.x C#, classes must be instantiated via script loading (not ClassDB).
## This uses NativeFactory which provides factory methods for all native classes.
##
## Available C# implementations:
## - NIFReader: 20-50x faster NIF parsing
## - NIFConverter: 2-5x faster mesh building
## - TerrainGenerator: Faster heightmap/controlmap generation
##
## Usage:
##   var bridge := NativeBridge.new()
##   if bridge.has_native_nif():
##       var mesh_data := bridge.convert_nif_mesh(nif_buffer, "model.nif")
##

# Disable strict typing warnings for dynamic C# interop
@warning_ignore("untyped_declaration")
@warning_ignore("unsafe_method_access")
@warning_ignore("unsafe_property_access")
@warning_ignore("unsafe_cast")

class_name NativeBridge
extends RefCounted

## Path to the NativeFactory C# script
const NATIVE_FACTORY_PATH := "res://src/native/NativeFactory.cs"

## Cached factory instance (creates all native objects)
static var _factory: RefCounted = null

## Whether we have checked for native availability
static var _checked: bool = false

## Whether native C# code is available
static var _native_available: bool = false

## Whether native NIF processing is available
static var _nif_native_available: bool = false

func _init() -> void:
	_check_native_availability()

## Check if C# classes are available by trying to load the factory
static func _check_native_availability() -> void:
	if _checked:
		return
	_checked = true

	# Try to load the NativeFactory C# script
	if not ResourceLoader.exists(NATIVE_FACTORY_PATH):
		print("NativeBridge: Native factory not found at %s" % NATIVE_FACTORY_PATH)
		return

	var factory_script: Resource = load(NATIVE_FACTORY_PATH)
	if factory_script == null:
		print("NativeBridge: Failed to load native factory script")
		return

	# Try to instantiate the factory (CSharpScript.new() returns RefCounted)
	# Must use call() since Script.new() isn't statically typed
	_factory = factory_script.call("new") as RefCounted
	if _factory == null:
		print("NativeBridge: Failed to instantiate native factory")
		return

	# Check if factory is working
	if not _factory.call("IsAvailable"):
		print("NativeBridge: Native factory reported not available")
		_factory = null
		return

	# Native code is available!
	_native_available = true
	_nif_native_available = true

	var version: String = _factory.call("GetVersion")
	print("NativeBridge: Native C# code available (version %s)" % version)

## Returns true if native C# terrain generation is available
func has_native_terrain() -> bool:
	return _native_available

## Returns true if native C# binary reader is available
func has_native_binary_reader() -> bool:
	return _native_available

## Generate a heightmap from raw height data using C# (if available)
## heights: PackedFloat32Array with 65*65=4225 values
## Returns: Image in FORMAT_RF or null if native not available
func generate_heightmap(heights: PackedFloat32Array) -> Image:
	if not has_native_terrain() or _factory == null:
		return null

	var generator: RefCounted = _factory.call("CreateTerrainGenerator")
	if generator == null:
		return null

	# Convert PackedFloat32Array to Array for C# interop
	var height_array: Array[float] = []
	height_array.resize(heights.size())
	for i in range(heights.size()):
		height_array[i] = heights[i]

	return generator.call("GenerateHeightmap", height_array)

## Generate a color map from raw color data using C#
## colors: PackedByteArray with 65*65*3=12675 RGB values
## Returns: Image in FORMAT_RGB8 or null if native not available
func generate_color_map(colors: PackedByteArray) -> Image:
	if not has_native_terrain() or _factory == null:
		return null

	var generator: RefCounted = _factory.call("CreateTerrainGenerator")
	if generator == null:
		return null

	return generator.call("GenerateColorMap", colors)

## Generate a control map from texture indices using C#
## texture_indices: PackedInt32Array with 16*16=256 values
## slot_mapper: Optional callable that maps MW texture index to Terrain3D slot
## Returns: Image in FORMAT_RF or null if native not available
func generate_control_map(texture_indices: PackedInt32Array, slot_mapper: Callable = Callable()) -> Image:
	if not has_native_terrain() or _factory == null:
		return null

	var generator: RefCounted = _factory.call("CreateTerrainGenerator")
	if generator == null:
		return null

	# Convert PackedInt32Array to Array for C# interop
	var tex_array: Array[int] = []
	tex_array.resize(texture_indices.size())
	for i in range(texture_indices.size()):
		tex_array[i] = texture_indices[i]

	return generator.call("GenerateControlMap", tex_array)

## Create a native binary reader instance
## Returns: NativeBinaryReader or null if not available
func create_binary_reader() -> RefCounted:
	if not has_native_binary_reader() or _factory == null:
		return null
	return _factory.call("CreateBinaryReader")

## Get performance comparison stats (for debugging)
func get_performance_info() -> Dictionary:
	return {
		"native_available": _native_available,
		"factory_loaded": _factory != null,
		"terrain_generator": has_native_terrain(),
		"binary_reader": has_native_binary_reader(),
		"nif_processing": has_native_nif(),
	}


## Static helper to check if C# is available at all
static func is_csharp_available() -> bool:
	_check_native_availability()
	return _native_available


# =============================================================================
# NIF PROCESSING (High-performance mesh conversion)
# =============================================================================

## Returns true if native C# NIF processing is available
func has_native_nif() -> bool:
	return _nif_native_available


## Create a native NIFReader instance
## Returns: NIFReader C# object or null if not available
func create_nif_reader() -> RefCounted:
	if not has_native_nif() or _factory == null:
		return null
	return _factory.call("CreateNIFReader")


## Create a native NIFConverter instance
## Returns: NIFConverter C# object or null if not available
func create_nif_converter() -> RefCounted:
	if not has_native_nif() or _factory == null:
		return null
	return _factory.call("CreateNIFConverter")


## Parse a NIF buffer using C# (much faster than GDScript)
## Returns: NIFReader C# object with parsed data, or null on failure
func parse_nif_buffer(data: PackedByteArray, path_hint: String = "") -> RefCounted:
	if not has_native_nif() or _factory == null:
		return null

	var reader: RefCounted = _factory.call("ParseNIFBuffer", data, path_hint)
	return reader


## Convert a NIF geometry record to Godot mesh arrays using C#
## reader: NIFReader C# object from parse_nif_buffer()
## data_index: Index of NiTriShapeData or NiTriStripsData record
## Returns: Dictionary with mesh arrays, or empty dict on failure
@warning_ignore("unsafe_method_access")
func convert_nif_geometry(reader: RefCounted, data_index: int) -> Dictionary:
	if not has_native_nif() or reader == null or _factory == null:
		return {}

	var converter: RefCounted = _factory.call("CreateNIFConverter")
	if converter == null:
		return {}

	# Try to determine the record type and call appropriate method
	var record: Object = reader.call("GetRecord", data_index) as Object
	if record == null:
		return {}

	var result: Object = null
	var record_type: String = record.get("RecordType") if record.has_method("get") else ""

	# Call the appropriate conversion method based on record type
	if record_type == "NiTriShapeData":
		result = converter.call("ConvertTriShapeData", reader, data_index)
	elif record_type == "NiTriStripsData":
		result = converter.call("ConvertTriStripsData", reader, data_index)
	else:
		push_warning("NativeBridge: Unknown geometry type at index %d" % data_index)
		return {}

	if result == null or not result.call("get_Success"):
		var error_msg: String = result.call("get_Error") if result else "null result"
		push_error("NativeBridge: NIF conversion failed: %s" % error_msg)
		return {}

	# Return the result as a dictionary for GDScript use
	return {
		"success": true,
		"vertices": result.call("get_Vertices"),
		"normals": result.call("get_Normals"),
		"uvs": result.call("get_UVs"),
		"colors": result.call("get_Colors"),
		"indices": result.call("get_Indices"),
		"center": result.call("get_Center"),
		"radius": result.call("get_Radius"),
		"vertex_count": result.call("get_VertexCount"),
		"triangle_count": result.call("get_TriangleCount"),
		"godot_arrays": result.call("ToGodotArrays"),
	}


## Create an ArrayMesh from C# conversion result
## result: MeshConversionResult from NIFConverter
## Returns: ArrayMesh or null on failure
func create_mesh_from_result(result: RefCounted) -> ArrayMesh:
	if result == null:
		return null
	return result.call("ToArrayMesh")


## Batch convert multiple geometry records (more efficient)
## reader: NIFReader C# object
## data_indices: Array of geometry data record indices
## Returns: Array of conversion results
@warning_ignore("unsafe_method_access")
func batch_convert_geometries(reader: RefCounted, data_indices: PackedInt32Array) -> Array:
	if not has_native_nif() or reader == null or _factory == null:
		return []

	var converter: RefCounted = _factory.call("CreateNIFConverter")
	if converter == null:
		return []

	var results: Array = converter.call("BatchConvertShapes", reader, data_indices) as Array
	if results == null or results.is_empty():
		return []

	# Convert C# array to GDScript array
	var output: Array = []
	for result: Object in results:
		if result != null and result.call("get_Success"):
			output.append({
				"success": true,
				"mesh": result.call("ToArrayMesh"),
				"vertex_count": result.call("get_VertexCount"),
				"triangle_count": result.call("get_TriangleCount"),
			})
		else:
			output.append({"success": false})

	return output


## Simplify a mesh using C# (for LOD generation)
## vertices: PackedVector3Array
## indices: PackedInt32Array
## target_ratio: float (0.5 = half triangles)
## Returns: Simplified indices array
func simplify_mesh(vertices: PackedVector3Array, indices: PackedInt32Array, target_ratio: float) -> PackedInt32Array:
	if not has_native_nif() or _factory == null:
		return indices  # Return original if C# not available

	var converter: RefCounted = _factory.call("CreateNIFConverter")
	if converter == null:
		return indices

	var result: Variant = converter.call("SimplifyMesh", vertices, indices, target_ratio)
	if result == null:
		return indices

	return result


# =============================================================================
# FULL NATIVE NIF PIPELINE (Maximum Performance)
# =============================================================================

## Full native NIF pipeline: Parse + Convert to Godot Node3D in one call.
## This is the FASTEST way to load NIF models - 20-50x faster than GDScript.
##
## Returns a Dictionary with:
##   - "success": bool - Whether conversion succeeded
##   - "error": String - Error message if failed
##   - "root": Node3D - Root node with MeshInstance3D children
##   - "mesh_count": int - Number of meshes created
##   - "total_vertices": int - Total vertex count
##   - "total_triangles": int - Total triangle count
##   - "texture_paths": Array[String] - Texture paths for loading
##
## Material info is stored as metadata on each MeshInstance3D:
##   mesh_instance.get_meta("nif_material") returns Dictionary with:
##     - "texture_path": String - Base texture path
##     - "glow_texture_path": String - Glow texture path (if any)
##     - "diffuse": Color, "ambient": Color, etc.
##     - "alpha": float, "blend_enabled": bool, "test_enabled": bool
##
## Usage:
##   var bridge = NativeBridge.new()
##   var result = bridge.convert_nif_to_scene(buffer, "model.nif")
##   if result.success:
##       add_child(result.root)
##       _apply_textures(result.root, result.texture_paths)
@warning_ignore("unsafe_method_access")
@warning_ignore("unsafe_property_access")
func convert_nif_to_scene(data: PackedByteArray, path_hint: String = "") -> Dictionary:
	if not has_native_nif() or _factory == null:
		return {"success": false, "error": "Native NIF processing not available"}

	var conversion_result: Object = _factory.call("ConvertNIFToScene", data, path_hint) as Object
	if conversion_result == null:
		return {"success": false, "error": "ConvertNIFToScene returned null"}

	# C# properties are accessed via .get() or direct property access, not get_PropertyName()
	var success: bool = conversion_result.get("Success")
	if not success:
		var error: String = conversion_result.get("Error")
		return {"success": false, "error": error}

	# Extract result data using .get() for C# properties
	var root_node: Node3D = conversion_result.get("RootNode") as Node3D
	var mesh_count: int = conversion_result.get("MeshCount")
	var total_verts: int = conversion_result.get("TotalVertices")
	var total_tris: int = conversion_result.get("TotalTriangles")

	# Convert texture paths list to GDScript array
	var tex_paths_obj: Variant = conversion_result.get("TexturePaths")
	var texture_paths: Array[String] = []
	if tex_paths_obj != null and tex_paths_obj is Array:
		for path: Variant in tex_paths_obj:
			if path is String:
				texture_paths.append(path as String)

	return {
		"success": true,
		"error": "",
		"root": root_node,
		"mesh_count": mesh_count,
		"total_vertices": total_verts,
		"total_triangles": total_tris,
		"texture_paths": texture_paths
	}


## Convert a pre-parsed NIF reader to a scene.
## Use when you already have a native reader from parse_nif_buffer().
@warning_ignore("unsafe_method_access")
@warning_ignore("unsafe_property_access")
func convert_reader_to_scene(reader: RefCounted, path_hint: String = "") -> Dictionary:
	if not has_native_nif() or _factory == null or reader == null:
		return {"success": false, "error": "Native NIF processing not available or null reader"}

	var conversion_result: Object = _factory.call("ConvertReaderToScene", reader, path_hint) as Object
	if conversion_result == null:
		return {"success": false, "error": "ConvertReaderToScene returned null"}

	# C# properties are accessed via .get()
	var success: bool = conversion_result.get("Success")
	if not success:
		var error: String = conversion_result.get("Error")
		return {"success": false, "error": error}

	var root_node: Node3D = conversion_result.get("RootNode") as Node3D
	var mesh_count: int = conversion_result.get("MeshCount")
	var total_verts: int = conversion_result.get("TotalVertices")
	var total_tris: int = conversion_result.get("TotalTriangles")

	var tex_paths_obj: Variant = conversion_result.get("TexturePaths")
	var texture_paths: Array[String] = []
	if tex_paths_obj != null and tex_paths_obj is Array:
		for path: Variant in tex_paths_obj:
			if path is String:
				texture_paths.append(path as String)

	return {
		"success": true,
		"error": "",
		"root": root_node,
		"mesh_count": mesh_count,
		"total_vertices": total_verts,
		"total_triangles": total_tris,
		"texture_paths": texture_paths
	}


# =============================================================================
# ESM PROCESSING (High-performance record loading)
# =============================================================================

## Returns true if native C# ESM processing is available
func has_native_esm() -> bool:
	return _native_available


## Create a native ESM loader instance
## Returns: NativeESMLoader C# object or null if not available
func create_esm_loader() -> RefCounted:
	if not has_native_esm() or _factory == null:
		return null
	return _factory.call("CreateESMLoader")


## Load an ESM file using C# (10-30x faster than GDScript)
## Returns: NativeESMLoader C# object with all records, or null on failure
## Parameters:
##   path: Path to the ESM/ESP file
##   lazy_load_references: If true, defer loading cell references for exterior cells
@warning_ignore("unsafe_method_access")
func load_esm_file(path: String, lazy_load_references: bool = true) -> RefCounted:
	if not has_native_esm() or _factory == null:
		return null

	var loader: RefCounted = _factory.call("LoadESMFile", path, lazy_load_references)
	return loader


## Load an ESM file with caching support (<50ms on subsequent loads)
## Returns: NativeESMLoader C# object with all records, or null on failure
## Parameters:
##   esm_path: Path to the ESM/ESP file
##   cache_path: Optional custom cache path (defaults to Documents/Godotwind/cache/)
@warning_ignore("unsafe_method_access")
func load_esm_file_cached(esm_path: String, cache_path: String = "") -> RefCounted:
	if not has_native_esm() or _factory == null:
		return null

	var loader: RefCounted
	if cache_path.is_empty():
		loader = _factory.call("LoadESMFileWithCache", esm_path)
	else:
		loader = _factory.call("LoadESMFileWithCachePath", esm_path, cache_path)
	return loader


## Check if a valid ESM cache exists
@warning_ignore("unsafe_method_access")
func esm_cache_exists(esm_path: String) -> bool:
	if not has_native_esm() or _factory == null:
		return false
	return _factory.call("ESMCacheExists", esm_path)


## Get the default cache path for an ESM file
@warning_ignore("unsafe_method_access")
func get_esm_cache_path(esm_path: String) -> String:
	if not has_native_esm() or _factory == null:
		return ""
	var result: Variant = _factory.call("GetESMCachePath", esm_path)
	return result if result is String else ""


## Get a model path from the ESM loader by record ID
## loader: NativeESMLoader C# object from load_esm_file()
## record_id: The base object ID (e.g., "barrel_01")
## Returns: Model path string or empty string if not found
@warning_ignore("unsafe_method_access")
func get_model_path(loader: RefCounted, record_id: String) -> String:
	if loader == null:
		return ""
	var result: Variant = loader.call("GetModelPath", record_id)
	return result if result is String else ""


## Get an exterior cell from the ESM loader
## loader: NativeESMLoader C# object
## grid_x, grid_y: Cell grid coordinates
## Returns: NativeCellRecord C# object or null if not found
@warning_ignore("unsafe_method_access")
func get_exterior_cell(loader: RefCounted, grid_x: int, grid_y: int) -> RefCounted:
	if loader == null:
		return null
	return loader.call("GetExteriorCell", grid_x, grid_y) as RefCounted


## Get a cell's references array
## cell: NativeCellRecord C# object
## Returns: Array of NativeCellReference objects
@warning_ignore("unsafe_method_access")
func get_cell_references(cell: RefCounted) -> Array:
	if cell == null:
		return []
	var refs: Variant = cell.get("References")
	return refs if refs is Array else []


## Get ESM loader statistics
## loader: NativeESMLoader C# object
## Returns: Dictionary with load statistics
@warning_ignore("unsafe_method_access")
func get_esm_stats(loader: RefCounted) -> Dictionary:
	if loader == null:
		return {}

	# Get counts with proper casting to avoid strict typing errors
	var statics_count := 0
	var cells_count := 0
	var exterior_count := 0

	var statics_v: Variant = loader.get("Statics")
	if statics_v is Dictionary:
		var statics_d: Dictionary = statics_v as Dictionary
		statics_count = statics_d.size()

	var cells_v: Variant = loader.get("Cells")
	if cells_v is Dictionary:
		var cells_d: Dictionary = cells_v as Dictionary
		cells_count = cells_d.size()

	var exterior_v: Variant = loader.get("ExteriorCells")
	if exterior_v is Dictionary:
		var exterior_d: Dictionary = exterior_v as Dictionary
		exterior_count = exterior_d.size()

	return {
		"total_records": loader.get("TotalRecordsLoaded"),
		"load_time_ms": loader.get("LoadTimeMs"),
		"statics_count": statics_count,
		"cells_count": cells_count,
		"exterior_cells_count": exterior_count,
	}
