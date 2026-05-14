## OceanMesh - Clipmap mesh for ocean surface rendering
## Creates a multi-LOD mesh that follows the camera
## Inner rings are high detail, outer rings are lower detail
##
## Two quality modes:
## - FLAT: Simple flat plane with basic lighting (software renderer fallback)
## - HIGH: FFT compute ocean via ocean_fft.gdshader (JONSWAP spectrum, multi-cascade)
class_name OceanMesh
extends MeshInstance3D

# Clipmap configuration. HIGH/FFT gets denser near-camera geometry so the
# shore-wave breaker profile has enough vertices; FLAT keeps the lighter legacy
# mesh for low-end hardware.
const LEGACY_NUM_LOD_RINGS: int = 11
const LEGACY_BASE_QUAD_SIZE: float = 2.0
const LEGACY_RING_VERTEX_COUNT: int = 64
const HIGH_NUM_LOD_RINGS: int = 12
const HIGH_BASE_QUAD_SIZE: float = 1.0
const HIGH_RING_VERTEX_COUNT: int = 80

# Projected grid configuration — single flat N×N mesh in local [0,1]²; the
# vertex shader unprojects each vertex from NDC → world via INV_VIEW_PROJECTION
# and ray-intersects the water plane. 192 = ~36k vertices, kept as a stable
# comparison path while FFT clipmap density is tuned independently.
const PROJECTED_GRID_DIM: int = 192
const PROJECTED_GRID_OVERSCAN: float = 1.15

enum QualityMode { FLAT, HIGH }
# MeshMode is independent of QualityMode. CLIPMAP is the 11-ring concentric
# mesh built by `_create_clipmap_mesh()`. PROJECTED is the Sea of Thieves /
# Wicked Engine flat grid + vertex-shader unproject path. PROJECTED is only
# meaningful in HIGH quality (FFT); FLAT ignores it.
enum MeshMode { CLIPMAP, PROJECTED }

# Shader state
var _material: ShaderMaterial = null
var _shader: Shader = null
var _quality: QualityMode = QualityMode.HIGH
var _mesh_mode: MeshMode = MeshMode.CLIPMAP

# Cached state for quality switching
var _cached_shore_mask: Texture2D = null
var _cached_shore_bounds: Rect2 = Rect2()
var _cached_wave_scale: float = 1.0
var _cached_foam_texture: Texture2D = null
var _debug_shore_mask: bool = false


func initialize(radius: float, quality_override: int = -1, mesh_mode: int = -1) -> void:
	_select_quality(quality_override)
	if mesh_mode >= 0:
		_mesh_mode = mesh_mode as MeshMode
	# Projected grid is FFT-only. Downgrade silently if the user asked for
	# PROJECTED at flat quality.
	if _mesh_mode == MeshMode.PROJECTED and _quality != QualityMode.HIGH:
		Log.warn("water", "OceanMesh: PROJECTED mesh mode requested but quality is not HIGH (FFT); falling back to CLIPMAP")
		_mesh_mode = MeshMode.CLIPMAP

	_create_shader()
	_create_material()
	if _mesh_mode == MeshMode.PROJECTED:
		_create_projected_mesh(radius)
	else:
		_create_clipmap_mesh(radius)

	Log.info("water", "OceanMesh: Initialized - radius: %.0fm, quality: %s, mesh: %s" % [
		radius, _quality_name(), _mesh_mode_name()])


func _select_quality(quality_override: int) -> void:
	if quality_override == 0:
		_quality = QualityMode.FLAT
		Log.info("water", "OceanMesh: Quality override: FLAT")
	elif quality_override > 0:
		_quality = QualityMode.HIGH
		Log.info("water", "OceanMesh: Quality override: HIGH (FFT)")
	else:
		# Auto-detect based on hardware
		HardwareDetection.detect()
		var recommended := HardwareDetection.get_recommended_quality()
		if recommended != HardwareDetection.WaterQuality.HIGH:
			_quality = QualityMode.FLAT
		else:
			_quality = QualityMode.HIGH
		Log.info("water", "OceanMesh: Auto-detected quality: %s (GPU: %s)" % [
			_quality_name(), HardwareDetection.get_gpu_name()])


func _create_shader() -> void:
	match _quality:
		QualityMode.HIGH:
			# Pick the FFT shader matching the current mesh mode. Both shaders
			# share `ocean_fft_common.gdshaderinc` — fragment + light + all
			# uniforms — so switching mesh mode is literally just swapping
			# the vertex path.
			var shader_path := "res://src/core/water/shaders/ocean_fft.gdshader"
			if _mesh_mode == MeshMode.PROJECTED:
				shader_path = "res://src/core/water/shaders/ocean_fft_projected.gdshader"
			_shader = load(shader_path) as Shader
			if not _shader:
				Log.warn("water", "OceanMesh: FFT shader not found at %s, falling back to flat" % shader_path)
				_quality = QualityMode.FLAT
				_create_shader()
				return
			Log.info("water", "OceanMesh: Using %s" % shader_path.get_file())

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

void fragment() {
	float fresnel = mix(pow(1.0 - max(dot(VIEW, NORMAL), 0.0), 5.0), 1.0, 0.02);
	ALBEDO = water_color.rgb;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
}
"""
	return shader


func _create_material() -> void:
	_material = ShaderMaterial.new()
	if not _shader:
		push_error("[OceanMesh] No shader set!")
		return

	_material.shader = _shader

	if _quality == QualityMode.HIGH:
		_setup_fft_defaults()
	# FLAT shader has sensible defaults in its code

	material_override = _material
	Log.debug("water", "OceanMesh: Material created - mode: %s" % _quality_name())


func _setup_fft_defaults() -> void:
	if not _material:
		return

	var foam_tex := _load_foam_texture()
	_material.set_shader_parameter("foam_texture", foam_tex)
	_cached_foam_texture = foam_tex

	Log.debug("water", "OceanMesh: FFT shader defaults configured")


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

func _clipmap_ring_count() -> int:
	return HIGH_NUM_LOD_RINGS if _quality == QualityMode.HIGH else LEGACY_NUM_LOD_RINGS


func _clipmap_base_quad_size() -> float:
	return HIGH_BASE_QUAD_SIZE if _quality == QualityMode.HIGH else LEGACY_BASE_QUAD_SIZE


func _clipmap_ring_vertex_count() -> int:
	return HIGH_RING_VERTEX_COUNT if _quality == QualityMode.HIGH else LEGACY_RING_VERTEX_COUNT


func _clipmap_snap_size() -> float:
	return _clipmap_base_quad_size() * float(_clipmap_ring_vertex_count()) * 0.5


func _create_clipmap_mesh(radius: float) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var vertex_offset := 0
	var prev_outer_radius := 0.0
	var ring_count := _clipmap_ring_count()
	var base_quad_size := _clipmap_base_quad_size()
	var ring_vertex_count := _clipmap_ring_vertex_count()

	for ring in range(ring_count):
		var quad_size := base_quad_size * pow(2.0, float(ring))
		# 2026-04-09 — clipmap seam fix. Successive rings have 2x quad_size
		# so the inner ring's outer edge has twice as many vertices as the
		# outer ring's inner edge, creating T-junctions. When the FFT
		# displacement lifts wave crests and `depth_draw_always` is honest
		# about depth (prior fix), those T-junctions surface as gaping
		# holes at ring boundaries. Canonical fix = CDLOD quadtree morph,
		# tracked for a later session. Interim: overlap rings 1+ inward
		# by one outer-ring quad so the fine inner ring and coarse outer
		# ring share a covered strip. Both rings sample the same
		# displacement at the same world XZ, so the vertices land at the
		# same Y — no z-fighting, just twice the triangle work in a thin
		# band. Ring 0 stays centered on origin (its inner_radius is 0).
		var inner_radius := prev_outer_radius
		if ring > 0:
			inner_radius = maxf(0.0, prev_outer_radius - quad_size)
		var outer_radius := quad_size * ring_vertex_count * 0.5
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
	# Custom AABB with Y extent for FFT wave displacement (flat mesh has zero Y extent)
	array_mesh.custom_aabb = AABB(Vector3(-radius, -50.0, -radius), Vector3(radius * 2.0, 100.0, radius * 2.0))
	mesh = array_mesh

	# Prevent false frustum/occlusion culling at distance and altitude
	extra_cull_margin = radius

	Log.info("water", "OceanMesh: Created mesh with %d vertices, %d triangles, %d rings" % [
		vertices.size(), indices.size() / 3, ring_count])


# ============================================================================
# PROJECTED GRID MESH CREATION
# ============================================================================
# Single flat N×N grid in local [0,1]² coordinates. The vertex shader unprojects
# each vertex from NDC → world ray → water plane intersection, so the mesh
# itself stays at origin with identity transform. Its job is just to provide
# PROJECTED_GRID_DIM² × 2 triangles worth of vertex-shader invocations.
#
# `custom_aabb` is set to an enormous box so the MeshInstance3D never gets
# frustum-culled regardless of where the camera is. Without this Godot would
# test the [0,1]² box against the frustum and cull the mesh away as soon as
# the camera stopped being inside the tiny local volume.
#
# Reference: Claes Johanson 2004, Wicked Engine `oceanSurfaceVS.hlsl`.

func _create_projected_mesh(radius: float) -> void:
	var dim := PROJECTED_GRID_DIM
	var vert_count := (dim + 1) * (dim + 1)
	var quad_count := dim * dim

	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	vertices.resize(vert_count)
	uvs.resize(vert_count)
	indices.resize(quad_count * 6)

	var inv_dim := 1.0 / float(dim)
	var vi := 0
	for z in range(dim + 1):
		for x in range(dim + 1):
			var u := float(x) * inv_dim
			var v := float(z) * inv_dim
			# Local grid position in [0,1]². Shader reads VERTEX.xz as the
			# normalized NDC seed.
			vertices[vi] = Vector3(u, 0.0, v)
			uvs[vi] = Vector2(u, v)
			vi += 1

	var ii := 0
	for z in range(dim):
		for x in range(dim):
			var i00 := z * (dim + 1) + x
			var i10 := i00 + 1
			var i01 := i00 + (dim + 1)
			var i11 := i01 + 1
			indices[ii + 0] = i00
			indices[ii + 1] = i01
			indices[ii + 2] = i10
			indices[ii + 3] = i10
			indices[ii + 4] = i01
			indices[ii + 5] = i11
			ii += 6

	var normals := PackedVector3Array()
	normals.resize(vert_count)
	normals.fill(Vector3.UP)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	arrays[Mesh.ARRAY_NORMAL] = normals

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# Enormous custom AABB — the vertex shader writes world positions anywhere
	# in space, so frustum culling based on the local mesh bounds is wrong.
	# 1e6 meters on each axis is safely beyond any realistic camera view.
	array_mesh.custom_aabb = AABB(
		Vector3(-1.0e6, -1.0e4, -1.0e6),
		Vector3( 2.0e6,  2.0e4,  2.0e6)
	)
	mesh = array_mesh

	# Belt-and-suspenders: in case a scene camera has a very tight frustum,
	# force a huge cull margin too.
	extra_cull_margin = 1.0e6

	Log.info("water", "OceanMesh: Created projected grid - %d×%d (%d vertices, %d triangles)" % [
		dim, dim, vert_count, quad_count * 2])


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
		# Outer ring - square annulus (4 rectangular strips forming a square donut)
		# Matches the square inner ring geometry — no gaps at diagonal angles
		var strip_width := outer_radius - inner_radius
		var strip_quads := maxi(int(strip_width / quad_size), 1)
		var inner_quads := maxi(int(inner_radius * 2.0 / quad_size), 1)
		var outer_quads := maxi(int(outer_radius * 2.0 / quad_size), 1)

		# 4 strips: top, bottom (full width), left, right (inner height only)
		var strips: Array[Dictionary] = [
			{"x0": -outer_radius, "z0": inner_radius, "nx": outer_quads, "nz": strip_quads},
			{"x0": -outer_radius, "z0": -outer_radius, "nx": outer_quads, "nz": strip_quads},
			{"x0": -outer_radius, "z0": -inner_radius, "nx": strip_quads, "nz": inner_quads},
			{"x0": inner_radius, "z0": -inner_radius, "nx": strip_quads, "nz": inner_quads},
		]

		for strip in strips:
			var x0: float = strip["x0"]
			var z0: float = strip["z0"]
			var nx: int = strip["nx"]
			var nz: int = strip["nz"]

			var strip_offset := vertices.size() + vertex_offset
			for z in range(nz + 1):
				for x in range(nx + 1):
					var pos := Vector3(x0 + x * quad_size, 0.0, z0 + z * quad_size)
					vertices.append(pos)
					uvs.append(Vector2(pos.x, pos.z))

			for z in range(nz):
				for x in range(nx):
					var i := z * (nx + 1) + x + strip_offset
					indices.append(i)
					indices.append(i + nx + 1)
					indices.append(i + 1)
					indices.append(i + 1)
					indices.append(i + nx + 1)
					indices.append(i + nx + 2)

	return {
		"vertices": vertices,
		"uvs": uvs,
		"indices": indices
	}


# ============================================================================
# PUBLIC API
# ============================================================================

func update_position(center: Vector3) -> void:
	# In PROJECTED mode the mesh stays at origin — the vertex shader unprojects
	# the camera's NDC and intersects the water plane, so "moving" the mesh is
	# a no-op (and would actually break things by pushing the mesh out from
	# under its enormous custom AABB).
	if _mesh_mode == MeshMode.PROJECTED:
		return
	# CLIPMAP mode: snap mesh position to the inner ring half-size to prevent
	# vertex swimming. Vertices stay stable between rare jumps.
	# Must move mesh (not shader offset) so Godot's AABB frustum culling stays correct.
	var snap_size := _clipmap_snap_size()
	global_position = Vector3(
		snappedf(center.x, snap_size),
		center.y,
		snappedf(center.z, snap_size)
	)


func get_mesh_mode() -> MeshMode:
	return _mesh_mode


func get_clipmap_origin() -> Vector2:
	return Vector2(global_position.x, global_position.z)


func get_clipmap_base_quad_size() -> float:
	return _clipmap_base_quad_size()


func get_clipmap_ring_vertex_count() -> int:
	return _clipmap_ring_vertex_count()


func get_clipmap_ring_count() -> int:
	return _clipmap_ring_count()


func get_projected_grid_dim() -> int:
	return PROJECTED_GRID_DIM


func get_projected_grid_overscan() -> float:
	return PROJECTED_GRID_OVERSCAN


func _mesh_mode_name() -> String:
	return "Projected" if _mesh_mode == MeshMode.PROJECTED else "Clipmap"


func set_wave_scale(scale: float) -> void:
	_cached_wave_scale = scale
	if _material:
		_material.set_shader_parameter("wave_scale", scale)


func set_shore_mask(mask: Texture2D, world_bounds: Rect2, fade_distance: float = 50.0) -> void:
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
		_material.set_shader_parameter("shore_fade_distance", fade_distance)
		Log.debug("water", "OceanMesh: Shore mask set - texture: %s, bounds: %s, fade: %.0fm" % [
			mask.get_size() if mask else "null",
			world_bounds, fade_distance])


func set_debug_shore_mask(enabled: bool) -> void:
	_debug_shore_mask = enabled
	Log.debug("water", "OceanMesh: Debug shore mask: %s" % enabled)


func get_material() -> ShaderMaterial:
	return _material


func get_quality() -> QualityMode:
	return _quality


## Set quality mode. Returns true if FFT pipeline needs (re)connection.
func set_quality(quality: QualityMode, radius: float) -> bool:
	var old_quality := _quality
	_quality = quality
	if _quality == old_quality:
		return false

	_create_shader()
	_create_material()
	if _mesh_mode == MeshMode.PROJECTED and _quality != QualityMode.HIGH:
		_mesh_mode = MeshMode.CLIPMAP
	if _mesh_mode == MeshMode.PROJECTED:
		_create_projected_mesh(radius)
	else:
		_create_clipmap_mesh(radius)
	_restore_cached_state()

	var needs_fft := (_quality == QualityMode.HIGH)
	Log.info("water", "OceanMesh: Quality changed: %s -> %s" % [
		_quality_name_for(old_quality), _quality_name()])
	return needs_fft


func _restore_cached_state() -> void:
	if not _material:
		return

	# Shore mask is common to all modes
	if _cached_shore_mask:
		set_shore_mask(_cached_shore_mask, _cached_shore_bounds)

	if _cached_wave_scale != 1.0:
		set_wave_scale(_cached_wave_scale)

	if _quality == QualityMode.HIGH and _cached_foam_texture:
		_material.set_shader_parameter("foam_texture", _cached_foam_texture)


func _quality_name() -> String:
	return _quality_name_for(_quality)


static func _quality_name_for(q: QualityMode) -> String:
	match q:
		QualityMode.HIGH:
			return "High (FFT)"
		_:
			return "Flat"
