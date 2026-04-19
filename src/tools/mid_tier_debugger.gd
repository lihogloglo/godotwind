## MidTierDebugger — Console-activated MID-tier visual debug system
##
## Provides instrumented debugging for MID-tier object streaming:
##   - Autopilot camera: back-and-forth flight path at configurable speed
##   - Object census: compares ESM expected objects vs actual loaded objects per cell
##   - Missing object markers: red 3D pillars at positions of expected-but-absent objects
##   - HUD panel: real-time stats overlay
##   - CSV report: data export for remote analysis
##
## Console commands:
##   mid_debug / md       — Toggle full debug mode (autopilot + census + HUD + markers)
##   mid_debug speed <N>  — Set autopilot speed (m/s, default 30)
##   mid_debug diagonal   — Toggle diagonal path (45° across cell corners)
##   mid_census / mc      — One-shot census (prints to console, no autopilot)
##   mid_markers / mm     — Toggle missing object markers only (no autopilot)
##
## Follows the established pattern of StreamingBenchmark and LodTransitionTest.
@warning_ignore("untyped_declaration", "unsafe_method_access")
class_name MidTierDebugger
extends Node3D

const DU := preload("res://src/core/world/distance_utils.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const StreamingPolicyScript := preload("res://src/core/world/streaming_policy.gd")
const NativeStreamingManagerScript := preload("res://src/core/world/native_streaming_manager.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")


#region Inner Classes

class CensusEntry:
	var grid: Vector2i
	var expected: int = 0
	var near: int = 0
	var mid: int = 0
	var queued: int = 0
	var genuinely_missing: int = 0
	var missing_pct: float = 0.0
	## Positions of genuinely missing objects (for markers)
	var missing_positions: Array[Dictionary] = []  # [{pos: Vector3, ref_id: String}]

#endregion


#region Constants

const AUTOPILOT_HEIGHT: float = 100.0
const AUTOPILOT_RANGE: float = 600.0
const DEFAULT_SPEED: float = 30.0
const CENSUS_INTERVAL: float = 5.0
const HUD_UPDATE_INTERVAL: float = 0.25
const MAX_MARKERS: int = 500
const ANOMALY_MIN_MISSING: int = 3
const ANOMALY_MIN_PERCENT: float = 20.0

const CSV_HEADERS := "timestamp_ms,lap,cam_x,cam_y,cam_z,cell_x,cell_y,cells_checked,expected,actual,near,mid,promoted,queued,genuinely_missing,missing_pct,worst_cell,worst_missing,fps"

#endregion


#region State

var _streaming_manager: NativeStreamingManagerScript = null
var _cell_manager: CellManagerScript = null
var _camera: Camera3D = null
var _console: Node = null

## Autopilot state
var _autopilot_active: bool = false
var _autopilot_speed: float = DEFAULT_SPEED
var _autopilot_diagonal: bool = false
var _autopilot_direction: int = 1  # 1 = forward, -1 = backward
var _autopilot_start_pos: Vector3 = Vector3.ZERO
var _autopilot_end_pos: Vector3 = Vector3.ZERO
var _autopilot_progress: float = 0.0
var _saved_camera_transform: Transform3D
var _saved_fly_camera_enabled: bool = true
var _lap_count: int = 0

## Census state
var _last_census: Array[CensusEntry] = []
var _census_timer: float = 0.0
var _total_expected: int = 0
var _total_near: int = 0
var _total_mid: int = 0
var _total_promoted: int = 0
var _total_queued: int = 0
var _total_missing: int = 0
var _anomaly_cells: Array[CensusEntry] = []

## Markers state
var _markers_active: bool = false
var _marker_container: Node3D = null
var _marker_material: StandardMaterial3D = null

## HUD state
var _hud_active: bool = false
var _hud_canvas: CanvasLayer = null
var _hud_label: RichTextLabel = null
var _hud_timer: float = 0.0

## CSV state
var _csv_file: FileAccess = null
var _csv_path: String = ""

## Running mode
var _running: bool = false  # Full debug mode (autopilot + census + HUD + markers)

#endregion


#region Initialization

func _ready() -> void:
	_create_marker_material()


func _exit_tree() -> void:
	stop()


func init(
	streaming_manager: NativeStreamingManagerScript,
	cell_manager: CellManagerScript,
	camera: Camera3D,
	console: Node = null
) -> void:
	_streaming_manager = streaming_manager
	_cell_manager = cell_manager
	_camera = camera
	_console = console

#endregion


#region Autopilot

func _start_autopilot() -> void:
	if not _camera:
		return

	_saved_camera_transform = _camera.global_transform

	# Disable FlyCamera input processing
	if "enabled" in _camera:
		_saved_fly_camera_enabled = _camera.enabled
		_camera.enabled = false

	# Build path from current position
	var cam_pos := _camera.global_position
	var forward := -_camera.global_basis.z
	if _autopilot_diagonal:
		# 45 degree rotation for diagonal path
		forward = forward.rotated(Vector3.UP, PI / 4.0)
	forward.y = 0.0
	forward = forward.normalized()

	_autopilot_start_pos = cam_pos
	_autopilot_start_pos.y = cam_pos.y  # Keep current altitude
	_autopilot_end_pos = cam_pos + forward * AUTOPILOT_RANGE
	_autopilot_end_pos.y = cam_pos.y

	_autopilot_progress = 0.5  # Start at midpoint (current position)
	_autopilot_direction = 1
	_autopilot_active = true
	_lap_count = 0

	Log.info("tools", "MidTierDebugger: Autopilot started at %.0f m/s" % _autopilot_speed)


func _stop_autopilot() -> void:
	if not _autopilot_active:
		return

	_autopilot_active = false

	# Restore camera
	if _camera and is_instance_valid(_camera):
		_camera.global_transform = _saved_camera_transform
		if "enabled" in _camera:
			_camera.enabled = _saved_fly_camera_enabled

	Log.info("tools", "MidTierDebugger: Autopilot stopped")


func _update_autopilot(delta: float) -> void:
	if not _autopilot_active or not _camera:
		return

	var path_length := _autopilot_start_pos.distance_to(_autopilot_end_pos)
	if path_length < 1.0:
		return

	var speed_normalized := (_autopilot_speed * delta) / path_length
	_autopilot_progress += speed_normalized * _autopilot_direction

	# Bounce at endpoints
	if _autopilot_progress >= 1.0:
		_autopilot_progress = 1.0
		_autopilot_direction = -1
		_lap_count += 1
		_run_census()
	elif _autopilot_progress <= 0.0:
		_autopilot_progress = 0.0
		_autopilot_direction = 1
		_lap_count += 1
		_run_census()

	# Position camera
	var pos := _autopilot_start_pos.lerp(_autopilot_end_pos, _autopilot_progress)
	_camera.global_position = pos

	# Look toward travel direction
	var look_target := pos + (_autopilot_end_pos - _autopilot_start_pos).normalized() * float(_autopilot_direction) * 10.0
	look_target.y = pos.y - 5.0  # Slight downward look
	if pos.distance_squared_to(look_target) > 1.0:
		_camera.look_at(look_target)

#endregion


#region Census

func _run_census() -> void:
	if not _streaming_manager or not _cell_manager:
		return

	_last_census.clear()
	_total_expected = 0
	_total_near = 0
	_total_mid = 0
	_total_queued = 0
	_total_missing = 0
	_anomaly_cells.clear()

	var loaded_coords: Array[Vector2i] = _streaming_manager.get_loaded_cell_coordinates()

	# Get static renderer for MID counts
	var static_renderer = _streaming_manager.get("_static_renderer")

	# S.1: promoted tracking deleted — per-cell tier FSM replaces it in S.7+.
	_total_promoted = 0

	# Get queue size
	_total_queued = _cell_manager.get_instantiation_queue_size()

	for grid: Vector2i in loaded_coords:
		var entry := _census_cell(grid, static_renderer)
		_last_census.append(entry)
		_total_expected += entry.expected
		_total_near += entry.near
		_total_mid += entry.mid
		_total_missing += entry.genuinely_missing

		# Flag anomalies
		if entry.genuinely_missing > ANOMALY_MIN_MISSING and entry.missing_pct > ANOMALY_MIN_PERCENT:
			_anomaly_cells.append(entry)

	# Sort anomalies by missing count (worst first)
	_anomaly_cells.sort_custom(func(a: CensusEntry, b: CensusEntry) -> bool:
		return a.genuinely_missing > b.genuinely_missing
	)

	# Update markers if active
	if _markers_active:
		_rebuild_markers()

	# Write CSV row
	_write_csv_row()

	Log.info("tools", "MidTierDebugger: Census — %d cells, %d expected, %d near, %d mid, %d missing (%.1f%%)" % [
		loaded_coords.size(), _total_expected, _total_near, _total_mid, _total_missing,
		(float(_total_missing) / maxf(float(_total_expected), 1.0)) * 100.0
	])


func _census_cell(grid: Vector2i, static_renderer: Variant) -> CensusEntry:
	var entry := CensusEntry.new()
	entry.grid = grid

	# Expected: count ESM references with valid models that pass StreamingPolicy
	var cell_record = ESMManager.get_exterior_cell(grid.x, grid.y)
	if not cell_record:
		return entry

	var expected_refs: Array[Dictionary] = []  # [{pos: Vector3, ref_id: String}]

	for ref in cell_record.references:
		if ref.is_deleted:
			continue

		var ref_id_str: String = str(ref.ref_id)

		# Skip NPCs/creatures if not loaded
		var out_type: Array = [""]
		var record = ESMManager.get_any_record(ref_id_str, out_type)
		if not record:
			continue

		var type_name: String = out_type[0]

		# Skip NPCs/creatures based on cell_manager flags
		if type_name == "npc" and not _cell_manager.load_npcs:
			continue
		if type_name == "creature" and not _cell_manager.load_creatures:
			continue

		# Get model path
		var model_path: String = ""
		if "model" in record and record.model:
			model_path = record.model

		# Skip references with no model
		if model_path.is_empty():
			continue

		# Skip items not visible in MID tier (small objects, inventory items)
		if not StreamingPolicyScript.is_mid_worthy(type_name, model_path):
			continue

		entry.expected += 1

		# Convert MW position to Godot for marker placement
		var godot_pos: Vector3 = CS.vector_to_godot(ref.position)
		expected_refs.append({"pos": godot_pos, "ref_id": ref_id_str})

	# Actual NEAR: children of the cell container
	var cell_node: Node3D = _streaming_manager.get_loaded_cell(grid)
	if cell_node:
		entry.near = cell_node.get_child_count()

	# Actual MID: static renderer count for this cell
	if static_renderer:
		var cell_index: Dictionary = static_renderer.get("_cell_index")
		if cell_index and grid in cell_index:
			entry.mid = cell_index[grid].size()

	# Genuinely missing = expected - near - mid (clamped to 0)
	# We don't subtract queued here because queue is global, not per-cell
	var actual := entry.near + entry.mid
	entry.genuinely_missing = maxi(0, entry.expected - actual)

	if entry.expected > 0:
		entry.missing_pct = (float(entry.genuinely_missing) / float(entry.expected)) * 100.0

	# Find positions of missing objects by checking which expected refs have no loaded child nearby
	if entry.genuinely_missing > 0 and cell_node:
		var loaded_positions: Array[Vector3] = []
		for child_idx in cell_node.get_child_count():
			var child: Node3D = cell_node.get_child(child_idx) as Node3D
			if child:
				loaded_positions.append(child.global_position)

		# Also check static renderer objects for this cell
		if static_renderer:
			var cell_index: Dictionary = static_renderer.get("_cell_index")
			var instances: Dictionary = static_renderer.get("_instances")
			if cell_index and grid in cell_index and instances:
				for obj_id in cell_index[grid]:
					var obj_entry = instances.get(obj_id)
					if obj_entry:
						loaded_positions.append(obj_entry.transform.origin)

		for ref_data: Dictionary in expected_refs:
			var ref_pos: Vector3 = ref_data["pos"]
			var found := false
			for loaded_pos: Vector3 in loaded_positions:
				if ref_pos.distance_squared_to(loaded_pos) < 4.0:  # 2m threshold
					found = true
					break
			if not found:
				entry.missing_positions.append(ref_data)

	return entry

#endregion


#region Markers

func _create_marker_material() -> void:
	_marker_material = StandardMaterial3D.new()
	_marker_material.albedo_color = Color(1.0, 0.15, 0.1, 0.8)
	_marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_marker_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_marker_material.no_depth_test = true
	_marker_material.cull_mode = BaseMaterial3D.CULL_DISABLED


func _enable_markers() -> void:
	_markers_active = true
	if not _marker_container:
		_marker_container = Node3D.new()
		_marker_container.name = "MissingObjectMarkers"
		get_tree().current_scene.add_child(_marker_container)


func _disable_markers() -> void:
	_markers_active = false
	if _marker_container and is_instance_valid(_marker_container):
		_marker_container.queue_free()
		_marker_container = null


func _rebuild_markers() -> void:
	if not _marker_container or not is_instance_valid(_marker_container):
		return

	# Clear existing markers
	for child in _marker_container.get_children():
		child.queue_free()

	var marker_count := 0
	for entry: CensusEntry in _last_census:
		for ref_data: Dictionary in entry.missing_positions:
			if marker_count >= MAX_MARKERS:
				break
			_create_marker(ref_data["pos"], ref_data["ref_id"])
			marker_count += 1
		if marker_count >= MAX_MARKERS:
			break

	Log.debug("tools", "MidTierDebugger: Placed %d missing object markers" % marker_count)


func _create_marker(pos: Vector3, ref_id: String) -> void:
	var marker := Node3D.new()
	marker.position = pos

	# Vertical pillar (0 to 10m)
	var pillar_mesh := ImmediateMesh.new()
	pillar_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	pillar_mesh.surface_add_vertex(Vector3.ZERO)
	pillar_mesh.surface_add_vertex(Vector3(0, 10, 0))
	# Ground cross
	pillar_mesh.surface_add_vertex(Vector3(-1, 0, 0))
	pillar_mesh.surface_add_vertex(Vector3(1, 0, 0))
	pillar_mesh.surface_add_vertex(Vector3(0, 0, -1))
	pillar_mesh.surface_add_vertex(Vector3(0, 0, 1))
	pillar_mesh.surface_end()

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = pillar_mesh
	mesh_inst.material_override = _marker_material
	marker.add_child(mesh_inst)

	# Label at top
	var label := Label3D.new()
	label.text = ref_id
	label.font_size = 32
	label.modulate = Color(1.0, 0.3, 0.2)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.position = Vector3(0, 11, 0)
	marker.add_child(label)

	_marker_container.add_child(marker)

#endregion


#region HUD

func _build_hud() -> void:
	_hud_canvas = CanvasLayer.new()
	_hud_canvas.name = "MidDebugHUD"
	_hud_canvas.layer = 100
	add_child(_hud_canvas)

	var panel := PanelContainer.new()
	panel.name = "MidDebugPanel"

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.1, 0.85)
	style.border_color = Color(0.8, 0.3, 0.2, 0.6)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)

	# Anchor to top-left
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 10
	panel.offset_top = 10
	panel.offset_right = 400
	panel.offset_bottom = 300

	_hud_label = RichTextLabel.new()
	_hud_label.bbcode_enabled = true
	_hud_label.fit_content = true
	_hud_label.scroll_active = false
	_hud_label.custom_minimum_size = Vector2(380, 0)
	_hud_label.add_theme_font_size_override("normal_font_size", 13)
	_hud_label.add_theme_font_size_override("bold_font_size", 14)

	panel.add_child(_hud_label)
	_hud_canvas.add_child(panel)
	_hud_active = true


func _destroy_hud() -> void:
	_hud_active = false
	if _hud_canvas and is_instance_valid(_hud_canvas):
		_hud_canvas.queue_free()
		_hud_canvas = null
		_hud_label = null


func _update_hud() -> void:
	if not _hud_label:
		return

	var status_str := "STOPPED"
	if _autopilot_active:
		status_str = "RUNNING %.0f m/s" % _autopilot_speed
	elif _markers_active:
		status_str = "MARKERS ONLY"

	var text := "[b][color=#ff6644]MID Debug[/color][/b] [%s] Lap %d\n" % [status_str, _lap_count]
	text += "[color=#888]━━━━━━━━━━━━━━━━━━━━━━━━━━[/color]\n"

	var cells_checked := _last_census.size()
	var actual := _total_near + _total_mid
	var missing_pct := (float(_total_missing) / maxf(float(_total_expected), 1.0)) * 100.0

	text += "[b]Census:[/b] %d cells | %d expected | %d actual\n" % [cells_checked, _total_expected, actual]
	text += "  NEAR: %d | MID: %d | Promoted: %d\n" % [_total_near, _total_mid, _total_promoted]
	text += "  Missing: %d (%.1f%%) | Queue: %d\n" % [_total_missing, missing_pct, _total_queued]

	if _camera:
		var cam_pos := _camera.global_position
		text += "[color=#888]Cam: (%.0f, %.0f, %.0f)[/color]\n" % [cam_pos.x, cam_pos.y, cam_pos.z]

	text += "[b]FPS:[/b] %d\n" % Engine.get_frames_per_second()

	if not _anomaly_cells.is_empty():
		text += "[color=#888]━━━━━━━━━━━━━━━━━━━━━━━━━━[/color]\n"
		text += "[b][color=#ff4444]Anomalies:[/color][/b]\n"
		var show_count := mini(_anomaly_cells.size(), 5)
		for i in show_count:
			var a: CensusEntry = _anomaly_cells[i]
			text += "  [color=#ff6644](%d,%d)[/color]: %d missing/%d exp\n" % [
				a.grid.x, a.grid.y, a.genuinely_missing, a.expected
			]

	_hud_label.text = text

#endregion


#region CSV

func _open_csv() -> void:
	var dir_path := "user://mid_debug_reports"
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	_csv_path = "%s/mid_debug_%s.csv" % [dir_path, timestamp]

	_csv_file = FileAccess.open(_csv_path, FileAccess.WRITE)
	if _csv_file:
		_csv_file.store_line(CSV_HEADERS)
		_csv_file.flush()
		Log.info("tools", "MidTierDebugger: CSV opened at %s" % _csv_path)


func _write_csv_row() -> void:
	if not _csv_file:
		return

	var cam_pos := _camera.global_position if _camera else Vector3.ZERO

	# Find worst cell
	var worst_cell := ""
	var worst_missing := 0
	for entry: CensusEntry in _anomaly_cells:
		if entry.genuinely_missing > worst_missing:
			worst_missing = entry.genuinely_missing
			worst_cell = "(%d;%d)" % [entry.grid.x, entry.grid.y]

	var actual := _total_near + _total_mid
	var missing_pct := (float(_total_missing) / maxf(float(_total_expected), 1.0)) * 100.0

	var cam_cell := DU.world_to_cell(cam_pos) if _camera else Vector2i.ZERO

	var line := "%d,%d,%.1f,%.1f,%.1f,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%.1f,%s,%d,%d" % [
		Time.get_ticks_msec(), _lap_count,
		cam_pos.x, cam_pos.y, cam_pos.z,
		cam_cell.x, cam_cell.y,
		_last_census.size(),
		_total_expected, actual, _total_near, _total_mid, _total_promoted,
		_total_queued, _total_missing, missing_pct,
		worst_cell, worst_missing,
		Engine.get_frames_per_second()
	]
	_csv_file.store_line(line)
	_csv_file.flush()


func _close_csv() -> void:
	if _csv_file:
		_csv_file.close()
		_csv_file = null
		Log.info("tools", "MidTierDebugger: CSV saved to %s" % _csv_path)

#endregion


#region Process

func _process(delta: float) -> void:
	if _autopilot_active:
		_update_autopilot(delta)

		# Periodic census during autopilot
		_census_timer += delta
		if _census_timer >= CENSUS_INTERVAL:
			_census_timer = 0.0
			_run_census()

	if _hud_active:
		_hud_timer += delta
		if _hud_timer >= HUD_UPDATE_INTERVAL:
			_hud_timer = 0.0
			_update_hud()

#endregion


#region Public API

## Start full debug mode: autopilot + census + HUD + markers
func start_full() -> void:
	if _running:
		stop()
		return

	_running = true
	_build_hud()
	_enable_markers()
	_open_csv()
	_start_autopilot()

	# Run initial census
	_run_census()


## Stop all debug mode
func stop() -> void:
	_running = false
	_stop_autopilot()
	_destroy_hud()
	_disable_markers()
	_close_csv()


## Run a one-shot census (no autopilot)
func run_census_once() -> String:
	_run_census()

	var lines: PackedStringArray = PackedStringArray()
	lines.append("===== MID-TIER CENSUS =====")
	lines.append("Cells: %d | Expected: %d | Actual: %d" % [
		_last_census.size(), _total_expected, _total_near + _total_mid
	])
	lines.append("  NEAR: %d | MID: %d | Promoted: %d" % [_total_near, _total_mid, _total_promoted])
	lines.append("  Queued: %d | Missing: %d (%.1f%%)" % [
		_total_queued, _total_missing,
		(float(_total_missing) / maxf(float(_total_expected), 1.0)) * 100.0
	])

	if not _anomaly_cells.is_empty():
		lines.append("")
		lines.append("Anomalies:")
		for a: CensusEntry in _anomaly_cells:
			lines.append("  (%d,%d): %d missing / %d expected (%.0f%%)" % [
				a.grid.x, a.grid.y, a.genuinely_missing, a.expected, a.missing_pct
			])

	# Per-cell breakdown
	lines.append("")
	lines.append("Per-cell breakdown:")
	for entry: CensusEntry in _last_census:
		var status := ""
		if entry.genuinely_missing > ANOMALY_MIN_MISSING and entry.missing_pct > ANOMALY_MIN_PERCENT:
			status = " [ANOMALY]"
		lines.append("  (%d,%d): exp=%d near=%d mid=%d miss=%d%s" % [
			entry.grid.x, entry.grid.y, entry.expected, entry.near, entry.mid,
			entry.genuinely_missing, status
		])

	lines.append("===========================")
	return "\n".join(lines)


## Toggle markers only (no autopilot)
func toggle_markers() -> void:
	if _markers_active:
		_disable_markers()
	else:
		_enable_markers()
		_run_census()  # Need census data to place markers


## Whether currently running
func is_running() -> bool:
	return _running

#endregion


#region Visual Audit

## Run a visual audit of all loaded objects — checks for rendering issues
func run_audit() -> String:
	if not _streaming_manager or not _camera:
		return "Streaming manager or camera not available"

	var cam_pos := _camera.global_position
	var cam_cull_mask: int = _camera.cull_mask

	var lines: PackedStringArray = PackedStringArray()
	lines.append("===== MID-TIER VISUAL AUDIT =====")
	lines.append("Camera: (%.0f, %.0f, %.0f)" % [cam_pos.x, cam_pos.y, cam_pos.z])

	# --- NEAR tier audit ---
	var loaded_coords: Array[Vector2i] = _streaming_manager.get_loaded_cell_coordinates()
	var near_stats := _audit_near_cells(loaded_coords, cam_pos, cam_cull_mask)

	lines.append("")
	lines.append("[NEAR Tier] %d objects audited" % near_stats.total)
	if near_stats.no_mesh > 0:
		lines.append("  No mesh: %d" % near_stats.no_mesh)
	if near_stats.no_material > 0:
		lines.append("  No material: %d" % near_stats.no_material)
	if near_stats.bad_range > 0:
		lines.append("  Bad visibility_range: %d" % near_stats.bad_range)
	if near_stats.wrong_layer > 0:
		lines.append("  Wrong layer (invisible to camera): %d" % near_stats.wrong_layer)
	if near_stats.hidden > 0:
		lines.append("  Hidden (visible=false): %d" % near_stats.hidden)
	lines.append("  In camera range & should render: %d" % near_stats.in_range_visible)
	lines.append("  In camera range but blocked: %d" % near_stats.in_range_invisible)

	# Show first 10 issues
	if not near_stats.issues.is_empty():
		lines.append("")
		lines.append("  Issues (first %d):" % mini(near_stats.issues.size(), 10))
		for i in mini(near_stats.issues.size(), 10):
			lines.append("    %s" % near_stats.issues[i])

	# --- MID tier static renderer audit ---
	var static_renderer = _streaming_manager.get("_static_renderer")
	var mid_stats := _audit_mid_renderer(static_renderer)

	lines.append("")
	lines.append("[MID Tier] %d mesh types, %d total instances, %d visible, %d LOD RIDs" % [
		mid_stats.mesh_types, mid_stats.total_instances,
		mid_stats.visible_instances, mid_stats.lod_rids])
	if mid_stats.invalid_rids > 0:
		lines.append("  Invalid RIDs: %d" % mid_stats.invalid_rids)
	if mid_stats.no_lod > 0:
		lines.append("  Instances without LOD: %d" % mid_stats.no_lod)

	if not mid_stats.issues.is_empty():
		lines.append("")
		lines.append("  Issues (first %d):" % mini(mid_stats.issues.size(), 10))
		for i in mini(mid_stats.issues.size(), 10):
			lines.append("    %s" % mid_stats.issues[i])

	lines.append("")
	lines.append("=================================")

	var output := "\n".join(lines)
	Log.info("tools", "MidTierDebugger: Audit complete\n%s" % output)
	return output


## Audit all NEAR-tier cell children
func _audit_near_cells(loaded_coords: Array[Vector2i], cam_pos: Vector3, cam_cull_mask: int) -> Dictionary:
	var stats := {
		"total": 0, "no_mesh": 0, "no_material": 0, "bad_range": 0,
		"wrong_layer": 0, "hidden": 0, "in_range_visible": 0,
		"in_range_invisible": 0, "issues": [] as Array[String]
	}

	for grid: Vector2i in loaded_coords:
		var cell_node: Node3D = _streaming_manager.get_loaded_cell(grid)
		if not cell_node:
			continue

		for child_idx in cell_node.get_child_count():
			var child = cell_node.get_child(child_idx)
			if not child is Node3D:
				continue
			_audit_near_object(child as Node3D, cam_pos, cam_cull_mask, stats)

	return stats


## Audit a single NEAR-tier object (recursive for mesh children)
func _audit_near_object(node: Node3D, cam_pos: Vector3, cam_cull_mask: int, stats: Dictionary) -> void:
	stats.total += 1

	var dist := cam_pos.distance_to(node.global_position)
	var obj_name: String = node.name
	var issues: Array[String] = stats.issues

	# Check visibility
	if not node.visible:
		stats.hidden += 1

	# Check layer mask on VisualInstance3D
	if node is VisualInstance3D:
		var vi := node as VisualInstance3D
		if (vi.layers & cam_cull_mask) == 0:
			stats.wrong_layer += 1
			if issues.size() < 50:
				issues.append("%s @ %.0fm: layer %d not in camera mask %d" % [
					obj_name, dist, vi.layers, cam_cull_mask])

	# Check visibility_range (only on VisualInstance3D)
	var vr_begin: float = 0.0
	var vr_end: float = 0.0
	var in_range := true

	if node is VisualInstance3D:
		vr_begin = node.visibility_range_begin
		vr_end = node.visibility_range_end

		if vr_end > 0.0:  # Has visibility_range configured
			if dist < vr_begin or dist > vr_end:
				in_range = false  # Correctly culled by range

			# Sanity check: begin should be < end
			if vr_begin >= vr_end:
				stats.bad_range += 1
				if issues.size() < 50:
					issues.append("%s: visibility_range inverted (begin=%.0f >= end=%.0f)" % [
						obj_name, vr_begin, vr_end])

			# Check for zero-margin (flicker risk)
			if node.visibility_range_end_margin == 0.0:
				stats.bad_range += 1
				if issues.size() < 50:
					issues.append("%s @ %.0fm: zero end_margin (flicker risk)" % [obj_name, dist])

	# Check mesh/material on MeshInstance3D children
	var found_mesh := false
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		found_mesh = true
		if not mi.mesh:
			stats.no_mesh += 1
			if issues.size() < 50:
				issues.append("%s @ %.0fm: MeshInstance3D with null mesh" % [obj_name, dist])
		elif mi.mesh.get_surface_count() > 0:
			var has_material := false
			if mi.material_override:
				has_material = true
			else:
				for s in mi.mesh.get_surface_count():
					if mi.mesh.surface_get_material(s):
						has_material = true
						break
			if not has_material:
				stats.no_material += 1
				if issues.size() < 50:
					issues.append("%s @ %.0fm: no material on any surface" % [obj_name, dist])
	else:
		# Check children for MeshInstance3D
		for child in node.get_children():
			if child is MeshInstance3D:
				found_mesh = true
				break

	# Count in-range visibility
	if in_range and found_mesh:
		if node.is_visible_in_tree():
			stats.in_range_visible += 1
		else:
			stats.in_range_invisible += 1
			if issues.size() < 50:
				issues.append("%s @ %.0fm: in range but not visible_in_tree" % [obj_name, dist])


## Audit MID-tier static renderer.
##
## Phase 3 registry path (post-step-7): one RS instance per PrototypeBatch,
## spanning all loaded cells. Instances themselves don't own an RS RID —
## they occupy slots in a batch's MultiMesh. Audit spot-checks batch RIDs
## (there are ~N batches for ~N_prototypes, not N_instances), and falls
## back to per-instance RID spot-check for the legacy register_mesh_type
## direct path.
func _audit_mid_renderer(static_renderer: Variant) -> Dictionary:
	var stats := {
		"mesh_types": 0, "total_instances": 0, "visible_instances": 0,
		"lod_rids": 0, "invalid_rids": 0, "no_lod": 0,
		"registry_batches": 0, "registry_slots": 0,
		"issues": [] as Array[String]
	}

	if not static_renderer:
		return stats

	var renderer_stats: Dictionary = static_renderer.get_stats()
	stats.mesh_types = renderer_stats.get("mesh_types", 0)
	stats.total_instances = renderer_stats.get("total_instances", 0)
	stats.visible_instances = renderer_stats.get("visible_instances", 0)
	stats.lod_rids = 0  # single-RID path; no per-LOD RID fan-out post-refactor
	stats.registry_batches = renderer_stats.get("registry_batches", 0)
	stats.registry_slots = renderer_stats.get("registry_slots", 0)

	var issues: Array[String] = stats.issues

	# Primary path: Phase 3 registry batches. Spot-check every batch's
	# single world-origin RS instance (cheap — there are only ~N_prototypes).
	var registry: RefCounted = static_renderer.get("_prototype_registry")
	if registry != null:
		var batches: Array[RefCounted] = registry.iter_batches()
		for batch: RefCounted in batches:
			var rid: RID = batch.rs_instance
			if not rid.is_valid():
				stats.invalid_rids += 1
				if issues.size() < 50:
					issues.append("PrototypeBatch @ %d slots: invalid RS instance RID" % batch.slot_count_live)

	# Legacy fallback: register_mesh_type direct callers still keep per-object
	# RIDs. Spot-check a sample of them.
	var instances: Dictionary = static_renderer.get("_instances")
	if instances:
		var checked := 0
		for id: int in instances:
			if checked >= 100:
				break
			var data = instances[id]
			if not data:
				continue
			# Skip registry-routed instances — they have registry_id >= 0 and
			# an always-invalid instance_rid under the current codepath.
			if data.registry_id >= 0:
				continue
			if not data.instance_rid.is_valid():
				stats.invalid_rids += 1
				if issues.size() < 50:
					issues.append("Legacy instance %d: invalid main RID" % id)
			checked += 1

	return stats

#endregion


#region Console Command Registration

static func register_console_commands(
	console: Node,
	streaming_manager: Variant,
	cell_manager: Variant,
	camera: Camera3D
) -> void:
	# Shared debugger instance (created on first use)
	# NOTE: Can't use class_name type hints inside static func lambdas — GDScript limitation
	var debugger: Node3D = null
	var script_ref := load("res://src/tools/mid_tier_debugger.gd")

	var get_or_create_debugger := func() -> Node3D:
		if debugger and is_instance_valid(debugger):
			return debugger
		var d := Node3D.new()
		d.set_script(script_ref)
		d.name = "MidTierDebugger"
		console.get_tree().root.add_child(d)
		d.init(streaming_manager, cell_manager, camera, console)
		debugger = d
		return d

	# mid_debug — toggle full debug mode
	var cmd_mid_debug := func(args: Dictionary) -> Variant:
		var d: Node3D = get_or_create_debugger.call()
		# Check for subcommand
		var subcmd: String = args.get("subcommand", "")
		if subcmd.is_empty():
			# Toggle full debug mode
			if d.is_running():
				d.stop()
				return "MID debug mode: OFF"
			else:
				d.start_full()
				return "MID debug mode: ON (autopilot + census + HUD + markers)"

		# Parse subcommand
		var parts := subcmd.strip_edges().split(" ", false)
		var cmd_name: String = parts[0].to_lower()

		if cmd_name == "speed" and parts.size() >= 2:
			var spd := parts[1].to_float()
			if spd > 0:
				d._autopilot_speed = spd
				return "Autopilot speed set to %.0f m/s" % spd
			return "Invalid speed value"

		if cmd_name == "diagonal":
			d._autopilot_diagonal = not d._autopilot_diagonal
			return "Diagonal path: %s" % ("ON" if d._autopilot_diagonal else "OFF")

		return "Unknown subcommand: %s. Use: speed <N>, diagonal" % cmd_name

	# mid_census — one-shot census
	var cmd_mid_census := func(args: Dictionary) -> Variant:
		var d: Node3D = get_or_create_debugger.call()
		return d.run_census_once()

	# mid_markers — toggle markers only
	var cmd_mid_markers := func(args: Dictionary) -> Variant:
		var d: Node3D = get_or_create_debugger.call()
		d.toggle_markers()
		return "Missing object markers: %s" % ("ON" if d._markers_active else "OFF")

	# mid_audit — visual audit
	var cmd_mid_audit := func(args: Dictionary) -> Variant:
		var d: Node3D = get_or_create_debugger.call()
		return d.run_audit()

	# Register mid_debug with optional subcommand parameter
	var md_params: Array[CommandRegistry.ParameterInfo] = [
		CommandRegistry.ParameterInfo.new("subcommand", TYPE_STRING, "Subcommand: speed <N>, diagonal", false, "")
	]
	console.register_command(
		"mid_debug", cmd_mid_debug,
		"Toggle MID-tier debug mode (autopilot + census + HUD + markers). Subcommands: speed <N>, diagonal",
		"debug",
		PackedStringArray(["md"]),
		md_params,
		PackedStringArray(["mid_debug", "mid_debug speed 50", "mid_debug diagonal"])
	)
	console.register_command(
		"mid_census", cmd_mid_census,
		"One-shot MID-tier object census (compare expected vs loaded)",
		"debug",
		PackedStringArray(["mc"])
	)
	console.register_command(
		"mid_markers", cmd_mid_markers,
		"Toggle missing object markers (red pillars at expected-but-absent positions)",
		"debug",
		PackedStringArray(["mm"])
	)
	console.register_command(
		"mid_audit", cmd_mid_audit,
		"Visual audit: check loaded objects for rendering issues (visibility_range, layers, materials)",
		"debug",
		PackedStringArray(["ma"])
	)

#endregion
