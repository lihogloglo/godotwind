## Impostor V6 Validation Scene — Phase 3 of IMPOSTOR_REBUILD.md
##
## Displays tree and building impostors using the real NativeImpostorRenderer.
## Also places REAL 3D models at the same positions for direct overlap
## comparison — the impostor should align exactly with the mesh.
##
## Controls (unified input actions from project.godot):
##   WASD / move_*    — fly camera
##   Mouse drag       — look around (captured)
##   Shift / sprint   — fast fly
##   impostor_sun_*   — rotate sun
##   impostor_bake_v6 — batch-bake selected trees to current v6 output
##   impostor_debug_normals — toggle normal debug
##   impostor_toggle_models — toggle real 3D models visible/hidden
##   ESC / ui_cancel  — release mouse / quit
##
## Launch:
##   "<godot-executable>" --path "<project-path>" res://tests/visual/test_impostor_v5.tscn
## Smoke:
##   ... res://tests/visual/test_impostor_v5.tscn -- --impostor-test-smoke
extends Node3D

const NativeImpostorRendererScript := preload("res://src/core/world/native_impostor_renderer.gd")
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")
const ImpostorBakerV3Script := preload("res://src/tools/prebaking/impostor_baker_v3.gd")
const NIFConverterScript := preload("res://src/core/nif/nif_converter.gd")

const ACTION_SUN_LEFT := &"impostor_sun_left"
const ACTION_SUN_RIGHT := &"impostor_sun_right"
const ACTION_SUN_UP := &"impostor_sun_up"
const ACTION_SUN_DOWN := &"impostor_sun_down"
const ACTION_BAKE_CURRENT := &"impostor_bake_v6"
const ACTION_DEBUG_NORMALS := &"impostor_debug_normals"
const ACTION_TOGGLE_MODELS := &"impostor_toggle_models"

## Tree models
const TEST_TREES: Array[String] = [
	"meshes/f/flora_tree_gl_01.nif",
	"meshes/f/flora_tree_gl_02.nif",
	"meshes/f/flora_tree_gl_03.nif",
	"meshes/f/flora_tree_ai_05.nif",
	"meshes/f/flora_tree_ai_06.nif",
]

## Building models
const TEST_BUILDINGS: Array[String] = [
	"meshes/x/ex_hlaalu_b_01.nif",
	"meshes/x/ex_hlaalu_b_03.nif",
	"meshes/x/ex_hlaalu_b_05.nif",
	"meshes/x/ex_vivec_hfq_01.nif",
	"meshes/x/ex_vivec_hfq_02.nif",
]

const EXISTING_V6_MODELS: Array[String] = [
	"meshes/x/ex_bm_dae_ruin_04.nif",
	"meshes/x/ex_dae_wall_256_04.nif",
	"meshes/x/ex_imp_rubble_08.nif",
]

const CURATED_DIVERSITY_MODELS: Array[String] = [
	"meshes/x/ex_vivec_b_01.nif",
	"meshes/x/ex_hlaalu_b_01.nif",
	"meshes/x/ex_vivec_hfq_01.nif",
	"meshes/x/ex_bm_dae_ruin_04.nif",
	"meshes/x/ex_dae_wall_256_04.nif",
	"meshes/x/ex_imp_rubble_08.nif",
	"meshes/x/terrain_rock_ma_57.nif",
	"meshes/f/flora_tree_gl_01.nif",
]

## Model path → cache .res filename mapping helper
## Cache files are named: first letter dir / sanitized_name.res
## e.g. "meshes/f/flora_tree_gl_01.nif" → "f_flora_tree_gl_01_nif.res"

## Placement
const TREE_RING_COUNT: int = 3
const TREES_PER_RING: int = 16
const TREE_RING_START: float = 30.0
const TREE_RING_SPACING: float = 25.0
const BUILDING_RADIUS: float = 120.0
const BUILDING_COUNT: int = 8
const VALIDATION_CAMERA_DISTANCE: float = 1000.0

## Fly camera
const FLY_SPEED: float = 80.0
const FLY_SPEED_FAST: float = 300.0
const MOUSE_SENSITIVITY: float = 0.002

var _camera: Camera3D
var _sun: DirectionalLight3D
var _sun_arrow: MeshInstance3D
var _impostor_renderer: NativeImpostorRendererScript
var _impostor_candidates: ImpostorCandidatesScript
var _hud: Label
var _baker: ImpostorBakerV3Script
var _model_container: Node3D
var _models_visible: bool = true

var _sun_azimuth: float = 30.0
var _sun_elevation: float = 45.0
var _camera_yaw: float = 0.0
var _camera_pitch: float = -3.0
var _animate_sun: bool = true
var _baking: bool = false
var _impostor_count: int = 0
var _v6_count: int = 0
var _missing_v6_count: int = 0
var _smoke_mode: bool = false
var _existing_v6_only: bool = false
var _curated_diversity: bool = false
var _smoke_elapsed: float = 0.0
var _smoke_result_written: bool = false

## Tracks placement data for both impostors and models
var _placements: Array[Dictionary] = []


func _ready() -> void:
	InputActions.verify()
	_verify_test_actions()
	var args := OS.get_cmdline_user_args()
	_smoke_mode = "--impostor-test-smoke" in args
	_existing_v6_only = "--existing-v6-only" in args
	_curated_diversity = "--curated-diversity" in args
	_ensure_bsa_archives_loaded()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_setup_environment()
	_setup_ground()
	_setup_camera()
	_setup_hud()
	_setup_impostor_renderer()
	_model_container = Node3D.new()
	_model_container.name = "RealModels"
	add_child(_model_container)
	call_deferred("_populate_scene")


func _setup_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.35, 0.5, 0.8)
	sky_mat.sky_horizon_color = Color(0.6, 0.7, 0.85)
	sky_mat.ground_bottom_color = Color(0.2, 0.18, 0.15)
	sky_mat.ground_horizon_color = Color(0.55, 0.55, 0.5)
	sky_mat.sun_angle_max = 60.0
	sky_mat.sun_curve = 0.08

	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.65, 0.7, 0.8)
	env.fog_density = 0.0003

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	_sun = DirectionalLight3D.new()
	_sun.shadow_enabled = true
	_sun.light_energy = 1.4
	_sun.light_color = Color(1.0, 0.95, 0.85)
	_sun.directional_shadow_max_distance = 1500.0
	_update_sun_direction()
	add_child(_sun)

	# Yellow cone arrow showing sun direction
	_sun_arrow = MeshInstance3D.new()
	var arrow_mesh := CylinderMesh.new()
	arrow_mesh.top_radius = 0.05
	arrow_mesh.bottom_radius = 0.3
	arrow_mesh.height = 3.0
	var arrow_mat := StandardMaterial3D.new()
	arrow_mat.albedo_color = Color.YELLOW
	arrow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	arrow_mesh.material = arrow_mat
	_sun_arrow.mesh = arrow_mesh
	add_child(_sun_arrow)


func _setup_ground() -> void:
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(2000, 2000)
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.35, 0.4, 0.25)
	ground_mat.roughness = 0.95
	ground_mesh.material = ground_mat
	var ground := MeshInstance3D.new()
	ground.mesh = ground_mesh
	ground.position = Vector3.ZERO
	add_child(ground)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.far = 6000.0
	_camera.fov = 60.0
	_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_camera)
	_camera.position = Vector3(0.0, 55.0, VALIDATION_CAMERA_DISTANCE)
	_camera.rotation_degrees = Vector3(_camera_pitch, _camera_yaw, 0.0)
	get_viewport().mesh_lod_threshold = 1.0


func _setup_hud() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_hud = Label.new()
	_hud.position = Vector2(10, 10)
	_hud.add_theme_color_override("font_color", Color.WHITE)
	_hud.add_theme_color_override("font_shadow_color", Color.BLACK)
	_hud.add_theme_constant_override("shadow_offset_x", 1)
	_hud.add_theme_constant_override("shadow_offset_y", 1)
	canvas.add_child(_hud)


func _setup_impostor_renderer() -> void:
	_impostor_candidates = ImpostorCandidatesScript.new()
	_impostor_renderer = NativeImpostorRendererScript.new()
	_impostor_renderer.debug_enabled = true
	_impostor_renderer.set_impostor_candidates(_impostor_candidates)
	add_child(_impostor_renderer)
	_impostor_renderer.set_force_visible_for_test(true)


func _verify_test_actions() -> void:
	for action_name: StringName in InputActions.VISUAL_TEST:
		if not InputMap.has_action(action_name):
			Log.error("input", "Missing visual test action: %s" % action_name)
			assert(false, "missing visual test action: %s" % action_name)


func _ensure_bsa_archives_loaded() -> void:
	if BSAManager.total_archives_loaded > 0:
		return
	var data_path: String = SettingsManager.get_data_path()
	var loaded := BSAManager.load_archives_from_directory(data_path)
	Log.info("impostors", "Loaded %d BSA archives for visual comparison models" % loaded)


func _populate_scene() -> void:
	await get_tree().process_frame
	if _curated_diversity:
		_populate_curated_diversity_scene()
		return
	if _existing_v6_only:
		_populate_existing_v6_scene()
		return

	_placements.clear()
	var cell_grid := Vector2i(0, 0)
	var tree_idx: int = 0

	# Trees in rings
	for ring in TREE_RING_COUNT:
		var radius := TREE_RING_START + ring * TREE_RING_SPACING
		for i in TREES_PER_RING:
			var angle := (float(i) / TREES_PER_RING) * TAU
			var jitter_r := randf_range(-8.0, 8.0)
			var jitter_a := randf_range(-0.1, 0.1)
			var r := radius + jitter_r
			var a := angle + jitter_a
			var pos := Vector3(cos(a) * r, 0.0, sin(a) * r)
			var yaw := randf() * TAU
			var model_path: String = TEST_TREES[tree_idx % TEST_TREES.size()]
			tree_idx += 1

			_placements.append({"path": model_path, "pos": pos, "yaw": yaw})
			_impostor_renderer.add_impostor(
				model_path, cell_grid, pos,
				Vector3(0, yaw, 0), Vector3.ONE
			)
			_count_impostor(model_path)

	# Buildings in outer ring
	for i in BUILDING_COUNT:
		var angle := (float(i) / BUILDING_COUNT) * TAU
		var jitter_a := randf_range(-0.15, 0.15)
		var r := BUILDING_RADIUS + randf_range(-10.0, 10.0)
		var a := angle + jitter_a
		var pos := Vector3(cos(a) * r, 0.0, sin(a) * r)
		var yaw := randf() * TAU
		var model_path: String = TEST_BUILDINGS[i % TEST_BUILDINGS.size()]

		_placements.append({"path": model_path, "pos": pos, "yaw": yaw})
		_impostor_renderer.add_impostor(
			model_path, cell_grid, pos,
			Vector3(0, yaw, 0), Vector3.ONE
		)
		_count_impostor(model_path)

	Log.info("impostors", "Test: %d impostors (%d v6, %d missing v6)" % [_impostor_count, _v6_count, _missing_v6_count])

	if _impostor_renderer._billboard_material:
		_impostor_renderer._billboard_material.set_shader_parameter("fade_distance", 0.0)

	# Place real 3D models at the same positions
	_spawn_real_models()


func _populate_existing_v6_scene() -> void:
	_placements.clear()
	_impostor_renderer.clear()
	_impostor_count = 0
	_missing_v6_count = 0
	_v6_count = 0

	var cell_grid := Vector2i(0, 0)
	var x_spacing := 30.0
	var z_spacing := 24.0
	var yaws: Array[float] = [0.0, PI * 0.5, PI, PI * 1.5]
	for model_idx in EXISTING_V6_MODELS.size():
		var model_path := EXISTING_V6_MODELS[model_idx]
		_impostor_candidates.add_custom_candidate(model_path)
		for yaw_idx in yaws.size():
			var yaw := yaws[yaw_idx]
			var pos := Vector3(
				(float(yaw_idx) - 1.5) * x_spacing,
				0.0,
				-36.0 - float(model_idx) * z_spacing
			)
			_placements.append({"path": model_path, "pos": pos, "yaw": yaw})
			_impostor_renderer.add_impostor(model_path, cell_grid, pos, Vector3(0, yaw, 0), Vector3.ONE)
			_count_impostor(model_path)

	if _impostor_renderer._billboard_material:
		_impostor_renderer._billboard_material.set_shader_parameter("fade_distance", 0.0)

	_spawn_real_models()
	Log.info("impostors", "Existing-v6 test: %d complete v6 impostor variants requested" % _v6_count)


func _populate_curated_diversity_scene() -> void:
	_placements.clear()
	_impostor_renderer.clear()
	_impostor_count = 0
	_missing_v6_count = 0
	_v6_count = 0

	var cell_grid := Vector2i(0, 0)
	var spacing := 46.0
	for model_idx in CURATED_DIVERSITY_MODELS.size():
		var model_path := CURATED_DIVERSITY_MODELS[model_idx]
		_impostor_candidates.add_custom_candidate(model_path)
		var pos := Vector3((float(model_idx) - 1.5) * spacing, 0.0, -72.0)
		var yaw := float(model_idx) * PI * 0.35
		_placements.append({"path": model_path, "pos": pos, "yaw": yaw})
		_impostor_renderer.add_impostor(model_path, cell_grid, pos, Vector3(0, yaw, 0), Vector3.ONE)
		_count_impostor(model_path)

	if _impostor_renderer._billboard_material:
		_impostor_renderer._billboard_material.set_shader_parameter("fade_distance", 0.0)

	_spawn_real_models()
	Log.info("impostors", "Curated diversity test: %d complete v6 impostors requested" % _v6_count)


func _spawn_real_models() -> void:
	# Clear previous
	for child in _model_container.get_children():
		child.queue_free()

	var cache_dir: String = SettingsManager.get_cache_base_path().path_join("models")
	Log.info("impostors", "Cache model dir: %s, placements: %d" % [cache_dir, _placements.size()])

	for placement in _placements:
		var model_path: String = placement["path"]
		var pos: Vector3 = placement["pos"]
		var yaw: float = placement["yaw"]

		# Build cache filename: "meshes/f/flora_tree_gl_01.nif" → "f_flora_tree_gl_01_nif.res"
		# Subdir letter comes from the path directory, not the filename
		var basename: String = model_path.get_file().replace(".", "_")
		var path_parts := model_path.replace("\\", "/").split("/")
		var subdir: String = path_parts[-2] if path_parts.size() >= 2 else basename.left(1)
		var res_name := "%s_%s.res" % [subdir, basename]
		var res_path := cache_dir.path_join(res_name)

		if not FileAccess.file_exists(res_path):
			Log.info("impostors", "Model not found: %s" % res_path)
		var node := _load_comparison_model(model_path, res_path)

		if not node:
			continue

		node.position = pos
		node.rotation.y = yaw
		_model_container.add_child(node)

	_model_container.visible = _models_visible
	Log.info("impostors", "Placed %d real models for comparison" % _model_container.get_child_count())


func _load_comparison_model(model_path: String, res_path: String) -> Node3D:
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
		Log.warn("impostors", "Comparison NIF not found in BSA: %s" % model_path)
		return null

	var converter := NIFConverterScript.new()
	converter.load_textures = true
	converter.load_animations = false
	converter.load_collision = false
	converter.generate_lods = false
	converter.generate_occluders = false
	return converter.convert_buffer(nif_data, full_path)


func _count_impostor(model_path: String) -> void:
	_impostor_count += 1
	var v6_path := ImpostorCandidatesScript.get_impostor_texture_path_v6(model_path)
	var normal_path := ImpostorCandidatesScript.get_impostor_normal_res_path_v6(model_path)
	var metadata_path := ImpostorCandidatesScript.get_impostor_metadata_path_v6(model_path)
	if FileAccess.file_exists(v6_path) and FileAccess.file_exists(normal_path) and FileAccess.file_exists(metadata_path):
		_v6_count += 1
	else:
		_missing_v6_count += 1


func _update_sun_direction() -> void:
	if not _sun:
		return
	_sun.rotation_degrees = Vector3(-_sun_elevation, _sun_azimuth, 0.0)

	if _sun_arrow and _camera:
		var sun_dir := -_sun.global_transform.basis.z
		_sun_arrow.global_position = _camera.global_position + sun_dir * 8.0
		_sun_arrow.look_at(_sun_arrow.global_position + sun_dir, Vector3.UP)
		_sun_arrow.rotate_object_local(Vector3.RIGHT, PI * 0.5)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		_camera_yaw -= motion.relative.x * MOUSE_SENSITIVITY * (180.0 / PI)
		_camera_pitch -= motion.relative.y * MOUSE_SENSITIVITY * (180.0 / PI)
		_camera_pitch = clampf(_camera_pitch, -89.0, 89.0)

	if event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			get_tree().quit()


func _process(delta: float) -> void:
	_process_fly_camera(delta)
	_process_sun_controls(delta)
	_process_sun_animation(delta)
	_update_hud()
	_process_smoke(delta)


func _process_fly_camera(delta: float) -> void:
	var input_dir := Input.get_vector(
		"move_left", "move_right", "move_forward", "move_backward"
	)
	var speed := FLY_SPEED_FAST if Input.is_action_pressed("sprint") else FLY_SPEED
	_camera.rotation_degrees = Vector3(_camera_pitch, _camera_yaw, 0.0)
	var forward := -_camera.global_transform.basis.z
	var right_vec := _camera.global_transform.basis.x
	var velocity := (right_vec * input_dir.x + forward * (-input_dir.y)) * speed
	if Input.is_action_pressed("jump"):
		velocity.y += speed
	if Input.is_action_pressed("crouch"):
		velocity.y -= speed
	_camera.position += velocity * delta


func _process_sun_controls(delta: float) -> void:
	var sun_speed := 30.0
	if Input.is_action_pressed(ACTION_SUN_LEFT):
		_animate_sun = false
		_sun_azimuth -= sun_speed * delta
	if Input.is_action_pressed(ACTION_SUN_RIGHT):
		_animate_sun = false
		_sun_azimuth += sun_speed * delta
	if Input.is_action_pressed(ACTION_SUN_UP):
		_animate_sun = false
		_sun_elevation = minf(_sun_elevation + sun_speed * delta, 90.0)
	if Input.is_action_pressed(ACTION_SUN_DOWN):
		_animate_sun = false
		_sun_elevation = maxf(_sun_elevation - sun_speed * delta, 5.0)
	_update_sun_direction()


func _process_sun_animation(delta: float) -> void:
	if not _animate_sun:
		return
	_sun_azimuth = fmod(_sun_azimuth + delta * 18.0, 360.0)
	_update_sun_direction()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not (event as InputEventKey).pressed:
		return
	if (event as InputEventKey).echo:
		return

	if event.is_action_pressed(ACTION_BAKE_CURRENT) and not _baking:
		_start_current_bake()
	elif event.is_action_pressed(ACTION_DEBUG_NORMALS) and _impostor_renderer._billboard_material:
		var current: bool = _impostor_renderer._billboard_material.get_shader_parameter("debug_normals")
		_impostor_renderer._billboard_material.set_shader_parameter("debug_normals", !current)
		Log.info("impostors", "Normal debug: %s" % (!current))
	elif event.is_action_pressed(ACTION_TOGGLE_MODELS):
		_models_visible = !_models_visible
		_model_container.visible = _models_visible
		Log.info("impostors", "Real models: %s" % ("visible" if _models_visible else "hidden"))


func _start_current_bake() -> void:
	_baking = true
	Log.info("impostors", "Starting v6 batch bake for %d trees..." % TEST_TREES.size())
	_baker = ImpostorBakerV3Script.new()
	add_child(_baker)
	await get_tree().process_frame
	var results := await _baker.bake_models(TEST_TREES)
	var success: int = results.get("success", 0)
	var failed: int = results.get("failed", 0)
	Log.info("impostors", "V6 bake done: %d success, %d failed" % [success, failed])
	_baker.queue_free()
	_baker = null
	_baking = false
	_impostor_renderer.clear()
	_impostor_count = 0
	_missing_v6_count = 0
	_v6_count = 0
	call_deferred("_populate_scene")


func _update_hud() -> void:
	var fps := Engine.get_frames_per_second()
	var bake_str := " [BAKING...]" if _baking else ""
	var model_str := "ON" if _models_visible else "OFF"
	var variant_note := ""
	if _missing_v6_count > 0 and _v6_count == 0:
		variant_note = "\nmissing v6 bakes — runtime fails closed"
	elif _v6_count > 0:
		variant_note = "\nv6 active — tri-sample + yaw-rotated normals"

	_hud.text = (
		"Impostor V6 Test | %d FPS%s\n" % [fps, bake_str]
		+ "%d impostors (%d v6, %d missing v6) | Models: %s\n"
		% [_impostor_count, _v6_count, _missing_v6_count, model_str]
		+ "Camera starts %.0fm out/elevated | Sun: az=%.0f el=%.0f | IJKL=sun | B=bake v6\n"
		% [VALIDATION_CAMERA_DISTANCE, _sun_azimuth, _sun_elevation]
		+ "Animated sun active | "
		+ "WASD=fly | Shift=fast | M=toggle models | N=debug normals | ESC=quit"
		+ variant_note
	)


func _process_smoke(delta: float) -> void:
	if not _smoke_mode or _smoke_result_written:
		return
	_smoke_elapsed += delta
	var stats: Dictionary = _impostor_renderer.get_stats()
	var uploaded := int(stats.get("far_uploaded_instances", 0))
	if uploaded > 0 or _smoke_elapsed >= 8.0:
		_smoke_result_written = true
		var status := "passed" if uploaded > 0 else "failed"
		var result := {
			"status": status,
			"elapsed_s": _smoke_elapsed,
			"impostors": int(stats.get("total_impostors", 0)),
			"far_page_count": int(stats.get("far_page_count", 0)),
			"far_dirty_page_count": int(stats.get("far_dirty_page_count", 0)),
			"far_pages_rebuilt": int(stats.get("far_pages_rebuilt", 0)),
			"far_uploaded_instances": uploaded,
			"far_texture_layers": int(stats.get("texture_array_layers", 0)),
		}
		var dir := "user://benchmark_results"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
		var file := FileAccess.open("%s/impostor_page_smoke.json" % dir, FileAccess.WRITE)
		if file:
			file.store_string(JSON.stringify(result, "\t"))
		Log.info("impostors", "Impostor page smoke %s: %s" % [status, str(result)])
		get_tree().quit(0 if status == "passed" else 1)
