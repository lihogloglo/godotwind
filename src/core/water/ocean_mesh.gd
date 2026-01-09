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
var _cached_sun_direction: Vector3 = Vector3(0.5, 0.7, 0.5)
var _cached_sun_fade: float = 1.0
var _cached_rain_intensity: float = 0.0
var _debug_shore_mask: bool = false

# New visual features
var _cached_sparkle_intensity: float = 1.5
var _cached_caustic_intensity: float = 0.7
var _cached_bubble_intensity: float = 0.5
var _cached_color_gradient: Texture2D = null
var _cached_sparkle_map: Texture2D = null
var _cached_bubble_texture: Texture2D = null


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
			shader_path = "res://src/core/water/shaders/flat_water.gdshader"
			_shader = load(shader_path) as Shader
			if not _shader:
				push_warning("[OceanMesh] Flat water shader not found, using inline")
				_shader = _create_inline_flat_shader()
			else:
				print("[OceanMesh] Using flat water shader with SSR")


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


func _setup_fft_shader_defaults() -> void:
	## Set up default parameters for FFT shader
	## Note: Detail normals removed - FFT provides all wave detail
	## Unit conversion: 1 Morrowind unit ≈ 0.0138 meters
	if not _material:
		return

	# OpenMW-style visual defaults (converted to meters)
	_material.set_shader_parameter("roughness", 0.05)
	_material.set_shader_parameter("normal_strength", 1.0)
	_material.set_shader_parameter("refraction_strength", 0.07)  # OpenMW REFR_BUMP
	_material.set_shader_parameter("water_visibility", 34.5)  # 2500 MW ≈ 34.5m
	_material.set_shader_parameter("depth_fade", 10.0)  # Tuned for meters (OpenMW 0.15 was for MW units)
	_material.set_shader_parameter("shore_depth_scale", 4.0)  # 300 MW ≈ 4m

	# Scattering (OpenMW defaults)
	_material.set_shader_parameter("enable_sunlight_scattering", true)
	_material.set_shader_parameter("scatter_amount", 0.3)
	_material.set_shader_parameter("scatter_color", Color(0.0, 1.0, 0.95))
	_material.set_shader_parameter("sun_extinction", Color(0.45, 0.55, 0.68))

	# Wobbly shores (enabled by default) - 6200 MW ≈ 85m
	_material.set_shader_parameter("enable_wobbly_shores", true)
	_material.set_shader_parameter("wobbly_shore_fade_distance", 85.0)

	# SSR disabled by default (use environment reflections)
	_material.set_shader_parameter("enable_ssr", false)

	# Rain disabled by default
	_material.set_shader_parameter("enable_rain_ripples", false)
	_material.set_shader_parameter("rain_intensity", 0.0)

	# === NEW VISUAL FEATURES ===

	# Color gradient (disabled by default, uses shader's color_shallow/color_deep)
	_material.set_shader_parameter("use_color_gradient", false)
	_material.set_shader_parameter("color_gradient_depth", 20.0)

	# Sparkles (sun glints on wave peaks)
	_material.set_shader_parameter("enable_sparkles", true)
	_material.set_shader_parameter("sparkle_intensity", _cached_sparkle_intensity)
	_material.set_shader_parameter("sparkle_speed", 0.05)
	_material.set_shader_parameter("sparkle_scale", 0.02)
	_setup_sparkle_texture()

	# Underwater caustics
	_material.set_shader_parameter("enable_caustics", true)
	_material.set_shader_parameter("caustic_intensity", _cached_caustic_intensity)
	_material.set_shader_parameter("caustic_scale", 0.025)
	_material.set_shader_parameter("caustic_speed", 1.8)

	# Bubble layer foam enhancement
	_material.set_shader_parameter("enable_bubbles", true)
	_material.set_shader_parameter("bubble_intensity", _cached_bubble_intensity)
	_material.set_shader_parameter("bubble_scale", 8.0)
	_material.set_shader_parameter("flow_speed", 0.5)
	_setup_bubble_texture()

	print("[OceanMesh] FFT shader defaults configured with enhanced visuals")


func _setup_sparkle_texture() -> void:
	## Create procedural sparkle/highlight noise texture
	if _cached_sparkle_map:
		_material.set_shader_parameter("sparkle_map", _cached_sparkle_map)
		return

	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_VALUE
	noise.frequency = 0.1
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	noise.seed = 55555

	var sparkle_tex := NoiseTexture2D.new()
	sparkle_tex.noise = noise
	sparkle_tex.seamless = true
	sparkle_tex.seamless_blend_skirt = 0.3
	sparkle_tex.width = 256
	sparkle_tex.height = 256

	_cached_sparkle_map = sparkle_tex
	_material.set_shader_parameter("sparkle_map", sparkle_tex)


func _setup_bubble_texture() -> void:
	## Create procedural bubble texture (cellular noise for foam look)
	if _cached_bubble_texture:
		_material.set_shader_parameter("bubble_texture", _cached_bubble_texture)
		return

	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	noise.frequency = 0.08
	noise.seed = 66666

	var bubble_tex := NoiseTexture2D.new()
	bubble_tex.noise = noise
	bubble_tex.seamless = true
	bubble_tex.seamless_blend_skirt = 0.3
	bubble_tex.width = 256
	bubble_tex.height = 256

	_cached_bubble_texture = bubble_tex
	_material.set_shader_parameter("bubble_texture", bubble_tex)


func _setup_flat_water_textures() -> void:
	## Set up noise textures for flat water shader
	## The shader expects: normal1tex, normal2tex, height1tex, height2tex, edge1tex, edge2tex
	if not _material:
		return

	# Generate procedural normal textures (two layers for animation blend)
	var normal_noise1 := FastNoiseLite.new()
	normal_noise1.noise_type = FastNoiseLite.TYPE_PERLIN
	normal_noise1.frequency = 0.02
	normal_noise1.fractal_type = FastNoiseLite.FRACTAL_FBM
	normal_noise1.fractal_octaves = 4
	normal_noise1.seed = 12345

	var normal_tex1 := NoiseTexture2D.new()
	normal_tex1.noise = normal_noise1
	normal_tex1.seamless = true
	normal_tex1.seamless_blend_skirt = 0.3
	normal_tex1.as_normal_map = true
	normal_tex1.bump_strength = 8.0
	normal_tex1.width = 512
	normal_tex1.height = 512

	var normal_noise2 := FastNoiseLite.new()
	normal_noise2.noise_type = FastNoiseLite.TYPE_PERLIN
	normal_noise2.frequency = 0.03
	normal_noise2.fractal_type = FastNoiseLite.FRACTAL_FBM
	normal_noise2.fractal_octaves = 3
	normal_noise2.seed = 67890

	var normal_tex2 := NoiseTexture2D.new()
	normal_tex2.noise = normal_noise2
	normal_tex2.seamless = true
	normal_tex2.seamless_blend_skirt = 0.3
	normal_tex2.as_normal_map = true
	normal_tex2.bump_strength = 6.0
	normal_tex2.width = 512
	normal_tex2.height = 512

	# Generate height textures for vertex displacement
	var height_noise1 := FastNoiseLite.new()
	height_noise1.noise_type = FastNoiseLite.TYPE_PERLIN
	height_noise1.frequency = 0.01
	height_noise1.fractal_type = FastNoiseLite.FRACTAL_FBM
	height_noise1.fractal_octaves = 2
	height_noise1.seed = 11111

	var height_tex1 := NoiseTexture2D.new()
	height_tex1.noise = height_noise1
	height_tex1.seamless = true
	height_tex1.width = 256
	height_tex1.height = 256

	var height_noise2 := FastNoiseLite.new()
	height_noise2.noise_type = FastNoiseLite.TYPE_PERLIN
	height_noise2.frequency = 0.015
	height_noise2.fractal_type = FastNoiseLite.FRACTAL_FBM
	height_noise2.fractal_octaves = 2
	height_noise2.seed = 22222

	var height_tex2 := NoiseTexture2D.new()
	height_tex2.noise = height_noise2
	height_tex2.seamless = true
	height_tex2.width = 256
	height_tex2.height = 256

	# Generate edge/foam textures
	var edge_noise1 := FastNoiseLite.new()
	edge_noise1.noise_type = FastNoiseLite.TYPE_CELLULAR
	edge_noise1.frequency = 0.05
	edge_noise1.seed = 33333

	var edge_tex1 := NoiseTexture2D.new()
	edge_tex1.noise = edge_noise1
	edge_tex1.seamless = true
	edge_tex1.width = 256
	edge_tex1.height = 256

	var edge_noise2 := FastNoiseLite.new()
	edge_noise2.noise_type = FastNoiseLite.TYPE_CELLULAR
	edge_noise2.frequency = 0.04
	edge_noise2.seed = 44444

	var edge_tex2 := NoiseTexture2D.new()
	edge_tex2.noise = edge_noise2
	edge_tex2.seamless = true
	edge_tex2.width = 256
	edge_tex2.height = 256

	# Set shader uniforms (matching flat_water.gdshader uniform names)
	_material.set_shader_parameter("normal1tex", normal_tex1)
	_material.set_shader_parameter("normal2tex", normal_tex2)
	_material.set_shader_parameter("height1tex", height_tex1)
	_material.set_shader_parameter("height2tex", height_tex2)
	_material.set_shader_parameter("edge1tex", edge_tex1)
	_material.set_shader_parameter("edge2tex", edge_tex2)

	# Water colors (shader uses surfacecolour/volumecolour)
	_material.set_shader_parameter("surfacecolour", Vector3(0.1, 0.3, 0.4))
	_material.set_shader_parameter("volumecolour", Vector3(0.0, 0.1, 0.2))

	# UV scaling - CRITICAL for large ocean mesh with world_vertex_coords
	# With world coords, UV = world_pos * samplerscale
	# For visible waves at human scale: 0.01 = 1 tile per 100m, 0.1 = 1 tile per 10m
	# Use 0.02 for nice wave visibility (1 tile per 50m)
	_material.set_shader_parameter("samplerscale", Vector2(0.02, 0.02))

	# Animation speeds (meters per second in world coords)
	_material.set_shader_parameter("sampler1speed", Vector2(0.02, 0.0))
	_material.set_shader_parameter("sampler2speed", Vector2(0.0, 0.02))

	# Normal and height strength
	_material.set_shader_parameter("normalstrength", 1.5)
	_material.set_shader_parameter("heightstrength", 0.3)

	# Refraction
	_material.set_shader_parameter("refrationamount", 0.3)

	# Edge foam
	_material.set_shader_parameter("edge_size", 0.1)
	_material.set_shader_parameter("foam_or_fade", false)

	# SSR settings
	_material.set_shader_parameter("far_clip", 50.0)
	_material.set_shader_parameter("steps", 256)  # Reduced from 512 for performance
	_material.set_shader_parameter("ssr_screen_fade", 0.05)

	print("[OceanMesh] Flat water shader configured with proper uniforms")


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
	_material.set_shader_parameter("roughness", 0.25)

	# Mode-specific uniforms
	if _quality == QualityMode.FFT:
		_material.set_shader_parameter("water_color", Color(0.09, 0.116, 0.127, 1.0))  # OpenMW WATER_COLOR
		_material.set_shader_parameter("foam_color", Color(0.9, 0.9, 0.9, 1.0))
		_material.set_shader_parameter("sun_direction", _cached_sun_direction)
		_material.set_shader_parameter("sun_fade", _cached_sun_fade)
		_material.set_shader_parameter("rain_intensity", _cached_rain_intensity)
		# Set up FFT shader defaults (no detail normals needed)
		_setup_fft_shader_defaults()
	else:
		# FLAT mode - set up noise textures for waves and normals
		_setup_flat_water_textures()

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
		var ring_verts: PackedVector3Array = ring_data.vertices
		var ring_uvs: PackedVector2Array = ring_data.uvs
		var ring_indices: PackedInt32Array = ring_data.indices
		vertices.append_array(ring_verts)
		uvs.append_array(ring_uvs)
		indices.append_array(ring_indices)
		vertex_offset += ring_verts.size()
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
		_material.set_shader_parameter("sun_direction", _cached_sun_direction)
		_material.set_shader_parameter("sun_fade", _cached_sun_fade)
		_material.set_shader_parameter("rain_intensity", _cached_rain_intensity)
		_material.set_shader_parameter("enable_rain_ripples", _cached_rain_intensity > 0.01)
		RenderingServer.global_shader_parameter_set(&"water_color", _cached_water_color.srgb_to_linear())
		RenderingServer.global_shader_parameter_set(&"foam_color", _cached_foam_color.srgb_to_linear())

		# Restore new visual features
		_material.set_shader_parameter("sparkle_intensity", _cached_sparkle_intensity)
		_material.set_shader_parameter("caustic_intensity", _cached_caustic_intensity)
		_material.set_shader_parameter("bubble_intensity", _cached_bubble_intensity)
		if _cached_color_gradient:
			_material.set_shader_parameter("water_color_gradient", _cached_color_gradient)
			_material.set_shader_parameter("use_color_gradient", true)
		if _cached_sparkle_map:
			_material.set_shader_parameter("sparkle_map", _cached_sparkle_map)
		if _cached_bubble_texture:
			_material.set_shader_parameter("bubble_texture", _cached_bubble_texture)

		# Apply FFT shader defaults
		_setup_fft_shader_defaults()

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


## Set sun direction for sunlight scattering effect
func set_sun_direction(direction: Vector3) -> void:
	_cached_sun_direction = direction.normalized()
	if _material and _quality == QualityMode.FFT:
		_material.set_shader_parameter("sun_direction", _cached_sun_direction)


## Set sun fade (ambient light level, 0.0 = night, 1.0 = full day)
func set_sun_fade(fade: float) -> void:
	_cached_sun_fade = clampf(fade, 0.0, 1.0)
	if _material and _quality == QualityMode.FFT:
		_material.set_shader_parameter("sun_fade", _cached_sun_fade)


## Set rain intensity for rain ripples effect (0.0 - 1.0)
func set_rain_intensity(intensity: float) -> void:
	_cached_rain_intensity = clampf(intensity, 0.0, 1.0)
	if _material and _quality == QualityMode.FFT:
		_material.set_shader_parameter("rain_intensity", _cached_rain_intensity)
		_material.set_shader_parameter("enable_rain_ripples", intensity > 0.01)


## Enable/disable sunlight scattering
func set_sunlight_scattering_enabled(enabled: bool) -> void:
	if _material and _quality == QualityMode.FFT:
		_material.set_shader_parameter("enable_sunlight_scattering", enabled)


## Enable/disable wobbly shores
func set_wobbly_shores_enabled(enabled: bool) -> void:
	if _material and _quality == QualityMode.FFT:
		_material.set_shader_parameter("enable_wobbly_shores", enabled)


## Enable/disable SSR (screen-space reflections)
## Note: SSR is expensive, disabled by default. Use environment reflections instead.
func set_ssr_enabled(enabled: bool) -> void:
	if _material and _quality == QualityMode.FFT:
		_material.set_shader_parameter("enable_ssr", enabled)
		print("[OceanMesh] SSR %s (WARNING: expensive!)" % ("enabled" if enabled else "disabled"))


# =============================================================================
# NEW VISUAL FEATURES API
# =============================================================================

## Set water color gradient texture (1D gradient, X = depth)
## Pass null to disable and use color_shallow/color_deep interpolation
func set_color_gradient(gradient_texture: Texture2D) -> void:
	_cached_color_gradient = gradient_texture
	if _material and _quality == QualityMode.FFT:
		if gradient_texture:
			_material.set_shader_parameter("water_color_gradient", gradient_texture)
			_material.set_shader_parameter("use_color_gradient", true)
		else:
			_material.set_shader_parameter("use_color_gradient", false)


## Set color gradient depth (how deep until full deep color)
func set_color_gradient_depth(depth: float) -> void:
	if _material and _quality == QualityMode.FFT:
		_material.set_shader_parameter("color_gradient_depth", depth)


## Set shallow/deep colors (when not using gradient texture)
func set_water_colors(shallow: Color, deep: Color) -> void:
	if _material and _quality == QualityMode.FFT:
		_material.set_shader_parameter("color_shallow", Vector3(shallow.r, shallow.g, shallow.b))
		_material.set_shader_parameter("color_deep", Vector3(deep.r, deep.g, deep.b))


## Enable/disable sparkles (sun glints on wave peaks)
func set_sparkles_enabled(enabled: bool) -> void:
	if _material and _quality == QualityMode.FFT:
		_material.set_shader_parameter("enable_sparkles", enabled)


## Set sparkle intensity (0.0 - 5.0)
func set_sparkle_intensity(intensity: float) -> void:
	_cached_sparkle_intensity = clampf(intensity, 0.0, 5.0)
	if _material and _quality == QualityMode.FFT:
		_material.set_shader_parameter("sparkle_intensity", _cached_sparkle_intensity)


## Enable/disable underwater caustics
func set_caustics_enabled(enabled: bool) -> void:
	if _material and _quality == QualityMode.FFT:
		_material.set_shader_parameter("enable_caustics", enabled)


## Set caustic intensity (0.0 - 2.0)
func set_caustic_intensity(intensity: float) -> void:
	_cached_caustic_intensity = clampf(intensity, 0.0, 2.0)
	if _material and _quality == QualityMode.FFT:
		_material.set_shader_parameter("caustic_intensity", _cached_caustic_intensity)


## Enable/disable bubble foam layer
func set_bubbles_enabled(enabled: bool) -> void:
	if _material and _quality == QualityMode.FFT:
		_material.set_shader_parameter("enable_bubbles", enabled)


## Set bubble intensity (0.0 - 2.0)
func set_bubble_intensity(intensity: float) -> void:
	_cached_bubble_intensity = clampf(intensity, 0.0, 2.0)
	if _material and _quality == QualityMode.FFT:
		_material.set_shader_parameter("bubble_intensity", _cached_bubble_intensity)


## Set custom sparkle texture (overrides procedural generation)
func set_sparkle_texture(texture: Texture2D) -> void:
	_cached_sparkle_map = texture
	if _material and _quality == QualityMode.FFT:
		_material.set_shader_parameter("sparkle_map", texture)


## Set custom bubble texture (overrides procedural generation)
func set_bubble_texture(texture: Texture2D) -> void:
	_cached_bubble_texture = texture
	if _material and _quality == QualityMode.FFT:
		_material.set_shader_parameter("bubble_texture", texture)
