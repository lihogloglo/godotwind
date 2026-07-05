extends Node

## Phase 3 M.1 — offline cook of per-cell world-object manifests.
## Plan: docs/plans/distant_rendering_recovery_2026_07.md, Phase 3 section.
##
## Builds each exterior cell's manifest through the EXISTING runtime path
## (MorrowindWorldObjectSource.get_cell_manifest) and serializes it via the
## C# NativeCellManifest codec, so cooked output equals the runtime build by
## construction. Standalone runner scene (same pattern as
## morrowind_hydrology_atlas_prebake_runner.tscn) — launch:
##   godot --path . res://src/tools/prebaking/cell_manifest_cook_runner.tscn
## Auto-quits: exit 0 = success, 1 = failure.

@warning_ignore("untyped_declaration", "unsafe_method_access")

const LoadingScreenScript := preload("res://src/core/ui/loading_screen.gd")
const WorldObjectSourceScript := preload("res://src/core/world/morrowind/morrowind_world_object_source.gd")

## Clear the source's per-cell caches every N cells so the cook doesn't hold
## every record of the whole worldspace in memory at once.
const CACHE_CLEAR_INTERVAL := 64


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var loading := LoadingScreenScript.new()
	add_child(loading)
	var ok: bool = await loading.load_game_data()
	loading.queue_free()
	if not ok:
		push_error("Manifest cook failed: game data did not load")
		get_tree().quit(1)
		return

	var esm: Node = get_node_or_null("/root/ESMManager")
	var settings: Node = get_node_or_null("/root/SettingsManager")
	if esm == null or settings == null:
		push_error("Manifest cook failed: ESMManager/SettingsManager autoload unavailable")
		get_tree().quit(1)
		return

	var out_dir: String = settings.call("get_cache_base_path").path_join("manifests")
	var mkdir_err := DirAccess.make_dir_recursive_absolute(out_dir)
	if mkdir_err != OK and mkdir_err != ERR_ALREADY_EXISTS:
		push_error("Manifest cook failed: cannot create %s (%s)" % [out_dir, error_string(mkdir_err)])
		get_tree().quit(1)
		return

	var factory = load("res://src/native/NativeFactory.cs").new()
	if not factory.IsAvailable():
		push_error("Manifest cook failed: native factory unavailable (build C# first)")
		get_tree().quit(1)
		return

	var source := WorldObjectSourceScript.new()
	var grid_keys: Array = (esm.get("exterior_cells") as Dictionary).keys()
	var start_ms := Time.get_ticks_msec()
	var cooked := 0
	var failed := 0
	var empty := 0
	var total_records := 0
	var total_bytes := 0

	for i in grid_keys.size():
		var parts: PackedStringArray = str(grid_keys[i]).split(",")
		if parts.size() != 2:
			continue
		var grid := Vector2i(int(parts[0]), int(parts[1]))
		var manifest: RefCounted = source.get_cell_manifest(grid)
		if manifest == null or (manifest.objects as Array).is_empty():
			empty += 1
			continue

		var out_path := out_dir.path_join("cell_%d_%d.gwm" % [grid.x, grid.y])
		var cooker = factory.CreateCellManifest()
		var err: int = cooker.CookFromRecords(grid, "", manifest.objects, out_path)
		if err != OK:
			push_error("Manifest cook failed for %s: %s (%s)" % [grid, error_string(err), str(cooker.LastError)])
			failed += 1
		else:
			cooked += 1
			total_records += (manifest.objects as Array).size()
			total_bytes += FileAccess.get_file_as_bytes(out_path).size()

		if (i + 1) % CACHE_CLEAR_INTERVAL == 0:
			source.clear_cache()
			print("Manifest cook: %d/%d cells (%d records, %.1f MB so far)" % [
				i + 1, grid_keys.size(), total_records, total_bytes / 1048576.0])
			await get_tree().process_frame

	var elapsed_ms := Time.get_ticks_msec() - start_ms
	print("Manifest cook complete: %d cooked, %d empty, %d failed | %d records, %.1f MB, %.1f s | out=%s" % [
		cooked, empty, failed, total_records, total_bytes / 1048576.0, elapsed_ms / 1000.0, out_dir])
	get_tree().quit(0 if failed == 0 else 1)
