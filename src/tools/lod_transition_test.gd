## LodTransitionTest — Automated LOD tier transition verification
##
## Runs a scripted camera path that systematically crosses every distance tier
## boundary (FAR↔MID↔NEAR) and logs per-frame metrics + events so that future
## agents can diagnose transition correctness from the output alone.
##
## Two modes:
##   1. Standalone: Open lod_transition_test.tscn directly (self-initializes)
##   2. Console command: Called from world_explorer via `test_lod_transitions`
##
## Outputs CSV + events CSV to user://lod_test_results/ and prints summary.
@warning_ignore("untyped_declaration", "unsafe_method_access")
class_name LodTransitionTest
extends Node3D

const DU := preload("res://src/core/world/distance_utils.gd")
const TU := preload("res://src/core/world/tier_utils.gd")
const LODCfg := preload("res://src/core/world/lod_configurator.gd")
const NativeStreamingManagerScript := preload("res://src/core/world/native_streaming_manager.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")


#region Signals
signal test_complete(results: Dictionary)
#endregion


#region Constants

const SPAWN_CELL := Vector2i(-2, -9)
const CAMERA_HEIGHT := 50.0

const PHASE_NAMES: Array[String] = [
	"INIT", "FAR_APPROACH", "FAR_TO_MID", "MID_TRAVERSE",
	"MID_TO_NEAR", "NEAR_HOLD", "RETREAT_NEAR_MID",
	"RETREAT_MID_FAR", "ORBIT_FAR", "ORBIT_NEAR"
]

## Tier boundary distances for markers and crossing detection
const BOUNDARY_PROMOTION := 130.0
const BOUNDARY_NEAR_MID := DU.NEAR_END        # 150
const BOUNDARY_DEMOTION := 190.0
const BOUNDARY_LOD1_LOD2 := LODCfg.LOD1_END   # 250
const BOUNDARY_LOD2_LOD3 := LODCfg.LOD2_END   # 375
const BOUNDARY_MID_FAR := DU.MID_END          # 500

const SUB_LOD_BOUNDARIES: Array[float] = [250.0, 375.0]

const CSV_HEADERS := "frame,time_ms,fps,phase,phase_name,cam_distance,cam_tier,cam_x,cam_y,cam_z,node_count,draw_calls,rendered_objects,primitives,loaded_cells,queue_size,mid_instances,mid_visible,mid_mesh_types,far_impostors,promotions_total,demotions_total,memory_static"

const MAX_DISPLAY_EVENTS := 12
const MAX_EVENT_LOG := 500

const FLICKER_WINDOW_FRAMES := 30
const FLICKER_THRESHOLD := 3

#endregion


#region Inner Classes

class Waypoint:
	var position: Vector3
	var look_at: Vector3
	var duration: float
	var is_teleport: bool
	var phase_index: int

	func _init(p_pos: Vector3, p_look: Vector3, p_dur: float, p_phase: int, p_teleport: bool = false) -> void:
		position = p_pos
		look_at = p_look
		duration = p_dur
		phase_index = p_phase
		is_teleport = p_teleport

#endregion


#region State

var _camera: Camera3D = null
var _streaming_manager = null
var _cell_manager = null
var _console: Node = null

var _owns_streaming: bool = false
var _target_center: Vector3 = Vector3.ZERO

## Waypoint navigation
var _waypoints: Array[Waypoint] = []
var _current_waypoint_index: int = 0
var _waypoint_elapsed: float = 0.0
var _waypoint_start_pos: Vector3 = Vector3.ZERO
var _phase_starts: PackedInt32Array = PackedInt32Array()
var _current_phase: int = 0

## Running state
var _running: bool = false
var _finished: bool = false
var _last_frame_time_ms: float = 0.0

## Distance & tier tracking
var _current_distance: float = 0.0
var _current_tier: int = TU.Tier.HIDDEN
var _prev_distance: float = 0.0
var _prev_tier: int = TU.Tier.HIDDEN

## Delta tracking for event detection
var _prev_promotions: int = 0
var _prev_demotions: int = 0
var _prev_rendered_objects: int = -1
var _prev_mid_instances: int = 0
var _prev_far_impostors: int = 0

## Tier transition frame log (for flicker detection)
var _tier_change_frames: Array[int] = []

## Event log
var _event_log: Array[Dictionary] = []

## Boundary crossing records
var _boundary_crossings: Array[Dictionary] = []

## Anomaly records
var _anomalies: Array[Dictionary] = []

## Per-phase peak tracking
var _phase_peaks: Dictionary = {}  # phase_index -> {near, mid, far, frame_time}

## Frame log for CSV
var _frame_log: Array[PackedFloat64Array] = []

## HUD labels
var _distance_label: Label = null
var _tier_label: Label = null
var _phase_label: Label = null
var _near_label: Label = null
var _mid_label: Label = null
var _far_label: Label = null
var _fps_label: Label = null
var _detail_label: Label = null
var _promo_label: Label = null
var _event_log_label: RichTextLabel = null
var _progress_bar: ProgressBar = null

#endregion


#region Initialization

func _ready() -> void:
	if not _streaming_manager:
		_init_standalone()


func _init_standalone() -> void:
	Log.info("testing", "LodTransitionTest: Standalone mode — initializing systems")
	_owns_streaming = true

	_target_center = DU.cell_to_world_center(SPAWN_CELL, 0.0)
	Log.info("testing", "LodTransitionTest: Target center = %s (cell %s)" % [_target_center, SPAWN_CELL])

	_setup_environment()
	_setup_camera()
	_setup_hud()

	# Load data
	var data_path: String = SettingsManager.get_data_path()
	if data_path.is_empty():
		data_path = SettingsManager.auto_detect_installation()
	if data_path.is_empty():
		Log.error("testing", "LodTransitionTest: No Morrowind data path found")
		return

	if BSAManager.get_archive_count() == 0:
		BSAManager.load_archives_from_directory(data_path)

	if ESMManager.cells.is_empty():
		var esm_file: String = SettingsManager.get_esm_file()
		var esm_path := data_path.path_join(esm_file)
		var err := ESMManager.load_file(esm_path)
		if err != OK:
			Log.error("testing", "LodTransitionTest: Failed to load ESM: %s" % error_string(err))
			return

	# Create cell manager
	_cell_manager = CellManagerScript.new()
	_cell_manager.load_npcs = false
	_cell_manager.load_creatures = false
	var pool_container := Node3D.new()
	pool_container.name = "PoolContainer"
	pool_container.visible = false
	add_child(pool_container)
	_cell_manager.init_object_pool(pool_container)
	_cell_manager.preload_common_models()

	# Create streaming manager with larger radius to cover MID/FAR boundary
	var nsm := Node3D.new()
	nsm.set_script(NativeStreamingManagerScript)
	nsm.name = "NativeStreamingManager"
	nsm.load_radius_cells = 5  # 5 * 117m = 585m — covers 500m MID/FAR boundary
	nsm.debug_enabled = true
	add_child(nsm)
	_streaming_manager = nsm
	_streaming_manager.initialize(_cell_manager, null)

	_create_boundary_markers()
	_build_waypoints()

	# Enable debug logging for streaming during test
	Log.set_category_level("streaming", Log.Level.DEBUG)

	_start_test()


func init_console_mode(
	streaming_manager,
	cell_manager,
	camera: Camera3D,
	console: Node = null
) -> void:
	_streaming_manager = streaming_manager
	_cell_manager = cell_manager
	_camera = camera
	_console = console
	_owns_streaming = false

	_target_center = DU.cell_to_world_center(SPAWN_CELL, 0.0)
	Log.info("testing", "LodTransitionTest: Console mode — target center = %s" % _target_center)

	_setup_hud()
	_create_boundary_markers()
	_build_waypoints()
	_start_test()

#endregion


#region Environment & Camera Setup

func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.4, 0.5, 0.7)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.7)
	env.ambient_light_energy = 0.5

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0)
	sun.shadow_enabled = true
	sun.light_energy = 1.0
	add_child(sun)


func _setup_camera() -> void:
	var rig := Node3D.new()
	rig.name = "CameraRig"
	add_child(rig)

	_camera = Camera3D.new()
	_camera.fov = 75.0
	_camera.far = 6000.0
	rig.add_child(_camera)
	_camera.current = true

#endregion


#region HUD Setup

func _setup_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "TestHUD"
	add_child(canvas)

	# Left panel — stats
	var left_panel := PanelContainer.new()
	left_panel.add_theme_stylebox_override("panel", _create_panel_style())
	left_panel.position = Vector2(10, 10)
	left_panel.custom_minimum_size = Vector2(320, 0)
	canvas.add_child(left_panel)

	var vbox := VBoxContainer.new()
	left_panel.add_child(vbox)

	var title := Label.new()
	title.text = "LOD TRANSITION TEST"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	vbox.add_child(HSeparator.new())

	_distance_label = _add_stat_label(vbox, "Distance: --")
	_tier_label = _add_stat_label(vbox, "Tier: --")
	_phase_label = _add_stat_label(vbox, "Phase: --")

	vbox.add_child(HSeparator.new())

	_near_label = _add_stat_label(vbox, "NEAR: --")
	_mid_label = _add_stat_label(vbox, "MID: --")
	_far_label = _add_stat_label(vbox, "FAR: --")

	vbox.add_child(HSeparator.new())

	_fps_label = _add_stat_label(vbox, "FPS: -- | Frame: --ms")
	_detail_label = _add_stat_label(vbox, "Draw: -- | Nodes: -- | Cells: --")
	_promo_label = _add_stat_label(vbox, "Promotions: 0 | Demotions: 0")

	# Right panel — event log
	var right_panel := PanelContainer.new()
	right_panel.add_theme_stylebox_override("panel", _create_panel_style())
	right_panel.anchor_left = 1.0
	right_panel.anchor_right = 1.0
	right_panel.offset_left = -420
	right_panel.offset_right = -10
	right_panel.offset_top = 10
	right_panel.custom_minimum_size = Vector2(400, 300)
	canvas.add_child(right_panel)

	var right_vbox := VBoxContainer.new()
	right_panel.add_child(right_vbox)

	var event_title := Label.new()
	event_title.text = "EVENTS"
	event_title.add_theme_font_size_override("font_size", 16)
	right_vbox.add_child(event_title)

	_event_log_label = RichTextLabel.new()
	_event_log_label.bbcode_enabled = true
	_event_log_label.scroll_following = true
	_event_log_label.custom_minimum_size = Vector2(380, 260)
	_event_log_label.add_theme_font_size_override("normal_font_size", 12)
	right_vbox.add_child(_event_log_label)

	# Bottom — progress bar
	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 100.0
	_progress_bar.custom_minimum_size = Vector2(0, 24)
	_progress_bar.anchor_top = 1.0
	_progress_bar.anchor_bottom = 1.0
	_progress_bar.anchor_left = 0.0
	_progress_bar.anchor_right = 1.0
	_progress_bar.offset_top = -34
	_progress_bar.offset_bottom = -10
	_progress_bar.offset_left = 10
	_progress_bar.offset_right = -10
	canvas.add_child(_progress_bar)


func _add_stat_label(parent: Control, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 14)
	parent.add_child(label)
	return label


func _create_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.75)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	return style

#endregion


#region Boundary Markers

func _create_boundary_markers() -> void:
	_create_ring(BOUNDARY_PROMOTION, Color.GREEN, "Promotion_130m")
	_create_ring(BOUNDARY_NEAR_MID, Color.YELLOW, "NearMid_150m")
	_create_ring(BOUNDARY_DEMOTION, Color.CYAN, "Demotion_190m")
	_create_ring(BOUNDARY_LOD1_LOD2, Color.ORANGE, "LOD1_LOD2_250m")
	_create_ring(BOUNDARY_LOD2_LOD3, Color.ORANGE, "LOD2_LOD3_375m")
	_create_ring(BOUNDARY_MID_FAR, Color.RED, "MidFar_500m")

	# Origin pole at target center
	_create_origin_pole()

	Log.info("testing", "LodTransitionTest: Created 6 boundary markers + origin pole at %s" % _target_center)


func _create_ring(radius: float, color: Color, label: String) -> void:
	var mesh := ImmediateMesh.new()
	var segments := 64

	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(segments + 1):
		var angle := float(i) * TAU / float(segments)
		var pos := Vector3(
			_target_center.x + cos(angle) * radius,
			_target_center.y + 2.0,
			_target_center.z + sin(angle) * radius
		)
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(pos)
	mesh.surface_end()

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = "Boundary_%s" % label

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.vertex_color_use_as_albedo = true
	mi.material_override = mat

	add_child(mi)


func _create_origin_pole() -> void:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_set_color(Color.WHITE)
	mesh.surface_add_vertex(_target_center + Vector3(0, 0, 0))
	mesh.surface_set_color(Color.WHITE)
	mesh.surface_add_vertex(_target_center + Vector3(0, 100, 0))
	mesh.surface_end()

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = "OriginPole"

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.vertex_color_use_as_albedo = true
	mi.material_override = mat

	add_child(mi)

#endregion


#region Waypoint Construction

func _build_waypoints() -> void:
	_waypoints.clear()
	_phase_starts.clear()

	var center := _target_center + Vector3(0, CAMERA_HEIGHT, 0)

	# Phase 0: INIT — static at 800m, let streaming stabilize
	_phase_starts.append(_waypoints.size())
	var init_pos := _pos_at_distance(800.0)
	_waypoints.append(Waypoint.new(init_pos, _target_center, 5.0, 0))

	# Phase 1: FAR_APPROACH — 800m → 520m
	_phase_starts.append(_waypoints.size())
	_waypoints.append(Waypoint.new(_pos_at_distance(520.0), _target_center, 8.0, 1))

	# Phase 2: FAR_TO_MID — 520m → 480m (slow crossing of 500m boundary)
	_phase_starts.append(_waypoints.size())
	_waypoints.append(Waypoint.new(_pos_at_distance(480.0), _target_center, 6.0, 2))

	# Phase 3: MID_TRAVERSE — 480m → 170m (crosses 375m and 250m sub-LOD boundaries)
	_phase_starts.append(_waypoints.size())
	_waypoints.append(Waypoint.new(_pos_at_distance(170.0), _target_center, 10.0, 3))

	# Phase 4: MID_TO_NEAR — 170m → 100m (crosses 150m, triggers promotions at ~130m)
	_phase_starts.append(_waypoints.size())
	_waypoints.append(Waypoint.new(_pos_at_distance(100.0), _target_center, 6.0, 4))

	# Phase 5: NEAR_HOLD — static at 100m
	_phase_starts.append(_waypoints.size())
	_waypoints.append(Waypoint.new(_pos_at_distance(100.0), _target_center, 5.0, 5))

	# Phase 6: RETREAT_NEAR_MID — 100m → 210m (should cross hysteresis demotion at ~190m)
	_phase_starts.append(_waypoints.size())
	_waypoints.append(Waypoint.new(_pos_at_distance(210.0), _target_center, 8.0, 6))

	# Phase 7: RETREAT_MID_FAR — 210m → 550m (crosses 500m outward)
	_phase_starts.append(_waypoints.size())
	_waypoints.append(Waypoint.new(_pos_at_distance(550.0), _target_center, 8.0, 7))

	# Phase 8: ORBIT_FAR — orbit at 500m (8 points)
	_phase_starts.append(_waypoints.size())
	var orbit_segments := 8
	for i in range(orbit_segments + 1):
		var angle := float(i) * TAU / float(orbit_segments)
		var orbit_pos := _orbit_pos(500.0, angle)
		_waypoints.append(Waypoint.new(orbit_pos, _target_center, 10.0 / float(orbit_segments), 8))

	# Phase 9: ORBIT_NEAR — orbit at 150m (8 points)
	_phase_starts.append(_waypoints.size())
	# Teleport to 150m first
	_waypoints.append(Waypoint.new(_pos_at_distance(150.0), _target_center, 0.0, 9, true))
	for i in range(orbit_segments + 1):
		var angle := float(i) * TAU / float(orbit_segments)
		var orbit_pos := _orbit_pos(150.0, angle)
		_waypoints.append(Waypoint.new(orbit_pos, _target_center, 10.0 / float(orbit_segments), 9))

	Log.info("testing", "LodTransitionTest: Built %d waypoints across %d phases" % [
		_waypoints.size(), PHASE_NAMES.size()])


## Camera position at a given horizontal distance from target (along +Z axis)
func _pos_at_distance(horizontal_dist: float) -> Vector3:
	return Vector3(
		_target_center.x,
		_target_center.y + CAMERA_HEIGHT,
		_target_center.z + horizontal_dist
	)


## Camera position on an orbit circle at a given distance and angle
func _orbit_pos(radius: float, angle: float) -> Vector3:
	return Vector3(
		_target_center.x + cos(angle) * radius,
		_target_center.y + CAMERA_HEIGHT,
		_target_center.z + sin(angle) * radius
	)

#endregion


#region Test Control

func _start_test() -> void:
	if _waypoints.is_empty():
		Log.error("testing", "LodTransitionTest: No waypoints defined")
		return

	_current_waypoint_index = 0
	_current_phase = 0
	_waypoint_elapsed = 0.0
	_frame_log.clear()
	_event_log.clear()
	_boundary_crossings.clear()
	_anomalies.clear()
	_phase_peaks.clear()
	_tier_change_frames.clear()
	_running = true
	_finished = false

	# Initialize phase peaks
	for i in range(PHASE_NAMES.size()):
		_phase_peaks[i] = {"near": 0, "mid": 0, "far": 0, "max_frame_time": 0.0}

	# Position camera at first waypoint
	var wp := _waypoints[0]
	_camera.global_position = wp.position
	_waypoint_start_pos = wp.position
	if wp.look_at.distance_squared_to(_camera.global_position) > 1.0:
		_camera.look_at(wp.look_at)

	# Initialize distance tracking
	_current_distance = _camera.global_position.distance_to(_target_center)
	_prev_distance = _current_distance
	_current_tier = TU.get_tier_for_distance(_current_distance)
	_prev_tier = _current_tier

	# Start streaming if standalone
	if _owns_streaming and _streaming_manager:
		_streaming_manager.set_camera(_camera)

	# Connect streaming signals
	if _streaming_manager:
		if _streaming_manager.has_signal("cell_loading"):
			_streaming_manager.cell_loading.connect(_on_cell_loading)
		if _streaming_manager.has_signal("cell_loaded"):
			_streaming_manager.cell_loaded.connect(_on_cell_loaded)
		if _streaming_manager.has_signal("cell_unloaded"):
			_streaming_manager.cell_unloaded.connect(_on_cell_unloaded)

	Log.info("testing", "LodTransitionTest: Started (%d waypoints, %d phases, initial distance: %.1fm, tier: %s)" % [
		_waypoints.size(), PHASE_NAMES.size(), _current_distance, TU.get_tier_name(_current_tier)])
	_log_event("test_start", "distance=%.1fm tier=%s" % [_current_distance, TU.get_tier_name(_current_tier)])


func _process(delta: float) -> void:
	if not _running or _finished:
		return

	_last_frame_time_ms = delta * 1000.0

	# Update distance and tier
	_current_distance = _camera.global_position.distance_to(_target_center)
	_current_tier = TU.get_tier_for_distance(_current_distance)

	# Detect events (must happen before logging so events are in sync)
	_detect_events()

	# Log frame metrics
	_log_frame()

	# Advance camera
	_advance_camera(delta)

	# Update HUD
	_update_hud()

	# Check completion
	if _current_waypoint_index >= _waypoints.size():
		_finish_test()


func _advance_camera(delta: float) -> void:
	if _current_waypoint_index >= _waypoints.size():
		return

	var wp := _waypoints[_current_waypoint_index]

	# Teleport
	if wp.is_teleport:
		_camera.global_position = wp.position
		if wp.look_at.distance_squared_to(_camera.global_position) > 1.0:
			_camera.look_at(wp.look_at)
		_log_event("teleport", "to %.1fm from target" % _camera.global_position.distance_to(_target_center))
		_advance_to_next_waypoint()
		return

	# Zero duration — instant
	if wp.duration <= 0.0:
		_camera.global_position = wp.position
		if wp.look_at.distance_squared_to(_camera.global_position) > 1.0:
			_camera.look_at(wp.look_at)
		_advance_to_next_waypoint()
		return

	_waypoint_elapsed += delta

	# Smoothstep interpolation
	var t := clampf(_waypoint_elapsed / wp.duration, 0.0, 1.0)
	var smoothed_t := t * t * (3.0 - 2.0 * t)
	_camera.global_position = _waypoint_start_pos.lerp(wp.position, smoothed_t)

	if wp.look_at.distance_squared_to(_camera.global_position) > 1.0:
		_camera.look_at(wp.look_at)

	if _waypoint_elapsed >= wp.duration:
		_camera.global_position = wp.position
		_advance_to_next_waypoint()


func _advance_to_next_waypoint() -> void:
	_waypoint_start_pos = _camera.global_position
	_current_waypoint_index += 1
	_waypoint_elapsed = 0.0
	_update_phase_index()


func _update_phase_index() -> void:
	for i in range(_phase_starts.size() - 1, -1, -1):
		if _current_waypoint_index >= _phase_starts[i]:
			if _current_phase != i:
				Log.info("testing", "LodTransitionTest: Phase %d -> %d (%s)" % [
					_current_phase, i, PHASE_NAMES[i] if i < PHASE_NAMES.size() else "done"])
			_current_phase = i
			return

#endregion


#region Event Detection

func _detect_events() -> void:
	var stats := _get_streaming_stats()

	# --- Tier transition ---
	if _current_tier != _prev_tier:
		var from_name := TU.get_tier_name(_prev_tier)
		var to_name := TU.get_tier_name(_current_tier)
		_log_event("tier_transition", "%s -> %s at %.1fm" % [from_name, to_name, _current_distance])

		var near_count := stats.get("mid_to_near_promotions", 0) as int
		_boundary_crossings.append({
			"frame": Engine.get_frames_drawn(),
			"time_ms": Time.get_ticks_msec(),
			"distance": _current_distance,
			"from_tier": from_name,
			"to_tier": to_name,
			"mid": stats.get("mid_instances", 0),
			"far": stats.get("total_impostors", 0),
			"fps": Engine.get_frames_per_second(),
			"phase": _current_phase,
		})

		_tier_change_frames.append(Engine.get_frames_drawn())
		_prev_tier = _current_tier

	# --- Sub-LOD boundary crossings ---
	for boundary in SUB_LOD_BOUNDARIES:
		var was_above := _prev_distance > boundary
		var is_above := _current_distance > boundary
		if was_above != is_above:
			var direction := "approaching" if not is_above else "retreating"
			_log_event("sub_lod_crossing", "Crossed %.0fm (%s) at %.1fm" % [boundary, direction, _current_distance])

	# --- Promotion/demotion deltas ---
	var current_promotions: int = stats.get("mid_to_near_promotions", 0)
	var current_demotions: int = stats.get("near_to_mid_demotions", 0)
	if current_promotions > _prev_promotions:
		var delta_p := current_promotions - _prev_promotions
		_log_event("promotion", "%d MID->NEAR at %.1fm (total: %d)" % [delta_p, _current_distance, current_promotions])
	if current_demotions > _prev_demotions:
		var delta_d := current_demotions - _prev_demotions
		_log_event("demotion", "%d NEAR->MID at %.1fm (total: %d)" % [delta_d, _current_distance, current_demotions])
	_prev_promotions = current_promotions
	_prev_demotions = current_demotions

	# --- MID instance count changes (significant) ---
	var mid_instances: int = stats.get("mid_instances", 0)
	if abs(mid_instances - _prev_mid_instances) > 20:
		_log_event("mid_change", "%d -> %d (delta %d) at %.1fm" % [
			_prev_mid_instances, mid_instances, mid_instances - _prev_mid_instances, _current_distance])
	_prev_mid_instances = mid_instances

	# --- FAR impostor count changes (significant) ---
	var far_impostors: int = stats.get("total_impostors", 0)
	if abs(far_impostors - _prev_far_impostors) > 50:
		_log_event("impostor_change", "%d -> %d (delta %d) at %.1fm" % [
			_prev_far_impostors, far_impostors, far_impostors - _prev_far_impostors, _current_distance])
	_prev_far_impostors = far_impostors

	# --- Visibility drops (anomaly) ---
	var rendered := int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	if _prev_rendered_objects >= 0:
		var delta_objs := rendered - _prev_rendered_objects
		if delta_objs < -10:
			_log_event("visibility_drop", "rendered %d -> %d (delta %d) at %.1fm" % [
				_prev_rendered_objects, rendered, delta_objs, _current_distance])
			_anomalies.append({
				"type": "visibility_drop",
				"frame": Engine.get_frames_drawn(),
				"distance": _current_distance,
				"phase": _current_phase,
				"detail": "Lost %d rendered objects" % abs(delta_objs),
			})
	_prev_rendered_objects = rendered

	# --- Frame spike during transition (anomaly) ---
	if _last_frame_time_ms > 33.0 and _current_phase > 0:
		_anomalies.append({
			"type": "frame_spike",
			"frame": Engine.get_frames_drawn(),
			"distance": _current_distance,
			"phase": _current_phase,
			"detail": "%.1fms (%.0f FPS) during %s" % [
				_last_frame_time_ms, 1000.0 / maxf(_last_frame_time_ms, 0.001),
				PHASE_NAMES[_current_phase] if _current_phase < PHASE_NAMES.size() else "?"],
		})

	# --- Flicker detection ---
	_check_flicker()

	# --- Update phase peaks ---
	_update_phase_peaks(stats)

	_prev_distance = _current_distance


func _check_flicker() -> void:
	if _tier_change_frames.size() < FLICKER_THRESHOLD:
		return

	var current_frame := Engine.get_frames_drawn()
	# Count recent tier changes within window
	var recent := 0
	for f in _tier_change_frames:
		if current_frame - f <= FLICKER_WINDOW_FRAMES:
			recent += 1

	if recent >= FLICKER_THRESHOLD:
		_log_event("flicker", "%d tier changes in %d frames at %.1fm" % [
			recent, FLICKER_WINDOW_FRAMES, _current_distance])
		_anomalies.append({
			"type": "flicker",
			"frame": current_frame,
			"distance": _current_distance,
			"phase": _current_phase,
			"detail": "%d tier changes in %d frames" % [recent, FLICKER_WINDOW_FRAMES],
		})
		# Reset to avoid spamming
		_tier_change_frames.clear()


func _update_phase_peaks(stats: Dictionary) -> void:
	if _current_phase not in _phase_peaks:
		return
	var peaks: Dictionary = _phase_peaks[_current_phase]
	var mid: int = stats.get("mid_instances", 0)
	var far: int = stats.get("total_impostors", 0)
	var promo: int = stats.get("mid_to_near_promotions", 0)
	peaks["mid"] = maxi(peaks["mid"], mid)
	peaks["far"] = maxi(peaks["far"], far)
	peaks["near"] = maxi(peaks["near"], promo)  # promoted count as proxy for NEAR
	peaks["max_frame_time"] = maxf(peaks["max_frame_time"], _last_frame_time_ms)

#endregion


#region Signal Handlers

func _on_cell_loading(grid: Vector2i) -> void:
	_log_event("cell_loading", "Cell %s" % grid)

func _on_cell_loaded(grid: Vector2i, object_count: int) -> void:
	_log_event("cell_loaded", "Cell %s (%d objects)" % [grid, object_count])

func _on_cell_unloaded(grid: Vector2i) -> void:
	_log_event("cell_unloaded", "Cell %s" % grid)

func _log_event(event: String, detail: String) -> void:
	var entry := {
		"frame": Engine.get_frames_drawn(),
		"time_ms": Time.get_ticks_msec(),
		"phase": _current_phase,
		"event": event,
		"distance": _current_distance,
		"tier": TU.get_tier_name(_current_tier),
		"detail": detail,
	}
	_event_log.append(entry)

	# Keep log bounded
	if _event_log.size() > MAX_EVENT_LOG:
		_event_log = _event_log.slice(_event_log.size() - MAX_EVENT_LOG)

	# Also log to the structured log system
	var phase_name: String = PHASE_NAMES[_current_phase] if _current_phase < PHASE_NAMES.size() else "?"
	Log.info("testing", "[%s] %s: %s" % [phase_name, event, detail])

#endregion


#region Metrics Logging

func _log_frame() -> void:
	var stats := _get_streaming_stats()

	var entry := PackedFloat64Array()
	entry.resize(23)
	entry[0] = float(Engine.get_frames_drawn())                                         # frame
	entry[1] = _last_frame_time_ms                                                       # time_ms
	entry[2] = Engine.get_frames_per_second()                                            # fps
	entry[3] = float(_current_phase)                                                     # phase
	# phase_name is string — stored as index, resolved in CSV
	entry[4] = _current_distance                                                         # cam_distance
	entry[5] = float(_current_tier)                                                      # cam_tier
	entry[6] = _camera.global_position.x                                                 # cam_x
	entry[7] = _camera.global_position.y                                                 # cam_y
	entry[8] = _camera.global_position.z                                                 # cam_z
	entry[9] = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)                    # node_count
	entry[10] = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)    # draw_calls
	entry[11] = Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)       # rendered_objects
	entry[12] = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)    # primitives
	entry[13] = float(stats.get("loaded_cells", 0))                                     # loaded_cells
	entry[14] = float(stats.get("load_queue_size", 0))                                  # queue_size
	entry[15] = float(stats.get("mid_instances", 0))                                    # mid_instances
	entry[16] = float(stats.get("mid_visible", 0))                                      # mid_visible
	entry[17] = float(stats.get("mid_mesh_types", 0))                                   # mid_mesh_types
	entry[18] = float(stats.get("total_impostors", 0))                                  # far_impostors
	entry[19] = float(stats.get("mid_to_near_promotions", 0))                           # promotions_total
	entry[20] = float(stats.get("near_to_mid_demotions", 0))                            # demotions_total
	entry[21] = Performance.get_monitor(Performance.MEMORY_STATIC)                       # memory_static
	# Entry 22 unused (padding for potential future columns)
	entry[22] = 0.0

	_frame_log.append(entry)


func _get_streaming_stats() -> Dictionary:
	if _streaming_manager and _streaming_manager.has_method("get_stats"):
		return _streaming_manager.get_stats()
	return {}

#endregion


#region HUD Update

func _update_hud() -> void:
	if not _distance_label:
		return

	var stats := _get_streaming_stats()
	var tier_name := TU.get_tier_name(_current_tier)

	# Tier detail (sub-LOD info for MID tier)
	var tier_detail := tier_name
	if _current_tier == TU.Tier.MID:
		if _current_distance < 250.0:
			tier_detail = "MID (LOD1: 150-250m)"
		elif _current_distance < 375.0:
			tier_detail = "MID (LOD2: 250-375m)"
		else:
			tier_detail = "MID (LOD3: 375-500m)"

	_distance_label.text = "Distance: %.1fm" % _current_distance
	_tier_label.text = "Tier: %s" % tier_detail

	var phase_name: String = PHASE_NAMES[_current_phase] if _current_phase < PHASE_NAMES.size() else "done"
	_phase_label.text = "Phase: %d/%d — %s" % [_current_phase + 1, PHASE_NAMES.size(), phase_name]

	var promotions: int = stats.get("mid_to_near_promotions", 0)
	_near_label.text = "NEAR: %d promoted objects" % promotions
	_mid_label.text = "MID: %d instances (%d visible)" % [
		stats.get("mid_instances", 0), stats.get("mid_visible", 0)]
	_far_label.text = "FAR: %d impostors" % stats.get("total_impostors", 0)

	var fps := Engine.get_frames_per_second()
	_fps_label.text = "FPS: %d | Frame: %.1fms" % [fps, _last_frame_time_ms]

	var draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var node_count := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var loaded_cells: int = stats.get("loaded_cells", 0)
	_detail_label.text = "Draw: %d | Nodes: %d | Cells: %d" % [draw_calls, node_count, loaded_cells]

	var demotions: int = stats.get("near_to_mid_demotions", 0)
	_promo_label.text = "Promotions: %d | Demotions: %d" % [promotions, demotions]

	# Progress bar
	if _progress_bar and _waypoints.size() > 0:
		_progress_bar.value = float(_current_waypoint_index) / float(_waypoints.size()) * 100.0

	# Event log (last N events)
	_update_event_display()


func _update_event_display() -> void:
	if not _event_log_label:
		return

	var start_idx := maxi(0, _event_log.size() - MAX_DISPLAY_EVENTS)
	var bbcode := ""
	for i in range(start_idx, _event_log.size()):
		var ev: Dictionary = _event_log[i]
		var phase_name: String = PHASE_NAMES[ev.phase] if ev.phase < PHASE_NAMES.size() else "?"
		var color := _get_event_color(ev.event)
		bbcode += "[color=%s][%s] %s:[/color] %s\n" % [color, phase_name, ev.event, ev.detail]

	_event_log_label.text = ""
	_event_log_label.append_text(bbcode)


func _get_event_color(event: String) -> String:
	match event:
		"tier_transition": return "#ffff00"
		"promotion": return "#00ff00"
		"demotion": return "#00ccff"
		"cell_loaded": return "#aaaaff"
		"cell_loading": return "#888888"
		"cell_unloaded": return "#ff8888"
		"sub_lod_crossing": return "#ffaa00"
		"visibility_drop": return "#ff4444"
		"frame_spike": return "#ff0000"
		"flicker": return "#ff00ff"
		"impostor_change": return "#cc88ff"
		"mid_change": return "#88ccff"
		"test_start": return "#ffffff"
		"teleport": return "#aaaaaa"
		_: return "#cccccc"

#endregion


#region Test Completion

func _finish_test() -> void:
	_running = false
	_finished = true

	Log.info("testing", "LodTransitionTest: Test complete — processing results")

	var results := _calculate_results()
	_save_csv()
	_save_events_csv()
	_print_summary(results)

	test_complete.emit(results)

	# Reset debug logging
	Log.set_category_level("streaming", Log.Level.INFO)

	# CRITICAL: Disable streaming manager process to prevent exit crash
	# during prototype duplication in _calculate_results phase
	if _streaming_manager:
		_streaming_manager.set_process(false)

	if not _owns_streaming:
		get_tree().create_timer(2.0).timeout.connect(queue_free)


func _calculate_results() -> Dictionary:
	if _frame_log.is_empty():
		return {}

	var total_frames := _frame_log.size()
	var frame_times := PackedFloat64Array()
	frame_times.resize(total_frames)
	for i in range(total_frames):
		frame_times[i] = _frame_log[i][1]

	var sorted_times := frame_times.duplicate()
	_sort_float_array(sorted_times)

	var total_time := 0.0
	for t in frame_times:
		total_time += t

	var avg_time := total_time / float(total_frames)
	var p50 := sorted_times[total_frames / 2]
	var p95 := sorted_times[int(total_frames * 0.95)]
	var p99 := sorted_times[int(total_frames * 0.99)]

	var max_time := 0.0
	var max_frame := 0
	for i in range(total_frames):
		if frame_times[i] > max_time:
			max_time = frame_times[i]
			max_frame = i

	# Per-phase breakdown
	var phase_data: Dictionary = {}
	for phase_idx in range(PHASE_NAMES.size()):
		var phase_times: Array[float] = []
		for entry in _frame_log:
			if int(entry[3]) == phase_idx:
				phase_times.append(entry[1])
		if phase_times.is_empty():
			continue
		phase_times.sort()
		var phase_avg := 0.0
		for t in phase_times:
			phase_avg += t
		phase_avg /= float(phase_times.size())
		var phase_p99 := phase_times[int(phase_times.size() * 0.99)] if phase_times.size() > 1 else phase_times[0]
		phase_data[PHASE_NAMES[phase_idx]] = {
			"avg": phase_avg, "p99": phase_p99, "frames": phase_times.size()
		}

	# Pass/fail checks
	var pass_fail := _check_pass_fail()

	return {
		"total_frames": total_frames,
		"total_time_s": total_time / 1000.0,
		"avg_time_ms": avg_time,
		"avg_fps": 1000.0 / maxf(avg_time, 0.001),
		"p50_ms": p50,
		"p95_ms": p95,
		"p99_ms": p99,
		"max_time_ms": max_time,
		"max_frame": max_frame,
		"boundary_crossings": _boundary_crossings,
		"anomalies": _anomalies,
		"phase_peaks": _phase_peaks,
		"phase_data": phase_data,
		"pass_fail": pass_fail,
	}


func _check_pass_fail() -> Dictionary:
	var checks: Dictionary = {}

	# Check: All 4 boundary crossings observed
	var crossing_pairs := {}
	for bc in _boundary_crossings:
		var key: String = "%s->%s" % [bc.from_tier, bc.to_tier]
		crossing_pairs[key] = bc

	checks["far_to_mid"] = "FAR->MID" in crossing_pairs
	checks["mid_to_near"] = "MID->NEAR" in crossing_pairs
	checks["near_to_mid"] = "NEAR->MID" in crossing_pairs
	checks["mid_to_far"] = "MID->FAR" in crossing_pairs

	# Check: Hysteresis — demotion should happen at >160m, not exactly at 150m
	var demotion_distance := 0.0
	if "NEAR->MID" in crossing_pairs:
		demotion_distance = crossing_pairs["NEAR->MID"].distance
	checks["hysteresis_ok"] = demotion_distance > 160.0 if demotion_distance > 0 else false

	# Check: Objects present in each tier
	checks["near_populated"] = _phase_peaks.get(5, {}).get("near", 0) > 0  # NEAR_HOLD phase
	checks["mid_populated"] = _phase_peaks.get(3, {}).get("mid", 0) > 0    # MID_TRAVERSE phase
	checks["far_populated"] = _phase_peaks.get(1, {}).get("far", 0) > 0    # FAR_APPROACH phase

	# Check: No flicker
	var flicker_count := 0
	for a in _anomalies:
		if a.type == "flicker":
			flicker_count += 1
	checks["no_flicker"] = flicker_count == 0

	# Overall
	checks["all_pass"] = (
		checks["far_to_mid"] and checks["mid_to_near"] and
		checks["near_to_mid"] and checks["mid_to_far"] and
		checks["hysteresis_ok"] and checks["near_populated"] and
		checks["mid_populated"] and checks["far_populated"] and
		checks["no_flicker"]
	)

	return checks


func _sort_float_array(arr: PackedFloat64Array) -> void:
	for i in range(1, arr.size()):
		var key := arr[i]
		var j := i - 1
		while j >= 0 and arr[j] > key:
			arr[j + 1] = arr[j]
			j -= 1
		arr[j + 1] = key

#endregion


#region CSV Output

func _save_csv() -> void:
	var dir_path := "user://lod_test_results"
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var file_path := "%s/lod_test_%s.csv" % [dir_path, timestamp]

	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if not file:
		Log.error("testing", "LodTransitionTest: Failed to write CSV to %s" % file_path)
		return

	file.store_line(CSV_HEADERS)
	for entry in _frame_log:
		var phase_idx := int(entry[3])
		var phase_name: String = PHASE_NAMES[phase_idx] if phase_idx < PHASE_NAMES.size() else "unknown"
		var tier_name := TU.get_tier_name(int(entry[5]))
		var line := "%d,%.2f,%.1f,%d,%s,%.1f,%s,%.1f,%.1f,%.1f,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%.0f" % [
			int(entry[0]),   # frame
			entry[1],        # time_ms
			entry[2],        # fps
			phase_idx,       # phase
			phase_name,      # phase_name
			entry[4],        # cam_distance
			tier_name,       # cam_tier
			entry[6],        # cam_x
			entry[7],        # cam_y
			entry[8],        # cam_z
			int(entry[9]),   # node_count
			int(entry[10]),  # draw_calls
			int(entry[11]),  # rendered_objects
			int(entry[12]),  # primitives
			int(entry[13]),  # loaded_cells
			int(entry[14]),  # queue_size
			int(entry[15]),  # mid_instances
			int(entry[16]),  # mid_visible
			int(entry[17]),  # mid_mesh_types
			int(entry[18]),  # far_impostors
			int(entry[19]),  # promotions_total
			int(entry[20]),  # demotions_total
			entry[21],       # memory_static
		]
		file.store_line(line)

	file.close()
	Log.info("testing", "LodTransitionTest: CSV saved to %s (%d frames)" % [file_path, _frame_log.size()])


func _save_events_csv() -> void:
	if _event_log.is_empty():
		return

	var dir_path := "user://lod_test_results"
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var file_path := "%s/lod_events_%s.csv" % [dir_path, timestamp]

	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if not file:
		return

	file.store_line("frame,time_ms,phase,event,distance,tier,detail")
	for entry: Dictionary in _event_log:
		file.store_line("%d,%d,%d,%s,%.1f,%s,%s" % [
			entry.frame, entry.time_ms, entry.phase,
			entry.event, entry.distance, entry.tier,
			str(entry.detail).replace(",", ";")
		])

	file.close()
	Log.info("testing", "LodTransitionTest: Events CSV saved to %s (%d events)" % [file_path, _event_log.size()])

#endregion


#region Summary Report

func _print_summary(results: Dictionary) -> void:
	if results.is_empty():
		return

	var L: PackedStringArray = PackedStringArray()
	L.append("========== LOD TRANSITION TEST RESULTS ==========")
	L.append("Duration: %.1fs (%d frames)" % [results.total_time_s, results.total_frames])
	L.append("Target: Cell %s at %s" % [SPAWN_CELL, _target_center])
	L.append("")

	# --- Tier Boundary Crossings ---
	L.append("=== Tier Boundary Crossings ===")
	if _boundary_crossings.is_empty():
		L.append("  (none observed)")
	else:
		for bc in _boundary_crossings:
			var phase_name: String = PHASE_NAMES[bc.phase] if bc.phase < PHASE_NAMES.size() else "?"
			L.append("  %s -> %s at %.1fm (frame %d, %d FPS, phase: %s)" % [
				bc.from_tier, bc.to_tier, bc.distance,
				bc.frame, bc.fps, phase_name])
			L.append("    MID: %d, FAR: %d" % [bc.mid, bc.far])
	L.append("")

	# --- Peak Object Counts per Phase ---
	L.append("=== Peak Object Counts per Phase ===")
	for i in range(PHASE_NAMES.size()):
		if i in _phase_peaks:
			var p: Dictionary = _phase_peaks[i]
			L.append("  %-18s NEAR: %d, MID: %d, FAR: %d (max frame: %.1fms)" % [
				PHASE_NAMES[i] + ":", p.near, p.mid, p.far, p.max_frame_time])
	L.append("")

	# --- Promotion/Demotion Summary ---
	L.append("=== Promotion/Demotion Summary ===")
	var final_stats := _get_streaming_stats()
	var total_promotions: int = final_stats.get("mid_to_near_promotions", 0)
	var total_demotions: int = final_stats.get("near_to_mid_demotions", 0)
	L.append("  Total MID->NEAR promotions: %d" % total_promotions)
	L.append("  Total NEAR->MID demotions: %d" % total_demotions)
	if total_promotions > 0 and total_demotions > 0:
		var ratio := float(total_demotions) / float(total_promotions) * 100.0
		L.append("  Demotion/Promotion ratio: %.0f%%" % ratio)
	L.append("")

	# --- Hysteresis Verification ---
	L.append("=== Hysteresis Verification ===")
	var pass_fail: Dictionary = results.pass_fail
	for bc in _boundary_crossings:
		if bc.from_tier == "NEAR" and bc.to_tier == "MID":
			var status := "OK" if bc.distance > 160.0 else "FAIL (expected >160m)"
			L.append("  NEAR->MID demotion at %.1fm — %s" % [bc.distance, status])
		if bc.from_tier == "MID" and bc.to_tier == "NEAR":
			L.append("  MID->NEAR transition at %.1fm" % bc.distance)
	L.append("")

	# --- Anomalies ---
	L.append("=== Anomalies ===")
	if _anomalies.is_empty():
		L.append("  None detected")
	else:
		var by_type: Dictionary = {}
		for a in _anomalies:
			var t: String = a.type
			if t not in by_type:
				by_type[t] = []
			by_type[t].append(a)
		for atype: String in by_type:
			var items: Array = by_type[atype]
			L.append("  %s: %d" % [atype, items.size()])
			# Show first 3 of each type
			for j in range(mini(3, items.size())):
				var a: Dictionary = items[j]
				var phase_name: String = PHASE_NAMES[a.phase] if a.phase < PHASE_NAMES.size() else "?"
				L.append("    Frame %d: %s (%.1fm, %s)" % [a.frame, a.detail, a.distance, phase_name])
			if items.size() > 3:
				L.append("    ... and %d more" % (items.size() - 3))
	L.append("")

	# --- Performance per Phase ---
	L.append("=== Performance per Phase ===")
	var phase_data: Dictionary = results.get("phase_data", {})
	for phase_name: String in PHASE_NAMES:
		if phase_name in phase_data:
			var pd: Dictionary = phase_data[phase_name]
			L.append("  %-18s avg %5.1fms  p99 %5.1fms  (%d frames)" % [
				phase_name + ":", pd.avg, pd.p99, pd.frames])
	L.append("")

	# --- Overall Performance ---
	L.append("=== Overall Performance ===")
	L.append("  Average: %.1fms (%.0f FPS)" % [results.avg_time_ms, results.avg_fps])
	L.append("  P50: %.1fms  P95: %.1fms  P99: %.1fms" % [results.p50_ms, results.p95_ms, results.p99_ms])
	L.append("  Max: %.1fms (frame %d)" % [results.max_time_ms, results.max_frame])
	L.append("")

	# --- Pass/Fail ---
	L.append("=== Pass/Fail ===")
	var check_labels := {
		"far_to_mid": "FAR->MID crossing observed",
		"mid_to_near": "MID->NEAR crossing observed",
		"near_to_mid": "NEAR->MID crossing observed",
		"mid_to_far": "MID->FAR crossing observed",
		"hysteresis_ok": "Hysteresis demotion >160m",
		"near_populated": "NEAR objects present in hold phase",
		"mid_populated": "MID instances present in traverse phase",
		"far_populated": "FAR impostors present in approach phase",
		"no_flicker": "No flicker events detected",
	}
	for key: String in check_labels:
		var passed: bool = pass_fail.get(key, false)
		var mark := "PASS" if passed else "FAIL"
		L.append("  [%s] %s" % [mark, check_labels[key]])

	var all_pass: bool = pass_fail.get("all_pass", false)
	L.append("")
	L.append("  OVERALL: %s" % ("ALL CHECKS PASSED" if all_pass else "SOME CHECKS FAILED"))
	L.append("")

	# --- File paths ---
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	L.append("CSV: user://lod_test_results/lod_test_%s.csv" % timestamp)
	L.append("Events: user://lod_test_results/lod_events_%s.csv" % timestamp)
	L.append("==================================================")

	var output := "\n".join(L)
	Log.info("testing", output)

	if _console and _console.has_method("print_line"):
		for line: String in L:
			_console.print_line(line)

#endregion


#region Console Command Registration

static func register_console_commands(console: Node, streaming_manager, cell_manager, camera: Camera3D) -> void:
	var script := load("res://src/tools/lod_transition_test.gd")
	var run := func(args: Dictionary) -> Variant:
		var test: Node3D = script.new()
		test.name = "LodTransitionTest"
		console.get_tree().root.add_child(test)
		test.init_console_mode(streaming_manager, cell_manager, camera, console)
		return "LOD transition test started (~75s)..."

	console.register_command(
		"test_lod_transitions", run,
		"Run LOD tier transition test (~75s)",
		"debug",
		PackedStringArray(["lod_test"]),
	)

#endregion


#region Cleanup

func _exit_tree() -> void:
	# Disconnect streaming signals
	if _streaming_manager:
		if _streaming_manager.has_signal("cell_loading") and _streaming_manager.cell_loading.is_connected(_on_cell_loading):
			_streaming_manager.cell_loading.disconnect(_on_cell_loading)
		if _streaming_manager.has_signal("cell_loaded") and _streaming_manager.cell_loaded.is_connected(_on_cell_loaded):
			_streaming_manager.cell_loaded.disconnect(_on_cell_loaded)
		if _streaming_manager.has_signal("cell_unloaded") and _streaming_manager.cell_unloaded.is_connected(_on_cell_unloaded):
			_streaming_manager.cell_unloaded.disconnect(_on_cell_unloaded)

	# Reset log level
	Log.set_category_level("streaming", Log.Level.INFO)

	Log.info("testing", "LodTransitionTest: Cleaned up")

#endregion
