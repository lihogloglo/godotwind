## ImpostorBaker - Tool for generating octahedral impostor textures
##
## Creates pre-baked impostor textures for distant rendering (FAR tier, 2km-5km)
##
## Process:
## 1. Load landmark models from NIF files
## 2. Render from 16 octahedral viewing angles (hemisphere coverage)
## 3. Pack frames into texture atlas
## 4. Save to {cache}/impostors/[model_hash].png + .json metadata
## Default cache: Documents/Godotwind/cache/
##
## Usage:
##   var baker := ImpostorBaker.new()
##   baker.bake_all_candidates()  # Bake all landmarks
##   # OR
##   baker.bake_model("meshes\\x\\ex_vivec_canton_00.nif")  # Bake single model
class_name ImpostorBaker
extends RefCounted

const NIFConverter := preload("res://src/core/nif/nif_converter.gd")

## Impostor generation settings
class ImpostorSettings:
	var texture_size: int = 512         # Resolution per frame (512×512)
	var frames: int = 16                # Viewing angles (octahedral hemisphere)
	var use_alpha: bool = true          # Alpha channel for transparency
	var atlas_columns: int = 4          # Atlas layout (4×4 grid)
	var atlas_rows: int = 4
	var optimize_size: bool = true      # Trim empty space
	var min_distance: float = 2000.0    # Minimum display distance
	var max_distance: float = 5000.0    # Maximum display distance
	var background_color: Color = Color.TRANSPARENT  # Background for renders

## Default settings
var settings := ImpostorSettings.new()

## Output directory for impostor assets (set in initialize from SettingsManager)
var output_dir: String = ""

## Progress tracking
signal progress(current: int, total: int, model_name: String)
signal impostor_baked(model_path: String, success: bool, output_path: String)
signal batch_complete(total: int, success_count: int, failed_count: int)

## Statistics
var _total_baked: int = 0
var _total_failed: int = 0
var _failed_models: Array[String] = []


## Initialize the baker (call before baking)
func initialize() -> Error:
	# Get output directory from settings manager
	if output_dir.is_empty():
		output_dir = SettingsManager.get_impostors_path()

	# Ensure cache directories exist
	var err := SettingsManager.ensure_cache_directories()
	if err != OK:
		push_error("ImpostorBaker: Failed to create cache directories")
		return err

	print("ImpostorBaker: Initialized - output dir: %s" % output_dir)
	return OK


## Bake all impostor candidates from world provider
func bake_all_candidates(world_provider = null) -> Dictionary:
	if initialize() != OK:
		return {"success": 0, "failed": 0}

	_total_baked = 0
	_total_failed = 0
	_failed_models.clear()

	# Get candidates from world provider
	var candidates: Array[String] = []
	if world_provider and world_provider.has_method("get_impostor_candidates"):
		candidates = world_provider.get_impostor_candidates()
	else:
		push_warning("ImpostorBaker: No world provider or no impostor candidates")
		return {"success": 0, "failed": 0}

	print("ImpostorBaker: Baking %d impostor candidates..." % candidates.size())

	# Bake each candidate
	for i in range(candidates.size()):
		var model_path := candidates[i]
		progress.emit(i + 1, candidates.size(), model_path)

		var result := bake_model(model_path)
		if result.success:
			_total_baked += 1
		else:
			_total_failed += 1
			_failed_models.append(model_path)

	# Complete
	batch_complete.emit(candidates.size(), _total_baked, _total_failed)

	print("ImpostorBaker: Batch complete - %d succeeded, %d failed" % [_total_baked, _total_failed])
	if not _failed_models.is_empty():
		print("  Failed models: %s" % ", ".join(_failed_models))

	return {
		"total": candidates.size(),
		"success": _total_baked,
		"failed": _total_failed,
		"failed_models": _failed_models.duplicate()
	}


## Bake impostor for a single model
## Returns: Dictionary with { success: bool, output_path: String, error: String }
func bake_model(model_path: String) -> Dictionary:
	print("ImpostorBaker: Baking %s..." % model_path)

	# Load model from BSA
	var model_node := _load_model(model_path)
	if not model_node:
		var error := "Failed to load model"
		push_warning("ImpostorBaker: %s - %s" % [error, model_path])
		impostor_baked.emit(model_path, false, "")
		return {"success": false, "output_path": "", "error": error}

	# Render from octahedral angles
	var frames: Array[Image] = _render_octahedral_frames(model_node)
	if frames.is_empty():
		var error := "Failed to render frames"
		push_warning("ImpostorBaker: %s - %s" % [error, model_path])
		model_node.queue_free()
		impostor_baked.emit(model_path, false, "")
		return {"success": false, "output_path": "", "error": error}

	# Pack into atlas
	var atlas: Image = _pack_atlas(frames)
	if not atlas:
		var error := "Failed to pack atlas"
		push_warning("ImpostorBaker: %s - %s" % [error, model_path])
		model_node.queue_free()
		impostor_baked.emit(model_path, false, "")
		return {"success": false, "output_path": "", "error": error}

	# Generate output path
	var output_path := _get_output_path(model_path, "png")
	var metadata_path := _get_output_path(model_path, "json")

	# Save atlas texture
	var save_err := atlas.save_png(output_path)
	if save_err != OK:
		var error := "Failed to save atlas: error %d" % save_err
		push_warning("ImpostorBaker: %s - %s" % [error, output_path])
		model_node.queue_free()
		impostor_baked.emit(model_path, false, "")
		return {"success": false, "output_path": "", "error": error}

	# Save metadata
	var metadata := _generate_metadata(model_path, model_node, output_path)
	_save_metadata(metadata_path, metadata)

	# Cleanup
	model_node.queue_free()

	print("ImpostorBaker: Saved %s" % output_path)
	impostor_baked.emit(model_path, true, output_path)

	return {
		"success": true,
		"output_path": output_path,
		"metadata_path": metadata_path,
		"error": ""
	}


## Load a model from BSA
func _load_model(model_path: String) -> Node3D:
	# Build full path
	var full_path := model_path
	if not model_path.to_lower().begins_with("meshes"):
		full_path = "meshes\\" + model_path

	# Extract from BSA
	var nif_data := PackedByteArray()
	if BSAManager.has_file(full_path):
		nif_data = BSAManager.extract_file(full_path)
	elif BSAManager.has_file(model_path):
		nif_data = BSAManager.extract_file(model_path)
		full_path = model_path

	if nif_data.is_empty():
		push_warning("ImpostorBaker: File not found in BSA: %s" % model_path)
		return null

	# Convert NIF to Node3D
	var converter := NIFConverter.new()
	converter.load_textures = true
	converter.load_animations = false
	converter.load_collision = false
	converter.generate_lods = false  # Don't need LODs for impostor baking
	converter.generate_occluders = false

	var node := converter.convert_buffer(nif_data, full_path)
	if not node:
		push_warning("ImpostorBaker: Failed to convert NIF: %s" % model_path)
		return null

	return node


## Render model from 16 octahedral viewing angles
## NOTE: Actual rendering requires SubViewport - returns placeholders for now
func _render_octahedral_frames(model: Node3D) -> Array[Image]:
	var frames: Array[Image] = []

	# Calculate model bounds for camera positioning
	var aabb := _get_model_aabb(model)
	if aabb.size.length() < 0.01:
		push_warning("ImpostorBaker: Model has invalid bounds")
		return frames

	# 16 octahedral angles (4×4 hemisphere coverage)
	for i in range(settings.frames):
		# TODO: Implement actual SubViewport rendering
		# For now, create placeholder images
		var img := Image.create(settings.texture_size, settings.texture_size, false, Image.FORMAT_RGBA8)
		img.fill(settings.background_color)
		frames.append(img)

	return frames


## Get AABB for entire model hierarchy
func _get_model_aabb(node: Node3D) -> AABB:
	var aabb := AABB()
	var first := true

	# Recursively find all MeshInstance3D nodes
	var mesh_instances := _find_mesh_instances(node)
	for mesh_inst in mesh_instances:
		var mesh_aabb := mesh_inst.get_aabb()
		var global_transform := mesh_inst.global_transform
		var transformed_aabb := global_transform * mesh_aabb

		if first:
			aabb = transformed_aabb
			first = false
		else:
			aabb = aabb.merge(transformed_aabb)

	return aabb


## Find all MeshInstance3D nodes in hierarchy
func _find_mesh_instances(node: Node) -> Array:
	var instances := []

	if node is MeshInstance3D:
		instances.append(node)

	for child in node.get_children():
		instances.append_array(_find_mesh_instances(child))

	return instances


## Pack rendered frames into atlas texture
func _pack_atlas(frames: Array[Image]) -> Image:
	if frames.size() != settings.frames:
		push_warning("ImpostorBaker: Expected %d frames, got %d" % [settings.frames, frames.size()])
		return null

	# Calculate atlas size
	var atlas_width := settings.atlas_columns * settings.texture_size
	var atlas_height := settings.atlas_rows * settings.texture_size

	# Create atlas
	var atlas := Image.create(atlas_width, atlas_height, false, Image.FORMAT_RGBA8)
	atlas.fill(Color.TRANSPARENT)

	# Blit each frame into atlas
	var frame_idx := 0
	for row in range(settings.atlas_rows):
		for col in range(settings.atlas_columns):
			if frame_idx >= frames.size():
				break

			var x := col * settings.texture_size
			var y := row * settings.texture_size
			var src_rect := Rect2i(0, 0, settings.texture_size, settings.texture_size)
			var dst_pos := Vector2i(x, y)

			atlas.blit_rect(frames[frame_idx], src_rect, dst_pos)
			frame_idx += 1

	return atlas


## Generate output path for impostor assets
func _get_output_path(model_path: String, extension: String) -> String:
	# Create hash from model path for unique filename
	var hash := model_path.hash()
	var filename := "%s_%x.%s" % [model_path.get_file().get_basename(), hash, extension]

	# Clean up filename (remove invalid characters)
	filename = filename.replace("\\", "_").replace("/", "_").replace(" ", "_")

	return output_dir.path_join(filename)


## Generate metadata JSON for impostor
func _generate_metadata(model_path: String, model: Node3D, texture_path: String) -> Dictionary:
	var aabb := _get_model_aabb(model)

	return {
		"model_path": model_path,
		"texture_path": texture_path,
		"settings": {
			"texture_size": settings.texture_size,
			"frames": settings.frames,
			"atlas_columns": settings.atlas_columns,
			"atlas_rows": settings.atlas_rows,
			"min_distance": settings.min_distance,
			"max_distance": settings.max_distance,
		},
		"bounds": {
			"position": [aabb.position.x, aabb.position.y, aabb.position.z],
			"size": [aabb.size.x, aabb.size.y, aabb.size.z],
		},
		"frame_uvs": _generate_frame_uvs(),
		"baked_date": Time.get_datetime_string_from_system(),
	}


## Generate UV coordinates for each frame in atlas
func _generate_frame_uvs() -> Array:
	var uvs := []
	var frame_uv_width := 1.0 / float(settings.atlas_columns)
	var frame_uv_height := 1.0 / float(settings.atlas_rows)

	for row in range(settings.atlas_rows):
		for col in range(settings.atlas_columns):
			var u := float(col) * frame_uv_width
			var v := float(row) * frame_uv_height

			uvs.append({
				"u": u,
				"v": v,
				"width": frame_uv_width,
				"height": frame_uv_height,
			})

	return uvs


## Save metadata JSON file
func _save_metadata(path: String, metadata: Dictionary) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		push_error("ImpostorBaker: Failed to open metadata file: %s" % path)
		return FileAccess.get_open_error()

	var json := JSON.stringify(metadata, "\t")
	file.store_string(json)
	file.close()

	return OK


## Get statistics
func get_stats() -> Dictionary:
	return {
		"total_baked": _total_baked,
		"total_failed": _total_failed,
		"failed_models": _failed_models.duplicate(),
	}
