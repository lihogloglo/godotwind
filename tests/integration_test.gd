extends SceneTree
## Integration Test - Attempts to load actual Morrowind ESM
## Run with: godot --headless --script res://tests/integration_test.gd -- "path/to/Morrowind.esm"
##
## This test requires actual game files and validates the full loading pipeline.

func _init() -> void:
	print("=" .repeat(60))
	print("GODOTWIND INTEGRATION TEST")
	print("=" .repeat(60))

	var esm_path := _get_esm_path()
	if esm_path.is_empty():
		print("ERROR: No ESM path provided")
		print("Usage: godot --headless --script res://tests/integration_test.gd -- \"path/to/Morrowind.esm\"")
		print("")
		print("Or set MORROWIND_ESM environment variable")
		quit(2)
		return

	print("Loading: %s" % esm_path)
	print("")

	_run_integration_test(esm_path)


func _get_esm_path() -> String:
	# Check command line arguments
	var args := OS.get_cmdline_args()
	for i in range(args.size()):
		if args[i] == "--" and i + 1 < args.size():
			return args[i + 1]

	# Check environment variable
	var env_path := OS.get_environment("MORROWIND_ESM")
	if not env_path.is_empty() and FileAccess.file_exists(env_path):
		return env_path

	# Try common paths
	var common_paths := [
		"C:/Program Files (x86)/Steam/steamapps/common/Morrowind/Data Files/Morrowind.esm",
		"C:/Program Files/Steam/steamapps/common/Morrowind/Data Files/Morrowind.esm",
		"C:/GOG Games/Morrowind/Data Files/Morrowind.esm",
		"D:/Games/Morrowind/Data Files/Morrowind.esm",
		"D:/SteamLibrary/steamapps/common/Morrowind/Data Files/Morrowind.esm",
	]

	for path in common_paths:
		if FileAccess.file_exists(path):
			return path

	return ""


func _run_integration_test(esm_path: String) -> void:
	var manager_script := load("res://src/core/esm/esm_manager.gd")
	var manager = manager_script.new()

	# Connect to signals
	var loading_complete := false
	var load_error := ""

	manager.loading_started.connect(func(): print("Loading started..."))
	manager.loading_progress.connect(func(current, total):
		if current % 10000 == 0:
			print("  Progress: %d / %d (%.1f%%)" % [current, total, float(current) / total * 100])
	)
	manager.loading_completed.connect(func():
		loading_complete = true
		print("Loading completed!")
	)
	manager.loading_failed.connect(func(error):
		load_error = error
		print("Loading failed: %s" % error)
	)

	# Start loading
	var start_time := Time.get_ticks_msec()
	manager.load_esm(esm_path)
	var duration := Time.get_ticks_msec() - start_time

	print("")
	print("─" .repeat(60))
	print("RESULTS")
	print("─" .repeat(60))
	print("")

	if not load_error.is_empty():
		print("❌ LOAD FAILED: %s" % load_error)
		quit(1)
		return

	# Print statistics
	print("Load time: %.2f seconds" % (duration / 1000.0))
	print("")

	var stats: Dictionary = manager.get_statistics()
	print("Records loaded:")
	for key in stats:
		if stats[key] > 0:
			print("  %s: %d" % [key, stats[key]])

	print("")

	# Sample some data
	print("Sample data:")

	var cells: Dictionary = manager.get_all_cells()
	if cells.size() > 0:
		var sample_cell = cells.values()[0]
		print("  First cell: %s" % sample_cell.name if sample_cell.has("name") else "  First cell: (unnamed)")

	var statics: Dictionary = manager.get_all_statics()
	if statics.size() > 0:
		var sample_static = statics.values()[0]
		print("  First static: %s → %s" % [statics.keys()[0], sample_static.model if sample_static.has("model") else "?"])

	print("")
	print("🎉 INTEGRATION TEST PASSED!")
	quit(0)
