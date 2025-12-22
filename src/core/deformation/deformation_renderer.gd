# DeformationRenderer.gd
# Handles RTT (Render-To-Texture) rendering of deformation stamps
# Uses SubViewport with orthographic camera for top-down rendering
# Supports two modes: region-based (static cameras) and player-following (dynamic camera)
extends Node

const STAMP_RADIUS_DEFAULT: float = 0.5  # Meters

# Viewport for rendering deformation stamps
var _viewport: SubViewport
var _camera: Camera3D
var _stamp_mesh: MeshInstance3D
var _stamp_material: ShaderMaterial

# Quad mesh for stamping
var _quad_mesh: QuadMesh

# Player-following mode
var _follow_player: bool = false
var _player_node: Node3D = null
var _follow_radius: float = 40.0
var _last_camera_pos: Vector3 = Vector3.ZERO

func _ready():
	# Load camera follow settings
	_follow_player = DeformationConfig.camera_follow_player
	_follow_radius = DeformationConfig.camera_follow_radius

	_setup_viewport()
	_setup_camera()
	_setup_stamp_mesh()

	if _follow_player:
		print("[DeformationRenderer] RTT renderer initialized (PLAYER-FOLLOWING mode, radius: ", _follow_radius, "m)")
	else:
		print("[DeformationRenderer] RTT renderer initialized (REGION-BASED mode)")

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
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.near = 0.1
	_camera.far = 10.0
	_camera.rotation_degrees = Vector3(-90, 0, 0)  # Always looking down

	if _follow_player:
		# Player-following mode: smaller camera centered on player
		_camera.size = _follow_radius * 2.0  # Diameter
		_camera.position = Vector3(0, 5.0, 0)  # Will be updated dynamically
	else:
		# Region-based mode: camera covers entire region
		_camera.size = DeformationManager.REGION_SIZE_METERS
		# Position camera above the region center
		_camera.position = Vector3(
			DeformationManager.REGION_SIZE_METERS * 0.5,
			5.0,
			DeformationManager.REGION_SIZE_METERS * 0.5
		)

	_viewport.add_child(_camera)

# Setup stamp mesh (quad for deformation rendering)
func _setup_stamp_mesh():
	_stamp_mesh = MeshInstance3D.new()

	# Create quad mesh - size depends on mode
	_quad_mesh = QuadMesh.new()
	var quad_size: float
	if _follow_player:
		quad_size = _follow_radius * 2.0
	else:
		quad_size = DeformationManager.REGION_SIZE_METERS

	_quad_mesh.size = Vector2(quad_size, quad_size)
	_stamp_mesh.mesh = _quad_mesh

	# Load stamp shader
	var shader = load("res://src/core/deformation/shaders/deformation_stamp.gdshader")
	_stamp_material = ShaderMaterial.new()
	_stamp_material.shader = shader

	_stamp_mesh.material_override = _stamp_material

	# Position quad - centered at origin for player-follow, region center for region-based
	if _follow_player:
		_stamp_mesh.position = Vector3(0.0, 0.0, 0.0)  # Will be updated dynamically
	else:
		_stamp_mesh.position = Vector3(
			DeformationManager.REGION_SIZE_METERS * 0.5,
			0.0,
			DeformationManager.REGION_SIZE_METERS * 0.5
		)
	_stamp_mesh.rotation_degrees = Vector3(-90, 0, 0)

	_viewport.add_child(_stamp_mesh)

# Set the player node to follow (only used in player-following mode)
func set_player(player: Node3D) -> void:
	_player_node = player
	if _follow_player and _player_node:
		print("[DeformationRenderer] Now following player: ", _player_node.name)

# Process function to update camera position when following player
func _process(_delta: float):
	if not _follow_player or not _player_node:
		return

	# Update camera and stamp mesh to follow player
	var player_pos = _player_node.global_position
	var new_camera_pos = Vector3(player_pos.x, 5.0, player_pos.z)

	# Only update if player moved significantly (avoid unnecessary updates)
	if _last_camera_pos.distance_to(new_camera_pos) > 0.1:
		_camera.global_position = new_camera_pos
		_stamp_mesh.global_position = Vector3(player_pos.x, 0.0, player_pos.z)
		_last_camera_pos = new_camera_pos

# Render a deformation stamp to region texture
# Note: This queues a render request, actual rendering happens on next frame
# The caller should handle this properly via the pending queue system
func render_stamp(
	region_data,
	region_uv: Vector2,
	material_type: int,
	strength: float,
	world_pos: Vector3 = Vector3.ZERO  # Only used in player-following mode
):
	if _stamp_material == null:
		push_error("[DeformationRenderer] Stamp material not initialized")
		return

	# Calculate UV based on mode
	var stamp_uv: Vector2
	var effective_region_size: float

	if _follow_player:
		# Player-following mode: UV relative to camera center
		# Camera is centered on player, world_pos is where deformation occurs
		var camera_pos_xz = Vector2(_camera.global_position.x, _camera.global_position.z)
		var deform_pos_xz = Vector2(world_pos.x, world_pos.z)
		var offset = deform_pos_xz - camera_pos_xz

		# Convert to UV (0.0 to 1.0, where 0.5 is center)
		stamp_uv = Vector2(0.5, 0.5) + offset / (_follow_radius * 2.0)
		effective_region_size = _follow_radius * 2.0
	else:
		# Region-based mode: use provided region UV
		stamp_uv = region_uv
		effective_region_size = DeformationManager.REGION_SIZE_METERS

	# Set shader parameters for this stamp
	_stamp_material.set_shader_parameter("previous_deformation", region_data.texture)
	_stamp_material.set_shader_parameter("stamp_center_uv", stamp_uv)
	_stamp_material.set_shader_parameter("stamp_radius", STAMP_RADIUS_DEFAULT)
	_stamp_material.set_shader_parameter("stamp_strength", strength)
	_stamp_material.set_shader_parameter("material_type", _get_material_type_value(material_type))
	_stamp_material.set_shader_parameter("region_size_meters", effective_region_size)

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
			return 0.0  # 0.0-0.125 range
		DeformationManager.MaterialType.MUD:
			return 0.25  # 0.25-0.375 range
		DeformationManager.MaterialType.ASH:
			return 0.5  # 0.5-0.625 range
		DeformationManager.MaterialType.SAND:
			return 0.75  # 0.75-0.9 range
		DeformationManager.MaterialType.ROCK:
			return 1.0  # 0.9-1.0 range (no deformation)
		_:
			return 0.0

# Batch render multiple stamps in one pass (optimization)
func render_batch(stamps: Array, region_data):
	# TODO: Implement instanced rendering for multiple stamps
	# For now, render stamps sequentially
	for stamp in stamps:
		var world_pos = stamp.get("world_pos", Vector3.ZERO)
		render_stamp(
			region_data,
			stamp.get("region_uv", Vector2.ZERO),
			stamp["material_type"],
			stamp["strength"],
			world_pos
		)
