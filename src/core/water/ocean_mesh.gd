## OceanMesh - Clipmap mesh for ocean surface rendering
## Creates a multi-LOD mesh that follows the camera
## Inner rings are high detail, outer rings are lower detail
##
## Two quality modes:
## - FFT (HIGH): GPU compute shader with 3 wave cascades - requires dedicated GPU
## - FLAT (LOW): Simple flat plane with basic lighting - works everywhere
class_name OceanMesh
extends MeshInstance3D

# Clipmap configuration
const NUM_LOD_RINGS: int = 6
const BASE_QUAD_SIZE: float = 2.0  # Innermost ring quad size in meters
const RING_VERTEX_COUNT: int = 64   # Vertices per side for each ring

# Quality modes (simplified from 4 to 2)
enum QualityMode { FLAT, FFT }

# Shader
var _material: ShaderMaterial = null
var _shader: Shader = null

# Quality settings
var _quality: QualityMode = QualityMode.FFT
var _quality_override: int = -1  # -1 = auto, 0 = flat, 1 = FFT

# Cascade data for shader
var _map_scales: Array[Vector4] = []
var _num_cascades: int = 3

# Cached state for quality switching
var _cached_shore_mask: Texture2D = null
var _cached_shore_bounds: Rect2 = Rect2()
var _cached_water_color: Color = Color(0.1, 0.15, 0.18, 1.0)
var _cached_foam_color: Color = Color(0.9, 0.9, 0.9, 1.0)
var _cached_depth_absorption: Vector3 = Vector3(7.5, 22.0, 38.0)
var _cached_wave_scale: float = 1.0
var _debug_shore_mask: bool = false


func initialize(radius: float, quality_override: int = -1) -> void:
	_quality_override = quality_override
	_select_quality()

	_create_shader()
	_create_material()
	_create_clipmap_mesh(radius)

	var mode_name := "GPU FFT (3 cascades)" if _quality == QualityMode.FFT else "Flat Plane"
	print("[OceanMesh] Initialized - radius: %.0fm, mode: %s" % [radius, mode_name])


func _select_quality() -> void:
	if _quality_override == 0:
		_quality = QualityMode.FLAT
		print("[OceanMesh] Quality override: FLAT")
	elif _quality_override == 1:
		_quality = QualityMode.FFT
		print("[OceanMesh] Quality override: FFT")
	else:
		# Auto-detect based on hardware
		HardwareDetection.detect()
		var recommended := HardwareDetection.get_recommended_quality()
		# Map old quality levels to new simplified ones
		# HIGH -> FFT, everything else -> FLAT
		if recommended == HardwareDetection.WaterQuality.HIGH:
			_quality = QualityMode.FFT
		else:
			_quality = QualityMode.FLAT
		print("[OceanMesh] Auto-detected quality: %s (GPU: %s)" % [
			"FFT" if _quality == QualityMode.FFT else "FLAT",
			HardwareDetection.get_gpu_name()])


func _create_shader() -> void:
	var shader_path: String

	match _quality:
		QualityMode.FFT:
			shader_path = "res://src/core/water/shaders/ocean_compute.gdshader"
			_shader = load(shader_path) as Shader
			if not _shader:
				push_warning("[OceanMesh] FFT shader not found, falling back to flat")
				_quality = QualityMode.FLAT
				_create_shader()  # Recurse to load flat
				return
			print("[OceanMesh] Using GPU FFT compute shader")

		QualityMode.FLAT:
			shader_path = "res://src/core/water/shaders/ocean_flat.gdshader"
			_shader = load(shader_path) as Shader
			if not _shader:
				push_warning("[OceanMesh] Flat shader not found, using inline")
				_shader = _create_inline_flat_shader()
			else:
				print("[OceanMesh] Using flat plane shader")


func _create_inline_flat_shader() -> Shader:
	# Simple flat plane shader - fallback if file not found
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode depth_draw_opaque, cull_disabled;

uniform vec4 water_color : source_color = vec4(0.1, 0.15, 0.18, 1.0);
uniform float roughness = 0.3;
uniform sampler2D shore_mask : filter_linear;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);

varying float shore_factor;
varying vec3 world_pos_val;

float sample_shore_mask(vec2 world_xz) {
	vec2 uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 1.0;
	}
	return texture(shore_mask, uv).r;
}

void vertex() {
	world_pos_val = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	shore_factor = sample_shore_mask(world_pos_val.xz);
}

void fragment() {
	if (shore_factor < 0.01) {
		discard;
	}
	float fresnel = mix(pow(1.0 - max(dot(VIEW, NORMAL), 0.0), 5.0), 1.0, 0.02);
	ALBEDO = water_color.rgb;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	ALPHA = shore_factor;
}
"""
	return shader


func _create_material() -> void:
	_material = ShaderMaterial.new()

	if not _shader:
		push_error("[OceanMesh] No shader set!")
		return

	# For FFT shader, initialize global uniforms first
	if _quality == QualityMode.FFT:
		var water_col := Color(0.1, 0.15, 0.18, 1.0)
		var foam_col := Color(0.9, 0.9, 0.9, 1.0)
		RenderingServer.global_shader_parameter_set(&"water_color", water_col.srgb_to_linear())
		RenderingServer.global_shader_parameter_set(&"foam_color", foam_col.srgb_to_linear())
		print("[OceanMesh] Initialized global shader parameters for FFT shader")

	_material.shader = _shader

	# Set common uniform values
	_material.set_shader_parameter("water_color", Color(0.1, 0.15, 0.18, 1.0))
	_material.set_shader_parameter("roughness", 0.3)

	# FFT-specific uniforms
	if _quality == QualityMode.FFT:
		_material.set_shader_parameter("foam_color", Color(0.9, 0.9, 0.9, 1.0))
		_material.set_shader_parameter("normal_strength", 1.0)
		_material.set_shader_parameter("time", 0.0)

	material_override = _material
	print("[OceanMesh] Material created - shader: %s" % [
		_shader.resource_path if _shader else "INLINE"])


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

		outer_radius = minf(outer_radius, radius)

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

	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	normals.fill(Vector3.UP)
	arrays[Mesh.ARRAY_NORMAL] = normals

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	mesh = array_mesh

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

		for i in range(num_segments):
			var angle := float(i) / float(num_segments) * TAU
			var cos_a := cos(angle)
			var sin_a := sin(angle)

			vertices.append(Vector3(cos_a * inner_radius, 0.0, sin_a * inner_radius))
			uvs.append(Vector2(cos_a * inner_radius, sin_a * inner_radius))

			vertices.append(Vector3(cos_a * outer_radius, 0.0, sin_a * outer_radius))
			uvs.append(Vector2(cos_a * outer_radius, sin_a * outer_radius))

		for i in range(num_segments):
			var next := (i + 1) % num_segments
			var i0 := i * 2 + vertex_offset
			var i1 := i * 2 + 1 + vertex_offset
			var i2 := next * 2 + vertex_offset
			var i3 := next * 2 + 1 + vertex_offset

			indices.append(i0)
			indices.append(i2)
			indices.append(i1)

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


func set_camera_position(pos: Vector3) -> void:
	if _material:
		_material.set_shader_parameter("camera_position_world", pos)


func set_shader_time(time: float) -> void:
	if _material:
		_material.set_shader_parameter("time", time)


func set_wave_scale(scale: float) -> void:
	_cached_wave_scale = scale
	if _material:
		_material.set_shader_parameter("wave_scale", scale)


func set_water_color(color: Color) -> void:
	_cached_water_color = color
	if _material:
		_material.set_shader_parameter("water_color", color)
	RenderingServer.global_shader_parameter_set(&"water_color", color.srgb_to_linear())


func set_foam_color(color: Color) -> void:
	_cached_foam_color = color
	if _material:
		_material.set_shader_parameter("foam_color", color)
	RenderingServer.global_shader_parameter_set(&"foam_color", color.srgb_to_linear())


func set_depth_absorption(absorption: Vector3) -> void:
	_cached_depth_absorption = absorption
	if _material:
		_material.set_shader_parameter("depth_color_consumption", absorption)


## Set wave textures from GPU compute (Texture2DArrayRD)
## Only used in FFT mode
func set_wave_textures(displacements: Texture2DArrayRD, normals: Texture2DArrayRD, num_cascades: int = -1) -> void:
	if _quality != QualityMode.FFT:
		return

	if not displacements or not displacements.texture_rd_rid.is_valid():
		push_warning("[OceanMesh] Displacement texture RID is invalid")
		return
	if not normals or not normals.texture_rd_rid.is_valid():
		push_warning("[OceanMesh] Normal texture RID is invalid")
		return

	if num_cascades > 0:
		_num_cascades = num_cascades

	RenderingServer.global_shader_parameter_set(&"displacements", displacements)
	RenderingServer.global_shader_parameter_set(&"normals", normals)
	RenderingServer.global_shader_parameter_set(&"num_cascades", _num_cascades)
	print("[OceanMesh] Global shader parameters set - cascades: %d" % _num_cascades)

	# Set map scales
	var scales: PackedVector4Array
	scales.resize(_num_cascades)
	var default_scales := [
		Vector4(0.004, 0.004, 1.0, 1.0),   # 250m tile
		Vector4(0.015, 0.015, 0.5, 0.5),   # 67m tile
		Vector4(0.059, 0.059, 0.25, 0.25)  # 17m tile
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


func get_material() -> ShaderMaterial:
	return _material


## Get current quality mode
func get_quality() -> QualityMode:
	return _quality


## Get quality as HardwareDetection.WaterQuality for compatibility
func get_quality_compat() -> HardwareDetection.WaterQuality:
	return HardwareDetection.WaterQuality.HIGH if _quality == QualityMode.FFT else HardwareDetection.WaterQuality.ULTRA_LOW


## Check if using GPU compute (FFT mode)
func is_using_compute() -> bool:
	return _quality == QualityMode.FFT


## Set quality mode
## Returns true if switching to FFT (caller needs to reconnect wave textures)
func set_quality(quality: QualityMode, radius: float) -> bool:
	var old_quality := _quality
	_quality = quality

	if _quality == old_quality:
		return false

	_create_shader()
	_create_material()
	_restore_cached_state()

	print("[OceanMesh] Quality changed: %s -> %s" % [
		"FFT" if old_quality == QualityMode.FFT else "FLAT",
		"FFT" if _quality == QualityMode.FFT else "FLAT"])

	return _quality == QualityMode.FFT


## Restore cached shader parameters after quality change
func _restore_cached_state() -> void:
	if not _material:
		return

	if _cached_shore_mask:
		_material.set_shader_parameter("shore_mask", _cached_shore_mask)
		_material.set_shader_parameter("shore_mask_bounds", Vector4(
			_cached_shore_bounds.position.x,
			_cached_shore_bounds.position.y,
			_cached_shore_bounds.size.x,
			_cached_shore_bounds.size.y
		))

	_material.set_shader_parameter("water_color", _cached_water_color)

	if _quality == QualityMode.FFT:
		_material.set_shader_parameter("foam_color", _cached_foam_color)
		_material.set_shader_parameter("depth_color_consumption", _cached_depth_absorption)
		_material.set_shader_parameter("wave_scale", _cached_wave_scale)
		RenderingServer.global_shader_parameter_set(&"water_color", _cached_water_color.srgb_to_linear())
		RenderingServer.global_shader_parameter_set(&"foam_color", _cached_foam_color.srgb_to_linear())

	_material.set_shader_parameter("debug_shore_mask", _debug_shore_mask)

	print("[OceanMesh] Restored cached state")


## Toggle debug visualization of shore mask
func set_debug_shore_mask(enabled: bool) -> void:
	_debug_shore_mask = enabled
	if _material:
		_material.set_shader_parameter("debug_shore_mask", enabled)
		print("[OceanMesh] Debug shore mask: %s" % enabled)


## Get current debug shore mask state
func is_debug_shore_mask() -> bool:
	return _debug_shore_mask
