extends Node3D

## Standalone ripple debug scene. No terrain, no inherited Ocean Lab UI.
## Shows the ripple atlas directly on ocean/volume water by default.

@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access")

const FlyCameraScript := preload("res://src/core/player/fly_camera.gd")
const InputActionsScript := preload("res://src/core/input/input_actions.gd")
const WaterInteractorScript := preload("res://src/core/water/water_interactor.gd")
const WaterVolumeScript := preload("res://src/core/water/water_volume.gd")
const FastWaterVolumeShader := preload("res://tests/visual/test_water_interaction_fast_volume.gdshader")
const DefaultWaterNormalTexture := preload("res://assets/water/water_normal.png")
const DefaultWaterFoamTexture := preload("res://src/core/water/textures/foam_albedo.png")

const WATER_RENDER_LAYER_MASK: int = 1 << 19
const SMOKE_GPU_MS_LIMIT := 2.0
const GRAB_RANGE_M := 40.0
const GRAB_DISTANCE_M := 5.0
const GRAB_PULL := 12.0
const GRAB_MAX_SPEED := 24.0
const PLAY_BALL_RADIUS := 0.65
const TEST_OCEAN_RADIUS_M := 96.0
const TEST_RIPPLE_HEIGHT_STRENGTH := 0.16
const TEST_RIPPLE_NORMAL_STRENGTH := 4.0
const TEST_RIPPLE_FOAM_STRENGTH := 0.18

var _camera: Camera3D = null
var _debug_label: RichTextLabel = null
var _debug_enabled: bool = false
var _smoke_mode: bool = false
var _time: float = 0.0
var _movers: Array[Node3D] = []
var _water_volumes: Array[WaterVolume] = []
var _play_ball: RigidBody3D = null
var _play_ball_interactor: WaterInteractor = null
var _held_ball: RigidBody3D = null
var _grab_marker: MeshInstance3D = null
var _perf_log_elapsed: float = 0.0
var _perf_frame_ms_accum: float = 0.0
var _perf_frame_count: int = 0
var _hud_update_elapsed: float = 0.0


func _ready() -> void:
	_smoke_mode = OS.get_cmdline_args().has("--water-ripple-smoke")
	DisplayServer.window_set_title("Godotwind - Water Interaction Ripples Debug")
	InputActionsScript.verify()
	_build_environment()
	_build_camera()
	_setup_ocean()
	_make_volume("DebugLake", WaterVolume.WaterType.LAKE, Vector3(20.0, 4.0, 16.0), Vector3(-12.0, 0.0, 0.0), Vector2.RIGHT, 0.0)
	_make_volume("DebugRiver", WaterVolume.WaterType.RIVER, Vector3(28.0, 4.0, 6.0), Vector3(14.0, 0.0, 0.0), Vector2.RIGHT, 2.5)
	_make_play_ball()
	_build_ui()
	_apply_debug_mode()

	if _smoke_mode:
		await _run_smoke()


func _process(delta: float) -> void:
	_time += delta
	_update_movers(delta)
	_update_grab_marker()
	_update_water_interaction_manual(delta)
	_hud_update_elapsed += delta
	if _hud_update_elapsed >= 0.25:
		_hud_update_elapsed = 0.0
		_update_debug_label()
	_log_perf_periodically(delta)
	_perf_frame_ms_accum += delta * 1000.0
	_perf_frame_count += 1


func _physics_process(_delta: float) -> void:
	_update_held_ball()
	_emit_ball_interactions(_delta)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"interact"):
		_toggle_ball_grab()


func _build_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_energy = 4.0
	sun.rotation_degrees = Vector3(-48.0, 35.0, 0.0)
	add_child(sun)

	var fill := OmniLight3D.new()
	fill.name = "WarmFillLight"
	fill.light_energy = 6.0
	fill.omni_range = 42.0
	fill.position = Vector3(-12.0, 9.0, 10.0)
	add_child(fill)

	var rim := OmniLight3D.new()
	rim.name = "CoolRiverLight"
	rim.light_color = Color(0.45, 0.72, 1.0)
	rim.light_energy = 4.5
	rim.omni_range = 38.0
	rim.position = Vector3(18.0, 7.5, -8.0)
	add_child(rim)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.18, 0.23, 0.27)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.58, 0.66, 0.72)
	environment.ambient_light_energy = 1.15
	env.environment = environment
	add_child(env)

	var floor := MeshInstance3D.new()
	floor.name = "MatteReferenceFloor"
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(58.0, 34.0)
	floor.mesh = floor_mesh
	floor.position = Vector3(1.0, -1.25, 0.0)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.12, 0.13, 0.12)
	floor_mat.roughness = 0.85
	floor.material_override = floor_mat
	add_child(floor)

	var floor_body := StaticBody3D.new()
	floor_body.name = "ReferenceFloorCollision"
	floor_body.position = floor.position
	var floor_collision := CollisionShape3D.new()
	var floor_shape := BoxShape3D.new()
	floor_shape.size = Vector3(58.0, 0.12, 34.0)
	floor_collision.shape = floor_shape
	floor_body.add_child(floor_collision)
	add_child(floor_body)


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "RippleDebugFlyCamera"
	_camera.set_script(FlyCameraScript)
	_camera.current = true
	_camera.far = 20000.0
	_camera.cull_mask = _camera.cull_mask | WATER_RENDER_LAYER_MASK
	add_child(_camera)
	_camera.global_position = Vector3(0.0, 14.0, 32.0)
	_camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
	(_camera as FlyCamera).move_speed = 20.0
	(_camera as FlyCamera).enable()


func _setup_ocean() -> void:
	if WaterSystem == null:
		push_error("[WaterInteractionRipples] WaterSystem missing")
		return
	ProjectSettings.set_setting("ocean/quality", 0)
	ProjectSettings.set_setting("ocean/radius", TEST_OCEAN_RADIUS_M)
	WaterSystem.water_quality = 0
	WaterSystem.ocean_radius = TEST_OCEAN_RADIUS_M
	WaterSystem.sea_spray_enabled = false
	WaterSystem.underwater_particles_enabled = false
	WaterSystem.force_initialize()
	WaterSystem.set_process(false)
	WaterSystem.set_physics_process(false)
	WaterSystem.set_camera(_camera)
	WaterSystem.set_sea_level(-2.0)
	WaterSystem.set_water_quality(0)
	if WaterSystem.has_method("_dispose_spray_layer"):
		WaterSystem.call("_dispose_spray_layer")
	if WaterSystem.has_method("_dispose_underwater_particulates_layer"):
		WaterSystem.call("_dispose_underwater_particulates_layer")
	var ocean_mesh := WaterSystem.get("_ocean_mesh") as Node3D
	if ocean_mesh != null:
		ocean_mesh.visible = false
	WaterSystem.set_wave_scale(0.08)
	WaterSystem.set_water_interaction_debug_enabled(_debug_enabled)


func _make_volume(volume_name: String, type_id: int, dimensions: Vector3, pos: Vector3, flow: Vector2, speed: float) -> void:
	var volume: WaterVolume = WaterVolumeScript.new()
	volume.name = volume_name
	volume.water_type = type_id
	volume.size = dimensions
	volume.water_surface_height = 0.0
	volume.flow_direction = flow
	volume.flow_speed = speed
	volume.current_strength = 1.0
	volume.water_color = Color(0.02, 0.18, 0.20, 1.0)
	volume.position = pos
	add_child(volume)
	_water_volumes.append(volume)
	if is_instance_valid(WaterSystem):
		var register_err: Error = WaterSystem.register_water_body(volume.get_water_body_descriptor())
		WaterSystem.register_water_interaction_renderer(volume)
		var stats: Dictionary = WaterSystem.get_water_body_runtime_status()
		var registry_stats := stats.get("registry", {}) as Dictionary
		Log.info("water", "[WaterInteractionRipples] registered %s err=%d bodies=%d" % [
			volume.name,
			register_err,
			int(registry_stats.get("body_count", 0)),
		])
	_tune_water_volume_material(volume)


func _tune_water_volume_material(volume: WaterVolume) -> void:
	var material := volume.get("_material") as ShaderMaterial
	if material == null:
		return
	material.shader = FastWaterVolumeShader
	material.set_shader_parameter("water_color", volume.water_color)
	material.set_shader_parameter("roughness", 0.18)
	material.set_shader_parameter("water_surface_shallow_color", Vector3(volume.water_color.r, volume.water_color.g, volume.water_color.b))
	material.set_shader_parameter("water_surface_deep_color", Vector3(volume.water_color.r * 0.42, volume.water_color.g * 0.58, volume.water_color.b * 0.72))
	material.set_shader_parameter("water_surface_medium_color", Vector3(volume.water_color.r * 0.65, volume.water_color.g * 0.72, volume.water_color.b * 0.78))
	material.set_shader_parameter("water_surface_foam_color", Vector3(0.82, 0.90, 0.88))
	material.set_shader_parameter("water_surface_visibility_distance_m", 24.0)
	material.set_shader_parameter("water_surface_absorption_density", 0.24)
	material.set_shader_parameter("water_surface_refraction_strength", 0.045)
	material.set_shader_parameter("water_surface_roughness", 0.12)
	material.set_shader_parameter("water_surface_clarity", 0.72)
	material.set_shader_parameter("water_surface_normal_strength", 0.45)
	material.set_shader_parameter("water_surface_normal_uv_scale", 0.12)
	material.set_shader_parameter("water_surface_foam_intensity", 0.35)
	material.set_shader_parameter("water_surface_normal_texture", DefaultWaterNormalTexture)
	material.set_shader_parameter("water_surface_foam_texture", DefaultWaterFoamTexture)
	material.set_shader_parameter("wave_scale", volume.wave_scale)
	material.set_shader_parameter("flow_direction", volume.flow_direction)
	material.set_shader_parameter("flow_speed", volume.flow_speed if volume.water_type == WaterVolume.WaterType.RIVER else 0.0)
	material.set_shader_parameter("debug_display_mode", volume.debug_display_mode)
	material.set_shader_parameter("water_interaction_height_strength", TEST_RIPPLE_HEIGHT_STRENGTH)
	material.set_shader_parameter("water_interaction_normal_strength", TEST_RIPPLE_NORMAL_STRENGTH)
	material.set_shader_parameter("water_interaction_foam_strength", TEST_RIPPLE_FOAM_STRENGTH)


func _make_probe_mover(node_name: String, pos: Vector3, radius: float) -> void:
	var sphere := MeshInstance3D.new()
	sphere.name = node_name
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	sphere.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.52, 0.12)
	mat.emission_enabled = true
	mat.emission = Color(0.65, 0.20, 0.03)
	mat.roughness = 0.35
	sphere.material_override = mat
	add_child(sphere)
	sphere.global_position = pos

	var interactor: WaterInteractor = WaterInteractorScript.new()
	interactor.radius_m = radius
	interactor.impact_strength = 0.7
	interactor.wake_strength = 0.22
	interactor.wake_interval_m = 0.0
	interactor.wake_interval_s = 0.0
	interactor.surface_band_m = radius + 0.28
	sphere.add_child(interactor)
	_movers.append(sphere)


func _make_play_ball() -> void:
	_play_ball = RigidBody3D.new()
	_play_ball.name = "GrabRippleBall"
	_play_ball.mass = 4.0
	_play_ball.gravity_scale = 0.2
	_play_ball.linear_damp = 1.1
	_play_ball.angular_damp = 0.35
	_play_ball.position = Vector3(-12.0, 1.2, 3.4)
	add_child(_play_ball)

	var collision := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = PLAY_BALL_RADIUS
	collision.shape = shape
	_play_ball.add_child(collision)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "BallMesh"
	var mesh := SphereMesh.new()
	mesh.radius = PLAY_BALL_RADIUS
	mesh.height = PLAY_BALL_RADIUS * 2.0
	mesh_instance.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.18, 0.08)
	mat.roughness = 0.42
	mat.metallic = 0.0
	mesh_instance.material_override = mat
	_play_ball.add_child(mesh_instance)

	_play_ball_interactor = WaterInteractorScript.new()
	_play_ball_interactor.auto_register = false
	_play_ball_interactor.radius_m = PLAY_BALL_RADIUS
	_play_ball_interactor.impact_strength = 1.3
	_play_ball_interactor.wake_strength = 0.34
	_play_ball_interactor.wake_interval_m = 0.0
	_play_ball_interactor.wake_interval_s = 0.0
	_play_ball_interactor.surface_band_m = PLAY_BALL_RADIUS + 0.38
	_play_ball.add_child(_play_ball_interactor)

	_grab_marker = MeshInstance3D.new()
	_grab_marker.name = "GrabTargetMarker"
	var marker_mesh := SphereMesh.new()
	marker_mesh.radius = 0.08
	marker_mesh.height = 0.16
	_grab_marker.mesh = marker_mesh
	var marker_mat := StandardMaterial3D.new()
	marker_mat.albedo_color = Color(0.2, 0.8, 1.0)
	marker_mat.emission_enabled = true
	marker_mat.emission = Color(0.05, 0.45, 0.9)
	_grab_marker.material_override = marker_mat
	_grab_marker.visible = false
	add_child(_grab_marker)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "RippleDebugUI"
	add_child(layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(12.0, 12.0)
	panel.size = Vector2(430.0, 190.0)
	layer.add_child(panel)

	var box := VBoxContainer.new()
	panel.add_child(box)

	var toggle := CheckBox.new()
	toggle.text = "Ripple debug view"
	toggle.button_pressed = _debug_enabled
	toggle.toggled.connect(func(enabled: bool) -> void:
		_debug_enabled = enabled
		_apply_debug_mode()
	)
	box.add_child(toggle)

	_debug_label = RichTextLabel.new()
	_debug_label.bbcode_enabled = false
	_debug_label.fit_content = false
	_debug_label.scroll_active = false
	_debug_label.size = Vector2(410.0, 140.0)
	box.add_child(_debug_label)


func _apply_debug_mode() -> void:
	if WaterSystem != null:
		WaterSystem.set_water_interaction_debug_enabled(_debug_enabled)


func _update_movers(_delta: float) -> void:
	for i in range(_movers.size()):
		var mover := _movers[i]
		if not is_instance_valid(mover):
			continue
		var base_x: float = PackedFloat32Array([-17.0, -8.0, 8.0, 19.0])[i]
		var phase := _time * (0.9 + float(i) * 0.17)
		mover.global_position = Vector3(
			base_x + sin(phase) * 2.0,
			0.04 + sin(phase * 1.65) * 0.26,
			cos(phase * 0.8) * (1.3 if i < 2 else 1.8)
		)


func _emit_debug_impulses() -> void:
	_emit_debug_impulse_burst(4)


func _emit_debug_impulse_burst(count: int) -> void:
	if WaterSystem == null:
		return
	var positions := [
		Vector3(-17.0 + sin(_time) * 2.0, 0.0, cos(_time * 0.8) * 1.3),
		Vector3(-8.0 + sin(_time * 1.2) * 2.0, 0.0, cos(_time) * 1.3),
		Vector3(8.0 + sin(_time * 1.1) * 2.0, 0.0, cos(_time * 0.9) * 1.8),
		Vector3(19.0 + sin(_time * 0.95) * 2.0, 0.0, cos(_time * 0.7) * 1.8),
	]
	for i in range(count):
		var base: Vector3 = positions[i % positions.size()]
		var row := float(i / positions.size())
		var offset := Vector3(sin(float(i) * 1.37) * 0.85, 0.0, cos(float(i) * 0.91) * 0.85 + row * 0.015)
		if _smoke_mode:
			var sim := WaterSystem.get("_water_interaction_sim") as WaterInteractionSim
			if sim != null:
				sim.queue_impulse(base + offset, 0.55 + float(i % positions.size()) * 0.05, 2.0, -2.0, 1.0, false)
			continue
		WaterSystem.emit_water_impulse(
			base + offset,
			0.55 + float(i % positions.size()) * 0.05,
			2.0,
			&"impact",
			WaterSurfaceState.WATER_BODY_OCEAN
		)


func _update_debug_label() -> void:
	if _debug_label == null or WaterSystem == null:
		return
	var stats: Dictionary = WaterSystem.get_water_interaction_stats()
	var body_stats: Dictionary = WaterSystem.get_water_body_runtime_status() if WaterSystem.has_method("get_water_body_runtime_status") else {}
	var fps := int(Engine.get_frames_per_second())
	var frame_ms := _average_frame_ms()
	_debug_label.text = "\n".join([
		"fps: %d   avg frame: %.2f ms   ripple gpu: %.3f ms" % [
			fps,
			frame_ms,
			float(stats.get("gpu_ms", -1.0)),
		],
		"E: grab/drop red ball   Hold right mouse: look/fly   Scroll: fly speed",
		"Debug colors: red = upward height, blue = downward height, green = slope",
		"dispatches: %d   last impulses: %d   pending: %d" % [
			int(stats.get("dispatch_count", 0)),
			int(stats.get("last_impulse_count", 0)),
			int(stats.get("pending_impulse_count", 0)),
		],
		"gpu: %.3f ms   cpu prep: %d us   splats: %d   active: %s" % [
			float(stats.get("gpu_ms", -1.0)),
			int(stats.get("cpu_prepare_us", stats.get("cpu_upload_us", 0))),
			int(stats.get("splat_dispatch_count", 0)),
			str(stats.get("active_dispatch", false)),
		],
		"culled: %d   dropped: %d   scroll: %s" % [
			int(stats.get("culled_impulses_total", 0)),
			int(stats.get("dropped_impulses_total", 0)),
			str(stats.get("atlas_scroll_px", Vector2i.ZERO)),
		],
		"atlas: %d px   enabled: %s   debug: %s" % [
			int(stats.get("atlas_size", 0)),
			str(stats.get("enabled", false)),
			str(stats.get("debug_enabled", false)),
		],
		"body atlas rebuilds: %d   last: %d us   syncs: %d" % [
			int(body_stats.get("atlas_rebuild_count", 0)),
			int(body_stats.get("atlas_rebuild_last_usec", 0)),
			int(stats.get("renderer_sync_count", 0)),
		],
		"registered bodies: %d" % [
			int((body_stats.get("registry", {}) as Dictionary).get("body_count", 0)),
		],
	])


func _toggle_ball_grab() -> void:
	if _held_ball != null:
		_release_ball()
		return
	if _play_ball == null or _camera == null:
		return
	var to_ball := _play_ball.global_position - _camera.global_position
	var forward := -_camera.global_transform.basis.z.normalized()
	if to_ball.length() > GRAB_RANGE_M:
		return
	if forward.dot(to_ball.normalized()) < 0.65:
		return
	_held_ball = _play_ball
	_held_ball.sleeping = false
	if _grab_marker != null:
		_grab_marker.visible = true


func _release_ball() -> void:
	if _held_ball == null:
		return
	_held_ball = null
	if _grab_marker != null:
		_grab_marker.visible = false


func _update_held_ball() -> void:
	if _held_ball == null or _camera == null:
		return
	var target := _grab_target()
	var delta := target - _held_ball.global_position
	var desired_velocity := delta * GRAB_PULL
	if desired_velocity.length() > GRAB_MAX_SPEED:
		desired_velocity = desired_velocity.normalized() * GRAB_MAX_SPEED
	_held_ball.linear_velocity = desired_velocity
	_held_ball.angular_velocity *= 0.92


func _emit_ball_interactions(delta: float) -> void:
	if _play_ball_interactor == null or WaterSystem == null:
		return
	var state := WaterSystem.get_water_surface_state()
	for impulse: Dictionary in _play_ball_interactor.gather_impulses(delta, state):
		WaterSystem.emit_water_impulse(
			impulse["position"],
			float(impulse["radius_m"]),
			float(impulse["strength"]),
			impulse["kind"],
			impulse["body_id"],
			impulse.get("wake_direction", Vector2.ZERO),
			float(impulse.get("wake_length_m", 0.0))
		)


func _update_water_interaction_manual(delta: float) -> void:
	if WaterSystem == null:
		return
	var sim := WaterSystem.get("_water_interaction_sim") as WaterInteractionSim
	if sim == null:
		return
	var center := _camera.global_position if _camera != null else Vector3.ZERO
	sim.update_sim(delta, center)
	var texture := sim.get_texture()
	var bounds := sim.get_bounds()
	var active := bool(sim.get_stats().get("enabled", false)) and texture != null
	for volume: WaterVolume in _water_volumes:
		if is_instance_valid(volume):
			volume.sync_water_interaction_texture(texture, bounds, active, _debug_enabled)


func _update_grab_marker() -> void:
	if _grab_marker == null or _held_ball == null:
		return
	_grab_marker.global_position = _grab_target()


func _grab_target() -> Vector3:
	if _camera == null:
		return Vector3.ZERO
	return _camera.global_position - _camera.global_transform.basis.z.normalized() * GRAB_DISTANCE_M


func _log_perf_periodically(delta: float) -> void:
	_perf_log_elapsed += delta
	if _perf_log_elapsed < 3.0 or WaterSystem == null:
		return
	_perf_log_elapsed = 0.0
	var stats: Dictionary = WaterSystem.get_water_interaction_stats()
	var body_stats: Dictionary = WaterSystem.get_water_body_runtime_status() if WaterSystem.has_method("get_water_body_runtime_status") else {}
	var fps := int(Engine.get_frames_per_second())
	var frame_ms := _average_frame_ms()
	var registry_stats := body_stats.get("registry", {}) as Dictionary
	Log.info("water", "[WaterInteractionRipples] fps=%d avg_frame=%.2fms ripple_gpu=%.3fms cpu=%dus impulses=%d splats=%d body_rebuilds=%d body_last_us=%d syncs=%d bodies=%d" % [
		fps,
		frame_ms,
		float(stats.get("gpu_ms", -1.0)),
		int(stats.get("cpu_prepare_us", stats.get("cpu_upload_us", 0))),
		int(stats.get("last_impulse_count", 0)),
		int(stats.get("splat_dispatch_count", 0)),
		int(body_stats.get("atlas_rebuild_count", 0)),
		int(body_stats.get("atlas_rebuild_last_usec", 0)),
		int(stats.get("renderer_sync_count", 0)),
		int(registry_stats.get("body_count", 0)),
	])
	_perf_frame_ms_accum = 0.0
	_perf_frame_count = 0


func _average_frame_ms() -> float:
	if _perf_frame_count <= 0:
		return 1000.0 / maxf(float(Engine.get_frames_per_second()), 1.0)
	return _perf_frame_ms_accum / float(_perf_frame_count)


func _run_smoke() -> void:
	for _warmup in range(5):
		await get_tree().process_frame

	for count in [0, 4, 32, 128]:
		_emit_debug_impulse_burst(count)
		_step_smoke_sim()
		await get_tree().process_frame

	var best_gpu_ms := INF
	var best_cpu_us := 2147483647
	var saw_splats := false
	var max_splats := 0
	for _i in range(30):
		await get_tree().process_frame
		_step_smoke_sim()
		var stats: Dictionary = WaterSystem.get_water_interaction_stats()
		var gpu_ms := float(stats.get("gpu_ms", -1.0))
		if gpu_ms >= 0.0 and gpu_ms < 50.0:
			best_gpu_ms = minf(best_gpu_ms, gpu_ms)
		best_cpu_us = mini(best_cpu_us, int(stats.get("cpu_prepare_us", stats.get("cpu_upload_us", 0))))
		max_splats = maxi(max_splats, int(stats.get("splat_dispatch_count", 0)))
		saw_splats = saw_splats or max_splats > 0
	var stats: Dictionary = WaterSystem.get_water_interaction_stats()
	if int(stats.get("dispatch_count", 0)) > 0 and best_gpu_ms < INF:
		if best_gpu_ms > SMOKE_GPU_MS_LIMIT:
			push_error("[WaterInteractionRipples] ripple simulation exceeded smoke GPU budget: %.3f ms > %.3f ms" % [
				best_gpu_ms,
				SMOKE_GPU_MS_LIMIT,
			])
			get_tree().quit(1)
			return
		Log.info("water", "[WaterInteractionRipples] smoke dispatches=%d last_impulses=%d best_gpu=%.3fms best_cpu=%dus max_splats=%d" % [
			int(stats.get("dispatch_count", 0)),
			int(stats.get("last_impulse_count", 0)),
			best_gpu_ms,
			best_cpu_us,
			max_splats
		])
		get_tree().quit(0)
		return

	push_error("[WaterInteractionRipples] ripple simulation did not dispatch; stats=%s" % str(WaterSystem.get_water_interaction_stats() if WaterSystem != null else {}))
	get_tree().quit(1)


func _step_smoke_sim() -> void:
	if WaterSystem == null:
		return
	var sim := WaterSystem.get("_water_interaction_sim") as WaterInteractionSim
	if sim == null:
		return
	var center := _camera.global_position if _camera != null else Vector3.ZERO
	sim.update_sim(1.0 / 30.0, center)
