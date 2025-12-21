## WaterVolume - Volume-based water system for inland water, lakes, rivers, pools
## Uses Area3D for swimming/buoyancy detection
## Supports SSR + cubemap reflections
## Configurable per water type (lake, river, etc.)
@tool
class_name WaterVolume
extends Node3D

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
@export var enable_swimming: bool = true
@export var enable_buoyancy: bool = true
@export var swim_speed_multiplier: float = 0.6  ## How much swimming slows movement
@export var current_strength: float = 1.0  ## For rivers - how strong the current pushes

# Internal nodes
var _area: Area3D = null
var _collision_shape: CollisionShape3D = null
var _water_mesh: MeshInstance3D = null
var _material: ShaderMaterial = null
var _shader: Shader = null

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


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	_time += delta * wave_speed
	if _material:
		_material.set_shader_parameter("time", _time)

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
	_shader = Shader.new()

	# Create water shader for volumes
	# This is a simpler shader than ocean - designed for smaller water bodies
	_shader.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#define REFLECTANCE 0.02

uniform vec4 water_color : source_color = vec4(0.02, 0.15, 0.22, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.1;
uniform float clarity : hint_range(0.0, 1.0) = 0.5;
uniform float refraction_strength : hint_range(0.0, 0.3) = 0.05;
uniform float depth_fade_distance : hint_range(0.0, 100.0) = 5.0;

uniform bool enable_waves = true;
uniform float wave_scale : hint_range(0.0, 2.0) = 0.3;
uniform float time = 0.0;

// River flow
uniform vec2 flow_direction = vec2(1.0, 0.0);
uniform float flow_speed = 0.0;

varying float wave_height;
varying float fresnel;

// Simple wave function for small water bodies
vec3 simple_wave(vec2 pos, float time_val) {
	if (!enable_waves) {
		return vec3(0.0);
	}

	// Combine two sine waves for variety
	float wave1 = sin(pos.x * 0.5 + time_val * 1.5) * cos(pos.y * 0.3 + time_val * 1.2);
	float wave2 = sin(pos.x * 0.8 - pos.y * 0.5 + time_val * 1.8) * 0.5;
	float height = (wave1 + wave2) * wave_scale * 0.1;

	return vec3(0.0, height, 0.0);
}

// Calculate normal from wave function
vec3 calculate_wave_normal(vec2 pos, float time_val) {
	if (!enable_waves) {
		return vec3(0.0, 1.0, 0.0);
	}

	const float eps = 0.1;
	vec3 p = simple_wave(pos, time_val);
	vec3 px = simple_wave(pos + vec2(eps, 0.0), time_val);
	vec3 py = simple_wave(pos + vec2(0.0, eps), time_val);

	vec3 tangent = normalize(vec3(eps, px.y - p.y, 0.0));
	vec3 binormal = normalize(vec3(0.0, py.y - p.y, eps));

	return normalize(cross(binormal, tangent));
}

void vertex() {
	vec2 pos = VERTEX.xz;

	// Apply river flow offset to UV for scrolling effect
	vec2 flow_offset = flow_direction * time * flow_speed * 0.1;
	UV = (pos + flow_offset) * 0.1;

	// Apply wave displacement
	vec3 wave_disp = simple_wave(pos, time);
	VERTEX += wave_disp;
	wave_height = wave_disp.y;

	// Calculate normal from waves
	if (enable_waves) {
		NORMAL = calculate_wave_normal(pos, time);
	}
}

void fragment() {
	float NdotV = max(dot(VIEW, NORMAL), 0.001);
	fresnel = REFLECTANCE + (1.0 - REFLECTANCE) * pow(1.0 - NdotV, 5.0);

	// Refraction
	vec2 refraction_offset = NORMAL.xy * refraction_strength;
	vec3 refracted_color = textureLod(SCREEN_TEXTURE, SCREEN_UV + refraction_offset, 0.0).rgb;

	// Depth-based transparency
	float depth = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	vec4 world_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float depth_diff = world_pos.z / world_pos.w - VERTEX.z;
	float water_depth_fade = 1.0 - exp(-depth_diff / depth_fade_distance);

	// Mix refracted color with water color
	vec3 water_with_refraction = mix(refracted_color, water_color.rgb, water_depth_fade * (1.0 - clarity));
	ALBEDO = water_with_refraction;

	// Transparency
	ALPHA = mix(clarity, 1.0, fresnel * 0.5);

	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = 0.5;
	SSS_STRENGTH = 0.05;
}

void light() {
	// Simple PBR lighting
	vec3 halfway = normalize(LIGHT + VIEW);
	float dot_nl = max(dot(NORMAL, LIGHT), 0.001);
	float dot_nh = max(dot(NORMAL, halfway), 0.001);

	// Specular (simplified GGX)
	float a_sq = roughness * roughness;
	float d = 1.0 + (a_sq - 1.0) * dot_nh * dot_nh;
	float D = a_sq / (PI * d * d);
	float spec = fresnel * D * 0.25;
	SPECULAR_LIGHT += spec * ATTENUATION * LIGHT_COLOR;

	// Diffuse with subtle SSS
	float sss = pow(max(dot(LIGHT, -VIEW), 0.0), 3.0) * 0.3;
	vec3 diff_color = mix(water_color.rgb, vec3(0.1, 0.4, 0.3), sss);
	DIFFUSE_LIGHT += diff_color * dot_nl * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
}
"""


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


func _update_material() -> void:
	if not _material:
		return

	_material.set_shader_parameter("water_color", water_color)
	_material.set_shader_parameter("roughness", roughness)
	_material.set_shader_parameter("clarity", clarity)
	_material.set_shader_parameter("refraction_strength", refraction_strength)
	_material.set_shader_parameter("enable_waves", enable_waves and water_type != WaterType.POOL)
	_material.set_shader_parameter("wave_scale", wave_scale)
	_material.set_shader_parameter("flow_direction", flow_direction)
	_material.set_shader_parameter("flow_speed", flow_speed if water_type == WaterType.RIVER else 0.0)


func _on_body_entered(body: Node3D) -> void:
	if body is CharacterBody3D or body is RigidBody3D:
		_bodies_in_water.append(body)
		body_entered_water.emit(body)
		print("[WaterVolume] Body entered water: %s" % body.name)


func _on_body_exited(body: Node3D) -> void:
	var idx := _bodies_in_water.find(body)
	if idx >= 0:
		_bodies_in_water.remove_at(idx)
		body_exited_water.emit(body)
		print("[WaterVolume] Body exited water: %s" % body.name)


func _process_body_in_water(body: Node3D, delta: float) -> void:
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
	if enable_buoyancy and body is RigidBody3D:
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
	if is_position_in_water(world_pos):
		return global_position.y + water_surface_height
	return -1000.0  # Not in water


## Get bodies currently in water
func get_bodies_in_water() -> Array[Node3D]:
	return _bodies_in_water.duplicate()


## Check if a specific body is in water
func is_body_in_water(body: Node3D) -> bool:
	return body in _bodies_in_water
