## DeformationChunk - Manages RTT deformation for a single terrain chunk
## Handles rendering deformation brushes and providing texture for terrain/grass sampling
class_name DeformationChunk
extends Node3D

## Chunk configuration
var chunk_coord: Vector2i  ## Grid coordinates of this chunk
var chunk_size: float = 256.0  ## Physical size in meters (matches terrain region)
var texture_resolution: int = 512  ## RTT resolution

## RTT resources
var viewport: SubViewport
var deformation_texture: ViewportTexture  ## RGBA: R=depth, G=accumulation, B=wetness, A=age
var brush_renderer: MeshInstance3D
var ortho_camera: Camera3D

## Material behavior
var material_preset: DeformationPreset

## State tracking
var is_dirty: bool = false  ## Needs render update
var pending_brushes: Array[Dictionary] = []  ## Queue of brush operations
var decay_age: float = 0.0  ## Time since last deformation


## Initialize the chunk with a pooled viewport or create new one
func initialize(coord: Vector2i, size: float, resolution: int, preset: DeformationPreset, pooled_viewport: SubViewport = null) -> void:
	chunk_coord = coord
	chunk_size = size
	texture_resolution = resolution
	material_preset = preset

	# Calculate world position (center of chunk)
	global_position = Vector3(
		coord.x * chunk_size + chunk_size / 2.0,
		0.0,
		coord.y * chunk_size + chunk_size / 2.0
	)

	# Setup viewport (reuse or create)
	if pooled_viewport:
		viewport = pooled_viewport
		viewport.size = Vector2i(texture_resolution, texture_resolution)
	else:
		viewport = SubViewport.new()
		viewport.size = Vector2i(texture_resolution, texture_resolution)
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED  # Manual updates only
		viewport.transparent_bg = false
		add_child(viewport)

	deformation_texture = viewport.get_texture()

	# Setup orthographic camera for top-down rendering
	ortho_camera = Camera3D.new()
	ortho_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	ortho_camera.size = chunk_size
	ortho_camera.near = 0.1
	ortho_camera.far = 100.0
	ortho_camera.position = Vector3(0, 50, 0)  # Above terrain
	ortho_camera.rotation.x = -PI / 2  # Look down
	viewport.add_child(ortho_camera)

	# Setup brush renderer (quad mesh for stamping)
	_setup_brush_renderer()

	print("[DeformationChunk] Initialized chunk %s at %s (res: %d)" % [chunk_coord, global_position, texture_resolution])


## Setup the brush rendering mesh
func _setup_brush_renderer() -> void:
	brush_renderer = MeshInstance3D.new()

	# Create quad mesh
	var quad_mesh := QuadMesh.new()
	quad_mesh.size = Vector2(chunk_size, chunk_size)
	brush_renderer.mesh = quad_mesh

	# TODO: Assign deformation brush shader material
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	brush_renderer.material_override = material

	brush_renderer.position = Vector3(0, 0, 0)
	brush_renderer.rotation.x = -PI / 2
	viewport.add_child(brush_renderer)


## Queue a brush stamp for rendering
func queue_brush(world_pos: Vector3, radius: float, strength: float) -> void:
	# Convert world position to chunk-local UV
	var local_pos := world_pos - global_position
	var uv := Vector2(
		(local_pos.x + chunk_size / 2.0) / chunk_size,
		(local_pos.z + chunk_size / 2.0) / chunk_size
	)

	# Clamp to chunk bounds
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return  # Outside chunk

	pending_brushes.append({
		"world_pos": world_pos,
		"uv": uv,
		"radius": radius,
		"strength": strength,
	})

	is_dirty = true


## Render all pending brushes to RTT
func render_pending_brushes() -> void:
	if pending_brushes.is_empty():
		return

	# TODO: Implement multi-pass brush rendering
	# 1. Render brush stamps with additive blending
	# 2. Apply accumulation logic
	# 3. Apply decay if enabled

	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	pending_brushes.clear()
	is_dirty = false


## Update decay over time
func update_decay(delta: float) -> void:
	if not material_preset.enable_decay:
		return

	decay_age += delta

	if decay_age >= material_preset.decay_delay:
		# TODO: Apply decay shader pass to reduce deformation
		is_dirty = true


## Get deformation depth at world position (CPU sample)
func get_deformation_at(world_pos: Vector3) -> float:
	var local_pos := world_pos - global_position
	var uv := Vector2(
		(local_pos.x + chunk_size / 2.0) / chunk_size,
		(local_pos.z + chunk_size / 2.0) / chunk_size
	)

	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return 0.0

	# TODO: Sample deformation texture (requires CPU readback)
	# Note: This is expensive - use sparingly or async
	return 0.0


## Save deformation state to disk
func save_to_disk(save_path: String) -> void:
	var img := viewport.get_texture().get_image()
	if img:
		img.save_png(save_path)
		print("[DeformationChunk] Saved to: " + save_path)


## Load deformation state from disk
func load_from_disk(load_path: String) -> void:
	if not FileAccess.file_exists(load_path):
		return

	var img := Image.load_from_file(load_path)
	if img:
		# TODO: Apply loaded texture to viewport
		print("[DeformationChunk] Loaded from: " + load_path)


## Get texture for terrain/grass shader binding
func get_deformation_texture() -> ViewportTexture:
	return deformation_texture


## Cleanup and return viewport to pool
func cleanup() -> SubViewport:
	if viewport:
		# Clear viewport contents
		for child in viewport.get_children():
			child.queue_free()

		remove_child(viewport)
		return viewport
	return null
