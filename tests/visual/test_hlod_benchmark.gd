## HLOD A/B Benchmark Test Scene
##
## Boots the full streaming pipeline on a 5×5 cell grid around Seyda Neen.
## No player, no dialogue, no weather — just LOD/HLOD/impostor tiers.
##
## Controls (InputMap actions):
##   WASD / move_* actions — fly camera
##   Mouse — look
##   Scroll — speed
##   hlod_toggle - toggle HLOD on/off (A/B comparison)
##   hlod_benchmark_toggle - start/stop benchmark logging (CSV output)
##   hlod_dump_stats - dump stats to console
##   hlod_teleport_tier - teleport to tier boundary distances
##   ui_cancel - release mouse / quit
##
## Output: benchmark CSV + per-frame RS instance counts in user://benchmark_results/
##
## Launch:
##   "D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" res://tests/visual/test_hlod_benchmark.tscn

extends Node3D

const DU := preload("res://src/core/world/distance_utils.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const NativeStreamingManagerScript := preload("res://src/core/world/native_streaming_manager.gd")
const StaticObjectRendererScript := preload("res://src/core/world/static_object_renderer.gd")

const ACTION_HLOD_TOGGLE := &"hlod_toggle"
const ACTION_HLOD_BENCHMARK_TOGGLE := &"hlod_benchmark_toggle"
const ACTION_HLOD_DUMP_STATS := &"hlod_dump_stats"
const ACTION_HLOD_TELEPORT_TIER := &"hlod_teleport_tier"

## Seyda Neen grid center (cell -2, -9 in ESM coords)
const START_CELL := Vector2i(-2, -9)

## Camera starts above Seyda Neen looking north
const START_POS := Vector3(-2 * 117.0 + 58.5, 40.0, 9 * 117.0 + 58.5)

## Tier boundary teleport positions (relative to start, looking at the cell center from each distance)
const TIER_DISTANCES: Array[float] = [150.0, 300.0, 600.0, 1000.0]
const TIER_LABELS: Array[String] = ["NEAR/MID boundary (150m)", "MID/HLOD boundary (300m)", "HLOD tier-1/2 boundary (600m)", "HLOD/FAR boundary (1000m)"]

var _streaming_manager: Node3D
var _cell_manager: CellManager
var _camera: Camera3D
var _hud_label: RichTextLabel

## Free-cam state
var _cam_speed: float = 30.0
var _mouse_captured: bool = true
var _mouse_sensitivity: float = 0.002

## HLOD state
var _hlod_enabled: bool = false

## Benchmark state
var _benchmarking: bool = false
var _bench_frames: Array[Dictionary] = []
var _bench_start_time: float = 0.0

## Tier teleport index
var _tier_idx: int = 0

## Startup tracking
var _startup_done: bool = false
var _startup_timer: float = 0.0

## Stats polling interval
var _stats_timer: float = 0.0
const STATS_INTERVAL: float = 1.0


func _ready() -> void:
	InputActions.verify()
	_verify_test_actions()
	_setup_environment()
	_setup_camera()
	_setup_hud()
	_hud_label.text = "[b]Loading ESM data...[/b]"
	# Defer streaming setup to next frame so UI renders the loading message
	_load_game_data.call_deferred()


func _load_game_data() -> void:
	# Check if ESM already loaded (e.g. from autoload or prior scene)
	if ESMManager.cells.size() > 0:
		Log.info("hlod_bench", "ESM already loaded: %d cells" % ESMManager.cells.size())
	else:
		# Load ESM file (required for cell data)
		var esm_file: String = SettingsManager.get_esm_file()
		var data_path: String = SettingsManager.get_data_path()
		var esm_path: String = data_path.path_join(esm_file)
		Log.info("hlod_bench", "Loading ESM: %s" % esm_path)
		_hud_label.text = "[b]Loading ESM data... (this takes ~7 seconds)[/b]"
		# Yield a frame so the HUD message renders before the blocking load
		await get_tree().process_frame
		var error: Error = ESMManager.load_file(esm_path)
		if error != OK:
			Log.error("hlod_bench", "Failed to load ESM: %s" % error_string(error))
			_hud_label.text = "[color=red]ERROR: Failed to load ESM: %s[/color]" % error_string(error)
			return
		Log.info("hlod_bench", "ESM loaded: %d cells, %d statics" % [ESMManager.cells.size(), ESMManager.statics.size()])

	# Wait a frame to let the renderer stabilize after ESM load
	_hud_label.text = "[b]Starting streaming...[/b]"
	await get_tree().process_frame

	_setup_streaming()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	Log.info("hlod_bench", "HLOD Benchmark ready. F1=HLOD toggle, F2=benchmark, F3=stats, F4=teleport")


func _exit_tree() -> void:
	if _benchmarking:
		_stop_benchmark()


func _setup_environment() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	light.shadow_enabled = true
	light.light_energy = 1.2
	add_child(light)

	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.38, 0.45, 0.55)
	sky_mat.sky_horizon_color = Color(0.64, 0.68, 0.74)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world_env.environment = env
	add_child(world_env)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.position = START_POS
	_camera.rotation_degrees = Vector3(-15, 0, 0)
	_camera.far = 6000.0
	_camera.near = 0.1
	add_child(_camera)
	_camera.make_current()


func _setup_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "HUD"
	add_child(canvas)

	_hud_label = RichTextLabel.new()
	_hud_label.bbcode_enabled = true
	_hud_label.fit_content = true
	_hud_label.scroll_active = false
	_hud_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_label.position = Vector2(10, 10)
	_hud_label.size = Vector2(600, 400)
	_hud_label.add_theme_font_size_override("normal_font_size", 14)
	canvas.add_child(_hud_label)


func _setup_streaming() -> void:
	# Create CellManager
	_cell_manager = CellManager.new()
	_cell_manager.load_npcs = false
	_cell_manager.load_creatures = false
	_cell_manager.use_static_renderer = true

	# Create NativeStreamingManager
	var nsm := Node3D.new()
	nsm.set_script(NativeStreamingManagerScript)
	nsm.name = "NativeStreamingManager"
	nsm.load_radius_cells = 3
	nsm.debug_enabled = false
	_streaming_manager = nsm
	add_child(_streaming_manager)

	# Connect signals
	_streaming_manager.startup_complete.connect(_on_startup_complete)

	# Initialize
	_streaming_manager.initialize(_cell_manager, _camera)
	Log.info("hlod_bench", "Streaming initialized around cell %s" % START_CELL)


func _verify_test_actions() -> void:
	for action_name: StringName in InputActions.VISUAL_TEST:
		if not InputMap.has_action(action_name):
			Log.error("input", "Missing visual test action: %s" % action_name)
			assert(false, "missing visual test action: %s" % action_name)


func _on_startup_complete() -> void:
	_startup_done = true
	_startup_timer = Time.get_ticks_msec() / 1000.0
	Log.info("hlod_bench", "Startup complete — auto-enabling HLOD in 1 second")
	# Auto-enable HLOD after a brief settle period
	get_tree().create_timer(1.0).timeout.connect(_auto_enable_hlod)


func _auto_enable_hlod() -> void:
	Log.info("hlod_bench", "Auto-enabling HLOD...")
	_toggle_hlod()
	# Start benchmark automatically
	_start_benchmark()
	Log.info("hlod_bench", "HLOD enabled + benchmark recording started. Fly around to capture data.")


@warning_ignore("untyped_declaration")
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		_camera.rotate_y(-event.relative.x * _mouse_sensitivity)
		_camera.rotate_object_local(Vector3.RIGHT, -event.relative.y * _mouse_sensitivity)
		# Clamp pitch
		var rot := _camera.rotation_degrees
		rot.x = clampf(rot.x, -89.0, 89.0)
		_camera.rotation_degrees = rot

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cam_speed = minf(_cam_speed * 1.3, 500.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cam_speed = maxf(_cam_speed / 1.3, 2.0)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			_mouse_captured = true

	if event is InputEventKey and event.pressed and not event.echo:
		if event.is_action_pressed(ACTION_HLOD_TOGGLE):
			_toggle_hlod()
		elif event.is_action_pressed(ACTION_HLOD_BENCHMARK_TOGGLE):
			if _benchmarking:
				_stop_benchmark()
			else:
				_start_benchmark()
		elif event.is_action_pressed(ACTION_HLOD_DUMP_STATS):
			_dump_stats()
		elif event.is_action_pressed(ACTION_HLOD_TELEPORT_TIER):
			_teleport_tier()
		elif event.is_action_pressed("ui_cancel"):
			if _mouse_captured:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				_mouse_captured = false
			else:
				get_tree().quit()


func _process(delta: float) -> void:
	_process_camera_movement(delta)
	_stats_timer += delta

	if _stats_timer >= STATS_INTERVAL:
		_stats_timer = 0.0
		_update_hud()

	if _benchmarking:
		_record_frame()


func _process_camera_movement(delta: float) -> void:
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var velocity := Vector3.ZERO
	velocity += _camera.global_transform.basis.z * input_dir.y
	velocity += _camera.global_transform.basis.x * input_dir.x
	if Input.is_action_pressed("jump"):
		velocity.y += 1.0
	if Input.is_action_pressed("crouch"):
		velocity.y -= 1.0
	if velocity.length() > 0.0:
		_camera.position += velocity.normalized() * _cam_speed * delta


#region HLOD Toggle

@warning_ignore("untyped_declaration", "unsafe_property_access", "unsafe_method_access")
func _toggle_hlod() -> void:
	_hlod_enabled = not _hlod_enabled
	if not _streaming_manager:
		return

	if _hlod_enabled:
		_streaming_manager.set_hlod_visible(true)
		# Log merger state for debugging
		Log.info("hlod_bench", "HLOD ENABLED")
		var merger_stats: Dictionary = _streaming_manager.get_hlod_stats() if _streaming_manager.has_method("get_hlod_stats") else {}
		Log.info("hlod_bench", "  HLOD stats: %s" % str(merger_stats))
		Log.info("hlod_bench", "  MID fixed 0-400m, HLOD visible 400-1000m, FAR impostors 400m+")
	else:
		_streaming_manager.set_hlod_visible(false)
		Log.info("hlod_bench", "HLOD DISABLED - MID fixed 0-400m, FAR impostors 400m+")

#endregion


#region Benchmark

func _start_benchmark() -> void:
	_benchmarking = true
	_bench_frames.clear()
	_bench_start_time = Time.get_ticks_msec() / 1000.0
	Log.info("hlod_bench", "Benchmark STARTED (HLOD=%s)" % ("ON" if _hlod_enabled else "OFF"))


func _stop_benchmark() -> void:
	_benchmarking = false
	var duration := Time.get_ticks_msec() / 1000.0 - _bench_start_time
	Log.info("hlod_bench", "Benchmark STOPPED after %.1fs (%d frames)" % [duration, _bench_frames.size()])
	_save_benchmark()


@warning_ignore("untyped_declaration")
func _record_frame() -> void:
	var p := Performance
	var stats: Dictionary = _get_streaming_stats()
	_bench_frames.append({
		"frame": Engine.get_frames_drawn(),
		"time_ms": Time.get_ticks_msec(),
		"fps": p.get_monitor(p.TIME_FPS),
		"frame_ms": p.get_monitor(p.TIME_PROCESS) * 1000.0,
		"draw_calls": int(p.get_monitor(p.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"objects": int(p.get_monitor(p.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"primitives": int(p.get_monitor(p.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"mid_instances": int(stats.get("mid_instances", 0)),
		"hlod_cells": int(stats.get("hlod_cells", 0)),
		"hlod_pending": int(stats.get("hlod_pending", 0)),
		"loaded_cells": int(stats.get("loaded_cells", 0)),
		"impostors": int(stats.get("impostors", 0)),
		"hlod_enabled": _hlod_enabled,
		"cam_x": _camera.position.x,
		"cam_y": _camera.position.y,
		"cam_z": _camera.position.z,
		"vram_mb": p.get_monitor(p.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0),
	})


func _save_benchmark() -> void:
	var dir_path := "user://benchmark_results"
	DirAccess.make_dir_recursive_absolute(dir_path)
	var hlod_tag := "hlod_on" if _hlod_enabled else "hlod_off"
	var ts := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var filename := "%s/hlod_bench_%s_%s.csv" % [dir_path, hlod_tag, ts]

	var file := FileAccess.open(filename, FileAccess.WRITE)
	if not file:
		Log.error("hlod_bench", "Failed to open %s for writing" % filename)
		return

	# Header
	file.store_line("frame,time_ms,fps,frame_ms,draw_calls,objects,primitives,mid_instances,hlod_cells,hlod_pending,loaded_cells,impostors,hlod_enabled,cam_x,cam_y,cam_z,vram_mb")

	for f: Dictionary in _bench_frames:
		file.store_line("%d,%d,%.1f,%.2f,%d,%d,%d,%d,%d,%d,%d,%d,%s,%.1f,%.1f,%.1f,%.1f" % [
			f["frame"], f["time_ms"], f["fps"], f["frame_ms"],
			f["draw_calls"], f["objects"], f["primitives"],
			f["mid_instances"], f["hlod_cells"], f["hlod_pending"],
			f["loaded_cells"], f["impostors"], str(f["hlod_enabled"]),
			f["cam_x"], f["cam_y"], f["cam_z"], f["vram_mb"],
		])

	file.close()

	# Summary
	if _bench_frames.is_empty():
		Log.warn("hlod_bench", "No frames recorded")
		return

	var fps_sum := 0.0
	var min_fps := 9999.0
	var max_draw := 0
	var max_mid := 0
	for f: Dictionary in _bench_frames:
		fps_sum += float(f["fps"])
		min_fps = minf(min_fps, float(f["fps"]))
		max_draw = maxi(max_draw, int(f["draw_calls"]))
		max_mid = maxi(max_mid, int(f["mid_instances"]))

	var avg_fps := fps_sum / _bench_frames.size()
	Log.info("hlod_bench", "=== BENCHMARK SUMMARY (HLOD=%s) ===" % ("ON" if _hlod_enabled else "OFF"))
	Log.info("hlod_bench", "  Frames: %d" % _bench_frames.size())
	Log.info("hlod_bench", "  Avg FPS: %.1f" % avg_fps)
	Log.info("hlod_bench", "  Min FPS: %.1f" % min_fps)
	Log.info("hlod_bench", "  Max draw calls: %d" % max_draw)
	Log.info("hlod_bench", "  Max MID instances: %d" % max_mid)
	Log.info("hlod_bench", "  Saved to: %s" % filename)

#endregion


#region Stats & HUD

@warning_ignore("unsafe_method_access")
func _get_streaming_stats() -> Dictionary:
	if not _streaming_manager:
		return {}
	if _streaming_manager.has_method("get_stats"):
		var result: Dictionary = _streaming_manager.call("get_stats")
		return result
	return {}


@warning_ignore("untyped_declaration")
func _dump_stats() -> void:
	var stats: Dictionary = _get_streaming_stats()
	Log.info("hlod_bench", "=== STREAMING STATS ===")
	for key: String in stats:
		Log.info("hlod_bench", "  %s: %s" % [key, str(stats[key])])


func _update_hud() -> void:
	if not _hud_label:
		return

	var p := Performance
	var stats := _get_streaming_stats()
	var fps := p.get_monitor(p.TIME_FPS)
	var frame_ms := p.get_monitor(p.TIME_PROCESS) * 1000.0
	var draws := int(p.get_monitor(p.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var objects := int(p.get_monitor(p.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var prims := int(p.get_monitor(p.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var mid: int = int(stats.get("mid_instances", 0))
	var hlod_active: int = int(stats.get("hlod_cells", 0))
	var hlod_pending: int = int(stats.get("hlod_pending", 0))
	var loaded: int = int(stats.get("loaded_cells", 0))
	var impostors: int = int(stats.get("impostors", 0))
	var vram := p.get_monitor(p.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0)

	var hlod_color := "green" if _hlod_enabled else "red"
	var hlod_text := "ON" if _hlod_enabled else "OFF"
	var bench_text := "[color=yellow]RECORDING[/color]" if _benchmarking else "idle"
	var startup_text := "[color=green]done[/color]" if _startup_done else "[color=yellow]loading...[/color]"

	var cam_cell := DU.world_to_cell(_camera.position)

	_hud_label.text = """[b]HLOD A/B Benchmark[/b]
[b]HLOD:[/b] [color=%s]%s[/color]  |  Bench: %s  |  Startup: %s

[b]Performance[/b]
  FPS: %.0f  |  Frame: %.1fms  |  Draws: %d  |  Objects: %d  |  Prims: %dk
  VRAM: %.0f MB

[b]Streaming[/b]
  Cells loaded: %d  |  Camera cell: %s
  MID instances: [b]%d[/b]  |  HLOD active: [b]%d[/b] (pending: %d)
  Impostors: %d

[b]Controls[/b]
  F1: Toggle HLOD  |  F2: Start/Stop benchmark  |  F3: Dump stats
  F4: Teleport to tier boundary  |  WASD: fly  |  Scroll: speed (%.0f m/s)
  Esc: release mouse / quit""" % [
		hlod_color, hlod_text, bench_text, startup_text,
		fps, frame_ms, draws, objects, prims / 1000, vram,
		loaded, cam_cell, mid, hlod_active, hlod_pending, impostors,
		_cam_speed,
	]

#endregion


#region Tier Teleport

func _teleport_tier() -> void:
	var dist: float = TIER_DISTANCES[_tier_idx]
	var label: String = TIER_LABELS[_tier_idx]
	# Position camera at `dist` meters south of start position, looking north
	_camera.position = START_POS + Vector3(0, 20, dist)
	_camera.rotation_degrees = Vector3(-10, 0, 0)
	Log.info("hlod_bench", "Teleported to %s (%.0fm)" % [label, dist])
	_tier_idx = (_tier_idx + 1) % TIER_DISTANCES.size()

#endregion
