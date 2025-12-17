# DeformationRenderer.gd
# Handles RTT (Render-To-Texture) rendering of deformation stamps
# Uses SubViewport with orthographic camera for top-down rendering
extends Node

const STAMP_RADIUS_DEFAULT: float = 0.5  # Meters

# Viewport for rendering deformation stamps
var _viewport: SubViewport
var _camera: Camera3D
var _stamp_mesh: MeshInstance3D
var _stamp_material: ShaderMaterial

# Quad mesh for stamping
var _quad_mesh: QuadMesh

func _ready():
	_setup_viewport()
	_setup_camera()
	_setup_stamp_mesh()

	print("[DeformationRenderer] RTT renderer initialized")

# Setup the SubViewport for rendering
func _setup_viewport():
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(
		DeformationManager.DEFORMATION_TEXTURE_SIZE,
		DeformationManager.DEFORMATION_TEXTURE_SIZE
	)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED  # Manual updates
	_viewport.transparent_bg = true
	add_child(_viewport)

# Setup orthographic camera for top-down view
func _setup_camera():
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGRAPHIC
	_camera.size = DeformationManager.REGION_SIZE_METERS
	_camera.near = 0.1
	_camera.far = 10.0

	# Position camera above the region looking down
	_camera.position = Vector3(
		DeformationManager.REGION_SIZE_METERS * 0.5,
		5.0,
		DeformationManager.REGION_SIZE_METERS * 0.5
	)
	_camera.rotation_degrees = Vector3(-90, 0, 0)

	_viewport.add_child(_camera)

# Setup stamp mesh (quad for deformation rendering)
func _setup_stamp_mesh():
	_stamp_mesh = MeshInstance3D.new()

	# Create quad mesh
	_quad_mesh = QuadMesh.new()
	_quad_mesh.size = Vector2(
		DeformationManager.REGION_SIZE_METERS,
		DeformationManager.REGION_SIZE_METERS
	)
	_stamp_mesh.mesh = _quad_mesh

	# Load stamp shader
	var shader = load("res://src/core/deformation/shaders/deformation_stamp.gdshader")
	_stamp_material = ShaderMaterial.new()
	_stamp_material.shader = shader

	_stamp_mesh.material_override = _stamp_material

	# Position quad to cover region
	_stamp_mesh.position = Vector3(
		DeformationManager.REGION_SIZE_METERS * 0.5,
		0.0,
		DeformationManager.REGION_SIZE_METERS * 0.5
	)
	_stamp_mesh.rotation_degrees = Vector3(-90, 0, 0)

	_viewport.add_child(_stamp_mesh)

# Render a deformation stamp to region texture
# Note: This queues a render request, actual rendering happens on next frame
# The caller should handle this properly via the pending queue system
func render_stamp(
	region_data,
	region_uv: Vector2,
	material_type: int,
	strength: float
):
	if _stamp_material == null:
		push_error("[DeformationRenderer] Stamp material not initialized")
		return

	# Set shader parameters for this stamp
	_stamp_material.set_shader_parameter("previous_deformation", region_data.texture)
	_stamp_material.set_shader_parameter("stamp_center_uv", region_uv)
	_stamp_material.set_shader_parameter("stamp_radius", STAMP_RADIUS_DEFAULT)
	_stamp_material.set_shader_parameter("stamp_strength", strength)
	_stamp_material.set_shader_parameter("material_type", _get_material_type_value(material_type))
	_stamp_material.set_shader_parameter("region_size_meters", DeformationManager.REGION_SIZE_METERS)

	# Request viewport render
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	# Force immediate rendering by accessing the render pipeline
	# This ensures the stamp is rendered synchronously within the current frame
	RenderingServer.force_draw(false, 0.0)

	# Get rendered result immediately after forced draw
	var rendered_texture = _viewport.get_texture()
	if rendered_texture != null:
		# Update region image from viewport
		var rendered_image = rendered_texture.get_image()
		if rendered_image != null:
			region_data.image = rendered_image
			region_data.texture.update(rendered_image)

# Convert material type enum to shader value
func _get_material_type_value(material_type: int) -> float:
	match material_type:
		DeformationManager.MaterialType.SNOW:
			return 0.0  # 0.0-0.25 range
		DeformationManager.MaterialType.MUD:
			return 0.25  # 0.25-0.5 range
		DeformationManager.MaterialType.ASH:
			return 0.5  # 0.5-0.75 range
		DeformationManager.MaterialType.SAND:
			return 0.75  # 0.75-1.0 range
		_:
			return 0.0

# Batch render multiple stamps in one pass (optimization)
func render_batch(stamps: Array, region_data):
	# TODO: Implement instanced rendering for multiple stamps
	# For now, render stamps sequentially
	for stamp in stamps:
		render_stamp(
			region_data,
			stamp["region_uv"],
			stamp["material_type"],
			stamp["strength"]
		)
