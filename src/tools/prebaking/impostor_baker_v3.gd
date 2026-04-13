## ImpostorBakerV3 - Octahedral impostor baker (bake_version = 5)
##
## Rebuild of ImpostorBakerV2 per `docs/audit/IMPOSTOR_REBUILD.md`. Replaces
## the misnamed v4 baker which was a 16-sample azimuthal billboard with no
## elevation variation. Targets the actual 7 audit bugs, nothing more.
##
## Design choices:
## - **Octahedral direction sampling**, hemi by default (correct for the 99%
##   of assets that are ground-rooted), with a per-asset `"sphere"` opt-in for
##   floating assets via `SPHERE_OVERRIDE_PATTERNS`. Framework-generic per the
##   user's requirement: anything that needs full-sphere views can opt in
##   without touching the rest of the pipeline.
## - **Single grid size for all assets** (8×8 = 64 views, 32 px frames →
##   256² atlas). Matches runtime texture array layer size directly.
##   Earlier versions had hero/prop tiering, which was bespoke complexity
##   for a problem we can solve with one well-chosen size. UE Impostor
##   Baker default is 8×8 hemi for vegetation; we adopt the same.
## - **Two viewports**: albedo with MSAA 4×, normal with MSAA off. The
##   v2 baker shared one MSAA viewport, which corrupted encoded normals on
##   silhouette edges (linear resolve averaging). Two viewports is simpler
##   than toggling msaa_3d on a single viewport (avoids render target
##   recreation churn). Normal viewport has NO Environment to keep any
##   future tonemap from touching the encoded normals.
## - **Normal atlas as `.res` ImageTexture, RGBA8**. Bypasses the PNG import
##   pipeline — no `.import` sidecar, no sRGB decode, bytes round-trip
##   exactly. Capture is RGBA8 end-to-end (Godot 4.6 SubViewport 3D render
##   target is RGBA8; storing as RGBA16F would be a false precision claim).
##   BC5 / true HDR capture are follow-ups, not phase 1.
##
## Output format (bake_version = 5):
## - Albedo atlas: `<name>_<hash>_v5.png` (RGBA8 sRGB).
## - Normal atlas: `<name>_<hash>_normal_v5.res` (ImageTexture RGBA8).
##     RGB = world-space normal encoded [0,1], A = linear depth [0,1].
## - Debug normal PNG: `<name>_<hash>_normal_debug_v5.png` (always written
##   for visual inspection — runtime loader ignores it).
## - Metadata JSON: `<name>_<hash>_v5.json` with:
##     "projection": "hemi" | "sphere"  (per-asset)
##     "grid_size": 8
##     "frame_size": 32
##     "normal_format": "rgba8_res"
##     "directions": flat list of unit Vector3 per cell (row-major)
##
## Runtime loader (native_impostor_renderer.gd) reads `bake_version` from
## metadata to pick between Variant A (legacy azimuthal 16-frame) and Variant
## B (octahedral nearest-neighbor). Variant B is phase 2 work — this file
## only produces v5 bakes, does not touch the runtime loader.
class_name ImpostorBakerV3
extends Node

const NIFConverter := preload("res://src/core/nif/nif_converter.gd")
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")

## Single grid configuration for all assets.
## 8×8 = 64 views, 32 px frames, 256² atlas. Matches the runtime texture array
## layer size (256×256) — no resize needed at load time, saves disk + memory.
##
## 32 px frames are adequate for FAR tier (1-5 km): a 10 m tree at 1 km
## occupies ~19 screen pixels at 60° FOV / 1080p; at 5 km it's < 4 px.
## Previous 64 px frames produced 512² atlases that the runtime downsampled
## to 256² anyway — wasted bake time and disk space.
const GRID_SIZE: int = 8
const FRAME_SIZE: int = 32

## Patterns that opt an asset into full-sphere projection instead of hemi.
## Hemi (upper hemisphere only) is correct for ground-rooted assets — the
## 99% case. Floating assets (cliff overhangs, airborne props, flying
## creatures) need full-sphere views and can opt in by adding a path
## substring here. Currently empty — Morrowind's standard asset list has no
## floating impostor candidates, but the framework supports them.
const SPHERE_OVERRIDE_PATTERNS: Array[String] = [
	# Example (uncomment + add patterns as future floating assets land):
	# "flying_",
	# "_airborne",
]

## Always write a debug PNG copy of the normal atlas next to the `.res` file,
## tagged `_normal_debug_v5.png`. Visual inspection only — runtime loader
## ignores it. Cheap (small file, RGBA8 PNG of an existing image).
const DUMP_DEBUG_NORMALS: bool = true

## Baker state
var output_dir: String = ""
var padding_factor: float = 1.2
var background_color: Color = Color(0, 0, 0, 0)

## Rendering infrastructure — TWO separate viewports
var _albedo_viewport: SubViewport = null
var _albedo_camera: Camera3D = null
var _albedo_model_container: Node3D = null

var _normal_viewport: SubViewport = null
var _normal_camera: Camera3D = null
var _normal_model_container: Node3D = null

var _normal_capture_material: ShaderMaterial = null

var _is_initialized: bool = false

## Progress signals (mirror v2 so existing batch UI keeps working)
signal progress(current: int, total: int, model_name: String)
signal model_baked(model_path: String, success: bool, output_path: String)
signal batch_complete(total: int, success_count: int, failed_count: int)

## Stats
var _total_baked: int = 0
var _total_failed: int = 0
var _failed_models: Array[String] = []


#region Lifecycle & Setup

func _ready() -> void:
	_setup_rendering_viewports()


## Create both viewports. Albedo = MSAA 4×, normal = MSAA OFF + no Environment.
func _setup_rendering_viewports() -> void:
	if _is_initialized:
		return

	# === Albedo viewport (MSAA 4×, ambient white, transparent background) ===
	_albedo_viewport = SubViewport.new()
	_albedo_viewport.size = Vector2i(FRAME_SIZE, FRAME_SIZE)  # Resized per-asset
	_albedo_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_albedo_viewport.transparent_bg = true
	_albedo_viewport.msaa_3d = Viewport.MSAA_4X
	_albedo_viewport.use_hdr_2d = false
	_albedo_viewport.own_world_3d = true
	add_child(_albedo_viewport)

	_albedo_camera = Camera3D.new()
	_albedo_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_albedo_camera.size = 10.0
	_albedo_camera.near = 0.1
	_albedo_camera.far = 1000.0
	_albedo_viewport.add_child(_albedo_camera)

	# Ambient-only environment for unlit capture. No directional light = no shadows
	# baked into the albedo, which is what we want — lighting happens at runtime.
	var albedo_world_env := WorldEnvironment.new()
	var albedo_env := Environment.new()
	albedo_env.background_mode = Environment.BG_COLOR
	albedo_env.background_color = background_color
	albedo_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	albedo_env.ambient_light_color = Color.WHITE
	albedo_env.ambient_light_energy = 1.0
	albedo_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	albedo_world_env.environment = albedo_env
	_albedo_viewport.add_child(albedo_world_env)

	_albedo_model_container = Node3D.new()
	_albedo_model_container.name = "AlbedoModelContainer"
	_albedo_viewport.add_child(_albedo_model_container)

	# === Normal viewport (MSAA OFF, NO Environment) ===
	# Per reviewer addendum D: leave Environment unassigned on the normal
	# viewport. The capture shader is `unshaded` so no Environment lighting
	# or tonemap should touch the pixels between fragment write and
	# get_image() read. MSAA disabled to prevent linear resolve averaging
	# encoded normals across silhouette edges.
	_normal_viewport = SubViewport.new()
	_normal_viewport.size = Vector2i(FRAME_SIZE, FRAME_SIZE)
	_normal_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_normal_viewport.transparent_bg = true
	_normal_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_normal_viewport.use_hdr_2d = false
	_normal_viewport.own_world_3d = true
	add_child(_normal_viewport)

	_normal_camera = Camera3D.new()
	_normal_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_normal_camera.size = 10.0
	_normal_camera.near = 0.1
	_normal_camera.far = 1000.0
	_normal_viewport.add_child(_normal_camera)

	# NOTE: intentionally NO WorldEnvironment on this viewport. See comment above.

	_normal_model_container = Node3D.new()
	_normal_model_container.name = "NormalModelContainer"
	_normal_viewport.add_child(_normal_model_container)

	_normal_capture_material = _create_normal_capture_material()

	_is_initialized = true
	Log.info("prebaking", "ImpostorBakerV3 initialized (bake_version=5, octahedral, 2-viewport)")


## Normal-capture shader: writes world-space normal to RGB, view-space linear
## depth to alpha. Unshaded. Double-sided so we capture backfaces too (needed
## for vegetation with single-sided quads).
func _create_normal_capture_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform float near_plane : hint_range(0.0, 1000.0) = 0.1;
uniform float far_plane : hint_range(0.0, 10000.0) = 100.0;

void fragment() {
	// NORMAL in fragment is view-space. Transform to world-space for storage.
	vec3 world_normal = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	ALBEDO = world_normal * 0.5 + 0.5;
	// Linear depth in view space: +z is into the screen, we want near=1 far=0
	float linear_depth = -VERTEX.z;
	ALPHA = 1.0 - clamp((linear_depth - near_plane) / (far_plane - near_plane), 0.0, 1.0);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat


func initialize() -> Error:
	_setup_rendering_viewports()
	if output_dir.is_empty():
		output_dir = SettingsManager.get_impostors_path()
	var err := SettingsManager.ensure_cache_directories()
	if err != OK:
		push_error("ImpostorBakerV3: Failed to create cache directories")
		return err
	return OK

#endregion


#region Octahedral Direction Encoding
#
# Full-sphere octahedral unwrap per Cigolle et al. 2014 ("A Survey of Efficient
# Representations for Independent Unit Vectors"). Maps a unit direction in
# R³ onto the unit square [-1, 1]² with ~1.8° worst-case angular error at
# full precision. Same encoding Brucks / UE Impostor Baker / Bevy use.
#
# We use this for the baker's camera direction lookup: given a grid cell
# (col, row) in an N×N atlas, `decode_octahedral(uv)` returns the camera
# direction for that cell. The phase 2 runtime shader will use the matching
# `encode_octahedral` to go from view-direction → atlas UV at sample time.
#
# Godot convention: Y up. The unwrap places Y=±1 at the center / corners of
# the unit square so the sphere is evenly distributed.

## Decode a 2D octahedral UV in [-1, 1]² to a 3D unit direction (full sphere).
## uv.xy is the grid cell UV (doubled and shifted from the [0,1] atlas space).
static func octahedral_decode_sphere(uv: Vector2) -> Vector3:
	var v := Vector3(uv.x, 1.0 - absf(uv.x) - absf(uv.y), uv.y)
	if v.y < 0.0:
		var old_x := v.x
		var old_z := v.z
		v.x = (1.0 - absf(old_z)) * signf(old_x)
		v.z = (1.0 - absf(old_x)) * signf(old_z)
	return v.normalized()


## Encode a 3D unit direction to [-1, 1]² (full sphere). Inverse of
## octahedral_decode_sphere.
static func octahedral_encode_sphere(n: Vector3) -> Vector2:
	var nn := n.normalized()
	var sum := absf(nn.x) + absf(nn.y) + absf(nn.z)
	if sum < 0.00001:
		return Vector2.ZERO
	var px := nn.x / sum
	var pz := nn.z / sum
	if nn.y < 0.0:
		var old_x := px
		var old_z := pz
		px = (1.0 - absf(old_z)) * signf(old_x)
		pz = (1.0 - absf(old_x)) * signf(old_z)
	return Vector2(px, pz)


## Decode a 2D UV in [-1, 1]² to a 3D unit direction on the UPPER hemisphere
## (y >= 0). Uses the 45° rotated unit square trick so every grid cell maps
## to a valid hemi direction with no dead zones.
##
## Mapping: rotate uv by 45° into (u, v) with |u| + |v| <= 1 always, then
## y = 1 - |u| - |v| (always >= 0), final direction (u, y, v).normalized().
static func octahedral_decode_hemi(uv: Vector2) -> Vector3:
	var u := (uv.x + uv.y) * 0.5
	var v := (uv.y - uv.x) * 0.5
	var y := 1.0 - absf(u) - absf(v)
	return Vector3(u, y, v).normalized()


## Encode a 3D unit direction on the UPPER hemisphere (y >= 0) to [-1, 1]².
## Inverse of octahedral_decode_hemi.
static func octahedral_encode_hemi(n: Vector3) -> Vector2:
	var nn := n.normalized()
	# Project onto the octahedron (|x| + |y| + |z| = 1) scaled by inv sum.
	var sum := absf(nn.x) + absf(nn.y) + absf(nn.z)
	if sum < 0.00001:
		return Vector2.ZERO
	var u := nn.x / sum
	var v := nn.z / sum
	# Inverse 45° rotation: uv.x = u - v, uv.y = u + v
	return Vector2(u - v, u + v)


## Build the list of camera directions for an N×N grid, in row-major order.
## Each cell's UV is its center: uv = ((col + 0.5) / N, (row + 0.5) / N),
## remapped from [0, 1] to [-1, 1]. `projection` is "hemi" (upper hemisphere
## only, default) or "sphere" (full sphere).
static func generate_directions(grid_size: int, projection: String = "hemi") -> Array[Vector3]:
	var dirs: Array[Vector3] = []
	dirs.resize(grid_size * grid_size)
	var idx := 0
	for row in range(grid_size):
		for col in range(grid_size):
			var u := (float(col) + 0.5) / float(grid_size)
			var v := (float(row) + 0.5) / float(grid_size)
			# Remap [0,1] → [-1,1]
			var uv := Vector2(u * 2.0 - 1.0, v * 2.0 - 1.0)
			if projection == "sphere":
				dirs[idx] = octahedral_decode_sphere(uv)
			else:
				dirs[idx] = octahedral_decode_hemi(uv)
			idx += 1
	return dirs

#endregion


#region Per-Asset Projection Resolution

## Pick the octahedral projection for a given model path. Default hemi.
## Override to "sphere" for assets matching SPHERE_OVERRIDE_PATTERNS (floating
## models that need below-horizon views — currently none in MW asset list).
func _resolve_projection(model_path: String) -> String:
	var lower_path := model_path.to_lower().replace("/", "\\")
	for pattern in SPHERE_OVERRIDE_PATTERNS:
		if pattern in lower_path:
			return "sphere"
	return "hemi"

#endregion


#region Bake Core

## Bake a single model to a v5 octahedral impostor.
## Returns {success, output_path, normal_path, metadata_path, bounds, error}.
##
## `candidates` is unused in the simplified API (kept as a default param for
## backwards compatibility with the v2 batch caller). Per-asset settings live
## entirely in this file now — only the projection flag is per-asset.
func bake_model(model_path: String, _candidates: ImpostorCandidatesScript = null) -> Dictionary:
	Log.info("prebaking", "Baking impostor v5: %s" % model_path)

	if not is_inside_tree():
		var error := "ImpostorBakerV3 not in scene tree"
		push_warning("ImpostorBakerV3: %s - %s" % [error, model_path])
		model_baked.emit(model_path, false, "")
		return {"success": false, "error": error}

	# Single grid+frame config for all assets (constants). Only the projection
	# (hemi/sphere) is per-asset.
	var projection := _resolve_projection(model_path)

	# Resize both viewports to the standard frame size
	_albedo_viewport.size = Vector2i(FRAME_SIZE, FRAME_SIZE)
	_normal_viewport.size = Vector2i(FRAME_SIZE, FRAME_SIZE)

	# Load model into albedo pass
	var albedo_model := _load_model(model_path)
	if not albedo_model:
		var error := "Failed to load model"
		push_warning("ImpostorBakerV3: %s - %s" % [error, model_path])
		model_baked.emit(model_path, false, "")
		return {"success": false, "error": error}

	_albedo_model_container.add_child(albedo_model)
	await get_tree().process_frame

	var aabb := _get_model_aabb(albedo_model)
	if aabb.size.length() < 0.01:
		albedo_model.queue_free()
		var error := "Model has invalid bounds"
		push_warning("ImpostorBakerV3: %s - %s" % [error, model_path])
		model_baked.emit(model_path, false, "")
		return {"success": false, "error": error}

	var center := aabb.get_center()
	albedo_model.position = -center
	await get_tree().process_frame

	var size := aabb.size
	var max_extent := maxf(maxf(size.x, size.y), size.z) * padding_factor
	_albedo_camera.size = max_extent
	_normal_camera.size = max_extent
	var camera_distance := max_extent * 2.0

	# Configure normal capture depth range
	_normal_capture_material.set_shader_parameter("near_plane", _normal_camera.near)
	_normal_capture_material.set_shader_parameter("far_plane", camera_distance * 2.0)

	# === Generate octahedral directions ===
	var directions := generate_directions(GRID_SIZE, projection)
	var total_frames := GRID_SIZE * GRID_SIZE

	# === PASS 1: Albedo frames ===
	var albedo_frames: Array[Image] = []
	for i in range(total_frames):
		var frame := await _render_from_direction_async(
			_albedo_camera, _albedo_viewport, directions[i], camera_distance
		)
		albedo_frames.append(frame if frame else _make_blank(FRAME_SIZE, background_color))

	albedo_model.queue_free()
	await get_tree().process_frame

	# === PASS 2: Normal frames (fresh model reload, override material) ===
	var normal_frames: Array[Image] = []
	var normal_model := _load_model(model_path)
	if normal_model:
		_normal_model_container.add_child(normal_model)
		normal_model.position = -center

		var mesh_instances := _find_all_mesh_instances(normal_model)
		Log.info("prebaking", "Normal pass: overriding %d mesh instances" % mesh_instances.size())
		for mesh_inst in mesh_instances:
			mesh_inst.material_override = _normal_capture_material

		await get_tree().process_frame
		await get_tree().process_frame  # Extra frame for material propagation

		for i in range(total_frames):
			var frame := await _render_from_direction_async(
				_normal_camera, _normal_viewport, directions[i], camera_distance
			)
			normal_frames.append(frame if frame else _make_blank(FRAME_SIZE, Color(0.5, 0.5, 1.0, 0.0)))

		normal_model.queue_free()
	else:
		for i in range(total_frames):
			normal_frames.append(_make_blank(FRAME_SIZE, Color(0.5, 0.5, 1.0, 0.0)))

	# === Pack atlases ===
	var atlas_size := GRID_SIZE * FRAME_SIZE
	var albedo_atlas := _pack_albedo_atlas(albedo_frames, atlas_size)
	var normal_atlas_image := _pack_normal_atlas(normal_frames, albedo_frames, atlas_size)

	# === Save ===
	# v5 filename suffix on all outputs — prevents collision with legacy v4
	# bakes in the same directory during the migration window. The runtime
	# loader (phase 2) will check for `_v5.*` first and fall back to the
	# legacy paths for v4 bakes.
	var albedo_path := _get_output_path_with_suffix(model_path, "v5", "png")
	var metadata_path := _get_output_path_with_suffix(model_path, "v5", "json")
	var normal_res_path := _get_output_path_with_suffix(model_path, "normal_v5", "res")
	var normal_debug_png_path := _get_output_path_with_suffix(model_path, "normal_debug_v5", "png")

	var save_err := albedo_atlas.save_png(albedo_path)
	if save_err != OK:
		var error := "Failed to save albedo atlas: error %d" % save_err
		push_warning("ImpostorBakerV3: %s - %s" % [error, albedo_path])
		model_baked.emit(model_path, false, "")
		return {"success": false, "error": error}

	# Save normal atlas as .res (ImageTexture, RGBA8) — bypass PNG import
	# pipeline entirely. No .import file, no sRGB decode, bytes are preserved
	# exactly. See addendum C in docs/audit/IMPOSTOR_REBUILD.md.
	var normal_tex := ImageTexture.create_from_image(normal_atlas_image)
	save_err = ResourceSaver.save(normal_tex, normal_res_path)
	if save_err != OK:
		push_warning("ImpostorBakerV3: Failed to save normal .res: %s (err=%d)" % [normal_res_path, save_err])
		normal_res_path = ""

	# Debug PNG dump of the normal atlas, for visual inspection of encoded
	# normals + depth. NOT loaded by the runtime path — purely an inspection
	# aid. Always written; constant flag at top of file.
	if DUMP_DEBUG_NORMALS and not normal_res_path.is_empty():
		var debug_save_err := normal_atlas_image.save_png(normal_debug_png_path)
		if debug_save_err != OK:
			push_warning("ImpostorBakerV3: Failed to save normal debug PNG: %s" % normal_debug_png_path)

	# Metadata
	var metadata := _generate_metadata(
		model_path, aabb, albedo_path, normal_res_path, projection, directions
	)
	_save_metadata(metadata_path, metadata)

	Log.info("prebaking", "Saved v5 impostor: %s (proj=%s)" % [albedo_path, projection])
	model_baked.emit(model_path, true, albedo_path)

	return {
		"success": true,
		"output_path": albedo_path,
		"normal_path": normal_res_path,
		"normal_debug_path": normal_debug_png_path,
		"metadata_path": metadata_path,
		"bounds": aabb,
		"projection": projection,
		"error": ""
	}


## Batch bake — mirrors v2 API so existing prebake UI can swap in.
func bake_models(model_paths: Array, _candidates: ImpostorCandidatesScript = null) -> Dictionary:
	if initialize() != OK:
		return {"success": 0, "failed": 0, "total": 0}

	_total_baked = 0
	_total_failed = 0
	_failed_models.clear()

	for i in range(model_paths.size()):
		var model_path: String = model_paths[i]
		progress.emit(i + 1, model_paths.size(), model_path)

		var result := await bake_model(model_path)
		if result.success:
			_total_baked += 1
		else:
			_total_failed += 1
			_failed_models.append(model_path)

		await get_tree().process_frame

	batch_complete.emit(model_paths.size(), _total_baked, _total_failed)

	return {
		"total": model_paths.size(),
		"success": _total_baked,
		"failed": _total_failed,
		"failed_models": _failed_models.duplicate()
	}

#endregion


#region Rendering Helpers

func _render_from_direction_async(
	cam: Camera3D, vp: SubViewport, direction: Vector3, distance: float
) -> Image:
	cam.position = direction * distance
	# look_at requires a non-parallel up vector; when direction is ±Y we need a
	# fallback or look_at spews errors.
	var up := Vector3.UP
	if absf(direction.dot(Vector3.UP)) > 0.999:
		up = Vector3.FORWARD
	cam.look_at(Vector3.ZERO, up)

	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await get_tree().process_frame
	await get_tree().process_frame

	var texture := vp.get_texture()
	if not texture or not texture.get_rid().is_valid():
		return null
	var image := texture.get_image()
	if not image:
		return null
	return image.duplicate()


static func _make_blank(size: int, fill: Color) -> Image:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(fill)
	return img

#endregion


#region Atlas Packing

## Pack albedo frames into the standard atlas, RGBA8. Bulk `blit_rect`,
## no per-pixel loops. Soft alpha — runtime shader handles cutoff.
func _pack_albedo_atlas(frames: Array[Image], atlas_size: int) -> Image:
	var atlas := Image.create(atlas_size, atlas_size, false, Image.FORMAT_RGBA8)
	atlas.fill(background_color)

	var frame_rect := Rect2i(0, 0, FRAME_SIZE, FRAME_SIZE)
	for row in range(GRID_SIZE):
		for col in range(GRID_SIZE):
			var frame_idx := row * GRID_SIZE + col
			if frame_idx >= frames.size():
				continue
			var src: Image = frames[frame_idx]
			if not src:
				continue
			atlas.blit_rect(src, frame_rect, Vector2i(col * FRAME_SIZE, row * FRAME_SIZE))
	return atlas


## Pack normal+depth frames into the standard atlas, RGBA8.
## RGB = world-space normal encoded [0,1], A = linear depth [0,1].
##
## Uses `blit_rect_mask` so transparent albedo pixels keep the atlas default
## (0.5, 1.0, 0.5, 0.0) instead of the garbage (0, 0, 0, 0) the normal
## capture shader wrote to the cleared framebuffer.
##
## Format: RGBA8. The SubViewport 3D render target is RGBA8 end-to-end —
## storing as RGBAH would be a false precision claim. HDR capture is a
## follow-up tracked in the file header.
func _pack_normal_atlas(
	normal_frames: Array[Image], albedo_frames: Array[Image], atlas_size: int
) -> Image:
	# Default: up-facing encoded normal (0.5, 1.0, 0.5 = (0, 1, 0) world),
	# zero depth. Transparent pixels in the albedo mask keep this value.
	var atlas := Image.create(atlas_size, atlas_size, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0.5, 1.0, 0.5, 0.0))

	var frame_rect := Rect2i(0, 0, FRAME_SIZE, FRAME_SIZE)
	for row in range(GRID_SIZE):
		for col in range(GRID_SIZE):
			var frame_idx := row * GRID_SIZE + col
			if frame_idx >= normal_frames.size():
				continue
			var src_normal: Image = normal_frames[frame_idx]
			var src_albedo: Image = albedo_frames[frame_idx] if frame_idx < albedo_frames.size() else null
			if not src_normal:
				continue

			var dst_offset := Vector2i(col * FRAME_SIZE, row * FRAME_SIZE)
			if src_albedo:
				atlas.blit_rect_mask(src_normal, src_albedo, frame_rect, dst_offset)
			else:
				atlas.blit_rect(src_normal, frame_rect, dst_offset)
	return atlas

#endregion


#region Model Loading & Bounds

func _load_model(model_path: String) -> Node3D:
	var full_path := model_path
	if not model_path.to_lower().begins_with("meshes"):
		full_path = "meshes/" + model_path
	full_path = full_path.replace("\\", "/")

	var nif_data := PackedByteArray()
	if BSAManager.has_file(full_path):
		nif_data = BSAManager.extract_file(full_path)
	elif BSAManager.has_file(model_path):
		nif_data = BSAManager.extract_file(model_path)
		full_path = model_path

	if nif_data.is_empty():
		push_warning("ImpostorBakerV3: File not found: %s" % model_path)
		return null

	var converter := NIFConverter.new()
	converter.load_textures = true
	converter.load_animations = false
	converter.load_collision = false
	converter.generate_lods = false
	converter.generate_occluders = false

	var node := converter.convert_buffer(nif_data, full_path)
	if not node:
		push_warning("ImpostorBakerV3: Failed to convert NIF: %s" % model_path)
		return null
	return node


func _get_model_aabb(node: Node3D) -> AABB:
	var aabb := AABB()
	var first := true
	var mesh_instances := _find_all_mesh_instances(node)
	for mesh_inst in mesh_instances:
		var mesh_aabb := mesh_inst.get_aabb()
		var transformed := mesh_inst.global_transform * mesh_aabb
		if first:
			aabb = transformed
			first = false
		else:
			aabb = aabb.merge(transformed)
	return aabb


func _find_all_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var instances: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		instances.append(node as MeshInstance3D)
	for child in node.get_children():
		instances.append_array(_find_all_mesh_instances(child))
	return instances

#endregion


#region Path Generation

## Match the hash/name conventions of impostor_candidates.gd exactly so the
## runtime loader can find these files without a separate lookup table.
func _get_output_path(model_path: String, extension: String) -> String:
	var normalized := _normalize(model_path)
	var hash_key := normalized.md5_text().substr(0, 8)
	var base_name := _base_name(normalized)
	return output_dir.path_join("%s_%s.%s" % [base_name, hash_key, extension])


func _get_output_path_with_suffix(model_path: String, suffix: String, extension: String) -> String:
	var normalized := _normalize(model_path)
	var hash_key := normalized.md5_text().substr(0, 8)
	var base_name := _base_name(normalized)
	return output_dir.path_join("%s_%s_%s.%s" % [base_name, hash_key, suffix, extension])


static func _normalize(model_path: String) -> String:
	var normalized := model_path
	var lower := normalized.to_lower()
	if lower.begins_with("meshes\\") or lower.begins_with("meshes/"):
		normalized = normalized.substr(7)
	return normalized.replace("/", "\\").to_lower()


static func _base_name(normalized: String) -> String:
	var base := normalized.get_file().get_basename()
	return base.replace("\\", "_").replace("/", "_").replace(" ", "_").to_lower()

#endregion


#region Metadata

func _generate_metadata(
	model_path: String,
	aabb: AABB,
	albedo_path: String,
	normal_path: String,
	projection: String,
	directions: Array[Vector3]
) -> Dictionary:
	var size := aabb.size
	var dirs_array: Array = []
	dirs_array.resize(directions.size())
	for i in range(directions.size()):
		var d := directions[i]
		dirs_array[i] = [d.x, d.y, d.z]

	return {
		"version": 5,
		"bake_version": 5,  # Mirror of "version" for forward-compat lookups
		"projection": projection,
		"model_path": model_path,
		"texture_path": albedo_path,
		"normal_texture_path": normal_path,
		"normal_format": "rgba8_res",
		"has_normal_map": not normal_path.is_empty(),
		"settings": {
			"grid_size": GRID_SIZE,
			"frame_size": FRAME_SIZE,
			"atlas_size": GRID_SIZE * FRAME_SIZE,
			"total_frames": GRID_SIZE * GRID_SIZE,
		},
		"bounds": {
			"center": [aabb.get_center().x, aabb.get_center().y, aabb.get_center().z],
			"size": [size.x, size.y, size.z],
			"width": size.x,
			"height": size.y,
			"depth": size.z,
		},
		"directions": dirs_array,
		"baked_date": Time.get_datetime_string_from_system(),
	}


func _save_metadata(path: String, metadata: Dictionary) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		push_error("ImpostorBakerV3: Failed to open metadata file: %s" % path)
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(metadata, "\t"))
	file.close()
	return OK

#endregion


#region Public API

func get_stats() -> Dictionary:
	return {
		"total_baked": _total_baked,
		"total_failed": _total_failed,
		"failed_models": _failed_models.duplicate(),
	}


## Check if a v5 impostor already exists for a model (by albedo PNG presence +
## metadata version check). Uses the _v5 filename suffix — does NOT match v4
## bakes even if the hash collides.
func impostor_exists(model_path: String) -> bool:
	var albedo_path := _get_output_path_with_suffix(model_path, "v5", "png")
	var meta_path := _get_output_path_with_suffix(model_path, "v5", "json")
	if not FileAccess.file_exists(albedo_path) or not FileAccess.file_exists(meta_path):
		return false
	var file := FileAccess.open(meta_path, FileAccess.READ)
	if not file:
		return false
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		return false
	var meta: Dictionary = json.data
	return int(meta.get("version", 0)) >= 5

#endregion
