## LODPrebaker - Generates simplified LOD meshes for significant objects
##
## Creates LOD1, LOD2, LOD3 meshes for models that need per-object LOD.
## These are used by ObjectDistanceManager for smooth LOD transitions with
## dither crossfade instead of the old per-cell MID tier merged meshes.
##
## Process:
## 1. Scan ImpostorCandidates to find significant models (buildings, landmarks, large rocks)
## 2. Load each model from prebaked cache or convert from NIF
## 3. Generate simplified meshes at LOD1 (50%), LOD2 (25%), LOD3 (10%) ratios
## 4. Save to {cache}/lods/{model_hash}_lod{N}.res
##
## LOD Levels:
##   LOD0: Original mesh (from models cache, 100%)
##   LOD1: 50% triangles (~30m distance)
##   LOD2: 25% triangles (~60m distance)
##   LOD3: 10% triangles (~100m distance)
##   LOD4: Impostor (handled by ImpostorManager, 150m+)
class_name LODPrebaker
extends RefCounted

const MeshOptimizer := preload("res://addons/meshoptimizer/mesh_optimizer.gd")
const ImpostorCandidates := preload("res://src/core/world/impostor_candidates.gd")

## Output directory (set from SettingsManager)
var output_dir: String = ""

## LOD simplification ratios (triangle percentage)
var lod_ratios := {
	1: 0.50,  # LOD1: 50% of original
	2: 0.25,  # LOD2: 25% of original
	3: 0.10,  # LOD3: 10% of original
}

## LOD error tolerances (higher = more aggressive simplification allowed)
## meshoptimizer stops simplifying when target_error is reached, even if target_ratio not met
var lod_errors := {
	1: 0.02,  # LOD1: low error tolerance (preserve details)
	2: 0.05,  # LOD2: medium error tolerance
	3: 0.10,  # LOD3: high error tolerance (aggressive)
}

## Minimum triangles per LOD (don't simplify below this)
## Note: Set low to allow simplification of small meshes
var min_triangles: int = 4

## Skip models that already have all LODs cached
var skip_existing: bool = true

## Progress tracking
signal progress(current: int, total: int, model_name: String)
signal model_baked(model_path: String, success: bool, lod_count: int)
signal batch_complete(total: int, success: int, failed: int, skipped: int)

## Statistics
var _total_baked: int = 0
var _total_failed: int = 0
var _total_skipped: int = 0
var _failed_models: Array[String] = []

## Mesh optimizer instance
var _optimizer: RefCounted = null

## Models cache path
var _models_path: String = ""


## Initialize the baker
func initialize() -> Error:
	# Access SettingsManager autoload dynamically to avoid parse-time errors
	var main_loop: SceneTree = Engine.get_main_loop() as SceneTree
	var settings_manager: Node = null
	if main_loop and main_loop.root:
		settings_manager = main_loop.root.get_node_or_null("/root/SettingsManager")

	if settings_manager == null:
		push_error("LODPrebaker: SettingsManager not available")
		return ERR_UNAVAILABLE

	if output_dir.is_empty():
		output_dir = str(settings_manager.call("get_lods_path"))

	_models_path = str(settings_manager.call("get_models_path"))

	var err: int = settings_manager.call("ensure_cache_directories")
	if err != OK:
		push_error("LODPrebaker: Failed to create cache directories")
		return err as Error

	# Initialize mesh optimizer
	_optimizer = MeshOptimizer.new()
	if _optimizer.is_native_available():
		print("LODPrebaker: Using native meshoptimizer")
	else:
		print("LODPrebaker: Using GDScript fallback simplifier")

	print("LODPrebaker: Initialized - output dir: %s" % output_dir)
	return OK


## Bake LODs for all significant models
func bake_all_lods() -> Dictionary:
	if initialize() != OK:
		return {"success": 0, "failed": 0, "skipped": 0}

	_total_baked = 0
	_total_failed = 0
	_total_skipped = 0
	_failed_models.clear()

	# Get all significant models from ImpostorCandidates
	var candidates := ImpostorCandidates.new()
	var model_paths := candidates.get_all_impostor_models()

	print("LODPrebaker: Found %d significant models to process" % model_paths.size())

	# Bake each model
	for i in range(model_paths.size()):
		var model_path: String = model_paths[i]
		progress.emit(i + 1, model_paths.size(), model_path.get_file())

		# Check if already cached
		if skip_existing and _lods_cached(model_path):
			_total_skipped += 1
			continue

		var result := bake_model_lods(model_path)
		if result.success:
			_total_baked += 1
		else:
			_total_failed += 1
			_failed_models.append(model_path)

		# Yield every 5 models to prevent UI freeze
		if i % 5 == 0:
			var main_loop: SceneTree = Engine.get_main_loop() as SceneTree
			if main_loop:
				await main_loop.process_frame

	batch_complete.emit(model_paths.size(), _total_baked, _total_failed, _total_skipped)

	print("LODPrebaker: Complete - %d baked, %d skipped, %d failed" % [
		_total_baked, _total_skipped, _total_failed])

	return {
		"total": model_paths.size(),
		"success": _total_baked,
		"failed": _total_failed,
		"skipped": _total_skipped,
		"failed_models": _failed_models.duplicate()
	}


## Bake LODs for a single model
func bake_model_lods(model_path: String) -> Dictionary:
	# Load the source model
	var source_scene := _load_source_model(model_path)
	if not source_scene:
		model_baked.emit(model_path, false, 0)
		return {"success": false, "error": "Failed to load source model"}

	# Extract all meshes from the scene
	var mesh_instances: Array[MeshInstance3D] = []
	_find_mesh_instances(source_scene, mesh_instances)

	if mesh_instances.is_empty():
		source_scene.queue_free()
		model_baked.emit(model_path, false, 0)
		return {"success": false, "error": "No meshes found in model"}

	# Generate LODs for each mesh
	var lods_created := 0
	var model_hash := _get_model_hash(model_path)

	for lod_level in [1, 2, 3]:
		var ratio: float = lod_ratios[lod_level]
		var error_tolerance: float = lod_errors[lod_level]
		var lod_mesh := _create_lod_mesh(mesh_instances, ratio, error_tolerance)

		if lod_mesh:
			var output_path := output_dir.path_join("%s_lod%d.res" % [model_hash, lod_level])
			# Use FLAG_BUNDLE_RESOURCES to embed textures directly in the .res file
			# Without this flag, textures are saved as external references which may not load
			var err := ResourceSaver.save(lod_mesh, output_path, ResourceSaver.FLAG_BUNDLE_RESOURCES)
			if err == OK:
				lods_created += 1
			else:
				push_warning("LODPrebaker: Failed to save LOD%d for %s" % [lod_level, model_path])

	source_scene.queue_free()

	if lods_created > 0:
		model_baked.emit(model_path, true, lods_created)
		return {"success": true, "lod_count": lods_created}
	else:
		model_baked.emit(model_path, false, 0)
		return {"success": false, "error": "Failed to create any LODs"}


## Load source model from cache or convert from NIF
func _load_source_model(model_path: String) -> Node3D:
	# Try to load from prebaked models cache first
	var cache_key := model_path.to_lower().replace("/", "\\")
	var scene_path := _models_path.path_join(cache_key.replace("\\", "_") + ".res")

	if ResourceLoader.exists(scene_path):
		var packed := ResourceLoader.load(scene_path) as PackedScene
		if packed:
			return packed.instantiate() as Node3D

	# Fall back to NIF conversion (slower)
	var nif_data := _load_nif_from_bsa(model_path)
	if nif_data.is_empty():
		return null

	var NIFConverter := load("res://src/core/nif/nif_converter.gd")
	var converter: RefCounted = NIFConverter.new()
	converter.set("load_textures", true)  # Need textures for materials
	converter.set("load_animations", false)
	converter.set("load_collision", false)
	converter.set("generate_lods", false)
	converter.set("generate_occluders", false)

	return converter.call("convert_buffer", nif_data, model_path)


## Load NIF data from BSA
func _load_nif_from_bsa(model_path: String) -> PackedByteArray:
	var normalized := model_path.to_lower().replace("/", "\\")
	if not normalized.begins_with("meshes\\"):
		normalized = "meshes\\" + normalized

	# Access BSAManager autoload dynamically
	var main_loop: SceneTree = Engine.get_main_loop() as SceneTree
	if main_loop and main_loop.root:
		var bsa_manager: Node = main_loop.root.get_node_or_null("/root/BSAManager")
		if bsa_manager and bsa_manager.has_method("extract_file"):
			return bsa_manager.call("extract_file", normalized) as PackedByteArray

	return PackedByteArray()


## Create a simplified LOD mesh from source meshes
func _create_lod_mesh(mesh_instances: Array[MeshInstance3D], target_ratio: float, target_error: float = 0.02) -> ArrayMesh:
	if mesh_instances.is_empty():
		return null

	var result_mesh := ArrayMesh.new()
	var surface_idx := 0

	for mesh_inst in mesh_instances:
		var source_mesh := mesh_inst.mesh
		if not source_mesh:
			continue

		# Get the material source: material_override takes priority, then surface materials
		# NIF converter stores materials on material_override, not on mesh surfaces
		var mesh_inst_material: Material = mesh_inst.material_override

		for surf_idx in range(source_mesh.get_surface_count()):
			var arrays: Array = source_mesh.surface_get_arrays(surf_idx)
			if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
				continue

			# Determine material for this surface:
			# 1. MeshInstance3D.material_override (applies to all surfaces)
			# 2. MeshInstance3D.get_surface_override_material(surf_idx)
			# 3. mesh.surface_get_material(surf_idx)
			var mat: Material = mesh_inst_material
			if not mat:
				mat = mesh_inst.get_surface_override_material(surf_idx)
			if not mat:
				mat = source_mesh.surface_get_material(surf_idx)

			# Get original triangle count for comparison
			var original_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] else PackedInt32Array()
			var original_tris := original_indices.size() / 3

			# Skip very small surfaces (< 4 triangles can't be simplified meaningfully)
			if original_tris < 4:
				# Just copy as-is
				result_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				if mat:
					var dup_mat := _duplicate_material_with_textures(mat)
					result_mesh.surface_set_material(surface_idx, dup_mat)
				surface_idx += 1
				continue

			# Simplify the mesh
			var simplified: Array = _optimizer.simplify_arrays(arrays, target_ratio, target_error)

			# Check if we got valid simplified data
			var simplified_indices: PackedInt32Array = simplified[Mesh.ARRAY_INDEX] if simplified.size() > Mesh.ARRAY_INDEX and simplified[Mesh.ARRAY_INDEX] else PackedInt32Array()
			var simplified_tris := simplified_indices.size() / 3

			# If simplification returned empty or degenerate, use original
			if simplified_tris < 1:
				simplified = arrays
				simplified_tris = original_tris

			# Add surface to result mesh
			result_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, simplified)

			# Copy and duplicate material to ensure it's saved with the resource
			if mat:
				# Deep duplicate material with textures to make it fully standalone
				var dup_mat := _duplicate_material_with_textures(mat)
				result_mesh.surface_set_material(surface_idx, dup_mat)

			surface_idx += 1

	if result_mesh.get_surface_count() == 0:
		return null

	return result_mesh


## Duplicate a material and ensure all textures are embedded (not external references)
## This is critical for LOD resources to be self-contained and loadable without original assets
func _duplicate_material_with_textures(mat: Material) -> Material:
	if mat is StandardMaterial3D:
		var std_mat := mat as StandardMaterial3D
		var dup := std_mat.duplicate() as StandardMaterial3D

		# Duplicate all texture properties to make them local resources
		# This ensures they get saved with FLAG_BUNDLE_RESOURCES
		if std_mat.albedo_texture:
			dup.albedo_texture = std_mat.albedo_texture.duplicate() if std_mat.albedo_texture else null
		if std_mat.normal_texture:
			dup.normal_texture = std_mat.normal_texture.duplicate() if std_mat.normal_texture else null
		if std_mat.roughness_texture:
			dup.roughness_texture = std_mat.roughness_texture.duplicate() if std_mat.roughness_texture else null
		if std_mat.metallic_texture:
			dup.metallic_texture = std_mat.metallic_texture.duplicate() if std_mat.metallic_texture else null
		if std_mat.ao_texture:
			dup.ao_texture = std_mat.ao_texture.duplicate() if std_mat.ao_texture else null
		if std_mat.emission_texture:
			dup.emission_texture = std_mat.emission_texture.duplicate() if std_mat.emission_texture else null

		return dup
	elif mat is ShaderMaterial:
		# For shader materials, duplicate but we can't easily duplicate shader params
		return mat.duplicate()
	else:
		return mat.duplicate()


## Check if all LODs are already cached for a model
func _lods_cached(model_path: String) -> bool:
	var model_hash := _get_model_hash(model_path)
	for lod_level in [1, 2, 3]:
		var path := output_dir.path_join("%s_lod%d.res" % [model_hash, lod_level])
		if not FileAccess.file_exists(path):
			return false
	return true


## Get hash for model path (used as filename)
func _get_model_hash(model_path: String) -> String:
	# Use a simple hash to create a unique but readable filename
	var normalized := model_path.to_lower().replace("\\", "/").replace("meshes/", "")
	return normalized.get_file().get_basename() + "_" + str(normalized.hash() & 0xFFFFFF).pad_zeros(6)


## Recursively find all MeshInstance3D nodes
func _find_mesh_instances(node: Node, out_instances: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out_instances.append(node as MeshInstance3D)

	for child in node.get_children():
		_find_mesh_instances(child, out_instances)


#region Static Helpers

## Cached LODs path to avoid repeated autoload lookups
static var _cached_lods_path: String = ""

## Get the LOD mesh path for a model at a specific LOD level
## Use this from ObjectDistanceManager to load prebaked LODs
static func get_lod_path(model_path: String, lod_level: int) -> String:
	# Use cached path if available (avoids repeated autoload lookups)
	if _cached_lods_path.is_empty():
		# Access SettingsManager autoload via SceneTree (NOT Engine.get_singleton - that's for Engine singletons only)
		var main_loop: MainLoop = Engine.get_main_loop()
		if main_loop is SceneTree:
			var scene_tree: SceneTree = main_loop as SceneTree
			if scene_tree.root:
				var settings_manager: Node = scene_tree.root.get_node_or_null("/root/SettingsManager")
				if settings_manager and settings_manager.has_method("get_lods_path"):
					_cached_lods_path = str(settings_manager.call("get_lods_path"))

		# Fallback path if SettingsManager not available
		if _cached_lods_path.is_empty():
			var documents := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
			_cached_lods_path = documents.path_join("Godotwind").path_join("cache").path_join("lods")

	var normalized := model_path.to_lower().replace("\\", "/").replace("meshes/", "")
	var model_hash := normalized.get_file().get_basename() + "_" + str(normalized.hash() & 0xFFFFFF).pad_zeros(6)
	return _cached_lods_path.path_join("%s_lod%d.res" % [model_hash, lod_level])


## Check if prebaked LODs exist for a model
static func has_prebaked_lods(model_path: String) -> bool:
	for lod_level in [1, 2, 3]:
		var path := get_lod_path(model_path, lod_level)
		if not FileAccess.file_exists(path):
			return false
	return true


## Load a prebaked LOD mesh
static func load_lod_mesh(model_path: String, lod_level: int) -> ArrayMesh:
	var path := get_lod_path(model_path, lod_level)
	if ResourceLoader.exists(path):
		return ResourceLoader.load(path) as ArrayMesh
	return null

#endregion
