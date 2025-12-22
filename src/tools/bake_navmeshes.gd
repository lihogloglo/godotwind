@tool
extends SceneTree

## Headless NavMesh Baking Tool
##
## Command-line tool for prebaking navigation meshes.
## Can be run in headless Godot or in editor.
##
## Usage:
##   # Bake all exterior cells
##   godot --headless --script res://src/tools/bake_navmeshes.gd
##
##   # Bake specific cell
##   godot --headless --script res://src/tools/bake_navmeshes.gd -- --cell -2,-3
##
##   # Bake interior cells only
##   godot --headless --script res://src/tools/bake_navmeshes.gd -- --interior-only
##
##   # Bake with options
##   godot --headless --script res://src/tools/bake_navmeshes.gd -- --skip-existing=false
##
## Arguments:
##   --cell X,Y          Bake only specific exterior cell (e.g., -2,-3)
##   --cell "Name"       Bake only specific interior cell (e.g., "Seyda Neen")
##   --interior-only     Bake only interior cells
##   --exterior-only     Bake only exterior cells (default)
##   --skip-existing     Skip cells that already have baked navmesh (default: true)
##   --output DIR        Output directory (default: Documents/Godotwind/cache/navmeshes)

const NavMeshBaker := preload("res://src/tools/navmesh_baker.gd")

var baker: RefCounted
var args: Dictionary = {}


func _init() -> void:
	print("=" * 80)
	print("NavMesh Baking Tool - Headless Mode")
	print("=" * 80)
	print()

	# Parse command line arguments
	_parse_arguments()

	# Initialize ESM system
	print("Initializing ESM system...")
	if not _initialize_esm():
		print("ERROR: Failed to initialize ESM system")
		quit(1)
		return

	# Create baker
	baker = NavMeshBaker.new()
	# Use settings manager default unless --output is explicitly provided
	if args.has("output"):
		baker.output_dir = args.get("output")
	# Otherwise leave empty and let initialize() use SettingsManager
	baker.bake_exterior_cells = args.get("bake_exterior", true)
	baker.bake_interior_cells = args.get("bake_interior", false)
	baker.skip_existing = args.get("skip_existing", true)

	# Connect signals for progress reporting
	baker.progress.connect(_on_progress)
	baker.cell_baked.connect(_on_cell_baked)
	baker.batch_complete.connect(_on_batch_complete)

	# Run baking
	_run_baking()


func _parse_arguments() -> void:
	var cmd_args := OS.get_cmdline_args()
	var i := 0

	# Find the "--" separator (everything after is our args)
	var found_separator := false
	for arg in cmd_args:
		if arg == "--":
			found_separator = true
			continue
		if not found_separator:
			continue

		# Parse argument
		if arg.begins_with("--cell=") or arg.begins_with("--cell"):
			var cell_str := ""
			if arg.begins_with("--cell="):
				cell_str = arg.substr(7)
			elif i + 1 < cmd_args.size():
				cell_str = cmd_args[i + 1]

			args["specific_cell"] = cell_str

		elif arg == "--interior-only":
			args["bake_interior"] = true
			args["bake_exterior"] = false

		elif arg == "--exterior-only":
			args["bake_interior"] = false
			args["bake_exterior"] = true

		elif arg.begins_with("--skip-existing="):
			var val := arg.substr(16).to_lower()
			args["skip_existing"] = val == "true" or val == "1"

		elif arg.begins_with("--output="):
			args["output"] = arg.substr(9)

		i += 1

	# Defaults
	if not args.has("bake_exterior"):
		args["bake_exterior"] = true
	if not args.has("bake_interior"):
		args["bake_interior"] = false
	if not args.has("skip_existing"):
		args["skip_existing"] = true

	# Print configuration
	print("Configuration:")
	print("  Exterior cells: %s" % args.get("bake_exterior", false))
	print("  Interior cells: %s" % args.get("bake_interior", false))
	print("  Skip existing: %s" % args.get("skip_existing", true))
	print("  Output: %s" % (args.get("output") if args.has("output") else "(using SettingsManager default)"))
	if args.has("specific_cell"):
		print("  Specific cell: %s" % args.specific_cell)
	print()


func _initialize_esm() -> bool:
	# Check if ESMManager is available
	if not ESMManager:
		print("ERROR: ESMManager autoload not found")
		return false

	# Check if data is loaded
	if ESMManager.cells.is_empty():
		print("ERROR: ESMManager has no cell data")
		print("Make sure Morrowind.esm is loaded and configured in settings")
		return false

	print("ESM system initialized: %d cells loaded" % ESMManager.cells.size())
	return true


func _run_baking() -> void:
	# Check if baking specific cell
	if args.has("specific_cell"):
		_bake_specific_cell(args.specific_cell)
	else:
		_bake_all_cells()

	# Done
	quit(0)


func _bake_all_cells() -> void:
	print("Starting batch baking...")
	print()

	var result := baker.bake_all_cells()

	print()
	print("=" * 80)
	print("Baking Complete")
	print("=" * 80)
	print("Total: %d" % result.total)
	print("Success: %d" % result.success)
	print("Skipped: %d" % result.skipped)
	print("Failed: %d" % result.failed)

	if result.failed > 0:
		print("\nFailed cells:")
		for cell_id in result.failed_cells:
			print("  - %s" % cell_id)


func _bake_specific_cell(cell_str: String) -> void:
	print("Baking specific cell: %s" % cell_str)
	print()

	# Parse cell identifier
	var cell: CellRecord = null

	# Try parsing as exterior grid coordinates (e.g., "-2,-3")
	if "," in cell_str:
		var parts := cell_str.split(",")
		if parts.size() == 2:
			var x := parts[0].to_int()
			var y := parts[1].to_int()
			var cell_id := "%d,%d" % [x, y]
			cell = ESMManager.cells.get(cell_id)

	# Try as interior cell name
	if not cell:
		cell = ESMManager.get_cell(cell_str)

	if not cell:
		print("ERROR: Cell not found: %s" % cell_str)
		quit(1)
		return

	# Bake the cell
	if baker.initialize() != OK:
		print("ERROR: Failed to initialize baker")
		quit(1)
		return

	var result := baker.bake_cell(cell)

	print()
	if result.success:
		print("SUCCESS: Baked navmesh with %d polygons" % result.polygon_count)
		print("  Output: %s" % result.output_path)
		print("  Time: %.2fs" % result.bake_time)
	else:
		print("FAILED: %s" % result.get("error", "Unknown error"))
		quit(1)


func _on_progress(current: int, total: int, cell_id: String) -> void:
	# Progress callback - already printed by NavMeshBaker
	pass


func _on_cell_baked(cell_id: String, success: bool, output_path: String, polygon_count: int) -> void:
	# Cell baked callback
	if not success:
		print("    FAILED: %s" % cell_id)


func _on_batch_complete(total: int, success_count: int, failed_count: int) -> void:
	# Batch complete callback
	pass
