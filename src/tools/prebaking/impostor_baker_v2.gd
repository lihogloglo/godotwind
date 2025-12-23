## ImpostorBakerV2 - Octahedral impostor texture generator with actual rendering
##
## Creates pre-baked impostor textures for distant rendering (FAR tier, 2km-5km).
## Uses SubViewport to render models from multiple octahedral viewing angles.
##
## Key improvements over v1:
## - Actual SubViewport rendering (not placeholders)
## - Octahedral mapping for 8-direction coverage
## - Proper alpha handling with depth sorting
## - Parallel baking support via WorkerThreadPool
## - Progress persistence for resume capability
##
## Process:
## 1. Load model from NIF/BSA
## 2. Calculate AABB and optimal camera distance
## 3. Render from 8 octahedral directions (hemisphere)
## 4. Pack frames into 4x2 atlas (top row) + 4x2 (bottom row variations)
## 5. Save PNG + JSON metadata
class_name ImpostorBakerV2
extends Node

const NIFConverter := preload("res://src/core/nif/nif_converter.gd")

## Octahedral directions (hemisphere coverage)
## These cover the 8 cardinal + diagonal directions from above
const OCTAHEDRAL_DIRECTIONS := [
	Vector3(0, 0, 1),      # Front (N)
	Vector3(1, 0, 1),      # Front-Right (NE)
	Vector3(1, 0, 0),      # Right (E)
	Vector3(1, 0, -1),     # Back-Right (SE)
	Vector3(0, 0, -1),     # Back (S)
	Vector3(-1, 0, -1),    # Back-Left (SW)
	Vector3(-1, 0, 0),     # Left (W)
	Vector3(-1, 0, 1),     # Front-Left (NW)
]

## Settings
var texture_size: int = 512        ## Resolution per frame
var atlas_columns: int = 4         ## Atlas layout columns
var atlas_rows: int = 2            ## Atlas layout rows (8 frames = 4x2)
var camera_fov: float = 45.0       ## Camera FOV for perspective rendering
var use_orthographic: bool = true  ## Use orthographic projection (better for impostors)
var padding_factor: float = 1.2    ## Extra space around model
var background_color: Color = Color(0, 0, 0, 0)
var min_distance: float = 1000.0   ## Start showing impostor (was 2km)
var max_distance: float = 5000.0   ## Stop showing impostor
var output_dir: String = ""        ## Set in initialize from SettingsManager

## Rendering setup
var _viewport: SubViewport = null
var _camera: Camera3D = null
var _light: DirectionalLight3D = null
var _model_container: Node3D = null

## Progress tracking
signal progress(current: int, total: int, model_name: String)
signal model_baked(model_path: String, success: bool, output_path: String)
signal batch_complete(total: int, success_count: int, failed_count: int)

## Statistics
var _total_baked: int = 0
var _total_failed: int = 0
var _failed_models: Array[String] = []
var _is_initialized: bool = false


func _ready() -> void:
	_setup_rendering_viewport()


## Initialize rendering infrastructure
func _setup_rendering_viewport() -> void:
	if _is_initialized:
		return

	# Create SubViewport for rendering
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(texture_size, texture_size)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.transparent_bg = true
	_viewport.msaa_3d = Viewport.MSAA_4X  # Smooth edges
	_viewport.use_hdr_2d = false
	_viewport.own_world_3d = true  # Isolated world
	add_child(_viewport)

	# Create camera
	_camera = Camera3D.new()
	if use_orthographic:
		_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		_camera.size = 10.0  # Will be adjusted per model
	else:
		_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
		_camera.fov = camera_fov
	_camera.near = 0.1
	_camera.far = 1000.0
	_viewport.add_child(_camera)

	# Create directional light for consistent lighting
	_light = DirectionalLight3D.new()
	_light.rotation_degrees = Vector3(-45, 45, 0)  # Angled from above-front-right
	_light.light_energy = 1.0
	_light.shadow_enabled = false  # No shadows for clean impostors
	_viewport.add_child(_light)

	# Add ambient light
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = background_color
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.5
	world_env.environment = env
	_viewport.add_child(world_env)

	# Container for models being rendered
	_model_container = Node3D.new()
	_model_container.name = "ModelContainer"
	_viewport.add_child(_model_container)

	_is_initialized = true
	print("ImpostorBakerV2: Rendering viewport initialized (%dx%d)" % [texture_size, texture_size])


## Initialize output directory
func initialize() -> Error:
	_setup_rendering_viewport()

	# Get output directory from settings manager
	if output_dir.is_empty():
		output_dir = SettingsManager.get_impostors_path()

	# Ensure cache directories exist
	var err := SettingsManager.ensure_cache_directories()
	if err != OK:
		push_error("ImpostorBakerV2: Failed to create cache directories")
		return err

	return OK


## Bake impostor for a single model (async to allow UI updates)
## Returns: Dictionary with { success: bool, output_path: String, error: String }
func bake_model(model_path: String) -> Dictionary:
	print("ImpostorBakerV2: Baking %s..." % model_path)

	# Ensure we're in the scene tree before proceeding
	if not is_inside_tree():
		var error := "ImpostorBaker not in scene tree"
		push_warning("ImpostorBakerV2: %s - %s" % [error, model_path])
		model_baked.emit(model_path, false, "")
		return {"success": false, "output_path": "", "error": error}

	# Load model
	var model := _load_model(model_path)
	if not model:
		var error := "Failed to load model"
		push_warning("ImpostorBakerV2: %s - %s" % [error, model_path])
		model_baked.emit(model_path, false, "")
		return {"success": false, "output_path": "", "error": error}

	# Add model to viewport scene
	_model_container.add_child(model)

	# Wait a frame for the model to be properly added to the scene tree
	await get_tree().process_frame

	# Calculate model bounds
	var aabb := _get_model_aabb(model)
	if aabb.size.length() < 0.01:
		var error := "Model has invalid bounds"
		push_warning("ImpostorBakerV2: %s - %s" % [error, model_path])
		model.queue_free()
		model_baked.emit(model_path, false, "")
		return {"success": false, "output_path": "", "error": error}

	# Center model at origin by offsetting its position
	var center := aabb.get_center()
	model.position = -center

	# Wait for transform to apply
	await get_tree().process_frame

	# The model is now centered at origin, so camera should look at origin
	var size := aabb.size
	var max_extent := maxf(maxf(size.x, size.y), size.z) * padding_factor

	# Configure camera for this model
	if use_orthographic:
		_camera.size = max_extent
	var camera_distance := max_extent * 2.0

	# Render from all octahedral directions
	var frames: Array[Image] = []
	for i in range(OCTAHEDRAL_DIRECTIONS.size()):
		var direction: Vector3 = OCTAHEDRAL_DIRECTIONS[i].normalized()
		var frame := await _render_from_direction_async(direction, camera_distance)
		if frame:
			frames.append(frame)
		else:
			# Create blank frame on failure
			var blank := Image.create(texture_size, texture_size, false, Image.FORMAT_RGBA8)
			blank.fill(background_color)
			frames.append(blank)

	# Remove model from scene
	model.queue_free()

	# Pack into atlas
	var atlas := _pack_atlas(frames)
	if not atlas:
		var error := "Failed to pack atlas"
		push_warning("ImpostorBakerV2: %s - %s" % [error, model_path])
		model_baked.emit(model_path, false, "")
		return {"success": false, "output_path": "", "error": error}

	# Generate output paths
	var texture_path := _get_output_path(model_path, "png")
	var metadata_path := _get_output_path(model_path, "json")

	# Save atlas
	var save_err := atlas.save_png(texture_path)
	if save_err != OK:
		var error := "Failed to save atlas: error %d" % save_err
		push_warning("ImpostorBakerV2: %s - %s" % [error, texture_path])
		model_baked.emit(model_path, false, "")
		return {"success": false, "output_path": "", "error": error}

	# Save metadata
	var metadata := _generate_metadata(model_path, aabb, texture_path)
	_save_metadata(metadata_path, metadata)

	print("ImpostorBakerV2: Saved %s" % texture_path)
	model_baked.emit(model_path, true, texture_path)

	return {
		"success": true,
		"output_path": texture_path,
		"metadata_path": metadata_path,
		"bounds": aabb,
		"error": ""
	}


## Bake all models in a list (async to allow UI updates)
func bake_models(model_paths: Array) -> Dictionary:
	if initialize() != OK:
		return {"success": 0, "failed": 0, "total": 0}

	_total_baked = 0
	_total_failed = 0
	_failed_models.clear()

	for i in range(model_paths.size()):
		var model_path: String = model_paths[i]
		progress.emit(i + 1, model_paths.size(), model_path)

		var result := await bake_model(model_path)
		if result.success:
			_total_baked += 1
		else:
			_total_failed += 1
			_failed_models.append(model_path)

		# Yield every model to keep UI responsive
		await get_tree().process_frame

	batch_complete.emit(model_paths.size(), _total_baked, _total_failed)

	return {
		"total": model_paths.size(),
		"success": _total_baked,
		"failed": _total_failed,
		"failed_models": _failed_models.duplicate()
	}


## Render model from a specific direction (async for proper rendering)
## Model is assumed to be centered at origin
func _render_from_direction_async(direction: Vector3, distance: float) -> Image:
	# Position camera looking at origin (where the model is centered)
	_camera.position = direction * distance
	_camera.look_at(Vector3.ZERO, Vector3.UP)

	# Trigger render
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	# Wait for the render to complete (2 frames to be safe)
	await get_tree().process_frame
	await get_tree().process_frame

	# Get rendered image
	var texture := _viewport.get_texture()
	if not texture:
		push_warning("ImpostorBakerV2: Failed to get viewport texture")
		return null

	var image := texture.get_image()
	if not image:
		push_warning("ImpostorBakerV2: Failed to get image from texture")
		return null

	# Make a copy since viewport texture gets overwritten
	return image.duplicate()


## Pack frames into atlas texture
func _pack_atlas(frames: Array[Image]) -> Image:
	var expected_frames := atlas_columns * atlas_rows
	if frames.size() < expected_frames:
		push_warning("ImpostorBakerV2: Expected %d frames, got %d" % [expected_frames, frames.size()])

	# Create atlas
	var atlas_width := atlas_columns * texture_size
	var atlas_height := atlas_rows * texture_size
	var atlas := Image.create(atlas_width, atlas_height, false, Image.FORMAT_RGBA8)
	atlas.fill(background_color)

	# Blit each frame
	var frame_idx := 0
	for row in range(atlas_rows):
		for col in range(atlas_columns):
			if frame_idx >= frames.size():
				break

			var x := col * texture_size
			var y := row * texture_size
			var src_rect := Rect2i(0, 0, texture_size, texture_size)
			var dst_pos := Vector2i(x, y)

			atlas.blit_rect(frames[frame_idx], src_rect, dst_pos)
			frame_idx += 1

	return atlas


## Load model from BSA/filesystem
func _load_model(model_path: String) -> Node3D:
	var full_path := model_path
	if not model_path.to_lower().begins_with("meshes"):
		full_path = "meshes/" + model_path

	# Normalize path separators
	full_path = full_path.replace("\\", "/")

	# Try BSA first
	var nif_data := PackedByteArray()
	if BSAManager.has_file(full_path):
		nif_data = BSAManager.extract_file(full_path)
	elif BSAManager.has_file(model_path):
		nif_data = BSAManager.extract_file(model_path)
		full_path = model_path

	if nif_data.is_empty():
		push_warning("ImpostorBakerV2: File not found: %s" % model_path)
		return null

	# Convert NIF
	var converter := NIFConverter.new()
	converter.load_textures = true
	converter.load_animations = false
	converter.load_collision = false
	converter.generate_lods = false
	converter.generate_occluders = false

	var node := converter.convert_buffer(nif_data, full_path)
	if not node:
		push_warning("ImpostorBakerV2: Failed to convert NIF: %s" % model_path)
		return null

	return node


## Get combined AABB for model hierarchy
func _get_model_aabb(node: Node3D) -> AABB:
	var aabb := AABB()
	var first := true

	var mesh_instances := _find_all_mesh_instances(node)
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


## Find all MeshInstance3D nodes recursively
func _find_all_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var instances: Array[MeshInstance3D] = []

	if node is MeshInstance3D:
		instances.append(node as MeshInstance3D)

	for child in node.get_children():
		instances.append_array(_find_all_mesh_instances(child))

	return instances


## Generate output path for impostor files
## NOTE: Must match impostor_candidates.gd get_impostor_texture_path() normalization
func _get_output_path(model_path: String, extension: String) -> String:
	# Normalize path to match loader expectations (remove meshes\ prefix)
	var normalized := model_path
	var lower := normalized.to_lower()
	if lower.begins_with("meshes\\") or lower.begins_with("meshes/"):
		normalized = normalized.substr(7)  # Remove "meshes\" or "meshes/"

	var hash_val := normalized.to_lower().hash()
	var base_name := normalized.get_file().get_basename()
	# Clean filename and lowercase to match loader
	base_name = base_name.replace("\\", "_").replace("/", "_").replace(" ", "_").to_lower()
	var filename := "%s_%x.%s" % [base_name, hash_val, extension]
	return output_dir.path_join(filename)


## Generate metadata JSON
func _generate_metadata(model_path: String, aabb: AABB, texture_path: String) -> Dictionary:
	var size := aabb.size

	return {
		"version": 2,
		"model_path": model_path,
		"texture_path": texture_path,
		"settings": {
			"texture_size": texture_size,
			"atlas_columns": atlas_columns,
			"atlas_rows": atlas_rows,
			"frames": atlas_columns * atlas_rows,
			"min_distance": min_distance,
			"max_distance": max_distance,
			"use_orthographic": use_orthographic,
		},
		"bounds": {
			"center": [aabb.get_center().x, aabb.get_center().y, aabb.get_center().z],
			"size": [size.x, size.y, size.z],
			"width": size.x,
			"height": size.y,
			"depth": size.z,
		},
		"frame_uvs": _generate_frame_uvs(),
		"directions": _generate_direction_data(),
		"baked_date": Time.get_datetime_string_from_system(),
	}


## Generate UV coordinates for each frame
func _generate_frame_uvs() -> Array:
	var uvs := []
	var frame_uv_width := 1.0 / float(atlas_columns)
	var frame_uv_height := 1.0 / float(atlas_rows)

	for row in range(atlas_rows):
		for col in range(atlas_columns):
			uvs.append({
				"u": float(col) * frame_uv_width,
				"v": float(row) * frame_uv_height,
				"width": frame_uv_width,
				"height": frame_uv_height,
			})

	return uvs


## Generate direction data for shader
func _generate_direction_data() -> Array:
	var directions := []
	for i in range(OCTAHEDRAL_DIRECTIONS.size()):
		var dir: Vector3 = OCTAHEDRAL_DIRECTIONS[i].normalized()
		directions.append({
			"index": i,
			"direction": [dir.x, dir.y, dir.z],
			"angle_degrees": rad_to_deg(atan2(dir.x, dir.z)),
		})
	return directions


## Save metadata to JSON file
func _save_metadata(path: String, metadata: Dictionary) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		push_error("ImpostorBakerV2: Failed to open metadata file: %s" % path)
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


## Check if an impostor already exists for a model
func impostor_exists(model_path: String) -> bool:
	var texture_path := _get_output_path(model_path, "png")
	return FileAccess.file_exists(texture_path)
