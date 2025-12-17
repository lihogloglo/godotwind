## La Palma Static Explorer - Uses pre-built Terrain3D data
##
## This version loads the terrain directly from saved Terrain3D files,
## which is much faster than streaming from raw heightmap files.
##
## Requirements:
##   - Run lapalma_batch_import.gd first to create lapalma_terrain/ directory
##
## Controls:
## - ZQSD/WASD to move, Right-click to look
## - Space/Shift for up/down
## - Ctrl for speed boost
## - Press F3 to toggle stats overlay
extends Node3D

const TERRAIN_DIR := "res://lapalma_terrain"

# Node references
@onready var camera: Camera3D = $FlyCamera
@onready var terrain_3d: Terrain3D = $Terrain3D
@onready var stats_panel: Panel = $UI/StatsPanel
@onready var stats_text: RichTextLabel = $UI/StatsPanel/VBox/StatsText

# Quick teleport buttons
@onready var roque_btn: Button = $UI/StatsPanel/VBox/QuickButtons/RoqueBtn
@onready var caldera_btn: Button = $UI/StatsPanel/VBox/QuickButtons/CalderaBtn
@onready var coast_btn: Button = $UI/StatsPanel/VBox/QuickButtons/CoastBtn
@onready var origin_btn: Button = $UI/StatsPanel/VBox/QuickButtons/OriginBtn
@onready var overview_btn: Button = $UI/StatsPanel/VBox/QuickButtons/OverviewBtn

# Camera controls
var camera_speed: float = 500.0
var mouse_sensitivity: float = 0.003
var mouse_captured: bool = false

# State
var _initialized: bool = false
var _stats_visible: bool = true
var _overview_mode: bool = false


func _ready() -> void:
	# Connect quick teleport buttons
	roque_btn.pressed.connect(func(): _teleport_to_position(Vector3(2000, 2500, -10000)))
	caldera_btn.pressed.connect(func(): _teleport_to_position(Vector3(-3000, 1500, -12000)))
	coast_btn.pressed.connect(func(): _teleport_to_position(Vector3(8000, 200, -8000)))
	origin_btn.pressed.connect(func(): _teleport_to_position(Vector3(0, 500, 0)))
	overview_btn.pressed.connect(_toggle_overview_mode)

	# Load terrain (deferred to allow await)
	call_deferred("_load_terrain")


func _load_terrain() -> void:
	var global_dir := ProjectSettings.globalize_path(TERRAIN_DIR)

	if not DirAccess.dir_exists_absolute(global_dir):
		push_error("Terrain directory not found: %s" % TERRAIN_DIR)
		push_error("Run lapalma_batch_import.gd first to create it!")
		return

	print("Loading terrain from %s..." % TERRAIN_DIR)
	var start := Time.get_ticks_msec()

	# Set the data directory - Terrain3D will load all region files from here
	terrain_3d.data_directory = global_dir

	# Configure display
	terrain_3d.show_checkered = false
	if terrain_3d.material:
		terrain_3d.material.show_checkered = false
		terrain_3d.material.show_colormap = true

	# Wait a frame for data to load
	await get_tree().process_frame

	var elapsed := (Time.get_ticks_msec() - start) / 1000.0
	var region_count := 0
	if terrain_3d.data:
		region_count = terrain_3d.data.get_region_count()

	print("Terrain loaded: %d regions in %.2f seconds" % [region_count, elapsed])

	_initialized = true
	_teleport_to_position(Vector3(0, 1000, 0))


func _teleport_to_position(pos: Vector3) -> void:
	# Get terrain height at position
	var height := pos.y
	if terrain_3d and terrain_3d.data:
		var terrain_height := terrain_3d.data.get_height(pos)
		if not is_nan(terrain_height) and terrain_height > -1000:
			height = terrain_height + 100.0

	camera.position = Vector3(pos.x, height, pos.z)
	camera.look_at(Vector3(pos.x, height - 100, pos.z - 200))


func _toggle_overview_mode() -> void:
	_overview_mode = not _overview_mode

	if _overview_mode:
		camera.position = Vector3(0, 30000, 10000)
		camera.look_at(Vector3(0, 0, -10000))
	else:
		_teleport_to_position(Vector3(0, 1000, 0))


func _update_stats() -> void:
	if not terrain_3d or not terrain_3d.data:
		return

	var fps := Engine.get_frames_per_second()
	var region_count := terrain_3d.data.get_region_count()

	# Estimate VRAM (rough)
	var estimated_vram_mb := region_count * 256 * 256 * 4 * 3 / 1024.0 / 1024.0 * 1.5

	var fps_color := "green" if fps >= 50 else ("yellow" if fps >= 30 else "red")

	stats_text.text = """[b]Performance[/b]
FPS: [color=%s]%.1f[/color]

[b]Terrain (Static)[/b]
Regions loaded: %d
Est. VRAM: %.1f MB

[b]Camera[/b]
Position: (%.0f, %.0f, %.0f)

[color=gray]F3: Toggle stats[/color]""" % [
		fps_color, fps,
		region_count,
		estimated_vram_mb,
		camera.position.x, camera.position.y, camera.position.z,
	]


# ==================== Input ====================

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				mouse_captured = true
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
				mouse_captured = false

	if event is InputEventMouseMotion and mouse_captured:
		camera.rotate_y(-event.relative.x * mouse_sensitivity)
		camera.rotate_object_local(Vector3.RIGHT, -event.relative.y * mouse_sensitivity)

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_F3:
				_stats_visible = not _stats_visible
				stats_panel.visible = _stats_visible


func _process(delta: float) -> void:
	if not _initialized:
		return

	# Update stats periodically
	if Engine.get_frames_drawn() % 30 == 0:
		_update_stats()

	if not mouse_captured:
		return

	# ZQSD/WASD movement
	var input_dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_Z) or Input.is_key_pressed(KEY_W):
		input_dir.z -= 1
	if Input.is_key_pressed(KEY_S):
		input_dir.z += 1
	if Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_A):
		input_dir.x -= 1
	if Input.is_key_pressed(KEY_D):
		input_dir.x += 1
	if Input.is_key_pressed(KEY_SPACE):
		input_dir.y += 1
	if Input.is_key_pressed(KEY_SHIFT):
		input_dir.y -= 1

	var speed := camera_speed
	if Input.is_key_pressed(KEY_CTRL):
		speed *= 3.0

	if input_dir != Vector3.ZERO:
		var move_dir := camera.global_transform.basis * input_dir.normalized()
		camera.position += move_dir * speed * delta
