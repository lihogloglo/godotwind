## ImpostorManager - Manages far-distance impostor rendering (2km-5km)
##
## Renders distant landmarks as octahedral impostors (pre-rendered billboards).
## Used by FAR tier to show recognizable silhouettes beyond merged mesh range.
##
## Key features:
## - Loads pre-baked impostor textures for landmarks
## - Spawns billboard quads with octahedral shader
## - Selects correct view angle based on camera direction
## - Handles impostor→mesh transition when player approaches
## - Batches impostors into atlas for draw call reduction
##
## Impostor textures are expected in the cache directory:
##   {cache}/impostors/[model_hash]_impostor.png
##   {cache}/impostors/[model_hash]_impostor.json (metadata)
## Default cache location: Documents/Godotwind/cache/
##
## Usage:
##   var manager := ImpostorManager.new()
##   add_child(manager)
##   manager.add_impostor(model_path, position, rotation, scale)
##   manager.remove_impostors_for_cell(cell_grid)
class_name ImpostorManager
extends Node3D

# Preload dependencies
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")
const CS := preload("res://src/core/coordinate_system.gd")

## Reference to ImpostorCandidates for checking impostor eligibility
var impostor_candidates: RefCounted = null  # ImpostorCandidates

## World scenario RID
var _scenario: RID = RID()

## Loaded impostor textures: model_path_hash -> Texture2D
var _impostor_textures: Dictionary = {}

## Loaded impostor metadata: model_path_hash -> Dictionary
var _impostor_metadata: Dictionary = {}

## Active impostors: impostor_id -> ImpostorInstance
var _impostors: Dictionary = {}

## Impostors by cell: Vector2i -> Array[impostor_id]
var _impostors_by_cell: Dictionary = {}

## Next impostor ID
var _next_id: int = 0

## Default billboard material (octahedral shader placeholder)
var _billboard_material: ShaderMaterial = null

## Stats
var _stats := {
	"total_impostors": 0,
	"visible_impostors": 0,
	"texture_cache_size": 0,
	"cells_with_impostors": 0,
}


## Impostor instance data
class ImpostorInstance:
	var id: int
	var model_path: String
	var position: Vector3
	var rotation: Vector3
	var scale: Vector3
	var cell_grid: Vector2i
	var instance_rid: RID      ## RenderingServer instance
	var mesh_rid: RID          ## Billboard quad mesh
	var visible: bool = true
	var texture_size: Vector2  ## Size of impostor in world units


func _enter_tree() -> void:
	_scenario = get_viewport().get_world_3d().scenario
	_setup_billboard_material()


func _exit_tree() -> void:
	clear()


func _process(_delta: float) -> void:
	# Update impostor orientations to face camera
	_update_impostor_billboards()


## Set up the billboard material with octahedral impostor shader
func _setup_billboard_material() -> void:
	# Try to load the prebaked octahedral shader
	var shader_path := "res://src/tools/prebaking/shaders/octahedral_impostor.gdshader"
	var shader: Shader = null

	if ResourceLoader.exists(shader_path):
		shader = load(shader_path) as Shader

	if not shader:
		# Fallback to inline shader if file not found
		shader = Shader.new()
		shader.code = _get_fallback_shader_code()

	_billboard_material = ShaderMaterial.new()
	_billboard_material.shader = shader
	_billboard_material.set_shader_parameter("atlas_columns", 4)
	_billboard_material.set_shader_parameter("atlas_rows", 2)
	_billboard_material.set_shader_parameter("interpolate_frames", true)


## Fallback shader code if external file not found
func _get_fallback_shader_code() -> String:
	return """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D albedo_atlas : source_color, filter_linear_mipmap;
uniform float alpha_cutoff : hint_range(0.0, 1.0) = 0.5;
uniform int atlas_columns = 4;
uniform int atlas_rows = 2;
uniform bool interpolate_frames = true;

varying vec3 view_direction;

void vertex() {
	vec3 camera_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 world_pos = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	view_direction = normalize(camera_pos - world_pos);

	vec3 look_dir = normalize(vec3(view_direction.x, 0.0, view_direction.z));
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), look_dir));
	vec3 up = vec3(0.0, 1.0, 0.0);

	mat4 billboard = mat4(
		vec4(right, 0.0),
		vec4(up, 0.0),
		vec4(look_dir, 0.0),
		MODEL_MATRIX[3]
	);

	float scale_x = length(MODEL_MATRIX[0].xyz);
	float scale_y = length(MODEL_MATRIX[1].xyz);
	float scale_z = length(MODEL_MATRIX[2].xyz);

	billboard[0] *= scale_x;
	billboard[1] *= scale_y;
	billboard[2] *= scale_z;

	MODELVIEW_MATRIX = VIEW_MATRIX * billboard;
}

int get_frame_index(vec3 view_dir) {
	float angle = atan(view_dir.x, view_dir.z);
	float normalized = (angle + PI) / (2.0 * PI);
	return int(normalized * 8.0) % 8;
}

vec2 get_frame_uv(int frame_index, vec2 uv) {
	float col = float(frame_index % atlas_columns);
	float row = float(frame_index / atlas_columns);
	vec2 frame_size = vec2(1.0 / float(atlas_columns), 1.0 / float(atlas_rows));
	return vec2(col, row) * frame_size + uv * frame_size;
}

void fragment() {
	int frame = get_frame_index(view_direction);
	vec2 atlas_uv = get_frame_uv(frame, UV);
	vec4 tex = texture(albedo_atlas, atlas_uv);

	ALBEDO = tex.rgb;
	if (tex.a < alpha_cutoff) {
		discard;
	}
	ALPHA = tex.a;
}
"""


## Set the impostor candidates reference
func set_impostor_candidates(candidates: RefCounted) -> void:
	impostor_candidates = candidates


## Add an impostor for a model at a specific world position
## Returns impostor_id or -1 if failed
func add_impostor(
	model_path: String,
	world_position: Vector3,
	world_rotation: Vector3,
	world_scale: Vector3,
	cell_grid: Vector2i = Vector2i.ZERO
) -> int:
	if not _scenario.is_valid():
		push_warning("ImpostorManager: Not in scene tree")
		return -1

	# Check if this model should have an impostor
	if impostor_candidates and not impostor_candidates.should_have_impostor(model_path):
		return -1

	# Load impostor texture if not cached
	var texture := _get_or_load_impostor_texture(model_path)
	if not texture:
		# No pre-baked impostor available - skip
		return -1

	# Get impostor metadata
	var metadata := _get_or_load_impostor_metadata(model_path)
	var impostor_size := Vector2(10.0, 10.0)  # Default size
	if not metadata.is_empty():
		# Try new format first (bounds.width/height), then old format
		var bounds: Dictionary = metadata.get("bounds", {})
		if not bounds.is_empty():
			impostor_size.x = bounds.get("width", 10.0)
			impostor_size.y = bounds.get("height", 10.0)
		else:
			impostor_size.x = metadata.get("width", 10.0)
			impostor_size.y = metadata.get("height", 10.0)

	# Create billboard quad mesh
	var quad_mesh := QuadMesh.new()
	quad_mesh.size = impostor_size * world_scale.x  # Uniform scale for now

	# Create RenderingServer instance
	var instance_rid := RenderingServer.instance_create()
	RenderingServer.instance_set_base(instance_rid, quad_mesh.get_rid())
	RenderingServer.instance_set_scenario(instance_rid, _scenario)

	# Set transform (position with Y offset for center)
	var transform := Transform3D.IDENTITY
	transform.origin = world_position + Vector3(0, impostor_size.y * 0.5 * world_scale.x, 0)
	RenderingServer.instance_set_transform(instance_rid, transform)

	# Apply material with texture
	var mat := _billboard_material.duplicate() as ShaderMaterial
	mat.set_shader_parameter("albedo_atlas", texture)  # Octahedral atlas texture
	RenderingServer.instance_geometry_set_material_override(instance_rid, mat.get_rid())

	# Create impostor instance
	var impostor := ImpostorInstance.new()
	impostor.id = _next_id
	impostor.model_path = model_path
	impostor.position = world_position
	impostor.rotation = world_rotation
	impostor.scale = world_scale
	impostor.cell_grid = cell_grid
	impostor.instance_rid = instance_rid
	impostor.mesh_rid = quad_mesh.get_rid()
	impostor.visible = true
	impostor.texture_size = impostor_size

	_impostors[_next_id] = impostor
	_next_id += 1

	# Track by cell
	if cell_grid not in _impostors_by_cell:
		_impostors_by_cell[cell_grid] = []
		_stats["cells_with_impostors"] += 1
	_impostors_by_cell[cell_grid].append(impostor.id)

	# Update stats
	_stats["total_impostors"] += 1
	_stats["visible_impostors"] += 1

	return impostor.id


## Add impostors for all eligible objects in a cell
## Returns number of impostors added
func add_cell_impostors(cell_grid: Vector2i, references: Array) -> int:
	var count := 0

	for ref in references:
		if not ref is CellReference:
			continue

		# Get base record
		var record_type: Array = [""]
		var base_record = ESMManager.get_any_record(str(ref.ref_id), record_type)
		if not base_record:
			continue

		# Get model path
		var model_path: String = ""
		if "model" in base_record:
			model_path = base_record.model
		elif "model_path" in base_record:
			model_path = base_record.model_path

		if model_path.is_empty():
			continue

		# Check if should have impostor
		if impostor_candidates and not impostor_candidates.should_have_impostor(model_path):
			continue

		# Calculate world position/rotation/scale
		var pos := CS.vector_to_godot(ref.position)
		var rot := CS.euler_to_godot(ref.rotation)
		var scl := CS.scale_to_godot(ref.scale)

		# Add impostor
		var id := add_impostor(model_path, pos, rot, scl, cell_grid)
		if id >= 0:
			count += 1

	return count


## Remove an impostor by ID
func remove_impostor(impostor_id: int) -> void:
	if impostor_id not in _impostors:
		return

	var impostor: ImpostorInstance = _impostors[impostor_id]

	# Free RenderingServer resources
	if impostor.instance_rid.is_valid():
		RenderingServer.free_rid(impostor.instance_rid)

	# Update stats
	_stats["total_impostors"] -= 1
	if impostor.visible:
		_stats["visible_impostors"] -= 1

	# Remove from cell tracking
	if impostor.cell_grid in _impostors_by_cell:
		_impostors_by_cell[impostor.cell_grid].erase(impostor_id)
		if _impostors_by_cell[impostor.cell_grid].is_empty():
			_impostors_by_cell.erase(impostor.cell_grid)
			_stats["cells_with_impostors"] -= 1

	_impostors.erase(impostor_id)


## Remove all impostors for a cell
func remove_impostors_for_cell(cell_grid: Vector2i) -> void:
	if cell_grid not in _impostors_by_cell:
		return

	# Copy array since we're modifying it
	var impostor_ids: Array = _impostors_by_cell[cell_grid].duplicate()
	for id in impostor_ids:
		remove_impostor(id)


## Set impostor visibility
func set_impostor_visible(impostor_id: int, visible: bool) -> void:
	if impostor_id not in _impostors:
		return

	var impostor: ImpostorInstance = _impostors[impostor_id]
	if impostor.visible == visible:
		return

	impostor.visible = visible
	RenderingServer.instance_set_visible(impostor.instance_rid, visible)

	if visible:
		_stats["visible_impostors"] += 1
	else:
		_stats["visible_impostors"] -= 1


## Update visibility for all impostors based on camera distance
## min_distance: Start showing impostors (end of MID tier)
## max_distance: Stop showing impostors (start of HORIZON tier)
func update_impostor_visibility(camera_pos: Vector3, min_distance: float, max_distance: float) -> int:
	var changes := 0
	var min_dist_sq := min_distance * min_distance
	var max_dist_sq := max_distance * max_distance

	for id in _impostors:
		var impostor: ImpostorInstance = _impostors[id]
		var dist_sq := camera_pos.distance_squared_to(impostor.position)

		var should_be_visible := dist_sq >= min_dist_sq and dist_sq <= max_dist_sq

		if impostor.visible != should_be_visible:
			set_impostor_visible(id, should_be_visible)
			changes += 1

	return changes


## Update billboard orientations to face camera
func _update_impostor_billboards() -> void:
	# Billboard rotation is handled in shader, nothing to do here
	pass


## Get or load impostor texture for a model
func _get_or_load_impostor_texture(model_path: String) -> Texture2D:
	var hash_key := str(model_path.to_lower().hash())

	# Check cache
	if hash_key in _impostor_textures:
		return _impostor_textures[hash_key]

	# Try to load from disk
	var texture_path := ImpostorCandidatesScript.get_impostor_texture_path(model_path)
	if ResourceLoader.exists(texture_path):
		var texture := load(texture_path) as Texture2D
		if texture:
			_impostor_textures[hash_key] = texture
			_stats["texture_cache_size"] += 1
			return texture

	# No pre-baked impostor available
	return null


## Get or load impostor metadata for a model
func _get_or_load_impostor_metadata(model_path: String) -> Dictionary:
	var hash_key := str(model_path.to_lower().hash())

	# Check cache
	if hash_key in _impostor_metadata:
		return _impostor_metadata[hash_key]

	# Try to load from disk
	var metadata_path := ImpostorCandidatesScript.get_impostor_metadata_path(model_path)
	if FileAccess.file_exists(metadata_path):
		var file := FileAccess.open(metadata_path, FileAccess.READ)
		if file:
			var json_str := file.get_as_text()
			file.close()

			var json := JSON.new()
			if json.parse(json_str) == OK:
				var data: Dictionary = json.data
				_impostor_metadata[hash_key] = data
				return data

	# Return empty - will use defaults
	return {}


## Clear all impostors
func clear() -> void:
	for id in _impostors.keys():
		remove_impostor(id)

	_impostors.clear()
	_impostors_by_cell.clear()
	_impostor_textures.clear()
	_impostor_metadata.clear()

	_stats["total_impostors"] = 0
	_stats["visible_impostors"] = 0
	_stats["texture_cache_size"] = 0
	_stats["cells_with_impostors"] = 0


## Get statistics
func get_stats() -> Dictionary:
	return _stats.duplicate()


## Check if a cell has impostors
func has_impostors_for_cell(cell_grid: Vector2i) -> bool:
	return cell_grid in _impostors_by_cell and not _impostors_by_cell[cell_grid].is_empty()


## Get count of impostors in a cell
func get_cell_impostor_count(cell_grid: Vector2i) -> int:
	if cell_grid not in _impostors_by_cell:
		return 0
	return _impostors_by_cell[cell_grid].size()
