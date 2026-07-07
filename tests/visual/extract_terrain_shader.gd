extends Node3D

## One-shot utility: extracts Terrain3D's actual runtime shader code
## and saves it to docs/audit/ for inspection.
## Run: godot --path . res://tests/visual/extract_terrain_shader.tscn

const CS := preload("res://src/core/coordinate_system.gd")

func _ready() -> void:
	# Camera required before Terrain3D (avoids _grab_camera crash)
	var cam := Camera3D.new()
	cam.current = true
	add_child(cam)

	# Create Terrain3D with default material (no shader override)
	var terrain := Terrain3D.new()
	terrain.name = "Terrain3D"
	add_child(terrain)
	terrain.set_physics_process(false)

	if not CS.configure_terrain3d(terrain):
		print("ERROR: Failed to configure Terrain3D")
		get_tree().quit(1)
		return

	# Load terrain data so the shader is fully initialized
	var terrain_data_dir := SettingsManager.get_terrain_path()
	if terrain.data and DirAccess.dir_exists_absolute(terrain_data_dir):
		terrain.data.load_directory(terrain_data_dir)
		print("Loaded %d terrain regions" % terrain.data.get_region_count())

	# Wait a frame for shader compilation
	await get_tree().process_frame
	await get_tree().process_frame

	# Extract shader code
	if not terrain.material:
		print("ERROR: No terrain material")
		get_tree().quit(1)
		return

	var shader_rid: RID = terrain.material.get_shader_rid()
	if not shader_rid.is_valid():
		print("ERROR: Invalid shader RID")
		get_tree().quit(1)
		return

	var shader_code: String = RenderingServer.shader_get_code(shader_rid)
	if shader_code.is_empty():
		print("ERROR: Empty shader code")
		get_tree().quit(1)
		return

	# Save to file
	var output_path := "res://docs/audit/terrain3d_internal_shader.gdshader"
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	if file:
		file.store_string(shader_code)
		file.close()
		print("SUCCESS: Saved %d chars to %s" % [shader_code.length(), output_path])
	else:
		# Print to stdout as fallback
		print("=== SHADER CODE START ===")
		print(shader_code)
		print("=== SHADER CODE END ===")

	get_tree().quit(0)
