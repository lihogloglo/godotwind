## OceanMesh - Clipmap mesh for ocean surface rendering
## Creates a multi-LOD mesh that follows the camera
## Inner rings are high detail, outer rings are lower detail
##
## Two quality modes:
## - STANDARD: Analytical multi-octave Gerstner waves via ocean_standard.gdshader
## - FLAT: Simple flat plane with basic lighting (software renderer fallback)
class_name OceanMesh
extends MeshInstance3D

# Clipmap configuration
const NUM_LOD_RINGS: int = 11
const BASE_QUAD_SIZE: float = 2.0  # Innermost ring quad size in meters
const RING_VERTEX_COUNT: int = 64   # Vertices per side for each ring

enum QualityMode { FLAT, STANDARD }

# Shader state
var _material: ShaderMaterial = null
var _shader: Shader = null
var _quality: QualityMode = QualityMode.STANDARD

# Cached state for quality switching
var _cached_shore_mask: Texture2D = null
var _cached_shore_bounds: Rect2 = Rect2()
var _cached_wave_scale: float = 1.0
var _cached_foam_texture: Texture2D = null
var _debug_shore_mask: bool = false


func initialize(radius: float, quality_override: int = -1) -> void:
	_select_quality(quality_override)
	_create_shader()
	_create_material()
	_create_clipmap_mesh(radius)

	var mode_name := "Standard (Gerstner)" if _quality == QualityMode.STANDARD else "Flat"
	Log.info("water", "OceanMesh: Initialized - radius: %.0fm, mode: %s" % [radius, mode_name])


func _select_quality(quality_override: int) -> void:
	if quality_override == 0:
		_quality = QualityMode.FLAT
		Log.info("water", "OceanMesh: Quality override: FLAT")
	elif quality_override >= 1:
		_quality = QualityMode.STANDARD
		Log.info("water", "OceanMesh: Quality override: STANDARD")
	else:
		# Auto-detect based on hardware
		HardwareDetection.detect()
		var recommended := HardwareDetection.get_recommended_quality()
		if recommended == HardwareDetection.WaterQuality.ULTRA_LOW:
			_quality = QualityMode.FLAT
		else:
			_quality = QualityMode.STANDARD
		Log.info("water", "OceanMesh: Auto-detected quality: %s (GPU: %s)" % [
			"STANDARD" if _quality == QualityMode.STANDARD else "FLAT",
			HardwareDetection.get_gpu_name()])


func _create_shader() -> void:
	match _quality:
		QualityMode.STANDARD:
			var shader_path := "res://src/core/water/shaders/ocean_standard.gdshader"
			_shader = load(shader_path) as Shader
			if not _shader:
				Log.warn("water", "OceanMesh: Standard shader not found, falling back to flat")
				_quality = QualityMode.FLAT
				_create_shader()
				return
			Log.info("water", "OceanMesh: Using ocean_standard.gdshader")

		QualityMode.FLAT:
			_shader = _create_inline_flat_shader()
			Log.info("water", "OceanMesh: Using inline flat shader")


func _create_inline_flat_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode depth_draw_opaque, cull_disabled;

uniform vec4 water_color : source_color = vec4(0.1, 0.15, 0.18, 1.0);
uniform float roughness = 0.3;
uniform sampler2D shore_mask : hint_default_white, filter_linear;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);

varying float shore_factor;

float sample_shore(vec2 world_xz) {
	vec2 uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 1.0;
	}
	return texture(shore_mask, uv).r;
}

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	shore_factor = sample_shore(world_pos.xz);
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

	_material.shader = _shader

	if _quality == QualityMode.STANDARD:
		_setup_standard_defaults()
	# FLAT shader has sensible defaults in its code

	material_override = _material
	Log.debug("water", "OceanMesh: Material created - mode: %s" % (
		"STANDARD" if _quality == QualityMode.STANDARD else "FLAT"))


func _setup_standard_defaults() -> void:
	if not _material:
		return

	# Load foam texture (procedural fallback if not found)
	var foam_tex := _load_foam_texture()
	_material.set_shader_parameter("foam_texture", foam_tex)
	_cached_foam_texture = foam_tex

	# Set a default white shore mask so water renders everywhere
	# (until a real shore mask is provided via set_shore_mask)
	var white_img := Image.create(1, 1, false, Image.FORMAT_L8)
	white_img.set_pixel(0, 0, Color.WHITE)
	var white_tex := ImageTexture.create_from_image(white_img)
	_material.set_shader_parameter("shore_mask", white_tex)

	Log.debug("water", "OceanMesh: Standard shader defaults configured")


func _load_foam_texture() -> Texture2D:
	var path := "res://src/core/water/textures/foam_albedo.png"
	if ResourceLoader.exists(path):
		var tex := load(path) as Texture2D
		if tex:
			return tex

	# Procedural fallback: cellular noise for foam
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	noise.frequency = 0.04
	noise.seed = 11111

	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.seamless = true
	tex.seamless_blend_skirt = 0.3
	tex.width = 256
	tex.height = 256
	return tex


# ============================================================================
# CLIPMAP MESH CREATION
# ============================================================================

func _create_clipmap_mesh(radius: float) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var vertex_offset := 0
	var prev_outer_radius := 0.0

	for ring in range(NUM_LOD_RINGS):
		var quad_size := BASE_QUAD_SIZE * pow(2.0, float(ring))
		var inner_radius := prev_outer_radius
		var outer_radius := quad_size * RING_VERTEX_COUNT * 0.5
		outer_radius = minf(outer_radius, radius)

		if outer_radius <= inner_radius:
			continue

		var ring_data := _create_ring(inner_radius, outer_radius, quad_size, vertex_offset)
		var ring_verts: PackedVector3Array = ring_data.vertices
		var ring_uvs: PackedVector2Array = ring_data.uvs
		var ring_indices: PackedInt32Array = ring_data.indices
		vertices.append_array(ring_verts)
		uvs.append_array(ring_uvs)
		indices.append_array(ring_indices)
		vertex_offset += ring_verts.size()
		prev_outer_radius = outer_radius

	if vertices.size() == 0:
		push_error("[OceanMesh] No vertices created! Radius: %.0f" % radius)
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

	Log.debug("water", "OceanMesh: Created mesh with %d vertices, %d triangles" % [
		vertices.size(), indices.size() / 3])


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


# ============================================================================
# PUBLIC API
# ============================================================================

func update_position(center: Vector3) -> void:
	global_position = center


func set_wave_scale(scale: float) -> void:
	_cached_wave_scale = scale
	if _material:
		_material.set_shader_parameter("wave_scale", scale)


func set_shore_mask(mask: Texture2D, world_bounds: Rect2) -> void:
	_cached_shore_mask = mask
	_cached_shore_bounds = world_bounds
	if _material:
		_material.set_shader_parameter("shore_mask", mask)
		_material.set_shader_parameter("shore_mask_bounds", Vector4(
			world_bounds.position.x,
			world_bounds.position.y,
			world_bounds.size.x,
			world_bounds.size.y
		))
		Log.debug("water", "OceanMesh: Shore mask set - texture: %s, bounds: %s" % [
			mask.get_size() if mask else "null",
			world_bounds])


func set_debug_shore_mask(enabled: bool) -> void:
	_debug_shore_mask = enabled
	# Not supported in the new standard shader, but keep API for future use
	Log.debug("water", "OceanMesh: Debug shore mask: %s" % enabled)


func get_material() -> ShaderMaterial:
	return _material


func get_quality() -> QualityMode:
	return _quality


## Set quality mode. Returns false (no wave texture reconnection needed).
func set_quality(quality: QualityMode, radius: float) -> bool:
	var old_quality := _quality
	_quality = quality
	if _quality == old_quality:
		return false

	_create_shader()
	_create_material()
	_restore_cached_state()

	Log.info("water", "OceanMesh: Quality changed: %s -> %s" % [
		"STANDARD" if old_quality == QualityMode.STANDARD else "FLAT",
		"STANDARD" if _quality == QualityMode.STANDARD else "FLAT"])
	return false


func _restore_cached_state() -> void:
	if not _material:
		return

	# Shore mask is common to all modes
	if _cached_shore_mask:
		set_shore_mask(_cached_shore_mask, _cached_shore_bounds)

	if _cached_wave_scale != 1.0:
		set_wave_scale(_cached_wave_scale)

	if _quality == QualityMode.STANDARD and _cached_foam_texture:
		_material.set_shader_parameter("foam_texture", _cached_foam_texture)
