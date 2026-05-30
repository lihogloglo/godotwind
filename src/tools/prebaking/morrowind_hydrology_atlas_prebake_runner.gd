extends Node

const HydrologyAtlasPrebaker := preload("res://src/tools/prebaking/morrowind_hydrology_atlas_prebaker.gd")
const CS := preload("res://src/core/coordinate_system.gd")


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var settings: Node = get_node_or_null("/root/SettingsManager")
	if settings == null:
		push_error("Hydrology atlas bake failed: SettingsManager autoload is unavailable")
		get_tree().quit(1)
		return
	var terrain := Terrain3D.new()
	terrain.name = "HydrologyPrebakeTerrain"
	var camera := Camera3D.new()
	camera.name = "HydrologyPrebakeCamera"
	add_child(camera)
	add_child(terrain)
	terrain.set_physics_process(false)
	terrain.set_process(false)
	await get_tree().process_frame
	CS.configure_terrain3d(terrain)
	var terrain_dir: String = settings.call("get_terrain_path")
	terrain.data.load_directory(terrain_dir)

	var baker: RefCounted = HydrologyAtlasPrebaker.new()
	baker.set("terrain_data_directory", terrain_dir)
	baker.set("output_directory", settings.call("get_cache_base_path").path_join("water").path_join("morrowind_hydrology_atlas"))
	baker.progress.connect(func(current: int, total: int, region_key: String) -> void:
		print("Hydrology atlas: %d/%d %s" % [current, total, region_key])
	)
	var result: Dictionary = baker.call("bake_from_terrain3d", terrain)
	var err := int(result.get("error", OK))
	if err != OK:
		push_error("Hydrology atlas bake failed: %s" % String(result.get("message", error_string(err))))
		get_tree().quit(1)
		return
	print("Hydrology atlas bake complete: %d baked, %d failed, output=%s" % [
		int(result.get("success", 0)),
		int(result.get("failed", 0)),
		String(result.get("output_directory", "")),
	])
	get_tree().quit(0)
