## OceanMesh - Clipmap mesh for ocean surface rendering
## Creates a multi-LOD mesh that follows the camera
## Inner rings are high detail, outer rings are lower detail
class_name OceanMesh
extends MeshInstance3D

# Clipmap configuration
const NUM_LOD_RINGS: int = 6
const BASE_QUAD_SIZE: float = 2.0  # Innermost ring quad size in meters
const RING_VERTEX_COUNT: int = 64   # Vertices per side for each ring

# Shader
var _material: ShaderMaterial = null
var _shader: Shader = null

# Quality settings
var _quality: HardwareDetection.WaterQuality = HardwareDetection.WaterQuality.HIGH
var _quality_override: int = -1  # -1 = auto, otherwise forced quality

# Cascade data for shader
var _map_scales: Array[Vector4] = []
var _num_cascades: int = 3


func _init() -> void:
	# Use world vertex coords for proper wave displacement
	pass


func initialize(radius: float, quality_override: int = -1) -> void:
	_quality_override = quality_override
	_select_quality()
	_create_shader()
	_create_material()
	_create_clipmap_mesh(radius)
	print("[OceanMesh] Initialized with %d LOD rings, radius: %.0fm, quality: %s" % [
		NUM_LOD_RINGS, radius, HardwareDetection.quality_name(_quality)])


func _select_quality() -> void:
	if _quality_override >= 0 and _quality_override <= HardwareDetection.WaterQuality.HIGH:
		_quality = _quality_override as HardwareDetection.WaterQuality
		print("[OceanMesh] Quality override: %s" % HardwareDetection.quality_name(_quality))
	else:
		_quality = HardwareDetection.get_recommended_quality()
		print("[OceanMesh] Auto-detected quality: %s (GPU: %s)" % [
			HardwareDetection.quality_name(_quality),
			HardwareDetection.get_gpu_name()])


func _create_shader() -> void:
	var shader_path: String

	match _quality:
		HardwareDetection.WaterQuality.ULTRA_LOW:
			shader_path = "res://src/core/water/shaders/ocean_ultra_low.gdshader"
		HardwareDetection.WaterQuality.LOW:
			shader_path = "res://src/core/water/shaders/ocean_low.gdshader"
		HardwareDetection.WaterQuality.MEDIUM:
			shader_path = "res://src/core/water/shaders/ocean_medium.gdshader"
		HardwareDetection.WaterQuality.HIGH:
			shader_path = "res://src/core/water/shaders/ocean.gdshader"

	_shader = load(shader_path) as Shader
	if not _shader:
		push_warning("[OceanMesh] Shader not found: %s, using fallback" % shader_path)
		_shader = _create_fallback_shader()
	else:
		print("[OceanMesh] Loaded shader: %s" % shader_path)


func _create_fallback_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode world_vertex_coords, depth_draw_always;

uniform vec4 water_color : source_color = vec4(0.02, 0.08, 0.15, 1.0);
uniform vec4 foam_color : source_color = vec4(0.9, 0.9, 0.9, 1.0);
uniform float time = 0.0;

// Simple Gerstner wave for fallback
vec3 gerstner_wave(vec2 pos, float wavelength, float steepness, vec2 direction, float time_val) {
	float k = 2.0 * PI / wavelength;
	float c = sqrt(9.81 / k);
	vec2 d = normalize(direction);
	float f = k * (dot(d, pos) - c * time_val);
	float a = steepness / k;
	return vec3(
		d.x * (a * cos(f)),
		a * sin(f),
		d.y * (a * cos(f))
	);
}

void vertex() {
	vec2 pos = VERTEX.xz;

	// Sum multiple Gerstner waves
	vec3 displacement = vec3(0.0);
	displacement += gerstner_wave(pos, 60.0, 0.25, vec2(1.0, 0.0), time);
	displacement += gerstner_wave(pos, 31.0, 0.25, vec2(1.0, 0.6), time);
	displacement += gerstner_wave(pos, 18.0, 0.25, vec2(1.0, 1.3), time);

	VERTEX += displacement;
}

void fragment() {
	ALBEDO = water_color.rgb;
	ROUGHNESS = 0.1;
	METALLIC = 0.0;

	// Simple fresnel
	float fresnel = pow(1.0 - dot(VIEW, NORMAL), 3.0);
	ALBEDO = mix(ALBEDO, vec3(0.8, 0.9, 1.0), fresnel * 0.3);
}
"""
	return shader


func _create_material() -> void:
	_material = ShaderMaterial.new()
	_material.shader = _shader

	# Set default uniform values
	_material.set_shader_parameter("water_color", Color(0.02, 0.08, 0.15, 1.0))
	_material.set_shader_parameter("foam_color", Color(0.9, 0.9, 0.9, 1.0))
	_material.set_shader_parameter("time", 0.0)
	_material.set_shader_parameter("roughness", 0.4)
	_material.set_shader_parameter("normal_strength", 1.0)

	material_override = _material


func _create_clipmap_mesh(radius: float) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var vertex_offset := 0

	# Create concentric rings with increasing quad sizes
	for ring in range(NUM_LOD_RINGS):
		var quad_size := BASE_QUAD_SIZE * pow(2.0, float(ring))
		var inner_radius := 0.0 if ring == 0 else BASE_QUAD_SIZE * pow(2.0, float(ring)) * RING_VERTEX_COUNT * 0.5
		var outer_radius := quad_size * RING_VERTEX_COUNT * 0.5

		# Clamp to max radius
		outer_radius = minf(outer_radius, radius)

		var ring_data := _create_ring(inner_radius, outer_radius, quad_size, vertex_offset)
		vertices.append_array(ring_data.vertices)
		uvs.append_array(ring_data.uvs)
		indices.append_array(ring_data.indices)
		vertex_offset += ring_data.vertices.size()

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	# Calculate normals
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	normals.fill(Vector3.UP)
	arrays[Mesh.ARRAY_NORMAL] = normals

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	mesh = array_mesh


func _create_ring(inner_radius: float, outer_radius: float, quad_size: float, vertex_offset: int) -> Dictionary:
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	if inner_radius <= 0.0:
		# Innermost ring - full grid
		var half_size := outer_radius
		var num_quads := int(outer_radius * 2.0 / quad_size)

		for z in range(num_quads + 1):
			for x in range(num_quads + 1):
				var pos := Vector3(
					-half_size + x * quad_size,
					0.0,
					-half_size + z * quad_size
				)
				vertices.append(pos)
				uvs.append(Vector2(pos.x, pos.z))

		# Create triangles
		for z in range(num_quads):
			for x in range(num_quads):
				var i := z * (num_quads + 1) + x + vertex_offset
				indices.append(i)
				indices.append(i + num_quads + 1)
				indices.append(i + 1)
				indices.append(i + 1)
				indices.append(i + num_quads + 1)
				indices.append(i + num_quads + 2)
	else:
		# Outer ring - donut shape
		var num_segments := int(outer_radius * 2.0 * PI / quad_size / 4.0) * 4
		num_segments = maxi(num_segments, 16)

		# Create vertices for inner and outer edges
		for i in range(num_segments):
			var angle := float(i) / float(num_segments) * TAU
			var cos_a := cos(angle)
			var sin_a := sin(angle)

			# Inner vertex
			vertices.append(Vector3(cos_a * inner_radius, 0.0, sin_a * inner_radius))
			uvs.append(Vector2(cos_a * inner_radius, sin_a * inner_radius))

			# Outer vertex
			vertices.append(Vector3(cos_a * outer_radius, 0.0, sin_a * outer_radius))
			uvs.append(Vector2(cos_a * outer_radius, sin_a * outer_radius))

		# Create triangles
		for i in range(num_segments):
			var next := (i + 1) % num_segments
			var i0 := i * 2 + vertex_offset
			var i1 := i * 2 + 1 + vertex_offset
			var i2 := next * 2 + vertex_offset
			var i3 := next * 2 + 1 + vertex_offset

			# First triangle
			indices.append(i0)
			indices.append(i2)
			indices.append(i1)

			# Second triangle
			indices.append(i1)
			indices.append(i2)
			indices.append(i3)

	return {
		"vertices": vertices,
		"uvs": uvs,
		"indices": indices
	}


func update_position(center: Vector3) -> void:
	global_position = center


func set_shader_time(time: float) -> void:
	if _material:
		_material.set_shader_parameter("time", time)


func set_water_color(color: Color) -> void:
	if _material:
		_material.set_shader_parameter("water_color", color)


func set_foam_color(color: Color) -> void:
	if _material:
		_material.set_shader_parameter("foam_color", color)


func set_depth_absorption(absorption: Vector3) -> void:
	if _material:
		_material.set_shader_parameter("depth_color_consumption", absorption)


func set_displacement_textures(displacements: Texture2DArray, normals: Texture2DArray) -> void:
	if _material:
		_material.set_shader_parameter("displacements", displacements)
		_material.set_shader_parameter("normals", normals)


func set_cascade_scales(scales: Array[Vector4], num_cascades: int) -> void:
	_map_scales = scales
	_num_cascades = num_cascades
	if _material:
		_material.set_shader_parameter("map_scales", scales)
		_material.set_shader_parameter("num_cascades", num_cascades)


func set_shore_mask(mask: Texture2D, world_bounds: Rect2) -> void:
	if _material:
		_material.set_shader_parameter("shore_mask", mask)
		_material.set_shader_parameter("shore_mask_bounds", Vector4(
			world_bounds.position.x,
			world_bounds.position.y,
			world_bounds.size.x,
			world_bounds.size.y
		))


func get_material() -> ShaderMaterial:
	return _material


## Get current water quality level
func get_quality() -> HardwareDetection.WaterQuality:
	return _quality


## Set water quality (requires re-initialization)
func set_quality(quality: HardwareDetection.WaterQuality, radius: float) -> void:
	_quality_override = quality
	_select_quality()
	_create_shader()
	_create_material()
	# Mesh doesn't need to be recreated for quality change
