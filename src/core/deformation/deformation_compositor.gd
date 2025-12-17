# DeformationCompositor.gd
# Handles deformation blending, accumulation, and time-based recovery
# Processes recovery shader for gradual deformation fade
extends Node

# Recovery viewport for processing recovery shader
var _recovery_viewport: SubViewport
var _recovery_camera: Camera3D
var _recovery_mesh: MeshInstance3D
var _recovery_material: ShaderMaterial

# Recovery update rate throttling (don't need to update every frame)
const RECOVERY_UPDATE_INTERVAL: float = 1.0  # Update once per second
var _time_since_last_recovery: float = 0.0

func _ready():
	_setup_recovery_viewport()
	print("[DeformationCompositor] Compositor initialized")

# Setup recovery viewport for processing recovery shader
func _setup_recovery_viewport():
	_recovery_viewport = SubViewport.new()
	_recovery_viewport.size = Vector2i(
		DeformationManager.DEFORMATION_TEXTURE_SIZE,
		DeformationManager.DEFORMATION_TEXTURE_SIZE
	)
	_recovery_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_recovery_viewport.transparent_bg = false
	add_child(_recovery_viewport)

	# Orthographic camera
	_recovery_camera = Camera3D.new()
	_recovery_camera.projection = Camera3D.PROJECTION_ORTHOGRAPHIC
	_recovery_camera.size = DeformationManager.REGION_SIZE_METERS
	_recovery_camera.near = 0.1
	_recovery_camera.far = 10.0
	_recovery_camera.position = Vector3(
		DeformationManager.REGION_SIZE_METERS * 0.5,
		5.0,
		DeformationManager.REGION_SIZE_METERS * 0.5
	)
	_recovery_camera.rotation_degrees = Vector3(-90, 0, 0)
	_recovery_viewport.add_child(_recovery_camera)

	# Quad mesh for recovery shader
	_recovery_mesh = MeshInstance3D.new()
	var quad = QuadMesh.new()
	quad.size = Vector2(
		DeformationManager.REGION_SIZE_METERS,
		DeformationManager.REGION_SIZE_METERS
	)
	_recovery_mesh.mesh = quad

	# Load recovery shader
	var shader = load("res://src/core/deformation/shaders/deformation_recovery.gdshader")
	_recovery_material = ShaderMaterial.new()
	_recovery_material.shader = shader
	_recovery_mesh.material_override = _recovery_material

	_recovery_mesh.position = Vector3(
		DeformationManager.REGION_SIZE_METERS * 0.5,
		0.0,
		DeformationManager.REGION_SIZE_METERS * 0.5
	)
	_recovery_mesh.rotation_degrees = Vector3(-90, 0, 0)
	_recovery_viewport.add_child(_recovery_mesh)

# Process recovery for all active regions
func process_recovery(delta: float, active_regions: Dictionary):
	if not DeformationManager.recovery_enabled:
		return

	_time_since_last_recovery += delta

	# Throttle recovery updates
	if _time_since_last_recovery < RECOVERY_UPDATE_INTERVAL:
		return

	var actual_delta = _time_since_last_recovery
	_time_since_last_recovery = 0.0

	# Apply recovery to each active region
	for region_coord in active_regions.keys():
		var region_data = active_regions[region_coord]
		_apply_recovery_to_region(region_data, actual_delta)

# Apply recovery shader to a single region
func _apply_recovery_to_region(region_data, delta: float):
	if _recovery_material == null:
		return

	# Set shader parameters
	_recovery_material.set_shader_parameter("previous_deformation", region_data.texture)
	_recovery_material.set_shader_parameter("recovery_rate", DeformationManager.recovery_rate)
	_recovery_material.set_shader_parameter("delta_time", delta)

	# Render recovery pass
	_recovery_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	# Wait for render
	await get_tree().process_frame

	# Get recovered result
	var recovered_texture = _recovery_viewport.get_texture()
	if recovered_texture != null:
		var recovered_image = recovered_texture.get_image()
		if recovered_image != null:
			region_data.image = recovered_image
			region_data.texture.update(recovered_image)
			region_data.dirty = true

# Blend two deformation states (for future accumulation tracking)
func blend_deformation(base_depth: float, new_depth: float, material_type: int) -> float:
	match material_type:
		DeformationManager.MaterialType.SNOW:
			# Snow accumulates
			return min(base_depth + new_depth, 1.0)
		DeformationManager.MaterialType.MUD:
			# Mud replaces
			return max(base_depth, new_depth * 0.7)
		DeformationManager.MaterialType.ASH:
			# Ash partially accumulates
			return min(base_depth + new_depth * 0.5, 0.8)
		DeformationManager.MaterialType.SAND:
			# Sand minimal accumulation
			return max(base_depth, new_depth * 0.5)
		_:
			return new_depth

# Get material-specific recovery rate multiplier
func get_recovery_multiplier(material_type: int) -> float:
	match material_type:
		DeformationManager.MaterialType.SNOW:
			return 0.5  # Snow recovers slowly
		DeformationManager.MaterialType.MUD:
			return 0.2  # Mud recovers very slowly
		DeformationManager.MaterialType.ASH:
			return 1.0  # Ash recovers normally
		DeformationManager.MaterialType.SAND:
			return 2.0  # Sand recovers quickly
		_:
			return 1.0
