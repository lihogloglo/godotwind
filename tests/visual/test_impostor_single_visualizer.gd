## Close-up single-model impostor visualizer.
##
## Shows one real model overlapped with its v6 impostor through the production
## NativeImpostorRenderer path. This is intentionally close-up and orbitable so
## origin, bounds, selected views, normals, and shadow behavior can be inspected
## before running any broad/far-distance validation.
extends Node3D

const NativeImpostorRendererScript := preload("res://src/core/world/native_impostor_renderer.gd")
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")
const ImpostorBakerV3Script := preload("res://src/tools/prebaking/impostor_baker_v3.gd")
const NIFConverterScript := preload("res://src/core/nif/nif_converter.gd")

const ACTION_TOGGLE_BILLBOARD := &"impostor_toggle_billboard"
const ACTION_TOGGLE_MODELS := &"impostor_toggle_models"
const ACTION_DEBUG_NORMALS := &"impostor_debug_normals"
const ACTION_MODEL_YAW_LEFT := &"impostor_sun_left"
const ACTION_MODEL_YAW_RIGHT := &"impostor_sun_right"

const DEFAULT_MODELS: Array[String] = [
	"meshes/x/ex_hlaalu_b_01.nif",
	"meshes/x/ex_vivec_b_01.nif",
	"meshes/x/ex_vivec_hfq_01.nif",
	"meshes/x/ex_bm_dae_ruin_04.nif",
	"meshes/x/ex_dae_wall_256_04.nif",
	"meshes/x/ex_imp_rubble_08.nif",
	"meshes/x/terrain_rock_ma_57.nif",
	"meshes/f/flora_tree_gl_01.nif",
]

const ORBIT_SPEED: float = 1.5
const ZOOM_SPEED: float = 18.0
const MODEL_YAW_STEP: float = PI * 0.25
const LIGHT_ORBIT_SPEED: float = 0.7
const MOUSE_ORBIT_SENSITIVITY: float = 0.01
const MIN_ORBIT_DISTANCE: float = 2.0

var _camera: Camera3D
var _sun: DirectionalLight3D
var _hud: Label
var _previous_model_button: Button
var _next_model_button: Button
var _rebake_button: Button
var _model_container: Node3D
var _bounds_container: Node3D
var _impostor_renderer: NativeImpostorRendererScript
var _impostor_candidates: ImpostorCandidatesScript
var _baker: ImpostorBakerV3Script

var _model_path: String = DEFAULT_MODELS[0]
var _model_index: int = 0
var _model_visible: bool = true
var _billboard_visible: bool = true
var _model_yaw: float = 0.0
var _orbit_yaw: float = 0.0
var _orbit_pitch: float = -0.2
var _orbit_distance: float = 30.0
var _orbit_target: Vector3 = Vector3(0.0, 5.0, 0.0)
var _light_azimuth: float = 0.0
var _bounds: AABB = AABB(Vector3(-5.0, 0.0, -5.0), Vector3(10.0, 10.0, 10.0))
var _load_status: String = "loading"
var _active_bake_info: String = "no bake"
var _baking: bool = false


func _ready() -> void:
	InputActions.verify()
	_verify_visual_actions()
	_model_path = _model_from_args()
	_model_index = _model_index_for_path(_model_path)
	_ensure_bsa_archives_loaded()
	_setup_environment()
	_setup_camera()
	_setup_hud()
	_setup_model_container()
	_setup_bounds_container()
	_setup_impostor_renderer()
	call_deferred("_load_visualized_model")


func _verify_visual_actions() -> void:
	for action_name: StringName in InputActions.VISUAL_TEST:
		if not InputMap.has_action(action_name):
			Log.error("input", "Missing visual test action: %s" % action_name)
			assert(false, "missing visual test action: %s" % action_name)


func _model_from_args() -> String:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--model="):
			var value := arg.trim_prefix("--model=").strip_edges()
			if not value.is_empty():
				return value
	return DEFAULT_MODELS[0]


func _model_index_for_path(model_path: String) -> int:
	for i: int in range(DEFAULT_MODELS.size()):
		if DEFAULT_MODELS[i] == model_path:
			return i
	return 0


func _ensure_bsa_archives_loaded() -> void:
	if BSAManager.total_archives_loaded > 0:
		return
	var data_path: String = SettingsManager.get_data_path()
	var loaded := BSAManager.load_archives_from_directory(data_path)
	Log.info("impostors", "Loaded %d BSA archives for single impostor visualizer" % loaded)


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.28, 0.32, 0.36)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.22, 0.24, 0.28)
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	_sun = DirectionalLight3D.new()
	_sun.name = "OrbitingSun"
	_sun.light_energy = 1.5
	_sun.light_color = Color(1.0, 0.94, 0.82)
	_sun.shadow_enabled = true
	_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	_sun.directional_shadow_max_distance = 120.0
	add_child(_sun)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "OrbitCamera"
	_camera.fov = 55.0
	_camera.near = 0.05
	_camera.far = 600.0
	_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_camera)


func _setup_hud() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	_hud = Label.new()
	_hud.position = Vector2(12, 12)
	_hud.add_theme_color_override("font_color", Color.WHITE)
	_hud.add_theme_color_override("font_shadow_color", Color.BLACK)
	_hud.add_theme_constant_override("shadow_offset_x", 1)
	_hud.add_theme_constant_override("shadow_offset_y", 1)
	canvas.add_child(_hud)

	_previous_model_button = Button.new()
	_previous_model_button.position = Vector2(12, 112)
	_previous_model_button.text = "Previous Model"
	_previous_model_button.pressed.connect(_select_previous_model)
	canvas.add_child(_previous_model_button)

	_next_model_button = Button.new()
	_next_model_button.position = Vector2(150, 112)
	_next_model_button.text = "Next Model"
	_next_model_button.pressed.connect(_select_next_model)
	canvas.add_child(_next_model_button)

	_rebake_button = Button.new()
	_rebake_button.position = Vector2(12, 152)
	_rebake_button.text = "Rebake Displayed Impostor"
	_rebake_button.pressed.connect(_rebake_current_model)
	canvas.add_child(_rebake_button)


func _setup_model_container() -> void:
	_model_container = Node3D.new()
	_model_container.name = "RealModel"
	add_child(_model_container)


func _setup_bounds_container() -> void:
	_bounds_container = Node3D.new()
	_bounds_container.name = "BakeBounds"
	add_child(_bounds_container)


func _setup_impostor_renderer() -> void:
	_impostor_candidates = ImpostorCandidatesScript.new()
	_add_custom_candidate_if_needed(_model_path)

	_impostor_renderer = NativeImpostorRendererScript.new()
	_impostor_renderer.name = "ProductionImpostor"
	_impostor_renderer.debug_enabled = true
	_impostor_renderer.set_impostor_candidates(_impostor_candidates)
	add_child(_impostor_renderer)
	_impostor_renderer.set_force_visible_for_test(true)


func _load_visualized_model() -> void:
	await get_tree().process_frame
	_clear_model_container()
	_clear_bounds_container()

	var node := _load_comparison_model(_model_path)
	if node:
		node.name = "OriginalModel"
		_model_container.add_child(node)
		_model_container.visible = _model_visible
		_apply_model_yaw()
		_bounds = _compute_aabb(node)
		_fit_orbit_to_bounds(_bounds)
		_load_status = "model loaded"
	else:
		_load_status = "model failed"

	var albedo_path := ImpostorCandidatesScript.get_impostor_texture_path_v6(_model_path)
	var normal_path := ImpostorCandidatesScript.get_impostor_normal_res_path_v6(_model_path)
	var metadata_path := ImpostorCandidatesScript.get_impostor_metadata_path_v6(_model_path)
	if not FileAccess.file_exists(albedo_path) or not FileAccess.file_exists(normal_path) or not FileAccess.file_exists(metadata_path):
		_load_status += ", missing v6 bake"
		_active_bake_info = "missing v6"
		_clear_bounds_container()
		Log.warn("impostors", "Missing v6 impostor files for %s" % _model_path)
		return

	var metadata := _load_metadata(metadata_path)
	_active_bake_info = _format_bake_info(metadata)
	_draw_bake_bounds(metadata)
	_apply_model_yaw()

	_queue_visualized_impostor()
	_load_status += ", impostor queued"
	Log.info("impostors", "Single impostor visualizer loaded %s" % _model_path)


func _select_previous_model() -> void:
	_select_model(wrapi(_model_index - 1, 0, DEFAULT_MODELS.size()))


func _select_next_model() -> void:
	_select_model(wrapi(_model_index + 1, 0, DEFAULT_MODELS.size()))


func _select_model(model_index: int) -> void:
	if _baking or model_index == _model_index:
		return
	_model_index = model_index
	_model_path = DEFAULT_MODELS[_model_index]
	_load_status = "loading selected model"
	_active_bake_info = "loading"
	_set_model_buttons_disabled(true)
	_reset_impostor_renderer()
	await _load_visualized_model()
	_set_model_buttons_disabled(false)


func _clear_model_container() -> void:
	for child: Node in _model_container.get_children():
		child.queue_free()


func _clear_bounds_container() -> void:
	for child: Node in _bounds_container.get_children():
		child.queue_free()


func _load_metadata(metadata_path: String) -> Dictionary:
	var file := FileAccess.open(metadata_path, FileAccess.READ)
	if not file:
		return {}
	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	if err != OK or not (json.data is Dictionary):
		return {}
	return json.data as Dictionary


func _format_bake_info(metadata: Dictionary) -> String:
	var settings: Dictionary = metadata.get("settings", {})
	return "v%d %s %d atlas %d frame" % [
		int(metadata.get("version", metadata.get("bake_version", 0))),
		str(settings.get("tier", "?")),
		int(settings.get("atlas_size", 0)),
		int(settings.get("frame_size", 0)),
	]


func _draw_bake_bounds(metadata: Dictionary) -> void:
	_clear_bounds_container()
	var bounds: Dictionary = metadata.get("bounds", {})
	if bounds.is_empty():
		return

	var center := Vector3.ZERO
	var center_values: Variant = bounds.get("center", [])
	if center_values is Array and (center_values as Array).size() >= 3:
		var arr := center_values as Array
		center = Vector3(float(arr[0]), float(arr[1]), float(arr[2]))

	var size := Vector3(
		float(bounds.get("width", 0.0)),
		float(bounds.get("height", 0.0)),
		float(bounds.get("depth", 0.0))
	)
	var size_values: Variant = bounds.get("size", [])
	if size_values is Array and (size_values as Array).size() >= 3:
		var arr := size_values as Array
		size = Vector3(float(arr[0]), float(arr[1]), float(arr[2]))

	if size.x > 0.0 and size.y > 0.0 and size.z > 0.0:
		var source_aabb := AABB(center - size * 0.5, size)
		_bounds_container.add_child(_make_wire_box(source_aabb, Color(0.1, 1.0, 0.35, 1.0), "SourceAABB"))

	var capture_size := float(bounds.get("capture_size", 0.0))
	if capture_size > 0.0:
		var capture_aabb := AABB(
			center - Vector3.ONE * capture_size * 0.5,
			Vector3.ONE * capture_size
		)
		_bounds_container.add_child(_make_wire_box(capture_aabb, Color(1.0, 0.85, 0.1, 1.0), "CaptureBounds"))


func _make_wire_box(aabb: AABB, color: Color, node_name: String) -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.no_depth_test = true

	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	var min_v := aabb.position
	var max_v := aabb.position + aabb.size
	var points: Array[Vector3] = [
		Vector3(min_v.x, min_v.y, min_v.z),
		Vector3(max_v.x, min_v.y, min_v.z),
		Vector3(max_v.x, min_v.y, max_v.z),
		Vector3(min_v.x, min_v.y, max_v.z),
		Vector3(min_v.x, max_v.y, min_v.z),
		Vector3(max_v.x, max_v.y, min_v.z),
		Vector3(max_v.x, max_v.y, max_v.z),
		Vector3(min_v.x, max_v.y, max_v.z),
	]
	var edges: Array[Vector2i] = [
		Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 3), Vector2i(3, 0),
		Vector2i(4, 5), Vector2i(5, 6), Vector2i(6, 7), Vector2i(7, 4),
		Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
	]
	for edge: Vector2i in edges:
		mesh.surface_add_vertex(points[edge.x])
		mesh.surface_add_vertex(points[edge.y])
	mesh.surface_end()

	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	return instance


func _load_comparison_model(model_path: String) -> Node3D:
	var cache_dir: String = SettingsManager.get_cache_base_path().path_join("models")
	var basename: String = model_path.get_file().replace(".", "_")
	var path_parts := model_path.replace("\\", "/").split("/")
	var subdir: String = path_parts[-2] if path_parts.size() >= 2 else basename.left(1)
	var res_name := "%s_%s.res" % [subdir, basename]
	var res_path := cache_dir.path_join(res_name)

	if FileAccess.file_exists(res_path):
		var mesh_res: Resource = ResourceLoader.load(res_path, "", ResourceLoader.CACHE_MODE_REUSE)
		if mesh_res is PackedScene:
			return (mesh_res as PackedScene).instantiate() as Node3D
		if mesh_res is ArrayMesh:
			var mi := MeshInstance3D.new()
			mi.mesh = mesh_res as ArrayMesh
			return mi

	var full_path := model_path.replace("\\", "/")
	if not full_path.to_lower().begins_with("meshes/"):
		full_path = "meshes/" + full_path

	var nif_data := PackedByteArray()
	if BSAManager.has_file(full_path):
		nif_data = BSAManager.extract_file(full_path)
	elif BSAManager.has_file(model_path):
		nif_data = BSAManager.extract_file(model_path)
		full_path = model_path

	if nif_data.is_empty():
		Log.warn("impostors", "Visualizer NIF not found in BSA: %s" % model_path)
		return null

	var converter := NIFConverterScript.new()
	converter.load_textures = true
	converter.load_animations = false
	converter.load_collision = false
	converter.generate_lods = false
	converter.generate_occluders = false
	return converter.convert_buffer(nif_data, full_path)


func _compute_aabb(node: Node3D) -> AABB:
	var meshes := _find_meshes(node)
	if meshes.is_empty():
		return AABB(Vector3(-1.0, 0.0, -1.0), Vector3(2.0, 2.0, 2.0))

	var result := AABB()
	var has_bounds := false
	for mi: MeshInstance3D in meshes:
		if not mi.mesh:
			continue
		var child_aabb := mi.global_transform * mi.mesh.get_aabb()
		if has_bounds:
			result = result.merge(child_aabb)
		else:
			result = child_aabb
			has_bounds = true
	return result if has_bounds else AABB(Vector3(-1.0, 0.0, -1.0), Vector3(2.0, 2.0, 2.0))


func _find_meshes(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		result.append(node as MeshInstance3D)
	for child: Node in node.get_children():
		result.append_array(_find_meshes(child))
	return result


func _fit_orbit_to_bounds(aabb: AABB) -> void:
	_orbit_target = aabb.get_center()
	var radius := maxf(aabb.size.length() * 0.7, 3.0)
	_orbit_distance = maxf(radius * 2.0, MIN_ORBIT_DISTANCE)
	_orbit_pitch = -0.22
	_update_camera()


func _process(delta: float) -> void:
	_process_orbit_controls(delta)
	_process_light(delta)
	_update_camera()
	_update_hud()


func _process_orbit_controls(delta: float) -> void:
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	_orbit_yaw += input_dir.x * ORBIT_SPEED * delta
	_orbit_distance = maxf(MIN_ORBIT_DISTANCE, _orbit_distance + input_dir.y * ZOOM_SPEED * delta)


func _process_light(delta: float) -> void:
	_light_azimuth = fmod(_light_azimuth + LIGHT_ORBIT_SPEED * delta, TAU)
	var elevation := deg_to_rad(42.0)
	var dir := Vector3(
		cos(_light_azimuth) * cos(elevation),
		-sin(elevation),
		sin(_light_azimuth) * cos(elevation)
	).normalized()
	_sun.look_at(_sun.global_position + dir, Vector3.UP)


func _update_camera() -> void:
	if not _camera:
		return
	_orbit_pitch = clampf(_orbit_pitch, -1.2, 1.0)
	var horizontal := cos(_orbit_pitch) * _orbit_distance
	var offset := Vector3(
		sin(_orbit_yaw) * horizontal,
		sin(_orbit_pitch) * _orbit_distance,
		cos(_orbit_yaw) * horizontal
	)
	_camera.global_position = _orbit_target + offset
	_camera.look_at(_orbit_target, Vector3.UP)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var motion := event as InputEventMouseMotion
		_orbit_yaw -= motion.relative.x * MOUSE_ORBIT_SENSITIVITY
		_orbit_pitch -= motion.relative.y * MOUSE_ORBIT_SENSITIVITY

	if event.is_action_pressed("ui_cancel"):
		get_tree().quit()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not (event as InputEventKey).pressed:
		return
	if (event as InputEventKey).echo:
		return

	if event.is_action_pressed(ACTION_TOGGLE_MODELS):
		_model_visible = !_model_visible
		_model_container.visible = _model_visible
	elif event.is_action_pressed(ACTION_TOGGLE_BILLBOARD):
		_billboard_visible = !_billboard_visible
		_impostor_renderer.visible = _billboard_visible
	elif event.is_action_pressed(ACTION_DEBUG_NORMALS) and _impostor_renderer._billboard_material:
		var current: bool = _impostor_renderer._billboard_material.get_shader_parameter("debug_normals")
		_impostor_renderer._billboard_material.set_shader_parameter("debug_normals", !current)
	elif event.is_action_pressed(ACTION_MODEL_YAW_LEFT):
		_rotate_model_yaw(-MODEL_YAW_STEP)
	elif event.is_action_pressed(ACTION_MODEL_YAW_RIGHT):
		_rotate_model_yaw(MODEL_YAW_STEP)


func _rebake_current_model() -> void:
	if _baking:
		return
	_baking = true
	_load_status = "rebaking displayed model"
	_rebake_button.disabled = true
	_set_model_buttons_disabled(true)
	_clear_bounds_container()

	_baker = ImpostorBakerV3Script.new()
	add_child(_baker)
	await get_tree().process_frame
	if _baker.initialize() != OK:
		_load_status = "rebake failed: baker init"
		await _finish_rebake()
		return

	var result := await _baker.bake_model(_model_path, _impostor_candidates)
	if bool(result.get("success", false)):
		_load_status = "rebake complete"
		_reset_impostor_renderer()
		await _load_visualized_model()
	else:
		_load_status = "rebake failed: %s" % str(result.get("error", "unknown"))
	await _finish_rebake()


func _finish_rebake() -> void:
	if _baker:
		_baker.queue_free()
		_baker = null
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().create_timer(1.0).timeout
	_baking = false
	_rebake_button.disabled = false
	_set_model_buttons_disabled(false)


func _set_model_buttons_disabled(disabled: bool) -> void:
	_previous_model_button.disabled = disabled
	_next_model_button.disabled = disabled


func _reset_impostor_renderer() -> void:
	if _impostor_renderer:
		_impostor_renderer.fast_cleanup()
		remove_child(_impostor_renderer)
		_impostor_renderer.queue_free()
		_impostor_renderer = null
	_setup_impostor_renderer()
	_impostor_renderer.visible = _billboard_visible


func _apply_model_yaw() -> void:
	if _model_container:
		_model_container.rotation = Vector3(0.0, _model_yaw, 0.0)
	if _bounds_container:
		_bounds_container.rotation = Vector3(0.0, _model_yaw, 0.0)


func _rotate_model_yaw(delta_yaw: float) -> void:
	_model_yaw = fposmod(_model_yaw + delta_yaw, TAU)
	_apply_model_yaw()
	_reset_impostor_renderer()
	_queue_visualized_impostor()


func _queue_visualized_impostor() -> void:
	if not _impostor_renderer:
		return
	var albedo_path := ImpostorCandidatesScript.get_impostor_texture_path_v6(_model_path)
	var normal_path := ImpostorCandidatesScript.get_impostor_normal_res_path_v6(_model_path)
	var metadata_path := ImpostorCandidatesScript.get_impostor_metadata_path_v6(_model_path)
	if not FileAccess.file_exists(albedo_path) or not FileAccess.file_exists(normal_path) or not FileAccess.file_exists(metadata_path):
		return
	_impostor_renderer.add_impostor(_model_path, Vector2i.ZERO, Vector3.ZERO, Vector3(0.0, _model_yaw, 0.0), Vector3.ONE)


func _add_custom_candidate_if_needed(model_path: String) -> void:
	# Keep normal candidates on their curated size tier. Forcing every
	# visualizer model into a blank custom candidate makes small assets bake at
	# the generic 512 setting instead of their intended lower tier.
	if not _impostor_candidates.should_have_impostor(model_path):
		_impostor_candidates.add_custom_candidate(model_path)


func _update_hud() -> void:
	var stats: Dictionary = _impostor_renderer.get_stats() if _impostor_renderer else {}
	_hud.text = (
		"Single Impostor Visualizer | %d FPS\n" % Engine.get_frames_per_second()
		+ "Model %d/%d: %s\n" % [_model_index + 1, DEFAULT_MODELS.size(), _model_path]
		+ "Status: %s | Bake: %s | Model: %s | Billboard: %s | Uploaded: %d | Model yaw: %.0f deg\n"
		% [
			_load_status,
			_active_bake_info,
			"ON" if _model_visible else "OFF",
			"ON" if _billboard_visible else "OFF",
			int(stats.get("far_uploaded_instances", 0)),
			rad_to_deg(_model_yaw),
		]
		+ "Bounds: green=AABB yellow=capture | Buttons cycle curated models and rebake the displayed model | Move left/right = orbit | Move forward/back = zoom | J/L = model yaw | mouse drag = orbit | M = model | V = billboard | N = normals | ESC = quit"
	)
