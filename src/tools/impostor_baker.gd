## ImpostorBaker - Tool for generating impostor textures from 3D models
##
## Renders models from multiple angles using SubViewport to create
## octahedral impostor textures for distant rendering (FAR tier).
##
## Output files:
##   res://assets/impostors/[hash]_impostor.png - Atlas texture
##   res://assets/impostors/[hash]_impostor.json - Metadata (size, frames, bounds)
##
## Usage in editor:
##   var baker := ImpostorBaker.new()
##   add_child(baker)
##   baker.bake_model("meshes/x/ex_vivec_canton_01.nif")
##   # Or batch:
##   baker.bake_all_candidates()
##
## The baked textures are used by ImpostorManager at runtime.
@tool
class_name ImpostorBaker
extends Node


#region Signals

## Emitted when a single model bake completes
signal model_baked(model_path: String, success: bool)

## Emitted when batch baking completes
signal batch_complete(total: int, succeeded: int, failed: int)

## Emitted for progress updates during batch baking
signal progress_updated(current: int, total: int, model_path: String)

#endregion


#region Constants

## Output directory for impostor textures
const OUTPUT_DIR := "res://assets/impostors"

## Default settings
const DEFAULT_TEXTURE_SIZE := 512
const DEFAULT_FRAME_COUNT := 16
const DEFAULT_ALPHA_CUTOFF := 0.5

#endregion


#region Configuration

## Resolution of each frame in the atlas (power of 2 recommended)
@export var frame_size: int = 256

## Number of viewing angles to capture (8, 12, 16, or 24)
@export_range(8, 32, 4) var frame_count: int = 16

## Use alpha transparency
@export var use_alpha: bool = true

## Background color for rendering (transparent if use_alpha)
@export var background_color: Color = Color(0, 0, 0, 0)

## Padding around model in frame (percentage)
@export_range(0.0, 0.5) var padding: float = 0.1

## Enable mipmaps on output texture
@export var generate_mipmaps: bool = true

#endregion


#region Internal State

## SubViewport for rendering
var _viewport: SubViewport = null

## Camera for capturing views
var _camera: Camera3D = null

## Light for scene illumination
var _light: DirectionalLight3D = null

## Current model being baked
var _current_model: Node3D = null

## Model loader reference (set externally)
var model_loader: RefCounted = null

## Impostor candidates reference
var impostor_candidates: RefCounted = null

## Batch processing state
var _batch_queue: Array[String] = []
var _batch_results: Dictionary = {"succeeded": 0, "failed": 0}
var _is_baking: bool = false

#endregion


func _ready() -> void:
	_setup_viewport()


func _exit_tree() -> void:
	_cleanup()


#region Public API


## Bake a single model to impostor texture
## Returns true if baking started successfully
func bake_model(model_path: String, custom_settings: Dictionary = {}) -> bool:
	if _is_baking:
		push_warning("ImpostorBaker: Already baking, queue this request")
		return false

	# Get settings
	var settings := _get_settings_for_model(model_path, custom_settings)

	# Load the model
	var model := _load_model(model_path)
	if not model:
		push_error("ImpostorBaker: Failed to load model: %s" % model_path)
		model_baked.emit(model_path, false)
		return false

	_is_baking = true
	_current_model = model

	# Add model to viewport scene
	_viewport.add_child(model)

	# Calculate model bounds
	var aabb := _calculate_model_aabb(model)
	if aabb.size.length() < 0.01:
		push_warning("ImpostorBaker: Model has no geometry: %s" % model_path)
		_cleanup_model()
		model_baked.emit(model_path, false)
		return false

	# Position camera based on bounds
	_setup_camera_for_model(aabb)

	# Capture frames from multiple angles
	var frames := await _capture_all_frames(settings.frame_count)

	if frames.is_empty():
		push_error("ImpostorBaker: Failed to capture frames for: %s" % model_path)
		_cleanup_model()
		model_baked.emit(model_path, false)
		return false

	# Create atlas from frames
	var atlas := _create_atlas(frames, settings.texture_size)

	# Save output files
	var success := _save_impostor(model_path, atlas, aabb, settings)

	_cleanup_model()
	model_baked.emit(model_path, success)

	return success


## Bake all impostor candidates (batch mode)
## Processes models from ImpostorCandidates list
func bake_all_candidates() -> void:
	if _is_baking:
		push_warning("ImpostorBaker: Already baking")
		return

	if not impostor_candidates:
		impostor_candidates = preload("res://src/core/world/impostor_candidates.gd").new()

	# Get all landmark models
	var landmarks: Array[String] = impostor_candidates.get_landmark_models()

	print("ImpostorBaker: Starting batch bake of %d models" % landmarks.size())

	_batch_queue = landmarks.duplicate()
	_batch_results = {"succeeded": 0, "failed": 0}

	await _process_batch_queue()


## Bake specific models from a list
func bake_models(model_paths: Array[String]) -> void:
	if _is_baking:
		push_warning("ImpostorBaker: Already baking")
		return

	print("ImpostorBaker: Starting batch bake of %d models" % model_paths.size())

	_batch_queue = model_paths.duplicate()
	_batch_results = {"succeeded": 0, "failed": 0}

	await _process_batch_queue()


## Check if an impostor already exists for a model
func has_impostor(model_path: String) -> bool:
	var texture_path := _get_texture_path(model_path)
	return FileAccess.file_exists(texture_path) or ResourceLoader.exists(texture_path)


## Delete existing impostor for a model
func delete_impostor(model_path: String) -> bool:
	var texture_path := _get_texture_path(model_path)
	var metadata_path := _get_metadata_path(model_path)

	var deleted := false

	if FileAccess.file_exists(texture_path):
		DirAccess.remove_absolute(texture_path)
		deleted = true

	if FileAccess.file_exists(metadata_path):
		DirAccess.remove_absolute(metadata_path)
		deleted = true

	return deleted


## Get baking status
func is_baking() -> bool:
	return _is_baking


#endregion


#region Internal Methods


## Set up the SubViewport for rendering
func _setup_viewport() -> void:
	# Create viewport
	_viewport = SubViewport.new()
	_viewport.name = "ImpostorViewport"
	_viewport.size = Vector2i(frame_size, frame_size)
	_viewport.transparent_bg = use_alpha
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.use_hdr_2d = false
	add_child(_viewport)

	# Create camera
	_camera = Camera3D.new()
	_camera.name = "ImpostorCamera"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.current = true
	_viewport.add_child(_camera)

	# Create directional light
	_light = DirectionalLight3D.new()
	_light.name = "ImpostorLight"
	_light.rotation_degrees = Vector3(-45, 45, 0)
	_light.light_energy = 1.0
	_light.shadow_enabled = false
	_viewport.add_child(_light)

	# Create world environment for clean rendering
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = background_color
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.4, 0.4)
	env.ambient_light_energy = 1.0

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	_viewport.add_child(world_env)


## Clean up resources
func _cleanup() -> void:
	_cleanup_model()
	_is_baking = false


## Clean up current model
func _cleanup_model() -> void:
	if _current_model and is_instance_valid(_current_model):
		_current_model.queue_free()
	_current_model = null
	_is_baking = false


## Load a model for baking
func _load_model(model_path: String) -> Node3D:
	# Try using model_loader if available
	if model_loader and model_loader.has_method("get_model"):
		var model = model_loader.get_model(model_path, "")
		if model:
			# Duplicate since model_loader may return shared prototype
			return model.duplicate()

	# Try loading as resource directly
	if ResourceLoader.exists(model_path):
		var resource = load(model_path)
		if resource is PackedScene:
			return resource.instantiate()
		elif resource is Mesh:
			var mesh_instance := MeshInstance3D.new()
			mesh_instance.mesh = resource
			return mesh_instance

	# Try with Godot resource path variations
	var variations := [
		model_path,
		"res://" + model_path,
		model_path.replace("\\", "/"),
		"res://" + model_path.replace("\\", "/"),
	]

	for path in variations:
		if ResourceLoader.exists(path):
			var resource = load(path)
			if resource is PackedScene:
				return resource.instantiate()
			elif resource is Mesh:
				var mesh_instance := MeshInstance3D.new()
				mesh_instance.mesh = resource
				return mesh_instance

	return null


## Calculate AABB for a model (including children)
func _calculate_model_aabb(model: Node3D) -> AABB:
	var aabb := AABB()
	var first := true

	for child in _get_all_mesh_instances(model):
		var mesh_instance: MeshInstance3D = child
		if mesh_instance.mesh:
			var mesh_aabb := mesh_instance.mesh.get_aabb()
			var global_aabb := mesh_instance.global_transform * mesh_aabb

			if first:
				aabb = global_aabb
				first = false
			else:
				aabb = aabb.merge(global_aabb)

	return aabb


## Get all MeshInstance3D nodes in hierarchy
func _get_all_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []

	if node is MeshInstance3D:
		result.append(node)

	for child in node.get_children():
		result.append_array(_get_all_mesh_instances(child))

	return result


## Set up camera to frame the model properly
func _setup_camera_for_model(aabb: AABB) -> void:
	var center := aabb.get_center()
	var size := aabb.size.length()

	# Add padding
	var padded_size := size * (1.0 + padding * 2)

	# Set orthographic size to fit model
	_camera.size = padded_size
	_camera.near = 0.01
	_camera.far = padded_size * 4

	# Center the model
	if _current_model:
		_current_model.position = -center


## Capture frames from multiple angles
func _capture_all_frames(num_frames: int) -> Array[Image]:
	var frames: Array[Image] = []

	# Calculate angles for octahedral coverage
	# We capture from a hemisphere above the object
	var angles := _calculate_capture_angles(num_frames)

	for angle in angles:
		var frame := await _capture_frame(angle)
		if frame:
			frames.append(frame)

		# Yield to prevent blocking
		await get_tree().process_frame

	return frames


## Calculate camera angles for capturing
func _calculate_capture_angles(num_frames: int) -> Array[Vector2]:
	var angles: Array[Vector2] = []

	# Use octahedral distribution
	# For simplicity, we use evenly spaced azimuth angles at fixed elevation
	# A more sophisticated approach would use spherical fibonacci

	var elevations := [30.0, 45.0]  # Two elevation bands
	var frames_per_elevation := num_frames / elevations.size()

	for elevation in elevations:
		for i in range(frames_per_elevation):
			var azimuth := (360.0 / frames_per_elevation) * i
			angles.append(Vector2(azimuth, elevation))

	return angles


## Capture a single frame from a specific angle
func _capture_frame(angle: Vector2) -> Image:
	if not _viewport or not _camera or not _current_model:
		return null

	# Position camera at angle
	var azimuth := deg_to_rad(angle.x)
	var elevation := deg_to_rad(angle.y)

	# Calculate camera position on sphere around origin
	var distance := _camera.size * 2
	var x := distance * cos(elevation) * sin(azimuth)
	var y := distance * sin(elevation)
	var z := distance * cos(elevation) * cos(azimuth)

	_camera.position = Vector3(x, y, z)
	_camera.look_at(Vector3.ZERO, Vector3.UP)

	# Render frame
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	# Get viewport texture
	var texture := _viewport.get_texture()
	if not texture:
		return null

	return texture.get_image()


## Create atlas texture from captured frames
func _create_atlas(frames: Array[Image], target_size: int) -> Image:
	if frames.is_empty():
		return null

	# Calculate atlas layout (square grid)
	var grid_size := ceili(sqrt(float(frames.size())))
	var frame_size_in_atlas := target_size / grid_size

	# Create atlas image
	var format := Image.FORMAT_RGBA8 if use_alpha else Image.FORMAT_RGB8
	var atlas := Image.create(target_size, target_size, generate_mipmaps, format)
	atlas.fill(background_color)

	# Place frames in grid
	for i in range(frames.size()):
		var frame := frames[i]

		# Resize frame to fit atlas cell
		if frame.get_width() != frame_size_in_atlas or frame.get_height() != frame_size_in_atlas:
			frame.resize(frame_size_in_atlas, frame_size_in_atlas, Image.INTERPOLATE_LANCZOS)

		# Calculate position in atlas
		var grid_x := i % grid_size
		var grid_y := i / grid_size
		var pos := Vector2i(grid_x * frame_size_in_atlas, grid_y * frame_size_in_atlas)

		# Blit frame to atlas
		atlas.blit_rect(frame, Rect2i(Vector2i.ZERO, frame.get_size()), pos)

	# Generate mipmaps if enabled
	if generate_mipmaps:
		atlas.generate_mipmaps()

	return atlas


## Save impostor texture and metadata
func _save_impostor(model_path: String, atlas: Image, aabb: AABB, settings: Dictionary) -> bool:
	if not atlas:
		return false

	# Ensure output directory exists
	var dir := DirAccess.open("res://")
	if dir:
		dir.make_dir_recursive(OUTPUT_DIR.replace("res://", ""))

	# Get output paths
	var texture_path := _get_texture_path(model_path)
	var metadata_path := _get_metadata_path(model_path)

	# Save texture as PNG
	var err := atlas.save_png(texture_path)
	if err != OK:
		push_error("ImpostorBaker: Failed to save texture: %s (error %d)" % [texture_path, err])
		return false

	# Save metadata as JSON
	var metadata := {
		"model_path": model_path,
		"width": aabb.size.x,
		"height": aabb.size.y,
		"depth": aabb.size.z,
		"center_x": aabb.get_center().x,
		"center_y": aabb.get_center().y,
		"center_z": aabb.get_center().z,
		"texture_size": settings.texture_size,
		"frame_count": settings.frame_count,
		"use_alpha": settings.use_alpha,
		"baked_at": Time.get_datetime_string_from_system(),
	}

	var json_string := JSON.stringify(metadata, "\t")
	var file := FileAccess.open(metadata_path, FileAccess.WRITE)
	if not file:
		push_error("ImpostorBaker: Failed to save metadata: %s" % metadata_path)
		return false

	file.store_string(json_string)
	file.close()

	print("ImpostorBaker: Saved impostor for %s" % model_path)
	print("  Texture: %s" % texture_path)
	print("  Size: %.1f x %.1f x %.1f" % [aabb.size.x, aabb.size.y, aabb.size.z])

	return true


## Get settings for a model (merging defaults with custom and candidate settings)
func _get_settings_for_model(model_path: String, custom: Dictionary) -> Dictionary:
	var settings := {
		"texture_size": DEFAULT_TEXTURE_SIZE,
		"frame_count": DEFAULT_FRAME_COUNT,
		"use_alpha": use_alpha,
	}

	# Apply settings from ImpostorCandidates if available
	if impostor_candidates:
		var candidate_settings: Dictionary = impostor_candidates.get_impostor_settings(model_path)
		for key in candidate_settings:
			settings[key] = candidate_settings[key]

	# Apply custom overrides
	for key in custom:
		settings[key] = custom[key]

	# Apply instance settings
	settings["frame_count"] = maxi(settings.frame_count, frame_count)

	return settings


## Get texture output path for a model
func _get_texture_path(model_path: String) -> String:
	var hash_str := str(model_path.to_lower().hash())
	return "%s/%s_impostor.png" % [OUTPUT_DIR, hash_str]


## Get metadata output path for a model
func _get_metadata_path(model_path: String) -> String:
	var hash_str := str(model_path.to_lower().hash())
	return "%s/%s_impostor.json" % [OUTPUT_DIR, hash_str]


## Process batch queue
func _process_batch_queue() -> void:
	var total := _batch_queue.size()
	var current := 0

	while not _batch_queue.is_empty():
		var model_path: String = _batch_queue.pop_front()
		current += 1

		progress_updated.emit(current, total, model_path)
		print("ImpostorBaker: [%d/%d] Baking %s" % [current, total, model_path])

		# Skip if already exists
		if has_impostor(model_path):
			print("  Skipping - impostor already exists")
			_batch_results.succeeded += 1
			continue

		var success := await bake_model(model_path)

		if success:
			_batch_results.succeeded += 1
		else:
			_batch_results.failed += 1

		# Small delay between models
		await get_tree().create_timer(0.1).timeout

	print("ImpostorBaker: Batch complete - %d succeeded, %d failed" % [
		_batch_results.succeeded, _batch_results.failed
	])

	batch_complete.emit(total, _batch_results.succeeded, _batch_results.failed)


#endregion


#region Static Utilities


## Get impostor texture path for a model (static version matching ImpostorCandidates)
static func get_impostor_texture_path(model_path: String) -> String:
	var hash_str := str(model_path.to_lower().hash())
	return "%s/%s_impostor.png" % [OUTPUT_DIR, hash_str]


## Get impostor metadata path for a model (static version matching ImpostorCandidates)
static func get_impostor_metadata_path(model_path: String) -> String:
	var hash_str := str(model_path.to_lower().hash())
	return "%s/%s_impostor.json" % [OUTPUT_DIR, hash_str]


#endregion
