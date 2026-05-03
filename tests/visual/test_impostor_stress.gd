## Standalone FAR impostor stress scene.
##
## Loads real ESM exterior refs and drives NativeImpostorRenderer directly,
## without terrain, MID, HLOD, CellManager, or scenes/Godotwind.tscn.
##
## Controls:
##   move_* / jump / crouch / sprint - fly camera
##   mouse drag - look
##   mouse wheel - speed
##   impostor_debug_normals - toggle normal debug
##   impostor_stress_toggle_bounds - toggle page AABB wire overlay
##   impostor_stress_force_visible - show all impostors from any distance
##   impostor_stress_reload_area - clear and reload current 60-cell FAR ring
##   ui_cancel - release mouse / quit
extends Node3D

const DU := preload("res://src/core/world/distance_utils.gd")
const NativeImpostorRendererScript := preload("res://src/core/world/native_impostor_renderer.gd")
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")

const START_CELL := Vector2i(-2, -9)
const IMPOSTOR_RADIUS_CELLS: int = 60
const LOAD_BUDGET_USEC: float = 15000.0
const MOUSE_SENSITIVITY: float = 0.002
const BASE_FLY_SPEED: float = 180.0
const SPRINT_MULTIPLIER: float = 4.0
const HUD_INTERVAL: float = 0.15
const BOUNDS_INTERVAL: float = 0.5
const AUTO_SPEED: float = 120.0
const ATLAS_SIZES: Array[int] = [512, 1024]

const ACTION_DEBUG_NORMALS := &"impostor_debug_normals"
const ACTION_TOGGLE_BOUNDS := &"impostor_stress_toggle_bounds"
const ACTION_FORCE_VISIBLE := &"impostor_stress_force_visible"
const ACTION_RELOAD_AREA := &"impostor_stress_reload_area"

var _camera: Camera3D
var _hud: RichTextLabel
var _renderer: NativeImpostorRendererScript
var _candidates: ImpostorCandidatesScript
var _bounds_mesh: ImmediateMesh
var _bounds_instance: MeshInstance3D
var _bounds_material: StandardMaterial3D

var _mouse_captured: bool = true
var _camera_yaw: float = 0.0
var _camera_pitch: float = -12.0
var _fly_speed: float = BASE_FLY_SPEED
var _last_camera_cell: Vector2i = Vector2i(999999, 999999)
var _hud_timer: float = 0.0
var _bounds_timer: float = 0.0
var _bounds_visible: bool = true
var _force_visible: bool = false
var _loading_stage: String = "Booting"
var _area_updates: int = 0
var _esm_loaded: bool = false
var _auto_duration: float = 0.0
var _auto_elapsed: float = 0.0
var _auto_started: bool = false
var _summary_stamp: String = "impostor_stress"
var _frame_count: int = 0
var _max_frame_ms: float = 0.0
var _max_texture_upload_ms: float = 0.0
var _max_normal_upload_ms: float = 0.0
var _max_pack_ms: float = 0.0
var _max_upload_ms: float = 0.0
var _max_total_impostors: int = 0
var _max_uploaded_instances: int = 0
var _max_texture_layers: int = 0
var _max_texture_upload_ms_by_size: Dictionary[int, float] = {}
var _max_normal_upload_ms_by_size: Dictionary[int, float] = {}
var _max_texture_layers_by_size: Dictionary[int, int] = {}
var _max_texture_slabs_by_size: Dictionary[int, int] = {}
var _warmup_remaining: int = 5


func _ready() -> void:
	InputActions.verify()
	_verify_test_actions()
	var args := OS.get_cmdline_user_args()
	_force_visible = "--force-visible" in args or "--all-visible" in args
	_bounds_visible = not "--hide-bounds" in args
	_auto_duration = _get_float_arg(args, "--auto-duration=", 0.0)
	_summary_stamp = _get_string_arg(args, "--stamp=", _summary_stamp)
	_setup_environment()
	_setup_camera()
	_setup_hud()
	_setup_bounds_debug()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_load_and_start.call_deferred()


func _verify_test_actions() -> void:
	for action_name: StringName in InputActions.VISUAL_TEST:
		if not InputMap.has_action(action_name):
			Log.error("input", "Missing visual test action: %s" % action_name)
			assert(false, "missing visual test action: %s" % action_name)


func _setup_environment() -> void:
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	light.rotation_degrees = Vector3(-35.0, 35.0, 0.0)
	light.light_energy = 1.4
	light.shadow_enabled = false
	add_child(light)

	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.28, 0.36, 0.48)
	sky_mat.sky_horizon_color = Color(0.62, 0.68, 0.74)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.65
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_density = 0.00008
	world_env.environment = env
	add_child(world_env)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "StressCamera"
	_camera.far = 8000.0
	_camera.fov = 65.0
	_camera.position = DU.cell_to_world_center(START_CELL, 180.0)
	_camera.rotation_degrees = Vector3(_camera_pitch, _camera_yaw, 0.0)
	_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_camera)
	_camera.make_current()


func _setup_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "HUD"
	add_child(canvas)
	_hud = RichTextLabel.new()
	_hud.bbcode_enabled = true
	_hud.fit_content = true
	_hud.scroll_active = false
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.position = Vector2(10, 10)
	_hud.size = Vector2(760, 520)
	_hud.add_theme_font_size_override("normal_font_size", 14)
	canvas.add_child(_hud)


func _setup_bounds_debug() -> void:
	_bounds_mesh = ImmediateMesh.new()
	_bounds_material = StandardMaterial3D.new()
	_bounds_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_bounds_material.albedo_color = Color(0.1, 0.95, 1.0, 0.75)
	_bounds_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_bounds_instance = MeshInstance3D.new()
	_bounds_instance.name = "ImpostorPageBounds"
	_bounds_instance.mesh = _bounds_mesh
	_bounds_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bounds_instance.visible = _bounds_visible
	add_child(_bounds_instance)


func _load_and_start() -> void:
	_loading_stage = "Loading ESM"
	_update_hud()
	await get_tree().process_frame

	if ESMManager.cells.size() == 0:
		var esm_path: String = SettingsManager.get_data_path().path_join(SettingsManager.get_esm_file())
		var err: Error = ESMManager.load_file(esm_path)
		if err != OK:
			_loading_stage = "ESM load failed: %s" % error_string(err)
			Log.error("impostors", _loading_stage)
			_update_hud()
			return

	_esm_loaded = true
	_loading_stage = "Starting impostor renderer"
	_setup_renderer()
	await get_tree().process_frame
	_request_current_area(true)
	_loading_stage = "Streaming impostors"
	_auto_started = _auto_duration > 0.0
	_frame_count = 0
	_warmup_remaining = 5


func _setup_renderer() -> void:
	_candidates = ImpostorCandidatesScript.new()
	_renderer = NativeImpostorRendererScript.new()
	_renderer.name = "NativeImpostorRendererStress"
	_renderer.debug_enabled = false
	_renderer.set_impostor_candidates(_candidates)
	_renderer.set_load_budget_usec(LOAD_BUDGET_USEC)
	add_child(_renderer)
	_apply_visibility_mode()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		var motion := event as InputEventMouseMotion
		_camera_yaw -= motion.relative.x * MOUSE_SENSITIVITY * (180.0 / PI)
		_camera_pitch -= motion.relative.y * MOUSE_SENSITIVITY * (180.0 / PI)
		_camera_pitch = clampf(_camera_pitch, -89.0, 89.0)

	if event is InputEventMouseButton and event.pressed:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_fly_speed = minf(_fly_speed * 1.25, 2500.0)
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_fly_speed = maxf(_fly_speed / 1.25, 20.0)
		elif button.button_index == MOUSE_BUTTON_LEFT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			_mouse_captured = true

	if event is InputEventKey and event.pressed and not event.echo:
		if event.is_action_pressed(ACTION_TOGGLE_BOUNDS):
			_bounds_visible = not _bounds_visible
			_bounds_instance.visible = _bounds_visible
		elif event.is_action_pressed(ACTION_FORCE_VISIBLE):
			_force_visible = not _force_visible
			_apply_visibility_mode()
		elif event.is_action_pressed(ACTION_DEBUG_NORMALS):
			_toggle_normal_debug()
		elif event.is_action_pressed(ACTION_RELOAD_AREA):
			_reload_current_area()
		elif event.is_action_pressed("ui_cancel"):
			if _mouse_captured:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				_mouse_captured = false
			else:
				get_tree().quit()


func _process(delta: float) -> void:
	if _auto_started:
		_frame_count += 1
		_record_benchmark_sample()
		_process_auto_camera(delta)
	else:
		_process_camera(delta)
	_process_area_update()

	_hud_timer += delta
	if _hud_timer >= HUD_INTERVAL:
		_hud_timer = 0.0
		_update_hud()

	if _bounds_visible:
		_bounds_timer += delta
		if _bounds_timer >= BOUNDS_INTERVAL:
			_bounds_timer = 0.0
			_rebuild_bounds_mesh()

	if _auto_started:
		_auto_elapsed += delta
		if _auto_elapsed >= _auto_duration:
			_write_auto_summary()
			get_tree().quit()


func _get_float_arg(args: PackedStringArray, prefix: String, fallback: float) -> float:
	for arg: String in args:
		if arg.begins_with(prefix):
			return maxf(0.0, float(arg.trim_prefix(prefix)))
	return fallback


func _get_string_arg(args: PackedStringArray, prefix: String, fallback: String) -> String:
	for arg: String in args:
		if arg.begins_with(prefix):
			var value := arg.trim_prefix(prefix).strip_edges()
			if not value.is_empty():
				return value
	return fallback


func _process_auto_camera(delta: float) -> void:
	if not _camera:
		return
	var angle := _auto_elapsed * 0.18
	var center := DU.cell_to_world_center(START_CELL, 180.0)
	var radius := 900.0
	_camera.position = center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
	_camera.look_at(center + Vector3(0.0, -40.0, 0.0), Vector3.UP)


func _record_benchmark_sample() -> void:
	if _warmup_remaining > 0:
		_warmup_remaining -= 1
		return
	var stats := _get_renderer_stats()
	var frame_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	_max_frame_ms = maxf(_max_frame_ms, frame_ms)
	_max_texture_upload_ms = maxf(_max_texture_upload_ms, float(stats.get("far_texture_upload_us", 0)) / 1000.0)
	_max_normal_upload_ms = maxf(_max_normal_upload_ms, float(stats.get("far_normal_upload_us", 0)) / 1000.0)
	for atlas_size: int in ATLAS_SIZES:
		_max_texture_upload_ms_by_size[atlas_size] = maxf(
			_max_texture_upload_ms_by_size.get(atlas_size, 0.0),
			float(stats.get("far_texture_upload_us_%d" % atlas_size, 0)) / 1000.0
		)
		_max_normal_upload_ms_by_size[atlas_size] = maxf(
			_max_normal_upload_ms_by_size.get(atlas_size, 0.0),
			float(stats.get("far_normal_upload_us_%d" % atlas_size, 0)) / 1000.0
		)
		_max_texture_layers_by_size[atlas_size] = maxi(
			_max_texture_layers_by_size.get(atlas_size, 0),
			int(stats.get("far_texture_layers_%d" % atlas_size, 0))
		)
		_max_texture_slabs_by_size[atlas_size] = maxi(
			_max_texture_slabs_by_size.get(atlas_size, 0),
			int(stats.get("far_texture_slabs_%d" % atlas_size, 0))
		)
	_max_pack_ms = maxf(_max_pack_ms, float(stats.get("far_multimesh_pack_us", 0)) / 1000.0)
	_max_upload_ms = maxf(_max_upload_ms, float(stats.get("far_multimesh_upload_us", 0)) / 1000.0)
	_max_total_impostors = maxi(_max_total_impostors, int(stats.get("total_impostors", 0)))
	_max_uploaded_instances = maxi(_max_uploaded_instances, int(stats.get("far_uploaded_instances", 0)))
	_max_texture_layers = maxi(_max_texture_layers, int(stats.get("texture_array_layers", 0)))


func _write_auto_summary() -> void:
	var dir := "user://benchmark_results"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var summary := {
		"stamp": _summary_stamp,
		"duration_s": _auto_duration,
		"frames": _frame_count,
		"avg_fps": float(_frame_count) / maxf(_auto_elapsed, 0.001),
		"max_frame_ms": _max_frame_ms,
		"max_texture_upload_ms": _max_texture_upload_ms,
		"max_normal_upload_ms": _max_normal_upload_ms,
		"max_multimesh_pack_ms": _max_pack_ms,
		"max_multimesh_upload_ms": _max_upload_ms,
		"max_total_impostors": _max_total_impostors,
		"max_uploaded_instances": _max_uploaded_instances,
		"max_texture_layers": _max_texture_layers,
	}
	for atlas_size: int in ATLAS_SIZES:
		summary["max_texture_upload_ms_%d" % atlas_size] = _max_texture_upload_ms_by_size.get(atlas_size, 0.0)
		summary["max_normal_upload_ms_%d" % atlas_size] = _max_normal_upload_ms_by_size.get(atlas_size, 0.0)
		summary["max_texture_layers_%d" % atlas_size] = _max_texture_layers_by_size.get(atlas_size, 0)
		summary["max_texture_slabs_%d" % atlas_size] = _max_texture_slabs_by_size.get(atlas_size, 0)
	var path := "%s/impostor_stress_%s.json" % [dir, _summary_stamp]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(summary, "\t"))
		f.close()
	Log.info("impostors", "[AUTO] summary=%s json=%s" % [JSON.stringify(summary), path])


func _process_camera(delta: float) -> void:
	if not _camera:
		return
	_camera.rotation_degrees = Vector3(_camera_pitch, _camera_yaw, 0.0)
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var forward := -_camera.global_transform.basis.z
	var right_vec := _camera.global_transform.basis.x
	var velocity := (right_vec * input_dir.x + forward * (-input_dir.y))
	if Input.is_action_pressed("jump"):
		velocity.y += 1.0
	if Input.is_action_pressed("crouch"):
		velocity.y -= 1.0
	if velocity.length() <= 0.0:
		return
	var speed := _fly_speed * (SPRINT_MULTIPLIER if Input.is_action_pressed("sprint") else 1.0)
	_camera.position += velocity.normalized() * speed * delta


func _process_area_update() -> void:
	if not _esm_loaded or not _renderer:
		return
	var camera_cell := DU.world_to_cell(_camera.global_position)
	if camera_cell == _last_camera_cell:
		return
	_request_area(camera_cell)


func _request_current_area(force: bool = false) -> void:
	var camera_cell := DU.world_to_cell(_camera.global_position)
	if force or camera_cell != _last_camera_cell:
		_request_area(camera_cell)


func _request_area(camera_cell: Vector2i) -> void:
	_last_camera_cell = camera_cell
	_area_updates += 1
	_renderer.update_impostor_area(camera_cell, IMPOSTOR_RADIUS_CELLS)


func _reload_current_area() -> void:
	if not _renderer:
		return
	_renderer.clear()
	_last_camera_cell = Vector2i(999999, 999999)
	_apply_visibility_mode()
	_request_current_area(true)


func _apply_visibility_mode() -> void:
	if not _renderer:
		return
	if _force_visible:
		_renderer.set_force_visible_for_test(true)
	else:
		_renderer.set_visibility_range_begin(DU.MID_END, DU.FADE_MARGIN_RENDER_FAR)


func _toggle_normal_debug() -> void:
	if not _renderer:
		return
	var material := _renderer.get("_billboard_material") as ShaderMaterial
	if not material:
		return
	var current_value: Variant = material.get_shader_parameter("debug_normals")
	var current: bool = current_value == true
	if _renderer.has_method("set_normal_debug_for_test"):
		_renderer.set_normal_debug_for_test(not current)
	else:
		material.set_shader_parameter("debug_normals", not current)


func _get_renderer_stats() -> Dictionary:
	if _renderer and _renderer.has_method("get_stats"):
		return _renderer.get_stats()
	return {}


func _update_hud() -> void:
	if not _hud:
		return
	var p := Performance
	var stats := _get_renderer_stats()
	var fps := p.get_monitor(p.TIME_FPS)
	var frame_ms := p.get_monitor(p.TIME_PROCESS) * 1000.0
	var draws := int(p.get_monitor(p.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var objects := int(p.get_monitor(p.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var primitives := int(p.get_monitor(p.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var camera_cell := DU.world_to_cell(_camera.global_position) if _camera else Vector2i.ZERO
	var total_impostors := int(stats.get("total_impostors", 0))
	var uploaded := int(stats.get("far_uploaded_instances", 0))
	var pending_cells := int(stats.get("pending_loads", 0))
	var pending_textures := int(stats.get("pending_texture_loads", 0))
	var pending_impostors := int(stats.get("pending_impostors", 0))
	var loaded_cells := int(stats.get("loaded_impostor_cells", 0))
	var page_count := int(stats.get("far_page_count", 0))
	var visible_pages := int(stats.get("far_visible_page_count", 0))
	var dirty_pages := int(stats.get("far_dirty_page_count", 0))
	var pages_rebuilt := int(stats.get("far_pages_rebuilt", 0))
	var texture_layers := int(stats.get("texture_array_layers", 0))
	var texture_layers_512 := int(stats.get("far_texture_layers_512", 0))
	var texture_layers_1024 := int(stats.get("far_texture_layers_1024", 0))
	var texture_upload_ms := float(stats.get("far_texture_upload_us", 0)) / 1000.0
	var normal_upload_ms := float(stats.get("far_normal_upload_us", 0)) / 1000.0
	var texture_upload_512_ms := float(stats.get("far_texture_upload_us_512", 0)) / 1000.0
	var texture_upload_1024_ms := float(stats.get("far_texture_upload_us_1024", 0)) / 1000.0
	var normal_upload_512_ms := float(stats.get("far_normal_upload_us_512", 0)) / 1000.0
	var normal_upload_1024_ms := float(stats.get("far_normal_upload_us_1024", 0)) / 1000.0
	var pack_ms := float(stats.get("far_multimesh_pack_us", 0)) / 1000.0
	var upload_ms := float(stats.get("far_multimesh_upload_us", 0)) / 1000.0
	var scan_ms := float(stats.get("far_cell_scan_us", 0)) / 1000.0
	var cells_processed := int(stats.get("far_cells_processed_last_frame", 0))
	var ready_created := int(stats.get("far_ready_created", 0))
	var force_text := "ALL" if _force_visible else "FAR >= %.0fm" % DU.MID_END
	var force_note := "[color=orange]diagnostic only; near impostors can overlap/halo[/color]" if _force_visible else "tier-accurate"
	var bounds_text := "ON" if _bounds_visible else "OFF"

	_hud.text = """[b]Impostor Stress - real FAR ring, no main scene[/b]
Stage: %s  |  Area updates: %d  |  Camera cell: %s  |  Radius: %d cells
Visibility: %s (%s)  |  Page bounds: %s

[b]Frame[/b]
  FPS: %.0f  |  Frame: %.2fms  |  Draws: %d  |  Objects: %d  |  Prims: %dk

[b]Impostor Renderer[/b]
  Loaded cells: %d  |  Pending cells: %d  |  Cell scan: %.2fms (%d cells this frame)
  Total impostors: %d  |  Uploaded slots: %d  |  Ready created/frame: %d
  Texture layers: %d total  |  512: %d/256  |  1024: %d/256
  Pending textures: %d  |  Pending impostor hashes: %d
  Upload last: %.2fms texture / %.2fms normal
  Upload buckets: 512 %.2f/%.2fms  |  1024 %.2f/%.2fms

[b]Paged MultiMesh[/b]
  Pages: %d  |  Visible page nodes: %d  |  Dirty pages: %d  |  Rebuilt/frame: %d
  Pack: %.2fms  |  Upload: %.2fms

[b]What optimized looks like[/b]
  Page count should grow by spatial pages, not one global object.
  Dirty pages and rebuilt/frame should settle near 0 when you stop moving.
  Draw calls should stay tied to visible pages/materials, not impostor count.

[b]Controls[/b]
  WASD/Space/C/Shift fly  |  Wheel speed %.0fm/s
  F5 bounds  |  F6 force-visible  |  F7 reload ring  |  N normals  |  ESC release/quit""" % [
		_loading_stage, _area_updates, str(camera_cell), IMPOSTOR_RADIUS_CELLS,
		force_text, force_note, bounds_text,
		fps, frame_ms, draws, objects, primitives / 1000,
		loaded_cells, pending_cells, scan_ms, cells_processed,
		total_impostors, uploaded, ready_created,
		texture_layers, texture_layers_512, texture_layers_1024,
		pending_textures, pending_impostors,
		texture_upload_ms, normal_upload_ms,
		texture_upload_512_ms, normal_upload_512_ms, texture_upload_1024_ms, normal_upload_1024_ms,
		page_count, visible_pages, dirty_pages, pages_rebuilt,
		pack_ms, upload_ms,
		_fly_speed,
	]


func _rebuild_bounds_mesh() -> void:
	if not _renderer or not _bounds_mesh:
		return
	var page_container := _renderer.get_node_or_null("ImpostorPages")
	_bounds_mesh.clear_surfaces()
	if page_container == null:
		return
	var line_count := 0
	_bounds_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _bounds_material)
	for child: Node in page_container.get_children():
		if not child is MultiMeshInstance3D:
			continue
		var page_instance := child as MultiMeshInstance3D
		var aabb := page_instance.custom_aabb
		if aabb.size.length_squared() <= 0.0:
			continue
		var min_pos := page_instance.global_position + aabb.position
		var max_pos := min_pos + aabb.size
		_add_box_lines(min_pos, max_pos)
		line_count += 12
	if line_count > 0:
		_bounds_mesh.surface_end()
	else:
		_bounds_mesh.clear_surfaces()


func _add_box_lines(min_pos: Vector3, max_pos: Vector3) -> void:
	var p000 := Vector3(min_pos.x, min_pos.y, min_pos.z)
	var p001 := Vector3(min_pos.x, min_pos.y, max_pos.z)
	var p010 := Vector3(min_pos.x, max_pos.y, min_pos.z)
	var p011 := Vector3(min_pos.x, max_pos.y, max_pos.z)
	var p100 := Vector3(max_pos.x, min_pos.y, min_pos.z)
	var p101 := Vector3(max_pos.x, min_pos.y, max_pos.z)
	var p110 := Vector3(max_pos.x, max_pos.y, min_pos.z)
	var p111 := Vector3(max_pos.x, max_pos.y, max_pos.z)
	_add_line(p000, p001)
	_add_line(p001, p101)
	_add_line(p101, p100)
	_add_line(p100, p000)
	_add_line(p010, p011)
	_add_line(p011, p111)
	_add_line(p111, p110)
	_add_line(p110, p010)
	_add_line(p000, p010)
	_add_line(p001, p011)
	_add_line(p100, p110)
	_add_line(p101, p111)


func _add_line(a: Vector3, b: Vector3) -> void:
	_bounds_mesh.surface_add_vertex(a)
	_bounds_mesh.surface_add_vertex(b)
