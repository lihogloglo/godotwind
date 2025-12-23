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

# Whether using GPU compute or flat plane
var _use_compute: bool = false

# Cached state for quality switching
var _cached_shore_mask: Texture2D = null
var _cached_shore_bounds: Rect2 = Rect2()
var _cached_water_color: Color = Color(0.1, 0.15, 0.18, 1.0)
var _cached_foam_color: Color = Color(0.9, 0.9, 0.9, 1.0)
var _cached_depth_absorption: Vector3 = Vector3(7.5, 22.0, 38.0)
var _cached_wave_scale: float = 1.0
var _debug_shore_mask: bool = false


func _init() -> void:
	# Use world vertex coords for proper wave displacement
	pass


func initialize(radius: float, quality_override: int = -1) -> void:
	_quality_override = quality_override
	_select_quality()

	# Determine if we use compute based on quality
	# ONLY HIGH uses GPU FFT compute (requires dedicated GPU)
	# MEDIUM/LOW use vertex Gerstner (works on any GPU including integrated)
	# ULTRA_LOW uses flat plane (no animation, minimal GPU use)
	_use_compute = _quality == HardwareDetection.WaterQuality.HIGH

	_create_shader()
	_create_material()
	_create_clipmap_mesh(radius)

	var mode: String
	match _quality:
		HardwareDetection.WaterQuality.HIGH:
			mode = "GPU FFT (3 cascades)"
		HardwareDetection.WaterQuality.MEDIUM:
			mode = "Gerstner (4 waves, full GGX)"
		HardwareDetection.WaterQuality.LOW:
			mode = "Gerstner (2 waves, simplified)"
		HardwareDetection.WaterQuality.ULTRA_LOW:
			mode = "Flat Plane"
	print("[OceanMesh] Initialized - radius: %.0fm, quality: %s, mode: %s" % [
		radius, HardwareDetection.quality_name(_quality), mode])


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

	# Select shader based on quality level
	match _quality:
		HardwareDetection.WaterQuality.HIGH:
			# GPU FFT compute shader - only for HIGH quality
			shader_path = "res://src/core/water/shaders/ocean_compute.gdshader"
			_shader = load(shader_path) as Shader
			if not _shader:
				push_warning("[OceanMesh] Compute shader not found, falling back to Gerstner")
				_shader = _create_gerstner_shader()
			else:
				print("[OceanMesh] Using GPU FFT compute shader")

		HardwareDetection.WaterQuality.MEDIUM:
			# 4 Gerstner waves with full GGX + SSS lighting
			shader_path = "res://src/core/water/shaders/ocean_gerstner.gdshader"
			_shader = load(shader_path) as Shader
			if not _shader:
				push_warning("[OceanMesh] Gerstner shader not found, using inline")
				_shader = _create_gerstner_shader()
			else:
				print("[OceanMesh] Using MEDIUM quality shader (4 waves)")

		HardwareDetection.WaterQuality.LOW:
			# 2 Gerstner waves with simplified lighting for weak GPUs
			shader_path = "res://src/core/water/shaders/ocean_low.gdshader"
			_shader = load(shader_path) as Shader
			if not _shader:
				push_warning("[OceanMesh] Low shader not found, using inline gerstner")
				_shader = _create_gerstner_shader()
			else:
				print("[OceanMesh] Using LOW quality shader (2 waves)")

		HardwareDetection.WaterQuality.ULTRA_LOW, _:
			# Flat plane - no animation, minimal GPU use
			shader_path = "res://src/core/water/shaders/ocean_flat.gdshader"
			_shader = load(shader_path) as Shader
			if not _shader:
				push_warning("[OceanMesh] Flat shader not found, using inline")
				_shader = _create_flat_shader()
			else:
				print("[OceanMesh] Using flat plane shader")


func _create_flat_shader() -> Shader:
	# Simple flat plane shader with improved lighting - no wave computation
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode world_vertex_coords, depth_draw_opaque, cull_disabled;

#define REFLECTANCE 0.02

uniform vec4 water_color : source_color = vec4(0.1, 0.15, 0.18, 1.0);
uniform float roughness = 0.3;

varying float fresnel;

void vertex() {
	UV = VERTEX.xz * 0.01;
}

void fragment() {
	fresnel = mix(pow(1.0 - max(dot(VIEW, NORMAL), 0.0), 5.0), 1.0, REFLECTANCE);
	ALBEDO = water_color.rgb;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
}

void light() {
	vec3 halfway = normalize(LIGHT + VIEW);
	float dot_nl = max(dot(NORMAL, LIGHT), 0.0);
	float dot_nv = max(dot(NORMAL, VIEW), 0.0);
	float dot_nh = max(dot(NORMAL, halfway), 0.0);
	float spec_power = 64.0 * (1.0 - roughness);
	float specular = pow(dot_nh, spec_power) * fresnel;
	SPECULAR_LIGHT += specular * ATTENUATION;
	float lambertian = 0.5 * dot_nl;
	DIFFUSE_LIGHT += (lambertian * water_color.rgb + vec3(0.02, 0.04, 0.06) * dot_nv) * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
}
"""
	return shader


func _create_gerstner_shader() -> Shader:
	# Vertex shader Gerstner waves with proper lighting - works on any GPU
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode world_vertex_coords, depth_draw_opaque, cull_disabled;

#define REFLECTANCE 0.02

uniform vec4 water_color : source_color = vec4(0.1, 0.15, 0.18, 1.0);
uniform vec4 foam_color : source_color = vec4(0.9, 0.9, 0.9, 1.0);
uniform float time = 0.0;
uniform float wave_scale = 1.0;
uniform float roughness = 0.3;

varying float wave_height;
varying float foam_factor;
varying float fresnel;

vec3 gerstner_wave(vec2 pos, float wl, float st, vec2 dir, float t, out vec3 tan, out vec3 bin) {
	float k = 6.28318 / wl;
	float c = sqrt(9.81 / k);
	vec2 d = normalize(dir);
	float f = k * (dot(d, pos) - c * t);
	float a = st / k;
	float cf = cos(f), sf = sin(f);
	tan = vec3(1.0 - d.x*d.x*st*sf, d.x*st*cf, -d.x*d.y*st*sf);
	bin = vec3(-d.x*d.y*st*sf, d.y*st*cf, 1.0 - d.y*d.y*st*sf);
	return vec3(d.x*a*cf, a*sf, d.y*a*cf);
}

void vertex() {
	vec2 pos = VERTEX.xz;
	vec3 disp = vec3(0.0), t, b;
	vec3 tsum = vec3(1,0,0), bsum = vec3(0,0,1);
	disp += gerstner_wave(pos, 60.0, 0.15*wave_scale, vec2(1.0,0.3), time, t, b);
	tsum += t - vec3(1,0,0); bsum += b - vec3(0,0,1);
	disp += gerstner_wave(pos, 31.0, 0.12*wave_scale, vec2(1.0,0.8), time*1.1, t, b);
	tsum += t - vec3(1,0,0); bsum += b - vec3(0,0,1);
	disp += gerstner_wave(pos, 18.0, 0.10*wave_scale, vec2(0.8,1.0), time*1.2, t, b);
	tsum += t - vec3(1,0,0); bsum += b - vec3(0,0,1);
	VERTEX += disp;
	wave_height = disp.y;
	NORMAL = normalize(cross(bsum, tsum));
	UV = pos * 0.01;
}

void fragment() {
	foam_factor = smoothstep(0.8, 2.0, abs(wave_height));
	foam_factor = clamp(foam_factor, 0.0, 0.6);
	float NdotV = max(dot(VIEW, NORMAL), 0.001);
	fresnel = REFLECTANCE + (1.0 - REFLECTANCE) * pow(1.0 - NdotV, 5.0);
	ALBEDO = mix(water_color.rgb, foam_color.rgb, foam_factor);
	ROUGHNESS = mix(roughness, 0.6, foam_factor);
	METALLIC = 0.0;
}

float smith_masking_shadowing(in float cos_theta, in float alpha) {
	float a = cos_theta / (alpha * sqrt(1.0 - cos_theta * cos_theta));
	float a_sq = a * a;
	return a < 1.6 ? (1.0 - 1.259 * a + 0.396 * a_sq) / (3.535 * a + 2.181 * a_sq) : 0.0;
}

float ggx_distribution(in float cos_theta, in float alpha) {
	float a_sq = alpha * alpha;
	float d = 1.0 + (a_sq - 1.0) * cos_theta * cos_theta;
	return a_sq / (PI * d * d);
}

void light() {
	vec3 halfway = normalize(LIGHT + VIEW);
	float dot_nl = max(dot(NORMAL, LIGHT), 0.001);
	float dot_nv = max(dot(NORMAL, VIEW), 0.001);
	float dot_nh = max(dot(NORMAL, halfway), 0.001);
	float view_mask = smith_masking_shadowing(dot_nv, roughness);
	float light_mask = smith_masking_shadowing(dot_nl, roughness);
	float D = ggx_distribution(dot_nh, roughness);
	float G = 1.0 / (1.0 + view_mask + light_mask);
	SPECULAR_LIGHT += fresnel * D * G / (4.0 * dot_nv + 0.1) * ATTENUATION * LIGHT_COLOR;
	const vec3 sss_color = vec3(0.1, 0.4, 0.35);
	float backlit = pow(max(dot(LIGHT, -VIEW), 0.0), 4.0);
	float wrap = pow(0.5 - 0.5 * dot(LIGHT, NORMAL), 2.0);
	float sss = max(0.0, wave_height + 1.0) * backlit * wrap;
	vec3 diff_color = mix(water_color.rgb, sss_color, sss * 0.5);
	diff_color = mix(diff_color, foam_color.rgb, foam_factor);
	DIFFUSE_LIGHT += diff_color * dot_nl * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
}
"""
	return shader


func _create_fallback_shader() -> Shader:
	# Gerstner fallback with proper lighting for when quality shader doesn't exist
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode world_vertex_coords, depth_draw_always;

#define REFLECTANCE 0.02

uniform vec4 water_color : source_color = vec4(0.1, 0.15, 0.18, 1.0);
uniform vec4 foam_color : source_color = vec4(0.9, 0.9, 0.9, 1.0);
uniform float time = 0.0;
uniform float roughness = 0.3;

varying float wave_height;
varying float foam_factor;
varying float fresnel;

vec3 gerstner_wave(vec2 pos, float wl, float st, vec2 dir, float t, out vec3 tan, out vec3 bin) {
	float k = 6.28318 / wl;
	float c = sqrt(9.81 / k);
	vec2 d = normalize(dir);
	float f = k * (dot(d, pos) - c * t);
	float a = st / k;
	float cf = cos(f), sf = sin(f);
	tan = vec3(1.0 - d.x*d.x*st*sf, d.x*st*cf, -d.x*d.y*st*sf);
	bin = vec3(-d.x*d.y*st*sf, d.y*st*cf, 1.0 - d.y*d.y*st*sf);
	return vec3(d.x*a*cf, a*sf, d.y*a*cf);
}

void vertex() {
	vec2 pos = VERTEX.xz;
	vec3 disp = vec3(0.0), t, b;
	vec3 tsum = vec3(1,0,0), bsum = vec3(0,0,1);
	disp += gerstner_wave(pos, 60.0, 0.15, vec2(1.0,0.3), time, t, b);
	tsum += t - vec3(1,0,0); bsum += b - vec3(0,0,1);
	disp += gerstner_wave(pos, 31.0, 0.12, vec2(1.0,0.8), time*1.1, t, b);
	tsum += t - vec3(1,0,0); bsum += b - vec3(0,0,1);
	disp += gerstner_wave(pos, 18.0, 0.10, vec2(0.8,1.0), time*1.2, t, b);
	tsum += t - vec3(1,0,0); bsum += b - vec3(0,0,1);
	VERTEX += disp;
	wave_height = disp.y;
	NORMAL = normalize(cross(bsum, tsum));
}

void fragment() {
	foam_factor = smoothstep(0.8, 2.0, abs(wave_height));
	foam_factor = clamp(foam_factor, 0.0, 0.6);
	float NdotV = max(dot(VIEW, NORMAL), 0.001);
	fresnel = REFLECTANCE + (1.0 - REFLECTANCE) * pow(1.0 - NdotV, 5.0);
	ALBEDO = mix(water_color.rgb, foam_color.rgb, foam_factor);
	ROUGHNESS = mix(roughness, 0.6, foam_factor);
	METALLIC = 0.0;
}

float smith_masking_shadowing(in float cos_theta, in float alpha) {
	float a = cos_theta / (alpha * sqrt(1.0 - cos_theta * cos_theta));
	float a_sq = a * a;
	return a < 1.6 ? (1.0 - 1.259 * a + 0.396 * a_sq) / (3.535 * a + 2.181 * a_sq) : 0.0;
}

float ggx_distribution(in float cos_theta, in float alpha) {
	float a_sq = alpha * alpha;
	float d = 1.0 + (a_sq - 1.0) * cos_theta * cos_theta;
	return a_sq / (PI * d * d);
}

void light() {
	vec3 halfway = normalize(LIGHT + VIEW);
	float dot_nl = max(dot(NORMAL, LIGHT), 0.001);
	float dot_nv = max(dot(NORMAL, VIEW), 0.001);
	float dot_nh = max(dot(NORMAL, halfway), 0.001);
	float view_mask = smith_masking_shadowing(dot_nv, roughness);
	float light_mask = smith_masking_shadowing(dot_nl, roughness);
	float D = ggx_distribution(dot_nh, roughness);
	float G = 1.0 / (1.0 + view_mask + light_mask);
	SPECULAR_LIGHT += fresnel * D * G / (4.0 * dot_nv + 0.1) * ATTENUATION * LIGHT_COLOR;
	const vec3 sss_color = vec3(0.1, 0.4, 0.35);
	float backlit = pow(max(dot(LIGHT, -VIEW), 0.0), 4.0);
	float wrap = pow(0.5 - 0.5 * dot(LIGHT, NORMAL), 2.0);
	float sss = max(0.0, wave_height + 1.0) * backlit * wrap;
	vec3 diff_color = mix(water_color.rgb, sss_color, sss * 0.5);
	diff_color = mix(diff_color, foam_color.rgb, foam_factor);
	DIFFUSE_LIGHT += diff_color * dot_nl * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
}
"""
	return shader


func _create_material() -> void:
	_material = ShaderMaterial.new()

	if not _shader:
		push_error("[OceanMesh] No shader set!")
		return

	# CRITICAL: For ocean_compute.gdshader which uses global uniforms,
	# we must set global shader parameters BEFORE assigning the shader.
	# This prevents "global parameter was removed" warnings.
	if _use_compute:
		# Initialize global shader parameters with proper values
		# Use brighter colors matching original GodotOceanWaves (0.1, 0.15, 0.18)
		var water_col := Color(0.1, 0.15, 0.18, 1.0)
		var foam_col := Color(0.9, 0.9, 0.9, 1.0)
		RenderingServer.global_shader_parameter_set(&"water_color", water_col.srgb_to_linear())
		RenderingServer.global_shader_parameter_set(&"foam_color", foam_col.srgb_to_linear())
		# num_cascades, displacements, normals are set later by set_wave_textures()
		print("[OceanMesh] Initialized global shader parameters for compute shader")

	_material.shader = _shader

	# Set default uniform values for all shader types (non-global uniforms)
	# Use brighter water color matching original GodotOceanWaves
	_material.set_shader_parameter("water_color", Color(0.1, 0.15, 0.18, 1.0))
	_material.set_shader_parameter("time", 0.0)
	_material.set_shader_parameter("roughness", 0.3)
	_material.set_shader_parameter("wave_scale", 1.0)

	# Foam color for Gerstner and compute shaders (not used by flat shader)
	if _quality != HardwareDetection.WaterQuality.ULTRA_LOW:
		_material.set_shader_parameter("foam_color", Color(0.9, 0.9, 0.9, 1.0))

	# GPU compute shader specific
	if _use_compute:
		_material.set_shader_parameter("normal_strength", 1.0)

	material_override = _material
	print("[OceanMesh] Material created - shader: %s, material_override set: %s" % [
		_shader.resource_path if _shader else "NONE",
		material_override != null])


func _create_clipmap_mesh(radius: float) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var vertex_offset := 0

	# Create concentric rings with increasing quad sizes
	var prev_outer_radius := 0.0
	for ring in range(NUM_LOD_RINGS):
		var quad_size := BASE_QUAD_SIZE * pow(2.0, float(ring))
		var inner_radius := prev_outer_radius
		var outer_radius := quad_size * RING_VERTEX_COUNT * 0.5

		# Clamp to max radius
		outer_radius = minf(outer_radius, radius)

		# Skip if this ring would be empty
		if outer_radius <= inner_radius:
			continue

		var ring_data := _create_ring(inner_radius, outer_radius, quad_size, vertex_offset)
		vertices.append_array(ring_data.vertices)
		uvs.append_array(ring_data.uvs)
		indices.append_array(ring_data.indices)
		vertex_offset += ring_data.vertices.size()
		prev_outer_radius = outer_radius

	print("[OceanMesh] Created mesh with %d vertices, %d triangles" % [vertices.size(), indices.size() / 3])

	if vertices.size() == 0:
		push_error("[OceanMesh] ERROR: No vertices created! Radius: %.0f" % radius)
		return

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

	# Debug: print AABB
	var aabb := array_mesh.get_aabb()
	print("[OceanMesh] Mesh AABB: position=%s, size=%s" % [aabb.position, aabb.size])


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


func set_wave_scale(scale: float) -> void:
	# Cache for quality switching
	_cached_wave_scale = scale

	if _material:
		_material.set_shader_parameter("wave_scale", scale)


func set_water_color(color: Color) -> void:
	# Cache for quality switching
	_cached_water_color = color

	# Set both material parameter and global parameter
	# Global is needed for ocean_compute.gdshader which uses global uniforms
	if _material:
		_material.set_shader_parameter("water_color", color)
	# Set global parameter with sRGB to linear conversion (matching GodotOceanWaves)
	RenderingServer.global_shader_parameter_set(&"water_color", color.srgb_to_linear())


func set_foam_color(color: Color) -> void:
	# Cache for quality switching
	_cached_foam_color = color

	# Set both material parameter and global parameter
	if _material:
		_material.set_shader_parameter("foam_color", color)
	# Set global parameter with sRGB to linear conversion
	RenderingServer.global_shader_parameter_set(&"foam_color", color.srgb_to_linear())


func set_depth_absorption(absorption: Vector3) -> void:
	# Cache for quality switching
	_cached_depth_absorption = absorption

	if _material:
		_material.set_shader_parameter("depth_color_consumption", absorption)


func set_displacement_textures(displacements: Texture2DArray, normals: Texture2DArray) -> void:
	if _material:
		_material.set_shader_parameter("displacements", displacements)
		_material.set_shader_parameter("normals", normals)


## Set wave textures from GPU compute (Texture2DArrayRD)
## These are set as global shader parameters for the GPU compute shader approach
func set_wave_textures(displacements: Texture2DArrayRD, normals: Texture2DArrayRD, num_cascades: int = -1) -> void:
	if not _use_compute:
		return

	# Verify textures have valid RIDs before setting global parameters
	if not displacements or not displacements.texture_rd_rid.is_valid():
		push_warning("[OceanMesh] Displacement texture RID is invalid, skipping global parameter set")
		return
	if not normals or not normals.texture_rd_rid.is_valid():
		push_warning("[OceanMesh] Normal texture RID is invalid, skipping global parameter set")
		return

	# Update num_cascades if provided
	if num_cascades > 0:
		_num_cascades = num_cascades

	# Set as global shader parameters (matching GodotOceanWaves approach)
	RenderingServer.global_shader_parameter_set(&"displacements", displacements)
	RenderingServer.global_shader_parameter_set(&"normals", normals)
	RenderingServer.global_shader_parameter_set(&"num_cascades", _num_cascades)
	print("[OceanMesh] Global shader parameters set - cascades: %d" % _num_cascades)

	# Update map scales
	var scales: PackedVector4Array
	scales.resize(_num_cascades)
	# Default scales for 3 cascades
	var default_scales := [
		Vector4(0.004, 0.004, 1.0, 1.0),  # 250m tile -> 1/250 = 0.004
		Vector4(0.015, 0.015, 0.5, 0.5),  # 67m tile -> ~0.015
		Vector4(0.059, 0.059, 0.25, 0.25) # 17m tile -> ~0.059
	]
	for i in range(mini(_num_cascades, 3)):
		scales[i] = default_scales[i]
	if _material:
		_material.set_shader_parameter("map_scales", scales)


func set_cascade_scales(scales: Array[Vector4], num_cascades: int) -> void:
	_map_scales = scales
	_num_cascades = num_cascades
	if _material:
		_material.set_shader_parameter("map_scales", scales)
		_material.set_shader_parameter("num_cascades", num_cascades)


func set_shore_mask(mask: Texture2D, world_bounds: Rect2) -> void:
	# Cache for quality switching
	_cached_shore_mask = mask
	_cached_shore_bounds = world_bounds

	if _material:
		_material.set_shader_parameter("shore_mask", mask)
		var bounds_vec := Vector4(
			world_bounds.position.x,
			world_bounds.position.y,
			world_bounds.size.x,
			world_bounds.size.y
		)
		_material.set_shader_parameter("shore_mask_bounds", bounds_vec)
		print("[OceanMesh] Shore mask set - texture: %s, bounds: %s" % [
			mask.get_size() if mask else "null",
			bounds_vec
		])
	else:
		push_warning("[OceanMesh] Cannot set shore mask - material is null")


func get_material() -> ShaderMaterial:
	return _material


## Get current water quality level
func get_quality() -> HardwareDetection.WaterQuality:
	return _quality


## Check if using GPU compute shaders
func is_using_compute() -> bool:
	return _use_compute


## Set water quality (requires re-initialization)
## Returns true if quality changed and HIGH quality needs wave texture setup
func set_quality(quality: HardwareDetection.WaterQuality, radius: float) -> bool:
	var old_quality := _quality
	_quality_override = quality
	_select_quality()

	# Check if quality actually changed
	if _quality == old_quality:
		return false

	_use_compute = _quality == HardwareDetection.WaterQuality.HIGH
	_create_shader()
	_create_material()

	# Restore all cached state after material recreation
	_restore_cached_state()

	print("[OceanMesh] Quality changed: %s -> %s, use_compute: %s" % [
		HardwareDetection.quality_name(old_quality),
		HardwareDetection.quality_name(_quality),
		_use_compute])

	# Return true if switching to HIGH (caller needs to reconnect wave textures)
	return _use_compute


## Restore all cached shader parameters after quality change
func _restore_cached_state() -> void:
	if not _material:
		return

	# Restore shore mask
	if _cached_shore_mask:
		_material.set_shader_parameter("shore_mask", _cached_shore_mask)
		_material.set_shader_parameter("shore_mask_bounds", Vector4(
			_cached_shore_bounds.position.x,
			_cached_shore_bounds.position.y,
			_cached_shore_bounds.size.x,
			_cached_shore_bounds.size.y
		))

	# Restore colors
	_material.set_shader_parameter("water_color", _cached_water_color)
	_material.set_shader_parameter("foam_color", _cached_foam_color)

	# Restore depth absorption (only for shaders that have this uniform)
	if _quality != HardwareDetection.WaterQuality.ULTRA_LOW:
		_material.set_shader_parameter("depth_color_consumption", _cached_depth_absorption)

	# Restore wave scale
	_material.set_shader_parameter("wave_scale", _cached_wave_scale)

	# Re-set global parameters for compute shader
	if _use_compute:
		RenderingServer.global_shader_parameter_set(&"water_color", _cached_water_color.srgb_to_linear())
		RenderingServer.global_shader_parameter_set(&"foam_color", _cached_foam_color.srgb_to_linear())

	print("[OceanMesh] Restored cached state: shore_mask=%s, water_color=%s" % [
		_cached_shore_mask != null, _cached_water_color])

	# Restore debug mode
	_material.set_shader_parameter("debug_shore_mask", _debug_shore_mask)


## Toggle debug visualization of shore mask damping
## Returns the new debug state
func set_debug_shore_mask(enabled: bool) -> void:
	_debug_shore_mask = enabled
	if _material:
		_material.set_shader_parameter("debug_shore_mask", enabled)
		print("[OceanMesh] Debug shore mask: %s" % enabled)


## Get current debug shore mask state
func is_debug_shore_mask() -> bool:
	return _debug_shore_mask
