## WaterVolume - Volume-based water system for inland water, lakes, rivers, pools
## Uses Area3D for swimming/buoyancy detection
## Supports SSR + cubemap reflections
## Configurable per water type (lake, river, etc.)
@tool
class_name WaterVolume
extends Node3D

const WaterBodyDescriptorScript := preload("res://src/core/water/water_body_descriptor.gd")
const DefaultNormalTexture := preload("res://assets/water/water_normal.png")
const DefaultFoamTexture := preload("res://src/core/water/textures/foam_albedo.png")
const WaterVolumeShader := preload("res://src/core/water/shaders/water_volume.gdshader")
const WATER_DETECT_ENVIRONMENT_LAYER := 1 << 0
const WATER_DETECT_PLAYER_LAYER := 1 << 1
const WATER_DETECT_INTERACTABLE_LAYER := 1 << 2
const DEFAULT_DETECTION_COLLISION_MASK := WATER_DETECT_ENVIRONMENT_LAYER | WATER_DETECT_PLAYER_LAYER | WATER_DETECT_INTERACTABLE_LAYER

## Water volume types
enum WaterType {
	LAKE,      ## Still water body - no flow
	RIVER,     ## Flowing water - has current direction
	POOL,      ## Small contained water - no waves
	OCEAN,     ## Large ocean (use OceanManager instead)
}

## Water configuration
@export_group("Water Type")
@export var water_type: WaterType = WaterType.LAKE

@export_group("Dimensions")
@export var size: Vector3 = Vector3(20.0, 5.0, 20.0):
	set(value):
		size = value
		_update_volume()

@export var water_surface_height: float = 0.0:
	set(value):
		water_surface_height = value
		_update_volume()

@export_group("Visual Settings")
@export var water_color: Color = Color(0.02, 0.15, 0.22, 1.0):
	set(value):
		water_color = value
		_update_material()

@export var clarity: float = 0.5:
	set(value):
		clarity = clamp(value, 0.0, 1.0)
		_update_material()

@export var roughness: float = 0.1:
	set(value):
		roughness = clamp(value, 0.0, 1.0)
		_update_material()

@export var refraction_strength: float = 0.05:
	set(value):
		refraction_strength = clamp(value, 0.0, 0.3)
		_update_material()

@export var depth_fade_distance: float = 5.0:
	set(value):
		depth_fade_distance = maxf(value, 0.0)
		_update_material()

@export var water_normal_uv_scale: float = 0.18:
	set(value):
		water_normal_uv_scale = maxf(value, 0.001)
		_update_material()

@export_group("Reflection Settings")
@export var use_ssr: bool = true:
	set(value):
		use_ssr = value
		_update_material()

@export var reflection_cubemap: Environment = null:
	set(value):
		reflection_cubemap = value
		_update_material()

@export_group("Wave Settings")
@export var enable_waves: bool = true:
	set(value):
		enable_waves = value
		_update_material()

@export var wave_scale: float = 0.3:
	set(value):
		wave_scale = value
		_update_material()

@export var wave_speed: float = 1.0:
	set(value):
		wave_speed = value
		_update_material()

@export_group("River Settings (only for RIVER type)")
@export var flow_direction: Vector2 = Vector2(1.0, 0.0):
	set(value):
		flow_direction = value.normalized()
		_update_material()

@export var flow_speed: float = 2.0:
	set(value):
		flow_speed = value
		_update_material()

@export_group("Swimming & Buoyancy")
@export var register_with_water_registry: bool = true
@export var enable_swimming: bool = true
@export var enable_buoyancy: bool = true
@export_flags_3d_physics var detection_collision_mask: int = DEFAULT_DETECTION_COLLISION_MASK:
	set(value):
		detection_collision_mask = value
		_apply_area_collision_mask()
@export var swim_speed_multiplier: float = 0.6  ## How much swimming slows movement
@export var current_strength: float = 1.0  ## For rivers - how strong the current pushes
@export_enum("Off", "Flow Direction", "Speed", "Depth Edge", "Coverage", "Interaction Ripples") var debug_display_mode: int = 0:
	set(value):
		debug_display_mode = clampi(value, 0, 5)
		_update_material()

# Internal nodes
var _area: Area3D = null
var _collision_shape: CollisionShape3D = null
var _water_mesh: MeshInstance3D = null
var _material: ShaderMaterial = null
var _shader: Shader = null
var _body_descriptor: RefCounted = null
var _water_interaction_fallback_texture: Texture2D = null
var _water_body_atlas_fallback_texture: Texture2D = null
var _registered_with_water_registry: bool = false

# State
var _time: float = 0.0
var _bodies_in_water: Array[Node3D] = []

# Signals
signal body_entered_water(body: Node3D)
signal body_exited_water(body: Node3D)
signal body_swimming(body: Node3D)


func _init() -> void:
	name = "WaterVolume"


func _ready() -> void:
	_setup_nodes()
	_create_shader()
	_create_material()
	_create_water_mesh()
	_update_volume()

	if not Engine.is_editor_hint():
		_area.body_entered.connect(_on_body_entered)
		_area.body_exited.connect(_on_body_exited)
		if register_with_water_registry:
			_register_with_water_registry()
		_register_water_interaction_renderer()


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	_unregister_water_interaction_renderer()
	_unregister_from_water_registry()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	_time += delta * wave_speed
	if _material:
		_material.set_shader_parameter("time", _time)
		_material.set_shader_parameter("water_surface_time", _time)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	# Update bodies in water
	for body in _bodies_in_water:
		if is_instance_valid(body):
			_process_body_in_water(body, delta)


func _setup_nodes() -> void:
	# Create Area3D for detection
	_area = Area3D.new()
	_area.name = "WaterArea"
	_area.monitoring = true
	_area.monitorable = false
	_area.collision_layer = 0
	_area.collision_mask = detection_collision_mask
	add_child(_area)
	_area.owner = self

	# Create collision shape (box)
	_collision_shape = CollisionShape3D.new()
	_collision_shape.name = "CollisionShape"
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	_collision_shape.shape = box_shape
	_area.add_child(_collision_shape)
	_collision_shape.owner = self

	# Create water mesh
	_water_mesh = MeshInstance3D.new()
	_water_mesh.name = "WaterSurface"
	add_child(_water_mesh)
	_water_mesh.owner = self


func _create_shader() -> void:
	_shader = WaterVolumeShader


func _create_material() -> void:
	_material = ShaderMaterial.new()
	_material.shader = _shader
	_update_material()


func _create_water_mesh() -> void:
	# Create a quad mesh for the water surface
	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(size.x, size.z)
	plane_mesh.subdivide_width = 32
	plane_mesh.subdivide_depth = 32

	_water_mesh.mesh = plane_mesh
	_water_mesh.material_override = _material
	_water_mesh.position.y = water_surface_height


func _update_volume() -> void:
	if not is_inside_tree():
		return

	# Update collision shape
	if _collision_shape and _collision_shape.shape:
		(_collision_shape.shape as BoxShape3D).size = size
		_collision_shape.position.y = water_surface_height

	# Update water mesh
	if _water_mesh and _water_mesh.mesh:
		(_water_mesh.mesh as PlaneMesh).size = Vector2(size.x, size.z)
		_water_mesh.position.y = water_surface_height
	_update_body_descriptor()


func _apply_area_collision_mask() -> void:
	if _area != null:
		_area.collision_mask = detection_collision_mask


func _update_material() -> void:
	if not _material:
		return

	_material.set_shader_parameter("water_color", water_color)
	_material.set_shader_parameter("roughness", roughness)
	_material.set_shader_parameter("clarity", clarity)
	_material.set_shader_parameter("refraction_strength", refraction_strength)
	_material.set_shader_parameter("water_surface_shallow_color", Vector3(water_color.r, water_color.g, water_color.b))
	_material.set_shader_parameter("water_surface_deep_color", Vector3(water_color.r * 0.42, water_color.g * 0.58, water_color.b * 0.72))
	_material.set_shader_parameter("water_surface_medium_color", Vector3(water_color.r * 0.65, water_color.g * 0.72, water_color.b * 0.78))
	_material.set_shader_parameter("water_surface_foam_color", Vector3(0.82, 0.90, 0.88))
	_material.set_shader_parameter("water_surface_visibility_distance_m", maxf(depth_fade_distance * 7.0, 12.0))
	_material.set_shader_parameter("water_surface_absorption_density", 0.24)
	_material.set_shader_parameter("water_surface_refraction_strength", refraction_strength)
	_material.set_shader_parameter("water_surface_roughness", roughness)
	_material.set_shader_parameter("water_surface_clarity", clarity)
	_material.set_shader_parameter("water_surface_normal_strength", 0.65)
	_material.set_shader_parameter("water_surface_normal_uv_scale", water_normal_uv_scale)
	_material.set_shader_parameter("water_surface_foam_intensity", 0.45)
	_material.set_shader_parameter("water_surface_foam_texture", DefaultFoamTexture)
	_material.set_shader_parameter("enable_waves", enable_waves and water_type != WaterType.POOL)
	_material.set_shader_parameter("wave_scale", wave_scale)
	_material.set_shader_parameter("flow_direction", flow_direction)
	_material.set_shader_parameter("flow_speed", flow_speed if water_type == WaterType.RIVER else 0.0)
	_material.set_shader_parameter("flow_visual_strength", 0.42 if water_type == WaterType.RIVER else 0.0)
	_material.set_shader_parameter("debug_display_mode", debug_display_mode)
	_material.set_shader_parameter("water_surface_normal_texture", DefaultNormalTexture)
	_sync_water_interaction_material()
	_update_body_descriptor()


func _sync_water_interaction_material() -> void:
	if _material == null:
		return
	if not is_instance_valid(OceanManager):
		sync_water_interaction_texture(null, Vector4.ZERO, false, false)
		return
	var texture := OceanManager.get_water_interaction_texture()
	var stats: Dictionary = OceanManager.get_water_interaction_stats()
	var active := bool(stats.get("enabled", false)) and texture != null
	sync_water_interaction_texture(
		texture,
		OceanManager.get_water_interaction_bounds(),
		active,
		OceanManager.is_water_interaction_debug_enabled(),
		OceanManager.get_water_body_atlas_texture(),
		OceanManager.get_water_body_atlas_bounds(),
		OceanManager.has_water_body_atlas()
	)


func sync_water_interaction_texture(
	texture: Texture2D,
	bounds: Vector4,
	enabled: bool,
	debug_enabled: bool = false,
	body_atlas_texture: Texture2D = null,
	body_atlas_bounds: Vector4 = Vector4.ZERO,
	body_atlas_available: bool = false,
	_dynamic_flow_texture: Texture2D = null,
	_dynamic_flow_bounds: Vector4 = Vector4.ZERO,
	_dynamic_flow_enabled: bool = false
) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("water_interaction_map", texture if texture != null else _get_water_interaction_fallback_texture())
	_material.set_shader_parameter("water_interaction_bounds", bounds)
	_material.set_shader_parameter("water_interaction_enabled", enabled and texture != null)
	_material.set_shader_parameter("water_interaction_debug_enabled", debug_enabled)
	_material.set_shader_parameter("water_body_atlas_map", body_atlas_texture if body_atlas_texture != null else _get_water_body_atlas_fallback_texture())
	_material.set_shader_parameter("water_body_atlas_bounds", body_atlas_bounds)
	_material.set_shader_parameter("water_body_atlas_available", body_atlas_available and body_atlas_texture != null)
	_material.set_shader_parameter("water_interaction_surface_height", global_position.y + water_surface_height)
	_material.set_shader_parameter("water_interaction_body_filter_mode", 1)


func _get_water_interaction_fallback_texture() -> Texture2D:
	if _water_interaction_fallback_texture != null:
		return _water_interaction_fallback_texture
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, Color(0.0, 0.0, 0.0, 0.0))
	_water_interaction_fallback_texture = ImageTexture.create_from_image(img)
	return _water_interaction_fallback_texture


func _get_water_body_atlas_fallback_texture() -> Texture2D:
	if _water_body_atlas_fallback_texture != null:
		return _water_body_atlas_fallback_texture
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, Color(0.0, 0.0, 0.0, 0.0))
	_water_body_atlas_fallback_texture = ImageTexture.create_from_image(img)
	return _water_body_atlas_fallback_texture


func get_water_body_descriptor() -> RefCounted:
	if _body_descriptor == null:
		_body_descriptor = WaterBodyDescriptorScript.new()
		_body_descriptor.body_id = _make_water_body_id()
		_body_descriptor.coverage_query = Callable(self, "sample_water_coverage")
		_body_descriptor.height_query = Callable(self, "sample_water_height")
		_body_descriptor.normal_query = Callable(self, "sample_water_normal")
		_body_descriptor.gradient_query = Callable(self, "sample_water_gradient")
		_body_descriptor.velocity_query = Callable(self, "sample_water_velocity")
		_body_descriptor.water_body_id_query = Callable(self, "sample_water_body_id")
	_update_body_descriptor()
	return _body_descriptor


func sample_water_coverage(pos: Vector3) -> float:
	var local_pos := to_local(pos)
	var half_size := size * 0.5
	if abs(local_pos.x) > half_size.x or abs(local_pos.z) > half_size.z:
		return 0.0
	var bottom := water_surface_height - size.y
	return 1.0 if local_pos.y >= bottom else 0.0


func sample_water_height(pos: Vector3) -> float:
	return global_position.y + water_surface_height if sample_water_coverage(pos) > 0.0 else -INF


func sample_water_normal(_pos: Vector3) -> Vector3:
	return Vector3.UP


func sample_water_gradient(_pos: Vector3) -> Vector2:
	return Vector2.ZERO


func sample_water_velocity(pos: Vector3) -> Vector3:
	if water_type != WaterType.RIVER or sample_water_coverage(pos) <= 0.0:
		return Vector3.ZERO
	var dir := flow_direction.normalized()
	return Vector3(dir.x, 0.0, dir.y) * flow_speed * current_strength


func sample_water_body_id(pos: Vector3) -> StringName:
	return _body_descriptor.body_id if _body_descriptor != null and sample_water_coverage(pos) > 0.0 else WaterSurfaceState.WATER_BODY_NONE


func _register_with_water_registry() -> void:
	if _registered_with_water_registry:
		return
	if not register_with_water_registry:
		return
	if not is_instance_valid(OceanManager):
		return
	if OceanManager.has_method("register_water_body"):
		OceanManager.call("register_water_body", get_water_body_descriptor())
		_registered_with_water_registry = true


func _register_water_interaction_renderer() -> void:
	if is_instance_valid(OceanManager) and OceanManager.has_method("register_water_interaction_renderer"):
		OceanManager.call("register_water_interaction_renderer", self)


func _unregister_water_interaction_renderer() -> void:
	if is_instance_valid(OceanManager) and OceanManager.has_method("unregister_water_interaction_renderer"):
		OceanManager.call("unregister_water_interaction_renderer", self)


func _unregister_from_water_registry() -> void:
	if not _registered_with_water_registry:
		return
	if _body_descriptor == null or not is_instance_valid(OceanManager):
		return
	if OceanManager.has_method("unregister_water_body"):
		OceanManager.call("unregister_water_body", _body_descriptor)
	_registered_with_water_registry = false


func _update_body_descriptor() -> void:
	if _body_descriptor == null:
		return
	_body_descriptor.body_type = _water_type_to_body_type()
	_body_descriptor.priority = _water_body_priority()
	_body_descriptor.surface_height = global_position.y + water_surface_height
	_body_descriptor.depth = size.y
	_body_descriptor.flow_direction = flow_direction
	_body_descriptor.flow_speed = flow_speed * current_strength if water_type == WaterType.RIVER else 0.0
	var global_center := global_position + Vector3(0.0, water_surface_height - size.y * 0.5, 0.0)
	_body_descriptor.bounds = AABB(global_center - size * 0.5, size)
	_body_descriptor.bounds_valid = true
	_body_descriptor.metadata["render_only"] = not register_with_water_registry


func _water_type_to_body_type() -> StringName:
	match water_type:
		WaterType.LAKE:
			return &"lake"
		WaterType.RIVER:
			return &"river"
		WaterType.POOL:
			return &"pool"
		WaterType.OCEAN:
			return &"ocean"
		_:
			return &"unknown"


func _water_body_priority() -> int:
	match water_type:
		WaterType.RIVER:
			return 220
		WaterType.LAKE, WaterType.POOL:
			return 200
		WaterType.OCEAN:
			return 10
		_:
			return 100


func _make_water_body_id() -> StringName:
	if is_inside_tree():
		return StringName(str(get_path()))
	return StringName("%s_%d" % [name, get_instance_id()])


func _on_body_entered(body: Node3D) -> void:
	if body is CharacterBody3D or body is RigidBody3D:
		_bodies_in_water.append(body)
		body_entered_water.emit(body)
		Log.debug("water", "WaterVolume: Body entered water: %s" % body.name)


func _on_body_exited(body: Node3D) -> void:
	var idx := _bodies_in_water.find(body)
	if idx >= 0:
		_bodies_in_water.remove_at(idx)
		body_exited_water.emit(body)
		Log.debug("water", "WaterVolume: Body exited water: %s" % body.name)


func _process_body_in_water(body: Node3D, delta: float) -> void:
	if sample_water_coverage(body.global_position) <= 0.0:
		return

	# Check if body is actually swimming (head underwater)
	var body_pos := body.global_position
	var water_level := global_position.y + water_surface_height
	var is_swimming := body_pos.y < water_level

	if is_swimming and enable_swimming:
		body_swimming.emit(body)

		# Apply river current if this is a river
		if water_type == WaterType.RIVER and body is CharacterBody3D:
			var current := Vector3(flow_direction.x, 0.0, flow_direction.y) * flow_speed * current_strength
			# You can apply current force here if you have access to the body's movement system

	# Apply buoyancy if enabled
	if enable_buoyancy and body is RigidBody3D and not body is BuoyancyBody3D:
		var submersion := _calculate_submersion(body, water_level)
		if submersion > 0.0:
			_apply_buoyancy_force(body, submersion)


func _calculate_submersion(body: RigidBody3D, water_level: float) -> float:
	# Simple submersion calculation - can be improved with actual collision shapes
	var body_bottom := body.global_position.y - 1.0  # Approximate
	var body_top := body.global_position.y + 1.0

	if body_top < water_level:
		return 1.0  # Fully submerged
	elif body_bottom < water_level:
		return (water_level - body_bottom) / (body_top - body_bottom)
	else:
		return 0.0


func _apply_buoyancy_force(body: RigidBody3D, submersion: float) -> void:
	# Simple buoyancy force - upward force proportional to submersion
	var buoyancy_force := Vector3.UP * submersion * 9.81 * 10.0  # 10 kg approximate
	body.apply_central_force(buoyancy_force)

	# Apply drag
	var drag := -body.linear_velocity * 0.5 * submersion
	body.apply_central_force(drag)


## Check if a global position is in this water volume
func is_position_in_water(pos: Vector3) -> bool:
	var local_pos := to_local(pos)
	var half_size := size * 0.5
	return (
		abs(local_pos.x) <= half_size.x and
		abs(local_pos.y) <= half_size.y and
		abs(local_pos.z) <= half_size.z and
		local_pos.y <= water_surface_height
	)


## Get water height at a horizontal position (for swimming/buoyancy)
func get_water_height(world_pos: Vector3) -> float:
	if sample_water_coverage(world_pos) > 0.0:
		return global_position.y + water_surface_height
	return -1000.0  # Not in water


## Get bodies currently in water
func get_bodies_in_water() -> Array[Node3D]:
	return _bodies_in_water.duplicate()


## Check if a specific body is in water
func is_body_in_water(body: Node3D) -> bool:
	return body in _bodies_in_water
