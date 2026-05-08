## UnderwaterVolume — follows the camera, drives underwater_volume.gdshader.
##
## Step 0 (caustics only). A BoxMesh rendered with a custom spatial shader
## that draws caustics on world geometry inside the volume's Y slab.
##
## Ported from paddy-exe/Godot-RealTimeCaustics (MIT):
##   https://github.com/paddy-exe/Godot-RealTimeCaustics
##
## ## Positioning model
##
## The volume is NOT a child of the camera — parenting to a Camera3D would
## rotate the box with camera pitch/yaw and cause the box edges to sweep
## through the world, popping effects in and out at the edges.
##
## Instead, this node lives as a sibling of the camera under the scene root.
## Each frame, `_process()` copies the camera's `global_position` (not
## rotation) into this node's `global_position`, keeping the volume axis-
## aligned with world Y.
##
## ## Volume bounds
##
## Size: 500 × 40 × 500 (per reviewer). Box is vertically centered on the
## camera, but the shader itself slabs its effects to the range
## [sea_level - volume_depth, sea_level] regardless of where the box floats —
## so effects will not appear above the water even if the camera is at y=+50.
## The box just has to contain any pixel where caustics should be visible,
## and 500 × 40 × 500 is comfortably larger than Morrowind's underwater
## visibility range.
##
## ## Activation
##
## Only visible when the camera is below the water surface. When above water,
## the node is hidden (saves the draw call entirely — no front-face cull + no
## SCREEN_TEXTURE sample).
class_name UnderwaterVolume
extends Node3D

const SHADER_PATH := "res://src/core/water/shaders/underwater_volume.gdshader"
const CAUSTICS_NOISE_PATH := "res://assets/water/caustics_noise.png"
const LUMA_GRADIENT_PATH := "res://assets/water/caustics_luma_gradient.tres"
const WATER_NORMAL_PATH := "res://assets/water/water_normal.png"

const VOLUME_SIZE := Vector3(500.0, 40.0, 500.0)

var _mesh_instance: MeshInstance3D
var _material: ShaderMaterial
var _camera: Camera3D = null
var _sun: DirectionalLight3D = null
var _sea_level: float = 0.0
var _debug_mode: int = 0
var enabled: bool = true
var active_above_water: bool = false
var wobble_enabled: bool = true


func _ready() -> void:
	var mesh := BoxMesh.new()
	mesh.size = VOLUME_SIZE

	_material = ShaderMaterial.new()
	_material.shader = load(SHADER_PATH)
	_material.render_priority = 80
	_material.set_shader_parameter("caustics_noise", load(CAUSTICS_NOISE_PATH))
	_material.set_shader_parameter("luma_gradient", load(LUMA_GRADIENT_PATH))
	_material.set_shader_parameter("water_normal_map", load(WATER_NORMAL_PATH))
	_material.set_shader_parameter("volume_depth", VOLUME_SIZE.y)

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "UnderwaterBox"
	_mesh_instance.mesh = mesh
	_mesh_instance.material_override = _material
	# The volume is geometry the camera sits inside; disable frustum culling
	# so the box doesn't pop out when the camera is near an edge.
	_mesh_instance.extra_cull_margin = 500.0
	add_child(_mesh_instance)

	visible = false  # hidden until _process() confirms camera is underwater


## Assign the scene camera. Must be called before the volume becomes useful.
func set_camera(camera: Camera3D) -> void:
	_camera = camera


## Assign the sun/directional light. Used to project caustics from the sun
## direction in world space (paddy-exe's make_rotation_dir technique).
func set_sun(sun: DirectionalLight3D) -> void:
	_sun = sun


## Override the sea level Y value. Defaults to 0 if not called.
## If OceanManager is available, prefer calling this from the scene each frame
## so tides/weather/etc. stay in sync.
func set_sea_level(y: float) -> void:
	_sea_level = y


## Diagnostic/refactor mode. When true, non-final debug modes can stay visible
## above sea level so Ocean Lab can prove render-order behavior. Final
## above-water waterline/refraction is owned by WaterlineCompositorEffect.
func set_active_above_water(value: bool) -> void:
	active_above_water = value


func set_debug_mode(mode: int) -> void:
	_debug_mode = clampi(mode, 0, 3)
	if _material != null:
		_material.set_shader_parameter("debug_mode", _debug_mode)


func set_wobble_enabled(value: bool) -> void:
	wobble_enabled = value
	if _material != null:
		_material.set_shader_parameter("wobble_enabled", wobble_enabled)


func set_render_layers(layer_mask: int) -> void:
	if _mesh_instance != null:
		_mesh_instance.layers = layer_mask


func sync_wave_surface_from_ocean_material(ocean_material: ShaderMaterial) -> void:
	if _material == null:
		return
	if ocean_material == null:
		_material.set_shader_parameter("use_dynamic_water_surface", false)
		return

	_material.set_shader_parameter("use_dynamic_water_surface", true)
	_material.set_shader_parameter("map_scales", ocean_material.get_shader_parameter("map_scales"))
	_material.set_shader_parameter("wave_scale", ocean_material.get_shader_parameter("wave_scale"))
	_material.set_shader_parameter("ocean_time", ocean_material.get_shader_parameter("ocean_time"))
	_material.set_shader_parameter("shore_mask", ocean_material.get_shader_parameter("shore_mask"))
	_material.set_shader_parameter("shore_mask_bounds", ocean_material.get_shader_parameter("shore_mask_bounds"))
	_material.set_shader_parameter("shore_fade_distance", ocean_material.get_shader_parameter("shore_fade_distance"))
	_material.set_shader_parameter("shore_wave_amplitude", ocean_material.get_shader_parameter("shore_wave_amplitude"))
	_material.set_shader_parameter("shore_wave_frequency", ocean_material.get_shader_parameter("shore_wave_frequency"))
	_material.set_shader_parameter("shore_wave_speed", ocean_material.get_shader_parameter("shore_wave_speed"))
	_material.set_shader_parameter("shore_wave_steepness", ocean_material.get_shader_parameter("shore_wave_steepness"))


func sync_wave_surface_from_water_state(state: WaterSurfaceState) -> void:
	if _material == null:
		return
	if state == null:
		_material.set_shader_parameter("use_dynamic_water_surface", false)
		return

	_sea_level = state.sea_level
	_material.set_shader_parameter("use_dynamic_water_surface", true)
	_material.set_shader_parameter("map_scales", state.map_scales)
	_material.set_shader_parameter("wave_scale", state.wave_scale)
	_material.set_shader_parameter("ocean_time", state.ocean_time)
	if state.shore_mask_texture != null:
		_material.set_shader_parameter("shore_mask", state.shore_mask_texture)
	_material.set_shader_parameter("shore_mask_bounds", state.shore_mask_bounds)
	_material.set_shader_parameter("shore_fade_distance", state.shore_fade_distance)
	_material.set_shader_parameter("shore_wave_amplitude", state.shore_wave_amplitude)
	_material.set_shader_parameter("shore_wave_frequency", state.shore_wave_frequency)
	_material.set_shader_parameter("shore_wave_speed", state.shore_wave_speed)
	_material.set_shader_parameter("shore_wave_steepness", state.shore_wave_steepness)
	_material.set_shader_parameter("water_tint", state.absorption_tint)
	_material.set_shader_parameter("absorption_sigma", state.absorption_sigma)
	_material.set_shader_parameter("caustics_strength", state.underwater_caustics_strength)


func sync_optical_constants_from_ocean_manager(ocean_manager: Node) -> void:
	if _material == null or ocean_manager == null:
		return
	if ocean_manager.has_method("get_absorption_tint"):
		var tint: Vector3 = ocean_manager.get_absorption_tint()
		_material.set_shader_parameter("water_tint", tint)
	if ocean_manager.has_method("get_absorption_sigma"):
		var sigma: Vector3 = ocean_manager.get_absorption_sigma()
		_material.set_shader_parameter("absorption_sigma", sigma)
	if ocean_manager.has_method("get_underwater_caustics_strength"):
		var caustics: float = ocean_manager.get_underwater_caustics_strength()
		_material.set_shader_parameter("caustics_strength", caustics)


func _process(_delta: float) -> void:
	if _camera == null or not is_instance_valid(_camera) or not enabled:
		visible = false
		return

	var cam_y: float = _camera.global_position.y
	var submerged: bool = cam_y < _sea_level
	var above_water_diagnostic: bool = active_above_water and _debug_mode != 0
	visible = submerged or above_water_diagnostic
	if not visible:
		return

	# Follow camera position, never rotation. The volume stays axis-aligned
	# with world Y so the slab test in the shader works unambiguously.
	global_position = _camera.global_position
	global_rotation = Vector3.ZERO

	# Per-frame uniforms. Cheap enough to push unconditionally.
	_material.set_shader_parameter("sea_level", _sea_level)
	_material.set_shader_parameter("debug_mode", _debug_mode)
	_material.set_shader_parameter("wobble_enabled", wobble_enabled)
	if _sun != null and is_instance_valid(_sun):
		# Godot DirectionalLight3D shines along -basis.z, so +basis.z is the
		# direction pointing AT the sun in the sky.
		var toward_sun: Vector3 = _sun.global_basis.z
		_material.set_shader_parameter("sun_direction_world", toward_sun)
