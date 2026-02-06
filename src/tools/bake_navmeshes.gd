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
	Logger.info("navmesh", "=" .repeat(80))
	Logger.info("navmesh", "NavMesh Baking Tool - Headless Mode")
	Logger.info("navmesh", "=" .repeat(80))

	# Parse command line arguments
	_parse_arguments()

	# Initialize ESM system
	Logger.info("navmesh", "Initializing ESM system...")
	if not _initialize_esm():
		Logger.error("navmesh", "Failed to initialize ESM system")
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

	# Log configuration
	Logger.info("navmesh", "Configuration:")
	Logger.info("navmesh", "  Exterior cells: %s" % args.get("bake_exterior", false))
	Logger.info("navmesh", "  Interior cells: %s" % args.get("bake_interior", false))
	Logger.info("navmesh", "  Skip existing: %s" % args.get("skip_existing", true))
	Logger.info("navmesh", "  Output: %s" % (args.get("output") if args.has("output") else "(using SettingsManager default)"))
	if args.has("specific_cell"):
		Logger.info("navmesh", "  Specific cell: %s" % args.specific_cell)


func _initialize_esm() -> bool:
	# Check if ESMManager is available
	if not ESMManager:
		Logger.error("navmesh", "ESMManager autoload not found")
		return false

	# Check if data is loaded
	if ESMManager.cells.is_empty():
		Logger.error("navmesh", "ESMManager has no cell data")
		Logger.error("navmesh", "Make sure Morrowind.esm is loaded and configured in settings")
		return false

	Logger.info("navmesh", "ESM system initialized: %d cells loaded" % ESMManager.cells.size())
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
	Logger.info("navmesh", "Starting batch baking...")

	var result := baker.bake_all_cells()

	Logger.info("navmesh", "=" .repeat(80))
	Logger.info("navmesh", "Baking Complete")
	Logger.info("navmesh", "=" .repeat(80))
	Logger.info("navmesh", "Total: %d" % result.total)
	Logger.info("navmesh", "Success: %d" % result.success)
	Logger.info("navmesh", "Skipped: %d" % result.skipped)
	Logger.info("navmesh", "Failed: %d" % result.failed)

	if result.failed > 0:
		Logger.warn("navmesh", "Failed cells:")
		for cell_id in result.failed_cells:
			Logger.warn("navmesh", "  - %s" % cell_id)


func _bake_specific_cell(cell_str: String) -> void:
	Logger.info("navmesh", "Baking specific cell: %s" % cell_str)

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
		Logger.error("navmesh", "Cell not found: %s" % cell_str)
		quit(1)
		return

	# Bake the cell
	if baker.initialize() != OK:
		Logger.error("navmesh", "Failed to initialize baker")
		quit(1)
		return

	var result := baker.bake_cell(cell)

	if result.success:
		Logger.info("navmesh", "SUCCESS: Baked navmesh with %d polygons" % result.polygon_count)
		Logger.info("navmesh", "  Output: %s" % result.output_path)
		Logger.info("navmesh", "  Time: %.2fs" % result.bake_time)
	else:
		Logger.error("navmesh", "FAILED: %s" % result.get("error", "Unknown error"))
		quit(1)


func _on_progress(current: int, total: int, cell_id: String) -> void:
	# Progress callback - already printed by NavMeshBaker
	pass


func _on_cell_baked(cell_id: String, success: bool, output_path: String, polygon_count: int) -> void:
	# Cell baked callback
	if not success:
		Logger.warn("navmesh", "FAILED: %s" % cell_id)


func _on_batch_complete(total: int, success_count: int, failed_count: int) -> void:
	# Batch complete callback
	pass
