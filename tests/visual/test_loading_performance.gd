@tool
extends Node3D

# Test parameters
const TEST_CELL_GRID := Vector2i(-2, -2)  # Balmora region
const CAMERA_HEIGHT := 1000.0
const TEST_DURATION := 5.0

var _camera: Camera3D
var _streaming_manager: Node
var _start_time: float
var _frames: int = 0
var _loading_complete: bool = false

func _ready() -> void:
	# Setup camera
	_camera = Camera3D.new()
	_camera.position = Vector3(
		TEST_CELL_GRID.x * 8192 * 0.014, # Approx world pos
		CAMERA_HEIGHT,
		TEST_CELL_GRID.y * 8192 * 0.014
	)
	_camera.look_at(_camera.position + Vector3.DOWN, Vector3.FORWARD)
	add_child(_camera)

	# Find or create streaming manager
	_streaming_manager = get_node_or_null("/root/Main/World/NativeStreamingManager")
	if not _streaming_manager:
		printerr("[Test] NativeStreamingManager not found!")
		get_tree().quit(1)
		return

	# Hook into loading signal
	if _streaming_manager.has_signal("cell_loaded"):
		_streaming_manager.connect("cell_loaded", _on_cell_loaded)

	print("[Test] Starting load of cell %s..." % TEST_CELL_GRID)
	_start_time = Time.get_ticks_msec()
	
	# Force load via camera update
	_streaming_manager.call("update_streaming", _camera.position)

func _process(delta: float) -> void:
	_frames += 1
	
	if _loading_complete:
		var elapsed := (Time.get_ticks_msec() - _start_time) / 1000.0
		if elapsed > TEST_DURATION:
			_finish_test()

func _on_cell_loaded(grid: Vector2i) -> void:
	if grid == TEST_CELL_GRID:
		var load_time := Time.get_ticks_msec() - _start_time
		print("[Test] Cell %s loaded in %d ms" % [grid, load_time])
		_loading_complete = true
		
		# Take screenshot
		await get_tree().process_frame
		var viewport := get_viewport()
		var img := viewport.get_texture().get_image()
		img.save_png("res://tests/visual/load_perf_%d_%d.png" % [grid.x, grid.y])
		print("[Test] Screenshot saved")

func _finish_test() -> void:
	print("[Test] FPS Average: %.2f" % (_frames / TEST_DURATION))
	get_tree().quit()
