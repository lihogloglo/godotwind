## Underwater post-processing effect controller.
##
## Creates a full-screen quad with the underwater shader and manages it based
## on camera submersion. Ported from Rafael's DIVE.omwfx (OpenMW).
##
## Features: caustics, absorption, screen wobble, light rays, backscatter,
## water boundary meniscus effect, anti-banding dithering.
##
## Usage: Created and managed by OceanManager. Can also be instantiated
## standalone — call initialize() with a camera reference.
class_name UnderwaterEffect
extends Node

const SHADER_PATH := "res://src/core/water/shaders/underwater.gdshader"

# Submersion state
var _camera: Camera3D = null
var _sea_level: float = 0.0
var _is_submerged: bool = false
var _submersion_depth: float = 0.0  # How deep camera is below sea level

# Rendering
var _quad: MeshInstance3D = null
var _material: ShaderMaterial = null
var _shader: Shader = null

# Sun tracking
var _sun_direction: Vector3 = Vector3(0.3, 0.8, 0.2)
var _sun_visibility: float = 1.0
var _sun_color: Color = Color(1.0, 0.95, 0.85)

# Effect toggles
var caustics_enabled: bool = true
var rays_enabled: bool = true
var wobble_enabled: bool = true
var backscatter_enabled: bool = true
var boundary_enabled: bool = true

# Debug mode: 0=off, 1=water_depth, 2=world_pos.y, 3=underwater mask,
#             4=caustic pattern, 5=world normal, 6=linear depth
var debug_mode: int = 0

# Activation threshold — camera must be this deep (m) before effects kick in
var activation_depth: float = 0.1


func initialize(camera: Camera3D, sea_level: float = 0.0) -> void:
	_camera = camera
	_sea_level = sea_level

	_shader = load(SHADER_PATH) as Shader
	if _shader == null:
		Log.error("water", "UnderwaterEffect: Failed to load shader at %s" % SHADER_PATH)
		return

	_material = ShaderMaterial.new()
	_material.shader = _shader
	_material.render_priority = 100  # Render after everything

	# Create full-screen quad as camera child
	_quad = MeshInstance3D.new()
	_quad.name = "UnderwaterQuad"
	var mesh := QuadMesh.new()
	mesh.size = Vector2(2.0, 2.0)
	_quad.mesh = mesh
	_quad.material_override = _material
	# Position quad at the near plane, filling the entire view
	# The shader uses SCREEN_UV so exact positioning doesn't matter much,
	# but it must be in front of the camera and cover the viewport.
	_quad.position = Vector3(0.0, 0.0, -0.5)
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.visible = false

	camera.add_child(_quad)
	Log.info("water", "UnderwaterEffect: Initialized (shader loaded)")


func _process(_delta: float) -> void:
	if _camera == null or _material == null:
		return

	# Compute submersion
	var cam_y: float = _camera.global_position.y
	_submersion_depth = _sea_level - cam_y
	_is_submerged = _submersion_depth > -boundary_thickness()

	# Show/hide quad
	_quad.visible = _is_submerged

	if not _is_submerged:
		return

	# Update uniforms
	_material.set_shader_parameter("sea_level", _sea_level)
	_material.set_shader_parameter("camera_world_pos", _camera.global_position)
	_material.set_shader_parameter("sun_direction", _sun_direction)
	_material.set_shader_parameter("sun_visibility", _sun_visibility)
	_material.set_shader_parameter("sun_color", Vector3(_sun_color.r, _sun_color.g, _sun_color.b))

	# Toggle effects via intensity uniforms
	_material.set_shader_parameter("caustic_intensity", 1.2 if caustics_enabled else 0.0)
	_material.set_shader_parameter("ray_intensity", 0.8 if rays_enabled else 0.0)
	_material.set_shader_parameter("wobble_strength", 0.012 if wobble_enabled else 0.0)
	_material.set_shader_parameter("backscatter_strength", 0.55 if backscatter_enabled else 0.0)
	_material.set_shader_parameter("boundary_distortion", 0.03 if boundary_enabled else 0.0)
	_material.set_shader_parameter("debug_mode", debug_mode)


## How thick the boundary zone is (camera near waterline) in meters
func boundary_thickness() -> float:
	return 2.0


func set_sea_level(level: float) -> void:
	_sea_level = level


func set_sun(direction: Vector3, visibility: float, color: Color) -> void:
	_sun_direction = direction.normalized()
	_sun_visibility = visibility
	_sun_color = color


func set_water_color(color: Color) -> void:
	if _material:
		_material.set_shader_parameter("water_tint", Vector3(color.r, color.g, color.b))


func set_absorption_rate(rate: float) -> void:
	if _material:
		_material.set_shader_parameter("absorption_rate", rate)


func is_submerged() -> bool:
	return _is_submerged


func get_submersion_depth() -> float:
	return _submersion_depth


func get_material() -> ShaderMaterial:
	return _material


func set_enabled(enabled: bool) -> void:
	if _quad:
		_quad.visible = enabled and _is_submerged
	set_process(enabled)


func cleanup() -> void:
	if _quad and is_instance_valid(_quad):
		_quad.queue_free()
		_quad = null
	_material = null
	_camera = null
