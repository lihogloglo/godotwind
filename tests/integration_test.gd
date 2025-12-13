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
	# Check command line arguments (highest priority for testing)
	var args := OS.get_cmdline_args()
	for i in range(args.size()):
		if args[i] == "--" and i + 1 < args.size():
			return args[i + 1]

	# Check MORROWIND_ESM environment variable (legacy support)
	var env_esm := OS.get_environment("MORROWIND_ESM")
	if not env_esm.is_empty() and FileAccess.file_exists(env_esm):
		return env_esm

	# Check MORROWIND_DATA_PATH environment variable + esm file
	var env_data_path := OS.get_environment("MORROWIND_DATA_PATH")
	if not env_data_path.is_empty():
		var esm_file := SettingsManager.get_esm_file()
		var full_path := env_data_path.path_join(esm_file)
		if FileAccess.file_exists(full_path):
			return full_path

	# Use SettingsManager's configured/detected path
	var esm_path := SettingsManager.get_esm_path()
	if not esm_path.is_empty() and FileAccess.file_exists(esm_path):
		return esm_path

	# Fallback: try auto-detection
	var detected_path := SettingsManager.auto_detect_installation()
	if not detected_path.is_empty():
		return detected_path.path_join(SettingsManager.get_esm_file())

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
