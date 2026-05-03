## DistantLightManager — Billboard MultiMesh for lights beyond NEAR tier
##
## Renders ESM light positions as emissive billboard sprites visible from 150m–5km.
## Real OmniLight3D nodes only exist in NEAR tier (0–150m). Beyond that, this system
## takes over with a single-draw-call MultiMesh of tiny glowing quads.
##
## Data source: ESM cell references (not the instantiation path), so lights are
## visible even for cells that haven't been fully loaded/streamed.
##
## Usage:
##   var dlm := DistantLightManager.new()
##   dlm.setup(parent_node)
##   dlm.scan_cells_around(camera_cell, radius_cells)
##   dlm.update_camera(camera_pos)  # call each frame or on camera move
class_name DistantLightManager
extends RefCounted

const CS := preload("res://src/core/coordinate_system.gd")
const DU := preload("res://src/core/world/distance_utils.gd")

#region Configuration

## Minimum distance for distant light sprites (matches NEAR tier end)
const MIN_DISTANCE: float = DU.NEAR_END  # 150m

## Maximum distance for distant light sprites (matches FAR tier end)
const MAX_DISTANCE: float = DU.FAR_END  # 5000m

## Fade margin to overlap with real OmniLight3D distance fade
const FADE_MARGIN: float = 30.0

## Base world-space size of light billboard (meters)
const BASE_SPRITE_SIZE: float = 3.0

## Minimum screen-space size factor — prevents lights from disappearing at extreme distance
## Applied as a distance-based scale in the shader
const MIN_SCREEN_FACTOR: float = 0.005

## Maximum instances the MultiMesh can hold
const MAX_INSTANCES: int = 4096

## MW light scale (same as reference_instantiator)
const MW_LIGHT_SCALE: float = 1.0 / 70.0

## Sun elevation threshold (radians) below which distant lights become visible
## ~6 degrees below horizon = full night, 0 = horizon
const DUSK_THRESHOLD: float = 0.15  # ~8.6 degrees — lights start appearing
const NIGHT_THRESHOLD: float = -0.05  # Below horizon — fully visible

#endregion


#region Internal state

## Lightweight struct for each registered distant light
## Packed for memory efficiency — no Node3D, no RefCounted overhead
var _positions: PackedVector3Array = PackedVector3Array()
var _colors: PackedColorArray = PackedColorArray()
var _radii: PackedFloat32Array = PackedFloat32Array()
var _flags: PackedInt32Array = PackedInt32Array()

## Set of cell grid keys already scanned to avoid double-scanning.
## Keyed by Vector2i (cheap native hash) rather than "x,y" String — per-cell
## String.format allocation was the dominant cellupd cost (~14 ms per cell
## cross at radius=60 = 14641 cells iterated). Vector2i dict hash is direct
## int-combo. See cellupd diag 2026-04-20.
var _scanned_cells: Dictionary = {}

## MultiMesh instance
var _multi_mesh: MultiMesh = null
var _multi_mesh_instance: RID = RID()
var _parent_node: Node3D = null

## Shader material for the billboard sprites
var _material: ShaderMaterial = null

## Current visibility (0.0 = invisible, 1.0 = fully visible)
var _night_factor: float = 0.0

## Whether the system is set up and ready
var _is_setup: bool = false

## Number of active lights in the MultiMesh
var _active_count: int = 0

## SubsystemToggles "distant_lights" flag state. When false, `scan_cells_around`
## and `update` early-return so the tier measures as fully-off (no new cells
## scanned, no billboard rebuilds) — not just hidden.
var _streaming_enabled: bool = true

#endregion


## Initialize the rendering resources. Call once after construction.
func setup(parent: Node3D) -> void:
	_parent_node = parent
	_create_material()
	_create_multi_mesh()
	_is_setup = true
	Log.info("streaming", "DistantLightManager: initialized (max %d instances)" % MAX_INSTANCES)


## Scan ESM cells in a radius around a grid position for light references.
## Only scans cells not previously scanned. Call when camera moves to new cell.
func scan_cells_around(center_cell: Vector2i, radius_cells: int) -> void:
	if not _is_setup:
		return
	# Dual-purpose SubsystemToggles gate: when `distant_lights` is off, skip
	# ESM cell scanning + MultiMesh rebuild entirely.
	if not _streaming_enabled:
		return

	var added: int = 0
	for dy: int in range(-radius_cells, radius_cells + 1):
		for dx: int in range(-radius_cells, radius_cells + 1):
			var gx: int = center_cell.x + dx
			var gy: int = center_cell.y + dy
			var key := Vector2i(gx, gy)

			if _scanned_cells.has(key):
				continue
			_scanned_cells[key] = true

			added += _scan_cell(gx, gy)

	if added > 0:
		_rebuild_multi_mesh()
		Log.info("streaming", "DistantLightManager: added %d distant lights (%d total, %d instances)" % [added, _positions.size(), _active_count])


## Scan a single exterior cell for light references. Returns number of lights found.
func _scan_cell(grid_x: int, grid_y: int) -> int:
	var cell: CellRecord = ESMManager.get_exterior_cell(grid_x, grid_y)
	if cell == null:
		return 0

	var count: int = 0
	for ref: CellReference in cell.references:
		if _positions.size() >= MAX_INSTANCES:
			break

		# Look up the base record — only interested in LIGH types
		var ref_id_lower: String = str(ref.ref_id).to_lower()
		var light_rec: LightRecord = ESMManager.lights.get(ref_id_lower)
		if light_rec == null:
			continue

		# Skip lights that are off by default, have no radius, or are negative
		if light_rec.is_off_by_default():
			continue
		if light_rec.radius <= 0:
			continue
		if light_rec.is_negative():
			continue

		# Convert MW position to Godot world space
		var godot_pos: Vector3 = CS.vector_to_godot(ref.position)

		_positions.append(godot_pos)
		_colors.append(light_rec.color)
		_radii.append(float(light_rec.radius) * MW_LIGHT_SCALE)
		_flags.append(light_rec.flags)
		count += 1

	return count


## Update camera position for distance-based sizing and culling.
## Also updates time-of-day visibility. Call each frame or on significant camera move.
func update(camera_pos: Vector3, sun_elevation_rad: float) -> void:
	if not _is_setup or _active_count == 0:
		return

	# Update night factor based on sun elevation
	if sun_elevation_rad <= NIGHT_THRESHOLD:
		_night_factor = 1.0
	elif sun_elevation_rad >= DUSK_THRESHOLD:
		_night_factor = 0.0
	else:
		_night_factor = 1.0 - (sun_elevation_rad - NIGHT_THRESHOLD) / (DUSK_THRESHOLD - NIGHT_THRESHOLD)

	# Update shader uniforms
	if _material:
		_material.set_shader_parameter("camera_position", camera_pos)
		_material.set_shader_parameter("night_factor", _night_factor)


## Clear all scanned data and rebuild. Call on teleport or major location change.
func clear() -> void:
	_positions.clear()
	_colors.clear()
	_radii.clear()
	_flags.clear()
	_scanned_cells.clear()
	_active_count = 0
	if _multi_mesh:
		_multi_mesh.instance_count = 0


## SubsystemToggles handler: hide MultiMesh AND stop cell scanning.
## Dual-purpose so the tier measures as fully-off when disabled, not just hidden.
func set_enabled(enabled: bool) -> void:
	_streaming_enabled = enabled
	if enabled:
		if not _is_setup and _parent_node:
			_create_material()
			_create_multi_mesh()
			_is_setup = true
		if _multi_mesh_instance.is_valid():
			RenderingServer.instance_set_visible(_multi_mesh_instance, true)
	else:
		clear()
		cleanup()


## Deprecated alias — kept briefly for any callers still using old name.
## New callers: use set_enabled(bool).
func set_visible(visible: bool) -> void:
	set_enabled(visible)


## Clean up rendering resources.
func cleanup() -> void:
	if _multi_mesh_instance.is_valid():
		RenderingServer.free_rid(_multi_mesh_instance)
		_multi_mesh_instance = RID()
	_multi_mesh = null
	_material = null
	_is_setup = false


#region Internal

func _create_material() -> void:
	_material = ShaderMaterial.new()

	var shader := Shader.new()
	shader.code = _get_shader_code()
	_material.shader = shader

	_material.set_shader_parameter("camera_position", Vector3.ZERO)
	_material.set_shader_parameter("night_factor", 0.0)
	_material.set_shader_parameter("base_size", BASE_SPRITE_SIZE)
	_material.set_shader_parameter("min_screen_factor", MIN_SCREEN_FACTOR)
	_material.set_shader_parameter("min_distance", MIN_DISTANCE)
	_material.set_shader_parameter("max_distance", MAX_DISTANCE)
	_material.set_shader_parameter("fade_margin", FADE_MARGIN)


func _create_multi_mesh() -> void:
	_multi_mesh = MultiMesh.new()
	_multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	_multi_mesh.use_custom_data = true
	_multi_mesh.use_colors = true

	# Quad mesh for billboard
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)  # Unit size, scaled per-instance
	quad.orientation = PlaneMesh.FACE_Z  # Face camera
	_multi_mesh.mesh = quad

	# Set material on the mesh
	quad.material = _material

	# Create the MultiMeshInstance via RenderingServer for lightweight rendering
	_multi_mesh_instance = RenderingServer.instance_create()
	RenderingServer.instance_set_base(_multi_mesh_instance, _multi_mesh.get_rid())

	if _parent_node:
		var scenario: RID = _parent_node.get_world_3d().scenario
		RenderingServer.instance_set_scenario(_multi_mesh_instance, scenario)

	# NOTE: Do NOT use instance_geometry_set_visibility_range on the MultiMesh itself.
	# Godot checks distance to the MultiMesh origin (0,0,0), not to individual instances.
	# Distance-based fade is handled per-instance in the shader via camera_position uniform.

	# Set layer mask to default camera layer (layer 1)
	RenderingServer.instance_set_layer_mask(_multi_mesh_instance, 1)
	RenderingServer.instance_set_visible(_multi_mesh_instance, true)


func _rebuild_multi_mesh() -> void:
	var count: int = _positions.size()
	if count == 0:
		_multi_mesh.instance_count = 0
		_active_count = 0
		return

	_multi_mesh.instance_count = count
	_active_count = count

	for i: int in range(count):
		# Transform: position + scale based on MW radius
		# Larger MW radius = brighter/bigger distant light
		var size_scale: float = clampf(_radii[i] / 3.0, 0.5, 4.0)
		var xform := Transform3D(
			Basis.IDENTITY.scaled(Vector3(size_scale, size_scale, size_scale)),
			_positions[i]
		)
		_multi_mesh.set_instance_transform(i, xform)

		# Color: original MW light color
		_multi_mesh.set_instance_color(i, _colors[i])

		# Custom data: pack flags and phase offset for flicker
		# R = is_fire (0 or 1), G = has_flicker (0 or 1), B = phase offset [0-1], A = unused
		var is_fire: float = 1.0 if (_flags[i] & LightRecord.FLAG_FIRE) != 0 else 0.0
		var has_flicker: float = 1.0 if (_flags[i] & (LightRecord.FLAG_FLICKER | LightRecord.FLAG_FLICKER_SLOW | LightRecord.FLAG_PULSE | LightRecord.FLAG_PULSE_SLOW)) != 0 else 0.0
		var phase_offset: float = fmod(float(i) * 0.618033988749, 1.0)  # Golden ratio distribution
		_multi_mesh.set_instance_custom_data(i, Color(is_fire, has_flicker, phase_offset, 0.0))


func _get_shader_code() -> String:
	return """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec3 camera_position;
uniform float night_factor : hint_range(0.0, 1.0) = 0.0;
uniform float base_size = 3.0;
uniform float min_screen_factor = 0.005;
uniform float min_distance = 150.0;
uniform float max_distance = 5000.0;
uniform float fade_margin = 30.0;

varying flat vec3 v_emission;

void vertex() {
	// Instance world position from MODEL_MATRIX
	vec3 world_pos = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float dist = length(world_pos - camera_position);

	// Per-instance color = MW light color
	vec3 light_col = COLOR.rgb;

	// Custom data: R=is_fire, G=has_flicker, B=phase_offset
	float is_fire = INSTANCE_CUSTOM.r;
	float has_flicker = INSTANCE_CUSTOM.g;
	float phase_offset = INSTANCE_CUSTOM.b;

	// Flicker animation
	float flicker = 1.0;
	if (has_flicker > 0.5) {
		float t = TIME * 2.0 + phase_offset * 6.283;
		flicker = 0.7 + 0.3 * (sin(t) * sin(t * 2.7 + 1.3) * 0.5 + 0.5);
	}

	// Night visibility
	float visibility = night_factor;
	if (is_fire > 0.5) {
		visibility = max(visibility, 0.3);
	}

	// Distance-based size with minimum screen presence
	float final_size = max(base_size, dist * min_screen_factor);

	// Near fade-in (smooth handoff from real OmniLight3D)
	float near_fade = smoothstep(min_distance - fade_margin, min_distance + fade_margin, dist);

	// Far fade-out
	float far_fade = 1.0 - smoothstep(max_distance - 500.0, max_distance, dist);

	float brightness = visibility * flicker * near_fade * far_fade;

	// Pre-compute emission color for fragment shader
	v_emission = light_col * brightness * 3.0;

	// Billboard: camera-facing quad using MODELVIEW_MATRIX bypass
	// Set MODELVIEW_MATRIX directly to a billboard transform (same pattern as impostor inline shader)
	// This avoids the MODEL_MATRIX double-transform issue with RenderingServer instances
	vec3 to_cam = camera_position - world_pos;
	to_cam.y = 0.0; // Y-axis locked billboard
	vec3 forward = normalize(to_cam);
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), forward));
	vec3 up = vec3(0.0, 1.0, 0.0);

	// Build a world-space billboard matrix and combine with VIEW_MATRIX
	mat4 billboard_model = mat4(
		vec4(right * final_size, 0.0),
		vec4(up * final_size, 0.0),
		vec4(forward, 0.0),
		vec4(world_pos, 1.0)
	);
	MODELVIEW_MATRIX = VIEW_MATRIX * billboard_model;
	// VERTEX stays in local space (unit quad -0.5 to 0.5)
}

void fragment() {
	// Radial soft glow
	vec2 uv = UV * 2.0 - 1.0;
	float r = dot(uv, uv);
	float glow = exp(-r * 4.0);

	// Additive blend: ALBEDO is added to framebuffer, no alpha needed
	ALBEDO = v_emission * glow;
}
"""

#endregion
