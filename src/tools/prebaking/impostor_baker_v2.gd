## ImpostorBakerV2 - High-quality octahedral impostor texture generator
##
## Creates pre-baked impostor textures for distant rendering (FAR tier, 500m-5km).
## Uses SubViewport to render models from 16 octahedral viewing angles.
##
## Key features:
## - 16-frame octahedral atlas (4x4 layout) for smooth rotation
## - Depth baking in alpha channel for parallax correction
## - Hemisphere coverage optimized for ground-based objects
## - Async baking support with progress signals
## - Resume capability via prebake state
##
## Output format:
## - PNG atlas: 512x512 (4x4 of 128x128 frames)
## - RGBA: RGB = albedo, A = normalized depth (for parallax)
## - JSON metadata with bounds, directions, UVs
class_name ImpostorBakerV2
extends Node

const NIFConverter := preload("res://src/core/nif/nif_converter.gd")

## 16 octahedral directions (hemisphere coverage for ground-based objects)
## Arranged for smooth rotation: 16 evenly spaced angles around the hemisphere
const OCTAHEDRAL_DIRECTIONS: Array[Vector3] = [
	Vector3(0.0, 0.0, 1.0),       # 0: Front (N)
	Vector3(0.383, 0.0, 0.924),   # 1: N-NE (22.5°)
	Vector3(0.707, 0.0, 0.707),   # 2: NE (45°)
	Vector3(0.924, 0.0, 0.383),   # 3: E-NE (67.5°)
	Vector3(1.0, 0.0, 0.0),       # 4: East (E)
	Vector3(0.924, 0.0, -0.383),  # 5: E-SE (112.5°)
	Vector3(0.707, 0.0, -0.707),  # 6: SE (135°)
	Vector3(0.383, 0.0, -0.924),  # 7: S-SE (157.5°)
	Vector3(0.0, 0.0, -1.0),      # 8: Back (S)
	Vector3(-0.383, 0.0, -0.924), # 9: S-SW (202.5°)
	Vector3(-0.707, 0.0, -0.707), # 10: SW (225°)
	Vector3(-0.924, 0.0, -0.383), # 11: W-SW (247.5°)
	Vector3(-1.0, 0.0, 0.0),      # 12: West (W)
	Vector3(-0.924, 0.0, 0.383),  # 13: W-NW (292.5°)
	Vector3(-0.707, 0.0, 0.707),  # 14: NW (315°)
	Vector3(-0.383, 0.0, 0.924),  # 15: N-NW (337.5°)
]

## Settings
var texture_size: int = 512        ## Total atlas size
var frame_size: int = 128          ## Size per frame (512/4 = 128)
var atlas_columns: int = 4         ## Atlas layout columns
var atlas_rows: int = 4            ## Atlas layout rows (16 frames = 4x4)
var camera_fov: float = 45.0       ## Camera FOV for perspective rendering
var use_orthographic: bool = true  ## Use orthographic projection (better for impostors)
var padding_factor: float = 1.2    ## Extra space around model
var background_color: Color = Color(0, 0, 0, 0)
var min_distance: float = 500.0    ## Start showing impostor
var max_distance: float = 5000.0   ## Stop showing impostor
var output_dir: String = ""        ## Set in initialize from SettingsManager
var bake_depth: bool = true        ## Bake depth into alpha channel

## Rendering setup
var _viewport: SubViewport = null
var _depth_viewport: SubViewport = null
var _camera: Camera3D = null
var _depth_camera: Camera3D = null
var _light: DirectionalLight3D = null
var _model_container: Node3D = null
var _depth_model_container: Node3D = null

## Depth rendering material
var _depth_material: ShaderMaterial = null

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

	# Create color SubViewport for rendering
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(frame_size, frame_size)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.transparent_bg = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.use_hdr_2d = false
	_viewport.own_world_3d = true
	add_child(_viewport)

	# Create camera
	_camera = Camera3D.new()
	if use_orthographic:
		_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		_camera.size = 10.0
	else:
		_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
		_camera.fov = camera_fov
	_camera.near = 0.1
	_camera.far = 1000.0
	_viewport.add_child(_camera)

	# Create directional light
	_light = DirectionalLight3D.new()
	_light.rotation_degrees = Vector3(-45, 45, 0)
	_light.light_energy = 1.0
	_light.shadow_enabled = false
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

	# Container for models
	_model_container = Node3D.new()
	_model_container.name = "ModelContainer"
	_viewport.add_child(_model_container)

	# Create depth viewport if depth baking is enabled
	if bake_depth:
		_setup_depth_viewport()

	_is_initialized = true
	print("ImpostorBakerV2: Initialized (16-frame, %dx%d atlas, depth=%s)" % [texture_size, texture_size, bake_depth])


## Set up depth rendering viewport
func _setup_depth_viewport() -> void:
	_depth_viewport = SubViewport.new()
	_depth_viewport.size = Vector2i(frame_size, frame_size)
	_depth_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_depth_viewport.transparent_bg = true
	_depth_viewport.msaa_3d = Viewport.MSAA_DISABLED  # Depth doesn't need MSAA
	_depth_viewport.use_hdr_2d = false
	_depth_viewport.own_world_3d = true
	add_child(_depth_viewport)

	# Create depth camera (matches main camera)
	_depth_camera = Camera3D.new()
	if use_orthographic:
		_depth_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		_depth_camera.size = 10.0
	else:
		_depth_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
		_depth_camera.fov = camera_fov
	_depth_camera.near = 0.1
	_depth_camera.far = 1000.0
	_depth_viewport.add_child(_depth_camera)

	# Depth environment (no lighting needed)
	var depth_world_env := WorldEnvironment.new()
	var depth_env := Environment.new()
	depth_env.background_mode = Environment.BG_COLOR
	depth_env.background_color = Color(1, 1, 1, 0)  # White = far
	depth_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	depth_env.ambient_light_color = Color.WHITE
	depth_env.ambient_light_energy = 1.0
	depth_world_env.environment = depth_env
	_depth_viewport.add_child(depth_world_env)

	# Container for depth model
	_depth_model_container = Node3D.new()
	_depth_model_container.name = "DepthModelContainer"
	_depth_viewport.add_child(_depth_model_container)

	# Create depth material
	_depth_material = ShaderMaterial.new()
	var depth_shader := Shader.new()
	depth_shader.code = """
shader_type spatial;
render_mode unshaded, depth_draw_always, cull_back;

uniform float near_plane = 0.1;
uniform float far_plane = 100.0;

void fragment() {
	// Linearize depth and output as grayscale
	float depth = FRAGCOORD.z;
	float linear_depth = (2.0 * near_plane) / (far_plane + near_plane - depth * (far_plane - near_plane));
	ALBEDO = vec3(linear_depth);
	ALPHA = 1.0;
}
"""
	_depth_material.shader = depth_shader


## Initialize output directory
func initialize() -> Error:
	_setup_rendering_viewport()

	if output_dir.is_empty():
		output_dir = SettingsManager.get_impostors_path()

	var err := SettingsManager.ensure_cache_directories()
	if err != OK:
		push_error("ImpostorBakerV2: Failed to create cache directories")
		return err

	return OK


## Bake impostor for a single model
func bake_model(model_path: String) -> Dictionary:
	print("ImpostorBakerV2: Baking %s..." % model_path)

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

	# Create depth model copy if baking depth
	var depth_model: Node3D = null
	if bake_depth and _depth_model_container:
		depth_model = _load_model(model_path)
		if depth_model:
			_apply_depth_material(depth_model)
			_depth_model_container.add_child(depth_model)

	await get_tree().process_frame

	# Calculate model bounds
	var aabb := _get_model_aabb(model)
	if aabb.size.length() < 0.01:
		var error := "Model has invalid bounds"
		push_warning("ImpostorBakerV2: %s - %s" % [error, model_path])
		model.queue_free()
		if depth_model:
			depth_model.queue_free()
		model_baked.emit(model_path, false, "")
		return {"success": false, "output_path": "", "error": error}

	# Center model at origin
	var center := aabb.get_center()
	model.position = -center
	if depth_model:
		depth_model.position = -center

	await get_tree().process_frame

	# Configure camera for this model
	var size := aabb.size
	var max_extent := maxf(maxf(size.x, size.y), size.z) * padding_factor

	if use_orthographic:
		_camera.size = max_extent
		if _depth_camera:
			_depth_camera.size = max_extent

	var camera_distance := max_extent * 2.0

	# Update depth material uniforms
	if _depth_material:
		_depth_material.set_shader_parameter("near_plane", _camera.near)
		_depth_material.set_shader_parameter("far_plane", camera_distance * 2.0)

	# Render from all 16 directions
	var color_frames: Array[Image] = []
	var depth_frames: Array[Image] = []

	for i in range(OCTAHEDRAL_DIRECTIONS.size()):
		var direction: Vector3 = OCTAHEDRAL_DIRECTIONS[i].normalized()

		# Render color frame
		var color_frame := await _render_from_direction_async(_camera, _viewport, direction, camera_distance)
		if color_frame:
			color_frames.append(color_frame)
		else:
			var blank := Image.create(frame_size, frame_size, false, Image.FORMAT_RGBA8)
			blank.fill(background_color)
			color_frames.append(blank)

		# Render depth frame if enabled
		if bake_depth and _depth_camera and _depth_viewport:
			var depth_frame := await _render_from_direction_async(_depth_camera, _depth_viewport, direction, camera_distance)
			if depth_frame:
				depth_frames.append(depth_frame)
			else:
				var blank := Image.create(frame_size, frame_size, false, Image.FORMAT_RGBA8)
				blank.fill(Color.WHITE)
				depth_frames.append(blank)

	# Clean up models
	model.queue_free()
	if depth_model:
		depth_model.queue_free()

	# Combine color and depth into final atlas
	var atlas := _pack_atlas_with_depth(color_frames, depth_frames)
	if not atlas:
		var error := "Failed to pack atlas"
		push_warning("ImpostorBakerV2: %s - %s" % [error, model_path])
		model_baked.emit(model_path, false, "")
		return {"success": false, "output_path": "", "error": error}

	# Save
	var texture_path := _get_output_path(model_path, "png")
	var metadata_path := _get_output_path(model_path, "json")

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


## Apply depth material to all meshes in a node hierarchy
func _apply_depth_material(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_inst: MeshInstance3D = node
		mesh_inst.material_override = _depth_material

	for child in node.get_children():
		_apply_depth_material(child)


## Bake all models in a list
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

		await get_tree().process_frame

	batch_complete.emit(model_paths.size(), _total_baked, _total_failed)

	return {
		"total": model_paths.size(),
		"success": _total_baked,
		"failed": _total_failed,
		"failed_models": _failed_models.duplicate()
	}


## Render model from a specific direction
func _render_from_direction_async(cam: Camera3D, vp: SubViewport, direction: Vector3, distance: float) -> Image:
	cam.position = direction * distance
	cam.look_at(Vector3.ZERO, Vector3.UP)

	vp.render_target_update_mode = SubViewport.UPDATE_ONCE

	await get_tree().process_frame
	await get_tree().process_frame

	var texture := vp.get_texture()
	if not texture:
		return null

	var image := texture.get_image()
	if not image:
		return null

	return image.duplicate()


## Pack frames into atlas with depth in alpha channel
func _pack_atlas_with_depth(color_frames: Array[Image], depth_frames: Array[Image]) -> Image:
	var expected_frames := atlas_columns * atlas_rows
	if color_frames.size() < expected_frames:
		push_warning("ImpostorBakerV2: Expected %d frames, got %d" % [expected_frames, color_frames.size()])

	# Create atlas
	var atlas := Image.create(texture_size, texture_size, false, Image.FORMAT_RGBA8)
	atlas.fill(background_color)

	var frame_idx := 0
	for row in range(atlas_rows):
		for col in range(atlas_columns):
			if frame_idx >= color_frames.size():
				break

			var x := col * frame_size
			var y := row * frame_size

			# Get color frame
			var color_frame: Image = color_frames[frame_idx]

			# Get depth frame if available
			var depth_frame: Image = null
			if frame_idx < depth_frames.size():
				depth_frame = depth_frames[frame_idx]

			# Combine color RGB with depth in alpha (or use color alpha if no depth)
			var combined := Image.create(frame_size, frame_size, false, Image.FORMAT_RGBA8)

			for py in range(frame_size):
				for px in range(frame_size):
					var color := color_frame.get_pixel(px, py)

					if depth_frame and color.a > 0.5:  # Only apply depth to non-transparent pixels
						var depth_color := depth_frame.get_pixel(px, py)
						# Use depth as alpha (inverted: close = 1, far = 0)
						# But preserve original alpha for transparency
						color.a = 1.0 - depth_color.r  # Invert so closer = higher alpha
					# Else keep original alpha for transparency masking

					combined.set_pixel(px, py, color)

			atlas.blit_rect(combined, Rect2i(0, 0, frame_size, frame_size), Vector2i(x, y))
			frame_idx += 1

	return atlas


## Load model from BSA/filesystem
func _load_model(model_path: String) -> Node3D:
	var full_path := model_path
	if not model_path.to_lower().begins_with("meshes"):
		full_path = "meshes/" + model_path

	full_path = full_path.replace("\\", "/")

	var nif_data := PackedByteArray()
	if BSAManager.has_file(full_path):
		nif_data = BSAManager.extract_file(full_path)
	elif BSAManager.has_file(model_path):
		nif_data = BSAManager.extract_file(model_path)
		full_path = model_path

	if nif_data.is_empty():
		push_warning("ImpostorBakerV2: File not found: %s" % model_path)
		return null

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
func _get_output_path(model_path: String, extension: String) -> String:
	var normalized := model_path
	var lower := normalized.to_lower()
	if lower.begins_with("meshes\\") or lower.begins_with("meshes/"):
		normalized = normalized.substr(7)

	var hash_val := normalized.to_lower().hash()
	var base_name := normalized.get_file().get_basename()
	base_name = base_name.replace("\\", "_").replace("/", "_").replace(" ", "_").to_lower()
	var filename := "%s_%x.%s" % [base_name, hash_val, extension]
	return output_dir.path_join(filename)


## Generate metadata JSON
func _generate_metadata(model_path: String, aabb: AABB, texture_path: String) -> Dictionary:
	var size := aabb.size

	return {
		"version": 3,
		"model_path": model_path,
		"texture_path": texture_path,
		"settings": {
			"texture_size": texture_size,
			"frame_size": frame_size,
			"atlas_columns": atlas_columns,
			"atlas_rows": atlas_rows,
			"frames": atlas_columns * atlas_rows,
			"min_distance": min_distance,
			"max_distance": max_distance,
			"use_orthographic": use_orthographic,
			"has_depth": bake_depth,
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
