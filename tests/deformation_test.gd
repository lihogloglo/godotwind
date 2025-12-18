# deformation_test.gd
# Test script for RTT deformation system
# Attach to any Node3D in your scene to test deformation
extends Node3D

@export var auto_test_on_ready: bool = false
@export var test_region: Vector2i = Vector2i(0, 0)
@export var test_material: DeformationManager.MaterialType = DeformationManager.MaterialType.SNOW

# Test modes
var _test_mode: int = 0  # 0=manual, 1=auto_spray, 2=circular_pattern

func _ready():
	print("=== Deformation System Test ===")
	print("Press 1: Manual click deformation")
	print("Press 2: Auto spray deformation")
	print("Press 3: Circular pattern test")
	print("Press 4: Toggle recovery")
	print("Press 5: Cycle material types")
	print("Press R: Reload test region")
	print("Press C: Clear all regions")
	print("================================")

	if auto_test_on_ready:
		_run_basic_test()

func _run_basic_test():
	print("[Test] Running basic deformation test...")

	# Enable deformation
	DeformationManager.set_deformation_enabled(true)

	# Load test region
	DeformationManager.load_deformation_region(test_region)

	# Wait for system to initialize
	await get_tree().create_timer(0.5).timeout

	# Apply test pattern
	print("[Test] Creating test deformation pattern...")
	for i in range(10):
		var pos = Vector3(i * 2.0, 0, 0)
		DeformationManager.add_deformation(
			pos,
			test_material,
			0.8
		)

	print("[Test] Test pattern complete! Check terrain for deformations.")

func _process(delta):
	# Auto spray mode
	if _test_mode == 1:
		var camera = get_viewport().get_camera_3d()
		if camera:
			var random_offset = Vector3(
				randf_range(-2, 2),
				0,
				randf_range(-2, 2)
			)
			DeformationManager.add_deformation(
				camera.global_position + random_offset,
				test_material,
				0.3
			)

	# Circular pattern mode
	if _test_mode == 2:
		var camera = get_viewport().get_camera_3d()
		if camera:
			var time = Time.get_ticks_msec() / 1000.0
			var angle = time * 2.0
			var radius = 5.0
			var offset = Vector3(cos(angle), 0, sin(angle)) * radius
			DeformationManager.add_deformation(
				camera.global_position + offset,
				test_material,
				0.5
			)

func _input(event):
	if not event is InputEventKey or not event.pressed:
		return

	match event.keycode:
		KEY_1:
			_test_mode = 0
			print("[Test] Mode: Manual click deformation")

		KEY_2:
			_test_mode = 1 if _test_mode != 1 else 0
			print("[Test] Mode: Auto spray ", "ENABLED" if _test_mode == 1 else "DISABLED")

		KEY_3:
			_test_mode = 2 if _test_mode != 2 else 0
			print("[Test] Mode: Circular pattern ", "ENABLED" if _test_mode == 2 else "DISABLED")

		KEY_4:
			var current = DeformationManager.recovery_enabled
			DeformationManager.set_recovery_enabled(not current)
			print("[Test] Recovery: ", "ENABLED" if not current else "DISABLED")

		KEY_5:
			_cycle_material_type()

		KEY_R:
			print("[Test] Reloading test region...")
			DeformationManager.unload_deformation_region(test_region)
			await get_tree().process_frame
			DeformationManager.load_deformation_region(test_region)
			print("[Test] Region reloaded")

		KEY_C:
			print("[Test] Clearing all regions...")
			DeformationManager._active_regions.clear()
			print("[Test] Regions cleared")

		KEY_SPACE:
			if _test_mode == 0:
				_add_deformation_at_camera()

		KEY_T:
			_run_basic_test()

func _add_deformation_at_camera():
	var camera = get_viewport().get_camera_3d()
	if camera == null:
		print("[Test] No camera found")
		return

	# Raycast from camera to find ground position
	var from = camera.global_position
	var to = from + camera.global_transform.basis.z * -100

	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	var result = space_state.intersect_ray(query)

	var deform_pos: Vector3
	if result:
		deform_pos = result.position
	else:
		# No hit, use camera position
		deform_pos = camera.global_position

	DeformationManager.add_deformation(
		deform_pos,
		test_material,
		0.5
	)

	print("[Test] Deformation added at: ", deform_pos, " (Material: ", _get_material_name(), ")")

func _cycle_material_type():
	match test_material:
		DeformationManager.MaterialType.SNOW:
			test_material = DeformationManager.MaterialType.MUD
		DeformationManager.MaterialType.MUD:
			test_material = DeformationManager.MaterialType.ASH
		DeformationManager.MaterialType.ASH:
			test_material = DeformationManager.MaterialType.SAND
		DeformationManager.MaterialType.SAND:
			test_material = DeformationManager.MaterialType.SNOW

	print("[Test] Material type: ", _get_material_name())

func _get_material_name() -> String:
	match test_material:
		DeformationManager.MaterialType.SNOW:
			return "SNOW"
		DeformationManager.MaterialType.MUD:
			return "MUD"
		DeformationManager.MaterialType.ASH:
			return "ASH"
		DeformationManager.MaterialType.SAND:
			return "SAND"
		_:
			return "UNKNOWN"

# Visualize deformation regions (debug)
func _draw_debug_info():
	if not Engine.is_editor_hint():
		return

	var camera = get_viewport().get_camera_3d()
	if camera == null:
		return

	var camera_region = DeformationManager.world_to_region_coord(camera.global_position)

	# Draw active region bounds
	for region_coord in DeformationManager._active_regions.keys():
		var region_origin = Vector2(region_coord) * DeformationManager.REGION_SIZE_METERS
		# Would need to use DebugDraw or similar to visualize
