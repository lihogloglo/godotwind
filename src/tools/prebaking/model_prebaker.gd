## ModelPrebaker - Converts all unique NIF models to Godot resources ahead of time
##
## This eliminates runtime NIF conversion entirely by pre-converting all models
## referenced in the ESM file. The disk cache in ModelLoader then loads these
## instantly on subsequent runs.
##
## Process:
## 1. Scan all ESM records to collect unique model paths
## 2. For each model: extract from BSA, convert NIF, save as .mesh + .res
## 3. Results saved to Documents/Godotwind/cache/models/
##
## Performance:
## - First run (prebaking): ~5-30 minutes depending on model count
## - Subsequent game loads: Near-instant model loading (0.1-0.2ms per model)
class_name ModelPrebaker
extends RefCounted

const NIFConverter := preload("res://src/core/nif/nif_converter.gd")

## Output directory (set from SettingsManager)
var output_dir: String = ""

## Skip models that already exist in cache
var skip_existing: bool = true

## Progress tracking
signal progress(current: int, total: int, model_name: String)
signal model_baked(model_path: String, success: bool, mesh_count: int)
signal batch_complete(total: int, success: int, failed: int, skipped: int)

## Statistics
var _total_baked: int = 0
var _total_failed: int = 0
var _total_skipped: int = 0
var _failed_models: Array[String] = []


## Initialize the baker
func initialize() -> Error:
	if output_dir.is_empty():
		output_dir = SettingsManager.get_models_path()

	var err := SettingsManager.ensure_cache_directories()
	if err != OK:
		push_error("ModelPrebaker: Failed to create cache directories")
		return err

	print("ModelPrebaker: Initialized - output dir: %s" % output_dir)
	return OK


## Bake all unique models from ESM
func bake_all_models() -> Dictionary:
	if initialize() != OK:
		return {"success": 0, "failed": 0, "skipped": 0}

	_total_baked = 0
	_total_failed = 0
	_total_skipped = 0
	_failed_models.clear()

	# Collect all unique model paths from ESM
	var model_paths := _collect_unique_models()
	print("ModelPrebaker: Found %d unique models to bake" % model_paths.size())

	# Bake each model
	for i in range(model_paths.size()):
		var model_path: String = model_paths[i]
		progress.emit(i + 1, model_paths.size(), model_path.get_file())

		# Check if already cached
		if skip_existing and _model_cached(model_path):
			_total_skipped += 1
			continue

		var result := bake_model(model_path)
		if result.success:
			_total_baked += 1
		else:
			_total_failed += 1
			_failed_models.append(model_path)

		# Yield every 10 models to prevent UI freeze
		if i % 10 == 0:
			await Engine.get_main_loop().process_frame

	batch_complete.emit(model_paths.size(), _total_baked, _total_failed, _total_skipped)

	print("ModelPrebaker: Complete - %d baked, %d skipped, %d failed" % [
		_total_baked, _total_skipped, _total_failed])

	return {
		"total": model_paths.size(),
		"success": _total_baked,
		"failed": _total_failed,
		"skipped": _total_skipped,
		"failed_models": _failed_models.duplicate()
	}


## Bake a single model
func bake_model(model_path: String) -> Dictionary:
	# Load NIF from BSA
	var nif_data := _load_nif(model_path)
	if nif_data.is_empty():
		model_baked.emit(model_path, false, 0)
		return {"success": false, "error": "NIF not found in BSA"}

	# Convert NIF to Godot scene
	var converter := NIFConverter.new()
	converter.load_textures = true
	converter.load_animations = false
	converter.load_collision = true
	converter.generate_lods = false
	converter.generate_occluders = false

	var model := converter.convert_buffer(nif_data, model_path)
	if not model:
		model_baked.emit(model_path, false, 0)
		return {"success": false, "error": "NIF conversion failed"}

	# Save meshes and scene
	var cache_key := model_path.to_lower().replace("/", "\\")
	var mesh_count := _save_model_to_cache(model, cache_key)

	model.queue_free()

	if mesh_count > 0:
		model_baked.emit(model_path, true, mesh_count)
		return {"success": true, "mesh_count": mesh_count}
	else:
		model_baked.emit(model_path, false, 0)
		return {"success": false, "error": "No meshes to save"}


## Collect all unique model paths from ESM records
func _collect_unique_models() -> Array[String]:
	var models: Array[String] = []
	var seen: Dictionary = {}

	# Scan all record types that have models
	var record_sources := [
		ESMManager.statics,
		ESMManager.activators,
		ESMManager.containers,
		ESMManager.doors,
		ESMManager.lights,
		ESMManager.misc_items,
		ESMManager.weapons,
		ESMManager.armors,
		ESMManager.clothing,
		ESMManager.books,
		ESMManager.ingredients,
		ESMManager.apparatus,
		ESMManager.lockpicks,
		ESMManager.probes,
		ESMManager.repair_items,
		ESMManager.alchemy,
	]

	for source in record_sources:
		if source == null:
			continue
		for key in source:
			var record = source[key]
			var model_path := _get_model_path_from_record(record)
			if not model_path.is_empty():
				var normalized := model_path.to_lower()
				if normalized not in seen:
					seen[normalized] = true
					models.append(model_path)

	# Also scan NPCs and creatures for body part models
	for key in ESMManager.npcs:
		var npc = ESMManager.npcs[key]
		# NPCs use body parts, not direct models - skip for now

	for key in ESMManager.creatures:
		var creature = ESMManager.creatures[key]
		var model_path := _get_model_path_from_record(creature)
		if not model_path.is_empty():
			var normalized := model_path.to_lower()
			if normalized not in seen:
				seen[normalized] = true
				models.append(model_path)

	# Sort for consistent ordering
	models.sort()
	return models


## Extract model path from a record
func _get_model_path_from_record(record) -> String:
	if record == null:
		return ""
	if "model" in record and record.model is String:
		return record.model
	if "mesh" in record and record.mesh is String:
		return record.mesh
	return ""


## Load NIF from BSA
func _load_nif(model_path: String) -> PackedByteArray:
	var full_path := model_path
	if not model_path.to_lower().begins_with("meshes"):
		full_path = "meshes/" + model_path

	full_path = full_path.replace("\\", "/")

	if BSAManager.has_file(full_path):
		return BSAManager.extract_file(full_path)
	elif BSAManager.has_file(model_path):
		return BSAManager.extract_file(model_path)

	return PackedByteArray()


## Check if a model is already cached
func _model_cached(model_path: String) -> bool:
	var cache_key := model_path.to_lower().replace("/", "\\")
	var safe_name := cache_key.replace("\\", "_").replace("/", "_").replace(":", "_").replace(".", "_")
	var scene_path := output_dir.path_join(safe_name + ".res")
	return FileAccess.file_exists(scene_path)


## Save model meshes to cache (reuses ModelLoader logic)
func _save_model_to_cache(node: Node3D, cache_key: String) -> int:
	var safe_name := cache_key.replace("\\", "_").replace("/", "_").replace(":", "_").replace(".", "_")
	var base_path := output_dir.path_join(safe_name)

	# Save all meshes
	var mesh_count := _save_meshes(node, base_path, 0)

	if mesh_count == 0:
		return 0

	# Save scene structure
	var scene_path := base_path + ".res"
	var packed_scene := PackedScene.new()
	var pack_result := packed_scene.pack(node)
	if pack_result != OK:
		return 0

	var save_result := ResourceSaver.save(packed_scene, scene_path)
	if save_result != OK:
		return 0

	return mesh_count


## Save all meshes in node tree
func _save_meshes(node: Node, base_path: String, start_idx: int) -> int:
	var count := start_idx

	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		if mesh_inst.mesh:
			var mesh_path := "%s_mesh_%d.mesh" % [base_path, count]
			var save_result := ResourceSaver.save(mesh_inst.mesh, mesh_path)
			if save_result == OK:
				mesh_inst.mesh.take_over_path(mesh_path)
				count += 1

	for child in node.get_children():
		count = _save_meshes(child, base_path, count)

	return count


## Get statistics
func get_stats() -> Dictionary:
	return {
		"total_baked": _total_baked,
		"total_failed": _total_failed,
		"total_skipped": _total_skipped,
		"failed_models": _failed_models.duplicate(),
	}
