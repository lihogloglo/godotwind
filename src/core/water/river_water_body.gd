## RiverWaterBody3D - curved flowing water body.
##
## Source-owned river rendering/query node. It uses generic Godot-space curve
## data, registers a WaterBodyDescriptor with OceanManager, and keeps authored
## river rendering separate from simple box/polygon water volumes.
@tool
class_name RiverWaterBody3D
extends Node3D

const NativeBridgeScript := preload("res://src/core/native_bridge.gd")
const WaterBodyDescriptorScript := preload("res://src/core/water/water_body_descriptor.gd")
const RiverShader := preload("res://src/core/water/shaders/river_surface.gdshader")
const DefaultNormalTexture := preload("res://assets/water/water_normal.png")
const DefaultFoamTexture := preload("res://src/core/water/textures/foam_albedo.png")
const FLOWMAP_MAX_SPEED_MPS := 6.0

@export var curve: Curve3D = null:
	set(value):
		curve = value
		_request_rebuild()

## Full river width at each curve control point, in meters.
@export var point_widths: Array[float] = [8.0, 8.0]:
	set(value):
		point_widths = value
		_request_rebuild()

@export_range(0.0, 10.0, 0.01, "or_greater") var surface_height: float = 0.0:
	set(value):
		surface_height = value
		_request_rebuild()

@export_range(0.1, 100.0, 0.1, "or_greater") var depth: float = 3.0:
	set(value):
		depth = value
		_update_body_descriptor()

@export_range(0.0, 10.0, 0.01, "or_greater") var flow_speed: float = 1.8:
	set(value):
		flow_speed = value
		_update_material()
		_update_body_descriptor()

@export_range(0.25, 10.0, 0.25, "or_greater") var length_step_m: float = 2.0:
	set(value):
		length_step_m = value
		_request_rebuild()

@export_range(1, 16, 1, "or_greater") var width_subdivisions: int = 6:
	set(value):
		width_subdivisions = value
		_request_rebuild()

@export_range(0.05, 4.0, 0.05, "or_greater") var tangent_smoothness: float = 1.0:
	set(value):
		tangent_smoothness = value
		_request_rebuild()

@export_range(0.01, 4.0, 0.01, "or_greater") var edge_fade_distance: float = 0.45:
	set(value):
		edge_fade_distance = value
		_update_material()

@export var water_color: Color = Color(0.035, 0.18, 0.22, 1.0):
	set(value):
		water_color = value
		_update_material()

@export var medium_color: Color = Color(0.02, 0.04, 0.05, 1.0):
	set(value):
		medium_color = value
		_update_material()

@export var flowmap_enabled: bool = false:
	set(value):
		flowmap_enabled = value
		_update_material()
		_update_body_descriptor()

@export var flowmap_image: Image = null:
	set(value):
		flowmap_image = value
		_flowmap_image_texture = null
		_update_material()
		_update_body_descriptor()

@export var flowmap_texture: Texture2D = null:
	set(value):
		flowmap_texture = value
		_update_material()
		_update_body_descriptor()

## World-space X/Z bounds covered by flowmap_image/flowmap_texture.
@export var flowmap_region_bounds: AABB = AABB():
	set(value):
		flowmap_region_bounds = value
		_update_material()
		_update_body_descriptor()

@export var register_with_water_registry: bool = true:
	set(value):
		if register_with_water_registry == value:
			return
		register_with_water_registry = value
		if Engine.is_editor_hint() or not is_inside_tree():
			return
		if register_with_water_registry:
			_register_with_water_registry()
		else:
			_unregister_from_water_registry()

@export_enum("Off", "Flow Direction", "Speed", "Coverage", "Bank Edge", "Interaction Ripples", "Dynamic Flow", "Flow Mismatch", "Mesh UV", "Flow Basis Gradient", "Oriented UV", "Base Flow", "Flowmap Flow") var debug_display_mode: int = 0:
	set(value):
		debug_display_mode = clampi(value, 0, 12)
		_update_material()

@export var debug_freeze_time: bool = false:
	set(value):
		debug_freeze_time = value
		_push_debug_time_uniforms()

var _mesh_instance: MeshInstance3D = null
var _material: ShaderMaterial = null
var _body_descriptor: RefCounted = null
var _native_bridge: NativeBridge = null
var _mesh_builder: RefCounted = null
var _rebuild_pending: bool = false
var _local_bounds: AABB = AABB()
var _local_bounds_valid: bool = false
var _sample_cache: Array[Dictionary] = []
var _water_interaction_fallback_texture: Texture2D = null
var _water_dynamic_flow_fallback_texture: Texture2D = null
var _water_body_atlas_fallback_texture: Texture2D = null
var _flowmap_image_texture: Texture2D = null
var _flowmap_fallback_texture: Texture2D = null
var _registered_with_water_registry: bool = false


func _ready() -> void:
	_ensure_curve()
	_ensure_nodes()
	_ensure_material()
	_rebuild_surface()
	if not Engine.is_editor_hint():
		if register_with_water_registry:
			_register_with_water_registry()
		_register_water_interaction_renderer()


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	_unregister_water_interaction_renderer()
	_unregister_from_water_registry()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_push_debug_time_uniforms()


func set_debug_freeze_time(enabled: bool) -> void:
	debug_freeze_time = enabled


func _push_debug_time_uniforms() -> void:
	if _material == null:
		return
	var t := 0.0 if debug_freeze_time else Time.get_ticks_msec() / 1000.0
	_material.set_shader_parameter(&"river_time", t)
	_material.set_shader_parameter(&"water_surface_time", t)


func get_water_body_descriptor() -> RefCounted:
	if _body_descriptor == null:
		_body_descriptor = WaterBodyDescriptorScript.new()
		_body_descriptor.body_id = _make_water_body_id()
		_body_descriptor.body_type = WaterBodyDescriptor.TYPE_RIVER
		_body_descriptor.coverage_query = Callable(self, "sample_water_coverage")
		_body_descriptor.height_query = Callable(self, "sample_water_height")
		_body_descriptor.normal_query = Callable(self, "sample_water_normal")
		_body_descriptor.gradient_query = Callable(self, "sample_water_gradient")
		_body_descriptor.velocity_query = Callable(self, "sample_water_velocity")
		_body_descriptor.water_body_id_query = Callable(self, "sample_water_body_id")
	_update_body_descriptor()
	return _body_descriptor


func sample_water_coverage(world_pos: Vector3) -> float:
	var sample := _closest_sample(world_pos)
	if sample.is_empty():
		return 0.0
	var local_pos := to_local(world_pos)
	var water_y := float(sample.get("center_y", 0.0)) + surface_height
	if local_pos.y < water_y - depth:
		return 0.0
	var lateral := float(sample.get("lateral", INF))
	var half_width := maxf(float(sample.get("width", 0.0)) * 0.5, 0.001)
	if lateral > half_width:
		return 0.0
	var edge_band := maxf(edge_fade_distance, 0.001)
	return clampf((half_width - lateral) / edge_band, 0.0, 1.0)


func sample_water_height(world_pos: Vector3) -> float:
	var sample := _closest_sample(world_pos)
	if sample.is_empty():
		return -INF
	var local_pos := to_local(world_pos)
	var lateral := float(sample.get("lateral", INF))
	var half_width := maxf(float(sample.get("width", 0.0)) * 0.5, 0.001)
	if lateral > half_width or local_pos.y < float(sample.get("center_y", 0.0)) + surface_height - depth:
		return -INF
	var local_height := float(sample.get("center_y", 0.0)) + surface_height
	return (global_transform * Vector3(local_pos.x, local_height, local_pos.z)).y


func sample_water_normal(_world_pos: Vector3) -> Vector3:
	return global_transform.basis.y.normalized()


func sample_water_gradient(_world_pos: Vector3) -> Vector2:
	return Vector2.ZERO


func sample_water_velocity(world_pos: Vector3) -> Vector3:
	if sample_water_coverage(world_pos) <= 0.0:
		return Vector3.ZERO
	var flowmap_sample := _sample_flowmap(world_pos)
	if not flowmap_sample.is_empty() and float(flowmap_sample.get("coverage", 0.0)) > 0.0:
		var flowmap_dir: Vector2 = flowmap_sample.get("direction", Vector2.ZERO)
		if flowmap_dir.length_squared() > 0.0001:
			var speed := float(flowmap_sample.get("speed", flow_speed))
			flowmap_dir = flowmap_dir.normalized()
			return Vector3(flowmap_dir.x, 0.0, flowmap_dir.y) * speed
	var sample := _closest_sample(world_pos)
	if sample.is_empty():
		return Vector3.ZERO
	var local_dir: Vector3 = sample.get("tangent", Vector3.FORWARD)
	var global_dir := (global_transform.basis * local_dir).normalized()
	return Vector3(global_dir.x, 0.0, global_dir.z).normalized() * flow_speed


func sample_water_body_id(world_pos: Vector3) -> StringName:
	if _body_descriptor != null and sample_water_coverage(world_pos) > 0.0:
		return _body_descriptor.body_id
	return WaterSurfaceState.WATER_BODY_NONE


func _request_rebuild() -> void:
	if not is_inside_tree():
		return
	if _rebuild_pending:
		return
	_rebuild_pending = true
	call_deferred("_rebuild_surface")


func _ensure_curve() -> void:
	if curve != null:
		return
	curve = Curve3D.new()
	curve.add_point(Vector3(0.0, 0.0, -32.0))
	curve.add_point(Vector3(0.0, 0.0, 32.0))


func _ensure_nodes() -> void:
	if _mesh_instance != null:
		return
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "RiverSurface"
	add_child(_mesh_instance)
	if Engine.is_editor_hint():
		_mesh_instance.owner = get_tree().edited_scene_root


func _ensure_material() -> void:
	if _material != null:
		return
	_material = ShaderMaterial.new()
	_material.shader = RiverShader
	if _mesh_instance != null:
		_mesh_instance.material_override = _material
	_update_material()


func _ensure_mesh_builder() -> RefCounted:
	if _mesh_builder != null:
		return _mesh_builder
	if _native_bridge == null:
		_native_bridge = NativeBridgeScript.new()
	if _native_bridge != null and _native_bridge.has_method("create_river_mesh_builder"):
		_mesh_builder = _native_bridge.create_river_mesh_builder()
	return _mesh_builder


func _rebuild_surface() -> void:
	_rebuild_pending = false
	_ensure_curve()
	_ensure_nodes()
	_ensure_material()
	_rebuild_sample_cache()

	var mesh: Mesh = null
	var builder := _ensure_mesh_builder()
	if builder != null and builder.has_method("BuildCurveRiverMesh"):
		var length := maxf(curve.get_baked_length(), 0.001)
		var length_divisions := maxi(1, ceili(length / maxf(length_step_m, 0.25)))
		var result: Dictionary = builder.call(
			"BuildCurveRiverMesh",
			curve,
			point_widths,
			length_divisions,
			maxi(1, width_subdivisions),
			maxf(tangent_smoothness, 0.05)
		)
		mesh = result.get("mesh") as Mesh
		var bounds_variant: Variant = result.get("bounds", AABB())
		if bounds_variant is AABB:
			_local_bounds = bounds_variant
			_local_bounds_valid = true
	if mesh == null:
		mesh = _build_fallback_mesh()

	_mesh_instance.mesh = mesh
	_mesh_instance.position.y = surface_height
	_update_material()
	_update_body_descriptor()


func _build_fallback_mesh() -> Mesh:
	var plane := PlaneMesh.new()
	var length := maxf(curve.get_baked_length(), 1.0)
	plane.size = Vector2(_width_at(0.5), length)
	plane.subdivide_depth = maxi(1, ceili(length / maxf(length_step_m, 0.25)))
	plane.subdivide_width = maxi(1, width_subdivisions)
	_local_bounds = AABB(Vector3(-plane.size.x * 0.5, 0.0, -plane.size.y * 0.5), Vector3(plane.size.x, 0.0, plane.size.y))
	_local_bounds_valid = true
	return plane


func _rebuild_sample_cache() -> void:
	_sample_cache.clear()
	if curve == null or curve.point_count < 2:
		return
	var length := maxf(curve.get_baked_length(), 0.001)
	var steps := maxi(2, ceili(length / maxf(length_step_m, 0.5)))
	for i in range(steps + 1):
		var distance := minf(length, float(i) / float(steps) * length)
		var center := curve.sample_baked(distance, true)
		var backward := curve.sample_baked(maxf(distance - length_step_m, 0.0), true)
		var forward := curve.sample_baked(minf(distance + length_step_m, length), true)
		var tangent := forward - backward
		if tangent.length_squared() < 0.0001:
			tangent = Vector3.FORWARD
		tangent = tangent.normalized()
		var right := tangent.cross(Vector3.UP)
		if right.length_squared() < 0.0001:
			right = Vector3.RIGHT
		right = right.normalized()
		_sample_cache.append({
			"center": center,
			"center_y": center.y,
			"tangent": tangent,
			"right": right,
			"width": _width_at(float(i) / float(steps)),
		})


func _closest_sample(world_pos: Vector3) -> Dictionary:
	if _sample_cache.is_empty():
		_rebuild_sample_cache()
	if _sample_cache.size() < 2:
		return {}
	var local_pos := to_local(world_pos)
	var local_xz := Vector2(local_pos.x, local_pos.z)
	var best: Dictionary = {}
	var best_dist_sq := INF
	for i in range(_sample_cache.size() - 1):
		var a: Dictionary = _sample_cache[i]
		var b: Dictionary = _sample_cache[i + 1]
		var a_center: Vector3 = a.get("center", Vector3.ZERO)
		var b_center: Vector3 = b.get("center", Vector3.ZERO)
		var a_xz := Vector2(a_center.x, a_center.z)
		var b_xz := Vector2(b_center.x, b_center.z)
		var segment := b_xz - a_xz
		var segment_len_sq := segment.length_squared()
		if segment_len_sq <= 0.0001:
			continue
		var t := (local_xz - a_xz).dot(segment) / segment_len_sq
		if t < 0.0 or t > 1.0:
			continue
		var closest_xz := a_xz + segment * t
		var delta := local_xz - closest_xz
		var dist_sq := delta.length_squared()
		if dist_sq >= best_dist_sq:
			continue
		var tangent := Vector3(segment.x, 0.0, segment.y)
		if tangent.length_squared() < 0.0001:
			tangent = a.get("tangent", Vector3.FORWARD)
		tangent = tangent.normalized()
		var center_y := lerpf(float(a.get("center_y", 0.0)), float(b.get("center_y", 0.0)), t)
		best_dist_sq = dist_sq
		best = {
			"center": Vector3(closest_xz.x, center_y, closest_xz.y),
			"center_y": center_y,
			"tangent": tangent,
			"width": lerpf(float(a.get("width", 0.0)), float(b.get("width", 0.0)), t),
			"lateral": sqrt(dist_sq),
		}
	return best


func _width_at(t: float) -> float:
	if point_widths.is_empty():
		return 8.0
	if point_widths.size() == 1:
		return maxf(point_widths[0], 0.1)
	var scaled := clampf(t, 0.0, 1.0) * float(point_widths.size() - 1)
	var index := mini(point_widths.size() - 2, int(floorf(scaled)))
	var local_t := scaled - float(index)
	return maxf(lerpf(point_widths[index], point_widths[index + 1], local_t), 0.1)


func _update_material() -> void:
	if _material == null:
		return
	_material.set_shader_parameter(&"water_color", water_color)
	_material.set_shader_parameter(&"medium_color", Vector3(medium_color.r, medium_color.g, medium_color.b))
	_material.set_shader_parameter(&"flow_speed", flow_speed)
	_material.set_shader_parameter(&"flowmap_max_speed_mps", FLOWMAP_MAX_SPEED_MPS)
	_material.set_shader_parameter(&"edge_fade_distance", edge_fade_distance)
	_material.set_shader_parameter(&"water_surface_shallow_color", Vector3(water_color.r, water_color.g, water_color.b))
	_material.set_shader_parameter(&"water_surface_deep_color", Vector3(medium_color.r * 0.75, medium_color.g * 0.75, medium_color.b * 0.75))
	_material.set_shader_parameter(&"water_surface_medium_color", Vector3(medium_color.r, medium_color.g, medium_color.b))
	_material.set_shader_parameter(&"water_surface_foam_color", Vector3(0.82, 0.90, 0.88))
	_material.set_shader_parameter(&"water_surface_visibility_distance_m", 34.0)
	_material.set_shader_parameter(&"water_surface_absorption_density", 0.24)
	_material.set_shader_parameter(&"water_surface_refraction_strength", 0.065)
	_material.set_shader_parameter(&"water_surface_roughness", 0.065)
	_material.set_shader_parameter(&"water_surface_clarity", 0.70)
	_material.set_shader_parameter(&"water_surface_normal_strength", 0.72)
	_material.set_shader_parameter(&"water_surface_normal_uv_scale", 0.095)
	_material.set_shader_parameter(&"water_surface_foam_intensity", 0.70)
	_material.set_shader_parameter(&"water_interaction_height_strength", 0.035)
	_material.set_shader_parameter(&"water_interaction_normal_strength", 3.1)
	_material.set_shader_parameter(&"water_interaction_foam_strength", 0.42)
	_material.set_shader_parameter(&"normal_bump_texture", DefaultNormalTexture)
	_material.set_shader_parameter(&"foam_texture", DefaultFoamTexture)
	_material.set_shader_parameter(&"water_surface_normal_texture", DefaultNormalTexture)
	_material.set_shader_parameter(&"water_surface_foam_texture", DefaultFoamTexture)
	_material.set_shader_parameter(&"flowmap_texture", _get_active_flowmap_texture() if _is_flowmap_active() else _get_flowmap_fallback_texture())
	_material.set_shader_parameter(&"flowmap_region_bounds", _flowmap_bounds_uniform())
	_material.set_shader_parameter(&"flowmap_enabled", _is_flowmap_active())
	_material.set_shader_parameter(&"debug_display_mode", debug_display_mode)
	_sync_water_interaction_material()


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
		OceanManager.has_water_body_atlas(),
		OceanManager.get_water_dynamic_flow_texture() if OceanManager.has_method("get_water_dynamic_flow_texture") else null,
		OceanManager.get_water_interaction_bounds(),
		active and OceanManager.has_method("get_water_dynamic_flow_texture")
	)


func sync_water_interaction_texture(
	texture: Texture2D,
	bounds: Vector4,
	enabled: bool,
	debug_enabled: bool = false,
	body_atlas_texture: Texture2D = null,
	body_atlas_bounds: Vector4 = Vector4.ZERO,
	body_atlas_available: bool = false,
	dynamic_flow_texture: Texture2D = null,
	dynamic_flow_bounds: Vector4 = Vector4.ZERO,
	dynamic_flow_enabled: bool = false
) -> void:
	if _material == null:
		return
	_material.set_shader_parameter(&"water_interaction_map", texture if texture != null else _get_water_interaction_fallback_texture())
	_material.set_shader_parameter(&"water_interaction_bounds", bounds)
	_material.set_shader_parameter(&"water_interaction_enabled", enabled and texture != null)
	_material.set_shader_parameter(&"water_interaction_debug_enabled", debug_enabled)
	_material.set_shader_parameter(&"water_dynamic_flow_map", dynamic_flow_texture if dynamic_flow_texture != null else _get_water_dynamic_flow_fallback_texture())
	_material.set_shader_parameter(&"water_dynamic_flow_enabled", dynamic_flow_enabled and dynamic_flow_texture != null and dynamic_flow_bounds.z > 0.0)
	_material.set_shader_parameter(&"water_body_atlas_map", body_atlas_texture if body_atlas_texture != null else _get_water_body_atlas_fallback_texture())
	_material.set_shader_parameter(&"water_body_atlas_bounds", body_atlas_bounds)
	_material.set_shader_parameter(&"water_body_atlas_available", body_atlas_available and body_atlas_texture != null)
	_material.set_shader_parameter(&"water_interaction_surface_height", global_position.y + surface_height)
	_material.set_shader_parameter(&"water_interaction_body_filter_mode", 1)


func _get_water_dynamic_flow_fallback_texture() -> Texture2D:
	if _water_dynamic_flow_fallback_texture != null:
		return _water_dynamic_flow_fallback_texture
	var img := Image.create(1, 1, false, Image.FORMAT_RGBAF)
	img.set_pixel(0, 0, Color(0.0, 0.0, 0.0, 0.0))
	_water_dynamic_flow_fallback_texture = ImageTexture.create_from_image(img)
	return _water_dynamic_flow_fallback_texture


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


func _get_active_flowmap_texture() -> Texture2D:
	if flowmap_texture != null:
		return flowmap_texture
	if flowmap_image == null:
		return null
	if _flowmap_image_texture == null:
		_flowmap_image_texture = ImageTexture.create_from_image(flowmap_image)
	return _flowmap_image_texture


func _get_flowmap_fallback_texture() -> Texture2D:
	if _flowmap_fallback_texture != null:
		return _flowmap_fallback_texture
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, Color(0.5, 1.0, 0.0, 0.0))
	_flowmap_fallback_texture = ImageTexture.create_from_image(img)
	return _flowmap_fallback_texture


func _is_flowmap_active() -> bool:
	return flowmap_enabled \
		and _get_active_flowmap_texture() != null \
		and flowmap_region_bounds.size.x > 0.001 \
		and flowmap_region_bounds.size.z > 0.001


func _sample_flowmap(world_pos: Vector3) -> Dictionary:
	if not _is_flowmap_active():
		return {}
	var image := flowmap_image
	if image == null and flowmap_texture is ImageTexture:
		image = (flowmap_texture as ImageTexture).get_image()
	if image == null:
		return {}
	var uv := Vector2(
		(world_pos.x - flowmap_region_bounds.position.x) / maxf(flowmap_region_bounds.size.x, 0.001),
		(world_pos.z - flowmap_region_bounds.position.z) / maxf(flowmap_region_bounds.size.z, 0.001)
	)
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return {}
	var c := _sample_flowmap_image_bilinear(image, uv)
	if c.a <= 0.001:
		return {}
	var direction := Vector2(c.r * 2.0 - 1.0, c.g * 2.0 - 1.0)
	var speed := c.b * FLOWMAP_MAX_SPEED_MPS
	if speed <= 0.001 or direction.length_squared() <= 0.000001:
		return {
			"coverage": c.a,
			"direction": Vector2.ZERO,
			"speed": 0.0,
		}
	return {
		"coverage": c.a,
		"direction": direction.normalized(),
		"speed": speed * clampf(direction.length(), 0.0, 1.0),
	}


func _sample_flowmap_image_bilinear(image: Image, uv: Vector2) -> Color:
	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0:
		return Color(0.5, 0.5, 0.0, 0.0)
	var x := clampf(uv.x, 0.0, 1.0) * float(maxi(width - 1, 0))
	var y := clampf(uv.y, 0.0, 1.0) * float(maxi(height - 1, 0))
	var x0 := clampi(floori(x), 0, width - 1)
	var y0 := clampi(floori(y), 0, height - 1)
	var x1 := clampi(x0 + 1, 0, width - 1)
	var y1 := clampi(y0 + 1, 0, height - 1)
	var tx := x - float(x0)
	var ty := y - float(y0)
	var c00 := image.get_pixel(x0, y0)
	var c10 := image.get_pixel(x1, y0)
	var c01 := image.get_pixel(x0, y1)
	var c11 := image.get_pixel(x1, y1)
	return c00.lerp(c10, tx).lerp(c01.lerp(c11, tx), ty)


func _flowmap_bounds_uniform() -> Vector4:
	return Vector4(
		flowmap_region_bounds.position.x,
		flowmap_region_bounds.position.z,
		maxf(flowmap_region_bounds.size.x, 0.001),
		maxf(flowmap_region_bounds.size.z, 0.001)
	)


func _register_with_water_registry() -> void:
	if _registered_with_water_registry:
		return
	if is_instance_valid(OceanManager) and OceanManager.has_method("register_water_body"):
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
	if _body_descriptor != null and is_instance_valid(OceanManager) and OceanManager.has_method("unregister_water_body"):
		OceanManager.call("unregister_water_body", _body_descriptor)
	_registered_with_water_registry = false


func _update_body_descriptor() -> void:
	if _body_descriptor == null:
		return
	_body_descriptor.body_type = WaterBodyDescriptor.TYPE_RIVER
	_body_descriptor.priority = 230
	_body_descriptor.surface_height = global_position.y + surface_height
	_body_descriptor.depth = depth
	_body_descriptor.flow_direction = Vector2(0.0, 1.0)
	_body_descriptor.flow_speed = flow_speed
	_body_descriptor.flowmap_texture = _get_active_flowmap_texture() if _is_flowmap_active() else null
	_body_descriptor.metadata["flowmap_region_bounds"] = flowmap_region_bounds
	_body_descriptor.metadata["flowmap_enabled"] = _is_flowmap_active()
	if _local_bounds_valid:
		var min_local := _local_bounds.position + Vector3(0.0, surface_height - depth, 0.0)
		var max_local := _local_bounds.position + _local_bounds.size + Vector3(0.0, surface_height, 0.0)
		_body_descriptor.bounds = _aabb_from_transformed_box(min_local, max_local)
		_body_descriptor.bounds_valid = true


func _aabb_from_transformed_box(min_local: Vector3, max_local: Vector3) -> AABB:
	var corners: Array[Vector3] = [
		Vector3(min_local.x, min_local.y, min_local.z),
		Vector3(max_local.x, min_local.y, min_local.z),
		Vector3(min_local.x, max_local.y, min_local.z),
		Vector3(max_local.x, max_local.y, min_local.z),
		Vector3(min_local.x, min_local.y, max_local.z),
		Vector3(max_local.x, min_local.y, max_local.z),
		Vector3(min_local.x, max_local.y, max_local.z),
		Vector3(max_local.x, max_local.y, max_local.z),
	]
	var bounds := AABB(global_transform * corners[0], Vector3.ZERO)
	for i in range(1, corners.size()):
		bounds = bounds.expand(global_transform * corners[i])
	return bounds


func _make_water_body_id() -> StringName:
	if is_inside_tree():
		return StringName(str(get_path()))
	return StringName("%s_%d" % [name, get_instance_id()])
